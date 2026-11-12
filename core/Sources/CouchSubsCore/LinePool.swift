// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Ortak havuz (varsayılan açık, ayarlardan kapatılabilir; ayarlarda ve kurulumun son adımında açıkça söylenir): hiçbir pakette bulunmayan İngilizce oyun satırları biriktirilir ve
/// beş dakikada bir (ve uygulama kapanırken) sunucuya gönderilir; yeni paketler bunlardan hazırlanır. Yalnız satırın
/// metni, anahtarı ve ilk görüldüğü an gider; kimlik olarak kuruluma özgü rastgele bir UUID kullanılır (IP, kullanıcı adı,
/// PSN bilgisi yok). Sunucuya ulaşılamazsa kuyruk diskte bekler, sonra sessizce yeniden denenir.
/// Windows'taki CouchSubs.Core/LinePool.cs ile aynı kurallar.
public actor LinePool {
    /// Açık; ayarlarda kullanıcı kapatabilir (kapatınca kuyruk da silinir).
    public static let enabledByDefault = true
    /// Sunucu adresi; denemede `COUCHSUBS_POOL_URL` ortam değişkeniyle değiştirilir.
    public static let defaultEndpoint = URL(string: "https://couchsubs-pool.enmera.workers.dev/v1/lines")!
    public static let batchSize = 200
    public static let maxQueue = 5000
    public static let maxLength = 300
    public static let minWords = 2
    public static let flushInterval: TimeInterval = 300
    /// Gönderilen anahtarlardan bu kadarı hatırlanır (aynı satır her oturumda yeniden gitmesin).
    static let rememberedSent = 20000
    /// Kuyruk en geç bu aralıkla diske yazılır (her satırda yazılmaz).
    static let saveInterval: TimeInterval = 30

    public struct Line: Codable, Equatable, Sendable {
        public let text: String
        public let key: String
        public let firstSeen: String
    }

    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct State: Codable {
        var install: String
        var queue: [Line]
        var sent: [String]
        var retryAfter: Date?
    }

    private struct Payload: Encodable {
        let install: String
        let app: String
        let platform: String
        let lines: [Line]
    }

    public static var endpoint: URL {
        if let value = ProcessInfo.processInfo.environment["COUCHSUBS_POOL_URL"], let url = URL(string: value), url.scheme != nil {
            return url
        }
        if let value = UserDefaults.standard.string(forKey: "poolURL"), let url = URL(string: value), url.scheme != nil { return url }
        return defaultEndpoint
    }

    private let file: URL
    private let url: URL
    private let app: String
    private let platform: String
    private let send: Send
    private let clock: @Sendable () -> Date
    private var state: State
    private var queuedKeys: Set<String>
    private var sentKeys: Set<String>
    private var lastSave = Date.distantPast
    private var dirty = false
    public private(set) var isEnabled: Bool

    public init(file: URL, endpoint: URL = LinePool.endpoint, app: String, platform: String = "mac",
                enabled: Bool = LinePool.enabledByDefault,
                send: @escaping Send = { try await URLSession.shared.data(for: $0) },
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.file = file
        url = endpoint
        self.app = app
        self.platform = platform
        self.send = send
        self.clock = clock
        isEnabled = enabled
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let saved = (try? Data(contentsOf: file)).flatMap { try? decoder.decode(State.self, from: $0) }
        let initial = saved ?? State(install: UUID().uuidString.lowercased(), queue: [], sent: [], retryAfter: nil)
        state = initial
        queuedKeys = Set(initial.queue.map(\.key))
        sentKeys = Set(initial.sent)
    }

    public var queued: [Line] { state.queue }
    public var installID: String { state.install }

    /// Kapatılınca bekleyen satırlar da silinir: kullanıcı vazgeçtiyse hiçbir şey gitmez.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard !enabled, !state.queue.isEmpty else { return }
        state.queue.removeAll()
        queuedKeys.removeAll()
        dirty = true
        save()
    }

    /// Okunan (pakette bulunmayan) satırı kuyruğa ekler; kapalıysa, filtreye takılırsa ya da zaten varsa bir şey yapmaz.
    public func offer(_ text: String) {
        guard isEnabled else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.accepts(text), let key = PackKey.key(text), !queuedKeys.contains(key), !sentKeys.contains(key) else { return }
        state.queue.append(Line(text: text, key: key, firstSeen: Self.timestamp(clock())))
        queuedKeys.insert(key)
        // Sınır aşılırsa en eski satırlar düşer.
        if state.queue.count > Self.maxQueue {
            let dropped = state.queue.prefix(state.queue.count - Self.maxQueue)
            for line in dropped { queuedKeys.remove(line.key) }
            state.queue.removeFirst(dropped.count)
        }
        dirty = true
        if clock().timeIntervalSince(lastSave) >= Self.saveInterval { save() }
    }

    /// Kuyruğu 200'lük parçalar hâlinde gönderir. 429'da sunucunun istediği kadar bekler; ulaşılamazsa kuyruk kalır.
    public func flush() async {
        defer { save() }
        guard isEnabled else { return }
        while !state.queue.isEmpty {
            if let retry = state.retryAfter, clock() < retry { return }
            let batch = Array(state.queue.prefix(Self.batchSize))
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let body = try? JSONEncoder().encode(Payload(install: state.install, app: app, platform: platform, lines: batch)) else { return }
            request.httpBody = body
            guard let reply = try? await send(request), let http = reply.1 as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200..<300:
                state.retryAfter = nil
                remove(batch, sent: true)
            case 429:
                state.retryAfter = clock().addingTimeInterval(Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After"), now: clock()))
                dirty = true
                return
            case 400..<500:
                // Sunucu bu parçayı kabul etmiyor; yeniden göndermek düzeltmez.
                remove(batch, sent: false)
            default:
                return
            }
        }
    }

    /// Kuyruğu diske yazar (uygulama kapanırken de çağrılır).
    public func save() {
        guard dirty else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(state) { try? data.write(to: file, options: .atomic) }
        dirty = false
        lastSave = clock()
    }

    private func remove(_ batch: [Line], sent: Bool) {
        let keys = Set(batch.map(\.key))
        state.queue.removeAll { keys.contains($0.key) }
        queuedKeys.subtract(keys)
        if sent {
            state.sent += batch.map(\.key)
            sentKeys.formUnion(keys)
            if state.sent.count > Self.rememberedSent {
                let dropped = state.sent.prefix(state.sent.count - Self.rememberedSent)
                sentKeys.subtract(dropped)
                state.sent.removeFirst(dropped.count)
            }
        }
        dirty = true
    }

    /// Havuza uygun satır: en az iki sözcük, en çok 300 karakter, arayüz ya da yazı tanıma çöpü gibi görünmüyor; Türkçe,
    /// PS5'in sistem yazısı ya da yarım okuma değil (`PoolFilter`).
    public static func accepts(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= maxLength else { return false }
        let words = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }
        guard words.count >= minWords else { return false }
        return !looksLikeNoise(text) && PoolFilter.accepts(text)
    }

    /// Yazı tanıma çöpü içeren ("ou$3e") ya da harften çok rakam ve simge taşıyan ("100/100 HP 25%") satır.
    static func looksLikeNoise(_ text: String) -> Bool {
        if PackKey.canon(OcrNoise.clean(text)) != PackKey.canon(text) { return true }
        let visible = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        let letters = visible.filter(isLetter).count
        return letters * 2 < visible.count
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    /// `Retry-After`: saniye ya da HTTP tarihi; yoksa bir dakika, en çok bir gün.
    static func retryDelay(_ header: String?, now: Date) -> TimeInterval {
        let fallback: TimeInterval = 60
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return fallback }
        if let seconds = Double(header) { return min(max(seconds, 1), 86400) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return fallback }
        return min(max(date.timeIntervalSince(now), 1), 86400)
    }

    /// "2026-11-11T03:17:00Z" (UTC, saniye hassasiyeti).
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
