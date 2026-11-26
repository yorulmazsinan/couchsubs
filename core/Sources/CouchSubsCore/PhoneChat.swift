// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// "Ekranı çevir"de GTA 6 telefonunun ekranındaki satırlar: önce telefonun düz ekranına taşınır (`ScreenPhoneCard.Handset`,
/// eğik telefonda da sol/sağ kenar ekranın kenarına göre ölçülür), sonra ekranın ne olduğu çıkarılır. Sohbet ekranında
/// her balon bir parça olur (balonun satırları birleşir); balon telefonun hangi kenarına yaslıysa gelen ya da giden
/// mesajdır. Sohbet listesinde kişi adları çevrilmez, son mesaj önizlemeleri çevrilir. Ana ekran (hava durumu, bildirim
/// sayacı, simge ızgarası) sohbet değildir: yazıları panelde kart olur, uygulama adları çevrilmez; öbür sohbet dışı ekranlar
/// (gönderi, haber, makale, fitness, ayarlar) `PhoneScreen` kartlarıdır. Windows (PhoneChat.cs) ve Android
/// (PhoneChat.kt) aynı kuralları ve eşikleri uygular; ortak deneme dosyası Fixtures/phone-chat.json.
enum PhoneChat {
    /// Satır, merkezi düz ekranda bu payla dışarıda kalsa da telefonundur (kutular kenarda biraz taşabilir).
    static let insideSlack = 0.05
    /// Düz ekranda bu kadar dışarı taşan satır telefonun yazısı değildir (telefonun arkasından geçen altyazı, tabela).
    static let outsideReach = 0.3
    /// Ekranın üst/alt kenarından bu kadar dışarı taşan satır kesiktir (sohbet kaymış, satırın yarısı görünüyor).
    static let edgeCut = 0.015
    /// Kesik satır: yüksekliği ortanca satırın bu kadarından az (başlığın altına girmiş ilk satır, alt kenardaki son satır).
    static let cutHeight = 0.6
    /// Fotoğrafın içindeki yazı: ortanca satırın bu kadar katından yüksek (en az üç satır varken).
    static let photoHeight = 2.0
    /// Aynı balonun iki satırı arasındaki boşluk ortanca satır yüksekliğinin bu kadarından az; balonlar arası daha geniş.
    static let bubbleGap = 0.6
    /// Aynı balonun satırları solda bu kadar hizalı (ekran genişliğine oranla); sağa yaslı balonda sağda `rightAlign`.
    static let leftAlign = 0.04, rightAlign = 0.03
    /// Kenar payı oranı: balonun bir yandaki payı öbür yandakinin bu kadarından azsa o yana yaslıdır.
    static let sideRatio = 0.6
    /// İki yanı da bundan dar balon (ekranı dolduran uzun mesaj) yaslı sayılmaz; tarafı balonun rengi söyler.
    static let wideMargin = 0.15
    /// Ortalı kısa satır (saat, "Today", "Delivered"): merkezi ortadan en çok bu kadar uzak, iki yanda en az `noteMargin` pay.
    static let noteCenter = 0.06, noteMargin = 0.2
    /// Başlık (kişi adı): ekranın üst bu kadarında, ortalıysa merkezi ortadan en çok `headerCenter` uzak.
    static let headerBand = 0.2, headerCenter = 0.12
    /// Aynı satırda yan yana okunan parçalar (emoji satırı böler) aradaki boşluk satır yüksekliğinin bu katından azsa birleşir.
    static let rowJoin = 2.0

