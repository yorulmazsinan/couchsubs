// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CouchSubsCore

/// Çevrimiçi motorun (DeepL, yapay zekâ, yerel model) hatasının kullanıcıya söylenişi; Mac ve iPhone ortak (iPhone
/// project.yml bu dosyayı da derler). Windows: Contracts.cs `Describe`, Android: OnlineIssueText.kt.
enum OnlineIssueText {
    /// Hatanın kendisi: anahtar kabul edilmedi, kota doldu, hizmete ulaşılamadı... (ayarlar ve ana ekran aynı metni kullanır).
    static func describe(_ state: OnlineKeyState, engine: TranslationEngine, server: LocalAIServer?, keychainFailure: String) -> String {
        if engine == .local { return LocalAIText.describe(state, server: server, keychainFailure: keychainFailure) }
        let name = engine.displayName
        return switch state {
        case .valid: String(localized: "It works.")
        case .invalid: String(format: String(localized: "%@ did not accept this key. Copy it again from your account page."), name)
        case .quotaExceeded: String(format: String(localized: "Your %@ account has no credit left or has reached its limit."), name)
        case .modelRejected: String(format: String(localized: "%@ did not accept the request. Choose the other model or try again later."), name)
        case .unreachable: String(format: String(localized: "%@ could not be reached. Check your internet connection."), name)
        case .busy: String(format: String(localized: "%@ is busy or did not answer in time. Try again in a moment, or choose the faster model."), name)
        case .keychainWriteFailed: keychainFailure
        }
    }

    /// Ana ekran uyarısı: motor şu an çevirmiyor, nedeni ve bu arada ne çevirdiği. Ücretsiz çeviri bu sistemde yoksa
    /// (macOS/iOS 26 öncesi) "ücretsiz çeviri kullanılıyor" denmez; yalnız oyun paketleri çevirir (GitHub #1322).
    static func notice(_ state: OnlineKeyState?, engine: TranslationEngine, server: LocalAIServer?, keychainFailure: String,
                       freeTranslation: Bool) -> String {
        let reason = state.map { describe($0, engine: engine, server: server, keychainFailure: keychainFailure) } ?? ""
        let meanwhile = freeTranslation
            ? String(localized: "Meanwhile the free translation is used.")
            : String(localized: "The free translation doesn't work on this system, so meanwhile only game packs translate.")
        return [String(format: String(localized: "%@ is not translating right now"), engine.displayName) + ".", reason, meanwhile]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
