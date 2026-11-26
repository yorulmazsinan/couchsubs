// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// #1251: telefon ekranda görünürken otomatik okumadan hiç satır gelmiyordu ve günlük de sessizdi. Telefonun açılıp kapanması,
/// oynadığı için açılmaması, turun atlanması ve eğik ekranın boş okunması artık sınırlı satırlarla günlüğe yazılır
/// (Mac/iPhone ve Android ile aynı metinler).
/// </summary>
public class PhoneTraceTrackerTests
{
    [Fact]
    public void TrackerLogsOpeningClosingAndAMovingPhoneOncePerMinute()
    {
        var log = new List<string>();
        var frame = Frame.Blank(2, 2);
        CropRegion? candidate = new(0.15, 0.83, 0.32, 0.58);
        var tracker = new GamePhoneTracker(_ => candidate) { Log = log.Add };
        long time = 0;
        void Sample() { time += 400; tracker.TrySample(frame, time, out _); }

        Sample();
        Sample();
        Assert.Equal(["düşen satır [PhoneTrace] telefon açıldı: \"\""], log);
        candidate = null;
        for (var i = 0; i < 3; i++) Sample();
        Assert.Equal("düşen satır [PhoneTrace] telefon kapandı (1200 ms görülmedi, 3 ıska): \"\"", log[^1]);

        // Elde sallanan telefon: her örnekte %10 kayıyor, iki uyumlu gözlem olmadığı için hiç açılmıyor.
        log.Clear();
        var shift = 0.0;
        for (var i = 0; i < 6; i++)
        {
            shift = shift == 0 ? 0.1 : 0;
            candidate = new(0.15 + shift, 0.83 + shift, 0.32, 0.58);
            Sample();
        }
        Assert.Equal(["düşen satır [PhoneTrace] telefon oynuyor, açılmadı (%10 oynama): \"\""], log);
        // Aynı satır 60 sn sonra yeniden yazılır.
        time += DropLog.RepeatMs;
        shift = shift == 0 ? 0.1 : 0;
        candidate = new(0.15 + shift, 0.83 + shift, 0.32, 0.58);
        Sample();
        Assert.Equal(2, log.Count);
    }

    [Fact]
    public void ShiftIsTheLargestEdgeMove()
    {
        Assert.Equal(0.07, PhoneTrace.Shift(new CropRegion(0.1, 0.8, 0.3, 0.6), new CropRegion(0.12, 0.8, 0.37, 0.6)), 6);
        Assert.Equal(7, PhoneTrace.Percent(0.07));
    }
}

public partial class RegionWatcherTests
{
    private static (WatchedArea Area, Frame Frame) PosedPhone(CancellationToken lifetime, double offset = 0)
    {
        var frame = GamePhoneTrackerTests.PhoneFrame();
        Assert.True(GamePhoneGeometry.TryLocate(frame, out var pose));
        var bounds = pose.Bounds;
        var region = new CropRegion(bounds.Top + offset, bounds.Bottom + offset, bounds.Left, bounds.Right);
        return (new WatchedArea("game-phone", "Phone", region) { PanelLifetime = lifetime, PhonePose = pose }, frame);
    }

    private static async Task<List<string>> PhoneTurns(WatchedArea area, Frame frame, ITextReader reader, int turns, long step = 1000)
    {
        var log = new List<string>();
        long clock = 0;
        var watcher = new RegionWatcher(reader, new Translator(), new Server(), clock: () => clock)
        {
            Log = line => { lock (log) log.Add(line); },
        };
        for (var i = 0; i < turns; i++)
        {
            clock += step;
            watcher.Offer(frame, [area]);
            await WaitForPass(watcher);
        }
        return log;
    }

    [Fact]
    public async Task PhoneTurnSkippedBecauseThePhoneMovedIsLogged()
    {
        using var lifetime = new CancellationTokenSource();
        var (area, frame) = PosedPhone(lifetime.Token, offset: 0.1);
        var log = await PhoneTurns(area, frame, new Reader { Lines = [Line("Where are you?")] }, 3);
        Assert.Equal(["düşen satır [PhoneTrace] telefon karede yerinde değil, tur atlandı (%10 oynama): \"Phone\""], log);
    }

    [Fact]
    public async Task PhoneTurnSkippedBecauseThePhoneIsGoneIsLoggedOncePerMinute()
    {
        using var lifetime = new CancellationTokenSource();
        var (area, _) = PosedPhone(lifetime.Token);
        var log = await PhoneTurns(area, Frame.Blank(400, 225), new Reader(), 4, step: 20_000);
        Assert.Equal(2, log.Count);
        Assert.All(log, line => Assert.Equal("düşen satır [PhoneTrace] PhoneMissing: telefon bu karede bulunamadı, tur atlandı: \"Phone\"", line));
    }

    [Fact]
    public async Task EmptyStraightenedPhoneReadingIsLogged()
    {
        using var lifetime = new CancellationTokenSource();
        var (area, frame) = PosedPhone(lifetime.Token);
        var reader = new Reader();
        var log = await PhoneTurns(area, frame, reader, 2);
        Assert.True(reader.Count > 0);
        Assert.Contains("düşen satır [PhoneTrace] eğik ekran düzeltilmiş okuması boş: \"Phone\"", log);
    }
}
