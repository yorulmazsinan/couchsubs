// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Oyun ipuçlarının içindeki kumanda simgeleri ("Hold △ to sprint", "Use 🕹 to move the camera"). Yazı tanıma simgeyi
/// okuyamaz: harf sanır ("Hold A to sprint", "PressÄ to open", "Useo to move") ya da yerinde boşluk bırakır. Çevirmen
/// o harfi atınca TV'deki çeviri simgeyi de örtüyor, Türkçede yalnız "basılı tut" kalıyordu; neye basılacağı
/// görünmüyordu. Burada simge satırın içinde bulunur (`mark`), kareden kesilir (`crop`) ve çeviride yeri korunarak
/// (`IconText`) TV'ye resim olarak gider (Windows: ButtonIcons.cs, aynı kurallar).
public enum ButtonIcons {
    /// Okunan metinde simgenin yeri; satırın `TextLine.icons` listesindeki sıradaki simgedir.
    public static let marker: Character = "\u{FFFC}"
    static let markerScalar: Unicode.Scalar = "\u{FFFC}"

    /// Simgeden önce gelen fiiller: "Press △", "Hold R2", "Use ◎" (küçük harfle karşılaştırılır).
    private static let verbs: Set<String> = [
        "press", "hold", "tap", "push", "use", "mash", "release", "click", "hit", "pressing", "holding", "tapping", "using",
    ]

    /// İki simgeyi bağlayanlar: "Press △ or ○", "Hold L1 + R1".
    private static let joiners: Set<String> = ["and", "or", "+", "/", "then"]

    /// Düğme adları ve simgeleri; harf olarak okunsalar da simgedirler (büyük harfle karşılaştırılır).
    private static let names: Set<String> = [
        "R1", "R2", "R3", "L1", "L2", "L3", "RB", "LB", "RT", "LT", "LS", "RS", "ZL", "ZR",
        "✕", "×", "⨯", "✖", "○", "◯", "●", "□", "▢", "◻", "■", "△", "▲", "⨂",
    ]

    /// Fiile yapışık okunan simgeden sonra gelemeyecek harfler: "Uses", "Used", "User", "Pushy", "Tape" sözcüktür.
    private static let inflections = "sdeyr"

    private static let brackets = "()[]{}<>「」\"'“”‘’"
    private static let punctuation = ".,;:!?…"

