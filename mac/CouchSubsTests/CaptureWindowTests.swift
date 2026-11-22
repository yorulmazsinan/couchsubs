// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import RemotePlay
import XCTest
@testable import CouchSubs

/// Seçilen pencereden okuma (OBS projektörü ya da oyun penceresi): kurulum, başlatma, pencere değişimi ve ana ekran
/// metinleri. Windows'taki `AppControllerTests` (SelectedWindow…) ile aynı vektörler.
@MainActor
final class CaptureWindowTests: XCTestCase {
    private let obs = WindowCaptureTarget(processName: "obs64", title: "Fullscreen Projector (Scene)")
    private let game = WindowCaptureTarget(processName: "game", title: "Gameplay")

    private func waitForStreams(_ count: Int, in services: FakeServices) async {
        for _ in 0..<200 where services.captureWindowStreams.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// PSN girişi ve PS5 eşleştirmesi atlanır ama pencere seçilmeden çeviri başlatılamaz (bütün masaüstü okunmaz).
    func testSelectedWindowSetupSkipsPSNPairingButRequiresExplicitTarget() {
        let store = MemoryStore()
        let defaults = UserDefaults.isolated()
        let model = AppModel(services: FakeServices(), store: store, defaults: defaults)
        model.advance()
        XCTAssertEqual(model.step, .secondAccount)

        model.useCaptureWindow()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(model.settings.frameSource, .captureWindow)
        XCTAssertEqual(model.settings.output, .computer)
        XCTAssertNil(model.accountId)
        XCTAssertFalse(model.canStart)
        XCTAssertFalse(model.needsPS5Link)

        model.settings.captureWindow = obs
        XCTAssertTrue(model.canStart)
        let reopened = AppModel(services: FakeServices(), store: store, defaults: defaults)
        XCTAssertEqual(reopened.step, .done)
        XCTAssertEqual(reopened.settings.captureWindow, obs)
    }

    func testIncompleteTargetCannotStart() async {
        let services = FakeServices()
        let model = AppModel(services: services, store: MemoryStore(), defaults: .isolated())
        model.useCaptureWindow()
        model.settings.captureWindow = WindowCaptureTarget(processName: "obs64", title: "")
        XCTAssertFalse(model.canStart)
        await model.start()
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(services.captureWindowStreams.isEmpty)
    }

    /// Seçilen pencere okunurken PS5 oturumu açılmaz; pencere değişince çeviri yeni pencereyle yeniden başlar.
    func testSelectedWindowStartsAndSwitchesTargetsWithoutOpeningPS5Session() async {
        let services = FakeServices()
        services.remotePlayInstalledResult = false
        let model = AppModel(services: services, store: MemoryStore(), defaults: .isolated())
        model.useCaptureWindow()
        model.settings.captureWindow = obs

        await model.start()
        XCTAssertEqual(services.captureWindowStreams, [obs])
        XCTAssertTrue(services.streamPasscodes.isEmpty)
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.remotePlayMissing)

        model.settings.captureWindow = game
        await waitForStreams(2, in: services)
        XCTAssertEqual(services.captureWindowStreams, [obs, game])
        XCTAssertEqual(services.streams.count, 2)
        XCTAssertTrue(model.isRunning)
        model.stop()
    }

    /// #853: Xbox seçiliyken OBS/oyun penceresi (Xbox uygulaması, play.xbox.com, capture card) seçilirse CouchSubs Xbox'a
    /// hiç bağlanmaz; sihirbazda Microsoft girişi atlanır (Windows XboxWithSelectedWindow… / XboxWizardWindowChoice… ile aynı).
    func testXboxWithSelectedWindowReadsOnlyTheWindowAndNeverConnectsToTheXbox() async {
        let services = FakeServices()
        let defaults = UserDefaults.isolated()
        defaults.set(ConsolePlatform.xbox.rawValue, forKey: XboxStoreKey.platform)
        let store = MemoryStore()
        let model = AppModel(services: services, store: store, defaults: defaults)
        XCTAssertTrue(model.isXbox)
        model.advance()
        XCTAssertEqual(model.step, .psnLogin)
        XCTAssertTrue(model.needsXboxLink)

        model.useXboxWindow()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(model.settings.xboxFrameSource, .captureWindow)
        XCTAssertEqual(model.settings.output, .computer)
        XCTAssertTrue(model.readsXboxWindow)
        XCTAssertFalse(model.needsXboxLink)
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(model.pictureSourceName, String(localized: "OBS projector or game window"))

        model.settings.captureWindow = obs
        XCTAssertTrue(model.canStart)
        XCTAssertTrue(model.keepsDisplayOn)
        XCTAssertEqual(AppModel(services: FakeServices(), store: store, defaults: defaults).step, .done)

        await model.start()
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(services.captureWindowStreams, [obs])
        XCTAssertTrue(services.xboxStreams.isEmpty)
        model.stop()

        // Xbox bağlantısına dönülünce giriş ve Xbox seçimi yine gerekir.
        model.settings.xboxFrameSource = .xbox
        XCTAssertTrue(model.needsXboxLink)
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(model.pictureSourceName, String(localized: "Xbox (this app connects)"))
    }

