// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Consistent, top-origin RGBA samples for Core Graphics images, including VideoToolbox frames.
/// Crop before drawing: a message bubble must not require a full-screen conversion.
///
/// Baytlar hep 8 bit, R G B A sırasında ve önceden çarpılmış alfalıdır (yarı saydam nokta siyah zemindeki rengiyle; çeviri katmanı gibi saydam resimde alfa korunur); karenin kanal
/// düzeni (BGRA/RGBA), alfası (önceden çarpılmış, başta/sonda), derinliği (16 bit, yarım kayan nokta) ne olursa olsun.
/// Renk uzayı `FrameColor.target`: sRGB ya da sRGB sayılan video/aygıt uzayı. Kullanıcı bildirimi (X, Mac mini,
/// beta-101): aynı kare dosyadan verilince telefon bulunuyor, canlıda bulunmuyordu; kare RGB'ye çevrilince canlıda da
/// bulunuyordu. Canlı kare (ScreenCaptureKit) ekranın renk uzayında gelir ve önceden o uzayda çizilip olduğu gibi
/// okunuyordu; dosyadaki kare sRGB'dir. Windows (BGRA, sRGB) ve Android (YUV; tam aralık çözücüde, video-decoder.c, sınırlıya
/// çevrilir) aynı değerleri görür.
struct GamePhonePixels {
    let width: Int
    let height: Int
    let x: Int
    let y: Int
    let bytes: [UInt8]
    /// Baytların renk uzayı (`FrameColor.target`).
    let space: CGColorSpace

    init?(_ image: CGImage, in rect: CGRect? = nil, width outputWidth: Int? = nil, height outputHeight: Int? = nil) {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let frame = (rect ?? extent).integral.intersection(extent)
        guard !frame.isEmpty else { return nil }
        let source: CGImage
        if frame == extent { source = image }
        else if let cropped = image.cropping(to: frame) { source = cropped }
        else { return nil }
        x = Int(frame.minX)
        y = Int(frame.minY)
        let w = outputWidth ?? Int(frame.width), h = outputHeight ?? Int(frame.height)
        guard w > 0, h > 0 else { return nil }
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let wanted = FrameColor.target(for: image)
        FrameColor.note(image, target: wanted)
        var space = wanted
        var storage = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = storage.withUnsafeMutableBytes { buffer -> Bool in
            func make(_ space: CGColorSpace) -> CGContext? {
                CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: space, bitmapInfo: info)
            }
            var made = make(space)
            if made == nil, space !== FrameColor.sRGB { space = FrameColor.sRGB; made = make(space) }
            guard let surface = made else { return false }
            surface.setBlendMode(.copy)
            surface.interpolationQuality = .none
            surface.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        bytes = storage
        self.space = space
    }

    /// Native-scale crop only; the rect uses the same pixel coordinates as the source.
    func offset(_ px: Int, _ py: Int) -> Int {
        (min(height - 1, max(0, py - y)) * width + min(width - 1, max(0, px - x))) * 4
    }

    static func rect(_ box: TextBox, in image: CGImage) -> CGRect {
        CGRect(x: box.left * Double(image.width), y: box.top * Double(image.height),
               width: (box.right - box.left) * Double(image.width), height: (box.bottom - box.top) * Double(image.height))
    }
}

/// Telefon araması ve renk örnekleri için karenin baytlarının renk uzayı. Hedef sRGB'dir (oyun görüntüsü sRGB/BT.709
/// kodludur; dosyadaki kareler ve denemeler sRGB). Kare 8 bitlik sRGB, aygıt RGB'si ya da BT.709/601 video uzayındaysa
/// (VideoToolbox'ın çözdüğü Remote Play/Xbox karesi; video baytları ekranda sRGB gibi gösterilir) baytları değiştirilmez;
/// ekranın renk uzayındaki (Display P3, ekranın ICC profili), geniş gamlı, doğrusal, HDR (PQ/HLG), 8 bitten derin ya da
/// gri kare sRGB'ye çevrilir.
enum FrameColor {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static let passthrough: Set<String> = [
        CGColorSpace.sRGB as String, CGColorSpace.itur_709 as String, "kCGColorSpaceITUR_601", "kCGColorSpaceDeviceRGB",
    ]

    /// `image`'ın çizileceği 8 bit RGB uzayı.
    static func target(for image: CGImage) -> CGColorSpace {
        guard let space = image.colorSpace, space.model == .rgb else { return sRGB }
        let deep = image.bitsPerComponent > 8 || image.bitmapInfo.contains(.floatComponents)
        return !deep && passes(space) ? space : sRGB
    }

    static func passes(_ space: CGColorSpace) -> Bool {
        if let name = space.name as String? { return passthrough.contains(name) }
        return CFEqual(space, CGColorSpaceCreateDeviceRGB())
    }

    /// Karenin biçimi (günlük için): renk uzayı, bit, kanal düzeni, alfa.
    static func describe(_ image: CGImage) -> String {
        let space = image.colorSpace.map { ($0.name as String?) ?? "adsız ICC (\($0.model.rawValue))" } ?? "yok"
        let info = image.bitmapInfo
        let order: String
        switch CGBitmapInfo(rawValue: info.rawValue & CGBitmapInfo.byteOrderMask.rawValue) {
        case .byteOrder32Little: order = "BGRA (32 küçük uçlu)"
        case .byteOrder32Big: order = "RGBA (32 büyük uçlu)"
        case .byteOrder16Little: order = "16 küçük uçlu"
        case .byteOrder16Big: order = "16 büyük uçlu"
        default: order = "varsayılan sıra"
        }
        let float = info.contains(.floatComponents) ? " kayan noktalı" : ""
        return "\(space), \(image.bitsPerComponent)/\(image.bitsPerPixel) bit\(float), \(order), alfa \(image.alphaInfo.rawValue)"
    }

    private final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var last: CGColorSpace?
        var lastBits = 0
        var texts: Set<String> = []
    }
    private static let seen = Seen()

    /// Telefon aramasının gördüğü her yeni kare biçimini bir kez günlüğe yazar (renk uzayı şüphesi: canlı kare ile dosya
    /// karesi farklı uzayda mı, çevriliyor mu). Aynı biçimdeki karede yalnız işaretçi karşılaştırılır.
    static func note(_ image: CGImage, target: CGColorSpace) {
        let current = image.colorSpace, bits = image.bitsPerPixel << 16 | Int(image.bitmapInfo.rawValue & 0xFFFF)
        let same: Bool = seen.lock.withLock {
            if let current, let last = seen.last, last === current, seen.lastBits == bits { return true }
            seen.last = current
            seen.lastBits = bits
            return false
        }
        guard !same, SubtitleLog.isEnabled else { return }
        let text = describe(image)
        guard seen.lock.withLock({ seen.texts.insert(text).inserted }) else { return }
        let how = target === image.colorSpace ? "olduğu gibi okunuyor" : "sRGB'ye çevrilip okunuyor"
        SubtitleLog.write("kare biçimi: \(text); telefon araması ve renk örnekleri \(how)")
    }
}
