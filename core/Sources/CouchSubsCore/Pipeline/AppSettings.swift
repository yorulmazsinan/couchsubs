// SPDX-License-Identifier: AGPL-3.0-only
// Mac ve iPhone/iPad uygulamalarının ortak ayarları ve kalıcı kayıt (Anahtarlık) arayüzü.

import Foundation

public enum StoreKey {
    public static let subtitleAccessKey = "subtitleAccessKey"
    public static let accountId = "accountId"
    public static let console = "console"
    public static let tv = "tv"
    public static let tvKey = "tvKey"
    public static let tvDevKey = "tvDevKey"
    /// Samsung ve Android TV'ye CouchSubs'ın kurduğu sürüm (LG'de sürüm TV'den okunur).
    public static let tvAppVersion = "tvAppVersion"
    /// LG geliştirici modu süresinin son uzatıldığı an.
    public static let devSessionRenewed = "devSessionRenewed"
    /// Aynı süre TV adresine göre tutulur; ikinci TV birincinin kaydıyla atlanmaz.
    public static func devSessionRenewedFor(host: String) -> String {
        "devSessionRenewed.\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
    public static let settings = "settings"
    /// İkinci hesabın PS5 giriş şifresi (4 hane, isteğe bağlı); PS5 isterse oturum açılırken gönderilir.
    public static let loginPasscode = "loginPasscode"
    /// Kurulum sihirbazı bitti. TV'siz kurulumda (altyazı bilgisayar ekranında) ana ekranı bu açar.
    public static let setupComplete = "setupComplete"
    /// Kullanıcının DeepL anahtarı (isteğe bağlı çevrimiçi çeviri).
    public static let deepLKey = "deepLKey"
    /// Kullanıcının yapay zekâ anahtarları (isteğe bağlı çevrimiçi çeviri).
    public static let geminiKey = "geminiKey"
    public static let openAIKey = "openAIKey"
    public static let claudeKey = "claudeKey"
    /// Yerel model sunucusunun (Ollama, LM Studio) isteğe bağlı anahtarı.
    public static let localAIKey = "localAIKey"
    /// "Yayın penceresi"nin zemin rengi (`StreamBackground`).
    public static let streamBackground = "streamBackground"
}

/// Ayarlardaki çeviri motoru seçimi. Ücretsiz olan cihaz üstü çeviridir; bulut motorları kullanıcının kendi anahtarıyla
/// çalışır; yerel model (Ollama, LM Studio) kullanıcının bilgisayarında çalışır, anahtarı isteğe bağlıdır (Windows'taki
/// `TranslationEngine` ile aynı).
public enum TranslationEngine: String, Codable, CaseIterable {
    case free, deepL = "deepl", gemini, openAI = "openai", claude, local

    public var aiProvider: AIProvider? {
        switch self {
        case .gemini: .gemini
        case .openAI: .openAI
        case .claude: .claude
        case .local: .local
        case .free, .deepL: nil
        }
    }

    public init(_ provider: AIProvider) {
        switch provider {
        case .gemini: self = .gemini
        case .openAI: self = .openAI
        case .claude: self = .claude
        case .local: self = .local
        }
    }

    /// Hizmetin adı (marka adı; çevrilmez). Yerel modelin adı uygulamanın metin dosyasından çevrilir.
    public var displayName: String {
        self == .local ? String(localized: "Local model") : aiProvider?.displayName ?? "DeepL"
    }

    /// Anahtarlık'taki anahtar adı.
    public var storeKey: String? {
        switch self {
        case .free: nil
        case .deepL: StoreKey.deepLKey
        case .gemini: StoreKey.geminiKey
        case .openAI: StoreKey.openAIKey
        case .claude: StoreKey.claudeKey
        case .local: StoreKey.localAIKey
        }
    }
}

/// Altyazının gösterileceği yer (Windows'taki `SubtitleOutput` ile aynı). `obs`: yalnız OBS katmanı (`/obs`, yayın); TV
/// aranmaz ve açılmaz, bilgisayar ekranında (telefonda: bu telefonun ekranında) pencere açılmaz. OBS katmanı her seçimde
/// altyazıyı alır; `obs` yalnız öbür yerleri kapatır. Bu seçeneği tanımayan eski sürüm kaydı varsayılanla (TV) açar.
public enum SubtitleOutput: String, Codable, CaseIterable {
    case tv, computer, both, obs

