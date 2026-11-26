// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// #1369 (beta-104, Mac): gevşek doğrulamada açık telefonun son yeri hoparlör ya da çentik şeridinin dışında kalınca satır
/// aralığı ters kuruluyor, Mac/iPhone'da uygulama çöküyordu. Son yer kenarda, dışında, eksi, karenin altını aşan ya da sayı
/// olmayan bir yer olsa da arama telefon bulmaz, hata atmaz. Ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/phone-near-edges.json (Mac/iPhone GamePhoneEdgeTests.swift, Android
/// GamePhoneEdgeTest.kt aynı durumları koşar).
/// </summary>
public class GamePhoneEdgeTests
{
    private static JsonElement Vectors() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("phone-near-edges.json"))).RootElement;

    private static List<GamePhoneGeometry.Pose> Poses()
    {
        var poses = Vectors().GetProperty("near").EnumerateArray()
            .Select(p => p.EnumerateArray().Select(v => v.GetDouble()).ToArray())
            .Select(v => new GamePhoneGeometry.Pose(v[0], v[1], v[2], v[3])).ToList();
        // JSON'da olmayan sayılar.
        foreach (var bad in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity, double.MaxValue, double.MinValue })
        {
            poses.Add(new(0.5, bad, 0.5, 0.8));
            poses.Add(new(0.5, 0.2, 0.5, bad));
            poses.Add(new(bad, 0.2, 0.5, 0.8));
            poses.Add(new(0.5, 0.2, bad, 0.8));
            poses.Add(new(bad, bad, bad, bad));
        }
        // Sabit tohumlu rastgele yerler.
        ulong seed = 1369;
        double Next()
        {
            seed = unchecked(seed * 6364136223846793005UL + 1442695040888963407UL);
            return (seed >> 11) / (double)(1UL << 53);
        }
        for (var i = 0; i < 150; i++) poses.Add(new(Next() * 3 - 1, Next() * 3 - 1, Next() * 3 - 1, Next() * 3 - 1));
        return poses;
    }

    private static Frame Image(int width, int height, Func<int, int, byte> tone)
    {
        var frame = Frame.Blank(width, height);
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var t = tone(x, y);
                var p = y * frame.Stride + x * 4;
                (frame.Pixels[p], frame.Pixels[p + 1], frame.Pixels[p + 2], frame.Pixels[p + 3]) = (t, t, t, 255);
            }
        return frame;
    }

    [Fact]
    public void ConfirmRowsStayInsideTheBand()
    {
        foreach (var item in Vectors().GetProperty("rows").EnumerateArray())
        {
            var center = item.GetProperty("center").GetDouble();
            int low = item.GetProperty("low").GetInt32(), high = item.GetProperty("high").GetInt32();
            var rows = GamePhoneGeometry.ConfirmRows(center, low, high);
            var expected = item.GetProperty("rows");
            if (expected.ValueKind == JsonValueKind.Null) Assert.True(rows is null, $"{center} in [{low}, {high})");
            else Assert.Equal((expected[0].GetInt32(), expected[1].GetInt32()), rows);
        }
        foreach (var bad in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity })
            Assert.Null(GamePhoneGeometry.ConfirmRows(bad, 17, 75));
    }

    /// <summary>Telefonsuz karede (düz, karanlık: kazançlı geçişler de koşar; 16:9 olmayan pencere) hiçbir son yer telefon bulmaz.</summary>
    [Fact]
    public void ConfirmNearEveryEdgeNeverThrows()
    {
        var frames = new[]
        {
            Image(800, 450, (_, _) => 128),
            Image(800, 450, (_, _) => 10),
            Image(800, 450, (x, y) => (byte)((x * 7 + y * 13) % 256)),
            Image(800, 560, (_, y) => (byte)(y < 80 ? 200 : 90)),
        };
        var near = Poses();
        for (var i = 0; i < frames.Length; i++)
            foreach (var pose in near)
            {
                var found = GamePhoneGeometry.TryLocate(frames[i], pose, out _, out _);
                // Desenli karede yalnız hata atmaması aranır.
                if (i != 2) Assert.False(found, $"kare {i}: {pose}");
            }
    }

    /// <summary>Gerçek telefon karesinde kenardaki ve dışarıdaki son yerler hata atmaz; telefon yine bulunur.</summary>
    [Fact]
    public void ConfirmNearEveryEdgeOnRealPhone()
    {
        var near = Poses();
        foreach (var item in Vectors().GetProperty("frames").EnumerateArray())
        {
            var frame = GamePhoneFirstSightingTests.Load(item.GetProperty("frame").GetString()!, item.GetProperty("transform").GetString()!);
            foreach (var pose in near) Assert.True(GamePhoneGeometry.TryLocate(frame, pose, out _, out _));
            var tracker = new GamePhoneTracker();
            tracker.TrySample(frame, 0, out _);
            tracker.TrySample(frame, 330, out _);
        }
    }
}
