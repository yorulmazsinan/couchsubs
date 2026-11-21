// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class TranslationGateTests: XCTestCase {
    private actor Counter {
        var running = 0
        var peak = 0
        var finished = 0
        func begin() { running += 1; peak = max(peak, running) }
        func end() { running -= 1; finished += 1 }
    }

    /// Isınma ile ilk altyazı aynı anda gelse de Apple'ın oturumuna aynı anda yalnız bir istek gider.
    func testRunsOneAtATime() async throws {
        let gate = TranslationGate()
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await gate.run {
                        await counter.begin()
                        try await Task.sleep(nanoseconds: 5_000_000)
                        await counter.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await counter.peak
        let finished = await counter.finished
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(finished, 8)
    }

    /// Sırada bekleyen iptal edilen istek beklemeyi bırakır; sıra sonrakilere geçer.
    func testCancelledWaiterLeavesQueue() async throws {
        let gate = TranslationGate()
        let release = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await gate.run { for await _ in release.stream { break } }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter = Task { try await gate.run { "çalıştı" } }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("iptal edilen bekleyen çalışmamalı")
        } catch is CancellationError {}
        release.continuation.yield()
        try await holder.value
        let after = try await gate.run { "sonra" }
        XCTAssertEqual(after, "sonra")
    }

    func testErrorReleasesGate() async throws {
        struct Failure: Error {}
        let gate = TranslationGate()
        do {
            try await gate.run { throw Failure() }
            XCTFail()
        } catch is Failure {}
        let value = try await gate.run { 42 }
        XCTAssertEqual(value, 42)
    }
}
