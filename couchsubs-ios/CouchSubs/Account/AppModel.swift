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

    /// Açılışta paket listesine hemen bakılır, sonra uygulama açık kaldıkça günde bir (Android'deki gibi).
    func start() async {
        await refreshPacks(force: true)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(PackStore.refreshInterval))
            guard !Task.isCancelled else { break }
            await refreshPacks(force: false)
        }
    }

    /// PS5'te yeni bir oyun başladı: o oyunun (havuzdan otomatik) paketi sunucuda yeni çıkmış olabilir; son bakış on
    /// dakikadan eskiyse hemen bakılır.
    func gameStarted() async {
        await refreshPacks(force: false, maxAge: PackStore.gameCheckInterval)
    }

    /// Paketleri sunucudan indirir (son bakış `maxAge`'den eskiyse; `force` ile hemen). Sunucu yoksa ya da ulaşılamazsa
    /// uygulamayla gelen paketler kullanılmaya devam eder.
    func refreshPacks(force: Bool, maxAge: TimeInterval = PackStore.refreshInterval) async {
        guard let packStore else { return }
        packStatus = .downloading
        do {
            let downloaded = try await packStore.refresh(force: force, maxAge: maxAge)
            if downloaded > 0 {
                library.reload()
                analytics.log(.packsUpdated(count: downloaded))
                onPacksChanged?()
            }
            packStatus = .ready
        } catch let failure as PackStore.Failure {
            await packsArrivedDespite(packStore)
            packStatus = .failed(Self.describe(failure))
        } catch {
            await packsArrivedDespite(packStore)
            packStatus = .failed(error.localizedDescription)
        }
    }

    /// Bir paket inemese de inenler hemen kullanılsın (Android'deki gibi).
    private func packsArrivedDespite(_ packStore: PackStore) async {
        let downloaded = await packStore.lastDownloadCount
        guard downloaded > 0 else { return }
        library.reload()
        analytics.log(.packsUpdated(count: downloaded))
        onPacksChanged?()
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
