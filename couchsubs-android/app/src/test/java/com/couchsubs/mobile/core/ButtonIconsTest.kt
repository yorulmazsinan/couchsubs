// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Oyun ipuçlarındaki kumanda simgeleri ("Hold △ to sprint"): yazı tanıma simgeyi harf sanıyor ("A", "Ä"), çeviri
 * simgeyi örtüyor ve Türkçede neye basılacağı kalmıyordu. Sözcük yerleri Windows yazı tanımasının 1280×200'lük gerçek
 * okumalarından alındı (Windows: ButtonIconsTests.cs ile aynı durumlar ve sayılar).
 */
class ButtonIconsTest {
    private companion object {
        const val WIDTH = 1280
        const val HEIGHT = 200
        const val M = ButtonIcons.MARKER

        /** Windows testindeki koyu zemin (BGR 52, 44, 40) parlaklığı. */
        const val BACKGROUND = 44
        const val WHITE = 255
        const val BLACK = 0
    }

    private fun word(text: String, x: Double, w: Double, y: Double, h: Double) =
        TextWord(text, TextBox(x / WIDTH, y / HEIGHT, (x + w) / WIDTH, (y + h) / HEIGHT))

    private fun line(vararg words: TextWord): TextLine {
        val box = words.drop(1).fold(words[0].box) { total, word -> total.union(word.box) }
        return TextLine(words.joinToString(" ") { it.text }, box, words = words.toList())
    }

    // "Hold △ to sprint.": △ "A" okundu.
    private val hold = line(word("Hold", 48.0, 75.0, 89.0, 31.0), word("A", 138.0, 29.0, 90.0, 27.0),
        word("to", 202.0, 34.0, 91.0, 25.0), word("sprint.", 249.0, 99.0, 84.0, 39.0))

    /** Koyu zeminde beyaz "yazı" blokları ve (135–182, 79–126) arasında yuvarlak bir simge. */
    private fun holdFrame(): GrayFrame {
        val frame = GrayFrame(ByteArray(WIDTH * HEIGHT), WIDTH, HEIGHT)
        fill(frame, 0, 0, WIDTH, HEIGHT, BACKGROUND)
        fill(frame, 48, 89, 123, 120, WHITE) // Hold
        fill(frame, 202, 91, 236, 116, WHITE) // to
        fill(frame, 249, 84, 348, 123, WHITE) // sprint.
        for (y in 79 until 126) {
            for (x in 135 until 182) {
                if ((x - 158.5) * (x - 158.5) + (y - 102.5) * (y - 102.5) <= 23.5 * 23.5) set(frame, x, y, BLACK)
            }
        }
        return frame
    }

    private fun fill(frame: GrayFrame, x0: Int, y0: Int, x1: Int, y1: Int, value: Int) {
        for (y in y0 until y1) for (x in x0 until x1) set(frame, x, y, value)
    }

    private fun set(frame: GrayFrame, x: Int, y: Int, value: Int) {
        frame.luma[y * frame.stride + x] = value.toByte()
    }

    private fun pngSize(dataUri: String): Pair<Int, Int> {
        val prefix = "data:image/png;base64,"
        assertTrue(dataUri.startsWith(prefix))
        val bytes = Base64.getDecoder().decode(dataUri.substring(prefix.length))
        fun read(at: Int) = ((bytes[at].toInt() and 0xff) shl 24) or ((bytes[at + 1].toInt() and 0xff) shl 16) or
            ((bytes[at + 2].toInt() and 0xff) shl 8) or (bytes[at + 3].toInt() and 0xff)
        return read(16) to read(20)
    }

    @Test
    fun iconReadAsALetterAfterAVerbIsMarked() {
        val marked = ButtonIcons.mark(hold)
        assertEquals("Hold $M to sprint.", marked.text)
        val icon = marked.icons!!.single()
        assertEquals("A", icon.text)
        // Kutu simgenin tamamını içine alır (komşu sözcüklerle arasındaki boşlukların ortasına kadar).
        assertTrue(icon.box.left * WIDTH <= 135 && icon.box.right * WIDTH >= 182)
        assertTrue(icon.box.top * HEIGHT <= 79 && icon.box.bottom * HEIGHT >= 126)
    }

