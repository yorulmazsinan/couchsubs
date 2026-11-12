// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Çevrimiçi çeviri anahtarı (DeepL ya da yapay zekâ hizmeti) denendiğinde ne çıktı.
public enum OnlineKeyState: Equatable {
    /// `modelRejected`: hizmet model adını kabul etmedi (yalnız yapay zekâ hizmetlerinde).
    case valid, invalid, quotaExceeded, modelRejected, unreachable
}

/// Çevrimiçi çevirmen hatasını bildirir; ana ekran "şu an çevirmiyor" uyarısını bundan gösterir.
public protocol OnlineTranslating: AnyObject {
    /// Hata başlayınca durumla, düzelince nil ile çağrılır (yalnız değişince).
    var onFailureChanged: ((OnlineKeyState?) -> Void)? { get set }
}

public struct OnlineKeyCheck: Equatable {
    public var state: OnlineKeyState
    /// Bu ay kullanılan karakter ve aylık sınır (geçerli anahtarda).
    public var used: Int64 = 0
    public var limit: Int64 = 0

    public init(state: OnlineKeyState, used: Int64 = 0, limit: Int64 = 0) {
        self.state = state
        self.used = used
        self.limit = limit
    }
}

/// İsteğe bağlı çevrimiçi çeviri: kullanıcının kendi DeepL anahtarıyla (Windows'taki `DeepLTranslator` ile aynı).
/// Altyazı cümle cümle, konuşmacı adları çevrilmeden gönderilir. Son gösterilen 3 satır bağlam olarak eklenir:
/// DeepL'in `context` alanı (tek metin) çeviriyi etkiler ama çevrilmez ve ücretlendirilmez ("Characters included in
/// the context parameter will not be counted toward billing", developers.deepl.com/docs/api-reference/translate,
/// Kasım 2026). Önbellekteki çeviri bağlamsız eski haliyle döner; anahtar yalnız satırın kendisidir.
/// DeepL'e ulaşılamazsa ya da kota biterse o satır Apple'ın cihaz üstü çevirisiyle çevrilir; oyun altyazısız kalmaz.
public final class DeepLTranslator: TextTranslator, OnlineTranslating {
    /// Kalıcı önbellek dosyasındaki motor adı.
    public static let engineID = "deepl"
    /// Bağlama giden önceki satır sayısı.
    public static let contextLines = 3
    /// Hata sonrası bu süre DeepL denenmez; her satırda bağlantı zaman aşımını beklemeyelim.
    private static let retryAfter: TimeInterval = 60

    private let key: String
    private let fallback: TextTranslator
    private let session: URLSession
    private let cache: TranslationCache
    private var speech: [String: [SpokenLine]] = [:]
    private let names = SpeakerNames()
    /// Son gösterilen satırlar, eskiden yeniye.
    private var recent: [String] = []
    private var pausedUntil = Date.distantPast
    private var failure: OnlineKeyState?
    public var onFailureChanged: ((OnlineKeyState?) -> Void)?

    /// `cache`: kalıcı önbellek; verilmezse yalnız bellekte tutulur.
    public init(key: String, fallback: TextTranslator, session: URLSession = DeepLTranslator.makeSession(),
         cache: TranslationCache = TranslationCache()) {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fallback = fallback
        self.session = session
        self.cache = cache
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        return URLSession(configuration: configuration)
    }

