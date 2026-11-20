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
    /// Dönen değer: hata olduysa uyarıda gösterilecek Türkçe neden (başarıda nil).
    @discardableResult
    func refreshPacks(force: Bool, maxAge: TimeInterval = PackStore.refreshInterval) async -> String? {
        guard let packStore else { return nil }
        packStatus = .downloading
        do {
            let downloaded = try await packStore.refresh(force: force, maxAge: maxAge)
            if downloaded > 0 {
                library.reload()
                analytics.log(.packsUpdated(count: downloaded))
                onPacksChanged?()
            }
            packStatus = .ready
            return nil
        } catch let failure as PackStore.Failure {
            await packsArrivedDespite(packStore)
            packStatus = .failed(Self.describe(failure))
            return Self.reason(failure)
        } catch {
            await packsArrivedDespite(packStore)
            packStatus = .failed(error.localizedDescription)
            return error.localizedDescription
        }
    }

    /// "Paketleri şimdi güncelle"nin sonucu (ekranda uyarı olarak gösterilir).
    enum PackUpdateOutcome: Equatable {
        case upToDate
        case updated(PackUpdateSummary)
        /// Neden ve hataya rağmen inen paketler.
        case failed(String, PackUpdateSummary)
    }

    /// Elle güncelleme: süresine bakmadan listeyi sunucudan (yerel önbelleği atlayarak, gerekirse yedek adresten) alır,
    /// değişen paketleri indirir ve neyin geldiğini özetler. Paket sunucusu yapılandırılmamışsa nil.
    func updatePacksNow() async -> PackUpdateOutcome? {
        guard let packStore else { return nil }
        let before = library.packs.map { (id: $0.id, lines: $0.entries) }
        let failure = await refreshPacks(force: true)
        let after = library.packs
        let downloaded = await packStore.lastDownloaded.map { entry in
            // Satır sayısı yeniden okunan kitaplıktan (gerçekte yüklenen), yoksa sunucudaki listeden.
            PackUpdateSummary.Downloaded(id: entry.id, title: entry.title,
                                         lines: after.last { $0.id == entry.id }?.entries ?? entry.entries ?? 0)
        }
        let summary = PackUpdateSummary(before: before, downloaded: downloaded)
        if let failure { return .failed(failure, summary) }
        return summary.isEmpty ? .upToDate : .updated(summary)
    }

    /// Uyarıdaki hata nedeni.
    static func reason(_ failure: PackStore.Failure) -> String {
        switch failure {
        case .network: String(localized: "No internet connection, or the pack server could not be reached.")
        case .server(429): String(localized: "Too many attempts. Wait a few minutes and try again.")
        case let .server(code): String(format: String(localized: "The pack server did not respond (HTTP %lld)."), code)
        case .badChecksum: String(localized: "A downloaded pack could not be verified; it may have arrived incomplete.")
        case .badResponse: String(localized: "The response from the pack server could not be read.")
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
