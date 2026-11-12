// SPDX-License-Identifier: AGPL-3.0-only

using System.IO;
using System.Runtime.InteropServices.WindowsRuntime;
using CouchSubs.Core;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace CouchSubs.App.Services;

/// <summary>
/// Windows'un cihaz üstü yazı tanıması. Oyun dilinin OCR paketi yoksa kullanıcının yüklü dillerinden
/// biri kullanılır (Latin alfabeli diller İngilizce altyazıyı da okuyabilir). Satırlar yukarıdan aşağı sıralanır.
/// </summary>
public sealed class WindowsOcrReader : ITextReader
{
    private readonly OcrEngine engine;

    private WindowsOcrReader(OcrEngine engine) => this.engine = engine;

    /// <summary>Hiçbir OCR dili yüklü değilse null.</summary>
    public static WindowsOcrReader? Create(string language)
    {
        var engine = OcrEngine.TryCreateFromLanguage(new Language(language))
                     ?? OcrEngine.TryCreateFromUserProfileLanguages();
        return engine is null ? null : new WindowsOcrReader(engine);
    }

    /// <summary>Oyun dilinin kendi OCR paketi yüklü mü (değilse ayarlarda eklenmesi önerilir).</summary>
    public static bool HasLanguage(string language) => OcrEngine.IsLanguageSupported(new Language(language));

    public string Read(Frame image) => Read(image, deep: true);

    public string Read(Frame image, bool deep) => string.Join(' ', ReadLines(image, deep).Lines.Select(line => line.Text));

    // Büyütülmüş yedek okumalarda (boş bölge) yalnız eski iki hazırlık denenir; işlemci yükü artmasın.
    public Reading ReadLines(Frame image, bool deep) =>
        deep ? ReadingFallback.FirstLines(image, frame => ReferenceEquals(frame, image) ? Recognize(frame) : Recognize(frame, allowChain: false))
             : Recognize(image);

    /// <summary>
    /// Kare hem olduğu gibi hem de yalnız beyaz yazısı bırakılarak okunur; daha sözcüğe benzeyen okuma seçilir.
    /// Parlak sahnelerde ikincisi, renkli altyazılarda birincisi kazanır.
    /// </summary>
    /// <summary>
    /// Paketteki satırın tamamı mı (oyun paketi; bkz. LiveServices). Verilirse kare birkaç ayrı hazırlıkla okunur ve
    /// paketteki bir satıra birebir denk gelen okuma seçilir.
    /// </summary>
    public Func<string, bool>? IsKnownLine { get; set; }

    /// <summary>Renkli sözcük süzgeci denensin mi (ölçüm için kapatılabilir).</summary>
    public static bool UseColorCandidate { get; set; } = true;
    /// <summary>
    /// Okumanın sözlükçe puanı (Windows'ta yazım denetimi; bkz. WindowsSpellCheck.Score). Verilirse paketsiz oyunlarda
    /// da kare bütün hazırlıklarla okunur ve en çok gerçek sözcük içeren okuma seçilir.
    /// </summary>
    public static Func<string, int>? DictionaryScore { get; set; }
    /// <summary>Ölçüm için: bir karenin bütün hazırlıklarla okunuşları (ad, metin).</summary>
    public static Action<IReadOnlyList<(string Name, string Text)>>? CandidatesObserved { get; set; }
    /// <summary>Bir karenin bütün hazırlıklarla okunuşları, satır kutularıyla.</summary>
    public static Action<IReadOnlyList<(string Name, Reading Reading)>>? CandidateReadingsObserved { get; set; }
    /// <summary>Otomatik parlaklık seviyesi (ölçümde resmî okumayla karşılaştırmak için kapatılabilir).</summary>
    public static bool UseAutoLevel { get; set; } = true;

    /// <summary>Art arda bu kadar okuma pakette bulunmazsa (paketsiz oyun) ek hazırlıklar ara sıra denenir.</summary>
    private const int MissesBeforeSparse = 30;
    private const int SparseEvery = 8;
    private int misses;
    private int sparseCounter;
    private readonly object engineGate = new();

