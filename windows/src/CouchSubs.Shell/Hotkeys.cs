// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell;

/// <summary>Genel kısayolların yaptığı iş. Her işin iki tuşu var: Num tuşu ve sayı tuş takımı olmayan klavyeler için Ctrl+Shift+rakam.</summary>
public enum HotkeyAction
{
    /// <summary>Num 1 / Ctrl+Shift+1: 1. ek bölgeyi bir kez çevir.</summary>
    ExtraRegion1,
    /// <summary>Num 2 / Ctrl+Shift+2: 2. ek bölgeyi bir kez çevir.</summary>
    ExtraRegion2,
    /// <summary>Num 3 / Ctrl+Shift+3: 3. ek bölgeyi bir kez çevir.</summary>
    ExtraRegion3,
    /// <summary>Num 5 / Ctrl+Shift+5: görüntüyü dondurup serbest alan seçtir.</summary>
    FreeArea,
    /// <summary>Num 8 / Ctrl+Shift+8: ayar ekranındaki görüntüyü oyunun şu anki görüntüsüyle yenile.</summary>
    Snapshot,
    /// <summary>Num 0 / Ctrl+Shift+0: canlı altyazı çevirisini duraklat / sürdür.</summary>
    PauseSubtitles,
    /// <summary>Num 9 / Ctrl+Shift+9: ekranın tamamını bir kez çevir; yeniden basınca çeviriler kalkar.</summary>
    Screen,
    /// <summary>Num 7 / Ctrl+Shift+7: bilgisayar ekranındaki altyazı penceresinde "Tıklamalar geçsin"i aç / kapat.</summary>
    ClickThrough,
}

/// <summary>RegisterHotKey'in değiştirici tuşları (değerler Win32 MOD_* ile aynı).</summary>
[Flags]
public enum HotkeyModifiers : uint
{
    None = 0,
    Alt = 0x0001,
    Control = 0x0002,
    Shift = 0x0004,
}

/// <param name="VirtualKey">Windows sanal tuş kodu (VK_*).</param>
/// <param name="Label">Günlükte görünen ad (ör. "Ctrl+Shift+9").</param>
public sealed record HotkeyBinding(HotkeyAction Action, HotkeyModifiers Modifiers, uint VirtualKey, string Label);

/// <summary>
/// Genel kısayol tablosu. Num tuşları (NumLock açıkken) dizüstü bilgisayarlarda yoksa aynı işler Ctrl+Shift ile üst
/// sıradaki rakamlarla da yapılır. Ctrl+Alt seçilmedi: Türkçe Q ve birçok Avrupa klavyesinde AltGr = Ctrl+Alt'tır ve
/// AltGr+rakam #, $, {, [, ], } gibi karakterleri yazar; Ctrl+Alt+rakam kısayolu bu karakterleri diğer uygulamalarda
/// yazdırmazdı. Ctrl+Shift+rakam karakter yazmaz ve Windows'ta varsayılan bir işi yoktur.
/// </summary>
public static class HotkeyTable
{
    public const uint NumPad0 = 0x60;
    public const uint Digit0 = 0x30;
    public const HotkeyModifiers ComboModifiers = HotkeyModifiers.Control | HotkeyModifiers.Shift;

    /// <summary>İşlerin rakamı: Num tuşu da Ctrl+Shift tuşu da bu rakamdır.</summary>
    public static IReadOnlyList<(HotkeyAction Action, int Digit)> Digits { get; } =
    [
        (HotkeyAction.ExtraRegion1, 1),
        (HotkeyAction.ExtraRegion2, 2),
        (HotkeyAction.ExtraRegion3, 3),
        (HotkeyAction.FreeArea, 5),
        (HotkeyAction.Snapshot, 8),
        (HotkeyAction.PauseSubtitles, 0),
        (HotkeyAction.Screen, 9),
        (HotkeyAction.ClickThrough, 7),
    ];

    /// <summary>Önce bütün Num tuşları, sonra Ctrl+Shift+rakam tuşları; sırası kısayol kimliğini belirler.</summary>
    public static IReadOnlyList<HotkeyBinding> Bindings { get; } =
    [
        .. Digits.Select(entry => new HotkeyBinding(entry.Action, HotkeyModifiers.None, NumPad0 + (uint)entry.Digit, $"Num {entry.Digit}")),
        .. Digits.Select(entry => new HotkeyBinding(entry.Action, ComboModifiers, Digit0 + (uint)entry.Digit, $"Ctrl+Shift+{entry.Digit}")),
    ];
}
