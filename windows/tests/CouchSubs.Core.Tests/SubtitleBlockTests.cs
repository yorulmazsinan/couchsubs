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

    /// <summary>
    /// Menü satırlarının kenarı hizalıdır; ortalanmış kısa konuşma satırları ("No / Wait / Go on") menü sayılmaz. Konuşan
    /// adıyla başlayan satır da menü değildir (Mac, Android ile aynı).
    /// </summary>
    [Fact]
    public void CenteredShortLinesAndSpeakerLinesAreNotAMenu()
    {
        Assert.True(new Reading([Line("MAP", 0.05, 0.05, 0.10), Line("HELP", 0.05, 0.15, 0.11), Line("SETTINGS", 0.051, 0.25, 0.17)]).IsMenu);
        Assert.False(new Reading([Line("No", 0.47, 0.05, 0.53), Line("Wait", 0.46, 0.15, 0.54), Line("Go on", 0.45, 0.25, 0.55)]).IsMenu);
        Assert.False(new Reading([Line("JASON: No", 0.05, 0.05, 0.15), Line("LUCIA: Wait", 0.05, 0.15, 0.16),
                                  Line("JASON: Go", 0.05, 0.25, 0.15)]).IsMenu);
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

    /// <summary>GTA 6: tuş simgesi okunmamış ya da harf/simge kalıntısına dönüşmüş ipuçları (havuzdaki gerçek satırlar).</summary>
    [Theory]
    [InlineData("Press to threaten the teller", true)]
    [InlineData("Press  to open the map", true)]
    [InlineData("Use to select your binoculars", true)]
    [InlineData("Hold to open your loadout", true)]
    [InlineData("Press @ to open the map", true)]
    [InlineData("Press D to greet Joey", true)]
    [InlineData("Hold I LI to open your loadout", true)]
    [InlineData("Press RE to go back to your weapons and equipment", true)]
    [InlineData("Press (9 0 to stop focusing", true)]
    [InlineData("Release 2 and R2 to breathe out", true)]
    [InlineData("Hold + to look at Joey", true)]
    [InlineData("Press [RB] to take cover", true)]
    [InlineData("Use ⓁⓇ to steer the boat", true)]
    [InlineData("Hold △ to enter", true)]
    [InlineData("Press © to call Lucia", true)]
    [InlineData("PRESS to VAULT over obstacles", true)]
    [InlineData("Press to heal.", true)]
    [InlineData("Release Li To Use", true)]
    [InlineData("Use i to follow Dutch", true)]
    [InlineData("0 0 00 0 Press • to open the index", true)]
    [InlineData("Press the button, Jason!", false)]
    [InlineData("Hold on to something.", false)]
    [InlineData("HOLD ON TO IT", false)]
    [InlineData("Use it to open the door.", false)]
    [InlineData("Hold up, Floyd. I'm coming down there.", false)]
    [InlineData("Use a rope to climb down.", false)]
    [InlineData("Hold to your course, men.", false)]
    [InlineData("Jason: Press to the left", false)]
    [InlineData("Use me to get inside.", false)]
    [InlineData("\"Press to the wall,\" he said", false)]
    [InlineData("Hold to it", false)]
    [InlineData("Hold on, Momma Bear!", false)]
    [InlineData("Press on, we're almost there.", false)]
    public void PromptWithUnreadIconIsAPrompt(string line, bool prompt) => Assert.Equal(prompt, ButtonPrompts.IsPrompt(line));

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

    /// <summary>
    /// GitHub #933 (GTA 6): karakter TV izlerken haber bandı konuşmanın altında hiç değişmeden duruyor; uzun süredir
    /// değişmeyen ortalı blok, yanında yeni beliren ortalı blok varken seçilmez. Tek sabit blok seçilmeye devam eder (Mac,
    /// Android ile aynı).
    /// </summary>
    [Fact]
    public void StaleCenteredBlockLosesToNewOne()
    {
        var speech = Line("We are live from the scene where it all happened.", 0.25, 0.3, 0.75);
        var ticker = Line("STORM HITS VICE CITY COAST - LIVE COVERAGE", 0.3, 0.8, 0.7);
        var ages = new Dictionary<string, long> { [speech.Text] = 1200, [ticker.Text] = 9000 };
        long? Age(string text) => ages.TryGetValue(text, out var value) ? value : null;
        var skipped = new List<string>();
        var both = new Reading([speech, ticker]);
        Assert.Equal(ticker.Text, both.SubtitleBlock(Area).Text);
        Assert.Equal(speech.Text, both.SubtitleBlock(Area, age: Age, stale: block => skipped.Add(block.Text)).Text);
        Assert.Equal([ticker.Text], skipped);
        // Tek sabit blok (değişmeyen uzun cümle) altyazıdır.
        skipped.Clear();
        Assert.Equal(ticker.Text, new Reading([ticker]).SubtitleBlock(Area, age: Age, stale: block => skipped.Add(block.Text)).Text);
        Assert.Empty(skipped);
        // İkisi de aynı anda belirip sabit kaldıysa (hangisinin yeni olduğu bilinmiyor) eski kural geçerli.
        Assert.Equal(ticker.Text, both.SubtitleBlock(Area, age: _ => 9000).Text);
        // Bant konuşan adı gibi başlıyor ("EXCLUSIVE: …"): sabitse yine atlanır, yeni konuşma seçilir.
        var headline = Line("EXCLUSIVE: LEONIDA'S TOP SPOTS FOR A DECENT CATCH", 0.25, 0.8, 0.75);
        var news = new Reading([speech, headline]);
        Assert.Equal(headline.Text, news.SubtitleBlock(Area).Text);
        Assert.Equal(speech.Text, news.SubtitleBlock(Area, age: text => text == headline.Text ? 9000 : 1000).Text);
        // Konuşan adlı blok yeniyse ya da yanındaki yeni yazı kısa (görev/HUD) ise seçilmeye devam eder.
        var named = Line("ANCHOR: Stay with us for more.", 0.3, 0.3, 0.7);
        Assert.Equal(named.Text, new Reading([named, ticker]).SubtitleBlock(Area, age: text => text == named.Text ? 1000 : 9000).Text);
        var shortLine = Line("Follow John", 0.4, 0.8, 0.6);
        Assert.Equal(named.Text, new Reading([named, shortLine]).SubtitleBlock(Area, age: text => text == named.Text ? 9000 : 1000).Text);
    }
}
