// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

public class GamePhoneTrackerTests
{
    [Fact]
    public void NeedsTwoAlignedSamplesAndClosesAfterMissGraceMs()
    {
        var frame = Frame.Blank(2, 2);
        CropRegion? candidate = new(0.15, 0.83, 0.32, 0.58);
        int calls = 0;
        var tracker = new GamePhoneTracker(_ => { calls++; return candidate; });
        Assert.True(tracker.TrySample(frame, 100, out var initial));
        Assert.Null(initial);
        Assert.False(tracker.TrySample(frame, 260, out _));
        Assert.Equal(1, calls);
        Assert.True(tracker.TrySample(frame, 430, out var opened));
        Assert.Equal(candidate, opened);
        // Açık telefon tek karede bulunamayınca kapanmaz (çeviriler gidip gelmesin); yakınında yeniden bulununca sürer,
        // en az MinimumMisses ıska ve MissGraceMs sonra kapanır. Yeniden açılış yine iki gözlem ister (Mac ve Android ile aynı).
        var open = candidate;
        candidate = null;
        Assert.True(tracker.TrySample(frame, 760, out var kept));
        Assert.Equal(open, kept);
        candidate = new(0.14, 0.82, 0.31, 0.57);
        Assert.True(tracker.TrySample(frame, 1090, out var followed));
        Assert.Equal(candidate, followed);
        candidate = null;
        for (var i = 0; i < 2; i++)
        {
            Assert.True(tracker.TrySample(frame, 1420 + 330 * i, out var still));
            Assert.NotNull(still);
        }
        Assert.True(tracker.TrySample(frame, 1420 + 330 * 2, out var closed));
        Assert.Null(closed);
        candidate = new(0.14, 0.8, 0.31, 0.56);
        Assert.True(tracker.TrySample(frame, 3000, out var reopening));
        Assert.Null(reopening);
        tracker.Reset();
        Assert.True(tracker.TrySample(frame, 3001, out var reset));
        Assert.Null(reset);
    }

    /// <summary>#1334: telefon indirilince çevirisi süreyle (~1 sn) kalkar; örnekler seyrek gelse de ıska sayısı beklenmez.</summary>
    [Fact]
    public void ClosedPhoneLeavesWithinASecondEvenWhenSamplesAreSparse()
    {
        var frame = Frame.Blank(2, 2);
        CropRegion? candidate = new(0.15, 0.83, 0.32, 0.58);
        var open = candidate;

        // Seyrek örnekler (1 sn arayla): tek ıska kapatmaz, ikinci ıskada kapanır (önceden dördüncüde, ~4 sn).
        var tracker = new GamePhoneTracker(_ => candidate);
        tracker.TrySample(frame, 0, out _);
        Assert.True(tracker.TrySample(frame, 1000, out var opened));
        Assert.NotNull(opened);
        candidate = null;
        tracker.TrySample(frame, 2000, out var kept);
        Assert.NotNull(kept);
        candidate = open;
        tracker.TrySample(frame, 3000, out var back);
        Assert.NotNull(back);
        candidate = null;
        tracker.TrySample(frame, 4000, out var once);
        Assert.NotNull(once);
        tracker.TrySample(frame, 5000, out var closed);
        Assert.Null(closed);

        // Akış takıldı, telefon iki kat süre hiç görülmedi: tek ıska yeter.
        candidate = open;
        tracker = new GamePhoneTracker(_ => candidate);
        tracker.TrySample(frame, 0, out _);
        tracker.TrySample(frame, 330, out var seen);
        Assert.NotNull(seen);
        candidate = null;
        tracker.TrySample(frame, 330 + 2 * GamePhoneTracker.MissGraceMs, out var gone);
        Assert.Null(gone);

        Assert.False(GamePhoneTracker.Closes(1, 1200));
        Assert.True(GamePhoneTracker.Closes(4, 0));
    }

    [Fact]
    public void DoesNotJoinUnrelatedOpenings()
    {
        var frame = Frame.Blank(2, 2);
        var area = new CropRegion(0.14, 0.8, 0.30, 0.52);
        var tracker = new GamePhoneTracker(_ => area);
        tracker.TrySample(frame, 1, out _);
        area = area with { Left = 0.42, Right = 0.64 };
        tracker.TrySample(frame, 401, out var moved);
        Assert.Null(moved);
        tracker.TrySample(frame, 801, out var stable);
        Assert.Equal(area, stable);
    }

    [Fact]
    public void EmptyPictureAndSubtitleStripeDoNotOpenPhone()
    {
        var frame = Frame.Blank(640, 360);
        Array.Fill(frame.Pixels, (byte)210, 280 * frame.Stride, 14 * frame.Stride);
        var tracker = new GamePhoneTracker();
        tracker.TrySample(frame, 0, out _);
        tracker.TrySample(frame, 500, out var result);
        Assert.Null(result);
    }

