// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import Foundation

/// Kullanım verisinin (GA4 Measurement Protocol, bkz. `UsageStats`) derlemedeki kimlikleri: ölçüm kimliği ve API sırrı
/// Info.plist'e derleme ayarlarından gelir (`GA_MEASUREMENT_ID`, `GA_API_SECRET`; CI'da aynı adlı sırlar, yerelde
/// `scripts/package-mac.sh`'e verilen aynı adlı ortam değişkenleri). Denemede `COUCHSUBS_GA_MEASUREMENT_ID` ve
/// `COUCHSUBS_GA_API_SECRET` ortam değişkenleri önce gelir. Hiçbiri yoksa ölçüm tamamen kapalıdır.
enum UsageMeasurement {
    static func config(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) -> UsageStats.Config? {
        #if APP_STORE
        // Mac App Store sürümü: App Store gizlilik beyanı ("veri toplanmıyor") güncellenene kadar ölçüm derlemede kapalı.
        return nil
        #else
        if let config = UsageStats.Config(measurementID: environment["COUCHSUBS_GA_MEASUREMENT_ID"],
                                          apiSecret: environment["COUCHSUBS_GA_API_SECRET"]) { return config }
        return UsageStats.Config(measurementID: bundle.object(forInfoDictionaryKey: "CSGAMeasurementID") as? String,
                                 apiSecret: bundle.object(forInfoDictionaryKey: "CSGAApiSecret") as? String)
        #endif
    }

    /// "macOS 15.1" biçiminde.
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
    }
}

extension AppModel.Step {
    /// Kullanım verisinde ekranın adı; kurulum bitince ana ekran.
    var screenName: String {
        switch self {
        case .welcome: "welcome"
        case .secondAccount: "second_account"
        case .psnLogin: "psn_login"
        case .console: "console"
        case .tv: "tv"
        case .hdmi: "tv_input"
        case .test: "test"
        case .betterTranslation: "better_translation"
        case .done: "home"
        }
    }
}
