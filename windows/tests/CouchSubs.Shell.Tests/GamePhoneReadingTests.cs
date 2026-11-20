// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Text.Json;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.Shell.Tests;

public class GamePhoneReadingTests
{
    [Fact]
    public void ExistingSettingsDefaultToOffAndThePreferenceRoundTrips()
    {
        Assert.False(JsonSerializer.Deserialize<UserSettings>("{}")!.AutoReadGamePhone);
        var json = JsonSerializer.Serialize(new UserSettings { AutoReadGamePhone = true });
        Assert.True(JsonSerializer.Deserialize<UserSettings>(json)!.AutoReadGamePhone);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task NormalSubtitleStillReachesTheDisplayWhenNoPhoneIsBeingRead(bool featureEnabled)
    {
        var services = new FakeServices { ReaderLines = Reading.FromText("Hold the gate") };
        var settings = new MemorySettings();
        // Otomatik ekran yazıları kapalı: telefon karesindeki yazılar ayrı okuyucu açmasın (bkz. ScreenTextReadingTests).
        settings.Save(new UserSettings { FrameSource = FrameSource.RemotePlayWindow, Output = SubtitleOutput.Computer, AutoReadGamePhone = featureEnabled, AutoScreenText = false });
        using var controller = AppControllerTests.Make(services, settings: settings);
        var events = new ConcurrentQueue<SubtitleEvent>();
        controller.StreamEvent += events.Enqueue;
        controller.ChooseGame("GTA 6");
        await controller.StartAsync();
        int readers = services.ReaderLanguages.Count;
        var frame = featureEnabled ? Frame.Blank(400, 225) : PhoneFrame();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!events.Any(e => e.Kind == SubtitleEventKind.Subtitle && e.Text == "TR: Hold the gate"))
        {
            services.Streams[0].Emit(frame);
            await Task.Delay(40, timeout.Token);
        }
        Assert.Equal(readers, services.ReaderLanguages.Count);
        Assert.DoesNotContain(events, e => e.Kind == SubtitleEventKind.Region && e.Id == "game-phone");
    }

    [Fact]
    public async Task OpensOnlyInTheSelectedGameAndClearsOnlyThePhoneWhenDisabled()
    {
        var services = new FakeServices { ReaderLines = Reading.FromText("Call me tomorrow.") };
        var settings = new MemorySettings();
        settings.Save(new UserSettings { FrameSource = FrameSource.RemotePlayWindow, Output = SubtitleOutput.Computer, AutoScreenText = false });
        var controller = AppControllerTests.Make(services, settings: settings);
        var events = new ConcurrentQueue<SubtitleEvent>();
        controller.StreamEvent += events.Enqueue;
        var frame = PhoneFrame();
        try
        {
            await controller.StartAsync();
            var stream = Assert.Single(services.Streams);
            var mainReaders = services.ReaderLanguages.Count;
            controller.ChooseGame("Grand Theft Auto VI");
            stream.Emit(frame);
            await Task.Delay(360);
            stream.Emit(frame);
            Assert.Equal(mainReaders, services.ReaderLanguages.Count);

            controller.ChooseGame("Far Cry 3");
            controller.Settings = controller.Settings with { AutoReadGamePhone = true };
            stream.Emit(frame);
            await Task.Delay(360);
            stream.Emit(frame);
            Assert.Equal(mainReaders, services.ReaderLanguages.Count);

            controller.ChooseGame("GTA 6");
            stream.Emit(Frame.Blank(frame.Width, frame.Height));
            await Task.Delay(360);
            stream.Emit(frame);
            Assert.Equal(mainReaders, services.ReaderLanguages.Count);

            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(7));
            while (!events.Any(e => e.Kind == SubtitleEventKind.Region && e.Id == "game-phone" && e.Text?.Length > 0))
            {
                await Task.Delay(120, timeout.Token);
                stream.Emit(frame);
            }
            Assert.Equal(mainReaders + 1, services.ReaderLanguages.Count);
            events.Clear();
            controller.Settings = controller.Settings with { AutoReadGamePhone = false };
            Assert.Contains(events, e => e.Kind == SubtitleEventKind.Region && e.Id == "game-phone" && e.Text == "");
            Assert.DoesNotContain(events, e => e.Kind == SubtitleEventKind.RegionClear);
        }
        finally { controller.Stop(); }
    }

    // Kayıt gerektirmeden kasa kenarları, iki hoparlör yarığı ve ön kamerayla gerçek algılayıcıyı çalıştırır.
    private static Frame PhoneFrame()
    {
        var frame = Frame.Blank(400, 225);
        void Fill(int x, int y, int width, int height, byte value)
        {
            for (var row = y; row < y + height; row++)
                Array.Fill(frame.Pixels, value, row * frame.Stride + x * 4, width * 4);
        }
        Fill(158, 42, 84, 157, 180);
        Fill(164, 52, 73, 138, 80);
        Fill(194, 47, 12, 2, 20);
        Fill(210, 47, 2, 2, 20);
        Fill(196, 192, 8, 2, 20);
        return frame;
    }
}
