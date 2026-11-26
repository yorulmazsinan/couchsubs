// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Koyu ekranlı telefonun (koyu temalı uygulama, gece, kısılmış ekran) okunmadan önceki hazırlığı. Kullanıcı bildirimi (X,
/// beta.104): "telefonda parlaklık varsa çeviri oluyor karanlıksa olmuyor". Düzeltilmiş ekran olduğu gibi okunuyordu: koyu
/// zeminde açık ve soluk yazı (kısılmış ekranda yazı ile zemin arasında 40–60 ton) yazı tanımada sık kayboluyordu. Ekranın
/// ortanca tonu <see cref="DarkLevel"/>'dan azsa ve açık yazı varsa (en açık %1'in tonu ortancadan en az
/// <see cref="MinSpread"/> fazla) ekran gri tona çevrilir, zeminden yazıya gerilir ve ters çevrilir: yazı koyu, zemin açık
/// (aydınlık ekranın okunduğu biçim). Aydınlık ekran değişmez. Mac/iPhone (PhoneDarkScreen.swift) ve Android
/// (PhoneDarkScreen.kt) aynı kural; ortak deneme dosyası Fixtures/phone-dark.json.
/// </summary>
internal static class PhoneDarkScreen
{
    /// <summary>Ortanca tonu bundan az ekran koyu sayılır (0–255).</summary>
    internal const int DarkLevel = 96;
    /// <summary>En açık %1'in tonu ortancadan en az bu kadar fazla olmalı (açık yazı var).</summary>
    internal const int MinSpread = 40;

    /// <summary>
    /// Tonların dönüşüm tablosu (256 öğe); hazırlık gerekmiyorsa null. Alt sınır en koyu %2'nin, üst sınır en açık %1'in
    /// tonu; ton <c>255 - (ton - alt) × 255 / (üst - alt)</c> (0–255'e kırpılır).
    /// </summary>
    internal static byte[]? Mapping(ReadOnlySpan<int> counts, int total)
    {
        if (total <= 0) return null;
        int low = Percentile(counts, total, 2), median = Percentile(counts, total, 50), high = Percentile(counts, total, 99);
        if (median >= DarkLevel || high - median < MinSpread || high <= low) return null;
        var map = new byte[256];
        for (int tone = 0; tone < 256; tone++)
            map[tone] = (byte)(255 - Math.Min(255, Math.Max(0, tone - low) * 255 / (high - low)));
        return map;
    }

    private static int Percentile(ReadOnlySpan<int> counts, int total, int share)
    {
        long sum = 0;
        for (int tone = 0; tone < 256; tone++)
        {
            sum += counts[tone];
            if (sum * 100 >= (long)total * share) return tone;
        }
        return 255;
    }

    /// <summary>Düzeltilmiş ekranın (BGRA) tonu, Mac ve Android ile aynı ağırlıklarla.</summary>
    private static int Tone(byte[] p, int at) => (p[at] * 29 + p[at + 1] * 150 + p[at + 2] * 77) >> 8;

    /// <summary>Koyu ekranı yerinde gri, gerilmiş ve ters çevrilmiş yapar; ekran koyu değilse false (dokunulmaz).</summary>
    internal static bool Prepare(Frame flat)
    {
        Span<int> counts = stackalloc int[256];
        for (int y = 0; y < flat.Height; y++)
            for (int x = 0; x < flat.Width; x++)
                counts[Tone(flat.Pixels, y * flat.Stride + x * 4)]++;
        if (Mapping(counts, flat.Width * flat.Height) is not { } map) return false;
        for (int y = 0; y < flat.Height; y++)
            for (int x = 0; x < flat.Width; x++)
            {
                int at = y * flat.Stride + x * 4;
                byte value = map[Tone(flat.Pixels, at)];
                flat.Pixels[at] = flat.Pixels[at + 1] = flat.Pixels[at + 2] = value;
                flat.Pixels[at + 3] = 255;
            }
        return true;
    }
}
