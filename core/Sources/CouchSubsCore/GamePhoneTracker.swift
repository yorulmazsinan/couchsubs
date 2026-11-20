// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics

/// The two aligned observations keep a single menu or subtitle frame from opening a phone session.
public final class GamePhoneTracker {
    public static let intervalMs = 330
    private let locate: (CGImage) -> GamePhoneGeometry.Pose?
    private var lastTime: Int?
    private var previous: GamePhoneGeometry.Pose?
    private var shown: GamePhoneGeometry.Pose?

    public init() { locate = GamePhoneGeometry.locate }
    init(locate: @escaping (CGImage) -> GamePhoneGeometry.Pose?) { self.locate = locate }

    public func sample(_ image: CGImage, now: Int) -> (sampled: Bool, pose: GamePhoneGeometry.Pose?) {
        if let lastTime, now >= lastTime, now - lastTime < Self.intervalMs { return (false, shown) }
        lastTime = now
        // Akıl sınırı: telefon ekranın küçük, dikey bir parçasıdır. Dışındaki bir aday (menüde ya da koyu ekranda yanlış
        // eşleşme) kabul edilmez; TV'de büyük opak telefon kutusu oyun görüntüsünü kapatırdı (Windows ile aynı).
        var found = locate(image)
        if let pose = found, !Self.plausible(pose.bounds, width: image.width, height: image.height) { found = nil }
        if let found, let previous, found.bounds.isClose(to: previous.bounds, tolerance: 0.035) { shown = found }
        else { shown = nil }
        previous = found
        return (true, shown)
    }

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

    public static func locate(_ image: CGImage) -> Pose? {
        guard image.width >= 400, image.height >= 225,
              abs(Double(image.width) / Double(image.height) - 400.0 / 225) <= 0.04,
              let topBand = Grid(image, columns: 80..<320, height: 90) else { return nil }
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
