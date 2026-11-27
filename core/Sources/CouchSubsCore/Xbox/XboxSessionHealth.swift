// SPDX-License-Identifier: AGPL-3.0-only
// Xbox yayınının sağlamlığı: canlı tutma sayacı, yayın durunca gösterilen metnin türü ve günlük özeti (#575, #611),
// görüntü başlayana kadar anahtar kare isteği ve tanı satırı (#403, #530). Kurallar ve satır biçimleri Windows'taki
// CouchSubs.Shell/XboxSessionHealth.cs ve XboxFirstFrameWatch.cs ile, Android'deki XboxFirstFrame.kt ile birebir.

import Foundation

/// Canlı tutma isteği (30 sn'de bir). Tek başarısız istek yayını bitirmez; yalnız `maxFailures` ardışık hata (yaklaşık
/// 90 sn yanıt yok) bitirir, arada başarılı bir istek sayacı sıfırlar.
public struct XboxKeepalive {
    public static let intervalSeconds = 30
    public static let maxFailures = 3

    public private(set) var failures = 0

    public init() {}

    public mutating func succeeded() { failures = 0 }

    /// Oturum bitirilmeli mi.
    public mutating func failed() -> Bool {
        failures += 1
        return failures >= Self.maxFailures
    }

    /// Canlı tutma yanıtı oturumun Xbox hizmetinde artık olmadığını söylüyor (HTTP 404/410): beklenmez, oturum biter.
    public static func sessionGone(_ message: String?) -> Bool {
        let text = message ?? ""
        return text.contains("HTTP 404") || text.contains("HTTP 410")
    }

    /// Başarısız canlı tutma isteğinden sonra yayın bitirilmeli mi. Görüntü akarken (`pictureFlowing`) hayır: Xbox
    /// yayını sürdürüyor, canlı tutma yanıtı (404 dahil) yanıltıcı olabiliyor. Android beta.85'te 404 ya da üç hata
    /// görüntü akarken de yayını kapatıyordu; ilk istek bağlantıdan 30 sn sonra gittiği için Xbox'ta "uzaktan yürütme
    /// başlatıldı / durduruldu" döngüsü oluyordu. Görüntü durmuşsa eskisi gibi: oturum Xbox hizmetinde yoksa (`gone`)
    /// ya da hatalar `maxFailures`'a vardıysa (`exhausted`) biter (Android ve Windows'taki XboxKeepalive ile aynı).
    public static func shouldEnd(gone: Bool, exhausted: Bool, pictureFlowing: Bool) -> Bool {
        !pictureFlowing && (gone || exhausted)
    }
}

/// Bir bağlantının neden bittiği: günlükte açıkça yazılır, yeniden bağlanırken ekrandaki kısa metni seçer. Windows'taki
/// CouchSubs.Shell/XboxEndCause ve Android'deki XboxEndCause ile aynı kurallar.
public enum XboxEndCause: String, Sendable {
    /// Xbox (ya da Xbox hizmeti) yayını kapattı: görüntü kanalı karşı taraftan kapandı, oturum bulunamadı, yayın reddedildi.
    case server = "sunucu kapattı"
    /// Beklenen yanıt ya da görüntü süresinde gelmedi.
    case timeout = "zaman aşımı"
    /// Ağ bağlantısı koptu ya da kurulamadı (ICE, Wi-Fi, internet).
    case network = "ağ"

    public static func of(_ kind: XboxErrorKind) -> XboxEndCause {
        switch kind {
        case .timeout, .noFirstFrame: return .timeout
        case .network, .noPicture: return .network
        default: return .server
        }
    }

    /// Günlük satırı, ör. `kapanma nedeni: ağ (Xbox ICE bağlantısı koptu (failed))`.
    public static func line(_ kind: XboxErrorKind, _ detail: String?) -> String {
        "kapanma nedeni: \(of(kind).rawValue) (\(XboxStop.shorten(detail)))"
    }

    /// Sessiz yeniden bağlanma satırı, ör. `sessiz yeniden bağlanma 2/3: 15 sn sonra` (Windows ve Android'de aynı biçim).
    /// `attempt` deneme sınırını aşabilir (kopmadan sonraki ret için tanınan ek deneme); o zaman "ek deneme" yazılır.
    public static func retryLine(attempt: Int, of max: Int, delayMs: Int) -> String {
        let count = attempt <= max ? "\(attempt)/\(max)" : "ek deneme"
        return "sessiz yeniden bağlanma \(count): \(delayMs / 1000) sn sonra"
    }

