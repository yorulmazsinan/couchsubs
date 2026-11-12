// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

/// Ayarlardaki görünüm: varsayılan koyu, kaydedilip geri okunur (Windows ile aynı testler).
final class AppAppearanceTests: XCTestCase {
    func testNewSettingsAreDark() {
        XCTAssertEqual(UserSettings().appearance, .dark)
    }

    func testExistingSettingsOpenDark() throws {
        let old = try JSONDecoder().decode(UserSettings.self,
                                           from: Data(#"{"sourceLanguage":"en","style":{"fontSize":58},"gamePacks":false}"#.utf8))
        XCTAssertEqual(old.appearance, .dark)
        XCTAssertEqual(old.style.fontSize, 58)
        XCTAssertFalse(old.gamePacks)
    }

    func testUnknownAppearanceOpensDarkAndKeepsOtherSettings() throws {
        let saved = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"appearance":"sepia","targetLanguage":"de"}"#.utf8))
        XCTAssertEqual(saved.appearance, .dark)
        XCTAssertEqual(saved.targetLanguage, "de")
    }

    func testAppearanceRoundTrips() throws {
        for appearance in AppAppearance.allCases {
            var settings = UserSettings()
            settings.appearance = appearance
            let data = try JSONEncoder().encode(settings)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""appearance":"\#(appearance.rawValue)""#))
            XCTAssertEqual(try JSONDecoder().decode(UserSettings.self, from: data).appearance, appearance)
        }
    }
}