    public var showsOnTV: Bool { self == .tv || self == .both }
    public var showsOnComputer: Bool { self == .computer || self == .both }
    /// Altyazının gideceği bir yer var mı: TV seçiliyse TV eşleşmiş olmalı; bilgisayar ekranı ve OBS TV istemez.
    public func hasDestination(hasTV: Bool) -> Bool { showsOnComputer || self == .obs || hasTV }
}

/// Görüntünün nereden okunduğu. `ps5`: CouchSubs PS5'e kendisi bağlanır (ikinci hesap). `remotePlayWindow`: oyun bu
/// bilgisayardaki Sony PS Remote Play uygulamasında oynanır, CouchSubs yalnız onun penceresini okur; PS5'e ikinci oturum
/// açılmadığı için ikinci hesap gerekmez. `captureWindow`: kullanıcının seçtiği OBS projektörü ya da oyun penceresi okunur
/// (bkz. `WindowCaptureTarget`; Windows'taki `CaptureWindow`). Eski kayıtlar `ps5` ile açılır.
public enum FrameSource: String, Codable, CaseIterable {
    case ps5, remotePlayWindow, captureWindow
}

/// Xbox seçiliyken görüntünün nereden okunduğu (#853). `xbox`: CouchSubs Xbox'a kendisi bağlanır (Microsoft girişi ve
/// seçilmiş Xbox). `captureWindow`: oyun bu bilgisayardaki Xbox uygulamasında, play.xbox.com'da ya da capture card ile
/// OBS'te oynanır; CouchSubs Xbox'a hiç bağlanmaz, yalnız seçilen pencereyi (`captureWindow`) okur. Xbox aynı anda tek
/// uzaktan oynatma bağlantısına izin verdiği için CouchSubs bağlanırsa kullanıcının oturumu düşerdi. Yalnız masaüstü:
/// telefonda okunacak pencere yoktur. Eski kayıtlar `xbox` ile açılır.
public enum XboxFrameSource: String, Codable, CaseIterable {
    case xbox, captureWindow
}

/// Görüntü pencereden okunurken hangi Remote Play uygulamasının penceresi: hangisi açıksa (Sony'nin PS Remote Play'i ya
/// da açık kaynak chiaki-ng), yalnız Sony'ninki ya da yalnız chiaki-ng'ninki. Eski kayıtlar "hangisi açıksa" ile açılır.
public enum RemotePlayApp: String, Codable, CaseIterable {
    case automatic, sony, chiaki
}

/// Uygulama pencerelerinin görünümü (Windows'taki `AppAppearance` ile aynı). Onaylı tasarım koyudur; varsayılan da odur.
public enum AppAppearance: String, Codable, CaseIterable {
    case dark, light, system
}

/// Kalıcı ayarlar (Anahtarlık değil, sıradan tercihler).
public struct UserSettings: Codable, Equatable {
    public var region = CropRegion()
    /// Bölgenin hazır seçimi (Alt bölge, Üst bölge, Tam ekran, Özel). Eski kayıtlarda yoktur; bölgeden çıkarılır.
    public var areaPreset = AreaPreset.bottom
    /// "Ortada tut": altyazı alanının çerçevesi kenarından boyutlandırılırken karşı kenar da aynı kadar oynar, alan ortalı
    /// kalır (oyunların çoğu altyazıyı ortalar). Kapalıysa yalnız tutulan kenar oynar (sola yaslı ya da köşedeki altyazı).
    /// Eski kayıtlarda yoktur; açık başlar (Windows: KeepAreaCentered, Android: keepAreaCentered).
    public var keepAreaCentered = true
    /// Altyazının yanındaki ek alanlar (görev, bildirim, telefon; en çok üç). Sıra kısayolu belirler: 1. alan
    /// "1. alanı çevir" (Num 1). Varsayılan: hiç yok.
    public var extraAreas: [ExtraArea] = []
    /// Serbest alan çevirisinin (Num 5) sonucu nerede gösterilir (Windows: FreeAreaTarget).
    public var freeAreaTarget = ResultTarget.tv
    /// Kullanıcının değiştirdiği kısayollar (yalnız varsayılandan farklı olanlar; bkz. `HotkeyTable.assign`). Eski
    /// kayıtlarda yoktur: bütün kısayollar varsayılanla açılır (Windows: Hotkeys).
    public var hotkeys: [HotkeyChoice] = []
    public var style = SubtitleStyle()
    public var sourceLanguage = "en"
    public var targetLanguage = "tr"
    public var dubbing = DubbingSettings()
    /// Açıksa çeviri `onlineEngine` ile yapılır (anahtarı kayıtlıysa); kapalıysa ya da hizmete ulaşılamazsa Apple'ın
    /// cihaz üstü çevirisi. Eski sürümlerde yalnız DeepL vardı; o kayıtlar DeepL ile açılır.
    public var onlineTranslation = false
    /// Seçili çevrimiçi motor (hiçbir zaman `.free` değildir).
    public var onlineEngine = TranslationEngine.deepL
    /// Seçili yapay zekâ modelleri (listedeki kimlikler; bkz. `AIProvider.models`).
    public var geminiModel = AIProvider.gemini.defaultModel.id
    /// Explicit opt-in for API keys billed by Google. Free keys keep the conservative local RPM.
    public var geminiPaidTier = false
    public var openAIModel = AIProvider.openAI.defaultModel.id
    public var claudeModel = AIProvider.claude.defaultModel.id
    /// Yerel model sunucusunun adresi (Ollama: http://127.0.0.1:11434/v1, LM Studio: http://localhost:1234/v1) ve
    /// kullanıcının yazdığı model adı.
    public var localAIBaseURL = LocalAIServer.ollamaURL
    public var localAIModel = LocalAIServer.defaultModel
    /// Ayarlardaki "Ek talimat" (#306): yapay zekâ çevirmeninin (Gemini, OpenAI, Claude, yerel model) sistem talimatının
    /// sonuna eklenir; boşsa hiçbir şey değişmez. Eski kayıtlarda yoktur, boş açılır.
    public var aiInstruction = ""
    /// Altyazı TV'de mi, bilgisayar ekranındaki pencerede mi, ikisinde de mi. Eski kayıtlar TV ile açılır.
    public var output = SubtitleOutput.tv
    /// Bilgisayar ekranındaki altyazı penceresi tıklamaları alttaki pencereye (oyun, PS Remote Play) geçirir.
    public var overlayClickThrough = false
    /// Oyun paketlerindeki hazır Türkçe çeviriler kullanılır (yalnız İngilizce→Türkçe).
    public var gamePacks = true
    /// Pakette bulunmayan İngilizce satırlar ortak havuza gönderilir (anonim; bkz. `LinePool`).
    public var sharePool = LinePool.enabledByDefault
    /// Oynanan oyun paketle tanınmazsa çeviri başladıktan iki dakika sonra bir kez sorulur (bkz. `GameSense`).
    public var askGame = true
    /// Kullanım verisi: telefonlardaki gibi kimliğe bağlanmayan kullanım istatistikleri gönderilir (bkz. `UsageStats`).
    public var usageData = UsageStats.enabledByDefault
    /// Kullanım verisi bilgi notu gösterildi (ilk açılışta bir kez). Eski kayıtlarda yoktur (false).
    public var usageNoticeSeen = false
    /// Altyazıdaki konuşan adı ("ARTHUR: …") çeviride gösterilir; kapalıysa yalnız Türkçe cümle görünür.
    public var showSpeakerNames = true
    /// Konuşana göre renk: "Mattia: …" satırında ad ve satır o konuşanın sabit renginde görünür (bkz. `SpeakerColors`).
    public var speakerColors = true
    /// Mac'te değişmeyen altyazı bölgesini en fazla iki kare yeniden kullan; varsayılan kapalı.
    public var fastSubtitleDetection = false
    /// Yalnız GTA 6'nın lacivert altyazı zemini üstündeki yazıyı oku. Varsayılan kapalı.
    public var watchSubtitleBackground = false
    /// "Bozuk okunan satır için bekleme" (ms): sözlükte olmayan sözcüklerle okunan satırın daha iyi okuması için en çok bu
    /// kadar beklenir (Windows: MisreadWaitMs). Eski kayıtlarda yoktur; önerilen 800 ile açılır.
    public var misreadWaitMs = SubtitlePipeline.packWaitMs
    /// "Yarım okunan satır için bekleme" (ms): yarım görünen satırın tamamı için en çok bu kadar beklenir (Windows:
    /// PartialWaitMs). Önerilen 300.
    public var partialWaitMs = SubtitlePipeline.cleanWaitMs
    /// Ayarlardaki bekleme kaydırıcılarının üst sınırı (ms); kayıttaki değer hatta en çok `maxWaitMs` olarak uygulanır.
    public static let waitSliderMaxMs = 1000
    public static let maxWaitMs = 2000
    /// Mac'te GTA 6 telefonu açıkken mesajları yerinde gösterir. Varsayılan kapalı; kullanıcı açmadıkça telefon okunmaz.
    public var autoReadGamePhone = false
    /// Bilinen oyunlarda hazır ek alanlar (bkz. `GameAreaPresets`); kullanıcının kendi ek alanı varsa o kullanılır.
    /// Varsayılan kapalı (beta.63–68'de açık geliyordu: otomatik ekran yazısı kapalıyken de GTA 6'nın sol üstünde menüyü,
    /// sağda bildirimleri çeviriyordu). Kullanıcı açmadıkça altyazı alanı dışında hiçbir şey çevrilmez.
    public var gameAreaPresets = false
    /// "Ekran yazılarını altyazıdan ayır": ek alan ve otomatik ekran yazısı kutuları özgün rengini ve zeminini korur,
    /// altyazı kutusuna benzemez (zemin yoksa zeminsiz, koyu gölgeli). Eski kayıtlarda yoktur; açık başlar.
    public var setTextApart = true
    /// Ekran yazıları kendiliğinden bulunup yerinde çevrilir (görev, yardım, mesaj; bütün oyunlarda, bkz.
    /// `ScreenTextDetector`). Altyazı alanı Tam ekranken çalışmaz. Deneysel: varsayılan kapalı (beta.63'te açık geliyordu;
    /// oyun dünyasındaki poster ve plakaları da çeviriyordu). Kullanıcı Ayarlar'dan açar.
    public var autoScreenText = false
    /// Bir kerelik göç yapıldı (bkz. `migratingAutoScreenText()`). Eski kayıtlarda yoktur (false).
    public var autoScreenTextReset = false
    /// Hazır alanlar ve GTA 6 telefonu bir kerelik göçü yapıldı (bkz. `migratingScreenTextExtras()`). Eski kayıtlarda yoktur.
    public var screenTextExtrasReset = false
    /// Otomatik ekran yazısında hangi türler çevrilir (bkz. `ScreenTextKind`); yalnız `autoScreenText` açıkken geçerli.
    /// Eski kayıtlarda yoktur; varsayılanla gelir: telefon, görev, yardım/eylemler açık; menüler ve diğerleri kapalı
    /// (kullanıcı isteği: "menülerde olmasını istemiyorum").
    public var screenTextPhone = true
    public var screenTextMission = true
    public var screenTextHelp = true
    public var screenTextMenus = false
    public var screenTextOther = false
    /// iPhone Xbox ev yayınında oyun sesi telefonda çalınır. Xbox uzaktan oynatma sürerken sesi istemciye verip TV'yi
    /// susturabilir; kapalıyken ses hiçbir yerden gelmeyebilir, bu yüzden varsayılan açık. PS5'i etkilemez.
    public var xboxAudioOnDevice = true
    /// Koyu, açık ya da sistemle aynı. Eski kayıtlarda yoktur; onlar da koyu açılır.
    public var appearance = AppAppearance.dark
    /// Görüntü PS5 bağlantısından mı, bu bilgisayardaki PS Remote Play penceresinden mi okunur.
    public var frameSource = FrameSource.ps5
    /// Xbox seçiliyken görüntü Xbox bağlantısından mı, seçilen pencereden mi okunur (bkz. `XboxFrameSource`).
    public var xboxFrameSource = XboxFrameSource.xbox
    /// Pencereden okunurken hangi Remote Play uygulaması (bkz. `RemotePlayApp`).
    public var remotePlayApp = RemotePlayApp.automatic
    /// OBS ya da başka bir açık pencere seçildiyse yalnız bu pencere okunur (varsayılan nil; masaüstünde).
    public var captureWindow: WindowCaptureTarget?
    /// Oyuna göre kaydedilmiş alanlar (son kullanılan sonda, en çok `AreaProfiles.maxCount`; bkz. `GameAreas`).
    public var areaProfiles: [AreaProfile] = []
    /// Şu an uygulanan profilin anahtarı; genel alanlar kullanılıyorsa nil.
    public var activeAreaProfile: String?
    /// Profil uygulanırken kenara alınan genel alanlar; profil bırakılınca geri gelir.
    public var generalAreas: AreaSet?

