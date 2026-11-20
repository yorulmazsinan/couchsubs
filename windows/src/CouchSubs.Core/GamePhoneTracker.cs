// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>GTA 6'da elde açık telefon. Algılama yazı tanıma çalıştırmaz; iki uyumlu gözlemle açılır.</summary>
public sealed class GamePhoneTracker
{
    internal const int IntervalMs = 330;
    private readonly Func<Frame, CropRegion?>? locateOverride;
    private GamePhoneGeometry.Pose? shownPose;
    private long? lastTime;
    private CropRegion? previous, shown;

    public GamePhoneTracker() { }
    internal GamePhoneTracker(Func<Frame, CropRegion?> locate) => locateOverride = locate;

    public bool TrySample(Frame frame, long now, out CropRegion? visible)
    {
        if (lastTime is { } last && now >= last && now - last < IntervalMs)
        {
            visible = shown;
            return false;
        }
        lastTime = now;
        GamePhoneGeometry.Pose? pose = null;
        CropRegion? candidate;
        if (locateOverride is not null) candidate = locateOverride(frame);
        else
        {
            pose = GamePhoneGeometry.TryLocate(frame, out var found) ? found : null;
            candidate = pose?.Bounds;
        }
        // Akıl sınırı: telefon ekranın küçük, dikey bir parçasıdır. Dışındaki bir aday (ör. menüde ya da koyu ekranda
        // yanlış eşleşme) kabul edilmez; TV'de büyük opak telefon kutusu oyun görüntüsünü kapatırdı.
        if (candidate is not null && !Plausible(candidate, frame)) candidate = null;
        shown = candidate is not null && previous is not null && candidate.IsClose(previous, 0.035)
            ? candidate : null;
        shownPose = shown is null ? null : pose;
        previous = candidate;
        visible = shown;
        return true;
    }

    public WatchedArea WithPose(WatchedArea area) => area with { PhonePose = shownPose };

    /// <summary>Telefon kutusunun alanı (kareye oranla) bu aralıkta olmalı.</summary>
    internal const double MinArea = 0.04, MaxArea = 0.35;

    /// <summary>
    /// Telefon kutusu akla yatkın mı: alanı karenin %4–%35'i, piksel olarak dikey (yükseklik/genişlik 0,9–2,6; eğik
    /// telefonun sınır kutusu dikey telefondan geniştir), yüksekliği karenin en çok %85'i, genişliği en çok yarısı, merkezi karenin sol kenarında ya da üst üçte birinde değil.
    /// </summary>
    internal static bool Plausible(CropRegion region, Frame frame)
    {
        double width = region.Right - region.Left, height = region.Bottom - region.Top;
        if (width <= 0 || height <= 0 || height > 0.85 || width > 0.5) return false;
        double area = width * height;
        if (area < MinArea || area > MaxArea) return false;
        double aspect = height * Math.Max(1, frame.Height) / (width * Math.Max(1, frame.Width));
        // Test karelerinde (2x2) en-boy anlamsız; gerçek kare 16:9'dur.
        if (frame.Width >= 64 && (aspect < 0.9 || aspect > 2.6)) return false;
        double centerX = (region.Left + region.Right) / 2, centerY = (region.Top + region.Bottom) / 2;
        return centerX >= 0.35 && centerY >= 1.0 / 3;
    }

    public void Reset()
    {
        lastTime = null;
        previous = shown = null;
        shownPose = null;
    }
}

internal static class GamePhoneGeometry
{
    private const int Width = 400, Height = 225, Left = 95, Right = 305;
    private readonly record struct Slot(double X, int Y, int Length, int Contrast);

    // Noktalar tam kareye göre 0..1; ekran düzleminin yönü hoparlörleri birleştiren eksenden alınabilir.
    internal readonly record struct Pose(double TopX, double TopY, double BottomX, double BottomY)
    {
        internal CropRegion Bounds
        {
            get
            {
                double h = BottomY - TopY, w = h * Height / Width * .25;
                return new CropRegion(TopY + h * .012, BottomY - h * .015,
                    Math.Min(TopX, BottomX) - w, Math.Max(TopX, BottomX) + w);
            }
        }
    }

    internal static CropRegion? Locate(Frame frame) => TryLocate(frame, out var pose) ? pose.Bounds : null;

