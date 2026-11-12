// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>Çevirinin nereden geldiği.</summary>
public enum LineOrigin
{
    /// <summary>Oyun paketindeki hazır Türkçe (çeviri motoru çağrılmadı).</summary>
    Pack,
    /// <summary>Çeviri motoru (ya da onun önbelleği).</summary>
    Engine,
}

/// <summary>
/// TV'ye giden son altyazı satırının ölçümleri (ana ekrandaki "Canlı altyazı" kartının altındaki küçük satır). Hepsi
/// gerçek ölçümdür: yazı tanımanın süresi, çevirinin süresi ve satırın okunduğu karenin geldiği andan TV'ye
/// gönderildiği ana kadar geçen süre. Mac'teki CouchSubsCore/LineMetrics.swift ile aynı.
/// </summary>
/// <param name="OcrMs">Satırı okuyan yazı tanımanın süresi (ms); bilinmiyorsa null.</param>
/// <param name="TranslationMs">Çevirinin süresi (ms); paketten gelen satırda null.</param>
/// <param name="TotalMs">Satırın okunduğu karenin geldiği andan TV'ye gönderildiği ana kadar (ms).</param>
/// <param name="Confidence">Yazı tanımanın güveni (yüzde, 0–100); okuyucu vermiyorsa null (Windows'un yazı tanıması vermez).</param>
public sealed record LineMetrics(int? OcrMs, int? TranslationMs, int TotalMs, int? Confidence, LineOrigin Origin)
{
    /// <summary>
    /// Ölçüm anlarından (aynı milisaniye saatiyle) satırın ölçümleri. Saat geri gitmiş gibi görünen (eksi) süreler 0 olur.
    /// </summary>
    /// <param name="capturedAt">Satırın okunduğu karenin geldiği an.</param>
    /// <param name="ocrMs">O okumanın süresi.</param>
    /// <param name="translation">Çevirinin başladığı ve bittiği an (paketten gelen satırda null).</param>
    /// <param name="sentAt">Satırın TV'ye gönderildiği an.</param>
    /// <param name="confidence">Yazı tanımanın güveni (0–1).</param>
    public static LineMetrics Measure(long capturedAt, int? ocrMs, (long Started, long Finished)? translation, long sentAt,
        double? confidence, LineOrigin origin) => new(
        ocrMs is { } ocr ? Math.Max(0, ocr) : null,
        translation is { } t ? Clamp(t.Finished - t.Started) : null,
        Clamp(sentAt - capturedAt),
        confidence is { } c ? (int)Math.Round(Math.Clamp(c, 0, 1) * 100, MidpointRounding.AwayFromZero) : null,
        origin);

    private static int Clamp(long ms) => (int)Math.Clamp(ms, 0, int.MaxValue);

    /// <summary>
    /// Ekrandaki parçalar, sırayla: "OCR 42 ms", "Translation 310 ms" (paketse "Ready pack"), "Delay 520 ms",
    /// "Confidence 93%". Bilinmeyen değer yazılmaz.
    /// </summary>
    public IReadOnlyList<string> Parts(Localizer l)
    {
        var parts = new List<string>();
        if (OcrMs is { } ocr) parts.Add(l.Format("OCR %lld ms", ocr));
        if (Origin == LineOrigin.Pack) parts.Add(l["Ready pack"]);
        else if (TranslationMs is { } translation) parts.Add(l.Format("Translation %lld ms", translation));
        parts.Add(l.Format("Delay %lld ms", TotalMs));
        if (Confidence is { } confidence) parts.Add(l.Format("Confidence %lld%%", confidence));
        return parts;
    }

    /// <summary>Parçalar tek satırda.</summary>
    public string Summary(Localizer l) => string.Join(" · ", Parts(l));
}
