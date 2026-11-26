// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// GTA 6 haritasında bir göreve ya da konuma basınca açılan bilgi kartı: BÜYÜK HARFLİ görev adı, altında (varsa) kısa
/// alt başlık satırları, bir iki cümlelik açıklama ve en altta kısa ayrıntı satırları (ödül, uzaklık). Kart yazıların
/// dizilişinden tanınır: başlığın hemen altında, aynı sol kenarda başlayan cümle satırları; kart ekranın bir parçası
/// kadar dardır, yardım kutularının durduğu sol üst köşede değildir ve (kare varsa) düz bir panelin üstündedir.
///
/// Tanınan kartın parçaları ayrı ayrı çevrilir ve kendi yerlerinde, özgün stilde çizilir (başlık büyük harfle): başlık
/// açıklamanın ilk cümlesine katılmaz, uzun başlık da ayrı kalır. Otomatik ekran yazısında kart "Görev ve hedef yazısı"
/// türündendir (`ScreenTextKind.mission`), menüde açılsa da. Windows (MissionCard.cs) ve Android (MissionCard.kt) aynı
/// kuralları ve eşikleri uygular; ortak deneme dosyası Fixtures/mission-card.json.
enum MissionCard {
    /// Başlık en çok bu kadar sözcük.
    static let titleWords = 7
    /// Açıklamanın ilk satırı başlığın altından en çok başlık yüksekliğinin bu katı aşağıda başlar.
    static let titleGap = 1.4
    /// Açıklama satırları arasında en çok satır yüksekliğinin bu katı boşluk; paragraf arası `paragraphGap`.
    static let lineGap = 1.0, paragraphGap = 2.2
    /// Ayrıntı satırları (ödül, uzaklık) açıklamanın altından en çok bu kat aşağıda ve en çok `detailWords` sözcük.
    static let detailGap = 1.8, detailWords = 5
    /// Sol kenarların hizası, satır yüksekliğinin bu katı (kare 16:9 sayılır; yatayda ~1 harf).
    static let alignment = 0.9
    /// Kart ekranın en çok bu kadarı genişliğindedir (tam genişlik yazı kart değildir).
    static let maxWidth = 0.55
    /// Açıklama en az bu kadar sözcük.
    static let bodyWords = 6
    /// Başlığın solundaki görev resmi en çok başlık yüksekliğinin bu katı genişliktedir; açıklama resmin altından başlar.
    static let pictureWidth = 2.5

    /// Bulunan kart: satırların sırası (verilen dizide), yukarıdan aşağı.
    struct Card: Equatable {
        var title: [Int]
        var subtitles: [Int]
        var body: [Int]
        var details: [Int]
        /// Konum kartı (#1391: dükkân, garaj; başlığı yer adı, `isPlaceTitle`): başlık çevrilmez, açıklama tek paragraf.
        var place = false
        var all: [Int] { title + subtitles + body + details }
    }

