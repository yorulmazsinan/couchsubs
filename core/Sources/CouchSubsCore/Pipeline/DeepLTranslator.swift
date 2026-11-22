// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Çevrimiçi çeviri anahtarı (DeepL ya da yapay zekâ hizmeti) denendiğinde ne çıktı.
public enum OnlineKeyState: Equatable {
    /// `modelRejected`: hizmet model adını kabul etmedi (yalnız yapay zekâ hizmetlerinde); `busy`: hizmet şu an yoğun ya da
    /// zamanında yanıt vermedi (DeepL'in anahtar denemesinde: 429, çok sık istek).
    case valid, invalid, quotaExceeded, modelRejected, unreachable, busy, keychainWriteFailed
}

/// Çevrimiçi çevirmen hatasını bildirir; ana ekran "şu an çevirmiyor" uyarısını bundan gösterir.
public protocol OnlineTranslating: AnyObject {
    /// Hata başlayınca durumla, düzelince nil ile çağrılır (yalnız değişince).
    var onFailureChanged: ((OnlineKeyState?) -> Void)? { get set }
}

/// DeepL anahtar denemesinin ayrıntılı nedeni (Windows: OnlineKeyReason, Android: KeyCheck.Reason; aynı kurallar).
/// Ayarlardaki mesaj ve günlük satırı bundan yazılır; anahtarın kendisini hiç içermez.
public enum OnlineKeyReason: Equatable {
    case none
    /// Görünmez karakterler silindikten sonra anahtarda DeepL anahtarında olamayacak karakter kaldı; istek gönderilmedi.
    case malformedKey
    /// DeepL 429 döndü: çok sık istek.
    case rateLimited
    /// DeepL bu HTTP koduyla yanıt verdi (401/403/456 ya da beklenmeyen 5xx vb.).
    case httpStatus(Int)
    /// İstek DeepL'e ulaşmadı (URLError kodu: bağlantı yok, zaman aşımı…).
    case network(Int)

    /// Günlük satırı için kısa, anahtarsız açıklama.
    public var logDescription: String {
        switch self {
        case .none: ""
        case .malformedKey: "anahtarda geçersiz karakter"
        case .rateLimited: "HTTP 429 (çok sık istek)"
        case .httpStatus(let code): "HTTP \(code)"
        case .network(let code): "ağ hatası \(code)"
        }
    }
}

public struct OnlineKeyCheck: Equatable {
    public var state: OnlineKeyState
    /// Bu ay kullanılan karakter ve aylık sınır (geçerli anahtarda). Sınır 0: DeepL bildirmedi; `unlimited` ve üstü: sınır yok.
    public var used: Int64 = 0
    public var limit: Int64 = 0
    public var reason: OnlineKeyReason = .none

    /// Sınır konmamış hesapta DeepL `character_limit` olarak bunu döndürür (developers.deepl.com, usage-and-quota, Kasım 2026).
    public static let unlimited: Int64 = 1_000_000_000_000

    public init(state: OnlineKeyState, used: Int64 = 0, limit: Int64 = 0, reason: OnlineKeyReason = .none) {
        self.state = state
        self.used = used
        self.limit = limit
        self.reason = reason
    }

    /// Günlük satırı: durum ve neden ("busy (HTTP 429 (çok sık istek))"); anahtarı içermez.
    public var logDescription: String {
        reason == .none ? "\(state)" : "\(state) (\(reason.logDescription))"
    }
}