    /// Satırdaki simgeleri `marker` ile işaretler ve yerlerini `TextLine.icons`'a yazar. Simge yalnız ipucu kalıbında
    /// aranır, konuşma bozulmasın: bir fiilin ("press", "hold", "use"...) ya da bir simgeden sonra gelen "and/or/+"
    /// bağlacının ardındaki (1) tek harf/simge ya da düğme adı ("A", "Ä", "©", "R2"), (2) fiile yapışık tek harf
    /// ("PressÄ", "Useo") ve (3) fiilden sonraki, birkaç harf genişliğindeki boşluk (simge hiç okunmamış). Simgeyi
    /// tanıyan okuyucunun yazdığı simge karakteri ("Hold △ to sprint") ya da düğme adı da simgedir; işaretlenen satır
    /// kumanda ipucu sayılıp atılmaz, simgesiyle çevrilir. Satır başı/sonundaki simge ("R2 Swing", "△ Pick up")
    /// işaretlenmez: bu kısa ipuçları bilerek hiç çevrilmez (ek alanda sürekli gelip gider), üstleri de örtülmez.
    /// Okuyucu sözcük yerlerini vermiyorsa yerler satırın içinde harf sayısına göre kestirilir; o zaman boşluk aranmaz.
    /// Simge yoksa satır olduğu gibi döner.
    public static func mark(_ line: TextLine) -> TextLine {
        guard let lineBox = line.box, (line.icons ?? []).isEmpty else { return line }
        let measured = !(line.words ?? []).isEmpty
        let words = measured ? line.words! : estimate(line.text, lineBox)
        guard !words.isEmpty else { return line }
        let charWidth = averageCharWidth(words)
        var tokens: [String] = []
        var icons: [IconSlot] = []
        var isIcon = [Bool](repeating: false, count: words.count)
        let top = lineBox.top, bottom = lineBox.bottom, pad = (lineBox.bottom - lineBox.top) * 0.3
        // (0) Tuş kalıntısı kalıbı (ButtonPrompts.isIconPrompt, GTA 6 havuzu): "Hold I LI to", "Press (9 0 to",
        // "Release 2 and R2 to". Bağlaçsız art arda kalıntılar tek simgenin parçalarıdır; bağlaç iki simgeyi ayırır.
        let span = ButtonPrompts.iconRemnantSpan(words.map(\.text), line: line.text)
        var skipThrough = -1

        for i in words.indices {
            if i <= skipThrough { continue }
            let word = words[i]
            if let span, i > span.verb, i < span.to {
                if ButtonPrompts.isConnector(trimming(word.text, brackets)) {
                    tokens.append(word.text)
                    continue
                }
                var last = i
                while last + 1 < span.to && !ButtonPrompts.isConnector(trimming(words[last + 1].text, brackets)) { last += 1 }
                let left = min(word.box.left, (words[i - 1].box.right + word.box.left) / 2)
                let right = max(words[last].box.right, (words[last].box.right + words[last + 1].box.left) / 2)
                tokens.append(String(marker))
                icons.append(IconSlot(box: TextBox(left: left, top: top - pad, right: right, bottom: bottom + pad),
                                      text: words[i...last].map(\.text).joined(separator: " ")))
                for k in i...last { isIcon[k] = true }
                skipThrough = last
                continue
            }
            let previous = i > 0 ? letters(words[i - 1].text) : ""
            let afterVerb = i > 0 && verbs.contains(previous.lowercased())
            let joiner = i > 0 && joiners.contains(trimming(words[i - 1].text, brackets).lowercased())
            // "Press △ or ○", ya da fiil önceden geçmiş: "Use ◎ to move the camera and △ to interact".
            let afterJoinedIcon = joiner && ((i > 1 && isIcon[i - 2])
                                             || (i + 1 < words.count && words[i + 1].text.lowercased() == "to"))

            // (3) Fiil ile bu sözcük arasında okunmamış simge: boşluk birkaç harf genişliğinde.
            if measured && afterVerb && !isIconToken(word.text) && word.box.left - words[i - 1].box.right >= charWidth * 2.5 {
                tokens.append(String(marker))
                // Sözcük kenarları yaklaşık olabilir: iki yana birer harf payı; kutuya giren harf kırıntıları kırpılırken atılır.
                icons.append(IconSlot(box: TextBox(left: words[i - 1].box.right - charWidth, top: top - pad,
                                                   right: word.box.left + charWidth, bottom: bottom + pad), text: ""))
                tokens.append(word.text)
                continue
            }
            // (1) Simgenin okunduğu harf ya da düğme adı.
            if (afterVerb || afterJoinedIcon) && isIconToken(word.text) {
                isIcon[i] = true
                // Komşu sözcükle arasındaki boşluğun ortasına kadar; kutular üst üste biniyorsa (gelişmiş yazı tanıma
                // kutuları geniş tutar) sözcüğün kendi kutusu küçülmez.
                let width = word.box.right - word.box.left
                let left = min(word.box.left, i > 0 ? (words[i - 1].box.right + word.box.left) / 2 : word.box.left - width / 2)
                let right = max(word.box.right, i + 1 < words.count ? (word.box.right + words[i + 1].box.left) / 2
                                                                     : word.box.right + width / 2)
                let (read, trail) = splitTrailingPunctuation(word.text)
                tokens.append(String(marker) + trail)
                icons.append(IconSlot(box: TextBox(left: left, top: top - pad, right: right, bottom: bottom + pad), text: read))
                continue
            }
            // (2) Fiile yapışık simge: "PressÄ", "Useo".
            if let glued = gluedVerb(word.text) {
                isIcon[i] = true
                // Simge harften geniştir; kesim fiilin son harfinden başlar, fazlası kırpılırken atılır.
                let split = min(word.box.right, word.box.left + Double(glued.verb.utf16.count - 1) * charWidth)
                let right = i + 1 < words.count ? (word.box.right + words[i + 1].box.left) / 2 : word.box.right
                tokens.append(glued.verb)
                tokens.append(String(marker))
                icons.append(IconSlot(box: TextBox(left: split, top: top - pad, right: right, bottom: bottom + pad), text: glued.icon))
                continue
            }
            tokens.append(word.text)
        }
        guard !icons.isEmpty else { return line }
        var marked = line
        marked.text = tokens.joined(separator: " ")
        marked.words = nil
        marked.icons = icons
        return marked
    }

    /// Gelişmiş yazı tanıma ipucu satırını simgenin olduğu yerden bölebilir: "Press" | "R2" | "to open the weapon wheel."
    /// ayrı satırlar olunca cümle ikiye bölünüp çevriliyordu. Aynı sırada yan yana duran (aralarında en çok
    /// `Reading.rowGap`) ve ipucu kalıbını sürdüren parçalar tek satır olur: soldaki parça fiille ya da fiilden sonraki
    /// simgeyle biter, ya da sağdaki parça "and/or"dan sonra gelen tek simgedir. Sözcük yerleri korunur.
    public static func joinHints(_ reading: Reading) -> Reading {
        guard reading.lines.count >= 2, reading.lines.allSatisfy({ $0.box != nil }) else { return reading }
        var pieces = reading.lines
        var joined = true
        while joined {
            joined = false
            search: for a in pieces.indices {
                for b in pieces.indices where a != b && continues(pieces[a], pieces[b]) {
                    let left = pieces[a], right = pieces[b]
                    let confidence = [left.confidence, right.confidence].compactMap { $0 }.min()
                    let words = (left.words ?? estimate(left.text, left.box!)) + (right.words ?? estimate(right.text, right.box!))
                    pieces[a] = TextLine(left.text + " " + right.text, box: left.box!.union(right.box!), confidence: confidence,
                                         words: words)
                    pieces.remove(at: b)
                    joined = true
                    break search
                }
            }
        }
        return pieces.count == reading.lines.count ? reading : Reading(lines: pieces.sorted { $0.box!.top < $1.box!.top })
    }

