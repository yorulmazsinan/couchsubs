// SPDX-License-Identifier: AGPL-3.0-only

using System.Text;

namespace CouchSubs.Core;

/// <summary>
/// Sözlük terimlerini DeepL'e "çevirme" etiketiyle gönderir (Mac: DeepLMarkup.swift, aynı kurallar). Terim Türkçesiyle
/// (<c>keep</c> adlarında kendisiyle) değiştirilip <c>&lt;x&gt;…&lt;/x&gt;</c> içine alınır; istek
/// <c>tag_handling: xml</c> ve <c>ignore_tags: ["x"]</c> ile gider, DeepL etiket içini değiştirmez. Etiketsiz
/// gönderilince DeepL "Soul began…" gibi cümlelerde adı sıradan sözcük gibi çeviriyor, ardından gelen sözcüğü de adın
/// parçası sanıyordu ("began" → "Pegan"; Phantom Blade Zero, 2026-11-13).
/// </summary>
public static class DeepLMarkup
{
    public const string Tag = "x";

    /// <summary>Sözlükte geçen terim varsa etiketli (XML'e kaçırılmış) metin, yoksa null.</summary>
    public static string? Wrap(string text, Glossary glossary)
    {
        var matches = glossary.Find(text);
        if (matches.Count == 0) return null;
        var result = new StringBuilder();
        var cursor = 0;
        foreach (var match in matches)
        {
            result.Append(Escape(text[cursor..match.Start]));
            result.Append('<').Append(Tag).Append('>').Append(Escape(match.Turkish)).Append("</").Append(Tag).Append('>');
            cursor = match.Start + match.Length;
        }
        result.Append(Escape(text[cursor..]));
        return result.ToString();
    }

    /// <summary>Etiketsiz gönderilen cümle de etiketli istekte XML olarak okunur; özel karakterleri kaçırılır.</summary>
    public static string Escape(string text) =>
        text.Replace("&", "&amp;", StringComparison.Ordinal).Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal);

    /// <summary>DeepL'in döndürdüğü etiketli çeviriden düz metin.</summary>
    public static string Unwrap(string text) =>
        text.Replace($"<{Tag}>", "", StringComparison.Ordinal).Replace($"</{Tag}>", "", StringComparison.Ordinal)
            .Replace("&lt;", "<", StringComparison.Ordinal).Replace("&gt;", ">", StringComparison.Ordinal)
            .Replace("&amp;", "&", StringComparison.Ordinal);

    /// <summary>Terim içeren satırın önbellek anahtarına sözlüğün izi girer; sözlük değişince yeniden çevrilir.</summary>
    public static string CacheKey(string text, Glossary glossary) =>
        glossary.Matches(text) ? glossary.Fingerprint + "\u001F" + text : text;
}
