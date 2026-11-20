// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network

/// TV'de çevirinin oyundaki İngilizce altyazıya göre yeri.
public enum SubtitlePlacement: String, Codable, CaseIterable, Sendable {
    /// İngilizce altyazının üstüne, onu örterek.
    case cover
    /// İngilizce altyazının hemen üstünde.
    case above
    /// İngilizce altyazının hemen altında.
    case below
    /// Ekranda sabit bir yükseklikte (`bottomPercent`).
    case fixed
}

/// Altyazı kutusunun kapladığı alan.
public enum SubtitleBackgroundShape: String, Codable, CaseIterable, Sendable {
    /// Kutu yazı kadar (ya da örtüyse okunan altyazı bölgesi kadar) yer kaplar.
    case fit
    /// Kutu tam genişlikte bir bant: oyundaki İngilizce altyazı yan yana taşsa da görünmez.
    case band
}

/// TV'de altyazı yazısının rengi.
public enum SubtitleTextColor: String, Codable, CaseIterable, Sendable {
    case white
    case yellow
}

/// Android TV'de PS5 görüntüsünün nasıl gösterildiği.
public enum TVDisplayMode: String, Codable, CaseIterable, Sendable {
    /// HDMI CouchSubs'ın içinde; görüntü hiç gelmezse TV uygulaması kendiliğinden katmana geçer.
    case inApp
    /// TV HDMI'yı kendi ekranında gösterir, altyazı üstteki şeffaf katmanda (bazı TV'lerde uygulama içi görüntü siyah kalıyor).
    case overlay
}

/// TV'de altyazının görünümü.
public struct SubtitleStyle: Codable, Equatable, Sendable {
    /// 36 (küçük), 46 (orta), 58 (büyük), 72 (çok büyük)
    public var fontSize: Int
    /// Sabit yerleşimde altyazının ekranın altından uzaklığı, yüzde.
    public var bottomPercent: Int
    public var placement: SubtitlePlacement
    /// Yazının arkasındaki siyah zeminin koyuluğu, yüzde (0: zemin yok).
    public var background: Int
    /// Zeminin kapladığı alan; eski TV uygulamaları alanı tanımaz, `fit` gibi davranır.
    public var backgroundShape: SubtitleBackgroundShape
    public var bold: Bool
    public var textColor: SubtitleTextColor
    /// Yalnız Android TV uygulaması kullanır; diğer TV'ler ve OBS katmanı alanı tanımaz.
    public var displayMode: TVDisplayMode
    /// Hızlı konuşmada önceki satır(lar) yeni satırın üstünde kısa süre soluk kalsın mı; kapalıysa yeni satır eskisinin
    /// yerine geçer. TV uygulaması 0.9.16 ve sonrası tanır (Windows: SubtitleStyle.StackPrevious).
    public var stackPrevious: Bool

    public init(fontSize: Int = 46, bottomPercent: Int = 7, placement: SubtitlePlacement = .cover, background: Int = 90, backgroundShape: SubtitleBackgroundShape = .fit, bold: Bool = false,
                textColor: SubtitleTextColor = .white, displayMode: TVDisplayMode = .inApp, stackPrevious: Bool = true) {
        self.fontSize = fontSize
        self.bottomPercent = bottomPercent
        self.placement = placement
        self.background = background
        self.backgroundShape = backgroundShape
        self.bold = bold
        self.textColor = textColor
        self.displayMode = displayMode
        self.stackPrevious = stackPrevious
    }

    private enum CodingKeys: String, CodingKey { case fontSize, bottomPercent, placement, background, backgroundShape, bold, textColor, displayMode, stackPrevious }

