// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// "Ekranı çevir"de GTA 6 telefonu: eğik telefon ekranının üstüne yazmak okunmuyordu (yazı küçük, ekran yamuk). Telefon
/// karede bulunursa (`GamePhoneGeometry`) ekranındaki satırlar düz ekrana taşınıp ayrı gruplanır (`PhoneChat`) ve
/// çevirileri telefonun hemen yanına, ekranda yer olan tarafa, telefon boyunda açık renkli bir "mesaj kartı" olarak
/// dizilir: en üstte kişi adı, altında her mesaj kendi balonunda (giden sağda mavi, gelen solda beyaz), sohbet listesinde
/// ad + önizleme satırları. Balonların yüksekliği Türkçenin kaç satır tutacağına göre hesaplanır, üst üste binmez; kart
/// dolarsa en eski mesajlar düşer. Yanda yer yoksa kart telefonun üstüne konur. Telefon dışındaki yazılar kendi
/// yerlerinde kalır. Kart, TV'ye ve masaüstüne sıradan stilli öğeler olarak gider (zemin, başlık, balonlar), ayrı bir
/// çizim gerekmez (Windows: ScreenPhoneCard.cs, Android: ScreenPhoneCard.kt; ortak deneme dosyası Fixtures/phone-chat.json).
public enum ScreenPhoneCard {
    /// Kartın zemini: yazısı yalnız bölünmez boşluk olan öğe, kartın tamamını kaplar; balonlar üstüne çizilir.
    public static let backdropText = "\u{00A0}"
    static let cardColor = PhoneTextStyle(background: "#F2F2F7", foreground: "#1C1C1E")
    static let incomingColor = PhoneTextStyle(background: "#FFFFFF", foreground: "#1C1C1E")
    static let outgoingColor = PhoneTextStyle(background: "#0A84FF", foreground: "#FFFFFF")
    /// Telefonla kart arasındaki boşluk ve kartın ekran kenarından payı (ekran genişliğine oranla).
    static let gap = 0.008
    /// Kart için yanda en az bu kadar yer olmalı; yoksa kart telefonun üstüne konur.
    static let minWidth = 0.12
    /// Kartın istenen eni: telefonun bu katı, en az `cardMin` (yanda yer varsa). Telefon boyundaki dar kartta Türkçe
    /// mesajlar çok satıra bölünüyor, balonlar iç içe görünüyordu.
    static let cardScale = 1.4, cardMin = 0.22
    /// Mesajlar telefon boyuna sığmazsa kart ekranın bu payına kadar yukarı ve aşağı uzar; yine sığmazsa eski mesajlar düşer.
    static let screenMargin = 0.03
    /// Balonlar arası boşluk, balonun iç dolgusu (üst + alt toplamı) ve satır aralığı; satır yüksekliğine oranla. TV
    /// yazıyı kutunun üstüne yaslar: dolgu, son satırın altında da boşluk bırakır. Önceden balonlar arası 0,35 satırdı,
    /// mesajlar birbirine yapışık görünüyordu.
    static let bubbleSpacing = 0.6, bubblePadding = 0.6, lineSpacing = 1.2
    /// Balonun kart genişliğine oranı (en çok) ve en az.
    static let bubbleShare = 0.8, bubbleMin = 0.3
    /// Kartta yazı boyu (kare yüksekliğine oranla) en az bu: telefonun küçük yazısı TV'de okunsun (1080p'de ~24 nokta).
    static let minLine = 0.022
    /// Bir harfin ortalama genişliği, satır yüksekliğine oranla (TV'nin yazı tipinde Türkçe metinle ölçüldü, ~0,5).
    static let charWidth = 0.5

