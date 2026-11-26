// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// "Ekranı yerinde Türkçe çiz" (deneysel, önce Mac; Sinan Bey kararı 24 Kas): GTA 6 telefonunun Türkçe ikizi. Telefonun
/// ekranı çapanın dönüşümüyle kareden kesilip başvuru dörtgenine düzleştirilir (eğiklik, perspektif ve sarsıntı gider),
/// her çevrilen yazının yalnız harf noktaları zeminden silinir (`TextErase`, #1142: simge, avatar, emoji, fotoğraf ve
/// çerçeve olduğu gibi kalır), Türkçe aynı yere, aynı hizada, özgün yazının rengi ve kalınlığıyla çizilir. Çıkan katman
/// yalnız yazı kutularında opaktır (geri kalanı saydam): oyunun canlı görüntüsü kutuların dışında hiç örtülmez. Çizim her
/// karede çapanın dönüşümüyle telefonun üstüne geri yansıtılır; silme ve çizim yalnız yazı değişince yeniden yapılır.
///
/// Zemin kuralı kutu başına ölçülür (`TextErase.Patch.texture`, kutunun çevre şeridinin düz/degrade kestirimine ortalama
/// uzaklığı): düz ya da hafif degrade zeminde tam silme; desenli/fotoğraflı zeminde yazı kutusuna sıkı oturan, zeminin
/// ortalama renginde kutu. Kutu yatayda yazının kutusundan taşmaz (simgeler örtülmez).
public enum PhoneTwin {
    public struct Layer: @unchecked Sendable {
        /// Çapanın kuşağı: katman yalnız bu kuşağın dönüşümüyle çizilir.
        public let generation: Int
        /// Katmanın kapladığı başvuru dörtgeni (kareye oranlı).
        public let reference: CropRegion
        /// Başvuru dörtgeninin düz görüntüsü; yalnız silinip yeniden yazılan kutular opak.
        public let image: CGImage
        /// Kutu başına zemin kararı ve ölçü (günlük için).
        public let notes: [String]
    }

    /// Düz görüntünün en büyük yüksekliği (piksel): çok büyük telefonda silme ve çizim süresi sınırlı kalsın.
    static let maxHeight = 900

