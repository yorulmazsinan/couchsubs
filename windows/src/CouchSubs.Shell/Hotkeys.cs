// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json.Serialization;

namespace CouchSubs.Shell;

/// <summary>
/// Genel kısayolların yaptığı iş. Her işin iki tuşu var; varsayılanlar Num tuşu ve sayı tuş takımı olmayan klavyeler
/// için Ctrl+Shift+rakamdır. Kullanıcı ikisini de Ayarlar › Kısayollar'da değiştirebilir (bkz. <see cref="HotkeyChoice"/>).
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<HotkeyAction>))]
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
[JsonConverter(typeof(JsonStringEnumConverter<HotkeyModifiers>))]
public enum HotkeyModifiers : uint
{
    None = 0,
    Alt = 0x0001,
    Control = 0x0002,
    Shift = 0x0004,
}

/// <param name="VirtualKey">Windows sanal tuş kodu (VK_*).</param>
/// <param name="Label">Ekranda ve günlükte görünen ad (ör. "Ctrl+Shift+9").</param>
public sealed record HotkeyBinding(HotkeyAction Action, HotkeyModifiers Modifiers, uint VirtualKey, string Label);

/// <summary>Bir tuş birleşimi: değiştiriciler ve Windows sanal tuş kodu.</summary>
public sealed record HotkeyKey(HotkeyModifiers Modifiers, uint VirtualKey)
{
    [JsonIgnore]
    public string Label => HotkeyTable.Label(this);
}

/// <summary>
/// Kullanıcının varsayılandan farklı seçtiği kısayol. <paramref name="Slot"/> 0 ya da 1 (her işin iki tuşu);
/// <paramref name="Key"/> null ise o tuş kapalıdır. Ayar dosyasında yalnız varsayılandan farklı olanlar durur; böylece
/// eski kayıtlar ve değiştirilmeyen tuşlar varsayılanla açılır.
/// </summary>
public sealed record HotkeyChoice(HotkeyAction Action, int Slot, HotkeyKey? Key);

