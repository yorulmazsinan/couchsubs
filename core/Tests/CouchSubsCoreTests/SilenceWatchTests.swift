// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Sessizlik bekçisi (Windows SilenceWatchTests ve Android SilenceWatchTest ile aynı örnekler). Vision kullanmaz.
final class SilenceWatchTests: XCTestCase {
    func testOnlySpeechLikeLinesCount() {
        for text in ["We should reach the lighthouse before dark.", "JASON: Get in the car", "Hey, look, we don't wanna get caught out here, man.",
                     "I need 5 more minutes, okay?"] {
            XCTAssertTrue(SilenceWatch.isSpeech(text), text)
        }
        for text in ["SETTINGS", "Search the camp for Donnie", "RETRY CHECKPOINT RESTART MISSION", "Okay.", "$1,250 in 3 days.",
                     "Collect the packages", "LUREPREDATOR / L35₽"] {
            XCTAssertFalse(SilenceWatch.isSpeech(text), text)
        }
    }

    func testFiresAfterTenSilentSecondsOncePerLineAndAtMostEveryTenSeconds() {
        var watch = SilenceWatch()
        let line = "We should reach the lighthouse before dark."
        XCTAssertNil(watch.due([line], at: 0))
        XCTAssertNil(watch.due([line], at: 9_900))
        XCTAssertEqual(watch.due([line], at: 10_000), line)
        watch.fired(line, at: 10_000)
        // Aynı satır bir daha gönderilmez.
        XCTAssertNil(watch.due([line], at: 20_000))
        let next = "Don't let him see you, stay low."
        XCTAssertNil(watch.due([next], at: 21_000))
        XCTAssertNil(watch.due([next], at: 30_000))
        XCTAssertEqual(watch.due([next], at: 31_000), next)
        watch.fired(next, at: 31_000)
        // Bir çeviri gönderildi: sessizlik yeniden başlar.
        watch.sent()
        let third = "Where the hell is Donnie now?"
        XCTAssertNil(watch.due([third], at: 32_000))
        XCTAssertNil(watch.due([third], at: 41_000))
        XCTAssertEqual(watch.due([third], at: 42_000), third)
        // Konuşma kesilirse süre baştan başlar.
        var gap = SilenceWatch()
        XCTAssertNil(gap.due([line], at: 0))
        XCTAssertNil(gap.due(["SETTINGS"], at: 5_000))
        XCTAssertNil(gap.due([line], at: 6_000))
        XCTAssertNil(gap.due([line], at: 15_000))
        XCTAssertEqual(gap.due([line], at: 16_000), line)
    }

    /// Uçtan uca: satır hiç gönderilemiyorsa (burada çevirmen her seferinde hata veriyor) bekçi 10 sn sonra satırı
    /// doğrudan çeviriye verir ve tutan aşamayı günlüğe yazar.
    @MainActor
    func testPipelineLogsTheHolderAndTranslatesTheLine() async throws {
        let line = "We should reach the lighthouse before dark."
        var now = 1_000_000
        let translator = Failing()
        let pipeline = SubtitlePipeline(reader: Fixed(line), translator: translator, server: Sent(), clock: { now })
        var log: [String] = []
        pipeline.onLog = { log.append($0) }
        let frame = try XCTUnwrap(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        for _ in 0..<120 {
            await pipeline.process(frame, region: CropRegion())
            await pipeline.waitForTranslations()
            now += 100
        }
        let fired = log.filter { $0.hasPrefix("bekçi:") }
        XCTAssertEqual(fired.count, 1, log.joined(separator: "\n"))
        XCTAssertTrue(fired[0].contains("tutan: kararlayıcı"), fired[0])
        XCTAssertTrue(translator.requested.contains(line))
    }

    private final class Fixed: TextReader, @unchecked Sendable {
        let text: String
        init(_ text: String) { self.text = text }
        func read(_ image: CGImage) throws -> String { text }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading { Reading(text: text) }
    }

    private final class Failing: TextTranslator, @unchecked Sendable {
        var requested: [String] = []
        func translate(_ text: String) async throws -> String {
            requested.append(text)
            throw URLError(.notConnectedToInternet)
        }
    }

    private final class Sent: SubtitleSending {
        func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) {}
        func clear() {}
    }
}
