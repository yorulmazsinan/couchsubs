// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// Bilgisayar ekranındaki pencere TV uygulamasıyla (tv-webos/app.js) aynı satırları aynı sürelerle göstermeli (Mac ile aynı testler).
public class SubtitleStackTests
{
    private static List<string> Texts(SubtitleStack stack, double now) => [.. stack.Lines(now).Select(l => l.Text)];

    [Fact]
    public void LineStaysForGivenDuration()
    {
        var stack = new SubtitleStack();
        stack.Show("Kapıyı aç.", 4000, false, 0);
        Assert.Equal(["Kapıyı aç."], Texts(stack, 3.9));
        Assert.True(stack.IsEmpty(4));
    }

    [Fact]
    public void VeryShortDurationStillShowsMinimumTime()
    {
        var stack = new SubtitleStack();
        stack.Show("Evet.", 100, false, 0);
        Assert.False(stack.IsEmpty(1.1));
        Assert.True(stack.IsEmpty(1.2));
    }

    [Fact]
    public void MissingDurationComesFromLength()
    {
        var stack = new SubtitleStack();
        stack.Show("Evet.", 0, false, 0);
        // 2 sn + 5 harf × 60 ms
        Assert.False(stack.IsEmpty(2.29));
        Assert.True(stack.IsEmpty(2.31));
    }

    [Fact]
    public void FastSpeechStacksUpToThreeLines()
    {
        var stack = new SubtitleStack();
        stack.Show("Birinci", 8000, false, 0);
        stack.Show("İkinci", 8000, false, 0.5);
        stack.Show("Üçüncü", 8000, false, 1);
        var lines = stack.Lines(1);
        Assert.Equal(["Birinci", "İkinci", "Üçüncü"], lines.Select(l => l.Text));
        Assert.Equal([SubtitleStack.Role.Older, SubtitleStack.Role.Previous, SubtitleStack.Role.Current], lines.Select(l => l.Role));
        // Dördüncü satır en eskiyi düşürür.
        stack.Show("Dördüncü", 8000, false, 1.5);
        Assert.Equal(["İkinci", "Üçüncü", "Dördüncü"], Texts(stack, 1.5));
    }

    [Fact]
    public void SlowSpeechReplacesTheLine()
    {
        var stack = new SubtitleStack();
        stack.Show("Birinci", 8000, false, 0);
        stack.Show("İkinci", 8000, false, 2);
        Assert.Equal(["İkinci"], Texts(stack, 2));
    }

    [Fact]
    public void PreviousLineFadesThenGoes()
    {
        var stack = new SubtitleStack();
        stack.Show("Birinci", 8000, false, 0);
        stack.Show("İkinci", 8000, false, 1);
        Assert.False(stack.Lines(2.4)[0].Fading);
        Assert.True(stack.Lines(2.6)[0].Fading);
        Assert.Equal(["İkinci"], Texts(stack, 2.9));
        Assert.Equal(2.5, stack.NextChange(1));
        Assert.Equal(2.9, stack.NextChange(2.5));
        Assert.Equal(9, stack.NextChange(2.9));
    }

    [Fact]
    public void SameSentenceReadAgainDoesNotStack()
    {
        var stack = new SubtitleStack();
        stack.Show("Kapı", 8000, false, 0);
        stack.Show("Kapı daha fazla açılmıyor.", 8000, false, 0.5);
        Assert.Equal(["Kapı daha fazla açılmıyor."], Texts(stack, 0.5));
    }

    /// Bilgisayar "yerine koy" dediyse (aynı cümlenin uzamış okuması) önceki çeviri üste çıkmaz; Türkçeleri birbirini
    /// içermese de. Üstteki daha eski satır yerinde kalır.
    [Fact]
    public void RevisedLineReplacesInsteadOfStacking()
    {
        var stack = new SubtitleStack();
        stack.Show("Birinci", 8000, false, 0);
        stack.Show("Vaktimiz yok", 8000, false, 0.5);
        stack.Show("Bunun için vaktimiz yok, evlat.", 8000, false, 0.8, replaces: true);
        Assert.Equal(["Birinci", "Bunun için vaktimiz yok, evlat."], Texts(stack, 0.8));
    }

    [Fact]
    public void ParagraphsNeverStack()
    {
        var stack = new SubtitleStack();
        stack.Show("Birinci", 8000, false, 0);
        stack.Show("GÖREV\n• Kapıyı bul", 8000, true, 0.5);
        Assert.Equal(["GÖREV\n• Kapıyı bul"], Texts(stack, 0.5));
        Assert.True(stack.Lines(0.5)[0].Paragraphs);
    }

    /// "Temizle" satırı okunacak kadar görünmeden kaldırmaz.
    [Fact]
    public void ClearWaitsForReadingTime()
    {
        var stack = new SubtitleStack();
        stack.Show("Kapıyı aç.", 15000, false, 0);
        stack.Clear(1);
        // 2 sn + 10 harf × 60 ms = 2,6 sn
        Assert.False(stack.IsEmpty(2.5));
        Assert.True(stack.IsEmpty(2.61));
    }

    [Fact]
    public void ClearAfterReadingTimeHidesAtOnce()
    {
        var stack = new SubtitleStack();
        stack.Show("Birinci", 15000, false, 0);
        stack.Show("İkinci", 15000, false, 1);
        stack.Clear(4);
        Assert.True(stack.IsEmpty(4));
        Assert.Null(stack.NextChange(4));
    }

    [Fact]
    public void HideRemovesEverything()
    {
        var stack = new SubtitleStack();
        stack.Show("Birinci", 8000, false, 0);
        stack.Show("İkinci", 8000, false, 0.5);
        stack.Hide();
        Assert.True(stack.IsEmpty(0.5));
    }

    [Fact]
    public void SameLineIgnoresCaseAndPunctuation()
    {
        Assert.True(SubtitleStack.SameLine("Kapıyı aç!", "kapıyı aç."));
        Assert.True(SubtitleStack.SameLine("Kapı", "Kapı daha fazla…"));
        Assert.False(SubtitleStack.SameLine("Evet", "Hayır"));
    }
}
