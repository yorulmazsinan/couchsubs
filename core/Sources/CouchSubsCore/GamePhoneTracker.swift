// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics

/// GTA 6'da elde açık telefon. Uyumlu gözlemlerle açılır (`openPoints`): iki sıkı gözlem, ya da bir sıkı gözlem ve onun
/// yerinde gevşek doğrulama / yanları zayıf aday, ya da üç zayıf gözlem. Tek menü ya da altyazı karesi telefon açmaz.
public final class GamePhoneTracker {
    public static let intervalMs = 330
    /// Gözlem: bulunan yer, sıkı aramayla mı bulundu ve sıkı aramanın sonucu (gerçek aramada; denemelerde nil).
    typealias Sighting = (pose: GamePhoneGeometry.Pose?, strict: Bool, probe: GamePhoneGeometry.Probe?)
    private let sight: (CGImage, GamePhoneGeometry.Pose?) -> Sighting
    private var lastTime: Int?
    private var shown: GamePhoneGeometry.Pose?

    private var clock = 0
    private lazy var trace = DropLog(clock: { [unowned self] in self.clock })
    /// Telefonun açılması, kapanması ve oynadığı için açılmaması altyazı günlüğüne (`PhoneTrace`; sınırlı). nil: altyazı
    /// günlüğü (Windows ve Android ile aynı satırlar).
    public var onLog: ((String) -> Void)?

    public init() {
        sight = { image, near in
            let (pose, probe) = GamePhoneGeometry.search(image, near: near)
            return (pose, pose != nil && probe.step == .found, probe)
        }
    }
    init(locate: @escaping (CGImage) -> GamePhoneGeometry.Pose?) { sight = { image, _ in (locate(image), true, nil) } }
    init(locate: @escaping (CGImage, GamePhoneGeometry.Pose?) -> GamePhoneGeometry.Pose?) {
        sight = { image, near in (locate(image, near), true, nil) }
    }
    /// Denemeler: gözlem ve gücü (strict: sıkı arama; değilse gevşek doğrulama ya da yanları zayıf aday).
    init(sight: @escaping (CGImage) -> (pose: GamePhoneGeometry.Pose, strict: Bool)?) {
        self.sight = { image, _ in
            guard let seen = sight(image) else { return (nil, false, nil) }
            return (seen.pose, seen.strict, nil)
        }
    }

    private func note(_ reason: String) { trace.note(PhoneTrace.component, reason, "", log: onLog) }

    /// Sıkı aramayla bulunan telefonun gözlem puanı.
    static let strongPoints = 2
    /// Gevşek doğrulamanın (doğrulanmayı bekleyen gözlemin yerinde hoparlör, kamera ve alt çentik) ya da yanları zayıf
    /// adayın (`GamePhoneGeometry.weakSide`) gözlem puanı.
    static let weakPoints = 1
    /// Yeni telefon, art arda uyumlu gözlemlerin puanı buna varınca açılır: iki sıkı gözlem (önceki kural), sıkı gözlem ve
    /// gevşek doğrulama, ya da üç zayıf gözlem. Önceden yalnız art arda iki sıkı gözlem açıyordu: sıkı arama telefonu ara
    /// sıra bulunca (açık kasa açık zeminde, el örtüyor, karanlık) telefon hiç açılmıyor, mesajları altyazı gibi okunuyordu
    /// (#1251, beta-102: altyazı süzgeci telefonu tek sıkı gözlem ve gevşek doğrulamayla 3 sn tuttu, izleyici hiç açmadı;
    /// Windows ve Android ile aynı).
    static let openPoints = 3
    /// Doğrulanmayı bekleyen gözlem, arada ıskalı örnek olsa da bu kadar süre (ms) geçerli kalır; ıskasız art arda örnekler
    /// süreye bakılmadan birleşir (seyrek örneklemede de telefon açılır).
    static let pendingMs = 1000
    private var pending: GamePhoneGeometry.Pose?
    private var pendingAt = 0
    private var pendingPoints = 0
    private var pendingMisses = 0
    private var pendingStrict = false
    private let missLog = PhoneMissLog()
    private let status = PhoneSearchStatus()

