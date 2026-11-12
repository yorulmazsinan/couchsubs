// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Gizli olmayan ama depoda durmayan ayarlar. Değerler `Config/Secrets.xcconfig`'ten (gitignore'da) Info.plist'e girer;
/// dosya yoksa boş kalır ve ilgili özellik kapanır (bkz. docs/ios-plan.md, "Sahibinin vermesi gerekenler").
enum AppConfig {
    private static func value(_ key: String) -> String? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    /// Firebase: GoogleService-Info.plist uygulamaya kopyalandıysa (derleme adımı, dosya varsa).
    static var hasFirebase: Bool { Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil }

    static var facebookAppID: String? { value("FacebookAppID") }
    static var facebookClientToken: String? { value("FacebookClientToken") }

    /// Paket sunucusu (Cloudflare Worker, server/packs). Yoksa yalnız uygulamayla gelen paketler kullanılır.
    static var packsBaseURL: URL? { value("CSPacksBaseURL").flatMap(URL.init(string:)) }

    static let privacyURL = URL(string: "https://github.com/yorulmazsinan/couchsubs/blob/main/PRIVACY.md")!
    static let helpURL = URL(string: "https://github.com/yorulmazsinan/couchsubs/issues")!
}
