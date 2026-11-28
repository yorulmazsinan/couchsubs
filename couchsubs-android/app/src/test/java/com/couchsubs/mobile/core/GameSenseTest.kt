// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Oynanan oyunun tanınması ve oyun adı anahtarı (sunucudaki server/pool/test/pool.test.js ile aynı örnekler). */
class GameSenseTest {
    /**
     * Xbox çalışan oyunu bildirmez: Xbox için son seçilen oyun kendiliğinden kullanılır (hatırlanan; değiştirilebilir), hiç
     * seçim yoksa oyun bilinmez ve günlüğe tek satır yazılır (Windows GameSenseTests, Mac/iPhone GameSenseTests ile aynı).
     */
    @Test
    fun xboxStartUsesTheLastChosenGameOrLogsThatTheGameIsUnknown() {
        val fresh = GameSense()
        fresh.startSession()
        assertEquals("Xbox: oyun tanınmadı, oyuna özel okumalar (telefon) kapalı", fresh.startXbox(null))
        assertNull(fresh.current)
        fresh.choose("Grand Theft Auto VI")
        assertEquals("gta 6", GameName.key(fresh.current?.name ?: ""))
        assertEquals("Xbox: oyun elle seçildi: Grand Theft Auto VI", GameSense.xboxChosenLog("Grand Theft Auto VI"))

        val returning = GameSense()
        returning.startSession()
        assertEquals("Xbox: son seçilen oyun kullanılıyor: Grand Theft Auto VI", returning.startXbox("Grand Theft Auto VI"))
        assertEquals("Grand Theft Auto VI", returning.current?.name)
        assertEquals(GameSense.Source.REMEMBERED, returning.source)
        assertFalse(returning.shouldAsk(600_000, true))
        // Kullanıcı değiştirebilir.
        returning.choose("Red Dead Redemption 2")
        assertEquals("Red Dead Redemption 2", returning.current?.name)
        assertEquals(GameSense.Source.USER, returning.source)

        // Bu çalışmada zaten seçilmiş oyun kayıtlı olanın önüne geçer.
        val running = GameSense()
        running.choose("Elden Ring")
        running.startSession()
        running.startXbox("Grand Theft Auto VI")
        assertEquals("Elden Ring", running.current?.name)
    }

    @Test
    fun gameNameKeyMatchesServer() {
        for (name in listOf("Grand Theft Auto VI", "GTA 6", "gta vi", "GTA6", "Grand Theft Auto VI™")) assertEquals(name, "gta 6", GameName.key(name))
        assertEquals("marvels spider man 2", GameName.key("Marvel's Spider-Man 2"))
        assertEquals("witcher 3 wild hunt", GameName.key("The Witcher 3: Wild Hunt"))
        assertEquals("cod black ops 7", GameName.key("Call of Duty: Black Ops 7"))
        assertEquals("ghost of yotei", GameName.key("Ghost of Yōtei"))
        assertEquals("mega man x", GameName.key("Mega Man X"))
        assertFalse(GameName.key("Mega Man X") == GameName.key("Mega Man 10"))
        assertEquals("x men", GameName.key("X-Men"))
        assertEquals("v rally", GameName.key("V-Rally"))
        assertEquals("mega man x 2", GameName.key("Mega Man X2"))
        assertEquals("gta 5", GameName.key("GTA V"))
        assertEquals("gta 5 enhanced", GameName.key("Grand Theft Auto V Enhanced"))
        assertEquals("gta 5 premium edition", GameName.key("GTA V Premium Edition"))
        assertEquals("final fantasy 10 hd", GameName.key("Final Fantasy X HD"))
        assertEquals("mega man x hd", GameName.key("Mega Man X HD"))
        assertEquals("x men origins wolverine", GameName.key("X-Men Origins: Wolverine"))
        assertEquals("v rally 4", GameName.key("V-Rally 4"))
        assertEquals("final fantasy 10", GameName.key("Final Fantasy X"))
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
        // PS5 başka oyun bildirdiyse elle seçim eskidi: PS5 bildirmeyi bırakınca eski seçim geri gelmez (paketten tanınan gelir), arama sınırlanmaz.
        sense.setConsole(null)
        assertEquals("Red Dead Redemption 2", sense.current?.name)
        assertNull(sense.packLimit)
    }

    /** PS5 elle seçilen oyunu bildirirse (adı aynı) seçim kalır. */
    @Test
    fun sameGameFromTheConsoleKeepsTheChoice() {
        val sense = GameSense()
        sense.choose("GTA 5")
        sense.setConsole(RunningGame(null, "Grand Theft Auto V"))
        sense.setConsole(null)
        assertEquals("GTA 5", sense.current?.name)
        assertEquals("GTA 5", sense.packLimit)
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

    /**
     * #353: canlı listedeki RDR2 ve Spider-Man 2 asıl paketle "(ek satırlar)" paketi olarak iki kez görünüyordu; tek karo
     * olur, satırlar toplanır, iki kimlik birlikte açılıp kapanır. Asıl paketi olmayan ek paket kendi karosunda kalır.
     */
    @Test
    fun packShelfFoldsExtraLinesIntoMainPack() {
        val packs = listOf(
            GamePackLibrary.Info("marvels-spider-man-2", "Marvel's Spider-Man 2", 2349, false),
            GamePackLibrary.Info("pool-marvels-spider-man-2", "Marvel's Spider-Man 2 (ek satırlar)", 425, false),
            GamePackLibrary.Info("pool-rdr-2", "Red Dead Redemption 2 (ek satırlar)", 481, false),
            GamePackLibrary.Info("red-dead-redemption-2", "Red Dead Redemption 2", 195_430, true),
            GamePackLibrary.Info("pool-ppsa09999", "Ghost of Yōtei (ek satırlar)", 40, false),
        )
        val shelf = GameCatalog.packShelf(packs)
        assertEquals(listOf("marvels-spider-man-2", "red-dead-redemption-2", "pool-ppsa09999"), shelf.map { it.id })
        assertEquals(2774, shelf[0].entries)
        assertEquals(listOf("marvels-spider-man-2", "pool-marvels-spider-man-2"), shelf[0].packIds)
        assertEquals("Red Dead Redemption 2", shelf[1].title)
        assertEquals(195_911, shelf[1].entries)
        assertTrue("Red Dead Redemption 2 (ek satırlar)" in shelf[1].titles)
        assertEquals(listOf("pool-ppsa09999"), shelf[2].packIds)
    }

    /**
     * #1443: telefon çevirisi açıkken oyun iki dakikada tanınmazsa oturumda bir kez "telefon aranmıyor" yazılır; oyun
     * biliniyorsa ya da telefon kapalıysa yazılmaz (Windows GameSenseTests, Mac/iPhone GameSenseTests ile aynı).
     */
    @Test
    fun phoneIdleIsLoggedOncePerSessionWhileTheGameIsUnknown() {
        val sense = GameSense()
        sense.startSession()
        assertFalse(sense.shouldLogPhoneIdle(60_000, readsPhone = true))
        assertFalse(sense.shouldLogPhoneIdle(130_000, readsPhone = false))
        assertTrue(sense.shouldLogPhoneIdle(130_000, readsPhone = true))
        assertFalse(sense.shouldLogPhoneIdle(145_000, readsPhone = true))
        sense.startSession()
        sense.choose("GTA 6")
        assertFalse(sense.shouldLogPhoneIdle(130_000, readsPhone = true))
        assertTrue(GameSense.PHONE_IDLE_LOG.startsWith("telefon aranmıyor: oynanan oyun bilinmiyor"))
    }
}

