// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * GTA 6 telefonunun sohbet dışı ekranları (Sinan Bey, beta.100 3416–3425): ekran türü, kartlar, kartların panelde
 * telefonun yanında orantılı boyda ve tek renkte çizilmesi, telefonun yazılarının altyazıya ve ekran yazısı kutularına
 * gitmemesi, ekran değişince eski kartların hemen kalkması ve aynı ekranda kartların kaybolmaması. Ortak deneme dosyası
 * fixtures/phone-screens.json (core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac/iPhone PhoneScreenTests.swift, Windows
 * PhoneScreenTests.cs aynı dosyayı okur).
 */
class PhoneScreenTest {
    private fun doubles(array: JSONArray) = (0 until array.length()).map { array.getDouble(it) }
    private fun box(v: List<Double>) = TextBox(v[0], v[1], v[2], v[3])
    private fun strings(array: JSONArray) = (0 until array.length()).map { array.getString(it) }

    @Test
    fun sharedScreensGiveTheSameKindAndCards() {
        val root = JSONObject(Fixtures.text("phone-screens.json"))
        val screens = root.getJSONArray("screens")
        for (s in 0 until screens.length()) {
            val screen = screens.getJSONObject(s)
            val name = screen.getString("name")
            val raw = screen.getJSONArray("lines")
            val lines = (0 until raw.length()).map { i ->
                val line = raw.getJSONObject(i)
                PhoneScreen.Line(line.getString("text"), box(doubles(line.getJSONArray("box"))))
            }
            val kind = PhoneScreen.kind(lines)
            assertEquals(name, screen.getString("kind"), kind.wire)
            val cards = PhoneScreen.cards(lines, kind)
            val expected = screen.getJSONArray("cards")
            val wanted = (0 until expected.length()).map { expected.getJSONObject(it) }
            assertEquals(name, wanted.map { strings(it.getJSONArray("paragraphs")) }, cards.map { PhoneScreen.paragraphs(it, lines) })
            assertEquals(name, wanted.map { it.getBoolean("titled") }, cards.map { it.titled })
            assertEquals(name, wanted.map { it.getBoolean("bold") }, cards.map { it.bold })
        }
        val times = root.getJSONObject("times")
        for (text in strings(times.getJSONArray("yes"))) assertTrue(text, PhoneScreen.isTime(text))
        for (text in strings(times.getJSONArray("no"))) assertFalse(text, PhoneScreen.isTime(text))
    }

    /** Gerçek kare (RGB). */
    private class Picture(override val width: Int, override val height: Int, private val pixels: IntArray) : PhoneImage {
        override fun rgb(x: Int, y: Int): Int = pixels[y * width + x]
        override fun tone(x: Int, y: Int): Int {
            val c = pixels[y * width + x]
            return 77 * ((c shr 16) and 0xff) + 150 * ((c shr 8) and 0xff) + 29 * (c and 0xff)
        }
    }

    private val frames: File? = generateSequence(File(System.getProperty("user.dir")!!).absoluteFile) { it.parentFile }
        .map { File(it, "testdata/frames") }
        .firstOrNull { File(it, "frames.json").isFile }

    private fun picture(file: File): Picture {
        val buffered = Class.forName("javax.imageio.ImageIO").getMethod("read", File::class.java).invoke(null, file)
        val type = buffered.javaClass
        val width = type.getMethod("getWidth").invoke(buffered) as Int
        val height = type.getMethod("getHeight").invoke(buffered) as Int
        val rgb = type.getMethod("getRGB", Int::class.java, Int::class.java, Int::class.java, Int::class.java, IntArray::class.java,
            Int::class.java, Int::class.java).invoke(buffered, 0, 0, width, height, null, 0, width) as IntArray
        for (i in rgb.indices) rgb[i] = rgb[i] and 0xFFFFFF
        return Picture(width, height, rgb)
    }

