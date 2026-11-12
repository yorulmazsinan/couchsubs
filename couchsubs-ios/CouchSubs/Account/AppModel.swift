// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import Foundation
import Combine

/// Uygulama düzeyindeki durum: oyun paketlerinin güncellenmesi, ölçüm ve tanıtım turu. Uygulama tamamen ücretsizdir ve
/// hesap istemez; paketler herkese açık sunucudan indirilir, indirilemezse uygulamayla gelenler kullanılır.
@MainActor
final class AppModel: ObservableObject {
    enum PackStatus: Equatable {
        case idle, downloading, ready, failed(String)
    }

    @Published private(set) var packStatus: PackStatus = .idle
    /// Paket listesi değişince okuma hattına ve ayarlardaki listeye iletilir.
    var onPacksChanged: (() -> Void)?

    let analytics: AnalyticsLogging
    private let packStore: PackStore?
    private let library: GamePackLibrary
    private let defaults: UserDefaults

    init(analytics: AnalyticsLogging, packStore: PackStore?, library: GamePackLibrary, defaults: UserDefaults = .standard) {
        self.analytics = analytics
        self.packStore = packStore
        self.library = library
        self.defaults = defaults
    }

    /// Açılışta ve uygulama öne gelince: paketler haftada bir yenilenir.
    func start() async {
        await refreshPacks(force: false)
    }

    /// Paketleri sunucudan indirir (haftalık; `force` ile hemen). Sunucu yoksa ya da ulaşılamazsa uygulamayla gelen
    /// paketler kullanılmaya devam eder.
    func refreshPacks(force: Bool) async {
        guard let packStore else { return }
        packStatus = .downloading
        do {
            let downloaded = try await packStore.refresh(force: force)
            if downloaded > 0 {
                library.reload()
                analytics.log(.packsUpdated(count: downloaded))
                onPacksChanged?()
            }
            packStatus = .ready
        } catch let failure as PackStore.Failure {
            packStatus = .failed(Self.describe(failure))
        } catch {
            packStatus = .failed(error.localizedDescription)
        }
    }

    static func describe(_ failure: PackStore.Failure) -> String {
        switch failure {
        case .network: String(localized: "No internet connection. The packs on this phone are used.")
        case .badChecksum, .badResponse, .server: String(localized: "The game packs could not be updated. The packs on this phone are used.")
        }
    }

    // MARK: - Tanıtım turu

    static let tourKey = "coachTourDone"
    var tourDone: Bool {
        get { defaults.bool(forKey: Self.tourKey) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.tourKey)
        }
    }
}
