// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubs
import CouchSubsCore

/// TV uygulaması güncellemesi takılınca: adımın süresi dolar, bağlantı kapatılır, bir kez daha denenir; yine takılırsa
/// "bağlantı koptu, tekrar dene" gösterilir (Windows TvStallTests ve Android TvStallTest ile aynı durumlar).
final class TVStallTests: XCTestCase {
    private func short(_ seconds: TimeInterval) -> (String) -> TimeInterval? {
        { $0 == "signin" || $0 == "play" ? nil : seconds }
    }

    /// Günlük geçici klasöre yazılır (gerçek tvinstall.log'a değil).
    private func scratchLog() -> InstallLog {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("TVStallTests-\(UUID().uuidString).log")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return InstallLog(file: file)
    }

    func testStalledStepClosesTheConnectionAndFails() {
        let stall = TVStall(limits: short(0.1))
        let closed = DispatchSemaphore(value: 0)
        stall.onStall { closed.signal() }
        XCTAssertThrowsError(try stall.run { () -> Int in
            stall.enter("installing")
            // Bloklayan okuma: bağlantı kapanınca hatayla döner.
            _ = closed.wait(timeout: .now() + 5)
            throw StreamClosed()
        }) { error in
            let timeout = error as? TVStepTimeout
            XCTAssertEqual(timeout?.step, "installing")
            XCTAssertTrue(timeout?.description.contains("paket gönderme ve kurulum") == true)
        }
    }

    func testEachStepGetsItsOwnTime() throws {
        let stall = TVStall(limits: short(0.3))
        let result = try stall.run { () -> Int in
            for step in ["reading", "closing", "installing", "launching"] {
                stall.enter(step)
                Thread.sleep(forTimeInterval: 0.15)
            }
            return 42
        }
        XCTAssertEqual(result, 42)
    }

    /// Samsung girişi ve TV'deki Play sayfası kullanıcıyı bekler: süre işlemez.
    func testStepsWaitingForTheUserHaveNoLimit() throws {
        let stall = TVStall(limits: short(0.1))
        let result = try stall.run { () -> String in
            stall.enter(.signIn)
            Thread.sleep(forTimeInterval: 0.4)
            return "tamam"
        }
        XCTAssertEqual(result, "tamam")
    }

    /// Takılan bağlantının hatasını yutan adım ("açılamadı, kurulum yine tamam") da başarı sayılmaz.
    func testSwallowedErrorAfterStallStillCountsAsStall() {
        let stall = TVStall(limits: short(0.1))
        XCTAssertThrowsError(try stall.run { () -> Int in
            stall.enter(.launching)
            Thread.sleep(forTimeInterval: 0.4)
            return 1
        }) { XCTAssertTrue($0 is TVStepTimeout) }
    }

    func testStallIsRetriedOnceWithAFreshAttempt() throws {
        var attempts: [Int] = []
        let log = scratchLog()
        let result = try TVStall.retryOnce(log: log, retryable: SamsungInstaller.isRetryable) { attempt -> String in
            attempts.append(attempt)
            if attempt == 1 { throw TVStepTimeout(step: "installing", limit: 360) }
            return "0.9.104"
        }
        XCTAssertEqual(result, "0.9.104")
        XCTAssertEqual(attempts, [1, 2])
        XCTAssertTrue((try? String(contentsOf: log.file, encoding: .utf8))?.contains("bir kez daha deneniyor") == true)
    }

    func testSecondStallIsReported() {
        var attempts = 0
        XCTAssertThrowsError(try TVStall.retryOnce(log: scratchLog(), retryable: AndroidTvInstaller.isRetryable) { _ -> String in
            attempts += 1
            throw TVStepTimeout(step: "launching", limit: 60)
        }) { error in
            XCTAssertTrue((error as? TVStepTimeout)?.gaveUp.contains("bir kez daha denendi") == true)
        }
        XCTAssertEqual(attempts, 2)
    }

