// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum TVBrand: String, Codable, Sendable {
    case lg, samsung
    /// Android TV: bilgisayar TV'yi denetlemez, TV uygulaması bilgisayarı kendisi bulur.
    case androidTV
}

public struct LGTV: Codable, Hashable, Sendable {
    public let name: String
    public let host: String
    public let brand: TVBrand

    public init(name: String, host: String, brand: TVBrand = .lg) {
        self.name = name
        self.host = host
        self.brand = brand
    }

    /// Eski kayıtlarda marka yoktur; hepsi LG'dir.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        brand = try container.decodeIfPresent(TVBrand.self, forKey: .brand) ?? .lg
    }
}

/// TV'de uygulama başlatabilen ve önplandaki uygulamayı söyleyebilen her şey.
public protocol TVControlling: AnyObject {
    func launch(appId: String, params: [String: Any]) async throws
    func foregroundAppId() async throws -> String
    func close()
}

/// LG TV ile SSAP (WebSocket) üzerinden konuşur. İlk bağlantıda TV ekranında izin sorulur;
/// dönen client-key saklanırsa sonraki bağlantılar sorusuz olur.
public final class SSAPClient: NSObject, TVControlling, URLSessionDelegate, @unchecked Sendable {
    public enum SSAPError: Error { case cannotConnect, rejected(String), badResponse }

    private let endpoints: [URL]
    private let approvalTimeout: Duration
    private let handshakeTimeout: Duration
    private var clientKey: String?
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var nextId = 1

    /// Önce şifreli (3001), olmazsa düz (3000) bağlantı denenir; eski webOS'lar yalnız 3000'i açar.
    public convenience init(tv: LGTV, clientKey: String?) {
        self.init(endpoints: Self.endpoints(host: tv.host), clientKey: clientKey)
    }

    /// Adres URL'ye dönüşmezse (ör. elle yazılmış "192.168.1.5:3000") liste boş kalır ve `connect` `cannotConnect`
    /// fırlatır. Eskiden burada zorla açılıyordu ve uygulama kapanıyordu.
    static func endpoints(host: String) -> [URL] {
        [URL(string: "wss://\(host):3001"), URL(string: "ws://\(host):3000")].compactMap { $0 }
    }

    init(endpoints: [URL], clientKey: String?, approvalTimeout: Duration = .seconds(60), handshakeTimeout: Duration = .seconds(5)) {
        self.endpoints = endpoints
        self.clientKey = clientKey
        self.approvalTimeout = approvalTimeout
        self.handshakeTimeout = handshakeTimeout
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    /// Eşleşir ve client-key'i döner. Kullanıcı TV'de onay verene kadar bekler (en çok 60 sn).
    public func connect() async throws -> String {
        for url in endpoints {
            let task = session.webSocketTask(with: url)
            task.resume()
            do {
                try await sendRegistration(on: task)
                let key = try await waitForRegistration(on: task)
                socket = task
                clientKey = key
                return key
            } catch SSAPError.rejected(let reason) {
                task.cancel()
                throw SSAPError.rejected(reason)
            } catch {
                task.cancel()
            }
        }
        throw SSAPError.cannotConnect
    }

    public func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        // URLSession temsilcisini (self) güçlü tutar; kapatılmazsa istemci hiç bırakılmaz.
        session.invalidateAndCancel()
    }

    public func launch(appId: String, params: [String: Any]) async throws {
        let response = try await request("ssap://system.launcher/launch", payload: ["id": appId, "params": params])
        if response["returnValue"] as? Bool == false { throw SSAPError.rejected(response["errorText"] as? String ?? "launch") }
    }

    public func foregroundAppId() async throws -> String {
        let response = try await request("ssap://com.webos.applicationManager/getForegroundAppInfo", payload: nil)
        return response["appId"] as? String ?? ""
    }

    // MARK: - İç işleyiş

