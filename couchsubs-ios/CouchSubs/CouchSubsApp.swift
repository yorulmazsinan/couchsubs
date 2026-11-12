// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import FacebookCore
import RemotePlay
import SwiftUI
import UIKit

/// SDK'lar uygulama açılırken kurulur (Firebase, Meta); her biri yalnız anahtarı/dosyası varsa.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            _ = Integrations.configureFirebase()
            _ = Integrations.configureMeta(application: application, options: options)
        }
        return true
    }
}

/// CouchSubs tamamen ücretsizdir ve hesap istemez: ücretsiz çeviri, DeepL, kendi yapay zekâ anahtarı ve oyun paketleri
/// herkese açık.
@main
struct CouchSubsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: PhoneModel
    @StateObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // AppDelegate bu noktada henüz çağrılmadı; Firebase burada da (bir kez) kurulur.
        let firebase = !testing && MainActor.assumeIsolated { Integrations.configureFirebase() }
        // Uygulamayla gelen paketler, üstüne sunucudan indirilen güncel sürümleri.
        let library = GamePackLibrary(bundled: GamePackLibrary.bundledDirectory,
                                      user: PackStore.filesDirectory(in: PackStore.defaultDirectory))
        let model = testing ? PhoneModel(store: EphemeralStore(), packs: library)
            : Self.demoStore().map { PhoneModel(store: $0, packs: library) } ?? PhoneModel(packs: library)
        // Çeviri sürerken ekran kararmaz: iOS kilitlenen ya da arka plana geçen uygulamayı askıya alır.
        model.keepScreenAwake = { UIApplication.shared.isIdleTimerDisabled = $0 }
        // Çevrilen son satırlar ("Geçmiş"); testlerde dosyaya dokunulmaz.
        if !testing { model.loadHistory() }

        let analytics = AppAnalytics(firebase: firebase, meta: !testing && AppConfig.facebookAppID != nil)
        let store = testing ? nil : AppConfig.packsBaseURL.map { PackStore(baseURL: $0, directory: PackStore.defaultDirectory) }
        let app = AppModel(analytics: analytics, packStore: store, library: library)
        model.onAnalytics = { [analytics] event in analytics.log(event) }
        app.onPacksChanged = { [weak model] in model?.packsChanged() }
        _model = StateObject(wrappedValue: model)
        _app = StateObject(wrappedValue: app)
    }

    /// Hata ayıklama: COUCHSUBS_DEMO=1 ile kurulum bitmiş gibi açılır (ekran görüntüsü ve tasarım denetimi için;
    /// PS5'e bağlanmaz). Anahtarlığa dokunmaz.
    private static func demoStore() -> CouchSubsCore.AppStore? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["COUCHSUBS_DEMO"] == "1" else { return nil }
        let store = EphemeralStore()
        store.save(Data([1, 2, 3]), for: StoreKey.accountId)
        store.save(RegisteredConsole(host: "192.168.1.103", name: "PS5-002", registKey: Data(), morning: Data()), for: StoreKey.console)
        store.save(LGTV(name: "Salon TV", host: "192.168.1.50", brand: .lg), for: StoreKey.tv)
        store.save("demo", for: StoreKey.tvKey)
        store.save(true, for: StoreKey.setupComplete)
        return store
        #else
        return nil
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(app)
                .appSurface()
                // Meta'nın dönüş adresleri.
                .onOpenURL { url in
                    guard AppConfig.facebookAppID != nil else { return }
                    ApplicationDelegate.shared.application(UIApplication.shared, open: url, sourceApplication: nil, annotation: nil)
                }
                .task { await app.start() }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: model.becameActive()
            case .background: Task { await model.flushPool() }
            default: break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var app: AppModel
    @AppStorage("welcomeSeen") private var welcomeSeen = false
    @State private var path: [Route] = []

    var body: some View {
        Group {
            if !welcomeSeen {
                WelcomeFlow(onFinish: finishWelcome)
            } else if model.step != .done {
                setup
            } else {
                home
            }
        }
        .preferredColorScheme(.dark)
        .tint(Mobile.Palette.accent)
    }

    private func finishWelcome() {
        welcomeSeen = true
        if model.step == .welcome { model.advance() }
        // Meta'nın otomatik olayları karşılamadan sonra açılır (reklam kimliği olmadan; izin formu ya da ATT yok).
        Integrations.startMeta()
    }

    /// Kurulum: PSN girişi → PS5 eşleme → altyazının yeri.
    @ViewBuilder private var setup: some View {
        switch model.step {
        case .welcome, .psnLogin:
            PSNScreen(onBack: { welcomeSeen = false }) {
                if model.step == .welcome { model.advance() }
                model.advance()
            }
        case .console:
            PS5PairScreen(onBack: { model.back() }) { model.advance() }
        case .output, .done:
            TargetScreen(onBack: { model.back() }) { model.advance() }
        }
    }

    private var home: some View {
        NavigationStack(path: $path) {
            Group {
                if model.isRunning { RunningScreen(path: $path) } else { HomeScreen(path: $path) }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .settings: SettingsScreen(path: $path)
                case .profile: ProfileScreen(path: $path)
                case .packs: PacksScreen()
                case .target: TargetScreen(setup: false) { path.removeLast() }
                case .ps5: PS5PairScreen(onBack: { path.removeLast() }) { path.removeLast() }
                case .psn: PSNScreen(onBack: { path.removeLast() }) { path.removeLast() }
                case .about: AboutScreen()
                case .history: HistoryScreen()
                }
            }
        }
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            if !app.tourDone && path.isEmpty && !model.isRunning {
                CoachTour(anchors: anchors) { withAnimation { app.tourDone = true } }
            }
        }
    }
}
