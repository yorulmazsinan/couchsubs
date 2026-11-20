// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Oyuna göre hazır ek alanlar: Windows ve Mac/iPhone ile aynı tablo ve kurallar. */
class GameAreaPresetsTest {
    private val ids = listOf(GameAreaPresets.HELP_ID, GameAreaPresets.PHONE_ID)

    @Test
    fun tableIsFoundByGameName() {
        assertEquals(ids, GameAreaPresets.areas("Grand Theft Auto VI").map { it.id })
        assertEquals(ids, GameAreaPresets.areas("GTA 6").map { it.id })
        assertEquals(CropRegion(top = 0.02, bottom = 0.28, left = 0.01, right = 0.36), GameAreaPresets.areas("GTA 6")[0].region)
        assertEquals(CropRegion(top = 0.45, bottom = 0.80, left = 0.72, right = 0.99), GameAreaPresets.areas("GTA 6")[1].region)
        assertTrue(GameAreaPresets.areas("Red Dead Redemption 2").isEmpty())
        assertTrue(GameAreaPresets.areas(null).isEmpty())
    }

    private fun active(
        enabled: Boolean = true, game: String? = "GTA 6", preset: AreaPreset = AreaPreset.BOTTOM,
        user: List<ExtraArea> = emptyList(), profile: Boolean = false, phone: Boolean = false,
    ) = GameAreaPresets.active(enabled, game, preset, user, profile, phone).map { it.id }

    @Test
    fun presetsApplyOnlyWithoutTheUsersOwnAreas() {
        assertEquals(ids, active())
        assertEquals(emptyList<String>(), active(user = listOf(ExtraArea(name = "Görev", region = ExtraAreaPreset.QUEST.region))))
        // Kapalı tutulan kendi alanı hazır alanları engellemez.
        assertEquals(ids, active(user = listOf(ExtraArea(name = "Görev", region = ExtraAreaPreset.QUEST.region, enabled = false))))
        assertEquals(emptyList<String>(), active(enabled = false))
        assertEquals(emptyList<String>(), active(preset = AreaPreset.FULL))
        assertEquals(emptyList<String>(), active(profile = true))
        assertEquals(listOf(GameAreaPresets.HELP_ID), active(phone = true))
        // Oyun değişince kalkar.
        assertEquals(emptyList<String>(), active(game = "Red Dead Redemption 2"))
        assertEquals(emptyList<String>(), active(game = null))
    }
}
