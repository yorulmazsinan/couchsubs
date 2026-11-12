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
    public init(provider: AIProvider, key: String, model: String?, server: LocalAIServer? = nil, fallback: TextTranslator,
                session: URLSession? = nil, cache: TranslationCache = TranslationCache()) {
        core = AITranslationCore(provider: provider, key: key, model: model, server: server, session: session, cache: cache)
        self.fallback = fallback
    }

    public func translate(_ text: String) async throws -> String {
        try await core.translate(text) { [fallback] line in try await fallback.translate(line) }
    }

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
