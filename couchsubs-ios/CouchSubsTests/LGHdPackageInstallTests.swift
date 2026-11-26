// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import XCTest
@testable import CouchSubs

/// #1098: LG 43LH590V (Full HD, webOS 3.x) sayfanın yalnız sol üst 1280x720'sini çiziyordu. iPhone'dan kurulumda da
/// Full HD webOS 3.x TV'ye paket appinfo.json'da 1280x720 çözünürlükle gider (karar ve paket core'daki LgHdPackage;
/// Mac LgHdPackageTests.swift, Windows LgHdPackageTests.cs, Android LgHdPackageTest.kt aynı deneme dosyasını okur).
final class LGHdPackageInstallTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable { let reply: String; let hd: Bool; let model: String? }
        let systemInfo: [Case]
        let package: String
        let adaptedAppInfo: String
    }

    /// Simülatörde depo dosyası doğrudan okunur (core/Tests/CouchSubsCoreTests/Fixtures/lg-hd-package.json).
    private func fixture() throws -> Fixture {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("core/Tests/CouchSubsCoreTests/Fixtures/lg-hd-package.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private final class FakeShell: LGShell {
        var commands: [String] = []
        var uploaded: [UInt8]?
        let reply: String
        private var installed = "0.9.120"
        init(reply: String) { self.reply = reply }

        func run(_ command: String, input: [UInt8]?) throws -> CommandResult {
            commands.append(command)
            if command == LgHdPackage.systemInfoCommand { return CommandResult(status: 0, output: reply) }
            if command.contains("cat > ") { uploaded = input; return CommandResult(status: 0, output: "") }
            if command.contains("wc -c") { return CommandResult(status: 0, output: "\(uploaded?.count ?? 0)\n") }
            if command.contains("appInstallService/dev/install") {
                installed = "0.9.122"
                return CommandResult(status: 0, output: #"{"returnValue":true,"details":{"state":"installed"}}"#)
            }
            if command.contains("appinfo.json") { return CommandResult(status: 0, output: #"{"version":"\#(installed)"}"#) }
            return CommandResult(status: 0, output: "")
        }
    }

    private func install(reply: String, ipk: [UInt8]) throws -> FakeShell {
        let shell = FakeShell(reply: reply)
        var installer = LGInstaller(shell: shell)
        installer.log = InstallLog(file: FileManager.default.temporaryDirectory.appendingPathComponent("lg-hd-test-\(UUID().uuidString).log"))
        installer.pollInterval = 0.001
        installer.verifyTimeout = 1
        try installer.install(ipk: ipk, packageName: "com.couchsubs.tv_0.9.122_all.ipk", version: "0.9.122")
        return shell
    }

    func testFullHDWebOS3TVGetsThe720pPackage() throws {
        let fixture = try fixture()
        let ipk = [UInt8](Data(base64Encoded: fixture.package)!)
        let shell = try install(reply: fixture.systemInfo[0].reply, ipk: ipk)
        XCTAssertEqual(shell.commands.first, LgHdPackage.systemInfoCommand)
        let sent = try XCTUnwrap(shell.uploaded)
        XCTAssertEqual(sent, LgHdPackage.adapt(ipk))
        XCTAssertNotEqual(sent, ipk)
        XCTAssertTrue(fixture.adaptedAppInfo.contains(#""resolution": "1280x720" ,"#))
    }

    func testOtherTVsGetThePackageUnchanged() throws {
        let fixture = try fixture()
        let ipk = [UInt8](Data(base64Encoded: fixture.package)!)
        for item in fixture.systemInfo where !item.hd {
            XCTAssertEqual(try install(reply: item.reply, ipk: ipk).uploaded, ipk, item.model ?? "-")
        }
    }
}
