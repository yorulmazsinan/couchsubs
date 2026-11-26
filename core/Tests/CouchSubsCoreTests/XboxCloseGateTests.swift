// SPDX-License-Identifier: AGPL-3.0-only
// Xbox oturumlarının kapanış sırası: yeni oturum önceki oturumun kapanışını bekler, kapatılamayan oturum sonraki oturuma
// kalır. Android'deki XboxCloseGateTest ile aynı.

import XCTest
@testable import CouchSubsCore

final class XboxCloseGateTests: XCTestCase {
    func testNothingPendingReturnsNil() async {
        let gate = XboxCloseGate()
        let waited = await gate.waitForPending(limitMs: 1000)
        XCTAssertNil(waited)
    }

    func testNewSessionWaitsForPreviousClose() async {
        let gate = XboxCloseGate()
        let closed = Flag()
        gate.track {
            try? await Task.sleep(nanoseconds: 100_000_000)
            closed.set()
        }
        let waited = await gate.waitForPending(limitMs: 5000)
        XCTAssertTrue(closed.value, "yeni oturum eski oturum kapanmadan açılmaz")
        XCTAssertEqual(waited?.sessions, 1)
        XCTAssertEqual(waited?.timedOut, false)
        XCTAssertEqual(gate.pendingCount, 0)
    }

    func testSlowCloseDoesNotBlockForever() async {
        let gate = XboxCloseGate()
        gate.track { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        let waited = await gate.waitForPending(limitMs: 50)
        XCTAssertEqual(waited?.timedOut, true)
        XCTAssertTrue(waited!.line.contains("bitmedi"))
    }

    /// İptal edilmiş görevden başlatılan kapanış iptal edilmiş sayılmaz (DELETE gerçekten gider).
    func testCloseRunsOutsideCancelledTask() async {
        let gate = XboxCloseGate()
        let cancelledInside = Flag()
        let outer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let closing = gate.track { if Task.isCancelled { cancelledInside.set() } }
            await closing.value
        }
        await outer.value
        XCTAssertFalse(cancelledInside.value)
    }

    func testStaleSessionsPassToTheNextSession() {
        let gate = XboxCloseGate()
        gate.addStale("a")
        gate.addStale("a")
        gate.addStale("b")
        XCTAssertEqual(gate.takeStale(), ["a", "b"])
        XCTAssertEqual(gate.takeStale(), [])
    }

    func testWaitLine() {
        XCTAssertEqual(XboxCloseWait(sessions: 1, elapsedMs: 420, timedOut: false).line,
                       "önceki oturumun kapanması beklendi (1 oturum, 0.4 sn)")
        XCTAssertEqual(XboxCloseWait(sessions: 2, elapsedMs: 10_000, timedOut: true).line,
                       "önceki oturumun kapanması 10.0 sn'de bitmedi (2 oturum); yeni oturum yine açılıyor")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
