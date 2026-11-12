// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

public enum StabilizerKind { None, Translate, Clear, Restore }

/// <summary>Okuma hattının bir kareye vereceği tepki.</summary>
public readonly record struct StabilizerAction(StabilizerKind Kind, string? Text = null)
{
    public static readonly StabilizerAction None = new(StabilizerKind.None);
    public static readonly StabilizerAction Clear = new(StabilizerKind.Clear);
    public static StabilizerAction Translate(string text) => new(StabilizerKind.Translate, text);
    /// <summary>Az önce kalkan satır geri geldi; çevirisi yeniden gösterilir, yeniden çevrilmez (metin: ilk gönderilen hali).</summary>
    public static StabilizerAction Restore(string text) => new(StabilizerKind.Restore, text);
}

public enum StabilizerNoteKind
{
    /// <summary>Gönderilen satırın daha kötü (daha az sözcük okuyan) yeniden okuması; yeni satır sayılmadı.</summary>
    WorseReread,
    /// <summary>Çöp gibi okunan satır (<see cref="OcrNoise.LooksGarbled"/>) yeterince kararlı kalmadan kalktı ya da değişti; hiç gönderilmedi.</summary>
    GarbledDropped,
}

/// <summary>Satırın gönderilmeden bırakıldığı durum (yalnız altyazı günlüğü için; kararları değiştirmez).</summary>
public readonly record struct StabilizerNote(StabilizerNoteKind Kind, string Text);

