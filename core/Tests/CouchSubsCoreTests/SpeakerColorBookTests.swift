// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Konuşana göre renk v2: dört platformun ortak vektörü (docs/speaker-colors-vectors.json) birebir.
final class SpeakerColorBookTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Step: Decodable { var name: String; var color: String }
        var palette: [String]
        var families: [String: String]
        var sequence: [Step]
    }

    private func vectors() throws -> Vectors {
        // core/Tests/CouchSubsCoreTests/<dosya> → depo kökü/docs/
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/speaker-colors-vectors.json"))
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    func testSharedSequenceGivesTheSameColours() throws {
        let vectors = try vectors()
        XCTAssertEqual(SpeakerColors.palette, vectors.palette)
        for (color, family) in vectors.families { XCTAssertEqual(SpeakerColorBook.families[color].map(String.init), family) }
        let book = SpeakerColorBook()
        for step in vectors.sequence { XCTAssertEqual(book.color(step.name), step.color, step.name) }
    }

    func testResetStartsANewSession() {
        let book = SpeakerColorBook()
        XCTAssertEqual(book.color("Mattia"), "#90CAF9")
        XCTAssertEqual(book.color("Boobie"), "#FFD54F")
        book.reset()
        XCTAssertEqual(book.color("Boobie"), "#90CAF9")
        XCTAssertNil(book.color(" ... "))
    }

    func testTitlesAndTimesAreNotSpeakers() {
        for line in ["Hedef: Arabaya bin.", "Görev: Lucia'yı bul.", "İpucu: Haritayı aç.", "Not: Kaydet.", "Soru: Neden?",
                     "12:30", "3:1 oranla kazandın"] {
            XCTAssertTrue(SpeakerColors.speakers(in: line).isEmpty, line)
        }
    }

    func testServerAndSegmentsUseTheSessionColours() {
        let server = SubtitleServer(port: 0)
        XCTAssertEqual(server.speakerBook.color("Mattia"), "#90CAF9")
        XCTAssertEqual(server.speakerBook.color("Boobie"), "#FFD54F")
        XCTAssertEqual(SpeakerColors.speakers(in: "Boobie: Gel.", book: server.speakerBook).map(\.color), ["#FFD54F"])
        XCTAssertEqual(SpeakerColors.segments(in: "Mattla: Gidelim.", book: server.speakerBook).map(\.color), ["#90CAF9"])
    }
}
