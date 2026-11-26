// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// GTA 6 telefonunun sohbet dışı ekranları (sosyal akış gönderisi, haber listesi ve makale, hava, fitness, ayarlar,
/// eklenti sayfası). Sinan Bey (beta.100, 3416–3425): bu ekranların Türkçesi ya telefonun üstüne kutularla yazılıyor ya da
/// sohbet balonu sanılıp dev balonlarla çiziliyordu; gönderinin açıklaması üç balona bölünüyor, yer adı ve kaynak adı
/// çevriliyordu. Artık ekranın türü çıkarılır (`kind`) ve sohbet dışı ekranın yazıları telefondaki yapının Türkçe kopyası
/// olarak kartlara ayrılır (`cards`): her satır kartı, makale başlığı ya da gövdesi, gönderinin açıklaması tek kart; kartlar
/// telefonun yanındaki panelde, mesaj listesi kartlarıyla aynı görünüşte (`ScreenPhoneCard.Role.card`). Çevrilmeyenler:
/// kullanıcı adı (@…), saat ("7PM"), geri düğmesi, gönderinin konum satırı ve fotoğrafın içindeki yazı, haberin kaynak
/// adı. Windows (PhoneScreen.cs) ve Android (PhoneScreen.kt) aynı kuralları ve eşikleri uygular; ortak deneme dosyası
/// Fixtures/phone-screens.json.
enum PhoneScreen {
    enum Kind: String, Equatable, Sendable {
        /// Sohbet (balonlar) ya da tanınmayan ekran: eski kurallar.
        case chat
        /// Uygulama ekranı (haber, makale, hava, fitness, ayarlar, eklenti): satırlar kart.
        case app
        /// Sosyal akış gönderisi: kullanıcı adının altındaki açıklama tek kart, gerisi çevrilmez.
        case post
    }