    /**
     * Gerçek sohbet kareleri (kayıtlı okumalarıyla) sohbet kalır: alt satıra sarılmış kısa parçalar ("off for you") etiket
     * sayılmaz, ana ekran kareleri de kart ekranı değil ana ekran kurallarıyla okunur.
     */
    @Test
    fun realChatFramesStayChats() {
        val directory = frames
        assumeTrue("gerçek kare yok", directory != null)
        for (name in listOf("gta6-telefon-sohbet-1", "gta6-telefon-sohbet-2")) {
            val file = File(directory, "$name.jpg")
            assumeTrue("gerçek kare yok", file.isFile)
            val frame = picture(file)
            val json = JSONObject(File(directory, "ocr/$name-tam.json").readText())
            val pose = GamePhoneGeometry.locate(frame)
            assertNotNull(name, pose)
            val handset = ScreenPhoneCard.Handset(pose!!, frame.width.toDouble() / frame.height)
            val raw = json.getJSONArray("lines")
            val lines = (0 until raw.length()).mapNotNull { i ->
                val line = raw.getJSONObject(i)
                val b = line.optJSONArray("box") ?: return@mapNotNull null
                if (b.length() != 4) return@mapNotNull null
                val box = box(doubles(b))
                if (!ScreenPhoneCard.holds(box, handset)) return@mapNotNull null
                PhoneScreen.Line(line.getString("text"), handset.flat(box))
            }
            assertTrue(name, lines.size >= 4)
            assertEquals(name, PhoneScreen.Kind.CHAT, PhoneScreen.kind(lines))
        }
    }

    private fun line(text: String, spot: List<Double>) = TextLine(text,
        TextBox(0.4 + spot[0] * 0.2, 0.1 + spot[1] * 0.8, 0.4 + spot[2] * 0.2, 0.1 + spot[3] * 0.8), phoneBox = box(spot))

    /**
     * Otomatik telefon okuması: uygulama ekranının satırları kartlarına ayrılır (rol `card`, başlıklı kart iki paragraf),
     * gönderide kullanıcı adı, konum ve fotoğraf yazısı çevrilmez, açıklama tek grup.
     */
    @Test
    fun autoPhoneReadingGroupsAppScreensIntoCards() {
        val fitness = Reading(listOf(
            line("Training", listOf(0.06, 0.12, 0.3, 0.14)),
            line("Power Session", listOf(0.1, 0.17, 0.5, 0.19)), line("Stage 2/4", listOf(0.1, 0.195, 0.35, 0.215)),
            line("Session done. Take a break.", listOf(0.12, 0.25, 0.8, 0.27)),
            line("Endurance Run", listOf(0.1, 0.32, 0.5, 0.34)), line("Stage 1/4", listOf(0.1, 0.345, 0.35, 0.365)),
            line("7PM", listOf(0.7, 0.5, 0.8, 0.52)),
        ))
        val groups = GamePhoneText.groups(GamePhoneText.forTranslation(fitness))
        assertEquals(listOf(listOf("Training"), listOf("Power Session", "Stage 2/4"), listOf("Session done. Take a break."),
            listOf("Endurance Run", "Stage 1/4")), groups.map { it.paragraphs })
        assertTrue(groups.all { it.phone?.role == ScreenPhoneCard.Role.CARD })
        assertEquals(listOf(false, true, false, true), groups.map { it.phone?.titled })

        val post = Reading(listOf(
            line("BAIT SHOP", listOf(0.2, 0.12, 0.6, 0.17)),
            line("@harbor_bait_club", listOf(0.12, 0.56, 0.62, 0.585)),
            line("Sunrise run past the north jetty", listOf(0.06, 0.6, 0.92, 0.625)),
            line("Grab the spring issue at the dock t...", listOf(0.06, 0.63, 0.92, 0.655)),
            line("Grab the spring issue", listOf(0.3, 0.63, 0.7, 0.655)),
            line("Marlin Point", listOf(0.1, 0.7, 0.4, 0.72)),
        ))
        val caption = GamePhoneText.groups(GamePhoneText.forTranslation(post))
        assertEquals(listOf(listOf("Sunrise run past the north jetty Grab the spring issue at the dock t...")), caption.map { it.paragraphs })
        assertEquals(ScreenPhoneCard.Role.CARD, caption.firstOrNull()?.phone?.role)
    }

    private val pose = GamePhoneGeometry.Pose(0.62, 0.15, 0.62, 0.85)

    private fun card(source: String, translation: String, top: Double, height: Double = 0.012, titled: Boolean = false,
                     style: TextSurface? = null, unchanged: Boolean = false, role: ScreenPhoneCard.Role = ScreenPhoneCard.Role.CARD) =
        ScreenTranslation.Item(source, translation, TextBox(0.56, 0.2 + top * 0.6, 0.7, 0.2 + top * 0.6 + height), height,
            surface = style, unchanged = unchanged,
            phone = ScreenPhoneCard.Placement(role, TextBox(0.06, top, 0.9, top + 0.03), titled = titled))

