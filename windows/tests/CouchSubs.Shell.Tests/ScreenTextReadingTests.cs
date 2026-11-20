// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.Shell.Tests;

/// <summary>Otomatik ekran yazıları: dedektörün bulduğu kutu ek alan okuyucusuyla yerinde çevrilir.</summary>
public class ScreenTextReadingTests
{
    // Koyu zeminde sol üstte beyaz "yazı" çizgili kutu; altyazı alanının dışında.
    private static Frame BoxFrame()
    {
        var frame = Frame.Blank(640, 360);
        Array.Fill(frame.Pixels, (byte)90);
        for (var y = 20; y < 80; y++)
            for (var x = 20; x < 180; x++)
            {
                var p = y * frame.Stride + x * 4;
                var value = (byte)((y - 20) % 9 is 3 or 4 && (x - 20) % 7 < 4 ? 240 : 24);
                frame.Pixels[p] = frame.Pixels[p + 1] = frame.Pixels[p + 2] = value;
            }
        return frame;
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task FoundTextBoxIsTranslatedInPlaceOnlyWhenEnabled(bool enabled)
    {
        var services = new FakeServices { ReaderLines = Reading.FromText("Follow Paulie to the car.") };
        var settings = new MemorySettings();
        settings.Save(new UserSettings { FrameSource = FrameSource.RemotePlayWindow, Output = SubtitleOutput.Computer, AutoScreenText = enabled, AutoScreenTextReset = true });
        using var controller = AppControllerTests.Make(services, settings: settings);
        var events = new ConcurrentQueue<SubtitleEvent>();
        controller.StreamEvent += events.Enqueue;
        await controller.StartAsync();
        var frame = BoxFrame();
        var until = DateTime.UtcNow + TimeSpan.FromSeconds(enabled ? 6 : 2);
        bool Found() => events.Any(e => e.Kind == SubtitleEventKind.Region && e.Id?.StartsWith("auto-") == true && e.Text.Length > 0);
        while (DateTime.UtcNow < until && !Found())
        {
            services.Streams[0].Emit(frame);
            await Task.Delay(50);
        }
        Assert.Equal(enabled, Found());
        controller.Stop();
    }
}
