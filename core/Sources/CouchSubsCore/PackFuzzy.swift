// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Paketteki satırın bulanık imzası: OCR'ın bozduğu satırı (harf hatası, birleşmiş sözcük) bulmak için.
/// canon metnin boşlukları atılır, OCR'ın karıştırdığı harfler birleştirilir (l/1/ı/j → i, 0 → o, 5 → s), kalan dizinin
/// her farklı üçlüsü FNV-1a 64 ile özetlenip m bitten birine düşer (Bloom kümesi; m uzunlukla büyür: 64/128/256).
/// Her bit onlarca farklı üçlünün ortak izidir ve sıra tutulmaz: İngilizce metin geri çıkarılamaz.
/// Windows'taki CouchSubs.Core/PackFuzzy.cs ve paket betiği (augment.py, common.py) ile birebir aynı; ortak deneme verisi
/// Tests/CouchSubsCoreTests/Fixtures/fuzzy-vectors.json.
public enum PackFuzzy {
    /// Bundan kısa satırda bulanık arama yok.
    public static let minLength = 16
    /// Bloom kümesinin en büyük boyu (32 bayt).
    static let maxBits = 256
    /// Üçlü başına bit.
    static let bitsPerGram = 3
    /// OCR izi olmayan satır neredeyse aynı olmalı: (uzunluk sınırı, en düşük benzerlik).
    static let cleanMinimum: [(limit: Int, value: Double)] = [(24, 90), (256, 80)]
    /// OCR izi olan satır: (uzunluk sınırı, en düşük benzerlik).
    static let damagedMinimum: [(limit: Int, value: Double)] = [(24, 70), (40, 60), (256, 55)]
    /// Türkçesi farklı en yakın ikinci aday en az bu kadar geride olmalı.
    static let margin = 5.0
    /// Tek yönlü kapsama (yarım ya da fazlalıklı okuma): iki taraf da en az `minLength` harf; kısa tarafın en az
    /// `inner`'ı uzun tarafta; uzun tarafın en az `partial`'ı (satır yarım okunmuş) ya da `extra`'sı (okumada fazlalık
    /// var: köşe yazısı, çöp) kısa tarafta; benzerlik `inner - penalty` sayılır. Fazlalık az olmalı: iki ayrı altyazının
    /// birleştiği okuma tek bir altyazıya çıkmasın.
    static let containment = (minLength: 22, inner: 90.0, partial: 25.0, extra: 55.0, penalty: 10.0)
    /// Fazlalıklı okumada yan cümle denetimi (`clauseHashes`): okuma birden çok cümle ya da yan cümleyse en az `letters`
    /// harfli her birinin üçlülerinin en az `covered`'ı kısa adayda olmalı. İki altyazı yan yana okununca ("Hey, look. …
    /// But listen, I got some other work.") ikinci cümle adayda yoktur: yalnız birinin Türkçesi gösterilmez, satır cümle
    /// cümle aranır ya da motora gider.
    static let sentenceCheck = (letters: 6, covered: 30.0)

    private static let fold: [Unicode.Scalar: Unicode.Scalar] = [
        "l": "i", "1": "i", "ı": "i", "j": "i", "0": "o", "5": "s", "æ": "a", "ø": "o", "œ": "o", "ß": "s",
    ]

    /// Yazı tanımanın sık karıştırdığı harf dizileri (canon metinde, küçük harf): okunan → asıl olabilecek.
    static let confusions: [(read: String, real: String)] = [
        ("rn", "m"), ("m", "rn"), ("cl", "d"), ("d", "cl"), ("vv", "w"), ("ri", "n"), ("n", "ri"), ("li", "h"),
        ("l", "i"), ("i", "l"), ("1", "l"), ("1", "i"), ("0", "o"), ("5", "s"), ("j", "i"), ("c", "e"), ("e", "c"),
        ("a", "o"), ("o", "a"), ("h", "b"), ("b", "h"), ("f", "t"), ("t", "f"), ("u", "v"), ("v", "u"), ("y", "v"),
        ("v", "y"), ("q", "g"), ("g", "q"),
    ]
    /// Tek düzeltmeyle denenecek en kısa ve en uzun canon satır (harf sayısı); daha uzun satırda bulanık imza yeter.
    static let variantLength = (minimum: 6, maximum: 48)

