// SPDX-License-Identifier: AGPL-3.0-only
using System.Runtime.CompilerServices;
using System.Text.Json;
using Xunit.Abstractions;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Ekran kilidi (Sinan Bey: "stabil olsun artık"): bütün ekran okuması her turda her bloğun kutusuna yeniden karar
/// veriyordu; kutular titriyor, yer değiştiriyor, kalkıp geliyordu. Kararlı ekran kilitlenir; küçük değişiklikte (imleç,
/// sayaç, bir bloğun yazısı) kutu taşınmaz, eklenmez, kalkmaz; ekran gerçekten değişince bir kez yeniden kurulur; aynı ekrana
/// dönülünce önbellekten aynı kutularla çizilir. Gerçek GTA 6 kareleri ve kayıtlı okumalar art arda turlarla
/// (core/Tests/CouchSubsCoreTests/Fixtures/screen-lock.json; Mac/iPhone ScreenLockTests.swift ve Android ScreenLockTest.kt aynı).
/// </summary>
public class ScreenLockTests(ITestOutputHelper output)
{
    private static string FramesDirectory([CallerFilePath] string source = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..", "testdata", "frames"));

    private static TextBox Box(JsonElement element)
    {
        var b = element.EnumerateArray().Select(v => v.GetDouble()).ToArray();
        return new TextBox(b[0], b[1], b[2], b[3]);
    }

    private static TextBox Box(double[] b) => new(b[0], b[1], b[2], b[3]);

    private sealed record Line(string Text, double[]? Box, double? Confidence, List<(string Text, double[] Box)>? Words);
    private sealed record Area(bool Menu, CropRegion Region, List<Line> Lines);
    private sealed record Screen(Frame Image, List<Area> Areas);
    private sealed record Pass(int? Jitter, List<string> Drop, List<(string From, string To)> Edit);
    private sealed record Segment(string? Screen, int IdBase, List<Pass> Passes);

    private static JsonDocument Plan() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("screen-lock.json")));

    private static List<Segment> Segments(JsonDocument plan) =>
        [.. plan.RootElement.GetProperty("segments").EnumerateArray().Select(segment => new Segment(
            segment.GetProperty("screen").ValueKind == JsonValueKind.Null ? null : segment.GetProperty("screen").GetString(),
            segment.GetProperty("idBase").GetInt32(),
            [.. segment.GetProperty("passes").EnumerateArray().Select(pass => new Pass(
                pass.TryGetProperty("jitter", out var jitter) ? jitter.GetInt32() : null,
                pass.TryGetProperty("drop", out var drop) ? [.. drop.EnumerateArray().Select(d => d.GetString()!)] : [],
                pass.TryGetProperty("edit", out var edit)
                    ? [.. edit.EnumerateArray().Select(e => (e[0].GetString()!, e[1].GetString()!))]
                    : []))]))];

    private static Screen LoadScreen(string id)
    {
        var directory = FramesDirectory();
        using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "ocr", "screen", id + ".json")));
        var areas = new List<Area>();
        foreach (var area in fixture.RootElement.GetProperty("areas").EnumerateArray())
        {
            var lines = area.GetProperty("lines").EnumerateArray().Select(line => new Line(line.GetProperty("text").GetString()!,
                line.TryGetProperty("box", out var box) ? [.. box.EnumerateArray().Select(v => v.GetDouble())] : null,
                line.TryGetProperty("confidence", out var confidence) ? confidence.GetDouble() : null,
                line.TryGetProperty("words", out var words)
                    ? [.. words.EnumerateArray().Select(word => (word.GetProperty("text").GetString()!,
                        word.GetProperty("box").EnumerateArray().Select(v => v.GetDouble()).ToArray()))]
                    : null)).ToList();
            if (lines.Count == 0) continue;
            var r = area.GetProperty("region").EnumerateArray().Select(v => v.GetDouble()).ToArray();
            areas.Add(new Area(area.TryGetProperty("menu", out var menu) && menu.GetBoolean(), new CropRegion(r[1], r[3], r[0], r[2]), lines));
        }
        return new Screen(Jpeg.Load(Path.Combine(directory, id + ".jpg")), areas);
    }

    /// <summary>Kayıtlı okumanın turdaki hâli (kural screen-lock.json'da).</summary>
    private static Reading ReadingOf(List<Line> lines, Pass pass)
    {
        var result = new List<TextLine>();
        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            if (pass.Drop.Contains(line.Text)) continue;
            var text = line.Text;
            foreach (var (from, to) in pass.Edit) if (from == line.Text) text = to;
            var index = i;
            TextBox Moved(double[] v)
            {
                if (pass.Jitter is not { } k) return Box(v);
                double dx = 0.002 * ((k + index) % 3 - 1), dy = 0.0015 * ((k + 2 * index) % 3 - 1);
                return new TextBox(v[0] + dx, v[1] + dy, v[2] + dx + 0.001 * (k % 2), v[3] + dy);
            }
            var words = text == line.Text ? line.Words?.Select(w => new TextWord(w.Text, Moved(w.Box))).ToList() : null;
            result.Add(new TextLine(text, line.Box is { } b ? Moved(b) : null, line.Confidence, words));
        }
        return new Reading(result);
    }

    private sealed class QueueReader : ITextReader
    {
        public Queue<Reading> Queue { get; } = new();
        public string Read(Frame image) => ReadLines(image, false).Text;
        public Reading ReadLines(Frame image, bool deep)
        {
            lock (Queue) return Queue.Count == 0 ? Reading.Empty : Queue.Dequeue();
        }
    }

    /// <summary>TV'nin gördüğü: alan alan çizili kutular.</summary>
    private sealed class Tv : IRegionSender
    {
        public Dictionary<string, List<(TextBox Box, string Text)>> Shown { get; } = [];
        public int Sends { get; private set; }
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight = null) =>
            SendRegion(id, text, box, lineHeight, null, null);
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight, IReadOnlyList<IconPlacement>? icons,
                               IReadOnlyList<ScreenTranslation.Item>? blocks)
        {
            lock (Shown)
            {
                Sends++;
                if (text.Length == 0) Shown.Remove(id);
                else Shown[id] = blocks is null ? [(box ?? default, text)] : [.. blocks.Select(item => (item.Box, item.Translation))];
            }
        }
        public void ClearRegions() { lock (Shown) Shown.Clear(); }
        public List<(TextBox Box, string Text)> Boxes() { lock (Shown) return [.. Shown.Values.SelectMany(v => v)]; }
    }

    internal sealed record Changes(int Added, int Moved, int Removed, int Retexted)
    {
        public int Boxes => Added + Moved + Removed;
        public static Changes operator +(Changes a, Changes b) =>
            new(a.Added + b.Added, a.Moved + b.Moved, a.Removed + b.Removed, a.Retexted + b.Retexted);
    }

    internal static Changes Compare(List<(TextBox Box, string Text)> old, List<(TextBox Box, string Text)> fresh)
    {
        var left = old.ToList();
        var added = new List<(TextBox Box, string Text)>();
        var retexted = 0;
        foreach (var item in fresh)
        {
            var i = left.FindIndex(o => o.Box == item.Box);
            if (i >= 0)
            {
                if (left[i].Text != item.Text) retexted++;
                left.RemoveAt(i);
            }
            else added.Add(item);
        }
        int moved = 0, newly = 0;
        foreach (var item in added)
        {
            var i = left.FindIndex(o => ScreenLock.Overlap(o.Box, item.Box) >= 0.3);
            if (i >= 0)
            {
                moved++;
                left.RemoveAt(i);
            }
            else newly++;
        }
        return new Changes(newly, moved, left.Count, retexted);
    }

    private sealed record Run(List<Changes> PerSegment, List<int> SendsPerSegment, Changes WhileLocked, List<int> UnlocksPerSegment,
                              int Locks, int Unlocks, int CacheHits, List<string> Log, int FinalShown);

    private static async Task<Run> ReplayAsync(bool screenLock)
    {
        using var plan = Plan();
        var passMs = plan.RootElement.GetProperty("passMs").GetInt32();
        var reader = new QueueReader();
        var tv = new Tv();
        long clock = 0;
        var log = new List<string>();
        var watcher = new RegionWatcher(reader, new FakeTranslator(), tv, passMs, () => clock)
        {
            LocksScreen = screenLock,
            RereadsEveryPass = true,
            Log = line => { lock (log) log.Add(line); },
        };
        var screens = new Dictionary<string, Screen>();
        var blank = LoadScreen("gta6-menu-gorevler").Image;
        var perSegment = new List<Changes>();
        var sends = new List<int>();
        var unlocksPer = new List<int>();
        var whileLocked = new Changes(0, 0, 0, 0);
        foreach (var segment in Segments(plan))
        {
            var total = new Changes(0, 0, 0, 0);
            var sendsBefore = tv.Sends;
            var unlocksBefore = watcher.ScreenLock.Unlocks;
            foreach (var pass in segment.Passes)
            {
                var areas = new List<WatchedArea>();
                var image = blank;
                if (segment.Screen is { } id)
                {
                    if (!screens.TryGetValue(id, out var screen)) screens[id] = screen = LoadScreen(id);
                    image = screen.Image;
                    for (var k = 0; k < screen.Areas.Count; k++)
                    {
                        var area = screen.Areas[k];
                        areas.Add(new WatchedArea($"auto-{segment.IdBase + k}", "Screen text", area.Region) { Auto = true, Menu = area.Menu });
                        reader.Queue.Enqueue(ReadingOf(area.Lines, pass));
                    }
                }
                var before = tv.Boxes();
                var lockedBefore = watcher.ScreenLock.Locked;
                var unlocks = watcher.ScreenLock.Unlocks;
                await watcher.PassAsync(image, areas);
                Assert.Empty(reader.Queue);
                clock += passMs;
                var change = Compare(before, tv.Boxes());
                total += change;
                if (lockedBefore && watcher.ScreenLock.Locked && watcher.ScreenLock.Unlocks == unlocks) whileLocked += change;
            }
            perSegment.Add(total);
            sends.Add(tv.Sends - sendsBefore);
            unlocksPer.Add(watcher.ScreenLock.Unlocks - unlocksBefore);
        }
        return new Run(perSegment, sends, whileLocked, unlocksPer, watcher.ScreenLock.Locks, watcher.ScreenLock.Unlocks,
                       watcher.ScreenLock.CacheHits, log, tv.Boxes().Count);
    }

    /// <summary>
    /// Kilitliyken hiçbir kutu taşınmaz, eklenmez, kalkmaz; her ekran değişikliğinde tam bir yeniden kurulum; menüye dönülünce
    /// önbellek tutar. Kilitsiz hâlin sayıları önce/sonra karşılaştırması için yazdırılır.
    /// </summary>
    [Fact]
    public async Task ReplayOfMenusAndCardsKeepsLockedBoxesStill()
    {
        using var plan = Plan();
        var segments = Segments(plan);
        var expect = plan.RootElement.GetProperty("expect");
        var before = await ReplayAsync(false);
        var after = await ReplayAsync(true);
        for (var k = 0; k < segments.Count; k++)
        {
            var (b, a) = (before.PerSegment[k], after.PerSegment[k]);
            output.WriteLine($"ekran kilidi {segments[k].Screen ?? "(boş)"}: kutu değişikliği önce {b.Boxes} (ekle {b.Added}, taşı {b.Moved}, "
                             + $"kaldır {b.Removed}), sonra {a.Boxes} (ekle {a.Added}, taşı {a.Moved}, kaldır {a.Removed}); "
                             + $"gönderi önce {before.SendsPerSegment[k]}, sonra {after.SendsPerSegment[k]}");
        }
        var lines = after.Log.Where(line => line.StartsWith("ekran kilidi", StringComparison.Ordinal)).ToList();
        foreach (var line in lines) output.WriteLine(line);
        Assert.Equal(new Changes(0, 0, 0, 0), after.WhileLocked);
        Assert.Equal(expect.GetProperty("locks").GetInt32(), after.Locks);
        Assert.Equal(expect.GetProperty("unlocks").GetInt32(), after.Unlocks);
        Assert.Equal(expect.GetProperty("cacheHits").GetInt32(), after.CacheHits);
        // Kilitli ekrandan sonra gelen her bölümde (başka ekran ya da yazının kalkması) tam bir yeniden kurulum.
        for (var k = 1; k < segments.Count; k++)
            if (segments[k - 1].Screen is not null)
                Assert.Equal(expect.GetProperty("rebuildsPerChange").GetInt32(), after.UnlocksPerSegment[k]);
        // Her kilit ve açılış günlükte nedeni ve blok sayısıyla.
        Assert.Equal(after.Locks + after.Unlocks, lines.Count);
        Assert.All(lines, line => Assert.Contains(" blok", line));
        Assert.True(after.PerSegment.Sum(c => c.Boxes) < before.PerSegment.Sum(c => c.Boxes));
        Assert.True(after.FinalShown > 0);
    }

    // Kilit kuralları (ScreenLock tek başına).

    private static ScreenLock.Block Block(string key, double top) => new(key, new TextBox(0.1, top, 0.4, top + 0.04));

    private static ScreenTranslation.Item Item(string source, ScreenLock.Block block) => new(source, "TR " + source, block.Box, 0.04);

    private static ScreenLock.Payload PayloadOf(IReadOnlyList<ScreenTranslation.Item> items) =>
        new(string.Join("\n", items.Select(i => i.Translation)), items.FirstOrDefault()?.Box, 0.04, null, items);

    private static readonly string[] Menu = ["resume", "map", "brief", "settings", "quit game"];

    private static List<ScreenLock.Block> ScreenOf(IReadOnlyList<string>? texts = null, double dy = 0) =>
        [.. (texts ?? Menu).Select((text, i) => Block(text, 0.1 + 0.08 * i + dy))];

    [Fact]
    public void LocksAfterTwoSteadyPassesAndHoldsBoxesThroughSmallChanges()
    {
        var lockOn = new ScreenLock();
        var log = new List<string>();
        lockOn.Log = log.Add;
        var blocks = ScreenOf();
        Assert.Single(lockOn.Offer("auto-1", PayloadOf([.. blocks.Select(b => Item(b.Key, b))])));
        Assert.Empty(lockOn.Observe(blocks, 0));
        Assert.False(lockOn.Locked);
        Assert.Empty(lockOn.Observe(ScreenOf(dy: 0.002), 500));
        Assert.True(lockOn.Locked);
        Assert.Equal(["ekran kilidi: kilitlendi, 5 blok (5 çevirili)"], log);
        // Kutusu oynayan, bir satırı eksik ve yeni bir blokla gelen gönderi: kutu taşınmaz, kalkmaz, eklenmez.
        var moved = ScreenOf(dy: 0.004).Select(b => Item(b.Key, b)).ToList();
        moved.RemoveAt(moved.Count - 1);
        moved.Add(Item("tooltip", Block("tooltip", 0.8)));
        Assert.Empty(lockOn.Offer("auto-1", PayloadOf(moved)));
        Assert.Empty(lockOn.Offer("auto-1", null));
        Assert.Empty(lockOn.Offer("auto-2", PayloadOf([Item("tooltip", Block("tooltip", 0.8))])));
        Assert.Equal(blocks.Select(b => b.Box), lockOn.Displayed("auto-1")!.Blocks!.Select(i => i.Box));
        // Bir blokta yazı değişti (sayaç): iki tur aynı okunmadan güncellenmez; sonra yalnız yazı güncellenir, kutu aynı.
        var ticked = ScreenOf();
        ticked[1] = ticked[1] with { Key = "map 2" };
        Assert.Empty(lockOn.Observe(ticked, 1000));
        Assert.Empty(lockOn.Offer("auto-1", PayloadOf([Item("map 2", ticked[1])])));
        var sends = lockOn.Observe(ticked, 1500);
        Assert.Single(sends);
        Assert.Equal(blocks.Select(b => b.Box), sends[0].Payload!.Blocks!.Select(i => i.Box));
        Assert.Equal("TR map 2", sends[0].Payload!.Blocks![1].Translation);
        Assert.True(lockOn.Locked);
        Assert.Equal(0, lockOn.Unlocks);
    }

    [Fact]
    public void UnlocksOnceWhenTheScreenReallyChangesAndShowsTheNewScreen()
    {
        var lockOn = new ScreenLock();
        var log = new List<string>();
        lockOn.Log = log.Add;
        var first = ScreenOf();
        lockOn.Offer("auto-1", PayloadOf([.. first.Select(b => Item(b.Key, b))]));
        lockOn.Observe(first, 0);
        lockOn.Observe(first, 500);
        Assert.True(lockOn.Locked);
        // İki blok (5'te 2, %40) değişti: tek tur yetmez, ikinci turda açılır; izleyicinin yeni ekranı çizilir.
        string[] otherTexts = ["resume", "map", "brief", "graphics", "audio"];
        var other = ScreenOf(otherTexts);
        Assert.Empty(lockOn.Observe(other, 1000));
        Assert.True(lockOn.Locked);
        Assert.Empty(lockOn.Offer("auto-1", PayloadOf([.. other.Select(b => Item(b.Key, b))])));
        var sends = lockOn.Observe(other, 1500);
        Assert.Equal(1, lockOn.Unlocks);
        Assert.Equal(["auto-1"], sends.Select(s => s.Id));
        Assert.Equal("TR audio", sends[0].Payload!.Blocks![^1].Translation);
        var unlocked = log.Where(l => l.StartsWith("ekran kilidi açıldı", StringComparison.Ordinal)).ToList();
        Assert.Single(unlocked);
        Assert.StartsWith("ekran kilidi açıldı: ekran değişti", unlocked[0]);
        Assert.EndsWith("5 blok", unlocked[0]);
        // Yeni ekran iki turdur aynı okunuyordu: çizildiği anda kilitlenir (tek yeniden kurulum).
        Assert.True(lockOn.Locked);
        Assert.Equal(2, lockOn.Locks);
        Assert.Empty(lockOn.Observe(other, 2000));
        // Yerleşim kaydı (aynı yazılar başka yerde) da açar; aynı yazı kümesi önbellekte olsa da eski kutular çizilmez.
        var shifted = ScreenOf(otherTexts, 0.5);
        lockOn.Observe(shifted, 2500);
        lockOn.Observe(shifted, 3000);
        Assert.Equal(2, lockOn.Unlocks);
        Assert.Equal(0, lockOn.CacheHits);
        Assert.Contains(log, l => l.StartsWith("ekran kilidi açıldı: yerleşim değişti (5 blok başka yerde)", StringComparison.Ordinal));
    }

    [Fact]
    public void ClearsWhenScreenTextIsGoneForMoreThanASecondAndRedrawsFromCache()
    {
        var lockOn = new ScreenLock();
        var blocks = ScreenOf();
        var items = blocks.Select(b => Item(b.Key, b)).ToList();
        lockOn.Offer("auto-1", PayloadOf(items));
        lockOn.Observe(blocks, 0);
        lockOn.Observe(blocks, 500);
        Assert.True(lockOn.Locked);
        Assert.Empty(lockOn.Observe([], 1000));
        Assert.Empty(lockOn.Observe([], 1500));
        Assert.Empty(lockOn.Observe([], 2000));
        var cleared = lockOn.Observe([], 2500);
        Assert.Equal([new ScreenLock.Send("auto-1", null, true)], cleared);
        Assert.False(lockOn.Locked);
        Assert.Empty(lockOn.DisplayedIds);
        // Aynı ekrana dönüldü (dedektör yeni kimlik verdi): ilk okumada aynı kutular ve çevirilerle çizilir.
        var back = lockOn.Observe(ScreenOf(dy: 0.003), 3000);
        Assert.True(lockOn.Locked);
        Assert.Equal(1, lockOn.CacheHits);
        Assert.Single(back);
        Assert.Equal(items, back[0].Payload!.Blocks);
        // İzleyicinin yeni kimlikle gönderdiği aynı ekran ikinci kutu açmaz.
        Assert.Empty(lockOn.Offer("auto-7", PayloadOf([.. ScreenOf(dy: 0.003).Select(b => Item(b.Key, b))])));
    }

    [Fact]
    public void MissionNoticeAndPhoneStayOutOfTheLock()
    {
        Assert.True(ScreenLock.Covers("auto-3"));
        Assert.False(ScreenLock.Covers(MissionLine.AreaId));
        Assert.False(ScreenLock.Covers(ScreenNotices.IdPrefix + "1"));
        Assert.False(ScreenLock.Covers("game-phone"));
        Assert.False(ScreenLock.Covers("preset-help"));
    }
}
