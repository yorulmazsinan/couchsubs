// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>"Örtsün"de yazı boyu sabit: en çok bir kademe küçülür, büyümez, zıplamaz (Mac: OverlayCoverTests).</summary>
public class CoverFontScaleTests
{
    private const string Short = "Çaldın mı?";
    private static readonly string Long = string.Concat(Enumerable.Repeat("Annenin arabası demiştin hani, unuttun mu yoksa? ", 4));

    [Fact]
    public void Font_stays_at_the_chosen_size_and_shrinks_one_step_at_most()
    {
        var font = new CoverFontScale();
        Assert.Equal(1, font.Scale(Short, 46));
        Assert.Equal(1, font.Scale("Bu cümle iki satıra bölünecek kadar uzun ama üç satıra rahat sığıyor.", 46));
        Assert.Equal(CoverFontScale.Step, font.Scale(Long, 46));
        // Sonraki kısa satırda geri büyümez; daha uzun satırda daha fazla küçülmez.
        Assert.Equal(CoverFontScale.Step, font.Scale(Short, 46));
        Assert.Equal(CoverFontScale.Step, font.Scale(Long + Long, 46));
        // Yazı boyu değişince kademe sıfırlanır.
        Assert.Equal(1, font.Scale(Short, 52));
    }

    [Fact]
    public void Wrap_at_a_fixed_scale_never_shrinks_further()
    {
        var wrapped = SubtitleWrap.Fit(string.Concat(Enumerable.Repeat(Long, 2)), CoverFontScale.Step);
        Assert.Equal(CoverFontScale.Step, wrapped.Scale);
        Assert.Equal(3, wrapped.Text.Split('\n').Length);
        Assert.Equal(new SubtitleWrap.Result(Short, 1), SubtitleWrap.Fit(Short, 1));
    }

    [Fact]
    public void Desktop_window_counts_three_lines_of_sixty_six_chars()
    {
        // 150 karakter: 3 x 42'ye sığmaz (TV/OBS bir kademe küçülür), 3 x 66'ya sığar (bilgisayar penceresi seçilen boyda kalır).
        var text = string.Concat(Enumerable.Repeat("Annenin arabası demiştin hani, unuttun mu yoksa? ", 3));
        Assert.Equal(CoverFontScale.Step, new CoverFontScale().Scale(text, 46));
        Assert.Equal(1, new CoverFontScale().Scale(text, 46, SubtitleWrap.DesktopMaxChars));
        var wrapped = SubtitleWrap.Fit(text, 1.0, SubtitleWrap.DesktopMaxChars);
        Assert.Equal(3, wrapped.Text.Split('\n').Length);
        Assert.All(wrapped.Text.Split('\n'), row => Assert.True(row.Length <= SubtitleWrap.DesktopMaxChars));
    }
}
