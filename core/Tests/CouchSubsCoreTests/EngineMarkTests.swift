// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import CouchSubsCore

private final class MarkReader: TextReader, @unchecked Sendable {
    var texts: [String]
    init(_ texts: [String]) { self.texts = texts }
    func read(_ image: CGImage) throws -> String { texts.isEmpty ? "" : texts.removeFirst() }
}
private final class MarkSender: SubtitleSending {
    var sent: [String] = []
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { sent.append(text) }
    func clear() {}
}
private final class MarkTranslator: TextTranslator {
    func translate(_ text: String) async throws -> String { "TR: " + text }
}

/// "Yerel modelin çevirdiği satırların başına nokta koy": işaret yalnız motorun çevirdiği satıra konur, paketteki satıra
/// konmaz (Windows: SubtitlePipelineTests.EngineMarkGoesOnlyBeforeEngineLines).
@MainActor
final class EngineMarkTests: XCTestCase {
    private var image: CGImage {
        CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func run(_ line: String, mark: String?, pack: String? = nil) async -> [String] {
        var time = 0
        let sender = MarkSender()
        let pipeline = SubtitlePipeline(reader: MarkReader(Array(repeating: line, count: 4)), translator: MarkTranslator(),
                                        server: sender, clock: { time })
        pipeline.engineMark = mark
        if let pack { pipeline.packLookup = { $0 == line ? PackMatch(text: pack, spoken: []) : nil } }
        pipeline.packWait = 0; pipeline.cleanWait = 0; pipeline.holdReadings = true
        for _ in 0..<4 {
            await pipeline.process(image, region: CropRegion())
            await pipeline.waitForTranslations()
            time += 100
        }
        return sender.sent
    }

    func testMarkGoesBeforeEngineLines() async {
        let sent = await run("Hold the gate.", mark: SubtitlePipeline.localAIMark)
        XCTAssertEqual(sent, [". TR: Hold the gate."])
    }

    func testPackLinesAreNotMarked() async {
        let sent = await run("Get in the car.", mark: SubtitlePipeline.localAIMark, pack: "Arabaya bin.")
        XCTAssertEqual(sent, ["Arabaya bin."])
    }

    func testNoMarkWhenTheOptionIsOff() async {
        let sent = await run("Hold the gate.", mark: nil)
        XCTAssertEqual(sent, ["TR: Hold the gate."])
    }
}
#endif
