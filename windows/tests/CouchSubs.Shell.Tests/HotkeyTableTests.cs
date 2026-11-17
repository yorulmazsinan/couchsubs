// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Shell;

namespace CouchSubs.Shell.Tests;

public class HotkeyTableTests
{
    /// Sayı tuş takımı olmayan dizüstünde de her iş yapılabilsin: her işin bir Num tuşu ve bir Ctrl+Shift+rakam tuşu var.
    [Fact]
    public void EveryActionHasNumpadAndCtrlShiftKey()
    {
        foreach (var action in Enum.GetValues<HotkeyAction>())
        {
            var keys = HotkeyTable.Bindings.Where(binding => binding.Action == action).ToList();
            Assert.Equal(2, keys.Count);
            Assert.Single(keys, binding => binding.Modifiers == HotkeyModifiers.None);
            Assert.Single(keys, binding => binding.Modifiers == (HotkeyModifiers.Control | HotkeyModifiers.Shift));
        }
    }

    /// Num 9 ile Ctrl+Shift+9 aynı işi yapar (ekranı çevir); diğer rakamlar da öyle.
    [Theory]
    [InlineData(HotkeyAction.PauseSubtitles, 0)]
    [InlineData(HotkeyAction.ExtraRegion1, 1)]
    [InlineData(HotkeyAction.ExtraRegion2, 2)]
    [InlineData(HotkeyAction.ExtraRegion3, 3)]
    [InlineData(HotkeyAction.FreeArea, 5)]
    [InlineData(HotkeyAction.ClickThrough, 7)]
    [InlineData(HotkeyAction.Snapshot, 8)]
    [InlineData(HotkeyAction.Screen, 9)]
    public void NumpadAndTopRowDigitDoTheSameThing(HotkeyAction action, int digit)
    {
        var numpad = HotkeyTable.Bindings.Single(b => b.Modifiers == HotkeyModifiers.None && b.VirtualKey == 0x60u + (uint)digit);
        var combo = HotkeyTable.Bindings.Single(b => b.Modifiers != HotkeyModifiers.None && b.VirtualKey == 0x30u + (uint)digit);
        Assert.Equal(action, numpad.Action);
        Assert.Equal(action, combo.Action);
        Assert.Equal($"Num {digit}", numpad.Label);
        Assert.Equal($"Ctrl+Shift+{digit}", combo.Label);
    }

    [Fact]
    public void NoKeyIsRegisteredTwice() =>
        Assert.Equal(HotkeyTable.Bindings.Count, HotkeyTable.Bindings.Select(b => (b.Modifiers, b.VirtualKey)).Distinct().Count());

    /// Ctrl+Alt, Türkçe Q klavyede AltGr'dir (AltGr+3 = #, AltGr+7 = {); kısayol bu karakterleri yutmasın.
    /// Win tuşu da kullanılmaz (Win+rakam görev çubuğundaki uygulamaları açar).
    [Fact]
    public void CombosDoNotSwallowAltGrCharacters()
    {
        Assert.DoesNotContain(HotkeyTable.Bindings, b => b.Modifiers.HasFlag(HotkeyModifiers.Control) && b.Modifiers.HasFlag(HotkeyModifiers.Alt));
        Assert.All(HotkeyTable.Bindings, b => Assert.True(b.Modifiers is HotkeyModifiers.None or (HotkeyModifiers.Control | HotkeyModifiers.Shift)));
    }

    /// Kısayol kimliği sıradan gelir: Num tuşlarının kimlikleri eskisi gibi kalır, yenileri arkadan eklenir.
    [Fact]
    public void NumpadKeysComeFirst() =>
        Assert.All(HotkeyTable.Bindings.Take(HotkeyTable.Digits.Count), b => Assert.Equal(HotkeyModifiers.None, b.Modifiers));

    /// Eski ayar dosyası (kısayol seçimi yok) varsayılan tabloyla açılır.
    [Fact]
    public void NoChoicesMeansDefaults() => Assert.Equal(HotkeyTable.Bindings, HotkeyTable.Resolve([]));

    /// Ekranı çevir için Num 9 yerine Alt+F2: Ctrl+Shift+9 kalır, Num 9 artık hiçbir işi yapmaz.
    [Fact]
    public void ChangedKeyReplacesOnlyThatSlot()
    {
        var altF2 = new HotkeyKey(HotkeyModifiers.Alt, 0x71);
        var choices = HotkeyTable.Assign([], HotkeyAction.Screen, 0, altF2, out var displaced);
        Assert.Null(displaced);
        Assert.Equal([altF2, new HotkeyKey(HotkeyTable.ComboModifiers, 0x39)], HotkeyTable.KeysFor(choices, HotkeyAction.Screen));
        Assert.DoesNotContain(HotkeyTable.Resolve(choices), b => b.Modifiers == HotkeyModifiers.None && b.VirtualKey == 0x69);
        Assert.Equal("Alt+F2", HotkeyTable.Resolve(choices).Single(b => b.VirtualKey == 0x71).Label);
    }

