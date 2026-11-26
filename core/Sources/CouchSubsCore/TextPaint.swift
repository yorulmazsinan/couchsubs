// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Bir ekran yazısının yerinde, arayüz Türkçe yapılmış gibi çizilmesi için göndericinin kareden ölçtükleri (TV pikselleri
/// okuyamaz). Yalnız yazı değişince ölçülür (Windows: TextPaint.cs, Android: TextPaint.kt; aynı kurallar ve eşikler).
/// TV'ye öğenin `bg`, `bg2`, `bgDir`, `bgPat`, `fg`, `weight`, `upper`, `align`, `lineH`, `cover`, `grow`, `group`
/// alanlarıyla (çizim kipi: `mode`, `spot`, `spotRoom`, `twinBox`, `radius`, `scale`, `tail`, `icon`) gider; eski TV
/// bunları yok sayıp eski çizimi sürdürür.
public struct TextPaint: Equatable, Sendable {
    public enum Direction: String, Sendable { case horizontal = "h", vertical = "v" }
    /// Kutunun zemini (degradede başlangıç ucu: sol ya da üst). Opak çizilir.
    public var background: String
    /// Degradenin öbür ucu (sağ ya da alt); düz zeminde nil.
    public var background2: String? = nil
    public var direction: Direction? = nil
    /// Zemin desenli (harita, dünya): `background` ortalama renktir.
    public var patterned = false
    /// Satır aralığı (bir satırın üstünden ötekinin üstüne), kareye oranla; tek satırda satır yüksekliği.
    public var pitch: Double
    /// Özgün yazıyı tam örten kutu: yazı tanıma kutusu ve dışına taşan harf noktaları, en çok `marginMax` piksel payla.
    /// Simgeye doğru taşmaz.
    public var cover: TextBox
    /// Kutunun yana uzayabileceği alan (yalnız tek satırlık etikette, hizanın açık tarafında): o yönde başka yazı, simge
    /// ya da kutu yok, yalnız oyunun zemini var. Simgeyle ya da komşuyla arada `ScreenFit.gapLines` kadar boşluk kalır.
    /// nil: uzayamaz.
    public var grow: TextBox? = nil
    /// Aynı listede alt alta (ya da aynı satırda) duran, özgün hâlinde aynı boydaki etiketlerin ortak numarası; grubun
    /// hepsi aynı yazı boyunda çizilir. nil: tek başına.
    public var group: Int? = nil
    /// Yazı tanıma kutusunun ucundaki simge (menü simgesi, tuş simgesi) yazının hangi yanında: örtü ve uzama o simgeye
    /// girmez, yazı o yana yaslanır (sol simgede sola, sağ simgede sağa; TV'ye `align` olarak gider). nil: simge yok.
    public var iconSide: TextLook.Align? = nil
    /// Çizim kipi (`TextPainter.Target.kind` verilince seçilir; yalnız otomatik ekran yazısında): örtme, yanına yazma ya da
    /// ikiz panel. TV'ye `mode` olarak gider; eski TV yok sayıp örter.
    public var mode: Mode = .cover
    /// `beside`/`twin`: Türkçenin yazıldığı kutu (yanına yazmada özgün yazının yanındaki boş alan, örtü boyunda; ikizde
    /// özgün yazının ikiz paneldeki yeri). TV'ye `spot`.
    public var spot: TextBox? = nil
    /// `spot`'un yana uzayabileceği alan (yalnız sol ve sağ kenarı anlamlı; yanına yazmada boş alanın tamamı, ikizde panelin
    /// iç genişliği). TV'ye `spotRoom`.
    public var spotRoom: TextBox? = nil
    /// `twin`: ikiz panelin kutusu (özgün panelin hemen üstünde ya da altında, sol kenarı hizalı, `scale` katı boyda). TV'ye `twinBox`.
    public var twin: TextBox? = nil
    /// `twin`: panelin köşe yarıçapı (ikizde), kare yüksekliğine oranla. TV'ye `radius`.
    public var radius: Double = 0
    /// `twin`: ikizin özgüne oranı (`TextPainter.twinScale`): yazı boyu ve satır aralığı bu katta. TV'ye `scale`.
    public var scale: Double = 1
    /// `twin`: konuşma balonunun kuyruğu hangi alt köşede ("left"/"right"); nil: kuyruk yok. TV'ye `tail`.
    public var tail: String? = nil
    /// `twin`: panelin solundaki kare resim (kişi resmi): karedeki yeri (kesmek için) ve ikiz paneldeki yeri.
    public var portrait: TextBox? = nil
    public var portraitTwin: TextBox? = nil
    /// Kesilmiş resim (PNG, data: adresi; en çok `TextPainter.portraitMax` piksel); çağıran keser
    /// (`TextPainter.portraitImage`). TV'ye `icon` ({src, box}).
    public var portraitImage: String? = nil
    /// `twin`: özgün panelin kenar çizgisi (panelin hemen dışındaki düz renkli ince şerit; GTA 6 kartının üstündeki renkli
    /// çizgi): ikiz de aynı çizgiyle çizilir. nil: çizgi yok. TV'ye `edge` ({color, top, right, bottom, left}).
    public var edge: Edge? = nil

    /// Kenar çizgisi: rengi ve her yandaki kalınlığı (kare yüksekliğine oranla; 0: o yanda çizgi yok).
    public struct Edge: Equatable, Sendable {
        public var color: String
        public var top: Double, right: Double, bottom: Double, left: Double
        public init(color: String, top: Double, right: Double, bottom: Double, left: Double) {
            self.color = color
            self.top = top
            self.right = right
            self.bottom = bottom
            self.left = left
        }
    }

    /// Çizim kipleri (Sinan Bey, beta.100: oyun arayüzünün hiçbir öğesi örtülmez; örtme yalnız son çare).
    /// - `cover`: türü belli olmayan yazı ("Ekranı çevir"), telefon ve hiç boş yer bulunamayan yazı: özgün yazıyı örten
    ///   kutu (eski davranış).
    /// - `beside`: zeminsiz satır (soldaki dikey menü, sekme çubuğu, tuş/ipucu listesi, kart başlığı, oyun dünyasındaki
    ///   istem): özgün yazı yerinde kalır, Türkçe arka plansız, özgün stille (renk, kalınlık, dar aile, büyük harf, kontur)
    ///   yanındaki boş alana yazılır. Listede bütün Türkçeler aynı tarafta, aynı boyda ve hizada (sağa yaslı listede solda
    ///   sağa yaslı tek sütun, sola yaslı listede sağda, sekme çubuğunda altta).
    /// - `twin`: kutu (görev paneli, harita mekân kartı, bildirim, ipucu kutusu, widget) örtülmez; en uygun boş yere (yan ›
    ///   alt › üst) özgün kutunun aynısı (zemin, kenar çizgisi, köşe, kuyruk, kişi resmi, iç boşluk, aynı yazı boyu) çizilir,
    ///   Türkçenin tamamı oraya yazılır; kutu içeriğe göre uzar.
    public enum Mode: String, Sendable { case cover, beside, twin }

    public init(background: String, pitch: Double, cover: TextBox) {
        self.background = background
        self.pitch = pitch
        self.cover = cover
    }

    /// Bu ölçüler `area` içindeki oranlarsa, aynı yerin `area`'yı içeren çerçevedeki oranları.
    public func placed(in area: TextBox) -> TextPaint {
        var paint = self
        paint.cover = cover.placed(in: area)
        paint.grow = grow?.placed(in: area)
        paint.pitch = pitch * (area.bottom - area.top)
        paint.spot = spot?.placed(in: area)
        paint.spotRoom = spotRoom?.placed(in: area)
        paint.twin = twin?.placed(in: area)
        paint.radius = radius * (area.bottom - area.top)
        paint.portrait = portrait?.placed(in: area)
        paint.portraitTwin = portraitTwin?.placed(in: area)
        if let edge {
            let h = area.bottom - area.top
            paint.edge = Edge(color: edge.color, top: edge.top * h, right: edge.right * h, bottom: edge.bottom * h,
                              left: edge.left * h)
        }
        return paint
    }
}

/// `TextPaint` ölçümü. Piksel erişimi soyuttur (`color(x, y)`): ortak deneme dosyası (Fixtures/text-paint.json) üç
/// platformda aynı yapay kareyi kurar.
public enum TextPainter {
    public typealias RGB = (r: Int, g: Int, b: Int)

    /// Ölçülecek yazı: kareye oranla kutusu ve satır yüksekliği, özgün satır sayısı, sampler'ın bulduğu zemin/yazı rengi
    /// ve hizası.
    public struct Target: Sendable {
        public var box: TextBox
        public var lineHeight: Double
        public var rows: Int
        public var background: String
        public var foreground: String
        public var upper: Bool
        public var align: TextLook.Align
        /// Okunan yazının sözcük sayısı (simge sanılan karakterler sayılmaz, `words(_:)`); 0: bilinmiyor, kutunun ucundaki
        /// simge aranmaz.
        public var words: Int
        /// Yazının türü (`ScreenTextKind`): verilirse çizim kipi seçilir (`TextPaint.mode`); nil: hep örtme ("Ekranı çevir").
        public var kind: ScreenTextKind? = nil
        /// Yazı bir tuş istemi/eylemi ("Hold L2 to aim", "Press ✕ to enter"): düz zeminde de yanına yazılabilir.
        public var prompt = false