    /// Satırın tek bir OCR düzeltmesiyle olabileceği canon hâller: karıştırılan harf dizisi değişir, bir harf düşer,
    /// sözcük ikiye bölünür (OCR boşluğu ya da kesme işaretini yuttu: "cant" → "can t") ya da iki sözcük birleşir.
    /// Pakette tam anahtarla aranırlar; bulanık imzanın yetmediği kısa satırlar içindir.
    static func variants(_ text: String) -> [String] {
        let canon = Array(PackKey.canon(text).unicodeScalars)
        guard canon.count >= variantLength.minimum, canon.count <= variantLength.maximum else { return [] }
        var output = Set<String>()
        func add(_ scalars: ArraySlice<Unicode.Scalar>...) {
            var view = String.UnicodeScalarView()
            for part in scalars { view.append(contentsOf: part) }
            let value = String(view)
            if !value.isEmpty, !value.hasPrefix(" "), !value.hasSuffix(" "), !value.contains("  ") { output.insert(value) }
        }
        let space: [Unicode.Scalar] = [" "]
        for index in canon.indices {
            for (read, real) in confusionScalars where starts(canon, at: index, with: read) {
                add(canon[..<index], real[...], canon[(index + read.count)...])
            }
            if canon[index] == " " {
                add(canon[..<index], canon[(index + 1)...])
            } else {
                add(canon[..<index], canon[(index + 1)...])
                if index > 0, canon[index - 1] != " " { add(canon[..<index], space[...], canon[index...]) }
            }
        }
        output.remove(String(String.UnicodeScalarView(canon)))
        return output.sorted()
    }

    /// İkinci tur düzeltmelerin en kısa ve en uzun canon satırı ve iki karışıklığın birden deneneceği en uzun satır.
    static let editLength = (minimum: 10, maximum: 40, pairs: 32)
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz".utf8)
    /// Yazı tanımanın birbirine benzettiği harfler (canon, küçük harf): okunan → asıl olabilecek. İkinci tur
    /// düzeltmede bir harf yalnız bunlardan birine döner: herhangi bir harfe dönmek "she" → "the", "honey" → "money"
    /// gibi başka gerçek satırlara çıkıyordu.
    static let lookalikes: [String: String] = [
        "a": "oecusdq", "b": "hkdlp", "c": "eoa", "d": "aobq", "e": "coa", "f": "tlir", "g": "qyp", "h": "bnk",
        "i": "ljtfr", "j": "il", "k": "hbx", "l": "ijtf", "m": "n", "n": "mhru", "o": "aecudq", "p": "qgb", "q": "gpo",
        "r": "nfti", "s": "z", "t": "flir", "u": "vnoa", "v": "uyw", "w": "v", "x": "ky", "y": "vgx", "z": "s",
        "0": "o", "1": "il", "5": "s", "6": "b", "8": "b", "9": "g",
    ]
    private static let lookalikeBytes: [[UInt8]] = {
        var table = [[UInt8]](repeating: [], count: 128)
        for (read, real) in lookalikes { table[Int(read.utf8.first!)] = Array(real.utf8) }
        return table
    }()

    /// İkinci tur düzeltmeler: `variants` pakette hiçbir satıra çıkmazsa denenir. Bir harf benzediği bir harf olur
    /// (`lookalikes`), yutulmuş bir harf eklenir ("abut" → "about") ya da `editLength.pairs`ten kısa satırda iki
    /// karışıklık birden düzelir ("l'm rnad" → "i'm mad"). Çok aday ürettikleri için yalnız `editLength` sınırındaki
    /// satırlarda; `variants`taki ve satırın kendisi olan hâller yoktur. Sıralı canon metinler (denemeler için;
    /// arama `editKeys` ile yapılır).
    static func edits(_ text: String) -> [String] {
        var output = Set<String>()
        forEachEdit(text) { output.insert(String(decoding: $0, as: UTF8.self)) }
        output.subtract(variants(text))
        output.remove(PackKey.canon(text))
        return output.sorted()
    }

    /// `edits`in anahtarları (`PackKey.canonNumber`), metne çevirmeden.
    static func editKeys(_ text: String) -> Set<UInt64> {
        var output = Set<UInt64>()
        forEachEdit(text) { if let key = PackKey.canonNumber(bytes: $0) { output.insert(key) } }
        for variant in variants(text) { if let key = PackKey.canonNumber(variant) { output.remove(key) } }
        if let key = PackKey.canonNumber(PackKey.canon(text)) { output.remove(key) }
        return output
    }

