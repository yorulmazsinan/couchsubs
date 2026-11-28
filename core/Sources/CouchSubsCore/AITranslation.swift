// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

/// Kullanıcının kendi anahtarıyla çalışan yapay zekâ çeviri hizmetleri (Windows'taki CouchSubs.Core/AiProvider.cs ile aynı).
/// `local`: kullanıcının bilgisayarında çalışan model (Ollama, LM Studio); OpenAI uyumlu Chat Completions adresine gider,
/// anahtar isteğe bağlıdır, model adını kullanıcı yazar.
public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case gemini
    case openAI = "openai"
    case claude
    case local

    /// Bulut hizmetleri: model listesi `ai-models.json`'dan gelir, anahtar gerekir.
    public static var cloud: [AIProvider] { allCases.filter { !$0.isLocal } }

    /// Kullanıcının bilgisayarındaki model (Ollama, LM Studio).
    public var isLocal: Bool { self == .local }

    /// Seçilebilen modeller; ilki varsayılandır (hızlı ve ucuz). Liste Windows ile ortak `ai-models.json` dosyasından gelir.
    /// Yerel modelde liste yoktur; model adını kullanıcı yazar.
    public var models: [AIModel] { AIModel.catalog[rawValue] ?? [] }

    /// Hızlı ve ucuz varsayılan model.
    public var defaultModel: AIModel {
        isLocal ? AIModel(id: LocalAIServer.defaultModel, label: LocalAIServer.defaultModel) : models[0]
    }

    /// Marka adı; çevrilmez. Yerel modelin arayüzdeki adı uygulamada çevrilir.
    public var displayName: String {
        switch self {
        case .gemini: "Gemini"
        case .openAI: "OpenAI"
        case .claude: "Claude"
        case .local: "Local model"
        }
    }

    /// Anahtarın alındığı resmî sayfa (yerel modelde Ollama'nın indirme sayfası).
    public var keyPage: URL {
        switch self {
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .claude: URL(string: "https://platform.claude.com/settings/keys")!
        case .local: URL(string: "https://ollama.com/download")!
        }
    }

    /// Kalıcı önbellek dosyasındaki motor adı: model değişince eski modelin çevirileri karışmaz. Yerel modelde sunucu
    /// adresi de girer (bkz. `LocalAIServer.engineID`).
    public func engineID(model: String) -> String { "\(rawValue):\(model)" }

    /// Kayıtlı model listede yoksa (eski ayar ya da listeden çıkarılan model) varsayılan model. Yerel modelde kullanıcının
    /// yazdığı ad olduğu gibi kullanılır (boşsa varsayılan).
    public func model(_ id: String?) -> AIModel {
        if isLocal {
            let name = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? defaultModel : AIModel(id: name, label: name)
        }
        return models.first { $0.id == id } ?? defaultModel
    }

    /// Ücretsiz anahtarla kullanılabilen bir modeli var mı (bugün yalnız Gemini).
    public var hasFreeTier: Bool { models.contains(where: \.freeTier) }
}

/// Listedeki bir model ve onunla gönderilen ayarlar. Kullanıcı model adı yazamaz; yalnız bu listeden seçer.
public struct AIModel: Codable, Equatable, Sendable {
    public var id: String
    /// Ayarlarda görünen ad (Localizable.xcstrings anahtarı).
    public var label: String
    /// OpenAI'da `reasoning_effort`, Claude'da `output_config.effort`; nil ise gönderilmez.
    public var effort: String?
    /// Gemini'de `thinkingConfig.thinkingLevel`, Claude'da `thinking.type`; nil ise gönderilmez.
    public var thinking: String?
    /// Ücretsiz anahtarla (faturası bağlanmamış Google projesi) kullanılabilir mi: Kasım 2026'da
    /// aistudio.google.com/docs/pricing sayfasında "Free Tier: Free of charge" yazan modeller.
    public var freeTier: Bool
    /// Dakikada en çok bu kadar istek gönderilir; hak bitince o satır yerel çeviriyle çevrilir. nil ise sınır yok.
    /// Google ücretsiz katmanın model başına sayılarını belgelerde yazmıyor (aistudio.google.com/docs/rate-limits:
    /// "Rate limits are applied per project, not per API key"; sayılar yalnız aistudio.google.com/rate-limit'te).
    /// Değer temkinli seçildi; hizmet 429 ile daha düşük sınır bildirirse o sınıra inilir.
    public var requestsPerMinute: Int?

    public init(id: String, label: String, effort: String? = nil, thinking: String? = nil, freeTier: Bool = false,
                requestsPerMinute: Int? = nil) {
        self.id = id
        self.label = label
        self.effort = effort
        self.thinking = thinking
        self.freeTier = freeTier
        self.requestsPerMinute = requestsPerMinute
    }

    /// Yeni alanlar eksikse varsayılanla okunur.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        effort = try values.decodeIfPresent(String.self, forKey: .effort)
        thinking = try values.decodeIfPresent(String.self, forKey: .thinking)
        freeTier = try values.decodeIfPresent(Bool.self, forKey: .freeTier) ?? false
        requestsPerMinute = try values.decodeIfPresent(Int.self, forKey: .requestsPerMinute)
    }

    /// `ai-models.json`: hizmet adı → modeller.
    static let catalog: [String: [AIModel]] = {
        guard let url = Bundle.module.url(forResource: "ai-models", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return parse(data)
    }()

    /// "_comment" gibi dizi olmayan alanlar atlanır.
    static func parse(_ data: Data) -> [String: [AIModel]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: [AIModel]] = [:]
        for (key, value) in root {
            guard let list = value as? [Any], let json = try? JSONSerialization.data(withJSONObject: list),
                  let models = try? JSONDecoder().decode([AIModel].self, from: json), !models.isEmpty else { continue }
            result[key] = models
        }
        return result
    }
}

/// Kullanıcının bilgisayarındaki (ya da ağındaki) OpenAI uyumlu model sunucusu: Ollama, LM Studio (Windows'taki
/// `LocalAiServer` ile aynı). Adres "http://127.0.0.1:11434/v1" gibi `/v1` ile biten temel adrestir.
public struct LocalAIServer: Equatable, Sendable {
    /// Ollama'nın OpenAI uyumlu adresi (docs.ollama.com/api/openai-compatibility). "localhost" değil: Windows'ta
    /// localhost önce IPv6'ya (::1) gider, Ollama yalnız IPv4'te dinlediği için istek başına ~2 sn kaybolur (#295).
    public static let ollamaURL = "http://127.0.0.1:11434/v1"
    /// LM Studio'nun yerel sunucusu (lmstudio.ai/docs/app/api/endpoints/openai).
    public static let lmStudioURL = "http://localhost:1234/v1"
    /// Türkçeyi iyi bilen, sıradan bir bilgisayarda çalışan model.
    public static let defaultModel = "qwen2.5:7b"