        public init(box: TextBox, lineHeight: Double, rows: Int, background: String, foreground: String, upper: Bool,
                    align: TextLook.Align, words: Int = 0, kind: ScreenTextKind? = nil, prompt: Bool = false) {
            self.box = box
            self.lineHeight = lineHeight
            self.rows = rows
            self.background = background
            self.foreground = foreground
            self.upper = upper
            self.align = align
            self.words = words
            self.kind = kind
            self.prompt = prompt
        }
    }

    /// Kutunun ucundaki simgeyi yazıdan ayıran en dar boşluk, satır yüksekliğinin katı (harf arası bundan dardır; GTA 6
    /// menüsünde simgeyle yazı arası ~0,4 satır).
    public static let iconGapLines = 0.3
    /// Simge parçasının genişliği satır yüksekliğinin bu katları arasında ("I" harfi gibi ince parça simge sayılmaz).
    public static let iconMinWide = 0.45
    public static let iconMaxWide = 1.6
    /// Simge sanılıp yazı olarak okunan karakterler (GTA 6 menü simgesi "I", "II"; tuş simgeleri).
    static let iconGlyphs: Set<Character> = ["I", "|", "l", "!", "[", "]", "(", ")", "©", "®", "@", "○", "◯", "●", "□",
                                             "■", "△", "▲", "✕", "✖", "×", "◎", "⊗", "⊙"]

    /// Okunan yazının sözcük sayısı: simge sanılan bir iki karakterlik parçalar ve harfi/rakamı olmayan parçalar sayılmaz
    /// ("I Map" → 1, "SELECT ⊗" → 1, "- SMASH 'N' GRABS" → 3, "• Objective" → 1). Menü simgesi (yön tuşu, renkli nokta)
    /// "-", "•", "+" diye okununca sözcük sayılıyor, parça sayısı sözcükten fazla çıkmıyor, simge bulunmuyordu: kutu
    /// simgenin üstüne çiziliyordu (#1268, #1270).
    public static func words(_ text: String) -> Int {
        IconText.plain(text).split(whereSeparator: \.isWhitespace).filter { token in
            !(token.count <= 2 && token.allSatisfy { iconGlyphs.contains($0) })
                && token.contains { $0.isLetter || $0.isNumber }
        }.count
    }

    /// Kutunun ([l, r), piksel) ucundaki simge: harf sütunları (`ink(x)`) `iconGapLines` satırdan geniş boşluklarla
    /// parçalara bölünür; parça sayısı sözcük sayısından çoksa uçtaki simge genişliğindeki (`iconMinWide`-`iconMaxWide`
    /// satır) parça simgedir. İki uç da uyarsa hizanın yanı (sola yaslıda sol, öbürlerinde sağ) önce; ikincisi ancak iki
    /// fazla parça varsa. Simgeler çıkınca kalan parça sözcüklerden çoksa simge yoktur. Dönen: simgeler ve onlar çıkınca
    /// yazının sol/sağ kenarı.
    static func iconSpans(l: Int, r: Int, line: Double, words: Int, align: TextLook.Align, ink: (Int) -> Bool)
        -> (left: (l: Int, r: Int)?, right: (l: Int, r: Int)?, textLeft: Int, textRight: Int) {
        guard words > 0, r - l >= 2 else { return (nil, nil, l, r) }
        let gap = max(2, Int((iconGapLines * line).rounded()))
        var spans: [(l: Int, r: Int)] = []
        var start: Int? = nil, last = l, blank = 0
        for x in l..<r {
            if ink(x) {
                if start == nil { start = x }
                last = x
                blank = 0
            } else if let s = start {
                blank += 1
                if blank >= gap { spans.append((s, last + 1)); start = nil; blank = 0 }
            }
        }
        if let s = start { spans.append((s, last + 1)) }
        guard spans.count >= 2, spans.count > words else { return (nil, nil, l, r) }
        func isIcon(_ span: (l: Int, r: Int)) -> Bool {
            let wide = Double(span.r - span.l)
            return wide >= iconMinWide * line && wide <= iconMaxWide * line
        }
        let extra = spans.count - words
        let first = spans[0], final = spans[spans.count - 1]
        var left: (l: Int, r: Int)? = nil, right: (l: Int, r: Int)? = nil
        if align == .left {
            if isIcon(first) { left = first }
            if isIcon(final), left == nil || extra >= 2 { right = final }
        } else {
            if isIcon(final) { right = final }
            if isIcon(first), right == nil || extra >= 2 { left = first }
        }
        // Simgeler çıkınca kalan parçalar sözcüklerden çok olamaz: harfleri aralıklı tek sözcük ("P R O G R E S S")
        // simge sanılmaz.
        if spans.count - (left == nil ? 0 : 1) - (right == nil ? 0 : 1) > words { return (nil, nil, l, r) }
        return (left, right, left != nil ? spans[1].l : l, right != nil ? spans[spans.count - 2].r : r)
    }

    /// Nokta zeminden bu kadar (en büyük renk bileşeni farkı) uzak ve yazı rengine zeminden yakınsa harf noktasıdır.
    public static let inkDistance = 40
    /// Bir satır/sütunun en az bu kadarı harf noktasıysa orada yazı sürer.
    public static let inkShare = 0.03
    /// Kutu yazı tanıma kutusunun dışına en çok bu kadar satır yüksekliği uzar (taşan harf ucu).
    public static let reachLines = 0.5
    /// Kenar payı: satır yüksekliğinin bu kadarı, en az 1, en çok `marginMax` piksel.
    public static let marginLines = 0.08
    public static let marginMax = 3
    /// İki uç arasındaki fark (en büyük renk bileşeni) en az bu kadarsa zemin degradedir.
    public static let gradientStep = 10
    /// Zeminin kendi içindeki sapması bundan büyükse zemin desenlidir.
    public static let patternDeviation = TextStyleSampler.flatDeviation
    /// Kenar şeridinin ortalaması sampler'ın zemininden bu kadar uzaksa (seçili satırın kendi kutusu dar) sampler'ınki kalır.
    public static let trustDistance = 48
    /// Boş alan en çok bu kadar satır yüksekliği taranır.
    public static let growLines = 12.0
    /// Aynı grup: satır yükseklikleri en çok bu oranda farklı (`ScreenFit.sameLine`).
    public static let sameLine = ScreenFit.sameLine

    // MARK: Kip seçimi sabitleri (Windows TextPaint.cs, Android TextPaint.kt aynı)

    /// Panel taramasında nokta zeminden en çok bu kadar uzaksa (en büyük renk bileşeni farkı) panelin zeminidir.
    public static let panelTolerance = 24
    /// Bir satır/sütunun en az bu kadarı zemin (ya da yazı) ise panel o yöne sürer.
    public static let panelShare = 0.7
    /// Panel karenin en çok bu kadarı genişlikte/yükseklikte; daha büyüğü (gökyüzü, menünün kendisi) panel sayılmaz.
    public static let panelMaxWidth = 0.45
    public static let panelMaxHeight = 0.35
    /// Panel yazının her yanında en az bu kadar satır yüksekliği (en az 2 piksel) taşmalı; taşmıyorsa düz kutudur (örtülür).
    public static let panelPadLines = 0.2
    /// Köşe yuvarlak: panelin köşesinden köşegen boyunca en az bu kadar nokta zemin değil (aynı kenardaki iki köşede).
    public static let cornerMin = 2
    /// Yanına yazmada bir sütunda/satırda yazı rengine (`besideInk` kadar yakın) noktaların payı bundan azsa alan boştur.
    public static let besideInk = 48
    public static let besideShare = 0.1
    /// Türkçenin özgün yazıdan uzaklığı, satır yüksekliğinin katı.
    public static let besideGapLines = 0.5
    /// Yanına yazma alanı en çok özgün yazının bu katı (+ bir satır yüksekliği) genişlikte taranır.
    public static let besideMax = 1.6
    /// Listede (grup) Türkçe sütunu özgün yazıdan en çok bu kadar satır yüksekliği uzakta olabilir (kısa satırla sütun
    /// arasındaki boşluk da boş olmalı).
    public static let besideReachLines = 12.0
    /// İkiz panel özgün panelle aynı boyda (Sinan Bey, beta.100: "AYNI punto, küçültme yok"; #1296'daki 0,58 kalktı).
    public static let twinScale = 1.0
    /// İkizdeki yazı özgün panelin genişliğini en çok bu katı kadar aşabilir (boş yer varsa; kutu içeriğe göre uzar).
    public static let twinWiden = 0.5
    /// Kenar çizgisi en çok bu kadar piksel kalın aranır.
    public static let edgeMax = 8
    /// Kişi resmi (ikiz panelde gösterilir) en çok bu kadar piksel kenarlı kesilir.
    public static let portraitMax = 40

