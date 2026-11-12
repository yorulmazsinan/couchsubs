// SPDX-License-Identifier: AGPL-3.0-only

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
/// `LocalAiServer` ile aynı). Adres "http://localhost:11434/v1" gibi `/v1` ile biten temel adrestir.
public struct LocalAIServer: Equatable, Sendable {
    /// Ollama'nın OpenAI uyumlu adresi (docs.ollama.com/api/openai-compatibility).
    public static let ollamaURL = "http://localhost:11434/v1"
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

    /// İsteğin gittiği adres.
    public var chatURL: URL { baseURL.appendingPathComponent("chat/completions") }

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

    /// Önbellekteki motor adı: sunucu (makine ve kapı) ve model girer; farklı yerel modellerin çevirileri karışmaz.
    /// Ör. "local:localhost:11434/qwen2.5:7b".
    public var engineID: String {
        let host = baseURL.host?.lowercased() ?? ""
        let port = baseURL.port.map { ":\($0)" } ?? ""
        return "\(AIProvider.local.rawValue):\(host)\(port)/\(model)"
    }
}

/// Yapay zekâ hizmeti neden çeviremedi. Hata yalnız durum taşır: anahtar ve hizmetin yanıt metni hiçbir yere yazılmaz.
public enum AIFailure: Error, Equatable, Sendable {
    /// Anahtar reddedildi (401/403 ya da Gemini'de "API key not valid").
    case invalidKey
    /// Bakiye bitti, aylık sınır ya da dakikalık istek sınırı aşıldı (429, 402, Claude'da "credit balance").
    case quotaExceeded
    /// Hizmet isteği kabul etmedi (400, 404); ör. listedeki model hesapta açık değil.
    case modelRejected
    /// Ağ hatası, zaman aşımı, hizmet arızası ya da anlaşılmayan yanıt.
    case unreachable
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

    public static let systemPrompt = """
        You translate English video game subtitles into natural, spoken Turkish, the way people really talk. \
        Characters address each other informally (use "sen", not "siz") unless the line is clearly formal. \
        Keep character names, place names and speaker labels such as "ATREUS:" exactly as they are. \
        Keep line breaks. Keep the meaning and tone; do not add or leave out anything. \
        Reply with only the translation, no explanations, notes or quotes.
        """

    /// Kullanıcı iletisi: önceki satırlar (yalnız bağlam) ve çevrilecek cümleler.
    public static func userMessage(sentences: [String], context: [AIContextLine], game: String? = nil) -> String {
        var parts: [String] = []
        if let game, !game.isEmpty { parts.append("Game: \(game)") }
        if !context.isEmpty {
            var lines = ["Previous subtitles, for context only (do not translate them again):"]
            for line in context {
                lines.append("English: \(line.source)")
                if let translation = line.translation { lines.append("Turkish: \(translation)") }
            }
            parts.append(lines.joined(separator: "\n"))
        }
        let list = (try? JSONSerialization.data(withJSONObject: sentences, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        parts.append("Translate each string in this JSON array into Turkish. Reply with only a JSON array of \(sentences.count) "
            + "Turkish strings in the same order.\n\(list)")
        return parts.joined(separator: "\n\n")
    }

    /// Yerel modelin sıcaklığı: çeviri tutarlı olsun, yine de doğal kalsın.
    public static let localTemperature = 0.2

    /// Hizmete giden HTTP isteği. `server`: yerel modelin sunucusu (verilmezse Ollama'nın varsayılan adresi).
    public static func make(provider: AIProvider, key: String, model: AIModel, sentences: [String],
                            context: [AIContextLine], game: String? = nil, server: LocalAIServer? = nil) -> URLRequest {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userMessage(sentences: sentences, context: context, game: game)
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
                "systemInstruction": ["parts": [["text": systemPrompt]]],
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
                "messages": [["role": "developer", "content": systemPrompt], ["role": "user", "content": user]],
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
                "system": systemPrompt,
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
                "messages": [["role": "system", "content": systemPrompt], ["role": "user", "content": user]],
                "temperature": localTemperature,
                "max_tokens": maxOutputTokens,
                "stream": false,
            ]
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
        // ```json … ``` çitini at.
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .filter { !$0.hasPrefix("```") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]"), start < end,
           let data = String(trimmed[start...end]).data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [String] {
            guard list.count == count else { throw AIFailure.unreachable }
            return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard count == 1 else { throw AIFailure.unreachable }
        return [trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))]
    }

