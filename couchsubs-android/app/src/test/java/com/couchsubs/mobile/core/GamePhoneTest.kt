// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

/** Sınama karesi: her pikselin rengi (0xRRGGBB) verilen kuraldan. */
internal class TestPhoneImage(override val width: Int, override val height: Int, color: (Int, Int) -> Int) : PhoneImage {
    private val pixels = IntArray(width * height) { color(it % width, it / width) }

    override fun rgb(x: Int, y: Int): Int = pixels[y * width + x]
    override fun tone(x: Int, y: Int): Int {
        val c = pixels[y * width + x]
        return 77 * ((c shr 16) and 0xff) + 150 * ((c shr 8) and 0xff) + 29 * (c and 0xff)
    }

    companion object {
        fun rgb(r: Int, g: Int, b: Int) = ((r and 0xff) shl 16) or ((g and 0xff) shl 8) or (b and 0xff)
        fun gray(g: Int) = rgb(g, g, g)

        /**
         * Telefon indirildi: telefonun yerinde düz zemin. Kamerasız telefon (`phone(camera = false)`) yalnız sıkı aramayı
         * ıskalatır; izleyici onu iziyle ([PhonePrint]) yerinde tutar.
         */
        fun gone() = TestPhoneImage(400, 225) { _, _ -> gray(85) }

        /** 400×225 karede dik duran telefon: gövde, ekran, hoparlör yuvası, kamera ve alt yuva. [patch]: sol, üst, en, boy. */
        fun phone(casing: Int = 110, slot: Int = 25, camera: Boolean = true, patch: IntArray? = null) = TestPhoneImage(400, 225) { x, y ->
            var gray = 85
            if (x in 160 until 244 && y in 22 until 201) gray = casing
            if (x in 164 until 240 && y in 40 until 181) gray = 195
            if (x in 196 until 209 && y in 33 until 35) gray = slot
            if (camera && x in 212 until 215 && y in 33 until 36) gray = slot
            if (x in 198 until 207 && y in 189 until 191) gray = slot
            if (x in 198 until 207 && y in 170 until 172) gray = 24
            if (patch != null && x in patch[0] until patch[0] + patch[2] && y in patch[1] until patch[1] + patch[3]) gray = 35
            gray(gray)
        }
    }
}

/** Tek renkli kare (bellek ayırmadan). */
private class FlatPhoneImage(override val width: Int, override val height: Int, private val color: Int) : PhoneImage {
    override fun rgb(x: Int, y: Int): Int = color
    override fun tone(x: Int, y: Int): Int = 77 * ((color shr 16) and 0xff) + 150 * ((color shr 8) and 0xff) + 29 * (color and 0xff)
}

/** Mac/iPhone GamePhoneVisionTests.swift (GamePhoneTrackerTests) ve Windows GamePhoneTrackerTests.cs ile aynı vektörler. */
class GamePhoneTrackerTest {
    @Test
    fun twoAlignedObservationsAndFirstMissingPhone() {
        val tracker = GamePhoneTracker()
        val image = TestPhoneImage.phone()
        assertNull(tracker.sample(image, 0).pose)
        assertFalse(tracker.sample(image, 250).sampled)
        assertNotNull(tracker.sample(image, 330).pose)
        // Açık telefon kısa süre bulunamayınca kapanmaz (panel kaybolup gelmesin); son görülmeden ~1 sn sonra, üçüncü
        // ıskada kapanır (#1334; önceden dördüncü ıskada, ~1,3 sn).
        val missing = TestPhoneImage.gone()
        assertNotNull(tracker.sample(missing, 660).pose)
        assertNotNull(tracker.sample(image, 990).pose)
        assertNotNull(tracker.sample(missing, 1320).pose)
        assertNotNull(tracker.sample(missing, 1650).pose)
        assertNull(tracker.sample(missing, 1980).pose)
        assertNull(tracker.sample(missing, 2310).pose)
        // Kapandıktan sonra yeniden açılış yine iki gözlem ister.
        assertNull(tracker.sample(image, 2640).pose)
        assertNotNull(tracker.sample(image, 2970).pose)
        tracker.reset()
        assertNull(tracker.sample(image, 2971).pose)
    }

    @Test
    fun movingHandsetRequiresNewConfirmationAndSubtitleBarAloneIsIgnored() {
        val game = TestPhoneImage(400, 225) { _, y -> TestPhoneImage.gray(if (y in 180 until 192) 210 else 32) }
        assertNull(GamePhoneGeometry.locate(game))
        var x = 0.4
        val tracker = GamePhoneTracker { GamePhoneGeometry.Pose(x, 0.16, x, 0.82) }
        assertNull(tracker.sample(game, 0).pose)
        x = 0.55
        assertNull(tracker.sample(game, 400).pose)
        assertEquals(x, tracker.sample(game, 800).pose!!.topX, 0.0)
    }

    @Test
    fun realBezelAndCameraRequiredEvenWithHigherContrastTextStroke() {
        for ((casing, slot) in listOf(110 to 25, 55 to 23)) {
            val pose = GamePhoneGeometry.locate(TestPhoneImage.phone(casing, slot))!!
            assertTrue(pose.topY * 225 in 32.0..35.0)
            assertTrue(pose.bottomY * 225 in 188.0..191.0)
            assertNull(GamePhoneGeometry.locate(TestPhoneImage.phone(casing, slot, camera = false)))
        }
    }

    /** Yayın çözünürlüğü ızgaradan büyükken de aynı telefon bulunur (1600×900: her ızgara hücresi 4×4 piksel). */
    @Test
    fun sameHandsetIsFoundAtStreamResolution() {
        val small = TestPhoneImage.phone()
        val large = TestPhoneImage(1600, 900) { x, y -> small.rgb(x / 4, y / 4) }
        assertEquals(GamePhoneGeometry.locate(small), GamePhoneGeometry.locate(large))
    }