    /// Yazının (örtü kutusu [l, r) x [t, b)) çevresindeki düz alan: kutu, satır/sütunlarının en az `panelShare`'i zemin
    /// (`like`: zemin, yazının kendi örtü kutusu ya da başka hedef; harf noktası sayılmaz, koyu oyun dünyası koyu yazıya
    /// benzer) olduğu sürece dört yana büyür. Karenin kenarına değen ya da `panelMaxWidth`/`panelMaxHeight`'tan büyük alan
    /// açık zemindir (gökyüzü, menünün kendisi): nil.
    /// `from..<to` aralığında `step` adımla alınan noktaların en az `share`'i `ok` mu (en az bir nokta). Sonuç belli olunca
    /// durur: kalan noktalar sonucu değiştiremez (`ok` yan etkisiz; bütün kare ölçümünde çağrı sayısı azalır, sonuç aynı).
    /// Android TextPaint.kt ve Windows TextPaint.cs aynı.
    static func shareAtLeast(from: Int, to: Int, step: Int, share: Double, _ ok: (Int) -> Bool) -> Bool {
        guard to > from else { return false }
        let total = (to - from + step - 1) / step
        let need = share * Double(total)
        var hits = 0, seen = 0, at = from
        while at < to {
            if ok(at) {
                hits += 1
                if Double(hits) >= need { return true }
            }
            seen += 1
            if Double(hits + (total - seen)) < need { return false }
            at += step
        }
        return Double(hits) >= need
    }

    /// Boş alan sütunu/satırı (`measureRoom`): `from..<to` noktalarından hiçbiri engel (nil) değil ve yazı rengindekiler
    /// `besideShare`'den az. İlk engelde ya da pay dolunca durur (sonuç aynı).
    static func roomOpen(from: Int, to: Int, _ free: (Int) -> Bool?) -> Bool {
        guard to > from else { return false }
        let limit = besideShare * Double(to - from)
        var ink = 0
        for at in from..<to {
            guard let cell = free(at) else { return false }
            if cell {
                ink += 1
                if Double(ink) >= limit { return false }
            }
        }
        return true
    }

    static func findPanel(l: Int, t: Int, r: Int, b: Int, width: Int, height: Int,
                          like: (Int, Int) -> Bool) -> (l: Int, t: Int, r: Int, b: Int)? {
        func row(_ y: Int, _ x0: Int, _ x1: Int) -> Bool {
            shareAtLeast(from: x0, to: x1, step: max(1, (x1 - x0) / 64), share: panelShare) { like($0, y) }
        }
        func column(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
            shareAtLeast(from: y0, to: y1, step: max(1, (y1 - y0) / 64), share: panelShare) { like(x, $0) }
        }
        guard r > l, b > t else { return nil }
        let maxW = Int(panelMaxWidth * Double(width)), maxH = Int(panelMaxHeight * Double(height))
        var pl = max(0, l), pt = max(0, t), pr = min(width, r), pb = min(height, b)
        var grew = true
        while grew {
            grew = false
            while pl > 0, column(pl - 1, pt, pb) {
                pl -= 1
                grew = true
                if pr - pl > maxW { return nil }
            }
            while pr < width, column(pr, pt, pb) {
                pr += 1
                grew = true
                if pr - pl > maxW { return nil }
            }
            while pt > 0, row(pt - 1, pl, pr) {
                pt -= 1
                grew = true
                if pb - pt > maxH { return nil }
            }
            while pb < height, row(pb, pl, pr) {
                pb += 1
                grew = true
                if pb - pt > maxH { return nil }
            }
        }
        if pl == 0 || pt == 0 || pr == width || pb == height { return nil }
        return (pl, pt, pr, pb)
    }

    /// Panelin ([l, r) x [t, b)) köşe yarıçapı (piksel) ve konuşma balonunun kuyruğu: köşeler (`ground`: yalnız zemin)
    /// köşegen boyunca taranır; üst ya da alt kenarın iki köşesinde en az `cornerMin` nokta zemin değilse panel yuvarlaktır,
    /// yarıçap köşegendeki mesafeden (k / (1 − 1/√2)). Üst köşeler yuvarlakken alt köşelerden yalnız biri köşeliyse o
    /// köşede balonun kuyruğu vardır ("left"/"right"). nil: köşeli kutu.
    static func cornerRadius(l: Int, t: Int, r: Int, b: Int, ground: (Int, Int) -> Bool) -> (radius: Double, tail: String?)? {
        let limit = max(1, min(r - l, b - t) / 4)
        func corner(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int) -> Int {
            var k = 0
            while k <= limit, !ground(x + dx * k, y + dy * k) { k += 1 }
            return k
        }
        let tl = corner(l, t, 1, 1), tr = corner(r - 1, t, -1, 1)
        let bl = corner(l, b - 1, 1, -1), br = corner(r - 1, b - 1, -1, -1)
        func round(_ k: Int) -> Bool { k >= cornerMin && k <= limit }
        let top = round(tl) && round(tr), bottom = round(bl) && round(br)
        guard top || bottom else { return nil }
        let ks = (top ? [tl, tr] : []) + (bottom ? [bl, br] : [])
        let radius = Double(ks.reduce(0, +)) / Double(ks.count) / (1 - 1 / 2.0.squareRoot())
        let tail: String? = !top || bottom ? nil : !round(bl) && round(br) ? "left" : round(bl) && !round(br) ? "right" : nil
        return (radius, tail)
    }

