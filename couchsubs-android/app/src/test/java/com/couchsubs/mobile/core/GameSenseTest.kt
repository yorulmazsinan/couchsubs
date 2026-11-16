// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Oynanan oyunun tanınması ve oyun adı anahtarı (sunucudaki server/pool/test/pool.test.js ile aynı örnekler). */
class GameSenseTest {
    @Test
    fun gameNameKeyMatchesServer() {
        for (name in listOf("Grand Theft Auto VI", "GTA 6", "gta vi", "GTA6", "Grand Theft Auto VI™")) assertEquals(name, "gta 6", GameName.key(name))
        assertEquals("marvels spider man 2", GameName.key("Marvel's Spider-Man 2"))
        assertEquals("witcher 3 wild hunt", GameName.key("The Witcher 3: Wild Hunt"))
        assertEquals("cod black ops 7", GameName.key("Call of Duty: Black Ops 7"))
        assertEquals("ghost of yotei", GameName.key("Ghost of Yōtei"))
        assertEquals("", GameName.key(""))
    }

    /** Yapay zekâya giden ad kararlı oyundur: tek bir yabancı satır değiştirmez, 20 satırın 5'i değiştirir (#27). */
    @Test
    fun oneStrayLineDoesNotChangeTheGame() {
        val sense = GameSense()
        repeat(5) { sense.noteLine("gta-v", "Grand Theft Auto V") }
        assertEquals("Grand Theft Auto V", sense.current?.name)
        assertFalse(sense.noteLine("rdr-2", "Red Dead Redemption 2"))
        assertEquals("Grand Theft Auto V", sense.current?.name)
        repeat(3) { assertFalse(sense.noteLine("rdr-2", "Red Dead Redemption 2")) }
        assertEquals("Grand Theft Auto V", sense.current?.name)
        assertTrue(sense.noteLine("rdr-2", "Red Dead Redemption 2"))
        assertEquals("Red Dead Redemption 2", sense.current?.name)
    }

    /** Paketle tanınmayan oyunda ad gitmez; kullanıcı seçtiyse onun seçtiği, PS5 bildirdiyse PS5'in bildirdiği gider. */
    @Test
    fun withoutAStableGameTheChosenNameOrNothingIsSent() {
        val sense = GameSense()
        repeat(4) { sense.noteLine("rdr-2", "Red Dead Redemption 2") }
        assertNull(sense.current)
        sense.choose("Grand Theft Auto V")
        assertEquals("Grand Theft Auto V", sense.current?.name)
        sense.setConsole(RunningGame(null, "Mafia: The Old Country"))
        assertEquals("Mafia: The Old Country", sense.current?.name)
    }

    /**
     * Elle seçilen oyun paket çoğunluğunun önüne geçer, PS5'in bildirdiğinin önüne geçmez; paket araması yalnız elle seçim
     * geçerliyken o oyunla sınırlanır (#218).
     */
    @Test
    fun chosenGameBeatsThePackButNotTheConsole() {
        val sense = GameSense()
        sense.choose("Marvel's Wolverine")
        repeat(5) { sense.noteLine("rdr-2", "Red Dead Redemption 2") }
        assertEquals("Marvel's Wolverine", sense.current?.name)
        assertEquals(GameSense.Source.USER, sense.source)
        assertEquals("Marvel's Wolverine", sense.packLimit)
        sense.setConsole(RunningGame(null, "Mafia: The Old Country"))
        assertEquals("Mafia: The Old Country", sense.current?.name)
        assertEquals(GameSense.Source.CONSOLE, sense.source)
        assertNull(sense.packLimit)
    }

    @Test
    fun fiveOfTwentyLinesFromOnePackRecogniseTheGame() {
        val sense = GameSense()
        repeat(4) { assertFalse(sense.noteLine("gta-v", "Grand Theft Auto V")) }
        repeat(10) { sense.noteLine(null, null) }
        assertNull(sense.current)
        assertTrue(sense.noteLine("gta-v", "Grand Theft Auto V"))
        assertEquals(RunningGame(null, "Grand Theft Auto V"), sense.current)
        assertEquals(GameSense.Source.PACK, sense.source)
        // Aynı paket yeniden "tanınmaz".
        assertFalse(sense.noteLine("gta-v", "Grand Theft Auto V"))
    }

    @Test
    fun generalPackIsNotAGameAndTitleIdComesFromAutoPack() {
        val sense = GameSense()
        repeat(10) { assertFalse(sense.noteLine(GameSense.GENERAL_PACK, "Ortak havuz")) }
        repeat(5) { sense.noteLine("pool-ppsa01234", "Grand Theft Auto VI") }
        assertEquals(RunningGame("PPSA01234", "Grand Theft Auto VI"), sense.current)
        assertEquals("CUSA00419_00", GameSense.titleIdFromPack("pool-cusa00419-00"))
        assertNull(GameSense.titleIdFromPack("pool-gta-6"))
    }

    @Test
    fun asksOnceAfterTwoMinutesWhenNothingIsKnown() {
        val sense = GameSense()
        assertFalse(sense.shouldAsk(60_000, true))
        assertFalse(sense.shouldAsk(GameSense.ASK_AFTER_MS, false))
        assertTrue(sense.shouldAsk(GameSense.ASK_AFTER_MS, true))
        sense.markAsked()
        assertFalse(sense.shouldAsk(GameSense.ASK_AFTER_MS, true))
        // Seçim oturumlar arasında kalır; seçilmişse yeni oturumda da sorulmaz.
        sense.choose("GTA 6")
        sense.startSession()
        assertEquals(RunningGame(null, "GTA 6"), sense.current)
        assertFalse(sense.shouldAsk(GameSense.ASK_AFTER_MS, true))
        // PS5'in bildirdiği oyun önce gelir.
        sense.setConsole(RunningGame.create("PPSA01234", "Grand Theft Auto VI"))
        assertEquals("PPSA01234", sense.current?.titleId)
    }

    @Test
    fun suggestionsPutLastPlayedFirstAndFindByKey() {
        val list = GameCatalog.suggestions("", listOf("Mafia: The Old Country"), last = "Elden Ring")
        assertEquals("Elden Ring", list[0])
        assertEquals("Mafia: The Old Country", list[1])
        assertEquals("Grand Theft Auto VI", GameCatalog.suggestions("gta 6", emptyList(), null).first())
        assertTrue(GameCatalog.suggestions("zzzz", emptyList(), null).isEmpty())
    }
}
