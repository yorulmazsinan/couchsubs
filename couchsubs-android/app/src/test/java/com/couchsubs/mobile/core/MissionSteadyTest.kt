// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.io.File
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Sinan Bey (GTA 6, beta.105): görev kutusu ekranda kararsızdı: yanıp sönüyor, biçim değiştiriyor, yer değiştiriyor, bazen
 * altyazı olarak çevriliyordu. Gerçek kare okumalarıyla (testdata/frames/ocr: gta6-854-gorev-1/2/3, pencere-kare-2/5-gorev)
 * art arda okumalar: görev tek başına, konuşmayla birlikte, bir okumada görev satırı kaçıyor ("kare@0"), iki saniyelik boş
 * okuma, sonra görev gerçekten kalkıyor. Altyazı hattı ve görev kutusunu çizen ek alan ("auto-mission") birlikte koşar.
 * Mac/iPhone (MissionSteadyTests.swift) ve Windows (MissionSteadyTests.cs) aynı okumalarla aynı sonucu verir.
 */
class MissionSteadyTest {
    private val directory: File = generateSequence(File(System.getProperty("user.dir")!!).absoluteFile) { it.parentFile }
        .map { File(it, "testdata/frames") }
        .first { File(it, "frames.json").isFile }
    private val subtitleArea = CropRegion(0.62, 0.97, 0.14, 0.86)
    private val place = TextBox(subtitleArea.left, subtitleArea.top, subtitleArea.right, subtitleArea.bottom)

    private fun box(array: JSONArray) = TextBox(array.getDouble(0), array.getDouble(1), array.getDouble(2), array.getDouble(3))

    /**
     * "kare" kaydı olduğu gibi; "kare@0" karenin yalnız 0. satırı; "-" boş okuma; "a+b" iki okumanın satırları birlikte
     * (aynı karede görev satırı ve açık telefon).
     */
    private fun reading(id: String): Reading {
        if (id == "-") return Reading.Empty
        if (id.contains('+')) return Reading(id.split('+').flatMap { reading(it).lines })
        val parts = id.split('@')
        val fixture = JSONObject(File(directory, "ocr/${parts[0]}.json").readText())
        val region = fixture.getJSONArray("region")
        assertEquals(listOf(subtitleArea.left, subtitleArea.top, subtitleArea.right, subtitleArea.bottom),
            (0 until 4).map { region.getDouble(it) })
        val keep = parts.getOrNull(1)?.toInt()
        val lines = fixture.getJSONArray("lines")
        return Reading((0 until lines.length()).filter { keep == null || it == keep }.map { i ->
            val line = lines.getJSONObject(i)
            val words = line.optJSONArray("words")?.let { list ->
                (0 until list.length()).map { k -> TextWord(list.getJSONObject(k).getString("text"), box(list.getJSONObject(k).getJSONArray("box"))) }
            }
            TextLine(line.getString("text"), line.optJSONArray("box")?.let(::box), words = words,
                confidence = if (line.has("confidence")) line.getDouble("confidence").toFloat() else null)
        })
    }

