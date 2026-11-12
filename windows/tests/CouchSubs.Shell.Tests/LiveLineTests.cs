// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;

namespace CouchSubs.Shell.Tests;

/// <summary>Ana ekrandaki ölçüm satırı ve altyazı geçmişi (oyun karesinden TV'ye giden satıra kadar).</summary>
public sealed class LiveLineTests : IDisposable
{
    private readonly string folder = Path.Combine(Path.GetTempPath(), "couchsubs-live-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
    }

    private static AppController Ready(FakeServices services)
    {
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        store.Save(StoreKeys.Console, new RegisteredConsole("192.168.1.253", "PS5", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray()));
        store.Save(StoreKeys.Tv, new LgTv("LG TV", "127.0.0.1"));
        store.Save(StoreKeys.TvKey, "tv-key");
        return AppControllerTests.Make(services, store);
    }

    /// <summary>Koşul sağlanana kadar oyun karesi gönderir (en çok 5 sn).</summary>
    private static async Task FeedUntil(FakeServices services, Func<bool> condition)
    {
        var frame = Frame.Blank(64, 64);
        for (var i = 0; i < 250 && !condition(); i++)
        {
            services.Streams[^1].Emit(frame);
            await Task.Delay(20);
        }
        Assert.True(condition());
    }

    [Fact]
    public async Task ShownLineGoesToMetricsAndHistory()
    {
        var services = new FakeServices { ReaderLines = Reading.FromText("Hold the gate") };
        var controller = Ready(services);
        await controller.StartAsync();
        Assert.Equal("", controller.MetricsText);
        var changed = new List<string?>();
        controller.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        await FeedUntil(services, () => controller.History.Count == 1 && controller.MetricsText.Length > 0);
        var entry = controller.History[0];
        Assert.Equal(("Hold the gate", "TR: Hold the gate", LineOrigin.Engine), (entry.Source, entry.Translation, entry.Origin));
        Assert.Matches(@"^OCR \d+ ms · Translation \d+ ms · Delay \d+ ms$", controller.MetricsText);
        Assert.Contains(nameof(AppController.History), changed);
        Assert.Contains(nameof(AppController.MetricsText), changed);
        controller.Stop();
        // Yeni oturumda ölçüm satırı ilk satıra kadar boştur.
        await controller.StartAsync();
        Assert.Equal("", controller.MetricsText);
        controller.Dispose();
    }

    [Fact]
    public async Task HistoryIsSavedAndLoadedOnTheNextStart()
    {
        var file = Path.Combine(folder, "history.json");
        var services = new FakeServices { ReaderLines = Reading.FromText("Hold the gate"), HistoryFile = file };
        var controller = Ready(services);
        await controller.StartAsync();
        await FeedUntil(services, () => controller.History.Count == 1);
        await controller.WaitForHistoryAsync();
        controller.Dispose();
        Assert.Equal("TR: Hold the gate", Assert.Single(SubtitleHistory.Load(file).Entries).Translation);

        var reopened = Ready(new FakeServices { HistoryFile = file });
        Assert.Equal("TR: Hold the gate", Assert.Single(reopened.History).Translation);
        reopened.ClearHistory();
        await reopened.WaitForHistoryAsync();
        Assert.Empty(reopened.History);
        Assert.Empty(SubtitleHistory.Load(file).Entries);
        reopened.Dispose();
    }

    [Fact]
    public void WithoutAFileNothingIsWritten()
    {
        var controller = Ready(new FakeServices());
        Assert.Empty(controller.History);
        controller.ClearHistory();
        Assert.True(controller.WaitForHistoryAsync().IsCompleted);
        controller.Dispose();
    }

    [Fact]
    public async Task TestSubtitleStartsTheServerWhenIdle()
    {
        var controller = AppControllerTests.Make(store: ComputerScreenStore());
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Computer };
        var received = new List<SubtitleEvent>();
        controller.OverlayEvent += received.Add;
        await controller.SendTestSubtitleAsync();
        Assert.Equal("This is a test subtitle. Can you see it on top of the game?", Assert.Single(received).Text);
        controller.Dispose();
    }

    private static MemoryStore ComputerScreenStore()
    {
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        return store;
    }
}

/// <summary>Altyazı alanının hazır seçimi ayarlarda (eski ayar dosyaları dahil).</summary>
public class AreaPresetSettingsTests
{
    [Fact]
    public void NewSettingsUseTheBottomArea()
    {
        var settings = new UserSettings();
        Assert.Equal(AreaPreset.Bottom, settings.AreaPreset);
        Assert.Equal(new CropRegion(), settings.Region);
    }

    [Theory]
    [InlineData("""{"SourceLanguage":"en"}""", AreaPreset.Bottom)]
    [InlineData("""{"Region":{"Top":0.03,"Bottom":0.38,"Left":0.14,"Right":0.86}}""", AreaPreset.Top)]
    [InlineData("""{"Region":{"Top":0,"Bottom":1,"Left":0,"Right":1}}""", AreaPreset.Full)]
    [InlineData("""{"Region":{"Top":0.5,"Bottom":0.9,"Left":0.1,"Right":0.9}}""", AreaPreset.Custom)]
    public void OldSettingsInferThePresetFromTheRegion(string json, AreaPreset preset) =>
        Assert.Equal(preset, JsonSerializer.Deserialize<UserSettings>(json)!.AreaPreset);

    [Fact]
    public void SavedPresetWinsOverTheRegion()
    {
        // Özel seçilip bölge alttakine denk getirilse de Özel kalır.
        var json = JsonSerializer.Serialize(new UserSettings().WithCustomRegion(new CropRegion()));
        Assert.Contains("\"AreaPreset\":\"Custom\"", json);
        Assert.Equal(AreaPreset.Custom, JsonSerializer.Deserialize<UserSettings>(json)!.AreaPreset);
        Assert.Equal(AreaPreset.Top, JsonSerializer.Deserialize<UserSettings>("""{"AreaPreset":"top"}""")!.AreaPreset);
    }

    [Fact]
    public void ChoosingAPresetSetsTheRegion()
    {
        var top = new UserSettings().WithAreaPreset(AreaPreset.Top);
        Assert.Equal(AreaPreset.Top, top.AreaPreset);
        Assert.Equal(new CropRegion(0.03, 0.38, 0.14, 0.86), top.Region);
        // Özel, kayıtlı bölgeyi değiştirmez.
        var custom = top.WithAreaPreset(AreaPreset.Custom);
        Assert.Equal(AreaPreset.Custom, custom.AreaPreset);
        Assert.Equal(top.Region, custom.Region);
    }

    [Fact]
    public void EditedRegionIsCustom()
    {
        var region = new CropRegion().WithVertical(40, 20);
        var settings = new UserSettings().WithAreaPreset(AreaPreset.Full).WithCustomRegion(region);
        Assert.Equal(AreaPreset.Custom, settings.AreaPreset);
        Assert.Equal(region, settings.Region);
    }

    [Fact]
    public void PresetIsKeptByTheController()
    {
        var store = new MemorySettings();
        var controller = AppControllerTests.Make(settings: store);
        controller.Settings = controller.Settings.WithAreaPreset(AreaPreset.Full);
        Assert.Equal(AreaPreset.Full, store.Saved?.AreaPreset);
        Assert.Equal(new CropRegion(0, 1, 0, 1), AppControllerTests.Make(settings: store).Settings.Region);
    }
}
