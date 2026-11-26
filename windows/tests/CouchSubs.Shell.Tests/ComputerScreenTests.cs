// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;

namespace CouchSubs.Shell.Tests;

/// <summary>Altyazının bilgisayar ekranında gösterilmesi: ayar, TV'siz kurulum ve pencereye giden olaylar (Mac ile aynı testler).</summary>
public class ComputerScreenTests
{
    private static readonly RegisteredConsole Console =
        new("192.168.1.253", "PS5", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray());

    /// <summary>PS5 kurulu, TV yok.</summary>
    private static MemoryStore StoreWithoutTv()
    {
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        store.Save(StoreKeys.Console, Console);
        return store;
    }

    private static AppController Make(FakeServices? services = null, MemoryStore? store = null, MemorySettings? settings = null) =>
        AppControllerTests.Make(services, store ?? StoreWithoutTv(), settings);

    [Fact]
    public void ExistingSettingsDefaultToTv()
    {
        var old = JsonSerializer.Deserialize<UserSettings>("""{"SourceLanguage":"en","Style":{"FontSize":58}}""")!;
        Assert.Equal(SubtitleOutput.Tv, old.Output);
        Assert.False(old.OverlayClickThrough);
        Assert.False(old.OverlayFollowSubtitle);
        Assert.Null(old.Overlay);
        Assert.Equal(58, old.Style.FontSize);
    }

    [Theory]
    [InlineData(SubtitlePlacement.Above)]
    [InlineData(SubtitlePlacement.Below)]
    public void ComputerFollowIsSavedIndependentlyOfTvPlacement(SubtitlePlacement tvPlacement)
    {
        var settings = new UserSettings { Style = new SubtitleStyle(Placement: tvPlacement), OverlayFollowSubtitle = true };
        var restored = JsonSerializer.Deserialize<UserSettings>(JsonSerializer.Serialize(settings))!;
        Assert.True(restored.OverlayFollowSubtitle);
        Assert.Equal(tvPlacement, restored.Style.Placement);
        var disabled = restored with { OverlayFollowSubtitle = false };
        Assert.Equal(tvPlacement, disabled.Style.Placement);
        Assert.False(disabled.OverlayFollowSubtitle);
    }

    [Fact]
    public void LegacyRemotePlayCoverMigratesOnceAndPreservesExplicitChoice()
    {
        const string legacy = """{"FrameSource":1,"Style":{"Placement":"Cover"}}""";
        var migrated = ExtraAreaMigration.Load(legacy);
        Assert.True(migrated.OverlayFollowSubtitle);
        Assert.Equal(SubtitlePlacement.Cover, migrated.Style.Placement);
        var disabled = migrated with { OverlayFollowSubtitle = false };
        Assert.False(ExtraAreaMigration.Load(JsonSerializer.Serialize(disabled)).OverlayFollowSubtitle);
    }

    [Theory]
    [InlineData("Above")]
    [InlineData("Below")]
    [InlineData("Fixed")]
    public void LegacyOtherPlacementsDoNotEnableComputerCover(string placement)
    {
        var json = JsonSerializer.Serialize(new { FrameSource = 1, Style = new { Placement = placement } });
        Assert.False(ExtraAreaMigration.Load(json).OverlayFollowSubtitle);
        Assert.False(ExtraAreaMigration.Load("""{"FrameSource":0,"Style":{"Placement":"Cover"}}""").OverlayFollowSubtitle);
    }

    [Fact]
    public void OutputAndWindowAreSavedAsText()
    {
        var settings = new UserSettings { Output = SubtitleOutput.Both, OverlayClickThrough = true, Overlay = new OverlayBounds(100, 800, 1200) };
        var json = JsonSerializer.Serialize(settings);
        Assert.Contains("\"Output\":\"Both\"", json);
        var loaded = JsonSerializer.Deserialize<UserSettings>(json)!;
        Assert.Equal(SubtitleOutput.Both, loaded.Output);
        Assert.True(loaded.OverlayClickThrough);
        Assert.Equal(new OverlayBounds(100, 800, 1200), loaded.Overlay);
    }

