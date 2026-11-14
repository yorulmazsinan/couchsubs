// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

/// Yerel ağdaki LG webOS TV'leri SSDP ile bulur.
public enum LGDiscovery {
    static let searchTarget = "urn:lge-com:service:webos-second-screen:1"

    public static func search(timeout: Duration = .seconds(3)) async -> [LGTV] {
        let hosts = await Task.detached { collectHosts(searchTarget: searchTarget, timeout: timeout) }.value
        var tvs: [LGTV] = []
        for host in Set(hosts).sorted() {
            tvs.append(LGTV(name: await friendlyName(host: host) ?? "LG TV", host: host))
        }
        if !tvs.isEmpty { return tvs }

        // SSDP yanıtı gelmediyse ağdaki adresler tek tek denenir. iPhone'da multicast izni (Apple onayı) olmadan SSDP
        // isteği hiç gönderilemiyor; Mac'te de bazı modemler çok noktaya yayını geçirmiyor.
        return await scan()
    }

    /// Üç yol birlikte: her adrese ayrı SSDP isteği (çok noktaya yayın değil, izin gerekmez), cihaz tanımı (1990) ve
    /// ikinci ekran sunucusu (3000). Biri yanıt verirse TV bulunmuştur.
    private static func scan() async -> [LGTV] {
        let targets = LocalNetwork.homeTargets()
        async let ssdp = Task.detached { collectHosts(searchTarget: searchTarget, timeout: .milliseconds(2500), unicast: targets) }.value
        var tvs = await LocalNetwork.probeAll { host in await probe(host: host) }.map(\.value)
        for host in Set(await ssdp).sorted() where !tvs.contains(where: { $0.host == host }) {
            tvs.append(LGTV(name: await friendlyName(host: host) ?? "LG TV", host: host))
        }
        return tvs.sorted { $0.host.compare($1.host, options: .numeric) == .orderedAscending }
    }

    /// Bir adresin LG webOS TV olup olmadığı: cihaz tanımı (1990) LG/webOS diyorsa ya da ikinci ekran sunucusu (3000)
    /// karşılık veriyorsa.
    private static func probe(host: String) async -> LGTV? {
        async let description = text(from: "http://\(host):1990/")
        async let greeting = text(from: "http://\(host):3000/")
        if let xml = await description, isLGDescription(xml) {
            return LGTV(name: friendlyName(fromDescription: xml) ?? "LG TV", host: host)
        }
        if let reply = await greeting, isSSAPGreeting(reply) { return LGTV(name: "LG TV", host: host) }
        return nil
    }

    private static func text(from address: String) async -> String? {
        guard let url = URL(string: address), let (data, _) = try? await LocalNetwork.probeSession.data(from: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// webOS cihaz tanımı mı (üretici LG ya da model webOS).
    static func isLGDescription(_ xml: String) -> Bool {
        let text = xml.lowercased()
        return text.contains("<device") && (text.contains("lg electronics") || text.contains("webos"))
    }

    /// webOS'un ikinci ekran (SSAP) sunucusu düz HTTP isteğine "Hello world" der.
    static func isSSAPGreeting(_ reply: String) -> Bool {
        reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "hello world"
    }

    static func friendlyName(fromDescription xml: String) -> String? {
        guard let start = xml.range(of: "<friendlyName>"),
              let end = xml.range(of: "</friendlyName>", range: start.upperBound..<xml.endIndex) else { return nil }
        let name = xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// SSDP yanıtından TV'nin adresini çıkarır; LG'nin ikinci ekran servisi değilse nil.
    static func host(fromSSDPResponse response: String, searchTarget: String = searchTarget) -> String? {
        var location: String?
        var isLG = false
        for line in response.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].uppercased() {
            case "LOCATION": location = parts[1]
            case "ST", "NT": isLG = isLG || parts[1] == searchTarget
            default: break
            }
        }
        guard isLG, let location, let url = URL(string: location) else { return nil }
        return url.host
    }

    /// SSDP arama isteği; tek adrese gönderilirken HOST o adresi taşır (UPnP 1.1 tek adresli M-SEARCH).
    static func searchRequest(searchTarget: String, host: String) -> String {
        "M-SEARCH * HTTP/1.1\r\nHOST: \(host)\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(searchTarget)\r\n\r\n"
    }

    /// `unicast` verilirse istek çok noktaya yayın grubuna değil, bu adreslerin her birine ayrı gönderilir.
    static func collectHosts(searchTarget: String, timeout: Duration, unicast: [String]? = nil) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(1900).bigEndian
        address.sin_addr.s_addr = inet_addr("239.255.255.250")

        func send(_ request: String) {
            _ = request.withCString { pointer in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, pointer, strlen(pointer), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        if let unicast {
            for _ in 0..<2 {
                for target in unicast {
                    address.sin_addr.s_addr = inet_addr(target)
                    send(searchRequest(searchTarget: searchTarget, host: "\(target):1900"))
                }
            }
        } else {
            let request = searchRequest(searchTarget: searchTarget, host: "239.255.255.250:1900")
            // İstek her ağ bağdaştırıcısından ayrı gönderilir: varsayılan bağdaştırıcı VPN olabilir ve TV o ağda değildir.
            let interfaces = LocalNetwork.privateAddresses()
            for _ in 0..<2 {
                if interfaces.isEmpty { send(request) }
                for var local in interfaces {
                    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &local, socklen_t(MemoryLayout<in_addr>.size))
                    send(request)
                }
            }
        }

        var hosts: [String] = []
        let end = ContinuousClock.now + timeout
        var buffer = [UInt8](repeating: 0, count: 2048)
        while ContinuousClock.now < end {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            if let host = host(fromSSDPResponse: String(decoding: buffer[0..<count], as: UTF8.self), searchTarget: searchTarget) { hosts.append(host) }
        }
        return hosts
    }

    /// TV'nin ağdaki adını (ör. "[LG] webOS TV UK7550") cihaz tanımından okur.
    private static func friendlyName(host: String) async -> String? {
        // webOS cihaz tanımı 1990 numaralı portta yayınlanır; okunamazsa genel ad kullanılır.
        guard let url = URL(string: "http://\(host):1990/"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return friendlyName(fromDescription: String(decoding: data, as: UTF8.self))
    }
}