    /// <summary>
    /// GTA V gibi oyunlarda altyazı beyaz yazı ve sağ-alta düşen koyu gölgedir; açık zeminde (ten, gömlek, kaldırım)
    /// Windows OCR harfleri zeminden ayıramaz. Aynı kare farklı hazırlıklarla okunur, paketteki bir satıra birebir denk
    /// gelen ilk okuma alınır (ölçüm: 244 gerçek karede doğru satır 95 → 196). Hiçbiri tutmazsa eski seçim (ham ya da
    /// beyaz, hangisi daha sözcüğe benziyorsa) aynen yapılır; paketsiz oyunlarda davranış değişmez.
    /// </summary>
    private Reading Recognize(Frame image) => Recognize(image, allowChain: true);

    /// <summary>
    /// Otomatik seviye: bölgenin en parlak %0,5'i beyaza çekilir. Karanlık ya da soluk görüntüde (HDR'den dönüştürülmüş
    /// video, karanlık sahne, geçiş efekti) beyaz altyazı ancak 120-180 parlaklıkta kalıyor, beyaz yazı süzgeçleri hiç
    /// çalışmıyordu. Yazı zaten beyazsa (en parlak kısım 235 ve üstü) görüntü değişmez.
    /// </summary>
    public static Frame AutoLevel(Frame image)
    {
        var hist = new int[256];
        for (var y = 0; y < image.Height; y++)
            for (var x = 0; x < image.Width; x++)
            {
                var i = (y * image.Stride) + (x * 4);
                hist[(image.Pixels[i + 2] * 3 + image.Pixels[i + 1] * 6 + image.Pixels[i]) / 10]++;
            }
        var limit = image.Width * image.Height * 0.005;
        int top = 255, count = 0;
        for (; top > 0; top--)
        {
            count += hist[top];
            if (count >= limit) break;
        }
        if (top >= 235 || top < 60) return image;
        var scale = 250.0 / top;
        var lookup = new byte[256];
        for (var v = 0; v < 256; v++) lookup[v] = (byte)Math.Min(255, v * scale);
        var result = new Frame(new byte[image.Width * image.Height * 4], image.Width, image.Height, image.Width * 4);
        for (var y = 0; y < image.Height; y++)
            for (var x = 0; x < image.Width; x++)
            {
                int i = (y * image.Stride) + (x * 4), o = (y * result.Stride) + (x * 4);
                result.Pixels[o] = lookup[image.Pixels[i]];
                result.Pixels[o + 1] = lookup[image.Pixels[i + 1]];
                result.Pixels[o + 2] = lookup[image.Pixels[i + 2]];
                result.Pixels[o + 3] = 255;
            }
        return result;
    }