    /// Eski sürümün kaydettiği ayarlarda yeni alanlar yoktur; eksikler varsayılanla dolar.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SubtitleStyle()
        fontSize = try values.decodeIfPresent(Int.self, forKey: .fontSize) ?? defaults.fontSize
        bottomPercent = try values.decodeIfPresent(Int.self, forKey: .bottomPercent) ?? defaults.bottomPercent
        placement = (try? values.decodeIfPresent(SubtitlePlacement.self, forKey: .placement)) ?? defaults.placement
        background = try values.decodeIfPresent(Int.self, forKey: .background) ?? defaults.background
        backgroundShape = (try? values.decodeIfPresent(SubtitleBackgroundShape.self, forKey: .backgroundShape)) ?? defaults.backgroundShape
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? defaults.bold
        textColor = (try? values.decodeIfPresent(SubtitleTextColor.self, forKey: .textColor)) ?? defaults.textColor
        displayMode = (try? values.decodeIfPresent(TVDisplayMode.self, forKey: .displayMode)) ?? defaults.displayMode
        stackPrevious = try values.decodeIfPresent(Bool.self, forKey: .stackPrevious) ?? defaults.stackPrevious
    }

    /// TV'ye giden `style` olayının gövdesi.
    var json: [String: Any] {
        ["fontSize": fontSize, "bottomPercent": bottomPercent, "placement": placement.rawValue,
         "background": max(0, min(100, background)), "backgroundShape": backgroundShape.rawValue, "bold": bold, "textColor": textColor.rawValue,
         "displayMode": displayMode.rawValue, "stackPrevious": stackPrevious]
    }
}

/// Sunucudan geçen ve bilgisayar ekranındaki altyazı penceresinin de gösterdiği olay.
public enum SubtitleEvent: Equatable, Sendable {
    /// `replaces`: satır öncekinin uzamış ya da düzelmiş okumasıdır; öncekinin üstüne yığılmaz, yerine geçer.
    case subtitle(text: String, durationMs: Int, paragraphs: Bool, replaces: Bool = false)
    case clear
    /// "Ekranı çevir" sonuçları: grupların çevirisi, yukarıdan aşağı, her biri ayrı satırda.
    case screen(text: String, durationMs: Int)
    /// "Ekranı çevir" çevirileri kaldırıldı.
    case screenClear
    /// Ek alanın (görev, telefon, bildirim) çevirisi; `text` boşsa o alanın kutusu kalkar.
    case region(id: String, text: String, box: TextBox?)
    /// Bütün ek alan kutuları kalktı (çeviri durdu).
    case regionClear
    /// Oyun içi telefonun renkleri ve yerleriyle gösterilen balonları. Boş liste yalnız telefonu kaldırır.
    case gamePhone([ScreenTranslation.Item])
    /// Kendiliğinden bulunan ekran yazısının blokları, özgün yazının yeri ve stiliyle (`TextLook`). Kutu kaldırılırken
    /// `region` olayı boş metinle gelir.
    case screenText(id: String, items: [ScreenTranslation.Item])
}

/// TV uygulamasının bağlandığı yerel Server-Sent Events sunucusu.
/// `GET /events` akışında `subtitle`, `clear` ve `style` olaylarını yayınlar.
public final class SubtitleServer: @unchecked Sendable {
    public enum ServerError: Error { case failedToStart(String) }

    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "couchsubs.subtitle-server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    /// OBS katmanı gibi TV olmayan izleyiciler: olayları alır ama "TV bağlı" sayısına katılmaz.
    private var viewers: Set<ObjectIdentifier> = []
    private var lastStyle: SubtitleStyle?
    private var pingTimer: DispatchSourceTimer?
    /// `GET` ile verilen dosyalar: dublaj sesleri ve seslendirme modelinin ses örnekleri.
    private var files: [String: (data: Data, type: String)] = [:]
    private var speechPaths: [String] = []
    private var speechNumber = 0
    private var key: String
    private let allowLegacy: Bool
    public let pairing = SubtitlePairing()
    public var onPairingRequest: (@Sendable (SubtitlePairing.Ticket) -> Void)?
    private var legacySeen = false
    public var onLegacyClient: (@Sendable () -> Void)?
    public var accessKey: String { queue.sync { key } }
    public var hasLegacyClient: Bool { queue.sync { legacySeen } }

    public func rotateKey(_ key: String) {
        queue.sync {
            self.key = key
            pairing.reset()
            for connection in clients.values { connection.cancel() }
            clients.removeAll()
            viewers.removeAll()
            notifyClientsChanged()
        }
    }

    public var onClientsChanged: ((Int) -> Void)?

