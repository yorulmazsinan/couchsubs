// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.CompilerServices;
using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// GitHub #1443 (X'te başkaları da: "sağ alt mesajlar çevrilmiyor"): GTA 6'nın sağ alttaki açık bildirim kartının yalnız
/// başlığı çevriliyor, gövdesi "koyu yazı açık zeminde (kâğıt/tabela)" sayılıp atılıyordu. Örnekler ortak deneme
/// dosyasından (core/Tests/CouchSubsCoreTests/Fixtures/notice-card.json; Mac NoticeCardTests.swift ve Android
/// NoticeCardTest.kt aynı dosyayı okur): gerçek kare gta6-n4-bildirim (kayıtlı okuması, alt şerit alanı kartı kesiyor),
/// kayıtlı okuması olan öteki bütün gerçek kareler (kart yok) ve kullanıcının fotoğrafındaki kartın ölçüleriyle sentetik kare.
/// </summary>
public class NoticeCardTests
{
    private static JsonElement Vectors() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("notice-card.json"))).RootElement;

    private static double[] Numbers(JsonElement element) => [.. element.EnumerateArray().Select(v => v.GetDouble())];

    private static TextBox Box(JsonElement element)
    {
        var b = Numbers(element);
        return new TextBox(b[0], b[1], b[2], b[3]);
    }

    private static string FramesDirectory([CallerFilePath] string source = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..", "testdata", "frames"));

    /// <summary>Kayıtlı okuma ve alanı (testdata/frames/ocr); yoksa null.</summary>
    private static (Reading Reading, TextBox Area)? Recorded(string id)
    {
        var path = Path.Combine(FramesDirectory(), "ocr", id + ".json");
        if (!File.Exists(path)) return null;
        using var fixture = JsonDocument.Parse(File.ReadAllText(path));
        if (!fixture.RootElement.TryGetProperty("region", out var region)) return null;
        var lines = fixture.RootElement.GetProperty("lines").EnumerateArray()
            .Select(line => new TextLine(line.GetProperty("text").GetString()!, Box(line.GetProperty("box")), 1)).ToList();
        return (new Reading(lines), Box(region));
    }

    private static void AssertClose(TextBox? got, JsonElement want, double tolerance, string name)
    {
        Assert.True(got is not null, $"{name}: kart bulunmadı");
        var w = Numbers(want);
        double[] g = [got!.Value.Left, got.Value.Top, got.Value.Right, got.Value.Bottom];
        for (var i = 0; i < 4; i++)
            Assert.True(Math.Abs(g[i] - w[i]) <= tolerance, $"{name}: {string.Join(", ", g)}");
    }

    [Fact]
    public void RealNotificationCardIsFoundWhole()
    {
        var vectors = Vectors();
        var tolerance = vectors.GetProperty("tolerance").GetDouble();
        foreach (var real in vectors.GetProperty("real").EnumerateArray())
        {
            var name = real.GetProperty("frame").GetString()!;
            var (reading, area) = Recorded(name)!.Value;
            var frame = Jpeg.Load(Path.Combine(FramesDirectory(), name + ".jpg"));
            var (kept, cards) = NoticeCard.Split(reading, area, NoticeCard.Sampler(frame));
            Assert.True(cards.Count == 1, name);
            AssertClose(cards[0].Card, real.GetProperty("card"), tolerance, name);
            var texts = real.GetProperty("texts").EnumerateArray().Select(t => t.GetString()!).ToList();
            Assert.Equal(texts, cards[0].Block.Lines.Select(l => l.Text).ToList());
            Assert.DoesNotContain(kept.Lines, line => texts.Contains(line.Text));
        }
    }

    /// <summary>Kayıtlı okuması olan öteki gerçek karelerde (konuşma, kâğıt ilan, tabela, kitap, tişört, telefon, menü) kart yoktur.</summary>
    [Fact]
    public void NoOtherRealFrameHasACard()
    {
        var cards = Vectors().GetProperty("real").EnumerateArray().Select(r => r.GetProperty("frame").GetString()).ToHashSet();
        var checkedCount = 0;
        foreach (var path in Directory.GetFiles(FramesDirectory(), "*.jpg").Order())
        {
            var name = Path.GetFileNameWithoutExtension(path);
            if (cards.Contains(name) || Recorded(name) is not { } recorded) continue;
            var (kept, found) = NoticeCard.Split(recorded.Reading, recorded.Area, NoticeCard.Sampler(Jpeg.Load(path)));
            Assert.True(found.Count == 0, $"{name}: {string.Join(" | ", found.Select(f => f.Block.Text))}");
            Assert.Same(recorded.Reading, kept);
            checkedCount++;
        }
        Assert.True(checkedCount > 30, checkedCount.ToString());
    }

    /// <summary>Sentetik parlaklık (ortak dosyadaki formül).</summary>
    private static int Luma(JsonElement synthetic, int x, int y, double shift, bool invert)
    {
        double fx = (x + 0.5) / synthetic.GetProperty("width").GetInt32() - shift, fy = (y + 0.5) / synthetic.GetProperty("height").GetInt32();
        bool Inside(JsonElement r)
        {
            var v = Numbers(r);
            return fx >= v[0] && fx < v[2] && fy >= v[1] && fy < v[3];
        }
        if (!Inside(synthetic.GetProperty("card"))) return 110 + ((x * 37) + (y * 91) + (x * y % 53)) % 90;
        var (ground, ink) = invert ? (40, 236) : (236, 40);
        if (Inside(synthetic.GetProperty("icon"))) return 130;
        if (synthetic.GetProperty("rows").EnumerateArray().Any(Inside) && x / 3 % 2 == 0) return ink;
        return ground;
    }

    /// <summary>Sentetik parlaklığı önceden hesaplanmış dizi olarak (her noktada JSON okunmasın).</summary>
    private static int[] Lumas(JsonElement synthetic, double shift, bool invert)
    {
        int width = synthetic.GetProperty("width").GetInt32(), height = synthetic.GetProperty("height").GetInt32();
        var values = new int[width * height];
        for (var y = 0; y < height; y++) for (var x = 0; x < width; x++) values[(y * width) + x] = Luma(synthetic, x, y, shift, invert);
        return values;
    }

    [Fact]
    public void SyntheticCases()
    {
        var vectors = Vectors();
        var tolerance = vectors.GetProperty("tolerance").GetDouble();
        var synthetic = vectors.GetProperty("synthetic");
        int width = synthetic.GetProperty("width").GetInt32(), height = synthetic.GetProperty("height").GetInt32();
        var body = synthetic.GetProperty("lines").EnumerateArray().Take(4).Select(l => Box(l.GetProperty("box"))).Aggregate((a, b) => a.Union(b));
        foreach (var item in synthetic.GetProperty("cases").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString()!;
            var shift = item.GetProperty("shift").GetDouble();
            var values = Lumas(synthetic, shift, item.GetProperty("invert").GetBoolean());
            var shifted = new TextBox(body.Left + shift, body.Top, body.Right + shift, body.Bottom);
            var found = NoticeCard.Bounds(shifted, width, height, (x, y) => values[(y * width) + x]);
            if (item.GetProperty("card").ValueKind == JsonValueKind.Null) Assert.True(found is null, name);
            else AssertClose(found, item.GetProperty("card"), tolerance, name);
        }
    }

    /// <summary>
    /// Kartın bölgesi kartın kendisidir; kart <see cref="ScreenNotices.SettleMs"/> yerinde durunca gelir, küçük oynamada
    /// bölge değişmez, kart görünmeyince <see cref="ScreenNotices.ForgetMs"/> sonra kalkar.
    /// </summary>
    [Fact]
    public void NoticesTrackCardsWithTheWholeCardAsRegion()
    {
        var notices = new ScreenNotices();
        var card = new TextBox(0.68, 0.63, 0.96, 0.93);
        Assert.False(notices.Observe([], 0, [card]));
        Assert.True(notices.Observe([], ScreenNotices.SettleMs, [card]));
        Assert.Equal(["auto-notice-1"], notices.Areas.Select(a => a.Id));
        Assert.Equal(new CropRegion(0.63, 0.93, 0.68, 0.96), notices.Areas[0].Region);
        Assert.False(notices.Observe([], ScreenNotices.SettleMs + 100, [new TextBox(0.682, 0.631, 0.958, 0.93)]));
        Assert.False(notices.Observe([], ScreenNotices.SettleMs + 100 + ScreenNotices.ForgetMs));
        Assert.True(notices.Observe([], ScreenNotices.SettleMs + 101 + ScreenNotices.ForgetMs));
        Assert.Empty(notices.Areas);
    }

    /// <summary>
    /// Kullanıcının durumu (#1443): alt şerit altyazı alanı kartı kesiyor, gövde koyu yazı. Kart açıkken (GTA 6, ekran yazısı
    /// ya da telefon çevirisi) gövde altyazıya girmez, kâğıt/tabela diye de atılmaz; kartın tamamı "auto-notice-1" olur.
    /// Aynı karedeki konuşma altyazı olarak çevrilir. Kart kapalıyken eski davranış (kart bildirimi yok).
    /// </summary>
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task PipelineRoutesTheCardToANoticeBeforeTheDarkInkRule(bool cards)
    {
        var vectors = Vectors();
        var tolerance = vectors.GetProperty("tolerance").GetDouble();
        var synthetic = vectors.GetProperty("synthetic");
        int width = synthetic.GetProperty("width").GetInt32(), height = synthetic.GetProperty("height").GetInt32();
        var area = Box(synthetic.GetProperty("area"));
        double aw = area.Right - area.Left, ah = area.Bottom - area.Top;
        var reading = new Reading(synthetic.GetProperty("lines").EnumerateArray().Select(line =>
        {
            var b = Box(line.GetProperty("box"));
            return new TextLine(line.GetProperty("text").GetString()!,
                new TextBox((b.Left - area.Left) / aw, (b.Top - area.Top) / ah, (b.Right - area.Left) / aw, (b.Bottom - area.Top) / ah), 1);
        }).ToList());
        var values = Lumas(synthetic, 0, false);
        var pixels = new byte[width * height * 4];
        for (var i = 0; i < values.Length; i++)
        {
            var v = (byte)values[i];
            (pixels[i * 4], pixels[(i * 4) + 1], pixels[(i * 4) + 2], pixels[(i * 4) + 3]) = (v, v, v, 255);
        }
        long clock = 1_000_000;
        var translator = new FakeTranslator();
        var log = new List<string>();
        IReadOnlyList<WatchedArea> areas = [];
        var pipeline = new SubtitlePipeline(new LinesReader(reading), translator, new FakeSender(), clock: () => clock)
        {
            Log = log.Add, LightInkGame = true, FindsNoticeCards = cards,
        };
        pipeline.NoticesChanged += changed => areas = changed;
        var region = new CropRegion(area.Top, area.Bottom, area.Left, area.Right);
        for (var i = 0; i < 20; i++)
        {
            await pipeline.ProcessAsync(new Frame(pixels, width, height, width * 4), region);
            await pipeline.WaitForTranslationsAsync();
            clock += 100;
        }
        var joined = string.Join("\n", log);
        var cardTexts = synthetic.GetProperty("cardTexts").EnumerateArray().Select(t => t.GetString()!).ToList();
        Assert.False(translator.Requested.Any(text => cardTexts.Any(text.Contains)), joined);
        if (cards)
        {
            // Kart ayrılınca konuşma kendi başına altyazıdır (önceden kartın satırlarıyla birlikte menü listesi sanılıyordu).
            var subtitle = synthetic.GetProperty("subtitle").GetString()!["Lucia: ".Length..];
            Assert.True(translator.Requested.Any(text => text.Contains(subtitle)), joined);
            Assert.Equal(["auto-notice-1"], areas.Select(a => a.Id));
            var r = areas[0].Region;
            AssertClose(new TextBox(r.Left, r.Top, r.Right, r.Bottom), synthetic.GetProperty("card"), tolerance, "hat");
            Assert.DoesNotContain(log, line => line.Contains(InkTone.Reason) && line.Contains("from a chop"));
            Assert.Contains(log, line => line.Contains("bildirim kartı:") && line.Contains("from a chop"));
        }
        else
        {
            Assert.Empty(areas);
        }
    }
}
