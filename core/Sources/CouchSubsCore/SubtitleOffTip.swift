// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// "Oyunun kendi altyazısını açın" ipucu ne zaman görünür (Mac ve iPhone; Android'de SubtitleOffTip.kt, Windows'ta
/// CouchSubs.Shell.SubtitleOffTip ile aynı kural).
///
/// En sık şikâyet "çeviri gelmiyor, yalnız test yazısı çıkıyor" (GitHub #503, #554, #566, #572): görüntü geliyor ama oyunda
/// altyazı kapalı ya da altyazı alanında hiç satır yok. CouchSubs sesi değil, ekrandaki altyazıyı okur. Görüntü `after`
/// boyunca kesintisiz geldiği hâlde bu çeviride tek satır gösterilmediyse ipucu görünür; ilk satırda kalkar. Görüntü hiç
/// gelmiyorsa görünmez (o zaman sorun altyazı değil bağlantıdır ve ayrı söylenir).
public struct SubtitleOffTip: Equatable, Sendable {
    public static let after: TimeInterval = 60

    /// `streaming`: görüntü kaynağı şu an bağlı. `sawLine`: bu çeviride en az bir satır gösterildi. `framesFor`: görüntünün
    /// kesintisiz ne zamandır geldiği (hiç gelmediyse nil).
    public static func isVisible(streaming: Bool, sawLine: Bool, framesFor: TimeInterval?) -> Bool {
        guard streaming, !sawLine, let framesFor else { return false }
        return framesFor >= after
    }

    /// Görüntünün bu bağlantıda ilk geldiği an (bağlantı koparsa sıfırlanır).
    public private(set) var framesSince: Date?
    public private(set) var sawLine = false

    public init() {}

    /// Yeni çeviri başladı ya da durdu.
    public mutating func reset() {
        framesSince = nil
        sawLine = false
    }

    /// Kare geldi; süre yalnız bağlıyken sayılır.
    public mutating func frameArrived(at now: Date, streaming: Bool) {
        if streaming, framesSince == nil { framesSince = now }
    }

    public mutating func lineShown() { sawLine = true }

    /// Bağlantı koptu ya da yeniden kuruluyor: görüntü süresi baştan sayılır.
    public mutating func connectionChanged(streaming: Bool) {
        if !streaming { framesSince = nil }
    }

    public func visible(now: Date, streaming: Bool) -> Bool {
        Self.isVisible(streaming: streaming, sawLine: sawLine, framesFor: framesSince.map { now.timeIntervalSince($0) })
    }
}
