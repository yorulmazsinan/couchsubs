// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import RemotePlay
import XCTest
@testable import CouchSubs

final class MemoryStore: AppStore {
    var values: [String: Data] = [:]
    var rejectedWrites: Set<String> = []
    func save<T: Encodable>(_ value: T, for key: String) {
        guard !rejectedWrites.contains(key) else { return }
        values[key] = try? JSONEncoder().encode(value)
    }
    func load<T: Decodable>(_ type: T.Type, for key: String) -> T? { values[key].flatMap { try? JSONDecoder().decode(type, from: $0) } }
    func remove(_ key: String) { values[key] = nil }
}

extension UserDefaults {
    /// Testler gerçek uygulamanın tercihlerine yazmasın diye her model ayrı bir alan kullanır.
    static func isolated() -> UserDefaults { TestDefaults.make("couchsubs-test") }
}

/// Testler gerçek Microsoft ve Xbox hizmetlerine gitmez: sahte verilmemişse her istek ağ hatasıdır.
struct UnreachableXboxHTTP: XboxHTTP {
    func request(_ method: String, _ url: String, headers: [String: String], body: String?) async throws -> XboxHTTPResponse {
        throw XboxError(.network, "test: ağ yok")
    }
}

final class FakeServices: AppServices {
    /// PS Remote Play / chiaki-ng bu Mac'te kurulu mu (Ayarlar'daki indirme satırları, ana ekran uyarısı).
    var remotePlayInstalledResult = true
    func remotePlayInstalled(_ app: RemotePlayApp) -> Bool { remotePlayInstalledResult }
    /// Seçilen pencereden okuma: gerçek ScreenCaptureKit'e gidilmez; açık pencereler ve izin elle verilir.
    var captureWindowStreams: [WindowCaptureTarget] = []
    var openCaptureWindows: [WindowCaptureTarget] = []
    var screenRecordingAllowedResult = true
    var screenRecordingSettingsOpened = 0
    func makeCaptureWindowStream(target: WindowCaptureTarget) -> StreamControlling {
        captureWindowStreams.append(target)
        let stream = FakeStream()
        streams.append(stream)
        return stream
    }
    func captureWindows() async -> [WindowCaptureTarget] { screenRecordingAllowedResult ? openCaptureWindows : [] }
    func screenRecordingAllowed() -> Bool { screenRecordingAllowedResult }
    func openScreenRecordingSettings() { screenRecordingSettingsOpened += 1 }
    var consoles = [ConsoleInfo(host: "192.168.1.253", name: "PS5-789", isAwake: true)]
    var tvs = [LGTV(name: "LG TV", host: "192.168.1.153")]
    var registered: RegisteredConsole?
    var registerError: Error?
    var launchedServer: String?
    var streams: [FakeStream] = []
    var keepers: [FakeKeeper] = []
    var appOnTV: String? = "0.6.1"
    var devMode = false
    var keyServer = true
    var refuseKey = false
    var installs = 0
    var pairCount = 0
    var onMoved: ((LGTV) -> Void)?

    /// "Kaydet ve dene"nin sonucu; gerçek hizmete gidilmez.
    var aiResult: Result<String, AIFailure> = .success("KRATOS: Gidiyoruz.")
    var aiTests: [(provider: AIProvider, key: String, model: String?)] = []
    func testAIKey(provider: AIProvider, key: String, model: String?) async -> Result<String, AIFailure> {
        aiTests.append((provider, key, model))
        return aiResult
    }
    /// "Bağlantıyı dene"nin sonucu; yerel sunucuya gidilmez.
    var localTests: [(server: LocalAIServer, key: String)] = []
    func testLocalAI(server: LocalAIServer, key: String) async -> Result<String, AIFailure> {
        localTests.append((server, key))
        return aiResult
    }

    // Xbox (Beta): Microsoft ve Xbox uçları sahte HTTP'den yanıtlanır; oturum sahte akıştır.
    var xboxHTTP: XboxHTTP?
    var xboxStreams: [(console: XboxConsole, playAudio: Bool, stream: FakeStream)] = []
    func makeXboxAuth(userToken: XboxUserToken?, onUserToken: @escaping @Sendable (XboxUserToken?) -> Void) -> XboxAuth {
        XboxAuth(http: xboxHTTP ?? UnreachableXboxHTTP(), sleep: { _ in }, userToken: userToken, onUserToken: onUserToken)
    }
    func xboxConsoles(auth: XboxAuth) async throws -> [XboxConsole] {
        try await XboxHome(auth: auth, http: xboxHTTP ?? UnreachableXboxHTTP()).consoles()
    }
    func makeXboxStream(auth: XboxAuth, console: XboxConsole, playAudio: Bool) -> StreamControlling {
        let stream = FakeStream()
        xboxStreams.append((console, playAudio, stream))
        return stream
    }

    func discoverConsoles() async -> [ConsoleInfo] { consoles }
    var loginError: Error?
    func accountId(fromRedirect url: URL) async throws -> Data {
        if let loginError { throw loginError }
        return Data(repeating: 1, count: 8)
    }
    var registeredPin: UInt32?
    func register(host: String, accountId: Data, pin: UInt32) async throws -> RegisteredConsole {
        registeredPin = pin
        if let registerError { throw registerError }
        let console = RegisteredConsole(host: host, name: "PS5-789", registKey: Data(repeating: 0x31, count: 16), morning: Data(repeating: 2, count: 16))
        registered = console
        return console
    }
    func discoverTVs() async -> [LGTV] { tvs }
    func pairTV(_ tv: LGTV, key: String?, server: String, accessKey: String) async throws -> TVPairing {
        launchedServer = server
        pairCount += 1
        return TVPairing(key: pairKey, launched: appOnTV != nil)
    }
    /// TV'nin eşleşmede döndüğü jeton (Samsung jetonla gelen bağlantıda boş dönebilir).
    var pairKey = "tv-key"
    func identifyTV(host: String) async -> LGTV? { LGTV(name: "LG OLED", host: host, brand: .lg) }
    var onKey: (@Sendable (String) -> Void)?
    var onOpenResult: (@Sendable (TVOpenProblem?) -> Void)?
    var streamPasscodes: [String?] = []
    func makeStream(console: RegisteredConsole, accountId: Data, loginPasscode: String?) -> StreamControlling {
        streamPasscodes.append(loginPasscode)
        let stream = FakeStream()
        streams.append(stream)
        return stream
    }
    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void, onKey: @escaping @Sendable (String) -> Void,
                    consolePort: @escaping @Sendable () -> Int?,
                    onOpenResult: @escaping @Sendable (TVOpenProblem?) -> Void) -> KeeperControlling {
        let keeper = FakeKeeper()
        keepers.append(keeper)
        self.onMoved = onMoved
        self.onKey = onKey
        self.onOpenResult = onOpenResult
        return keeper
    }
    var bundledTVAppVersion: String? = "0.6.1"
    func isDevModeOn(host: String) async -> Bool { devMode && !silentHosts.contains(host) }
    /// Yanıt vermeyen (adresi değişmiş ya da kapalı) TV adresleri; varsayılan: her adres yanıt verir.
    var silentHosts: Set<String> = []
    var reachChecks: [String] = []
    func tvResponds(host: String, brand: TVBrand) async -> Bool {
        reachChecks.append(host)
        return !silentHosts.contains(host)
    }
    var keyHosts: [String] = []
    func fetchDevKey(host: String, passphrase: String) async throws -> String {
        keyHosts.append(host)
        guard keyServer, !silentHosts.contains(host) else { throw DevModeError.keyServerOff }
        guard passphrase == "ABC123" else { throw DevModeError.wrongPassphrase }
        return "dev-key"
    }
    func installedTVAppVersion(host: String, devKey: String) async throws -> String? {
        if refuseKey { throw DevModeError.keyRefused }
        return appOnTV
    }
    var lgInstallError: Error?
    func installTVApp(host: String, devKey: String) async throws {
        installs += 1
        if let lgInstallError { throw lgInstallError }
        appOnTV = bundledTVAppVersion
    }
    var closes = 0
    func closeTVApp(host: String, devKey: String) async { closes += 1 }
    var renewedHours: Int? = 999
    var renewals = 0
    func renewDevSession(host: String, devKey: String) async -> Int? {
        renewals += 1
        return renewedHours
    }

    // Samsung ve Android TV
    var bundled: [TVBrand: BundledTVApp] = [:]
    var samsungDevMode = false
    var androidHosts: [String] = []
    var installError: Error?
    var events: [TVInstallEvent] = []
    var brandInstalls: [(brand: TVBrand, host: String)] = []
    func bundledApp(for brand: TVBrand) -> BundledTVApp? { bundled[brand] }
    func isSamsungDevModeOn(host: String) async -> Bool { samsungDevMode }
    /// Samsung TV'nin 8001 yanıtı ve TV'ye giden yolun bu Mac'teki adresi.
    var samsungCheck = SamsungPreflight(info: nil, computerAddress: nil)
    func checkSamsung(host: String) async -> SamsungPreflight { samsungCheck }
    /// Samsung TV'de kurulu sürüm (sahte TV'nin vd_applist'i); nil: uygulama yok.
    var samsungOnTV: String?
    /// true ise bir sonraki Samsung kurulumu `releaseSamsungInstall`'a kadar sürer (TV'de kurulum uzun sürüyor).
    var holdSamsungInstall = false
    private(set) var heldSamsungInstall: CheckedContinuation<Void, Never>?
    var samsungInstallCalls = 0
    func releaseSamsungInstall() {
        heldSamsungInstall?.resume()
        heldSamsungInstall = nil
    }
    func installSamsungApp(host: String, app: BundledTVApp,
                           onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> (version: String, installed: Bool) {
        samsungInstallCalls += 1
        if holdSamsungInstall {
            holdSamsungInstall = false
            await withCheckedContinuation { heldSamsungInstall = $0 }
        }
        if let onTV = samsungOnTV, !DevModeInstaller.isNewer(app.version, than: onTV) { return (onTV, false) }
        events.forEach(onEvent)
        if let installError { throw installError }
        brandInstalls.append((.samsung, host))
        samsungOnTV = app.version
        return (app.version, true)
    }
    func isAndroidDebugOn(host: String) async -> Bool { androidHosts.contains(host) }
    func scanAndroidTVs() async -> [String] { androidHosts }
    /// Her Android kurulumunda "güncelse de aç" istendi mi.
    var androidOpenRequests: [Bool] = []
    func installAndroidApp(host: String, app: BundledTVApp, open: Bool, onEvent: @escaping @Sendable (TVInstallEvent) -> Void) async throws -> String {
        androidOpenRequests.append(open)
        events.forEach(onEvent)
        if let installError { throw installError }
        brandInstalls.append((.androidTV, host))
        return app.version
    }
}

final class FakeStream: StreamControlling {
    var onFrame: ((CGImage) -> Void)?
    var onState: ((SessionState) -> Void)?
    var onConsoleMoved: ((RegisteredConsole) -> Void)?
    var started = false
    func start() { started = true }
    func stop() { started = false }
    var reconnects = 0
    func reconnectNow() { reconnects += 1 }
    /// Oturum yeniden denemeyi bıraktı (PS5'te Uzaktan Oynatma çöktü, Xbox denemeleri bitti).
    var hasGivenUp = false
    /// Çeviri sürerken verilen ses ayarları (Xbox).
    var playAudioChanges: [Bool] = []
    func setPlayAudio(_ enabled: Bool) { playAudioChanges.append(enabled) }
}

final class FakeKeeper: KeeperControlling {
    var running = false
    var reconnects = 0
    func start(interval: Duration) { running = true }
    func stop() { running = false }
    func reconnect() { reconnects += 1 }
}

@MainActor
final class AppModelTests: XCTestCase {
    private let console = RegisteredConsole(host: "192.168.1.253", name: "PS5", registKey: Data(repeating: 0x31, count: 16), morning: Data(repeating: 2, count: 16))

    /// Her test kendi geçici kurulum günlüğüne yazar; kullanıcının ~/Library/Logs/CouchSubs/tvinstall.log'una asla.
    override func setUp() {
        super.setUp()
        TVInstallLog.testFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("CouchSubsTests-\(UUID().uuidString)/tvinstall.log")
    }

