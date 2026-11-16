// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>Oynanan oyunun tanınması ve oyun adı anahtarı (sunucudaki server/pool/test/pool.test.js ve Android ile aynı örnekler).</summary>
public class GameSenseTests
{
    [Theory]
    [InlineData("Grand Theft Auto VI", "gta 6")]
    [InlineData("GTA 6", "gta 6")]
    [InlineData("gta vi", "gta 6")]
    [InlineData("GTA6", "gta 6")]
    [InlineData("Grand Theft Auto VI™", "gta 6")]
    [InlineData("Marvel's Spider-Man 2", "marvels spider man 2")]
    [InlineData("The Witcher 3: Wild Hunt", "witcher 3 wild hunt")]
    [InlineData("Call of Duty: Black Ops 7", "cod black ops 7")]
    [InlineData("Ghost of Yōtei", "ghost of yotei")]
    [InlineData("", "")]
    public void GameNameKeyMatchesTheServer(string name, string key) => Assert.Equal(key, GameName.Key(name));

    [Fact]
    public void FiveOfTwentyLinesFromOnePackRecogniseTheGame()
    {
        var sense = new GameSense();
        for (var i = 0; i < 4; i++) Assert.False(sense.NoteLine("gta-v", "Grand Theft Auto V"));
        for (var i = 0; i < 10; i++) sense.NoteLine(null, null);
        Assert.Null(sense.Current);
        Assert.True(sense.NoteLine("gta-v", "Grand Theft Auto V"));
        Assert.Equal(new RunningGame(null, "Grand Theft Auto V"), sense.Current);
        Assert.Equal(GameSense.GameSource.Pack, sense.Source);
        Assert.False(sense.NoteLine("gta-v", "Grand Theft Auto V"));
    }

    /// <summary>
    /// Elle seçilen oyun paket çoğunluğunun önüne geçer, PS5'in bildirdiğinin önüne geçmez; paket araması yalnız elle seçim
    /// geçerliyken o oyunla sınırlanır (#218).
    /// </summary>
    [Fact]
    public void ChosenGameBeatsThePackButNotTheConsole()
    {
        var sense = new GameSense();
        sense.Choose("Marvel's Wolverine");
        for (var i = 0; i < 5; i++) sense.NoteLine("rdr-2", "Red Dead Redemption 2");
        Assert.Equal("Marvel's Wolverine", sense.Current?.Name);
        Assert.Equal(GameSense.GameSource.User, sense.Source);
        Assert.Equal("Marvel's Wolverine", sense.PackLimit);
        sense.SetConsole(new RunningGame(null, "Mafia: The Old Country"));
        Assert.Equal("Mafia: The Old Country", sense.Current?.Name);
        Assert.Equal(GameSense.GameSource.Console, sense.Source);
        Assert.Null(sense.PackLimit);
    }

    /// <summary>Yapay zekâya giden ad kararlı oyundur: tek bir yabancı satır değiştirmez, 20 satırın 5'i değiştirir (#27).</summary>
    [Fact]
    public void OneStrayLineDoesNotChangeTheGame()
    {
        var sense = new GameSense();
        for (var i = 0; i < 5; i++) sense.NoteLine("gta-v", "Grand Theft Auto V");
        Assert.Equal("Grand Theft Auto V", sense.Current?.Name);
        Assert.False(sense.NoteLine("rdr-2", "Red Dead Redemption 2"));
        Assert.Equal("Grand Theft Auto V", sense.Current?.Name);
        for (var i = 0; i < 3; i++) Assert.False(sense.NoteLine("rdr-2", "Red Dead Redemption 2"));
        Assert.Equal("Grand Theft Auto V", sense.Current?.Name);
        Assert.True(sense.NoteLine("rdr-2", "Red Dead Redemption 2"));
        Assert.Equal("Red Dead Redemption 2", sense.Current?.Name);
    }

    /// <summary>Paketle tanınmayan oyunda ad gitmez; kullanıcı seçtiyse onun seçtiği, PS5 bildirdiyse PS5'in bildirdiği gider.</summary>
    [Fact]
    public void WithoutAStableGameTheChosenNameOrNothingIsSent()
    {
        var sense = new GameSense();
        for (var i = 0; i < 4; i++) sense.NoteLine("rdr-2", "Red Dead Redemption 2");
        Assert.Null(sense.Current);
        sense.Choose("Grand Theft Auto V");
        Assert.Equal("Grand Theft Auto V", sense.Current?.Name);
        sense.SetConsole(new RunningGame(null, "Mafia: The Old Country"));
        Assert.Equal("Mafia: The Old Country", sense.Current?.Name);
    }

    [Fact]
    public void GeneralPackIsNotAGameAndTitleIdComesFromAutoPack()
    {
        var sense = new GameSense();
        for (var i = 0; i < 10; i++) Assert.False(sense.NoteLine(GameSense.GeneralPack, "Ortak havuz"));
        for (var i = 0; i < 5; i++) sense.NoteLine("pool-ppsa01234", "Grand Theft Auto VI");
        Assert.Equal(new RunningGame("PPSA01234", "Grand Theft Auto VI"), sense.Current);
        Assert.Equal("CUSA00419_00", GameSense.TitleIdFromPack("pool-cusa00419-00"));
        Assert.Null(GameSense.TitleIdFromPack("pool-gta-6"));
    }

    [Fact]
    public void AsksOnceAfterTwoMinutesWhenNothingIsKnown()
    {
        var sense = new GameSense();
        Assert.False(sense.ShouldAsk(TimeSpan.FromMinutes(1), true));
        Assert.False(sense.ShouldAsk(GameSense.AskAfter, false));
        Assert.True(sense.ShouldAsk(GameSense.AskAfter, true));
        sense.MarkAsked();
        Assert.False(sense.ShouldAsk(GameSense.AskAfter, true));
        sense.Choose("GTA 6");
        sense.StartSession();
        Assert.Equal(new RunningGame(null, "GTA 6"), sense.Current);
        Assert.False(sense.ShouldAsk(GameSense.AskAfter, true));
        sense.SetConsole(RunningGame.Create("PPSA01234", "Grand Theft Auto VI"));
        Assert.Equal("PPSA01234", sense.Current?.TitleId);
    }

    [Fact]
    public void SuggestionsPutLastPlayedFirstAndFindByKey()
    {
        var list = GameCatalog.Suggestions("", ["Mafia: The Old Country"], "Elden Ring");
        Assert.Equal("Elden Ring", list[0]);
        Assert.Equal("Mafia: The Old Country", list[1]);
        Assert.Equal("Grand Theft Auto VI", GameCatalog.Suggestions("gta 6", [], null)[0]);
        Assert.Empty(GameCatalog.Suggestions("zzzz", [], null));
    }
}
