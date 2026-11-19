// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Alanda altyazının yanında menü, köşe göstergesi ve kumanda ipucu da okunur (Mac: SubtitleBlockTests).</summary>
public class SubtitleBlockTests
{
    private static readonly TextBox Area = new(0, 0.6, 1, 1);

    private static TextLine Line(string text, double left, double top, double right, double height = 0.07) =>
        new(text, new TextBox(left, top, right, top + height));

    [Fact]
    public void MenuAndCornerTextAreNotSubtitles()
    {
        string[] items = ["MAP", "HELP", "PROGRESS", "PLAYER", "STORY", "ONLINE", "SOCIAL CLUB", "SETTINGS"];
        var menu = items.Select((item, i) => Line(item, 0.05, 0.05 + (i * 0.1), 0.05 + (item.Length * 0.015)));
        var reading = new Reading([.. menu, Line("PHOTO MODE", 0.85, 0.9, 0.97)]);
        Assert.Empty(reading.SubtitleBlock(Area).Lines);
    }

    [Fact]
    public void CenteredSubtitleIsKeptWithoutCornerGauge()
    {
        var reading = new Reading([
            Line("We'll lose these tracks if we don't hurry.", 0.25, 0.7, 0.75),
            Line("9", 0.02, 0.7, 0.04),
            Line("PHOTO MODE", 0.85, 0.9, 0.97),
        ]);
        var block = reading.SubtitleBlock(Area);
        Assert.Equal("We'll lose these tracks if we don't hurry.", block.Text);
        Assert.Equal(new TextBox(0.25, 0.7, 0.75, 0.77), block.Box!.Value with { Bottom = Math.Round(block.Box!.Value.Bottom, 2) });
    }

    [Fact]
    public void TwoLineSubtitleStaysTogether()
    {
        var reading = new Reading([
            Line("Mac and John... they were both shot.", 0.3, 0.6, 0.7),
            Line("We need to move.", 0.4, 0.68, 0.6),
        ]);
        Assert.Equal("Mac and John... they were both shot.\nWe need to move.", reading.SubtitleBlock(Area).Text);
    }

    [Fact]
    public void LeftAlignedSentenceIsStillRead()
    {
        var reading = new Reading([Line("Mafioso: We're worried about this one.", 0.05, 0.8, 0.5)]);
        Assert.Equal("Mafioso: We're worried about this one.", reading.SubtitleBlock(Area).Text);
    }

    [Fact]
    public void LinesWithoutPlaceAreUntouched()
    {
        var reading = Reading.FromText("MAP\nHELP");
        Assert.Same(reading, reading.SubtitleBlock(Area));
    }

    [Theory]
    [InlineData("PHOTO MODE L1 + R1", true)]
    [InlineData("PHOTO MODE [L1] + [R3]", true)]
    [InlineData("Hand me the L1.", false)]
    public void ButtonAtTheEndIsAPrompt(string line, bool prompt) => Assert.Equal(prompt, ButtonPrompts.IsPrompt(line));

    [Theory]
    [InlineData("9? We'll lose these tracks.", "We'll lose these tracks.")]
    [InlineData("100. Mac and John...", "Mac and John...")]
    [InlineData("23m CESARE: It's here! Shoot him!", "CESARE: It's here! Shoot him!")]
    [InlineData("100 men came", "100 men came")]
    public void GaugeNumberStuckToLineIsDropped(string line, string clean) => Assert.Equal(clean, OcrNoise.Clean(line));

    /// <summary>GTA 6 (#404): etkileşim ve ekipman yazıları tek başına okununca altyazı sayılmaz.</summary>
    [Theory]
    [InlineData("TAKE AMMO PACK (0/3)")]
    [InlineData("SIT")]
    [InlineData("CLOSE")]
    [InlineData("FRESHEN UP")]
    [InlineData("• ADD TO TRUNK")]
    [InlineData("> REMOVE FROM TRUNK")]
    [InlineData("D STASH")]
    [InlineData("A TURN ON")]
    [InlineData("BEAST")]
    [InlineData("BENCH PRESS")]
    public void ActionLabelIsNotASubtitle(string label)
    {
        Assert.True(ButtonPrompts.IsActionLabel(label));
        Assert.Empty(new Reading([Line(label, 0.4, 0.8, 0.6)]).SubtitleBlock(Area).Lines);
        Assert.Empty(Reading.FromText(label).SubtitleBlock(Area).Lines);
    }

    /// <summary>Kısa gerçek konuşma ve görev yazısı kalır.</summary>
    [Theory]
    [InlineData("Yes.")]
    [InlineData("Okay.")]
    [InlineData("Why?")]
    [InlineData("OKAY.")]
    [InlineData("WHAT?")]
    [InlineData("Talk to Andy")]
    [InlineData("EXCLUSIVE: LEONIDA'S TOP SPOTS FOR A DECENT CATCH")]
    [InlineData("はい")]
    public void ShortSpeechIsKept(string speech)
    {
        Assert.False(ButtonPrompts.IsActionLabel(speech));
        Assert.Equal(speech, new Reading([Line(speech, 0.4, 0.8, 0.6)]).SubtitleBlock(Area).Text);
    }

    [Fact]
    public void ActionLabelBelowSubtitleDoesNotHideIt()
    {
        var reading = new Reading([
            Line("Hey. Looking for Andy.", 0.35, 0.7, 0.65),
            Line("TAKE AMMO PACK (0/3)", 0.42, 0.9, 0.58),
        ]);
        Assert.Equal("Hey. Looking for Andy.", reading.SubtitleBlock(Area).Text);
    }

    [Fact]
    public void WrappedAllCapsSubtitleStaysTogether()
    {
        var reading = new Reading([Line("I TOLD YOU", 0.42, 0.7, 0.58), Line("NOT TO GO THERE.", 0.4, 0.78, 0.6)]);
        Assert.Equal("I TOLD YOU\nNOT TO GO THERE.", reading.SubtitleBlock(Area).Text);
    }
}