    public init() {}

    /// Yeni eklenen ayarlar eski kayıtta yoktur; varsayılanla açılır, eski ayarlar kaybolmaz.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UserSettings()
        region = try values.decodeIfPresent(CropRegion.self, forKey: .region) ?? defaults.region
        areaPreset = (try? values.decodeIfPresent(AreaPreset.self, forKey: .areaPreset)) ?? AreaPreset.matching(region)
        keepAreaCentered = try values.decodeIfPresent(Bool.self, forKey: .keepAreaCentered) ?? defaults.keepAreaCentered
        extraAreas = Array(((try? values.decodeIfPresent([ExtraArea].self, forKey: .extraAreas)) ?? defaults.extraAreas)
            .prefix(ExtraArea.maxCount))
        style = try values.decodeIfPresent(SubtitleStyle.self, forKey: .style) ?? defaults.style
        sourceLanguage = try values.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? defaults.sourceLanguage
        targetLanguage = try values.decodeIfPresent(String.self, forKey: .targetLanguage) ?? defaults.targetLanguage
        dubbing = (try? values.decodeIfPresent(DubbingSettings.self, forKey: .dubbing)) ?? defaults.dubbing
        onlineTranslation = try values.decodeIfPresent(Bool.self, forKey: .onlineTranslation) ?? defaults.onlineTranslation
        let engine = (try? values.decodeIfPresent(TranslationEngine.self, forKey: .onlineEngine)) ?? defaults.onlineEngine
        onlineEngine = engine == .free ? defaults.onlineEngine : engine
        geminiModel = try values.decodeIfPresent(String.self, forKey: .geminiModel) ?? defaults.geminiModel
        geminiPaidTier = try values.decodeIfPresent(Bool.self, forKey: .geminiPaidTier) ?? defaults.geminiPaidTier
        openAIModel = try values.decodeIfPresent(String.self, forKey: .openAIModel) ?? defaults.openAIModel
        claudeModel = try values.decodeIfPresent(String.self, forKey: .claudeModel) ?? defaults.claudeModel
        localAIBaseURL = try values.decodeIfPresent(String.self, forKey: .localAIBaseURL) ?? defaults.localAIBaseURL
        localAIModel = try values.decodeIfPresent(String.self, forKey: .localAIModel) ?? defaults.localAIModel
        aiInstruction = (try? values.decodeIfPresent(String.self, forKey: .aiInstruction)) ?? defaults.aiInstruction
        output = (try? values.decodeIfPresent(SubtitleOutput.self, forKey: .output)) ?? defaults.output
        overlayClickThrough = try values.decodeIfPresent(Bool.self, forKey: .overlayClickThrough) ?? defaults.overlayClickThrough
        freeAreaTarget = (try? values.decodeIfPresent(ResultTarget.self, forKey: .freeAreaTarget)) ?? defaults.freeAreaTarget
        // Bozuk tek bir kayıt bütün kısayolları silmesin: okunamayan seçimler atlanır.
        hotkeys = ((try? values.decodeIfPresent([LossyHotkeyChoice].self, forKey: .hotkeys)) ?? []).compactMap(\.choice)
        gamePacks = try values.decodeIfPresent(Bool.self, forKey: .gamePacks) ?? defaults.gamePacks
        sharePool = try values.decodeIfPresent(Bool.self, forKey: .sharePool) ?? defaults.sharePool
        askGame = try values.decodeIfPresent(Bool.self, forKey: .askGame) ?? defaults.askGame
        usageData = try values.decodeIfPresent(Bool.self, forKey: .usageData) ?? defaults.usageData
        usageNoticeSeen = try values.decodeIfPresent(Bool.self, forKey: .usageNoticeSeen) ?? defaults.usageNoticeSeen
        showSpeakerNames = try values.decodeIfPresent(Bool.self, forKey: .showSpeakerNames) ?? defaults.showSpeakerNames
        speakerColors = try values.decodeIfPresent(Bool.self, forKey: .speakerColors) ?? defaults.speakerColors
        fastSubtitleDetection = try values.decodeIfPresent(Bool.self, forKey: .fastSubtitleDetection) ?? defaults.fastSubtitleDetection
        watchSubtitleBackground = try values.decodeIfPresent(Bool.self, forKey: .watchSubtitleBackground) ?? defaults.watchSubtitleBackground
        misreadWaitMs = (try? values.decodeIfPresent(Int.self, forKey: .misreadWaitMs)) ?? defaults.misreadWaitMs
        partialWaitMs = (try? values.decodeIfPresent(Int.self, forKey: .partialWaitMs)) ?? defaults.partialWaitMs
        autoReadGamePhone = try values.decodeIfPresent(Bool.self, forKey: .autoReadGamePhone) ?? defaults.autoReadGamePhone
        gameAreaPresets = try values.decodeIfPresent(Bool.self, forKey: .gameAreaPresets) ?? defaults.gameAreaPresets
        setTextApart = try values.decodeIfPresent(Bool.self, forKey: .setTextApart) ?? defaults.setTextApart
        autoScreenText = try values.decodeIfPresent(Bool.self, forKey: .autoScreenText) ?? defaults.autoScreenText
        autoScreenTextReset = try values.decodeIfPresent(Bool.self, forKey: .autoScreenTextReset) ?? defaults.autoScreenTextReset
        screenTextExtrasReset = try values.decodeIfPresent(Bool.self, forKey: .screenTextExtrasReset) ?? defaults.screenTextExtrasReset
        screenTextPhone = try values.decodeIfPresent(Bool.self, forKey: .screenTextPhone) ?? defaults.screenTextPhone
        screenTextMission = try values.decodeIfPresent(Bool.self, forKey: .screenTextMission) ?? defaults.screenTextMission
        screenTextHelp = try values.decodeIfPresent(Bool.self, forKey: .screenTextHelp) ?? defaults.screenTextHelp
        screenTextMenus = try values.decodeIfPresent(Bool.self, forKey: .screenTextMenus) ?? defaults.screenTextMenus
        screenTextOther = try values.decodeIfPresent(Bool.self, forKey: .screenTextOther) ?? defaults.screenTextOther
        xboxAudioOnDevice = try values.decodeIfPresent(Bool.self, forKey: .xboxAudioOnDevice) ?? defaults.xboxAudioOnDevice
        appearance = (try? values.decodeIfPresent(AppAppearance.self, forKey: .appearance)) ?? defaults.appearance
        frameSource = (try? values.decodeIfPresent(FrameSource.self, forKey: .frameSource)) ?? defaults.frameSource
        xboxFrameSource = (try? values.decodeIfPresent(XboxFrameSource.self, forKey: .xboxFrameSource)) ?? defaults.xboxFrameSource
        remotePlayApp = (try? values.decodeIfPresent(RemotePlayApp.self, forKey: .remotePlayApp)) ?? defaults.remotePlayApp
        captureWindow = try? values.decodeIfPresent(WindowCaptureTarget.self, forKey: .captureWindow)
        areaProfiles = Array(((try? values.decodeIfPresent([AreaProfile].self, forKey: .areaProfiles)) ?? defaults.areaProfiles)
            .suffix(AreaProfiles.maxCount))
        activeAreaProfile = try? values.decodeIfPresent(String.self, forKey: .activeAreaProfile)
        generalAreas = try? values.decodeIfPresent(AreaSet.self, forKey: .generalAreas)
    }

