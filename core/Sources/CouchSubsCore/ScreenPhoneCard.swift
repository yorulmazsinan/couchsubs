// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// "GTA 6 Telefon Mesajları" ayarı (`UserSettings.phoneMessagesPanel`) ve panelin yazı çarpanı (altyazı boyutundan,
/// `ScreenPhoneCard.textScale(fontSize:)`).
public struct PhonePanelOptions: Equatable, Sendable {
    public var enabled: Bool
    public var textScale: Double

    public init(enabled: Bool = true, textScale: Double = 1) {
        self.enabled = enabled
        self.textScale = textScale
    }
}

/// GTA 6 telefonunun sohbet paneli ("Ekranı çevir" ve otomatik telefon okuması): eğik telefon ekranının üstüne yazmak
/// okunmuyordu (yazı küçük, ekran yamuk, monitörde balonların yeri kayıyor). Telefon karede bulunursa (`GamePhoneGeometry`)
/// ekranındaki satırlar düz ekrana taşınıp ayrı gruplanır (`PhoneChat`, `GamePhoneText.groups`) ve çevirileri telefonun
/// hemen yanına (telefon solda ise sağına, sağda ise soluna; yanda yer yoksa altına) dizilir. Hizalı panel (varsayılan):
/// zemin kartı ve simge yok; her Türkçe balon telefondaki İngilizce balonuyla aynı yükseklikte, oyunun üstünde doğrudan
/// çizilir (karşı taraf solda, oyuncu sağda, telefondaki balonun renginde, %85 örtülü); kişi adı (çevrilmez) üstte küçük
/// başlık, sohbet listesinde önizleme satırları. Balonların yüksekliği Türkçenin kaç satır tutacağına göre hesaplanır, üst
/// üste binmez (çakışan balon en az kaydırmayla aşağı itilir). Yazı boyu altyazı boyutu ayarına bağlıdır
/// (`layout(textScale:)`). Telefon dışındaki yazılar kendi yerlerinde kalır. Panel, TV'ye ve masaüstüne stilli öğeler
/// olarak gider (zemin, başlık, balonlar) ve her öğe panel parçasını taşır (`PanelPart`, JSON `panel`; zemin `aligned`):
/// yeni çiziciler parçaları kutularının yerinde çizer; `aligned`'ı tanımayan TV (0.9.75–0.9.105) eskisi gibi kartta akışla,
/// `panel`'i tanımayan eski TV öğeleri yerinde çizer
/// (Windows: ScreenPhoneCard.cs, Android: ScreenPhoneCard.kt; ortak deneme dosyası Fixtures/phone-chat.json).
public enum ScreenPhoneCard {
    /// Panelin parçası; JSON'da `panel` alanının değeri.
    public enum PanelPart: String, Equatable, Sendable {
        /// Panelin zemini (kutusu panelin yeri ve boyu).
        case card
        /// Konuşulan kişinin adı (telefonun başlığı; çevrilmez).
        case title
        /// Karşı tarafın mesajı (solda, açık zemin) ve oyuncunun mesajı (sağda, amber zemin).
        case theirs, mine
        /// Ortalı kısa satır ("Bugün", saat) ve sohbet listesinin bölüm başlığı.
        case note
        /// Sohbet listesinin bir satırı ya da ana ekran bileşeni tek kartta (`ListRow`: avatar, kalın ad, altında önizleme,
        /// rozet, seçili satır çerçevesi). TV uygulaması 0.9.110; eski TV öğeyi yerinde, ad ve önizleme iki satır çizer.
        case row
    }

    /// Liste kartının içeriği (`PanelPart.row`; JSON `row`). Sinan Bey (beta.100, 3399): ad ve önizleme ayrı haplar
    /// dağınıktı; telefondaki satırın Türkçe kopyası tek kartta. Avatar ve rozet oyundan kesilir (`rowPortrait`,
    /// `rowBadge`; küçük PNG, aynı satırda bir kez kesilip saklanır), seçili satırın çerçevesi kareden okunur.
    public struct ListRow: Equatable, Sendable {
        /// Kalın ad (kişi adı çevrilmez; bileşen başlığı çevrilir). Boşsa yalnız önizleme.
        public var name: String
        /// Adın altındaki önizleme (çeviri; kesikse "..." ile biter). Boş olabilir (yalnız emoji önizleme).
        public var preview: String
        /// Oyundan kesilmiş avatar ya da bileşen simgesi (PNG data: adresi); yoksa nil.
        public var avatar: String? = nil
        /// Sağdaki rozet (gönder/konum simgesi; PNG data: adresi); yoksa nil.
        public var badge: String? = nil
        /// Seçili satırın çerçeve rengi (telefonda mavi); seçili değilse nil.
        public var selected: String? = nil
        /// Ana ekran bileşeni ("Hatırlatıcılar / 6 Bildirim").
        public var widget = false
        /// Karede avatarın, rozetin ve seçim çerçevesinin aranacağı yerler (kesmek için; gönderilmez).
        public var portraitSpot: TextBox? = nil
        public var badgeSpot: TextBox? = nil
        public var frameSpot: TextBox? = nil

        public init(name: String, preview: String) {
            self.name = name
            self.preview = preview
        }

        /// Görünüşü aynı mı (karedeki arama yerleri el titremesiyle oynar, karşılaştırmaya girmez; #1279).
        public static func == (a: ListRow, b: ListRow) -> Bool {
            a.name == b.name && a.preview == b.preview && a.avatar == b.avatar && a.badge == b.badge
                && a.selected == b.selected && a.widget == b.widget
        }
    }

