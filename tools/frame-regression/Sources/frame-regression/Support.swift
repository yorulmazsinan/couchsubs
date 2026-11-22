// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CouchSubsCore
import CryptoKit
import Foundation
import ImageIO

enum Images {
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Aynı boyda simsiyah kare (altyazının kalktığı an).
    static func blank(width: Int, height: Int) -> CGImage {
        let context = rgba(width: width, height: height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Karenin `area` alanı (kenarlara oranla) hemen solundaki pikselin rengiyle örtülür: yazı tanıma oradaki yazıyı
    /// (konuşan adını) okuyamaz.
    static func hiding(_ image: CGImage, _ area: TextBox) -> CGImage {
        let width = image.width, height = image.height
        let data = pixels(image)
        let x = max(0, Int(area.left * Double(width)) - 4), y = min(height - 1, Int((area.top + area.bottom) / 2 * Double(height)))
        let i = (y * width + x) * 4
        let context = rgba(width: width, height: height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: Double(data[i]) / 255, green: Double(data[i + 1]) / 255, blue: Double(data[i + 2]) / 255, alpha: 1))
        // CoreGraphics'in y ekseni aşağıdan yukarı.
        context.fill(CGRect(x: area.left * Double(width), y: (1 - area.bottom) * Double(height),
                            width: (area.right - area.left) * Double(width), height: (area.bottom - area.top) * Double(height)))
        return context.makeImage()!
    }

    static func rgba(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Karenin RGBA pikselleri (sol üstten).
    static func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    static func digest(_ image: CGImage) -> String {
        let data = pixels(image)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "-\(image.width)x\(image.height)"
    }

    /// Piksel testi: beklenen altyazı kutusundaki yazı pikselleri (kutunun ortanca parlaklığından belirgin ayrılan
    /// pikseller: harfler ve gölgeleri) çizilen kutuyla ne oranda örtülüyor. `cover` karede, kenarlara oranla.
    static func coverage(of expected: TextBox, by cover: TextBox, in image: CGImage) -> Double {
        let width = image.width, height = image.height
        let data = pixels(image)
        func px(_ v: Double, _ n: Int) -> Int { max(0, min(n, Int((v * Double(n)).rounded()))) }
        let x0 = px(expected.left, width), x1 = px(expected.right, width)
        let y0 = px(expected.top, height), y1 = px(expected.bottom, height)
        guard x1 > x0, y1 > y0 else { return 0 }
        var luma: [Int] = []
        luma.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                luma.append((Int(data[i]) * 299 + Int(data[i + 1]) * 587 + Int(data[i + 2]) * 114) / 1000)
            }
        }
        let median = luma.sorted()[luma.count / 2]
        let cx0 = px(cover.left, width), cx1 = px(cover.right, width)
        let cy0 = px(cover.top, height), cy1 = px(cover.bottom, height)
        var text = 0, covered = 0, k = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                defer { k += 1 }
                guard abs(luma[k] - median) > 60 else { continue }
                text += 1
                if x >= cx0, x < cx1, y >= cy0, y < cy1 { covered += 1 }
            }
        }
        return text == 0 ? 0 : Double(covered) / Double(text)
    }
}

/// Yazının harf ve rakamları, küçük harfle; karşılaştırma için.
func normalized(_ text: String) -> String {
    String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
}

/// 0–1 benzerlik (düzenleme uzaklığına göre).
func similarity(_ a: String, _ b: String) -> Double {
    let x = Array(normalized(a)), y = Array(normalized(b))
    if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty ? 1 : 0 }
    var previous = Array(0...y.count)
    for i in 1...x.count {
        var current = [i] + Array(repeating: 0, count: y.count)
        for j in 1...y.count {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
        }
        previous = current
    }
    return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
}

/// `needle` (tabela yazısı) `haystack`'te geçiyor mu.
func mentions(_ haystack: String, _ needle: String) -> Bool {
    let n = normalized(needle)
    return !n.isEmpty && normalized(haystack).contains(n)
}

/// Konuşan adı ("Lucia: …") ayrılmış cümle.
func withoutSpeaker(_ text: String) -> String {
    SpeakerPrefix.split(text)?.body ?? text
}

/// Gerçek Apple Vision okuyucusu; aynı görüntü bir kez okunur (kare her turda yeniden okunuyor, sonuç aynı).
final class CachedReader: TextReader, @unchecked Sendable {
    let base: TextReader
    private var cache: [String: Reading] = [:]
    private let lock = NSLock()
    private(set) var reads = 0

    init(base: TextReader) { self.base = base }

    func read(_ image: CGImage) throws -> String { try readLines(image, deep: true).text }

    func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
        let key = Images.digest(image) + (deep ? "+" : "")
        if let hit = lock.withLock({ cache[key] }) { return hit }
        let reading = try base.readLines(image, deep: deep)
        lock.withLock {
            cache[key] = reading
            reads += 1
        }
        return reading
    }
}

/// Asıl okuyucu (bu süreçteki Vision) yavaş: yedek bağlamın dışındaki her okuma `delayMs` sürer (GitHub #822).
final class SlowPrimaryReader: TextReader, @unchecked Sendable {
    let base: TextReader
    let delayMs: Int

    init(base: TextReader, delayMs: Int) {
        self.base = base
        self.delayMs = delayMs
    }

    func read(_ image: CGImage) throws -> String { try readLines(image, deep: true).text }

    func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
        if ReadQueue.activeRescuer == nil { Thread.sleep(forTimeInterval: Double(delayMs) / 1000) }
        return try base.readLines(image, deep: deep)
    }
}

/// Bağımsız yedek okuyucunun yerine: aynı süreçte isabetli Vision (Mac'teki ayrı yardımcı sürecin okuduğu gibi).
final class InProcessRescuer: ReadRescuer, @unchecked Sendable {
    func recognize(_ image: CGImage, language: String) throws -> Reading {
        try VisionReader.recognize(image, language: language, fast: false)
    }

    func abandon() {}
    func standDown() {}
}
