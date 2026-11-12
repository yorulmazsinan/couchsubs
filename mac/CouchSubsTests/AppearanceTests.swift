// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import XCTest
@testable import CouchSubs

/// Ayarlardaki görünüm uygulamanın tüm pencerelerine (NSApp.appearance) uygulanır; varsayılan koyu.
@MainActor
final class AppearanceTests: XCTestCase {
    func testDarkByDefaultAndAppliedAppWide() {
        defer { AppAppearance.dark.apply() }
        NSApplication.shared.appearance = nil
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        XCTAssertEqual(model.settings.appearance, .dark)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
        model.settings.appearance = .light
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)
        model.settings.appearance = .system
        XCTAssertNil(NSApplication.shared.appearance)
    }

    func testSavedAppearanceIsAppliedAtLaunch() {
        defer { AppAppearance.dark.apply() }
        let defaults = UserDefaults.isolated()
        AppModel(services: FakeServices(), store: MemoryStore(), defaults: defaults).settings.appearance = .light
        NSApplication.shared.appearance = nil
        let reopened = AppModel(services: FakeServices(), store: MemoryStore(), defaults: defaults)
        XCTAssertEqual(reopened.settings.appearance, .light)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)
    }
}