    /// Kartın zemini: yazısı yalnız bölünmez boşluk olan öğe, kartın tamamını kaplar; balonlar üstüne çizilir.
    public static let backdropText = "\u{00A0}"
    /// Panelin renkleri (CouchSubs tasarım dili, design/tokens.json): koyu zemin (çiziciler %88 örtüyle çizer), karşı
    /// tarafın balonu krem, oyuncunun balonu amber, not satırı soluk.
    static let cardColor = PhoneTextStyle(background: "#141518", foreground: "#F3EEE4")
    static let incomingColor = PhoneTextStyle(background: "#F3EEE4", foreground: "#17181B")
    static let outgoingColor = PhoneTextStyle(background: "#F5B83D", foreground: "#17181B")
    static let noteColor = PhoneTextStyle(background: "#141518", foreground: "#A9A59C")
    /// Telefonla kart arasındaki boşluk ve kartın ekran kenarından payı (ekran genişliğine oranla).
    static let gap = 0.008
    /// Kart için yanda en az bu kadar yer olmalı; yoksa kart telefonun altına (orada da en az `minBelow` yükseklik yoksa
    /// telefonun üstüne) konur.
    static let minWidth = 0.12, minBelow = 0.18
    /// Kartın istenen eni: telefonun bu katı, en az `cardMin` (yanda yer varsa). Telefon boyundaki dar kartta Türkçe
    /// mesajlar çok satıra bölünüyor, balonlar iç içe görünüyordu.
    static let cardScale = 1.4, cardMin = 0.22
    /// Mesajlar telefon boyuna sığmazsa kart ekranın bu payına kadar yukarı ve aşağı uzar; yine sığmazsa eski mesajlar düşer.
    static let screenMargin = 0.03
    /// Balonlar arası boşluk, balonun iç dolgusu (üst + alt toplamı) ve satır aralığı; satır yüksekliğine oranla. TV
    /// yazıyı kutunun üstüne yaslar: dolgu, son satırın altında da boşluk bırakır. Önceden balonlar arası 0,35 satırdı,
    /// mesajlar birbirine yapışık görünüyordu.
    static let bubbleSpacing = 0.6, bubblePadding = 0.6, lineSpacing = 1.2
    /// Sohbet listesinde kişi adıyla altındaki önizleme arasındaki boşluk (satır yüksekliğine oranla).
    static let listGap = 0.1
    /// Balonun kart genişliğine oranı (en çok) ve en az.
    static let bubbleShare = 0.8, bubbleMin = 0.3
    /// Kartta yazı boyu (kare yüksekliğine oranla) en az bu: telefonun küçük yazısı TV'de okunsun (1080p'de ~24 nokta).
    static let minLine = 0.022
    /// Kartta yazı boyu en çok bu (altyazı boyutu çarpanıyla): telefon yazısıyla orantılı kalır. Sinan Bey (beta.100,
    /// 3416): gönderinin Türkçesi dev, her satıra bir sözcük düşen patlak balondu; ölçüm fotoğrafın içindeki büyük yazıyı
    /// (tabela) da alıyordu. 3417'deki küçük balon doğru boydur (1080p'de ~32 nokta satır).
    static let maxLine = 0.03
    /// Bir harfin ortalama genişliği, satır yüksekliğine oranla (TV'nin yazı tipinde Türkçe metinle ölçüldü, ~0,5).
    static let charWidth = 0.5

    /// Telefondaki yazının kartta ne olduğu.
    public enum Role: String, Equatable, Sendable {
        /// Sohbetin başlığı (kişi adı); çevrilmez.
        case header
        /// Gelen mesaj (sola yaslı balon), giden mesaj (sağa yaslı), tarafı belirsiz mesaj (rengine bakılır).
        case incoming, outgoing, message
        /// Sohbetin altındaki cevap seçeneği (oyuncunun seçeceği yanıt; `PhoneChat.withOptions`): her biri ayrı balon,
        /// oyuncunun tarafında, seçeneklerin hepsi aynı renkte.
        case option
        /// Ortalı kısa satır: saat, "Today", "Delivered".
        case note
        /// Sohbet listesi: kişi adı (çevrilmez), son mesaj önizlemesi, bölüm başlığı ("Messages").
        case contact, preview, heading
        /// Ana ekranın ve hava uygulamasının yazısı (bildirim, hava): sohbet değildir; panelde kart (`card` gibi).
        case home
        /// Ana ekran bileşeni (başlık + sayaç: "Reminders / 6 Notifications"): panelde tek kart (`ListRow.widget`).
        case widget
        /// Sohbet dışı ekranın satırı ya da bloğu (`PhoneScreen`: uygulama satırı, makale başlığı/gövdesi, gönderinin
        /// açıklaması): panelde tek kart, mesaj listesi kartının görünüşünde (avatarsız).
        case card

        /// Çevirmene gitmez, aslıyla gösterilir (ad).
        var keepsText: Bool { self == .header || self == .contact }
        /// Telefonun yanındaki panelde dizilir. Sinan Bey (beta.100, 3422): ana ekran ve hava yazıları da artık telefonun
        /// üstüne çizilmez, panelde kart olur.
        var inCard: Bool { true }
    }

    /// Telefondaki bir grubun rolü ve düz ekrandaki yeri (0–1). Kartta (`card`): `titled` ilk paragraf kalın başlık,
    /// `bold` kartın tamamı başlık (makale başlığı).
    public struct Placement: Equatable, Sendable {
        public var role: Role
        public var spot: TextBox
        public var titled = false
        public var bold = false
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

        /// Telefonun ekseni (gevşek doğrulama için; `GamePhoneGeometry.locate(near:)`).
        public var pose: GamePhoneGeometry.Pose { .init(topX: topX, topY: topY, bottomX: bottomX, bottomY: bottomY) }

