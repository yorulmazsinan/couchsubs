// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>BGRA (piksel başına 4 bayt) görüntü. PS5 akışından gelen kareler ve kırpılmış bölgeler.</summary>
public sealed class Frame(byte[] pixels, int width, int height, int stride)
{
    public byte[] Pixels { get; } = pixels;
    public int Width { get; } = width;
    public int Height { get; } = height;
    public int Stride { get; } = stride;

    /// <summary>
    /// Karenin kaynaktaki biçimi (tanı, telefon aramasının durum satırı; #1385): Xbox'ta oynatıcının gönderdiği JPEG'in
    /// boyutu, akışın boyutu ve piksel düzeni. PS5 karesinde null.
    /// </summary>
    public string? Source { get; init; }

    /// <summary>
    /// Boyutlar diziye uyuyor mu: genişlik, yükseklik ve satır aralığı negatif değil, satır en az <c>genişlik × 4</c> bayt
    /// ve dizi son satırın sonuna kadar yetiyor. Kurulurken bir kez hesaplanır (kare değiştirilemez). Tutarsız kare
    /// okunmaz (<c>WindowsOcrReader</c>), piksel döngüleri ona girmez; dizinin dışına taşan okuma olmaz (GitHub #587).
    /// </summary>
    public bool IsConsistent { get; } = Fits(pixels, width, height, stride);

    /// <summary>Günlük için: "genişlik x yükseklik, satır aralığı, dizi boyu".</summary>
    public string Layout => $"{Width}x{Height}, stride {Stride}, {Pixels?.Length ?? -1} bayt";

    private static bool Fits(byte[]? pixels, int width, int height, int stride)
    {
        if (pixels is null || width < 0 || height < 0 || stride < 0) return false;
        if (width == 0 || height == 0) return true;
        return (long)stride >= (long)width * 4 && pixels.LongLength >= ((long)(height - 1) * stride) + ((long)width * 4);
    }

    public static Frame Blank(int width, int height) => new(new byte[width * height * 4], width, height, width * 4);

    /// <summary>Yerel kodun verdiği tamponun kopyası (tampon yalnız geri çağrı süresince geçerlidir).</summary>
    public static unsafe Frame Copy(IntPtr bgra, int width, int height, int stride)
    {
        var pixels = new byte[width * height * 4];
        var source = (byte*)bgra;
        fixed (byte* target = pixels)
            for (var y = 0; y < height; y++)
                Buffer.MemoryCopy(source + ((long)y * stride), target + ((long)y * width * 4), width * 4, width * 4);
        return new Frame(pixels, width, height, width * 4);
    }

    public Frame Crop(int x, int y, int width, int height)
    {
        x = Math.Clamp(x, 0, Width);
        y = Math.Clamp(y, 0, Height);
        width = Math.Clamp(width, 0, Width - x);
        height = Math.Clamp(height, 0, Height - y);
        var result = Blank(width, height);
        if (!IsConsistent) return result;
        for (var row = 0; row < height; row++)
            Buffer.BlockCopy(Pixels, ((y + row) * Stride) + (x * 4), result.Pixels, row * result.Stride, width * 4);
        return result;
    }

    /// <summary>İki doğrusal (bilinear) büyütme; kısa satırların okunmasına yardım eder.</summary>
    public Frame Scaled(int factor)
    {
        var result = Blank(Width * factor, Height * factor);
        if (!IsConsistent || Width == 0 || Height == 0) return result;
        for (var ty = 0; ty < result.Height; ty++)
        {
            var sy = Math.Min(((ty + 0.5) / factor) - 0.5, Height - 1.0);
            if (sy < 0) sy = 0;
            var y0 = (int)sy;
            var y1 = Math.Min(y0 + 1, Height - 1);
            var fy = sy - y0;
            for (var tx = 0; tx < result.Width; tx++)
            {
                var sx = Math.Min(((tx + 0.5) / factor) - 0.5, Width - 1.0);
                if (sx < 0) sx = 0;
                var x0 = (int)sx;
                var x1 = Math.Min(x0 + 1, Width - 1);
                var fx = sx - x0;
                for (var c = 0; c < 4; c++)
                {
                    double P(int x, int y) => Pixels[(y * Stride) + (x * 4) + c];
                    var top = P(x0, y0) + ((P(x1, y0) - P(x0, y0)) * fx);
                    var bottom = P(x0, y1) + ((P(x1, y1) - P(x0, y1)) * fx);
                    result.Pixels[(ty * result.Stride) + (tx * 4) + c] = (byte)Math.Round(top + ((bottom - top) * fy));
                }
            }
        }
        return result;
    }

