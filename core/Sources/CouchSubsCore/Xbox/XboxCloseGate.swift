// SPDX-License-Identifier: AGPL-3.0-only
// Xbox oturumlarının kapanış sırası (süreç genelinde). "Yeniden bağlan", öne dönüş ya da ses ayarı gibi durumlarda eski
// oturum durdurulup hemen yenisi açılıyordu: eski oturumun kapatma isteği (DELETE) ve WebRTC kapanışı daha bitmeden yeni
// oturumun `play` isteği Xbox'a gidiyordu. Xbox eski oturumu açık sayınca yeni oturum düşüyor, "uzaktan yürütme
// başladı/durduruldu" art arda geliyor ve kullanıcılar Xbox'ı yeniden başlatmak zorunda kalıyordu. Windows'ta oturumlar
// zaten sırayla açılıyor (XboxStreamSession.Start → RunAfterAsync); burada da yeni oturum önceki oturumların kapanışını
// (en çok `waitLimitMs`) bekler. Kapatılamayan oturum kimlikleri de süreç genelinde tutulur: oturum nesnesi atıldıktan
// sonra açılan yeni oturum onları önce kapatır (eskiden kimlik atılan nesneyle kayboluyordu). Android'deki
// XboxCloseGate (XboxCloseGate.kt) ile aynı kurallar.

import Foundation

public final class XboxCloseGate: @unchecked Sendable {
    public static let shared = XboxCloseGate()
    /// Yeni oturum önceki oturumların kapanışını en çok bu kadar bekler (Windows'taki RunAfterAsync gibi 10 sn).
    public static let waitLimitMs = 10_000

    private let lock = NSLock()
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var stale: [String] = []

    public init() {}

    /// Kapanış işi kaydedilir ve başlatılır (görevden bağımsız: iptal edilmiş bir görevden çağrılsa da istekler gider).
    @discardableResult
    public func track(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        lock.lock()
        let task = Task.detached { [weak self] in
            await work()
            self?.finish(id)
        }
        pending[id] = task
        lock.unlock()
        return task
    }

    private func finish(_ id: UUID) {
        lock.lock()
        pending[id] = nil
        lock.unlock()
    }

    /// Süren kapanış sayısı.
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// Süren kapanışlar biter ya da [limitMs] dolar. Dönen değer: beklenen kapanış sayısı, geçen süre ve süre doldu mu
    /// (bekleyen yoksa nil).
    public func waitForPending(limitMs: Int = XboxCloseGate.waitLimitMs) async -> XboxCloseWait? {
        let tasks: [Task<Void, Never>] = {
            lock.lock()
            defer { lock.unlock() }
            return Array(pending.values)
        }()
        guard !tasks.isEmpty else { return nil }
        let started = DispatchTime.now().uptimeNanoseconds
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for task in tasks { await task.value }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, limitMs)) * 1_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
        return XboxCloseWait(sessions: tasks.count, elapsedMs: elapsed, timedOut: !finished)
    }

    /// Kapatılamayan oturum: sonra açılan ilk oturum `play`dan önce yeniden kapatır.
    public func addStale(_ id: String) {
        lock.lock()
        if !stale.contains(id) { stale.append(id) }
        lock.unlock()
    }

    /// Kapatılmayı bekleyen eski oturumlar (alınınca liste boşalır).
    public func takeStale() -> [String] {
        lock.lock()
        defer { stale = []; lock.unlock() }
        return stale
    }
}

/// Önceki oturumların kapanışının beklenmesi (günlük satırı için).
public struct XboxCloseWait: Equatable, Sendable {
    public let sessions: Int
    public let elapsedMs: Int
    public let timedOut: Bool

    public init(sessions: Int, elapsedMs: Int, timedOut: Bool) {
        self.sessions = sessions
        self.elapsedMs = elapsedMs
        self.timedOut = timedOut
    }

    /// "önceki oturumun kapanması beklendi (1 oturum, 0.4 sn)" ya da süre dolduysa "... 10 sn'de bitmedi; yeni oturum açılıyor".
    public var line: String {
        let seconds = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(elapsedMs) / 1000)
        return timedOut
            ? "önceki oturumun kapanması \(seconds) sn'de bitmedi (\(sessions) oturum); yeni oturum yine açılıyor"
            : "önceki oturumun kapanması beklendi (\(sessions) oturum, \(seconds) sn)"
    }
}
