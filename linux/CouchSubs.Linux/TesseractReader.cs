// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using CouchSubs.Core;

namespace CouchSubs.Linux;

/// <summary>
/// Linux'ta cihaz üstü yazı tanıma: Tesseract (Apache-2.0), sistemin <c>libtesseract</c> kütüphanesiyle.
/// Windows'taki <c>WindowsOcrReader</c>'ın karşılığıdır: kare hem yalnız beyaz yazısı bırakılarak hem olduğu gibi
/// okunur, daha sözcüğe benzeyen okuma seçilir; aynı hizadaki uzak yazılar ayrı satır olur.
/// </summary>
public sealed class TesseractReader : ITextReader, IDisposable
{
    /// <summary>Bu güvenin üstündeki sözcük "kesin okunmuş" sayılır (COUCHSUBS_OCR_STRONG).</summary>
    private static readonly float StrongConfidence = Setting("COUCHSUBS_OCR_STRONG", 75);
    /// <summary>Satırın başındaki ve sonundaki, bu güvenin altındaki parçalar atılır (COUCHSUBS_OCR_MIN_WORD).</summary>
    private static readonly float MinWordConfidence = Setting("COUCHSUBS_OCR_MIN_WORD", 60);
    private static readonly int MaxEngines = Math.Clamp(Environment.ProcessorCount, 2, 4);

    private readonly string tessLanguage;
    private readonly ConcurrentBag<nint> idle = [];
    /// <summary>Bir motor aynı anda tek görüntü okur; iki okuma aynı anda yapıldığı için birkaç motor tutulur.</summary>
    private readonly SemaphoreSlim engines = new(MaxEngines, MaxEngines);
    /// <summary>Son okumada renkli (beyaz olmayan) altyazı bulundu; ekranda kaldıkça her kare olduğu gibi de okunur.</summary>
    private bool colorMode;
    private bool disposed;

    private TesseractReader(string tessLanguage, nint first)
    {
        this.tessLanguage = tessLanguage;
        idle.Add(first);
    }

    private static float Setting(string name, float fallback) =>
        float.TryParse(Environment.GetEnvironmentVariable(name), CultureInfo.InvariantCulture, out var value) ? value : fallback;

    /// <summary>Oyun dilinin Tesseract adı (ISO 639-2).</summary>
    public static string TesseractName(string language) => language.ToLowerInvariant() switch
    {
        "en" => "eng",
        "ja" => "jpn",
        "de" => "deu",
        "fr" => "fra",
        "es" => "spa",
        "it" => "ita",
        "pt" => "por",
        "ru" => "rus",
        "ko" => "kor",
        "zh" => "chi_sim",
        var other => other,
    };

    /// <summary>Kütüphane ya da dil verisi yoksa null (ör. <c>apt install tesseract-ocr-eng</c> yapılmamış).</summary>
    public static TesseractReader? Create(string language)
    {
        var name = TesseractName(language);
        if (NewEngine(name) is { } engine) return new TesseractReader(name, engine);
        // Oyun dilinin verisi yoksa İngilizce veriyle okunur (Latin alfabeli diller çoğunlukla okunur).
        return name != "eng" && NewEngine("eng") is { } english ? new TesseractReader("eng", english) : null;
    }

    public static bool HasLanguage(string language)
    {
        if (NewEngine(TesseractName(language)) is not { } engine) return false;
        Tess.TessBaseAPIDelete(engine);
        return true;
    }

