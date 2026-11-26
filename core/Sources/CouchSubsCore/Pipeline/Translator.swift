// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Translation

public protocol TextTranslator {
    func translate(_ text: String) async throws -> String
    /// Altyazı gelmeden yerel modeli hazırlar; çevrimiçi çeviri isteği ya da bağlam durumu oluşturmamalı.
    func warmUp() async
    /// Son çevrilen altyazının seslendirilecek cümleleri (konuşmacısıyla); dublaj için.
    func spokenLines(for text: String) -> [SpokenLine]
    /// Birbirinden bağımsız metinleri ("ekranı çevir"deki menü satırları, görev yazıları) aynı sırada çevirir.
    func translateAll(_ texts: [String]) async throws -> [String]
    /// `translateAll` hepsini tek istekte çevirir (yapay zekâ); öyleyse ekran çevirisi parça parça istek göndermez.
    var translatesTogether: Bool { get }
    /// Hat satır başındaki konuşan adını ("PRICE: …") ayırıp çevirmene yalnız cümleyi verir; ad buradan öğrenilir ve
    /// sonraki cümlelerin içinde geçince çeviriden korunur (#287).
    func noteSpeaker(_ name: String)
    /// Diskteki önbellekte duran çevirisi (istek göndermeden); yoksa nil. "Ekranı çevir" önbellekteki yazıları çeviri
    /// isteğini beklemeden hemen çizer.
    func cachedTranslation(_ text: String) -> String?
}

extension TextTranslator {
    public func warmUp() async {}

    public func spokenLines(for text: String) -> [SpokenLine] { [] }

    /// Varsayılan: metinler sırayla tek tek çevrilir.
    public func translateAll(_ texts: [String]) async throws -> [String] {
        var result: [String] = []
        for text in texts { result.append(try await translate(text)) }
        return result
    }

    public var translatesTogether: Bool { false }

    public func noteSpeaker(_ name: String) {}

    public func cachedTranslation(_ text: String) -> String? { nil }
}

public enum TranslatorError: Error, Equatable {
    case needsDownload
    case unsupported
}

public enum TranslatorStatus: Equatable {
    case ready, needsDownload, unsupported

    /// Çeviri sonucunun ana ekrana yansıyan durumu. Çevrimiçi motor (DeepL, yapay zekâ, yerel model) açıkken satır
    /// yalnız motor çeviremeyince yerel yedeğe düşer; yedeğin bu sistemde olmaması (`unsupported`) asıl sorun değildir ve
    /// "Apple çevirisi iOS 26 ister" uyarısı motorun gerçek hatasını (anahtar, kota, ağ) gizliyordu (GitHub #1322). Motorun
    /// hatası ayrı uyarıda (`onlineIssue`) söylenir. Dil paketi eksikliği (`needsDownload`) yine gösterilir: indirilirse
    /// yedek çalışır. Android ve Windows'ta yerel yedek her sistemde vardır; motor hatası aynı biçimde ayrı uyarıda.
    public static func after(_ error: TranslatorError?, onlineActive: Bool) -> TranslatorStatus {
        switch error {
        case nil: .ready
        case .needsDownload: .needsDownload
        case .unsupported: onlineActive ? .ready : .unsupported
        }
    }
}

/// Apple'ın cihaz üstü çevirisi. Dil paketi yüklü olmalı; değilse `needsDownload` atar.
/// Altyazı cümle cümle çevrilir: alt alta sarılmış satırlar birleşir, konuşmacı adları ("ATREUS:") çevrilmez,
/// tümü büyük harfli cümleler önce cümle düzenine getirilir (öğrenilen adlar büyük harfle kalır).
/// İngilizce→Türkçede Windows'taki OPUS-MT ile aynı metin hattı kullanılır (`FreeLineTranslator`): terim sözlüğü
/// (~/Library/Application Support/CouchSubs/Glossary/*.json), kısa satır bağlamı, Türkçe düzeltmeler.
/// Uygulama kalıcı önbelleği verir: önceki oturumlarda çevrilmiş cümleler hiç çevrilmeden döner.
/// Arayüzsüz çeviri oturumu (`TranslationSession(installedSource:target:)`) macOS 26 / iOS 26'da geldi; daha eski
/// sistemlerde bu motor `unsupported` döner, satırlar oyun paketlerinden ya da DeepL/yapay zekâdan gelir.
public final class Translator: TextTranslator {
    /// Kalıcı önbellek dosyasındaki motor adı; metin hattı değişince (`FreeTranslation.pipelineVersion`) bu da değişir.
    public static let engineID = "apple-p\(FreeTranslation.pipelineVersion)"

    private let source: Locale.Language
    private let target: Locale.Language
    /// `TranslationSession` (macOS 26 / iOS 26); eski sistemlerde hiç oluşmaz.
    private var session: Any?
    private let cache: TranslationCache
    private let freeLine: FreeLineTranslator?
    private let speech = SpeechMemory()
    private let names = SpeakerNames()