    /// İkinci tur adaylar, UTF-8 baytlarıyla (yinelenebilir). Değişen ve eklenen harfler ASCII'dir; UTF-8'de ASCII
    /// baytı çok baytlı bir harfin içinde geçmez, bu yüzden karışıklıklar bayt bayt aranabilir.
    private static func forEachEdit(_ text: String, _ body: ([UInt8]) -> Void) {
        let canon = PackKey.canon(text)
        let scalars = Array(canon.unicodeScalars)
        guard scalars.count >= editLength.minimum, scalars.count <= editLength.maximum else { return }
        let bytes = Array(canon.utf8)
        // offsets[i]: i. harfin bayt konumu; offsets[count]: bayt sayısı.
        var offsets = [Int](repeating: bytes.count, count: scalars.count + 1)
        var position = 0
        for (index, scalar) in scalars.enumerated() {
            offsets[index] = position
            position += String(scalar).utf8.count
        }
        var buffer = [UInt8]()
        buffer.reserveCapacity(bytes.count + 8)
        for index in 0...scalars.count {
            let at = offsets[index]
            for letter in alphabet {
                buffer.removeAll(keepingCapacity: true)
                buffer.append(contentsOf: bytes[..<at])
                buffer.append(letter)
                buffer.append(contentsOf: bytes[at...])
                body(buffer)
            }
            guard index < scalars.count, scalars[index].isASCII else { continue }
            let next = offsets[index + 1]
            for letter in lookalikeBytes[Int(scalars[index].value)] {
                buffer.removeAll(keepingCapacity: true)
                buffer.append(contentsOf: bytes[..<at])
                buffer.append(letter)
                buffer.append(contentsOf: bytes[next...])
                body(buffer)
            }
        }
        guard scalars.count <= editLength.pairs else { return }
        for variant in variants(text) {
            let bytes = Array(variant.utf8)
            for index in bytes.indices {
                for (read, real) in confusionBytes where starts(bytes, at: index, with: read) {
                    buffer.removeAll(keepingCapacity: true)
                    buffer.append(contentsOf: bytes[..<index])
                    buffer.append(contentsOf: real)
                    buffer.append(contentsOf: bytes[(index + read.count)...])
                    body(buffer)
                }
            }
        }
    }

    private static let confusionBytes = confusions.map { (Array($0.read.utf8), Array($0.real.utf8)) }

    private static let confusionScalars = confusions.map { (Array($0.read.unicodeScalars), Array($0.real.unicodeScalars)) }

    /// `scalars`ın `index`ten başlayan kısmı `prefix` ile mi başlıyor.
    @inline(__always)
    private static func starts<T: Equatable>(_ scalars: [T], at index: Int, with prefix: [T]) -> Bool {
        guard index + prefix.count <= scalars.count else { return false }
        for offset in prefix.indices where scalars[index + offset] != prefix[offset] { return false }
        return true
    }

    /// canon metin, boşluksuz ve OCR'ın karıştırdığı harfler birleşmiş.
    static func folded(_ text: String) -> [Unicode.Scalar] {
        PackKey.canon(text).unicodeScalars.compactMap { $0 == " " ? nil : (fold[$0] ?? $0) }
    }

    /// Uzunluğa göre Bloom boyu (bit).
    static func bits(forLength length: Int) -> Int {
        var bits = 64
        while bits < maxBits, length * bitsPerGram > bits { bits *= 2 }
        return bits
    }

    static func trigramHashes(_ scalars: [Unicode.Scalar]) -> [UInt64] {
        guard scalars.count >= 3 else { return [] }
        var hashes = Set<UInt64>()
        for index in 0...(scalars.count - 3) {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for scalar in scalars[index..<(index + 3)] {
                for byte in String(scalar).utf8 {
                    hash ^= UInt64(byte)
                    hash = hash &* 0x0000_0100_0000_01b3
                }
            }
            hashes.insert(hash)
        }
        return Array(hashes)
    }

    static func bloom(_ hashes: [UInt64], bits: Int) -> [UInt64] {
        var words = [UInt64](repeating: 0, count: bits / 64)
        for hash in hashes {
            let bit = Int(hash & UInt64(bits - 1))
            words[bit >> 6] |= 1 << UInt64(bit & 63)
        }
        return words
    }

    /// İki yönlü, rastlantıdan arındırılmış kapsama (0-100): min(sorgunun üçlülerinin adayda olanı, adayınkinin sorguda
    /// olanı). `entry`: dizindeki kelimeler, `offset`ten başlayarak `bits / 64` tane.
    static func similarity(_ query: [UInt64], _ entry: [UInt64], offset: Int, bits: Int) -> Double {
        var both = 0, inQuery = 0, inEntry = 0
        for index in 0..<(bits / 64) {
            let q = query[index], e = entry[offset + index]
            both += (q & e).nonzeroBitCount
            inQuery += q.nonzeroBitCount
            inEntry += e.nonzeroBitCount
        }
        return score(both: both, inQuery: inQuery, inEntry: inEntry, bits: bits)
    }

