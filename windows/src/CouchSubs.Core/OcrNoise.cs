// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text.RegularExpressions;

namespace CouchSubs.Core;

/// <summary>
/// Süslü yazı tiplerinde, solan ya da titreyen altyazıda yazı tanıma bazı sözcükleri harf, rakam ve simge
/// karışımı çöpe çevirir ("ou$3e", "waters2aljd"). Bunlar hiçbir dilde sözcük değildir; çevirmen onları
/// olduğu gibi taşır. Sözcük ortasında simge ya da harflerle rakamların iç içe geçtiği parçalar atılır;
/// gerçek bir sözcüğe yapışmış çöp ("waters2aljd") sözcükten ayrılır. "PS5", "R2", "2nd", "100m", "$500"
/// gibi olağan biçimler korunur (Mac'teki OcrNoise ile aynı kurallar).
/// </summary>
public static partial class OcrNoise
{
    private const string Symbols = "$@#%^*_=|\\~<>{}¢£¥§©®°±µ¶¤";

    public static string Clean(string line)
    {
        var kept = new List<string>();
        var tokens = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        for (var index = 0; index < tokens.Length; index++)
        {
            var token = tokens[index];
            var (lead, core, trail) = Split(token);
            // Tek başına "l" ya da "|" çoğu zaman yanlış okunmuş "I"dır ("l don't know", "|'ll go"); ardından küçük
            // harfle süren sözcük gelmiyorsa altyazı kutusunun kenarıdır ("| Get in the car."), atılır.
            if (MisreadI(core) is { } pronoun)
            {
                var next = index + 1 < tokens.Length ? tokens[index + 1].FirstOrDefault(char.IsLetter) : '\0';
                if (pronoun != "I" || char.IsLower(next)) kept.Add(lead + pronoun + trail);
                continue;
            }
            // Yalnız "?!", ".", "," gibi işaretlerden oluşan parça: satır başında ya da cümle bittikten sonra yazı
            // tanımanın uydurmasıdır ("?! Where", "car. ?!"); sözcükten ayrı düşmüşse sözcüğe yapışır ("going ?!").
            if (core.Length == 0 && IsStrayPunctuation(token))
            {
                if (kept.Count > 0 && !".?!…,;:".Contains(kept[^1][^1])) kept[^1] += token;
                continue;
            }
            if (CleanCore(core) is { } fixedCore)
                kept.Add(lead + fixedCore + trail);
            else if (trail.Length > 0 && kept.Count > 0)
                // Atılan çöpün ardındaki noktalama cümleye aittir ("ou$3e," → virgül kalır).
                kept[^1] += trail;
        }
        // Altyazının yanındaki göstergenin sayısı satırın başına yapışıyor ("9? We'll lose", "100. Mac and John").
        // Mesafe işareti de öyle ("23m CESARE: Here!"). Tek başına sayı ve ardından büyük harfle başlayan cümle: sayı atılır.
        if (kept.Count >= 3 && LeadingNumber().IsMatch(kept[0]) && char.IsUpper(kept[1][0])) kept.RemoveAt(0);
        return string.Join(' ', kept);
    }

    [GeneratedRegex(@"^\d+(?:m|km|ft|yd)?[.?!:;]?$")]
    private static partial Regex LeadingNumber();

    /// <summary>
    /// Bir okumanın ne kadar sözcük gibi göründüğü: düzgün sözcüklerin harfleri artı, çöp ve karışık büyük-küçük
    /// harfli parçalar ("CESAREiVJütt'h") eksi sayılır. Aynı karenin iki okumasından iyisini seçmek için.
    /// </summary>
    public static int Score(string text)
    {
        var score = 0;
        foreach (var token in text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var core = Split(token).Core;
            var letters = core.Count(char.IsLetter);
            if (letters == 0) continue;
            // Sözcük ortasındaki parantez ("the[lil") de okuma karışıklığıdır.
            var clean = CleanCore(core) == core && NormalCase(core) && core.IndexOfAny(['[', ']', '(', ')']) < 0;
            score += clean ? letters : -2 * letters;
        }
        return score;
    }