    /// Adres artık başka bir cihazdaysa bağlantı yanıtsız kalabilir; o adreste uzun süre beklenmez.
    private func sendRegistration(on task: URLSessionWebSocketTask) async throws {
        let message = String(decoding: SSAPMessages.register(clientKey: clientKey), as: UTF8.self)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await task.send(.string(message)) }
            group.addTask { [handshakeTimeout] in
                try await Task.sleep(for: handshakeTimeout)
                task.cancel()
                throw SSAPError.cannotConnect
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// TV'deki izin sorusu yanıtlanana kadar bekler; `approvalTimeout` dolarsa vazgeçer.
    private func waitForRegistration(on task: URLSessionWebSocketTask) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                while true {
                    let message = try await Self.decode(task.receive())
                    switch message["type"] as? String {
                    case "registered":
                        guard let key = (message["payload"] as? [String: Any])?["client-key"] as? String else { throw SSAPError.badResponse }
                        return key
                    case "error":
                        throw SSAPError.rejected(message["error"] as? String ?? "register")
                    default:
                        continue // "response": TV soruyu gösterdi, onay bekleniyor
                    }
                }
            }
            group.addTask { [approvalTimeout] in
                try await Task.sleep(for: approvalTimeout)
                // receive() iptale yanıt vermez; soketi kapatmak onu da sonlandırır.
                task.cancel()
                throw SSAPError.rejected("timeout")
            }
            defer {
                group.cancelAll()
            }
            guard let key = try await group.next() else { throw SSAPError.badResponse }
            return key
        }
    }

    private func request(_ uri: String, payload: [String: Any]?) async throws -> [String: Any] {
        guard let socket else { throw SSAPError.cannotConnect }
        let id = "req_\(nextId)"
        nextId += 1
        try await socket.send(.string(String(decoding: SSAPMessages.request(id: id, uri: uri, payload: payload), as: UTF8.self)))
        while true {
            let message = try await Self.decode(socket.receive())
            guard message["id"] as? String == id else { continue }
            if message["type"] as? String == "error" { throw SSAPError.rejected(message["error"] as? String ?? uri) }
            return message["payload"] as? [String: Any] ?? [:]
        }
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: throw SSAPError.badResponse
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SSAPError.badResponse }
        return object
    }

    /// TV'nin 3001 portundaki sertifikası kendinden imzalıdır; yalnız bu TV'nin adresi için kabul edilir.
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let host = challenge.protectionSpace.host
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              endpoints.contains(where: { $0.host == host }),
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// TV uygulamasını açık tutar: TV kendi HDMI ya da yayın girişine geçerse (SimpLink/CEC) uygulamayı
/// yeniden öne getirir. TV kapalıysa ya da bağlantı koparsa bir sonraki kontrolde yeniden bağlanır.
public final class TVKeeper: @unchecked Sendable {
    private let connect: () async throws -> TVControlling
    private let appId: String
    private let params: [String: Any]
    private let appConnected: (@Sendable () -> Bool)?
    private let relaunchInterval: Duration
    private var control: TVControlling?
    private var loop: Task<Void, Never>?
    private var lastLaunch: ContinuousClock.Instant?

    /// `appConnected` verilirse (Samsung) TV'ye yalnız TV uygulaması bilgisayara bağlı değilken ve en çok
    /// `relaunchInterval`'da bir dokunulur: uygulama açılır, bağlantı hemen kapatılır. Samsung önplandaki uygulamayı
    /// söylemediği için sürekli açık "uzaktan kumanda" bağlantısı gereksizdi; birkaç saniyede bir yeniden kurulan
    /// bağlantı TV'de "uzaktan kumanda bağlandı" bildirimi çıkarıyor, PS5 kolunu düşürüyordu (#5).
    public init(connect: @escaping () async throws -> TVControlling, appId: String, params: [String: Any],
                appConnected: (@Sendable () -> Bool)? = nil, relaunchInterval: Duration = .seconds(30)) {
        self.connect = connect
        self.appId = appId
        self.params = params
        self.appConnected = appConnected
        self.relaunchInterval = relaunchInterval
    }

    /// Kullanıcının bilerek açtığı uygulamalara (Netflix vb.) dokunulmaz; yalnız giriş ve yayın ekranları.
    static func isInputOrLiveTV(_ appId: String) -> Bool {
        appId.hasPrefix("com.webos.app.hdmi") || appId.hasPrefix("com.webos.app.externalinput") || appId == "com.webos.app.livetv"
    }

    /// Bir kontrol. Hata fırlatmaz; bağlantı sorununda bir sonraki kontrolde yeniden dener.
    public func tick() async {
        if let appConnected {
            await launchIfAppIsAway(appConnected())
            return
        }
        do {
            if control == nil {
                let fresh = try await connect()
                control = fresh
                try await fresh.launch(appId: appId, params: params)
                return
            }
            guard let control else { return }
            let current = try await control.foregroundAppId()
            if Self.isInputOrLiveTV(current) { try await control.launch(appId: appId, params: params) }
        } catch {
            control?.close()
            control = nil
        }
    }

    private func launchIfAppIsAway(_ connected: Bool) async {
        guard !connected else { return }
        if let lastLaunch, ContinuousClock.now - lastLaunch < relaunchInterval { return }
        lastLaunch = .now
        guard let fresh = try? await connect() else { return }
        defer { fresh.close() }
        try? await fresh.launch(appId: appId, params: params)
    }

    public func start(interval: Duration = .seconds(5)) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Mac uykudan uyandığında: bağlantıyı yenile.
    public func reconnect() {
        control?.close()
        control = nil
        lastLaunch = nil
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        control?.close()
        control = nil
    }

    deinit { loop?.cancel() }
}
