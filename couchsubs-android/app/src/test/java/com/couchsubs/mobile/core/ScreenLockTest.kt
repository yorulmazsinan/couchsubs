// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.io.File
import kotlin.math.ceil
import kotlin.math.floor
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ekran kilidi (Sinan Bey: "stabil olsun artık"): bütün ekran okuması her turda her bloğun kutusuna yeniden karar veriyordu;
 * kutular titriyor, yer değiştiriyor, kalkıp geliyordu. Kararlı ekran kilitlenir; küçük değişiklikte (imleç, sayaç, bir
 * bloğun yazısı) kutu taşınmaz, eklenmez, kalkmaz; ekran gerçekten değişince bir kez yeniden kurulur; aynı ekrana dönülünce
 * önbellekten aynı kutularla çizilir. Gerçek GTA 6 kareleri ve kayıtlı okumalar art arda turlarla (fixtures/screen-lock.json,
 * core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac/iPhone ScreenLockTests.swift ve Windows ScreenLockTests.cs aynı).
 */
class ScreenLockTest {
    private val directory: File = generateSequence(File(System.getProperty("user.dir")!!).absoluteFile) { it.parentFile }
        .map { File(it, "testdata/frames") }
        .first { File(it, "frames.json").isFile }

    private val plan = JSONObject(Fixtures.text("screen-lock.json"))

    private class Picture(val gray: GrayFrame, val color: (Int, Int) -> Int, val rgb: IntArray, val width: Int, val height: Int)

    private fun picture(rgb: IntArray, width: Int, height: Int): Picture {
        val luma = ByteArray(rgb.size) { i ->
            val c = rgb[i]
            ((299 * ((c shr 16) and 0xff) + 587 * ((c shr 8) and 0xff) + 114 * (c and 0xff)) / 1000).toByte()
        }
        return Picture(GrayFrame(luma, width, height), { x, y -> rgb[y * width + x] }, rgb, width, height)
    }

    /** Kareyi masaüstü JDK'nın ImageIO'suyla okur (CoverInPlaceTest gibi). */
    private fun load(file: File): Picture {
        val buffered = Class.forName("javax.imageio.ImageIO").getMethod("read", File::class.java).invoke(null, file)
        val type = buffered.javaClass
        val width = type.getMethod("getWidth").invoke(buffered) as Int
        val height = type.getMethod("getHeight").invoke(buffered) as Int
        val rgb = type.getMethod("getRGB", Int::class.java, Int::class.java, Int::class.java, Int::class.java, IntArray::class.java,
            Int::class.java, Int::class.java).invoke(buffered, 0, 0, width, height, null, 0, width) as IntArray
        for (i in rgb.indices) rgb[i] = rgb[i] and 0xFFFFFF
        return picture(rgb, width, height)
    }

    private fun crop(source: Picture, region: CropRegion): Picture {
        val x0 = floor(source.width * region.left).toInt().coerceIn(0, source.width)
        val x1 = ceil(source.width * region.right).toInt().coerceIn(0, source.width)
        val y0 = floor(source.height * region.top).toInt().coerceIn(0, source.height)
        val y1 = ceil(source.height * region.bottom).toInt().coerceIn(0, source.height)
        val width = x1 - x0
        val height = y1 - y0
        return picture(IntArray(width * height) { i -> source.rgb[(y0 + i / width) * source.width + x0 + i % width] }, width, height)
    }

    private class Area(val menu: Boolean, val region: CropRegion, val lines: List<JSONObject>)
    private class Screen(val image: Picture, val areas: List<Area>)

    private fun screen(id: String): Screen {
        val fixture = JSONObject(File(directory, "ocr/screen/$id.json").readText())
        val list = fixture.getJSONArray("areas")
        val areas = (0 until list.length()).map { list.getJSONObject(it) }.filter { it.getJSONArray("lines").length() > 0 }.map { area ->
            val r = area.getJSONArray("region")
            val lines = area.getJSONArray("lines")
            Area(area.optBoolean("menu", false), CropRegion(r.getDouble(1), r.getDouble(3), r.getDouble(0), r.getDouble(2)),
                (0 until lines.length()).map { lines.getJSONObject(it) })
        }
        return Screen(load(File(directory, "$id.jpg")), areas)
    }

