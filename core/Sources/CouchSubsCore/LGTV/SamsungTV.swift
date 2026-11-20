// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Samsung uzaktan kumanda WebSocket'inin iletileri. Samsung bunu belgelemez; alanlar topluluk kaynaklarından.
enum SamsungMessages {
    /// Adres geçersizse nil (bağlantı `cannotConnect` ile biter; eskiden zorla açılıp uygulamayı kapatıyordu).
    static func url(host: String, token: String?) -> URL? {
        let name = Data("CouchSubs".utf8).base64EncodedString()
        var text = "wss://\(host):8002/api/v2/channels/samsung.remote.control?name=\(name)"
        if let token, !token.isEmpty { text += "&token=\(token)" }
        return URL(string: text)
    }

    /// TV uygulaması parametreleri `PAYLOAD` içinde alır (bkz. tv-tizen/platform.js).
    static func launch(appId: String, params: [String: Any]) -> Data {
        let meta = (try? JSONSerialization.data(withJSONObject: params)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let message: [String: Any] = [
            "method": "ms.channel.emit",
            "params": ["event": "ed.apps.launch", "to": "host",
                       "data": ["appId": appId, "action_type": "DEEP_LINK", "metaTag": meta]],
        ]
        return (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
    }

    /// Bağlantı sonucu: onaylandıysa jeton (TV vermediyse boş), reddedildiyse ya da soru zaman aşımına uğradıysa hata.
    static func connectResult(_ text: String) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        switch object["event"] as? String {
        case "ms.channel.connect":
            return ((object["data"] as? [String: Any])?["token"] as? String) ?? ""
        case "ms.channel.unauthorized":
            throw SamsungClient.SamsungError.rejected
        case "ms.channel.timeOut":
            // TV'deki izin sorusu yanıtsız kaldı; 60 saniye boşuna beklenmez.
            throw SamsungClient.SamsungError.cannotConnect
        default:
            return nil
        }
    }

    /// `http://TV:8001/api/v2/` yanıtındaki TV adı.
    static func deviceName(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["device"] as? [String: Any], let name = device["name"] as? String else { return nil }
        return name.replacingOccurrences(of: "&quot;", with: "\"")
    }

    /// 8001 yanıtında geliştirici modu açık mı (`device.developerMode`: "1"/"0"); bildirilmezse nil.
    static func developerMode(_ data: Data) -> Bool? {
        guard let value = deviceField(data, "developerMode") else { return nil }
        return value == "1" || value.lowercased() == "true"
    }

    /// TV'nin geliştirici modundaki "Host PC IP" (`device.developerIP`); boş ya da "0.0.0.0" ise nil.
    static func developerIp(_ data: Data) -> String? {
        guard let value = deviceField(data, "developerIP"), value != "0.0.0.0" else { return nil }
        return value
    }

    private static func deviceField(_ data: Data, _ name: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["device"] as? [String: Any], let raw = device[name] else { return nil }
        let text = (raw as? String ?? "\(raw)").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

/// Samsung TV'nin 8001 yanıtındaki geliştirici modu bilgisi.
public struct SamsungDeveloperInfo: Equatable, Sendable {
    /// Geliştirici modu açık mı; TV bildirmezse nil.
    public var developerMode: Bool?
    /// TV'deki "Host PC IP"; boşsa nil.
    public var developerIp: String?
    public init(developerMode: Bool?, developerIp: String?) {
        self.developerMode = developerMode
        self.developerIp = developerIp
    }

    /// TV'deki Host PC IP bu bilgisayarın adresinden farklı mı? Biri bilinmiyorsa farklı sayılmaz (#343).
    public static func hostPcIpMismatch(developerIp: String?, computer: String?) -> Bool {
        guard let ip = developerIp?.trimmingCharacters(in: .whitespaces), !ip.isEmpty,
              let mine = computer?.trimmingCharacters(in: .whitespaces), !mine.isEmpty else { return false }
        return ip != mine
    }

    /// sdb (26101) bağlantısı reddedilince TV'nin kendi söylediği duruma göre neden: geliştirici modu kapalı, Host PC IP
    /// başka bir cihazın, ya da ayar doğru olduğu hâlde TV o zamandan beri tam yeniden başlamamış (sdb sunucusu yalnız
    /// açılışta başlar; TV kapanınca güç tuşunu bırakmak yalnız bekleme moduna geçirir, #524, #484).
    public static func refusal(developerMode: Bool?, developerIp: String?, device: String?) -> SamsungRefusal {
        switch developerMode {
        case false?: return .developerModeOff
        case true?:
            if hostPcIpMismatch(developerIp: developerIp, computer: device), let ip = developerIp {
                return .otherHostIp(ip.trimmingCharacters(in: .whitespaces))
            }
            let ip = developerIp?.trimmingCharacters(in: .whitespaces)
            let mine = device?.trimmingCharacters(in: .whitespaces)
            return ip != nil && ip == mine ? .notRestarted : .unknown
        case nil: return .unknown
        }
    }
}

/// Samsung TV'nin sdb bağlantısını neden reddettiği (8001'deki geliştirici modu bilgisine göre).
public enum SamsungRefusal: Equatable, Sendable {
    case developerModeOff
    case otherHostIp(String)
    /// Geliştirici modu açık ve Host PC IP bu cihaz; TV ayardan sonra tam yeniden başlamamış.
    case notRestarted
    case unknown
}

/// Bekçinin (TVKeeper) Samsung bağlantılarında kullandığı jeton. TV yeni jeton verirse bir sonraki bağlantı onu kullanır
/// ve `onChange` ile saklanır; önceden yalnız eşleşmedeki jeton kullanılıyor, sonradan gelen atılıyordu.
public final class SamsungTokenHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private let onChange: (String) -> Void

    public init(token: String?, onChange: @escaping (String) -> Void) {
        self.token = token
        self.onChange = onChange
    }

    public var current: String? { lock.withLock { token } }

    /// Bağlantıda TV'nin döndüğü jeton; boşsa ya da aynıysa bir şey değişmez.
    public func received(_ value: String) {
        let changed: Bool = lock.withLock {
            let kept = Self.keptToken(stored: token, received: value)
            guard kept != (token ?? "") else { return false }
            token = kept
            return true
        }
        if changed { onChange(value) }
    }

    /// Saklanacak jeton. TV yeni jeton verdiyse o; vermediyse (boş döndü, bazı TV'ler jetonla gelen bağlantıda yeniden
    /// göndermez) eldeki korunur. Boş jeton eldekinin üstüne yazılınca sonraki her bağlantıda TV yeniden izin soruyordu (#40).
    public static func keptToken(stored: String?, received: String) -> String {
        received.isEmpty ? (stored ?? "") : received
    }
}

/// Samsung TV ile uzaktan kumanda WebSocket'i üzerinden konuşur. İlk bağlantıda TV izin sorar.
public final class SamsungClient: NSObject, TVControlling, URLSessionDelegate, @unchecked Sendable {
    public enum SamsungError: Error { case cannotConnect, rejected }

    private let url: URL?
    private let approvalTimeout: Duration
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?

    public convenience init(tv: LGTV, token: String?) {
        self.init(url: SamsungMessages.url(host: tv.host, token: token))
    }

    /// `url` nil ise (geçersiz adres) `connect` `cannotConnect` fırlatır.
    init(url: URL?, approvalTimeout: Duration = .seconds(60)) {
        self.url = url
        self.approvalTimeout = approvalTimeout
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    /// Bağlanır ve jetonu döner. Kullanıcı TV'de onay verene kadar bekler.
    public func connect() async throws -> String {
        guard let url else { throw SamsungError.cannotConnect }
        let task = session.webSocketTask(with: url)
        task.resume()
        let token = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                while true {
                    let message = try await task.receive()
                    let text: String
                    switch message {
                    case .string(let value): text = value
                    case .data(let value): text = String(decoding: value, as: UTF8.self)
                    @unknown default: continue
                    }
                    if let token = try SamsungMessages.connectResult(text) { return token }
                }
            }
            group.addTask { [approvalTimeout] in
                try await Task.sleep(for: approvalTimeout)
                task.cancel()
                throw SamsungError.cannotConnect
            }
            defer { group.cancelAll() }
            guard let token = try await group.next() else { throw SamsungError.cannotConnect }
            return token
        }
        socket = task
        return token
    }

    public func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session.invalidateAndCancel()
    }

