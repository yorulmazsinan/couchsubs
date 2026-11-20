// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Hazır ek alanın (oyuna göre sabit bölge, `GameAreaPresets`) içindeki yazı gerçekten oyunun arayüz kutusunda mı: oyun
/// yanlış seçiliyse (PS5 ana ekranı, başka oyun) ya da bölgede yalnız oyun dünyası varsa (tabela, plaka, poster)
/// çevrilmez. Bölge 96 × 48 noktaya örneklenir, 8 × 8 hücreye bölünür; her hücrede azınlık parlaklık kümesi yazı, çoğunluk
/// zemindir. Yazılı hücrenin zemini düz (sapma ≤ 22 ve %70'i ortancanın ±20'sinde) ise hücre düzdür. Kanıt: en az 3 düz
/// yazılı hücre ya da yazılı hücrelerin %60'ı düz. Windows (UiPanel.cs) ve Android (UiPanel.kt) aynı kuralları uygular.
public enum UiPanel {
    public static let gridX = 96, gridY = 48, cells = 8
    static let textShare = 0.04, minContrast = 60.0
    static let groundDeviation = 22.0, groundShare = 0.7, groundTone = 20
    static let flatCells = 0.6, minFlatCells = 3

    /// Bölgede düz panel üstünde yazı var mı.
    public static func hasText(_ crop: CGImage) -> Bool {
        guard crop.width >= 8, crop.height >= 8, let luma = gray(crop) else { return false }
        return hasText(luma: luma)
    }

    /// `gridX × gridY` parlaklık değerleri (satır satır) üzerinde karar; testler doğrudan çağırır.
    static func hasText(luma: [UInt8]) -> Bool {
        let cellW = gridX / cells, cellH = gridY / cells
        var textCells = 0, flat = 0
        var cell = [Int](repeating: 0, count: cellW * cellH)
        for cy in 0..<cells {
            for cx in 0..<cells {
                var n = 0
                for y in (cy * cellH)..<((cy + 1) * cellH) {
                    for x in (cx * cellW)..<((cx + 1) * cellW) {
                        cell[n] = Int(luma[y * gridX + x]); n += 1
                    }
                }
                switch classify(cell) {
                case .flat: textCells += 1; flat += 1
                case .busy: textCells += 1
                case .empty: break
                }
            }
        }
        return flat >= minFlatCells || (textCells > 0 && Double(flat) >= Double(textCells) * flatCells)
    }

    private enum Cell { case empty, flat, busy }

    private static func classify(_ values: [Int]) -> Cell {
        let threshold = otsu(values)
        var above = 0, aboveSum = 0.0, belowSum = 0.0
        for value in values {
            if value > threshold { above += 1; aboveSum += Double(value) } else { belowSum += Double(value) }
        }
        let below = values.count - above
        guard above > 0, below > 0 else { return .empty }
        let textBright = above <= below
        let text = textBright ? above : below
        guard Double(text) >= Double(values.count) * textShare,
              abs(aboveSum / Double(above) - belowSum / Double(below)) >= minContrast else { return .empty }
        var ground = values.filter { ($0 > threshold) != textBright }
        let mean = Double(ground.reduce(0, +)) / Double(ground.count)
        let deviation = (ground.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(ground.count)).squareRoot()
        ground.sort()
        let median = ground[ground.count / 2]
        let near = ground.filter { abs($0 - median) <= groundTone }.count
        return deviation <= groundDeviation && Double(near) >= Double(ground.count) * groundShare ? .flat : .busy
    }

    private static func otsu(_ values: [Int]) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        var sum = 0.0
        for value in values { histogram[value] += 1; sum += Double(value) }
        var sumBack = 0.0, best = -1.0, weightBack = 0, threshold = 127
        for i in 0..<256 {
            weightBack += histogram[i]
            if weightBack == 0 { continue }
            let weightFore = values.count - weightBack
            if weightFore == 0 { break }
            sumBack += Double(i * histogram[i])
            let meanBack = sumBack / Double(weightBack), meanFore = (sum - sumBack) / Double(weightFore)
            let between = Double(weightBack) * Double(weightFore) * (meanBack - meanFore) * (meanBack - meanFore)
            if between > best { best = between; threshold = i }
        }
        return threshold
    }

    /// Kareyi `gridX × gridY` gri noktaya indirir (nokta örnekleme; Windows'taki gibi ara değer yok).
    private static func gray(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: gridX * gridY)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: gridX, height: gridY, bitsPerComponent: 8,
                                          bytesPerRow: gridX, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: gridX, height: gridY))
            return true
        }
        return ok ? pixels : nil
    }
}

extension GameAreaPresets {
    /// Hazır alanın kimliği mi (bu alanlar ancak `UiPanel.hasText` kanıtıyla okunur).
    public static func isPreset(_ id: String) -> Bool { id == helpId || id == phoneId }
}
