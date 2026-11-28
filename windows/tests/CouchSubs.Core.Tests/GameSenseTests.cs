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
    [InlineData("Mega Man X", "mega man x")]
    [InlineData("Mega Man 10", "mega man 10")]
    [InlineData("X-Men", "x men")]
    [InlineData("V-Rally", "v rally")]
    [InlineData("Mega Man X2", "mega man x 2")]
    [InlineData("GTA V", "gta 5")]
    [InlineData("Grand Theft Auto V Enhanced", "gta 5 enhanced")]
    [InlineData("GTA V Premium Edition", "gta 5 premium edition")]
    [InlineData("Final Fantasy X HD", "final fantasy 10 hd")]
    [InlineData("Mega Man X HD", "mega man x hd")]
    [InlineData("X-Men Origins: Wolverine", "x men origins wolverine")]
    [InlineData("V-Rally 4", "v rally 4")]
    [InlineData("Final Fantasy X", "final fantasy 10")]
    [InlineData("Ghost of Yōtei", "ghost of yotei")]
    [InlineData("", "")]
    public void GameNameKeyMatchesTheServer(string name, string key) => Assert.Equal(key, GameName.Key(name));

    /// <summary>
    /// Xbox çalışan oyunu bildirmez: Xbox için son seçilen oyun kendiliğinden kullanılır (hatırlanan; değiştirilebilir), hiç
    /// seçim yoksa oyun bilinmez ve günlüğe tek satır yazılır (Mac/iPhone GameSenseTests, Android GameSenseTest ile aynı).
    /// </summary>
    [Fact]
    public void XboxStartUsesTheLastChosenGameOrLogsThatTheGameIsUnknown()
    {
        var fresh = new GameSense();
        fresh.StartSession();
        Assert.Equal("Xbox: oyun tanınmadı, oyuna özel okumalar (telefon) kapalı", fresh.StartXbox(null));
        Assert.Null(fresh.Current);
        fresh.Choose("Grand Theft Auto VI");
        Assert.Equal("gta 6", GameName.Key(fresh.Current?.Name));
        Assert.Equal("Xbox: oyun elle seçildi: Grand Theft Auto VI", GameSense.XboxChosenLog("Grand Theft Auto VI"));

        var returning = new GameSense();
        returning.StartSession();
        Assert.Equal("Xbox: son seçilen oyun kullanılıyor: Grand Theft Auto VI", returning.StartXbox("Grand Theft Auto VI"));
        Assert.Equal("Grand Theft Auto VI", returning.Current?.Name);
        Assert.Equal(GameSense.GameSource.Remembered, returning.Source);
        Assert.False(returning.ShouldAsk(TimeSpan.FromMinutes(10), true));
        // Kullanıcı değiştirebilir.
        returning.Choose("Red Dead Redemption 2");
        Assert.Equal("Red Dead Redemption 2", returning.Current?.Name);
        Assert.Equal(GameSense.GameSource.User, returning.Source);

        // Bu çalışmada zaten seçilmiş oyun kayıtlı olanın önüne geçer.
        var running = new GameSense();
        running.Choose("Elden Ring");
        running.StartSession();
        running.StartXbox("Grand Theft Auto VI");
        Assert.Equal("Elden Ring", running.Current?.Name);
    }

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
        // PS5 başka oyun bildirdiyse elle seçim eskidi: PS5 bildirmeyi bırakınca eski seçim geri gelmez (paketten tanınan gelir), arama sınırlanmaz.
        sense.SetConsole(null);
        Assert.Equal("Red Dead Redemption 2", sense.Current?.Name);
        Assert.Null(sense.PackLimit);
    }

    /// <summary>PS5 elle seçilen oyunu bildirirse (adı aynı) seçim kalır.</summary>
    [Fact]
    public void SameGameFromTheConsoleKeepsTheChoice()
    {
        var sense = new GameSense();
        sense.Choose("GTA 5");
        sense.SetConsole(new RunningGame(null, "Grand Theft Auto V"));
        sense.SetConsole(null);
        Assert.Equal("GTA 5", sense.Current?.Name);
        Assert.Equal("GTA 5", sense.PackLimit);
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

    /// <summary>
    /// #353: canlı listedeki RDR2 ve Spider-Man 2 asıl paketle "(ek satırlar)" paketi olarak iki kez görünüyordu; tek karo
    /// olur, satırlar toplanır, iki kimlik birlikte açılıp kapanır. Asıl paketi olmayan ek paket kendi karosunda kalır.
    /// </summary>
    [Fact]
    public void PackShelfFoldsExtraLinesIntoMainPack()
    {
        GamePackLibrary.Info[] packs =
        [
            new("marvels-spider-man-2", "Marvel's Spider-Man 2", 2349, false),
            new("pool-marvels-spider-man-2", "Marvel's Spider-Man 2 (ek satırlar)", 425, false),
            new("pool-rdr-2", "Red Dead Redemption 2 (ek satırlar)", 481, false),
            new("red-dead-redemption-2", "Red Dead Redemption 2", 195_430, true),
            new("pool-ppsa09999", "Ghost of Yōtei (ek satırlar)", 40, false),
        ];
        var shelf = GameCatalog.PackShelf(packs);
        Assert.Equal(["marvels-spider-man-2", "red-dead-redemption-2", "pool-ppsa09999"], shelf.Select(p => p.Id));
        Assert.Equal(2774, shelf[0].Entries);
        Assert.Equal(["marvels-spider-man-2", "pool-marvels-spider-man-2"], shelf[0].PackIds);
        Assert.Equal("Red Dead Redemption 2", shelf[1].Title);
        Assert.Equal(195_911, shelf[1].Entries);
        Assert.Contains("Red Dead Redemption 2 (ek satırlar)", shelf[1].Titles);
        Assert.Equal(["pool-ppsa09999"], shelf[2].PackIds);
    }

    /// <summary>
    /// #1443: telefon çevirisi açıkken oyun iki dakikada tanınmazsa oturumda bir kez "telefon aranmıyor" yazılır; oyun
    /// biliniyorsa ya da telefon kapalıysa yazılmaz (Mac/iPhone GameSenseTests, Android GameSenseTest ile aynı).
    /// </summary>
    [Fact]
    public void PhoneIdleIsLoggedOncePerSessionWhileTheGameIsUnknown()
    {
        var sense = new GameSense();
        sense.StartSession();
        Assert.False(sense.ShouldLogPhoneIdle(TimeSpan.FromSeconds(60), readsPhone: true));
        Assert.False(sense.ShouldLogPhoneIdle(TimeSpan.FromSeconds(130), readsPhone: false));
        Assert.True(sense.ShouldLogPhoneIdle(TimeSpan.FromSeconds(130), readsPhone: true));
        Assert.False(sense.ShouldLogPhoneIdle(TimeSpan.FromSeconds(145), readsPhone: true));
        sense.StartSession();
        sense.Choose("GTA 6");
        Assert.False(sense.ShouldLogPhoneIdle(TimeSpan.FromSeconds(130), readsPhone: true));
        Assert.StartsWith("telefon aranmıyor: oynanan oyun bilinmiyor", GameSense.PhoneIdleLog);
    }
}

