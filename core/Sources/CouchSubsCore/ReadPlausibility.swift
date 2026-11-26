// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Yazı tanımanın bozduğu satır çeviri motoruna gitmez (GitHub #1293). Windows'un yazı tanıması güven değeri vermediği için
/// düşük güven süzgeci (#1370) orada hiç çalışmıyordu; paketteki satırlar düzgün çıkarken paket dışındaki satırlar bozuk
/// okunup ("es aepressea arter Donnıas aeatIT", "pop ılırıe man -ın DööStet Seat") Gemini'ye gidiyor, TV'de anlamsız
/// çeviriler beliriyordu. Bu süzgeç yalnız metne bakar; her okuyucuda (Windows, Vision, ML Kit, PaddleOCR) aynı çalışır.
///
/// Sözcük başına işaretler: İngilizce satırda yalnız Türkçede olan harf (ı, ş, ğ), sözcük içinde tuhaf büyük-küçük harf
/// ("aeatIT", "DööStet"), harflerin arasına girmiş rakam ("b1r") ve ünlüsüz sözcük ("flnd"). Satır ancak en az üç
/// sözcüklüyse, en az iki sözcük bozuksa, harflerinin en az üçte biri bozuk sözcüklerdeyse ve sözcüklerinin yarısından
/// azı sık İngilizce sözcükse bozuk sayılır; yalnız Türkçe harf yetmez (en az bir başka işaret gerekir). Ayrıca sık sözcük
/// ve ünlem olmayan sözcüklerde ünlü oranı beşte birin altındaysa ("Gtt rnnk flvd brrt") bozuktur. Kısa satırlar
/// ("Yeah.", "What?"), BÜYÜK HARF bağırma, adlar ("McDonald", "PlayStation"), ünlemler ("Hmm", "Pfft", "Nnngh"), sayılar
/// ve sohbet kısaltmaları dokunulmaz kalır. Windows (ReadPlausibility.cs) ve Android (ReadPlausibility.kt) aynı kurallar.
public enum ReadPlausibility {
    /// Satırın bozuk sayılma nedeni (günlük için, Türkçe); düzgünse nil.
    public static func reason(_ text: String) -> String? {
        let words = words(text)
        guard words.count >= 3 else { return nil }
        if TurkishText.looksTurkish(text) { return nil }
        var letters = 0, bad = 0, badWords = 0, known = 0
        var reasons: [Signal] = []
        var judgedLetters = 0, judgedVowels = 0
        for word in words {
            let count = word.filter(\.isLetter).count
            letters += count
            if isKnown(word) {
                known += 1
                continue
            }
            if let signal = signal(word) {
                bad += count
                badWords += 1
                if !reasons.contains(signal) { reasons.append(signal) }
            }
            // Ünlü oranı: yalnız Latin harfli, BÜYÜK HARF olmayan, ünlem harflerinden oluşmayan sözcükler.
            let wordLetters = word.filter(\.isLetter)
            if wordLetters.allSatisfy(isLatin), !wordLetters.allSatisfy(\.isUppercase),
               !wordLetters.lowercased().allSatisfy({ gruntLetters.contains($0) }) {
                judgedLetters += wordLetters.count
                judgedVowels += wordLetters.filter(isVowel).count
            }
        }
        guard known * 2 < words.count else { return nil }
        if judgedLetters >= 12, judgedVowels * 5 < judgedLetters { return Signal.lowVowels.text }
        guard badWords >= 2, bad * 3 >= letters, reasons.contains(where: { $0 != .turkish }) else { return nil }
        return reasons.map(\.text).joined(separator: ", ")
    }

    enum Signal: Equatable {
        case turkish, digit, mixedCase, vowelless, lowVowels
        var text: String {
            switch self {
            case .turkish: "İngilizce satırda Türkçe harf"
            case .digit: "sözcük içinde rakam"
            case .mixedCase: "karışık büyük-küçük harf"
            case .vowelless: "ünlüsüz sözcük"
            case .lowVowels: "ünlü oranı çok düşük"
            }
        }
    }

    /// Sözcüğün bozukluk işareti (nil: düzgün ya da Latin harfli değil).
    static func signal(_ word: String) -> Signal? {
        let stem = String(word.prefix { $0 != "'" && $0 != "’" })
        let letters = stem.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy(isLatin) else { return nil }
        if word.contains(where: { turkishOnly.contains($0) }) { return .turkish }
        if stem.contains(where: \.isLowercase), digitInside(stem) { return .digit }
        if stem.split(separator: "-").contains(where: { oddCase(String($0.filter(\.isLetter))) }) { return .mixedCase }
        let lower = letters.lowercased()
        if letters.count >= 3, !letters.allSatisfy(\.isUppercase), !letters.contains(where: isVowel),
           !interjections.contains(collapsed(lower)), !lower.allSatisfy({ gruntLetters.contains($0) }) {
            return .vowelless
        }
        return nil
    }