    /// Kabul edilen bulanık adayda ortak bitler rastlantının en az bu kadar standart sapma üstünde olmalı
    /// (`evidence`). Kısa satırın 64 bitlik imzasında yüz binlerce aday arasında rastlantıyla eşiği geçen ilgisiz
    /// satır çıkıyordu ("No n0, the wealth was all Mother's." → "He could use some clothes.").
    static let minimumEvidence = 5.0
    /// OCR izi olmayan okumada tek yönlü kapsamada kısa tarafın adayda olmayan en çok bit sayısı: temiz okuma ya
    /// uzun satırın tam bir parçasıdır ya da başka bir satırdır ("You weren't supposed to see that." → "So that's
    /// the something you weren't supposed to see, huh?" değil).
    static let cleanMissing = 0

    /// Ortak bitlerin rastlantıya göre ne kadar fazla olduğu (standart sapma cinsinden), iki yönden: sorgunun bitleri
    /// adayın doluluğuyla ve adayın bitleri sorgunun doluluğuyla rastlantıda ne kadar örtüşürdü.
    static func evidence(both: Int, inQuery: Int, inEntry: Int, bits: Int) -> (query: Double, entry: Double) {
        let fillQuery = Double(inQuery) / Double(bits), fillEntry = Double(inEntry) / Double(bits)
        func z(_ count: Int, _ fill: Double) -> Double {
            let mean = Double(count) * fill, spread = (Double(count) * fill * (1 - fill)).squareRoot()
            return spread > 0 ? (Double(both) - mean) / spread : 0
        }
        return (z(inQuery, fillEntry), z(inEntry, fillQuery))
    }

    /// Benzerlik, bit sayılarından (ortak, sorgudaki, adaydaki).
    @inline(__always)
    static func score(both: Int, inQuery: Int, inEntry: Int, bits: Int) -> Double {
        let cover = coverage(both: both, inQuery: inQuery, inEntry: inEntry, bits: bits)
        return min(cover.query, cover.entry)
    }

    /// Rastlantıdan arındırılmış tek yönlü kapsamalar (0-100): sorgunun adayda olanı, adayın sorguda olanı.
    @inline(__always)
    static func coverage(both: Int, inQuery: Int, inEntry: Int, bits: Int) -> (query: Double, entry: Double) {
        guard inQuery > 0, inEntry > 0 else { return (0, 0) }
        let fillQuery = Double(inQuery) / Double(bits), fillEntry = Double(inEntry) / Double(bits)
        guard fillQuery < 1, fillEntry < 1 else { return (0, 0) }
        let queryCovered = (Double(both) / Double(inQuery) - fillEntry) / (1 - fillEntry)
        let entryCovered = (Double(both) / Double(inEntry) - fillQuery) / (1 - fillQuery)
        return (100.0 * queryCovered, 100.0 * entryCovered)
    }

    private static let clauseEnders = Set(".!?…,;:".unicodeScalars)
    /// Ardından küçük harf gelse de bölen işaretler (yan cümle).
    private static let clauseMarks = Set(",;:".unicodeScalars)
    private static let clauseClosers = Set("\"'”’)]".unicodeScalars)

