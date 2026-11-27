// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// GTA 6 telefon aramasının 30 sn'lik durum satırı (X, beta-105: "telefon komple çalışmıyor"; #1385'in beta-104 günlüğünde
/// telefon hiç bulunamayınca tek satır yoktu). Ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/phone-search-status.json
/// (Mac/iPhone PhoneSearchStatusTests.swift, Android PhoneSearchStatusTest.kt aynı durumları koşar).
/// </summary>
public class PhoneSearchStatusTests
{
    private static JsonElement Vectors() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("phone-search-status.json"))).RootElement;

    private static GamePhoneGeometry.Step Step(string name) => Enum.Parse<GamePhoneGeometry.Step>(name, ignoreCase: true);

    [Fact]
    public void SharedCases()
    {
        foreach (var item in Vectors().GetProperty("cases").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString();
            var status = new PhoneSearchStatus();
            var due = item.GetProperty("due").EnumerateArray().Select(d => d.GetBoolean()).ToArray();
            var index = 0;
            foreach (var sample in item.GetProperty("samples").EnumerateArray())
            {
                var step = sample.GetProperty("step");
                GamePhoneGeometry.Probe? probe = step.ValueKind == JsonValueKind.Null ? null
                    : new GamePhoneGeometry.Probe(Step(step.GetString()!), -1, null, sample.GetProperty("level").GetInt32());
                Assert.True(due[index] == status.Note(probe, sample.GetProperty("seen").GetBoolean(), sample.GetProperty("at").GetInt64()),
                    $"{name} #{index}");
                index++;
            }
            var frame = item.GetProperty("frame");
            Assert.Equal(item.GetProperty("line").GetString(), status.Line(item.GetProperty("open").GetBoolean(),
                item.GetProperty("width").GetInt32(), item.GetProperty("height").GetInt32(), item.GetProperty("median").GetInt32(),
                frame.ValueKind == JsonValueKind.Null ? null : frame.GetString()));
        }
    }

    [Fact]
    public void SharedMedians()
    {
        foreach (var item in Vectors().GetProperty("median").EnumerateArray())
            Assert.Equal(item.GetProperty("median").GetInt32(),
                PhoneSearchStatus.Median(item.GetProperty("tones").EnumerateArray().Select(t => t.GetInt32()).ToArray()));
    }

    /// <summary>Satırdan sonra pencere baştan başlar: sonraki satır yine 30 sn sonra.</summary>
    [Fact]
    public void WindowRestartsAfterLine()
    {
        var status = new PhoneSearchStatus();
        Assert.False(status.Note(null, false, 0));
        Assert.True(status.Note(null, false, 30_000));
        status.Line(false, 1280, 720, 0, null);
        Assert.False(status.Note(null, false, 31_000));
        Assert.False(status.Note(null, false, 60_000));
        Assert.True(status.Note(null, false, 61_000));
    }

    /// <summary>İzleyici telefon hiç bulunamasa da 30 sn'de bir satır yazar (önceden sessizdi).</summary>
    [Fact]
    public void TrackerLogsStatusEvenWhenPhoneIsNeverFound()
    {
        var pixels = new byte[800 * 450 * 4];
        Array.Fill(pixels, (byte)40);
        var frame = new Frame(pixels, 800, 450, 800 * 4);
        var lines = new List<string>();
        var tracker = new GamePhoneTracker { Log = lines.Add };
        for (long now = 1_000; now <= 32_000; now += 400) tracker.TrySample(frame, now, out _);
        var status = lines.Where(l => l.Contains("telefon arama durumu")).ToList();
        Assert.Single(status);
        Assert.Contains("telefon kapalı", status[0]);
        Assert.Contains("0 bulundu", status[0]);
        Assert.Contains("ortanca parlaklık 40/255, kare 800x450", status[0]);
        Assert.EndsWith("kare 800x450", status[0]);
    }

    /// <summary>Xbox karesinin biçimi (<see cref="Frame.Source"/>, #1385) satırın sonunda.</summary>
    [Fact]
    public void TrackerStatusCarriesTheXboxFrameFormat()
    {
        var pixels = new byte[800 * 450 * 4];
        Array.Fill(pixels, (byte)40);
        var frame = new Frame(pixels, 800, 450, 800 * 4) { Source = "Xbox JPEG 800×450 (akış 1920×1080, kalite %80), BGRA adım 3200" };
        var lines = new List<string>();
        var tracker = new GamePhoneTracker { Log = lines.Add };
        for (long now = 1_000; now <= 32_000; now += 400) tracker.TrySample(frame, now, out _);
        var status = Assert.Single(lines, l => l.Contains("telefon arama durumu"));
        Assert.EndsWith("kare 800x450, Xbox JPEG 800×450 (akış 1920×1080, kalite %80), BGRA adım 3200", status);
    }
}
