// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Süslü yazı tiplerinde, solan ya da titreyen altyazıda yazı tanıma bazı sözcükleri harf, rakam ve simge
/// karışımı çöpe çevirir ("ou$3e", "waters2aljd"). Bunlar hiçbir dilde sözcük değildir; çevirmen onları
/// olduğu gibi taşır. Sözcük ortasında simge ya da harflerle rakamların iç içe geçtiği parçalar atılır;
/// gerçek bir sözcüğe yapışmış çöp ("waters2aljd") sözcükten ayrılır. "PS5", "R2", "2nd", "100m", "$500"
/// gibi olağan biçimler korunur.
public enum OcrNoise {
    private static let symbols = CharacterSet(charactersIn: "$@#%^*_=|\\~<>{}¢£¥§©®°±µ¶¤")
    private static let edgePunctuation = CharacterSet.punctuationCharacters.union(.symbols).subtracting(symbols)
        .union(CharacterSet(charactersIn: "\"'“”‘’«»()[]"))

    public static func clean(_ line: String) -> String {
        var kept: [String] = []
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, token) in tokens.enumerated() {
            let (lead, core, trail) = split(token)
            // Tek başına "l" ya da "|" çoğu zaman yanlış okunmuş "I"dır ("l don't know", "|'ll go"); ardından küçük
            // harfle süren sözcük gelmiyorsa altyazı kutusunun kenarıdır ("| Get in the car."), atılır.
            if let pronoun = misreadI(core) {
                let next = index + 1 < tokens.count ? tokens[index + 1].first(where: \.isLetter) : nil
                if pronoun != "I" || next?.isLowercase == true { kept.append(lead + pronoun + trail) }
                continue
            }
            // Yalnız "?!", ".", "," gibi işaretlerden oluşan parça: satır başında ya da cümle bittikten sonra yazı
            // tanımanın uydurmasıdır ("?! Where", "car. ?!"); sözcükten ayrı düşmüşse sözcüğe yapışır ("going ?!").
            if core.isEmpty, isStrayPunctuation(token) {
                if let last = kept.last, let end = last.last, !".?!…,;:".contains(end) {
                    kept[kept.count - 1] = last + token
                }
                continue
            }
            if let fixed = cleanCore(core) {
                kept.append(lead + fixed + trail)
            } else if !trail.isEmpty, let last = kept.popLast() {
                // Atılan çöpün ardındaki noktalama cümleye aittir ("ou$3e," → virgül kalır).
                kept.append(last + trail)
            }
        }
        // Altyazının yanındaki göstergenin sayısı satırın başına yapışıyor ("9? We'll lose", "100. Mac and John").
        // Mesafe işareti de öyle ("23m CESARE: Here!"). Tek başına sayı ve ardından büyük harfle başlayan cümle: sayı atılır.
        if kept.count >= 3, kept[0].range(of: "^\\d+(?:m|km|ft|yd)?[.?!:;]?$", options: .regularExpression) != nil,
           kept[1].first?.isUppercase == true {
            kept.removeFirst()
        }
        return kept.joined(separator: " ")
    }

    /// Bir okumanın ne kadar sözcük gibi göründüğü: düzgün sözcüklerin harfleri artı, çöp ve karışık büyük-küçük
    /// harfli parçalar ("CESAREiVJütt'h") eksi sayılır (Windows: OcrNoise.Score).
    public static func score(_ text: String) -> Int {
        var score = 0
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let core = split(token).1
            let letters = core.filter(\.isLetter).count
            guard letters > 0 else { continue }
            // Sözcük ortasındaki parantez ("the[lil") de okuma karışıklığıdır.
            let clean = cleanCore(core) == core && normalCase(core) && !core.contains(where: { "[]()".contains($0) })
            score += clean ? letters : -2 * letters
        }
        return score
    }

    /// Okuma çöp gibi mi: harflerinin altıda birinden çoğu bozuk sözcüklerde (karışık büyük-küçük harf, simge, ünlüsüz
    /// "Gtt"). Altyazılar geçişte birbirinin üstüne solarken yazı tanıma iki satırı karıştırıp ("Gtt solkolfege.")
    /// noktayla biten bir çöp okuyordu; nokta yüzünden ilk karede çevriliyor, TV'de anlamsız bir cümle beliriyordu.
    public static func looksGarbled(_ text: String) -> Bool {
        var good = 0, bad = 0
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let core = split(token).1
            let letters = core.filter(\.isLetter)
            guard !letters.isEmpty else { continue }
            let clean = cleanCore(core) == core && normalCase(core) && !core.contains(where: { "[]()".contains($0) })
                && !vowelless(letters)
            if clean { good += letters.count } else { bad += letters.count }
        }
        return bad * 6 > good + bad
    }

    /// Üç ve daha çok harfli, ünlüsüz ve kısaltma olmayan (tümü büyük harf değil) sözcük: İngilizcede olmaz ("Gtt", "rnnk").
    private static func vowelless(_ letters: String) -> Bool {
        letters.count >= 3 && !letters.allSatisfy(\.isUppercase)
            && !letters.lowercased().contains(where: { "aeiouyäöüıàáâèéêìíîòóôùúû".contains($0) })
    }

    /// "word", "WORD", "Word", "McDonald", "don't": büyük harf yalnız başta ya da baştan bir dizi.
    private static func normalCase(_ core: String) -> Bool {
        let letters = core.filter(\.isLetter)
        if letters.allSatisfy(\.isUppercase) || letters.dropFirst().allSatisfy(\.isLowercase) { return true }
        // Tek iç büyük harf ("McDonald", "iPhone") olağan; daha fazlası OCR karışıklığıdır.
        return letters.dropFirst().filter(\.isUppercase).count == 1 && letters.filter(\.isLowercase).count >= 2
    }

    /// "l", "|", "l'm", "|'ll" → "I", "I'm", "I'll" (nil: böyle bir okuma değil).
    private static func misreadI(_ core: String) -> String? {
        guard let first = core.first, first == "l" || first == "|" else { return nil }
        let rest = core.dropFirst()
        if rest.isEmpty { return "I" }
        guard let apostrophe = rest.first, apostrophe == "'" || apostrophe == "’",
              ["m", "ll", "ve", "d"].contains(rest.dropFirst()) else { return nil }
        return "I" + rest
    }

    /// Yalnız ? ! . , ; : işaretlerinden oluşan parça; üç nokta ("...") gerçek noktalamadır.
    private static func isStrayPunctuation(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { "?!.,;:".contains($0) } && !(token.count >= 2 && token.allSatisfy { $0 == "." })
    }

    /// Sözcüğün kendisi; nil ise tamamen çöptür.
    private static func cleanCore(_ core: String) -> String? {
        let letters = core.filter(\.isLetter).count
        let digits = core.filter(\.isNumber).count
        let hasSymbol = core.unicodeScalars.contains { symbols.contains($0) }
        guard letters > 0 else { return core }  // "24", "$500", "…"
        if !hasSymbol && digits == 0 { return core }
        if !hasSymbol && isUsualMix(core) { return core }
        // Gerçek sözcüğe yapışmış çöp: baştaki en az 3 harf korunur ("waters2aljd" → "waters").
        let prefix = core.prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
        if prefix.filter(\.isLetter).count >= 3 { return String(prefix) }
        return nil
    }

    /// "PS5", "R2", "MK2", "2nd", "100m", "4K", "60fps", "x2", "1980s": olağan harf-rakam karışımları.
    private static func isUsualMix(_ core: String) -> Bool {
        // "R2-D2" gibi tireli adlarda her parça ayrı denetlenir.
        core.split(separator: "-").allSatisfy { part in
            let part = String(part)
            guard part.contains(where: \.isNumber) else { return true }
            return usual.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)) != nil
        }
    }

    private static let usual = try! NSRegularExpression(
        pattern: "^(?:[A-Za-z]{1,4}\\d{1,4}|\\d+(?:st|nd|rd|th|s|k|K|m|km|kg|cm|mm|p|x|fps|hp|HP|XP|xp|v|V|D|d)|[xX]\\d{1,3}|\\d+[.,]\\d+[A-Za-z]{0,3}|\\d{1,2}[:.]\\d{2}(?:am|pm|AM|PM)?)$")

    private static func split(_ token: String) -> (String, String, String) {
        let scalars = Array(token.unicodeScalars)
        var start = 0, end = scalars.count
        while start < end, edgePunctuation.contains(scalars[start]) { start += 1 }
        while end > start, edgePunctuation.contains(scalars[end - 1]) { end -= 1 }
        func text(_ range: Range<Int>) -> String {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: scalars[range])
            return String(s)
        }
        return (text(0..<start), text(start..<end), text(end..<scalars.count))
    }
}
