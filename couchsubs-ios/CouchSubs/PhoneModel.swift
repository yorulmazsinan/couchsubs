// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CouchSubsCore
import Foundation
import Combine
import RemotePlay
import XboxStream

/// Telefon uygulamasının bütün durumu: kurulum (PSN girişi, PS5 eşleştirme, altyazının yeri), çeviri (PS5 görüntüsü →
/// yazı tanıma → çeviri → TV ya da telefon ekranı) ve ayarlar. Okuma hattı, çevirmenler, ayarlar ve TV denetimi Mac
/// uygulamasıyla ortak (CouchSubsCore, RemotePlay); burada yalnız telefona özgü akış var.
@MainActor
final class PhoneModel: ObservableObject {
    enum Step: Int, CaseIterable {
        /// `hdmi`: TV girişi (Mac'teki kurulum adımı); yalnız TV eşli, altyazı TV'de ve TV Android TV değilken (`asksTVInput`).
        case welcome, psnLogin, console, output, hdmi, done
    }

    @Published var step: Step {
        didSet { if step == .done, oldValue != .done { store.save(true, for: StoreKey.setupComplete) } }
    }
    @Published var accountId: Data?
    /// Okunan konsol: PlayStation (varsayılan) ya da Xbox (Beta). `platformChosen` false ise kurulumda sorulur.
    @Published private(set) var platform: ConsolePlatform
    @Published var platformChosen: Bool
    /// Seçilen Xbox ve Microsoft girişi (jeton Anahtar Zinciri'nde).
    @Published private(set) var xboxConsole: XboxConsole?
    @Published private(set) var xboxSignedIn: Bool
    let xboxAuth: XboxAuth
    private let tokenSink: XboxTokenSink
    @Published var console: RegisteredConsole?
    @Published var tv: LGTV?
    @Published private(set) var tvKeySaved: Bool
    /// İkinci hesabın PS5 giriş şifresi Anahtarlık'ta kayıtlı.
    @Published private(set) var hasLoginPasscode: Bool
    /// Son eşleşmede TV uygulaması açılamadı: büyük olasılıkla TV'de kurulu değil; telefon kurabilir (TV uygulamasını kur).
    @Published var tvAppMissing = false
    /// TV'deki uygulama telefondaki paketten eski: ana ekranda "TV uygulamasını güncelle".
    @Published private(set) var tvAppUpdate: TVAppUpdate?
    /// LG: TV'deki paket güncel ama açık uygulama kapatıp açtıktan sonra da eski sürümde (beta.89); değer çalışan sürüm.
    /// Ana ekran "TV'de CouchSubs'ı kapatıp yeniden açın" der.
    @Published private(set) var tvAppStaleRunning: String?
    /// LG: kurulumdan ya da kapat-aç'tan sonra çalışan uygulamanın sürümü bekleniyor (masaüstündeki runningCheck).
    private var lgRunningCheck: TVAppRunningCheck?
    /// Bağlı TV uygulamasının son bildirdiği sürüm (boş: sürüm bildirmeyen eski uygulama); kurulum ekranı LG'ye verir.
    private(set) var runningTVAppVersion: String?
    /// Bu telefonun TV uygulamasını kurduğu ya da sürümünü okuduğu son TV.
    @Published private(set) var installedTVApp: InstalledTVApp?
    private var tvAppCheckedAt: Date?
    private var checkingTVApp = false