    /// Satırın sözcükleri: harf ve rakam dizileri; araya giren kesme ve tire sözcüğü bölmez ("don't", "Sh-sh-shut"). En az
    /// bir harf taşıyan sözcükler.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if "'’-".contains(character), !current.isEmpty, index + 1 < characters.count,
                      characters[index + 1].isLetter || characters[index + 1].isNumber {
                current.append(character)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { $0.contains(where: \.isLetter) }
    }

    private static func isKnown(_ word: String) -> Bool {
        let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
        return common.contains(key) || chat.contains(key)
    }

    /// Harf Latin alfabesinden mi (ASCII ya da U+00C0–U+024F). Başka yazıların (tam genişlik, Kiril, Japonca) sözcükleri yargılanmaz.
    private static func isLatin(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value, character.unicodeScalars.count == 1 else { return false }
        return value < 0x80 || (0xC0...0x24F).contains(value)
    }

    private static func isVowel(_ character: Character) -> Bool { vowels.contains(character) }

    /// "b1r", "h3p": küçük harfli sözcükte harflerin arasına rakam girmiş. "PS5", "M4A1", "2nd", "100m" sayılmaz.
    private static func digitInside(_ stem: String) -> Bool {
        let characters = Array(stem)
        var index = 1
        while index < characters.count {
            if characters[index].isNumber, characters[index - 1].isLetter {
                var end = index
                while end < characters.count, characters[end].isNumber { end += 1 }
                if end < characters.count, characters[end].isLetter { return true }
                index = end
            } else {
                index += 1
            }
        }
        return false
    }

    /// Tuhaf büyük-küçük harf. ASCII sözcükte yalnız en az üç küçük harfle başlayıp sonra büyük harf taşıyan ("aeatIT");
    /// "McDonald", "PlayStation", "iPhone", "eBay", "WebRTC" olağan. ASCII dışı harfli sözcükte baştaki dışında her büyük
    /// harf ("DööStet"); tümü büyük harf olağan.
    private static func oddCase(_ letters: String) -> Bool {
        guard letters.count >= 2, !letters.allSatisfy(\.isUppercase), !letters.dropFirst().allSatisfy(\.isLowercase) else { return false }
        if letters.allSatisfy(\.isASCII) { return letters.prefix(while: \.isLowercase).count > 2 }
        return true
    }

    private static func collapsed(_ text: String) -> String {
        var result = ""
        for character in text where character != result.last { result.append(character) }
        return result
    }

    private static let vowels: Set<Character> = Set("aeiouyäöüıàáâãåæèéêëìíîïòóôõøùúûýÿAEIOUYÄÖÜİÀÁÂÃÅÆÈÉÊËÌÍÎÏÒÓÔÕØÙÚÛÝ")
    private static let turkishOnly: Set<Character> = ["ı", "İ", "ş", "Ş", "ğ", "Ğ"]
    /// Ünlüsüz ama gerçek ünlemler (art arda tekrarlar tek harf sayılır; `OcrNoise` ile aynı).
    private static let interjections: Set<String> = ["hm", "m", "sh", "br", "gr", "pst", "pft", "tsk", "hrm", "z", "pht"]
    /// Yalnız bu harflerden oluşan ünlüsüz sözcük inilti ya da ünlemdir ("Nnngh", "Hnnng", "Grrr", "Pfft").
    private static let gruntLetters: Set<Character> = Set("hmngrszpfbt")

    /// Sohbet ve argo kısaltmaları (ünlüsüz olsalar da sözcüktür).
    static let chat: Set<String> = [
        "thx", "pls", "plz", "omg", "lol", "lmao", "brb", "ttyl", "idk", "wtf", "smh", "tbh", "btw", "ppl", "msg", "txt",
        "bro", "ya", "u", "ur", "r", "k", "kk", "nvm", "rn", "wyd", "hmu", "gtg", "ty", "np", "yo", "sry", "tho", "cuz",
        "gonna", "wanna", "gotta", "dunno", "ain't", "y'all", "c'mon", "nah", "yep", "nope", "dude", "mr", "mrs", "ms", "dr",
    ]