    /// Hazır bölge seçilir; Özel seçilince kayıtlı bölge olduğu gibi kalır.
    public mutating func selectAreaPreset(_ preset: AreaPreset) {
        areaPreset = preset
        if let region = preset.region { self.region = region }
    }

    /// Bölge elle değişti (kaydırıcı ya da sürükleme): seçim Özel olur.
    public mutating func setCustomRegion(_ region: CropRegion) {
        self.region = region
        areaPreset = .custom
    }

    /// Listede olmayan kayıtlı modeller (eski ayar ya da listeden çıkarılan model) varsayılana döner.
    public func withCuratedModels() -> UserSettings {
        var settings = self
        for provider in AIProvider.allCases { settings.setModel(provider.model(model(for: provider)).id, for: provider) }
        return settings
    }

    /// Yapay zekâ hizmetinin seçili model kimliği.
    public func model(for provider: AIProvider) -> String {
        switch provider {
        case .gemini: geminiModel
        case .openAI: openAIModel
        case .claude: claudeModel
        case .local: localAIModel
        }
    }

    public mutating func setModel(_ id: String, for provider: AIProvider) {
        switch provider {
        case .gemini: geminiModel = id
        case .openAI: openAIModel = id
        case .claude: claudeModel = id
        case .local: localAIModel = id
        }
    }

