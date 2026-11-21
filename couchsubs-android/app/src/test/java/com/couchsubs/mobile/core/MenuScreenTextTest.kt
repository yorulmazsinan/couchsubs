// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** Ekranın herhangi bir yerindeki menüler (tekerlek menü) ve yoğun menü ekranları (duraklatma menüsü, kontrol şeması). */
class MenuScreenTextTest {
    private val width = 640
    private val height = 360

    /** Tek karoluk (20×20) koyu etiket kutusu ve beyaz yazı çizgileri; [columns] karo genişliğinde. */
    private fun label(pixels: ByteArray, column: Int, row: Int, columns: Int = 1) {
        for (y in row * 20 until row * 20 + 20) for (x in column * 20 until (column + columns) * 20) {
            val text = (y - row * 20) % 8 in 3..4 && x % 4 != 0
            pixels[y * width + x] = (if (text) 230 else 25).toByte()
        }
    }

    private val labels = listOf(4 to 12, 8 to 12, 12 to 12, 16 to 12, 20 to 12, 24 to 12, 6 to 4, 26 to 4)

    /** Tekerlek menü: bulanık (düşük sapmalı) zemin, 8 kısa etiket, ortada üç karoluk başlık. */
    private fun wheel(seed: Int, blurred: Boolean = true): ByteArray {
        val random = Random(seed)
        val pixels = ByteArray(width * height) { if (blurred) (110 + random.nextInt(6)).toByte() else random.nextInt(256).toByte() }
        labels.forEach { (column, row) -> label(pixels, column, row) }
        label(pixels, 14, 8, columns = 3)
        return pixels
    }

    private fun ScreenTextDetector.step(pixels: ByteArray, now: Long): List<ExtraArea> =
        update(sample(width, height) { x, y -> pixels[y * width + x].toInt() and 0xff }, emptyList(), now)

    @Test
    fun wheelMenuIsDetectedAndClosesAtOnce() {
        val detector = ScreenTextDetector()
        var areas = emptyList<ExtraArea>()
        for (t in 0L..300L step 100) areas = detector.step(wheel(t.toInt()), t)
        assertTrue(detector.menu)
        // 8 tek karoluk etiket ve başlık: hepsi alan, menü bayraklı.
        assertEquals(9, areas.size)
        assertTrue(areas.all { it.menu && it.auto })
        // Menü kapanınca (bulanık zemin kaldı, etiketler gitti) bütün alanlar hemen kalkar.
        val closed = ByteArray(width * height) { 112 }
        assertTrue(detector.step(closed, 400).isEmpty())
        assertFalse(detector.menu)
    }

    @Test
    fun shortLabelsOverASharpMovingSceneAreNotAMenu() {
        val detector = ScreenTextDetector()
        var areas = emptyList<ExtraArea>()
        for (t in 0L..600L step 100) areas = detector.step(wheel(t.toInt(), blurred = false), t)
        assertFalse(detector.menu)
        // Tek karoluk etiketler menü dışında alan olmaz; yalnız üç karoluk başlık kalır.
        assertEquals(1, areas.size)
        assertFalse(areas.single().menu)
    }

    @Test
    fun menuNoiseRules() {
        assertTrue(ScreenTextNoise.isNoise("OFF"))
        assertFalse(ScreenTextNoise.isNoise("OFF", menu = true))
        assertFalse(ScreenTextNoise.isNoise("Map", menu = true))
        listOf("40", "0", "x3", "100%").forEach { assertTrue(it, ScreenTextNoise.isNoise(it, menu = true)) }
    }

    @Test
    fun uiCommandsKeepTheOriginalCase() {
        assertEquals("KAPALI", UiCommands.translateLabel("OFF"))
        assertEquals("Kapalı", UiCommands.translateLabel("Off"))
        assertEquals("kapalı", UiCommands.translateLabel("off"))
        assertEquals("AÇIK", UiCommands.translateLabel("ON"))
        assertEquals("KIYAFETLER", UiCommands.translateLabel("OUTFITS"))
        assertEquals("İSTATİSTİKLER", UiCommands.translateLabel("STATS"))
        assertEquals("SEÇ ${ButtonIcons.MARKER}", UiCommands.translateLabelLoosely("SELECT ${ButtonIcons.MARKER}"))
        assertNull(UiCommands.translateLabel("Open the door"))
    }