    /// Düz ekrandaki satır.
    struct Row {
        var lines: [TextLine]
        /// Düz ekrandaki yeri (0–1, ekranın kenarlarına göre).
        var spot: TextBox
        var text: String
        var height: Double { spot.bottom - spot.top }
        var center: Double { (spot.left + spot.right) / 2 }
        var words: Int { text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Telefonun içinde mi (merkezi düz ekranda, satır ekranın dışına taşmıyor).
    static func onScreen(_ spot: TextBox) -> Bool {
        let u = (spot.left + spot.right) / 2, v = (spot.top + spot.bottom) / 2
        return u >= -insideSlack && u <= 1 + insideSlack && v >= -insideSlack && v <= 1 + insideSlack
            && spot.left >= -outsideReach && spot.right <= 1 + outsideReach
    }

    /// Ana ekranda yan yana okunan parçalar yalnız bu kadar yakınsa birleşir (simge etiketleri arasında daha geniş boşluk var).
    static let homeJoin = 1.0
    /// Ana ekranda bir bloğun (bileşen başlığı ve içeriği, bildirimin satırları) iki satırı arasındaki boşluk ortanca satırın
    /// bu kadarından az.
    static let homeGap = 0.8
    /// Simge ızgarası: aynı hizada en az bu kadar uygulama adı.
    static let gridLabels = 3
    /// Hava durumu ("76°", "24 °C") ve bildirim sayacı ("10 Notifications", "3 new messages"): yalnız ana ekranda olur.
    private static let weather = try! NSRegularExpression(pattern: #"^[-−]?\d{1,3}\s?[°º˚]\s?[CFcf]?$"#)
    private static let counter = try! NSRegularExpression(
        pattern: #"^\d{1,3}\s+(?:new\s+)?(?:notifications?|reminders?|alerts?|messages?|missed\s+calls?|e-?mails?|updates?)$"#,
        options: .caseInsensitive)

    /// Telefonun satırlarını (kutuları bilinen, süzülmüş) parçalara ayırır; her grup `phone` bilgisini taşır. `raw`:
    /// telefondaki süzülmemiş satırlar (harfsiz satırlar da: hava durumu ana ekranı belli eder).
    static func groups(_ lines: [TextLine], handset: ScreenPhoneCard.Handset, raw: [TextLine] = []) -> [ScreenTranslation.Group] {
        let single = lines.compactMap { line in
            line.box.map { Row(lines: [line], spot: handset.flat($0), text: clean(line.text)) }
        }.filter { $0.text.filter(\.isLetter).count >= 2 }.sorted { $0.spot.top < $1.spot.top }
        var rows = joinedRows(single)
        guard !rows.isEmpty else { return [] }
        let median = rows.map(\.height).sorted()[rows.count / 2]
        rows.removeAll { $0.spot.top < -edgeCut || $0.spot.bottom > 1 + edgeCut }
        // Ana ekran (saat, hava, bileşenler, simge ızgarası) sohbet değildir: yazıları panelde kart olur.
        let home = joinedRows(single, join: homeJoin).filter { $0.spot.top >= -edgeCut && $0.spot.bottom <= 1 + edgeCut }
        if isHome(home, raw: raw) { return homeGroups(home, median: median, handset: handset) }
        var header: Row?
        if let first = rows.first, isHeader(first) {
            header = first
            rows.removeFirst()
        }
        if rows.count >= 3 { rows.removeAll { $0.height > median * photoHeight } }
        // Kaymış sohbetin en üstteki ve en alttaki yarım satırı okunmaz, çevrilmez.
        if let first = rows.first, first.height < median * cutHeight { rows.removeFirst() }
        if let last = rows.last, last.height < median * cutHeight { rows.removeLast() }

        var result: [ScreenTranslation.Group] = []
        if let list = contactList(rows, median: median) {
            // Listenin başındaki ortalı olmayan başlık bir kişi değil bölüm adıdır ("Messages"): çevrilir.
            if let header { result.append(group([header], role: abs(header.center - 0.5) <= headerCenter ? .header : .heading, handset: handset)) }
            for (index, row) in rows.enumerated() { result.append(group([row], role: list[index], handset: handset)) }
            return result
        }
        // Sohbet dışı ekran (gönderi, haber, makale, hava, fitness, ayarlar, eklenti): kartlar (`PhoneScreen`; otomatik
        // telefon okumasıyla aynı kural).
        if let cards = screenGroups(raw.isEmpty ? lines : raw, handset: handset) { return cards }
        if let header { result.append(group([header], role: .header, handset: handset)) }
        var bubble: [Row] = []
        func finish() {
            guard !bubble.isEmpty else { return }
            result.append(group(bubble, role: role(of: bubble), handset: handset))
            bubble.removeAll()
        }
        for row in rows {
            if let last = bubble.last, !continues(row, after: last, first: bubble[0], median: median) { finish() }
            bubble.append(row)
        }
        finish()
        return result
    }

    /// Satırın başındaki ve sonundaki harfsiz, rakamsız kırıntılar (emoji ya da simge yanlış okunmuş: "©", "•", "♡") atılır.
    static func clean(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func junk(_ word: String) -> Bool {
            // Para simgesi ("$ in your mailbox") mesajın parçasıdır.
            !word.contains(where: { $0.isLetter || $0.isNumber || $0.unicodeScalars.first?.properties.generalCategory == .currencySymbol })
                && !word.allSatisfy { ".,!?…'\"-:;()".contains($0) }
        }
        while let first = words.first, junk(first) { words.removeFirst() }
        while let last = words.last, junk(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Aynı yükseklikte yan yana okunmuş parçalar (arada emoji ya da simge) tek satır olur.
    static func joinedRows(_ rows: [Row], join: Double = rowJoin) -> [Row] {
        var result: [Row] = []
        for row in rows {
            if let index = result.lastIndex(where: { sameRow($0, row, join: join) }) {
                let (a, b) = result[index].spot.left <= row.spot.left ? (result[index], row) : (row, result[index])
                result[index] = Row(lines: a.lines + b.lines, spot: a.spot.union(b.spot), text: a.text + " " + b.text)
            } else {
                result.append(row)
            }
        }
        return result.sorted { $0.spot.top < $1.spot.top }
    }

    private static func sameRow(_ a: Row, _ b: Row, join: Double) -> Bool {
        guard sameBand(a, b) else { return false }
        let gap = max(a.spot.left, b.spot.left) - min(a.spot.right, b.spot.right)
        // Yatay boşluk ekran genişliğine, satır yüksekliği ekran yüksekliğine oranla; ikisi aynı ölçüye çevrilir.
        return gap * ScreenPhoneCard.Handset.screenShape <= max(a.height, b.height) * join
    }

    /// İki satır aynı yükseklikte (dikeyde en az yarı yarıya üst üste).
    private static func sameBand(_ a: Row, _ b: Row) -> Bool {
        min(a.spot.bottom, b.spot.bottom) - max(a.spot.top, b.spot.top) >= min(a.height, b.height) * 0.5
    }

    /// Ana ekran mı: hava durumu satırı, bildirim sayacı ("10 Notifications") ya da aynı hizada en az üç uygulama adı
    /// (simge ızgarası). Sohbette bunların hiçbiri olmaz; tek başına kısa bir yanıt ("Ok") ana ekran sayılmaz.
    static func isHome(_ rows: [Row], raw: [TextLine]) -> Bool {
        if raw.contains(where: { matches(weather, $0.text.trimmingCharacters(in: .whitespaces)) }) { return true }
        if rows.contains(where: { matches(counter, $0.text) }) { return true }
        let labels = rows.filter { isAppLabel($0.text) && ($0.spot.top + $0.spot.bottom) / 2 >= headerBand }
        return labels.contains { label in labels.filter { sameBand($0, label) }.count >= gridLabels }
    }

    /// Uygulama başlatıcı (gerçek ana ekran): bildirim sayacı ya da simge ızgarası var. Yalnız hava satırı ("71°") olan
    /// ekran hava uygulamasıdır: oradaki tek sözcüklük satırlar ("Now", "Sunset") uygulama adı değildir, çevrilir
    /// (Sinan Bey, beta.100 3422).
    static func isLauncher(_ rows: [Row]) -> Bool {
        if rows.contains(where: { matches(counter, $0.text) }) { return true }
        let labels = rows.filter { isAppLabel($0.text) && ($0.spot.top + $0.spot.bottom) / 2 >= headerBand }
        return labels.contains { label in labels.filter { sameBand($0, label) }.count >= gridLabels }
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Uygulama adı gibi: bir-iki sözcük, hepsi harf ve büyük harfle başlıyor, rakam ve noktalama yok ("WhatUp", "Camera").
    static func isAppLabel(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard (1...2).contains(words.count) else { return false }
        return words.allSatisfy { word in
            word.first?.isUppercase == true && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "&" }
        }
    }

    /// Ana ekranın blokları: arada dar boşluk ve solda aynı hizada duran satırlar (bileşenin başlığı ve içeriği, bildirimin
    /// satırları) bir blok; yan yana duranlar ayrı.
    static func homeBlocks(_ rows: [Row], median: Double) -> [[Row]] {
        var blocks: [[Row]] = []
        for row in rows {
            // Bileşenin sayacı ("6 Notifications") başlığın altındadır ama başlığın solunda simge olduğundan sol hizası
            // başlıktan önde başlar: yine aynı bloktur (`widgetIndent` kadar).
            if let last = blocks.last?.last, let first = blocks.last?.first, row.spot.top - last.spot.bottom < median * homeGap,
               row.spot.top >= last.spot.top, !sameBand(row, last),
               abs(row.spot.left - first.spot.left) <= leftAlign
                || (blocks.last?.count == 1 && isCounter(row.text) && first.spot.left - row.spot.left <= widgetIndent
                    && row.spot.left <= first.spot.left) {
                blocks[blocks.count - 1].append(row)
            } else {
                blocks.append([row])
            }
        }
        return blocks
    }

    /// Bileşen başlığının solundaki simgenin payı (düz ekran genişliğine oranla).
    static let widgetIndent = 0.2

    /// Bildirim sayacı ("6 Notifications", "3 new messages").
    static func isCounter(_ text: String) -> Bool { matches(counter, text.trimmingCharacters(in: .whitespaces)) }

    /// Ana ekran bileşeni: kısa başlık ve hemen altında sayaç ("Reminders / 6 Notifications"). Sinan Bey (beta.100,
    /// 3397): bileşen çevrilmiyordu; panelde tek kart olur (`ScreenPhoneCard.Role.widget`).
    static func isWidget(_ block: [Row]) -> Bool {
        block.count == 2 && isCounter(block[1].text) && !isCounter(block[0].text) && (1...3).contains(block[0].words)
    }

    /// Blok tek başına duran kısa bir ad: uygulamanın adı (simge etiketi, "WhatUp"); çevrilmez.
    static func isAppName(_ block: [Row]) -> Bool { block.count == 1 && isAppLabel(block[0].text) }

    /// Otomatik telefon panelinin (`GamePhoneText.groups`) satırları ana ekransa uygulama adları atılmış hâli; saat ve hava
    /// ve harfsiz satırlar atılır, bileşen ve bildirim yazıları kalır (panelde kart). Satırların yeri düz ekranda
    /// (`phoneBox`) bilinmiyorsa ya da ekran ana ekran değilse satırlar olduğu gibi döner ("Ekranı çevir" ile aynı kural).
    static func withoutAppNames(_ lines: [TextLine]) -> [TextLine] {
        guard isHomeScreen(lines) else { return lines }
        let rows = homeRows(lines)
        let median = rows.map(\.height).sorted()[rows.count / 2]
        let names = isLauncher(rows) ? homeBlocks(rows, median: median).filter(isAppName).flatMap { $0[0].lines } : []
        // Saat ("7PM", "10 PM") çevrilmez (Sinan Bey, beta.100 3422: "10PM" "22:00" yazılıyordu).
        return lines.filter { line in
            line.text.filter(\.isLetter).count >= 2 && !PhoneScreen.isTime(line.text)
                && !names.contains { $0.text == line.text && $0.phoneBox == line.phoneBox }
        }
    }

    /// Satırlar (düz ekrandaki yerleri bilinen) telefonun ana ekranı mı (`isHome`); sohbet panelinde ana ekran yazıları
    /// `home` rolünde kalır (`GamePhoneText.roles`).
    static func isHomeScreen(_ lines: [TextLine]) -> Bool {
        guard !lines.isEmpty, lines.allSatisfy({ $0.phoneBox != nil }) else { return false }
        let rows = homeRows(lines)
        return !rows.isEmpty && isHome(rows, raw: lines)
    }

    private static func homeRows(_ lines: [TextLine]) -> [Row] {
        let single = lines.indices.map { Row(lines: [lines[$0]], spot: lines[$0].phoneBox!, text: clean(lines[$0].text)) }
            .filter { $0.text.filter(\.isLetter).count >= 2 }.sorted { $0.spot.top < $1.spot.top }
        return joinedRows(single, join: homeJoin)
    }

    /// Ana ekranın yazıları: bir arada duran satırlar (bileşenin başlığı ve içeriği, bildirimin satırları) birer blok, her
    /// satır kendi yerinde ayrı çevrilir (alt satıra sarılmış cümle birleşir). Tek başına duran kısa ad (simge etiketi,
    /// "WhatUp") gerçek ana ekranda (`isLauncher`) uygulamanın adıdır, çevrilmez; saat ("7PM") çevrilmez. Gruplar `home`
    /// rolündedir: panelde kart olur (Sinan Bey, beta.100 3422: telefonun üstüne yazılmaz).
    static func homeGroups(_ rows: [Row], median: Double, handset: ScreenPhoneCard.Handset) -> [ScreenTranslation.Group] {
        var result: [ScreenTranslation.Group] = []
        let launcher = isLauncher(rows)
        for block in homeBlocks(rows.filter { !PhoneScreen.isTime($0.text) }, median: median) {
            if launcher, isAppName(block) { continue }
            if isWidget(block) {
                var widget = group([block[0]], role: .widget, handset: handset)
                widget.paragraphs = [block[0].text, block[1].text]
                let boxes = block.flatMap(\.lines).compactMap(\.box)
                widget.box = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
                widget.phone = ScreenPhoneCard.Placement(role: .widget, spot: block[0].spot.union(block[1].spot))
                result.append(widget)
                continue
            }
            var piece: [Row] = []
            for row in block {
                if let last = piece.last, !(row.text.first(where: \.isLetter)?.isLowercase == true && !endsSentence(last.text)) {
                    result.append(group(piece, role: .home, handset: handset))
                    piece.removeAll()
                }
                piece.append(row)
            }
            if !piece.isEmpty { result.append(group(piece, role: .home, handset: handset)) }
        }
        return result
    }

    /// Sohbet dışı ekranın kartları (`PhoneScreen.kind`/`cards`, satırların düz ekrandaki yeriyle); ekran sohbetse nil.
    /// Ekranın üst/alt kenarından taşan kesik satırlar kartlara girmez.
    static func screenGroups(_ lines: [TextLine], handset: ScreenPhoneCard.Handset) -> [ScreenTranslation.Group]? {
        let boxed = lines.filter { $0.box != nil }
        let all = boxed.map { PhoneScreen.Line(text: clean($0.text), spot: handset.flat($0.box!)) }
        let kind = PhoneScreen.kind(all)
        guard kind != .chat else { return nil }
        var result: [ScreenTranslation.Group] = []
        for card in PhoneScreen.cards(all, kind: kind) {
            let rows = card.lines.filter { all[$0].spot.top >= -edgeCut && all[$0].spot.bottom <= 1 + edgeCut }
            guard !rows.isEmpty else { continue }
            let titled = card.titled && rows.count >= 2 && rows[0] == card.lines[0]
            let paragraphs = PhoneScreen.paragraphs(PhoneScreen.Card(lines: rows, titled: titled, bold: card.bold), all)
            let boxes = rows.map { boxed[$0].box! }, spots = rows.map { all[$0].spot }
            let heights = spots.map { $0.bottom - $0.top }.sorted()
            var group = ScreenTranslation.Group(paragraphs: paragraphs, box: boxes.dropFirst().reduce(boxes[0]) { $0.union($1) },
                                                lineHeight: heights[(heights.count - 1) / 2] * handset.screenHeight)
            group.phone = ScreenPhoneCard.Placement(role: .card, spot: spots.dropFirst().reduce(spots[0]) { $0.union($1) },
                                                    titled: titled, bold: card.bold)
            result.append(group)
        }
        return result
    }

    /// Başlık: ekranın en üstündeki kısa, cümle olmayan satır; ortalı ya da (solda avatarın yanında) ad gibi yazılmış.
    static func isHeader(_ row: Row) -> Bool {
        let v = (row.spot.top + row.spot.bottom) / 2
        guard v < headerBand, (1...4).contains(row.words), !endsSentence(row.text) else { return false }
        return abs(row.center - 0.5) <= headerCenter || looksLikeName(row.text)
    }

    /// Ad gibi: bir-üç sözcük, her biri büyük harf ya da rakamla başlar, virgül ve cümle sonu yok.
    static func looksLikeName(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard (1...3).contains(words.count), !text.contains(","), !endsSentence(text) else { return false }
        return words.allSatisfy { word in word.first.map { $0.isUppercase || $0.isNumber } ?? false }
    }

    static func endsSentence(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).last.map { ".!?…".contains($0) } ?? false
    }

    /// Sohbet listesi: en az iki "ad + hemen altında aynı hizada önizleme" çifti ve satırların çoğu bu çiftlerde. Liste
    /// ise her satırın rolü, değilse nil.
    static func contactList(_ rows: [Row], median: Double) -> [ScreenPhoneCard.Role]? {
        var roles = [ScreenPhoneCard.Role](repeating: .heading, count: rows.count)
        var pairs = 0, index = 0
        while index + 1 < rows.count {
            let name = rows[index], preview = rows[index + 1]
            if looksLikeName(name.text), preview.words >= 2, abs(name.spot.left - preview.spot.left) <= leftAlign,
               preview.spot.top - name.spot.bottom <= median * 0.7, name.spot.left < 0.5 {
                roles[index] = .contact
                roles[index + 1] = .preview
                pairs += 1
                index += 2
            } else {
                index += 1
            }
        }
        guard pairs >= 2, pairs * 2 * 10 >= rows.count * 6 else { return nil }
        // Çifte girmeyen ad gibi satırlar bölüm başlığıdır ("Messages"), uzunlar tek başına önizlemedir.
        for i in rows.indices where roles[i] == .heading && !looksLikeName(rows[i].text) { roles[i] = .preview }
        return roles
    }

    /// Satır, açık balonun devamı mı: arada dar boşluk ve aynı hiza (solda; sağa yaslı balonda sağda da olur).
    private static func continues(_ row: Row, after last: Row, first: Row, median: Double) -> Bool {
        guard row.spot.top - last.spot.bottom < median * bubbleGap else { return false }
        if abs(row.spot.left - first.spot.left) <= leftAlign { return true }
        return min(row.spot.left, first.spot.left) > 0.2 && abs(row.spot.right - last.spot.right) <= rightAlign
    }

    /// Balonun rolü yaslı olduğu kenardan: sağa yaslı giden, sola yaslı gelen; ortalı kısa satır not; iki yanı da dar
    /// (ekranı dolduran) balon belirsiz, tarafı kartta balonun renginden seçilir.
    static func role(of bubble: [Row]) -> ScreenPhoneCard.Role {
        let spot = bubble.dropFirst().reduce(bubble[0].spot) { $0.union($1.spot) }
        let left = max(0, spot.left), right = max(0, 1 - spot.right)
        if bubble.count == 1, abs((spot.left + spot.right) / 2 - 0.5) <= noteCenter, left >= noteMargin, right >= noteMargin {
            return .note
        }
        if left < wideMargin && right < wideMargin { return .message }
        if right < left * sideRatio { return .outgoing }
        if left < right * sideRatio { return .incoming }
        return .message
    }

    /// Satırlar tek parça olur: satır sonunda tireyle bölünmüş sözcük boşluksuz birleşir.
    private static func group(_ rows: [Row], role: ScreenPhoneCard.Role, handset: ScreenPhoneCard.Handset) -> ScreenTranslation.Group {
        var text = ""
        for row in rows {
            if text.isEmpty { text = row.text }
            else if text.hasSuffix("-") { text += row.text }
            else { text += " " + row.text }
        }
        let boxes = rows.flatMap(\.lines).compactMap(\.box)
        let spot = rows.dropFirst().reduce(rows[0].spot) { $0.union($1.spot) }
        // Eğik telefonda okunan kutu satırın eğimini de kapsar; yazı boyu düz ekrandaki yükseklikten gelir.
        let heights = rows.map(\.height).sorted()
        var group = ScreenTranslation.Group(paragraphs: [text], box: boxes.dropFirst().reduce(boxes[0]) { $0.union($1) },
                                            lineHeight: heights[heights.count / 2] * handset.screenHeight)
        group.phone = ScreenPhoneCard.Placement(role: role, spot: spot)
        return group
    }
}