    @Test
    fun iconGluedToTheVerbIsSplitOff() {
        // "Press [R2] to open the weapon wheel." → "PressÄ"
        val line = line(word("PressÄ", 49.0, 148.0, 71.0, 41.0), word("to", 223.0, 33.0, 80.0, 24.0), word("open", 269.0, 80.0, 85.0, 28.0),
            word("the", 362.0, 52.0, 76.0, 28.0), word("weapon", 425.0, 127.0, 85.0, 28.0), word("wheel.", 565.0, 101.0, 76.0, 28.0))
        val marked = ButtonIcons.mark(line)
        assertEquals("Press $M to open the weapon wheel.", marked.text)
        assertEquals("Ä", marked.icons!!.single().text)
    }

    @Test
    fun severalIconsInOneHintAreMarked() {
        // "Use [stick] to move the camera and [△] to interact." → "Useo ... and A to interact."
        val line = line(word("Useo", 48.0, 94.0, 69.0, 41.0), word("to", 164.0, 27.0, 80.0, 21.0), word("move", 204.0, 76.0, 85.0, 16.0),
            word("the", 291.0, 44.0, 77.0, 24.0), word("camera", 346.0, 100.0, 85.0, 16.0), word("and", 458.0, 50.0, 77.0, 24.0),
            word("A", 527.0, 26.0, 76.0, 24.0), word("to", 582.0, 29.0, 80.0, 21.0), word("interact.", 623.0, 110.0, 78.0, 23.0))
        val marked = ButtonIcons.mark(line)
        assertEquals("Use $M to move the camera and $M to interact.", marked.text)
        assertEquals(listOf("o", "A"), marked.icons!!.map { it.text })
    }

    @Test
    fun unreadIconLeavesAGapAfterTheVerb() {
        // Simge hiç okunmadı: "Hold" ile "to" arasında birkaç harflik boşluk kalır.
        val line = line(word("Hold", 48.0, 75.0, 89.0, 31.0), word("to", 202.0, 34.0, 91.0, 25.0), word("sprint.", 249.0, 99.0, 84.0, 39.0))
        val marked = ButtonIcons.mark(line)
        assertEquals("Hold $M to sprint.", marked.text)
        assertEquals("", marked.icons!!.single().text)
    }

    @Test
    fun ordinaryTextIsLeftAlone() {
        for (text in listOf("I'll use a rope to climb down.", "Press the button to continue.", "Hold on, Arthur.",
            "He uses the map, and I follow.", "A New Quest", "Use it wisely.")) {
            // Sözcük yerleri bilinmiyor: harf sayısına göre kestirilir.
            val line = TextLine(text, TextBox(0.1, 0.4, 0.6, 0.45))
            assertSame(text, line, ButtonIcons.mark(line))
        }
    }

    @Test
    fun withoutWordPositionsTheIconIsStillFoundByItsPlaceInTheText() {
        // Okuyucu yalnız satırın kutusunu veriyor.
        val marked = ButtonIcons.mark(TextLine("Hold A to sprint.", TextBox(0.1, 0.4, 0.6, 0.45)))
        assertEquals("Hold $M to sprint.", marked.text)
    }

    @Test
    fun iconRecognisedAsASymbolIsTranslatedInsteadOfDroppedAsAPrompt() {
        // Simgeyi tanıyan okuyucu: "Hold △ to sprint." eskiden kumanda ipucu sayılıp hiç çevrilmiyordu.
        val line = TextLine("Hold △ to sprint.", TextBox(39.0 / WIDTH, 0.4, 356.0 / WIDTH, 0.62))
        val lines = Reading(listOf(line)).withButtonIcons().withoutButtonPrompts().lines
        assertEquals("Hold $M to sprint.", lines.single().text)
    }

    @Test
    fun iconRemnantsFromTheHintPoolBecomeIcons() {
        // #424'ün GTA 6 havuzundaki gerçek okumaları: fiil ile "to" arasındaki tuş kalıntıları simgedir.
        val cases = listOf(
            Triple("Press @ to open the map", "Press $M to open the map", listOf("@")),
            Triple("Hold I LI to open your loadout", "Hold $M to open your loadout", listOf("I LI")),
            Triple("Press RE to go back to your weapons and equipment", "Press $M to go back to your weapons and equipment", listOf("RE")),
            Triple("Press (9 0 to stop focusing", "Press $M to stop focusing", listOf("(9 0")),
            Triple("Release 2 and R2 to breathe out", "Release $M and $M to breathe out", listOf("2", "R2")),
            Triple("Press [RB] to take cover", "Press $M to take cover", listOf("[RB]")),
        )
        for ((read, marked, icons) in cases) {
            val line = ButtonIcons.mark(TextLine(read, TextBox(0.1, 0.4, 0.6, 0.45)))
            assertEquals(read, marked, line.text)
            assertEquals(read, icons, line.icons.orEmpty().map { it.text })
        }
    }

