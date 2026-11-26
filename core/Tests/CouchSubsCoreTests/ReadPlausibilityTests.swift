// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Yazı tanımanın bozduğu satır çeviri motoruna gitmez (GitHub #1293). Windows: ReadPlausibilityTests.cs, Android:
/// ReadPlausibilityTest.kt; üçü de read-plausibility.json'u okur.
final class ReadPlausibilityTests: XCTestCase {
    private struct Vectors: Decodable {
        let garbled: [String]
        let kept: [String]
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(name))
    }

    func testSharedVectors() throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: fixture("read-plausibility.json"))
        for text in vectors.garbled { XCTAssertNotNil(ReadPlausibility.reason(text), text) }
        for text in vectors.kept { XCTAssertNil(ReadPlausibility.reason(text), text) }
    }

    /// Var olan sahne yazısı, altyazı ve telefon fixture'larındaki satırların hiçbiri bozuk sayılmaz.
    func testExistingSubtitleFixturesAreKept() throws {
        for name in ["scene-text.json", "growing-lines.json", "settled-text.json", "phone-chat.json"] {
            var texts: [String] = []
            func walk(_ value: Any, key: String?) {
                if let text = value as? String, key == "text" { texts.append(text) }
                if let list = value as? [Any] { list.forEach { walk($0, key: key) } }
                if let map = value as? [String: Any] { map.forEach { walk($0.value, key: $0.key) } }
            }
            walk(try JSONSerialization.jsonObject(with: fixture(name)), key: nil)
            XCTAssertFalse(texts.isEmpty, name)
            for text in texts { XCTAssertNil(ReadPlausibility.reason(text), "\(name): \(text)") }
        }
    }

    func testLogIsRateLimited() {
        var time = 0
        let log = ReadPlausibility.Log(clock: { time })
        XCTAssertEqual(log.line("es aepressea\narter", reason: "r"),
                       "okuma bozuk görünüyor, çeviriye gönderilmedi: «es aepressea / arter» (r)")
        XCTAssertNil(log.line("es aepressea\narter", reason: "r"))
        for index in 0..<(ReadPlausibility.Log.perMinute - 1) { XCTAssertNotNil(log.line("satır \(index)", reason: "r")) }
        XCTAssertNil(log.line("bir satır daha", reason: "r"))
        time += ReadPlausibility.Log.repeatMs
        XCTAssertEqual(log.line("es aepressea\narter", reason: "r"),
                       "okuma bozuk görünüyor, çeviriye gönderilmedi: «es aepressea / arter» (r) (+1 satır sınır yüzünden yazılmadı)")
    }
}

#if canImport(CoreGraphics)
private final class ScriptedReader: TextReader, @unchecked Sendable {
    var text = ""
    func read(_ image: CGImage) throws -> String { text }
    func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
        text.isEmpty ? .empty : Reading(lines: [TextLine(text, box: TextBox(left: 0.2, top: 0.4, right: 0.8, bottom: 0.6))])
    }
}

private final class RecordingScreen: SubtitleSending, @unchecked Sendable {
    var sent: [String] = []
    var clears = 0
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { sent.append(text) }
    func clear() { clears += 1 }
}

private final class RecordingTranslator: TextTranslator, @unchecked Sendable {
    var calls: [String] = []
    func translate(_ text: String) async throws -> String {
        calls.append(text)
        return "Çeviri: " + text
    }
}

@MainActor
final class ReadPlausibilityPipelineTests: XCTestCase {
    private func frame(_ shade: Int) -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: CGFloat(shade % 7) / 7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }

    /// Bozuk okuma motora gitmez, önceki altyazı ekranda kalır; aynı satır düzgün okununca çevrilir. Günlüğe bir kez yazılır.
    func testGarbledReadIsNotTranslatedAndThePreviousSubtitleStays() async {
        var time = 0
        let reader = ScriptedReader(), screen = RecordingScreen(), translator = RecordingTranslator()
        let pipeline = SubtitlePipeline(reader: reader, translator: translator, server: screen, clock: { time })
        var logs: [String] = []
        pipeline.onLog = { logs.append($0) }
        var shade = 0
        func run(_ text: String, frames: Int) async {
            reader.text = text
            for _ in 0..<frames {
                shade += 1
                await pipeline.process(frame(shade), region: CropRegion())
                await pipeline.waitForTranslations()
                time += 250
            }
        }
        await run("Get in the car, now.", frames: 4)
        XCTAssertEqual(translator.calls, ["Get in the car, now."])
        await run("es aepressea arter Donnıas aeatIT", frames: 16)
        XCTAssertEqual(translator.calls, ["Get in the car, now."], logs.joined(separator: "\n"))
        XCTAssertEqual(screen.clears, 0, logs.joined(separator: "\n"))
        XCTAssertEqual(logs.filter { $0.hasPrefix("okuma bozuk görünüyor, çeviriye gönderilmedi: «es aepressea arter Donnıas aeatIT»") }.count,
                       1, logs.joined(separator: "\n"))
        await run("He's depressed after Donna's death.", frames: 4)
        XCTAssertEqual(translator.calls, ["Get in the car, now.", "He's depressed after Donna's death."], logs.joined(separator: "\n"))
    }
}
#endif
