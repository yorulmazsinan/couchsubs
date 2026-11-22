// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Altyazı alanının hazır seçimleri ve ek alanlar (Mac/iPhone AreaPresetTests ve RegionWatcherTests ile aynı durumlar). */
class AreasTest {
    @Test
    fun presetsMatchTheirRegions() {
        assertEquals(AreaPreset.BOTTOM, AreaPreset.matching(CropRegion()))
        assertEquals(AreaPreset.TOP, AreaPreset.matching(CropRegion(top = 0.03, bottom = 0.38, left = 0.14, right = 0.86)))
        assertEquals(AreaPreset.FULL, AreaPreset.matching(CropRegion(0.0, 1.0, 0.0, 1.0)))
        assertEquals(AreaPreset.CUSTOM, AreaPreset.matching(CropRegion(top = 0.5)))
        assertEquals(ExtraAreaPreset.PHONE, ExtraAreaPreset.matching(ExtraAreaPreset.PHONE.region))
        assertNull(ExtraAreaPreset.matching(CropRegion()))
    }

    @Test
    fun regionStaysInsideTheFrame() {
        val moved = CropRegion().moved(dx = 0.5, dy = 0.5)
        assertEquals(1.0, moved.bottom, 1e-9)
        assertEquals(1.0, moved.right, 1e-9)
        val small = CropRegion().resized(right = 0.0, bottom = 0.0)
        assertEquals(MINIMUM_REGION_SIZE, small.bottom - small.top, 1e-9)
        val vertical = CropRegion().withVertical(position = 90.0, height = 30.0)
        assertEquals(0.7, vertical.top, 1e-9)
        assertEquals(1.0, vertical.bottom, 1e-9)
    }

    @Test
    fun extraAreasRoundTripAndAreCapped() {
        val areas = (1..5).map { ExtraArea(name = "Alan $it", region = ExtraAreaPreset.QUEST.region, enabled = it % 2 == 1) }
        val read = ExtraArea.listFromJson(ExtraArea.listToJson(areas))
        assertEquals(ExtraArea.MAX_COUNT, read.size)
        assertEquals(areas.take(3), read)
        assertEquals(listOf("Alan 1", "Alan 3"), read.active().map { it.name })
        assertEquals(emptyList<ExtraArea>(), ExtraArea.listFromJson("bozuk"))
    }

    /** Hedef seçimi kaydedilir; eski kayıtta (ve bilinmeyen değerde) TV sayılır, diğer alanlar kaybolmaz (Mac/Windows ile aynı). */
    @Test
    fun extraAreaTargetRoundTripsAndOldRecordsShowOnTheTv() {
        val areas = listOf(ExtraArea(id = "q", name = "Görev", region = ExtraAreaPreset.QUEST.region, enabled = false, target = ResultTarget.BOTH))
        assertEquals(areas, ExtraArea.listFromJson(ExtraArea.listToJson(areas)))
        val old = ExtraArea.listFromJson("""[{"id":"q","name":"Görev","region":{"top":0.03,"bottom":0.3,"left":0.66,"right":0.98},"enabled":false}]""")
        assertEquals(ResultTarget.TV, old.single().target)
        assertEquals("Görev", old.single().name)
        assertFalse(old.single().enabled)
        val unknown = ExtraArea.listFromJson("""[{"id":"q","name":"","region":{"top":0.03,"bottom":0.3,"left":0.66,"right":0.98},"target":"watch"}]""")
        assertEquals(ResultTarget.TV, unknown.single().target)
        assertEquals(ResultTarget.TV, ExtraArea(name = "Yeni", region = ExtraAreaPreset.QUEST.region).target)
    }