    internal static bool TryLocate(Frame frame, out Pose pose)
    {
        pose = default;
        if (frame.Width < Width || frame.Height < Height ||
            Math.Abs(frame.Width / (double)frame.Height - Width / (double)Height) > .04) return false;
        Span<int> columns = stackalloc int[Width * 2];
        var grid = new Samples(frame, columns);
        Span<Slot> upper = stackalloc Slot[12], lower = stackalloc Slot[16];
        int tops = FindSlots(grid, 17, 75, 8, 19, upper);
        if (tops < 1) return false;
        int bottoms = FindSlots(grid, 145, 217, 5, 14, lower);
        if (bottoms < 1) return false;
        double best = 0;
        foreach (var top in upper[..tops])
        {
            if (!HasCamera(grid, top)) continue;
            foreach (var bottom in lower[..bottoms])
            {
                int h = bottom.Y - top.Y;
                double dx = bottom.X - top.X;
                if (h is < 115 or > 179 || Math.Abs(dx) > h * .24 ||
                    bottom.Length < top.Length * .46 || bottom.Length > top.Length ||
                    h < 7.9 * top.Length || h > 16.5 * top.Length ||
                    h < 12 * bottom.Length || h > 30 * bottom.Length) continue;
                if (!SmoothRim(grid, top, dx, h) || !SmoothRim(grid, bottom, dx, h)) continue;
                int left = SideStrength(grid, top, dx, h, -1);
                if (left < 12) continue;
                int right = SideStrength(grid, top, dx, h, 1);
                if (right < 12) continue;
                double score = Math.Min(left, right) + .25 * Math.Max(left, right) + .1 * Math.Min(top.Contrast, bottom.Contrast)
                    + .5 * RimBoundary(grid, bottom, dx, h, lower: true) + .5 * RimBoundary(grid, top, dx, h, lower: false);
                if (score <= best) continue;
                best = score;
                pose = new Pose(top.X / Width, (double)top.Y / Height, bottom.X / Width, (double)bottom.Y / Height);
            }
        }
        return best > 0;
    }

    // Üst ve alt şeritler ayrı okunur. Yarık bulunmazsa görüntünün ortasına ve altına bakılmaz.
    private static int FindSlots(Samples grid, int from, int to, int min, int max, Span<Slot> slots)
    {
        const int stride = Right - Left + 1;
        Span<byte> band = stackalloc byte[(to - from + 8) * stride];
        for (int y = from - 4; y < to + 4; y++)
            grid.Row(y, band.Slice((y - from + 4) * stride, stride));
        int count = 0;
        for (int y = from; y < to; y++)
        {
            var row = band.Slice((y - from + 4) * stride, stride);
            var above = band.Slice((y - from + 1) * stride, stride);
            var below = band.Slice((y - from + 7) * stride, stride);
            var rimAbove = band.Slice((y - from) * stride, stride);
            var rimBelow = band.Slice((y - from + 8) * stride, stride);
            int start = -1;
            for (int x = 105 - Left; x <= 294 - Left; x++)
            {
                int surround = Math.Min(above[x], below[x]);
                if (x < 294 - Left && surround - row[x] >= Math.Clamp(surround / 3, 14, 25))
                {
                    if (start < 0) start = x;
                    continue;
                }
                int length = x - start;
                if (start >= 0 && length >= min && length <= max)
                {
                    int center = start + length / 2, end = x + 1, border = start - 2;
                    Span<byte> rim = [rimAbove[border], rimAbove[center], rimAbove[end], rimBelow[border],
                        rimBelow[center], rimBelow[end], row[border], row[end]];
                    rim.Sort();
                    int rimTone = (rim[3] + rim[4]) / 2;
                    int contrast = rimTone - row[center];
                    if (contrast >= Math.Clamp(rimTone / 3, 20, 33) && rim[7] - rim[0] <= Math.Max(24, contrast * 3 / 4))
                    {
                        if (count == slots.Length) return 0; // Fazla adaylı menüde OCR açma.
                        slots[count++] = new Slot(Left + (start + x - 1) * .5, y, length, contrast);
                    }
                }
                start = -1;
            }
        }
        return count;
    }

    private static bool HasCamera(Samples grid, Slot top)
    {
        for (int side = -1; side <= 1; side += 2)
            for (int d = Math.Max(5, (int)Math.Round(top.Length * .62)); d <= (int)Math.Round(top.Length * 1.15); d++)
                for (int y = top.Y - 2; y <= top.Y + 2; y++)
                {
                    int x = (int)Math.Round(top.X) + side * d;
                    int center = grid.At(x, y);
                    int a = grid.At(x, y - 3), b = grid.At(x, y + 3), c = grid.At(x - 3, y), e = grid.At(x + 3, y);
                    int min = Math.Min(Math.Min(a, b), Math.Min(c, e));
                    int max = Math.Max(Math.Max(a, b), Math.Max(c, e));
                    if (min - center >= Math.Clamp(min / 3, 15, 23) && max - min < Math.Max(25, top.Contrast * .9)) return true;
                }
        return false;
    }

