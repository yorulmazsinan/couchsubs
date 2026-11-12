// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// TV'ye giden son altyazı satırının ölçümleri (ana ekrandaki "Canlı altyazı" alanının altındaki küçük satır).
/// Hepsi gerçek ölçümdür: yazı tanımanın süresi, çevirinin süresi ve satırın okunduğu karenin geldiği andan TV'ye
/// gönderildiği ana kadar geçen süre. Windows'taki CouchSubs.Core/LineMetrics.cs ile aynı.
public struct LineMetrics: Equatable, Sendable {
    /// Çevirinin nereden geldiği.
    public enum Origin: String, Codable, Sendable {
        /// Oyun paketindeki hazır Türkçe (çeviri motoru çağrılmadı).
        case pack
        /// Çeviri motoru (ya da onun önbelleği).
        case engine
    }

    /// Satırı okuyan yazı tanımanın süresi (ms); bilinmiyorsa nil.
    public var ocrMs: Int?
    /// Çevirinin süresi (ms); paketten gelen satırda nil.
    public var translationMs: Int?
    /// Satırın okunduğu karenin geldiği andan TV'ye gönderildiği ana kadar (ms).
    public var totalMs: Int
    /// Yazı tanımanın güveni (yüzde, 0–100); okuyucu vermiyorsa nil (Windows'un yazı tanıması vermez).
    public var confidence: Int?
    public var origin: Origin

    public init(ocrMs: Int?, translationMs: Int?, totalMs: Int, confidence: Int?, origin: Origin) {
        self.ocrMs = ocrMs
        self.translationMs = translationMs
        self.totalMs = totalMs
        self.confidence = confidence
        self.origin = origin
    }

    /// Ölçüm anlarından (aynı milisaniye saatiyle) satırın ölçümleri. Saat geri gitmiş gibi görünen (eksi) süreler 0 olur.
    /// - Parameters:
    ///   - capturedAt: Satırın okunduğu karenin geldiği an.
    ///   - ocrMs: O okumanın süresi.
    ///   - translation: Çevirinin başladığı ve bittiği an (paketten gelen satırda nil).
    ///   - sentAt: Satırın TV'ye gönderildiği an.
    ///   - confidence: Yazı tanımanın güveni (0–1).
    public static func measure(capturedAt: Int, ocrMs: Int?, translation: (started: Int, finished: Int)?, sentAt: Int,
                               confidence: Double?, origin: Origin) -> LineMetrics {
        LineMetrics(ocrMs: ocrMs.map { max(0, $0) },
                    translationMs: translation.map { max(0, $0.finished - $0.started) },
                    totalMs: max(0, sentAt - capturedAt),
                    confidence: confidence.map { Int((min(1, max(0, $0)) * 100).rounded()) },
                    origin: origin)
    }

    /// Ekrandaki parçalar, sırayla: "OCR 42 ms", "Translation 310 ms" (paketse "Ready pack"), "Delay 520 ms",
    /// "Confidence 93%". Bilinmeyen değer yazılmaz.
    public var parts: [String] {
        var parts: [String] = []
        if let ocrMs { parts.append(String(format: String(localized: "OCR %lld ms"), ocrMs)) }
        switch origin {
        case .pack: parts.append(String(localized: "Ready pack"))
        case .engine: if let translationMs { parts.append(String(format: String(localized: "Translation %lld ms"), translationMs)) }
        }
        parts.append(String(format: String(localized: "Delay %lld ms"), totalMs))
        if let confidence { parts.append(String(format: String(localized: "Confidence %lld%%"), confidence)) }
        return parts
    }

    /// Parçalar tek satırda.
    public var summary: String { parts.joined(separator: " · ") }
}