    /** Altyazı alanı Tam ekranken ek alan okunmaz; ayarlar değişmez, başka alana dönünce eskisi gibi okunur (Mac/iPhone ile aynı). */
    @Test
    fun fullScreenAreaPausesExtraAreasWithoutChangingThem() {
        val areas = listOf(ExtraArea(name = "Görev", region = ExtraAreaPreset.QUEST.region),
            ExtraArea(name = "Telefon", region = ExtraAreaPreset.PHONE.region, enabled = false))
        assertEquals(emptyList<ExtraArea>(), areas.watched(AreaPreset.FULL))
        assertEquals(listOf("Görev"), areas.watched(AreaPreset.BOTTOM).map { it.name })
        assertEquals(listOf("Görev"), areas.watched(AreaPreset.TOP).map { it.name })
        assertEquals(listOf("Görev"), areas.watched(AreaPreset.CUSTOM).map { it.name })
    }

    @Test
    fun paragraphsJoinWrappedLines() {
        val lines = listOf(TextLine("NEW OBJECTIVE"), TextLine("Meet Lamar at the"), TextLine("garage."), TextLine("Bring the car."))
        assertEquals(listOf("NEW OBJECTIVE", "Meet Lamar at the garage.", "Bring the car."), ScreenText.paragraphs(lines))
        assertTrue(ScreenText.isWords("Go home"))
        assertFalse(ScreenText.isWords("23m 9"))
        // Haritadaki uzaklık göstergedir (X: chiaki); içinde sözcük olan ayrıntı satırı yazıdır.
        for (distance in listOf("124 ft", "4 ft", "2.4 mi", "1,2 km", "50 yd")) assertFalse(distance, ScreenText.isWords(distance))
        assertTrue(ScreenText.isWords("Distance 2.4 mi"))
    }