    /// Telefondaki yazının kartta ne olduğu.
    public enum Role: String, Equatable, Sendable {
        /// Sohbetin başlığı (kişi adı); çevrilmez.
        case header
        /// Gelen mesaj (sola yaslı balon), giden mesaj (sağa yaslı), tarafı belirsiz mesaj (rengine bakılır).
        case incoming, outgoing, message
        /// Ortalı kısa satır: saat, "Today", "Delivered".
        case note
        /// Sohbet listesi: kişi adı (çevrilmez), son mesaj önizlemesi, bölüm başlığı ("Messages").
        case contact, preview, heading
        /// Ana ekranın yazısı (bileşen, bildirim): sohbet değildir, karta girmez; kendi yerinde, özgün stilinde çizilir.
        case home

        /// Çevirmene gitmez, aslıyla gösterilir (ad).
        var keepsText: Bool { self == .header || self == .contact }
        /// Kartta dizilir (ana ekranın yazıları yerinde kalır).
        var inCard: Bool { self != .home }
    }

    /// Telefondaki bir grubun rolü ve düz ekrandaki yeri (0–1).
    public struct Placement: Equatable, Sendable {
        public var role: Role
        public var spot: TextBox
    }

    /// Karedeki telefon: sınır kutusu ve ekranın ekseni (hoparlörden alt çentiğe). Eğik telefonun ekranındaki her nokta
    /// düz ekrana (u: soldan sağa, v: yukarıdan aşağı, 0–1) taşınabilir; `GamePhoneReader`'ın düzeltmesinin tersidir.
    public struct Handset: Equatable, Sendable {
        public let bounds: TextBox
        let topX: Double, topY: Double, bottomX: Double, bottomY: Double
        /// Karenin genişliği / yüksekliği.
        let aspect: Double
        /// Düz ekranın eni / boyu (telefon okuyucusunun ekran oranı: 0,52 / 0,915).
        static let screenShape = 0.52 / 0.915

        public init(pose: GamePhoneGeometry.Pose, aspect: Double) {
            let region = pose.bounds
            bounds = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
            topX = pose.topX
            topY = pose.topY
            bottomX = pose.bottomX
            bottomY = pose.bottomY
            self.aspect = aspect
        }

        /// Ekranın yüksekliği, kare yüksekliğine oranla.
        var screenHeight: Double { (bottomY - topY) * 0.915 }

        /// Düz ekrandaki noktanın karedeki yeri (kenarlara oranla).
        func point(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
            let dx = bottomX - topX, dy = bottomY - topY
            let t = 0.04 + 0.915 * v, side = (u - 0.5) * 0.52
            return (topX + dx * t + side * dy / aspect, topY + dy * t - side * dx * aspect * (0.52 + v * 0.30))
        }

        /// Karedeki noktanın düz ekrandaki yeri (Newton adımlarıyla; dönüşüm neredeyse doğrusal, dört adım yeter).
        func screen(_ x: Double, _ y: Double) -> (u: Double, v: Double) {
            let dx = bottomX - topX, dy = bottomY - topY
            var u = 0.5, v = ((y - topY) / dy - 0.04) / 0.915
            for _ in 0..<4 {
                let p = point(u, v)
                let ex = p.x - x, ey = p.y - y
                let a = 0.52 * dy / aspect, b = 0.915 * dx
                let c = -0.52 * dx * aspect * (0.52 + 0.30 * v), d = 0.915 * dy - (u - 0.5) * 0.52 * dx * aspect * 0.30
                let det = a * d - b * c
                guard abs(det) > 1e-12 else { break }
                u -= (d * ex - b * ey) / det
                v -= (a * ey - c * ex) / det
            }
            return (u, v)
        }

        /// Karedeki satır kutusunun düz ekrandaki yeri. Eğik ekranda okunan kutu satırın eğimini de kapsar: satırın
        /// gerçek yüksekliği kutunun yüksekliğinden eğimin payı düşülerek bulunur.
        func flat(_ box: TextBox) -> TextBox {
            let cx = (box.left + box.right) / 2, cy = (box.top + box.bottom) / 2
            let center = screen(cx, cy)
            let dx = bottomX - topX, dy = bottomY - topY
            let slope = (-0.52 * dx * aspect * (0.52 + 0.30 * center.v)) / (0.52 * dy / aspect)
            let left = screen(box.left, cy + slope * (box.left - cx)).u
            let right = screen(box.right, cy + slope * (box.right - cx)).u
            let height = box.bottom - box.top
            let upright = max(height - abs(slope) * (box.right - box.left), height * 0.35)
            let half = upright / screenHeight / 2
            return TextBox(left: left, top: center.v - half, right: right, bottom: center.v + half)
        }
    }

