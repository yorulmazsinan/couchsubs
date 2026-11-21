// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import XCTest

final class SubtitleWrapTests: XCTestCase {
    /// Bilgisayardaki pencerede oyunda tek satır görünen altyazının çevirisi tek satırda kalır (66); telefonda 42
    /// (Windows: SubtitleWrapTests.Desktop_keeps_a_sixty_char_line_on_one_line).
    func testDesktopKeepsASixtyCharLineOnOneLine() {
        let text = "Evet, bazı yerlerin koruması daha fazla. İki taraf da kazandı."
        XCTAssertEqual(SubtitleWrap.fit(text, maxChars: SubtitleWrap.desktopMaxChars).text.split(separator: "\n").count, 1)
        XCTAssertEqual(SubtitleWrap.fit(text).text.split(separator: "\n").count, 2)
    }

    func testShortTextIsUntouched() {
        XCTAssertEqual(SubtitleWrap.fit("Gitmeliyiz, hemen."), .init(text: "Gitmeliyiz, hemen.", scale: 1))
    }

    func testLongTextSplitsIntoTwoBalancedLines() {
        let text = "Bu işin sonunda hepimiz için bir çıkış yolu bulmamız gerekiyor artık"
        let result = SubtitleWrap.fit(text)
        let lines = result.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(result.scale, 1)
        XCTAssertLessThanOrEqual(abs(lines[0].count - lines[1].count), 12)
        XCTAssertEqual(lines.joined(separator: " "), text)
    }

    func testVeryLongTextUsesAtMostThreeLinesAndShrinks() {
        let text = Array(repeating: "kelime", count: 30).joined(separator: " ")
        let result = SubtitleWrap.fit(text)
        XCTAssertEqual(result.text.split(separator: "\n").count, 3)
        XCTAssertLessThan(result.scale, 1)
        XCTAssertGreaterThanOrEqual(result.scale, SubtitleWrap.minScale)
    }

    func testSpeakerNameStaysOnFirstLineWithText() {
        let result = SubtitleWrap.fit("ARTHUR: We need to leave before they find us here in the middle of the night, understand?")
        let first = result.text.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(first.hasPrefix("ARTHUR: "), first)
        XCTAssertGreaterThan(first.count, "ARTHUR:".count)
    }

    func testExistingBreaksAndParagraphsAreKept() {
        let text = "Birinci satır uzun uzun uzun uzun\nİkinci satır da oldukça uzun bir satır"
        XCTAssertEqual(SubtitleWrap.fit(text).text, text)
        let line = SubtitleStack.Line(id: 1, text: Array(repeating: "kelime", count: 20).joined(separator: " "),
                                      role: .current, paragraphs: true)
        XCTAssertEqual(line.wrapped.scale, 1)
        XCTAssertFalse(line.wrapped.text.contains("\n"))
    }
}
