// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using CouchSubs.Core;

namespace CouchSubs.App.Services;

/// <summary>
/// Windows'un yazım denetleyicisi (ISpellCheckerFactory, Windows 8+; Office'in değil işletim sisteminin sözlüğü).
/// Paketli oyunlarda okumanın bozuk olup olmadığına karar vermek için: sözlükte olmayan küçük harfli sözcük
/// ("rnan", "anywjnere", "lirn") yazı tanımanın yanlış okumasıdır. Özel adlar (büyük harfle başlayan) ve oyunların
/// sokak ağzı ("gonna", "somethin'") yanlış sayılmaz.
/// </summary>
public static partial class WindowsSpellCheck
{
    private static readonly object Gate = new();
    private static ISpellChecker? checker;
    private static bool tried;

    private static readonly HashSet<string> Slang = new(StringComparer.OrdinalIgnoreCase)
    {
        "gonna", "wanna", "gotta", "kinda", "sorta", "lemme", "gimme", "ya", "yo", "nah", "yeah", "yep", "nope", "ain't",
        "homie", "homies", "y'all", "dunno", "outta", "lotta", "cuz", "'cause", "em", "'em", "huh", "uh", "um", "hmm", "mm",
        "ok", "okay", "whaddya", "c'mon", "ma'am", "bro", "dude", "fuckin", "motherfucker", "motherfuckers", "dumbass",
    };

    /// <summary>Okuma bozuk mu: yazım denetleyicisi yoksa yalnız <see cref="PackFuzzy"/>'nin OCR izi kuralı.</summary>
    public static bool LooksMisread(string text)
    {
        foreach (var line in text.Split('\n'))
        {
            var first = true;
            foreach (var match in WordPattern().Matches(line).Cast<Match>())
            {
                var word = match.Value.Trim('\'', '’');
                // Satırın ilk sözcüğü büyük harfle başladığı için özel ad sayılmaz, sözlükte aranır ("Arfgfit man").
                var ok = first && word.Length >= 2 ? IsWord(word.ToLowerInvariant()) || Known(word) : IsWord(word);
                if (!ok) return true;
                first = false;
            }
        }
        return false;
    }

