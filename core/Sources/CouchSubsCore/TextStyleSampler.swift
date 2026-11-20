// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Yazı bloğunun görünüşü (çeviri özgün yazının stilinde çizilsin diye): kalın mı, dar mı, hizası, BÜYÜK HARF mi ve
/// zemin düz mü. Düz zeminde kutu zemin rengiyle tam opak doldurulur; değilse (harita, dünya) %85 opak kaplanır.
/// TV'ye region bloklarının `style` alanıyla (`flat` `surface` içinde) gider; eski TV yok sayar.
public struct TextLook: Equatable, Sendable {
    public enum Align: String, Sendable { case left, center, right }
    public var bold: Bool
    public var condensed: Bool
    public var align: Align
    public var upper: Bool
    public var flat: Bool

    public init(bold: Bool, condensed: Bool, align: Align, upper: Bool, flat: Bool) {
        self.bold = bold
        self.condensed = condensed
        self.align = align
        self.upper = upper
        self.flat = flat
    }
}

/// Otomatik bulunan ekran yazısının stilini kareden çıkarır (Windows/Android: TextStyleSampler ile aynı kurallar). Blok
/// kutusundaki pikseller parlaklığa göre iki kümeye ayrılır (Otsu eşiği): az olan küme yazı, çok olan zemin.
public enum TextStyleSampler {
    /// Yazı pikseli oranı (satır kutularında) en az bu kadarsa kalın.
    public static let boldInk = 0.28
    /// Ortalama harf genişliği / satır yüksekliği bundan küçükse dar yazı ailesi.
    public static let condensedWidth = 0.45
    /// Özgün harflerin en az bu kadarı büyükse çeviri de büyük harfe çevrilir.
    public static let upperShare = 0.8
    /// Zemin kümesinin renk sapması bundan küçükse düz zemin.
    public static let flatDeviation = 16.0

    public static let neutral = PhoneTextStyle(background: "#000000", foreground: "#FFFFFF")

    private static let samplesX = 48
    private static let samplesY = 10

    private struct Pixel { var luma: Int, r: Int, g: Int, b: Int }

    /// `frame`: okunan alanın görüntüsü; `box` ve `lines` ona oranla. `lines`: bloğun satırları (metni ve kutusu); boşsa
    /// yalnız blok kutusu örneklenir.
    public static func sample(_ frame: CGImage, box: TextBox, lines: [TextLine], source: String) -> (surface: PhoneTextStyle, look: TextLook) {
        var boxes = lines.compactMap(\.box)
        if boxes.isEmpty { boxes = [box] }
        var pixels: [Pixel] = []
        for area in boxes { collect(frame, area, into: &pixels) }
        let upper = isUpper(source)
        let align = alignment(boxes)
        let condensed = isCondensed(frame, lines)
        guard pixels.count >= 8 else {
            return (neutral, TextLook(bold: false, condensed: condensed, align: align, upper: upper, flat: false))
        }
        let threshold = otsu(pixels)
        let low = pixels.filter { $0.luma <= threshold }
        let high = pixels.filter { $0.luma > threshold }
        guard !low.isEmpty, !high.isEmpty else {
            return (neutral, TextLook(bold: false, condensed: condensed, align: align, upper: upper, flat: false))
        }
        let (ink, ground) = low.count < high.count ? (low, high) : (high, low)
        let bold = Double(ink.count) / Double(pixels.count) >= boldInk
        let background = mean(ground)
        var foreground = mean(ink)
        let flat = deviation(ground) < flatDeviation
        if contrast(background, foreground) < 3 {
            let shade = Double(ground.map(\.luma).reduce(0, +)) / Double(ground.count)
            foreground = shade < 128 ? "#FFFFFF" : "#000000"
        }
        return (PhoneTextStyle(background: background, foreground: foreground),
                TextLook(bold: bold, condensed: condensed, align: align, upper: upper, flat: flat))
    }

    /// Türkçe kurallarıyla büyük harf (i → İ, ı → I); sistem diline bağlı değildir.
    public static func turkishUpper(_ text: String) -> String {
        text.uppercased(with: Locale(identifier: "tr_TR"))
    }