    /// Yerel model sunucusu; adres geçersizse nil.
    public var localAIServer: LocalAIServer? {
        LocalAIServer(baseURL: localAIBaseURL, model: AIProvider.local.model(localAIModel).id)
    }

    /// Ayarlarda seçili motor: çevrimiçi çeviri kapalıysa ücretsiz olan.
    public var translationEngine: TranslationEngine {
        get { onlineTranslation ? onlineEngine : .free }
        set {
            onlineTranslation = newValue != .free
            if newValue != .free { onlineEngine = newValue }
        }
    }
}

public protocol AppStore: AnyObject {
    func save<T: Encodable>(_ value: T, for key: String)
    func load<T: Decodable>(_ type: T.Type, for key: String) -> T?
    func remove(_ key: String)
}

public final class KeychainStore: AppStore {
    public init() {}
    public func save<T: Encodable>(_ value: T, for key: String) { SecureStore.save(value, for: key) }
    public func load<T: Decodable>(_ type: T.Type, for key: String) -> T? { SecureStore.load(type, for: key) }
    public func remove(_ key: String) { SecureStore.remove(key) }
}

/// Hiçbir şey kalıcı olmaz.
public final class EphemeralStore: AppStore {
    private var values: [String: Data] = [:]
    public init() {}
    public func save<T: Encodable>(_ value: T, for key: String) { values[key] = try? JSONEncoder().encode(value) }
    public func load<T: Decodable>(_ type: T.Type, for key: String) -> T? { values[key].flatMap { try? JSONDecoder().decode(type, from: $0) } }
    public func remove(_ key: String) { values[key] = nil }
}

