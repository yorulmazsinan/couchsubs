// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
#if !APP_STORE
// Mac App Store sürümünde (APP_STORE) güncellemeyi App Store yapar; Sparkle pakete hiç girmez.
import Sparkle
#endif
import SwiftUI

@main
struct CouchSubsApp: App {
    @StateObject private var model = Self.makeModel()
    /// Bilgisayar ekranındaki altyazı penceresi.
    @State private var overlay = SubtitleOverlayController()
    #if !APP_STORE
    /// Sparkle: her açılışta ve uygulama açıkken saatte bir GitHub'daki son sürüme bakar; testlerde başlamaz.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    /// Testler uygulamanın içinde çalışır. Gerçek Anahtarlığa dokunmazlar: imza farklı olunca macOS parola sorar ve test takılır.
    private static func makeModel() -> AppModel {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? AppModel() : AppModel(store: EphemeralStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                // Sparkle kendi takviminde günde bir bakar; yeni sürüm her açılışta fark edilsin diye açılışta da sessizce bakılır.
                .task {
                    overlay.attach(model)
                    #if !APP_STORE
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    updater.updater.checkForUpdatesInBackground()
                    #endif
                }
                .appSurface()
                .frame(minWidth: Theme.size("windowWidth"), idealWidth: Theme.size("windowWidth"), maxWidth: Theme.size("windowWidth") * 1.25,
                       minHeight: Theme.size("windowHeight"), idealHeight: Theme.size("windowHeight"))
                // Başlık çubuğu da pencere zemininin rengini alır (macOS 15 ve sonrası; öncesinde sistem rengi).
                .windowBackground(Color.csBackground)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About CouchSubs") { model.showAbout = true }
                #if !APP_STORE
                Button("Check for updates…") { updater.checkForUpdates(nil) }
                #endif
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings") { model.showSettings = true }
                    .keyboardShortcut(",")
                    .disabled(model.step != .done)
            }
        }
        // Altyazı bilgisayar ekranındayken menü çubuğundan pencereye ulaşılır ("Tıklamalar geçsin" açıkken geri dönüş yolu).
        MenuBarExtra("CouchSubs", systemImage: "captions.bubble",
                     isInserted: Binding(get: { model.step == .done && model.settings.output.showsOnComputer }, set: { _ in })) {
            Toggle("Clicks pass through", isOn: Binding(get: { model.settings.overlayClickThrough },
                                                        set: { model.settings.overlayClickThrough = $0 }))
            Button("Adjust the subtitle window") { model.overlayAdjusting = true }
            Divider()
            Button("Open CouchSubs") {
                if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.step == .done { MainView() } else { OnboardingView() }
        }
        .sheet(isPresented: $model.showAbout) { AboutView().appSurface() }
    }
}

private extension View {
    /// Pencere zemini; `containerBackground(_:for: .window)` macOS 15'te geldi.
    @ViewBuilder func windowBackground(_ color: Color) -> some View {
        if #available(macOS 15, *) {
            containerBackground(color, for: .window)
        } else {
            self
        }
    }
}
