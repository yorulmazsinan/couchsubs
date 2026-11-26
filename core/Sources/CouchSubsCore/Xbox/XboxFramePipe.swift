// SPDX-License-Identifier: AGPL-3.0-only
// Xbox görüntü alıcısının ve kare işlemenin süreleri (#1308) ve kapanma anındaki akış durumu (#1252). Android'deki
// XboxFramePipeStats ve XboxCloseContext (XboxFramePipe.kt) ile aynı satırlar.

import Foundation

/// Görüntü alıcısı ve kare işleme süreleri; 10 sn'de bir günlüğe yazılır: alıcı hızlı dönüyor mu, işlenemeyip atlanan
/// kare var mı, bellek büyüyor mu.
public struct XboxFramePipeStats: Sendable {
    public static let windowMs = 10_000

    private var arrived = 0
    private var sinkNanos: UInt64 = 0
    private var sinkMaxNanos: UInt64 = 0
    private var handed = 0
    private var dropped = 0
    private var processed = 0
    private var processNanos: UInt64 = 0
    private var processMaxNanos: UInt64 = 0
    /// Kare onayı döngüsünün turları arasındaki süre: döngü takılırsa (iş parçacığı meşgul) Xbox onay alamayıp görüntü
    /// kanalını kapatır. Windows'taki oynatıcının "onay en uzun aralık" alanıyla aynı.
    private var ackTicks = 0
    private var ackMaxGapNanos: UInt64 = 0
    private var ackLate = 0

    /// Bu süreyi aşan onay aralığı "geç" sayılır (Windows oynatıcısındaki 250 ms).
    public static let lateAckNanos: UInt64 = 250_000_000

    public init() {}

    /// Alıcıya gelen her kare (aralık dolmadığı için atlananlar da) ve alıcıda geçen süre.
    public mutating func sink(nanos: UInt64) {
        arrived += 1
        sinkNanos += nanos
        sinkMaxNanos = max(sinkMaxNanos, nanos)
    }

    public mutating func handedOver() { handed += 1 }

    /// Okuma hattı yetişemedi: bekleyen kare yenisiyle değişti.
    public mutating func dropped(_ count: Int = 1) { dropped += count }

    public mutating func processed(nanos: UInt64) {
        processed += 1
        processNanos += nanos
        processMaxNanos = max(processMaxNanos, nanos)
    }

    /// Kare onayı döngüsünün bir turu; [gapNanos] önceki turdan bu yana geçen süre.
    public mutating func ackTick(gapNanos: UInt64) {
        ackTicks += 1
        ackMaxGapNanos = max(ackMaxGapNanos, gapNanos)
        if gapNanos > Self.lateAckNanos { ackLate += 1 }
    }

    /// Pencerenin satırı ("kare hattı (10 sn): ..."); sayaçlar sıfırlanır. Hiç kare gelmediyse nil.
    public mutating func take(windowMs: Int, memory: String) -> String? {
        defer { self = XboxFramePipeStats() }
        guard arrived > 0 else { return nil }
        func ms(_ nanos: UInt64) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(nanos) / 1_000_000) }
        let sinkAvg = sinkNanos / UInt64(arrived)
        let processAvg = processed > 0 ? processNanos / UInt64(processed) : 0
        let acks = ackTicks > 0 ? "onay aralığı en çok \(ms(ackMaxGapNanos)) ms, 250 ms üstü \(ackLate); " : ""
        return "kare hattı (\(windowMs / 1000) sn): gelen \(arrived), aktarılan \(handed), işlenen \(processed), atlanan \(dropped); "
            + "alıcı ort \(ms(sinkAvg)) ms, en çok \(ms(sinkMaxNanos)) ms; işleme ort \(ms(processAvg)) ms, en çok \(ms(processMaxNanos)) ms; \(acks)\(memory)"
    }
}

/// Xbox görüntü kanalını (input) ya da WebRTC bağlantısını kapattığında akışın durumu: son kare ve son kare onayı ne
/// kadar önceydi. Onay uzun süredir gitmiyorsa kapanmanın nedeni onaydır; kare uzun süredir gelmiyorsa ağ.
public enum XboxCloseContext {
    /// Anlar milisaniye; 0 "hiç olmadı" demektir.
    public static func describe(nowMs: Int, lastFrameAtMs: Int, lastAckAtMs: Int, acksSent: Int) -> String {
        func ago(_ at: Int) -> String {
            String(format: "%.1f sn önce", locale: Locale(identifier: "en_US_POSIX"), Double(max(0, nowMs - at)) / 1000)
        }
        let frame = lastFrameAtMs > 0 ? "son kare \(ago(lastFrameAtMs))" : "kare gelmedi"
        let ack = lastAckAtMs > 0 ? "son onay \(ago(lastAckAtMs)), onay \(acksSent)" : "onay gönderilmedi"
        return "\(frame), \(ack)"
    }
}
