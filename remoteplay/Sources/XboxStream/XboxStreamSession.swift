// SPDX-License-Identifier: AGPL-3.0-only
// Xbox ev yayını (Beta): Windows'taki XboxStreamSession + player.html'in iPhone ve Mac karşılığı (Android:
// XboxStreamSession.kt). iPhone ve Mac uygulamalarının ortak oturumu; protokol katmanı CouchSubsCore/Xbox'ta.
// Görüntü yerel WebRTC'yle (stasel/WebRTC) alınır; VideoToolbox'ın verdiği kare CGImage olarak okuma hattına gider.
// Oyun sesi ayar açıksa (varsayılan açık) bu cihazda çalınır: Xbox uzaktan oynatma sürerken sesi istemciye verip TV'yi
// susturabilir. Yerel ses parçası eklenmez, Xbox'a ses gönderilmez. iPhone'da ses mikrofonsuz, yalnız-çalma birimiyle
// (XboxPlayoutDevice) medya sesi olarak seçili çıkıştan çalar; ayar kapalıyken birim hiç başlatılmaz, Mac'te ses
// parçası kapatılır. Kumanda girdisi gönderilmez.
// Sağlamlık kuralları Windows (#538, #611) ve Android ile aynı (CouchSubsCore XboxSessionHealth): ilk kare gelene kadar
// anahtar kare istenir ve tanı satırı yazılır; tek başarısız canlı tutma isteği yayını bitirmez, ardışık üçü bitirir;
// bağlantı bitince özet satırı yazılır; yayın durunca metin nedene göre seçilir. İlk kareden sonra görüntü kesilirse
// (ICE `disconnected`da takılı kalsa da) uyarı gösterilir ve oturum yeniden kurulur (XboxPictureWatch).

#if os(iOS)
import AVFoundation
#endif
import CoreGraphics
import CouchSubsCore
import Foundation
import RemotePlay
import VideoToolbox
import WebRTC

public final class XboxStreamSession: NSObject, @unchecked Sendable {
    public var onFrame: ((CGImage) -> Void)?
    public var onState: ((SessionState) -> Void)?
    /// Xbox'ta kullanılmaz (uygulamaların `StreamControlling` protokolü ister).
    public var onConsoleMoved: ((RegisteredConsole) -> Void)?

    private static let iceGatherMs = 5000
    private static let keepaliveSeconds: UInt64 = 30
    private static let firstFrameSeconds = TimeInterval(XboxFirstFrameWatch.firstFrameLimitMs / 1000)
    private static let connectSeconds = TimeInterval(XboxConnectWatch.connectLimitMs / 1000)
    private static let reconnectReason = "Yeniden bağlanılıyor"
    /// Okuma saniyede birkaç kez yapılır; her kareyi CGImage'a çevirmeye gerek yok.
    private static let frameInterval: TimeInterval = 0.066
    /// Kare onayları oynatıcıdaki gibi 16 ms'de bir paketlenir (Input.ts `_inputInterval`).
    private static let ackIntervalNs: UInt64 = 16_000_000

