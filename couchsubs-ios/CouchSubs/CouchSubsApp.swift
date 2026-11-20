// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import FacebookCore
import RemotePlay
import SwiftUI
import UIKit
import UserNotifications

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
    /// Kendi ürünlerimizin tanıtım popup'ı (promo.json; reklam SDK'sı ve izleme yok).
    @StateObject private var promo: PromoController
    @Environment(\.scenePhase) private var scenePhase
    /// Son etkin oluştan beri arka plana gidildi mi (yalnız etkin değilken dönmek bağlantıyı yenilemez).
    @State private var wasInBackground = false

    init() {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // AppDelegate bu noktada henüz çağrılmadı; Firebase burada da (bir kez) kurulur.
        let firebase = !testing && MainActor.assumeIsolated { Integrations.configureFirebase() }
        // Uygulamayla gelen paketler, üstüne sunucudan indirilen güncel sürümleri, en üstte içe aktarılan topluluk paketleri.
        let library = GamePackLibrary(bundled: GamePackLibrary.bundledDirectory,
                                      user: PackStore.filesDirectory(in: PackStore.defaultDirectory),
                                      imported: PackStore.importedDirectory)
        let model = testing ? PhoneModel(store: EphemeralStore(), packs: library)
            : Self.demoStore().map { PhoneModel(store: $0, packs: library) } ?? PhoneModel(packs: library)
        // Çeviri sürerken ekran kararmaz: iOS kilitlenen ya da arka plana geçen uygulamayı askıya alır.
        model.keepScreenAwake = { UIApplication.shared.isIdleTimerDisabled = $0 }
        // PS5 bağlantısı koptuğunda yerel bildirim (Profil'deki tercih; testlerde kapalı).
        if !testing {
            model.requestNotificationPermission = { ConnectionAlert.requestPermission() }
            model.onConnectionLost = { ConnectionAlert.post() }
            model.onPausedInBackground = { ConnectionAlert.schedulePausedInBackground() }
            model.onResumedFromBackground = { ConnectionAlert.clearPausedInBackground() }
        }
        // Çevrilen son satırlar ("Geçmiş"); testlerde dosyaya dokunulmaz.
        if !testing { model.loadHistory() }

        let analytics = AppAnalytics(firebase: firebase, meta: !testing && AppConfig.facebookAppID != nil)
        let store = testing ? nil : AppConfig.packsBaseURL.map { PackStore(baseURL: $0, directory: PackStore.defaultDirectory) }
        let app = AppModel(analytics: analytics, packStore: store, library: library)
        model.onAnalytics = { [analytics] event in analytics.log(event) }
        app.onPacksChanged = { [weak model] in model?.packsChanged() }
        model.onGameStarted = { [weak app] in Task { await app?.gameStarted() } }
        _model = StateObject(wrappedValue: model)
        _app = StateObject(wrappedValue: app)
        _promo = StateObject(wrappedValue: PromoController(enabled: !testing))
    }

    /// Tanıtım popup'ı yalnız karşılama, kurulum ve ilk tur bittikten sonra hazırlanır (yeni kullanıcı ilk açılışta görmez).
    @MainActor private var promoSetupDone: Bool {
        UserDefaults.standard.bool(forKey: "welcomeSeen") && model.step == .done && app.tourDone
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
                .environmentObject(promo)
                .appSurface()
                // Meta'nın dönüş adresleri.
                .onOpenURL { url in
                    guard AppConfig.facebookAppID != nil else { return }
                    ApplicationDelegate.shared.application(UIApplication.shared, open: url, sourceApplication: nil, annotation: nil)
                }
                .task { await app.start() }
                // Soğuk açılışta promo.json'a arka planda bakılır (ön plana dönüşler aşağıda).
                .task { await promo.refresh(setupDone: promoSetupDone) }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                model.becameActive(afterBackground: wasInBackground)
                wasInBackground = false
                // Ön plana gelince tanıtım popup'ına bakılır (promo.json en çok günde bir yeniden çekilir).
                Task { await promo.refresh(setupDone: promoSetupDone) }
            case .background:
                wasInBackground = true
                model.enteredBackground()
                Task { await model.flushPool() }
            default: break
            }
        }
    }
}

/// "PS5 bağlantısı koptu" yerel bildirimi (Android'deki gibi). Uygulama öndeyken gösterilmez: durum ekranda görünür.
@MainActor
enum ConnectionAlert {
    private static let identifier = "connection-lost"

    /// İzin yalnız ilk seferde sorulur; sonra iOS kayıtlı yanıtı döner.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post() {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "PS5 connection lost")
        content.body = String(localized: "Subtitles stopped. Open CouchSubs to reconnect.")
        content.sound = .default
        // Aynı kimlik: art arda kopmalarda bildirimler birikmez, sonuncusu kalır.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static let pausedIdentifier = "paused-in-background"
    /// Arka plana geçişten bu kadar sonra uyarılır: Denetim Merkezi ya da kısa bir mesaj için çıkıp hemen dönen
    /// kullanıcı bildirim görmez (dönünce `clearPausedInBackground` iptal eder).
    private static let pausedDelay: TimeInterval = 8

