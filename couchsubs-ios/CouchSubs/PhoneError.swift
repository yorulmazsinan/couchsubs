// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import RemotePlay

/// PSN girişi ve PS5 eşleştirmesinin kullanıcıya anlatılan sonuçları. Metinler Mac uygulamasıyla aynı katalogdan gelir;
/// "bu bilgisayar" diyen ve macOS ayarını anlatanların yerine telefona uygun olanlar kullanılır.
enum PhoneError: LocalizedError, Equatable {
    case invalidPin, missingAccount, missingConsole, wrongAccount, wrongCode, consoleNoAnswer, consoleNoReply,
         consoleInUse, consoleCrashed, consoleVersion, badAddress, localNetworkBlocked, registrationFailed
    case invalidLogin, loginRefused, loginRateLimited, loginServer, loginNetwork, loginBadResponse, loginWindowClosed

    init(_ kind: Registration.RegistrationError.Kind) {
        switch kind {
        case .wrongAccount: self = .wrongAccount
        case .wrongCode: self = .wrongCode
        case .noAnswer: self = .consoleNoAnswer
        case .noReply, .canceled: self = .consoleNoReply
        case .inUse: self = .consoleInUse
        case .consoleCrashed: self = .consoleCrashed
        case .versionMismatch: self = .consoleVersion
        case .badAddress: self = .badAddress
        case .localNetworkBlocked: self = .localNetworkBlocked
        case .failed: self = .registrationFailed
        }
    }

    init(_ error: PSNAccount.PSNError) {
        switch error {
        case .noCode: self = .invalidLogin
        case .refused: self = .loginRefused
        case .rateLimited: self = .loginRateLimited
        case .http: self = .loginServer
        case .network: self = .loginNetwork
        case .badResponse: self = .loginBadResponse
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidPin: String(localized: "The code must be 8 digits.")
        case .missingAccount: String(localized: "Sign in to PlayStation Network first.")
        case .missingConsole: String(localized: "No PS5 found. Make sure it is on and on the same network, or enter its IP address.")
        case .wrongAccount: String(localized: "The PS5 did not recognise this account. Get the code from the PS5 user signed in with the account you used in CouchSubs, or sign in again with that user's account.")
        case .wrongCode: String(localized: "The code is wrong or has expired. Open Pair Device again on the PS5 and enter the new code.")
        case .consoleNoAnswer: String(localized: "The PS5 did not answer. Make sure it is on (not in rest mode), on the same Wi-Fi as this phone, and that Remote Play is turned on, then try again.")
        case .consoleNoReply: String(localized: "The PS5 received the request but did not answer in time. Open Pair Device again on the PS5 and enter the new code.")
        case .consoleInUse: String(localized: "Remote Play is in use on another device. Close it there and enter a new code.")
        case .consoleCrashed: String(localized: "The PS5 Remote Play service stopped unexpectedly. Restart the PS5 and enter a new code.")
        case .consoleVersion: String(localized: "This PS5 system version is not supported yet. Update CouchSubs and try again.")
        case .badAddress: String(localized: "No PS5 found at this address. Check the PS5's IP address under Settings › Network › Connection Status.")
        case .localNetworkBlocked: String(localized: "iOS blocked the connection to the home network. Turn on CouchSubs in Settings › Privacy & Security › Local Network, then enter a new code.")
        case .registrationFailed: String(localized: "The PS5 refused the code. Open Pair Device again on the PS5 and enter the new code.")
        case .invalidLogin: String(localized: "Sign-in did not complete. Please try again.")
        case .loginRefused: String(localized: "Sony did not complete the sign-in. Wait a minute, then press Sign in again and sign in with the second account.")
        case .loginRateLimited: String(localized: "Sony received too many sign-in attempts. Wait about 15 minutes, then sign in again.")
        case .loginServer: String(localized: "Sony's sign-in server returned an error. Wait a few minutes, then sign in again.")
        case .loginNetwork: String(localized: "Could not reach Sony's sign-in server. Check the internet connection, then sign in again.")
        case .loginBadResponse: String(localized: "Sony's answer could not be read. Sign in again; if it keeps happening, update CouchSubs.")
        case .loginWindowClosed: String(localized: "The sign-in window was closed before sign-in finished. Press Sign in and finish signing in in the window.")
        }
    }
}

/// Hata ve ayrıntısı (PS5'in kodu, Sony'nin yanıtı); ayrıntı iletinin sonuna eklenir.
struct PhoneFailure: LocalizedError, Equatable {
    let error: PhoneError
    let detail: String?

    var errorDescription: String? {
        let text = error.errorDescription ?? ""
        guard let detail, !detail.isEmpty else { return text }
        return "\(text) (\(detail))"
    }
}
