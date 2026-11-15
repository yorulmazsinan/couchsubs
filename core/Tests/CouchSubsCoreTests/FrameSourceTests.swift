// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

/// Görüntü kaynağı ayarı: yeni ve eski kayıtlar PS5 bağlantısıyla açılır, seçim kaydedilip geri okunur.
final class FrameSourceTests: XCTestCase {
    func testNewSettingsReadThePS5() {
        XCTAssertEqual(UserSettings().frameSource, .ps5)
    }

    func testExistingSettingsReadThePS5AndKeepOtherSettings() throws {
        let old = try JSONDecoder().decode(UserSettings.self,
                                           from: Data(#"{"sourceLanguage":"en","output":"computer","gamePacks":false}"#.utf8))
        XCTAssertEqual(old.frameSource, .ps5)
        XCTAssertEqual(old.output, .computer)
        XCTAssertFalse(old.gamePacks)
    }

    func testUnknownSourceOpensPS5AndKeepsOtherSettings() throws {
        let saved = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"frameSource":"capture-card","targetLanguage":"de"}"#.utf8))
        XCTAssertEqual(saved.frameSource, .ps5)
        XCTAssertEqual(saved.targetLanguage, "de")
    }

    func testRemotePlayAppDefaultsToWhicheverIsOpen() throws {
        XCTAssertEqual(UserSettings().remotePlayApp, .automatic)
        let old = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"frameSource":"remotePlayWindow"}"#.utf8))
        XCTAssertEqual(old.remotePlayApp, .automatic)
        let unknown = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"remotePlayApp":"xcloud","gamePacks":false}"#.utf8))
        XCTAssertEqual(unknown.remotePlayApp, .automatic)
        XCTAssertFalse(unknown.gamePacks)
    }

    func testRemotePlayAppRoundTrips() throws {
        for app in RemotePlayApp.allCases {
            var settings = UserSettings()
            settings.remotePlayApp = app
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(UserSettings.self, from: data).remotePlayApp, app)
        }
    }

    func testFrameSourceRoundTrips() throws {
        for source in FrameSource.allCases {
            var settings = UserSettings()
            settings.frameSource = source
            let data = try JSONEncoder().encode(settings)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""frameSource":"\#(source.rawValue)""#))
            XCTAssertEqual(try JSONDecoder().decode(UserSettings.self, from: data).frameSource, source)
        }
    }
}