    private fun Double.rounded(places: Int): Double {
        val factor = Math.pow(10.0, places.toDouble())
        return Math.rint(this * factor) / factor
    }

    /**
     * Kartlar telefonun boş yanında (telefonun üstünde değil), mesaj listesi kartı görünüşünde (avatarsız), hepsi aynı
     * renkte ve aynı genişlikte; başlıklı kartın başlığı kalın ad, gövdesi altında; çevrilmeyen kart (ad) çizilmez.
     */
    @Test
    fun appCardsAreDrawnBesideThePhoneAsUniformRowCards() {
        val handset = ScreenPhoneCard.Handset(pose, 16.0 / 9)
        val white = TextSurface("#F2F2F2", "#111111")
        val navy = TextSurface("#1A2238", "#F0F0F0")
        val items = listOf(
            card("Riley", "Riley", top = 0.03, style = white, unchanged = true),
            card("Power Session\nStage 2/4", "Güç Seansı\nAşama 2/4", top = 0.17, titled = true, style = white),
            card("Session done. Take a break.", "Seans bitti. Mola ver.", top = 0.25, style = navy),
            card("Endurance Run\nStage 1/4", "Dayanıklılık Koşusu\nAşama 1/4", top = 0.32, titled = true, style = white),
        )
        val laid = ScreenPhoneCard.layout(items, handset).filter { !it.unchanged }
        val rows = laid.filter { it.panel == ScreenPhoneCard.PanelPart.ROW }
        assertEquals(3, rows.size)
        assertEquals(listOf("Güç Seansı", "", "Dayanıklılık Koşusu"), rows.mapNotNull { it.listRow }.map { it.name })
        assertEquals(listOf("Aşama 2/4", "Seans bitti. Mola ver.", "Aşama 1/4"), rows.mapNotNull { it.listRow }.map { it.preview })
        assertTrue(rows.all { it.listRow?.avatar == null && it.listRow?.portraitSpot == null })
        assertEquals("tek renk", 1, rows.map { it.surface?.background ?: "" }.toSet().size)
        assertEquals(white.background, rows[0].surface?.background)
        assertEquals("aynı genişlik", 1, rows.map { (it.box.right - it.box.left).rounded(9) }.toSet().size)
        val phone = handset.bounds
        for (row in rows) assertTrue("telefonun üstünde değil", row.box.right <= phone.left + 1e-9 || row.box.left >= phone.right - 1e-9)
        // Kartların üstü İngilizcesiyle aynı hizada, üst üste binmez.
        for ((a, b) in rows.zipWithNext()) assertTrue(a.box.bottom <= b.box.top + 1e-9)
        assertFalse("çevrilmeyen ad çizilmez", laid.any { it.source == "Riley" })
    }

    /**
     * Yazı boyu telefon yazısıyla orantılı: fotoğrafın içindeki büyük yazı ya da yakın kamera paneli dev yazıyla
     * çizmez (3416); çift sayıda ölçümde küçük ortanca alınır.
     */
    @Test
    fun cardTextIsProportionalNotHuge() {
        val handset = ScreenPhoneCard.Handset(pose, 16.0 / 9)
        val small = card("Last call for the boat", "Tekne için son çağrı", top = 0.6, height = 0.012)
        val sign = card("BAIT SHOP", "YEM DÜKKANI", top = 0.1, height = 0.07)
        assertEquals(0.012, ScreenPhoneCard.measuredLine(listOf(small, sign))!!, 0.0)
        val laid = ScreenPhoneCard.layout(listOf(small, sign), handset)
        for (row in laid.filter { it.panel == ScreenPhoneCard.PanelPart.ROW }) {
            assertTrue(row.lineHeight <= ScreenPhoneCard.MAX_LINE + 1e-9)
            assertTrue(row.lineHeight >= ScreenPhoneCard.MIN_LINE - 1e-9)
        }
        val huge = ScreenPhoneCard.layout(listOf(card("Big", "Büyük yazı", top = 0.3, height = 0.08)), handset, textScale = 1.0)
        assertEquals(ScreenPhoneCard.MAX_LINE, huge.first { it.panel == ScreenPhoneCard.PanelPart.ROW }.lineHeight, 1e-9)
        // Altyazı boyutu ayarı yine çarpan olarak işler.
        val scaled = ScreenPhoneCard.layout(listOf(card("Big", "Büyük yazı", top = 0.3, height = 0.08)), handset, textScale = 1.5)
        assertEquals(ScreenPhoneCard.MAX_LINE * 1.5, scaled.first { it.panel == ScreenPhoneCard.PanelPart.ROW }.lineHeight, 1e-9)
    }