    private static bool SmoothRim(Samples grid, Slot slot, double dx, int h)
    {
        int r = (int)(h * .14), flat = 0;
        ReadOnlySpan<int> offsets = [-r, 3 - r, r - 3, r];
        foreach (int k in offsets)
        {
            int x = (int)Math.Round(slot.X) + k, y = slot.Y + (int)Math.Round(-k * dx / h);
            if (Math.Abs(grid.At(x, y - 2) - grid.At(x, y + 2)) < 16) flat++;
        }
        return flat >= 3;
    }

    // İki yarık da yazı alanının dışında kalmalı: üst yarığın altında, alt yarığın üstünde ekran-kasa sınırını ara.
    private static int RimBoundary(Samples grid, Slot slot, double dx, int h, bool lower)
    {
        Span<int> samples = stackalloc int[5];
        int best = 0;
        for (int distance = lower ? -10 : 3; distance <= (lower ? -4 : 7); distance += 2)
        {
            for (int i = -2; i <= 2; i++)
            {
                double k = i * .08;
                int x = (int)Math.Round(slot.X + k * h + dx * distance * .01);
                int y = (int)Math.Round(slot.Y + h * distance * .01 - (lower ? .8 : .52) * dx * k);
                samples[i + 2] = Math.Abs(grid.At(x, y - 2) - grid.At(x, y + 2));
            }
            samples.Sort();
            best = Math.Max(best, samples[2]);
        }
        return best;
    }

    // İki paralel uzun kenarı ayrı ayrı doğrula; ekrandaki bir metin çizgisi hoparlör gibi görünebilir.
    private static int SideStrength(Samples grid, Slot top, double dx, int h, int side)
    {
        ReadOnlySpan<double> heights = [.1, .24, .39, .54, .69, .84];
        Span<int> samples = stackalloc int[6];
        int best = 0;
        for (int width = 23; width <= 27; width++)
        {
            double radius = side * width * .01;
            for (int i = 0; i < heights.Length; i++)
            {
                int x = (int)Math.Round(top.X + heights[i] * dx + radius * h);
                int y = (int)Math.Round(top.Y + heights[i] * h - radius * dx);
                int strongest = 0;
                for (int k = -2; k <= 2; k += 2)
                    strongest = Math.Max(strongest, Math.Abs(grid.At(x + k - 2, y) - grid.At(x + k + 2, y)));
                samples[i] = strongest;
            }
            samples.Sort();
            best = Math.Max(best, (samples[2] + samples[3]) / 2);
        }
        return best;
    }

    // İki bant ve birkaç kenar noktası, kaynak çözünürlüğünden bağımsız sayıda örnek.
    private readonly ref struct Samples
    {
        private readonly Frame frame;
        private readonly Span<int> x1, x2;
        internal Samples(Frame frame, Span<int> columns)
        {
            this.frame = frame;
            x1 = columns[..Width];
            x2 = columns[Width..];
            for (int x = 0; x < Width; x++)
            {
                x1[x] = (4 * x + 1) * frame.Width / (4 * Width) * 4;
                x2[x] = (4 * x + 3) * frame.Width / (4 * Width) * 4;
            }
        }

        internal void Row(int y, scoped Span<byte> dest)
        {
            (int a, int b) = Rows(y);
            for (int i = 0; i < dest.Length; i++)
                dest[i] = (byte)Sample(Left + i, a, b);
        }

        internal int At(int x, int y)
        {
            (int a, int b) = Rows(y);
            return Sample(x, a, b);
        }

        private (int, int) Rows(int y) => (
            (4 * y + 1) * frame.Height / (4 * Height) * frame.Stride,
            (4 * y + 3) * frame.Height / (4 * Height) * frame.Stride);

        private int Sample(int x, int row1, int row2)
        {
            int a = x1[x], b = x2[x];
            return (Tone(row1 + a) + Tone(row1 + b) + Tone(row2 + a) + Tone(row2 + b)) >> 10;
        }

        private int Tone(int p) => frame.Pixels[p] * 29 + frame.Pixels[p + 1] * 150 + frame.Pixels[p + 2] * 77;
    }
}
