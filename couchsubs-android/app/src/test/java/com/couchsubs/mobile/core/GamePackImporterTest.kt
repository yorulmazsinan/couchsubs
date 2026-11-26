// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/** core/Tests/CouchSubsCoreTests/GamePackImporterTests.swift ile aynı durumlar (Mac, Windows ve telefon aynı sonucu verir). */
class GamePackImporterTest {
    private fun parse(source: String, name: String) = GamePackImporter.parse(source.toByteArray(Charsets.UTF_8), name)

    @Test
    fun flatJsonHashesEnglishAndCountsInvalidRecords() {
        val preview = parse("""{"You fucked up now, boy!":"  Bu kez işi batırdın!  ","...":"x","":"x","Blank":"  ","Number":7}""", "flat.JSON")
        assertNull(preview.suggestedTitle)
        assertEquals(mapOf("e7f18c8f6d1083ab" to "Bu kez işi batırdın!"), preview.entries)
        assertEquals(4, preview.invalidCount)
    }

    @Test
    fun jsonEnvelopeUsesMetadataAndOnlyReadsSubtitlePairs() {
        val preview = parse("""{"game":"  Test Game  ","title":"Alternate","subtitles":{"Get Down!":"Yere yat!"},"other":"ignored"}""", "game.json")
        assertEquals("Test Game", preview.suggestedTitle)
        assertEquals(mapOf("ebf811f2fee9a8cc" to "Yere yat!"), preview.entries)
        assertEquals(0, preview.invalidCount)
    }

    @Test
    fun hashedJsonValidatesAndLowercasesKeysWithoutRehashing() {
        val preview = parse(
            """{"format":1,"id":"ignored","title":"Existing Game","entries":{"0123456789ABCDEF":"Türkçe","0123456789abcdef":"Türkçe","+123456789abcdef":"bad","g123456789abcdef":"bad","fedcba9876543210":null,"9999999999999999":"  ","123":"bad"}}""",
            "existing.json",
        )
        assertEquals("Existing Game", preview.suggestedTitle)
        assertEquals(mapOf("0123456789abcdef" to "Türkçe"), preview.entries)
        assertEquals(5, preview.invalidCount)
        assertEquals(1, preview.duplicateCount)
    }

    @Test
    fun canonicalJsonDuplicatesAreCountedAndConflictsOmitted() {
        val preview = parse("""{"Get Down!":"Yere yat!","get down":"Yere yat!","get DOWN?":"Çök!","GET DOWN.":"Yere yat!","Who is that?":"Kim o?"}""", "repeat.json")
        assertEquals(mapOf("ce61a5b5526ea81a" to "Kim o?"), preview.entries)
        assertEquals(2, preview.duplicateCount)
        assertEquals(1, preview.conflictCount)
    }

    @Test
    fun repeatedJsonMembersReachThePairAccumulator() {
        val fixtures = listOf(
            """{"Get Down!":"Yere yat!","Get Down!":"Çök!","Get Down!":"Çök!","Who is that?":"Kim o?","Who is that?":"Kim o?"}""" to "ce61a5b5526ea81a",
            """{"subtitles":{"Get Down!":"Yere yat!","Get Down!":"Çök!","Get Down!":"Çök!","Who is that?":"Kim o?","Who is that?":"Kim o?"}}""" to "ce61a5b5526ea81a",
            """{"format":1,"entries":{"0123456789abcdef":"Yere yat!","0123456789abcdef":"Çök!","0123456789abcdef":"Çök!","ffffffffffffffff":"Kim o?","ffffffffffffffff":"Kim o?"}}""" to "ffffffffffffffff",
        )
        for ((source, survivingKey) in fixtures) {
            val preview = parse(source, "repeats.json")
            assertEquals(source, mapOf(survivingKey to "Kim o?"), preview.entries)
            assertEquals(source, 2, preview.duplicateCount)
            assertEquals(source, 1, preview.conflictCount)
        }
    }