    /// Satır (karedeki kutusu) telefonun ekranında mı: düz ekrandaki ortası ekranın içinde ve iki yanı ekranın kenarlarını
    /// `screenSlack`'ten çok aşmıyor. Altyazı hattı bu satırları okumaz (`SubtitlePipeline.process(phone:)`). Kullanıcı
    /// bildirimleri (X, beta.79): telefonun alt kısmındaki mesaj, telefon ekranın ortasına yakın tutulunca bütün sohbet
    /// altyazı sanılıp ekranın ortasında tek uzun satır olarak çevriliyordu. Telefonun önünden geçen geniş altyazı satırı
    /// telefonun ekranından taşar, telefon yazısı sayılmaz (Windows: ScreenPhoneCard.Holds, Android: ScreenPhoneCard.holds).
    public static func holds(_ box: TextBox, handset: Handset) -> Bool {
        let flat = handset.flat(box)
        let v = (flat.top + flat.bottom) / 2
        return v >= -screenSlack && v <= 1 + belowSlack && flat.left >= -sideSlack && flat.right <= 1 + sideSlack
    }

    /// `holds`: satırın ortası ekranın üst kenarını bu kadar, yanları ekranın kenarlarını `sideSlack` kadar aşabilir (düz
    /// ekrana oranla; eğik telefonda kutular biraz taşar). Alt kenarda pay `belowSlack`: telefonun alt gövdesi elle ya da
    /// altyazıyla örtülünce telefon kısa bulunuyor (alt çentik görünmüyor), sohbetin son mesajları ekranın altında kalıyordu
    /// (gerçek kare gta6-telefon-sohbet-2: "Go get em" v=1,12, "Locating..." v=1,24). Telefonun altındaki altyazı daha
    /// aşağıdadır ve telefonun ekranından geniştir.
    static let screenSlack = 0.03, sideSlack = 0.12, belowSlack = 0.25

