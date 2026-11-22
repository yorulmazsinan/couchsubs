// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Okuma hattına aynı anda tek kare girer; önceki kare hâlâ işleniyorsa yeni kare atlanır (okuma kareleri biriktirmez).
///
/// Eskiden bu, uygulamadaki bir `processing` bayrağıydı ve çeviri durdurulup başlatılınca sıfırlanmıyordu. Tek bir
/// okuma bitmezse (yazı tanıma takılırsa) sonraki hiçbir kare hatta girmiyor, Ayarlar'daki önizleme canlı görünse de
/// altyazı gelmiyordu; "Durdur / Başlat" düzeltmiyor, yalnız uygulamayı kapatıp açmak düzeltiyordu. Kapı her girişe bir
/// numara verir: durdurma ve yeni hat kapıyı sıfırlar, eski okumanın geç gelen çıkışı yeni okumayı serbest bırakmaz.
/// `stuckAfterMs`'ten uzun süren okuma takılmış sayılır; çağıran hattı yeniden kurar.
///
/// Okuma sürerken atlanan kare olduysa `leave` bunu söyler; çağıran atlanan son kareyi hemen okutur (GitHub #1019).
/// Mac ve Windows'ta pencere yakalaması değişmeyen ekranda kare göndermez: altyazı belirirken gelen son kare okuma
/// sürdüğü için atlanırsa ardından kare gelmiyor, yeni satır kamera oynatılana dek okunmuyordu.
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
    /// Süren okuma sırasında kare atlandı mı.
    private var skipped = false

    public init(stuckAfterMs: Int = FrameGate.defaultStuckAfterMs) {
        self.stuckAfterMs = stuckAfterMs
    }

    /// Bir kare işleniyor mu.
    public var isBusy: Bool { current != nil }

    /// `now`: milisaniye saati (`SubtitleStabilizer.uptimeMs`).
    public mutating func enter(now: Int) -> Entry {
        if let current {
            let elapsed = now - current.since
            guard elapsed >= stuckAfterMs else {
                skipped = true
                return .busy
            }
            self.current = nil
            skipped = false
            return .stuck(ms: elapsed)
        }
        skipped = false
        lastToken &+= 1
        current = (lastToken, now)
        return .enter(token: lastToken)
    }

    /// Kare işlendi. Kapı bu arada sıfırlandıysa (durdurma, yeni hat) eski okumanın çıkışı bir şey değiştirmez.
    /// Bu okuma sürerken kare atlandıysa true: çağıran atlanan son kareyi hatta sokmalı.
    @discardableResult
    public mutating func leave(_ token: Int) -> Bool {
        guard current?.token == token else { return false }
        current = nil
        defer { skipped = false }
        return skipped
    }

    /// Çeviri durdu ya da hat yeniden kuruldu: süren okuma beklenmez.
    public mutating func reset() {
        current = nil
        skipped = false
    }
}
