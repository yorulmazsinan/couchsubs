// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import CouchSubsCore

private final class LateReader: TextReader, @unchecked Sendable {
    var texts: [String]
    init(_ texts: [String]) { self.texts = texts }
    func read(_ image: CGImage) throws -> String { texts.isEmpty ? "" : texts.removeFirst() }
}
private final class LateSender: SubtitleSending {
    var sent: [(text: String, replaces: Bool)] = []
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { sent.append((text, replaces)) }
    func clear() {}
}
private final class LateTranslator: TextTranslator {
    var requested: [String] = []
    var open = true
    var gates: [CheckedContinuation<Void, Never>] = []
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        if !open { await withCheckedContinuation { gates.append($0) } }
        return "Çeviri \(requested.count)."
    }
    func release() { open = true; gates.forEach { $0.resume() }; gates.removeAll() }
}

/// X'te iki kişi: diyalogda her altyazı iki kez çıkıyor, önce beyaz (adsız), sonra adıyla renkli. Renkli konuşan adı ilk
/// karelerde okunamıyor, cümle adsız çevrilip gösteriliyor; ad okununca aynı cümle yeni satır sayılıp yeniden çevriliyordu.
@MainActor
final class SpeakerReadLateTests: XCTestCase {
    private var image: CGImage {
        CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func replay(_ frames: [String], translator: LateTranslator = LateTranslator(), showNames: Bool = true,
                        afterFirst: (() -> Void)? = nil) async -> LateSender {
        var time = 0
        let sender = LateSender()
        let pipeline = SubtitlePipeline(reader: LateReader(frames), translator: translator, server: sender, clock: { time })
        pipeline.holdReadings = false
        pipeline.showSpeakerNames = showNames
        for index in frames.indices {
            await pipeline.process(image, region: CropRegion())
            if translator.open { await pipeline.waitForTranslations() }
            if index == 0 {
                for _ in 0..<1000 where translator.requested.isEmpty { await Task.yield() }
            }
            time += 150
        }
        translator.release()
        await pipeline.waitForTranslations()
        return sender
    }

    func testNameReadLaterUpdatesTheShownLineWithoutTranslatingAgain() async {
        for sentence in ["We need to go now.", "Come on.", "Jus- Just be quiet. Donnie's up.", "You know what I mean, right?"] {
            let translator = LateTranslator()
            let sender = await replay([sentence, "JASON: " + sentence, "JASON: " + sentence], translator: translator)
            XCTAssertEqual(translator.requested, [sentence], sentence)
            XCTAssertEqual(sender.sent.map(\.text), ["Çeviri 1.", "JASON: Çeviri 1."], sentence)
            XCTAssertEqual(sender.sent.map(\.replaces), [false, true], sentence)
        }
    }

    func testNameOnItsOwnRowIsTheSameLine() async {
        let translator = LateTranslator()
        let sender = await replay(["What the hell was that?", "JASON:\nWhat the hell was that?"], translator: translator)
        XCTAssertEqual(translator.requested, ["What the hell was that?"])
        XCTAssertEqual(sender.sent.map(\.text), ["Çeviri 1.", "JASON: Çeviri 1."])
        XCTAssertEqual(sender.sent.last?.replaces, true)
    }

    func testNameReadWhileTranslatingShowsOnlyTheNamedLine() async {
        let translator = LateTranslator()
        translator.open = false
        let sender = await replay(["We need to go now.", "JASON: We need to go now.", "JASON: We need to go now."],
                                  translator: translator)
        XCTAssertEqual(translator.requested, ["We need to go now."])
        XCTAssertEqual(sender.sent.map(\.text), ["JASON: Çeviri 1."])
    }

    func testFlickeringNameIsOneLine() async {
        let translator = LateTranslator()
        let sender = await replay(["Come on.", "JASON: Come on.", "Come on.", "JASON: Come on.", "Come on."], translator: translator)
        XCTAssertEqual(translator.requested, ["Come on."])
        XCTAssertEqual(sender.sent.map(\.text), ["Çeviri 1.", "JASON: Çeviri 1."])

        let named = LateTranslator()
        let first = await replay(["JASON: Come on.", "Come on.", "JASON: Come on.", "Come on."], translator: named)
        XCTAssertEqual(named.requested, ["Come on."])
        XCTAssertEqual(first.sent.map(\.text), ["JASON: Çeviri 1."])
    }

    func testNamesHiddenSendsNothingNew() async {
        let translator = LateTranslator()
        let sender = await replay(["We need to go now.", "JASON: We need to go now."], translator: translator, showNames: false)
        XCTAssertEqual(translator.requested, ["We need to go now."])
        XCTAssertEqual(sender.sent.map(\.text), ["Çeviri 1."])
    }

    func testDifferentSentenceWithNameIsStillANewLine() async {
        let translator = LateTranslator()
        let sender = await replay(["We need to go now.", "JASON: We don't need to go now."], translator: translator)
        XCTAssertEqual(translator.requested, ["We need to go now.", "We don't need to go now."])
        XCTAssertEqual(sender.sent.count, 2)

        let other = LateTranslator()
        _ = await replay(["We need to go now.", "LUCIA: Where are we going?"], translator: other)
        XCTAssertEqual(other.requested, ["We need to go now.", "Where are we going?"])
    }

    func testStabilizerTreatsUnnamedRereadOfNamedLineAsSame() {
        XCTAssertTrue(SubtitleStabilizer.isUnnamedReread("Come on.", of: "JASON: Come on."))
        XCTAssertTrue(SubtitleStabilizer.isUnnamedReread("What the hell was that?", of: "Jason:\nWhat the hell was that?"))
        XCTAssertFalse(SubtitleStabilizer.isUnnamedReread("Come on.", of: "Come on."))
        XCTAssertFalse(SubtitleStabilizer.isUnnamedReread("LUCIA: Come on.", of: "JASON: Come on."))
        XCTAssertFalse(SubtitleStabilizer.isUnnamedReread("Go home.", of: "JASON: Come on."))
    }
}
#endif
