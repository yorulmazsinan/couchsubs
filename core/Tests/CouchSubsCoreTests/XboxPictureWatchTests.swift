// SPDX-License-Identifier: AGPL-3.0-only
// İlk kareden sonra Xbox görüntüsü kesilince uyarı ve yeniden kurma. Sahte saat: anlar ms olarak verilir.
// Windows'taki XboxPictureWatchTests.cs ve Android'deki XboxPictureWatchTest.kt ile aynı durumlar.

import XCTest
@testable import CouchSubsCore

final class XboxPictureWatchTests: XCTestCase {
    func testNothingIsDecidedBeforeTheFirstFrame() {
        var watch = XboxPictureWatch()
        watch.iceChanged(.disconnected, atMs: 0)
        XCTAssertEqual(watch.tick(atMs: 60_000), .fine)
    }

    func testFlowingPictureIsFine() {
        var watch = XboxPictureWatch()
        for second in 0..<120 {
            watch.frameArrived(atMs: second * 1000)
            XCTAssertEqual(watch.tick(atMs: second * 1000 + 500), .fine)
        }
    }

    func testWarnsOnceThenReconnectsWhenFramesStopWhileTheConnectionLooksOpen() {
        var watch = XboxPictureWatch()
        watch.frameArrived(atMs: 10_000)
        XCTAssertEqual(watch.tick(atMs: 14_000), .fine)
        XCTAssertEqual(watch.tick(atMs: 15_000), .warn)
        XCTAssertTrue(watch.warned)
        XCTAssertEqual(watch.tick(atMs: 16_000), .fine)
        XCTAssertEqual(watch.tick(atMs: 21_000), .fine)
        XCTAssertEqual(watch.tick(atMs: 22_000), .stalled("Xbox'tan 12 sn'dir görüntü gelmiyor (bağlantı açık görünüyor)"))
    }

    func testRecoversWhenFramesComeBackBeforeTheLimit() {
        var watch = XboxPictureWatch()
        watch.frameArrived(atMs: 0)
        XCTAssertEqual(watch.tick(atMs: 6000), .warn)
        watch.frameArrived(atMs: 8000)
        XCTAssertEqual(watch.tick(atMs: 8500), .recovered)
        XCTAssertFalse(watch.warned)
        XCTAssertEqual(watch.tick(atMs: 9500), .fine)
    }

    func testIceDisconnectedWarnsAfterOneSecondWithoutFrames() {
        var watch = XboxPictureWatch()
        watch.frameArrived(atMs: 0)
        watch.iceChanged(.disconnected, atMs: 200)
        XCTAssertEqual(watch.tick(atMs: 500), .fine)
        XCTAssertEqual(watch.tick(atMs: 1200), .warn)
        watch.iceChanged(.connected, atMs: 3000)
        watch.frameArrived(atMs: 3100)
        XCTAssertEqual(watch.tick(atMs: 3500), .recovered)
    }

    func testIceStuckInDisconnectedEndsTheSessionAtTheLimit() {
        var watch = XboxPictureWatch()
        watch.frameArrived(atMs: 0)
        watch.iceChanged(.disconnected, atMs: 100)
        XCTAssertEqual(watch.tick(atMs: 1000), .warn)
        XCTAssertEqual(watch.tick(atMs: 12_000), .stalled("Xbox'tan 12 sn'dir görüntü gelmiyor (ICE disconnected)"))
    }

    func testIceFailedEndsTheSessionAtOnce() {
        var watch = XboxPictureWatch()
        watch.frameArrived(atMs: 0)
        watch.iceChanged(.failed, atMs: 500)
        XCTAssertEqual(watch.tick(atMs: 600), .stalled("Xbox ICE bağlantısı koptu (failed)"))
    }

    func testFramesWhileIceSaysDisconnectedDoNotWarn() {
        var watch = XboxPictureWatch()
        watch.iceChanged(.disconnected, atMs: 0)
        for second in 0..<20 {
            watch.frameArrived(atMs: second * 1000)
            XCTAssertEqual(watch.tick(atMs: second * 1000 + 300), .fine)
        }
    }

    func testStalledSessionRetriesThroughTheMachine() {
        var clock = 0.0
        var machine = XboxSessionMachine(clock: { clock })
        XCTAssertEqual(machine.start(), .play)
        XCTAssertEqual(machine.played(), .pollState(delayMs: 0))
        XCTAssertEqual(machine.status("Provisioned", errorDetails: nil), .negotiate)
        XCTAssertTrue(machine.streaming())
        clock = 30_000
        XCTAssertEqual(machine.fail(.noPicture, "Xbox'tan 12 sn'dir görüntü gelmiyor"), .retry(delayMs: 5000))
        XCTAssertEqual(machine.phase, .failed(.noPicture, message: "Xbox'tan 12 sn'dir görüntü gelmiyor", willRetry: true, attempt: 1))
    }
}