    @Test
    fun hintWhoseIconWasFoundIsTranslatedButOtherwiseStillDropped() {
        val line = TextLine("Press @ to open the map", TextBox(0.1, 0.4, 0.6, 0.45))
        // Ekranı çevir/ek alan: simge bulunduysa satır kalır (simgesiyle çevrilir).
        assertEquals(1, Reading(listOf(line)).withButtonIcons().withoutButtonPrompts().lines.size)
        // Ana altyazı simge aramaz: #424'teki gibi ipucu atılır.
        assertTrue(Reading(listOf(line)).withoutButtonPrompts().lines.isEmpty())
    }

    @Test
    fun speechKeptByTheHintRuleIsNotMarked() {
        // #424'ün koruduğu konuşmalar simge sanılmaz.
        for (text in listOf("Press the button, Jason!", "Hold on to something.", "HOLD ON TO IT", "Use it to open the door.",
                            "Jason: Press to the left", "Hold to your course")) {
            val line = TextLine(text, TextBox(0.1, 0.4, 0.6, 0.45))
            assertSame(text, line, ButtonIcons.mark(line))
        }
    }

    @Test
    fun hintSplitAroundTheIconIsJoinedBack() {
        // Gerçek bir okuma: "Press" | "R2" | "to open the weapon wheel." (x: 42-144, 125-179, 215-670).
        val reading = Reading(listOf(
            TextLine("Press", TextBox(42.0 / WIDTH, 70.0 / HEIGHT, 144.0 / WIDTH, 114.0 / HEIGHT)),
            TextLine("R2", TextBox(125.0 / WIDTH, 68.0 / HEIGHT, 179.0 / WIDTH, 116.0 / HEIGHT)),
            TextLine("to open the weapon wheel.", TextBox(215.0 / WIDTH, 72.0 / HEIGHT, 670.0 / WIDTH, 112.0 / HEIGHT)),
        ))
        val line = reading.withButtonIcons().lines.single()
        assertEquals("Press $M to open the weapon wheel.", line.text)
        assertEquals("R2", line.icons!!.single().text)
    }

    @Test
    fun separateLabelsOnOneRowAreNotJoined() {
        val reading = Reading(listOf(
            TextLine("Map", TextBox(0.10, 0.9, 0.14, 0.93)),
            TextLine("Inventory", TextBox(0.16, 0.9, 0.24, 0.93)),
        ))
        assertSame(reading, ButtonIcons.joinHints(reading))
    }

    @Test
    fun shortPromptsWithTheButtonAtAnEdgeStayUntranslated() {
        // Bilerek çevrilmezler (ek alanda sürekli gelip giderler); örtülmedikleri için simge zaten görünür kalır.
        for (text in listOf("△ Pick up", "L1 + R1 Spartan Rage", "PHOTO MODE L1 + R1")) {
            val line = TextLine(text, TextBox(0.1, 0.4, 0.4, 0.45))
            assertEquals(text, emptyList<TextLine>(), Reading(listOf(line)).withButtonIcons().withoutButtonPrompts().lines)
        }
    }

    @Test
    fun buttonAfterAVerbAtTheEndIsTranslatedWithTheVerb() {
        // "Hold △": yalnız "Hold" çevrilince "Tut" kalır; ad ile "△'yu basılı tut" olur.
        val marked = ButtonIcons.mark(TextLine("Hold △", TextBox(0.1, 0.4, 0.3, 0.45)))
        assertEquals("Hold Feldor", IconText.protect(marked.text).text)
    }

    @Test
    fun singleLettersAtTheStartAreNotButtons() {
        // "A Pick up": "A" düğme de olabilir, tanım edatı da; tek harfe ancak fiilden sonra güvenilir.
        val line = TextLine("A Pick up", TextBox(0.1, 0.4, 0.3, 0.45))
        assertSame(line, ButtonIcons.mark(line))
    }

