// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Mac'teki PackLookupTests'in OCR'a dayanıklı arama denemeleri (GamePacksTests.swift). */
class PackLookupFuzzyTest {
    private val pack = mapOf(
        PackKey.key("Get Down!")!! to "Yere yat!",
        PackKey.key("Who is that?")!! to "O da kim?",
        PackKey.key("Don Torrisi wants you.")!! to "Don Torrisi seni istiyor.",
        PackKey.key("Get back!")!! to "Geri çekil!",
    )

    private fun find(line: String) = PackKey.key(line)?.let { pack[it] }
    private fun match(text: String) = PackLookup.match(text) { find(it) }

    /** OCR'ın bozduğu etiket ("-GAETANO:", "M]:", "li LUCA:") da atılıp aranır; ekranda olduğu gibi kalır. */
    @Test
    fun garbledSpeakerLabelIsStripped() {
        assertEquals("- GAETANO: Don Torrisi seni istiyor.", match("-GAETANO: Don Torrisi wants you.")?.text)
        assertEquals("- GAETANO: Don Torrisi seni istiyor.", match("- GAETANO: Don Torrisi wants you.")?.text)
        assertEquals("M]: Yere yat!", match("M]: Get down!")?.text)
        assertEquals("li LUCA: O da kim?", match("li LUCA: Who is that?")?.text)
        assertEquals("SEBASTIAN O da kim?", match("SEBASTIAN Who is that?")?.text)
        assertNull(match("I told you: get out!"))
    }

    /** Paket betiğiyle aynı gevşek etiket kuralı (fuzzy-vectors.json). */
    @Test
    fun looseLabelVectors() {
        val vectors = JSONObject(Fixtures.text("fuzzy-vectors.json")).getJSONArray("looseLabels")
        assertTrue(vectors.length() > 5)
        for (index in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(index)
            val input = vector.getString("input")
            val found = PackLookup.looseLabel(input)
            assertEquals(input, vector.optString("label").takeIf { !vector.isNull("label") }, found?.first)
            assertEquals(input, vector.optString("body").takeIf { !vector.isNull("body") }, found?.second)
        }
    }

    /** Tam anahtar tutmazsa her parça önce tam, sonra bulanık aranır; tam satır her zaman önce gelir. */
    @Test
    fun nearestIsTriedOnlyAfterExactParts() {
        val asked = mutableListOf<String>()
        val nearest = { line: String ->
            asked.add(line)
            if (line == "Who iz that?") "O da kim?" else null
        }
        assertEquals("ENZO: Yere yat! O da kim?", PackLookup.match("ENZO: Get down! Who iz that?", nearest) { find(it) }?.text)
        assertEquals("Yere yat!", PackLookup.match("GET DOWN!!", { "x" }) { find(it) }?.text)
        assertFalse(asked.contains("Get down!"))
    }

    /** Altyazının bloğuna düşen köşe yazısı (GTA V'te bölge adı, kamera ipucu) atlanır; tek başına eşleşme sayılmaz. */
    @Test
    fun overlayLineNextToTheSubtitleIsSkipped() {
        assertEquals("O da kim?", match("San Andreas\nWho is that?")?.text)
        assertEquals("Yere yat!", match("Get down!\nFirst Person • zoom")?.text)
        assertEquals("Yere yat!\nO da kim?", match("Get down!\nMirror Park\nWho is that?")?.text)
        assertNull(match("San Andreas\nMirror Park"))
        assertNull(match("Get down!\nwho are you"))
        assertTrue(PackLookup.isOverlay("LOSNN"))
        assertFalse(PackLookup.isOverlay("Listen to me,"))
        assertFalse(PackLookup.isOverlay("Hey, Franklin!"))
    }

    /** Uzun satırdaki "•" OCR lekesidir: satır köşe yazısı sayılıp atlanmaz, yalnız ikinci satırın Türkçesi gelmez (#245). */
    @Test
    fun longLineWithStrayBulletIsNotAnOverlay() {
        assertFalse(PackLookup.isOverlay("I have a business meeting there with a colleague• Not that it's anything to do"))
        assertNull(match("I have a business meeting there with a colleague• Not that it's anything to do\nWho is that?"))
    }
}

