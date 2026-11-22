// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Kullanıcı bildirimi (X, iki kişi, GTA 6): "Tam ekran" altyazı alanında sağ altta beliren mesaj önizlemesinin ve solda
/// kayarak giren bildirimin çevirisi ekranın ortasına geliyordu. Örnekler ortak deneme dosyasından
/// (core/Tests/CouchSubsCoreTests/Fixtures/screen-notice.json; Mac ScreenNoticeTests.swift ve Android ScreenNoticeTest.kt
/// aynı dosyayı okur).
/// </summary>
public class ScreenNoticeTests
{
    private static double[] Numbers(JsonElement element) => [.. element.EnumerateArray().Select(v => v.GetDouble())];

    private static TextBox Box(JsonElement element)
    {
        var b = Numbers(element);
        return new TextBox(b[0], b[1], b[2], b[3]);
    }

    private static Reading Lines(JsonElement lines) => new(lines.EnumerateArray()
        .Select(line => new TextLine(line.GetProperty("text").GetString()!, Box(line.GetProperty("box")))).ToList());

    [Fact]
    public void SharedVectors()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("screen-notice.json")));
        foreach (var vector in fixture.RootElement.GetProperty("cases").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString();
            var area = Box(vector.GetProperty("area"));
            var notices = new ScreenNotices();
            foreach (var frame in vector.GetProperty("frames").EnumerateArray())
            {
                var at = frame.GetProperty("at").GetInt64();
                var edge = new List<Reading>();
                var block = Lines(frame.GetProperty("lines")).SubtitleBlock(area, null, null, b => edge.Add(b.PlacedIn(area)));
                Assert.True(frame.GetProperty("subtitle").GetString() == block.Text, $"{name} @{at}: {block.Text}");
                notices.Observe(edge, at);
                var expected = frame.GetProperty("areas").EnumerateArray().ToList();
                Assert.True(expected.Select(e => e.GetProperty("id").GetString()).SequenceEqual(notices.Areas.Select(a => a.Id)),
                            $"{name} @{at}: {string.Join(",", notices.Areas.Select(a => a.Id))}");
                foreach (var (got, want) in notices.Areas.Zip(expected))
                {
                    var r = Numbers(want.GetProperty("region"));
                    Assert.Equal(r[0], got.Region.Left, 6);
                    Assert.Equal(r[1], got.Region.Top, 6);
                    Assert.Equal(r[2], got.Region.Right, 6);
                    Assert.Equal(r[3], got.Region.Bottom, 6);
                    Assert.True(got.Auto);
                    // Bölge asla ekranın ortasını kaplamaz.
                    Assert.False(got.Region.Left < 0.5 && got.Region.Right > 0.5);
                }
            }
        }
    }

    [Fact]
    public void Rules()
    {
        Assert.True(ScreenNotices.IsWholeScreen(new TextBox(0, 0, 1, 1)));
        Assert.False(ScreenNotices.IsWholeScreen(new TextBox(0.14, 0.62, 0.86, 0.97)));
        Assert.True(ScreenNotices.IsNotice(new TextBox(0.74, 0.86, 0.97, 0.92)));
        Assert.True(ScreenNotices.IsNotice(new TextBox(0.02, 0.4, 0.28, 0.43)));
        // Ortadan geçen ya da ortaya yakın blok bildirim değildir; sıfır alanlı kutu da.
        Assert.False(ScreenNotices.IsNotice(new TextBox(0.3, 0.8, 0.7, 0.84)));
        Assert.False(ScreenNotices.IsNotice(new TextBox(0.55, 0.8, 0.62, 0.84)));
        Assert.False(ScreenNotices.IsNotice(new TextBox(0.8, 0.8, 0.8, 0.84)));
        Assert.True(ScreenNotices.IsNotice("auto-notice-3"));
        Assert.False(ScreenNotices.IsNotice("auto-3"));
    }
}
