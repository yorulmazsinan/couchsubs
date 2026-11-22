// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

/// Yerel ağdaki LG webOS TV'leri SSDP ile bulur.
public enum LGDiscovery {
    static let searchTarget = "urn:lge-com:service:webos-second-screen:1"
    /// Yedek arama: webOS 3.x (2017) TV'ler ikinci ekran hedefine cevap vermiyor, "ssdp:all"a veriyor (#498).
    static let allTarget = "ssdp:all"

    public static func search(timeout: Duration = .seconds(3)) async -> [LGTV] {
        var hits = await Task.detached { collectHits(searchTarget: searchTarget, timeout: timeout) }.value
        if hits.isEmpty {
            hits = await Task.detached { collectHits(searchTarget: allTarget, timeout: timeout) }.value
        }
        let tvs = await resolve(hits)
        if !tvs.isEmpty { return tvs }

        // SSDP yanıtı gelmediyse ağdaki adresler tek tek denenir. iPhone'da multicast izni (Apple onayı) olmadan SSDP
        // isteği hiç gönderilemiyor; Mac'te de bazı modemler çok noktaya yayını geçirmiyor.
        return await scan()
    }

    /// Üç yol birlikte: her adrese ayrı SSDP isteği (çok noktaya yayın değil, izin gerekmez), cihaz tanımı (1990) ve
    /// ikinci ekran sunucusu (3000). Biri yanıt verirse TV bulunmuştur.
    private static func scan() async -> [LGTV] {
        let targets = LocalNetwork.homeTargets()
        async let ssdp = Task.detached { collectHits(searchTarget: searchTarget, timeout: .milliseconds(2500), unicast: targets) }.value
        // webOS 3.x tek adrese gönderilen "ssdp:all"a cevap veriyor (#498).
        async let ssdpAll = Task.detached { collectHits(searchTarget: allTarget, timeout: .milliseconds(2500), unicast: targets) }.value
        var tvs = await LocalNetwork.probeAll { host in await probe(host: host) }.map(\.value)
        let hits = await ssdp + ssdpAll
        let known = Set(tvs.map(\.host))
        tvs += await resolve(hits.filter { !known.contains($0.host) })
        return tvs.sorted { $0.host.compare($1.host, options: .numeric) == .orderedAscending }
    }

    /// SSDP yanıtlarından TV'ler. Yanıtı kendini LG webOS olarak tanıtan adres (bkz. `SSDPHit.confirmed`) LG'dir. Yalnız
    /// sorulan hedefi geri söyleyen yanıt LG sayılmaz: bazı cihazların UPnP yığını her M-SEARCH'e sorulan hedefi aynen
    /// yazıp cevap veriyor. Önceden böyle bir adres (ör. Android TV) "LG TV" diye listeleniyor, "Bağlan" LG eşleştirmesi
    /// deneyip "TV yanıt vermedi" diyordu; LG bekçisinin taraması da onu kayıtlı LG'nin "yeni adresi" sanabiliyordu
    /// (`TVLocator`). Doğrulanmamış adreste LG cihaz tanımına ve ikinci ekran sunucusuna, sonra Android TV portlarına
    /// bakılır; ikisi de değilse atlanır.
    static func resolve(_ hits: [SSDPHit]) async -> [LGTV] {
        var confirmed: [String: Bool] = [:]
        for hit in hits { confirmed[hit.host] = (confirmed[hit.host] ?? false) || hit.confirmed }
        var tvs: [LGTV] = []
        for host in confirmed.keys.sorted() {
            if confirmed[host] == true {
                tvs.append(LGTV(name: await friendlyName(host: host) ?? "LG TV", host: host))
                continue
            }
            async let lg = probe(host: host)
            async let android = ManualTV.isAndroidTV(host: host)
            if let tv = classify(host: host, probed: await lg, androidPortOpen: await android) { tvs.append(tv) }
        }
        return tvs
    }

    /// LG olduğunu yanıtında söylemeyen SSDP adresi: LG yoklaması tanırsa LG, Android TV portu açıksa Android TV, yoksa nil.
    static func classify(host: String, probed: LGTV?, androidPortOpen: Bool) -> LGTV? {
        if let probed { return probed }
        return androidPortOpen ? LGTV(name: "Android TV", host: host, brand: .androidTV) : nil
    }