    @Test
    fun ocrNoiseCleaningKeepsTheMarker() {
        val reading = Reading(listOf(ButtonIcons.mark(hold))).withoutOcrNoise()
        assertEquals("Hold $M to sprint.", reading.lines[0].text)
        assertEquals(1, reading.lines[0].icons!!.size)
    }

    @Test
    fun cropCutsTheIconTightlyOutOfTheFrame() {
        val icon = ButtonIcons.mark(hold).icons!!.single()
        val image = ButtonIcons.crop(holdFrame(), icon.box)
        assertNotNull(image)
        val (width, height) = pngSize(image!!)
        // 47 piksellik simge + iki yanda 2 piksel pay; komşu sözcükler girmez.
        assertTrue("$width", width in 47..53)
        assertTrue("$height", height in 47..53)
    }

    @Test
    fun cropOfAnEmptyPlaceGivesNothing() {
        val frame = GrayFrame(ByteArray(WIDTH * HEIGHT), WIDTH, HEIGHT)
        fill(frame, 0, 0, WIDTH, HEIGHT, BACKGROUND)
        assertNull(ButtonIcons.crop(frame, TextBox(0.1, 0.3, 0.15, 0.6)))
    }

    @Test
    fun iconKeepsItsPlaceThroughTranslation() {
        val (text, names) = IconText.protect("Hold $M to sprint.")
        assertEquals("Hold Feldor to sprint.", text)
        // Çevirmen ada Türkçe ek koyar; ek gerçek düğmenin adına uymayacağı için atılır.
        val restored = IconText.restore("Koşmak için Feldor'u basılı tutun.", names, 0)
        val rendered = IconText.render(restored, listOf(IconSlot(TextBox(0.0, 0.0, 0.0, 0.0), "A", "data:image/png;base64,AAAA")))
        assertEquals("Koşmak için basılı tutun.", rendered.text)
        assertEquals(12, rendered.icons.single().at)
    }

    @Test
    fun twoIconsKeepTheirOwnPlacesAndPunctuationStaysAttached() {
        val (text, names) = IconText.protect("Use $M to move the camera and $M to interact.")
        assertEquals("Use Feldor to move the camera and Halvor to interact.", text)
        // Türkçede sıra değişir; her ad kendi simgesine döner.
        val restored = IconText.restore("Etkileşim için Halvor'u, kamerayı oynatmak için Feldor'u kullanın.", names, 0)
        val none = TextBox(0.0, 0.0, 0.0, 0.0)
        val slots = listOf(IconSlot(none, "o", "data:image/png;base64,STICK"), IconSlot(none, "A", "data:image/png;base64,TRI"))
        val rendered = IconText.render(restored, slots)
        assertEquals("Etkileşim için, kamerayı oynatmak için kullanın.", rendered.text)
        assertEquals(listOf(14 to "data:image/png;base64,TRI", 39 to "data:image/png;base64,STICK"), rendered.icons.map { it.at to it.image })
    }

    @Test
    fun cropIgnoresANeighbouringLetterThatFallsIntoTheBox() {
        val frame = holdFrame()
        fill(frame, 126, 96, 132, 118, WHITE) // simgeye yakın bir harf
        val image = ButtonIcons.crop(frame, TextBox(120.0 / WIDTH, 70.0 / HEIGHT, 186.0 / WIDTH, 135.0 / HEIGHT))
        val (width, _) = pngSize(image!!)
        assertTrue("$width", width in 47..53)
    }

    @Test
    fun droppedPlaceholderPutsTheIconInFront() {
        val (_, names) = IconText.protect("Hold $M to sprint.")
        val restored = IconText.restore("Koşmak için basılı tutun.", names, 0)
        val rendered = IconText.render(restored, listOf(IconSlot(TextBox(0.0, 0.0, 0.0, 0.0), "A", "data:image/png;base64,AAAA")))
        assertEquals("Koşmak için basılı tutun.", rendered.text)
        assertEquals(0, rendered.icons.single().at)
    }

    @Test
    fun iconThatCouldNotBeCutFallsBackToTheReadText() {
        val restored = IconText.restore("Koşmak için Feldor'u basılı tutun.", listOf("Feldor"), 0)
        val rendered = IconText.render(restored, listOf(IconSlot(TextBox(0.0, 0.0, 0.0, 0.0), "A")))
        assertEquals("Koşmak için A basılı tutun.", rendered.text)
        assertTrue(rendered.icons.isEmpty())
    }