    /// Başka işin tuşu seçilirse o işten kaldırılır; iki iş aynı tuşu tutmaz.
    [Fact]
    public void TakenKeyMovesFromOtherAction()
    {
        var num5 = new HotkeyKey(HotkeyModifiers.None, 0x65);
        var choices = HotkeyTable.Assign([], HotkeyAction.Screen, 0, num5, out var displaced);
        Assert.Equal(HotkeyAction.FreeArea, displaced);
        Assert.Equal(HotkeyAction.Screen, HotkeyTable.Resolve(choices).Single(b => b.VirtualKey == 0x65).Action);
        Assert.Null(HotkeyTable.KeyFor(choices, HotkeyAction.FreeArea, 0));
        Assert.Equal([new HotkeyKey(HotkeyTable.ComboModifiers, 0x35)], HotkeyTable.KeysFor(choices, HotkeyAction.FreeArea));
    }

    /// Kısayol kapatılabilir; varsayılana dönen yuva ayar dosyasında yer kaplamaz.
    [Fact]
    public void ClearingAndRestoringKeys()
    {
        var cleared = HotkeyTable.Assign([], HotkeyAction.ClickThrough, 1, null, out _);
        Assert.Single(HotkeyTable.KeysFor(cleared, HotkeyAction.ClickThrough));
        var restored = HotkeyTable.Assign(cleared, HotkeyAction.ClickThrough, 1, HotkeyTable.DefaultKey(HotkeyAction.ClickThrough, 1), out _);
        Assert.Empty(restored);
    }

    /// Ayar dosyası elle bozulsa da (aynı tuş iki işte, geçersiz tuş) tutulan tabloda çakışma olmaz.
    [Fact]
    public void ResolveSkipsDuplicateAndInvalidChoices()
    {
        HotkeyChoice[] choices =
        [
            new(HotkeyAction.Screen, 1, new HotkeyKey(HotkeyModifiers.None, 0x41)),
            new(HotkeyAction.FreeArea, 1, new HotkeyKey(HotkeyModifiers.None, 0x69)),
        ];
        var bindings = HotkeyTable.Resolve(choices);
        Assert.Equal(bindings.Count, bindings.Select(b => (b.Modifiers, b.VirtualKey)).Distinct().Count());
        Assert.DoesNotContain(bindings, b => b.VirtualKey == 0x41);
        Assert.Equal(HotkeyAction.Screen, bindings.Single(b => b.VirtualKey == 0x69).Action);
    }

    [Theory]
    [InlineData(HotkeyModifiers.None, 0x69u, HotkeyProblem.None)]          // Num 9
    [InlineData(HotkeyModifiers.None, 0x71u, HotkeyProblem.None)]          // F2
    [InlineData(HotkeyModifiers.None, 0x7Bu, HotkeyProblem.UnsupportedKey)] // F12 hata ayıklayıcıya ayrılmış
    [InlineData(HotkeyModifiers.None, 0x1Bu, HotkeyProblem.UnsupportedKey)] // Esc
    [InlineData(HotkeyModifiers.None, 0x54u, HotkeyProblem.NeedsModifier)]  // T
    [InlineData(HotkeyModifiers.Shift, 0x54u, HotkeyProblem.NeedsModifier)] // Shift+T büyük harf yazar
    [InlineData(HotkeyModifiers.Control, 0x43u, HotkeyProblem.NeedsModifier)] // Ctrl+C kopyalar
    [InlineData(HotkeyModifiers.Alt, 0x54u, HotkeyProblem.None)]            // Alt+T
    [InlineData(HotkeyModifiers.Alt | HotkeyModifiers.Shift, 0x54u, HotkeyProblem.None)]
    [InlineData(HotkeyModifiers.Control | HotkeyModifiers.Shift, 0x54u, HotkeyProblem.None)]
    [InlineData(HotkeyModifiers.Control | HotkeyModifiers.Alt, 0x33u, HotkeyProblem.AltGr)] // AltGr+3 = #
    [InlineData(HotkeyModifiers.Alt, 0x73u, HotkeyProblem.Reserved)]       // Alt+F4
    public void Validation(HotkeyModifiers modifiers, uint vk, HotkeyProblem expected) =>
        Assert.Equal(expected, HotkeyTable.Validate(new HotkeyKey(modifiers, vk)));

    /// Varsayılan tuşların hepsi kendi kuralından geçer.
    [Fact]
    public void DefaultsAreValid() =>
        Assert.All(HotkeyTable.Bindings, b => Assert.Equal(HotkeyProblem.None, HotkeyTable.Validate(new HotkeyKey(b.Modifiers, b.VirtualKey))));

    /// Seçim ayar dosyasına yazılıp geri okunur (enumlar adla).
    [Fact]
    public void ChoicesSurviveSettingsFile()
    {
        var choices = HotkeyTable.Assign([], HotkeyAction.Screen, 0, new HotkeyKey(HotkeyModifiers.Alt | HotkeyModifiers.Shift, 0x53), out _);
        choices = HotkeyTable.Assign(choices, HotkeyAction.Screen, 1, null, out _);
        var json = System.Text.Json.JsonSerializer.Serialize(new UserSettings { Hotkeys = choices });
        Assert.Contains("\"Screen\"", json);
        var loaded = System.Text.Json.JsonSerializer.Deserialize<UserSettings>(json)!;
        Assert.Equal(HotkeyTable.Resolve(choices), HotkeyTable.Resolve(loaded.Hotkeys));
        Assert.Equal([new HotkeyKey(HotkeyModifiers.Alt | HotkeyModifiers.Shift, 0x53)], HotkeyTable.KeysFor(loaded.Hotkeys, HotkeyAction.Screen));
        Assert.Empty(System.Text.Json.JsonSerializer.Deserialize<UserSettings>("{}")!.Hotkeys);
    }
}
