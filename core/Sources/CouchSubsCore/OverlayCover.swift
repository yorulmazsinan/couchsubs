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
}

/// "Örtsün" yerleşiminde yazı boyu kararlıdır (TV ve OBS sayfası aynı kuralı uygular; Windows: CoverFontScale). Kullanıcının
/// seçtiği boy kullanılır, kutu çeviriye göre genişler; yazı ancak 3 satıra sığmıyorsa bir kademe küçülür (seçilen boyun
/// %80'i) ve asla büyütülmez. Küçülen boy oturum boyunca (yazı boyu değişene dek) kalır: ardışık satırlarda boy bir büyük
/// bir küçük zıplamasın.
public struct CoverFontScale: Equatable, Sendable {
    /// Tek kademe: seçilen boyun %80'i. Bundan küçüğe inilmez.
    public static let step = 0.8
    public private(set) var shrunk = false
    private var fontSize: Int?

    public init() {}

    /// Satırın yazı boyu çarpanı (1 ya da `step`). Yazı boyu ayarı değişince kademe sıfırlanır. `limit`: satır başına karakter
    /// tabanı (bilgisayardaki pencereler: `SubtitleWrap.desktopMaxChars`).
    public mutating func scale(for text: String, fontSize: Int, maxChars limit: Int = SubtitleWrap.maxChars) -> Double {
        if self.fontSize != fontSize {
            self.fontSize = fontSize
            shrunk = false
        }
        if !text.contains("\n"), SubtitleWrap.fit(text, maxChars: limit).scale < 1 { shrunk = true }
        return shrunk ? Self.step : 1
    }
}
