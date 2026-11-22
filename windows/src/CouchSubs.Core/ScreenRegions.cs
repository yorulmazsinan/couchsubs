// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Bilgisayardaki altyazı ve yayın pencerelerinde "Ekranı çevir" çevirileri: özgün stiliyle gelen öğeler (bkz.
/// <see cref="ScreenTranslation.Styled"/>) otomatik ekran yazısı gibi stilli kutularda, ayrı bir ek alan olarak gösterilir
/// (telefon kartının balonları dahil, zemini hariç). Önceden hepsi altyazı kutusunda alt alta tek liste oluyordu.
/// </summary>
public static class ScreenRegions
{
    /// <summary>Pencerelerdeki ek alan kimliği (otomatik ekran yazısı "auto-…" değildir; saydam pencerede de görünür).</summary>
    public const string Id = "screen";

    /// <summary>Olayın stilli ek alanı; stil yoksa ya da ayrık gösterim kapalıysa null (eski liste gösterilir).</summary>
    public static (string Text, TextBox? Box, IReadOnlyList<ScreenTranslation.Item>? Blocks)? Styled(SubtitleEvent e, bool apart)
    {
        if (!apart || e.Kind != SubtitleEventKind.Screen || e.Blocks is not { } all) return null;
        var blocks = all.Where(item => !ScreenPhoneCard.IsBackdrop(item)).ToList();
        if (blocks.Count == 0 || !blocks.Any(item => item.Look is not null)) return null;
        var box = blocks.Select(item => item.Box).Aggregate((a, b) => a.Union(b));
        return (e.Text, box, blocks);
    }

    /// <summary>
    /// Pencerede gösterilecek alanlar: "Ekranı çevir" çevirileri ekrandayken, onların yerindeki otomatik ekran yazısı
    /// blokları çıkar (aynı yazı iki kez görünmesin, #827); bloğu kalmayan alan gösterilmez. Diğer alanlar olduğu gibi.
    /// </summary>
    public static IEnumerable<KeyValuePair<string, (string Text, TextBox? Box, IReadOnlyList<ScreenTranslation.Item>? Blocks)>> Visible(
        IReadOnlyDictionary<string, (string Text, TextBox? Box, IReadOnlyList<ScreenTranslation.Item>? Blocks)> regions)
    {
        var top = regions.TryGetValue(Id, out var screen) && screen.Blocks is { Count: > 0 } items ? items : null;
        foreach (var pair in regions)
        {
            if (top is null || pair.Key == Id || pair.Value.Blocks is not { Count: > 0 } blocks)
            {
                yield return pair;
                continue;
            }
            var left = ScreenTranslation.Uncovered(blocks, top);
            if (left.Count == 0) continue;
            yield return new(pair.Key, (pair.Value.Text, pair.Value.Box, left));
        }
    }

    /// <summary>Pencerenin bir sonraki değişim anı: yığınınki ya da stilli çevirilerin kalkışı, hangisi önceyse.</summary>
    public static double? NextChange(double? stack, double screenUntil) =>
        screenUntil <= 0 ? stack : stack is { } next ? Math.Min(next, screenUntil) : screenUntil;
}
