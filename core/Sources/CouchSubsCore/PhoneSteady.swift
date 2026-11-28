// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Otomatik telefon okumasında çevirinin kararlılığı. Aynı mesajın OCR'la bir iki harfi farklı okunuşu yeni mesaj
/// sayılıyor, balon bir an özgün diline dönüp yeniden çevriliyor, çeviri her seferinde biraz değişiyordu; telefon tek
/// karede bulunamayınca da bütün çeviriler silinip geri geliyordu ("sürekli git gel yapıyor", X'teki bildirim). Windows
/// (PhoneSteady.cs) ve Android (PhoneSteady.kt) aynı eşikleri kullanır.
enum PhoneSteady {
    /// Telefon art arda bu kadar turda bulunamazsa ya da okuma doğrulanamazsa çeviriler silinir.
    static let missTurns = 3
    /// Yan yana bozuk harfler en çok bu kadar tur bekletilir.
    static let holdTurns = 2
    /// Eksik düzen (düşen, kesilen ya da komşusuyla birleşen balon) ancak sekiz ardışık okumada (~4 sn) doğrulanırsa gösterilen
    /// sohbeti değiştirir (X, 28 Kas, beta.107; Windows ve Android ile aynı).
    static let degradedTurns = 8
    /// Sayfanın türü (sohbet listesi ya da sohbet) ancak bu kadar ardışık okuma aynı yeni türü verirse değişir: sallanan
    /// telefonda tek okumada bölüm başlığı kaçınca TV'deki panel liste ile balonlar arasında her saniye gidip geliyordu
    /// (LG, beta.93).
    static let kindTurns = 2

    /// Okumanın grupları sohbet listesi mi (kişi adı, önizleme, bölüm başlığı).
    static func isList(_ roles: [ScreenPhoneCard.Role?]) -> Bool {
        roles.contains { $0 == .contact || $0 == .preview || $0 == .heading }
    }
    /// Aynı mesaj sayılmak için sadeleştirilmiş iki okumanın benzerliği (Levenshtein oranı) en az bu.
    static let sameMessage = 0.9
    /// Kısa satırda bir harf anlamı değiştirir ("Ok" / "On"): benzer okuma yalnız bu kadar harften uzun mesajda kullanılır.
    static let minimumLetters = 8

    /// Mesajın bilinen çevirisi: birebir aynı okunuşunki, yoksa aynı mesajın OCR'la biraz farklı okunuşununki. Sayı ya da
    /// olumsuzluk ekleyen/düşüren okuma ("at 5" / "at 6", "can" / "can't") aynı mesaj sayılmaz. Birden çok aday varsa
    /// kayıt sırasında (`order`) ilk eşleşen; sıra verilmezse alfabede önce gelen (her platformda aynı sonuç).
    ///
    /// Sadeleştirilmiş hali birebir aynı okuma (yalnız büyük/küçük harf ya da noktalama farkı: "Ok." / "ok") kısa satırda
    /// da aynı mesajdır: önceden kısa mesaj her noktalama oynamasında yeniden çevriliyor, balonu kayboluyordu (X, GTA 6
    /// telefonu: "yazılar sürekli oynuyor").
    static func translation(of source: String, in known: [String: String], order: [String]? = nil) -> String? {
        if let exact = known[source] { return exact }
        for old in order ?? known.keys.sorted() where sameReading(source, old) { return known[old] }
        return nil
    }

