// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Text.Json;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.Shell.Tests;

/// <summary>Oyuna göre hazır ek alanlar: ne zaman eklenir, ne zaman kalkar.</summary>
public class GameAreaPresetTests
{
    private static IEnumerable<string> Ids(IReadOnlyList<WatchedArea> areas) => areas.Select(area => area.Id);

    [Fact]
    public void Gta6GetsBothAreasWhenTheUserHasNone() =>
        Assert.Equal(["preset-help", "preset-phone"], Ids(new UserSettings().PresetAreas("GTA 6", phoneOpen: false)));

    [Fact]
    public void UserAreaOffSettingFullScreenAndProfileTurnThemOff()
    {
        var own = new UserSettings().WithExtraRegion(1, ExtraAreaPreset.Quest.Region()).WithExtraLive(1, true);
        Assert.Empty(own.PresetAreas("GTA 6", false));
        Assert.Empty((new UserSettings() with { GameAreaPresets = false }).PresetAreas("GTA 6", false));
        Assert.Empty(new UserSettings().WithAreaPreset(AreaPreset.Full).PresetAreas("GTA 6", false));
        Assert.Empty((new UserSettings() with { ActiveAreaProfile = "gta 6|window" }).PresetAreas("GTA 6", false));
        Assert.Empty(new UserSettings().PresetAreas("Red Dead Redemption 2", false));
        // Kapalı (sürekli okunmayan) kullanıcı alanı hazır alanları engellemez.
        Assert.Equal(2, new UserSettings().WithExtraRegion(1, ExtraAreaPreset.Quest.Region()).PresetAreas("GTA 6", false).Count);
    }

    [Fact]
    public void OpenPhoneLeavesOnlyTheHelpArea() =>
        Assert.Equal(["preset-help"], Ids(new UserSettings().PresetAreas("GTA 6", phoneOpen: true)));

    [Fact]
    public void OldSettingsTurnPresetsOn()
    {
        Assert.True(JsonSerializer.Deserialize<UserSettings>("{}")!.GameAreaPresets);
        var off = JsonSerializer.Serialize(new UserSettings() with { GameAreaPresets = false });
        Assert.False(JsonSerializer.Deserialize<UserSettings>(off)!.GameAreaPresets);
    }

    private static Frame PanelFrame()
    {
        var frame = Frame.Blank(400, 225);
        Array.Fill(frame.Pixels, (byte)120);
        for (var y = 8; y < 60; y++)
            for (var x = 6; x < 140; x++)
            {
                var p = y * frame.Stride + x * 4;
                var value = (byte)(((y >= 16 && y < 26) || (y >= 34 && y < 44)) && x % 7 < 3 ? 235 : 26);
                frame.Pixels[p] = frame.Pixels[p + 1] = frame.Pixels[p + 2] = value;
            }
        return frame;
    }

    [Fact]
    public async Task PresetAreaWithoutAnInterfacePanelShowsNothing()
    {
        // Oyun yanlış seçili (GTA 6) ama ekranda arayüz kutusu yok: hazır alan hiçbir şey çevirmez.
        var services = new FakeServices { ReaderLines = Reading.FromText("Follow Paulie to the car.") };
        var settings = new MemorySettings();
        settings.Save(new UserSettings { FrameSource = FrameSource.RemotePlayWindow, Output = SubtitleOutput.Computer, AutoScreenText = false,
                                         AutoScreenTextReset = true });
        using var controller = AppControllerTests.Make(services, settings: settings);
        var events = new ConcurrentQueue<SubtitleEvent>();
        controller.StreamEvent += events.Enqueue;
        controller.ChooseGame("GTA 6");
        await controller.StartAsync();
        var frame = Frame.Blank(400, 225);
        for (var i = 0; i < 40; i++)
        {
            services.Streams[0].Emit(frame);
            await Task.Delay(50);
        }
        Assert.DoesNotContain(events, e => e.Kind == SubtitleEventKind.Region && e.Text.Length > 0);
        controller.Stop();
    }

    [Fact]
    public async Task PresetAreasAreReadForGta6AndLeaveWhenTheGameChanges()
    {
        var services = new FakeServices { ReaderLines = Reading.FromText("Follow Paulie to the car.") };
        var settings = new MemorySettings();
        var userRegion = new CropRegion(0.70, 0.90, 0.20, 0.80);
        var overlay = new OverlayBounds(100, 600, 900);
        settings.Save(new UserSettings { FrameSource = FrameSource.RemotePlayWindow, Output = SubtitleOutput.Computer, AutoScreenText = false,
                                         AutoScreenTextReset = true, Overlay = overlay }.WithCustomRegion(userRegion));
        using var controller = AppControllerTests.Make(services, settings: settings);
        var events = new ConcurrentQueue<SubtitleEvent>();
        controller.StreamEvent += events.Enqueue;
        controller.ChooseGame("GTA 6");
        await controller.StartAsync();
        // Hazır alan ancak arayüz kutusu kanıtıyla okunur: sol üstte koyu panel üstünde beyaz yazı çizgileri.
        var frame = PanelFrame();
        bool Shown() => events.Any(e => e.Kind == SubtitleEventKind.Region && e.Id == "preset-help" && e.Text.Length > 0);
        using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(6)))
            while (!Shown())
            {
                services.Streams[0].Emit(frame);
                await Task.Delay(60, timeout.Token);
            }
        // Hazır alanlar kullanıcının altyazı alanını, ek alanlarını ve altyazı penceresinin yerini değiştirmez.
        Assert.Equal(userRegion, controller.Settings.Region);
        Assert.Equal(AreaPreset.Custom, controller.Settings.AreaPreset);
        Assert.Null(controller.Settings.ExtraRegion1);
        Assert.Equal(overlay, controller.Settings.Overlay);
        Assert.Equal(userRegion, settings.Load().Region);
        events.Clear();
        controller.ChooseGame("Far Cry 3");
        using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(6)))
            while (!events.Any(e => e.Kind is SubtitleEventKind.RegionClear
                       || (e.Kind == SubtitleEventKind.Region && e.Id == "preset-help" && e.Text.Length == 0)))
            {
                services.Streams[0].Emit(frame);
                await Task.Delay(60, timeout.Token);
            }
        controller.Stop();
    }
}
