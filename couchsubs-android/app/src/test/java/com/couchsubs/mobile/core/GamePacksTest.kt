// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Mac ve Windows'la ortak deneme dosyaları (core/Tests/CouchSubsCoreTests/Fixtures'tan kopya). */
internal object Fixtures {
    fun bytes(name: String): ByteArray = Fixtures::class.java.getResourceAsStream("/fixtures/$name")!!.use { it.readBytes() }
    fun text(name: String) = String(bytes(name), Charsets.UTF_8)
}

class PackKeyTest {
    /** Mac, Windows ve paket hazırlayan Python betiği (canon.py) ile aynı sonuç. */
    @Test
    fun goldenVectors() {
        val vectors = JSONArray(Fixtures.text("golden-vectors.json"))
        assertEquals(15, vectors.length())
        for (i in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(i)
            val input = vector.getString("input")
            assertEquals(input, vector.getString("canon"), PackKey.canon(input))
            assertEquals(input, vector.getString("key"), PackKey.key(input) ?: "")
        }
    }

    @Test
    fun tagsLongerThanFortyCharactersStay() {
        assertEquals("a   c", PackKey.stripTags("a <b> c"))
        val tooLong = "<" + "x".repeat(41) + ">"
        assertEquals(tooLong, PackKey.stripTags(tooLong))
        assertEquals(" ", PackKey.stripTags("<" + "x".repeat(40) + ">"))
        assertEquals("a < b   c", PackKey.stripTags("a < b <i> c"))
        assertEquals("< >", PackKey.stripTags("<<b>>"))
    }

    @Test
    fun numberRoundTripsUnsignedKeys() {
        assertEquals(-1L, PackKey.number("ffffffffffffffff"))
        assertNull(PackKey.number("xyz"))
        assertNull(PackKey.number("0123"))
    }
}

class GamePackTest {
    private fun load(name: String) = GamePack.decode(Fixtures.bytes(name), name.removeSuffix(".json.gz"))

    @Test
    fun wrappedAndBareFormatsLoad() {
        val wrapped = load("pack-wrapped.json.gz")
        assertEquals("test-game", wrapped.id)
        assertEquals("Test Game", wrapped.title)
        assertEquals(5, wrapped.size)
        val bare = load("pack-bare.json.gz")
        assertEquals("pack-bare", bare.id)
        assertEquals("pack-bare", bare.title)
        assertEquals(2, bare.size)
    }

    @Test
    fun plainJsonIsAccepted() {
        val key = PackKey.key("Get back!")!!
        val pack = GamePack.decode("{\"$key\": \"Geri çekil!\"}".toByteArray(), "plain")
        assertEquals("Geri çekil!", pack[PackKey.number(key)!!])
    }

    @Test
    fun brokenFilesAreRejected() {
        assertThrows(InvalidPackException::class.java) { GamePack.decode("not json".toByteArray(), "x") }
        assertThrows(InvalidPackException::class.java) { GamePack.decode(byteArrayOf(0x1f, 0x8b.toByte(), 8, 0) + ByteArray(30) { 7 }, "x") }
        assertThrows(InvalidPackException::class.java) { GamePack.decode("{\"format\":2,\"entries\":{\"0123456789abcdef\":\"x\"}}".toByteArray(), "x") }
        assertThrows(InvalidPackException::class.java) { GamePack.decode("{\"bad\":\"x\"}".toByteArray(), "x") }
    }

    @Test
    fun tagsAreRemovedFromTurkish() {
        val pack = load("pack-wrapped.json.gz")
        val key = PackKey.number(PackKey.key("<b><h>SCANNATURI SPECIALE</></> KNIFE")!!)!!
        assertEquals("SCANNATURI SPECIALE BIÇAĞI", pack[key])
    }

