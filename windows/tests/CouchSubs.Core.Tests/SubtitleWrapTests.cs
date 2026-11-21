// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// Mac ile aynı kurallar (core/Tests/CouchSubsCoreTests/SubtitleWrapTests.swift).
public class SubtitleWrapTests
{
    /// <summary>Bilgisayardaki pencerede oyunda tek satır görünen altyazının çevirisi tek satırda kalır (66); telefonda 42.</summary>
    [Fact]
    public void Desktop_keeps_a_sixty_char_line_on_one_line()
    {
        const string text = "Evet, bazı yerlerin koruması daha fazla. İki taraf da kazandı.";
        Assert.Single(SubtitleWrap.FitChars(text, SubtitleWrap.DesktopMaxChars).Text.Split('\n'));
        Assert.Equal(2, SubtitleWrap.Fit(text).Text.Split('\n').Length);
    }

    [Fact]
    public void Short_text_is_untouched() =>
        Assert.Equal(new SubtitleWrap.Result("Gitmeliyiz, hemen.", 1), SubtitleWrap.Fit("Gitmeliyiz, hemen."));

    [Fact]
    public void Long_text_splits_into_two_balanced_lines()
    {
        var text = "Bu işin sonunda hepimiz için bir çıkış yolu bulmamız gerekiyor artık";
        var result = SubtitleWrap.Fit(text);
        var lines = result.Text.Split('\n');
        Assert.Equal(2, lines.Length);
        Assert.Equal(1, result.Scale);
        Assert.True(Math.Abs(lines[0].Length - lines[1].Length) <= 12);
        Assert.Equal(text, string.Join(' ', lines));
    }

    [Fact]
    public void Very_long_text_uses_at_most_three_lines_and_shrinks()
    {
        var result = SubtitleWrap.Fit(string.Join(' ', Enumerable.Repeat("kelime", 30)));
        Assert.Equal(3, result.Text.Split('\n').Length);
        Assert.InRange(result.Scale, SubtitleWrap.MinScale, 0.999);
    }

    [Fact]
    public void Speaker_name_stays_on_first_line_with_text()
    {
        var result = SubtitleWrap.Fit("ARTHUR: We need to leave before they find us here in the middle of the night, understand?");
        var first = result.Text.Split('\n')[0];
        Assert.StartsWith("ARTHUR: ", first);
        Assert.True(first.Length > "ARTHUR:".Length);
    }

    [Fact]
    public void Existing_breaks_and_paragraphs_are_kept()
    {
        var text = "Birinci satır uzun uzun uzun uzun\nİkinci satır da oldukça uzun bir satır";
        Assert.Equal(text, SubtitleWrap.Fit(text).Text);
        var line = new SubtitleStack.Line(1, string.Join(' ', Enumerable.Repeat("kelime", 20)), SubtitleStack.Role.Current, true, false);
        Assert.Equal(1, line.Wrapped.Scale);
        Assert.DoesNotContain('\n', line.Wrapped.Text);
    }
}
