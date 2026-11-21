// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

/// PS5 aramaya yanıt vermeyince bu cihazın kendi ağ durumu (Windows ve Android'deki DeviceDiagnostics ile aynı satır).
///
/// "PS5 … adresinde bulunamadı" iki ayrı durumda görünür: PS5 ağdan düşmüştür ya da bu cihaz PS5'e paket gönderemiyordur
/// (soket açılamıyor, IPv4 adresi gitmiş, başka bir ağa geçmiş). libchiaki soket açamayınca yalnız "Discovery failed to
/// create socket" der, nedenini söylemez. iPhone ve iPad'de süreç başına açık dosya tanıtıcısı sınırı düşüktür (yumuşak
/// sınır 256); Windows'ta böyle bir sınır yoktur. Satır açık tanıtıcı sayısını, sınırı ve IPv4 ağlarını verir.
public enum DeviceDiagnostics {
    /// Yumuşak sınır en az bu kadar istenir (sert sınır daha düşükse o).
    static let wantedOpenFiles: rlim_t = 4096

    /// Tanı satırı: "açık tanıtıcı 37/4096; IPv4 en0 192.168.1.23/24".
    public static func line() -> String {
        describe(openFiles: openFileCount(), limit: openFileLimit(), networks: ipv4Networks())
    }

    static func describe(openFiles: Int, limit: Int, networks: [String]) -> String {
        let nets = networks.isEmpty ? "IPv4 ağı yok" : "IPv4 " + networks.joined(separator: ", ")
        return "açık tanıtıcı \(openFiles)/\(limit); \(nets)"
    }

    /// Yumuşak açık dosya sınırı.
    static func openFileLimit() -> Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return -1 }
        return limit.rlim_cur >= rlim_t(Int32.max) ? Int(Int32.max) : Int(limit.rlim_cur)
    }

    /// Açık dosya tanıtıcısı sayısı (sınıra kadar her numaraya bakılır, en çok 10 240).
    static func openFileCount() -> Int {
        let upper = min(max(openFileLimit(), 256), 10_240)
        return (0..<Int32(upper)).reduce(0) { $0 + (fcntl($1, F_GETFD) != -1 ? 1 : 0) }
    }

    /// Bağlı IPv4 ağları ("en0 192.168.1.23/24"); geri döngü hariç.
    static func ipv4Networks() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET), let mask = entry.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
            let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr).nonzeroBitCount }
            result.append("\(String(cString: entry.ifa_name)) \(ip)/\(bits)")
        }
        return result
    }

    /// Yumuşak sınır `wanted`'dan düşükse sert sınıra (en çok `wanted`) yükseltilir. Yeni yumuşak sınır; olmadıysa eskisi.
    @discardableResult
    static func raiseOpenFileLimit(wanted: rlim_t = wantedOpenFiles) -> Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return -1 }
        let target = min(limit.rlim_max, wanted)
        guard limit.rlim_cur < target else { return openFileLimit() }
        let old = limit.rlim_cur
        limit.rlim_cur = target
        if setrlimit(RLIMIT_NOFILE, &limit) == 0 {
            RemotePlayLog.write("açık dosya sınırı \(old) → \(target)")
        } else {
            RemotePlayLog.write("açık dosya sınırı yükseltilemedi (\(old), errno \(errno))")
        }
        return openFileLimit()
    }

    private static let raiseOnce: Void = { raiseOpenFileLimit() }()

    /// Uzun oturumda tanıtıcı biriktiyse soket açılabilsin diye (iPhone/iPad'de yumuşak sınır 256) çeviri başlarken bir kez.
    public static func raiseOpenFileLimitOnce() { _ = raiseOnce }
}