    override func tearDown() {
        if let file = TVInstallLog.testFile { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        TVInstallLog.testFile = nil
        super.tearDown()
    }

    /// Güvence: test sürecinde kurulum günlüğü gerçek kullanıcı günlüğü değil (21–22 Kas'ta test satırları oraya düşüyordu).
    func testInstallLogNeverPointsAtTheRealUserLog() {
        XCTAssertTrue(TVInstallLog.isTesting)
        XCTAssertNotEqual(TVInstallLog.file.standardizedFileURL, TVInstallLog.userFile.standardizedFileURL)
        XCTAssertFalse(TVInstallLog.file.path.contains("Library/Logs"))
        TVInstallLog.testFile = nil
        XCTAssertNotEqual(TVInstallLog.file.standardizedFileURL, TVInstallLog.userFile.standardizedFileURL)
        XCTAssertFalse(TVInstallLog.file.path.contains("Library/Logs"))
    }

    func testFreshInstallStartsAtWelcome() {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        XCTAssertNotEqual(model.step, .tv)
    }

    func testCompleteSetupOpensMainScreen() {
        let store = MemoryStore()
        store.save(Data(repeating: 1, count: 8), for: StoreKey.accountId)
        store.save(console, for: StoreKey.console)
        store.save(LGTV(name: "LG TV", host: "192.168.1.153"), for: StoreKey.tv)
        store.save("tv-key", for: StoreKey.tvKey)
        XCTAssertEqual(AppModel(services: FakeServices(), store: store, defaults: .isolated()).step, .done)
        XCTAssertEqual(store.load(Bool.self, for: StoreKey.setupComplete), true, "Eski kurulum bir kez 'bitti' diye kaydedilir")
    }

    /// Sihirbazda PS5'e kadar gelinmiş bir kurulum (hesap ve konsol kayıtlı).
    private func wizardUpToTV(_ store: MemoryStore, _ defaults: UserDefaults) -> AppModel {
        let model = AppModel(services: FakeServices(), store: store, defaults: defaults)
        XCTAssertNotEqual(model.step, .tv)
        let accountId = Data(repeating: 1, count: 8)
        model.accountId = accountId
        model.console = console
        store.save(accountId, for: StoreKey.accountId)
        store.save(console, for: StoreKey.console)
        model.step = .tv
        return model
    }

    /// Samsung: TV eşleşti, uygulama kurulurken CouchSubs kapatıldı. Yeniden açılınca kurulum bitmiş sayılmaz, TV
    /// adımından sürer.
    func testInterruptedTVInstallIsNotComplete() async throws {
        let store = MemoryStore()
        let defaults = UserDefaults.isolated()
        let model = wizardUpToTV(store, defaults)
        try await model.pair(LGTV(name: "Samsung", host: "192.168.1.20", brand: .samsung))
        XCTAssertTrue(model.hasTV)
        let reopened = AppModel(services: FakeServices(), store: store, defaults: defaults)
        XCTAssertEqual(reopened.step, .tv)
        XCTAssertTrue(reopened.hasTV, "Eşleşme kaybolmaz; TV adımında uygulama kurulumu sürer")
        XCTAssertNotEqual(store.load(Bool.self, for: StoreKey.setupComplete), true)
    }

    func testFinishedTVSetupIsComplete() async throws {
        let store = MemoryStore()
        let defaults = UserDefaults.isolated()
        let model = wizardUpToTV(store, defaults)
        try await model.pair(LGTV(name: "Samsung", host: "192.168.1.20", brand: .samsung))
        // TV → TV girişi → daha iyi çeviri → deneme → bitti.
        model.advance()
        model.advance()
        model.advance()
        model.advance()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(AppModel(services: FakeServices(), store: store, defaults: defaults).step, .done)
    }

    /// "İkinci hesap yok mu?": PSN girişi ve PS5 olmadan kurulum biter; görüntü Remote Play penceresinden, altyazı
    /// bilgisayar ekranında. Yeniden açılınca sihirbaz çıkmaz.
    func testNoSecondAccountReadsRemotePlayWindowAndCompletesSetup() {
        let store = MemoryStore()
        let defaults = UserDefaults.isolated()
        let model = AppModel(services: FakeServices(), store: store, defaults: defaults)
        model.advance()
        XCTAssertEqual(model.step, .secondAccount)
        model.useRemotePlayWindow()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(model.settings.frameSource, .remotePlayWindow)
        XCTAssertEqual(model.settings.output, .computer)
        XCTAssertNil(model.accountId)
        XCTAssertTrue(model.canStart)
        XCTAssertEqual(AppModel(services: FakeServices(), store: store, defaults: defaults).step, .done)
    }

    /// Pencere modunda kurulmuş, sonra Ayarlar'da PS5 seçilmiş: "Hesabı bağla" görünür, sihirbaz ikinci hesap adımından açılır.
    func testLinkPS5AccountOpensWizardAtSecondAccount() {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: UserDefaults.isolated())
        model.advance()
        model.useRemotePlayWindow()
        XCTAssertFalse(model.needsPS5Link)
        model.settings.frameSource = .ps5
        XCTAssertTrue(model.needsPS5Link)
        XCTAssertFalse(model.canStart)
        model.linkPS5Account()
        XCTAssertEqual(model.step, .secondAccount)
    }

    /// Remote Play uygulaması kurulu değilse ana ekran bunu ve nereden indirileceğini söyler.
    func testMissingRemotePlayAppIsReported() {
        let services = FakeServices()
        services.remotePlayInstalledResult = false
        let model = AppModel(services: services, store: MemoryStore(), defaults: UserDefaults.isolated())
        model.advance()
        model.useRemotePlayWindow()
        XCTAssertTrue(model.remotePlayMissing)
        XCTAssertEqual(model.ps5StatusText, String(localized: "The Remote Play app isn't installed on this Mac. Download it in Settings › Picture source."))
        services.remotePlayInstalledResult = true
        XCTAssertFalse(model.remotePlayMissing)
        XCTAssertEqual(model.ps5StatusText, String(localized: "Reads the Remote Play window on this Mac when you start translating."))
    }

    /// "TV'm yok, bilgisayar ekranında göster" de kurulumu bitirir.
    func testComputerScreenChoiceCompletesSetup() {
        let store = MemoryStore()
        let defaults = UserDefaults.isolated()
        let model = wizardUpToTV(store, defaults)
        model.useComputerScreen()
        // Yarıda kapatılırsa yine TV adımından sürer.
        XCTAssertEqual(AppModel(services: FakeServices(), store: store, defaults: defaults).step, .tv)
        model.advance()
        model.advance()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(AppModel(services: FakeServices(), store: store, defaults: defaults).step, .done)
    }

    func testPsnStepNeedsAccountId() {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        model.step = .psnLogin
        XCTAssertFalse(model.canAdvance)
        model.accountId = Data(repeating: 1, count: 8)
        XCTAssertTrue(model.canAdvance)
    }

    func testConsoleStepNeedsRegistration() async throws {
        let services = FakeServices()
        let model = AppModel(services: services, store: MemoryStore(), defaults: .isolated())
        model.accountId = Data(repeating: 1, count: 8)
        model.step = .console
        XCTAssertFalse(model.canAdvance)
        try await model.register(host: "192.168.1.253", pin: "12345678")
        XCTAssertTrue(model.canAdvance)
        XCTAssertEqual(services.registered?.host, "192.168.1.253")
    }

