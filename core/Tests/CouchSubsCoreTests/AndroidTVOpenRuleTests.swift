// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// X'te bildirildi (Android TV 8, çeviri MacBook'tan, beta.74): "TV'den uygulamayı açtığımda çevirili ekran gelip hemen başka
/// bir ekrana geçiyor, HDMI seçemiyorum". Bekçi bağlı görmediği her an 30 sn'de bir, sınırsız `am start` gönderiyordu.
final class AndroidTVOpenRuleTests: XCTestCase {
    func testConnectedAppIsNeverReopenedInTheSameSession() {
        var rule = AndroidTVOpenRule()
        XCTAssertTrue(rule.shouldTry(connected: false, now: 0))
        rule.opened()
        XCTAssertFalse(rule.shouldTry(connected: true, now: 5))
        // Kullanıcı CouchSubs'ı kumandadan açtı (katmanın bağlantısı kapandı) ya da TV'nin kendi girişine geçti.
        for second in stride(from: 10.0, through: 600, by: 5) {
            XCTAssertFalse(rule.shouldTry(connected: false, now: second))
        }
        XCTAssertEqual(rule.opens, 1)
    }

    func testNeverConnectedAppIsOpenedAtMostThreeTimesThirtySecondsApart() {
        var rule = AndroidTVOpenRule()
        var tries: [Double] = []
        for second in stride(from: 0.0, through: 600, by: 5) where rule.shouldTry(connected: false, now: second) {
            tries.append(second)
            rule.opened()
        }
        XCTAssertEqual(tries, [0, 30, 60])
    }

    /// X (beta.77): "izni sürekli yeniden istiyor". Uygulama TV'de çalışırken bulunduysa ya da TV onay sorduysa (`am start`
    /// gönderilmedi) eskiden deneme sayılmıyor, bekçi çeviri boyunca 30 sn'de bir ADB bağlantısı açıyordu. Her bağlantı sayılır.
    func testEveryAdbConnectionCountsEvenWhenNothingWasOpened() {
        var rule = AndroidTVOpenRule()
        var tries: [Double] = []
        for second in stride(from: 0.0, through: 3600, by: 5) where rule.shouldTry(connected: false, now: second) {
            tries.append(second)
        }
        XCTAssertEqual(tries, [0, 30, 60])
        XCTAssertEqual(rule.attempts, 3)
        XCTAssertEqual(rule.opens, 0)
    }

    func testResetAllowsOpeningAgainWithoutWaiting() {
        var rule = AndroidTVOpenRule()
        XCTAssertFalse(rule.shouldTry(connected: true, now: 0))
        XCTAssertFalse(rule.shouldTry(connected: false, now: 100))
        rule.reset()
        XCTAssertTrue(rule.shouldTry(connected: false, now: 101))
    }

    func testRunningAppIsRecognisedFromActivityStacksAndServices() {
        // Android 8: ekran arka planda (kullanıcı TV'nin kendi HDMI girişinde) yığında durur.
        let background = """
              * Hist #0: ActivityRecord{6c1b2f0 u0 com.couchsubs.tv/.MainActivity t42}
              * Hist #0: ActivityRecord{2a1d9e1 u0 com.android.tv.launcher/.MainActivity t1}
            """
        XCTAssertTrue(AndroidTVApp.isRunning(background))
        // Katman: ekran kapalı, servis çalışıyor.
        XCTAssertTrue(AndroidTVApp.isRunning("""
              * Hist #0: ActivityRecord{2a1d9e1 u0 com.android.tv.launcher/.MainActivity t1}
              * ServiceRecord{9f3e2a1 u0 com.couchsubs.tv/.OverlayService}
            """))
        XCTAssertFalse(AndroidTVApp.isRunning("    * Hist #0: ActivityRecord{2a1d9e1 u0 com.android.tv.launcher/.MainActivity t1}"))
        // Kapanmış uygulamanın izi (son duraklatılan) çalışıyor sayılmaz; grep'i olmayan TV'de çıktı boş ya da hata.
        XCTAssertFalse(AndroidTVApp.isRunning("  mLastPausedActivity: ActivityRecord{6c1b2f0 u0 com.couchsubs.tv/.MainActivity t42}"))
        XCTAssertFalse(AndroidTVApp.isRunning(""))
        XCTAssertFalse(AndroidTVApp.isRunning("/system/bin/sh: grep: not found"))
        XCTAssertEqual(AndroidTVApp.runningCommand,
                       "shell:dumpsys activity activities | grep Hist; dumpsys activity services com.couchsubs.tv | grep ServiceRecord")
    }
}