    public func sample(_ image: CGImage, now: Int) -> (sampled: Bool, pose: GamePhoneGeometry.Pose?) {
        if let lastTime, now >= lastTime, now - lastTime < Self.intervalMs { return (false, shown) }
        lastTime = now
        clock = now
        let wasShown = shown != nil
        // Açık telefonun ya da doğrulanmayı bekleyen gözlemin yerinde gevşek doğrulama da denenir
        // (`GamePhoneGeometry.locate(near:)`): beyaz ya da mavi ekranlı uygulamada (haber, ayarlar, hava) telefonun yanları
        // zemine karışıyor, sıkı arama ıskalıyordu. Yeni telefonda sıkı arama ıskalarsa yanları zayıf aday (`Probe.weak`)
        // zayıf gözlem sayılır.
        let seen = sight(image, shown ?? (pendingFresh(now) ? pending : nil))
        var found = seen.pose
        var strict = seen.strict
        var probe = seen.probe
        if found == nil, shown == nil, let weak = probe?.weak {
            found = weak
            strict = false
        }
        // Akıl sınırı: telefon ekranın küçük, dikey bir parçasıdır. Dışındaki bir aday (menüde ya da koyu ekranda yanlış
        // eşleşme) kabul edilmez; TV'de büyük opak telefon kutusu oyun görüntüsünü kapatırdı (Windows ile aynı).
        if let pose = found, !Self.plausible(pose.bounds, width: image.width, height: image.height) {
            if strict { probe?.step = .implausible }
            found = nil
            strict = false
        }
        let points = found == nil ? 0 : strict ? Self.strongPoints : Self.weakPoints
        var unseen = (ms: 0, misses: 0)
        var movedFrom: GamePhoneGeometry.Pose?
        if let current = shown, let found,
           found.bounds.isClose(to: current.bounds, tolerance: strict ? Self.strictMoveTolerance : Self.sameTolerance) {
            // Açık telefonun yakınında tek bir gözlem: aynı telefon, yeri güncellenir. Sıkı aramanın bulduğu telefon daha çok
            // oynamış da olabilir (el hızlı oynadı): yine aynı telefon sayılır, önceden ıska sayılıp telefonu kapatıyordu.
            shown = found
            misses = 0
            lastSeen = now
        } else if shown != nil, !Self.closes(misses: misses + 1, unseenMs: Self.elapsed(since: lastSeen, now)) {
            // Açık telefon tek bir karede bulunamadı ya da el titredi: hemen kapanmaz. Önceden tek ıska paneli kapatıyor,
            // yeniden açılış iki gözlem bekleyip bütün sayfayı yeniden çeviriyordu; çeviriler gidip geliyordu (X'teki
            // bildirim). Telefon gerçekten indirilince `missGraceMs` sonra kapanır (`closes`).
            misses += 1
        } else if shown != nil {
            unseen = (Self.elapsed(since: lastSeen, now), misses + 1)
            shown = nil
            misses = 0
            clearPending()
        } else if let found {
            // Yeni telefon: doğrulanmayı bekleyen gözlemin yakınındaysa puanı eklenir, değilse yeni bekleyen gözlem olur.
            if let pending, found.bounds.isClose(to: pending.bounds, tolerance: Self.sameTolerance), pendingMisses == 0 || pendingFresh(now) {
                pendingPoints += points
            } else {
                if let pending, pendingMisses == 0 { movedFrom = pending }
                if pending != nil { missLog.unconfirmed(strict: pendingStrict) }
                pendingPoints = points
                pendingStrict = false
            }
            pending = found
            pendingAt = now
            pendingMisses = 0
            pendingStrict = pendingStrict || strict
            if pendingPoints >= Self.openPoints {
                shown = found
                misses = 0
                lastSeen = now
                clearPending()
            }
        } else if pending != nil {
            pendingMisses += 1
            if !pendingFresh(now) {
                missLog.unconfirmed(strict: pendingStrict)
                clearPending()
            }
        }
        if !wasShown, shown != nil {
            note(PhoneTrace.opened)
        } else if wasShown, shown == nil {
            note(PhoneTrace.closed(afterMs: unseen.ms, misses: unseen.misses))
        }
        // Telefon art arda iki örnekte bulundu ama yeri çok oynadı: hiç açılmıyor, okuma da başlamıyor (önceden sessizdi).
        if shown == nil, let found, let movedFrom {
            note(PhoneTrace.moving(PhoneTrace.shift(found.bounds, movedFrom.bounds)))
        }
        // İlk açılış ıskalanınca nedeni (en ileri geçilen ölçüt, en iyi aday) sınırlı aralıkla günlüğe (#1251).
        if shown != nil {
            missLog.reset()
        } else if let probe {
            missLog.note(probe, now: now) { [weak self] line in self?.note(line) }
        }
        // Arama durumu 30 sn'de bir (telefon hiç bulunamasa da): ıska ölçütü, parlaklık, kare biçimi (Android ve Windows aynı).
        if status.note(probe, seen: found != nil, now: now) {
            note(status.line(open: shown != nil, width: image.width, height: image.height,
                             median: PhoneSearchStatus.median(image), frame: PhoneSearchStatus.frame(image)))
        }
        return (true, shown)
    }

    private func pendingFresh(_ now: Int) -> Bool { pending != nil && now >= pendingAt && now - pendingAt <= Self.pendingMs }

    private func clearPending() {
        pending = nil
        pendingPoints = 0
        pendingMisses = 0
        pendingStrict = false
    }

    /// Açık telefon bu kadar süre (ms) görülmezse kapanır; çevirisi hemen kalkar (izleyici `closePhone`). Önceden süre
    /// değil örnek sayılıyordu (art arda 4 ıska): örnekler seyrek geldiğinde (Android'de ağır kare, takılan akış) telefon
    /// indirildikten 3–4 sn sonra kalkıyordu (#1334). Tek karelik ıska yine kapatmaz: en az `minimumMisses` ıska gerekir;
    /// yalnız telefon `2 × missGraceMs` boyunca hiç görülmediyse tek ıska yeter. 330 ms aralıkla ~1 sn (Windows ve Android
    /// ile aynı).
    static let missGraceMs = 900
    /// Altyazı süzgecinin açık telefonu bulunamadığı aramalarda tuttuğu arama sayısı (`SubtitlePipeline.heldPhone`); telefon
    /// oturumunun kapanması süreyle ölçülür (`missGraceMs`).
    static let missGrace = 3
    static let minimumMisses = 2
    /// Saat geri giderse süre ölçülemez: art arda bu kadar ıskada her durumda kapanır (eski kural).
    static let maximumMisses = 4
    private var misses = 0
    /// Telefonun en son görüldüğü an (ms).
    private var lastSeen = 0

