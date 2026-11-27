// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network

/// Kayıtlı TV adresi yanıt veriyor mu, vermiyorsa TV ağda yeni bir adreste mi (Windows `TvReach`, Android `TvReach` ile
/// aynı kural).
///
/// beta.89 (Mac): modem LG TV'ye yeni adres vermişti (192.168.1.238 → .156). Uygulama eski adrese gidip "geliştirici modu
/// kapalı" ve "Key Server kapalı" diyordu; TV'de ikisi de açıktı. Şimdi kurulumdan, "TV uygulamasını güncelle"den ve
/// eşli TV kartından önce adres yoklanır: hiçbir kapı yanıt vermiyorsa (zaman aşımı, adreste cihaz yok; "reddedildi"
/// yanıt sayılır) TV ağda yeniden aranır, aynı TV bulunursa adres güncellenir; bulunmazsa "TV bu adreste yanıt vermiyor".
public enum TVReach {
    /// TV'nin açıkken her zaman dinlediği (ya da reddettiği) kapılar. Geliştirici modu kapalıyken de en az biri yanıt verir.
    public static func ports(for brand: TVBrand) -> [UInt16] {
        switch brand {
        case .lg: [3000, 3001, 9922, 9991, 1990]
        case .samsung: [8001, 8002, 26101, 9197]
        case .androidTV: [5555, 6466, 6467, 8008, 8009]
        // Vestel Linux (MB130): SmartCenter/DIAL her zaman açık; 1986 test aracı soketi DevProfile ile açıldıysa.
        case .vestelLinux: [56789, 1986]
        }
    }

    /// Günlüğe ve ekrana giden metin (Türkçe günlük satırı; ekran metni katalogdan çevrilir).
    public static let notRespondingLine = "TV bu adreste yanıt vermiyor (açık ve aynı ağda mı?)"

    public static func movedLine(from old: String, to new: String) -> String { "TV'nin adresi değişmiş: \(old) → \(new)" }

    /// Kayıtlı TV'nin yeri.
    public enum Location: Equatable, Sendable {
        /// Kayıtlı adreste bir şey yanıt veriyor (kapı açık ya da bağlantıyı reddediyor).
        case here
        /// Kayıtlı adres sessiz; aynı TV ağda yeni adreste bulundu.
        case moved(LGTV)
        /// Kayıtlı adres sessiz ve TV ağda bulunamadı.
        case silent
    }

    /// Kayıtlı adres yanıt vermiyorsa TV'yi ağda arar. Adresi olmayan kayıtta bir şey yapılmaz (`here`).
    public static func locate(_ saved: LGTV, responds: (String) async -> Bool, search: () async -> [LGTV]) async -> Location {
        guard !saved.host.isEmpty, !(await responds(saved.host)) else { return .here }
        guard let moved = relocated(saved, among: await search()) else { return .silent }
        return .moved(moved)
    }

    /// Bulunanlar içinde kayıtlı TV'nin yeni adresi: aynı marka ve aynı ad tekse o, değilse markada tek TV varsa o. Emin
    /// olunamazsa (birden çok tanınmayan TV) nil; başka odadaki TV'ye geçilmez.
    public static func relocated(_ saved: LGTV, among found: [LGTV]) -> LGTV? {
        TVLocator.moved(saved, among: found)
    }

    /// Adreste TV yanıt veriyor mu: kapılardan biri bağlantıyı kabul eder ya da hemen reddederse evet. Hepsi zaman aşımına
    /// uğrarsa ya da adrese yol yoksa hayır.
    public static func responds(host: String, brand: TVBrand, timeout: Duration = .milliseconds(1500)) async -> Bool {
        guard !host.isEmpty else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            for port in ports(for: brand) { group.addTask { await answers(host: host, port: port, timeout: timeout) } }
            for await answered in group where answered {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    /// Kapı bağlantıyı kabul etti ya da reddetti mi (ikisi de adreste bir cihaz olduğunu gösterir).
    static func answers(host: String, port: UInt16, timeout: Duration) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let once = Once { result in
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.fire(true)
                case .waiting(let error), .failed(let error): once.fire(isRefusal(error))
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            Task {
                try? await Task.sleep(for: timeout)
                once.fire(false)
            }
        }
    }

    /// "Bağlantı reddedildi" ya da sıfırlandı: adreste cihaz var. Zaman aşımı, yol yok, cihaz yok: sessiz.
    static func isRefusal(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .ECONNREFUSED || code == .ECONNRESET }
        return false
    }
}