/// Dublajın nereden çalınacağı.
public enum DubbingOutput: String, Codable, CaseIterable, Sendable {
    /// TV uygulaması çalar; ses oyunun sesiyle aynı hoparlörden gelir.
    case tv
    /// Bilgisayarın (ya da telefonun) hoparlörü ya da kulaklığı.
    case computer
}

/// Dublajın sesi (Windows DubbingEngine ile aynı): Pocket TTS'in doğal sesleri ya da cihazın kendi Türkçe sesi.
public enum DubbingEngine: String, Codable, CaseIterable, Sendable {
    /// İndirilen doğal sesler (Pocket TTS Turkish).
    case natural
    /// Cihazın kendi Türkçe sesi (`SystemSpeech`): indirme yok, anında konuşur, daha mekanik.
    case fast
}

public struct DubbingSettings: Codable, Equatable {
    public var enabled = false
    public var output = DubbingOutput.tv
    public var cast = VoiceCast()
    /// "Ses: Doğal / Hızlı". Eski kayıtlarda yoktur; doğal sesle açılır (Windows ile aynı).
    public var engine = DubbingEngine.natural

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DubbingSettings()
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        output = (try? values.decodeIfPresent(DubbingOutput.self, forKey: .output)) ?? defaults.output
        cast = (try? values.decodeIfPresent(VoiceCast.self, forKey: .cast)) ?? defaults.cast
        engine = (try? values.decodeIfPresent(DubbingEngine.self, forKey: .engine)) ?? defaults.engine
    }
}

