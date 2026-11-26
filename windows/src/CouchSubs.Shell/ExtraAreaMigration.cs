// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using System.Text.Json.Nodes;
using CouchSubs.Core;

namespace CouchSubs.Shell;

/// <summary>
/// Eski ayar dosyasındaki üç sabit ek bölge yuvasını (ExtraRegion1-3, ExtraLive1-3, ExtraTarget1-3) adlı ek alan
/// listesine (<see cref="UserSettings.ExtraAreas"/>) dönüştürür. Kayıp yoktur:
/// <list type="bullet">
/// <item>Bölgesi olan her yuva bir alan olur: yeri, "sürekli oku" seçimi ve sonucun gösterildiği yer aynen kalır. Kimliği
/// eskiden TV'deki kutunun kimliği olan "area1" … "area3"tür; adı boştur (ekranda "Bölge 1" gibi görünür).</item>
/// <item>Boş yuva (bölgesi yok) listeye girmez. Arkasındaki alanlar öne gelir; bu yüzden kısayollar da alanla birlikte
/// taşınır: eskiden Num 2 ile okunan alan 1. sıraya geçtiyse Num 2 yine onu okur.</item>
/// <item>Genel alanlar (oyun profili açıkken kenara alınanlar) ve her oyun profilinin alanları da aynı biçimde dönüşür.</item>
/// </list>
/// Dönüşmüş dosya bir sonraki kayıtta yeni biçimle yazılır; eski alanlar dosyadan kalkar.
/// </summary>
public static class ExtraAreaMigration
{
    private static readonly string[] LegacyKeys =
        [.. Enumerable.Range(1, 3).SelectMany(slot => new[] { $"ExtraRegion{slot}", $"ExtraLive{slot}", $"ExtraTarget{slot}" })];

    /// <summary>Ayar dosyasının metninden ayarlar; eski yuvalar listeye dönüşür.</summary>
    /// <exception cref="JsonException">Dosya JSON değilse.</exception>
    public static UserSettings Load(string json)
    {
        if (JsonNode.Parse(json) is not JsonObject root) return new UserSettings();
        var order = Upgrade(root);
        // Profil açıkken uygulama kapandıysa asıl (genel) alanlar GeneralAreas'tadır; açılışta onlar geri gelir, kısayollar
        // onların sırasına göre taşınır.
        if (root["GeneralAreas"] is JsonObject general) order = Upgrade(general) ?? order;
        if (root["AreaProfiles"] is JsonArray profiles)
            foreach (var profile in profiles)
                if (profile?["Areas"] is JsonObject areas) Upgrade(areas);
        var settings = root.Deserialize<UserSettings>() ?? new UserSettings();
        // Yalnız alanı henüz bulunmayan eski Remote Play kayıtları göç eder. Kullanıcının açıkça seçtiği false korunur.
        if (!root.ContainsKey(nameof(UserSettings.OverlayFollowSubtitle))
            && settings.FrameSource == FrameSource.RemotePlayWindow && settings.Style.Placement == SubtitlePlacement.Cover)
            settings = settings with { OverlayFollowSubtitle = true };
        return order is null ? settings : settings with { Hotkeys = HotkeyTable.MoveAreaKeys(settings.Hotkeys, order) };
    }

    /// <summary>
    /// Bir alan kümesindeki (ayarların kendisi ya da AreaSet) eski yuvaları ExtraAreas'a çevirir. Eski yuva yoksa null;
    /// varsa yeni sıradaki her alanın eski yuva numarası.
    /// </summary>
    internal static int[]? Upgrade(JsonObject areas)
    {
        if (!LegacyKeys.Any(areas.ContainsKey)) return null;
        var order = new List<int>();
        var list = new JsonArray();
        for (var slot = 1; slot <= 3; slot++)
        {
            if (areas[$"ExtraRegion{slot}"] is not JsonObject region) continue;
            order.Add(slot);
            list.Add(new JsonObject
            {
                ["Id"] = $"area{slot}",
                ["Name"] = "",
                ["Region"] = region.DeepClone(),
                ["Enabled"] = areas[$"ExtraLive{slot}"]?.DeepClone() ?? false,
                ["Target"] = areas[$"ExtraTarget{slot}"]?.DeepClone() ?? (int)ResultTarget.Tv,
            });
        }
        foreach (var key in LegacyKeys) areas.Remove(key);
        // Yeni biçimde yazılmış liste varsa o geçerlidir (eski alanlar yalnız artık kalmış olabilir).
        if (!areas.ContainsKey("ExtraAreas")) areas["ExtraAreas"] = list;
        else return null;
        return [.. order];
    }
}
