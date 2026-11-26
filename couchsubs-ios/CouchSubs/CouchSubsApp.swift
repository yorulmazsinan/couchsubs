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

    /// Altyazı ekranı açıkken yalnız yatay (ya da "Ekranı döndür" ile dik); başka yerde her yön (bkz. Orientation).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Orientation.allowed }
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
            model.onPausedInBackground = { [weak model] in ConnectionAlert.schedulePausedInBackground(pipEnabled: model?.backgroundPiP ?? false) }
            model.onResumedFromBackground = {
                ConnectionAlert.clearPausedInBackground()
                ConnectionAlert.clearTVLostWhileAway()
            }
            // #1303: arka plandayken TV bağlantısı koptu (Android ile aynı uyarı).
            model.onTVLostWhileAway = { [weak model] in
                guard model?.notifiesDisconnect == true else { return }
                ConnectionAlert.postTVLostWhileAway()
            }
            // "Arka planda sürdür": çeviri sürerken uygulamadan çıkınca Resim içinde resim penceresi; açıkken çeviri sürer,
            // "duraklatıldı" uyarısı gerekmez. Pencere arka planda kapanırsa uyarı yeniden kurulur.
            let pip = BackgroundPiP.shared
            pip.bind(model)
            pip.onStarted = { ConnectionAlert.clearPausedInBackground() }
            pip.onStoppedInBackground = { [weak model] in
                guard let model, model.isRunning, !model.demoMode, model.notifiesDisconnect else { return }
                ConnectionAlert.schedulePausedInBackground(pipEnabled: model.backgroundPiP)
            }
            // Uzun oturum tanısı: önceki oturum durdurulmadan bittiyse (bellek, çökme) raporlanır.
            CrashNotes.enabled = firebase
            model.onDiagnostic = { CrashNotes.log($0) }
            if let ended = model.takeUnexpectedEnd() { CrashNotes.record(ended) }
        }
        // Çevrilen son satırlar ("Geçmiş"); testlerde dosyaya dokunulmaz.
        if !testing { model.loadHistory() }

        let analytics = AppAnalytics(firebase: firebase, meta: !testing && AppConfig.facebookAppID != nil)
        // Sır yoksa (yerel geliştirici derlemesi) sunucu imzasız isteği reddeder: paket indirme sessizce kapalı.
        let store = testing ? nil : AppConfig.packsBaseURL.flatMap { base in
            AppConfig.packsSecret.map { secret in
                PackStore(baseURL: base, fallbackURLs: AppConfig.packsFallbackURL.map { [$0] } ?? [], secret: secret,
                          directory: PackStore.defaultDirectory)
            }
        }
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
                // Uzun oturum tanısı: iOS'un bellek uyarısı günlüğe yazılır (kapanmadan önceki son iz).
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    model.receivedMemoryWarning()
                }
                // Soğuk açılışta promo.json'a arka planda bakılır (ön plana dönüşler aşağıda).
                .task { await promo.refresh(setupDone: promoSetupDone) }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                // Arka planda Resim içinde resim penceresi hiç kapanmadıysa iOS uygulamayı askıya almadı: PS5 oturumu
                // yeniden kurulmaz (ikinci hesap girip çıkmasın), yalnız bildirim silinir.
                let keptAlive = wasInBackground && BackgroundPiP.shared.takeKeptAlive()
                if keptAlive { ConnectionAlert.clearPausedInBackground() }
                model.becameActive(afterBackground: wasInBackground && !keptAlive)
                wasInBackground = false
                // Ön plana gelince tanıtım popup'ına bakılır (promo.json en çok günde bir yeniden çekilir).
                Task { await promo.refresh(setupDone: promoSetupDone) }
            case .background:
                wasInBackground = true
                BackgroundPiP.shared.enteredBackground()
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
        #if DEBUG
        // Ekran görüntüsü kipinde (COUCHSUBS_DEMO=1) izin penceresi ekranı kapatmasın.
        if ProcessInfo.processInfo.environment["COUCHSUBS_DEMO"] == "1" { return }
        #endif
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

    /// Resim içinde resim penceresi açık değilse iPhone'da çeviri arka planda ya da kilitli ekranda sürmez (iOS uygulamayı
    /// askıya alır). Bildirimi iOS zamanında kendisi gösterir; uygulamanın çalışması gerekmez. Pencere 8 sn içinde açılırsa
    /// bildirim gösterilmeden silinir.
    static func schedulePausedInBackground(pipEnabled: Bool) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Subtitles paused")
        content.body = pipEnabled
            ? String(localized: "The small Picture in Picture window closed, so iPhone paused CouchSubs. Open CouchSubs to continue; it reconnects by itself.")
            : String(localized: "iPhone pauses CouchSubs in the background. Open CouchSubs to continue; it reconnects by itself. To keep translating in a small window, turn on “Keep translating in the background” in Profile.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: pausedDelay, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: pausedIdentifier, content: content, trigger: trigger))
    }

    private static let tvLostIdentifier = "tv-lost-while-away"

    /// #1303: uygulama arka plandayken TV bağlantısı koptu; altyazı yalnız telefonda kalıyordu ve nedeni söylenmiyordu.
    /// Uygulama öndeyse gösterilmez (ana ekrandaki not yeter). Android'deki TvAwayAlert ile aynı metin.
    static func postTVLostWhileAway() {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "TV connection lost")
        content.body = String(localized: "The TV lost the connection while CouchSubs was in the background. Keep CouchSubs open while you play; open it now and it reconnects by itself.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: tvLostIdentifier, content: content, trigger: nil))
    }

    static func clearTVLostWhileAway() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [tvLostIdentifier])
    }

    static func clearPausedInBackground() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [pausedIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [pausedIdentifier])
    }
}

