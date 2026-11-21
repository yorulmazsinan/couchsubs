// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics

/// "Yazı boyu oyundaki altyazı kadar": bilgisayardaki altyazı penceresinde yazı boyu oyunun kendi altyazısından alınır
/// (Windows: OverlayPlacement.GameTextSize).
public enum OverlayTextSize {
    /// Okunan satır yüksekliğinden yazı boyuna geçiş (TV uygulamasının ekran yazısında kullandığı oran).
    public static let gameTextRatio: CGFloat = 0.95

    /// Son altyazı kutularının yüksekliklerinin (kareye oranla) ortancası; altyazıların çoğu tek satır olduğundan ortanca bir
    /// satırın yüksekliğidir. Ekran yüksekliğiyle çarpılıp `gameTextRatio` ile yazı boyuna çevrilir ve seçilen boyun
    /// (`manual`) %70–150'si arasında tutulur. Ölçüm yoksa seçilen boy.
    public static func size(boxHeights: [Double], screenHeight: CGFloat, manual: CGFloat) -> CGFloat {
        guard !boxHeights.isEmpty, screenHeight.isFinite, screenHeight > 0, manual > 0 else { return manual }
        let sorted = boxHeights.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        return min(manual * 1.5, max(manual * 0.7, gameTextRatio * CGFloat(median) * screenHeight))
    }

    /// Pencere yüksekliğinin hesaplandığı yazı boyu: oyundaki kadar açıkken yazı seçilenin %150'sine kadar büyüyebilir.
    public static func windowFontSize(_ style: SubtitleStyle) -> Int {
        style.autoTextSize ? Int((Double(style.fontSize) * 1.5).rounded(.up)) : style.fontSize
    }
}
