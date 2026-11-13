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
    /// Açık bir ağ bağdaştırıcısının IPv4 adresi.
    public struct Candidate: Equatable, Sendable {
        public var interface: String
        public var address: String
        public var netmask: String
        public var pointToPoint: Bool
        public init(interface: String, address: String, netmask: String, pointToPoint: Bool = false) {
            self.interface = interface; self.address = address; self.netmask = netmask; self.pointToPoint = pointToPoint
        }
    }

    /// VPN (utun, ipsec, ppp), sanal makine (vmnet, vboxnet, bridge) ve benzeri bağdaştırıcılar ev ağı adresi taşısa da
    /// TV onlara ulaşamaz; Samsung'un "Host PC IP" alanına bunlardan biri yazılınca TV bağlantıyı kesiyordu.
    public static func isVirtual(_ candidate: Candidate) -> Bool {
        if candidate.pointToPoint { return true }
        let prefixes = ["utun", "ipsec", "ppp", "gif", "stf", "vmnet", "vboxnet", "bridge", "feth", "tap", "tun", "awdl", "llw", "anpi", "zt"]
        return prefixes.contains { candidate.interface.hasPrefix($0) }
    }

    /// `host` ile aynı alt ağdaki gerçek bağdaştırıcı; yoksa Wi-Fi/Ethernet (en*) ev ağı adresi; sanal bağdaştırıcı ancak
    /// başka adres yoksa. `host` nil ya da geçersizse aynı ağ adımı atlanır.
    public static func choose(_ candidates: [Candidate], near host: String?) -> String? {
        let real = candidates.filter { !isVirtual($0) }
        if let host, inet_addr(host) != UInt32.max {
            let target = inet_addr(host)
            func same(_ c: Candidate) -> Bool {
                let mask = inet_addr(c.netmask)
                return mask != 0 && inet_addr(c.address) & mask == target & mask
            }
            if let hit = real.first(where: same) ?? candidates.first(where: same) { return hit.address }
        }
        func isPrivate(_ c: Candidate) -> Bool { LocalNetwork.isPrivate(in_addr(s_addr: inet_addr(c.address))) }
        return (real.first { $0.interface.hasPrefix("en") && isPrivate($0) }
            ?? real.first(where: isPrivate)
            ?? real.first
            ?? candidates.first(where: isPrivate)
            ?? candidates.first)?.address
    }

    /// Açık (loopback dışı) bağdaştırıcıların IPv4 adresleri.
    public static func candidates() -> [Candidate] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Candidate] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0, entry.ifa_addr?.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let address = entry.ifa_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            result.append(Candidate(interface: String(cString: entry.ifa_name), address: String(cString: inet_ntoa(address)),
                                    netmask: String(cString: inet_ntoa(netmask)), pointToPoint: flags & IFF_POINTOPOINT != 0))
        }
        return result
    }

    /// `host` ile aynı alt ağdaki IPv4 adresi; yoksa Wi-Fi/Ethernet adresi (bkz. `choose`).
    public static func near(_ host: String?) -> String? { choose(candidates(), near: host) }
}
