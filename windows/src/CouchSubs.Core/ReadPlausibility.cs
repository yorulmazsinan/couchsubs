// SPDX-License-Identifier: AGPL-3.0-only

using System.Text;

namespace CouchSubs.Core;

/// <summary>
/// Yazı tanımanın bozduğu satır çeviri motoruna gitmez (GitHub #1293). Windows'un yazı tanıması güven değeri vermediği için
/// düşük güven süzgeci (#1370) burada hiç çalışmıyordu; paketteki satırlar düzgün çıkarken paket dışındaki satırlar bozuk
/// okunup ("es aepressea arter Donnıas aeatIT", "pop ılırıe man -ın DööStet Seat") Gemini'ye gidiyor, TV'de anlamsız
/// çeviriler beliriyordu. Bu süzgeç yalnız metne bakar; her okuyucuda (Windows, PaddleOCR, Vision, ML Kit) aynı çalışır.
///
/// Sözcük başına işaretler: İngilizce satırda yalnız Türkçede olan harf (ı, ş, ğ), sözcük içinde tuhaf büyük-küçük harf
/// ("aeatIT", "DööStet"), harflerin arasına girmiş rakam ("b1r") ve ünlüsüz sözcük ("flnd"). Satır ancak en az üç
/// sözcüklüyse, en az iki sözcük bozuksa, harflerinin en az üçte biri bozuk sözcüklerdeyse ve sözcüklerinin yarısından
/// azı sık İngilizce sözcükse bozuk sayılır; yalnız Türkçe harf yetmez (en az bir başka işaret gerekir). Ayrıca sık sözcük
/// ve ünlem olmayan sözcüklerde ünlü oranı beşte birin altındaysa ("Gtt rnnk flvd brrt") bozuktur. Kısa satırlar
/// ("Yeah.", "What?"), BÜYÜK HARF bağırma, adlar ("McDonald", "PlayStation"), ünlemler ("Hmm", "Pfft", "Nnngh"), sayılar
/// ve sohbet kısaltmaları dokunulmaz kalır. Mac/iPhone (ReadPlausibility.swift) ve Android (ReadPlausibility.kt) aynı kurallar.
/// </summary>
public static class ReadPlausibility
{
    internal enum Signal { Turkish, Digit, MixedCase, Vowelless, LowVowels }

    private static string Text(Signal signal) => signal switch
    {
        Signal.Turkish => "İngilizce satırda Türkçe harf",
        Signal.Digit => "sözcük içinde rakam",
        Signal.MixedCase => "karışık büyük-küçük harf",
        Signal.Vowelless => "ünlüsüz sözcük",
        _ => "ünlü oranı çok düşük",
    };

    /// <summary>Satırın bozuk sayılma nedeni (günlük için, Türkçe); düzgünse null.</summary>
    public static string? Reason(string text)
    {
        var words = Words(text);
        if (words.Count < 3) return null;
        if (TurkishText.LooksTurkish(text)) return null;
        int letters = 0, bad = 0, badWords = 0, known = 0, judgedLetters = 0, judgedVowels = 0;
        var reasons = new List<Signal>();
        foreach (var word in words)
        {
            var wordLetters = new string(word.Where(char.IsLetter).ToArray());
            letters += wordLetters.Length;
            if (IsKnown(word)) { known++; continue; }
            if (SignalOf(word) is { } signal)
            {
                bad += wordLetters.Length;
                badWords++;
                if (!reasons.Contains(signal)) reasons.Add(signal);
            }
            // Ünlü oranı: yalnız Latin harfli, BÜYÜK HARF olmayan, ünlem harflerinden oluşmayan sözcükler.
            if (wordLetters.All(IsLatin) && !wordLetters.All(char.IsUpper)
                && !wordLetters.ToLowerInvariant().All(c => GruntLetters.Contains(c)))
            {
                judgedLetters += wordLetters.Length;
                judgedVowels += wordLetters.Count(c => Vowels.Contains(c));
            }
        }
        if (known * 2 >= words.Count) return null;
        if (judgedLetters >= 12 && judgedVowels * 5 < judgedLetters) return Text(Signal.LowVowels);
        if (badWords < 2 || bad * 3 < letters || !reasons.Any(r => r != Signal.Turkish)) return null;
        return string.Join(", ", reasons.Select(Text));
    }

