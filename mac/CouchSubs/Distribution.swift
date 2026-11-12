// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Uygulamanın hangi kanaldan dağıtıldığı. GitHub/DMG sürümü (com.couchsubs.mac) sandbox'sız çalışır ve Sparkle ile
/// güncellenir; Mac App Store sürümü (CouchSubsAppStore hedefi, com.couchsubs.ios, APP_STORE bayrağı) App Sandbox'ta
/// çalışır ve güncellemeyi App Store yapar. Ayrıntı: docs/app-store.md.
enum Distribution {
    #if APP_STORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif

    /// GitHub sürümlerinin sayfası (DMG buradan indirilir).
    static let githubReleasesURL = URL(string: "https://github.com/yorulmazsinan/couchsubs/releases/latest")!
}
