// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

/// Bilgisayarın yerel ağ adresleri ve TV aramak için taranacak komşu adresler.
enum LocalNetwork {
    /// Açık ağ bağdaştırıcılarının özel (ev ağı) IPv4 adresleri.
    static func privateAddresses() -> [in_addr] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [in_addr] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if isPrivate(ipv4) { result.append(ipv4) }
        }
        return result
    }

    static func octets(_ address: in_addr) -> [UInt8] {
        withUnsafeBytes(of: address.s_addr) { Array($0) }
    }

    static func isPrivate(_ address: in_addr) -> Bool {
        let b = octets(address)
        return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
    }

    /// Her yerel adresin /24 ağındaki diğer adresler (kendisi hariç), tekrarsız.
    static func scanTargets(_ locals: [in_addr]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for local in locals {
            let b = octets(local)
            for last in 1..<255 where last != Int(b[3]) {
                let candidate = "\(b[0]).\(b[1]).\(b[2]).\(last)"
                if seen.insert(candidate).inserted { result.append(candidate) }
            }
        }
        return result
    }
}

/// Bu cihazın (Mac ya da iPhone/iPad) ev ağındaki adresi; TV uygulamasına altyazı sunucusunun adresi olarak verilir.
public enum NetworkAddress {
    /// `host` ile aynı alt ağdaki IPv4 adresi; yoksa ilk ağ bağdaştırıcısının adresi.
    public static func near(_ host: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        let target = inet_addr(host)
        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard Int32(entry.ifa_flags) & IFF_LOOPBACK == 0, entry.ifa_addr?.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let address = entry.ifa_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let text = String(cString: inet_ntoa(address))
            if address.s_addr & netmask == target & netmask { return text }
            fallback = fallback ?? text
        }
        return fallback
    }
}
