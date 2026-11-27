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
        var objectives: [TextBox?] = []
        func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) {}
        func clear() {}
        func sendObjective(_ box: TextBox?) { objectives.append(box) }
    }
    private final class Translator: TextTranslator {
        var requested: [String] = []
        func translate(_ text: String) async throws -> String {
            requested.append(text)
            return "TR: " + text
        }
    }

    private func run(_ frames: [Reading], sender: Sender = Sender()) async -> (regions: [CropRegion?], requested: [String]) {
        var time = 0
        let translator = Translator()
        let pipeline = SubtitlePipeline(reader: Reader(frames), translator: translator, server: sender, clock: { time })
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
        let frames = ObjectiveWithDialogueTests.frames(below: true, gap: 1.5, objectiveFirst: 4) + Array(repeating: .empty, count: 10)
        let (regions, _) = await run(frames)
        XCTAssertNotNil(regions.first ?? nil)
        XCTAssertNil(regions.last ?? CropRegion())
    }

    /// X, beta.100–104 (GTA 6): altyazı kutusu alttaki görev satırını örtüyordu. Görev satırının yeri, görev sayılmasını
    /// (`settleMs`) beklemeden TV'ye bildirilir; konuşma değişse de yeniden gönderilmez, görev kalkınca nil gider.
    func testObjectiveBelowDialogueIsSentAsClearanceOnce() async throws {
        let sender = Sender()
        let frames = ObjectiveWithDialogueTests.frames(below: true, gap: 0.1, objectiveFirst: 4) + Array(repeating: .empty, count: 10)
        let (regions, _) = await run(frames, sender: sender)
        let first = try XCTUnwrap(sender.objectives.first ?? nil)
        XCTAssertEqual(first.top, 0.8, accuracy: 0.001)
        XCTAssertEqual(first.bottom, 0.88, accuracy: 0.001)
        XCTAssertEqual(sender.objectives.count, 2, "\(sender.objectives)")
        XCTAssertNil(sender.objectives.last ?? first)
        XCTAssertNotNil(regions.first ?? nil)
    }

    func testClearanceIgnoresSmallJitterAndFollowsRealMoves() {
        var mission = MissionLine()
        let area = TextBox(left: 0, top: 0, right: 1, bottom: 1)
        func see(_ top: Double, _ time: Int) {
            _ = mission.observe([TextLine("Get in the speedboat", box: TextBox(left: 0.45, top: top, right: 0.62, bottom: top + 0.03))],
                                area: area, at: time)
        }
        see(0.94, 0)
        let first = mission.clearance
        XCTAssertNotNil(first)
        see(0.945, 500)
        XCTAssertEqual(mission.clearance, first)
        see(0.80, 1000)
        XCTAssertEqual(mission.clearance?.top ?? 0, 0.80, accuracy: 0.0001)
        _ = mission.observe([], area: area, at: 3000)
        XCTAssertNil(mission.clearance)
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
