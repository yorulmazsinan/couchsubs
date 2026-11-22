// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Kısa kod karşılaştırma içindir; teslim için ayrı 128 bit istek sırrı gerekir.
public final class SubtitlePairing: @unchecked Sendable {
    /// `host`: isteği gönderen TV'nin adresi (bkz. `SubtitleAccess.tvHost`); bilinmiyorsa boş. Onaylanınca telefon/bilgisayar
    /// bu TV'yi kendi TV kaydına alır (marka adresten yoklanır): eskiden TV'nin başlattığı eşleşmede TV kaydedilmiyor, TV
    /// bekçisi (otomatik açma) hiç çalışmıyor, ana ekrandaki TV kartı çıkmıyordu.
    public struct Ticket: Sendable, Identifiable, Equatable {
        public let id: String
        public let code: String
        public let host: String
        public init(id: String, code: String, host: String = "") { self.id = id; self.code = code; self.host = host }
    }
    /// Onay bekleyen istek bu kadar eskiyse yeni istek onun yerini alır (bkz. `begin`).
    static let supersedeAfterMs: Int64 = 2000
    private let lock = NSLock()
    private let now: () -> Int64
    private var session = false
    private var manualUntil: Int64 = 0
    private var expires: Int64 = 0
    private var cooldown: Int64 = 0
    private var began: Int64 = 0
    private var ticket: Ticket?
    private var approved = false
    private var delivered = false
    /// Telefonda/bilgisayarda reddedilen son istek: TV'ye `rejected` olarak söylenir. TV süresi dolan ya da düşen isteği
    /// kendisi yeniden ister, reddedileni istemez (Tamam bekler); yoksa reddedilen TV için pencere art arda açılırdı.
    private var rejected: String?
    public init(clock: @escaping () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }) { now = clock }
    /// Çeviri sürüyor mu (`setSession`); `/hello`'daki `live` alanı.
    public var inSession: Bool { lock.lock(); defer { lock.unlock() }; return session }
    public func setSession(_ active: Bool) { lock.lock(); defer { lock.unlock() }; session = active; if !active { clear() } }
    public func open() { lock.lock(); defer { lock.unlock() }; manualUntil = now() + 120000 }
    public func reset() { lock.lock(); defer { lock.unlock() }; clear() }
    private func clear() { ticket = nil; approved = false; delivered = false; manualUntil = 0; cooldown = 0; rejected = nil }
    /// Süresi dolan isteğin bekleme süresi dolduğu andan sayılır. Eskiden ilk bakıldığı andan sayılıyordu: TV'de
    /// "Eşleştirme tamamlanmadı" çıktıktan sonra Tamam'a basınca istek hep reddediliyor (409), TV on saniye boyunca
    /// "Çeviriyi başlat'a basın" diyordu (çeviri sürerken).
    private func expire() { if ticket != nil && now() >= expires { ticket = nil; approved = false; delivered = false; cooldown = expires + 10000 } }
    /// Eşleştirme açık mı (çeviri sürüyor ya da "TV eşleştir"in iki dakikası dolmadı).
    public var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return session || now() < manualUntil }
    /// Onay bekleyen istek (yoksa nil). Arayüz kaçırdığı isteği buradan yeniden gösterir.
    public var pending: Ticket? { lock.lock(); defer { lock.unlock() }; expire(); return approved ? nil : ticket }
    /// TV'nin eşleştirme isteği. Onay bekleyen bir istek varken gelen yeni istek (TV uygulaması yeniden açıldı ya da
    /// TV'de Tamam ile yeniden denendi) eskisinin yerini alır: telefonda yeni kodla yeni pencere açılır. Eskiden eski
    /// istek iki dakika dolana kadar her yeni istek reddediliyor, telefondaki pencere TV'de artık görünmeyen kodu
    /// gösteriyordu. Anahtarı teslim edilmiş istek de yeni isteği engellemez.
    public func begin(host: String = "") -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        expire()
        guard session || now() < manualUntil, now() >= cooldown else { return nil }
        if ticket != nil {
            guard approved ? delivered : now() - began >= Self.supersedeAfterMs else { return nil }
        }
        let result = Ticket(id: SubtitleAccess.createKey(), code: String(Int.random(in: 100000...999999)), host: host)
        ticket = result; began = now(); expires = began + 120000; approved = false; delivered = false
        return result
    }
    @discardableResult public func resolve(_ id: String, accept: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        expire()
        guard ticket?.id == id, !approved else { return false }
        if accept { approved = true } else { ticket = nil; rejected = id; cooldown = now() + 10000 }
        return true
    }
    /// İsteğin durumu: `pending`, `approved`, `rejected` (reddedildi) ya da `expired` (süresi doldu, yerini yenisi aldı,
    /// çeviri durdu). Sunucu `rejected`'ı eski TV uygulamaları için `expired` olarak, yanında `rejected: true` ile gönderir.
    public func poll(_ id: String) -> String {
        lock.lock(); defer { lock.unlock() }
        expire()
        guard ticket?.id == id else { return id == rejected ? "rejected" : "expired" }
        if approved { delivered = true }
        return approved ? "approved" : "pending"
    }
}
