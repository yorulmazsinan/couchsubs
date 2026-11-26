// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>Eldeki telefonun eğik ekranını düz okuyup sözcükleri özgün görüntüdeki yerlerine döndürür.</summary>
internal sealed class GamePhoneReader
{
    private string? failedTail;
    private long retryAfter;

    public Reading Read(Frame frame, CropRegion region, GamePhoneGeometry.Pose pose, ITextReader reader)
    {
        double topX = pose.TopX * frame.Width, topY = pose.TopY * frame.Height;
        double dx = (pose.BottomX - pose.TopX) * frame.Width, dy = (pose.BottomY - pose.TopY) * frame.Height;
        // Ekran iki hoparlör arasındadır. Perspektifte alt yatay kenarın eğimi üsttekinden farklıdır.
        (double X, double Y) Point(double u, double v)
        {
            double t = 0.04 + 0.915 * v;
            double side = (u - 0.5) * 0.52;
            return (topX + dx * t + side * dy, topY + dy * t - side * dx * (0.52 + v * 0.30));
        }

        // Küçük yazıyı tek örneklemede büyüt; yüksek çözünürlükte ara görüntü 960 satırı aşmasın.
        double scale = dy * 0.5 < 300 ? 1.5 : 1;
        scale = Math.Min(scale, 960 / (dy * 0.9));
        int width = Math.Max(1, (int)Math.Round(dy * 0.5 * scale));
        int height = Math.Max(1, (int)Math.Round(dy * 0.9 * scale));
        var flat = Frame.Blank(width, height);
        for (int y = 0; y < height; y++)
        {
            double v = (y + 0.5) / height;
            var left = Point(0, v);
            var right = Point(1, v);
            double stepX = (right.X - left.X) / width, stepY = (right.Y - left.Y) / width;
            double sx = left.X + stepX * 0.5 - 0.5, sy = left.Y + stepY * 0.5 - 0.5;
            for (int x = 0; x < width; x++, sx += stepX, sy += stepY)
                Sample(frame, sx, sy, flat.Pixels, y * flat.Stride + x * 4);
        }

        // Koyu ekran (koyu tema, gece, kısılmış ekran): gri, gerilmiş ve ters çevrilmiş okunur (PhoneDarkScreen).
        PhoneDarkScreen.Prepare(flat);
        var reading = ReadMessages(flat, reader);
        if (reading.Lines.Count == 0) return Reading.Empty;
        TextBox Map(TextBox b)
        {
            var a = Point(b.Left, b.Top); var c = Point(b.Right, b.Top);
            var d = Point(b.Left, b.Bottom); var e = Point(b.Right, b.Bottom);
            double X(double x) => Math.Clamp((x / frame.Width - region.Left) / (region.Right - region.Left), 0, 1);
            double Y(double y) => Math.Clamp((y / frame.Height - region.Top) / (region.Bottom - region.Top), 0, 1);
            return new TextBox(X(Math.Min(Math.Min(a.X, c.X), Math.Min(d.X, e.X))),
                               Y(Math.Min(Math.Min(a.Y, c.Y), Math.Min(d.Y, e.Y))),
                               X(Math.Max(Math.Max(a.X, c.X), Math.Max(d.X, e.X))),
                               Y(Math.Max(Math.Max(a.Y, c.Y), Math.Max(d.Y, e.Y))));
        }
        return new Reading(reading.Lines.Select(line => line with
        {
            PhoneBox = line.Box,
            Box = line.Box is { } box ? Map(box) : null,
            Words = line.Words?.Select(w => w with { Box = Map(w.Box) }).ToArray(),
            Icons = line.Icons?.Select(i => i with { Box = Map(i.Box) }).ToArray(),
        }).ToArray());
    }

