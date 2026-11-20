// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

/// "Ekran yazılarını otomatik çevir" varsayılan kapalı; beta.63'te açık gelen ayar bir kez kapatılır (Windows
/// AutoScreenTextMigration, Android aynı kural).
final class AutoScreenTextMigrationTests: XCTestCase {
    func testOffByDefaultAndInOldSettings() throws {
        XCTAssertFalse(UserSettings().autoScreenText)
        let old = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"showSpeakerNames": false}"#.utf8))
        XCTAssertFalse(old.autoScreenText)
        XCTAssertFalse(old.autoScreenTextReset)
    }

    func testBeta63SettingIsTurnedOffOnceWithANotice() throws {
        var beta63 = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"autoScreenText": true}"#.utf8))
        XCTAssertTrue(beta63.migratingAutoScreenText())
        XCTAssertFalse(beta63.autoScreenText)
        XCTAssertTrue(beta63.autoScreenTextReset)
        // Kaydedilip yeniden açılınca göç tekrarlanmaz; kullanıcı açtıysa açık kalır.
        var reopened = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(beta63))
        reopened.autoScreenText = true
        XCTAssertFalse(reopened.migratingAutoScreenText())
        XCTAssertTrue(reopened.autoScreenText)
    }

    func testFreshInstallIsMigratedSilently() {
        var fresh = UserSettings()
        XCTAssertFalse(fresh.migratingAutoScreenText())
        XCTAssertFalse(fresh.autoScreenText)
        XCTAssertTrue(fresh.autoScreenTextReset)
    }

    /// Hazır alanlar kullanıcının altyazı alanını ve ek alanlarını değiştirmez (yalnız okunacak alan listesine eklenir).
    func testPresetAreasLeaveTheUsersAreasAlone() {
        var settings = UserSettings()
        settings.region = CropRegion(top: 0.7, bottom: 0.9, left: 0.2, right: 0.8)
        let before = settings
        _ = settings.watchedExtraAreas(game: "GTA 6", phoneOpen: false)
        XCTAssertEqual(settings, before)
        XCTAssertEqual(settings.region, CropRegion(top: 0.7, bottom: 0.9, left: 0.2, right: 0.8))
        XCTAssertTrue(settings.extraAreas.isEmpty)
    }
}
