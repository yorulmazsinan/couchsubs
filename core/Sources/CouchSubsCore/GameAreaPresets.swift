// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Oyuna göre hazır ek alanlar: tabloda satırı olan oyun oynanırken o oyunun ipucu kutusu ve mesajları, kullanıcı ek
/// alan tanımlamadan sürekli okunup yerinde çevrilir (ayar: `UserSettings.gameAreaPresets`). Alanlar çalışma anında
/// hesaplanır, kayıtlı ayarlara yazılmaz; kullanıcının kendi etkin ek alanı ya da o oyun için etkin alan profili varsa
/// hiç eklenmez. Yeni oyun tabloya bir satırdır. Windows (GameAreaPresets.cs) ve Android (GameAreaPresets.kt) aynı
/// tabloyu ve kuralları uygular.
///
/// GTA 6 bölgeleri GTA V'in arayüz düzenine göre biraz geniş tutuldu (oransal: 1080p ve 4K'da, 16:9'da aynı); gerçek
/// GTA 6 ekranında doğrulanmadı. Kullanıcı kendi ek alanını ekleyerek değiştirebilir.
public enum GameAreaPresets {
    public static let helpId = "preset-help"
    public static let phoneId = "preset-phone"

    /// `GameName.key` → o oyunun hazır alanları.
    static let table: [String: [ExtraArea]] = [
        "gta 6": [
            // Sol üstteki ipucu/yardım kutusu.
            ExtraArea(id: helpId, name: "Help", region: CropRegion(top: 0.02, bottom: 0.28, left: 0.01, right: 0.36)),
            // Sağ alttaki telefon mesajı kartı.
            ExtraArea(id: phoneId, name: "Messages", region: CropRegion(top: 0.45, bottom: 0.80, left: 0.72, right: 0.99)),
        ],
    ]

    /// Oyunun hazır alanları; tabloda yoksa boş.
    public static func areas(_ game: String?) -> [ExtraArea] {
        guard let game else { return [] }
        return table[GameName.key(game)] ?? []
    }
}

extension UserSettings {
    /// Sürekli okunacak ek alanlar: kullanıcının etkin ek alanları; hiç yoksa ve ayar açıksa oynanan oyunun hazır
    /// alanları (`GameAreaPresets`). Tam ekranda hiçbiri. Oyunun etkin bir alan profili varsa hazır alan eklenmez.
    /// `phoneOpen`: oyun telefonu açık ve ayrıca okunuyor; telefon mesajı alanı o sırada okunmaz.
    public func watchedExtraAreas(game: String?, phoneOpen: Bool = false) -> [ExtraArea] {
        let own = activeExtraAreas
        guard own.isEmpty, gameAreaPresets, !extraAreasPausedByFullScreen, let game else { return own }
        let name = GameName.key(game)
        if let profile = activeAreaProfile, profile.hasPrefix(name + "|") { return own }
        return GameAreaPresets.areas(game).filter { !(phoneOpen && $0.id == GameAreaPresets.phoneId) }
    }
}
