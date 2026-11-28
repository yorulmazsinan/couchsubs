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

    /// <summary>Ton eşitleme eşlemesi (<see cref="GamePhoneGeometry.Equalization"/>): her platformda aynı tonlar.</summary>
    [Fact]
    public void EqualizationMap()
    {
        foreach (var item in Vectors().GetProperty("equalization").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString();
            var counts = new int[1021];
            var total = 0;
            foreach (var pair in item.GetProperty("counts").EnumerateArray())
            {
                var values = pair.EnumerateArray().Select(v => v.GetInt32()).ToArray();
                counts[values[0]] += values[1];
                total += values[1];
            }
            var map = GamePhoneGeometry.Equalization(counts, total);
            foreach (var pair in item.GetProperty("map").EnumerateArray())
            {
                var values = pair.EnumerateArray().Select(v => v.GetInt32()).ToArray();
                Assert.True(map[values[0]] == values[1], $"{name}: {values[0]} → {map[values[0]]}");
            }
        }
    }

    /// <summary>Ton eşitleme simsiyaha yakın karede denenmez (<see cref="GamePhoneGeometry.Equalizable"/>): her platformda aynı.</summary>
    [Fact]
    public void EqualizationNeedsABrightEnd()
    {
        foreach (var item in Vectors().GetProperty("equalizable").EnumerateArray())
        {
            var counts = new int[1021];
            var total = 0;
            foreach (var pair in item.GetProperty("counts").EnumerateArray())
            {
                var values = pair.EnumerateArray().Select(v => v.GetInt32()).ToArray();
                counts[values[0]] += values[1];
                total += values[1];
            }
            Assert.True(GamePhoneGeometry.Equalizable(counts, total) == item.GetProperty("equalizable").GetBoolean(), item.GetProperty("name").GetString());
        }
    }

    /// <summary>
    /// Gece, kapalı yer ve karanlık sahne: gerçek telefon karelerinin karartılmış hâlleri (parlaklık × k, gama, gece renk
    /// ayarı, kararan kenarlar, koyu arka plan; kare ortalaması ~5–60/255) telefonu açar.
    /// </summary>
    [Fact]
    public void DarkVariantsOpenThePhone()
    {
        foreach (var item in Vectors().GetProperty("darkVariants").EnumerateArray())
        {
            var name = item.GetProperty("frame").GetString()!;
            foreach (var transform in item.GetProperty("transforms").EnumerateArray().Select(t => t.GetString()!))
            {
                var frame = GamePhoneFirstSightingTests.Load(name, transform);
                var tracker = new GamePhoneTracker();
                var opened = false;
                for (var i = 0; i < 3; i++)
                {
                    tracker.TrySample(frame, i * 330L, out var visible);
                    opened |= visible is not null;
                }
                GamePhoneGeometry.TryLocate(frame, null, out _, out var probe);
                Assert.True(opened, $"{name} ({transform}): {probe}");
            }
        }
    }

    /// <summary>İz benzerliği (<see cref="PhonePrint.Similarity"/>): parlaklıktan ve karşıtlıktan bağımsız; düz ya da çok sönük iz 0.</summary>
    [Fact]
    public void PrintSimilarity()
    {
        foreach (var item in Vectors().GetProperty("printSimilarity").EnumerateArray())
        {
            var a = item.GetProperty("a").EnumerateArray().Select(v => v.GetInt32()).ToArray();
            var b = item.GetProperty("b").EnumerateArray().Select(v => v.GetInt32()).ToArray();
            var expected = item.GetProperty("similarity").GetDouble();
            var actual = PhonePrint.Similarity(a, b);
            Assert.True(Math.Abs(actual - expected) < 1e-6, $"{item.GetProperty("name").GetString()}: {actual}");
        }
    }

    /// <summary>
    /// Telefon aydınlıkta açılır, sahne kararır (sıkı arama ıskalar): son yerindeki iziyle açık kalır, okuma sürer. Telefon
    /// indirilince (telefonsuz kare) iz tutmaz, telefon her zamanki sürede kapanır.
    /// </summary>
    [Fact]
    public void OpenPhoneIsHeldByItsPrint()
    {
        foreach (var item in Vectors().GetProperty("hold").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString();
            var open = GamePhoneFirstSightingTests.Load(item.GetProperty("frame").GetString()!, "none");
            var then = GamePhoneFirstSightingTests.Load(item.GetProperty("then").GetString()!, item.GetProperty("transform").GetString()!);
            var log = new List<string>();
            var tracker = new GamePhoneTracker { Log = log.Add };
            long t = 0;
            for (var i = 0; i < 3; i++, t += 330) tracker.TrySample(open, t, out _);
            tracker.TrySample(open, t, out var shown);
            Assert.True(shown is not null, name);
            t += 330;
            var samples = item.GetProperty("samples").GetInt32();
            CropRegion? last = null;
            var kept = 0;
            for (var i = 0; i < samples; i++, t += 330)
            {
                tracker.TrySample(then, t, out last);
                if (last is not null) kept++;
            }
            if (item.GetProperty("held").GetBoolean()) Assert.True(kept == samples, $"{name}: {kept}/{samples} {string.Join(" | ", log)}");
            else Assert.True(last is null, $"{name}: {string.Join(" | ", log)}");
            if (item.TryGetProperty("log", out var parts))
                foreach (var part in parts.EnumerateArray())
                    Assert.True(log.Any(line => line.Contains(part.GetString()!)), $"{name}: {part.GetString()} yok: {string.Join(" | ", log)}");
        }
    }

    /// <summary>
    /// İz telefonsuz karede telefonu tutmaz: telefon açıldıktan sonra telefonsuz gerçek kareler (karanlık hâlleriyle) gelince
    /// telefon kapanır.
    /// </summary>
    [Fact]
    public void PrintNeverHoldsPhoneFreeFrames()
    {
        var spec = Vectors().GetProperty("holdNoPhone");
        var transforms = spec.GetProperty("transforms").EnumerateArray().Select(item => item.GetString()!).ToList();
        var openers = spec.GetProperty("openers").EnumerateArray().Select(item => GamePhoneFirstSightingTests.Load(item.GetString()!, "none")).ToList();
        var samples = spec.GetProperty("samples").GetInt32();
        using var manifest = JsonDocument.Parse(File.ReadAllText(GamePhoneFirstSightingTests.FramePath("frames.json")));
        var names = manifest.RootElement.GetProperty("frames").EnumerateArray()
            .Where(frame => !frame.TryGetProperty("phone", out _))
            .Select(frame => Path.GetFileNameWithoutExtension(frame.GetProperty("file").GetString()!)).Distinct().ToList();
        foreach (var name in names)
        {
            var source = Jpeg.Load(GamePhoneFirstSightingTests.FramePath(name + ".jpg"));
            foreach (var transform in transforms)
            {
                var frame = GamePhoneFirstSightingTests.Transform(source, transform);
                for (var o = 0; o < openers.Count; o++)
                {
                    var tracker = new GamePhoneTracker();
                    long t = 0;
                    for (var i = 0; i < 3; i++, t += 330) tracker.TrySample(openers[o], t, out _);
                    CropRegion? last = null;
                    for (var i = 0; i < samples; i++, t += 330) tracker.TrySample(frame, t, out last);
                    Assert.True(last is null, $"{name} ({transform}) telefon {o} açık kaldı");
                }
            }
        }
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
