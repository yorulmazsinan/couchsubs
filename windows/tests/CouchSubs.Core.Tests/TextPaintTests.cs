// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Yerinde birebir çizim: göndericinin kareden ölçtükleri (<see cref="TextPainter"/>: örtü kutusu, zemin/degrade/desen,
/// boş alan, grup) ve çizicilerin ortak yerleşimi (<see cref="ScreenFit.Exact"/>). Ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/text-paint.json (Mac TextPaintTests.swift, Android TextPaintTest.kt ve TV
/// scripts/tv-exact-fit.test.js aynı vakalar).
/// </summary>
public class TextPaintTests
{
    private static JsonDocument Fixture() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("text-paint.json")));

    private static double[] Numbers(JsonElement array) => [.. array.EnumerateArray().Select(value => value.GetDouble())];

    /// <summary>Yapay karenin noktası: zemin, üstüne sırayla çizilen dikdörtgenler.</summary>
    private static (int R, int G, int B) Pixel(JsonElement frame, int x, int y)
    {
        foreach (var rect in frame.GetProperty("rects").EnumerateArray().Reverse())
            if (Inside(rect, x, y)) return TextPainter.Rgb(rect.GetProperty("color").GetString()!);
        var background = frame.GetProperty("background");
        var from = TextPainter.Rgb(background.GetProperty("from").GetString()!);
        var to = background.TryGetProperty("to", out var end) && end.ValueKind == JsonValueKind.String ? TextPainter.Rgb(end.GetString()!) : from;
        int width = frame.GetProperty("width").GetInt32(), height = frame.GetProperty("height").GetInt32();
        static int Mix(int a, int b, double f) => (int)Math.Round(a + ((b - a) * f), MidpointRounding.AwayFromZero);
        (int, int, int) At(double f) => (Mix(from.R, to.R, f), Mix(from.G, to.G, f), Mix(from.B, to.B, f));
        switch (background.GetProperty("kind").GetString())
        {
            case "h": return At((double)x / (width - 1));
            case "v": return At((double)y / (height - 1));
            case "checker":
                var cell = background.TryGetProperty("cell", out var size) && size.ValueKind == JsonValueKind.Number ? size.GetInt32() : 6;
                return ((x / cell) + (y / cell)) % 2 == 0 ? from : to;
            default: return from;
        }
    }

    /// <summary>
    /// Yuvarlak köşeli dikdörtgen (Mac TextPaintTests.inside ile aynı): köşe karesindeki nokta, merkezi köşe dairesinin
    /// içindeyse boyanır; <c>tail</c> köşesi köşeli kalır.
    /// </summary>
    private static bool Inside(JsonElement rect, int x, int y)
    {
        var b = Numbers(rect.GetProperty("box"));
        if (!(x >= b[0] && x < b[2] && y >= b[1] && y < b[3])) return false;
        if (!rect.TryGetProperty("radius", out var radius) || radius.ValueKind != JsonValueKind.Number || radius.GetInt32() <= 0) return true;
        var tail = rect.TryGetProperty("tail", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
        double px = x + 0.5, py = y + 0.5, rr = radius.GetInt32();
        bool left = px < b[0] + rr, right = px > b[2] - rr, top = py < b[1] + rr, bottom = py > b[3] - rr;
        if (!((left || right) && (top || bottom))) return true;
        if (bottom && ((left && tail == "left") || (right && tail == "right"))) return true;
        double cx = left ? b[0] + rr : b[2] - rr, cy = top ? b[1] + rr : b[3] - rr;
        return ((px - cx) * (px - cx)) + ((py - cy) * (py - cy)) <= rr * rr;
    }

    /// <summary>
    /// Çizim kipi (<see cref="TextPaint.Mode"/>): desenli zeminde yanına yazma (önce sol, yer yoksa sağ), simge örtülmez,
    /// köşeli düz kutu örtülür, yuvarlak panel küçük ikizle (resim, kuyruk) üstte ya da altta, yer yoksa örtme; menü ve
    /// türsüz yazı hep örtülür. Ortak vakalar Fixtures/text-paint.json → modes (Mac, Android aynı).
    /// </summary>
    [Fact]
    public void SharedModeVectors()
    {
        using var fixture = Fixture();
        var frames = fixture.RootElement.GetProperty("modes").EnumerateArray().ToList();
        Assert.NotEmpty(frames);
        foreach (var frame in frames)
        {
            var id = frame.GetProperty("id").GetString()!;
            int width = frame.GetProperty("width").GetInt32(), height = frame.GetProperty("height").GetInt32();
            double w = width, h = height;
            var targets = frame.GetProperty("targets").EnumerateArray().Select(t =>
            {
                var box = Numbers(t.GetProperty("box"));
                ScreenTextKind? kind = t.TryGetProperty("kind", out var k) ? Enum.Parse<ScreenTextKind>(k.GetString()!, ignoreCase: true) : null;
                return new TextPainter.Target(new TextBox(box[0] / w, box[1] / h, box[2] / w, box[3] / h),
                    t.GetProperty("line").GetDouble() / h, t.GetProperty("rows").GetInt32(), t.GetProperty("bg").GetString()!,
                    t.GetProperty("fg").GetString()!, t.GetProperty("upper").GetBoolean(), t.GetProperty("align").GetString()!,
                    t.TryGetProperty("words", out var words) ? words.GetInt32() : 0, kind,
                    t.TryGetProperty("prompt", out var prompt) && prompt.GetBoolean());
            }).ToList();
            var boxes = frame.GetProperty("targets").EnumerateArray().Select(t => Numbers(t.GetProperty("box"))).ToList();
            var paints = TextPainter.Paints(targets, width, height, (x, y) => Pixel(frame, x, y));
            var expects = frame.GetProperty("expect").EnumerateArray().ToList();
            Assert.True(paints.Count == expects.Count, id);
            double[]? Px(TextBox? b) => b is { } v ? [v.Left * w, v.Top * h, v.Right * w, v.Bottom * h] : null;
            for (var k = 0; k < expects.Count; k++)
            {
                var e = expects[k];
                var paint = paints[k];
                var name = $"{id}#{k}";
                Assert.True(paint.Mode == e.GetProperty("mode").GetString(), $"{name} kip {paint.Mode}");
                void Near(double[]? got, string key, double tolerance = 1.01)
                {
                    if (!e.TryGetProperty(key, out var want) || want.ValueKind != JsonValueKind.Array) return;
                    Assert.True(got is not null, $"{name} {key} yok");
                    var values = Numbers(want);
                    for (var i = 0; i < values.Length; i++) Close(values[i], got![i], tolerance, $"{name} {key} [{string.Join(", ", got)}]");
                }
                Near(Px(paint.Spot), "spot");
                Near(Px(paint.SpotRoom) is { } room ? [room[0], room[2]] : null, "room");
                Near(Px(paint.Twin), "twin");
                Near(Px(paint.PortraitTwin), "portraitTwin");
                if (e.TryGetProperty("radius", out var radius)) Close(radius.GetDouble(), paint.Radius * h, 1.5, $"{name} radius");
                if (e.TryGetProperty("scale", out var scale)) Close(scale.GetDouble(), paint.Scale, 0.001, $"{name} scale");
                if (e.TryGetProperty("twin", out _))
                {
                    var tail = e.TryGetProperty("tail", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
                    Assert.True(paint.Tail == tail, $"{name} kuyruk {paint.Tail}");
                }
                if (e.TryGetProperty("portrait", out var face))
                {
                    if (face.ValueKind == JsonValueKind.Null) Assert.True(paint.Portrait is null, $"{name} resim olmamalı");
                    else Near(Px(paint.Portrait), "portrait");
                }
                Near(paint.Edge is { } edge ? [edge.Top * h, edge.Right * h, edge.Bottom * h, edge.Left * h] : null, "edge", 0.51);
                // hug: ikiz özgün yazıyı her yanda en çok bu kadar satır aşar; yanına yazılan Türkçenin yeri özgünün satır
                // yüksekliğinde ve genişliğinde, Türkçeler birbirine binmez (tuş çubuğu, beta.103).
                if (frame.TryGetProperty("hug", out var hugValue))
                {
                    var target = boxes[k];
                    var pad = hugValue.GetDouble() * frame.GetProperty("targets")[k].GetProperty("line").GetDouble();
                    if (paint.Twin is { } twin)
                        Assert.True((twin.Right - twin.Left) * w <= target[2] - target[0] + 2 * pad
                                    && (twin.Bottom - twin.Top) * h <= target[3] - target[1] + 2 * pad, $"{name} dev ikiz");
                    if (paint.Mode == PaintMode.Beside && paint.Spot is { } spot)
                    {
                        var cover = paint.Cover;
                        Close((cover.Bottom - cover.Top) * h, (spot.Bottom - spot.Top) * h, 0.5, $"{name} satır yüksekliği");
                        Assert.True((spot.Bottom - spot.Top) * h <= target[3] - target[1] + 2.0 * TextPainter.MarginMax, name);
                        Close((cover.Right - cover.Left) * w, (spot.Right - spot.Left) * w, 0.5, $"{name} genişlik");
                        for (var j = k + 1; j < paints.Count; j++)
                        {
                            if (paints[j].Mode != PaintMode.Beside || paints[j].Spot is not { } o) continue;
                            Assert.False(Math.Min(o.Right, spot.Right) > Math.Max(o.Left, spot.Left)
                                         && Math.Min(o.Bottom, spot.Bottom) > Math.Max(o.Top, spot.Top), $"{name} ile #{j} binişiyor");
                        }
                    }
                }
                // Örtmeyen kipte Türkçe özgün yazıya (ve kutunun ucundaki simgeye) binmez; ikiz özgün paneli örtmez.
                if (paint.Mode != PaintMode.Cover && paint.SpotRoom is { } spotRoom)
                {
                    var target = boxes[k];
                    Assert.False(spotRoom.Right * w > target[0] + 0.5 && spotRoom.Left * w < target[2] - 0.5
                                 && spotRoom.Bottom * h > target[1] + 0.5 && spotRoom.Top * h < target[3] - 0.5, $"{name} özgüne biner");
                }
            }
        }
    }

    /// <summary>
    /// Kip örtmeyen öğede yerleşim girdisi Türkçenin yerinden (spot) gelir; ikizde yazı boyu ölçekli, yanına yazmada yazı
    /// özgüne yaslanır; grup örtmede ve yanına yazmada (listedeki Türkçeler aynı boyda), ikizde yok; ikizde yazı küçülmez
    /// (Mac ScreenFit.ExactInput ile aynı).
    /// </summary>
    [Fact]
    public void ExactInputFollowsMode()
    {
        var cover = new TextBox(0.5, 0.5, 0.6, 0.55);
        var item = new ScreenTranslation.Item("Hold", "BASILI TUT", cover, 0.05)
        {
            Look = new TextLook(true, false, "center", true, false),
            Paint = new TextPaint("#000000", 0.05, cover)
            {
                Group = 3, Mode = PaintMode.Beside, Spot = new TextBox(0.38, 0.5, 0.48, 0.55), SpotRoom = new TextBox(0.3, 0.5, 0.48, 0.55),
            },
        };
        var beside = ScreenFit.ExactInput.From(item, 1000, 1000)!;
        Close(380, beside.Left, 1e-6, "sol");
        Close(300, beside.GrowLeft, 1e-6, "uzama solu");
        Assert.Equal("right", beside.Align);
        Assert.Equal(3, beside.Group);
        Assert.False(beside.KeepSize);
        Close(50, beside.Line, 1e-6, "satır");
        var twin = ScreenFit.ExactInput.From(item with { Paint = item.Paint! with { Mode = PaintMode.Twin, Scale = 0.5 } }, 1000, 1000)!;
        Close(25, twin.Line, 1e-6, "ikiz satır");
        Assert.Equal("center", twin.Align);
        Assert.Null(twin.Group);
        Assert.True(twin.KeepSize);
        var covered = ScreenFit.ExactInput.From(item with { Paint = item.Paint! with { Mode = PaintMode.Cover } }, 1000, 1000)!;
        Close(500, covered.Left, 1e-6, "örtü solu");
        Assert.Equal(3, covered.Group);
    }

    /// <summary>
    /// TV'ye giden öğe: örtmeyen kipte mode, spot, spotRoom; ikizde twinBox, radius, scale, tail, icon {src, box}. Örtmede
    /// bu alanlar yok (eski TV ve yeni TV aynı çizer).
    /// </summary>
    [Fact]
    public void ModeFieldsGoToTv()
    {
        var cover = new TextBox(0.5, 0.5, 0.6, 0.55);
        var item = new ScreenTranslation.Item("Hi", "Selam", cover, 0.05)
        {
            Look = new TextLook(false, false, "left", false, true),
            Style = new PhoneTextStyle("#D0D0D0", "#202020"),
            Paint = new TextPaint("#D0D0D0", 0.05, cover),
        };
        var plain = SubtitleServer.ItemJson(item, phone: false);
        Assert.True(plain.ContainsKey("cover"));
        foreach (var key in new[] { "mode", "spot", "spotRoom", "twinBox", "radius", "scale", "tail", "icon" }) Assert.False(plain.ContainsKey(key), key);
        var twin = SubtitleServer.ItemJson(item with
        {
            Paint = item.Paint! with
            {
                Mode = PaintMode.Twin, Spot = new TextBox(0.5, 0.3, 0.56, 0.33), SpotRoom = new TextBox(0.5, 0.3, 0.6, 0.33),
                Twin = new TextBox(0.48, 0.28, 0.6, 0.36), Radius = 0.006, Scale = 0.58, Tail = "left",
                PortraitImage = "data:image/png;base64,AA==", PortraitTwin = new TextBox(0.485, 0.29, 0.495, 0.31),
                Edge = new TextPaint.EdgeLine("#E0A030", 0.003, 0, 0, 0),
            },
        }, phone: false);
        Assert.Equal("twin", twin["mode"]);
        foreach (var key in new[] { "spot", "spotRoom", "twinBox", "radius", "scale", "tail", "icon", "cover", "edge" }) Assert.True(twin.ContainsKey(key), key);
        var edge = Assert.IsType<SortedDictionary<string, object>>(twin["edge"]);
        Assert.Equal("#E0A030", edge["color"]);
        Assert.Equal(0.003m, edge["top"]);
        Assert.Equal(0m, edge["left"]);
        Assert.Equal(0.58m, twin["scale"]);
        var icon = Assert.IsType<SortedDictionary<string, object>>(twin["icon"]);
        Assert.Equal("data:image/png;base64,AA==", icon["src"]);
    }

    /// <summary>Renkler kanal başına en çok 4 farklı.</summary>
    private static bool Near(string a, string b) => TextPainter.Distance(TextPainter.Rgb(a), TextPainter.Rgb(b)) <= 4;

    private static void Close(double expected, double actual, double tolerance, string name) =>
        Assert.True(Math.Abs(expected - actual) <= tolerance, $"{name}: {actual} ≠ {expected} (±{tolerance})");

    [Fact]
    public void SharedPaintVectors()
    {
        using var fixture = Fixture();
        var frames = fixture.RootElement.GetProperty("paint").EnumerateArray().ToList();
        Assert.NotEmpty(frames);
        foreach (var frame in frames)
        {
            var id = frame.GetProperty("id").GetString()!;
            int width = frame.GetProperty("width").GetInt32(), height = frame.GetProperty("height").GetInt32();
            double w = width, h = height;
            var targets = frame.GetProperty("targets").EnumerateArray().Select(t =>
            {
                var box = Numbers(t.GetProperty("box"));
                return new TextPainter.Target(new TextBox(box[0] / w, box[1] / h, box[2] / w, box[3] / h),
                    t.GetProperty("line").GetDouble() / h, t.GetProperty("rows").GetInt32(), t.GetProperty("bg").GetString()!,
                    t.GetProperty("fg").GetString()!, t.GetProperty("upper").GetBoolean(), t.GetProperty("align").GetString()!,
                    t.TryGetProperty("words", out var words) ? words.GetInt32() : 0);
            }).ToList();
            var paints = TextPainter.Paints(targets, width, height, (x, y) => Pixel(frame, x, y));
            var expects = frame.GetProperty("expect").EnumerateArray().ToList();
            Assert.True(paints.Count == expects.Count, id);
            for (var k = 0; k < expects.Count; k++)
            {
                var expect = expects[k];
                var paint = paints[k];
                var name = $"{id}#{k}";
                if (expect.TryGetProperty("cover", out var cover) && cover.ValueKind == JsonValueKind.Array)
                {
                    double[] got = [paint.Cover.Left * w, paint.Cover.Top * h, paint.Cover.Right * w, paint.Cover.Bottom * h];
                    var want = Numbers(cover);
                    for (var i = 0; i < 4; i++) Close(want[i], got[i], 1.01, $"{name} örtü [{string.Join(", ", got)}]");
                }
                if (expect.TryGetProperty("bg", out var bg) && bg.ValueKind == JsonValueKind.String)
                    Assert.True(Near(paint.Background, bg.GetString()!), $"{name} zemin {paint.Background} ≠ {bg.GetString()}");
                if (expect.TryGetProperty("bg2", out var bg2))
                {
                    if (bg2.ValueKind == JsonValueKind.Null) Assert.True(paint.Background2 is null, $"{name} bg2 {paint.Background2}");
                    else Assert.True(paint.Background2 is { } second && Near(second, bg2.GetString()!), $"{name} bg2 {paint.Background2}");
                }
                if (expect.TryGetProperty("bgDir", out var direction) && direction.ValueKind == JsonValueKind.String)
                    Assert.True(paint.Direction == direction.GetString(), $"{name} yön {paint.Direction}");
                if (expect.TryGetProperty("patterned", out var patterned) && patterned.ValueKind is JsonValueKind.True or JsonValueKind.False)
                    Assert.True(paint.Patterned == patterned.GetBoolean(), $"{name} desen {paint.Patterned}");
                if (expect.TryGetProperty("grow", out var grow))
                {
                    if (grow.ValueKind == JsonValueKind.Null) Assert.True(paint.Grow is null, $"{name} uzamamalı: {paint.Grow}");
                    else
                    {
                        Assert.True(paint.Grow is not null, $"{name} uzamalı");
                        var want = Numbers(grow);
                        Close(want[0], paint.Grow!.Value.Left * w, 1.01, $"{name} uzama solu");
                        Close(want[1], paint.Grow!.Value.Right * w, 1.01, $"{name} uzama sağı");
                    }
                }
                if (expect.TryGetProperty("group", out var group))
                {
                    int? want = group.ValueKind == JsonValueKind.Null ? null : group.GetInt32();
                    Assert.True(paint.Group == want, $"{name} grup {paint.Group} ≠ {want}");
                }
                if (expect.TryGetProperty("pitch", out var pitch) && pitch.ValueKind == JsonValueKind.Number)
                    Close(pitch.GetDouble(), paint.Pitch * h, 0.5, $"{name} satır aralığı");
                if (expect.TryGetProperty("side", out var side))
                {
                    var want = side.ValueKind == JsonValueKind.Null ? null : side.GetString();
                    Assert.True(paint.IconSide == want, $"{name} simge yanı {paint.IconSide} ≠ {want}");
                }
            }
        }
    }

    private static List<ScreenFit.ExactInput> ExactInputs(JsonElement vector) =>
        [.. vector.GetProperty("items").EnumerateArray().Select(item =>
        {
            var box = Numbers(item.GetProperty("box"));
            var grow = item.TryGetProperty("grow", out var g) && g.ValueKind == JsonValueKind.Array ? Numbers(g) : null;
            double? pitch = item.TryGetProperty("pitch", out var p) && p.ValueKind == JsonValueKind.Number ? p.GetDouble() : null;
            var rows = item.TryGetProperty("rows", out var r) && r.ValueKind == JsonValueKind.Number ? r.GetInt32() : 1;
            int? group = item.TryGetProperty("group", out var gr) && gr.ValueKind == JsonValueKind.Number ? gr.GetInt32() : null;
            return new ScreenFit.ExactInput(item.GetProperty("text").GetString()!, box[0], box[1], box[2], box[3], grow?[0], grow?[1],
                item.GetProperty("line").GetDouble(), pitch, rows, item.GetProperty("align").GetString()!, group);
        })];

    private static IReadOnlyList<ScreenFit.ExactPlacement> Place(JsonElement vector, List<ScreenFit.ExactInput> inputs)
    {
        var charWidth = vector.GetProperty("charWidth").GetDouble();
        return ScreenFit.Exact(inputs, (text, size) => new System.Globalization.StringInfo(text).LengthInTextElements * charWidth * size);
    }

    [Fact]
    public void SharedExactVectors()
    {
        using var fixture = Fixture();
        var vectors = fixture.RootElement.GetProperty("exact").EnumerateArray().ToList();
        Assert.NotEmpty(vectors);
        foreach (var vector in vectors)
        {
            var id = vector.GetProperty("id").GetString()!;
            var placed = Place(vector, ExactInputs(vector));
            if (!vector.TryGetProperty("expect", out var expect) || expect.ValueKind != JsonValueKind.Array) continue;
            var expected = expect.EnumerateArray().ToList();
            Assert.True(placed.Count == expected.Count, id);
            for (var i = 0; i < expected.Count; i++)
            {
                var p = placed[i];
                var e = expected[i];
                var lines = e.GetProperty("lines").EnumerateArray().Select(line => line.GetString()!).ToList();
                var name = $"{id} [{string.Join(" | ", lines)}]";
                Assert.True(lines.SequenceEqual(p.Lines), $"{name}: satırlar [{string.Join(" | ", p.Lines)}]");
                Close(e.GetProperty("left").GetDouble(), p.Left, 0.05, $"{name} sol");
                Close(e.GetProperty("top").GetDouble(), p.Top, 0.05, $"{name} üst");
                Close(e.GetProperty("width").GetDouble(), p.Width, 0.05, $"{name} genişlik");
                Close(e.GetProperty("height").GetDouble(), p.Height, 0.05, $"{name} yükseklik");
                Close(e.GetProperty("fontSize").GetDouble(), p.FontSize, 0.05, $"{name} yazı boyu");
                Close(e.GetProperty("lineHeight").GetDouble(), p.LineHeight, 0.05, $"{name} satır aralığı");
                Close(e.GetProperty("rowHeight").GetDouble(), p.RowHeight, 0.05, $"{name} satır yüksekliği");
            }
        }
    }

    private static JsonElement Vector(JsonDocument fixture, string id) =>
        fixture.RootElement.GetProperty("exact").EnumerateArray().First(vector => vector.GetProperty("id").GetString() == id);

    /// <summary>
    /// Kurallar ortak dosyadan bağımsız da: grup içinde yazı boyu eşit, uzun çeviri boş alana uzar, kutu simgeye/ekran
    /// kenarına taşmaz, yazı kesilmez.
    /// </summary>
    [Fact]
    public void GrubunYaziBoyuTekVeUzunCeviriBosAlanaUzar()
    {
        using var fixture = Fixture();
        var vector = Vector(fixture, "grup-esit-boy-bos-alana-uzar");
        var inputs = ExactInputs(vector);
        var placed = Place(vector, inputs);
        Assert.Single(placed.Select(p => Math.Round(p.FontSize * 100)).Distinct());
        for (var i = 0; i < inputs.Count; i++)
        {
            var (input, p) = (inputs[i], placed[i]);
            Assert.Equal(input.Text, string.Join(' ', p.Lines));
            Assert.Equal(input.Right, p.Left + p.Width, 2);
            Assert.True(p.Left >= input.GrowLeft - 0.01, "boş alanın dışına taşmaz");
            Assert.Single(p.Lines);
        }
        // "HEDEF BELİRLE" kendi kutusundan uzun: boş sol tarafa uzar, yazı boyu küçülmez.
        Assert.True(placed[3].Left < inputs[3].Left);
        Assert.Equal(ScreenFit.ExactFont * 20, placed[3].FontSize, 2);
    }

    [Fact]
    public void BosAlanYoksaGrupBirlikteKuculur()
    {
        using var fixture = Fixture();
        var vector = Vector(fixture, "bos-alan-yok-grup-birlikte-kuculur");
        var inputs = ExactInputs(vector);
        var placed = Place(vector, inputs);
        Assert.Single(placed.Select(p => Math.Round(p.FontSize * 100)).Distinct());
        Assert.True(placed[0].FontSize < ScreenFit.ExactFont * 20);
        for (var i = 0; i < inputs.Count; i++)
        {
            var (input, p) = (inputs[i], placed[i]);
            Assert.True(p.Left >= input.GrowLeft - 0.01);
            Assert.True(p.Left + p.Width <= input.GrowRight + 0.01);
            Assert.Equal(input.Text, string.Join(' ', p.Lines));
        }
    }

    /// <summary>Ölçü alanın karesinde alınır, karedeki yere taşınır: örtü, boş alan ve satır aralığı alanla ölçeklenir.</summary>
    [Fact]
    public void OlculerAlandanKareyeTasinir()
    {
        var paint = new TextPaint("#000000", 0.1, new TextBox(0.2, 0.2, 0.4, 0.3)) { Grow = new TextBox(0.1, 0.2, 0.4, 0.3) };
        var placed = paint.PlacedIn(new TextBox(0.5, 0.5, 1, 1));
        Assert.Equal(0.6, placed.Cover.Left, 6);
        Assert.Equal(0.6, placed.Cover.Top, 6);
        Assert.Equal(0.7, placed.Cover.Right, 6);
        Assert.Equal(0.65, placed.Cover.Bottom, 6);
        Assert.Equal(0.55, placed.Grow!.Value.Left, 6);
        Assert.Equal(0.05, placed.Pitch, 6);
    }

    /// <summary>
    /// #1268, #1270: harfi/rakamı olmayan parça (yön tuşu simgesinin "-" okunuşu, renkli nokta "•") sözcük sayılmaz; simge
    /// kutunun ucunda bulunur, kutu simgenin üstüne çizilmez (Mac ile aynı).
    /// </summary>
    [Fact]
    public void HarfsizParcaSozcukSayilmaz()
    {
        Assert.Equal(3, TextPainter.WordCount("- SMASH 'N' GRABS"));
        Assert.Equal(1, TextPainter.WordCount("• Objective"));
        Assert.Equal(1, TextPainter.WordCount("+ CLUBS"));
        Assert.Equal(3, TextPainter.WordCount("Buck's Jewelry & Pawn"));
        Assert.Equal(1, TextPainter.WordCount("I Map"));
        Assert.Equal(2, TextPainter.WordCount("2D VIEW"));
        Assert.Equal(2, TextPainter.WordCount("$1,000 - $10,000"));
        (int L, int R)[] spans = [(0, 20), (28, 90), (98, 112), (120, 180)];
        var found = TextPainter.IconSpans(0, 180, 20.0, TextPainter.WordCount("- SMASH 'N' GRABS"), "left",
            x => spans.Any(s => x >= s.L && x < s.R));
        Assert.NotNull(found.Left);
        Assert.Equal(28, found.TextLeft);
    }

    /// <summary>
    /// #1255: kare dışına taşan kutu (sol, sağ, üst, alt) boş alan taramasını sonsuz döngüye sokmaz; ölçüm biter ve kutular
    /// kareye kırpılır. Nokta okuması kenara sabitlenir; sayaç bütçeyi aşarsa (eski kodda sonsuz döngü) farklı renk döner ki
    /// deneme takılmasın, sonra bütçe aşımı hata sayılır.
    /// </summary>
    [Theory]
    [InlineData(-0.08, 0.4, 0.3, 0.6)]
    [InlineData(0.7, 0.4, 1.08, 0.6)]
    [InlineData(0.3, -0.1, 0.6, 0.15)]
    [InlineData(0.3, 0.85, 0.6, 1.1)]
    [InlineData(-0.2, -0.2, 1.2, 1.2)]
    public void PaintsEndsWhenBoxOverflowsFrame(double left, double top, double right, double bottom)
    {
        const int width = 200, height = 100, budget = 2_000_000;
        var box = new TextBox(left, top, right, bottom);
        var calls = 0;
        var target = new TextPainter.Target(box, 0.1, 1, "#202020", "#F0F0F0", false, "center");
        var paints = TextPainter.Paints([target], width, height, (x, y) =>
        {
            calls++;
            if (calls > budget) return (255, 0, 0);
            int cx = Math.Min(width - 1, Math.Max(0, x)), cy = Math.Min(height - 1, Math.Max(0, y));
            double fx = (double)cx / width, fy = (double)cy / height;
            var ink = fx > Math.Max(0, left) + 0.02 && fx < Math.Min(1, right) - 0.02 && cy % 4 == 0 && fy > Math.Max(0, top)
                      && fy < Math.Min(1, bottom);
            return ink ? (240, 240, 240) : (32, 32, 32);
        });
        Assert.True(calls <= budget, $"sonsuz döngü: {box}");
        var paint = Assert.Single(paints);
        foreach (var b in paint.Grow is { } grow ? new[] { paint.Cover, grow } : new[] { paint.Cover })
        {
            Assert.True(b.Left >= 0 && b.Top >= 0 && b.Right <= 1 && b.Bottom <= 1, $"{box}: {b}");
            Assert.True(b.Left <= b.Right && b.Top <= b.Bottom, $"{box}: {b}");
        }
    }

    /// <summary>
    /// Beta.100 (3407–3409): tek satır okunan sekme çubuğu her karede aynı çevrilir (motora gitmez); kart başlıkları ve sekme
    /// adları sözlükte; haritanın yer adı ve soluk okunan parçası çevrilmez (Mac testTabBarIsStableAndPlaceNamesKept ile aynı).
    /// </summary>
    [Fact]
    public void TabBarIsStableAndPlaceNamesKept()
    {
        Assert.Equal("JASON & LUCIA HARİTA ÖZET", UiCommands.TranslateLabelLoosely("JASON & LUCIA MAP BRIEF"));
        Assert.Equal("JASON & LUCIA HARİTA ÖZET İLERLEME", UiCommands.TranslateLabelLoosely("JASON & LUCIA MAP BRIEF PROGRESS"));
        Assert.Equal("HARİTA ÖZET", UiCommands.TranslateLabelLoosely("MAP BRIEF"));
        Assert.Null(UiCommands.TranslateTabs("Map Brief"));
        Assert.Null(UiCommands.TranslateTabs("MAP SOMETHING"));
        foreach (var label in new[] { "VEHICLES", "WEAPONS", "ANIMALS", "ADD MARKER", "Map" })
            Assert.True(UiCommands.TranslateLabel(label) is not null, label);
        foreach (var place in new[] { "Peregrine Bay", "Shoeless Keys", "Key Lento", "Gambit Bay", "ne Bay" })
            Assert.True(ScreenTranslation.KeepsNames(place), place);
        foreach (var text in new[] { "Add Marker", "Bay", "Go to the Bay", "KEY BINDINGS", "Ambient Sound" })
            Assert.False(ScreenTranslation.KeepsNames(text), text);
    }

    /// <summary>
    /// Beta.100 (3385): menüdeki otomatik alanla kesişen hazır alan okunmaz (tuş listesi iki alana bölünmesin; Mac
    /// testPresetYieldsToMenuArea ile aynı).
    /// </summary>
    [Fact]
    public void PresetYieldsToMenuArea()
    {
        var phone = new WatchedArea(GameAreaPresets.PhoneId, "Messages", new CropRegion(0.45, 0.80, 0.72, 0.99));
        var menu = new WatchedArea("auto-1", ScreenTextDetector.AreaName, new CropRegion(0.70, 0.96, 0.80, 0.98)) { Auto = true };
        Assert.Equal([phone.Id, "auto-1"], RegionWatcher.YieldingPresets([phone, menu]).Select(a => a.Id));
        menu = menu with { Menu = true };
        Assert.Equal(["auto-1"], RegionWatcher.YieldingPresets([phone, menu]).Select(a => a.Id));
        menu = menu with { Region = new CropRegion(0.05, 0.12, 0.4, 0.9) };
        Assert.Equal([phone.Id, "auto-1"], RegionWatcher.YieldingPresets([phone, menu]).Select(a => a.Id));
    }
}