    /// Açık telefon `misses` ıskadan, `unseenMs` görülmeden sonra kapansın mı.
    static func closes(misses: Int, unseenMs: Int) -> Bool {
        misses >= maximumMisses || (misses >= minimumMisses && unseenMs >= missGraceMs) || unseenMs >= 2 * missGraceMs
    }

    private static func elapsed(since time: Int, _ now: Int) -> Int { now >= time ? now - time : 0 }

    /// Açık telefonun yeni gözlemi en çok bu kadar oynadıysa (kutunun her kenarı, kareye oranla) aynı telefondur; sıkı
    /// aramanın gözleminde `strictMoveTolerance` (Windows ve Android ile aynı).
    static let sameTolerance = 0.035, strictMoveTolerance = 0.1

    /// Telefon kutusunun alanı (kareye oranla) bu aralıkta olmalı.
    static let minArea = 0.04, maxArea = 0.35

    /// Telefon kutusu akla yatkın mı: alanı karenin %4–%35'i, piksel olarak dikey (yükseklik/genişlik 0,9–2,6; eğik
    /// telefonun sınır kutusu dikey telefondan geniştir), yüksekliği karenin en çok %85'i, genişliği en çok yarısı, merkezi karenin sol kenarında ya da üst üçte birinde değil.
    static func plausible(_ region: CropRegion, width: Int, height: Int) -> Bool {
        let w = region.right - region.left, h = region.bottom - region.top
        guard w > 0, h > 0, h <= 0.85, w <= 0.5 else { return false }
        let area = w * h
        guard area >= minArea, area <= maxArea else { return false }
        if width >= 64 {
            let aspect = h * Double(max(1, height)) / (w * Double(max(1, width)))
            guard aspect >= 0.9, aspect <= 2.6 else { return false }
        }
        return (region.left + region.right) / 2 >= GamePhoneGeometry.minCenterX && (region.top + region.bottom) / 2 >= 1.0 / 3
    }

    public func reset() {
        lastTime = nil
        shown = nil
        misses = 0
        lastSeen = 0
        clearPending()
        missLog.reset()
        status.reset()
    }
}

public enum GamePhoneGeometry {
    public struct Pose: Equatable, Sendable {
        public let topX: Double, topY: Double, bottomX: Double, bottomY: Double
        public init(topX: Double, topY: Double, bottomX: Double, bottomY: Double) {
            self.topX = topX
            self.topY = topY
            self.bottomX = bottomX
            self.bottomY = bottomY
        }
        public var bounds: CropRegion {
            let h = bottomY - topY, w = h * 225 / 400 * 0.25
            return CropRegion(top: topY + h * 0.012, bottom: bottomY - h * 0.015,
                              left: min(topX, bottomX) - w, right: max(topX, bottomX) + w)
        }
    }

    private struct Slot {
        let x: Double, y: Int, length: Int, contrast: Int
    }

    // Two samples per axis, one 400×225 detection grid irrespective of stream resolution.
    private struct Grid {
        let pixels: GamePhonePixels
        let left: Int
        /// Parlaklık kazancı (256 = 1×; `darkGain`). Karanlık sahnede telefonun kasası ve yarıkları aynı oranda koyulaşır,
        /// eşikler mutlak tonda kalıyordu; kazanç ızgarayı aydınlık sahnenin tonlarına taşır.
        var gain = 256

        init?(_ image: CGImage, columns: Range<Int>, height: Int) {
            let xScale = Double(image.width) / 400, yScale = Double(image.height) / 225
            let crop = CGRect(x: Double(columns.lowerBound) * xScale, y: 0,
                              width: Double(columns.count) * xScale, height: Double(height) * yScale)
            // Use the whole grid for unusual stream dimensions where rounding the crop would shift a sample.
            if crop == crop.integral {
                guard let part = GamePhonePixels(image, in: crop, width: 2 * columns.count, height: 2 * height) else { return nil }
                left = columns.lowerBound
                pixels = part
            } else {
                guard let whole = GamePhonePixels(image, width: 800, height: 450) else { return nil }
                left = 0
                pixels = whole
            }
        }

        func at(_ x: Int, _ y: Int) -> Int {
            // Izgaranın dışındaki örnek kenardan okunur: dizinin dışına okumak çöker (#1369).
            let column = min(max(0, x - left), max(0, pixels.width / 2 - 1)), row = min(max(0, y), max(0, pixels.height / 2 - 1))
            let p = (row * 2 * pixels.width + 2 * column) * 4
            let stride = pixels.width * 4
            func tone(_ i: Int) -> Int {
                77 * Int(pixels.bytes[i]) + 150 * Int(pixels.bytes[i+1]) + 29 * Int(pixels.bytes[i+2])
            }
            let sum = tone(p) + tone(p + 4) + tone(p + stride) + tone(p + stride + 4)
            return gain == 256 ? sum >> 10 : min(255, (sum * gain) >> 18)
        }

        func with(gain: Int) -> Grid {
            var copy = self
            copy.gain = gain
            return copy
        }

