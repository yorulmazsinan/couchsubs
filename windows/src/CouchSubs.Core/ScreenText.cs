// SPDX-License-Identifier: AGPL-3.0-only
namespace CouchSubs.Core;

/// <summary>
/// GTA'nın ekran yazısı: küçük harfi olmayan ve cümle sonu noktalamasıyla bitmeyen satır (silah adı
/// "LT W-22 SMALL GAME RIFLE", plaka "LN 5963 51", tabela "GREAT PRICES", mağaza menüsü "SKIP / REDRAW / CONFIRM").
/// GTA altyazısı büyük/küçük harflidir; "WHAT?" gibi noktalamayla biten satıra dokunulmaz. Konuşmaya yapışan ekran
/// yazısı yalnız o satırdan atılır, konuşma paketten bulunur. <see cref="ButtonPrompts.IsActionLabel"/> yalnız tek başına
/// okunan en çok üç sözcüklük etiketi tutuyordu; bu kural uzun ve yapışık olanları da kapsar.
/// Ölçüm (YouTube %100 oynanışlarından 156.683 okuma, bu zincirle): 26B/motora giden 16.312 → 12.662, paketten bulunan +656.
/// </summary>
public static class ScreenText
{
    /// <summary>Küçük harf yok, en az iki harf ve bir büyük harf var, cümle sonu noktalaması yok.</summary>
    public static bool IsScreenText(string line)
    {
        var t = line.Trim().TrimEnd('"', '\'', '”', '’', '»', ')', ']');
        return line.Count(char.IsLetter) >= 2 && line.Any(char.IsUpper) && !line.Any(char.IsLower)
            && !(t.Length > 0 && ".!?…".Contains(t[^1]));
    }

    /// <summary>Ekran yazısı satırları atılmış okuma.</summary>
    public static Reading WithoutScreenText(this Reading reading) =>
        new(reading.Lines.Where(line => !IsScreenText(line.Text)));

    /// <summary>Seçili oyun kuralın ölçüldüğü GTA oyunu mu.</summary>
    public static bool IsGta(string? game) =>
        game is { Length: > 0 } g && (g.Contains("Grand Theft Auto VI", StringComparison.OrdinalIgnoreCase)
            || g.Contains("GTA 6", StringComparison.OrdinalIgnoreCase) || g.Contains("GTA VI", StringComparison.OrdinalIgnoreCase));
}
