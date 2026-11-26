// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import Darwin
import Combine
import RemotePlay
import XboxStream

/// Dış dünyayla (PS5, PSN, TV) konuşan her şey; testlerde sahtesi kullanılır.
extension AppServices {
    /// Eşleşme isteği gönderen TV: marka ve ad adresten yoklanır (bkz. `PairedTV.identify`); tanınmazsa nil.
    func identifyTV(host: String) async -> LGTV? { await PairedTV.identify(host: host) }
    /// DeepL anahtarını dener (ayarlardaki "Kaydet ve dene").
    func checkOnlineKey(_ key: String) async -> OnlineKeyCheck { await DeepLTranslator.check(key: key) }
    /// Yapay zekâ anahtarını örnek bir satırı çevirerek dener.
    func testAIKey(provider: AIProvider, key: String, model: String?) async -> Result<String, AIFailure> {
        await AITranslationCore.test(provider: provider, key: key, model: model)
    }
    /// Yerel model sunucusunu (Ollama, LM Studio) örnek bir satırı çevirerek dener; anahtar boş olabilir.
    func testLocalAI(server: LocalAIServer, key: String) async -> Result<String, AIFailure> {
        await AITranslationCore.test(provider: .local, key: key, model: server.model, server: server)
    }
    /// Bu Mac'teki Remote Play penceresinden (PS Remote Play ya da chiaki-ng) okuyan görüntü kaynağı (bkz. `RemotePlayWindowStream`).
    func makeWindowStream(app: RemotePlayApp) -> StreamControlling { RemotePlayWindowStream(app: app) }
    func remotePlayInstalled(_ app: RemotePlayApp) -> Bool { RemotePlayWindowStream.isInstalled(app) }
    /// Kullanıcının seçtiği OBS projektörü ya da oyun penceresini okuyan kaynak; aynı ScreenCaptureKit hattı.
    func makeCaptureWindowStream(target: WindowCaptureTarget) -> StreamControlling { RemotePlayWindowStream(target: target) }
    func captureWindows() async -> [WindowCaptureTarget] { await RemotePlayWindowStream.captureWindows() }
    func screenRecordingAllowed() -> Bool { RemotePlayWindowStream.screenRecordingAllowed }
    func openScreenRecordingSettings() { RemotePlayWindowStream.openScreenRecordingSettings() }
    /// PS5'te o an çalışan oyun (ortak havuz için; bkz. `RunningGame`): kayıtlı adrese keşif sorusu gider. Yanıt yoksa ya
    /// da yanıt veren başka bir PS5'se kayıtlı PS5 ağda kimliğiyle aranır; yeni adreste bulunursa kayıt güncellenir
    /// (`ConsoleFinder.onChange`). Eskiden yoklama hep ilk adrese bakıyordu.
    func runningGame(finder: ConsoleFinder) async -> RunningGame? {
        let info = await Task.detached { finder.locate().info }.value
        guard let info else { return nil }
        return RunningGame(titleId: info.runningAppTitleId, name: info.runningAppName)
    }
    /// Xbox (Beta): Microsoft girişi ve jeton zinciri (testlerde sahte HTTP'li bir `XboxAuth` verilir).
    func makeXboxAuth(userToken: XboxUserToken?, onUserToken: @escaping @Sendable (XboxUserToken?) -> Void) -> XboxAuth {
        XboxAuth(userToken: userToken, onUserToken: onUserToken)
    }
    /// Hesaptaki Xbox'lar (smartglass listesi).
    func xboxConsoles(auth: XboxAuth) async throws -> [XboxConsole] { try await XboxHome(auth: auth).consoles() }
    /// Xbox ev yayını oturumu (iPhone'la ortak `XboxStreamSession`); ekran metinleri `XboxText`'ten.
    func makeXboxStream(auth: XboxAuth, console: XboxConsole, playAudio: Bool) -> StreamControlling {
        XboxStreamSession(auth: auth, console: console, playAudio: playAudio, describe: XboxText.session, stopped: XboxText.stopped)
    }
    /// Samsung kurulumundan önce: TV'nin 8001 yanıtı ve TV'ye giden yolun bu Mac'teki adresi (#343).
    func checkSamsung(host: String) async -> SamsungPreflight {
        SamsungPreflight(info: await SamsungDiscovery.developerInfo(host: host), computerAddress: NetworkAddress.near(host))
    }
}

/// Samsung kurulumundan önceki denetim: TV'nin geliştirici modu bilgisi ve TV'nin göreceği bu Mac'in adresi.
struct SamsungPreflight: Equatable {
    var info: SamsungDeveloperInfo?
    var computerAddress: String?
}