    /// Sessiz yeniden bağlanma sınırı doldu (Windows ve Android'de aynı biçim).
    public static let limitLine = "sessiz yeniden bağlanma sınırı doldu (\(XboxSessionMachine.dropRetryWindowMs / 60_000) dk içinde en çok "
        + "\(XboxSessionMachine.maxDropRetries)): yeniden denenmiyor, yayın durdu"
}

/// Oturum kapatma (DELETE) denemeleri. Kopma anında ağ da takılıyor olabilir; tek başarısız istek eski oturumu Xbox'ta
/// açık bırakıyor, yeni oturum "uzaktan oynatma hizmeti hazır değil" ya da `Failed` ile reddediliyordu. Kapatılamayan
/// oturum bir sonraki `play`dan önce yeniden kapatılır (Windows köprüsü ve Android'de de).
public enum XboxSessionClose {
    /// Denemeler arasındaki bekleme (ilki hemen).
    public static let delaysMs = [0, 1000, 2000]
}

/// ICE adayları değişildikten sonra görüntü kanalı (input) bu sürede açılmazsa bağlantı zaman aşımıyla kapatılır. İlk
/// kare sınırı (`XboxFirstFrameWatch.firstFrameLimitMs`) kanal açılınca başlar: Wi-Fi'daki yavaş ICE kurulumu ilk kare
/// süresinden yemez (Windows ve Android'de de böyle).
public enum XboxConnectWatch {
    public static let connectLimitMs = 30_000
}

/// Yayının neden durduğu (kullanıcıya gösterilen metni seçer).
public enum XboxStopKind: Equatable, Sendable {
    /// `noPicture`: son bağlantılarda Xbox tek kare göndermedi (Windows XboxStopKind.NoPicture, Android NO_PICTURE).
    /// `serviceNotReady`: Xbox uzaktan oynatma hizmetini başlatamadı ("Timed out waiting for Cloud Streaming Service to be
    /// ready", 0x8007139F); `startFailed`: Xbox bilinmeyen bir hata koduyla yayını reddetti (#871); `dropped`: oynanan yayın
    /// koptu ve sessiz yeniden bağlanma sınırı doldu (`XboxSessionMachine.dropLimitReached`, #1252).
    case busy, consoleUnavailable, noPicture, serviceNotReady, startFailed, dropped, other
}

/// Xbox yayını durunca günlük satırı ve kullanıcıya gösterilen metnin türü.
public enum XboxStop {
    /// Kullanıcı metninde gösterilen ham nedenin en çok uzunluğu (Xbox hizmeti 500 karakterlik JSON dönebilir).
    public static let reasonLimit = 120

    /// Ham nedene bakılır: ilk kare gelmeyince de hata türü `consoleUnavailable` olur ama o durumda "Xbox'a ulaşılamadı"
    /// yanlış olur (Android'deki `stopKind` ile aynı).
    public static func classify(_ reason: String?, kind: XboxErrorKind? = nil) -> XboxStopKind {
        if kind == .noFirstFrame { return .noPicture }
        let text = reason ?? ""
        func has(_ word: String) -> Bool { text.range(of: word, options: .caseInsensitive) != nil }
        if kind == .busy || has("InUse") || has("Busy") || has("AlreadyStreaming") { return .busy }
        let code = errorCode(text)
        if has("Cloud Streaming Service") || code == serviceNotReadyCode { return .serviceNotReady }
        if has("Offline") || has("NotFound") || has("Unavailable") || has("PowerOff") || has("StreamingDisabled") { return .consoleUnavailable }
        return code == nil ? .other : .startFailed
    }

    /// "Timed out waiting for Cloud Streaming Service to be ready" hatasının kodu: Xbox'ın verdiği -2147019873, HRESULT
    /// 0x8007139F (Win32 5023, ERROR_INVALID_STATE).
    public static let serviceNotReadyCode = "0x8007139F"

    /// Bu neden yeniden denenmez: Xbox kendi hizmetini başlatamıyor, yeniden denemek yalnız Xbox'ta "uzaktan oynatma
    /// başlatıldı / durduruldu" bildirimini tekrarlar; Xbox'ı kullanıcının yeniden başlatması gerekir.
    public static func isPermanent(_ reason: String?) -> Bool { classify(reason) == .serviceNotReady }

