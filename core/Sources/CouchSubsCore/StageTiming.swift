// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Ek alan turunun ve kare işlerinin aşama süreleri; `period` ms'de bir tek günlük satırı. Altyazı ya da telefon çevirisi
/// geç kalınca hangi işin (okuma, çizim ölçümü, telefon izleme, bütün karenin çizimi) zaman aldığı günlükte görünsün diye
/// (beta.103: "telefon mesajları yavaş, altyazı gecikiyor"). Android StageTiming.kt ve Windows StageTiming.cs aynı biçim.
public final class StageTiming: @unchecked Sendable {
    public static let periodMs = 30_000

    private struct Stat {
        var count = 0
        var total: Int64 = 0
        var maximum: Int64 = 0
    }

    private let lock = NSLock()
    private let period: Int
    private var order: [String] = []
    private var stats: [String: Stat] = [:]
    private var since: Int?

    public init(period: Int = StageTiming.periodMs) {
        self.period = period
    }

    /// `stage` bir kez `nanoseconds` sürdü.
    public func add(_ stage: String, nanoseconds: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if stats[stage] == nil { order.append(stage) }
        var stat = stats[stage] ?? Stat()
        stat.count += 1
        stat.total += max(0, nanoseconds)
        stat.maximum = max(stat.maximum, nanoseconds)
        stats[stage] = stat
    }

    /// `stage` bir kez `milliseconds` sürdü.
    public func add(_ stage: String, milliseconds: Int) {
        add(stage, nanoseconds: Int64(milliseconds) * 1_000_000)
    }

    /// Süre dolduysa (`now`, ms) satır, sayaçlar sıfırlanır; dolmadıysa ya da ölçüm yoksa nil. İlk çağrı süreyi başlatır.
    public func report(now: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let start = since else {
            since = now
            return nil
        }
        if now >= start, now - start < period { return nil }
        since = now
        guard !order.isEmpty else { return nil }
        let line = Self.format(spanMs: max(0, now - start), order.map { ($0, stats[$0]!.count, stats[$0]!.total, stats[$0]!.maximum) })
        order = []
        stats = [:]
        return line
    }

    /// "aşama süreleri (30 sn): okuma 12× ort 85,0 en çok 140,2 ms; çizim 4× ort 30,1 en çok 52,0 ms".
    static func format(spanMs: Int, _ stages: [(String, Int, Int64, Int64)]) -> String {
        func ms(_ nanos: Int64) -> String {
            let tenths = (nanos + 50_000) / 100_000
            return "\(tenths / 10),\(tenths % 10)"
        }
        return "aşama süreleri (\(spanMs / 1000) sn): " + stages.map { stage, count, total, maximum in
            "\(stage) \(count)× ort \(ms(total / Int64(max(1, count)))) en çok \(ms(maximum)) ms"
        }.joined(separator: "; ")
    }
}