protocol AppServices: AnyObject {
    /// Yapay zekâ anahtarını örnek bir satırı çevirerek dener (varsayılanı yukarıda; testlerde sahtesi).
    func testAIKey(provider: AIProvider, key: String, model: String?) async -> Result<String, AIFailure>
    /// Yerel model sunucusunu dener (varsayılanı yukarıda; testlerde sahtesi).
    func testLocalAI(server: LocalAIServer, key: String) async -> Result<String, AIFailure>
    func discoverConsoles() async -> [ConsoleInfo]
    func accountId(fromRedirect url: URL) async throws -> Data
    func register(host: String, accountId: Data, pin: UInt32) async throws -> RegisteredConsole
    func discoverTVs() async -> [LGTV]
    /// TV ile eşleşir ve TV uygulamasını sunucu adresiyle başlatmayı dener.
    func pairTV(_ tv: LGTV, key: String?, server: String, accessKey: String) async throws -> TVPairing
    func identifyTV(host: String) async -> LGTV?
    /// `loginPasscode`: PS5 bu hesap için giriş şifresi isterse gönderilecek 4 hane (Ayarlar'da kayıtlıysa).
    func makeStream(console: RegisteredConsole, accountId: Data, loginPasscode: String?) -> StreamControlling
    /// Görüntüyü bu Mac'teki Remote Play penceresinden alan kaynak (`UserSettings.frameSource`, `remotePlayApp`).
    func makeWindowStream(app: RemotePlayApp) -> StreamControlling
    /// Seçilen Remote Play uygulaması (PS Remote Play ya da chiaki-ng) bu Mac'te kurulu mu.
    func remotePlayInstalled(_ app: RemotePlayApp) -> Bool
    /// Seçilen pencereden okuma (`UserSettings.captureWindow`): kaynak, seçilebilir pencereler ve ekran kaydı izni
    /// (varsayılanları yukarıda; testlerde sahtesi).
    func makeCaptureWindowStream(target: WindowCaptureTarget) -> StreamControlling
    func captureWindows() async -> [WindowCaptureTarget]
    func screenRecordingAllowed() -> Bool
    func openScreenRecordingSettings()
    /// Xbox (Beta): Microsoft girişi, hesaptaki Xbox'lar ve ev yayını oturumu (varsayılanları yukarıda; testlerde sahtesi).
    func makeXboxAuth(userToken: XboxUserToken?, onUserToken: @escaping @Sendable (XboxUserToken?) -> Void) -> XboxAuth
    func xboxConsoles(auth: XboxAuth) async throws -> [XboxConsole]
    func makeXboxStream(auth: XboxAuth, console: XboxConsole, playAudio: Bool) -> StreamControlling
    /// `onMoved`: TV ağda yeni bir adreste bulununca çağrılır.
    /// `appConnected`: TV uygulaması bilgisayara bağlı mı (Samsung'da bağlıyken TV'ye dokunulmaz).
    /// `onKey`: TV bağlantıda yeni jeton verdi (Samsung); saklanır.
    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void, onKey: @escaping @Sendable (String) -> Void,
                    consolePort: @escaping @Sendable () -> Int?,
                    onOpenResult: @escaping @Sendable (TVOpenProblem?) -> Void) -> KeeperControlling
    /// Bu Mac'in ev ağı adresini izler; değişince `onChange` (bkz. `SenderAddressWatcher`). Testlerde izlenmez.
    func makeAddressWatcher(onChange: @escaping @Sendable ([String], [String]) -> Void) -> AddressWatching?
    /// Uygulamayla gelen TV paketinin sürümü (geliştirici derlemesinde paket olmayabilir).
    var bundledTVAppVersion: String? { get }
    func isDevModeOn(host: String) async -> Bool
    /// Kayıtlı TV adresinde bir şey yanıt veriyor mu (kapı açık ya da reddediyor); hepsi zaman aşımındaysa hayır (`TVReach`).
    func tvResponds(host: String, brand: TVBrand) async -> Bool
    func fetchDevKey(host: String, passphrase: String) async throws -> String
    func installedTVAppVersion(host: String, devKey: String) async throws -> String?
    func installTVApp(host: String, devKey: String) async throws
    /// LG: TV'de açık CouchSubs'ı kapatır (eski sürümde çalışıyorsa; kurulum bunu kendisi de yapar).
    func closeTVApp(host: String, devKey: String) async
    /// LG geliştirici modunun süresini baştan başlatır; kalan saati döner (bilinmiyorsa nil).
    func renewDevSession(host: String, devKey: String) async -> Int?

    /// Samsung ve Android TV için uygulamayla gelen paket (geliştirici derlemesinde olmayabilir).
    func bundledApp(for brand: TVBrand) -> BundledTVApp?
    func isSamsungDevModeOn(host: String) async -> Bool
    func checkSamsung(host: String) async -> SamsungPreflight
    /// TV'deki sürüme bakar, eksik ya da eskiyse kurar; TV'deki sürümü ve kurulup kurulmadığını döner.
    func installSamsungApp(host: String, app: BundledTVApp,
                           onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> (version: String, installed: Bool)
    func isAndroidDebugOn(host: String) async -> Bool
    /// Ağda ADB'si açık cihazlar.
    func scanAndroidTVs() async -> [String]
    /// Eksikse ya da eskiyse kurar; TV'deki sürümü döner. `open`: uygulama güncelse de TV'de açılır ("yeniden kur").
    func installAndroidApp(host: String, app: BundledTVApp, open: Bool, onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> String

    /// `replaceForeign`: kullanıcı "Kaldırıp Kur" dedi; TV'de CouchSubs'ın kimliğini kullanan başka uygulama önce kaldırılır.
    /// Üç markada da onay yoksa hiçbir şey silinmez, `DevModeError.foreignApp` gelir (Windows'taki IAppServices ile aynı).
    func installTVApp(host: String, devKey: String, replaceForeign: Bool) async throws
    func installSamsungApp(host: String, app: BundledTVApp, replaceForeign: Bool,
                           onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> (version: String, installed: Bool)
    func installAndroidApp(host: String, app: BundledTVApp, open: Bool, replaceForeign: Bool,
                           onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> String
}

extension AppServices {
    func closeTVApp(host: String, devKey: String) async {}

    func installTVApp(host: String, devKey: String, replaceForeign: Bool) async throws {
        try await installTVApp(host: host, devKey: devKey)
    }

    func installSamsungApp(host: String, app: BundledTVApp, replaceForeign: Bool,
                           onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> (version: String, installed: Bool) {
        try await installSamsungApp(host: host, app: app, onEvent: onEvent)
    }

    func installAndroidApp(host: String, app: BundledTVApp, open: Bool, replaceForeign: Bool,
                           onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> String {
        try await installAndroidApp(host: host, app: app, open: open, onEvent: onEvent)
    }
}

struct BundledTVApp: Equatable {
    let url: URL
    let version: String

    /// `couchsubs-androidtv_0.7.0.apk` → `0.7.0`
    static func version(ofFile name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        guard let underscore = stem.lastIndex(of: "_"), underscore < stem.index(before: stem.endIndex) else { return nil }
        return String(stem[stem.index(after: underscore)...])
    }
}

/// Denetlenemeyen TV'ler için: TV uygulaması kendisi bağlanır.
final class IdleKeeper: KeeperControlling {
    func start(interval: Duration) {}
    func stop() {}
    func reconnect() {}
}

struct TVPairing: Equatable {
    let key: String
    /// false ise TV uygulaması açılamadı; büyük olasılıkla TV'de kurulu değil.
    let launched: Bool
}

/// PS5 bağlantısı (gerçekte `StreamSession`).
protocol StreamControlling: AnyObject {
    var onFrame: ((CGImage) -> Void)? { get set }
    var onState: ((SessionState) -> Void)? { get set }
    /// PS5 ağda yeni bir adreste bulundu; yeni adres kaydedilir.
    var onConsoleMoved: ((RegisteredConsole) -> Void)? { get set }
    func start()
    func stop()
    func reconnectNow()
    /// Oturum yeniden denemeyi kendisi bıraktı (kullanıcı durdurmadı); `reconnectNow` artık bir şey yapmaz.
    var hasGivenUp: Bool { get }
    /// Xbox: "Xbox sesini bu bilgisayarda çal" çeviri sürerken değişti; yalnız yerel ses açılır/kısılır (#871).
    func setPlayAudio(_ enabled: Bool)
    /// PS5: bağlanırken son adım; "Bağlanıyor…" 30 sn'yi geçince nedeni söylenir (Xbox ve pencereden okumada yok).
    var connectStep: ConnectStep? { get }
    /// Karelerin kopyalanma sıklığı (`FrameCadence`; Windows IStreamSession.UseCadence ile aynı): oturum kareyi kendi
    /// belleğimize kopyalamadan önce sorar. Vermeyen oturum kendi hızında gönderir.
    func useCadence(_ cadence: FrameCadence)
}

extension StreamControlling {
    func setPlayAudio(_ enabled: Bool) {}
    var connectStep: ConnectStep? { nil }
    func useCadence(_ cadence: FrameCadence) {}
}

/// TV uygulamasını açık tutan görevli (gerçekte `TVKeeper`).
protocol KeeperControlling: AnyObject {
    func start(interval: Duration)
    func stop()
    func reconnect()
    /// LG: uygulama kapatıldı (kurulumdan sonra); bağlı görünse de bir kez açılır (TVKeeper.reopenApp).
    func reopenApp()
}

extension KeeperControlling {
    func reopenApp() { reconnect() }
}

extension StreamSession: StreamControlling {}
/// Bu cihazın ev ağı adresini izleyen görevli (gerçekte `SenderAddressWatcher`).
protocol AddressWatching: AnyObject { func stop() }
extension SenderAddressWatcher: AddressWatching {}
extension AppServices {
    /// Varsayılan: izlenmez (testlerin sahte hizmetleri).
    func makeAddressWatcher(onChange: @escaping @Sendable ([String], [String]) -> Void) -> AddressWatching? { nil }
}
/// Xbox ev yayını (Beta): iPhone'la ortak oturum (remoteplay/Sources/XboxStream).
extension XboxStreamSession: StreamControlling {}
extension TVKeeper: KeeperControlling {}

/// Deneme modunun "konsolu": uygulamadaki örnek kareleri (`DemoFrameSource`) akış gibi verir; ağ kullanmaz.
final class DemoStream: StreamControlling {
    var onFrame: ((CGImage) -> Void)?
    var onState: ((SessionState) -> Void)?
    var onConsoleMoved: ((RegisteredConsole) -> Void)?
    private let source = DemoFrameSource()

    func start() {
        source.onFrame = { [weak self] frame in self?.onFrame?(frame) }
        source.start()
        onState?(.streaming)
    }

    func stop() { source.stop() }

    func reconnectNow() {}

    var hasGivenUp: Bool { false }
}

final class LiveServices: AppServices {
    func discoverConsoles() async -> [ConsoleInfo] {
        let found = await Console.discover()
        let names = found.map { "\($0.name) \($0.host)\($0.isAwake ? "" : " (dinlenmede)")" }
        RemotePlayLog.write("PS5 araması: \(names.isEmpty ? "bulunamadı" : names.joined(separator: ", "))")
        return found
    }

    func accountId(fromRedirect url: URL) async throws -> Data {
        try await PSNAccount.accountId(fromRedirect: url)
    }

    func register(host: String, accountId: Data, pin: UInt32) async throws -> RegisteredConsole {
        try await Registration.register(host: host, accountId: accountId, pin: pin)
    }

    func discoverTVs() async -> [LGTV] {
        async let lg = LGDiscovery.search()
        async let samsung = SamsungDiscovery.search()
        return await lg + samsung
    }

    func pairTV(_ tv: LGTV, key: String?, server: String, accessKey: String) async throws -> TVPairing {
        switch tv.brand {
        case .androidTV:
            // Bilgisayar bu TV'yi denetlemez; TV uygulaması bilgisayarı kendisi bulur.
            return TVPairing(key: "", launched: true)
        case .samsung:
            SamsungAppKnowledge.installLog = { TVInstallLog.write($0) }
            let client = SamsungClient(tv: tv, token: key)
            defer { client.close() }
            let token: String
            do {
                token = try await client.connect()
            } catch {
                // TV uzaktan kumanda iznini sormadı ya da izin 60 saniyede gelmedi (The Frame'de Sanat Modu, izin kutusu
                // kapalı TV'ler) ama ağda yanıt veriyor: eşleşme durmaz, TV uygulaması geliştirici bağlantısıyla kurulup
                // açılır. Önceden "Bağlan" bir dakika bekleyip başa dönüyordu. Açıkça reddedildiyse hata gösterilir.
                if (error as? SamsungClient.SamsungError) == .rejected { throw error }
                guard await SamsungDiscovery.developerInfo(host: tv.host) != nil else { throw error }
                TVInstallLog.write("Samsung uzaktan kumanda izni alınamadı (\(error)); TV 8001'de yanıt verdi, eşleşme izinsiz sürdü.")
                return TVPairing(key: key ?? "", launched: true)
            }
            // TV uygulamanın kurulu olduğunu doğrulamadıysa (listede yok ya da liste 3 sn'de gelmedi) açma komutu gitmez:
            // kurulum adımları görünür (Smart Hub mağaza aramasına gidip "AS400" demesin; iPhone ve Windows ile aynı).
            do {
                try await client.launch(appId: AppIdentity.samsungAppId, params: ["server": server, "key": accessKey])
            } catch SamsungClient.SamsungError.notInstalled {
                return TVPairing(key: token, launched: false)
            } catch {}
            return TVPairing(key: token, launched: true)
        case .lg:
            break
        }
        let client = SSAPClient(tv: tv, clientKey: key)
        defer { client.close() }
        let newKey = try await client.connect()
        let launched = (try? await client.launch(appId: AppIdentity.tvAppId, params: ["server": server, "key": accessKey])) != nil
        return TVPairing(key: newKey, launched: launched)
    }

    func makeStream(console: RegisteredConsole, accountId: Data, loginPasscode: String?) -> StreamControlling {
        StreamSession(console: console, accountId: accountId, loginPasscode: loginPasscode)
    }

    func makeAddressWatcher(onChange: @escaping @Sendable ([String], [String]) -> Void) -> AddressWatching? {
        let watcher = SenderAddressWatcher(onChange: onChange)
        watcher.start()
        return watcher
    }

    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void, onKey: @escaping @Sendable (String) -> Void,
                    consolePort: @escaping @Sendable () -> Int?,
                    onOpenResult: @escaping @Sendable (TVOpenProblem?) -> Void) -> KeeperControlling {
        switch tv.brand {
        case .androidTV:
            // ADB açıksa (uygulama bu Mac'ten kurulduysa) CouchSubs TV Mac'in adresiyle açılır ve bağlanana kadar arada bir
            // yeniden açılır (iPhone, Windows ve Android telefonla aynı). Eskiden Mac Android TV'ye hiç dokunmuyordu.
            guard TVHelper.executable != nil, let server = params["server"] as? String, !tv.host.isEmpty else { return IdleKeeper() }
            // TV'ye ulaşılamazsa ağda yeniden aranır (LG ve Samsung'daki TVLocator gibi; iPhone ve Windows ile aynı).
            let locator = AndroidTVLocator(tv: tv, onMoved: { moved in DispatchQueue.main.async { onMoved(moved) } },
                                           log: { TVInstallLog.write($0) })
            return AndroidTVKeeper(host: tv.host, server: server, appConnected: appConnected, locator: locator, onOpenResult: onOpenResult)
        case .samsung:
            SamsungAppKnowledge.installLog = { TVInstallLog.write($0) }
            let token = SamsungTokenHolder(token: key, onChange: onKey)
            let paired = tv.host
            let locator = TVLocator(tv: tv, connect: { tv in
                // Adresi değişen TV'de kurulu olduğu bilgisi yeni adrese de geçer (yoksa bekçi listeye bakıp açmayabilir).
                SamsungAppKnowledge.shared.carry(from: paired, to: tv.host)
                let client = SamsungClient(tv: tv, token: token.current)
                do {
                    let received = try await client.connect()
                    token.received(received)
                } catch {
                    client.close()
                    throw error
                }
                return client
            }, search: { await SamsungDiscovery.search() }, onMoved: onMoved, log: { TVInstallLog.write($0) })
            // Önce geliştirici bağlantısı (sdb) denenir: uzaktan kumanda bağlantısıyla açma Tizen 9.0'da (2025 Neo QLED,
            // OLED) sessizce çalışmıyor, arka plana düşen TV uygulaması geri gelmiyordu (Windows'ta #412).
            let host = tv.host
            // "resumed" (uygulama çalışıyor ama bağlı değil) 8002'ye düşmez; bağlanmazsa sdb ile kapatılıp açılır (#1248).
            return TVKeeper(connect: { SamsungLauncher(openWithSdb: { await Self.openSamsungApp(host: host, restart: $0) },
                                                       appConnected: appConnected,
                                                       connectRemote: { try await locator.connect() }) },
                            appId: AppIdentity.samsungAppId, params: params, appConnected: appConnected, onOpenResult: onOpenResult)
        case .lg:
            break
        }
        let locator = TVLocator(tv: tv, connect: { tv in
            let client = SSAPClient(tv: tv, clientKey: key)
            do {
                _ = try await client.connect()
            } catch {
                client.close()
                throw error
            }
            return client
        }, search: { await LGDiscovery.search() }, onMoved: onMoved, log: { TVInstallLog.write($0) })
        // Açık ve bağlı TV uygulamasına yeni bağlantıda açma komutu gitmez (#1055; iPhone, Windows ve Android ile aynı).
        return TVKeeper(connect: { try await locator.connect() }, appId: AppIdentity.tvAppId, params: params, consolePort: consolePort,
                        onOpenResult: onOpenResult, tvConnected: appConnected)
    }

    // MARK: - TV uygulamasını kurma

    private var bundledTVPackage: URL? {
        Bundle.main.urls(forResourcesWithExtension: "ipk", subdirectory: "tv-app")?.first
    }

    var bundledTVAppVersion: String? {
        bundledTVPackage.flatMap { DevModeInstaller.version(ofPackage: $0.lastPathComponent) }
    }

    func isDevModeOn(host: String) async -> Bool { await DevModeInstaller.isDevModeOn(host: host) }

    func tvResponds(host: String, brand: TVBrand) async -> Bool { await TVReach.responds(host: host, brand: brand) }

    func fetchDevKey(host: String, passphrase: String) async throws -> String {
        try await DevModeInstaller.fetchKey(host: host, passphrase: passphrase, runner: ProcessRunner())
    }

    func installedTVAppVersion(host: String, devKey: String) async throws -> String? {
        try await withKeyFile(devKey) { file in
            // TV'de CouchSubs'ın kimliğiyle başka uygulama varsa sürümü yerine DevModeFailure(.foreignApp).
            try await DevModeInstaller(host: host, keyFile: file, runner: ProcessRunner()).checkInstalledVersion()
        }
    }

    func installTVApp(host: String, devKey: String) async throws {
        try await installTVApp(host: host, devKey: devKey, replaceForeign: false)
    }

    func installTVApp(host: String, devKey: String, replaceForeign: Bool) async throws {
        guard let package = bundledTVPackage, let version = bundledTVAppVersion else { throw DevModeError.installFailed }
        try await withKeyFile(devKey) { file in
            let installer = DevModeInstaller(host: host, keyFile: file, runner: ProcessRunner())
            // Kullanıcı "Kaldırıp Kur" dedi: CouchSubs'ın kimliğini kullanan başka uygulama önce kaldırılır.
            if replaceForeign {
                TVInstallLog.write("LG: kullanıcı onayıyla TV'deki com.couchsubs.tv kaldırıldı: \(try await installer.removeApp())")
            }
            try await installer.install(package: package, version: version)
        }
    }

    func closeTVApp(host: String, devKey: String) async {
        _ = try? await withKeyFile(devKey) { file in
            let reply = await DevModeInstaller(host: host, keyFile: file, runner: ProcessRunner()).closeApp()
            TVInstallLog.write("LG: TV'deki CouchSubs kapatıldı: \(reply)")
        }
    }

    func renewDevSession(host: String, devKey: String) async -> Int? {
        try? await withKeyFile(devKey) { file in
            try await DevModeInstaller(host: host, keyFile: file, runner: ProcessRunner()).renewSession()
        }
    }

    // MARK: Samsung ve Android TV (gömülü yardımcıyla)

    func bundledApp(for brand: TVBrand) -> BundledTVApp? {
        let ext = switch brand {
        case .samsung: "wgt"
        case .androidTV: "apk"
        case .lg: "ipk"
        }
        guard brand != .lg, TVHelper.executable != nil,
              let url = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "tv-app")?.first,
              let version = BundledTVApp.version(ofFile: url.lastPathComponent) else { return nil }
        return BundledTVApp(url: url, version: version)
    }

    func isSamsungDevModeOn(host: String) async -> Bool { await Self.isPortOpen(host: host, port: 26101) }

    func installSamsungApp(host: String, app: BundledTVApp,
                           onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> (version: String, installed: Bool) {
        try await installSamsungApp(host: host, app: app, replaceForeign: false, onEvent: onEvent)
    }

    func installSamsungApp(host: String, app: BundledTVApp, replaceForeign: Bool,
                           onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> (version: String, installed: Bool) {
        // Aynı TV'de kurulum zaten sürüyorsa yenisi başlatılmaz, sürenin sonucu döner; bekçinin sdb açması kurulum bitene
        // kadar bekler (#1223; TVLane, Windows ve telefonlarla aynı).
        let arguments = ["samsung-install", "--host", host, "--package", app.url.path, "--version", app.version,
                         "--profiles", TVHelper.dataDirectory.appendingPathComponent("samsung").path,
                         "--log", TVInstallLog.file.path] + (replaceForeign ? ["--replace-foreign"] : [])
        let result = try await TVLane.shared.installAsync(host: host, log: { TVInstallLog.write($0) }) {
            try await TVHelper.run(arguments, onEvent: onEvent)
        }
        let version = result.version.flatMap { $0.isEmpty ? nil : $0 } ?? app.version
        return (version, result.installed)
    }

    /// Kurulu TV uygulamasını geliştirici bağlantısıyla (sdb, `was_execute`) açar; `restart` ise önce kapatır (`was_kill`).
    /// Geliştirici modu kapalıysa, Host PC IP başka bilgisayarınsa ya da TV açmadıysa `.failed`; uygulama zaten çalışıyor
    /// ve yalnız öne geldiyse `.resumed`.
    static func openSamsungApp(host: String, restart: Bool = false) async -> SamsungSdbOpen {
        guard !host.isEmpty, await isPortOpen(host: host, port: 26101) else { return .failed }
        let arguments = ["samsung-open", "--host", host,
                         "--profiles", TVHelper.dataDirectory.appendingPathComponent("samsung").path,
                         "--log", TVInstallLog.file.path] + (restart ? ["--restart"] : [])
        // Aynı TV'de kurulum ya da başka bir sdb oturumu sürüyorsa sırası beklenir (#1223; TVLane).
        let result = await TVLane.shared.runAsync(host: host, restart ? "kapatıp açma" : "açma", log: { TVInstallLog.write($0) }) {
            try? await TVHelper.run(arguments)
        }
        return result.map(TVHelper.sdbOpen) ?? .failed
    }

    func isAndroidDebugOn(host: String) async -> Bool { await Self.isPortOpen(host: host, port: 5555) }

    func scanAndroidTVs() async -> [String] {
        (try? await TVHelper.run(["android-scan"]).hosts) ?? []
    }

    func installAndroidApp(host: String, app: BundledTVApp, open: Bool, onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> String {
        try await installAndroidApp(host: host, app: app, open: open, replaceForeign: false, onEvent: onEvent)
    }

    func installAndroidApp(host: String, app: BundledTVApp, open: Bool, replaceForeign: Bool,
                           onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> String {
        let arguments = ["android-install", "--host", host, "--package", app.url.path, "--version", app.version,
                         "--key-dir", TVHelper.dataDirectory.appendingPathComponent("adb").path,
                         "--log", TVInstallLog.file.path] + (open ? ["--open"] : []) + (replaceForeign ? ["--replace-foreign"] : [])
        // Aynı TV'de kurulum zaten sürüyorsa yenisi başlatılmaz; bekçinin ADB açması kurulum bitene kadar bekler (#1223).
        let result = try await TVLane.shared.installAsync(host: host, log: { TVInstallLog.write($0) }) {
            try await TVHelper.run(arguments, onEvent: onEvent)
        }
        return result.version ?? app.version
    }

    static func isPortOpen(host: String, port: UInt16) async -> Bool {
        await DevModeInstaller.isPortOpen(host: host, port: port)
    }

    /// ssh anahtarı dosyadan okur; dosya yalnız komut süresince durur.
    private func withKeyFile<T>(_ key: String, _ body: (URL) async throws -> T) async throws -> T {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw DevModeError.installFailed
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return try await body(file)
    }
}

enum AppError: LocalizedError, Equatable {
    case invalidPin, invalidLogin, missingAccount, wrongAccount, registrationFailed
    /// PS5 eşleştirmesinin ayrı ayrı anlatılan sonuçları (Windows'taki AppError ile aynı).
    case missingConsole, wrongCode, consoleNoAnswer, consoleNoReply, consoleInUse, consoleCrashed, consoleVersion,
         badAddress, localNetworkBlocked
    /// PS5 ağda ama eşleştirme ekranı kapalı; PS5 bulundu ama bağlantı açılamadı; bu cihazda boş port kalmadı (GitHub #590).
    case consolePairingClosed, consoleConnectFailed, noFreePort
    /// PSN girişinin ayrı ayrı anlatılan sonuçları (eskiden hepsi invalidLogin ya da ham Swift hatasıydı).
    case loginRefused, loginRateLimited, loginServer, loginNetwork, loginBadResponse, loginWindowClosed, loginPageFailed

    /// PSN girişinin hatası ve iletiye eklenecek ayrıntı (Sony'nin hatası, HTTP kodu).
    static func login(_ error: PSNAccount.PSNError) -> DetailedError {
        func detail(_ status: Int?, _ text: String?) -> String? {
            let candidates: [String?] = [status.map { "HTTP \($0)" }, text]
            let parts = candidates.compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        switch error {
        case .noCode: return DetailedError(error: .invalidLogin, detail: nil)
        case .refused(let status, let text): return DetailedError(error: .loginRefused, detail: detail(status, text))
        case .rateLimited(let status, let text): return DetailedError(error: .loginRateLimited, detail: detail(status, text))
        case .http(let status, let text): return DetailedError(error: .loginServer, detail: detail(status, text))
        case .network(let text): return DetailedError(error: .loginNetwork, detail: text)
        case .badResponse: return DetailedError(error: .loginBadResponse, detail: nil)
        }
    }

    init(_ kind: Registration.RegistrationError.Kind) {
        switch kind {
        case .wrongAccount: self = .wrongAccount
        case .wrongCode: self = .wrongCode
        case .noAnswer: self = .consoleNoAnswer
        // libchiaki iptali yalnız durdurulunca bildirir; bu da PS5'in yanıtı gelmeden bitmek demektir.
        case .noReply, .canceled: self = .consoleNoReply
        case .inUse: self = .consoleInUse
        case .consoleCrashed: self = .consoleCrashed
        case .versionMismatch: self = .consoleVersion
        case .badAddress: self = .badAddress
        case .localNetworkBlocked: self = .localNetworkBlocked
        case .pairingClosed: self = .consolePairingClosed
        case .connectFailed: self = .consoleConnectFailed
        case .noFreePort: self = .noFreePort
        case .failed: self = .registrationFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidPin: String(localized: "The code must be 8 digits.")
        case .invalidLogin: String(localized: "Sign-in did not complete. Please try again.")
        case .missingAccount: String(localized: "Sign in to PlayStation Network first.")
        case .wrongAccount: String(localized: "The PS5 did not recognise this account. Get the code from the PS5 user signed in with the account you used in CouchSubs, or sign in again with that user's account.")
        case .registrationFailed: String(localized: "The PS5 refused the code. Open Pair Device again on the PS5 and enter the new code.")
        case .missingConsole: String(localized: "No PS5 found. Make sure it is on and on the same network, or enter its IP address.")
        case .wrongCode: String(localized: "The code is wrong or has expired. Open Pair Device again on the PS5 and enter the new code.")
        case .consoleNoAnswer: String(localized: "The PS5 did not answer. Make sure it is on (not in rest mode), on the same network as this computer, and that Remote Play is turned on, then try again.")
        case .consoleNoReply: String(localized: "The PS5 received the request but did not answer in time. Open Pair Device again on the PS5 and enter the new code.")
        case .consoleInUse: String(localized: "Remote Play is in use on another device. Close it there and enter a new code.")
        case .consoleCrashed: String(localized: "The PS5 Remote Play service stopped unexpectedly. Restart the PS5 and enter a new code.")
        case .consoleVersion: String(localized: "This PS5 system version is not supported yet. Update CouchSubs and try again.")
        case .badAddress: String(localized: "No PS5 found at this address. Check the PS5's IP address under Settings › Network › Connection Status.")
        case .localNetworkBlocked: String(localized: "macOS blocked the connection to the local network. Turn on CouchSubs in System Settings › Privacy & Security › Local Network, then enter a new code.")
        case .consolePairingClosed: String(localized: "The PS5 is on the network but is not waiting for a code. On the PS5 open Settings › System › Remote Play › Pair Device and enter the new code it shows. If the PS5 is in rest mode, turn it on first.")
        case .consoleConnectFailed: String(localized: "The PS5 answered, but the pairing connection to it could not be opened. Turn off any VPN or firewall app that blocks the home network, then open Pair Device again on the PS5 and enter the new code.")
        case .noFreePort: String(localized: "This computer has no free network ports left, so it cannot connect to the PS5. Restart the computer, then open Pair Device again on the PS5 and enter the new code.")
        case .loginRefused: String(localized: "Sony did not complete the sign-in. Wait a minute, then press Sign in again and sign in with the second account.")
        case .loginRateLimited: String(localized: "Sony received too many sign-in attempts. Wait about 15 minutes, then sign in again.")
        case .loginServer: String(localized: "Sony's sign-in server returned an error. Wait a few minutes, then sign in again.")
        case .loginNetwork: String(localized: "Could not reach Sony's sign-in server. Check the internet connection, then sign in again.")
        case .loginBadResponse: String(localized: "Sony's answer could not be read. Sign in again; if it keeps happening, update CouchSubs.")
        case .loginWindowClosed: String(localized: "The sign-in window was closed before sign-in finished. Press Sign in and finish signing in in the window.")
        case .loginPageFailed: String(localized: "Sony's sign-in page could not be loaded. Check the internet connection, then sign in again.")
        }
    }
}

/// Başarısız PS5 eşleştirmesi ya da PSN girişi: ne yapılacağı, ayrıntı (PS5'in kodu, libchiaki'nin hata satırı, Sony'nin
/// hatası ya da HTTP kodu) ve gönderilecek günlük dosyası.
struct DetailedError: LocalizedError, Equatable {
    let error: AppError
    let detail: String?

    var errorDescription: String? {
        var text = error.errorDescription ?? ""
        if let detail, !detail.isEmpty { text += " (\(detail))" }
        return text + " " + String(format: String(localized: "If this keeps happening, send us this file: %@"), RemotePlayLog.displayPath)
    }
}

/// TV'ye bağlı uygulama bu cihazdaki TV paketinden eski (#884, #891).
struct TVAppOutdated: Equatable {
    /// 0.9.69'den eski TV uygulamaları sürüm bildirmez; ekranda böyle görünür.
    static let unreported = SubtitleServer.unreportedTVAppVersion
    let installed: String
    let bundled: String
}

/// TV uygulamasının kurulum durumu.
enum TVAppState: Equatable {
    /// Bilinmiyor ya da yapılacak bir şey yok (ör. uygulama açılıyor ama anahtar yok).
    case unknown
    case working
    case upToDate(String)
    /// TV uygulaması açılamadı ve geliştirici modu kapalı.
    case devModeOff
    /// Geliştirici modu açık; Key Server parolası gerekiyor. `error` son denemenin sonucu.
    case needsPassphrase(error: DevModeError?)
    /// `reason`: TV'nin verdiği sebep (LG kurulumunda luna yanıtındaki errorText/reason); kullanıcıya da gösterilir.
    case failed(DevModeError, reason: String? = nil)
    /// Samsung: sertifika için tarayıcıda Samsung hesabıyla giriş bekleniyor.
    case signIn(URL)
    /// Android TV: TV ekranında hata ayıklama izni bekleniyor.
    case approveOnTV
    /// Android TV: TV'de Google Play sayfası açıldı; kullanıcı TV'de Yükle'ye basmalı.
    case pressInstallOnTV
    /// Samsung: TV'deki Host PC IP (`tvIp`) bu Mac'in adresi (`computer`) değil; sdb denenmedi (#343).
    case hostPcMismatch(tvIp: String, computer: String)
    /// Android TV: ağda hata ayıklaması açık birden çok TV var; kurulumun gideceği TV kullanıcıya sorulur (#425).
    case chooseAndroidTV([String])
}

extension AppAppearance {
    /// Uygulamanın tüm pencerelerinin (ana pencere, ayarlar, kurulum, altyazı penceresi, menüler) görünümü; nil sistemi
    /// izler. Theme.swift'teki renkler pencerenin görünümüne göre çözüldüğü için hepsi birlikte değişir.
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }

    @MainActor func apply() { NSApplication.shared.appearance = nsAppearance }
}

@MainActor
final class AppModel: ObservableObject {
    enum Step: Int, CaseIterable {
        /// `betterTranslation`: isteğe bağlı ücretsiz Gemini anahtarı; atlanabilir. Yeni arayüzün sırası (onaylı tuval):
        /// konsol, hesap, PS5, TV, TV girişi (HDMI; yalnız TV eşleştiyse), daha iyi çeviri, deneme.
        case welcome, secondAccount, psnLogin, console, tv, hdmi, betterTranslation, test, done
    }

    @Published var step: Step {
        didSet {
            // Sihirbaz bitince ana ekran TV'siz de açılsın.
            if step == .done, oldValue != .done { store.save(true, for: StoreKey.setupComplete) }
            guard step != oldValue else { return }
            usage.record(.screen(step.screenName))
            if step == .done, !demoMode { usage.record(.onboardingDone(target: settings.output.rawValue, console: usageConsole)) }
        }
    }
    @Published var accountId: Data?
    @Published var console: RegisteredConsole?
    /// Okunan konsol: PlayStation (varsayılan) ya da Xbox (Beta); kurulumun ilk adımında ve Ayarlar'da seçilir.
    @Published private(set) var platform: ConsolePlatform
    /// Seçilen Xbox ve Microsoft girişi (jeton Anahtarlık'ta).
    @Published private(set) var xboxConsole: XboxConsole?
    @Published private(set) var xboxSignedIn: Bool
    let xboxAuth: XboxAuth
    private let xboxTokenSink = XboxTokenSink()
    /// İkinci hesabın PS5 giriş şifresi Anahtarlık'ta kayıtlı.
    @Published private(set) var hasLoginPasscode: Bool
    @Published var tv: LGTV?
    /// TV'nin eşleşme anahtarı kayıtlı.
    @Published private var tvKeySaved: Bool
    @Published var tvApp = TVAppState.unknown {
        didSet {
            // Kurulum ya da sürüm denetimi TV'deki uygulamayı güncel buldu: "TV uygulamasını güncelle" kalkar.
            if case .upToDate(let version) = tvApp, let outdated = tvAppOutdated,
               !DevModeInstaller.isNewer(outdated.bundled, than: version) { tvAppOutdated = nil }
        }
    }
    /// TV'ye bağlı uygulama bu Mac'teki TV paketinden eski (sürümü altyazı akışıyla öğrenilir; bildirmeyen TV 0.9.69'den
    /// eskidir). LG'de geliştirici modu kapalıyken ya da anahtar bu Mac'te değilken TV'deki sürüm başka yoldan okunamıyor,
    /// TV uygulaması eski kalıyor ve hiç uyarı çıkmıyordu (GitHub #884, #891). Ana ekrandaki TV kartı güncellemeyi önerir.
    @Published private(set) var tvAppOutdated: TVAppOutdated? {
        didSet { if tvAppOutdated == nil { tvAppStaleRunning = false } }
    }
    /// LG: TV'deki paket güncel ama çalışan uygulama kapatıp açtıktan sonra da eski sürümde (beta.89). Ana ekrandaki not
    /// "TV'de CouchSubs'ı kapatıp yeniden açın" der (tvAppOutdated o sürümleri taşır).
    @Published private(set) var tvAppStaleRunning = false
    /// LG: kurulumdan ya da kapat-aç'tan sonra çalışan uygulamanın sürümü bekleniyor.
    private var runningCheck: TVAppRunningCheck?
    /// Bağlı TV uygulamasının son bildirdiği sürüm (boş: sürüm bildirmeyen eski uygulama); bağlı uygulama yoksa nil.
    private var runningTVAppVersion: String?
    /// LG geliştirici modunun kalan süresi (saat); CouchSubs uzattıktan sonra bilinir.
    @Published var devModeHoursLeft: Int?
    /// Son eşleşmede TV uygulaması açılamadı.
    @Published private var tvAppMissing = false
    /// Kurulum günlüğüne en son yazılan "LG kurulumu başlamadı" nedeni (aynısı art arda yazılmaz).
    private var lastLGSkipReason: String?
    /// LG'de "yeniden kur" istendi: TV'deki sürüm güncel olsa da paket yeniden kurulur. İstek bir kerelik.
    private var lgReinstallRequested = false
    /// TV uygulaması denetimi sürüyor (bekleme ekranı ve çeviri başlangıcı aynı anda çağırabilir).
    @Published private var refreshingTVApp = false
    /// "TV uygulamasını yeniden kur"a basıldı: Android TV'de uygulama kuruluysa da TV'de açılır.
    private var openTVAppAfterCheck = false
    /// Birden çok Android TV bulununca kullanıcının seçtiği TV'nin adresi; yalnız bir sonraki denetimde kullanılır.
    /// Kurulum başarılı olursa TV'nin adresi zaten kaydedilir; olmazsa bir sonraki denemede yeniden sorulur (#425).
    private var androidTVChoice: String?
    /// Samsung kurulumu ya da sürüm denetimi sürüyor: olaylar (giriş, kurulum adımı) kartı değiştirebilir.
    @Published private var samsungCheckRunning = false
    @Published var settings: UserSettings {
        didSet {
            // Sıradan tercih; her kaydırıcı hareketinde Anahtarlık'a yazılmasın.
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: StoreKey.settings) }
            server.sendStyle(settings.style)
            if settings.output != oldValue.output { outputChanged() }
            if settings.dubbing != oldValue.dubbing { dubbingSettingsChanged(from: oldValue.dubbing) }
            if settings.gamePacks != oldValue.gamePacks, let pipeline { connectPacks(to: pipeline) }
            pipeline?.showSpeakerNames = settings.showSpeakerNames
            server.speakerColors = settings.speakerColors
            if settings.setTextApart != oldValue.setTextApart {
                server.setApart = settings.setTextApart
                server.sendStyle(settings.style)
            }
            if settings.autoScreenText != oldValue.autoScreenText { showsAutoScreenTextNotice = false }
            if settings.hotkeys != oldValue.hotkeys { applyHotkeys() }
            if settings.usageData != oldValue.usageData {
                usage.setEnabled(settings.usageData)
                // Ayarı değiştiren notu görmüştür. didSet içindeki atama didSet'i yeniden çağırmaz; kayıt burada yinelenir.
                if !settings.usageNoticeSeen {
                    settings.usageNoticeSeen = true
                    if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: StoreKey.settings) }
                }
            }
            if settings.appearance != oldValue.appearance { settings.appearance.apply() }
            let windowAppChanged = settings.frameSource == .remotePlayWindow && settings.remotePlayApp != oldValue.remotePlayApp
            // Xbox sesi: oturum yeniden kurulmaz, yalnız yerel ses açılır/kısılır (pencereden okurken oturum sesi yoktur,
            // çağrı bir şey yapmaz). Eskiden yayın kapatılıp hemen yeniden açılıyordu; Xbox eski oturumu bırakmadan gelen
            // yeni istekte hizmetini başlatamıyor, bağlantı geri gelmiyordu (#871).
            if settings.xboxAudioOnDevice != oldValue.xboxAudioOnDevice { session?.setPlayAudio(settings.xboxAudioOnDevice) }
            let captureWindowChanged = readsCaptureWindow && settings.captureWindow != oldValue.captureWindow
            let sourceChanged = isXbox ? settings.xboxFrameSource != oldValue.xboxFrameSource : settings.frameSource != oldValue.frameSource
            if sourceChanged || windowAppChanged || captureWindowChanged, isRunning {
                // Görüntü kaynağı (ya da okunan Remote Play uygulaması) değişti: çeviri yeniden başlar.
                // TV uygulaması kapatılmaz; kapanıp yeniden açılsa TV girişi gidip gelirdi.
                stop(closingTVApp: false)
                Task { await start() }
            }
            if settings.sharePool != oldValue.sharePool {
                let (pool, enabled) = (pool, settings.sharePool)
                Task { await pool.setEnabled(enabled) }
            }
            let translationChanged = settings.onlineTranslation != oldValue.onlineTranslation
                || settings.onlineEngine != oldValue.onlineEngine || settings.geminiModel != oldValue.geminiModel
                || settings.geminiPaidTier != oldValue.geminiPaidTier
                || settings.openAIModel != oldValue.openAIModel || settings.claudeModel != oldValue.claudeModel
                || settings.localAIBaseURL != oldValue.localAIBaseURL || settings.localAIModel != oldValue.localAIModel
                || settings.aiInstruction != oldValue.aiInstruction
            if translationChanged { Task { await refreshTranslatorStatus() } }
            if settings.readsGamePhone != oldValue.readsGamePhone
                || settings.drawScreenInPlace != oldValue.drawScreenInPlace { configureGamePhone() }
            if settings.drawScreenInPlace != oldValue.drawScreenInPlace {
                capturedWindow?.setFastFrames(settings.drawScreenInPlace)
            }
            if settings.readsGamePhone { showsGamePhoneHint = false }
            if settings.misreadWaitMs != oldValue.misreadWaitMs || settings.partialWaitMs != oldValue.partialWaitMs {
                pipeline?.applyWaits(from: settings)
            }
            let languageChanged = settings.sourceLanguage != oldValue.sourceLanguage
                || settings.targetLanguage != oldValue.targetLanguage
            if isRunning, languageChanged || translationChanged || settings.fastSubtitleDetection != oldValue.fastSubtitleDetection {
                if languageChanged { Task { await refreshTranslatorStatus() } }
                makePipeline()
            }
        }
    }

    // Çalışma durumu
    /// Çeviri sürüyor; hareket kapısı (Perde) bunu bütün pencerelere duyurur: sürerken sürekli animasyonlar durur.
    @Published var isRunning = false {
        didSet { if isRunning != oldValue { DSMotionState.shared.translating = isRunning } }
    }
    /// Genel kısayollar (bkz. `applyHotkeys`).
    lazy var hotkeys = GlobalHotkeys { [weak self] action in self?.hotkeyPressed(action) }
    /// Ayarlar › Kısayollar yeni tuşu bekliyor: basılan tuş kısayol olarak çalışmasın, oraya gelsin.
    @Published var hotkeysPaused = false {
        didSet { if hotkeysPaused != oldValue { applyHotkeys() } }
    }
    /// Num 0 ile canlı altyazı çevirisi duraklatıldı (oturum bitince kalkar).
    @Published private(set) var subtitlesPaused = false
    /// Kısayolla tek seferlik alan okuması sürüyor; üst üste basılınca ikincisi başlamaz.
    private var regionBusy = false
    @Published var isStarting = false
    /// Deneme modu: konsol yerine uygulamadaki örnek kareler okunur (`DemoFrameSource`); kurulum gerekmez.
    @Published private(set) var demoMode = false
    @Published var sessionState: SessionState = .disconnected(.stopped) {
        didSet { connectingChanged(from: oldValue) }
    }
    /// "Bağlanıyor…" 30 sn'yi geçince durum satırının altındaki neden (`ConnectingHint`); yoksa nil.
    @Published private(set) var connectingHint: String?
    private var connectingWatch: Task<Void, Never>?
    /// Çeviri sürerken Mac'in boşta uykuya geçmesi engellenir (kullanıcı TV'de oynuyor, Mac'e dokunmuyor).
    var isPreventingSleep: Bool { sleepActivity != nil }
    @Published var tvClients = 0 {
        // Eski uygulama TV'den kalktı (silindi, kapandı): "TV uygulamasını güncelle" bellekte kalmıyor; ana ekran "TV
        // uygulaması bekleniyor / Yeniden kur" der. Eski uygulama yeniden bağlanırsa sürümünü yine bildirir.
        didSet {
            if tvClients == 0, tvAppOutdated != nil { tvAppOutdated = nil }
            if tvClients == 0 { runningTVAppVersion = nil }
        }
    }
    /// TV uygulamasını kendiliğinden açmanın son denemesi neden olmadı (ana ekranda tek satır); açıldıysa nil.
    @Published private(set) var tvOpenProblem: TVOpenProblem?
    /// TV bağlıyken bağlantı koptu ya da TV alındı göndermez oldu (`SubtitleServer.onTVStale`): TV durumu "Bağlı" yerine
    /// "Yeniden bağlanılıyor…" der; TV yeniden bağlanınca, çeviri durunca ya da `SubtitleServer.reconnectingFor` sonra
    /// "TV uygulaması bekleniyor"a döner (iPhone, Windows ve Android ile aynı).
    @Published private(set) var tvReconnecting = false
    private var tvReconnectTask: Task<Void, Never>?
    @Published var lastSource = ""
    @Published var lastTranslation = ""
    /// Görüntü bir dakikadır geliyor ama bu çeviride tek altyazı satırı gösterilmedi: "oyunun kendi altyazısını açın"
    /// ipucu (CouchSubsCore SubtitleOffTip; GitHub #503, #566, #572).
    @Published private(set) var showsSubtitleOffTip = false
    /// Otomatik ekran yazısı göçle kapatıldı (beta.63'te açıktı): bu oturumda bir kez "kapatıldı; Ayarlar › Gelişmiş ›
    /// Ekran yazıları'ndan açabilirsiniz" bilgisi görünür. Kullanıcı ayarı değiştirince kalkar.
    @Published private(set) var showsAutoScreenTextNotice = false
    /// Telefon çevirisi kapalıyken GTA 6'nın telefon listesi altyazı yolunda sahne yazısı sayılıp atıldı: oturumda bir kez
    /// "Telefon çevirisi kapalı, açmak ister misiniz?" (`GamePhoneHint`, #1202).
    @Published private(set) var showsGamePhoneHint = false
    private var gamePhoneHint = GamePhoneHint()
    private var subtitleOffTip = SubtitleOffTip()
    /// Bu ve önceki oturumlarda çevrilen son 200 altyazı (history.json); kaçırılan satır ana pencereden ve "Geçmiş"ten
    /// yeniden okunur.
    @Published var history = SubtitleHistory()
    /// Bu oturumun başladığı an; canlı altyazı alanı yalnız bu oturumun satırlarını gösterir (nil: hepsi).
    @Published private(set) var sessionStartedAt: Date?
    /// Son satırın ölçümleri (yazı tanıma, çeviri, gecikme, güven).
    @Published var lastMetrics: LineMetrics?
    @Published var showHistory = false {
        didSet { if showHistory, !oldValue { usage.record(.screen("history")) } }
    }
    /// Geçmişin yazıldığı dosya (testlerde nil: hiçbir şey yazılmaz).
    private var historyFile: URL?
    private let historyQueue = DispatchQueue(label: "history.json", qos: .utility)
    @Published var translatorStatus: TranslatorStatus = .ready
    /// Çevrimiçi çeviri (DeepL ya da yapay zekâ) şu an çeviremiyor; o satırlar cihaz üstü çeviriyle çevriliyor.
    @Published var onlineIssue: OnlineKeyState?
    /// Yazı tanıma art arda hata veriyor; değeri diskteki boş yer (GB). macOS, diskte yer kalmayınca okuma modelini
    /// diske yazamaz ve her okumayı hata ile bitirir; altyazı sessizce hiç gelmez.
    @Published var readingFailedFreeGB: Double?
    /// Yazı tanıma (Vision) takıldı ve yedek okuyucu da okuyamıyor (#507, #679); altyazı gelmez. Takılan okuma bitince
    /// kendiliğinden düzelir (macOS modeli hazırlıyorsa bir iki dakika); düzelmezse uygulama yeniden başlatılır.
    @Published var readingStuck = false
    /// Yazı tanıma takıldı, altyazılar yedek okuyucudan (ayrı süreç) geliyor. Asıl okuyucu kilitli kaldıysa ve yedek
    /// isabetli düzeyde okuyorsa yedek kalıcı okuyucudur; uyarı gösterilmez (`ReadQueue.showsRescueNotice`, #1307).
    @Published var readingRescued = false
    private var readFailures = 0
    /// Son PS5 karesi (Ayarlar'daki bölge önizlemesi). Her karede değiştiği için modelin kendi yayınına girmez; yalnız
    /// önizlemeyi gösteren görünüm `framePreview`'u izler, öbür ekranlar her karede yeniden çizilmez.
    let framePreview = FramePreview()
    var lastFrame: CGImage? {
        get { framePreview.image }
        set { framePreview.image = newValue }
    }
    /// Gelen kare sayısı ve son karenin anı (ana ekrandaki "Kare/sn" ve "Görüntü Durdu"); yayınlanmaz, ekran saniyede
    /// bir okur.
    private(set) var frameCount = 0
    private(set) var lastFrameAt: Date?
    /// Son karenin geldiği an (ms, `SubtitleStabilizer.uptimeMs`): yerinde çizimde çapanın o karedeki yeri bununla bulunur.
    private(set) var lastFrameMs = 0
    @Published var showAbout = false
    /// Uygulama menüsündeki "Sürüm Notları".
    @Published var showReleaseNotes = false
    @Published var showSettings = false {
        didSet { if showSettings, !oldValue { usage.record(.screen("settings")) } }
    }
    /// Ayarlar açılınca gösterilen bölüm (ana ekrandaki "Çeviri" satırı Çeviri'yi açar); sayfa kapanınca başa döner.
    @Published var settingsSection: SettingsSection = .basics

    /// Yeni arayüz ilk kez açıldı (bir kez): konuşan rengi yeni dildeki gibi yalnız adı boyar. Görünüm ayarına dokunulmaz:
    /// Perde tasarım dili koyu temalıdır ve varsayılan da koyudur (tasarim.json › defaultTheme); kullanıcının seçtiği
    /// Açık / Koyu / Sisteme Uy korunur.
    func adoptNewDesign() {
        let key = "newDesignAdopted"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        settings.style.nameOnly = true
    }

    /// Ayarları verilen bölümle açar.
    func openSettings(_ section: SettingsSection) {
        settingsSection = section
        showSettings = true
    }

    let services: AppServices
    private let store: AppStore
    private let defaults: UserDefaults
    /// Çalışan okuma hattının dilleri.
    @Published private(set) var activeLanguages: (source: String, target: String)?
    private var server = SubtitleServer(port: AppIdentity.serverPort)
    /// Oturumun konuşan renkleri (TV'ye gidenle aynı; bilgisayar ekranındaki pencereler buradan boyar).
    var speakerBook: SpeakerColorBook { server.speakerBook }
    private var serverStarted = false
    /// Sunucunun gerçekten dinlediği port (8787 doluysa rastgele bir port).
    @Published private(set) var serverPort: UInt16 = AppIdentity.serverPort
    private var session: StreamControlling?
    /// Bağlantının ne zamandan beri gittiği: "Yeniden bağlan" düğmesi için (bkz. `offersReconnect`).
    @Published private(set) var reconnectOffer = ReconnectOffer()
    /// Bu çeviri PS5'e ya da Xbox'a doğrudan bağlanıyor (Remote Play ya da seçilen pencereden okumuyor).
    private var sessionIsConsole = false
    private var keeper: KeeperControlling?
    /// Her yeni bekçide artar: durdurulan bekçinin geç gelen açma sonucu yenisininkiyle karışmaz.
    private var keeperGeneration = 0
    @Published private var sleepActivity: NSObjectProtocol?
    private var pipeline: SubtitlePipeline?
    /// Ek alanları (görev, telefon, bildirim) okuyup çeviren; çeviri sürerken var.
    private var regionWatcher: RegionWatcher?
    private var gamePhoneTracker: GamePhoneTracker?
    /// Telefona yapışık çeviri (deneysel, önce Mac): GTA 6 telefonunun çapası (`PhoneAnchorSession`). Yalnız ayar açık ve
    /// oyun görüntüsü bu Mac'teki bir pencereden okunurken kurulur (bkz. `configureGamePhone`).
    private(set) var phoneAnchor: PhoneAnchorSession?
    /// Çapanın gösterilen yeri; oyun penceresinin üstündeki katman ve yayın penceresi izler (saniyede 30'a kadar değişir,
    /// AppModel'in kendisini yayımlamaz).
    let phoneAnchorFeed = PhoneAnchorFeed()
    /// Görüntüyü okunan pencere (PS Remote Play, chiaki-ng ya da seçilen OBS/oyun penceresi); konsoldan okunurken nil.
    var capturedWindow: RemotePlayWindowStream? { session as? RemotePlayWindowStream }
    /// Ekran yazılarını kendiliğinden bulan (ayar açık ve çeviri sürerken var); örnek arka planda, tek uçuşta alınır.
    private var screenTextDetector: ScreenTextDetector?
    private var screenTextBusy = false
    /// Altyazı hattının göndericisi: ekranda menü varken satırları bekletir, menü kapanınca konuşma satırını gönderir
    /// (#1240); her karede yoklanır.
    private var menuSender: MenuHeldSender?
    /// Altyazı hattının altyazıdan ayırdığı görev satırının bölgesi (bkz. `MissionLine`); yoksa nil.
    private var missionRegion: CropRegion?
    /// Altyazı hattının altyazıdan ayırdığı kenar bildirimlerinin alanları (bkz. `ScreenNotices`); yoksa boş.
    private var noticeAreas: [ExtraArea] = []
    /// Oyundaki altyazının son görüldüğü yer; deneme altyazısı TV'de oraya yerleşir.
    private var lastSubtitleBox: TextBox?
    /// Hatta aynı anda tek kare girer. Durdurma ve yeni hat kapıyı sıfırlar; takılan okuma hattı yeniden kurdurur.
    private var frameGate = FrameGate()
    /// Oturumların kare kopyalama sıklığı (oyun takılmasın): okuma süresi buradan bildirilir (bkz. `FrameCadence`).
    let frameCadence = FrameCadence()
    /// Okuma sürerken atlanan son kare; okuma bitince okunur (bkz. `FrameGate.leave`).
    private var skippedFrame: (frame: CGImage, capturedAt: Int)?
    private var wakeObserver: NSObjectProtocol?
    /// Çeviri sürerken bu Mac'in ev ağı adresini izler (bkz. `senderAddressChanged`).
    private var addressWatcher: AddressWatching?

    // Oyun paketleri ve ortak havuz
    /// Uygulamayla gelen ve ~/Library/Application Support/CouchSubs/packs klasöründeki paketler.
    let packs = GamePackLibrary(bundled: GamePackLibrary.bundledDirectory, user: GamePackLibrary.userDirectory)
    /// Ayarlarda listelenen paketler (açılışta arka planda yüklenince dolar).
    @Published var installedPacks: [GamePackLibrary.Info] = []
    private let pool: LinePool
    /// Kullanım verisi (Ayarlar › Kullanım verisi; bkz. `UsageStats`). Ölçüm kimliği derlemede yoksa, Mac App Store
    /// sürümünde ve testlerde hiçbir şey göndermez.
    let usage: UsageStats
    private var usageTimer: Task<Void, Never>?
    /// Bu çeviri oturumunun başlangıcı, gösterilen satırlar, paketten gelenler ve satır gelen paketler (kullanım verisi).
    private var usageSession: (started: Date, lines: Int, packLines: Int, packs: Set<String>)?
    /// Oynanan oyun: PS5'in bildirdiği, kullanıcının seçtiği ya da paketten tanınan (havuza giden satırlar bu oyunla gider).
    let gameChoice: GameChoice
    /// Oyuna göre alanlar: oyun değişince kayıtlı alanları uygular ya da önerir (bkz. CouchSubsCore GameAreas).
    lazy var gameAreas = GameAreas(read: { [weak self] in self?.settings ?? UserSettings() },
                                   write: { [weak self] in self?.settings = $0 })
    private var poolTimer: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    /// Bağlıyken birkaç dakikada bir PS5'e çalışan oyunu sorar (havuza giden satırlar oyunla gider). Testlerde kapalı.
    private var gameProbe: Task<Void, Never>?
    private let probesGame: Bool
    static let gameProbeInterval: Duration = .seconds(120)
    /// Paket sunucusundan yeni ve güncellenen paketler (adres yapılandırılmadıysa nil; bkz. `PackUpdater`).
    private var packUpdates: Task<Void, Never>?
    private var packUpdater: PackUpdater?

    // Dublaj
    private var dubber: Dubber?
    /// Model indiriliyorsa ilerleme (0…1).
    @Published var dubbingDownload: Double?
    @Published var dubbingError: String?
    @Published var dubbingModelReady = DubbingModelStore.isReady

    // Bilgisayar ekranındaki altyazı penceresi (bkz. AppModel+ComputerScreen.swift)
    /// Pencerede şu an görünen satırlar (TV'dekiyle aynı yığın).
    @Published var overlayLines: [SubtitleStack.Line] = []
    /// Penceredeki ek alan çevirileri (yukarıdan aşağı).
    @Published var overlayRegions: [OverlayRegion] = []
    @Published var overlayPhoneItems: [ScreenTranslation.Item] = []
    /// "Ekranı çevir" çevirileri yerleri ve özgün stilleriyle: yayın penceresi onları kendi yerlerinde çizer ve yığındaki
    /// düz listeyi (`overlayScreenText` satırı) göstermez; saydam pencere listeyi gösterir (oyunun üstünde değil).
    @Published var overlayScreenItems: [ScreenTranslation.Item] = []
    var overlayScreenText = ""
    /// Yerindeki "Ekranı çevir" çevirilerini süresi dolunca kaldırır (TV'deki gibi yeni altyazı onları kaldırmaz).
    var overlayScreenExpiry: Task<Void, Never>?
    /// Pencerenin yeri ve boyu ayarlanıyor ("Altyazıyı konumlandır"): örnek yazı görünür, tıklamalar geçmez. Yeni yer
    /// `commitOverlayEdit()` ile kaydedilir; başka yoldan kapanırsa (Esc, altyazı bilgisayardan kalktı) pencere eski
    /// yerine döner.
    @Published var overlayAdjusting = false
    /// Altyazı penceresinin kaydetme işi (SubtitleOverlayController verir).
    var overlayCommit: (() -> Void)?

    /// Bitti, çift tık ya da Enter: yeni yer kaydedilir, düzenleme kapanır.
    func commitOverlayEdit() {
        if overlayAdjusting { overlayCommit?() }
        overlayAdjusting = false
    }
    var overlayStack = SubtitleStack()
    /// Son altyazının metni, oyundaki yeri ve yazı boyu çarpanı: "Yazı kadar" zeminde o satırın kutusu oyunun altyazısını
    /// örter (bkz. OverlayCover). Yeri gelmeyen satır son bilinen yeri kullanır; "Örtsün"de boy kararlıdır (CoverFontScale).
    var overlayCover: (text: String, box: TextBox?, scale: Double)?
    var overlayCoverFont = CoverFontScale()
    /// "Yayın penceresi" açık: altyazı bilgisayar ekranında gösterilmese de satırlar yığına gelir (bkz. StreamWindow.swift).
    @Published var streamWindowOpen = false {
        didSet {
            guard streamWindowOpen != oldValue, !streamWindowOpen, !settings.output.showsOnComputer else { return }
            overlayHide()
        }
    }
    /// Yayın penceresinin zemin rengi (chroma key ile silinir).
    @Published var streamBackground = StreamBackground.green {
        didSet { defaults.set(streamBackground.rawValue, forKey: StoreKey.streamBackground) }
    }
    /// "Ekranı çevir" çevirilerinin pencerede kalacağı an (`overlayClock` saatiyle); yoksa 0.
    var overlayScreenUntil: TimeInterval = 0
    var overlayTimer: Task<Void, Never>?
    /// Yığının saati (saniye); testlerde ileri sarılır.
    var overlayClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(services: AppServices = LiveServices(), store: AppStore = KeychainStore(), defaults: UserDefaults = .standard) {
        self.services = services
        self.store = store
        self.defaults = defaults
        let accountId = store.load(Data.self, for: StoreKey.accountId)
        let console = store.load(RegisteredConsole.self, for: StoreKey.console)
        let tv = store.load(LGTV.self, for: StoreKey.tv)
        let tvKeySaved = store.load(String.self, for: StoreKey.tvKey) != nil
        let paired = tv != nil && tvKeySaved
        let saved = defaults.data(forKey: StoreKey.settings)
        let loaded = saved.flatMap { try? JSONDecoder().decode(UserSettings.self, from: $0) } ?? UserSettings()
        // Xbox (Beta): konsol türü, Microsoft jetonu ve seçilen Xbox.
        let platform = defaults.string(forKey: XboxStoreKey.platform).flatMap(ConsolePlatform.init(rawValue:)) ?? .playstation
        self.platform = platform
        let xboxConsole = store.load(XboxConsole.self, for: XboxStoreKey.console)
        let xboxToken = XboxUserToken.parse(store.load(String.self, for: XboxStoreKey.userToken))
        self.xboxConsole = xboxConsole
        xboxSignedIn = xboxToken != nil
        let sink = xboxTokenSink
        xboxAuth = services.makeXboxAuth(userToken: xboxToken, onUserToken: { token in sink.handler?(token) })
        let xboxLinked = xboxToken != nil && xboxConsole != nil
        // Xbox'ta kurulum yalnız sihirbazın sonuna gelindiyse bitmiştir (iPhone'daki kural).
        let ready = platform == .xbox
            ? (xboxLinked || loaded.xboxFrameSource == .captureWindow) && store.load(Bool.self, for: StoreKey.setupComplete) == true
            : Self.setupIsComplete(store: store, accountId: accountId, console: console, paired: paired,
                                   readsWindow: loaded.frameSource != .ps5)
        self.tvKeySaved = tvKeySaved
        hasLoginPasscode = LoginPasscode.normalized(store.load(String.self, for: StoreKey.loginPasscode)) != nil
        self.accountId = accountId
        self.console = console
        self.tv = tv
        // Uygulama oturum sürerken kapandıysa oyunun profili açık kalmış olabilir: genel alanlar geri gelir.
        var curated = GameAreas.restored(loaded.withCuratedModels())
        // beta.63'te varsayılan açık gelen otomatik ekran yazısı bir kez kapatılır; açık olanlara bir kez söylenir.
        let autoScreenTextNotice = curated.migratingAutoScreenText()
        // Otomatik ekran yazısı kapalıyken hazır alanlar ve GTA 6 telefonu da bir kez kapatılır (altyazı dışında çeviri yok).
        curated.migratingScreenTextExtras()
        // GTA 6 telefonu eski göçle kapalı kaldıysa bir kez açılır (#1202; iPhone, Windows, Android ile aynı).
        curated.migratingGamePhone()
        // Önceki sürümden gelen kurulumda eski ⌥⌘T ve ⌥⌘L ikinci tuş olarak kalır (bir kez; kayıtla birlikte yazılır).
        if LegacyMacHotkeys.isLegacy(saved) { curated.hotkeys = LegacyMacHotkeys.apply(curated.hotkeys) }
        settings = curated
        showsAutoScreenTextNotice = autoScreenTextNotice
        streamBackground = StreamBackground(stored: defaults.string(forKey: StoreKey.streamBackground))
        // Pencereler açılmadan önce: açılışta açık temanın bir an görünmesi olmaz.
        curated.appearance.apply()
        let poolFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true).appendingPathComponent("pool.json")
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // PS5 bağlantı günlüğü (~/Library/Logs/CouchSubs/remoteplay.log); eşleştirme olmazsa kullanıcı bunu gönderir.
        if !testing {
            RemotePlayLog.enable()
            RemotePlayLog.write("CouchSubs \(AppIdentity.version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            // Altyazı günlüğü (aynı klasörde altyazi.log): okunan satırlar ve akıbetleri, görüntü duraklamaları.
            SubtitleLog.enable()
            let stalls = VideoStallTracker()
            RemotePlayLog.observe { line in
                if let note = stalls.note(line) { SubtitleLog.write(note) }
            }
        }
        pool = LinePool(file: poolFile, app: AppIdentity.version, platform: "mac", enabled: curated.sharePool && !testing)
        usage = UsageStats(config: testing ? nil : UsageMeasurement.config(), enabled: curated.usageData,
                           idFile: poolFile.deletingLastPathComponent().appendingPathComponent("usage-id"),
                           appVersion: AppIdentity.version, osVersion: UsageMeasurement.osVersion, platform: "mac")
        probesGame = !testing
        gameChoice = GameChoice(defaults: defaults)
        if !testing {
            historyFile = SubtitleHistory.defaultFile
            history = SubtitleHistory.load(from: SubtitleHistory.defaultFile)
        }
        // Listede olmayan model varsayılana döndüyse ayar hemen kaydedilir.
        if curated != loaded, let data = try? JSONEncoder().encode(curated) { defaults.set(data, forKey: StoreKey.settings) }
        // Yarım kalan kurulum (ör. TV uygulaması kurulurken kapatıldı) PS5 kayıtlıysa TV adımından sürer.
        let linked = platform == .xbox ? xboxLinked : accountId != nil && console != nil
        step = ready ? .done : (linked ? .tv : .welcome)
        savedKeys = Set(TranslationEngine.allCases.filter { engine in
            engine.storeKey.flatMap { store.load(String.self, for: $0) }?.isEmpty == false
        })
        let storedKey = store.load(String.self, for: StoreKey.subtitleAccessKey)
        let accessKey = storedKey?.isEmpty == false ? storedKey! : SubtitleAccess.createKey()
        store.save(accessKey, for: StoreKey.subtitleAccessKey)
        server.rotateKey(accessKey)
        subtitleAccessKey = accessKey
        attachServer()
        let pool = self.pool
        gameChoice.onChange = { [weak self] game in
            self?.regionWatcher?.reset()
            self?.configureGamePhone()
            Task { await pool.setGame(game) }
            // Bu oyunun (havuzdan otomatik) paketi sunucuda yeni çıkmış olabilir.
            if game != nil { self?.packsForGame() }
        }
        gameChoice.onPublish = { [weak self] game, source in self?.gameAreas.follow(game: game, source: source) }
        // Xbox'ta oyunun tanınmadığı ya da elle seçildiği günlükte tek satır (Windows, iPhone, Android ile aynı).
        gameChoice.onLog = { SubtitleLog.write($0) }
        // Ayarlar'da oyun profili seçilince ya da yeni profil açılınca oynanan oyun o olur.
        gameAreas.onChoose = { [weak self] name in self?.gameChoice.choose(name) }
        // Jeton yenilenince (ya da çıkış yapılınca) Anahtarlık güncellenir.
        xboxTokenSink.handler = { [weak self] token in
            Task { @MainActor in
                guard let self else { return }
                if let token { self.store.save(token.serialize(), for: XboxStoreKey.userToken) } else { self.store.remove(XboxStoreKey.userToken) }
                self.xboxSignedIn = token != nil
            }
        }
        gameChoice.packTitles = { [weak self] in GameCatalog.packGames(self?.installedPacks ?? []) }
        // Elle seçilen oyunda satırlar yalnız o oyunun paketinde aranır, paketi yoksa hiç aranmaz (#218).
        gameChoice.packs = packs

        // Paketler ilk altyazıyı bekletmesin diye açılışta arka planda yüklenir.
        let packs = self.packs
        Task.detached(priority: .utility) { [weak self] in
            let list = packs.packs
            await MainActor.run { self?.installedPacks = list }
        }
        // Testlerde havuz hiçbir şey göndermez, paket sunucusuna da sorulmaz.
        if !testing {
            startPool()
            startPackUpdates()
        }
        usage.record(.screen(step.screenName))
    }

    /// Paket sunucusunun adresi ve uygulama sırrı yapılandırıldıysa (Info.plist `CSPacksBaseURL`, `CSPacksAppSecret`) açılışta ve günde bir bakılır; PS5'te
    /// yeni bir oyun tanınınca da (`packsForGame`). Yeni paket inince paketler yeniden okunur.
    private func startPackUpdates() {
        // Sır yoksa (yerel geliştirici derlemesi) sunucu imzasız isteği reddeder: indirme sessizce kapalı.
        guard let base = PackUpdater.configuredBaseURL(), let secret = PackSigning.configuredSecret() else { return }
        let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true).appendingPathComponent("packs-remote.json")
        let updater = PackUpdater(baseURL: base, fallbackURLs: PackUpdater.configuredFallbackURL().map { [$0] } ?? [],
                                  directory: GamePackLibrary.userDirectory, stateFile: state, secret: secret)
        packUpdater = updater
        let packs = self.packs
        packUpdates = Task.detached(priority: .background) { [weak self] in
            var force = true
            while !Task.isCancelled {
                let result = await updater.refresh(force: force)
                force = false
                await Self.applyPackRefresh(result, packs: packs, model: self)
                try? await Task.sleep(for: .seconds(PackUpdater.refreshInterval))
            }
        }
    }

    /// PS5'te yeni bir oyun başladı: o oyunun paketi sunucuda yeni çıkmış olabilir, son bakış eskiyse hemen bakılır.
    private func packsForGame() {
        guard let updater = packUpdater else { return }
        let packs = self.packs
        Task.detached(priority: .utility) { [weak self] in
            let result = await updater.refresh(maxAge: PackUpdater.gameCheckInterval)
            await Self.applyPackRefresh(result, packs: packs, model: self)
        }
    }

    /// Paket sunucusu yapılandırılmış ("Paketleri şimdi güncelle" düğmesi açık).
    var canUpdatePacks: Bool { packUpdater != nil }

    /// Elle güncelleme (Ayarlar > Oyun paketleri; iPhone'daki `updatePacksNow` ile aynı): süresine bakmadan listeyi
    /// sunucudan alır, değişen paketleri indirir ve neyin geldiğini özetler. Paket sunucusu yapılandırılmamışsa nil.
    func updatePacksNow() async -> PackUpdateOutcome? {
        guard let updater = packUpdater else { return nil }
        let packs = self.packs
        let (result, before, after, titles) = await Task.detached(priority: .userInitiated) { [weak self] in
            let before = packs.packs
            let result = await updater.refresh(force: true)
            await Self.applyPackRefresh(result, packs: packs, model: self)
            let titles = Dictionary(await updater.installed.map { ($0.id, $0.title) }, uniquingKeysWith: { _, last in last })
            return (result, before, packs.packs, titles)
        }.value
        let downloaded = result.downloaded.map { id in
            let pack = after.last { $0.id == id }
            return PackUpdateSummary.Downloaded(id: id, title: pack?.title ?? titles[id] ?? id, lines: pack?.entries ?? 0)
        }
        let summary = PackUpdateSummary(before: before.map { (id: $0.id, lines: $0.entries) }, downloaded: downloaded)
        if result.failed {
            return .failed(String(localized: "No internet connection, or the pack server could not be reached."), summary)
        }
        if result.incomplete {
            return .failed(String(localized: "A downloaded pack could not be verified; it may have arrived incomplete."), summary)
        }
        return summary.isEmpty ? .upToDate : .updated(summary)
    }

    private nonisolated static func applyPackRefresh(_ result: PackUpdater.Refresh, packs: GamePackLibrary, model: AppModel?) async {
        guard result.changed else { return }
        packs.reload()
        let list = packs.packs
        await MainActor.run { model?.installedPacks = list }
        RemotePlayLog.write("Paketler güncellendi: \((result.downloaded + result.removed).joined(separator: ", "))")
    }

    /// Kayıtlı PS5'i (adresi değiştiyse ağda kimliğiyle) bulan arayıcı; kayıt değişirse saklanır. Kayıt yoksa nil.
    private func consoleFinder() -> ConsoleFinder? {
        guard let console else { return nil }
        let finder = ConsoleFinder(console: console)
        finder.onChange = { [weak self] moved in Task { @MainActor in self?.consoleMoved(moved) } }
        return finder
    }

    /// PS5'e bağlanınca çalışan oyun okunmaya başlar, bağlantı gidince bırakılır (havuz satırı oyunsuz gider).
    private func updateGameProbe(connected: Bool) {
        guard probesGame else { return }
        // Xbox'ta çalışan oyun sorulmaz (PS5 keşif sorusu); kayıtlı bir PS5 olsa da.
        guard connected, !isXbox, console != nil else {
            gameProbe?.cancel()
            gameProbe = nil
            gameChoice.consoleReported(nil)
            return
        }
        guard gameProbe == nil else { return }
        let services = self.services
        gameProbe = Task { [weak self] in
            var last: RunningGame?
            while !Task.isCancelled {
                // Her yoklamada güncel kayıt kullanılır (oturum PS5'i yeni adreste bulmuş olabilir).
                guard let finder = self?.consoleFinder() else { break }
                let game = await services.runningGame(finder: finder)
                // Bu arada bağlantı bittiyse oyun yazılmaz (bırakılan oyun geri gelmesin).
                guard !Task.isCancelled else { break }
                self?.gameChoice.consoleReported(game)
                if game != last, let game {
                    // Paket sunucusuna bakılması `gameChoice.onChange`te.
                    SubtitleLog.write("PS5'te çalışan oyun: \(game.name ?? "?") (\(game.titleId ?? "?"))")
                }
                last = game
                try? await Task.sleep(for: Self.gameProbeInterval)
            }
        }
    }

    /// Kurulum bitmiş mi. "Bitti" yalnız sihirbazın sonuna gelinince kaydedilir (TV adımı başarıyla geçildi ya da
    /// "TV'm yok" seçildi). Sihirbaz başlarken `false` yazılır: Samsung'da TV eşleşip uygulama kurulurken CouchSubs
    /// kapatılırsa eşleşme kayıtlı olsa da kurulum bitmiş sayılmaz. Hiç kayıt yoksa (beta.25'ten önce kurulmuş)
    /// eskisi gibi eşleşmiş TV yeter ve "bitti" kaydedilir. Görüntü PS Remote Play penceresinden okunuyorsa PS5 eşleşmesi
    /// (hesap, PS5 kaydı) gerekmez; sihirbaz açılmaz, kayıt da değiştirilmez (PS5'e dönülürse eski durum geçerlidir).
    static func setupIsComplete(store: AppStore, accountId: Data?, console: RegisteredConsole?, paired: Bool,
                                readsWindow: Bool = false) -> Bool {
        if readsWindow { return true }
        let saved = store.load(Bool.self, for: StoreKey.setupComplete)
        let ready = accountId != nil && console != nil && (saved ?? paired)
        if saved == nil { store.save(ready, for: StoreKey.setupComplete) }
        return ready
    }

    /// Sunucunun TV sayısını, altyazı yerini ve bilgisayar ekranına giden olayları bağlar (sunucu yeniden kurulunca da).
    @Published private(set) var subtitleAccessKey = ""
    @Published private(set) var legacyTVWarning = false
    @Published var tvPairingRequest: SubtitlePairing.Ticket?
    func resolveTVPairing(_ ticket: SubtitlePairing.Ticket, accept: Bool) {
        if server.pairing.resolve(ticket.id, accept: accept), accept { adoptPairedTV(host: ticket.host) }
        // Onaylanan istek artık geçerli değilse (süresi doldu, TV yeniden denedi) bekleyen yeni istek gösterilir.
        tvPairingRequest = server.pairing.pending
    }
    /// TV'nin kendisi başlattığı eşleşme onaylandı: TV, listeden elle seçilmiş gibi eşlenir ve kaydedilir (adres, marka, ad,
    /// LG izni / Samsung jetonu; bkz. `PairedTV`). Eskiden yalnız altyazı anahtarı TV'ye gidiyordu: TV kaydı olmadığı için
    /// TV bekçisi (otomatik açma) hiç çalışmıyor, ana ekranda TV kartı çıkmıyordu (iPhone, Windows, Android ile aynı).
    private func adoptPairedTV(host: String) {
        guard PairedTV.shouldAdopt(host: host, saved: tv, hasKey: tvKeySaved) else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let found = await self.services.identifyTV(host: host) else {
                SubtitleLog.write("Eşleşen TV'nin türü anlaşılamadı (\(host)); TV kaydedilmedi")
                return
            }
            guard PairedTV.shouldAdopt(host: host, saved: self.tv, hasKey: self.tvKeySaved) else { return }
            do {
                try await self.pair(found)
                SubtitleLog.write("Eşleşen TV kaydedildi: \(found.brand.rawValue) \(found.host)")
                // Çeviri sürüyorsa bekçi bu TV için hemen kurulur (adressiz kayıtta çalışan boş bekçi yerine).
                self.keeper?.stop()
                self.keeper = nil
                if self.isRunning { self.startKeeper() }
            } catch {
                SubtitleLog.write("Eşleşen TV kaydedilemedi (\(found.brand.rawValue) \(host)): \(error)")
            }
        }
    }
    func openTVPairing() async {
        do { try await startServer(); server.pairing.open() }
        catch { SubtitleLog.write("TV eşleştirme sunucusu açılamadı.") }
    }

    func rotateSubtitleKey() {
        let key = SubtitleAccess.createKey()
        store.save(key, for: StoreKey.subtitleAccessKey)
        keeper?.stop()
        keeper = nil
        server.rotateKey(key)
        tvPairingRequest = nil
        subtitleAccessKey = key
        startKeeper()
    }

    private func attachServer() {
        server.onPairingRequest = { [weak self] ticket in
            Task { @MainActor [weak self] in
                guard let self, let pending = self.server.pairing.pending else { return }
                self.tvPairingRequest = pending
            }
        }
        server.onLegacyClient = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.legacyTVWarning = true
                SubtitleLog.write("TV bağlantısı geçiş izniyle anahtarsız açıldı; TV uygulamasını güncelleyin.")
                await self.refreshTVApp()
            }
        }

        server.onTVAppVersion = { [weak self] version in
            Task { @MainActor [weak self] in self?.tvAppReported(version) }
        }
        shareLatestTVAppVersion()

        server.onClientsChanged = { [weak self] count in
            if let self, self.tvClients == 0, count > 0, self.isRunning {
                self.usage.record(.tvConnected(count: count, brand: self.tv?.brand.rawValue ?? "unknown"))
            }
            let lost = (self?.tvClients ?? 0) > 0 && count == 0
            self?.tvClients = count
            if count > 0 { self?.endTVReconnecting() } else if lost { self?.tvLost(stale: false) }
            if count > 0 { self?.tvOpenProblem = nil }
            // TV uygulaması bağlandı: bu Samsung TV'de kurulu olduğu artık biliniyor (bekçi listeye bakmadan açar).
            if count > 0, let tv = self?.tv, tv.brand == .samsung { SamsungAppKnowledge.shared.mark(host: tv.host) }
        }
        // Bu Mac'in daha önce kurduğu Samsung uygulaması da bilinen sayılır.
        if let tv, tv.brand == .samsung, installedAppVersion != nil { SamsungAppKnowledge.shared.mark(host: tv.host) }
        // TV'nin listesi uygulamanın silindiğini söyledi (#1158): bu Mac'in kurduğu sürümün kaydı da silinir; yoksa açılışta
        // bilgi yeniden işaretleniyor, kart "güncel" gösteriyor ve sdb reddedilince kurulum adımı hiç çıkmıyordu.
        SamsungAppKnowledge.onMissing = { [weak self] host in
            Task { @MainActor [weak self] in self?.samsungAppMissing(host: host) }
        }
        server.onTVStale = { [weak self] in
            Task { @MainActor [weak self] in self?.tvLost(stale: true) }
        }
        server.sendsToTV = settings.output.showsOnTV
        server.speakerColors = settings.speakerColors
        server.setApart = settings.setTextApart
        server.onEvent = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.overlayReceive(event) } }
        }
    }

    /// Beş dakikada bir ve uygulama kapanırken havuz kuyruğu gönderilir; sunucuya ulaşılamazsa sonra yeniden denenir.
    private func startPool() {
        let pool = self.pool
        let usage = self.usage
        poolTimer = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LinePool.flushInterval))
                await pool.flush()
            }
        }
        // Kullanım verisi dakikada bir, arka planda; ağ hatasında sonraki tura kalır.
        usageTimer = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(UsageStats.flushInterval))
                await usage.flush()
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                   queue: nil) { [weak self] _ in
            // Çeviri sürüyorsa TV uygulaması kapanır; mesaj sunucu kapanmadan yazılsın diye en çok bir saniye beklenir.
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let self, self.keeper != nil else { return }
                    self.keeper?.stop()
                    self.keeper = nil
                    let exited = DispatchSemaphore(value: 0)
                    self.server.exitTVApp { exited.signal() }
                    _ = exited.wait(timeout: .now() + 1)
                }
            }
            // Kapanış en çok birkaç saniye bekler.
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await pool.flush()
                await usage.flush()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 3)
        }
    }

    /// Paketler yalnız İngilizce→Türkçede ve ayar açıkken kullanılır. Pakette olmayan İngilizce satır havuza önerilir
    /// (paketler kapalıysa da yalnız hiçbir pakette olmayanlar).
    private func connectPacks(to pipeline: SubtitlePipeline) {
        let packs = self.packs
        let pool = self.pool
        // Deneme satırları paketlerde aranmaz ve havuza önerilmez.
        if demoMode {
            pipeline.packLookup = nil
            pipeline.onPackMiss = nil
            regionWatcher?.packLookup = nil
            return
        }
        let active = settings.gamePacks && settings.sourceLanguage == "en" && settings.targetLanguage == "tr"
        pipeline.packLookup = active ? { packs.match($0) } : nil
        pipeline.packName = { packs.searchScope }
        // Ek alanlar da pakette aranır ama havuza önerilmez (arayüz yazıları havuzu kirletmesin).
        regionWatcher?.packLookup = pipeline.packLookup
        guard settings.sourceLanguage == "en" else {
            pipeline.onPackMiss = nil
            return
        }
        pipeline.onPackMiss = { text in
            guard active || packs.match(text) == nil else { return }
            Task { await pool.offer(text) }
        }
    }

    // MARK: - Sihirbaz

    var canAdvance: Bool {
        switch step {
        case .welcome, .secondAccount, .test, .betterTranslation, .hdmi: true
        case .psnLogin: isXbox ? xboxSignedIn : accountId != nil
        case .console: isXbox ? xboxConsole != nil : console != nil
        case .tv: hasTV || !settings.output.showsOnTV
        case .done: false
        }
    }

    func advance() {
        guard canAdvance, var next = Step(rawValue: step.rawValue + 1) else { return }
        // Xbox'ta "İkinci hesap" adımı yoktur: karşılamadan Microsoft girişine geçilir.
        if next == .secondAccount && isXbox { next = .psnLogin }
        // TV girişi (HDMI) yalnız TV eşleştiyse ve altyazı TV'de gösterilecekse sorulur.
        if next == .hdmi && !asksTVInput { next = .betterTranslation }
        step = next
    }

    func back() {
        guard var previous = Step(rawValue: step.rawValue - 1) else { return }
        if previous == .secondAccount && isXbox { previous = .welcome }
        if previous == .hdmi && !asksTVInput { previous = .tv }
        step = previous
    }

    /// Kurulumda TV girişi (HDMI) adımı gösterilir mi (Android TV girişi kendi seçer; görüntü modu ayrı).
    var asksTVInput: Bool { hasTV && settings.output.showsOnTV && tv?.brand != .androidTV }

    // MARK: - Xbox (Beta)

    var isXbox: Bool { platform == .xbox }

    /// Sihirbazda gösterilen adımlar: Xbox'ta "İkinci hesap" yoktur.
    var wizardSteps: [Step] { Step.allCases.filter { $0 != .done && !(isXbox && $0 == .secondAccount) } }

    /// Konsol türünü seçer (karşılama adımı ve Ayarlar › Konsol). Çeviri sürüyorsa yeni konsolla yeniden başlar.
    func choosePlatform(_ value: ConsolePlatform) {
        guard value != platform else { return }
        let wasRunning = isRunning && !demoMode
        if wasRunning { stop(closingTVApp: false) }
        platform = value
        defaults.set(value.rawValue, forKey: XboxStoreKey.platform)
        RemotePlayLog.write("Konsol türü: \(value == .xbox ? "Xbox (Beta)" : "PlayStation 5")")
        if wasRunning { Task { await start() } }
    }

    /// Microsoft cihaz kodu ister (kullanıcı kodu microsoft.com/link'te yazar).
    func beginXboxLogin() async throws -> XboxDeviceCode {
        do {
            let code = try await xboxAuth.startDeviceCode()
            RemotePlayLog.write("Xbox: Microsoft cihaz kodu alındı")
            return code
        } catch let error as XboxError {
            RemotePlayLog.write("Xbox: cihaz kodu alınamadı (\(error.kind.rawValue)): \(XboxStop.shorten(error.message, limit: 300))")
            throw error
        }
    }

    /// Kullanıcı kodu onaylayana kadar bekler; jeton Anahtarlık'a yazılır.
    func completeXboxLogin(_ code: XboxDeviceCode) async throws {
        do {
            let token = try await xboxAuth.pollDeviceCode(code)
            store.save(token.serialize(), for: XboxStoreKey.userToken)
            xboxSignedIn = true
            RemotePlayLog.write("Xbox: Microsoft girişi tamam")
        } catch let error as XboxError {
            RemotePlayLog.write("Xbox: Microsoft girişi başarısız (\(error.kind.rawValue)): \(XboxStop.shorten(error.message, limit: 300))")
            throw error
        }
    }

    /// Hesaptaki Xbox'lar. Kayıtlı Xbox'ın adı listedekiyle tazelenir.
    func discoverXboxConsoles() async throws -> [XboxConsole] {
        do {
            let found = try await services.xboxConsoles(auth: xboxAuth)
            let names = found.map { "\($0.name.isEmpty ? $0.model : $0.name)\($0.streamingEnabled ? "" : " (uzaktan oynatma kapalı)")" }
            RemotePlayLog.write("Xbox araması: \(names.isEmpty ? "bulunamadı" : names.joined(separator: ", "))")
            if let saved = xboxConsole, let current = found.first(where: { $0.id == saved.id }), current != saved { chooseXbox(current) }
            return found
        } catch let error as XboxError {
            RemotePlayLog.write("Xbox araması başarısız (\(error.kind.rawValue)): \(XboxStop.shorten(error.message, limit: 300))")
            throw error
        }
    }

    func chooseXbox(_ console: XboxConsole) {
        xboxConsole = console
        store.save(console, for: XboxStoreKey.console)
    }

    /// Microsoft hesabından çıkar (jeton silinir); seçilen Xbox kalır.
    func signOutXbox() {
        if isXbox, isRunning, !demoMode { stop() }
        let auth = xboxAuth
        Task { await auth.signOut() }
        store.remove(XboxStoreKey.userToken)
        xboxSignedIn = false
    }

    /// Konsol Xbox ama Microsoft girişi ya da Xbox seçimi eksik: Ayarlar'da "Xbox'ı bağla" görünür.
    /// Görüntü seçilen pencereden okunuyorsa Xbox'a bağlanılmaz, bağlama gerekmez (#853).
    var needsXboxLink: Bool { isXbox && !readsXboxWindow && (!xboxSignedIn || xboxConsole == nil) }

    /// Ayarlar › Konsol › "Xbox'ı bağla": sihirbaz Microsoft girişinden (giriş varsa Xbox seçiminden) açılır.
    func linkXbox() { step = xboxSignedIn ? .console : .psnLogin }

    /// Ana ekrandaki Xbox durumu (Windows'taki XboxStatusText ile aynı kurallar). Oturum, kullanıcıya gösterilecek metni
    /// `.other(detail)` içinde verir (`XboxText`).
    static func xboxStatusText(_ state: SessionState, running: Bool, console: XboxConsole?, signedIn: Bool) -> String {
        switch state {
        case .streaming: return String(localized: "Connected")
        case .connecting: return String(localized: "Connecting…")
        case .disconnected(let reason):
            guard running else {
                guard let console, signedIn else { return String(localized: "Not connected") }
                return String(format: String(localized: "%@ is ready. It connects when you start translating."), console.name.isEmpty ? "Xbox" : console.name)
            }
            if case .other(let detail) = reason, !detail.isEmpty { return detail }
            return String(localized: "Retrying the Xbox connection…")
        }
    }

    /// Ücretsiz Gemini anahtarı kayıtlı ve çeviri Gemini ile yapılıyor ("Daha iyi çeviri" adımı tamam).
    var usesFreeGemini: Bool { settings.translationEngine == .gemini && hasKey(.gemini) }

    /// Ayarlardaki "Ücretsiz anahtar al": Gemini seçilir, anahtar alanı görünür (anahtar gelene dek ücretsiz çeviri sürer).
    func chooseFreeGemini() { settings.translationEngine = .gemini }

    /// Giriş penceresinin yönlendirmesinden hesap kimliği. Her hata kendi iletisiyle (`DetailedError`) döner ve
    /// remoteplay.log'a yazılır; genel "Giriş tamamlanmadı" yalnız son çaredir.
    func completePSNLogin(redirect: URL) async throws {
        let id: Data
        do {
            id = try await services.accountId(fromRedirect: redirect)
        } catch let error as PSNAccount.PSNError {
            RemotePlayLog.write("PSN girişi başarısız: \(error)")
            throw AppError.login(error)
        } catch {
            RemotePlayLog.write("PSN girişi beklenmedik hatayla bitti: \(error)")
            throw DetailedError(error: .invalidLogin, detail: error.localizedDescription)
        }
        RemotePlayLog.write("PSN girişi tamam")
        accountId = id
        store.save(id, for: StoreKey.accountId)
    }

    /// Giriş penceresi yönlendirme olmadan kapandı: kullanıcı kapattı (`problem` nil) ya da Sony'nin sayfası açılamadı.
    func loginWindowError(problem: String?) -> Error {
        RemotePlayLog.write("PSN giriş penceresi giriş bitmeden kapandı\(problem.map { ": \($0)" } ?? "")")
        guard let problem else { return AppError.loginWindowClosed }
        return DetailedError(error: problem.contains("429") ? .loginRateLimited : .loginPageFailed, detail: problem)
    }

    func discoverConsoles() async -> [ConsoleInfo] { await services.discoverConsoles() }

    /// PS5'e kayıt olur. Her başarısızlık kullanıcıya anlatılır (`AppError` ya da `DetailedError`); sessiz dönüş yok.
    func register(host: String, pin: String) async throws {
        let typed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { throw AppError.missingConsole }
        // Elle yazılan adres temizlenir ("192.168.1.5:9295", "http://…", virgüllü yazım); adres değilse libchiaki'ye
        // gitmeden söylenir.
        guard let host = ManualAddress.normalize(typed) else {
            RemotePlayLog.write("PS5 kaydı: geçersiz adres yazıldı: \(typed)")
            throw AppError.badAddress
        }
        guard let value = Registration.pin(from: pin) else { throw AppError.invalidPin }
        guard let accountId else { throw AppError.missingAccount }
        let registered: RegisteredConsole
        do {
            registered = try await services.register(host: host, accountId: accountId, pin: value)
        } catch let error as Registration.RegistrationError {
            throw DetailedError(error: AppError(error.kind), detail: error.detail)
        } catch {
            RemotePlayLog.write("PS5 kaydı beklenmedik hatayla bitti (\(host)): \(error)")
            throw DetailedError(error: .registrationFailed, detail: error.localizedDescription)
        }
        console = registered
        store.save(registered, for: StoreKey.console)
        // Günlükte eşleşmenin kaydedildiği de görünsün (kullanıcılar başarıyı fark etmeyip yeniden bağlanıyordu).
        RemotePlayLog.write("PS5 kaydı kaydedildi (\(registered.host)): \(registered.name)")
    }

    /// Eşleşmeden kısa süre sonra kendiliğinden sonraki adıma geçilir. Kullanıcı bu arada Geri'ye bastıysa ya da
    /// adım değiştiyse hiçbir şey yapılmaz (yalnız PS5 adımından ilerler).
    func continueAfterPairing() {
        guard step == .console, console != nil else { return }
        advance()
    }

    /// "Hesap kimliğini elle gir": Sony girişi açılamayan kullanıcılar (ör. servis sağlayıcı engelliyor) PSN hesap
    /// kimliğini base64 olarak (8 bayt, 12 karakter) yazar. Web girişiyle aynı biçimde saklanır. Geçersizse false.
    @discardableResult
    func useManualAccountId(_ value: String) -> Bool {
        guard let id = Self.accountId(fromBase64: value) else { return false }
        RemotePlayLog.write("PSN hesap kimliği elle girildi")
        accountId = id
        store.save(id, for: StoreKey.accountId)
        return true
    }

    /// Base64 PSN hesap kimliği: boşluklar atılır, çözülen değer tam 8 bayt olmalı (12 karakter).
    static func accountId(fromBase64 value: String) -> Data? {
        let trimmed = value.filter { !$0.isWhitespace }
        guard trimmed.count == 12, let data = Data(base64Encoded: trimmed), data.count == 8 else { return nil }
        return data
    }

    func discoverTVs() async -> [LGTV] { await services.discoverTVs() }

    /// Eşleşmiş bir TV var. Anahtarın varlığı saklanır; ana ekran her çizimde Anahtarlık'a sormasın.
    var hasTV: Bool { tv != nil && tvKeySaved }

    /// Sihirbazdaki "TV'm yok": TV aranmaz ve kurulmaz, altyazı bilgisayar ekranında gösterilir; sonraki adıma geçilir.
    func useComputerScreen() {
        settings.output = .computer
        advance()
    }

    /// Sihirbazdaki "İkinci hesap yok mu?": görüntü bu Mac'teki PS Remote Play penceresinden okunur. PSN girişi, PS5
    /// eşleştirmesi ve TV adımı atlanır, kurulum biter; TV eşleşmemişse altyazı bilgisayar ekranında gösterilir (TV ve
    /// daha iyi çeviri sonra Ayarlar'dan).
    func useRemotePlayWindow() {
        settings.frameSource = .remotePlayWindow
        if !hasTV { settings.output = .computer }
        step = .done
    }

    /// Görüntü PS5'ten (ikinci hesap) alınacak ama hesap ya da PS5 eşleşmesi yok: Ayarlar'da "Hesabı bağla" görünür.
    var needsPS5Link: Bool { !isXbox && settings.frameSource == .ps5 && (accountId == nil || console == nil) }

    /// Ayarlar › Görüntü kaynağı › "Hesabı bağla": sihirbaz ikinci hesap adımından açılır (PSN girişi, PS5 eşleştirmesi).
    func linkPS5Account() { step = .secondAccount }

    /// Seçilen Remote Play uygulaması bu Mac'te kurulu mu (Ayarlar'daki "Kurulu" / "İndir" satırları).
    func remotePlayInstalled(_ app: RemotePlayApp) -> Bool { services.remotePlayInstalled(app) }

    /// Görüntü Remote Play penceresinden okunacak ama seçilen uygulama kurulu değil: ana ekran nereden indirileceğini söyler.
    var remotePlayMissing: Bool { !isXbox && settings.frameSource == .remotePlayWindow && !services.remotePlayInstalled(settings.remotePlayApp) }

    /// "PS Remote Play'i indir" / "chiaki-ng'yi indir": resmi indirme sayfası tarayıcıda açılır.
    func openDownload(for app: RemotePlayApp) {
        NSWorkspace.shared.open(app == .chiaki ? RemotePlayWindowStream.chiakiDownloadURL : RemotePlayWindowStream.sonyDownloadURL)
    }

    func pair(_ tv: LGTV) async throws {
        try await startServer()
        let savedKey = store.load(String.self, for: StoreKey.tvKey)
        let pairing = try await services.pairTV(tv, key: savedKey, server: serverAddress(for: tv), accessKey: server.accessKey)
        if self.tv?.brand != tv.brand || (tv.brand != .androidTV && self.tv?.host != tv.host) {
            store.remove(StoreKey.tvAppVersion)
        }
        self.tv = tv
        store.save(tv, for: StoreKey.tv)
        // Samsung jetonla gelen bağlantıda jetonu yeniden göndermeyebilir; boş jeton saklı olanı silmez (#40).
        store.save(SamsungTokenHolder.keptToken(stored: savedKey, received: pairing.key), for: StoreKey.tvKey)
        tvKeySaved = true
        tvAppMissing = !pairing.launched
        // Daha önce "TV'm yok" seçildiyse TV bağlanınca altyazı TV'ye gider.
        // "Yalnız OBS (yayın)" seçiliyken TV eşlenirse de altyazı TV'ye gider (Android'de TV seçilince olduğu gibi).
        if !settings.output.showsOnTV { settings.output = .tv }
        if tv.brand == .lg {
            await refreshTVApp()
        } else {
            // Samsung girişi ya da Android onayı dakikalar sürebilir; eşleşme beklemesin.
            Task { await refreshTVApp() }
        }
    }

    // MARK: - TV uygulamasının sürümü

    /// Bu Mac'teki TV paketinin sürümü (seçili TV'nin markası için); paket yoksa nil.
    private var bundledVersionForTV: String? {
        guard let tv else { return nil }
        return tv.brand == .lg ? services.bundledTVAppVersion : services.bundledApp(for: tv.brand)?.version
    }

    /// TV uygulaması altyazı akışına bağlandı ve sürümünü bildirdi (boş: 0.9.69'den eski, sürüm bildirmeyen uygulama).
    /// Eskiyse ana ekran "TV uygulamasını güncelle" der; geliştirici modu açık ve anahtar kayıtlıysa (LG) ya da TV'ye
    /// ulaşılıyorsa (Samsung, Android TV) güncelleme hemen, sorulmadan kurulur (önceki sürüm denetimiyle aynı yol).
    func tvAppReported(_ version: String) {
        runningTVAppVersion = version
        shareLatestTVAppVersion()
        if tv?.brand == .lg, lgRunningReported(version) { return }
        guard let bundled = bundledVersionForTV, SubtitleServer.isTVAppOutdated(reported: version, bundled: bundled) else {
            tvAppOutdated = nil
            return
        }
        let installed = version.isEmpty ? TVAppOutdated.unreported : version
        let first = tvAppOutdated == nil
        tvAppOutdated = TVAppOutdated(installed: installed, bundled: bundled)
        guard first else { return }
        // Sessiz güncelleme en çok saatte bir denenir: bağlantı her kopup geldiğinde (uyarı bağlantı kalkınca düşer)
        // başarısız kurulum yeniden denenmesin.
        if let last = lastTVAppAutoUpdate, Date().timeIntervalSince(last) < Self.tvAppAutoUpdateInterval {
            SubtitleLog.write("TV uygulaması eski: TV \(installed), bu Mac'teki paket \(bundled); son denemeden bu yana bir saat geçmedi.")
            return
        }
        lastTVAppAutoUpdate = Date()
        SubtitleLog.write("TV uygulaması eski: TV \(installed), bu Mac'teki paket \(bundled); güncelleme deneniyor.")
        Task { await refreshTVApp() }
    }

    /// LG, kurulumdan ya da kapat-aç'tan sonraki ilk sürüm bildirimi (`runningCheck`): çalışan uygulama kurulan sürümdeyse
    /// denetim biter; eskiyse bir kez daha kapatılıp açılır, yine eskiyse ana ekran "TV'de CouchSubs'ı kapatıp yeniden
    /// açın" der (fiş çekmek gerekmez). true: bildirim burada ele alındı. iPhone, Windows ve Android ile aynı.
    private func lgRunningReported(_ version: String) -> Bool {
        guard var check = runningCheck else { return false }
        let verdict = check.report(version)
        runningCheck = check
        let shown = version.isEmpty ? TVAppOutdated.unreported : version
        switch verdict {
        case .running:
            runningCheck = nil
            tvAppStaleRunning = false
            TVInstallLog.write("TV'de çalışan CouchSubs: \(shown) (kurulan \(check.expected)).")
            return false
        case .restartAgain:
            if let tv, let devKey = store.load(String.self, for: StoreKey.tvDevKey) {
                TVInstallLog.write("TV'de çalışan CouchSubs hâlâ \(shown), kurulu \(check.expected); uygulama bir kez daha kapatılıp açılıyor.")
                Task { await restartLGApp(tv, devKey: devKey) }
                return true
            }
            fallthrough
        case .stale:
            runningCheck = nil
            TVInstallLog.write("TV'de çalışan CouchSubs kapatıp açtıktan sonra da \(shown), kurulu \(check.expected); kullanıcıdan TV'de kapatıp açması isteniyor.")
            tvAppOutdated = TVAppOutdated(installed: shown, bundled: check.expected)
            tvAppStaleRunning = true
            return true
        }
    }

    /// LG: TV'deki CouchSubs'ı kapatır ve yeniden açar (adres ve anahtar parametreyle).
    private func restartLGApp(_ tv: LGTV, devKey: String) async {
        await services.closeTVApp(host: tv.host, devKey: devKey)
        await openTVAppAfterInstall(tv)
    }

    /// Eski TV uygulamasının sessiz güncellemesi en son ne zaman denendi (en çok saatte bir).
    private var lastTVAppAutoUpdate: Date?
    static let tvAppAutoUpdateInterval: TimeInterval = 3600

    /// Ana ekrandaki "TV uygulamasını güncelle": güncelleme hemen, ana ekranda başlar; ilerleme, eksik adım (Developer Mode
    /// kapalı, Passphrase) ve sonuç ana ekrandaki TV uygulaması kartında görünür. Eksik giderilince (geliştirici modu
    /// açılınca) kart kendiliğinden devam eder. Önceden TV adımı açılıyor, orada yalnız eşleştirme/test görünüyor, test
    /// onaylanınca aynı ana ekrana dönülüyordu.
    func updateTVApp() async {
        tvAppUpdating = true
        if await joinRunningTVAppRefresh("\"TV uygulamasını güncelle\"") { return }
        TVInstallLog.write("--- Ana ekrandan \"TV uygulamasını güncelle\" (TV \(tvAppOutdated?.installed ?? "?") → \(tvAppOutdated?.bundled ?? "?")).")
        await reinstallTVApp()
    }

    /// Ana ekranda TV uygulaması kartı açık (güncelleme sürüyor, bir adım bekliyor ya da sonucu gösteriyor).
    @Published private(set) var tvAppUpdating = false

    /// Ana ekrandaki TV uygulaması kartını kapatır ("Tamam").
    func dismissTVAppUpdate() { tvAppUpdating = false }

    /// Telefon ipucundaki "Aç": "GTA 6 Telefonunu Çevir" açılır.
    func enableGamePhone() {
        settings.translatesGamePhone = true
        showsGamePhoneHint = false
    }

    func dismissGamePhoneHint() { showsGamePhoneHint = false }

    // MARK: - TV uygulamasını kurma

    /// Geliştirici modu açık TV'de uygulamayı eksikse kurar, eskiyse günceller.
    /// Anahtar yoksa ve uygulama çalışıyorsa kullanıcıdan bir şey istenmez.
    func refreshTVApp() async {
        // İptal edilmiş görevden (kapanan kartın beklemesi) TV'ye sorulmaz; sorulursa yardımcı boşuna açılır (#359).
        guard let tv, !refreshingTVApp, !Task.isCancelled else {
            if tv == nil, tvAppOutdated != nil { TVInstallLog.write("TV uygulaması denetlenmedi: TV seçili değil.") }
            return
        }
        refreshingTVApp = true
        defer {
            refreshingTVApp = false
            let waiting = refreshWaiters
            refreshWaiters = []
            waiting.forEach { $0.resume() }
        }
        switch tv.brand {
        case .lg: await refreshLGApp(tv)
        case .samsung: await refreshSamsungApp(tv)
        case .androidTV: await refreshAndroidApp(tv)
        }
    }

    /// Süren TV uygulaması denetiminin/kurulumunun bitmesini bekleyenler.
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    /// Samsung ve Android TV'de denetim ya da kurulum sürüyorsa yenisi başlatılmaz: günlüğe yazılır ve sürenin bitmesi
    /// beklenir (true). #1223: "güncelle"ye üç kez basılınca aynı TV'ye üç kurulum başlıyordu; TV sdb bağlantılarını kapattı
    /// (Windows ile aynı).
    func joinRunningTVAppRefresh(_ what: String) async -> Bool {
        guard let tv, tv.brand != .lg, refreshingTVApp else { return false }
        TVInstallLog.write("\(what): TV uygulaması denetimi/kurulumu zaten sürüyor; yeni kurulum başlatılmadı, sürenin bitmesi bekleniyor.")
        await withCheckedContinuation { refreshWaiters.append($0) }
        return true
    }

    /// Samsung ya da Android TV'ye daha önce CouchSubs'ın kurduğu sürüm.
    private var installedAppVersion: String? { store.load(String.self, for: StoreKey.tvAppVersion) }

    /// Samsung TV'nin kurulu uygulama listesi CouchSubs'ın silindiğini söyledi (bkz. `SamsungAppKnowledge.appMissing`):
    /// "kurulu" kaydı silinir, kart kurulum adımlarını gösterir. iPhone, Windows ve Android ile aynı.
    func samsungAppMissing(host: String) {
        guard let tv, tv.brand == .samsung, SamsungAppKnowledge.sameHost(tv.host, host) else { return }
        store.remove(StoreKey.tvAppVersion)
        tvAppMissing = true
        if case .upToDate = tvApp { tvApp = .unknown }
    }

    private func needsInstall(_ bundled: BundledTVApp) -> Bool {
        guard let installed = installedAppVersion else { return true }
        return DevModeInstaller.isNewer(bundled.version, than: installed)
    }

    private func refreshLGApp(_ tv: LGTV) async {
        guard let bundled = services.bundledTVAppVersion else {
            lgSkipped("bu Mac'te LG TV paketi yok")
            return
        }
        guard !tv.host.isEmpty else {
            lgSkipped("TV'nin adresi yok")
            return
        }
        var tv = tv
        var devModeOn = await services.isDevModeOn(host: tv.host)
        // Geliştirici modu kapalı görünüyorsa önce adres: TV'nin adresi değiştiyse eski adres hiç yanıt vermez; "geliştirici
        // modu kapalı" denmez, TV ağda yeniden aranır (beta.89, 192.168.1.238 → .156).
        var silent = false
        if !devModeOn {
            switch await locateTV() {
            case .moved(let moved):
                tv = moved
                devModeOn = await services.isDevModeOn(host: moved.host)
            case .silent: silent = true
            case .here: break
            }
        }
        // Beklerken parola kartından kurulum başladıysa kart geri "geliştirici modu kapalı"ya dönmez.
        if tvApp == .working { return }
        // Eski TV uygulaması da eksik gibi kurulum adımlarını gösterir: bağlı (eski) uygulamada kart boş kalıyor, "TV
        // uygulamasını güncelle" TV adımını açıp yalnız eşleştirme/test gösteriyor, ana ekrana dönülüyordu (sonsuz döngü).
        let needsSteps = tvAppMissing || tvAppOutdated != nil
        if silent {
            if needsSteps { lgSkipped("\(TVReach.notRespondingLine) (\(tv.host))") }
            tvApp = needsSteps ? .failed(.tvNotResponding) : .unknown
            return
        }
        guard devModeOn else {
            if needsSteps { lgSkipped("geliştirici modu kapalı ya da TV'ye ulaşılamıyor (\(tv.host):9922)") }
            tvApp = needsSteps ? .devModeOff : .unknown
            return
        }
        guard let devKey = store.load(String.self, for: StoreKey.tvDevKey) else {
            if needsSteps { lgSkipped("Key Server anahtarı bu Mac'te yok; Passphrase isteniyor") }
            tvApp = needsSteps ? .needsPassphrase(error: nil) : .unknown
            return
        }
        await install(tv: tv, devKey: devKey, bundled: bundled)
    }

    /// LG kurulumu ya da güncellemesi başlamadıysa nedeni kurulum günlüğüne bir kez yazılır (her 3 sn'lik denetimde değil):
    /// önceden "TV uygulamasını güncelle"ye basınca tvinstall.log'a hiç satır düşmüyordu.
    private func lgSkipped(_ reason: String) {
        guard reason != lastLGSkipReason else { return }
        lastLGSkipReason = reason
        TVInstallLog.write("LG kurulumu başlamadı: \(reason).")
    }

    /// Samsung: geliştirici modu açıksa TV'deki CouchSubs sürümüne bakar, yoksa ya da eskiyse imzalayıp kurar
    /// (sertifika yoksa Samsung girişi istenir). Önceden yalnız bu Mac'in kurduğu sürüm hatırlanıyordu; TV'de eski
    /// kalan uygulama (ör. 0.9.10 gelirken 0.9.7) hiç güncellenmiyordu.
    private func refreshSamsungApp(_ tv: LGTV) async {
        guard let bundled = services.bundledApp(for: .samsung) else { return }
        // TV eski sürümü bildirdiyse bu Mac'in kurduğu sürümün kaydına güvenilmez: kurulum adımları gösterilir.
        let remembered = !needsInstall(bundled) && tvAppOutdated == nil
        let current = TVAppState.upToDate(installedAppVersion ?? bundled.version)
        // TV 8001'de geliştirici modunu ve Host PC IP'yi söyler (Android ve iPhone uygulaması da buna bakar). Host PC IP
        // bu Mac'inki değilse TV sdb el sıkışmasında bağlantıyı keser (#343); sdb hiç denenmez, iki adres söylenir.
        let check = await services.checkSamsung(host: tv.host)
        let devModeOn: Bool
        if check.info?.developerMode == false { devModeOn = false } else { devModeOn = await services.isSamsungDevModeOn(host: tv.host) }
        // TV 8001'de de yanıt vermediyse adres değişmiş olabilir: TV ağda aranır, bulunursa yeni adresle denetlenir.
        if !devModeOn, check.info == nil {
            switch await locateTV() {
            case .moved(let moved):
                await refreshSamsungApp(moved)
                return
            case .silent:
                tvApp = remembered ? current : .failed(.tvNotResponding)
                return
            case .here: break
            }
        }
        guard devModeOn else {
            // Geliştirici modu kapalıyken TV'ye sorulamaz; bu Mac'in kurduğu sürüme bakılır.
            tvApp = remembered ? current : .devModeOff
            return
        }
        if let tvIp = check.info?.developerIp, let computer = check.computerAddress,
           SamsungDeveloperInfo.hostPcIpMismatch(developerIp: tvIp, computer: computer) {
            TVInstallLog.write("TV'deki Host PC IP (developerIP) \(tvIp), bu Mac'in TV'ye giden adresi \(computer); kurulum denenmedi.")
            tvApp = remembered ? current : .hostPcMismatch(tvIp: tvIp, computer: computer)
            return
        }
        // Güncel bilinen uygulamada denetim sessiz sürer; kart ancak kurulum başlarsa değişir.
        tvApp = remembered ? current : .working
        samsungCheckRunning = true
        defer { samsungCheckRunning = false }
        do {
            let result = try await services.installSamsungApp(host: tv.host, app: bundled, replaceForeign: replaceForeignApp) { [weak self] event in
                Task { @MainActor in self?.installEvent(event) }
            }
            store.save(result.version, for: StoreKey.tvAppVersion)
            SamsungAppKnowledge.shared.mark(host: tv.host)
            tvApp = .upToDate(result.version)
            if result.installed { await openTVAppAfterInstall(tv) }
        } catch let failure as DevModeFailure where remembered && failure.error == .unreachable {
            // TV sdb bağlantısını kabul etmedi (ör. Host PC IP değişti): çalışan uygulama "kurulamadı" diye gösterilmez.
            tvApp = current
        } catch DevModeError.unreachable where remembered {
            tvApp = current
        } catch {
            tvApp = Self.failedState(error)
        }
    }

    /// Kurulumun TV'yi değiştiren adımları (yalnız sürüm okumak değil).
    static func isInstallStep(_ step: String) -> Bool {
        ["signin", "certificate", "signing", "installing", "uninstalling", "play"].contains(step)
    }

    /// Kurulum hatası ve yardımcının verdiği sebep (TV'nin kurulum çıktısı, Samsung'un yanıtı); sebep de gösterilir.
    static func failedState(_ error: Error) -> TVAppState {
        guard let failure = error as? DevModeFailure else { return .failed(error as? DevModeError ?? .installFailed) }
        let reason = failure.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(failure.error, reason: reason.isEmpty ? nil : reason)
    }

    /// Android TV: ağda ADB'si açık TV'yi bulur, uygulamayı kurar ve açar.
    private func refreshAndroidApp(_ tv: LGTV) async {
        guard let bundled = services.bundledApp(for: .androidTV) else { return }
        var host = tv.host
        let reachable = host.isEmpty ? false : await services.isAndroidDebugOn(host: host)
        if !reachable {
            // Bu Mac'in kurduğu sürüm kayıtlıysa ve TV'de hata ayıklama kapalıysa yapılacak bir şey yok. Ama kayda ancak
            // TV'nin adresi biliniyorsa ya da TV uygulaması şu an bağlıysa güvenilir: TV sihirbazda yeniden seçilince adres
            // boşalıyor, kayıt kalıyordu; TV'den kaldırılan uygulama "hazır" görünüyor, kurulum denenmiyordu (#352, #389).
            if !needsInstall(bundled), tvAppOutdated == nil, !tv.host.isEmpty || tvClients > 0 {
                tvApp = .upToDate(installedAppVersion ?? bundled.version)
                return
            }
            // Birden çok TV varsa ilk bulunana gidilmez: kayıtlı ya da seçilen TV, yoksa kullanıcıya sorulur. Eskiden izin
            // sorusu başka odadaki TV'de çıkıyor, kurulum "onaylanmadı" diye bitiyordu (#425).
            let choice = androidTVChoice
            androidTVChoice = nil
            switch AndroidTVPick.pick(found: await services.scanAndroidTVs(), preferred: [choice, tv.host].compactMap { $0 }) {
            case .none:
                // Kayıtlı adres hiç yanıt vermiyorsa "hata ayıklama kapalı" denmez: TV ağda aranır (bulunursa adres
                // güncellenir; hata ayıklama orada da kapalıysa adımlar gösterilir), bulunamazsa "TV bu adreste yanıt vermiyor".
                if case .silent = await locateTV() {
                    tvApp = .failed(.tvNotResponding)
                    return
                }
                tvApp = .devModeOff
                return
            case .ask(let hosts):
                TVInstallLog.write("Ağda hata ayıklaması açık birden çok Android TV var (\(hosts.joined(separator: ", "))); TV soruluyor.")
                tvApp = .chooseAndroidTV(hosts)
                return
            case .host(let found):
                host = found
            }
        }
        tvApp = .working
        let open = openTVAppAfterCheck
        openTVAppAfterCheck = false
        do {
            let version = try await services.installAndroidApp(host: host, app: bundled, open: open,
                                                               replaceForeign: replaceForeignApp) { [weak self] event in
                Task { @MainActor in self?.installEvent(event) }
            }
            // TV'nin adresi bundan sonra sürüm denetimi için kullanılır.
            let located = LGTV(name: tv.name, host: host, brand: .androidTV, uuid: tv.uuid, mac: tv.mac)
            let addressChanged = self.tv?.host != located.host
            if addressChanged, let old = self.tv?.host, !old.isEmpty { TVInstallLog.write(TVReach.movedLine(from: old, to: host)) }
            self.tv = located
            store.save(located, for: StoreKey.tv)
            store.save(version, for: StoreKey.tvAppVersion)
            tvApp = .upToDate(version)
            if addressChanged {
                // Çeviri sürerken ADB bekçisi eski adresi tutar; yeni TV kaydıyla yeniden oluştur.
                keeper?.stop()
                keeper = nil
                if isRunning && settings.output.showsOnTV { startKeeper(refreshApp: false) }
            }
        } catch {
            tvApp = Self.failedState(error)
        }
    }

    private func installEvent(_ event: TVInstallEvent) {
        // Kurulum bittikten sonra gelen geç olay sonucu ezmesin.
        switch tvApp {
        case .working, .signIn, .approveOnTV, .pressInstallOnTV: break
        default: if !samsungCheckRunning { return }
        }
        switch event {
        // Android TV'de Google Play sayfası açıldı: kart TV'de Yükle'ye basılmasını söyler. Önceden yalnız "kuruluyor"
        // görünüyordu; TV'deki sayfayı görmeyen kullanıcı dört dakika boyunca bir şey olmuyor sanıyordu.
        case .progress("play"):
            tvApp = .pressInstallOnTV
        case .signIn(let url):
            tvApp = .signIn(url)
            openInBrowser(url)
        case .approveOnTV:
            tvApp = .approveOnTV
        case .progress(let step):
            if case .signIn = tvApp {
                tvApp = .working
            } else if tvApp != .working, Self.isInstallStep(step) {
                // Sürüm denetimi güncelleme kurmaya başladı: kart "kuruluyor"a geçer.
                tvApp = .working
            }
        }
    }

    /// Birden çok Android TV arasından seçilen TV'ye kurulur (#425).
    func chooseAndroidTV(_ host: String) async {
        androidTVChoice = host
        tvApp = .working
        await refreshTVApp()
    }

    /// TV uygulaması bağlı değilken üç markada da "TV uygulamasını yeniden kur" görünür (ana ekran ve TV kartı). TV'den
    /// kaldırılan uygulama bu Mac'in kaydında "kurulu" kalıyordu (#352, #389). LG'de önceden yoktu: kayıtlı anahtar varsa
    /// Passphrase sorulmadan, yoksa Passphrase adımıyla yeniden kurulur.
    var canReinstallTVApp: Bool {
        guard tv != nil else { return false }
        return canInstallTVApp && tvClients == 0
    }

    /// TV eşleşmiş ama TV uygulaması bağlı değilken (LG dahil) ana ekranda "TV'ye bağlan" görünür: TV adımı açılır, başka
    /// TV seçilebilir ya da LG kurulum adımları (Developer Mode, Passphrase) yeniden izlenir. Önceden kurulum bittikten
    /// sonra LG'de TV adımına dönmenin görünür bir yolu yoktu (yalnız Hakkında › Yeniden kur).
    var canReconnectTV: Bool { hasTV && !canReinstallTVApp && tvClients == 0 }

    /// TV eşleşmişken (TV uygulaması bağlı olsa da) ana ekranda "TV'yi değiştir" görünür: yalnız TV adımı açılır, başka TV
    /// seçilir; "Yeniden kur…" ile bütün kurulumu baştan yapmak gerekmez. "TV'ye bağlan" aynı yere gittiği için ikisi
    /// birden çıkmaz.
    var canChangeTV: Bool { hasTV && !canReconnectTV }

    /// Kullanıcı "Kaldırıp Kur"a bastı (yalnız `.failed(.foreignApp)`'ta sorulur): bir kerelik olarak TV'de CouchSubs'ın
    /// kimliğini kullanan başka uygulama kaldırılır ve CouchSubs kurulur. Onay olmadan hiçbir markada bir şey silinmez
    /// (Windows'taki ReplaceForeignTvAppAsync ile aynı).
    private var replaceForeignApp = false

    func replaceForeignTVApp() async {
        guard let tv else { return }
        TVInstallLog.write("Kullanıcı onayladı: TV'de CouchSubs'ın kimliğini kullanan başka uygulama kaldırılıp CouchSubs kurulacak.")
        replaceForeignApp = true
        defer { replaceForeignApp = false }
        if tv.brand == .lg {
            lastLGSkipReason = nil
            await reinstallLGApp(tv)
            return
        }
        tvApp = .working
        await refreshTVApp()
    }

    /// Kurulan sürüm kaydını unutur ve TV'ye yeniden bakar: uygulama TV'de yoksa kurulur, Android TV'de varsa açılır.
    /// TV'ye ulaşılamazsa kart geliştirici modu / hata ayıklama adımlarını gösterir.
    func reinstallTVApp() async {
        guard let tv else {
            TVInstallLog.write("TV uygulaması kurulamadı: TV seçili değil.")
            return
        }
        lastLGSkipReason = nil
        if tv.brand == .lg {
            await reinstallLGApp(tv)
            return
        }
        if await joinRunningTVAppRefresh("\"TV uygulamasını yeniden kur\"") { return }
        store.remove(StoreKey.tvAppVersion)
        openTVAppAfterCheck = true
        tvApp = .unknown
        await refreshTVApp()
    }

    /// LG'de TV uygulamasını yeniden kurar: kayıtlı anahtar varsa Passphrase sorulmadan paket yeniden kurulur ve açılır;
    /// anahtar yoksa (ya da TV reddederse) Passphrase adımı, geliştirici modu kapalıysa adımları görünür.
    private func reinstallLGApp(_ tv: LGTV) async {
        TVInstallLog.write("--- LG: TV uygulamasını yeniden kurma/güncelleme istendi (TV \(tv.host.isEmpty ? "adresi yok" : tv.host)).")
        guard let bundled = services.bundledTVAppVersion else {
            lgSkipped("bu Mac'te LG TV paketi yok")
            return
        }
        lgReinstallRequested = true
        // Kurulum adımları görünsün: TV uygulaması bağlı değil, kullanıcı yeniden kurmak istiyor.
        tvAppMissing = true
        tvApp = .working
        var tv = tv
        if !(await services.isDevModeOn(host: tv.host)) {
            switch await locateTV(force: true) {
            case .moved(let moved): tv = moved
            case .silent:
                lgSkipped("\(TVReach.notRespondingLine) (\(tv.host))")
                tvApp = .failed(.tvNotResponding)
                return
            case .here: break
            }
        }
        guard await services.isDevModeOn(host: tv.host) else {
            lgSkipped("geliştirici modu kapalı ya da TV'ye ulaşılamıyor (\(tv.host):9922)")
            tvApp = .devModeOff
            return
        }
        guard let devKey = store.load(String.self, for: StoreKey.tvDevKey) else {
            lgSkipped("Key Server anahtarı bu Mac'te yok; Passphrase isteniyor")
            tvApp = .needsPassphrase(error: nil)
            return
        }
        await install(tv: tv, devKey: devKey, bundled: bundled)
    }

    /// Seçili TV'ye uygulamayı CouchSubs kurabilir mi (paket uygulamayla geldi mi)?
    var canInstallTVApp: Bool {
        guard let tv else { return false }
        return tv.brand == .lg ? services.bundledTVAppVersion != nil : services.bundledApp(for: tv.brand) != nil
    }

    /// Testlerde tarayıcı açılmasın diye değiştirilebilir.
    var openInBrowser: (URL) -> Void = { url in
        // Tarayıcı öne gelsin: sayfa arkada açılınca kullanıcı giriş penceresini görmüyordu. Açılmazsa kart "Sayfayı
        // yeniden aç" ve "Bağlantıyı kopyala" ile bekler; günlükte de görünür.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error { TVInstallLog.write("Tarayıcı açılamadı: \(url.absoluteString): \(error.localizedDescription)") }
        }
    }

    /// Samsung'da geliştirici modunda "Host PC IP" olarak yazılacak bu Mac'in adresi.
    var computerAddress: String? {
        Self.localAddress(near: tv?.host.isEmpty == false ? tv!.host : nil)
    }

    /// Host PC IP için gösterilenin dışındaki ev ağı adresleri (Wi-Fi ve Ethernet ikisi de bağlıysa ya da birden çok ağ
    /// varsa). TV gösterilen adresi kabul etmezse bunlar denenir.
    var otherComputerAddresses: [String] {
        let chosen = computerAddress
        return NetworkAddress.homeAddresses().filter { $0 != chosen }
    }

    /// Key Server'dan anahtarı alır (TV ekranındaki parolayla) ve uygulamayı kurar.
    func installTVApp(passphrase: String) async {
        guard var tv, let bundled = services.bundledTVAppVersion else { return }
        tvApp = .working
        var relocated = false
        while true {
            do {
                TVInstallLog.lgKeyRequest(host: tv.host)
                let devKey = try await services.fetchDevKey(host: tv.host, passphrase: passphrase.trimmingCharacters(in: .whitespacesAndNewlines))
                TVInstallLog.write("Key Server'dan anahtar alındı.")
                store.save(devKey, for: StoreKey.tvDevKey)
                await install(tv: tv, devKey: devKey, bundled: bundled)
            } catch {
                TVInstallLog.failure(error)
                let failed = (error as? DevModeFailure)?.error ?? error as? DevModeError ?? .installFailed
                // "Key Server kapalı" ancak TV bu adreste yanıt veriyorsa: adres hiç yanıt vermiyorsa TV ağda aranır, yeni
                // adreste bulunursa anahtar oradan bir kez daha istenir; bulunamazsa "TV bu adreste yanıt vermiyor".
                if !relocated, failed == .keyServerOff || failed == .unreachable {
                    relocated = true
                    switch await locateTV(force: true) {
                    case .moved(let moved):
                        tv = moved
                        continue
                    case .silent:
                        tvApp = .needsPassphrase(error: .tvNotResponding)
                        return
                    case .here: break
                    }
                }
                tvApp = .needsPassphrase(error: failed)
            }
            return
        }
    }

    private func install(tv: LGTV, devKey: String, bundled: String) async {
        tvApp = .working
        // LG kurulumunun adımları da kurulum günlüğüne yazılır (telefonlardaki satırlar); önceden yalnız Samsung ve
        // Android TV kurulumu günlük tutuyordu, LG hatasında gönderilecek bir şey yoktu.
        TVInstallLog.lgStart(host: tv.host, package: bundled)
        do {
            // Kullanıcı "Kaldırıp Kur" dediyse TV'deki (başka) uygulamanın sürümüne bakılmaz; o kaldırılıp CouchSubs kurulur.
            // Yoksa TV'de CouchSubs'ın kimliğiyle başka uygulama varsa sürüm okuması .foreignApp fırlatır.
            let replace = replaceForeignApp
            let installed = replace ? nil : try await services.installedTVAppVersion(host: tv.host, devKey: devKey)
            TVInstallLog.write("TV'deki CouchSubs: \(replace ? "başka uygulama (kaldırılacak)" : installed ?? "yok")")
            // "Yeniden kur": TV'deki sürüm güncel görünse de paket yeniden kurulur (anahtar reddedilirse istek sürer,
            // Passphrase yazılınca kurulur).
            let force = lgReinstallRequested
            lgReinstallRequested = false
            if force { TVInstallLog.write("Yeniden kurulum istendi; TV'deki sürüme bakılmadan kuruluyor.") }
            if !force, let installed, !DevModeInstaller.isNewer(bundled, than: installed) {
                tvApp = .upToDate(installed)
                // Paket güncel ama TV'de çalışan uygulama eski (beta.89: webOS kurulumdan sonra eski süreci tuttu):
                // yeniden kurmak gerekmez, uygulama kapatılıp açılır.
                if tvClients > 0, let running = runningTVAppVersion, TVAppRunningCheck.isStale(running: running, installed: installed) {
                    TVInstallLog.write("TV'deki paket \(installed), çalışan CouchSubs \(running.isEmpty ? TVAppOutdated.unreported : running); uygulama kapatılıp yeniden açılıyor.")
                    runningCheck = TVAppRunningCheck(expected: installed)
                    await restartLGApp(tv, devKey: devKey)
                }
                await renewDevSessionIfDue(tv: tv, devKey: devKey)
                return
            }
            try await services.installTVApp(host: tv.host, devKey: devKey, replaceForeign: replace)
            TVInstallLog.write("Kurulum tamam.")
            tvApp = .upToDate(bundled)
            tvAppMissing = false
            // Açılan uygulamanın bildirdiği sürüm denetlenir (lgRunningReported).
            runningCheck = TVAppRunningCheck(expected: bundled)
            await renewDevSessionIfDue(tv: tv, devKey: devKey)
            await openTVAppAfterInstall(tv)
        } catch DevModeError.keyRefused {
            // Geliştirici modu yeniden açılınca TV yeni anahtar üretir; eskisi işe yaramaz.
            TVInstallLog.write("Kayıtlı anahtar reddedildi; bırakıldı.")
            store.remove(StoreKey.tvDevKey)
            tvApp = .needsPassphrase(error: nil)
        } catch let failure as DevModeFailure {
            TVInstallLog.failure(failure)
            // Genel mesaj tek başına sorunu bulmaya yetmiyordu; TV'nin verdiği sebep de gösterilir.
            let reason = failure.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            tvApp = .failed(failure.error, reason: reason.isEmpty ? nil : reason)
        } catch {
            TVInstallLog.failure(error)
            tvApp = .failed(error as? DevModeError ?? .installFailed)
        }
    }

    /// LG geliştirici modunun 1000 saatlik süresini günde en çok bir kez baştan başlatır; kullanıcı TV'den uzatmak
    /// zorunda kalmaz.
    private func renewDevSessionIfDue(tv: LGTV, devKey: String) async {
        let key = StoreKey.devSessionRenewedFor(host: tv.host)
        let last = defaults.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        if let hours = await services.renewDevSession(host: tv.host, devKey: devKey) {
            devModeHoursLeft = hours
            defaults.set(Date(), forKey: key)
        }
    }

    private func openTVAppAfterInstall(_ tv: LGTV) async {
        if let keeper {
            // Kurulum uygulamayı kapattı: sunucu kopan akışı henüz fark etmese de uygulama açılır.
            keeper.reopenApp()
        } else {
            _ = try? await services.pairTV(tv, key: store.load(String.self, for: StoreKey.tvKey), server: serverAddress(for: tv), accessKey: server.accessKey)
        }
    }

    /// Ana ekrandaki "TV'de test et": sunucu henüz açık değilse açılır, deneme altyazısı gönderilir.
    func testSubtitle() async {
        try? await startServer()
        // Çeviri sürmüyorken TV'nin eşleştirme isteği (TV 0.9.34+) reddediliyordu: Android TV anahtarı başlatma yoluyla
        // alamaz, "TV'de test et"e TV'de yalnız "Eşleştirme tamamlanmadı" çıkıyordu. Deneme, Ayarlar'daki "TV eşleştir"
        // gibi iki dakikalık onay penceresi açar; TV kodu gösterince bilgisayarda onay sorulur.
        if !isRunning { server.pairing.open() }
        // TV uygulaması bağlı değilse deneme altyazısı kimseye gitmiyordu: bekçi yalnız çeviri sürerken çalışır, TV
        // uygulaması kapalıysa ya da bilgisayarı arıyorsa "TV'de test et"e TV'de hiçbir şey çıkmıyordu (Samsung 65S95F).
        // Önce TV uygulaması açılır (Samsung'da geliştirici bağlantısıyla) ve bağlanması beklenir.
        if settings.output.showsOnTV, hasTV, let tv, server.connectedClients == 0 {
            await waitForTVApp(tv)
        }
        // Beklemeden sonra da TV bağlı değilse deneme yazısı TV'ye gitmez: TV'deki 6 haneli kodun nereye yazılacağı
        // aranıyordu (kod yazılmaz, bu bilgisayarda açılan pencerede onaylanır). Ana ekran bunu söyler.
        testTVNotConnected = settings.output.showsOnTV && hasTV && server.connectedClients == 0
        sendTestSubtitle()
    }

    /// TV uygulamasını açar (Android TV'de uygulama bilgisayarı kendisi bulur, eşleştirme onayı da gerekebilir) ve
    /// bağlanmasını bekler. Bekleme süresince `openingTVAppForTest` açıktır (düğme ve TV kartı "TV'de açılıyor…" der).
    private func waitForTVApp(_ tv: LGTV) async {
        if tv.brand != .androidTV {
            await openTVAppForTest(tv)
            return
        }
        openingTVAppForTest = true
        let deadline = ContinuousClock.now + testPairWait
        while server.connectedClients == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        openingTVAppForTest = false
    }

    /// Ayarlar › TV kartındaki "TV'de CouchSubs'ı Aç": TV eşli ama uygulama bağlı değilken eşleştirmeyi yeniden istemek
    /// yerine TV'de uygulama açılır; iki dakikalık eşleştirme onayı da açılır (TV kod gösterirse bu Mac'te sorulur).
    /// TV uygulaması bağlandıysa true.
    func openTVAppOnTV() async -> Bool {
        guard hasTV, let tv else { return false }
        guard await ensureTVReachable() else { return false }
        await openTVPairing()
        if server.connectedClients == 0 { await waitForTVApp(tv) }
        return server.connectedClients > 0
    }

    /// Son "TV'de test et"te TV uygulaması bağlanmadı (ana ekran eşleştirme yönergesini gösterir; TV bağlanınca kalkar).
    @Published private(set) var testTVNotConnected = false

    /// "TV'de test et"te TV uygulamasının açılıp bağlanması için en çok bu kadar beklenir.
    var testTVWait: Duration = .seconds(20)
    /// Android TV'de deneme altyazısı için TV'nin bağlanması (gerekirse eşleştirme onayı) en çok bu kadar beklenir.
    var testPairWait: Duration = .seconds(30)
    /// Deneme altyazısından önce TV uygulaması açılıp bağlanması bekleniyor (düğme bunu gösterir).
    @Published private(set) var openingTVAppForTest = false

    /// TV uygulamasını açar ve bağlanmasını bekler. Çeviri sürüyorsa bekçi hemen yeniden dener; sürmüyorsa geçici bir
    /// bekçi kurulur, bekleme bitince kapanır.
    private func openTVAppForTest(_ tv: LGTV) async {
        var temporary: KeeperControlling?
        if let keeper {
            keeper.reconnect()
        } else {
            let server = self.server
            let made = services.makeKeeper(tv: tv, key: store.load(String.self, for: StoreKey.tvKey), params: ["server": serverAddress(for: tv), "key": server.accessKey],
                                           appConnected: { server.connectedClients > 0 }, onMoved: { [weak self] moved in
                // Bekçinin yeniden bulucusu satırı kendisi yazdı (kimlikle mi, adla mı).
                Task { @MainActor in self?.tvMoved(to: moved, logged: true) }
            }, onKey: { [weak self] key in
                Task { @MainActor in self?.store.save(key, for: StoreKey.tvKey) }
            }, consolePort: { server.consolePort }, onOpenResult: { _ in })
            made.start(interval: .seconds(5))
            temporary = made
        }
        openingTVAppForTest = true
        let deadline = ContinuousClock.now + testTVWait
        while server.connectedClients == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        temporary?.stop()
        openingTVAppForTest = false
    }

    func sendTestSubtitle() {
        server.sendStyle(settings.style)
        // Oyunda henüz altyazı görülmediyse altyazı bölgesinin altına yakın tipik bir yer kullanılır.
        let region = settings.region
        let box = lastSubtitleBox ?? TextBox(left: 0.3, top: region.bottom - 0.1, right: 0.7, bottom: region.bottom - 0.03)
        server.sendSubtitle(String(localized: "This is a test subtitle. Can you see it on top of the game?"), durationMs: 8000, box: box)
    }

    /// Kurulumu baştan başlatır (kayıtlı her şeyi siler).
    func resetSetup() {
        stop()
        [StoreKey.accountId, StoreKey.console, StoreKey.tv, StoreKey.tvKey, StoreKey.tvDevKey, StoreKey.tvAppVersion,
         StoreKey.setupComplete, StoreKey.loginPasscode].forEach(store.remove)
        hasLoginPasscode = false
        accountId = nil
        console = nil
        store.remove(XboxStoreKey.console)
        xboxConsole = nil
        signOutXbox()
        defaults.removeObject(forKey: XboxStoreKey.platform)
        platform = .playstation
        tv = nil
        tvKeySaved = false
        tvApp = .unknown
        tvAppMissing = false
        step = .welcome
    }

    // MARK: - Çeviri

    /// Deneme modunu açar: konsol, hesap ve TV olmadan örnek karelerle çeviri başlar (altyazı ana pencerede ve seçiliyse
    /// bilgisayar ekranında ya da TV'de). Çalışan çeviri önce durdurulur.
    func startDemo() async {
        guard !isStarting else { return }
        if isRunning { stop() }
        demoMode = true
        showSettings = false
        await start()
        if !isRunning { demoMode = false }
    }

    /// Deneme modundan çıkar; uygulama kaldığı yere (kurulum ya da ana ekran) döner.
    func exitDemo() {
        stop()
        demoMode = false
    }

    func start() async {
        // Düğmeye iki kez basılması ya da beklerken tekrar çağrılması ikinci bir oturum açmaz.
        guard !isRunning, !isStarting, canStart || demoMode else { return }
        // PS5'e bağlanmak için eşleşmiş PS5 ve ikinci hesap gerekir; PS Remote Play penceresinden okumak için gerekmez.
        // Xbox (Beta) bağlantısı için Microsoft girişi ve seçilmiş Xbox gerekir.
        // Xbox'ta seçilen pencere okunuyorsa (#853) Xbox'a hiç bağlanılmaz: Xbox aynı anda tek bağlantıya izin verir.
        let xbox = isXbox && !demoMode && xboxSignedIn && !readsXboxWindow ? xboxConsole : nil
        let readsWindow = !isXbox && settings.frameSource == .remotePlayWindow && !demoMode
        let captureTarget = readsCaptureWindow && !demoMode ? settings.captureWindow : nil
        guard demoMode || readsWindow || captureTarget != nil || (isXbox ? xbox != nil : console != nil && accountId != nil) else { return }
        isStarting = true
        defer { isStarting = false }

        translatorStatus = await Translator.status(source: settings.sourceLanguage, target: settings.targetLanguage)
        try? await startServer()
        server.sendStyle(settings.style)

        makePipeline()
        sessionStartedAt = Date()
        // Konuşan renkleri oturum başına: yeni oturumda kişiler yeniden sıralanır.
        server.speakerBook.reset()
        lastMetrics = nil
        subtitleOffTip.reset()
        updateSubtitleOffTip()
        gamePhoneHint.reset()
        showsGamePhoneHint = false
        if settings.dubbing.enabled, dubbingReady { makeDubber().prepare() }
        SubtitleLog.write("oturum başladı: CouchSubs \(AppIdentity.version), \(settings.sourceLanguage)→\(settings.targetLanguage), "
            + "motor: \(onlineTranslationActive ? settings.onlineEngine.rawValue : "ücretsiz"), "
            + "seçilen motor: \(settings.translationEngine.rawValue), paketler: \(settings.gamePacks ? "açık" : "kapalı"), "
            + "görüntü: \(demoMode ? "deneme modu" : xbox != nil ? "Xbox (Beta)" : readsWindow ? "PS Remote Play penceresi" : captureTarget != nil ? "seçilen pencere" : "PS5"), "
            + SubtitleLog.areaSummary(settings))

        let session: StreamControlling
        if demoMode {
            RemotePlayLog.write("Deneme modu başladı (örnek kareler)")
            session = DemoStream()
        } else if readsWindow {
            RemotePlayLog.write("Çeviri başladı; görüntü bu Mac'teki Remote Play penceresinden (\(settings.remotePlayApp.rawValue))")
            session = services.makeWindowStream(app: settings.remotePlayApp)
        } else if let captureTarget {
            RemotePlayLog.write("Çeviri başladı; seçilen pencere: \(captureTarget.processName) / \(captureTarget.title)")
            session = services.makeCaptureWindowStream(target: captureTarget)
        } else if let xbox {
            RemotePlayLog.write("Çeviri başladı; Xbox'a bağlanılıyor (Beta): \(xbox.name)")
            guard let made = makeConsoleSession(xbox: xbox) else { return }
            session = made
        } else if console != nil, accountId != nil {
            if let console { RemotePlayLog.write("Çeviri başladı; PS5'e bağlanılıyor: \(console.name) \(console.host)") }
            guard let made = makeConsoleSession(xbox: nil) else { return }
            session = made
        } else {
            return
        }
        sessionIsConsole = !demoMode && !readsWindow && captureTarget == nil
        attach(session)
        // Oturum başlamadan atanır: hemen gelen durum "eski oturumun" sayılıp atılmasın (bkz. `attach`).
        self.session = session
        // Yapışık çeviri açıkken pencere saniyede 30 kare yakalanır (çapa izlemesi için; okuma yine en çok 10).
        capturedWindow?.setFastFrames(settings.drawScreenInPlace)
        configureGamePhone()
        session.start()
        reconnectOffer.reset(now: Date())

        startKeeper()
        // Deneme karelerinde oyun yoktur: oyun sorulmaz, oyuna göre alan uygulanmaz.
        if !demoMode {
            gameAreas.start()
            // Remote Play penceresinden okurken PS5 eşleşmesi olmayabilir; son oyun o zaman PS5 adı olmadan hatırlanır.
            // Xbox çalışan oyunu bildirmez: Xbox için son seçilen oyun (Xbox penceresinden okurken de) kendiliğinden
            // kullanılır, hiç seçim yoksa Oyun karosu vurgulanır (`GameChoice.xboxNeedsGame`).
            let consoleName = isXbox ? nil : console.map { $0.name.isEmpty ? $0.host : $0.name }
            gameChoice.start(console: consoleName, xbox: isXbox) { [weak self] in
                guard let self else { return false }
                return self.settings.askGame && self.settings.sharePool
            }
        }

        // Mac uykudan uyanınca bağlantıları hemen yenile.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemWoke() }
        }
        // Mac'in adresi değişince (modem yeniden başladı, başka ağ) TV'ye yeni adres hemen bildirilir.
        addressWatcher?.stop()
        addressWatcher = services.makeAddressWatcher { [weak self] old, new in
            Task { @MainActor in self?.senderAddressChanged(old: old, new: new) }
        }
        keepAwake()
        server.pairing.setSession(true)
        isRunning = true
        if !settings.usageNoticeSeen { settings.usageNoticeSeen = true }
        if !demoMode {
            usageSession = (Date(), 0, 0, [])
            usage.record(.sessionStart(target: settings.output.rawValue,
                                       engine: onlineTranslationActive ? settings.onlineEngine.rawValue : "free",
                                       packs: settings.gamePacks, console: usageConsole))
        }
        applyHotkeys()
    }

    /// Konsola (PS5 ya da Xbox) bağlanan oturumu kurar; başlatmaz. "Çeviriyi başlat" ve "Yeniden bağlan" kullanır.
    private func makeConsoleSession(xbox: XboxConsole?) -> StreamControlling? {
        if let xbox { return services.makeXboxStream(auth: xboxAuth, console: xbox, playAudio: settings.xboxAudioOnDevice) }
        guard let console, let accountId else { return nil }
        return services.makeStream(console: console, accountId: accountId,
                                   loginPasscode: store.load(String.self, for: StoreKey.loginPasscode))
    }

    /// Oturumun olayları modele bağlanır. Yeniden bağlanırken kapatılan eski oturumun geç gelen olayı (Xbox'ta "durdu")
    /// yeni oturumun durumunu ezmez, eski oturumun karesi okunmaz (iPhone ile aynı).
    private func attach(_ session: StreamControlling) {
        session.onState = { [weak self, weak session] state in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.sessionStateChanged(state)
            }
        }
        session.onConsoleMoved = { [weak self] moved in Task { @MainActor in self?.consoleMoved(moved) } }
        session.onFrame = { [weak self, weak session] frame in
            // Karenin geldiği an: canlı altyazı alanındaki gecikme buradan TV'ye gidene kadar ölçülür.
            let capturedAt = SubtitleStabilizer.uptimeMs()
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                await self.handle(frame, capturedAt: capturedAt)
            }
        }
        session.useCadence(frameCadence)
    }

    /// "Yeniden bağlan" (ve oturumun bıraktığı bağlantıda uykudan uyanış): konsol oturumu kapatılıp yenisi açılır, TV
    /// bağlantısı yoklanır. Çeviri sürer (geçmiş, oyun seçimi, süre korunur). Eskiden oturum yeniden denemeyi bırakınca
    /// (görüntü gelmiyor, PS5'te Uzaktan Oynatma çöktü, Xbox denemeleri bitti) ya da uzun süre bağlanamayınca tek çare
    /// uygulamayı kapatıp açmaktı (iPhone, Android ve Windows ile aynı).
    func reconnect(reason: String = "kullanıcı") {
        guard isRunning, !isStarting, !demoMode, sessionIsConsole else { return }
        let xbox = isXbox && xboxSignedIn ? xboxConsole : nil
        guard isXbox ? xbox != nil : (console != nil && accountId != nil) else { return }
        RemotePlayLog.write("Yeniden bağlanılıyor (\(reason)); son durum: \(sessionState)")
        SubtitleLog.write("bağlantı yeniden kuruluyor (\(reason))")
        session?.stop()
        session = nil
        frameGate.reset()
        frameCadence.reset()
        skippedFrame = nil
        guard let session = makeConsoleSession(xbox: xbox) else { return }
        attach(session)
        self.session = session
        sessionState = .connecting
        session.start()
        reconnectOffer.reset(now: Date())
        if keeper == nil { startKeeper() } else { keeper?.reconnect() }
    }

    /// Ana ekrandaki "Yeniden bağlan" düğmesi görünsün mü (bkz. `ReconnectOffer`). Yalnız konsola doğrudan bağlanırken
    /// (pencereden okurken ya da deneme modunda yok).
    func offersReconnect(now: Date = Date()) -> Bool {
        guard isRunning, !demoMode, sessionIsConsole else { return false }
        return reconnectOffer.shows(gaveUp: session?.hasGivenUp ?? false, now: now)
    }

    /// Oturum yeniden denemeyi bıraktıysa uykudan uyanınca kendiliğinden yeniden bağlanılır mı. Kayıt ya da giriş şifresi
    /// sorununda hayır: aynı yere çıkar (yanlış şifre yeniden gönderilmez); kullanıcı düzeltip düğmeye basar (iPhone
    /// `PhoneModel.reconnectsOnReturn` ile aynı kural).
    static func reconnectsOnReturn(after state: SessionState) -> Bool {
        guard case .disconnected(let reason) = state else { return true }
        switch reason {
        // PS5 oturumu bilerek iki kez kapattı: kendiliğinden yeniden bağlanmak PS5'teki oyunu yine böler (GitHub #353).
        case .registrationInvalid, .loginPasscode, .loginPasscodeIncorrect, .stopped, .consoleClosedRepeatedly: return false
        default: return true
        }
    }

    /// Bu Mac'in ev ağı adresi değişti (modem yeniden başladı, Wi-Fi değişti): TV bekçisi yeni adresle yeniden kurulur;
    /// LG ve Samsung'da açma komutu, Android TV'de adres komutu yeni sunucu adresini TV'ye hemen götürür. Eskiden TV eski
    /// adrese bağlanmaya çalışıp ağı taramaya düşüyordu (iPhone, Windows ve Android ile aynı).
    func senderAddressChanged(old: [String], new: [String]) {
        guard isRunning else { return }
        TVInstallLog.write(SenderAddressWatcher.line(old: old, new: new))
        guard keeper != nil else { return }
        keeper?.stop()
        keeper = nil
        startKeeper(refreshApp: false)
        keeper?.reconnect()
    }

    /// Mac uykudan uyandı: bağlantılar hemen yenilenir. Oturum yeniden denemeyi bırakmışsa `reconnectNow` bir şey yapmaz;
    /// yeni oturum açılır (kayıt ya da giriş şifresi sorununda açılmaz, düğme görünür).
    func systemWoke() {
        guard isRunning else { return }
        if session?.hasGivenUp == true {
            if Self.reconnectsOnReturn(after: sessionState) {
                return reconnect(reason: "uykudan uyanış; oturum yeniden denemeyi bırakmıştı")
            }
        } else {
            session?.reconnectNow()
        }
        keeper?.reconnect()
    }

    /// Çeviri başlatılabilir mi: görüntü kaynağı hazır (PS5 kurulu ya da PS Remote Play penceresi seçili) ve altyazının
    /// gideceği bir yer var (TV eşleşmiş ya da bilgisayar ekranı seçili).
    var canStart: Bool {
        pictureSourceReady && settings.output.hasDestination(hasTV: hasTV)
    }

    /// TV uygulamasını başlatır ve açık tutar; TV kapalıysa açıldığında bağlanır. Altyazı TV'ye gitmiyorsa ya da TV
    /// yoksa bir şey yapmaz.
    /// TV durumunun yazısı: bağlı, yeniden bağlanılıyor ya da TV uygulaması bekleniyor.
    var tvStatusText: String {
        tvClients > 0 ? String(localized: "Connected")
            : tvNotResponding ? String(localized: "Not responding — searching again…")
            : tvReconnecting ? String(localized: "Reconnecting…") : String(localized: "Waiting for the TV app")
    }

    /// TV bağlantısı koptu (`stale`: TV alındı göndermez oldu; uygulama askıya alınmış ya da arka planda). Çeviri sürüyor ve
    /// altyazı TV'ye gidiyorsa TV durumu "Yeniden bağlanılıyor…" der. Alındı kesildiyse TV bekçisi yenilenir: TV'ye yeniden
    /// bağlanıp uygulamayı öne getirir (LG'de geri çekilmiş bekçi de işe döner). TV sayfası kendi tarafında yeniden bağlanır.
    private func tvLost(stale: Bool) {
        guard isRunning, settings.output.showsOnTV, !demoMode, tvClients == 0 else { return }
        tvReconnecting = true
        tvReconnectTask?.cancel()
        tvReconnectTask = Task { [weak self] in
            try? await Task.sleep(for: SubtitleServer.reconnectingFor)
            guard !Task.isCancelled else { return }
            self?.tvReconnecting = false
        }
        if stale {
            SubtitleLog.write("TV alındı göndermiyor: TV uygulaması yeniden açılıyor")
            if keeper == nil { startKeeper() } else { keeper?.reconnect() }
        }
    }

    private func endTVReconnecting() {
        tvReconnectTask?.cancel()
        tvReconnectTask = nil
        tvReconnecting = false
    }

    private func startKeeper(refreshApp: Bool = true) {
        guard keeper == nil, settings.output.showsOnTV, hasTV, let tv else { return }
        let server = self.server
        keeperGeneration += 1
        let generation = keeperGeneration
        let keeper = services.makeKeeper(tv: tv, key: store.load(String.self, for: StoreKey.tvKey), params: ["server": serverAddress(for: tv), "key": server.accessKey],
                                         appConnected: { server.connectedClients > 0 }, onMoved: { [weak self] moved in
            // Bekçinin yeniden bulucusu satırı kendisi yazdı (kimlikle mi, adla mı).
            Task { @MainActor in self?.tvMoved(to: moved, logged: true) }
        }, onKey: { [weak self] key in
            Task { @MainActor in self?.store.save(key, for: StoreKey.tvKey) }
        }, consolePort: { server.consolePort }, onOpenResult: { [weak self] problem in
            Task { @MainActor in
                // Yerine yenisi kurulan (eski adresteki) bekçinin geç gelen sonucu yok sayılır. Adres karşılaştırılmaz:
                // bekçinin kendisi TV'yi yeni adreste bulunca (onMoved) sonuçları yine gösterilmeli.
                guard let self, self.keeper != nil, self.keeperGeneration == generation else { return }
                self.openResult(problem, brand: tv.brand)
            }
        })
        keeper.start(interval: .seconds(5))
        self.keeper = keeper
        if refreshApp { Task { await refreshTVApp() } }
    }

    private func openResult(_ problem: TVOpenProblem?, brand: TVBrand) {
        guard isRunning, tvClients == 0 else { tvOpenProblem = nil; return }
        tvOpenProblem = TVOpenProblem.shown(problem, brand: brand, hasKey: !(store.load(String.self, for: StoreKey.tvKey) ?? "").isEmpty)
    }

    /// Ana ekrandaki "Otomatik açmayı dene": TV uygulaması hemen yeniden açılmaya çalışılır (bekçi beklemeden dener).
    func retryTVOpen() {
        tvOpenProblem = nil
        guard isRunning else { return }
        if let keeper { keeper.reconnect() } else { startKeeper() }
    }

    /// Çeviri sürerken bilgisayar ekranı da açık kalsın mı: görüntü bu Mac'teki Remote Play penceresinden okunuyorsa
    /// (ekran kapanınca ScreenCaptureKit kare vermez) ya da altyazı bu ekranda gösteriliyorsa. X'te bildirildi: kullanıcı
    /// TV'de oynayıp Mac'e dokunmayınca ekran kendi ayarıyla (prizdeyken çoğu zaman 10 dakika) kapanıyor, altyazı
    /// kesiliyordu. PS5'ten doğrudan okunup yalnız TV'ye gönderiliyorsa ekran kendi ayarıyla kapanabilir.
    var keepsDisplayOn: Bool {
        (!isXbox && settings.frameSource != .ps5) || readsXboxWindow || settings.output.showsOnComputer
    }

    /// Mac'in boşta uyuması (ve gerekiyorsa ekranın kapanması) engellenir; çeviri sürerken ayar değişince yeniden kurulur.
    private func keepAwake() {
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if keepsDisplayOn { options.insert(.idleDisplaySleepDisabled) }
        let previous = sleepActivity
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: options, reason: "Translating game subtitles")
        if let previous { ProcessInfo.processInfo.endActivity(previous) }
    }

    /// Altyazının yeri değişti: TV seçildiyse TV uygulaması açılır, kaldırıldıysa artık açık tutulmaz.
    private func outputChanged() {
        server.sendsToTV = settings.output.showsOnTV
        if !settings.output.showsOnComputer {
            // Yayın penceresi açıksa satırları kalır; yalnız saydam pencerenin yer ayarı biter.
            if streamWindowOpen { overlayAdjusting = false } else { overlayHide() }
        }
        guard isRunning else { return }
        keepAwake()
        if settings.output.showsOnTV {
            startKeeper()
        } else if let keeper {
            // Altyazı artık TV'ye gitmiyor: TV uygulaması kapanır, TV kendi girişine döner (#268).
            keeper.stop()
            self.keeper = nil
            server.exitTVApp()
        }
    }

    // MARK: - Kısayollar

    /// Kısayollar yalnız çeviri sürerken ve Ayarlar yeni tuş beklemiyorken tutulur (Windows: ShellWindow.ApplyHotkeys).
    func applyHotkeys() {
        hotkeys.bindings = HotkeyTable.resolve(settings.hotkeys)
        hotkeys.enabled = isRunning && !hotkeysPaused
    }

    /// Kısayola basıldı (Windows: ShellWindow.OnHotkey).
    func hotkeyPressed(_ action: HotkeyAction) {
        switch action {
        case .extraRegion1, .extraRegion2, .extraRegion3:
            if let number = action.areaNumber { Task { await translateExtraArea(number) } }
        case .pauseSubtitles: toggleSubtitles()
        case .snapshot: requestSnapshot()
        case .freeArea: FreeAreaPanel.open(self)
        case .screen: translateScreen()
        case .clickThrough: toggleClickThrough()
        }
    }

    /// Num 0: canlı altyazı çevirisini duraklatır ya da sürdürür. Alan çevirirken sürekli çeviri de TV'de görünüp
    /// karışmasın diye kullanılır; duraklarken ek alanlar da okunmaz, kutuları kalkar. TV'de kısa bir bildirim çıkar.
    /// Çeviri sürmüyorsa bir şey yapmaz (Windows: AppController.ToggleSubtitles).
    func toggleSubtitles() {
        guard isRunning else { return }
        subtitlesPaused.toggle()
        if subtitlesPaused {
            pipeline?.reset()
            regionWatcher?.reset()
            server.clear()
            server.clearRegions()
        }
        server.sendStyle(settings.style)
        server.sendSubtitle(String(localized: subtitlesPaused ? "Subtitle translation paused" : "Subtitle translation resumed"),
                            durationMs: 1800)
    }

    /// Num 8: Ayarlar'daki önizleme oyunun şu anki görüntüsünü yeniden alır (Windows: RequestSnapshot).
    func requestSnapshot() {
        framePreview.objectWillChange.send()
    }

    /// 1, 2 ya da 3. sıradaki ek alanı şimdi bir kez okuyup çevirir; sonuç alanın seçimindeki yere (TV, bu Mac ya da
    /// ikisi) gider. Çeviri sürmüyorsa, o sırada alan yoksa ya da önceki istek bitmediyse bir şey yapılmaz (Windows:
    /// AppController.TranslateExtraRegionAsync).
    @discardableResult
    func translateExtraArea(_ number: Int) async -> RegionTranslation.Outcome {
        guard let area = settings.extraArea(at: number) else { return .notConfigured }
        guard let frame = lastFrame else { return .notRunning }
        return await translateRegion(frame, area.region, toTV: area.target.toTV, toComputer: area.target.toComputer).outcome
    }

    /// Serbest alan (Num 5): verilen karedeki alanı bir kez okuyup çevirir. Sonuç ayardaki hedefe göre TV'ye de gider;
    /// bilgisayarda serbest alan penceresi kendisi gösterir (Windows: AppController.TranslateAreaAsync).
    func translateFreeArea(_ frame: CGImage, _ region: CropRegion) async -> (outcome: RegionTranslation.Outcome, result: RegionTranslation.Result?) {
        await translateRegion(frame, region, toTV: settings.freeAreaTarget.toTV, toComputer: false)
    }

    private func translateRegion(_ frame: CGImage, _ region: CropRegion, toTV: Bool,
                                 toComputer: Bool) async -> (outcome: RegionTranslation.Outcome, result: RegionTranslation.Result?) {
        guard isRunning else { return (.notRunning, nil) }
        // Tuşa üst üste basılınca ikinci bir okuma başlamaz.
        guard !regionBusy else { return (.busy, nil) }
        regionBusy = true
        defer { regionBusy = false }
        let reader = VisionReader(language: settings.sourceLanguage)
        let result: RegionTranslation.Result?
        do {
            result = try await RegionTranslation.translateOnce(frame, region: region, reader: reader, translator: makeTranslator())
        } catch let error as TranslatorError {
            translatorStatus = Self.translatorStatus(after: error)
            return (.translatorUnavailable, nil)
        } catch {
            return (.failed, nil)
        }
        guard let result else {
            let message = String(localized: "No text found in this area.")
            if toTV {
                server.sendStyle(settings.style)
                server.sendSubtitle(message, durationMs: 2500,
                                    box: TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom))
            }
            if toComputer { ResultPanel.show(message, milliseconds: 2500) }
            return (.noText, nil)
        }
        let milliseconds = RegionTranslation.displayMilliseconds(result.translation)
        if toTV {
            server.sendStyle(settings.style)
            server.sendSubtitle(result.translation, durationMs: milliseconds, box: result.box, paragraphs: result.structured)
        }
        lastSource = result.source
        lastTranslation = result.translation
        if toComputer { ResultPanel.show(result.translation, milliseconds: milliseconds) }
        return (.shown, result)
    }

    // MARK: - Ekranı çevir
    /// Süren "ekranı çevir" işi; yeniden basılınca iptal edilir.
    private var screenTask: Task<Void, Never>?
    /// TV'deki ekran çevirilerinin kalkacağı an; bu andan önce yeniden basınca ekran değişmediyse onlar kalkar.
    private var screenShownUntil = Date.distantPast
    /// Ekrandaki çevirilerin okunduğu karenin yazı izi (`ScreenTranslation.fingerprint`).
    private var screenFingerprint = ""
    /// Ekrandaki son çeviriler: telefon kartı izlenirken süresi bunlarla uzatılır.
    private var screenItems: [ScreenTranslation.Item] = []
    /// Telefon kartı ekrandayken sohbeti izleyen yoklama (`ScreenPhoneFollow`); kart yoksa nil.
    private var screenFollow: ScreenPhoneFollow?
    private var screenFollowTask: Task<Void, Never>?
    /// "Ekranı çevir" çevirilerinin hafızası (telefon mesajları sohbet başlığıyla); dil ya da motor değişince yenilenir.
    private var screenMemory = PhoneChatMemory()
    private var screenMemoryKey = ""

    /// Num 9 / ⌃⇧9: oyunun şu anki karesinin tamamını bir kez okur, her yazı grubunu ayrı çevirip TV'de kendi yerine koyar.
    /// Çeviriler hazırlandıkça TV'ye gider. Çeviri sürerken yeniden basmak onu durdurur. Çeviriler ekrandayken yeniden
    /// basınca kare yine okunur: ekran değiştiyse (telefonda başka sohbet) yenisi çevrilir, değişmediyse çeviriler kalkar.
    /// Karede GTA 6 telefonu varsa kart ekrandayken telefon izlenir (`followPhone`): sohbet değişince kart kendiliğinden
    /// yenilenir, telefon kapanınca kalkar. `refresh`: bu izlemenin yenilemesi (tuşa basılmadı).
    func translateScreen(refresh: Bool = false) {
        guard isRunning else { return }
        guard let frame = lastFrame else {
            // Çeviri sürüyor ama PS5'ten henüz görüntü gelmedi: tuş sessizce yok sayılmasın.
            if !refresh {
                server.sendSubtitle(String(localized: "Couldn't capture the screen: no picture from the PS5 yet."), durationMs: 4000)
            }
            return
        }
        if let task = screenTask {
            if refresh { return }
            task.cancel()
            screenTask = nil
            hideScreen()
            return
        }
        let wasShown = !refresh && Date() < screenShownUntil
        let previous = screenFingerprint
        server.sendStyle(settings.style)
        if !wasShown && !refresh { server.sendSubtitle(String(localized: "Translating the screen…"), durationMs: 2500) }
        let reader = VisionReader(language: settings.sourceLanguage)
        let translator = makeTranslator()
        let memoryKey = "\(settings.sourceLanguage)|\(settings.targetLanguage)|\(onlineTranslationActive)|\(settings.onlineEngine)"
        if memoryKey != screenMemoryKey {
            screenMemoryKey = memoryKey
            screenMemory = PhoneChatMemory()
        }
        let memory = screenMemory
        let server = self.server
        let phoneCard = settings.phoneMessagesPanel
        let panelScale = ScreenPhoneCard.textScale(fontSize: settings.style.fontSize)
        screenTask = Task { [weak self] in
            do {
                let read = try await ReadQueue.shared.run(priority: .background, detail: ReadQueue.detail("ekranı çevir", frame), droppable: false) {
                    try reader.readLines(frame, deep: false)
                }
                // Altyazı zaten kendi yerinde çevriliyor: ekran çevirisinde ikinci kez çizilmez (bkz. SubtitleEcho).
                let echo = SubtitleEcho.shared
                let reading = echo.filter(read, geometry: echo.hasRecent)
                let fingerprint = ScreenTranslation.fingerprint(reading)
                if wasShown {
                    guard !Task.isCancelled else { return }
                    if ScreenTranslation.isSameScreen(fingerprint, previous) {
                        self?.screenTask = nil
                        self?.hideScreen()
                        return
                    }
                    server.sendSubtitle(String(localized: "Translating the screen…"), durationMs: 2500)
                }
                self?.screenFingerprint = fingerprint
                // Yapay zekâda ekranın bütün yazıları tek istekte gider (bkz. AITranslationCore.translateAll). Yazının
                // içindeki kumanda simgeleri okunan kareden kesilip TV'de çevirinin içine konur (ButtonIcons). Çeviriler
                // özgün yazının stilinde kendi yerlerine çizilir; GTA 6 telefonunun yazıları yanında mesaj kartında.
                let items = try await ScreenTranslation.translate(reading, using: translator, frame: frame, memory: memory,
                                                                  phoneCard: phoneCard, panelScale: panelScale) { shown in
                    // İzlemenin yenilemesinde aynı çeviriler yeniden gönderilmez (TV'de kart yeniden çizilmesin).
                    guard !Task.isCancelled, !(refresh && self?.screenItems == shown) else { return }
                    let milliseconds = ScreenTranslation.displayMilliseconds(shown)
                    server.sendScreen(shown, durationMs: milliseconds)
                    self?.screenItems = shown
                    self?.screenShownUntil = Date().addingTimeInterval(Double(milliseconds) / 1000)
                }
                if !refresh { server.clear() }
                if items.isEmpty {
                    // Yeni karede yazı yok: önceki ekranın çevirileri de kalkar.
                    if wasShown || refresh { self?.hideScreen() }
                    if !refresh { server.sendSubtitle(String(localized: "No text found on the screen."), durationMs: 2500) }
                } else {
                    self?.followPhone(in: frame)
                }
            } catch is CancellationError {
                return
            } catch let error as TranslatorError {
                self?.translatorStatus = Self.translatorStatus(after: error)
                // İzlemenin yenilemesi başarısızsa eski kart kalır; aynı görüntü yeniden denenmez.
                if refresh { self?.followPhone(in: frame) } else { self?.showScreenFailure(error, translator: translator) }
            } catch {
                if refresh { self?.followPhone(in: frame) } else { self?.showScreenFailure(error, translator: translator) }
            }
            if !Task.isCancelled { self?.screenTask = nil }
        }
    }

    /// Ekran bu kareyle çevrildi: karede telefon varsa kart ekrandayken telefon izlenir (`ScreenPhoneFollow`). Sohbet
    /// değişip durulunca ekran yeniden çevrilir (hafızadaki mesajlar hemen gelir), telefon aynıyken kartın süresi uzar,
    /// telefon kapanınca kart kalkar. Önceden kart tek karenin çevirisiydi: başka sohbete geçince eskisi kalıyor, süresi
    /// dolunca kayboluyordu.
    private func followPhone(in frame: CGImage) {
        // Çeviriler balonların üstündeyken (kartsız) sohbet durulmadan değişmeyi sürdürürse kalkar (`ScreenPhoneFollow.hide`).
        let follow = screenFollow ?? ScreenPhoneFollow(hidesOnChange: !settings.phoneMessagesPanel)
        Task { [weak self] in
            guard let look = await Task.detached(priority: .utility, operation: { ScreenPhoneFollow.look(frame) }).value else {
                if self?.screenFollow === follow { self?.stopFollowing() }
                return
            }
            follow.settled(look.box, signature: look.signature)
            guard let self, self.screenFollow !== follow else { return }
            self.stopFollowing()
            self.screenFollow = follow
            self.screenFollowTask = Task { [weak self] in
                // İzleme bitince (kart kalktı, süresi doldu) sonraki kart yeni bir izlemeyle başlar.
                defer { if let self, self.screenFollow === follow { self.stopFollowing() } }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(ScreenPhoneFollow.interval) * 1_000_000)
                    guard let self, !Task.isCancelled, self.screenFollow === follow, self.isRunning,
                          Date() < self.screenShownUntil else { return }
                    guard self.screenTask == nil, let current = self.lastFrame else { continue }
                    let look = await Task.detached(priority: .utility, operation: { ScreenPhoneFollow.look(current) }).value
                    guard !Task.isCancelled, self.screenFollow === follow else { return }
                    switch follow.step(look?.box, signature: look?.signature) {
                    case .wait: continue
                    case .keep: self.keepScreen()
                    case .hide: self.hidePhoneBubbles()
                    case .refresh: self.translateScreen(refresh: true)
                    case .stop:
                        self.hideScreen()
                        return
                    }
                }
            }
        }
    }

    private func stopFollowing() {
        screenFollowTask?.cancel()
        screenFollowTask = nil
        screenFollow = nil
    }

    /// Telefonun ekranı değişti (sohbet kaydı/değişti): balonların üstündeki çeviriler hemen kalkar, telefon dışındaki
    /// çeviriler kalır; ekran durulunca yeniden çevrilir (hafızadaki mesajlar hemen gelir).
    private func hidePhoneBubbles() {
        let kept = screenItems.filter { !$0.bubble }
        guard kept.count != screenItems.count else { return }
        screenItems = kept
        if kept.isEmpty { server.clearScreen() } else { server.sendScreen(kept, durationMs: ScreenTranslation.displayMilliseconds(kept)) }
    }

    /// Telefon kartı izlenirken telefon aynı: çevirilerin süresi dolmak üzereyse yeniden gönderilip uzatılır.
    private func keepScreen() {
        guard !screenItems.isEmpty, screenShownUntil.timeIntervalSinceNow < 5 else { return }
        let milliseconds = ScreenTranslation.displayMilliseconds(screenItems)
        server.sendScreen(screenItems, durationMs: milliseconds)
        screenShownUntil = Date().addingTimeInterval(Double(milliseconds) / 1000)
    }

    /// Ekran çevrilemedi: nedeni TV'de (ve bilgisayardaki altyazıda) birkaç saniye görünür, sessizce kaybolmaz.
    private func showScreenFailure(_ error: Error, translator: TextTranslator) {
        guard !Task.isCancelled else { return }
        server.clear()
        let reason = Self.screenFailureReason(error, translator: translator, engine: settings.onlineEngine, server: settings.localAIServer)
        server.sendSubtitle(String(format: String(localized: "Couldn't translate the screen: %@"), reason), durationMs: 6000)
    }

    /// Ekran çevirisinin neden olmadığı: önce çevrimiçi motorun hatası, sonra ücretsiz çevirinin durumu.
    static func screenFailureReason(_ error: Error, translator: TextTranslator, engine: TranslationEngine,
                                    server: LocalAIServer?) -> String {
        if let online = translator as? AITranslator {
            if let failure = online.lastFailure { return TranslationCard.describe(failure, engine: engine, server: server) }
            if online.lastLineWasRateLimited {
                return String(format: String(localized: "%@ has reached its per-minute limit. Try again in a minute."), engine.displayName)
            }
        }
        switch error as? TranslatorError {
        case .needsDownload: return String(localized: "The free translation isn't downloaded yet.")
        case .unsupported: return String(localized: "The free translation doesn't work on this Mac.")
        case nil: return String(localized: "Something went wrong. Try again.")
        }
    }

    private func hideScreen() {
        stopFollowing()
        screenShownUntil = .distantPast
        screenFingerprint = ""
        screenItems = []
        server.clearScreen()
        server.clear()
    }

    /// `how`: TV ağda nasıl tanındı (kimlikle, adla); biliniyorsa günlük satırında yazılır.
    /// `logged`: satırı TV bekçisinin yeniden bulucusu (`TVLocator`, `AndroidTVLocator`) yazdı.
    func tvMoved(to moved: LGTV, how: TVIdentity.Match? = nil, logged: Bool = false) {
        if !logged, let old = tv?.host, old != moved.host {
            let line = how.map { TVIdentity.movedLine(from: old, to: moved.host, how: $0) } ?? TVReach.movedLine(from: old, to: moved.host)
            TVInstallLog.write(line)
            SubtitleLog.write(line)
        }
        if moved.brand == .samsung { SamsungAppKnowledge.shared.carry(from: tv?.host, to: moved.host) }
        tv = moved
        store.save(moved, for: StoreKey.tv)
        tvNotResponding = false
        tvUnreachableHost = nil
    }

    // MARK: - TV'nin adresi değişince

    /// Kayıtlı TV adresi hiç yanıt vermiyor (kart "Yanıt vermiyor — yeniden aranıyor…" der). beta.89: modem TV'ye yeni
    /// adres verince kart "TV uygulaması bekleniyor", kurulum "geliştirici modu kapalı" ve "Key Server kapalı" diyordu.
    @Published private(set) var tvNotResponding = false
    /// "TV'yi Eşleştir" ya da "Deneme Altyazısı Gönder" TV'ye ulaşamadı, TV ağda da bulunamadı: kartta açık hata,
    /// "TV'yi Yeniden Ara" ve "IP Adresi Gir". Önceden düğmeye basınca hiçbir şey olmuyordu.
    @Published private(set) var tvUnreachableHost: String?
    /// "IP Adresi Gir"e yazılan adreste TV tanınmadı.
    @Published private(set) var tvAddressRejected = false
    /// Ağ en son ne zaman arandı (kendiliğinden yeniden bulma en çok 30 sn'de bir arar; düğmeler beklemez).
    private var lastTVSearch: Date?
    static let tvSearchInterval: TimeInterval = 30

    /// Kayıtlı TV adresini yoklar; yanıt yoksa TV'yi ağda arar (`force` yoksa en çok 30 sn'de bir). Aynı TV bulunursa
    /// adres güncellenir ("TV'nin adresi değişmiş: eski → yeni") ve iş yeni adresle sürer. Windows, iPhone ve Android'de
    /// aynı adım (`TvReach`).
    func locateTV(force: Bool = false) async -> TVReach.Location {
        guard let saved = tv, !saved.host.isEmpty else { return .here }
        guard !(await services.tvResponds(host: saved.host, brand: saved.brand)) else {
            tvNotResponding = false
            return .here
        }
        // Yoklama sürerken TV değiştirildiyse (eşleşme kaldırıldı, başka TV seçildi) eski kayıt için aranmaz.
        guard tv == saved else { return .here }
        tvNotResponding = true
        if !force, let last = lastTVSearch, Date().timeIntervalSince(last) < Self.tvSearchInterval { return .silent }
        lastTVSearch = Date()
        TVInstallLog.write("Kayıtlı TV adresi \(saved.host) yanıt vermiyor; TV ağda yeniden aranıyor.")
        let found = await services.discoverTVs()
        guard tv == saved else { return .here }
        if let learned = TVLocator.learned(saved, among: found) {
            TVInstallLog.write(TVIdentity.learnedLine(learned))
            tvMoved(to: learned)
            return .here
        }
        guard let (moved, how) = TVLocator.locate(saved, among: found), moved.host != saved.host else {
            TVInstallLog.write("\(TVReach.notRespondingLine) (\(saved.host)); TV ağda bulunamadı.")
            return .silent
        }
        adoptMovedTV(moved, how: how)
        return .moved(moved)
    }

    /// Yeni adreste bulunan TV kaydedilir; çeviri sürüyorsa TV bekçisi yeni adresle yeniden kurulur.
    private func adoptMovedTV(_ moved: LGTV, how: TVIdentity.Match? = nil) {
        tvMoved(to: moved, how: how)
        keeper?.stop()
        keeper = nil
        if isRunning && settings.output.showsOnTV { startKeeper(refreshApp: false) }
    }

    /// Eşli TV kartı görünürken ~10 sn'de bir: TV uygulaması bağlı değilse adres yoklanır, gerekirse TV yeniden bulunur.
    func checkTVReachable() async {
        guard tv != nil, tvClients == 0 else {
            tvNotResponding = false
            return
        }
        _ = await locateTV()
    }

    /// "TV'yi Eşleştir" ve "Deneme Altyazısı Gönder"den önce: TV'ye ulaşılıyor mu (adresi değiştiyse yeni adresle evet).
    /// Ulaşılamazsa kart açık hatayı gösterir.
    func ensureTVReachable() async -> Bool {
        guard tv != nil else { return true }
        switch await locateTV(force: true) {
        case .here, .moved:
            tvUnreachableHost = nil
            return true
        case .silent:
            tvUnreachableHost = tv?.host
            return false
        }
    }

    /// Kartta "TV'yi Yeniden Ara".
    @discardableResult
    func searchTVAgain() async -> Bool { await ensureTVReachable() }

    /// Kartta "IP Adresi Gir": yazılan adresteki TV tanınırsa eşli TV o adrese taşınır (anahtarı korunur).
    @discardableResult
    func useTVAddress(_ text: String) async -> Bool {
        guard let host = ManualAddress.normalize(text), let found = await services.identifyTV(host: host) else {
            tvAddressRejected = true
            return false
        }
        tvAddressRejected = false
        guard let saved = tv else {
            tv = found
            store.save(found, for: StoreKey.tv)
            return true
        }
        let moved = found.brand == saved.brand ? saved.withHost(found.host).identified(from: found) : found
        if moved.brand != saved.brand { store.remove(StoreKey.tvAppVersion) }
        adoptMovedTV(moved)
        return true
    }

    /// Kartta "Eşleşmeyi Kaldır": eşli TV, TV izni/jetonu ve TV uygulaması kaydı silinir; altyazı TV'ye gidiyorsa bu
    /// Mac'in ekranına geçer. Önceden eşli TV hiçbir yerden kaldırılamıyordu (yalnız "Kurulumu sıfırla").
    func removeTVPairing() {
        if let tv { TVInstallLog.write("Eşleşme kaldırıldı: \(tv.name) (\(tv.host)).") }
        keeper?.stop()
        keeper = nil
        [StoreKey.tv, StoreKey.tvKey, StoreKey.tvAppVersion].forEach(store.remove)
        tv = nil
        tvKeySaved = false
        tvApp = .unknown
        tvAppOutdated = nil
        tvAppMissing = false
        tvNotResponding = false
        tvUnreachableHost = nil
        tvAddressRejected = false
        if settings.output.showsOnTV { settings.output = .computer }
    }

    /// Okuma hattını güncel dillerle (yeniden) kurar.
    private func makePipeline() {
        pipeline?.reset()
        // Eski hatta süren okuma beklenmez; yeni hat ilk karesini hemen alır.
        frameGate.reset()
        frameCadence.reset()
        skippedFrame = nil
        let scheduler = ReadScheduler(maxReuse: settings.fastSubtitleDetection
            ? ReadScheduler.fastMaxReuse : ReadScheduler.defaultMaxReuse)
        // Ekranda menü varken altyazı bekletilir; menü kapanınca bekletilen konuşma satırı gönderilir (#1240).
        let sender = MenuHeldSender(server, inMenu: { [weak self] in self?.screenTextDetector?.inMenu == true })
        menuSender = sender
        let pipeline = SubtitlePipeline(reader: VisionReader(language: settings.sourceLanguage),
                                        translator: makeTranslator(),
                                        server: sender, scheduler: scheduler)
        // Altyazı alanında konuşan adıyla satır okundu: ekranda menü yok (#1240).
        pipeline.onDialogue = { [weak self] in self?.screenTextDetector?.noteDialogue(now: SubtitleStabilizer.uptimeMs()) }
        // Altyazı alanında menünün geçmiş listesi okundu: menü sürer, listeden bekletilen satır gönderilmez.
        pipeline.onList = { [weak self, weak sender] in
            self?.screenTextDetector?.noteList(now: SubtitleStabilizer.uptimeMs())
            sender?.forget()
        }
        pipeline.echoPaused = { [weak self] in self?.screenTextDetector?.inMenu == true }
        pipeline.showSpeakerNames = settings.showSpeakerNames
        pipeline.applyWaits(from: settings)
        pipeline.echo = .shared
        // Görev satırı altyazıya girmez; otomatik ekran yazısı açıksa "auto-mission" ek alanı olarak kendi yerinde ve özgün
        // stilinde gösterilir (Windows ile aynı). Kapalıysa ayrıca gösterilmez.
        missionRegion = nil
        pipeline.onMissionChanged = { [weak self] region in self?.missionRegion = region }
        // "Tam ekran" alanda ekranın kenarındaki bildirim kartı (sağ altta mesaj önizlemesi, solda kayan bildirim) altyazıya
        // girmez; kendi yerinde ve özgün stilinde gösterilir, ekranın ortasına çizilmez (Windows ve Android ile aynı).
        noticeAreas = []
        pipeline.onNoticesChanged = { [weak self] areas in self?.noticeAreas = areas }
        pipeline.skipsTurkish = settings.targetLanguage == "tr"
        pipeline.onPair = { [weak self, weak pipeline] source, translation in
            self?.lastSource = source
            self?.lastTranslation = translation
            self?.subtitleOffTip.lineShown()
            self?.updateSubtitleOffTip()
            self?.addToHistory(source: source, translation: translation, origin: pipeline?.lastOrigin == "paket" ? .pack : .engine)
            if let self { self.gameChoice.noteLine(fromPack: pipeline?.lastOrigin == "paket", packs: self.packs) }
            self?.countUsageLine(fromPack: pipeline?.lastOrigin == "paket")
            if let box = pipeline?.lastBox { self?.lastSubtitleBox = box }
        }
        pipeline.onMetrics = { [weak self] metrics in self?.lastMetrics = metrics }
        // Dil paketi bu arada indirilmiş olabilir; her çeviri sonucu durumu günceller.
        pipeline.onTranslationResult = { [weak self] error in
            self?.translatorStatus = Self.translatorStatus(after: error)
        }
        pipeline.onReadResult = { [weak self] error in self?.noteRead(error) }
        pipeline.onSpeech = { [weak self] lines in self?.speak(lines) }
        pipeline.onLog = { SubtitleLog.write($0) }
        pipeline.onSceneTextDropped = { [weak self] reason in
            guard let self, self.gamePhoneHint.observe(reason: reason, readsPhone: self.settings.readsGamePhone,
                                                       game: self.gameChoice.game?.name) else { return }
            SubtitleLog.write("telefon ipucu: telefon çevirisi kapalı, telefon listesi altyazı yolunda atıldı (\(reason))")
            self.showsGamePhoneHint = true
        }
        // Telefon çevirisi kapalıyken de altyazı hattı GTA 6'da telefonu arar (yalnız bulmak için; okumaz, çevirmez): ekranındaki
        // satırlar altyazı sayılmaz, telefon art arda bulunursa oturumda bir kez ipucu (#1282; iPhone, Windows, Android ile aynı).
        pipeline.onPhoneLooked = { [weak self] found in
            guard let self, self.gamePhoneHint.observePhone(found: found, readsPhone: self.settings.readsGamePhone,
                                                            game: self.gameChoice.game?.name) else { return }
            SubtitleLog.write("telefon ipucu: telefon çevirisi kapalı, GTA 6 telefonu ekranda bulundu")
            self.showsGamePhoneHint = true
        }
        watchReadQueue()
        onlineIssue = nil
        pipeline.warmUp()
        self.pipeline = pipeline
        // Ek alan okuyucusu yeni dil ve motorla, ilk ek alan karesinde yeniden kurulur.
        regionWatcher?.reset()
        regionWatcher = nil
        screenTextDetector?.reset()
        configureGamePhone()
        connectPacks(to: pipeline)
        activeLanguages = (settings.sourceLanguage, settings.targetLanguage)
    }

    private func configureGamePhone() {
        regionWatcher?.closePhone()
        // Telefon GTA 6'da her zaman izlenir (telefon çevirisi kapalıyken de): açık telefonun ekranına otomatik ekran yazısı
        // kutusu ve kenar bildirimi çizilmez (Sinan Bey, beta.100 3420–3425). Telefonun okunması ayara bağlıdır.
        if Self.findsGamePhone(running: pipeline != nil, game: gameChoice.game?.name) {
            gamePhoneTracker = GamePhoneTracker()
        } else {
            gamePhoneTracker = nil
        }
        // Telefona yapışık çeviri: yalnız oyun görüntüsü bu Mac'teki bir pencereden okunurken (çeviri oyunun üstünde,
        // kendi yerinde çizilebilir). PS5'ten doğrudan okurken eski davranış (Sinan Bey kararı, 24 Kas: önce Mac).
        setPhoneAnchor(gamePhoneTracker != nil && settings.readsGamePhone && settings.drawScreenInPlace && capturedWindow != nil
                       ? PhoneAnchorSession() : nil)
        // Altyazı hattı telefonu yalnız GTA 6'da arar: başka oyunda ya da karanlık sahnede yanlış bulunan telefon alt şeritteki
        // altyazıyı silmesin. Telefon ayarı kapalıyken de arar (#1282): telefonun mesaj listesi altyazı olarak çevrilip
        // gidip geliyordu; bulunan telefonun satırları altyazı sayılmaz, ipucu gösterilir (iPhone, Windows, Android ile aynı).
        pipeline?.findsPhone = Self.findsGamePhone(running: pipeline != nil, game: gameChoice.game?.name)
    }

    /// Altyazı hattı telefonu arar mı: çeviri sürüyor ve oyun GTA 6 (telefon ayarından bağımsız, #1282).
    static func findsGamePhone(running: Bool, game: String?) -> Bool {
        guard running, let game else { return false }
        return GameName.key(game) == "gta 6"
    }

    /// Çapayı değiştirir: okuma, pencere yakalaması ve çizim yeni çapaya bağlanır; eskisi bırakılır.
    private func setPhoneAnchor(_ anchor: PhoneAnchorSession?) {
        phoneAnchor?.reset(reason: "telefon okuması yeniden kuruldu")
        phoneAnchor?.onChange = nil
        phoneAnchor = anchor
        regionWatcher?.phoneAnchor = anchor
        capturedWindow?.trackAnchor = anchor
        phoneAnchorFeed.reset()
        guard let anchor else { return }
        let server = self.server, feed = phoneAnchorFeed
        anchor.onLog = { SubtitleLog.write($0) }
        anchor.onChange = { [weak anchor] change in
            server.sendAnchor(change)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let anchor else { return }
                    feed.receive(change, from: anchor)
                }
            }
        }
        feed.current = anchor
    }

    /// Ek alanlar aynı dil, motor ve paketlerle okunur; ayrı bir okuyucu ve çevirmenle (altyazının sırasını beklemez).
    private func makeRegionWatcher(packLookup: ((String) -> PackMatch?)?) -> RegionWatcher {
        let watcher = RegionWatcher(reader: VisionReader(language: settings.sourceLanguage), translator: makeTranslator(), server: server)
        watcher.packLookup = packLookup
        watcher.subtitleEcho = .shared
        watcher.phoneAnchor = phoneAnchor
        // Ayarlar'daki ekran yazısı türleri (telefon, görev, yardım/eylemler, menüler, diğer).
        watcher.allows = { [weak self] kind in self?.settings.screenTextAllows(kind) ?? true }
        // "GTA 6 Telefon Mesajları: Yanda Panel / Balonların Üstünde"; panelin yazısı altyazı boyutuyla (Windows, Android ile aynı).
        watcher.phonePanel = { [weak self] in
            guard let self else { return PhonePanelOptions() }
            return PhonePanelOptions(enabled: self.settings.phoneMessagesPanel,
                                     textScale: ScreenPhoneCard.textScale(fontSize: self.settings.style.fontSize))
        }
        watcher.skipsTurkish = settings.targetLanguage == "tr"
        watcher.translatesUiCommands = settings.sourceLanguage == "en" && settings.targetLanguage == "tr"
        watcher.englishPhoneMessages = settings.sourceLanguage == "en"
        watcher.onLog = { SubtitleLog.write($0) }
        // Okunup yazısız ya da gürültülü çıkan otomatik alan dedektöre bildirilir (o görüntüde yeniden önerilmez).
        watcher.onAutoRejected = { [weak self] id in self?.screenTextDetector?.reject(id) }
        // Menüde okunan tuş ipucu ya da görev/HUD yazısı menü bileşeni sayılmaz (#1240).
        watcher.onAutoHud = { [weak self] id in self?.screenTextDetector?.markHud(id) }
        return watcher
    }

    private func refreshTranslatorStatus() async {
        if onlineTranslationActive {
            translatorStatus = .ready
            return
        }
        translatorStatus = await Translator.status(source: settings.sourceLanguage, target: settings.targetLanguage)
    }

    // MARK: - Çevrimiçi çeviri (DeepL ve yapay zekâ)

    /// Deneme modunda seçili motor çeviremezse (dil paketi yok, ağ ya da anahtar yok) örnek satırların hazır çevirisi.
    private func makeTranslator() -> TextTranslator {
        let translator = makeEngineTranslator()
        return demoMode ? DemoTranslator(base: translator) : translator
    }

    private func makeEngineTranslator() -> TextTranslator {
        let (source, target) = (settings.sourceLanguage, settings.targetLanguage)
        // Önceki oturumların çevirileri motor ve dil çifti başına diskte durur; tekrar eden satır hemen gelir.
        let local = Translator(source: source, target: target,
                               cache: Self.translationCache(engine: Translator.engineID, source: source, target: target))
        let engine = settings.onlineEngine
        guard onlineTranslationActive, let storeKey = engine.storeKey else { return local }
        let online: TextTranslator & OnlineTranslating
        // Oynanan oyunun adı modele bağlam olarak gider, önbellek de oyuna göre ayrılır. Ad kararlı oyundur (`GameSense`:
        // PS5'in bildirdiği, kullanıcının seçtiği ya da son 20 satırın 5'i aynı paketten gelince o paketin oyunu); son
        // eşleşen paket değil, yoksa tek bir ortak satır adı başka oyuna geçirirdi (#27). Oyun bilinmiyorsa ad gitmez.
        let sense = gameChoice.sense
        let game: @Sendable () -> String? = { sense.current?.name }
        if engine == .local, let server = settings.localAIServer {
            // Yerel modelin anahtarı isteğe bağlıdır; önbellekte sunucu ve model ayrı tutulur.
            let key = store.load(String.self, for: storeKey) ?? ""
            online = AITranslator(provider: .local, key: key, model: server.model, server: server, fallback: local,
                                  cache: Self.translationCache(engine: server.engineID, source: source, target: target), game: game,
                                  instruction: settings.aiInstruction)
        } else if let key = store.load(String.self, for: storeKey), let provider = engine.aiProvider {
            let model = provider.model(settings.model(for: provider)).id
            online = AITranslator(provider: provider, key: key, model: model, fallback: local,
                                  cache: Self.translationCache(engine: provider.engineID(model: model), source: source, target: target),
                                  game: game, instruction: settings.aiInstruction,
                                  paidTier: provider == .gemini && settings.geminiPaidTier)
        } else if let key = store.load(String.self, for: storeKey) {
            online = DeepLTranslator(key: key, fallback: local,
                                     cache: Self.translationCache(engine: DeepLTranslator.engineID, source: source, target: target))
        } else {
            return local
        }
        // Hizmet çeviremeyince ana ekranda uyarı çıkar; düzelince kalkar.
        online.onFailureChanged = { [weak self] state in
            Task { @MainActor in self?.onlineIssue = state }
        }
        return online
    }

    /// ~/Library/Application Support/CouchSubs/Translations içindeki kalıcı çeviri önbelleği.
    private static func translationCache(engine: String, source: String, target: String) -> TranslationCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent(AppIdentity.name, isDirectory: true)
            .appendingPathComponent("Translations", isDirectory: true)
        return TranslationCache.shared(in: directory, engine: engine, source: source, target: target)
    }

    /// Çevrimiçi çeviri yalnız İngilizce→Türkçe için ve seçili motor hazırsa açılır.
    var onlineTranslationActive: Bool {
        settings.onlineTranslation && settings.sourceLanguage == "en" && settings.targetLanguage == "tr" && isReady(settings.onlineEngine)
    }

    /// Motor kullanılabilir mi: bulut motorlarında anahtar kayıtlıdır; yerel modelde anahtar gerekmez, adres ve model adı
    /// geçerli olmalıdır. Sunucu kapalıysa satırlar ücretsiz çeviriyle gelir ve ana ekranda uyarı çıkar.
    func isReady(_ engine: TranslationEngine) -> Bool {
        engine == .local ? settings.localAIServer != nil : hasKey(engine)
    }

    /// Anahtarı kayıtlı motorlar (anahtarların kendisi arayüze hiç dönmez).
    @Published private var savedKeys: Set<TranslationEngine> = []

    func hasKey(_ engine: TranslationEngine) -> Bool { savedKeys.contains(engine) }

    /// Kayıtlı bir DeepL anahtarı var mı.
    var hasDeepLKey: Bool { hasKey(.deepL) }

    /// Anahtar denenir; geçerliyse (kotası bitmiş ya da DeepL o an çok sık istek aldığını bildirmiş olsa da) Anahtarlık'a
    /// yazılır ve DeepL seçilir. Görünmez karakterler silinir; sonuç nedeniyle günlüğe yazılır (anahtarın kendisi yazılmaz).
    func setDeepLKey(_ key: String) async -> OnlineKeyCheck {
        let key = DeepLKey.clean(key)
        SubtitleLog.write("API anahtarı testi başladı: deepl")
        let check = await services.checkOnlineKey(key)
        if check.state != .valid { SubtitleLog.write("API anahtarı testi sonucu: deepl \(check.logDescription)") }
        if check.state == .valid || check.state == .quotaExceeded || check.state == .busy {
            guard saveKey(key, for: .deepL) else { return OnlineKeyCheck(state: .keychainWriteFailed) }
        }
        return check
    }

    /// Kayıtlı anahtarın bu ayki kullanımı.
    func deepLUsage() async -> OnlineKeyCheck {
        guard let key = store.load(String.self, for: StoreKey.deepLKey) else { return OnlineKeyCheck(state: .invalid) }
        return await services.checkOnlineKey(key)
    }

    func removeDeepLKey() { removeKey(.deepL) }

    /// Yapay zekâ anahtarı örnek bir satırla denenir. Anahtar kabul edildiyse (bakiye bitmiş ya da model adı yanlış olsa
    /// da) Anahtarlık'a yazılır ve bu motor seçilir.
    func setAIKey(_ key: String, for provider: AIProvider) async -> Result<String, AIFailure> {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SubtitleLog.write("API anahtarı testi başladı: \(provider.rawValue)")
        let result = await services.testAIKey(provider: provider, key: key, model: settings.model(for: provider))
        if case .failure(let error) = result {
            SubtitleLog.write("API anahtarı testi sonucu: \(provider.rawValue) \(error)")
        }
        switch result {
        case .success, .failure(.quotaExceeded), .failure(.modelRejected), .failure(.busy):
            guard saveKey(key, for: TranslationEngine(provider)) else { return .failure(.keychainWriteFailed) }
        case .failure: break
        }
        return result
    }

    /// Kayıtlı anahtar ve modelle örnek satırı çevirir (ayarlardaki "Dene").
    func testAIKey(for provider: AIProvider) async -> Result<String, AIFailure> {
        guard let storeKey = TranslationEngine(provider).storeKey, let key = store.load(String.self, for: storeKey) else {
            return .failure(.invalidKey)
        }
        return await services.testAIKey(provider: provider, key: key, model: settings.model(for: provider))
    }

    /// Ayarlardaki "Bağlantıyı dene": yerel model sunucusuna örnek satırı gönderir. `key` yazıldıysa o, yoksa kayıtlı
    /// anahtar kullanılır; yazılan anahtar sunucu kabul ettiyse Anahtarlık'a yazılır. Adres geçersizse sunucuya
    /// ulaşılamadı sayılır.
    func testLocalAI(key typed: String = "") async -> Result<String, AIFailure> {
        guard let server = settings.localAIServer else { return .failure(.unreachable) }
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? store.load(String.self, for: StoreKey.localAIKey) ?? "" : typed
        let result = await services.testLocalAI(server: server, key: key)
        if !typed.isEmpty {
            switch result {
            case .success, .failure(.quotaExceeded), .failure(.modelRejected), .failure(.busy):
                guard saveKey(typed, for: .local) else { return .failure(.keychainWriteFailed) }
            case .failure: break
            }
        }
        return result
    }

    func removeKey(_ engine: TranslationEngine) {
        guard let storeKey = engine.storeKey else { return }
        store.remove(storeKey)
        savedKeys.remove(engine)
        if engine == .local {
            // Yerel modelin anahtarı isteğe bağlıdır: anahtarsız çeviri sürer, hat anahtarsız yeniden kurulur.
            if settings.translationEngine == .local, isRunning { makePipeline() }
            return
        }
        if settings.translationEngine == engine {
            settings.onlineTranslation = false
        } else {
            Task { await refreshTranslatorStatus() }
        }
    }

    private func saveKey(_ key: String, for engine: TranslationEngine) -> Bool {
        guard let storeKey = engine.storeKey else { return false }
        store.save(key, for: storeKey)
        guard store.load(String.self, for: storeKey) == key else {
            SubtitleLog.write("API anahtarı Anahtar Zinciri'ne kaydedilemedi: \(engine.rawValue)")
            return false
        }
        savedKeys.insert(engine)
        if settings.translationEngine == engine {
            // Motor zaten seçiliydi, anahtar yeni geldi: hat yeni anahtarla kurulsun.
            if isRunning { makePipeline() }
            Task { await refreshTranslatorStatus() }
        } else {
            settings.translationEngine = engine
        }
        return true
    }

    // MARK: - PS5 giriş şifresi

    /// 4 haneyi Anahtarlık'a kaydeder; geçersizse kaydetmez ve false döner. Sonraki bağlantıda kullanılır.
    @discardableResult
    func setLoginPasscode(_ value: String) -> Bool {
        guard let pin = LoginPasscode.normalized(value) else { return false }
        store.save(pin, for: StoreKey.loginPasscode)
        hasLoginPasscode = true
        return true
    }

    func removeLoginPasscode() {
        store.remove(StoreKey.loginPasscode)
        hasLoginPasscode = false
    }

    /// Çeviriyi durdurur. `closingTVApp`: kullanıcı durdurdu, TV uygulaması da kapanır (#268); ayar değişikliği gibi
    /// iç yeniden başlatmalarda `false` verilir, TV açık kalır ve ardından gelen `start()` aynı bağlantıyı kullanır.
    func stop(closingTVApp: Bool = true) {
        if let usageSession {
            usage.record(.sessionStop(seconds: Int(Date().timeIntervalSince(usageSession.started)), lines: usageSession.lines,
                                      packLines: usageSession.packLines))
            self.usageSession = nil
        }
        session?.stop()
        session = nil
        updateGameProbe(connected: false)
        gameChoice.stop()
        gameAreas.stop()
        if let keeper {
            keeper.stop()
            self.keeper = nil
            if closingTVApp { server.exitTVApp() }
        }
        tvOpenProblem = nil
        endTVReconnecting()
        pipeline?.reset()
        if pipeline != nil { SubtitleLog.write("oturum bitti") }
        menuSender = nil
        pipeline = nil
        regionWatcher?.reset()
        regionWatcher = nil
        screenTextDetector?.reset()
        gamePhoneTracker = nil
        setPhoneAnchor(nil)
        // Yeni "Başlat" eski oturumdan kalan (belki takılmış) okumayı beklemeden temiz başlar.
        frameGate.reset()
        frameCadence.reset()
        skippedFrame = nil
        activeLanguages = nil
        subtitlesPaused = false
        screenTask?.cancel()
        screenTask = nil
        if Date() < screenShownUntil { server.clearScreen() }
        screenShownUntil = .distantPast
        if let dubber {
            self.dubber = nil
            Task { await dubber.shutdown() }
        }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        addressWatcher?.stop()
        addressWatcher = nil
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
        server.pairing.setSession(false)
        tvPairingRequest = nil
        isRunning = false
        onlineIssue = nil
        sessionState = .disconnected(.stopped)
        reconnectOffer.reset()
        sessionIsConsole = false
        subtitleOffTip.reset()
        updateSubtitleOffTip()
        applyHotkeys()
        FreeAreaPanel.close()
        overlayHide()
    }

    /// Gösterilen satır kullanım verisinin oturum sayımına girer; paketten geldiyse paketi oturumda bir kez bildirilir.
    private func countUsageLine(fromPack: Bool) {
        guard var current = usageSession else { return }
        current.lines += 1
        if fromPack {
            current.packLines += 1
            if let pack = packs.searchScope, current.packs.insert(pack).inserted { usage.record(.packHit(pack)) }
        }
        usageSession = current
    }

    /// Kullanım verisindeki konsol türü.
    var usageConsole: String { isXbox ? "xbox" : "ps5" }

    /// İlk açılıştaki kullanım verisi notu: ölçüm bu derlemede varsa ve not daha önce görülmediyse.
    var showsUsageNotice: Bool { usage.isConfigured && !settings.usageNoticeSeen }

    private func sessionStateChanged(_ state: SessionState) {
        // Altyazı günlüğünde durumun türü ve kopmanın nedeni (adres ve ayrıntı remoteplay.log'da). Neden eskiden
        // yazılmıyordu; yalnız altyazi.log gönderen kullanıcının kopmaları teşhis edilemiyordu (GitHub #456).
        if state != sessionState {
            switch state {
            case .connecting: SubtitleLog.write("\(isXbox ? "Xbox" : "PS5"): bağlanıyor")
            case .streaming: SubtitleLog.write("\(isXbox ? "Xbox" : "PS5"): bağlandı")
            case .disconnected(let reason): SubtitleLog.write("\(isXbox ? "Xbox" : "PS5"): bağlantı yok (\(reason.logName))")
            }
            // PS5'in kendi tarafındaki çökme ayrıca yazılır: kullanıcının günlüğünde nedeni görünsün (GitHub #519).
            if state == .disconnected(.consoleRemotePlayCrashed) {
                SubtitleLog.write("PS5: Uzaktan Oynatma PS5'te çöktü (Remote Play on Console has crashed); PS5 tamamen kapatılıp açılmalı")
            }
        }
        sessionState = state
        reconnectOffer.update(live: state == .streaming)
        subtitleOffTip.connectionChanged(streaming: state == .streaming)
        updateSubtitleOffTip()
        updateGameProbe(connected: state == .streaming)
        // Bağlantı koptuysa TV'de eski altyazı kalmasın.
        if case .disconnected = state {
            pipeline?.reset()
            regionWatcher?.reset()
            gamePhoneTracker?.reset()
            screenTextDetector?.reset()
            server.clear()
            dubber?.stop()
        }
    }

    /// Okuma sırasının olayları günlüğe yazılır; takılınca okumalar yedek okuyucuya (uygulamanın `--ocr-helper` ile
    /// açılan ikinci süreci) geçer. Süreç boyunca bir kez kurulur.
    private func watchReadQueue() {
        let queue = ReadQueue.shared
        if queue.rescuer == nil, let executable = Bundle.main.executableURL {
            let rescuer = OcrHelperRescuer(executable: executable)
            rescuer.onLog = { SubtitleLog.write($0) }
            queue.rescuer = rescuer
        }
        queue.onEvent = { [weak self] event in
            switch event {
            case .stalled(let stall, let rescued):
                SubtitleLog.write("okuma takıldı: \(stall.logText); \(rescued ? "okumalar yedek okuyucuya geçti" : "yedek okuyucu yok, takılan okuma bekleniyor")")
            case .recovered(let ms):
                SubtitleLog.write("okuma düzeldi: takılan okuma \(ms) ms sonra bitti; asıl okuyucuya dönüldü")
            case .rescueFailed(let stall, let failures):
                SubtitleLog.write("yedek okuyucu da takıldı (\(failures). kez): \(stall.logText); yeniden kuruluyor")
            case .degraded(let stalls):
                SubtitleLog.write("okuma \(stalls) kez takıldı; \(queue.fastLevelHoldMs / 1000) sn hızlı düzeyde okunacak (Neural Engine yolu bırakıldı), sonra isabetli düzey yeniden denenecek")
            case .restored(let ms):
                SubtitleLog.write("hızlı düzeyin süresi doldu (\(ms / 1000) sn); okuma yeniden isabetli düzeyde")
            case .backgroundYielded(let stall, let dropped, let rescued):
                SubtitleLog.write("altyazı arka plan okumasını bekledi (takılma sayılmadı): \(stall.logText); sıradaki \(dropped) arka plan okuması düşürüldü; \(rescued ? "altyazı bu tur yedekten okunuyor" : "altyazı sırada öne geçti")")
            case .abandonedFinished(let still):
                SubtitleLog.write("bırakılan takılı okuma sonunda bitti (bitmeyen bırakılmış okuma: \(still))")
            case .abandoned(let ms, let rescued, let cancelled):
                SubtitleLog.write("takılan okuma bırakıldı, okuyucu yeniden kuruldu: okuma \(ms) ms'dir dönmüyordu\(cancelled ? " (istek iptal edildi)" : ""); \(rescued ? "yeni okuyucu sınanıyor, altyazı yedek okuyucudan sürüyor" : "okuma yeni okuyucuda sürüyor")")
            case .recoveredAfterRebuild(let reads):
                SubtitleLog.write("okuma düzeldi (yeniden kurulumdan sonra): yeni okuyucu art arda \(reads) okumayı süresinde bitirdi; asıl okuyucuya dönüldü, yedek kapatıldı")
            case .parked(let still, _):
                SubtitleLog.write("yeni okuyucu da tek okuma bitiremeden takıldı: macOS yazı tanıma kilidi bırakılan okumada (bitmeyen: \(still)); yeniden kurma durdu, okumalar yedek okuyucuda (ayrı süreç) sürüyor; kilit serbest kalınca asıl okuyucuya dönülecek")
            }
            Task { @MainActor in self?.readQueueChanged() }
        }
    }

    private func readQueueChanged() {
        let rescued = ReadQueue.shared.showsRescueNotice
        if readingRescued != rescued { readingRescued = rescued }
        if ReadQueue.shared.stalledMs == nil, readingStuck { readingStuck = false }
    }

    /// Uygulamayı kapatıp yeniden açar (okuma düzelmediğinde tek tuşla).
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func noteRead(_ error: Error?) {
        let rescued = ReadQueue.shared.showsRescueNotice
        if readingRescued != rescued { readingRescued = rescued }
        // Yedek okuyucunun kapanması da takılmadır; disk uyarısına sayılmaz.
        if case ReadQueueError.stuck? = error { if !readingStuck { readingStuck = true }; return }
        if error is OcrHelper.Failure { if !readingStuck { readingStuck = true }; return }
        if readingStuck { readingStuck = false }
        guard error != nil else {
            readFailures = 0
            // Her başarılı okumada yazılmasın: yayınlanan özellik her atamada bütün ekranları yeniden çizdirir.
            if readingFailedFreeGB != nil { readingFailedFreeGB = nil }
            return
        }
        readFailures += 1
        if readFailures >= 10, readingFailedFreeGB == nil { readingFailedFreeGB = Self.freeDiskGB() }
    }

    static func freeDiskGB() -> Double {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let bytes = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return Double(bytes) / 1_000_000_000
    }

    static func translatorStatus(after error: TranslatorError?) -> TranslatorStatus {
        switch error {
        case nil: .ready
        case .needsDownload: .needsDownload
        case .unsupported: .unsupported
        }
    }

    /// Çeviri başlamamışken bağlı olmamak bir sorun değildir; nokta gri kalır.
    static func ps5Tone(_ state: SessionState, running: Bool) -> StatusTone {
        state == .streaming ? .good : running ? .warning : .idle
    }

    static func tvTone(clients: Int, running: Bool) -> StatusTone {
        clients > 0 ? .good : running ? .warning : .idle
    }

    /// Ana ekrandaki PS5 durumu (eşleşmiş PS5'in adıyla).
    var ps5StatusText: String {
        if demoMode { return String(localized: "Sample pictures") }
        if readsCaptureWindow {
            return Self.captureWindowStatusText(sessionState, running: isRunning, target: settings.captureWindow)
        }
        if isXbox { return Self.xboxStatusText(sessionState, running: isRunning, console: xboxConsole, signedIn: xboxSignedIn) }
        if settings.frameSource == .remotePlayWindow {
            return Self.windowStatusText(sessionState, running: isRunning, installed: !remotePlayMissing)
        }
        return Self.statusText(sessionState, running: isRunning, pairedName: console.map { $0.name.isEmpty ? "PS5" : $0.name },
                               connectingHint: connectingHint)
    }

    /// Bağlanma 30 sn'yi geçerse nedeni saniyede bir oturumun son adımından hesaplanır (iPhone, Windows, Android aynı).
    private func connectingChanged(from old: SessionState) {
        guard sessionState == .connecting else {
            connectingWatch?.cancel()
            connectingWatch = nil
            if connectingHint != nil { connectingHint = nil }
            return
        }
        guard old != .connecting || connectingWatch == nil else { return }
        let since = Date()
        connectingWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let step = self.session?.connectStep.flatMap { ConnectingHint.Step(rawValue: $0.rawValue) }
                let hint = ConnectingHint.text(seconds: Date().timeIntervalSince(since), step: step)
                if hint != self.connectingHint { self.connectingHint = hint }
            }
        }
    }

    /// Görüntü bu Mac'teki Remote Play penceresinden okunurken durumun metni.
    static func windowStatusText(_ state: SessionState, running: Bool, installed: Bool = true) -> String {
        if case .streaming = state { return String(localized: "Reading the Remote Play window") }
        if !installed { return String(localized: "The Remote Play app isn't installed on this Mac. Download it in Settings › Picture source.") }
        switch state {
        case .streaming: return String(localized: "Reading the Remote Play window")
        case .connecting: return String(localized: "Waiting for the Remote Play window. Open PS Remote Play or chiaki-ng on this Mac.")
        case .disconnected(let reason):
            guard running else { return String(localized: "Reads the Remote Play window on this Mac when you start translating.") }
            if case .other(let detail) = reason, !detail.isEmpty { return detail }
            return String(localized: "Waiting for the Remote Play window. Open PS Remote Play or chiaki-ng on this Mac.")
        }
    }

    /// PS5 durumunun kullanıcıya gösterilecek metni. `pairedName`: eşleşmiş PS5'in adı; çeviri başlamamışken eşleşmiş
    /// PS5 için "Bağlı değil" yerine "eşleşti, başlatınca bağlanır" denir (eskiden eşleştirme başarılı olsa da ana ekran
    /// "Bağlı değil" diyordu).
    static func statusText(_ state: SessionState, running: Bool, pairedName: String? = nil, connectingHint: String? = nil) -> String {
        switch state {
        case .streaming: return String(localized: "Connected")
        case .connecting:
            guard let connectingHint else { return String(localized: "Connecting…") }
            return String(localized: "Connecting…") + "\n" + connectingHint
        case .disconnected(let reason):
            guard running else {
                guard let pairedName else { return String(localized: "Not connected") }
                return String(format: String(localized: "Paired with %@. Connects when you start translating."), pairedName)
            }
            return disconnectText(reason)
        }
    }

    private static func disconnectText(_ reason: DisconnectReason) -> String {
        switch reason {
        case .consoleAsleep: return String(localized: "Turn on your PS5")
        case .inUse: return String(localized: "Remote Play is in use on another device")
        case .refused: return String(localized: "The PS5 did not accept the connection yet. It may still be starting up, or its network address may have changed. Reconnecting and searching for the PS5… If this keeps happening, make sure the PS5 is on and on the same network.")
        case .loginPasscode:
            return String(localized: "The PS5 asks for this account's login passcode. Enter it in Settings, or turn off this account's login passcode on the PS5.")
        // Yanlış şifre bir kez gönderilir; PS5 yeniden isterse oturum kapanır (döngü yok).
        case .loginPasscodeIncorrect:
            return String(localized: "The PS5 didn't accept the login passcode in Settings. Correct it, or turn off this account's login passcode on the PS5.")
        // Eskiden "Yeniden bağlanılıyor… (Unknown Session Request Error)" diye sonsuza kadar deneniyordu.
        case .registrationInvalid: return String(localized: "The PS5 didn't accept this pairing. Pair the PS5 again with the second account in Settings.")
        // Eskiden görüntü hiç gelmeyince sonsuza kadar "Yeniden bağlanılıyor… (no picture from the PS5)".
        case .noPicture: return String(localized: "No picture from the PS5. Is Remote Play turned off, or is the PS5 in rest mode? Check, then start again.")
        // Eskiden ağ hatası, bulunamayan PS5 ve diğer nedenler hep yalnız "Yeniden bağlanılıyor…" idi.
        case .notFound(let host):
            return String(format: String(localized: "PS5 not found at %@. Searching the network for it. Make sure it is on and on the same network; if its address changed, use Enter IP Address in Settings > Console. Reconnecting…"), host)
        // Kablosuz ağda akış sık kopuyordu (GitHub #388, #401): yeniden bağlanılır, kalıcı çözüm kablodur.
        case .network:
            return String(localized: "Lost the connection to the PS5. Reconnecting… If this keeps happening, connect the PS5 to the router with a cable.")
        // 0x80108b12: PS5'te Uzaktan Oynatma kapalı (GitHub #9). Ayar açılınca yeniden denemede bağlanılır.
        case .rejected(.some(DisconnectReason.remotePlayDisabled)):
            return String(format: String(localized: "Remote Play is turned off on the PS5 (code %@). On the PS5, go to Settings › System › Remote Play and turn on Enable Remote Play."),
                          String(format: "0x%08x", DisconnectReason.remotePlayDisabled))
        // Eskiden "Yeniden bağlanılıyor… (Unknown Session Request Error)" görünüyordu (GitHub #33, #202).
        case .rejected(let code?):
            return String(format: String(localized: "The PS5 rejected the connection (code %@). Another Remote Play app (PS Remote Play) may be open, or the PS5 may be in another session. Close PS Remote Play, restart the PS5, then try again."), String(format: "0x%08x", code))
        case .rejected(nil): return String(localized: "The PS5 didn't start the session. Another Remote Play app (PS Remote Play) may be open, or the PS5 may be in another session. Close PS Remote Play, restart the PS5, then try again.")
        // Eskiden İngilizce "Remote Play on Console has crashed" ile sonsuza kadar "Yeniden bağlanılıyor…" (GitHub #519).
        // PS5 akışı kendisi kapattı (ör. oyun sırasında PS5'te kullanıcı değişti): eskiden "kabloyla bağlayın" deniyordu.
        case .consoleClosed: return String(localized: "The PS5 ended Remote Play. This usually happens when the user is switched on the PS5 during the game. Reconnecting…")
        // PS5 yeniden bağlanmadan sonra da kapattı: durulur (eskiden sınırsız deneniyor, oyun bölünüyordu; GitHub #353).
        case .consoleClosedRepeatedly: return String(localized: "The PS5 ended Remote Play. While playing, choose your own main account on the PS5; don't play with the second account CouchSubs uses.")
        case .reconnectGaveUp: return String(localized: "The connection to the PS5 kept dropping, so reconnecting stopped. Make sure the PS5 is on and on the same network, then press Reconnect.")
        case .consoleRemotePlayCrashed: return String(localized: "Remote Play on the PS5 has crashed. Turn the PS5 off completely (not rest mode) and back on, then connect again.")
        case .other(let detail) where !detail.isEmpty: return String(format: String(localized: "Reconnecting… (%@)"), detail)
        case .other, .stopped: return String(localized: "Reconnecting…")
        }
    }

    /// Ayarlar'da "IP Adresi Gir": PS5'in yeni adresi elle yazılır (modem adresi değiştirip PS5 ağda bulunamadığında).
    /// Geçersiz adres ya da kayıtlı PS5 yoksa false. Kayıt (anahtar) korunur; bağlıysa yeni adresle yeniden bağlanılır.
    @discardableResult
    func enterConsoleAddress(_ text: String) -> Bool {
        guard let host = ManualAddress.normalize(text), let current = console else { return false }
        if host != current.host {
            RemotePlayLog.write("PS5 adresi elle girildi: \(current.host) -> \(host)")
            consoleMoved(current.withHost(host))
        }
        reconnect(reason: "PS5 adresi elle girildi")
        return true
    }

    /// PS5'in adresi değişti: sonraki açılışlar yeni adresle başlasın.
    private func consoleMoved(_ moved: RegisteredConsole) {
        guard console != nil else { return }
        console = moved
        store.save(moved, for: StoreKey.console)
    }

    /// Kare geldi, satır gösterildi ya da bağlantı değişti: ipucu yeniden değerlendirilir (deneme modunda görünmez).
    private func updateSubtitleOffTip() {
        let visible = isRunning && !demoMode && subtitleOffTip.visible(now: Date(), streaming: sessionState == .streaming)
        if visible != showsSubtitleOffTip { showsSubtitleOffTip = visible }
    }

    private func handle(_ frame: CGImage, capturedAt: Int) async {
        lastFrame = frame
        lastFrameMs = capturedAt
        frameCount &+= 1
        lastFrameAt = Date()
        // Çevirisi gösterilen ekran yazıları hâlâ yerinde mi: özgün yazı kalkınca çevirisi de bu karede kalkar
        // (`ScreenPresence`; Windows/Android aynı).
        server.observe(frame)
        subtitleOffTip.frameArrived(at: Date(), streaming: sessionState == .streaming)
        updateSubtitleOffTip()
        // Num 0 ile duraklatıldı: altyazı da ek alanlar da okunmaz (kare yine alınır: kısayolla tek seferlik okuma ve
        // serbest alan onu kullanır).
        guard pipeline != nil, !subtitlesPaused else { return }
        // Ek alanlar altyazıyla aynı OCR kuyruğunu kullanır; saniyede bir tur yeterlidir.
        // Kullanıcının ek alanı yoksa bilinen oyunun hazır alanları (GameAreaPresets; ör. GTA 6 yardım kutusu ve mesajlar).
        // Telefon görünüyorsa (`seen`) ekran yazısı ve kenar bildirimi telefona çizilmez; telefonun okunması ayarla (`pose`).
        let seen = gamePhoneTracker?.sample(frame, now: capturedAt).pose
        let pose = settings.readsGamePhone ? seen : nil
        var areas = settings.watchedExtraAreas(game: gameChoice.game?.name, phoneOpen: pose != nil)
        if settings.autoScreenText, let missionRegion {
            areas.append(ExtraArea(id: MissionLine.areaId, name: "Mission", region: missionRegion, auto: true))
        }
        // Oyun telefonu açıkken telefonun yazıları telefon okuyucusundadır; kenar bildirimi sayılmaz.
        if seen == nil { areas += noticeAreas }
        areas += screenTextAreas(frame, capturedAt: capturedAt, watched: areas, phoneOpen: seen != nil)
        if regionWatcher == nil, !areas.isEmpty || pose != nil, let pipeline {
            regionWatcher = makeRegionWatcher(packLookup: pipeline.packLookup)
        }
        // Yapışık çeviri: pencere yakalaması her kareyi çapaya kendisi verir (okuma sıklığından bağımsız, saniyede 30);
        // konsoldan okunurken kare burada verilir.
        if let anchor = phoneAnchor, capturedWindow?.trackAnchor !== anchor { anchor.feed(frame, at: capturedAt) }
        regionWatcher?.offer(frame, areas: areas, phone: pose, capturedAt: capturedAt)
        // Ekranda menü açık (otomatik ekran yazısı menü durumunda): altyazı okunur ama gönderilmez, bekletilir; menü
        // kapanınca bekletilen konuşma satırı gönderilir (MenuHeldSender, #1240). Eskiden menüde altyazı hiç okunmuyordu;
        // menü sanılan anlarda konuşma satırları kayboluyordu.
        if menuSender?.poll() == true { pipeline?.skipForMenu() }
        // Önceki kare hâlâ işleniyorsa bu kare atlanır; okuma kareleri biriktirmez.
        var entry = frameGate.enter(now: SubtitleStabilizer.uptimeMs())
        if case .stuck(let ms) = entry {
            // Okuma bitmedi: önizleme canlıyken altyazı hiç gelmiyordu ve ancak uygulamayı kapatıp açmak düzeltiyordu.
            SubtitleLog.write("okuma \(ms) ms'dir bitmedi; okuma hattı yeniden kuruldu")
            makePipeline()
            entry = frameGate.enter(now: SubtitleStabilizer.uptimeMs())
        }
        guard case .enter(var token) = entry, let pipeline else {
            if case .busy = entry { skippedFrame = (frame, capturedAt) }
            return
        }
        skippedFrame = nil
        var next = (frame: frame, capturedAt: capturedAt)
        while true {
            await pipeline.process(next.frame, region: settings.region, capturedAt: next.capturedAt)
            // Okuma kare aralığından uzun sürüyorsa oturum kareleri o kadar seyrek kopyalar (atılacak kare kopyalanmaz).
            frameCadence.reportReadMs(pipeline.lastOcrMs)
            // Okuma sürerken atlanan son kare hemen okunur: pencere yakalaması değişmeyen ekranda kare göndermez; altyazı
            // belirirken gelen son kare atlanınca yeni satır kamera oynatılana dek okunmuyordu (GitHub #1019).
            guard frameGate.leave(token), let skipped = skippedFrame else { return }
            skippedFrame = nil
            guard self.pipeline === pipeline, !subtitlesPaused,
                  case .enter(let again) = frameGate.enter(now: SubtitleStabilizer.uptimeMs()) else { return }
            token = again
            next = skipped
        }
    }

    /// Kendiliğinden bulunan ekran yazıları (ayar açıkken, Tam ekran dışında; oyun telefonu açıkken değil). Karo örneği
    /// kare akışını tutmaz: arka planda tek uçuşta alınır, sonuç sonraki karelerde kullanılır. Altyazı alanı ve okunan
    /// ek alanlar (hazır alanlar dahil) dışlanır.
    private func screenTextAreas(_ frame: CGImage, capturedAt: Int, watched: [ExtraArea], phoneOpen: Bool) -> [ExtraArea] {
        guard settings.autoScreenText, !settings.extraAreasPausedByFullScreen, !phoneOpen else {
            screenTextDetector = nil
            return []
        }
        let detector = screenTextDetector ?? ScreenTextDetector()
        screenTextDetector = detector
        if !screenTextBusy, detector.due(capturedAt) {
            screenTextBusy = true
            let excluded = [settings.region] + watched.map(\.region)
            Task.detached(priority: .utility) { [weak self] in
                detector.sample(frame, now: capturedAt, excluded: excluded)
                await MainActor.run { self?.screenTextBusy = false }
            }
        }
        return detector.areas
    }

    // MARK: - Geçmiş

    private func addToHistory(source: String, translation: String, origin: LineMetrics.Origin) {
        history.add(source: source, translation: translation, origin: origin)
        saveHistory()
    }

    /// "Geçmiş"teki "Temizle": listeyi ve dosyayı boşaltır.
    func clearHistory() {
        history.clear()
        saveHistory()
    }

    /// Geçmiş arka planda dosyaya yazılır (küçük dosya; sırayla, en son hâli kalır).
    private func saveHistory() {
        guard let historyFile else { return }
        let history = self.history
        historyQueue.async { try? history.save(to: historyFile) }
    }

    /// Canlı altyazı alanındaki liste: bu oturumun satırları (oturum başlamadıysa hepsi).
    var sessionHistory: [SubtitleHistory.Entry] {
        sessionStartedAt.map { history.entries(since: $0) } ?? history.entries
    }

    /// Bu Mac'teki TV paketinin sürümü altyazı akışının `link` olayıyla TV'ye gider; TV'deki uygulama daha eskiyse TV'nin
    /// paneli "TV uygulaması eski" der (GitHub #1199). TV seçilmemişse LG paketi (sürümler aynı). Windows, iPhone ve
    /// Android ile aynı.
    private func shareLatestTVAppVersion() {
        server.latestTVAppVersion = bundledVersionForTV ?? services.bundledTVAppVersion
    }

    private func startServer() async throws {
        shareLatestTVAppVersion()
        guard !serverStarted else { return }
        do {
            serverPort = try await server.start()
        } catch {
            // 8787 başka bir uygulamada; TV'ye zaten adres bildirildiği için herhangi bir boş port olur.
            server = SubtitleServer(port: 0, key: server.accessKey, pairing: server.pairing)
            attachServer()
            serverPort = try await server.start()
        }
        serverStarted = true
    }

    /// TV ile aynı ağdaki Mac adresi.
    private func serverAddress(for tv: LGTV) -> String {
        "http://\(Self.localAddress(near: tv.host) ?? "127.0.0.1"):\(serverPort)"
    }

    static func localAddress(near host: String?) -> String? { NetworkAddress.near(host) }
}