    /// <summary>
    /// Okumanın sözlükçe puanı: sözlükte olan sözcüklerin harfleri artı, olmayanların ve çöp parçaların iki katı eksi.
    /// Aynı karenin farklı hazırlıklarla okunuşlarından ve aynı satırın art arda okunuşlarından en iyisini seçmek için
    /// (paketi olmayan oyunlar: GTA 6 gibi). Yarım okuma daha az sözcük taşıdığı için tam okumadan düşük puan alır.
    /// </summary>
    public static int Score(string text)
    {
        var score = 0;
        foreach (var line in text.Split('\n'))
        {
            var first = true;
            foreach (var token in line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            {
                score += TokenScore(token, first);
                first = false;
            }
        }
        return score;
    }

    private static int TokenScore(string token, bool lineStart)
    {
        {
            var core = token.Trim(Edge);
            if (core.Length == 0) return 0;
            var letters = core.Count(char.IsLetter);
            var clean = core.All(c => char.IsLetter(c) || c is '\'' or '’' or '-')
                        && core.All(c => c < 128 || c is '’')
                        && WordPattern().Matches(core).All(match =>
                        {
                            var word = match.Value.Trim('\'', '’');
                            // Satır başındaki büyük harfli sözcük özel ad sayılmaz, sözlükte aranır ("Hels" → bozuk).
                            return lineStart && match.Index == 0 && word.Length >= 2 ? Known(word.ToLowerInvariant()) || Known(word) || IsWord(word.ToLowerInvariant())
                                                                                    : IsWord(word);
                        });
            if (letters == 0) return core.Any(char.IsDigit) ? 0 : -2 * core.Length;  // "24" olağan, "•" çöp
            if (!clean) return -2 * Math.Max(letters, core.Length);
            // Sözlükte olmayıp yalnız büyük harfle başladığı için geçen sözcük (özel ad ya da "Dihnnr" gibi bozuk okuma)
            // ceza almaz ama puan da kazandırmaz; yoksa bozuk okuma doğrusundan yüksek puan alıyordu.
            var namesOnly = WordPattern().Matches(core).Any(match =>
            {
                var word = match.Value.Trim('\'', '’');
                return word.Length >= 2 && char.IsUpper(word[0]) && !IsDictionaryWord(word);
            });
            return namesOnly ? 0 : letters;
        }
    }

    private static readonly char[] Edge = ".,!?;:\"'“”‘’()[]…-—–".ToCharArray();

    private static IEnumerable<string> Words(string text) =>
        WordPattern().Matches(text).Select(match => match.Value.Trim('\'', '’'));

    /// <summary>Özel ad ayrıcalığı olmadan: sözlükte (ya da sokak ağzı listesinde) var mı.</summary>
    private static bool IsDictionaryWord(string word)
    {
        var lower = word.ToLowerInvariant();
        if (Slang.Contains(lower) || Known(word) || Known(lower)) return true;
        return lower.EndsWith("in", StringComparison.Ordinal) && (Slang.Contains(lower + "g") || Known(lower + "g"));
    }

    private static bool IsWord(string word)
    {
        if (word.Length < 2) return true;
        // Özel adlar ve bağırışlar ("Vinewood", "MICHAEL") sözlükte olmayabilir; yanlış okuma sayılmaz.
        if (char.IsUpper(word[0]) && (word.Skip(1).All(char.IsLower) || word.All(char.IsUpper))) return true;
        if (Slang.Contains(word) || word.EndsWith("in", StringComparison.Ordinal) && Slang.Contains(word + "g")) return true;
        if (word.EndsWith("in", StringComparison.Ordinal) && Known(word + "g")) return true; // "somethin'", "starin'"
        return Known(word);
    }

    private static readonly Dictionary<string, bool> Cache = new(StringComparer.Ordinal);

    private static bool Known(string word)
    {
        lock (Gate)
        {
            if (Cache.TryGetValue(word, out var cached)) return cached;
            var known = KnownUncached(word);
            if (Cache.Count > 20000) Cache.Clear();
            Cache[word] = known;
            return known;
        }
    }

    private static bool KnownUncached(string word)
    {
        lock (Gate)
        {
            if (!tried)
            {
                tried = true;
                try
                {
                    // Denetleyici MTA'da kurulur. Arayüz (STA) iş parçacığında kurulsaydı okuma iş parçacıklarından gelen her
                    // sorgu arayüz iş parçacığına sıralanır, arayüz bu kilidi beklerken kilitlenebilirdi.
                    checker = Thread.CurrentThread.GetApartmentState() == ApartmentState.STA
                        ? Task.Run(CreateChecker).GetAwaiter().GetResult()
                        : CreateChecker();
                }
                catch { checker = null; }
            }
            if (checker is null) return true;
            IEnumSpellingError? errors = null;
            object? error = null;
            try
            {
                errors = checker.Check(word);
                return errors.Next(out error) != 0;  // S_FALSE (1): hata yok
            }
            catch { return true; }
            finally
            {
                if (error is not null && Marshal.IsComObject(error)) Marshal.ReleaseComObject(error);
                if (errors is not null) Marshal.ReleaseComObject(errors);
            }
        }
    }

    /// <summary>en-US yazım denetleyicisi; dil yüklü değilse ya da Windows'ta yoksa null.</summary>
    private static ISpellChecker? CreateChecker()
    {
        var factory = (ISpellCheckerFactory)new SpellCheckerFactoryClass();
        return factory.IsSupported("en-US") != 0 ? factory.CreateSpellChecker("en-US") : null;
    }

    /// <summary>Yazım denetleyicisi bu bilgisayarda çalışıyor mu.</summary>
    public static bool Available
    {
        get { Known("hello"); lock (Gate) return checker is not null; }
    }

    [GeneratedRegex(@"[A-Za-z][A-Za-z'’]*")]
    private static partial Regex WordPattern();

    [ComImport, Guid("7AB36653-1796-484B-BDFA-E74F1DB7C1DC")]
    private class SpellCheckerFactoryClass { }

    [ComImport, Guid("8E018A9D-2415-4677-BF08-794EA61F94BB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISpellCheckerFactory
    {
        IntPtr SupportedLanguages { get; }
        int IsSupported([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
        ISpellChecker CreateSpellChecker([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
    }

    [ComImport, Guid("B6FD0B71-E2BC-4653-8D05-F197E412770B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISpellChecker
    {
        [return: MarshalAs(UnmanagedType.LPWStr)] string get_LanguageTag();
        IEnumSpellingError Check([MarshalAs(UnmanagedType.LPWStr)] string text);
    }

    [ComImport, Guid("803E3BD4-2828-4410-8290-418D1D73C762"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumSpellingError
    {
        [PreserveSig] int Next([MarshalAs(UnmanagedType.IUnknown)] out object? value);
    }
}
