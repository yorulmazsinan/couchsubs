// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import CouchSubsCore

private final class GrowingReader: TextReader, @unchecked Sendable {
    var texts: [String]
    init(_ texts: [String]) { self.texts = texts }
    func read(_ image: CGImage) throws -> String { texts.isEmpty ? "" : texts.removeFirst() }
}
private final class GrowingSender: SubtitleSending {
    var sent: [String] = []
    var replaces: [Bool] = []
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) {
        sent.append(text)
        self.replaces.append(replaces)
    }
    func clear() {}
}
/// Çeviri "TR: " + harfleri ROT13 ile kaydırılmış kaynak (kaynağa benzemesin; "zaten hedef dilde" sayılmasın).
private final class GrowingTranslator: TextTranslator {
    var requested: [String] = []
    var open: Bool
    var gates: [CheckedContinuation<Void, Never>] = []
    init(blocked: Bool) { open = !blocked }
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        if !open { await withCheckedContinuation { gates.append($0) } }
        return "TR: " + GrowingLinesTests.rot13(text)
    }
    func release() { open = true; gates.forEach { $0.resume() }; gates.removeAll() }
}

/// Uzun altyazı satırları: aşama aşama beliren satır tek altyazıdır ve yerinde güncellenir, yazı tanıma farkıyla okunan
/// uzun satır motora bir kez gider, art arda iki farklı uzun satırın ikisi de gösterilir (beta-104, Mafia: The Old
/// Country). Ortak deneme dosyası Fixtures/growing-lines.json (Windows GrowingLinesTests.cs ve Android GrowingLinesTest.kt
/// aynı dosyayı okur).
@MainActor
final class GrowingLinesTests: XCTestCase {
    nonisolated static func rot13(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 97...122: return Character(UnicodeScalar((scalar.value - 97 + 13) % 26 + 97)!)
            case 65...90: return Character(UnicodeScalar((scalar.value - 65 + 13) % 26 + 65)!)
            default: return Character(scalar)
            }
        })
    }

    private var image: CGImage {
        CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func fixture() throws -> [[String: Any]] {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("growing-lines.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return root["cases"] as! [[String: Any]]
    }

    func testFixture() async throws {
        for item in try fixture() {
            let name = item["name"] as! String
            var reads: [String] = []
            for read in item["reads"] as! [[String: Any]] {
                reads += Array(repeating: read["text"] as! String, count: read["times"] as! Int)
            }
            let frameMs = item["frameMs"] as! Int
            let blocked = item["translator"] as! String == "blocked"
            var time = 0
            let translator = GrowingTranslator(blocked: blocked), sender = GrowingSender()
            var log: [String] = []
            let pipeline = SubtitlePipeline(reader: GrowingReader(reads), translator: translator, server: sender, clock: { time })
            pipeline.onLog = { log.append($0) }
            for _ in reads {
                await pipeline.process(image, region: CropRegion())
                if !blocked { await pipeline.waitForTranslations() }
                time += frameMs
            }
            translator.release()
            await pipeline.waitForTranslations()
            let shown = sender.sent.map { $0.hasPrefix("TR: ") ? Self.rot13(String($0.dropFirst(4))) : $0 }
            let trace = "\(name)\nmotor: \(translator.requested)\ngösterilen: \(shown)\nyerine: \(sender.replaces)\n"
                + log.joined(separator: "\n")
            let expect = item["expect"] as! [String: Any]
            if let calls = expect["engineCalls"] as? [String] { XCTAssertEqual(translator.requested, calls, trace) }
            if let max = expect["maxEngineCalls"] as? Int { XCTAssertLessThanOrEqual(translator.requested.count, max, trace) }
            if let expected = expect["shown"] as? [String] { XCTAssertEqual(shown, expected, trace) }
            XCTAssertEqual(sender.replaces.filter { !$0 }.count, expect["fresh"] as! Int, trace)
            XCTAssertEqual(shown.last, expect["last"] as? String, trace)
        }
    }

    func testLooseGrowth() {
        XCTAssertTrue(TextMatch.isLooseGrowth("Listen to me, Enz0. The Don wants you down at the docks", of: "Listen to me, Enzo. The Don wants you down"))
        XCTAssertTrue(TextMatch.isLooseGrowth("You think the farnily forgets what you did for us\nback in Sicily?",
                                              of: "You think the family forgets what you did for us"))
        XCTAssertFalse(TextMatch.isLooseGrowth("the docks before the sun comes up, Enzo.", of: "Listen to me, Enz0. The docks before the sun"))
        XCTAssertFalse(TextMatch.isLooseGrowth("Listen to me, Enzo. The Don wants you down", of: "Listen to me, Enzo. The Don wants you down"))
        XCTAssertFalse(TextMatch.isLooseGrowth("I don't know what you're talking about.", of: "I don't know what you want"))
    }

    func testJitter() {
        let long = "Listen to me, Enzo. The Don wants you down at the docks before\nthe sun comes up, and he wants it done quietly."
        XCTAssertTrue(TextMatch.isJitter(long + " Il", of: long))
        XCTAssertTrue(TextMatch.isJitter("Listen to me, Enz0. The Don wants y0u down at the docks before\nthe sun comes up, and he wants it done quietly.", of: long))
        XCTAssertTrue(TextMatch.isJitter("Listen to me, Enzo. The Don wants you down at the docks before\nthe sun comes up, and he wants it done", of: long))
        XCTAssertFalse(TextMatch.isJitter(long + " Go.", of: long))
        XCTAssertFalse(TextMatch.isJitter(long + " Then come home.", of: long))
        XCTAssertFalse(TextMatch.isJitter("Listen to me, Enzo. The Don doesn't want you down at the docks before\nthe sun comes up, and he wants it done quietly.", of: long))
        XCTAssertFalse(TextMatch.isJitter("Listen to me, Enzo. The Don wants you down at the docks before\nthe sun comes up, and he wants it done in 5.", of: long))
        XCTAssertFalse(TextMatch.isJitter("Listen to me, Enzo.", of: long))
    }

    /// Gecikme dökümü 30 sn'de bir tek satır: her aşama adıyla (#1349 biçimi).
    func testTimingLineNamesEveryStage() async {
        var time = 0
        let reads = Array(repeating: "Get in the car, Jason", count: 6) + ["", ""]
        var lines: [String] = []
        let pipeline = SubtitlePipeline(reader: GrowingReader(reads), translator: GrowingTranslator(blocked: false),
                                        server: GrowingSender(), clock: { time })
        pipeline.onTiming = { lines.append($0) }
        for index in reads.indices {
            await pipeline.process(image, region: CropRegion())
            await pipeline.waitForTranslations()
            time += index == reads.count - 2 ? StageTiming.periodMs : 200
        }
        XCTAssertEqual(lines.count, 1, "\(lines)")
        let line = lines.first ?? ""
        XCTAssertTrue(line.hasPrefix("altyazı aşama süreleri"), line)
        for stage in [SubtitlePipeline.stageFrameGap, SubtitlePipeline.stageOcr, SubtitlePipeline.stageSettle,
                      SubtitlePipeline.stageHold, SubtitlePipeline.stageQueue, SubtitlePipeline.stageEngine, SubtitlePipeline.stageTotal] {
            XCTAssertTrue(line.contains(stage + " "), "\(stage): \(line)")
        }
        // Satır 2. karede doğrulandı (ilk okumadan 200 ms sonra).
        XCTAssertTrue(line.contains("\(SubtitlePipeline.stageSettle) 1× ort 200,0"), line)
    }
}
#endif
