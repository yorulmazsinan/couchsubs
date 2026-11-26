// SPDX-License-Identifier: AGPL-3.0-only
// Xbox kare hattı satırı (#1308) ve kapanma anındaki akış durumu (#1252). Android'deki XboxFramePipeTest ile aynı.

import XCTest
@testable import CouchSubsCore

final class XboxFramePipeTests: XCTestCase {
    func testStatsLineAndReset() {
        var stats = XboxFramePipeStats()
        XCTAssertNil(stats.take(windowMs: 10_000, memory: "bellek"), "kare gelmediyse satır yok")
        stats.sink(nanos: 1_000_000)
        stats.sink(nanos: 3_000_000)
        stats.handedOver()
        stats.processed(nanos: 40_000_000)
        XCTAssertEqual(stats.take(windowMs: 10_000, memory: "bellek 230 MB"),
                       "kare hattı (10 sn): gelen 2, aktarılan 1, işlenen 1, atlanan 0; alıcı ort 2.0 ms, en çok 3.0 ms; "
                       + "işleme ort 40.0 ms, en çok 40.0 ms; bellek 230 MB")
        XCTAssertNil(stats.take(windowMs: 10_000, memory: "bellek"))
    }

    func testDroppedFramesAreCounted() {
        var stats = XboxFramePipeStats()
        stats.sink(nanos: 100_000)
        stats.handedOver()
        stats.dropped(4)
        XCTAssertTrue(stats.take(windowMs: 10_000, memory: "")!.contains("işlenen 0, atlanan 4"))
    }

    /// Kare onayı döngüsü takılırsa (Xbox onay alamayıp görüntü kanalını kapatır) satırda en uzun aralık ve geç tur sayısı.
    func testAckGapsAreReported() {
        var stats = XboxFramePipeStats()
        stats.sink(nanos: 1_000_000)
        stats.ackTick(gapNanos: 16_000_000)
        stats.ackTick(gapNanos: 1_200_000_000)
        stats.ackTick(gapNanos: 300_000_000)
        XCTAssertEqual(stats.take(windowMs: 10_000, memory: "bellek 1 MB"),
                       "kare hattı (10 sn): gelen 1, aktarılan 0, işlenen 0, atlanan 0; alıcı ort 1.0 ms, en çok 1.0 ms; "
                       + "işleme ort 0.0 ms, en çok 0.0 ms; onay aralığı en çok 1200.0 ms, 250 ms üstü 2; bellek 1 MB")
        stats.sink(nanos: 1_000_000)
        XCTAssertFalse(stats.take(windowMs: 10_000, memory: "")!.contains("onay aralığı"), "sayaçlar sıfırlanır")
    }

    func testCloseContextNamesLastFrameAndAck() {
        XCTAssertEqual(XboxCloseContext.describe(nowMs: 10_000, lastFrameAtMs: 9_800, lastAckAtMs: 6_500, acksSent: 1200),
                       "son kare 0.2 sn önce, son onay 3.5 sn önce, onay 1200")
        XCTAssertEqual(XboxCloseContext.describe(nowMs: 10_000, lastFrameAtMs: 0, lastAckAtMs: 0, acksSent: 0),
                       "kare gelmedi, onay gönderilmedi")
    }
}
