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
