// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore

#if canImport(CoreGraphics)
import CoreGraphics

/// Görev satırı altyazıdan ayrı, kendi yerinde (spec bölüm 5; Windows MissionLineTests.cs ile aynı): alt ortada görev
/// satırı + değişen altyazı. Görev hiçbir altyazıya girmez, bölgesi bir kez bildirilir (yanıp sönmez), görev kalkınca
/// bölge de kalkar.
@MainActor
final class MissionLineTests: XCTestCase {
    private final class Reader: TextReader, @unchecked Sendable {
        var readings: [Reading]
        init(_ readings: [Reading]) { self.readings = readings }
        func read(_ image: CGImage) throws -> String { try readLines(image, deep: false).text }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading { readings.isEmpty ? .empty : readings.removeFirst() }
    }
    private final class Sender: SubtitleSending {
        func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) {}
        func clear() {}
    }
    private final class Translator: TextTranslator {
        var requested: [String] = []
        func translate(_ text: String) async throws -> String {
            requested.append(text)
            return "TR: " + text
        }
    }

    private func run(_ frames: [Reading]) async -> (regions: [CropRegion?], requested: [String]) {
        var time = 0
        let translator = Translator()
        let pipeline = SubtitlePipeline(reader: Reader(frames), translator: translator, server: Sender(), clock: { time })
        pipeline.packWait = 0
        pipeline.cleanWait = 0
        var regions: [CropRegion?] = []
        pipeline.onMissionChanged = { regions.append($0) }
        let image = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        for _ in frames.indices {
            await pipeline.process(image, region: CropRegion(top: 0, bottom: 1, left: 0, right: 1))
            await pipeline.waitForTranslations()
            time += 500
        }
        return (regions, translator.requested)
    }

    func testObjectiveGetsItsOwnAreaOnceWhileDialogueChanges() async throws {
        for (below, gap, first) in [(true, 0.1, 4), (true, 1.5, 4), (false, 0.1, 4), (true, 0.1, 20)] {
            let label = "below: \(below) gap: \(gap) first: \(first)"
            let (regions, requested) = await run(ObjectiveWithDialogueTests.frames(below: below, gap: gap, objectiveFirst: first))
            // Görevin bölgesi bir kez bildirildi; altyazı beş kez değişse de değişmedi.
            let found = regions.compactMap { $0 }
            XCTAssertEqual(found.count, 1, label)
            let region = try XCTUnwrap(found.first, label)
            XCTAssertTrue(region.top <= (below ? 0.8 : 0.2) && region.bottom >= (below ? 0.88 : 0.28), "\(label) \(region)")
            // Görev bir altyazı isteğine karışmadı.
            XCTAssertFalse(requested.contains { $0.contains("Go to the bank") && $0.trimmingCharacters(in: .whitespaces) != "Go to the bank." }, label)
        }
    }

    func testObjectiveLeavingRemovesItsArea() async {
        let frames = ObjectiveWithDialogueTests.frames(below: true, gap: 1.5, objectiveFirst: 4) + Array(repeating: .empty, count: 6)
        let (regions, _) = await run(frames)
        XCTAssertNotNil(regions.first ?? nil)
        XCTAssertNil(regions.last ?? CropRegion())
    }

    func testSpokenLinesAreNeverAMission() {
        var mission = MissionLine()
        let area = TextBox(left: 0, top: 0, right: 1, bottom: 1)
        for time in stride(from: 0, through: 4000, by: 500) {
            _ = mission.observe([TextLine("Lucia: Wait here.", box: TextBox(left: 0.3, top: 0.8, right: 0.7, bottom: 0.88))],
                                area: area, at: time)
        }
        XCTAssertNil(mission.region)
    }

    /// Görev ilk altyazıyla aynı anda: aradaki boşluk satırın 0,6'sından büyük ya da yazı boyu farklıysa ayrı blok;
    /// konuşan adlı blok altyazıdır.
    func testLineThatAppearsWithTheFirstSubtitleIsASeparateBlock() {
        let reading = Reading(lines: [
            TextLine("Lucia: Just drive the car.", box: TextBox(left: 0.2, top: 0.60, right: 0.8, bottom: 0.68)),
            TextLine("Go to the bank.", box: TextBox(left: 0.35, top: 0.74, right: 0.65, bottom: 0.80)),
        ])
        XCTAssertEqual(reading.subtitleBlock(in: TextBox(left: 0, top: 0, right: 1, bottom: 1)).text, "Lucia: Just drive the car.")
    }
}
#endif
