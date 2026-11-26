// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Altyazı kapısının eleme sayacı (`RejectTally`; beta.103 kaçan altyazı). Windows RejectTallyTests.cs ve Android
/// RejectTallyTest.kt aynı vakalar.
final class RejectTallyTests: XCTestCase {
    func testLineCarriesTheReasonCount() {
        let tally = RejectTally()
        XCTAssertEqual(tally.note("menü", line: "a", now: 0), ["a [bu nedenle 1. kez]"])
        XCTAssertEqual(tally.note("menü", line: nil, now: 10), [])
        XCTAssertEqual(tally.note("menü", line: "b", now: 20), ["b [bu nedenle 3. kez]"])
        XCTAssertEqual(tally.note("telefon", line: "c", now: 30), ["c [bu nedenle 1. kez]"])
        XCTAssertEqual(tally.count("menü"), 3)
    }

    func testLinesAreCappedPerMinuteAndSummarized() {
        let tally = RejectTally()
        var written: [String] = []
        for index in 0..<(RejectTally.perMinute + 5) { written += tally.note("menü", line: "satır \(index)", now: index) }
        _ = tally.note("telefon", line: nil, now: 100)
        XCTAssertEqual(written.count, RejectTally.perMinute)
        let next = tally.note("menü", line: "yeni", now: RejectTally.windowMs + 1)
        XCTAssertEqual(next, [
            "altyazı elemesi (son 60 sn): menü ×\(RejectTally.perMinute + 5); telefon ×1; sınır yüzünden yazılmayan 5 satır",
            "yeni [bu nedenle \(RejectTally.perMinute + 6). kez]",
        ])
    }

    func testResetForgetsTheCounts() {
        let tally = RejectTally()
        _ = tally.note("menü", line: nil, now: 0)
        tally.reset()
        XCTAssertEqual(tally.note("menü", line: "a", now: 1), ["a [bu nedenle 1. kez]"])
    }
}
