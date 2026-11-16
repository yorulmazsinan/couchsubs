// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import XCTest

/// Yarım ya da bozuk okumanın aynı satır sayılma kuralları (Windows: SubtitlePipeline.IsRereadOf, Android: ReadingHoldTest).
final class RereadsTests: XCTestCase {
    func testHalfReadLineIsRereadOfWholeLine() {
        XCTAssertTrue(Rereads.isRereadOf("Get Franklin close to the", "Get Franklin close to the house."))
    }

    func testSeparateShortSentenceIsNotReread() {
        XCTAssertFalse(Rereads.isRereadOf("You kill me!", "I swear to God, you kill me!"))
    }

    func testDroppedWordIsReread() {
        XCTAssertTrue(Rereads.isRereadOf("Go to Bluffs", "Go to Pacific Bluffs."))
    }

    func testCompleteness() {
        XCTAssertTrue(Rereads.looksComplete("Hold the gate."))
        XCTAssertFalse(Rereads.looksComplete("hold the gate"))
        XCTAssertFalse(Rereads.looksComplete("Get Franklin close to the"))
    }

    func testMissingSecondLineIsKept() {
        XCTAssertEqual(Rereads.keepMissingLines("You did it.", older: "You did it.\nI don't care!"), "You did it.\nI don't care!")
    }

    func testRelated() {
        XCTAssertTrue(Rereads.related("Get Franklin close", "Get Franklin close to the house."))
        XCTAssertFalse(Rereads.related("And you watch your language!", "r guage! fair!"))
    }
}