    /**
     * PS Remote Play / chiaki-ng / OBS penceresinden okunan kare 16:9 değildir (başlık çubuğu, siyah şeritler). Telefon
     * önceden yalnız tam 16:9 karede aranıyordu; pencerede hiç bulunmuyordu. Şimdi oyun görüntüsü karenin içinde bulunur,
     * telefonun yeri karenin tamamına göre verilir (Mac ve Windows'ta aynı deneme).
     */
    @Test
    fun phoneIsFoundInsideARemotePlayWindow() {
        val phone = TestPhoneImage.phone()
        val direct = GamePhoneGeometry.locate(phone)!!
        // Başlık çubuğu + tam oturan görüntü; başlık çubuğu + üstte/altta siyah şerit; başlık çubuğu + yanlarda şerit.
        for (layout in listOf(intArrayOf(400, 256, 31, 0, 31), intArrayOf(400, 300, 31, 0, 56), intArrayOf(470, 256, 31, 35, 31))) {
            val (width, height, title, left) = layout
            val top = layout[4]
            fun window(picture: PhoneImage) = TestPhoneImage(width, height) { x, y ->
                when {
                    y < title -> TestPhoneImage.gray(if (x in 8 until 120 && y in title / 3 until title * 2 / 3 && x % 4 < 2) 30 else 220)
                    x in left until left + 400 && y in top until top + 225 -> picture.rgb(x - left, y - top)
                    else -> 0
                }
            }
            val frame = window(phone)
            assertEquals(layout.toList().toString(), GamePhoneGeometry.Area(left, top, 400, 225),
                GamePhoneGeometry.picture(width, height) { x, y -> frame.tone(x, y) shr 8 })
            val pose = GamePhoneGeometry.locate(frame)!!
            assertEquals(left + direct.topX * 400, pose.topX * width, 0.5)
            assertEquals(top + direct.topY * 225, pose.topY * height, 0.5)
            assertEquals(top + direct.bottomY * 225, pose.bottomY * height, 0.5)
            // Telefonsuz görüntü pencerede de telefon sayılmaz.
            assertNull(GamePhoneGeometry.locate(window(TestPhoneImage(400, 225) { _, _ -> TestPhoneImage.gray(85) })))
        }
    }
}

/** Mac/iPhone ve Windows GamePhoneFalsePositiveTests ile aynı vektörler (büyük kutu koruması: SubtitleServerTest). */
class GamePhoneFalsePositiveTest {
    @Test
    fun flatDarkScreensDoNotOpenPhone() {
        for (color in listOf(0x24272a, 0x000000, 0x1a1c22)) {
            val image = FlatPhoneImage(1920, 1080, color)
            val tracker = GamePhoneTracker()
            tracker.sample(image, 0)
            assertNull(tracker.sample(image, 400).pose)
        }
    }

    @Test
    fun implausiblePhoneBoxIsRejected() {
        fun plausible(top: Double, bottom: Double, left: Double, right: Double) =
            GamePhoneTracker.plausible(CropRegion(top, bottom, left, right), 1920, 1080)
        assertTrue(plausible(0.15, 0.85, 0.45, 0.64))
        assertFalse(plausible(0.0, 1.0, 0.0, 1.0))
        assertFalse(plausible(0.05, 0.95, 0.2, 0.8))
        assertFalse(plausible(0.6, 0.75, 0.4, 0.95))
        assertFalse(plausible(0.15, 0.85, 0.02, 0.2))
        assertFalse(plausible(0.0, 0.5, 0.5, 0.64))
        assertFalse(plausible(0.5, 0.6, 0.6, 0.63))
    }

    @Test
    fun trackerNeverOpensAFullScreenPhone() {
        val image = FlatPhoneImage(1920, 1080, 0x24272a)
        // Bu poz ekranın tamamını kaplayan telefon kutusu verir.
        val tracker = GamePhoneTracker { GamePhoneGeometry.Pose(0.5, 0.0, 0.5, 1.0) }
        tracker.sample(image, 0)
        assertNull(tracker.sample(image, 400).pose)
    }
}

/** Mac/iPhone GamePhonePaletteTests ve Windows GamePhonePaletteTests.cs ile aynı vektörler. */
class GamePhonePaletteTest {
    private fun hex(r: Int, g: Int, b: Int) = String.format(Locale.ROOT, "#%02X%02X%02X", r, g, b)

    @Test
    fun surfaceAndInkComeFromInsideTheBox() {
        for ((color, ink) in listOf(Triple(224, 232, 224) to 24, Triple(32, 64, 120) to 248)) {
            val (r, g, b) = color
            val image = TestPhoneImage(120, 50) { x, y ->
                if (x !in 15 until 105 || y !in 10 until 40) TestPhoneImage.rgb(255, 0, 196)
                else if (x % 13 < 3) TestPhoneImage.gray(ink) else TestPhoneImage.rgb(r, g, b)
            }
            val style = GamePhonePalette.sample(image, TextBox(0.125, 0.2, 0.875, 0.8))
            assertEquals(hex(r, g, b), style.background)
            assertEquals(hex(ink, ink, ink), style.foreground)
        }
    }

    @Test
    fun lowContrastBlueKeepsLightInkAndPhotosGetNeutralColors() {
        val box = TextBox(0.0, 0.0, 1.0, 1.0)
        val blue = TestPhoneImage(90, 30) { x, _ -> if (x % 13 < 3) TestPhoneImage.rgb(230, 239, 246) else TestPhoneImage.rgb(88, 120, 192) }
        assertEquals(TextSurface("#5070B8", "#FFFFFF"), GamePhonePalette.sample(blue, box))
        for (step in 0..1) {
            val photo = TestPhoneImage(96, 54) { x, y -> TestPhoneImage.rgb(3 * x + step * 80, y * 4, (x + y) * 3) }
            assertEquals(GamePhonePalette.neutral, GamePhonePalette.sample(photo, box))
        }
    }
}

/** Mac/iPhone GamePhoneReaderTests ve Windows GamePhoneReaderTests.cs ile aynı vektörler. */
class GamePhoneReaderTest {
    private val box = TextBox(0.2, 0.25, 0.6, 0.35)

    /** Düzleştirilmiş görüntüde [box]'ın dört köşesindeki parlaklık ([scale] ile kare koordinatına çevrilir). */
    private fun probe(image: PhoneImage, pose: GamePhoneGeometry.Pose, scale: Int, samples: MutableList<Int>): Reading =
        GamePhoneReader.read(image, pose.bounds, pose) { flat ->
            assertEquals(0, flat.width % 2)
            assertEquals(0, flat.height % 2)
            for (v in listOf(box.top, box.bottom)) for (u in listOf(box.left, box.right)) {
                val x = (u * flat.width).toInt().coerceIn(0, flat.width - 1)
                val y = (v * flat.height).toInt().coerceIn(0, flat.height - 1)
                samples.add((flat.nv21[y * flat.width + x].toInt() and 0xff) * scale)
            }
            Reading(listOf(TextLine("Notice", box, words = listOf(TextWord("Notice", box)), icons = listOf(IconSlot(box, "X")))))
        }

