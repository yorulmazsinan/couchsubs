// SPDX-License-Identifier: AGPL-3.0-only
// Xbox (Beta) hatalarının ekrandaki anlatımı; Mac ve iPhone uygulamalarında ortak (iPhone projesi bu dosyayı da derler).

import CouchSubsCore
import Foundation

enum XboxText {
    /// Kurulum ekranlarında: anlaşılır neden; beklenmedik yanıtta teknik ayrıntı parantez içinde.
    static func problem(_ error: XboxError) -> String {
        switch error.kind {
        case .signInRequired, .signInDeclined: return String(localized: "Your Microsoft sign-in expired. Sign in again in Settings › Console.")
        case .codeExpired: return String(localized: "The code expired. Try again.")
        case .noXboxAccount: return String(localized: "This Microsoft account has no Xbox profile. Sign in with the account you use on your Xbox.")
        case .network: return String(localized: "Couldn't connect to the internet. Check your connection and try again.")
        default: return String(format: String(localized: "The Xbox service sent an unexpected reply (%@)."), XboxStop.shorten(error.message, limit: 300))
        }
    }

    /// Yayın durdu (denemeler bitti ya da konsol reddetti): metin nedene göre (Windows ve Android'deki üç metin, #611);
    /// `reason`: kısaltılmış ham neden.
    static func stopped(_ kind: XboxStopKind, _ reason: String) -> String {
        switch kind {
        case .busy:
            return String(localized: "Your Xbox is streaming to another device (the Xbox app, a phone or a PC). Close that session, then start translation again.")
        case .consoleUnavailable:
            return String(localized: "Can't reach your Xbox. Make sure it's on and remote play is enabled in Settings › Devices & connections › Remote features, then start translation again.")
        case .noPicture:
            return String(localized: "No picture came from the Xbox, so translation stopped. On the Xbox, check that remote play is on in Settings › Devices & connections › Remote features, connect the Xbox with a network cable if you can (or restart it), then start translation again.")
        case .stuckPicture:
            return String(localized: "The Xbox sent sound but no picture: its picture stream is stuck. Turn the Xbox fully off by holding the power button for 10 seconds (waking it from sleep isn't enough), turn it back on, then start translation again.")
        case .serviceNotReady:
            return String(localized: "Your Xbox couldn't start its remote play service. Turn the Xbox fully off by holding the power button for 10 seconds, turn it back on, check that Remote features are on, then try again.")
        case .startFailed:
            // `reason`: yalnız hata kodu (XboxStop.displayReason); Xbox'ın JSON hata nesnesi ekranda gösterilmez (#871).
            return String(format: String(localized: "Your Xbox couldn't start the stream (code %@). Turn the Xbox fully off by holding the power button for 10 seconds, turn it back on, check that Remote features are on, then try again."), reason)
        case .dropped:
            return String(localized: "The Xbox connection dropped. Press Reconnect; if it keeps dropping, connect the Xbox with a network cable or restart it.")
        case .other:
            return String(format: String(localized: "The Xbox stream stopped (%@). Start translation again; if it keeps stopping, restart the Xbox."), reason)
        }
    }

    /// Çeviri sürerken oturum durumu.
    static func session(_ kind: XboxErrorKind) -> String {
        switch kind {
        case .signInRequired, .codeExpired, .signInDeclined:
            return String(localized: "Your Microsoft sign-in expired. Sign in again in Settings › Console.")
        case .noXboxAccount: return String(localized: "This Microsoft account has no Xbox profile. Sign in with the account you use on your Xbox.")
        case .consoleUnavailable:
            return String(localized: "Can't reach your Xbox. Is it on, and is remote play enabled in Settings › Devices & connections › Remote features? Retrying…")
        case .busy: return String(localized: "Your Xbox is in another remote play session. Close it; retrying…")
        case .timeout: return String(localized: "Your Xbox didn't answer. Retrying…")
        case .network: return String(localized: "The Xbox connection dropped. Reconnecting…")
        case .service: return String(localized: "The Xbox service sent an unexpected reply. Retrying…")
        case .noPicture: return String(localized: "No picture from the Xbox. Reconnecting…")
        case .noFirstFrame: return String(localized: "No picture came from the Xbox. Trying once more…")
        case .serverClosed: return String(localized: "The Xbox closed the stream. Reconnecting…")
        }
    }
}
