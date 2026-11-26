// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Altyazı kapısının eleme sayacı: okunan bir satır altyazı sayılmayınca (sahne yazısı, menü/mağaza satırı, menü açıklaması,
/// telefon, sabit blok) nedeni sayılır. Kullanıcı bildirimi (beta.103, iki kullanıcı, GTA 6: "bazı altyazıları kaçırıyor,
/// öncesinde iyiydi"): günlükte hangi kuralın hangi satırı ne sıklıkla attığı görünmüyordu. Her neden satırı sonuna o nedenin
/// bu oturumdaki sayısını taşır ("[bu nedenle 12. kez]"); dakikada en çok `perMinute` satır yazılır, aşan satırlar sayılır.
/// `windowMs` dolunca sonraki elemede son dakikanın neden başına sayısı tek özet satırı olarak yazılır. Yalnız metin
/// yazılır. Windows (RejectTally.cs) ve Android (RejectTally.kt) aynı biçim, aynı sınırlar.
public final class RejectTally: @unchecked Sendable {
    /// Özet aralığı (ms).
    public static let windowMs = 60_000
    /// Bir dakikada en çok yazılan neden satırı.
    public static let perMinute = 20

    private let lock = NSLock()
    private var total: [String: Int] = [:]
    private var window: [String: Int] = [:]
    private var windowStart: Int?
    private var written = 0
    private var suppressed = 0

    public init() {}

    /// Elemeyi sayar. `line`: bu eleme için yazılacak satır (tekrarı yazılmayacaksa nil). Dönen satırlar sırayla günlüğe
    /// yazılır: varsa önce son dakikanın özeti, sonra sayaçlı neden satırı.
    public func note(_ reason: String, line: String?, now: Int) -> [String] {
        lock.withLock {
            var out: [String] = []
            if let start = windowStart, now - start >= Self.windowMs {
                if let summary = summaryLine() { out.append(summary) }
                window = [:]
                written = 0
                suppressed = 0
                windowStart = now
            } else if windowStart == nil {
                windowStart = now
            }
            total[reason, default: 0] += 1
            window[reason, default: 0] += 1
            if let line {
                if written < Self.perMinute {
                    written += 1
                    out.append("\(line) [bu nedenle \(total[reason]!). kez]")
                } else {
                    suppressed += 1
                }
            }
            return out
        }
    }

    /// Bu oturumda `reason` ile atılan satır sayısı.
    public func count(_ reason: String) -> Int { lock.withLock { total[reason] ?? 0 } }

    public func reset() {
        lock.withLock {
            total = [:]
            window = [:]
            windowStart = nil
            written = 0
            suppressed = 0
        }
    }

    private func summaryLine() -> String? {
        guard !window.isEmpty else { return nil }
        let parts = window.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
        var line = "altyazı elemesi (son \(Self.windowMs / 1000) sn): " + parts.joined(separator: "; ")
        if suppressed > 0 { line += "; sınır yüzünden yazılmayan \(suppressed) satır" }
        return line
    }
}
