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

    /// TV uygulaması parametreleri `PAYLOAD` içinde alır (bkz. tv-tizen/platform.js). `actionType` TV'nin uygulama
    /// listesinde bildirdiği türe göre seçilir (`actionType(appType:)`); bilinmiyorsa DEEP_LINK.
    static func launch(appId: String, params: [String: Any], actionType: String = "DEEP_LINK") -> Data {
        let meta = (try? JSONSerialization.data(withJSONObject: params)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let message: [String: Any] = [
            "method": "ms.channel.emit",
            "params": ["event": "ed.apps.launch", "to": "host",
                       "data": ["appId": appId, "action_type": actionType, "metaTag": meta]],
        ]
        return (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
    }

    /// TV'de kurulu uygulamaların listesini ister. Yanıt aynı olay adıyla gelir; listede geliştirici modunda kurulan
    /// (mağazada olmayan) uygulamalar da bulunur.
    static let installedAppsRequest = #"{"method":"ms.channel.emit","params":{"event":"ed.installedApp.get","to":"host"}}"#

    /// Kurulu uygulama listesi yanıtında `appId` var mı. Yanıt bu değilse nil; varsa TV'nin bildirdiği `app_type` ile.
    static func installedApp(_ text: String, appId: String) -> SamsungAppPresence? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["event"] as? String == "ed.installedApp.get",
              let apps = (object["data"] as? [String: Any])?["data"] as? [[String: Any]] else { return nil }
        guard let app = apps.first(where: { $0["appId"] as? String == appId }) else { return .missing }
        return .installed(appType: app["app_type"] as? Int)
    }

    /// `ed.apps.launch` açılış türü: TV'nin listesinde `app_type` 4 (yerel Tizen uygulaması) NATIVE_LAUNCH, 2 (web
    /// uygulaması; CouchSubs .wgt paketi) ve bilinmeyen DEEP_LINK.
    static func actionType(appType: Int?) -> String { appType == 4 ? "NATIVE_LAUNCH" : "DEEP_LINK" }

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

/// TV'nin kurulu uygulama listesine göre CouchSubs TV uygulamasının durumu.
enum SamsungAppPresence: Equatable, Sendable {
    case missing
    case installed(appType: Int?)
}

/// Bir sürekliliği yalnız bir kez sürdürür (okuma ile zaman aşımı yarışır).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SamsungAppPresence?, Never>?

    init(_ continuation: CheckedContinuation<SamsungAppPresence?, Never>) { self.continuation = continuation }

    var done: Bool { lock.withLock { continuation == nil } }

    func resume(_ value: SamsungAppPresence?) {
        let pending: CheckedContinuation<SamsungAppPresence?, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
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
    /// `tv` verilirse önce ağ denetlenir: TV ile bu cihaz farklı /24 ağındaysa (#484'te 192.168.1.x ve 192.168.0.x; ikinci
    /// modem, mesh ya da misafir ağı) Host PC IP doğru yazılsa da TV bağlantıyı reddeder.
    public static func refusal(developerMode: Bool?, developerIp: String?, device: String?, tv: String? = nil) -> SamsungRefusal {
        if let tv, let device, differentNetworks(tv, device) { return .differentNetworks(tv: tv, device: device) }
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

extension SamsungDeveloperInfo {
    /// İki IPv4 adresi farklı /24 ağında mı? Adreslerden biri IPv4 değilse farklı sayılmaz.
    public static func differentNetworks(_ a: String, _ b: String) -> Bool {
        func prefix(_ text: String) -> [Int]? {
            let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard parts.count == 4, parts.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) <= 255 }) else { return nil }
            return parts.prefix(3).compactMap { $0 }
        }
        guard let left = prefix(a), let right = prefix(b) else { return false }
        return left != right
    }
}

