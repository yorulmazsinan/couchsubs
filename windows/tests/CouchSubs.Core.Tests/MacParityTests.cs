// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Mac #690 ile eşitlik: alan birleştirme, gruplar, hizalı etiket sütunu kanıtı.</summary>
public class MacParityTests
{
    [Fact]
    public void ShortLastLineStaysInItsParagraphAndUppercaseHeaderIsItsOwnBlock()
    {
        var reading = new Reading(
        [
            new TextLine("ROB VICKI'S BOSS", new TextBox(0.1, 0.10, 0.5, 0.18)),
            new TextLine("Vicki wants to rob her boss and split the", new TextBox(0.05, 0.25, 0.95, 0.33)),
            new TextLine("cash. Meet her at Delights.", new TextBox(0.05, 0.36, 0.6, 0.44)),
        ]);
        var candidate = RegionWatcher.MakeCandidate(reading, new CropRegion(0, 1, 0, 1), auto: true);
        Assert.Equal(["ROB VICKI'S BOSS", "Vicki wants to rob her boss and split the cash. Meet her at Delights."], candidate.Paragraphs);
        Assert.Equal(2, candidate.Blocks!.Count);
    }

    [Fact]
    public void AllLabelGroupBecomesOneBlockPerLine()
    {
        var reading = new Reading(
        [
            new TextLine("RECENTER", new TextBox(0.5, 0.10, 0.9, 0.16)),
            new TextLine("3D VIEW", new TextBox(0.6, 0.20, 0.9, 0.26)),
            new TextLine("ADD MARKER", new TextBox(0.45, 0.30, 0.9, 0.36)),
        ]);
        var candidate = RegionWatcher.MakeCandidate(reading, new CropRegion(0, 1, 0, 1), auto: true);
        Assert.Equal(3, candidate.Blocks!.Count);
    }

    /// <summary>Dokulu zeminde sağa yaslı, farklı uzunlukta üç etiket (tuş çubuğu): hizalı sütun arayüz sayılır.</summary>
    [Fact]
    public void RightAlignedLabelColumnOnATexturedGroundIsInterface()
    {
        var random = new Random(5);
        var noise = new byte[640 * 360];
        random.NextBytes(noise);
        var frame = Frame.Blank(640, 360);
        for (var y = 0; y < 360; y++)
            for (var x = 0; x < 640; x++)
            {
                var value = (byte)(noise[y * 640 + x] % 110);
                // Satırlar 200, 220, 240'ta; sağ kenar 620, sol kenar 500/540/460 (dağınık).
                foreach (var (top, left) in new[] { (200, 500), (220, 540), (240, 460) })
                    if (y >= top + 4 && y < top + 16 && x >= left && x < 620 && (y - top) % 6 is 2 or 3 && x % 5 < 2) value = 240;
                var p = y * frame.Stride + x * 4;
                frame.Pixels[p] = frame.Pixels[p + 1] = frame.Pixels[p + 2] = value;
            }
        var detector = new ScreenTextDetector();
        for (var time = 0; time <= 800; time += 100) detector.Sample(frame, time, []);
        var area = Assert.Single(detector.Areas);
        Assert.True(area.Region.Right > 0.95 && area.Region.Top < 0.56);
    }
}
