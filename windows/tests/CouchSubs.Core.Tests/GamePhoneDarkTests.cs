// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Karanlık sahnede ve koyu ekranlı GTA 6 telefonu (X, beta.104: "telefonda parlaklık varsa çeviri oluyor karanlıksa
/// olmuyor"). Ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/phone-dark.json (Mac/iPhone
/// GamePhoneDarkTests.swift, Android GamePhoneDarkTest.kt aynı durumları koşar); telefonsuz karelerin karanlık hâlleri
/// phone-first-sighting.json'da (noPhone).
/// </summary>
public class GamePhoneDarkTests
{
    private static JsonElement Vectors() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("phone-dark.json"))).RootElement;

    private static GamePhoneGeometry.Step Step(string name) => Enum.Parse<GamePhoneGeometry.Step>(name, ignoreCase: true);

    [Fact]
    public void DarkSceneGains()
    {
        foreach (var item in Vectors().GetProperty("gains").EnumerateArray())
        {
            var level = item.GetProperty("level").GetInt32();
            Assert.Equal(item.GetProperty("gains").EnumerateArray().Select(g => g.GetInt32()).ToArray(), GamePhoneGeometry.DarkGains(level));
        }
    }

    [Fact]
    public void DarkFramesFindThePhone()
    {
        foreach (var item in Vectors().GetProperty("frames").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString();
            var frame = GamePhoneFirstSightingTests.Load(item.GetProperty("frame").GetString()!, item.GetProperty("transform").GetString()!);
            Assert.True(GamePhoneGeometry.TryLocate(frame, null, out _, out var probe), $"{name}: {probe}");
            if (item.TryGetProperty("gain", out var gain) && gain.GetBoolean()) Assert.True(probe.Gain > 256, $"{name}: {probe}");
            // İzleyici de iki gözlemde açar.
            var tracker = new GamePhoneTracker();
            tracker.TrySample(frame, 0, out var first);
            Assert.True(first is null, name);
            tracker.TrySample(frame, 330, out var second);
            Assert.True(second is not null, name);
        }
    }

    [Fact]
    public void DarkScreenPreparation()
    {
        foreach (var item in Vectors().GetProperty("darkScreen").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString();
            var counts = new int[256];
            var total = 0;
            foreach (var pair in item.GetProperty("histogram").EnumerateArray())
            {
                var values = pair.EnumerateArray().Select(v => v.GetInt32()).ToArray();
                counts[values[0]] += values[1];
                total += values[1];
            }
            var map = PhoneDarkScreen.Mapping(counts, total);
            Assert.True((map is not null) == item.GetProperty("prepared").GetBoolean(), name);
            if (item.TryGetProperty("map", out var expected))
                foreach (var pair in expected.EnumerateArray())
                {
                    var values = pair.EnumerateArray().Select(v => v.GetInt32()).ToArray();
                    Assert.True(map![values[0]] == values[1], $"{name}: {values[0]} → {map[values[0]]}");
                }
        }
    }

    /// <summary>Düzeltilmiş ekran (BGRA): koyu temada gri, ters çevrilmiş; aydınlık ekran aynen.</summary>
    [Fact]
    public void FlatScreenIsPreparedOnlyWhenDark()
    {
        static Frame Screen((byte B, byte G, byte R) background, (byte B, byte G, byte R) ink)
        {
            var frame = Frame.Blank(10, 10);
            for (var i = 0; i < 100; i++)
            {
                var (b, g, r) = i < 90 ? background : ink;
                (frame.Pixels[i * 4], frame.Pixels[i * 4 + 1], frame.Pixels[i * 4 + 2], frame.Pixels[i * 4 + 3]) = (b, g, r, 255);
            }
            return frame;
        }
        var light = Screen((235, 230, 230), (25, 20, 20));
        var before = light.Pixels.ToArray();
        Assert.False(PhoneDarkScreen.Prepare(light));
        Assert.Equal(before, light.Pixels);
        var dark = Screen((20, 20, 20), (220, 220, 220));
        Assert.True(PhoneDarkScreen.Prepare(dark));
        Assert.Equal(new byte[] { 255, 255, 255, 255 }, dark.Pixels[..4]);
        Assert.Equal(new byte[] { 0, 0, 0, 255 }, dark.Pixels[^4..]);
    }

    [Fact]
    public void DarkMissIsLoggedWithBrightness()
    {
        var spec = Vectors().GetProperty("missLog");
        var frame = GamePhoneFirstSightingTests.Load(spec.GetProperty("frame").GetString()!, spec.GetProperty("transform").GetString()!);
        var interval = spec.GetProperty("intervalMs").GetInt64();
        var duration = spec.GetProperty("durationMs").GetInt64();
        var log = new List<string>();
        var tracker = new GamePhoneTracker { Log = log.Add };
        for (long t = 0; t <= duration; t += interval)
        {
            tracker.TrySample(frame, t, out var visible);
            Assert.Null(visible);
        }
        var missed = log.Where(line => line.Contains("telefon ilk aramada bulunamadı")).ToList();
        Assert.True(missed.Count == 1, string.Join(" | ", log));
        foreach (var part in spec.GetProperty("contains").EnumerateArray()) Assert.Contains(part.GetString()!, missed[0]);
    }

    [Fact]
    public void DarkMissLineText()
    {
        var spec = Vectors().GetProperty("missLine");
        int Int(string key) => spec.GetProperty(key).GetInt32();
        Assert.Equal(spec.GetProperty("line").GetString(),
            PhoneTrace.MissedFirst(Int("samples"), PhoneTrace.Reason(Step(spec.GetProperty("furthest").GetString()!)),
                PhoneTrace.Reason(Step(spec.GetProperty("common").GetString()!)), Int("commonCount"), Int("side"), Int("unconfirmed"),
                Int("strict"), Int("level"), Int("gain")));
    }
}
