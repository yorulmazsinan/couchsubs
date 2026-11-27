// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

/// CouchSubs ile resmi PS Remote Play yan yana: günlük satırları ortak deneme dosyasından (Fixtures/remote-play-coexistence.json;
/// Windows RemotePlayCoexistenceTests.cs aynı dosyayı okur).
final class RemotePlayCoexistenceTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("remote-play-coexistence.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testLinesMatchTheSharedFixture() throws {
        let root = try fixture()
        for item in try XCTUnwrap(root["windowMode"] as? [[String: Any]]) {
            XCTAssertEqual(RemotePlayCoexistence.windowModeLine(app: item["app"] as! String), item["line"] as? String)
        }
        let gone = try XCTUnwrap(root["windowGone"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(gone.count, 6)
        for item in gone {
            let line = RemotePlayCoexistence.windowGoneLine(app: item["app"] as! String, pid: (item["pid"] as! NSNumber).intValue,
                                                            why: item["why"] as! String,
                                                            exited: (item["exited"] as? NSNumber)?.boolValue,
                                                            exitCode: (item["exitCode"] as? NSNumber)?.int64Value)
            XCTAssertEqual(line, item["line"] as? String)
        }
        for item in try XCTUnwrap(root["consoleConflict"] as? [[String: Any]]) {
            XCTAssertEqual(RemotePlayCoexistence.consoleConflictLine(app: item["app"] as! String, reason: item["reason"] as? String),
                           item["line"] as? String)
        }
    }

    func testCrashExitCodeIsShownAsHexAndCalledACrash() {
        XCTAssertTrue(RemotePlayCoexistence.windowGoneLine(app: "RemotePlay", pid: 1, why: "pencere kapandı", exited: true,
                                                           exitCode: 0xC000_0005).contains("0xC0000005 (uygulama çöktü)"))
    }
}