    /// Ekrandaki bir satır: yazısı ve düz ekrandaki yeri (0–1).
    struct Line: Equatable {
        var text: String
        var spot: TextBox
        var height: Double { spot.bottom - spot.top }
        var words: Int { text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Satırın kartı (`TextLine.phoneCard`).
    struct Mark: Equatable, Sendable {
        var card: Int
        var title = false
        var bold = false
    }

    /// Bir kart: satırlarının sırası (`lines` içindeki yerleri, yukarıdan aşağı) ve başlığı. `titled`: ilk satır kartın
    /// kalın başlığı ("Strength Workout" / "Level 3/4"); `bold`: kartın tamamı başlık (makale başlığı).
    struct Card: Equatable {
        var lines: [Int]
        var titled = false
        var bold = false
    }

    /// Uygulama ekranı için en az bu kadar kısa satır (en çok `shortWords` sözcük, cümle sonu yok) ve satırların en az
    /// `shortShare`'i kısa olmalı (sohbette mesajlar cümledir).
    static let shortRows = 3, shortWords = 3, shortShare = 0.5
    /// "…" ile kesilmiş en az bu kadar satır (haber listesi): uygulama ekranı.
    static let cutRows = 2
    /// Karttaki iki satır arasındaki boşluk satır yüksekliğinin bu kadarından azsa aynı karttır; sol kenarlar `leftAlign`
    /// içinde hizalı ve yükseklikler en çok `heightRatio` katı farklı olmalı.
    static let rowGap = 0.7, leftAlign = 0.06, heightRatio = 1.35
    /// Kartın satır yüksekliği sayfanın ortancasının bu katından büyükse kart başlıktır (makale başlığı, kalın).
    static let titleHeight = 1.25
    /// Gönderinin açıklaması kullanıcı adının en çok bu kadar satır altında başlar; açıklama satırları arası `rowGap`.
    static let captionGap = 1.6
    /// Açıklama satırları kullanıcı adının (ya da ilk açıklama satırının) sol kenarına bu kadar hizalı.
    static let captionAlign = 0.12

    private static let time = try! NSRegularExpression(
        pattern: #"^\d{1,2}(?::\d{2})?\s?(?:[AaPp]\.?\s?[Mm]\.?|ᴬᴹ|ᴾᴹ)$"#)

    /// Saat ("7PM", "10 PM", "6:15PM"): çevrilmez.
    static func isTime(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        return time.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// Geri düğmesi ("< Back", "‹ Back").
    static func isBack(_ text: String) -> Bool {
        String(text.drop(while: { !$0.isLetter })).trimmingCharacters(in: .whitespaces).lowercased() == "back"
    }

    /// Yalnız kullanıcı adı ya da etiket ("@offthehook_magazine", "@Cal_zone ✓").
    static func isHandle(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.contains { $0.first == "@" && $0.count >= 3 }
            && words.allSatisfy { $0.first == "@" || !$0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    /// Çevrilecek yazı mı: en az iki harf, saat, geri düğmesi ve kullanıcı adı değil.
    static func isWords(_ text: String) -> Bool {
        text.filter(\.isLetter).count >= 2 && !isTime(text) && !isBack(text) && !isHandle(text)
    }

    static func endsSentence(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).last.map { ".!?".contains($0) } ?? false
    }

    static func isCut(_ text: String) -> Bool { GamePhoneText.isCut(text) }

    /// Kısa satır: en çok `shortWords` sözcük, cümle sonu ve "…" yok ("Wallpaper", "Cardio Workout", "Level 1/4").
    static func isShort(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return words >= 1 && words <= shortWords && !endsSentence(text) && !isCut(text)
    }

    /// Ad gibi (kaynak adı, yer adı): bir-üç sözcük, her biri büyük harfle başlar, rakam ve cümle sonu yok
    /// ("Vice City Horn", "Weazel News", "Okchiloha Bay").
    static func isName(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard (1...3).contains(words.count), !endsSentence(text), !isCut(text), !text.contains(where: \.isNumber) else { return false }
        return words.allSatisfy { word in
            word.first?.isUppercase == true && word.allSatisfy { $0.isLetter || "-'&.".contains($0) }
        }
    }

    /// Ekranın türü. `lines`: telefondaki bütün satırlar (kullanıcı adları ve harfsiz satırlar da). Sohbet listesi ve ana
    /// ekran önce ayrılır (`GamePhoneText.forTranslation`, `PhoneChat.isHome`); burada yalnız sohbet / uygulama / gönderi.
    /// - Gönderi: sol yarıda bir kullanıcı adı satırı ("@THE_DONDIDDLER") ve altında yazı.
    /// - Uygulama: üstte geri düğmesi (makale), "…" ile kesilmiş en az `cutRows` satır (haber listesi) ya da en az
    ///   `shortRows` kısa satır ve satırların en az `shortShare`'i kısa, sağa yaslı (giden mesaj) balon yok.
    /// - Değilse sohbet.
    static func kind(_ lines: [Line]) -> Kind {
        let words = lines.filter { isWords($0.text) }
        if lines.contains(where: { line in
            isHandle(line.text) && line.spot.left < 0.5
                && words.contains { $0.spot.top >= line.spot.top + line.height * 0.5 }
        }) { return .post }
        if lines.contains(where: { isBack($0.text) && ($0.spot.top + $0.spot.bottom) / 2 < 0.15 }) { return .app }
        guard !words.isEmpty else { return .chat }
        if words.filter({ isCut($0.text) }).count >= cutRows { return .app }
        let short = labels(words)
        // Sağa yaslı, iki yanı da dolu olmayan çok sözcüklü satır: oyuncunun mesajı (sohbet).
        let outgoing = words.contains { line in
            let left = max(0, line.spot.left), right = max(0, 1 - line.spot.right)
            return line.words >= 2 && left >= 0.2 && right < left * PhoneChat.sideRatio
        }
        if short >= shortRows, Double(short) >= Double(words.count) * shortShare, !outgoing { return .app }
        return .chat
    }

    /// Kısa etiket satırlarının sayısı (`isShort`): alt satıra sarılmış cümlenin parçası sayılmaz. Satır, hemen altındaki
    /// hizalı satır küçük harfle başlıyorsa (cümle sürüyor: "Dropped that stuff" / "off for you") ya da kendisi küçük
    /// harfle başlıyorsa ya da hemen üstündeki hizalı satır uzun bir cümle parçasıysa ("anything else AND I" / "MEAN
    /// ANYTHING u") etiket değildir.
    static func labels(_ words: [Line]) -> Int {
        let sorted = words.sorted { $0.spot.top < $1.spot.top }
        func joined(_ a: Line, _ b: Line) -> Bool {
            b.spot.top - a.spot.bottom <= rowGap * max(a.height, b.height) && abs(a.spot.left - b.spot.left) <= leftAlign
        }
        func lower(_ line: Line) -> Bool { line.text.first(where: \.isLetter)?.isLowercase == true }
        return sorted.indices.filter { index in
            let line = sorted[index]
            guard isShort(line.text), !lower(line) else { return false }
            if index + 1 < sorted.count, joined(line, sorted[index + 1]), lower(sorted[index + 1]) { return false }
            if index > 0, joined(sorted[index - 1], line), sorted[index - 1].words > shortWords,
               !endsSentence(sorted[index - 1].text) { return false }
            return true
        }.count
    }

    /// Sohbet dışı ekranın kartları (yukarıdan aşağı). Çevrilmeyen satırlar hiçbir karta girmez.
    static func cards(_ lines: [Line], kind: Kind) -> [Card] {
        let order = lines.indices.sorted { lines[$0].spot.top < lines[$1].spot.top }
        let heights = order.filter { isWords(lines[$0].text) }.map { lines[$0].height }.sorted()
        guard !heights.isEmpty else { return [] }
        let median = heights[(heights.count - 1) / 2]
        switch kind {
        case .chat: return []
        case .post: return captions(lines, order: order, median: median)
        case .app: return appCards(lines, order: order, median: median)
        }
    }

    /// Gönderinin açıklaması: her kullanıcı adının altında, ona hizalı ve aralıksız satırlar tek kart. Fotoğrafın içindeki
    /// yazı, beğeni/yorum sayısı, konum satırı ("Okchiloha Bay") ve öbür satırlar çevrilmez.
    private static func captions(_ lines: [Line], order: [Int], median: Double) -> [Card] {
        var cards: [Card] = []
        for handle in order where isHandle(lines[handle].text) {
            let head = lines[handle]
            var taken: [Int] = []
            var last = head
            for index in order where isWords(lines[index].text) {
                let line = lines[index]
                guard line.spot.top >= head.spot.top + head.height * 0.5 else { continue }
                let gap = line.spot.top - last.spot.bottom
                let limit = (taken.isEmpty ? captionGap : rowGap) * max(median, last.height)
                let anchor = taken.isEmpty ? head.spot.left : lines[taken[0]].spot.left
                if gap > limit || abs(line.spot.left - anchor) > captionAlign {
                    // Aynı satırda yan yana okunan parça (emoji satırı böler) ya da aynı satırın ikinci okunuşu.
                    if let first = taken.last, sameBand(lines[first], line) { taken.append(index); continue }
                    break
                }
                taken.append(index)
                last = line
            }
            if !taken.isEmpty { cards.append(Card(lines: withoutRepeats(taken, lines))) }
        }
        return cards
    }

    /// Uygulama ekranının kartları: arada dar boşluk, solda hizalı ve aynı boyda satırlar bir kart. Kartın ilk satırı kısa
    /// bir başlıksa ve alttaki satır yeni bir cümleyle başlıyorsa başlıktır ("Strength Workout" / "Level 3/4"); satırları
    /// sayfadan belirgin büyük kart başlıktır (makale başlığı). "…" ile kesilmiş başlığın ya da cümlenin altındaki ad satırı
    /// haberin kaynağıdır ("Vice City Horn"): çevrilmez.
    private static func appCards(_ lines: [Line], order: [Int], median: Double) -> [Card] {
        var blocks: [[Int]] = []
        for index in order where isWords(lines[index].text) {
            let line = lines[index]
            if let block = blocks.last, let lastIndex = block.last {
                let last = lines[lastIndex], first = lines[block[0]]
                if sameBand(last, line) {
                    blocks[blocks.count - 1].append(index)
                    continue
                }
                let gap = line.spot.top - last.spot.bottom
                let ratio = max(line.height, last.height) / max(1e-6, min(line.height, last.height))
                // Kesik başlığın hemen altındaki satır (kaynak adı, simgesiyle biraz içeride) hizasız da aynı karttır.
                let aligned = abs(line.spot.left - first.spot.left) <= leftAlign || isCut(last.text)
                if gap <= rowGap * max(line.height, last.height), aligned, ratio <= heightRatio {
                    blocks[blocks.count - 1].append(index)
                    continue
                }
            }
            blocks.append([index])
        }
        return blocks.compactMap { block in
            var rows = withoutRepeats(block, lines)
            // Haberin kaynağı: kesik başlığın ya da cümlenin altındaki ad satırı.
            if rows.count >= 2, let tail = rows.last, isName(lines[tail].text),
               rows.dropLast().contains(where: { isCut(lines[$0].text) || endsSentence(lines[$0].text) || lines[$0].words > shortWords }) {
                rows.removeLast()
            }
            guard !rows.isEmpty else { return nil }
            let tall = rows.map { lines[$0].height }.sorted()[(rows.count - 1) / 2] >= median * titleHeight
            var card = Card(lines: rows)
            if tall {
                card.bold = true
            } else if rows.count >= 2, isShort(lines[rows[0]].text),
                      let next = lines[rows[1]].text.first(where: { $0.isLetter || $0.isNumber }),
                      next.isUppercase || next.isNumber, !sameBand(lines[rows[0]], lines[rows[1]]) {
                card.titled = true
            }
            return card
        }
    }

    /// Kartın çevrilecek paragrafları: başlıklı kartta başlık ve gövde, değilse tek paragraf. Satırlar birleşir; satır
    /// sonunda tireyle bölünmüş sözcük boşluksuz.
    static func paragraphs(_ card: Card, _ lines: [Line]) -> [String] {
        func joined(_ part: ArraySlice<Int>) -> String {
            var text = ""
            for index in part {
                let piece = lines[index].text.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { text = piece } else if text.hasSuffix("-") { text += piece } else { text += " " + piece }
            }
            return text
        }
        guard !card.lines.isEmpty else { return [] }
        return card.titled && card.lines.count >= 2
            ? [joined(card.lines.prefix(1)), joined(card.lines.dropFirst())] : [joined(card.lines[...])]
    }

    /// İki satır aynı yükseklikte (dikeyde en az yarı yarıya üst üste).
    static func sameBand(_ a: Line, _ b: Line) -> Bool {
        min(a.spot.bottom, b.spot.bottom) - max(a.spot.top, b.spot.top) >= min(a.height, b.height) * 0.5
    }

    /// Aynı satırın ikinci okunuşu ya da başka bir satırın içinde kalan parçası atılır (Sinan Bey, 3419: "Pick up OFF
    /// THE HOOK" ayrı balon olarak da çiziliyordu). Uzun olan kalır.
    static func withoutRepeats(_ rows: [Int], _ lines: [Line]) -> [Int] {
        func key(_ text: String) -> String {
            var value = text.trimmingCharacters(in: .whitespaces)
            while let last = value.last, last == "." || last == "…" { value.removeLast() }
            return TextMatch.normalize(value)
        }
        return rows.filter { index in
            let mine = key(lines[index].text)
            guard mine.filter(\.isLetter).count >= 4 else { return true }
            return !rows.contains { other in
                guard other != index else { return false }
                let theirs = key(lines[other].text)
                guard theirs.count >= mine.count else { return false }
                // Eşit uzunlukta aynı yazı: önce okunan kalır.
                if theirs == mine { return other < index }
                return theirs.contains(mine)
            }
        }
    }
}