/// DeepL anahtarının yazımı (Windows ve Android'deki DeepLKey ile aynı kural). Yapıştırırken araya giren boşluk, satır
/// sonu, sekme, bölünmez boşluk (U+00A0), sıfır genişlikli boşluk, BOM, yumuşak tire gibi görünmez karakterler her yerden
/// silinir; DeepL anahtarında bunlar hiç yoktur. Bölünmez boşluk başlıkta kalınca istek "sunucuya bağlanılamadı"
/// (-1004), é gibi Latin-1 harfleri DeepL'den 502 döndürüyordu; ikisi de "DeepL'e ulaşılamadı" görünüyordu.
public enum DeepLKey {
    public static func clean(_ key: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in key.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Temizlenmiş anahtar DeepL anahtarı olabilir mi: boş değil, yalnız görünür ASCII (harf, rakam, "-", ":" …).
    public static func isWellFormed(_ cleaned: String) -> Bool {
        !cleaned.isEmpty && cleaned.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
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
    /// Hata sonrası bu süre DeepL denenmez; her satırda bağlantı zaman aşımını beklemeyelim. 1 dk oyunda çok uzundu
    /// (Windows ve Android ile aynı).
    static let retryAfter: TimeInterval = 15

    /// Uygulamanın ortak DeepL oturumu: bağlantı açık kalır, sıcak tutucu da bunu kullanır.
    static let sharedSession = makeSession()

    private let key: String
    private let fallback: TextTranslator
    private let session: URLSession
    private let cache: TranslationCache
    private let speech = SpeechMemory()
    private let names = SpeakerNames()
    /// Çevrilmeyecek adlar ve terimler (ücretsiz çeviriyle aynı sözlük); DeepL'e etiketle korunarak gider.
    private let glossaryStore: GlossaryStore
    /// Son gösterilen satırlar, eskiden yeniye.
    private var recent: [String] = []
    private var pausedUntil = Date.distantPast
    /// Bekleme DeepL'in 429 yanıtından mı; öyleyse yerel çeviri olmasa da istek gönderilmez.
    private var pauseRateLimited = false
    private var failure: OnlineKeyState?
    public var onFailureChanged: ((OnlineKeyState?) -> Void)?

    /// Ortak oturumla çalışırken bağlantıyı sıcak tutan; testlerin sahte oturumunda nil.
    private let warmer: DeepLConnectionWarmer?

    /// `cache`: kalıcı önbellek; verilmezse yalnız bellekte tutulur. `session` verilmezse ortak oturum kullanılır ve
    /// bağlantı oturum başından itibaren sıcak tutulur.
    public init(key: String, fallback: TextTranslator, session: URLSession? = nil,
         cache: TranslationCache = TranslationCache(),
         glossary: GlossaryStore = GlossaryStore(directory: GlossaryStore.userDirectory)) {
        self.key = DeepLKey.clean(key)
        self.fallback = fallback
        self.session = session ?? Self.sharedSession
        self.cache = cache
        glossaryStore = glossary
        warmer = session == nil && !self.key.isEmpty ? DeepLConnectionWarmer.shared : nil
        // Gerçek bağlantıyla oturum başında ısınır, oyun boyunca sıcak kalır.
        warmer?.touch(key: self.key)
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        return URLSession(configuration: configuration)
    }

    /// Ücretsiz anahtarlar ":fx" ile biter ve ayrı adrese gider.
    public static func baseURL(for key: String) -> URL {
        URL(string: DeepLKey.clean(key).hasSuffix(":fx")
            ? "https://api-free.deepl.com/v2/" : "https://api.deepl.com/v2/")!
    }

    public func translate(_ text: String) async throws -> String {
        // Bağlam, bu satırdan önce gösterilenlerdir; satırın kendisi bağlama girmez.
        let context = recent.isEmpty ? nil : recent.joined(separator: "\n")
        shown(text)
        warmer?.touch(key: key)
        let glossary = glossaryStore.glossary
        if let cached = cache.value(for: DeepLMarkup.cacheKey(text, glossary: glossary)) { return cached }
        // Hata sonrası beklemede yerel çeviri yoksa (indirilmemiş, açılamadı) satır düşmesin: DeepL yine denenir.
        // 429 beklemesi kalır.
        if Date() < pausedUntil {
            if pauseRateLimited { return try await fallback.translate(text) }
            if let local = try await tryFallback(text) { return local }
        }
        let pieces = SubtitleSegmenter.split(text)
        names.learn(from: pieces)
        // Önbellekte duran cümleler yeniden gönderilmez; kota yalnız yeni cümlelere gider.
        var translations: [String?] = pieces.map {
            $0.translate ? cache.value(for: DeepLMarkup.cacheKey($0.text, glossary: glossary)) : nil
        }
        let missing = pieces.indices.filter { pieces[$0].translate && translations[$0] == nil }
        let plain = missing.map { SubtitleSegmenter.normalizeCase(pieces[$0].text, names: names.all.union(glossary.capitalWords)) }
        // Sözlükteki adlar etiketle korunur; etiket varsa istek XML olarak gider, diğer cümleler de kaçırılır.
        let wrapped = plain.map { DeepLMarkup.wrap($0, glossary: glossary) }
        let tagged = wrapped.contains { $0 != nil }
        let sources = tagged ? zip(plain, wrapped).map { $1 ?? DeepLMarkup.escape($0) } : plain
        let translated: [String]
        do {
            var reply: [String] = []
            if !sources.isEmpty {
                do {
                    reply = try await request(sources, context: context, tagged: tagged)
                } catch let error as URLError where Self.isDroppedConnection(error) && !Task.isCancelled {
                    // Açık tutulan bağlantıyı sunucu sessizce kapatmış olabilir: yeni bağlantıyla hemen bir kez daha
                    // denenir, yedek çeviriye (ve DeepL'in beklemesine) ancak ikinci hata düşürür.
                    reply = try await request(sources, context: context, tagged: tagged)
                }
            }
            translated = tagged ? reply.map(DeepLMarkup.unwrap) : reply
            report(nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            report((error as? DeepLError)?.state ?? .unreachable)
            pausedUntil = Date().addingTimeInterval(Self.retryAfter)
            pauseRateLimited = (error as? DeepLError)?.rateLimited == true
            return try await fallback.translate(text)
        }
        for (index, sentence) in zip(missing, translated) {
            translations[index] = sentence
            cache.store(sentence, for: DeepLMarkup.cacheKey(pieces[index].text, glossary: glossary))
        }
        let result = zip(pieces, translations).map { $1 ?? $0.text }.joined()
        speech.store(SpeechScript.lines(pieces: pieces, translations: translations), for: text)
        cache.store(result, for: DeepLMarkup.cacheKey(text, glossary: glossary))
        return result
    }

    public func noteSpeaker(_ name: String) {
        names.learn(name: name)
        fallback.noteSpeaker(name)
    }

    /// Yalnız yerel yedeği hazırlar; DeepL isteği veya satır bağlamı oluşturmaz.
    public func warmUp() async {
        await fallback.warmUp()
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

    private func request(_ sentences: [String], context: String?, tagged: Bool) async throws -> [String] {
        var body: [String: Any] = [
            "text": sentences, "source_lang": "EN", "target_lang": "TR",
            // Oyun konuşması: "siz" değil "sen" (DeepL Türkçede desteklemiyorsa yok sayar).
            "formality": "prefer_less", "preserve_formatting": true,
        ]
        if let context { body["context"] = context }
        if tagged {
            body["tag_handling"] = "xml"
            body["ignore_tags"] = [DeepLMarkup.tag]
        }
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

    /// Ayarlardaki "Kaydet ve dene": anahtar geçerli mi, bu ay ne kadar kullanıldı. Her hata kendi nedeniyle döner:
    /// 401/403 geçersiz, 456 sınır doldu, 429 çok sık istek (`busy`: anahtar reddedilmedi, kaydedilir), diğer HTTP kodları
    /// sunucu hatası, istek hiç ulaşmadıysa ağ hatası. 200 yanıtında kullanım alanları eksik ya da beklenmedik biçimdeyse
    /// anahtar yine geçerlidir (sınır 0 görünür).
    public static func check(key: String, session: URLSession = makeSession()) async -> OnlineKeyCheck {
        let key = DeepLKey.clean(key)
        guard !key.isEmpty else { return OnlineKeyCheck(state: .invalid) }
        guard DeepLKey.isWellFormed(key) else { return OnlineKeyCheck(state: .invalid, reason: .malformedKey) }
        var request = URLRequest(url: baseURL(for: key).appending(path: "usage"))
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            return OnlineKeyCheck(state: .unreachable, reason: .network(error.code.rawValue))
        } catch {
            return OnlineKeyCheck(state: .unreachable, reason: .network(URLError.Code.unknown.rawValue))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        switch status {
        case 200..<300: break
        case 401, 403: return OnlineKeyCheck(state: .invalid, reason: .httpStatus(status))
        case 456: return OnlineKeyCheck(state: .quotaExceeded, reason: .httpStatus(status))
        case 429: return OnlineKeyCheck(state: .busy, reason: .rateLimited)
        default: return OnlineKeyCheck(state: .unreachable, reason: .httpStatus(status))
        }
        // JSON olmayan 200 yanıtı (otel/kafe ağının giriş sayfası gibi) DeepL'den gelmemiştir: ağ hatası.
        guard let usage = Usage(data) else {
            return OnlineKeyCheck(state: .unreachable, reason: .network(URLError.Code.cannotParseResponse.rawValue))
        }
        let usedUp = usage.limit > 0 && usage.count >= usage.limit
        return OnlineKeyCheck(state: usedUp ? .quotaExceeded : .valid, used: usage.count, limit: usage.limit)
    }

    /// `/v2/usage` yanıtı (Windows ve Android'deki çözümlemeyle aynı). Alan eksik ya da sayı değilse 0; ondalıklı değer
    /// tam sayıya, Int64'e sığmayan değer Int64.max'a indirilir. Gövde JSON nesnesi değilse nil.
    struct Usage {
        var count: Int64 = 0
        var limit: Int64 = 0

        init?(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            count = Self.number(object["character_count"])
            limit = Self.number(object["character_limit"])
        }

        static func number(_ value: Any?) -> Int64 {
            let double: Double
            switch value {
            case let number as NSNumber:
                guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
                if let exact = Int64(number.stringValue) { return max(0, exact) }
                double = number.doubleValue
            case let text as String:
                if let exact = Int64(text) { return max(0, exact) }
                double = Double(text) ?? 0
            default:
                return 0
            }
            guard !double.isNaN, double > 0 else { return 0 }
            return double >= 9.2e18 ? .max : Int64(double)
        }
    }

    /// Yeniden denenecek ağ hatası: bağlantı koptu, sıfırlandı vb. Zaman aşımı ve iptal denenmez (zaman aşımında
    /// satır zaten 4 sn bekledi); DeepL'in durum kodları (429, 456, 403) `DeepLError` olarak gelir, denenmez.
    static func isDroppedConnection(_ error: URLError) -> Bool {
        error.code != .timedOut && error.code != .cancelled
    }

    private struct DeepLError: Error {
        let state: OnlineKeyState
        /// DeepL 429 döndü (çok sık istek): bekleme süresince istek gönderilmez.
        var rateLimited = false
    }

    /// Cihaz üstü çeviri; hata verirse nil.
    private func tryFallback(_ text: String) async throws -> String? {
        do {
            return try await fallback.translate(text)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        switch http.statusCode {
        case 401, 403: throw DeepLError(state: .invalid)
        case 456: throw DeepLError(state: .quotaExceeded)
        case 429: throw DeepLError(state: .unreachable, rateLimited: true)
        default: throw DeepLError(state: .unreachable)
        }
    }
}


/// Ortak DeepL bağlantısını sıcak tutar (Windows: DeepLTranslator.KeepWarm): oturum başında ve son çeviriden sonraki
/// `keepWarmFor` boyunca her `keepWarmEvery`'de bir kullanım sorgusu (`/v2/usage`; karakter kotasından yemez) gönderir.
/// Boşta kalan bağlantı sunucuda genelde 60 sn'de kapanıyor, sessizlikten sonraki ilk satır yeni TLS el sıkışmasını
/// bekliyordu. Süre dolunca durur, sonraki çeviride yeniden başlar.
final class DeepLConnectionWarmer: @unchecked Sendable {
    static let keepWarmEvery: TimeInterval = 40
    static let keepWarmFor: TimeInterval = 10 * 60
    static let shared = DeepLConnectionWarmer { key in
        _ = await DeepLTranslator.check(key: key, session: DeepLTranslator.sharedSession)
    }

    private let lock = NSLock()
    private var key = ""
    private var lastUsed = Date.distantPast
    private var running = false
    private let ping: @Sendable (String) async -> Void
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init, ping: @escaping @Sendable (String) async -> Void) {
        self.now = now
        self.ping = ping
    }

    /// Anahtarı ve son kullanım anını yazar; sıcak tutma durmuşsa yeniden başlatır.
    func touch(key: String) {
        guard !key.isEmpty else { return }
        lock.lock()
        self.key = key
        lastUsed = now()
        let start = !running
        running = true
        lock.unlock()
        if start { Task.detached(priority: .utility) { [self] in await run() } }
    }

    /// Şimdi sorgu gönderilecek anahtar; son çeviriden bu yana `keepWarmFor` geçtiyse nil (döngü durur).
    func nextPing() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard now().timeIntervalSince(lastUsed) <= Self.keepWarmFor, !key.isEmpty else {
            running = false
            return nil
        }
        return key
    }

    private func run() async {
        while let key = nextPing() {
            await ping(key)
            try? await Task.sleep(nanoseconds: UInt64(Self.keepWarmEvery * 1_000_000_000))
        }
    }
}
