// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import Darwin
import Combine
import RemotePlay

/// Dış dünyayla (PS5, PSN, TV) konuşan her şey; testlerde sahtesi kullanılır.
extension AppServices {
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
    func pairTV(_ tv: LGTV, key: String?, server: String) async throws -> TVPairing
    func makeStream(console: RegisteredConsole, accountId: Data) -> StreamControlling
    /// `onMoved`: TV ağda yeni bir adreste bulununca çağrılır.
    /// `appConnected`: TV uygulaması bilgisayara bağlı mı (Samsung'da bağlıyken TV'ye dokunulmaz).
    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void) -> KeeperControlling
    /// Uygulamayla gelen TV paketinin sürümü (geliştirici derlemesinde paket olmayabilir).
    var bundledTVAppVersion: String? { get }
    func isDevModeOn(host: String) async -> Bool
    func fetchDevKey(host: String, passphrase: String) async throws -> String
    func installedTVAppVersion(host: String, devKey: String) async throws -> String?
    func installTVApp(host: String, devKey: String) async throws
    /// LG geliştirici modunun süresini baştan başlatır; kalan saati döner (bilinmiyorsa nil).
    func renewDevSession(host: String, devKey: String) async -> Int?

    /// Samsung ve Android TV için uygulamayla gelen paket (geliştirici derlemesinde olmayabilir).
    func bundledApp(for brand: TVBrand) -> BundledTVApp?
    func isSamsungDevModeOn(host: String) async -> Bool
    /// TV'deki sürüme bakar, eksik ya da eskiyse kurar; TV'deki sürümü ve kurulup kurulmadığını döner.
    func installSamsungApp(host: String, app: BundledTVApp,
                           onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> (version: String, installed: Bool)
    func isAndroidDebugOn(host: String) async -> Bool
    /// Ağda ADB'si açık cihazlar.
    func scanAndroidTVs() async -> [String]
    /// Eksikse ya da eskiyse kurar; TV'deki sürümü döner.
    func installAndroidApp(host: String, app: BundledTVApp, onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> String
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
}

/// TV uygulamasını açık tutan görevli (gerçekte `TVKeeper`).
protocol KeeperControlling: AnyObject {
    func start(interval: Duration)
    func stop()
    func reconnect()
}

extension StreamSession: StreamControlling {}
extension TVKeeper: KeeperControlling {}

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

    func pairTV(_ tv: LGTV, key: String?, server: String) async throws -> TVPairing {
        switch tv.brand {
        case .androidTV:
            // Bilgisayar bu TV'yi denetlemez; TV uygulaması bilgisayarı kendisi bulur.
            return TVPairing(key: "", launched: true)
        case .samsung:
            let client = SamsungClient(tv: tv, token: key)
            defer { client.close() }
            let token = try await client.connect()
            try? await client.launch(appId: AppIdentity.samsungAppId, params: ["server": server])
            return TVPairing(key: token, launched: true)
        case .lg:
            break
        }
        let client = SSAPClient(tv: tv, clientKey: key)
        defer { client.close() }
        let newKey = try await client.connect()
        let launched = (try? await client.launch(appId: AppIdentity.tvAppId, params: ["server": server])) != nil
        return TVPairing(key: newKey, launched: launched)
    }

    func makeStream(console: RegisteredConsole, accountId: Data) -> StreamControlling {
        StreamSession(console: console, accountId: accountId)
    }

    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void) -> KeeperControlling {
        switch tv.brand {
        case .androidTV:
            return IdleKeeper()
        case .samsung:
            let locator = TVLocator(tv: tv, connect: { tv in
                let client = SamsungClient(tv: tv, token: key)
                do {
                    _ = try await client.connect()
                } catch {
                    client.close()
                    throw error
                }
                return client
            }, search: { await SamsungDiscovery.search() }, onMoved: onMoved)
            return TVKeeper(connect: { try await locator.connect() }, appId: AppIdentity.samsungAppId, params: params,
                            appConnected: appConnected)
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
        }, search: { await LGDiscovery.search() }, onMoved: onMoved)
        return TVKeeper(connect: { try await locator.connect() }, appId: AppIdentity.tvAppId, params: params)
    }

    // MARK: - TV uygulamasını kurma

    private var bundledTVPackage: URL? {
        Bundle.main.urls(forResourcesWithExtension: "ipk", subdirectory: "tv-app")?.first
    }

    var bundledTVAppVersion: String? {
        bundledTVPackage.flatMap { DevModeInstaller.version(ofPackage: $0.lastPathComponent) }
    }

    func isDevModeOn(host: String) async -> Bool { await DevModeInstaller.isDevModeOn(host: host) }

    func fetchDevKey(host: String, passphrase: String) async throws -> String {
        try await DevModeInstaller.fetchKey(host: host, passphrase: passphrase, runner: ProcessRunner())
    }

    func installedTVAppVersion(host: String, devKey: String) async throws -> String? {
        try await withKeyFile(devKey) { file in
            try await DevModeInstaller(host: host, keyFile: file, runner: ProcessRunner()).installedVersion()
        }
    }

    func installTVApp(host: String, devKey: String) async throws {
        guard let package = bundledTVPackage, let version = bundledTVAppVersion else { throw DevModeError.installFailed }
        try await withKeyFile(devKey) { file in
            try await DevModeInstaller(host: host, keyFile: file, runner: ProcessRunner()).install(package: package, version: version)
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
        let result = try await TVHelper.run(["samsung-install", "--host", host, "--package", app.url.path, "--version", app.version,
                                    "--profiles", TVHelper.dataDirectory.appendingPathComponent("samsung").path,
                                    "--log", TVInstallLog.file.path], onEvent: onEvent)
        let version = result.version.flatMap { $0.isEmpty ? nil : $0 } ?? app.version
        return (version, result.installed)
    }

    func isAndroidDebugOn(host: String) async -> Bool { await Self.isPortOpen(host: host, port: 5555) }

    func scanAndroidTVs() async -> [String] {
        (try? await TVHelper.run(["android-scan"]).hosts) ?? []
    }

    func installAndroidApp(host: String, app: BundledTVApp, onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> String {
        let result = try await TVHelper.run(["android-install", "--host", host, "--package", app.url.path, "--version", app.version,
                                             "--key-dir", TVHelper.dataDirectory.appendingPathComponent("adb").path], onEvent: onEvent)
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
}

@MainActor
final class AppModel: ObservableObject {
    enum Step: Int, CaseIterable {
        /// `betterTranslation`: isteğe bağlı ücretsiz Gemini anahtarı; atlanabilir.
        case welcome, secondAccount, psnLogin, console, tv, test, betterTranslation, done
    }

    @Published var step: Step {
        didSet {
            // Sihirbaz bitince ana ekran TV'siz de açılsın.
            if step == .done, oldValue != .done { store.save(true, for: StoreKey.setupComplete) }
        }
    }
    @Published var accountId: Data?
    @Published var console: RegisteredConsole?
    @Published var tv: LGTV?
    /// TV'nin eşleşme anahtarı kayıtlı.
    @Published private var tvKeySaved: Bool
    @Published var tvApp = TVAppState.unknown
    /// LG geliştirici modunun kalan süresi (saat); CouchSubs uzattıktan sonra bilinir.
    @Published var devModeHoursLeft: Int?
    /// Son eşleşmede TV uygulaması açılamadı.
    @Published private var tvAppMissing = false
    /// TV uygulaması denetimi sürüyor (bekleme ekranı ve çeviri başlangıcı aynı anda çağırabilir).
    @Published private var refreshingTVApp = false
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
            if settings.sharePool != oldValue.sharePool {
                let (pool, enabled) = (pool, settings.sharePool)
                Task { await pool.setEnabled(enabled) }
            }
            let translationChanged = settings.onlineTranslation != oldValue.onlineTranslation
                || settings.onlineEngine != oldValue.onlineEngine || settings.geminiModel != oldValue.geminiModel
                || settings.openAIModel != oldValue.openAIModel || settings.claudeModel != oldValue.claudeModel
                || settings.localAIBaseURL != oldValue.localAIBaseURL || settings.localAIModel != oldValue.localAIModel
            if translationChanged { Task { await refreshTranslatorStatus() } }
            if isRunning, settings.sourceLanguage != oldValue.sourceLanguage || settings.targetLanguage != oldValue.targetLanguage
                || translationChanged {
                Task { await refreshTranslatorStatus() }
                makePipeline()
            }
        }
    }

    // Çalışma durumu
    @Published var isRunning = false
    @Published var isStarting = false
    @Published var sessionState: SessionState = .disconnected(.stopped)
    /// Çeviri sürerken Mac'in boşta uykuya geçmesi engellenir (kullanıcı TV'de oynuyor, Mac'e dokunmuyor).
    var isPreventingSleep: Bool { sleepActivity != nil }
    @Published var tvClients = 0
    @Published var lastSource = ""
    @Published var lastTranslation = ""
    /// Bu oturumda çevrilen altyazılar; kaçırılan satır ana pencereden yeniden okunur.
    @Published var history = SubtitleHistory()
    @Published var translatorStatus: TranslatorStatus = .ready
    /// Çevrimiçi çeviri (DeepL ya da yapay zekâ) şu an çeviremiyor; o satırlar cihaz üstü çeviriyle çevriliyor.
    @Published var onlineIssue: OnlineKeyState?
    /// Yazı tanıma art arda hata veriyor; değeri diskteki boş yer (GB). macOS, diskte yer kalmayınca okuma modelini
    /// diske yazamaz ve her okumayı hata ile bitirir; altyazı sessizce hiç gelmez.
    @Published var readingFailedFreeGB: Double?
    private var readFailures = 0
    /// Son PS5 karesi (Ayarlar'daki bölge önizlemesi). Her karede değiştiği için modelin kendi yayınına girmez; yalnız
    /// önizlemeyi gösteren görünüm `framePreview`'u izler, öbür ekranlar her karede yeniden çizilmez.
    let framePreview = FramePreview()
    var lastFrame: CGImage? {
        get { framePreview.image }
        set { framePreview.image = newValue }
    }
    @Published var showAbout = false
    @Published var showSettings = false

    private let services: AppServices
    private let store: AppStore
    private let defaults: UserDefaults
    /// Çalışan okuma hattının dilleri.
    @Published private(set) var activeLanguages: (source: String, target: String)?
    private var server = SubtitleServer(port: AppIdentity.serverPort)
    private var serverStarted = false
    /// Sunucunun gerçekten dinlediği port (8787 doluysa rastgele bir port).
    @Published private(set) var serverPort: UInt16 = AppIdentity.serverPort
    private var session: StreamControlling?
    private var keeper: KeeperControlling?
    @Published private var sleepActivity: NSObjectProtocol?
    private var pipeline: SubtitlePipeline?
    /// Oyundaki altyazının son görüldüğü yer; deneme altyazısı TV'de oraya yerleşir.
    private var lastSubtitleBox: TextBox?
    private var processing = false
    private var wakeObserver: NSObjectProtocol?

    // Oyun paketleri ve ortak havuz
    /// Uygulamayla gelen ve ~/Library/Application Support/CouchSubs/packs klasöründeki paketler.
    let packs = GamePackLibrary(bundled: GamePackLibrary.bundledDirectory, user: GamePackLibrary.userDirectory)
    /// Ayarlarda listelenen paketler (açılışta arka planda yüklenince dolar).
    @Published var installedPacks: [GamePackLibrary.Info] = []
    private let pool: LinePool
    private var poolTimer: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?

    // Dublaj
    private var dubber: Dubber?
    /// Model indiriliyorsa ilerleme (0…1).
    @Published var dubbingDownload: Double?
    @Published var dubbingError: String?
    @Published var dubbingModelReady = DubbingModelStore.isReady

    // Bilgisayar ekranındaki altyazı penceresi (bkz. AppModel+ComputerScreen.swift)
    /// Pencerede şu an görünen satırlar (TV'dekiyle aynı yığın).
    @Published var overlayLines: [SubtitleStack.Line] = []
    /// Pencerenin yeri ve genişliği ayarlanıyor: örnek yazı görünür, tıklamalar geçmez.
    @Published var overlayAdjusting = false
    var overlayStack = SubtitleStack()
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
        let ready = Self.setupIsComplete(store: store, accountId: accountId, console: console, paired: paired)
        self.tvKeySaved = tvKeySaved
        self.accountId = accountId
        self.console = console
        self.tv = tv
        let loaded = defaults.data(forKey: StoreKey.settings).flatMap { try? JSONDecoder().decode(UserSettings.self, from: $0) } ?? UserSettings()
        let curated = loaded.withCuratedModels()
        settings = curated
        let poolFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true).appendingPathComponent("pool.json")
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // PS5 bağlantı günlüğü (~/Library/Logs/CouchSubs/remoteplay.log); eşleştirme olmazsa kullanıcı bunu gönderir.
        if !testing {
            RemotePlayLog.enable()
            RemotePlayLog.write("CouchSubs \(AppIdentity.version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        }
        pool = LinePool(file: poolFile, app: AppIdentity.version, platform: "mac", enabled: curated.sharePool && !testing)
        // Listede olmayan model varsayılana döndüyse ayar hemen kaydedilir.
        if curated != loaded, let data = try? JSONEncoder().encode(curated) { defaults.set(data, forKey: StoreKey.settings) }
        // Yarım kalan kurulum (ör. TV uygulaması kurulurken kapatıldı) PS5 kayıtlıysa TV adımından sürer.
        step = ready ? .done : (accountId != nil && console != nil ? .tv : .welcome)
        savedKeys = Set(TranslationEngine.allCases.filter { engine in
            engine.storeKey.flatMap { store.load(String.self, for: $0) }?.isEmpty == false
        })
        attachServer()

        // Paketler ilk altyazıyı bekletmesin diye açılışta arka planda yüklenir.
        let packs = self.packs
        Task.detached(priority: .utility) { [weak self] in
            let list = packs.packs
            await MainActor.run { self?.installedPacks = list }
        }
        // Testlerde havuz hiçbir şey göndermez.
        if !testing { startPool() }
    }

    /// Kurulum bitmiş mi. "Bitti" yalnız sihirbazın sonuna gelinince kaydedilir (TV adımı başarıyla geçildi ya da
    /// "TV'm yok" seçildi). Sihirbaz başlarken `false` yazılır: Samsung'da TV eşleşip uygulama kurulurken CouchSubs
    /// kapatılırsa eşleşme kayıtlı olsa da kurulum bitmiş sayılmaz. Hiç kayıt yoksa (beta.25'ten önce kurulmuş)
    /// eskisi gibi eşleşmiş TV yeter ve "bitti" kaydedilir.
    static func setupIsComplete(store: AppStore, accountId: Data?, console: RegisteredConsole?, paired: Bool) -> Bool {
        let saved = store.load(Bool.self, for: StoreKey.setupComplete)
        let ready = accountId != nil && console != nil && (saved ?? paired)
        if saved == nil { store.save(ready, for: StoreKey.setupComplete) }
        return ready
    }

    /// Sunucunun TV sayısını, altyazı yerini ve bilgisayar ekranına giden olayları bağlar (sunucu yeniden kurulunca da).
    private func attachServer() {
        server.onClientsChanged = { [weak self] count in self?.tvClients = count }
        server.sendsToTV = settings.output.showsOnTV
        server.onEvent = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.overlayReceive(event) } }
        }
    }

    /// Beş dakikada bir ve uygulama kapanırken havuz kuyruğu gönderilir; sunucuya ulaşılamazsa sonra yeniden denenir.
    private func startPool() {
        let pool = self.pool
        poolTimer = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LinePool.flushInterval))
                await pool.flush()
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                   queue: nil) { _ in
            // Kapanış en çok birkaç saniye bekler.
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await pool.flush()
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
        let active = settings.gamePacks && settings.sourceLanguage == "en" && settings.targetLanguage == "tr"
        pipeline.packLookup = active ? { packs.match($0) } : nil
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
        case .welcome, .secondAccount, .test, .betterTranslation: true
        case .psnLogin: accountId != nil
        case .console: console != nil
        case .tv: hasTV || settings.output == .computer
        case .done: false
        }
    }

    func advance() {
        guard canAdvance, let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
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
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw AppError.missingConsole }
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

    func pair(_ tv: LGTV) async throws {
        try await startServer()
        let pairing = try await services.pairTV(tv, key: store.load(String.self, for: StoreKey.tvKey), server: serverAddress(for: tv))
        if self.tv?.brand != tv.brand || (tv.brand != .androidTV && self.tv?.host != tv.host) {
            store.remove(StoreKey.tvAppVersion)
        }
        self.tv = tv
        store.save(tv, for: StoreKey.tv)
        store.save(pairing.key, for: StoreKey.tvKey)
        tvKeySaved = true
        tvAppMissing = !pairing.launched
        // Daha önce "TV'm yok" seçildiyse TV bağlanınca altyazı TV'ye gider.
        if settings.output == .computer { settings.output = .tv }
        if tv.brand == .lg {
            await refreshTVApp()
        } else {
            // Samsung girişi ya da Android onayı dakikalar sürebilir; eşleşme beklemesin.
            Task { await refreshTVApp() }
        }
    }

    // MARK: - TV uygulamasını kurma

    /// Geliştirici modu açık TV'de uygulamayı eksikse kurar, eskiyse günceller.
    /// Anahtar yoksa ve uygulama çalışıyorsa kullanıcıdan bir şey istenmez.
    func refreshTVApp() async {
        guard let tv, !refreshingTVApp else { return }
        refreshingTVApp = true
        defer { refreshingTVApp = false }
        switch tv.brand {
        case .lg: await refreshLGApp(tv)
        case .samsung: await refreshSamsungApp(tv)
        case .androidTV: await refreshAndroidApp(tv)
        }
    }

    /// Samsung ya da Android TV'ye daha önce CouchSubs'ın kurduğu sürüm.
    private var installedAppVersion: String? { store.load(String.self, for: StoreKey.tvAppVersion) }

    private func needsInstall(_ bundled: BundledTVApp) -> Bool {
        guard let installed = installedAppVersion else { return true }
        return DevModeInstaller.isNewer(bundled.version, than: installed)
    }

    private func refreshLGApp(_ tv: LGTV) async {
        guard let bundled = services.bundledTVAppVersion else { return }
        guard await services.isDevModeOn(host: tv.host) else {
            tvApp = tvAppMissing ? .devModeOff : .unknown
            return
        }
        guard let devKey = store.load(String.self, for: StoreKey.tvDevKey) else {
            tvApp = tvAppMissing ? .needsPassphrase(error: nil) : .unknown
            return
        }
        await install(tv: tv, devKey: devKey, bundled: bundled)
    }

    /// Samsung: geliştirici modu açıksa TV'deki CouchSubs sürümüne bakar, yoksa ya da eskiyse imzalayıp kurar
    /// (sertifika yoksa Samsung girişi istenir). Önceden yalnız bu Mac'in kurduğu sürüm hatırlanıyordu; TV'de eski
    /// kalan uygulama (ör. 0.9.10 gelirken 0.9.7) hiç güncellenmiyordu.
    private func refreshSamsungApp(_ tv: LGTV) async {
        guard let bundled = services.bundledApp(for: .samsung) else { return }
        let remembered = !needsInstall(bundled)
        let current = TVAppState.upToDate(installedAppVersion ?? bundled.version)
        guard await services.isSamsungDevModeOn(host: tv.host) else {
            // Geliştirici modu kapalıyken TV'ye sorulamaz; bu Mac'in kurduğu sürüme bakılır.
            tvApp = remembered ? current : .devModeOff
            return
        }
        // Güncel bilinen uygulamada denetim sessiz sürer; kart ancak kurulum başlarsa değişir.
        tvApp = remembered ? current : .working
        samsungCheckRunning = true
        defer { samsungCheckRunning = false }
        do {
            let result = try await services.installSamsungApp(host: tv.host, app: bundled) { [weak self] event in
                Task { @MainActor in self?.installEvent(event) }
            }
            store.save(result.version, for: StoreKey.tvAppVersion)
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
        ["signin", "certificate", "signing", "installing", "uninstalling"].contains(step)
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
            // Uygulama kuruluysa ve TV'de hata ayıklama kapalıysa yapılacak bir şey yok.
            if !needsInstall(bundled) {
                tvApp = .upToDate(installedAppVersion ?? bundled.version)
                return
            }
            guard let found = await services.scanAndroidTVs().first else {
                tvApp = .devModeOff
                return
            }
            host = found
        }
        tvApp = .working
        do {
            let version = try await services.installAndroidApp(host: host, app: bundled) { [weak self] event in
                Task { @MainActor in self?.installEvent(event) }
            }
            // TV'nin adresi bundan sonra sürüm denetimi için kullanılır.
            let located = LGTV(name: tv.name, host: host, brand: .androidTV)
            self.tv = located
            store.save(located, for: StoreKey.tv)
            store.save(version, for: StoreKey.tvAppVersion)
            tvApp = .upToDate(version)
        } catch {
            tvApp = Self.failedState(error)
        }
    }

    private func installEvent(_ event: TVInstallEvent) {
        // Kurulum bittikten sonra gelen geç olay sonucu ezmesin.
        switch tvApp {
        case .working, .signIn, .approveOnTV: break
        default: if !samsungCheckRunning { return }
        }
        switch event {
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
        Self.localAddress(near: tv?.host.isEmpty == false ? tv!.host : "192.168.1.1")
    }

    /// Key Server'dan anahtarı alır (TV ekranındaki parolayla) ve uygulamayı kurar.
    func installTVApp(passphrase: String) async {
        guard let tv, let bundled = services.bundledTVAppVersion else { return }
        tvApp = .working
        do {
            let devKey = try await services.fetchDevKey(host: tv.host, passphrase: passphrase.trimmingCharacters(in: .whitespacesAndNewlines))
            store.save(devKey, for: StoreKey.tvDevKey)
            await install(tv: tv, devKey: devKey, bundled: bundled)
        } catch {
            tvApp = .needsPassphrase(error: error as? DevModeError ?? .installFailed)
        }
    }

    private func install(tv: LGTV, devKey: String, bundled: String) async {
        tvApp = .working
        do {
            let installed = try await services.installedTVAppVersion(host: tv.host, devKey: devKey)
            if let installed, !DevModeInstaller.isNewer(bundled, than: installed) {
                tvApp = .upToDate(installed)
                await renewDevSessionIfDue(tv: tv, devKey: devKey)
                return
            }
            try await services.installTVApp(host: tv.host, devKey: devKey)
            tvApp = .upToDate(bundled)
            tvAppMissing = false
            await renewDevSessionIfDue(tv: tv, devKey: devKey)
            await openTVAppAfterInstall(tv)
        } catch DevModeError.keyRefused {
            // Geliştirici modu yeniden açılınca TV yeni anahtar üretir; eskisi işe yaramaz.
            store.remove(StoreKey.tvDevKey)
            tvApp = .needsPassphrase(error: nil)
        } catch let failure as DevModeFailure {
            // Genel mesaj tek başına sorunu bulmaya yetmiyordu; TV'nin verdiği sebep de gösterilir.
            let reason = failure.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            tvApp = .failed(failure.error, reason: reason.isEmpty ? nil : reason)
        } catch {
            tvApp = .failed(error as? DevModeError ?? .installFailed)
        }
    }

    /// LG geliştirici modunun 1000 saatlik süresini günde en çok bir kez baştan başlatır; kullanıcı TV'den uzatmak
    /// zorunda kalmaz.
    private func renewDevSessionIfDue(tv: LGTV, devKey: String) async {
        let last = defaults.object(forKey: StoreKey.devSessionRenewed) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        if let hours = await services.renewDevSession(host: tv.host, devKey: devKey) {
            devModeHoursLeft = hours
            defaults.set(Date(), forKey: StoreKey.devSessionRenewed)
        }
    }

    private func openTVAppAfterInstall(_ tv: LGTV) async {
        if let keeper {
            keeper.reconnect()
        } else {
            _ = try? await services.pairTV(tv, key: store.load(String.self, for: StoreKey.tvKey), server: serverAddress(for: tv))
        }
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
         StoreKey.setupComplete].forEach(store.remove)
        accountId = nil
        console = nil
        tv = nil
        tvKeySaved = false
        tvApp = .unknown
        tvAppMissing = false
        step = .welcome
    }

    // MARK: - Çeviri

    func start() async {
        // Düğmeye iki kez basılması ya da beklerken tekrar çağrılması ikinci bir oturum açmaz.
        guard !isRunning, !isStarting, canStart, let console, let accountId else { return }
        isStarting = true
        defer { isStarting = false }

        translatorStatus = await Translator.status(source: settings.sourceLanguage, target: settings.targetLanguage)
        try? await startServer()
        server.sendStyle(settings.style)

        makePipeline()
        if settings.dubbing.enabled, dubbingModelReady { makeDubber().prepare() }

        RemotePlayLog.write("Çeviri başladı; PS5'e bağlanılıyor: \(console.name) \(console.host)")
        let session = services.makeStream(console: console, accountId: accountId)
        session.onState = { [weak self] state in Task { @MainActor in self?.sessionStateChanged(state) } }
        session.onConsoleMoved = { [weak self] moved in Task { @MainActor in self?.consoleMoved(moved) } }
        session.onFrame = { [weak self] frame in Task { @MainActor in await self?.handle(frame) } }
        session.start()
        self.session = session

        startKeeper()

        // Mac uykudan uyanınca bağlantıları hemen yenile.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.session?.reconnectNow()
                self?.keeper?.reconnect()
            }
        }
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                              reason: "Translating game subtitles")
        isRunning = true
        if screenHotkey == nil { screenHotkey = GlobalHotkey(.translateScreen) { [weak self] in self?.translateScreen() } }
        screenHotkey?.enabled = true
        updateClickThroughHotkey()
    }

    /// Çeviri başlatılabilir mi: PS5 kurulu ve altyazının gideceği bir yer var (TV eşleşmiş ya da bilgisayar ekranı seçili).
    var canStart: Bool {
        console != nil && accountId != nil && (settings.output.showsOnComputer || hasTV)
    }

    /// TV uygulamasını başlatır ve açık tutar; TV kapalıysa açıldığında bağlanır. Altyazı TV'ye gitmiyorsa ya da TV
    /// yoksa bir şey yapmaz.
    private func startKeeper() {
        guard keeper == nil, settings.output.showsOnTV, hasTV, let tv else { return }
        let server = self.server
        let keeper = services.makeKeeper(tv: tv, key: store.load(String.self, for: StoreKey.tvKey), params: ["server": serverAddress(for: tv)],
                                         appConnected: { server.connectedClients > 0 }) { [weak self] moved in
            Task { @MainActor in self?.tvMoved(to: moved) }
        }
        keeper.start(interval: .seconds(5))
        self.keeper = keeper
        Task { await refreshTVApp() }
    }

    /// Altyazının yeri değişti: TV seçildiyse TV uygulaması açılır, kaldırıldıysa artık açık tutulmaz.
    private func outputChanged() {
        server.sendsToTV = settings.output.showsOnTV
        if !settings.output.showsOnComputer { overlayHide() }
        updateClickThroughHotkey()
        guard isRunning else { return }
        if settings.output.showsOnTV {
            startKeeper()
        } else {
            keeper?.stop()
            keeper = nil
        }
    }

    // MARK: - Ekranı çevir

    /// ⌥⌘T yalnız çeviri sürerken tutulur.
    private var screenHotkey: GlobalHotkey?
    /// ⌥⌘L: altyazı penceresinde "Tıklamalar geçsin"i açar/kapatır; çeviri sürerken ve altyazı bilgisayardayken tutulur.
    var clickThroughHotkey: GlobalHotkey?
    /// Süren "ekranı çevir" işi; yeniden basılınca iptal edilir.
    private var screenTask: Task<Void, Never>?
    /// TV'deki ekran çevirilerinin kalkacağı an; bu andan önce yeniden basmak onları kaldırır.
    private var screenShownUntil = Date.distantPast

    /// ⌥⌘T: oyunun şu anki karesinin tamamını bir kez okur, her yazı grubunu ayrı çevirip TV'de kendi yerine koyar.
    /// Çeviriler hazırlandıkça TV'ye gider. Çeviri sürerken ya da çeviriler TV'deyken yeniden basmak onları kaldırır.
    func translateScreen() {
        guard isRunning, let frame = lastFrame else { return }
        if let task = screenTask {
            task.cancel()
            screenTask = nil
            hideScreen()
            return
        }
        if Date() < screenShownUntil {
            hideScreen()
            return
        }
        server.sendStyle(settings.style)
        server.sendSubtitle(String(localized: "Translating the screen…"), durationMs: 2500)
        let reader = VisionReader(language: settings.sourceLanguage)
        let translator = makeTranslator()
        let server = self.server
        screenTask = Task { [weak self] in
            do {
                let reading = try await Task.detached(priority: .userInitiated) { try reader.readLines(frame, deep: false) }.value
                let items = try await ScreenTranslation.translate(reading, using: { try await translator.translate($0) }) { shown in
                    guard !Task.isCancelled else { return }
                    let milliseconds = ScreenTranslation.displayMilliseconds(shown)
                    server.sendScreen(shown, durationMs: milliseconds)
                    self?.screenShownUntil = Date().addingTimeInterval(Double(milliseconds) / 1000)
                }
                server.clear()
                if items.isEmpty { server.sendSubtitle(String(localized: "No text found on the screen."), durationMs: 2500) }
            } catch is CancellationError {
                return
            } catch let error as TranslatorError {
                server.clear()
                self?.translatorStatus = Self.translatorStatus(after: error)
            } catch {
                server.clear()
            }
            if !Task.isCancelled { self?.screenTask = nil }
        }
    }

    private func hideScreen() {
        screenShownUntil = .distantPast
        server.clearScreen()
        server.clear()
    }

    func tvMoved(to moved: LGTV) {
        tv = moved
        store.save(moved, for: StoreKey.tv)
    }

    /// Okuma hattını güncel dillerle (yeniden) kurar.
    private func makePipeline() {
        pipeline?.reset()
        let pipeline = SubtitlePipeline(reader: VisionReader(language: settings.sourceLanguage),
                                        translator: makeTranslator(),
                                        server: server, scheduler: ReadScheduler())
        pipeline.onPair = { [weak self, weak pipeline] source, translation in
            self?.lastSource = source
            self?.lastTranslation = translation
            self?.history.add(source: source, translation: translation)
            if let box = pipeline?.lastBox { self?.lastSubtitleBox = box }
        }
        // Dil paketi bu arada indirilmiş olabilir; her çeviri sonucu durumu günceller.
        pipeline.onTranslationResult = { [weak self] error in
            self?.translatorStatus = Self.translatorStatus(after: error)
        }
        pipeline.onReadResult = { [weak self] error in self?.noteRead(error) }
        pipeline.onSpeech = { [weak self] lines in self?.speak(lines) }
        connectPacks(to: pipeline)
        onlineIssue = nil
        pipeline.warmUp()
        self.pipeline = pipeline
        activeLanguages = (settings.sourceLanguage, settings.targetLanguage)
    }

    private func refreshTranslatorStatus() async {
        if onlineTranslationActive {
            translatorStatus = .ready
            return
        }
        translatorStatus = await Translator.status(source: settings.sourceLanguage, target: settings.targetLanguage)
    }

    // MARK: - Çevrimiçi çeviri (DeepL ve yapay zekâ)

    private func makeTranslator() -> TextTranslator {
        let (source, target) = (settings.sourceLanguage, settings.targetLanguage)
        // Önceki oturumların çevirileri motor ve dil çifti başına diskte durur; tekrar eden satır hemen gelir.
        let local = Translator(source: source, target: target,
                               cache: Self.translationCache(engine: Translator.engineID, source: source, target: target))
        let engine = settings.onlineEngine
        guard onlineTranslationActive, let storeKey = engine.storeKey else { return local }
        let online: TextTranslator & OnlineTranslating
        if engine == .local, let server = settings.localAIServer {
            // Yerel modelin anahtarı isteğe bağlıdır; önbellekte sunucu ve model ayrı tutulur.
            let key = store.load(String.self, for: storeKey) ?? ""
            online = AITranslator(provider: .local, key: key, model: server.model, server: server, fallback: local,
                                  cache: Self.translationCache(engine: server.engineID, source: source, target: target))
        } else if let key = store.load(String.self, for: storeKey), let provider = engine.aiProvider {
            let model = provider.model(settings.model(for: provider)).id
            online = AITranslator(provider: provider, key: key, model: model, fallback: local,
                                  cache: Self.translationCache(engine: provider.engineID(model: model), source: source, target: target))
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

    /// Anahtar denenir; geçerliyse (kotası bitmiş olsa da) Anahtarlık'a yazılır ve DeepL seçilir.
    func setDeepLKey(_ key: String) async -> OnlineKeyCheck {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let check = await services.checkOnlineKey(key)
        if check.state == .valid || check.state == .quotaExceeded { saveKey(key, for: .deepL) }
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
        let result = await services.testAIKey(provider: provider, key: key, model: settings.model(for: provider))
        switch result {
        case .success, .failure(.quotaExceeded), .failure(.modelRejected): saveKey(key, for: TranslationEngine(provider))
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
            case .success, .failure(.quotaExceeded), .failure(.modelRejected): saveKey(typed, for: .local)
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

    private func saveKey(_ key: String, for engine: TranslationEngine) {
        guard let storeKey = engine.storeKey else { return }
        store.save(key, for: storeKey)
        savedKeys.insert(engine)
        if settings.translationEngine == engine {
            // Motor zaten seçiliydi, anahtar yeni geldi: hat yeni anahtarla kurulsun.
            if isRunning { makePipeline() }
            Task { await refreshTranslatorStatus() }
        } else {
            settings.translationEngine = engine
        }
    }

    func stop() {
        session?.stop()
        session = nil
        keeper?.stop()
        keeper = nil
        pipeline?.reset()
        pipeline = nil
        activeLanguages = nil
        screenHotkey?.enabled = false
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
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
        isRunning = false
        onlineIssue = nil
        sessionState = .disconnected(.stopped)
        updateClickThroughHotkey()
        overlayHide()
    }

    private func sessionStateChanged(_ state: SessionState) {
        sessionState = state
        // Bağlantı koptuysa TV'de eski altyazı kalmasın.
        if case .disconnected = state {
            pipeline?.reset()
            server.clear()
            dubber?.stop()
        }
    }

    private func noteRead(_ error: Error?) {
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
        Self.statusText(sessionState, running: isRunning, pairedName: console.map { $0.name.isEmpty ? "PS5" : $0.name })
    }

    /// PS5 durumunun kullanıcıya gösterilecek metni. `pairedName`: eşleşmiş PS5'in adı; çeviri başlamamışken eşleşmiş
    /// PS5 için "Bağlı değil" yerine "eşleşti, başlatınca bağlanır" denir (eskiden eşleştirme başarılı olsa da ana ekran
    /// "Bağlı değil" diyordu).
    static func statusText(_ state: SessionState, running: Bool, pairedName: String? = nil) -> String {
        switch state {
        case .streaming: return String(localized: "Connected")
        case .connecting: return String(localized: "Connecting…")
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
        case .refused: return String(localized: "The PS5 refused the connection. Set up the PS5 again.")
        case .loginPasscode: return String(localized: "The second user has a login passcode on the PS5. Turn it off in Settings › Users and Accounts.")
        // Eskiden ağ hatası, bulunamayan PS5 ve diğer nedenler hep yalnız "Yeniden bağlanılıyor…" idi.
        case .notFound(let host):
            return String(format: String(localized: "PS5 not found at %@. Make sure it is on and on the same network. Reconnecting…"), host)
        case .network: return String(localized: "Can't reach the PS5. Reconnecting…")
        case .other(let detail) where !detail.isEmpty: return String(format: String(localized: "Reconnecting… (%@)"), detail)
        case .other, .stopped: return String(localized: "Reconnecting…")
        }
    }

    /// PS5'in adresi değişti: sonraki açılışlar yeni adresle başlasın.
    private func consoleMoved(_ moved: RegisteredConsole) {
        guard console != nil else { return }
        console = moved
        store.save(moved, for: StoreKey.console)
    }

    private func handle(_ frame: CGImage) async {
        lastFrame = frame
        // Önceki kare hâlâ işleniyorsa bu kare atlanır; okuma kareleri biriktirmez.
        guard !processing, let pipeline else { return }
        processing = true
        await pipeline.process(frame, region: settings.region)
        processing = false
    }

    private func startServer() async throws {
        guard !serverStarted else { return }
        do {
            serverPort = try await server.start()
        } catch {
            // 8787 başka bir uygulamada; TV'ye zaten adres bildirildiği için herhangi bir boş port olur.
            server = SubtitleServer(port: 0)
            attachServer()
            serverPort = try await server.start()
        }
        serverStarted = true
    }

    /// TV ile aynı ağdaki Mac adresi.
    private func serverAddress(for tv: LGTV) -> String {
        "http://\(Self.localAddress(near: tv.host) ?? "127.0.0.1"):\(serverPort)"
    }

    static func localAddress(near host: String) -> String? { NetworkAddress.near(host) }
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

    private func speak(_ lines: [SpokenLine]) {
        guard settings.dubbing.enabled, dubbingModelReady else { return }
        makeDubber().speak(lines)
    }

    private func dubbingSettingsChanged(from old: DubbingSettings) {
        guard let dubber else {
            if settings.dubbing.enabled, !old.enabled, isRunning, dubbingModelReady { makeDubber().prepare() }
            return
        }
        dubber.cast = settings.dubbing.cast
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
        guard dubbingModelReady else { return }
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

