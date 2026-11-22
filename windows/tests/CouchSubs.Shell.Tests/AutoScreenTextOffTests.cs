// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.Shell.Tests;

/// <summary>
/// Saha (beta.63/64): "otomatik çeviri kapalıyken de bütün ekranı çeviriyor; Gelişmiş'teki iki ayarı açıp kapatınca hep
/// tam çeviri". Otomatik ekran yazısı kapalıyken altyazı alanı dışında hiçbir yazı çevrilmez; Gelişmiş ayarların aç-kapa
/// gidiş-dönüşü kalıcı bir durum bırakmaz.
/// </summary>
public class AutoScreenTextOffTests
{
    // Koyu zeminde sol üstte beyaz "yazı" çizgili kutu; altyazı alanının dışında (ScreenTextReadingTests ile aynı).
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

    private static bool AutoShown(IEnumerable<SubtitleEvent> events) =>
        events.Any(e => e.Kind == SubtitleEventKind.Region && ScreenTextAreas.IsAuto(e.Id) && e.Text.Length > 0);

    private static async Task Feed(FakeServices services, Frame frame, TimeSpan time, Func<bool>? until = null)
    {
        var end = DateTime.UtcNow + time;
        while (DateTime.UtcNow < end && until?.Invoke() != true)
        {
            services.Streams[0].Emit(frame);
            await Task.Delay(50);
        }
    }

    [Fact]
    public async Task AdvancedSettingsRoundTripLeavesNoLastingStateAndNothingOutsideTheSubtitleArea()
    {
        var services = new FakeServices { ReaderLines = Reading.FromText("Follow Paulie to the car.") };
        var store = new MemorySettings();
        var start = new UserSettings
        {
            FrameSource = FrameSource.RemotePlayWindow, Output = SubtitleOutput.Computer,
            AutoScreenText = false, AutoScreenTextReset = true,
        }.WithAreaPreset(AreaPreset.Bottom);
        store.Save(start);
        using var controller = AppControllerTests.Make(services, settings: store);
        var events = new ConcurrentQueue<SubtitleEvent>();
        controller.StreamEvent += events.Enqueue;
        await controller.StartAsync();

        // Gelişmiş'teki ayar açılır, kare gelir, sonra kapatılır (sahadaki sıra).
        controller.Settings = controller.Settings with { FastSubtitleDetection = true };
        await Feed(services, BoxFrame(), TimeSpan.FromSeconds(1));
        controller.Settings = controller.Settings with { FastSubtitleDetection = false };
        await Feed(services, BoxFrame(), TimeSpan.FromSeconds(2));

        // Altyazı alanı dışındaki kutu hiçbir zaman çevrilmedi; alan ve diğer ayarlar başlangıçtaki gibi.
        Assert.False(AutoShown(events));
        var now = controller.Settings;
        Assert.Equal(start.Region, now.Region);
        Assert.Equal(AreaPreset.Bottom, now.AreaPreset);
        Assert.False(now.AutoScreenText);
        Assert.False(now.FastSubtitleDetection);
        Assert.Null(now.ActiveAreaProfile);
        Assert.Equal(start.Areas, now.Areas);
        // Kayıtlı dosya da aynı.
        Assert.Equal(now, store.Load());
        controller.Stop();
    }

    [Fact]
    public async Task TurningAutoScreenTextOffRemovesItsBoxesAndStopsFindingNewOnes()
    {
        var services = new FakeServices { ReaderLines = Reading.FromText("Follow Paulie to the car.") };
        var store = new MemorySettings();
        store.Save(new UserSettings
        {
            FrameSource = FrameSource.RemotePlayWindow, Output = SubtitleOutput.Computer,
            AutoScreenText = true, AutoScreenTextReset = true,
        });
        using var controller = AppControllerTests.Make(services, settings: store);
        // Sahte okuyucu altyazıya ve alana aynı yazıyı verir; altyazı yinelemesi engeli burada sınanmıyor.
        controller.SubtitleEcho = null;
        var events = new ConcurrentQueue<SubtitleEvent>();
        controller.StreamEvent += events.Enqueue;
        await controller.StartAsync();
        await Feed(services, BoxFrame(), TimeSpan.FromSeconds(6), () => AutoShown(events));
        Assert.True(AutoShown(events));
        var shownId = events.Last(e => e.Kind == SubtitleEventKind.Region && ScreenTextAreas.IsAuto(e.Id) && e.Text.Length > 0).Id;

        controller.Settings = controller.Settings with { AutoScreenText = false };
        await Feed(services, BoxFrame(), TimeSpan.FromSeconds(2));
        // Kutu kalktı (boş region ya da hepsini kaldırma) ve ayar kapalıyken yeni otomatik kutu gelmedi.
        var after = events.ToList();
        var offAt = after.FindLastIndex(e => (e.Kind == SubtitleEventKind.Region && e.Id == shownId && e.Text.Length == 0)
                                             || e.Kind == SubtitleEventKind.RegionClear);
        Assert.True(offAt >= 0, "otomatik kutu kaldırılmadı");
        Assert.False(AutoShown(after.Skip(offAt + 1)));
        controller.Stop();
    }
}
