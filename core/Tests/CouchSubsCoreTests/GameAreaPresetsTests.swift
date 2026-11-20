// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Oyuna göre hazır ek alanlar (Windows: GameAreaPresetsTests.cs, Android: GameAreaPresetsTest.kt).
final class GameAreaPresetsTests: XCTestCase {
    func testTableKnowsGta6ByAnyName() {
        XCTAssertEqual(GameAreaPresets.areas("Grand Theft Auto VI").map(\.id), ["preset-help", "preset-phone"])
        XCTAssertEqual(GameAreaPresets.areas("GTA 6").map(\.id), ["preset-help", "preset-phone"])
        XCTAssertEqual(GameAreaPresets.areas("GTA 6")[0].region, CropRegion(top: 0.02, bottom: 0.28, left: 0.01, right: 0.36))
        XCTAssertEqual(GameAreaPresets.areas("GTA 6")[1].region, CropRegion(top: 0.45, bottom: 0.80, left: 0.72, right: 0.99))
        XCTAssertTrue(GameAreaPresets.areas("Red Dead Redemption 2").isEmpty)
        XCTAssertTrue(GameAreaPresets.areas(nil).isEmpty)
    }

    func testPresetsAreUsedOnlyWithoutOwnAreas() {
        var settings = UserSettings()
        XCTAssertEqual(settings.watchedExtraAreas(game: "GTA 6").map(\.id), ["preset-help", "preset-phone"])
        // Oyun değişince kalkar.
        XCTAssertTrue(settings.watchedExtraAreas(game: "Red Dead Redemption 2").isEmpty)
        XCTAssertTrue(settings.watchedExtraAreas(game: nil).isEmpty)
        // Telefon açıkken mesaj alanı okunmaz.
        XCTAssertEqual(settings.watchedExtraAreas(game: "GTA 6", phoneOpen: true).map(\.id), ["preset-help"])
        // Kullanıcının kendi alanı varsa yalnız o.
        settings.addExtraArea(.quest, name: "Görev")
        XCTAssertEqual(settings.watchedExtraAreas(game: "GTA 6").map(\.name), ["Görev"])
        // Kapalı kendi alanı sayılmaz.
        settings.updateExtraArea(id: settings.extraAreas[0].id) { $0.enabled = false }
        XCTAssertEqual(settings.watchedExtraAreas(game: "GTA 6").count, 2)
    }

    func testPresetsRespectSettingFullScreenAndProfile() {
        var settings = UserSettings()
        settings.gameAreaPresets = false
        XCTAssertTrue(settings.watchedExtraAreas(game: "GTA 6").isEmpty)
        settings.gameAreaPresets = true
        settings.areaPreset = .full
        XCTAssertTrue(settings.watchedExtraAreas(game: "GTA 6").isEmpty)
        settings.areaPreset = .bottom
        settings.activeAreaProfile = AreaProfiles.key("GTA 6", source: .stream)
        XCTAssertTrue(settings.watchedExtraAreas(game: "GTA 6").isEmpty)
    }

    func testOldSettingsTurnPresetsOn() throws {
        let old = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"showSpeakerNames": false}"#.utf8))
        XCTAssertTrue(old.gameAreaPresets)
        XCTAssertFalse(old.showSpeakerNames)
    }
}