    /** Android yazıyı parlaklıktan okur: yatay ve dikey yer iki ayrı gri geçişle (x/4 ve y/2) ölçülür. */
    @Test
    fun deskewInBothDirectionsMapsWordsAndIconsToOriginalPixels() {
        val across = TestPhoneImage(800, 450) { x, _ -> TestPhoneImage.gray(x / 4) }
        val down = TestPhoneImage(800, 450) { _, y -> TestPhoneImage.gray(y / 2) }
        for (tilt in listOf(-0.06, 0.06)) {
            val pose = GamePhoneGeometry.Pose(0.50, 0.16, 0.50 + tilt, 0.82)
            val xs = mutableListOf<Int>()
            val ys = mutableListOf<Int>()
            val result = probe(across, pose, 4, xs)
            probe(down, pose, 2, ys)
            val line = result.lines.first()
            val mapped = line.box!!.placedIn(pose.bounds.box)
            assertEquals(4, xs.size)
            assertEquals(xs.min().toDouble(), mapped.left * 800, 5.0)
            assertEquals(xs.max().toDouble(), mapped.right * 800, 5.0)
            assertEquals(ys.min().toDouble(), mapped.top * 450, 3.0)
            assertEquals(ys.max().toDouble(), mapped.bottom * 450, 3.0)
            assertEquals(box, line.phoneBox)
            assertEquals(line.box, line.words!!.first().box)
            assertEquals(line.box, line.icons!!.first().box)
        }
    }

    @Test
    fun changingGlyphsInsideEachBubbleButNotNoiseOrOutsideVideoInvalidatesPage() {
        val region = CropRegion(top = 0.0, bottom = 1.0, left = 0.0, right = 1.0)
        val bubble = TextBox(0.2, 0.3, 0.8, 0.6)
        fun image(mode: Int) = TestPhoneImage(100, 50) { x, y ->
            var g = if (mode == 0) 85 else 89
            if (mode > 0 && x < 12) g = 200
            if (mode > 0 && x == 30 && y == 20) g = 220
            if (mode == 2 && x in 45 until 48 && y in 20 until 25) g = 210
            TestPhoneImage.gray(g)
        }
        val page = GamePhonePage(image(0), region, Reading(listOf(TextLine("Hey", bubble))))
        assertFalse(page.changed(image(1), region))
        assertTrue(page.changed(image(2), region))
    }
}

/** Mac/iPhone GamePhoneTextTests.swift ve Windows GamePhoneTextTests.cs ile aynı vektörler. */
class GamePhoneTextTest {
    private fun line(text: String, y: Double, left: Double = 0.2, right: Double = 0.8) =
        TextLine(text, TextBox(left, y, right, y + 0.031))

    @Test
    fun captionsRemainTranslatableButStandaloneTagsAndUserNamesStayInTheGame() {
        val reading = Reading(listOf(line("@vice.305", 0.63), line("Meet me #NightRide", 0.68),
            line("#sunset #leonida", 0.73), line("Tell @vice.305 to wait.", 0.80)))
        val kept = GamePhoneText.forTranslation(reading)
        assertEquals(listOf("Meet me #NightRide", "Tell @vice.305 to wait."), GamePhoneText.groups(kept).flatMap { it.paragraphs })
        val source = "Send the photo to @KaterinaDiva."
        assertEquals("Fotoğrafı @KaterinaDiva'ya gönder.", GamePhoneText.keepIdentifiers(source, "Fotoğrafı @katerinadiva'ya gönder."))
        assertNull(GamePhoneText.keepIdentifiers(source, "Fotoğrafı ona gönder."))
        assertNull(GamePhoneText.keepIdentifiers(source, "Fotoğrafı @Joey'e gönder."))
    }

    @Test
    fun englishShorthandAndNumericOcrCorrectionRespectNamesAndCodes() {
        val text = "We're in this 2gether. I left it 4u."
        assertEquals("We're in this together. I left it for you.", GamePhoneText.englishModelInput(text))
        assertEquals(listOf(text), GamePhoneText.groups(Reading(listOf(line(text, 0.5)))).flatMap { it.paragraphs })
        val codes = "Use B4, @4u, #2gether or gate C4."
        assertEquals(codes, GamePhoneText.englishModelInput(codes))
        assertEquals("10 min out.", GamePhoneText.englishModelInput("IO min out."))
        assertEquals("IO port. I owe him.", GamePhoneText.englishModelInput("IO port. I owe him."))
    }

    @Test
    fun contactsAreMarkedOnlyInRecognizableMessageListAndCutWordsAreNeverCompleted() {
        val rows = listOf(line("Suggestions", 0.04), line("Chase", 0.12), line("call me after ...", 0.16),
            line("May", 0.25), line("Don't leave yet.", 0.29), line("Messages", 0.42),
            line("Rose", 0.54), line("Meet me at 06:40.", 0.58))
        val kept = GamePhoneText.forTranslation(Reading(rows))
        assertEquals(listOf("Suggestions", "Chase", "call me after...", "May", "Don't leave yet.", "Messages", "Rose",
            "Meet me at 06:40."), kept.lines.map { it.text })
        assertEquals(listOf(HEADING, CONTACT, PREVIEW, CONTACT, PREVIEW, HEADING, CONTACT, PREVIEW), kept.lines.map { it.listRole })
        // Tek başlık da yeter: sallanan telefonda biri bir okumada kaçabilir.
        assertEquals(listOf(CONTACT, PREVIEW, CONTACT, PREVIEW, HEADING, CONTACT, PREVIEW),
            GamePhoneText.forTranslation(Reading(rows.drop(1))).lines.map { it.listRole })
        // Başlıksız ve kesik önizlemesiz üç ad-yanıt çifti liste sayılmaz.
        val plain = rows.filter { GamePhoneText.section(it.text) == null && !it.text.endsWith("...") }
        assertTrue(GamePhoneText.forTranslation(Reading(plain)).lines.all { it.listRole == null })
    }

    /**
     * Başlığın simgesi yazı tanımada tek harf ya da işaret olarak okunur ("g Suggested"): artık atılır, satır yine
     * başlıktır. Başlık içeren gerçek cümle başlık değildir.
     */
    @Test
    fun headingIconResidueIsDropped() {
        for (text in listOf("g Suggested", "✱ Suggested", "Suggested", "Messages ☆", "• Messages", "O Messages")) {
            assertNotNull(text, GamePhoneText.section(text))
        }
        for (text in listOf("Suggested items", "My Messages", "Messages from Joey", "Send Messages now")) {
            assertNull(text, GamePhoneText.section(text))
        }
    }