    /// Satırın cümle ve yan cümleleri: . ! ? … (yinelenebilir, isteğe bağlı kapanış tırnağı ya da ayraç) ardından boşluk
    /// ve büyük harf, ya da , ; : … ve üç nokta ardından boşluk. Tek noktadan sonra küçük harfle süren yer ("seriously.
    /// nis seriously") bölünmez: OCR çöpüdür, ayrı cümle değil.
    static func clauses(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var output: [String] = []
        var begin = 0, index = 0
        func cut(_ end: Int) {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[begin..<end])
            let clause = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clause.isEmpty { output.append(clause) }
        }
        while index < scalars.count {
            guard clauseEnders.contains(scalars[index]) else { index += 1; continue }
            var end = index
            while end < scalars.count, clauseEnders.contains(scalars[end]) { end += 1 }
            while end < scalars.count, clauseClosers.contains(scalars[end]) { end += 1 }
            var next = end
            while next < scalars.count, scalars[next].properties.isWhitespace { next += 1 }
            // Üç nokta da küçük harfle süren yan cümleyi ayırır ("to escape... if we're able").
            let run = scalars[index..<end]
            let soft = run.contains { clauseMarks.contains($0) || $0 == "…" } || run.filter { $0 == "." }.count > 1
            if next > end, next < scalars.count, soft || scalars[next].properties.isUppercase {
                cut(end)
                begin = next
            }
            index = max(next, index + 1)
        }
        cut(scalars.count)
        // `sentenceCheck.letters` harften kısa yan cümle ("Bye," "Dad.") sonrakine (sonuncuysa öncekine) eklenir.
        var merged: [String] = []
        var pending = ""
        for clause in output {
            let joined = pending.isEmpty ? clause : pending + " " + clause
            if folded(joined).count < sentenceCheck.letters { pending = joined } else { merged.append(joined); pending = "" }
        }
        if !pending.isEmpty {
            if let last = merged.popLast() { merged.append(last + " " + pending) } else { merged.append(pending) }
        }
        return merged
    }

    /// Fazlalıklı okumanın denetlenecek yan cümleleri: her biri için üçlü kümesi seçenekleri (biri kısa adayda yeterince
    /// varsa yan cümle tamam). Köşe yazısına benzeyen yan cümle atlanır; ilk yan cümlenin başındaki ve sonuncunun
    /// sonundaki en çok üç büyük harfli sözcük ("Mirror Park Errr.", "… in a state Vinewood Hills") köşe yazısı olabilir,
    /// onlarsız hâli de seçenektir. Seçeneklerden biri `sentenceCheck.letters` harften kısaysa yan cümle denetlenmez.
    /// Okuma tek yan cümleyse boş.
    static func clauseHashes(_ text: String) -> [[[UInt64]]] {
        let parts = clauses(text)
        guard parts.count > 1 else { return [] }
        var output: [[[UInt64]]] = []
        for (position, part) in parts.enumerated() where !overlayLike(part) {
            let words = part.split(whereSeparator: \.isWhitespace)
            var options = [Substring](arrayLiteral: Substring(part))
            for count in 1...3 where count < words.count {
                if position == 0, words.prefix(count).allSatisfy(capitalized) {
                    options.append(Substring(words.dropFirst(count).joined(separator: " ")))
                }
                if position == parts.count - 1, words.suffix(count).allSatisfy(capitalized) {
                    options.append(Substring(words.dropLast(count).joined(separator: " ")))
                }
            }
            let folds = options.map { folded(String($0)) }
            guard folds.allSatisfy({ $0.count >= sentenceCheck.letters }) else { continue }
            output.append(folds.map(trigramHashes))
        }
        return output
    }

    /// Büyük harfle başlayan, yalnız harf ve rakamlı sözcük (köşe yazısı sözcüğü: "Vinewood", "LOSNN").
    static func capitalized(_ word: Substring) -> Bool {
        guard let first = word.unicodeScalars.first, first.properties.isUppercase else { return false }
        return word.unicodeScalars.allSatisfy { isLetter($0) || isDigit($0) }
    }

    /// Köşe yazısına benzeyen parça: "•" içerir ya da en çok dört sözcük, noktalama yok ve her sözcük büyük harfle
    /// başlar ("San Andreas", "First Person • zoom"). Fazlalık sayılır, cümle değil.
    static func overlayLike(_ text: String) -> Bool {
        if text.contains("•") { return true }
        let words = text.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.count <= 4 && words.allSatisfy(capitalized)
    }

    /// Her yan cümlenin seçeneklerinden birinin üçlülerinin en az `sentenceCheck.covered`'ı (rastlantıdan arındırılmış)
    /// adayın Bloom'unda mı. `entry`: adayın kelimeleri (`bits / 64` tane), `inEntry`: adaydaki 1 bit sayısı.
    static func coversClauses(_ clauses: [[[UInt64]]], entry: UnsafeBufferPointer<UInt64>, offset: Int, bits: Int,
                              inEntry: Int) -> Bool {
        let fill = Double(inEntry) / Double(bits)
        guard fill < 1 else { return false }
        func covered(_ hashes: [UInt64]) -> Bool {
            let words = bloom(hashes, bits: bits)
            var both = 0, inClause = 0
            for index in words.indices {
                both += (words[index] & entry[offset + index]).nonzeroBitCount
                inClause += words[index].nonzeroBitCount
            }
            guard inClause > 0 else { return true }
            return 100.0 * (Double(both) / Double(inClause) - fill) / (1 - fill) >= sentenceCheck.covered
        }
        return clauses.allSatisfy { $0.contains(where: covered) }
    }

    /// (uzunluk, Bloom baytları) — paket betiğinin yazdığıyla aynı; satır çok kısaysa nil.
    static func signature(_ text: String) -> (length: Int, bytes: [UInt8])? {
        let scalars = folded(text)
        guard scalars.count >= minLength else { return nil }
        let length = min(scalars.count, 255)
        let words = bloom(trigramHashes(scalars), bits: bits(forLength: length))
        return (length, words.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> UInt64($0 * 8)) } })
    }

    /// Kabul için en düşük benzerlik (0-100), OCR izine ve uzunluğa göre.
    static func required(length: Int, damaged: Bool) -> Double {
        let table = damaged ? damagedMinimum : cleanMinimum
        return table.first { length < $0.limit }?.value ?? table[table.count - 1].value
    }

    private static let edge = Set(".,!?;:'\"()[]-…“”’‘".unicodeScalars)
    private static let typographic = Set("’‘“”—–…".unicodeScalars)

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.numericType == .decimal || scalar.properties.numericType == .digit
    }

    /// OCR izi: İngilizce satırda ASCII dışı harf ya da işaret, sözcük içinde harf olmayan işaret ya da rakam, tek harfli
    /// garip sözcük, çok uzun (birleşmiş) sözcük. İzi olmayan satırın neredeyse aynı olması gerekir: temiz ama pakette
    /// olmayan satır büyük olasılıkla başka bir satırdır.
    static func damaged(_ text: String) -> Bool {
        if text.unicodeScalars.contains(where: { $0.value > 127 && !typographic.contains($0) }) { return true }
        for word in text.split(whereSeparator: \.isWhitespace) {
            var core = Array(word.unicodeScalars)
            while let first = core.first, edge.contains(first) { core.removeFirst() }
            while let last = core.last, edge.contains(last) { core.removeLast() }
            guard !core.isEmpty else { continue }
            if core.count >= 3 {
                for index in 1..<(core.count - 1)
                    where isLetter(core[index - 1]) && isLetter(core[index + 1]) && !isLetter(core[index])
                    && !"'’-".unicodeScalars.contains(core[index]) {
                    return true
                }
            }
            for index in core.indices.dropFirst() {
                let previous = core[index - 1], current = core[index]
                if (isLetter(previous) && isDigit(current)) || (isDigit(previous) && isLetter(current)) { return true }
            }
            if core.count == 1, isLetter(core[0]), !"aAIoO".unicodeScalars.contains(core[0]) { return true }
            if core.count > 14 { return true }
        }
        return false
    }
}


