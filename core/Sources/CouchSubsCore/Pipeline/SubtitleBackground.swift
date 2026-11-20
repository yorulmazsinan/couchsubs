// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// GTA 6'nın koyu lacivert altyazı zemini. OCR satırının arkasındaki rengi sınar; panel kenarı aranmaz.
public enum SubtitleBackground {
    private static let verticalSamples: [Double] = [-0.30, -0.15, 0.10, 0.90, 1.15, 1.30]
    private static let horizontalSamples = 9

    /// Yalnız GTA 6 altyazı zemininin üstündeki OCR satırlarını bırakır.
    public static func filter(_ reading: Reading, in image: CGImage) -> Reading {
        let width = 384
        let height = max(64, min(192, Int((Double(image.height) / Double(image.width) * Double(width)).rounded())))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // Kare kendi renk uzayında çizilir: PS5 karesi VideoToolbox'tan BT.709 etiketiyle gelir ve başka uzaya
        // çevrilirse koyu tonlar açılır (#534). Böylece Windows'taki gibi çözücünün ham değerleri sınanır.
        let spaces = [image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }, CGColorSpaceCreateDeviceRGB()]
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            let made = spaces.lazy.compactMap { space in
                space.flatMap { CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: $0,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) }
            }.first
            guard let context = made else { return false }
            context.interpolationQuality = .low
            // Bitmap satırları ve OCR kutuları üstten ölçülür; görüntüyü ayrıca çevirmeyin.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return .empty }
        return filter(reading, pixels: pixels, width: width, height: height)
    }

    /// Satırın hemen üstü, içi ve altındaki yatay örnekler aynı lacivert zemini taşıyor mu?
    public static func filter(_ reading: Reading, pixels: [UInt8], width: Int, height: Int) -> Reading {
        Reading(lines: reading.lines.filter { line in
            guard let box = line.box else { return false }
            return hasBackground(pixels, width: width, height: height, box: box)
        })
    }

    public static func hasBackground(_ pixels: [UInt8], width: Int, height: Int, box: TextBox) -> Bool {
        guard width > 0, height > 0, pixels.count >= width * height * 4,
              box.right > box.left, box.bottom > box.top else { return false }
        let lineHeight = box.bottom - box.top
        var bestRow = 0
        var total = 0
        for offset in verticalSamples {
            let y = box.top + lineHeight * offset
            if y < 0 || y >= 1 { continue }
            let py = min(height - 1, max(0, Int(y * Double(height))))
            var matches = 0
            for sample in 0..<horizontalSamples {
                let x = box.left + (box.right - box.left) * (Double(sample) + 0.5) / Double(horizontalSamples)
                let px = min(width - 1, max(0, Int(x * Double(width))))
                let i = (py * width + px) * 4
                if isPanelColor(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])) { matches += 1 }
            }
            bestRow = max(bestRow, matches)
            total += matches
        }
        return bestRow >= 7 && total >= 18
    }

    /// Görüntüde ölçülen yaklaşık #21212E; Mac'te #3D3D51'e kadar açık gelebiliyor (#534). Sabit renk yerine kanallar
    /// arası ilişki sınanır: kırmızı ile yeşil yakın, mavi biraz önde (az doygun lacivert), parlaklık geniş aralıkta.
    /// Nötr gri, beyaz/sarı yazı ve doygun mavi (gece göğü, deniz) panel sayılmaz.
    public static func isPanelColor(_ red: Int, _ green: Int, _ blue: Int) -> Bool {
        let brightest = max(red, green)
        guard (14...100).contains(brightest), min(red, green) >= 10,
              abs(red - green) <= max(12, brightest / 5) else { return false }
        let lift = blue - brightest
        return lift >= max(4, brightest / 10) && lift <= max(30, brightest / 2)
    }
}
