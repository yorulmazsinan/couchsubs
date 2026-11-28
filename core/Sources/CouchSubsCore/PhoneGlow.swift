// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Açık telefonun ekran ışığı: karanlık sahnede telefonun ekranı kendi ışığıyla aydınlık kalır, kasası ve çevresi kararır.
/// #1443 (beta-108, Mac günlüğü): karanlık mekânda üst şeridin parlaklığı 2–10/255, ortanca parlaklık 3–9/255; sıkı arama
/// telefonu 30 sn'de 84 aramanın yalnız 27–72'sinde buluyor, kasanın izi (`PhonePrint`) düz ve koyu kasada tutmuyor
/// ("benzerlik %0"), telefon ~1,1 sn'de bir kapanıp açılıyordu; her kapanışta telefonun kutuları siliniyor, ekran yazısı ve
/// görev satırı telefonun yazılarını okuyordu. Telefon açıkken arama ve iz ıskalarsa son yerinde ekranın ışığına bakılır:
/// çevresi karanlık ve ekran hâlâ son gerçek gözlemdeki kadar aydınlıksa telefon yerinde sayılır (`holdMs`'e dek). Telefon
/// indirilince son yerde karanlık arka plan kalır, ışık tutmaz ve telefon her zamanki sürede kapanır. Windows
/// (PhoneGlow.cs) ve Android (PhoneGlow.kt) aynı örnekler ve eşikler.
enum PhoneGlow {
    /// Ekranın içi: telefonun ekseni boyunca (0: hoparlör yarığı, 1: alt çentik) ve eksene dik (boyun oranı) örnekler.
    static let screenAlong: [Double] = [0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85]
    static let screenAcross: [Double] = [-0.16, -0.08, 0, 0.08, 0.16]
    /// Telefonun iki yanı (kasanın dışı; kasa ~0,25 boyda biter).
    static let ringAlong: [Double] = [0.2, 0.35, 0.5, 0.65, 0.8]
    static let ringAcross: [Double] = [0.4, 0.5]
    /// Telefonun üstü (hoparlör yarığının üstünde, kasanın dışı).
    static let aboveAlong: [Double] = [-0.12, -0.18]
    static let aboveAcross: [Double] = [-0.15, 0, 0.15]
    /// Çevre karanlık: telefonun iki yanından koyu olanının ortanca tonu bundan az (0–255; karanlık sahne eşiği
    /// `GamePhoneGeometry.darkLevel` ile aynı). Günlükte telefonun gidip geldiği sahnede ortanca parlaklık 3–9/255.
    static let darkRing = 56.0
    /// Ekran çevreden en az bu kadar ton aydınlık olmalı.
    static let minGlow = 40.0
    /// Ekranın ortanca tonu son gerçek gözlemdekinden en çok bu oranda sapabilir (yazı kaydı, bildirim).
    static let screenShare = 0.4
    /// Işıkla tutma en çok bu kadar süre (ms; son gerçek gözlemden): sonra telefon her zamanki gibi kapanır. Günlükte
    /// telefon kapandıktan sonra yeniden bulunana dek görülmediği süre 2,2–5,9 sn (sekiz kapanış).
    static let holdMs = 6000

    /// Ekranın ve çevrenin ortanca tonları (0–255).
    struct Glow: Equatable {
        let screen: Double, ring: Double
    }

    /// `pose`'taki (görüntüye göre 0..1) telefonun ekran ışığı; `raw` 400×225 ızgaranın ham tonu (dört noktanın tonu × 256).
    static func measure(_ pose: GamePhoneGeometry.Pose, raw: (Int, Int) -> Int) -> Glow? {
        let topX = pose.topX * 400, topY = pose.topY * 225
        let axisX = (pose.bottomX - pose.topX) * 400, h = (pose.bottomY - pose.topY) * 225
        guard topX.isFinite, topY.isFinite, axisX.isFinite, h.isFinite, h > 20 else { return nil }
        func tone(_ t: Double, _ r: Double) -> Int {
            let x = Int((topX + t * axisX + r * h).rounded(.toNearestOrEven))
            let y = Int((topY + t * h - r * axisX).rounded(.toNearestOrEven))
            return raw(min(399, max(0, x)), min(224, max(0, y)))
        }
        let screen = screenAlong.flatMap { t in screenAcross.map { tone(t, $0) } }
        let left = ringAlong.flatMap { t in ringAcross.map { tone(t, -$0) } }
        let right = ringAlong.flatMap { t in ringAcross.map { tone(t, $0) } }
        let above = aboveAlong.flatMap { t in aboveAcross.map { tone(t, $0) } }
        return Glow(screen: median(screen), ring: max(median(left), median(right), median(above)))
    }

    /// Ortanca ton (ham tonlardan, 0–255; çift sayıda örnekte ortadaki ikisinin ortalaması).
    static func median(_ raw: [Int]) -> Double {
        let sorted = raw.sorted(), n = sorted.count
        guard n > 0 else { return 0 }
        let mid = n % 2 == 1 ? Double(sorted[n / 2]) : Double(sorted[n / 2 - 1] + sorted[n / 2]) / 2
        return mid / 1024
    }

    /// Karanlık sahnede ışıklı ekran: çevre koyu, ekran çevreden en az `minGlow` ton aydınlık.
    static func lit(_ glow: Glow) -> Bool { glow.ring < darkRing && glow.screen >= glow.ring + minGlow }

    /// Son gerçek gözlemin ışığı (`recorded`) son yerde hâlâ tutuyor mu.
    static func holds(_ recorded: Glow, _ current: Glow) -> Bool {
        lit(recorded) && lit(current) && abs(current.screen - recorded.screen) <= screenShare * recorded.screen
    }
}