    [Theory]
    [InlineData(110, 25)]
    [InlineData(55, 23)]
    public void UsesTheLowerBezelInsteadOfAHighContrastTextStroke(byte casing, byte slot)
    {
        var frame = PhoneFrame(casing, slot);
        Assert.True(GamePhoneGeometry.TryLocate(frame, out var pose));
        Assert.InRange(pose.TopY * frame.Height, 32, 35);
        Assert.InRange(pose.BottomY * frame.Height, 188, 191);
        for (int y = 32; y < 37; y++)
            Array.Fill(frame.Pixels, casing, y * frame.Stride + 211 * 4, 5 * 4);
        Assert.False(GamePhoneGeometry.TryLocate(frame, out _));
    }

    /// <summary>
    /// PS Remote Play / chiaki-ng / OBS penceresinden okunan kare 16:9 değildir (başlık çubuğu, siyah şeritler). Telefon
    /// önceden yalnız tam 16:9 karede aranıyordu; pencerede hiç bulunmuyordu. Şimdi oyun görüntüsü karenin içinde bulunur,
    /// telefonun yeri karenin tamamına göre verilir (Mac ve Android'de aynı deneme).
    /// </summary>
    [Theory]
    [InlineData(400, 256, 31, 0, 31)]   // başlık çubuğu + tam oturan görüntü
    [InlineData(400, 300, 31, 0, 56)]   // başlık çubuğu + üstte ve altta siyah şerit
    [InlineData(470, 256, 31, 35, 31)]  // başlık çubuğu + yanlarda siyah şerit
    public void FindsThePhoneInsideARemotePlayWindow(int width, int height, int title, int left, int top)
    {
        Assert.True(GamePhoneGeometry.TryLocate(PhoneFrame(), out var direct));
        var frame = WindowFrame(width, height, title, left, top);
        int Tone(int x, int y)
        {
            var p = y * frame.Stride + x * 4;
            return (frame.Pixels[p] * 29 + frame.Pixels[p + 1] * 150 + frame.Pixels[p + 2] * 77) >> 8;
        }
        Assert.Equal((left, top, 400, 225), GamePhoneGeometry.Picture(width, height, Tone));
        Assert.True(GamePhoneGeometry.TryLocate(frame, out var pose));
        Assert.Equal(left + direct.TopX * 400, pose.TopX * width, 0.5);
        Assert.Equal(top + direct.TopY * 225, pose.TopY * height, 0.5);
        Assert.Equal(top + direct.BottomY * 225, pose.BottomY * height, 0.5);
        Assert.NotNull(ScreenPhoneCard.Phone(frame));
        // Telefonsuz görüntü pencerede de telefon sayılmaz.
        var empty = WindowFrame(width, height, title, left, top, phone: false);
        Assert.False(GamePhoneGeometry.TryLocate(empty, out _));
    }

    /// <summary>Pencere karesi: üstte açık renk başlık çubuğu (üstünde koyu yazı), 400×225 görüntü, kalan yer simsiyah.</summary>
    internal static Frame WindowFrame(int width, int height, int title, int left, int top, bool phone = true)
    {
        var frame = Frame.Blank(width, height);
        for (int y = 0; y < title; y++)
            for (int x = 0; x < width; x++)
            {
                var ink = x is >= 8 and < 120 && y >= title / 3 && y < title * 2 / 3 && x % 4 < 2 ? (byte)30 : (byte)220;
                Array.Fill(frame.Pixels, ink, y * frame.Stride + x * 4, 4);
            }
        var picture = PhoneFrame();
        if (!phone) Array.Fill(picture.Pixels, (byte)85);
        for (int y = 0; y < 225; y++)
            Buffer.BlockCopy(picture.Pixels, y * picture.Stride, frame.Pixels, (top + y) * frame.Stride + left * 4, 400 * 4);
        return frame;
    }

    internal static Frame PhoneFrame(byte casing = 110, byte slot = 25)
    {
        var frame = Frame.Blank(400, 225);
        Fill(0, 0, 400, 225, 85);
        Fill(160, 22, 84, 179, casing);
        Fill(164, 40, 76, 141, 195);
        Fill(196, 33, 13, 2, slot);  // kulaklık
        Fill(212, 33, 3, 3, slot);   // ön kamera
        Fill(198, 189, 9, 2, slot);   // alt yarık
        Fill(198, 170, 9, 2, 24);     // yazının parçası

        return frame;

        void Fill(int left, int top, int width, int height, byte gray)
        {
            for (int y = top; y < top + height; y++)
                Array.Fill(frame.Pixels, gray, y * frame.Stride + left * 4, width * 4);
        }
    }
}