    /// <summary>İki doğrusal büyütme ya da küçültme, kesirli oranla (OpenCV'nin INTER_LINEAR'ı gibi piksel ortalarından).</summary>
    public Frame Resized(int width, int height)
    {
        var result = Blank(width, height);
        if (!IsConsistent || Width == 0 || Height == 0) return result;
        double scaleX = (double)Width / width, scaleY = (double)Height / height;
        for (var ty = 0; ty < height; ty++)
        {
            var sy = Math.Clamp(((ty + 0.5) * scaleY) - 0.5, 0, Height - 1.0);
            var y0 = (int)sy;
            var y1 = Math.Min(y0 + 1, Height - 1);
            var fy = sy - y0;
            for (var tx = 0; tx < width; tx++)
            {
                var sx = Math.Clamp(((tx + 0.5) * scaleX) - 0.5, 0, Width - 1.0);
                var x0 = (int)sx;
                var x1 = Math.Min(x0 + 1, Width - 1);
                var fx = sx - x0;
                int a = (y0 * Stride) + (x0 * 4), b = (y0 * Stride) + (x1 * 4), c = (y1 * Stride) + (x0 * 4), d = (y1 * Stride) + (x1 * 4);
                var o = (ty * result.Stride) + (tx * 4);
                for (var k = 0; k < 4; k++)
                {
                    var top = Pixels[a + k] + ((Pixels[b + k] - Pixels[a + k]) * fx);
                    var bottom = Pixels[c + k] + ((Pixels[d + k] - Pixels[c + k]) * fx);
                    result.Pixels[o + k] = (byte)Math.Round(top + ((bottom - top) * fy));
                }
            }
        }
        return result;
    }
}

/// <summary>Görüntüde altyazının arandığı bölge, kenarlara oranla (0–1, üstten ve soldan).</summary>
/// <summary>Yazı tanıma öncesi görüntü hazırlığı.</summary>
public static class TextImage
{
    /// <summary>
    /// Otomatik seviye: bölgenin en parlak %0,5'i beyaza çekilir. Karanlık ya da soluk görüntüde (HDR'den dönüştürülmüş
    /// video, karanlık sahne, geçiş efekti) beyaz altyazı ancak 120-180 parlaklıkta kalıyor, beyaz yazı süzgeçleri hiç
    /// çalışmıyordu. Yazı zaten beyazsa (en parlak kısım 235 ve üstü) görüntü değişmez. Sonuç dolgusuz yeni bir karedir.
    ///
    /// GitHub #903: üç çökme bu döngünün dizi okuma/yazma komutunda oldu (erişilen adres, dizi + sıra toplamının yalnız alt
    /// 32 biti). Eski döngüde güvensiz kod, sabitleme ya da yerel tampon yoktu; dizi erişimleri sınır denetimliydi ve sıra
    /// hesapları dizi boyunu aşamıyordu. Döngü yine de satır satır, sınır denetimli <see cref="Span{T}"/> dilimleri
    /// üzerinde yazıldı: satırın başı 64 bit hesaplanıp bir kez denetlenir, iç döngü yalnız satırın içinde küçük bir sıra
    /// kullanır, SIMD yok. Kodun bir hatası bulunmadı; bu, kod tarafını sadeleştirip daraltmak için (nedeni kesin değil).
    /// </summary>
    public static Frame AutoLevel(Frame image)
    {
        if (!image.IsConsistent || image.Width == 0 || image.Height == 0) return image;
        int width = image.Width, height = image.Height, stride = image.Stride;
        var rowBytes = width * 4; // IsConsistent: dizi en az bir satır tutuyor, int'e sığar.
        var source = image.Pixels;

        var hist = new int[256];
        for (var y = 0; y < height; y++)
        {
            ReadOnlySpan<byte> row = source.AsSpan(RowStart(y, stride), rowBytes);
            for (var i = 0; i < row.Length; i += 4)
            {
                int b = row[i], g = row[i + 1], r = row[i + 2];
                hist[((r * 3) + (g * 6) + b) / 10]++;
            }
        }

        var limit = (double)width * height * 0.005;
        long count = 0;
        var top = 255;
        for (; top > 0; top--)
        {
            count += hist[top];
            if (count >= limit) break;
        }
        if (top >= 235 || top < 60) return image;

        var scale = 250.0 / top;
        var lookup = new byte[256];
        for (var v = 0; v < 256; v++) lookup[v] = (byte)Math.Min(255, v * scale);

        var output = new byte[checked(rowBytes * height)];
        for (var y = 0; y < height; y++)
        {
            ReadOnlySpan<byte> row = source.AsSpan(RowStart(y, stride), rowBytes);
            var target = output.AsSpan(RowStart(y, rowBytes), rowBytes);
            for (var i = 0; i < row.Length; i += 4)
            {
                target[i] = lookup[row[i]];
                target[i + 1] = lookup[row[i + 1]];
                target[i + 2] = lookup[row[i + 2]];
                target[i + 3] = 255;
            }
        }
        return new Frame(output, width, height, rowBytes);
    }

