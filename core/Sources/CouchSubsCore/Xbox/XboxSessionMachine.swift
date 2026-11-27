// SPDX-License-Identifier: AGPL-3.0-only
// Ev yayını oturumunun durum makinesi ve veri kanalı iletileri (Android: XboxSessionMachine.kt, XboxChannels.kt).
// Kurallar Windows'taki XboxStreamSession ile aynı; iletiler xbox-xcloud-player 0.2.11'inkilerle birebir (MIT, unknownskl).
// Görüntü gelmeden biten bağlantıda bir kez, 5 sn sonra baştan denenir; o da olmazsa durulur ("Yeniden bağlan" hemen görünür). Eskiden
// 5, 15, 45 sn aralarla üç deneme vardı; her biri Xbox'ta "uzaktan yürütme başlatıldı / durduruldu" bildirimi çıkarıyor,
// kullanıcı bunu bitmeyen bir döngü olarak görüyordu (Play, Android beta.85). Konsol `Failed` ya da `errorDetails` dönerse
// hiç denenmez; yalnız görüntü gelmiş bir yayın koptuktan sonraki ilk ret bir kez, `reconnectGraceMs` sonra denenir.
// Yayın `healthyStreamMs` (10 dk) ayakta kaldıysa deneme sayısı sıfırlanır.
// Görüntü gelmiş (oynanan) bir yayın beklenmedik koparsa sessiz yeniden bağlanma `dropRetryDelaysMs` kadar (5, 15 sn;
// en çok iki) denenir. Tek deneme yetmiyordu: kısa bir Wi-Fi takılmasında ilk deneme Xbox eski oturumu bırakmadan
// düşünce yayın duruyor, kullanıcı birkaç dakikada bir "Yeniden bağlan"a basmak zorunda kalıyordu (App Store, Play,
// X; GitHub #1185, #1190). Görüntü hiç gelmemiş bağlantılarda kural eskisi gibi (bir deneme). Sessiz yeniden bağlanma
// oturum boyunca `dropRetryWindowMs` (10 dk) içinde en çok `maxDropRetries` (iki) kez yapılır; sınır dolunca durulur
// (`dropLimitReached`, ekranda "Xbox bağlantısı koptu" ve "Yeniden bağlan"). beta.94'te (#1216) üç deneme ve 60 sn'de
// sıfırlanan sayaç birlikte, birkaç dakikada bir kopan yayında Xbox'ta bitmeyen "uzaktan yürütme durdu / başladı"
// bildirimi döngüsü yaratıyordu (#1252).

import Foundation

public struct XboxSessionMachine {
    public enum Phase: Equatable {
        case idle, starting
        case provisioning(polls: Int, connectSent: Bool)
        case negotiating, streaming
        /// `attempt`: bu kopmadan sonraki ardışık deneme (1, kopmadan sonraki retten sonra 2); denenmiyorsa 0.
        case failed(XboxErrorKind, message: String, willRetry: Bool, attempt: Int = 0)
        case stopped
    }

    public enum Action: Equatable {
        case play
        case pollState(delayMs: Int)
        case connect
        case negotiate
        /// Oturumu kapat; `delayMs` sonra baştan başla (nil: durul).
        case retry(delayMs: Int?)
        case nothing
    }

    public static let fatal: Set<XboxErrorKind> = [.signInRequired, .noXboxAccount]

    public let maxPolls: Int
    public let pollIntervalMs: Int
    public let retryDelaysMs: [Int]
    /// Görüntü gelmiş yayın koptuktan sonraki sessiz yeniden bağlanma aralıkları (Windows `XboxRetryPlan.DropDelaysMs`,
    /// Android `dropRetryDelaysMs` ile aynı).
    public let dropRetryDelaysMs: [Int]
    public static let defaultDropRetryDelaysMs = [5000, 15_000]
    /// Yayın bu kadar sağlıklı sürdüyse kopma yeni bir dizinin ilkidir (eskiden 60 sn: birkaç dakikada bir kopan yayın
    /// döngüye giriyordu, #1252).
    public static let defaultHealthyStreamMs = 600_000
    /// Sessiz yeniden bağlanma oturum sınırı: `dropRetryWindowMs` içinde en çok `maxDropRetries` deneme.
    public static let dropRetryWindowMs = 600_000
    public static let maxDropRetries = 2
    public let healthyStreamMs: Int
    private let clock: () -> Double
    public private(set) var phase: Phase = .idle
    /// Ardışık başarısız deneme sayısı.
    private var failures = 0
    private var streamingSince: Double = 0
    /// Ardışık, Xbox'tan tek kare gelmeden biten bağlantılar.
    private var noPictureConnections = 0
    public static let maxNoPictureAttempts = 2
    /// Bu makinede bir kez görüntü geldi (kopmadan sonraki ret bir kez denenir, bkz. `fail`).
    private var hadPicture = false
    /// Kopmadan sonraki ret için tanınan tek deneme kullanıldı; yeni görüntüde sıfırlanır.
    private var graceUsed = false
    /// Kopmadan sonra Xbox yeni oturumu reddederse (eski oturum Xbox'ta henüz kapanmadı) beklenen süre.
    public static let reconnectGraceMs = 15_000
    /// Görüntü gelmiş yayından sonraki sessiz yeniden bağlanmaların anları (son `dropRetryWindowMs` içindekiler).
    private var dropRetries: [Double] = []
    /// Son kopmada sessiz yeniden bağlanma sınırı doldu (görüntü gelmiş yayın `dropRetryDelaysMs` kadar ya da
    /// `dropRetryWindowMs` içinde `maxDropRetries` kez yeniden bağlandı ve yine koptu): yeniden denenmez, kullanıcıya
    /// "Xbox bağlantısı koptu" gösterilir.
    public private(set) var dropLimitReached = false

