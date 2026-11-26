// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Mac TextStyleSamplerTests ve Android TextStyleSamplerTest ile aynı sentetik görüntüler.</summary>
public class TextStyleSamplerTests
{
    /// <summary>Düz zeminde dikey çizgilerden "yazı": her 10 pikselde <paramref name="stroke"/> piksel yazı rengi.</summary>
    private static Frame Text((byte R, byte G, byte B) ground, (byte R, byte G, byte B) ink, int stroke, int width = 400, int height = 60)
    {
        var frame = Frame.Blank(width, height);
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var isInk = y is >= 15 and < 45 && x % 10 < stroke;
                var (r, g, b) = isInk ? ink : ground;
                var p = y * frame.Stride + x * 4;
                frame.Pixels[p] = b;
                frame.Pixels[p + 1] = g;
                frame.Pixels[p + 2] = r;
                frame.Pixels[p + 3] = 255;
            }
        return frame;
    }

    private static readonly TextBox Whole = new(0, 10.0 / 60, 1, 50.0 / 60);

    [Fact]
    public void DarkBoxWithWhiteTextIsLightOnDarkAndFlat()
    {
        var (surface, look) = TextStyleSampler.Sample(Text((20, 22, 30), (240, 240, 240), 2), Whole,
            [new TextLine("Meet Vicki at the bar tonight", Whole)], "Meet Vicki at the bar tonight");
        Assert.Equal("#14161E", surface.Background);
        Assert.Equal("#F0F0F0", surface.Foreground);
        Assert.True(look.Flat);
        Assert.False(look.Bold);
        Assert.False(look.Upper);
    }

    [Fact]
    public void LightGroundWithDarkTextIsDarkOnLight()
    {
        var (surface, _) = TextStyleSampler.Sample(Text((235, 235, 225), (15, 15, 15), 2), Whole,
            [new TextLine("Lamar has sent you a message", Whole)], "Lamar has sent you a message");
        Assert.Equal("#EBEBE1", surface.Background);
        Assert.Equal("#0F0F0F", surface.Foreground);
    }

    [Fact]
    public void UppercaseHeavyHeaderIsBoldUpperAndCondensed()
    {
        var header = new TextBox(0, 10.0 / 60, 0.6, 50.0 / 60);
        var (_, look) = TextStyleSampler.Sample(Text((20, 22, 30), (240, 240, 240), 5), header,
            [new TextLine("ROB VICKI'S BOSS", header)], "ROB VICKI'S BOSS");
        Assert.True(look.Bold);
        Assert.True(look.Upper);
        Assert.True(look.Condensed);
    }

    [Fact]
    public void NoisyGroundIsNotFlat()
    {
        var frame = Text((60, 60, 60), (250, 250, 250), 2);
        var random = new Random(1);
        for (var p = 0; p < frame.Pixels.Length; p += 4)
            if (frame.Pixels[p] == 60)
                frame.Pixels[p] = frame.Pixels[p + 1] = frame.Pixels[p + 2] = (byte)random.Next(10, 120);
        var (_, look) = TextStyleSampler.Sample(frame, Whole, [new TextLine("Go to the Saloon now", Whole)], "Go to the Saloon now");
        Assert.False(look.Flat);
    }

    /// <summary>
    /// #1268 (gerçek karede "ADD MARKER"): kontur yazının zemin kümesi denizle kontur grisinin karışımı; ikisinin parlaklığı
    /// aynı (125) ama rengi değil. Zemin renk sapmasıyla düz sayılmaz, yanındaki şerit de konturlu olduğundan bir şerit ötedeki
    /// düz deniz zemin olur. Android eskiden sapmayı yalnız parlaklıktan ölçüyor, kutuyu grimsi çiziyordu (Mac ve Android ile
    /// aynı görüntü; gerçek kare Mac'te ve Android'de denenir).
    /// </summary>
    [Fact]
    public void LumaFlatButColouredGroundTakesTheFarBand()
    {
        var frame = Frame.Blank(400, 100);
        for (var y = 0; y < 100; y++)
            for (var x = 0; x < 400; x++)
            {
                var (r, g, b) = y is >= 30 and < 70 && x % 16 < 5 ? (240, 240, 240)
                    : y is >= 20 and < 80 && x % 16 is >= 5 and < 10 ? (125, 125, 125) : (58, 148, 187);
                var p = y * frame.Stride + x * 4;
                frame.Pixels[p] = (byte)b;
                frame.Pixels[p + 1] = (byte)g;
                frame.Pixels[p + 2] = (byte)r;
                frame.Pixels[p + 3] = 255;
            }
        var box = new TextBox(0.1, 0.3, 0.9, 0.7);
        var (surface, look) = TextStyleSampler.Sample(frame, box, [new TextLine("ADD MARKER", box)], "ADD MARKER");
        Assert.False(look.Flat);
        static int Distance(string hex, int r, int g, int b)
        {
            var v = Convert.ToInt32(hex[1..], 16);
            return Math.Max(Math.Abs(((v >> 16) & 0xff) - r), Math.Max(Math.Abs(((v >> 8) & 0xff) - g), Math.Abs((v & 0xff) - b)));
        }
        Assert.True(Distance(surface.Background, 58, 148, 187) <= 8, surface.Background);
        Assert.True(Distance(surface.Foreground, 240, 240, 240) <= 8, surface.Foreground);
    }

    [Fact]
    public void AlignmentFollowsTheLineEdges()
    {
        var frame = Text((20, 22, 30), (240, 240, 240), 2);
        TextLine Line(double left, double right, double top) => new("Some words here", new TextBox(left, top, right, top + 0.2));
        Assert.Equal("left", TextStyleSampler.Sample(frame, Whole, [Line(0.1, 0.9, 0.1), Line(0.1, 0.5, 0.4)], "a").Look.Align);
        Assert.Equal("center", TextStyleSampler.Sample(frame, Whole, [Line(0.1, 0.9, 0.1), Line(0.3, 0.7, 0.4)], "a").Look.Align);
        Assert.Equal("right", TextStyleSampler.Sample(frame, Whole, [Line(0.1, 0.9, 0.1), Line(0.5, 0.9, 0.4)], "a").Look.Align);
    }

    [Fact]
    public void TurkishUppercaseKeepsDottedI()
    {
        Assert.Equal("VİCKİ'NİN PATRONUNU SOY", TextStyleSampler.TurkishUpper("vicki'nin patronunu soy"));
        Assert.Equal("ILIK SU", TextStyleSampler.TurkishUpper("ılık su"));
        Assert.True(TextStyleSampler.IsUpper("ROB VICKI'S BOSS"));
        Assert.False(TextStyleSampler.IsUpper("Rob Vicki's boss"));
    }

    [Fact]
    public void AutoAreaBlocksCarryTheLookAndUppercaseTranslation()
    {
        var frame = Text((20, 22, 30), (240, 240, 240), 5);
        var header = new TextBox(0, 10.0 / 60, 0.6, 50.0 / 60);
        var reading = new Reading([new TextLine("ROB VICKI'S BOSS", header)]);
        var candidate = RegionWatcher.MakeCandidate(reading, new CropRegion(0, 1, 0, 1), frame, auto: true);
        var block = Assert.Single(candidate.Blocks!);
        Assert.NotNull(block.Look);
        Assert.True(block.Look!.Upper);
        Assert.Equal("#14161E", block.Style!.Background);
        // Kullanıcının alanında (otomatik değil) tek grup eskisi gibi bloksuzdur.
        Assert.Null(RegionWatcher.MakeCandidate(reading, new CropRegion(0, 1, 0, 1), frame).Blocks);
    }

    /// <summary>
    /// Kullanıcının ek alanı ve hazır alan, otomatik alanla aynı çizim kipini alır (#1324): tek kutu tuş simgelerini örtmez,
    /// yazı boyu özgünden ölçülür (Mac ve Android aynı).
    /// </summary>
    [Fact]
    public void ExtraAreaGetsTheAutoAreaPaintMode()
    {
        // Koyu zeminde solda tek satır yazı; sağı ve altı boş.
        var frame = Frame.Blank(400, 120);
        for (var y = 0; y < 120; y++)
            for (var x = 0; x < 400; x++)
            {
                var ink = y is >= 15 and < 45 && x is >= 20 and < 200 && x % 10 < 5;
                var p = y * frame.Stride + x * 4;
                (frame.Pixels[p + 2], frame.Pixels[p + 1], frame.Pixels[p]) = ink ? ((byte)240, (byte)240, (byte)240) : ((byte)20, (byte)22, (byte)30);
                frame.Pixels[p + 3] = 255;
            }
        var reading = new Reading([new TextLine("ROB VICKI'S BOSS", new TextBox(20.0 / 400, 15.0 / 120, 200.0 / 400, 45.0 / 120))]);
        var whole = new CropRegion(0, 1, 0, 1);
        var auto = Assert.Single(RegionWatcher.MakeCandidate(reading, whole, frame, auto: true).Blocks!).Paint;
        var extra = Assert.Single(RegionWatcher.MakeCandidate(reading, whole, frame, styled: true).Blocks!).Paint;
        Assert.NotNull(auto);
        Assert.NotNull(extra);
        Assert.Equal(auto!.Mode, extra!.Mode);
        Assert.NotEqual(PaintMode.Cover, extra.Mode);
        Assert.Equal(auto.Pitch, extra.Pitch, 9);
    }

    /// <summary>
    /// Görev/hedef satırının çevirisi altyazıdan ve öbür ekran yazılarından ayrı görünür (beta.100): özgün zemin yerine koyu
    /// kehribar kutu, birebir çizim yok, başında hedef imi (Mac ve Android aynı).
    /// </summary>
    [Fact]
    public void MissionLineHasItsOwnAmberLook()
    {
        var frame = Text((20, 22, 30), (240, 240, 240), 5);
        var reading = new Reading([new TextLine("Lose the cops", new TextBox(0, 10.0 / 60, 0.6, 50.0 / 60))]);
        var other = Assert.Single(RegionWatcher.MakeCandidate(reading, new CropRegion(0, 1, 0, 1), frame, auto: true).Blocks!);
        Assert.Equal("#14161E", other.Style!.Background);
        Assert.False(other.Mission);
        var candidate = RegionWatcher.MakeCandidate(reading, new CropRegion(0, 1, 0, 1), frame, auto: true, kind: ScreenTextKind.Mission);
        var block = Assert.Single(candidate.Blocks!);
        Assert.True(block.Mission);
        Assert.Null(block.Paint);
        Assert.Equal(MissionLine.Style, block.Style);
        var item = Assert.Single(RegionWatcher.RenderBlocks(candidate, candidate.Blocks!, ["Polislerden kurtul"], [false], [])).Item;
        Assert.Equal("\u25BA Polislerden kurtul", item.Translation);
        Assert.Equal("#7A4E00", item.Style!.Background);
    }
}
