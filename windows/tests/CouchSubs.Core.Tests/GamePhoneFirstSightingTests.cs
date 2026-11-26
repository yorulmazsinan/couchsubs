// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.CompilerServices;
using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// GTA 6 telefonunun ilk açılışı (#1251, beta-102): telefon çoğu zaman hiç tanınmıyor, mesajları altyazı gibi çevriliyordu.
/// Ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/phone-first-sighting.json (Mac/iPhone
/// GamePhoneFirstSightingTests.swift, Android GamePhoneFirstSightingTest.kt aynı durumları koşar); gerçek kareler
/// testdata/frames.
/// </summary>
public class GamePhoneFirstSightingTests
{
    private static JsonElement Vectors() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("phone-first-sighting.json"))).RootElement;

    private static string FramePath(string name, [CallerFilePath] string source = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..", "testdata", "frames", name));

    private static readonly Dictionary<string, Frame> Loaded = [];

    /// <summary>
    /// Gerçek kare, ortak dosyadaki dönüşümüyle (none, shiftUp, lowContrast, dark); <paramref name="cover"/> [sol, üst, sağ,
    /// alt] (0..1) verilirse o dikdörtgen el rengiyle örtülür (parmak telefonun kenarında).
    /// </summary>
    internal static Frame Load(string name, string transform, double[]? cover = null)
    {
        var key = name + "|" + transform + "|" + (cover is null ? "" : string.Join(',', cover));
        lock (Loaded)
        {
            if (Loaded.TryGetValue(key, out var cached)) return cached;
            var frame = Transform(Jpeg.Load(FramePath(name + ".jpg")), transform);
            if (cover is not null) frame = Cover(frame, cover);
            Loaded[key] = frame;
            return frame;
        }
    }

    /// <summary>Ortak dosyanın el rengi (R, G, B).</summary>
    private static readonly byte[] Hand = [196, 140, 110];

    internal static Frame Cover(Frame source, double[] cover)
    {
        var frame = Frame.Blank(source.Width, source.Height);
        Buffer.BlockCopy(source.Pixels, 0, frame.Pixels, 0, source.Pixels.Length);
        int left = (int)(cover[0] * source.Width), top = (int)(cover[1] * source.Height);
        int right = (int)(cover[2] * source.Width), bottom = (int)(cover[3] * source.Height);
        for (var y = top; y < bottom; y++)
            for (var x = left; x < right; x++)
            {
                var p = y * frame.Stride + x * 4;
                (frame.Pixels[p], frame.Pixels[p + 1], frame.Pixels[p + 2], frame.Pixels[p + 3]) = (Hand[2], Hand[1], Hand[0], 255);
            }
        return frame;
    }

    private static double[]? CoverOf(JsonElement sample) =>
        sample.TryGetProperty("cover", out var cover) ? cover.EnumerateArray().Select(item => item.GetDouble()).ToArray() : null;

    internal static Frame Transform(Frame source, string transform)
    {
        if (transform == "none") return source;
        var frame = Frame.Blank(source.Width, source.Height);
        if (transform == "shiftUp")
        {
            var shift = source.Height / 12;
            for (var y = 0; y < source.Height; y++)
                Buffer.BlockCopy(source.Pixels, Math.Min(source.Height - 1, y + shift) * source.Stride, frame.Pixels, y * frame.Stride, source.Stride);
            return frame;
        }
        Func<int, int> tone = transform switch
        {
            "lowContrast" => value => 128 + (value - 128) * 6 / 10,
            "dark" => value => value * 6 / 10,
            _ => throw new ArgumentException(transform),
        };
        for (var i = 0; i < source.Pixels.Length; i++)
            frame.Pixels[i] = i % 4 == 3 ? (byte)255 : (byte)Math.Clamp(tone(source.Pixels[i]), 0, 255);
        return frame;
    }

    private static GamePhoneGeometry.Pose Pose(JsonElement values)
    {
        var v = values.EnumerateArray().Select(item => item.GetDouble()).ToArray();
        return new GamePhoneGeometry.Pose(v[0], v[1], v[2], v[3]);
    }

    [Fact]
    public void SequencesOpenTheSameWayOnEveryPlatform()
    {
        var all = Vectors();
        var fallback = Pose(all.GetProperty("defaultPose"));
        foreach (var sequence in all.GetProperty("sequences").EnumerateArray())
        {
            var name = sequence.GetProperty("name").GetString();
            (CropRegion, bool)? next = null;
            var tracker = new GamePhoneTracker(_ => next);
            int? opened = null;
            var index = 0;
            foreach (var sample in sequence.GetProperty("samples").EnumerateArray())
            {
                var pose = sample.TryGetProperty("pose", out var given) ? Pose(given) : fallback;
                next = sample.GetProperty("kind").GetString() switch
                {
                    "strict" => (pose.Bounds, true),
                    "weak" => (pose.Bounds, false),
                    _ => null,
                };
                Assert.True(tracker.TrySample(Frame.Blank(2, 2), sample.GetProperty("t").GetInt64(), out var visible), name);
                if (visible is not null && opened is null) opened = index;
                index++;
            }
            int? expected = sequence.GetProperty("opensAt").ValueKind == JsonValueKind.Null ? null : sequence.GetProperty("opensAt").GetInt32();
            Assert.True(expected == opened, $"{name}: {opened?.ToString() ?? "açılmadı"}");
        }
    }

    [Fact]
    public void RealFramesFromTheLogOpenThePhone()
    {
        foreach (var sequence in Vectors().GetProperty("frames").EnumerateArray())
        {
            var name = sequence.GetProperty("name").GetString();
            var tracker = new GamePhoneTracker();
            int? opened = null;
            var index = 0;
            foreach (var sample in sequence.GetProperty("samples").EnumerateArray())
            {
                var frame = Load(sample.GetProperty("frame").GetString()!, sample.GetProperty("transform").GetString()!, CoverOf(sample));
                tracker.TrySample(frame, sample.GetProperty("t").GetInt64(), out var visible);
                if (visible is not null && opened is null) opened = index;
                index++;
            }
            int? expected = sequence.GetProperty("opensAt").ValueKind == JsonValueKind.Null ? null : sequence.GetProperty("opensAt").GetInt32();
            Assert.True(expected == opened, $"{name}: {opened?.ToString() ?? "açılmadı"}");
        }
    }

    /// <summary>Telefonsuz gerçek kareler (frames.json'da telefon işareti olmayanlar) hiçbir dönüşümde telefon açmaz, aday da olmaz.</summary>
    [Fact]
    public void FramesWithoutPhoneNeverOpenOrHoldIt()
    {
        var noPhone = Vectors().GetProperty("noPhone");
        var transforms = noPhone.GetProperty("transforms").EnumerateArray().Select(item => item.GetString()!).ToList();
        var samples = noPhone.GetProperty("samples").GetInt32();
        using var manifest = JsonDocument.Parse(File.ReadAllText(FramePath("frames.json")));
        var names = manifest.RootElement.GetProperty("frames").EnumerateArray()
            .Where(frame => !frame.TryGetProperty("phone", out _))
            .Select(frame => Path.GetFileNameWithoutExtension(frame.GetProperty("file").GetString()!)).Distinct().ToList();
        Assert.True(names.Count > 50);
        foreach (var name in names)
        {
            var source = Jpeg.Load(FramePath(name + ".jpg"));
            foreach (var transform in transforms)
            {
                var frame = Transform(source, transform);
                var tracker = new GamePhoneTracker();
                for (var i = 0; i < samples; i++)
                {
                    tracker.TrySample(frame, i * 330L, out var visible);
                    Assert.True(visible is null, $"{name} ({transform}): telefon açıldı");
                }
                Assert.Null(ScreenPhoneCard.Phone(frame, null, out var candidate));
                Assert.True(candidate is null, $"{name} ({transform}): telefon adayı");
            }
        }
    }

    [Fact]
    public void SubtitleFilterHoldsTheCandidateAndConfirmsItInPlace()
    {
        foreach (var item in Vectors().GetProperty("candidates").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString();
            var frame = Load(item.GetProperty("frame").GetString()!, item.GetProperty("transform").GetString()!);
            Assert.Null(ScreenPhoneCard.Phone(frame, null, out var candidate));
            Assert.True(candidate is not null, $"{name}: aday yok");
            Assert.True(ScreenPhoneCard.Phone(frame, candidate) is not null, $"{name}: adayın yerinde telefon doğrulanmadı");
        }
    }

    [Fact]
    public void MissedFirstSightingIsLoggedOncePerWindow()
    {
        var spec = Vectors().GetProperty("missLog");
        var frame = Load(spec.GetProperty("frame").GetString()!, spec.GetProperty("transform").GetString()!);
        var interval = spec.GetProperty("intervalMs").GetInt64();
        var duration = spec.GetProperty("durationMs").GetInt64();
        var log = new List<string>();
        var tracker = new GamePhoneTracker { Log = log.Add };
        for (long t = 0; t <= duration; t += interval) tracker.TrySample(frame, t, out _);
        var missed = log.Where(line => line.Contains("telefon ilk aramada bulunamadı")).ToList();
        Assert.Single(missed);
        foreach (var part in spec.GetProperty("contains").EnumerateArray()) Assert.Contains(part.GetString()!, missed[0]);

        // Telefonsuz oyunda (aramalar hoparlör yarığında kalır) satır yazılmaz.
        log.Clear();
        var empty = Load("gta6-01-lucia", "none");
        tracker = new GamePhoneTracker { Log = log.Add };
        for (long t = 0; t <= duration; t += interval) tracker.TrySample(empty, t, out _);
        Assert.Empty(log);
    }

    [Fact]
    public void MissedFirstLineNamesTheCriterion()
    {
        Assert.Equal("telefon ilk aramada bulunamadı (61 arama): en ileri ölçüt yan kenarlar zayıf, en sık yan kenarlar zayıf (61), "
                     + "en iyi aday yan gücü 3/12, doğrulanmayan gözlem 1 (1 sıkı)",
            PhoneTrace.MissedFirst(61, PhoneTrace.Reason(GamePhoneGeometry.Step.Sides), PhoneTrace.Reason(GamePhoneGeometry.Step.Sides), 61, 3, 1, 1));
        Assert.Equal("telefon ilk aramada bulunamadı (5 arama): en ileri ölçüt ön kamera yok, en sık hoparlör yarığı yok (4), "
                     + "doğrulanmayan gözlem 0 (0 sıkı)",
            PhoneTrace.MissedFirst(5, PhoneTrace.Reason(GamePhoneGeometry.Step.NoCamera), PhoneTrace.Reason(GamePhoneGeometry.Step.NoTopSlot), 4, -1, 0, 0));
    }

    /// <summary>Altyazı hattının adayı: ilk görüldüğü an yakınında korunur, satırlar CandidateHoldMs boyunca bekletilir.</summary>
    [Fact]
    public void CandidateHoldIsShortAndDoesNotExtendItself()
    {
        var frame = Load("gta6-telefon-sohbet-2", "shiftUp");
        Assert.Null(ScreenPhoneCard.Phone(frame, null, out var weak));
        Assert.NotNull(weak);
        var (first, since) = SubtitlePipeline.Candidate(weak, null, 0, 1000);
        Assert.Same(weak, first);
        Assert.Equal(1000, since);
        (_, since) = SubtitlePipeline.Candidate(weak, first, since, 1330);
        Assert.Equal(1000, since);
        Assert.True(SubtitlePipeline.HoldsCandidate(first, since, 1000 + SubtitlePipeline.CandidateHoldMs - 1));
        Assert.False(SubtitlePipeline.HoldsCandidate(first, since, 1000 + SubtitlePipeline.CandidateHoldMs));
        Assert.Equal((null, 0), SubtitlePipeline.Candidate(null, first, since, 1660));
        Assert.False(SubtitlePipeline.HoldsCandidate(null, 0, 10));
    }
}