    /// <summary>Satırın dizideki başı; 64 bit hesaplanır, int'e sığmazsa (dizi 2 GB'ı aşamaz, olmamalı) istisna.</summary>
    private static int RowStart(int y, int stride) => checked((int)((long)y * stride));

    /// <summary>
    /// Oyun altyazıları çoğunlukla koyu kenarlı ya da gölgeli beyaz yazıdır. Parlak zeminde (kum, gökyüzü) Windows'un
    /// yazı tanıması harfleri zeminden ayıramıyor ve "CESAREiVJütt'h" gibi okuyordu. Burada yakınında koyu piksel olan
    /// beyaza yakın pikseller siyah yazı, geri kalanı beyaz zemin olur; yazı tanıma en iyi bu biçimi okur.
    /// </summary>
    public static Frame WhiteTextOnly(Frame image, int radius = 5)
    {
        if (!image.IsConsistent) return image;
        int width = image.Width, height = image.Height;
        var bright = new bool[width * height];
        // Koyu piksellerin toplamlı tablosu: bir pencerede koyu piksel var mı tek adımda bulunur.
        var dark = new int[(width + 1) * (height + 1)];
        for (var y = 0; y < height; y++)
        {
            var rowSum = 0;
            ReadOnlySpan<byte> row = image.Pixels.AsSpan(RowStart(y, image.Stride), width * 4);
            for (var x = 0; x < width; x++)
            {
                var i = x * 4;
                int b = row[i], g = row[i + 1], r = row[i + 2];
                int min = Math.Min(r, Math.Min(g, b)), max = Math.Max(r, Math.Max(g, b));
                bright[(y * width) + x] = min >= 200 && max - min <= 45;
                rowSum += (r * 3 + g * 6 + b) / 10 < 110 ? 1 : 0;
                dark[((y + 1) * (width + 1)) + x + 1] = dark[(y * (width + 1)) + x + 1] + rowSum;
            }
        }
        var result = new Frame(new byte[width * height * 4], width, height, width * 4);
        for (var y = 0; y < height; y++)
        {
            int top = Math.Max(0, y - radius), bottom = Math.Min(height, y + radius + 1);
            for (var x = 0; x < width; x++)
            {
                var text = false;
                if (bright[(y * width) + x])
                {
                    int left = Math.Max(0, x - radius), right = Math.Min(width, x + radius + 1);
                    var darkCount = dark[(bottom * (width + 1)) + right] - dark[(top * (width + 1)) + right]
                                    - dark[(bottom * (width + 1)) + left] + dark[(top * (width + 1)) + left];
                    text = darkCount > 0;
                }
                var value = (byte)(text ? 0 : 255);
                var o = (y * result.Stride) + (x * 4);
                result.Pixels[o] = result.Pixels[o + 1] = result.Pixels[o + 2] = value;
                result.Pixels[o + 3] = 255;
            }
        }
        return result;
    }
}

public sealed record CropRegion(double Top = 0.62, double Bottom = 0.97, double Left = 0.14, double Right = 0.86);

public static class RegionCropper
{
    public static Frame Crop(Frame image, CropRegion region)
    {
        // Mac'teki CGRect.integral ile aynı: kenarlar dışa yuvarlanır.
        var left = (int)Math.Floor(image.Width * region.Left);
        var top = (int)Math.Floor(image.Height * region.Top);
        var right = (int)Math.Ceiling(image.Width * region.Right);
        var bottom = (int)Math.Ceiling(image.Height * region.Bottom);
        return image.Crop(left, top, right - left, bottom - top);
    }

    /// <summary>Bölgenin küçültülmüş gri kopyası: iki kareyi yazı tanımaya gerek kalmadan karşılaştırmaya yeter.</summary>
    public static byte[] Signature(Frame image)
    {
        const int width = ReadScheduler.SignatureWidth, height = ReadScheduler.SignatureHeight;
        var samples = new byte[width * height];
        if (image.Width == 0 || image.Height == 0 || !image.IsConsistent) return samples;
        for (var y = 0; y < height; y++)
        {
            var row = (y * image.Height / height) * image.Stride;
            for (var x = 0; x < width; x++)
            {
                var pixel = row + (x * image.Width / width) * 4;
                samples[y * width + x] = (byte)((image.Pixels[pixel] + image.Pixels[pixel + 1] * 2 + image.Pixels[pixel + 2]) / 4);
            }
        }
        return samples;
    }
}