    /**
     * LG, beta.93: GTA 6 Mesajlar ekranı (fotoğraftaki sıra). Telefon sallanırken her okuma başka: başlığın simgesi bir
     * "g" okunur, bir okunmaz; "Messages" bir okumada kaçar; kutular birkaç piksel oynar. Liste her okumada liste, satırlar
     * aynı sırada ve aynı rolde kalır; kişi adları ayrı satırdır.
     */
    @Test
    fun swayingMessageListKeepsItsRolesInEveryRead() {
        fun rows(dy: Double, suggested: String?, messages: Boolean): Reading {
            fun flat(text: String, y: Double, left: Double, right: Double = 0.95): TextLine {
                val box = TextBox(left + dy / 2, y + dy, right + dy / 2, y + dy + 0.031)
                return TextLine(text, box, phoneBox = box)
            }
            val lines = mutableListOf<TextLine>()
            if (suggested != null) lines += flat(suggested, 0.04, 0.05, 0.40)
            lines += listOf(flat("Cal", 0.10, 0.30, 0.38), flat("$ in your mailbox. You bailed", 0.14, 0.30),
                flat("Brian", 0.22, 0.30, 0.42), flat("Ok. There's some cash in t...", 0.26, 0.30))
            if (messages) lines += flat("Messages", 0.33, 0.03, 0.30)
            lines += listOf(flat("Donnie", 0.40, 0.30, 0.45),
                flat("Joey", 0.50, 0.30, 0.40), flat("Hey this is Joey from Coa...", 0.54, 0.30),
                flat("Lucia (Yolanda phone)", 0.62, 0.30, 0.70), flat("Outside living better than ...", 0.66, 0.30),
                flat("Shirley", 0.74, 0.30, 0.45), flat("Oh that's nice hon. aren't ...", 0.78, 0.30),
                flat("Rusty Anchor", 0.88, 0.30, 0.62))
            return Reading(lines)
        }
        val expected = listOf(
            "Suggested" to HEADING, "Cal" to CONTACT, "$ in your mailbox. You bailed" to PREVIEW, "Brian" to CONTACT,
            "Ok. There's some cash in t..." to PREVIEW, "Messages" to HEADING, "Donnie" to CONTACT, "Joey" to CONTACT,
            "Hey this is Joey from Coa..." to PREVIEW, "Lucia (Yolanda phone)" to CONTACT,
            "Outside living better than..." to PREVIEW, "Shirley" to CONTACT, "Oh that's nice hon. aren't..." to PREVIEW,
            "Rusty Anchor" to CONTACT)
        val reads = listOf<Pair<String?, Boolean>>("Suggested" to true, "g Suggested" to true, "✱ Suggested" to false,
            null to true, null to false)
        for ((index, read) in reads.withIndex()) {
            val (suggested, messages) = read
            val groups = GamePhoneText.groups(GamePhoneText.forTranslation(rows(0.002 * index, suggested, messages)))
            val wanted = expected.filter { (suggested != null || it.first != "Suggested") && (messages || it.first != "Messages") }
            assertEquals("$index", wanted.map { it.first }, groups.map { it.paragraphs.joinToString("") })
            assertEquals("$index", wanted.map { it.second }, groups.map { it.phone?.role })
        }
    }

    /** Kesik önizleme kesik çevrilir: yarım son sözcük ve sarkan edat çeviriye gitmez, çeviri "..." ile biter. */
    @Test
    fun cutPreviewIsTranslatedWithoutTheBrokenWord() {
        assertEquals("Hey this is Joey", GamePhoneText.cutInput("Hey this is Joey from Coa..."))
        assertEquals("Ok. There's some cash", GamePhoneText.cutInput("Ok. There's some cash in t..."))
        assertEquals("Outside living better", GamePhoneText.cutInput("Outside living better than..."))
        assertEquals("Oh that's nice hon.", GamePhoneText.cutInput("Oh that's nice hon. aren't..."))
        assertEquals("Call me", GamePhoneText.cutInput("Call me, then…"))
        assertNull(GamePhoneText.cutInput("Meet me at 6."))
        assertNull(GamePhoneText.cutInput("Coa..."))
        assertEquals("Selam, ben Joey...", GamePhoneText.cutTranslation("Selam, ben Joey."))
        assertEquals("Dışarıda yaşamak daha iyi...", GamePhoneText.cutTranslation("Dışarıda yaşamak daha iyi"))
    }

    /**
     * Sinan Bey (beta.100, 3399): "…" koymadan satır sonunda kesilen önizleme ("$ in your mailbox. You bailed") bağlamsız
     * çevrilip uyduruluyordu ("Posta kutunda. Beni aradın"; "$" düşmüş). Sohbette tam çevirisi bilinen mesajın önizlemesi o
     * çevirinin başı + "..."; bilinmiyorsa kesik metin "..." ipucuyla gider, sonu tamamlanmaz; baştaki "$" düşmez (iPhone
     * ile aynı).
     */
    @Test
    fun clippedPreviewUsesTheKnownChatTranslationOrStaysCut() {
        assertEquals("$ in your mailbox. You bailed", GamePhoneText.clippedInput("$ in your mailbox. You bailed"))
        assertEquals("Meet me", GamePhoneText.clippedInput("Meet me at the"))
        assertNull(GamePhoneText.clippedInput("See you there."))
        assertNull(GamePhoneText.clippedInput("Okay"))
        assertEquals("Meet me...", GamePhoneText.cutHint("Meet me"))
        assertEquals("$ Posta kutunda", GamePhoneText.keepingLeadingSymbol("$ in your mailbox", "Posta kutunda"))
        assertEquals("$ posta kutunda", GamePhoneText.keepingLeadingSymbol("$ in your mailbox", "$ posta kutunda"))
        assertEquals("Posta kutunda", GamePhoneText.keepingLeadingSymbol("in your mailbox", "Posta kutunda"))
        val known = mapOf("$ in your mailbox. You bailed me out again bro! You got away right? Tell me you got away. LMK!" to
            "$ posta kutunda. Beni yine kurtardın, kanka! Kaçtın, değil mi? Kaçtığını söyle bana. Haber ver!",
            "I'm good. Thanks for the cash." to "İyiyim. Para için sağ ol.")
        val preview = GamePhoneText.knownPreview("$ in your mailbox. You bailed", known)!!
        assertTrue(preview, preview.startsWith("$ posta kutunda."))
        assertTrue(preview, preview.endsWith("..."))
        assertTrue(preview, preview.length < 50)
        assertEquals("her seferinde aynı", preview, GamePhoneText.knownPreview("$ in your mailbox. You bailed", known))
        // "…" ile kesik önizlemenin yarım sözcüğü eşleşmeye girmez.
        assertNotNull(GamePhoneText.knownPreview("$ in your mailbox. You bai...", known))
        assertNull("bilinmeyen mesaj uydurulmaz", GamePhoneText.knownPreview("Hey this is Joey from Coa...", known))
        assertNull("çok kısa önizleme eşleşmez", GamePhoneText.knownPreview("I'm good", known))
        // Para simgesi kumanda simgesi değildir; telefon yolunda tek başına "$" okuma çöpü sayılmaz.
        assertFalse(ButtonIcons.isIconToken("$"))
        assertEquals("$ in your mailbox", OcrNoise.clean("$ in your mailbox", keepIdentifiers = true))
    }