    /// Sondaki "/" atılmış temel adres.
    public let baseURL: URL
    public let model: String

    /// Adres ya da model geçersizse nil. "localhost:11434" gibi şemasız adrese "http://" eklenir; yolsuz adrese "/v1"
    /// eklenir; sona yapıştırılmış "/chat/completions" atılır.
    public init?(baseURL: String, model: String) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let url = Self.normalize(baseURL) else { return nil }
        self.baseURL = url
        self.model = model
    }

    /// Kullanıcının yazdığı adresin düzeltilmiş hali; geçersizse nil.
    public static func normalize(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/chat/completions") { text.removeLast("/chat/completions".count) }
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        if components.path.isEmpty { components.path = "/v1" }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// İsteğin gittiği adres. Kullanıcı "localhost" yazdıysa istek 127.0.0.1'e gider (IPv6 gecikmesi, #295); başka
    /// adrese dokunulmaz.
    public var chatURL: URL { Self.preferIPv4(baseURL).appendingPathComponent("chat/completions") }

    /// "localhost" adını 127.0.0.1 yapar; başka adresi olduğu gibi bırakır.
    public static func preferIPv4(_ url: URL) -> URL {
        guard url.host?.lowercased() == "localhost",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.host = "127.0.0.1"
        return components.url ?? url
    }

    /// Ollama'da düşünme kapatılır: Gemma, Qwen3 gibi düşünen modeller altyazı çevirisinde boşuna yavaşlar (#295).
    public var disablesThinking: Bool { kind == .ollama }

    /// Kullanıcıya gösterilen kısa adres: "http://localhost:11434".
    public var address: String {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        return components.string ?? baseURL.absoluteString
    }

    /// Sunucunun türü; adresin kapısından tahmin edilir (hata iletisinde doğru yönerge için).
    public enum Kind: Equatable, Sendable { case ollama, lmStudio, other }

    public var kind: Kind {
        switch baseURL.port {
        case 11434: .ollama
        case 1234: .lmStudio
        default: .other
        }
    }

    /// Önbellekteki motor adı sunucu adresini ve modeli içerir; farklı yerel uç noktaların çevirileri karışmaz.
    public var engineID: String {
        let scheme = baseURL.scheme?.lowercased() ?? ""
        let host = baseURL.host?.lowercased() ?? ""
        let port = baseURL.port.map { String($0) } ?? ""
        let path = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? baseURL.path

        // Standart HTTP /v1 adresinin mevcut önbellek anahtarını koru.
        if scheme == "http", path == "/v1" {
            let legacyPort = baseURL.port.map { ":\($0)" } ?? ""
            return "\(AIProvider.local.rawValue):\(host)\(legacyPort)/\(model)"
        }

        // Alan uzunlukları yol ve model ayraçlarının yeni bir önbellek çakışması oluşturmasını engeller.
        let endpoint = [scheme, host, port, path, model]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        return "\(AIProvider.local.rawValue):endpoint-v2:\(endpoint)"
    }
}

/// Yapay zekâ hizmeti neden çeviremedi. Hata yalnız durum taşır: anahtar ve hizmetin yanıt metni hiçbir yere yazılmaz.
public enum AIFailure: Error, Equatable, Sendable {
    /// Anahtar reddedildi (401/403 ya da Gemini'de "API key not valid").
    case invalidKey
    /// Bakiye bitti ya da günlük/aylık sınır aşıldı (429, 402, Claude'da "credit balance").
    case quotaExceeded
    /// Hizmet isteği kabul etmedi (400, 404); ör. listedeki model hesapta açık değil.
    case modelRejected
    /// Ağ hatası (bağlantı kurulamadı) ya da anlaşılmayan yanıt.
    case unreachable
    /// Hizmete ulaşıldı ama şu an yoğun (5xx, Gemini 503 "overloaded", Claude 529), yanıt zamanında gelmedi ya da
    /// "Dene" dakikalık sınıra takıldı. Anahtar reddedilmedi, internet de çalışıyor.
    case busy
    /// Test sonucu ne olursa olsun API anahtarı cihazın Anahtar Zinciri'ne kaydedilemedi.
    case keychainWriteFailed
}

/// Hizmetin bildirdiği dakikalık istek sınırı aşımı (429). Gün sınırından farklı olarak kısa sürer; kullanıcıya hata
/// gösterilmez, birkaç saniye o satırlar yerel çeviriyle çevrilir.
public struct AIRateLimit: Equatable, Sendable {
    /// Hizmetin önerdiği bekleme ("retryDelay"); yoksa nil.
    public var retryAfter: TimeInterval?
    /// Hizmetin bildirdiği dakikalık istek sınırı ("quotaValue"); yoksa nil.
    public var requestsPerMinute: Int?

    public init(retryAfter: TimeInterval? = nil, requestsPerMinute: Int? = nil) {
        self.retryAfter = retryAfter
        self.requestsPerMinute = requestsPerMinute
    }
}

/// Hizmet dakikalık sınırın aşıldığını bildirdi; kullanıcıya hata olarak gösterilmez.
struct AIRateLimited: Error {
    let limit: AIRateLimit
}

/// Bağlam olarak giden, daha önce gösterilmiş satır ve (biliniyorsa) çevirisi.
public struct AIContextLine: Equatable, Sendable {
    public var source: String
    public var translation: String?

    public init(source: String, translation: String? = nil) {
        self.source = source
        self.translation = translation
    }
}

/// Üç hizmet için istek kurma ve yanıt okuma. Cümleler bir JSON dizisi olarak gider, aynı sırada JSON dizisi beklenir;
/// böylece cümle cümle önbelleğe yazılır ve dublaj konuşmacıyı bilir (DeepL ile aynı düzen).
public enum AIRequest {
    /// Bir altyazı satırına yeten çıktı sınırı; düşünen modellere de pay bırakır.
    public static let maxOutputTokens = 1024
    /// "Ekranı çevir"in tek isteğinde çıktı sınırı: ekrandaki bütün yazılar birlikte döner.
    public static let screenOutputTokens = 8192

    public static let systemPrompt = """
        You translate English video game subtitles into natural, spoken Turkish, the way people really talk. \
        Characters address each other informally (use "sen", not "siz") unless the line is clearly formal. \
        Keep character names, place names and speaker labels such as "ATREUS:" exactly as they are. \
        Keep line breaks. Keep the meaning and tone; do not add or leave out anything. \
        The text is read from the screen by OCR and may have misread or missing letters ("Y u ave to ask?", \
        "Doesn't 00k good."); translate the line the speaker clearly meant. \
        A subtitle may continue the previous one (it starts in lowercase or with a word like "and"); \
        translate it so that it reads as that continuation. \
        Short menu items, objectives and button labels without a subject ("Make Money", "Find Donnie's Package") \
        are commands to the player: translate them as short singular informal imperatives ("Para Kazan", \
        "Donnie'nin Paketini Bul"), never polite or plural forms such as "Para Kazanın". \
        Reply with only the translation, no explanations, notes or quotes.
        """

