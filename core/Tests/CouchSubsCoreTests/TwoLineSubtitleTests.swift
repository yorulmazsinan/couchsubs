// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore

#if canImport(CoreGraphics)
import CoreGraphics

/// GitHub #715: iki satırlı altyazının (üst satır 6-7 sözcük, alttaki devamı 1-2 sözcük, ortalanmış) yalnız ALT satırı
/// çevriliyordu. Alt satır üstten sonra belirince üst satır "uçta bekleyen görev satırı" sanılıp atılıyor
/// (`StickyRows.lingerMs`), ya da kısa satırın kutusu daha alçak olduğu için "yazı boyu farklı" denip ayrı blok sayılıyor,
/// en alttaki blok seçiliyordu. İki satır hep tek altyazı olmalı; görev satırı varken de
/// (Windows: TwoLineSubtitleTests.cs, Android: TwoLineSubtitleTest.kt).
private final class TwoLineReader: TextReader, @unchecked Sendable {
    var readings: [Reading]
    init(_ readings: [Reading]) { self.readings = readings }
    func read(_ image: CGImage) throws -> String { try readLines(image, deep: false).text }
    func readLines(_ image: CGImage, deep: Bool) throws -> Reading { readings.isEmpty ? Reading.empty : readings.removeFirst() }
}
private final class TwoLineSender: SubtitleSending {
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) {}
    func clear() {}
}
private final class TwoLineTranslator: TextTranslator {
    var requested: [String] = []
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        return "TR: " + text
    }
}

@MainActor
final class TwoLineSubtitleTests: XCTestCase {
    static let objective = "Go to the bank."
    static let subtitles: [[String]] = [
        ["Local junkies might find a car missing its", "catalytic converter."],
        ["I already told you we should leave right", "now."],
        ["You never listen to anything I say about", "money."],
        ["I already explained everything about the plan to", "Lucia."],
        ["We are going to need a much bigger", "boat, man."],
    ]
    static let line = 0.08

    static func row(_ text: String, _ top: Double, width: Double, height: Double = line) -> TextLine {
        TextLine(text, box: TextBox(left: 0.5 - width / 2, top: top, right: 0.5 + width / 2, bottom: top + height), confidence: 0.95)
    }

    /// 100 ms'de bir kare. Her altyazı 3 sn: üst satır hemen, alt satır `delay` ms sonra; alt satır dar ve kutusu daha alçak
    /// (0,7 kat). `objective`: görev altta (true), üstte (false) ya da yok (nil); görev altyazılardan 2 sn önce belirir.
    /// `typing`: üst satır da yazılır gibi büyür.
    static func frames(delay: Int, objective: Bool?, typing: Bool) -> [Reading] {
        var frames: [Reading] = []
        if let objective {
            frames += Array(repeating: Reading(lines: [row(Self.objective, objective ? 0.8 : 0.2, width: 0.3)]), count: 20)
        }
        for lines in subtitles {
            let top = objective == false ? 0.35 : 0.6
            for t in stride(from: 0, to: 3000, by: 100) {
                var rows: [TextLine] = []
                if objective == false { rows.append(row(Self.objective, 0.2, width: 0.3)) }
                var upper = lines[0]
                if typing { upper = String(upper.prefix(min(upper.count, 4 + upper.count * t / max(1, delay)))) }
                rows.append(row(upper, top, width: 0.6 * Double(upper.count) / Double(lines[0].count)))
                if t >= delay { rows.append(row(lines[1], top + line, width: 0.12, height: line * 0.7)) }
                if objective == true { rows.append(row(Self.objective, 0.8, width: 0.3)) }
                frames.append(Reading(lines: rows))
            }
            let between = objective.map { Reading(lines: [row(Self.objective, $0 ? 0.8 : 0.2, width: 0.3)]) } ?? .empty
            frames += Array(repeating: between, count: 3)
        }
        return frames
    }

    func run(delay: Int, objective: Bool?, typing: Bool = false) async {
        let frames = Self.frames(delay: delay, objective: objective, typing: typing)
        var time = 0
        let translator = TwoLineTranslator()
        let pipeline = SubtitlePipeline(reader: TwoLineReader(frames), translator: translator, server: TwoLineSender(), clock: { time })
        pipeline.packWait = 0; pipeline.cleanWait = 0
        let image = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        for _ in frames.indices {
            await pipeline.process(image, region: CropRegion(top: 0, bottom: 1, left: 0, right: 1))
            await pipeline.waitForTranslations()
            time += 100
        }
        let label = "delay: \(delay) objective: \(String(describing: objective)) typing: \(typing) — istekler: \(translator.requested)"
        for lines in Self.subtitles {
            XCTAssertTrue(translator.requested.contains { $0.contains(lines[0]) && $0.contains(lines[1]) },
                          "birlikte çevrilmedi: \(lines[0]) / \(lines[1]) — \(label)")
            XCTAssertFalse(translator.requested.contains { $0.trimmingCharacters(in: .whitespaces) == lines[1] },
                           "alt satır tek başına çevrildi: \(lines[1]) — \(label)")
        }
        XCTAssertFalse(translator.requested.contains { $0.contains("Go to the bank") && $0.trimmingCharacters(in: .whitespaces) != Self.objective },
                       "görev karıştı — \(label)")
    }

    func testTogetherNoObjective() async { await run(delay: 0, objective: nil) }
    func testLate300NoObjective() async { await run(delay: 300, objective: nil) }
    func testLate800NoObjective() async { await run(delay: 800, objective: nil) }
    func testLate1500NoObjective() async { await run(delay: 1500, objective: nil) }
    func testTyping1500NoObjective() async { await run(delay: 1500, objective: nil, typing: true) }
    func testTogetherObjectiveBelow() async { await run(delay: 0, objective: true) }
    func testLate800ObjectiveBelow() async { await run(delay: 800, objective: true) }
    func testLate1500ObjectiveBelow() async { await run(delay: 1500, objective: true) }
    func testTyping1500ObjectiveBelow() async { await run(delay: 1500, objective: true, typing: true) }
    func testLate800ObjectiveAbove() async { await run(delay: 800, objective: false) }
    func testLate1500ObjectiveAbove() async { await run(delay: 1500, objective: false) }
}
#endif