    /**
     * Ana ekran bileşeni (Sinan Bey, beta.100 3397): başlık ve sayaç tek grup, iki parça ("Reminders", "6 Notifications");
     * rolü WIDGET. Tek satır okunan "Reminders 6 Notifications" de ikiye ayrılır. Uygulama adı ("WhatUp") çevrilmez.
     */
    @Test
    fun homeWidgetIsOneGroupWithTitleAndCounter() {
        fun flat(text: String, left: Double, top: Double, right: Double): TextLine {
            val box = TextBox(left, top, right, top + 0.028)
            return TextLine(text, box, phoneBox = box)
        }
        val lines = listOf(flat("Reminders", 0.16, 0.12, 0.45), flat("6 Notifications", 0.05, 0.155, 0.5), flat("WhatUp", 0.38, 0.86, 0.62))
        val groups = GamePhoneText.groups(Reading(lines))
        assertEquals(listOf(listOf("Reminders", "6 Notifications")), groups.map { it.paragraphs })
        assertEquals(ScreenPhoneCard.Role.WIDGET, groups.first().phone?.role)
        assertEquals("6 Notifications", GamePhoneText.widgetParts("Reminders 6 Notifications")?.second)
        assertNull(GamePhoneText.widgetParts("Call me 6 times"))
    }

    private companion object {
        val HEADING = ScreenPhoneCard.Role.HEADING
        val CONTACT = ScreenPhoneCard.Role.CONTACT
        val PREVIEW = ScreenPhoneCard.Role.PREVIEW
    }

    @Test
    fun opposingRepliesAndWrappedMessagesUseFlatDisplayCoordinates() {
        val rows = listOf(line("Find someone who", 0.30, 0.10, 0.69), line("knows this road.", 0.334, 0.10, 0.64),
            line("on my way", 0.372, 0.38, 0.93))
        assertEquals(listOf("Find someone who knows this road.", "on my way"), GamePhoneText.groups(Reading(rows)).flatMap { it.paragraphs })
        fun tilted(text: String, x: Double, y: Double, right: Double) =
            TextLine(text, TextBox(x, y, right, y + 0.068), phoneBox = TextBox(x, y, right, y + 0.026))
        val angled = listOf(tilted("That was quite a", 0.1, 0.20, 0.75), tilted("surprise!", 0.1, 0.237, 0.35),
            tilted("Did you see it?", 0.1, 0.325, 0.70), tilted("Ask later", 0.52, 0.78, 0.88),
            tilted("No problem", 0.50, 0.862, 0.88))
        val groups = GamePhoneText.groups(Reading(angled))
        assertEquals(listOf("That was quite a surprise!", "Did you see it?", "Ask later", "No problem"), groups.flatMap { it.paragraphs })
        assertEquals(angled[0].box!!.union(angled[1].box!!), groups.first().box)
    }
}

/** Mac/iPhone PhoneRegionSessionTests.swift ile aynı senaryolar; Android'de tur ayrı iş parçacığında sürer. */
class PhoneRegionSessionTest {
    private class Reader {
        @Volatile var lines: List<TextLine> = emptyList()
        /** Sonraki okuma hata verir (okunamayan kare). */
        @Volatile var failNext = false
        val count = java.util.concurrent.atomic.AtomicInteger()
        /** Her okumada (OCR sürerken) çağrılır: elde sallanan telefonun yeni karesi gibi. */
        @Volatile var onRead: (() -> Unit)? = null
        fun read(): Reading {
            count.incrementAndGet()
            onRead?.invoke()
            if (failNext) {
                failNext = false
                throw IllegalStateException("okunamadı")
            }
            return Reading(lines)
        }
    }

    /** Geciktirilen çeviri iptali yok sayar: yoldaki bulut yanıtı gibi. */
    private class Translator : TextTranslator {
        override val translatesTogether: Boolean get() = true
        @Volatile var delayed: String? = null
        @Volatile var waiting = false
        private var gate = java.util.concurrent.CountDownLatch(1)
        val calls = java.util.Collections.synchronizedList(mutableListOf<String>())

        fun resume() {
            delayed = null
            gate.countDown()
        }

        override fun translate(text: String): String {
            calls.add(text)
            if (text == delayed) {
                gate = java.util.concurrent.CountDownLatch(1)
                waiting = true
                gate.await()
                waiting = false
            }
            return when (text) {
                "Reply today." -> "Bugün yanıtla."
                "Open the camera." -> "Kamerayı aç."
                "Meet me tomorrow." -> "Yarın buluşalım."
                else -> "Çevrildi: $text"
            }
        }
    }

    private class Sent(val id: String, val text: String, val items: List<ScreenTranslation.Item>)