    /// Eşleşmenin kaydedildiği günlüğe yazılır (kullanıcılar başarıyı fark etmeyip tekrar bağlanıyordu).
    func testPairingSaveIsLogged() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("couchsubs-log-\(UUID())")
        let file = folder.appendingPathComponent("remoteplay.log")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MemoryStore()
        let model = AppModel(services: FakeServices(), store: store, defaults: .isolated())
        model.accountId = Data(repeating: 1, count: 8)
        RemotePlayLog.enable(file: file)
        defer { RemotePlayLog.disable() }
        try await model.register(host: "192.168.1.253", pin: "12345678")
        RemotePlayLog.flush()
        XCTAssertNotNil(store.load(RegisteredConsole.self, for: StoreKey.console))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("PS5 kaydı kaydedildi (192.168.1.253): PS5-789"), text)
    }

    /// Eşleşince sonraki adıma kendiliğinden geçilir; kullanıcı bu arada Geri'ye bastıysa ilerlenmez.
    func testContinueAfterPairingAdvancesOnlyFromConsoleStep() async throws {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        model.accountId = Data(repeating: 1, count: 8)
        model.step = .console
        model.continueAfterPairing()
        XCTAssertEqual(model.step, .console)
        try await model.register(host: "192.168.1.253", pin: "12345678")
        model.back()
        model.continueAfterPairing()
        XCTAssertEqual(model.step, .psnLogin)
        model.step = .console
        model.continueAfterPairing()
        XCTAssertEqual(model.step, .tv)
    }

    /// Sony girişi engellenen kullanıcı hesap kimliğini base64 olarak elle yazar; web girişiyle aynı biçimde saklanır.
    func testManualAccountIdIsStoredLikeWebLogin() {
        let store = MemoryStore()
        let model = AppModel(services: FakeServices(), store: store, defaults: .isolated())
        model.step = .psnLogin
        let id = Data([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertTrue(model.useManualAccountId("  \(id.base64EncodedString()) "))
        XCTAssertEqual(model.accountId, id)
        XCTAssertTrue(model.canAdvance)
        XCTAssertEqual(store.load(Data.self, for: StoreKey.accountId), id)
    }

    func testInvalidManualAccountIdIsRejected() {
        for value in ["", "AQIDBAUGBw==", "AQIDBAUGBwgJ", "AQIDBAUGBw!=", "1234567890"] {
            let store = MemoryStore()
            let model = AppModel(services: FakeServices(), store: store, defaults: .isolated())
            XCTAssertFalse(model.useManualAccountId(value), value)
            XCTAssertNil(model.accountId, value)
            XCTAssertNil(store.load(Data.self, for: StoreKey.accountId), value)
        }
    }

    /// Yeni metinler Türkçesiyle ortak metin dosyasında (Windows da aynı dosyayı okur).
    func testPairingStringsAreTranslated() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CouchSubs/Resources/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let strings = root?["strings"] as? [String: Any] ?? [:]
        let expected = [
            "PS5 paired: %@ (%@). Press Continue.": "PS5 eşleşti: %@ (%@). Devam'a basın.",
            "Enter account ID manually": "Hesap kimliğini elle gir",
        ]
        for (key, value) in expected {
            let entry = strings[key] as? [String: Any]
            let tr = ((entry?["localizations"] as? [String: Any])?["tr"] as? [String: Any])?["stringUnit"] as? [String: Any]
            XCTAssertEqual(tr?["value"] as? String, value, key)
        }
    }

    /// PS5 hesabı tanımazsa kullanıcıya kodu hangi kullanıcıdan alacağı söylenmeli.
    func testWrongAccountRegistrationExplainsWhatToDo() async {
        let error = await registrationError(Registration.RegistrationError(.wrongAccount, reason: 0x80108b02))
        XCTAssertEqual((error as? DetailedError)?.error, .wrongAccount)
    }

    func testOtherRegistrationFailureSuggestsNewCode() async {
        let error = await registrationError(Registration.RegistrationError(.failed))
        XCTAssertEqual((error as? DetailedError)?.error, .registrationFailed)
    }

    /// Her eşleştirme sonucu kendi iletisini alır; hiçbiri sessiz kalmaz ve genel "kodu kabul etmedi"ye düşmez.
    func testEveryRegistrationFailureHasItsOwnMessage() async {
        let cases: [(Registration.RegistrationError.Kind, AppError)] = [
            (.wrongCode, .wrongCode), (.noAnswer, .consoleNoAnswer), (.noReply, .consoleNoReply), (.canceled, .consoleNoReply),
            (.inUse, .consoleInUse), (.consoleCrashed, .consoleCrashed), (.versionMismatch, .consoleVersion),
            (.badAddress, .badAddress), (.localNetworkBlocked, .localNetworkBlocked),
            (.pairingClosed, .consolePairingClosed), (.connectFailed, .consoleConnectFailed), (.noFreePort, .noFreePort),
        ]
        for (kind, expected) in cases {
            let error = await registrationError(Registration.RegistrationError(kind))
            XCTAssertEqual((error as? DetailedError)?.error, expected, "\(kind)")
            XCTAssertFalse(error?.localizedDescription.isEmpty ?? true)
        }
    }

    /// İletide PS5'in kodu ve gönderilecek günlük dosyası yazar.
    func testRegistrationErrorShowsThePs5CodeAndLogFile() async {
        let error = await registrationError(Registration.RegistrationError(.wrongCode, reason: 0x80108b09,
                                                                            detail: "0x80108b09 (Regist failed, probably invalid PIN)"))
        let text = error?.localizedDescription ?? ""
        XCTAssertTrue(text.contains("0x80108b09"))
        XCTAssertTrue(text.contains(RemotePlayLog.displayPath))
    }

    /// libchiaki dışı bir hata da (ör. kayıt başlatılamadı) iletiye dönüşür.
    func testUnexpectedRegistrationErrorIsStillExplained() async {
        struct Boom: Error {}
        let error = await registrationError(Boom())
        XCTAssertEqual((error as? DetailedError)?.error, .registrationFailed)
    }

    func testPinMustBeEightDigits() async {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        model.accountId = Data(repeating: 1, count: 8)
        for pin in ["1234", "", "123456789", "1234567a"] {
            do {
                try await model.register(host: "192.168.1.253", pin: pin)
                XCTFail("Geçersiz kod kabul edilmemeli: \(pin)")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidPin)
                XCTAssertNil(model.console)
            }
        }
    }

    /// PS5'in ekranındaki gibi boşluklu ya da tireli yazılan kod da kabul edilir.
    func testPinWithSpacesIsAccepted() async throws {
        let services = FakeServices()
        let model = AppModel(services: services, store: MemoryStore(), defaults: .isolated())
        model.accountId = Data(repeating: 1, count: 8)
        try await model.register(host: " 192.168.1.253 ", pin: " 1234 5678 ")
        XCTAssertEqual(services.registered?.host, "192.168.1.253")
        XCTAssertEqual(services.registeredPin, 12345678)
    }

    /// PSN girişinin her hatası kendi iletisini alır (eskiden ham Swift hatası ya da "Giriş tamamlanmadı" idi);
    /// Sony'nin hatası ve HTTP kodu iletide yazar, hesap kaydedilmez.
    func testEveryLoginFailureHasItsOwnMessage() async {
        let cases: [(PSNAccount.PSNError, AppError, String?)] = [
            (.refused(status: 400, detail: "invalid_grant: Invalid authorization code"), .loginRefused, "HTTP 400, invalid_grant"),
            (.rateLimited(status: 429, detail: nil), .loginRateLimited, "HTTP 429"),
            (.http(503, detail: nil), .loginServer, "HTTP 503"),
            (.network("The Internet connection appears to be offline."), .loginNetwork, "offline"),
            (.badResponse, .loginBadResponse, nil),
            (.noCode, .invalidLogin, nil),
        ]
        for (thrown, expected, detail) in cases {
            let services = FakeServices()
            services.loginError = thrown
            let model = AppModel(services: services, store: MemoryStore(), defaults: .isolated())
            do {
                try await model.completePSNLogin(redirect: URL(string: "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=x")!)
                XCTFail("Giriş başarısız olmalı: \(thrown)")
            } catch {
                XCTAssertEqual((error as? DetailedError)?.error, expected, "\(thrown)")
                if let detail { XCTAssertTrue(error.localizedDescription.contains(detail), error.localizedDescription) }
                XCTAssertTrue(error.localizedDescription.contains(RemotePlayLog.displayPath))
                XCTAssertNil(model.accountId)
            }
        }
    }

    /// Giriş penceresi yönlendirmesiz kapanırsa sessiz kalınmaz; sayfanın sorunu varsa o söylenir.
    func testClosedLoginWindowIsExplained() {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        XCTAssertEqual(model.loginWindowError(problem: nil) as? AppError, .loginWindowClosed)
        XCTAssertEqual((model.loginWindowError(problem: "HTTP 429") as? DetailedError)?.error, .loginRateLimited)
        let failed = model.loginWindowError(problem: "The Internet connection appears to be offline.")
        XCTAssertEqual((failed as? DetailedError)?.error, .loginPageFailed)
        XCTAssertTrue(failed.localizedDescription.contains("offline"))
    }

    /// Elle yazılan PS5 adresi temizlenir; adres olmayan yazı libchiaki'ye gitmeden "bu adreste PS5 yok" iletisi alır.
    func testManualConsoleAddressIsCleanedOrRejected() async throws {
        for (typed, expected) in [("192.168.1.253:9295", "192.168.1.253"), ("http://192.168.1.253/", "192.168.1.253"),
                                  ("192,168,1,253", "192.168.1.253")] {
            let services = FakeServices()
            let model = AppModel(services: services, store: MemoryStore(), defaults: .isolated())
            model.accountId = Data(repeating: 1, count: 8)
            try await model.register(host: typed, pin: "12345678")
            XCTAssertEqual(services.registered?.host, expected, typed)
        }
        for typed in ["192.168.1.256", "192.168.1. 253", "PS5 salon", "fe80::1"] {
            let services = FakeServices()
            let model = AppModel(services: services, store: MemoryStore(), defaults: .isolated())
            model.accountId = Data(repeating: 1, count: 8)
            do {
                try await model.register(host: typed, pin: "12345678")
                XCTFail("Geçersiz adresle kayıt başlamamalı: \(typed)")
            } catch {
                XCTAssertEqual(error as? AppError, .badAddress, typed)
                XCTAssertNil(services.registered, typed)
            }
        }
    }

    /// PS5 seçilmeden ya da adres yazılmadan bağlanılırsa "PS5 bulunamadı" denir.
    func testMissingConsoleIsExplained() async {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        model.accountId = Data(repeating: 1, count: 8)
        do {
            try await model.register(host: "  ", pin: "12345678")
            XCTFail("Adressiz kayıt başlamamalı")
        } catch {
            XCTAssertEqual(error as? AppError, .missingConsole)
        }
    }

    private func registrationError(_ thrown: Error) async -> Error? {
        let services = FakeServices()
        services.registerError = thrown
        let model = AppModel(services: services, store: MemoryStore(), defaults: .isolated())
        model.accountId = Data(repeating: 1, count: 8)
        do {
            try await model.register(host: "192.168.1.253", pin: "12345678")
            XCTFail("Kayıt başarısız olmalı")
            return nil
        } catch {
            XCTAssertNil(model.console)
            return error
        }
    }

    func testPairingTvPassesServerAddressAndStoresKey() async throws {
        let services = FakeServices()
        let store = MemoryStore()
        let model = AppModel(services: services, store: store, defaults: .isolated())
        try await model.pair(LGTV(name: "LG TV", host: "192.168.1.153"))
        XCTAssertTrue(services.launchedServer?.hasPrefix("http://") == true)
        XCTAssertTrue(services.launchedServer?.hasSuffix(":\(model.serverPort)") == true)
        XCTAssertEqual(store.load(String.self, for: StoreKey.tvKey), "tv-key")
    }

    /// PR #870 incelemesi: TV'nin başlattığı eşleşme onaylanınca TV kaydedilmiyordu (bekçi ve TV kartı çalışmıyordu). Onaylanan
    /// TV elle seçilmiş gibi eşlenir: adres, marka ve izin kayıtlı.
    func testApprovedTVRequestSavesTheTV() async throws {
        let services = FakeServices()
        let store = MemoryStore()
        let model = AppModel(services: services, store: store, defaults: .isolated())
        await model.openTVPairing()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(model.serverPort)/pair")!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
        for _ in 0..<100 where model.tvPairingRequest == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let pending = try XCTUnwrap(model.tvPairingRequest)
        model.resolveTVPairing(SubtitlePairing.Ticket(id: pending.id, code: pending.code, host: "192.168.1.40"), accept: true)
        for _ in 0..<100 where !model.hasTV { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(model.hasTV)
        XCTAssertEqual(model.tv, LGTV(name: "LG OLED", host: "192.168.1.40", brand: .lg))
        XCTAssertEqual(store.load(String.self, for: StoreKey.tvKey), "tv-key")
        XCTAssertEqual(services.pairCount, 1)
    }

    /// "TV'de test et": TV uygulaması bağlı değilse önce TV'de açılır (Samsung 65S95F'de TV'ye hiçbir şey gelmiyordu);
    /// çeviri sürmüyorsa geçici bekçi bekleme bitince kapanır.
    func testTestOnTVOpensTheTVAppWhenItIsNotConnected() async {
        let services = FakeServices()
        let store = MemoryStore()
        store.save(LGTV(name: "Samsung", host: "127.0.0.1", brand: .samsung), for: StoreKey.tv)
        store.save("tv-key", for: StoreKey.tvKey)
        let model = AppModel(services: services, store: store, defaults: .isolated())
        model.settings.output = .tv
        model.testTVWait = .milliseconds(300)
        await model.testSubtitle()
        XCTAssertEqual(services.keepers.count, 1)
        XCTAssertFalse(services.keepers[0].running)
        XCTAssertFalse(model.openingTVAppForTest)
    }

    /// X @Eaglaris (20 Kas): çeviri sürmeden "TV'de test et"e basılınca Android TV 0.9.34'ün eşleştirme isteği 409 ile
    /// reddediliyordu; TV "Eşleştirme tamamlanmadı" yazıyor, deneme altyazısı hiç çıkmıyordu. Deneme onay penceresini açar.
    func testTestOnTVOpensThePairingWindowForAnAndroidTV() async throws {
        let store = MemoryStore()
        store.save(LGTV(name: "Android TV", host: "127.0.0.1", brand: .androidTV), for: StoreKey.tv)
        let model = AppModel(services: FakeServices(), store: store, defaults: .isolated())
        model.settings.output = .tv
        model.testPairWait = .milliseconds(300)
        await model.testSubtitle()
        XCTAssertFalse(model.openingTVAppForTest)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(model.serverPort)/pair")!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    /// #40: Samsung jetonla gelen bağlantıda jeton göndermeyince saklı jeton silinmemeli (yoksa TV her seferinde izin sorar).
    func testPairingWithoutNewTokenKeepsSavedToken() async throws {
        let services = FakeServices()
        services.pairKey = ""
        let store = MemoryStore()
        store.save("samsung-token", for: StoreKey.tvKey)
        let model = AppModel(services: services, store: store, defaults: .isolated())
        try await model.pair(LGTV(name: "Samsung", host: "192.168.1.20", brand: .samsung))
        XCTAssertEqual(store.load(String.self, for: StoreKey.tvKey), "samsung-token")
    }

    func testOnboardingWalksAllStepsInOrder() async throws {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        XCTAssertNotEqual(model.step, .tv); model.advance()
        XCTAssertEqual(model.step, .secondAccount); model.advance()
        XCTAssertEqual(model.step, .psnLogin)
        try await model.completePSNLogin(redirect: URL(string: "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=x")!)
        model.advance()
        XCTAssertEqual(model.step, .console)
        try await model.register(host: "192.168.1.253", pin: "12345678"); model.advance()
        XCTAssertEqual(model.step, .tv)
        try await model.pair(LGTV(name: "LG TV", host: "192.168.1.153")); model.advance()
        XCTAssertEqual(model.step, .hdmi); model.advance()
        XCTAssertEqual(model.step, .betterTranslation)
        XCTAssertTrue(model.canAdvance)
        model.advance()
        XCTAssertEqual(model.step, .test); model.advance()
        XCTAssertEqual(model.step, .done)
        model.step = .betterTranslation; model.back()
        XCTAssertEqual(model.step, .hdmi); model.back()
        XCTAssertEqual(model.step, .tv)
    }

    /// "Daha iyi çeviri" adımı isteğe bağlıdır: geçilirse ücretsiz çeviri kalır; anahtar kabul edilirse Gemini seçilir.
    func testBetterTranslationStepCanBeSkipped() {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        model.step = .betterTranslation
        XCTAssertFalse(model.usesFreeGemini)
        XCTAssertTrue(model.canAdvance)
        model.advance()
        XCTAssertEqual(model.step, .test)
        XCTAssertEqual(model.settings.translationEngine, .free)
        model.back()
        XCTAssertEqual(model.step, .betterTranslation)
        // TV yok: TV girişi adımı atlanır.
        model.back()
        XCTAssertEqual(model.step, .tv)
    }

    func testBetterTranslationStepSavesTheKeyAndSelectsGemini() async {
        let services = FakeServices()
        let store = MemoryStore()
        let model = AppModel(services: services, store: store, defaults: .isolated())
        model.step = .betterTranslation
        let result = await model.setAIKey("  AIza-free  ", for: .gemini)
        XCTAssertEqual(result, .success("KRATOS: Gidiyoruz."))
        XCTAssertEqual(services.aiTests.first?.provider, .gemini)
        XCTAssertEqual(services.aiTests.first?.key, "AIza-free")
        // Ücretsiz katmandaki varsayılan model denenir.
        XCTAssertEqual(services.aiTests.first?.model, AIProvider.gemini.defaultModel.id)
        XCTAssertTrue(AIProvider.gemini.defaultModel.freeTier)
        XCTAssertEqual(store.load(String.self, for: StoreKey.geminiKey), "AIza-free")
        XCTAssertEqual(model.settings.translationEngine, .gemini)
        XCTAssertTrue(model.usesFreeGemini)
        model.advance()
        XCTAssertEqual(model.step, .test)
        model.advance()
        XCTAssertEqual(model.step, .done)
    }

    func testSuccessfulClaudeCheckDoesNotReportKeySavedWhenStorageRejectsIt() async {
        let store = MemoryStore()
        store.rejectedWrites.insert(StoreKey.claudeKey)
        let model = AppModel(services: FakeServices(), store: store, defaults: .isolated())

        let result = await model.setAIKey("example-claude-key", for: .claude)

        XCTAssertEqual(result, .failure(.keychainWriteFailed))
        XCTAssertFalse(model.hasKey(.claude))
        XCTAssertEqual(model.settings.translationEngine, .free)
    }

    /// Yerel model anahtarsız hazırdır; "Bağlantıyı dene" ayardaki adres ve modelle gider, yazılan anahtarı yalnız sunucu
    /// kabul ederse saklar; anahtar kaldırılınca yerel model seçili kalır.
    func testLocalModelNeedsNoKey() async {
        let services = FakeServices()
        let store = MemoryStore()
        let model = AppModel(services: services, store: store, defaults: .isolated())
        model.settings.translationEngine = .local
        XCTAssertTrue(model.isReady(.local))
        XCTAssertTrue(model.onlineTranslationActive)
        XCTAssertFalse(model.hasKey(.local))

        model.settings.localAIBaseURL = LocalAIServer.lmStudioURL
        model.settings.localAIModel = " qwen2.5-7b-instruct "
        let result = await model.testLocalAI()
        XCTAssertEqual(result, .success("KRATOS: Gidiyoruz."))
        XCTAssertEqual(services.localTests.first?.server.chatURL.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
        XCTAssertEqual(services.localTests.first?.server.model, "qwen2.5-7b-instruct")
        XCTAssertEqual(services.localTests.first?.key, "")
        XCTAssertNil(store.load(String.self, for: StoreKey.localAIKey))

        services.aiResult = .failure(.invalidKey)
        _ = await model.testLocalAI(key: "wrong")
        XCTAssertFalse(model.hasKey(.local))
        services.aiResult = .success("KRATOS: Gidiyoruz.")
        _ = await model.testLocalAI(key: " lm-key ")
        XCTAssertEqual(store.load(String.self, for: StoreKey.localAIKey), "lm-key")
        XCTAssertEqual(model.settings.translationEngine, .local)
        _ = await model.testLocalAI()
        XCTAssertEqual(services.localTests.last?.key, "lm-key")

        model.removeKey(.local)
        XCTAssertFalse(model.hasKey(.local))
        XCTAssertEqual(model.settings.translationEngine, .local)

        // Geçersiz adreste yerel model hazır sayılmaz; çeviri ücretsiz motorla sürer.
        model.settings.localAIBaseURL = "ftp://nowhere"
        XCTAssertFalse(model.onlineTranslationActive)
        let invalid = await model.testLocalAI()
        XCTAssertEqual(invalid, .failure(.unreachable))
    }

    /// Yanlış anahtar kaydedilmez, motor değişmez; dakikalık sınıra takılan anahtar geçerlidir ve kaydedilir.
    func testBetterTranslationStepRejectsAWrongKey() async {
        let services = FakeServices()
        services.aiResult = .failure(.invalidKey)
        let model = AppModel(services: services, store: MemoryStore(), defaults: .isolated())
        model.step = .betterTranslation
        let result = await model.setAIKey("wrong", for: .gemini)
        XCTAssertEqual(result, .failure(.invalidKey))
        XCTAssertFalse(model.hasKey(.gemini))
        XCTAssertEqual(model.settings.translationEngine, .free)
        XCTAssertFalse(model.usesFreeGemini)

        services.aiResult = .failure(.quotaExceeded)
        _ = await model.setAIKey("AIza-busy", for: .gemini)
        XCTAssertTrue(model.usesFreeGemini)
    }

    /// Ayarlardaki "Ücretsiz anahtar al" Gemini'yi seçer; anahtar gelene dek ücretsiz çeviri sürer.
    func testChooseFreeGeminiSelectsGeminiWithoutAKey() {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        model.chooseFreeGemini()
        XCTAssertEqual(model.settings.translationEngine, .gemini)
        XCTAssertFalse(model.onlineTranslationActive)
        XCTAssertFalse(model.usesFreeGemini)
    }

    /// Yeni metinler ortak metin dosyasında Türkçesiyle durur (Windows da aynı dosyayı okur).
    func testFreeGeminiStringsAreTranslated() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CouchSubs/Resources/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let strings = root?["strings"] as? [String: Any] ?? [:]
        for key in ["Better translation (free)", "Get a free key", "Skip for now", "For better translation, get a free Gemini key.",
                    "Gemini is ready. Subtitles will be translated with Gemini.",
                    "Press Get a free key and sign in with your Google account.", "Press Create API key and copy the key.",
                    "Paste the key here and press Save and test.",
                    "The free translation works without the internet but often sounds stiff. Google's Gemini translates much more naturally, and a free Google key is enough.",
                    "Subtitle text is sent to Google. With a free key, Google may use it to improve its products, and people at Google may read it. Only the game's subtitles are sent.",
                    "The free key has a per-minute limit. When it is reached, that line is translated by the free translation."] {
            let entry = strings[key] as? [String: Any]
            let tr = ((entry?["localizations"] as? [String: Any])?["tr"] as? [String: Any])?["stringUnit"] as? [String: Any]
            XCTAssertNotNil(tr?["value"] as? String, key)
        }
    }

    /// Ölçüm satırı, bölge seçimleri ve geçmiş metinleri Türkçesiyle (çekirdekteki metinler Xcode'un taramasına girmez).
    func testMetricsAreaAndHistoryStringsAreTranslated() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CouchSubs/Resources/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let strings = root?["strings"] as? [String: Any] ?? [:]
        let expected = [
            "OCR %lld ms": "OCR %lld ms", "Translation %lld ms": "Çeviri %lld ms", "Ready pack": "Hazır paket",
            "Delay %lld ms": "Gecikme %lld ms", "Confidence %lld%%": "Güven %%%lld", "%lld%%": "%%%lld",
            "Bottom area": "Alt bölge", "Top area": "Üst bölge", "Full screen": "Tam ekran", "Custom": "Özel",
            "Vertical position": "Dikey konum", "Height": "Yükseklik", "Test on TV": "TV'de test et", "History": "Geçmiş",
            "Clear": "Temizle", "Pack": "Paket",
        ]
        for (key, value) in expected {
            let entry = strings[key] as? [String: Any]
            let tr = ((entry?["localizations"] as? [String: Any])?["tr"] as? [String: Any])?["stringUnit"] as? [String: Any]
            XCTAssertEqual(tr?["value"] as? String, value, key)
        }
    }

    func testClearingHistoryEmptiesTheList() {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        model.history.add(source: "Stay close, boy.", translation: "Yakın dur, evlat.")
        model.clearHistory()
        XCTAssertTrue(model.history.entries.isEmpty)
    }
}

