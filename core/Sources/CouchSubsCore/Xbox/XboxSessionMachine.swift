// SPDX-License-Identifier: AGPL-3.0-only
// Ev yayını oturumunun durum makinesi ve veri kanalı iletileri (Android: XboxSessionMachine.kt, XboxChannels.kt).
// Kurallar Windows'taki XboxStreamSession ile aynı; iletiler xbox-xcloud-player 0.2.11'inkilerle birebir (MIT, unknownskl).
// Hata ya da kopmada 5, 15, 45 sn sonra baştan denenir; üç ardışık denemeden sonra durulur (konsol "oyun başka yerde
// açıldı" deyip yayını kesince eskiden her 5 sn'de bir yeniden açılıyordu). Konsol `Failed` ya da `errorDetails` dönerse
// hiç denenmez. Yayın `healthyStreamMs` ayakta kaldıysa deneme sayısı sıfırlanır.

import Foundation

public struct XboxSessionMachine {
    public enum Phase: Equatable {
        case idle, starting
        case provisioning(polls: Int, connectSent: Bool)
        case negotiating, streaming
        /// `attempt`: bu kopmadan sonraki ardışık deneme (1…3); denenmiyorsa 0.
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
    public let healthyStreamMs: Int
    private let clock: () -> Double
    public private(set) var phase: Phase = .idle
    /// Ardışık başarısız deneme sayısı.
    private var failures = 0
    private var streamingSince: Double = 0
    /// Ardışık, Xbox'tan tek kare gelmeden biten bağlantılar.
    private var noPictureConnections = 0
    public static let maxNoPictureAttempts = 2

    public init(maxPolls: Int = 90, pollIntervalMs: Int = 1000, retryDelaysMs: [Int] = [5000, 15000, 45000], healthyStreamMs: Int = 60_000,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }) {
        self.maxPolls = maxPolls
        self.pollIntervalMs = pollIntervalMs
        self.retryDelaysMs = retryDelaysMs
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
        return true
    }

    /// `permanent`: konsol yayını reddetti (`Failed` ya da `errorDetails`); yeniden denenmez. `.noFirstFrame` (bağlantı
    /// kuruldu, Xbox tek kare göndermedi) ayrıca sayılır: `maxNoPictureAttempts` ardışık bağlantıda görüntü gelmezse
    /// durulur. Eskiden her biri ~60 sn sürüp Xbox'ta "uzaktan oynatma başlatıldı / durduruldu" bildirimiyle dört kez
    /// açılıp kapanıyordu (Windows'taki XboxRetryPlan ile aynı).
    public mutating func fail(_ kind: XboxErrorKind, _ message: String, permanent: Bool = false) -> Action {
        guard phase != .stopped else { return .nothing }
        // Yayın en az `healthyStreamMs` sürdüyse bu kopma yeni bir dizinin ilkidir.
        if streamingSince > 0 && clock() - streamingSince >= Double(healthyStreamMs) { failures = 0 }
        streamingSince = 0
        failures += 1
        if kind == .noFirstFrame { noPictureConnections += 1 }
        // Xbox uzaktan oynatma hizmetini başlatamadı (HTTP hatası olarak gelse de): yeniden denemek işe yaramaz (#871).
        let retry = !permanent && !XboxStop.isPermanent(message) && !Self.fatal.contains(kind) && failures <= retryDelaysMs.count
            && noPictureConnections < Self.maxNoPictureAttempts
        phase = .failed(kind, message: message, willRetry: retry, attempt: retry ? failures : 0)
        return .retry(delayMs: retry ? retryDelaysMs[failures - 1] : nil)
    }

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