    /// Altyazı ve temizleme olayları gönderildiği anda buraya da verilir (çağıranın iş parçacığında). Bilgisayar
    /// ekranındaki pencere TV'ye gidenin aynısını gösterir; sunucu başlamamış olsa da çalışır.
    public var onEvent: (@Sendable (SubtitleEvent) -> Void)?

    /// false ise altyazı olayları TV'lere gitmez (altyazı yalnız bilgisayar ekranında); OBS katmanı almaya devam eder.
    public var sendsToTV: Bool {
        get { queue.sync { tvEnabled } }
        set { queue.sync { tvEnabled = newValue } }
    }
    private var tvEnabled = true

    /// Konuşana göre renk: açıksa adlı satırları olan `subtitle` olayına `speakers` alanı ([{name, color}]) eklenir;
    /// TV o adla başlayan satırı o renkte gösterir. Alanı tanımayan eski TV uygulaması yok sayar.
    public var speakerColors: Bool {
        get { queue.sync { colorsEnabled } }
        set { queue.sync { colorsEnabled = newValue } }
    }
    private var colorsEnabled = false

    /// Oturumun konuşan renkleri (v2; çeviri başlayınca sıfırlanır). Bilgisayar ekranındaki pencereler de buradan boyar.
    public let speakerBook = SpeakerColorBook()

    /// "Ekran yazılarını altyazıdan ayır": TV ek alan kutularını özgün renginde ve kendi yerinde, altyazı kutusundan farklı
    /// zeminde çizer (`style` olayının `setApart` alanı; yoksa açık sayılır). Değişince `sendStyle` yeniden gönderilmeli.
    public var setApart: Bool {
        get { queue.sync { apart } }
        set { queue.sync { apart = newValue } }
    }
    private var apart = true

    /// Bağlantı canlı tutma çerçevesi: yorum satırını EventSource görmez; adlı "ping" olayını TV görür ve
    /// bir süre gelmezse yarı açık kalmış bağlantıyı kapatıp yeniden bağlanır (Windows ile aynı).
    static let pingFrame = ": ping\n\nevent: ping\ndata: {}\n\n"
    private let pingInterval: TimeInterval

    /// Bu kurulumun kalıcı kimliği (`/hello` yanıtında). Aynı ağda iki CouchSubs varken TV uygulaması kendi bilgisayarını
    /// ya da telefonunu adres değişse de bununla tanır; eskiden ağda ilk bulduğuna bağlanıyordu (GitHub #425).
    public let instanceId: String

    public init(port: UInt16 = 8787, pingInterval: TimeInterval = 15, key: String? = nil,
                allowLegacy: Bool = SubtitleAccess.allowLegacyClients, instanceId: String = SubtitleServer.installationId) {
        requestedPort = port
        self.pingInterval = pingInterval
        self.key = key ?? SubtitleAccess.createKey()
        self.allowLegacy = allowLegacy
        self.instanceId = instanceId
    }

    /// Kurulumun kimliği: ilk istekte rastgele üretilir ve ayarlarda saklanır (Mac ve iPhone).
    public static var installationId: String {
        let key = "couchsubs.serverId"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        let made = UUID().uuidString.lowercased()
        UserDefaults.standard.set(made, forKey: key)
        return made
    }

    /// `/hello` yanıtı: uygulama, eşleştirme gerektiği (`auth`), kurulum kimliği ve bağlı TV sayısı (Windows ve Android ile
    /// aynı biçim). Erişim anahtarını içermez. TV, ağda birden çok CouchSubs bulursa kayıtlı kimliği, yoksa TV'si bağlı
    /// olmayanı seçer; onayladığı anahtarı da bu kimlikle eşler.
    static func helloBody(id: String, tvs: Int) -> String {
        let escaped = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return #"{"app":"couchsubs","auth":1,"id":""# + escaped + #"","tvs":"# + String(max(0, tvs)) + "}"
    }

    public var connectedClients: Int {
        queue.sync { clients.count - viewers.count }
    }

    /// Dinleyici açık ve bağlantı kabul ediyor. iPhone'da uygulama arka planda askıya alınınca iOS dinleyiciyi
    /// kapatabiliyor; eskiden bu sessiz kalıyor, sunucu "başlamış" sayıldığı için TV bir daha bağlanamıyordu.
    public var isListening: Bool { queue.sync { listening } }
    private var listening = false
    /// Hazır olduktan sonra dinleyici düştü (neden); çağıran `start()` ile yeniden açabilir. Sunucunun kuyruğunda çağrılır.
    public var onListenerFailed: (@Sendable (String) -> Void)?