@MainActor
final class AppModelRunTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TVInstallLog.testFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("CouchSubsTests-\(UUID().uuidString)/tvinstall.log")
    }

    override func tearDown() {
        if let file = TVInstallLog.testFile { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        TVInstallLog.testFile = nil
        super.tearDown()
    }

    private func readyModel(_ services: FakeServices) -> AppModel {
        let store = MemoryStore()
        store.save(Data(repeating: 1, count: 8), for: StoreKey.accountId)
        store.save(RegisteredConsole(host: "192.168.1.253", name: "PS5", registKey: Data(repeating: 0x31, count: 16), morning: Data(repeating: 2, count: 16)), for: StoreKey.console)
        store.save(LGTV(name: "LG TV", host: "127.0.0.1"), for: StoreKey.tv)
        store.save("tv-key", for: StoreKey.tvKey)
        return AppModel(services: services, store: store, defaults: .isolated())
    }

    /// Mobil sürümü deneyen kullanıcı (21 Kas): "ilk başta olmadı, TV'den de uygulamayı açmak lazımmış". Bekçinin açma
    /// sonucu ana ekrana gelir; "Otomatik açmayı dene" bekçiyi beklemeden yeniden denetir.
    func testAutoOpenProblemIsShownAndRetried() async throws {
        let services = FakeServices()
        let model = readyModel(services)
        model.settings.output = .tv
        await model.start()
        let keeper = try XCTUnwrap(services.keepers.first)
        services.onOpenResult?(.unreachable)
        for _ in 0..<50 where model.tvOpenProblem == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.tvOpenProblem, .unreachable)
        model.retryTVOpen()
        XCTAssertNil(model.tvOpenProblem)
        XCTAssertEqual(keeper.reconnects, 1)
        model.stop()
        XCTAssertNil(model.tvOpenProblem)
    }

    /// Bekçi TV'yi yeni adreste bulunca (onMoved) açma sonucu yine ana ekrana gelir; yalnız yerine yenisi kurulan
    /// bekçinin geç sonucu yok sayılır (#985).
    func testOpenResultOfAMovedKeeperIsStillShown() async throws {
        let services = FakeServices()
        let model = readyModel(services)
        model.settings.output = .tv
        await model.start()
        services.onMoved?(LGTV(name: "LG TV", host: "127.0.0.2"))
        for _ in 0..<50 where model.tv?.host != "127.0.0.2" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.tv?.host, "127.0.0.2")
        services.onOpenResult?(.unreachable)
        for _ in 0..<50 where model.tvOpenProblem == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.tvOpenProblem, .unreachable)
        XCTAssertEqual(services.keepers.count, 1)
        model.stop()
    }

    func testDoubleStartCreatesOneSession() async {
        let services = FakeServices()
        let model = readyModel(services)
        async let first: Void = model.start()
        async let second: Void = model.start()
        _ = await (first, second)
        XCTAssertEqual(services.streams.count, 1)
        XCTAssertEqual(services.keepers.count, 1)
        XCTAssertTrue(model.isRunning)
        model.stop()
    }

    /// Bağlantı kopunca uygulamayı kapatıp açmak gerekmiyor: "Yeniden bağlan" süren denemelerde 45 sn sonra görünür,
    /// konsol oturumu yeniden kurulur, çeviri sürer; kapatılan eski oturumun geç gelen durumu yenisini ezmez (iPhone,
    /// Android ve Windows ile aynı).
    func testReconnectOfferAndReconnectKeepTranslating() async throws {
        let services = FakeServices()
        let model = readyModel(services)
        await model.start()
        defer { model.stop() }
        let first = try XCTUnwrap(services.streams.first)
        first.onState?(.streaming)
        for _ in 0..<50 where model.sessionState != .streaming { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.offersReconnect(now: Date().addingTimeInterval(600)))
        let dropped = Date()
        first.onState?(.disconnected(.network))
        for _ in 0..<50 where model.sessionState == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.offersReconnect(now: dropped.addingTimeInterval(30)))
        XCTAssertTrue(model.offersReconnect(now: dropped.addingTimeInterval(ReconnectOffer.after + 1)))

        let keeperReconnects = services.keepers.map(\.reconnects).reduce(0, +)
        model.reconnect()
        XCTAssertEqual(services.streams.count, 2)
        let second = services.streams[1]
        XCTAssertFalse(first.started)
        XCTAssertTrue(second.started)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.sessionState, .connecting)
        XCTAssertFalse(model.offersReconnect(now: Date().addingTimeInterval(30)))
        XCTAssertEqual(services.keepers.map(\.reconnects).reduce(0, +), keeperReconnects + 1)

        first.onState?(.disconnected(.stopped))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.sessionState, .connecting, "eski oturumun geç gelen durumu yenisini ezmez")
        second.onState?(.streaming)
        for _ in 0..<50 where model.sessionState != .streaming { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.sessionState, .streaming)
    }

    /// Oturum yeniden denemeyi bıraktıysa düğme hemen görünür; uykudan uyanınca yeni oturum açılır (kayıt ya da giriş
    /// şifresi sorununda açılmaz).
    func testGivenUpSessionOffersReconnectAndWakeReopensIt() async throws {
        let services = FakeServices()
        let model = readyModel(services)
        await model.start()
        defer { model.stop() }
        let stream = try XCTUnwrap(services.streams.first)
        model.systemWoke()
        XCTAssertEqual(services.streams.count, 1)
        XCTAssertEqual(stream.reconnects, 1)

        stream.hasGivenUp = true
        stream.onState?(.disconnected(.loginPasscodeIncorrect))
        for _ in 0..<50 where model.sessionState == .connecting || model.sessionState == .disconnected(.stopped) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.offersReconnect())
        model.systemWoke()
        XCTAssertEqual(services.streams.count, 1, "yanlış şifre yeniden gönderilmez")

        stream.onState?(.disconnected(.consoleRemotePlayCrashed))
        for _ in 0..<50 where model.sessionState != .disconnected(.consoleRemotePlayCrashed) { try await Task.sleep(for: .milliseconds(10)) }
        model.systemWoke()
        XCTAssertEqual(services.streams.count, 2)
    }

    func testReconnectsOnReturnUnlessRetryingEndsTheSameWay() {
        for reason in [DisconnectReason.registrationInvalid, .loginPasscode, .loginPasscodeIncorrect, .stopped, .consoleClosedRepeatedly] {
            XCTAssertFalse(AppModel.reconnectsOnReturn(after: .disconnected(reason)), "\(reason)")
        }
        for reason in [DisconnectReason.consoleRemotePlayCrashed, .noPicture, .network, .reconnectGaveUp] {
            XCTAssertTrue(AppModel.reconnectsOnReturn(after: .disconnected(reason)), "\(reason)")
        }
        XCTAssertTrue(AppModel.reconnectsOnReturn(after: .connecting))
    }

    /// #40: bekçinin bağlantısında TV yeni jeton verirse saklanır; sonraki açılışta TV yeniden izin sormaz.
    func testKeeperSavesNewTvToken() async throws {
        let services = FakeServices()
        let store = MemoryStore()
        store.save(Data(repeating: 1, count: 8), for: StoreKey.accountId)
        store.save(RegisteredConsole(host: "192.168.1.253", name: "PS5", registKey: Data(repeating: 0x31, count: 16), morning: Data(repeating: 2, count: 16)), for: StoreKey.console)
        store.save(LGTV(name: "Samsung", host: "127.0.0.1", brand: .samsung), for: StoreKey.tv)
        store.save("", for: StoreKey.tvKey)
        let model = AppModel(services: services, store: store, defaults: .isolated())
        await model.start()
        let onKey = try XCTUnwrap(services.onKey)
        onKey("new-token")
        await Task.yield()
        for _ in 0..<20 where store.load(String.self, for: StoreKey.tvKey) != "new-token" { await Task.yield() }
        XCTAssertEqual(store.load(String.self, for: StoreKey.tvKey), "new-token")
        model.stop()
    }

    /// Ayarlar'daki PS5 giriş şifresi oturuma verilir; yalnız 4 hane kaydedilir, kurulum sıfırlanınca silinir.
    func testLoginPasscodeIsSavedAndPassedToTheSession() async {
        let services = FakeServices()
        let model = readyModel(services)
        XCTAssertFalse(model.hasLoginPasscode)
        XCTAssertFalse(model.setLoginPasscode("12a4"))
        XCTAssertFalse(model.hasLoginPasscode)
        XCTAssertTrue(model.setLoginPasscode(" 4321 "))
        XCTAssertTrue(model.hasLoginPasscode)
        await model.start()
        XCTAssertEqual(services.streamPasscodes, ["4321"])
        model.stop()
        model.removeLoginPasscode()
        XCTAssertFalse(model.hasLoginPasscode)
        await model.start()
        XCTAssertEqual(services.streamPasscodes, ["4321", nil])
        model.stop()
        XCTAssertTrue(model.setLoginPasscode("1111"))
        model.resetSetup()
        XCTAssertFalse(model.hasLoginPasscode)
    }

    func testRunningPreventsIdleSleep() async {
        let model = readyModel(FakeServices())
        await model.start()
        XCTAssertTrue(model.isPreventingSleep)
        model.stop()
        XCTAssertFalse(model.isPreventingSleep)
    }

    func testDisconnectClearsSubtitleOnTV() async throws {
        let services = FakeServices()
        let model = readyModel(services)
        await model.start()
        defer { model.stop() }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(model.serverPort)/events")!)
        try await Task.sleep(nanoseconds: 200_000_000)
        services.streams[0].onState?(.disconnected(.network))
        var sawClear = false
        for try await line in bytes.lines where line == "event: clear" { sawClear = true; break }
        XCTAssertTrue(sawClear)
    }

    func testTranslatorStatusFollowsPipeline() {
        XCTAssertEqual(AppModel.translatorStatus(after: nil), .ready)
        XCTAssertEqual(AppModel.translatorStatus(after: .needsDownload), .needsDownload)
        XCTAssertEqual(AppModel.translatorStatus(after: .unsupported), .unsupported)
    }

    func testSettingsGoToPreferencesNotKeychain() {
        let store = MemoryStore()
        let defaults = TestDefaults.make("couchsubs-test")
        let model = AppModel(services: FakeServices(), store: store, defaults: defaults)
        model.settings.style.fontSize = 58
        XCTAssertNil(store.values[StoreKey.settings])
        XCTAssertEqual(AppModel(services: FakeServices(), store: store, defaults: defaults).settings.style.fontSize, 58)
    }

    func testChangingLanguageWhileRunningRebuildsPipeline() async {
        let model = readyModel(FakeServices())
        await model.start()
        defer { model.stop() }
        XCTAssertEqual(model.activeLanguages?.source, "en")
        model.settings.sourceLanguage = "ja"
        XCTAssertEqual(model.activeLanguages?.source, "ja")
    }

    /// Çeviri başlamamışken bağlı olmamak bir uyarı değildir; nokta gri kalır.
    func testStatusToneIsIdleUntilTranslationStarts() {
        XCTAssertEqual(AppModel.ps5Tone(.disconnected(.stopped), running: false), .idle)
        XCTAssertEqual(AppModel.ps5Tone(.disconnected(.network), running: true), .warning)
        XCTAssertEqual(AppModel.ps5Tone(.connecting, running: true), .warning)
        XCTAssertEqual(AppModel.ps5Tone(.streaming, running: true), .good)
        XCTAssertEqual(AppModel.tvTone(clients: 0, running: false), .idle)
        XCTAssertEqual(AppModel.tvTone(clients: 0, running: true), .warning)
        XCTAssertEqual(AppModel.tvTone(clients: 1, running: false), .good)
    }

    func testLoginPasscodeIsExplained() {
        XCTAssertEqual(AppModel.statusText(.disconnected(.loginPasscode), running: true),
                       String(localized: "The PS5 asks for this account's login passcode. Enter it in Settings, or turn off this account's login passcode on the PS5."))
        XCTAssertEqual(AppModel.statusText(.disconnected(.loginPasscodeIncorrect), running: true),
                       String(localized: "The PS5 didn't accept the login passcode in Settings. Correct it, or turn off this account's login passcode on the PS5."))
    }

    /// X, 21 Kas: PS5 akışı kendisi kapatınca (oyun sırasında kullanıcı değişti) "kabloyla bağlayın" değil, nedeni söylenir.
    func testConsoleClosedStatusNamesUserSwitch() {
        XCTAssertEqual(AppModel.statusText(.disconnected(.consoleClosed("x")), running: true),
                       String(localized: "The PS5 ended Remote Play. This usually happens when the user is switched on the PS5 during the game. Reconnecting…"))
    }

    /// GitHub #353: PS5 yeniden bağlanmadan sonra da kapatınca durulur; ana hesapla oynaması söylenir.
    func testStoppedReconnectingIsExplained() {
        XCTAssertEqual(AppModel.statusText(.disconnected(.consoleClosedRepeatedly), running: true),
                       String(localized: "The PS5 ended Remote Play. While playing, choose your own main account on the PS5; don't play with the second account CouchSubs uses."))
        XCTAssertEqual(AppModel.statusText(.disconnected(.reconnectGaveUp), running: true),
                       String(localized: "The connection to the PS5 kept dropping, so reconnecting stopped. Make sure the PS5 is on and on the same network, then press Reconnect."))
    }

    /// GitHub #519: İngilizce "Remote Play on Console has crashed" yerine yerelleştirilmiş yönlendirme.
    func testConsoleRemotePlayCrashIsExplained() {
        XCTAssertEqual(AppModel.statusText(.disconnected(.consoleRemotePlayCrashed), running: true),
                       String(localized: "Remote Play on the PS5 has crashed. Turn the PS5 off completely (not rest mode) and back on, then connect again."))
    }

    func testDisconnectReasonsAreExplained() {
        XCTAssertEqual(AppModel.statusText(.disconnected(.consoleAsleep), running: true), String(localized: "Turn on your PS5"))
        XCTAssertEqual(AppModel.statusText(.disconnected(.inUse), running: true), String(localized: "Remote Play is in use on another device"))
        XCTAssertEqual(AppModel.statusText(.disconnected(.refused), running: true), String(localized: "The PS5 did not accept the connection yet. It may still be starting up, or its network address may have changed. Reconnecting and searching for the PS5… If this keeps happening, make sure the PS5 is on and on the same network."))
        XCTAssertEqual(AppModel.statusText(.disconnected(.network), running: true),
                       String(localized: "Lost the connection to the PS5. Reconnecting… If this keeps happening, connect the PS5 to the router with a cable."))
        // 0x80108b12: PS5'te Uzaktan Oynatma kapalı (GitHub #9); genel "başka Remote Play açık olabilir" metni yanıltıyordu.
        let disabled = AppModel.statusText(.disconnected(.rejected(DisconnectReason.remotePlayDisabled)), running: true)
        XCTAssertTrue(disabled.contains("0x80108b12"))
        XCTAssertNotEqual(disabled, AppModel.statusText(.disconnected(.rejected(0x80108bff)), running: true))
        XCTAssertEqual(AppModel.statusText(.disconnected(.registrationInvalid), running: true),
                       String(localized: "The PS5 didn't accept this pairing. Pair the PS5 again with the second account in Settings."))
        // PS5 oturum isteğini reddetti: kod metinde, libchiaki'nin "Unknown Session Request Error"u değil (GitHub #33, #202).
        let rejected = AppModel.statusText(.disconnected(.rejected(0x80108bff)), running: true)
        XCTAssertTrue(rejected.contains("0x80108bff"))
        XCTAssertFalse(rejected.contains("Unknown Session Request"))
        XCTAssertFalse(AppModel.statusText(.disconnected(.rejected(nil)), running: true).contains("Unknown Session Request"))
        XCTAssertTrue(AppModel.statusText(.disconnected(.notFound("192.168.1.70")), running: true).contains("192.168.1.70"))
        XCTAssertTrue(AppModel.statusText(.disconnected(.other("Session Request RP Version Mismatch")), running: true)
            .contains("Session Request RP Version Mismatch"))
        XCTAssertEqual(AppModel.statusText(.disconnected(.other("")), running: true), String(localized: "Reconnecting…"))
        XCTAssertEqual(AppModel.statusText(.disconnected(.stopped), running: false), String(localized: "Not connected"))
    }

    /// Eşleştirme başarılıyken çeviri başlamadan ana ekran "Bağlı değil" demez (kullanıcı PS5'i bağlanmamış sanıyordu).
    func testPairedConsoleIsNotShownAsDisconnectedBeforeStart() async throws {
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: .isolated())
        XCTAssertEqual(model.ps5StatusText, String(localized: "Not connected"))
        model.accountId = Data(repeating: 1, count: 8)
        try await model.register(host: "192.168.1.70", pin: "12345678")
        XCTAssertEqual(model.ps5StatusText,
                       String(format: String(localized: "Paired with %@. Connects when you start translating."), "PS5-789"))
    }

    /// PS5 yeni adreste bulununca adres kaydedilir; sonraki açılış yeni adresle başlar.
    func testMovedConsoleIsSaved() async throws {
        let services = FakeServices()
        let store = MemoryStore()
        let model = AppModel(services: services, store: store, defaults: .isolated())
        model.accountId = Data(repeating: 1, count: 8)
        try await model.register(host: "192.168.1.70", pin: "12345678")
        model.settings.output = .computer
        await model.start()
        let moved = RegisteredConsole(host: "192.168.1.71", name: "PS5-789", registKey: Data(repeating: 0x31, count: 16),
                                      morning: Data(repeating: 2, count: 16))
        services.streams.first?.onConsoleMoved?(moved)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.console?.host, "192.168.1.71")
        XCTAssertEqual(store.load(RegisteredConsole.self, for: StoreKey.console)?.host, "192.168.1.71")
        model.stop()
    }

    /// Ayarlar'da "IP Adresi Gir": PS5'in yeni adresi elle yazılır, kaydedilir ve yeni adresle yeniden bağlanılır.
    func testEnteredConsoleAddressIsSavedAndReconnects() async throws {
        let services = FakeServices()
        let store = MemoryStore()
        let model = AppModel(services: services, store: store, defaults: .isolated())
        model.accountId = Data(repeating: 1, count: 8)
        try await model.register(host: "192.168.1.70", pin: "12345678")
        model.settings.output = .computer
        await model.start()
        XCTAssertFalse(model.enterConsoleAddress("192.168.1.300"))
        XCTAssertEqual(model.console?.host, "192.168.1.70")
        XCTAssertTrue(model.enterConsoleAddress("192.168.1.72"))
        XCTAssertEqual(model.console?.host, "192.168.1.72")
        XCTAssertEqual(model.console?.name, "PS5-789")
        XCTAssertEqual(store.load(RegisteredConsole.self, for: StoreKey.console)?.host, "192.168.1.72")
        model.stop()
    }
}

