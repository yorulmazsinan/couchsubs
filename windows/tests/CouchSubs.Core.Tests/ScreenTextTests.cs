// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core.Tests;

/// <summary>GTA'da küçük harfsiz, noktalamasız ekran yazısı satırı çevrilmez; konuşma paketten bulunur.</summary>
public class ScreenTextTests
{
    private static readonly Frame Image = Frame.Blank(64, 64);

    private static PackMatch? Lookup(string text) =>
        PackKey.Canon(text) == "i swear they got our cash in here man grab it" ? new PackMatch("Yemin ederim paramız burada, kap şunu!", []) : null;

    [Theory]
    [InlineData("LT W-22 SMALL GAME RIFLE", true)]
    [InlineData("LN 5963 51", true)]
    [InlineData("GREAT PRICES", true)]
    [InlineData("SKIP O", true)]
    [InlineData("WHAT?", false)]
    [InlineData("OKAY.", false)]
    [InlineData("Go to Andy", false)]
    [InlineData("I swear they got our cash in here, man, grab it!", false)]
    [InlineData("JASON: Get down!", false)]
    [InlineData("4", false)]
    public void RecognizesScreenText(string line, bool expected) => Assert.Equal(expected, ScreenText.IsScreenText(line));

    [Theory]
    [InlineData("Grand Theft Auto VI", true)]
    [InlineData("GTA 6", true)]
    [InlineData("Red Dead Redemption 2", false)]
    [InlineData(null, false)]
    public void OnlyGta(string? game, bool expected) => Assert.Equal(expected, ScreenText.IsGta(game));

    [Fact]
    public void DropsOnlyTheScreenTextLineFromAJoinedReading()
    {
        var reading = Reading.FromText("LT W-22 SMALL GAME RIFLE\nI swear they got our cash in here, man, grab it!").WithoutScreenText();
        Assert.Equal("I swear they got our cash in here, man, grab it!", reading.Text);
    }

    private static async Task<(List<string> sent, string? origin)> Run(Func<bool>? drop)
    {
        var sender = new FakeSender();
        var text = "LT W-22 SMALL GAME RIFLE\nI swear they got our cash in here, man, grab it!";
        var pipeline = new SubtitlePipeline(new FakeReader(text, text, text), new FakeTranslator(), sender)
            { PackLookup = Lookup, DropsScreenText = drop };
        for (var i = 0; i < 3; i++)
        {
            await pipeline.ProcessAsync(Image, new CropRegion());
            await pipeline.WaitForTranslationsAsync();
        }
        return (sender.Sent, pipeline.LastOrigin);
    }

    [Fact]
    public async Task InGtaTheWeaponLineIsDroppedAndTheLineComesFromThePack()
    {
        var (sent, origin) = await Run(() => true);
        Assert.Equal(["Yemin ederim paramız burada, kap şunu!"], sent);
        Assert.Equal("paket", origin);
    }

    [Fact]
    public async Task OffByDefault()
    {
        var (_, origin) = await Run(null);
        Assert.NotEqual("paket", origin);
    }

    [Fact]
    public void PackKeySurvivesNoncharacters()
    {
        // U+FFFE OCR okumasında görüldü; anahtar üretimi istisnayla çökmemeli, karakter yokmuş gibi davranmalı.
        Assert.Equal(PackKey.Key("Hold the gate"), PackKey.Key("Hold the gate￾"));
    }
}
