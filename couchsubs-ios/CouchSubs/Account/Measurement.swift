// SPDX-License-Identifier: AGPL-3.0-only
// Ölçüm ve izinler: Firebase Analytics + Crashlytics, Meta App Events, izin akışı (Google UMP, sonra Apple ATT) ve
// AdMob. Reklam varsayılan olarak kapalı: Remote Config'teki `ads_enabled` true olmadan reklam SDK'sı başlatılmaz.

import AppTrackingTransparency
import FacebookCore
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import FirebaseRemoteConfig
import GoogleMobileAds
import UIKit
import UserMessagingPlatform

/// Firebase Analytics ve Meta App Events'e aynı olayı gönderir.
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
        if meta { AppEvents.shared.logEvent(AppEvents.Name(event.name)) }
    }

    func screen(_ name: String) {
        guard firebase else { return }
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [AnalyticsParameterScreenName: name])
    }

    func setCollection(_ enabled: Bool) {
        guard firebase else { return }
        Analytics.setAnalyticsCollectionEnabled(enabled)
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)
    }
}

/// Uygulama açılışındaki SDK kurulumu; her parça yalnız anahtarı/dosyası varsa kurulur.
@MainActor
enum Integrations {
    /// Firebase (Analytics, Crashlytics, Remote Config): GoogleService-Info.plist varsa.
    static func configureFirebase() -> Bool {
        guard AppConfig.hasFirebase else { return false }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        let config = RemoteConfig.remoteConfig()
        config.setDefaults(["ads_enabled": false as NSObject])
        return true
    }

    /// Meta SDK: Info.plist'te FacebookAppID ve FacebookClientToken varsa. Reklam kimliği ve otomatik olaylar izin
    /// gelene kadar kapalı (Info.plist'te de kapalı başlar).
    static func configureMeta(application: UIApplication, options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        guard AppConfig.facebookAppID != nil, AppConfig.facebookClientToken != nil else { return false }
        ApplicationDelegate.shared.application(application, didFinishLaunchingWithOptions: options)
        return true
    }

    /// İzin akışı: önce Google'ın izin formu (AB/İngiltere'de gerekiyorsa), sonra Apple'ın izleme izni. Sonuca göre Meta'nın
    /// reklam kimliği toplaması açılır; Remote Config `ads_enabled` true ise ve reklam izni varsa AdMob başlatılır.
    static func requestConsent(meta: Bool, firebase: Bool) async {
        let parameters = RequestParameters()
        try? await ConsentInformation.shared.requestConsentInfoUpdate(with: parameters)
        if let presenter = topViewController() {
            try? await ConsentForm.loadAndPresentIfRequired(from: presenter)
        }
        let status = await ATTrackingManager.requestTrackingAuthorization()
        if meta {
            let allowed = status == .authorized
            Settings.shared.isAdvertiserIDCollectionEnabled = allowed
            Settings.shared.isAutoLogAppEventsEnabled = true
        }
        guard firebase else { return }
        let config = RemoteConfig.remoteConfig()
        _ = try? await config.fetchAndActivate()
        if config.configValue(forKey: "ads_enabled").boolValue, ConsentInformation.shared.canRequestAds {
            await MobileAds.shared.start()
        }
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