        /// Düz ekrandaki noktanın karedeki yeri (kenarlara oranla).
        func point(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
            let dx = bottomX - topX, dy = bottomY - topY
            let t = 0.04 + 0.915 * v, side = (u - 0.5) * 0.52
            return (topX + dx * t + side * dy / aspect, topY + dy * t - side * dx * aspect * (0.52 + v * 0.30))
        }

        /// Düz ekrandaki kutunun karedeki sınır kutusu (dört köşesinden; eğik telefonda biraz geniştir).
        func frameBox(_ box: TextBox) -> TextBox {
            let corners = [point(box.left, box.top), point(box.right, box.top), point(box.left, box.bottom), point(box.right, box.bottom)]
            return TextBox(left: corners.map(\.x).min()!, top: corners.map(\.y).min()!,
                           right: corners.map(\.x).max()!, bottom: corners.map(\.y).max()!)
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

    /// Doğrulanmamış telefon adayı (#1251, `candidateHoldMs`) yalnız ekranının içindeki satırları bekletir: alt gövde payı
    /// (`belowSlack`) yok ve konuşan adlı satır ("Lucia: …") hiç bekletilmez. Yanlış aday (yanları zayıf, telefon olmayan
    /// dikdörtgen) altındaki ya da önündeki altyazıyı 1,5 sn yutuyordu (beta.103 kaçan altyazı denetimi).
    /// Windows (ScreenPhoneCard.HoldsUnconfirmed) ve Android (holdsUnconfirmed) aynı.
    public static func holdsUnconfirmed(_ text: String, box: TextBox, handset: Handset) -> Bool {
        guard SpeakerPrefix.split(text) == nil else { return false }
        let flat = handset.flat(box)
        let v = (flat.top + flat.bottom) / 2
        return v >= -screenSlack && v <= 1 + screenSlack && flat.left >= -sideSlack && flat.right <= 1 + sideSlack
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
    /// `near`: açık telefonun son yeri (bulunmuşsa); sıkı arama ıskalarsa orada gevşek doğrulama yapılır.
    public static func phone(in frame: CGImage, near: Handset? = nil) -> Handset? { search(in: frame, near: near).phone }

    /// `phone(in:near:)`; telefon bulunamazsa `candidate`: sıkı aramada yanları zayıf kalan akla yatkın aday
    /// (`GamePhoneGeometry.Probe.weak`), yoksa nil. Aday telefon sayılmaz; altyazı hattı ekranındaki satırları kısa süre
    /// bekletir (Windows: ScreenPhoneCard.Phone(frame, near, out candidate), Android: ScreenPhoneCard.search).
    static func search(in frame: CGImage, near: Handset? = nil) -> (phone: Handset?, candidate: Handset?) {
        let aspect = Double(frame.width) / Double(max(1, frame.height))
        let (pose, probe) = GamePhoneGeometry.search(frame, near: near?.pose)
        if let pose {
            guard GamePhoneTracker.plausible(pose.bounds, width: frame.width, height: frame.height) else { return (nil, nil) }
            return (Handset(pose: pose, aspect: aspect), nil)
        }
        guard let weak = probe.weak, GamePhoneTracker.plausible(weak.bounds, width: frame.width, height: frame.height) else {
            return (nil, nil)
        }
        return (nil, Handset(pose: weak, aspect: aspect))
    }

    /// Kartın yeri: telefonun yanında, telefon boyunda; iki yanda da yer yoksa telefonun altında, orada da yer yoksa
    /// telefonun üstünde. İki yanda da yer varsa kart başka çevirilerin (`avoiding`) üstüne en az binen yana, eşitse daha
    /// geniş boş kalan yana (telefon solda ise sağa, sağda ise sola) konur.
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
            if 1 - screenMargin - (phone.bottom + gap) >= minBelow {
                let width = min(wanted, 1 - 2 * gap)
                let left = min(max(gap, (phone.left + phone.right - width) / 2), 1 - gap - width)
                return TextBox(left: left, top: phone.bottom + gap, right: left + width, bottom: 1 - screenMargin)
            }
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

    /// Telefondaki öğeleri (`phone` bilgisi olanlar) telefonun yanındaki panelde dizer. Telefonda çevrilmiş öğe yoksa liste
    /// olduğu gibi döner. Çevrilmemiş öğeler (`unchanged`: kişi adı, "ok") panelde aslıyla görünür; panel dışındakiler sonra
    /// atılır. Hizalı panel (`aligned`): her Türkçe balon telefondaki İngilizce balonuyla aynı yükseklikte durur (yazısının
    /// üst kenarı İngilizce yazının üst kenarında, `alignedTop`); göz İngilizce balonla Türkçesini doğrudan eşleştirir.
    /// Balonlar çakışırsa üsttekinin altına en az kaydırmayla itilir (aralarında en az `bubbleSpacing` satır); panel gerekirse
    /// aşağı uzar, ekranın kenar payına da sığmazsa en eski mesajlar düşer. Yazı küçülmez. Balonlar telefonun balon renginde
    /// (`bubbleColor`). Kartın altında kalan başka bir çeviri kartın dışına, yanına alınır. `textScale`: altyazı boyutu
    /// ayarının varsayılana oranı (`textScale(fontSize:)`). `line`: telefondaki satır yüksekliği yerine kullanılacak kilitli
    /// ölçüm (`PhonePanelSteady.steadyLine`, #1152); verilmezse bu karenin ölçümü (`measuredLine`). Kartın kutusu eski TV
    /// için (akışla çizer) bütün satırları ve dolguyu alacak boydadır.
    public static func layout(_ items: [ScreenTranslation.Item], handset: Handset,
                              textScale: Double = 1, line locked: Double? = nil) -> [ScreenTranslation.Item] {
        let onPhone = items.filter { $0.phone?.role.inCard == true }.sorted { $0.phone!.spot.top < $1.phone!.spot.top }
        guard onPhone.contains(where: { !$0.unchanged }) else { return items }
        let others = items.filter { $0.phone?.role.inCard != true }
        var card = cardBox(handset.bounds, avoiding: others.filter { !$0.unchanged }.map(\.box))
        let cardWidth = card.right - card.left
        let measured = locked ?? measuredLine(onPhone) ?? 0
        let scale = min(maxScale, max(minScale, textScale))
        let line = min(maxLine * scale, max(minLine * scale, measured))
        let pad = cardWidth * 0.05, padY = line * 0.4, spacing = line * bubbleSpacing
        let flat = { (align: TextLook.Align, bold: Bool) in TextLook(bold: bold, condensed: false, align: align, upper: false, flat: true) }

        // Sohbetin üstündeki kişi adı çizilmez (Sinan Bey, beta.100 3400/3402: "Cal" başlığı gereksiz); balonlar aynen kalır.
        // Sohbet dışı ekranda çevrilmeyen kart (kişi adı "Jason", yer adı) çizilmez.
        let body = onPhone.filter { $0.phone?.role != .header && !(isCard($0.phone!.role) && $0.unchanged) }
        // Sohbet dışı ekranın kartları tek renkte (telefonda en çok görünen satır kartı rengi): her kart kendi örneğiyle
        // ayrı renkte çiziliyordu (Sinan Bey, 3423: "stilleri tutarsız").
        let cardStyle = commonStyle(body.filter { isCard($0.phone!.role) }.map(\.style))
        // Cevap seçenekleri tek renkte (okunabilen örneklerin en çok görüneni): seçili seçeneğin çerçevesi ya da renk
        // geçişi örneği bozunca biri telefonun renginde, öbürü yedek renkte çiziliyordu (X, 26 Kas).
        let optionStyle = commonStyle(body.filter { $0.phone!.role == .option }.map(\.style))

        // Her satırın panelde kaplayacağı yer: genişliği rolünden, yüksekliği Türkçenin o genişlikte kaç satır tuttuğundan.
        // Sohbet listesinin satırı (ad + altındaki önizleme) ve ana ekran bileşeni tek kart olur (`listRow`).
        struct Row { var item: ScreenTranslation.Item; var width: Double; var height: Double; var side: TextLook.Align }
        var rows: [Row] = []
        var index = 0
        while index < body.count {
            let item = body[index]
            let role = item.phone!.role
            index += 1
            if isCard(role) {
                if let made = cardRow(item, style: cardStyle, handset: handset, line: line, width: cardWidth - 2 * pad) {
                    rows.append(Row(item: made.item, width: cardWidth - 2 * pad, height: made.height, side: .left))
                }
                continue
            }
            if role == .contact || role == .preview || role == .widget {
                var name: ScreenTranslation.Item?, preview: ScreenTranslation.Item?
                if role == .contact {
                    name = item
                    if index < body.count, body[index].phone?.role == .preview {
                        preview = body[index]
                        index += 1
                    }
                } else if role == .preview {
                    preview = item
                } else {
                    name = item
                }
                if let made = listRow(name: name, preview: preview, widget: role == .widget, handset: handset,
                                      line: line, width: cardWidth - 2 * pad) {
                    rows.append(Row(item: made.item, width: cardWidth - 2 * pad, height: made.height, side: .left))
                }
                continue
            }
            let kind: Role = role == .message ? (isOutgoing(item.style) ? .outgoing : .incoming) : role == .option ? .outgoing : role
            let bubble = kind == .incoming || kind == .outgoing
            let widest = (bubble ? bubbleShare : 1) * cardWidth - (bubble ? 0 : 2 * pad)
            let inner = widest - 2 * pad
            let lines = wrap(item.translation, perLine: characters(inner * handset.aspect / (line * charWidth)))
            let longest = Double(lines.map(\.count).max() ?? 0) * line * charWidth / handset.aspect + 2 * pad
            let width = bubble ? min(widest, max(cardWidth * bubbleMin, longest)) : widest
            var placed = item
            placed.unchanged = false
            placed.lineHeight = line
            switch kind {
            case .outgoing:
                placed.style = bubbleColor(role == .option ? optionStyle : item.style, fallback: outgoingColor)
                placed.panel = .mine
            case .incoming:
                placed.style = bubbleColor(item.style, fallback: incomingColor)
                placed.panel = .theirs
            default:
                // Bölüm başlığı ("Önerilen", "Mesajlar") soluk ve kalın küçük başlık, sola yaslı; not ortalı.
                placed.style = noteColor
                placed.panel = .note
            }
            let side: TextLook.Align = kind == .outgoing ? .right : kind == .note ? .center : .left
            placed.look = flat(side, kind == .heading)
            rows.append(Row(item: placed, width: width, height: Double(lines.count) * line * lineSpacing + line * bubblePadding, side: side))
        }
        guard !rows.isEmpty else { return items }
        let limit = 1 - screenMargin
        let bodyTop = screenMargin
        // Her balon kendi İngilizce balonunun yüksekliğinde; çakışan balon üsttekinin altına en az kaydırmayla itilir. Panel
        // ekranın alt kenar payını aşarsa satırlar alttan yukarı itilir (yine en az kaydırmayla); yukarıda da yer kalmazsa en
        // eski (en üstteki) satırlar düşer, son mesajlar görünür kalır. Tek kalan çok uzun mesaj ekranın üst payından başlar.
        func alignedTops() -> [Double] {
            var tops: [Double] = []
            for (index, row) in rows.enumerated() {
                let below = index == 0 ? bodyTop : tops[index - 1] + rows[index - 1].height + spacing
                tops.append(max(alignedTop(row.item, line: line), below))
            }
            var floor = limit
            for index in rows.indices.reversed() {
                tops[index] = min(tops[index], floor - rows[index].height)
                floor = tops[index] - spacing
            }
            return tops
        }
        var tops = alignedTops()
        while rows.count > 1, let first = tops.first, first < bodyTop - 1e-9 {
            rows.removeFirst()
            tops = alignedTops()
        }
        if let first = tops.first, first < bodyTop { tops[0] = bodyTop }
        let contentTop = tops.first ?? card.top
        let contentBottom = rows.indices.last.map { tops[$0] + rows[$0].height } ?? card.bottom
        // Kart: telefon boyunda, balonlar aşağı uzanırsa onlarla; eski TV'nin akışı (dolgu, aralıklar) da sığar.
        let flow = 2 * padY + rows.reduce(0) { $0 + $1.height } + Double(max(0, rows.count - 1)) * spacing
        card.top = max(screenMargin, min(card.top, contentTop))
        card.bottom = min(limit, max(card.bottom, contentBottom + padY, card.top + flow))

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
        backdrop.panel = .card
        backdrop.aligned = true
        result.append(backdrop)

        for (index, row) in rows.enumerated() {
            var placed = row.item
            let left = row.side == .right ? card.right - pad - row.width
                : row.side == .center ? (card.left + card.right - row.width) / 2 : card.left + pad
            placed.box = TextBox(left: left, top: tops[index], right: left + row.width, bottom: tops[index] + row.height)
            result.append(placed)
        }
        return result
    }

    /// Sohbet dışı ekranın kartı mı (ana ekranın yazısı da).
    static func isCard(_ role: Role) -> Bool { role == .card || role == .home }

    /// En çok görünen okunmuş renk (eşitlikte önce gelen); örnek yoksa nil.
    static func commonStyle(_ styles: [PhoneTextStyle?]) -> PhoneTextStyle? {
        let known = styles.compactMap { $0 }.filter { $0.background.uppercased() != GamePhonePalette.neutral.background }
        var best: (style: PhoneTextStyle, count: Int)?
        for style in known {
            let count = known.filter { $0 == style }.count
            if best.map({ count > $0.count }) ?? true { best = (style, count) }
        }
        return best?.style
    }

    /// Sohbet dışı ekranın kartı: mesaj listesi kartının görünüşünde, avatarsız. Kalın başlık ("Strength Workout") ve
    /// altında yazı ("Level 3/4"), yalnız başlık (makale başlığı) ya da yalnız yazı (gönderinin açıklaması, ayar satırı).
    /// Kartın üstü İngilizcesiyle aynı hizada, boyu Türkçenin satır sayısına ve telefondaki bloğun boyuna göre.
    static func cardRow(_ item: ScreenTranslation.Item, style: PhoneTextStyle?, handset: Handset, line: Double,
                        width: Double) -> (item: ScreenTranslation.Item, height: Double)? {
        let parts = item.translation.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let placement = item.phone
        let title: String, below: String
        if placement?.bold == true {
            title = parts.joined(separator: " ")
            below = ""
        } else if placement?.titled == true, parts.count >= 2 {
            title = parts[0]
            below = parts.dropFirst().joined(separator: " ")
        } else {
            title = ""
            below = parts.joined(separator: " ")
        }
        var row = ListRow(name: title, preview: below)
        row.widget = false
        let inset = rowPadding * line / handset.aspect
        let inner = width - 2 * inset
        let perLine = characters(inner * handset.aspect / (line * charWidth))
        let lines = (title.isEmpty ? 0 : wrap(title, perLine: perLine).count) + (below.isEmpty ? 0 : wrap(below, perLine: perLine).count)
        let needed = Double(max(1, lines)) * line * lineSpacing + 2 * rowPadding * line
        let original = item.box.bottom - item.box.top + line * bubblePadding
        var placed = item
        placed.unchanged = false
        placed.lineHeight = line
        placed.style = bubbleColor(style ?? item.style, fallback: rowColor)
        placed.look = TextLook(bold: false, condensed: false, align: .left, upper: false, flat: true)
        placed.panel = .row
        placed.listRow = row
        return (placed, max(needed, original))
    }

    /// Liste kartının rengi okunamadıysa: GTA 6 telefonunun açık satır kartı.
    static let rowColor = PhoneTextStyle(background: "#F4F1EC", foreground: "#17181B")
    /// Liste kartında avatarın çapı, avatarla yazı arası ve kartın iç dolgusu (satır yüksekliğine oranla).
    public static let avatarLines = 2.2, avatarGap = 0.5, rowPadding = 0.45

    /// Liste satırını (ad + önizleme) ya da ana ekran bileşenini tek kart yapar: kartın üstü adın İngilizcesiyle aynı
    /// hizada, boyu Türkçenin satır sayısına ve telefondaki satırın boyuna göre (hangisi büyükse; kartlar arası boşluk
    /// telefondakiyle orantılı kalır). Kart telefonun satır kartı renginde (önizlemenin örneklenen zemini). Avatarın,
    /// rozetin ve seçim çerçevesinin karedeki yeri `ListRow`'a yazılır; kesmek çağıranın işi (`withRowImages`).
    static func listRow(name: ScreenTranslation.Item?, preview: ScreenTranslation.Item?, widget: Bool, handset: Handset,
                        line: Double, width: Double) -> (item: ScreenTranslation.Item, height: Double)? {
        guard let first = name ?? preview else { return nil }
        let title: String, below: String
        if widget {
            let parts = first.translation.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            title = parts[0]
            below = parts.count > 1 ? parts[1] : ""
        } else {
            title = name?.translation ?? ""
            below = preview?.translation ?? ""
        }
        var row = ListRow(name: title, preview: below)
        row.widget = widget
        let inset = rowPadding * line / handset.aspect
        let inner = width - 2 * inset - (avatarLines + avatarGap) * line / handset.aspect
        let wrapped = below.isEmpty ? 0 : wrap(below, perLine: characters(inner * handset.aspect / (line * charWidth))).count
        let lines = (title.isEmpty ? 0 : 1) + wrapped
        let needed = max(Double(max(1, lines)) * line * lineSpacing, avatarLines * line) + 2 * rowPadding * line
        // Telefondaki satırın boyu (adın üstünden önizlemenin altına, dolguyla).
        let last = preview ?? first
        let original = last.box.bottom - first.box.top + line * bubblePadding
        // Karedeki yerler (düz ekrandan): avatar adın solunda, ad ve önizleme bloğunun ortasında; rozet satırın sağ ucunda,
        // ad hizasında; seçim çerçevesi satırın üst kenarı (adın biraz üstü).
        if let top = first.phone?.spot, let bottom = last.phone?.spot {
            let shape = Handset.screenShape
            if widget {
                // Bileşenin simgesi başlığın solunda (sayaç satırının sol hizasında), başlık satırı boyunda.
                let size = (top.bottom - top.top) * 0.5
                row.portraitSpot = handset.frameBox(TextBox(left: top.left - size * 0.1 / shape, top: top.top - size * 0.1,
                                                            right: top.left + size * 1.1 / shape, bottom: top.top + size * 1.1))
            } else {
                let block = max(1e-4, bottom.bottom - top.top)
                let center = (top.top + bottom.bottom) / 2
                let size = block * 1.35
                let right = min(top.left, bottom.left) - block * 0.1 / shape
                row.portraitSpot = handset.frameBox(TextBox(left: right - size / shape, top: center - size / 2,
                                                            right: right, bottom: center + size / 2))
                let nameCenter = (top.top + top.bottom) / 2, badge = block * 0.62
                row.badgeSpot = handset.frameBox(TextBox(left: 0.985 - badge / shape, top: nameCenter - badge / 2,
                                                         right: 0.985, bottom: nameCenter + badge / 2))
                row.frameSpot = handset.frameBox(TextBox(left: max(0.25, top.left), top: top.top - block * 0.6,
                                                         right: 0.8, bottom: top.top - block * 0.05))
            }
        }
        var item = first
        item.source = widget ? first.source : [name?.source, preview?.source].compactMap { $0 }.joined(separator: "\n")
        item.translation = [title, below].filter { !$0.isEmpty }.joined(separator: "\n")
        item.unchanged = false
        item.lineHeight = line
        item.style = bubbleColor(preview?.style ?? first.style, fallback: widget ? cardColor : rowColor)
        item.look = TextLook(bold: false, condensed: false, align: .left, upper: false, flat: true)
        item.panel = .row
        item.listRow = row
        return (item, max(needed, original))
    }

    /// Hizalı panelde satırın istenen üst kenarı: Türkçe yazının üstü İngilizce yazının üstünde (`box`, karede); balon üst
    /// dolgusu kadar yukarıdan başlar. Telefondaki balonun dolgusu da benzer olduğundan iki balonun üst kenarı aynı hizadadır.
    static func alignedTop(_ item: ScreenTranslation.Item, line: Double) -> Double {
        item.box.top - line * bubblePadding / 2
    }

    /// Kişi adının (başlık) yüksekliği ve altındaki boşluk (satır yüksekliğine oranla); başlık balondan küçük yazılır.
    static let titleHeight = 1.4, titleGap = 0.3
    /// Hizalı panelde balonların, notların ve başlığın zemin örtüsü: oyun arkadan biraz görünür, yazı okunur.
    public static let bubbleOpacity = 0.85

    /// Balonun rengi: telefondaki balondan örneklenen zemin ve yazı (`GamePhonePalette`; gelen ve giden balonun kendi
    /// rengi). Örnek yoksa ya da okunamadıysa (nötr yedek, geçersiz renk) `fallback`. Örneğin yazısı zeminde okunmuyorsa
    /// (kontrast 4,5'ten az) zemine göre koyu ya da açık yazı.
    static func bubbleColor(_ style: PhoneTextStyle?, fallback: PhoneTextStyle) -> PhoneTextStyle {
        guard let style, style.background.uppercased() != GamePhonePalette.neutral.background,
              let background = rgb(style.background) else { return fallback }
        if let ink = rgb(style.foreground), contrast(background, ink) >= 4.5 { return style }
        let dark = "#17181B", light = "#F3EEE4"
        return PhoneTextStyle(background: style.background,
                              foreground: contrast(background, rgb(dark)!) >= contrast(background, rgb(light)!) ? dark : light)
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double)? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF))
    }

