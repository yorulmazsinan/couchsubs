// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import RemotePlay
import XCTest
@testable import CouchSubs

/// Altyazının bilgisayar ekranında gösterilmesi: ayar, TV'siz kurulum ve pencerenin aldığı satırlar.
@MainActor
final class ComputerScreenTests: XCTestCase {
    private let console = RegisteredConsole(host: "192.168.1.253", name: "PS5", registKey: Data(repeating: 0x31, count: 16), morning: Data(repeating: 2, count: 16))

    /// PS5 kurulu, TV yok.
    private func storeWithoutTV() -> MemoryStore {
        let store = MemoryStore()
        store.save(Data(repeating: 1, count: 8), for: StoreKey.accountId)
        store.save(console, for: StoreKey.console)
        return store
    }

    /// Sunucunun pencereye ilettiği olaylar ana kuyrukta işlenir; sıradakiler bitene kadar beklenir.
    private func drainMainQueue() async {
        let done = expectation(description: "ana kuyruk")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
    }

    func testExistingSettingsDefaultToTV() throws {
        let old = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"sourceLanguage":"en","style":{"fontSize":58}}"#.utf8))
        XCTAssertEqual(old.output, .tv)
        XCTAssertFalse(old.overlayClickThrough)
        XCTAssertEqual(old.style.fontSize, 58)
    }

    func testOutputAndClickThroughArePersisted() throws {
        let defaults = UserDefaults.isolated()
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: defaults)
        model.settings.output = .both
        model.settings.overlayClickThrough = true
        let reopened = AppModel(services: FakeServices(), store: MemoryStore(), defaults: defaults)
        XCTAssertEqual(reopened.settings.output, .both)
        XCTAssertTrue(reopened.settings.overlayClickThrough)
    }

    func testNoTVChoiceSkipsTVSetup() {
        let services = FakeServices()
        let model = AppModel(services: services, store: storeWithoutTV(), defaults: .isolated())
        model.step = .tv
        XCTAssertFalse(model.canAdvance)
        model.useComputerScreen()
        XCTAssertEqual(model.step, .test)
        XCTAssertEqual(model.settings.output, .computer)
        XCTAssertEqual(services.pairCount, 0)
        XCTAssertNil(model.tv)
    }

    func testSetupWithoutTVOpensMainScreenNextLaunch() {
        let store = storeWithoutTV()
        let defaults = UserDefaults.isolated()
        let model = AppModel(services: FakeServices(), store: store, defaults: defaults)
        // PS5 kayıtlı ama kurulum bitmemiş: sihirbaz TV adımından sürer.
        XCTAssertEqual(model.step, .tv)
        model.useComputerScreen()
        // Deneme ve isteğe bağlı "Daha iyi çeviri" adımları (Windows'taki testle aynı).
        model.advance()
        XCTAssertEqual(model.step, .betterTranslation)
        model.advance()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(AppModel(services: FakeServices(), store: store, defaults: defaults).step, .done)
    }

    func testSetupAgainForgetsCompletedSetup() {
        let store = storeWithoutTV()
        let defaults = UserDefaults.isolated()
        let model = AppModel(services: FakeServices(), store: store, defaults: defaults)
        model.step = .done
        model.resetSetup()
        XCTAssertEqual(AppModel(services: FakeServices(), store: store, defaults: defaults).step, .welcome)
    }

    func testStartWithoutTVShowsOnComputerOnly() async {
        let services = FakeServices()
        let model = AppModel(services: services, store: storeWithoutTV(), defaults: .isolated())
        model.settings.output = .computer
        XCTAssertTrue(model.canStart)
        await model.start()
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(services.streams.count, 1)
        // TV aranmaz, açık tutulmaz.
        XCTAssertTrue(services.keepers.isEmpty)
        XCTAssertEqual(services.pairCount, 0)
        model.stop()
    }

    func testTVOnlyWithoutTVCannotStart() async {
        let services = FakeServices()
        let model = AppModel(services: services, store: storeWithoutTV(), defaults: .isolated())
        XCTAssertFalse(model.canStart)
        await model.start()
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(services.streams.isEmpty)
    }

    func testChoosingTVWhileRunningStartsKeeper() async throws {
        let services = FakeServices()
        let store = storeWithoutTV()
        store.save(LGTV(name: "LG TV", host: "127.0.0.1"), for: StoreKey.tv)
        store.save("tv-key", for: StoreKey.tvKey)
        let model = AppModel(services: services, store: store, defaults: .isolated())
        model.settings.output = .computer
        await model.start()
        XCTAssertTrue(services.keepers.isEmpty)
        model.settings.output = .both
        XCTAssertEqual(services.keepers.count, 1)
        XCTAssertTrue(services.keepers[0].running)
        model.settings.output = .computer
        XCTAssertFalse(services.keepers[0].running)
        model.stop()
    }

    func testPairingTVAfterNoTVChoiceSendsSubtitlesToTV() async throws {
        let model = AppModel(services: FakeServices(), store: storeWithoutTV(), defaults: .isolated())
        model.settings.output = .computer
        try await model.pair(LGTV(name: "LG TV", host: "192.168.1.153"))
        XCTAssertEqual(model.settings.output, .tv)
    }

    func testClosingPhoneKeepsTheOtherOverlayRegions() {
        let model = AppModel(services: FakeServices(), store: storeWithoutTV(), defaults: .isolated())
        model.settings.output = .computer
        let box = TextBox(left: 0.4, top: 0.3, right: 0.6, bottom: 0.4)
        let message = ScreenTranslation.Item(source: "Hello", translation: "Merhaba", box: box, lineHeight: 0.03)
        model.overlayReceive(.gamePhone([message]))
        XCTAssertEqual(model.overlayPhoneItems, [message])
        XCTAssertTrue(model.overlayVisible)
        model.overlayReceive(.region(id: "quest", text: "Görev", box: box))
        model.overlayReceive(.gamePhone([]))
        XCTAssertTrue(model.overlayPhoneItems.isEmpty)
        XCTAssertEqual(model.overlayRegions.map(\.id), ["quest"])
    }

    /// Kendiliğinden bulunan ekran yazısı blokları stilleriyle saklanır; boş region olayı onları kaldırır.
    func testScreenTextBlocksAreKeptWithTheirStyleUntilCleared() {
        let model = AppModel(services: FakeServices(), store: storeWithoutTV(), defaults: .isolated())
        model.settings.output = .computer
        var item = ScreenTranslation.Item(source: "ROB VICKI'S BOSS", translation: "VİCKİ'NİN PATRONUNU SOY",
                                          box: TextBox(left: 0.02, top: 0.05, right: 0.3, bottom: 0.09), lineHeight: 0.03)
        item.style = PhoneTextStyle(background: "#14161E", foreground: "#F0F0F0")
        item.look = TextLook(bold: true, condensed: true, align: .left, upper: true, flat: true)
        model.overlayReceive(.screenText(id: "auto-1", items: [item]))
        XCTAssertEqual(model.overlayRegions.map(\.id), ["auto-1"])
        XCTAssertEqual(model.overlayRegions.first?.items, [item])
        XCTAssertEqual(model.overlayRegions.first?.box, item.box)
        XCTAssertTrue(model.overlayVisible)
        model.overlayReceive(.region(id: "auto-1", text: "", box: nil))
        XCTAssertTrue(model.overlayRegions.isEmpty)
    }

    func testTestSubtitleAppearsInComputerWindow() async {
        let model = AppModel(services: FakeServices(), store: storeWithoutTV(), defaults: .isolated())
        model.settings.output = .computer
        var now: TimeInterval = 100
        model.overlayClock = { now }
        model.sendTestSubtitle()
        await drainMainQueue()
        XCTAssertEqual(model.overlayLines.map(\.text), [String(localized: "This is a test subtitle. Can you see it on top of the game?")])
        XCTAssertTrue(model.overlayVisible)
        // Süresi (8 sn) dolunca pencere kendiliğinden gizlenir.
        now = 108
        model.overlayRefresh()
        XCTAssertTrue(model.overlayLines.isEmpty)
        XCTAssertFalse(model.overlayVisible)
    }

    func testTVOnlyKeepsComputerWindowHidden() async {
        let model = AppModel(services: FakeServices(), store: storeWithoutTV(), defaults: .isolated())
        model.sendTestSubtitle()
        await drainMainQueue()
        XCTAssertTrue(model.overlayLines.isEmpty)
        XCTAssertFalse(model.overlayVisible)
    }

    func testStopClearsComputerWindow() async {
        let model = AppModel(services: FakeServices(), store: storeWithoutTV(), defaults: .isolated())
        model.settings.output = .both
        await model.start()
        model.sendTestSubtitle()
        await drainMainQueue()
        XCTAssertFalse(model.overlayLines.isEmpty)
        model.stop()
        XCTAssertTrue(model.overlayLines.isEmpty)
    }

    func testAdjustingShowsWindowAndTakesClicks() {
        let model = AppModel(services: FakeServices(), store: storeWithoutTV(), defaults: .isolated())
        model.settings.output = .computer
        model.settings.overlayClickThrough = true
        XCTAssertFalse(model.overlayVisible)
        XCTAssertTrue(model.overlayIgnoresMouse)
        model.overlayAdjusting = true
        XCTAssertTrue(model.overlayVisible)
        XCTAssertFalse(model.overlayIgnoresMouse)
        model.toggleClickThrough()
        XCTAssertFalse(model.settings.overlayClickThrough)
    }
}
