// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// İsteğe bağlı yapay zekâ çevirisi: kullanıcının kendi Gemini, OpenAI ya da Claude anahtarıyla ya da bilgisayarındaki
/// yerel modelle (Ollama, LM Studio) (Windows'taki
/// `AiTranslator` ile aynı). İstek kurma, bağlam, önbellek ve hata sonrası bekleme `AITranslationCore`'da; hizmete
/// ulaşılamazsa ya da kota biterse o satır Apple'ın cihaz üstü çevirisiyle çevrilir, oyun altyazısız kalmaz.
public final class AITranslator: TextTranslator, OnlineTranslating {
    private let core: AITranslationCore
    private let fallback: TextTranslator

    public var onFailureChanged: ((OnlineKeyState?) -> Void)? {
        didSet {
            let report = onFailureChanged
            core.onFailureChanged = { failure in report?(failure.map(OnlineKeyState.init)) }
        }
    }

    /// `server`: yerel modelin (Ollama, LM Studio) sunucusu. `session` verilmezse hizmete uygun zaman aşımıyla kurulur.
    /// `budget` verilmezse modelin uygulama genelindeki ortak dakikalık hakkı kullanılır.
    public init(provider: AIProvider, key: String, model: String?, server: LocalAIServer? = nil, fallback: TextTranslator,
                session: URLSession? = nil, cache: TranslationCache = TranslationCache(), budget: RequestBudget? = nil) {
        core = AITranslationCore(provider: provider, key: key, model: model, server: server, session: session, cache: cache,
                                 budget: budget)
        self.fallback = fallback
    }

    public func translate(_ text: String) async throws -> String {
        try await core.translate(text) { [fallback] line in try await fallback.translate(line) }
    }

    /// Ekran çevirisi: bütün parçalar tek istekte gider; dakikalık hak parça başına harcanmaz.
    public func translateAll(_ texts: [String]) async throws -> [String] {
        try await core.translateAll(texts) { [fallback] line in try await fallback.translate(line) }
    }

    public var translatesTogether: Bool { true }

    /// Son hata; çeviri düzgün gidiyorsa nil.
    public var lastFailure: OnlineKeyState? { core.lastFailure.map(OnlineKeyState.init) }
    /// Son istek dakikalık sınır yüzünden gönderilmedi ya da hizmet dakikalık sınırı bildirdi.
    public var lastLineWasRateLimited: Bool { core.lastLineWasRateLimited }

    public func spokenLines(for text: String) -> [SpokenLine] {
        core.spokenLines(for: text) { [fallback] line in fallback.spokenLines(for: line) }
    }
}

extension OnlineKeyState {
    public init(_ failure: AIFailure) {
        switch failure {
        case .invalidKey: self = .invalid
        case .quotaExceeded: self = .quotaExceeded
        case .modelRejected: self = .modelRejected
        case .unreachable: self = .unreachable
        }
    }
}