/// Samsung TV'nin sdb bağlantısını neden reddettiği (8001'deki geliştirici modu bilgisine göre).
public enum SamsungRefusal: Equatable, Sendable {
    /// TV ile bu cihaz farklı ağlarda (adresleri farklı /24'te).
    case differentNetworks(tv: String, device: String)
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

/// CouchSubs TV uygulamasının kurulu olduğu bilinen Samsung TV'ler: uygulama o TV'den daha önce bağlandı ya da bu cihaz
/// oraya kurdu. Böyle bir TV'de açma komutundan önce TV'nin kurulu uygulama listesine bakılmaz (bkz.
/// `SamsungClient.launch`): listenin geliştirici moduyla kurulan uygulamayı içerdiği gerçek TV'de doğrulanmadı;
/// içermiyorsa bekçi uygulamayı hiç açmıyor, TV kendi girişine geçince (Anynet+) altyazı geri gelmiyordu.
/// Bilgi `UserDefaults`'ta saklanır (Windows'taki SamsungAppKnowledge ile aynı kural).
public final class SamsungAppKnowledge: @unchecked Sendable {
    public static let shared = SamsungAppKnowledge()
    static let storeKey = "samsungAppKnownHosts"

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var hosts: Set<String>
    private var probed = false

    /// `defaults` nil ise bilgi yalnız bellekte tutulur (testler).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        hosts = Set(defaults?.stringArray(forKey: Self.storeKey) ?? [])
    }

    private static func normalized(_ host: String?) -> String? {
        guard let text = host?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        return text
    }

    public func isKnown(host: String?) -> Bool {
        guard let host = Self.normalized(host) else { return false }
        return lock.withLock { hosts.contains(host) }
    }

    /// TV uygulaması bu TV'de kurulu: bağlandı ya da kuruldu.
    public func mark(host: String?) {
        guard let host = Self.normalized(host) else { return }
        lock.withLock {
            guard hosts.insert(host).inserted else { return }
            defaults?.set(hosts.sorted(), forKey: Self.storeKey)
        }
    }

    /// Eşleşmiş TV ağda yeni adreste bulundu (modem yeni adres verdi, bkz. `TVLocator`): eski adreste kurulu olduğu
    /// biliniyorsa yeni adres de bilinen sayılır. Bilgi adrese bağlı olduğundan, adresi değişen TV'de bekçi önce listeye
    /// bakıyor, liste geliştirici moduyla kurulan uygulamayı içermiyorsa uygulamayı hiç açmıyordu (beta.62'de adres
    /// değişse de açıyordu; Windows'taki Carry ile aynı).
    public func carry(from old: String?, to new: String?) {
        guard Self.normalized(new) != nil, isKnown(host: old) else { return }
        mark(host: new)
    }

    public func forget(host: String?) {
        guard let host = Self.normalized(host) else { return }
        lock.withLock {
            guard hosts.remove(host) != nil else { return }
            defaults?.set(hosts.sorted(), forKey: Self.storeKey)
        }
    }

    /// Sahadan öğrenmek için yapılan liste sorgusu çalışma boyunca bir kez yapılır.
    func takeProbe() -> Bool {
        lock.withLock {
            if probed { return false }
            probed = true
            return true
        }
    }

    /// Açma komutundan önce TV'nin kurulu uygulama listesine bakılsın mı: yalnız kurulu olduğu bilinmeyen TV'de.
    static func checksList(knownInstalled: Bool) -> Bool { !knownInstalled }

    /// Açma kararı. Kurulu olduğu bilinen TV'de liste ne derse desin eski yol (DEEP_LINK) gönderilir; bilinmeyen TV'de
    /// listede yoksa (#637) ya da liste 3 saniyede gelmezse gönderilmez: kurulu olmayan uygulamaya giden DEEP_LINK Smart
    /// Hub'ı mağaza aramasına yolluyor, Samsung'a ulaşamayan TV'de "Samsung sunucusuna bağlanılamıyor (AS400)" çıkıyordu
    /// (Samsung 7 Series 2018, 21 Kas). Dönen değer gönderilecek tür, gönderilmeyecekse nil (Windows ve Android ile aynı).
    static func action(knownInstalled: Bool, presence: SamsungAppPresence?) -> String? {
        if knownInstalled { return "DEEP_LINK" }
        switch presence {
        case .missing, nil: return nil
        case .installed(let type): return SamsungMessages.actionType(appType: type)
        }
    }

    /// Açma isteği gönderilmediğinde tvinstall.log satırı (Mac'te TVInstallLog, iPhone'da InstallLog bağlar).
    public static var installLog: (@Sendable (String) -> Void)?

    private var lastNotSent: String?

    /// Gönderilmeyen açma isteği günlüklere yazılır; bekçi her 30 sn'de denediği için aynı satır yinelenmez.
    func reportNotSent(host: String?, presence: SamsungAppPresence?) {
        let line = Self.notSentLine(host: host, presence: presence)
        lock.lock()
        let repeated = lastNotSent == line
        lastNotSent = line
        lock.unlock()
        if repeated { return }
        SubtitleLog.write(line)
        Self.installLog?(line)
    }

