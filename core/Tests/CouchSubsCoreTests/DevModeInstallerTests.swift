// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class DevModeInstallerTests: XCTestCase {
    final class FakeRunner: CommandRunning, @unchecked Sendable {
        var calls: [(executable: String, arguments: [String], input: URL?)] = []
        var answers: [(String) -> CommandResult?] = []
        func run(_ executable: String, _ arguments: [String], input: URL?) async throws -> CommandResult {
            calls.append((executable, arguments, input))
            let line = arguments.joined(separator: " ")
            for answer in answers { if let result = answer(line) { return result } }
            return CommandResult(status: 0, output: "")
        }
    }

    private func installer(_ runner: FakeRunner) -> DevModeInstaller {
        DevModeInstaller(host: "192.168.1.230", keyFile: URL(fileURLWithPath: "/tmp/key"), runner: runner,
                         pollInterval: .milliseconds(1), installTimeout: .milliseconds(200), verifyTimeout: .milliseconds(200))
    }

    private func isInstall(_ line: String) -> Bool { line.contains("appInstallService") }

    func testVersionIsReadFromThePackageName() {
        XCTAssertEqual(DevModeInstaller.version(ofPackage: "com.couchsubs.tv_0.6.1_all.ipk"), "0.6.1")
        XCTAssertNil(DevModeInstaller.version(ofPackage: "notes.txt"))
    }

    func testVersionComparisonIsNumeric() {
        XCTAssertTrue(DevModeInstaller.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(DevModeInstaller.isNewer("0.6.1", than: "0.4.0"))
        XCTAssertFalse(DevModeInstaller.isNewer("0.6.1", than: "0.6.1"))
        XCTAssertFalse(DevModeInstaller.isNewer("0.6.0", than: "0.6.1"))
    }

    func testVersionIsReadFromAppInfo() {
        XCTAssertEqual(DevModeInstaller.version(fromAppInfo: "{\n  \"id\": \"x\",\n  \"version\": \"0.4.0\"\n}"), "0.4.0")
        XCTAssertNil(DevModeInstaller.version(fromAppInfo: "cat: can't open"))
    }

    func testMissingAppHasNoVersion() async throws {
        let runner = FakeRunner()
        runner.answers = [{ _ in CommandResult(status: 1, output: "No such file") }]
        let version = try await installer(runner).installedVersion()
        XCTAssertNil(version)
    }

    func testRefusedKeyIsReportedAsAnAuthorizationProblem() async {
        let runner = FakeRunner()
        runner.answers = [{ _ in CommandResult(status: 255, output: "prisoner@tv: Permission denied (publickey).") }]
        do {
            _ = try await installer(runner).installedVersion()
            XCTFail("Hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? DevModeError, .keyRefused)
        }
    }

    func testUnreachableTVIsReportedSeparately() async {
        let runner = FakeRunner()
        runner.answers = [{ _ in CommandResult(status: 255, output: "ssh: connect to host port 9922: Operation timed out") }]
        do {
            _ = try await installer(runner).installedVersion()
            XCTFail("Hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? DevModeError, .unreachable)
        }
    }

    func testInstallUploadsThenAsksTheTVToInstallAndWaitsForTheVersion() async throws {
        let runner = FakeRunner()
        var reads = 0
        runner.answers = [{ line in
            guard line.contains("appinfo.json") else { return nil }
            reads += 1
            return CommandResult(status: 0, output: reads < 3 ? "\"version\": \"0.4.0\"" : "\"version\": \"0.6.1\"")
        }]
        let package = URL(fileURLWithPath: "/tmp/com.couchsubs.tv_0.6.1_all.ipk")
        try await installer(runner).install(package: package, version: "0.6.1")

        let remote = "/media/developer/temp/com.couchsubs.tv_0.6.1_all.ipk"
        XCTAssertEqual(runner.calls[0].input, package)
        // ares-install gibi: paket kendi adıyla yüklenir, eski CouchSubs paketleri önce silinir.
        XCTAssertTrue(runner.calls[0].arguments.last!.contains("cat > '\(remote)'"))
        XCTAssertTrue(runner.calls[0].arguments.last!.contains("rm -f /media/developer/temp/com.couchsubs.tv_*.ipk"))
        XCTAssertTrue(runner.calls[1].arguments.last!.contains("luna://com.webos.appInstallService/dev/install"))
        XCTAssertTrue(runner.calls[1].arguments.last!.contains("\"ipkUrl\":\"\(remote)\""))
        XCTAssertTrue(runner.calls.last!.arguments.last!.contains("rm -f '\(remote)'"))
    }

    func testInstallCommandKeepsTheSubscriptionOpenUntilTheTVAnswers() {
        let command = DevModeInstaller.installCommand(remotePackage: "/media/developer/temp/com.couchsubs.tv_0.9.6_all.ipk", waitSeconds: 180)
        // -n 1 ilk yanıttan sonra aboneliği kapatıyordu; ares-install -i kullanır ve sonucu bekler.
        XCTAssertFalse(command.contains("-n 1"))
        XCTAssertTrue(command.contains("/usr/bin/luna-send-pub -i 'luna://com.webos.appInstallService/dev/install'"))
        XCTAssertTrue(command.contains(#"{"id":"com.ares.defaultName","ipkUrl":"/media/developer/temp/com.couchsubs.tv_0.9.6_all.ipk","subscribe":true}"#))
        XCTAssertTrue(command.contains("while [ $i -lt 180 ]"))
        XCTAssertTrue(command.contains("sleep 210 </dev/null 2>/dev/null |"))
        XCTAssertTrue(command.contains("kill $L"))
    }

    func testInstallCommandIsTheSameAsOnWindows() {
        // Windows (DevModeInstaller.cs) aynı komutu kurar; ikisi ayrışmasın.
        let command = DevModeInstaller.installCommand(remotePackage: "/media/developer/temp/x.ipk", waitSeconds: 5)
        XCTAssertTrue(command.hasPrefix("rm -f /media/developer/temp/couchsubs-install.log; sleep 35 </dev/null 2>/dev/null | "))
        XCTAssertTrue(command.hasSuffix("; cat /media/developer/temp/couchsubs-install.log; kill $L 2>/dev/null; rm -f /media/developer/temp/couchsubs-install.log"))
    }

    func testRepliesAreReadLikeAresInstall() {
        let progress = "{\"returnValue\":true,\"subscribed\":true}\n{\"details\":{\"state\":\"installing\"},\"returnValue\":true}\n"
        XCTAssertEqual(DevModeInstaller.parseInstallReplies(progress), .init())
        XCTAssertTrue(DevModeInstaller.parseInstallReplies(progress + #"{"details":{"state":"installed"},"returnValue":true}"#).installed)
        XCTAssertTrue(DevModeInstaller.parseInstallReplies(#"{"details":{"state":"SUCCESS"}}"#).installed)

        let failed = DevModeInstaller.parseInstallReplies(
            progress + #"{"details":{"state":"install failed","reason":"Installation failure","errorCode":-5},"returnValue":true}"#)
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.reason, "Installation failure (errorCode -5)")

        XCTAssertEqual(DevModeInstaller.parseInstallReplies(#"{"returnValue":false,"errorCode":-1,"errorText":"Denied method call"}"#),
                       .init(failed: true, reason: "Denied method call (errorCode -1)"))
        // Birden çok satıra bölünmüş yanıt ve JSON olmayan satırlar.
        XCTAssertTrue(DevModeInstaller.parseInstallReplies("Error: something\n{\"details\":\n{\"state\":\"installed\"}}\n").installed)
    }

    func testInstallReportsTheTVsReasonAndRemovesThePackage() async {
        let runner = FakeRunner()
        runner.answers = [{ [self] line in
            isInstall(line) ? CommandResult(status: 0, output: "{\"returnValue\":true}\n" + #"{"details":{"state":"FAILED_IPK_INSTALL","reason":"Invalid package"},"returnValue":true}"#) : nil
        }]
        do {
            try await installer(runner).install(package: URL(fileURLWithPath: "/tmp/a.ipk"), version: "0.6.1")
            XCTFail("Hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? DevModeFailure, DevModeFailure(.installFailed, detail: "Invalid package"))
        }
        XCTAssertTrue(runner.calls.last!.arguments.last!.contains("rm -f '/media/developer/temp/a.ipk'"))
        XCTAssertFalse(runner.calls.contains { $0.arguments.last!.contains("appinfo.json") })
    }

    func testStorageErrorsAreReportedAsMissingSpace() async {
        let runner = FakeRunner()
        runner.answers = [{ [self] line in
            isInstall(line) ? CommandResult(status: 0, output: #"{"details":{"state":"install failed","reason":"Not enough space"},"returnValue":true}"#) : nil
        }]
        do {
            try await installer(runner).install(package: URL(fileURLWithPath: "/tmp/a.ipk"), version: "0.6.1")
            XCTFail("Hata bekleniyordu")
        } catch {
            XCTAssertEqual((error as? DevModeFailure)?.error, .notEnoughSpace)
        }
    }

    func testInstalledReplyIsConfirmedByTheVersion() async throws {
        let runner = FakeRunner()
        runner.answers = [{ [self] line in
            if isInstall(line) { return CommandResult(status: 0, output: #"{"details":{"state":"installed"},"returnValue":true}"#) }
            return line.contains("appinfo.json") ? CommandResult(status: 0, output: "\"version\": \"0.6.1\"") : nil
        }]
        try await installer(runner).install(package: URL(fileURLWithPath: "/tmp/a.ipk"), version: "0.6.1")
        XCTAssertTrue(runner.calls.last!.arguments.last!.contains("rm -f '/media/developer/temp/a.ipk'"))
    }

    func testInstallTimesOutWhenTheVersionNeverChanges() async {
        let runner = FakeRunner()
        runner.answers = [{ line in line.contains("appinfo.json") ? CommandResult(status: 0, output: "\"version\": \"0.4.0\"") : nil }]
        do {
            try await installer(runner).install(package: URL(fileURLWithPath: "/tmp/a.ipk"), version: "0.6.1")
            XCTFail("Hata bekleniyordu")
        } catch {
            XCTAssertEqual((error as? DevModeFailure)?.error, .installFailed)
        }
        // TV sonuç vermediyse kurulum sürüyor olabilir; paket silinmez.
        XCTAssertFalse(runner.calls.dropFirst().contains { $0.arguments.last!.hasPrefix("rm -f '") })
    }

    func testFailedUploadStopsBeforeInstalling() async {
        let runner = FakeRunner()
        runner.answers = [{ line in line.contains("cat >") ? CommandResult(status: 1, output: "cat: write error: No space left on device") : nil }]
        do {
            try await installer(runner).install(package: URL(fileURLWithPath: "/tmp/a.ipk"), version: "0.6.1")
            XCTFail("Hata bekleniyordu")
        } catch {
            XCTAssertEqual((error as? DevModeFailure)?.error, .notEnoughSpace)
        }
        XCTAssertFalse(runner.calls.contains { $0.arguments.last!.contains("appInstallService") })
    }

    func testSshUsesTheTVPortKeyAndOldKeyTypes() async throws {
        let runner = FakeRunner()
        _ = try await installer(runner).installedVersion()
        let arguments = runner.calls[0].arguments
        XCTAssertEqual(runner.calls[0].executable, "/usr/bin/ssh")
        XCTAssertTrue(arguments.contains("9922"))
        XCTAssertTrue(arguments.contains("/tmp/key"))
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
        XCTAssertTrue(arguments.contains("PubkeyAcceptedAlgorithms=+ssh-rsa"))
        XCTAssertTrue(arguments.contains("prisoner@192.168.1.230"))
    }

    func testRemainingSessionTimeIsReadFromLGsReply() {
        XCTAssertEqual(DevModeInstaller.remainingHours(#"{"result":"success","errorCode":"200","errorMsg":"999:58:40"}"#), 999)
        XCTAssertNil(DevModeInstaller.remainingHours(#"{"result":"fail"}"#))
    }

    func testRenewalAddressCarriesTheSessionToken() {
        XCTAssertEqual(DevModeInstaller.renewURL(token: "ab12").absoluteString,
                       "https://developer.lge.com/secure/ResetDevModeSession.dev?sessionToken=ab12")
    }

    func testKeyServerAddress() {
        XCTAssertEqual(DevModeInstaller.keyURL(host: "192.168.1.230")?.absoluteString, "http://192.168.1.230:9991/webos_rsa")
        XCTAssertNil(DevModeInstaller.keyURL(host: "192.168.1.230:3000"))
    }
}