    /// Aynı pencere yeniden seçilirse (ya da başka bir ayar değişirse) çeviri yeniden başlamaz.
    func testUnchangedTargetDoesNotRestart() async {
        let services = FakeServices()
        let model = AppModel(services: services, store: MemoryStore(), defaults: .isolated())
        model.useCaptureWindow()
        model.settings.captureWindow = obs
        await model.start()
        model.settings.captureWindow = obs
        model.settings.gamePacks.toggle()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(services.captureWindowStreams, [obs])
        model.stop()
    }

    /// Görüntü bu Mac'teki pencereden okunurken ekran kapanmamalı (kapanınca ScreenCaptureKit kare vermez).
    func testSelectedWindowKeepsTheDisplayOn() {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        model.settings.output = .tv
        XCTAssertFalse(model.keepsDisplayOn)
        model.settings.frameSource = .captureWindow
        XCTAssertTrue(model.keepsDisplayOn)
    }

    func testPictureSourceTitleFollowsTheSelectedSource() {
        XCTAssertEqual(AppModel.pictureSourceTitle(.ps5), String(localized: "The PS5 (second account)"))
        XCTAssertEqual(AppModel.pictureSourceTitle(.remotePlayWindow), String(localized: "Remote Play window on this Mac"))
        XCTAssertEqual(AppModel.pictureSourceTitle(.captureWindow), String(localized: "OBS projector or game window"))
    }

    // MARK: - Durum metni (Windows'taki CaptureWindowStatusText)

    func testStatusAsksForAWindowUntilOneIsChosen() {
        let ask = String(localized: "Choose an OBS or game window in Settings › Picture source.")
        XCTAssertEqual(AppModel.captureWindowStatusText(.disconnected(.stopped), running: false, target: nil), ask)
        XCTAssertEqual(AppModel.captureWindowStatusText(.streaming, running: true,
                                                        target: WindowCaptureTarget(processName: "", title: "Gameplay")), ask)
    }

    func testStatusFollowsTheSession() {
        XCTAssertEqual(AppModel.captureWindowStatusText(.disconnected(.stopped), running: false, target: obs),
                       String(format: String(localized: "Ready to read %@ when translation starts."), obs.title))
        XCTAssertEqual(AppModel.captureWindowStatusText(.streaming, running: true, target: obs),
                       String(localized: "Reading the selected window"))
        // Pencere kapandı ya da henüz açılmadı: aynı pencere beklenir.
        XCTAssertEqual(AppModel.captureWindowStatusText(.connecting, running: true, target: obs),
                       String(format: String(localized: "Waiting for the selected window: %@"), obs.title))
        XCTAssertEqual(AppModel.captureWindowStatusText(.disconnected(.stopped), running: true, target: obs),
                       String(format: String(localized: "Waiting for the selected window: %@"), obs.title))
    }

    /// Siyah kare ve ekran kaydı izni uyarıları olduğu gibi gösterilir.
    func testStatusShowsTheReasonWhenThereIsOne() {
        let black = String(localized: "The selected window is black. Check the OBS projector or game window.")
        XCTAssertEqual(AppModel.captureWindowStatusText(.disconnected(.other(black)), running: true, target: obs), black)
        XCTAssertEqual(AppModel.captureWindowStatusText(.disconnected(.other(RemotePlayWindowStream.permissionText)), running: true, target: obs),
                       RemotePlayWindowStream.permissionText)
    }

    func testMainScreenStatusUsesTheSelectedWindowText() {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        model.useCaptureWindow()
        XCTAssertEqual(model.ps5StatusText, String(localized: "Choose an OBS or game window in Settings › Picture source."))
        model.settings.captureWindow = obs
        XCTAssertEqual(model.ps5StatusText, String(format: String(localized: "Ready to read %@ when translation starts."), obs.title))
    }

    // MARK: - Pencere listesi ve ekran kaydı izni

    func testWindowListAndPermissionComeFromServices() async {
        let services = FakeServices()
        services.openCaptureWindows = [game, obs]
        let model = AppModel(services: services, store: MemoryStore(), defaults: .isolated())
        XCTAssertTrue(model.screenRecordingAllowed)
        let open = await model.availableCaptureWindows()
        XCTAssertEqual(open, [game, obs])

        // İzin yoksa macOS pencere başlıklarını vermez: liste boştur, "Sistem Ayarları'nı aç" izin sayfasını açar.
        services.screenRecordingAllowedResult = false
        XCTAssertFalse(model.screenRecordingAllowed)
        let hidden = await model.availableCaptureWindows()
        XCTAssertTrue(hidden.isEmpty)
        model.openScreenRecordingSettings()
        XCTAssertEqual(services.screenRecordingSettingsOpened, 1)
    }

    func testScreenRecordingSettingsPageIsThePrivacyPane() {
        XCTAssertEqual(RemotePlayWindowStream.screenRecordingSettingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
}
