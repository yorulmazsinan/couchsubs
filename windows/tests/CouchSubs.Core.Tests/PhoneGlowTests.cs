// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// #1443 (beta-108): GTA 6 telefonu karanlık sahnede ~1 sn'de bir kapanıp açılıyor, her kapanışta kutuları siliniyor, görev
/// satırı yolu telefonun mesajlarını okuyordu. Telefon karanlıkta ekranının ışığıyla tutulur (<see cref="PhoneGlow"/>),
/// gerçekten indirilince her zamanki sürede kapanır; telefon açıkken başka yolların telefonun alanındaki satırları
/// bastırılır (<see cref="PhoneShield"/>). Ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/phone-glow.json
/// (Mac/iPhone PhoneGlowTests.swift, Android PhoneGlowTest.kt aynı durumları koşar).
/// </summary>
public class PhoneGlowTests
{
    private static JsonElement Vectors() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("phone-glow.json"))).RootElement;

    private static double[] Doubles(JsonElement value) => [.. value.EnumerateArray().Select(item => item.GetDouble())];
    private static PhoneGlow.Glow Glow(JsonElement value)
    {
        var v = Doubles(value);
        return new PhoneGlow.Glow(v[0], v[1]);
    }
    private static CropRegion Region(double[] v) => new(v[1], v[3], v[0], v[2]);
    private static TextBox Box(double[] v) => new(v[0], v[1], v[2], v[3]);

    [Fact]
    public void GlowHoldsOnlyALitScreenInTheDark()
    {
        foreach (var item in Vectors().GetProperty("holds").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString();
            var recorded = Glow(item.GetProperty("recorded"));
            var current = Glow(item.GetProperty("current"));
            Assert.True(PhoneGlow.Lit(current) == item.GetProperty("lit").GetBoolean(), name);
            Assert.True(PhoneGlow.Holds(recorded, current) == item.GetProperty("holds").GetBoolean(), name);
        }
    }

    /// <summary>Sentetik kare: her yer <paramref name="background"/>, ekran kutusu <paramref name="screen"/> tonunda (null: ekran yok).</summary>
    private static Frame Scene(int width, int height, int background, int? screen, double[] box)
    {
        var frame = Frame.Blank(width, height);
        int left = (int)Math.Round(box[0] * width), top = (int)Math.Round(box[1] * height);
        int right = (int)Math.Round(box[2] * width), bottom = (int)Math.Round(box[3] * height);
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var tone = (byte)(screen is { } lit && x >= left && x < right && y >= top && y < bottom ? lit : background);
                var p = y * frame.Stride + x * 4;
                (frame.Pixels[p], frame.Pixels[p + 1], frame.Pixels[p + 2], frame.Pixels[p + 3]) = (tone, tone, tone, 255);
            }
        return frame;
    }

    [Fact]
    public void DarkPhoneIsHeldByItsScreenAndClosesWhenLowered()
    {
        var vectors = Vectors();
        var scene = vectors.GetProperty("scene");
        int width = scene.GetProperty("width").GetInt32(), height = scene.GetProperty("height").GetInt32();
        var p = Doubles(scene.GetProperty("pose"));
        var screenBox = Doubles(scene.GetProperty("screenBox"));
        var pose = new GamePhoneGeometry.Pose(p[0], p[1], p[2], p[3]);
        foreach (var sequence in vectors.GetProperty("sequences").EnumerateArray())
        {
            var name = sequence.GetProperty("name").GetString();
            int background = sequence.GetProperty("background").GetInt32(), screen = sequence.GetProperty("screen").GetInt32();
            var opener = Scene(width, height, background, screen, screenBox);
            var tracker = new GamePhoneTracker(frame => ReferenceEquals(frame, opener) ? (pose, true) : null, glows: true);
            var log = new List<string>();
            tracker.Log = log.Add;
            long t = 0;
            CropRegion? visible = null;
            for (var i = 0; i < sequence.GetProperty("open").GetInt32(); i++, t += GamePhoneTracker.IntervalMs)
                tracker.TrySample(opener, t, out visible);
            Assert.True(visible is not null, $"{name}: telefon açılmadı");
            foreach (var part in sequence.GetProperty("then").EnumerateArray())
            {
                var lit = part.GetProperty("frame").GetString() == "lit";
                var image = Scene(width, height,
                    part.TryGetProperty("background", out var b) ? b.GetInt32() : background,
                    lit ? part.TryGetProperty("screen", out var s) ? s.GetInt32() : screen : null, screenBox);
                var openAll = part.TryGetProperty("openAll", out var all) && all.GetBoolean();
                for (var i = 0; i < part.GetProperty("samples").GetInt32(); i++, t += GamePhoneTracker.IntervalMs)
                {
                    tracker.TrySample(image, t, out visible);
                    if (openAll) Assert.True(visible is not null, $"{name}: {i + 1}. örnekte kapandı");
                }
                if (part.TryGetProperty("openAtEnd", out var end)) Assert.True((visible is not null) == end.GetBoolean(), $"{name}: parçanın sonunda");
            }
            var text = string.Join('\n', log);
            if (sequence.TryGetProperty("log", out var needles))
                foreach (var needle in needles.EnumerateArray())
                    Assert.True(text.Contains(needle.GetString()!), $"{name}: günlükte yok: {needle.GetString()}\n{text}");
            if (sequence.TryGetProperty("noLog", out var absent))
                foreach (var needle in absent.EnumerateArray())
                    Assert.False(text.Contains(needle.GetString()!), $"{name}: günlükte var: {needle.GetString()}");
        }
    }

    /// <summary>
    /// Gerçek karanlık oda karesinde telefonun ekranı ışıklı sayılır; telefonsuz gerçek karelerin aynı yerinde ışık o kaydı
    /// tutmaz (telefon indirilince ışıkla açık kalmaz).
    /// </summary>
    [Fact]
    public void RealDarkRoomScreenIsLitAndNoPhoneFrameHoldsIt()
    {
        var spec = Vectors().GetProperty("realFrame");
        var phone = GamePhoneFirstSightingTests.Load(spec.GetProperty("frame").GetString()!, spec.GetProperty("transform").GetString()!);
        Assert.True(GamePhoneGeometry.TryLocate(phone, out var pose));
        var recorded = GamePhoneGeometry.Glow(phone, pose);
        Assert.True(recorded is { } r && PhoneGlow.Lit(r), $"{recorded}");
        using var manifest = JsonDocument.Parse(File.ReadAllText(GamePhoneFirstSightingTests.FramePath("frames.json")));
        var names = manifest.RootElement.GetProperty("frames").EnumerateArray()
            .Where(frame => !frame.TryGetProperty("phone", out _))
            .Select(frame => Path.GetFileNameWithoutExtension(frame.GetProperty("file").GetString()!)).Distinct().ToList();
        foreach (var name in names)
        {
            var source = Jpeg.Load(GamePhoneFirstSightingTests.FramePath(name + ".jpg"));
            foreach (var transform in spec.GetProperty("transforms").EnumerateArray().Select(item => item.GetString()!))
            {
                var frame = GamePhoneFirstSightingTests.Transform(source, transform);
                var current = GamePhoneGeometry.Glow(frame, pose);
                Assert.True(current is not null, name);
                Assert.False(PhoneGlow.Holds(recorded!.Value, current!.Value), $"{name} ({transform}): {current}");
            }
        }
    }

    [Fact]
    public void ShieldDropsOtherRoutesLinesOnThePhone()
    {
        var vectors = Vectors();
        foreach (var item in vectors.GetProperty("shield").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString();
            var lines = item.GetProperty("lines").EnumerateArray().Select(line => new TextLine(line.GetProperty("text").GetString()!,
                line.GetProperty("box").ValueKind == JsonValueKind.Null ? null : Box(Doubles(line.GetProperty("box"))))).ToList();
            var phone = item.GetProperty("phone").ValueKind == JsonValueKind.Null ? null : Region(Doubles(item.GetProperty("phone")));
            var result = PhoneShield.Filter(new Reading(lines), Region(Doubles(item.GetProperty("region"))), phone);
            var kept = item.GetProperty("kept").EnumerateArray().Select(text => text.GetString()!).ToList();
            Assert.True(kept.SequenceEqual(result.Kept.Lines.Select(line => line.Text)), name);
            Assert.True(result.Dropped == lines.Count - kept.Count, name);
        }
        foreach (var item in vectors.GetProperty("covers").EnumerateArray())
            Assert.Equal(item.GetProperty("covers").GetBoolean(),
                         PhoneShield.Covers(Box(Doubles(item.GetProperty("box"))), Region(Doubles(item.GetProperty("phone")))));
    }
}
