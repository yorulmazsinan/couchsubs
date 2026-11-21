// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;

namespace CouchSubs.Core;

/// <summary>
/// Uzun çevirinin ekranda tek uzun satır olarak sağa sola taşmaması: satır başına en çok <see cref="MaxChars"/> karakter,
/// en çok 3 satır, kelime sınırından ve dengeli bölünür. 3 satıra sığmayacak kadar uzunsa yazı biraz küçülür
/// (<c>Scale</c>, en çok <see cref="MinScale"/>'e kadar). Konuşan adı ("ARTHUR: ...") bölünmez, hep ilk satırdadır.
/// Mac/iPhone (SubtitleWrap.swift), Android (SubtitleWrap.kt), TV ve OBS sayfaları aynı kuralları uygular.
/// </summary>
public static class SubtitleWrap
{
    public const int MaxChars = 42;
    /// <summary>
    /// Bilgisayardaki altyazı ve yayın penceresinde (Windows, Mac) satır başına en çok karakter: oyunda tek satır görünen
    /// altyazının çevirisi de tek satırda kalır (oyundaki tek satırların %99'u en çok 66 karakter). Telefon ekranı dar
    /// olduğu için orada <see cref="MaxChars"/>.
    /// </summary>
    public const int DesktopMaxChars = 66;
    public const int MaxLines = 3;
    public const double MinScale = 0.75;

    public readonly record struct Result(string Text, double Scale);

    public static Result Fit(string text) => FitChars(text, MaxChars);

    /// <summary>Satır başına en çok <paramref name="maxChars"/> karakterle (bilgisayar penceresi: <see cref="DesktopMaxChars"/>).</summary>
    public static Result FitChars(string text, int maxChars)
    {
        var length = new StringInfo(text).LengthInTextElements;
        if (length <= maxChars || text.Contains('\n')) return new Result(text, 1);
        var words = Tokens(text);
        if (words.Count < 2) return new Result(text, 1);
        var scale = Math.Clamp((double)(maxChars * MaxLines) / length, MinScale, 1);
        var cap = (int)Math.Floor(maxChars / scale);
        var lines = Math.Min(MaxLines, Math.Max(2, (int)Math.Ceiling((double)length / cap)));
        return new Result(Balance(words, Math.Min(lines, words.Count)), scale);
    }

    /// <summary>
    /// Verilen sabit yazı boyu çarpanıyla bölme ("Örtsün", bkz. <see cref="CoverFontScale"/>): satır başına
    /// <c>MaxChars / scale</c> karakter, en çok 3 satır; daha uzun metinde satırlar uzar, yazı daha fazla küçülmez.
    /// </summary>
    public static Result Fit(string text, double scale) => Fit(text, scale, MaxChars);

    /// <summary>Sabit yazı boyu çarpanıyla, satır başına en çok <paramref name="maxChars"/> karakter tabanıyla (bilgisayar penceresi:
    /// <see cref="DesktopMaxChars"/>).</summary>
    public static Result Fit(string text, double scale, int maxChars)
    {
        scale = double.IsFinite(scale) && scale > 0 ? Math.Min(1, scale) : 1;
        var cap = (int)Math.Floor(Math.Max(1, maxChars) / scale);
        var length = new StringInfo(text).LengthInTextElements;
        if (length <= cap || text.Contains('\n')) return new Result(text, scale);
        var words = Tokens(text);
        if (words.Count < 2) return new Result(text, scale);
        var lines = Math.Min(MaxLines, Math.Max(2, (int)Math.Ceiling((double)length / cap)));
        return new Result(Balance(words, Math.Min(lines, words.Count)), scale);
    }

    /// <summary>Sözcükler; konuşan adı ("ARTHUR:") sonraki sözcükle birleşik tutulur, ad satır sonunda tek kalmaz.</summary>
    internal static List<string> Tokens(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
        for (var i = 0; i < Math.Min(3, words.Count); i++)
        {
            if (!words[i].EndsWith(':') && !words[i].EndsWith('：')) continue;
            if (i + 1 < words.Count)
            {
                var joined = string.Join(' ', words.Take(i + 2));
                words.RemoveRange(0, i + 2);
                words.Insert(0, joined);
            }
            break;
        }
        return words;
    }

    /// <summary>En uzun satırı en kısa yapan bölme; eşitlikte uzunlukların kareleri toplamı küçük olan seçilir.</summary>
    internal static string Balance(List<string> words, int lines)
    {
        var count = words.Count;
        int Width(int from, int to) => words.Skip(from).Take(to - from).Sum(w => w.Length) + (to - from - 1);
        int[]? best = null;
        (int Longest, int Spread) bestKey = (int.MaxValue, int.MaxValue);
        void Consider(params int[] cuts)
        {
            var edges = new[] { 0 }.Concat(cuts).Append(count).ToArray();
            var widths = Enumerable.Range(0, edges.Length - 1).Select(i => Width(edges[i], edges[i + 1])).ToArray();
            var key = (widths.Max(), widths.Sum(w => w * w));
            if (best is null || key.CompareTo(bestKey) < 0) { best = cuts; bestKey = key; }
        }
        if (lines == 2 || count < 3)
            for (var a = 1; a < count; a++) Consider(a);
        else
            for (var a = 1; a < count - 1; a++)
                for (var b = a + 1; b < count; b++) Consider(a, b);
        if (best is null) return string.Join(' ', words);
        var all = new[] { 0 }.Concat(best).Append(count).ToArray();
        return string.Join('\n', Enumerable.Range(0, all.Length - 1).Select(i => string.Join(' ', words.Skip(all[i]).Take(all[i + 1] - all[i]))));
    }
}