    @Test
    fun numericFormatRequiresAnEntriesObject() {
        listOf(
            """{"format":1,"title":"Existing Game","entries":[]}""",
            """{"format":1,"title":"Existing Game","entries":"text"}""",
            """{"format":1,"title":"Existing Game","entries":[true,"Get Down!","Yere yat!"]}""",
            """{"format":1,"title":"Existing Game","subtitles":{"Get Down!":"Yere yat!"}}""",
            """{"format":2,"title":"Existing Game","entries":null}""",
        ).forEach { source -> assertThrows(source, GamePackImporter.ImportException::class.java) { parse(source, "broken-pack.json") } }
    }

    @Test
    fun txtHandlesBomCrlfAndBothDelimiters() {
        val preview = parse("﻿  # ignored\r\n\r\nGet Down! = Yere yat! = şimdi\r\nWho is that?\tKim o?\r\nbroken\r\nEmpty = \r\n\tMissing\r\nExtra\tfield\tline\r\n", "pairs.txt")
        assertEquals(mapOf("ebf811f2fee9a8cc" to "Yere yat! = şimdi", "ce61a5b5526ea81a" to "Kim o?"), preview.entries)
        assertEquals(4, preview.invalidCount)
    }

    @Test
    fun conflictingCanonicalKeyStaysOmittedAfterMoreRecords() {
        val preview = parse("Get Down! = Yere yat!\nget down = Yere yat!\n<b>GET DOWN</b> = Çök!\nGet down? = Yere yat!\nGet down = Eğil!\nWho is that? = Kim o?", "pairs.txt")
        assertEquals(mapOf("ce61a5b5526ea81a" to "Kim o?"), preview.entries)
        assertEquals(2, preview.duplicateCount)
        assertEquals(1, preview.conflictCount)
        assertEquals(0, preview.invalidCount)
    }

    @Test
    fun bilingualSrtSkipsInvalidCueShapesWithoutLosingNeighbors() {
        val cues = listOf(
            "1\n00:00:01,250 --> 00:00:03,999\n Get Down! \n Yere yat! ",
            "2\n00:00:04,000 --> 00:00:05,000\nOne line",
            "3\n00:00:06,000 --> 00:00:07,000\nThree\nText\nLines",
            "x\n00:00:08,000 --> 00:00:09,000\nBad\nIndex",
            "5\n00:60:00,000 --> 00:60:01,000\nBad\nClock",
            "6\n00:00:11.000 --> 00:00:11.999\nBad\nSeparator",
            "7\n00:00:13,000 --> 00:00:12,000\nReversed\nClock",
            "8\n00:00:14,000 --> 00:00:15,000\nWho is that?\nKim o?",
        )
        val preview = parse("﻿" + cues.joinToString("\n \t\n").replace("\n", "\r\n"), "pairs.SRT")
        assertEquals(mapOf("ebf811f2fee9a8cc" to "Yere yat!", "ce61a5b5526ea81a" to "Kim o?"), preview.entries)
        assertEquals(6, preview.invalidCount)
    }

    @Test
    fun invalidFileShapesAndUnsupportedFormatsThrow() {
        val failure = GamePackImporter.ImportException::class.java
        assertThrows(failure) { parse("pairs", "file.csv") }
        assertThrows(failure) { GamePackImporter.parse(byteArrayOf(0xff.toByte()), "file.txt") }
        assertThrows(failure) { parse("[1, 2]", "file.json") }
        assertThrows(failure) { parse("""{"oops",1}""", "file.json") }
        assertThrows(failure) { parse("""{"format":3,"entries":{"0123456789ABCDEF":"Türkçe"}}""", "file.json") }
        assertThrows(failure) { parse("""{"format":true,"entries":{"0123456789ABCDEF":"Türkçe"}}""", "file.json") }
        val tooLarge = assertThrows(failure) { GamePackImporter.parse(ByteArray(GamePackImporter.MAX_FILE_BYTES + 1), "big.txt") }
        assertEquals(GamePackImporter.Failure.FILE_TOO_LARGE, tooLarge.failure)
    }

