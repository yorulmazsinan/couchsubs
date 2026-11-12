// SPDX-License-Identifier: AGPL-3.0-only

using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using CouchSubs.Core;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;

namespace CouchSubs.Linux;

/// <summary>
/// PS5 bağlantısının (libchiaki) günlüğünü veri klasöründeki remoteplay.log dosyasına yazar; uyarı ve hatalar panelin
/// günlüğünde de görünür. Dosya 1 MB'yi geçince eski yarısı silinir (Windows'taki RemotePlayDiagnostics ile aynı).
/// </summary>
internal static class RemotePlayDiagnostics
{
    private const long MaxBytes = 1 << 20;
    private static readonly BlockingCollection<string> Lines = new(boundedCapacity: 2000);

    internal static string LogPath => Path.Combine(AppPaths.Data, "remoteplay.log");

    public static void Start()
    {
        RemotePlayLog.MessageLogged += line =>
        {
            Lines.TryAdd($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {line}");
            if (!line.StartsWith("[chiaki info]", StringComparison.Ordinal)) Log.Write("ps5", line);
        };
        new Thread(WriteLoop) { IsBackground = true, Name = "remoteplay.log" }.Start();
    }

    private static void WriteLoop()
    {
        foreach (var line in Lines.GetConsumingEnumerable())
        {
            try
            {
                var info = new FileInfo(LogPath);
                if (info.Exists && info.Length > MaxBytes)
                {
                    var text = File.ReadAllText(LogPath);
                    File.WriteAllText(LogPath, text[(text.Length / 2)..]);
                }
                File.AppendAllText(LogPath, line + Environment.NewLine);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // Günlük yazılamasa da uygulama sürer.
            }
        }
    }
}

/// <summary>Bir bölgenin tek seferlik okuması: süre, bölgenin boyutu, bulunan satırlar ve altyazı sayılan kısım.</summary>
internal sealed record RegionReading(long Ms, int Width, int Height, string[] Lines, string Subtitle);

internal static class Diagnostics
{
    /// <summary>couchsubs_native.so yüklenebiliyor mu (yoksa PS5'e bağlanılamaz).</summary>
    public static bool NativeAvailable { get; } = CheckNative();

    private static bool CheckNative()
    {
        if (!NativeLibrary.TryLoad("couchsubs_native", typeof(StreamSession).Assembly, null, out var handle)) return false;
        NativeLibrary.Free(handle);
        return true;
    }

    /// <summary>Altyazı bölgesini bir kez okur: panelde "şu an ne okunuyor?" denemesi.</summary>
    public static RegionReading ReadRegion(LinuxServices services, Frame frame, UserSettings settings, bool deep = true)
    {
        var reader = services.MakeReader(settings.SourceLanguage)
                     ?? throw new InvalidOperationException("Tesseract bulunamadı / Tesseract is not installed.");
        var area = RegionCropper.Crop(frame, settings.Region);
        var watch = Stopwatch.StartNew();
        var reading = reader.ReadLines(area, deep);
        var elapsed = watch.ElapsedMilliseconds;
        var region = new TextBox(settings.Region.Left, settings.Region.Top, settings.Region.Right, settings.Region.Bottom);
        var subtitle = reading.WithoutButtonPrompts().WithoutOcrNoise().SubtitleBlock(region);
        return new RegionReading(elapsed, area.Width, area.Height, [.. reading.Lines.Select(line => line.Text)], subtitle.Text);
    }

