// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Az önce sahne yazısı sayılıp atılan satırın (plaka, tabela, telefon mesajı) başka okunuşu altyazı olmaz (#1411).
/// Örnekler ortak deneme dosyasından (Fixtures/scene-text-memory.json; Windows SceneTextMemoryTests.cs ve Android
/// SceneTextMemoryTest.kt aynı dosyayı okur).
final class SceneTextMemoryTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Step: Decodable {
            let at: Int
            let dropped: [String]?
            let reason: String?
            let forget: String?
            let read: [String]?
            let kept: [String]?
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
            for step in vector.steps {
                if let dropped = step.dropped { memory.remember(dropped, reason: try XCTUnwrap(step.reason), at: step.at) }
                if let reason = step.forget { memory.forget(reason: reason) }
                if let read = step.read {
                    let kept = memory.filter(Reading(lines: read.map { TextLine($0) }), at: step.at)
                    XCTAssertEqual(kept.lines.map(\.text), step.kept, vector.name)
                }
            }
        }
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
