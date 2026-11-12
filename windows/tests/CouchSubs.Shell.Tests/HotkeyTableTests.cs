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
}
