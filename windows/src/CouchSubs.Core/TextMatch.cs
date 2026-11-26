// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text;

namespace CouchSubs.Core;

/// <summary>OCR çıktılarını karşılaştırmak için sadeleştirme ve gürültüye dayanıklı benzerlik.</summary>
public static class TextMatch
{
    /// <summary>Küçük harf, yalnız harf/rakam, tek boşluk.</summary>
    public static string Normalize(string s)
    {
        var builder = new StringBuilder(s.Length);
        foreach (var c in s.ToLowerInvariant())
            builder.Append(IsAlphanumeric(c) ? c : ' ');
        return string.Join(' ', builder.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    /// <summary>Levenshtein oranı <paramref name="threshold"/> ve üstündeyse benzer sayılır. Boş metin hiçbir metne benzemez.</summary>
    public static bool IsSimilar(string a, string b, double threshold = 0.85)
    {
        if (a == b) return a.Length > 0;
        if (a.Length == 0 || b.Length == 0) return false;
        var previous = new int[b.Length + 1];
        var row = new int[b.Length + 1];
        for (var j = 0; j <= b.Length; j++) previous[j] = j;
        for (var i = 1; i <= a.Length; i++)
        {
            row[0] = i;
            for (var j = 1; j <= b.Length; j++)
                row[j] = Math.Min(Math.Min(previous[j] + 1, row[j - 1] + 1), previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
            (previous, row) = (row, previous);
        }
        return 1 - (double)previous[b.Length] / Math.Max(a.Length, b.Length) >= threshold;
    }

    /// <summary>Boşluksuz harf dizisinin en az bu kadar uzun olması gerekir; kısa satırda bir harf bile anlamı değiştirir.</summary>
    internal const int SameLettersMinimum = 6;

    /// <summary>
    /// Sadeleştirilmiş iki okuma boşluklar atılınca neredeyse aynı mı. Bozuk okumada OCR bir sözcüğü bölebilir ya da iki
    /// sözcüğü birleştirebilir ("That smo e..." / "That smoke...", #296); sözcük sayısı değişince sözcük sözcük
    /// karşılaştırma aynı satırı tanımaz. Çağıran, okumalardan birinin bozuk olduğunu ayrıca denetler.
    /// </summary>
    public static bool SameLetters(string a, string b)
    {
        var x = a.Replace(" ", "");
        var y = b.Replace(" ", "");
        return Math.Min(x.Length, y.Length) >= SameLettersMinimum && IsSimilar(x, y, 0.8);
    }

    /// <summary>Satırları ayrı ayrı sadeleştirip alt alta birleştirir; <see cref="IsSameSubtitle"/> kaçırılan satırı bundan anlar.</summary>
    public static string NormalizeRows(string s) =>
        string.Join('\n', s.Replace("\r\n", "\n").Split('\n').Select(Normalize).Where(row => row.Length > 0));

    /// <summary>
    /// Yeni okuma, gönderilmiş altyazının yeniden okuması mı (sadeleştirilmiş metinler; <paramref name="sent"/> satırları
    /// <see cref="NormalizeRows"/> ile alt alta verilebilir). Süslü yazı tipinde ya da solarken OCR bir iki sözcüğü her
    /// karede başka çöpe çevirir ("ou$3e", "waters2aljd") ya da iki satırlık altyazının bir satırını kaçırır; karakter
    /// benzerliği düşse de sözcükler aynı kalır. Rakam karışmış sözcükler ve tek harfler çöp sayılıp karşılaştırmaya girmez.
    /// Başına ya da sonuna sözcük eklenmiş metin (daktilo efekti, "Nereye gidiyorsun?" / "Nereye gidiyorsun evlat?") yenidir;
    /// sondan kısalmış metin ise ancak tam bir satırı eksikse aynı altyazıdır.
    /// </summary>
    public static bool IsSameSubtitle(string reread, string sent)
    {
        var rows = sent.Split('\n');
        var flat = string.Join(' ', rows);
        // Gönderilende olmayan olumsuzluk ya da sayı taşıyan okuma, karakterce ne kadar benzese de başka bir cümledir.
        if (AddsMeaning(reread, flat)) return false;
        var x = CleanWords(reread);
        var y = CleanWords(flat);
        // Uzayan metin (daktilo efekti ya da aynı sözlerle başlayan yeni satır) karakterce benzese de yenidir.
        if (y.Count > 0 && x.Count > y.Count && (StartsWith(x, y) || EndsWith(x, y))) return false;
        if (IsSimilar(reread, flat)) return true;
        // Baştan ya da sondan kesilmiş okuma: altyazının yalnız tam satırları okunduysa aynıdır, yoksa başka bir cümledir.
        if (x.Count > 0 && x.Count < y.Count && (StartsWith(y, x) || EndsWith(y, x)))
            return IsWholeRows(x.Count, rows, StartsWith(y, x));
        var remaining = new List<string>(y);
        var sentCount = remaining.Count;
        var shared = 0;
        foreach (var word in x)
            if (remaining.Remove(word)) shared++;
        // Arasından çöp sözcükler düşmüş okuma: yeni okumanın sözcüklerinin hemen hepsi gönderilende var.
        if (x.Count >= 4 && x.Count <= sentCount && shared >= x.Count * 0.85) return true;
        // Kısa satırda tek sözcük anlamı değiştirir ("where is the boy" / "ship"); orada yalnız karakter benzerliği geçerli.
        int longer = Math.Max(x.Count, sentCount), shorter = Math.Min(x.Count, sentCount);
        if (shorter < 6 || (double)shorter / longer < 0.75) return false;
        return (double)shared / longer >= 0.75;
    }

    /// <summary>
    /// Yeni satır, az önce gösterilen satırın uzamış ya da düzelmiş okuması mı: daktilo efektinde büyüyen cümle
    /// ("We do not have" → "We do not have time."), belirirken yarım okunan satır, bir iki sözcüğü başka okunan aynı
    /// cümle. TV böyle bir çeviriyi öncekinin üstüne yığmaz, yerine koyar; yoksa aynı cümlenin iki üç çevirisi üst üste
    /// duruyordu. Ham metinler verilir (Mac: TextMatch.isRevision).
    /// </summary>
    public static bool IsRevision(string newText, string oldText)
    {
        var x = Normalize(newText);
        var y = Normalize(oldText);
        if (x.Length == 0 || y.Length == 0) return false;
        if (IsLooseGrowth(newText, oldText) || IsLooseGrowth(oldText, newText)) return true;
        if (IsSimilar(x, y, 0.8)) return true;
        var a = CleanWords(x);
        var b = CleanWords(y);
        int shorter = Math.Min(a.Count, b.Count), longer = Math.Max(a.Count, b.Count);
        if (shorter < 5) return false;
        if (Similarity(a, b) >= 0.65) return true;
        var shared = 0;
        foreach (var word in a)
            if (b.Remove(word)) shared++;
        return (double)shared / longer >= 0.7;
    }

    /// <summary>
    /// Okuma, gönderilmiş satırın aynı cümleyi bozuk okuyan ve ondan daha iyi olmayan bir yeniden okuması mı. Açık zeminde
    /// ya da süslü yazıda yazı tanıma her karede bir iki sözcüğü başka okur ("somethin'" / "somethinl") ya da araya bir
    /// sözcük ekler/düşürür; benzerlik <see cref="IsSameSubtitle"/>'ın sınırının altında kalınca her okuma ayrı çevriliyor,
    /// TV'de aynı cümlenin üç çevirisi üst üste duruyordu (GTA V, #26). Sözcük sırasıyla karşılaştırılır (en çok üç
    /// sözcükte bir fark) ya da karakterce çok benzer; uzayan ve baştan/sondan kısalan metin <see cref="IsSameSubtitle"/>'a
    /// kalır. Daha çok sözcük okuyan (puanı belirgin yüksek) okuma kötü sayılmaz, yeniden çevrilir (Mac: TextMatch.isWorseReread).
    /// </summary>
    public static bool IsWorseReread(string reread, string sent)
    {
        var a = Normalize(reread);
        var b = Normalize(sent);
        var x = CleanWords(a);
        var y = CleanWords(b);
        if (x.Count < 5 || y.Count == 0 || IsGrowth(reread, sent) || IsGrowth(sent, reread) || AddsMeaning(reread, sent)) return false;
        var reads = Similarity(x, y) >= 0.65 || IsSimilar(a, b, 0.75);
        return reads && OcrNoise.Score(reread) < OcrNoise.Score(sent) + 4;
    }

    /// <summary>Olumsuzluk sözcükleri; kesme işaretini kaçıran okumalar ("dont", "cant") da sayılır.</summary>
    private static readonly HashSet<string> Negations = new(StringComparer.Ordinal)
    {
        "not", "no", "never", "nothing", "nobody", "none", "nowhere", "neither", "nor", "cannot",
        "dont", "doesnt", "didnt", "cant", "wont", "isnt", "arent", "wasnt", "werent", "aint",
        "couldnt", "shouldnt", "wouldnt", "havent", "hasnt", "hadnt", "mustnt", "neednt",
    };

    /// <summary>
    /// <paramref name="reread"/>, <paramref name="sent"/>'te olmayan bir anlam işareti taşıyor mu: daha çok olumsuzluk
    /// ya da gönderilende bulunmayan bir sayı. Bu farklar karakterce küçüktür ("I can do that for you right now." / "I can't do that for you right now.":
    /// 0.94, "at 5" / "at 6": 0.92) ama cümleyi tersine çevirir; altyazının ilk karesi olumsuzluğu kaçırıp hızlı yoldan
    /// gittiyse doğru okuma yeniden okuma sayılıp atılıyor, TV'de ters çeviri kalıyordu. Yalnız EKLENEN işaret sayılır:
    /// işareti düşüren okuma ("can't" → "can") çoğu zaman OCR kaybıdır ve gösterileni bozmamalıdır. Rakam karışmış
    /// sözcük ("n0t") OCR karışıklıklarına göre harfe çevrilip sayılır; kesmenin tek başına kalan "t"si ("can t")
    /// bilinen bir olumsuz kısaltmayı tamamladığında olumsuzluktur. Ham ya da sadeleştirilmiş metin verilebilir.
    /// </summary>
    public static bool AddsMeaning(string reread, string sent)
    {
        var words = Normalize(reread).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var sentWords = Normalize(sent).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var (negations, numbers) = MeaningMarks(words);
        var (sentNegations, sentNumbers) = MeaningMarks(sentWords);
        if (negations > sentNegations) return true;
        if (numbers.Count == 0) return false;
        // Eşit uzunlukta sözcük konumunu, eksik/ek sözcükte eşleşen baş/son bölümü kullan.
        // Baştaki "I", başka konumdaki gerçek "5 → 1" değişimini gizlememeli.
        if (words.Length == sentWords.Length)
        {
            for (var i = 0; i < words.Length; i++)
                if (words[i] != sentWords[i] && SameGlyphWord(words[i], sentWords[i])) numbers.Remove(words[i]);
        }
        else
        {
            var prefix = 0;
            while (prefix < Math.Min(words.Length, sentWords.Length) && SameGlyphWord(words[prefix], sentWords[prefix]))
            {
                if (words[prefix] != sentWords[prefix]) numbers.Remove(words[prefix]);
                prefix++;
            }
            for (int i = words.Length - 1, j = sentWords.Length - 1;
                 i >= prefix && j >= prefix && SameGlyphWord(words[i], sentWords[j]); i--, j--)
                if (words[i] != sentWords[j]) numbers.Remove(words[i]);
        }
        foreach (var number in numbers)
            if (!sentNumbers.Remove(number)) return true;
        return false;
    }

    private static bool SameGlyphWord(string word, string sent) =>
        word == sent || (word.All(char.IsAsciiDigit) && FoldDigits(word) == sent);

    private static (int Negations, List<string> Numbers) MeaningMarks(string[] words)
    {
        var negations = 0;
        var numbers = new List<string>();
        for (var i = 0; i < words.Length; i++)
        {
            var word = words[i];
            if (word.All(char.IsAsciiDigit))
            {
                numbers.Add(word);
                continue;
            }
            if (word.Any(char.IsAsciiDigit)) word = FoldDigits(word);
            if (Negations.Contains(word) || (word == "t" && i > 0 && Negations.Contains(FoldDigits(words[i - 1]) + "t"))) negations++;
        }
        return (negations, numbers);
    }

    /// <summary>OCR'ın harfle karıştırdığı rakamlar harfe çevrilir ("n0t" → "not").</summary>
    private static string FoldDigits(string word) => string.Create(word.Length, word, (span, source) =>
    {
        for (var i = 0; i < source.Length; i++)
            span[i] = source[i] switch { '0' => 'o', '1' => 'i', '3' => 'e', '4' => 'a', '5' => 's', '7' => 't', '8' => 'b', var c => c };
    });

    /// <summary>Levenshtein oranı (sözcük dizileri için).</summary>
    private static double Similarity(List<string> x, List<string> y)
    {
        if (x.Count == 0 || y.Count == 0) return x.Count == 0 && y.Count == 0 ? 1 : 0;
        var previous = new int[y.Count + 1];
        var row = new int[y.Count + 1];
        for (var j = 0; j <= y.Count; j++) previous[j] = j;
        for (var i = 1; i <= x.Count; i++)
        {
            row[0] = i;
            for (var j = 1; j <= y.Count; j++)
                row[j] = Math.Min(Math.Min(previous[j] + 1, row[j - 1] + 1), previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1));
            (previous, row) = (row, previous);
        }
        return 1 - (double)previous[y.Count] / Math.Max(x.Count, y.Count);
    }

    /// <summary><paramref name="newText"/>, <paramref name="oldText"/>'in sonuna sözcük eklenmiş hali mi (daktilo efekti; satırın başı okunmamışsa başına eklenmiş hali).</summary>
    public static bool IsGrowth(string newText, string oldText)
    {
        var x = Normalize(newText).Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        var y = Normalize(oldText).Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (y.Count == 0 || x.Count <= y.Count) return false;
        return StartsWith(x, y) || (y.Count >= 2 && EndsWith(x, y));
    }

    /// <summary>Gevşek uzamada eski okumanın en az bu kadar harfi olmalı; kısa satırda bir harf bile anlamı değiştirir.</summary>
    internal const int LooseGrowthLetters = 12;

    /// <summary>
    /// <paramref name="newText"/>, <paramref name="oldText"/>'in uzamış hali mi; eski okumanın sözcükleri yazı tanıma farkıyla
    /// başka okunmuş olabilir. Uzun satır aşama aşama belirir (daktilo efekti) ya da iki satırlık altyazının önce ilk satırı
    /// okunur; her okumada bir iki harf başka çıkınca ("Enzo" / "Enz0", "family" / "farnily") <see cref="IsGrowth"/> sözcük
    /// sözcük eşleşmeyi bulamıyor, yarım okumanın çevirisi tamamının çevirisiyle üst üste duruyor, sırada bekleyen yarım
    /// okumalar da tek tek çevrilip gecikme birikiyordu (beta-104, Mafia: The Old Country). Boşluksuz harf dizisinde eski
    /// okuma yenisinin başına (satırın başı okunmamışsa sonuna) %85 benziyorsa uzamadır. Mac/iPhone (isLooseGrowth) ve
    /// Android (isLooseGrowth) aynı kuralı uygular.
    /// </summary>
    public static bool IsLooseGrowth(string newText, string oldText)
    {
        if (IsGrowth(newText, oldText)) return true;
        var x = Normalize(newText).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var y = Normalize(oldText).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (y.Length < 3 || x.Length < y.Length) return false;
        var a = string.Concat(x);
        var b = string.Concat(y);
        if (b.Length < LooseGrowthLetters || a.Length < b.Length + 3) return false;
        return IsSimilar(a[..b.Length], b, 0.85) || IsSimilar(a[^b.Length..], b, 0.85);
    }

    /// <summary>Uzun satır sayılan okumanın en az harf sayısı (<see cref="IsJitterOf"/>).</summary>
    internal const int JitterLetters = 30;

    /// <summary>
    /// <paramref name="reread"/>, <paramref name="shown"/>'ın yalnız yazı tanıma farkıyla başka okunmuş hali mi (uzun satır):
    /// bir iki harf başka ("Enz0", "y0u"), sonuna çöp parça eklenmiş ("quietly. Il"), sondan ya da baştan kesilmiş ya da
    /// arada bir sözcüğü düşmüş okuma. Böyle okuma motora yeniden gitmez; ekrandaki (ya da beklenen) çevirisi kalır. Anlam
    /// işareti (olumsuzluk, sayı) ekleyen ya da düşüren, gerçek sözcükle uzayan ve bozuk sözcüğü onaran okuma
    /// (SubtitleStabilizer düzeltmesi, #854) farklıdır, yeniden çevrilir. Kısa satırda tek harf anlamı değiştirdiği için
    /// yalnız uzun satırlarda (<see cref="JitterLetters"/>) geçerlidir. Mac/iPhone (isJitter) ve Android (isJitterOf) aynı.
    /// </summary>
    public static bool IsJitterOf(string reread, string shown)
    {
        var x = Normalize(reread).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var y = Normalize(shown).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var a = string.Concat(x);
        var b = string.Concat(y);
        if (Math.Min(a.Length, b.Length) < JitterLetters) return false;
        if (AddsMeaning(reread, shown) || AddsMeaning(shown, reread)) return false;
        if (x.Length == y.Length) return IsSimilar(a, b, 0.9) && !SubtitleStabilizer.RepairsWords(x, y);
        // Cümle ortasında kesilen okuma (satırın bir bölümü okunamadı): gösterilen tamamı kalır. Cümle sonuyla biten kısa
        // okuma ("Huh? Jumping out of airplanes?") aynı sözlerle başlayan ayrı bir söz olabilir; ona dokunulmaz.
        if (x.Length < y.Length)
            return !SubtitleStabilizer.EndsSentence(reread) && (IsLooseGrowth(shown, reread) || IsSimilar(a, b, 0.9));
        // Uzayan okuma ancak eklenen parçalar çöpse aynı satırdır; gerçek sözcükle uzayan satır yeniden çevrilir.
        var prefix = x.Take(y.Length).SequenceEqual(y);
        var suffix = x.Skip(x.Length - y.Length).SequenceEqual(y);
        if (prefix || suffix) return (prefix ? x.Skip(y.Length) : x.Take(x.Length - y.Length)).All(IsJunkToken);
        return IsSimilar(a, b, 0.9) && x.Count(word => !IsJunkToken(word)) <= y.Length;
    }

    /// <summary>Yazı tanımanın uydurduğu parça: bilinen kısa sözcük olmayan 1–2 harf ya da sözcük olamayacak harf dizisi.</summary>
    internal static bool IsJunkToken(string word) =>
        (word.Length <= 2 && !SubtitleStabilizer.IsShortWord(word)) || OcrNoise.IsNonWord(word);

    private static bool StartsWith(List<string> words, List<string> part) => words.Take(part.Count).SequenceEqual(part);

    private static bool EndsWith(List<string> words, List<string> part) => words.Skip(words.Count - part.Count).SequenceEqual(part);

    /// <summary>Baştan (ya da sondan) <paramref name="count"/> sözcük tam satırlara denk geliyor mu.</summary>
    private static bool IsWholeRows(int count, string[] rows, bool fromStart)
    {
        var total = 0;
        foreach (var row in fromStart ? rows : Enumerable.Reverse(rows))
        {
            total += CleanWords(row).Count;
            if (total == count) return true;
            if (total > count) return false;
        }
        return false;
    }

    // Tek harfler ("a", "I" ya da OCR'ın uydurduğu "O") karşılaştırmaya bir şey katmaz.
    private static List<string> CleanWords(string normalized) =>
        normalized.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => w.Length > 1 && !w.Any(char.IsNumber)).ToList();

    private static bool IsAlphanumeric(char c) => char.GetUnicodeCategory(c) switch
    {
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
            or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
            or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark
            or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber => true,
        _ => false,
    };
}
