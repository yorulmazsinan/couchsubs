// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// PS5 aramasının ağa bindirdiği yük (Windows `SweepPacing`, Android `SweepPacing` ve yerel kütüphanelerdeki döngü aynı kural).
///
/// #1366: çeviri başlayınca evdeki bütün cihazların Wi-Fi'ı kopuyordu. Ağ taraması /24'ün 254 adresine (Mac'te /22'ye kadar
/// ~1000 adres) yarım saniyede bir, 3 sn boyunca aralıksız paket gönderiyordu: bir taramada ~1500 paket, her turda birkaç
/// milisaniyede 254 paket ve boştaki her adres için gönderenin ARP genel yayını. Zayıf modemlerde bu, akışın açıldığı anda
/// Wi-Fi'ı tıkıyordu. Artık tarama yalnız iki tur gönderir ve paketler arasında 4 ms beklenir (en çok ~250 paket/sn);
/// tek adrese (ya da birkaç adrese) soru eskisi gibi yarım saniyede bir gider.
public enum SweepPacing {
    /// Bu sayıdan çok hedef "ağ taraması"dır.
    public static let sweepMinTargets = 8
    /// Taramada iki paket arası.
    public static let paceMilliseconds = 4
    static var paceMicroseconds: useconds_t { useconds_t(paceMilliseconds * 1000) }
    /// Taramada hedeflerin hepsine kaç tur gönderilir (ilk tur ve yarım saniye sonraki tur).
    public static let sweepRounds = 2

    public static func isSweep(_ targetCount: Int) -> Bool { targetCount > sweepMinTargets }

    /// `round` (0'dan) turunda hedeflere paket gider mi.
    public static func sendsInRound(_ round: Int, targetCount: Int) -> Bool {
        !isSweep(targetCount) || round < sweepRounds
    }
}

/// PS5 aramalarının ve yeniden denemelerin sayacı: dakikada en çok bir satır günlüğe yazılır, böylece kullanıcı günlüğünde
/// ağa ne kadar yük bindiği görünür ("Ağ yükü (son 60 sn): PS5 ağ taraması 1 kez, 510 paket; ..."). İlk olay hemen yazılır,
/// sonrakiler biriktirilip dakikası dolunca tek satırda yazılır. Windows `NetworkLoad`, Android `NetworkLoad` ile aynı.
public final class NetworkLoad: @unchecked Sendable {
    public static let shared = NetworkLoad(write: { RemotePlayLog.write($0) })
    public static let interval: TimeInterval = 60

    private let lock = NSLock()
    private let write: @Sendable (String) -> Void
    private var sweeps = 0
    private var sweepPackets = 0
    private var queries = 0
    private var queryPackets = 0
    private var retries = 0
    private var windowStart: Date?
    private var lastLine: Date?

    public init(write: @escaping @Sendable (String) -> Void) {
        self.write = write
    }

    /// Bir PS5 araması bitti: `sweep` ağ taraması mı, `packets` kaç paket gitti.
    public func discovery(sweep: Bool, packets: Int, now: Date = Date()) {
        record(now) {
            if sweep { sweeps += 1; sweepPackets += packets } else { queries += 1; queryPackets += packets }
        }
    }

    /// PS5 oturumu yeniden denendi.
    public func retry(now: Date = Date()) {
        record(now) { retries += 1 }
    }

    private func record(_ now: Date, _ change: () -> Void) {
        let line: String? = lock.withLock {
            if windowStart == nil { windowStart = now }
            change()
            if let lastLine, now.timeIntervalSince(lastLine) < Self.interval { return nil }
            let seconds = Int(now.timeIntervalSince(windowStart ?? now).rounded())
            let text = Self.line(seconds: max(seconds, 0), sweeps: sweeps, sweepPackets: sweepPackets, queries: queries,
                                 queryPackets: queryPackets, retries: retries)
            sweeps = 0; sweepPackets = 0; queries = 0; queryPackets = 0; retries = 0
            lastLine = now
            windowStart = nil
            return text
        }
        if let line { write(line) }
    }

    static func line(seconds: Int, sweeps: Int, sweepPackets: Int, queries: Int, queryPackets: Int, retries: Int) -> String {
        "Ağ yükü (son \(seconds) sn): PS5 ağ taraması \(sweeps) kez, \(sweepPackets) paket; tek adres sorgusu \(queries) kez, "
            + "\(queryPackets) paket; PS5'e yeniden bağlanma \(retries)"
    }
}