    private let auth: XboxAuth
    private let console: XboxConsole
    private let home: XboxHome
    private let describe: (XboxErrorKind) -> String
    private let stopText: (XboxStopKind, String) -> String
    private let lock = NSLock()
    private var machine = XboxSessionMachine()
    private var task: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var peer: RTCPeerConnection?
    private var channels: [String: RTCDataChannel] = [:]
    private var channelDelegates: [ChannelDelegate] = []
    private var localCandidates: [XboxIceCandidate] = []
    private var gatheringComplete = false
    private var endReason: String?
    /// Bağlantıyı bitiren olayın türü (`endReason` ile birlikte yazılır): kapanma nedenini ve ekrandaki metni seçer.
    private var endKind: XboxErrorKind?
    private var sessionId: String?
    /// Kapatılamayan (DELETE başarısız) oturumlar ve süren kapanışlar süreç genelinde `XboxCloseGate`'te: yeni oturum
    /// (bu nesneninki ya da "Yeniden bağlan"la açılan yeni nesneninki) önce onları bekler ve kapatır. Kapatılmadan yenisi
    /// açılınca Xbox eski oturumu açık sayıp yeni oturumu reddediyordu.
    private let closeGate = XboxCloseGate.shared
    private var lastConverted: TimeInterval = 0
    public private(set) var framesReceived = 0
    /// Kare onayı (Windows'taki xbox-xcloud-player her gösterilen karede yapar): Xbox onay gelmeyen yayını kısa sürede
    /// kapatır (Greenlight wiki, WebRTC: "Without sending any data back the stream will only last for +- 40 seconds").
    private var pendingAcks: [XboxFrameAck] = []
    private var acking = false
    private var ackSequence: UInt32 = 0
    private var acksSent = 0
    private var ackTask: Task<Void, Never>?
    /// Onay paketlerindeki anların sıfırı (oynatıcıdaki performance.now() gibi).
    private var clockStart: TimeInterval = 0
    private var firstFrameAt: TimeInterval = 0
    /// Görüntü başlayana kadar anahtar kare isteği ve tanı (input kanalı açılınca başlar, ilk karede durur).
    private var watch: XboxFirstFrameWatch?
    private var watchTask: Task<Void, Never>?
    private var connectedAt: TimeInterval = 0
    private var videoTrack: RTCVideoTrack?
    /// Xbox'ın SDP yanıtında seçtiği görüntü kodeği (tanı satırı için, #1252).
    private var negotiatedCodec: String?
    /// İlk kareden sonra görüntü kesilirse uyarı ve yeniden kurma (kareler ve ICE olayları buraya yazılır).
    private var picture = XboxPictureWatch()
    /// Görüntü alıcısından okuma hattına kare aktarımı (#1308): alıcı (WebRTC'nin iş parçacığı) yalnız kareyi kutuya
    /// bırakıp döner; kareyi resme çevirme ve okuma hattına verme ayrı bir sırada, yalnız en son kareyle yapılır.
    /// Eskiden çevirme ve `onFrame` alıcıda çalışıyordu; alıcı yavaşlayınca WebRTC'nin kare kuyruğu büyüyordu.
    private let frameBox = FrameMailbox<RTCVideoFrameBuffer>()
    private let frameQueue = DispatchQueue(label: "CouchSubs Xbox kare", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var pipeStats = XboxFramePipeStats()
    private var pipeTask: Task<Void, Never>?
    /// Son karenin ve son kare onayı paketinin anı (ms; kapanma satırı için).
    private var lastFrameAtMs = 0
    private var lastAckAtMs = 0

    /// Oyun sesi bu cihazda çalınır (Android'deki `playAudio` ile aynı). Çeviri sürerken `setPlayAudio` ile değişir.
    private var playAudio: Bool
    /// Xbox'tan gelen ses parçası; ayar değişince yalnız bu açılıp kapatılır.
    private var audioTrack: RTCMediaStreamTrack?

    /// Ekran metinleri uygulamanın kataloğundan gelir. `describe`: yeniden denenirken gösterilen durum; `stopped`: yayın
    /// durunca (denemeler bitti ya da konsol reddetti) nedenin türüne göre gösterilen metin (ikinci değer kısaltılmış neden).
    /// `http`: ev yayını uçlarına giden istekler (testlerde sahtesi).
    public init(auth: XboxAuth, console: XboxConsole, playAudio: Bool = true, http: XboxHTTP = URLSessionXboxHTTP(),
                describe: @escaping (XboxErrorKind) -> String, stopped: @escaping (XboxStopKind, String) -> String) {
        self.auth = auth
        self.console = console
        self.home = XboxHome(auth: auth, http: http)
        self.playAudio = playAudio
        self.describe = describe
        self.stopText = stopped
    }

    #if os(iOS)
    /// iPhone'da oyun sesi yalnız-çalma birimiyle çalınır (bkz. XboxPlayoutDevice, #907).
    private static let playout = XboxPlayoutDevice()
    #endif

    /// Kurulan görüntü çözücüsü tanı satırına yazılır (#1252); çözücüler RTCDefaultVideoDecoderFactory'ninki.
    private static let decoders = XboxDecoderFactory()

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        #if os(iOS)
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: decoders,
                                        audioDevice: playout)
        #else
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: decoders)
        #endif
    }()

    /// Oyun sesini açar ya da kapatır. Ses medya sesi gibi (.playback) kullanıcının seçtiği çıkıştan çalınır
    /// (kulaklık, AirPods, Bluetooth hoparlör; yoksa hoparlör). WebRTC'nin varsayılan görüşme birimi (.playAndRecord +
    /// .defaultToSpeaker, mikrofonlu VoiceProcessingIO) Bluetooth kulaklığı bırakıp sesi hoparlöre veriyordu (#907).
    /// Mikrofon açılmaz, Xbox'a hiçbir şey gönderilmez.
    private static func setAudio(_ enabled: Bool) {
        // Mac'te ses oturumu yoktur: ses sistemin çıkışından çalınır, kapalıyken ses parçası kapatılır.
        #if os(iOS)
        playout.setEnabled(enabled)
        #endif
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func log(_ text: String) { RemotePlayLog.write("Xbox: \(text)") }

    /// "Xbox sesini bu cihazda çal" çeviri sürerken değişti: yalnız yerel ses açılır ya da kısılır, Xbox'a yeni oturum
    /// açılmaz. Eskiden ayar değişince yayın kapatılıp hemen yeniden açılıyordu; Xbox eski oturumu kapatmadan gelen yeni
    /// istekte uzaktan oynatma hizmetini başlatamıyor, bağlantı kopup geri gelmiyordu (#871).
    public func setPlayAudio(_ enabled: Bool) {
        let track = locked { () -> RTCMediaStreamTrack? in
            guard playAudio != enabled else { return nil }
            playAudio = enabled
            return audioTrack
        }
        guard let track else { return }
        track.isEnabled = enabled
        Self.setAudio(enabled)
        log(enabled ? "oyun sesi açıldı (ayar, oturum sürüyor)" : "oyun sesi kapatıldı (ayar, oturum sürüyor)")
    }

    public func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .userInitiated) { [weak self] in await self?.run() }
    }

    /// Oturum durur: bağlantı kapatılır ve oturum Xbox hizmetinde kapatılır (DELETE). Kapanış `XboxCloseGate`'e kaydedilir;
    /// hemen ardından açılan yeni oturum (Yeniden bağlan, öne dönüş) `play`dan önce bunun bitmesini bekler. Kapanış oturuma
    /// güçlü başvuru tutar: uygulama oturumu bıraksa da DELETE gider (eskiden zayıf başvuruydu, nesne gidince kapanış
    /// atlanabiliyordu). Süren döngü de beklenir: iptal edilen döngü o sırada açtığı oturumu kendisi kapatır.
    public func stop() {
        locked { machine.stop() }
        let running = task
        running?.cancel()
        task = nil
        log("oturum durduruluyor: bağlantı ve Xbox oturumu kapatılıyor")
        closeGate.track { [self] in
            await teardown()
            await running?.value
        }
        onState?(.disconnected(.stopped))
    }

    /// Uygulama öne gelince: süren el sıkışma ya da bağlantı kapatılıp baştan açılır.
    public func reconnectNow() {
        locked { if endReason == nil { endReason = Self.reconnectReason } }
    }

    private var stopped: Bool { locked { machine.phase == .stopped } }

    /// Bağlantıyı bitiren ilk olay kaydedilir (neden ve türü); sonrakiler ilkinin yerine geçmez.
    private func end(_ reason: String, _ kind: XboxErrorKind) {
        locked {
            guard endReason == nil else { return }
            endReason = reason
            endKind = kind
        }
    }

    private func run() async {
        log("konsol: \(console.name)")
        while !Task.isCancelled && !stopped {
            var action = locked { machine.start() }
            // Makine `/state` yanıtında kendisi karar verdiyse (Failed, errorDetails) aynı hata yeniden sayılmaz.
            var decided: XboxSessionMachine.Action?
            onState?(.connecting)
            do {
                // Önceki oturum (eski nesne, "Yeniden bağlan") kapanırken yenisi açılmaz: Xbox eskisini açık sayıyordu.
                if let waited = await closeGate.waitForPending() { log(waited.line) }
                for stale in closeGate.takeStale() {
                    log("önceki oturum Xbox'ta açık kalmış olabilir: yeni oturumdan önce kapatılıyor (\(stale.prefix(8))…)")
                    await closeRemote(stale)
                }
                try Task.checkCancellation()
                log("oturum açılıyor: \(console.name)")
                let id = try await home.play(consoleId: console.id)
                log("play yanıtı: oturum \(id.prefix(8))…")
                locked { sessionId = id }
                action = locked { machine.played() }
                loop: while !Task.isCancelled {
                    switch action {
                    case let .pollState(delay):
                        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                        let status = try await home.state(id)
                        if status.state != "Provisioning" { log("durum: \(status.state)") }
                        if let details = status.errorDetails { log("errorDetails: \(details)") }
                        action = locked { machine.status(status.state, errorDetails: status.errorDetails) }
                    case .connect:
                        try await home.connect(id)
                        log("connect: başarılı")
                        action = locked { machine.connected() }
                    case .negotiate:
                        try await negotiate(id)
                        break loop
                    case .retry:
                        decided = action
                        if case let .failed(kind, message, _, _) = locked({ machine.phase }) { throw XboxError(kind, message) }
                        throw XboxError(.service, "Xbox")
                    case .play, .nothing:
                        break loop
                    }
                }
                if !Task.isCancelled && !stopped {
                    let (reason, kind, noFirstFrame) = locked { (endReason, endKind, connectedAt > 0 && framesReceived == 0 && endReason != Self.reconnectReason) }
                    // Bağlantı kuruldu ama Xbox tek kare göndermeden kapattı: "görüntü gelmedi" sayılır (iki bağlantıda durulur).
                    throw XboxError(noFirstFrame ? .noFirstFrame : kind ?? .network, reason ?? "Xbox görüntü bağlantısı kapandı")
                }
            } catch is CancellationError {
            } catch let error as XboxError {
                action = decided ?? locked { machine.fail(error.kind, error.message) }
                report(error.kind, error.message, retryDelayMs: Self.delay(action))
            } catch {
                action = locked { machine.fail(.service, error.localizedDescription) }
                report(.service, error.localizedDescription, retryDelayMs: Self.delay(action))
            }
            summarize()
            await teardown()
            guard !Task.isCancelled, !stopped, case let .retry(delay?) = action else { break }
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        }
        // Denemeler bitti ya da konsol reddetti: `reconnectNow` bundan sonra bir şey yapmaz, uygulama yeni oturum açar.
        if !Task.isCancelled && !stopped { locked { gaveUp = true } }
    }

    private static func delay(_ action: XboxSessionMachine.Action) -> Int? {
        if case let .retry(delay) = action { return delay }
        return nil
    }

    /// Yeniden denemeler bitti, yayın kendiliğinden durdu (kullanıcı durdurmadı).
    public var hasGivenUp: Bool { locked { gaveUp } }
    private var gaveUp = false

    /// Bağlantı bitince: kaç kare geldi, kaç onay gitti, ilk kareden kaç saniye sonra ve neden bitti.
    private func summarize() {
        let (frames, sent, first, reason, error, kind) = locked { (framesReceived, acksSent, firstFrameAt, endReason, lastError, lastKind) }
        guard frames > 0 || reason != nil || error != nil else { return }
        log(XboxStop.summary(reason: reason ?? error, frames: frames, acks: sent,
                             secondsSinceFirstFrame: first > 0 ? Int(ProcessInfo.processInfo.systemUptime - first) : nil,
                             cause: kind.map(XboxEndCause.of)))
    }

    private var lastError: String?
    private var lastKind: XboxErrorKind?

    private func report(_ kind: XboxErrorKind, _ detail: String, retryDelayMs: Int?) {
        locked {
            lastError = "\(kind.rawValue): \(detail)"
            lastKind = kind
        }
        guard !stopped else { return }
        // Durum bildirilmeden önce: ana ekran "Yeniden bağlan"ı bu bildirimle hemen gösterir (Android ile aynı).
        if retryDelayMs == nil { locked { gaveUp = true } }
        log("kopma (\(kind.rawValue)): \(detail)")
        log(XboxEndCause.line(kind, detail))
        if kind == .noFirstFrame {
            log("Xbox görüntü göndermedi: bağlantı kuruldu ama tek kare gelmedi. Xbox'ta Ayarlar › Cihazlar ve bağlantılar › "
                + "Uzak özellikler açık mı, Xbox kablolu mu? Tanı satırlarında video bayt 0 ise Xbox hiç görüntü kodlamıyor")
        }
        let (phase, maxRetries, limited) = locked { (machine.phase, machine.maxRetries, machine.dropLimitReached) }
        if case let .failed(_, _, true, attempt) = phase, attempt > 0 {
            log(XboxEndCause.retryLine(attempt: attempt, of: maxRetries, delayMs: retryDelayMs ?? 0))
        } else if case .failed = phase, !XboxSessionMachine.fatal.contains(kind) {
            // Denemeler bitti ya da konsol yayını reddetti: yayın durur, yeniden denenmez.
            log(limited ? XboxEndCause.limitLine : "yeniden denenmiyor, yayın durdu")
            // Ham neden (Xbox'ın JSON hata nesnesi) yukarıda günlüğe yazıldı; ekranda yalnız anlaşılır metin ve kod (#871).
            // Sessiz yeniden bağlanma sınırı dolduysa: "Xbox bağlantısı koptu, Yeniden bağlan" (#1252).
            let stop = limited ? .dropped : XboxStop.classify(detail, kind: kind)
            onState?(.disconnected(.other(stopText(stop, XboxStop.displayReason(detail, stop, fallback: kind.rawValue)))))
            return
        }
        onState?(.disconnected(.other(describe(kind))))
    }

    private func teardown() async {
        keepaliveTask?.cancel()
        watchTask?.cancel()
        watchTask = nil
        ackTask?.cancel()
        ackTask = nil
        pipeTask?.cancel()
        pipeTask = nil
        frameBox.clear()
        locked {
            acking = false
            pendingAcks = []
            watch = nil
            videoTrack = nil
            audioTrack = nil
        }
        let (peer, channels, id) = locked { () -> (RTCPeerConnection?, [RTCDataChannel], String?) in
            let result = (self.peer, Array(self.channels.values), self.sessionId)
            self.peer = nil
            self.channels = [:]
            self.channelDelegates = []
            self.sessionId = nil
            return result
        }
        channels.forEach { $0.delegate = nil; $0.close() }
        peer?.close()
        Self.setAudio(false)
        if let id {
            // İptal edilmiş döngüden (stop, Yeniden bağlan) çağrılsa da DELETE gitsin: URLSession iptal edilmiş görevde
            // isteği hiç göndermeden hata veriyordu, oturum Xbox'ta açık kalıyordu.
            await Task.detached { [self] in await closeRemote(id) }.value
        }
    }

    /// Oturumu Xbox hizmetinde kapatır (birkaç deneme). Kapanmazsa bir sonraki `play`dan önce yeniden denenir; sonuç
    /// günlüğe yazılır (eskiden hata sessizce yutuluyordu).
    private func closeRemote(_ id: String) async {
        let result = await home.close(id)
        if result.closed {
            log("oturum kapatıldı: \(id.prefix(8))…")
            return
        }
        closeGate.addStale(id)
        log("oturum kapatılamadı (\(XboxSessionClose.delaysMs.count) deneme): \(XboxStop.shorten(result.error)); yeni oturumdan önce yeniden denenecek")
    }

    // MARK: - WebRTC

    private func negotiate(_ id: String) async throws {
        locked {
            endReason = nil
            endKind = nil
            lastKind = nil
            localCandidates = []
            gatheringComplete = false
            framesReceived = 0
            firstFrameAt = 0
            lastError = nil
            acking = false
            pendingAcks = []
            ackSequence = 0
            acksSent = 0
            clockStart = ProcessInfo.processInfo.systemUptime
            watch = nil
            connectedAt = 0
            negotiatedCodec = nil
            picture = XboxPictureWatch()
            lastFrameAtMs = 0
            lastAckAtMs = 0
            pipeStats = XboxFramePipeStats()
        }
        Self.decoders.reset()
        startPipeLog()
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]), RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw XboxError(.service, "WebRTC bağlantısı kurulamadı")
        }
        locked { peer = connection }
        // Oynatıcıdaki sıra: önce veri kanalları, sonra ses (gönder-al) ve görüntü (yalnız al).
        for (name, proto) in XboxChannels.channels {
            let channelConfig = RTCDataChannelConfiguration()
            channelConfig.isOrdered = true
            channelConfig.`protocol` = proto
            guard let channel = connection.dataChannel(forLabel: name, configuration: channelConfig) else {
                throw XboxError(.service, "Veri kanalı açılamadı: \(name)")
            }
            let delegate = ChannelDelegate(name: name, owner: self)
            channel.delegate = delegate
            locked {
                channels[name] = channel
                channelDelegates.append(delegate)
            }
        }
        let audioInit = RTCRtpTransceiverInit()
        audioInit.direction = .sendRecv
        let videoInit = RTCRtpTransceiverInit()
        videoInit.direction = .recvOnly
        let audio = connection.addTransceiver(of: .audio, init: audioInit)
        let video = connection.addTransceiver(of: .video, init: videoInit)
        let playAudio = locked { () -> Bool in
            audioTrack = audio?.receiver.track
            return self.playAudio
        }
        audio?.receiver.track?.isEnabled = playAudio
        Self.setAudio(playAudio)
        log(playAudio ? "oyun sesi bu cihazda çalınır" : "oyun sesi kapalı (ayar)")
        guard let track = video?.receiver.track as? RTCVideoTrack else { throw XboxError(.service, "Görüntü alıcısı kurulamadı") }
        track.add(self)
        locked { videoTrack = track }

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: XboxError(.service, "SDP teklifi: \(error?.localizedDescription ?? "?")")) }
            }
        }
        let munged = RTCSessionDescription(type: .offer, sdp: XboxChannels.mungeOffer(offer.sdp))
        try await set(connection, local: munged)
        log("SDP gönderiliyor")
        let answer = try await home.sdp(id, offer: munged.sdp)
        locked { negotiatedCodec = XboxSdp.negotiated(answer) }
        log(XboxSdp.summary(offer: munged.sdp, answer: answer))
        try await set(connection, remote: RTCSessionDescription(type: .answer, sdp: answer))
        // Yerel adaylar toplanana kadar (en çok 5 sn) beklenir.
        for _ in 0..<(Self.iceGatherMs / 100) where !locked({ gatheringComplete }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let candidates = locked { localCandidates }
        log("ICE: \(candidates.count) yerel aday gönderiliyor")
        let remote = try await home.ice(id, candidates: candidates)
        var added = 0
        for candidate in remote {
            guard let line = candidate.sdpLine else { continue }
            let ice = RTCIceCandidate(sdp: line, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
            let ok: Bool = await withCheckedContinuation { continuation in
                connection.add(ice) { error in continuation.resume(returning: error == nil) }
            }
            if ok { added += 1 }
        }
        log("ICE: Xbox'tan \(remote.count) aday, \(added) eklendi")

        let negotiatedAt = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled && !stopped {
            if locked({ endReason }) != nil { return }
            let (frames, connected) = locked { (framesReceived, connectedAt) }
            let now = ProcessInfo.processInfo.systemUptime
            // Görüntü kanalı açılmadı (ICE Wi-Fi'da kurulamadı): ilk kare sınırı kanal açılınca başlar.
            if connected == 0 && now - negotiatedAt > Self.connectSeconds {
                throw XboxError(.timeout, "Xbox ile görüntü bağlantısı \(Int(Self.connectSeconds)) sn içinde kurulamadı (ICE)")
            }
            if frames == 0 && connected > 0 && now - connected > Self.firstFrameSeconds {
                throw XboxError(.noFirstFrame, "Xbox'tan \(Int(Self.firstFrameSeconds)) sn içinde görüntü gelmedi")
            }
            try checkPicture()
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func nowMs() -> Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }

    /// Saniyede bir: ilk kareden sonra görüntü kesildiyse ana ekranda uyarı, uzun sürdüyse oturum kapatılır ve
    /// yeniden denenir (bkz. `XboxPictureWatch`). Uyarı sırasında okuma hattı ve TV'deki altyazı temizlenir.
    private func checkPicture() throws {
        switch locked({ picture.tick(atMs: Self.nowMs()) }) {
        case .fine:
            break
        case .warn:
            log("görüntü kesildi (\(XboxPictureWatch.warnAfterMs / 1000) sn kare yok ya da ICE takıldı); toparlanması bekleniyor")
            onState?(.disconnected(.other(describe(.noPicture))))
        case .recovered:
            log("görüntü yeniden geliyor")
            onState?(.streaming)
        case let .stalled(reason):
            log("\(reason); oturum yeniden kuruluyor")
            locked { if endReason == nil { endReason = reason } }
            throw XboxError(.noPicture, reason)
        }
    }

    private func set(_ connection: RTCPeerConnection, local: RTCSessionDescription? = nil, remote: RTCSessionDescription? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done: (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: XboxError(.service, "SDP: \(error.localizedDescription)")) }
                else { continuation.resume() }
            }
            if let local { connection.setLocalDescription(local, completionHandler: done) }
            else if let remote { connection.setRemoteDescription(remote, completionHandler: done) }
        }
    }

    fileprivate func channelChanged(_ name: String, _ channel: RTCDataChannel) {
        log("kanal \(name): \(channel.readyState.rawValue)")
        switch (name, channel.readyState) {
        case ("message", .open): send("message", Data(XboxChannels.handshake.utf8), binary: false)
        case ("input", .open):
            startKeepalive()
            startWatch()
        case ("input", .closed):
            if !stopped { log("input kanalı kapandı (Xbox görüntü kanalını kapattı): \(closeContext())") }
            end("Xbox görüntü kanalını kapattı", .serverClosed)
        default: break
        }
    }

    /// Kapanma anında akış ve onay sürüyor muydu (input kanalı ya da WebRTC bağlantısı kapanınca yazılır).
    private func closeContext() -> String {
        let (frameAt, ackAt, acks) = locked { (lastFrameAtMs, lastAckAtMs, acksSent) }
        return XboxCloseContext.describe(nowMs: Self.nowMs(), lastFrameAtMs: frameAt, lastAckAtMs: ackAt, acksSent: acks)
    }

    /// Bağlantı sürerken 10 sn'de bir kare hattının satırı (#1308): alıcıda geçen süre, atlanan kare ve bellek.
    private func startPipeLog() {
        pipeTask?.cancel()
        pipeTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(XboxFramePipeStats.windowMs) * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                let dropped = self.frameBox.takeDropped()
                let line = self.locked { () -> String? in
                    self.pipeStats.dropped(dropped)
                    return self.pipeStats.take(windowMs: XboxFramePipeStats.windowMs, memory: Self.memory())
                }
                if let line { self.log(line) }
            }
        }
    }

    /// Uygulamanın bellek ayak izi (Xcode'un ve iOS'un bellek sınırında saydığı phys_footprint).
    private static func memory() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return "bellek ?" }
        return "bellek \(info.phys_footprint / (1024 * 1024)) MB"
    }

    fileprivate func channelMessage(_ name: String, _ buffer: RTCDataBuffer) {
        if buffer.isBinary {
            // input kanalından gelenler: 16 = ServerMetadata, 128 = titreşim (her an gelir, yazılmaz).
            let type = buffer.data.first.map { Int($0) } ?? -1
            if type != 128 { log("kanal \(name): ikili ileti, tür \(type), \(buffer.data.count) bayt") }
            return
        }
        let text = String(decoding: buffer.data, as: UTF8.self)
        guard name == "message", XboxChannels.isHandshakeAck(text) else {
            // Xbox'ın kapatma bildirimi gibi iletiler (ör. TransactionStart) burada görünür.
            log("kanal \(name): \(text.prefix(300))")
            return
        }
        log("el sıkışma tamam")
        send("control", Data(XboxChannels.authorization.utf8), binary: false)
        send("control", Data(XboxChannels.gamepadAdded.utf8), binary: false)
        send("input", XboxChannels.clientMetadataPacket(timestampMs: sessionMs()), binary: true)
        XboxChannels.configurationMessages().forEach { send("message", Data($0.utf8), binary: false) }
        startAcks()
    }

    private func sessionMs(_ at: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        (at - locked { clockStart }) * 1000
    }

    /// El sıkışmadan sonra gösterilen karelerin onayı 16 ms'de bir `input` kanalına gider (oynatıcıdaki döngü).
    private func startAcks() {
        ackTask?.cancel()
        locked {
            pendingAcks = []
            acking = true
        }
        ackTask = Task.detached { [weak self] in
            var previous = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.ackIntervalNs)
                guard let self, !Task.isCancelled else { return }
                // Döngünün turları arası (kare hattı satırında "onay aralığı"): takılırsa Xbox onay alamaz.
                let now = DispatchTime.now().uptimeNanoseconds
                let gap = now &- previous
                previous = now
                self.locked { self.pipeStats.ackTick(gapNanos: gap) }
                let batch = self.locked { () -> (frames: [XboxFrameAck], sequence: UInt32)? in
                    guard self.acking, !self.pendingAcks.isEmpty else { return nil }
                    let frames = Array(self.pendingAcks.prefix(XboxChannels.maxFrameAcks))
                    self.pendingAcks.removeFirst(frames.count)
                    self.ackSequence &+= 1
                    self.acksSent += frames.count
                    self.lastAckAtMs = Self.nowMs()
                    return (frames, self.ackSequence)
                }
                guard let batch else { continue }
                self.send("input", XboxChannels.frameAckPacket(sequence: batch.sequence, timestampMs: self.sessionMs(), frames: batch.frames), binary: true)
                if batch.sequence == 1 { self.log("kare onayı başladı") }
            }
        }
    }

    private func send(_ name: String, _ data: Data, binary: Bool) {
        guard let channel = locked({ channels[name] }), channel.readyState == .open else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: binary))
    }

    /// Tek başarısız canlı tutma isteği yayını bitirmez (görüntü akarken ağ bir an takılabilir); görüntü durmuşken ardışık
    /// `XboxKeepalive.maxFailures` hata ya da 404/410 bitirir ve oturum baştan denenir (bkz. `XboxKeepalive.shouldEnd`).
    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task.detached { [weak self] in
            var keepalive = XboxKeepalive()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keepaliveSeconds * 1_000_000_000)
                guard let self, !Task.isCancelled, let id = self.locked({ self.sessionId }) else { return }
                do {
                    try await self.home.keepalive(id)
                    if keepalive.failures > 0 { self.log("canlı tutma yeniden yanıt verdi") }
                    keepalive.succeeded()
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    let end = keepalive.failed()
                    let detail = (error as? XboxError)?.message ?? error.localizedDescription
                    self.log("canlı tutma başarısız (\(keepalive.failures)/\(XboxKeepalive.maxFailures)): \(XboxStop.shorten(detail))")
                    // Oturum Xbox hizmetinde yok (404/410) ya da hatalar sınıra vardı; görüntü akıyorsa yayın sürer.
                    let gone = XboxKeepalive.sessionGone(detail)
                    let flowing = self.locked { self.picture.isFlowing(atMs: Self.nowMs()) }
                    guard XboxKeepalive.shouldEnd(gone: gone, exhausted: end, pictureFlowing: flowing) else {
                        if flowing && (gone || end) { self.log("görüntü akıyor: canlı tutma hatası yayını kapatmıyor") }
                        continue
                    }
                    if gone {
                        self.end("Xbox oturumu kapattı (canlı tutma: \(XboxStop.shorten(detail, limit: 60)))", .serverClosed)
                    } else {
                        self.end("Xbox canlı tutma isteklerine yanıt vermiyor", .timeout)
                    }
                    return
                }
            }
        }
    }

    /// Bağlantıdan (input kanalı açıldı) ilk kareye kadar: 2,5 sn'de bir, en çok 20 sn Xbox'tan anahtar kare istenir;
    /// 10 sn'den sonra 10 sn'de bir getStats tanısı yazılır. İlk kare gelince durur.
    private func startWatch() {
        watchTask?.cancel()
        let started = ProcessInfo.processInfo.systemUptime
        locked {
            watch = XboxFirstFrameWatch()
            connectedAt = started
        }
        watchTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ready = self.locked { self.videoTrack != nil && self.channels["control"]?.readyState == .open }
                let since = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                let (step, seen, requested) = self.locked { () -> (XboxWatchStep, Bool, Int) in
                    guard self.connectedAt == started, var current = self.watch else { return (XboxWatchStep(), true, 0) }
                    let step = current.tick(sinceConnectedMs: since, keyframeReady: ready)
                    self.watch = current
                    return (step, current.frameSeen, current.keyframesRequested)
                }
                if seen { return }
                if step.requestKeyframe {
                    if requested == 1 { self.log("ilk kare bekleniyor: Xbox'tan anahtar kare isteniyor") }
                    self.send("control", Data(XboxFirstFrameWatch.keyframeRequest.utf8), binary: false)
                }
                if step.logStats { self.logStats(sinceMs: since, keyframes: requested) }
                try? await Task.sleep(nanoseconds: UInt64(XboxFirstFrameWatch.tickMs) * 1_000_000)
            }
        }
    }

    private func logStats(sinceMs: Int, keyframes: Int) {
        let (connection, track) = locked { (peer, videoTrack) }
        guard let connection else { return }
        let picture = XboxStreamStats.picture(trackState: track.map { $0.readyState == .live ? "LIVE" : "ENDED" } ?? "yok")
        connection.statistics { [weak self] report in
            guard let self else { return }
            let stats = report.statistics.values.filter { XboxStreamStats.types.contains($0.type) }
                .map { XboxStat(type: $0.type, id: $0.id, members: $0.values) }
            let (seen, codec) = self.locked { (self.watch?.frameSeen ?? true, self.negotiatedCodec) }
            self.log(XboxStreamStats.describe(sinceConnectedMs: sinceMs, frameSeen: seen, keyframes: keyframes, stats: stats, picture: picture,
                                              negotiatedCodec: codec, decoder: Self.decoders.note))
        }
    }
}