    private static nint? NewEngine(string name)
    {
        try
        {
            var engine = Tess.TessBaseAPICreate();
            if (engine == 0) return null;
            if (Tess.TessBaseAPIInit3(engine, null, name) != 0)
            {
                Tess.TessBaseAPIDelete(engine);
                return null;
            }
            // Altyazı bölgesi tek bir yazı bloğudur; sayfa düzeni çözümlemesi oyun görüntüsünde yanıltır.
            Tess.TessBaseAPISetPageSegMode(engine, Tess.PsmSingleBlock);
            Tess.TessBaseAPISetVariable(engine, "debug_file", "/dev/null");
            return engine;
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
        {
            return null;
        }
    }

    public string Read(Frame image) => Read(image, deep: true);

    public string Read(Frame image, bool deep) => string.Join(' ', ReadLines(image, deep).Lines.Select(line => line.Text));

    /// <summary>
    /// Kare iki biçimde okunabilir: yalnız beyaz yazısı bırakılarak (hızlı ve temiz; oyun altyazılarının çoğu) ve olduğu
    /// gibi (renkli altyazı ve renkli konuşmacı adı için). Tesseract oyun görüntüsünün tamamında yavaştır ve zeminden
    /// harf uydurur; bu yüzden olağan karede yalnız beyaz yazı okunur, bulunan yazının çevresi olduğu gibi de okunup
    /// daha sözcüğe benzeyen seçilir. Bölgenin tamamı ancak derin okumada (boş bölgede üç okumada bir) ya da renkli
    /// altyazı ekrandayken olduğu gibi okunur.
    /// </summary>
    public Reading ReadLines(Frame image, bool deep)
    {
        if (image.Width < 40 || image.Height < 40) return Reading.Empty;
        var white = ReadWhite(image);
        if (white.Lines.Count > 0)
        {
            colorMode = false;
            return Better(white, ReadAround(image, white));
        }
        if (!deep && !colorMode) return Reading.Empty;

        // Beyaz yazı yok: altyazı renkli olabilir. Bölgenin tamamını okumak pahalıdır; yazı bulunursa ekranda kaldıkça sürer.
        var raw = ReadRaw(image);
        colorMode = raw.Lines.Count > 0;
        if (colorMode || !deep) return raw;

        // Geniş bölgede "Go!" gibi kısa satırlar bulunamayabilir: ortadaki şerit (altyazılar ortalıdır) büyütülerek okunur.
        var stripWidth = (int)(image.Width * 0.4);
        var x = (image.Width - stripWidth) / 2;
        var strip = image.Crop(x, 0, stripWidth, image.Height).Scaled(2);
        return ReadWhite(strip).PlacedIn(new TextBox((double)x / image.Width, 0, (double)(x + stripWidth) / image.Width, 1));
    }

    private Reading ReadWhite(Frame image) => RecognizeOnce(Gray(TextImage.WhiteTextOnly(image), invert: false), image.Width, image.Height);

    private Reading ReadRaw(Frame image) => RecognizeOnce(Gray(image, invert: true), image.Width, image.Height);

    /// <summary>
    /// Bulunan beyaz yazının çevresini (satırın tamamı boyunca, üstten ve alttan birer satır payıyla) olduğu gibi okur:
    /// renkli konuşmacı adı ("ARTHUR:") ve açık zeminde beyaz süzgecin kaçırdığı sözcükler böyle yakalanır.
    /// </summary>
    private Reading ReadAround(Frame image, Reading found)
    {
        if (found.Box is not { } box) return Reading.Empty;
        var lineHeight = found.Lines.Where(line => line.Box is not null).Max(line => line.Box!.Value.Bottom - line.Box!.Value.Top);
        var top = Math.Max(0, (int)((box.Top - lineHeight) * image.Height));
        var bottom = Math.Min(image.Height, (int)Math.Ceiling((box.Bottom + lineHeight) * image.Height));
        if (bottom - top < 40) return Reading.Empty;
        var band = image.Crop(0, top, image.Width, bottom - top);
        return ReadRaw(band).PlacedIn(new TextBox(0, (double)top / image.Height, 1, (double)bottom / image.Height));
    }

    /// <summary>Daha sözcüğe benzeyen okuma; eşitlikte beyaz yazı (zeminden etkilenmediği için daha güvenilir).</summary>
    private static Reading Better(Reading whiteText, Reading raw) =>
        OcrNoise.Score(raw.Text) > OcrNoise.Score(whiteText.Text) ? raw : whiteText;

    /// <summary>
    /// Tek kanallı görüntü. Tesseract açık zeminde koyu yazıyı en iyi okur; oyun altyazısı ise koyu sahnede açık
    /// yazıdır, bu yüzden ham kare ters çevrilir.
    /// </summary>
    internal static byte[] Gray(Frame image, bool invert)
    {
        var gray = new byte[image.Width * image.Height];
        for (var y = 0; y < image.Height; y++)
        {
            var row = y * image.Stride;
            for (var x = 0; x < image.Width; x++)
            {
                var i = row + (x * 4);
                var value = ((image.Pixels[i + 2] * 3) + (image.Pixels[i + 1] * 6) + image.Pixels[i]) / 10;
                gray[(y * image.Width) + x] = (byte)(invert ? 255 - value : value);
            }
        }
        return gray;
    }

    /// <summary>
    /// Tanı: verilmişse Tesseract'a giden her görüntü bu klasöre PGM olarak, sözcükler de güvenleriyle yanına yazılır
    /// (<c>COUCHSUBS_OCR_DUMP</c>). Bir oyunda okuma bozuksa görüntünün Tesseract'a nasıl gittiği buradan görülür.
    /// </summary>
    internal static string? DumpFolder { get; set; } = Environment.GetEnvironmentVariable("COUCHSUBS_OCR_DUMP") is { Length: > 0 } folder ? folder : null;
    private static int dumpNumber;

    private unsafe Reading RecognizeOnce(byte[] gray, int width, int height)
    {
        if (disposed) return Reading.Empty;
        engines.Wait();
        nint engine = 0;
        try
        {
            if (!idle.TryTake(out engine)) engine = NewEngine(tessLanguage) ?? 0;
            if (engine == 0) return Reading.Empty;
            fixed (byte* pixels = gray) Tess.TessBaseAPISetImage(engine, pixels, width, height, 1, width);
            // Çözünürlük bilinmezse Tesseract her karede uyarı yazar; 1080p'deki altyazı boyu için 150 uygundur.
            Tess.TessBaseAPISetSourceResolution(engine, 150);
            if (Tess.TessBaseAPIRecognize(engine, 0) != 0) return Reading.Empty;
            var words = Words(engine);
            if (DumpFolder is { } folder) Dump(folder, gray, width, height, words);
            return new Reading(words.SelectMany(line => Split(Confident(line), width, height)).OrderBy(line => line.Box?.Top ?? 0));
        }
        finally
        {
            if (engine != 0)
            {
                Tess.TessBaseAPIClear(engine);
                idle.Add(engine);
            }
            engines.Release();
        }
    }

    internal readonly record struct Word(string Text, float Confidence, int Left, int Top, int Right, int Bottom)
    {
        public int Weight => Math.Max(1, Text.Count(char.IsLetterOrDigit));
    }

    /// <summary>Tesseract'ın bulduğu sözcükler, satır satır.</summary>
    private static List<List<Word>> Words(nint engine)
    {
        var lines = new List<List<Word>>();
        var iterator = Tess.TessBaseAPIGetIterator(engine);
        if (iterator == 0) return lines;
        try
        {
            var page = Tess.TessResultIteratorGetPageIterator(iterator);
            do
            {
                if (lines.Count == 0 || Tess.TessPageIteratorIsAtBeginningOf(page, Tess.LevelTextLine) != 0) lines.Add([]);
                var pointer = Tess.TessResultIteratorGetUTF8Text(iterator, Tess.LevelWord);
                if (pointer == 0) continue;
                var text = Marshal.PtrToStringUTF8(pointer)?.Trim() ?? "";
                Tess.TessDeleteText(pointer);
                if (text.Length == 0) continue;
                var confidence = Tess.TessResultIteratorConfidence(iterator, Tess.LevelWord);
                if (Tess.TessPageIteratorBoundingBox(page, Tess.LevelWord, out var left, out var top, out var right, out var bottom) == 0) continue;
                lines[^1].Add(new Word(FixCapitalI(text), confidence, left, top, right, bottom));
            }
            while (Tess.TessResultIteratorNext(iterator, Tess.LevelWord) != 0);
        }
        finally
        {
            Tess.TessResultIteratorDelete(iterator);
        }
        lines.RemoveAll(line => line.Count == 0);
        return lines;
    }

    /// <summary>
    /// Tesseract oyun görüntüsündeki dokulardan da harf uydurur ("~wuet", "ma dt io r"). Gerçek altyazıda sözcüklerin
    /// çoğunun güveni 90'ın üstündedir, uydurma satırlarda hiçbiri 75'i geçmez. Harflerinin yarısından azı kesin okunmuş
    /// satır tümüyle atılır. Kalan satırın başına ve sonuna yapışmış düşük güvenli parçalar ("|", "eC,") kırpılır;
    /// ortadaki sözcüklere dokunulmaz, çünkü Tesseract doğru okuduğu sözcüğe de bazen 0 güven verir.
    /// </summary>
    internal static List<Word> Confident(List<Word> line)
    {
        if (line.Count == 0) return line;
        var strong = line.Where(word => word.Confidence >= StrongConfidence).Sum(word => word.Weight);
        if (strong * 2 < line.Sum(word => word.Weight) || line.Sum(word => word.Text.Count(char.IsLetterOrDigit)) < 2) return [];
        var first = line.FindIndex(word => word.Confidence >= MinWordConfidence);
        var last = line.FindLastIndex(word => word.Confidence >= MinWordConfidence);
        return first < 0 ? [] : line.GetRange(first, last - first + 1);
    }

    /// <summary>Tesseract tek başına duran büyük "I"yı sık sık dik çizgi okur ("| told you", "|'m").</summary>
    internal static string FixCapitalI(string word) =>
        word.Contains('|') && word.All(c => c == '|' || char.IsLetter(c) || c is '\'' or '’' or '.' or ',' or '!' or '?') ? word.Replace('|', 'I') : word;

    /// <summary>
    /// Satırın kutusu sözcük kutularının birleşimidir; görüntünün kenarlarına oranla verilir. Aynı hizadaki uzak yazılar
    /// (soldaki menü, sağdaki gösterge) tek satır sayılabilir; aradaki boşluk bir sözcük boşluğu olamayacak kadar
    /// genişse satır orada bölünür (<see cref="Reading.IsSeparateText"/>).
    /// </summary>
    private static IEnumerable<TextLine> Split(List<Word> words, double width, double height)
    {
        if (words.Count == 0) yield break;
        var lineHeight = words.Max(word => word.Bottom - word.Top);
        var start = 0;
        for (var index = 1; index <= words.Count; index++)
        {
            var end = index == words.Count;
            if (!end && !Reading.IsSeparateText(words[index].Left - words[index - 1].Right, lineHeight, width)) continue;
            var part = words.GetRange(start, index - start);
            TextBox? box = null;
            foreach (var word in part)
            {
                var wordBox = new TextBox(word.Left / width, word.Top / height, word.Right / width, word.Bottom / height);
                box = box?.Union(wordBox) ?? wordBox;
            }
            // Tesseract'ın kutuları harflere sıkı oturur; satır yüksekliği (çıkıntılı harflerle) biraz daha fazladır.
            // Alt alta iki satırın aynı altyazı bloğu sayılması (Reading.SubtitleBlock) bu yüksekliğe göre yapılır.
            if (box is { } tight)
            {
                var margin = (tight.Bottom - tight.Top) * 0.2;
                box = tight with { Top = Math.Max(0, tight.Top - margin), Bottom = Math.Min(1, tight.Bottom + margin) };
            }
            yield return new TextLine(string.Join(' ', part.Select(word => word.Text)), box);
            start = index;
        }
    }

    private static void Dump(string folder, byte[] gray, int width, int height, List<List<Word>> lines)
    {
        try
        {
            Directory.CreateDirectory(folder);
            var name = Path.Combine(folder, $"ocr-{Interlocked.Increment(ref dumpNumber):D4}");
            using (var file = File.Create(name + ".pgm"))
            {
                file.Write(System.Text.Encoding.ASCII.GetBytes($"P5\n{width} {height}\n255\n"));
                file.Write(gray);
            }
            File.WriteAllLines(name + ".txt", lines.Select(line =>
                $"{(Confident(line).Count > 0 ? "+" : "-")} " + string.Join(' ', line.Select(word => $"{word.Text}[{word.Confidence:0}]"))));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Tanı dökümü yazılamasa da okuma sürer.
        }
    }

    public void Dispose()
    {
        disposed = true;
        while (idle.TryTake(out var engine)) Tess.TessBaseAPIDelete(engine);
    }
}

/// <summary>libtesseract'in C arayüzü (tesseract/capi.h); 4.x ve 5.x'te aynıdır.</summary>
internal static unsafe partial class Tess
{
    private const string Library = "tesseract";