class PackFuzzyTest {
    /**
     * İkinci tur düzeltmeler (yutulan harf, benzeyen harf, iki karışıklık) Mac ve Windows'la aynı küme
     * (fuzzy-vectors.json); arama anahtarları metinlerinkiyle aynı.
     */
    @Test
    fun editVectors() {
        val vectors = JSONObject(Fixtures.text("fuzzy-vectors.json"))
        val thresholds = vectors.getJSONObject("thresholds")
        val length = thresholds.getJSONArray("editLength")
        assertEquals(listOf(PackFuzzy.EDIT_MINIMUM, PackFuzzy.EDIT_MAXIMUM, PackFuzzy.EDIT_PAIRS), (0 until length.length()).map { length.getInt(it) })
        assertEquals(PackFuzzy.MINIMUM_EVIDENCE, thresholds.getDouble("minimumEvidence"), 0.0)
        assertEquals(PackFuzzy.CLEAN_MISSING, thresholds.getInt("cleanMissing"))
        val edits = vectors.getJSONArray("edits")
        assertTrue(edits.length() >= 5)
        fun strings(array: org.json.JSONArray) = (0 until array.length()).map { array.getString(it) }
        for (index in 0 until edits.length()) {
            val vector = edits.getJSONObject(index)
            val input = vector.getString("input")
            val found = PackFuzzy.edits(input)
            assertEquals(input, vector.getInt("count"), found.size)
            assertEquals(input, strings(vector.getJSONArray("first")), found.take(5))
            assertEquals(input, strings(vector.getJSONArray("last")), found.takeLast(5))
            for (expected in strings(vector.getJSONArray("contains"))) assertTrue(expected, expected in found)
            assertEquals(input, found.mapNotNull { PackKey.canonNumber(it) }.toSet(), PackFuzzy.editKeys(input))
            assertTrue(input, found.toSet().intersect(PackFuzzy.variants(input).toSet()).isEmpty())
        }
        val evidence = vectors.getJSONArray("evidence")
        for (index in 0 until evidence.length()) {
            val vector = evidence.getJSONObject(index)
            val z = PackFuzzy.evidence(vector.getInt("both"), vector.getInt("inQuery"), vector.getInt("inEntry"), vector.getInt("bits"))
            assertEquals(vector.getDouble("query"), z.query, 1e-9)
            assertEquals(vector.getDouble("entry"), z.entry, 1e-9)
        }
    }

    /**
     * Ortak deneme paketi (pack-fuzzy.json.gz, paket betiğiyle yapıldı): Mac ve Windows'la aynı vakalar, aynı sonuç. Tek
     * harf hatası, yutulan harf, iki karışıklık, konuşmacı adı ve OCR izli uzun satır bulunur; pakette olmayan benzer
     * satırlar başka satıra eşlenmez.
     */
    @Test
    fun sharedFuzzyPackCases() {
        val fixtures = JSONObject(Fixtures.text("pack-fuzzy-cases.json"))
        val library = GamePackLibrary({ listOf("pack-fuzzy.json.gz" to { Fixtures.bytes("pack-fuzzy.json.gz") }) }, null)
        assertNotNull(PackLookup.match(library, fixtures.getString("warmUp")))
        assertEquals("fuzzy-test", library.searchScope)
        val cases = fixtures.getJSONArray("cases")
        for (index in 0 until cases.length()) {
            val item = cases.getJSONObject(index)
            val screen = item.getString("screen")
            assertEquals(screen, if (item.isNull("turkish")) null else item.getString("turkish"), PackLookup.match(library, screen)?.text)
        }
    }

    /** İmza Mac, Windows ve paket betiğiyle bit bit aynı. */
    @Test
    fun signatureVectors() {
        val vectors = JSONObject(Fixtures.text("fuzzy-vectors.json"))
        val signatures = vectors.getJSONArray("signatures")
        assertTrue(signatures.length() > 10)
        for (index in 0 until signatures.length()) {
            val vector = signatures.getJSONObject(index)
            val input = vector.getString("input")
            assertEquals(input, vector.getString("folded"), String(PackFuzzy.folded(input), 0, PackFuzzy.folded(input).size))
            assertEquals(input, vector.getBoolean("damaged"), PackFuzzy.damaged(input))
            val signature = PackFuzzy.signature(input)
            if (vector.isNull("length")) {
                assertNull(input, signature)
                continue
            }
            assertEquals(input, vector.getInt("length"), signature!!.first)
            assertEquals(input, vector.getInt("bits"), PackFuzzy.bits(signature.first))
            assertEquals(input, vector.getString("bloom"), signature.second.joinToString("") { "%02x".format(it.toInt() and 0xff) })
        }
        val pairs = vectors.getJSONArray("similarities")
        for (index in 0 until pairs.length()) {
            val pair = pairs.getJSONObject(index)
            val bits = pair.getInt("bits")
            val query = PackFuzzy.bloom(PackFuzzy.trigramHashes(PackFuzzy.folded(pair.getString("query"))), bits)
            val entry = PackFuzzy.bloom(PackFuzzy.trigramHashes(PackFuzzy.folded(pair.getString("entry"))), bits)
            assertEquals(pair.getString("query"), pair.getDouble("similarity"), PackFuzzy.similarity(query, entry, 0, bits), 1e-9)
        }
    }