/// Bir paketin bulanık dizini: imzalı satırlar uzunluğa göre sıralı (aynı uzunlukta anahtar sırasıyla), Bloom
/// kelimeleri ardışık, her satırın bit sayısı önceden sayılmış.
struct PackFuzzyIndex: Sendable {
    private let lengths: [UInt8]
    private let keys: [UInt64]
    private let offsets: [Int32]
    private let ones: [UInt16]
    private let words: [UInt64]
    /// `start[n]`: uzunluğu n olan ilk satırın sırası.
    private let start: [Int]

    var count: Int { keys.count }

    /// Paketteki "fuzzy" nesnesi. `order`: paketteki bütün anahtarlar (entries + segments) sayı sırasıyla.
    /// Biçim tutmazsa nil (paket yine de tam eşleşmeyle çalışır).
    init?(json: [String: Any], order: [UInt64]) {
        guard json["version"] as? Int == 1, json["count"] as? Int == order.count,
              let mask = (json["mask"] as? String).flatMap({ Data(base64Encoded: $0) }).map([UInt8].init),
              let lengthBytes = (json["lengths"] as? String).flatMap({ Data(base64Encoded: $0) }).map([UInt8].init),
              let blooms = (json["blooms"] as? String).flatMap({ Data(base64Encoded: $0) }),
              mask.count == (order.count + 7) / 8 else { return nil }
        // Dosyadaki sıra: imzalı anahtarlar sayı sırasıyla, Bloom'ları ardışık.
        let total = lengthBytes.count
        var fileKeys = [UInt64](repeating: 0, count: total)
        var fileOffsets = [Int](repeating: 0, count: total)
        var signed = 0, byteOffset = 0
        for index in order.indices where mask[index >> 3] >> UInt8(index & 7) & 1 == 1 {
            guard signed < total else { return nil }
            fileKeys[signed] = order[index]
            fileOffsets[signed] = byteOffset
            byteOffset += PackFuzzy.bits(forLength: Int(lengthBytes[signed])) / 8
            signed += 1
        }
        guard signed == total, byteOffset == blooms.count else { return nil }
        // Uzunluğa göre sayarak sırala (aynı uzunlukta anahtar sırası korunur).
        var start = [Int](repeating: 0, count: 257)
        for length in lengthBytes { start[Int(length) + 1] += 1 }
        for length in 1...256 { start[length] += start[length - 1] }
        var next = start
        var lengths = [UInt8](repeating: 0, count: total)
        var keys = [UInt64](repeating: 0, count: total)
        var offsets = [Int32](repeating: 0, count: total)
        var ones = [UInt16](repeating: 0, count: total)
        var words = [UInt64](repeating: 0, count: blooms.count / 8)
        // source[yeni sıra] = dosyadaki sıra
        var source = [Int](repeating: 0, count: total)
        for item in 0..<total {
            let length = Int(lengthBytes[item])
            source[next[length]] = item
            next[length] += 1
        }
        var wordOffset = 0
        blooms.withUnsafeBytes { raw in
            for position in 0..<total {
                let item = source[position]
                let length = lengthBytes[item]
                let count = PackFuzzy.bits(forLength: Int(length)) / 64
                lengths[position] = length
                keys[position] = fileKeys[item]
                offsets[position] = Int32(wordOffset)
                var bits = 0
                for word in 0..<count {
                    let value = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: fileOffsets[item] + word * 8, as: UInt64.self))
                    words[wordOffset + word] = value
                    bits += value.nonzeroBitCount
                }
                ones[position] = UInt16(bits)
                wordOffset += count
            }
        }
        self.lengths = lengths
        self.keys = keys
        self.offsets = offsets
        self.ones = ones
        self.words = words
        self.start = start
    }

    /// Eşik, uzunluk ve ikinci aday şartlarını sağlayan en benzer satırın anahtarı; yoksa nil.
    /// `translation`: anahtarın Türkçesi (aynı Türkçeli iki aday birbirinin rakibi sayılmaz).
    /// Önce boyu yakın adaylar (benzerlik iki yönlü kapsamanın küçüğü). Hiçbiri eşiği geçmezse boyu çok farklı adaylarda
    /// tek yönlü kapsamaya bakılır (`PackFuzzy.containment`): yarım okunan satır (iki satırlık altyazının bir satırı)
    /// uzun adayın içinde, köşe yazısı ya da çöp eklenmiş okuma kısa adayın dışında kalır.
    func nearest(_ text: String, translation: (UInt64) -> String?) -> UInt64? {
        let scalars = PackFuzzy.folded(text)
        guard scalars.count >= PackFuzzy.minLength, !keys.isEmpty else { return nil }
        let length = min(scalars.count, 255)
        let damaged = PackFuzzy.damaged(text)
        let floor = PackFuzzy.required(length: length, damaged: damaged) - PackFuzzy.margin
        let need = floor + PackFuzzy.margin
        let hashes = PackFuzzy.trigramHashes(scalars)
        // Sorgunun üç boydaki Bloom'u yan yana: 64 bit [0], 128 bit [1, 2], 256 bit [3...6].
        let query = PackFuzzy.bloom(hashes, bits: 64) + PackFuzzy.bloom(hashes, bits: 128) + PackFuzzy.bloom(hashes, bits: 256)
        let queryOnes = [query[0].nonzeroBitCount, query[1].nonzeroBitCount + query[2].nonzeroBitCount,
                         query[3...6].reduce(0) { $0 + $1.nonzeroBitCount }]
        let contain = PackFuzzy.containment
        // İki yönlü aday: boyu en çok ±%25 farklı (|aday - satır| * 4 <= satır); benzerlik kapsamaların küçüğü.
        let near = (length - length / 4)...min(255, length + length / 4)
        // Tek yönlü aday: satırın 11/20'si ile 5/2'si arası (fazlalıklı okumada aday satırın en az %55'i kadar olur);
        // kısa taraf en az `inner` kapsanmalı, uzun tarafın en az `partial`/`extra`'sı kısa tarafta; benzerlik
        // `inner - penalty`.
        let wide = length >= contain.minLength
            ? max(contain.minLength, length * 11 / 20)...min(255, length * 5 / 2) : near
        var close: [(score: Double, key: UInt64, z: Double)] = []
        var contained: [(score: Double, key: UInt64, z: Double)] = []
        /// Okumanın yan cümle üçlüleri (`PackFuzzy.clauseHashes`); ilk fazlalıklı adayda hesaplanır.
        var clauses: [[[UInt64]]]?
        let nearLower = near.lowerBound, nearUpper = near.upperBound
        let one = queryOnes[0], two = queryOnes[1], four = queryOnes[2]
        /// `range` sırasındaki adaylar: `wideOn` false ise iki yönlü benzerlik (`close`), true ise tek yönlü (`contained`).
        /// Hata ayıklama derlemesinde de hızlı olsun diye diziler doğrudan okunur.
        func scan(_ range: Range<Int>, wideOn: Bool) {
        query.withUnsafeBufferPointer { q in
        words.withUnsafeBufferPointer { w in
        lengths.withUnsafeBufferPointer { lengths in
        offsets.withUnsafeBufferPointer { offsets in
        ones.withUnsafeBufferPointer { ones in
            for index in range {
                let entryLength = Int(lengths[index])
                let base = Int(offsets[index])
                let bits: Int, inQuery: Int, both: Int
                if entryLength * PackFuzzy.bitsPerGram <= 64 {
                    bits = 64; inQuery = one
                    both = (q[0] & w[base]).nonzeroBitCount
                } else if entryLength * PackFuzzy.bitsPerGram <= 128 {
                    bits = 128; inQuery = two
                    both = (q[1] & w[base]).nonzeroBitCount + (q[2] & w[base + 1]).nonzeroBitCount
                } else {
                    bits = 256; inQuery = four
                    both = (q[3] & w[base]).nonzeroBitCount + (q[4] & w[base + 1]).nonzeroBitCount
                        + (q[5] & w[base + 2]).nonzeroBitCount + (q[6] & w[base + 3]).nonzeroBitCount
                }
                let inEntry = Int(ones[index])
                if !wideOn {
                    let score = PackFuzzy.score(both: both, inQuery: inQuery, inEntry: inEntry, bits: bits)
                    if score >= floor {
                        let z = PackFuzzy.evidence(both: both, inQuery: inQuery, inEntry: inEntry, bits: bits)
                        close.append((score, keys[index], min(z.query, z.entry)))
                    }
                    continue
                }
                // Kısa tarafın bitlerinin en az %90'ı ortak olmalı (hızlı eleme).
                guard entryLength >= contain.minLength, entryLength != length,
                      both * 10 >= 9 * (entryLength > length ? inQuery : inEntry) else { continue }
                let cover = PackFuzzy.coverage(both: both, inQuery: inQuery, inEntry: inEntry, bits: bits)
                let (inner, outer, least) = entryLength > length
                    ? (cover.query, cover.entry, contain.partial) : (cover.entry, cover.query, contain.extra)
                guard inner >= contain.inner, outer >= least, inner - contain.penalty >= floor else { continue }
                // OCR izi olmayan okuma adayın içindeyse (ya da aday okumanın içindeyse) kısa tarafın bitlerinin
                // hepsi ortak olmalı: temiz okuma ya tam parçadır ya da başka bir satırdır.
                if !damaged, (entryLength > length ? inQuery : inEntry) - both > PackFuzzy.cleanMissing { continue }
                // Fazlalıklı okumada her yan cümle adayda olmalı: ikinci bir altyazının cümlesi fazlalık sayılmaz.
                if entryLength < length {
                    if clauses == nil { clauses = PackFuzzy.clauseHashes(text) }
                    if let clauses, !clauses.isEmpty,
                       !PackFuzzy.coversClauses(clauses, entry: w, offset: base, bits: bits, inEntry: inEntry) { continue }
                }
                let z = PackFuzzy.evidence(both: both, inQuery: inQuery, inEntry: inEntry, bits: bits)
                contained.append((inner - contain.penalty, keys[index], entryLength > length ? z.query : z.entry))
            }
        }
        }
        }
        }
        }
        }
        /// En iyi aday; eşiği geçmiyorsa nil, Türkçesi farklı rakibi yakınsa `.ambiguous`.
        func pick(_ found: [(score: Double, key: UInt64, z: Double)]) -> (key: UInt64?, ambiguous: Bool) {
            guard let best = found.max(by: { ($0.score, $0.key) < ($1.score, $1.key) }), best.score >= need else { return (nil, false) }
            guard best.z >= PackFuzzy.minimumEvidence else { return (nil, true) }
            let turkish = translation(best.key)
            for other in found where other.key != best.key && other.score > best.score - PackFuzzy.margin
                && translation(other.key) != turkish {
                return (nil, true)
            }
            return (best.key, false)
        }
        scan(start[nearLower]..<start[nearUpper + 1], wideOn: false)
        // Tek yönlü adaylara yalnız iki yönlü hiçbir aday eşiği geçmediyse bakılır.
        let first = pick(close)
        guard first.key == nil, !first.ambiguous, length >= contain.minLength else { return first.key }
        scan(start[wide.lowerBound]..<start[wide.upperBound + 1], wideOn: true)
        return contained.isEmpty ? nil : pick(close + contained).key
    }
}