    /** Ana ekran ve hava yazıları da telefonun üstüne yazılmaz: panelde kart olur; saat ("7PM") çevrilmez. */
    @Test
    fun homeAndWeatherTextGoesToThePanel() {
        val handset = ScreenPhoneCard.Handset(pose, 16.0 / 9)
        val home = card("Partly cloudy", "Parçalı bulutlu", top = 0.2, role = ScreenPhoneCard.Role.HOME)
        val row = ScreenPhoneCard.layout(listOf(home), handset).firstOrNull { it.panel == ScreenPhoneCard.PanelPart.ROW }
        assertEquals("Parçalı bulutlu", row?.listRow?.preview)
        assertTrue((row?.box?.right ?: 1.0) <= handset.bounds.left + 1e-9 || (row?.box?.left ?: 0.0) >= handset.bounds.right - 1e-9)
        val weather = PhoneChat.withoutAppNames(listOf(line("Now", listOf(0.06, 0.1, 0.2, 0.12)), line("71°", listOf(0.06, 0.13, 0.3, 0.2)),
            line("Partly cloudy", listOf(0.06, 0.21, 0.5, 0.23)), line("7PM", listOf(0.06, 0.3, 0.14, 0.32)),
            line("8PM", listOf(0.2, 0.3, 0.28, 0.32)), line("Sunset", listOf(0.06, 0.6, 0.3, 0.62))))
        assertFalse(weather.any { it.text == "7PM" || it.text == "8PM" })
        assertTrue(weather.any { it.text == "Sunset" })
    }

    /**
     * Açık telefonun yanları beyaz ekranda zemine karışınca sıkı arama telefonu bulamaz; son yerindeki gevşek doğrulama
     * (hoparlör yarığı, kamera, alt çentik) telefonu tutar. Yeni telefon gevşek doğrulamayla açılmaz; telefon gerçekten
     * kalkınca (yarıklar yok) tolerans dolunca kapanır.
     */
    @Test
    fun openPhoneIsKeptWhenItsSidesBlendIntoTheBackground() {
        val normal = TestPhoneImage.phone()
        // Beyaz ekran, açık kasa ve açık zemin aynı tonda: yan kenar yok (yalnız yarıklar ve kamera koyu).
        val blended = TestPhoneImage(400, 225) { x, y ->
            val gray = normal.rgb(x, y) and 0xff
            TestPhoneImage.gray(if (gray == 85 || gray == 110) 192 else gray)
        }
        val gone = TestPhoneImage(400, 225) { _, _ -> TestPhoneImage.gray(85) }
        assertNull("sıkı arama bulamıyor", GamePhoneGeometry.locate(blended))
        val found = GamePhoneGeometry.locate(normal)!!
        val near = GamePhoneGeometry.locate(blended, found)
        assertNotNull("son yerinde doğrulanır", near)
        assertEquals(found.topY, near!!.topY, 3.0 / 225)
        assertNull(GamePhoneGeometry.locate(gone, found))
        // Uzaktaki eski yer doğrulamaz.
        val far = GamePhoneGeometry.Pose(found.topX - 0.2, found.topY, found.bottomX - 0.2, found.bottomY)
        assertNull(GamePhoneGeometry.locate(blended, far))

        val tracker = GamePhoneTracker()
        assertNull(tracker.sample(normal, 0).pose)
        assertNotNull(tracker.sample(normal, 330).pose)
        for (turn in 2..12) assertNotNull("tur $turn", tracker.sample(blended, turn * 330L).pose)
        var closed = false
        for (turn in 13..18) if (tracker.sample(gone, turn * 330L).pose == null) closed = true
        assertTrue(closed)
        // Kapanmış telefon gevşek doğrulamayla açılmaz.
        val fresh = GamePhoneTracker()
        assertNull(fresh.sample(blended, 0).pose)
        assertNull(fresh.sample(blended, 330).pose)
    }

