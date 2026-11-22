// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import RemotePlay
import SwiftUI
import XCTest
@testable import CouchSubs

/// Geliştirme aracı: README'deki ekran görüntüleri (docs/screenshots/mac). Yalnız `COUCHSUBS_SCREENSHOTS` ortam
/// değişkeni (klasör) verilince çalışır; `scripts/mac-screenshots.sh` başlatır. Uygulamanın ekranları koyu görünümde,
/// örnek verilerle (sahte hizmetler, bellekteki kayıt) birer pencerede açılır ve pencerenin kendisi (başlık çubuğu
/// dahil, ekranın 2x ölçeğinde) PNG'ye çizilir; Ekran Kaydı izni gerekmez.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var windows: [NSWindow] = []

    func testCaptureScreens() async throws {
        guard let path = ProcessInfo.processInfo.environment["COUCHSUBS_SCREENSHOTS"] else {
            throw XCTSkip("COUCHSUBS_SCREENSHOTS verilmedi")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let main = try await mainModel()
        let setup = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        setup.accountId = Data(repeating: 1, count: 8)
        setup.step = .console

        // Yeni arayüz: her ekran sırayla aynı modelle açılır (sekme ve bölüm modelin bayraklarında).
        let size = CGSize(width: DS.size("windowWidth"), height: DS.size("windowHeight"))
        var screens: [(String, () -> Void)] = [
            ("ana", { main.showSettings = false; main.showHistory = false }),
            ("gecmis", { main.showHistory = true }),
        ]
        for section in SettingsSection.allCases {
            screens.append(("ayarlar-\(section)", { main.showHistory = false; main.settingsSection = section; main.showSettings = true }))
        }
        let only = ProcessInfo.processInfo.environment["COUCHSUBS_SCREENSHOT_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
        for (name, prepare) in screens where only == nil || name.hasPrefix(only!) {
            prepare()
            let window = show(AnyView(RootView().environmentObject(main)), size: size, offset: 0)
            try await Task.sleep(for: .seconds(1.5))
            try capture(window).write(to: folder.appendingPathComponent("\(name).png"))
            window.close()
        }
        // Kurulum adımları (karşılama adımı ilk kurulumda açılış animasyonunu gösterir).
        let steps: [(String, AppModel.Step)] = [("kurulum-0-acilis", .welcome), ("kurulum-2-hesap", .secondAccount),
                                                ("kurulum-2b-giris", .psnLogin), ("kurulum-3-ps5", .console), ("kurulum-5-tv", .tv),
                                                ("kurulum-6-hdmi", .hdmi), ("kurulum-7-ceviri", .betterTranslation), ("kurulum-8-dene", .test)]
        for (name, step) in steps where only == nil || name.hasPrefix(only!) {
            setup.step = step
            let window = show(AnyView(WizardView().environmentObject(setup)), size: size, offset: 40)
            try await Task.sleep(for: .seconds(step == .welcome ? 3.5 : 2))
            try capture(window).write(to: folder.appendingPathComponent("\(name).png"))
            window.close()
        }
        windows.forEach { $0.close() }
    }

    /// Pencereyi çerçevesiyle (başlık çubuğu ve düğmeleri dahil) PNG olarak çizer.
    private func capture(_ window: NSWindow) throws -> Data {
        let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Kurulumu bitmiş, çeviri süren uygulama: PS5 ve TV bağlı, DeepL seçili, son altyazılar geçmişte.
    private func mainModel() async throws -> AppModel {
        let store = MemoryStore()
        store.save(Data(repeating: 1, count: 8), for: StoreKey.accountId)
        store.save(RegisteredConsole(host: "192.168.1.253", name: "PS5-789", registKey: Data(repeating: 0x31, count: 16),
                                     morning: Data(repeating: 2, count: 16)), for: StoreKey.console)
        store.save(LGTV(name: "LG TV", host: "192.168.1.153"), for: StoreKey.tv)
        store.save("tv-key", for: StoreKey.tvKey)
        let model = AppModel(services: FakeServices(), store: store, defaults: .isolated())
        model.settings.translationEngine = .deepL
        model.isRunning = true
        model.sessionState = .streaming
        model.tvClients = 1
        let sample = [("I gotta tell you this, Franklin.", "Bunu sana söylemem lazım, Franklin."),
                      ("Take out the Lost.", "Lost üyelerini ortadan kaldır."),
                      ("Are you listening to me?", "Dinliyor musun beni?")]
        for (source, translation) in sample {
            model.history.add(source: source, translation: translation)
            model.lastSource = source
            model.lastTranslation = translation
        }
        // Paketler açılışta arka planda yüklenir.
        let deadline = Date().addingTimeInterval(10)
        while model.installedPacks.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        return model
    }

    private func show(_ view: AnyView, size: CGSize, offset: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "CouchSubs"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: (ProcessInfo.processInfo.environment["COUCHSUBS_SCREENSHOT_DARK"] ?? "").isEmpty ? .aqua : .darkAqua)
        window.backgroundColor = NSColor(Color.dsBackground)
        window.contentView = NSHostingView(rootView: view.appSurface().frame(width: size.width, height: size.height))
        window.setFrameTopLeftPoint(NSPoint(x: 80 + offset, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 40 - offset))
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }
}