    public init(maxPolls: Int = 90, pollIntervalMs: Int = 1000, retryDelaysMs: [Int] = [5000],
         dropRetryDelaysMs: [Int] = XboxSessionMachine.defaultDropRetryDelaysMs,
         healthyStreamMs: Int = XboxSessionMachine.defaultHealthyStreamMs,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }) {
        self.maxPolls = maxPolls
        self.pollIntervalMs = pollIntervalMs
        self.retryDelaysMs = retryDelaysMs
        self.dropRetryDelaysMs = dropRetryDelaysMs.isEmpty ? retryDelaysMs : dropRetryDelaysMs
        self.healthyStreamMs = healthyStreamMs
        self.clock = clock
    }

    public mutating func start() -> Action {
        guard phase != .stopped else { return .nothing }
        phase = .starting
        return .play
    }

    public mutating func played() -> Action {
        guard phase == .starting else { return .nothing }
        phase = .provisioning(polls: 0, connectSent: false)
        return .pollState(delayMs: 0)
    }

    public mutating func status(_ state: String, errorDetails: String?) -> Action {
        guard case let .provisioning(polls, connectSent) = phase else { return .nothing }
        // Konsol yayını kendisi reddetti: yeniden denemek konsolu yeniden tetikler, denenmez.
        if state == "Failed" || (state != "Provisioned" && Self.hasErrorDetails(errorDetails)) {
            return fail(Self.classifyFailure(errorDetails), errorDetails ?? "Xbox yayını açılamadı", permanent: true)
        }
        switch state {
        case "Provisioned":
            phase = .negotiating
            return .negotiate
        case "ReadyToConnect" where !connectSent:
            phase = .provisioning(polls: polls, connectSent: true)
            return .connect
        default:
            return poll(polls: polls, connectSent: connectSent)
        }
    }

    public mutating func connected() -> Action {
        guard case let .provisioning(polls, connectSent) = phase else { return .nothing }
        return poll(polls: polls, connectSent: connectSent)
    }

    private mutating func poll(polls: Int, connectSent: Bool) -> Action {
        let next = polls + 1
        if next >= maxPolls { return fail(.timeout, "Xbox yayını hazır olmayı beklerken zaman aşımına uğradı") }
        phase = .provisioning(polls: next, connectSent: connectSent)
        return .pollState(delayMs: pollIntervalMs)
    }

    public mutating func streaming() -> Bool {
        guard phase == .negotiating else { return false }
        phase = .streaming
        streamingSince = clock()
        noPictureConnections = 0
        hadPicture = true
        graceUsed = false
        return true
    }

    /// `permanent`: konsol yayını reddetti (`Failed` ya da `errorDetails`); yeniden denenmez. `.noFirstFrame` (bağlantı
    /// kuruldu, Xbox tek kare göndermedi) ayrıca sayılır: `maxNoPictureAttempts` ardışık bağlantıda görüntü gelmezse
    /// durulur. Eskiden her biri ~60 sn sürüp Xbox'ta "uzaktan oynatma başlatıldı / durduruldu" bildirimiyle dört kez
    /// açılıp kapanıyordu (Windows'taki XboxRetryPlan ile aynı).
    public mutating func fail(_ kind: XboxErrorKind, _ message: String, permanent: Bool = false) -> Action {
        guard phase != .stopped else { return .nothing }
        let now = clock()
        // Yayın en az `healthyStreamMs` sürdüyse bu kopma yeni bir dizinin ilkidir.
        if streamingSince > 0 && now - streamingSince >= Double(healthyStreamMs) { failures = 0 }
        streamingSince = 0
        failures += 1
        if kind == .noFirstFrame { noPictureConnections += 1 }
        // Xbox uzaktan oynatma hizmetini başlatamadı (HTTP hatası olarak gelse de): yeniden denemek işe yaramaz (#871).
        let refused = permanent || XboxStop.isPermanent(message)
        // Görüntü gelmiş yayın koptuktan hemen sonra Xbox eski oturumu bırakmadan yenisini reddedebiliyor ("bir kez
        // kopunca Xbox yeniden başlatılmadan bağlanmıyor"): bu ret bir kez, eski oturum kapansın diye uzun beklenip denenir.
        let grace = refused && hadPicture && !graceUsed
        // Kopma dizisinde görüntü gelmiş yayından sonra en çok `dropRetryDelaysMs` kadar (üç), görüntü hiç gelmediyse
        // `retryDelaysMs` kadar (bir) yeniden bağlanma; kopmadan sonraki ret için tanınan tek deneme bu sınırın dışındadır
        // (reddedilen oturumda Xbox yayın açmaz).
        let delays = retryLimit
        var retry = ((!refused && failures <= delays.count) || grace) && !Self.fatal.contains(kind)
            && noPictureConnections < Self.maxNoPictureAttempts
        // Oturum sınırı: görüntü gelmiş yayından sonra `dropRetryWindowMs` içinde en çok `maxDropRetries` sessiz yeniden
        // bağlanma (kopmadan sonraki ret için tanınan deneme de sayılır; her biri Xbox'ta bildirim çıkarır).
        dropRetries.removeAll { now - $0 >= Double(Self.dropRetryWindowMs) }
        let limited = hadPicture && !Self.fatal.contains(kind) && noPictureConnections < Self.maxNoPictureAttempts
            && (!refused || grace) && (!retry || dropRetries.count >= Self.maxDropRetries)
        if limited { retry = false }
        dropLimitReached = limited
        if retry && hadPicture { dropRetries.append(now) }
        if retry && grace { graceUsed = true }
        phase = .failed(kind, message: message, willRetry: retry, attempt: retry ? failures : 0)
        guard retry else { return .retry(delayMs: nil) }
        let backoff = delays[min(failures, delays.count) - 1]
        return .retry(delayMs: grace ? max(Self.reconnectGraceMs, backoff) : backoff)
    }

    /// Bu kopma dizisindeki yeniden bağlanma aralıkları: görüntü gelmiş yayından sonra `dropRetryDelaysMs`, yoksa
    /// `retryDelaysMs`.
    private var retryLimit: [Int] { hadPicture ? dropRetryDelaysMs : retryDelaysMs }

    /// Sessiz yeniden bağlanmanın en çok deneme sayısı (günlükte "deneme 2/3").
    public var maxRetries: Int { retryLimit.count }

    /// `errorDetails` gerçek bir hata mı (boş nesne ya da tüm alanları null olan nesne sayılmaz).
    public static func hasErrorDetails(_ details: String?) -> Bool {
        let text = (details ?? "").replacingOccurrences(of: " ", with: "")
        if text.isEmpty || text == "{}" || text == "null" { return false }
        return text.range(of: #"^\{("[^"]*":(null|""),?)*\}$"#, options: .regularExpression) == nil
    }

    public mutating func stop() { phase = .stopped }

    public static func classifyFailure(_ details: String?) -> XboxErrorKind {
        let text = (details ?? "").lowercased()
        if ["inuse", "busy", "alreadystreaming"].contains(where: text.contains) { return .busy }
        return .consoleUnavailable
    }
}