extension UserSettings {
    /// "Ekran yazılarını otomatik çevir" bir kerelik göçü (Windows AutoScreenTextMigration, Android aynı kural): göç
    /// işareti olmayan kayıtta ayar kapatılır, işaret konur. Dönüş true ise ayar açıktı (beta.63 varsayılanı); kullanıcıya
    /// bir kez "deneysel; Ayarlar'dan açabilirsiniz" bilgisi gösterilir.
    @discardableResult
    public mutating func migratingAutoScreenText() -> Bool {
        guard !autoScreenTextReset else { return false }
        let wasOn = autoScreenText
        autoScreenText = false
        autoScreenTextReset = true
        return wasOn
    }

    /// Hazır alanlar ("Bilinen oyunlarda hazır alanları kullan") ve "GTA 6 telefonunu otomatik çevir" bir kerelik göçü
    /// (Windows ScreenTextExtrasMigration, Android aynı kural). `migratingAutoScreenText()`'ten sonra çağrılır. Hazır
    /// alanlar beta.63–68'de varsayılan açık geliyordu ve otomatik ekran yazısı kapalıyken de GTA 6'da menüyü ve
    /// bildirimleri çeviriyordu. İşaret yoksa: otomatik ekran yazısı kapalıysa ikisi de kapatılır; kullanıcı otomatik ekran
    /// yazısını açmışsa dokunulmaz. Sonra işaret konur; kullanıcı ikisini bilerek yeniden açabilir. Dönüş: ayar değişti.
    @discardableResult
    public mutating func migratingScreenTextExtras() -> Bool {
        guard !screenTextExtrasReset else { return false }
        screenTextExtrasReset = true
        guard !autoScreenText else { return false }
        let changed = gameAreaPresets || autoReadGamePhone
        gameAreaPresets = false
        autoReadGamePhone = false
        return changed
    }
}

extension SubtitlePipeline {
    /// Ayarlardaki iki bekleme süresini hatta uygular (Windows AppController.ApplyWaits ile aynı sınırlar: 0–2 sn).
    /// Hat yeniden kurulmaz; bekleyen satır yeni süreyle sınanır.
    public func applyWaits(from settings: UserSettings) {
        packWait = min(max(settings.misreadWaitMs, 0), UserSettings.maxWaitMs)
        cleanWait = min(max(settings.partialWaitMs, 0), UserSettings.maxWaitMs)
    }
}

/// Kısayol seçimini okur; okunamıyorsa (bilinmeyen iş, bozuk kayıt) nil, liste bozulmaz.
private struct LossyHotkeyChoice: Decodable {
    let choice: HotkeyChoice?
    init(from decoder: Decoder) throws { choice = try? HotkeyChoice(from: decoder) }
}