/// <summary>
/// Kare kare gelen OCR çıktısını izler; altyazı kararlı hale gelince çevrilmesini,
/// ekrandan kalkınca TV'den temizlenmesini ister. Aynı altyazıyı tekrar göndermez.
/// Kararlar okuma hızına değil saate bağlıdır (<paramref name="clock"/>: milisaniye; testlerde sahtesi verilir).
/// </summary>
/// <param name="cleanFastPathOnly">
/// Noktalamayla biten satır ilk karede gönderilir. Açıksa bu yalnız temiz okumada olur (<see cref="LooksClean"/>):
/// altyazı belirirken okunan bozuk kare ("f fe &amp; ie want it.") <paramref name="stableFrames"/> kare doğrulanmayı
/// bekler. Satır ilk okunan hâliyle gönderilir (çeviri ilk karede önceden başlatıldıysa aynı metin olsun diye).
/// Temiz satırın da beklemesi kısa görünen satırları hiç göstermiyordu.
/// </param>
public sealed class SubtitleStabilizer(double similarity = 0.85, int stableFrames = 2,
    int clearAfterMs = SubtitleStabilizer.ClearAfterMs, Func<long>? clock = null, bool cleanFastPathOnly = false)
{
    /// <summary>Bölge bu kadar boş kalırsa altyazı kalkmış sayılır; parlak arka planda kaçan birkaç okuma silmez.</summary>
    public const int ClearAfterMs = 800;
    /// <summary>Kalkan satır bu süre içinde geri gelirse aynı satırdır (okuma kaçmıştı); yeniden çevrilmez.</summary>
    public const int RestoreWithinMs = 1500;
    /// <summary>Çevirisi başarısız olan satır en erken bu kadar sonra yeniden denenir.</summary>
    public const int RetryAfterMs = 1000;
    /// <summary>
    /// Çöp gibi okunan satır (<see cref="OcrNoise.LooksGarbled"/>) ancak bu kadar süre aynı okununca gider. Altyazılar
    /// geçişte üst üste solarken yazı tanıma iki satırı karıştırıp birkaç kare aynı çöpü okuyabiliyordu ("- Nat) but, you
    /// knpw. shit, I m", GTA V, #26); süslü ama gerçekten öyle duran yazı yine çevrilir.
    /// </summary>
    public const int GarbledStableMs = 700;
    private const int HistorySize = 5;

    private readonly Func<long> now = clock ?? (() => Environment.TickCount64);

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

    private string candidate = "";
    private string candidateRaw = "";
    private int candidateCount;
    private long candidateSince;
    /// <summary>Ekrandaki (gönderilmiş) satır: sadeleştirilmiş satırlar alt alta, ve ilk okunduğu hali.</summary>
    private string sent = "";
    private string sentRaw = "";
    private long? emptySince;
    /// <summary>Son kalkan satırlar ve kalktıkları an.</summary>
    private readonly List<(string Rows, string Raw, long LeftAt)> history = [];
    /// <summary>Çevirisi başarısız olan satır ve en erken yeniden deneneceği an.</summary>
    private string forgotten = "";
    private long retryAt;
    /// <summary>Bekleyen (henüz gönderilmemiş) çöp gibi okunan aday; gönderilmeden kalkarsa günlüğe yazılır.</summary>
    private string garbledPending = "";

    /// <summary>Son <see cref="Feed"/> çağrısında bırakılan satır (günlük için); her çağrıda sıfırlanır.</summary>
    public StabilizerNote? Note { get; private set; }

    public StabilizerAction Feed(string rawText)
    {
        var time = now();
        var text = TextMatch.Normalize(rawText);
        Note = null;
        // 3 karakterden kısa okumalar (gürültü, tek simge) boş kare sayılır.
        if (text.Length < 3)
        {
            DropGarbled();
            candidate = "";
            candidateCount = 0;
            emptySince ??= time;
            if (sent.Length > 0 && time - emptySince >= clearAfterMs)
            {
                LeaveScreen(time);
                return StabilizerAction.Clear;
            }
            return StabilizerAction.None;
        }

        emptySince = null;
        if (TextMatch.IsSimilar(text, candidate, similarity))
        {
            candidateCount++;
        }
        else
        {
            DropGarbled();
            candidate = text;
            candidateRaw = rawText.Trim();
            candidateCount = 1;
            candidateSince = time;
        }
        // Daktilo efektinde metin büyürken aday değişir; tamamlanıp kararlı olunca gider.
        // Noktalamayla biten satır zaten tamamdır; hızlı konuşmada beklemeden ilk karede gider. Çöp gibi okunan satır
        // (altyazılar geçişte üst üste solarken karışan okuma) beklemeden gitmez; geçiş süresinden uzun kararlıysa gider.
        // cleanFastPathOnly (Linux, Tesseract): noktalamayla bitse bile çöp parçalı okuma ilk karede gitmez.
        var garbled = OcrNoise.LooksGarbled(rawText);
        var ready = garbled
            ? candidateCount >= stableFrames && time - candidateSince >= GarbledStableMs
            : candidateCount >= stableFrames || (EndsSentence(rawText) && (!cleanFastPathOnly || LooksClean(rawText)));
        // Gönderilenin gürültülü yeniden okuması yeni satır değildir; TV'de aynı cümle iki kez görünmesin.
        if (IsSame(text, sent)) return StabilizerAction.None;
        if (!ready)
        {
            if (garbled) garbledPending = rawText.Trim();
            return StabilizerAction.None;
        }
        garbledPending = "";
        // Aynı cümlenin bir iki sözcüğü başka okunmuş, daha iyi olmayan okuması da yeni satır değildir; çevrilseydi TV'de
        // aynı cümlenin iki üç çevirisi üst üste dururdu. Daha çok sözcük okuyan okuma yeniden çevrilir (TV yerine koyar).
        if (sentRaw.Length > 0 && TextMatch.IsWorseReread(rawText, sentRaw))
        {
            Note = new StabilizerNote(StabilizerNoteKind.WorseReread, rawText.Trim());
            return StabilizerAction.None;
        }

        // Az önce kalkan satır geri geldiyse okuma birkaç kare kaçmıştır: çevirisi yeniden gösterilir, yeniden çevrilmez.
        var index = history.FindLastIndex(h => time - h.LeftAt <= RestoreWithinMs && IsSame(text, h.Rows));
        if (index >= 0)
        {
            var back = history[index];
            history.RemoveAt(index);
            LeaveScreen(time);
            (sent, sentRaw) = (back.Rows, back.Raw);
            return StabilizerAction.Restore(back.Raw);
        }
        // Çevirisi az önce başarısız olan satır her karede yeniden istenmez.
        if (forgotten.Length > 0 && time < retryAt && IsSame(text, forgotten)) return StabilizerAction.None;

        LeaveScreen(time);
        forgotten = "";
        sentRaw = cleanFastPathOnly ? candidateRaw : rawText.Trim();
        sent = TextMatch.NormalizeRows(sentRaw);
        return StabilizerAction.Translate(sentRaw);
    }

    /// <summary>Bekleyen çöp aday gönderilmeden bırakıldı (kalktı ya da başka okumaya döndü): günlük için not edilir.</summary>
    private void DropGarbled()
    {
        if (garbledPending.Length == 0) return;
        Note = new StabilizerNote(StabilizerNoteKind.GarbledDropped, garbledPending);
        garbledPending = "";
    }

    /// <summary>Okuma, bu satırların (gürültülü) yeniden okuması mı; sonuna sözcük eklenmiş hali yenidir.</summary>
    private static bool IsSame(string text, string rows) => rows.Length > 0 && TextMatch.IsSameSubtitle(text, rows);

    /// <summary>Ekrandaki satırı geçmişe yazar (kalktı ya da yerine başkası geldi).</summary>
    private void LeaveScreen(long time)
    {
        if (sent.Length == 0) return;
        history.Add((sent, sentRaw, time));
        if (history.Count > HistorySize) history.RemoveAt(0);
        sent = "";
        sentRaw = "";
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

    /// <summary>
    /// Son gönderilen satırı unutur (ör. çevirisi başarısız oldu); satır ekranda kaldıkça yeniden kararlı sayılıp çevrilir,
    /// ama en erken <see cref="RetryAfterMs"/> sonra: kalıcı hatada (model eksik) her karede çevirmene gidilmez.
    /// </summary>
    public void ForgetSent()
    {
        if (sent.Length > 0) forgotten = sent;
        retryAt = now() + RetryAfterMs;
        sent = "";
        sentRaw = "";
        candidate = "";
        candidateCount = 0;
        garbledPending = "";
    }

    public StabilizerAction Reset()
    {
        candidate = "";
        candidateCount = 0;
        garbledPending = "";
        Note = null;
        emptySince = null;
        history.Clear();
        forgotten = "";
        if (sent.Length == 0) return StabilizerAction.None;
        sent = "";
        sentRaw = "";
        return StabilizerAction.Clear;
    }
}
