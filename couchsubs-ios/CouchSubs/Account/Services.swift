// SPDX-License-Identifier: AGPL-3.0-only
// Ölçüm arayüzü. Uygulama tamamen ücretsiz ve hesapsızdır; gerçek ölçüm Firebase Analytics ve Meta App Events'e gider
// (Measurement.swift), testlerde ve anahtarlar yokken boşu kullanılır.

import Foundation

/// Ölçülen olaylar (Firebase Analytics ve Meta App Events'e aynı anda gider).
enum AnalyticsEvent: Equatable, Sendable {
    case packHit(packId: String?)
    case sessionStart(output: String)
    case sessionStop(seconds: Int)
    case tvConnected(brand: String)
    case packsUpdated(count: Int)

    var name: String {
        switch self {
        case .packHit: "pack_hit"
        case .sessionStart: "session_start"
        case .sessionStop: "session_stop"
        case .tvConnected: "tv_connected"
        case .packsUpdated: "packs_updated"
        }
    }

    var parameters: [String: Sendable] {
        switch self {
        case .packHit(let id): id.map { ["pack_id": $0] } ?? [:]
        case .sessionStart(let output): ["output": output]
        case .sessionStop(let seconds): ["seconds": seconds]
        case .tvConnected(let brand): ["brand": brand]
        case .packsUpdated(let count): ["count": count]
        }
    }
}

@MainActor
protocol AnalyticsLogging: AnyObject {
    func log(_ event: AnalyticsEvent)
    func screen(_ name: String)
    /// Profil › Kullanım verisi: Analytics ve Crashlytics toplamasını açar/kapatır.
    func setCollection(_ enabled: Bool)
}

/// Hiçbir şey göndermez (testler, Firebase yapılandırılmamışken).
final class NoAnalytics: AnalyticsLogging {
    func log(_ event: AnalyticsEvent) {}
    func screen(_ name: String) {}
    func setCollection(_ enabled: Bool) {}
}