    [Fact]
    public void NoTvChoiceSkipsTvSetup()
    {
        var services = new FakeServices();
        var controller = Make(services);
        controller.Step = OnboardingStep.Tv;
        Assert.False(controller.CanAdvance);
        controller.UseComputerScreen();
        // Windows'ta TV'den sonra çeviri modeli adımı gelir.
        Assert.Equal(OnboardingStep.Translation, controller.Step);
        Assert.Equal(SubtitleOutput.Computer, controller.Settings.Output);
        Assert.Equal(0, services.PairCount);
        Assert.Null(controller.Tv);
    }

    [Fact]
    public void SetupWithoutTvOpensMainScreenNextLaunch()
    {
        var store = StoreWithoutTv();
        var settings = new MemorySettings();
        var controller = Make(store: store, settings: settings);
        // PS5 kayıtlı ama kurulum bitmemiş: sihirbaz TV adımından sürer.
        Assert.Equal(OnboardingStep.Tv, controller.Step);
        controller.UseComputerScreen();
        controller.Advance(); // çeviri modeli -> deneme
        controller.Advance(); // deneme -> daha iyi çeviri (isteğe bağlı)
        controller.Advance(); // daha iyi çeviri -> bitti
        Assert.Equal(OnboardingStep.Done, controller.Step);
        Assert.Equal(OnboardingStep.Done, Make(store: store, settings: settings).Step);
    }

    [Fact]
    public void SetupAgainForgetsCompletedSetup()
    {
        var store = StoreWithoutTv();
        var controller = Make(store: store);
        controller.Step = OnboardingStep.Done;
        controller.ResetSetup();
        Assert.Equal(OnboardingStep.Welcome, Make(store: store).Step);
    }