    private fun strings(array: JSONArray?) = array?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()

    /** Kayıtlı okumanın turdaki hâli (kural screen-lock.json'da). */
    private fun reading(lines: List<JSONObject>, pass: JSONObject): Reading {
        val drop = strings(pass.optJSONArray("drop"))
        val edits = pass.optJSONArray("edit")?.let { a -> (0 until a.length()).map { a.getJSONArray(it).getString(0) to a.getJSONArray(it).getString(1) } }
            ?: emptyList()
        val jitter = if (pass.has("jitter")) pass.getInt("jitter") else null
        val result = mutableListOf<TextLine>()
        for ((i, line) in lines.withIndex()) {
            val original = line.getString("text")
            if (original in drop) continue
            var text = original
            for ((from, to) in edits) if (from == original) text = to
            fun moved(v: JSONArray): TextBox {
                val k = jitter ?: return TextBox(v.getDouble(0), v.getDouble(1), v.getDouble(2), v.getDouble(3))
                val dx = 0.002 * ((k + i) % 3 - 1)
                val dy = 0.0015 * ((k + 2 * i) % 3 - 1)
                return TextBox(v.getDouble(0) + dx, v.getDouble(1) + dy, v.getDouble(2) + dx + 0.001 * (k % 2), v.getDouble(3) + dy)
            }
            val words = if (text == original) line.optJSONArray("words")?.let { list ->
                (0 until list.length()).map { k -> TextWord(list.getJSONObject(k).getString("text"), moved(list.getJSONObject(k).getJSONArray("box"))) }
            } else null
            result.add(TextLine(text, line.optJSONArray("box")?.let(::moved), words = words,
                confidence = if (line.has("confidence")) line.getDouble("confidence").toFloat() else null))
        }
        return Reading(result)
    }

