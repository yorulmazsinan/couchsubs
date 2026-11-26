// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Kalabalık sahnede aynı anda konuşan kişilerin alt alta duran ayrı blokları tek altyazıda, her biri kendi satırında ve
/// adıyla birleşir (X, beta.100). Ortalı, eşit aralıklı üç konuşma satırı menü listesi sayılmaz. Windows
/// (SpokenTogetherTests) ve Android (SpokenTogetherTest) aynı vakalar.
final class SpokenTogetherTests: XCTestCase {
    private let area = TextBox(left: 0, top: 0, right: 1, bottom: 1)

    /// Ortaya hizalı satır; genişliği yazının uzunluğuyla.
    private func line(_ text: String, _ top: Double, height: Double = 0.04) -> TextLine {
        let half = Double(text.count) * 0.0065
        return TextLine(text, box: TextBox(left: 0.5 - half, top: top, right: 0.5 + half, bottom: top + height))
    }

    private func left(_ text: String, _ top: Double, height: Double = 0.04) -> TextLine {
        TextLine(text, box: TextBox(left: 0.1, top: top, right: 0.1 + Double(text.count) * 0.012, bottom: top + height))
    }

    func testTwoSpeakersAtOnceAreJoinedInOrder() {
        let reading = Reading(lines: [
            line("Vendor: You want the usual today?", 0.74),
            line("Driver: Move your cart, man.", 0.82),
        ])
        let block = reading.subtitleBlock(in: area)
        XCTAssertEqual(block.text, "Vendor: You want the usual today?\nDriver: Move your cart, man.")
        XCTAssertEqual(block.box?.top, 0.74)
        XCTAssertEqual(block.box?.bottom ?? 0, 0.86, accuracy: 1e-9)
    }

    func testThreeEvenlySpacedSpeakersAreJoinedNotAMenuList() {
        let reading = Reading(lines: [
            line("Tourist: Which way to the beach?", 0.66),
            line("Guard: Keep walking.", 0.74),
            line("Kid: Look at that car over there!", 0.82),
        ])
        XCTAssertFalse(reading.isHistoryList)
        XCTAssertEqual(reading.subtitleBlock(in: area).text,
                       "Tourist: Which way to the beach?\nGuard: Keep walking.\nKid: Look at that car over there!")
    }

    func testWrappedSpeechStaysWithItsSpeaker() {
        let reading = Reading(lines: [
            line("Tourist: Excuse me, which way is", 0.62),
            line("the beach from here?", 0.665),
            line("Guard: Keep walking.", 0.74),
        ])
        XCTAssertEqual(reading.subtitleBlock(in: area).text,
                       "Tourist: Excuse me, which way is\nthe beach from here?\nGuard: Keep walking.")
    }

    func testLeftAlignedHistoryListIsStillAList() {
        let reading = Reading(lines: [
            left("Staff: Hi there.", 0.3),
            left("Customer: One coffee, please.", 0.38),
            left("Staff: Coming right up.", 0.46),
        ])
        XCTAssertTrue(reading.isHistoryList)
        XCTAssertEqual(reading.subtitleBlock(in: area), .empty)
    }

    func testFarApartSpeakerIsNotJoined() {
        let reading = Reading(lines: [line("Vendor: Fresh fruit!", 0.5), line("Driver: Move it.", 0.82)])
        XCTAssertEqual(reading.subtitleBlock(in: area).text, "Vendor: Fresh fruit!")
    }

    func testObjectiveBetweenSpeakersStopsTheJoin() {
        let reading = Reading(lines: [
            line("Vendor: You want the usual today?", 0.66),
            line("Go to the market.", 0.735, height: 0.02),
            line("Driver: Move your cart, man.", 0.8),
        ])
        XCTAssertEqual(reading.subtitleBlock(in: area).text, "Vendor: You want the usual today?")
    }

    func testDifferentTextSizeIsNotJoined() {
        let reading = Reading(lines: [line("Vendor: Fresh fruit!", 0.7), line("Driver: Move it.", 0.8, height: 0.07)])
        XCTAssertEqual(reading.subtitleBlock(in: area).text, "Vendor: Fresh fruit!")
    }

    func testJoinedSpeakersKeepTheirNames() {
        let pieces = SubtitleSegmenter.split("Vendor: You want the usual today?\nDriver: Move your cart, man.")
        let kept = pieces.filter { !$0.translate }.map(\.text).joined()
        XCTAssertTrue(kept.contains("Vendor:"), "\(pieces)")
        XCTAssertTrue(kept.contains("Driver:"), "\(pieces)")
        XCTAssertTrue(kept.contains("\n"), "\(pieces)")
    }

    /// Altyazı seçicinin konuşan adı saydığı her satır ("JASON : …", "Lucia：…") kendi satırında kalır; iki konuşanın
    /// sözü tek satıra birleşmez (beta.103 bildirimi; Windows ve Android aynı).
    func testEverySpeakerLineStartsItsOwnRow() {
        for second in ["JASON : I'm coming.", "Jason：I'm coming.", "DJ Pooh: I'm coming."] {
            let pieces = SubtitleSegmenter.split("Lucia: Get in the car.\n" + second)
            XCTAssertTrue(pieces.contains { !$0.translate && $0.text == "\n" }, "\(second): \(pieces)")
            XCTAssertFalse(pieces.contains { $0.translate && $0.text.contains("Get in") && $0.text.contains("coming") }, "\(pieces)")
        }
    }
}