/// <summary>Seçilen tuş neden kullanılamaz.</summary>
public enum HotkeyProblem
{
    None,
    /// <summary>Bu tuş kısayol olamaz (Esc, Sekme, harf dışı simgeler, F12 …).</summary>
    UnsupportedKey,
    /// <summary>Harf, rakam ve gezinme tuşları tek başına (ya da yalnız Shift/Ctrl ile) diğer uygulamalarda yazıyı bozar.</summary>
    NeedsModifier,
    /// <summary>Ctrl+Alt, Türkçe Q ve birçok Avrupa klavyesinde AltGr'dir; #, $, {, [ gibi karakterleri yazdırmaz.</summary>
    AltGr,
    /// <summary>Windows'un kendi işi var (Alt+F4).</summary>
    Reserved,
}

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
    /// <summary>Her işin kaç tuşu var (0: Num tuşu, 1: Ctrl+Shift+rakam).</summary>
    public const int SlotCount = 2;

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

    /// <summary>Varsayılan tablo: önce bütün Num tuşları, sonra Ctrl+Shift+rakam tuşları; sırası kısayol kimliğini belirler.</summary>
    public static IReadOnlyList<HotkeyBinding> Bindings { get; } = Resolve(null);

    /// <summary>İşin varsayılan tuşu: 0. yuva Num rakamı, 1. yuva Ctrl+Shift+rakam.</summary>
    public static HotkeyKey DefaultKey(HotkeyAction action, int slot)
    {
        var digit = (uint)Digits.Single(entry => entry.Action == action).Digit;
        return slot == 0 ? new HotkeyKey(HotkeyModifiers.None, NumPad0 + digit) : new HotkeyKey(ComboModifiers, Digit0 + digit);
    }

    /// <summary>Kullanıcının seçimine göre işin o yuvadaki tuşu; kapatıldıysa null.</summary>
    public static HotkeyKey? KeyFor(IReadOnlyList<HotkeyChoice>? choices, HotkeyAction action, int slot)
    {
        var choice = choices?.LastOrDefault(c => c.Action == action && c.Slot == slot);
        return choice is null ? DefaultKey(action, slot) : choice.Key;
    }

    /// <summary>
    /// Tutulacak kısayollar. Sıra varsayılan tablodaki gibidir (önce 0. yuvalar). Kapatılan, geçersiz (ayar dosyası elle
    /// değiştirildiyse) ya da başka bir işe zaten verilmiş tuşlar atlanır.
    /// </summary>
    public static IReadOnlyList<HotkeyBinding> Resolve(IReadOnlyList<HotkeyChoice>? choices)
    {
        var result = new List<HotkeyBinding>();
        var used = new HashSet<HotkeyKey>();
        for (var slot = 0; slot < SlotCount; slot++)
            foreach (var (action, _) in Digits)
            {
                if (KeyFor(choices, action, slot) is not { } key || Validate(key) != HotkeyProblem.None || !used.Add(key)) continue;
                result.Add(new HotkeyBinding(action, key.Modifiers, key.VirtualKey, key.Label));
            }
        return result;
    }

    /// <summary>İşin çalışan tuşları (kapatılanlar ve çakışanlar hariç), yuva sırasıyla.</summary>
    public static IReadOnlyList<HotkeyKey> KeysFor(IReadOnlyList<HotkeyChoice>? choices, HotkeyAction action) =>
        [.. Resolve(choices).Where(b => b.Action == action).Select(b => new HotkeyKey(b.Modifiers, b.VirtualKey))];

    /// <summary>
    /// İşin o yuvasına tuşu verir (null: kapatır). Tuş başka bir işte kullanılıyorsa oradan kaldırılır ve
    /// <paramref name="displaced"/> o iş olur. Dönen listede yalnız varsayılandan farklı yuvalar bulunur.
    /// </summary>
    public static IReadOnlyList<HotkeyChoice> Assign(IReadOnlyList<HotkeyChoice>? choices, HotkeyAction action, int slot, HotkeyKey? key, out HotkeyAction? displaced)
    {
        displaced = null;
        var keys = new Dictionary<(HotkeyAction, int), HotkeyKey?>();
        foreach (var (each, _) in Digits)
            for (var s = 0; s < SlotCount; s++)
                keys[(each, s)] = KeyFor(choices, each, s);
        keys[(action, slot)] = key;
        if (key is not null)
            foreach (var (other, s) in keys.Keys.ToList())
            {
                if ((other, s) == (action, slot) || keys[(other, s)] != key) continue;
                keys[(other, s)] = null;
                if (other != action) displaced = other;
            }
        return [.. keys.Where(entry => entry.Value != DefaultKey(entry.Key.Item1, entry.Key.Item2))
            .Select(entry => new HotkeyChoice(entry.Key.Item1, entry.Key.Item2, entry.Value))];
    }

    /// <summary>Tuş kısayol olabilir mi; olamıyorsa nedeni.</summary>
    public static HotkeyProblem Validate(HotkeyKey key)
    {
        if (KeyName(key.VirtualKey) is null) return HotkeyProblem.UnsupportedKey;
        if (key.Modifiers.HasFlag(HotkeyModifiers.Control) && key.Modifiers.HasFlag(HotkeyModifiers.Alt)) return HotkeyProblem.AltGr;
        if (key.VirtualKey == 0x73 && key.Modifiers.HasFlag(HotkeyModifiers.Alt)) return HotkeyProblem.Reserved;
        if (StandsAlone(key.VirtualKey)) return HotkeyProblem.None;
        // Harf, rakam, ok ve gezinme tuşları: yalnız Ctrl+Shift, Alt ya da Alt+Shift ile (Ctrl+harf kopyala/yapıştır gibi
        // işlerle, Shift+harf büyük harfle çakışır).
        return key.Modifiers is ComboModifiers or HotkeyModifiers.Alt or (HotkeyModifiers.Alt | HotkeyModifiers.Shift)
            ? HotkeyProblem.None
            : HotkeyProblem.NeedsModifier;
    }

    /// <summary>Tek başına da kısayol olabilen tuşlar: sayı tuş takımı, F1–F24 (F12 hariç), Pause, Scroll Lock.</summary>
    private static bool StandsAlone(uint vk) => vk is >= 0x60 and <= 0x6F or >= 0x70 and <= 0x87 or 0x13 or 0x91;

    /// <summary>Ekranda görünen ad (ör. "Ctrl+Shift+9", "Alt+F2", "Num 9").</summary>
    public static string Label(HotkeyKey key)
    {
        var parts = new List<string>();
        if (key.Modifiers.HasFlag(HotkeyModifiers.Control)) parts.Add("Ctrl");
        if (key.Modifiers.HasFlag(HotkeyModifiers.Alt)) parts.Add("Alt");
        if (key.Modifiers.HasFlag(HotkeyModifiers.Shift)) parts.Add("Shift");
        parts.Add(KeyName(key.VirtualKey) ?? $"0x{key.VirtualKey:X2}");
        return string.Join("+", parts);
    }

    /// <summary>Kısayol olabilen tuşun adı; olamıyorsa null.</summary>
    public static string? KeyName(uint vk) => vk switch
    {
        >= 0x30 and <= 0x39 => ((char)vk).ToString(),
        >= 0x41 and <= 0x5A => ((char)vk).ToString(),
        >= 0x60 and <= 0x69 => $"Num {vk - NumPad0}",
        0x6A => "Num *",
        0x6B => "Num +",
        0x6D => "Num -",
        0x6E => "Num .",
        0x6F => "Num /",
        // F12 hata ayıklayıcıya ayrılmıştır; RegisterHotKey onu tutmamalı.
        0x7B => null,
        >= 0x70 and <= 0x87 => $"F{vk - 0x6F}",
        0x13 => "Pause",
        0x91 => "Scroll Lock",
        0x2D => "Insert",
        0x24 => "Home",
        0x23 => "End",
        0x21 => "Page Up",
        0x22 => "Page Down",
        0x25 => "←",
        0x26 => "↑",
        0x27 => "→",
        0x28 => "↓",
        _ => null,
    };
}