    /// En sık İngilizce sözcükler (konuşma dili ağırlıklı). Satırın yarısı bunlardansa satır bozuk sayılmaz.
    static let common: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "almost", "alone", "along", "already", "also", "always",
        "am", "an", "and", "another", "any", "anyone", "anything", "are", "around", "as", "ask", "at", "away", "back", "bad",
        "be", "because", "been", "before", "behind", "being", "believe", "best", "better", "between", "big", "both", "boy",
        "bring", "but", "buy", "by", "call", "came", "can", "can't", "car", "check", "come", "cops", "could", "couldn't",
        "dad", "day", "dead", "did", "didn't", "die", "do", "does", "doesn't", "dog", "don't", "done", "door", "down",
        "drive", "each", "else", "end", "enough", "even", "ever", "every", "everyone", "everything", "eye", "face", "fact",
        "far", "feel", "few", "find", "fine", "first", "for", "found", "friend", "from", "fuck", "fucking", "get", "gets",
        "girl", "give", "go", "god", "going", "gone", "good", "got", "great", "guy", "guys", "had", "has", "hate", "have",
        "haven't", "he", "he's", "head", "hear", "hell", "help", "her", "here", "hey", "him", "his", "hold", "home", "hope",
        "house", "how", "i", "i'd", "i'll", "i'm", "i've", "if", "in", "inside", "into", "is", "isn't", "it", "it's", "job",
        "just", "keep", "kill", "kind", "know", "last", "leave", "left", "let", "let's", "life", "like", "listen", "little",
        "long", "look", "lot", "love", "made", "make", "man", "many", "may", "me", "mean", "men", "might", "mind", "miss",
        "mom", "money", "more", "most", "move", "much", "must", "my", "name", "need", "never", "new", "next", "nice",
        "night", "no", "not", "nothing", "now", "of", "off", "oh", "ok", "okay", "old", "on", "once", "one", "only", "or",
        "other", "our", "out", "over", "own", "people", "place", "play", "please", "police", "put", "real", "really",
        "right", "run", "said", "same", "saw", "say", "see", "seen", "she", "shit", "should", "show", "shut", "since", "so",
        "some", "someone", "something", "sorry", "still", "stop", "sure", "take", "talk", "tell", "than", "thank", "thanks",
        "that", "that's", "the", "their", "them", "then", "there", "there's", "these", "they", "they're", "thing", "think",
        "this", "those", "though", "thought", "through", "time", "to", "today", "together", "told", "tonight", "too", "took",
        "town", "try", "trying", "two", "up", "us", "use", "very", "wait", "want", "wanted", "was", "wasn't", "watch",
        "way", "we", "we're", "well", "went", "were", "what", "what's", "when", "where", "which", "while", "who", "why",
        "will", "with", "without", "won't", "work", "world", "would", "wouldn't", "yeah", "yes", "yet", "you", "you're",
        "your", "yourself",
    ]

    /// Bozuk satırın günlük satırı, seyreltilmiş: aynı metin `repeatMs` içinde yeniden yazılmaz, bir dakikada en çok
    /// `perMinute` satır (aşanlar sayılıp sonraki satırda bildirilir). Satır ekranda kaldıkça her karede yeniden okunur;
    /// günlük her karede dolmasın.
    public final class Log: @unchecked Sendable {
        public static let repeatMs = 60_000
        public static let perMinute = 10
        static let excerptLength = 80
        private let lock = NSLock()
        private let now: () -> Int
        private var seen: [String: Int] = [:]
        private var windowStart: Int?
        private var written = 0
        private var suppressed = 0

        public init(clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs) { now = clock }

        /// Yazılacak satır; aynı metin yakın zamanda yazıldıysa ya da dakikalık sınır dolduysa nil.
        public func line(_ text: String, reason: String) -> String? {
            let excerpt = Self.excerpt(text)
            return lock.withLock {
                let time = now()
                if let last = seen[excerpt], time - last < Self.repeatMs { return nil }
                if let start = windowStart, time - start < 60_000 {
                    guard written < Self.perMinute else {
                        suppressed += 1
                        return nil
                    }
                } else {
                    windowStart = time
                    written = 0
                }
                written += 1
                seen[excerpt] = time
                if seen.count > 128 { seen = seen.filter { time - $0.value < Self.repeatMs } }
                var line = "okuma bozuk görünüyor, çeviriye gönderilmedi: «\(excerpt)» (\(reason))"
                if suppressed > 0 {
                    line += " (+\(suppressed) satır sınır yüzünden yazılmadı)"
                    suppressed = 0
                }
                return line
            }
        }

        static func excerpt(_ text: String) -> String {
            let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " / ")
            return flat.count > excerptLength ? String(flat.prefix(excerptLength - 1)) + "…" : flat
        }
    }
}
