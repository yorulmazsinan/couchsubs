// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import CouchSubsCore

private final class PackedReader: TextReader, @unchecked Sendable {
    var texts: [String]
    init(_ texts: [String]) { self.texts = texts }
    func read(_ image: CGImage) throws -> String { texts.isEmpty ? "" : texts.removeFirst() }
}
private final class PackedSender: SubtitleSending {
    var sent: [String] = []
    var clears = 0
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { sent.append(text) }
    func clear() { clears += 1 }
}
private final class PackedTranslator: TextTranslator {
    var requested: [String] = []
    var open = false
    var gates: [CheckedContinuation<Void, Never>] = []
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        if !open { await withCheckedContinuation { gates.append($0) } }
        return "TR: " + text
    }
    func release() { open = true; gates.forEach { $0.resume() }; gates.removeAll() }
}

@MainActor
final class PackedRereadTests: XCTestCase {
    private var image: CGImage {
        CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    func testPackOnlyShowsMatchesAndSkipsMissesWithoutWaiting() async {
        let first = "Let's get to the car.", miss = "This sign is not in the pack.", next = "We should go now."
        var time = 0
        let frames = [first, miss, next].flatMap { Array(repeating: $0, count: 4) }
        let translator = PackedTranslator(), sender = PackedSender()
        translator.release()
        let pipeline = SubtitlePipeline(reader: PackedReader(frames), translator: translator, server: sender,
                                        clock: { time }, packOnly: true)
        pipeline.packLookup = { source in
            [first: "Arabaya gidelim.", next: "Artık gitmeliyiz."][source].map { PackMatch(text: $0, spoken: []) }
        }
        var log: [String] = []
        pipeline.onLog = { log.append($0) }
        for (index, _) in frames.enumerated() {
            await pipeline.process(image, region: CropRegion())
            if index == 7 { XCTAssertEqual(sender.clears, 1) }
            time += 100
        }
        await pipeline.waitForTranslations()

        XCTAssertEqual(sender.sent, ["Arabaya gidelim.", "Artık gitmeliyiz."])
        XCTAssertTrue(translator.requested.isEmpty)
        XCTAssertTrue(log.contains { $0.contains("pakette yok, atlandı") })
        XCTAssertFalse(log.contains { $0.contains("bekletiliyor") })
    }

    func testPackOnlySettingDefaultsOffAndRoundTrips() throws {
        let decoder = JSONDecoder()
        var settings = try decoder.decode(UserSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.usesPackOnlySubtitles)
        settings.sourceLanguage = "en"
        settings.targetLanguage = "tr"
        settings.packOnlySubtitles = true
        let saved = try JSONEncoder().encode(settings)
        settings = try decoder.decode(UserSettings.self, from: saved)
        XCTAssertTrue(settings.usesPackOnlySubtitles)
        settings.gamePacks = false
        XCTAssertFalse(settings.usesPackOnlySubtitles)
    }
    func testRecordedFragmentsDoNotReplaceSlowFullTranslation() async {
        for (full, fragment) in [("I'm king of the world.", "world."),
            ("That he fucking passed out.", "passed"), ("Yo Jason, get in, get in!", "get in!")] {
            var time = 0
            let translator = PackedTranslator(), sender = PackedSender()
            let frames = Array(repeating: full, count: 4) + Array(repeating: fragment, count: 4)
            let pipeline = SubtitlePipeline(reader: PackedReader(frames), translator: translator, server: sender, clock: { time })
            pipeline.packLookup = { $0 == fragment ? PackMatch(text: "Paket parçası", spoken: []) : nil }
            pipeline.packWait = 0; pipeline.cleanWait = 0
            for _ in frames { await pipeline.process(image, region: CropRegion()); time += 100 }
            XCTAssertTrue(sender.sent.isEmpty, fragment)
            time += 3000
            translator.release()
            await pipeline.waitForTranslations()
            XCTAssertEqual(sender.sent, ["TR: " + full], fragment)
            XCTAssertEqual(translator.requested, [full], fragment)
        }
    }
    func testHeldFullLineKeepsOriginalDeadline() async {
        let full = "we are king of the world", fragment = "world"
        var time = 0
        let translator = PackedTranslator(), sender = PackedSender()
        translator.release()
        let frames = Array(repeating: full, count: 2) + Array(repeating: fragment, count: 6)
        let pipeline = SubtitlePipeline(reader: PackedReader(frames), translator: translator, server: sender, clock: { time })
        pipeline.packLookup = { $0 == fragment ? PackMatch(text: "Dünya", spoken: []) : nil }
        for (index, _) in frames.enumerated() {
            await pipeline.process(image, region: CropRegion()); await pipeline.waitForTranslations()
            if index == 4 { XCTAssertEqual(translator.requested, [full]) }
            time += 100
        }
        XCTAssertEqual(translator.requested, [full])
        XCTAssertEqual(sender.sent, ["TR: " + full])
    }

    func testGenuineShortLinesAndClearedRegionKeepImmediatePackPath() async {
        for (full, next, blank) in [("I swear to God, you kill me!", "You kill me!", false),
            ("I'm king of the world.", "world.", true),
            ("That he fucking passed out.", "Get down!", false),
            ("I have five bullets.", "I have one bullet.", false)] {
            var time = 0
            let translator = PackedTranslator(), sender = PackedSender()
            translator.release()
            let frames = Array(repeating: full, count: 4) + (blank ? Array(repeating: "", count: 12) : []) + Array(repeating: next, count: 4)
            let pipeline = SubtitlePipeline(reader: PackedReader(frames), translator: translator, server: sender, clock: { time })
            pipeline.packLookup = { $0 == next ? PackMatch(text: "Yeni replik", spoken: []) : nil }
            for (index, _) in frames.enumerated() {
                await pipeline.process(image, region: CropRegion()); await pipeline.waitForTranslations()
                if index == frames.count - 3 { XCTAssertTrue(sender.sent.contains("Yeni replik"), next) }
                time += 100
            }
            XCTAssertEqual(sender.sent.last, "Yeni replik", next)
            XCTAssertFalse(translator.requested.contains(next), next)
        }
    }

    /// Temiz ama yarım görünen satır bekletilirken gelen bozuk okumalı yeni satır yok sayılıyordu; kararlayıcı onu
    /// gönderilmiş saydığı için ekranda kaldığı sürece bir daha hiç çevrilmiyordu. Bekleme bitince o da çevrilmeli.
    func testMisreadLineArrivingDuringCleanHoldIsTranslatedLater() async {
        let held = "I told you to stay close", next = "Where is the bóat?"
        var time = 0
        let translator = PackedTranslator(), sender = PackedSender()
        translator.release()
        let frames = Array(repeating: held, count: 2) + Array(repeating: next, count: 20)
        let pipeline = SubtitlePipeline(reader: PackedReader(frames), translator: translator, server: sender, clock: { time })
        pipeline.packLookup = { _ in nil }
        for _ in frames {
            await pipeline.process(image, region: CropRegion()); await pipeline.waitForTranslations()
            time += 100
        }
        XCTAssertEqual(translator.requested, [held, next])
        XCTAssertEqual(sender.sent.last, "TR: " + next)
    }
}
#endif
