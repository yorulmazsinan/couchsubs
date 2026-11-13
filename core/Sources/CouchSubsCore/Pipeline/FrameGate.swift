// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Okuma hattına aynı anda tek kare girer; önceki kare hâlâ işleniyorsa yeni kare atlanır (okuma kareleri biriktirmez).
///
/// Eskiden bu, uygulamadaki bir `processing` bayrağıydı ve çeviri durdurulup başlatılınca sıfırlanmıyordu. Tek bir
/// okuma bitmezse (yazı tanıma takılırsa) sonraki hiçbir kare hatta girmiyor, Ayarlar'daki önizleme canlı görünse de
/// altyazı gelmiyordu; "Durdur / Başlat" düzeltmiyor, yalnız uygulamayı kapatıp açmak düzeltiyordu. Kapı her girişe bir
/// numara verir: durdurma ve yeni hat kapıyı sıfırlar, eski okumanın geç gelen çıkışı yeni okumayı serbest bırakmaz.
/// `stuckAfterMs`'ten uzun süren okuma takılmış sayılır; çağıran hattı yeniden kurar.
public struct FrameGate {
    /// Yavaş bir Mac'te bütün karenin derin okuması birkaç saniye sürebilir; bundan uzunu takılmadır.
    public static let defaultStuckAfterMs = 15_000

    public enum Entry: Equatable {
        /// Önceki kare işleniyor; bu kare atlanır.
        case busy
        /// Kare hatta girer; bitince `leave(token)` çağrılır.
        case enter(token: Int)
        /// Önceki okuma `ms` milisaniyedir bitmedi. Kapı sıfırlandı; çağıran hattı yeniden kurup kareyi yeniden sokar.
        case stuck(ms: Int)
    }

    private let stuckAfterMs: Int
    private var current: (token: Int, since: Int)?
    private var lastToken = 0

    public init(stuckAfterMs: Int = FrameGate.defaultStuckAfterMs) {
        self.stuckAfterMs = stuckAfterMs
    }

    /// Bir kare işleniyor mu.
    public var isBusy: Bool { current != nil }

    /// `now`: milisaniye saati (`SubtitleStabilizer.uptimeMs`).
    public mutating func enter(now: Int) -> Entry {
        if let current {
            let elapsed = now - current.since
            guard elapsed >= stuckAfterMs else { return .busy }
            self.current = nil
            return .stuck(ms: elapsed)
        }
        lastToken &+= 1
        current = (lastToken, now)
        return .enter(token: lastToken)
    }

    /// Kare işlendi. Kapı bu arada sıfırlandıysa (durdurma, yeni hat) eski okumanın çıkışı bir şey değiştirmez.
    public mutating func leave(_ token: Int) {
        if current?.token == token { current = nil }
    }

    /// Çeviri durdu ya da hat yeniden kuruldu: süren okuma beklenmez.
    public mutating func reset() {
        current = nil
    }
}