    /// Satırlardaki kartlar. `lines` kareye oranla yerleşmiş (kutusu olmayan satır atlanır); `place` verilirse kutular o
    /// alana oranlıdır ve önce kareye taşınır.
    static func find(_ lines: [TextLine], place: TextBox? = nil) -> [Card] {
        let boxes: [TextBox?] = lines.map { line in line.box.map { place.map($0.placed) ?? $0 } }
        let order = lines.indices.filter { boxes[$0] != nil }.sorted { boxes[$0]!.top < boxes[$1]!.top }
        var used = Set<Int>()
        var cards: [Card] = []
        func height(_ i: Int) -> Double { boxes[i]!.bottom - boxes[i]!.top }
        func aligned(_ i: Int, _ j: Int, _ h: Double) -> Bool { abs(boxes[i]!.left - boxes[j]!.left) <= h * alignment * 9 / 16 }
        for (position, start) in order.enumerated() where !used.contains(start) && isTitle(lines[start].text) {
            var title = [start], subtitles: [Int] = [], body: [Int] = [], details: [Int] = []
            // Kartın sütunu: başlığın sol kenarının tümüyle solunda biten ya da kart genişliğinden sağda başlayan satır
            // (haritada kartın yanındaki uzaklık "124 ft", simge kırıntısı, yan menü) karta ait değildir; kartın satırları
            // arasına girip kartı bölüyordu (X: chiaki, harita kartı tanınmıyor, çevirisi sola kayıyordu).
            func inColumn(_ i: Int) -> Bool {
                boxes[i]!.right > boxes[start]!.left && boxes[i]!.left < boxes[start]!.left + maxWidth
            }
            var rest = order[(position + 1)...].filter { !used.contains($0) && inColumn($0) }[...]
            // Açıklamanın ilk satırı: cümle satırı ya da sözcükleri cümle gibi yazılmış kısa satır ("Nautical-themed
            // souvenir") ki altında küçük harfle süren cümle satırı var; böyle satır alt başlık değildir.
            func opensBody(_ i: Int, _ after: ArraySlice<Int>) -> Bool {
                // Fiyatla başlayan kısa satır ("$150 - Collectibles to sell") alt başlıktır: açıklamaya katılıp cümleyi bozuyordu (#1391).
                if startsWithPrice(lines[i].text), words(lines[i].text) <= detailWords { return false }
                if isSentence(lines[i].text) { return true }
                guard sentenceCased(lines[i].text, words: 2), let next = after.first, aligned(next, i, height(i)),
                      lines[next].text.first?.isLowercase == true, isSentence(lines[next].text),
                      abs(height(next) - height(i)) <= height(i) * 0.3,
                      boxes[next]!.top - boxes[i]!.bottom <= height(i) * lineGap else { return false }
                return true
            }
            // Başlık iki satıra sarılmış olabilir.
            if let next = rest.first, isTitle(lines[next].text), aligned(next, start, height(start)),
               boxes[next]!.top - boxes[start]!.bottom <= height(start) * 0.6 {
                title.append(next)
                rest = rest.dropFirst()
            }
            var last = title.last!
            let titleHeight = height(start)
            while let next = rest.first, !opensBody(next, rest.dropFirst()), words(lines[next].text) <= detailWords,
                  !isTitle(lines[next].text), aligned(next, start, titleHeight),
                  boxes[next]!.top - boxes[last]!.bottom <= titleHeight * titleGap {
                subtitles.append(next)
                last = next
                rest = rest.dropFirst()
            }
            // Başlığın solunda görev resmi (portre) olabilir: açıklama resmin altından, başlıktan daha solda başlar (#856).
            func underTitle(_ i: Int) -> Bool {
                aligned(i, start, titleHeight) || (boxes[i]!.left < boxes[start]!.left
                    && boxes[start]!.left - boxes[i]!.left <= titleHeight * pictureWidth * 9 / 16)
            }
            guard let first = rest.first, opensBody(first, rest.dropFirst()), underTitle(first),
                  boxes[first]!.top - boxes[last]!.bottom <= titleHeight * titleGap,
                  height(first) <= titleHeight * 1.1 else { continue }
            let line = height(first)
            body = [first]
            last = first
            rest = rest.dropFirst()
            // Alt satır cümlenin devamı: yazı boyu benzer; küçük harfle başlayan kısa son satır ("treasure.") harfleri
            // kısa diye daha alçak okunabilir. Sıradaki görevin BÜYÜK HARFLİ başlığı açıklamaya katılmaz (görev listesi).
            // Bitmemiş cümlenin altındaki bir iki sözcüklük kısa satır ("No", "and") harfleri kısa diye daha alçak okunsa da
            // cümlenin devamıdır: ayrıntı sanılıp tek başına çevriliyordu ("Hayır!", #1391).
            func shortTail(_ next: Int) -> Bool {
                words(lines[next].text) <= tailWords && height(next) >= line * 0.5 && height(next) <= line * 1.5
                    && !SubtitleStabilizer.endsSentence(lines[last].text.trimmingCharacters(in: .whitespaces))
            }
            while let next = rest.first, aligned(next, first, line), !isTitle(lines[next].text),
                  abs(height(next) - line) <= line * 0.3 || shortTail(next)
                    || (lines[next].text.first?.isLowercase == true && height(next) <= line * 1.5
                        && !SubtitleStabilizer.endsSentence(lines[last].text.trimmingCharacters(in: .whitespaces))) {
                let gap = boxes[next]!.top - boxes[last]!.bottom
                // Satır ya cümlenin devamı (dar boşluk) ya da yeni bir açıklama paragrafı: daha geniş boşluk, önceki satır
                // cümleyi bitirmiş ve yeni satır ayrıntı satırından uzun bir cümle ("Distance 2.4 mi" ayrıntıdır).
                let paragraph = gap <= line * paragraphGap && isSentence(lines[next].text) && words(lines[next].text) > 3
                    && SubtitleStabilizer.endsSentence(lines[last].text.trimmingCharacters(in: .whitespaces))
                guard gap <= line * lineGap || paragraph else { break }
                body.append(next)
                last = next
                rest = rest.dropFirst()
            }
            let right = body.map { boxes[$0]!.right }.max()!
            // Altında cümle olan BÜYÜK HARFLİ satır ayrıntı değil, sıradaki görevin başlığıdır.
            func nextTitle(_ i: Int) -> Bool {
                guard isTitle(lines[i].text), let after = order.first(where: { boxes[$0]!.top > boxes[i]!.bottom - 1e-9 && $0 != i })
                else { return false }
                return isSentence(lines[after].text) && boxes[after]!.top - boxes[i]!.bottom <= height(i) * titleGap
            }
            while let next = rest.first, !nextTitle(next), words(lines[next].text) <= detailWords, height(next) <= line * 1.3,
                  boxes[next]!.top - boxes[last]!.bottom <= line * detailGap,
                  aligned(next, first, line) || abs(boxes[next]!.right - right) <= line * alignment * 9 / 16 {
                details.append(next)
                last = next
                rest = rest.dropFirst()
            }
            let card = Card(title: title, subtitles: subtitles, body: body, details: details,
                            place: isPlaceTitle(title.map { lines[$0].text }.joined(separator: " ")))
            let span = card.all.map { boxes[$0]! }
            guard body.reduce(0, { $0 + words(lines[$1].text) }) >= bodyWords,
                  span.map(\.right).max()! - span.map(\.left).min()! <= maxWidth else { continue }
            used.formUnion(card.all)
            cards.append(card)
        }
        return cards
    }