    private Reading Recognize(Frame image, bool allowChain)
    {
        if (image.Width < 40 || image.Height < 40) return RecognizeOnce(image);
        if (UseAutoLevel) image = AutoLevel(image);
        var known = IsKnownLine;
        var score = DictionaryScore;
        // Sözlük puanı varsa (paketsiz oyunlar da) bütün hazırlıklar denenir; yalnız paket varsa paketsiz oyunda ara sıra.
        var full = allowChain && (score is not null
                                  || (known is not null && (misses < MissesBeforeSparse || Interlocked.Increment(ref sparseCounter) % SparseEvery == 0)));

        Reading? raw = null, whiteText = null;
        string winner = "";
        Reading? chosen = null;
        var tried = new List<(string Name, Reading Reading)>();
        if (full)
        {
            (string Name, Func<Frame, Frame?> Prepare)[] candidates =
            [
                ("shadow-s60", f => ShadowText(f, 5, 200, 60, 80)),
                ("shadow-r4", f => ShadowText(f, 4, 200, 45, 80)),
                ("white", f => TextImage.WhiteTextOnly(f)),
                ("shadow-gray", f => ShadowText(f, 3, 150, 45, 110)),
                // Görev yazılarındaki renkli sözcük ("Chase the yacht.": mavi "yacht") beyaz süzgeçte kayboluyordu.
                ("shadow-color", f => ShadowText(f, 5, 200, 60, 80, colored: true)),
                ("raw", _ => null),
            ];
            var anyText = false;
            foreach (var (name, prepare) in candidates.Where(c => UseColorCandidate || c.Name != "shadow-color"))
            {
                var reading = RecognizeOnce(prepare(image) ?? image);
                if (name == "white") whiteText = reading;
                if (name == "raw") raw = reading;
                tried.Add((name, reading));
                if (known is not null && chosen is null && Matches(reading, known))
                {
                    chosen = reading;
                    winner = name;
                    // Sözlük yoksa ilk eşleşmede durulur. Varsa geri kalan hazırlıklar da denenir: pakette "Go to" gibi
                    // kısa satırlar da var; renkli sözcüğü okuyan hazırlık satırı tamamlayabilir ("Go to Pacific Bluffs.").
                    if (score is null) break;
                }
                anyText |= reading.Text.Trim().Length >= 3;
                // İlk üç hazırlıkta hiç yazı yoksa bölge büyük olasılıkla boştur; geri kalanı denenmez.
                if (name == "white" && !anyText) break;
            }
        }
        CandidatesObserved?.Invoke(tried.Select(t => (t.Name, t.Reading.Text)).ToList());
        CandidateReadingsObserved?.Invoke(tried);
        if (chosen is not null && score is not null)
        {
            // Paketteki okumayı aynı sözlerle başlayıp daha çok gerçek sözcükle süren okuma tamamlar.
            var hitText = TextMatch.Normalize(chosen.Text);
            var hitScore = score(chosen.Text);
            foreach (var (name, reading) in tried)
            {
                var text = TextMatch.Normalize(reading.Text);
                if (text.Length > hitText.Length && text.StartsWith(hitText + " ", StringComparison.Ordinal) && score(reading.Text) > hitScore)
                {
                    chosen = reading;
                    winner = name + "+tamam";
                    hitScore = score(reading.Text);
                }
            }
        }
        if (chosen is null && score is not null && tried.Any(t => t.Reading.Text.Trim().Length >= 3))
        {
            // Paket yok ya da tutmadı: sözlükte en çok sözcüğü olan okuma (eşitlikte sıradaki ilk hazırlık).
            var best = tried[0];
            var bestScore = int.MinValue;
            foreach (var candidate in tried)
            {
                var value = candidate.Reading.Text.Trim().Length >= 3 ? score(candidate.Reading.Text) : int.MinValue;
                if (value > bestScore) (best, bestScore) = (candidate, value);
            }
            chosen = best.Reading;
            winner = "sozluk-" + best.Name;
            if (known is not null) misses++;
        }
        if (chosen is null)
        {
            raw ??= RecognizeOnce(image);
            whiteText ??= RecognizeOnce(TextImage.WhiteTextOnly(image));
            chosen = OcrNoise.Score(whiteText.Text) > OcrNoise.Score(raw.Text) ? whiteText : raw;
            winner = "eski-secim";
            if (full && chosen.Text.Trim().Length >= 3) misses++;
        }
        else if (!winner.StartsWith("sozluk", StringComparison.Ordinal))
        {
            misses = 0;
        }
        return chosen;
    }

    private static bool Matches(Reading reading, Func<string, bool> known)
    {
        if (reading.Lines.Count == 0) return false;
        try
        {
            if (reading.Lines.Count > 1 && known(string.Join(' ', reading.Lines.Select(line => line.Text)))) return true;
            return reading.Lines.Any(line => line.Text.Trim().Length > 2 && known(line.Text.Trim()));
        }
        catch { return false; }
    }

