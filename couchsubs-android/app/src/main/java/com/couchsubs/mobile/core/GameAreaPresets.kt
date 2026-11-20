// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Oyuna göre hazır ek alanlar: tabloda satırı olan bir oyun oynanırken o oyunun yardım kutusu ve mesajları, kullanıcı
 * hiçbir şey ayarlamadan sürekli okunup kendi yerinde çevrilir. Alanlar çalışma anında hesaplanır, ayarlara yazılmaz;
 * kullanıcının kendi ek alanı ya da o oyun için etkin alan profili varsa hiç eklenmez. Yeni oyun = tabloya bir satır.
 * Windows (GameAreaPresets.cs) ve Mac/iPhone (GameAreaPresets.swift) aynı tabloyu ve kuralları kullanır.
 * Bölgeler gerçek GTA 6 ekranında doğrulanmadı; kullanıcı kendi ek alanını ekleyerek değiştirebilir.
 */
object GameAreaPresets {
    const val HELP_ID = "preset-help"
    const val PHONE_ID = "preset-phone"

    private val table: Map<String, List<ExtraArea>> = mapOf(
        "gta 6" to listOf(
            // Sol üstteki ipucu kutusu.
            ExtraArea(HELP_ID, "Help", CropRegion(top = 0.02, bottom = 0.28, left = 0.01, right = 0.36)),
            // Sağ alttaki telefon mesajı kartı.
            ExtraArea(PHONE_ID, "Messages", CropRegion(top = 0.45, bottom = 0.80, left = 0.72, right = 0.99)),
        ),
    )

    /** Oyunun hazır alanları ([GameName.key] ile aranır); tabloda yoksa boş. */
    fun areas(game: String?): List<ExtraArea> = game?.let { table[GameName.key(it)] } ?: emptyList()

    /**
     * Şu an okunacak hazır alanlar. [enabled]: "Bilinen oyunlarda hazır alanları kullan"; [userAreas]: kullanıcının
     * etkin (sürekli okunan) ek alanları; [profileActive]: bir alan profili uygulanıyor; [phoneOpen]: oyunun telefonu
     * açık (telefon kendisi okunuyor, mesaj kartı çıkarılır).
     */
    fun active(
        enabled: Boolean, game: String?, preset: AreaPreset, userAreas: List<ExtraArea>, profileActive: Boolean,
        phoneOpen: Boolean = false,
    ): List<ExtraArea> {
        if (!enabled || preset == AreaPreset.FULL || profileActive || userAreas.any { it.enabled }) return emptyList()
        val areas = areas(game)
        return if (phoneOpen) areas.filter { it.id != PHONE_ID } else areas
    }
}
