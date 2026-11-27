// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum TVBrand: String, Codable, Sendable {
    case lg, samsung
    /// Android TV: bilgisayar TV'yi denetlemez, TV uygulaması bilgisayarı kendisi bulur.
    case androidTV
    /// Vestel'in kendi Linux'u (Android değil; ör. MB130 anakartlı 2017 modelleri); deneysel. TV'de çalışan yerel
    /// DirectFB istemcisi (`tv-vestel/`) bu bilgisayara kendisi bağlanır ve TV uygulamaları gibi eşleşir (`/pair`).
    /// Bilgisayar TV'ye bir şey kurmaz ve TV'yi denetlemez; istemci şimdilik TV'ye elle kopyalanır.
    case vestelLinux

    /// TV uygulaması bilgisayara kendisi bağlanır; bilgisayar TV'de uygulama açamaz (Android TV, Vestel Linux).
    public var connectsByItself: Bool { self == .androidTV || self == .vestelLinux }
}

public struct LGTV: Codable, Hashable, Sendable {
    public let name: String
    public let host: String
    public let brand: TVBrand
    /// Cihazın kalıcı kimliği (SSDP USN / cihaz tanımı UDN, Samsung `device.id`, Android TV'de Google Cast UDN), küçük harf
    /// ve "uuid:" öneki olmadan. Modem TV'ye yeni adres verince TV bununla tanınır (ad değişse de, aynı adlı iki TV olsa
    /// da). Eski kayıtlarda yoktur; TV ilk kez ağda bulununca öğrenilir (bkz. `TVLocator.learned`).
    public let uuid: String?
    /// TV'nin MAC adresi (Samsung `device.wifiMac`; biliniyorsa), "aa:bb:cc:dd:ee:ff" biçiminde.
    public let mac: String?

    public init(name: String, host: String, brand: TVBrand = .lg, uuid: String? = nil, mac: String? = nil) {
        self.name = name
        self.host = host
        self.brand = brand
        self.uuid = TVIdentity.normalizedUUID(uuid)
        self.mac = TVIdentity.normalizedMAC(mac)
    }

