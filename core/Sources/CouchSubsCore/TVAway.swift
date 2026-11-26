// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// #1303: telefon uygulaması arka plandayken TV ile bağlantı koptu mu; koptuysa kullanıcıya "CouchSubs'ı açık tutun"
/// denir (arka plandayken bildirim, dönüşte ana ekranda not). Kullanıcı "altyazı bir süre TV'ye geliyor, sonra yalnız
/// telefonda kalıyor" diyordu: iPhone arka plana geçen uygulamayı askıya alıyor, TV bağlantısı düşüyordu; neden hiç
/// söylenmiyordu.
///
/// iPhone askıdayken hiçbir olay gelmez: kopma çoğu zaman dönüşte görülür (TV bağlı değil ya da dönüşten hemen sonra
/// kopuyor). Bu yüzden dönüşten sonraki kısa süre (`grace`) de "arka plandayken koptu" sayılır. Uyarı bir arka plan
/// gezisinde bir kez verilir. Android'deki `TvAway` ile aynı kural.
public struct TVAway: Sendable {
    /// Dönüşten sonra bu kadar saniye içinde gelen kopma, arka planda kopmuş sayılır (askıdan dönen soket geç kapanır).
    public static let defaultGrace: TimeInterval = 5

    public let grace: TimeInterval
    /// Uygulama şu an arka planda mı.
    public private(set) var away = false
    /// Arka plana geçerken TV bağlı mıydı (değilse kopma bizim uyarımız değildir).
    private var linkedWhenLeft = false
    private var returnedAt: TimeInterval?
    /// Bu gezide uyarı verildi.
    private var warned = false

    public init(grace: TimeInterval = TVAway.defaultGrace) {
        self.grace = grace
    }

    /// Uygulama arka plana geçti; `linked`: TV uygulaması o anda bağlı mı.
    public mutating func left(linked: Bool) {
        away = true
        linkedWhenLeft = linked
        returnedAt = nil
        warned = false
    }

    /// Uygulama öne döndü. TV giderken bağlıydı ve şimdi bağlı değilse true: uyarı gösterilir.
    public mutating func returned(at now: TimeInterval, linked: Bool) -> Bool {
        let wasAway = away
        away = false
        returnedAt = now
        guard wasAway, linkedWhenLeft, !linked else { return false }
        return warn()
    }

    /// Bağlı TV uygulamasının bağlantısı koptu. Uygulama arka plandaysa ya da az önce döndüyse (TV giderken bağlıydı) true.
    public mutating func lost(at now: TimeInterval) -> Bool {
        if away { return warn() }
        guard linkedWhenLeft, let returnedAt, now - returnedAt <= grace else { return false }
        return warn()
    }

    /// Çeviri durdu ya da başladı: geçmiş unutulur.
    public mutating func reset() {
        away = false
        linkedWhenLeft = false
        returnedAt = nil
        warned = false
    }

    private mutating func warn() -> Bool {
        if warned { return false }
        warned = true
        return true
    }
}