    // --- Ek alan hattı ---

    private class Recorder : RegionSender {
        val sent = mutableListOf<String>()
        val blocks = mutableListOf<List<ScreenTranslation.Item>?>()
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) =
            sendRegion(id, text, box, lineHeight, null, null)
        override fun sendRegion(
            id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?,
            blocks: List<ScreenTranslation.Item>?,
        ) {
            sent.add(text)
            this.blocks.add(blocks)
        }
        override fun clearRegions() {}
    }

    /** Sayan sahte çevirmen: toplu istek tek istek sayılır. */
    private class Counting : TextTranslator {
        var requests = 0
        val texts = mutableListOf<String>()
        override fun translate(text: String): String {
            requests++
            texts.add(text)
            return "TR $text"
        }
        override fun translateAll(texts: List<String>): List<String> {
            requests++
            this.texts.addAll(texts)
            return texts.map { "TR $it" }
        }
    }

    private fun signature(value: Int) = ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { value.toByte() }

    private val region = CropRegion(top = 0.0, bottom = 1.0, left = 0.0, right = 1.0)

    @Test
    fun menuLabelsComeFromTheDictionaryAndNumbersAreLeftOut() {
        val recorder = Recorder()
        val engine = Counting()
        val rejected = mutableListOf<String>()
        val off = ExtraArea("auto-1", ScreenTextDetector.NAME, region, auto = true, menu = true)
        val forty = ExtraArea("auto-2", ScreenTextDetector.NAME, region, auto = true, menu = true)
        val frame = GrayFrame(ByteArray(100 * 100) { 25 }, 100, 100)
        var text = "OFF"
        val watcher = RegionWatcher({ Reading(listOf(TextLine(text, TextBox(0.1, 0.1, 0.4, 0.3)))) }, engine, recorder)
        watcher.onAutoRejected = { rejected.add(it) }
        repeat(2) { watcher.pass(setOf(off.id), listOf(off to RegionWatcher.Crop(Unit, signature(1), frame))) }
        assertEquals(listOf("KAPALI"), recorder.sent)
        assertEquals(0, engine.requests)
        text = "40"
        watcher.pass(setOf(forty.id), listOf(forty to RegionWatcher.Crop(Unit, signature(2), frame)))
        assertEquals(listOf("auto-2"), rejected)
    }

    /** Koyu panelde 6 satır; [selected] satırı açık zeminde koyu yazı. */
    private fun pausePanel(selected: Int): GrayFrame {
        val w = 200
        val h = 240
        return GrayFrame(ByteArray(w * h) { index ->
            val x = index % w
            val y = index / w
            val row = y / 40
            val inverted = row == selected
            val ink = y % 40 in 15..18 && x in 20..120 && x % 4 != 0
            (if (inverted) (if (ink) 20 else 220) else (if (ink) 230 else 25)).toByte()
        }, w, h)
    }

    private val pauseLines = listOf("Map", "Game", "Store", "Help", "Photo Studio", "Settings").mapIndexed { i, text ->
        TextLine(text, TextBox(0.1, (i * 40 + 12) / 240.0, 0.6, (i * 40 + 22) / 240.0))
    }

    @Test
    fun pauseMenuStyleIsPerLineAndSelectionOnlyResendsColors() {
        val recorder = Recorder()
        val engine = Counting()
        val area = ExtraArea("auto-1", ScreenTextDetector.NAME, CropRegion(top = 0.1, bottom = 0.9, left = 0.0, right = 0.4), auto = true)
        val watcher = RegionWatcher({ Reading(pauseLines) }, engine, recorder)
        repeat(2) { watcher.pass(setOf(area.id), listOf(area to RegionWatcher.Crop(Unit, signature(1), pausePanel(0)))) }
        val first = recorder.blocks.last()!!
        assertEquals(6, first.size)
        assertEquals("#DCDCDC", first[0].surface!!.background)
        assertEquals("#141414", first[0].surface!!.foreground)
        assertEquals("#191919", first[1].surface!!.background)
        // Harf düzeni korunur: karışık harfli özgün normal Türkçe; hepsi arayüz sözlüğünden, çevirmene gidilmez.
        assertEquals(listOf("Harita", "Oyun", "Dükkân", "Yardım", "Fotoğraf stüdyosu", "Ayarlar"), first.map { it.translation })
        assertEquals(0, engine.requests)
        val requests = engine.requests
        // Seçim bir alt satıra kayar: çeviri yeniden istenmez, yalnız renkler gider.
        repeat(2) { watcher.pass(setOf(area.id), listOf(area to RegionWatcher.Crop(Unit, signature(100), pausePanel(1)))) }
        assertEquals(requests, engine.requests)
        val second = recorder.blocks.last()!!
        assertEquals("#191919", second[0].surface!!.background)
        assertEquals("#DCDCDC", second[1].surface!!.background)
        assertEquals(first.map { it.translation }, second.map { it.translation })
    }

    @Test
    fun controlSchemeIsTranslatedInOneBatchAndCachedForTheSession() {
        val recorder = Recorder()
        val engine = Counting()
        val area = ExtraArea("auto-1", ScreenTextDetector.NAME, CropRegion(top = 0.0, bottom = 1.0, left = 0.0, right = 1.0), auto = true, menu = true)
        val left = listOf("HOLSTER (L1)", "AIM / INTERACT (L2)", "RUN (L3)", "SPRINT FAST (L3)", "CROUCH LOW (R3)", "SWAP WEAPON (R1)",
            "FIRE WEAPON (R2)", "RADIO WHEEL (L1)", "PHONE MENU (UP)", "QUICK SAVE (DOWN)")
        val right = listOf("(△) INTERACT", "(✕) JUMP / CLIMB", "(○) TAKE COVER", "(□) RELOAD GUN", "(△) ENTER VEHICLE",
            "(✕) MELEE ATTACK", "(○) DODGE ROLL", "(□) PICK UP ITEM", "(△) CALL HORSE", "(✕) WHISTLE LOUD", "5 / 9")
        // Sol sütun sağa yaslı (sağ kenarlar aynı), sağ sütun sola yaslı; satırlar arası boşluk grupları ayırmasın diye geniş.
        val lines = left.mapIndexed { i, text ->
            TextLine(text, TextBox(0.40 - text.length * 0.01, 0.05 + i * 0.09, 0.40, 0.08 + i * 0.09))
        } + right.mapIndexed { i, text -> TextLine(text, TextBox(0.60, 0.05 + i * 0.08, 0.60 + text.length * 0.01, 0.08 + i * 0.08)) }
        val frame = GrayFrame(ByteArray(400 * 400) { index -> (if (index % 7 == 0) 230 else 25).toByte() }, 400, 400)
        val watcher = RegionWatcher({ Reading(lines) }, engine, recorder)
        repeat(2) { watcher.pass(setOf(area.id), listOf(area to RegionWatcher.Crop(Unit, signature(1), frame))) }
        // 20'den çok etiket tek toplu istekte.
        assertEquals(1, engine.requests)
        // Ayırıcıyla bölünen etiket parça parça; tuş adları ve sayaç dokunulmaz.
        // Satır ucundaki tuş adı çeviriye ve kutuya girmez, ekranda görünür kalır (#860).
        assertTrue(engine.texts.toString(), "AIM" in engine.texts && "JUMP" in engine.texts && "CLIMB" in engine.texts)
        assertFalse(engine.texts.any { it.contains("(L1)") || it.contains("(✕)") })
        assertFalse(engine.texts.any { it.contains("5 / 9") || it == "5" })
        val items = recorder.blocks.last()!!
        val holster = items.first { it.source == "HOLSTER" }
        assertEquals("right", holster.look!!.align)
        assertTrue(holster.box.right < 0.40)
        assertEquals("TR AIM / ETKİLEŞİM", items.first { it.source.startsWith("AIM") }.translation)
        assertEquals("left", items.first { it.source.contains("JUMP") }.look!!.align)
        // Aynı ekrana dönüş: oturum terimleriyle istek gitmez.
        watcher.reset()
        repeat(2) { watcher.pass(setOf(area.id), listOf(area to RegionWatcher.Crop(Unit, signature(5), frame))) }
        assertEquals(1, engine.requests)
    }
}