    /// `right`, `left`'in hemen sağında aynı sırada ve ipucu ondan sürüyor.
    private static func continues(_ left: TextLine, _ right: TextLine) -> Bool {
        let a = left.box!, b = right.box!
        let overlap = min(a.bottom, b.bottom) - max(a.top, b.top)
        let smaller = min(a.bottom - a.top, b.bottom - b.top)
        guard smaller > 0, overlap >= smaller * 0.6, b.left > a.left, b.left - a.right <= Reading.rowGap else { return false }
        let first = left.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let second = right.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = first.last, let next = second.first else { return false }
        if verbs.contains(letters(last).lowercased()) { return true }
        if first.count >= 2, isIconToken(last) {
            let before = first[first.count - 2]
            if verbs.contains(letters(before).lowercased()) || joiners.contains(before.lowercased()) { return true }
        }
        return second.count == 1 && isIconToken(next) && joiners.contains(last.lowercased())
    }

    /// Tek harf/simge (küçük "a" ve "I" dışında: sözcüktürler) ya da düğme adı; çevresindeki parantez ve noktalama
    /// sayılmaz. Uzunluk Windows'taki gibi UTF-16 birimiyle ölçülür.
    /// Sözcük bir kumanda tuşunun adı ya da simgesi mi ("R3", "(L1)", "△").
    static func isButtonName(_ text: String) -> Bool { names.contains(trimming(text, brackets).uppercased()) }

    /// Renkli zeminde (kutu kenarının ortancası) her kanalda zemine bu kadar yakın nokta zemindir, simge sayılmaz.
    static let baseTolerance = 40

