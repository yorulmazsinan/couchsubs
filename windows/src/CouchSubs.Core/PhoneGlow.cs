// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Açık telefonun ekran ışığı: karanlık sahnede telefonun ekranı kendi ışığıyla aydınlık kalır, kasası ve çevresi kararır.
/// #1443 (beta-108, Mac günlüğü): karanlık mekânda üst şeridin parlaklığı 2–10/255, ortanca parlaklık 3–9/255; sıkı arama
/// telefonu 30 sn'de 84 aramanın yalnız 27–72'sinde buluyor, kasanın izi (<see cref="PhonePrint"/>) düz ve koyu kasada
/// tutmuyor ("benzerlik %0"), telefon ~1,1 sn'de bir kapanıp açılıyordu; her kapanışta telefonun kutuları siliniyor, ekran
/// yazısı ve görev satırı telefonun yazılarını okuyordu. Telefon açıkken arama ve iz ıskalarsa son yerinde ekranın ışığına
/// bakılır: çevresi karanlık ve ekran hâlâ son gerçek gözlemdeki kadar aydınlıksa telefon yerinde sayılır
/// (<see cref="HoldMs"/>'e dek). Telefon indirilince son yerde karanlık arka plan kalır, ışık tutmaz ve telefon her zamanki
/// sürede kapanır. Mac/iPhone (PhoneGlow.swift) ve Android (PhoneGlow.kt) aynı örnekler ve eşikler.
/// </summary>
internal static class PhoneGlow
{
    /// <summary>Ekranın içi: telefonun ekseni boyunca (0: hoparlör yarığı, 1: alt çentik) ve eksene dik (boyun oranı) örnekler.</summary>
    internal static readonly double[] ScreenAlong = [0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85];
    internal static readonly double[] ScreenAcross = [-0.16, -0.08, 0, 0.08, 0.16];
    /// <summary>Telefonun iki yanı (kasanın dışı; kasa ~0,25 boyda biter).</summary>
    internal static readonly double[] RingAlong = [0.2, 0.35, 0.5, 0.65, 0.8];
    internal static readonly double[] RingAcross = [0.4, 0.5];
    /// <summary>Telefonun üstü (hoparlör yarığının üstünde, kasanın dışı).</summary>
    internal static readonly double[] AboveAlong = [-0.12, -0.18];
    internal static readonly double[] AboveAcross = [-0.15, 0, 0.15];
    /// <summary>
    /// Çevre karanlık: telefonun iki yanının ve üstünün en aydınlığının ortanca tonu bundan az (0–255; karanlık sahne eşiği
    /// <see cref="GamePhoneGeometry.DarkLevel"/> ile aynı). Günlükte telefonun gidip geldiği sahnede ortanca parlaklık 3–9/255.
    /// </summary>
    internal const double DarkRing = 56;
    /// <summary>Ekran çevreden en az bu kadar ton aydınlık olmalı.</summary>
    internal const double MinGlow = 40;
    /// <summary>Ekranın ortanca tonu son gerçek gözlemdekinden en çok bu oranda sapabilir (yazı kaydı, bildirim).</summary>
    internal const double ScreenShare = 0.4;
    /// <summary>
    /// Işıkla tutma en çok bu kadar süre (ms; son gerçek gözlemden): sonra telefon her zamanki gibi kapanır. Günlükte
    /// telefon kapandıktan sonra yeniden bulunana dek görülmediği süre 2,2–5,9 sn (sekiz kapanış).
    /// </summary>
    internal const long HoldMs = 6000;

    /// <summary>Ekranın ve çevrenin ortanca tonları (0–255).</summary>
    internal readonly record struct Glow(double Screen, double Ring);

    /// <summary>
    /// <paramref name="pose"/>'taki (görüntüye göre 0..1) telefonun ekran ışığı; <paramref name="raw"/> 400×225 ızgaranın
    /// ham tonu (dört noktanın tonu × 256), satır satır.
    /// </summary>
    internal static Glow? Measure(GamePhoneGeometry.Pose pose, int[] raw)
    {
        double topX = pose.TopX * 400, topY = pose.TopY * 225;
        double axisX = (pose.BottomX - pose.TopX) * 400, h = (pose.BottomY - pose.TopY) * 225;
        if (!double.IsFinite(topX) || !double.IsFinite(topY) || !double.IsFinite(axisX) || !double.IsFinite(h) || h <= 20) return null;
        int Tone(double t, double r)
        {
            var x = (int)Math.Round(topX + t * axisX + r * h);
            var y = (int)Math.Round(topY + t * h - r * axisX);
            return raw[Math.Clamp(y, 0, 224) * 400 + Math.Clamp(x, 0, 399)];
        }
        var screen = ScreenAlong.SelectMany(t => ScreenAcross.Select(r => Tone(t, r))).ToList();
        var left = RingAlong.SelectMany(t => RingAcross.Select(r => Tone(t, -r))).ToList();
        var right = RingAlong.SelectMany(t => RingAcross.Select(r => Tone(t, r))).ToList();
        var above = AboveAlong.SelectMany(t => AboveAcross.Select(r => Tone(t, r))).ToList();
        return new Glow(Median(screen), Math.Max(Median(left), Math.Max(Median(right), Median(above))));
    }

    /// <summary>Ortanca ton (ham tonlardan, 0–255; çift sayıda örnekte ortadaki ikisinin ortalaması).</summary>
    internal static double Median(List<int> raw)
    {
        if (raw.Count == 0) return 0;
        var sorted = raw.OrderBy(v => v).ToList();
        var n = sorted.Count;
        var mid = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0;
        return mid / 1024;
    }

    /// <summary>Karanlık sahnede ışıklı ekran: çevre koyu, ekran çevreden en az <see cref="MinGlow"/> ton aydınlık.</summary>
    internal static bool Lit(Glow glow) => glow.Ring < DarkRing && glow.Screen >= glow.Ring + MinGlow;

    /// <summary>Son gerçek gözlemin ışığı (<paramref name="recorded"/>) son yerde hâlâ tutuyor mu.</summary>
    internal static bool Holds(Glow recorded, Glow current) =>
        Lit(recorded) && Lit(current) && Math.Abs(current.Screen - recorded.Screen) <= ScreenShare * recorded.Screen;
}