    /// İki rengin WCAG kontrast oranı.
    static func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        func luminance(_ c: (Double, Double, Double)) -> Double {
            func linear(_ n: Double) -> Double {
                let s = n / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Kartta dizilecek telefon yazılarının satır yüksekliklerinin ortancası (panelin yazı boyu bundan gelir); yoksa nil.
    /// Çift sayıda ölçümde küçük ortanca alınır: iki öğeden biri fotoğrafın içindeki büyük yazıysa (3416) panel onun
    /// boyunda çiziliyordu.
    public static func measuredLine(_ items: [ScreenTranslation.Item]) -> Double? {
        let heights = items.filter { $0.phone?.role.inCard == true }.map(\.lineHeight).sorted()
        return heights.isEmpty ? nil : heights[(heights.count - 1) / 2]
    }

    /// Metni sözcük sözcük en çok `perLine` harflik satırlara böler (çok uzun sözcük kendi satırında kalır).
    /// Satıra sığan harf sayısı; ölçü sayı değilse (sıfır boy, bozuk telefon yeri) 0. `Int(_:)` sonsuzda ve NaN'da çöker
    /// (#1369; Windows ve Android ile aynı).
    static func characters(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(100_000, max(-100_000, value)))
    }

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

    /// Çizilecek sohbet paneli: zemini (kutusu panelin yeri), kişinin adı ve mesajlar telefondaki sırasıyla. Öğelerde
    /// panel yoksa nil; panel dışındaki öğeler (`outside`) kendi yerlerinde çizilir.
    public struct Panel: Equatable, Sendable {
        public let card: ScreenTranslation.Item
        public let title: ScreenTranslation.Item?
        public let messages: [ScreenTranslation.Item]
        public let outside: [ScreenTranslation.Item]
        /// Hizalı panel: zemin çizilmez, her parça kendi kutusunun yerinde (`PhonePanelAligned`); değilse akışla, kartta.
        public var aligned: Bool { card.aligned }
    }

    public static func panel(_ items: [ScreenTranslation.Item]) -> Panel? {
        guard let card = items.first(where: { $0.panel == .card }) else { return nil }
        let parts = items.filter { $0.panel != nil && $0.panel != .card }
        return Panel(card: card, title: parts.first { $0.panel == .title },
                     messages: parts.filter { $0.panel != .title }.sorted { $0.box.top < $1.box.top },
                     outside: items.filter { $0.panel == nil })
    }

    /// Saydam altyazı penceresindeki sohbet paneli (Mac SubtitleOverlay, Windows SubtitleOverlayWindow): pencere oyun karesi
    /// değil, kullanıcının seçtiği alan olduğundan balonlar telefondaki İngilizce balonlarına hizalanamaz. Görünüm hizalı
    /// panelle aynıdır (koyu kart ve simge yok; her balon ayrı, telefonun balon renginde, `bubbleColor`): balonlar alanın
    /// telefon tarafındaki kenarında (telefon sağdaysa sağda) üstten alta, telefondaki sırasıyla ve aralarındaki boşlukla
    /// (en çok `stackedGapMax` satır) dizilir; gelen sola, giden sağa yaslı, kişi adı üstte küçük başlık. Yazı boyu `font`
    /// (piksel, en az `stackedMinFont`). Mesajların hepsi alana sığmazsa önce sütun genişler (alanın en çok
    /// `stackedWideShare`'i), yine sığmazsa yazı `stackedMinFont`'a dek küçülür; yalnız hiçbiri yetmezse yazı verilen boyda
    /// kalır ve en eski mesajlar düşer. X (26 Kas, beta.104, Windows): saydam pencerede uzun ilk mesaj (dar sütunda 10+
    /// satır) sığmadığı için hiç çizilmiyordu, "en üstteki mesaj çevrilmiyor" sanılıyordu. `width`×`height`: alanın
    /// boyu (piksel); dönen kutular alana oranla (0–1) ve çiziciler hizalı paneli çizer gibi çizer (`PhonePanelAligned`,
    /// Windows `PhonePanelView.Aligned`). Aynı girdi her zaman birebir aynı çıktı (#1279). Windows: `Stacked`, Android: `stacked`.
    public static func stacked(_ panel: Panel, width: Double, height: Double, font: Double) -> Panel {
        guard width > 0, height > 0 else { return panel }
        let given = max(stackedMinFont, font)
        let narrow = min(width * stackedShare, given * stackedChars) / width
        let wide = max(narrow, stackedWideShare)
        // Sığan ilk düzen: verilen boy dar sütunda, geniş sütunda, sonra küçülen yazıyla; hiçbiri sığmazsa ilk düzen.
        var tries: [(column: Double, font: Double)] = [(narrow, given)]
        if wide > narrow + 1e-9 { tries.append((wide, given)) }
        var smaller = given
        while smaller > stackedMinFont + 1e-9 {
            smaller = max(stackedMinFont, smaller * 0.9)
            tries.append((wide, smaller))
        }
        for attempt in tries {
            let result = stackedPanel(panel, width: width, height: height, font: attempt.font, column: attempt.column)
            if result.messages.count == panel.messages.count { return result }
        }
        return stackedPanel(panel, width: width, height: height, font: given, column: narrow)
    }

    private static func stackedPanel(_ panel: Panel, width: Double, height: Double, font: Double, column: Double) -> Panel {
        // Çiziciler yazı boyunu satır yüksekliğinin 0,85'i alır (`PhonePanelAligned`).
        let line = font / 0.85 / height
        let aspect = width / height
        let right = (panel.card.box.left + panel.card.box.right) / 2 > 0.5
        let left = right ? 1 - column : 0
        // Balonun yan dolgusu (çizicilerde yazı boyunun 0,6'sı), alana oranla.
        let padX = font * 0.6 / width

        var card = panel.card
        card.box = TextBox(left: left, top: 0, right: left + column, bottom: 1)
        card.lineHeight = line
        card.aligned = true
        var title = panel.title
        let bodyTop = title == nil ? 0 : line * (titleHeight + titleGap)
        if var head = title {
            head.box = TextBox(left: left, top: 0, right: left + column, bottom: line * titleHeight)
            head.lineHeight = line
            title = head
        }

        struct Row { var item: ScreenTranslation.Item; var width: Double; var height: Double; var gap: Double }
        let rows: [Row] = panel.messages.enumerated().map { index, source in
            var item = source
            let bubble = item.panel == .mine || item.panel == .theirs
            if item.panel == .mine { item.style = bubbleColor(item.style, fallback: outgoingColor) }
            if item.panel == .theirs { item.style = bubbleColor(item.style, fallback: incomingColor) }
            item.lineHeight = line
            let widest = (bubble ? bubbleShare : 1) * column
            // Liste kartında yazı avatarın sağında; kart en az avatar boyunda.
            let avatar = item.panel == .row ? (avatarLines + avatarGap + 2 * rowPadding) * line / aspect : 0
            let lines = wrap(item.translation, perLine: characters((widest - 2 * padX - avatar) * aspect / (line * charWidth)))
            // Telefondaki aralık satır yüksekliğine oranla korunur (önizleme kişi adının hemen altında kalır).
            var gap = bubbleSpacing
            if index > 0 {
                let previous = panel.messages[index - 1]
                gap = min(stackedGapMax, max(0, (source.box.top - previous.box.bottom) / max(1e-9, source.lineHeight)))
            }
            var height = Double(lines.count) * line * lineSpacing + line * bubblePadding
            if item.panel == .row { height = max(Double(lines.count) * line * lineSpacing, avatarLines * line) + 2 * rowPadding * line }
            return Row(item: item, width: widest, height: height, gap: gap * line)
        }
        // Sığmazsa en eski mesajlar düşer; tek kalan çok uzun mesaj yine çizilir (aşağıda kırpılır).
        var first = 0
        func bottom(from start: Int) -> Double {
            rows[start...].indices.reduce(bodyTop) { sum, index in sum + rows[index].height + (index > start ? rows[index].gap : 0) }
        }
        while first < rows.count - 1, bottom(from: first) > 1 + 1e-9 { first += 1 }

        var messages: [ScreenTranslation.Item] = []
        var top = bodyTop
        for index in rows.indices where index >= first {
            let row = rows[index]
            if index > first { top += row.gap }
            var item = row.item
            let x = item.panel == .mine ? left + column - row.width : left
            item.box = TextBox(left: x, top: top, right: x + row.width, bottom: top + row.height)
            messages.append(item)
            top += row.height
        }
        return Panel(card: card, title: title, messages: messages, outside: panel.outside)
    }

    /// Saydam pencerede panelin yazısı en az bu boyda (piksel); sütunun eni alanın en çok `stackedShare`'i ve yazı boyunun
    /// `stackedChars` katı; balonlar arası boşluk en çok `stackedGapMax` satır. Mesajlar sığmazsa sütun alanın en çok
    /// `stackedWideShare`'ine genişler.
    public static let stackedMinFont = 13.0
    static let stackedShare = 0.45, stackedChars = 20.0, stackedGapMax = 1.2, stackedWideShare = 0.9

    /// Panelin köşe yarıçapı ve zemin örtüsü (1080 satırlık ekranda piksel; çiziciler ekran boyuna ölçekler).
    public static let panelRadius = 18.0, panelOpacity = 0.88

    /// Kanepe simgesi (panelin sağ alt köşesi; logo değil, sade): 24×16 ızgarada yuvarlak köşeli dikdörtgenler
    /// (x, y, en, boy, köşe). Bütün çiziciler (SwiftUI, WPF, Compose, TV) aynı şekli çizer.
    public static let couchGlyph: [(x: Double, y: Double, width: Double, height: Double, radius: Double)] = [
        (3, 1, 18, 8, 2.5),   // sırtlık
        (0, 5, 5, 8, 2),      // sol kolçak
        (19, 5, 5, 8, 2),     // sağ kolçak
        (4, 8, 16, 5, 1.5),   // oturak
        (2, 13, 2, 3, 0.8),   // sol ayak
        (20, 13, 2, 3, 0.8),  // sağ ayak
    ]

    /// Altyazı boyutu ayarının (TV pikseli, 1080p) panel yazısına çarpanı: varsayılan boyda 1, `minScale`–`maxScale` arası.
    public static func textScale(fontSize: Int) -> Double {
        min(maxScale, max(minScale, Double(fontSize) / Double(defaultFontSize)))
    }
    static let defaultFontSize = 46, minScale = 0.75, maxScale = 1.6

    /// Tarafı hizadan belli olmayan balon (ekranı dolduran uzun mesaj) oyuncunun mu: zemini belirgin mavi ya da başka
    /// doygun bir renk (yeşil, turuncu) ya da açık mavimsi (GTA 6'nın giden balonu #D3DCF4; gelen balon kremdir, #F6EFE8).
    /// Karşı tarafın balonu telefonda krem, gri ya da beyazdır.
    static func isOutgoing(_ style: PhoneTextStyle?) -> Bool {
        if isBlue(style) { return true }
        guard let hex = style?.background, hex.count == 7, hex.hasPrefix("#"),
              let value = Int(hex.dropFirst(), radix: 16) else { return false }
        let r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF
        return (max(r, g, b) - min(r, g, b) >= 70 && max(r, g, b) >= 90) || (b - r >= 20 && b >= g)
    }

    /// Balonun okunan rengi belirgin mavi mi (giden mesaj balonu): mavi kanal kırmızı ve yeşilin ortalamasından en az 40 fazla.
    static func isBlue(_ style: PhoneTextStyle?) -> Bool {
        guard let hex = style?.background, hex.count == 7, hex.hasPrefix("#"),
              let value = Int(hex.dropFirst(), radix: 16) else { return false }
        let r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF
        return b - (r + g) / 2 >= 40
    }
}
