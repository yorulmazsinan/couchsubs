// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Kol ikinci hesaba atanınca PS5 her yeniden bağlanışta kolu kapatıyor (Play yorumu 20 Kas): ipucu bağlantı koptuğunda
/// da görünmeli (Android MainAccountTipTest, Windows AppControllerTests ile aynı).
final class MainAccountTipTests: XCTestCase {
    func testShowsBeforeFirstSubtitle() {
        XCTAssertTrue(MainAccountTip.isVisible(ps5: true, demo: false, hasSubtitle: false, streaming: false))
        XCTAssertTrue(MainAccountTip.isVisible(ps5: true, demo: false, hasSubtitle: false, streaming: true))
    }

    func testHidesWhileSubtitlesFlow() {
        XCTAssertFalse(MainAccountTip.isVisible(ps5: true, demo: false, hasSubtitle: true, streaming: true))
    }

    func testShowsAgainWhenConnectionDropsAfterSubtitles() {
        XCTAssertTrue(MainAccountTip.isVisible(ps5: true, demo: false, hasSubtitle: true, streaming: false))
    }

    func testNeverForXboxOrDemo() {
        XCTAssertFalse(MainAccountTip.isVisible(ps5: false, demo: false, hasSubtitle: false, streaming: false))
        XCTAssertFalse(MainAccountTip.isVisible(ps5: true, demo: true, hasSubtitle: true, streaming: false))
    }
}
