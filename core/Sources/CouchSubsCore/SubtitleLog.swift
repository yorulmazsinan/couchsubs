// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Altyazı günlüğü: her oturumda okunan altyazı satırlarının ve akıbetlerinin kısa kaydı
/// (~/Library/Logs/CouchSubs/altyazi.log; Mac App Store sürümünde kapsayıcının Logs klasörü, remoteplay.log'un yanı.
/// Windows'ta %LOCALAPPDATA%\CouchSubs\altyazi.log). "İlk satırlar görünmedi" gibi bildirimlerde ne okunduğu ve her
/// satıra ne olduğu (paket, önbellek, çeviri, geç kaldı, atıldı, çöp) buradan görülür. Altyazı metni dışında kişisel
/// bilgi yazılmaz. Uygulama açılışta `enable()` çağırır; çağrılmazsa (testler) hiçbir şey yazılmaz. Satırlar arka planda
/// yazılır; dosya 1 MB'yi geçince altyazi.log.1'e taşınır (en çok ~2 MB). Windows'taki CouchSubs.Core/SubtitleLog.cs
/// ile aynı biçim.
public enum SubtitleLog {
    public static var defaultFile: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/CouchSubs/altyazi.log")
    }

    /// Bir dosyanın en büyük boyutu; aşılınca eskisi `.1` olur.
    static let maxBytes = 1 << 20
    /// Günlükteki altyazı alıntısının en uzun hâli.
    public static let excerptLength = 120

    private final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "altyazi.log", qos: .utility)
        let lock = NSLock()
        var file: URL?
        let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return formatter
        }()
    }

    private static let state = State()

    public static func enable(file: URL = defaultFile) {
        state.lock.withLock { state.file = file }
    }

    public static func disable() {
        flush()
        state.lock.withLock { state.file = nil }
    }

    public static var isEnabled: Bool { state.lock.withLock { state.file != nil } }

    /// Bekleyen satırlar yazılana kadar bekler (testler ve kapanış için).
    public static func flush() { state.queue.sync {} }

    public static func write(_ line: String) {
        guard let file = state.lock.withLock({ state.file }) else { return }
        let date = Date()
        state.queue.async {
            let text = "[\(state.formatter.string(from: date))] \(line)\n"
            append(Data(text.utf8), to: file)
        }
    }

    /// Günlükteki tırnaklı, tek satırlık, en çok `limit` karakterlik alıntı.
    public static func excerpt(_ text: String, limit: Int = excerptLength) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " / ")
        let short = flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
        return "\"\(short)\""
    }

    static func rotateIfNeeded(_ file: URL, incoming: Int) {
        let manager = FileManager.default
        guard let size = (try? manager.attributesOfItem(atPath: file.path)[.size]) as? Int, size + incoming > maxBytes else { return }
        let backup = file.appendingPathExtension("1")
        try? manager.removeItem(at: backup)
        try? manager.moveItem(at: file, to: backup)
    }

    private static func append(_ data: Data, to file: URL) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            rotateIfNeeded(file, incoming: data.count)
            if !manager.fileExists(atPath: file.path) {
                try data.write(to: file)
                return
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Günlük yazılamasa da altyazı sürer.
        }
    }
}

/// libchiaki'nin günlük satırlarından görüntü duraklamalarını çıkarır: "FEC failed, waiting for IDR frame" ile görüntü
/// donar, "Received IDR frame, resuming decode" ile sürer. Bu arada kare gelmez; altyazı da okunamaz. Altyazı günlüğüne
/// duraklamanın başı ve süresi yazılır (satırlar libchiaki'nin iş parçacığından gelir).
public final class VideoStallTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let now: () -> Int
    private var stalledAt: Int?

    public init(clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs) {
        now = clock
    }

    /// Satır bir duraklamayı başlatıyor ya da bitiriyorsa günlük satırı; yoksa nil.
    public func note(_ line: String) -> String? {
        lock.withLock {
            if line.contains("FEC failed") || line.contains("Video FEC failure") {
                guard stalledAt == nil else { return nil }
                stalledAt = now()
                return "görüntü durdu: FEC hatası, IDR karesi bekleniyor"
            }
            if line.contains("Received IDR frame") {
                guard let since = stalledAt else { return nil }
                stalledAt = nil
                return "görüntü sürdü: IDR karesi geldi (\(now() - since) ms boşluk)"
            }
            return nil
        }
    }
}
