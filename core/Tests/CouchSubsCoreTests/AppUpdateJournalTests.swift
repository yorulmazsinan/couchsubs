// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class AppUpdateJournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("update-journal-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func journal(build: Int, version: String, path: String = "/Applications/CouchSubs.app") -> AppUpdateJournal {
        AppUpdateJournal(file: directory.appendingPathComponent("guncelleme-denemesi.json"),
                         currentVersion: version, currentBuild: build, currentPath: path)
    }

    func testNoAttemptMeansNoFailure() {
        XCTAssertNil(journal(build: 1345, version: "0.1.0-beta.107").failedAttempt())
    }

    func testReachingTheTargetClearsTheRecord() {
        let before = journal(build: 1339, version: "0.1.0-beta.106")
        before.record(targetVersion: "0.1.0-beta.107", targetBuild: 1345, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(before.read()?.targetBuild, 1345)
        let after = journal(build: 1345, version: "0.1.0-beta.107")
        XCTAssertNil(after.failedAttempt())
        XCTAssertNil(after.read(), "hedefe ulaşılınca kayıt silinir")
    }

    func testStillOldAfterInstallIsAFailedAttemptWithBothPaths() {
        // Güncellenen kopya İndirilenler'deki; açılan /Applications'taki eski kopya.
        let downloads = journal(build: 1339, version: "0.1.0-beta.106", path: "/Users/u/Downloads/CouchSubs.app")
        downloads.record(targetVersion: "0.1.0-beta.107", targetBuild: 1345, now: Date(timeIntervalSince1970: 100))
        let applications = journal(build: 1339, version: "0.1.0-beta.106")
        let failed = applications.failedAttempt()
        XCTAssertEqual(failed, AppUpdateAttempt(fromVersion: "0.1.0-beta.106", fromBuild: 1339, targetVersion: "0.1.0-beta.107",
                                                targetBuild: 1345, appPath: "/Users/u/Downloads/CouchSubs.app",
                                                at: Date(timeIntervalSince1970: 100)))
        XCTAssertNotNil(applications.read(), "başarısız deneme sonraki açılışa kadar kalır")
    }

    func testBuildNumberDecidesNotVersionText() {
        // "beta.99" metin olarak "beta.107"den büyük görünür; karşılaştırma yapı numarasıyla.
        let old = journal(build: 1271, version: "0.1.0-beta.99")
        old.record(targetVersion: "0.1.0-beta.107", targetBuild: 1345)
        XCTAssertNotNil(old.failedAttempt())
        XCTAssertNil(journal(build: 1346, version: "0.1.0-beta.108").failedAttempt())
    }

    func testBrokenRecordIsIgnored() throws {
        let file = directory.appendingPathComponent("guncelleme-denemesi.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: file)
        XCTAssertNil(journal(build: 1, version: "0.1.0").failedAttempt())
    }

    func testCopyLocation() {
        XCTAssertEqual(AppCopyLocation.of(path: "/Applications/CouchSubs.app"), .normal)
        XCTAssertEqual(AppCopyLocation.of(path: "/Users/u/Applications/CouchSubs.app"), .normal)
        XCTAssertEqual(AppCopyLocation.of(path: "/private/var/folders/x/T/AppTranslocation/ABC/d/CouchSubs.app"), .translocated)
        XCTAssertEqual(AppCopyLocation.of(path: "/Volumes/CouchSubs/CouchSubs.app"), .diskImage)
        XCTAssertTrue(AppCopyLocation.normal.canUpdateItself)
        XCTAssertFalse(AppCopyLocation.diskImage.canUpdateItself)
        XCTAssertFalse(AppCopyLocation.translocated.canUpdateItself)
    }

    func testNewerCopyElsewhere() {
        let running = AppCopy(path: "/Applications/CouchSubs.app", version: "0.1.0-beta.106", build: 1339)
        let copies = [
            AppCopy(path: "/Applications/CouchSubs.app/", version: "0.1.0-beta.106", build: 1339),
            AppCopy(path: "/Users/u/Downloads/CouchSubs.app", version: "0.1.0-beta.107", build: 1345),
            AppCopy(path: "/Users/u/Desktop/CouchSubs.app", version: "0.1.0-beta.99", build: 1271),
        ]
        XCTAssertEqual(AppCopy.newerElsewhere(than: running, in: copies)?.path, "/Users/u/Downloads/CouchSubs.app")
        let newest = AppCopy(path: "/Applications/CouchSubs.app", version: "0.1.0-beta.107", build: 1345)
        XCTAssertNil(AppCopy.newerElsewhere(than: newest, in: copies))
        XCTAssertEqual(copies[1].logText, "/Users/u/Downloads/CouchSubs.app 0.1.0-beta.107 (1345)")
    }
}

final class AppUpdateIssueTests: XCTestCase {
    private let current = AppCopy(path: "/Applications/CouchSubs.app", version: "0.1.0-beta.106", build: 1339)
    private let newer = AppCopy(path: "/Users/u/Downloads/CouchSubs.app", version: "0.1.0-beta.107", build: 1345)
    private let attempt = AppUpdateAttempt(fromVersion: "0.1.0-beta.106", fromBuild: 1339, targetVersion: "0.1.0-beta.107",
                                           targetBuild: 1345, appPath: "/Users/u/Downloads/CouchSubs.app", at: Date())

    func testNothingToSay() {
        XCTAssertNil(AppUpdateIssue.atLaunch(failed: nil, location: .normal, current: current, copies: [current]))
    }

    func testFailedAttemptComesFirstAndNamesTheNewerCopy() {
        XCTAssertEqual(AppUpdateIssue.atLaunch(failed: attempt, location: .diskImage, current: current, copies: [current, newer]),
                       .failed(attempt, newerCopy: newer))
    }

    func testCopyThatCannotUpdateItself() {
        XCTAssertEqual(AppUpdateIssue.atLaunch(failed: nil, location: .translocated, current: current, copies: [newer]),
                       .cannotUpdateItself(.translocated))
    }

    func testNewerCopyElsewhere() {
        XCTAssertEqual(AppUpdateIssue.atLaunch(failed: nil, location: .normal, current: current, copies: [current, newer]),
                       .newerCopyElsewhere(newer))
    }
}