    /** Altyazı süzgeci açık telefonu tek ıskada bırakmaz (3418, 3420, 3421): [GamePhoneTracker.MISS_GRACE] arama tutulur. */
    @Test
    fun subtitleFilterHoldsThePhoneThroughShortMisses() {
        val handset = ScreenPhoneCard.Handset(pose, 16.0 / 9)
        var misses = 0
        fun held(found: ScreenPhoneCard.Handset?, shown: ScreenPhoneCard.Handset?): ScreenPhoneCard.Handset? {
            val (next, count) = SubtitlePipeline.heldPhone(found, shown, misses)
            misses = count
            return next
        }
        assertEquals(handset, held(handset, null))
        repeat(GamePhoneTracker.MISS_GRACE) { assertEquals(handset, held(null, handset)) }
        assertNull(held(null, handset))
        assertEquals(0, misses)
        assertNull(held(null, null))
    }

    // Oturum (otomatik telefon okuması)

    private class Reader {
        @Volatile var lines: List<TextLine> = emptyList()
        fun read(): Reading = Reading(lines)
    }

    private class Translator : TextTranslator {
        override val translatesTogether: Boolean get() = true
        val calls = java.util.Collections.synchronizedList(mutableListOf<String>())
        private val known = mapOf(
            "City council approves the waterfront plan" to "Meclis sahil planını onayladı",
            "The council voted late on Tuesday to approve the long delayed plan." to
                "Meclis salı geç saatte uzun süredir bekleyen planı onayladı.",
            "Partly cloudy" to "Parçalı bulutlu", "Sunset" to "Gün batımı", "Now" to "Şimdi",
            "Governor speaks today" to "Vali bugün konuşuyor",
        )
        override fun translate(text: String): String {
            calls.add(text)
            return known[text] ?: ("Çeviri " + text.reversed())
        }
    }