public enum XboxChannels {
    /// Kanal adı → protokol; oluşturma sırası oynatıcıdaki gibi.
    public static let channels: [(name: String, protocol: String)] = [("input", "1.0"), ("chat", "chatV1"), ("control", "controlV1"), ("message", "messageV1")]
    public static let handshake = "{\"type\":\"Handshake\",\"version\":\"messageV1\",\"id\":\"f9c5f412-0e69-4ede-8e62-92c7f5358c56\",\"cv\":\"\"}"
    public static let authorization = "{\"message\":\"authorizationRequest\",\"accessKey\":\"4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E\"}"
    public static let gamepadAdded = "{\"message\":\"gamepadChanged\",\"gamepadIndex\":0,\"wasAdded\":true}"
    private static let messageId = "41f93d5a-900f-4d33-b7a1-2d4ca6747072"

    public static func isHandshakeAck(_ text: String) -> Bool { (try? parseJSON(text))?["type"] as? String == "HandshakeAck" }

    public static func configurationMessages(width: Int = 1920, height: Int = 1080) -> [String] {
        func message(_ target: String, _ data: JSON) -> String {
            jsonText(["type": "Message", "content": jsonText(data), "id": messageId, "target": target, "cv": ""])
        }
        return [
            message("/streaming/systemUi/configuration", ["version": [0, 1, 0], "systemUis": [Int]()]),
            message("/streaming/properties/clientappinstallidchanged", ["clientAppInstallId": "c11ddb2e-c7e3-4f02-a62b-fd5448e0b851"]),
            message("/streaming/characteristics/orientationchanged", ["orientation": 0]),
            message("/streaming/characteristics/touchinputenabledchanged", ["touchInputEnabled": false]),
            message("/streaming/characteristics/clientdevicecapabilities", [:]),
            message("/streaming/characteristics/dimensionschanged", [
                "horizontal": width, "vertical": height, "preferredWidth": width, "preferredHeight": height,
                "safeAreaLeft": 0, "safeAreaTop": 0, "safeAreaRight": width, "safeAreaBottom": height, "supportsCustomResolution": true]),
        ]
    }

