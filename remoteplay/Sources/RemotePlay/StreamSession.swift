// SPDX-License-Identifier: AGPL-3.0-only

import CChiaki
import CoreGraphics
import Foundation

/// Saniyede en fazla belirli sayıda karenin geçmesine izin verir.
struct FrameThrottle {
    let minInterval: TimeInterval
    let now: () -> Date
    private var last: Date?

    init(minInterval: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.minInterval = minInterval
        self.now = now
    }

    mutating func shouldPass() -> Bool {
        let current = now()
        if let last, current.timeIntervalSince(last) < minInterval { return false }
        last = current
        return true
    }
}

/// Bağlantı koptuğunda yeniden deneme aralıkları: 2, 4, 8, 16, en çok 30 sn.
struct ReconnectPolicy {
    private var attempt = 0

    mutating func nextDelay() -> Int {
        defer { attempt = min(attempt + 1, 5) }
        return min(30, 2 << attempt)
    }

    mutating func reset() { attempt = 0 }
}

/// Bağlantının neden koptuğu; kullanıcıya anlatılabilecek biçimde.
public enum DisconnectReason: Equatable, Sendable {
    case stopped
    /// PS5 kapalı ya da uyandırılamadı.
    case consoleAsleep
    /// Remote Play başka bir cihazda kullanılıyor.
    case inUse
    /// PS5 bağlantıyı reddetti (ör. kayıt geçersiz ya da Uzaktan Oynatma kapalı).
    case refused
    case network
    /// İkinci kullanıcının PS5'te giriş şifresi var; Uzaktan Oynatma şifre istiyor.
    case loginPasscode
    /// Kayıtlı adreste PS5 aramaya yanıt vermedi ve oturum da açılamadı (değer: adres).
    case notFound(String)
    case other(String)

    /// Oturum ağ hatasıyla düştüyse ve PS5 aramaya da yanıt vermediyse neden "bulunamadı"dır (eskiden yalnız
    /// "Yeniden bağlanılıyor…" görünüyordu).
    static func classify(_ reason: DisconnectReason, searchAnswered: Bool, host: String) -> DisconnectReason {
        guard !searchAnswered else { return reason }
        switch reason {
        case .network, .other: return .notFound(host)
        default: return reason
        }
    }

    init(quit: ChiakiQuitReason) {
        switch quit {
        case CHIAKI_QUIT_REASON_STOPPED: self = .stopped
        case CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE: self = .inUse
        case CHIAKI_QUIT_REASON_SESSION_REQUEST_CONNECTION_REFUSED, CHIAKI_QUIT_REASON_CTRL_CONNECTION_REFUSED,
             CHIAKI_QUIT_REASON_PSN_REGIST_FAILED: self = .refused
        case CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_DISCONNECTED, CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_SHUTDOWN,
             CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED, CHIAKI_QUIT_REASON_STREAM_CONNECTION_UNKNOWN: self = .network
        default: self = .other(String(cString: chiaki_quit_reason_string(quit)))
        }
    }
}

public enum SessionState: Equatable, Sendable {
    case connecting
    case streaming
    case disconnected(DisconnectReason)
}

/// Tek bir libchiaki oturumunun sahibi. Geri çağrılar bu kutuya gelir; kutu, oturum kapatılıp
/// iş parçacığı beklenene (join) kadar yaşar, böylece geri çağrı serbest bırakılmış belleğe düşmez.
///
/// Oturumun günlüğü de kutunundur: libchiaki `ChiakiLog`'un yalnız adresini tutar ve iş parçacığı kapanırken bile
/// günlüğe yazar. Günlük eskiden `StreamSession`'daydı; "Çeviriyi durdur"da `StreamSession` hemen bırakılıyor, oturum
/// ise arka planda kapatılıyordu. Kapanan iş parçacığı serbest kalmış günlüğe yazınca uygulama çöküyordu
/// (EXC_BAD_ACCESS, chiaki_log ← chiaki_stream_connection_run; GitHub #21).
final class ChiakiSessionBox {
    let pointer = UnsafeMutablePointer<ChiakiSession>.allocate(capacity: 1)
    let logger = ChiakiLogger()
    let generation: Int
    weak var owner: StreamSession?
    private var torn = false
    private let lock = NSLock()

