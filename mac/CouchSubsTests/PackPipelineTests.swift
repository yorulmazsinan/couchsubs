// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CouchSubsCore
import XCTest
@testable import CouchSubs

private final class QueueReader: TextReader, @unchecked Sendable {
    var texts: [String]
    init(_ texts: [String]) { self.texts = texts }
    func read(_ image: CGImage) throws -> String { texts.isEmpty ? "" : texts.removeFirst() }
}

private final class CountingTranslator: TextTranslator {
    private(set) var requested: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    var holds = false
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        if holds { await withCheckedContinuation { gate = $0 } }
        return "TR: " + text
    }
    func open() async {
        holds = false
        while gate == nil { await Task.yield() }
        gate?.resume()
        gate = nil
    }
}

private final class RecordingSender: SubtitleSending {
    var sent: [String] = []
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { sent.append(text) }
    func clear() {}
}

/// Oyun paketindeki satır çeviri motoruna gitmeden gösterilir (Windows: PackPipelineTests).
@MainActor
final class PackPipelineTests: XCTestCase {
    private let frame: CGImage = {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    private static func lookup(_ text: String) -> PackMatch? {
        PackKey.canon(text) == "get down"
            ? PackMatch(text: "Yere yat!", spoken: [SpokenLine(english: "Get down!", turkish: "Yere yat!")]) : nil
    }

    private func run(_ pipeline: SubtitlePipeline, _ frames: Int) async {
        for _ in 0..<frames {
            await pipeline.process(frame, region: CropRegion())
            await pipeline.waitForTranslations()
        }
    }

    func testPackHitSkipsTheEngine() async {
        let sender = RecordingSender()
        let translator = CountingTranslator()
        let pipeline = SubtitlePipeline(reader: QueueReader(["Get down!", "Get down!", "Get down!"]), translator: translator, server: sender)
        pipeline.packLookup = Self.lookup
        var shown: [String] = []
        var spoken: [[SpokenLine]] = []
        var missed: [String] = []
        pipeline.onPair = { _, translation in shown.append(translation) }
        pipeline.onSpeech = { spoken.append($0) }
        pipeline.onPackMiss = { missed.append($0) }
        await run(pipeline, 3)
        XCTAssertEqual(sender.sent, ["Yere yat!"])
        XCTAssertEqual(translator.requested, [])
        XCTAssertEqual(shown, ["Yere yat!"])
        XCTAssertEqual(spoken.first?.map(\.turkish), ["Yere yat!"])
        XCTAssertEqual(missed, [])
        XCTAssertEqual(pipeline.lastOrigin, "paket")
        XCTAssertEqual(pipeline.packHits, 1)
    }

    func testPackMissUsesTheEngineAndIsReported() async {
        let sender = RecordingSender()
        let translator = CountingTranslator()
        let pipeline = SubtitlePipeline(reader: QueueReader(["Hold the gate", "Hold the gate"]), translator: translator, server: sender)
        pipeline.packLookup = Self.lookup
        var missed: [String] = []
        pipeline.onPackMiss = { missed.append($0) }
        await run(pipeline, 2)
        XCTAssertEqual(sender.sent, ["TR: Hold the gate"])
        XCTAssertEqual(translator.requested, ["Hold the gate"])
        XCTAssertEqual(missed, ["Hold the gate"])
        XCTAssertEqual(pipeline.lastOrigin, "motor")
    }

    /// Paket kapalıyken her satır motora gider ve havuz için bildirilir.
    func testWithoutPacksEveryLineGoesToTheEngine() async {
        let sender = RecordingSender()
        let pipeline = SubtitlePipeline(reader: QueueReader(["Get down!", "Get down!"]), translator: CountingTranslator(), server: sender)
        var missed: [String] = []
        pipeline.onPackMiss = { missed.append($0) }
        await run(pipeline, 2)
        XCTAssertEqual(sender.sent, ["TR: Get down!"])
        XCTAssertEqual(missed, ["Get down!"])
    }

    /// Önceki satırın çevirisi sürerken gelen paket satırı beklemeden gösterilir; geç gelen eski çeviri üstüne yazmaz.
    func testPackLineDoesNotWaitForASlowTranslation() async {
        let sender = RecordingSender()
        let translator = CountingTranslator()
        translator.holds = true
        let pipeline = SubtitlePipeline(reader: QueueReader(["Hold the gate", "Hold the gate", "Get down!", "Get down!"]),
                                        translator: translator, server: sender)
        pipeline.packLookup = Self.lookup
        for _ in 0..<4 { await pipeline.process(frame, region: CropRegion()) }
        XCTAssertEqual(sender.sent, ["Yere yat!"])
        await translator.open()
        await pipeline.waitForTranslations()
        XCTAssertEqual(sender.sent, ["Yere yat!"])
    }
}
