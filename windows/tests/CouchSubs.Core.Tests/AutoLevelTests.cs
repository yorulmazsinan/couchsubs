// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using Xunit.Abstractions;

namespace CouchSubs.Core.Tests;

/// <summary>
/// #903: AutoLevel satır dilimleriyle yeniden yazıldı. Sonuç eski döngüyle (burada 64 bit sıralı başvuru) bayt bayt
/// aynı olmalı; 4K/8K karelerde, dolgulu satırlarda ve tutarsız karelerde de.
/// </summary>
public class AutoLevelTests(ITestOutputHelper output)
{
    /// <summary>Eski algoritma, sıralar long ile: karşılaştırma için başvuru.</summary>
    private static Frame Reference(Frame image)
    {
        if (!image.IsConsistent || image.Width == 0 || image.Height == 0) return image;
        var hist = new long[256];
        for (long y = 0; y < image.Height; y++)
            for (long x = 0; x < image.Width; x++)
            {
                var i = (y * image.Stride) + (x * 4);
                hist[(image.Pixels[i + 2] * 3 + image.Pixels[i + 1] * 6 + image.Pixels[i]) / 10]++;
            }
        var limit = (double)image.Width * image.Height * 0.005;
        long count = 0;
        var top = 255;
        for (; top > 0; top--)
        {
            count += hist[top];
            if (count >= limit) break;
        }
        if (top >= 235 || top < 60) return image;
        var scale = 250.0 / top;
        var result = new byte[(long)image.Width * image.Height * 4];
        for (long y = 0; y < image.Height; y++)
            for (long x = 0; x < image.Width; x++)
            {
                long i = (y * image.Stride) + (x * 4), o = ((y * image.Width) + x) * 4;
                for (var c = 0; c < 3; c++) result[o + c] = (byte)Math.Min(255, image.Pixels[i + c] * scale);
                result[o + 3] = 255;
            }
        return new Frame(result, image.Width, image.Height, image.Width * 4);
    }

    /// <summary>Karanlık kare (en parlak kısım ~180): AutoLevel kareyi yeniden yazar. Satır sonunda dolgu olabilir.</summary>
    private static Frame Dark(int width, int height, int padding = 0, int seed = 1)
    {
        var stride = (width * 4) + padding;
        var pixels = new byte[(long)stride * height];
        var random = new Random(seed);
        random.NextBytes(pixels);
        for (var i = 0; i < pixels.Length; i++) pixels[i] = (byte)(pixels[i] % 180);
        return new Frame(pixels, width, height, stride);
    }

    [Theory]
    [InlineData(64, 48, 0)]
    [InlineData(640, 120, 0)]
    [InlineData(641, 121, 12)]
    [InlineData(1920, 1080, 256)]
    public void MatchesTheOldLoopByteForByte(int width, int height, int padding)
    {
        var image = Dark(width, height, padding, seed: width);
        var expected = Reference(image);
        var actual = TextImage.AutoLevel(image);
        Assert.NotSame(image, actual);
        Assert.Equal((expected.Width, expected.Height, expected.Stride), (actual.Width, actual.Height, actual.Stride));
        Assert.True(expected.Pixels.AsSpan().SequenceEqual(actual.Pixels));
    }

    [Theory]
    [InlineData(3840, 2160)]
    [InlineData(7680, 4320)]
    public void LargeFramesAreLeveledAndMatchTheReference(int width, int height)
    {
        var image = Dark(width, height, padding: 64);
        TextImage.AutoLevel(Dark(64, 48)); // ısınma
        var watch = Stopwatch.StartNew();
        var actual = TextImage.AutoLevel(image);
        watch.Stop();
        output.WriteLine($"AutoLevel {width}x{height}: {watch.Elapsed.TotalMilliseconds:F1} ms");
        Assert.Equal(width * 4, actual.Stride);
        Assert.True(actual.IsConsistent);
        Assert.True(Reference(image).Pixels.AsSpan().SequenceEqual(actual.Pixels));
    }

    [Fact]
    public void BrightOrBlackFramesAreReturnedAsIs()
    {
        var bright = new Frame(Enumerable.Repeat((byte)250, 64 * 48 * 4).ToArray(), 64, 48, 64 * 4);
        Assert.Same(bright, TextImage.AutoLevel(bright));
        var black = Frame.Blank(64, 48);
        Assert.Same(black, TextImage.AutoLevel(black));
    }

    [Fact]
    public void InconsistentFramesAreNotTouched()
    {
        // Negatif satır aralığı (alttan yukarı görüntü) ve dizisine sığmayan kare döngüye girmez.
        var negative = new Frame(new byte[64 * 48 * 4], 64, 48, -(64 * 4));
        Assert.Same(negative, TextImage.AutoLevel(negative));
        var shortArray = new Frame(new byte[(64 * 48 * 4) - 1], 64, 48, 64 * 4);
        Assert.Same(shortArray, TextImage.AutoLevel(shortArray));
        var shortStride = new Frame(new byte[64 * 48 * 4], 64, 48, 63 * 4);
        Assert.Same(shortStride, TextImage.AutoLevel(shortStride));
        var empty = new Frame([], 0, 0, 0);
        Assert.Same(empty, TextImage.AutoLevel(empty));
    }

    [Fact]
    public void WhiteTextOnlyReadsPaddedRows()
    {
        // Satır dilimine geçen beyaz yazı süzgeci dolgulu satırda dolguyu okumaz: dolgu beyaz olsa da sonuç aynı.
        var plain = Dark(200, 60, padding: 0, seed: 7);
        var padded = new Frame(new byte[((200 * 4) + 40) * 60], 200, 60, (200 * 4) + 40);
        Array.Fill(padded.Pixels, (byte)255);
        for (var y = 0; y < 60; y++) Buffer.BlockCopy(plain.Pixels, y * 800, padded.Pixels, y * 840, 800);
        Assert.True(TextImage.WhiteTextOnly(plain).Pixels.AsSpan().SequenceEqual(TextImage.WhiteTextOnly(padded).Pixels));
    }
}