    /// <summary>
    /// Kaydedilmiş ham BGRA kareyi varsayılan altyazı bölgesinde okur, istenirse çevirir. PS5 olmadan yazı tanımayı ve
    /// çeviriyi denemek içindir: <c>ffmpeg -i kare.png -pix_fmt bgra -f rawvideo kare.bgra</c>.
    /// </summary>
    public static async Task<int> ReadRawAsync(string file, int width, int height, bool translate)
    {
        var pixels = await File.ReadAllBytesAsync(file);
        if (pixels.Length < width * height * 4)
        {
            Console.Error.WriteLine($"Dosya {width}x{height} BGRA kare için küçük ({pixels.Length} bayt).");
            return 2;
        }
        var frame = new Frame(pixels, width, height, width * 4);
        var services = new LinuxServices();
        var settings = new UserSettings();
        if (services.MakeReader(settings.SourceLanguage) is null)
        {
            Console.Error.WriteLine("Tesseract bulunamadı (libtesseract ve tesseract-ocr-eng kurulu mu?).");
            return 3;
        }
        for (var round = 1; round <= 4; round++)
        {
            // İlk iki okuma derin (boş bölgede üç karede bir yapılan), son ikisi olağan kare okumasıdır.
            var result = ReadRegion(services, frame, settings, deep: round <= 2);
            Console.WriteLine($"{(round <= 2 ? "derin" : "olağan")} okuma {round}: {result.Ms} ms, bölge {result.Width}x{result.Height}");
            if (round < 4) continue;
            foreach (var line in result.Lines) Console.WriteLine($"  satır: {line}");
            Console.WriteLine($"  altyazı: {result.Subtitle}");
            if (!translate || string.IsNullOrWhiteSpace(result.Subtitle)) continue;
            var model = services.Translation;
            if (!model.IsInstalled(settings.SourceLanguage, settings.TargetLanguage))
            {
                Console.WriteLine("  çeviri modeli indiriliyor…");
                await model.DownloadAsync(settings.SourceLanguage, settings.TargetLanguage, new Progress<double>(), CancellationToken.None);
            }
            var translator = model.Create(settings.SourceLanguage, settings.TargetLanguage);
            for (var attempt = 1; attempt <= 2; attempt++)
            {
                var watch = Stopwatch.StartNew();
                var translated = await translator.TranslateAsync(result.Subtitle.Replace('\n', ' '));
                Console.WriteLine($"  çeviri {attempt}: {watch.ElapsedMilliseconds} ms: {translated}");
            }
        }
        return 0;
    }
}

/// <summary>Panelde bölge seçimi için PS5 karesinin küçültülmüş PNG'si (bağımlılıksız, en hızlı sıkıştırma).</summary>
internal static class Png
{
    private static readonly uint[] CrcTable = MakeCrcTable();

    public static byte[] Encode(Frame frame, int maxWidth)
    {
        var step = Math.Max(1, (int)Math.Ceiling(frame.Width / (double)maxWidth));
        int width = frame.Width / step, height = frame.Height / step;
        var raw = new byte[(width * 3 + 1) * height];
        for (var y = 0; y < height; y++)
        {
            var target = y * (width * 3 + 1) + 1;
            var source = y * step * frame.Stride;
            for (var x = 0; x < width; x++)
            {
                var i = source + (x * step * 4);
                raw[target++] = frame.Pixels[i + 2];
                raw[target++] = frame.Pixels[i + 1];
                raw[target++] = frame.Pixels[i];
            }
        }
        using var data = new MemoryStream();
        using (var zlib = new ZLibStream(data, CompressionLevel.Fastest, leaveOpen: true)) zlib.Write(raw);

        using var png = new MemoryStream();
        png.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header, width);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), height);
        header[8] = 8;   // kanal başına bit
        header[9] = 2;   // RGB
        Chunk(png, "IHDR", header);
        Chunk(png, "IDAT", data.ToArray());
        Chunk(png, "IEND", []);
        return png.ToArray();
    }

    private static void Chunk(Stream output, string type, byte[] data)
    {
        Span<byte> number = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(number, data.Length);
        output.Write(number);
        var name = System.Text.Encoding.ASCII.GetBytes(type);
        output.Write(name);
        output.Write(data);
        BinaryPrimitives.WriteUInt32BigEndian(number, Crc(data, Crc(name, 0xFFFFFFFF)) ^ 0xFFFFFFFF);
        output.Write(number);
    }

    private static uint Crc(byte[] data, uint crc)
    {
        foreach (var value in data) crc = CrcTable[(crc ^ value) & 0xFF] ^ (crc >> 8);
        return crc;
    }

    private static uint[] MakeCrcTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            var c = n;
            for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }
}
