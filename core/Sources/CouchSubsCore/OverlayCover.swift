// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics

/// "Yazı kadar" zeminde bilgisayardaki altyazı penceresinin kutusu oyundaki altyazıyı örter: çeviri kısa kalınca oyunun
/// altyazısı kutunun yanlarından görünmesin (Windows: OverlayPlacement.CoverSize).
public enum OverlayCover {
    /// Kutunun oyundaki altyazıyı örterken her yana bıraktığı pay (1080 satırlık ekranda nokta).
    public static let margin: CGFloat = 8

    /// Kutunun en küçük dış boyu: altyazının karedeki kutusu ekran boyuyla çarpılır (oyun görüntüsü ekranı kaplıyor sayılır),
    /// her yana `margin` eklenir. Kutu yoksa, boşsa ya da altyazı olamayacak kadar yüksekse (karenin yarısından fazla) nil;
    /// kutu eskisi gibi yazı kadar kalır.
    public static func size(of box: TextBox?, screen: CGSize, scale: CGFloat) -> CGSize? {
        guard let box, scale.isFinite, scale > 0 else { return nil }
        let width = CGFloat(box.right - box.left) * screen.width
        let height = CGFloat(box.bottom - box.top) * screen.height
        guard width.isFinite, height.isFinite, width > 0, height > 0, box.bottom - box.top <= 0.5 else { return nil }
        let pad = 2 * margin * scale
        return CGSize(width: width + pad, height: height + pad)
    }

    /// Altyazı kutusunun zemin opaklığı (0-1). "Örtsün"ün güncel satırı "Zemin koyuluğu"ndan bağımsız tam opaktır: oyundaki
    /// altyazıyı kapatmak bu yerleşimin işi. Eskiden koyuluğu izliyordu; varsayılan %72'de ve kaydırıcı düşükken İngilizce satır
    /// Türkçenin altından görünüyordu (X, MertTurna19). Öbür yerleşimlerde ve önceki satırlarda koyuluk aynen geçerli (önceki
    /// satır %83'ü). TV (app.js ownBackground), OBS katmanı ve Windows (OverlayPlacement.BoxOpacity) aynı kural.
    public static func boxOpacity(background: Int, covering: Bool, current: Bool) -> Double {
        if covering && current { return 1 }
        return Double(max(0, min(100, background))) / 100 * (current ? 1 : 0.83)
    }
}

/// "Örtsün" yerleşiminde yazı boyu sabittir (TV ve OBS sayfası aynı kuralı uygular; Windows: CoverFontScale): her satır
/// kullanıcının seçtiği boyda, kutu çeviriye göre genişler. 3 satıra sığmayan çeviri küçülmez, daha çok satıra bölünür
/// (en çok 3 dengeli satır, pencere daha uzununu kendisi böler). X'te bildirildi (beta.89): eskiden böyle tek bir satır yazıyı %80'e indiriyor ve boy
/// ayarı değişene dek öyle bırakıyordu; yazı boyu satırdan satıra değişiyor, çeviri sıkışıyordu.
public struct CoverFontScale: Equatable, Sendable {
    public init() {}

    /// Satırın yazı boyu çarpanı: hep 1 (seçilen boy).
    public mutating func scale(for text: String, fontSize: Int) -> Double { 1 }
}