    /// Kullanıcının ek talimatında en çok bu kadar karakter gider (fazlası kesilir).
    public static let maxInstructionLength = 1000

    /// Ayarlardaki "Ek talimat": baştaki/sondaki boşluk atılır, sınırdan uzunsa kesilir; boşsa nil.
    public static func instruction(_ text: String?) -> String? {
        var trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maxInstructionLength {
            trimmed = String(trimmed.prefix(maxInstructionLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Sistem talimatı: kullanıcının ek talimatı varsa sona eklenir (#306; ör. küfrü yumuşatmadan çevir). Boşsa
    /// `systemPrompt` olduğu gibi gider.
    public static func systemPromptWith(_ instruction: String?) -> String {
        guard let extra = self.instruction(instruction) else { return systemPrompt }
        return systemPrompt + "\n\n" + extra
    }

    /// Ek talimatın önbellek etiketi: talimat değişince eski çeviriler dönmesin diye anahtarın başına girer. Talimat
    /// yoksa nil; o zaman anahtar eskisi gibidir ve önceki çeviriler geçerli kalır (Windows ve Android ile aynı).
    public static func instructionTag(_ instruction: String?) -> String? {
        guard let extra = self.instruction(instruction) else { return nil }
        return String(SHA256.hash(data: Data(extra.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Kullanıcı iletisi: önceki satırlar (yalnız bağlam) ve çevrilecek cümleler. `names`: konuşan etiketlerinden
    /// öğrenilip cümlelerde geçen adlar; model "Price"ı "Fiyat" diye çevirmesin diye adıyla söylenir (#287).
    /// Ekran çevirisinde her yazının en çok karakter sayısı: özgün uzunluğun %15 fazlası (en az 4). Türkçe çoğu zaman
    /// İngilizceden uzundur; çeviri özgün yazının yerine, aynı boyda sığsın diye kısa söyleyiş istenir (Windows ve Android
    /// ile aynı).
    public static func screenLimits(_ sentences: [String]) -> [Int] {
        sentences.map { max(4, Int((Double($0.count) * 1.15).rounded(.up))) }
    }

    /// Ekran çevirisinin günlüğe yazılacak sorunu (`DropLog`): boş döndü, aslıyla aynı döndü (İngilizce kaldı) ya da
    /// `screenLimits` sınırını aştı. Sorun yoksa nil. Windows (AiRequest.ScreenIssue) ve Android (AiRequest.screenIssue) aynı.
    public static func screenIssue(source: String, translation: String, limit: Int) -> String? {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "motor boş çeviri döndü" }
        if trimmed.lowercased() == source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           source.contains(where: \.isLetter) {
            return "çeviri aslıyla aynı döndü, İngilizce kaldı"
        }
        if trimmed.count > limit { return "%115 sınırını aştı (\(trimmed.count)/\(limit))" }
        return nil
    }

    /// Karakter sınırlarının istemdeki açıklaması (küfür kuralı: sansür ve yumuşatma yok).
    public static let limitsNote = "On-screen texts (menus, objectives, labels): each Turkish translation must fit in the place of the English text. Use at most the number of characters given for it in this JSON array, in the same order; choose shorter Turkish wording, but keep the meaning and never censor or soften profanity."

    public static func userMessage(sentences: [String], context: [AIContextLine], game: String? = nil,
                                   names: [String] = [], limits: [Int]? = nil) -> String {
        var parts: [String] = []
        if let game, !game.isEmpty { parts.append("Game: \(game)") }
        if !names.isEmpty {
            parts.append("Character names (keep them exactly as written, do not translate them): \(names.joined(separator: ", "))")
        }
        if !context.isEmpty {
            var lines = ["Previous subtitles, for context only (do not translate them again):"]
            for line in context {
                lines.append("English: \(line.source)")
                if let translation = line.translation { lines.append("Turkish: \(translation)") }
            }
            parts.append(lines.joined(separator: "\n"))
        }
        if let limits, limits.count == sentences.count {
            parts.append(limitsNote + "\n[" + limits.map(String.init).joined(separator: ",") + "]")
        }
        let list = (try? JSONSerialization.data(withJSONObject: sentences, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        parts.append("Translate each string in this JSON array into Turkish. Reply with only a JSON array of \(sentences.count) "
            + "Turkish strings in the same order.\n\(list)")
        return parts.joined(separator: "\n\n")
    }

    /// Yerel modelin sıcaklığı: 0, aynı satır her seferinde aynı çevrilir (#306).
    public static let localTemperature = 0.0

    /// Ollama modeli son istekten sonra bu kadar bellekte tutar (varsayılan 5 dk). Oyunda uzun süre altyazı çıkmayınca
    /// model bellekten atılıyor, ilk satır modelin diskten yeniden yüklenmesini bekliyordu (#306).
    public static let ollamaKeepAlive = "24h"

    /// Hizmete giden HTTP isteği. `server`: yerel modelin sunucusu (verilmezse Ollama'nın varsayılan adresi).
    /// `thinkingOff`: Ollama'da düşünmeyi kapatan alanlar gitsin mi (bu alanları reddeden eski sürümde false).
    /// `instruction`: Ayarlardaki "Ek talimat"; sistem talimatının sonuna eklenir, boşsa hiçbir şey değişmez.
    public static func make(provider: AIProvider, key: String, model: AIModel, sentences: [String],
                            context: [AIContextLine], game: String? = nil, server: LocalAIServer? = nil,
                            maxOutputTokens: Int = AIRequest.maxOutputTokens, thinkingOff: Bool = true,
                            names: [String] = [], instruction: String? = nil, limits: [Int]? = nil) -> URLRequest {
        let key = DeepLKey.clean(key)
        let user = userMessage(sentences: sentences, context: context, game: game, names: names, limits: limits)
        let system = systemPromptWith(instruction)
        var request: URLRequest
        var body: [String: Any]
        switch provider {
        case .gemini:
            // https://ai.google.dev/api/generate-content (aistudio.google.com/api-reference/generate-content):
            // POST /v1beta/models/{model}:generateContent, anahtar "x-goog-api-key" başlığında.
            // Gemini 3.6 Flash ve sonrası temperature'ı yok sayıyor; düşünme düzeyi listedeki modelle gelir.
            let escaped = model.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model.id
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escaped):generateContent")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            var config: [String: Any] = ["maxOutputTokens": maxOutputTokens]
            if let thinking = model.thinking { config["thinkingConfig"] = ["thinkingLevel": thinking] }
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": user]]]],
                "generationConfig": config,
            ]
        case .openAI:
            // https://platform.openai.com/docs/api-reference/chat/create (developers.openai.com/api/reference):
            // POST /v1/chat/completions, "Authorization: Bearer"; "developer" iletisi yönergedir.
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model.id,
                "messages": [["role": "developer", "content": system], ["role": "user", "content": user]],
                "max_completion_tokens": maxOutputTokens,
            ]
            if let effort = model.effort { body["reasoning_effort"] = effort }
        case .claude:
            // https://docs.anthropic.com/en/api/messages (platform.claude.com/docs/en/api/messages): POST /v1/messages,
            // "x-api-key" ve "anthropic-version". Yeni modellerde temperature gönderilmez; effort ve düşünme listedeki
            // modelle gelir (platform.claude.com/docs/en/build-with-claude/effort).
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model.id,
                "max_tokens": maxOutputTokens,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
            if let effort = model.effort { body["output_config"] = ["effort": effort] }
            if let thinking = model.thinking { body["thinking"] = ["type": thinking] }
        case .local:
            // Ollama ve LM Studio'nun OpenAI uyumlu Chat Completions'ı: POST {adres}/chat/completions. Yalnız iki
            // sunucunun da tanıdığı alanlar gider ("developer" rolü, reasoning_effort, max_completion_tokens gitmez).
            // Anahtar isteğe bağlıdır; boşsa Authorization başlığı hiç eklenmez.
            let server = server ?? LocalAIServer(baseURL: LocalAIServer.ollamaURL, model: model.id)!
            request = URLRequest(url: server.chatURL)
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = [
                "model": model.id,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                "temperature": localTemperature,
                "max_tokens": maxOutputTokens,
                "stream": false,
            ]
            // Ollama'da düşünme kapalı (#295): yerel API "think": false okur, OpenAI uyumlu adres ise
            // reasoning_effort "none" (github.com/ollama/ollama openai/openai.go). Eski sürüm 400 verirse çevirmen
            // alanlarsız yeniden dener ve bunu oturum boyunca hatırlar.
            if thinkingOff, server.disablesThinking {
                body["think"] = false
                body["reasoning_effort"] = "none"
            }
            // Ollama'nın OpenAI uyumlu adresi keep_alive'ı okur ("Ollama extension", github.com/ollama/ollama
            // openai/openai.go ChatCompletionRequest.KeepAlive); bu alanı bilmeyen eski sürüm bilinmeyen alanı yok
            // sayar. Yalnız Ollama'ya gider: LM Studio ve başka sunucular bu alanı tanımaz (#306).
            if server.kind == .ollama { body["keep_alive"] = ollamaKeepAlive }
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Yanıttaki düz metin (düşünme bölümleri atlanır).
    public static func text(provider: AIProvider, from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIFailure.unreachable }
        let text: String?
        switch provider {
        case .gemini:
            // candidates[0].content.parts[].text; "thought": true olan parçalar düşünmedir.
            let candidate = (root["candidates"] as? [[String: Any]])?.first
            let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        case .openAI, .local:
            let message = ((root["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any]
            text = message?["content"] as? String
        case .claude:
            let blocks = root["content"] as? [[String: Any]] ?? []
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIFailure.unreachable }
        return text
    }

    /// Yanıttaki JSON dizisi; tek cümlede model diziyi unutup düz metin dönerse o metin alınır.
    public static func translations(from text: String, count: Int) throws -> [String] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Düşünen yerel modeller (ör. Qwen3, DeepSeek-R1) yanıtın başına <think>…</think> koyar; yalnız sonrası alınır.
        if let end = trimmed.range(of: "</think>", options: .backwards) {
            trimmed = String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        trimmed = stripControlTokens(trimmed)
        // ```json … ``` çitini at.
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .filter { !$0.hasPrefix("```") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]"), start < end,
           let data = withoutTrailingComma(String(trimmed[start...end])).data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [String] {
            guard list.count == count else { throw AIFailure.unreachable }
            return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let list = unquotedList(trimmed, count: count) { return list }
        guard count == 1 else { throw AIFailure.unreachable }
        return [trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))]
    }

    /// Yerel modellerin metne sızan bitiş/rol işaretleri (`</s>`, `<|im_end|>`, `<|eot_id|>`, `<end_of_turn>` …)
    /// ekranda görünmesin; yalnız bu kalıplar silinir, altyazıdaki başka `<…>` yazılara dokunulmaz.
    static func stripControlTokens(_ text: String) -> String {
        text.replacingOccurrences(of: #"</?s>|<\|[A-Za-z0-9_]{1,32}\|>|</?(?:start|end)_of_turn>|</?(?:eos|bos|pad)>"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `["Bir.", "İki.",]` gibi sondaki fazla virgül JSON'u bozmasın.
    static func withoutTrailingComma(_ text: String) -> String {
        text.replacingOccurrences(of: #",\s*\]$"#, with: "]", options: .regularExpression)
    }

    /// Tırnaksız dizi: bazı yerel modeller JSON istense de `[Hareket etmemiz lazım.]` ya da `[Satır bir., Satır iki.]`
    /// döndürür. Yalnız bütün yanıt köşeli parantez içindeyse ve öğe sayısı tam tutuyorsa alınır; tutmazsa nil (hat
    /// her zamanki geri dönüşe gider). Cümle içi virgülde yanlış bölmemek için sıra: satır sonu, cümle sonu işaretinden
    /// (. ! ? … ") sonra gelen virgül, en son düz virgül.
    static func unquotedList(_ text: String, count: Int) -> [String]? {
        guard count >= 1, text.count >= 2, text.hasPrefix("["), text.hasSuffix("]") else { return nil }
        let inner = String(text.dropFirst().dropLast())
        func clean(_ item: Substring) -> String {
            var value = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix(",") { value.removeLast() }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let candidates: [[Substring]] = count == 1 ? [[Substring(inner)]] : [
            inner.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            sentenceSplit(inner),
            inner.split(separator: ",", omittingEmptySubsequences: false),
        ]
        for parts in candidates {
            let items = parts.map(clean)
            if items.count == count, !items.contains(where: \.isEmpty) { return items }
        }
        return nil
    }

    /// Cümle sonu işaretinden (. ! ? … " ”) hemen sonra gelen virgüllerden böler; işaret öğede kalır.
    private static func sentenceSplit(_ text: String) -> [Substring] {
        let ends: Set<Character> = [".", "!", "?", "…", "\"", "”"]
        var parts: [Substring] = []
        var start = text.startIndex
        var last: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == ",", let last, ends.contains(last) {
                parts.append(text[start..<index])
                start = text.index(after: index)
            }
            if !character.isWhitespace { last = character }
            index = text.index(after: index)
        }
        parts.append(text[start...])
        return parts
    }

    /// Başarısız HTTP yanıtının anlamı. Gövde yalnız tanınan hata kodları için okunur, hiçbir yere yazılmaz.
    private static func isTemporaryProviderRateLimit(_ body: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return false }
        let code = (error["code"] as? String)?.lowercased()
        let detailCode = ((error["details"] as? [String: Any])?["error_code"] as? String)?.lowercased()
        let type = (error["type"] as? String)?.lowercased()
        let billingCodes: Set<String> = ["insufficient_quota", "billing_hard_limit_reached", "credit_balance_exhausted",
                                         "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
                                         "organization_usage_limit_exceeded", "enforced_spend_limit_reached"]
        if [code, detailCode].compactMap({ $0 }).contains(where: billingCodes.contains) {
            return false
        }
        return type == "rate_limit_error" || code == "slow_down" || code == "rate_limit_exceeded"
    }

    public static func failure(status: Int, body: Data) -> AIFailure {
        let message = String(data: body, encoding: .utf8)?.lowercased() ?? ""
        switch status {
        case 401, 403: return .invalidKey
        case 429 where isTemporaryProviderRateLimit(body): return .busy
        case 402, 429: return .quotaExceeded
        case 400:
            if message.contains("api_key_invalid") || message.contains("api key not valid") { return .invalidKey }
            if message.contains("credit balance") || message.contains("insufficient_quota") { return .quotaExceeded }
            return .modelRejected
        case 404: return .modelRejected
        // Hizmete ulaşıldı ama şu an yoğun ya da arızalı; internet çalışıyor.
        case 408, 500...599: return .busy
        default: return .unreachable
        }
    }

    /// 429 yalnız dakikalık sınırdan geldiyse onun ayrıntısı; gün sınırı, bakiye ya da tanınmayan 429 için nil (bunlar
    /// `quotaExceeded` olarak kullanıcıya gösterilir). OpenAI'nin `rate_limit_error`/`slow_down` yanıtları kısa bekleme
    /// olarak ele alınır. Gemini'nin hata gövdesinde error.details[] içinde
    /// google.rpc.QuotaFailure (violations[].quotaId, ör. "GenerateRequestsPerMinutePerProjectPerModel-FreeTier",
    /// quotaValue "15") ve google.rpc.RetryInfo (retryDelay "37s") bulunur.
    public static func rateLimit(status: Int, body: Data) -> AIRateLimit? {
        guard status == 429 else { return nil }
        if isTemporaryProviderRateLimit(body) { return AIRateLimit() }
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let details = (root["error"] as? [String: Any])?["details"] as? [[String: Any]] else { return nil }
        let violations = details.flatMap { $0["violations"] as? [[String: Any]] ?? [] }
        let ids = violations.compactMap { $0["quotaId"] as? String }
        // Günlük sınır doldu: dakikalık beklemeyle geçmez, kullanıcı bilmeli.
        guard !ids.contains(where: { $0.contains("PerDay") }), ids.contains(where: { $0.contains("PerMinute") }) else { return nil }
        var limit = AIRateLimit()
        if let delay = details.compactMap({ $0["retryDelay"] as? String }).first,
           let seconds = TimeInterval(delay.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) {
            limit.retryAfter = seconds
        }
        // İstek sınırı (token sınırı değil).
        if let requests = violations.first(where: { ($0["quotaId"] as? String)?.contains("Requests") == true }) {
            let value = requests["quotaValue"] as? String ?? (requests["quotaValue"] as? Int).map(String.init)
            if let number = value.flatMap(Int.init), number > 0 { limit.requestsPerMinute = number }
        }
        return limit
    }
}

/// Yapay zekâ çevirisinin ortak çekirdeği: önbellek, bağlam, cümle bölme, hata sonrası bekleme ve yerel çeviriye düşme.
/// Uygulamadaki `AITranslator` bunu çeviri protokolüne bağlar. Hata olursa o satır yerel (ücretsiz) motorla çevrilir ve
/// bir dakika (yerel modelde 5 sn) hizmet denenmez; her satırda zaman aşımı beklenmez. Yerel çeviriler bu motorun
/// önbelleğine yazılmaz.
/// Bir altyazının çevrilmemiş bütün cümleleri tek istekte gider. Ücretsiz katmanın dakikalık sınırı için model listesindeki
/// `requestsPerMinute` kadar istek hakkı vardır; hak bitince o satır sessizce (hata göstermeden) yerel çeviriyle çevrilir.
public final class AITranslationCore: @unchecked Sendable {
    /// Bağlama giden önceki satır sayısı.
    public static let contextLines = 3
    /// Hata sonrası bu süre hizmet denenmez (bulut hizmetlerinin kotası için).
    public static let retryAfter: TimeInterval = 60
    /// Yerel modelde hata sonrası bekleme. Kota yoktur, sunucu çoğunlukla hemen düzelir (zaman aşımı, bozuk JSON, an
    /// meşgul): tek bir hata bir dakika boyunca bütün satırları yerel çeviriye düşürmesin, yalnız birkaç satırı etkilesin.
    /// Askıda kalan sunucuda da bekleme sürer: her satır `localTimeout` kadar beklemez, sıra dolmaz.
    public static let localRetryAfter: TimeInterval = 5
    /// Dakikalık sınır aşılınca en çok bu kadar beklenir (hizmet bekleme önermezse de bu kadar).
    public static let rateLimitPause: TimeInterval = 20

    /// Hata sonrası hizmetin denenmediği süre: yerel modelde `localRetryAfter`, bulutta `retryAfter` (testler kısaltır).
    var errorPause: TimeInterval
    public let provider: AIProvider
    public let model: AIModel
    /// Yerel modelin sunucusu; bulut hizmetlerinde nil.
    public let server: LocalAIServer?
    private let key: String
    private let session: URLSession
    /// "Ekranı çevir"in uzun yanıtlı tek isteği için daha uzun bekleyen oturum.
    private let screenSession: URLSession
    private let cache: TranslationCache
    private let budget: RequestBudget?
    private let names = SpeakerNames()
    /// Ekran çevirisinin boş, aslıyla aynı ya da sınırı aşan yanıtı altyazı günlüğüne (`DropLog`).
    private let drops = DropLog()
    private let lock = NSLock()
    private var speech: [String: [SpokenLine]] = [:]
    /// Son gösterilen satırlar, eskiden yeniye.
    private var recent: [AIContextLine] = []
    private var recentGame: String?
    private var pausedUntil = Date.distantPast
    /// Bekleme hizmetin 429 yanıtından mı (dakikalık sınır); öyleyse yerel çeviri olmasa da istek gönderilmez.
    private var pauseRateLimited = false
    private var failure: AIFailure?
    private var rateLimited = false
    /// Oynanan oyunun adı (ör. paket eşleşmesinden); biliniyorsa istemde "Game:" olarak gider.
    private let game: (@Sendable () -> String?)?
    /// Ayarlardaki "Ek talimat" (sınırlanmış); yoksa nil.
    private let instruction: String?
    /// Ek talimatın önbellek etiketi; talimat yoksa nil (anahtar eskisi gibi).
    private let instructionTag: String?

    /// Son hata; çeviri düzgün gidiyorsa nil. Değiştikçe `onFailureChanged` çağrılır.
    public var lastFailure: AIFailure? { lock.withLock { failure } }
    public var onFailureChanged: ((AIFailure?) -> Void)?
    /// Son satır dakikalık sınır yüzünden yerel çeviriyle çevrildi (hata sayılmaz, bildirilmez).
    public var lastLineWasRateLimited: Bool { lock.withLock { rateLimited } }

    /// `model`: kayıtlı model kimliği; listede yoksa varsayılan model.
    /// `budget`: dakikalık istek hakkı; nil ise modelin uygulama genelindeki ortak hakkı (Google sınırı proje ve model başına
    /// sayar; çeviri hattı yeniden kurulsa da hak sıfırlanmaz). Modelin sınırı yoksa hak da yoktur.
    /// `server`: yerel modelin sunucusu (yalnız `.local`; verilmezse Ollama'nın varsayılan adresi).
    /// `session`: verilmezse hizmete uygun zaman aşımıyla kurulur (yerel model daha uzun bekler).
    /// `game`: oynanan oyunun adı; her istekte sorulur, nil ya da boşsa istemde oyun satırı olmaz.
    /// `instruction`: Ayarlardaki "Ek talimat"; sistem talimatının sonuna eklenir, boşsa hiçbir şey değişmez.
    public init(provider: AIProvider, key: String, model: String? = nil, server: LocalAIServer? = nil, session: URLSession? = nil,
                cache: TranslationCache = TranslationCache(), budget: RequestBudget? = nil, game: (@Sendable () -> String?)? = nil,
                instruction: String? = nil, paidTier: Bool = false) {
        self.provider = provider
        errorPause = provider.isLocal ? Self.localRetryAfter : Self.retryAfter
        self.game = game
        self.instruction = AIRequest.instruction(instruction)
        instructionTag = AIRequest.instructionTag(instruction)
        self.key = DeepLKey.clean(key)
        let resolved = provider.model(model)
        self.model = resolved
        self.server = provider.isLocal ? server ?? LocalAIServer(baseURL: LocalAIServer.ollamaURL, model: resolved.id) : nil
        self.session = session ?? Self.makeSession(provider: provider)
        screenSession = session ?? Self.makeSession(timeout: provider.isLocal ? Self.localTestTimeout : Self.screenTimeout)
        self.cache = cache
        self.budget = budget ?? RequestBudget.shared(provider: provider, model: resolved, apiKey: self.key, paidTier: paidTier)
    }

    /// Bulut hizmetinde beklenen en uzun süre.
    public static let timeout: TimeInterval = 5
    /// "Ekranı çevir"de bulut hizmetinde beklenen en uzun süre: bütün ekranın çevirisi tek yanıtta gelir.
    public static let screenTimeout: TimeInterval = 30
    /// Bir istekte giden en çok parça; kalabalık ekran birkaç isteğe bölünür.
    public static let screenBatch = 40
    /// Yerel modelde beklenen en uzun süre: bilgisayardaki model buluttan yavaştır ve bir süre boşta kalınca belleğe
    /// yeniden yüklenir. Yine de sınırlıdır: çeviriler sırayla gider, bir satır bütün sırayı bekletmesin; ekrandan çoktan
    /// kalkmış satırın geç gelen çevirisini hat zaten göstermez.
    public static let localTimeout: TimeInterval = 15
    /// "Bağlantıyı dene"de yerel model için beklenen süre: ilk istek modeli belleğe yükler, uzun sürebilir.
    public static let localTestTimeout: TimeInterval = 90
    static let cloudKeyTestTimeout: TimeInterval = 15

    /// Kısa zaman aşımı: altyazı birkaç saniye ekranda kalır, geç gelen çeviri işe yaramaz.
    public static func makeSession(timeout: TimeInterval = AITranslationCore.timeout) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }

    /// Hizmete uygun zaman aşımıyla oturum.
    public static func makeSession(provider: AIProvider) -> URLSession {
        makeSession(timeout: provider.isLocal ? localTimeout : timeout)
    }

    static func makeKeyTestSession(provider: AIProvider) -> URLSession {
        let limit = provider.isLocal ? localTestTimeout : cloudKeyTestTimeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = limit
        configuration.timeoutIntervalForResource = limit
        return URLSession(configuration: configuration)
    }

    /// Hattın ayırdığı konuşan adı; istemde adıyla söylenir.
    public func noteSpeaker(_ name: String) { names.learn(name: name) }

    public func translate(_ text: String, fallback: (String) async throws -> String) async throws -> String {
        // Arama, HTTP isteği ve kayıt aynı oyunla yapılmalı; callback işlem sırasında değişebilir.
        let game = self.game?()?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bağlam, bu satırdan önce gösterilenlerdir; satırın kendisi bağlama girmez.
        let context = contextBeforeShowing(text, game: game)
        if let cached = cache.value(for: self.cacheKey(text, game: game)) { return remember(cached, for: text, game: game) }
        let pieces = SubtitleSegmenter.split(text)
        names.learn(from: pieces)
        // Önbellekte duran cümleler yeniden gönderilmez.
        var translations: [String?] = pieces.map { $0.translate ? cache.value(for: self.cacheKey($0.text, game: game)) : nil }
        let missing = pieces.indices.filter { pieces[$0].translate && translations[$0] == nil }
        let sources = missing.map { SubtitleSegmenter.normalizeCase(pieces[$0].text, names: names.all) }
        // Hizmetin beklemesi yalnız eksik çeviriler içindir; önbellekteki parçalar yerel motor istemez. Hata sonrası
        // beklemede yerel çeviri yoksa (indirilmemiş, açılamadı) satır düşmesin: hizmet yine denenir. 429 beklemesi kalır.
        let (paused, pausedForLimit) = lock.withLock { (Date() < pausedUntil, pauseRateLimited) }
        if !sources.isEmpty, paused {
            if pausedForLimit {
                TranslationProbe.current?.noteFallback("\(provider.rawValue) dakikalık hizmet sınırı")
                return remember(try await fallback(text), for: text, game: game)
            }
            if let local = try await Self.tryFallback(text, fallback: fallback) {
                let reason = lastFailure.map { String(describing: $0) } ?? "bekleme"
                TranslationProbe.current?.noteFallback("\(provider.rawValue) yeniden deneme beklemesi (\(reason))")
                return remember(local, for: text, game: game)
            }
        }
        // Dakikalık hak bittiyse satır sessizce yerel çeviriyle çevrilir (hata değildir). Hak uygulamanın temkinli
        // tahminidir; yerel çeviri yoksa satır denenmeden düşmesin, istek yine gönderilir.
        let allowed = sources.isEmpty || budget?.take() != false
        lock.withLock { rateLimited = !allowed }
        if !allowed {
            if let local = try await Self.tryFallback(text, fallback: fallback) {
                TranslationProbe.current?.noteFallback("\(provider.rawValue) uygulama dakikalık sınırı")
                return remember(local, for: text, game: game)
            }
            lock.withLock { rateLimited = false }
        }
        let translated: [String]
        do {
            let present = SpeakerNames.occurring(names.protected, in: sources.joined(separator: "\n"), exact: true)
            translated = sources.isEmpty ? [] : try await request(sources, context: context, game: game, names: present)
            if !sources.isEmpty { setFailure(nil) }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as AIRateLimited {
            // Dakikalık sınır: kısa beklenir, ana ekranda uyarı çıkmaz; hizmet daha düşük sınır bildirdiyse ona inilir.
            if let perMinute = error.limit.requestsPerMinute { budget?.lower(to: perMinute) }
            let pause = max(1, min(error.limit.retryAfter ?? Self.rateLimitPause, Self.rateLimitPause))
            lock.withLock {
                rateLimited = true
                pausedUntil = Date().addingTimeInterval(pause)
                pauseRateLimited = true
            }
            TranslationProbe.current?.noteFallback("\(provider.rawValue) dakikalık hizmet sınırı")
            return remember(try await fallback(text), for: text, game: game)
        } catch {
            let reason = error as? AIFailure ?? .unreachable
            setFailure(reason)
            lock.withLock {
                pausedUntil = Date().addingTimeInterval(errorPause)
                pauseRateLimited = false
            }
            TranslationProbe.current?.noteFallback("\(provider.rawValue) hizmet durumu: \(reason)")
            return remember(try await fallback(text), for: text, game: game)
        }
        var local = false
        for (index, sentence) in zip(missing, translated) {
            let piece = pieces[index].text
            // Model dizide bu cümleyi boş bıraktıysa (bozuk OCR okumasında olabiliyor, #296) yanıt yok sayılır.
            let empty = sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if empty || Self.isEcho(piece, sentence), let retried = try await Self.tryFallback(piece, fallback: fallback),
               !retried.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Self.isEcho(piece, retried) {
                // Yerel çeviri bu motorun önbelleğine yazılmaz.
                TranslationProbe.current?.noteFallback("\(provider.rawValue) boş veya değişmemiş yanıt")
                translations[index] = retried
                local = true
                continue
            }
            if empty {
                // Yerel çeviri de yoksa cümle olduğu gibi kalır; boş satır gösterilmez, sonuç önbelleğe yazılmaz.
                local = true
                continue
            }
            translations[index] = sentence
            cache.store(sentence, for: self.cacheKey(piece, game: game))
        }
        let result = zip(pieces, translations).map { $1 ?? $0.text }.joined()
        lock.withLock {
            if speech.count >= 512 { speech.removeAll() }
            speech[self.cacheKey(text, game: game)] = SpeechScript.lines(pieces: pieces, translations: translations)
        }
        if !local { cache.store(result, for: self.cacheKey(text, game: game)) }
        return remember(result, for: text, game: game)
    }

    /// Model cümleyi çevirmeden geri verdi mi (hattın "zaten hedef dilde" eşiğiyle aynı). Küçük yerel modeller İngilizce
    /// cümleyi sık sık olduğu gibi döndürüyor ("You think I'm on the run?"); hat bunu Türkçe sanıp hiç göstermiyor,
    /// önbellek de öyle saklıyordu (#245).
    static func isEcho(_ source: String, _ translation: String) -> Bool {
        TextMatch.isSimilar(TextMatch.normalize(source), TextMatch.normalize(translation), threshold: 0.90)
    }

    /// Cümle cihaz üstü çeviriyle denenir; yerel çeviri yoksa ya da hata verirse nil. Geri verilen cümlede o da aynı
    /// kalırsa (ad, konsolun Türkçe menüsü) çevrilecek bir şey yoktur ve modelin yanıtı önbelleğe yazılır; hizmet
    /// beklerken nil dönerse istek yine gönderilir.
    private static func tryFallback(_ text: String, fallback: (String) async throws -> String) async throws -> String? {
        do {
            return try await fallback(text)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// "Ekranı çevir": birbirinden bağımsız parçalar (menü satırı, görev yazısı...) tek istekte, aynı sırada çevrilir.
    /// Parça başına istek gitseydi kalabalık bir ekran Gemini'nin dakikalık hakkını (15) ilk saniyelerde bitirir, kalan
    /// parçalar yerel çeviriye düşerdi; yerel çeviri kurulu değilse ekranın hiçbir yazısı çevrilmezdi. Bu tek istek
    /// kullanıcının tuşa basmasıyla gider: ortak hak o an bitmiş olsa da gönderilir (hakkı sayılır). Hata ya da dakikalık
    /// sınırda parçalar yerel çeviriyle çevrilir; o da yoksa hata yukarı çıkar ve ekranda gösterilir.
    /// Önbellekteki çevirisi (`translateAll` ile aynı anahtar: oynanan oyunla); istek göndermez.
    public func cached(_ text: String) -> String? {
        let game = self.game?()?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cache.value(for: cacheKey(text, game: game))
    }

    public func translateAll(_ texts: [String], fallback: (String) async throws -> String) async throws -> [String] {
        let game = self.game?()?.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [String?] = texts.map { cache.value(for: self.cacheKey($0, game: game)) }
        let missing = texts.indices.filter { results[$0] == nil }
        var failed = Date() < lock.withLock({ pausedUntil })
        for chunk in stride(from: 0, to: missing.count, by: Self.screenBatch).map({ Array(missing[$0..<min($0 + Self.screenBatch, missing.count)]) })
        where !failed {
            try Task.checkCancellation()
            _ = budget?.take()
            lock.withLock { rateLimited = false }
            do {
                let sentences = chunk.map { texts[$0] }
                let translated = try await perform(count: sentences.count, session: screenSession) { thinkingOff in
                    AIRequest.make(provider: provider, key: key, model: model, sentences: sentences, context: [], game: game,
                                   server: server, maxOutputTokens: AIRequest.screenOutputTokens, thinkingOff: thinkingOff,
                                   instruction: instruction, limits: AIRequest.screenLimits(sentences))
                }
                setFailure(nil)
                let limits = AIRequest.screenLimits(sentences)
                for (offset, (index, translation)) in zip(chunk, translated).enumerated() {
                    if let issue = AIRequest.screenIssue(source: texts[index], translation: translation, limit: limits[offset]) {
                        drops.note("translateAll", issue, texts[index])
                    }
                    results[index] = translation
                    cache.store(translation, for: self.cacheKey(texts[index], game: game))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                throw CancellationError()
            } catch let error as AIRateLimited {
                if let perMinute = error.limit.requestsPerMinute { budget?.lower(to: perMinute) }
                let pause = max(1, min(error.limit.retryAfter ?? Self.rateLimitPause, Self.rateLimitPause))
                lock.withLock {
                    rateLimited = true
                    pausedUntil = Date().addingTimeInterval(pause)
                    pauseRateLimited = true
                }
                failed = true
            } catch {
                setFailure(error as? AIFailure ?? .unreachable)
                lock.withLock {
                    pausedUntil = Date().addingTimeInterval(errorPause)
                    pauseRateLimited = false
                }
                failed = true
            }
        }
        for index in texts.indices where results[index] == nil {
            try Task.checkCancellation()
            results[index] = try await fallback(texts[index])
        }
        return results.map { $0 ?? "" }
    }

    public func spokenLines(for text: String, fallback: (String) -> [SpokenLine]) -> [SpokenLine] {
        let game = self.game?()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lines = lock.withLock({ speech[self.cacheKey(text, game: game)] }) { return lines }
        let cached = SpeechScript.fromCache(text, cache: cache, cacheKey: { self.cacheKey($0, game: game) })
        return cached.isEmpty ? fallback(text) : cached
    }

    // Oyun bilinmiyorsa eski kayıtlar geçerlidir; biliniyorsa yalnız o oyunun sonucu kullanılır. Ek talimat varsa
    // anahtar onun etiketiyle başlar: talimat değişince eski çeviriler dönmez, talimat yoksa anahtar eskisi gibidir.
    private func cacheKey(_ text: String, game: String?) -> String {
        var key = text
        if let game, !game.isEmpty { key = game + "\u{001f}" + text }
        guard let instructionTag else { return key }
        return "i:" + instructionTag + "\u{001f}" + key
    }

    private func contextBeforeShowing(_ text: String, game: String?) -> [AIContextLine] {
        lock.withLock {
            if recentGame != game {
                recent.removeAll(keepingCapacity: true)
                recentGame = game
            }
            let context = recent
            // Aynı satır yeniden okunduysa bağlam tekrarla dolmasın.
            if recent.last?.source != text {
                recent.append(AIContextLine(source: text))
                if recent.count > Self.contextLines { recent.removeFirst() }
            }
            return context
        }
    }

    /// Gösterilen satırın çevirisi sonraki satırların bağlamına girer.
    private func remember(_ translation: String, for text: String, game: String?) -> String {
        lock.withLock {
            guard recentGame == game else { return }
            if let index = recent.lastIndex(where: { $0.source == text }) { recent[index].translation = translation }
        }
        return translation
    }

    private func setFailure(_ value: AIFailure?) {
        let changed = lock.withLock { () -> Bool in
            defer { failure = value }
            return failure != value
        }
        if changed { onFailureChanged?(value) }
    }

    private func request(_ sentences: [String], context: [AIContextLine], game: String?, names: [String]) async throws -> [String] {
        try await perform(count: sentences.count, session: session) { thinkingOff in
            AIRequest.make(provider: provider, key: key, model: model, sentences: sentences, context: context, game: game,
                           server: server, thinkingOff: thinkingOff, names: names, instruction: instruction)
        }
    }

    /// İsteği gönderir. Ollama düşünmeyi kapatan alanları 400 ile reddederse (eski sürüm) alanlarsız bir kez yeniden
    /// dener; işe yararsa bu sunucuya oturum boyunca alanlar gönderilmez.
    private func perform(count: Int, session: URLSession, _ make: (_ thinkingOff: Bool) -> URLRequest) async throws -> [String] {
        guard provider.isLocal, let server, server.disablesThinking, !LocalThinking.rejected(server) else {
            return try await Self.send(make(false), provider: provider, count: count, session: session)
        }
        do {
            return try await Self.send(make(true), provider: provider, count: count, session: session, thinkingOff: true)
        } catch is ThinkingRejected {
            let result = try await Self.send(make(false), provider: provider, count: count, session: session)
            LocalThinking.remember(server)
            return result
        }
    }

    private static func send(_ request: URLRequest, provider: AIProvider, count: Int, session: URLSession,
                             thinkingOff: Bool = false) async throws -> [String] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            // Hizmete ulaşıldı ama yanıt zamanında gelmedi: internet hatası değildir.
            throw AIFailure.busy
        } catch {
            // URLError adresi taşır ama anahtarı taşımaz; yine de dışarı yalnız durum çıkar.
            throw AIFailure.unreachable
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if thinkingOff, http.statusCode == 400 { throw ThinkingRejected() }
            if let limit = AIRequest.rateLimit(status: http.statusCode, body: data) { throw AIRateLimited(limit: limit) }
            throw AIRequest.failure(status: http.statusCode, body: data)
        }
        return try AIRequest.translations(from: AIRequest.text(provider: provider, from: data), count: count)
    }

    /// Ayarlardaki "Dene" ve "Bağlantıyı dene": örnek bir satırı çevirir; çeviri ya da hatanın türü döner. Yerel modelde
    /// anahtar isteğe bağlıdır ve model belleğe yüklenirken uzun beklenir.
    public static func test(provider: AIProvider, key: String, model: String?, server: LocalAIServer? = nil,
                            sample: String = AITranslationCore.sample, session: URLSession? = nil) async -> Result<String, AIFailure> {
        // Yapıştırırken araya giren görünmez karakterler silinir (DeepL ile aynı kural). Geriye görünür ASCII dışında
        // karakter kalırsa istek gönderilmez: hiçbir hizmetin anahtarında yoktur ve HTTP başlığına yazılamaz.
        let key = DeepLKey.clean(key)
        guard !key.isEmpty || provider.isLocal else { return .failure(.invalidKey) }
        guard key.isEmpty || DeepLKey.isWellFormed(key) else { return .failure(.invalidKey) }
        let session = session ?? makeKeyTestSession(provider: provider)
        // Deneme tek istektir; çeviri hattının dakikalık hakkından yemez.
        let translator = AITranslationCore(provider: provider, key: key, model: model, server: server, session: session,
                                           budget: RequestBudget(perMinute: .max))
        do {
            let result = try await translator.translate(sample) { _ in
                // Dakikalık sınıra takıldıysa anahtar geçerlidir, hizmet şu an yoğundur (bakiye bitmedi).
                throw translator.lastFailure ?? (translator.lastLineWasRateLimited ? AIFailure.busy : AIFailure.unreachable)
            }
            return .success(result)
        } catch {
            return .failure(error as? AIFailure ?? .unreachable)
        }
    }

    /// Denemede çevrilen örnek satır.
    public static let sample = "KRATOS: We go now. Stay close, boy."
}

/// Ollama düşünmeyi kapatan alanları reddetti (eski sürüm); istek alanlarsız yeniden gönderilir.
struct ThinkingRejected: Error {}

/// Düşünmeyi kapatan alanları reddeden Ollama sunucuları; uygulama açık kaldıkça hatırlanır.
enum LocalThinking {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers = Set<String>()

    static func rejected(_ server: LocalAIServer) -> Bool { lock.withLock { servers.contains(server.address) } }
    static func remember(_ server: LocalAIServer) { lock.withLock { _ = servers.insert(server.address) } }
    static func reset() { lock.withLock { servers.removeAll() } }
}