    /// Başlık: en az üç harf, harflerinin çoğu büyük, en çok `titleWords` sözcük, nokta ile bitmez.
    static func isTitle(_ text: String) -> Bool {
        let plain = IconText.plain(text).trimmingCharacters(in: .whitespaces)
        return plain.filter(\.isLetter).count >= 3 && TextStyleSampler.isUpper(plain) && (1...titleWords).contains(words(plain))
            && !plain.hasSuffix(".")
    }

    /// Cümle satırı: en az üç sözcük, harflerinin en az %40'ı küçük ve ilkinden sonra küçük harfle başlayan bir sözcüğü
    /// var (her sözcüğü büyük harfle başlayan "Lucia · Story Mission" alt başlıktır).
    static func isSentence(_ text: String) -> Bool { sentenceCased(text, words: 3) }

    /// En az `words` sözcük, harflerin en az %40'ı küçük, ilkinden sonra küçük harfle başlayan sözcük var.
    static func sentenceCased(_ text: String, words: Int) -> Bool {
        let letters = text.filter(\.isLetter)
        let parts = text.split(whereSeparator: \.isWhitespace)
        return parts.count >= words && !letters.isEmpty && Double(letters.filter(\.isLowercase).count) >= 0.4 * Double(letters.count)
            && parts.dropFirst().contains { $0.first?.isLowercase == true }
    }

    private static func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// Açıklamanın sonuna katılan kısa satır en çok bu kadar sözcük (`shortTail`).
    static let tailWords = 2

    /// Satır fiyatla başlıyor ("$150 - Collectibles to sell", "150$").
    static func startsWithPrice(_ text: String) -> Bool {
        guard let first = IconText.plain(text).trimmingCharacters(in: .whitespaces).split(separator: " ").first else { return false }
        return first.first.map { "$€£".contains($0) || $0.isNumber } == true && first.contains(where: \.isNumber)
    }

    /// Konum kartının başlığı bir yer adıdır (#1391, GTA 6 haritası: "PAY 'N' SPRAY - PORT GELLHORN", "BUCK'S JEWELRY &
    /// PAWN", "PAWN GUN - PORT GELLHORN"): çevrilmez, özgün yazı görünür kalır. Motor yer adını sözcük sözcük çeviriyor
    /// ("LİMAN GELLHORN"), başlığı açıklamayla bir tutup kartın üstüne taşan tek kutu çiziyordu. Görev başlığı ("STEAL
    /// VEHICLES FOR MOSES", fiille başlar) değildir. Yer adı: "AD - SEMT", iyelik ("BUCK'S"), "&", "'N'" ya da son sözcüğü
    /// işletme/yer türü. Windows ve Android aynı.
    static func isPlaceTitle(_ text: String) -> Bool {
        let plain = IconText.plain(text).trimmingCharacters(in: .whitespaces)
        guard TextStyleSampler.isUpper(plain) else { return false }
        let tokens = plain.split(separator: " ").map { String($0).uppercased(with: Locale(identifier: "en_US_POSIX")) }
        guard let first = tokens.first, !missionVerbs.contains(first) else { return false }
        if tokens.contains(where: { $0 == "-" || $0 == "–" || $0 == "&" || $0 == "'N'" || $0 == "’N’" }) { return true }
        if tokens.contains(where: { $0.count > 2 && ($0.hasSuffix("'S") || $0.hasSuffix("’S")) }) { return true }
        return tokens.last.map { placeNouns.contains($0) } ?? false
    }