    /// <summary>
    /// Okuma çöp gibi mi: harflerinin altıda birinden çoğu bozuk sözcüklerde (karışık büyük-küçük harf, simge, ünlüsüz
    /// "Gtt"). Altyazılar geçişte birbirinin üstüne solarken yazı tanıma iki satırı karıştırıp ("Gtt solkolfege.")
    /// noktayla biten bir çöp okuyordu; nokta yüzünden ilk karede çevriliyor, TV'de anlamsız bir cümle beliriyordu (Mac ile aynı).
    /// </summary>
    public static bool LooksGarbled(string text)
    {
        int good = 0, bad = 0;
        foreach (var token in text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var core = Split(token).Core;
            var letters = new string(core.Where(char.IsLetter).ToArray());
            if (letters.Length == 0) continue;
            var clean = CleanCore(core) == core && NormalCase(core) && core.IndexOfAny(['[', ']', '(', ')']) < 0 && !Vowelless(letters);
            if (clean) good += letters.Length; else bad += letters.Length;
        }
        return bad * 6 > good + bad;
    }

    /// <summary>Üç ve daha çok harfli, ünlüsüz ve kısaltma olmayan (tümü büyük harf değil) sözcük: İngilizcede olmaz ("Gtt", "rnnk").</summary>
    private static bool Vowelless(string letters) =>
        letters.Length >= 3 && !letters.All(char.IsUpper) && letters.ToLowerInvariant().IndexOfAny("aeiouyäöüıàáâèéêìíîòóôùúû".ToCharArray()) < 0;

    /// <summary>"word", "WORD", "Word", "McDonald", "don't": büyük harf yalnız başta ya da baştan bir dizi.</summary>
    private static bool NormalCase(string core)
    {
        var letters = core.Where(char.IsLetter).ToArray();
        if (letters.All(char.IsUpper) || letters.Skip(1).All(char.IsLower)) return true;
        // Tek iç büyük harf ("McDonald", "iPhone") olağan; daha fazlası OCR karışıklığıdır.
        return letters.Skip(1).Count(char.IsUpper) == 1 && letters.Count(char.IsLower) >= 2;
    }

    /// <summary>"l", "|", "l'm", "|'ll" → "I", "I'm", "I'll" (null: böyle bir okuma değil).</summary>
    private static string? MisreadI(string core)
    {
        if (core.Length == 0 || core[0] is not ('l' or '|')) return null;
        if (core.Length == 1) return "I";
        if (core[1] is not ('\'' or '’') || core[2..] is not ("m" or "ll" or "ve" or "d")) return null;
        return "I" + core[1..];
    }

    /// <summary>Yalnız ? ! . , ; : işaretlerinden oluşan parça; üç nokta ("...") gerçek noktalamadır.</summary>
    private static bool IsStrayPunctuation(string token) =>
        token.Length > 0 && token.All(c => "?!.,;:".Contains(c)) && !(token.Length >= 2 && token.All(c => c == '.'));

    /// <summary>Sözcüğün kendisi; null ise tamamen çöptür.</summary>
    private static string? CleanCore(string core)
    {
        var letters = core.Count(char.IsLetter);
        var digits = core.Count(char.IsNumber);
        var hasSymbol = core.Any(c => Symbols.Contains(c));
        if (letters == 0) return core;  // "24", "$500", "…"
        if (!hasSymbol && digits == 0) return core;
        if (!hasSymbol && IsUsualMix(core)) return core;
        // Gerçek sözcüğe yapışmış çöp: baştaki en az 3 harf korunur ("waters2aljd" → "waters").
        var prefix = new string(core.TakeWhile(c => char.IsLetter(c) || c is '\'' or '’' or '-').ToArray());
        return prefix.Count(char.IsLetter) >= 3 ? prefix : null;
    }

    /// <summary>"PS5", "R2", "MK2", "2nd", "100m", "4K", "60fps", "x2", "1980s", "R2-D2": olağan harf-rakam karışımları.</summary>
    private static bool IsUsualMix(string core) =>
        core.Split('-').All(part => !part.Any(char.IsNumber) || Usual().IsMatch(part));

    [GeneratedRegex(@"^(?:[A-Za-z]{1,4}\d{1,4}|\d+(?:st|nd|rd|th|s|k|K|m|km|kg|cm|mm|p|x|fps|hp|HP|XP|xp|v|V|D|d)|[xX]\d{1,3}|\d+[.,]\d+[A-Za-z]{0,3}|\d{1,2}[:.]\d{2}(?:am|pm|AM|PM)?)$")]
    private static partial Regex Usual();

    private static bool IsEdge(char c) =>
        !Symbols.Contains(c) && (char.IsPunctuation(c) || char.IsSymbol(c) || "\"'“”‘’«»()[]".Contains(c));

    private static (string Lead, string Core, string Trail) Split(string token)
    {
        int start = 0, end = token.Length;
        while (start < end && IsEdge(token[start])) start++;
        while (end > start && IsEdge(token[end - 1])) end--;
        return (token[..start], token[start..end], token[end..]);
    }
}
