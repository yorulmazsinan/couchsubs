// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Uzun çevirinin ekranda tek uzun satır olarak sağa sola taşmaması: satır başına en çok `maxChars` karakter,
/// en çok 3 satır, kelime sınırından ve dengeli bölünür. 3 satıra sığmayacak kadar uzunsa yazı biraz küçülür
/// (`scale`, en çok `minScale`'e kadar). Konuşan adı ("ARTHUR: ...") bölünmez, hep ilk satırdadır.
/// Android (SubtitleWrap.kt), Windows (SubtitleWrap.cs), TV sayfası (tv-webos/app.js) ve OBS sayfası aynı kuralları uygular.
public enum SubtitleWrap {
    public static let maxChars = 42
    /// Bilgisayardaki altyazı ve yayın penceresinde (Mac, Windows) satır başına en çok karakter: oyunda tek satır görünen
    /// altyazının çevirisi de tek satırda kalır (oyundaki tek satırların %99'u en çok 66 karakter). Telefonda `maxChars`.
    public static let desktopMaxChars = 66
    public static let maxLines = 3
    public static let minScale = 0.75

    public struct Result: Equatable, Sendable {
        public var text: String
        public var scale: Double
    }

    /// Bölünmüş metin ve yazı boyu çarpanı. Zaten satır sonu içeren ya da kısa metin olduğu gibi döner. `limit`: satır
    /// başına en çok karakter (bilgisayardaki pencereler: `desktopMaxChars`).
    public static func fit(_ text: String, maxChars limit: Int = maxChars) -> Result {
        let length = text.count
        if length <= limit || text.contains("\n") { return Result(text: text, scale: 1) }
        let words = tokens(text)
        guard words.count > 1 else { return Result(text: text, scale: 1) }
        let scale = max(minScale, Double(limit * maxLines) / Double(length)).clamped(to: minScale...1)
        let cap = Int((Double(limit) / scale).rounded(.down))
        let lines = min(maxLines, max(2, Int((Double(length) / Double(cap)).rounded(.up))))
        return Result(text: balance(words, lines: min(lines, words.count)), scale: scale)
    }

    /// Verilen sabit yazı boyu çarpanıyla bölme ("Örtsün", bkz. `CoverFontScale`): satır başına `maxChars / scale`
    /// karakter, en çok 3 satır; daha uzun metinde satırlar uzar, yazı daha fazla küçülmez.
    /// `limit`: satır başına karakter tabanı (bilgisayardaki pencereler: `desktopMaxChars`).
    public static func fit(_ text: String, scale: Double, maxChars limit: Int = maxChars) -> Result {
        let scale = scale.isFinite && scale > 0 ? min(1, scale) : 1
        let cap = Int((Double(max(1, limit)) / scale).rounded(.down))
        if text.count <= cap || text.contains("\n") { return Result(text: text, scale: scale) }
        let words = tokens(text)
        guard words.count > 1 else { return Result(text: text, scale: scale) }
        let lines = min(maxLines, max(2, Int((Double(text.count) / Double(cap)).rounded(.up))))
        return Result(text: balance(words, lines: min(lines, words.count)), scale: scale)
    }

    /// Sözcükler; konuşan adı ("ARTHUR:") sonraki sözcükle birleşik tutulur, böylece ad satır sonunda tek kalmaz.
    static func tokens(_ text: String) -> [String] {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if let colon = words.prefix(3).firstIndex(where: { $0.hasSuffix(":") || $0.hasSuffix("：") }),
           colon + 1 < words.count {
            let joined = words[0...(colon + 1)].joined(separator: " ")
            words.replaceSubrange(0...(colon + 1), with: [joined])
        }
        return words
    }

    /// En uzun satırı en kısa yapan bölme; eşitlikte uzunlukların kareleri toplamı küçük olan (daha dengeli) seçilir.
    static func balance(_ words: [String], lines: Int) -> String {
        let count = words.count
        func width(_ from: Int, _ to: Int) -> Int {
            words[from..<to].reduce(0) { $0 + $1.count } + (to - from - 1)
        }
        var best: (longest: Int, spread: Int, cuts: [Int])?
        func consider(_ cuts: [Int]) {
            let edges = [0] + cuts + [count]
            let widths = (0..<(edges.count - 1)).map { width(edges[$0], edges[$0 + 1]) }
            let key = (widths.max() ?? 0, widths.reduce(0) { $0 + $1 * $1 })
            if best == nil || key < (best!.longest, best!.spread) { best = (key.0, key.1, cuts) }
        }
        if lines == 2 {
            for a in 1..<count { consider([a]) }
        } else if count >= 3 {
            for a in 1..<(count - 1) { for b in (a + 1)..<count { consider([a, b]) } }
        } else {
            for a in 1..<count { consider([a]) }
        }
        guard let cuts = best?.cuts else { return words.joined(separator: " ") }
        let edges = [0] + cuts + [count]
        return (0..<(edges.count - 1)).map { words[edges[$0]..<edges[$0 + 1]].joined(separator: " ") }.joined(separator: "\n")
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