    /// İki okuma aynı mesaj mı: birebir aynı, sadeleştirilmiş hali aynı ya da en az `minimumLetters` harfli iki uzun
    /// mesajda yalnız OCR artığı farklı: kesme işareti, noktalama, "rn" / "m", "l" / "i", yan yana iki bozuk sözcük ya da en
    /// çok `slipWords` sözcükte tek harf kayması. Gerçek sözcük değişimi ("here" / "there"), sayı ya da olumsuzluk
    /// ekleyen/düşüren okuma aynı sayılmaz (Windows ve Android ile aynı).
    static func sameReading(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = TextMatch.normalize(a), y = TextMatch.normalize(b)
        guard !x.isEmpty, !y.isEmpty, !TextMatch.addsMeaning(a, to: b), !TextMatch.addsMeaning(b, to: a) else { return false }
        // "Ok?" / "Ok." aynı harfler, başka anlam: kısa satırda soru işareti ikisinde de olmalı. Uzun mesajda düşen soru
        // işareti OCR'ın kaçırdığı noktalamadır: mesaj yeniden çevrilmiyor.
        if x == y { return a.contains("?") == b.contains("?") || x.filter(\.isLetter).count >= minimumLetters }
        guard x.filter(\.isLetter).count >= minimumLetters, y.filter(\.isLetter).count >= minimumLetters else { return false }
        // Uzun cümlede gerçek bir sözcüğün değişmesi ("here" / "there") benzerlik eşiğini geçebilir (X, 28 Kas, beta.107):
        // yalnız OCR'ın karıştırdığı harfler, kesme işareti ve noktalama artığı eşleşir.
        // Bitişik ya da ayrık okunan sözcük ("Yo Istill" / "Yo I still") da aynı mesajdır.
        let p = readingLetters(a), q = readingLetters(b)
        return p == q || p.replacingOccurrences(of: " ", with: "") == q.replacingOccurrences(of: " ", with: "")
            || GamePhoneText.hasAdjacentOcrEdits(a, b) || letterSlips(a, b)
    }

    /// Aynı mesajın okunuşunda en çok bu kadar sözcükte tek harf kayabilir.
    static let slipWords = 2
    /// Tek harf kayması yalnız en az bu kadar harfli sözcükte aranır ("cold" / "bold" gibi kısa sözcükler anlam taşır).
    private static let slipLetters = 5
    private static let echoedLetter = try! NSRegularExpression(pattern: #"(\p{L}),\1\b"#, options: [.caseInsensitive])

    /// Karşılaştırma için okunuşun harfleri: "it,t" → "it", "You'l " → "You'll ", kesme işareti atılır; "rn" / "m",
    /// "q" / "g" ve "l" / "i" (OCR'ın sık karıştırdığı harfler, "flnd" / "find") birleştirilir.
    static func readingLetters(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let echoed = echoedLetter.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        let apostrophes = echoed.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "'l ", with: "'ll ", options: .caseInsensitive)
            .replacingOccurrences(of: "'", with: "")
        return TextMatch.normalize(apostrophes).replacingOccurrences(of: "rn", with: "m")
            .replacingOccurrences(of: "q", with: "g").replacingOccurrences(of: "l", with: "i")
    }

    /// Sözcük sayısı aynı, en çok `slipWords` sözcükte OCR'ın tek harf kayması: aynı uzunlukta tek harf değişimi
    /// ("breathabie") ya da yan yana yinelenen harf ("SOMETHINnG"). Başa harf eklenmesi ("here" / "there") eşleşmez.
    private static func letterSlips(_ a: String, _ b: String) -> Bool {
        let x = readingLetters(a).split(separator: " ").map(String.init)
        let y = readingLetters(b).split(separator: " ").map(String.init)
        guard x.count == y.count else { return false }
        var slips = 0
        for (p, q) in zip(x, y) where p != q {
            slips += 1
            if slips > slipWords || !letterSlip(p, q) { return false }
        }
        return slips > 0
    }

    private static func letterSlip(_ p: String, _ q: String) -> Bool {
        let a = Array(p), b = Array(q)
        guard min(a.count, b.count) >= slipLetters, a.allSatisfy(\.isLetter), b.allSatisfy(\.isLetter) else { return false }
        if a.count == b.count { return zip(a, b).filter { $0 != $1 }.count == 1 }
        let (shorter, longer) = a.count < b.count ? (a, b) : (b, a)
        guard longer.count == shorter.count + 1 else { return false }
        for i in 1..<longer.count where longer[i] == longer[i - 1] {
            var removed = longer
            removed.remove(at: i)
            if removed == shorter { return true }
        }
        return false
    }