    /// Xbox hizmetinin hata nesnesindeki (errorDetails ya da HTTP gövdesi) kod. `Agent : -2147019873 : …` ve 0x… biçimi
    /// HRESULT olarak (0x8007139F), yoksa `"code"` alanı olduğu gibi; bulunamazsa nil.
    public static func errorCode(_ reason: String?) -> String? {
        guard let text = reason, !text.isEmpty else { return nil }
        if let agent = firstGroup(#"Agent\s*:\s*(-?\d+)"#, text) { return hresult(agent) }
        if let hex = firstGroup(#"\b0[xX]([0-9A-Fa-f]{8})\b"#, text) { return "0x" + hex.uppercased() }
        if let code = firstGroup(#""(?:code|errorCode|hresult)"\s*:\s*"?(-?[A-Za-z0-9_.]+)"#, text), code != "null" {
            return hresult(code)
        }
        return nil
    }

    /// Hata nesnesindeki `"message"` metni (JSON kaçışları açılmış); yoksa nil.
    public static func errorMessage(_ reason: String?) -> String? {
        guard let text = reason, let raw = firstGroup(#""(?:message|errorMessage)"\s*:\s*"((?:[^"\\]|\\.)*)""#, text) else { return nil }
        let message = raw.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        return message.trimmingCharacters(in: .whitespaces).isEmpty ? nil : message
    }

    /// Ekrandaki metne giren neden: `startFailed`te yalnız kod, `other`da JSON'suz kısa metin; ham neden yalnız günlüğe yazılır.
    public static func displayReason(_ reason: String?, _ kind: XboxStopKind, fallback: String = "?") -> String {
        switch kind {
        case .startFailed: return errorCode(reason) ?? fallback
        case .other:
            guard let text = reason, let brace = text.firstIndex(of: "{") else { return shorten(reason, fallback: fallback) }
            if let message = errorMessage(text) { return shorten(message, fallback: fallback) }
            return shorten(String(text[..<brace]).trimmingCharacters(in: CharacterSet(charactersIn: " :")), fallback: fallback)
        default: return shorten(reason, fallback: fallback)
        }
    }

    /// Ondalık HRESULT (-2147019873 ya da 2147947423) 0x8007139F biçimine çevrilir; başka değer olduğu gibi kalır.
    static func hresult(_ value: String) -> String {
        guard let number = Int64(value) else { return value }
        if number < 0, number >= Int64(Int32.min) { return String(format: "0x%08X", UInt32(bitPattern: Int32(number))) }
        if number >= 0x8000_0000, number <= 0xFFFF_FFFF { return String(format: "0x%08X", UInt32(number)) }
        return value
    }

    private static func firstGroup(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Ham nedeni tek satıra indirir ve `limit` karakterde keser; boşsa `fallback`.
    public static func shorten(_ reason: String?, limit: Int = reasonLimit, fallback: String = "?") -> String {
        let line = (reason ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if line.isEmpty { return fallback }
        return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
    }

    /// Bağlantı bitince yazılan özet: neden, kare ve onay sayısı, ilk kareden sonra kaç saniye sürdüğü. "Görüntü hiç
    /// gelmedi" ile "görüntü geldi, sonra kesildi" bu satırla ayrılır.
    public static func summary(reason: String?, frames: Int, acks: Int? = nil, secondsSinceFirstFrame: Int?, cause: XboxEndCause? = nil) -> String {
        let why = (reason ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "durduruldu" : reason!
        let lived = secondsSinceFirstFrame.map { "\($0) sn" } ?? "ilk kare yok"
        return "bağlantı bitti\(cause.map { " (\($0.rawValue))" } ?? ""): \(why); kare \(frames), \(acks.map { "onay \($0), " } ?? "")ilk kareden sonra \(lived)"
    }
}

/// Bir saat adımında yapılacaklar: Xbox'tan anahtar kare istenir mi, tanı satırı yazılır mı.
public struct XboxWatchStep: Equatable, Sendable {
    public var requestKeyframe = false
    public var logStats = false

    public init(requestKeyframe: Bool = false, logStats: Bool = false) {
        self.requestKeyframe = requestKeyframe
        self.logStats = logStats
    }
}

/// Xbox görüntüsü başlayana kadar yapılanlar. Xbox kare onayı alamazsa oturumu ~60 sn sonra kapatır; onay yalnız
/// gösterilen karede gider, kare hiç gelmezse onay da gitmez. İlk kare gelene kadar kontrol kanalından anahtar kare
/// istenir (xbox-xcloud-player Channel/Control.ts `requestKeyframeRequest`) ve bağlantıdan 10 sn sonra, sonra 10 sn'de
/// bir tanı satırı yazılır.
public struct XboxFirstFrameWatch {
    /// Bağlantıdan sonra ilk kare için beklenen en uzun süre; dolunca bağlantı `.noFirstFrame` ile kapatılır, Xbox'ın
    /// kendisi kapatması (~60 sn) beklenmez (Windows ve Android'de de 30 sn).
    public static let firstFrameLimitMs = 30_000
    public static let keyframeIntervalMs = 2500
    /// Bu süreden sonra anahtar kare istenmez; tanı satırları sürer.
    public static let keyframeWindowMs = 20_000
    public static let statsDelayMs = 10_000
    public static let statsIntervalMs = 10_000
    /// Saatin adımı.
    public static let tickMs = 500
    /// Kontrol kanalı iletisi (Control.ts `requestKeyframeRequest`).
    public static let keyframeRequest = "{\"message\":\"videoKeyframeRequested\",\"ifrRequested\":true}"

    private var lastKeyframe: Int?
    private var nextStats = XboxFirstFrameWatch.statsDelayMs
    /// İlk kare geldi; bundan sonra hiçbir şey yapılmaz.
    public private(set) var frameSeen = false
    public private(set) var keyframesRequested = 0

    public init() {}

    public mutating func frameArrived() { frameSeen = true }

    /// `sinceConnectedMs`: bağlantıdan (input kanalı açıldı) bu yana geçen süre. `keyframeReady`: görüntü parçası var ve
    /// kontrol kanalı açık.
    public mutating func tick(sinceConnectedMs: Int, keyframeReady: Bool) -> XboxWatchStep {
        if frameSeen { return XboxWatchStep() }
        let keyframe = keyframeReady && sinceConnectedMs <= Self.keyframeWindowMs
            && (lastKeyframe.map { sinceConnectedMs - $0 >= Self.keyframeIntervalMs } ?? true)
        if keyframe {
            lastKeyframe = sinceConnectedMs
            keyframesRequested += 1
        }
        let stats = sinceConnectedMs >= nextStats
        // Saat takıldıysa kaçan satırlar art arda yazılmaz.
        if stats { while nextStats <= sinceConnectedMs { nextStats += Self.statsIntervalMs } }
        return XboxWatchStep(requestKeyframe: keyframe, logStats: stats)
    }
}

/// Görüntü bekçisinin bir saat adımındaki kararı.
public enum XboxPictureVerdict: Equatable, Sendable {
    case fine
    /// Görüntü `warnAfterMs`'dir gelmiyor ya da ICE bağlantısı takıldı: ana ekranda "bağlı" yerine uyarı (bir kez).
    case warn
    /// Uyarıdan sonra görüntü yeniden geliyor: yeniden "bağlı".
    case recovered
    /// Oturum kapatılıp yeniden kurulmalı; değer günlükteki neden.
    case stalled(String)
}

/// İlk kareden sonra Xbox görüntüsünün kesilip kesilmediği (PS5'teki `PictureWatchdog`un Xbox karşılığı). Eskiden
/// yayın yalnız WebRTC bağlantısı `failed`/`closed` olunca, input kanalı kapanınca ya da canlı tutma üç kez yanıtsız
/// kalınca bitiyordu: ICE `disconnected`da takılı kalan ya da kare göndermeyi bırakan yayında ana ekran "bağlı"
/// diyor, altyazı donuyor ve bir daha gelmiyordu (X'te kullanıcı bildirimi, iPhone + Xbox Series S). Kare
/// `warnAfterMs` gelmezse (ICE `disconnected` iken 1 sn) uyarı gösterilir; `stallAfterMs` gelmezse ya da ICE
/// `failed` olursa oturum kapatılıp `XboxSessionMachine`le (sessizce en çok iki kez: 5, 15 sn sonra) yeniden kurulur. İlk kareden sonraki
/// `startupGraceMs` içinde yalnız ICE `failed` oturumu kapatır: yayının başında Xbox görüntüyü birkaç saniye
/// bekletebiliyor (yükleme, "uzaktan yürütme başlatıldı" bildirimi); eskiden bu boşlukta oturum kapatılıp yeniden
/// açılıyor, Xbox'ta başladı/durdu döngüsü oluyordu (Play, Android beta.85). Windows'taki
/// CouchSubs.Shell/XboxPictureWatch ve Android'deki XboxPictureWatch ile birebir.
public struct XboxPictureWatch {
    public static let warnAfterMs = 5000
    public static let stallAfterMs = 12_000
    /// ICE `disconnected` iken uyarı için yeterli boşluk (bağlantı takılınca kareler hemen kesilir).
    public static let iceWarnAfterMs = 1000
    /// İlk kareden sonra bu süre içinde kare boşluğu oturumu kapatmaz (yalnız uyarı); ICE `failed` yine kapatır.
    public static let startupGraceMs = 30_000

    /// RTCIceConnectionState'in bekçiyi ilgilendiren kısmı.
    public enum Ice: Sendable {
        case connected, disconnected, failed, other
    }

    private var firstFrameMs: Int?
    private var lastFrameMs: Int?
    private var iceLostSinceMs: Int?
    private var iceFailed = false
    /// Uyarı gösteriliyor.
    public private(set) var warned = false

    public init() {}

    public mutating func frameArrived(atMs now: Int) {
        if firstFrameMs == nil { firstFrameMs = now }
        lastFrameMs = now
    }

    /// Görüntü akıyor mu: son kare `warnAfterMs`'den yeni. Akan yayın canlı tutma hatasıyla kapatılmaz
    /// (bkz. `XboxKeepalive.shouldEnd`).
    public func isFlowing(atMs now: Int) -> Bool {
        guard let last = lastFrameMs else { return false }
        return now - last < Self.warnAfterMs
    }

    public mutating func iceChanged(_ state: Ice, atMs now: Int) {
        switch state {
        case .connected: iceLostSinceMs = nil
        case .disconnected: if iceLostSinceMs == nil { iceLostSinceMs = now }
        case .failed: iceFailed = true
        case .other: break
        }
    }

    /// Saniyede bir çağrılır. İlk kare gelmeden karar verilmez (ilk kare sınırı ayrı).
    public mutating func tick(atMs now: Int) -> XboxPictureVerdict {
        guard let last = lastFrameMs else { return .fine }
        let iceLost = iceLostSinceMs != nil
        if iceFailed { return .stalled("Xbox ICE bağlantısı koptu (failed)") }
        let gap = now - last
        let starting = firstFrameMs.map { now - $0 < Self.startupGraceMs } ?? false
        if gap >= Self.stallAfterMs && !starting {
            return .stalled("Xbox'tan \(gap / 1000) sn'dir görüntü gelmiyor (\(iceLost ? "ICE disconnected" : "bağlantı açık görünüyor"))")
        }
        let trouble = gap >= Self.warnAfterMs || (iceLost && gap >= Self.iceWarnAfterMs)
        if trouble, !warned {
            warned = true
            return .warn
        }
        if !trouble, warned {
            warned = false
            return .recovered
        }
        return .fine
    }
}

/// getStats raporunun bir girdisi (RTCStats: tür, kimlik, alanlar).
public struct XboxStat {
    public let type: String
    public let id: String
    public let members: [String: Any]

    public init(type: String, id: String, members: [String: Any]) {
        self.type = type
        self.id = id
        self.members = members
    }
}

/// WebRTC getStats özetini tek günlük satırına çevirir; Windows'taki XboxStreamStats ile aynı biçim.
public enum XboxStreamStats {
    /// `codec`: anlaşılan görüntü kodeği tanı satırına girer.
    public static let types: Set<String> = ["inbound-rtp", "candidate-pair", "local-candidate", "remote-candidate", "transport", "codec"]

    /// Telefonda ve Mac'te video öğesi yok: görüntü parçasının durumu (LIVE, ENDED).
    public static func picture(trackState: String) -> String { "görüntü parça \(trackState)" }

    /// Görüntü verisi hiç gelmediyse (bayt 0) libwebrtc çözücüyü kurmaz; "çözücü" alanı bunu söyler (#1252).
    public static let decoderNotStarted = "kurulmadı, görüntü verisi gelmedi"

    /// - Parameters:
    ///   - negotiatedCodec: Xbox'ın SDP yanıtında seçtiği görüntü kodeği (getStats kodeği ilk kareye kadar boştur).
    ///   - decoder: uygulamanın bildiği çözücü durumu (ad, donanım/yazılım); getStats'ta yoksa kullanılır.
    public static func describe(sinceConnectedMs: Int, frameSeen: Bool, keyframes: Int, stats: [XboxStat], picture: String,
                                negotiatedCodec: String? = nil, decoder: String? = nil) -> String {
        var line = "tanı (\(sinceConnectedMs / 1000) sn, \(frameSeen ? "ilk kare geldi" : "ilk kare yok")): keyframe isteği \(keyframes); "
        if let video = stats.first(where: { $0.type == "inbound-rtp" && (text($0, "kind") ?? text($0, "mediaType")) == "video" }) {
            line += "video paket \(number(video, "packetsReceived")), bayt \(number(video, "bytesReceived")), kayıp \(number(video, "packetsLost")), "
            line += "çözülen \(number(video, "framesDecoded")), düşen \(number(video, "framesDropped")), anahtar kare \(number(video, "keyFramesDecoded")), "
            let noData = number(video, "bytesReceived") == "0"
            line += "PLI \(number(video, "pliCount")), çözücü \(text(video, "decoderImplementation") ?? decoder ?? (noData ? decoderNotStarted : "?"))"
            if let codec = byId(stats, text(video, "codecId")) {
                line += ", kodek \(text(codec, "mimeType") ?? "?") \(text(codec, "sdpFmtpLine") ?? "")".trimmingCharacters(in: .whitespaces)
            } else if let negotiatedCodec {
                line += ", kodek \(negotiatedCodec) (SDP yanıtı)"
            }
            line += "; "
        } else {
            line += "video yok; "
        }
        // Ses de geliyor mu (#1416): video yalnız dolgu paketiyken (bayt 0) ses akıyorsa Xbox yayını başlatmış, yalnız
        // görüntüyü kodlamıyor; ses de yoksa Xbox'ın yayın hizmeti hiç başlamamış.
        if let audio = stats.first(where: { $0.type == "inbound-rtp" && (text($0, "kind") ?? text($0, "mediaType")) == "audio" }) {
            line += "ses paket \(number(audio, "packetsReceived")), bayt \(number(audio, "bytesReceived")); "
        } else {
            line += "ses yok; "
        }
        if let pair = selectedPair(stats) {
            let local = byId(stats, text(pair, "localCandidateId"))
            let remote = byId(stats, text(pair, "remoteCandidateId"))
            line += "aday yerel \(field(local, "candidateType"))/\(field(local, "protocol")) ağ \(field(local, "networkType")), "
            line += "uzak \(field(remote, "candidateType")), durum \(text(pair, "state") ?? "?"); "
        } else {
            line += "aday seçilmedi; "
        }
        return line + picture
    }

    private static func selectedPair(_ stats: [XboxStat]) -> XboxStat? {
        for transport in stats where transport.type == "transport" {
            if let pair = byId(stats, text(transport, "selectedCandidatePairId")) { return pair }
        }
        let pairs = stats.filter { $0.type == "candidate-pair" }
        return pairs.first { flag($0, "selected") } ?? pairs.first { flag($0, "nominated") && text($0, "state") == "succeeded" }
    }

    private static func byId(_ stats: [XboxStat], _ id: String?) -> XboxStat? {
        guard let id else { return nil }
        return stats.first { $0.id == id }
    }

    private static func field(_ stat: XboxStat?, _ name: String) -> String { stat.flatMap { text($0, name) } ?? "?" }

    private static func text(_ stat: XboxStat, _ name: String) -> String? { stat.members[name] as? String }

    /// Yalnız gerçek Bool (JSON `true`, NSNumber(bool)); 1 sayısı sayılmaz.
    private static func flag(_ stat: XboxStat, _ name: String) -> Bool {
        guard let value = stat.members[name] else { return false }
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue }
        return value as? Bool ?? false
    }

    private static func number(_ stat: XboxStat, _ name: String) -> String {
        guard let value = stat.members[name], !(value is String) else { return "?" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "?" }
            return String(Int64(number.doubleValue))
        }
        return "?"
    }
}