    public func launch(appId: String, params: [String: Any]) async throws {
        guard let socket else { throw SamsungError.cannotConnect }
        try await socket.send(.string(String(decoding: SamsungMessages.launch(appId: appId, params: params), as: UTF8.self)))
    }

    /// Samsung önplandaki uygulamayı söylemez; bağlantı ayakta mı diye bakılır, boş döner.
    public func foregroundAppId() async throws -> String {
        guard let socket else { throw SamsungError.cannotConnect }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return ""
    }

    /// TV'nin 8002 portundaki sertifikası kendinden imzalıdır; yalnız bu TV'nin adresi için kabul edilir.
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let host = url?.host, challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Yerel ağdaki Samsung TV'leri SSDP ile bulur.
public enum SamsungDiscovery {
    static let searchTarget = "urn:samsung.com:device:RemoteControlReceiver:1"

    /// TV'nin geliştirici modu bilgisi (`http://TV:8001/api/v2/`); TV yanıt vermezse nil.
    public static func developerInfo(host: String) async -> SamsungDeveloperInfo? {
        guard let url = URL(string: "http://\(host):8001/api/v2/"),
              let (data, _) = try? await LocalNetwork.probeSession.data(from: url) else { return nil }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return SamsungDeveloperInfo(developerMode: SamsungMessages.developerMode(data), developerIp: SamsungMessages.developerIp(data))
    }

