// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class SpeakerColorsTests: XCTestCase {
    /// Windows, Android ve TV uygulaması aynı değerleri üretir (aynı palet, aynı FNV-1a).
    func testColorIsStablePerNameAndCaseInsensitive() {
        XCTAssertEqual(SpeakerColors.color(for: "Mattia"), "#90CAF9")
        XCTAssertEqual(SpeakerColors.color(for: "MATTIA"), "#90CAF9")
        XCTAssertEqual(SpeakerColors.color(for: " Mattia "), "#90CAF9")
        XCTAssertEqual(SpeakerColors.color(for: "Lucia"), "#F06292")
        XCTAssertEqual(SpeakerColors.color(for: "Jason"), "#4DD0E1")
        XCTAssertEqual(SpeakerColors.color(for: "Cal"), "#4FC3F7")
    }

    func testPaletteParsesToComponents() {
        XCTAssertTrue(SpeakerColors.palette.allSatisfy { SpeakerColors.rgb($0) != nil })
        let amber = SpeakerColors.rgb("#FFD54F")
        XCTAssertEqual(amber?.red, 1)
        XCTAssertEqual(amber?.blue ?? 0, 0x4F / 255, accuracy: 0.0001)
        XCTAssertNil(SpeakerColors.rgb("FFD54F"))
    }

    /// Çeviride ad gibi görünen Türkçe başlıklar konuşan sayılmaz, renklenmez.
    func testTurkishHeadingsAreNotSpeakers() {
        XCTAssertTrue(SpeakerColors.speakers(in: "Hedef: Arabaya bin.\nGörev: Lucia'yı bul.\nNOT: Kaydet.\nİpucu: Koş.").isEmpty)
        XCTAssertEqual(SpeakerColors.segments(in: "Mattia: Gidelim.\nHedef: Arabaya bin."), [
            .init(text: "Mattia: Gidelim.", color: "#90CAF9"),
            .init(text: "\nHedef: Arabaya bin.", color: nil),
        ])
    }

    func testSpeakersAreUniqueInOrder() {
        let speakers = SpeakerColors.speakers(in: "Lucia: Gel.\nMattia: Geliyorum.\nLucia: Çabuk.")
        XCTAssertEqual(speakers.map(\.name), ["Lucia", "Mattia"])
        XCTAssertEqual(speakers.map(\.color), ["#F06292", "#90CAF9"])
        XCTAssertTrue(SpeakerColors.speakers(in: "Saat 10:30 oldu").isEmpty)
        XCTAssertTrue(SpeakerColors.speakers(in: "Note: Kaydet").isEmpty)
    }

    /// Bölünmüş devam satırı konuşanın renginde kalır; ilk adlı satırdan öncesi renksizdir; parçalar metni bozmaz.
    func testSegmentsFollowSpeakerUntilNextName() {
        let text = "Görev başladı\nMattia: Buradan\ngidelim.\nLucia: Tamam."
        let segments = SpeakerColors.segments(in: text)
        XCTAssertEqual(segments.map(\.text).joined(), text)
        XCTAssertEqual(segments, [
            .init(text: "Görev başladı", color: nil),
            .init(text: "\nMattia: Buradan\ngidelim.", color: "#90CAF9"),
            .init(text: "\nLucia: Tamam.", color: "#F06292"),
        ])
        XCTAssertEqual(SpeakerColors.segments(in: "Adsız"), [.init(text: "Adsız", color: nil)])
    }
}