    private class Translator(private val answer: (String) -> String) : TextTranslator {
        val calls = mutableListOf<String>()
        override fun translate(text: String): String {
            synchronized(calls) { calls.add(text) }
            return answer(text)
        }
    }

    private val turkish: (String) -> String = { if (it == "Hold Feldor to sprint.") "Koşmak için Feldor'u basılı tutun." else it }

    @Test
    fun screenTranslationShowsTheButtonInsideTheTranslation() {
        val translator = Translator(turkish)
        val items = ScreenTranslation.translate(Reading(listOf(hold)), translator, frame = holdFrame())
        assertEquals(listOf("Hold Feldor to sprint."), translator.calls)
        val item = items.single()
        assertEquals("Koşmak için basılı tutun.", item.translation)
        assertEquals("Hold to sprint.", item.source)
        val icon = item.icons!!.single()
        assertEquals(12, icon.at)
        assertTrue(icon.image.startsWith("data:image/png;base64,"))
        // TV'ye giden "screen" olayında simgenin yeri ve resmi.
        val json = SubtitleServer.screenFrame(items, 12000)
        assertTrue(json, json.contains("\"icons\":[{\"at\":12,\"src\":\"data:image/png;base64,"))
    }

    private class Recorder : RegionSender {
        val sent = mutableListOf<Pair<String, List<IconPlacement>?>>()
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            sent.add(text to null)
        }
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?) {
            sent.add(text to icons)
        }
        override fun clearRegions() {}
    }

    @Test
    fun extraAreaShowsTheButtonInsideTheTranslation() {
        // Alan karenin tamamı: okunan alanın kutuları kareyle aynı.
        val area = ExtraArea("tip", "Tip", CropRegion(top = 0.0, bottom = 1.0, left = 0.0, right = 1.0))
        val recorder = Recorder()
        val watcher = RegionWatcher({ Reading(listOf(hold)) }, Translator(turkish), recorder)
        val frame = holdFrame()
        val signature = ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { 10 }
        repeat(2) { watcher.pass(setOf(area.id), listOf(area to RegionWatcher.Crop(Unit, signature, frame))) }
        val (text, icons) = recorder.sent.single()
        assertEquals("Koşmak için basılı tutun.", text)
        assertEquals(12, icons!!.single().at)
    }

    @Test
    fun regionEventCarriesTheIcons() {
        val frame = SubtitleServer.regionFrame("q", "Koşmak için basılı tutun.", null, null, listOf(IconPlacement(12, "data:image/png;base64,AAAA")))
        assertEquals("event: region\ndata: {\"icons\":[{\"at\":12,\"src\":\"data:image/png;base64,AAAA\"}],\"id\":\"q\"," +
            "\"text\":\"Koşmak için basılı tutun.\"}\n\n", frame)
        // Simgesiz çeviri eskisi gibi gider.
        assertTrue(!SubtitleServer.regionFrame("q", "Tamam", null, null).contains("icons"))
    }

    /**
     * GTA 6 haritasının açık mavi denizinde beyaz ✕ simgesi: zemin noktaları renkli sayılıp simge tanınmıyor, "SET
     * DESTINATION ✕" çevirisi simgeyi örtüyordu (Mac ve Windows ile aynı durum). Düz renkli resim yine simge değildir.
     */
    @Test
    fun whiteIconOnLightSeaIsColourless() {
        val size = 40
        fun sea(x: Int, y: Int): Int {
            val ring = kotlin.math.abs(kotlin.math.sqrt(((x - 20) * (x - 20) + (y - 20) * (y - 20)).toDouble()) - 12)
            return if (ring < 2) 0xFFFFFF else 0x3A94BB
        }
        val frame = GrayFrame(ByteArray(size * size) { 120 }, size, size)
        assertTrue(ButtonIcons.isColourless(frame, ::sea, TextBox(0.0, 0.0, 1.0, 1.0)))
        org.junit.Assert.assertFalse(ButtonIcons.isColourless(frame, { _, _ -> 0xF050C8 }, TextBox(0.0, 0.0, 1.0, 1.0)))
    }
}