    @Published var settings: UserSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: StoreKey.settings) }
            server.sendStyle(settings.style)
            if settings.output != oldValue.output { outputChanged() }
            if settings.gamePacks != oldValue.gamePacks, let pipeline { connectPacks(to: pipeline) }
            pipeline?.showSpeakerNames = settings.showSpeakerNames
            if settings.autoScreenText != oldValue.autoScreenText { showsAutoScreenTextNotice = false }
            server.speakerColors = settings.speakerColors
            if settings.setTextApart != oldValue.setTextApart {
                server.setApart = settings.setTextApart
                server.sendStyle(settings.style)
            }
            if settings.sharePool != oldValue.sharePool {
                let (pool, enabled) = (pool, settings.sharePool)
                Task { await pool.setEnabled(enabled) }
            }
            let translationChanged = settings.onlineTranslation != oldValue.onlineTranslation
                || settings.onlineEngine != oldValue.onlineEngine || settings.geminiModel != oldValue.geminiModel
                || settings.openAIModel != oldValue.openAIModel || settings.claudeModel != oldValue.claudeModel
                || settings.localAIBaseURL != oldValue.localAIBaseURL || settings.localAIModel != oldValue.localAIModel
                || settings.aiInstruction != oldValue.aiInstruction || settings.geminiPaidTier != oldValue.geminiPaidTier
            if translationChanged { Task { await refreshTranslatorStatus() } }
            if settings.readsGamePhone != oldValue.readsGamePhone { configureGamePhone() }
            if settings.readsGamePhone { showsGamePhoneHint = false }
            if settings.dubbing != oldValue.dubbing { dubbingSettingsChanged() }
            // Xbox sesi çeviri sürerken hemen değişir; Xbox'a yeni oturum açılmaz (#871).
            if settings.xboxAudioOnDevice != oldValue.xboxAudioOnDevice { session?.setPlayAudio(settings.xboxAudioOnDevice) }
            if settings.misreadWaitMs != oldValue.misreadWaitMs || settings.partialWaitMs != oldValue.partialWaitMs {
                pipeline?.applyWaits(from: settings)
            }
            if isRunning, translationChanged || settings.fastSubtitleDetection != oldValue.fastSubtitleDetection {
                makePipeline()
            }
        }
    }

    // Çalışma durumu
    /// Çeviri sürüyor; hareket kapısı (Perde) bunu bütün ekranlara duyurur: sürerken sürekli animasyonlar durur.
    @Published private(set) var isRunning = false {
        didSet { if isRunning != oldValue { DSMotionState.shared.translating = isRunning } }
    }
    @Published private(set) var isStarting = false
    /// Deneme modu: konsol yerine uygulamadaki örnek kareler okunur (`DemoFrameSource`); kurulum gerekmez.
    @Published private(set) var demoMode = false
    @Published private(set) var sessionState: SessionState = .disconnected(.stopped) {
        didSet {
            if sessionState != .connecting { connectingSince = nil } else if oldValue != .connecting { connectingSince = Date() }
        }
    }
    /// "Bağlanıyor…"un başladığı an; 30 sn geçince durum satırında nedeni söylenir (`ConnectingHint`).
    private(set) var connectingSince: Date?
    /// Bağlantının ne zamandan beri gittiği: "Yeniden bağlan" düğmesi için (bkz. `offersReconnect`).
    @Published private(set) var reconnectOffer = ReconnectOffer()
    @Published private(set) var tvClients = 0
    /// TV bağlıyken bağlantı koptu ya da TV alındı göndermez oldu (`SubtitleServer.onTVStale`): durum satırı "Bağlı"
    /// yerine "Yeniden bağlanılıyor…" der; TV yeniden bağlanınca, çeviri durunca ya da `SubtitleServer.reconnectingFor`
    /// sonra "TV uygulaması bekleniyor"a döner (Mac, Windows ve Android ile aynı).
    @Published private(set) var tvReconnecting = false
    private var tvReconnectTask: Task<Void, Never>?
    /// Çeviri bir süredir sürüyor ama TV uygulaması bağlanmadı: TV kartının altında ne yapılacağı söylenir.
    @Published private(set) var tvWaitingLong = false
    /// TV uygulamasını kendiliğinden açmanın son denemesi neden olmadı (TV kartının altında tek satır); açıldıysa nil.
    @Published private(set) var tvOpenProblem: TVOpenProblem?
    /// Kayıtlı TV adresi hiç yanıt vermiyor (kapılar zaman aşımında; "reddedildi" yanıt sayılır): kart "Yanıt vermiyor —
    /// yeniden aranıyor…" der, TV ağda yeniden aranır (bkz. `checkTVReachable`). beta.89'da (Mac) modem LG TV'ye yeni
    /// adres vermişti; uygulama eski adrese gidip "TV uygulaması bekleniyor", "Key Server kapalı" diyordu.
    @Published private(set) var tvNotResponding = false
    /// "TV'yi Eşleştir" ya da "Deneme Altyazısı Gönder" eşli TV'ye ulaşamadı ve TV ağda bulunamadı: kartta bu adresle açık
    /// hata, "TV'yi Yeniden Ara" ve "IP Adresi Gir" görünür. Ulaşılınca nil.
    @Published private(set) var tvUnreachableHost: String?
    /// TV ağda aranıyor (kartta "TV'yi Yeniden Ara" beklerken).
    @Published private(set) var tvSearching = false
    /// Ağ araması en çok bu aralıkla yapılır (kullanıcı "TV'yi Yeniden Ara"ya basınca beklenmez; Mac/Windows/Android ile aynı).
    static let tvSearchInterval: TimeInterval = 30
    private var lastTVSearch: Date?
    private var tvWaitTask: Task<Void, Never>?
    static let tvWaitLimit: Duration = .seconds(30)
    /// "Test on TV"da TV uygulaması bağlı değil (ya da beklemeden sonra da bağlanmadı): eşleştirme yönergesi gösterilir.
    @Published private(set) var testTVNotConnected = false
    /// "Test on TV"da TV'nin bağlanması (gerekirse eşleştirme onayı) en çok bu kadar beklenir (Mac ile aynı).
    var testPairWait: Duration = .seconds(30)
    private var testWaitTask: Task<Void, Never>?
    @Published private(set) var lastSource = ""
    @Published private(set) var lastTranslation = ""
    /// Bu ve önceki oturumlarda çevrilen son 200 altyazı (history.json; "Geçmiş" ekranı).
    @Published private(set) var history = SubtitleHistory()
    /// Son satırın ölçümleri (yazı tanıma, çeviri, gecikme, güven).
    @Published private(set) var lastMetrics: LineMetrics?
    /// Son PS5 karesi (Ayarlar'daki bölge önizlemesi); yalnız önizleme izler.
    let framePreview = PhoneFramePreview()
    /// Geçmişin yazıldığı dosya (testlerde nil: hiçbir şey yazılmaz).
    private var historyFile: URL?
    private let historyQueue = DispatchQueue(label: "history.json", qos: .utility)
    @Published private(set) var translatorStatus: TranslatorStatus = .ready
    /// Yazı tanıma (Vision) takıldı (#679); takılan okuma bitince kendiliğinden düzelir. iPhone'da ayrı süreçte yedek
    /// okuyucu açılamaz; takılıyken yeni okuma verilmez, ana ekranda not görünür. Takılma
    /// `ReadQueue.defaultAbandonStallAfterMs`'i aşarsa ya da çeviri yeniden başlatılırsa takılan okuma bırakılır (`abandonStalledRead`).
    @Published private(set) var readingStuck = false
    @Published private(set) var onlineIssue: OnlineKeyState?
    /// Son altyazı oyun paketinden mi geldi (ana ekrandaki "paket kullanılıyor" göstergesi).
    @Published private(set) var lastFromPack = false
    /// Bu oturumda çevrilen satırlar (en yenisi başta), nereden geldikleriyle.
    @Published private(set) var recentLines: [RecentLine] = []
    /// Görüntü bir dakikadır geliyor ama bu çeviride tek altyazı satırı gösterilmedi: "oyunun kendi altyazısını açın"
    /// ipucu (CouchSubsCore SubtitleOffTip; GitHub #503, #566, #572).
    @Published private(set) var showsSubtitleOffTip = false
    /// Otomatik ekran yazısı göçle kapatıldı (beta.63'te açıktı): bu oturumda bir kez "kapatıldı; Ayarlar › Gelişmiş ›
    /// Ekran yazıları'ndan açabilirsiniz" bilgisi görünür. Kullanıcı ayarı değiştirince kalkar.
    @Published private(set) var showsAutoScreenTextNotice = false
    /// Telefon çevirisi kapalıyken GTA 6'nın telefon listesi altyazı yolunda sahne yazısı sayılıp atıldı: oturumda bir kez
    /// "Telefon çevirisi kapalı, açmak ister misiniz?" (`GamePhoneHint`, #1202; Mac ile aynı).
    @Published private(set) var showsGamePhoneHint = false
    private var gamePhoneHint = GamePhoneHint()
    private var subtitleOffTip = SubtitleOffTip()
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
    /// Telefon ekranındaki ek alan çevirileri (görev, telefon, bildirim); TV'deki gibi kendi yerlerinde küçük kutular.
    @Published private(set) var phoneRegions: [PhoneRegion] = []

    /// "Ekranı çevir" sonuçları (telefon ekranında yazının kendi yerinde); boşken görünür bir şey yok.
    @Published private(set) var screenItems: [ScreenTranslation.Item] = []
    /// "Ekranı çevir" düğmesinin durumu: çeviri sürüyor ya da sonuçlar ekranda.
    @Published private(set) var screenState: ScreenState = .idle

    enum ScreenState: Equatable { case idle, working, shown }

    struct PhoneRegion: Identifiable, Equatable {
        let id: String
        let text: String
        let box: TextBox?
        /// Bloklu alanın (GTA 6 telefonu, kendiliğinden bulunan ekran yazısı) blokları: her biri kendi yerinde ve özgün
        /// stilinde çizilir (Android ve TV ile aynı); düz ek alanlarda nil.
        var items: [ScreenTranslation.Item]? = nil
    }
    @Published private(set) var installedPacks: [GamePackLibrary.Info] = []
    /// Paketler ekranında kapatılan paketlerin kimlikleri (Android'deki gibi karoya dokunarak; UserDefaults'ta).
    @Published private(set) var disabledPacks: Set<String> = []
    /// Son satırı veren paketin başlığı (Paketler ekranındaki "Oynanıyor"); çeviri durunca silinir.
    @Published private(set) var packInUse: String?

    /// Kurulumda "Şimdilik geç" (PSN girişi ve PS5 eşleme atlandı; eşleme sonra Profil ya da Ayarlar'dan).
    static let setupSkippedKey = "setupSkipped"
    static let disabledPacksKey = "disabledPacks"
    /// Profil'deki "PS5 bağlantısı koptuğunda bildir" tercihi (varsayılan açık, Android ile aynı).
    static let notifyDisconnectKey = "notifyDisconnect"
    /// "Arka planda sürdür (Resim içinde resim)" (varsayılan açık, Android ile aynı ad ve açıklama; bkz. BackgroundPiP).
    static let backgroundPiPKey = "backgroundPiP"
    @Published var backgroundPiP: Bool {
        didSet { defaults.set(backgroundPiP, forKey: Self.backgroundPiPKey) }
    }

    /// Çeviri sürerken ekran kararmasın (iOS uygulamayı askıya alınca bağlantı da durur). Uygulama UIKit'e bağlar.
    var keepScreenAwake: (Bool) -> Void = { _ in }
    /// Ölçüm olayları (Firebase Analytics, Meta); uygulama `AppModel.analytics`'e bağlar.
    var onAnalytics: (AnalyticsEvent) -> Void = { _ in }
    /// PS5 bağlantısı kendiliğinden koptu (kullanıcı durdurmadı). Uygulama, etkin değilken yerel bildirim gösterir;
    /// testlerde boş.
    var onConnectionLost: () -> Void = {}
    /// Çeviri sürerken uygulama arka plana geçti ya da ekran kilitlendi: Resim içinde resim penceresi açılmazsa iOS
    /// uygulamayı kısa süre sonra askıya alır ve altyazı durur. Uygulama gecikmeli bir yerel bildirim kurar; pencere
    /// açılınca ya da `onResumedFromBackground` onu geri alır. Testlerde boş.
    var onPausedInBackground: () -> Void = {}
    /// Uygulama yeniden öne geldi: arka planda kurulan bildirim (henüz gösterilmediyse) iptal edilir, gösterildiyse silinir.
    var onResumedFromBackground: () -> Void = {}
    /// PS5'te yeni bir oyun tanındı (paket sunucusuna o oyun için bakılır).
    var onGameStarted: () -> Void = {}
    /// Çeviri başlarken bildirim izni istenir (tercih açıksa; iOS yalnız ilk seferde sorar). Testlerde boş.
    var requestNotificationPermission: () -> Void = {}
    /// Uzun oturum tanısı (SessionHealth): satır çökme raporunun izine de yazılır (Crashlytics). Testlerde boş.
    var onDiagnostic: (String) -> Void = { _ in }
    private var startedAt: Date?
    /// On dakikada bir sağlık satırı yazan iş; çeviri sürerken var.
    private var healthTask: Task<Void, Never>?
    /// Bu oturumda iOS'un gönderdiği bellek uyarıları.
    private var memoryWarnings = 0

    private let services: PhoneServices
    private let store: AppStore
    private let defaults: UserDefaults
    private var server = SubtitleServer(port: AppIdentity.serverPort)
    /// Oturumun konuşan renkleri (TV'ye gidenle aynı; telefondaki altyazı ekranı buradan boyar).
    var speakerBook: SpeakerColorBook { server.speakerBook }
    private var serverStarted = false
    private var serverRestarting = false
    @Published private(set) var serverPort: UInt16 = AppIdentity.serverPort
    private var session: StreamControlling?
    private var keeper: KeeperControlling?
    /// Her yeni bekçide artar: durdurulan bekçinin geç gelen açma sonucu yenisininkiyle karışmaz.
    private var keeperGeneration = 0
    private var pipeline: SubtitlePipeline?
    /// Ek alanları (görev, telefon, bildirim) okuyup çeviren; çeviri sürerken ve ek alan varken var (Mac ile aynı).
    private var regionWatcher: RegionWatcher?
    /// GTA 6'daki oyun telefonunun pozu ("GTA 6'daki telefonu otomatik çevir" açıkken ve oyun GTA 6 iken; Mac ile aynı).
    private var gamePhoneTracker: GamePhoneTracker?
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
    /// Hatta aynı anda tek kare girer. Durdurma ve yeni hat kapıyı sıfırlar; takılan okuma hattı yeniden kurdurur (Mac ile aynı).
    private var frameGate = FrameGate()
    /// Okuma sürerken atlanan son kare; okuma bitince okunur (bkz. `FrameGate.leave`).
    private var skippedFrame: (frame: CGImage, capturedAt: Int)?
    /// Çözücüden gelen son kare (ana iş parçacığında bekleyen en çok bir kare); çeviri sürerken var.
    private var frameMailbox: FrameMailbox<(frame: CGImage, capturedAt: Int)>?
    private var savedKeys: Set<TranslationEngine> = []
    private var stack = SubtitleStack()
    private var stackTimer: Task<Void, Never>?
    /// Süren "ekranı çevir" işi ve sonuçların kalkma zamanlayıcısı.
    private var screenTask: Task<Void, Never>?
    private var screenExpiry: Task<Void, Never>?
    /// Ekrandaki son sonuçlar ve kalkacakları an (sonuçlar bilgisayar çıkışında değilse de); telefon kartı izlenirken
    /// süre bunlarla uzatılır.
    private var screenShown: [ScreenTranslation.Item] = []
    private var screenShownUntil = Date.distantPast
    /// Telefon kartı ekrandayken sohbeti izleyen yoklama (`ScreenPhoneFollow`); kart yoksa nil.
    private var screenFollow: ScreenPhoneFollow?
    private var screenFollowTask: Task<Void, Never>?
    /// "Ekranı çevir" çevirilerinin hafızası (telefon mesajları sohbet başlığıyla); dil ya da motor değişince yenilenir.
    private var screenMemory = PhoneChatMemory()
    private var screenMemoryKey = ""
    /// Yığının saati (saniye); testlerde ileri sarılır.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Oyun paketleri: uygulamayla gelenler ve sunucudan indirilen güncel sürümleri (ücretsiz, herkese).
    let packs: GamePackLibrary
    private let pool: LinePool
    /// Oynanan oyun: PS5'in bildirdiği, kullanıcının seçtiği ya da paketten tanınan (havuza giden satırlar bu oyunla gider).
    let gameChoice: GameChoice
    /// Oyuna göre alanlar: oyun değişince kayıtlı alanları uygular ya da önerir (bkz. CouchSubsCore GameAreas).
    lazy var gameAreas = GameAreas(read: { [weak self] in self?.settings ?? UserSettings() },
                                   write: { [weak self] in self?.settings = $0 })
    /// Bağlıyken birkaç dakikada bir PS5'e çalışan oyunu sorar (havuza giden satırlar oyunla gider). Testlerde kapalı.
    private var gameProbe: Task<Void, Never>?
    private let probesGame: Bool
    static let gameProbeInterval: Duration = .seconds(120)

    init(services: PhoneServices = LivePhoneServices(), store: AppStore = KeychainStore(), defaults: UserDefaults = .standard,
         packs: GamePackLibrary = GamePackLibrary(bundled: nil, user: nil)) {
        self.services = services
        self.store = store
        self.defaults = defaults
        self.packs = packs
        backgroundPiP = defaults.object(forKey: Self.backgroundPiPKey) as? Bool ?? true
        let accountId = store.load(Data.self, for: StoreKey.accountId)
        let console = store.load(RegisteredConsole.self, for: StoreKey.console)
        let tv = store.load(LGTV.self, for: StoreKey.tv)
        let tvKeySaved = store.load(String.self, for: StoreKey.tvKey) != nil
        self.accountId = accountId
        self.console = console
        self.tv = tv
        self.tvKeySaved = tvKeySaved
        hasLoginPasscode = LoginPasscode.normalized(store.load(String.self, for: StoreKey.loginPasscode)) != nil
        let savedPlatform = defaults.string(forKey: XboxStoreKey.platform).flatMap(ConsolePlatform.init(rawValue:))
        platform = savedPlatform ?? .playstation
        // PS5'i önceden eşlenmiş kurulumlar PlayStation sayılır, yeniden sorulmaz.
        platformChosen = savedPlatform != nil || accountId != nil || console != nil
        xboxConsole = store.load(XboxConsole.self, for: XboxStoreKey.console)
        let xboxToken = XboxUserToken.parse(store.load(String.self, for: XboxStoreKey.userToken))
        xboxSignedIn = xboxToken != nil
        let tokenSink = XboxTokenSink()
        self.tokenSink = tokenSink
        xboxAuth = XboxAuth(userToken: xboxToken, onUserToken: { token in tokenSink.handler?(token) })
        let loaded = defaults.data(forKey: StoreKey.settings).flatMap { try? JSONDecoder().decode(UserSettings.self, from: $0) }
        // Uygulama oturum sürerken kapandıysa oyunun profili açık kalmış olabilir: genel alanlar geri gelir.
        var curated = GameAreas.restored((loaded ?? UserSettings()).withCuratedModels())
        // beta.63'te varsayılan açık gelen otomatik ekran yazısı bir kez kapatılır; açık olanlara bir kez söylenir.
        let autoScreenTextNotice = curated.migratingAutoScreenText()
        // Otomatik ekran yazısı kapalıyken hazır alanlar ve GTA 6 telefonu da bir kez kapatılır (altyazı dışında çeviri yok).
        curated.migratingScreenTextExtras()
        // GTA 6 telefonu eski göçle kapalı kaldıysa bir kez açılır (#1202; Mac, Windows, Android ile aynı).
        curated.migratingGamePhone()
        settings = curated
        showsAutoScreenTextNotice = autoScreenTextNotice
        if loaded?.autoScreenTextReset != true || loaded?.screenTextExtrasReset != true, let data = try? JSONEncoder().encode(curated) {
            defaults.set(data, forKey: StoreKey.settings)
        }
        // "Şimdilik geç" ile PSN ve PS5 atlandıysa PS5'siz ana ekrana gidilir; altyazı hedefi seçilmediyse oradan sürer.
        let skipped = defaults.bool(forKey: Self.setupSkippedKey)
        let done = (skipped || accountId != nil && console != nil) && store.load(Bool.self, for: StoreKey.setupComplete) == true
        let xboxReady = savedPlatform == .xbox && xboxToken != nil && store.load(XboxConsole.self, for: XboxStoreKey.console) != nil
        let doneAny = (done || xboxReady && store.load(Bool.self, for: StoreKey.setupComplete) == true)
        step = doneAny ? .done : skipped ? .output : .welcome
        disabledPacks = Set(defaults.stringArray(forKey: Self.disabledPacksKey) ?? [])
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !testing {
            RemotePlayLog.enable()
            RemotePlayLog.write("CouchSubs iOS \(AppIdentity.version)")
            // altyazi.log Mac'teki gibi yazılır; Profil › Hakkında › "Günlükleri paylaş" ile gönderilir.
            SubtitleLog.enable()
        }
        let poolFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true).appendingPathComponent("pool.json")
        pool = LinePool(file: poolFile, app: AppIdentity.version, platform: "ios", enabled: curated.sharePool && !testing)
        probesGame = !testing
        gameChoice = GameChoice(defaults: defaults)
        savedKeys = Set(TranslationEngine.allCases.filter { engine in
            engine.storeKey.flatMap { store.load(String.self, for: $0) }?.isEmpty == false
        })
        installedTVApp = defaults.data(forKey: StoreKey.tvAppInstalled).flatMap { try? JSONDecoder().decode(InstalledTVApp.self, from: $0) }
        let storedKey = store.load(String.self, for: StoreKey.subtitleAccessKey)
        let accessKey = storedKey?.isEmpty == false ? storedKey! : SubtitleAccess.createKey()
        store.save(accessKey, for: StoreKey.subtitleAccessKey)
        server.rotateKey(accessKey)
        subtitleAccessKey = accessKey
        attachServer()
        reloadPackList()
        let pool = self.pool
        gameChoice.onChange = { [weak self] game in
            self?.regionWatcher?.reset()
            self?.configureGamePhone()
            Task { await pool.setGame(game) }
            // Bu oyunun (havuzdan otomatik) paketi sunucuda yeni çıkmış olabilir.
            if game != nil { self?.onGameStarted() }
        }
        gameChoice.onPublish = { [weak self] game, source in self?.gameAreas.follow(game: game, source: source) }
        // Xbox'ta oyunun tanınmadığı ya da elle seçildiği günlükte tek satır (Mac, Windows, Android ile aynı).
        gameChoice.onLog = { SubtitleLog.write($0) }
        // Ayarlar'da oyun profili seçilince ya da yeni profil açılınca oynanan oyun o olur.
        gameAreas.onChoose = { [weak self] name in self?.gameChoice.choose(name) }
        gameChoice.packTitles = { [weak self] in GameCatalog.packGames(self?.installedPacks ?? []) }
        // Elle seçilen oyunda satırlar yalnız o oyunun paketinde aranır, paketi yoksa hiç aranmaz (#218).
        gameChoice.packs = packs
        // Kullanıcı jetonu her yenilendiğinde Anahtar Zinciri'ne yazılır (Windows'taki DPAPI, Android'deki Keystore).
        tokenSink.handler = { [weak self, store] token in
            if let token { store.save(token.serialize(), for: XboxStoreKey.userToken) } else { store.remove(XboxStoreKey.userToken) }
            Task { @MainActor in self?.xboxSignedIn = token != nil }
        }
    }

    // MARK: - Xbox (Beta)

    func choosePlatform(_ value: ConsolePlatform) {
        platform = value
        platformChosen = true
        defaults.set(value.rawValue, forKey: XboxStoreKey.platform)
    }

    func chooseXbox(_ console: XboxConsole) {
        xboxConsole = console
        store.save(console, for: XboxStoreKey.console)
    }

    func signOutXbox() {
        Task { await xboxAuth.signOut() }
        xboxSignedIn = false
    }

    /// PSN'den çıkış: ikinci hesabın kimliği ve PS5 eşleşmesi (PS5 o hesaba bağlıdır) bu telefondan silinir. Eskiden
    /// yanlış hesapla girenin kurulumu baştan almaktan başka yolu yoktu (TestFlight). TV ve çeviri ayarları kalır.
    func signOutPSN() {
        stop()
        [StoreKey.accountId, StoreKey.console, StoreKey.loginPasscode].forEach(store.remove)
        accountId = nil
        console = nil
        hasLoginPasscode = false
        RemotePlayLog.write("PSN hesabından çıkıldı; PS5 eşleşmesi silindi")
    }

    var isXbox: Bool { platform == .xbox }

    /// Ayarlardaki paket listesi; paketler güncellenince yeniden okunur.
    func reloadPackList() {
        let packs = self.packs
        Task { [weak self] in
            let list = await Task.detached(priority: .utility) { packs.packs }.value
            self?.installedPacks = list
        }
    }

    @Published private(set) var subtitleAccessKey = ""
    @Published private(set) var legacyTVWarning = false
    /// TV'nin onay bekleyen eşleştirme isteği. Onay penceresi ve her ekranın üstündeki "TV eşleşmek istiyor" satırı
    /// bunu gösterir; sunucudaki istekle `syncTVPairing` eşitler (süresi dolan ya da yerini yenisi alan istek kalkar).
    @Published var tvPairingRequest: SubtitlePairing.Ticket?
    /// "TV eşleştir"e basıldı: TV'de ne yapılacağı Ayarlar'da yazılır (eskiden düğme hiçbir şey göstermiyordu).
    @Published private(set) var tvPairingOpened = false
    private var tvPairingWatch: Task<Void, Never>?
    func resolveTVPairing(_ ticket: SubtitlePairing.Ticket, accept: Bool) {
        let resolved = server.pairing.resolve(ticket.id, accept: accept)
        SubtitleLog.write("TV eşleştirme isteği \(accept ? "onaylandı" : "reddedildi")\(resolved ? "" : " (istek artık geçerli değil)")")
        if resolved, accept {
            tvPairingOpened = false
            adoptPairedTV(host: ticket.host)
        }
        tvPairingRequest = nil
        // Onaylanan istek geçersizdiyse (süresi doldu, TV yeniden denedi) bekleyen yeni istek hemen gösterilir.
        syncTVPairing()
    }

    /// TV'nin kendisi başlattığı eşleşme onaylandı: TV, listeden elle seçilmiş gibi eşlenir ve kaydedilir (adres, marka, ad,
    /// LG izni / Samsung jetonu; bkz. `PairedTV`). Eskiden yalnız altyazı anahtarı TV'ye gidiyordu: TV kaydı olmadığı için
    /// TV bekçisi (otomatik açma) hiç çalışmıyor, ana ekranda TV kartı çıkmıyordu (PR #870 incelemesi).
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

    /// Arayüzdeki isteği sunucudaki bekleyen istekle eşitler. İstek geldiğinde, uygulama öne geldiğinde ve istek
    /// beklerken saniyede bir çağrılır: gösterilemeyen istek kaybolmaz, geçersiz istek ekranda kalmaz.
    func syncTVPairing() {
        let pending = server.pairing.pending
        if tvPairingRequest != pending { tvPairingRequest = pending }
        guard pending != nil, tvPairingWatch == nil else { return }
        tvPairingWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let pending = self.server.pairing.pending
                if self.tvPairingRequest != pending { self.tvPairingRequest = pending }
                if pending == nil { self.tvPairingWatch = nil; return }
            }
        }
    }
    var subtitleViewerAddress: String { "http://\(NetworkAddress.near(nil) ?? "127.0.0.1"):\(serverPort)/obs?k=\(subtitleAccessKey)" }
    /// "Başka bir cihazda göster" adresi (QR kodu da bundan); telefon ağa bağlı değilse nil.
    var secondScreenAddress: String? {
        NetworkAddress.near(nil).map { SecondScreen.address(host: $0, port: Int(serverPort), key: subtitleAccessKey) }
    }
    /// Ayarlar'daki "TV eşleştir": çeviri sürse de sürmese de eşleştirmeyi iki dakika açar, yanıt vermeyen sunucuyu
    /// yeniden açar ve bekleyen istek varsa onay penceresini yeniden gösterir (kurtarma yolu).
    func openTVPairing() async {
        await confirmTVReachable()
        if serverStarted { await reviveServerIfSilent() } else { await ensureServer() }
        guard serverStarted else { SubtitleLog.write("TV eşleştirme sunucusu açılamadı."); return }
        server.pairing.open()
        tvPairingOpened = true
        SubtitleLog.write("TV eşleştirme elle açıldı (2 dk); port=\(serverPort)")
        syncTVPairing()
    }

    /// Ayarlar › TV kartındaki "TV'de CouchSubs'ı Aç": TV eşli ama uygulama bağlı değilken eşleştirmeyi yeniden istemek
    /// yerine iki dakikalık onay açılır, çeviri sürüyorsa bekçi TV uygulamasını hemen açar ve bağlanması beklenir
    /// (Mac ve Windows ile aynı). TV uygulaması bağlandıysa true.
    func openTVAppOnTV() async -> Bool {
        guard hasTV else { return false }
        await openTVPairing()
        guard tvUnreachableHost == nil else { return false }
        if server.connectedClients == 0, isRunning { retryTVOpen() }
        let deadline = ContinuousClock.now + testPairWait
        while server.connectedClients == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return server.connectedClients > 0
    }

    func rotateSubtitleKey() {
        let key = SubtitleAccess.createKey()
        store.save(key, for: StoreKey.subtitleAccessKey)
        keeper?.stop()
        keeper = nil
        server.rotateKey(key)
        tvPairingRequest = nil
        tvPairingOpened = false
        subtitleAccessKey = key
        startKeeper()
    }

    private func attachServer() {
        // Bekçi TV'nin listesinde CouchSubs'ın silindiğini gördü (#1158): telefondaki "kurulu" kaydı da silinir.
        SamsungAppKnowledge.onMissing = { [weak self] host in
            Task { @MainActor [weak self] in self?.samsungAppMissing(host: host) }
        }
        server.onPairingRequest = { [weak self] ticket in
            Task { @MainActor [weak self] in
                SubtitleLog.write("TV eşleştirme istedi; onay bekleniyor")
                self?.syncTVPairing()
            }
        }
        server.onLegacyClient = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.legacyTVWarning = true
                SubtitleLog.write("TV bağlantısı geçiş izniyle anahtarsız açıldı; TV uygulamasını güncelleyin.")
            }
        }
        server.onTVAppVersion = { [weak self] version in
            Task { @MainActor [weak self] in self?.tvAppReported(version) }
        }
        shareLatestTVAppVersion()

        server.onClientsChanged = { [weak self] count in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let connected = self.tvClients == 0 && count > 0
                    let lost = self.tvClients > 0 && count == 0
                    self.tvClients = count
                    if count == 0 { self.runningTVAppVersion = nil }
                    if count > 0 { self.endTVReconnecting() } else if lost { self.tvLost(stale: false) }
                    if count > 0 {
                        self.tvWaitingLong = false
                        self.tvOpenProblem = nil
                        // TV uygulaması bağlandı: TV yanıt veriyor.
                        self.tvNotResponding = false
                        self.tvUnreachableHost = nil
                    }
                    // TV uygulaması bağlandı: bu Samsung TV'de kurulu olduğu artık biliniyor (bekçi listeye bakmadan açar).
                    if count > 0, let tv = self.tv, tv.brand == .samsung { SamsungAppKnowledge.shared.mark(host: tv.host) }
                    // TV uygulaması her bağlandığında sürümüne bakılır (eskiyse ana ekranda güncelleme önerilir).
                    if connected { Task { await self.checkTVApp() } }
                }
            }
        }
        server.onListenerFailed = { [weak self] reason in
            Task { @MainActor [weak self] in self?.serverDropped(reason) }
        }
        server.onTVStale = { [weak self] in
            Task { @MainActor [weak self] in self?.tvLost(stale: true) }
        }
        server.sendsToTV = settings.output.showsOnTV
        server.speakerColors = settings.speakerColors
        server.setApart = settings.setTextApart
        server.onEvent = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.phoneReceive(event) } }
        }
    }

    // MARK: - Kurulum

    var canAdvance: Bool {
        switch step {
        case .welcome: true
        case .psnLogin: isXbox ? xboxSignedIn : accountId != nil
        case .console: isXbox ? xboxConsole != nil : console != nil
        case .output: hasTV || !settings.output.showsOnTV
        case .hdmi: true
        case .done: false
        }
    }

    func advance() {
        guard canAdvance, var next = Step(rawValue: step.rawValue + 1) else { return }
        if next == .hdmi && !asksTVInput { next = .done }
        step = next
    }

    /// Kurulumda "Şimdilik geç": PSN girişi ve PS5 eşleme atlanır, altyazı hedefinden sonra PS5'siz ana ekrana geçilir.
    func skipSetup() {
        defaults.set(true, forKey: Self.setupSkippedKey)
        step = .output
    }

    var notifiesDisconnect: Bool { defaults.object(forKey: Self.notifyDisconnectKey) as? Bool ?? true }

    func back() {
        guard var previous = Step(rawValue: step.rawValue - 1) else { return }
        if previous == .hdmi && !asksTVInput { previous = .output }
        step = previous
    }

    var hasTV: Bool { tv != nil && tvKeySaved }

    /// TV girişi (HDMI) sorulur mu: TV eşli, altyazı TV'de ve TV Android TV değil (Android TV uygulaması görüntüyü kendi
    /// gösterir; Mac'teki `asksTVInput` ile aynı kural).
    var asksTVInput: Bool { hasTV && settings.output.showsOnTV && tv?.brand != .androidTV }

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
        let savedKey = store.load(String.self, for: StoreKey.tvKey)
        let pairing = try await services.pairTV(tv, key: savedKey, server: serverAddress(for: tv), accessKey: server.accessKey)
        self.tv = tv
        store.save(tv, for: StoreKey.tv)
        // Samsung jetonla gelen bağlantıda jetonu yeniden göndermeyebilir; boş jeton saklı olanı silmez (#40).
        store.save(SamsungTokenHolder.keptToken(stored: savedKey, received: pairing.key), for: StoreKey.tvKey)
        tvKeySaved = true
        tvAppMissing = !pairing.launched
        // "Yalnız OBS (yayın)" seçiliyken TV eşlenirse de altyazı TV'ye gider (Android'de TV seçilince olduğu gibi).
        if !settings.output.showsOnTV { settings.output = .tv }
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
        [StoreKey.accountId, StoreKey.console, StoreKey.tv, StoreKey.tvKey, StoreKey.setupComplete, StoreKey.loginPasscode]
            .forEach(store.remove)
        hasLoginPasscode = false
        accountId = nil
        console = nil
        store.remove(XboxStoreKey.console)
        xboxConsole = nil
        signOutXbox()
        defaults.removeObject(forKey: XboxStoreKey.platform)
        platform = .playstation
        platformChosen = false
        tv = nil
        tvKeySaved = false
        tvAppMissing = false
        tvNotResponding = false
        tvUnreachableHost = nil
        defaults.removeObject(forKey: Self.setupSkippedKey)
        step = .welcome
    }

    // MARK: - Çeviri

    var canStart: Bool {
        let paired = isXbox ? xboxConsole != nil && xboxSignedIn : console != nil && accountId != nil
        return paired && settings.output.hasDestination(hasTV: hasTV)
    }

    /// Deneme modunu açar: konsol, hesap ve TV olmadan örnek karelerle çeviri başlar (altyazı bu ekranda görünür; TV
    /// kuruluysa orada da). Çalışan çeviri önce durdurulur.
    func startDemo() async {
        guard !isStarting else { return }
        if isRunning { stop() }
        demoMode = true
        await start()
        if !isRunning { demoMode = false }
    }

    /// Deneme modundan çıkar; uygulama kaldığı yere (kurulum ya da ana ekran) döner.
    func exitDemo() {
        stop()
        demoMode = false
    }

    func start() async {
        guard !isRunning, !isStarting, canStart || demoMode else { return }
        let xbox = isXbox && !demoMode ? xboxConsole : nil
        guard demoMode || xbox != nil || console != nil && accountId != nil else { return }
        isStarting = true
        defer { isStarting = false }
        await refreshTranslatorStatus()
        // Eskiden hata try? ile yutuluyordu: sunucu açılamazsa çeviri "sürüyor" görünüp TV hiç bağlanamıyordu.
        await ensureServer()
        server.sendStyle(settings.style)
        // Konuşan renkleri oturum başına: yeni oturumda kişiler yeniden sıralanır.
        server.speakerBook.reset()
        makePipeline()
        // Mac'teki gibi: altyazı günlüğünde oturumun dili, motoru ve alanı (günlükten teşhis için).
        SubtitleLog.write("oturum başladı: CouchSubs iOS \(AppIdentity.version), \(settings.sourceLanguage)→\(settings.targetLanguage), "
            + "motor: \(onlineTranslationActive ? settings.onlineEngine.rawValue : "ücretsiz"), "
            + "seçilen motor: \(settings.translationEngine.rawValue), paketler: \(settings.gamePacks ? "açık" : "kapalı"), "
            + "görüntü: \(demoMode ? "deneme modu" : xbox != nil ? "Xbox (Beta)" : "PS5"), " + SubtitleLog.areaSummary(settings))
        guard let (session, consoleName) = makeSession(xbox: xbox) else { return }
        // "Durdur / Başlat" takılı okumayı da bırakır: eskiden iPhone'da takılan okuma bitmezse yalnız uygulamayı kapatıp
        // açmak düzeltiyordu.
        abandonStalledRead(olderThanMs: 0)
        session.start()
        self.session = session
        reconnectOffer.reset(now: Date())
        startKeeper()
        // Deneme karelerinde oyun yoktur: oyun sorulmaz, oyuna göre alan uygulanmaz.
        if !demoMode {
            gameAreas.start()
            // Xbox çalışan oyunu bildirmez: Xbox için son seçilen oyun kendiliğinden kullanılır, hiç seçim yoksa Oyun
            // satırı vurgulanır (`GameChoice.xboxNeedsGame`).
            gameChoice.start(console: consoleName, xbox: xbox != nil) { [weak self] in
                guard let self else { return false }
                return self.settings.askGame && self.settings.sharePool
            }
        }
        server.pairing.setSession(true)
        isRunning = true
        // Telefonun adresi değişince (modem yeniden başladı, başka Wi-Fi) TV'ye yeni adres hemen bildirilir.
        addressWatcher?.stop()
        addressWatcher = services.makeAddressWatcher { [weak self] old, new in
            Task { @MainActor in self?.senderAddressChanged(old: old, new: new) }
        }
        startedAt = Date()
        runningSince = startedAt
        recentLines = []
        subtitleOffTip.reset()
        updateSubtitleOffTip()
        gamePhoneHint.reset()
        showsGamePhoneHint = false
        lastMetrics = nil
        sessionLines = 0
        sessionPackLines = 0
        packInUse = nil
        keepScreenAwake(true)
        startHealth()
        watchTVConnection()
        if notifiesDisconnect { requestNotificationPermission() }
        onAnalytics(.sessionStart(output: settings.output.rawValue))
    }

    /// Konsol oturumunu kurar ve olaylarını modele bağlar (başlatmaz). "Çeviriyi başlat" ve "Yeniden bağlan" kullanır.
    private func makeSession(xbox: XboxConsole?) -> (StreamControlling, String)? {
        let session: StreamControlling
        let consoleName: String
        if demoMode {
            RemotePlayLog.write("Deneme modu başladı (örnek kareler)")
            session = DemoStream()
            consoleName = ""
        } else if let xbox {
            RemotePlayLog.write("Çeviri başladı; Xbox'a bağlanılıyor (Beta): \(xbox.name)")
            session = XboxStreamSession(auth: xboxAuth, console: xbox, playAudio: settings.xboxAudioOnDevice,
                                        describe: XboxText.session, stopped: XboxText.stopped)
            consoleName = xbox.name.isEmpty ? "Xbox" : xbox.name
        } else if let console, let accountId {
            RemotePlayLog.write("Çeviri başladı; PS5'e bağlanılıyor: \(console.name) \(console.host)")
            session = services.makeStream(console: console, accountId: accountId,
                                          loginPasscode: store.load(String.self, for: StoreKey.loginPasscode))
            consoleName = console.name.isEmpty ? console.host : console.name
        } else { return nil }
        // Yeniden bağlanırken kapatılan eski oturumun geç gelen olayı (Xbox'ta "durdu") yeni oturumun durumunu ezmez.
        session.onState = { [weak self, weak session] state in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.sessionStateChanged(state)
            }
        }
        session.onConsoleMoved = { [weak self] moved in Task { @MainActor in self?.consoleMoved(moved) } }
        // Kareler ana iş parçacığına tek gözlü kutudan gider: eskiden her kare (saniyede 20) ayrı bir ana iş parçacığı işi
        // kuruyordu; ana iş parçacığı yavaşlayınca işler 8 MB'lık kareleriyle birikiyor, dokunuşlar ("Çeviriyi durdur")
        // ve ekran dönüşü gecikiyordu (TestFlight, X). Yetişilemeyen kare atlanır (bkz. FrameMailbox).
        let mailbox = FrameMailbox<(frame: CGImage, capturedAt: Int)>()
        session.onFrame = { [weak self] frame in
            // Karenin geldiği an: gecikme buradan TV'ye gidene kadar ölçülür.
            guard mailbox.put((frame, SubtitleStabilizer.uptimeMs())) else { return }
            Task { @MainActor in
                while let next = mailbox.take() {
                    self?.handle(next.frame, capturedAt: next.capturedAt)
                    await Task.yield()
                }
            }
        }
        frameMailbox = mailbox
        return (session, consoleName)
    }

    /// "Yeniden bağlan" (ve oturumun bıraktığı bağlantıda öne dönüş): konsol oturumu kapatılıp yenisi açılır, TV bağlantısı
    /// ve altyazı sunucusu yoklanır. Çeviri sürer (geçmiş, oyun seçimi, süre korunur). Eskiden oturum yeniden denemeyi
    /// bırakınca (görüntü gelmiyor, PS5'te Uzaktan Oynatma çöktü, Xbox denemeleri bitti) ya da uzun süre bağlanamayınca
    /// tek çare uygulamayı kapatıp açmaktı (TestFlight, iPhone).
    func reconnect(reason: String = "kullanıcı") {
        guard isRunning, !isStarting else { return }
        let xbox = isXbox && !demoMode ? xboxConsole : nil
        RemotePlayLog.write("Yeniden bağlanılıyor (\(reason)); son durum: \(sessionState)")
        SubtitleLog.write("bağlantı yeniden kuruluyor (\(reason))")
        session?.stop()
        session = nil
        frameMailbox?.clear()
        frameGate.reset()
        skippedFrame = nil
        abandonStalledRead(olderThanMs: 0)
        guard let (session, _) = makeSession(xbox: xbox) else { return }
        sessionState = .connecting
        session.start()
        self.session = session
        reconnectOffer.reset(now: Date())
        if keeper == nil { startKeeper() } else { keeper?.reconnect() }
        Task { await reviveServerIfSilent() }
    }

    /// Ana ekrandaki "Yeniden bağlan" düğmesi görünsün mü (bkz. `ReconnectOffer`).
    func offersReconnect(now: Date = Date()) -> Bool {
        guard isRunning, !demoMode else { return false }
        return reconnectOffer.shows(gaveUp: session?.hasGivenUp ?? false, now: now)
    }

    /// Oturum yeniden denemeyi bıraktıysa uygulama öne dönünce kendiliğinden yeniden bağlanılır mı. Kayıt ya da giriş
    /// şifresi sorununda hayır: aynı yere çıkar (yanlış şifre yeniden gönderilmez); kullanıcı düzeltip düğmeye basar.
    static func reconnectsOnReturn(after state: SessionState) -> Bool {
        guard case .disconnected(let reason) = state else { return true }
        switch reason {
        // PS5 oturumu bilerek iki kez kapattı: kendiliğinden yeniden bağlanmak PS5'teki oyunu yine böler (GitHub #353).
        case .registrationInvalid, .loginPasscode, .loginPasscodeIncorrect, .stopped, .consoleClosedRepeatedly: return false
        default: return true
        }
    }

    func stop() {
        if let startedAt {
            let seconds = Int(Date().timeIntervalSince(startedAt))
            onAnalytics(.sessionStop(seconds: seconds))
            defaults.set(seconds, forKey: "lastSessionSeconds")
            self.startedAt = nil
        }
        healthTask?.cancel()
        healthTask = nil
        dubber?.stop()
        tvWaitTask?.cancel()
        tvWaitTask = nil
        tvWaitingLong = false
        tvOpenProblem = nil
        endTVReconnecting()
        SessionHealth.saveMark(nil, defaults)
        runningSince = nil
        packInUse = nil
        gameChoice.stop()
        gameAreas.stop()
        session?.stop()
        session = nil
        updateGameProbe(connected: false)
        keeper?.stop()
        keeper = nil
        pipeline?.reset()
        if pipeline != nil { SubtitleLog.write("oturum bitti") }
        pipeline = nil
        menuSender = nil
        regionWatcher?.reset()
        regionWatcher = nil
        screenTextDetector?.reset()
        gamePhoneTracker = nil
        frameMailbox?.clear()
        frameMailbox = nil
        // Yeni "Başlat" eski oturumdan kalan (belki takılmış) okumayı beklemeden temiz başlar.
        frameGate.reset()
        skippedFrame = nil
        server.pairing.setSession(false)
        tvPairingRequest = nil
        tvPairingOpened = false
        isRunning = false
        addressWatcher?.stop()
        addressWatcher = nil
        onlineIssue = nil
        sessionState = .disconnected(.stopped)
        reconnectOffer.reset()
        subtitleOffTip.reset()
        updateSubtitleOffTip()
        phoneHide()
        keepScreenAwake(false)
    }

    /// Çeviri sürerken telefonun ev ağı adresini izler (bkz. `senderAddressChanged`).
    private var addressWatcher: AddressWatching?

    /// Telefonun ev ağı adresi değişti (modem yeniden başladı, Wi-Fi değişti): TV bekçisi yeni adresle yeniden kurulur;
    /// LG ve Samsung'da açma komutu, Android TV'de adres komutu yeni sunucu adresini TV'ye hemen götürür. Eskiden TV eski
    /// adrese bağlanmaya çalışıp ağı taramaya düşüyordu (Mac, Windows ve Android ile aynı).
    func senderAddressChanged(old: [String], new: [String]) {
        guard isRunning else { return }
        SubtitleLog.write(SenderAddressWatcher.line(old: old, new: new))
        guard keeper != nil else { return }
        keeper?.stop()
        keeper = nil
        startKeeper()
        keeper?.reconnect()
    }

    /// Uygulama yeniden öne gelince (iOS arka planda bağlantıları keser) PS5 ve TV bağlantıları hemen yenilenir.
    /// Arka plana gitmeden yalnız etkin olmaktan çıkıp dönünce (Denetim Merkezi, bildirim, izin penceresi) çalışan PS5
    /// oturumu kapatılıp açılmaz: eskiden her dönüşte kapatılıyor, PS5'te ikinci hesap girip çıkıyordu.
    func becameActive(afterBackground: Bool = true) {
        if afterBackground { onResumedFromBackground() }
        // iOS askıdayken altyazı sunucusunun dinleyicisini kapatabiliyor; dönüşte açık değilse yeniden açılır.
        // Dinleyici "açık" görünse de askıdan sonra bağlantı kabul etmeyebilir: kendi adresinden sorulur, yanıt yoksa
        // yeniden açılır (TV uygulaması telefonu bulamıyor, telefon "TV uygulaması bekleniyor"da kalıyordu).
        if afterBackground, isRunning || serverStarted { Task { await reviveServerIfSilent() } }
        // Uygulama öndeyken gösterilemeyen (ya da arka plandayken gelen) eşleştirme isteği yeniden gösterilir.
        syncTVPairing()
        guard isRunning else { return }
        if afterBackground { markBackground(false) }
        if session?.hasGivenUp == true {
            // Oturum yeniden denemeyi bırakmıştı: `reconnectNow` bir şey yapmaz, kullanıcı uygulamayı kapatıp açmak zorunda
            // kalıyordu. Arka planda (PiP) görüntü çözülemeyince "görüntü gelmiyor" diye bırakılabiliyor; dönüşte yeni
            // oturum açılır. Kayıt ya da giriş şifresi sorununda açılmaz (aynı yere çıkar; düğme görünür).
            if Self.reconnectsOnReturn(after: sessionState) { return reconnect(reason: "öne dönüş; oturum yeniden denemeyi bırakmıştı") }
        } else if afterBackground || !Self.isLive(sessionState) {
            session?.reconnectNow()
        }
        keeper?.reconnect()
    }

    /// Uygulama arka plana geçti (ana ekran, başka uygulama ya da kilit tuşu). Çeviri sürüyorsa ve bildirim tercihi açıksa
    /// gecikmeli uyarı kurulur: Resim içinde resim penceresi açılmazsa iOS yerel ağ bağlantısını ve görüntü okumayı durdurur
    /// (pencere açılınca uyarı kalkar). Deneme modunda PS5 yok, uyarı da yok.
    func enteredBackground() {
        if isRunning { markBackground(true) }
        guard isRunning, !demoMode, notifiesDisconnect else { return }
        onPausedInBackground()
    }

    // MARK: - Uzun oturum tanısı

    /// Telefon uygulaması uzun oyunda (40-45 dk) kendiliğinden kapanıyordu, iz kalmıyordu: belleği yetmeyen uygulamayı
    /// iOS çökme raporu bırakmadan kapatır. Çeviri sürerken on dakikada bir bellek, ısı ve süre remoteplay.log'a ve
    /// Crashlytics izine yazılır; oturum durdurulmadan biterse bir sonraki açılışta raporlanır (Android ile aynı).
    private func startHealth() {
        guard let startedAt else { return }
        memoryWarnings = 0
        SessionHealth.saveMark(SessionHealth.Mark(startedAt: startedAt), defaults)
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(SessionHealth.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.writeHealth()
            }
        }
    }

    private func writeHealth(note: String? = nil) {
        guard let startedAt else { return }
        let line = SessionHealth.line(minutes: Int(Date().timeIntervalSince(startedAt) / 60), memoryMB: SessionHealth.footprintMB(),
                                      availableMB: SessionHealth.availableMB(), memoryWarnings: memoryWarnings,
                                      thermal: ProcessInfo.processInfo.thermalState.rawValue)
        let text = note.map { "\($0); \(line)" } ?? line
        RemotePlayLog.write("Sağlık: \(text)")
        onDiagnostic(text)
        var mark = SessionHealth.loadMark(defaults) ?? SessionHealth.Mark(startedAt: startedAt)
        mark.lastLine = text
        SessionHealth.saveMark(mark, defaults)
    }

    private func markBackground(_ background: Bool) {
        guard var mark = SessionHealth.loadMark(defaults) else { return }
        mark.background = background
        SessionHealth.saveMark(mark, defaults)
    }

    /// iOS bellek uyarısı gönderdi (UIApplication.didReceiveMemoryWarningNotification): çeviri sürüyorsa hemen yazılır.
    func receivedMemoryWarning() {
        guard isRunning else { return }
        memoryWarnings += 1
        writeHealth(note: "iOS bellek uyarısı")
    }

    /// Açılışta: önceki oturum durdurulmadan bittiyse rapor satırı (bir kez; iz silinir).
    func takeUnexpectedEnd() -> String? {
        let message = SessionHealth.unexpectedEnd(SessionHealth.loadMark(defaults))
        SessionHealth.saveMark(nil, defaults)
        if let message { RemotePlayLog.write(message) }
        return message
    }

    /// Bağlı ya da bağlanıyor; yeniden bağlanmaya gerek yok.
    private static func isLive(_ state: SessionState) -> Bool {
        if case .disconnected = state { return false }
        return true
    }

    private func startKeeper() {
        guard keeper == nil, settings.output.showsOnTV, hasTV, let tv else { return }
        let server = self.server
        keeperGeneration += 1
        let generation = keeperGeneration
        let keeper = services.makeKeeper(tv: tv, key: store.load(String.self, for: StoreKey.tvKey), params: ["server": serverAddress(for: tv), "key": server.accessKey],
                                         appConnected: { server.connectedClients > 0 }, onMoved: { [weak self] moved in
            Task { @MainActor in self?.tvMoved(to: moved) }
        }, onKey: { [weak self] key in
            Task { @MainActor in self?.store.save(key, for: StoreKey.tvKey) }
        }, consolePort: { server.consolePort }, onOpenResult: { [weak self] problem in
            Task { @MainActor in
                // Yerine yenisi kurulan (eski adresteki) bekçinin geç gelen sonucu yok sayılır.
                guard let self, self.keeper != nil, self.keeperGeneration == generation else { return }
                self.openResult(problem, brand: tv.brand)
            }
        })
        keeper.start(interval: .seconds(5))
        self.keeper = keeper
    }

    private func openResult(_ problem: TVOpenProblem?, brand: TVBrand) {
        guard isRunning, tvClients == 0 else { tvOpenProblem = nil; return }
        tvOpenProblem = TVOpenProblem.shown(problem, brand: brand, hasKey: store.load(String.self, for: StoreKey.tvKey) != nil)
    }

    /// TV bağlantısı koptu (`stale`: TV alındı göndermez oldu; uygulama askıya alınmış ya da arka planda). Çeviri sürüyor ve
    /// altyazı TV'ye gidiyorsa durum satırı "Yeniden bağlanılıyor…" der. Alındı kesildiyse TV bekçisi yenilenir: TV'ye
    /// yeniden bağlanıp uygulamayı öne getirir (LG'de geri çekilmiş bekçi de işe döner). TV sayfası kendi tarafında
    /// yeniden bağlanır.
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

    /// Ana ekrandaki "Otomatik açmayı dene": TV uygulaması hemen yeniden açılmaya çalışılır (bekçi beklemeden dener).
    func retryTVOpen() {
        tvOpenProblem = nil
        guard isRunning else { return }
        if keeper == nil { startKeeper() } else { keeper?.reconnect() }
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
        if moved.brand == .samsung { SamsungAppKnowledge.shared.carry(from: tv?.host, to: moved.host) }
        let old = tv?.host
        tv = moved
        store.save(moved, for: StoreKey.tv)
        tvNotResponding = false
        tvUnreachableHost = nil
        guard let old, old != moved.host else { return }
        // Telefondan kurulan TV uygulamasının kaydı ve LG anahtarı da yeni adrese geçer (anahtar adrese göre saklanır).
        if let installed = installedTVApp, installed.brand == moved.brand, installed.host == old {
            saveInstalledTVApp(InstalledTVApp(brand: installed.brand, host: moved.host, port: installed.port, version: installed.version))
        }
        if let update = tvAppUpdate, update.host == old {
            tvAppUpdate = TVAppUpdate(brand: update.brand, host: moved.host, port: update.port, installed: update.installed, bundled: update.bundled)
        }
        if moved.brand == .lg, LGKeys.load(moved.host) == nil, let key = LGKeys.load(old) { LGKeys.save(moved.host, key: key) }
        // Çeviri sürerken bekçi eski adresi tutar; yeni kayıtla yeniden kurulur.
        if keeper != nil {
            keeper?.stop()
            keeper = nil
            if isRunning { startKeeper() }
        }
    }

    // MARK: - TV'nin adresi değişince yeniden bulma (Mac, Windows ve Android ile aynı kural: `TVReach`)

    /// Kayıtlı TV'nin yeri: adres yanıt veriyorsa `here`; vermiyorsa TV ağda aranır (`force` değilse en çok 30 sn'de bir),
    /// aynı TV bulunursa kayıt yeni adrese taşınır (`moved`), bulunamazsa `silent`. `log`: satırın gideceği günlük.
    @discardableResult
    func relocateTV(force: Bool = false, log: @escaping (String) -> Void = { SubtitleLog.write($0) },
                    search: (() async -> [LGTV])? = nil) async -> TVReach.Location {
        guard let saved = tv, !saved.host.isEmpty else { return .here }
        guard !(await services.tvResponds(host: saved.host, brand: saved.brand)) else {
            tvNotResponding = false
            return .here
        }
        guard tv == saved else { return .here }
        tvNotResponding = true
        if !force, let last = lastTVSearch, Date().timeIntervalSince(last) < Self.tvSearchInterval { return .silent }
        lastTVSearch = Date()
        tvSearching = true
        defer { tvSearching = false }
        log("Kayıtlı TV adresi (\(saved.host)) yanıt vermiyor; TV ağda yeniden aranıyor.")
        let found = await discover(search)
        // Arama sürerken TV değiştirildiyse ya da kaldırıldıysa sonuç uygulanmaz.
        guard tv == saved else { return .here }
        if let learned = TVLocator.learned(saved, among: found) {
            log(TVIdentity.learnedLine(learned))
            tvMoved(to: learned)
            return .here
        }
        guard let (moved, how) = TVLocator.locate(saved, among: found), moved.host != saved.host else {
            log("\(TVReach.notRespondingLine): \(saved.host)")
            return .silent
        }
        log(TVIdentity.movedLine(from: saved.host, to: moved.host, how: how))
        tvMoved(to: moved)
        return .moved(moved)
    }

    /// Kurulum hedefinin adresi: kayıtlı (ya da telefondan kurulmuş) TV'nin adresiyse ve yanıt vermiyorsa TV ağda aranır,
    /// bulunursa yeni adres döner. Sessiz ve bulunamadıysa nil: kurulum "TV bu adreste yanıt vermiyor" der, "Key Server
    /// kapalı" ya da "geliştirici modu kapalı" denmez. Elle yazılan başka bir adres yoklanmadan olduğu gibi döner.
    func relocateForInstall(host: String, brand: TVBrand, search: (() async -> [LGTV])? = nil) async -> String? {
        guard !host.isEmpty else { return host }
        let log: (String) -> Void = { InstallLog.shared.write($0) }
        if let saved = tv, saved.brand == brand, saved.host == host {
            switch await relocateTV(force: true, log: log, search: search) {
            case .here: return tv?.host ?? host
            case .moved(let moved): return moved.host
            case .silent: return nil
            }
        }
        guard let installed = installedTVApp, installed.brand == brand, installed.host == host,
              !(await services.tvResponds(host: host, brand: brand)) else { return host }
        log("Kayıtlı TV adresi (\(host)) yanıt vermiyor; TV ağda yeniden aranıyor.")
        let saved = LGTV(name: tv?.brand == brand ? tv?.name ?? "" : "", host: host, brand: brand,
                         uuid: tv?.brand == brand ? tv?.uuid : nil, mac: tv?.brand == brand ? tv?.mac : nil)
        let found = await discover(search)
        guard let (moved, how) = TVLocator.locate(saved, among: found), moved.host != host else {
            log("\(TVReach.notRespondingLine): \(host)")
            return nil
        }
        log(TVIdentity.movedLine(from: host, to: moved.host, how: how))
        saveInstalledTVApp(InstalledTVApp(brand: brand, host: moved.host, port: installed.port, version: installed.version))
        if brand == .lg, LGKeys.load(moved.host) == nil, let key = LGKeys.load(host) { LGKeys.save(moved.host, key: key) }
        return moved.host
    }

    /// Ağdaki TV'ler: verilen arama (Android TV'de hata ayıklaması açık adresler) ya da LG/Samsung keşfi.
    private func discover(_ search: (() async -> [LGTV])?) async -> [LGTV] {
        if let search { return await search() }
        return await services.discoverTVs()
    }

    /// Eşli TV kartı görünürken (~10 sn'de bir): TV uygulaması bağlı değilse kayıtlı adres yoklanır, sessizse TV ağda
    /// yeniden aranır (en çok 30 sn'de bir); bulunursa kartta yeni adres görünür.
    func checkTVReachable() async {
        guard hasTV, tvClients == 0, !demoMode else {
            tvNotResponding = false
            return
        }
        if case .moved = await relocateTV() { tvUnreachableHost = nil }
    }

    /// Kartta "TV'yi Yeniden Ara": arama hemen (30 sn beklemeden) yapılır.
    func searchTVAgain() async {
        switch await relocateTV(force: true) {
        case .here, .moved: tvUnreachableHost = nil
        case .silent: tvUnreachableHost = tv?.host
        }
    }

    /// Kartta "IP Adresi Gir": yazılan adresteki TV tanınırsa (marka ve ad TV'ye sorulur, `PairedTV.identify`) kayıtlı TV o
    /// adrese taşınır. Adres geçersizse ya da orada TV tanınmazsa false.
    func useTVAddress(_ typed: String) async -> Bool {
        guard let host = ManualAddress.normalize(typed), let saved = tv else { return false }
        guard let found = await services.identifyTV(host: host) else {
            SubtitleLog.write("Elle yazılan TV adresinde (\(host)) TV tanınmadı")
            return false
        }
        SubtitleLog.write(TVReach.movedLine(from: saved.host, to: host))
        if found.brand == saved.brand {
            tvMoved(to: saved.withHost(host).identified(from: found))
        } else {
            // Başka marka TV: yeniden eşlenir (izin/jeton markaya göre).
            do { try await pair(found) } catch { return false }
            tvUnreachableHost = nil
            tvNotResponding = false
        }
        return true
    }

    /// "TV'yi Eşleştir" ve "Deneme Altyazısı Gönder"den önce: TV uygulaması bağlı değilse eşli TV'nin adresi yoklanır; adres
    /// sessizse TV ağda aranır, bulunamazsa kartta açık hata gösterilir. Önceden düğmeler hiçbir hata göstermiyordu.
    private func confirmTVReachable() async {
        guard hasTV, tvClients == 0, let host = tv?.host, !host.isEmpty else { return }
        switch await relocateTV(force: true) {
        case .here, .moved: tvUnreachableHost = nil
        case .silent: tvUnreachableHost = host
        }
    }

    /// Kartta "Eşleşmeyi Kaldır" (onaydan sonra): kayıtlı TV, TV izni/jetonu ve telefondan kurulan TV uygulamasının kaydı
    /// silinir, bekçi durur. Altyazı yalnız TV'ye gidiyorsa bu telefona döner.
    func removeTVPairing() {
        SubtitleLog.write("Eşli TV kaldırıldı: \(tv.map { "\($0.brand.rawValue) \($0.host)" } ?? "yok")")
        keeper?.stop()
        keeper = nil
        if let host = tv?.host, tv?.brand == .lg { LGKeys.remove(host) }
        store.remove(StoreKey.tv)
        store.remove(StoreKey.tvKey)
        defaults.removeObject(forKey: StoreKey.tvAppInstalled)
        tv = nil
        tvKeySaved = false
        tvAppMissing = false
        installedTVApp = nil
        tvAppUpdate = nil
        tvNotResponding = false
        tvUnreachableHost = nil
        tvOpenProblem = nil
        testTVNotConnected = false
        if settings.output == .tv || settings.output == .both { settings.output = .computer }
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

    private func consoleMoved(_ moved: RegisteredConsole) {
        guard console != nil else { return }
        console = moved
        store.save(moved, for: StoreKey.console)
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
        guard connected, !isXbox, console != nil else {
            gameProbe?.cancel()
            gameProbe = nil
            gameChoice.consoleReported(nil)
            return
        }
        guard gameProbe == nil else { return }
        let services = self.services
        gameProbe = Task { [weak self] in
            while !Task.isCancelled {
                // Her yoklamada güncel kayıt kullanılır (oturum PS5'i yeni adreste bulmuş olabilir).
                guard let finder = self?.consoleFinder() else { break }
                let game = await services.runningGame(finder: finder)
                // Bu arada bağlantı bittiyse oyun yazılmaz (bırakılan oyun geri gelmesin).
                guard !Task.isCancelled else { break }
                // Yeni oyunda paket sunucusuna bakılması `gameChoice.onChange`te (Android'deki gibi).
                self?.gameChoice.consoleReported(game)
                try? await Task.sleep(for: Self.gameProbeInterval)
            }
        }
    }

    private func sessionStateChanged(_ state: SessionState) {
        let wasStreaming = sessionState == .streaming
        // Altyazı günlüğünde durumun türü ve kopmanın nedeni (Mac ile aynı satırlar).
        if state != sessionState {
            switch state {
            case .connecting: SubtitleLog.write("\(isXbox ? "Xbox" : "PS5"): bağlanıyor")
            case .streaming: SubtitleLog.write("\(isXbox ? "Xbox" : "PS5"): bağlandı")
            case .disconnected(let reason): SubtitleLog.write("\(isXbox ? "Xbox" : "PS5"): bağlantı yok (\(reason.logName))")
            }
        }
        // PS5'in kendi tarafındaki çökme altyazı günlüğüne de yazılır: kullanıcının günlüğünde nedeni görünsün (GitHub #519).
        if state == .disconnected(.consoleRemotePlayCrashed), state != sessionState {
            SubtitleLog.write("PS5: Uzaktan Oynatma PS5'te çöktü (Remote Play on Console has crashed); PS5 tamamen kapatılıp açılmalı")
        }
        sessionState = state
        reconnectOffer.update(live: state == .streaming)
        subtitleOffTip.connectionChanged(streaming: state == .streaming)
        updateSubtitleOffTip()
        // Akış sürerken kendiliğinden koptu (kullanıcı durdurmadı): tercih açıksa bildirim (uygulama etkin değilse).
        if wasStreaming, isRunning, case .disconnected(let reason) = state, reason != .stopped, notifiesDisconnect {
            onConnectionLost()
        }
        updateGameProbe(connected: state == .streaming)
        if case .disconnected = state {
            pipeline?.reset()
            regionWatcher?.reset()
            gamePhoneTracker?.reset()
            screenTextDetector?.reset()
            server.clear()
        }
    }

    private func makePipeline() {
        pipeline?.reset()
        // Eski hatta süren okuma beklenmez; yeni hat ilk karesini hemen alır.
        frameGate.reset()
        skippedFrame = nil
        let scheduler = ReadScheduler(maxReuse: settings.fastSubtitleDetection
            ? ReadScheduler.fastMaxReuse : ReadScheduler.defaultMaxReuse)
        // Ekranda menü varken altyazı bekletilir; menü kapanınca bekletilen konuşma satırı gönderilir (#1240).
        let sender = MenuHeldSender(server, inMenu: { [weak self] in self?.screenTextDetector?.inMenu == true })
        menuSender = sender
        let pipeline = SubtitlePipeline(reader: VisionReader(language: settings.sourceLanguage), translator: makeTranslator(),
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
        wireSpeech(pipeline)
        pipeline.onPair = { [weak self, weak pipeline] source, translation in
            self?.lastSource = source
            self?.lastTranslation = translation
            let fromPack = pipeline?.lastOrigin == "paket"
            if fromPack, let title = self?.packs.scopeTitle { self?.packInUse = title }
            if let self { self.gameChoice.noteLine(fromPack: fromPack, packs: self.packs) }
            self?.addToHistory(source: source, translation: translation, origin: fromPack ? .pack : .engine)
            self?.noteLine(source: source, translation: translation, fromPack: fromPack)
        }
        pipeline.onMetrics = { [weak self] metrics in self?.lastMetrics = metrics }
        // Altyazı hattının olayları (ilk kare, okunan satırlar ve akıbetleri, sahne yazısı, kalkan satır) Mac'teki gibi
        // altyazi.log'a yazılır. Eskiden iPhone'da bağlı değildi: paylaşılan günlükte yalnız ek alan satırları vardı,
        // altyazının neden çevrilmediği görülemiyordu (1.0.6, 2026-11-22).
        pipeline.onLog = { SubtitleLog.write($0) }
        pipeline.onSceneTextDropped = { [weak self] reason in
            guard let self, self.gamePhoneHint.observe(reason: reason, readsPhone: self.settings.readsGamePhone,
                                                       game: self.gameChoice.game?.name) else { return }
            SubtitleLog.write("telefon ipucu: telefon çevirisi kapalı, telefon listesi altyazı yolunda atıldı (\(reason))")
            self.showsGamePhoneHint = true
        }
        // Telefon çevirisi kapalıyken de altyazı hattı GTA 6'da telefonu arar (yalnız bulmak için; okumaz, çevirmez): ekranındaki
        // satırlar altyazı sayılmaz, telefon art arda bulunursa oturumda bir kez ipucu (#1282; Mac, Windows, Android ile aynı).
        pipeline.onPhoneLooked = { [weak self] found in
            guard let self, self.gamePhoneHint.observePhone(found: found, readsPhone: self.settings.readsGamePhone,
                                                            game: self.gameChoice.game?.name) else { return }
            SubtitleLog.write("telefon ipucu: telefon çevirisi kapalı, GTA 6 telefonu ekranda bulundu")
            self.showsGamePhoneHint = true
        }
        pipeline.onReadResult = { [weak self] error in
            // Takılıyken her kare beklemeden `stuck` alır; takılma uzarsa (`ReadQueue.defaultAbandonStallAfterMs`) okuma
            // kendiliğinden bırakılır, altyazı yeni kuyrukta sürer (Mac ile aynı).
            let stuck = ReadQueue.shared.stalledMs != nil
            if self?.readingStuck != stuck { self?.readingStuck = stuck }
        }
        ReadQueue.shared.onEvent = { [weak self] event in
            switch event {
            case .stalled(let stall, _): SubtitleLog.write("okuma takıldı: \(stall.logText); takılan okuma bekleniyor")
            case .recovered(let ms): SubtitleLog.write("okuma düzeldi: takılan okuma \(ms) ms sonra bitti")
            case .rescueFailed: break
            case .abandonedFinished(let still):
                SubtitleLog.write("bırakılan takılı okuma sonunda bitti (bitmeyen bırakılmış okuma: \(still))")
            case .abandoned(let ms, _, let cancelled):
                SubtitleLog.write("takılan okuma bırakıldı, okuyucu yeniden kuruldu: okuma \(ms) ms'dir dönmüyordu\(cancelled ? " (istek iptal edildi)" : ""); okuma yeni okuyucuda hızlı düzeyde sürüyor")
            case .recoveredAfterRebuild(let reads):
                SubtitleLog.write("okuma düzeldi (yeniden kurulumdan sonra): yeni okuyucu art arda \(reads) okumayı süresinde bitirdi")
            case .parked(let still, _):
                SubtitleLog.write("yeni okuyucu da tek okuma bitiremeden takıldı: yazı tanıma kilidi bırakılan okumada (bitmeyen: \(still)); yeniden kurma durdu, kilit serbest kalınca okuma sürecek")
            case .degraded(let stalls):
                SubtitleLog.write("okuma \(stalls) kez takıldı; \(ReadQueue.shared.fastLevelHoldMs / 1000) sn hızlı düzeyde okunacak (Neural Engine yolu bırakıldı), sonra isabetli düzey yeniden denenecek")
            case .restored(let ms):
                SubtitleLog.write("hızlı düzeyin süresi doldu (\(ms / 1000) sn); okuma yeniden isabetli düzeyde")
            case .backgroundYielded(let stall, let dropped, _):
                SubtitleLog.write("altyazı arka plan okumasını bekledi (takılma sayılmadı): \(stall.logText); sıradaki \(dropped) arka plan okuması düşürüldü")
            }
            Task { @MainActor in
                let stuck = ReadQueue.shared.stalledMs != nil
                if self?.readingStuck != stuck { self?.readingStuck = stuck }
            }
        }
        // Çevrimiçi motor açıkken yerel yedeğin bu iPhone'da olmaması (iOS 26 öncesi) gösterilmez; motorun gerçek hatası
        // (anahtar, kota, ağ) `onlineIssue` ile ana ekranda söylenir (GitHub #1322, Mac ile aynı).
        pipeline.onTranslationResult = { [weak self] error in
            guard let self else { return }
            self.translatorStatus = TranslatorStatus.after(error, onlineActive: self.onlineTranslationActive)
        }
        // Ek alan okuyucusu yeni dil ve motorla, ilk ek alan karesinde yeniden kurulur.
        regionWatcher?.reset()
        regionWatcher = nil
        screenTextDetector?.reset()
        connectPacks(to: pipeline)
        onlineIssue = nil
        pipeline.warmUp()
        self.pipeline = pipeline
        configureGamePhone()
    }

    /// iPhone'da bağımsız yedek okuyucu yok: takılan okuma bırakılır, sonraki okumalar yeni kuyrukta hızlı düzeyde verilir
    /// (Android'de takılan tanıyıcı da bırakılıp yenisi kuruluyor).
    private func abandonStalledRead(olderThanMs: Int) {
        // Günlük satırı `ReadQueue.Event.abandoned` ile yazılır.
        guard ReadQueue.shared.abandonStall(olderThanMs: olderThanMs) != nil else { return }
        if readingStuck { readingStuck = false }
    }

    /// Telefon ipucundaki "Aç": "GTA 6 Telefonunu Çevir" açılır.
    func enableGamePhone() {
        settings.translatesGamePhone = true
        showsGamePhoneHint = false
    }

    func dismissGamePhoneHint() { showsGamePhoneHint = false }

    /// Oyun telefonu yalnız ayar açıkken ve oynanan oyun GTA 6 iken izlenir (Mac'teki `configureGamePhone` ile aynı).
    private func configureGamePhone() {
        regionWatcher?.closePhone()
        // Telefon GTA 6'da her zaman izlenir (telefon çevirisi kapalıyken de): açık telefonun ekranına otomatik ekran yazısı
        // kutusu ve kenar bildirimi çizilmez (Sinan Bey, beta.100 3420–3425). Telefonun okunması ayara bağlıdır.
        gamePhoneTracker = Self.tracksGamePhone(running: pipeline != nil, enabled: true,
                                                game: gameChoice.game?.name) ? GamePhoneTracker() : nil
        // Altyazı hattı telefonu yalnız GTA 6'da arar: başka oyunda ya da karanlık sahnede yanlış bulunan telefon alt şeritteki
        // altyazıyı silmesin. Telefon ayarı kapalıyken de arar (#1282): telefonun mesaj listesi altyazı olarak çevrilip
        // gidip geliyordu; bulunan telefonun satırları altyazı sayılmaz, ipucu gösterilir (Mac, Windows, Android ile aynı).
        pipeline?.findsPhone = Self.tracksGamePhone(running: pipeline != nil, enabled: true, game: gameChoice.game?.name)
    }

    static func tracksGamePhone(running: Bool, enabled: Bool, game: String?) -> Bool {
        guard running, enabled, let game else { return false }
        return GameName.key(game) == "gta 6"
    }

    /// Ek alanlar aynı dil, motor ve paketlerle okunur; ayrı bir okuyucu ve çevirmenle (altyazının sırasını beklemez).
    private func makeRegionWatcher(packLookup: ((String) -> PackMatch?)?) -> RegionWatcher {
        let watcher = RegionWatcher(reader: VisionReader(language: settings.sourceLanguage), translator: makeTranslator(), server: server)
        watcher.packLookup = packLookup
        watcher.subtitleEcho = .shared
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
        watcher.onLog = { SubtitleLog.write($0) }
        // Okunup yazısız ya da gürültülü çıkan otomatik alan dedektöre bildirilir (o görüntüde yeniden önerilmez).
        watcher.onAutoRejected = { [weak self] id in self?.screenTextDetector?.reject(id) }
        // Menüde okunan tuş ipucu ya da görev/HUD yazısı menü bileşeni sayılmaz (#1240).
        watcher.onAutoHud = { [weak self] id in self?.screenTextDetector?.markHud(id) }
        return watcher
    }

    /// Kendiliğinden bulunan ekran yazıları (ayar açıkken, Tam ekran dışında; Mac ile aynı). Karo örneği arka planda
    /// tek uçuşta alınır; altyazı alanı ve okunan ek alanlar dışlanır.
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

    /// Kare geldi, satır gösterildi ya da bağlantı değişti: ipucu yeniden değerlendirilir (deneme modunda görünmez).
    private func updateSubtitleOffTip() {
        let visible = isRunning && !demoMode && subtitleOffTip.visible(now: Date(), streaming: sessionState == .streaming)
        if visible != showsSubtitleOffTip { showsSubtitleOffTip = visible }
    }

    /// Kare ana iş parçacığında kısa iş görür (önizleme, ek alanlar) ve hemen döner; altyazı okuması kapıdan geçerse kendi
    /// işinde beklenir. Eskiden kare işi okumayı bekliyordu; sonraki kareler de ayrı işlerde birikiyordu.
    private func handle(_ frame: CGImage, capturedAt: Int) {
        framePreview.image = frame
        // Çevirisi gösterilen ekran yazıları hâlâ yerinde mi: özgün yazı kalkınca çevirisi de bu karede kalkar
        // (`ScreenPresence`; Mac/Windows/Android aynı).
        server.observe(frame)
        subtitleOffTip.frameArrived(at: Date(), streaming: sessionState == .streaming)
        updateSubtitleOffTip()
        guard let current = pipeline else { return }
        // Ek alanlar altyazıyla aynı OCR kuyruğunu kullanır; saniyede bir tur yeterlidir.
        // Kullanıcının ek alanı yoksa bilinen oyunun hazır alanları (GameAreaPresets; ör. GTA 6 yardım kutusu ve mesajlar).
        // Oyun telefonu açıkken ekranı ayrıca okunur; hazır alanlardaki telefon mesajı ve otomatik ekran yazısı o sırada okunmaz.
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
        if regionWatcher == nil, !areas.isEmpty || pose != nil { regionWatcher = makeRegionWatcher(packLookup: current.packLookup) }
        regionWatcher?.offer(frame, areas: areas, phone: pose)
        // Ekranda menü açık (otomatik ekran yazısı menü durumunda): altyazı okunur ama gönderilmez, bekletilir; menü
        // kapanınca bekletilen konuşma satırı gönderilir (MenuHeldSender, #1240). Eskiden menüde altyazı hiç okunmuyordu;
        // menü sanılan anlarda konuşma satırları kayboluyordu.
        if menuSender?.poll() == true { current.skipForMenu() }
        // Önceki kare hâlâ işleniyorsa bu kare atlanır. Tek okuma bitmezse çeviri tamamen duruyor, "Durdur / Başlat"
        // düzeltmiyordu (Mac'te görüldü, 2026-11-13); takılan okuma hattı yeniden kurdurur.
        var entry = frameGate.enter(now: SubtitleStabilizer.uptimeMs())
        if case .stuck(let ms) = entry {
            SubtitleLog.write("okuma \(ms) ms'dir bitmedi; okuma hattı yeniden kuruldu")
            makePipeline()
            entry = frameGate.enter(now: SubtitleStabilizer.uptimeMs())
        }
        guard case .enter(let token) = entry, let pipeline else {
            if case .busy = entry { skippedFrame = (frame, capturedAt) }
            return
        }
        skippedFrame = nil
        Task { [weak self] in
            var token = token
            var next = (frame: frame, capturedAt: capturedAt)
            while let model = self {
                await pipeline.process(next.frame, region: model.settings.region, capturedAt: next.capturedAt)
                // Okuma sürerken atlanan son kare hemen okunur: altyazı belirirken gelen son kare atlanıp ardından kare
                // gelmezse yeni satır okunmuyordu (GitHub #1019; Mac ve Windows ile aynı).
                guard model.frameGate.leave(token), let skipped = model.skippedFrame else { return }
                model.skippedFrame = nil
                guard model.pipeline === pipeline,
                      case .enter(let again) = model.frameGate.enter(now: SubtitleStabilizer.uptimeMs()) else { return }
                token = again
                next = skipped
            }
        }
    }

    // MARK: - Geçmiş

    /// Açılışta kayıtlı geçmiş okunur (uygulama çağırır; testlerde çağrılmaz, dosyaya yazılmaz).
    func loadHistory(from file: URL = SubtitleHistory.defaultFile) {
        historyFile = file
        history = SubtitleHistory.load(from: file)
    }

    private func addToHistory(source: String, translation: String, origin: LineMetrics.Origin) {
        history.add(source: source, translation: translation, origin: origin)
        saveHistory()
    }

    /// "Geçmiş"teki "Temizle".
    func clearHistory() {
        history.clear()
        saveHistory()
    }

    private func saveHistory() {
        guard let historyFile else { return }
        let history = self.history
        historyQueue.async { try? history.save(to: historyFile) }
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
        subtitleOffTip.lineShown()
        updateSubtitleOffTip()
    }

    /// Okuma hattı oyun paketlerine bakıyor mu: ayar açık ve İngilizce→Türkçe (paketler herkese ücretsiz).
    var packsActive: Bool {
        settings.gamePacks && settings.sourceLanguage == "en" && settings.targetLanguage == "tr"
    }

    /// Paketler ekranında karoya dokunma: oyunun asıl paketi ve "(ek satırlar)" paketi birlikte açılır ya da kapanır
    /// (okuma hattı hemen yeni listeyle eşleşir).
    func setPacks(_ ids: [String], on: Bool) {
        if on { disabledPacks.subtract(ids) } else { disabledPacks.formUnion(ids) }
        defaults.set(disabledPacks.sorted(), forKey: Self.disabledPacksKey)
        if let pipeline { connectPacks(to: pipeline) }
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
        // Deneme satırları paketlerde aranmaz ve havuza önerilmez.
        let active = packsActive && !demoMode
        let disabled = disabledPacks
        if demoMode {
            pipeline.packLookup = nil
            pipeline.onPackMiss = nil
            regionWatcher?.packLookup = nil
            return
        }
        // Kapatılan paket: paketler tek sözlükte birleştiği için eşleşmeyi veren paket, bulanık aramanın kapsamından
        // (son tam eşleşmenin paketi) okunur; o paket kapalıysa satır motorla çevrilir.
        pipeline.packLookup = !active ? nil : disabled.isEmpty ? { packs.match($0) } : { text in
            guard let found = packs.match(text) else { return nil }
            return packs.searchScope.map(disabled.contains) == true ? nil : found
        }
        // Ek alanlar da pakette aranır ama havuza önerilmez (arayüz yazıları havuzu kirletmesin).
        regionWatcher?.packLookup = pipeline.packLookup
        guard settings.sourceLanguage == "en" else {
            pipeline.onPackMiss = nil
            return
        }
        pipeline.onPackMiss = { text in
            // Kapalı paketteki satır da havuza önerilmez (zaten çevrili).
            guard (active && disabled.isEmpty) || packs.match(text) == nil else { return }
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

    /// Deneme modunda seçili motor çeviremezse (dil paketi yok, ağ ya da anahtar yok) örnek satırların hazır çevirisi.
    private func makeTranslator() -> TextTranslator {
        let translator = makeEngineTranslator()
        return demoMode ? DemoTranslator(base: translator) : translator
    }

    private func makeEngineTranslator() -> TextTranslator {
        let (source, target) = (settings.sourceLanguage, settings.targetLanguage)
        let local = Translator(source: source, target: target,
                               cache: Self.translationCache(engine: Translator.engineID, source: source, target: target))
        let engine = settings.onlineEngine
        guard onlineTranslationActive, let storeKey = engine.storeKey else { return local }
        let online: TextTranslator & OnlineTranslating
        if engine == .local, let server = settings.localAIServer {
            // Yerel model (aynı ağdaki bilgisayarda Ollama, LM Studio): anahtar isteğe bağlıdır; önbellekte sunucu ve
            // model ayrı tutulur (Mac ile aynı).
            let sense = gameChoice.sense
            online = AITranslator(provider: .local, key: store.load(String.self, for: storeKey) ?? "", model: server.model,
                                  server: server, fallback: local,
                                  cache: Self.translationCache(engine: server.engineID, source: source, target: target),
                                  game: { sense.current?.name }, instruction: settings.aiInstruction)
        } else if let key = store.load(String.self, for: storeKey), let provider = engine.aiProvider {
            let model = provider.model(settings.model(for: provider)).id
            // Oynanan oyunun adı modele bağlam olarak gider; önbellek de oyuna göre ayrılır (Mac ile aynı). Ad kararlı
            // oyundur (`GameSense.current`), son eşleşen paket değil: tek bir ortak satır adı başka oyuna geçirmez (#27).
            let sense = gameChoice.sense
            online = AITranslator(provider: provider, key: key, model: model, fallback: local,
                                  cache: Self.translationCache(engine: provider.engineID(model: model), source: source, target: target),
                                  game: { sense.current?.name }, instruction: settings.aiInstruction,
                                  paidTier: provider == .gemini && settings.geminiPaidTier)
        } else if let key = store.load(String.self, for: storeKey) {
            online = DeepLTranslator(key: key, fallback: local,
                                     cache: Self.translationCache(engine: DeepLTranslator.engineID, source: source, target: target))
        } else {
            return local
        }
        online.onFailureChanged = { [weak self] state in
            if let state { SubtitleLog.write("çevrimiçi motor çeviremedi: \(engine.rawValue) \(state); yedek: \(Translator.isAvailable ? "ücretsiz çeviri" : "yok (iOS 26 öncesi), yalnız oyun paketleri")") }
            Task { @MainActor in self?.onlineIssue = state }
        }
        return online
    }

    private static func translationCache(engine: String, source: String, target: String) -> TranslationCache {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true).appendingPathComponent("Translations", isDirectory: true)
        return TranslationCache.shared(in: directory, engine: engine, source: source, target: target)
    }

    // MARK: - Çevrimiçi çeviri anahtarları (Anahtarlık)

    var onlineTranslationActive: Bool {
        settings.onlineTranslation && settings.sourceLanguage == "en" && settings.targetLanguage == "tr" && isReady(settings.onlineEngine)
    }

    /// Motor kullanılabilir mi: bulut motorlarında anahtar kayıtlıdır; yerel modelde anahtar gerekmez, adres ve model adı
    /// geçerli olmalıdır (Mac ile aynı). Sunucuya ulaşılamazsa satırlar ücretsiz çeviriyle gelir, ana ekranda uyarı çıkar.
    func isReady(_ engine: TranslationEngine) -> Bool {
        engine == .local ? settings.localAIServer != nil : hasKey(engine)
    }

    /// Ayarlardaki "Bağlantıyı dene": yerel model sunucusuna örnek satırı gönderir. `key` yazıldıysa o, yoksa kayıtlı
    /// anahtar kullanılır; yazılan anahtar sunucu kabul ettiyse Anahtarlık'a yazılır (Mac `testLocalAI` ile aynı).
    func testLocalAI(key typed: String = "") async -> Result<String, AIFailure> {
        guard let server = settings.localAIServer else { return .failure(.unreachable) }
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? store.load(String.self, for: StoreKey.localAIKey) ?? "" : typed
        SubtitleLog.write("Yerel model testi başladı: \(server.address) \(server.model)")
        let result = await services.testLocalAI(server: server, key: key)
        if case .failure(let error) = result { SubtitleLog.write("Yerel model testi sonucu: \(error)") }
        if !typed.isEmpty {
            switch result {
            case .success, .failure(.quotaExceeded), .failure(.modelRejected), .failure(.busy):
                store.save(typed, for: StoreKey.localAIKey)
                guard store.load(String.self, for: StoreKey.localAIKey) == typed else { return .failure(.keychainWriteFailed) }
                savedKeys.insert(.local)
            case .failure: break
            }
        }
        if case .success = result {
            settings.translationEngine = .local
            if isRunning { makePipeline() }
            await refreshTranslatorStatus()
        }
        return result
    }

    func hasKey(_ engine: TranslationEngine) -> Bool { savedKeys.contains(engine) }

    /// PS5 giriş şifresi: yalnız 4 hane Anahtarlık'a kaydedilir; geçersizse false. Sonraki bağlantıda kullanılır.
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

    /// Anahtar kaydının sonucu: hizmet kabul etmediyse `rejected`, Anahtarlık'a yazılamadıysa (geri okunamadı) `notStored`.
    enum KeySaveResult: Equatable { case saved, rejected, notStored }

    /// Son DeepL anahtar denemesinin sonucu: reddedilince Ayarlar nedenini (geçersiz karakter, 5xx, ağ yok…) gösterir.
    private(set) var lastDeepLCheck: OnlineKeyCheck?

    /// Anahtar denenir; kabul edildiyse Anahtarlık'a yazılır ve motor seçilir. Anahtarlık'tan geri okunamazsa kayıt
    /// başarılı sayılmaz (Mac'teki `saveKey` ile aynı kural).
    func saveKey(_ key: String, for engine: TranslationEngine) async -> KeySaveResult {
        // DeepL anahtarındaki görünmez karakterler (araya giren boşluk, bölünmez boşluk, satır sonu…) her yerden silinir.
        let key = engine == .deepL ? DeepLKey.clean(key) : key.trimmingCharacters(in: .whitespacesAndNewlines)
        lastDeepLCheck = nil
        guard !key.isEmpty, let storeKey = engine.storeKey else { return .rejected }
        let accepted: Bool
        SubtitleLog.write("API anahtarı testi başladı: \(engine.rawValue)")
        if let provider = engine.aiProvider {
            let result = await services.testAIKey(provider: provider, key: key, model: settings.model(for: provider))
            if case .failure(let error) = result { SubtitleLog.write("API anahtarı testi sonucu: \(provider.rawValue) \(error)") }
            switch result {
            case .success, .failure(.quotaExceeded), .failure(.modelRejected), .failure(.busy): accepted = true
            case .failure: accepted = false
            }
        } else {
            // 429 (çok sık istek) anahtarı reddetmez: Mac, Windows ve Android'deki gibi kaydedilir.
            let check = await services.checkDeepLKey(key)
            lastDeepLCheck = check
            if check.state != .valid { SubtitleLog.write("API anahtarı testi sonucu: \(engine.rawValue) \(check.logDescription)") }
            accepted = check.state == .valid || check.state == .quotaExceeded || check.state == .busy
        }
        guard accepted else { return .rejected }
        store.save(key, for: storeKey)
        guard store.load(String.self, for: storeKey) == key else {
            SubtitleLog.write("API anahtarı Anahtarlık'a kaydedilemedi: \(engine.rawValue)")
            return .notStored
        }
        savedKeys.insert(engine)
        if settings.translationEngine == engine {
            if isRunning { makePipeline() }
            await refreshTranslatorStatus()
        } else {
            settings.translationEngine = engine
        }
        return .saved
    }

    /// Kayıtlı DeepL anahtarının bu ayki kullanımı (Mac'teki `deepLUsage` ile aynı sorgu; karakter kotasından yemez).
    /// Anahtar yoksa nil.
    func deepLUsage() async -> OnlineKeyCheck? {
        guard let storeKey = TranslationEngine.deepL.storeKey, let key = store.load(String.self, for: storeKey), !key.isEmpty else { return nil }
        return await services.checkDeepLKey(key)
    }

    func removeKey(_ engine: TranslationEngine) {
        guard let storeKey = engine.storeKey else { return }
        store.remove(storeKey)
        savedKeys.remove(engine)
        // Yerel modelin anahtarı isteğe bağlıdır: anahtarsız çeviri sürer, hat anahtarsız yeniden kurulur.
        if engine == .local {
            if settings.translationEngine == .local, isRunning { makePipeline() }
            return
        }
        if settings.translationEngine == engine { settings.onlineTranslation = false }
    }

    // MARK: - Telefon ekranındaki altyazı

    /// Sunucunun TV'ye gönderdiği olayların aynısı telefon ekranına da gelir (TV kurulu olmasa da).
    func phoneReceive(_ event: SubtitleEvent) {
        // Deneme modunda altyazı TV seçili olsa da bu ekranda görünür (TV'si olmayan da görsün). "Arka planda sürdür"
        // açıkken satırlar Resim içinde resim penceresine de gider (TV seçiliyken de).
        guard settings.output.showsOnComputer || demoMode || backgroundPiP else { return }
        let now = clock()
        switch event {
        case .subtitle(let text, let durationMs, let paragraphs, let replaces, _):
            // Aynı cümlenin uzamış ya da düzelmiş okuması öncekinin yerine geçer (Mac'teki pencere ve TV gibi).
            stack.stackPrevious = settings.style.stackPrevious
            stack.show(text, durationMs: durationMs, paragraphs: paragraphs, replaces: replaces, now: now)
        case .clear:
            stack.clear(now: now)
        // "Ekranı çevir" sonuçları yazının yerinde gösterilir (`screenItems`); satır yığınına girmez.
        case .screen, .screenClear:
            return
        // Oyun telefonunun çevirisi telefon ekranında da her mesaj kendi balonunun yerinde ve renginde (TV ve Android gibi;
        // boş liste kaldırır).
        case .gamePhone(let items):
            phoneRegions = Self.phoneRegions(phoneRegions, gamePhone: items)
            return
        // Ek alanın çevirisi telefon ekranında da kendi yerinde küçük kutuda görünür (boş metin kutuyu kaldırır).
        case .region(let id, let text, let box):
            var regions = phoneRegions.filter { $0.id != id }
            if !text.isEmpty { regions.append(PhoneRegion(id: id, text: text, box: box)) }
            if regions != phoneRegions { phoneRegions = regions }
            return
        // Kendiliğinden bulunan ekran yazısı telefonda da blok blok kendi yerinde ve özgün stilinde (TV ve Android gibi).
        case .screenText(let id, let items):
            let boxes = items.map(\.box)
            let box = boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }
            var regions = phoneRegions.filter { $0.id != id }
            regions.append(PhoneRegion(id: id, text: items.map(\.translation).joined(separator: "\n"), box: box, items: items))
            if regions != phoneRegions { phoneRegions = regions }
            return
        case .regionClear:
            if !phoneRegions.isEmpty { phoneRegions = [] }
            return
        }
        phoneRefresh()
    }

    /// Oyun telefonunun alanı (`game-phone`) eklenmiş ya da kaldırılmış ek alanlar; mesajlar blok blok tutulur (her biri
    /// kendi balonunun yerinde çizilir, `placedItems`).
    static func phoneRegions(_ regions: [PhoneRegion], gamePhone items: [ScreenTranslation.Item]) -> [PhoneRegion] {
        var regions = regions.filter { $0.id != gamePhoneRegionId }
        let boxes = items.map(\.box)
        if let first = boxes.first {
            regions.append(PhoneRegion(id: gamePhoneRegionId, text: items.map(\.translation).joined(separator: "\n"),
                                       box: boxes.dropFirst().reduce(first) { $0.union($1) }, items: items))
        }
        return regions
    }

    /// Telefon ekranında kendi yerinde çizilecek bloklar: bloklu ek alanlarınki ("Ekranı çevir" sonuçlarının örttüğü
    /// bloklar hariç, #827) ve "Ekranı çevir" sonuçları en üstte. Android `PhoneSubtitleActivity` ile aynı kural.
    static func placedItems(_ regions: [PhoneRegion], screen: [ScreenTranslation.Item]) -> [ScreenTranslation.Item] {
        let blocks = regions.flatMap { $0.items ?? [] }
        return (screen.isEmpty ? blocks : ScreenTranslation.uncovered(blocks, by: screen)) + screen
    }

    static let gamePhoneRegionId = "game-phone"

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
        if !phoneRegions.isEmpty { phoneRegions = [] }
        hideScreen()
    }

    // MARK: - Ekranı çevir

    /// "Ekranı çevir": PS5'in şu anki karesinin tamamı bir kez okunur, yazı grupları (menü, görev paneli, bilgi kutusu...)
    /// tek istekte çevrilir; sonuçlar telefonda ve TV'de yazının kendi yerinde, özgün stilinde görünür (GTA 6 telefonu
    /// yanında mesaj kartında). Çeviri sürerken ya da sonuçlar ekrandayken dokunmak ("Remove screen translations") çeviriyi
    /// hemen kapatır: kare yeniden okunmaz, önbellekten yeniden çizilmez (Android ile aynı). Önceden sonuçlar ekrandayken
    /// dokununca kare yine okunuyor, oyunda yazılar biraz değişince ekran baştan çevriliyordu (#1182).
    /// Karede GTA 6 telefonu varsa kart ekrandayken telefon izlenir (`followPhone`): sohbet değişince kart kendiliğinden
    /// yenilenir, telefon kapanınca kalkar. `refresh`: bu izlemenin yenilemesi (dokunulmadı).
    func translateScreen(refresh: Bool = false) {
        guard isRunning else { return }
        if (!refresh && screenState != .idle) || (refresh && screenTask != nil) {
            if !refresh { hideScreen() }
            return
        }
        guard let frame = framePreview.image else {
            if !refresh { server.sendSubtitle(String(localized: "Couldn't capture the screen: no picture from the PS5 yet."), durationMs: 4000) }
            return
        }
        if !refresh {
            // Yeniden okunurken önceki sonuçların süresi dolup yeni çeviriyi iptal etmesin.
            screenExpiry?.cancel()
            screenExpiry = nil
            screenState = .working
        }
        server.sendStyle(settings.style)
        if !refresh { server.sendSubtitle(String(localized: "Translating the screen…"), durationMs: 2500) }
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
                let items = try await ScreenTranslation.translate(reading, using: translator, frame: frame, memory: memory,
                                                                  phoneCard: phoneCard, panelScale: panelScale) { shown in
                    // İzlemenin yenilemesinde aynı çeviriler yeniden gönderilmez (TV'de kart yeniden çizilmesin).
                    guard !Task.isCancelled, !(refresh && self?.screenShown == shown) else { return }
                    let milliseconds = ScreenTranslation.displayMilliseconds(shown)
                    server.sendScreen(shown, durationMs: milliseconds)
                    self?.showScreen(shown, milliseconds: milliseconds)
                }
                guard !Task.isCancelled else { return }
                if !refresh { server.clear() }
                if items.isEmpty {
                    if refresh { self?.hideScreen() }
                    self?.screenState = .idle
                    if !refresh { server.sendSubtitle(String(localized: "No text found on the screen."), durationMs: 2500) }
                } else {
                    self?.followPhone(in: frame)
                }
            } catch is CancellationError {
                return
            } catch {
                // İzlemenin yenilemesi başarısızsa eski kart kalır; aynı görüntü yeniden denenmez.
                if refresh { self?.followPhone(in: frame) } else { self?.showScreenFailure(error, translator: translator) }
            }
            self?.screenTask = nil
        }
    }

    /// Ekran bu kareyle çevrildi: karede telefon varsa kart ekrandayken telefon izlenir (`ScreenPhoneFollow`). Sohbet
    /// değişip durulunca ekran yeniden çevrilir (hafızadaki mesajlar hemen gelir), telefon aynıyken kartın süresi uzar,
    /// telefon kapanınca kart kalkar (Mac ile aynı).
    private func followPhone(in frame: CGImage) {
        // Çeviriler balonların üstündeyken (kartsız) sohbet kayınca/değişince hemen kalkar (`ScreenPhoneFollow.hide`).
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
                // İzleme bitince (kart kalktı) sonraki kart yeni bir izlemeyle başlar.
                defer { if let self, self.screenFollow === follow { self.stopFollowing() } }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(ScreenPhoneFollow.interval))
                    guard let self, !Task.isCancelled, self.screenFollow === follow, self.isRunning,
                          self.screenState != .idle else { return }
                    guard self.screenTask == nil, let current = self.framePreview.image else { continue }
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
    /// çeviriler kalır; ekran durulunca yeniden çevrilir (Mac ile aynı).
    private func hidePhoneBubbles() {
        let kept = screenShown.filter { !$0.bubble }
        guard kept.count != screenShown.count else { return }
        if kept.isEmpty {
            screenShown = []
            screenItems = []
            server.clearScreen()
            return
        }
        let milliseconds = ScreenTranslation.displayMilliseconds(kept)
        server.sendScreen(kept, durationMs: milliseconds)
        showScreen(kept, milliseconds: milliseconds)
    }

    /// Telefon kartı izlenirken telefon aynı: sonuçlar yeniden gönderilip süresi uzatılır (süresi dolmak üzereyse).
    private func keepScreen() {
        guard !screenShown.isEmpty, screenShownUntil.timeIntervalSinceNow < 5 else { return }
        let milliseconds = ScreenTranslation.displayMilliseconds(screenShown)
        server.sendScreen(screenShown, durationMs: milliseconds)
        showScreen(screenShown, milliseconds: milliseconds)
    }

    private func showScreen(_ items: [ScreenTranslation.Item], milliseconds: Int) {
        screenShown = items
        screenShownUntil = Date().addingTimeInterval(Double(milliseconds) / 1000)
        if settings.output.showsOnComputer { screenItems = items }
        screenState = .shown
        screenExpiry?.cancel()
        screenExpiry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            self?.hideScreen()
        }
    }

    /// Çeviriyi durdurur, sonuçları telefondan ve TV'den kaldırır.
    func hideScreen() {
        stopFollowing()
        guard screenState != .idle || !screenItems.isEmpty else { return }
        screenTask?.cancel()
        screenTask = nil
        screenExpiry?.cancel()
        screenExpiry = nil
        screenItems = []
        screenShown = []
        screenShownUntil = .distantPast
        screenState = .idle
        server.clearScreen()
        server.clear()
    }

    /// Ekran çevrilemedi: nedeni telefonda ve TV'de birkaç saniye görünür.
    private func showScreenFailure(_ error: Error, translator: TextTranslator) {
        guard !Task.isCancelled else { return }
        screenState = .idle
        server.clear()
        let reason: String
        if let online = translator as? AITranslator, online.lastLineWasRateLimited {
            reason = String(format: String(localized: "%@ has reached its per-minute limit. Try again in a minute."), settings.translationEngine.displayName)
        } else {
            switch error as? TranslatorError {
            case .needsDownload: reason = String(localized: "The free translation isn't downloaded yet.")
            case .unsupported: reason = String(localized: "The free translation doesn't work on this phone.")
            case nil: reason = String(localized: "Something went wrong. Try again.")
            }
        }
        server.sendSubtitle(String(format: String(localized: "Couldn't translate the screen: %@"), reason), durationMs: 6000)
    }

    /// Deneme altyazısı: TV'de ya da telefon ekranında yazının nasıl göründüğü.
    func sendTestSubtitle() {
        Task {
            try? await startServer()
            await confirmTVReachable()
            // Çeviri sürmüyorken TV'nin eşleştirme isteği (TV 0.9.34+) reddediliyordu; TV'de yalnız "Eşleştirme
            // tamamlanmadı" çıkıyordu. Deneme, Profil'deki "TV eşleştir" gibi iki dakikalık onay penceresi açar.
            if !isRunning { server.pairing.open() }
            server.sendStyle(settings.style)
            server.sendSubtitle(String(localized: "This is a test subtitle. Can you see it on top of the game?"), durationMs: 8000)
            // TV bağlı değilse yazı TV'ye gitmiyordu ve TV'deki 6 haneli kodun nereye yazılacağı aranıyordu (kod yazılmaz,
            // bu telefonda açılan pencerede onaylanır). Yönerge gösterilir; TV onaylanıp bağlanınca yazı bir kez daha gider.
            testWaitTask?.cancel()
            guard settings.output.showsOnTV, server.connectedClients == 0 else {
                testTVNotConnected = false
                return
            }
            testTVNotConnected = true
            testWaitTask = Task { [weak self] in
                guard let self else { return }
                let deadline = ContinuousClock.now + self.testPairWait
                while self.server.connectedClients == 0, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                }
                guard self.server.connectedClients > 0 else { return }
                self.testTVNotConnected = false
                self.server.sendStyle(self.settings.style)
                self.server.sendSubtitle(String(localized: "This is a test subtitle. Can you see it on top of the game?"), durationMs: 8000)
            }
        }
    }

    // MARK: - Durum metinleri

    var ps5StatusText: String {
        switch sessionState {
        case .streaming: return String(localized: "Connected")
        case .connecting:
            // 30 sn'den uzun sürerse nedeni (PS5 uyandırılıyor / yanıt vermiyor / yanıt verdi ama açılmıyor); Mac,
            // Windows ve Android'de de aynı.
            guard let since = connectingSince, !isXbox, !demoMode,
                  let hint = ConnectingHint.text(seconds: Date().timeIntervalSince(since),
                                                 step: session?.connectStep.flatMap { ConnectingHint.Step(rawValue: $0.rawValue) })
            else { return String(localized: "Connecting…") }
            return String(localized: "Connecting…") + "\n" + hint
        case .disconnected(let reason):
            guard isRunning else { return String(localized: "Not connected") }
            switch reason {
            case .consoleAsleep: return String(localized: "Turn on your PS5")
            case .inUse: return String(localized: "Remote Play is in use on another device")
            case .refused: return String(localized: "The PS5 did not accept the connection yet. It may still be starting up, or its network address may have changed. Reconnecting and searching for the PS5… If this keeps happening, make sure the PS5 is on and on the same network.")
            case .loginPasscode:
                return String(localized: "The PS5 asks for this account's login passcode. Enter it in Settings, or turn off this account's login passcode on the PS5.")
            case .loginPasscodeIncorrect:
                return String(localized: "The PS5 didn't accept the login passcode in Settings. Correct it, or turn off this account's login passcode on the PS5.")
            case .registrationInvalid: return String(localized: "The PS5 didn't accept this pairing. Pair the PS5 again with the second account in Settings.")
            case .noPicture: return String(localized: "No picture from the PS5. Is Remote Play turned off, or is the PS5 in rest mode? Check, then start again.")
            case .notFound(let host):
                return String(format: String(localized: "PS5 not found at %@. Searching the network for it. Make sure it is on and on the same network; if its address changed, use Enter IP Address in Settings > Console. Reconnecting…"), host)
            // Kablosuz ağda akış sık kopuyordu (GitHub #388, #401): yeniden bağlanılır, kalıcı çözüm kablodur.
            case .network:
                return String(localized: "Lost the connection to the PS5. Reconnecting… If this keeps happening, connect the PS5 to the router with a cable.")
            // 0x80108b12: PS5'te Uzaktan Oynatma kapalı (GitHub #9). Ayar açılınca yeniden denemede bağlanılır.
            case .rejected(.some(DisconnectReason.remotePlayDisabled)):
                return String(format: String(localized: "Remote Play is turned off on the PS5 (code %@). On the PS5, go to Settings › System › Remote Play and turn on Enable Remote Play."),
                              String(format: "0x%08x", DisconnectReason.remotePlayDisabled))
            // Eskiden "Yeniden bağlanılıyor…" ile anlamsız libchiaki metni (Unknown Session Request Error) vardı.
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
            case .other(let detail) where isXbox: return detail
            case .other, .stopped: return String(localized: "Reconnecting…")
            }
        }
    }

    var tvStatusText: String {
        tvClients > 0 ? String(localized: "Connected")
            : tvReconnecting ? String(localized: "Reconnecting…")
            // TV gerçekten yanıt vermiyorsa "TV uygulaması bekleniyor" denmez (beklenen bir şey yok).
            : tvNotResponding ? String(localized: "Not responding — searching again…")
            : String(localized: "Waiting for the TV app")
    }

    // MARK: - TV uygulamasının sürümü

    /// TV'deki CouchSubs sürümünü sessizce okur (Samsung sdb, Android TV adb, LG ssh; geliştirici modu kapalıysa
    /// sorulamaz); telefondaki paketten eskiyse `tvAppUpdate` dolar. Uygulama açılınca ve TV her bağlandığında çağrılır.
    func checkTVApp(force: Bool = false) async {
        guard !checkingTVApp else { return }
        if !force, let last = tvAppCheckedAt, Date().timeIntervalSince(last) < 60 { return }
        let target: (TVBrand, String, UInt16?)
        if let installed = installedTVApp {
            // Bu telefonun daha önce kurduğu Samsung uygulaması kurulu bilinir (bekçi listeye bakmadan açar).
            if installed.brand == .samsung { SamsungAppKnowledge.shared.mark(host: installed.host) }
            target = (installed.brand, installed.host, installed.port)
        } else if let tv, !tv.host.isEmpty {
            target = (tv.brand, tv.host, nil)
        } else {
            return
        }
        guard let bundled = TVPackages.version(for: target.0) else { return }
        checkingTVApp = true
        tvAppCheckedAt = Date()
        defer { checkingTVApp = false }
        let version: String
        switch await TVAppVersionCheck.check(brand: target.0, host: target.1, port: target.2) {
        case .unknown: return
        case .missing:
            // TV'ye bağlanıldı ve listede CouchSubs yok: uygulama silinmiş (#1158); "kurulu" kaydı silinir.
            samsungAppMissing(host: target.1)
            return
        case .version(let value): version = value
        }
        if Versions.isNewer(bundled, than: version) {
            tvAppUpdate = TVAppUpdate(brand: target.0, host: target.1, port: target.2, installed: version, bundled: bundled)
        } else {
            tvAppUpdate = nil
        }
        saveInstalledTVApp(InstalledTVApp(brand: target.0, host: target.1, port: target.2, version: version))
    }

    /// TV uygulaması altyazı akışına bağlanıp sürümünü bildirdi (boş: 0.9.69'den eski, sürüm bildirmeyen uygulama). LG'de
    /// geliştirici modu kapalıyken ya da anahtar bu telefonda değilken `checkTVApp` TV'deki sürümü okuyamıyor, TV uygulaması
    /// eski kalıyor ve hiç öneri çıkmıyordu (GitHub #884, #891). Eskiyse ana ekran "TV uygulamasını güncelle" önerir.
    func tvAppReported(_ version: String) {
        runningTVAppVersion = version
        shareLatestTVAppVersion()
        if lgRunningReported(version) { return }
        let target: (TVBrand, String, UInt16?)
        if let installed = installedTVApp {
            target = (installed.brand, installed.host, installed.port)
        } else if let tv, !tv.host.isEmpty {
            target = (tv.brand, tv.host, nil)
        } else {
            return
        }
        guard let bundled = TVPackages.version(for: target.0) else { return }
        if SubtitleServer.isTVAppOutdated(reported: version, bundled: bundled) {
            let installed = version.isEmpty ? SubtitleServer.unreportedTVAppVersion : version
            if tvAppUpdate == nil { SubtitleLog.write("TV uygulaması eski: TV \(installed), bu telefondaki paket \(bundled).") }
            tvAppUpdate = TVAppUpdate(brand: target.0, host: target.1, port: target.2, installed: installed, bundled: bundled)
        } else {
            tvAppUpdate = nil
            if !version.isEmpty, installedTVApp?.version != version, let installed = installedTVApp {
                saveInstalledTVApp(InstalledTVApp(brand: installed.brand, host: installed.host, port: installed.port, version: version))
            }
        }
    }

    /// LG, kurulumdan ya da kapat-aç'tan sonraki ilk sürüm bildirimi: çalışan uygulama kurulan sürümdeyse denetim biter;
    /// eskiyse bir kez daha kapatılıp açılır, yine eskiyse ana ekran "TV'de CouchSubs'ı kapatıp yeniden açın" der (fiş
    /// çekmek gerekmez). true: bildirim burada ele alındı. Mac, Windows ve Android ile aynı.
    private func lgRunningReported(_ version: String) -> Bool {
        guard var check = lgRunningCheck, let installed = installedTVApp, installed.brand == .lg else { return false }
        let verdict = check.report(version)
        lgRunningCheck = check
        let shown = version.isEmpty ? SubtitleServer.unreportedTVAppVersion : version
        switch verdict {
        case .running:
            lgRunningCheck = nil
            tvAppStaleRunning = nil
            InstallLog.shared.write("TV'de çalışan CouchSubs: \(shown) (kurulan \(check.expected)).")
            return false
        case .restartAgain:
            InstallLog.shared.write("TV'de çalışan CouchSubs hâlâ \(shown), kurulu \(check.expected); uygulama bir kez daha kapatılıp açılıyor.")
            let host = installed.host
            let expected = check.expected
            Task { [weak self] in
                let restarted = await Task.detached(priority: .userInitiated) { LGPhoneInstall.restartApp(host: host) }.value
                // Anahtar yok ya da geliştirici modu kapalı: kapatılamadı, kullanıcıya söylenir.
                if !restarted { self?.showLGStaleRunning(shown, expected: expected) }
            }
            return true
        case .stale:
            showLGStaleRunning(shown, expected: check.expected)
            return true
        }
    }

    private func showLGStaleRunning(_ running: String, expected: String) {
        lgRunningCheck = nil
        InstallLog.shared.write("TV'de çalışan CouchSubs kapatıp açtıktan sonra da \(running), kurulu \(expected); kullanıcıdan TV'de kapatıp açması isteniyor.")
        tvAppStaleRunning = running
    }

    /// Telefondan kurulum ya da sürüm denetimi bitti: TV hatırlanır. Android TV onaysız eşlendiği için altyazı hedefi olur.
    func tvAppInstalled(brand: TVBrand, host: String, port: UInt16?, version: String) async {
        // LG: kurulum (ya da kapat-aç) açık uygulamayı kapatıp açtı; açılan uygulamanın bildirdiği sürüm denetlenir.
        if brand == .lg {
            lgRunningCheck = TVAppRunningCheck(expected: version)
            tvAppStaleRunning = nil
        }
        saveInstalledTVApp(InstalledTVApp(brand: brand, host: host, port: port, version: version))
        if tvAppUpdate?.brand == brand, !Versions.isNewer(tvAppUpdate?.bundled ?? "", than: version) { tvAppUpdate = nil }
        tvAppMissing = false
        // Kurulan TV altyazı hedefi olur (Android'deki TvAppUpdate.installed gibi); yoksa kurulumun 3. adımında "Devam"
        // kapalı kalıyor, uygulama her açılışta yine o adımdan başlıyordu (#113).
        if !(tv?.brand == brand && tv?.host == host && hasTV) {
            let previousHost = tv?.host
            let name = switch brand {
            case .androidTV: "Android TV"
            case .lg: "LG TV"
            case .samsung: "Samsung TV"
            }
            try? await pair(LGTV(name: name, host: host, brand: brand))
            if keeper != nil, tv?.host == host, previousHost != host {
                // Çeviri sürerken bekçi eski adresi tutar (Android TV DHCP'den yeni adres aldı, #985); yeni TV kaydıyla
                // yeniden kurulur (Mac ile aynı).
                keeper?.stop()
                keeper = nil
                startKeeper()
            }
        }
        if hasTV, tv?.host == host, step == .output {
            store.save(true, for: StoreKey.setupComplete)
        }
    }

    /// Samsung TV'de CouchSubs yok (sessiz sürüm denetiminde `vd_applist` ya da bekçide TV'nin kurulu uygulama listesi):
    /// uygulama güncelleme sırasında ya da elle silinmiş (#1158). Önceden "kurulu" kaydı kalıyordu: Ayarlar sürümü
    /// gösteriyor, bekçi listesiz açmayı deniyor, ana ekran kurulumu önermiyordu. Kayıt silinir, ana ekran kurulumu önerir.
    /// Mac, Windows ve Android ile aynı.
    func samsungAppMissing(host: String) {
        SamsungAppKnowledge.shared.forget(host: host)
        if let installed = installedTVApp, installed.brand == .samsung, SamsungAppKnowledge.sameHost(installed.host, host) {
            InstallLog.shared.write("Samsung \(host): TV'de CouchSubs yok; telefondaki \"kurulu\" kaydı (\(installed.version)) silindi.")
            installedTVApp = nil
            defaults.removeObject(forKey: StoreKey.tvAppInstalled)
        }
        if tvAppUpdate?.brand == .samsung, SamsungAppKnowledge.sameHost(tvAppUpdate?.host, host) { tvAppUpdate = nil }
        if let tv, tv.brand == .samsung, SamsungAppKnowledge.sameHost(tv.host, host) { tvAppMissing = true }
    }

    private func saveInstalledTVApp(_ value: InstalledTVApp) {
        installedTVApp = value
        // Bu telefonun kurduğu ya da sürümünü TV'den okuduğu Samsung uygulaması kurulu bilinir.
        if value.brand == .samsung { SamsungAppKnowledge.shared.mark(host: value.host) }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: StoreKey.tvAppInstalled) }
    }

    // MARK: - Sunucu

    /// Sunucu açık değilse açar (ilk kez ya da iOS dinleyiciyi kapattıktan sonra); port değiştiyse TV'yi açık tutan
    /// görev yeni adresle yeniden kurulur. Hata günlüklere yazılır.
    private func ensureServer(force: Bool = false) async {
        if !force, serverStarted, server.isListening { return }
        // Düşme bildirimi ve öne gelme aynı anda yeniden açmaya kalkmasın.
        guard !serverRestarting else { return }
        serverRestarting = true
        defer { serverRestarting = false }
        let previousPort = serverPort
        if serverStarted {
            serverStarted = false
            // Eşleştirme durumu korunur: onay bekleyen istek ve "TV eşleştir" süresi yeniden açılışta silinmez.
            server.stop(keepPairing: true)
        }
        // Önceki açılışta 8787 alınamayıp rastgele porta düşüldüyse yeniden 8787 denenir: TV uygulaması ağı o portta tarar.
        if serverPort != AppIdentity.serverPort {
            server = SubtitleServer(port: AppIdentity.serverPort, key: server.accessKey, pairing: server.pairing)
            attachServer()
        }
        do {
            try await startServer()
        } catch {
            RemotePlayLog.write("Altyazı sunucusu açılamadı: \(error)")
            SubtitleLog.write("Altyazı sunucusu açılamadı; TV bağlanamaz: \(error)")
            return
        }
        syncTVPairing()
        guard isRunning else { return }
        server.pairing.setSession(true)
        if serverPort != previousPort, keeper != nil {
            keeper?.stop()
            keeper = nil
            startKeeper()
        }
    }

    /// Testler için: sağlık yoklamasının yanıt alamadığı durumdaki gibi sunucuyu yeniden açar.
    func restartServer() async { await ensureServer(force: true) }

    /// Sunucu kendi adresinden `/hello` isteğine yanıt veriyor mu (dinleyici gerçekten bağlantı kabul ediyor mu).
    func serverAnswers() async -> Bool {
        guard serverStarted, server.isListening, let url = URL(string: "http://127.0.0.1:\(serverPort)/hello") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200 && String(decoding: data, as: UTF8.self).contains("couchsubs")
    }

    /// Sunucu yanıt vermiyorsa yeniden açar; yanıt verip vermediğini döner (yeniden açmadan önceki durum).
    @discardableResult
    private func reviveServerIfSilent() async -> Bool {
        // TV bağlıyken sunucuya dokunulmaz (yeniden açmak bağlı TV'yi düşürür).
        if serverStarted, server.isListening, tvClients > 0 { return true }
        if await serverAnswers() { return true }
        // Tek bir yanıtsız yoklama (askıdan yeni dönen uygulama) sunucuyu kapatmasın: TV o sırada kod bekliyor olabilir.
        try? await Task.sleep(for: .milliseconds(500))
        if await serverAnswers() { return true }
        RemotePlayLog.write("Altyazı sunucusu yanıt vermiyor; yeniden açılıyor")
        SubtitleLog.write("Altyazı sunucusu yanıt vermiyor; yeniden açılıyor")
        await ensureServer(force: true)
        return false
    }

    private func serverDropped(_ reason: String) {
        RemotePlayLog.write("Altyazı sunucusu kapandı (\(reason)); yeniden açılıyor")
        SubtitleLog.write("Altyazı sunucusu kapandı (\(reason)); yeniden açılıyor")
        Task { await ensureServer() }
    }

    /// Çeviri başladıktan bir süre sonra TV uygulaması hâlâ bağlanmadıysa tanı satırı yazılır ve TV kartı ne yapılacağını
    /// söyler. TestFlight'ta "Hazır" görünen telefonda TV kartı "TV uygulaması bekleniyor"da kalıyordu, iz yoktu.
    private func watchTVConnection() {
        tvWaitTask?.cancel()
        tvWaitingLong = false
        guard settings.output.showsOnTV, !demoMode else { return }
        tvWaitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.tvWaitLimit)
            guard !Task.isCancelled, let self, self.isRunning, self.tvClients == 0 else { return }
            self.tvWaitingLong = true
            // Sunucu yanıt vermiyorsa yeniden açılır; TV uygulaması bir sonraki denemesinde bağlanır.
            let answered = await self.reviveServerIfSilent()
            let line = self.tvConnectionDiagnostic() + " yanıt=\(answered ? 1 : 0) port=\(self.serverPort)"
            RemotePlayLog.write(line)
            SubtitleLog.write(line)
            InstallLog.shared.write(line)
        }
    }

    /// TV bağlanmadığında neye bakılacağı: sunucu dinliyor mu, hangi adresi veriyor, TV kayıtlı mı, TV'yi açık tutan
    /// görev var mı, TV uygulaması eski mi (anahtarsız istemci).
    func tvConnectionDiagnostic() -> String {
        // Günlük satırı (ekran metni değil): 1 = evet, 0 = hayır.
        func flag(_ value: Bool) -> String { value ? "1" : "0" }
        let tvText = tv.map { "\($0.brand.rawValue) \($0.host)" } ?? "-"
        let address = tv.map { serverAddress(for: $0) } ?? "http://\(NetworkAddress.near(nil) ?? "?"):\(serverPort)"
        return "TV bağlanmadı (\(Int(Self.tvWaitLimit.components.seconds)) sn): sunucu dinliyor=\(flag(server.isListening)) "
            + "adres=\(address) TV=\(tvText) eşli=\(flag(hasTV)) TV görevi=\(flag(keeper != nil)) "
            + "eski TV uygulaması=\(flag(server.hasLegacyClient)) çıkış=\(settings.output.rawValue)"
    }

    /// Bu telefondaki TV paketinin sürümü altyazı akışının `link` olayıyla TV'ye gider; TV'deki uygulama daha eskiyse TV'nin
    /// paneli "TV uygulaması eski" der (GitHub #1199). TV seçilmemişse LG paketi (sürümler aynı). Mac, Windows ve Android
    /// ile aynı.
    private func shareLatestTVAppVersion() {
        let brand = installedTVApp?.brand ?? tv?.brand ?? .lg
        server.latestTVAppVersion = TVPackages.version(for: brand) ?? TVPackages.lgVersion
    }

    private func startServer() async throws {
        shareLatestTVAppVersion()
        guard !serverStarted else { return }
        do {
            serverPort = try await server.start()
        } catch {
            RemotePlayLog.write("Altyazı sunucusu \(AppIdentity.serverPort) portunu alamadı (\(error)); rastgele port deneniyor")
            server = SubtitleServer(port: 0, key: server.accessKey, pairing: server.pairing)
            attachServer()
            serverPort = try await server.start()
        }
        serverStarted = true
    }

    /// Android TV kurulumunda uygulama açılırken verilecek başlatma parametreleri (sunucu açılamazsa nil).
    func androidLaunchParams(host: String) async -> String? {
        try? await startServer()
        guard serverStarted else { return nil }
        return AndroidTvInstaller.launchParams(server: serverAddress(for: LGTV(name: "", host: host, brand: .androidTV)))
    }

    /// TV ile aynı ağdaki telefon adresi.
    func serverAddress(for tv: LGTV) -> String {
        "http://\(NetworkAddress.near(tv.host.isEmpty ? "192.168.1.1" : tv.host) ?? "127.0.0.1"):\(serverPort)"
    }

    // MARK: - Türkçe dublaj (telefonun kendi sesi; masaüstündeki "Hızlı" dublajla aynı)

    private var dubber: PhoneDubber?

    private func makeDubber() -> PhoneDubber {
        if let dubber { return dubber }
        let dubber = PhoneDubber(server: { [unowned self] in self.server }, settings: settings.dubbing)
        dubber.onCastChanged = { [weak self] cast in self?.settings.dubbing.cast = cast }
        self.dubber = dubber
        return dubber
    }

    private func speak(_ lines: [SpokenLine]) {
        guard settings.dubbing.enabled else { return }
        makeDubber().speak(lines)
    }

    /// Okuma hattı seslendirme cümlelerini yalnız dublaj açıkken çıkarır: kapalıyken her satırda çevirmenin seslendirme
    /// hafızasına gidilmez (dublaj kapalı kullanıcıda bu iş hiç yapılmasın; Android'de de dublaj kapalıyken yapılmıyor).
    private func wireSpeech(_ pipeline: SubtitlePipeline) {
        pipeline.onSpeech = settings.dubbing.enabled ? { [weak self] lines in self?.speak(lines) } : nil
    }

    private func dubbingSettingsChanged() {
        if let pipeline { wireSpeech(pipeline) }
        guard let dubber else { return }
        dubber.cast = settings.dubbing.cast
        if dubber.output != settings.dubbing.output {
            dubber.stop()
            dubber.output = settings.dubbing.output
        }
        if !settings.dubbing.enabled { dubber.stop() }
    }

    /// Ayarlardaki "Dinle".
    func previewVoice(_ voice: DubbingVoice) { makeDubber().preview(voice) }

    func assignVoice(_ voice: DubbingVoice, to name: String) { settings.dubbing.cast.assign(voice, to: name) }
}

/// Son PS5 karesi; yalnız bölge önizlemesi izler (her karede bütün ekranlar yeniden çizilmesin).
@MainActor
final class PhoneFramePreview: ObservableObject {
    @Published var image: CGImage?
}
