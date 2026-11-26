// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics

/// The two aligned observations keep a single menu or subtitle frame from opening a phone session.
public final class GamePhoneTracker {
    public static let intervalMs = 330
    private let locate: (CGImage, GamePhoneGeometry.Pose?) -> GamePhoneGeometry.Pose?
    private var lastTime: Int?
    private var previous: GamePhoneGeometry.Pose?
    private var shown: GamePhoneGeometry.Pose?

    private var clock = 0
    private lazy var trace = DropLog(clock: { [unowned self] in self.clock })
    /// Telefonun açılması, kapanması ve oynadığı için açılmaması altyazı günlüğüne (`PhoneTrace`; sınırlı). nil: altyazı
    /// günlüğü (Windows ve Android ile aynı satırlar).
    public var onLog: ((String) -> Void)?

    public init() { locate = { GamePhoneGeometry.locate($0, near: $1) } }
    init(locate: @escaping (CGImage) -> GamePhoneGeometry.Pose?) { self.locate = { image, _ in locate(image) } }
    init(locate: @escaping (CGImage, GamePhoneGeometry.Pose?) -> GamePhoneGeometry.Pose?) { self.locate = locate }

    private func note(_ reason: String) { trace.note(PhoneTrace.component, reason, "", log: onLog) }

    public func sample(_ image: CGImage, now: Int) -> (sampled: Bool, pose: GamePhoneGeometry.Pose?) {
        if let lastTime, now >= lastTime, now - lastTime < Self.intervalMs { return (false, shown) }
        lastTime = now
        clock = now
        let wasShown = shown != nil
        // Akıl sınırı: telefon ekranın küçük, dikey bir parçasıdır. Dışındaki bir aday (menüde ya da koyu ekranda yanlış
        // eşleşme) kabul edilmez; TV'de büyük opak telefon kutusu oyun görüntüsünü kapatırdı (Windows ile aynı).
        // Açık telefon yerinde ararken gevşek doğrulama da denenir (`GamePhoneGeometry.locate(near:)`): beyaz ya da mavi
        // ekranlı uygulamada (haber, ayarlar, hava) telefonun yanları zemine karışıyor, sıkı arama ıskalıyordu.
        var found = locate(image, shown)
        if let pose = found, !Self.plausible(pose.bounds, width: image.width, height: image.height) { found = nil }
        if let found, let previous, found.bounds.isClose(to: previous.bounds, tolerance: 0.035) {
            shown = found
            misses = 0
        } else if let current = shown, let found, found.bounds.isClose(to: current.bounds, tolerance: 0.035) {
            // Açık telefonun yakınında tek bir gözlem: aynı telefon, yeri güncellenir.
            shown = found
            misses = 0
        } else if shown != nil, misses < Self.missGrace {
            // Açık telefon tek bir karede bulunamadı ya da el titredi: hemen kapanmaz. Önceden tek ıska paneli kapatıyor,
            // yeniden açılış iki gözlem bekleyip bütün sayfayı yeniden çeviriyordu; çeviriler gidip geliyordu (X'teki
            // bildirim). Telefon gerçekten indirilince `missGrace` tur sonra kapanır.
            misses += 1
        } else {
            shown = nil
            misses = 0
        }
        if !wasShown, shown != nil { note(PhoneTrace.opened) } else if wasShown, shown == nil { note(PhoneTrace.closed) }
        // Telefon art arda iki örnekte bulundu ama yeri çok oynadı: hiç açılmıyor, okuma da başlamıyor (önceden sessizdi).
        if shown == nil, let found, let previous {
            note(PhoneTrace.moving(PhoneTrace.shift(found.bounds, previous.bounds)))
        }
        previous = found
        return (true, shown)
    }

