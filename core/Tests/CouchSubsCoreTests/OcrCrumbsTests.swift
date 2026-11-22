// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import Foundation
import XCTest

/// Okuma kırıntısı ve tek sözcük bozulması (GitHub #854, #882; GTA 6): HUD kırıntısı görev sayılmaz, konuşmanın üstünde
/// beliren kırıntı konuşmayı attırmaz, ilk karede bozuk okunan sözcük doğru okununca yeniden çevrilir. Kurallar ortak deneme
/// dosyasından (Fixtures/ocr-crumbs.json; Windows OcrCrumbsTests.cs ve Android OcrCrumbsTest.kt aynı dosyayı okur).
final class OcrCrumbsTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Crumb: Decodable { let text: String; let crumb: Bool }
        struct Clean: Decodable { let `in`: String; let out: String }
        struct NonWord: Decodable { let word: String; let nonWord: Bool }
        struct Mission: Decodable { let text: String; let box: [Double]; let candidate: Bool }
        struct Step: Decodable { let time: Int; let lines: [String] }
        struct Sticky: Decodable { let name: String; let steps: [Step]; let kept: [String] }
        struct Stabilizer: Decodable { let name: String; let sent: String; let sentReads: Int; let reads: [String]; let translated: [String] }
        let crumb: [Crumb]
        let clean: [Clean]
        let nonWord: [NonWord]
        let mission: [Mission]
        let stickyRows: [Sticky]
        let stabilizer: [Stabilizer]
    }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("ocr-crumbs.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testCrumbs() throws {
        for vector in try vectors().crumb {
            XCTAssertEqual(OcrNoise.isCrumb(vector.text), vector.crumb, vector.text)
        }
    }

    func testSymbolOnlyTokensAreDropped() throws {
        for vector in try vectors().clean {
            XCTAssertEqual(OcrNoise.clean(vector.in), vector.out, vector.in)
        }
    }

    func testNonWords() throws {
        for vector in try vectors().nonWord {
            XCTAssertEqual(OcrNoise.isNonWord(vector.word), vector.nonWord, vector.word)
        }
    }

    func testMissionCandidates() throws {
        for vector in try vectors().mission {
            let box = TextBox(left: vector.box[0], top: vector.box[1], right: vector.box[2], bottom: vector.box[3])
            XCTAssertEqual(MissionLine.isCandidate(vector.text, box: box), vector.candidate, vector.text)
        }
    }

    func testStickyRows() throws {
        for vector in try vectors().stickyRows {
            var rows = StickyRows()
            var kept = Reading.empty
            for step in vector.steps {
                kept = rows.filter(Reading(lines: step.lines.map { TextLine($0) }), at: step.time)
            }
            XCTAssertEqual(kept.lines.map(\.text), vector.kept, vector.name)
        }
    }

    func testStabilizerCorrections() throws {
        for vector in try vectors().stabilizer {
            var time = 0
            var stabilizer = SubtitleStabilizer(clock: { time })
            var sent = false
            for _ in 0..<vector.sentReads {
                if case .translate(let text) = stabilizer.feed(vector.sent) {
                    XCTAssertEqual(text, vector.sent, vector.name)
                    sent = true
                }
                time += 100
            }
            XCTAssertTrue(sent, vector.name)
            var translated: [String] = []
            for read in vector.reads {
                if case .translate(let text) = stabilizer.feed(read) { translated.append(text) }
                time += 100
            }
            XCTAssertEqual(translated, vector.translated, vector.name)
        }
    }
}
