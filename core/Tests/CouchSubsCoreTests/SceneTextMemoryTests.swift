// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Az önce sahne yazısı sayılıp atılan satırın (plaka, tabela, telefon mesajı) başka okunuşu altyazı olmaz (#1411).
/// Örnekler ortak deneme dosyasından (Fixtures/scene-text-memory.json; Windows SceneTextMemoryTests.cs ve Android
/// SceneTextMemoryTest.kt aynı dosyayı okur).
final class SceneTextMemoryTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Line: Decodable {
            let text: String
            let box: [Double]
        }
        struct Step: Decodable {
            let at: Int
            let dropped: [String]?
            let reason: String?
            let forget: String?
            let read: [String]?
            let area: [Double]?
            let band: [Line]?
            let lines: [Line]?
            let kept: [String]?
            let leftovers: [String]?
        }
        struct Case: Decodable { let name: String; let steps: [Step] }
        let cases: [Case]
    }

    func testSharedVectors() throws {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("scene-text-memory.json")
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertFalse(vectors.cases.isEmpty)
        for vector in vectors.cases {
            var memory = SceneTextMemory()
            var band = SubtitleBand()
            for step in vector.steps {
                let area = step.area.map(Self.box)
                if let subtitle = step.band { band.record(Self.boxed(subtitle), in: try XCTUnwrap(area)) }
                if let dropped = step.dropped { memory.remember(dropped, reason: try XCTUnwrap(step.reason), at: step.at) }
                if let reason = step.forget { memory.forget(reason: reason) }
                guard let reading = step.read.map({ Reading(lines: $0.map { TextLine($0) }) }) ?? step.lines.map(Self.boxed)
                else { continue }
                let kept = memory.filter(reading, at: step.at, in: area, band: band)
                XCTAssertEqual(kept.lines.map(\.text), step.kept, vector.name)
                if let leftovers = step.leftovers {
                    XCTAssertEqual(memory.leftovers.map(\.line.text), leftovers, "\(vector.name) (kalan)")
                }
            }
        }
    }

    private static func box(_ values: [Double]) -> TextBox {
        TextBox(left: values[0], top: values[1], right: values[2], bottom: values[3])
    }

    private static func boxed(_ lines: [Vectors.Line]) -> Reading {
        Reading(lines: lines.map { TextLine($0.text, box: box($0.box), confidence: 1) })
    }

    /// Ortak dosyadaki nedenler çekirdeğin nedenleriyle aynı yazılır (biri değişirse dosya da değişmeli).
    func testRememberedReasonsMatchTheGate() {
        for reason in [SceneText.signReason, SceneText.numberReason, SceneText.plateNumberReason, SceneText.menuItemReason,
                       SceneText.tiltedReason, InkTone.reason, Reading.offBandReason, SceneTextMemory.phoneReason] {
            XCTAssertTrue(SceneTextMemory.remembers(reason), reason)
        }
        for reason in [SceneMotion.reason, PackageText.reason, Reading.listReason, "karenin ortasında kısa satır"] {
            XCTAssertFalse(SceneTextMemory.remembers(reason), reason)
        }
    }

    func testResetForgetsEverything() {
        var memory = SceneTextMemory()
        memory.remember(["ALL GUN SALES ARE FINAL"], reason: SceneText.signReason, at: 0)
        memory.reset()
        let kept = memory.filter(Reading(lines: [TextLine("ALL GUN SALES ARE FINAL")]), at: 10)
        XCTAssertEqual(kept.lines.map(\.text), ["ALL GUN SALES ARE FINAL"])
        XCTAssertTrue(memory.removed.isEmpty)
    }
}
