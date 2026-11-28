// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Açık telefonun izi: kasanın üst (hoparlör yarığı, kamera, kasa kenarı) ve alt (alt çentik, çene) şeridinden örnekler.
/// X'te 3+ kullanıcı (beta-107): GTA 6 telefonu gece, kapalı ya da karanlık sahnede bir kez çevrilip kayboluyor, bir daha
/// gelmiyordu. Sıkı arama karanlıkta telefonu ara sıra buluyor (günlük: parlaklık 7–60/255, "hoparlör yarığı yok"), açılan
/// telefon iki ıskada kapanıyor, yeniden açılış yine üç gözlem bekliyordu. Telefon açıkken sıkı arama ve gevşek doğrulama
/// ıskalarsa son yerin çevresinde iz karşılaştırılır (normalleştirilmiş çapraz ilinti: parlaklıktan, karşıtlıktan ve gamadan
/// bağımsız): iz tutuyorsa telefon yerinde sayılır, okuma sürer. Telefon indirilince son yerde artık arka plan vardır, iz
/// tutmaz ve telefon her zamanki sürede kapanır. Mac/iPhone (PhonePrint.swift) ve Android (PhonePrint.kt) aynı örnekler ve
/// eşikler.
/// </summary>
internal static class PhonePrint
{
    /// <summary>Telefonun ekseni boyunca (0: hoparlör yarığı, 1: alt çentik; boy oranı) örnek satırları.</summary>
    internal static readonly double[] Along = [-0.045, -0.02, 0, 0.02, 0.04, 0.96, 0.98, 1.0, 1.02, 1.045];
    /// <summary>Eksene dik (boyun oranı) örnek sütunları: kasanın içinde, -0,26 … 0,26.</summary>
    internal static readonly double[] Across = Enumerable.Range(0, 13).Select(i => -0.26 + i * 0.52 / 12).ToArray();
    /// <summary>İz son yerin bu kadar çevresinde aranır (400×225 ızgarada, her yönde): 330 ms'de el titremesi.</summary>
    internal const int Reach = 4;
    /// <summary>İz bu benzerlikten (normalleştirilmiş çapraz ilinti, -1…1) az değilse telefon yerinde sayılır.</summary>
    internal const double HoldSimilarity = 0.8;
    /// <summary>İzdeki örneklerin en az sapması (ham ton; 1024 = 1 ton): düz, simsiyah ya da tek renk yer iz sayılmaz.</summary>
    internal const double MinSpread = 2048;
    /// <summary>Güncel izin sapması kayıtlı izinkinin bu oranından az olmamalı (çok karardı, telefon gitti).</summary>
    internal const double MinSpreadRatio = 0.08;

    /// <summary>
    /// <paramref name="pose"/>'taki (görüntüye göre 0..1) telefonun izi, <paramref name="dx"/>/<paramref name="dy"/> ızgara
    /// noktası kaydırılmış; <paramref name="raw"/> 400×225 ızgaranın ham tonu (dört noktanın tonu × 256), satır satır.
    /// </summary>
    internal static int[]? Samples(GamePhoneGeometry.Pose pose, int dx, int dy, int[] raw)
    {
        double topX = pose.TopX * 400, topY = pose.TopY * 225;
        double axisX = (pose.BottomX - pose.TopX) * 400, h = (pose.BottomY - pose.TopY) * 225;
        if (!double.IsFinite(topX) || !double.IsFinite(topY) || !double.IsFinite(axisX) || !double.IsFinite(h) || h <= 20) return null;
        var output = new int[Along.Length * Across.Length];
        var i = 0;
        foreach (var t in Along)
            foreach (var r in Across)
            {
                var x = (int)Math.Round(topX + t * axisX + r * h) + dx;
                var y = (int)Math.Round(topY + t * h - r * axisX) + dy;
                output[i++] = raw[Math.Clamp(y, 0, 224) * 400 + Math.Clamp(x, 0, 399)];
            }
        return output;
    }

    /// <summary>
    /// İki izin benzerliği: üst ve alt şeridin (izin iki yarısı) normalleştirilmiş çapraz ilintisinin (-1…1) küçüğü. Tek
    /// şerit yetmez: telefonsuz karede geniş bir parlaklık geçişi (koyu üst, açık alt) bütün izle %82 benzeşiyordu; hoparlör
    /// yarığı ve kamera üstte, alt çentik altta aynı anda tutmalı. Şerit düzse (<see cref="MinSpread"/>) ya da güncel şerit
    /// kayıtlı şeritten çok sönükse (<see cref="MinSpreadRatio"/>) 0.
    /// </summary>
    internal static double Similarity(int[] print, int[] current)
    {
        if (print.Length != current.Length || print.Length < 2) return 0;
        var half = print.Length / 2;
        return Math.Min(Strip(print, current, 0, half), Strip(print, current, half, print.Length));
    }

    /// <summary>Tek şeridin (<paramref name="from"/>, <paramref name="to"/>) normalleştirilmiş çapraz ilintisi; düz ya da çok sönükse 0.</summary>
    private static double Strip(int[] print, int[] current, int from, int to)
    {
        double n = to - from;
        long ta = 0, tb = 0;
        for (var i = from; i < to; i++)
        {
            ta += print[i];
            tb += current[i];
        }
        double ma = ta / n, mb = tb / n;
        double sab = 0, saa = 0, sbb = 0;
        for (var i = from; i < to; i++)
        {
            double a = print[i] - ma, b = current[i] - mb;
            sab += a * b;
            saa += a * a;
            sbb += b * b;
        }
        double sa = Math.Sqrt(saa / n), sb = Math.Sqrt(sbb / n);
        if (sa < MinSpread || sb < MinSpread || sb < sa * MinSpreadRatio) return 0;
        return sab / Math.Sqrt(saa * sbb);
    }

    /// <summary>İzin son yerin <see cref="Reach"/> çevresindeki en iyi eşleşmesi: kayma (ızgara noktası) ve benzerlik.</summary>
    internal static (int Dx, int Dy, double Similarity) Match(int[] print, GamePhoneGeometry.Pose pose, int[] raw)
    {
        (int Dx, int Dy, double Similarity) best = (0, 0, -1);
        for (var dy = -Reach; dy <= Reach; dy++)
            for (var dx = -Reach; dx <= Reach; dx++)
            {
                if (Samples(pose, dx, dy, raw) is not { } current) return (0, 0, 0);
                var s = Similarity(print, current);
                // Eşitlikte ilk bulunan (her platformda aynı tarama sırası).
                if (s > best.Similarity + 1e-9) best = (dx, dy, s);
            }
        return (best.Dx, best.Dy, Math.Max(0, best.Similarity));
    }
}
