// SPDX-License-Identifier: AGPL-3.0-only
// Ölçüm: Firebase Analytics + Crashlytics ve Meta App Events. Reklam yok (AdMob, Google'ın izin formu UMP kaldırıldı);
// izleme yok: Apple'ın izleme izni (ATT) istenmez, Meta reklam kimliği (IDFA) toplamaz.

import FacebookCore
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import UIKit

/// Profil › Kullanım verisi (`usageData`, varsayılan açık). Kapalıyken Meta'ya olay gitmez; Firebase'in kendi ayarı kalıcıdır.
enum UsageData {
    static let key = "usageData"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Firebase Analytics ve Meta App Events'e aynı olayı gönderir (Meta'ya yalnız olayın adı).
@MainActor
final class AppAnalytics: AnalyticsLogging {
    private let firebase: Bool
    private let meta: Bool

    init(firebase: Bool, meta: Bool) {
        self.firebase = firebase
        self.meta = meta
    }

    func log(_ event: AnalyticsEvent) {
        if firebase { Analytics.logEvent(event.name, parameters: event.parameters) }
        if meta && UsageData.enabled { AppEvents.shared.logEvent(AppEvents.Name(event.name)) }
    }

    func screen(_ name: String) {
        guard firebase else { return }
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [AnalyticsParameterScreenName: name])
    }

    func setCollection(_ enabled: Bool) {
        if meta { Settings.shared.isAutoLogAppEventsEnabled = enabled }
        guard firebase else { return }
        Analytics.setAnalyticsCollectionEnabled(enabled)
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)
    }
}

/// Uygulama açılışındaki SDK kurulumu; her parça yalnız anahtarı/dosyası varsa kurulur.
@MainActor
enum Integrations {
    /// Firebase (Analytics, Crashlytics): GoogleService-Info.plist varsa.
    static func configureFirebase() -> Bool {
        guard AppConfig.hasFirebase else { return false }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        return true
    }

    /// Meta SDK: Info.plist'te FacebookAppID ve FacebookClientToken varsa. Reklam kimliği hiç toplanmaz; otomatik olaylar
    /// karşılama ekranına kadar kapalı (Info.plist'te de kapalı başlar).
    static func configureMeta(application: UIApplication, options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        guard AppConfig.facebookAppID != nil, AppConfig.facebookClientToken != nil else { return false }
        // Eski bir yapıda izleme izni verilmiş olsa da reklam kimliği toplanmaz (ayar SDK'da kalıcı).
        Settings.shared.isAdvertiserIDCollectionEnabled = false
        ApplicationDelegate.shared.application(application, didFinishLaunchingWithOptions: options)
        return true
    }

    /// Karşılama ekranından sonra: Meta'nın otomatik olayları (açılış, kurulum) açılır, reklam kimliği (IDFA) kapalı
    /// kalır. İzin formu ya da Apple'ın izleme izni (ATT) yok; Meta olayları IDFA olmadan (Aggregated Event
    /// Measurement) gider.
    static func startMeta() {
        guard AppConfig.facebookAppID != nil, AppConfig.facebookClientToken != nil else { return }
        Settings.shared.isAdvertiserIDCollectionEnabled = false
        Settings.shared.isAutoLogAppEventsEnabled = UsageData.enabled
    }
}
