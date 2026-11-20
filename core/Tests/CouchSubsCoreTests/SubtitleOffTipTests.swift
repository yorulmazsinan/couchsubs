// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// "Oyunun kendi altyazısını açın": görüntü bir dakikadır geliyor ama tek satır yok (GitHub #503, #566, #572; Android
/// SubtitleOffTipTest, Windows AppControllerTests ile aynı).
final class SubtitleOffTipTests: XCTestCase {
    func testRule() {
        XCTAssertTrue(SubtitleOffTip.isVisible(streaming: true, sawLine: false, framesFor: 60))
        XCTAssertFalse(SubtitleOffTip.isVisible(streaming: true, sawLine: false, framesFor: 59.9))
        XCTAssertFalse(SubtitleOffTip.isVisible(streaming: true, sawLine: true, framesFor: 600))
        XCTAssertFalse(SubtitleOffTip.isVisible(streaming: false, sawLine: false, framesFor: 600))
        XCTAssertFalse(SubtitleOffTip.isVisible(streaming: true, sawLine: false, framesFor: nil))
    }

    func testAppearsAfterAMinuteOfFramesAndHidesAtFirstLine() {
        var tip = SubtitleOffTip()
        let start = Date(timeIntervalSince1970: 1_000)
        tip.frameArrived(at: start, streaming: true)
        tip.frameArrived(at: start.addingTimeInterval(30), streaming: true)
        XCTAssertFalse(tip.visible(now: start.addingTimeInterval(59), streaming: true))
        XCTAssertTrue(tip.visible(now: start.addingTimeInterval(61), streaming: true))
        tip.lineShown()
        XCTAssertFalse(tip.visible(now: start.addingTimeInterval(120), streaming: true))
    }

    func testConnectionDropRestartsTheClock() {
        var tip = SubtitleOffTip()
        let start = Date(timeIntervalSince1970: 1_000)
        tip.frameArrived(at: start, streaming: true)
        tip.connectionChanged(streaming: false)
        XCTAssertFalse(tip.visible(now: start.addingTimeInterval(120), streaming: true))
        tip.frameArrived(at: start.addingTimeInterval(100), streaming: true)
        XCTAssertFalse(tip.visible(now: start.addingTimeInterval(130), streaming: true))
        XCTAssertTrue(tip.visible(now: start.addingTimeInterval(160), streaming: true))
    }

    func testFramesBeforeStreamingDoNotCount() {
        var tip = SubtitleOffTip()
        let start = Date(timeIntervalSince1970: 1_000)
        tip.frameArrived(at: start, streaming: false)
        XCTAssertNil(tip.framesSince)
    }

    func testResetStartsANewRun() {
        var tip = SubtitleOffTip()
        tip.frameArrived(at: Date(timeIntervalSince1970: 1_000), streaming: true)
        tip.lineShown()
        tip.reset()
        XCTAssertNil(tip.framesSince)
        XCTAssertFalse(tip.sawLine)
    }
}