    /// OBS'de "Tarayıcı kaynağı" olarak eklenen altyazı katmanı (`GET /obs`).
    public static let obsOverlay: Data = {
        guard let url = Bundle.module.url(forResource: "obs-overlay", withExtension: "html"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }()

    /// Sunucuyu başlatır ve dinlenen portu döner (`port: 0` ise rastgele seçilen port).
    ///
    /// Sabit portta "Address already in use" gelirse kısa aralıklarla yeniden denenir: az önce kapatılan dinleyici portu
    /// birkaç milisaniye sonra bırakır. Eskiden `stop()` ardından `start()` hep bu hatayı veriyor, çağıran rastgele bir
    /// porta düşüyordu; ağı yalnız 8787'de tarayan TV uygulaması (Android TV) telefonu bir daha bulamıyordu.
    public func start() async throws -> UInt16 {
        var attempt = 0
        while true {
            do {
                return try await startOnce()
            } catch PortBusy.busy(let reason) {
                attempt += 1
                guard requestedPort != 0, attempt < Self.busyRetries else { throw ServerError.failedToStart(reason) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private enum PortBusy: Error { case busy(String) }
    static let busyRetries = 10

    private func startOnce() async throws -> UInt16 {
        let port: NWEndpoint.Port = requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort)!
        // Sessizce kaybolan TV'ler (fişten çekme, Wi-Fi kopması) TCP canlılık denetimiyle fark edilir.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        // Altyazı çerçeveleri küçüktür; Nagle beklemesi her satırı TV'ye geç ulaştırmasın.
        tcp.noDelay = true
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        return try await withCheckedThrowingContinuation { continuation in
            // Durum değişiklikleri seri kuyrukta gelir; devamı yalnız bir kez çağırmak için saklanır.
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                guard let continuation = self.startContinuation else {
                    // Açıldıktan sonra düşen dinleyici (stop() ile kapatılan .cancelled olur, o sayılmaz).
                    if case .failed(let error) = state, self.listener === listener {
                        self.listening = false
                        self.pingTimer?.cancel()
                        self.pingTimer = nil
                        listener.cancel()
                        self.onListenerFailed?(error.localizedDescription)
                    }
                    return
                }
                switch state {
                case .ready:
                    self.startContinuation = nil
                    self.listening = true
                    self.pingTimer?.cancel()
                    self.startPing()
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    // .waiting: port ya da ağ şu an kullanılamıyor; beklemek yerine hata ver ki çağıran başka port denesin.
                    self.startContinuation = nil
                    listener.cancel()
                    if case .posix(.EADDRINUSE) = error {
                        continuation.resume(throwing: PortBusy.busy(error.localizedDescription))
                    } else {
                        continuation.resume(throwing: ServerError.failedToStart(error.localizedDescription))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private var startContinuation: CheckedContinuation<UInt16, Error>?

    public func stop() {
        pairing.setSession(false)
        queue.sync {
            listening = false
            pingTimer?.cancel()
            pingTimer = nil
            listener?.cancel()
            listener = nil
            clients.values.forEach { $0.cancel() }
            clients.removeAll()
            viewers.removeAll()
        }
    }

    /// `box`: oyundaki İngilizce altyazının ekrandaki yeri (kenarlara oranla); TV çeviriyi buna göre yerleştirir.
    /// `replaces`: çeviri, az önce gösterilen satırın uzamış ya da düzelmiş bir okumasından gelir (`TextMatch.isRevision`);
    /// TV onu öncekinin üstüne yığmaz, yerine koyar (`replace` alanı; eski TV uygulamaları yok sayar).
    public func sendSubtitle(_ text: String, durationMs: Int = 15000, box: TextBox? = nil, replaces: Bool = false) {
        let at = Int(Date().timeIntervalSince1970 * 1000)
        var json: [String: Any] = ["text": text, "duration": durationMs, "at": at]
        if let box { json["box"] = Self.json(box) }
        if replaces { json["replace"] = true }
        if speakerColors {
            let speakers = SpeakerColors.speakers(in: text, book: speakerBook)
            if !speakers.isEmpty { json["speakers"] = speakers.map { ["name": $0.name, "color": $0.color] } }
        }
        broadcast(event: "subtitle", json: json)
        onEvent?(.subtitle(text: text, durationMs: durationMs, paragraphs: false, replaces: replaces))
    }

    /// Dört basamağa yuvarlanır; Decimal, JSON'da 0.80000000000000004 yerine 0.8 yazılsın diye.
    static func json(_ box: TextBox) -> [String: Decimal] {
        let round = { (value: Double) in Decimal(Int((max(0, min(1, value)) * 10000).rounded())) / 10000 }
        return ["left": round(box.left), "top": round(box.top), "right": round(box.right), "bottom": round(box.bottom)]
    }

    /// Yeriyle bir çeviri ("Ekranı çevir" öğesi ya da ek alan bloğu).
    static func json(_ item: ScreenTranslation.Item, phone: Bool = false) -> [String: Any] {
        let line = Decimal(Int((max(0, min(1, item.lineHeight)) * 10000).rounded())) / 10000
        var result: [String: Any] = ["box": Self.json(item.box), "line": line, "text": item.translation]
        if item.paragraphs { result["paragraphs"] = true }
        if phone || item.look != nil, let style = item.style, isRGB(style.background), isRGB(style.foreground) {
            var surface: [String: Any] = ["background": style.background, "foreground": style.foreground]
            if let look = item.look { surface["flat"] = look.flat }
            result["surface"] = surface
        }
        // Otomatik ekran yazısı: özgün yazının görünüşü (eski TV yok sayar).
        if let look = item.look {
            result["style"] = ["align": look.align.rawValue, "bold": look.bold, "condensed": look.condensed, "upper": look.upper]
        }
        if let icons = item.icons, !icons.isEmpty { result["icons"] = Self.json(icons) }
        return result
    }

    private static func isRGB(_ color: String) -> Bool {
        color.utf8.count == 7 && color.first == "#" && color.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    static func json(_ icons: [IconPlacement]) -> [[String: Any]] {
        icons.map { icon -> [String: Any] in ["at": icon.at, "src": icon.image] }
    }

    public func clear() {
        broadcast(event: "clear", json: [:])
        onEvent?(.clear)
    }

    /// TV uygulamasını kapatır; çeviri durduğunda TV kendi girişine (HDMI) döner (#268, Windows ile aynı). Yalnız
    /// TV'lere gider, OBS gibi izleyicilere gitmez. `completion`, mesaj bütün TV'lere yazılınca (ya da yazılamayınca)
    /// sunucunun kuyruğunda çağrılır; kapanışta sunucu durdurulmadan önce kısa süre beklenebilir.
    public func exitTVApp(completion: (@Sendable () -> Void)? = nil) {
        let data = Data(Self.frame(event: "exit", json: [:]).utf8)
        queue.async {
            let group = DispatchGroup()
            for (id, connection) in self.clients where !self.viewers.contains(id) {
                group.enter()
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let self, error != nil {
                        connection.cancel()
                        if self.clients.removeValue(forKey: id) != nil { self.notifyClientsChanged() }
                    }
                    group.leave()
                })
            }
            group.notify(queue: self.queue) { completion?() }
        }
    }

    /// "Ekranı çevir" sonuçları: `screen` olayı her çeviriyi yazının yeri (`box`), tipik satır yüksekliği (`line`,
    /// ekrana oranla) ve çok parçalıysa `paragraphs` ile taşır. TV öncekinin yerine bunları koyar. Çevirinin içinde
    /// kumanda simgeleri varsa `icons` her simgenin düz metindeki yerini (`at`) ve PNG'sini (`src`) taşır; eski TV
    /// uygulamaları alanı yok sayıp düz metni gösterir (Windows ile aynı).
    public func sendScreen(_ items: [ScreenTranslation.Item], durationMs: Int) {
        let items = items.filter { Self.area($0.box) <= Self.maxBoxArea }
        broadcast(event: "screen", json: ["duration": durationMs, "items": items.map { Self.json($0) }])
        // Altyazı yalnız bilgisayardaysa (TV yok) çeviriler başka hiçbir yere gitmiyordu: tuşa basınca yalnız
        // "Ekran çevriliyor…" görünüyordu.
        onEvent?(.screen(text: items.map(\.translation).joined(separator: "\n"), durationMs: durationMs))
    }

    /// Ek alanın çevirisi: `region` olayı alanın kimliğini (`id`), çeviriyi (`text`; boşsa kutu kalkar), yazının karedeki
    /// yerini (`box`) ve satır yüksekliğini (`line`, ekrana oranla) taşır. TV çeviriyi o yerde küçük bir kutuda gösterir;
    /// ana altyazıya dokunmaz. Olayı tanımayan eski TV uygulamaları yok sayar.
    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double? = nil) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: nil)
    }

    /// `icons`: çevirinin içindeki kumanda simgeleri; `icons` alanı her simgenin düz metindeki yerini (`at`) ve PNG'sini
    /// (`src`) taşır. Eski TV uygulamaları alanı yok sayıp düz metni gösterir.
    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: icons, blocks: nil)
    }

    /// `blocks`: alanda ayrı duran yazı gruplarının çevirileri kendi yerleriyle (`blocks`; her biri `screen` olayındaki
    /// öğe gibi `box`, `line`, `text`). TV her birini kendi İngilizce yazısının üstüne koyar. Alanı tanımayan eski TV
    /// uygulamaları birleşik `text`'i tek kutuda gösterir (Windows ile aynı).
    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                           blocks: [ScreenTranslation.Item]?) {
        let (text, blocks) = Self.guarded(text: text, box: box, blocks: blocks)
        var json: [String: Any] = ["id": id, "text": text]
        if let icons, !icons.isEmpty { json["icons"] = Self.json(icons) }
        if let blocks, !blocks.isEmpty, !text.isEmpty { json["blocks"] = blocks.map { Self.json($0, phone: id == "game-phone") } }
        if let box { json["box"] = Self.json(box) }
        if let lineHeight { json["line"] = Decimal(Int((max(0, min(1, lineHeight)) * 10000).rounded())) / 10000 }
        broadcast(event: "region", json: json)
        if id == "game-phone" { onEvent?(.gamePhone(text.isEmpty ? [] : blocks ?? [])) }
        else if let blocks, !blocks.isEmpty, !text.isEmpty, blocks.contains(where: { $0.look != nil }) {
            onEvent?(.screenText(id: id, items: blocks))
        } else { onEvent?(.region(id: id, text: text, box: box)) }
    }

    /// Ekranın bu oranından büyük çeviri kutusu gönderilmez. TV ve OBS kutuyu opak zeminle çizer; yanlış bir algılamanın
    /// (oyun telefonu, otomatik ekran yazısı) ekranın büyük kısmını kaplayan kutusu oyun görüntüsünü kapatıyordu
    /// (LG'de "siyah ekran, ses var"). Windows: SubtitleServer.MaxBoxArea, Android: SubtitleServer.MAX_BOX_AREA.
    public static let maxBoxArea = 0.4

    static func area(_ box: TextBox) -> Double { max(0, box.right - box.left) * max(0, box.bottom - box.top) }

    /// Büyük kutu koruması: alanı `maxBoxArea`'dan büyük bloklar atılır; blokların toplamı da sınırı aşıyorsa ya da
    /// bloksuz alanın kutusu sınırdan büyükse alan boş gönderilir (TV kutuyu kaldırır).
    static func guarded(text: String, box: TextBox?, blocks: [ScreenTranslation.Item]?) -> (String, [ScreenTranslation.Item]?) {
        guard !text.isEmpty else { return (text, blocks) }
        var blocks = blocks
        if let all = blocks, !all.isEmpty {
            let kept = all.filter { area($0.box) <= maxBoxArea }
            if kept.reduce(0, { $0 + area($1.box) }) > maxBoxArea { return ("", nil) }
            if !kept.isEmpty { return (text, kept) }
            blocks = nil
        }
        if let box, area(box) > maxBoxArea { return ("", nil) }
        return (text, blocks)
    }

    /// Bütün ek alan kutularını kaldırır.
    public func clearRegions() {
        broadcast(event: "region-clear", json: [:])
        onEvent?(.regionClear)
    }

    /// TV'deki "ekranı çevir" çevirilerini kaldırır (altyazıya dokunmaz).
    public func clearScreen() {
        broadcast(event: "screen-clear", json: [:])
        onEvent?(.screenClear)
    }

    /// Dosyayı `path` adresinden verir ("/voices/male_1.wav").
    public func publish(_ data: Data, at path: String, type: String = "audio/wav") {
        queue.async { self.files[path] = (data, type) }
    }

    /// Dublaj sesini TV'ye gönderir: ses `/speech/<n>.wav` adresinden verilir, `speech` olayı adresi bildirir.
    /// Son 16 ses tutulur; TV kopup bağlanınca eskisini istemez.
    public func sendSpeech(_ wav: Data, durationMs: Int) {
        queue.async {
            self.speechNumber += 1
            let path = "/speech/\(self.speechNumber).wav"
            self.files[path] = (wav, "audio/wav")
            self.speechPaths.append(path)
            while self.speechPaths.count > 16 { self.files[self.speechPaths.removeFirst()] = nil }
            self.sendToAll(Data(Self.frame(event: "speech", json: ["url": path, "duration": durationMs]).utf8))
        }
    }

    /// TV'de çalan dublajı durdurur (yeni sahne, oturum sonu).
    public func stopSpeech() {
        broadcast(event: "speech-stop", json: [:])
    }

    public func sendStyle(_ style: SubtitleStyle) {
        queue.async { self.lastStyle = style }
        var json = style.json
        json["setApart"] = setApart
        broadcast(event: "style", json: json)
    }

    // MARK: - Bağlantılar

    private func accept(_ connection: NWConnection) {
        guard case let .hostPort(host, _) = connection.endpoint, SubtitleAccess.isLocalPeer("\(host)") else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.route(connection, requestLine: head)
            } else if isComplete || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func route(_ connection: NWConnection, requestLine: String) {
        guard let request = SubtitleAccess.parse(requestLine) else {
            respondAndClose(connection, status: "400 Bad Request")
            return
        }
        let access = SubtitleAccess.authorize(request, key: key, allowLegacy: allowLegacy)
        let cors = SubtitleAccess.cors(request)
        guard access.status == 200 else {
            respondAndClose(connection, status: access.status == 403 ? "403 Forbidden" : "401 Unauthorized", cors: access.status == 403 ? "" : cors)
            return
        }
        let path = request.path
        let method = request.method

        if path == "/pair" {
            if method == "POST" {
                guard let ticket = pairing.begin() else { respondAndClose(connection, status: "409 Conflict", cors: cors); return }
                if let handler = onPairingRequest { DispatchQueue.main.async { handler(ticket) } }
                let data = try! JSONSerialization.data(withJSONObject: ["id": ticket.id, "code": ticket.code])
                respondAndClose(connection, status: "200 OK", data: data, type: "application/json", cors: cors)
            } else if method == "GET" {
                let state: String
                if request.parameter("validate") == "1" {
                    let supplied = request.parameter("k") ?? ""
                    let check = SubtitleAccess.Request(method: "GET", target: "/events?k=\(supplied.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")", origin: request.origin, host: request.host)
                    state = SubtitleAccess.authorize(check, key: key, allowLegacy: false).status == 200 ? "valid" : "expired"
                } else { state = pairing.poll(request.parameter("id") ?? "") }
                var result = ["state": state]
                if state == "approved" { result["key"] = key }
                respondAndClose(connection, status: "200 OK", data: try! JSONSerialization.data(withJSONObject: result), type: "application/json", cors: cors)
            } else { respondAndClose(connection, status: "405 Method Not Allowed", cors: cors) }
            return
        }
        if method == "OPTIONS" {
            // Chromium'un yerel ağ erişimi denetimi (Private Network Access) ön istekte bu başlıkları ister; yeni
            // tarayıcılı TV'ler (Tizen 9.0 ve sonrası) başlık olmadan bilgisayara bağlanmayabilir. Eski TV'ler yok sayar.
            respondAndClose(connection, status: "204 No Content", data: Data(), type: nil, cors: cors + Self.preflightHeaders)
        } else if method == "GET" && path == "/events" {
            let obs = request.parameter("viewer") == "obs"
            // Anahtarsız OBS sayfası eski bir OBS adresidir; TV uygulamasının eski olduğu anlamına gelmez.
            if access.legacy && !obs && !legacySeen {
                legacySeen = true
                if let handler = onLegacyClient { DispatchQueue.main.async { handler() } }
            }
            openStream(connection, viewer: obs, cors: cors)
        } else if method == "GET" && path == "/obs" {
            respondAndClose(connection, status: "200 OK", data: Self.obsOverlay, type: "text/html; charset=utf-8", cors: cors)
        } else if method == "GET" && path == "/hello" {
            // TV uygulaması ağdaki bilgisayarı bu yanıtla tanır (bağlantı kuyruğunda: sayaçlar doğrudan okunur).
            respondAndClose(connection, status: "200 OK", body: Self.helloBody(id: instanceId, tvs: clients.count - viewers.count), cors: cors)
        } else if method == "GET", let file = files[path] {
            respondAndClose(connection, status: "200 OK", data: file.data, type: file.type, cors: cors)
        } else {
            respondAndClose(connection, status: "404 Not Found", cors: cors)
        }
    }

    private func respondAndClose(_ connection: NWConnection, status: String, body: String = "", cors: String = "") {
        respondAndClose(connection, status: status, data: Data(body.utf8), type: nil, cors: cors)
    }

    static let preflightHeaders = "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\n"
        + "Access-Control-Allow-Private-Network: true\r\nAccess-Control-Max-Age: 600\r\n"

    private func respondAndClose(_ connection: NWConnection, status: String, data: Data, type: String?, cors: String = "") {
        var head = "HTTP/1.1 \(status)\r\n\(cors)Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        head += "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func openStream(_ connection: NWConnection, viewer: Bool = false, cors: String = "") {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream; charset=utf-8\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: keep-alive\r\n"
        head += cors + "\r\n"
        head += "retry: 2000\n\n"
        if let style = lastStyle {
            var json = style.json
            json["setApart"] = apart
            head += Self.frame(event: "style", json: json)
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        let id = ObjectIdentifier(connection)
        clients[id] = connection
        if viewer { viewers.insert(id) }
        notifyClientsChanged()
        watchForClose(connection, id: id)
    }

    /// İstemci bağlantıyı kapattığında listeden çıkarır.
    private func watchForClose(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                connection.cancel()
                self.viewers.remove(id)
                if self.clients.removeValue(forKey: id) != nil { self.notifyClientsChanged() }
            } else {
                self.watchForClose(connection, id: id)
            }
        }
    }

    private func notifyClientsChanged() {
        let count = clients.count - viewers.count
        if let handler = onClientsChanged { DispatchQueue.main.async { handler(count) } }
    }

    private func broadcast(event: String, json: [String: Any]) {
        let data = Data(Self.frame(event: event, json: json).utf8)
        // Dublaj sesi altyazı yerinden bağımsızdır; yalnız altyazı olayları kapatılır.
        let subtitle = Self.subtitleEvents.contains(event)
        queue.async { self.sendToAll(data, includingTVs: !subtitle || self.tvEnabled) }
    }

    static let subtitleEvents: Set<String> = ["subtitle", "clear", "screen", "screen-clear", "style", "region", "region-clear"]

    /// Gönderim hatası alan bağlantı kopmuş sayılır ve listeden çıkarılır. `includingTVs` false ise yalnız izleyiciler
    /// (OBS) alır.
    private func sendToAll(_ data: Data, includingTVs: Bool = true) {
        for (id, connection) in clients where includingTVs || viewers.contains(id) {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, error != nil else { return }
                connection.cancel()
                self.viewers.remove(id)
                if self.clients.removeValue(forKey: id) != nil { self.notifyClientsChanged() }
            })
        }
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in self?.sendToAll(Data(Self.pingFrame.utf8)) }
        timer.resume()
        pingTimer = timer
    }

    private static func frame(event: String, json: [String: Any]) -> String {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "event: \(event)\ndata: \(body)\n\n"
    }
}
