// SPDX-License-Identifier: AGPL-3.0-only

using System.IO.Compression;
using System.Text;
using System.Text.Json;
using CouchSubs.Core;
using Xunit.Abstractions;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Gerçek kare doğrulaması (yalnız yerel): COUCHSUBS_REAL_FRAMES bir dizin gösterirse (içinde kareler/K*.png ve
/// ocr/K*.json) her kare dedektör → okuyucu → sözlük/sahte çevirmen → stil → TV olayı hattından geçer; olaylar
/// cikti-windows/K*.json'a, özet cikti-windows/K*.txt'ye yazılır. Kareler telif altındadır, depoya girmez. Okuyucu
/// sahtedir: Apple Vision'ın aynı karedeki satırlarından okunan alanla kesişenleri, alanın koordinatına çevirip döner.
/// </summary>
public class RealFrameTests(ITestOutputHelper output)
{
    private static readonly string? Root = Environment.GetEnvironmentVariable("COUCHSUBS_REAL_FRAMES");

    public static IEnumerable<object[]> Frames() =>
        Root is null || !Directory.Exists(Path.Combine(Root, "kareler")) ? [["-"]]
            : Directory.GetFiles(Path.Combine(Root, "kareler"), "K*.png").Select(path => new object[] { Path.GetFileNameWithoutExtension(path) });

    /// <summary>Alan kırpıntısının boyutundan hangi bölge olduğunu bulan, Vision satırlarını döndüren okuyucu.</summary>
    private sealed class VisionReader : ITextReader
    {
        public IReadOnlyList<TextLine> Lines { get; set; } = [];
        /// <summary>Bu turda okunabilecek alanlar ve kırpıntıları (aynı boyda iki alan pikselleriyle ayrılır).</summary>
        public List<(CropRegion Region, Frame Crop)> Crops { get; } = [];
        public int Reads;
        public string Read(Frame image) => string.Join('\n', ReadScreen(image).Lines.Select(line => line.Text));
        public Reading ReadLines(Frame image, bool deep) => ReadScreen(image);
        public Reading ReadScreen(Frame image)
        {
            Interlocked.Increment(ref Reads);
            var match = Crops.FirstOrDefault(item => item.Crop.Width == image.Width && item.Crop.Height == image.Height
                                                     && item.Crop.Pixels.AsSpan().SequenceEqual(image.Pixels));
            if (match.Crop is null) return new Reading([]);
            var region = match.Region;
            var width = region.Right - region.Left;
            var height = region.Bottom - region.Top;
            var found = new List<TextLine>();
            foreach (var line in Lines)
            {
                var box = line.Box!.Value;
                var x = (box.Left + box.Right) / 2;
                var y = (box.Top + box.Bottom) / 2;
                if (x < region.Left || x > region.Right || y < region.Top || y > region.Bottom) continue;
                found.Add(line with
                {
                    Box = new TextBox(Math.Clamp((box.Left - region.Left) / width, 0, 1), Math.Clamp((box.Top - region.Top) / height, 0, 1),
                                      Math.Clamp((box.Right - region.Left) / width, 0, 1), Math.Clamp((box.Bottom - region.Top) / height, 0, 1)),
                });
            }
            return new Reading(found);
        }
    }

    private sealed class Prefixed : ITextTranslator
    {
        public int Requests;
        public List<string> Texts { get; } = [];
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref Requests);
            lock (Texts) Texts.Add(text);
            // Her sözcüğe "ç" eklenir: çeviri aslına benzemesin (benzer çeviri gösterilmez), okunur da kalsın.
            return Task.FromResult("⟨TR⟩ " + string.Join(' ', text.Split(' ').Select(word => word.Any(char.IsLetter) ? word + "ç" : word)));
        }
    }

    private sealed class Recorder : IRegionSender
    {
        public List<(string Event, SortedDictionary<string, object> Data)> Events { get; } = [];
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight = null) => SendRegion(id, text, box, lineHeight, null, null);
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight, IReadOnlyList<IconPlacement>? icons,
                               IReadOnlyList<ScreenTranslation.Item>? blocks)
        {
            lock (Events) Events.Add(("region", SubtitleServer.RegionData(id, text, box, lineHeight, icons, blocks)));
        }
        public void ClearRegions()
        {
            lock (Events) Events.Add(("region-clear", new SortedDictionary<string, object>()));
        }
    }

    [Theory]
    [MemberData(nameof(Frames))]
    public async Task RealFrameThroughTheWholeLine(string name)
    {
        if (Root is null || name == "-") return;
        var frame = Png.Load(Path.Combine(Root, "kareler", name + ".png"));
        var lines = VisionLines(Path.Combine(Root, "ocr", name + ".json"));
        var outDir = Directory.CreateDirectory(Path.Combine(Root, "cikti-windows")).FullName;
        var variants = Variants(name, frame, lines);
        var report = new StringBuilder();
        foreach (var (label, sequence) in variants)
        {
            var detector = new ScreenTextDetector();
            var reader = new VisionReader();
            var translator = new Prefixed();
            var recorder = new Recorder();
            var watcher = new RegionWatcher(reader, translator, recorder) { TranslatesUiCommands = true, Rejected = detector.Reject };
            var random = new Random(7);
            long time = 0;
            var settled = -1;
            var requestsAtSettle = 0;
            for (var step = 0; step < sequence.Count * 12; step++, time += 100)
            {
                var (image, frameLines) = sequence[Math.Min(sequence.Count - 1, step / 12)];
                var noisy = Noisy(image, random);
                detector.Sample(noisy, time, [new CropRegion()]);
                var areas = detector.Areas;
                reader.Lines = frameLines;
                reader.Crops.Clear();
                foreach (var area in areas)
                {
                    var crop = RegionCropper.Crop(noisy, area.Region);
                    reader.Crops.Add((area.Region, crop));
                    reader.Crops.Add((area.Region, crop.Scaled(2)));
                }
                await watcher.PassAsync(noisy, areas);
                report.AppendLine($"   t{time} {(detector.InMenu ? "menü " : "")}{string.Join(", ", areas.Select(area => $"{area.Id} {Fmt(area.Region)}"))}");
                if (step == 11) { settled = recorder.Events.Count; requestsAtSettle = translator.Requests; }
            }
            var file = Path.Combine(outDir, $"{name}{label}.json");
            await File.WriteAllTextAsync(file, "[" + string.Join(",\n", recorder.Events.Select(item =>
                $"{{\"event\":\"{item.Event}\",\"data\":{SubtitleServer.Json(item.Data)}}}")) + "]");
            report.AppendLine($"== {name}{label}: alanlar {string.Join(", ", detector.Areas.Select(area => $"{area.Id}{(area.Menu ? "(menü)" : "")} {Fmt(area.Region)}"))}");
            report.AppendLine($"   okuma {reader.Reads}, çeviri isteği {translator.Requests} (ilk oturuşta {requestsAtSettle}), olay {recorder.Events.Count} (ilk oturuşta {settled})");
            foreach (var (ev, data) in recorder.Events)
                report.AppendLine($"   {ev} {(data.TryGetValue("id", out var id) ? id : "")}: {(data.TryGetValue("text", out var text) ? ((string)text).Replace("\n", " ⏎ ") : "")}");
            report.AppendLine("   motora giden: " + string.Join(" | ", translator.Texts));
        }
        await File.WriteAllTextAsync(Path.Combine(outDir, name + ".txt"), report.ToString());
        output.WriteLine(report.ToString());
    }

    /// <summary>Aynı kare 10 kez (küçük gürültüyle); K3'te seçili satırı bir alta kaydırılmış ikinci kare.</summary>
    private static List<(string Label, List<(Frame Frame, IReadOnlyList<TextLine> Lines)> Sequence)> Variants(
        string name, Frame frame, IReadOnlyList<TextLine> lines)
    {
        var list = new List<(string, List<(Frame, IReadOnlyList<TextLine>)>)> { ("", [(frame, lines)]) };
        if (name == "K3" && ShiftSelection(frame, lines) is { } shifted) list.Add(("-kayma", [(frame, lines), (shifted, lines)]));
        if (WithoutMargin(frame) is { } clean) list.Add(("-kenarsiz", [(clean, lines)]));
        return list;
    }

    /// <summary>
    /// Ekran görüntüsünün sol kenarındaki beyaz şerit (yakalama artığı; oyun karesinde yok) yanındaki renkle doldurulur.
    /// Şerit yoksa null.
    /// </summary>
    private static Frame? WithoutMargin(Frame frame)
    {
        int Luma(int x, int y)
        {
            var p = y * frame.Stride + x * 4;
            return (299 * frame.Pixels[p + 2] + 587 * frame.Pixels[p + 1] + 114 * frame.Pixels[p]) / 1000;
        }
        var middle = frame.Height / 2;
        var margin = 0;
        while (margin < frame.Width / 20 && Luma(margin, middle) > 220) margin++;
        if (margin == 0 || margin >= frame.Width / 20) return null;
        var copy = new Frame((byte[])frame.Pixels.Clone(), frame.Width, frame.Height, frame.Stride);
        for (var y = 0; y < frame.Height; y++)
            for (var x = 0; x <= margin + 1; x++)
                Array.Copy(frame.Pixels, y * frame.Stride + (margin + 3) * 4, copy.Pixels, y * frame.Stride + x * 4, 4);
        return copy;
    }

    /// <summary>Açık zeminli (seçili) satır şeridi bir alttaki satırınkiyle yer değiştirir.</summary>
    private static Frame? ShiftSelection(Frame frame, IReadOnlyList<TextLine> lines)
    {
        var rows = lines.Where(line => line.Box!.Value.Left < 0.3).OrderBy(line => line.Box!.Value.Top).ToList();
        int Luma(TextBox box)
        {
            var x = (int)((box.Left - 0.004) * frame.Width);
            var y = (int)((box.Top + box.Bottom) / 2 * frame.Height);
            var p = Math.Clamp(y, 0, frame.Height - 1) * frame.Stride + Math.Clamp(x, 0, frame.Width - 1) * 4;
            return (frame.Pixels[p] + frame.Pixels[p + 1] + frame.Pixels[p + 2]) / 3;
        }
        var selected = rows.FindIndex(line => Luma(line.Box!.Value) > 150);
        if (selected < 0 || selected + 1 >= rows.Count) return null;
        var a = rows[selected].Box!.Value;
        var b = rows[selected + 1].Box!.Value;
        var pitch = (int)((b.Top - a.Top) * frame.Height);
        var top = (int)((a.Top - 0.25 * (a.Bottom - a.Top)) * frame.Height);
        var copy = new Frame((byte[])frame.Pixels.Clone(), frame.Width, frame.Height, frame.Stride);
        for (var y = top; y < top + pitch && y + pitch < frame.Height; y++)
        {
            var first = y * frame.Stride;
            var second = (y + pitch) * frame.Stride;
            Array.Copy(frame.Pixels, second, copy.Pixels, first, frame.Stride);
            Array.Copy(frame.Pixels, first, copy.Pixels, second, frame.Stride);
        }
        return copy;
    }

    private static Frame Noisy(Frame frame, Random random)
    {
        var copy = new Frame((byte[])frame.Pixels.Clone(), frame.Width, frame.Height, frame.Stride);
        for (var p = 0; p < copy.Pixels.Length; p += 4)
            for (var c = 0; c < 3; c++)
                copy.Pixels[p + c] = (byte)Math.Clamp(copy.Pixels[p + c] + random.Next(-2, 3), 0, 255);
        return copy;
    }

    private static string Fmt(CropRegion r) => $"[{r.Left:0.00}-{r.Right:0.00} x {r.Top:0.00}-{r.Bottom:0.00}]";

    private static List<TextLine> VisionLines(string path)
    {
        using var json = JsonDocument.Parse(File.ReadAllText(path));
        return [.. json.RootElement.GetProperty("lines").EnumerateArray().Select(line =>
        {
            var box = line.GetProperty("box");
            return new TextLine(line.GetProperty("text").GetString()!,
                new TextBox(Math.Max(0, box.GetProperty("left").GetDouble()), Math.Max(0, box.GetProperty("top").GetDouble()),
                            Math.Min(1, box.GetProperty("right").GetDouble()), Math.Min(1, box.GetProperty("bottom").GetDouble())),
                line.TryGetProperty("confidence", out var confidence) ? confidence.GetDouble() : null);
        })];
    }

    /// <summary>En küçük PNG okuyucu (8 bit RGB/RGBA, taramasız): BGRA kare.</summary>
    internal static class Png
    {
        public static Frame Load(string path)
        {
            var bytes = File.ReadAllBytes(path);
            int width = 0, height = 0, colorType = 0;
            using var data = new MemoryStream();
            for (var at = 8; at < bytes.Length;)
            {
                var length = (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3];
                var type = Encoding.ASCII.GetString(bytes, at + 4, 4);
                if (type == "IHDR")
                {
                    width = (bytes[at + 8] << 24) | (bytes[at + 9] << 16) | (bytes[at + 10] << 8) | bytes[at + 11];
                    height = (bytes[at + 12] << 24) | (bytes[at + 13] << 16) | (bytes[at + 14] << 8) | bytes[at + 15];
                    colorType = bytes[at + 17];
                }
                else if (type == "IDAT") data.Write(bytes, at + 8, length);
                else if (type == "IEND") break;
                at += 12 + length;
            }
            var channels = colorType == 6 ? 4 : 3;
            data.Position = 0;
            using var inflate = new ZLibStream(data, CompressionMode.Decompress);
            using var raw = new MemoryStream();
            inflate.CopyTo(raw);
            var source = raw.ToArray();
            var stride = width * channels;
            var previous = new byte[stride];
            var current = new byte[stride];
            var frame = Frame.Blank(width, height);
            for (var y = 0; y < height; y++)
            {
                var filter = source[y * (stride + 1)];
                Array.Copy(source, y * (stride + 1) + 1, current, 0, stride);
                for (var i = 0; i < stride; i++)
                {
                    int left = i >= channels ? current[i - channels] : 0, up = previous[i], corner = i >= channels ? previous[i - channels] : 0;
                    current[i] = (byte)(current[i] + filter switch
                    {
                        1 => left,
                        2 => up,
                        3 => (left + up) / 2,
                        4 => Paeth(left, up, corner),
                        _ => 0,
                    });
                }
                for (var x = 0; x < width; x++)
                {
                    var p = y * frame.Stride + x * 4;
                    frame.Pixels[p] = current[x * channels + 2];
                    frame.Pixels[p + 1] = current[x * channels + 1];
                    frame.Pixels[p + 2] = current[x * channels];
                    frame.Pixels[p + 3] = 255;
                }
                (previous, current) = (current, previous);
            }
            return frame;
        }

        private static int Paeth(int a, int b, int c)
        {
            int p = a + b - c, pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
            return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
        }
    }
}