    /// Kutudaki parlak piksellerin çoğu renksiz mi (kumanda simgesi beyaz/gri; portre, harita renkli).
    static func isColourless(_ frame: CGImage, _ box: TextBox) -> Bool {
        let rect = GamePhonePixels.rect(box, in: frame)
        guard let pixels = GamePhonePixels(frame, in: rect), pixels.width >= 2, pixels.height >= 2 else { return false }
        // Zemin: kutunun kenarındaki noktaların ortancası. Beyaz simgenin kenarı zeminle karışır (mavi haritada mavimsi);
        // zeminle beyaz arasındaki karışım renkli sayılmaz (#860: GTA 6 haritasında L3/R3 simgesi tanınmıyordu).
        var edge: [(Int, Int, Int)] = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where y == 0 || y == pixels.height - 1 || x == 0 || x == pixels.width - 1 {
                let i = (y * pixels.width + x) * 4
                edge.append((Int(pixels.bytes[i]), Int(pixels.bytes[i + 1]), Int(pixels.bytes[i + 2])))
            }
        }
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        let base = (median(edge.map(\.0)), median(edge.map(\.1)), median(edge.map(\.2)))
        let baseLuma = (299 * base.0 + 587 * base.1 + 114 * base.2) / 1000
        let colourfulBase = max(base.0, base.1, base.2) - min(base.0, base.1, base.2) > 60
        var bright = 0, coloured = 0
        for i in stride(from: 0, to: pixels.bytes.count, by: 4) {
            let r = Int(pixels.bytes[i]), g = Int(pixels.bytes[i + 1]), b = Int(pixels.bytes[i + 2])
            let luma = (299 * r + 587 * g + 114 * b) / 1000
            // Zeminin kendisi simgenin parçası değildir: parlak renkli zeminde (GTA 6 haritasının açık mavi denizi) zemin
            // noktaları renkli sayılıyor, haritadaki ✕/○ simgesi tanınmayıp çeviri kutusuna giriyordu.
            if colourfulBase, max(abs(r - base.0), abs(g - base.1), abs(b - base.2)) <= baseTolerance { continue }
            if luma < 110 { continue }
            bright += 1
            guard max(r, g, b) - min(r, g, b) > 60 else { continue }
            // Zeminle beyazın karışımı mı: karışım oranı parlaklıktan, beklenen renk ondan. Yalnız koyu zeminde (kenarı
            // parlak renkle dolu kutu simge değil, resimdir: portre kutuyu kenarına kadar doldurur).
            guard baseLuma < 110 else { coloured += 1; continue }
            let share = baseLuma >= 250 ? 1.0 : max(0, min(1, Double(luma - baseLuma) / Double(255 - baseLuma)))
            let expected = [base.0, base.1, base.2].map { Double($0) * (1 - share) + 255 * share }
            let distance = zip([r, g, b].map(Double.init), expected).map { abs($0 - $1) }.max()!
            if distance > 60 { coloured += 1 }
        }
        return bright > 0 && coloured * 4 < bright
    }

    static func isIconToken(_ text: String) -> Bool {
        let core = trimming(trimming(trimming(text, brackets), punctuation, leading: false), brackets)
        if names.contains(core.uppercased()) { return true }
        guard core.utf16.count == 1, let c = core.unicodeScalars.first else { return false }
        if c.properties.generalCategory == .decimalNumber || "aI-–—&".unicodeScalars.contains(c) { return false }
        return c.properties.generalCategory == .uppercaseLetter || c == "o" || c == "x" || !isLetter(c)
    }

    /// Fiile yapışmış tek harf ("PressÄ" → "Press", "Ä"); değilse nil.
    private static func gluedVerb(_ text: String) -> (verb: String, icon: String)? {
        guard text.utf16.count >= 4, let last = text.unicodeScalars.last, last.value <= 0xFFFF else { return nil }
        var scalars = text.unicodeScalars
        scalars.removeLast()
        let verb = String(scalars)
        guard verbs.contains(verb.lowercased()), verb.unicodeScalars.allSatisfy(isLetter) else { return nil }
        if last.properties.generalCategory == .lowercaseLetter && inflections.unicodeScalars.contains(last) { return nil }
        return isLetter(last) || !isPunctuation(last) ? (verb, String(Character(last))) : nil
    }

    /// Sözcüğün sonundaki noktalama ayrılır ("A." → "A", "."); tek karakter kalır.
    private static func splitTrailingPunctuation(_ text: String) -> (String, String) {
        var characters = Array(text)
        var trail: [Character] = []
        while characters.count > 1, let last = characters.last, punctuation.contains(last) {
            trail.insert(last, at: 0)
            characters.removeLast()
        }
        return (String(characters), String(trail))
    }

    /// Baştaki (istenirse) ve sondaki, `set` içindeki karakterler atılır.
    private static func trimming(_ text: String, _ set: String, leading: Bool = true) -> String {
        var rest = Substring(text)
        if leading { while let c = rest.first, set.contains(c) { rest = rest.dropFirst() } }
        while let c = rest.last, set.contains(c) { rest = rest.dropLast() }
        return String(rest)
    }

    private static func letters(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where isLetter(scalar) { result.append(scalar) }
        return String(result)
    }

    /// .NET'teki `char.IsLetter` gibi: yalnız harf sınıfları.
    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// .NET'teki `char.IsPunctuation` gibi.
    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    /// Yeri bilinen sözcüklerin harf başına ortalama genişliği (alan genişliğine oranla).
    private static func averageCharWidth(_ words: [TextWord]) -> Double {
        var normal = words.filter { $0.text.utf16.count >= 2 && !isIconToken($0.text) }
        if normal.isEmpty { normal = words }
        let chars = normal.reduce(0) { $0 + $1.text.utf16.count }
        guard chars > 0 else { return 0 }
        return normal.reduce(0.0) { $0 + ($1.box.right - $1.box.left) } / Double(chars)
    }

    /// Sözcük yerleri bilinmiyorsa satırın kutusu harf sayısına göre paylaştırılır.
    static func estimate(_ text: String, _ box: TextBox) -> [TextWord] {
        let units = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf16)
        guard !units.isEmpty else { return [] }
        let width = (box.right - box.left) / Double(units.count)
        var result: [TextWord] = []
        var start = 0
        for i in 0...units.count {
            if i < units.count && units[i] != 0x20 { continue }
            if i > start {
                result.append(TextWord(String(decoding: units[start..<i], as: UTF16.self),
                                       box: TextBox(left: box.left + Double(start) * width, top: box.top,
                                                    right: box.left + Double(i) * width, bottom: box.bottom)))
            }
            start = i + 1
        }
        return result
    }

    // MARK: - Kesme

    /// Simgeyi kareden keser ve PNG (data: adresi) olarak verir; bulunamazsa nil. Kutu kabacadır (simgenin okunduğu
    /// harf simgeden dar, kestirilen yer kayık olabilir): içindeki zeminden ayrışan pikseller bitişik kümelere ayrılır,
    /// kutunun ortasındaki en büyük küme simgedir ve sıkıca kırpılır. `frame`, kutunun oranlandığı karedir.
    public static func crop(_ frame: CGImage, _ box: TextBox) -> String? {
        guard let icon = locate(frame, box) else { return nil }
        let data = png(icon.pixels, stride: icon.stride, x: icon.x, y: icon.y, width: icon.width, height: icon.height)
        return "data:image/png;base64," + data.base64EncodedString()
    }

    private struct LocatedIcon {
        let pixels: [UInt8]
        let stride, x, y, width, height, inkWidth, inkHeight: Int
    }

    private static func locate(_ frame: CGImage, _ box: TextBox) -> LocatedIcon? {
        guard box.left.isFinite, box.top.isFinite, box.right.isFinite, box.bottom.isFinite else { return nil }
        let frameWidth = frame.width, frameHeight = frame.height
        let clamp = { (value: Double, limit: Int) -> Int in Int(max(0, min(Double(limit), value))) }
        let x0 = clamp((box.left * Double(frameWidth)).rounded(.down), frameWidth)
        let x1 = clamp((box.right * Double(frameWidth)).rounded(.up), frameWidth)
        let y0 = clamp((box.top * Double(frameHeight)).rounded(.down), frameHeight)
        let y1 = clamp((box.bottom * Double(frameHeight)).rounded(.up), frameHeight)
        let width = x1 - x0, height = y1 - y0
        guard width >= 4, height >= 6 else { return nil }

        // Kutu ve çevresindeki kırpma payı tek seferde okunur (bütün kare çizilmez).
        let margin = 2
        let readLeft = max(0, x0 - margin), readTop = max(0, y0 - margin)
        let readWidth = min(frameWidth, x1 + margin) - readLeft, readHeight = min(frameHeight, y1 + margin) - readTop
        guard let pixels = rgba(frame, x: readLeft, y: readTop, width: readWidth, height: readHeight) else { return nil }
        let stride = readWidth * 4
        let offsetX = x0 - readLeft, offsetY = y0 - readTop
        let at = { (x: Int, y: Int) -> Int in (offsetY + y) * stride + (offsetX + x) * 4 }

        let background = borderMedian(pixels, stride: stride, offsetX: offsetX, offsetY: offsetY, width: width, height: height)
        var ink = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = at(x, y)
                let distance = abs(Int(pixels[i]) - background.r) + abs(Int(pixels[i + 1]) - background.g)
                    + abs(Int(pixels[i + 2]) - background.b)
                ink[y * width + x] = distance > 90
            }
        }

        // Bitişik piksel kümeleri: simge genellikle kutudaki en büyük kümedir; kutuya taşan komşu harfler ("Use|o")
        // ayrı küçük kümelerdir. Ana kümenin içine düşen kümeler (halkanın içindeki △, düğmenin üstündeki "R2") simgeye katılır.
        let found = components(ink, width: width, height: height)
        let central = found.filter {
            Double($0.left + $0.right) / 2 >= Double(width) * 0.1 && Double($0.left + $0.right) / 2 <= Double(width) * 0.9
        }
        guard let main = central.max(by: { $0.area < $1.area }) else { return nil }
        var start = main.left, end = main.right, top = main.top, bottom = main.bottom
        let padX = Double(end - start) * 0.15, padY = Double(bottom - top) * 0.15
        for c in found where Double(c.left) >= Double(start) - padX && Double(c.right) <= Double(end) + padX
            && Double(c.top) >= Double(top) - padY && Double(c.bottom) <= Double(bottom) + padY {
            start = min(start, c.left)
            end = max(end, c.right)
            top = min(top, c.top)
            bottom = max(bottom, c.bottom)
        }
        // Simge satır yüksekliğinin en az üçte biri kadardır; daha küçüğü kir ya da harf kırıntısıdır.
        guard Double(bottom - top) >= Double(height) * 0.3, end - start >= 3 else { return nil }

        let left = max(0, x0 + start - margin)
        let right = min(frameWidth, x0 + end + margin)
        let cropTop = max(0, y0 + top - margin)
        let cropBottom = min(frameHeight, y0 + bottom + margin)
        return LocatedIcon(pixels: pixels, stride: stride, x: left - readLeft, y: cropTop - readTop,
                           width: right - left, height: cropBottom - cropTop, inkWidth: end - start, inkHeight: bottom - top)
    }

    /// Ek alanlardaki tuş çubuklarında ve satır uçlarında yalnız kareden doğrulanan simgeler işaretlenir.
    /// Windows ButtonIcons.MarkFree ile aynı kurallar (GameTranslator ve Nino Game Translator, bkz. THIRD-PARTY-NOTICES.md).
    /// `monochrome`: otomatik bulunan ekran yazısında yalnız renksiz (beyaz/gri) ve satır yüksekliğinin en az %60'ı
    /// kadar simgeler kabul edilir; satırın solundaki menü simgesi çeviriye taşınmaz (kutu simgeden sonra başlar).
    /// Görev kutusundaki portre ve harita parçası simge sanılıp çevirinin içine kesiliyordu (gerçek kare doğrulaması).
    static func markFree(_ line: TextLine, frame: CGImage, monochrome: Bool = false) -> TextLine {
        guard let lineBox = line.box, (line.icons ?? []).isEmpty, frame.width >= 8, frame.height >= 8 else { return line }
        let measured = !(line.words ?? []).isEmpty
        let words = measured ? line.words! : estimate(line.text, lineBox)
        let width = Double(frame.width)
        let lineHeight = lineBox.bottom - lineBox.top
        let linePx = lineHeight * Double(frame.height)
        guard let first = words.first, linePx >= 6 else { return line }
        let head = words.map(\.text).filter { $0.utf16.count > 1 && !names.contains($0.uppercased()) }.joined()
        let bar = head.filter(\.isLetter).count >= 2 && head == head.uppercased()
        let spanX = linePx * 1.8 / width
        let symbol = String(marker)
        var tokens: [String] = []
        var icons: [IconSlot] = []
        func padded(_ left: Double, _ right: Double) -> TextBox {
            TextBox(left: max(0, min(1, left)), top: max(0, min(1, lineBox.top - lineHeight * 0.3)),
                    right: max(0, min(1, right)), bottom: max(0, min(1, lineBox.bottom + lineHeight * 0.3)))
        }
        func hasIcon(_ box: TextBox) -> Bool {
            guard let ink = locate(frame, box), Double(ink.inkHeight) >= linePx * (monochrome ? 0.6 : 0.5),
                  Double(ink.inkHeight) <= linePx * 2.2 else { return false }
            return (0.6...2.4).contains(Double(ink.inkWidth) / Double(ink.inkHeight)) && (!monochrome || isColourless(frame, box))
        }
        func addEdge(_ left: Double, _ right: Double) {
            let box = padded(left, right)
            if hasIcon(box) {
                tokens.append(symbol)
                icons.append(IconSlot(box: box, text: ""))
            }
        }
        if !monochrome, !isIconToken(first.text), lineBox.left > 0 {
            addEdge(lineBox.left - spanX, lineBox.left - spanX * 0.08)
        }
        for (i, word) in words.enumerated() {
            if bar, i > 0, tokens.last != symbol {
                let left = words[i - 1].box.right, gap = word.box.left - left
                if gap * width > linePx * 0.9 { addEdge(left + gap * 0.1, word.box.left - gap * 0.1) }
            }
            let core = trimming(word.text, brackets)
            let named = names.contains(core.uppercased())
            let hasLettersOrDigits = core.unicodeScalars.contains { isLetter($0) || $0.properties.generalCategory == .decimalNumber }
            // Satır sonundaki harf+rakam ("C3", "13"): yuvarlak L3/R3 simgesinin okunuşu (#860).
            let suspicious = bar ? (named || core.utf16.count == 1 || ["11", "12", "13", "21", "22", "23"].contains(core)
                                     || (i == words.count - 1 && i > 0 && core.utf16.count == 2 && core.last?.isNumber == true)
                                     || (core.utf16.count <= 2 && !hasLettersOrDigits))
                                 : (i == 0 && words.count >= 2 && isIconToken(word.text))
            if suspicious {
                let halfWidth = (word.box.right - word.box.left) / 2
                var left = i > 0 ? min(word.box.left, (words[i - 1].box.right + word.box.left) / 2) : word.box.left - halfWidth
                var right = i + 1 < words.count ? max(word.box.right, (word.box.right + words[i + 1].box.left) / 2)
                                                  : word.box.right + halfWidth
                let measuredButton = named && measured
                if measuredButton {
                    let rim = linePx * 0.3 / width
                    left = max(left, word.box.left - rim)
                    right = min(right, word.box.right + rim)
                }
                let box = padded(left, right)
                if hasIcon(box) {
                    if measuredButton || tokens.last != symbol {
                        tokens.append(symbol)
                        icons.append(IconSlot(box: box, text: core))
                    }
                    continue
                }
                if !named && !hasLettersOrDigits && !["+", "/", "&", "-"].contains(core) { continue }
            }
            tokens.append(word.text)
        }
        if !monochrome, bar, !tokens.isEmpty, tokens.last != symbol, lineBox.right < 1 {
            addEdge(lineBox.right + spanX * 0.08, lineBox.right + spanX)
        }
        guard !icons.isEmpty else { return line }
        if monochrome {
            // Otomatik ekran yazısında satırın başındaki ve sonundaki simge çeviriye taşınmaz: oyunun kendi simgesi yerinde
            // görünür kalır, çeviri kutusu simgeden sonra başlar (önce biter). Yazının ortasındaki simge korunur.
            var kept = tokens, slots = icons
            while kept.first == symbol, kept.count > 1 { kept.removeFirst(); slots.removeFirst() }
            while kept.last == symbol, kept.count > 1 { kept.removeLast(); slots.removeLast() }
            guard kept.count < tokens.count else {
                return TextLine(tokens.joined(separator: " "), box: line.box, confidence: line.confidence, icons: icons)
            }
            let texts = Set(kept.filter { $0 != symbol })
            let boxes = words.filter { texts.contains($0.text) }.map(\.box)
            var box = lineBox
            if let first = boxes.first, let last = boxes.last {
                box.left = max(lineBox.left, first.left)
                box.right = min(lineBox.right, last.right)
            }
            return TextLine(kept.joined(separator: " "), box: box, confidence: line.confidence,
                            icons: slots.isEmpty ? nil : slots)
        }
        return TextLine(tokens.joined(separator: " "), box: line.box, confidence: line.confidence, icons: icons)
    }

    /// Kesilmiş simgeler: kutusu verilen her simge kareden kesilir (bkz. `crop`).
    public static func withImages(_ icons: [IconSlot], frame: CGImage) -> [IconSlot] {
        icons.map { icon in
            guard icon.image == nil else { return icon }
            var cut = icon
            cut.image = crop(frame, icon.box)
            return cut
        }
    }

    /// Bitişik piksel kümesinin kutusu (sağ ve alt kenar dahil değil).
    private struct Component {
        var left, top, right, bottom: Int
        var area: Int { (right - left) * (bottom - top) }
    }

    /// Sekiz komşulu bitişik piksel kümelerinin kutuları; dört pikselden küçükler atılır.
    private static func components(_ ink: [Bool], width: Int, height: Int) -> [Component] {
        var seen = [Bool](repeating: false, count: ink.count)
        var result: [Component] = []
        var stack: [Int] = []
        for first in ink.indices where ink[first] && !seen[first] {
            var box = Component(left: width, top: height, right: 0, bottom: 0)
            var count = 0
            seen[first] = true
            stack.append(first)
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                count += 1
                box.left = min(box.left, x)
                box.right = max(box.right, x + 1)
                box.top = min(box.top, y)
                box.bottom = max(box.bottom, y + 1)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let next = ny * width + nx
                        guard ink[next], !seen[next] else { continue }
                        seen[next] = true
                        stack.append(next)
                    }
                }
            }
            if count >= 4 { result.append(box) }
        }
        return result
    }

    /// Kutunun kenar piksellerinin ortanca rengi: zemin.
    private static func borderMedian(_ pixels: [UInt8], stride: Int, offsetX: Int, offsetY: Int,
                                     width: Int, height: Int) -> (r: Int, g: Int, b: Int) {
        var r: [Int] = [], g: [Int] = [], b: [Int] = []
        func add(_ x: Int, _ y: Int) {
            let i = (offsetY + y) * stride + (offsetX + x) * 4
            r.append(Int(pixels[i]))
            g.append(Int(pixels[i + 1]))
            b.append(Int(pixels[i + 2]))
        }
        for x in 0..<width {
            add(x, 0)
            add(x, height - 1)
        }
        for y in 0..<height {
            add(0, y)
            add(width - 1, y)
        }
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        return (median(r), median(g), median(b))
    }

    /// Karenin bir dikdörtgenini RGBA piksellere çizer (satırlar yukarıdan aşağı); çizilemezse nil.
    private static func rgba(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, let part = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    // MARK: - PNG

    /// RGBA piksellerin bir dikdörtgenini opak RGBA PNG'ye çevirir. Paket ImageIO'ya bağlı değil: PNG elle yazılır,
    /// sıkıştırmayı Foundation yapar (`.zlib` ham deflate verir; zlib başlığı ve Adler-32 burada eklenir).
    static func png(_ pixels: [UInt8], stride: Int, x: Int, y: Int, width: Int, height: Int) -> Data {
        var raw: [UInt8] = []
        raw.reserveCapacity(height * (width * 4 + 1))
        for row in 0..<height {
            raw.append(0) // filtre yok
            let base = (y + row) * stride + x * 4
            for column in 0..<width {
                let i = base + column * 4
                raw.append(pixels[i])
                raw.append(pixels[i + 1])
                raw.append(pixels[i + 2])
                raw.append(255)
            }
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = bigEndian(UInt32(width)) + bigEndian(UInt32(height))
        header += [8, 6, 0, 0, 0] // bit derinliği, RGBA, sıkıştırma, filtre, satır atlama yok
        chunk(&png, "IHDR", header)
        chunk(&png, "IDAT", zlib(raw))
        chunk(&png, "IEND", [])
        return png
    }

    /// zlib akışı: başlık + deflate + Adler-32. Sıkıştırma olmazsa sıkıştırmasız deflate blokları yazılır.
    private static func zlib(_ raw: [UInt8]) -> [UInt8] {
        var stream: [UInt8] = [0x78, 0x01]
        if let deflated = try? (Data(raw) as NSData).compressed(using: .zlib) {
            stream += [UInt8](deflated as Data)
        } else {
            stream += stored(raw)
        }
        stream += bigEndian(adler32(raw))
        return stream
    }

    /// Sıkıştırmasız deflate blokları (her biri en çok 65535 bayt).
    private static func stored(_ raw: [UInt8]) -> [UInt8] {
        var blocks: [UInt8] = []
        var offset = 0
        repeat {
            let length = min(65535, raw.count - offset)
            blocks.append(offset + length >= raw.count ? 1 : 0)
            blocks += [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8((~length >> 8) & 0xFF)]
            blocks += raw[offset..<offset + length]
            offset += length
        } while offset < raw.count
        return blocks
    }

    private static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static func chunk(_ png: inout Data, _ type: String, _ data: [UInt8]) {
        png.append(contentsOf: bigEndian(UInt32(data.count)))
        let body = Array(type.utf8) + data
        png.append(contentsOf: body)
        png.append(contentsOf: bigEndian(crc32(body)))
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// TV'de çevirinin içine konacak simge: düz metinde `at`. karakterden (UTF-16 birimi, TV'deki JavaScript gibi) önce.
public struct IconPlacement: Equatable, Sendable {
    public var at: Int
    /// Simgenin PNG'si (data: adresi).
    public var image: String

    public init(at: Int, image: String) {
        self.at = at
        self.image = image
    }
}

/// Simgenin yerini çeviri boyunca korur. Çeviriden önce her `ButtonIcons.marker` uydurma bir özel adla değiştirilir
/// (`TermProtector` ile aynı gerekçe: çevirmenler özel adı olduğu gibi bırakır, "[1]" gibi işaretleri düşürebilir):
/// "Hold Feldor to sprint" → "Koşmak için Feldor'u basılı tut". Çeviriden sonra ad (ekiyle birlikte: ek gerçek düğmenin
/// adına uymaz) simgenin sıra imine döner; çevirmen adı düşürdüyse simge başa konur (Windows: ButtonIcons.cs, IconText).
public enum IconText {
    /// Korunmuş paragraf: çevirmene gidecek metin ve sırayla kullanılan adlar.
    public typealias Protected = (text: String, names: [String])

    /// Çevrilmiş metinde k. simgenin imi: U+E000 + k (özel kullanım alanı).
    public static let firstSlot: Character = "\u{E000}"
    private static let firstSlotValue: UInt32 = 0xE000

    /// Terim korumasının adlarıyla aynı kurallar; sondan başlanır, ikisi aynı metinde karşılaşmasın.
    private static let names: [String] = TermProtector.placeholders.reversed()

    private static func slot(_ k: Int) -> Unicode.Scalar { Unicode.Scalar(firstSlotValue + UInt32(k))! }

    private static func isSlot(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= firstSlotValue && scalar.value < firstSlotValue + 0x100
    }

    /// Simgeleri adlarla değiştirir; kullanılan adlar sırayla döner. Ad kalmazsa fazla simge düşer. Simgenin ardındaki
    /// noktalama ada yapışık kalır ("Hold Feldor.").
    public static func protect(_ paragraph: String) -> Protected {
        guard paragraph.unicodeScalars.contains(ButtonIcons.markerScalar) else { return (paragraph, []) }
        var free = names.filter { paragraph.range(of: $0, options: .caseInsensitive) == nil }
        var used: [String] = []
        var builder = String.UnicodeScalarView()
        for scalar in paragraph.unicodeScalars {
            if scalar != ButtonIcons.markerScalar {
                builder.append(scalar)
            } else if !free.isEmpty {
                let name = free.removeFirst()
                used.append(name)
                builder.append(contentsOf: name.unicodeScalars)
            }
        }
        return (collapse(String(builder)), used)
    }

    /// Çevirideki adları `offset`'ten başlayan sıra imlerine çevirir. Çeviride bulunmayan adın simgesi metnin başına
    /// konur (en azından hangi düğme olduğu görünsün).
    public static func restore(_ translation: String, names: [String], offset: Int) -> String {
        var text = translation
        var missing = ""
        for (k, name) in names.enumerated() {
            let mark = String(Character(slot(offset + k)))
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name)
                + #"(?:\s?['’`´]\p{L}+|\p{L}+)?(?![\p{L}\p{N}])"#
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if expression.firstMatch(in: text, range: range) != nil {
                text = expression.stringByReplacingMatches(in: text, range: range,
                                                           withTemplate: NSRegularExpression.escapedTemplate(for: mark))
            } else {
                missing += mark + " "
            }
        }
        return missing.isEmpty ? text : missing + text
    }

    /// Okunan paragraf çevrilmeden gösterilecekse simgeleri sırayla imlenir.
    public static func indexed(_ paragraph: String, offset: Int) -> String {
        var builder = String.UnicodeScalarView()
        var next = offset
        for scalar in paragraph.unicodeScalars {
            if scalar == ButtonIcons.markerScalar {
                builder.append(slot(next))
                next += 1
            } else {
                builder.append(scalar)
            }
        }
        return String(builder)
    }

    /// İmli metni TV'ye gidecek düz metne ve simge yerlerine ayırır. Kesilemeyen simgenin yerine okunan hali yazılır;
    /// art arda boşluklar teke iner (eski TV uygulamaları simgesiz düz metni gösterir). Yerler UTF-16 birimiyle sayılır
    /// (TV'deki JavaScript dizgileri gibi).
    public static func render(_ marked: String, slots: [IconSlot]) -> (text: String, icons: [IconPlacement]) {
        var text = ""
        var icons: [IconPlacement] = []
        func append(_ value: String) {
            for c in value {
                if c == " " && (text.isEmpty || text.last == " " || text.last == "\n") { continue }
                // Simgenin ardındaki noktalama ve satır sonu önündeki boşluğu yutar: "için [◎], etkileşim".
                if c == "\n" || ".,;:!?…)".contains(c), text.last == " " {
                    text.removeLast()
                    let length = text.utf16.count
                    for i in icons.indices where icons[i].at > length { icons[i].at = length }
                }
                text.append(c)
            }
        }
        for scalar in marked.unicodeScalars {
            if scalar == ButtonIcons.markerScalar { continue }
            guard isSlot(scalar) else {
                append(String(Character(scalar)))
                continue
            }
            let k = Int(scalar.value - firstSlotValue)
            guard k < slots.count else { continue }
            if let image = slots[k].image {
                icons.append(IconPlacement(at: text.utf16.count, image: image))
            } else {
                append(slots[k].text)
            }
        }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        let length = text.utf16.count
        return (text, icons.map { IconPlacement(at: min($0.at, length), image: $0.image) })
    }

    /// Simgesiz düz metin (okunanın kaydı ve karşılaştırma için).
    public static func plain(_ text: String) -> String {
        var builder = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar != ButtonIcons.markerScalar && !isSlot(scalar) { builder.append(scalar) }
        return collapse(String(builder))
    }

    private static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
