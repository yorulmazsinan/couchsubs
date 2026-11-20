// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.RegularExpressions;
using CouchSubs.Core.Dubbing;

namespace CouchSubs.Core;

/// <summary>
/// Altyazının başındaki konuşan adı ("ARTHUR: We need to go.", "Dutch：Easy."). Ad çeviriye gitmez: motorlar adı
/// çeviriyor ya da cümlenin içine katıyordu, paket anahtarı da çoğu zaman adsız tutuluyor. Hat önce adlı satırı, sonra
/// adsız cümleyi pakette arar; motora yalnız cümle gider, ad gösterirken geri eklenir ya da (ayar kapalıysa) atılır.
/// Mac/iPhone (SpeakerPrefix.swift) ve Android (SpeakerPrefix.kt) aynı kuralları uygular.
/// </summary>
public static partial class SpeakerPrefix
{
    public sealed record Split(string Name, string Body);

    public const int MaxNameLength = 24;

    /// <summary>En çok üç sözcük, her sözcük büyük harfle başlar (BÜYÜK HARF ya da Baş Harf Büyük), rakam yok; ardından ":" ya da "：".</summary>
    [GeneratedRegex(@"^(\p{Lu}[\p{L}'’.\-]*(?: \p{Lu}[\p{L}'’.\-]*){0,2}) ?[:：]\s*")]
    private static partial Regex Pattern();

    /// <summary>Büyük harfle başlayıp iki noktayla biten ama ad olmayan oyun başlıkları (SubtitleSegmenter ile aynı).</summary>
    private static readonly HashSet<string> NotNames =
    [
        "note", "warning", "tip", "hint", "objective", "objectives", "quest", "goal", "new", "reward", "rewards",
        "location", "chapter", "mission", "task", "tutorial", "update", "info", "status", "level", "controls",
        "press", "hold", "tap", "remember", "example", "question", "answer", "result", "results", "time",
        "listen", "look", "wait", "okay", "ok", "well", "so", "yes", "no", "now", "then", "and", "but",
        // Türkçe başlıklar (çevirinin kendisi ya da Türkçe oyun): "Hedef: Arabaya bin." konuşan değildir.
        "hedef", "görev", "not", "ipucu", "uyarı", "bilgi", "ödül", "konum", "bölüm", "durum", "soru", "cevap",
    ];

    /// <summary>Baştaki konuşan adı ve cümle; ad yoksa (saat "10:30", adres "https://", oran "16:9", "Note:" gibi başlıklar) null.</summary>
    public static Split? Parse(string text)
    {
        var trimmed = text.Trim();
        var match = Pattern().Match(trimmed);
        if (!match.Success) return null;
        var name = match.Groups[1].Value;
        var body = trimmed[match.Length..].Trim();
        if (name.Length > MaxNameLength) return null;
        // "İpucu": büyük noktalı İ, sistem dilinden bağımsız küçük i sayılır.
        if (!name.Contains(' ') && NotNames.Contains(name.Replace('İ', 'i').ToLowerInvariant())) return null;
        if (!body.Any(char.IsLetter) || body.StartsWith('/')) return null;
        return new Split(name, body);
    }

    /// <summary>
    /// Gösterilecek metin: çeviri <paramref name="source"/>'un baştaki adıyla başlar ("ARTHUR: Gitmeliyiz.");
    /// <paramref name="show"/> kapalıysa İngilizcede konuşan adı olan satır başları atılır, yalnız Türkçe cümle kalır
    /// ("Hedef: …" gibi Türkçe başlık kalır).
    /// </summary>
    public static string Present(string translation, string source, bool show)
    {
        var text = translation;
        if (Parse(source) is { } prefix && Parse(text)?.Name != prefix.Name) text = $"{prefix.Name}: {text}";
        if (show) return text;
        var names = source.Split('\n').Append(source).Select(line => Parse(line)?.Name).OfType<string>().ToHashSet();
        return string.Join("\n", text.Split('\n').Select(line => Parse(line) is { } found && names.Contains(found.Name) ? found.Body : line));
    }

    /// <summary>Cümlenin seslendirme satırları adı taşımıyorsa konuşan, baştaki addır.</summary>
    public static IReadOnlyList<SpokenLine> Voiced(IReadOnlyList<SpokenLine> lines, Split? prefix)
    {
        if (prefix is null) return lines;
        var result = lines.ToList();
        for (var index = 0; index < result.Count; index++)
        {
            if (result[index].Speaker is not null || (index > 0 && result[index].NewTurn)) break;
            result[index] = result[index] with { Speaker = prefix.Name };
        }
        return result;
    }
}
