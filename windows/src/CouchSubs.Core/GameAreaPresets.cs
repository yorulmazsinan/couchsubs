// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Oyuna göre hazır ek alanlar: tabloda satırı olan oyun oynanırken (ve kullanıcının kendi ek alanı yokken) bu alanlar
/// sürekli okunur, çevirileri kendi yerinde görünür. Yeni oyun tabloya bir satırdır. Alanlar çalışma anında eklenir,
/// ayarlara yazılmaz. Mac/iPhone (GameAreaPresets.swift) ve Android (GameAreaPresets.kt) aynı tabloyu kullanır.
/// Bölgeler gerçek GTA 6 ekranında doğrulanmadı; kullanıcı kendi ek alanını ekleyerek değiştirebilir.
/// </summary>
public static class GameAreaPresets
{
    /// <summary>GTA 6 telefonu açıkken çıkarılan alan (telefon okuyucusu aynı köşeyi okuyor).</summary>
    public const string PhoneId = "preset-phone";

    private static readonly Dictionary<string, IReadOnlyList<WatchedArea>> Table = new()
    {
        ["gta 6"] =
        [
            // Sol üstteki ipucu kutusu.
            new WatchedArea("preset-help", "Help", new CropRegion(0.02, 0.28, 0.01, 0.36)),
            // Sağ alttaki telefon mesajı kartı.
            new WatchedArea(PhoneId, "Messages", new CropRegion(0.45, 0.80, 0.72, 0.99)),
        ],
    };

    /// <summary>Oyunun hazır alanları; tabloda yoksa boş.</summary>
    public static IReadOnlyList<WatchedArea> Areas(string? game) =>
        Table.TryGetValue(GameName.Key(game), out var areas) ? areas : [];
}