// MARK: - Dublaj

extension AppModel {
    @discardableResult
    private func makeDubber() -> Dubber {
        if let dubber {
            dubber.update(serverPort: serverPort)
            return dubber
        }
        let dubber = Dubber(server: server, serverPort: serverPort, settings: settings.dubbing)
        dubber.onCastChanged = { [weak self] cast in self?.settings.dubbing.cast = cast }
        dubber.onError = { [weak self] message in self?.dubbingError = message }
        self.dubber = dubber
        return dubber
    }

    /// Dublaj çalabilir mi: doğal seste model indirilmiş olmalı, Hızlı seste (Mac'in kendi sesi) indirme gerekmez.
    var dubbingReady: Bool { settings.dubbing.engine == .fast || dubbingModelReady }

    private func speak(_ lines: [SpokenLine]) {
        guard settings.dubbing.enabled, dubbingReady else { return }
        makeDubber().speak(lines)
    }

    private func dubbingSettingsChanged(from old: DubbingSettings) {
        guard let dubber else {
            if settings.dubbing.enabled, !old.enabled, isRunning, dubbingReady { makeDubber().prepare() }
            return
        }
        dubber.cast = settings.dubbing.cast
        if dubber.voiceEngine != settings.dubbing.engine {
            dubber.stop()
            dubber.voiceEngine = settings.dubbing.engine
            if settings.dubbing.enabled, isRunning, dubbingReady { dubber.prepare() }
        }
        if dubber.output != settings.dubbing.output {
            dubber.stop()
            dubber.output = settings.dubbing.output
        }
        if !settings.dubbing.enabled {
            self.dubber = nil
            Task { await dubber.shutdown() }
        }
    }

