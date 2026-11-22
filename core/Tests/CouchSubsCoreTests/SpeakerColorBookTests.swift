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

    /// Altyazı Görünümü › Karakter Adı: "Tek Renk" herkesi aynı renkle, "Karaktere Göre"de seçilen renk otomatik paletin
    /// önüne geçer; seçilmeyenlere palet sırayla verilir. Stil sunucuya gidince defter ayarlanır.
    func testChosenNameColorsWin() {
        let book = SpeakerColorBook()
        book.configure(fixed: nil, overrides: ["Jason": "#4FD1C5"])
        XCTAssertEqual(book.color("JASON"), "#4FD1C5")
        XCTAssertNotNil(book.color("Lucia"))
        XCTAssertNotEqual(book.color("Lucia"), "#4FD1C5")
        book.configure(fixed: "#F5B83D", overrides: [:])
        XCTAssertEqual(book.color("Lucia"), "#F5B83D")
        XCTAssertEqual(book.color("Cal"), "#F5B83D")

        let server = SubtitleServer(port: 0)
        server.sendStyle(SubtitleStyle(nameColorMode: .single, nameHex: "#B794F6"))
        XCTAssertEqual(server.speakerBook.color("Brian"), "#B794F6")
    }

    /// Yeni stil alanları eski kayıtta yoktur; geçersiz renk yok sayılır, TV'ye yalnız geçerli alanlar gider.
    func testStyleColorFieldsDecodeAndEncode() throws {
        let old = try JSONDecoder().decode(SubtitleStyle.self, from: Data(#"{"fontSize":58}"#.utf8))
        XCTAssertEqual(old.backgroundColor, SubtitleStyle.defaultBackgroundColor)
        XCTAssertNil(old.textHex)
        XCTAssertEqual(old.nameColorMode, .speaker)
        XCTAssertFalse(old.nameOnly)
        let bad = try JSONDecoder().decode(SubtitleStyle.self, from: Data(##"{"textHex":"red","backgroundColor":"#0e1a30"}"##.utf8))
        XCTAssertNil(bad.textHex)
        XCTAssertEqual(bad.backgroundColor, "#0E1A30")
        var style = SubtitleStyle()
        style.textHex = "#FFE066"
        style.nameOnly = true
        let json = style.json
        XCTAssertEqual(json["textHex"] as? String, "#FFE066")
        XCTAssertEqual(json["backgroundColor"] as? String, "#101014")
        XCTAssertEqual(json["nameOnly"] as? Bool, true)
        XCTAssertNil(json["hdmiInput"])
        style.hdmiInput = 2
        XCTAssertEqual(style.json["hdmiInput"] as? Int, 2)
        let round = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(round, style)
    }
}