    /// Açık telefon art arda bu kadar örnekte bulunamazsa kapanır (330 ms aralıkla ~1–1,3 sn; Windows ve Android ile aynı).
    /// Önceden 2 örnekti (~0,7 sn): telefonun ekranı bir an okunamayınca panel kaybolup baştan çevrilerek geri geliyordu
    /// (X, 22 Kas, GTA 6 telefonu).
    static let missGrace = 3
    private var misses = 0

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
        return (region.left + region.right) / 2 >= 0.35 && (region.top + region.bottom) / 2 >= 1.0 / 3
    }

    public func reset() {
        lastTime = nil
        previous = nil
        shown = nil
        misses = 0
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
            let p = (y * 2 * pixels.width + 2 * (x - left)) * 4
            let stride = pixels.width * 4
            func tone(_ i: Int) -> Int {
                77 * Int(pixels.bytes[i]) + 150 * Int(pixels.bytes[i+1]) + 29 * Int(pixels.bytes[i+2])
            }
            return (tone(p) + tone(p + 4) + tone(p + stride) + tone(p + stride + 4)) >> 10
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

    /// Simsiyah şerit: örneklerin hepsi bu tondan koyu (0–255).
    static let darkTone = 24

    /// Karedeki telefon. `near`: açık telefonun son yeri; sıkı arama ıskalarsa o yerin hemen çevresinde gevşek doğrulama
    /// yapılır (`confirmPicture`): hoparlör yarığı ve kamera üstte, alt çentik altta aynı yerde duruyorsa telefon
    /// yerindedir. Sinan Bey (beta.100, 3418–3425): beyaz/mavi ekranlı uygulamalarda (haber, makale, hava, ayarlar,
    /// eklenti) telefonun yan kenarları elin ve gövdenin rengine karışıyor, sıkı arama telefonu kaybediyordu; telefon
    /// kaybolunca balonlar kalkıyor ("arada kaçıyor", 3417), telefonun yazıları altyazıya (3418, 3420, 3421) ve ekran
    /// yazısı kutularına (3420–3425) gidiyordu. Gevşek doğrulama yalnız açık telefonun yerinde yapılır: yeni telefon yine
    /// sıkı aramayla ve iki gözlemle açılır (Windows ve Android ile aynı).
    public static func locate(_ image: CGImage, near: Pose? = nil) -> Pose? {
        guard image.width >= 400, image.height >= 225 else { return nil }
        if abs(Double(image.width) / Double(image.height) - 400.0 / 225) <= 0.04 { return locatePicture(image, near: near) }
        // Kare küçültülerek okunur (en çok 960 piksel genişlik); şeritlerin yeri piksel piksel gerekmez.
        let scale = min(1, 960 / Double(image.width))
        let sw = max(1, Int((Double(image.width) * scale).rounded())), sh = max(1, Int((Double(image.height) * scale).rounded()))
        guard let small = GamePhonePixels(image, width: sw, height: sh),
              let area = picture(width: image.width, height: image.height, tone: { x, y in
                  let p = (min(sh - 1, Int(Double(y) * scale)) * sw + min(sw - 1, Int(Double(x) * scale))) * 4
                  return (77 * Int(small.bytes[p]) + 150 * Int(small.bytes[p + 1]) + 29 * Int(small.bytes[p + 2])) >> 8
              }),
              let cropped = image.cropping(to: CGRect(x: area.x, y: area.y, width: area.width, height: area.height)) else { return nil }
        let w = Double(image.width), h = Double(image.height)
        // Açık telefonun yeri görüntünün içine taşınır.
        let local = near.map { pose in
            Pose(topX: (pose.topX * w - Double(area.x)) / Double(area.width), topY: (pose.topY * h - Double(area.y)) / Double(area.height),
                 bottomX: (pose.bottomX * w - Double(area.x)) / Double(area.width),
                 bottomY: (pose.bottomY * h - Double(area.y)) / Double(area.height))
        }
        guard let pose = locatePicture(cropped, near: local) else { return nil }
        func x(_ value: Double) -> Double { (Double(area.x) + value * Double(area.width)) / w }
        func y(_ value: Double) -> Double { (Double(area.y) + value * Double(area.height)) / h }
        return Pose(topX: x(pose.topX), topY: y(pose.topY), bottomX: x(pose.bottomX), bottomY: y(pose.bottomY))
    }

    private static func locatePicture(_ image: CGImage, near: Pose? = nil) -> Pose? {
        guard image.width >= 400, image.height >= 225,
              abs(Double(image.width) / Double(image.height) - 400.0 / 225) <= 0.04 else { return nil }
        if let pose = strictPicture(image) { return pose }
        guard let near else { return nil }
        return confirmPicture(image, near: near)
    }

    /// Gevşek doğrulamada yarıklar açık telefonun son yerinden en çok bu kadar (400×225 ızgarada) uzak olabilir.
    static let confirmReach = 4.0

    /// Açık telefonun son yerinde gevşek doğrulama: üstte kameralı hoparlör yarığı ve altta alt çentik, son yerin
    /// `confirmReach` kadar çevresinde, sıkı aramayla aynı boy ve oran kurallarıyla; yan kenarların ve çerçevenin
    /// gücüne bakılmaz (beyaz ekranda yanlar zemine karışır). Bulunmazsa nil.
    static func confirmPicture(_ image: CGImage, near: Pose) -> Pose? {
        guard let grid = Grid(image, columns: 40..<360, height: 225) else { return nil }
        let topX = near.topX * 400, topY = near.topY * 225, bottomX = near.bottomX * 400, bottomY = near.bottomY * 225
        let reach = Int(confirmReach)
        let upperRows = max(17, Int(topY.rounded()) - reach)..<min(75, Int(topY.rounded()) + reach + 1)
        let lowerRows = max(145, Int(bottomY.rounded()) - reach)..<min(217, Int(bottomY.rounded()) + reach + 1)
        guard !upperRows.isEmpty, !lowerRows.isEmpty else { return nil }
        let upper = slots(grid, rows: upperRows, lengths: 8...19, maximum: 12)
            .filter { abs($0.x - topX) <= confirmReach && hasCamera(grid, $0) }
        let lower = slots(grid, rows: lowerRows, lengths: 5...14, maximum: 16).filter { abs($0.x - bottomX) <= confirmReach }
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

    private static func strictPicture(_ image: CGImage) -> Pose? {
        guard let topBand = Grid(image, columns: 80..<320, height: 90) else { return nil }
        // Normal gameplay ends here. Only sample the body after seeing both a speaker and a camera in the upper band.
        let upper = slots(topBand, rows: 17..<75, lengths: 8...19, maximum: 12).filter { hasCamera(topBand, $0) }
        guard !upper.isEmpty, let grid = Grid(image, columns: 40..<360, height: 225) else { return nil }
        let lower = slots(grid, rows: 145..<217, lengths: 5...14, maximum: 16)
        var best = 0.0, pose: Pose?
        for top in upper {
            for bottom in lower {
                let h = Double(bottom.y - top.y), dx = bottom.x - top.x
                guard (115...179).contains(h), abs(dx) <= h * 0.24,
                      Double(bottom.length) >= Double(top.length) * 0.46, bottom.length <= top.length,
                      h >= 7.9 * Double(top.length), h <= 16.5 * Double(top.length),
                      h >= 12 * Double(bottom.length), h <= 30 * Double(bottom.length),
                      smoothRim(grid, top, dx, h), smoothRim(grid, bottom, dx, h) else { continue }
                let left = sideStrength(grid, top, dx, h, side: -1)
                guard left >= 12 else { continue }
                let right = sideStrength(grid, top, dx, h, side: 1)
                guard right >= 12 else { continue }
                let edges = Double(min(left, right)) + 0.25 * Double(max(left, right))
                let rims = rimBoundary(grid, top, dx, h, lower: false) + rimBoundary(grid, bottom, dx, h, lower: true)
                let score = edges + 0.1 * Double(min(top.contrast, bottom.contrast)) + 0.5 * Double(rims)
                if score > best {
                    best = score
                    pose = Pose(topX: top.x / 400, topY: Double(top.y) / 225, bottomX: bottom.x / 400, bottomY: Double(bottom.y) / 225)
                }
            }
        }
        return pose
    }

    private static func slots(_ grid: Grid, rows: Range<Int>, lengths: ClosedRange<Int>, maximum: Int) -> [Slot] {
        let left = 95, width = 211
        var band = [UInt8](repeating: 0, count: (rows.count + 8) * width)
        for y in (rows.lowerBound - 4)..<(rows.upperBound + 4) {
            let row = (y - rows.lowerBound + 4) * width
            for i in 0..<width { band[row + i] = UInt8(grid.at(left + i, y)) }
        }
        var found: [Slot] = []
        for y in rows {
            let row = (y - rows.lowerBound + 4) * width
            var start: Int?
            for x in (105 - left)...(294 - left) {
                let p = row + x
                let surround = Int(min(band[p - 3 * width], band[p + 3 * width]))
                if x < 294 - left, surround - Int(band[p]) >= limit(surround / 3, 14, 25) {
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
                        guard found.count < maximum else { return [] }
                        found.append(Slot(x: Double(left) + Double(s + x - 1) / 2, y: y, length: x - s, contrast: contrast))
                    }
                }
                start = nil
            }
        }
        return found
    }

    private static func hasCamera(_ grid: Grid, _ top: Slot) -> Bool {
        for side in [-1, 1] {
            for d in max(5, rounded(Double(top.length) * 0.62))...rounded(Double(top.length) * 1.15) {
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
