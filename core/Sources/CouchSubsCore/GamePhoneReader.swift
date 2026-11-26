// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

enum GamePhoneReader {
    /// Read the deskewed screen once. Keep its flat coordinates for grouping, and return real game coordinates for drawing.
    static func read(_ frame: CGImage, region: CropRegion, pose: GamePhoneGeometry.Pose, reader: any TextReader,
                     retry: GamePhoneRetry? = nil) throws -> Reading {
        let topX = pose.topX * Double(frame.width), topY = pose.topY * Double(frame.height)
        let dx = (pose.bottomX - pose.topX) * Double(frame.width), dy = (pose.bottomY - pose.topY) * Double(frame.height)
        guard dy > 0, dy.isFinite, dx.isFinite, topX.isFinite, topY.isFinite,
              region.right > region.left, region.bottom > region.top else { return .empty }
        func point(_ u: Double, _ v: Double) -> CGPoint {
            let t = 0.04 + 0.915 * v, side = (u - 0.5) * 0.52
            return CGPoint(x: topX + dx * t + side * dy,
                           y: topY + dy * t - side * dx * (0.52 + v * 0.30))
        }
        func rect(_ box: TextBox) -> CGRect {
            let a = point(box.left, box.top), b = point(box.right, box.top)
            let c = point(box.left, box.bottom), d = point(box.right, box.bottom)
            let x = min(a.x,b.x,c.x,d.x), y = min(a.y,b.y,c.y,d.y)
            return CGRect(x: x, y: y, width: max(a.x,b.x,c.x,d.x) - x, height: max(a.y,b.y,c.y,d.y) - y)
        }
        let whole = TextBox(left: 0, top: 0, right: 1, bottom: 1)
        guard let pixels = GamePhonePixels(frame, in: rect(whole).insetBy(dx: -2, dy: -2)) else { return .empty }
        let scale = min(dy * 0.5 < 300 ? 1.5 : 1, 960 / (dy * 0.9))
        let width = max(1, Int((dy * 0.5 * scale).rounded(.toNearestOrEven)))
        let height = max(1, Int((dy * 0.9 * scale).rounded(.toNearestOrEven)))
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: UInt8.self)
            pixels.bytes.withUnsafeBufferPointer { input in
                for y in 0..<height {
                    let v = (Double(y) + 0.5) / Double(height)
                    let left = point(0, v), right = point(1, v)
                    let stepX = (right.x - left.x) / Double(width), stepY = (right.y - left.y) / Double(width)
                    var sx = left.x + stepX * 0.5 - 0.5, sy = left.y + stepY * 0.5 - 0.5
                    for x in 0..<width {
                        let px = min(Double(pixels.width - 1), max(0, sx - Double(pixels.x)))
                        let py = min(Double(pixels.height - 1), max(0, sy - Double(pixels.y)))
                        let x0 = Int(px), y0 = Int(py), wx = Int((px - Double(x0)) * 256), wy = Int((py - Double(y0)) * 256)
                        let a = (y0 * pixels.width + x0) * 4, b = x0 + 1 < pixels.width ? a + 4 : a
                        let row = y0 + 1 < pixels.height ? pixels.width * 4 : 0, out = (y * width + x) * 4
                        for channel in 0..<3 {
                            let upper = Int(input[a+channel]) * (256-wx) + Int(input[b+channel]) * wx
                            let lower = Int(input[a+row+channel]) * (256-wx) + Int(input[b+row+channel]) * wx
                            output[out+channel] = UInt8((upper * (256-wy) + lower * wy + 32768) >> 16)
                        }
                        output[out+3] = 255
                        sx += stepX; sy += stepY
                    }
                }
            }
        }
        // Koyu ekran (koyu tema, gece, kısılmış ekran): gri, gerilmiş ve ters çevrilmiş okunur (`PhoneDarkScreen`).
        rgba = darkScreenPrepared(rgba)
        guard let provider = CGDataProvider(data: rgba as CFData),
              let flat = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                 space: frame.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return .empty }
        func map(_ box: TextBox) -> TextBox {
            let q = rect(box)
            func x(_ n: CGFloat) -> Double { min(1,max(0,(n / Double(frame.width) - region.left) / (region.right - region.left))) }
            func y(_ n: CGFloat) -> Double { min(1,max(0,(n / Double(frame.height) - region.top) / (region.bottom - region.top))) }
            return TextBox(left: x(q.minX), top: y(q.minY), right: x(q.maxX), bottom: y(q.maxY))
        }
        let reading = try readMessages(flat, rgba: rgba, width: width, height: height, reader: reader, retry: retry)
        return Reading(lines: reading.lines.map { original in
            var line = original
            line.phoneBox = original.box
            line.box = original.box.map(map)
            line.words = original.words?.map { TextWord($0.text, box: map($0.box)) }
            line.icons = original.icons?.map { IconSlot(box: map($0.box), text: $0.text, image: $0.image) }
            return line
        })
    }

    /// Bir balonun alt satırı okunup üstü kaybolabilir (soluk yazı). Aynı karede o satırın üstünde harf izi varsa yalnız o
    /// şeridin kontrastı artırılıp yeniden okunur; ikinci okuma aynı alt satırı aynı yerde bulursa eksik satır eklenir.
    /// Başarısız kurtarma aynı sohbette her turda yeniden OCR başlatmaz (2 sn). Windows (GamePhoneReader.ReadMessages) ile aynı.
    static func readMessages(_ flat: CGImage, rgba: Data, width: Int, height: Int, reader: any TextReader,
                             retry: GamePhoneRetry?) throws -> Reading {
        let reading = try reader.readLines(flat, deep: false)
        guard let retry, reading.lines.count >= 3,
              let tail = reading.lines.max(by: { ($0.box?.bottom ?? 0) < ($1.box?.bottom ?? 0) }),
              let b = tail.box, b.top > 0.65,
              tail.text.drop(while: \.isWhitespace).first?.isLowercase == true,
              tail.text.contains(where: \.isWhitespace) else { return reading }
        let h = b.bottom - b.top
        guard (tail.confidence ?? 0) >= 0.85, !retry.isWaiting(tail.text), h > 0, h <= 0.12,
              !reading.lines.contains(where: { $0 != tail && $0.box.map { isPrecedingLine($0, b) } == true })
        else { return reading }
        let top = max(0, Int(floor((b.top - 1.6 * h) * Double(height))))
        let end = min(height, Int(ceil((b.bottom + 0.35 * h) * Double(height))))
        guard end > top, hasTextEdges(rgba, width: width, height: height, tail: b, h: h) else { return reading }
        retry.failed(tail.text)
        let background = backgroundLevel(rgba, width: width, height: height, anchor: b)
        var band = Data(count: width * (end - top) * 4)
        band.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            rgba.withUnsafeBytes { inRaw in
                let input = inRaw.bindMemory(to: UInt8.self)
                for i in 0..<(width * (end - top)) {
                    let at = (top * width) * 4 + i * 4
                    let tone = UInt8(min(255, max(0, 160 + 6 * (luma(input, at) - background))))
                    out[i * 4] = tone; out[i * 4 + 1] = tone; out[i * 4 + 2] = tone; out[i * 4 + 3] = 255
                }
            }
        }
        guard let provider = CGDataProvider(data: band as CFData),
              let image = CGImage(width: width, height: end - top, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let again = try? reader.readLines(image, deep: false) else { return reading }
        let strip = TextBox(left: 0, top: Double(top) / Double(height), right: 1, bottom: Double(end) / Double(height))
        let key = TextMatch.normalize(tail.text)
        let confirms = again.lines.contains { line in
            guard let box = line.box else { return false }
            return TextMatch.normalize(line.text) == key && abs(box.placed(in: strip).top - b.top) < h * 0.5 && abs(box.left - b.left) < 0.08
        }
        guard confirms else { return reading }
        let missing = again.lines.filter { line in
            guard let box = line.box else { return false }
            return isPrecedingLine(box.placed(in: strip), b) && line.text.contains(where: \.isWhitespace)
                && line.text.filter(\.isLetter).count >= 4 && (line.confidence ?? 0) >= 0.94
        }.prefix(2)
        guard missing.count == 1, let found = missing.first, let foundBox = found.box?.placed(in: strip) else { return reading }
        // İlk okuma aynı satırın yalnız son sözcüklerini bulmuş olabilir: üstüne ikinci bir kutu konmaz.
        guard !reading.lines.contains(where: { $0 != tail && $0.box.map { sameRow($0, foundBox) } == true }) else { return reading }
        // Kurtarılan satır okumada zaten varsa (başka yerde okunmuş aynı yazı) ikinci kez eklenmez: balonda aynı cümle iki
        // kez görünüyordu (X, 22 Kas).
        let recoveredText = TextMatch.normalize(found.text)
        guard !reading.lines.contains(where: { line in
            PhoneSteady.sameReading(line.text, found.text) || TextMatch.normalize(line.text).contains(recoveredText)
        }) else { return reading }
        retry.succeeded()
        var recovered = found
        recovered.box = foundBox
        recovered.words = found.words?.map { TextWord($0.text, box: $0.box.placed(in: strip)) }
        recovered.icons = found.icons?.map { IconSlot(box: $0.box.placed(in: strip), text: $0.text, image: $0.image) }
        return Reading(lines: (reading.lines + [recovered]).sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) })
    }

    /// Düzeltilmiş ekranın (RGBA) koyu ekran hazırlığı (`PhoneDarkScreen`); gerekmiyorsa olduğu gibi.
    static func darkScreenPrepared(_ rgba: Data) -> Data {
        let bytes = [UInt8](rgba)
        var tones = [UInt8](repeating: 0, count: bytes.count / 4)
        for i in tones.indices {
            let r = 77 * Int(bytes[4 * i]), g = 150 * Int(bytes[4 * i + 1]), b = 29 * Int(bytes[4 * i + 2])
            tones[i] = UInt8((r + g + b) >> 8)
        }
        guard let map = PhoneDarkScreen.mapping(tones) else { return rgba }
        var out = [UInt8](repeating: 255, count: bytes.count)
        for (i, tone) in tones.enumerated() {
            let value = map[Int(tone)]
            out[4 * i] = value
            out[4 * i + 1] = value
            out[4 * i + 2] = value
        }
        return Data(out)
    }

    private static func sameRow(_ a: TextBox, _ b: TextBox) -> Bool {
        let overlap = min(a.bottom, b.bottom) - max(a.top, b.top)
        return min(a.right, b.right) > max(a.left, b.left) && overlap >= 0.5 * min(a.bottom - a.top, b.bottom - b.top)
    }

    private static func isPrecedingLine(_ a: TextBox, _ b: TextBox) -> Bool {
        let h = b.bottom - b.top, distance = (b.top + b.bottom - a.top - a.bottom) / 2
        return distance > h * 0.4 && distance < h * 1.55 && (abs(a.left - b.left) < 0.08 || abs(a.right - b.right) < 0.05)
    }

    private static func luma(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int { (Int(p[i]) + 2 * Int(p[i + 1]) + Int(p[i + 2])) / 4 }

    /// Balonun zemini: ortanca parlaklık (harfler ve kenar yumuşatma ölçümü bozmasın).
    private static func backgroundLevel(_ rgba: Data, width: Int, height: Int, anchor: TextBox) -> Int {
        var levels = [Int](repeating: 0, count: 256)
        let columns = 24, rows = 8
        rgba.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<rows {
                let v = anchor.top + (Double(y) + 0.5) / Double(rows) * (anchor.bottom - anchor.top)
                let row = min(height - 1, max(0, Int(v * Double(height)))) * width * 4
                for x in 0..<columns {
                    let u = anchor.left + (Double(x) + 0.5) / Double(columns) * (anchor.right - anchor.left)
                    let column = min(width - 1, max(0, Int(u * Double(width))))
                    levels[luma(p, row + column * 4)] += 1
                }
            }
        }
        var sum = 0
        for i in levels.indices {
            sum += levels[i]
            if sum >= columns * rows / 2 { return i }
        }
        return 0
    }

    /// Alt satırın üstünde soluk harf izi var mı: en az iki sırada birkaç parlaklık basamağı (tek çizgi yetmez).
    private static func hasTextEdges(_ rgba: Data, width: Int, height: Int, tail: TextBox, h: Double) -> Bool {
        let left = min(width - 1, max(0, Int(tail.left * Double(width))))
        let right = min(width - 1, max(left, Int(tail.right * Double(width))))
        return rgba.withUnsafeBytes { raw -> Bool in
            let p = raw.bindMemory(to: UInt8.self)
            var rows = 0
            for k in 0..<8 {
                let y = min(height - 1, max(0, Int((tail.top - h * (0.2 + Double(k) * 0.12)) * Double(height))))
                var at = y * width * 4 + left * 4, edges = 0, x = left
                while x + 3 < right {
                    if abs(luma(p, at + 12) - luma(p, at)) >= 3 { edges += 1; if edges >= 7 { break } }
                    x += 2; at += 8
                }
                if edges >= 7 { rows += 1; if rows >= 2 { return true } }
            }
            return false
        }
    }
}

/// Telefon oturumunun soluk satır kurtarma hafızası: başarısız denenen alt satır 2 sn yeniden denenmez.
final class GamePhoneRetry: @unchecked Sendable {
    private let lock = NSLock()
    private var failedTail: String?
    private var retryAfter = 0.0
    private let now: () -> Double

    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    func isWaiting(_ tail: String) -> Bool { lock.withLock { failedTail == tail && now() < retryAfter } }
    func failed(_ tail: String) { lock.withLock { failedTail = tail; retryAfter = now() + 2 } }
    func succeeded() { lock.withLock { failedTail = nil } }
}
