// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import XCTest
@testable import CouchSubs

/// LG OLED CX (webOS 5): kurulum "ipk verified failed" (errorCode -5). TV'nin saati okunur ve günlüğe yazılır; çok
/// gerideyse kullanıcıya saati düzeltmesi söylenir (Mac, Windows ve Android'deki LG kurulumuyla aynı).
final class LGVerifyFailureTests: XCTestCase {
    private final class FakeShell: LGShell {
        var commands: [String] = []
        var clock: String
        init(clock: String) { self.clock = clock }

        func run(_ command: String, input: [UInt8]?) throws -> CommandResult {
            commands.append(command)
            if command.contains("wc -c") { return CommandResult(status: 0, output: "4\n") }
            if command.contains("appInstallService/dev/install") {
                return CommandResult(status: 0, output: #"{"details":{"state":"FAILED_IPKG_INSTALL","verified":false,"errorCode":-5,"reason":"ipk verified failed"},"returnValue":true}"#)
            }
            if command == DevModeInstaller.clockCommand { return CommandResult(status: 0, output: clock) }
            return CommandResult(status: 0, output: "")
        }
    }

    private func install(clock: String) -> (LGInstallFailure?, FakeShell) {
        let shell = FakeShell(clock: clock)
        let installer = LGInstaller(shell: shell)
        do {
            try installer.install(ipk: [1, 2, 3, 4], packageName: "com.couchsubs.tv_0.9.113_all.ipk", version: "0.9.113")
            return (nil, shell)
        } catch {
            return (error as? LGInstallFailure, shell)
        }
    }

    func testClockFarBehindAsksToFixTheTVClock() {
        let (failure, shell) = install(clock: "1577838229\n") // 2020-01-01 00:23:49 UTC
        XCTAssertEqual(failure?.error, .tvClockWrong)
        XCTAssertTrue(failure?.detail?.hasPrefix("ipk verified failed (errorCode -5); TV saati 2020-01-01 00:23:49 UTC") == true)
        XCTAssertTrue(shell.commands.contains(DevModeInstaller.clockCommand))
        XCTAssertTrue(shell.commands.last?.hasPrefix("rm -f '/media/developer/temp/com.couchsubs.tv_0.9.113_all.ipk'") == true)
    }

    func testRightClockStaysAnInstallFailureWithTheVerifyHint() {
        let (failure, _) = install(clock: "\(Int(Date().timeIntervalSince1970))")
        XCTAssertEqual(failure?.error, .installFailed)
        XCTAssertTrue(failure?.detail.map(DevModeInstaller.isPackageVerifyFailure) == true)
        XCTAssertTrue(failure?.detail?.contains("TV saati") == true)
    }

    func testUnreadableClockStaysAnInstallFailure() {
        let (failure, _) = install(clock: "sh: date: not found")
        XCTAssertEqual(failure?.error, .installFailed)
        XCTAssertEqual(failure?.detail, "ipk verified failed (errorCode -5); TV saati okunamadı")
    }
}