        /// Şeritteki ortanca ton (kazançsız; her üç noktada bir örnek).
        func level(rows: Range<Int>, columns: ClosedRange<Int>) -> Int {
            var counts = [Int](repeating: 0, count: 256), total = 0
            for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 3) {
                for x in stride(from: columns.lowerBound, through: columns.upperBound, by: 3) {
                    counts[with(gain: 256).at(x, y)] += 1
                    total += 1
                }
            }
            var sum = 0
            for (tone, count) in counts.enumerated() {
                sum += count
                if 2 * sum >= total { return tone }
            }
            return 255
        }
    }

    private static func rounded(_ value: Double) -> Int { Int(value.rounded(.toNearestOrEven)) }
    private static func limit(_ n: Int, _ low: Int, _ high: Int) -> Int { min(high, max(low, n)) }

    /// Karedeki 16:9 oyun görüntüsü (piksel). Pencereden okunan kare (PS Remote Play, chiaki-ng, OBS penceresi) başlık
    /// çubuğunu ve pencere görüntüden farklı oransa siyah şeritleri de taşır; önceden telefon yalnız tam 16:9 karede
    /// aranıyordu, pencerede hiç bulunmuyordu (ne otomatik telefon okuması ne "Ekranı çevir"in telefon kartı). Alttaki ve
    /// yanlardaki simsiyah şeritler atılır, görüntü kalan genişliğin 16:9'u kadar yüksekliktedir ve alta yaslıdır (başlık
    /// çubuğu üstte). Kare zaten 16:9 ise tamamı; görüntü bulunamazsa nil (Windows ve Android ile aynı kural).
    static func picture(width: Int, height: Int, tone: (Int, Int) -> Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard width >= 400, height >= 225 else { return nil }
        if abs(Double(width) / Double(height) - 400.0 / 225) <= 0.04 { return (0, 0, width, height) }
        let columns = (0..<64).map { min(width - 1, Int((Double($0) + 0.5) * Double(width) / 64)) }
        func darkRow(_ y: Int) -> Bool { columns.allSatisfy { tone($0, y) < darkTone } }
        var bottom = height
        while bottom > height / 2, darkRow(bottom - 1) { bottom -= 1 }
        // Yan şeritlere başlık çubuğunun altından bakılır (başlık çubuğu bütün genişlikte uzanır).
        let from = height * 2 / 5
        let rows = (0..<48).map { from + Int((Double($0) + 0.5) * Double(bottom - from) / 48) }
        func darkColumn(_ x: Int) -> Bool { rows.allSatisfy { tone(x, $0) < darkTone } }
        var left = 0, right = width
        while left < width / 4, darkColumn(left) { left += 1 }
        while right > width * 3 / 4, darkColumn(right - 1) { right -= 1 }
        var w = right - left, h = Int((Double(w) * 9 / 16).rounded())
        if h > bottom {
            h = bottom
            w = Int((Double(h) * 16 / 9).rounded())
            left = (left + right - w) / 2
        }
        guard w >= 400, h >= 225, left >= 0, left + w <= width else { return nil }
        return (left, bottom - h, w, h)
    }

    /// Simsiyah şerit: örneklerin hepsi bu tondan koyu (0–255). Önceden 24'tü: karanlık sahnede (gece, karartılmış oyun) görüntünün kenar sütunları ve alt satırları da şerit sayılıp kırpılıyor, 16:9 olmayan pencerede (Remote Play, şeritli ya da başlık çubuklu) oyun görüntüsü küçük ve kaymış bulunuyor, telefon aranamıyordu. Oyun penceresinin şeritleri simsiyahtır (0–3).
    static let darkTone = 8

    /// Karedeki telefon. `near`: açık telefonun son yeri; sıkı arama ıskalarsa o yerin hemen çevresinde gevşek doğrulama
    /// yapılır (`confirmPicture`): hoparlör yarığı ve kamera üstte, alt çentik altta aynı yerde duruyorsa telefon
    /// yerindedir. Sinan Bey (beta.100, 3418–3425): beyaz/mavi ekranlı uygulamalarda (haber, makale, hava, ayarlar,
    /// eklenti) telefonun yan kenarları elin ve gövdenin rengine karışıyor, sıkı arama telefonu kaybediyordu; telefon
    /// kaybolunca balonlar kalkıyor ("arada kaçıyor", 3417), telefonun yazıları altyazıya (3418, 3420, 3421) ve ekran
    /// yazısı kutularına (3420–3425) gidiyordu. Gevşek doğrulama yalnız açık telefonun yerinde yapılır: yeni telefon yine
    /// sıkı aramayla ve iki gözlemle açılır (Windows ve Android ile aynı).
    public static func locate(_ image: CGImage, near: Pose? = nil) -> Pose? { search(image, near: near).pose }

    /// Sıkı aramanın ıska nedeni: aramanın geçemediği ilk ölçüt (sırayla). Telefon ekrandayken ilk açılış ıskalanınca hangi
    /// ölçütün tuttuğu günlükte görünsün diye (#1251; Windows ve Android ile aynı adlar ve sıra).
    enum Step: Int, Comparable {
        /// Karede 16:9 oyun görüntüsü yok.
        case noPicture
        /// Üst şeritte hoparlör yarığına benzer koyu çizgi yok.
        case noTopSlot
        /// Üst şeritte çok aday (menü, yazı satırları): arama bırakıldı.
        case topCrowded
        /// Hoparlör yarığının yanında ön kamera yok.
        case noCamera
        /// Alt şeritte alt çentiğe benzer koyu çizgi yok.
        case noBottomSlot
        /// Alt şeritte çok aday: arama bırakıldı.
        case bottomCrowded
        /// Yarık ile çentik telefon boyunda ve oranında değil.
        case shape
        /// Yarığın ya da çentiğin çevresi düz kasa değil.
        case rim
        /// Telefonun yan kenarları zayıf (açık kasa açık zeminde, el örtüyor).
        case sides
        /// Sıkı arama buldu ama kutu akla yatkın değil (`GamePhoneTracker.plausible`; izleyici koyar).
        case implausible
        /// Bulundu.
        case found

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    /// Yan kenarların sıkı aramadaki eşiği (ikisi de en az bu kadar güçlü olmalı).
    static let sideThreshold = 12

    /// Yanları zayıf adayın zayıf gözlem sayılması için zayıf yanının en az gücü. Gerçek telefonsuz karelerin
    /// (testdata/frames; karartılmış, açılmış, düşük karşıtlıklı hâlleriyle) hiçbiri yan ölçütüne gelmiyor; gerçek telefon
    /// (480p akış, yukarıda tutulan) 10–11'de kalıp bulunmuyordu (Windows ve Android ile aynı).
    static let weakSide = 8

    /// Sıkı aramanın sonucu: `step` ıskanın nedeni; `side` yan ölçütüne gelen adaylardan zayıf yanı en güçlü olanın zayıf
    /// yanı (yoksa -1); `candidate` o aday (yarık, kamera, çentik, oran ve kasa tutuyor, yanları zayıf). Aday tek başına
    /// telefon açmaz.
    struct Probe: Equatable {
        var step: Step
        var side = -1
        var candidate: Pose?
        /// Üst şeridin ortanca tonu (0–255; -1: ölçülmedi) ve sonucu veren aramanın kazancı (256 = 1×; `darkGain`).
        var level = -1
        var gain = 256

        static func missed(_ step: Step) -> Probe { Probe(step: step) }

        /// Zayıf gözlem sayılan aday (`weakSide`).
        var weak: Pose? { side >= GamePhoneGeometry.weakSide ? candidate : nil }
    }

    /// `locate`; `probe`: sıkı aramanın ıska nedeni ve en iyi adayı (karenin tamamına göre).
    static func search(_ image: CGImage, near: Pose? = nil) -> (pose: Pose?, probe: Probe) {
        guard image.width >= 400, image.height >= 225 else { return (nil, .missed(.noPicture)) }
        if abs(Double(image.width) / Double(image.height) - 400.0 / 225) <= 0.04 { return locatePicture(image, near: near) }
        // Kare küçültülerek okunur (en çok 960 piksel genişlik); şeritlerin yeri piksel piksel gerekmez.
        let scale = min(1, 960 / Double(image.width))
        let sw = max(1, Int((Double(image.width) * scale).rounded())), sh = max(1, Int((Double(image.height) * scale).rounded()))
        guard let small = GamePhonePixels(image, width: sw, height: sh),
              let area = picture(width: image.width, height: image.height, tone: { x, y in
                  let p = (min(sh - 1, Int(Double(y) * scale)) * sw + min(sw - 1, Int(Double(x) * scale))) * 4
                  return (77 * Int(small.bytes[p]) + 150 * Int(small.bytes[p + 1]) + 29 * Int(small.bytes[p + 2])) >> 8
              }),
              let cropped = image.cropping(to: CGRect(x: area.x, y: area.y, width: area.width, height: area.height)) else {
            return (nil, .missed(.noPicture))
        }
        let w = Double(image.width), h = Double(image.height)
        // Açık telefonun yeri görüntünün içine taşınır.
        let local = near.map { pose in
            Pose(topX: (pose.topX * w - Double(area.x)) / Double(area.width), topY: (pose.topY * h - Double(area.y)) / Double(area.height),
                 bottomX: (pose.bottomX * w - Double(area.x)) / Double(area.width),
                 bottomY: (pose.bottomY * h - Double(area.y)) / Double(area.height))
        }
        func x(_ value: Double) -> Double { (Double(area.x) + value * Double(area.width)) / w }
        func y(_ value: Double) -> Double { (Double(area.y) + value * Double(area.height)) / h }
        func outside(_ pose: Pose) -> Pose {
            Pose(topX: x(pose.topX), topY: y(pose.topY), bottomX: x(pose.bottomX), bottomY: y(pose.bottomY))
        }
        var (pose, probe) = locatePicture(cropped, near: local)
        probe.candidate = probe.candidate.map(outside)
        return (pose.map(outside), probe)
    }

    private static func locatePicture(_ image: CGImage, near: Pose? = nil) -> (pose: Pose?, probe: Probe) {
        guard image.width >= 400, image.height >= 225,
              abs(Double(image.width) / Double(image.height) - 400.0 / 225) <= 0.04 else { return (nil, .missed(.noPicture)) }
        let (strict, probe) = strictPicture(image)
        if let strict { return (strict, probe) }
        guard let near else { return (nil, probe) }
        return (confirmPicture(image, near: near), probe)
    }

    /// Gevşek doğrulamada yarıklar açık telefonun son yerinden yatayda ve dikeyde en çok bu kadar (400×225 ızgarada) uzak
    /// olabilir: izleyicinin aynı telefon saydığı oynama kadar (`GamePhoneTracker.sameTolerance`, karenin %3,5'i). Önceden
    /// her yönde 4'tü (yatayda %1, dikeyde %1,8): el titreyince ya da telefon kaldırılınca 330 ms'de %2 oynayan telefon,
    /// sıkı arama da ıskalarsa ~1,1 sn sonra kapanıyordu (#1251, beta-104 Windows günlüğü: "telefon kapandı (1141 ms
    /// görülmedi, 3 ıska)", telefon ekranda; Windows ve Android ile aynı).
    static let confirmReachX = 14.0, confirmReachY = 8.0

    /// Açık telefonun son yerinde gevşek doğrulama: üstte kameralı hoparlör yarığı ve altta alt çentik, son yerin
    /// `confirmReachX`/`confirmReachY` kadar çevresinde, sıkı aramayla aynı boy ve oran kurallarıyla; yan kenarların ve çerçevenin
    /// gücüne bakılmaz (beyaz ekranda yanlar zemine karışır). Bulunmazsa nil.
    static func confirmPicture(_ image: CGImage, near: Pose) -> Pose? {
        guard let whole = Grid(image, columns: 0..<400, height: 225) else { return nil }
        if let pose = confirmPass(whole, near: near) { return pose }
        for gain in darkGains(level: whole.level(rows: 0..<90, columns: 95...305)) {
            if let pose = confirmPass(whole.with(gain: gain), near: near) { return pose }
        }
        return nil
    }

    private static func confirmPass(_ grid: Grid, near: Pose) -> Pose? {
        let topX = near.topX * 400, topY = near.topY * 225, bottomX = near.bottomX * 400, bottomY = near.bottomY * 225
        guard topX.isFinite, bottomX.isFinite,
              let upperRows = confirmRows(topY, within: 17, 75),
              let lowerRows = confirmRows(bottomY, within: 145, 217) else { return nil }
        let upper = slots(grid, rows: upperRows, lengths: 8...19, maximum: 12)
            .filter { abs($0.x - topX) <= confirmReachX && hasCamera(grid, $0) }
        let lower = slots(grid, rows: lowerRows, lengths: 5...14, maximum: 16).filter { abs($0.x - bottomX) <= confirmReachX }
        var best = Double.infinity, pose: Pose?
        for top in upper {
            for bottom in lower {
                let h = Double(bottom.y - top.y), dx = bottom.x - top.x
                guard (115...179).contains(h), abs(dx) <= h * 0.24,
                      Double(bottom.length) >= Double(top.length) * 0.46, bottom.length <= top.length,
                      h >= 7.9 * Double(top.length), h <= 16.5 * Double(top.length),
                      h >= 12 * Double(bottom.length), h <= 30 * Double(bottom.length) else { continue }
                let distance = abs(top.x - topX) + abs(Double(top.y) - topY) + abs(bottom.x - bottomX) + abs(Double(bottom.y) - bottomY)
                if distance < best {
                    best = distance
                    pose = Pose(topX: top.x / 400, topY: Double(top.y) / 225, bottomX: bottom.x / 400, bottomY: Double(bottom.y) / 225)
                }
            }
        }
        return pose
    }

    /// Gevşek doğrulamanın tarandığı satırlar: `center ± confirmReachY`, `low..<high` şeridinin içinde; şeritle kesişmiyorsa
    /// ya da yer sayı değilse nil. #1369 (beta-104, Mac): aralık sınırlar sıralanmadan kuruluyordu; son yer şeridin dışında
    /// kalınca (telefon şeridin üstünde/altında, eksi ya da karenin altını aşan yer) alt sınır üst sınırı geçiyor, Swift
    /// aralığı kurulurken uygulama çöküyordu. Önce kırpılır, boşsa atlanır (Windows ve Android ile aynı).
    static func confirmRows(_ center: Double, within low: Int, _ high: Int) -> Range<Int>? {
        guard center.isFinite, low < high else { return nil }
        let reach = Int(confirmReachY)
        let c = Int(min(Double(high + reach + 1), max(Double(low - reach - 1), center)).rounded())
        let from = max(low, c - reach), to = min(high, c + reach + 1)
        return from < to ? from..<to : nil
    }

    /// Karanlık sahne: üst şeridin ortanca tonu bundan azsa (0–255) sıkı arama kazançla da yapılır (`darkGains`).
    static let darkLevel = 56
    /// Kazançlı aramada üst şeridin ortanca tonunun en çok taşındığı ton; denenen kazançlar (256 = 1×).
    static let darkTarget = 96
    static let gainSteps = [384, 640, 1024]

    /// Karanlık sahnede denenen kazançlar (256 = 1×; küçükten büyüğe); sahne karanlık değilse boş. Kullanıcı bildirimi
    /// (X, beta.104): "telefonda parlaklık varsa çeviri oluyor karanlıksa olmuyor". Gece ya da karanlık odada telefonun
    /// kasası koyu, hoparlör yarığıyla kasa arasındaki fark mutlak eşiğin (14–20 ton) altında kalıyordu; sıkı arama hoparlör
    /// yarığında kalıyor, telefon hiç açılmıyordu. Ölçütler aynı, yalnız ızgara aydınlatılır. Sahne karanlık ama telefon
    /// aydınlıksa büyük kazanç kasayı doyurur: kazançlar küçükten denenir, üst şeridi `darkTarget`'tan çok aydınlatan
    /// kazanç denenmez (Windows ve Android ile aynı).
    static func darkGains(level: Int) -> [Int] {
        guard level < darkLevel else { return [] }
        let most = 256 * darkTarget / max(8, level)
        let steps = gainSteps.filter { $0 <= most }
        return steps.isEmpty ? [gainSteps[0]] : steps
    }

    private static func strictPicture(_ image: CGImage) -> (pose: Pose?, probe: Probe) {
        guard let topBand = Grid(image, columns: 80..<350, height: 90) else { return (nil, .missed(.noPicture)) }
        let level = topBand.level(rows: 0..<90, columns: 95...305)
        var (pose, probe) = strictPass(image, topBand: topBand, gain: 256)
        probe.level = level
        guard pose == nil else { return (pose, probe) }
        for gain in darkGains(level: level) {
            var (dark, darkProbe) = strictPass(image, topBand: topBand, gain: gain)
            darkProbe.level = level
            darkProbe.gain = gain
            if dark != nil { return (dark, darkProbe) }
            // Iskada en ileri geçilen ölçüt ve en iyi aday bütün aramalardan.
            if darkProbe.step > probe.step { (probe.step, probe.gain) = (darkProbe.step, gain) }
            if darkProbe.side > probe.side { (probe.side, probe.candidate) = (darkProbe.side, darkProbe.candidate) }
        }
        return (nil, probe)
    }

    private static func strictPass(_ image: CGImage, topBand whole: Grid, gain: Int) -> (pose: Pose?, probe: Probe) {
        let topBand = whole.with(gain: gain)
        // Normal gameplay ends here. Only sample the body after seeing both a speaker and a camera in the upper band.
        let speakers = scan(topBand, rows: 17..<75, lengths: 8...19, maximum: 12)
        guard !speakers.slots.isEmpty else { return (nil, .missed(speakers.crowded ? .topCrowded : .noTopSlot)) }
        let upper = speakers.slots.filter { hasCamera(topBand, $0) }
        guard !upper.isEmpty else { return (nil, .missed(.noCamera)) }
        guard let grid = Grid(image, columns: 0..<400, height: 225)?.with(gain: gain) else { return (nil, .missed(.noPicture)) }
        let notches = scan(grid, rows: 145..<217, lengths: 5...14, maximum: 16)
        guard !notches.slots.isEmpty else { return (nil, .missed(notches.crowded ? .bottomCrowded : .noBottomSlot)) }
        var best = 0.0, pose: Pose?
        var probe = Probe(step: .shape)
        for top in upper {
            for bottom in notches.slots {
                let h = Double(bottom.y - top.y), dx = bottom.x - top.x
                guard (115...179).contains(h), abs(dx) <= h * 0.24,
                      Double(bottom.length) >= Double(top.length) * 0.46, bottom.length <= top.length,
                      h >= 7.9 * Double(top.length), h <= 16.5 * Double(top.length),
                      h >= 12 * Double(bottom.length), h <= 30 * Double(bottom.length) else { continue }
                probe.step = max(probe.step, .rim)
                guard smoothRim(grid, top, dx, h), smoothRim(grid, bottom, dx, h) else { continue }
                probe.step = max(probe.step, .sides)
                let left = sideStrength(grid, top, dx, h, side: -1)
                let right = sideStrength(grid, top, dx, h, side: 1)
                let found = Pose(topX: top.x / 400, topY: Double(top.y) / 225, bottomX: bottom.x / 400, bottomY: Double(bottom.y) / 225)
                guard left >= sideThreshold, right >= sideThreshold else {
                    if min(left, right) > probe.side {
                        probe.side = min(left, right)
                        probe.candidate = found
                    }
                    continue
                }
                let edges = Double(min(left, right)) + 0.25 * Double(max(left, right))
                let rims = rimBoundary(grid, top, dx, h, lower: false) + rimBoundary(grid, bottom, dx, h, lower: true)
                let score = edges + 0.1 * Double(min(top.contrast, bottom.contrast)) + 0.5 * Double(rims)
                if score > best {
                    best = score
                    pose = found
                }
            }
        }
        return pose == nil ? (nil, probe) : (pose, Probe(step: .found))
    }

    private static func slots(_ grid: Grid, rows: Range<Int>, lengths: ClosedRange<Int>, maximum: Int) -> [Slot] {
        scan(grid, rows: rows, lengths: lengths, maximum: maximum).slots
    }

    /// Yarıkların arandığı en sağ sütun (400×225 ızgarada; arama `scanLeft`'ten başlar). Önceden 294'tü (karenin %73,5'i): GTA 6
    /// telefonu sağ elde ~%70'te durur, hoparlör yarığının sağ ucu sınıra değiyordu; telefon %1,5 sağa oynayınca yarık
    /// kesiliyor, sıkı arama da gevşek doğrulama da "hoparlör yarığı yok"ta kalıyordu (#1251, beta-104 günlüğü: telefon
    /// açılıp ~1,1 sn içinde kapanıyor, sonraki aramaların çoğu hoparlör yarığında kalıyor). Kamera, kasa ve yan kenar
    /// örnekleri için ızgara karenin tamamı okunur (Windows ve Android ile aynı).
    static let scanRight = 324

    /// Yarıkların arandığı en sol sütun: `scanRight`'ın aynası (400 − 324). Telefon sol elde tutulunca (#1385, beta-105)
    /// görüntü aynalanır, hoparlör yarığı karenin ~%30'unda durur; arama önceden 105'ten (%26) başlıyordu, telefon biraz sola
    /// oynayınca yarık kesiliyordu (Windows ve Android ile aynı).
    static let scanLeft = 400 - scanRight

    /// Telefon kutusunun merkezi bu sınırın solundaysa akla yatkın değil (karenin sol kenarındaki HUD, harita). Önceden 0,35'ti:
    /// sol eldeki telefonun merkezi ~0,30'da kaldığından izleyici onu hiç açmıyordu, telefon ne okunuyor ne de ekran yazısından
    /// dışlanıyordu (#1385; Windows ve Android ile aynı).
    static let minCenterX = 0.2

    /// Şeritteki yarıklar; `maximum`'dan çoksa hiçbiri (`crowded`: menü ya da yazı satırları, telefon aranmaz).
    private static func scan(_ grid: Grid, rows: Range<Int>, lengths: ClosedRange<Int>, maximum: Int) -> (slots: [Slot], crowded: Bool) {
        guard !rows.isEmpty, rows.lowerBound >= 4, rows.upperBound <= 221 else { return ([], false) }
        let left = scanLeft - 10, width = scanRight + 11 - left
        var band = [UInt8](repeating: 0, count: (rows.count + 8) * width)
        for y in (rows.lowerBound - 4)..<(rows.upperBound + 4) {
            let row = (y - rows.lowerBound + 4) * width
            for i in 0..<width { band[row + i] = UInt8(grid.at(left + i, y)) }
        }
        var found: [Slot] = []
        for y in rows {
            let row = (y - rows.lowerBound + 4) * width
            var start: Int?
            for x in (scanLeft - left)...(scanRight - left) {
                let p = row + x
                let surround = Int(min(band[p - 3 * width], band[p + 3 * width]))
                if x < scanRight - left, surround - Int(band[p]) >= limit(surround / 3, 14, 25) {
                    if start == nil { start = x }
                    continue
                }
                if let s = start, lengths.contains(x - s) {
                    let center = row + s + (x - s) / 2, end = p + 1, border = row + s - 2
                    let rim = [band[border-4*width], band[center-4*width], band[end-4*width],
                               band[border+4*width], band[center+4*width], band[end+4*width],
                               band[border], band[end]].sorted()
                    let tone = (Int(rim[3]) + Int(rim[4])) / 2
                    let contrast = tone - Int(band[center])
                    if contrast >= limit(tone / 3, 20, 33), Int(rim[7]) - Int(rim[0]) <= max(24, contrast * 3 / 4) {
                        guard found.count < maximum else { return ([], true) }
                        found.append(Slot(x: Double(left) + Double(s + x - 1) / 2, y: y, length: x - s, contrast: contrast))
                    }
                }
                start = nil
            }
        }
        return (found, false)
    }

    private static func hasCamera(_ grid: Grid, _ top: Slot) -> Bool {
        let nearest = max(5, rounded(Double(top.length) * 0.62)), farthest = rounded(Double(top.length) * 1.15)
        guard nearest <= farthest else { return false }
        for side in [-1, 1] {
            for d in nearest...farthest {
                for y in (top.y - 2)...(top.y + 2) {
                    let x = rounded(top.x) + side * d
                    let above = grid.at(x,y-3), below = grid.at(x,y+3), left = grid.at(x-3,y), right = grid.at(x+3,y)
                    let low = min(above, below, left, right), high = max(above, below, left, right)
                    if low - grid.at(x,y) >= limit(low / 3, 15, 23), Double(high - low) < max(25, Double(top.contrast) * 0.9) { return true }
                }
            }
        }
        return false
    }

    private static func smoothRim(_ grid: Grid, _ slot: Slot, _ dx: Double, _ h: Double) -> Bool {
        let r = Int(h * 0.14)
        return [-r, 3-r, r-3, r].filter { k in
            let x = rounded(slot.x) + k, y = slot.y + rounded(-Double(k) * dx / h)
            return abs(grid.at(x,y-2) - grid.at(x,y+2)) < 16
        }.count >= 3
    }

    private static func rimBoundary(_ grid: Grid, _ slot: Slot, _ dx: Double, _ h: Double, lower: Bool) -> Int {
        var best = 0
        for distance in stride(from: lower ? -10 : 3, through: lower ? -4 : 7, by: 2) {
            let samples = (-2...2).map { i -> Int in
                let k = Double(i) * 0.08, d = Double(distance) * 0.01
                let x = rounded(slot.x + k * h + dx * d)
                let y = rounded(Double(slot.y) + h * d - (lower ? 0.8 : 0.52) * dx * k)
                return abs(grid.at(x,y-2) - grid.at(x,y+2))
            }.sorted()
            best = max(best, samples[2])
        }
        return best
    }

    private static func sideStrength(_ grid: Grid, _ slot: Slot, _ dx: Double, _ h: Double, side: Int) -> Int {
        var best = 0
        for width in 23...27 {
            let r = Double(side * width) * 0.01
            let samples = [0.10, 0.24, 0.39, 0.54, 0.69, 0.84].map { t -> Int in
                let x = rounded(slot.x + t * dx + r * h), y = rounded(Double(slot.y) + t * h - r * dx)
                return max(abs(grid.at(x-4,y) - grid.at(x,y)), abs(grid.at(x-2,y) - grid.at(x+2,y)), abs(grid.at(x,y) - grid.at(x+4,y)))
            }.sorted()
            best = max(best, (samples[2] + samples[3]) / 2)
        }
        return best
    }
}