    /// Ses modelini indirir (ilk kullanımda bir kez, ~440 MB).
    func downloadDubbingModel() async {
        guard dubbingDownload == nil else { return }
        dubbingDownload = 0
        dubbingError = nil
        do {
            try await DubbingModelStore.download { [weak self] progress in self?.dubbingDownload = progress }
            dubbingModelReady = true
            if settings.dubbing.enabled, isRunning { makeDubber().prepare() }
        } catch {
            dubbingError = error.localizedDescription
        }
        dubbingDownload = nil
    }

    /// Ayarlardaki "Dinle": sesi seçilen çıkıştan çalar.
    func previewVoice(_ voice: DubbingVoice) async {
        guard dubbingReady else { return }
        dubbingError = nil
        try? await startServer()
        makeDubber().preview(voice)
    }

    func assignVoice(_ voice: DubbingVoice, to name: String) {
        settings.dubbing.cast.assign(voice, to: name)
    }

    func removeDubbingModel() {
        if let dubber {
            self.dubber = nil
            Task { await dubber.shutdown() }
        }
        DubbingModelStore.remove()
        dubbingModelReady = false
    }
}

/// Son PS5 karesi; yalnız bölge önizlemesi izler.
@MainActor
final class FramePreview: ObservableObject {
    @Published var image: CGImage?
}