    internal const int PsmSingleBlock = 6;
    internal const int LevelTextLine = 2;
    internal const int LevelWord = 3;

    static Tess() => NativeLibrary.SetDllImportResolver(typeof(Tess).Assembly, Resolve);

    /// <summary>Dağıtımlar kütüphaneyi sürüm numarasıyla kurar (Ubuntu 24.04: .so.5, 22.04: .so.4).</summary>
    private static nint Resolve(string name, Assembly assembly, DllImportSearchPath? path)
    {
        if (name != Library) return 0;
        foreach (var candidate in new[] { "libtesseract.so.5", "libtesseract.so.4", "libtesseract.so", "libtesseract.dylib", "tesseract" })
            if (NativeLibrary.TryLoad(candidate, assembly, path, out var handle)) return handle;
        return 0;
    }

    [LibraryImport(Library)] internal static partial nint TessBaseAPICreate();
    [LibraryImport(Library)] internal static partial void TessBaseAPIDelete(nint handle);
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)] internal static partial int TessBaseAPIInit3(nint handle, string? dataPath, string language);
    [LibraryImport(Library)] internal static partial void TessBaseAPISetPageSegMode(nint handle, int mode);
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)] internal static partial int TessBaseAPISetVariable(nint handle, string name, string value);
    [LibraryImport(Library)] internal static partial void TessBaseAPISetImage(nint handle, byte* data, int width, int height, int bytesPerPixel, int bytesPerLine);
    [LibraryImport(Library)] internal static partial void TessBaseAPISetSourceResolution(nint handle, int ppi);
    [LibraryImport(Library)] internal static partial int TessBaseAPIRecognize(nint handle, nint monitor);
    [LibraryImport(Library)] internal static partial void TessBaseAPIClear(nint handle);
    [LibraryImport(Library)] internal static partial nint TessBaseAPIGetIterator(nint handle);
    [LibraryImport(Library)] internal static partial void TessResultIteratorDelete(nint iterator);
    [LibraryImport(Library)] internal static partial nint TessResultIteratorGetPageIterator(nint iterator);
    [LibraryImport(Library)] internal static partial int TessResultIteratorNext(nint iterator, int level);
    [LibraryImport(Library)] internal static partial nint TessResultIteratorGetUTF8Text(nint iterator, int level);
    [LibraryImport(Library)] internal static partial float TessResultIteratorConfidence(nint iterator, int level);
    [LibraryImport(Library)] internal static partial int TessPageIteratorBoundingBox(nint iterator, int level, out int left, out int top, out int right, out int bottom);
    [LibraryImport(Library)] internal static partial int TessPageIteratorIsAtBeginningOf(nint iterator, int level);
    [LibraryImport(Library)] internal static partial void TessDeleteText(nint text);
}