    /// Aynı yerdeki balonun başı, sonu ya da aradaki satırı eksik okunmuş mu.
    static func truncatedReading(_ read: String, of shown: String) -> Bool {
        func normalized(_ text: String) -> [Character] {
            Array(TextMatch.normalize(text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")))
        }
        let shorter = normalized(read), full = normalized(shown)
        guard !shorter.isEmpty, shorter.count < full.count else { return false }
        if full.starts(with: shorter), full[shorter.count] == " " || shorter.count >= minimumLetters { return true }
        if TextMatch.addsMeaning(read, to: shown) { return false }
        if TextMatch.isGrowth(shown, of: read) { return true }
        // Bitişik okunan sözcüklerle de eksik okuma: boşluksuz hâli tam metnin içinde.
        if shorter.count >= minimumLetters,
           String(full).replacingOccurrences(of: " ", with: "").contains(String(shorter).replacingOccurrences(of: " ", with: "")) {
            return true
        }
        let words = String(shorter).split(separator: " ")
        guard words.count >= 3 else { return false }
        var kept = 0
        for word in String(full).split(separator: " ") where word == words[kept] {
            kept += 1
            if kept == words.count { return true }
        }
        return false
    }

    /// Önceki iki komşu balonun tek kutuda okunuşu; ikincisi yarım da kalabilir.
    static func mergedReading(_ read: String, _ first: String, _ second: String) -> Bool {
        let combined = first + " " + second
        return sameReading(read, combined) || (TextMatch.isGrowth(read, of: first) && truncatedReading(read, of: combined))
    }

    // MARK: Ekrandaki balonların kararlılığı (X, 22 Kas, GTA 6 telefonu: "yazılar sürekli oynuyor okumak çok zor,
    // balonların içinde de aynı hata var"). Her OCR turunda balon kutuları birkaç piksel oynuyor, telefonun bulunan yeri
    // titriyordu; masaüstü her turda yeni kutuları gönderiyor, TV paneli ve balonları yeniden diziyordu. Windows
    // (PhoneSteady.cs) ve Android (PhoneSteady.kt) aynı kuralı, aynı eşikleri kullanır.

    /// Aynı balonun yeri, satır yüksekliğinin bu payından az oynadıysa son çizilen yerde kalır (histerezis).
    static let positionShare = 0.25
    /// Yanda Panel'in dayandığı telefon yeri, kutusunun her kenarı bu kadardan (kareye oranla) az oynadıysa sabit kalır.
    static let poseSlack = 0.015

    /// Balonların yeri: önceki gönderiyle eşleşen balonlar (`match`: aynı çeviri, aynı okuma, 0,05 içinde) küçük oynamada
    /// (satır yüksekliğinin `positionShare`'i; yatayda kare oranıyla) son çizilen yerde kalır. Eşleşen balonların yarısından
    /// çoğu eşiği aşarsa (telefon gerçekten kıpırdadı, sohbet kaydı) hepsi birlikte, tek seferde yeni yerine geçer; tek
    /// başına eşiği aşan balon kendi yerine geçer. Boyu `stableBlocks` belirler; boyu değişmeyen balonun kutusu birebir
    /// öncekidir. `aspect`: karenin eni / boyu.
    static func steadyPositions(_ items: [ScreenTranslation.Item], previous: [ScreenTranslation.Item],
                                aspect: Double) -> [ScreenTranslation.Item] {
        let ratio = max(0.1, aspect)
        func still(_ box: TextBox, _ old: ScreenTranslation.Item) -> Bool {
            let limit = positionShare * old.lineHeight
            return abs(box.top - old.box.top) <= limit && abs(box.left - old.box.left) <= limit / ratio
        }
        let pairs = items.enumerated().compactMap { index, item in match(item, in: previous).map { (index, $0) } }
        let moved = pairs.filter { !still(items[$0.0].box, $0.1) }.count
        guard !pairs.isEmpty, 2 * moved <= pairs.count else { return items }
        var result = items
        for (index, old) in pairs where still(items[index].box, old) {
            let box = items[index].box
            let width = box.right - box.left, height = box.bottom - box.top
            let oldWidth = old.box.right - old.box.left, oldHeight = old.box.bottom - old.box.top
            result[index].box = TextBox(left: old.box.left, top: old.box.top,
                                        right: abs(width - oldWidth) < 1e-9 ? old.box.right : min(1, old.box.left + width),
                                        bottom: abs(height - oldHeight) < 1e-9 ? old.box.bottom : min(1, old.box.top + height))
        }
        return result
    }

    /// Kaydırma sayılmak için eşleşen balonların her biri en az satır yüksekliğinin bu katı kadar kaymalı.
    static let scrollShare = 0.5

    /// Telefonda sohbet kaydırıldı mı: önceki okumayla eşleşen balonların (aynı mesaj, `sameReading`) hepsi dikeyde aynı
    /// yöne, satır yüksekliğinin `scrollShare`'inden fazla kaydı. Kaydırmada bekletme (`holdTurns`) ve konum sabitleme
    /// (`steadyPositions`, `stableBlocks`) atlanır, görünen yeni balonlar tek istekte çevrilir (#1202, #1170, X: "kaydırınca
    /// yenilenmiyor"). Üstler ve `lineHeight` telefon bölgesine oranlıdır (telefonun kendisi kıpırdasa da ölçü değişmez).
    /// Her güncel balon, öncekilerden henüz eşlenmemiş ilk aynı mesajla eşlenir. Windows ve Android aynı kuralı uygular.
    static func scrolled(previous: [(text: String, top: Double)], current: [(text: String, top: Double)],
                         lineHeight: Double) -> Bool {
        guard lineHeight > 0 else { return false }
        var used = Set<Int>()
        var shifts: [Double] = []
        for bubble in current {
            guard let index = previous.indices.first(where: { !used.contains($0) && sameReading(previous[$0].text, bubble.text) })
            else { continue }
            used.insert(index)
            shifts.append(bubble.top - previous[index].top)
        }
        guard !shifts.isEmpty, shifts.allSatisfy({ abs($0) > scrollShare * lineHeight }) else { return false }
        return shifts.allSatisfy { $0 > 0 } || shifts.allSatisfy { $0 < 0 }
    }

    /// İki yazı rengi zeminin aynı yanında mı (ikisi de zeminden koyu ya da ikisi de açık; algılanan parlaklıkla).
    static func sameInk(_ a: String, _ b: String, on background: String) -> Bool {
        func brightness(_ hex: String) -> Int? {
            guard hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
            return (((value >> 16) & 0xFF) * 299 + ((value >> 8) & 0xFF) * 587 + (value & 0xFF) * 114) / 1000
        }
        guard let x = brightness(a), let y = brightness(b), let z = brightness(background) else { return false }
        return (x < z) == (y < z)
    }

    /// Önceki gönderide bu balonun eşi: aynı çeviri, aynı okuma (`sameReading`), sol üst köşesi 0,05 içinde. Aynı yerde iki
    /// eş varsa ayırt edilemez, nil.
    static func match(_ item: ScreenTranslation.Item, in previous: [ScreenTranslation.Item]) -> ScreenTranslation.Item? {
        var found: ScreenTranslation.Item?
        for old in previous where old.translation == item.translation && old.panel == item.panel
            && abs(old.box.left - item.box.left) <= 0.05 && abs(old.box.top - item.box.top) <= 0.05
            && sameReading(old.source, item.source) {
            if found != nil { return nil }
            found = old
        }
        return found
    }

    /// Yanda Panel'in dayandığı telefon: yeni bulunan yerin kutusu öncekinden her kenarda `poseSlack`'ten az oynadıysa
    /// önceki yer. Panel telefonun el titremesiyle kaymaz; telefon gerçekten kıpırdayınca bir kerede yeni yerine geçer.
    static func steadyPose(_ pose: GamePhoneGeometry.Pose, anchor: GamePhoneGeometry.Pose?) -> GamePhoneGeometry.Pose {
        guard let anchor else { return pose }
        let a = pose.bounds, b = anchor.bounds
        let still = abs(a.left - b.left) <= poseSlack && abs(a.right - b.right) <= poseSlack
            && abs(a.top - b.top) <= poseSlack && abs(a.bottom - b.bottom) <= poseSlack
        return still ? anchor : pose
    }

    // MARK: Kararlı çıktı (X, 22 Kas: "sağ tarafta kutu çıkarıyorsun ama her saniye şekli de hareketi de değişiyor").
    // Telefonun yazısı değişmedikçe çizilen Türkçe birebir aynı kalır: aynı mesaj aynı çeviriyle ve bir kez, gruptaki
    // bütün balonlar tek boyda; panelin kutusu yalnız telefon gerçekten kıpırdayınca kayar. Windows (PhoneSteady.cs) ve
    // Android (PhoneSteady.kt) aynı kuralı, aynı eşikleri kullanır.

    /// Art arda gelmeyen iki öğe ancak bu kadar harften uzunsa aynı mesaj sayılıp sonraki atılır (kısa "Ok" sohbette iki
    /// kez gerçekten yazılmış olabilir).
    static let repeatLetters = 12

    /// Aynı mesaj panelde bir kez: telefondaki öğelerden (`phone` bilgisi olanlar) bir öncekiyle aynı mesajı taşıyan
    /// (`sameReading`) art arda öğe atılır; araları açık iki öğeden sonraki ancak uzun mesajsa (`repeatLetters`) atılır.
    /// Bir mesajın OCR'da iki kez gelmesi panelde aynı paragrafı art arda iki kez yazdırıyordu (X, 22 Kas). Telefon
    /// dışındaki öğelere dokunulmaz.
    static func withoutRepeats(_ items: [ScreenTranslation.Item]) -> [ScreenTranslation.Item] {
        var kept: [ScreenTranslation.Item] = []
        for item in items {
            guard item.phone != nil else {
                kept.append(item)
                continue
            }
            let onPhone = kept.filter { $0.phone != nil }
            let long = TextMatch.normalize(item.source).filter(\.isLetter).count >= repeatLetters
            let repeated = onPhone.indices.contains { index in
                sameReading(onPhone[index].source, item.source) && (index == onPhone.count - 1 || long)
            }
            if !repeated { kept.append(item) }
        }
        return kept
    }

    /// Önceki gönderide aynı mesaj (`sameReading`) varsa öğe onun kaynağını ve çevirisini aynen alır: aynı İngilizce
    /// için Türkçe her okumada yeniden üretilmez; bir harfi oynayan okuma ya da paketin bir bulup bir bulamadığı satır
    /// başka bir çeviri göstermez. Her önceki öğe en çok bir kez kullanılır; telefonun öğeleri yalnız telefonun öğeleriyle,
    /// çevrilmemiş öğeler (`unchanged`) yalnız çevrilmemişlerle eşlenir.
    static func keptTranslations(_ items: [ScreenTranslation.Item], previous: [ScreenTranslation.Item]) -> [ScreenTranslation.Item] {
        var used = Set<Int>()
        return items.map { item in
            guard let index = previous.indices.first(where: { index in
                let old = previous[index]
                return !used.contains(index) && (old.phone != nil) == (item.phone != nil) && old.unchanged == item.unchanged
                    && sameBubble(old.source, at: old.phone?.spot, item.source, at: item.phone?.spot)
            }) else { return item }
            used.insert(index)
            var kept = item
            kept.source = previous[index].source
            kept.translation = previous[index].translation
            kept.icons = previous[index].icons
            return kept
        }
    }

    /// Telefonda aynı yerde duran balonun okunuşları bu benzerlikten (Levenshtein oranı) yüksekse aynı mesajdır: yerini
    /// bildiğimiz balonda daha bozuk okuma da (atılan rakamlı sözcük "fo1ding", kaçan harf) yeni mesaj sayılmaz.
    static let sameSpotMessage = 0.8
    /// Aynı yer: düz ekrandaki sol üst köşeleri bu kadar içinde.
    static let sameSpot = 0.05

    /// İki okuma aynı balon mu: aynı mesaj (`sameReading`) ya da telefonun ekranında aynı yerde (`sameSpot`) ve en az
    /// `minimumLetters` harfli iki uzun okuma `sameSpotMessage` kadar benzer; sayı ya da olumsuzluk ekleyen/düşüren okuma
    /// aynı sayılmaz.
    static func sameBubble(_ a: String, at spotA: TextBox?, _ b: String, at spotB: TextBox?) -> Bool {
        if sameReading(a, b) { return true }
        guard let spotA, let spotB, abs(spotA.top - spotB.top) <= sameSpot, abs(spotA.left - spotB.left) <= sameSpot,
              !TextMatch.addsMeaning(a, to: b), !TextMatch.addsMeaning(b, to: a) else { return false }
        let x = TextMatch.normalize(a), y = TextMatch.normalize(b)
        return truncatedReading(b, of: a) && x.filter(\.isLetter).count >= minimumLetters
            && y.filter(\.isLetter).count >= minimumLetters && TextMatch.isSimilar(x, y, threshold: sameSpotMessage)
    }

    /// Ekranda aynı yerde duran aynı balonun gösterilen çevirisi (`sameBubble`); yoksa nil. Simgeli çeviri (yeri simgeye
    /// göre kurulmuş) kullanılmaz.
    static func shownTranslation(of source: String, at spot: TextBox?, in shown: [ScreenTranslation.Item]) -> String? {
        shown.first { $0.phone != nil && !$0.unchanged && $0.icons == nil && !$0.translation.contains("\n")
            && sameBubble($0.source, at: $0.phone?.spot, source, at: spot) }?.translation
    }

    /// Gruptaki bütün mesaj balonları tek yazı boyunda (`line`: kilitli ölçüm, `PhonePanelSteady.steadyLine`): her balonun
    /// OCR satır yüksekliği okumadan okumaya oynuyor, balonların üstündeki yazı bir küçük bir büyük çiziliyordu. Kişinin
    /// adı ve telefon dışı öğeler kendi boyunda kalır.
    static func uniformLine(_ items: [ScreenTranslation.Item], line: Double?) -> [ScreenTranslation.Item] {
        guard let line, line > 0 else { return items }
        return items.map { item in
            guard let role = item.phone?.role, role.inCard, role != .header, role != .contact else { return item }
            var same = item
            same.lineHeight = line
            return same
        }
    }

    /// Panelin zemini (kart) kısalmaz: yeni düzenin kartı öncekiyle aynı yanda, aynı genişlikte ve onun içinde kalıyorsa
    /// önceki kart kalır. Bir mesajın tek okumada düşmesi kartın boyunu her saniye değiştiriyordu; çiziciler mesajları
    /// kartın içinde akışla dizdiği için uzun kalan kart hiçbir mesajı kaydırmaz. Telefon gerçekten kıpırdayınca (kartın
    /// yanı ya da eni değişince) yeni kart geçer.
    static func steadyCard(_ shown: [ScreenTranslation.Item], previous: [ScreenTranslation.Item]) -> [ScreenTranslation.Item] {
        guard let index = shown.firstIndex(where: { $0.panel == .card }),
              let old = previous.first(where: { $0.panel == .card })?.box else { return shown }
        let box = shown[index].box, near = 1e-9
        guard abs(box.left - old.left) < near, abs(box.right - old.right) < near,
              box.top >= old.top - near, box.bottom <= old.bottom + near else { return shown }
        var result = shown
        result[index].box = old
        return result
    }

    /// İki gönderi TV'de ve masaüstünde aynı görünür mü. Akışla çizilen panelde mesajların, kişi adının ve notların yalnız
    /// sırası, yazısı ve rengi önemlidir; kutuları (telefondaki yere göre biraz oynar) önemsizdir. Hizalı panelde
    /// (`aligned`) her parça kendi kutusunda çizilir: kutular da aynı olmalıdır (küçük oynamayı `steadyPositions` zaten
    /// tutar). Panelin zemini ve panel dışındaki her öğe yeriyle birlikte aynı olmalıdır.
    static func samePicture(_ a: [ScreenTranslation.Item], _ b: [ScreenTranslation.Item]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { x, y in
            guard x.panel == y.panel, x.translation == y.translation, x.style == y.style, x.look == y.look,
                  x.icons == y.icons, x.bubble == y.bubble, x.lineHeight == y.lineHeight, x.aligned == y.aligned,
                  x.listRow == y.listRow else { return false }
            if let part = x.panel, part != .card, !a.contains(where: { $0.panel == .card && $0.aligned }) { return true }
            return x.box == y.box
        }
    }
}

/// Yanda Panel'in yazı boyu ve yeri oturum boyunca kararlı (#1152, GTA 6: "telefon titreyince sohbet panelinin yazıları
/// büyüyüp küçülüyor, balonlar yer değiştiriyor"). Panelin yazı boyu her turda telefondaki satır yüksekliklerinin
/// ortancasından, yeri ve eni telefonun bulunan kutusundan geliyordu; yakın kamerada el titremesi `PhoneSteady.poseSlack`
/// eşiğini ve telefon boyundaki %3'lük "yakınlaşma" eşiğini her turda aşıyor, panel her turda yeniden diziliyordu.
/// Artık ilk ölçümde kilitlenir: telefonun yeri ancak telefon belirgin biçimde (boyu `sizeShare`'den, ortası boyunun
/// `moveShare`'inden fazla) ve kesintisiz `settleMs` boyunca başka yerdeyse, satır yüksekliği ancak ölçülen değer
/// kilitliden `sizeShare`'den fazla ve kesintisiz `settleMs` boyunca farklıysa yenilenir. Telefon gerçekten yakınlaşınca
/// (boy `sizeShare`'den fazla değişip yeni yer benimsenince) yazı boyu yeniden ölçülür. Windows (PhoneSteady.cs) ve
/// Android (PhoneSteady.kt) aynı kuralı, aynı eşikleri kullanır.
struct PhonePanelSteady: Sendable {
    /// Bu paydan büyük boy değişimi belirgindir (yakınlaşma/uzaklaşma, yanlış ilk ölçüm).
    static let sizeShare = 0.25
    /// Telefonun ortası boyunun bu payından (yatayda eninin iki katı payından) fazla kaydıysa yer değişimi belirgindir.
    static let moveShare = 0.1
    /// Belirgin değişim bu kadar (ms) kesintisiz sürmeden benimsenmez; arada eski yere dönen tur sayacı sıfırlar.
    static let settleMs = 1000

    private(set) var pose: GamePhoneGeometry.Pose?
    private(set) var line: Double?
    private var poseSince: Int?
    private var lineSince: Int?
    /// Son kilitli yazı boyu ve o andaki telefon boyu: telefon kapanıp açılınca (ya da ekran bir an silinince) yazı boyu
    /// baştan ölçülmez; telefon aynı boydaysa (`sizeShare` içinde) aynı boy kalır. `reset` bunu silmez, `forget` siler.
    private(set) var remembered: (line: Double, height: Double)?

    init() {}

    /// Panelin dayanacağı telefon yeri. `resized`: telefonun boyu belirgin değişti (ya da ilk yer), balonların görünüşü
    /// baştan ölçülmeli.
    mutating func steadyPose(_ found: GamePhoneGeometry.Pose, now: Int) -> (pose: GamePhoneGeometry.Pose, resized: Bool) {
        guard let locked = pose else {
            pose = found
            poseSince = nil
            // Aynı boydaki telefon yeniden açıldı: yazı boyu öncekiyle aynı kalır.
            if line == nil, let remembered, remembered.height > 0,
               abs(Self.height(found) / remembered.height - 1) <= Self.sizeShare {
                line = remembered.line
                return (found, false)
            }
            return (found, true)
        }
        if Self.sameSpot(found, locked) {
            poseSince = nil
            return (locked, false)
        }
        guard let since = poseSince, now - since >= Self.settleMs else {
            if poseSince == nil { poseSince = now }
            return (locked, false)
        }
        poseSince = nil
        if Self.resized(found, locked) {
            pose = found
            line = nil
            lineSince = nil
            return (found, true)
        }
        // Boyu aynı kalan telefon yalnız yer değiştirdi: panel telefona sabit uzaklıkla, aynı boyda izler (kartın eni ve
        // boyu her yer değişiminde telefonun titreyen ölçüsünden yeniden kurulmaz).
        let moved = Self.shifted(locked, toward: found)
        pose = moved
        return (moved, false)
    }

    /// Telefonun yüksekliği (kareye oranla).
    static func height(_ pose: GamePhoneGeometry.Pose) -> Double { pose.bounds.bottom - pose.bounds.top }

    /// `locked` telefonun, ortası `found`'unkine gelecek biçimde kaydırılmış hali (boyu ve eğikliği aynı).
    static func shifted(_ locked: GamePhoneGeometry.Pose, toward found: GamePhoneGeometry.Pose) -> GamePhoneGeometry.Pose {
        // Biçimi birebir aynı telefon: bulunan yer olduğu gibi.
        if abs((found.bottomY - found.topY) - (locked.bottomY - locked.topY)) < 1e-9,
           abs((found.bottomX - found.topX) - (locked.bottomX - locked.topX)) < 1e-9 { return found }
        let a = locked.bounds, b = found.bounds
        let dx = (b.left + b.right - a.left - a.right) / 2, dy = (b.top + b.bottom - a.top - a.bottom) / 2
        return GamePhoneGeometry.Pose(topX: locked.topX + dx, topY: locked.topY + dy,
                                      bottomX: locked.bottomX + dx, bottomY: locked.bottomY + dy)
    }

    /// Panelin satır yüksekliği (kare yüksekliğine oranla; `ScreenPhoneCard.measuredLine`). Ölçüm yoksa kilitli değer.
    mutating func steadyLine(_ measured: Double?, now: Int) -> Double? {
        let result = lockedLine(measured, now: now)
        if let result, let pose { remembered = (result, Self.height(pose)) }
        return result
    }

    private mutating func lockedLine(_ measured: Double?, now: Int) -> Double? {
        guard let measured, measured > 0 else { return line }
        guard let locked = line else {
            line = measured
            lineSince = nil
            return measured
        }
        if abs(measured / locked - 1) <= Self.sizeShare {
            lineSince = nil
            return locked
        }
        guard let since = lineSince, now - since >= Self.settleMs else {
            if lineSince == nil { lineSince = now }
            return locked
        }
        line = measured
        lineSince = nil
        return measured
    }

    /// Telefon kayboldu: sonraki bulunuşta yeri yeniden ölçülür; aynı boydaki telefonun yazı boyu hatırlanır (`remembered`).
    mutating func reset() {
        let remembered = self.remembered
        self = PhonePanelSteady()
        self.remembered = remembered
    }

    /// Çeviri durdu: her şey unutulur.
    mutating func forget() {
        self = PhonePanelSteady()
    }

    /// İki telefon yeri aynı sayılır mı: kenarlar `PhoneSteady.poseSlack` içinde ya da boy `sizeShare` içinde ve ortası
    /// boyunun `moveShare`'inden (yatayda eninin `2 * moveShare`'inden) az kaymış.
    static func sameSpot(_ a: GamePhoneGeometry.Pose, _ b: GamePhoneGeometry.Pose) -> Bool {
        let x = a.bounds, y = b.bounds
        if abs(x.left - y.left) <= PhoneSteady.poseSlack && abs(x.right - y.right) <= PhoneSteady.poseSlack
            && abs(x.top - y.top) <= PhoneSteady.poseSlack && abs(x.bottom - y.bottom) <= PhoneSteady.poseSlack { return true }
        let height = y.bottom - y.top, width = y.right - y.left
        guard height > 0, width > 0, !resized(a, b) else { return false }
        return abs((x.top + x.bottom) - (y.top + y.bottom)) / 2 <= moveShare * height
            && abs((x.left + x.right) - (y.left + y.right)) / 2 <= 2 * moveShare * width
    }

    /// Telefonun boyu belirgin değişti mi.
    static func resized(_ a: GamePhoneGeometry.Pose, _ b: GamePhoneGeometry.Pose) -> Bool {
        let x = a.bounds.bottom - a.bounds.top, y = b.bounds.bottom - b.bounds.top
        guard y > 0 else { return true }
        return abs(x / y - 1) > sizeShare
    }
}