    private class Server : RegionSender {
        val sent = java.util.Collections.synchronizedList(mutableListOf<Sent>())
        @Volatile var clears = 0
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) = sendRegion(id, text, box, lineHeight, null, null)
        override fun sendRegion(
            id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?, blocks: List<ScreenTranslation.Item>?,
        ) {
            sent.add(Sent(id, text, blocks ?: emptyList()))
        }
        override fun clearRegions() { clears++ }
    }

    private val first = TextBox(0.15, 0.30, 0.85, 0.48)
    private val second = TextBox(0.15, 0.72, 0.85, 0.85)
    private val edit = intArrayOf(183, 94, 36, 12)
    private val work = java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it).apply { isDaemon = true } }
    @Volatile private var clock = 0L

    private fun wait(done: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5000
        while (!done()) {
            check(System.currentTimeMillis() < deadline) { "zaman aşımı" }
            Thread.sleep(1)
        }
    }

    // Bu sınamalar balonların üstündeki düzeni (kararlılık) ölçer; Yanda Panel ScreenPhoneCardTest'te sınanır.
    private fun watcher(reader: Reader, translator: Translator, server: Server) =
        RegionWatcher({ reader.read() }, translator, server, clock = { clock }, readPhone = { reader.read() })
            .apply { phonePanel = { PhonePanelOptions(enabled = false) } }

    private fun RegionWatcher.offer(areas: List<ExtraArea> = emptyList()) = offer(areas, {
        RegionWatcher.Crop(Unit, ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT))
    }) { work.execute(it) }

    /** #1251: eğik ekranın düzeltilmiş okuması boş gelince günlüğe yazılır (önceden sessizdi; Windows, Mac/iPhone ile aynı). */
    @Test
    fun emptyStraightenedPhoneReadingIsLogged() {
        val reader = Reader()
        val watcher = watcher(reader, Translator(), Server())
        val log = java.util.Collections.synchronizedList(mutableListOf<String>())
        watcher.onLog = { log.add(it) }
        val a = TestPhoneImage.phone()
        val pose = GamePhoneGeometry.locate(a)!!
        watcher.observePhone(PhoneCapture(a, pose))
        watcher.offer()
        wait { !watcher.isBusy }
        assertTrue(reader.count.get() > 0)
        assertTrue(log.toString(), log.contains("düşen satır [PhoneTrace] eğik ekran düzeltilmiş okuması boş: \"Phone\""))
    }

    @Test
    fun changedBubbleDropsOldTextWhileKeepingItsTranslatedNeighbor() {
        val reader = Reader()
        val translator = Translator()
        val server = Server()
        val watcher = watcher(reader, translator, server)
        val a = TestPhoneImage.phone()
        val b = TestPhoneImage.phone(patch = edit)
        val pose = GamePhoneGeometry.locate(a)!!
        val unchanged = TextLine("Meet me tomorrow.", second)
        reader.lines = listOf(TextLine("Reply today.", first), unchanged)
        watcher.observePhone(PhoneCapture(a, pose))
        watcher.offer()
        wait { !watcher.isBusy }
        val shown = server.sent.last().items
        assertEquals(listOf("Bugün yanıtla.", "Yarın buluşalım."), shown.map { it.translation })
        assertTrue(shown.all { it.surface != null && it.box.left >= pose.bounds.left && it.box.right <= pose.bounds.right })
        assertTrue(server.sent.all { it.id == "game-phone" })

        reader.lines = listOf(TextLine("Open the camera.", first), unchanged)
        translator.delayed = "Open the camera."
        clock = 450
        watcher.observePhone(PhoneCapture(b, pose))
        watcher.offer()
        wait { translator.waiting }
        assertEquals(listOf("Yarın buluşalım."), server.sent.last().items.map { it.translation })
        translator.resume()
        wait { !watcher.isBusy }
        assertEquals(listOf("Kamerayı aç.", "Yarın buluşalım."), server.sent.last().items.map { it.translation })
        val count = reader.count.get()
        val visibleChanges = server.sent.size
        clock = 900
        watcher.observePhone(PhoneCapture(b, pose))
        watcher.offer()
        wait { !watcher.isBusy }
        assertEquals(count, reader.count.get())
        assertEquals(visibleChanges, server.sent.size)
        assertEquals(1, translator.calls.count { it == "Meet me tomorrow." })
    }

    @Test
    fun oldPageCannotPublishWhenAnotherFrameArrivesDuringTranslation() {
        val reader = Reader()
        val translator = Translator()
        val server = Server()
        val watcher = watcher(reader, translator, server)
        val a = TestPhoneImage.phone()
        val b = TestPhoneImage.phone(patch = edit)
        val pose = GamePhoneGeometry.locate(a)!!
        translator.delayed = "Reply today."
        reader.lines = listOf(TextLine("Reply today.", first))
        watcher.observePhone(PhoneCapture(a, pose))
        watcher.offer()
        wait { translator.waiting }
        reader.lines = listOf(TextLine("Open the camera.", first))
        watcher.observePhone(PhoneCapture(b, pose))
        watcher.offer()
        translator.resume()
        wait { !watcher.isBusy }
        assertTrue(server.sent.isEmpty())
        clock = 450
        watcher.observePhone(PhoneCapture(b, pose))
        watcher.offer()
        wait { !watcher.isBusy }
        assertEquals(listOf("Kamerayı aç."), server.sent.map { it.text })
    }

    /**
     * GTA 6'nın telefonu elde durur, her karede birkaç piksel sallanır: okuma sürerken gelen her yeni karenin yazı
     * pikselleri değişir. Okuma son karede yeniden okunur ve kabul edilir; o okuma sürerken bir kare daha geldi diye
     * atılmaz. Önceden mesajlar ancak telefon tam durduğu nadir anlarda çevriliyordu (#1202, #1197, #1193, #1170; Mac/iPhone
     * ve Windows ile aynı).
     */
    @Test
    fun swayingPhoneStillTranslatesAndShowsNewMessages() {
        val reader = Reader()
        val translator = Translator()
        val server = Server()
        val watcher = watcher(reader, translator, server)
        val pose = GamePhoneGeometry.locate(TestPhoneImage.phone())!!
        val frames = (0 until 4).map { TestPhoneImage.phone(patch = intArrayOf(170 + 12 * it, 94, 10, 12)) }
        val sway = java.util.concurrent.atomic.AtomicInteger()
        reader.onRead = { watcher.observePhone(PhoneCapture(frames[sway.incrementAndGet() % frames.size], pose)) }
        reader.lines = listOf(TextLine("Reply today.", first))
        watcher.observePhone(PhoneCapture(frames[0], pose))
        watcher.offer()
        wait { !watcher.isBusy }
        assertEquals(listOf("Bugün yanıtla."), server.sent.lastOrNull()?.items?.map { it.translation })

        reader.lines = listOf(TextLine("Reply today.", first), TextLine("Meet me tomorrow.", second))
        clock = 450
        watcher.observePhone(PhoneCapture(frames[sway.get() % frames.size], pose))
        watcher.offer()
        wait { !watcher.isBusy }
        assertEquals(listOf("Bugün yanıtla.", "Yarın buluşalım."), server.sent.lastOrNull()?.items?.map { it.translation })
    }

    /**
     * LG, beta.93: GTA 6 Mesajlar ekranı elde sallanırken TV'deki panel her saniye liste ile sohbet balonları arasında
     * gidip geliyordu. Pikselleri biraz farklı, başlığı bir "g" ile bir simgesiz okunan art arda okumalarda sayfa liste
     * kalır, aynı görüntü yeniden gönderilmez; tek bir sohbet gibi okunan kare türü değiştirmez, art arda iki okuma
     * değiştirir (iPhone ile aynı).
     */
    @Test
    fun swayingMessageListKeepsTheListLayout() {
        val reader = Reader()
        val translator = Translator()
        val server = Server()
        // Yanda Panel açık: liste satırları panelde sola yaslı dizilir.
        val watcher = RegionWatcher({ reader.read() }, translator, server, clock = { clock }, readPhone = { reader.read() })
        val pose = GamePhoneGeometry.locate(TestPhoneImage.phone())!!
        fun row(text: String, y: Double, left: Double, right: Double, dy: Double) =
            TextLine(text, TextBox(left, y + dy, right, y + dy + 0.031))
        fun list(heading: String, dy: Double) = listOf(
            row(heading, 0.04, 0.05, 0.40, dy), row("Cal", 0.10, 0.30, 0.38, dy), row("$ in your mailbox. You bailed", 0.14, 0.30, 0.95, dy),
            row("Brian", 0.22, 0.30, 0.42, dy), row("Ok. There's some cash in t...", 0.26, 0.30, 0.95, dy),
            row("Messages", 0.33, 0.03, 0.30, dy), row("Donnie", 0.40, 0.30, 0.45, dy),
            row("Joey", 0.50, 0.30, 0.40, dy), row("Hey this is Joey from Coa...", 0.54, 0.30, 0.95, dy),
            row("Shirley", 0.74, 0.30, 0.45, dy), row("Oh that's nice hon. aren't ...", 0.78, 0.30, 0.95, dy),
            row("Rusty Anchor", 0.88, 0.30, 0.62, dy))
        // Liste gibi okunamayan kare: yalnız iki ad-önizleme çifti, başlık ve kesik önizleme yok.
        val chat = listOf(row("Joey", 0.50, 0.30, 0.40, 0.0), row("Hey this is Joey from home.", 0.54, 0.30, 0.95, 0.0),
            row("Shirley", 0.74, 0.30, 0.45, 0.0), row("Oh that's nice hon.", 0.78, 0.30, 0.95, 0.0))
        var step = 0
        fun read(lines: List<TextLine>) {
            reader.lines = lines
            clock = 450L * step
            val frame = TestPhoneImage.phone(patch = intArrayOf(170 + 6 * (step % 10), 60 + 4 * step, 10, 12))
            watcher.observePhone(PhoneCapture(frame, pose))
            watcher.offer()
            step++
            wait { !watcher.isBusy }
        }
        read(list("Suggested", 0.0))
        // Bölüm başlıkları küçük başlık (sola yaslı, kalın not); her kişi satırı tek kart (ad + önizleme; Sinan Bey, beta.100
        // 3399). "…" ile ya da satır sonunda kesilmiş önizleme kesik çevrilir, "$" düşmez (iPhone ile aynı).
        val shown = server.sent.last().items
        val notes = shown.filter { it.panel == ScreenPhoneCard.PanelPart.NOTE }
        assertEquals(listOf("Çevrildi: Suggested", "Çevrildi: Messages"), notes.map { it.translation })
        assertTrue("başlık sola yaslı, kalın", notes.all { it.look?.align == "left" && it.look?.bold == true })
        val cards = shown.mapNotNull { it.listRow }
        assertEquals(listOf("Cal", "Brian", "Donnie", "Joey", "Shirley", "Rusty Anchor"), cards.map { it.name })
        assertEquals(listOf("Çevrildi: $ in your mailbox. You bailed...", "Çevrildi: Ok. There's some cash...", "",
            "Çevrildi: Hey this is Joey...", "Çevrildi: Oh that's nice hon...", ""), cards.map { it.preview })
        val rows = shown.filter { it.panel == ScreenPhoneCard.PanelPart.NOTE || it.panel == ScreenPhoneCard.PanelPart.ROW }
        assertEquals("telefondaki sıra, üst üste binmez", 0, rows.zipWithNext().count { (a, b) -> a.box.bottom > b.box.top + 1e-9 })
        val names = setOf("Cal", "Brian", "Joey", "Donnie", "Shirley", "Rusty Anchor")
        assertFalse("adlar çevrilmez", translator.calls.any { it in names })
        assertFalse("yarım sözcük çeviriye gitmez", translator.calls.any { it.contains("Coa") })
        val sent = server.sent.size

        // Sallanan telefon: kutular birkaç piksel oynar, başlığın simgesi bir "g" okunur; görüntü aynı, yeniden gönderilmez.
        read(list("g Suggested", 0.003))
        read(list("✱ Suggested", -0.002))
        assertEquals(sent, server.sent.size)
        assertFalse(translator.calls.any { it.contains("g Suggested") })

        // Tek bir okuma sohbet gibi geldi: liste kalır.
        read(chat)
        read(list("Suggested", 0.002))
        assertEquals(sent, server.sent.size)

        // Sayfa gerçekten değişti (art arda iki okuma): yeni tür çizilir.
        read(chat)
        assertEquals(sent, server.sent.size)
        read(chat)
        assertTrue(server.sent.size > sent)
        assertFalse(server.sent.last().items.any {
            it.panel == ScreenPhoneCard.PanelPart.ROW || (it.panel == ScreenPhoneCard.PanelPart.NOTE && it.look?.align == "left")
        })
    }

    @Test
    fun closingPhoneWhileTranslationIsPendingLeavesManualRegionAlone() {
        val reader = Reader()
        val translator = Translator()
        val server = Server()
        val watcher = watcher(reader, translator, server)
        val a = TestPhoneImage.phone()
        val b = TestPhoneImage.phone(patch = edit)
        val pose = GamePhoneGeometry.locate(a)!!
        val quest = ExtraArea("q", "Quest", ExtraAreaPreset.QUEST.region)

        reader.lines = listOf(TextLine("Meet me tomorrow.", second))
        watcher.offer(listOf(quest))
        wait { !watcher.isBusy }
        clock = 1000
        watcher.offer(listOf(quest))
        wait { !watcher.isBusy }
        assertEquals(listOf("q"), server.sent.map { it.id })

        reader.lines = listOf(TextLine("Reply today.", first))
        watcher.observePhone(PhoneCapture(a, pose))
        watcher.offer(listOf(quest))
        wait { !watcher.isBusy }
        assertEquals("Bugün yanıtla.", server.sent.last().text)
        val passes = watcher.passes
        translator.delayed = "Open the camera."
        reader.lines = listOf(TextLine("Open the camera.", first))
        clock += 450
        watcher.observePhone(PhoneCapture(b, pose))
        watcher.offer(listOf(quest))
        wait { translator.waiting }
        // İzleyici telefonu kapattı. Bekleyen yanıt oyunun üstüne çizilmez.
        watcher.closePhone()
        watcher.offer(listOf(quest))
        translator.resume()
        wait { !watcher.isBusy }
        assertEquals(listOf("Bugün yanıtla.", ""), server.sent.filter { it.id == "game-phone" }.map { it.text })
        assertEquals(1, server.sent.count { it.id == "q" })
        assertEquals(0, server.clears)
        assertEquals(passes, watcher.passes)
    }

    /**
     * Uzun mesajda yan yana iki sözcükteki OCR sapması bekletilir; ikinci okumada da sürse aynı mesajın OCR'la biraz farklı
     * okunuşudur ([PhoneSteady]): yeniden çevrilmez, ekrandaki çeviri değişmez. Önceden yeniden çevriliyor, çeviri gidip
     * geliyordu (Mac ve Windows ile aynı).
     */
    private fun adjacentTypo(realChange: Boolean) {
        val original = "Cool. I'll check it out. Would be nice to clear my head for a second."
        val alternate = "Cool. I'll check ct ocut. Would be nice to clear my head for a second."
        val reader = Reader()
        val translator = Translator()
        val server = Server()
        val watcher = watcher(reader, translator, server)
        val a = TestPhoneImage.phone()
        val b = TestPhoneImage.phone(patch = intArrayOf(232, 120, 18, 30))
        val pose = GamePhoneGeometry.locate(a)!!
        reader.lines = listOf(TextLine(original, first))
        watcher.observePhone(PhoneCapture(a, pose))
        watcher.offer()
        wait { !watcher.isBusy }
        val sends = server.sent.size
        reader.lines = listOf(TextLine(alternate, first))
        clock = 450
        watcher.observePhone(PhoneCapture(b, pose))
        watcher.offer()
        wait { !watcher.isBusy }
        assertEquals(2, reader.count.get())
        assertEquals(sends, server.sent.size)
        assertEquals(1, translator.calls.size)
        reader.lines = listOf(TextLine(if (realChange) alternate else original, first))
        clock = 900
        watcher.observePhone(PhoneCapture(b, pose))
        watcher.offer()
        wait { !watcher.isBusy }
        assertEquals(3, reader.count.get())
        assertEquals(1, translator.calls.size)
        assertEquals("Çevrildi: $original", server.sent.last().text)
    }

    @Test
    fun longMessageConfirmsAdjacentOcrTyposOnce() = adjacentTypo(realChange = false)

    @Test
    fun longMessageOcrVariantKeepsItsTranslation() = adjacentTypo(realChange = true)

    /** İki komşusu yerinde dururken düşen balon ekrandan hemen silinmez ([PhoneSteady.HOLD_TURNS] tur); sonra da yoksa silinir. */
    private fun missingBubble(stillMissing: Boolean) {
        val reader = Reader()
        val translator = Translator()
        val server = Server()
        val watcher = watcher(reader, translator, server)
        val a = TestPhoneImage.phone()
        val b = TestPhoneImage.phone(patch = intArrayOf(232, 120, 18, 30))
        val pose = GamePhoneGeometry.locate(a)!!
        val full = listOf(TextLine("How's work?", TextBox(0.15, 0.10, 0.60, 0.16)), TextLine("Not great.", TextBox(0.15, 0.40, 0.60, 0.46)),
            TextLine("See you.", TextBox(0.15, 0.75, 0.60, 0.81)))
        reader.lines = full
        watcher.observePhone(PhoneCapture(a, pose))
        watcher.offer()
        wait { !watcher.isBusy }
        assertEquals(3, server.sent.last().items.size)
        val sends = server.sent.size
        reader.lines = listOf(full[0], full[2])
        clock = 450
        watcher.observePhone(PhoneCapture(b, pose))
        watcher.offer()
        wait { !watcher.isBusy }
        assertEquals(sends, server.sent.size)
        if (!stillMissing) reader.lines = full
        clock = 900
        watcher.observePhone(PhoneCapture(b, pose))
        watcher.offer()
        wait { !watcher.isBusy }
        assertEquals(3, server.sent.last().items.size)
        // Aynı eksik düzen [PhoneSteady.DEGRADED_TURNS] okuma sürerse geçer (X, 28 Kas, beta.107; Windows ile aynı).
        for (turn in 3..PhoneSteady.DEGRADED_TURNS) {
            clock = 450L * turn
            watcher.observePhone(PhoneCapture(b, pose))
            watcher.offer()
            wait { !watcher.isBusy }
            if (turn < PhoneSteady.DEGRADED_TURNS) assertEquals(3, server.sent.last().items.size)
        }
        assertEquals(if (stillMissing) 2 else 3, server.sent.last().items.size)
        assertTrue(stillMissing || server.sent.none { it.items.size == 2 })
    }

    /**
     * GitHub #822 / X (beta.76): çeviri motordayken telefon bir karede doğrulanamadı. Okunan sayfa bırakılmıyordu; telefon
     * aynı görünüşe dönünce sayfa "değişmedi" sayılıyor, hazır çeviri hiç gösterilmiyordu (Mac PhoneRegionSessionTests ile aynı).
     */
    @Test
    fun translationArrivingDuringBriefPhoneMissIsShownOnTheNextTurn() {
        val reader = Reader()
        val translator = Translator()
        val server = Server()
        val watcher = watcher(reader, translator, server)
        val a = TestPhoneImage.phone()
        val blurred = TestPhoneImage.phone(patch = edit)
        val pose = GamePhoneGeometry.locate(a)!!
        reader.lines = listOf(TextLine("Reply today.", first))
        translator.delayed = "Reply today."
        watcher.observePhone(PhoneCapture(a, pose))
        watcher.offer()
        wait { translator.waiting }
        // Android'de doğrulama okuması telefonu aramaz: yazısı değişmiş görünen ama okunamayan kare doğrulanamaz.
        watcher.observePhone(PhoneCapture(blurred, pose))
        reader.failNext = true
        translator.resume()
        wait { !watcher.isBusy }
        clock = 450
        watcher.observePhone(PhoneCapture(a, pose))
        watcher.offer()
        wait { !watcher.isBusy }
        assertEquals("Bugün yanıtla.", server.sent.lastOrNull()?.text)
        assertEquals(listOf("Reply today."), translator.calls.toList())
    }

    @Test
    fun omittedInteriorBubbleWaitsForASecondRead() = missingBubble(stillMissing = false)

    @Test
    fun interiorBubbleStillMissingAfterTheHoldIsRemoved() = missingBubble(stillMissing = true)
}

