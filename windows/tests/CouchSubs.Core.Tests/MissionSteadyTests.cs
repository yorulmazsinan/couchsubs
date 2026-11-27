// SPDX-License-Identifier: AGPL-3.0-only
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Sinan Bey (GTA 6, beta.105): görev kutusu ekranda kararsızdı: yanıp sönüyor, biçim değiştiriyor, yer değiştiriyor, bazen
/// altyazı olarak çevriliyordu. Gerçek kare okumalarıyla (testdata/frames/ocr: gta6-854-gorev-1/2/3, pencere-kare-2/5-gorev)
/// art arda okumalar: görev tek başına, konuşmayla birlikte, bir okumada görev satırı kaçıyor ("kare@0"), iki saniyelik boş
/// okuma, sonra görev gerçekten kalkıyor. Altyazı hattı ve görev kutusunu çizen ek alan ("auto-mission") birlikte koşar.
/// Mac/iPhone (MissionSteadyTests.swift) ve Android (MissionSteadyTest.kt) aynı okumalarla aynı sonucu verir.
/// </summary>
public class MissionSteadyTests
{
    private static readonly CropRegion SubtitleArea = new(0.62, 0.97, 0.14, 0.86);

    private static string Directory([CallerFilePath] string source = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..", "testdata", "frames"));

    private static TextBox Box(JsonElement element)
    {
        var b = element.EnumerateArray().Select(v => v.GetDouble()).ToArray();
        return new TextBox(b[0], b[1], b[2], b[3]);
    }

    /// <summary>"kare" kaydı olduğu gibi; "kare@0" karenin yalnız 0. satırı; "-" boş okuma.</summary>
    private static Reading ReadingOf(string id)
    {
        if (id == "-") return Reading.Empty;
        var parts = id.Split('@');
        using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(Directory(), "ocr", parts[0] + ".json")));
        var region = fixture.RootElement.GetProperty("region").EnumerateArray().Select(v => v.GetDouble()).ToArray();
        Assert.Equal([SubtitleArea.Left, SubtitleArea.Top, SubtitleArea.Right, SubtitleArea.Bottom], region);
        int? keep = parts.Length > 1 ? int.Parse(parts[1]) : null;
        return new Reading(fixture.RootElement.GetProperty("lines").EnumerateArray()
            .Select((line, index) => (line, index))
            .Where(pair => keep is null || pair.index == keep)
            .Select(pair => new TextLine(pair.line.GetProperty("text").GetString()!,
                pair.line.TryGetProperty("box", out var box) ? Box(box) : null,
                pair.line.TryGetProperty("confidence", out var confidence) ? confidence.GetDouble() : null,
                pair.line.TryGetProperty("words", out var words)
                    ? [.. words.EnumerateArray().Select(word => new TextWord(word.GetProperty("text").GetString()!, Box(word.GetProperty("box"))))]
                    : null))
            .ToList());
    }

    private sealed class FuncReader(Func<Reading> next) : ITextReader
    {
        public string Read(Frame image) => ReadLines(image, false).Text;
        public Reading ReadLines(Frame image, bool deep) => next();
    }

    private sealed class Overlay : IRegionSender
    {
        public List<(string Text, TextBox? Box)> Sent { get; } = [];
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight = null)
        {
            if (id == MissionLine.AreaId) lock (Sent) Sent.Add((text, box));
        }
        public void ClearRegions() { }
    }

    private sealed record Run(List<CropRegion?> Regions, int? SubtitlesBeforeMission, FakeSender Sender, List<string> Requested,
                              List<string> WatcherRequested, Overlay Overlay);

    private static Frame Shade(byte shade)
    {
        var frame = Frame.Blank(320, 180);
        Array.Fill(frame.Pixels, shade);
        return frame;
    }

    /// <summary>
    /// Altyazı hattı 250 ms'de bir okur; görev kutusunun alanı (varsa) 500 ms'de bir okunur ve alanın içindeki satırlar (aynı
    /// karenin okuması) alana oranla verilir.
    /// </summary>
    private static async Task<Run> RunAsync(IReadOnlyList<string> ids)
    {
        var frames = ids.Select(ReadingOf).ToList();
        long clock = 0;
        var index = 0;
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        var pipeline = new SubtitlePipeline(new FuncReader(() => frames[index]), translator, sender, clock: () => clock)
        { PackWait = 0, CleanWait = 0 };
        CropRegion? region = null;
        var regions = new List<CropRegion?>();
        pipeline.MissionChanged += next => { region = next; regions.Add(next); };
        var place = new TextBox(SubtitleArea.Left, SubtitleArea.Top, SubtitleArea.Right, SubtitleArea.Bottom);
        var watchTranslator = new FakeTranslator();
        var overlay = new Overlay();
        var watcher = new RegionWatcher(new FuncReader(() =>
        {
            if (region is not { } r) return Reading.Empty;
            double h = r.Bottom - r.Top, w = r.Right - r.Left;
            return new Reading(frames[index].Lines.Where(line => line.Box is { } b && b.PlacedIn(place).Top >= r.Top
                                                                && b.PlacedIn(place).Bottom <= r.Bottom)
                .Select(line =>
                {
                    var b = line.Box!.Value.PlacedIn(place);
                    return new TextLine(line.Text, new TextBox((b.Left - r.Left) / w, (b.Top - r.Top) / h, (b.Right - r.Left) / w,
                                                               (b.Bottom - r.Top) / h), line.Confidence);
                }).ToList());
        }), watchTranslator, overlay, clock: () => clock);
        var shades = new Dictionary<string, byte>();
        int? before = null;
        for (var i = 0; i < ids.Count; i++)
        {
            index = i;
            if (!shades.TryGetValue(ids[i], out var shade)) shades[ids[i]] = shade = (byte)(40 + 20 * shades.Count);
            var frame = Shade(shade);
            await pipeline.ProcessAsync(frame, SubtitleArea);
            await pipeline.WaitForTranslationsAsync();
            if (region is not null && before is null) before = sender.Sent.Count;
            if (i % 2 == 0)
                await watcher.PassAsync(frame, region is { } r ? [new WatchedArea(MissionLine.AreaId, "Mission", r) { Auto = true }] : []);
            clock += 250;
        }
        return new Run(regions, before, sender, translator.Requested, watchTranslator.Requested, overlay);
    }

    private static IEnumerable<string> Rep(string id, int count) => Enumerable.Repeat(id, count);

    public static readonly IReadOnlyList<string> Speedboat =
    [
        .. Rep("gta6-854-gorev-1", 4), .. Rep("gta6-854-gorev-2", 12), .. Rep("gta6-854-gorev-3", 16), .. Rep("gta6-854-gorev-3@0", 8),
        .. Rep("gta6-854-gorev-3", 16), .. Rep("gta6-854-gorev-2", 8), .. Rep("gta6-854-gorev-1", 2), .. Rep("gta6-854-gorev-3", 8),
        .. Rep("-", 8), .. Rep("gta6-854-gorev-3", 16), .. Rep("-", 28),
    ];

    public static readonly IReadOnlyList<string> Plane =
    [
        .. Rep("pencere-kare-2-gorev", 12), .. Rep("pencere-kare-5-gorev", 16), .. Rep("pencere-kare-5-gorev@0", 8),
        .. Rep("pencere-kare-5-gorev", 12), .. Rep("pencere-kare-2-gorev", 8), .. Rep("-", 8), .. Rep("pencere-kare-5-gorev", 16),
        .. Rep("-", 28),
    ];

    [Theory]
    [InlineData("speedboat", "Speedboat", "Somebody's happy to be free")]
    [InlineData("plane", "Follow the plane", "Okay.")]
    public async Task ObjectiveBoxStaysSteadyAcrossReads(string session, string objective, string dialogue)
    {
        var run = await RunAsync(session == "speedboat" ? Speedboat : Plane);
        // Görev kutusu bir kez belirdi ve görev gerçekten kalkınca bir kez kalktı.
        Assert.Equal(2, run.Regions.Count);
        var region = Assert.IsType<CropRegion>(run.Regions[0]);
        Assert.Null(run.Regions[1]);
        // Bölge yalnız görev satırı: konuşma görev sayılıp bölgeye katılmadı.
        Assert.True(region.Bottom - region.Top < 0.08, $"{region}");
        // Altyazı kutusunun kaçacağı yer bir kez bildirildi, bir kez kalktı.
        Assert.Equal(2, run.Sender.Objectives.Count);
        // Görev kutusu belirdikten sonra görev satırı altyazı olarak çevrilmedi.
        Assert.DoesNotContain(run.Sender.Sent.Skip(run.SubtitlesBeforeMission ?? 0), text => text.Contains(objective));
        Assert.Contains(run.Requested, text => text.Contains(dialogue));
        // Görev kutusu: bir kez gönderildi, yeri ve boyu hep aynı, çevirisi bir kez istendi; tek boş gönderim en sonda.
        var drawn = run.Overlay.Sent.Where(item => item.Text.Length > 0).ToList();
        Assert.Single(drawn);
        Assert.Single(run.WatcherRequested);
        Assert.Equal("", run.Overlay.Sent[^1].Text);
        Assert.Single(run.Overlay.Sent, item => item.Text.Length == 0);
    }

    /// <summary>Geçmişi olmayan tek başına görev (gta6-20-gorev) altyazı olarak çevrilmeye devam eder.</summary>
    [Fact]
    public async Task LoneObjectiveWithoutHistoryIsStillTheSubtitle()
    {
        var run = await RunAsync([.. Rep("gta6-20-gorev", 8)]);
        Assert.Contains(run.Sender.Sent, text => text.Contains("Follow the plane"));
        Assert.Empty(run.Regions);
    }

    [Fact]
    public void SettledObjectiveSurvivesAMissButNotALongAbsence()
    {
        var mission = new MissionLine();
        var area = new TextBox(0, 0, 1, 1);
        TextLine[] objective = [new("Get in the Speedboat", new TextBox(0.45, 0.94, 0.62, 0.97))];
        var changes = 0;
        for (long time = 0; time <= 4000; time += 250) if (mission.Observe(objective, area, time)) changes++;
        Assert.NotNull(mission.Region);
        Assert.Equal(1, changes);
        for (long time = 4250; time <= 6250; time += 250) Assert.False(mission.Observe([], area, time));
        Assert.NotNull(mission.Region);
        var (kept, claimed) = mission.Claim(new Reading([
            new TextLine("Lucia: Go.", new TextBox(0.4, 0.85, 0.6, 0.9)),
            new TextLine("Get in the speedbat", new TextBox(0.45, 0.941, 0.62, 0.971)),
        ]), area);
        Assert.Equal(["Lucia: Go."], kept.Lines.Select(line => line.Text));
        Assert.Equal(["Get in the speedbat"], claimed.Select(line => line.Text));
        Assert.False(mission.Observe(claimed, area, 6500));
        Assert.False(mission.Observe([], area, 6500 + MissionLine.HoldMs));
        Assert.True(mission.Observe([], area, 6750 + MissionLine.HoldMs));
        Assert.Null(mission.Region);
    }
}
