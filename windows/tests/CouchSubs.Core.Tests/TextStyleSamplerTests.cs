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
}