    /// Panelin solundaki kare resim (kişi resmi): panelin solu ile yazının arası, yazının satırı çevresinde (bir satır
    /// yüksekliği yukarı/aşağı); `off` (zeminden belirgin ayrılan, başka yazı olmayan) noktaların sınırı. En az 0,8 satır
    /// yüksekliği (en az 6 piksel), en çok 4 satır yüksekliği, kareye yakın (0,75–1,33) ve yazıdan ayrıksa resimdir.
    static func portrait(panelLeft: Int, panelTop: Int, panelBottom: Int, l: Int, t: Int, b: Int, line: Double,
                         off: (Int, Int) -> Bool) -> (l: Int, t: Int, r: Int, b: Int)? {
        let x0 = panelLeft + 2, x1 = l
        let y0 = max(panelTop + 2, t - Int(line.rounded())), y1 = min(panelBottom - 2, b + Int(line.rounded()))
        guard x1 > x0, y1 > y0 else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in y0..<y1 {
            for x in x0..<x1 where off(x, y) {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let w = maxX - minX + 1, h = maxY - minY + 1
        let least = max(6, Int((0.8 * line).rounded()))
        guard w >= least, h >= least, Double(w) <= 4 * line, Double(h) <= 4 * line,
              Double(w) >= 0.75 * Double(h), Double(w) <= 1.33 * Double(h),
              maxX + 1 + max(2, Int((ScreenFit.gapLines * line).rounded())) <= l else { return nil }
        return (minX, minY, maxX + 1, maxY + 1)
    }

    /// Kişi resmini kareden keser: en çok `portraitMax` piksel kenarlı (en yakın nokta örneklemesi), opak PNG data: adresi.
    /// `largest`: çıktının en uzun kenarı (telefon listesinin avatarı `ScreenPhoneCard.avatarMax`).
    public static func portraitImage(_ box: TextBox, width: Int, height: Int, largest: Int = portraitMax,
                                     color: (Int, Int) -> RGB) -> String? {
        let l = max(0, Int((box.left * Double(width)).rounded())), t = max(0, Int((box.top * Double(height)).rounded()))
        let r = min(width, Int((box.right * Double(width)).rounded())), b = min(height, Int((box.bottom * Double(height)).rounded()))
        guard r - l >= 2, b - t >= 2 else { return nil }
        let side = max(r - l, b - t)
        let ow = max(1, min(r - l, (r - l) * largest / side)), oh = max(1, min(b - t, (b - t) * largest / side))
        var pixels = [UInt8](repeating: 255, count: ow * oh * 4)
        for j in 0..<oh {
            for i in 0..<ow {
                let c = color(l + i * (r - l) / ow, t + j * (b - t) / oh)
                let p = (j * ow + i) * 4
                pixels[p] = UInt8(max(0, min(255, c.r)))
                pixels[p + 1] = UInt8(max(0, min(255, c.g)))
                pixels[p + 2] = UInt8(max(0, min(255, c.b)))
            }
        }
        return "data:image/png;base64," + ButtonIcons.png(pixels, stride: ow * 4, x: 0, y: 0, width: ow, height: oh)
            .base64EncodedString()
    }

    /// Kare (CGImage) üzerinden kişi resmi.
    public static func portraitImage(_ box: TextBox, frame: CGImage) -> String? {
        guard let pixels = GamePhonePixels(frame) else { return nil }
        return portraitImage(box, pixels: pixels)
    }

    static func portraitImage(_ box: TextBox, pixels: GamePhonePixels) -> String? {
        portraitImage(box, width: pixels.width, height: pixels.height) { x, y in
            let p = pixels.offset(x, y)
            return (Int(pixels.bytes[p]), Int(pixels.bytes[p + 1]), Int(pixels.bytes[p + 2]))
        }
    }

    /// Ölçümler (hedeflerle aynı sırada). `width`/`height`: karenin piksel boyu.
    public static func paints(_ targets: [Target], width: Int, height: Int, color: (Int, Int) -> RGB) -> [TextPaint] {
        guard width > 0, height > 0 else { return [] }
        let fw = Double(width), fh = Double(height)
        // Hedeflerin piksel kutuları (öbür hedefler engeldir); karenin dışına taşan kutu kareye kırpılır (#1255).
        func pixel(_ v: Double, _ size: Int, up: Bool) -> Int {
            guard v.isFinite else { return v > 0 ? size : 0 }
            let p = (v * Double(size)).rounded(up ? .up : .down)
            return Int(min(Double(size), max(0, p)))
        }
        let rects = targets.map { t in
            (l: pixel(t.box.left, width, up: false), t: pixel(t.box.top, height, up: false),
             r: pixel(t.box.right, width, up: true), b: pixel(t.box.bottom, height, up: true))
        }
        var result: [TextPaint] = []
        // Kip seçimi için: örtü kutuları (piksel), satır yükseklikleri ve ikiz panel adayları.
        var covers: [(l: Int, t: Int, r: Int, b: Int)] = []
        var lines: [Double] = []
        var grounds: [RGB] = []
        var panels: [Int: (l: Int, t: Int, r: Int, b: Int)] = [:]
        // Yanına yazma için her hedefin çevresindeki boş alan (yalnız kipi seçilen yazıda).
        var rooms: [Room?] = []
        /// Bir hedefin kutusu (`except` hariç) bu noktada mı.
        func rectHit(_ x: Int, _ y: Int, except: Int?) -> Bool {
            rects.indices.contains { j in j != except && x >= rects[j].l && x < rects[j].r && y >= rects[j].t && y < rects[j].b }
        }
        for (index, target) in targets.enumerated() {
            let bg = rgb(target.background), fg = rgb(target.foreground)
            let line = max(1, target.lineHeight * fh)
            func isInk(_ c: RGB) -> Bool {
                let toBg = distance(c, bg)
                return toBg > inkDistance && distance(c, fg) < toBg
            }
            // Kutunun ucundaki kendi simgesi (0. adım): öbür hedefler gibi engeldir; araya `ScreenFit.gapLines` boşluk kalır.
            var zones: [(l: Int, r: Int)] = []
            func others(_ x: Int, _ y: Int) -> Bool {
                zones.contains { x >= $0.l && x < $0.r }
                    || rects.indices.contains { j in j != index && x >= rects[j].l && x < rects[j].r && y >= rects[j].t && y < rects[j].b }
            }
            func inkRow(_ y: Int, _ x0: Int, _ x1: Int) -> Bool {
                guard y >= 0, y < height, x1 > x0 else { return false }
                let step = max(1, (x1 - x0) / 200)
                var n = 0, ink = 0
                for x in stride(from: max(0, x0), to: min(width, x1), by: step) {
                    if others(x, y) { return false }
                    n += 1
                    if isInk(color(x, y)) { ink += 1 }
                }
                return n > 0 && ink >= max(2, Int((inkShare * Double(n)).rounded(.up)))
            }
            func inkColumn(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
                guard x >= 0, x < width, y1 > y0 else { return false }
                var n = 0, ink = 0
                for y in max(0, y0)..<min(height, y1) {
                    if others(x, y) { return false }
                    n += 1
                    if isInk(color(x, y)) { ink += 1 }
                }
                return n > 0 && ink >= max(1, Int((inkShare * Double(n)).rounded(.up)))
            }
            var (l, t, r, b) = rects[index]
            // 0) Kutunun ucundaki simge (#1266, #1267): yazı tanıma kutusu menü/tuş simgesini de alıyordu; kutu simgenin
            // üstüne çiziliyor, simge kayboluyordu. Simge kutudan çıkar ve engel olur: örtü, kenar payı ve uzama ona girmez.
            var iconLeft = false, iconRight = false
            if target.rows <= 1 {
                let found = iconSpans(l: l, r: r, line: line, words: target.words, align: target.align) { x in
                    inkColumn(x, t, b)
                }
                let keep = Int((ScreenFit.gapLines * line).rounded(.up))
                if let icon = found.left { zones.append((icon.l - keep, icon.r + keep)); iconLeft = true }
                if let icon = found.right { zones.append((icon.l - keep, icon.r + keep)); iconRight = true }
                l = found.textLeft
                r = found.textRight
            }
            let textLeft = l, textRight = r
            // 1) Örtü: yazı tanıma kutusunun dışına taşan harf noktaları (bitişik satır/sütunlar) kutuya katılır.
            let reach = max(1, Int((reachLines * line).rounded()))
            var y = b
            while y < min(height, rects[index].b + reach), inkRow(y, l, r) { y += 1 }
            b = y
            y = t - 1
            while y >= max(0, rects[index].t - reach), inkRow(y, l, r) { y -= 1 }
            t = y + 1
            var x = r
            while x < min(width, textRight + reach), inkColumn(x, t, b) { x += 1 }
            r = x
            x = l - 1
            while x >= max(0, textLeft - reach), inkColumn(x, t, b) { x -= 1 }
            l = x + 1
            // Kenar payı: yazının yanındaki boş noktalar; ötesinde başka yazı/simge varsa pay ona değmez.
            let margin = max(1, min(marginMax, Int((marginLines * line).rounded())))
            func pad(_ blank: (Int) -> Bool) -> Int {
                var k = 0
                while k < margin, blank(k + 1) { k += 1 }
                return k
            }
            let padL = pad { k in l - k >= 0 && !inkColumn(l - k, t, b) && !(t..<b).contains { others(l - k, $0) } }
            let padR = pad { k in r - 1 + k < width && !inkColumn(r - 1 + k, t, b) && !(t..<b).contains { others(r - 1 + k, $0) } }
            let padT = pad { k in t - k >= 0 && !inkRow(t - k, l, r) }
            let padB = pad { k in b - 1 + k < height && !inkRow(b - 1 + k, l, r) }
            let cl = l - padL, cr = r + padR, ct = t - padT, cb = b + padB
            let cover = TextBox(left: Double(cl) / fw, top: Double(ct) / fh, right: Double(cr) / fw, bottom: Double(cb) / fh)

            // 2) Zemin: kutunun üstündeki ve altındaki şerit (yanlarda simge olabilir); sol/sağ üçte bir ve üst/alt farkı.
            let strip = max(2, Int((0.25 * line).rounded()))
            var samples: [(c: RGB, fx: Double, top: Bool)] = []
            func collect(_ y0: Int, _ y1: Int, top: Bool) {
                guard y0 >= 0, y1 <= height, y1 > y0 else { return }
                let step = max(1, (cr - cl) / 64)
                let rowStep = max(1, (y1 - y0) / 4)
                var strip: [(c: RGB, fx: Double, top: Bool)] = []
                for yy in stride(from: y0, to: y1, by: rowStep) {
                    for xx in stride(from: max(0, cl), to: min(width, cr), by: step) {
                        if others(xx, yy) { return }
                        let c = color(xx, yy)
                        if isInk(c) { continue }
                        strip.append((c, Double(xx - cl) / Double(max(1, cr - cl - 1)), top))
                    }
                }
                samples += strip
            }
            collect(ct - strip, ct, top: true)
            collect(cb, cb + strip, top: false)
            var paint = TextPaint(background: target.background, pitch: pitch(target), cover: cover)
            paint.iconSide = iconLeft == iconRight ? nil : iconLeft ? .left : .right
            if samples.count >= 16 {
                let all = samples.map(\.c)
                let average = mean(all)
                if distance(average, bg) <= trustDistance {
                    let left = samples.filter { $0.fx < 1.0 / 3 }.map(\.c), right = samples.filter { $0.fx > 2.0 / 3 }.map(\.c)
                    let above = samples.filter(\.top).map(\.c), below = samples.filter { !$0.top }.map(\.c)
                    // Desen: her parçanın kendi içindeki sapması (degrade kendi başına desen sayılmaz).
                    var parts: [[RGB]] = []
                    for side in [true, false] {
                        for third in 0..<3 {
                            let part: [RGB] = samples.filter { $0.top == side && min(2, Int($0.fx * 3)) == third }.map(\.c)
                            if part.count >= 4 { parts.append(part) }
                        }
                    }
                    let spread = parts.isEmpty ? deviation(all) : parts.map(deviation).reduce(0, +) / Double(parts.count)
                    let dh = left.count >= 4 && right.count >= 4 ? distance(mean(left), mean(right)) : 0
                    let dv = above.count >= 4 && below.count >= 4 ? distance(mean(above), mean(below)) : 0
                    if spread > patternDeviation {
                        paint.patterned = true
                        paint.background = hex(average)
                    } else if dh >= gradientStep, dh >= dv {
                        // Üçte birlerin ortası 1/6 ve 5/6'da: uçlara doğrusal uzatılır.
                        let a = mean(left), z = mean(right)
                        paint.background = hex(extend(a, z, 0.25))
                        paint.background2 = hex(extend(z, a, 0.25))
                        paint.direction = .horizontal
                    } else if dv >= gradientStep {
                        let a = mean(above), z = mean(below)
                        // Şeritlerin ortası kutunun yarım şerit dışında: uçlar içeri doğru aradeğerlenir.
                        let span = Double(cb - ct + strip)
                        let inward = span > 0 ? Double(strip) / 2 / span : 0
                        paint.background = hex(extend(a, z, -inward))
                        paint.background2 = hex(extend(z, a, -inward))
                        paint.direction = .vertical
                    } else {
                        paint.background = hex(average)
                    }
                }
            }

            // 3) Boş alan: tek satırlık etiket hizasının açık tarafına (sağa yaslıda sola, sola yaslıda sağa, ortalıda iki
            // yana) uzayabilir; başka yazıya, simgeye, kutu kenarına ya da karenin kenarına `gapLines` kala durur. Kutunun
            // ucunda simge varsa yalnız simgenin öbür yanına uzar (sağdaki tuş simgesinde sola, soldaki menü simgesinde sağa).
            if target.rows <= 1 {
                let band = stride(from: ct + max(1, (cb - ct) / 6), to: max(ct + 1, cb - max(1, (cb - ct) / 6)),
                                  by: max(1, (cb - ct) / 6)).map { min(height - 1, max(0, $0)) }
                let gap = Int((ScreenFit.gapLines * line).rounded(.up))
                let limit = Int((growLines * line).rounded())
                func scan(from start: Int, step: Int, ground first: RGB) -> Int {
                    var ground = first
                    var x = start
                    let end = step < 0 ? max(-1, start - limit) : min(width, start + limit)
                    // Sınır karşılaştırması ve adım sınırı: başlangıç karenin dışında kalsa da döngü biter (#1255).
                    var steps = 0
                    while step < 0 ? x > end : x < end, x >= 0, x < width, steps <= width {
                        steps += 1
                        if band.contains(where: { others(x, $0) }) || rects.indices.contains(where: { j in
                            j != index && x >= rects[j].l && x < rects[j].r && rects[j].b > ct && rects[j].t < cb
                        }) { return x - step * gap }
                        var sum = (0, 0, 0)
                        for yy in band {
                            let c = color(x, yy)
                            if distance(c, ground) > ScreenFit.inkDistance { return x - step * gap }
                            sum = (sum.0 + c.r, sum.1 + c.g, sum.2 + c.b)
                        }
                        let n = band.count
                        // Degrade zeminde zemin yavaşça izlenir (ScreenFit.withRoom ile aynı).
                        ground = ((ground.r * 7 + sum.0 / n) / 8, (ground.g * 7 + sum.1 / n) / 8, (ground.b * 7 + sum.2 / n) / 8)
                        x += step
                    }
                    return step < 0 ? max(0, end + 1) : min(width, end)
                }
                let startColor = rgb(paint.background), endColor = rgb(paint.background2 ?? paint.background)
                var gl = cl, gr = cr
                let toLeft = !iconLeft && (target.align != .left || iconRight)
                let toRight = !iconRight && (target.align != .right || iconLeft)
                if !band.isEmpty, toLeft { gl = min(cl, max(0, scan(from: cl - 1, step: -1, ground: startColor) + 1)) }
                if !band.isEmpty, toRight { gr = max(cr, min(width, scan(from: cr, step: 1, ground: endColor))) }
                if gl < cl || gr > cr {
                    paint.grow = TextBox(left: Double(gl) / fw, top: cover.top, right: Double(gr) / fw, bottom: cover.bottom)
                }
            }

            // 5) Kip (yalnız türü verilen yazıda; telefon hep örtülür): düz zemini sınırlı bir alansa (panel) karar döngüden
            // sonra panel panel verilir (kutu: ikiz; listedeki satırın kendi şeridi/vurgusu: yanına yazma). Açık zeminde
            // (desenli zemin, degrade, karenin kenarına değen ya da çok büyük düz alan) Türkçe yanındaki boş alana yazılır;
            // listede bütün satırlar birlikte (aynı yan, aynı hiza). Yer bulunamazsa örtülür.
            covers.append((cl, ct, cr, cb))
            lines.append(line)
            grounds.append(rgb(paint.background))
            if let kind = target.kind, kind != .phone {
                let ground = rgb(paint.background)
                let panel = paint.patterned || paint.background2 != nil ? nil
                    : findPanel(l: cl, t: ct, r: cr, b: cb, width: width, height: height) { x, y in
                        if rectHit(x, y, except: index) || (x >= cl && x < cr && y >= ct && y < cb) { return true }
                        return distance(color(x, y), ground) <= panelTolerance
                    }
                if let panel { panels[index] = panel }
                rooms.append(measureRoom(l: cl, t: ct, r: cr, b: cb, line: line, width: width, height: height,
                                         iconLeft: iconLeft, iconRight: iconRight) { x, y in
                    if others(x, y) { return nil }
                    return distance(color(x, y), fg) <= besideInk
                })
            } else {
                rooms.append(nil)
            }
            result.append(paint)
        }
        func overlaps(_ a: (l: Int, t: Int, r: Int, b: Int), _ b: (l: Int, t: Int, r: Int, b: Int)) -> Bool {
            min(a.r, b.r) > max(a.l, b.l) && min(a.b, b.b) > max(a.t, b.t)
        }
        // Listeler (`groups`): aynı sütunda ya da aynı satırda duran, aynı boydaki tek satırlık etiketler.
        let lists = groups(targets)
        var listOf: [Int: Int] = [:]
        for (k, list) in lists.enumerated() { for m in list.0 { listOf[m] = k } }

        // 6) Kutular (ikiz): kesişen paneller tek paneldir (bildirimin başlığı ve gövdesi, kartın başlığı, açıklaması ve
        // ayrıntıları), kutusu hepsinin birleşimi. Her yazı panelin içinde her yanda `panelPadLines` boşlukla durmalı;
        // durmuyorsa panel yazının kendi şerididir (yanına yazılır). Tek satırlık tek yazılı panel listenin satırıysa (kart
        // başlığının koyu şeridi, seçili satırın açık vurgusu) kutu değil satırdır. İkiz özgünle aynı boyda (yazı, resim,
        // köşe, iç boşluk, kenar çizgisi), en uygun boş yere: yan (ekranın ortasına bakan yan önce) › alt › üst; başka
        // yazıya, başka kutuya ve karenin dışına taşmaz. Yer yoksa örtülür (son çare).
        // Zemini degrade ya da desenli ölçülen yazı (yarı saydam kartın altından harita görünüyor) başka yazının bulduğu
        // panelin içindeyse o paneldedir: kartın başlığı ve açıklaması ayrıntı satırlarıyla tek kart olur (beta.100 3407–3409:
        // kartın parçaları ayrı yamalarla örtülüyordu).
        // Kesişen paneller önce birleşir (yarı saydam kartta her yazının taraması kartın bir parçasında durabilir); yazının
        // örtüsünün en az %80'i birleşik panelin içindeyse yazı o paneldedir.
        var merged: [(l: Int, t: Int, r: Int, b: Int)] = []
        for p in panels.keys.sorted() {
            var box = panels[p]!
            var changed = true
            while changed {
                changed = false
                if let k = merged.firstIndex(where: { overlaps($0, box) }) {
                    let o = merged.remove(at: k)
                    box = (min(o.l, box.l), min(o.t, box.t), max(o.r, box.r), max(o.b, box.b))
                    changed = true
                }
            }
            merged.append(box)
        }
        for i in targets.indices where rooms[i] != nil && panels[i] == nil {
            let c = covers[i]
            let area = Double(max(1, (c.r - c.l) * (c.b - c.t)))
            if let inside = merged.first(where: { p in
                Double(max(0, min(p.r, c.r) - max(p.l, c.l)) * max(0, min(p.b, c.b) - max(p.t, c.t))) >= 0.8 * area
            }) {
                panels[i] = inside
            }
        }
        let keys = panels.keys.sorted()
        var parent = Dictionary(uniqueKeysWithValues: keys.map { ($0, $0) })
        func root(_ i: Int) -> Int { var i = i; while parent[i]! != i { i = parent[i]! }; return i }
        for a in keys {
            for b in keys where b > a && overlaps(panels[a]!, panels[b]!) { parent[root(b)] = root(a) }
        }
        var boxes: [(members: [Int], l: Int, t: Int, r: Int, b: Int)] = []
        for members in Dictionary(grouping: keys, by: root).values.map({ $0.sorted() }).sorted(by: { $0[0] < $1[0] }) {
            let l = members.map { panels[$0]!.l }.min()!, t = members.map { panels[$0]!.t }.min()!
            let r = members.map { panels[$0]!.r }.max()!, b = members.map { panels[$0]!.b }.max()!
            let padded = members.allSatisfy { m in
                let c = covers[m], pad = max(2, Int((panelPadLines * lines[m]).rounded()))
                return c.l - l >= pad && r - c.r >= pad && c.t - t >= pad && b - c.b >= pad
            }
            let box = members.count >= 2 || targets[members[0]].rows > 1 || listOf[members[0]] == nil
            if padded && box { boxes.append((members, l, t, r, b)) }
        }
        let boxed = Set(boxes.flatMap(\.members))
        var twins: [(l: Int, t: Int, r: Int, b: Int)] = []
        for box in boxes {
            let (members, l, t, r, b) = box
            let ground = grounds[members[0]]
            let line = lines[members[0]]
            // Zemin: panelin yazı dışındaki noktalarının ortalaması (yazının çevresindeki şeritten daha doğru ton).
            var sum = (0, 0, 0), count = 0
            let stepX = max(1, (r - l) / 24), stepY = max(1, (b - t) / 24)
            for y in stride(from: t, to: b, by: stepY) {
                for x in stride(from: l, to: r, by: stepX) where !rectHit(x, y, except: nil) {
                    let c = color(x, y)
                    guard distance(c, ground) <= panelTolerance else { continue }
                    sum = (sum.0 + c.r, sum.1 + c.g, sum.2 + c.b)
                    count += 1
                }
            }
            let fill: RGB = count >= 8 ? (sum.0 / count, sum.1 / count, sum.2 / count) : ground
            let corner = cornerRadius(l: l, t: t, r: r, b: b) { x, y in distance(color(x, y), ground) <= panelTolerance }
            let edge = edges(l: l, t: t, r: r, b: b, width: width, height: height, ground: fill,
                             blocked: { x, y in rectHit(x, y, except: nil) }, color: color)
            let el = edge?.left ?? 0, et = edge?.top ?? 0, er = edge?.right ?? 0, eb = edge?.bottom ?? 0
            let ow = r - l + el + er, oh = b - t + et + eb, ox = l - el, oy = t - et
            let gap = max(2, Int((ScreenFit.gapLines * line).rounded(.up)))
            func blocked(_ a: (l: Int, t: Int, r: Int, b: Int)) -> Bool {
                a.l < 0 || a.t < 0 || a.r > width || a.b > height
                    || rects.indices.contains { j in !members.contains(j) && overlaps(a, rects[j]) }
                    || boxes.contains { overlaps(a, ($0.l, $0.t, $0.r, $0.b)) } || twins.contains { overlaps(a, $0) }
            }
            let sides = (l + r) / 2 < width / 2 ? [(ox + ow + gap, oy), (ox - gap - ow, oy)] : [(ox - gap - ow, oy), (ox + ow + gap, oy)]
            let candidates = sides + [(ox, oy + oh + gap), (ox, oy - gap - oh)]
            guard let at = candidates.first(where: { !blocked(($0.0, $0.1, $0.0 + ow, $0.1 + oh)) }) else { continue }
            twins.append((at.0, at.1, at.0 + ow, at.1 + oh))
            let dx = at.0 - ox, dy = at.1 - oy
            // İkizdeki Türkçe özgün panelden uzunsa ikiz sağa uzar (boş yer varsa, en çok `twinWiden`).
            var widen = Int(twinWiden * Double(r - l))
            for j in rects.indices where !members.contains(j) && rects[j].t < b + dy && rects[j].b > t + dy && rects[j].l >= r + dx {
                widen = min(widen, rects[j].l - (r + dx) - er - gap)
            }
            for other in boxes.map({ ($0.l, $0.t, $0.r, $0.b) }) + [(l, t, r, b)]
                where other.1 < b + dy && other.3 > t + dy && other.0 >= r + dx {
                widen = min(widen, other.0 - (r + dx) - er - gap)
            }
            widen = max(0, min(widen, width - (r + dx) - er))
            func x(_ v: Int) -> Double { Double(v + dx) / fw }
            func y(_ v: Int) -> Double { Double(v + dy) / fh }
            var face: (l: Int, t: Int, r: Int, b: Int)? = nil
            for m in members where face == nil {
                face = portrait(panelLeft: l, panelTop: t, panelBottom: b, l: covers[m].l, t: covers[m].t, b: covers[m].b,
                                line: lines[m]) { x, y in
                    !rectHit(x, y, except: nil) && distance(color(x, y), ground) > 2 * panelTolerance
                }
            }
            let inset = max(gap, members.map { covers[$0].l - l }.min() ?? gap)
            for m in members {
                let c = covers[m], align = targets[m].align
                var paint = result[m]
                paint.mode = .twin
                paint.scale = twinScale
                paint.tail = corner?.tail
                paint.background = hex(fill)
                paint.background2 = nil
                paint.direction = nil
                paint.patterned = false
                paint.twin = TextBox(left: x(l), top: y(t), right: x(r), bottom: y(b))
                paint.radius = (corner?.radius ?? 0) / fh
                paint.spot = TextBox(left: x(c.l), top: y(c.t), right: x(c.r), bottom: y(c.b))
                paint.spotRoom = TextBox(left: align == .left ? x(c.l) : x(l + inset), top: y(c.t),
                                         right: max(x(c.r), x(r - inset + widen)), bottom: y(c.b))
                if let edge {
                    paint.edge = TextPaint.Edge(color: hex(edge.color), top: Double(et) / fh, right: Double(er) / fh,
                                                bottom: Double(eb) / fh, left: Double(el) / fh)
                }
                if let face {
                    paint.portrait = TextBox(left: Double(face.l) / fw, top: Double(face.t) / fh, right: Double(face.r) / fw,
                                             bottom: Double(face.b) / fh)
                    paint.portraitTwin = TextBox(left: x(face.l), top: y(face.t), right: x(face.r), bottom: y(face.b))
                }
                result[m] = paint
            }
        }

        // 7) Satırlar (yanına yazma): listede bütün satırlar aynı yana (sağa yaslı sütunda sol, sola yaslı sütunda sağ;
        // satırdaki sekme/kart başlıklarında hizanın açık yanı, sonra alt, sonra üst), sütunda Türkçeler tek hizada (sağa
        // yaslı listede sağ kenarları, sola yaslıda sol kenarları aynı), satırda aynı taban çizgisinde. Bir yan ancak listenin
        // bütün satırlarına yer varsa ve hiçbiri önceden yerleşen Türkçeye ya da ikiz kutuya binmiyorsa seçilir; değilse
        // sıradaki yan denenir (çakışma örtmeye döndürmez). Hiçbir yana birlikte sığmazsa en çok satırın sığdığı yan seçilir;
        // sığmayan satır kendi başına önce listenin yanlarını, sonra alt › üst dener (#1339: GTA 6 duraklatma menüsünde en uzun
        // satır "Photo Studio" sağa sığmayınca bütün liste dağılıyor, satırlar tek tek yerleşiyor, "Photo Studio" örtülüyordu).
        // Listede olmayan tek satır sol › sağ › alt › üst.
        func assign(_ i: Int, _ spot: Spot) {
            result[i].mode = .beside
            result[i].spot = TextBox(left: Double(spot.l) / fw, top: Double(spot.t) / fh, right: Double(spot.r) / fw,
                                     bottom: Double(spot.b) / fh)
            result[i].spotRoom = TextBox(left: Double(spot.roomL) / fw, top: Double(spot.t) / fh,
                                         right: Double(spot.roomR) / fw, bottom: Double(spot.b) / fh)
        }
        // Yerleşen Türkçelerin ve ikiz kutuların yeri (piksel): sonraki yerleşim bunlara binmez.
        var used: [(l: Int, t: Int, r: Int, b: Int)] = twins
        func collides(_ s: Spot) -> Bool { used.contains { overlaps($0, (s.l, s.t, s.r, s.b)) } }
        var placed = Set<Int>()
        var listSides: [Int: [Side]] = [:]
        for list in lists {
            let members = list.0.filter { rooms[$0] != nil && !boxed.contains($0) }
            guard members.count >= 2 else { continue }
            let ms = members.map { rooms[$0]! }
            let aligns = members.map { targets[$0].align }
            let majority: TextLook.Align = [TextLook.Align.left, .right, .center]
                .max { a, b in aligns.filter { $0 == a }.count < aligns.filter { $0 == b }.count } ?? .left
            let sameRow = ms.map(\.t).max()! < ms.map(\.b).min()!
            var sides: [Side]
            if sameRow {
                sides = (majority == .left ? [.right] : majority == .right ? [.left] : []) + [.below, .above]
            } else {
                let tolerance = Int((0.5 * ms.map(\.line).max()!).rounded())
                let rightEdge = ms.map(\.r).max()! - ms.map(\.r).min()! <= tolerance
                let leftEdge = ms.map(\.l).max()! - ms.map(\.l).min()! <= tolerance
                let right = rightEdge && !leftEdge ? true : leftEdge && !rightEdge ? false : majority == .right ? true
                    : majority == .left ? false : nil
                sides = right == false ? [.right, .left] : [.left, .right]
            }
            for m in members { listSides[m] = sides }
            var best: (side: Side, spots: [Spot?])? = nil
            for side in sides {
                var edge: Int? = nil
                switch side {
                case .left: edge = sameRow ? nil : ms.map { $0.l - $0.near }.min()!
                case .right: edge = sameRow ? nil : ms.map { $0.r + $0.near }.max()!
                case .below: edge = ms.map { $0.b + $0.near }.max()!
                case .above: edge = ms.map { $0.t - $0.near }.min()!
                }
                var spots = ms.map { spot($0, side, edge: edge) }
                if side == .below || side == .above, spots.allSatisfy({ $0 != nil }) {
                    // Satırdaki komşular arasında Türkçeler ortadaki çizgiyi geçmez.
                    let order = spots.indices.sorted { spots[$0]!.l < spots[$1]!.l }
                    for (a, b) in zip(order, order.dropFirst()) {
                        let middle = (ms[a].r + ms[b].l) / 2
                        spots[a]!.roomR = max(spots[a]!.r, min(spots[a]!.roomR, middle))
                        spots[b]!.roomL = min(spots[b]!.l, max(spots[b]!.roomL, middle))
                    }
                }
                spots = spots.map { s in s.flatMap { collides($0) ? nil : $0 } }
                let fit = spots.filter { $0 != nil }.count
                if fit > (best.map { b in b.spots.filter { $0 != nil }.count } ?? 0) { best = (side, spots) }
                if fit == spots.count { break }
            }
            guard let best else { continue }
            for (m, s) in zip(members, best.spots) {
                guard let s else { continue }
                assign(m, s)
                used.append((s.l, s.t, s.r, s.b))
                placed.insert(m)
            }
            listSides[members[0]] = [best.side] + sides.filter { $0 != best.side }
            for m in members { listSides[m] = listSides[members[0]] }
        }
        for i in targets.indices where rooms[i] != nil && !boxed.contains(i) && !placed.contains(i) {
            var order = listSides[i] ?? [.left, .right]
            for side in [Side.left, .right, .below, .above] where !order.contains(side) { order.append(side) }
            for side in order {
                if let s = spot(rooms[i]!, side, edge: nil), !collides(s) {
                    assign(i, s)
                    used.append((s.l, s.t, s.r, s.b))
                    break
                }
            }
        }
        // Çakışma: yanına yazılan Türkçenin uzayabileceği alan (spotRoom) başka bir Türkçenin alanına ya da ikiz kutuya
        // binerse alan aradaki çizgide kesilir (Türkçeler birbirine yaslanmaz). Türkçenin kendi yeri binerse (yerleşim
        // çakışmayı önlediği için seyrek) listede olmayan yazı örtmeye döner; menü/liste satırı hiç örtülmez (#1339).
        func overlaps(_ a: TextBox, _ b: TextBox) -> Bool {
            min(a.right, b.right) > max(a.left, b.left) && min(a.bottom, b.bottom) > max(a.top, b.top)
        }
        let eps = 1e-9
        for i in result.indices where result[i].mode == .beside {
            guard var mine = result[i].spotRoom, let spot = result[i].spot else { continue }
            var hit = false
            for j in result.indices where j != i {
                let other: TextBox?
                if result[j].mode == .twin { other = result[j].twin }
                else if result[j].mode == .beside { other = result[j].spot }
                else { other = nil }
                guard let other, overlaps(mine, other) else { continue }
                if overlaps(spot, other) {
                    if result[j].mode == .twin || j < i { hit = true }
                    continue
                }
                // Öbür Türkçe sağdaysa alan onun solunda, soldaysa sağında biter (ikizde kutunun kenarı; yanına yazmada iki
                // Türkçenin ortası).
                if other.left >= spot.right - eps {
                    let end = result[j].mode == .twin ? other.left : (spot.right + other.left) / 2
                    mine.right = max(spot.right, min(mine.right, end))
                } else if other.right <= spot.left + eps {
                    let end = result[j].mode == .twin ? other.right : (other.right + spot.left) / 2
                    mine.left = min(spot.left, max(mine.left, end))
                }
            }
            result[i].spotRoom = mine
            if hit && listOf[i] == nil {
                result[i].mode = .cover
                result[i].spot = nil
                result[i].spotRoom = nil
            }
        }
        // 4) Grup: aynı sütunda (ortak sol ya da sağ kenar, düzenli aralık) ya da aynı satırda duran, BÜYÜK HARF'i ve
        // satır yüksekliği aynı tek satırlık etiketler.
        for (members, id) in lists { for i in members { result[i].group = id } }
        return result
    }

    /// Yanına yazma için bir hedefin çevresindeki boş alan (piksel; döngüde ölçülür, kip kararı döngüden sonra verilir).
    struct Room {
        /// Örtü kutusu ve satır yüksekliği.
        var l: Int, t: Int, r: Int, b: Int
        var line: Double
        /// Türkçenin özgünden uzaklığı (`besideGapLines`), öbür uçta engelden uzaklığı (`ScreenFit.gapLines`) ve en çok
        /// genişliği (`besideMax`).
        var near: Int, far: Int, most: Int
        var iconLeft: Bool, iconRight: Bool
        /// Örtünün solundan/sağından art arda boş sütun sayısı (en çok `cap`; azsa alan bir engelle bitti).
        var left = 0, right = 0, cap = 0
        /// Altından/üstünden art arda boş satır sayısı.
        var down = 0, up = 0
        /// Altındaki/üstündeki yazı şeridinde (yakın boşluktan sonra örtü yüksekliği) solda/sağda art arda boş sütun (en
        /// çok `side` + `far`).
        var downLeft = 0, downRight = 0, upLeft = 0, upRight = 0, side = 0
    }

    enum Side { case left, right, below, above }
    typealias Spot = (l: Int, t: Int, r: Int, b: Int, roomL: Int, roomR: Int)

    /// Boş alan ölçümü. `free(x, y)`: nil başka hedef ya da simge (alan orada biter), true yazı rengine yakın nokta, false
    /// boş zemin. Bir sütun/satır, yazı rengindeki noktaları `besideShare`'den azsa boştur.
    static func measureRoom(l: Int, t: Int, r: Int, b: Int, line: Double, width: Int, height: Int, iconLeft: Bool,
                            iconRight: Bool, free: (Int, Int) -> Bool?) -> Room {
        let w = r - l, h = b - t
        var room = Room(l: l, t: t, r: r, b: b, line: line, near: max(2, Int((besideGapLines * line).rounded())),
                        far: max(1, Int((ScreenFit.gapLines * line).rounded(.up))),
                        most: Int((besideMax * Double(max(0, w)) + line).rounded()), iconLeft: iconLeft, iconRight: iconRight)
        guard w > 0, h > 0, t >= 0, b <= height else { return room }
        func column(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
            guard x >= 0, x < width, y0 >= 0, y1 <= height, y1 > y0 else { return false }
            return roomOpen(from: y0, to: y1) { free(x, $0) }
        }
        func row(_ y: Int, _ x0: Int, _ x1: Int) -> Bool {
            guard y >= 0, y < height, x0 >= 0, x1 <= width, x1 > x0 else { return false }
            return roomOpen(from: x0, to: x1) { free($0, y) }
        }
        func run(from x: Int, step: Int, _ y0: Int, _ y1: Int, cap: Int) -> Int {
            var n = 0
            while n < cap, column(x + step * n, y0, y1) { n += 1 }
            return n
        }
        func rows(from y: Int, step: Int, cap: Int) -> Int {
            var n = 0
            while n < cap, row(y + step * n, l, r) { n += 1 }
            return n
        }
        room.cap = min(width, room.near + room.most + room.far + Int((besideReachLines * line).rounded()))
        room.left = iconLeft ? 0 : run(from: l - 1, step: -1, t, b, cap: room.cap)
        room.right = iconRight ? 0 : run(from: r, step: 1, t, b, cap: room.cap)
        let vertical = room.near + 2 * h
        room.down = rows(from: b + room.near, step: 1, cap: vertical)
        room.up = rows(from: t - room.near - 1, step: -1, cap: vertical)
        room.side = w / 2
        let low = b + room.near, high = t - room.near - h
        if low + h <= height {
            room.downLeft = run(from: l - 1, step: -1, low, low + h, cap: room.side + room.far)
            room.downRight = run(from: r, step: 1, low, low + h, cap: room.side + room.far)
        }
        if high >= 0 {
            room.upLeft = run(from: l - 1, step: -1, high, high + h, cap: room.side + room.far)
            room.upRight = run(from: r, step: 1, high, high + h, cap: room.side + room.far)
        }
        return room
    }

    /// Yanına yazma yeri (Sinan Bey: "SELAMLA  GREET"; beta.100: menülerde de). `edge`: listede ortak kenar (solda
    /// Türkçenin sağ kenarı, sağda sol kenarı, altta üstü, üstte altı); nil: hedefin kendi kenarından yakın boşluk kadar.
    /// Solda/sağda alan en az örtü genişliğinde olmalı (Türkçe `most`'a kadar uzar); altta/üstte örtü yüksekliği kadar satır
    /// boş olmalı (Türkçe iki yana yarım genişliğe kadar uzar). Simgenin olduğu yana yazılmaz.
    static func spot(_ m: Room, _ side: Side, edge: Int?) -> Spot? {
        let w = m.r - m.l, h = m.b - m.t
        guard w > 0, h > 0 else { return nil }
        func usable(_ n: Int, cap: Int) -> Int { n - (n < cap ? m.far : 0) }
        func spread(_ left: Int, _ right: Int) -> (Int, Int) {
            let cap = m.side + m.far
            return (m.l - max(0, min(m.side, usable(left, cap: cap))), m.r + max(0, min(m.side, usable(right, cap: cap))))
        }
        switch side {
        case .left:
            guard !m.iconLeft else { return nil }
            let e = edge ?? (m.l - m.near), gap = m.l - e
            guard gap >= m.near else { return nil }
            let room = min(m.most, usable(m.left, cap: m.cap) - gap)
            guard room >= w else { return nil }
            return (e - w, m.t, e, m.b, e - room, e)
        case .right:
            guard !m.iconRight else { return nil }
            let e = edge ?? (m.r + m.near), gap = e - m.r
            guard gap >= m.near else { return nil }
            let room = min(m.most, usable(m.right, cap: m.cap) - gap)
            guard room >= w else { return nil }
            return (e, m.t, e + w, m.b, e, e + room)
        case .below:
            let top = edge ?? (m.b + m.near)
            guard top - m.b >= m.near, m.down >= top + h - (m.b + m.near) else { return nil }
            let (roomL, roomR) = spread(m.downLeft, m.downRight)
            return (m.l, top, m.r, top + h, roomL, roomR)
        case .above:
            let bottom = edge ?? (m.t - m.near)
            guard m.t - bottom >= m.near, bottom - h >= 0, m.up >= (m.t - m.near) - (bottom - h) else { return nil }
            let (roomL, roomR) = spread(m.upLeft, m.upRight)
            return (m.l, bottom - h, m.r, bottom, roomL, roomR)
        }
    }

    /// Panelin ([l, r) x [t, b)) kenar çizgisi: her yanda panelin hemen dışındaki 1…`edgeMax` piksellik düz renkli şerit
    /// (satır/sütun noktalarının en az %80'i ortalamasına `panelTolerance` kadar yakın, zeminden uzak) ve ötesinde o renk
    /// biter. Çizginin rengi ilk bulunan yanınki; öbür yanlar ancak aynı renkteyse. nil: çizgi yok.
    static func edges(l: Int, t: Int, r: Int, b: Int, width: Int, height: Int, ground: RGB,
                      blocked: (Int, Int) -> Bool, color: (Int, Int) -> RGB) -> (color: RGB, top: Int, right: Int, bottom: Int, left: Int)? {
        /// Yanın k. dış çizgisinin rengi (düzse).
        func strip(_ points: [(Int, Int)]) -> RGB? {
            guard !points.isEmpty, points.allSatisfy({ $0.0 >= 0 && $0.0 < width && $0.1 >= 0 && $0.1 < height }),
                  !points.contains(where: { blocked($0.0, $0.1) }) else { return nil }
            let colors = points.map { color($0.0, $0.1) }
            let average = mean(colors)
            guard Double(colors.filter { distance($0, average) <= panelTolerance }.count) >= 0.8 * Double(colors.count)
            else { return nil }
            return average
        }
        func horizontal(_ y: Int) -> [(Int, Int)] {
            let step = max(1, (r - l) / 32)
            return stride(from: l, to: r, by: step).map { ($0, y) }
        }
        func vertical(_ x: Int) -> [(Int, Int)] {
            let step = max(1, (b - t) / 32)
            return stride(from: t, to: b, by: step).map { (x, $0) }
        }
        var reference: RGB? = nil
        /// Kalınlık: `line(k)` (k = 1, 2, …) aynı renkte sürdükçe; `edgeMax`'a varan ya da karenin kenarına değen şerit çizgi değildir.
        func thickness(_ line: (Int) -> [(Int, Int)]) -> Int {
            guard let first = strip(line(1)), distance(first, ground) > panelTolerance,
                  reference.map({ distance($0, first) <= panelTolerance }) ?? true else { return 0 }
            var k = 1
            while k < edgeMax, let next = strip(line(k + 1)), distance(next, first) <= panelTolerance { k += 1 }
            guard k < edgeMax, line(k + 1).allSatisfy({ $0.0 >= 0 && $0.0 < width && $0.1 >= 0 && $0.1 < height }) else { return 0 }
            if reference == nil { reference = first }
            return k
        }
        let top = thickness { horizontal(t - $0) }
        let bottom = thickness { horizontal(b - 1 + $0) }
        let left = thickness { vertical(l - $0) }
        let right = thickness { vertical(r - 1 + $0) }
        guard let reference, top + bottom + left + right > 0 else { return nil }
        return (reference, top, right, bottom, left)
    }

    /// Kare (CGImage) üzerinden ölçüm.
    public static func paints(_ targets: [Target], frame: CGImage) -> [TextPaint] {
        guard let pixels = GamePhonePixels(frame) else { return [] }
        return paints(targets, pixels: pixels)
    }

    /// Önceden çizilmiş kare üzerinden ölçüm (bütün kare turda bir kez çizilir; `RegionWatcher.ScreenFrame`).
    static func paints(_ targets: [Target], pixels: GamePhonePixels) -> [TextPaint] {
        paints(targets, width: pixels.width, height: pixels.height) { x, y in
            let p = pixels.offset(x, y)
            return (Int(pixels.bytes[p]), Int(pixels.bytes[p + 1]), Int(pixels.bytes[p + 2]))
        }
    }

    /// Satır aralığı: çok satırlı yazıda kutudan ((satır sayısı - 1) aralık + bir satır yüksekliği), tek satırda satır yüksekliği.
    static func pitch(_ target: Target) -> Double {
        let height = target.box.bottom - target.box.top
        guard target.rows > 1, target.lineHeight > 0 else { return target.lineHeight > 0 ? target.lineHeight : height }
        return max(target.lineHeight, (height - target.lineHeight) / Double(target.rows - 1))
    }

    /// Grup üyeleri ve numarası (grubun en küçük sıra numarası); tek üyeli grup yok.
    static func groups(_ targets: [Target]) -> [([Int], Int)] {
        let labels = targets.indices.filter { targets[$0].rows <= 1 }
        var parent = Dictionary(uniqueKeysWithValues: labels.map { ($0, $0) })
        func root(_ i: Int) -> Int { var i = i; while parent[i]! != i { i = parent[i]! }; return i }
        func overlap(_ a: TextBox, _ b: TextBox) -> Double {
            max(0, min(a.bottom, b.bottom) - max(a.top, b.top)) / max(1e-9, min(a.bottom - a.top, b.bottom - b.top))
        }
        for a in labels {
            for b in labels where b > a {
                let x = targets[a], y = targets[b]
                let line = max(x.lineHeight, y.lineHeight)
                guard x.upper == y.upper, abs(x.lineHeight - y.lineHeight) <= sameLine * line else { continue }
                // Satır yüksekliği kareye oranla; yatay pay aynı piksele denk gelsin diye en-boy oranı bilinmez, yarım satır
                // yüksekliğinin yarısı kadar (16:9'da ~0,28 satır) alınır.
                let tolerance = 0.5 * line * 9 / 16
                let sameRow = overlap(x.box, y.box) >= 0.5
                let column = (abs(x.box.left - y.box.left) <= tolerance || abs(x.box.right - y.box.right) <= tolerance)
                    && overlap(x.box, y.box) == 0 && abs(x.box.top - y.box.top) <= 3 * line
                if sameRow || column { parent[root(a)] = root(b) }
            }
        }
        return Dictionary(grouping: labels, by: root).values.filter { $0.count >= 2 }.map { ($0.sorted(), $0.min()!) }
            .sorted { $0.1 < $1.1 }
    }

    static func rgb(_ hex: String) -> RGB {
        guard let (r, g, b) = SpeakerColors.rgb(hex) else { return (0, 0, 0) }
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    static func hex(_ c: RGB) -> String {
        String(format: "#%02X%02X%02X", max(0, min(255, c.r)), max(0, min(255, c.g)), max(0, min(255, c.b)))
    }

    static func distance(_ a: RGB, _ b: RGB) -> Int { max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) }

    static func mean(_ list: [RGB]) -> RGB {
        let n = max(1, list.count)
        return (list.map(\.r).reduce(0, +) / n, list.map(\.g).reduce(0, +) / n, list.map(\.b).reduce(0, +) / n)
    }

    /// `a`'dan `b`'nin tersine `share` kadar (eksiyse `b`'ye doğru) uzatılmış renk.
    static func extend(_ a: RGB, _ b: RGB, _ share: Double) -> RGB {
        func one(_ x: Int, _ y: Int) -> Int { Int((Double(x) + Double(x - y) * share).rounded()) }
        return (one(a.r, b.r), one(a.g, b.g), one(a.b, b.b))
    }

    static func deviation(_ list: [RGB]) -> Double {
        guard !list.isEmpty else { return 0 }
        func spread(_ values: [Int]) -> Double {
            let average = Double(values.reduce(0, +)) / Double(values.count)
            return (values.map { (Double($0) - average) * (Double($0) - average) }.reduce(0, +) / Double(values.count)).squareRoot()
        }
        return (spread(list.map(\.r)) + spread(list.map(\.g)) + spread(list.map(\.b))) / 3
    }
}