    /// Başarısız HTTP yanıtının anlamı. Gövde yalnız tanınan hata kodları için okunur, hiçbir yere yazılmaz.
    public static func failure(status: Int, body: Data) -> AIFailure {
        let message = String(data: body, encoding: .utf8)?.lowercased() ?? ""
        switch status {
        case 401, 403: return .invalidKey
        case 402, 429: return .quotaExceeded
        case 400:
            if message.contains("api_key_invalid") || message.contains("api key not valid") { return .invalidKey }
            if message.contains("credit balance") || message.contains("insufficient_quota") { return .quotaExceeded }
            return .modelRejected
        case 404: return .modelRejected
        default: return .unreachable
        }
    }

    /// 429 yalnız dakikalık sınırdan geldiyse onun ayrıntısı; gün sınırı, bakiye ya da tanınmayan 429 için nil (bunlar
    /// `quotaExceeded` olarak kullanıcıya gösterilir). Gemini'nin hata gövdesinde error.details[] içinde
    /// google.rpc.QuotaFailure (violations[].quotaId, ör. "GenerateRequestsPerMinutePerProjectPerModel-FreeTier",
    /// quotaValue "15") ve google.rpc.RetryInfo (retryDelay "37s") bulunur.
    public static func rateLimit(status: Int, body: Data) -> AIRateLimit? {
        guard status == 429,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
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
/// bir dakika hizmet denenmez; her satırda zaman aşımı beklenmez. Yerel çeviriler bu motorun önbelleğine yazılmaz.
/// Bir altyazının çevrilmemiş bütün cümleleri tek istekte gider. Ücretsiz katmanın dakikalık sınırı için model listesindeki
/// `requestsPerMinute` kadar istek hakkı vardır; hak bitince o satır sessizce (hata göstermeden) yerel çeviriyle çevrilir.
public final class AITranslationCore: @unchecked Sendable {
    /// Bağlama giden önceki satır sayısı.
    public static let contextLines = 3
    /// Hata sonrası bu süre hizmet denenmez.
    public static let retryAfter: TimeInterval = 60
    /// Dakikalık sınır aşılınca en çok bu kadar beklenir (hizmet bekleme önermezse de bu kadar).
    public static let rateLimitPause: TimeInterval = 20

    public let provider: AIProvider
    public let model: AIModel
    /// Yerel modelin sunucusu; bulut hizmetlerinde nil.
    public let server: LocalAIServer?
    private let key: String
    private let session: URLSession
    private let cache: TranslationCache
    private let budget: RequestBudget?
    private let names = SpeakerNames()
    private let lock = NSLock()
    private var speech: [String: [SpokenLine]] = [:]
    /// Son gösterilen satırlar, eskiden yeniye.
    private var recent: [AIContextLine] = []
    private var pausedUntil = Date.distantPast
    private var failure: AIFailure?
    private var rateLimited = false

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
    public init(provider: AIProvider, key: String, model: String? = nil, server: LocalAIServer? = nil, session: URLSession? = nil,
                cache: TranslationCache = TranslationCache(), budget: RequestBudget? = nil) {
        self.provider = provider
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = provider.model(model)
        self.model = resolved
        self.server = provider.isLocal ? server ?? LocalAIServer(baseURL: LocalAIServer.ollamaURL, model: resolved.id) : nil
        self.session = session ?? Self.makeSession(provider: provider)
        self.cache = cache
        self.budget = budget ?? RequestBudget.shared(provider: provider, model: resolved)
    }

    /// Bulut hizmetinde beklenen en uzun süre.
    public static let timeout: TimeInterval = 5
    /// Yerel modelde beklenen en uzun süre: bilgisayardaki model buluttan yavaştır ve bir süre boşta kalınca belleğe
    /// yeniden yüklenir. Yine de sınırlıdır: çeviriler sırayla gider, bir satır bütün sırayı bekletmesin; ekrandan çoktan
    /// kalkmış satırın geç gelen çevirisini hat zaten göstermez.
    public static let localTimeout: TimeInterval = 15
    /// "Bağlantıyı dene"de yerel model için beklenen süre: ilk istek modeli belleğe yükler, uzun sürebilir.
    public static let localTestTimeout: TimeInterval = 90

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

    public func translate(_ text: String, fallback: (String) async throws -> String) async throws -> String {
        // Bağlam, bu satırdan önce gösterilenlerdir; satırın kendisi bağlama girmez.
        let context = lock.withLock { recent }
        shown(text)
        if let cached = cache.value(for: text) { return remember(cached, for: text) }
        guard Date() >= lock.withLock({ pausedUntil }) else { return remember(try await fallback(text), for: text) }
        let pieces = SubtitleSegmenter.split(text)
        names.learn(from: pieces)
        // Önbellekte duran cümleler yeniden gönderilmez.
        var translations: [String?] = pieces.map { $0.translate ? cache.value(for: $0.text) : nil }
        let missing = pieces.indices.filter { pieces[$0].translate && translations[$0] == nil }
        let sources = missing.map { SubtitleSegmenter.normalizeCase(pieces[$0].text, names: names.all) }
        // Dakikalık hak bittiyse istek gönderilmez; satır sessizce yerel çeviriyle çevrilir (hata değildir).
        let allowed = sources.isEmpty || budget?.take() != false
        lock.withLock { rateLimited = !allowed }
        guard allowed else { return remember(try await fallback(text), for: text) }
        let translated: [String]
        do {
            translated = sources.isEmpty ? [] : try await request(sources, context: context)
            setFailure(nil)
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
            }
            return remember(try await fallback(text), for: text)
        } catch {
            setFailure(error as? AIFailure ?? .unreachable)
            lock.withLock { pausedUntil = Date().addingTimeInterval(Self.retryAfter) }
            return remember(try await fallback(text), for: text)
        }
        for (index, sentence) in zip(missing, translated) {
            translations[index] = sentence
            cache.store(sentence, for: pieces[index].text)
        }
        let result = zip(pieces, translations).map { $1 ?? $0.text }.joined()
        lock.withLock {
            if speech.count >= 512 { speech.removeAll() }
            speech[text] = SpeechScript.lines(pieces: pieces, translations: translations)
        }
        cache.store(result, for: text)
        return remember(result, for: text)
    }

    public func spokenLines(for text: String, fallback: (String) -> [SpokenLine]) -> [SpokenLine] {
        if let lines = lock.withLock({ speech[text] }) { return lines }
        let cached = SpeechScript.fromCache(text, cache: cache)
        return cached.isEmpty ? fallback(text) : cached
    }

    private func shown(_ text: String) {
        lock.withLock {
            // Aynı satır yeniden okunduysa bağlam tekrarla dolmasın.
            guard recent.last?.source != text else { return }
            recent.append(AIContextLine(source: text))
            if recent.count > Self.contextLines { recent.removeFirst() }
        }
    }

    /// Gösterilen satırın çevirisi sonraki satırların bağlamına girer.
    private func remember(_ translation: String, for text: String) -> String {
        lock.withLock {
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

    private func request(_ sentences: [String], context: [AIContextLine]) async throws -> [String] {
        try await Self.send(AIRequest.make(provider: provider, key: key, model: model, sentences: sentences, context: context,
                                           server: server),
                            provider: provider, count: sentences.count, session: session)
    }

    private static func send(_ request: URLRequest, provider: AIProvider, count: Int, session: URLSession) async throws -> [String] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // URLError adresi taşır ama anahtarı taşımaz; yine de dışarı yalnız durum çıkar.
            throw AIFailure.unreachable
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let limit = AIRequest.rateLimit(status: http.statusCode, body: data) { throw AIRateLimited(limit: limit) }
            throw AIRequest.failure(status: http.statusCode, body: data)
        }
        return try AIRequest.translations(from: AIRequest.text(provider: provider, from: data), count: count)
    }

    /// Ayarlardaki "Dene" ve "Bağlantıyı dene": örnek bir satırı çevirir; çeviri ya da hatanın türü döner. Yerel modelde
    /// anahtar isteğe bağlıdır ve model belleğe yüklenirken uzun beklenir.
    public static func test(provider: AIProvider, key: String, model: String?, server: LocalAIServer? = nil,
                            sample: String = AITranslationCore.sample, session: URLSession? = nil) async -> Result<String, AIFailure> {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty || provider.isLocal else { return .failure(.invalidKey) }
        let session = session ?? makeSession(timeout: provider.isLocal ? localTestTimeout : timeout)
        // Deneme tek istektir; çeviri hattının dakikalık hakkından yemez.
        let translator = AITranslationCore(provider: provider, key: key, model: model, server: server, session: session,
                                           budget: RequestBudget(perMinute: .max))
        do {
            let result = try await translator.translate(sample) { _ in
                // Dakikalık sınıra takıldıysa anahtar geçerlidir ama şu an sınırdadır.
                throw translator.lastFailure ?? (translator.lastLineWasRateLimited ? AIFailure.quotaExceeded : AIFailure.unreachable)
            }
            return .success(result)
        } catch {
            return .failure(error as? AIFailure ?? .unreachable)
        }
    }

    /// Denemede çevrilen örnek satır.
    public static let sample = "KRATOS: We go now. Stay close, boy."
}
