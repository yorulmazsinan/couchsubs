// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Altyazı bölgesinin hazır seçimleri (Ayarlar › Altyazı alanı). Windows'taki CouchSubs.Core/AreaPreset.cs ile aynı.
public enum AreaPreset: String, Codable, CaseIterable, Sendable {
    /// Ekranın altı: oyunların çoğu altyazıyı orada gösterir (varsayılan bölge).
    case bottom
    /// Ekranın üstü.
    case top
    /// Bütün kare.
    case full
    /// Kullanıcının ayarladığı bölge.
    case custom

    /// Hazır seçimin bölgesi; `custom` için nil (kayıtlı bölge kullanılır).
    public var region: CropRegion? {
        switch self {
        case .bottom: CropRegion()
        case .top: CropRegion(top: 0.03, bottom: 0.38, left: 0.14, right: 0.86)
        case .full: CropRegion(top: 0, bottom: 1, left: 0, right: 1)
        case .custom: nil
        }
    }

    /// Bölge bir hazır seçimle aynıysa o, değilse `custom` (eski kayıtlarda seçim yoktur; bölgeden çıkarılır).
    public static func matching(_ region: CropRegion) -> AreaPreset {
        allCases.first { $0.region.map { $0.isClose(to: region) } == true } ?? .custom
    }
}

extension CropRegion {
    /// Bölgenin en küçük yüksekliği ve genişliği (kenara oranla).
    public static let minimumSize = 0.05

    /// Bölgenin üst kenarı ve yüksekliği, yüzde olarak (Özel bölgenin "Dikey konum" ve "Yükseklik" kaydırıcıları).
    public var verticalPercent: (position: Double, height: Double) {
        (top * 100, (bottom - top) * 100)
    }

    /// Üst kenarı `position`, yüksekliği `height` yüzde olan bölge; sola ve sağa dokunulmaz. Yükseklik en az %5'tir;
    /// bölge karenin dışına taşmaz (gerekirse yukarı kayar).
    public func withVertical(position: Double, height: Double) -> CropRegion {
        let height = min(1, max(Self.minimumSize, height / 100))
        let top = min(1 - height, max(0, position / 100))
        var region = self
        region.top = top
        region.bottom = top + height
        return region
    }

    /// Bölge yatayda `dx`, dikeyde `dy` kadar kaydırılır (kenara oranla); boyutu değişmez, karenin dışına taşmaz.
    public func moved(dx: Double, dy: Double) -> CropRegion {
        let width = right - left, height = bottom - top
        let left = min(1 - width, max(0, self.left + dx))
        let top = min(1 - height, max(0, self.top + dy))
        return CropRegion(top: top, bottom: top + height, left: left, right: left + width)
    }

    /// Sağ alt köşe `(right, bottom)` noktasına taşınır; bölge en az `minimumSize` kalır ve karenin dışına taşmaz.
    public func resized(right: Double, bottom: Double) -> CropRegion {
        CropRegion(top: top, bottom: min(1, max(top + Self.minimumSize, bottom)),
                   left: left, right: min(1, max(left + Self.minimumSize, right)))
    }

    /// İki bölge yuvarlama payı içinde aynı mı (kaydırıcılar ve kayıt küçük farklar bırakabilir).
    public func isClose(to other: CropRegion, tolerance: Double = 0.001) -> Bool {
        abs(top - other.top) <= tolerance && abs(bottom - other.bottom) <= tolerance
            && abs(left - other.left) <= tolerance && abs(right - other.right) <= tolerance
    }
}
