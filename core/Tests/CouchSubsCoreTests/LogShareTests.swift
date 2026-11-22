// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

/// "Günlükleri paylaş": paylaşılan dosyada kişisel veri kalmaz (Fixtures/log-redaction.json; Android LogShareTest.kt
/// aynı dosyayı okur), günlükler başlıklarıyla birleştirilir.
final class LogShareTests: XCTestCase {
    private struct Case: Decodable { let input: String; let expected: String }

    func testSharedRedactionCases() throws {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("log-redaction.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(cases.count, 10)
        for item in cases {
            XCTAssertEqual(LogShare.redact(item.input), item.expected, item.input)
        }
    }

    func testCombinesLogsWithBackupFirstAndMarksMissing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("log-share-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let remote = folder.appendingPathComponent("remoteplay.log")
        let subtitle = folder.appendingPathComponent("altyazi.log")
        try "PS5 kaydı başlıyor: 192.168.1.20, hesap kimliği q83vEjRWeJA=\n".write(to: remote, atomically: true, encoding: .utf8)
        try "eski satır\n".write(to: subtitle.appendingPathExtension("1"), atomically: true, encoding: .utf8)
        try "yeni satır".write(to: subtitle, atomically: true, encoding: .utf8)
        let out = try LogShare.write(header: "CouchSubs iOS 1.0.4", logs: [
            ("remoteplay.log", remote), ("altyazi.log", subtitle), ("tvinstall.log", folder.appendingPathComponent("yok.log")),
        ], to: folder.appendingPathComponent("share"))
        XCTAssertEqual(out.lastPathComponent, LogShare.fileName)
        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("CouchSubs iOS 1.0.4\n\n===== remoteplay.log =====\n"))
        XCTAssertTrue(text.contains("192.168.1.20, hesap kimliği ***"))
        XCTAssertFalse(text.contains("q83vEjRWeJA"))
        XCTAssertTrue(text.contains("===== altyazi.log =====\n\neski satır\nyeni satır\n"))
        XCTAssertTrue(text.hasSuffix("===== tvinstall.log =====\n\n(yok)\n"))
    }

    func testConnectingHintAppearsAfterThirtySeconds() {
        XCTAssertNil(ConnectingHint.text(seconds: 29, step: .waking))
        XCTAssertEqual(ConnectingHint.text(seconds: 30, step: .waking),
                       "The PS5 is being woken from rest mode. This can take up to a minute.")
        XCTAssertEqual(ConnectingHint.text(seconds: 45, step: .opening),
                       "The PS5 answered, but the connection is taking long. If it doesn't connect, stop and start translating again.")
        XCTAssertEqual(ConnectingHint.text(seconds: 60, step: .noAnswer), ConnectingHint.text(seconds: 60, step: nil))
        XCTAssertEqual(ConnectingHint.text(seconds: 60, step: nil),
                       "The PS5 is not answering. Make sure it is on and on the same network as this device.")
    }
}
