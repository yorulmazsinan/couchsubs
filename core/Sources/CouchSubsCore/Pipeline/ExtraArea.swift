// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Altyazı alanının yanında sürekli okunan ek alan (görev yazısı, telefon mesajı, bildirim). Ek alanlar ana altyazıdan
/// ayrı ve daha seyrek okunur (bkz. `RegionWatcher`); çevirileri TV'de kendi yerlerinde küçük kutuda görünür.
/// Windows'ta aynı işi ek bölgelerin "Sürekli oku" seçeneği yapar (CouchSubs.Core/RegionWatcher.cs).
public struct ExtraArea: Codable, Equatable, Identifiable, Sendable {
    /// En çok bu kadar ek alan tanımlanır (her biri saniyede bir okunur).
    public static let maxCount = 3

    /// TV'deki kutunun kimliği; değişmez.
    public var id: String
    /// Kullanıcının verdiği ad ("Görev", "Telefon").
    public var name: String
    public var region: CropRegion
    /// Kapalı alan okunmaz, ayarı kalır.
    public var enabled: Bool
    /// Ekran yazısı olarak kendiliğinden bulunmuş geçici alan (`ScreenTextDetector`): gürültü yazısı (sayaç, etiket)
    /// çevrilmez, yazısız ya da gürültülü okuma `RegionWatcher.onAutoRejected` ile bildirilir; okuma aralığı en çok
    /// 500 ms. Ayarlara yazılmaz.
    public var auto = false
    /// Otomatik alan ekrandaki bir menüde (`ScreenTextDetector.inMenu`): kısa etiketler de çevrilir.
    public var menu = false

    public init(id: String = UUID().uuidString, name: String, region: CropRegion, enabled: Bool = true, auto: Bool = false) {
        self.id = id
        self.name = name
        self.region = region
        self.enabled = enabled
        self.auto = auto
    }

    private enum CodingKeys: String, CodingKey { case id, name, region, enabled }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        region = try values.decodeIfPresent(CropRegion.self, forKey: .region) ?? ExtraAreaPreset.quest.region
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Ek alanın hazır seçimleri: oyunların çoğu bu yazıları ekranın köşelerinde gösterir.
public enum ExtraAreaPreset: String, CaseIterable, Sendable {
    /// Sağ üstteki görev yazısı.
    case quest
    /// Sol alttaki bildirim (eşya alındı, görev güncellendi).
    case notification
    /// Sağ alttaki telefon mesajı ya da e-posta.
    case phone

    public var region: CropRegion {
        switch self {
        case .quest: CropRegion(top: 0.03, bottom: 0.30, left: 0.66, right: 0.98)
        case .notification: CropRegion(top: 0.58, bottom: 0.88, left: 0.02, right: 0.30)
        case .phone: CropRegion(top: 0.50, bottom: 0.95, left: 0.72, right: 0.98)
        }
    }

    /// Bölge bir hazır seçimle aynıysa o.
    public static func matching(_ region: CropRegion) -> ExtraAreaPreset? {
        allCases.first { $0.region.isClose(to: region) }
    }
}

extension UserSettings {
    /// Okunacak ek alanlar (açık olanlar, en çok `ExtraArea.maxCount`). Altyazı alanı Tam ekranken hiçbiri okunmaz:
    /// ekranın tamamı zaten okunuyor, ek alanlar aynı yazıyı ikinci kez çevirirdi. Alanların açık/kapalı ayarı
    /// değişmez; başka bir alan seçilince eskisi gibi okunurlar (Windows: UserSettings.WatchedAreas, Android: watched).
    public var activeExtraAreas: [ExtraArea] {
        guard !extraAreasPausedByFullScreen else { return [] }
        return Array(extraAreas.filter(\.enabled).prefix(ExtraArea.maxCount))
    }

    /// Altyazı alanı Tam ekran: ek alanlar okunmuyor (ayarları korunur).
    public var extraAreasPausedByFullScreen: Bool { areaPreset == .full }

    /// Ek alan eklenebilir mi.
    public var canAddExtraArea: Bool { extraAreas.count < ExtraArea.maxCount }

    /// Hazır seçimle yeni ek alan ekler; sınır dolduysa bir şey yapmaz. Eklenen alanın kimliğini döner.
    @discardableResult
    public mutating func addExtraArea(_ preset: ExtraAreaPreset, name: String) -> String? {
        guard canAddExtraArea else { return nil }
        let area = ExtraArea(name: name, region: preset.region)
        extraAreas.append(area)
        return area.id
    }

    public mutating func removeExtraArea(id: String) {
        extraAreas.removeAll { $0.id == id }
    }

    /// Kimliği verilen ek alanı değiştirir (yoksa bir şey yapmaz).
    public mutating func updateExtraArea(id: String, _ change: (inout ExtraArea) -> Void) {
        guard let index = extraAreas.firstIndex(where: { $0.id == id }) else { return }
        change(&extraAreas[index])
    }
}