    public static func search(timeout: Duration = .seconds(3)) async -> [LGTV] {
        let hosts = await Task.detached { LGDiscovery.collectHosts(searchTarget: searchTarget, timeout: timeout) }.value
        // SSDP'ye cevap veren her Samsung cihazı TV değil: soundbar da aynı hedefi yanıtlıyor ama 8001'de
        // kendini tanıtmıyor. Yalnız 8001/api/v2/ yanıtını verenler TV sayılır; aksi hâlde uygulama
        // yanlış cihazı listeliyor ve "TV yanıt vermedi" diyordu.
        var tvs: [LGTV] = []
        for host in Set(hosts).sorted() {
            if let name = await name(host: host) {
                tvs.append(LGTV(name: name, host: host, brand: .samsung))
            }
        }
        if !tvs.isEmpty { return tvs }

        // SSDP'den TV çıkmadıysa (yalnız başka bir Samsung cihazı cevapladı ya da çok noktaya yayın geçmiyor)
        // ağdaki adresler tek tek denenir: Samsung TV 8001 portunda kendi adını veren bir arayüz sunar.
        let scanned = await scan()
        if !scanned.isEmpty { return scanned }

        // 8001 kapalı ama SSDP'ye cevap veren bir TV de olabilir: adı bilinmeyen olarak listelenir.
        return Set(hosts).sorted().map { LGTV(name: "Samsung TV", host: $0, brand: .samsung) }
    }

    /// Elle yazılan adresteki Samsung TV (8001'de kendini tanıtırsa); yoksa nil.
    public static func tv(at host: String) async -> LGTV? {
        guard let name = await name(host: host, session: LocalNetwork.probeSession) else { return nil }
        return LGTV(name: name, host: host, brand: .samsung)
    }

    private static func scan() async -> [LGTV] {
        await LocalNetwork.probeAll { host in await name(host: host, session: LocalNetwork.probeSession) }
            .map { LGTV(name: $0.value, host: $0.host, brand: .samsung) }
    }

    private static func name(host: String, session: URLSession = .shared) async -> String? {
        guard let url = URL(string: "http://\(host):8001/api/v2/"),
              let (data, _) = try? await session.data(from: url) else { return nil }
        return SamsungMessages.deviceName(data)
    }
}
