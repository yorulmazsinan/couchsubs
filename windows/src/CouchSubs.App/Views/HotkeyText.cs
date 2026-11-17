// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>Ekrandaki metinlerde kullanıcının seçtiği kısayollar ("Num 9 ya da Ctrl+Shift+9").</summary>
internal static class HotkeyText
{
    /// <summary>İşin çalışan tuşları, ör. "Num 9 ya da Ctrl+Shift+9"; hiç kısayolu yoksa null.</summary>
    public static string? Keys(UserSettings settings, HotkeyAction action)
    {
        var keys = HotkeyTable.KeysFor(settings.Hotkeys, action);
        return keys.Count switch
        {
            0 => null,
            1 => keys[0].Label,
            _ => Localizer.Current.Format("%@ or %@", keys[0].Label, keys[1].Label),
        };
    }

    /// <summary>Başlık: "Ekranı çevir (Num 9 ya da Ctrl+Shift+9)"; kısayol yoksa "(kısayol yok)".</summary>
    public static string Title(UserSettings settings, HotkeyAction action, string format) =>
        Localizer.Current.Format(format, Keys(settings, action) ?? Localizer.Current["no shortcut"]);

    /// <summary>"%@ kısayoluna basın …" cümlesi; kısayol yoksa nereden atanacağı söylenir.</summary>
    public static string Sentence(UserSettings settings, HotkeyAction action, string format) =>
        Keys(settings, action) is { } keys
            ? Localizer.Current.Format(format, keys)
            : Localizer.Current["No shortcut is set for this. You can set one under Keyboard shortcuts."];

    /// <summary>Ayarlar › Kısayollar'daki satır adı.</summary>
    public static string Name(HotkeyAction action) => Localizer.Current[action switch
    {
        HotkeyAction.Screen => "Translate the screen",
        HotkeyAction.FreeArea => "Free area",
        HotkeyAction.ExtraRegion1 => "Translate area 1",
        HotkeyAction.ExtraRegion2 => "Translate area 2",
        HotkeyAction.ExtraRegion3 => "Translate area 3",
        HotkeyAction.PauseSubtitles => "Pause or resume subtitles",
        HotkeyAction.ClickThrough => "Clicks pass through on or off",
        _ => "Refresh the picture in Settings",
    }];

    /// <summary>Ayarlar › Kısayollar'daki sıra: en çok kullanılandan aza.</summary>
    public static IReadOnlyList<HotkeyAction> Order { get; } =
    [
        HotkeyAction.Screen,
        HotkeyAction.FreeArea,
        HotkeyAction.ExtraRegion1,
        HotkeyAction.ExtraRegion2,
        HotkeyAction.ExtraRegion3,
        HotkeyAction.PauseSubtitles,
        HotkeyAction.ClickThrough,
        HotkeyAction.Snapshot,
    ];
}
