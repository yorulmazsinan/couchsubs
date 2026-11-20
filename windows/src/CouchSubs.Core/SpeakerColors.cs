// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Konuşana göre renkli altyazı: "Mattia: …" satırında ad ve satır o konuşana özgü renkte görünür; aynı ad hep aynı
/// renktir. Renk addan hesaplanır (büyük/küçük harf fark etmez): FNV-1a (32 bit, UTF-16 birimleri) → 10 renklik palet.
/// Mac/iPhone (SpeakerColors.swift), Android (SpeakerColors.kt) ve TV uygulaması aynı paleti ve aynı hesabı kullanır.
/// TV'ye <c>subtitle</c> olayının <c>speakers</c> alanıyla gider (eski TV uygulaması alanı yok sayar).
/// </summary>
public static class SpeakerColors
{
    /// <summary>Koyu zeminde okunaklı, birbirinden ayrılan renkler (beyaz yok: renksiz satır beyazdır).</summary>
    public static readonly IReadOnlyList<string> Palette =
    [
        "#FFD54F", "#4FC3F7", "#81C784", "#FF8A65", "#CE93D8", "#F06292", "#4DD0E1", "#AED581", "#FFB74D", "#90CAF9",
    ];

    /// <summary>Adın rengi ("#RRGGBB").</summary>
    public static string Color(string name) => Palette[(int)(Hash(name.Trim().ToLowerInvariant()) % (uint)Palette.Count)];

    /// <summary>FNV-1a (32 bit), UTF-16 birimleri üzerinde.</summary>
    public static uint Hash(string key)
    {
        var hash = 2166136261u;
        foreach (var unit in key)
        {
            hash ^= unit;
            hash = unchecked(hash * 16777619u);
        }
        return hash;
    }

    /// <summary>Metnin satır başlarındaki konuşan adları (<see cref="SpeakerPrefix.Parse"/>), ilk görülme sırasıyla, tekrarsız.</summary>
    public static IReadOnlyList<string> Speakers(string text) =>
        [.. text.Split('\n').Select(line => SpeakerPrefix.Parse(line)?.Name).OfType<string>().Distinct()];

    /// <summary>Gösterilecek metnin bir parçası; <see cref="Color"/> null ise öntanımlı renkte.</summary>
    public readonly record struct Segment(string Text, string? Color);

    /// <summary>
    /// Bölünmüş (satırlara sarılmış) metni renkli parçalara ayırır: <paramref name="names"/>'ten biri satır başında
    /// "Ad:" ile başlıyorsa oradan bir sonraki adlı satıra dek o adın rengindedir. Ad yoksa tek renksiz parça döner.
    /// </summary>
    /// <param name="colorOf">Adın rengi (oturumun <see cref="SpeakerColorBook"/>'u); verilmezse <see cref="Color"/>.</param>
    public static IReadOnlyList<Segment> Segments(string text, IReadOnlyList<string> names, Func<string, string?>? colorOf = null)
    {
        if (names.Count == 0) return [new Segment(text, null)];
        var result = new List<Segment>();
        var start = 0;
        string? color = null;
        var lineStart = 0;
        while (lineStart <= text.Length)
        {
            var found = names.FirstOrDefault(name => StartsWithName(text, lineStart, name));
            if (found is not null)
            {
                if (lineStart > start) result.Add(new Segment(text[start..lineStart], color));
                start = lineStart;
                color = colorOf is null ? Color(found) : colorOf(found);
            }
            var next = text.IndexOf('\n', lineStart);
            if (next < 0) break;
            lineStart = next + 1;
        }
        if (start < text.Length) result.Add(new Segment(text[start..], color));
        return result;
    }

    private static bool StartsWithName(string text, int at, string name)
    {
        if (string.CompareOrdinal(text, at, name, 0, name.Length) != 0) return false;
        var rest = at + name.Length;
        if (rest < text.Length && text[rest] == ' ') rest++;
        return rest < text.Length && text[rest] is ':' or '：';
    }
}