    // Bir balonun alt satırı okunup üstü kaybolabilir. Aynı karede üstünde harf izi arayıp
    // yalnız o şeritteki soluk harflerin kontrastını artır. İkinci okuma da aynı alt satırı aynı yerde bulursa eksik satırı ekle.
    internal Reading ReadMessages(Frame flat, ITextReader reader)
    {
        var reading = reader.ReadScreen(flat);
        if (reading.Lines.Count < 3) return reading;
        var tail = reading.Lines.MaxBy(l => l.Box?.Bottom ?? 0)!;
        if (tail.Box is not { Top: > .65 } b || !char.IsLower(tail.Text.TrimStart()[0])
            || !tail.Text.Any(char.IsWhiteSpace)) return reading;
        double h = b.Bottom - b.Top;
        if (tail.Confidence is not >= .85 || (tail.Text == failedTail && Environment.TickCount64 < retryAfter)
            || h <= 0 || h > .12 || reading.Lines.Any(l => l != tail && l.Box is { } a && IsPrecedingLine(a, b)))
            return reading;
        int top = Math.Max(0, (int)Math.Floor((b.Top - 1.6 * h) * flat.Height));
        int end = Math.Min(flat.Height, (int)Math.Ceiling((b.Bottom + .35 * h) * flat.Height));
        if (end <= top || !HasTextEdges(flat, b, h)) return reading;
        failedTail = tail.Text;
        retryAfter = Environment.TickCount64 + 2000;
        var band = flat.Crop(0, top, flat.Width, end - top);
        EnhanceBand(band, BackgroundLevel(flat, b));
        Reading retry;
        try { retry = reader.ReadScreen(band); }
        catch (Exception e) when (e is not OperationCanceledException and not OutOfMemoryException) { return reading; }
        var strip = new TextBox(0, (double)top / flat.Height, 1, (double)end / flat.Height);
        TextBox Map(TextBox box) => box.PlacedIn(strip);
        var key = TextMatch.Normalize(tail.Text);
        bool ConfirmsTail(TextLine line) => line.Box is { } box && TextMatch.Normalize(line.Text) == key
            && Math.Abs(Map(box).Top - b.Top) < h * .5 && Math.Abs(box.Left - b.Left) < .08;
        if (!retry.Lines.Any(ConfirmsTail)) return reading;
        var missing = retry.Lines.Where(l => l.Box is { } box && IsPrecedingLine(Map(box), b)
            && l.Text.Any(char.IsWhiteSpace) && l.Text.Count(char.IsLetter) >= 4 && l.Confidence is >= .94).Take(2).ToArray();
        if (missing.Length != 1) return reading;
        var line = missing[0];
        var recoveredBox = Map(line.Box!.Value);
        // İlk okuma aynı satırın yalnız son kelimelerini bulmuş olabilir. Üstüne ikinci bir kutu koyma.
        if (reading.Lines.Any(l => l != tail && l.Box is { } existing && SameRow(existing, recoveredBox))) return reading;
        // Kurtarılan satır okumada zaten varsa (başka yerde okunmuş aynı yazı) ikinci kez eklenmez: balonda aynı cümle iki
        // kez görünüyordu (X, 22 Kas; Mac ile aynı).
        var recoveredText = TextMatch.Normalize(line.Text);
        if (reading.Lines.Any(l => PhoneSteady.SameReading(l.Text, line.Text)
            || TextMatch.Normalize(l.Text).Contains(recoveredText, StringComparison.Ordinal))) return reading;
        failedTail = null;
        var recovered = line with
        {
            Box = recoveredBox,
            Words = line.Words?.Select(w => w with { Box = Map(w.Box) }).ToArray(),
            Icons = line.Icons?.Select(i => i with { Box = Map(i.Box) }).ToArray(),
        };
        return new Reading(reading.Lines.Append(recovered).OrderBy(l => l.Box?.Top));
    }

