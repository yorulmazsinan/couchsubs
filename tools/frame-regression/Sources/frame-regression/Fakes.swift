// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import Foundation

/// Çeviri motoru yerine sabit sözlük (testdata/frames/sozluk.json); sözlükte olmayan satır "TR«…»" olur. Her çağrı
/// kaynağıyla kaydedilir: TV'ye giden metnin hangi okunan satırdan geldiği buradan bulunur.
final class DictionaryTranslator: TextTranslator, @unchecked Sendable {
    private let words: [String: String]
    private let lock = NSLock()
    private var log: [(source: String, output: String)] = []
    /// Açıksa ilk çeviri `release()` çağrılana kadar bekler (telefon senaryosu: çeviri motordayken telefon kayboluyor).
    private var holding = false
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    init(words: [String: String]) {
        var normal: [String: String] = [:]
        for (english, turkish) in words { normal[normalized(english)] = turkish }
        self.words = normal
    }

    var calls: [(source: String, output: String)] { lock.withLock { log } }

    func holdFirst() { lock.withLock { holding = true } }

    var isHolding: Bool { lock.withLock { gate != nil } }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    func translate(_ text: String) async throws -> String {
        let (output, wait) = lock.withLock { () -> (String, Bool) in
            // Sözlükte yoksa numaralı yer tutucu: kaynağı içermemeli (hat aslıyla aynı çeviriyi "zaten Türkçe" sayıp atar).
            let output = words[normalized(text)] ?? "çeviri №\(log.count + 1)."
            log.append((text, output))
            defer { holding = false }
            return (output, holding && !released)
        }
        if wait {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return output
    }

    /// TV'ye giden metnin kaynağı: çıktısı metnin içinde geçen son çağrı.
    func source(of sent: String) -> String? {
        calls.last { !$0.output.isEmpty && sent.contains($0.output) }?.source
    }
}

/// TV yerine: altyazı gönderimlerini kaydeder.
final class SubtitleRecorder: SubtitleSending {
    struct Sent { var frame: String; var text: String; var box: TextBox?; var replaces = false }
    var current = ""
    private(set) var sent: [Sent] = []

    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) {
        sent.append(Sent(frame: current, text: text, box: box, replaces: replaces))
    }

    func clear() {}
}

/// TV yerine: ek alan (telefon kartı) gönderimlerini kaydeder.
final class RegionRecorder: RegionSending {
    private(set) var sent: [(id: String, text: String)] = []

    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
        sent.append((id, text))
    }

    func clearRegions() {}
}

/// Gerçek saatle en çok `seconds` bekler; koşul sağlanınca döner.
@MainActor
func waitUntil(seconds: Double = 30, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