    private class Sender : SubtitleSender {
        val sent = java.util.Collections.synchronizedList(mutableListOf<String>())
        val objectives = mutableListOf<TextBox?>()
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) { sent.add(text) }
        override fun clear() {}
        override fun sendObjective(box: TextBox?) { objectives.add(box) }
    }

    private class Overlay : RegionSender {
        val sent = mutableListOf<Pair<String, TextBox?>>()
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            if (id == MissionLine.AREA_ID) sent.add(text to box)
        }
        override fun clearRegions() {}
    }

    private class Run(
        val regions: List<CropRegion?>, val subtitlesBeforeMission: Int?, val sender: Sender, val requested: List<String>,
        val watcherRequested: List<String>, val overlay: Overlay,
    )

    /**
     * Altyazı hattı 250 ms'de bir okur; görev kutusunun alanı (varsa) 500 ms'de bir okunur ve alanın içindeki satırlar (aynı
     * karenin okuması) alana oranla verilir.
     */
    private fun run(ids: List<String>): Run {
        val frames = ids.map(::reading)
        // Telefonlu okumada telefon karede (kayıttaki yeri; Android'de telefonu kare okuyucusu bulup hatta verir).
        val handsets = ids.map { id ->
            id.split('+').firstOrNull { it.startsWith("gta6-telefon") }?.let { phone ->
                val p = JSONObject(File(directory, "ocr/${phone.substringBefore('@')}.json").readText()).getJSONArray("phone")
                ScreenPhoneCard.Handset(GamePhoneGeometry.Pose(p.getDouble(0), p.getDouble(1), p.getDouble(2), p.getDouble(3)), p.getDouble(4))
            }
        }
        val executor = Executors.newSingleThreadExecutor { Thread(it, "test translate").apply { isDaemon = true } }
        try {
            var now = 0L
            var index = 0
            val sender = Sender()
            val requested = java.util.Collections.synchronizedList(mutableListOf<String>())
            val pipeline = SubtitlePipeline({ requested.add(it); "TR: $it" }, sender, { now }, executor).apply { packWait = 0; cleanWait = 0 }
            var region: CropRegion? = null
            val regions = mutableListOf<CropRegion?>()
            pipeline.onMissionChanged = { region = it; regions.add(it) }
            val watcherRequested = mutableListOf<String>()
            val overlay = Overlay()
            val watcher = RegionWatcher({
                val r = region ?: return@RegionWatcher Reading.Empty
                val h = r.bottom - r.top
                val w = r.right - r.left
                Reading(frames[index].lines.mapNotNull { line ->
                    val b = line.box?.placedIn(place) ?: return@mapNotNull null
                    if (b.top < r.top || b.bottom > r.bottom) return@mapNotNull null
                    TextLine(line.text, TextBox((b.left - r.left) / w, (b.top - r.top) / h, (b.right - r.left) / w, (b.bottom - r.top) / h),
                        confidence = line.confidence)
                })
            }, { watcherRequested.add(it); "TR: $it" }, overlay, clock = { now })
            val shades = mutableMapOf<String, Byte>()
            var before: Int? = null
            for (i in ids.indices) {
                index = i
                val shade = shades.getOrPut(ids[i]) { (40 + 20 * shades.size).toByte() }
                pipeline.process(frames[i], place, phone = handsets[i])
                executor.submit {}.get()
                if (region != null && before == null) before = sender.sent.size
                if (i % 2 == 0) {
                    val current = region
                    val areas = if (current == null) emptyList() else
                        listOf(ExtraArea(id = MissionLine.AREA_ID, name = "Mission", region = current, auto = true))
                    watcher.pass(areas.map { it.id }.toSet(), areas.map {
                        it to RegionWatcher.Crop(Unit, ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { shade })
                    })
                }
                now += 250
            }
            return Run(regions, before, sender, requested.toList(), watcherRequested, overlay)
        } finally {
            executor.shutdownNow()
        }
    }

    private fun rep(id: String, count: Int) = List(count) { id }

    private val speedboat = rep("gta6-854-gorev-1", 4) + rep("gta6-854-gorev-2", 12) + rep("gta6-854-gorev-3", 16) +
        rep("gta6-854-gorev-3@0", 8) + rep("gta6-854-gorev-3", 16) + rep("gta6-854-gorev-2", 8) + rep("gta6-854-gorev-1", 2) +
        rep("gta6-854-gorev-3", 8) + rep("-", 8) + rep("gta6-854-gorev-3", 16) + rep("-", 28)
    private val plane = rep("pencere-kare-2-gorev", 12) + rep("pencere-kare-5-gorev", 16) + rep("pencere-kare-5-gorev@0", 8) +
        rep("pencere-kare-5-gorev", 12) + rep("pencere-kare-2-gorev", 8) + rep("-", 8) + rep("pencere-kare-5-gorev", 16) + rep("-", 28)

    private fun assertSteady(ids: List<String>, objective: String, dialogue: String) {
        val run = run(ids)
        // Görev kutusu bir kez belirdi ve görev gerçekten kalkınca bir kez kalktı.
        assertEquals("${run.regions}", 2, run.regions.size)
        val region = run.regions[0]!!
        assertNull(run.regions[1])
        // Bölge yalnız görev satırı: konuşma görev sayılıp bölgeye katılmadı.
        assertTrue("$region", region.bottom - region.top < 0.08)
        // Altyazı kutusunun kaçacağı yer bir kez bildirildi, bir kez kalktı.
        assertEquals(2, run.sender.objectives.size)
        // Görev kutusu belirdikten sonra görev satırı altyazı olarak çevrilmedi.
        assertFalse("${run.sender.sent}", run.sender.sent.drop(run.subtitlesBeforeMission ?: 0).any { it.contains(objective) })
        assertTrue("${run.requested}", run.requested.any { it.contains(dialogue) })
        // Görev kutusu: bir kez gönderildi, yeri ve boyu hep aynı, çevirisi bir kez istendi; tek boş gönderim en sonda.
        assertEquals("${run.overlay.sent}", 1, run.overlay.sent.count { it.first.isNotEmpty() })
        assertEquals("${run.watcherRequested}", 1, run.watcherRequested.size)
        assertEquals("", run.overlay.sent.last().first)
        assertEquals(1, run.overlay.sent.count { it.first.isEmpty() })
    }

    @Test
    fun speedboatObjectiveBoxStaysSteadyAcrossReads() = assertSteady(speedboat, "Speedboat", "Somebody's happy to be free")

    @Test
    fun planeObjectiveBoxStaysSteadyAcrossReads() = assertSteady(plane, "Follow the plane", "Okay.")

    /**
     * Beta.106 (3 kullanıcı): telefon, görev ve hedef çevirileri birbirinin yerine geçiyordu. Görev kutusu kurulduktan sonra
     * telefon açılır (gerçek telefon karesi gta6-telefon-sohbet-1) ve görev satırı görünmeye devam eder; sonra telefon kapanır.
     * Görev kutusu telefon yüzünden kalkmaz, yer değiştirmez; telefonun mesajları altyazıya da görev kutusuna da girmez
     * (Mac/iPhone ve Windows aynı).
     */
    @Test
    fun phoneAndObjectiveStayIndependent() {
        val phone = "gta6-854-gorev-2+gta6-telefon-sohbet-1"
        val run = run(rep("gta6-854-gorev-2", 12) + rep("gta6-854-gorev-3", 16) + rep(phone, 24) + rep("gta6-854-gorev-3", 12) +
            rep(phone, 8) + rep("gta6-854-gorev-3", 8) + rep("-", 28))
        assertEquals("${run.regions}", 2, run.regions.size)
        assertNull(run.regions[1])
        assertEquals(2, run.sender.objectives.size)
        val messages = listOf("amigo", "ANYTHING", "bring it")
        assertFalse("${run.sender.sent}", run.sender.sent.any { text -> messages.any { text.contains(it) } })
        assertFalse(run.sender.sent.drop(run.subtitlesBeforeMission ?: 0).any { it.contains("Speedboat") })
        val drawn = run.overlay.sent.filter { it.first.isNotEmpty() }
        assertEquals("${run.overlay.sent}", 1, drawn.size)
        assertFalse(drawn.any { d -> messages.any { d.first.contains(it) } })
        assertEquals(1, run.overlay.sent.count { it.first.isEmpty() })
    }

    /** Geçmişi olmayan tek başına görev (gta6-20-gorev) altyazı olarak çevrilmeye devam eder. */
    @Test
    fun loneObjectiveWithoutHistoryIsStillTheSubtitle() {
        val run = run(rep("gta6-20-gorev", 8))
        assertTrue("${run.sender.sent}", run.sender.sent.any { it.contains("Follow the plane") })
        assertTrue(run.regions.isEmpty())
    }

    @Test
    fun settledObjectiveSurvivesAMissButNotALongAbsence() {
        val mission = MissionLine()
        val area = TextBox(0.0, 0.0, 1.0, 1.0)
        val objective = listOf(TextLine("Get in the Speedboat", TextBox(0.45, 0.94, 0.62, 0.97)))
        var changes = 0
        for (time in 0L..4000L step 250) if (mission.observe(objective, area, time)) changes++
        assertNotNull(mission.region)
        assertEquals(1, changes)
        for (time in 4250L..6250L step 250) assertFalse(mission.observe(emptyList(), area, time))
        assertNotNull(mission.region)
        val (kept, claimed) = mission.claim(Reading(listOf(
            TextLine("Lucia: Go.", TextBox(0.4, 0.85, 0.6, 0.9)),
            TextLine("Get in the speedbat", TextBox(0.45, 0.941, 0.62, 0.971)),
        )), area)
        assertEquals(listOf("Lucia: Go."), kept.lines.map { it.text })
        assertEquals(listOf("Get in the speedbat"), claimed.map { it.text })
        assertFalse(mission.observe(claimed, area, 6500))
        assertFalse(mission.observe(emptyList(), area, 6500 + MissionLine.HOLD_MS))
        assertTrue(mission.observe(emptyList(), area, 6750 + MissionLine.HOLD_MS))
        assertNull(mission.region)
    }
}