    /** TV'nin gördüğü: alan alan çizili kutular. */
    private class Tv : RegionSender {
        val shown = LinkedHashMap<String, List<Pair<TextBox, String>>>()
        var sends = 0
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) = sendRegion(id, text, box, lineHeight, null, null)
        override fun sendRegion(
            id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?, blocks: List<ScreenTranslation.Item>?,
        ) {
            sends++
            if (text.isEmpty()) shown.remove(id)
            else shown[id] = blocks?.map { it.box to it.translation } ?: listOf((box ?: TextBox(0.0, 0.0, 0.0, 0.0)) to text)
        }
        override fun clearRegions() = shown.clear()
        fun boxes() = shown.values.flatten()
    }

    data class Changes(val added: Int = 0, val moved: Int = 0, val removed: Int = 0, val retexted: Int = 0) {
        val boxes get() = added + moved + removed
        operator fun plus(o: Changes) = Changes(added + o.added, moved + o.moved, removed + o.removed, retexted + o.retexted)
    }

    private fun changes(old: List<Pair<TextBox, String>>, fresh: List<Pair<TextBox, String>>): Changes {
        val left = old.toMutableList()
        val added = mutableListOf<Pair<TextBox, String>>()
        var retexted = 0
        for (item in fresh) {
            val i = left.indexOfFirst { it.first == item.first }
            if (i >= 0) {
                if (left[i].second != item.second) retexted++
                left.removeAt(i)
            } else added.add(item)
        }
        var moved = 0
        var newly = 0
        for (item in added) {
            val i = left.indexOfFirst { ScreenLock.overlap(it.first, item.first) >= 0.3 }
            if (i >= 0) {
                moved++
                left.removeAt(i)
            } else newly++
        }
        return Changes(newly, moved, left.size, retexted)
    }

    private class Run(
        val perSegment: List<Changes>, val sendsPerSegment: List<Int>, val whileLocked: Changes, val unlocksPerSegment: List<Int>,
        val locks: Int, val unlocks: Int, val cacheHits: Int, val log: List<String>, val finalShown: Int,
    )

    private fun replay(lock: Boolean): Run {
        val passMs = plan.getLong("passMs")
        val readings = HashMap<String, Reading>()
        val tv = Tv()
        var clock = 0L
        val log = mutableListOf<String>()
        val watcher = RegionWatcher({ readings.remove(it.pixels as String) ?: Reading.Empty }, { "TR $it" }, tv, passMs, { clock })
        watcher.locksScreen = lock
        watcher.rereadsEveryPass = true
        watcher.onLog = { synchronized(log) { log.add(it) } }
        val screens = HashMap<String, Screen>()
        val perSegment = mutableListOf<Changes>()
        val sends = mutableListOf<Int>()
        val unlocksPer = mutableListOf<Int>()
        var whileLocked = Changes()
        val segments = plan.getJSONArray("segments")
        for (s in 0 until segments.length()) {
            val segment = segments.getJSONObject(s)
            val id = if (segment.isNull("screen")) null else segment.getString("screen")
            val base = segment.getInt("idBase")
            val passes = segment.getJSONArray("passes")
            var total = Changes()
            val sendsBefore = tv.sends
            val unlocksBefore = watcher.screenLock.unlocks
            for (p in 0 until passes.length()) {
                val pass = passes.getJSONObject(p)
                val offered = mutableListOf<Pair<ExtraArea, RegionWatcher.Crop>>()
                if (id != null) {
                    val screen = screens.getOrPut(id) { screen(id) }
                    for ((k, area) in screen.areas.withIndex()) {
                        val areaId = "auto-${base + k}"
                        val extra = ExtraArea(id = areaId, name = "Screen text", region = area.region, auto = true, menu = area.menu)
                        val part = crop(screen.image, area.region)
                        readings[areaId] = reading(area.lines, pass)
                        offered.add(extra to RegionWatcher.Crop(areaId, ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { 1 },
                            part.gray, part.color, screen.image.gray, screen.image.color))
                    }
                }
                val before = tv.boxes()
                val lockedBefore = watcher.screenLock.isLocked
                val unlocks = watcher.screenLock.unlocks
                watcher.pass(offered.map { it.first.id }.toSet(), offered)
                assertTrue("her alan bir kez okunmalı", readings.isEmpty())
                clock += passMs
                val change = changes(before, tv.boxes())
                total += change
                if (lockedBefore && watcher.screenLock.isLocked && watcher.screenLock.unlocks == unlocks) whileLocked += change
            }
            perSegment.add(total)
            sends.add(tv.sends - sendsBefore)
            unlocksPer.add(watcher.screenLock.unlocks - unlocksBefore)
        }
        return Run(perSegment, sends, whileLocked, unlocksPer, watcher.screenLock.locks, watcher.screenLock.unlocks,
            watcher.screenLock.cacheHits, log.toList(), tv.boxes().size)
    }

    /**
     * Kilitliyken hiçbir kutu taşınmaz, eklenmez, kalkmaz; her ekran değişikliğinde tam bir yeniden kurulum; menüye dönülünce
     * önbellek tutar. Kilitsiz hâlin sayıları önce/sonra karşılaştırması için yazdırılır.
     */
    @Test
    fun replayOfMenusAndCardsKeepsLockedBoxesStill() {
        val segments = plan.getJSONArray("segments")
        val expect = plan.getJSONObject("expect")
        val before = replay(false)
        val after = replay(true)
        val names = (0 until segments.length()).map { segments.getJSONObject(it).let { s -> if (s.isNull("screen")) "(boş)" else s.getString("screen") } }
        for ((k, name) in names.withIndex()) {
            val b = before.perSegment[k]
            val a = after.perSegment[k]
            println("ekran kilidi $name: kutu değişikliği önce ${b.boxes} (ekle ${b.added}, taşı ${b.moved}, kaldır ${b.removed}), " +
                "sonra ${a.boxes} (ekle ${a.added}, taşı ${a.moved}, kaldır ${a.removed}); gönderi önce ${before.sendsPerSegment[k]}, " +
                "sonra ${after.sendsPerSegment[k]}")
        }
        val lines = after.log.filter { it.startsWith("ekran kilidi") }
        lines.forEach(::println)
        assertEquals(Changes(), after.whileLocked)
        assertEquals(lines.joinToString("\n"), expect.getInt("locks"), after.locks)
        assertEquals(expect.getInt("unlocks"), after.unlocks)
        assertEquals(expect.getInt("cacheHits"), after.cacheHits)
        // Kilitli ekrandan sonra gelen her bölümde (başka ekran ya da yazının kalkması) tam bir yeniden kurulum.
        for (k in 1 until segments.length()) {
            if (segments.getJSONObject(k - 1).isNull("screen")) continue
            assertEquals("${names[k]}: yeniden kurulum sayısı", expect.getInt("rebuildsPerChange"), after.unlocksPerSegment[k])
        }
        // Her kilit ve açılış günlükte nedeni ve blok sayısıyla.
        assertEquals(after.locks + after.unlocks, lines.size)
        assertTrue(lines.toString(), lines.all { it.contains(" blok") })
        assertTrue(after.perSegment.sumOf { it.boxes } < before.perSegment.sumOf { it.boxes })
        assertTrue(after.finalShown > 0)
    }

    // Kilit kuralları (ScreenLock tek başına).

    private fun block(key: String, top: Double) = ScreenLock.Block(key, TextBox(0.1, top, 0.4, top + 0.04))

    private fun item(source: String, block: ScreenLock.Block) = ScreenTranslation.Item(source, "TR $source", block.box, 0.04)

    private fun payload(items: List<ScreenTranslation.Item>) =
        ScreenLock.Payload(items.joinToString("\n") { it.translation }, items.firstOrNull()?.box, 0.04, null, items)

    private val menu = listOf("resume", "map", "brief", "settings", "quit game")

    private fun screenOf(texts: List<String> = menu, dy: Double = 0.0) = texts.mapIndexed { i, text -> block(text, 0.1 + 0.08 * i + dy) }

    @Test
    fun locksAfterTwoSteadyPassesAndHoldsBoxesThroughSmallChanges() {
        val lock = ScreenLock()
        val log = mutableListOf<String>()
        lock.onLog = { log.add(it) }
        val blocks = screenOf()
        assertEquals(1, lock.offer("auto-1", payload(blocks.map { item(it.key, it) })).size)
        assertTrue(lock.observe(blocks, 0).isEmpty())
        assertFalse(lock.isLocked)
        assertTrue(lock.observe(screenOf(dy = 0.002), 500).isEmpty())
        assertTrue(lock.isLocked)
        assertEquals(listOf("ekran kilidi: kilitlendi, 5 blok (5 çevirili)"), log)
        // Kutusu oynayan, bir satırı eksik ve yeni bir blokla gelen gönderi: kutu taşınmaz, kalkmaz, eklenmez.
        val moved = screenOf(dy = 0.004).map { item(it.key, it) }.dropLast(1) + item("tooltip", block("tooltip", 0.8))
        assertTrue(lock.offer("auto-1", payload(moved)).isEmpty())
        assertTrue(lock.offer("auto-1", null).isEmpty())
        assertTrue(lock.offer("auto-2", payload(listOf(item("tooltip", block("tooltip", 0.8))))).isEmpty())
        assertEquals(blocks.map { it.box }, lock.displayed("auto-1")!!.blocks!!.map { it.box })
        // Bir blokta yazı değişti (sayaç): iki tur aynı okunmadan güncellenmez; sonra yalnız yazı güncellenir, kutu aynı.
        val ticked = screenOf().toMutableList()
        ticked[1] = ticked[1].copy(key = "map 2")
        assertTrue(lock.observe(ticked, 1000).isEmpty())
        assertTrue(lock.offer("auto-1", payload(listOf(item("map 2", ticked[1])))).isEmpty())
        val sends = lock.observe(ticked, 1500)
        assertEquals(1, sends.size)
        assertEquals(blocks.map { it.box }, sends[0].payload!!.blocks!!.map { it.box })
        assertEquals("TR map 2", sends[0].payload!!.blocks!![1].translation)
        assertTrue(lock.isLocked)
        assertEquals(0, lock.unlocks)
    }

    @Test
    fun unlocksOnceWhenTheScreenReallyChangesAndShowsTheNewScreen() {
        val lock = ScreenLock()
        val log = mutableListOf<String>()
        lock.onLog = { log.add(it) }
        val first = screenOf()
        lock.offer("auto-1", payload(first.map { item(it.key, it) }))
        lock.observe(first, 0)
        lock.observe(first, 500)
        assertTrue(lock.isLocked)
        // İki blok (5'te 2, %40) değişti: tek tur yetmez, ikinci turda açılır; izleyicinin yeni ekranı çizilir.
        val otherTexts = listOf("resume", "map", "brief", "graphics", "audio")
        val other = screenOf(otherTexts)
        assertTrue(lock.observe(other, 1000).isEmpty())
        assertTrue(lock.isLocked)
        assertTrue(lock.offer("auto-1", payload(other.map { item(it.key, it) })).isEmpty())
        val sends = lock.observe(other, 1500)
        assertEquals(1, lock.unlocks)
        assertEquals(listOf("auto-1"), sends.map { it.id })
        assertEquals("TR audio", sends[0].payload!!.blocks!!.last().translation)
        val unlocked = log.filter { it.startsWith("ekran kilidi açıldı") }
        assertEquals(1, unlocked.size)
        assertTrue(log.toString(), unlocked[0].startsWith("ekran kilidi açıldı: ekran değişti"))
        assertTrue(log.toString(), unlocked[0].endsWith("5 blok"))
        // Yeni ekran iki turdur aynı okunuyordu: çizildiği anda kilitlenir (tek yeniden kurulum).
        assertTrue(lock.isLocked)
        assertEquals(2, lock.locks)
        assertTrue(lock.observe(other, 2000).isEmpty())
        // Yerleşim kaydı (aynı yazılar başka yerde) da açar; aynı yazı kümesi önbellekte olsa da eski kutular çizilmez.
        val shifted = screenOf(otherTexts, 0.5)
        lock.observe(shifted, 2500)
        lock.observe(shifted, 3000)
        assertEquals(2, lock.unlocks)
        assertEquals(0, lock.cacheHits)
        assertTrue(log.toString(), log.any { it.startsWith("ekran kilidi açıldı: yerleşim değişti (5 blok başka yerde)") })
    }

    @Test
    fun clearsWhenScreenTextIsGoneForMoreThanASecondAndRedrawsFromCache() {
        val lock = ScreenLock()
        val blocks = screenOf()
        val items = blocks.map { item(it.key, it) }
        lock.offer("auto-1", payload(items))
        lock.observe(blocks, 0)
        lock.observe(blocks, 500)
        assertTrue(lock.isLocked)
        assertTrue(lock.observe(emptyList(), 1000).isEmpty())
        assertTrue(lock.observe(emptyList(), 1500).isEmpty())
        assertTrue(lock.observe(emptyList(), 2000).isEmpty())
        assertEquals(listOf(ScreenLock.Send("auto-1", null, true)), lock.observe(emptyList(), 2500))
        assertFalse(lock.isLocked)
        assertTrue(lock.displayedIds.isEmpty())
        // Aynı ekrana dönüldü (dedektör yeni kimlik verdi): ilk okumada aynı kutular ve çevirilerle çizilir.
        val back = lock.observe(screenOf(dy = 0.003), 3000)
        assertTrue(lock.isLocked)
        assertEquals(1, lock.cacheHits)
        assertEquals(1, back.size)
        assertEquals(items, back[0].payload!!.blocks)
        // İzleyicinin yeni kimlikle gönderdiği aynı ekran ikinci kutu açmaz.
        assertTrue(lock.offer("auto-7", payload(screenOf(dy = 0.003).map { item(it.key, it) })).isEmpty())
        assertNull(lock.displayed("auto-7"))
    }

    @Test
    fun missionNoticeAndPhoneStayOutOfTheLock() {
        assertTrue(ScreenLock.covers("auto-3"))
        assertFalse(ScreenLock.covers(MissionLine.AREA_ID))
        assertFalse(ScreenLock.covers(ScreenNotices.ID_PREFIX + "1"))
        assertFalse(ScreenLock.covers("game-phone"))
        assertFalse(ScreenLock.covers("preset-help"))
    }
}
