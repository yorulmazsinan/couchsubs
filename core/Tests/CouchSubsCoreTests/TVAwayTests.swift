// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore

/// #1303: arka plandayken TV bağlantısı koptuysa "CouchSubs'ı açık tutun" uyarısı (Android TvAwayTest ile aynı durumlar).
final class TVAwayTests: XCTestCase {
    func testLinkLostWhileAwayWarnsOncePerTrip() {
        var away = TVAway()
        away.left(linked: true)
        XCTAssertTrue(away.lost(at: 10))
        XCTAssertFalse(away.lost(at: 20))
        // Dönüşte TV hâlâ bağlı değil: aynı gezi için ikinci uyarı yok.
        XCTAssertFalse(away.returned(at: 30, linked: false))
        // Yeni gezi yeniden uyarabilir.
        away.left(linked: true)
        XCTAssertTrue(away.lost(at: 40))
    }

    /// iPhone askıdayken olay gelmez: TV giderken bağlıydı, dönüşte bağlı değil.
    func testTvMissingOnReturnWarns() {
        var away = TVAway()
        away.left(linked: true)
        XCTAssertTrue(away.returned(at: 100, linked: false))
    }

    /// Askıdan dönen soket dönüşten hemen sonra kapanır: kısa süre içindeki kopma da arka planda sayılır.
    func testLossRightAfterReturnCountsAsAway() {
        var away = TVAway()
        away.left(linked: true)
        XCTAssertFalse(away.returned(at: 100, linked: true))
        XCTAssertTrue(away.lost(at: 103))
    }

    func testLossLongAfterReturnIsNotAboutTheBackground() {
        var away = TVAway()
        away.left(linked: true)
        XCTAssertFalse(away.returned(at: 100, linked: true))
        XCTAssertFalse(away.lost(at: 100 + TVAway.defaultGrace + 1))
    }

    func testNoWarningWhileTheAppIsOnScreenOrTheTvWasNotLinked() {
        var away = TVAway()
        XCTAssertFalse(away.lost(at: 1))
        away.left(linked: false)
        XCTAssertFalse(away.returned(at: 5, linked: false))
        XCTAssertFalse(away.lost(at: 6))
    }

    func testResetForgetsTheTrip() {
        var away = TVAway()
        away.left(linked: true)
        away.reset()
        XCTAssertFalse(away.returned(at: 5, linked: false))
        XCTAssertFalse(away.away)
    }
}
