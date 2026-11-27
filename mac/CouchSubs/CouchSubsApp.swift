// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
#if !APP_STORE
// Mac App Store sürümünde (APP_STORE) güncellemeyi App Store yapar; Sparkle pakete hiç girmez.
import Sparkle
#endif
import SwiftUI

/// Uygulama `--ocr-helper` ile açıldıysa pencere açmaz: yedek okuyucu olarak çalışır (`OcrHelper`, #679).
@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains(OcrHelper.argument) { OcrHelper.runAsHelper() }
        CouchSubsApp.main()
    }
}

struct CouchSubsApp: App {
    @StateObject private var model = Self.makeModel()
    /// Bilgisayar ekranındaki altyazı penceresi.
    @State private var overlay = SubtitleOverlayController()
    /// Yayın programlarının yakaladığı düz zeminli altyazı penceresi (Ayarlar > OBS'ten açılır).
    @State private var stream = StreamWindowController()
    /// Oyun penceresinin üstünde GTA 6 telefonunun yerinde Türkçe çizimi ("Ekranı yerinde Türkçe çiz").
    @State private var phoneTwin = PhoneTwinOverlayController()
    #if !APP_STORE
    /// Sparkle: her açılışta ve uygulama açıkken saatte bir GitHub'daki son sürüme bakar; testlerde başlamaz.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        updaterDelegate: Self.updateRecorder, userDriverDelegate: nil)
    /// Kurulmak üzere olan güncellemeyi kaydeder (Sparkle temsilciyi zayıf tutar; burada yaşar).
    private static let updateRecorder = AppUpdateRecorder()
    #endif

    /// Hakkında'daki "Güncellemeleri Denetle…" (Mac App Store sürümünde yok).
    private var checkForUpdates: (() -> Void)? {
        #if APP_STORE
        nil
        #else
        { [updater] in updater.checkForUpdates(nil) }
        #endif
    }

    /// Testler uygulamanın içinde çalışır. Gerçek Anahtarlığa dokunmazlar: imza farklı olunca macOS parola sorar ve test takılır.
    private static func makeModel() -> AppModel {
        // Testlerde ayarlar da gerçek kayda (com.couchsubs.mac) yazılmaz.
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? AppModel()
            : AppModel(store: EphemeralStore(), defaults: UserDefaults(suiteName: "couchsubs-test-host") ?? .standard)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                // Sparkle kendi takviminde günde bir bakar; yeni sürüm her açılışta fark edilsin diye açılışta da sessizce bakılır.
                .environment(\.checkForUpdates, checkForUpdates)
                .task {
                    overlay.attach(model)
                    stream.attach(model)
                    phoneTwin.attach(model)
                    CrashNotice.shared.checkOnce()
                    AppUpdateNotice.shared.checkOnce()
                    #if !APP_STORE
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    updater.updater.checkForUpdatesInBackground()
                    #endif
                }
                .appSurface()
                // Yeni arayüz: en küçük 1200 × 760, büyüyünce sütunlar oransal genişler (içerik en fazla 1680, ortalı).
                .frame(minWidth: DS.size("windowWidth"), idealWidth: DS.size("windowWidth"), maxWidth: .infinity,
                       minHeight: DS.size("windowHeight"), idealHeight: DS.size("windowHeight"), maxHeight: .infinity)
                // Başlık çubuğu da pencere zemininin rengini alır (macOS 15 ve sonrası; öncesinde sistem rengi).
                .windowBackground(Color.dsBackground)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About CouchSubs") { model.showAbout = true }
                Button("Release Notes") { model.showReleaseNotes = true }
                #if !APP_STORE
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
                #endif
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings") { model.showSettings = true }
                    .keyboardShortcut(",")
                    .disabled(model.step != .done)
            }
        }
        // Altyazı bilgisayar ekranındayken menü çubuğundan pencereye ulaşılır ("Tıklamalar geçsin" açıkken geri dönüş yolu).
        // Yeni arayüzde pencere biçiminde (tuval 17): durum, Çeviriyi Başlat/Durdur, Tıklamalar Geçsin, Konumlandır, Aç.
        MenuBarExtra("CouchSubs", systemImage: "captions.bubble",
                     isInserted: Binding(get: { model.step == .done && model.settings.output.showsOnComputer }, set: { _ in })) {
            MenuBarPanel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            // Deneme modu kurulumdan bağımsızdır: sihirbazın hangi adımından açılırsa açılsın ana pencere görünür.
            if model.step == .done || model.demoMode { AppShell() } else { WizardView() }
        }
        .onAppear { model.adoptNewDesign() }
        .sheet(isPresented: $model.showAbout) { NewAboutView() }
        .sheet(isPresented: $model.showReleaseNotes) { ReleaseNotesView() }
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