    /// Görev başlığını açan fiiller (BÜYÜK HARFLİ başlıkta; `UiCommands.titleVerbs` ve haritadaki görev türleri).
    static let missionVerbs: Set<String> = ["HIT", "ROB", "MEET", "VISIT", "FIND", "CHECK", "GO", "HEAD", "RETURN", "CALL",
                                            "FOLLOW", "STEAL", "PROTECT", "CHASE", "RESCUE", "DEFEND", "EXPLORE",
                                            "INVESTIGATE", "PICK", "HELP", "DELIVER", "COLLECT", "ESCAPE", "KILL", "TAKE",
                                            "GET", "LOSE", "DESTROY", "DRIVE", "BUY", "SELL", "WIN", "SURVIVE"]

    /// Konum kartı başlığının son sözcüğü olan işletme ve yer türleri.
    static let placeNouns: Set<String> = ["PAWN", "GARAGE", "CABARET", "CLUB", "BAR", "DINER", "MOTEL", "HOTEL", "SHOP",
                                          "STORE", "BANK", "MARKET", "SALON", "GYM", "CLINIC", "HOSPITAL", "DEALERSHIP",
                                          "CUSTOMS", "LOUNGE", "CASINO", "MARINA", "PIER", "MALL", "PLAZA", "MOTORS",
                                          "AUTOS", "TATTOO", "BARBER", "CAFE", "RESTAURANT", "NIGHTCLUB", "THEATER",
                                          "THEATRE", "ARCADE", "AMMU-NATION", "SPRAY", "BOWLING", "LIQUOR", "PHARMACY"]

    /// Kartın kutusu yardım kutularının durduğu sol üst köşede mi (oradaki başlıklı kutu bir ipucudur, görev kartı değil).
    static func inHelpCorner(_ box: TextBox) -> Bool { box.left < 0.25 && box.top < 0.3 }

    /// Kart paneli düz zemin sayılırken izin verilen sapma, düz zemin eşiğinin bu katı.
    static let panelSlack = 1.5

    /// Kartın yazıları düz bir panelin üstünde mi (harita ya da oyun dünyasının dokulu zemininde duran yazı kart değildir).
    /// Harita kartı yarı saydamdır: arkadaki harita zemini satırdan satıra biraz değiştirir, sıkıştırılmış görüntüde harf
    /// kenarları da zemine karışır; kart bu yüzden düz zemin eşiğinin `panelSlack` katına kadar paneldir (X: chiaki,
    /// harita kartı tanınmıyordu). Dokulu dünya zemini bu sınırın çok üstündedir.
    static func onPanel(_ frame: CGImage, _ lines: [TextLine]) -> Bool {
        let boxes = lines.compactMap(\.box)
        guard let first = boxes.first else { return false }
        let box = boxes.dropFirst().reduce(first) { $0.union($1) }
        return TextStyleSampler.sample(frame, box: box, lines: lines, source: lines.map(\.text).joined(separator: " "),
                                       flatLimit: TextStyleSampler.flatDeviation * panelSlack).look.flat
    }

    /// Kartın çeviri grupları: başlık (sarılmışsa tek parça), alt başlıklar ve ayrıntılar tek tek, açıklama paragraflarıyla.
    static func groups(_ card: Card, _ lines: [TextLine]) -> [ScreenTranslation.Group] {
        func group(_ indices: [Int], joined: Bool) -> ScreenTranslation.Group {
            let own = indices.map { lines[$0] }
            let boxes = own.map(\.box!)
            let heights = boxes.map { $0.bottom - $0.top }.sorted()
            let icons = ScreenTranslation.paragraphIcons(own)
            let paragraphs = joined ? [own.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")]
                : ScreenTranslation.paragraphs(own)
            let slots = joined ? [icons.flatMap { $0 }] : icons
            var made = ScreenTranslation.Group(paragraphs: paragraphs, box: boxes.dropFirst().reduce(boxes[0]) { $0.union($1) },
                                               lineHeight: heights[heights.count / 2],
                                               icons: slots.contains { !$0.isEmpty } ? slots : nil)
            made.rows = ScreenTranslation.rows(own)
            return made
        }
        // Konum kartında başlık (yer adı) çevrilmez; açıklamanın sarılmış satırları tek cümle olarak birlikte çevrilir ve
        // tek blokta çizilir (#1391: satır satır bölünüp yarısı çevriliyordu).
        return (card.place ? [] : [group(card.title, joined: true)]) + card.subtitles.map { group([$0], joined: true) }
            + [group(card.body, joined: card.place)] + card.details.map { group([$0], joined: true) }
    }
}