    /// <summary>Sözcüğün bozukluk işareti (null: düzgün ya da Latin harfli değil).</summary>
    internal static Signal? SignalOf(string word)
    {
        var cut = word.IndexOfAny(['\'', '’']);
        var stem = cut < 0 ? word : word[..cut];
        var letters = new string(stem.Where(char.IsLetter).ToArray());
        if (letters.Length == 0 || !letters.All(IsLatin)) return null;
        if (word.Any(c => TurkishOnly.Contains(c))) return Signal.Turkish;
        if (stem.Any(char.IsLower) && DigitInside(stem)) return Signal.Digit;
        if (stem.Split('-').Any(part => OddCase(new string(part.Where(char.IsLetter).ToArray())))) return Signal.MixedCase;
        var lower = letters.ToLowerInvariant();
        if (letters.Length >= 3 && !letters.All(char.IsUpper) && !letters.Any(c => Vowels.Contains(c))
            && !Interjections.Contains(Collapsed(lower)) && !lower.All(c => GruntLetters.Contains(c)))
            return Signal.Vowelless;
        return null;
    }

    /// <summary>Satırın sözcükleri: harf ve rakam dizileri; araya giren kesme ve tire sözcüğü bölmez ("don't",
    /// "Sh-sh-shut"). En az bir harf taşıyan sözcükler.</summary>
    internal static List<string> Words(string text)
    {
        var result = new List<string>();
        var current = new StringBuilder();
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (char.IsLetter(c) || char.IsNumber(c)) current.Append(c);
            else if ((c is '\'' or '’' or '-') && current.Length > 0 && i + 1 < text.Length && (char.IsLetter(text[i + 1]) || char.IsNumber(text[i + 1])))
                current.Append(c);
            else if (current.Length > 0)
            {
                result.Add(current.ToString());
                current.Clear();
            }
        }
        if (current.Length > 0) result.Add(current.ToString());
        return result.Where(word => word.Any(char.IsLetter)).ToList();
    }

    private static bool IsKnown(string word)
    {
        var key = word.ToLowerInvariant().Replace('’', '\'');
        return Common.Contains(key) || Chat.Contains(key);
    }

    /// <summary>Harf Latin alfabesinden mi (ASCII ya da U+00C0–U+024F). Başka yazıların (tam genişlik, Kiril, Japonca)
    /// sözcükleri yargılanmaz.</summary>
    private static bool IsLatin(char c) => c < 0x80 || c is >= 'À' and <= 'ɏ';

    /// <summary>"b1r", "h3p": küçük harfli sözcükte harflerin arasına rakam girmiş. "PS5", "M4A1", "2nd", "100m" sayılmaz.</summary>
    private static bool DigitInside(string stem)
    {
        var i = 1;
        while (i < stem.Length)
        {
            if (char.IsNumber(stem[i]) && char.IsLetter(stem[i - 1]))
            {
                var end = i;
                while (end < stem.Length && char.IsNumber(stem[end])) end++;
                if (end < stem.Length && char.IsLetter(stem[end])) return true;
                i = end;
            }
            else i++;
        }
        return false;
    }

    /// <summary>Tuhaf büyük-küçük harf. ASCII sözcükte yalnız en az üç küçük harfle başlayıp sonra büyük harf taşıyan
    /// ("aeatIT"); "McDonald", "PlayStation", "iPhone", "eBay", "WebRTC" olağan. ASCII dışı harfli sözcükte baştaki dışında
    /// her büyük harf ("DööStet"); tümü büyük harf olağan.</summary>
    private static bool OddCase(string letters)
    {
        if (letters.Length < 2 || letters.All(char.IsUpper) || letters.Skip(1).All(char.IsLower)) return false;
        if (letters.All(char.IsAscii)) return letters.TakeWhile(char.IsLower).Count() > 2;
        return true;
    }

    private static string Collapsed(string text)
    {
        var result = new StringBuilder();
        foreach (var c in text) if (result.Length == 0 || result[^1] != c) result.Append(c);
        return result.ToString();
    }

    private static readonly HashSet<char> Vowels = [.. "aeiouyäöüıàáâãåæèéêëìíîïòóôõøùúûýÿAEIOUYÄÖÜİÀÁÂÃÅÆÈÉÊËÌÍÎÏÒÓÔÕØÙÚÛÝ"];
    private static readonly HashSet<char> TurkishOnly = ['ı', 'İ', 'ş', 'Ş', 'ğ', 'Ğ'];
    /// <summary>Ünlüsüz ama gerçek ünlemler (art arda tekrarlar tek harf sayılır; <see cref="OcrNoise"/> ile aynı).</summary>
    private static readonly HashSet<string> Interjections = ["hm", "m", "sh", "br", "gr", "pst", "pft", "tsk", "hrm", "z", "pht"];
    /// <summary>Yalnız bu harflerden oluşan ünlüsüz sözcük inilti ya da ünlemdir ("Nnngh", "Hnnng", "Grrr", "Pfft").</summary>
    private static readonly HashSet<char> GruntLetters = [.. "hmngrszpfbt"];

    /// <summary>Sohbet ve argo kısaltmaları (ünlüsüz olsalar da sözcüktür).</summary>
    internal static readonly HashSet<string> Chat =
    [
        "thx", "pls", "plz", "omg", "lol", "lmao", "brb", "ttyl", "idk", "wtf", "smh", "tbh", "btw", "ppl", "msg", "txt",
        "bro", "ya", "u", "ur", "r", "k", "kk", "nvm", "rn", "wyd", "hmu", "gtg", "ty", "np", "yo", "sry", "tho", "cuz",
        "gonna", "wanna", "gotta", "dunno", "ain't", "y'all", "c'mon", "nah", "yep", "nope", "dude", "mr", "mrs", "ms", "dr",
    ];

    /// <summary>En sık İngilizce sözcükler (konuşma dili ağırlıklı). Satırın yarısı bunlardansa satır bozuk sayılmaz.</summary>
    internal static readonly HashSet<string> Common =
    [
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
    ];

    /// <summary>
    /// Bozuk satırın günlük satırı, seyreltilmiş: aynı metin <see cref="RepeatMs"/> içinde yeniden yazılmaz, bir dakikada en
    /// çok <see cref="PerMinute"/> satır (aşanlar sayılıp sonraki satırda bildirilir). Satır ekranda kaldıkça her karede
    /// yeniden okunur; günlük her karede dolmasın.
    /// </summary>
    public sealed class Log(Func<long>? clock = null)
    {
        public const long RepeatMs = 60_000;
        public const int PerMinute = 10;
        internal const int ExcerptLength = 80;
        private readonly Func<long> now = clock ?? (() => Environment.TickCount64);
        private readonly object gate = new();
        private readonly Dictionary<string, long> seen = [];
        private long? windowStart;
        private int written;
        private int suppressed;

        /// <summary>Yazılacak satır; aynı metin yakın zamanda yazıldıysa ya da dakikalık sınır dolduysa null.</summary>
        public string? Line(string text, string reason)
        {
            var excerpt = Excerpt(text);
            lock (gate)
            {
                var time = now();
                if (seen.TryGetValue(excerpt, out var last) && time - last < RepeatMs) return null;
                if (windowStart is { } start && time - start < 60_000)
                {
                    if (written >= PerMinute)
                    {
                        suppressed++;
                        return null;
                    }
                }
                else
                {
                    windowStart = time;
                    written = 0;
                }
                written++;
                seen[excerpt] = time;
                if (seen.Count > 128)
                    foreach (var key in seen.Where(pair => time - pair.Value >= RepeatMs).Select(pair => pair.Key).ToList()) seen.Remove(key);
                var line = $"okuma bozuk görünüyor, çeviriye gönderilmedi: «{excerpt}» ({reason})";
                if (suppressed > 0)
                {
                    line += $" (+{suppressed} satır sınır yüzünden yazılmadı)";
                    suppressed = 0;
                }
                return line;
            }
        }

        internal static string Excerpt(string text)
        {
            var flat = string.Join(" / ", text.Split('\n', '\r').Select(part => part.Trim()).Where(part => part.Length > 0));
            return flat.Length > ExcerptLength ? flat[..(ExcerptLength - 1)] + "…" : flat;
        }
    }
}
