// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import XCTest

/// Tek tuş kurulumun komut üretimi: Mac IP katı doğrulanır, indirme/çalıştırma satırı beklenen biçimde.
final class VestelInstallTests: XCTestCase {
    func testSafeIPv4() {
        XCTAssertTrue(VestelInstall.safeIPv4("192.168.1.44"))
        XCTAssertTrue(VestelInstall.safeIPv4("10.0.0.1"))
        XCTAssertFalse(VestelInstall.safeIPv4("192.168.1"))            // eksik
        XCTAssertFalse(VestelInstall.safeIPv4("192.168.1.256"))        // > 255
        XCTAssertFalse(VestelInstall.safeIPv4("192.168.1.1; rm -rf /")) // enjeksiyon
        XCTAssertFalse(VestelInstall.safeIPv4("example.com"))          // IP değil
        XCTAssertFalse(VestelInstall.safeIPv4(""))
    }

    func testInstallLine() {
        let line = VestelInstall.installLine(macAddress: "192.168.1.44", serverPort: 8787)
        XCTAssertTrue(line.contains("http://192.168.1.44:8787/vestel-tv-client"))
        XCTAssertTrue(line.contains("chmod +x couchsubs-vestel-tv"))
        XCTAssertTrue(line.contains("nohup ./couchsubs-vestel-tv 192.168.1.44 8787"))
        XCTAssertTrue(line.contains("kill $(pidof couchsubs-vestel-tv)"))   // eskisini durdur
        XCTAssertTrue(line.contains("kill $(pidof telnetd)"))               // telnetd'yi kapat
        XCTAssertTrue(line.hasSuffix("\n"))
    }

    func testInstallLineWithoutClosingShell() {
        let line = VestelInstall.installLine(macAddress: "10.0.0.2", serverPort: 9000, closeShell: false)
        XCTAssertFalse(line.contains("kill $(pidof telnetd)"))
        XCTAssertTrue(line.contains("10.0.0.2:9000/vestel-tv-client"))
    }

    func testOpenShellLineUnchanged() {
        // Bu TV'de doğrulanan satır; değişirse root kabuğu açılmaz.
        XCTAssertEqual(VestelInstall.openShellLine, "/bin/telnetd -p 2323 -l /bin/sh\n")
    }
}