    /// Yazının çevirisi aslıyla aynıysa (ad, sayı, fiyat) dokunulmaz: özgün yazı görünür kalır.
    static func unchanged(_ item: ScreenTranslation.Item) -> Bool {
        let a = IconText.plain(item.source).trimmingCharacters(in: .whitespacesAndNewlines)
        let b = IconText.plain(item.translation).trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty || a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// `frame`: çapanın `pose` yerindeki kare; `items`: başvuru koordinatında balonlar (kareye oranlı).
    public static func build(frame: CGImage, pose: AnchorPose, items: [ScreenTranslation.Item]) -> Layer? {
        let r = pose.reference
        let rw = r.right - r.left, rh = r.bottom - r.top
        guard rw > 0, rh > 0, rw.isFinite, rh.isFinite else { return nil }
        let fw = Double(frame.width), fh = Double(frame.height)
        var outW = max(2, Int((rw * fw).rounded())), outH = max(2, Int((rh * fh).rounded()))
        if outH > maxHeight {
            outW = max(2, outW * maxHeight / outH)
            outH = maxHeight
        }
        // Telefonun bu karedeki yerinin (kenar payıyla) kopyası; tüm kare kopyalanmaz.
        let shown = pose.fromReference(r)
        let crop = CGRect(x: (shown.left - 0.01) * fw, y: (shown.top - 0.01) * fh,
                          width: (shown.right - shown.left + 0.02) * fw, height: (shown.bottom - shown.top + 0.02) * fh)
        guard let source = GamePhonePixels(frame, in: crop) else { return nil }
        var twin = TextErase.Image(width: outW, height: outH, bytes: rectify(source, pose: pose, width: outW, height: outH,
                                                                              frameWidth: fw, frameHeight: fh))
        var rects: [(Int, Int, Int, Int)] = []
        var notes: [String] = []
        for item in items where !unchanged(item) {
            let box = TextBox(left: (item.box.left - r.left) / rw, top: (item.box.top - r.top) / rh,
                              right: (item.box.right - r.left) / rw, bottom: (item.box.bottom - r.top) / rh)
            guard box.right > box.left, box.bottom > box.top, box.right > 0, box.bottom > 0, box.left < 1, box.top < 1 else { continue }
            let clipped = TextBox(left: max(0, box.left), top: max(0, box.top), right: min(1, box.right), bottom: min(1, box.bottom))
            let x0 = Int((clipped.left * Double(outW)).rounded(.down)), x1 = min(outW - 1, Int((clipped.right * Double(outW)).rounded(.up)))
            let y0 = Int((clipped.top * Double(outH)).rounded(.down)), y1 = min(outH - 1, Int((clipped.bottom * Double(outH)).rounded(.up)))
            guard x1 > x0 + 1, y1 > y0 + 1 else { continue }
            let patch = TextErase.erase(&twin, box: clipped) ?? fallback(twin, item: item, rect: (x0, y0, x1, y1))
            let text = IconText.plain(item.translation)
            TextErase.draw(text, in: &twin, box: clipped, lineHeight: item.lineHeight / rh, rows: max(1, item.rows), patch: patch,
                           bold: item.look?.bold ?? false, align: item.look?.align ?? .left)
            let p = patch.rect
            rects.append((min(p.x0, x0), min(p.y0, y0), max(p.x1, x1), max(p.y1, y1)))
            notes.append(String(format: "%@: %@ (doku %.1f, kalan iz %%%.0f)", String(text.prefix(24)),
                                patch.clean ? "silindi, yerine çizildi" : "desenli zemin, zemin renginde kutu",
                                patch.texture, patch.residual * 100))
        }
        guard !rects.isEmpty else { return nil }
        // Yalnız kutular opak; geri kalan saydam (oyunun canlı görüntüsü görünür).
        var out = [UInt8](repeating: 0, count: outW * outH * 4)
        for (x0, y0, x1, y1) in rects {
            for y in max(0, y0)...min(outH - 1, y1) {
                let start = (y * outW + max(0, x0)) * 4, end = (y * outW + min(outW - 1, x1)) * 4 + 4
                for i in stride(from: start, to: end, by: 4) {
                    out[i] = twin.bytes[i]
                    out[i + 1] = twin.bytes[i + 1]
                    out[i + 2] = twin.bytes[i + 2]
                    out[i + 3] = 255
                }
            }
        }
        guard let image = TextErase.Image(width: outW, height: outH, bytes: out).cgImage() else { return nil }
        return Layer(generation: pose.generation, reference: r, image: image, notes: notes)
    }

    /// Temiz harf bulunamadı (yazı soluk ya da kutu yazıdan büyük): kutu zeminin ortalama renginde doldurulur, yazı
    /// balonun yazı renginde çizilir.
    private static func fallback(_ image: TextErase.Image, item: ScreenTranslation.Item,
                                 rect: (Int, Int, Int, Int)) -> TextErase.Patch {
        func hex(_ value: String?) -> (Int, Int, Int)? {
            guard let value, value.count == 7, value.hasPrefix("#"), let v = Int(value.dropFirst(), radix: 16) else { return nil }
            return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
        }
        var sum = (0, 0, 0), n = 0
        for y in [rect.1, rect.3] {
            for x in stride(from: rect.0, through: rect.2, by: 2) {
                let c = image.rgb(x, y)
                sum = (sum.0 + c.0, sum.1 + c.1, sum.2 + c.2)
                n += 1
            }
        }
        let ground = hex(item.style?.background) ?? (n == 0 ? (0, 0, 0) : (sum.0 / n, sum.1 / n, sum.2 / n))
        let ink = hex(item.style?.foreground) ?? ((ground.0 + ground.1 + ground.2) / 3 > 128 ? (0, 0, 0) : (255, 255, 255))
        return TextErase.Patch(rect: (x0: rect.0, y0: rect.1, x1: rect.2, y1: rect.3), masked: 0, residual: 0, clean: false,
                               ink: ink, outline: nil, ground: ground, texture: -1)
    }

    /// Başvuru dörtgeninin düz görüntüsü: her çıkış noktası için çapanın o karedeki yeri çift doğrusal örneklenir.
    static func rectify(_ source: GamePhonePixels, pose: AnchorPose, width: Int, height: Int,
                        frameWidth: Double, frameHeight: Double) -> [UInt8] {
        let r = pose.reference
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let sw = source.width, sh = source.height
        let ox = Double(source.x), oy = Double(source.y)
        source.bytes.withUnsafeBufferPointer { src in
            for j in 0..<height {
                let ny = r.top + (Double(j) + 0.5) / Double(height) * (r.bottom - r.top)
                for i in 0..<width {
                    let nx = r.left + (Double(i) + 0.5) / Double(width) * (r.right - r.left)
                    let p = pose.map(nx, ny)
                    let fx = p.x * frameWidth - 0.5 - ox, fy = p.y * frameHeight - 0.5 - oy
                    let x0 = min(max(0, Int(fx.rounded(.down))), sw - 1), y0 = min(max(0, Int(fy.rounded(.down))), sh - 1)
                    let x1 = min(x0 + 1, sw - 1), y1 = min(y0 + 1, sh - 1)
                    let tx = min(max(0, fx - Double(x0)), 1), ty = min(max(0, fy - Double(y0)), 1)
                    let o = (j * width + i) * 4
                    for c in 0..<3 {
                        let a = Double(src[(y0 * sw + x0) * 4 + c]), b = Double(src[(y0 * sw + x1) * 4 + c])
                        let d = Double(src[(y1 * sw + x0) * 4 + c]), e = Double(src[(y1 * sw + x1) * 4 + c])
                        let top = a + (b - a) * tx, bottom = d + (e - d) * tx
                        out[o + c] = UInt8(max(0, min(255, (top + (bottom - top) * ty).rounded())))
                    }
                    out[o + 3] = 255
                }
            }
        }
        return out
    }
}