    init(generation: Int, owner: StreamSession?) {
        self.generation = generation
        self.owner = owner
    }

    /// `chiaki_session_init`; başarısızsa kutu kullanılmamış sayılır (kapatılacak iş parçacığı yok).
    func initialize(console: RegisteredConsole, accountId: Data) -> ChiakiErrorCode {
        var info = ChiakiConnectInfo()
        info.ps5 = true
        copy(console.registKey, into: &info.regist_key)
        copy(console.morning, into: &info.morning)
        chiaki_connect_video_profile_preset(&info.video_profile, CHIAKI_VIDEO_RESOLUTION_PRESET_1080p, CHIAKI_VIDEO_FPS_PRESET_30)
        info.video_profile.codec = CHIAKI_CODEC_H264
        info.video_profile_auto_downgrade = true
        info.enable_keyboard = false
        info.enable_dualsense = false
        info.audio_video_disabled = CHIAKI_AUDIO_DISABLED
        info.auto_regist = false
        info.holepunch_session = nil
        info.rudp_sock = nil
        copy(accountId, into: &info.psn_account_id)
        info.packet_loss_max = 0.05
        info.enable_idr_on_fec_failure = true

        // libchiaki adresi oturum açılırken kopyalar; geçici C dizgesi yeterli.
        let error = console.host.withCString { host -> ChiakiErrorCode in
            info.host = host
            return chiaki_session_init(pointer, &info, logger.pointer)
        }
        if !error.isSuccess { markUnused() }
        return error
    }

    /// Oturumu durdurur ve iş parçacığını bekler. libchiaki iş parçacığından çağrılmamalı.
    func tearDown() {
        lock.lock()
        defer { lock.unlock() }
        guard !torn else { return }
        torn = true
        chiaki_session_stop(pointer)
        chiaki_session_join(pointer)
        chiaki_session_fini(pointer)
    }

    /// `chiaki_session_init`/`start` başarısız olduysa: join edilecek iş parçacığı yok, kapatma adımları atlanır.
    func markUnused() {
        lock.lock()
        torn = true
        lock.unlock()
    }

    deinit {
        tearDown()
        pointer.deallocate()
    }
}

/// PS5'e (ikinci hesapla) Remote Play bağlantısı kurar ve görüntüyü kare kare verir.
/// Ses kapalıdır, kol girdisi gönderilmez. Bağlantı koparsa kendiliğinden yeniden bağlanır.
public final class StreamSession: @unchecked Sendable {
    public var onFrame: ((CGImage) -> Void)?
    public var onState: ((SessionState) -> Void)?
    /// PS5 ağda yeni bir adreste bulununca (oturum kuyruğunda) çağrılır; yeni adres kaydedilmelidir.
    public var onConsoleMoved: ((RegisteredConsole) -> Void)?

    /// Yalnız `queue` üzerinde değişir (PS5'in adresi değişirse; Windows'taki gibi).
    private var console: RegisteredConsole
    /// Son aramada PS5 yanıt verdi mi (yalnız `queue`).
    private var searchAnswered = true
    /// Tüm ağı taramak pahalı; PS5 kapalıyken her yeniden denemede yapılmaz.
    private var nextRelocate = Date.distantPast
    private let accountId: Data
    private let queue = DispatchQueue(label: "couchsubs.stream-session")
    private let decodeQueue = DispatchQueue(label: "couchsubs.decode")
    private var decoder = H264FrameDecoder()
    private var throttle = FrameThrottle(minInterval: 1.0 / 20)
    private var policy = ReconnectPolicy()
    /// Yalnız `queue` üzerinde okunup yazılır.
    private var box: ChiakiSessionBox?

    /// Durdurma isteği ve kuşak numarası; her başlat/durdur yeni bir kuşak açar ve eski
    /// bloklar (yeniden deneme, eski oturumun kapanma olayı) kendini iptal eder.
    private let stateLock = NSLock()
    private var running = false
    private var generation = 0

    public init(console: RegisteredConsole, accountId: Data) {
        self.console = console
        self.accountId = accountId
    }