    private class Recorder : RegionSender {
        val sent = mutableListOf<Pair<String, String>>()
        val placements = mutableListOf<Pair<TextBox?, Double?>>()
        var cleared = 0
        /** Her gönderimin blokları ([sent] ile aynı sırada; bloksuz gönderimde null). */
        val blocks = mutableListOf<List<ScreenTranslation.Item>?>()
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) =
            sendRegion(id, text, box, lineHeight, null, null)
        override fun sendRegion(
            id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?,
            blocks: List<ScreenTranslation.Item>?,
        ) {
            sent.add(id to text)
            placements.add(box to lineHeight)
            this.blocks.add(blocks)
        }
        override fun clearRegions() {
            cleared++
        }
    }

    private val quest = ExtraArea(id = "q", name = "Quest", region = ExtraAreaPreset.QUEST.region)

    private fun at(text: String, left: Double, top: Double, right: Double, bottom: Double) =
        TextLine(text, TextBox(left, top, right, bottom))

    private fun inQuest(box: TextBox) = box.placedIn(quest.region.box)

    /**
     * Alanda birbirinden ayrı duran yazılar alt alta tek kutuda değil, her biri kendi yeriyle gider; eski TV'ler için
     * birleşik metin de kalır (Windows ve Mac/iPhone ile aynı).
     */
    @Test
    fun separateGroupsInAnAreaAreSentAsBlocksAtTheirOwnPlaces() {
        val recorder = Recorder()
        val lines = listOf(at("Find the blacksmith", 0.5, 0.1, 0.95, 0.2), at("Go to the barn", 0.1, 0.6, 0.4, 0.7))
        val watcher = RegionWatcher({ Reading(lines) }, { "TR: $it" }, recorder)
        repeat(2) { watcher.pass(setOf(quest.id), listOf(quest to RegionWatcher.Crop(Unit, signature(10)))) }
        assertEquals(listOf("q" to "TR: Find the blacksmith\nTR: Go to the barn"), recorder.sent)
        val blocks = recorder.blocks.single()!!
        assertEquals(listOf("TR: Find the blacksmith", "TR: Go to the barn"), blocks.map { it.translation })
        assertEquals(listOf("Find the blacksmith", "Go to the barn"), blocks.map { it.source })
        assertEquals(inQuest(TextBox(0.5, 0.1, 0.95, 0.2)), blocks[0].box)
        assertEquals(inQuest(TextBox(0.1, 0.6, 0.4, 0.7)), blocks[1].box)
        assertEquals(0.1 * (quest.region.bottom - quest.region.top), blocks[0].lineHeight, 1e-9)
        assertEquals(inQuest(TextBox(0.1, 0.1, 0.95, 0.7)), recorder.placements[0].first)
    }

    /** Tek grup (alt alta sarılmış tek yazı) eskisi gibi tek kutudur, blok gönderilmez. */
    @Test
    fun oneGroupIsSentWithoutBlocks() {
        val recorder = Recorder()
        val calls = mutableListOf<String>()
        val lines = listOf(at("Find the blacksmith and ask him", 0.1, 0.2, 0.9, 0.3), at("to repair your sword.", 0.1, 0.3, 0.9, 0.4))
        val watcher = RegionWatcher({ Reading(lines) }, { calls.add(it); "Demirciyi bul ve kılıcını onarmasını iste." }, recorder)
        repeat(2) { watcher.pass(setOf(quest.id), listOf(quest to RegionWatcher.Crop(Unit, signature(10)))) }
        assertEquals(listOf("Find the blacksmith and ask him to repair your sword."), calls)
        assertEquals(listOf("q" to "Demirciyi bul ve kılıcını onarmasını iste."), recorder.sent)
        assertEquals(listOf<List<ScreenTranslation.Item>?>(null), recorder.blocks)
    }

    /** Çevirisi aslıyla aynı grup (ad) blok olarak gönderilmez; İngilizcesi görünür kalır. */
    @Test
    fun untranslatedGroupIsLeftOutOfTheBlocks() {
        val recorder = Recorder()
        val lines = listOf(at("Arthur", 0.1, 0.1, 0.3, 0.2), at("Meet me at the barn", 0.1, 0.6, 0.6, 0.7))
        val watcher = RegionWatcher({ Reading(lines) }, { if (it == "Arthur") it else "TR: $it" }, recorder)
        repeat(2) { watcher.pass(setOf(quest.id), listOf(quest to RegionWatcher.Crop(Unit, signature(10)))) }
        val blocks = recorder.blocks.single()!!
        assertEquals(listOf("TR: Meet me at the barn"), blocks.map { it.translation })
        assertEquals(inQuest(TextBox(0.1, 0.6, 0.6, 0.7)), blocks[0].box)
    }

    /** Aynı yazı kayınca yeniden çevrilmez; bloklar aynı çeviriyle yeni yerlerine gönderilir. */
    @Test
    fun movedBlocksKeepTheirTranslations() {
        val recorder = Recorder()
        val calls = mutableListOf<String>()
        var lines = listOf(at("Find the blacksmith", 0.5, 0.1, 0.95, 0.2), at("Go to the barn", 0.1, 0.6, 0.4, 0.7))
        val watcher = RegionWatcher({ Reading(lines) }, { calls.add(it); "TR: $it" }, recorder)
        fun pass(value: Int) = watcher.pass(setOf(quest.id), listOf(quest to RegionWatcher.Crop(Unit, signature(value))))
        pass(10)
        pass(10)
        lines = listOf(at("Find the blacksmith", 0.5, 0.1, 0.95, 0.2), at("Go to the barn", 0.1, 0.7, 0.4, 0.8))
        pass(60)
        assertEquals(listOf("Find the blacksmith", "Go to the barn"), calls)
        assertEquals(2, recorder.sent.size)
        val moved = recorder.blocks[1]!!
        assertEquals(listOf("TR: Find the blacksmith", "TR: Go to the barn"), moved.map { it.translation })
        assertEquals(inQuest(TextBox(0.1, 0.7, 0.4, 0.8)), moved[1].box)
        // Yer değişmeden yeniden okunan aynı yazı bir şey göndermez.
        pass(100)
        assertEquals(2, recorder.sent.size)
    }

    @Test
    fun regionFrameCarriesBlocksBesideTheJoinedText() {
        val blocks = listOf(ScreenTranslation.Item("Find", "Bul", TextBox(0.7, 0.05, 0.95, 0.08), 0.03),
            ScreenTranslation.Item("Go", "Git", TextBox(0.6, 0.15, 0.7, 0.2), 0.04))
        val frame = SubtitleServer.regionFrame("q", "Bul\nGit", TextBox(0.6, 0.05, 0.95, 0.2), 0.03, null, blocks)
        assertTrue(frame, frame.contains("\"blocks\":["))
        assertTrue(frame, frame.contains("\"text\":\"Bul\"") && frame.contains("\"text\":\"Git\"") && frame.contains("\"line\":0.04"))
        // Boşalan alanda blok gönderilmez.
        val empty = SubtitleServer.regionFrame("q", "", null, null, null, blocks)
        assertFalse(empty, empty.contains("blocks"))
    }

    private fun signature(value: Int) = ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { value.toByte() }

    @Test
    fun failedReadRetriesOnAnUnchangedFrameThenStopsReading() {
        val recorder = Recorder()
        var reads = 0
        val calls = mutableListOf<String>()
        val watcher = RegionWatcher({
            reads++
            if (reads == 1) throw IllegalStateException("Expected OCR failure")
            Reading.fromText("Find the blacksmith")
        }, { calls.add(it); "TR: $it" }, recorder)
        val area = ExtraArea(id = "q", name = "Quest", region = ExtraAreaPreset.QUEST.region)
        fun pass() = watcher.pass(setOf(area.id), listOf(area to RegionWatcher.Crop(Unit, signature(10))))
        pass()
        pass()
        assertTrue(recorder.sent.isEmpty())
        repeat(4) { pass() }
        assertEquals(2, reads)
        assertEquals(listOf("Find the blacksmith"), calls)
        assertEquals(listOf("q" to "TR: Find the blacksmith"), recorder.sent)
    }

    @Test
    fun failedReadKeepsShownTextAndDiscardsUnconfirmedReading() {
        val recorder = Recorder()
        var text = "Talk to Arthur"
        var fail = false
        val calls = mutableListOf<String>()
        val watcher = RegionWatcher({
            if (fail) { fail = false; throw IllegalStateException("Expected OCR failure") }
            Reading.fromText(text)
        }, { calls.add(it); "TR: $it" }, recorder)
        val area = ExtraArea(id = "q", name = "Quest", region = ExtraAreaPreset.QUEST.region)
        fun pass(value: Int) = watcher.pass(setOf(area.id), listOf(area to RegionWatcher.Crop(Unit, signature(value))))
        pass(10)
        pass(10)
        text = "Meet Arthur at the barn"
        pass(60)
        fail = true
        pass(100)
        text = "Find the blacksmith"
        pass(100)
        assertEquals(listOf("q" to "TR: Talk to Arthur"), recorder.sent)
        pass(100)
        assertEquals(listOf("Talk to Arthur", "Find the blacksmith"), calls)
        assertEquals(listOf("q" to "TR: Talk to Arthur", "q" to "TR: Find the blacksmith"), recorder.sent)
    }

    @Test
    fun failedReadDoesNotBlockAnotherArea() {
        val recorder = Recorder()
        var reads = 0
        val watcher = RegionWatcher({
            reads++
            if (reads == 1) throw IllegalStateException("Expected OCR failure")
            Reading.fromText("Find the blacksmith")
        }, { "TR: $it" }, recorder)
        val areas = listOf(ExtraArea(id = "q", name = "Quest", region = ExtraAreaPreset.QUEST.region),
            ExtraArea(id = "p", name = "Phone", region = ExtraAreaPreset.PHONE.region))
        fun pass() = watcher.pass(areas.map { it.id }.toSet(), areas.map { it to RegionWatcher.Crop(Unit, signature(10)) })
        pass()
        pass()
        assertEquals(listOf("p"), recorder.sent.map { it.first })
        pass()
        assertEquals(listOf("p", "q"), recorder.sent.map { it.first })
        assertEquals(3, reads)
    }

    @Test
    fun repeatedReadFailuresStillRespectThePassInterval() {
        val recorder = Recorder()
        var reads = 0
        var now = 0L
        val watcher = RegionWatcher({ reads++; throw IllegalStateException("Expected OCR failure") },
            { "TR: $it" }, recorder, clock = { now })
        val area = ExtraArea(id = "q", name = "Quest", region = ExtraAreaPreset.QUEST.region)
        for (step in 0..20) {
            now = step * RegionWatcher.DEFAULT_INTERVAL_MS / 10
            watcher.offer(listOf(area), { RegionWatcher.Crop(Unit, signature(10)) }) { it.run() }
        }
        assertEquals(3, watcher.passes)
        assertEquals(3, reads)
        assertTrue(recorder.sent.isEmpty())
    }

    @Test
    fun stableTextIsTranslatedOnceAndClearedWhenGone() {
        val recorder = Recorder()
        var text = "Meet Lamar at the garage."
        var now = 0L
        val watcher = RegionWatcher({ Reading.fromText(text) }, { "TR: $it" }, recorder, clock = { now })
        val area = ExtraArea(id = "q", name = "Görev", region = ExtraAreaPreset.QUEST.region)
        fun pass(value: Int) {
            assertTrue(watcher.offer(listOf(area), { RegionWatcher.Crop(Unit, signature(value)) }) { it.run() })
            now += 1000
        }
        pass(10) // ilk okuma: henüz kararlı değil
        assertEquals(emptyList<Pair<String, String>>(), recorder.sent)
        pass(10) // iz değişmedi: kararlı, çevrilir
        assertEquals(listOf("q" to "TR: Meet Lamar at the garage."), recorder.sent)
        pass(10) // aynı yazı yeniden çevrilmez
        assertEquals(1, recorder.sent.size)
        assertEquals(1, watcher.reads)
        text = ""
        pass(200)
        pass(200)
        assertEquals("q" to "", recorder.sent.last())
        watcher.reset()
        assertEquals(0, recorder.cleared)
    }

    @Test
    fun sameTextAtNewGeometryUpdatesRegionWithoutRetranslating() {
        val recorder = Recorder()
        val calls = mutableListOf<String>()
        var top = 0.2
        var height = 0.1
        val watcher = RegionWatcher({
            Reading(listOf(TextLine("Find the blacksmith", TextBox(0.1, top, 0.9, top + height))))
        }, { calls.add(it); "TR: $it" }, recorder)
        val area = ExtraArea(id = "q", name = "Quest", region = ExtraAreaPreset.QUEST.region)
        fun pass(value: Int) = watcher.pass(setOf(area.id), listOf(area to RegionWatcher.Crop(Unit, signature(value))))

        pass(10)
        pass(10)
        val first = recorder.placements[0]
        top = 0.45
        height = 0.2
        pass(60)

        assertEquals(listOf("q" to "TR: Find the blacksmith", "q" to "TR: Find the blacksmith"), recorder.sent)
        assertTrue(first.first != recorder.placements[1].first)
        assertTrue(first.second != recorder.placements[1].second)
        assertEquals(listOf("Find the blacksmith"), calls)
    }

    @Test
    fun failedTranslationRetriesWithoutLosingPreviouslyShownText() {
        val recorder = Recorder()
        var text = "Talk to Arthur"
        var now = 0L
        var failures = 0
        val calls = mutableListOf<String>()
        val watcher = RegionWatcher({ Reading.fromText(text) }, {
            calls.add(it)
            if (failures > 0) { failures--; throw IllegalStateException("expected") }
            "TR: $it"
        }, recorder, clock = { now })
        val area = ExtraArea(id = "q", name = "Görev", region = ExtraAreaPreset.QUEST.region)
        fun pass(value: Int) {
            assertTrue(watcher.offer(listOf(area), { RegionWatcher.Crop(Unit, signature(value)) }) { it.run() })
            now += 1000
        }
        pass(10)
        pass(10)
        assertEquals(listOf("q" to "TR: Talk to Arthur"), recorder.sent)

        text = "Meet Arthur at the barn"
        failures = 1
        pass(90)
        pass(90)
        assertEquals(listOf("q" to "TR: Talk to Arthur"), recorder.sent)

        pass(90)
        assertEquals(listOf("Talk to Arthur", "Meet Arthur at the barn", "Meet Arthur at the barn"), calls)
        assertEquals(listOf("q" to "TR: Talk to Arthur", "q" to "TR: Meet Arthur at the barn"), recorder.sent)
    }

    @Test
    fun removedAreaIsClearedAndFrequencyIsLimited() {
        val recorder = Recorder()
        var now = 0L
        val watcher = RegionWatcher({ Reading.fromText("Quest updated.") }, { "TR: $it" }, recorder, clock = { now })
        val area = ExtraArea(id = "n", name = "Bildirim", region = ExtraAreaPreset.NOTIFICATION.region)
        val crop: (CropRegion) -> RegionWatcher.Crop? = { RegionWatcher.Crop(Unit, signature(5)) }
        watcher.offer(listOf(area), crop) { it.run() }
        now += 100
        assertFalse(watcher.offer(listOf(area), crop) { it.run() })
        now += 1000
        watcher.offer(listOf(area), crop) { it.run() }
        assertEquals(listOf("n" to "TR: Quest updated."), recorder.sent)
        now += 1000
        watcher.offer(emptyList(), crop) { it.run() }
        assertEquals("n" to "", recorder.sent.last())
        watcher.reset()
        assertEquals(0, recorder.cleared)
    }

    /** Görev alanı: [text] okunur, çevirmene gidenler [calls]'a yazılır (Windows RegionWatcherTests ile aynı durumlar). */
    private inner class Scene(prefetch: Boolean = false) {
        var text = ""
        val calls = mutableListOf<String>()
        val recorder = Recorder()
        val watcher = RegionWatcher({ Reading.fromText(text) }, { calls.add(it); "TR: $it" }, recorder)
            .apply { prefetchesTranslations = prefetch }

        val sent: List<String> get() = recorder.sent.map { it.second }

        fun pass(shade: Int) = watcher.pass(setOf(quest.id), listOf(quest to RegionWatcher.Crop(Unit, signature(shade))))

        /** Kararlı okunup gösterilen yazı (iki tur aynı iz). */
        fun show(text: String, shade: Int) {
            this.text = text
            pass(shade)
            pass(shade)
        }
    }

    /** Görev yazısı arada kaybolup yeniden çıkınca çevirmene yeniden gidilmez. */
    @Test
    fun reappearingTextUsesTheEarlierTranslation() {
        val scene = Scene()
        scene.show("Find the blacksmith", 10)
        scene.show("", 90)
        scene.show("Find the blacksmith", 170)
        assertEquals(listOf("Find the blacksmith"), scene.calls)
        assertEquals(listOf("TR: Find the blacksmith", "", "TR: Find the blacksmith"), scene.sent)
    }

    /** Önceden çeviri açıkken çeviri yazı kararlı mı diye beklenirken istenir; gösterimde yeniden istenmez. */
    @Test
    fun prefetchedTranslationIsReusedWhenTheTextIsConfirmed() {
        val scene = Scene(prefetch = true)
        scene.text = "Find the blacksmith"
        scene.pass(10)
        assertEquals(listOf("Find the blacksmith"), scene.calls)
        assertTrue(scene.sent.isEmpty())
        scene.pass(10)
        assertEquals(listOf("Find the blacksmith"), scene.calls)
        assertEquals(listOf("TR: Find the blacksmith"), scene.sent)
    }

    /**
     * Yazı belirirken renkli sözcük geç geliyor: az önce gösterilen yazının başı okunursa tamamı beklenir; görev iki kez
     * çevrilip değişmez.
     */
    @Test
    fun partialReadingOfTheLastTextWaitsForTheWholeText() {
        val scene = Scene()
        scene.show("Fly to a drop point", 10)
        scene.show("", 90)
        scene.show("Fly to a", 170)
        scene.text = "Fly to a drop point"
        scene.pass(250)
        scene.pass(250)
        assertEquals(listOf("Fly to a drop point"), scene.calls)
        assertEquals(listOf("TR: Fly to a drop point", "", "TR: Fly to a drop point"), scene.sent)
    }

    /** Arka plan oynarken ekrandakinin harfi bozuk okuması kutuyu değiştirmez. */
    @Test
    fun nearlySameReadingKeepsTheShownText() {
        val scene = Scene()
        scene.show("SET DESTINATION EXIT", 10)
        scene.show("SET DESTINATIPN EXIT", 90)
        scene.show("SET DESTINATION EXIT", 170)
        assertEquals(listOf("SET DESTINATION EXIT"), scene.calls)
        assertEquals(1, scene.sent.size)
    }

    /** Yalnız bir sözcüğü değişen görev, o hâlde kalırsa birkaç tur sonra gösterilir. */
    @Test
    fun nearlySameTextThatStaysIsShownAfterTheHoldLimit() {
        val scene = Scene()
        scene.show("Go to the barn", 10)
        scene.show("Go to the bank", 90)
        assertEquals(1, scene.sent.size)
        repeat(RegionWatcher.HOLD_LIMIT) { scene.pass(90) }
        assertEquals(listOf("TR: Go to the barn", "TR: Go to the bank"), scene.sent)
    }

    @Test
    fun partialAndWordLosingReadingsAreRecognised() {
        assertFalse(RegionWatcher.isPartOf("run", "find the blacksmith"))
        assertTrue(RegionWatcher.isPartOf("add marker set destination", "add marker set destination exit"))
        assertFalse(RegionWatcher.isPartOf("talk to arthur", "meet arthur at the barn"))
        assertTrue(RegionWatcher.losesWords("find ${ButtonIcons.MARKER}", "find donnie"))
        assertFalse(RegionWatcher.losesWords("hold ${ButtonIcons.MARKER} to climb", "hold to climb"))
    }

    @Test
    fun newNumberNegationAndUnrelatedWordAreShownAfterConfirmation() {
        val scene = Scene()
        val sources = listOf("Take gate 5", "Take gate 6", "You can leave the base", "You can't leave the base", "Run")
        sources.forEachIndexed { index, source -> scene.show(source, index * 40) }
        assertEquals(sources, scene.calls)
    }

    @Test
    fun alternatingRereadsDoNotAccumulateHolds() {
        val scene = Scene()
        scene.show("Go to the barn", 10)
        repeat(RegionWatcher.HOLD_LIMIT + 1) {
            scene.show("Go to the bank", 90)
            scene.show("Go to the barn", 10)
        }
        assertEquals(listOf("Go to the barn"), scene.calls)
    }

    @Test
    fun cachedTranslationRetainsOriginalCapitalisation() {
        val scene = Scene()
        scene.show("Ask May", 10)
        scene.show("", 90)
        scene.show("Ask may", 170)
        assertEquals(listOf("Ask May", "Ask may"), scene.calls)
        assertEquals("TR: Ask may", scene.sent.last())
    }

    @Test
    fun firstConfirmedTextAfterResetUsesTheNewGameTranslation() {
        val recorder = Recorder()
        var translation = "İlk oyun"
        val watcher = RegionWatcher({ Reading.fromText("Board the train") }, { translation }, recorder)
        val crop = RegionWatcher.Crop(Unit, signature(10))
        fun show() = repeat(2) { watcher.pass(setOf(quest.id), listOf(quest to crop)) }
        show()
        watcher.reset()
        translation = "İkinci oyun"
        show()
        assertEquals(listOf("İlk oyun", "İkinci oyun"), recorder.sent.map { it.second })
        assertEquals(1, recorder.cleared)
    }

    @Test
    fun confirmedTextCanFinishWhileAStalePrefetchIsStillRunning() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val worker = Executors.newSingleThreadExecutor()
        val recorder = Recorder()
        var text = "Call the pilot"
        val watcher = RegionWatcher({ Reading.fromText(text) }, { "Bitti" }, recorder,
            prefetchWork = worker, prefetchTranslator = {
                started.countDown()
                try {
                    check(release.await(3, TimeUnit.SECONDS))
                } finally {
                    finished.countDown()
                }
                "Eski görev"
            }).apply { prefetchesTranslations = true }
        fun pass(shade: Int) = watcher.pass(setOf(quest.id), listOf(quest to RegionWatcher.Crop(Unit, signature(shade))))
        try {
            pass(10)
            assertTrue(started.await(3, TimeUnit.SECONDS))
            text = "Board the train"
            pass(90)
            pass(90)
            assertEquals(listOf("Bitti"), recorder.sent.map { it.second })
            assertEquals(1L, finished.count)
        } finally {
            release.countDown()
            worker.shutdownNow()
        }
    }

    @Test
    fun slowPrefetchDoesNotQueueUnconfirmedChangesAndResetCancelsQueuedWork() {
        val queued = mutableListOf<Runnable>()
        val calls = mutableListOf<String>()
        var text = ""
        val watcher = RegionWatcher({ Reading.fromText(text) }, { calls.add(it); "TR: $it" }, Recorder(),
            prefetchWork = Executor { queued.add(it) }).apply { prefetchesTranslations = true }
        fun pass(value: String, shade: Int) {
            text = value
            watcher.pass(setOf(quest.id), listOf(quest to RegionWatcher.Crop(Unit, signature(shade))))
        }
        pass("Find the blacksmith", 10)
        pass("Call the pilot", 90)
        pass("Board the train", 170)
        pass("Board the train", 170)
        assertEquals(1, queued.size)
        assertEquals(listOf("Board the train"), calls)
        watcher.reset()
        queued.single().run()
        assertEquals(listOf("Board the train"), calls)
    }

    @Test
    fun resetDropsAnOldPassBeforeItCanClearCurrentRegions() {
        val recorder = Recorder()
        val watcher = RegionWatcher({ Reading.fromText("Board the train") }, { "TR: $it" }, recorder)
        val crop = RegionWatcher.Crop(Unit, signature(10))
        lateinit var delayed: Runnable
        watcher.offer(listOf(quest), { crop }, { delayed = it })
        watcher.reset()
        val current = quest.copy(id = "current")
        repeat(2) { watcher.pass(setOf(current.id), listOf(current to crop)) }
        delayed.run()
        assertEquals(listOf("TR: Board the train"), recorder.sent.map { it.second })
        assertEquals(2, watcher.passes)
    }

    @Test
    fun textKeyKeepsButtonIcons() {
        val marker = ButtonIcons.MARKER
        assertEquals("set destination $marker exit", RegionWatcher.textKey(listOf("SET DESTINATION $marker EXIT")))
        assertTrue(RegionWatcher.textKey(listOf("SET DESTINATION")) != RegionWatcher.textKey(listOf("SET DESTINATION $marker")))
    }

    @Test
    fun serverSendsRegionEvents() {
        val frame = SubtitleServer.regionFrame("q", "Lamar ile garajda buluş.", TextBox(0.66, 0.03, 0.98, 0.3), 0.03)
        assertTrue(frame, frame.startsWith("event: region\n"))
        assertTrue(frame, frame.contains("\"id\":\"q\"") && frame.contains("\"line\":0.03"))
    }
}