    /// Elle yazılan adresteki LG TV (cihaz tanımı ya da ikinci ekran sunucusu yanıt verirse); yoksa nil.
    public static func tv(at host: String) async -> LGTV? { await probe(host: host) }

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

    /// SSDP yanıtından TV'nin adresini çıkarır; aranan hedef değilse nil. "ssdp:all" aramasında her cihaz cevap
    /// verir: yalnız kendini LG webOS TV olarak tanıtan yanıt (bkz. isLGHeader) alınır.
    static func host(fromSSDPResponse response: String, searchTarget: String = searchTarget) -> String? {
        hit(fromSSDPResponse: response, searchTarget: searchTarget)?.host
    }

    /// SSDP yanıtındaki aday adres. `confirmed`: yanıt kendini LG webOS olarak tanıtıyor: sorulan hedefin adı dışında bir
    /// başlıkta webOS/LGTV geçiyor (webOS: "SERVER: WebOS/4.4.0 UPnP/1.0") ya da cihaz tanımı webOS'un 1990 portunda.
    /// Hedefin adı ("...webos-second-screen...") içinde "webos" geçtiği için yalnız onu geri söyleyen yanıt doğrulanmış
    /// sayılmaz.
    struct SSDPHit: Equatable, Sendable {
        let host: String
        let confirmed: Bool
    }

    static func hit(fromSSDPResponse response: String, searchTarget: String = searchTarget) -> SSDPHit? {
        var location: String?
        var isLG = false
        var lgHeader = false
        for line in response.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let name = parts[0].uppercased()
            if name == "LOCATION" { location = parts[1]; continue }
            guard ["ST", "NT", "USN", "SERVER"].contains(name) else { continue }
            if name == "ST" || name == "NT", parts[1] == searchTarget { isLG = true }
            if searchTarget == allTarget, isLGHeader(parts[1]) { isLG = true }
            if isLGHeader(parts[1].replacingOccurrences(of: searchTarget, with: "")) { lgHeader = true }
        }
        guard isLG, let location, let url = URL(string: location), let host = url.host else { return nil }
        return SSDPHit(host: host, confirmed: lgHeader || url.port == 1990)
    }

    /// LG webOS TV'nin SSDP başlığı mı: ikinci ekran servisi, sunucu adında "webOS" (webOS 3: "... LGE WebOS TV ...")
    /// ya da cihaz kimliğinde "LGTV" (webOS 3: "uuid:LGTV2017..."). LG'nin TV olmayan cihazları sayılmaz.
    static func isLGHeader(_ value: String) -> Bool {
        let text = value.lowercased()
        return text.contains("webos") || text.contains("lgtv")
    }

    /// SSDP arama isteği; tek adrese gönderilirken HOST o adresi taşır (UPnP 1.1 tek adresli M-SEARCH).
    static func searchRequest(searchTarget: String, host: String) -> String {
        "M-SEARCH * HTTP/1.1\r\nHOST: \(host)\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(searchTarget)\r\n\r\n"
    }

    /// `unicast` verilirse istek çok noktaya yayın grubuna değil, bu adreslerin her birine ayrı gönderilir.
    static func collectHosts(searchTarget: String, timeout: Duration, unicast: [String]? = nil) -> [String] {
        collectHits(searchTarget: searchTarget, timeout: timeout, unicast: unicast).map(\.host)
    }

    static func collectHits(searchTarget: String, timeout: Duration, unicast: [String]? = nil) -> [SSDPHit] {
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

        var hits: [SSDPHit] = []
        let end = ContinuousClock.now + timeout
        var buffer = [UInt8](repeating: 0, count: 2048)
        while ContinuousClock.now < end {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            if let hit = hit(fromSSDPResponse: String(decoding: buffer[0..<count], as: UTF8.self), searchTarget: searchTarget) { hits.append(hit) }
        }
        return hits
    }

    /// TV'nin ağdaki adını (ör. "[LG] webOS TV UK7550") cihaz tanımından okur.
    private static func friendlyName(host: String) async -> String? {
        // webOS cihaz tanımı 1990 numaralı portta yayınlanır; okunamazsa genel ad kullanılır.
        guard let url = URL(string: "http://\(host):1990/"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return friendlyName(fromDescription: String(decoding: data, as: UTF8.self))
    }
}