// MARK: - Kareler

extension XboxStreamSession: RTCVideoRenderer {
    public func setSize(_ size: CGSize) {}

    /// Alıcı WebRTC'nin iş parçacığındadır ve hemen dönmelidir (#1308): kare yalnız kutuya bırakılır, resme çevirme ve
    /// `onFrame` `frameQueue`'da yapılır (yalnız en son kare; yetişilemeyen kare atlanır).
    public func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            let spent = DispatchTime.now().uptimeNanoseconds &- started
            locked { pipeStats.sink(nanos: spent) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let (count, due) = locked { () -> (Int, Bool) in
            framesReceived += 1
            lastFrameAtMs = Int(now * 1000)
            if framesReceived == 1 { firstFrameAt = now }
            picture.frameArrived(atMs: Int(now * 1000))
            let due = now - lastConverted >= Self.frameInterval
            if due { lastConverted = now }
            if acking {
                // timeStamp: karenin RTP zaman damgası (90 kHz), oynatıcıdaki serverDataKey (rtpTimestamp).
                let at = (now - clockStart) * 1000
                if pendingAcks.count >= 600 { pendingAcks.removeFirst() }
                pendingAcks.append(XboxFrameAck(serverDataKey: UInt32(bitPattern: frame.timeStamp), arrivalMs: at, decodedMs: at))
            }
            return (framesReceived, due)
        }
        if count == 1 {
            let waited = locked { () -> String in
                guard var current = watch else { return "" }
                current.frameArrived()
                watch = current
                return String(format: ", bağlantıdan %.1f sn sonra, keyframe isteği %d", locale: Locale(identifier: "en_US_POSIX"),
                              now - connectedAt, current.keyframesRequested)
            }
            log("ilk kare \(frame.width)x\(frame.height)\(waited)")
            if locked({ machine.streaming() }) { onState?(.streaming) }
        }
        guard due else { return }
        locked { pipeStats.handedOver() }
        guard frameBox.put(frame.buffer) else { return }
        frameQueue.async { [weak self] in self?.drainFrames() }
    }