    /// Harflerin en az %80'i büyük mü.
    public static func isUpper(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        return !letters.isEmpty && Double(letters.filter(\.isUppercase).count) >= upperShare * Double(letters.count)
    }

    private static func collect(_ frame: CGImage, _ area: TextBox, into pixels: inout [Pixel]) {
        let left = max(0, min(1, area.left)) * Double(frame.width)
        let right = max(0, min(1, area.right)) * Double(frame.width)
        let top = max(0, min(1, area.top)) * Double(frame.height)
        let bottom = max(0, min(1, area.bottom)) * Double(frame.height)
        guard right - left >= 2, bottom - top >= 2,
              let grid = GamePhonePixels(frame, in: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                                         width: samplesX, height: samplesY) else { return }
        for i in stride(from: 0, to: grid.bytes.count, by: 4) {
            let r = Int(grid.bytes[i]), g = Int(grid.bytes[i + 1]), b = Int(grid.bytes[i + 2])
            pixels.append(Pixel(luma: (299 * r + 587 * g + 114 * b) / 1000, r: r, g: g, b: b))
        }
    }

    private static func otsu(_ pixels: [Pixel]) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        for pixel in pixels { histogram[pixel.luma] += 1 }
        let total = Double(pixels.count)
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * histogram[i]) }
        var below = 0.0, belowSum = 0.0, best = -1.0
        var threshold = 127
        for t in 0..<255 {
            below += Double(histogram[t])
            if below == 0 { continue }
            let above = total - below
            if above == 0 { break }
            belowSum += Double(t * histogram[t])
            let meanBelow = belowSum / below
            let meanAbove = (sum - belowSum) / above
            let between = below * above * (meanBelow - meanAbove) * (meanBelow - meanAbove)
            if between > best {
                best = between
                threshold = t
            }
        }
        return threshold
    }

    private static func mean(_ pixels: [Pixel]) -> String {
        let n = pixels.count
        return String(format: "#%02X%02X%02X", pixels.map(\.r).reduce(0, +) / n, pixels.map(\.g).reduce(0, +) / n,
                      pixels.map(\.b).reduce(0, +) / n)
    }

    private static func deviation(_ pixels: [Pixel]) -> Double {
        func spread(_ channel: (Pixel) -> Int) -> Double {
            let values = pixels.map { Double(channel($0)) }
            let average = values.reduce(0, +) / Double(values.count)
            return (values.map { ($0 - average) * ($0 - average) }.reduce(0, +) / Double(values.count)).squareRoot()
        }
        return (spread(\.r) + spread(\.g) + spread(\.b)) / 3
    }

    /// WCAG 2 kontrast oranı (1–21).
    static func contrast(_ a: String, _ b: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let (r, g, b) = SpeakerColors.rgb(hex) ?? (0, 0, 0)
            func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func isCondensed(_ frame: CGImage, _ lines: [TextLine]) -> Bool {
        let ratios = lines.compactMap { line -> Double? in
            let count = line.text.trimmingCharacters(in: .whitespaces).count
            guard let box = line.box, count > 0 else { return nil }
            let height = max(1, (box.bottom - box.top) * Double(frame.height))
            return (box.right - box.left) * Double(frame.width) / Double(count) / height
        }
        return !ratios.isEmpty && ratios.reduce(0, +) / Double(ratios.count) < condensedWidth
    }

    private static func alignment(_ boxes: [TextBox]) -> TextLook.Align {
        guard boxes.count >= 2 else { return .left }
        let width = max(1e-6, boxes.map(\.right).max()! - boxes.map(\.left).min()!)
        func spread(_ edge: (TextBox) -> Double) -> Double {
            let values = boxes.map(edge)
            return (values.max()! - values.min()!) / width
        }
        let left = spread(\.left)
        let center = spread { ($0.left + $0.right) / 2 }
        let right = spread(\.right)
        // Eşitlikte (aynı genişlikteki satırlar) sola yaslı sayılır.
        if left <= center + 0.01 && left <= right + 0.01 { return .left }
        return center <= right + 0.01 ? .center : .right
    }
}
