// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Sessizlik bekçisi: altyazı alanında konuşmaya benzeyen satır (`isSpeech`) `silenceMs` boyunca okunup hiçbir çeviri
/// gönderilmediyse o satır süzgeçler atlanarak doğrudan çevrilir. En çok `silenceMs`'de bir satır gönderir; aynı satırı
/// bir kez. Kullanıcı bildirimleri (iPhone 1.0.6, Mac beta.80, 2026-11-22): bir süzgeç altyazıyı sessizce tutunca bütün
/// oturum hiçbir satır çevrilmiyordu. İlke: fazladan bir HUD çevirisi kabul, diyaloğun kaybolması kabul değil. Windows
/// (SilenceWatch.cs) ve Android (SilenceWatch.kt) aynı kuralları uygular.
public struct SilenceWatch: Equatable {
    public static let silenceMs = 10_000
    /// Konuşma sayılmak için en az bu kadar sözcük.
    static let minWords = 3
    /// Rakam taşıyan satır ancak bu kadar sözcükle konuşma sayılır (sayaç, para, saat gibi HUD yazıları geçmesin).
    static let digitWords = 5

    private var since: Int?
    private var lastFired: Int?
    private var done: Set<String> = []

    public init() {}

    /// Hat bir çeviri gönderdi: sessizlik bitti.
    mutating func sent() { since = nil }

    /// Okunan satırlardan çevrilmesi gereken (süre dolduysa); yoksa nil.
    mutating func due(_ lines: [String], at time: Int) -> String? {
        let speech = lines.filter { Self.isSpeech($0) && !done.contains(TextMatch.normalize($0)) }
        guard let candidate = speech.max(by: { $0.count < $1.count }) else {
            since = nil
            return nil
        }
        guard let start = since else {
            since = time
            return nil
        }
        guard time - start >= Self.silenceMs, lastFired.map({ time - $0 >= Self.silenceMs }) ?? true else { return nil }
        return candidate
    }

    /// Satır gönderildi; aynı satır yeniden gönderilmez, bekçi yeniden `silenceMs` bekler.
    mutating func fired(_ text: String, at time: Int) {
        done.insert(TextMatch.normalize(text))
        lastFired = time
        since = time
    }

    /// Konuşmaya benzeyen satır: en az üç sözcük, küçük harf içerir ve cümle sonu noktalamasıyla biter ya da konuşan
    /// adıyla başlar. Tek sözcük, BÜYÜK HARF etiket ve rakamlı kısa HUD yazısı geçmez.
    public static func isSpeech(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words >= minWords, text.contains(where: \.isLowercase) else { return false }
        if text.contains(where: \.isNumber), words < digitWords { return false }
        return SubtitleStabilizer.endsSentence(text) || SpeakerPrefix.split(text) != nil
    }
}