    /// Eski kayıtlarda marka yoktur; hepsi LG'dir. Kimlik (uuid, mac) eski kayıtlarda yoktur.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        brand = try container.decodeIfPresent(TVBrand.self, forKey: .brand) ?? .lg
        uuid = TVIdentity.normalizedUUID(try container.decodeIfPresent(String.self, forKey: .uuid))
        mac = TVIdentity.normalizedMAC(try container.decodeIfPresent(String.self, forKey: .mac))
    }

    /// Aynı TV yeni adreste.
    public func withHost(_ newHost: String) -> LGTV { LGTV(name: name, host: newHost, brand: brand, uuid: uuid, mac: mac) }

    /// Bilinmeyen kimlik alanları `other`dan tamamlanır (ad, adres ve marka bu kaydınki kalır).
    public func identified(from other: LGTV) -> LGTV {
        LGTV(name: name, host: host, brand: brand, uuid: uuid ?? other.uuid, mac: mac ?? other.mac)
    }

    /// Kimliği (uuid ya da mac) var mı.
    public var hasIdentity: Bool { uuid != nil || mac != nil }
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
///
/// Kullanıcı TV'de bilerek başka girişe geçiyorsa zorlanmaz: uygulama `standDownAfter` kez `standDownWindow` içinde
/// girişten geri getirildiyse ve TV yine girişteyse bekçi çekilir ("PS kapalıyken HDMI değiştirince TV sürekli
/// CouchSubs'a geri atıyor"). Kullanıcı CouchSubs'ı TV'de kendisi açınca, bağlantı yenilenince ya da çeviri yeniden
/// başlayınca bekçi işine döner. SimpLink/CEC'in bir iki kez girişe geçirmesi sınırın altında kalır (Windows ile aynı).
///
/// PS tuşu (HDMI-CEC "One Touch Play") TV'yi konsolun kendi HDMI girişine geçirir; oyunda PS menüsü her açıldığında olur.
/// TV uygulaması gösterdiği girişi bildirdiyse (`consolePort`) o girişe geçiş kullanıcı ısrarı sayılmaz, uygulama her
/// seferinde geri getirilir; yalnız bir dakikada `consoleLoopLimit` kez olursa (bitmeyen CEC döngüsü) bekçi çekilir. Başka
/// HDMI numarası ve yayın eskisi gibi sayılır, başka uygulamalara (Netflix) dokunulmaz. LG'de önplan `foregroundPoll`'da
/// bir sorulur: eskiden 5 sn'de bir soruluyordu, PS tuşundan sonra çeviri 5-6 sn ekrandan gidiyordu ve kısa sürede dört
/// PS basışı bekçiyi çekiyordu (X, Kas 2026; Windows ve Android ile aynı).
public final class TVKeeper: @unchecked Sendable {
    /// Bu kadar zorla geri getirmeden sonra TV yine girişteyse bekçi çekilir.
    public static let standDownAfter = 3
    public static let standDownWindow: Duration = .seconds(90)
    /// LG'de önplandaki uygulamanın sorulma aralığı (açık SSAP bağlantısında tek istek; TV'de bir şey göstermez).
    public static let foregroundPoll: Duration = .seconds(1)
    /// Geri getirdikten sonra bu kadar beklenir: TV uygulamayı öne alırken önplan bir an eski girişi gösterir.
    public static let launchSettle: Duration = .seconds(2)
    /// Konsol girişinden bir dakikada bu kadar geri getirmeden sonra bekçi çekilir (bitmeyen CEC döngüsü).
    public static let consoleLoopLimit = 10
    public static let consoleLoopWindow: Duration = .seconds(60)
    private let now: () -> ContinuousClock.Instant
    /// Uygulamanın girişten geri getirildiği anlar (pencere içindekiler).
    private var forced: [ContinuousClock.Instant] = []
    /// Uygulamanın konsol girişinden (PS tuşu) geri getirildiği anlar.
    private var consoleReturns: [ContinuousClock.Instant] = []
    private var lastForced: ContinuousClock.Instant?
    /// Kullanıcı girişte kalmakta ısrar etti; bekçi uygulamayı öne getirmiyor.
    public private(set) var stoodDown = false
    private let connect: () async throws -> TVControlling
    private let appId: String
    private let params: [String: Any]
    private let appConnected: (@Sendable () -> Bool)?
    private let consolePort: (@Sendable () -> Int?)?
    /// Her açma denemesinin sonucu: açıldıysa nil, TV'ye ulaşılamadıysa ya da açamadıysa `.unreachable` (ana ekrandaki satır).
    private let onOpenResult: (@Sendable (TVOpenProblem?) -> Void)?
    private var control: TVControlling?
    private var loop: Task<Void, Never>?
    /// Samsung: ne zaman açılacağı (seyrelen aralık ve üst sınır; `reconnect` sıfırlar).
    private var samsungRule: SamsungOpenRule
    /// Samsung: sınır dolunca günlüğe bir kez yazılır.
    private var exhaustedLogged = false
    /// `samsungRule`'un tekdüze saatinin başlangıcı.
    private let started: ContinuousClock.Instant
    /// Samsung: son açma komutunun gittiği an (uygulama bağlanınca ya da "TV açmadı" bildirilince sıfırlanır).
    private var sentAt: ContinuousClock.Instant?
    private var lastReported: TVOpenProblem?
    private var reportedOnce = false
    /// LG: TV uygulaması bilgisayara/telefona bağlı mı (altyazı akışı açık). Verilirse açık ve bağlı uygulamaya yeni
    /// kurulan bağlantıda açma komutu gitmez (bkz. `reopenBackoff`).
    private let tvConnected: (@Sendable () -> Bool)?
    /// LG: bu bekçi uygulamayı bir kez açtı (ya da açık ve bağlı buldu).
    private var opened = false
    /// LG: uygulama kurulumdan sonra kapatıldı (`reopenApp`); yeni bağlantıda bağlı görünse de açılır.
    private var launchAfterClose = false
    /// LG: yeniden kurulan bağlantıdaki açmaların sayısı (geri çekilme için) ve sonuncusunun anı.
    private var reopens = 0
    private var lastReopen: ContinuousClock.Instant?
    /// LG: uygulamanın kesintisiz bağlı görüldüğü ilk an (`healthyReset` dolunca geri çekilme sıfırlanır).
    private var connectedSince: ContinuousClock.Instant?