    static func notSentLine(host: String?, presence: SamsungAppPresence?) -> String {
        let tv = host ?? "?"
        return presence == nil
            ? "Samsung \(tv): uygulama listesi 3 sn'de gelmedi; açma isteği gönderilmedi (kurulu olmayan uygulamaya DEEP_LINK Smart Hub'ı mağazaya yollar)."
            : "Samsung \(tv): kurulu uygulama listesinde CouchSubs yok; açma isteği gönderilmedi."
    }
}

/// Samsung TV ile uzaktan kumanda WebSocket'i üzerinden konuşur. İlk bağlantıda TV izin sorar.
public final class SamsungClient: NSObject, TVControlling, URLSessionDelegate, @unchecked Sendable {
    /// `notInstalled`: TV'nin kurulu uygulama listesinde CouchSubs yok ya da liste yanıtsız; açma komutu gönderilmedi.
    public enum SamsungError: Error { case cannotConnect, rejected, notInstalled }

    private let url: URL?
    private let approvalTimeout: Duration
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    /// TV uygulamasının bu TV'de kurulu olduğu biliniyor mu; nil ise `SamsungAppKnowledge.shared`'a sorulur.
    public var knownInstalled: Bool?

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

    /// TV uygulamasını uzaktan kumanda bağlantısıyla açar. Açma yolları (bekçide geliştirici bağlantısı önce denenir):
    /// 1. sdb `0 was_execute` (Mac'te `samsung-open` yardımcısı): Tizen 2.4 ve sonrası (2016 K serisinden bu yana),
    ///    geliştirici modu açık ve Host PC IP bu cihazsa. Smart Hub'dan geçmez, mağaza denetimi yok; PAYLOAD taşımaz, TV
    ///    uygulaması bilgisayarı kendisi bulur.
    /// 2. Bu yöntem: önce `ed.installedApp.get` ile uygulamanın kurulu olduğuna bakılır, sonra `ed.apps.launch` TV'nin
    ///    bildirdiği türle (web uygulamasında DEEP_LINK) gönderilir; 2016 ve sonrası Tizen TV'lerde çalışır. Uygulama
    ///    kurulu değilken DEEP_LINK gönderilirse Smart Hub appId'yi mağazada arıyor ve mağazada olmayan CouchSubs için TV'de
    ///    "Sunucu bakım altında (1544007)" ya da "Samsung sunucusuna bağlanılamıyor (AS400)" çıkıyordu (#402'de kurulum 118
    ///    hatasıyla düşmüştü; #511, #637). Bu yüzden listede yoksa ya da liste 3 saniyede gelmezse hiçbir şey gönderilmez
    ///    (`SamsungError.notInstalled`); kurulum adımı önerilir.
    /// REST `POST http://TV:8001/api/v2/applications/<id>` kullanılmaz: PAYLOAD taşımaz ve 2019 sonrası yazılımlarda
    /// izinsiz istekleri reddediyor.
    public func launch(appId: String, params: [String: Any]) async throws {
        guard let socket else { throw SamsungError.cannotConnect }
        // Uygulama bu TV'den daha önce bağlandıysa ya da bu cihaz kurduysa listeye bakılmaz, eskisi gibi doğrudan açılır:
        // listenin geliştirici moduyla kurulan uygulamayı içerdiği gerçek TV'de doğrulanmadı (beta.63'te içermeyen TV'de
        // bekçi uygulamayı hiç açmıyordu).
        let host = url?.host
        let known = knownInstalled ?? SamsungAppKnowledge.shared.isKnown(host: host)
        if !SamsungAppKnowledge.checksList(knownInstalled: known) {
            let direct = SamsungMessages.launch(appId: appId, params: params, actionType: "DEEP_LINK")
            try await socket.send(.string(String(decoding: direct, as: UTF8.self)))
            await probeList(appId: appId, socket: socket, host: host)
            return
        }
        let presence = await installedApp(appId: appId, socket: socket)
        guard let action = SamsungAppKnowledge.action(knownInstalled: false, presence: presence) else {
            SamsungAppKnowledge.shared.reportNotSent(host: host, presence: presence)
            throw SamsungError.notInstalled
        }
        let message = SamsungMessages.launch(appId: appId, params: params, actionType: action)
        try await socket.send(.string(String(decoding: message, as: UTF8.self)))
    }