    private static bool SameRow(TextBox a, TextBox b)
    {
        double overlap = Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top);
        return Math.Min(a.Right, b.Right) > Math.Max(a.Left, b.Left)
            && overlap >= .5 * Math.Min(a.Bottom - a.Top, b.Bottom - b.Top);
    }

    private static bool IsPrecedingLine(TextBox a, TextBox b)
    {
        double h = b.Bottom - b.Top, distance = (b.Top + b.Bottom - a.Top - a.Bottom) / 2;
        return distance > h * .4 && distance < h * 1.55
            && (Math.Abs(a.Left - b.Left) < .08 || Math.Abs(a.Right - b.Right) < .05);
    }

    private static int Luma(byte[] pixels, int index) =>
        (pixels[index] + 2 * pixels[index + 1] + pixels[index + 2]) / 4;

    private static int BackgroundLevel(Frame image, TextBox anchor)
    {
        // Medyan, balondaki harflerin ve kenar yumuşatmanın zemin ölçümünü bozmasını önler.
        Span<int> levels = stackalloc int[256];
        levels.Clear();
        const int columns = 24, rows = 8;
        for (int y = 0; y < rows; y++)
        {
            double v = anchor.Top + (y + .5) / rows * (anchor.Bottom - anchor.Top);
            int row = Math.Clamp((int)(v * image.Height), 0, image.Height - 1) * image.Stride;
            for (int x = 0; x < columns; x++)
            {
                double u = anchor.Left + (x + .5) / columns * (anchor.Right - anchor.Left);
                int column = Math.Clamp((int)(u * image.Width), 0, image.Width - 1);
                levels[Luma(image.Pixels, row + column * 4)]++;
            }
        }
        int sum = 0;
        for (int i = 0; i < levels.Length; i++)
            if ((sum += levels[i]) >= columns * rows / 2) return i;
        return 0;
    }

    private static void EnhanceBand(Frame band, int background)
    {
        for (int at = 0; at < band.Pixels.Length; at += 4)
        {
            byte tone = (byte)Math.Clamp(160 + 6 * (Luma(band.Pixels, at) - background), 0, 255);
            band.Pixels[at] = band.Pixels[at + 1] = band.Pixels[at + 2] = tone;
        }
    }

    private static bool HasTextEdges(Frame image, TextBox tail, double h)
    {
        int left = Math.Clamp((int)(tail.Left * image.Width), 0, image.Width - 1);
        int right = Math.Clamp((int)(tail.Right * image.Width), left, image.Width - 1);
        int rows = 0;
        for (int k = 0; k < 8; k++)
        {
            int y = Math.Clamp((int)((tail.Top - h * (.2 + k * .12)) * image.Height), 0, image.Height - 1);
            int at = y * image.Stride + left * 4, edges = 0;
            // Soluk harfin iki yanı arasında birkaç parlaklık basamağı yeter. Tek çizgi yeterli değil.
            for (int x = left; x + 3 < right; x += 2, at += 8)
                if (Math.Abs(Luma(image.Pixels, at + 12) - Luma(image.Pixels, at)) >= 3 && ++edges >= 7) break;
            if (edges >= 7 && ++rows >= 2) return true;
        }
        return false;
    }

    private static void Sample(Frame frame, double x, double y, byte[] output, int offset)
    {
        x = Math.Clamp(x, 0, frame.Width - 1);
        y = Math.Clamp(y, 0, frame.Height - 1);
        int x0 = (int)x, y0 = (int)y;
        int wx = (int)((x - x0) * 256), wy = (int)((y - y0) * 256);
        int a = y0 * frame.Stride + x0 * 4, b = x0 + 1 < frame.Width ? a + 4 : a;
        int nextRow = y0 + 1 < frame.Height ? frame.Stride : 0;
        var pixels = frame.Pixels;
        for (int channel = 0; channel < 3; channel++)
        {
            int top = pixels[a + channel] * (256 - wx) + pixels[b + channel] * wx;
            int bottom = pixels[a + nextRow + channel] * (256 - wx) + pixels[b + nextRow + channel] * wx;
            output[offset + channel] = (byte)((top * (256 - wy) + bottom * wy + 32768) >> 16);
        }
        output[offset + 3] = 255;
    }
}