    /// LG'de yeniden kurulan SSAP bağlantısında (TV kapanıp açıldı, bağlantı koptu, alındı kesildi) iki açma arasındaki
    /// en kısa süre: ilk yeniden açma hemen, sonra 30 sn, 1, 2, 5 dk. #1055 (beta.86, LG OLED C4): bekçi her yeni
    /// bağlantıda, uygulama açık ve bağlıyken de `system.launcher/launch` gönderiyordu; webOS uygulamayı yeniden başlatıp
    /// HDMI görüntüsünü yeniden kuruyor, ekran kararıp "HDR" yazısıyla geri geliyordu. Alındı denetimi her kopuşta bekçiyi
    /// yenilediği için bu, çeviri başlarken 6-7 kez ve sonra aralıklı oldu. Windows ve Android ile aynı.
    public static let reopenBackoff: [Duration] = [.seconds(30), .seconds(60), .seconds(120), .seconds(300)]
    /// Uygulama bu kadar kesintisiz bağlı kalınca geri çekilme sıfırlanır.
    public static let healthyReset: Duration = .seconds(600)

    /// `appConnected` verilirse (Samsung) TV'ye yalnız TV uygulaması bilgisayara bağlı değilken dokunulur: uygulama açılır,
    /// bağlantı hemen kapatılır. Samsung önplandaki uygulamayı söylemediği için sürekli açık "uzaktan kumanda" bağlantısı
    /// gereksizdi; birkaç saniyede bir yeniden kurulan bağlantı TV'de "uzaktan kumanda bağlandı" bildirimi çıkarıyor, PS5
    /// kolunu düşürüyordu (#5). Denemeler `relaunchInterval`'dan başlayıp seyrelir ve sınırlıdır (bkz. `SamsungOpenRule`).
    /// `consolePort`: TV uygulamasının gösterdiği HDMI girişi (1-4; altyazı akışına bağlanırken bildirir), bilinmiyorsa nil.
    public init(connect: @escaping () async throws -> TVControlling, appId: String, params: [String: Any],
                appConnected: (@Sendable () -> Bool)? = nil, relaunchInterval: Duration = .seconds(30),
                consolePort: (@Sendable () -> Int?)? = nil,
                onOpenResult: (@Sendable (TVOpenProblem?) -> Void)? = nil,
                tvConnected: (@Sendable () -> Bool)? = nil,
                now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
        self.tvConnected = tvConnected
        self.onOpenResult = onOpenResult
        self.connect = connect
        self.appId = appId
        self.params = params
        self.appConnected = appConnected
        self.consolePort = consolePort
        self.samsungRule = SamsungOpenRule(interval: Self.seconds(relaunchInterval))
        self.started = now()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Kullanıcının bilerek açtığı uygulamalara (Netflix vb.) dokunulmaz; yalnız giriş ve yayın ekranları.
    static func isInputOrLiveTV(_ appId: String) -> Bool {
        appId.hasPrefix("com.webos.app.hdmi") || appId.hasPrefix("com.webos.app.externalinput") || appId == "com.webos.app.livetv"
    }

    /// Önplandaki uygulama, TV uygulamasının gösterdiği HDMI girişi mi (LG: `com.webos.app.hdmi2`).
    static func isConsoleInput(_ appId: String, port: Int?) -> Bool {
        guard let port, (1...4).contains(port) else { return false }
        return appId == "com.webos.app.hdmi\(port)"
    }

    /// Kontrol aralığı: LG'de PS tuşundan sonra en geç ~2 sn'de geri gelinsin diye en çok `foregroundPoll`; Samsung'da
    /// verilen aralık (TV'ye yine en çok `relaunchInterval`'da bir dokunulur).
    public func pollInterval(_ requested: Duration) -> Duration {
        appConnected == nil && requested > Self.foregroundPoll ? Self.foregroundPoll : requested
    }

    /// Bir kontrol. Hata fırlatmaz; bağlantı sorununda bir sonraki kontrolde yeniden dener.
    public func tick() async {
        if let appConnected {
            await launchIfAppIsAway(appConnected())
            return
        }
        let opening = control == nil
        do {
            if control == nil {
                let fresh = try await connect()
                control = fresh
                if tvConnected != nil {
                    try await openOnFreshConnection(fresh)
                    return
                }
                try await fresh.launch(appId: appId, params: params)
                onOpenResult?(nil)
                return
            }
            guard let control else { return }
            let time = now()
            noteHealth(at: time)
            if let lastForced, time - lastForced < Self.launchSettle { return }
            let current = try await control.foregroundAppId()
            if current == appId {
                // Uygulama önde. Bekçi çekilmişken öndeyse kullanıcı onu kendisi açmıştır: bekçi işine döner.
                if stoodDown {
                    stoodDown = false
                    forced.removeAll()
                    consoleReturns.removeAll()
                }
                return
            }
            guard Self.isInputOrLiveTV(current), !stoodDown else { return }
            if Self.isConsoleInput(current, port: consolePort?()) {
                // PS tuşu: konsol TV'yi kendi girişine geçirdi. Kullanıcı ısrarı sayılmaz, hemen geri getirilir.
                consoleReturns.removeAll { time - $0 > Self.consoleLoopWindow }
                if consoleReturns.count >= Self.consoleLoopLimit {
                    stoodDown = true
                    return
                }
                consoleReturns.append(time)
                lastForced = time
                try await control.launch(appId: appId, params: params)
                return
            }
            forced.removeAll { time - $0 > Self.standDownWindow }
            if forced.count >= Self.standDownAfter {
                stoodDown = true
                return
            }
            forced.append(time)
            lastForced = time
            try await control.launch(appId: appId, params: params)
        } catch {
            // Bağlanıp açma denemesi olmadıysa (TV kapalı, başka ağda, açmayı reddetti) bildirilir; açık bağlantının
            // kopması bir sonraki denemede bildirilir.
            if opening { onOpenResult?(.unreachable) }
            control?.close()
            control = nil
        }
    }

    /// LG, yeni kurulan SSAP bağlantısı (`tvConnected` verildiyse). Açık ve bağlı uygulamaya açma komutu gitmez: webOS önde
    /// çalışan uygulamayı da yeniden başlatıyor, HDMI görüntüsü yeniden kuruluyordu (#1055). İlk açılışta uygulama bağlı
    /// değilse eskisi gibi bir kez açılır (adres ve anahtar parametreyle gider). Sonraki bağlantılarda uygulama bağlı
    /// değilse (kapandı, arka plana düştü ya da önde ama yanıtsız) `reopenBackoff` aralığıyla açılır; aralık dolmadıysa
    /// bir sonraki kontrol önplana bakar (PS tuşundan dönüş eskisi gibi).
    private func openOnFreshConnection(_ fresh: TVControlling) async throws {
        let time = now()
        noteHealth(at: time)
        if launchAfterClose {
            // Kurulumdan sonra uygulama kapatıldı: sunucu kopan akışı henüz fark etmemiş olabilir, bağlı sayılmaz.
            launchAfterClose = false
            try await fresh.launch(appId: appId, params: params)
            opened = true
            onOpenResult?(nil)
            return
        }
        if tvConnected?() == true {
            opened = true
            onOpenResult?(nil)
            return
        }
        if !opened {
            try await fresh.launch(appId: appId, params: params)
            opened = true
            onOpenResult?(nil)
            return
        }
        if let lastReopen, reopens > 0,
           time - lastReopen < Self.reopenBackoff[min(reopens - 1, Self.reopenBackoff.count - 1)] {
            onOpenResult?(nil)
            return
        }
        reopens += 1
        lastReopen = time
        lastForced = time
        try await fresh.launch(appId: appId, params: params)
        onOpenResult?(nil)
    }

    /// Uygulama `healthyReset` boyunca kesintisiz bağlı kaldıysa yeniden açmanın geri çekilmesi sıfırlanır.
    private func noteHealth(at time: ContinuousClock.Instant) {
        guard let tvConnected else { return }
        guard tvConnected() else {
            connectedSince = nil
            return
        }
        let since = connectedSince ?? time
        connectedSince = since
        if time - since >= Self.healthyReset {
            reopens = 0
            lastReopen = nil
        }
    }

    /// Samsung'da açma komutu gittikten sonra TV uygulamasının bağlanması için beklenen süre; bağlanmazsa ana ekranda
    /// "TV açmadı" yazar. Samsung `ed.apps.launch`'a yanıt vermez ya da yanıtı açılışı söylemez: bazı TV'ler (Tizen 9.0,
    /// Windows'ta #412; iPhone'da Samsung, 21 Kas) komutu alıp uygulamayı açmıyor, ekranda "açıldı" sanılıyor, neden satırı
    /// boş kalıyordu.
    public static let samsungOpenCheck: Duration = .seconds(15)

    private func launchIfAppIsAway(_ connected: Bool) async {
        let time = now()
        let tryNow = samsungRule.shouldTry(connected: connected, now: Self.seconds(time - started))
        guard !connected else {
            sentAt = nil
            return
        }
        if let sentAt, time - sentAt >= Self.samsungOpenCheck {
            self.sentAt = nil
            report(.notOpened)
        }
        guard tryNow else {
            if samsungRule.exhausted, !exhaustedLogged {
                exhaustedLogged = true
                SubtitleLog.write("TV uygulamasını açma (\(appId)): \(samsungRule.maxAttempts) denemede bağlanmadı, otomatik açma durdu (\"TV'de aç\" ya da çeviriyi yeniden başlatmak yeniden dener)")
            }
            return
        }
        let attempt = "\(samsungRule.attempts)/\(samsungRule.maxAttempts)"
        guard let fresh = try? await connect() else {
            SubtitleLog.write("TV uygulamasını açma denemesi \(attempt) (\(appId)): TV'ye bağlanılamadı")
            report(.unreachable)
            return
        }
        defer { fresh.close() }
        var notInstalled = false
        let opened: Bool
        do {
            try await fresh.launch(appId: appId, params: params)
            opened = true
        } catch {
            // Samsung: TV kurulu olduğunu doğrulamadı, açma komutu gönderilmedi (kurulum gerekiyor; TV yanıt verdi).
            notInstalled = (error as? SamsungClient.SamsungError) == .notInstalled
            opened = false
        }
        SubtitleLog.write("TV uygulamasını açma denemesi \(attempt) (\(appId)): \(opened ? "açma komutu gitti" : notInstalled ? "kurulu değil" : "TV açma komutunu almadı")")
        if opened {
            sentAt = now()
            // TV bir önceki komutta da açmadıysa neden satırı yeniden gönderilen komutla silinmez (her 30 sn'de yanıp sönmesin).
            if lastReported == .notOpened { return }
        }
        report(opened ? nil : notInstalled ? .notInstalled : .unreachable)
    }

    /// Sonuç ana ekrana gider; değiştiğinde subtitles.log'a da yazılır (eskiden Samsung'da açma denemesi iz bırakmıyordu).
    private func report(_ problem: TVOpenProblem?) {
        if problem != lastReported || !reportedOnce {
            SubtitleLog.write("TV uygulamasını açma (\(appId)): \(problem.map { "olmadı, \($0.rawValue)" } ?? "açma komutu gitti")")
        }
        lastReported = problem
        reportedOnce = true
        onOpenResult?(problem)
    }

    public func start(interval: Duration = .seconds(5)) {
        loop?.cancel()
        let delay = pollInterval(interval)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// Mac uykudan uyandığında: bağlantıyı yenile.
    public func reconnect() {
        control?.close()
        control = nil
        samsungRule.reset()
        exhaustedLogged = false
        sentAt = nil
        lastReported = nil
        stoodDown = false
        forced.removeAll()
        consoleReturns.removeAll()
        lastForced = nil
    }

    /// LG: TV uygulaması kurulumdan sonra (ya da eski sürümde çalıştığı için) kapatıldı; bağlantı yeniden kurulur ve uygulama
    /// bağlı görünse de bir kez açılır (adres ve anahtar parametreyle). Windows TvKeeper.ReopenApp ile aynı.
    public func reopenApp() {
        reconnect()
        launchAfterClose = true
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        control?.close()
        control = nil
    }

    deinit { loop?.cancel() }
}