/// <summary>Bir görüntüdeki yazıyı okur (Windows'ta Windows.Media.Ocr).</summary>
public interface ITextReader
{
    string Read(Frame image);
    /// <summary><paramref name="deep"/> false ise boş bölgede büyütülmüş okuma denenmez (işlemciyi çok daha az yorar).</summary>
    string Read(Frame image, bool deep) => Read(image);
    /// <summary>Satırlar ayrı ayrı ve görüntüdeki yerleriyle.</summary>
    Reading ReadLines(Frame image, bool deep) => Reading.FromText(Read(image, deep));
    /// <summary>
    /// "Ekranı çevir": karenin bütün yazıları, olduğu gibi. Altyazı okuması karenin birkaç hazırlığından (yalnız gölgeli
    /// beyaz yazı...) pakete ya da sözlüğe en uyanını seçer; ekranın tamamında o seçim altyazının hazırlığını kazandırıyor,
    /// menü, görev ve bilgi yazıları okumadan düşüyordu (GTA 6: "Ekranı çevir yalnız altyazıyı çeviriyor").
    /// </summary>
    Reading ReadScreen(Frame image) => ReadLines(image, false);
}

/// <summary>
/// OCR geniş bölgede "Go!" gibi kısa satırları sık sık hiç bulmaz. Bölgede yazı çıkmazsa ortadaki şerit (altyazılar
/// ortalıdır), sonra bölgenin tamamı büyütülerek yeniden okunur; yazı bulan ilk okuma kullanılır (şerit önce).
///
/// Mac'teki <c>VisionReader.firstLines</c> ile aynı: iki yedek okuma <b>sırayla</b> yapılır ve bölgenin tamamının
/// büyütmesinin uzun kenarı <see cref="MaxFallbackDimension"/> ile sınırlanır. Eskiden ikisi <c>Parallel.For</c> ile aynı
/// anda başlatılıyordu; yazı tanıma motoru zaten tek okumaya kilitli olduğu için kazanç yalnız hazırlıktaydı, 1440p
/// pencerede ise her boş karede iki iş parçacığı aynı anda 15 MB'lık iki katına büyütülmüş kareler ayırıyordu. Uzun
/// oturumdaki erişim ihlali (GitHub #587) bu paralel okumada görülüyordu.
/// </summary>
public static class ReadingFallback
{
    /// <summary>Yedek okumada büyütülmüş bölgenin uzun kenarı (piksel; Mac'te <c>maxFallbackDimension</c>).</summary>
    public const int MaxFallbackDimension = 1920;

    /// <summary>Satırsız eski biçim: bulunan yazı tek metin olarak döner.</summary>
    public static string FirstReading(Frame image, Func<Frame, string> recognize) =>
        FirstLines(image, frame => Reading.FromText(recognize(frame))).Text;

    public static Reading FirstLines(Frame image, Func<Frame, Reading> recognize)
    {
        var reading = recognize(image);
        if (reading.Lines.Count > 0 || image.Width == 0 || image.Height == 0) return reading;

        // Şeritte bulunan satırın yeri şeridin değil bölgenin tamamının oranlarıyla verilir.
        var (x, width) = CenterStrip(image, 0.4);
        var stripArea = new TextBox((double)x / image.Width, 0, (double)(x + width) / image.Width, 1);
        var strip = recognize(image.Crop(x, 0, width, image.Height).Scaled(2)).PlacedIn(stripArea);
        if (strip.Lines.Count > 0) return strip;
        var whole = recognize(ScaledForFallback(image));
        return whole.Lines.Count > 0 ? whole : Reading.Empty;
    }

    /// <summary>İki katına büyütme; uzun kenar <see cref="MaxFallbackDimension"/>'ı aşacaksa oran ona göre düşer (en az 1).</summary>
    internal static Frame ScaledForFallback(Frame image)
    {
        var longest = Math.Max(image.Width, image.Height);
        if (longest * 2 <= MaxFallbackDimension) return image.Scaled(2);
        var scale = Math.Max(1, (double)MaxFallbackDimension / longest);
        return image.Resized(Math.Max(1, (int)(image.Width * scale)), Math.Max(1, (int)(image.Height * scale)));
    }

    private static (int X, int Width) CenterStrip(Frame image, double widthFraction)
    {
        var width = image.Width * widthFraction;
        var left = (image.Width - width) / 2;
        var x = (int)Math.Floor(left);
        return (x, (int)Math.Ceiling(left + width) - x);
    }
}