    /// `frameQueue`'da: kutudaki en son kare resme çevrilip okuma hattına verilir; kutu boşalınca biter. Kareler
    /// akarken kutu hiç boşalmayabilir, döngü tek iş içinde sürer: her kare kendi autorelease havuzunda (#1390).
    private func drainFrames() {
        while let buffer = frameBox.take() {
            guard !stopped else { continue }
            autoreleasepool {
                let started = DispatchTime.now().uptimeNanoseconds
                if let image = Self.image(from: buffer) { onFrame?(image) }
                let spent = DispatchTime.now().uptimeNanoseconds &- started
                locked { pipeStats.processed(nanos: spent) }
            }
        }
    }

    /// VideoToolbox karesi doğrudan CGImage olur; yazılım çözücüsünün I420 karesinden gri (Y düzlemi) resim. WebRTC'nin
    /// I420'si sınırlı aralıklıdır (16–235): gri resim tam aralığa açılır (`VideoRange.expandLuma`), telefon araması
    /// VideoToolbox karesiyle ve dosyadaki kareyle aynı parlaklığı görür.
    public static func image(from buffer: RTCVideoFrameBuffer) -> CGImage? {
        if let pixel = buffer as? RTCCVPixelBuffer {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixel.pixelBuffer, options: nil, imageOut: &image)
            return image
        }
        let i420 = buffer.toI420()
        let width = Int(i420.width), height = Int(i420.height), stride = Int(i420.strideY)
        var data = Data(bytes: i420.dataY, count: stride * height)
        VideoRange.expandLuma(&data)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Bağlantı olayları

extension XboxStreamSession: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log("ICE: \(newState.rawValue)")
        let ice: XboxPictureWatch.Ice = switch newState {
        case .connected, .completed: .connected
        case .disconnected: .disconnected
        case .failed: .failed
        default: .other
        }
        guard locked({ peer === peerConnection }) else { return }
        locked { picture.iceChanged(ice, atMs: Self.nowMs()) }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { locked { gatheringComplete = true } }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        locked { localCandidates.append(XboxIceCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)) }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        log("bağlantı: \(newState.rawValue)")
        guard locked({ peer === peerConnection }) else { return }
        if (newState == .failed || newState == .closed) && !stopped {
            log("WebRTC bağlantısı kapandı (\(newState == .failed ? "FAILED" : "CLOSED")): \(closeContext())")
        }
        if newState == .failed { end("Xbox WebRTC bağlantısı kesildi (ICE failed)", .network) }
        else if newState == .closed { end("Xbox WebRTC bağlantısını kapattı", .serverClosed) }
    }
}

private final class ChannelDelegate: NSObject, RTCDataChannelDelegate {
    let name: String
    weak var owner: XboxStreamSession?
    init(name: String, owner: XboxStreamSession) {
        self.name = name
        self.owner = owner
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) { owner?.channelChanged(name, dataChannel) }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) { owner?.channelMessage(name, buffer) }
}