/// "Bu TV eşleşsin mi?" penceresi. O an en üstte hangi ekran varsa (kök, tam ekran altyazı, bir sayfa) onun üstünde açılır.
@MainActor
final class TVPairingPrompt {
    private weak var alert: UIAlertController?
    private var shownId: String?

    func show(_ ticket: SubtitlePairing.Ticket?, resolve: @escaping (SubtitlePairing.Ticket, Bool) -> Void) {
        if let alert, alert.presentingViewController != nil {
            if shownId == ticket?.id { return }
            // İstek kalktı ya da yerini yenisi aldı: eski kodu gösteren pencere kapanır, yenisi bir sonraki denemede açılır.
            alert.dismiss(animated: false)
            self.alert = nil
            return
        }
        guard let ticket, let top = Self.topController(), !(top is UIAlertController),
              !top.isBeingPresented, !top.isBeingDismissed else { return }
        let alert = UIAlertController(
            title: String(localized: "Pair this TV?"),
            message: String(format: String(localized: "TV code: %@. You don't type this code anywhere: if your TV shows the same code, approve it here."), ticket.code),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Reject"), style: .cancel) { _ in resolve(ticket, false) })
        let approve = UIAlertAction(title: String(localized: "Approve"), style: .default) { _ in resolve(ticket, true) }
        alert.addAction(approve)
        alert.preferredAction = approve
        top.present(alert, animated: true)
        self.alert = alert
        shownId = ticket.id
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }),
              var top = (scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first)?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// Onay bekleyen TV eşleştirme isteği: pencere görünmese de her ekranın üstünde durur.
struct TVPairingBanner: View {
    @EnvironmentObject private var model: PhoneModel
    let ticket: SubtitlePairing.Ticket