    private class Server : RegionSender {
        val sent = java.util.Collections.synchronizedList(mutableListOf<Pair<String, List<ScreenTranslation.Item>>>())
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) = sendRegion(id, text, box, lineHeight, null, null)
        override fun sendRegion(
            id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?, blocks: List<ScreenTranslation.Item>?,
        ) {
            sent.add(id to (if (text.isEmpty()) emptyList()
                else blocks ?: listOf(ScreenTranslation.Item("", text, box ?: TextBox(0.0, 0.0, 1.0, 1.0), lineHeight ?: 0.0))))
        }
        override fun clearRegions() {}
    }

    private val work = java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it).apply { isDaemon = true } }
    @Volatile private var clock = 0L

    private fun wait(done: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5000
        while (!done()) {
            check(System.currentTimeMillis() < deadline) { "zaman aşımı" }
            Thread.sleep(1)
        }
    }

    private fun RegionWatcher.turn(image: PhoneImage, pose: GamePhoneGeometry.Pose) {
        observePhone(PhoneCapture(image, pose))
        offer(emptyList(), { RegionWatcher.Crop(Unit, ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT)) }) { work.execute(it) }
        wait { !isBusy }
    }

    private fun flat(text: String, spot: List<Double>) = TextLine(text, box(spot))

    private fun phoneItems(server: Server) = server.sent.lastOrNull { it.first == PhoneRegionSession.ID }?.second

    /**
     * Uygulama değişince (makaleden hava uygulamasına) eski kartlar aynı gönderide kalkar; aynı ekran art arda okununca
     * kartlar kaybolmaz, yeniden gönderilmez ve yeniden çevrilmez (#1279).
     */
    @Test
    fun screenChangeReplacesCardsAndSameScreenStaysStill() {
        val frame = TestPhoneImage.phone()
        val found = GamePhoneGeometry.locate(frame)!!
        val shifted = GamePhoneGeometry.Pose(found.topX + 0.02, found.topY, found.bottomX + 0.02, found.bottomY)
        val reader = Reader()
        val translator = Translator()
        val server = Server()
        val watcher = RegionWatcher({ reader.read() }, translator, server, clock = { clock }, readPhone = { reader.read() })
        reader.lines = listOf(flat("< Back", listOf(0.04, 0.02, 0.2, 0.045)),
            flat("City council approves", listOf(0.06, 0.06, 0.9, 0.1)), flat("the waterfront plan", listOf(0.06, 0.105, 0.9, 0.145)),
            flat("The council voted late on Tuesday to", listOf(0.06, 0.6, 0.94, 0.62)),
            flat("approve the long delayed plan.", listOf(0.06, 0.625, 0.9, 0.645)))
        watcher.turn(frame, found)
        val first = phoneItems(server)!!
        assertEquals(listOf("Meclis sahil planını onayladı", ""), first.mapNotNull { it.listRow }.map { it.name })
        assertEquals(listOf("", "Meclis salı geç saatte uzun süredir bekleyen planı onayladı."), first.mapNotNull { it.listRow }.map { it.preview })
        assertFalse(first.any { it.translation.contains("Back") })

        // Aynı ekran, telefon biraz kıpırdadı: yeniden okunur ama gönderi ve çeviri yinelenmez, kartlar yerinde kalır.
        val sends = server.sent.size
        val calls = translator.calls.size
        for (turn in 1..4) {
            clock += 450
            watcher.turn(frame, if (turn % 2 == 1) shifted else found)
        }
        assertEquals("aynı ekran yeniden çevrilmez", calls, translator.calls.size)
        assertFalse("kartlar kaybolmaz", server.sent.drop(sends).any { it.first == PhoneRegionSession.ID && it.second.isEmpty() })

        // Hava uygulaması: eski makale kartları bu gönderide kalkar.
        reader.lines = listOf(flat("Now", listOf(0.06, 0.1, 0.2, 0.12)), flat("71°", listOf(0.06, 0.13, 0.3, 0.2)),
            flat("Partly cloudy", listOf(0.06, 0.21, 0.5, 0.23)), flat("7PM", listOf(0.06, 0.3, 0.14, 0.32)),
            flat("Sunset", listOf(0.06, 0.6, 0.3, 0.62)))
        clock += 450
        watcher.turn(frame, shifted) // kare değişti (yeni uygulama); testte telefonun yeri oynatılarak yeniden okunur
        val texts = phoneItems(server)!!.mapNotNull { it.listRow }.map { it.name + it.preview }
        assertFalse("eski kartlar kalktı: $texts", texts.any { it.contains("Meclis") })
        assertTrue(texts.toString(), texts.contains("Parçalı bulutlu"))
        assertTrue(texts.toString(), texts.contains("Gün batımı"))
        assertFalse("saat çevrilmez", texts.any { it.contains("7PM") })
    }

    /** Telefon açılınca otomatik ekran yazısı kutuları (telefonun ekranına çizilmiş olanlar dahil) aynı karede kalkar. */
    @Test
    fun phoneOpeningClearsScreenTextBoxesAtOnce() {
        val frame = TestPhoneImage.phone()
        val found = GamePhoneGeometry.locate(frame)!!
        val translator = Translator()
        val server = Server()
        val watcher = RegionWatcher({ Reading(listOf(TextLine("Governor speaks today", TextBox(0.1, 0.2, 0.9, 0.5)))) }, translator, server,
            clock = { clock }, readPhone = { Reading.Empty })
        val area = ExtraArea("auto-7", "auto", CropRegion(top = 0.3, bottom = 0.4, left = 0.45, right = 0.6), auto = true)
        // Koyu kutuda beyaz yazı çizgileri ve yazının izi.
        val gray = GrayFrame(ByteArray(256 * 108) { index ->
            val x = index % 256
            val y = index / 256
            (if (y in 20..60 && y % 10 < 2 && x in 20..230 && x % 4 != 0) 230 else 25).toByte()
        }, 256, 108)
        val signature = ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { index ->
            (if (index / RegionSignature.WIDTH in 4..7 && index % 2 == 0) 255 else 25).toByte()
        }
        repeat(4) {
            watcher.pass(setOf(area.id), listOf(area to RegionWatcher.Crop(Unit, signature, gray)))
            clock += 1000
        }
        assertTrue("kutu gösterildi", server.sent.any { it.first == "auto-7" && it.second.isNotEmpty() })
        val before = server.sent.size
        watcher.observePhone(PhoneCapture(frame, found))
        assertTrue("aynı karede kalktı", server.sent.drop(before).any { it.first == "auto-7" && it.second.isEmpty() })
    }
}
