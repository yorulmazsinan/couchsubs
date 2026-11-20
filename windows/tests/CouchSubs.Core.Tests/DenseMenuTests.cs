// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Yoğun menü ekranları: duraklatma menüsü ve kontrol şeması (Mac ve Android ile aynı örnekler).</summary>
public class DenseMenuTests
{
    private sealed class Reader : ITextReader
    {
        public List<TextLine> Lines { get; set; } = [];
        public string Read(Frame image) => string.Join('\n', Lines.Select(line => line.Text));
        public Reading ReadScreen(Frame image) => new(Lines);
        public Reading ReadLines(Frame image, bool deep) => new(Lines);
    }

    /// <summary>Toplu istekleri sayan çevirmen.</summary>
    private sealed class Batch : ITextTranslator
    {
        public int Requests;
        public List<string> Texts { get; } = [];
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default) =>
            Task.FromResult(Map(text));
        public Task<IReadOnlyList<string>> TranslateAllAsync(IReadOnlyList<string> texts, CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref Requests);
            lock (Texts) Texts.AddRange(texts);
            return Task.FromResult<IReadOnlyList<string>>([.. texts.Select(Map)]);
        }
        private static string Map(string text) => "çeviri" + (Math.Abs(text.GetHashCode()) % 9973);
    }

    private sealed class Server : IRegionSender
    {
        public List<IReadOnlyList<ScreenTranslation.Item>?> Blocks { get; } = [];
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight = null) =>
            SendRegion(id, text, box, lineHeight, null, null);
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight, IReadOnlyList<IconPlacement>? icons,
                               IReadOnlyList<ScreenTranslation.Item>? blocks)
        {
            lock (Blocks) Blocks.Add(text.Length > 0 ? blocks : null);
        }
        public void ClearRegions() { }
    }

    private static readonly WatchedArea Area = new("auto-1", ScreenTextDetector.AreaName, new CropRegion(0, 1, 0, 1)) { Auto = true };

    // --- (a) Duraklatma menüsü: koyu panelde altı satır, seçili satır ters renk ---

    private static readonly string[] PauseRows = ["Map", "Game", "Store", "Help", "Photo Studio", "Settings"];

    private static TextBox Row(int index) => new(20 / 400.0, (20 + 40 * index) / 300.0, 200 / 400.0, (50 + 40 * index) / 300.0);

    private static Frame Pause(int selected)
    {
        var frame = Frame.Blank(400, 300);
        for (var y = 0; y < 300; y++)
            for (var x = 0; x < 400; x++)
            {
                var row = (y - 20) / 40;
                var inRow = y >= 20 && (y - 20) % 40 < 30 && row < PauseRows.Length && x is >= 20 and < 200;
                var chosen = inRow && row == selected;
                var ink = inRow && (y - 20) % 40 is >= 10 and < 20 && x % 6 < 2;
                byte value = chosen ? (ink ? (byte)20 : (byte)225) : ink ? (byte)235 : (byte)30;
                var p = y * frame.Stride + x * 4;
                frame.Pixels[p] = frame.Pixels[p + 1] = frame.Pixels[p + 2] = value;
            }
        return frame;
    }

    private static List<TextLine> PauseLines() => [.. PauseRows.Select((text, index) => new TextLine(text, Row(index)))];

    private static bool Light(string hex) => Convert.ToInt32(hex.Substring(1, 2), 16) > 128;

    [Fact]
    public async Task EachRowHasItsOwnSurfaceAndMovingTheSelectionOnlyRecolours()
    {
        var reader = new Reader { Lines = PauseLines() };
        var translator = new Batch();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server) { TranslatesUiCommands = true };
        await watcher.PassAsync(Pause(2), [Area]);
        await watcher.PassAsync(Pause(2), [Area]);
        var first = server.Blocks.Last(blocks => blocks is not null)!;
        Assert.Equal(6, first.Count);
        Assert.True(Light(first[2].Style!.Background));
        Assert.All(first.Where((_, index) => index != 2), block => Assert.False(Light(block.Style!.Background)));
        // Yalnız sözlükte olmayan "Game" motora gitti; karışık harfli özgün normal Türkçe kalır.
        Assert.Equal(1, translator.Requests);
        Assert.Equal(["Game"], translator.Texts);
        Assert.Equal("Harita", first[0].Translation);

        await watcher.PassAsync(Pause(3), [Area]);
        await watcher.PassAsync(Pause(3), [Area]);
        Assert.Equal(1, translator.Requests);
        var moved = server.Blocks.Last(blocks => blocks is not null)!;
        Assert.False(Light(moved[2].Style!.Background));
        Assert.True(Light(moved[3].Style!.Background));
        Assert.Equal(first.Select(block => block.Translation), moved.Select(block => block.Translation));
    }

    // --- (b) Kontrol şeması: sağa yaslı tuş etiketleri, sola yaslı simgeli etiketler, sayaçlar ---

    private static TextLine Label(string text, double left, double right, int row) =>
        new(text, new TextBox(left, 0.04 + row * 0.04, right, 0.07 + row * 0.04));

    private static List<TextLine> Scheme()
    {
        List<TextLine> lines =
        [
            Label("CONTROL SCHEME", 0.05, 0.25, 0), Label("PREVIEW", 0.6, 0.7, 0),
            Label("Default 1 / 3", 0.05, 0.2, 1), Label("On Foot", 0.05, 0.15, 2), Label("Land / Water Vehicles", 0.05, 0.28, 3),
            Label("5 / 9", 0.05, 0.1, 4),
            Label("HOLSTER (L1)", 0.32, 0.45, 5), Label("AIM / INTERACT (L2)", 0.28, 0.45, 6), Label("RUN (L3)", 0.38, 0.45, 7),
            Label("(△) INTERACT", 0.55, 0.66, 5), Label("(✕) JUMP / CLIMB", 0.55, 0.7, 6),
            Label("RESTORE DEFAULT (□)", 0.05, 0.22, 20), Label("SELECT (✕)", 0.3, 0.4, 20), Label("BACK (○)", 0.45, 0.53, 20),
        ];
        string[] more = ["MELEE", "RELOAD", "SPRINT", "CROUCH", "COVER", "WHISTLE", "SWAP WEAPON", "THROW", "PHONE", "RADIO",
                         "HORN", "HANDBRAKE", "LOOK BEHIND", "HEADLIGHTS"];
        for (var i = 0; i < more.Length; i++) lines.Add(Label(more[i] + " (R" + (1 + i % 3) + ")", 0.3 - i % 2 * 0.02, 0.45, 8 + i % 11));
        return lines;
    }

    [Fact]
    public void LabelsAlignByTheirNeighboursAndKeepButtonNames()
    {
        var frame = Pause(-1);
        var candidate = RegionWatcher.MakeCandidate(new Reading(Scheme()), new CropRegion(0, 1, 0, 1), frame, auto: true);
        var blocks = candidate.Blocks!;
        string Align(string text) => blocks[Enumerable.Range(0, blocks.Count).First(i => candidate.Paragraphs[blocks[i].Start] == text)].Look!.Align;
        Assert.Equal("right", Align("HOLSTER (L1)"));
        Assert.Equal("left", Align("(△) INTERACT"));
        Assert.DoesNotContain("5 / 9", candidate.Paragraphs);

        Assert.Equal([("", "HOLSTER", " (L1)")], RegionWatcher.SplitLabel("HOLSTER (L1)"));
        Assert.Equal([("", "AIM", ""), ("", "INTERACT", " (L2)")], RegionWatcher.SplitLabel("AIM / INTERACT (L2)"));
        Assert.Equal([("(△) ", "INTERACT", "")], RegionWatcher.SplitLabel("(△) INTERACT"));
        Assert.Equal([("", "Default", " 1 / 3")], RegionWatcher.SplitLabel("Default 1 / 3"));
    }

    [Fact]
    public async Task WholeSchemeIsOneBatchAndReturningCostsNothing()
    {
        var reader = new Reader { Lines = Scheme() };
        var translator = new Batch();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server) { TranslatesUiCommands = true };
        await watcher.PassAsync(Pause(-1), [Area]);
        await watcher.PassAsync(Pause(-1), [Area]);
        Assert.Equal(1, translator.Requests);
        Assert.True(translator.Texts.Count >= 20);
        // Tuş adları ve sayaçlar çeviriye gitmez, sözlükteki etiketler de ("SELECT", "BACK").
        Assert.DoesNotContain(translator.Texts, text => text.Contains("(L1)") || text.Contains("1 / 3") || text is "SELECT" or "BACK");
        var sent = server.Blocks.Last(blocks => blocks is not null)!;
        Assert.EndsWith(" (L1)", sent.Single(block => block.Source == "HOLSTER (L1)").Translation);
        Assert.Contains(" / ", sent.Single(block => block.Source == "AIM / INTERACT (L2)").Translation);
        Assert.Equal("SEÇ (✕)", sent.Single(block => block.Source == "SELECT (✕)").Translation);

        // Menü kapandı, yeniden açıldı: hepsi oturum önbelleğinden.
        await watcher.PassAsync(Pause(-1), []);
        await watcher.PassAsync(Pause(-1), [Area with { Id = "auto-7" }]);
        await watcher.PassAsync(Pause(-1), [Area with { Id = "auto-7" }]);
        Assert.Equal(1, translator.Requests);
    }
}