    /** Tek OCR düzeltmesi: karışan harf, düşen harf, yutulan boşluk ya da kesme işareti; kısa ve uzun satırda yok. */
    @Test
    fun variantsAreSingleCorrections() {
        val variants = PackFuzzy.variants("Somebody help rne!")
        assertTrue(variants.contains("somebody help me"))
        assertTrue(PackFuzzy.variants("You cant put a price").contains("you can t put a price"))
        assertTrue(PackFuzzy.variants("Yeah, well, well see.").contains("yeah well we ll see"))
        assertFalse(variants.contains("somebody help rne"))
        assertTrue(variants.none { it.startsWith(' ') || it.endsWith(' ') || it.contains("  ") })
        assertTrue(PackFuzzy.variants("Hey").isEmpty())
        assertTrue(PackFuzzy.variants("x".repeat(49)).isEmpty())
    }

    private val directory = System.getProperty("couchsubs.packs")?.let(::File)

    /** Yalnız tek paketle kitaplık (birleşik kitaplıkta ortak satırlarda başka oyunun çevirisi kazanabilir). */
    private fun library(file: String) = GamePackLibrary({ listOf(file to { File(directory, file).readBytes() }) }, null)

    private fun GamePackLibrary.match(text: String) = PackLookup.match(this, text)

    /**
     * Kullanıcılardan gelen gerçek ıskalamalar (Mafia: The Old Country, OCR hatalı, parça parça ve etiketi bozuk
     * satırlar): Mac, Windows ve paket betiğiyle aynı Türkçe ya da hiç eşleşme (başka oyunların satırları).
     */
    @Test
    fun realOcrMissesMatchLikeThePackScript() {
        if (directory == null) return
        val fixtures = JSONObject(Fixtures.text("pack-matches.json"))
        val cases = fixtures.getJSONArray("cases")
        assertTrue(cases.length() >= 50)
        val library = library("mafia-the-old-country.json.gz")
        assertNull(library.searchScope)
        assertNotNull(library.match(fixtures.getString("warmUp")))
        assertEquals("mafia-the-old-country", library.searchScope)
        val started = System.nanoTime()
        for (index in 0 until cases.length()) {
            val item = cases.getJSONObject(index)
            val screen = item.getString("screen")
            assertEquals(screen, if (item.isNull("turkish")) null else item.getString("turkish"), library.match(screen)?.text)
        }
        println("Mafia bulanık arama: satır başına ${"%.2f".format((System.nanoTime() - started) / 1e6 / cases.length())} ms")
    }

    /** Hiç tam eşleşme olmadan bulanık arama yapılmaz (hangi oyunun oynandığı belli değil). */
    @Test
    fun noFuzzySearchBeforeTheGameIsKnown() {
        if (directory == null) return
        val library = library("mafia-the-old-country.json.gz")
        val garbled = "GAETANO: All this will bébehind u soon: Uötil'then don't let any of these båétards getpyou, alrightiz:t"
        assertNull(library.match(garbled))
        assertNull(library.scopeTitle)
        assertNotNull(library.match("You fucked up now, boy!"))
        assertEquals("Mafia: The Old Country", library.scopeTitle)
        val clean = library.match("All this will be behind us soon. Until then don’t let any of these bastards get to you, alright?")?.text
        assertEquals("GAETANO: $clean", library.match(garbled)?.text)
        assertEquals("mafia-the-old-country", library.match(garbled)?.packId)
    }

    /** Biçim 2: oyunun ayrı gösterdiği parçalar ve imzalar. */
    @Test
    fun versionTwoSegmentsAndSignaturesLoad() {
        if (directory == null) return
        val library = library("mafia-the-old-country.json.gz")
        assertNotNull(library.match("Che buono."))
        assertEquals("ENZO: Che buono.", library.match("ENZO: Che buono.")?.text)
        assertNotNull(library.match("then clear the way for someone who does."))
        val pack = GamePack.decode(File(directory, "mafia-the-old-country.json.gz").readBytes(), "mafia-the-old-country")
        assertTrue((pack.fuzzy?.count ?: 0) > 20000)
    }

