// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CouchSubsCore

/// Gerçek oyun kareleriyle uçtan uca doğrulama (yalnız yerel): kare → dedektör → Vision OCR → sözlük/sahte çevirmen →
/// stil → TV'ye giden olaylar. `COUCHSUBS_REAL_FRAMES` bir dizin verirse koşar (içinde `kareler/K*.png`); yoksa atlanır.
/// Olaylar `<dizin>/cikti/mac/K*.json`'a yazılır (TV çizimiyle bakmak için). Kareler ve çıktılar depoya girmez.
@MainActor
final class RealFrameTests: XCTestCase {
    /// Gerçek motor yerine: "⟨TR⟩" önekli çeviri; toplu istekleri sayar.
    private final class Marked: TextTranslator {
        var requests = 0
        var texts: [String] = []
        var translatesTogether: Bool { true }
        func translate(_ text: String) async throws -> String {
            requests += 1
            texts.append(text)
            return Self.mark(text)
        }
        /// "⟨TR⟩" önekli ROT13: aslına benzemesin (benzer çeviri gösterilmiyor), uzunluğu korunsun.
        static func mark(_ text: String) -> String {
            "⟨TR⟩ " + String(text.unicodeScalars.map { scalar -> Character in
                let v = scalar.value
                if (65...90).contains(v) { return Character(UnicodeScalar((v - 65 + 13) % 26 + 65)!) }
                if (97...122).contains(v) { return Character(UnicodeScalar((v - 97 + 13) % 26 + 97)!) }
                return Character(scalar)
            })
        }
        func translateAll(_ texts: [String]) async throws -> [String] {
            requests += 1
            self.texts += texts
            return texts.map(Self.mark)
        }
    }

    /// TV'ye giden `region` olaylarını sunucunun JSON biçimiyle kaydeder.
    private final class Recorder: RegionSending {
        var events: [[String: Any]] = []
        var sends = 0
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: nil, blocks: nil)
        }
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                        blocks: [ScreenTranslation.Item]?) {
            sends += 1
            var json: [String: Any] = ["id": id, "text": text]
            if let blocks, !blocks.isEmpty, !text.isEmpty { json["blocks"] = blocks.map { SubtitleServer.json($0) } }
            if let box { json["box"] = SubtitleServer.json(box) }
            if let lineHeight { json["line"] = lineHeight }
            events.append(["event": "region", "data": json])
        }
        func clearRegions() { events.append(["event": "region-clear", "data": [String: Any]()]) }
    }

    private static var directory: URL? {
        ProcessInfo.processInfo.environment["COUCHSUBS_REAL_FRAMES"].map { URL(fileURLWithPath: $0) }
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Kareye küçük gürültü (arka plan kıpırtısı): her pikselin parlaklığı ±2 oynar.
    static func jitter(_ image: CGImage, seed: Int) -> CGImage {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if seed > 0 {
            var generator = ScreenTextDetectorTests.SplitMix(seed: UInt64(seed))
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let delta = Int(generator.next() % 5) - 2
                for c in 0..<3 { pixels[i + c] = UInt8(max(0, min(255, Int(pixels[i + c]) + delta))) }
            }
        }
        return ScreenTextDetectorTests.image(pixels, width: width, height: height)
    }

    struct Outcome {
        var areas: [ExtraArea]
        var events: [[String: Any]]
        var requests: Int
        var sends: Int
        var texts: [String]
        var log: [String] = []
    }

    /// Kareyi hattan geçirir: dedektör 1 sn (10 örnek), sonra her örnekte RegionWatcher turu.
    static func run(_ frames: [CGImage], excluded: [CropRegion] = []) async -> Outcome {
        let detector = ScreenTextDetector()
        let translator = Marked(), recorder = Recorder()
        let watcher = RegionWatcher(reader: VisionReader(language: "en"), translator: translator, server: recorder)
        watcher.translatesUiCommands = true
        var log: [String] = []
        watcher.onAutoRejected = { log.append("ret \($0)"); detector.reject($0) }
        watcher.onLog = { log.append($0) }
        var time = 0
        var last: [ExtraArea] = []
        for frame in frames {
            detector.sample(frame, now: time, excluded: excluded)
            last = detector.areas
            log.append("t\(time) alanlar: " + last.map { "\($0.id)\($0.menu ? "M" : "") [\(String(format: "%.2f-%.2f x %.2f-%.2f", $0.region.left, $0.region.right, $0.region.top, $0.region.bottom))]" }.joined(separator: ", "))
            if time >= ScreenTextDetector.stableMs { await watcher.pass(frame, areas: last) }
            time += ScreenTextDetector.sampleIntervalMs
        }
        return Outcome(areas: last, events: recorder.events, requests: translator.requests, sends: recorder.sends,
                       texts: translator.texts, log: log)
    }

    /// Tanı: bir karenin bütününü Vision ile okuyup otomatik alan adayının satırlarını yazar.
    func testRealFrameCandidates() async throws {
        guard let directory = Self.directory else { throw XCTSkip("COUCHSUBS_REAL_FRAMES verilmedi") }
        var out: [String] = []
        for name in ["K1", "K2", "K3", "K4"] {
            guard let image = Self.load(directory.appendingPathComponent("kareler/\(name).png")) else { continue }
            let reading = try VisionReader(language: "en").readLines(image, deep: false)
            out.append("\(name) OCR: " + reading.lines.map { "\($0.text) [\(String(format: "%.2f", $0.confidence ?? -1))]" }.joined(separator: " | "))
            let candidate = RegionWatcher.candidate(reading, in: CropRegion(top: 0, bottom: 1, left: 0, right: 1), frame: image,
                                                    auto: true)
            out.append("\(name) aday: " + candidate.paragraphs.joined(separator: " | "))
        }
        try out.joined(separator: "\n").write(to: directory.appendingPathComponent("cikti/mac/aday.txt"), atomically: true, encoding: .utf8)
    }

    func testRealFrames() async throws {
        guard let directory = Self.directory else { throw XCTSkip("COUCHSUBS_REAL_FRAMES verilmedi") }
        let output = directory.appendingPathComponent("cikti/mac")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report: [String] = []
        for name in ["K1", "K2", "K3", "K4", "K5"] {
            guard let image = Self.load(directory.appendingPathComponent("kareler/\(name).png")) else { continue }
            // K5 altyazı karesi: altyazı alanı (varsayılan alt bölge) dışlanır, gerçek kullanımdaki gibi.
            let excluded = name == "K5" ? [CropRegion()] : []
            let frames = (0..<20).map { Self.jitter(image, seed: $0) }
            let outcome = await Self.run(frames, excluded: excluded)
            let data = try JSONSerialization.data(withJSONObject: outcome.events, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("\(name).json"))
            try outcome.log.joined(separator: "\n").write(to: output.appendingPathComponent("\(name).log"), atomically: true, encoding: .utf8)
            let shown = outcome.events.compactMap { ($0["data"] as? [String: Any])?["text"] as? String }.filter { !$0.isEmpty }
            report.append("\(name): alan \(outcome.areas.count), gönderim \(outcome.sends), istek \(outcome.requests), "
                          + "motora \(outcome.texts.count) metin\n  " + shown.joined(separator: "\n  "))
        }
        try report.joined(separator: "\n").write(to: output.appendingPathComponent("rapor.txt"), atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
    }
}
