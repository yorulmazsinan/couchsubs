// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.service

import com.couchsubs.mobile.core.GamePackLibrary
import com.couchsubs.mobile.core.PackKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.file.Files

class PlayedGameIdentifyTest {
    /**
     * #1443: paketler kapalıyken (satırlar motordan) oyun yine okunan satırlardan tanınır; PS5 oyunu bildirmeyince GTA 6 hiç
     * tanınmıyor, telefon hiç aranmıyordu. [PlayedGame.noteLine]'a `identify` verilmezse (paketler açık, satır motordan) oy
     * yok; birkaç pakette ortak satır oy getirmez (Windows, Mac/iPhone ile aynı).
     */
    @Test
    fun engineLinesStillRecognizeTheGameWhenPacksAreOff() {
        val directory = Files.createTempDirectory("packs").toFile()
        try {
            val common = PackKey.key("Let's go.")
            val tarnished = PackKey.key("Rise, Tarnished.")
            val horse = PackKey.key("Easy, girl.")
            directory.resolve("a.json").writeText(
                """{"format":1,"id":"elden-ring","title":"Elden Ring","entries":{"$common":"Gidelim.","$tarnished":"Kalk, Lekeli."}}""")
            directory.resolve("b.json").writeText(
                """{"format":1,"id":"rdr-2","title":"Red Dead Redemption 2","entries":{"$common":"Hadi gidelim.","$horse":"Sakin ol kızım."}}""")
            val library = GamePackLibrary(null, directory)
            val log = mutableListOf<String>()
            PlayedGame.log = { log.add(it) }
            PlayedGame.sense.startSession()
            repeat(6) { PlayedGame.noteLine(false, library) }
            assertNull(PlayedGame.sense.current)
            repeat(6) { PlayedGame.noteLine(false, library, "Let's go.") }
            assertNull(PlayedGame.sense.current)
            repeat(4) { PlayedGame.noteLine(false, library, "Rise, Tarnished.") }
            assertNull(PlayedGame.sense.current)
            PlayedGame.noteLine(false, library, "Rise, Tarnished.")
            assertEquals("Elden Ring", PlayedGame.sense.current?.name)
            assertEquals("oyun okunan satırlardan tanındı: Elden Ring", log.last())
        } finally {
            PlayedGame.stop()
            PlayedGame.log = {}
            directory.deleteRecursively()
        }
    }
}
