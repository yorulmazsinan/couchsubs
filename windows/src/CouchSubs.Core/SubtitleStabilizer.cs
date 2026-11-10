// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

public enum StabilizerKind { None, Translate, Clear }

/// <summary>Okuma hattının bir kareye vereceği tepki.</summary>
public readonly record struct StabilizerAction(StabilizerKind Kind, string? Text = null)
{
    public static readonly StabilizerAction None = new(StabilizerKind.None);
    public static readonly StabilizerAction Clear = new(StabilizerKind.Clear);
    public static StabilizerAction Translate(string text) => new(StabilizerKind.Translate, text);
}

/// <summary>
/// Kare kare gelen OCR çıktısını izler; altyazı kararlı hale gelince çevrilmesini,
/// ekrandan kalkınca TV'den temizlenmesini ister. Aynı altyazıyı tekrar göndermez.
/// </summary>
/// <param name="emptyTimeToClear">
/// Verilirse bölge en az <see cref="MinEmptyFramesForTime"/> kare ve bu süre boş kalınca da temizlenir. Kare sayısı tek
/// başına kare hızına bağlıdır: saniyede 20 karede 6 kare 0,3 sn iken TV'den yakalamada (saniyede ~3 kare) 2 sn
/// ediyor ve çeviri TV'de oyundaki altyazıdan çok sonra kalkıyordu.
/// </param>
/// <param name="clock">Milisaniye saati (testlerde sahtesi verilir).</param>
/// <param name="cleanFastPathOnly">
/// Noktalamayla biten satır ilk karede gönderilir. Açıksa bu yalnız temiz okumada olur (<see cref="LooksClean"/>):
/// altyazı belirirken okunan bozuk kare ("f fe &amp; ie want it.") <paramref name="stableFrames"/> kare doğrulanmayı
/// bekler. Satır ilk okunan hâliyle gönderilir (çeviri ilk karede önceden başlatıldıysa aynı metin olsun diye).
/// Temiz satırın da beklemesi kısa görünen satırları hiç göstermiyordu.
/// </param>
public sealed class SubtitleStabilizer(double similarity = 0.85, int stableFrames = 2, int emptyFramesToClear = 2,
    TimeSpan? emptyTimeToClear = null, Func<long>? clock = null, bool cleanFastPathOnly = false)
{
    /// <summary>İngilizcede tek başına geçen kısa sözcükler; bunların dışındaki 1–2 harflik parçalar OCR çöpüdür.</summary>
    private static readonly HashSet<string> ShortWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "a", "i", "o", "an", "am", "as", "at", "be", "by", "do", "go", "ha", "he", "hi", "if", "in", "is", "it", "me", "mr",
        "ms", "mrs", "dr", "st", "my", "no", "of", "oh", "ok", "on", "or", "so", "to", "tv", "uh", "um", "up", "us", "we", "ya", "ye",
    };

    /// <summary>
    /// Okumada çöp parça yok mu: her parça (noktalama ayıklanınca) harf, rakam, kesme ve tireden oluşur; 1–2 harflik
    /// parçalar bilinen kısa sözcüklerdir. Yanlış "kirli" sayılan satır yalnız bir kare gecikir.
    /// </summary>
    public static bool LooksClean(string raw)
    {
        var tokens = raw.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0) return false;
        foreach (var token in tokens)
        {
            var word = token.Trim('.', ',', '!', '?', '…', ':', ';', '"', '\'', '“', '”', '‘', '’', '(', ')');
            if (word.Length == 0) return false;
            if (!word.All(c => char.IsLetterOrDigit(c) || c is '\'' or '’' or '-')) return false;
            if (word.Length <= 2 && word.All(char.IsLetter) && !ShortWords.Contains(word)) return false;
        }
        return true;
    }

    /// <summary>Süreyle temizlemede de en az bu kadar boş kare gerekir; tek bir hatalı okuma altyazıyı silmesin.</summary>
    public const int MinEmptyFramesForTime = 2;

    private readonly Func<long> now = clock ?? (() => Environment.TickCount64);
    private string candidate = "";
    private string candidateRaw = "";
    private int candidateCount;
    private string sent = "";
    private int emptyCount;
    private long emptySince;

    public StabilizerAction Feed(string rawText)
    {
        var text = TextMatch.Normalize(rawText);
        // 3 karakterden kısa okumalar (gürültü, tek simge) boş kare sayılır.
        if (text.Length < 3)
        {
            candidate = "";
            candidateCount = 0;
            emptyCount++;
            var time = now();
            if (emptyCount == 1) emptySince = time;
            var longEnough = emptyTimeToClear is { } wait && emptyCount >= MinEmptyFramesForTime &&
                             time - emptySince >= wait.TotalMilliseconds;
            if ((emptyCount >= emptyFramesToClear || longEnough) && sent.Length > 0)
            {
                sent = "";
                return StabilizerAction.Clear;
            }
            return StabilizerAction.None;
        }

        emptyCount = 0;
        if (TextMatch.IsSimilar(text, candidate, similarity))
        {
            candidateCount++;
        }
        else
        {
            candidate = text;
            candidateRaw = rawText.Trim();
            candidateCount = 1;
        }
        // Daktilo efektinde metin büyürken aday değişir; tamamlanıp kararlı olunca gider.
        // Noktalamayla biten satır zaten tamamdır; hızlı konuşmada beklemeden ilk karede gider.
        var ready = candidateCount == stableFrames ||
                    (candidateCount == 1 && EndsSentence(rawText) && (!cleanFastPathOnly || LooksClean(rawText)));
        // Gönderilenin gürültülü yeniden okuması yeni satır değildir; TV'de aynı cümle iki kez görünmesin.
        if (!ready || TextMatch.IsSimilar(text, sent, similarity) || TextMatch.IsSameSubtitle(text, sent)) return StabilizerAction.None;
        sent = text;
        return StabilizerAction.Translate(cleanFastPathOnly ? candidateRaw : rawText.Trim());
    }

    /// <summary>Satır nokta, ünlem, soru ya da üç noktayla bitiyor mu (kapanan tırnak ve parantezler yok sayılır).</summary>
    public static bool EndsSentence(string raw)
    {
        var text = raw.Trim().TrimEnd('"', '\'', '”', '’', '»', ')', ']');
        return text.Length > 0 && ".!?…".Contains(text[^1]);
    }

    /// <summary>Çeviri kaynağıyla neredeyse aynıysa metin zaten hedef dildedir (ör. konsolun Türkçe menüleri).</summary>
    public bool ShouldSend(string source, string translation) =>
        !TextMatch.IsSimilar(TextMatch.Normalize(source), TextMatch.Normalize(translation), 0.90);

    /// <summary>Son gönderilen satırı unutur (ör. çevirisi başarısız oldu); satır ekranda kaldıkça yeniden kararlı sayılıp çevrilir.</summary>
    public void ForgetSent()
    {
        sent = "";
        candidate = "";
        candidateCount = 0;
    }

    public StabilizerAction Reset()
    {
        candidate = "";
        candidateCount = 0;
        emptyCount = 0;
        if (sent.Length == 0) return StabilizerAction.None;
        sent = "";
        return StabilizerAction.Clear;
    }
}
