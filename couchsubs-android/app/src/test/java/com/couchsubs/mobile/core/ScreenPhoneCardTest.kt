// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * "Ekranı çevir": stil eşleşmeli yerinde çizim, GTA 6 telefon kartı ve yeniden basınca ekranın değişip değişmediği.
 * Telefonun satır kuralları ortak deneme dosyasından (fixtures/phone-chat.json, core/Tests/CouchSubsCoreTests/Fixtures
 * kopyası; Mac ScreenPhoneCardTests.swift ve Windows ScreenPhoneCardTests.cs aynı dosyayı okur).
 */
class ScreenPhoneCardTest {
    private val root = JSONObject(Fixtures.text("phone-chat.json"))

    private fun doubles(array: JSONArray) = (0 until array.length()).map { array.getDouble(it) }
    private fun box(array: JSONArray) = doubles(array).let { TextBox(it[0], it[1], it[2], it[3]) }
    private fun handset(pose: List<Double>, aspect: Double = 16.0 / 9) =
        ScreenPhoneCard.Handset(GamePhoneGeometry.Pose(pose[0], pose[1], pose[2], pose[3]), aspect)

    private fun caseGroups(vector: JSONObject): List<ScreenTranslation.Group> {
        val lines = vector.getJSONArray("lines")
        val reading = Reading((0 until lines.length()).map { i ->
            val line = lines.getJSONObject(i)
            TextLine(line.getString("text"), box(line.getJSONArray("box")))
        })
        return ScreenTranslation.groups(reading, wholeScreen = true,
            handset = handset(doubles(vector.getJSONArray("pose")), vector.getDouble("aspect")))
    }