final class LocalizationTests: XCTestCase {
    private func strings(_ language: String) throws -> [String: String] {
        let bundle = Bundle(for: AppModel.self)
        let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language), language)
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    func testTurkishCoversEveryEnglishKey() throws {
        let english = try strings("en"), turkish = try strings("tr")
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys).subtracting(turkish.keys), [])
        XCTAssertTrue(turkish.values.allSatisfy { !$0.isEmpty })
    }
}

@MainActor
final class TVAppInstallTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TVInstallLog.testFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("CouchSubsTests-\(UUID().uuidString)/tvinstall.log")
    }

    override func tearDown() {
        if let file = TVInstallLog.testFile { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        TVInstallLog.testFile = nil
        super.tearDown()
    }

    private let tv = LGTV(name: "LG TV", host: "192.168.1.153")

    private func model(_ services: FakeServices, store: MemoryStore = MemoryStore()) -> AppModel {
        AppModel(services: services, store: store, defaults: .isolated())
    }

    func testMissingAppWithDevModeOffShowsTheSteps() async throws {
        let services = FakeServices()
        services.appOnTV = nil
        let model = model(services)
        try await model.pair(tv)
        XCTAssertEqual(model.tvApp, .devModeOff)
        XCTAssertNotNil(model.tv, "Eşleşme uygulama olmadan da kaydedilir")
    }

    func testTurningDevModeOnAsksForThePassphrase() async throws {
        let services = FakeServices()
        services.appOnTV = nil
        let model = model(services)
        try await model.pair(tv)
        services.devMode = true
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: nil))
    }

    func testPassphraseInstallsAndOpensTheApp() async throws {
        let services = FakeServices()
        services.appOnTV = nil
        services.devMode = true
        let store = MemoryStore()
        let model = model(services, store: store)
        try await model.pair(tv)
        let pairs = services.pairCount
        await model.installTVApp(passphrase: " ABC123 ")
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
        XCTAssertEqual(services.installs, 1)
        XCTAssertEqual(store.load(String.self, for: StoreKey.tvDevKey), "dev-key")
        XCTAssertEqual(services.pairCount, pairs + 1, "Kurulumdan sonra TV uygulaması açılır")
    }

    func testWrongPassphraseAsksAgain() async throws {
        let services = FakeServices()
        services.appOnTV = nil
        services.devMode = true
        let model = model(services)
        try await model.pair(tv)
        await model.installTVApp(passphrase: "WRONG")
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: .wrongPassphrase))
        XCTAssertEqual(services.installs, 0)
    }

    func testClosedKeyServerIsExplained() async throws {
        let services = FakeServices()
        services.appOnTV = nil
        services.devMode = true
        services.keyServer = false
        let model = model(services)
        try await model.pair(tv)
        await model.installTVApp(passphrase: "ABC123")
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: .keyServerOff))
    }

    // MARK: TV'nin adresi değişince (beta.89: 192.168.1.238 → .156; "Key Server kapalı" deniyordu)

    private func movedTVServices() -> FakeServices {
        let services = FakeServices()
        services.appOnTV = nil
        services.devMode = true
        services.silentHosts = ["192.168.1.153"]
        services.tvs = [LGTV(name: "LG TV", host: "192.168.1.156")]
        return services
    }

    func testPassphraseFollowsTheTVToItsNewAddress() async throws {
        let services = movedTVServices()
        // Eşleşirken TV eski adresteydi; parola yazılırken adresi değişmiş.
        services.silentHosts = []
        let model = model(services)
        try await model.pair(tv)
        services.silentHosts = ["192.168.1.153"]
        await model.installTVApp(passphrase: "ABC123")
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
        XCTAssertEqual(model.tv?.host, "192.168.1.156")
        XCTAssertEqual(services.keyHosts, ["192.168.1.153", "192.168.1.156"])
        XCTAssertTrue(TVInstallLog.tail().contains("TV yeni adreste bulundu: 192.168.1.153 → 192.168.1.156"), TVInstallLog.tail())
    }

    func testSilentTVThatIsNotFoundIsNotCalledKeyServerOff() async throws {
        let services = movedTVServices()
        services.tvs = []
        let model = model(services)
        try await model.pair(tv)
        await model.installTVApp(passphrase: "ABC123")
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: .tvNotResponding))
        XCTAssertEqual(model.tv?.host, "192.168.1.153")
        XCTAssertTrue(TVInstallLog.tail().contains(TVReach.notRespondingLine), TVInstallLog.tail())
    }

    func testAnsweringTVWithClosedKeyServerIsStillKeyServerOff() async throws {
        let services = FakeServices()
        services.appOnTV = nil
        services.devMode = true
        services.keyServer = false
        services.tvs = [LGTV(name: "LG TV", host: "192.168.1.156")]
        let model = model(services)
        try await model.pair(tv)
        await model.installTVApp(passphrase: "ABC123")
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: .keyServerOff))
        XCTAssertEqual(model.tv?.host, "192.168.1.153", "Yanıt veren TV'nin adresi değiştirilmez")
    }

    /// Ana ekrandaki "TV uygulamasını güncelle" de aynı yeniden bulma adımından geçer.
    func testUpdateFromHomeFollowsTheTVToItsNewAddress() async throws {
        let services = movedTVServices()
        let store = MemoryStore()
        let model = model(services, store: store)
        try await model.pair(tv)
        store.save("dev-key", for: StoreKey.tvDevKey)
        await model.updateTVApp()
        XCTAssertEqual(model.tv?.host, "192.168.1.156")
        XCTAssertEqual(store.load(LGTV.self, for: StoreKey.tv)?.host, "192.168.1.156")
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
        XCTAssertEqual(services.installs, 1)
    }

    func testUpdateFromHomeWithSilentTVSaysItIsNotResponding() async throws {
        let services = movedTVServices()
        services.tvs = []
        let model = model(services)
        try await model.pair(tv)
        await model.updateTVApp()
        XCTAssertEqual(model.tvApp, .failed(.tvNotResponding))
        XCTAssertTrue(TVInstallLog.tail().contains(TVReach.notRespondingLine), TVInstallLog.tail())
    }

    /// Eşli TV kartı: "TV'yi Eşleştir" / "Deneme Altyazısı Gönder" ulaşamazsa açık hata; "TV'yi Yeniden Ara" düzeltir.
    func testCardShowsUnreachableErrorAndSearchAgainFindsTheTV() async throws {
        let services = movedTVServices()
        let found = services.tvs
        services.tvs = []
        let model = model(services)
        try await model.pair(tv)
        let reachable = await model.ensureTVReachable()
        XCTAssertFalse(reachable)
        XCTAssertEqual(model.tvUnreachableHost, "192.168.1.153")
        XCTAssertEqual(model.tvStatusText, String(localized: "Not responding — searching again…"))
        services.tvs = found
        let again = await model.searchTVAgain()
        XCTAssertTrue(again)
        XCTAssertNil(model.tvUnreachableHost)
        XCTAssertEqual(model.tv?.host, "192.168.1.156")
        XCTAssertFalse(model.tvNotResponding)
    }

    /// Kendiliğinden yeniden bulma ağı en çok 30 sn'de bir arar; bulunca adresi günceller.
    func testCardCheckFindsMovedTVAndThrottlesSearches() async throws {
        let services = movedTVServices()
        let found = services.tvs
        services.tvs = []
        let model = model(services)
        try await model.pair(tv)
        await model.checkTVReachable()
        XCTAssertTrue(model.tvNotResponding)
        services.tvs = found
        await model.checkTVReachable()
        XCTAssertEqual(model.tv?.host, "192.168.1.153", "30 sn dolmadan ağ yeniden aranmaz")
        _ = await model.searchTVAgain()
        XCTAssertEqual(model.tv?.host, "192.168.1.156")
    }

    func testEnteredAddressMovesThePairedTVAndKeepsItsKey() async throws {
        let services = movedTVServices()
        let store = MemoryStore()
        let model = model(services, store: store)
        try await model.pair(tv)
        let rejected = await model.useTVAddress("http://")
        XCTAssertFalse(rejected)
        XCTAssertTrue(model.tvAddressRejected)
        let used = await model.useTVAddress("192.168.1.156")
        XCTAssertTrue(used)
        XCTAssertEqual(model.tv, LGTV(name: "LG TV", host: "192.168.1.156"))
        XCTAssertEqual(store.load(String.self, for: StoreKey.tvKey), "tv-key")
        XCTAssertTrue(model.hasTV)
    }

    func testRemovePairingForgetsTheTV() async throws {
        let services = FakeServices()
        let store = MemoryStore()
        let model = model(services, store: store)
        try await model.pair(tv)
        model.removeTVPairing()
        XCTAssertNil(model.tv)
        XCTAssertFalse(model.hasTV)
        XCTAssertNil(store.load(LGTV.self, for: StoreKey.tv))
        XCTAssertNil(store.load(String.self, for: StoreKey.tvKey))
        XCTAssertFalse(model.settings.output.showsOnTV)
    }

    func testFailedInstallShowsTheTVsReason() async throws {
        let services = FakeServices()
        services.appOnTV = nil
        services.devMode = true
        services.lgInstallError = DevModeFailure(.installFailed, detail: "Invalid package (errorCode -5)")
        let model = model(services)
        try await model.pair(tv)
        await model.installTVApp(passphrase: "ABC123")
        XCTAssertEqual(model.tvApp, .failed(.installFailed, reason: "Invalid package (errorCode -5)"))
        // Boş alan yalnız TV öyle dediğinde suçlanır.
        XCTAssertFalse(TVAppCard.message(for: .installFailed, brand: .lg, reason: "Invalid package").contains("free space"))
        XCTAssertTrue(TVAppCard.message(for: .installFailed, brand: .lg, reason: "Invalid package").contains(String(localized: "TV says:") + " Invalid package"))
    }

    /// LG "ipk verified failed" (-5): saat çok gerideyse saati düzeltme adımları, değilse doğrulama ipucu; Samsung'un saat
    /// metni değişmez (iPhone, Windows, Android aynı).
    func testLgVerifyFailureGivesClockSteps() {
        let clockSteps = String(localized: "The TV's date and time are wrong, so it rejected the TV app package (ipk verified failed). On the TV, open Settings › General › System › Time & Timer › Time, turn off Set Automatically, enter today's date and time, then restart the TV and try again.")
        let verifyHint = String(localized: "The TV could not verify the TV app package (ipk verified failed). Check that the TV's date and time are right (Settings › General › System › Time & Timer), unplug the TV for 30 seconds, plug it back in and try again. If it fails again, send us the reason below.")
        let clock = TVAppCard.message(for: .tvClockWrong, brand: .lg, reason: "ipk verified failed (errorCode -5); TV saati 2020-01-01 00:23:49 UTC")
        XCTAssertTrue(clock.hasPrefix(clockSteps))
        XCTAssertTrue(clock.contains("2020-01-01 00:23:49"))
        XCTAssertTrue(TVAppCard.message(for: .installFailed, brand: .lg, reason: "ipk verified failed (errorCode -5); TV saati okunamadı").hasPrefix(verifyHint))
        XCTAssertFalse(TVAppCard.message(for: .tvClockWrong, brand: .samsung, reason: nil).contains("ipk"))
    }

    /// Samsung kısa basışta tam kapanmaz: "yeniden başlatın" diyen hatada güç tuşunun basılı tutulacağı yazar. Kurulum
    /// sırasında bağlantı koparsa HDMI-CEC (Anynet+) ve otomatik kaynak değiştirme anlatılır.
    func testSamsungFailureExplainsRestartAndSourceSwitching() {
        // Bilgisayarın diline göre İngilizce ya da Türkçe gelir; ipucu metni de aynı dilde aranır.
        let restart = String(localized: "To restart a Samsung TV fully, hold the power button on the remote until the TV turns off and comes back on with the Samsung logo (about 5 seconds), or unplug it for 30 seconds. Letting go when it turns off only puts it on standby.")
        let unreachable = TVAppCard.message(for: .unreachable, brand: .samsung, reason: nil)
        XCTAssertTrue(unreachable.contains(restart))
        XCTAssertFalse(unreachable.contains("Anynet+"))
        let dropped = TVAppCard.message(for: .connectionLost, brand: .samsung, reason: nil)
        XCTAssertTrue(dropped.contains("Anynet+ (HDMI-CEC)"))
        XCTAssertFalse(dropped.contains(restart))
        XCTAssertFalse(TVAppCard.message(for: .unreachable, brand: .lg, reason: nil).contains(restart))
    }

    /// "IP hatası" (#1158): Samsung kurulum bağlantısını reddedince metin menüyü, iki ayarı ve bu Mac'in adresini söyler.
    func testSamsungUnreachableGivesHostPcStepsWithThisAddress() {
        let text = TVAppCard.message(for: .unreachable, brand: .samsung, reason: nil, address: "192.168.1.34")
        XCTAssertTrue(text.contains(TVAppCard.hostPcSteps("192.168.1.34")))
        XCTAssertTrue(text.contains("192.168.1.34"))
        XCTAssertTrue(text.contains("1 2 3 4 5"))
        XCTAssertTrue(TVAppCard.hostPcSteps(nil).contains("(?)"))
        XCTAssertFalse(TVAppCard.message(for: .unreachable, brand: .lg, reason: nil, address: "192.168.1.34").contains("192.168.1.34"))
    }

    /// TV'nin listesi CouchSubs'ın silindiğini söyleyince (#1158) bu Mac'in kurduğu sürümün kaydı silinir: kart artık
    /// "güncel" göstermez, kurulum adımları çıkar. Başka TV'nin bildirimi kaydı silmez.
    func testSamsungAppMissingForgetsTheInstalledVersion() {
        let services = FakeServices()
        let store = MemoryStore()
        let tv = LGTV(name: "Samsung", host: "192.168.1.40", brand: .samsung)
        store.save(tv, for: StoreKey.tv)
        store.save("0.9.80", for: StoreKey.tvAppVersion)
        let model = AppModel(services: services, store: store, defaults: .isolated())
        model.samsungAppMissing(host: "192.168.1.99")
        XCTAssertEqual(store.load(String.self, for: StoreKey.tvAppVersion), "0.9.80")
        model.samsungAppMissing(host: " 192.168.1.40 ")
        XCTAssertNil(store.load(String.self, for: StoreKey.tvAppVersion))
    }

    func testOlderAppIsUpdatedWithoutAsking() async throws {
        let services = FakeServices()
        services.appOnTV = "0.4.0"
        services.devMode = true
        let store = MemoryStore()
        store.save("dev-key", for: StoreKey.tvDevKey)
        let model = model(services, store: store)
        try await model.pair(tv)
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
        XCTAssertEqual(services.installs, 1)
    }

    func testCurrentAppIsNotReinstalled() async throws {
        let services = FakeServices()
        services.devMode = true
        let store = MemoryStore()
        store.save("dev-key", for: StoreKey.tvDevKey)
        let model = model(services, store: store)
        try await model.pair(tv)
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
        XCTAssertEqual(services.installs, 0)
    }

    func testRefusedKeyIsForgottenAndPassphraseAskedAgain() async throws {
        let services = FakeServices()
        services.devMode = true
        services.refuseKey = true
        let store = MemoryStore()
        store.save("old-key", for: StoreKey.tvDevKey)
        let model = model(services, store: store)
        try await model.pair(tv)
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: nil))
        XCTAssertNil(store.load(String.self, for: StoreKey.tvDevKey))
    }

    func testWorkingAppWithoutKeyAsksNothing() async throws {
        let services = FakeServices()
        services.devMode = true
        let model = model(services)
        try await model.pair(tv)
        XCTAssertEqual(model.tvApp, .unknown)
    }

    /// #884, #891: anahtar bu Mac'te yokken TV'deki LG uygulaması eski kalıyor, hiç uyarı çıkmıyordu. TV sürümünü
    /// altyazı akışıyla bildirir (bildirmeyen eski sayılır); ana ekran "TV uygulamasını güncelle" der.
    func testOldLGAppReportedOnTheStreamAsksForAnUpdate() async throws {
        let services = FakeServices()
        services.devMode = true
        let model = model(services)
        try await model.pair(tv)
        XCTAssertEqual(model.tvApp, .unknown)
        model.tvAppReported("")
        XCTAssertEqual(model.tvAppOutdated, TVAppOutdated(installed: TVAppOutdated.unreported, bundled: "0.6.1"))
        model.tvAppReported("0.5.0")
        XCTAssertEqual(model.tvAppOutdated, TVAppOutdated(installed: "0.5.0", bundled: "0.6.1"))
        let step = model.step
        await model.updateTVApp()
        XCTAssertEqual(model.step, step, "TV adımına (eşleştirme/test) gidilmez")
        XCTAssertTrue(model.tvAppUpdating, "İlerleme ana ekrandaki kartta")
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: nil))
        await model.installTVApp(passphrase: "ABC123")
        XCTAssertEqual(services.installs, 1)
        XCTAssertNil(model.tvAppOutdated)
        model.tvAppReported("0.6.1")
        XCTAssertNil(model.tvAppOutdated)
    }

    /// İki TV'li ev (X, beta.105): seçili TV LG, altyazı aynı ağdaki Android TV'nin eski uygulamasına gidiyor. Öbür TV'nin
    /// bildirdiği sürüm LG'ninki sayılmaz: LG için güncelleme önerilmez, kurulmaya çalışılmaz. LG'nin kendi bildirimi sayılır.
    func testOtherTVsReportDoesNotAskToUpdateTheSelectedTV() async throws {
        let services = FakeServices()
        services.devMode = true
        let model = model(services)
        try await model.pair(tv)
        model.tvAppReported("0.5.0", from: "192.168.1.41")
        XCTAssertNil(model.tvAppOutdated)
        XCTAssertEqual(services.installs, 0)
        model.tvAppReported("0.5.0", from: "192.168.1.153")
        XCTAssertEqual(model.tvAppOutdated, TVAppOutdated(installed: "0.5.0", bundled: "0.6.1"))
    }

    /// Eski TV uygulaması bağlı (eksik değil) ve geliştirici modu kapalı: TV adımında Developer Mode adımları görünür.
    /// Önceden kart boş kalıyor (`.unknown`), "TV uygulamasını güncelle" yalnız eşleştirme/test gösteriyordu (döngü).
    func testOldLGAppWithDevModeOffShowsTheDevModeSteps() async throws {
        let services = FakeServices()
        let model = model(services)
        try await model.pair(tv)
        XCTAssertEqual(model.tvApp, .unknown, "Güncel bilinen uygulamada kart boş")
        model.tvAppReported("")
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .devModeOff)
        let step = model.step
        await model.updateTVApp()
        XCTAssertEqual(model.step, step, "TV adımına (eşleştirme/test) gidilmez")
        XCTAssertTrue(model.tvAppUpdating, "İlerleme ana ekrandaki kartta")
        XCTAssertEqual(model.tvApp, .devModeOff)
        // TV adımının bekleme döngüsü yeniden denetler; kart boşalmaz.
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .devModeOff)
        services.devMode = true
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: nil))
    }

    // MARK: "TV uygulamasını güncelle" senaryoları (ana ekranda; TV adımına gidilmez, her adım tvinstall.log'da)

    private func updateScenario(_ services: FakeServices, key: Bool, reported: String? = "") async throws -> AppModel {
        let store = MemoryStore()
        if key { store.save("dev-key", for: StoreKey.tvDevKey) }
        let model = model(services, store: store)
        model.tv = tv
        model.tvClients = 1
        if let reported { model.tvAppReported(reported) }
        // tvAppReported'ın başlattığı sessiz deneme bitsin.
        try await Task.sleep(nanoseconds: 100_000_000)
        for _ in 0..<100 where model.tvApp == .working { try await Task.sleep(nanoseconds: 10_000_000) }
        try? FileManager.default.removeItem(at: TVInstallLog.file)
        return model
    }

    /// Eski + her şey hazır (geliştirici modu açık, anahtar kayıtlı): basınca güncelleme hemen kurulur, sonuç kartta.
    func testUpdateWithEverythingReadyInstallsAtOnce() async throws {
        let services = FakeServices()
        services.devMode = true
        services.appOnTV = "0.5.0"
        let model = try await updateScenario(services, key: true, reported: nil)
        await model.updateTVApp()
        XCTAssertNotEqual(model.step, .tv)
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
        XCTAssertTrue(model.tvAppUpdating)
        XCTAssertNil(model.tvAppOutdated)
        let log = TVInstallLog.tail(of: TVInstallLog.file)
        XCTAssertTrue(log.contains("Ana ekrandan") && log.contains("Kurulum tamam."), log)
        model.dismissTVAppUpdate()
        XCTAssertFalse(model.tvAppUpdating)
    }

    /// beta.89 (LG): TV'de 0.6.1 kurulu ama açık uygulama 0.5.0'ı çalıştırıyor. Yeniden kurulmaz; uygulama kapatılıp açılır,
    /// yine eskiyse bir kez daha, sonra ana ekran "TV'de CouchSubs'ı kapatıp yeniden açın" der. Yeni sürüm bağlanınca kalkar.
    func testUpToDatePackageWithAnOldRunningAppIsRestartedThenReported() async throws {
        let services = FakeServices()
        services.devMode = true
        services.appOnTV = "0.6.1"
        let store = MemoryStore()
        store.save("dev-key", for: StoreKey.tvDevKey)
        let model = model(services, store: store)
        model.tv = tv
        model.tvClients = 1
        model.tvAppReported("0.5.0")
        for _ in 0..<200 where services.closes == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(services.closes, 1)
        XCTAssertEqual(services.installs, 0, "paket güncel: yeniden kurulmaz")
        model.tvAppReported("0.5.0")
        for _ in 0..<200 where services.closes == 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(services.closes, 2)
        XCTAssertFalse(model.tvAppStaleRunning)
        model.tvAppReported("0.5.0")
        XCTAssertTrue(model.tvAppStaleRunning)
        XCTAssertEqual(model.tvAppOutdated, TVAppOutdated(installed: "0.5.0", bundled: "0.6.1"))
        XCTAssertEqual(services.closes, 2, "üçüncüde yalnız söylenir")
        model.tvAppReported("0.6.1")
        XCTAssertFalse(model.tvAppStaleRunning)
        XCTAssertNil(model.tvAppOutdated)
    }

    /// Kurulumdan sonra açılan uygulama yeni sürümü bildirirse kapat-aç tekrarlanmaz.
    func testFreshInstallIsCheckedAgainstTheRunningVersion() async throws {
        let services = FakeServices()
        services.devMode = true
        services.appOnTV = "0.5.0"
        let model = try await updateScenario(services, key: true, reported: nil)
        await model.updateTVApp()
        XCTAssertEqual(services.installs, 1)
        model.tvAppReported("0.6.1")
        XCTAssertFalse(model.tvAppStaleRunning)
        XCTAssertNil(model.tvAppOutdated)
        XCTAssertEqual(services.closes, 0, "kapatmayı kurulum yaptı; ayrıca kapatılmaz")
    }

    /// Eski + geliştirici modu kapalı: Developer Mode adımları; açılınca kullanıcı bir şey yapmadan kurulum sürer.
    func testUpdateWithDevModeOffContinuesByItselfOnceItIsOn() async throws {
        let services = FakeServices()
        services.appOnTV = "0.5.0"
        let model = try await updateScenario(services, key: true)
        await model.updateTVApp()
        XCTAssertEqual(model.tvApp, .devModeOff)
        XCTAssertEqual(services.installs, 0)
        XCTAssertTrue(TVInstallLog.tail(of: TVInstallLog.file).contains("geliştirici modu kapalı"))
        services.devMode = true
        // Kartın 3 sn'lik bekleme döngüsü.
        await model.refreshTVApp()
        XCTAssertEqual(services.installs, 1)
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
    }

    /// Eski + anahtar yok: Passphrase kartı; yazılınca kurulur.
    func testUpdateWithoutAKeyAsksThePassphraseThenInstalls() async throws {
        let services = FakeServices()
        services.devMode = true
        services.appOnTV = "0.5.0"
        let model = try await updateScenario(services, key: false)
        await model.updateTVApp()
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: nil))
        XCTAssertTrue(TVInstallLog.tail(of: TVInstallLog.file).contains("Passphrase isteniyor"))
        await model.installTVApp(passphrase: "ABC123")
        XCTAssertEqual(services.installs, 1)
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
    }

    /// Uygulama TV'den silinmiş (uyarı bağlantı kalkınca düştü): "Yeniden kur" de aynı yoldan, ana ekranda kurar.
    func testReinstallingADeletedAppFromHomeInstallsIt() async throws {
        let services = FakeServices()
        services.devMode = true
        services.appOnTV = nil
        let model = try await updateScenario(services, key: true, reported: nil)
        model.tvClients = 0
        XCTAssertNil(model.tvAppOutdated)
        await model.updateTVApp()
        XCTAssertNotEqual(model.step, .tv)
        XCTAssertEqual(services.installs, 1)
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
        XCTAssertTrue(TVInstallLog.tail(of: TVInstallLog.file).contains("TV'deki CouchSubs: yok"))
    }

    /// Kurulum başarısız: neden kartta ("Tekrar dene" kartın düğmesi, refreshTVApp); yeniden deneyince kurulur.
    func testFailedUpdateShowsWhyAndRetrySucceeds() async throws {
        let services = FakeServices()
        services.devMode = true
        services.appOnTV = "0.5.0"
        services.lgInstallError = DevModeFailure(.installFailed, detail: "disk dolu")
        let model = try await updateScenario(services, key: true, reported: nil)
        model.tvAppReported("0.5.0")
        for _ in 0..<100 where model.tvApp == .working { try await Task.sleep(nanoseconds: 10_000_000) }
        await model.updateTVApp()
        XCTAssertEqual(model.tvApp, .failed(.installFailed, reason: "disk dolu"))
        XCTAssertTrue(TVInstallLog.tail(of: TVInstallLog.file).contains("HATA installFailed: disk dolu"))
        services.lgInstallError = nil
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
    }

    /// Eski TV uygulaması bağlı, geliştirici modu açık, anahtar bu Mac'te yok: Passphrase kartı görünür.
    func testOldLGAppWithoutKeyShowsThePassphraseCard() async throws {
        let services = FakeServices()
        services.devMode = true
        let model = model(services)
        try await model.pair(tv)
        XCTAssertEqual(model.tvApp, .unknown)
        model.tvAppReported("0.5.0")
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: nil))
    }

    /// TV'den silinen (ya da kapanan) eski uygulamanın "TV uygulamasını güncelle" uyarısı bellekte kalmıyordu.
    func testOutdatedWarningClearsWhenTheTVAppDisconnects() async throws {
        let model = model(FakeServices())
        model.tv = tv
        model.tvClients = 1
        model.tvAppReported("")
        XCTAssertNotNil(model.tvAppOutdated)
        model.tvClients = 0
        XCTAssertNil(model.tvAppOutdated)
    }

    /// TV'den silinen uygulama için "Yeniden kur": geliştirici modu açık, anahtar yok → Passphrase kartı; neden kurulum
    /// günlüğüne yazılır (önceden tvinstall.log'a hiç satır düşmüyordu).
    func testReinstallForADeletedLGAppAsksThePassphraseAndLogsWhy() async throws {
        let services = FakeServices()
        services.devMode = true
        let model = model(services)
        try await model.pair(tv)
        XCTAssertEqual(model.tvApp, .unknown)
        try? FileManager.default.removeItem(at: TVInstallLog.file)
        await model.reinstallTVApp()
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: nil))
        let written = TVInstallLog.tail(of: TVInstallLog.file)
        XCTAssertTrue(written.contains("yeniden kurma/güncelleme istendi"), written)
        XCTAssertTrue(written.contains("Passphrase isteniyor"), written)
        XCTAssertFalse(TVInstallLog.file.path.contains("Library/Logs"), "Testler gerçek günlüğe yazmaz")
    }

    func testOldLGAppReportedOnTheStreamIsUpdatedWithTheSavedKey() async throws {
        let services = FakeServices()
        services.devMode = true
        services.appOnTV = "0.5.0"
        let store = MemoryStore()
        store.save("dev-key", for: StoreKey.tvDevKey)
        let model = model(services, store: store)
        model.tv = tv
        model.tvAppReported("")
        for _ in 0..<200 where services.installs == 0 || model.tvApp == .working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(services.installs, 1)
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
        XCTAssertNil(model.tvAppOutdated)
    }

    func testOtherBrandsAreNotInstalledThroughLGDeveloperMode() async throws {
        let services = FakeServices()
        services.appOnTV = nil
        services.devMode = true
        let model = model(services)
        try await model.pair(LGTV(name: "Samsung", host: "192.168.1.20", brand: .samsung))
        XCTAssertEqual(model.tvApp, .unknown)
        XCTAssertEqual(services.installs, 0)
    }

    func testLGDeveloperModeIsExtendedOncePerDay() async throws {
        let services = FakeServices()
        services.devMode = true
        let store = MemoryStore()
        store.save("dev-key", for: StoreKey.tvDevKey)
        let model = model(services, store: store)
        try await model.pair(tv)
        XCTAssertEqual(model.devModeHoursLeft, 999)
        await model.refreshTVApp()
        XCTAssertEqual(services.renewals, 1, "Aynı gün ikinci kez uzatılmaz")
    }

    private let samsung = LGTV(name: "Samsung", host: "192.168.1.20", brand: .samsung)
    private let app = BundledTVApp(url: URL(fileURLWithPath: "/tmp/couchsubs-samsung_0.7.0.wgt"), version: "0.7.0")

    /// #1223: "güncelle"ye arka arkaya basılınca aynı Samsung TV'ye birden çok kurulum başlıyordu (TV sdb bağlantılarını
    /// kapattı). Kurulum sürerken düğmeler kapalı; yine gelen istek yeni kurulum başlatmaz, sürenin bitmesini bekler
    /// (Windows ile aynı).
    func testSecondUpdatePressWaitsForTheRunningSamsungInstall() async throws {
        let services = FakeServices()
        services.samsungDevMode = true
        services.bundled[.samsung] = app
        let model = model(services)
        model.tv = samsung
        await model.refreshTVApp()
        XCTAssertEqual(services.brandInstalls.count, 1)
        services.samsungOnTV = "0.6.0"
        services.holdSamsungInstall = true
        let calls = services.samsungInstallCalls
        let first = Task { await model.updateTVApp() }
        for _ in 0..<200 where services.heldSamsungInstall == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(services.heldSamsungInstall)
        let second = Task { await model.updateTVApp() }
        let third = Task { await model.reinstallTVApp() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(services.samsungInstallCalls, calls + 1)
        services.releaseSamsungInstall()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(services.samsungInstallCalls, calls + 1)
        XCTAssertEqual(services.brandInstalls.count, 2)
        XCTAssertEqual(TVInstallLog.tail(of: TVInstallLog.file).components(separatedBy: "yeni kurulum başlatılmadı").count - 1, 2)
        XCTAssertEqual(model.tvApp, .upToDate("0.7.0"))
    }

    func testSamsungWithDevModeOffShowsTheSteps() async {
        let services = FakeServices()
        services.bundled[.samsung] = app
        let model = model(services)
        model.tv = samsung
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .devModeOff)
        XCTAssertTrue(model.canInstallTVApp)
    }

    // #343: TV'deki Host PC IP başka bir adres; sdb denenmez, iki adres de söylenir.
    func testSamsungWithAnotherHostPcIpSaysWhichAddressToType() async {
        let services = FakeServices()
        services.samsungDevMode = true
        services.samsungCheck = SamsungPreflight(info: SamsungDeveloperInfo(developerMode: true, developerIp: "192.168.1.50"),
                                                 computerAddress: "192.168.1.34")
        services.bundled[.samsung] = app
        let model = model(services)
        model.tv = samsung
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .hostPcMismatch(tvIp: "192.168.1.50", computer: "192.168.1.34"))
        XCTAssertTrue(services.brandInstalls.isEmpty)

        services.samsungCheck = SamsungPreflight(info: SamsungDeveloperInfo(developerMode: true, developerIp: "192.168.1.34"),
                                                 computerAddress: "192.168.1.34")
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .upToDate("0.7.0"))
    }

    func testSamsungSayingDeveloperModeIsOffShowsTheSteps() async {
        let services = FakeServices()
        services.samsungDevMode = true
        services.samsungCheck = SamsungPreflight(info: SamsungDeveloperInfo(developerMode: false, developerIp: nil), computerAddress: "192.168.1.34")
        services.bundled[.samsung] = app
        let model = model(services)
        model.tv = samsung
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .devModeOff)
    }

    func testSamsungInstallOpensSignInAndRemembersTheVersion() async {
        let services = FakeServices()
        services.bundled[.samsung] = app
        services.samsungDevMode = true
        let page = URL(string: "https://account.samsung.com/signin")!
        services.events = [.signIn(page)]
        let store = MemoryStore()
        let model = model(services, store: store)
        model.openInBrowser = { _ in }
        model.tv = samsung
        await model.refreshTVApp()
        // Olaylar ana iş parçacığına bir sonraki turda gelir.
        await Task.yield()
        XCTAssertEqual(model.tvApp, .upToDate("0.7.0"))
        XCTAssertEqual(store.load(String.self, for: StoreKey.tvAppVersion), "0.7.0")
        XCTAssertEqual(services.brandInstalls.map { $0.host }, ["192.168.1.20"])

        await model.refreshTVApp()
        XCTAssertEqual(services.brandInstalls.count, 1, "Kurulu sürüm yeniden kurulmaz")
    }

    func testOldSamsungAppOnTheTVIsUpdatedEvenIfThisMacThinksItIsCurrent() async {
        // Q60: TV'de 0.9.7 kalmıştı, bilgisayar kendi kaydına bakıp hiç güncellemiyordu.
        let services = FakeServices()
        services.bundled[.samsung] = app
        services.samsungDevMode = true
        services.samsungOnTV = "0.6.0"
        let store = MemoryStore()
        store.save("0.7.0", for: StoreKey.tvAppVersion)
        let model = model(services, store: store)
        model.tv = samsung
        await model.refreshTVApp()
        XCTAssertEqual(services.brandInstalls.count, 1)
        XCTAssertEqual(model.tvApp, .upToDate("0.7.0"))
    }

    /// Bu Mac'in kaydı güncel dese de TV eski sürümü bildirdiyse geliştirici modu kapalıyken adımlar görünür.
    func testOldSamsungAppReportedOnTheStreamWithDevModeOffShowsTheSteps() async {
        let services = FakeServices()
        services.bundled[.samsung] = app
        let store = MemoryStore()
        store.save("0.7.0", for: StoreKey.tvAppVersion)
        let model = model(services, store: store)
        model.tv = samsung
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .upToDate("0.7.0"))
        model.tvAppReported("0.6.0")
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .devModeOff)
    }

    func testCurrentSamsungAppOnTheTVIsNotReinstalled() async {
        let services = FakeServices()
        services.bundled[.samsung] = app
        services.samsungDevMode = true
        services.samsungOnTV = "0.7.0"
        let store = MemoryStore()
        let model = model(services, store: store)
        model.tv = samsung
        await model.refreshTVApp()
        XCTAssertTrue(services.brandInstalls.isEmpty)
        XCTAssertEqual(store.load(String.self, for: StoreKey.tvAppVersion), "0.7.0")
        XCTAssertEqual(model.tvApp, .upToDate("0.7.0"))
    }

    func testSamsungCheckThatCannotReachTheTVKeepsAWorkingAppReady() async {
        let services = FakeServices()
        services.bundled[.samsung] = app
        services.samsungDevMode = true
        services.installError = DevModeFailure(.unreachable, detail: "sdb: closed")
        let store = MemoryStore()
        store.save("0.7.0", for: StoreKey.tvAppVersion)
        let model = model(services, store: store)
        model.tv = samsung
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .upToDate("0.7.0"))
        store.remove(StoreKey.tvAppVersion)
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .failed(.unreachable, reason: "sdb: closed"))
    }

    func testSamsungFailureIsShown() async {
        let services = FakeServices()
        services.bundled[.samsung] = app
        services.samsungDevMode = true
        services.installError = DevModeError.signInFailed
        let model = model(services)
        model.tv = samsung
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .failed(.signInFailed))
    }

    func testSamsungFailureShowsTheHelpersReasonAndTheLog() async {
        let services = FakeServices()
        services.bundled[.samsung] = app
        services.samsungDevMode = true
        services.installError = DevModeFailure(.packageBlocked, detail: "app_id[CouchSubsT.CouchSubs] install failed[118, -22]")
        let model = model(services)
        model.tv = samsung
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .failed(.packageBlocked, reason: "app_id[CouchSubsT.CouchSubs] install failed[118, -22]"))
        let text = TVAppCard.message(for: .packageBlocked, brand: .samsung, reason: "install failed[118, -22]")
        XCTAssertTrue(text.contains("Smart Hub"))
        XCTAssertTrue(text.contains("install failed[118, -22]"))
        XCTAssertTrue(text.hasSuffix(TVInstallLog.displayPath), "Gönderilecek günlük yazar")
    }

    func testSamsungMessagesAreSpecific() {
        let generic = TVAppCard.message(for: .installFailed, brand: .samsung)
        for error in [DevModeError.certificateMismatch, .certificateRejected, .tvClockWrong, .packageBlocked, .connectionLost] {
            XCTAssertNotEqual(TVAppCard.message(for: error, brand: .samsung), generic, "\(error)")
        }
        // Ayrıntısı olmasa da Samsung hatası günlük dosyasını söyler. LG ve Android TV hatası da söyler (önceden yalnız
        // Samsung); Samsung'a özgü ipuçları onlara eklenmez.
        XCTAssertTrue(TVAppCard.message(for: .signInFailed, brand: .samsung, reason: nil).contains(TVInstallLog.displayPath))
        for brand in [TVBrand.lg, .androidTV] {
            let text = TVAppCard.message(for: .installFailed, brand: brand, reason: "Invalid package")
            XCTAssertTrue(text.hasSuffix(TVInstallLog.displayPath), "\(brand)")
            XCTAssertFalse(text.contains("Samsung"), "\(brand)")
        }
    }

    func testSamsungPairingSaysWhetherThePermissionBoxWasMissedOrRefused() {
        let timeout = TVStep.pairingMessage(for: SamsungClient.SamsungError.cannotConnect, brand: .samsung)
        let refused = TVStep.pairingMessage(for: SamsungClient.SamsungError.rejected, brand: .samsung)
        let generic = TVStep.pairingMessage(for: URLError(.timedOut), brand: .samsung)
        XCTAssertTrue(timeout.contains("60"))
        // Test, sistemin dilinde (Türkçe ya da İngilizce) çalışır; iki ileti de genelden ayrı olmalı.
        XCTAssertNotEqual(refused, generic)
        XCTAssertNotEqual(timeout, generic)
        XCTAssertNotEqual(timeout, refused)
        XCTAssertEqual(generic, TVStep.pairingMessage(for: SamsungClient.SamsungError.cannotConnect, brand: .lg))
    }

    func testHelperErrorKeepsItsReason() {
        let line = #"{"event":"error","code":"CertificateFailed","message":"Samsung sertifika sunucusu /apis/v3/distributors: 401 Unauthorized"}"#
        XCTAssertEqual(TVHelper.parse(line), .failed(DevModeFailure(.certificateFailed,
                                                                    detail: "Samsung sertifika sunucusu /apis/v3/distributors: 401 Unauthorized")))
        XCTAssertEqual(TVHelper.parse(#"{"event":"error","code":"Yeni"}"#), .failed(DevModeFailure(.installFailed, detail: "Yeni")))
        XCTAssertEqual(TVHelper.parse(#"{"event":"login","url":"https://account.samsung.com/x"}"#),
                       .event(.signIn(URL(string: "https://account.samsung.com/x")!)))
        XCTAssertEqual(TVHelper.parse(#"{"event":"done","version":"0.9.10","installed":true}"#),
                       .finished(TVHelper.Result(version: "0.9.10", installed: true)))
        XCTAssertNil(TVHelper.parse("Unhandled exception."))
    }

    /// #1248: samsung-open "resumed"i ayrı bildirir (uygulama çalışıyor, yalnız öne geldi); bekçi bunu 8002'ye düşmeden
    /// bekler, bağlanmazsa `--restart` ile kapatıp açar. Eski yardımcı `state` yazmaz: "installed" açıldı mı demektir.
    func testHelperSamsungOpenStateIsRead() {
        guard case .finished(let resumed)? = TVHelper.parse(#"{"event":"done","version":"","installed":true,"state":"resumed"}"#) else {
            return XCTFail("done okunmadı")
        }
        XCTAssertEqual(TVHelper.sdbOpen(resumed), .resumed)
        XCTAssertEqual(TVHelper.sdbOpen(TVHelper.Result(version: "", installed: true, state: "launched")), .launched)
        XCTAssertEqual(TVHelper.sdbOpen(TVHelper.Result(version: "", installed: false, state: "failed")), .failed)
        XCTAssertEqual(TVHelper.sdbOpen(TVHelper.Result(version: "", installed: true)), .launched)
        XCTAssertEqual(TVHelper.sdbOpen(TVHelper.Result(version: "", installed: false)), .failed)
    }

    func testHelperErrorCodesMapToTheirOwnErrors() {
        XCTAssertEqual(TVHelper.error(code: "CertificateMismatch"), .certificateMismatch)
        XCTAssertEqual(TVHelper.error(code: "CertificateRejected"), .certificateRejected)
        XCTAssertEqual(TVHelper.error(code: "TvClockWrong"), .tvClockWrong)
        XCTAssertEqual(TVHelper.error(code: "PackageBlocked"), .packageBlocked)
        XCTAssertEqual(TVHelper.error(code: "ConnectionLost"), .connectionLost)
        XCTAssertEqual(TVHelper.error(code: "NotEnoughSpace"), .notEnoughSpace)
        XCTAssertEqual(TVHelper.error(code: "InstallFailed"), .installFailed)
    }

    func testHelperThatEndsWithoutAResultSaysSo() {
        let failure = TVHelper.unfinished(status: 134, stderr: "line 1\nUnhandled exception. System.PlatformNotSupportedException: x")
        XCTAssertEqual(failure.error, .installFailed)
        XCTAssertTrue(failure.detail.contains("134"))
        XCTAssertTrue(failure.detail.contains("PlatformNotSupportedException"))
    }

    func testLogLinesAreAppended() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("tvinstall.log")
        TVInstallLog.write("bir", to: file)
        TVInstallLog.write("iki", to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("] bir\n"))
        XCTAssertTrue(text.contains("] iki\n"))
        XCTAssertEqual(TVInstallLog.displayPath, "~/Library/Logs/CouchSubs/tvinstall.log")
    }

    /// "Günlüğü kopyala": günlüğün sonu panoya gider (telefonlardaki "Kurulum günlüğünü paylaş" gibi).
    func testLogTailIsTheEndOfTheLog() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("tvinstall.log")
        XCTAssertEqual(TVInstallLog.tail(of: file), "", "Dosya yoksa boş")
        TVInstallLog.write("bir", to: file)
        TVInstallLog.write("iki", to: file)
        XCTAssertEqual(TVInstallLog.tail(of: file), try String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(TVInstallLog.tail(of: file, limit: 6), "] iki\n")
    }

    /// LG kurulumunun adımları ve hatası günlüğe telefonlardaki satırlarla yazılır.
    func testLGInstallLinesMatchThePhones() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("tvinstall.log")
        TVInstallLog.lgKeyRequest(host: "192.168.1.20", to: file)
        TVInstallLog.lgStart(host: "192.168.1.20", package: "0.9.43", to: file)
        TVInstallLog.failure(DevModeFailure(.installFailed, detail: "FAILED_IPKG_INSTALL"), to: file)
        TVInstallLog.failure(DevModeError.wrongPassphrase, to: file)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { String($0.drop { $0 != "]" }.dropFirst(2)) }
        XCTAssertEqual(lines, [
            "--- LG kurulumu başlıyor: TV 192.168.1.20, Key Server'dan anahtar isteniyor",
            "--- LG kurulumu başlıyor: TV 192.168.1.20, paket 0.9.43",
            "HATA installFailed: FAILED_IPKG_INSTALL",
            "HATA wrongPassphrase",
        ])
    }

    func testAndroidTVIsFoundOnTheNetworkAndRemembered() async {
        let services = FakeServices()
        services.bundled[.androidTV] = BundledTVApp(url: URL(fileURLWithPath: "/tmp/couchsubs-androidtv_0.7.0.apk"), version: "0.7.0")
        let store = MemoryStore()
        let model = model(services, store: store)
        model.tv = LGTV(name: "Android TV", host: "", brand: .androidTV)
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .devModeOff, "Hata ayıklama açılana kadar adımlar görünür")

        services.androidHosts = ["192.168.1.40"]
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .upToDate("0.7.0"))
        XCTAssertEqual(model.tv?.host, "192.168.1.40")
        XCTAssertEqual(store.load(LGTV.self, for: StoreKey.tv)?.host, "192.168.1.40")
    }

    // #352, #389: TV'den kaldırılan uygulama; TV sihirbazda yeniden seçilince adres boşalıyor, kayıtlı sürüm kalıyordu.
    // Kart "hazır" diyor, ağda TV aranmıyor, kurulum hiç denenmiyordu.
    func testReselectedAndroidTVWithARememberedVersionIsCheckedOnTheTV() async {
        let services = FakeServices()
        services.bundled[.androidTV] = BundledTVApp(url: URL(fileURLWithPath: "/tmp/a_0.7.0.apk"), version: "0.7.0")
        services.androidHosts = ["192.168.1.40"]
        let store = MemoryStore()
        store.save("0.7.0", for: StoreKey.tvAppVersion)
        let model = model(services, store: store)
        model.tv = LGTV(name: "Android TV", host: "", brand: .androidTV)
        await model.refreshTVApp()
        XCTAssertEqual(services.brandInstalls.map { $0.host }, ["192.168.1.40"])
        XCTAssertEqual(model.tvApp, .upToDate("0.7.0"))
    }

    func testReselectedAndroidTVThatCannotBeFoundShowsTheDebuggingSteps() async {
        let services = FakeServices()
        services.bundled[.androidTV] = BundledTVApp(url: URL(fileURLWithPath: "/tmp/a_0.7.0.apk"), version: "0.7.0")
        let store = MemoryStore()
        store.save("0.7.0", for: StoreKey.tvAppVersion)
        let model = model(services, store: store)
        model.tv = LGTV(name: "Android TV", host: "", brand: .androidTV)
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .devModeOff)
    }

    func testReinstallForgetsTheVersionChecksTheTVAndOpensTheApp() async {
        let services = FakeServices()
        services.bundled[.androidTV] = BundledTVApp(url: URL(fileURLWithPath: "/tmp/a_0.7.0.apk"), version: "0.7.0")
        services.androidHosts = ["192.168.1.40"]
        let store = MemoryStore()
        store.save("0.7.0", for: StoreKey.tvAppVersion)
        let model = model(services, store: store)
        model.tv = LGTV(name: "Android TV", host: "192.168.1.40", brand: .androidTV)
        XCTAssertTrue(model.canReinstallTVApp)
        await model.reinstallTVApp()
        XCTAssertEqual(services.androidOpenRequests, [true])
        XCTAssertEqual(model.tvApp, .upToDate("0.7.0"))
        // "Açılsın" isteği bir kerelik.
        await model.refreshTVApp()
        XCTAssertEqual(services.androidOpenRequests, [true, false])
    }

    func testReinstallWithoutDebuggingShowsTheDebuggingSteps() async {
        let services = FakeServices()
        services.bundled[.androidTV] = BundledTVApp(url: URL(fileURLWithPath: "/tmp/a_0.7.0.apk"), version: "0.7.0")
        let store = MemoryStore()
        store.save("0.7.0", for: StoreKey.tvAppVersion)
        let model = model(services, store: store)
        model.tv = LGTV(name: "Android TV", host: "192.168.1.40", brand: .androidTV)
        await model.reinstallTVApp()
        XCTAssertNil(store.load(String.self, for: StoreKey.tvAppVersion))
        XCTAssertEqual(model.tvApp, .devModeOff)
    }

    /// "Yeniden kur" üç markada da var (önceden yalnız Samsung ve Android TV); TV uygulaması bağlıyken çıkmaz.
    func testReinstallIsOfferedForAllThreeBrandsWhileTheTVAppIsNotConnected() {
        let services = FakeServices()
        services.bundled[.androidTV] = BundledTVApp(url: URL(fileURLWithPath: "/tmp/a_0.7.0.apk"), version: "0.7.0")
        let model = model(services)
        model.tv = LGTV(name: "LG TV", host: "192.168.1.153")
        XCTAssertTrue(model.canReinstallTVApp)
        model.tv = LGTV(name: "Android TV", host: "", brand: .androidTV)
        XCTAssertTrue(model.canReinstallTVApp)
        model.tvClients = 1
        XCTAssertFalse(model.canReinstallTVApp)
    }

    /// LG paketi uygulamayla gelmediyse yeniden kurulamaz; TV adımına "TV'ye bağlan" götürür (#662). Paket varken aynı
    /// yere "TV'yi değiştir" götürür; iki düğme birden çıkmaz, TV uygulaması bağlıyken de "TV'yi değiştir" kalır.
    func testChangeTVIsOfferedWheneverATVIsPaired() async throws {
        let services = FakeServices()
        let model = model(services)
        XCTAssertFalse(model.canReconnectTV)
        XCTAssertFalse(model.canChangeTV)
        try await model.pair(LGTV(name: "LG TV", host: "192.168.1.153"))
        XCTAssertTrue(model.canReinstallTVApp)
        XCTAssertFalse(model.canReconnectTV)
        XCTAssertTrue(model.canChangeTV)
        model.tvClients = 1
        XCTAssertFalse(model.canReinstallTVApp)
        XCTAssertTrue(model.canChangeTV, "TV uygulaması bağlıyken de TV değiştirilebilir")
        model.tvClients = 0
        services.bundledTVAppVersion = nil
        XCTAssertFalse(model.canReinstallTVApp)
        XCTAssertTrue(model.canReconnectTV)
        XCTAssertFalse(model.canChangeTV)
    }

    /// LG'de "yeniden kur": kayıtlı anahtar varsa Passphrase sorulmadan, TV'deki sürüm güncel olsa da yeniden kurulur.
    func testLGReinstallWithASavedKeyInstallsAgainWithoutAskingThePassphrase() async throws {
        let services = FakeServices()
        services.devMode = true
        let store = MemoryStore()
        store.save("dev-key", for: StoreKey.tvDevKey)
        let model = model(services, store: store)
        try await model.pair(LGTV(name: "LG TV", host: "192.168.1.153"))
        XCTAssertEqual(services.installs, 0, "TV'deki sürüm güncel: açılışta kurulmaz")
        await model.reinstallTVApp()
        XCTAssertEqual(services.installs, 1)
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))
        // İstek bir kerelik: sonraki denetim güncel uygulamayı yeniden kurmaz.
        await model.refreshTVApp()
        XCTAssertEqual(services.installs, 1)
    }

    /// Kayıtlı anahtar yoksa Passphrase adımı açılır; parola yazılınca güncel uygulama da yeniden kurulur. Geliştirici
    /// modu kapalıysa adımları görünür.
    func testLGReinstallWithoutAKeyAsksThePassphraseThenInstallsAgain() async throws {
        let services = FakeServices()
        services.devMode = true
        let model = model(services)
        try await model.pair(LGTV(name: "LG TV", host: "192.168.1.153"))
        await model.reinstallTVApp()
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: nil))
        XCTAssertEqual(services.installs, 0)
        await model.installTVApp(passphrase: "ABC123")
        XCTAssertEqual(services.installs, 1)
        XCTAssertEqual(model.tvApp, .upToDate("0.6.1"))

        services.devMode = false
        await model.reinstallTVApp()
        XCTAssertEqual(model.tvApp, .devModeOff)
    }

    /// TV kayıtlı anahtarı reddederse (geliştirici modu yeniden açılmış) anahtar bırakılır ve Passphrase adımı açılır.
    func testLGReinstallWithARefusedKeyFallsBackToThePassphraseStep() async throws {
        let services = FakeServices()
        services.devMode = true
        services.refuseKey = true
        let store = MemoryStore()
        store.save("eski-anahtar", for: StoreKey.tvDevKey)
        let model = model(services, store: store)
        try await model.pair(LGTV(name: "LG TV", host: "192.168.1.153"))
        await model.reinstallTVApp()
        XCTAssertEqual(model.tvApp, .needsPassphrase(error: nil))
        XCTAssertNil(store.load(String.self, for: StoreKey.tvDevKey))
    }

    func testInstalledAndroidAppNeedsNothingWhenDebuggingIsOff() async {
        let services = FakeServices()
        services.bundled[.androidTV] = BundledTVApp(url: URL(fileURLWithPath: "/tmp/a_0.7.0.apk"), version: "0.7.0")
        let store = MemoryStore()
        store.save("0.7.0", for: StoreKey.tvAppVersion)
        let model = model(services, store: store)
        model.tv = LGTV(name: "Android TV", host: "192.168.1.40", brand: .androidTV)
        await model.refreshTVApp()
        XCTAssertEqual(model.tvApp, .upToDate("0.7.0"))
        XCTAssertTrue(services.brandInstalls.isEmpty)
    }

    func testBundledFileNameCarriesTheVersion() {
        XCTAssertEqual(BundledTVApp.version(ofFile: "couchsubs-androidtv_0.7.0.apk"), "0.7.0")
        XCTAssertNil(BundledTVApp.version(ofFile: "couchsubs.apk"))
    }

    func testMovedTVIsSaved() {
        let store = MemoryStore()
        let model = model(FakeServices(), store: store)
        let moved = LGTV(name: "LG TV", host: "192.168.1.230")
        model.tvMoved(to: moved)
        XCTAssertEqual(model.tv, moved)
        XCTAssertEqual(store.load(LGTV.self, for: StoreKey.tv), moved)
    }
}
