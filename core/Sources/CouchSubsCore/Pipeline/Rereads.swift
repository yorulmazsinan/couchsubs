// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Aynı altyazının farklı okumalarını tanıma kuralları (Windows: SubtitlePipeline.cs içindeki IsRereadOf, Related,
/// KeepMissingLines, LooksComplete; Android: Rereads.kt). Hat, yarım ya da bozuk okumayı kısa süre bekletip aynı
/// satırın en iyi okumasını çevirir; bu kurallar hangi okumanın aynı satır sayılacağını söyler.
enum Rereads {
    /// Okuma bozuk mu (OCR izi taşıyor mu).
    static func looksMisread(_ text: String) -> Bool { PackFuzzy.damaged(text) }

    /// Okumanın puanı: daha çok gerçek sözcük, daha uzun.
    static func score(_ text: String) -> Int { OcrNoise.score(text) }

    private static func words(_ text: String) -> [String] {
        TextMatch.normalize(text).split(separator: " ").map(String.init)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Her satırı büyük harfle başlayıp nokta, soru, ünlem ya da üç noktayla biten okuma.
    static func looksComplete(_ text: String) -> Bool {
        let all = lines(text)
        return !all.isEmpty && all.allSatisfy { line in
            guard let first = line.first(where: { $0.isLetter }) else { return false }
            return first.isUppercase && SubtitleStabilizer.endsSentence(line)
        }
    }

    /// İki okuma aynı altyazının okunuşları mı: ortak sözcükler kısa olanın en az yarısı (iki sözcükten kısa satırlarda
    /// biri ötekini içermeli).
    static func related(_ a: String, _ b: String) -> Bool {
        let x = words(a)
        var remaining = words(b)
        let ySize = remaining.count
        guard !x.isEmpty, ySize > 0 else { return false }
        var shared = 0
        for word in x {
            if let index = remaining.firstIndex(of: word) {
                remaining.remove(at: index)
                shared += 1
            }
        }
        let shorter = min(x.count, ySize)
        return shorter <= 1 ? shared >= 1 : shared >= 2 && shared * 2 >= shorter
    }

    /// `x` sözcükleri `y`'de aynı sırada geçiyor ama bitişik bir parça değil.
    private static func isGappedSubsequence(_ x: [String], _ y: [String]) -> Bool {
        var i = 0, firstMatch = -1, lastMatch = -1
        for j in y.indices where i < x.count {
            guard y[j] == x[i] else { continue }
            if firstMatch < 0 { firstMatch = j }
            lastMatch = j
            i += 1
        }
        return i == x.count && lastMatch - firstMatch + 1 > x.count
    }

    /// `newer`, `older`'ın yeniden okuması mı: biri bozuksa ortak sözcükler yeter; ikisi de temizse yeni okuma eskinin
    /// kesilmiş bir parçası olmalı ve cümle sonu işareti taşımamalı ("Get Franklin close to the").
    static func isRereadOf(_ newer: String, _ older: String) -> Bool {
        // Eskide olmayan olumsuzluk ya da sayı taşıyan okuma yeniden okuma değil, düzeltmedir.
        if TextMatch.addsMeaning(newer, to: older) { return false }
        let normNewer = TextMatch.normalize(newer)
        let normOlder = TextMatch.normalize(older)
        let x = normNewer.split(separator: " ").map(String.init)
        let y = normOlder.split(separator: " ").map(String.init)
        if normNewer.count >= 4, x.count == y.count, TextMatch.isSimilar(normNewer, normOlder, threshold: 0.75) { return true }
        if x.count >= 2, x.count == y.count {
            let differing = x.indices.filter { x[$0] != y[$0] }
            if !differing.isEmpty, differing.count * 2 <= x.count, differing.allSatisfy({ looksMisread(x[$0]) }) { return true }
        }
        if looksMisread(newer) || looksMisread(older) { return related(newer, older) }
        if x.isEmpty || x.count > y.count { return false }
        if x.count >= 2, x.count < y.count, isGappedSubsequence(x, y) { return true }
        let head = newer.drop(while: { $0.isWhitespace }).first
        let startsLower = !(head?.isUppercase ?? false)
        if SubtitleStabilizer.endsSentence(newer), !(startsLower && x.count < y.count) { return false }
        for start in 0...(y.count - x.count) where Array(y[start..<start + x.count]) == x { return true }
        return false
    }

    private static func covered(_ line: String, by previous: String) -> Bool {
        let norm = TextMatch.normalize(line)
        if norm.isEmpty { return true }
        if isRereadOf(line, previous.replacingOccurrences(of: "\n", with: " ")) { return true }
        return previous.split(separator: "\n").map(String.init).contains { old in
            TextMatch.normalize(old) == norm || isRereadOf(line, old)
        }
    }

    /// Okumanın her satırı az önce çevrilenin (aynı ya da yeniden okunmuş) bir satırı mı.
    static func allLinesCovered(_ reading: String, by previous: String) -> Bool {
        let all = lines(reading)
        return !all.isEmpty && all.allSatisfy { covered($0, by: previous) }
    }

    /// Daha iyi okuma bekleyenin yerine geçerken bekleyende olup yenisinde olmayan temiz satırlar korunur (iki satırlı
    /// altyazının ikinci satırı bir okumada çıkıp ötekinde kaçabiliyor).
    static func keepMissingLines(_ better: String, older: String) -> String {
        let corrected = better.split(separator: "\n").map(String.init)
        let extra = lines(older).filter { line in
            !looksMisread(line) && !covered(line, by: better) && !corrected.contains { fixed in
                TextMatch.addsMeaning(fixed, to: line)
                    && TextMatch.isSimilar(TextMatch.normalize(fixed), TextMatch.normalize(line))
            }
        }
        guard !extra.isEmpty else { return better }
        var trimmed = better
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        return trimmed + "\n" + extra.joined(separator: "\n")
    }
}
