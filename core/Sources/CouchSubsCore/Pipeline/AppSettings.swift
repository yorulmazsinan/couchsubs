// SPDX-License-Identifier: AGPL-3.0-only
// Mac ve iPhone/iPad uygulamalarının ortak ayarları ve kalıcı kayıt (Anahtarlık) arayüzü.

import Foundation

public enum StoreKey {
    public static let accountId = "accountId"
    public static let console = "console"
    public static let tv = "tv"
    public static let tvKey = "tvKey"
    public static let tvDevKey = "tvDevKey"
    /// Samsung ve Android TV'ye CouchSubs'ın kurduğu sürüm (LG'de sürüm TV'den okunur).
    public static let tvAppVersion = "tvAppVersion"
    /// LG geliştirici modu süresinin son uzatıldığı an.
    public static let devSessionRenewed = "devSessionRenewed"
    public static let settings = "settings"
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

/// Altyazının gösterileceği yer (Windows'taki `SubtitleOutput` ile aynı).
public enum SubtitleOutput: String, Codable, CaseIterable {
    case tv, computer, both

    public var showsOnTV: Bool { self != .computer }
    public var showsOnComputer: Bool { self != .tv }
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
    public var openAIModel = AIProvider.openAI.defaultModel.id
    public var claudeModel = AIProvider.claude.defaultModel.id
    /// Yerel model sunucusunun adresi (Ollama: http://localhost:11434/v1, LM Studio: http://localhost:1234/v1) ve
    /// kullanıcının yazdığı model adı.
    public var localAIBaseURL = LocalAIServer.ollamaURL
    public var localAIModel = LocalAIServer.defaultModel
    /// Altyazı TV'de mi, bilgisayar ekranındaki pencerede mi, ikisinde de mi. Eski kayıtlar TV ile açılır.
    public var output = SubtitleOutput.tv
    /// Bilgisayar ekranındaki altyazı penceresi tıklamaları alttaki pencereye (oyun, PS Remote Play) geçirir.
    public var overlayClickThrough = false
    /// Oyun paketlerindeki hazır Türkçe çeviriler kullanılır (yalnız İngilizce→Türkçe).
    public var gamePacks = true
    /// Pakette bulunmayan İngilizce satırlar ortak havuza gönderilir (anonim; bkz. `LinePool`).
    public var sharePool = LinePool.enabledByDefault
    /// Koyu, açık ya da sistemle aynı. Eski kayıtlarda yoktur; onlar da koyu açılır.
    public var appearance = AppAppearance.dark

    public init() {}

    /// Yeni eklenen ayarlar eski kayıtta yoktur; varsayılanla açılır, eski ayarlar kaybolmaz.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UserSettings()
        region = try values.decodeIfPresent(CropRegion.self, forKey: .region) ?? defaults.region
        areaPreset = (try? values.decodeIfPresent(AreaPreset.self, forKey: .areaPreset)) ?? AreaPreset.matching(region)
        style = try values.decodeIfPresent(SubtitleStyle.self, forKey: .style) ?? defaults.style
        sourceLanguage = try values.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? defaults.sourceLanguage
        targetLanguage = try values.decodeIfPresent(String.self, forKey: .targetLanguage) ?? defaults.targetLanguage
        dubbing = (try? values.decodeIfPresent(DubbingSettings.self, forKey: .dubbing)) ?? defaults.dubbing
        onlineTranslation = try values.decodeIfPresent(Bool.self, forKey: .onlineTranslation) ?? defaults.onlineTranslation
        let engine = (try? values.decodeIfPresent(TranslationEngine.self, forKey: .onlineEngine)) ?? defaults.onlineEngine
        onlineEngine = engine == .free ? defaults.onlineEngine : engine
        geminiModel = try values.decodeIfPresent(String.self, forKey: .geminiModel) ?? defaults.geminiModel
        openAIModel = try values.decodeIfPresent(String.self, forKey: .openAIModel) ?? defaults.openAIModel
        claudeModel = try values.decodeIfPresent(String.self, forKey: .claudeModel) ?? defaults.claudeModel
        localAIBaseURL = try values.decodeIfPresent(String.self, forKey: .localAIBaseURL) ?? defaults.localAIBaseURL
        localAIModel = try values.decodeIfPresent(String.self, forKey: .localAIModel) ?? defaults.localAIModel
        output = (try? values.decodeIfPresent(SubtitleOutput.self, forKey: .output)) ?? defaults.output
        overlayClickThrough = try values.decodeIfPresent(Bool.self, forKey: .overlayClickThrough) ?? defaults.overlayClickThrough
        gamePacks = try values.decodeIfPresent(Bool.self, forKey: .gamePacks) ?? defaults.gamePacks
        sharePool = try values.decodeIfPresent(Bool.self, forKey: .sharePool) ?? defaults.sharePool
        appearance = (try? values.decodeIfPresent(AppAppearance.self, forKey: .appearance)) ?? defaults.appearance
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

public struct DubbingSettings: Codable, Equatable {
    public var enabled = false
    public var output = DubbingOutput.tv
    public var cast = VoiceCast()

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DubbingSettings()
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        output = (try? values.decodeIfPresent(DubbingOutput.self, forKey: .output)) ?? defaults.output
        cast = (try? values.decodeIfPresent(VoiceCast.self, forKey: .cast)) ?? defaults.cast
    }
}