    @Test
    fun libraryMergesBundledAndUserPacks() {
        val user = Files.createTempDirectory("packs").toFile()
        val library = GamePackLibrary({
            listOf(
                "a.json.gz" to Fixtures.bytes("pack-bare.json.gz"),
                "b.json.gz" to Fixtures.bytes("pack-wrapped.json.gz"),
                "c.json.gz" to "bozuk".toByteArray(),
            )
        }, user)
        assertEquals(listOf("a", "Test Game"), library.infos.map { it.title })
        assertEquals(listOf(2, 5), library.infos.map { it.entries })
        // Aynı anahtarda sonraki paket kazanır.
        assertEquals("Yere yat!", library.find("Get Down!"))
        assertEquals("test-game", library.findWithPack("Get Down!")?.packId)
        assertEquals("Geri çekil!", library.find("Get back!"))

        // Kullanıcının klasöründeki aynı kimlikli paket uygulamanınkinin yerine geçer.
        val key = PackKey.key("Get Down!")
        File(user, "test.json").writeText("{\"format\":1,\"id\":\"test-game\",\"title\":\"Test Game 2\",\"entries\":{\"$key\":\"Yat yere!\"}}")
        library.reload()
        assertEquals(listOf("a", "Test Game 2"), library.infos.map { it.title })
        assertEquals(listOf(true, false), library.infos.map { it.builtIn })
        assertEquals("Yat yere!", library.find("Get Down!"))
        assertNull(library.find("Who is that?"))

        // Kapatılan paket aranmaz; önceki paketin çevirisi görünür.
        library.setDisabled(setOf("test-game"))
        assertEquals("a", library.findWithPack("Get Down!")?.packId)
    }

    /** Uygulamayla gelen paketler (core/Sources/CouchSubsCore/Resources/packs) yüklenir ve hızlı aranır. */
    @Test
    fun embeddedPacksLoad() {
        val directory = File(System.getProperty("couchsubs.packs") ?: return)
        val started = System.nanoTime()
        val library = GamePackLibrary({ directory.listFiles()!!.map { it.name to it.readBytes() } }, null)
        val ids = library.infos.map { it.id }
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertTrue(ids.contains("gta-v"))
        assertTrue(ids.contains("mafia-the-old-country"))
        assertTrue("paketler $elapsedMs ms'de yüklendi", elapsedMs < 10_000)
        val mafia = GamePackLibrary({ listOf("mafia-the-old-country.json.gz" to File(directory, "mafia-the-old-country.json.gz").readBytes()) }, null)
        assertEquals("MARIA: Yere yat!", PackLookup.match(mafia, "MARIA: Get Down!")?.text)
        assertEquals("Yere yat!\nMinchia! Sana at sürmeyi yasaklamak lazım!",
            PackLookup.match(mafia, "Get Down!\nMinchia! You shouldn't be allowed to ride!")?.text)
    }
}

class PackLookupTest {
    private val pack = mapOf(
        PackKey.key("Get Down!")!! to "Yere yat!",
        PackKey.key("Who is that?")!! to "O da kim?",
        PackKey.key("Don Torrisi wants you.")!! to "Don Torrisi seni istiyor.",
        PackKey.key("Get back!")!! to "Geri çekil!",
    )

    private fun match(text: String) = PackLookup.match(text) { line -> PackKey.key(line)?.let { pack[it] } }

    @Test
    fun wholeLineIgnoresCaseSpacingAndPunctuation() {
        assertEquals("Yere yat!", match("GET DOWN!!")?.text)
        assertEquals("O da kim?", match("  Who   is\nthat?  ")?.text)
        assertNull(match("Get out!"))
        assertNull(match(""))
    }

    @Test
    fun speakerLabelIsKept() {
        assertEquals("ENZO: Don Torrisi seni istiyor.", match("ENZO: Don Torrisi wants you.")?.text)
        assertEquals("Cesare: Yere yat!", match("Cesare: Get down!")?.text)
        assertNull(match("ENZO: Get out!"))
    }

    @Test
    fun eachLineIsLookedUpWhenTheWholeIsMissing() {
        assertEquals("ENZO: Yere yat!\nMARIA: O da kim?", match("ENZO: Get down!\nMARIA: Who is that?")?.text)
        assertEquals("- Yere yat!\n- O da kim?", match("- Get down!\n- Who is that?")?.text)
        assertNull(match("Get down!\nWho are you?"))
    }

    @Test
    fun eachSentenceIsLookedUpWhenTheLineIsMissing() {
        assertEquals("ENZO: Yere yat! O da kim?", match("ENZO: Get down! Who is that?")?.text)
        assertEquals("Yere yat! Geri çekil!", match("Get down! Get back!")?.text)
        assertNull(match("Get down! Who are you?"))
    }

    @Test
    fun wholeLineWinsOverParts() {
        val custom = mapOf(PackKey.key("Get down! Get back!")!! to "Eğil ve geri çekil!", PackKey.key("Get Down!")!! to "Yere yat!")
        assertEquals("Eğil ve geri çekil!", PackLookup.match("Get down! Get back!") { line -> PackKey.key(line)?.let { custom[it] } }?.text)
    }
}