    deinit {
        // Kuyruk bloklarının hiçbiri self'i güçlü tutmaz; kalan oturum (varsa) arka planda kapatılır.
        if let box { DispatchQueue.global().async { box.tearDown() } }
    }

    public func start() {
        let current = bump(running: true)
        queue.async { [weak self] in
            self?.policy.reset()
            self?.connect(current)
        }
    }

    /// Bloklamaz: oturum arka planda kapatılır.
    public func stop() {
        _ = bump(running: false)
        queue.async { [weak self] in self?.closeBox() }
    }

    /// Mac uykudan uyandığında ya da ağ değiştiğinde uygulama tarafından çağrılır.
    public func reconnectNow() {
        guard isRunning else { return }
        let current = bump(running: true)
        queue.async { [weak self] in
            guard let self else { return }
            self.closeBox()
            self.policy.reset()
            self.connect(current)
        }
    }

    // MARK: - Durum

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func bump(running: Bool) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.running = running
        generation += 1
        return generation
    }

    private func isCurrent(_ value: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && generation == value
    }

    // MARK: - Bağlantı (hepsi `queue` üzerinde)

    private func connect(_ current: Int) {
        guard isCurrent(current), box == nil else { return }
        emit(.connecting)

        // PS5 uyuyorsa uyandır; uyanmayı kuyruğu bloklamadan, aralıklı kontrollerle bekle.
        let info = Console.blockingDiscover(timeout: 2, host: console.host).first ?? relocate()
        searchAnswered = info != nil
        if let info {
            RemotePlayLog.write("PS5 oturumu: \(info.name) \(info.host) \(info.isAwake ? "uyanık" : "dinlenmede, uyandırılıyor")")
        } else {
            RemotePlayLog.write("PS5 oturumu: \(console.host) aramaya yanıt vermedi, yine de bağlanılıyor")
        }
        if let info, !info.isAwake {
            do { try Console.wake(console) } catch { RemotePlayLog.write("PS5 uyandırılamadı: \(error)") }
            return waitForWake(current, deadline: Date().addingTimeInterval(20))
        }
        openSession(current)
    }

    /// Kayıtlı adreste PS5 yoksa (modem adresini değiştirmiş olabilir) ağda arar; bulursa adresi günceller.
    /// Eskiden yalnız Windows'ta vardı; Mac'te adres değişince bağlantı hiç kurulamıyordu.
    private func relocate() -> ConsoleInfo? {
        guard Date() >= nextRelocate else { return nil }
        nextRelocate = Date().addingTimeInterval(30)
        guard let moved = Self.pickMoved(Console.search(timeout: .seconds(3), host: nil), name: console.name),
              moved.host != console.host else { return nil }
        RemotePlayLog.write("PS5 yeni adreste: \(console.host) -> \(moved.host)")
        console = console.withHost(moved.host)
        onConsoleMoved?(console)
        return moved
    }

    /// Taramada bulunanlar arasından kayıtlı PS5: tek PS5 varsa odur, birden çoksa adı tek eşleşen; emin değilse nil.
    static func pickMoved(_ found: [ConsoleInfo], name: String) -> ConsoleInfo? {
        if found.count == 1 { return found[0] }
        let named = found.filter { $0.name == name }
        return named.count == 1 ? named[0] : nil
    }

    private func waitForWake(_ current: Int, deadline: Date) {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            if Console.blockingDiscover(timeout: 2, host: self.console.host).contains(where: \.isAwake) {
                self.openSession(current)
            } else if Date() < deadline {
                self.waitForWake(current, deadline: deadline)
            } else {
                self.scheduleReconnect(current, reason: .consoleAsleep)
            }
        }
    }

    private func openSession(_ current: Int) {
        guard isCurrent(current), box == nil else { return }
        // Yeniden bağlanmada çözücü sıfırdan başlar (uykudan sonra eski oturumu geçersiz olabilir).
        decodeQueue.async { [weak self] in self?.decoder = H264FrameDecoder() }

        let box = ChiakiSessionBox(generation: current, owner: self)
        let error = box.initialize(console: console, accountId: accountId)
        guard error.isSuccess else {
            return scheduleReconnect(current, reason: .other(ChiakiError(code: error).description), initialized: false, box: box)
        }

        let user = Unmanaged.passUnretained(box).toOpaque()
        chiaki_session_set_event_cb(box.pointer, { event, user in
            guard let event, let user else { return }
            let box = Unmanaged<ChiakiSessionBox>.fromOpaque(user).takeUnretainedValue()
            box.owner?.handle(event.pointee, generation: box.generation)
        }, user)
        chiaki_session_set_video_sample_cb(box.pointer, { buffer, size, _, _, user in
            guard let buffer, let user else { return true }
            Unmanaged<ChiakiSessionBox>.fromOpaque(user).takeUnretainedValue().owner?.ingest(Data(bytes: buffer, count: size))
            return true
        }, user)

        let started = chiaki_session_start(box.pointer)
        guard started.isSuccess else {
            chiaki_session_fini(box.pointer)
            return scheduleReconnect(current, reason: .other(ChiakiError(code: started).description), initialized: false, box: box)
        }
        self.box = box
    }

    /// Geçerli oturumu kapatır. Kapatma join içerdiği için kuyruğu bekletmemek adına arka planda yapılır.
    private func closeBox() {
        guard let box else { return }
        self.box = nil
        DispatchQueue.global().async { box.tearDown() }
    }

    /// libchiaki iş parçacığından çağrılır.
    fileprivate func handle(_ event: ChiakiEvent, generation eventGeneration: Int) {
        switch event.type {
        case CHIAKI_EVENT_CONNECTED:
            queue.async { [weak self] in
                guard let self, self.box?.generation == eventGeneration else { return }
                self.policy.reset()
                self.emit(.streaming)
            }
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
            // Kol girdisi göndermediğimiz için şifre giremeyiz; yeniden denemek de aynı yere çıkar.
            queue.async { [weak self] in
                guard let self, self.box?.generation == eventGeneration else { return }
                _ = self.bump(running: false)
                self.closeBox()
                self.emit(.disconnected(.loginPasscode))
            }
        case CHIAKI_EVENT_QUIT:
            let reason = DisconnectReason(quit: event.quit.reason)
            queue.async { [weak self] in
                // Eski bir oturumun (ör. reconnectNow ile kapatılanın) kapanma olayı yeni oturumu etkilemez.
                guard let self, self.box?.generation == eventGeneration else { return }
                self.closeBox()
                self.scheduleReconnect(eventGeneration, reason: reason)
            }
        default:
            break
        }
    }

    private func scheduleReconnect(_ current: Int, reason: DisconnectReason, initialized: Bool = true, box failed: ChiakiSessionBox? = nil) {
        // Başlatılamamış kutunun join edilecek iş parçacığı yok; yalnız belleği bırakılır.
        if let failed, !initialized { failed.markUnused() }
        emit(.disconnected(DisconnectReason.classify(reason, searchAnswered: searchAnswered, host: console.host)))
        guard isCurrent(current) else { return }
        let delay = policy.nextDelay()
        queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in self?.connect(current) }
    }

    /// Her kare çözülür (sonraki kareler öncekilere dayanır); görüntü saniyede en çok 20 kez üretilir.
    /// Okuma meşgulken gelen kareler zaten atlanır; sık kare, altyazının erken ve eksiksiz yakalanmasını sağlar.
    fileprivate func ingest(_ sample: Data) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            let wanted = self.throttle.shouldPass()
            if let image = self.decoder.decode(annexB: sample, makeImage: wanted), wanted {
                self.onFrame?(image)
            }
        }
    }

    private func emit(_ state: SessionState) {
        // Ana ekrandaki durumun nedeni remoteplay.log'da da görünsün.
        if state != .connecting { RemotePlayLog.write("PS5 oturumu: \(state)") }
        onState?(state)
    }
}

extension Console {
    /// Senkron arama (yalnız oturum kuyruğunda kullanılır).
    static func blockingDiscover(timeout: Double, host: String) -> [ConsoleInfo] {
        search(timeout: .seconds(timeout), host: host)
    }
}