    @Test
    fun idsUseStablePathSafeAscii() {
        assertEquals("community-my-game-a-a", GamePackImporter.makeId(" ../My GAME\\a:a... "))
        assertEquals("community-game", GamePackImporter.makeId("../遊戲"))
        assertEquals("community-" + "a".repeat(80), GamePackImporter.makeId("a".repeat(300)))
    }

    @Test
    fun installWritesPackTheLibraryCanReloadAndRequiresReplacement() {
        val directory = Files.createTempDirectory("imported").toFile()
        try {
            val library = GamePackLibrary(null, null, directory)
            assertTrue(library.infos.isEmpty())
            val initial = parse("Get Down! = Yere yat!", "pairs.txt")
            assertThrows(GamePackImporter.ImportException::class.java) { GamePackImporter.install(initial, " \n ", directory, false) }
            val file = GamePackImporter.install(initial, " Test Game ", directory, false)
            assertEquals("community-test-game.json", file.name)
            val original = file.readBytes()
            val json = JSONObject(String(original, Charsets.UTF_8))
            assertEquals(1, json.getInt("format"))
            assertEquals("community-test-game", json.getString("id"))
            assertEquals("Test Game", json.getString("title"))
            assertEquals("Yere yat!", json.getJSONObject("entries").getString("ebf811f2fee9a8cc"))
            assertEquals(1, json.getJSONObject("entries").length())
            library.reload()
            assertEquals(listOf("Test Game"), library.infos.map { it.title })
            assertEquals(listOf(1), library.infos.map { it.entries })
            assertEquals("Yere yat!", library.find("Get down!"))

            val updated = parse("Get Down! = Çök!", "pairs.txt")
            val exists = assertThrows(GamePackImporter.ImportException::class.java) { GamePackImporter.install(updated, "Test Game", directory, false) }
            assertEquals(GamePackImporter.Failure.DESTINATION_EXISTS, exists.failure)
            assertArrayEquals(original, file.readBytes())
            assertEquals(file, GamePackImporter.install(updated, "Test Game", directory, true))
            library.reload()
            assertEquals("Çök!", library.find("Get down!"))
            assertEquals(listOf(file.name), directory.list()!!.toList())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun importedPackWinsOverDownloadedPackOnTheSameLine() {
        val downloaded = Files.createTempDirectory("downloaded").toFile()
        val imported = Files.createTempDirectory("imported").toFile()
        try {
            val key = PackKey.key("Get Down!")!!
            java.io.File(downloaded, "game.json").writeText("""{"format":1,"id":"game","title":"Game","entries":{"$key":"Yere yat!"}}""")
            GamePackImporter.install(parse("Get Down! = Çök!", "pairs.txt"), "Game", imported, false)
            val library = GamePackLibrary(null, downloaded, imported)
            assertEquals(listOf("game", "community-game"), library.infos.map { it.id })
            assertEquals("Çök!", library.find("Get Down!"))
        } finally {
            downloaded.deleteRecursively()
            imported.deleteRecursively()
        }
    }

    /**
     * Ortak deneme dosyası (fixtures/pack-import-report.json, core/Tests/CouchSubsCoreTests/Fixtures kopyası): her dosya
     * türünde kabul edilen satırlar, nedenine göre atlananlar ve günlük satırı Mac ve Windows ile aynı; kurulan paketten
     * satırlar ekrandaki gibi bulunur (#1355).
     */
    @Test
    fun sharedImportReportCases() {
        val cases = JSONObject(Fixtures.text("pack-import-report.json")).getJSONArray("cases")
        for (index in 0 until cases.length()) {
            val item = cases.getJSONObject(index)
            val file = item.getString("file")
            val preview = parse(item.getString("text"), file)
            assertEquals(file, item.getInt("accepted"), preview.acceptedCount)
            assertEquals(file, item.getInt("segments"), preview.segments.size)
            val skipped = item.getJSONObject("skipped")
            assertEquals(file, skipped.keys().asSequence().associateWith { skipped.getInt(it) },
                preview.skipped.mapKeys { it.key.rawValue })
            assertEquals(file, item.optBoolean("fuzzyDropped", false), preview.fuzzyDropped)
            assertEquals(file, if (item.has("title")) item.getString("title") else null, preview.suggestedTitle)
            assertEquals(item.getString("log"), preview.logLine(file))

            val directory = Files.createTempDirectory("imported").toFile()
            try {
                GamePackImporter.install(preview, "Harbor", directory, false)
                val library = GamePackLibrary(null, null, directory)
                val lookups = item.getJSONObject("lookups")
                for (screen in lookups.keys()) {
                    val turkish = if (lookups.isNull(screen)) null else lookups.getString(screen)
                    assertEquals("$file: $screen", turkish, PackLookup.match(library, screen)?.text)
                }
            } finally {
                directory.deleteRecursively()
            }
        }
    }

    /**
     * Paket betiğiyle yapılan biçim 2 paket (parçalar ve OCR verisiyle) içe aktarılabilir; oyunun adından farklı bir
     * başlıkla kurulsa da oyun elle seçiliyken satırlar (OCR hatalı olanlar da) bu paketten bulunur. Başka oyunun paketi
     * seçilen oyunda yine aranmaz (#218). Önceden biçim 2 reddediliyor, oyun seçiliyken içe aktarılan paket hiç
     * okunmuyordu (#1355).
     */
    @Test
    fun formatTwoCommunityPackServesTheChosenGameDespiteADifferentTitle() {
        val community = JSONObject(Fixtures.text("pack-import-report.json")).getJSONObject("community")
        val data = java.util.zip.GZIPInputStream(Fixtures.bytes("pack-fuzzy.json.gz").inputStream()).use { it.readBytes() }
        val preview = GamePackImporter.parse(data, "harbor-fuzzy.json")
        assertTrue(preview.fuzzy != null)
        assertTrue(!preview.fuzzyDropped)
        assertEquals(0, preview.skippedCount)
        assertTrue(preview.acceptedCount > 10)

        val bundledLine = community.getString("otherLine")
        val other = """{"format":1,"id":"elsewhere","title":"${community.getString("otherPackTitle")}","entries":{"${PackKey.key(bundledLine)}":"Fener söndü."}}"""
        val imported = Files.createTempDirectory("imported").toFile()
        try {
            val library = GamePackLibrary({ listOf("elsewhere.json" to { other.toByteArray() }) }, null, imported)
            val game = community.getString("chosenGame")
            assertEquals(community.getString("missingLog"), library.limitLog(game))

            GamePackImporter.install(preview, community.getString("title"), imported, false)
            assertEquals(community.getString("installLog"), preview.installLog(" ${community.getString("title")} "))
            library.reload()
            library.limitToGame(game)
            assertEquals(community.getString("log"), library.limitLog(game))
            assertNull(PackLookup.match(library, bundledLine))

            val fuzzy = JSONObject(Fixtures.text("pack-fuzzy-cases.json"))
            assertTrue(PackLookup.match(library, fuzzy.getString("warmUp")) != null)
            val cases = fuzzy.getJSONArray("cases")
            for (index in 0 until cases.length()) {
                val item = cases.getJSONObject(index)
                val screen = item.getString("screen")
                assertEquals(screen, if (item.isNull("turkish")) null else item.getString("turkish"), PackLookup.match(library, screen)?.text)
            }
        } finally {
            imported.deleteRecursively()
        }
    }

    @Test
    fun emptyPreviewCannotReplaceAUsablePack() {
        val directory = Files.createTempDirectory("imported").toFile()
        try {
            val file = GamePackImporter.install(parse("Get Down! = Yere yat!", "pairs.txt"), "Test Game", directory, false)
            val original = file.readBytes()
            val empty = parse("# no pairs\ninvalid", "pairs.txt")
            assertTrue(empty.entries.isEmpty())
            assertThrows(GamePackImporter.ImportException::class.java) { GamePackImporter.install(empty, "Test Game", directory, true) }
            assertArrayEquals(original, file.readBytes())
        } finally {
            directory.deleteRecursively()
        }
    }
}
