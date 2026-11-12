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

        let width = Theme.size("windowWidth"), height = Theme.size("windowHeight")
        let settingsSize = CGSize(width: width - 2 * Theme.space("screen"), height: height - 2 * Theme.space("screen"))
        let screens: [(String, AnyView, CGSize)] = [
            ("ana", AnyView(MainView().environmentObject(main)), CGSize(width: width, height: height)),
            ("ayarlar-ceviri", AnyView(SettingsView(section: .translation).environmentObject(main)), settingsSize),
            ("ayarlar-paketler", AnyView(SettingsView(section: .packs).environmentObject(main)), settingsSize),
            ("kurulum", AnyView(OnboardingView().environmentObject(setup)), CGSize(width: width, height: height)),
        ]
        let shown = screens.enumerated().map { index, screen in
            (screen.0, show(screen.1, size: screen.2, offset: CGFloat(index) * 40))
        }
        // Görevler (PS5 arama, paket yükleme) ve çizim bitsin.
        try await Task.sleep(for: .seconds(3))
        for (name, window) in shown {
            try capture(window).write(to: folder.appendingPathComponent("\(name).png"))
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
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Color.csBackground)
        window.contentView = NSHostingView(rootView: view.appSurface().frame(width: size.width, height: size.height))
        window.setFrameTopLeftPoint(NSPoint(x: 80 + offset, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 40 - offset))
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }
}