    func testOnlyStallsAndDroppedConnectionsAreRetried() {
        XCTAssertTrue(SamsungInstaller.isRetryable(TVStepTimeout(step: "reading", limit: 60)))
        XCTAssertTrue(SamsungInstaller.isRetryable(StreamClosed()))
        XCTAssertTrue(SamsungInstaller.isRetryable(SamsungInstallFailure(error: .connectionLost, detail: nil)))
        // Geliştirici modu kapalı, Host PC IP yanlış, yer yok: yeniden denemek düzeltmez.
        XCTAssertFalse(SamsungInstaller.isRetryable(SamsungInstallFailure(error: .unreachable, detail: nil)))
        XCTAssertFalse(SamsungInstaller.isRetryable(SamsungInstallFailure(error: .notEnoughSpace, detail: nil)))
        XCTAssertFalse(AndroidTvInstaller.isRetryable(AndroidInstallFailure(error: .notApproved, detail: nil)))
    }

    /// Güncellemeden önce TV'de çalışan eski uygulama kapatılır; kapatılamasa da kurulum sürer.
    func testSamsungClosesTheRunningAppBeforeUpdating() {
        var sent: [String] = []
        var paused = false
        var lines: [String] = []
        SamsungInstaller.closeOverSdb(shell: { command in
            sent.append(command)
            if command.hasSuffix("CouchSubsT") { throw StreamClosed() }
            return "app_id[CouchSubsT.CouchSubs] kill success"
        }, pause: { paused = true }, log: { lines.append($0) })
        XCTAssertEqual(sent, ["0 was_kill CouchSubsT.CouchSubs", "0 was_kill CouchSubsT"])
        XCTAssertTrue(paused)
        XCTAssertEqual(lines.count, 2)
    }

    func testAndroidTvStopsTheAppWithForceStop() {
        XCTAssertEqual(AndroidTvInstaller.forceStopCommand, "shell:am force-stop com.couchsubs.tv")
    }

    /// #1221: önce kapanma isteği, beklenir; uygulama hâlâ çalışıyorsa ya da bilinemiyorsa am force-stop (Android ve
    /// Windows/Mac ile aynı sıra).
    func testAndroidTvAsksTheAppToExitBeforeForceStop() {
        var sent: [String] = []
        var slept: TimeInterval = 0
        let result = AndroidTvInstaller.stopApp(run: { command in
            sent.append(command)
            return command == AndroidTVApp.runningCommand ? "" : "Starting: Intent { cmp=com.couchsubs.tv/.MainActivity }"
        }, sleep: { slept += $0 })
        XCTAssertEqual(sent, [AndroidTVApp.exitCommand, AndroidTVApp.runningCommand, AndroidTvInstaller.forceStopCommand])
        XCTAssertEqual(slept, AndroidTvInstaller.exitWait)
        XCTAssertTrue(result.contains("am force-stop"))
    }

    /// #1221: kapanma isteğiyle kapanan uygulamaya am force-stop gönderilmez (HDMI'yı kendisi bıraktı).
    func testAndroidTvAppThatExitsOnRequestIsNotForceStopped() {
        var sent: [String] = []
        let result = AndroidTvInstaller.stopApp(run: { command in
            sent.append(command)
            return command == AndroidTVApp.runningCommand
                ? "    * Hist #0: ActivityRecord{2a1d9e1 u0 com.google.android.tvlauncher/.MainActivity t1}" : ""
        }, sleep: { _ in })
        XCTAssertEqual(sent, [AndroidTVApp.exitCommand, AndroidTVApp.runningCommand])
        XCTAssertTrue(result.contains("kapanma isteğiyle kapandı"))
    }

    func testEveryStepHasALimitExceptTheOnesWaitingForTheUser() {
        for step in ["connecting", "approve", "reading", "certificate", "signing", "closing", "installing", "uninstalling", "launching"] {
            XCTAssertNotNil(TVStall.limit(for: step), step)
        }
        XCTAssertNil(TVStall.limit(for: TVStall.key(.signIn)))
        XCTAssertNil(TVStall.limit(for: TVStall.key(.openPlay)))
    }
}