    /// <summary>
    /// <see cref="TextImage.WhiteTextOnly"/> gibi, ama koyu piksel (gölge) yalnız sağ-altta aranır: açık zeminde
    /// harflerin sol-üstündeki zemin yazı sanılıp harfler kara lekeye dönmez.
    /// </summary>
    public static Frame ShadowText(Frame image, int radius, int minBright, int maxSpread, int darkLuma, bool colored = false)
    {
        int width = image.Width, height = image.Height;
        var bright = new bool[width * height];
        var dark = new int[(width + 1) * (height + 1)];
        for (var y = 0; y < height; y++)
        {
            var rowSum = 0;
            for (var x = 0; x < width; x++)
            {
                var i = (y * image.Stride) + (x * 4);
                int b = image.Pixels[i], g = image.Pixels[i + 1], r = image.Pixels[i + 2];
                int min = Math.Min(r, Math.Min(g, b)), max = Math.Max(r, Math.Max(g, b));
                // colored: parlak ve doygun renkli harfler de (açık mavi, kırmızı, sarı) yazı sayılır.
                bright[(y * width) + x] = (min >= minBright && max - min <= maxSpread)
                                          || (colored && max >= 170 && max - min >= 60 && (r * 3 + g * 6 + b) / 10 >= 120);
                rowSum += (r * 3 + g * 6 + b) / 10 < darkLuma ? 1 : 0;
                dark[((y + 1) * (width + 1)) + x + 1] = dark[(y * (width + 1)) + x + 1] + rowSum;
            }
        }
        var result = new Frame(new byte[width * height * 4], width, height, width * 4);
        for (var y = 0; y < height; y++)
        {
            int top = y, bottom = Math.Min(height, y + radius + 1);
            for (var x = 0; x < width; x++)
            {
                var text = false;
                if (bright[(y * width) + x])
                {
                    int left = x, right = Math.Min(width, x + radius + 1);
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

    private Reading RecognizeOnce(Frame image)
    {
        // OCR motoru çok küçük ya da çok büyük görüntüyü reddeder.
        if (image.Width < 40 || image.Height < 40 || image.Width > OcrEngine.MaxImageDimension || image.Height > OcrEngine.MaxImageDimension)
            return Reading.Empty;
        using var bitmap = new SoftwareBitmap(BitmapPixelFormat.Bgra8, image.Width, image.Height, BitmapAlphaMode.Premultiplied);
        bitmap.CopyFromBuffer(image.Pixels.AsBuffer());
        // Bir OcrEngine aynı anda iki okuma yapamaz ("Another RecognizeAsync operation is already running");
        // ReadingFallback iki büyütülmüş okumayı paralel başlatıyordu, biri hata verip okuma boş dönüyordu.
        OcrResult result;
        lock (engineGate) result = engine.RecognizeAsync(bitmap).AsTask().GetAwaiter().GetResult();
        double width = image.Width, height = image.Height;
        var lines = result.Lines
            .SelectMany(line => Split(line, width, height))
            .OrderBy(line => line.Box?.Top ?? 0);
        return new Reading(lines);
    }

    /// <summary>
    /// Satırın kutusu sözcük kutularının birleşimidir; görüntünün kenarlarına oranla verilir. Windows aynı hizadaki
    /// uzak yazıları (soldaki menü, sağdaki gösterge) bazen tek satır sayar; aradaki boşluk bir sözcük boşluğu olamayacak
    /// kadar genişse satır orada ayrı satırlara bölünür (<see cref="Reading.IsSeparateText"/>).
    /// </summary>
    private static IEnumerable<TextLine> Split(OcrLine line, double width, double height)
    {
        var words = line.Words.ToList();
        if (words.Count == 0) yield break;
        var lineHeight = words.Max(word => word.BoundingRect.Height);
        var start = 0;
        for (var index = 1; index <= words.Count; index++)
        {
            var end = index == words.Count;
            if (!end && !Reading.IsSeparateText(words[index].BoundingRect.X - (words[index - 1].BoundingRect.X + words[index - 1].BoundingRect.Width), lineHeight, width))
                continue;
            var part = words.GetRange(start, index - start);
            TextBox? box = null;
            foreach (var word in part)
            {
                var r = word.BoundingRect;
                var wordBox = new TextBox(r.X / width, r.Y / height, (r.X + r.Width) / width, (r.Y + r.Height) / height);
                box = box?.Union(wordBox) ?? wordBox;
            }
            // Bölünmeyen satırın metni Windows'un verdiği gibi kalır (boşluksuz yazılan dillerde sözcükler birleşik).
            var text = start == 0 && end ? line.Text : string.Join(' ', part.Select(word => word.Text));
            yield return new TextLine(text.Trim(), box);
            start = index;
        }
    }
}
