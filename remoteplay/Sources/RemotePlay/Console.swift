// SPDX-License-Identifier: AGPL-3.0-only

import CChiaki
import Darwin
import Foundation

public struct ConsoleInfo: Codable, Hashable, Sendable {
    public let host: String
    public let name: String
    public let isAwake: Bool

    public init(host: String, name: String, isAwake: Bool) {
        self.host = host
        self.name = name
        self.isAwake = isAwake
    }
}

/// Yerel ağdaki PS5'leri bulur ve uyutulmuş olanı uyandırır.
public enum Console {
    /// `host` verilirse yalnız o adrese sorulur (genel yayın bazı ağlarda engellenebiliyor).
    public static func discover(timeout: Duration = .seconds(3), host: String? = nil) async -> [ConsoleInfo] {
        // Arama birkaç saniye uyuyarak bekler; Swift'in iş havuzunu tutmamak için ayrı kuyrukta çalışır.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: search(timeout: timeout, host: host))
            }
        }
    }

    /// Kayıtlı PS5'i dinlenme modundan uyandırır.
    public static func wake(_ console: RegisteredConsole) throws {
        guard let credential = console.wakeCredential else { throw ChiakiError(code: CHIAKI_ERR_INVALID_DATA) }
        let logger = ChiakiLogger()
        // Günlük çağrı bitene dek yaşamalı: Swift onu son kullanımda (`pointer` okununca) bırakabilir, libchiaki ise
        // uyandırma sırasında günlüğe yazar (serbest kalmış belleğe yazmak chiaki_log'da çökertir).
        let error = withExtendedLifetime(logger) {
            chiaki_discovery_wakeup(logger.pointer, nil, console.host, credential, true)
        }
        guard error.isSuccess else { throw ChiakiError(code: error) }
    }

    private final class Collector {
        var hosts: [String: ConsoleInfo] = [:]
        let lock = NSLock()
    }

    static func search(timeout: Duration, host: String?) -> [ConsoleInfo] {
        let logger = ChiakiLogger()
        // İlk defer en son çalışır: günlük, aşağıdaki chiaki_discovery_fini de dahil her C çağrısından sonra bırakılır.
        defer { withExtendedLifetime(logger) {} }
        let discovery = UnsafeMutablePointer<ChiakiDiscovery>.allocate(capacity: 1)
        let thread = UnsafeMutablePointer<ChiakiDiscoveryThread>.allocate(capacity: 1)
        defer {
            discovery.deallocate()
            thread.deallocate()
        }
        guard chiaki_discovery_init(discovery, logger.pointer, sa_family_t(AF_INET)).isSuccess else { return [] }
        defer { chiaki_discovery_fini(discovery) }

        let collector = Collector()
        let user = Unmanaged.passUnretained(collector).toOpaque()
        guard chiaki_discovery_thread_start(thread, discovery, { host, user in
            guard let host, let user, chiaki_discovery_host_is_ps5(host), let address = host.pointee.host_addr else { return }
            let collector = Unmanaged<Collector>.fromOpaque(user).takeUnretainedValue()
            let info = ConsoleInfo(host: String(cString: address),
                                   name: host.pointee.host_name.map { String(cString: $0) } ?? "PS5",
                                   isAwake: host.pointee.state == CHIAKI_DISCOVERY_HOST_STATE_READY)
            collector.lock.lock()
            collector.hosts[info.host] = info
            collector.lock.unlock()
        }, user).isSuccess else { return [] }

        let version = strdup(CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5)
        defer { free(version) }
        var packet = ChiakiDiscoveryPacket(cmd: CHIAKI_DISCOVERY_CMD_SRCH, protocol_version: version, user_credential: 0)

        // Adres verilmezse yerel ağdaki her adrese ayrı ayrı sorulur; macOS'ta genel yayına PS5'ten
        // yanıt gelmeyebiliyor, tek tek sorgu her ağda çalışıyor.
        let targets: [in_addr_t] = host.map { [inet_addr($0)] } ?? localSubnetAddresses()

        // Yanıt kaçmasın diye arama birkaç kez tekrarlanır.
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            for target in targets {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(CHIAKI_DISCOVERY_PORT_PS5).bigEndian
                address.sin_addr.s_addr = target
                withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = chiaki_discovery_send(discovery, &packet, $0, MemoryLayout<sockaddr_in>.size)
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        chiaki_discovery_thread_stop(thread)

        collector.lock.lock()
        defer { collector.lock.unlock() }
        return collector.hosts.values.sorted { $0.host < $1.host }
    }

    /// Bağlı IPv4 ağlarındaki tüm adresler (en çok /22, yani 1022 adres), her ağın yayın adresi ve genel yayın.
    static func localSubnetAddresses() -> [in_addr_t] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [INADDR_BROADCAST] }
        defer { freeifaddrs(list) }
        var networks: [(address: UInt32, netmask: UInt32)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            // iPhone'un hücresel bağdaştırıcısı (pdp_ip) ev ağında değildir; PS5 orada aranmaz.
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, !isCellular(String(cString: entry.ifa_name)),
                  entry.ifa_addr?.pointee.sa_family == sa_family_t(AF_INET), let mask = entry.ifa_netmask else { continue }
            let address = UInt32(bigEndian: entry.ifa_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr })
            let netmask = UInt32(bigEndian: mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr })
            networks.append((address, netmask))
        }
        return targets(networks: networks).map { $0.bigEndian }
    }

    static func isCellular(_ interface: String) -> Bool { interface.hasPrefix("pdp_ip") }

    /// Arama hedefleri (ana bilgisayar sıralı). Eskiden genel yayın yalnız hiç adres bulunamazsa ekleniyordu; Wi-Fi
    /// /22'den büyükken (ör. /16) başka bir arayüz (VPN, sanal makine) adres verince PS5'in ağına hiç sorulmuyordu.
    /// Artık her ağın kendi yayın adresi ve genel yayın da her zaman eklenir.
    static func targets(networks: [(address: UInt32, netmask: UInt32)]) -> [UInt32] {
        var result: [UInt32] = []
        for network in networks {
            result += hosts(address: network.address, netmask: network.netmask)
            if ~network.netmask > 1 { result.append((network.address & network.netmask) | ~network.netmask) }
        }
        result.append(UInt32(INADDR_BROADCAST))
        var seen = Set<UInt32>()
        return result.filter { seen.insert($0).inserted }
    }

    /// Ağdaki diğer adresler (ağ ve yayın adresi hariç); /22'den büyük ağlarda boş.
    static func hosts(address: UInt32, netmask: UInt32) -> [UInt32] {
        let hostCount = ~netmask
        guard hostCount > 1, hostCount <= 1023 else { return [] }
        let network = address & netmask
        return (1..<hostCount).map { network + $0 }.filter { $0 != address }
    }
}
