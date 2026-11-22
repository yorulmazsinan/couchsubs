// SPDX-License-Identifier: AGPL-3.0-only
// DeepL anahtarının bu ayki kullanımı ("Bu ay: … karakterin … kadarı kullanıldı.") ve denemenin sonucu: Mac ve iPhone
// uygulamalarında ortak (Windows'ta SettingsWindow.ShowDeepLStatus, Android'de deepLUsageText aynı metinleri gösterir).

import CouchSubsCore
import Foundation

enum DeepLUsageText {
    /// `quotaUsedUp`: sınır dolunca gösterilen, cihaza göre değişen cümle (bilgisayarda yerel model, telefonda ücretsiz çeviri).
    static func describe(_ check: OnlineKeyCheck, quotaUsedUp: String) -> String {
        switch check.state {
        case .valid where check.limit >= OnlineKeyCheck.unlimited:
            String(format: String(localized: "This month: %@ characters used (no limit)."), check.used.formatted())
        case .valid where check.limit <= 0:
            String(localized: "DeepL accepted the key. This month's usage could not be read.")
        case .valid:
            String(format: String(localized: "This month: %1$@ of %2$@ characters used."),
                   check.used.formatted(), check.limit.formatted())
        case .quotaExceeded:
            quotaUsedUp
        case .invalid where check.reason == .malformedKey:
            String(localized: "The key contains characters a DeepL key cannot have. Copy it again from your DeepL account page.")
        case .invalid:
            String(localized: "DeepL did not accept this key. Copy it again from your DeepL account page.")
        case .keychainWriteFailed:
            String(localized: "The API key could not be saved to the Mac keychain.")
        case .busy:
            String(localized: "DeepL is receiving too many requests right now (HTTP 429). The key is saved; DeepL translates again in a few minutes.")
        case .unreachable, .modelRejected:
            if case .httpStatus(let code) = check.reason {
                String(format: String(localized: "DeepL answered with an error (HTTP %lld). Try again in a few minutes."), code)
            } else {
                String(localized: "DeepL could not be reached. Check your internet connection.")
            }
        }
    }
}