    [Fact]
    public async Task StartWithoutTvShowsOnComputerOnly()
    {
        var services = new FakeServices();
        var controller = Make(services);
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Computer };
        Assert.True(controller.CanStart);
        Assert.False(controller.ShowsOnTv);
        await controller.StartAsync();
        Assert.True(controller.IsRunning);
        Assert.Single(services.Streams);
        // TV aranmaz, açık tutulmaz.
        Assert.Empty(services.Keepers);
        controller.Stop();
    }

    /// <summary>
    /// beta.26'da TV'siz (Samsung 2017 desteklenmiyor) "Bilgisayar ekranı" seçen kullanıcıda "Çeviriyi başlat" uygulamayı
    /// kapatıyordu: başlatma hiçbir TV hizmetine dokunmadan, hata vermeden çeviriye geçmeli.
    /// </summary>
    [Fact]
    public async Task StartOnComputerWithoutTvNeverTouchesTv()
    {
        var services = new FakeServices();
        var sleep = new FakeSleep();
        var controller = AppControllerTests.Make(services, StoreWithoutTv(), new MemorySettings(), sleep);
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Computer };
        Assert.False(controller.HasTv);
        Assert.False(controller.NeedsTv);
        await controller.StartAsync();
        Assert.True(controller.IsRunning);
        Assert.False(controller.IsStarting);
        Assert.True(sleep.Active);
        Assert.True(Assert.Single(services.Streams).Started);
        // PS5 bağlanamasa da (ör. kapalı) TV aranmaz, beklenmez.
        services.Streams[0].Emit(SessionState.Disconnected(DisconnectKind.Network));
        await controller.CheckConnectionsAsync();
        Assert.Equal(0, services.TvCalls);
        controller.Stop();
        Assert.False(sleep.Active);
    }

    /// <summary>Samsung'la eşleşme yarım kaldıysa (TV kayıtlı, anahtarı yok) bilgisayar ekranında çeviri yine başlar.</summary>
    [Fact]
    public async Task StartOnComputerWithHalfPairedTvNeverTouchesTv()
    {
        var services = new FakeServices();
        var store = StoreWithoutTv();
        store.Save(StoreKeys.Tv, new LgTv("Samsung TV", "192.168.1.40", TvBrand.Samsung));
        var controller = Make(services, store);
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Computer };
        Assert.True(controller.CanStart);
        await controller.StartAsync();
        Assert.True(controller.IsRunning);
        Assert.Equal(0, services.TvCalls);
        controller.Stop();
    }

    /// <summary>Başlatma yarıda hata verirse geride çalışan oturum ya da "Başlatılıyor" durumu kalmaz; hata çağırana gider.</summary>
    [Fact]
    public async Task FailedStartCleansUp()
    {
        var services = new FakeServices { StreamError = new InvalidOperationException("couchsubs_native yok") };
        var sleep = new FakeSleep();
        var controller = AppControllerTests.Make(services, StoreWithoutTv(), new MemorySettings(), sleep);
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Computer };
        var hidden = 0;
        controller.OverlayHidden += () => hidden++;
        await Assert.ThrowsAsync<InvalidOperationException>(controller.StartAsync);
        Assert.False(controller.IsRunning);
        Assert.False(controller.IsStarting);
        Assert.False(sleep.Active);
        Assert.Equal(1, hidden);
        // Sorun giderilince yeniden başlatılabilir.
        services.StreamError = null;
        await controller.StartAsync();
        Assert.True(controller.IsRunning);
        controller.Stop();
    }

    [Fact]
    public async Task TvOnlyWithoutTvCannotStart()
    {
        var services = new FakeServices();
        var controller = Make(services);
        Assert.False(controller.CanStart);
        Assert.True(controller.NeedsTv);
        Assert.Equal("Not set up", controller.TvStatusText);
        await controller.StartAsync();
        Assert.False(controller.IsRunning);
        Assert.Empty(services.Streams);
    }

    [Fact]
    public async Task ChoosingTvWhileRunningStartsKeeper()
    {
        var services = new FakeServices();
        var store = StoreWithoutTv();
        store.Save(StoreKeys.Tv, new LgTv("LG TV", "127.0.0.1"));
        store.Save(StoreKeys.TvKey, "tv-key");
        var controller = Make(services, store);
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Computer };
        await controller.StartAsync();
        Assert.Empty(services.Keepers);
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Both };
        Assert.True(Assert.Single(services.Keepers).Running);
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Computer };
        Assert.False(services.Keepers[0].Running);
        controller.Stop();
    }

    /// <summary>
    /// "Yalnız OBS (yayın)": TV eşleşmiş olsa da aranmaz ve açık tutulmaz, bilgisayar ekranında pencere açılmaz; çeviri TV'siz de
    /// başlar (OBS katmanı olayları sunucudan alır). Mac ile aynı test.
    /// </summary>
    [Fact]
    public async Task ObsOnlyStartsWithoutTvAndOpensNoWindow()
    {
        var services = new FakeServices();
        var store = StoreWithoutTv();
        store.Save(StoreKeys.Tv, new LgTv("LG TV", "127.0.0.1"));
        store.Save(StoreKeys.TvKey, "tv-key");
        var controller = Make(services, store);
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Obs };
        Assert.True(controller.CanStart);
        Assert.False(controller.ShowsOnTv);
        Assert.False(controller.ShowsOnComputer);
        var received = new List<SubtitleEvent>();
        controller.OverlayEvent += received.Add;
        await controller.StartAsync();
        Assert.True(controller.IsRunning);
        Assert.Empty(services.Keepers);
        controller.SendTestSubtitle();
        Assert.Empty(received);
        controller.Stop();
        var alone = Make();
        alone.Settings = alone.Settings with { Output = SubtitleOutput.Obs };
        Assert.True(alone.CanStart);
        Assert.Contains("\"Output\":\"Obs\"", JsonSerializer.Serialize(alone.Settings));
    }

    [Fact]
    public async Task PairingTvAfterNoTvChoiceSendsSubtitlesToTv()
    {
        var controller = Make();
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Computer };
        await controller.PairAsync(new LgTv("LG TV", "192.168.1.153"));
        Assert.Equal(SubtitleOutput.Tv, controller.Settings.Output);
        controller.Dispose();
    }

    [Fact]
    public void TestSubtitleGoesToComputerWindow()
    {
        var controller = Make();
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Computer };
        var received = new List<SubtitleEvent>();
        controller.OverlayEvent += received.Add;
        controller.SendTestSubtitle();
        var shown = Assert.Single(received);
        Assert.Equal(SubtitleEventKind.Subtitle, shown.Kind);
        Assert.Equal("This is a test subtitle. Can you see it on top of the game?", shown.Text);
        Assert.Equal(8000, shown.DurationMs);
    }

    [Fact]
    public void TvOnlyKeepsComputerWindowEmpty()
    {
        var controller = Make();
        var received = new List<SubtitleEvent>();
        controller.OverlayEvent += received.Add;
        controller.SendTestSubtitle();
        Assert.Empty(received);
    }

    /// <summary>Yayın penceresi altyazı yalnız TV'deyken de satırları alır (yayın ekrandaki seçimden bağımsız).</summary>
    [Fact]
    public void StreamWindowReceivesSubtitlesEvenOnTvOnly()
    {
        var controller = Make();
        var received = new List<SubtitleEvent>();
        controller.StreamEvent += received.Add;
        controller.SendTestSubtitle();
        Assert.Equal(SubtitleEventKind.Subtitle, Assert.Single(received).Kind);
    }

    [Fact]
    public async Task StopHidesStreamWindow()
    {
        var controller = Make();
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Both };
        await controller.StartAsync();
        var hidden = 0;
        controller.StreamHidden += () => hidden++;
        controller.Stop();
        Assert.Equal(1, hidden);
    }

    [Fact]
    public void StreamBackgroundIsSavedAndDefaultsToGreen()
    {
        var store = StoreWithoutTv();
        var controller = Make(store: store);
        Assert.Equal(StreamBackground.Green, controller.StreamBackground);
        controller.StreamBackground = StreamBackground.Magenta;
        Assert.Equal("magenta", store.Load<string>(StoreKeys.StreamBackground));
        Assert.Equal(StreamBackground.Magenta, Make(store: store).StreamBackground);
        Assert.Equal(StreamBackground.Green, StreamBackgrounds.FromStored("bozuk"));
        Assert.Equal((byte)0xFF, StreamBackground.Green.Rgb().Green);
        Assert.Equal(1, StreamBackgrounds.BoxOpacity(60));
        Assert.Equal(0, StreamBackgrounds.BoxOpacity(0));
    }

    [Fact]
    public async Task StopHidesComputerWindow()
    {
        var controller = Make();
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Both };
        await controller.StartAsync();
        var hidden = 0;
        controller.OverlayHidden += () => hidden++;
        controller.Stop();
        Assert.Equal(1, hidden);
    }

    [Fact]
    public void ClickThroughToggles()
    {
        var controller = Make();
        controller.ToggleClickThrough();
        Assert.True(controller.Settings.OverlayClickThrough);
        controller.ToggleClickThrough();
        Assert.False(controller.Settings.OverlayClickThrough);
    }

    /// <summary>Altyazı TV'ye gitmiyorsa TV'nin bağlanmaması güvenlik duvarı önerisine yol açmaz.</summary>
    [Fact]
    public async Task ComputerOnlyNeverWaitsForTv()
    {
        var firewall = new FakeFirewall { Rule = false };
        var services = new FakeServices { Firewall = firewall };
        var store = StoreWithoutTv();
        store.Save(StoreKeys.Tv, new LgTv("LG TV", "127.0.0.1"));
        store.Save(StoreKeys.TvKey, "tv-key");
        var controller = Make(services, store);
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Computer };
        var now = DateTime.UtcNow;
        controller.Clock = () => now;
        await controller.StartAsync();
        services.Streams[0].Emit(SessionState.Streaming);
        now += TimeSpan.FromMinutes(5);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        controller.Stop();
    }
}