    @Test
    fun sharedChatVectors() {
        val cases = root.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val vector = cases.getJSONObject(i)
            val expected = vector.getJSONArray("groups").let { all ->
                (0 until all.length()).map { all.getJSONArray(it).let { pair -> listOf(pair.getString(0), pair.getString(1)) } }
            }
            val groups = caseGroups(vector)
            assertTrue(vector.getString("name"), groups.all { it.phone != null })
            assertEquals(vector.getString("name"), expected, groups.map { listOf(it.phone!!.role.wire, it.paragraphs.joinToString("\n")) })
        }
    }

    @Test
    fun sharedEdgeAndFlatVectors() {
        val outside = root.getJSONObject("outside")
        val phone = handset(doubles(outside.getJSONArray("pose")), outside.getDouble("aspect"))
        val boxes = outside.getJSONArray("boxes")
        for (i in 0 until boxes.length()) {
            val entry = boxes.getJSONObject(i)
            assertEquals(entry.toString(), entry.getBoolean("inside"), PhoneChat.onScreen(phone.flat(box(entry.getJSONArray("box")))))
        }
        val flats = root.getJSONArray("flat")
        for (i in 0 until flats.length()) {
            val entry = flats.getJSONObject(i)
            val spot = handset(doubles(entry.getJSONArray("pose")), entry.getDouble("aspect")).flat(box(entry.getJSONArray("box")))
            val want = doubles(entry.getJSONArray("flat"))
            assertEquals(entry.toString(), want[0], spot.left, 0.02)
            assertEquals(entry.toString(), want[2], spot.right, 0.02)
            assertEquals(entry.toString(), (want[1] + want[3]) / 2, (spot.top + spot.bottom) / 2, 0.006)
            assertEquals(entry.toString(), want[3] - want[1], spot.bottom - spot.top, 0.012)
        }
        val cards = root.getJSONArray("cards")
        for (i in 0 until cards.length()) {
            val entry = cards.getJSONObject(i)
            val avoid = entry.optJSONArray("avoid")?.let { all -> (0 until all.length()).map { box(all.getJSONArray(it)) } } ?: emptyList()
            val card = ScreenPhoneCard.cardBox(box(entry.getJSONArray("phone")), avoid)
            val want = doubles(entry.getJSONArray("card"))
            listOf(card.left, card.top, card.right, card.bottom).zip(want).forEach { (a, b) -> assertEquals(b, a, 1e-9) }
        }
    }

    private val upright = listOf(0.78, 0.17, 0.78, 0.85)

    private fun item(
        source: String, translation: String, role: ScreenPhoneCard.Role, top: Double,
        left: Double = 0.1, right: Double = 0.7, unchanged: Boolean = false, surface: TextSurface? = null,
    ) = ScreenTranslation.Item(source, translation, TextBox(0.8, 0.2 + top * 0.6, 0.9, 0.22 + top * 0.6), 0.018,
        surface = surface, unchanged = unchanged, phone = ScreenPhoneCard.Placement(role, TextBox(left, top, right, top + 0.03)))

    private val outsideItem = ScreenTranslation.Item("Find the car", "Arabayı bul", TextBox(0.30, 0.10, 0.50, 0.13), 0.025)

    /** Kartsız (varsayılan ayar): her mesajın çevirisi kendi balonunun yerinde, kart zemini yok (Mac ile aynı). */
    @Test
    fun withoutTheCardEachMessageStaysOnItsOwnBubble() {
        val incoming = item("Where are you man", "Neredesin adamım", ScreenPhoneCard.Role.INCOMING, 0.2)
        val outgoing = item("On my way", "Yoldayım", ScreenPhoneCard.Role.OUTGOING, 0.3, 0.6, 0.93)
        val shown = ScreenTranslation.present(listOf(
            outsideItem, item("Brian", "Brian", ScreenPhoneCard.Role.HEADER, 0.06, unchanged = true), incoming, outgoing,
        ), handset(upright), card = false)
        assertEquals(listOf("Arabayı bul", "Neredesin adamım", "Yoldayım"), shown.map { it.translation })
        assertEquals(listOf(false, true, true), shown.map { it.bubble })
        assertFalse(shown.any { ScreenPhoneCard.isBackdrop(it) })
        assertEquals(incoming.box, shown[1].box)
        assertEquals(outgoing.box, shown[2].box)
    }

    /** Çeviriler balonların üstündeyken sohbet kayınca ilk yoklamada kalkar (HIDE), durulunca yeniden çevrilir (Mac ile aynı). */
    @Test
    fun inPlaceTranslationsLeaveAsSoonAsTheChatMoves() {
        val a = ByteArray(768) { 40 }
        val b = ByteArray(768) { 200.toByte() }
        val place = TextBox(0.6, 0.2, 0.8, 0.85)
        val inPlace = ScreenPhoneFollow(hidesOnChange = true)
        val card = ScreenPhoneFollow()
        inPlace.settled(place, a)
        card.settled(place, a)
        assertEquals(ScreenPhoneFollow.Step.KEEP, inPlace.step(place, a))
        assertEquals(ScreenPhoneFollow.Step.HIDE, inPlace.step(place, b))
        assertEquals(ScreenPhoneFollow.Step.REFRESH, inPlace.step(place, b))
        assertEquals(ScreenPhoneFollow.Step.WAIT, card.step(place, b))
        assertEquals(ScreenPhoneFollow.Step.REFRESH, card.step(place, b))
    }

    @Test
    fun phoneMessagesBecomeACardBesideThePhone() {
        val phone = handset(upright)
        val laid = ScreenTranslation.present(listOf(
            outsideItem,
            item("Brian", "Brian", ScreenPhoneCard.Role.HEADER, 0.06, unchanged = true),
            item("Where are you man", "Neredesin adamım", ScreenPhoneCard.Role.INCOMING, 0.2),
            item("On my way", "Yoldayım", ScreenPhoneCard.Role.OUTGOING, 0.3, 0.6, 0.93),
        ), phone)
        assertEquals("Arabayı bul", laid[0].translation)
        assertEquals(5, laid.size)
        val backdrop = laid[1]
        assertTrue(ScreenPhoneCard.isBackdrop(backdrop))
        assertEquals(phone.bounds.top, backdrop.box.top, 0.0)
        assertEquals(phone.bounds.bottom, backdrop.box.bottom, 0.0)
        assertTrue(backdrop.box.right < phone.bounds.left)
        val width = backdrop.box.right - backdrop.box.left
        // Kişi adı çevrilmese de kartın başlığıdır: ortalı, kalın; yazı TV'de okunacak boyda.
        assertEquals("Brian", laid[2].translation)
        assertEquals("center", laid[2].look?.align)
        assertEquals(true, laid[2].look?.bold)
        assertEquals(ScreenPhoneCard.MIN_LINE, laid[2].lineHeight, 0.0)
        assertEquals(ScreenPhoneCard.INCOMING, laid[3].surface)
        assertEquals(backdrop.box.left + width * 0.05, laid[3].box.left, 1e-9)
        assertEquals(ScreenPhoneCard.OUTGOING, laid[4].surface)
        assertEquals("right", laid[4].look?.align)
        assertEquals(backdrop.box.right - width * 0.05, laid[4].box.right, 1e-9)
        // Satırlar üst üste binmez ve kartın içinde kalır.
        for (i in 2 until laid.size - 1) assertTrue(laid[i].box.bottom <= laid[i + 1].box.top)
        assertTrue(laid.drop(2).all {
            it.box.left >= backdrop.box.left && it.box.right <= backdrop.box.right &&
                it.box.top >= backdrop.box.top && it.box.bottom <= backdrop.box.bottom
        })
    }

    @Test
    fun fullCardDropsTheOldestMessagesAndKeepsTheNewest() {
        val long = "Bu çok uzun bir mesajın Türkçesi ".repeat(4)
        val items = (0 until 9).map { index ->
            item("message $index", "$index $long", if (index % 2 == 0) ScreenPhoneCard.Role.INCOMING else ScreenPhoneCard.Role.OUTGOING,
                0.1 + index * 0.09)
        }
        val laid = ScreenPhoneCard.layout(items, handset(upright))
        val card = laid[0].box
        val rows = laid.drop(1)
        assertTrue(rows.size < 9)
        assertEquals("message 8", rows.last().source)
        for (i in 0 until rows.size - 1) assertTrue(rows[i].box.bottom <= rows[i + 1].box.top + 1e-9)
        assertTrue(rows.last().box.bottom <= card.bottom)
        assertTrue(rows.first().box.top >= card.top)
    }

    @Test
    fun ambiguousBubbleSideComesFromItsColorAndListRowsAreLeftAligned() {
        val laid = ScreenPhoneCard.layout(listOf(
            item("Sure thing", "Tabii", ScreenPhoneCard.Role.MESSAGE, 0.2, 0.05, 0.96, surface = TextSurface("#1E6FE0", "#FFFFFF")),
            item("Ok then", "Peki", ScreenPhoneCard.Role.MESSAGE, 0.4, 0.05, 0.96, surface = TextSurface("#E5E5EA", "#000000")),
            item("Lucia", "Lucia", ScreenPhoneCard.Role.CONTACT, 0.6, unchanged = true),
            item("You coming?", "Geliyor musun?", ScreenPhoneCard.Role.PREVIEW, 0.65),
        ), handset(upright))
        assertEquals(ScreenPhoneCard.OUTGOING, laid[1].surface)
        assertEquals(ScreenPhoneCard.INCOMING, laid[2].surface)
        assertEquals(true, laid[3].look?.bold)
        assertEquals("left", laid[3].look?.align)
        assertEquals(ScreenPhoneCard.CARD, laid[4].surface)
    }

    /**
     * Telefonun ana ekranı sohbet değildir: kart kurulmaz, bileşenin yazıları kendi yerinde kalır, uygulama adı ("WhatUp")
     * çevrilmez. Önceden ana ekran sohbet kartı sayılıyor, çeviri telefonun yanında tek blok oluyordu (X'teki bildirim).
     */
    @Test
    fun homeScreenIsTranslatedInPlaceWithoutACard() {
        val cases = root.getJSONArray("cases")
        val vector = (0 until cases.length()).map { cases.getJSONObject(it) }.first { it.getString("name").startsWith("ana ekran: bildirim") }
        val phone = handset(doubles(vector.getJSONArray("pose")), vector.getDouble("aspect"))
        val groups = caseGroups(vector)
        val words = mapOf("Reminders" to "Hatırlatıcılar", "10 Notifications" to "10 Bildirim")
        val items = groups.map { ScreenTranslation.Item(it.paragraphs[0], words.getValue(it.paragraphs[0]), it.box, it.lineHeight, phone = it.phone) }
        val shown = ScreenTranslation.present(items, phone)
        assertEquals(listOf("Hatırlatıcılar", "10 Bildirim"), shown.map { it.translation })
        assertTrue(shown.none(ScreenPhoneCard::isBackdrop))
        assertEquals(groups.map { it.box }, shown.map { it.box })
        assertTrue(shown.all { it.box.left >= phone.bounds.left && it.box.right <= phone.bounds.right })
    }

    /**
     * Otomatik telefon panelinde ([GamePhoneText.groups], satırların yeri düz ekranda) da ana ekranın uygulama adları ve
     * saat/hava çevrilmez; bileşen ve bildirim yazıları kendi yerinde kalır. Sohbet satırları olduğu gibi kalır (ortak
     * deneme dosyasının `panels` bölümü; Mac ve Windows aynı dosyayı okur).
     */
    @Test
    fun automaticPanelSkipsAppNamesOnTheHomeScreen() {
        val panels = root.getJSONArray("panels")
        for (i in 0 until panels.length()) {
            val panel = panels.getJSONObject(i)
            val lines = panel.getJSONArray("lines").let { all ->
                (0 until all.length()).map { all.getJSONObject(it) }.map {
                    val box = box(it.getJSONArray("box"))
                    TextLine(it.getString("text"), box, phoneBox = box)
                }
            }
            val expected = panel.getJSONArray("groups").let { all -> (0 until all.length()).map { all.getString(it) } }
            assertEquals(panel.getString("name"), expected, GamePhoneText.groups(Reading(lines)).map { it.paragraphs.joinToString("\n") })
        }
    }

    /** Sohbetin son kısa yanıtı ("Ok") ana ekran sayılmaz; sohbet yine kart olur. */
    @Test
    fun shortChatReplyIsNotAHomeScreen() {
        val vector = root.getJSONArray("cases").getJSONObject(0)
        val lines = vector.getJSONArray("lines").let { all ->
            (0 until all.length()).map { all.getJSONObject(it) }.map { TextLine(it.getString("text"), box(it.getJSONArray("box"))) }
        } + TextLine("Ok", TextBox(0.84, 0.60, 0.86, 0.617))
        val groups = ScreenTranslation.groups(Reading(lines), wholeScreen = true, handset = handset(upright))
        assertTrue(groups.none { it.phone?.role == ScreenPhoneCard.Role.HOME })
        assertEquals(ScreenPhoneCard.Role.HEADER, groups[0].phone?.role)
    }

    @Test
    fun cardGoesRightWhenThePhoneIsOnTheLeft() {
        val left = handset(listOf(0.20, 0.17, 0.20, 0.85))
        val laid = ScreenPhoneCard.layout(listOf(item("Where are you man", "Neredesin adamım", ScreenPhoneCard.Role.INCOMING, 0.3)), left)
        assertTrue(laid[0].box.left > left.bounds.right)
    }

    @Test
    fun withoutATranslatedPhoneTextNothingMovesAndUnchangedItemsAreDropped() {
        val items = listOf(item("Donnie", "Donnie", ScreenPhoneCard.Role.HEADER, 0.06, unchanged = true), outsideItem)
        assertEquals(listOf("Arabayı bul"), ScreenTranslation.present(items, handset(upright)).map { it.translation })
        assertEquals(listOf("Arabayı bul"), ScreenTranslation.present(items, null).map { it.translation })
    }

    /** Telefondaki kişi adı çevirmene gitmez ("Rose" → "Gül" olmasın); mesajlar gider. */
    @Test
    fun contactNamesAreNotSentToTheTranslator() {
        val groups = caseGroups(root.getJSONArray("cases").getJSONObject(0))
        assertEquals("Brian", ScreenTranslation.known("Brian", groups[0]))
        assertNull(ScreenTranslation.known("Will do", groups.last()))
    }

    /** Çeviriler artık özgün yazının stilinde: koyu kutudaki açık yazı koyu zeminde açık, BÜYÜK HARF yazı büyük harf. */
    @Test
    fun translationsTakeTheLookOfTheOriginalText() {
        val width = 200
        val height = 40
        val luma = ByteArray(width * height) { index -> (if ((index / width) % 10 < 2 && (index % width) % 4 != 0) 230 else 30).toByte() }
        val items = ScreenTranslation.translate(Reading(listOf(TextLine("SCROLL THE LIST", TextBox(0.0, 0.0, 1.0, 1.0)))),
            { "listeyi kaydır" }, frame = GrayFrame(luma, width, height))
        assertEquals(1, items.size)
        assertEquals("#1E1E1E", items[0].surface?.background)
        assertEquals(true, items[0].look?.upper)
        assertEquals("LİSTEYİ KAYDIR", items[0].translation)
    }

    private fun objects(array: JSONArray) = (0 until array.length()).map { array.getJSONObject(it) }
    private fun sides(b: TextBox) = listOf(b.left, b.top, b.right, b.bottom)

    /**
     * Sıkışık balonlar: balonlar arasında en az yarım satır boşluk, hepsi kartın içinde; mesajlar telefon boyuna sığmazsa
     * kart ekranın kenar payına kadar uzar, yine sığmazsa en eskiler düşer; kartın altında kalan çeviri kartın yanına
     * alınır (ortak deneme dosyasının `layouts` bölümü; Mac ve Windows aynı sonucu bulur).
     */
    @Test
    fun sharedLayoutVectors() {
        for (vector in objects(root.getJSONArray("layouts"))) {
            val name = vector.getString("name")
            val phone = handset(doubles(vector.getJSONArray("pose")))
            val outside = vector.optJSONArray("outside")?.let(::objects) ?: emptyList()
            val items = outside.map { ScreenTranslation.Item(it.getString("source"), it.getString("translation"), box(it.getJSONArray("box")), 0.02) } +
                objects(vector.getJSONArray("items")).map { m ->
                    val role = ScreenPhoneCard.Role.values().first { it.wire == m.getString("role") }
                    val top = m.getDouble("top")
                    ScreenTranslation.Item(m.getString("source"), m.getString("translation"), TextBox(0.8, 0.2, 0.9, 0.22), m.getDouble("line"),
                        unchanged = m.getBoolean("unchanged"),
                        phone = ScreenPhoneCard.Placement(role, TextBox(m.getDouble("left"), top, m.getDouble("right"), top + 0.03)))
                }
            val laid = ScreenPhoneCard.layout(items, phone)
            val n = outside.size
            val card = laid[n].box
            assertTrue(name, ScreenPhoneCard.isBackdrop(laid[n]))
            val rows = laid.drop(n + 1).filter { it.phone?.role != ScreenPhoneCard.Role.HEADER }
            val line = rows.first().lineHeight
            for (i in 0 until rows.size - 1) assertTrue(name, rows[i + 1].box.top - rows[i].box.bottom >= line * 0.5 - 1e-9)
            assertTrue(name, laid.drop(n + 1).all {
                it.box.left >= card.left && it.box.right <= card.right && it.box.top >= card.top - 1e-9 && it.box.bottom <= card.bottom + 1e-9
            })
            assertTrue(name, card.top >= ScreenPhoneCard.SCREEN_MARGIN - 1e-9 && card.bottom <= 1 - ScreenPhoneCard.SCREEN_MARGIN + 1e-9)
            val messages = objects(vector.getJSONArray("items"))
            assertEquals(name, messages.last().getString("source"), rows.last().source)
            for (i in 0 until n) assertEquals(name, 0.0, ScreenPhoneCard.covered(laid[i].box, listOf(card)), 0.0)
            vector.optJSONArray("card")?.let { sides(card).zip(doubles(it)).forEach { (a, b) -> assertEquals(name, b, a, 1e-6) } }
            vector.optJSONArray("kept")?.let { kept -> assertEquals(name, (0 until kept.length()).map(kept::getString), rows.map { it.source }) }
            vector.optJSONArray("moved")?.let { moved ->
                for (i in 0 until moved.length()) sides(laid[i].box).zip(doubles(moved.getJSONArray(i))).forEach { (a, b) -> assertEquals(name, b, a, 1e-6) }
            }
        }
    }

    /**
     * Kart ekrandayken telefon izlenir: sohbet değişip durulunca yeniden çevrilir, değişmeyen telefonda kart kalır,
     * telefon kapanınca kart kalkar; tek karelik ıska kartı kaldırmaz (ortak deneme dosyasının `follow` bölümü).
     */
    @Test
    fun sharedFollowVectors() {
        fun signature(spec: JSONArray) = ByteArray(768) { (if (it < spec.getInt(1)) spec.getInt(2) else spec.getInt(0)).toByte() }
        for (vector in objects(root.getJSONArray("follow"))) {
            val follow = ScreenPhoneFollow()
            objects(vector.getJSONArray("steps")).forEachIndexed { index, step ->
                if (step.has("settle")) {
                    follow.settled(box(step.getJSONArray("settle")), signature(step.getJSONArray("sig")))
                    return@forEachIndexed
                }
                val phone = if (step.isNull("phone")) null else box(step.getJSONArray("phone"))
                val got = follow.step(phone, if (phone == null) null else signature(step.getJSONArray("sig")))
                assertEquals("${vector.getString("name")} #$index", step.getString("expect"), got.wire)
            }
        }
    }

    /**
     * Başka bir sohbete geçip dönünce eski sohbetin mesajları çevirmene yeniden gitmez: çeviriler sohbetin başlığıyla
     * saklanır ([PhoneChatMemory]; ortak deneme dosyasının `switch` bölümü).
     */
    @Test
    fun switchingChatsReusesTheirTranslations() {
        val cases = objects(root.getJSONArray("cases"))
        val plan = root.getJSONObject("switch")
        val chats = plan.getJSONArray("chats")
        val calls = plan.getJSONArray("calls")
        val memory = PhoneChatMemory()
        val first = mutableMapOf<String, List<String>>()
        for (i in 0 until chats.length()) {
            val name = chats.getString(i)
            val vector = cases.first { it.getString("name") == name }
            val lines = objects(vector.getJSONArray("lines")).map { TextLine(it.getString("text"), box(it.getJSONArray("box"))) }
            var count = 0
            val items = ScreenTranslation.translate(Reading(lines), { count++; "TR $it" },
                phone = handset(doubles(vector.getJSONArray("pose")), vector.getDouble("aspect")), memory = memory)
            assertEquals(name, calls.getInt(i), count)
            val texts = items.map { it.translation }
            first[name]?.let { assertEquals(name, it, texts) } ?: run { first[name] = texts }
        }
    }

    /** Başka bir sohbete geçince ekranın izi değişir: düğmeye yeniden basmak yeni sohbeti çevirir, sonuçları kaldırmaz. */
    @Test
    fun anotherChatIsADifferentScreen() {
        fun screen(vararg lines: String) = ScreenTranslation.fingerprint(Reading(lines.mapIndexed { i, text ->
            TextLine(text, TextBox(0.74, 0.35 + i * 0.08, 0.94, 0.38 + i * 0.08))
        }))
        val donnie = screen("Donnie", "Where are you man", "Meet me at the docks")
        assertTrue(ScreenTranslation.isSameScreen(donnie, screen("Donnie", "Where are you man", "Meet me at the docks")))
        assertTrue(ScreenTranslation.isSameScreen(donnie, screen("Donnie", "Where are you rnan", "Meet me at the docks")))
        assertFalse(ScreenTranslation.isSameScreen(donnie, screen("Lucia", "Did you get the money", "Call me back")))
        assertFalse(ScreenTranslation.isSameScreen(donnie, screen("Donnie", "Where are you man", "Meet me at the docks", "Hurry up")))
        assertTrue(ScreenTranslation.isSameScreen("", ""))
        assertFalse(ScreenTranslation.isSameScreen("", donnie))
    }

    /** Telefonun ekranındaki satırlar altyazı hattına girmez; telefonun önünden/altından geçen geniş altyazı girer (Mac ile aynı). */
    @Test
    fun holdsOnlyTheLinesOnThePhoneScreen() {
        val phone = handset(listOf(0.50375, 0.12444, 0.46125, 0.68444))
        assertTrue(ScreenPhoneCard.holds(TextBox(0.39415, 0.47436, 0.54888, 0.52616), phone))
        assertTrue(ScreenPhoneCard.holds(TextBox(0.47965, 0.17571, 0.5218, 0.19897), phone))
        assertTrue(ScreenPhoneCard.holds(TextBox(0.3974, 0.74924, 0.4632, 0.79995), phone))
        assertFalse(ScreenPhoneCard.holds(TextBox(0.30, 0.86, 0.70, 0.91), phone))
        assertFalse(ScreenPhoneCard.holds(TextBox(0.46, 0.90, 0.54, 0.94), phone))
        assertFalse(ScreenPhoneCard.holds(TextBox(0.949, 0.93197, 0.99577, 0.95692), phone))
    }
}