/** Mac GamePhoneStabilityTests ve Windows PhoneSteadyTests ile aynı deneme. */
class PhoneSteadyTest {
    private val known = mapOf(
        "Did you hear back from the guy at the marina?" to "Marinadaki adamdan haber aldın mı?",
        "Meet me at 5 by the docks" to "Benimle 5'te rıhtımda buluş",
        "I can do that tonight" to "Bunu bu gece yapabilirim",
        "Ok" to "Tamam",
    )

    /** Aynı mesajın OCR'la biraz farklı okunuşu bilinen çevirisini alır; sayı/olumsuzluk değişen okuma ve kısa satır almaz. */
    @Test
    fun sameMessageReadSlightlyDifferentlyKeepsItsTranslation() {
        assertEquals("Marinadaki adamdan haber aldın mı?", PhoneSteady.translation("Did you hear back from the guy at the rnarina?", known))
        assertEquals("Marinadaki adamdan haber aldın mı?", PhoneSteady.translation("Did you hear back frorn the guy at the marina", known))
        assertNull(PhoneSteady.translation("Meet me at 6 by the docks", known))
        assertNull(PhoneSteady.translation("I can't do that tonight", known))
        assertNull(PhoneSteady.translation("On", known))
        assertNull(PhoneSteady.translation("Where are you going tonight?", known))
        assertEquals("Tamam", PhoneSteady.translation("Ok", known))
    }
}