    /// `input` kanalının ilk paketi (ClientMetadata, 15 bayt, küçük sonlu).
    public static func clientMetadataPacket(sequence: UInt32 = 0, timestampMs: Double, maxTouchpoints: UInt8 = 2) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt16(8).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sequence.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: timestampMs.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        data.append(maxTouchpoints)
        return data
    }

    /// `input` kanalından gelen ikili iletinin günlük metni (#1416): tür, uzunluk ve ilk `inputHexBytes` bayt onaltılı.
    /// Xbox el sıkışmadan sonra 16 (ServerMetadata) gönderir; içeriği Xbox'ın görüntü ayarını gösterebilir (görüntü hiç
    /// gelmeyen oturumu çalışan oturumla karşılaştırmak için). 128 (titreşim) her an gelir, yazılmaz (nil).
    public static func describeInput(_ data: Data) -> String? {
        let type = data.first.map { Int($0) } ?? -1
        if type == 128 { return nil }
        let name = type == 16 ? " (ServerMetadata)" : ""
        let hex = data.prefix(inputHexBytes).map { String(format: "%02x", $0) }.joined(separator: " ")
        return "ikili ileti, tür \(type)\(name), \(data.count) bayt" + (hex.isEmpty ? "" : ": \(hex)") + (data.count > inputHexBytes ? " …" : "")
    }

    public static let inputHexBytes = 32

    /// Oynatıcı bir pakette en çok 29 kare onaylar (Input.ts `getMetadataQueue(30)` → `splice(0, 29)`).
    public static let maxFrameAcks = 29

    /// `input` kanalının kare onayı paketi (Input/Packet.ts, rapor türü 1 = Metadata): tür (u16), sıra no (u32), zaman
    /// (f64, ms), kare sayısı (u8), her kare için yedi u32: serverDataKey (RTP zaman damgası), varış, gönderim, çözülme,
    /// gösterim, paket hazırlama ve gönderme anları (ms). Hepsi küçük sonlu; Android'deki `frameAckPacket` ile aynı.
    public static func frameAckPacket(sequence: UInt32, timestampMs: Double, frames: [XboxFrameAck]) -> Data {
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func ms(_ value: Double) -> UInt32 { UInt32(truncatingIfNeeded: Int64(value)) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) }
        u32(sequence)
        withUnsafeBytes(of: timestampMs.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        data.append(UInt8(frames.count))
        for frame in frames {
            u32(frame.serverDataKey)
            u32(ms(frame.arrivalMs))
            u32(ms(frame.arrivalMs))
            u32(ms(frame.decodedMs))
            u32(ms(frame.decodedMs))
            u32(ms(timestampMs))
            u32(ms(timestampMs))
        }
        return data
    }

    /// Oynatıcının SDP düzeltmesi: stereo ses (ilk `useinbandfec=1`).
    public static func mungeOffer(_ sdp: String) -> String {
        guard let range = sdp.range(of: "useinbandfec=1") else { return sdp }
        return sdp.replacingCharacters(in: range, with: "useinbandfec=1; stereo=1")
    }
}

/// Gösterilen bir görüntü karesinin onayı: [serverDataKey] karenin RTP zaman damgası, anlar oturum saatine göre ms.
public struct XboxFrameAck: Equatable {
    public let serverDataKey: UInt32
    public let arrivalMs: Double
    public let decodedMs: Double

    public init(serverDataKey: UInt32, arrivalMs: Double, decodedMs: Double) {
        self.serverDataKey = serverDataKey
        self.arrivalMs = arrivalMs
        self.decodedMs = decodedMs
    }
}