    var body: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.inline) {
            Label(String(localized: "A TV wants to pair"), systemImage: "tv").font(Mobile.TypeScale.headline)
            Text(String(format: String(localized: "TV code: %@. You don't type this code anywhere: if your TV shows the same code, approve it here."), ticket.code))
                .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Mobile.Space.gap) {
                Button("Approve") { model.resolveTVPairing(ticket, accept: true) }.buttonStyle(.mobilePrimary)
                Button("Reject") { model.resolveTVPairing(ticket, accept: false) }.buttonStyle(.mobileSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Mobile.Space.tile)
        .background(Mobile.Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Mobile.Palette.accent).frame(height: 1.5) }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var promo: PromoController
    @AppStorage("welcomeSeen") private var welcomeSeen = false
    @State private var path: [Route] = []
    /// Perde: üç sekme (Ana Ekran · Geçmiş · Ayarlar); her sekmenin kökü gezinme yığınının kökünde.
    @State private var tab: PhoneTab = .home
    /// Klavye açıkken sekme çubuğu gizlenir (yazı alanının üstünde yer kaplamasın).
    @State private var keyboardShown = false
    @State private var pairingPrompt = TVPairingPrompt()

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
        .onChange(of: model.demoMode) { _ in
            path = []
            tab = .home
        }
        #if DEBUG
        // Hata ayıklama: COUCHSUBS_ROUTE=settings,packs gibi ekranları sırayla açar (simülatör ekran görüntüleri için).
        .task {
            // COUCHSUBS_START_DEMO=1: deneme modu (çeviri sürüyor ekranı) kendiliğinden açılır.
            if ProcessInfo.processInfo.environment["COUCHSUBS_START_DEMO"] == "1" {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await model.startDemo()
            }
            // COUCHSUBS_SETUP_STEP=hdmi: kurulumun TV girişi adımı (ekran görüntüsü için).
            if ProcessInfo.processInfo.environment["COUCHSUBS_SETUP_STEP"] == "hdmi" {
                welcomeSeen = true
                model.step = .hdmi
            }
            guard let names = ProcessInfo.processInfo.environment["COUCHSUBS_ROUTE"] else { return }
            // Ana ekran yerleşsin; yığın ilk çizimde değişirse gezinme boş kalıyor.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let routes: [String: Route] = ["settings": .settings, "profile": .profile, "packs": .packs, "target": .target,
                                           "ps5": .ps5, "psn": .psn, "about": .about, "history": .history,
                                           "platform": .platform, "tvInstall": .tvInstall,
                                           "basics": .settingsPage(.basics), "appearance": .settingsPage(.appearance),
                                           "advanced": .settingsPage(.advanced), "area": .settingsPage(.area),
                                           "dubbing": .settingsPage(.dubbing), "outputs": .settingsPage(.outputs),
                                           "console": .settingsPage(.console)]
            let tabs: [String: PhoneTab] = ["tab:home": .home, "tab:history": .history, "tab:settings": .settings]
            if let first = names.split(separator: ",").first, let chosen = tabs[String(first)] { tab = chosen }
            path = names.split(separator: ",").compactMap { routes[String($0)] }
        }
        #endif
        // TV'nin eşleştirme isteği: onay penceresi en üstteki ekranda açılır (tam ekran altyazı ya da bir sayfa açıkken de)
        // ve istek beklediği sürece her ekranın üstünde onay satırı durur. Eskiden pencere SwiftUI `.alert(item:)` ile kök
        // görünümden sunuluyordu: başka bir ekran sunulmuşken ya da istek değiştiğinde pencere sessizce düşebiliyor,
        // TV'de kod beklerken telefonda onaylanacak bir şey görünmüyordu (TestFlight, 21 Kas).
        .safeAreaInset(edge: .top, spacing: 0) {
            if let ticket = model.tvPairingRequest { TVPairingBanner(ticket: ticket) }
        }
        .animation(.easeOut(duration: 0.2), value: model.tvPairingRequest)
        .task(id: model.tvPairingRequest?.id) {
            // Pencere o an açılamıyorsa (uygulama önde değil, başka bir pencere kapanıyor) açılana kadar yeniden denenir.
            while !Task.isCancelled {
                pairingPrompt.show(model.tvPairingRequest) { ticket, accept in model.resolveTVPairing(ticket, accept: accept) }
                guard model.tvPairingRequest != nil else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Ayarlar › Temel › Görünüm: Açık, Koyu (varsayılan, Mac ile aynı) ya da Sisteme Uy; anahtarlar her yerde yeni dilde.
        .preferredColorScheme(model.settings.appearance.colorScheme)
        // Tek hareket kapısı: çeviri sürerken, hareketi azaltta, Geçiş Animasyonları kapalıyken ya da uygulama arka
        // plandayken sürekli animasyonlar durur (yalnız kısa geri bildirimler kalır).
        .dsMotionGate(translating: model.isRunning)
        // Ayarlar › Temel › Geçiş Animasyonları kapalıyken yeni dildeki bileşenler yalnız kısa solma kullanır.
        .environment(\.dsMotionOff, !model.settings.transitionAnimations)
        .tint(Mobile.Palette.accent)
        .toggleStyle(DSToggleStyle())
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
        case .hdmi:
            HDMIScreen(onBack: { model.back() }) { model.advance() }
        }
    }

    /// Sekme çubuğunda vurgulanan sekme: açık sayfa bir sekmeye aitse (Geçmiş, Ayarlar ve bölümleri) o, değilse seçili sekme.
    private var activeTab: PhoneTab { path.first?.tab ?? tab }

    /// Sekme çubuğu: kurulum adımlarında (konsol, giriş, eşleme, TV kurulumu) ve klavye açıkken yok; uygulama
    /// sayfalarında var (her ekranın alt çubuğunda, reklam şeridinin altında).
    private func tabBar(_ route: Route?) -> PerdeTabBarState? {
        guard route?.showsAdBand ?? true, !keyboardShown else { return nil }
        return PerdeTabBarState(active: activeTab, select: select)
    }

    private func select(_ chosen: PhoneTab) {
        // Aynı sekmeye yeniden dokunmak o sekmenin köküne döner (iOS alışkanlığı).
        path.removeAll()
        tab = chosen
    }

    /// TV kurulumu bitince "Ana Ekrana Geç".
    private func goHome() {
        path.removeAll()
        tab = .home
    }

    private var home: some View {
        NavigationStack(path: $path) {
            Group {
                switch tab {
                case .home:
                    if model.isRunning { RunningScreen(path: $path) } else { HomeScreen(path: $path) }
                case .history: HistoryScreen()
                case .settings: SettingsScreen(path: $path)
                }
            }
            // Reklam şeridi boştaki uygulama sayfalarında; çeviri sürerken (oyun görüntüsü ve açılan sayfalar) yok.
            .environment(\.mobileAdBand, PromoPolicy.adBandVisible(appPage: true, translating: model.isRunning, demo: model.demoMode))
            .environment(\.perdeTabBar, tabBar(nil))
            .navigationDestination(for: Route.self) { route in
                Group {
                // Ekranlar yığını `removeLast()` ile değil `pop(route)` ile kapatır: kapanma animasyonu sürerken ikinci
                // dokunuşta yığın boşalmış olur ve `removeLast()` uygulamayı kapatırdı (TestFlight çökmesi, yapı 18).
                switch route {
                case .settings: SettingsScreen(path: $path)
                case .settingsPage(let section): SettingsPageScreen(section: section, path: $path)
                // Profil Ayarlar'a katıldı (hesap kartları, cihazlar, bildirimler); eski bağlantılar Ayarlar'ı açar.
                case .profile: SettingsScreen(path: $path)
                case .packs: PacksScreen()
                case .target: TargetScreen(setup: false) { path.pop(route) }
                // Kurulum atlandıysa PSN girişi yoktur: PS5 eşlemeden önce giriş yapılır, ardından eşlemeye geçilir.
                case .platform:
                    PlatformScreen(onBack: { path.pop(route) }) {
                        if path.pop(route), model.isXbox && (!model.xboxSignedIn || model.xboxConsole == nil) { path.append(.ps5) }
                    }
                // Xbox (Beta): giriş yoksa önce Microsoft girişi, ardından Xbox seçimi.
                case .ps5 where model.isXbox && !model.xboxSignedIn:
                    XboxLoginScreen(onBack: { path.pop(route) }, onDone: {
                        if path.pop(route) { path.append(.ps5) }
                    })
                case .ps5 where model.isXbox:
                    XboxConsoleScreen(onBack: { path.pop(route) }, onSignIn: { model.signOutXbox() }, onDone: { path.pop(route) })
                case .ps5 where model.accountId == nil:
                    PSNScreen(onBack: { path.pop(route) }, onDone: {
                        if path.pop(route) { path.append(.ps5) }
                    })
                case .ps5: PS5PairScreen(onBack: { path.pop(route) }, onDone: { path.pop(route) })
                case .psn: PSNScreen(onBack: { path.pop(route) }, onDone: { path.pop(route) })
                case .about: AboutScreen()
                case .history: HistoryScreen()
                case .tvInstall: TVInstallScreen(onDone: goHome)
                case .tvUpdate: TVInstallScreen(update: model.tvAppUpdate, onDone: goHome)
                }
                }
                .environment(\.mobileAdBand, PromoPolicy.adBandVisible(appPage: route.showsAdBand, translating: model.isRunning, demo: model.demoMode))
                .environment(\.perdeTabBar, tabBar(route))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardShown = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardShown = false }
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            if !app.tourDone && path.isEmpty && tab == .home && !model.isRunning && !model.demoMode {
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
        PromoMoment(onHome: path.isEmpty && tab == .home, sessionActive: model.isRunning || model.isStarting, demo: model.demoMode,
                    onboarding: !welcomeSeen || model.step != .done, tour: !app.tourDone,
                    inApp: Date().timeIntervalSince(promo.foregroundAt))
    }
}