    /// iPhone'da çeviri arka planda ya da kilitli ekranda sürmez (iOS uygulamayı askıya alır; App Store kurallarına uyan
    /// bir arka plan modu bu iş için yok). Bildirimi iOS zamanında kendisi gösterir; uygulamanın çalışması gerekmez.
    static func schedulePausedInBackground() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Subtitles paused")
        content.body = String(localized: "iPhone pauses CouchSubs in the background and when the screen is locked. Open CouchSubs to continue; it reconnects by itself.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: pausedDelay, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: pausedIdentifier, content: content, trigger: trigger))
    }

    static func clearPausedInBackground() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [pausedIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [pausedIdentifier])
    }
}

struct RootView: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var promo: PromoController
    @AppStorage("welcomeSeen") private var welcomeSeen = false
    @State private var path: [Route] = []

    var body: some View {
        Group {
            // Deneme modu kurulumdan bağımsızdır: hangi adımdan açılırsa açılsın çeviri ekranı görünür.
            if model.demoMode {
                home
            } else if !welcomeSeen {
                WelcomeFlow(onFinish: finishWelcome)
            } else if model.step != .done {
                setup
            } else {
                home
            }
        }
        .onChange(of: model.demoMode) { _ in path = [] }
        .alert(item: $model.tvPairingRequest) { ticket in
            Alert(title: Text("Pair this TV?"),
                  message: Text(String(format: String(localized: "TV code: %@. Approve only if this code is shown on your TV."), ticket.code)),
                  primaryButton: .default(Text("Approve")) { model.resolveTVPairing(ticket, accept: true) },
                  secondaryButton: .cancel(Text("Reject")) { model.resolveTVPairing(ticket, accept: false) })
        }
        .preferredColorScheme(.dark)
        .tint(Mobile.Palette.accent)
        // Yazılar Dinamik Yazı'yla büyür; en büyük erişilebilirlik boylarında karolar taşmasın diye üst sınır.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
            // Önce konsol türü (PlayStation varsayılan, Xbox Beta); Xbox'ta ikinci hesap (PSN) yerine Microsoft girişi.
            if !model.platformChosen {
                PlatformScreen(onBack: { welcomeSeen = false }) {}
            } else if model.isXbox {
                XboxLoginScreen(onBack: { model.platformChosen = false }, onSkip: { model.skipSetup() }, onDone: {
                    if model.step == .welcome { model.advance() }
                    model.advance()
                })
            } else {
                PSNScreen(onBack: { model.platformChosen = false }, onSkip: { model.skipSetup() }, onDone: {
                    if model.step == .welcome { model.advance() }
                    model.advance()
                })
            }
        case .console where model.isXbox:
            XboxConsoleScreen(onBack: { model.back() }, onSkip: { model.skipSetup() }, onSignIn: { model.back() },
                              onDone: { model.advance() })
        case .console:
            PS5PairScreen(onBack: { model.back() }, onSkip: { model.skipSetup() }, onDone: { model.advance() })
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
                // Kurulum atlandıysa PSN girişi yoktur: PS5 eşlemeden önce giriş yapılır, ardından eşlemeye geçilir.
                case .platform:
                    PlatformScreen(onBack: { path.removeLast() }) {
                        path.removeLast()
                        if model.isXbox && (!model.xboxSignedIn || model.xboxConsole == nil) { path.append(.ps5) }
                    }
                // Xbox (Beta): giriş yoksa önce Microsoft girişi, ardından Xbox seçimi.
                case .ps5 where model.isXbox && !model.xboxSignedIn:
                    XboxLoginScreen(onBack: { path.removeLast() }, onDone: {
                        path.removeLast()
                        path.append(.ps5)
                    })
                case .ps5 where model.isXbox:
                    XboxConsoleScreen(onBack: { path.removeLast() }, onSignIn: { model.signOutXbox() }, onDone: { path.removeLast() })
                case .ps5 where model.accountId == nil:
                    PSNScreen(onBack: { path.removeLast() }, onDone: {
                        path.removeLast()
                        path.append(.ps5)
                    })
                case .ps5: PS5PairScreen(onBack: { path.removeLast() }, onDone: { path.removeLast() })
                case .psn: PSNScreen(onBack: { path.removeLast() }, onDone: { path.removeLast() })
                case .about: AboutScreen()
                case .history: HistoryScreen()
                case .tvInstall: TVInstallScreen(onDone: { path.removeAll() })
                case .tvUpdate: TVInstallScreen(update: model.tvAppUpdate, onDone: { path.removeAll() })
                }
            }
        }
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            if !app.tourDone && path.isEmpty && !model.isRunning && !model.demoMode {
                CoachTour(anchors: anchors) { withAnimation { app.tourDone = true } }
            }
        }
        // Kendi ürünlerimizin tanıtımı (promo.json): yalnız boştaki ana ekranda, girişten 10 sn sonra; oturum, bağlanma,
        // deneme, kurulum ve tur sırasında asla (Android'deki MainScreen ile aynı karar).
        .overlay {
            if let ready = promo.ready, PromoPolicy.shouldShow(ready.popup, record: promo.record, now: Date(), moment: promoMoment) {
                PromoOverlay(ready: ready) { withAnimation { promo.dismissed(ready.popup) } }
            }
        }
        .animation(.easeOut(duration: 0.25), value: promo.ready?.popup)
    }

    private var promoMoment: PromoMoment {
        PromoMoment(onHome: path.isEmpty, sessionActive: model.isRunning || model.isStarting, demo: model.demoMode,
                    onboarding: !welcomeSeen || model.step != .done, tour: !app.tourDone,
                    inApp: Date().timeIntervalSince(promo.foregroundAt))
    }
}