    /// Ücretsiz anahtarlar ":fx" ile biter ve ayrı adrese gider.
    public static func baseURL(for key: String) -> URL {
        URL(string: key.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":fx")
            ? "https://api-free.deepl.com/v2/" : "https://api.deepl.com/v2/")!
    }

    public func translate(_ text: String) async throws -> String {
        // Bağlam, bu satırdan önce gösterilenlerdir; satırın kendisi bağlama girmez.
        let context = recent.isEmpty ? nil : recent.joined(separator: "\n")
        shown(text)
        if let cached = cache.value(for: text) { return cached }
        guard Date() >= pausedUntil else { return try await fallback.translate(text) }
        let pieces = SubtitleSegmenter.split(text)
        names.learn(from: pieces)
        // Önbellekte duran cümleler yeniden gönderilmez; kota yalnız yeni cümlelere gider.
        var translations: [String?] = pieces.map { $0.translate ? cache.value(for: $0.text) : nil }
        let missing = pieces.indices.filter { pieces[$0].translate && translations[$0] == nil }
        let sources = missing.map { SubtitleSegmenter.normalizeCase(pieces[$0].text, names: names.all) }
        let translated: [String]
        do {
            translated = sources.isEmpty ? [] : try await request(sources, context: context)
            report(nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            report((error as? DeepLError)?.state ?? .unreachable)
            pausedUntil = Date().addingTimeInterval(Self.retryAfter)
            return try await fallback.translate(text)
        }
        for (index, sentence) in zip(missing, translated) {
            translations[index] = sentence
            cache.store(sentence, for: pieces[index].text)
        }
        let result = zip(pieces, translations).map { $1 ?? $0.text }.joined()
        if speech.count >= 512 { speech.removeAll() }
        speech[text] = SpeechScript.lines(pieces: pieces, translations: translations)
        cache.store(result, for: text)
        return result
    }

    private func report(_ state: OnlineKeyState?) {
        guard state != failure else { return }
        failure = state
        onFailureChanged?(state)
    }

    private func shown(_ text: String) {
        // Aynı satır yeniden okunduysa bağlam tekrarla dolmasın.
        guard recent.last != text else { return }
        recent.append(text)
        if recent.count > Self.contextLines { recent.removeFirst() }
    }

    public func spokenLines(for text: String) -> [SpokenLine] {
        if let lines = speech[text] { return lines }
        let cached = SpeechScript.fromCache(text, cache: cache)
        return cached.isEmpty ? fallback.spokenLines(for: text) : cached
    }

    private func request(_ sentences: [String], context: String?) async throws -> [String] {
        var body: [String: Any] = [
            "text": sentences, "source_lang": "EN", "target_lang": "TR",
            // Oyun konuşması: "siz" değil "sen" (DeepL Türkçede desteklemiyorsa yok sayar).
            "formality": "prefer_less", "preserve_formatting": true,
        ]
        if let context { body["context"] = context }
        var request = URLRequest(url: Self.baseURL(for: key).appending(path: "translate"))
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        struct Reply: Decodable { struct Item: Decodable { let text: String }; let translations: [Item] }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.translations.count == sentences.count else { throw URLError(.cannotParseResponse) }
        return reply.translations.map(\.text)
    }

    /// Ayarlardaki "Kaydet ve dene": anahtar geçerli mi, bu ay ne kadar kullanıldı.
    public static func check(key: String, session: URLSession = makeSession()) async -> OnlineKeyCheck {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return OnlineKeyCheck(state: .invalid) }
        var request = URLRequest(url: baseURL(for: key).appending(path: "usage"))
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            try check(response)
            struct Usage: Decodable { let character_count: Int64; let character_limit: Int64 }
            let usage = try JSONDecoder().decode(Usage.self, from: data)
            let used = usage.character_limit > 0 && usage.character_count >= usage.character_limit
            return OnlineKeyCheck(state: used ? .quotaExceeded : .valid, used: usage.character_count, limit: usage.character_limit)
        } catch let error as DeepLError {
            return OnlineKeyCheck(state: error.state)
        } catch {
            return OnlineKeyCheck(state: .unreachable)
        }
    }

    private struct DeepLError: Error { let state: OnlineKeyState }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        switch http.statusCode {
        case 401, 403: throw DeepLError(state: .invalid)
        case 456: throw DeepLError(state: .quotaExceeded)
        default: throw DeepLError(state: .unreachable)
        }
    }
}
