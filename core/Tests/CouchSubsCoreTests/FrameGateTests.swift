// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import XCTest

final class FrameGateTests: XCTestCase {
    func testOneFrameAtATime() {
        var gate = FrameGate(stuckAfterMs: 1000)
        guard case .enter(let token) = gate.enter(now: 0) else { return XCTFail("ilk kare girer") }
        XCTAssertEqual(gate.enter(now: 100), .busy, "önceki kare işlenirken yenisi atlanır")
        gate.leave(token)
        XCTAssertFalse(gate.isBusy)
        guard case .enter = gate.enter(now: 200) else { return XCTFail("önceki bitince sonraki girer") }
    }

    /// Durdur / Başlat kapıyı sıfırlar: eski oturumdan kalan bitmemiş okuma yeni oturumu bekletmez. (Eskiden bayrak
    /// sıfırlanmıyordu; okuma takılınca altyazı ancak uygulama kapatılıp açılınca geri geliyordu.)
    func testResetLetsTheNextFrameInWhileAnOldReadIsStillRunning() {
        var gate = FrameGate(stuckAfterMs: 1000)
        guard case .enter(let old) = gate.enter(now: 0) else { return XCTFail() }
        gate.reset()
        guard case .enter(let fresh) = gate.enter(now: 10) else { return XCTFail("sıfırlanınca yeni kare girer") }
        // Eski okuma sonunda biterse yeni okumayı serbest bırakmaz.
        gate.leave(old)
        XCTAssertTrue(gate.isBusy)
        XCTAssertEqual(gate.enter(now: 20), .busy)
        gate.leave(fresh)
        XCTAssertFalse(gate.isBusy)
    }

    /// Bitmeyen okuma takılmış sayılır; kapı açılır ve sonraki kare girer.
    func testReadThatNeverFinishesIsReportedAsStuck() {
        var gate = FrameGate(stuckAfterMs: 1000)
        guard case .enter(let stuck) = gate.enter(now: 0) else { return XCTFail() }
        XCTAssertEqual(gate.enter(now: 999), .busy)
        XCTAssertEqual(gate.enter(now: 1500), .stuck(ms: 1500))
        XCTAssertFalse(gate.isBusy)
        guard case .enter(let next) = gate.enter(now: 1501) else { return XCTFail("takılma bildirilince sonraki kare girer") }
        gate.leave(stuck)
        XCTAssertTrue(gate.isBusy, "takılan okumanın geç çıkışı yeni okumayı bırakmaz")
        gate.leave(next)
        XCTAssertFalse(gate.isBusy)
    }

    func testDefaultStuckLimitAllowsSlowReads() {
        var gate = FrameGate()
        _ = gate.enter(now: 0)
        XCTAssertEqual(gate.enter(now: 10_000), .busy, "yavaş Mac'te bütün karenin okuması birkaç saniye sürebilir")
        XCTAssertEqual(gate.enter(now: FrameGate.defaultStuckAfterMs), .stuck(ms: FrameGate.defaultStuckAfterMs))
    }
}