    /// Öğe kartın zemini mi (masaüstü listesi ve düz metin bunu atlar).
    public static func isBackdrop(_ item: ScreenTranslation.Item) -> Bool {
        item.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Okunan karede telefon varsa yeri ve eğikliği; akla yatkın olmayan aday (bkz. `GamePhoneTracker.plausible`) yok sayılır.
    public static func phone(in frame: CGImage) -> Handset? {
        guard let pose = GamePhoneGeometry.locate(frame),
              GamePhoneTracker.plausible(pose.bounds, width: frame.width, height: frame.height) else { return nil }
        return Handset(pose: pose, aspect: Double(frame.width) / Double(max(1, frame.height)))
    }

    /// Kartın yeri: telefonun yanında, telefon boyunda; iki yanda da yer yoksa telefonun üstünde. İki yanda da yer varsa
    /// kart başka çevirilerin (`avoiding`) üstüne en az binen yana, eşitse daha geniş boş kalan yana konur.
    static func cardBox(_ phone: TextBox, avoiding others: [TextBox] = []) -> TextBox {
        let roomLeft = phone.left - 2 * gap, roomRight = 1 - phone.right - 2 * gap
        let wanted = max((phone.right - phone.left) * cardScale, cardMin)
        func side(right: Bool) -> TextBox? {
            let width = min(wanted, right ? roomRight : roomLeft)
            guard width >= minWidth else { return nil }
            let left = right ? phone.right + gap : phone.left - gap - width
            return TextBox(left: left, top: phone.top, right: left + width, bottom: phone.bottom)
        }
        // Önce daha geniş yan; öbür yan ancak başka çevirilerin üstüne daha az binerse seçilir.
        let candidates = [side(right: roomLeft < roomRight), side(right: roomLeft >= roomRight)].compactMap { $0 }
        guard var best = candidates.first else {
            return TextBox(left: max(0, phone.left), top: phone.top, right: min(1, phone.right), bottom: phone.bottom)
        }
        for candidate in candidates.dropFirst() where covered(candidate, others) < covered(best, others) - 1e-9 { best = candidate }
        return best
    }

    /// Kutunun başka kutularla örtüşen alanı.
    static func covered(_ box: TextBox, _ others: [TextBox]) -> Double {
        others.reduce(0) { sum, other in
            sum + max(0, min(box.right, other.right) - max(box.left, other.left))
                * max(0, min(box.bottom, other.bottom) - max(box.top, other.top))
        }
    }

    /// Telefondaki öğeleri (`phone` bilgisi olanlar) kart olarak dizer. Telefonda çevrilmiş öğe yoksa liste olduğu gibi
    /// döner. Çevrilmemiş öğeler (`unchanged`: kişi adı, "ok") kartta aslıyla görünür; kart dışındakiler sonra atılır.
    /// Balonlar arasında en az `bubbleSpacing` satır boşluk kalır; mesajlar telefon boyuna sığmazsa kart uzar, yine
    /// sığmazsa en eski mesajlar düşer. Kartın altında kalan başka bir çeviri kartın dışına, yanına alınır.
    public static func layout(_ items: [ScreenTranslation.Item], handset: Handset) -> [ScreenTranslation.Item] {
        let onPhone = items.filter { $0.phone?.role.inCard == true }.sorted { $0.phone!.spot.top < $1.phone!.spot.top }
        guard onPhone.contains(where: { !$0.unchanged }) else { return items }
        let others = items.filter { $0.phone?.role.inCard != true }
        var card = cardBox(handset.bounds, avoiding: others.filter { !$0.unchanged }.map(\.box))
        let cardWidth = card.right - card.left
        let heights = onPhone.map(\.lineHeight).sorted()
        let line = max(minLine, heights[heights.count / 2])
        let pad = cardWidth * 0.05, padY = line * 0.4, spacing = line * bubbleSpacing
        let flat = { (align: TextLook.Align, bold: Bool) in TextLook(bold: bold, condensed: false, align: align, upper: false, flat: true) }

        var body = onPhone
        var header: ScreenTranslation.Item?
        if let first = body.first, first.phone?.role == .header {
            header = first
            body.removeFirst()
        }
        let headerHeight = header == nil ? 0 : line * 1.4 + spacing

        // Her satırın kartta kaplayacağı yer: genişliği rolünden, yüksekliği Türkçenin o genişlikte kaç satır tuttuğundan.
        struct Row { var item: ScreenTranslation.Item; var width: Double; var height: Double; var side: TextLook.Align }
        var rows: [Row] = body.map { item in
            let role = item.phone!.role == .message ? (isBlue(item.style) ? .outgoing : .incoming) : item.phone!.role
            let bubble = role == .incoming || role == .outgoing
            let widest = (bubble ? bubbleShare : 1) * cardWidth - (bubble ? 0 : 2 * pad)
            let inner = widest - 2 * pad
            let lines = wrap(item.translation, perLine: Int(inner * handset.aspect / (line * charWidth)))
            let longest = Double(lines.map(\.count).max() ?? 0) * line * charWidth / handset.aspect + 2 * pad
            let width = bubble ? min(widest, max(cardWidth * bubbleMin, longest)) : widest
            var placed = item
            placed.unchanged = false
            placed.lineHeight = line
            switch role {
            case .outgoing: placed.style = outgoingColor
            case .incoming: placed.style = incomingColor
            default: placed.style = cardColor
            }
            let side: TextLook.Align = role == .outgoing ? .right : role == .note ? .center : .left
            placed.look = flat(side, role == .contact || role == .heading)
            let inside = line * (bubble ? bubblePadding : 0.3)
            return Row(item: placed, width: width, height: Double(lines.count) * line * lineSpacing + inside, side: side)
        }
        // Mesajlar telefon boyuna sığmazsa kart önce aşağı, sonra yukarı uzar (ekranın kenar payına kadar).
        func needed() -> Double {
            2 * padY + headerHeight + rows.reduce(0) { $0 + $1.height } + spacing * Double(max(0, rows.count - 1))
        }
        var extra = needed() - (card.bottom - card.top)
        if extra > 0 {
            let down = min(extra, max(0, 1 - screenMargin - card.bottom))
            card.bottom += down
            extra -= down
            card.top -= min(extra, max(0, card.top - screenMargin))
        }
        // Yine sığmazsa en eski (en üstteki) satırlar düşer: son mesajlar görünür kalır.
        while rows.count > 1, needed() > card.bottom - card.top + 1e-9 { rows.removeFirst() }

        var result = others
        // Kartın altında kalan başka bir çeviri kartın telefondan uzak yanına alınır; oraya sığmazsa yerinde kalır.
        let cardOnLeft = card.right <= handset.bounds.left + 1e-9
        for index in result.indices where !result[index].unchanged && covered(result[index].box, [card]) > 0 {
            let box = result[index].box, width = box.right - box.left
            let left = cardOnLeft ? card.left - gap - width : card.right + gap
            if left >= 0, left + width <= 1 { result[index].box = TextBox(left: left, top: box.top, right: left + width, bottom: box.bottom) }
        }
        var backdrop = ScreenTranslation.Item(source: "", translation: backdropText, box: card, lineHeight: line)
        backdrop.style = cardColor
        backdrop.look = flat(.left, false)
        result.append(backdrop)

        var bodyTop = card.top + padY
        if var header {
            header.unchanged = false
            header.box = TextBox(left: card.left + pad, top: bodyTop, right: card.right - pad, bottom: bodyTop + line * 1.4)
            header.lineHeight = line
            header.style = cardColor
            header.look = flat(.center, true)
            result.append(header)
            bodyTop = header.box.bottom + spacing
        }
        let limit = card.bottom - padY
        // Önce telefondaki yerine (oranla) yakın, üsttekinin altında; taşan satırlar alttan yukarı itilir.
        let phone = handset.bounds
        var tops: [Double] = []
        var cursor = bodyTop
        for row in rows {
            let wanted = phone.top + row.item.phone!.spot.top * (phone.bottom - phone.top)
            let top = max(wanted, cursor)
            tops.append(top)
            cursor = top + row.height + spacing
        }
        var floor = limit
        for index in rows.indices.reversed() {
            tops[index] = max(bodyTop, min(tops[index], floor - rows[index].height))
            floor = tops[index] - spacing
        }
        for (index, row) in rows.enumerated() {
            var placed = row.item
            let left = row.side == .right ? card.right - pad - row.width
                : row.side == .center ? (card.left + card.right - row.width) / 2 : card.left + pad
            placed.box = TextBox(left: left, top: tops[index], right: left + row.width, bottom: tops[index] + row.height)
            result.append(placed)
        }
        return result
    }

    /// Metni sözcük sözcük en çok `perLine` harflik satırlara böler (çok uzun sözcük kendi satırında kalır).
    static func wrap(_ text: String, perLine: Int) -> [String] {
        let limit = max(4, perLine)
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var current = ""
            for word in paragraph.split(whereSeparator: \.isWhitespace) {
                if current.isEmpty { current = String(word) }
                else if current.count + 1 + word.count <= limit { current += " " + word }
                else {
                    lines.append(current)
                    current = String(word)
                }
            }
            lines.append(current)
        }
        return lines
    }

    /// Balonun okunan rengi belirgin mavi mi (giden mesaj balonu): mavi kanal kırmızı ve yeşilin ortalamasından en az 40 fazla.
    static func isBlue(_ style: PhoneTextStyle?) -> Bool {
        guard let hex = style?.background, hex.count == 7, hex.hasPrefix("#"),
              let value = Int(hex.dropFirst(), radix: 16) else { return false }
        let r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF
        return b - (r + g) / 2 >= 40
    }
}
