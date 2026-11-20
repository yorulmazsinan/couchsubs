// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import RemotePlay
import CChiaki

/// PS5 aramasında boştaki adreslere gönderim hataları remoteplay.log'u şişirmemeli; başka satırlar etkilenmemeli.
final class ConsoleLogTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        let lock = NSLock()
        var items: [String] = []
        func add(_ line: String) { lock.lock(); items.append(line); lock.unlock() }
    }

    func testRepeatedSendErrorIsWrittenOnceAndSummarized() {
        let digest = Console.SendErrorDigest()
        let hostDown = "Discovery failed to send: Host is down"
        XCTAssertTrue(digest.admit(hostDown))
        for _ in 0..<479 { XCTAssertFalse(digest.admit(hostDown)) }
        // Farklı bir gönderim hatası da bir kez yazılır; gönderim hatası olmayan satırlar hep yazılır.
        XCTAssertTrue(digest.admit("Discovery failed to send: Network is unreachable"))
        XCTAssertTrue(digest.admit("Discovery thread failed to read"))
        XCTAssertTrue(digest.admit("Discovery thread failed to read"))
        XCTAssertEqual(digest.summary(targets: 254),
                       ["[chiaki error] \(hostDown) (bu PS5 aramasında toplam 480 kez, 254 adrese soruldu)"])
    }

    func testNoSummaryWithoutRepeats() {
        let digest = Console.SendErrorDigest()
        XCTAssertTrue(digest.admit("Discovery failed to send: Host is down"))
        XCTAssertEqual(digest.summary(targets: 10), [])
    }

    func testLoggerSkipsFilteredLinesButStillReportsThem() {
        let written = Lines()
        let seen = Lines()
        RemotePlayLog.observe { written.add($0) }
        defer { RemotePlayLog.observe(nil) }
        let logger = ChiakiLogger()
        let digest = Console.SendErrorDigest()
        logger.shouldWrite = { digest.admit($0) }
        logger.onMessage = { text, _ in seen.add(text) }
        func log(_ text: String) {
            text.withCString { logger.pointer.pointee.cb(CHIAKI_LOG_ERROR, $0, logger.pointer.pointee.user) }
        }
        for _ in 0..<5 { log("Discovery failed to send: Host is down") }
        log("Session connect failed")
        withExtendedLifetime(logger) {}
        XCTAssertEqual(written.items, ["[chiaki error] Discovery failed to send: Host is down",
                                       "[chiaki error] Session connect failed"])
        XCTAssertEqual(seen.items.count, 6)
    }
}