    /// `cache`: kalıcı önbellek; verilmezse yalnız bellekte tutulur.
    public init(source: String = "en", target: String = "tr", cache: TranslationCache = TranslationCache(),
         glossary: GlossaryStore = GlossaryStore(directory: GlossaryStore.userDirectory)) {
        self.source = Locale.Language(identifier: source)
        self.target = Locale.Language(identifier: target)
        self.cache = cache
        // Sözlük, ek kuralları ve Türkçe düzeltmeler yalnız İngilizce→Türkçe için.
        freeLine = source == "en" && target == "tr" ? FreeLineTranslator(cache: cache, glossary: glossary) : nil
    }

    /// Apple'ın cihaz üstü çevirisi bu sistemde kullanılabilir mi (macOS 26 / iOS 26 ve sonrası).
    public static var isAvailable: Bool {
        if #available(macOS 26, iOS 26, *) { return true }
        return false
    }

    public static func status(source: String, target: String) async -> TranslatorStatus {
        guard #available(macOS 26, iOS 26, *) else { return .unsupported }
        return switch await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) {
        case .installed: .ready
        case .supported: .needsDownload
        default: .unsupported
        }
    }

    public func noteSpeaker(_ name: String) {
        names.learn(name: name)
        freeLine?.noteSpeaker(name)
    }

    public func translate(_ text: String) async throws -> String {
        if let freeLine { return try await freeLine.translate(text) { try await self.run($0) } }
        if let cached = cache.value(for: text) { return cached }
        let pieces = SubtitleSegmenter.split(text)
        names.learn(from: pieces)
        var result = ""
        var translations: [String?] = []
        for piece in pieces {
            let translated = piece.translate ? try await translateSentence(piece.text) : nil
            translations.append(translated)
            result += translated ?? piece.text
        }
        speech.store(SpeechScript.lines(pieces: pieces, translations: translations), for: text)
        cache.store(result, for: text)
        return result
    }

    /// Apple'ın yerel modelini doğrudan çalıştırır; FreeLine bağlamını ve çeviri önbelleğini etkilemez.
    public func warmUp() async {
        _ = try? await run("Hello")
    }

    public func spokenLines(for text: String) -> [SpokenLine] {
        if let freeLine { return freeLine.spokenLines(for: text) }
        return speech[text] ?? SpeechScript.fromCache(text, cache: cache)
    }

    private func translateSentence(_ sentence: String) async throws -> String {
        if let cached = cache.value(for: sentence) { return cached }
        let result = try await run(GameEnglish.plain(SubtitleSegmenter.normalizeCase(sentence, names: names.all)))
        cache.store(result, for: sentence)
        return result
    }

    /// Hazır metni Apple'ın çevirisine verir; oturum ilk çağrıda açılır.
    ///
    /// Çağrılar tek sıradan geçer (`TranslationGate`). Eskiden ısınma ("Hello") ile ilk altyazı aynı anda gelince ikisi
    /// de `LanguageAvailability` beklerken oturumu boş görüp ayrı `TranslationSession` açıyordu; biri öbürünün üstüne
    /// yazılıp çevirisi sürerken bırakılıyordu, aynı oturuma eşzamanlı istek de gidebiliyordu. iPhone'da Translation
    /// çerçevesinin içinde Swift tuzağıyla kapanma görülüyordu (Crashlytics, 1.0.1–1.0.3).
    private func run(_ input: String) async throws -> String {
        try await gate.run { try await self.runNow(input) }
    }

    private let gate = TranslationGate()

    private func runNow(_ input: String) async throws -> String {
        guard #available(macOS 26, iOS 26, *) else { throw TranslatorError.unsupported }
        if session == nil {
            switch await LanguageAvailability().status(from: source, to: target) {
            case .installed: session = TranslationSession(installedSource: source, target: target)
            case .supported: throw TranslatorError.needsDownload
            default: throw TranslatorError.unsupported
            }
        }
        guard let session = session as? TranslationSession else { throw TranslatorError.unsupported }
        return try await session.translate(input).targetText
    }
}

/// Eşzamansız çağrıları sırayla, birer birer çalıştırır. Sırada bekleyen görev iptal edilirse beklemeyi bırakır
/// (`CancellationError`); altyazı hattı süren çeviriyi bıraktığında arkadaki istekler takılı kalmaz.
final class TranslationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var nextID: UInt64 = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []

    func run<T>(_ body: () async throws -> T) async throws -> T {
        try await enter()
        defer { leave() }
        return try await body()
    }

    private func enter() async throws {
        let id = makeID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if !busy {
                    busy = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func makeID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func cancel(_ id: UInt64) {
        lock.lock()
        let waiter = waiters.firstIndex { $0.id == id }.map { waiters.remove(at: $0) }
        lock.unlock()
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func leave() {
        lock.lock()
        guard !waiters.isEmpty else {
            busy = false
            lock.unlock()
            return
        }
        let next = waiters.removeFirst()
        lock.unlock()
        next.continuation.resume()
    }
}