    /**
     * GTA V oyuncularının gerçek ıskalamaları: kısa satırda tek harf hatası, yutulmuş kesme işareti, köşe yazısı, iki
     * satırlık altyazının yalnız bir satırı ve başına çöp eklenmiş okuma da paketten bulunur.
     */
    @Test
    fun gtaOcrReadsAreFound() {
        if (directory == null) return
        val library = library("gta-v.json.gz")
        assertNotNull(library.match("Are you listening to me?"))
        fun same(screen: String, line: String) {
            val expected = library.match(line)?.text
            assertNotNull(line, expected)
            assertEquals(screen, expected, library.match(screen)?.text)
        }
        same("Somebody help rne!", "Somebody help me!")
        same("Yeah, well, well see.", "Yeah, well, we'll see.")
        same("You cant put a price on freedom.", "You can't put a price on freedom.")
        same("LOSNN\nI told him to leave it, Trevor.", "I told him to leave it, Trevor.")
        same("I can't do crap with this deathship right", "I can't do crap with this deathship right on top of me! Bring it down, T!")
        same("San Andreas LOSNN but it does mean he's got money to pay people who help him.",
            "but it does mean he's got money to pay people who help him.")
        assertNull(library.match("The quick brown fox jumps over the lazy dog near the river bank."))
        assertNull(library.match("Sauvage gentleman of the western plains"))
    }

    /**
     * İki altyazı yan yana tek satır okununca yalnız birinin Türkçesi gösterilmez (Mac'teki
     * testTwoSubtitlesReadAsOneLineAreNotHalfTranslated ile aynı); köşe yazısı eklenmiş okuma yine bulunur.
     */
    @Test
    fun twoSubtitlesReadAsOneLineAreNotHalfTranslated() {
        assertEquals(
            listOf("Mirror Park Errr.", "Your broke.", "Call me back,", "okay? Bye, Dad."),
            PackFuzzy.clauses("Mirror Park Errr. Your broke. Call me back, okay? Bye, Dad."),
        )
        assertEquals(
            listOf("to escape...", "if we're able.", "You said seriously. nis seriously."),
            PackFuzzy.clauses("to escape... if we're able. You said seriously. nis seriously."),
        )
        if (directory == null) return
        val library = library("gta-v.json.gz")
        assertNotNull(library.match("Are you listening to me?"))
        val pairs = listOf(
            "Hey, look. Good shit on those contracts you been workin' on." to "But listen, I got some other work.",
            "I'm calling it. Don't burn your eyes out." to "Bye, Dad.",
        )
        for ((first, second) in pairs) {
            val alone = library.match(first)?.text
            assertNotNull(first, alone)
            val found = library.match("$first $second")?.text
            assertNotEquals("$first $second", alone, found)
            val other = library.match(second)?.text
            if (found != null && other != null) assertTrue(found, found.contains(alone!!) && found.contains(other))
        }
        assertNotNull(library.match("Your vehicle? Sorry, we can't get that sorted at this time. San Andreas"))
        assertNotNull(library.match("Vinewood Hills Just not my junk, okay? I'm already scarred down there."))
    }

    /** En büyük pakette (GTA V) bulunamayan satırın araması da satır başına 20 ms'nin altında. */
    @Test
    fun fuzzySearchIsFastInTheLargestPack() {
        if (directory == null) return
        val library = library("gta-v.json.gz")
        assertNotNull(library.match("Are you listening to me?"))
        val lines = listOf(
            "Wh4t the fück are y0u doing here, man? Get öut of my house!", "Mich ael, I tbink we need to tälk about this",
            "Yöu know what, Franklin? You're a good kid, but you gotta lısten", "Lâmar, get in the c ar, we're late!",
            "The quick brown fox jumps over the lazy dog near the river bank.", "Sauvage gentleman of the western plains",
        )
        // Isınma (JIT), sonra ölçüm.
        repeat(5) { for (line in lines) library.match(line) }
        val rounds = 25
        val started = System.nanoTime()
        repeat(rounds) { for (line in lines) library.match(line) }
        val perLineMs = (System.nanoTime() - started) / 1e6 / (rounds * lines.size)
        println("GTA V bulanık arama: satır başına ${"%.2f".format(perLineMs)} ms")
        assertTrue("satır başına $perLineMs ms", perLineMs < 20)
    }
}