    /// Sahadan öğrenmek için: kurulu olduğu bilinen TV'de açma komutu gittikten sonra listeye bir kez bakılır; liste
    /// uygulamayı içermiyorsa günlüğe yazılır. Sonucu açmayı etkilemez.
    private func probeList(appId: String, socket: URLSessionWebSocketTask, host: String?) async {
        guard SamsungAppKnowledge.shared.takeProbe() else { return }
        let tv = host ?? "?"
        switch await installedApp(appId: appId, socket: socket) {
        case nil:
            SubtitleLog.write("Samsung \(tv): kurulu uygulama listesi yanıtsız; uygulama daha önce bağlandığı için doğrudan açıldı.")
        case .missing:
            SubtitleLog.write("Samsung \(tv): kurulu uygulama listesinde CouchSubs YOK ama uygulama daha önce bağlandı/kuruldu; doğrudan açıldı.")
        case .installed(let type):
            SubtitleLog.write("Samsung \(tv): kurulu uygulama listesinde CouchSubs var (app_type \(type.map(String.init) ?? "?")).")
        }
    }

    /// TV'nin kurulu uygulama listesine göre durum; TV 3 saniyede yanıtlamazsa nil.
    private func installedApp(appId: String, socket: URLSessionWebSocketTask) async -> SamsungAppPresence? {
        guard (try? await socket.send(.string(SamsungMessages.installedAppsRequest))) != nil else { return nil }
        // Okuma görevi zaman aşımında iptal edilemez (URLSessionWebSocketTask.receive iptali dinlemez); sonucu ilk gelen
        // belirler, geride kalan okuma bağlantı kapanınca biter.
        return await withCheckedContinuation { (continuation: CheckedContinuation<SamsungAppPresence?, Never>) in
            let once = ResumeOnce(continuation)
            Task {
                while true {
                    guard let message = try? await socket.receive() else { once.resume(nil); return }
                    let text: String
                    switch message {
                    case .string(let value): text = value
                    case .data(let value): text = String(decoding: value, as: UTF8.self)
                    @unknown default: continue
                    }
                    if let presence = SamsungMessages.installedApp(text, appId: appId) { once.resume(presence); return }
                    if once.done { return }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                once.resume(nil)
            }
        }
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

/// Bekçinin Samsung'da TV uygulamasını açma yolu: önce geliştirici bağlantısı (sdb `0 was_execute`), olmazsa uzaktan kumanda
/// bağlantısı (8002, ilk bağlantıda TV izin sorar). Samsung önplandaki uygulamayı söylemez; bekçi yalnız açar.
///
/// Mac ve Windows sdb'yi Tizen 9.0'da uzaktan kumandayla açma sessizce çalışmadığı için (#412) önce deniyordu; iPhone
/// (ve Android telefon) yalnız uzaktan kumanda yolunu kullanıyordu: TV komutu alıp açmayınca kullanıcı CouchSubs'ı
/// kumandayla açmak zorunda kalıyordu (iPhone, TestFlight build 27, 21 Kas). sdb yalnız TV'nin geliştirici modu açık ve
/// Host PC IP bu cihazsa çalışır (telefondan kurulduysa öyledir); değilse hemen uzaktan kumandaya geçilir.
public final class SamsungLauncher: TVControlling, @unchecked Sendable {
    private let openWithSdb: () async -> Bool
    private let connectRemote: () async throws -> TVControlling

    public init(openWithSdb: @escaping () async -> Bool, connectRemote: @escaping () async throws -> TVControlling) {
        self.openWithSdb = openWithSdb
        self.connectRemote = connectRemote
    }

    public func launch(appId: String, params: [String: Any]) async throws {
        if await openWithSdb() { return }
        let remote = try await connectRemote()
        defer { remote.close() }
        try await remote.launch(appId: appId, params: params)
    }

    public func foregroundAppId() async throws -> String { "" }

    public func close() {}

    /// `0 was_execute` yanıtı uygulamanın açıldığını söylüyor mu ("app_id[…] launched"); Windows'taki
    /// SamsungTvInstaller.Launched ile aynı.
    public static func sdbLaunched(_ reply: String) -> Bool {
        reply.contains("] launched") && reply.range(of: "fail", options: .caseInsensitive) == nil
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
