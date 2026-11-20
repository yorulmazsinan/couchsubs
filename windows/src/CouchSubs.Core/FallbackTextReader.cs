// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Gelişmiş okuyucuyu (Windows'ta PP-OCRv6) yedek okuyucuyla (Windows'un yazı tanıması) saran okuyucu. Gelişmiş okuyucu
/// okurken hata verirse (ör. sürücü sıfırlanınca ya da uykudan dönünce DirectML'in "device removed" hatası) o kare yedekle
/// okunur. <see cref="Threshold"/> kez art arda hata olursa <c>onFallback</c> çağrılır (bozuk oturumlar bırakılır), bu okuyucunun
/// geri kalan ömründe yalnız yedek okur ve durum <see cref="SubtitleLog"/>'a yazılır. Arada başarılı okuma sayacı sıfırlar.
/// Hat yeniden kurulunca (çeviriyi durdurup başlatma, dil ya da motor değişimi) yeni okuyucu gelişmişi yeniden dener.
/// </summary>
public sealed class FallbackTextReader(ITextReader primary, ITextReader? fallback, Action? onFallback = null) : ITextReader
{
    /// <summary>Yedeğe kalıcı geçmek için art arda gereken okuma hatası.</summary>
    public const int Threshold = 3;

    private readonly object gate = new();
    private int failures;
    private bool fellBack;

    /// <summary>Gelişmiş okuyucu bırakıldı; okumalar yedekle yapılıyor.</summary>
    public bool FellBack { get { lock (gate) return fellBack; } }

    public string Read(Frame image) => ReadLines(image, deep: true).Text;

    public string Read(Frame image, bool deep) => ReadLines(image, deep).Text;

    public Reading ReadLines(Frame image, bool deep) => Run(reader => reader.ReadLines(image, deep));

    /// <summary>"Ekranı çevir" okuması da aynı yedekle (bkz. <see cref="ITextReader.ReadScreen"/>).</summary>
    public Reading ReadScreen(Frame image) => Run(reader => reader.ReadScreen(image));

    private Reading Run(Func<ITextReader, Reading> read)
    {
        if (FellBack) return Secondary(read);
        Reading reading;
        try
        {
            reading = read(primary);
        }
        catch (Exception error)
        {
            Failed(error);
            return Secondary(read);
        }
        lock (gate) if (!fellBack) failures = 0;
        return reading;
    }

    private Reading Secondary(Func<ITextReader, Reading> read) => fallback is null ? Reading.Empty : read(fallback);

    private void Failed(Exception error)
    {
        var reason = $"{error.GetType().Name}: {SubtitleLog.Excerpt(error.Message)}";
        bool switchNow;
        int count;
        lock (gate)
        {
            if (fellBack) return;
            count = ++failures;
            switchNow = count >= Threshold;
            if (switchNow) fellBack = true;
        }
        if (!switchNow)
        {
            SubtitleLog.Write($"gelişmiş yazı tanıma hata verdi ({count}/{Threshold}), kare yedekle okundu; {reason}");
            return;
        }
        SubtitleLog.Write(fallback is null
            ? $"gelişmiş yazı tanıma {Threshold} kez art arda hata verdi, bırakıldı; Windows'un yazı tanıması da yok (dil paketi eksik), okuma yapılamıyor; {reason}"
            : $"gelişmiş yazı tanıma {Threshold} kez art arda hata verdi, bırakıldı; bu oturumun geri kalanında Windows'un yazı tanıması okuyor; {reason}");
        try
        {
            onFallback?.Invoke();
        }
        catch (Exception release)
        {
            SubtitleLog.Write($"gelişmiş yazı tanıma bırakılırken hata: {release.GetType().Name}");
        }
    }
}
