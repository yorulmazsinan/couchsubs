// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CouchSubsCore
import Foundation
import Combine
import RemotePlay

/// Telefon uygulamasının bütün durumu: kurulum (PSN girişi, PS5 eşleştirme, altyazının yeri), çeviri (PS5 görüntüsü →
/// yazı tanıma → çeviri → TV ya da telefon ekranı) ve ayarlar. Okuma hattı, çevirmenler, ayarlar ve TV denetimi Mac
/// uygulamasıyla ortak (CouchSubsCore, RemotePlay); burada yalnız telefona özgü akış var.
@MainActor
final class PhoneModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, psnLogin, console, output, done
    }

    @Published var step: Step {
        didSet { if step == .done, oldValue != .done { store.save(true, for: StoreKey.setupComplete) } }
    }
    @Published var accountId: Data?
    @Published var console: RegisteredConsole?
    @Published var tv: LGTV?
    @Published private(set) var tvKeySaved: Bool
    /// Son eşleşmede TV uygulaması açılamadı: büyük olasılıkla TV'de kurulu değil. Telefon TV uygulamasını kuramaz
    /// (LG ssh, Samsung sdb, Android TV adb ister); ilk kurulum bilgisayardaki CouchSubs ile yapılır.
    @Published var tvAppMissing = false

    @Published var settings: UserSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: StoreKey.settings) }
            server.sendStyle(settings.style)
            if settings.output != oldValue.output { outputChanged() }
            if settings.gamePacks != oldValue.gamePacks, let pipeline { connectPacks(to: pipeline) }
            if settings.sharePool != oldValue.sharePool {
                let (pool, enabled) = (pool, settings.sharePool)
                Task { await pool.setEnabled(enabled) }
            }
            let translationChanged = settings.onlineTranslation != oldValue.onlineTranslation
                || settings.onlineEngine != oldValue.onlineEngine || settings.geminiModel != oldValue.geminiModel
                || settings.openAIModel != oldValue.openAIModel || settings.claudeModel != oldValue.claudeModel
            if translationChanged {
                Task { await refreshTranslatorStatus() }
                if isRunning { makePipeline() }
            }
        }
    }

    // Çalışma durumu
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var sessionState: SessionState = .disconnected(.stopped)
    @Published private(set) var tvClients = 0
    @Published private(set) var lastSource = ""
    @Published private(set) var lastTranslation = ""
    @Published private(set) var history = SubtitleHistory()
    @Published private(set) var translatorStatus: TranslatorStatus = .ready
    @Published private(set) var onlineIssue: OnlineKeyState?
    /// Son altyazı oyun paketinden mi geldi (ana ekrandaki "paket kullanılıyor" göstergesi).
    @Published private(set) var lastFromPack = false
    /// Bu oturumda çevrilen satırlar (en yenisi başta), nereden geldikleriyle.
    @Published private(set) var recentLines: [RecentLine] = []
    /// Bu oturumdaki satır sayısı ve paketten gelenler ("Hazır çeviriden 47 / 50").
    @Published private(set) var sessionLines = 0
    @Published private(set) var sessionPackLines = 0
    /// Çevirinin başladığı an (çalışma ekranındaki süre).
    @Published private(set) var runningSince: Date?

    struct RecentLine: Identifiable, Equatable {
        let id: Int
        let source: String
        let translation: String
        let fromPack: Bool
    }

    /// Son oturumun süresi (saniye; ana ekrandaki "Son oturum").
    var lastSessionSeconds: Int? {
        let value = defaults.integer(forKey: "lastSessionSeconds")
        return value > 0 ? value : nil
    }
    /// Telefon ekranında şu an görünen satırlar (TV uygulamasıyla aynı yığın kuralları).
    @Published private(set) var phoneLines: [SubtitleStack.Line] = []
    @Published private(set) var installedPacks: [GamePackLibrary.Info] = []

    /// Çeviri sürerken ekran kararmasın (iOS uygulamayı askıya alınca bağlantı da durur). Uygulama UIKit'e bağlar.
    var keepScreenAwake: (Bool) -> Void = { _ in }
    /// Ölçüm olayları (Firebase Analytics, Meta); uygulama `AppModel.analytics`'e bağlar.
    var onAnalytics: (AnalyticsEvent) -> Void = { _ in }
    private var startedAt: Date?

    private let services: PhoneServices
    private let store: AppStore
    private let defaults: UserDefaults
    private var server = SubtitleServer(port: AppIdentity.serverPort)
    private var serverStarted = false
    @Published private(set) var serverPort: UInt16 = AppIdentity.serverPort
    private var session: StreamControlling?
    private var keeper: KeeperControlling?
    private var pipeline: SubtitlePipeline?
    private var processing = false
    private var savedKeys: Set<TranslationEngine> = []
    private var stack = SubtitleStack()
    private var stackTimer: Task<Void, Never>?
    /// Yığının saati (saniye); testlerde ileri sarılır.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Oyun paketleri: uygulamayla gelenler ve sunucudan indirilen güncel sürümleri (ücretsiz, herkese).
    let packs: GamePackLibrary
    private let pool: LinePool

    init(services: PhoneServices = LivePhoneServices(), store: AppStore = KeychainStore(), defaults: UserDefaults = .standard,
         packs: GamePackLibrary = GamePackLibrary(bundled: nil, user: nil)) {
        self.services = services
        self.store = store
        self.defaults = defaults
        self.packs = packs
        let accountId = store.load(Data.self, for: StoreKey.accountId)
        let console = store.load(RegisteredConsole.self, for: StoreKey.console)
        let tv = store.load(LGTV.self, for: StoreKey.tv)
        let tvKeySaved = store.load(String.self, for: StoreKey.tvKey) != nil
        self.accountId = accountId
        self.console = console
        self.tv = tv
        self.tvKeySaved = tvKeySaved
        let loaded = defaults.data(forKey: StoreKey.settings).flatMap { try? JSONDecoder().decode(UserSettings.self, from: $0) }
        let curated = (loaded ?? UserSettings()).withCuratedModels()
        settings = curated
        let done = accountId != nil && console != nil && store.load(Bool.self, for: StoreKey.setupComplete) == true
        step = done ? .done : .welcome
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !testing {
            RemotePlayLog.enable()
            RemotePlayLog.write("CouchSubs iOS \(AppIdentity.version)")
        }
        let poolFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true).appendingPathComponent("pool.json")
        pool = LinePool(file: poolFile, app: AppIdentity.version, platform: "ios", enabled: curated.sharePool && !testing)
        savedKeys = Set(TranslationEngine.allCases.filter { engine in
            engine.storeKey.flatMap { store.load(String.self, for: $0) }?.isEmpty == false
        })
        attachServer()
        reloadPackList()
    }

    /// Ayarlardaki paket listesi; paketler güncellenince yeniden okunur.
    func reloadPackList() {
        let packs = self.packs
        Task { [weak self] in
            let list = await Task.detached(priority: .utility) { packs.packs }.value
            self?.installedPacks = list
        }
    }

    private func attachServer() {
        server.onClientsChanged = { [weak self] count in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.tvClients = count } }
        }
        server.sendsToTV = settings.output.showsOnTV
        server.onEvent = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.phoneReceive(event) } }
        }
    }

    // MARK: - Kurulum

    var canAdvance: Bool {
        switch step {
        case .welcome: true
        case .psnLogin: accountId != nil
        case .console: console != nil
        case .output: hasTV || settings.output == .computer
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

    var hasTV: Bool { tv != nil && tvKeySaved }

    func completePSNLogin(redirect: URL) async throws {
        do {
            let id = try await services.accountId(fromRedirect: redirect)
            accountId = id
            store.save(id, for: StoreKey.accountId)
            RemotePlayLog.write("PSN girişi tamam")
        } catch let error as PSNAccount.PSNError {
            RemotePlayLog.write("PSN girişi başarısız: \(error)")
            throw PhoneFailure(error: PhoneError(error), detail: nil)
        } catch {
            throw PhoneFailure(error: .invalidLogin, detail: error.localizedDescription)
        }
    }

    func discoverConsoles() async -> [ConsoleInfo] { await services.discoverConsoles() }

    /// PS5'e ikinci hesapla kayıt olur (PS5'teki 8 haneli kodla).
    func register(host: String, pin: String) async throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw PhoneError.missingConsole }
        guard let value = Registration.pin(from: pin) else { throw PhoneError.invalidPin }
        guard let accountId else { throw PhoneError.missingAccount }
        do {
            let registered = try await services.register(host: host, accountId: accountId, pin: value)
            console = registered
            store.save(registered, for: StoreKey.console)
        } catch let error as Registration.RegistrationError {
            throw PhoneFailure(error: PhoneError(error.kind), detail: error.detail)
        } catch {
            throw PhoneFailure(error: .registrationFailed, detail: error.localizedDescription)
        }
    }

    func discoverTVs() async -> [LGTV] { await services.discoverTVs() }

    /// TV ile eşleşir ve TV uygulamasını telefonun adresiyle açmayı dener.
    func pair(_ tv: LGTV) async throws {
        try await startServer()
        let pairing = try await services.pairTV(tv, key: store.load(String.self, for: StoreKey.tvKey), server: serverAddress(for: tv))
        self.tv = tv
        store.save(tv, for: StoreKey.tv)
        store.save(pairing.key, for: StoreKey.tvKey)
        tvKeySaved = true
        tvAppMissing = !pairing.launched
        if settings.output == .computer { settings.output = .tv }
        onAnalytics(.tvConnected(brand: tv.brand.rawValue))
    }

    /// "TV'm yok": altyazı bu telefonun ekranında gösterilir.
    func usePhoneScreen() {
        settings.output = .computer
        advance()
    }

    /// Kurulumu baştan başlatır (kayıtlı her şeyi siler).
    func resetSetup() {
        stop()
        [StoreKey.accountId, StoreKey.console, StoreKey.tv, StoreKey.tvKey, StoreKey.setupComplete].forEach(store.remove)
        accountId = nil
        console = nil
        tv = nil
        tvKeySaved = false
        tvAppMissing = false
        step = .welcome
    }

    // MARK: - Çeviri

    var canStart: Bool { console != nil && accountId != nil && (settings.output.showsOnComputer || hasTV) }

    func start() async {
        guard !isRunning, !isStarting, canStart, let console, let accountId else { return }
        isStarting = true
        defer { isStarting = false }
        await refreshTranslatorStatus()
        try? await startServer()
        server.sendStyle(settings.style)
        makePipeline()
        RemotePlayLog.write("Çeviri başladı; PS5'e bağlanılıyor: \(console.name) \(console.host)")
        let session = services.makeStream(console: console, accountId: accountId)
        session.onState = { [weak self] state in Task { @MainActor in self?.sessionStateChanged(state) } }
        session.onConsoleMoved = { [weak self] moved in Task { @MainActor in self?.consoleMoved(moved) } }
        session.onFrame = { [weak self] frame in Task { @MainActor in await self?.handle(frame) } }
        session.start()
        self.session = session
        startKeeper()
        isRunning = true
        startedAt = Date()
        runningSince = startedAt
        recentLines = []
        sessionLines = 0
        sessionPackLines = 0
        keepScreenAwake(true)
        onAnalytics(.sessionStart(output: settings.output.rawValue))
    }

    func stop() {
        if let startedAt {
            let seconds = Int(Date().timeIntervalSince(startedAt))
            onAnalytics(.sessionStop(seconds: seconds))
            defaults.set(seconds, forKey: "lastSessionSeconds")
            self.startedAt = nil
        }
        runningSince = nil
        session?.stop()
        session = nil
        keeper?.stop()
        keeper = nil
        pipeline?.reset()
        pipeline = nil
        isRunning = false
        onlineIssue = nil
        sessionState = .disconnected(.stopped)
        phoneHide()
        keepScreenAwake(false)
    }

    /// Uygulama yeniden öne gelince (iOS arka planda bağlantıları keser) PS5 ve TV bağlantıları hemen yenilenir.
    func becameActive() {
        guard isRunning else { return }
        session?.reconnectNow()
        keeper?.reconnect()
    }

    private func startKeeper() {
        guard keeper == nil, settings.output.showsOnTV, hasTV, let tv else { return }
        let server = self.server
        let keeper = services.makeKeeper(tv: tv, key: store.load(String.self, for: StoreKey.tvKey), params: ["server": serverAddress(for: tv)],
                                         appConnected: { server.connectedClients > 0 }) { [weak self] moved in
            Task { @MainActor in self?.tvMoved(to: moved) }
        }
        keeper.start(interval: .seconds(5))
        self.keeper = keeper
    }

    private func outputChanged() {
        server.sendsToTV = settings.output.showsOnTV
        if !settings.output.showsOnComputer { phoneHide() }
        guard isRunning else { return }
        if settings.output.showsOnTV {
            startKeeper()
        } else {
            keeper?.stop()
            keeper = nil
        }
    }

    private func tvMoved(to moved: LGTV) {
        tv = moved
        store.save(moved, for: StoreKey.tv)
    }

    private func consoleMoved(_ moved: RegisteredConsole) {
        guard console != nil else { return }
        console = moved
        store.save(moved, for: StoreKey.console)
    }

    private func sessionStateChanged(_ state: SessionState) {
        sessionState = state
        if case .disconnected = state {
            pipeline?.reset()
            server.clear()
        }
    }

    private func makePipeline() {
        pipeline?.reset()
        let pipeline = SubtitlePipeline(reader: VisionReader(language: settings.sourceLanguage), translator: makeTranslator(),
                                        server: server, scheduler: ReadScheduler())
        pipeline.onPair = { [weak self, weak pipeline] source, translation in
            self?.lastSource = source
            self?.lastTranslation = translation
            self?.history.add(source: source, translation: translation)
            let fromPack = pipeline?.lastOrigin == "paket"
            self?.noteLine(source: source, translation: translation, fromPack: fromPack)
        }
        pipeline.onTranslationResult = { [weak self] error in
            let status: TranslatorStatus = switch error {
            case nil: .ready
            case .needsDownload: .needsDownload
            case .unsupported: .unsupported
            }
            self?.translatorStatus = status
        }
        connectPacks(to: pipeline)
        onlineIssue = nil
        pipeline.warmUp()
        self.pipeline = pipeline
    }

    private func handle(_ frame: CGImage) async {
        guard !processing, let pipeline else { return }
        processing = true
        await pipeline.process(frame, region: settings.region)
        processing = false
    }

    private func noteLine(source: String, translation: String, fromPack: Bool) {
        lastFromPack = fromPack
        sessionLines += 1
        if fromPack {
            sessionPackLines += 1
            onAnalytics(.packHit(packId: nil))
        }
        recentLines.insert(RecentLine(id: sessionLines, source: source, translation: translation, fromPack: fromPack), at: 0)
        if recentLines.count > 30 { recentLines.removeLast() }
    }

    /// Okuma hattı oyun paketlerine bakıyor mu: ayar açık ve İngilizce→Türkçe (paketler herkese ücretsiz).
    var packsActive: Bool {
        settings.gamePacks && settings.sourceLanguage == "en" && settings.targetLanguage == "tr"
    }

    /// Paketler güncellendi: okuma hattı yeni listeyle eşleşir.
    func packsChanged() {
        if let pipeline { connectPacks(to: pipeline) }
        reloadPackList()
    }

    /// Paketler yalnız İngilizce→Türkçede ve ayar açıkken kullanılır; pakette olmayan satır ortak havuza önerilir.
    private func connectPacks(to pipeline: SubtitlePipeline) {
        let packs = self.packs
        let pool = self.pool
        let active = packsActive
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

    /// Havuz kuyruğu: uygulama arka plana geçerken gönderilir (iOS sonra uygulamayı askıya alabilir).
    func flushPool() async { await pool.flush() }

    func refreshTranslatorStatus() async {
        if onlineTranslationActive {
            translatorStatus = .ready
            return
        }
        translatorStatus = await Translator.status(source: settings.sourceLanguage, target: settings.targetLanguage)
    }

    private func makeTranslator() -> TextTranslator {
        let (source, target) = (settings.sourceLanguage, settings.targetLanguage)
        let local = Translator(source: source, target: target,
                               cache: Self.translationCache(engine: Translator.engineID, source: source, target: target))
        let engine = settings.onlineEngine
        guard onlineTranslationActive, let storeKey = engine.storeKey, let key = store.load(String.self, for: storeKey) else { return local }
        let online: TextTranslator & OnlineTranslating
        if let provider = engine.aiProvider {
            let model = provider.model(settings.model(for: provider)).id
            online = AITranslator(provider: provider, key: key, model: model, fallback: local,
                                  cache: Self.translationCache(engine: provider.engineID(model: model), source: source, target: target))
        } else {
            online = DeepLTranslator(key: key, fallback: local,
                                     cache: Self.translationCache(engine: DeepLTranslator.engineID, source: source, target: target))
        }
        online.onFailureChanged = { [weak self] state in Task { @MainActor in self?.onlineIssue = state } }
        return online
    }

    private static func translationCache(engine: String, source: String, target: String) -> TranslationCache {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true).appendingPathComponent("Translations", isDirectory: true)
        return TranslationCache.shared(in: directory, engine: engine, source: source, target: target)
    }

    // MARK: - Çevrimiçi çeviri anahtarları (Anahtarlık)

    var onlineTranslationActive: Bool {
        settings.onlineTranslation && settings.sourceLanguage == "en" && settings.targetLanguage == "tr" && hasKey(settings.onlineEngine)
    }

    func hasKey(_ engine: TranslationEngine) -> Bool { savedKeys.contains(engine) }

    /// Anahtar denenir; kabul edildiyse Anahtarlık'a yazılır ve motor seçilir. Dönen metin kullanıcıya gösterilir.
    func saveKey(_ key: String, for engine: TranslationEngine) async -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let storeKey = engine.storeKey else { return false }
        let accepted: Bool
        if let provider = engine.aiProvider {
            switch await services.testAIKey(provider: provider, key: key, model: settings.model(for: provider)) {
            case .success, .failure(.quotaExceeded), .failure(.modelRejected): accepted = true
            case .failure: accepted = false
            }
        } else {
            let state = await services.checkDeepLKey(key).state
            accepted = state == .valid || state == .quotaExceeded
        }
        guard accepted else { return false }
        store.save(key, for: storeKey)
        savedKeys.insert(engine)
        if settings.translationEngine == engine {
            if isRunning { makePipeline() }
            await refreshTranslatorStatus()
        } else {
            settings.translationEngine = engine
        }
        return true
    }

    func removeKey(_ engine: TranslationEngine) {
        guard let storeKey = engine.storeKey else { return }
        store.remove(storeKey)
        savedKeys.remove(engine)
        if settings.translationEngine == engine { settings.onlineTranslation = false }
    }

    // MARK: - Telefon ekranındaki altyazı

    /// Sunucunun TV'ye gönderdiği olayların aynısı telefon ekranına da gelir (TV kurulu olmasa da).
    func phoneReceive(_ event: SubtitleEvent) {
        guard settings.output.showsOnComputer else { return }
        let now = clock()
        switch event {
        case .subtitle(let text, let durationMs, let paragraphs, let replaces):
            // Aynı cümlenin uzamış ya da düzelmiş okuması öncekinin yerine geçer (Mac'teki pencere ve TV gibi).
            stack.show(text, durationMs: durationMs, paragraphs: paragraphs, replaces: replaces, now: now)
        case .clear:
            stack.clear(now: now)
        }
        phoneRefresh()
    }

    private func phoneRefresh() {
        let now = clock()
        let lines = stack.lines(at: now)
        if lines != phoneLines { phoneLines = lines }
        stackTimer?.cancel()
        stackTimer = nil
        guard let next = stack.nextChange(after: now) else { return }
        let wait = max(0.01, next - now)
        stackTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.phoneRefresh()
        }
    }

    private func phoneHide() {
        stack.hide()
        stackTimer?.cancel()
        stackTimer = nil
        if !phoneLines.isEmpty { phoneLines = [] }
    }

    /// Deneme altyazısı: TV'de ya da telefon ekranında yazının nasıl göründüğü.
    func sendTestSubtitle() {
        Task {
            try? await startServer()
            server.sendStyle(settings.style)
            server.sendSubtitle(String(localized: "This is a test subtitle. Can you see it on top of the game?"), durationMs: 8000)
        }
    }

    // MARK: - Durum metinleri

    var ps5StatusText: String {
        switch sessionState {
        case .streaming: return String(localized: "Connected")
        case .connecting: return String(localized: "Connecting…")
        case .disconnected(let reason):
            guard isRunning else { return String(localized: "Not connected") }
            switch reason {
            case .consoleAsleep: return String(localized: "Turn on your PS5")
            case .inUse: return String(localized: "Remote Play is in use on another device")
            case .refused: return String(localized: "The PS5 refused the connection. Set up the PS5 again.")
            case .loginPasscode: return String(localized: "The second user has a login passcode on the PS5. Turn it off in Settings › Users and Accounts.")
            case .notFound(let host):
                return String(format: String(localized: "PS5 not found at %@. Make sure it is on and on the same network. Reconnecting…"), host)
            case .network: return String(localized: "Can't reach the PS5. Reconnecting…")
            case .other, .stopped: return String(localized: "Reconnecting…")
            }
        }
    }

    var tvStatusText: String {
        tvClients > 0 ? String(localized: "Connected") : String(localized: "Waiting for the TV app")
    }

    // MARK: - Sunucu

    private func startServer() async throws {
        guard !serverStarted else { return }
        do {
            serverPort = try await server.start()
        } catch {
            server = SubtitleServer(port: 0)
            attachServer()
            serverPort = try await server.start()
        }
        serverStarted = true
    }

    /// TV ile aynı ağdaki telefon adresi.
    func serverAddress(for tv: LGTV) -> String {
        "http://\(NetworkAddress.near(tv.host.isEmpty ? "192.168.1.1" : tv.host) ?? "127.0.0.1"):\(serverPort)"
    }
}
