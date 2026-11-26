// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import com.couchsubs.mobile.core.ScreenPhoneCard.Role

/**
 * X (26 Kas, beta.104, Windows + PS Remote Play): GTA 6 telefon sohbetinde en üstteki uzun mesaj çizilmiyordu, alttaki iki
 * cevap seçeneğinden biri sarı giden balon, öbürü soluk ortalı not olarak karışık görünüyordu. Ortak deneme dosyasının
 * `roles` bölümü (iPhone PhoneOptionTests.swift, Windows PhoneOptionTests.cs aynı durumlar).
 */
class PhoneOptionTest {
    private val root = JSONObject(Fixtures.text("phone-chat.json"))

    private fun box(array: JSONArray) = (0 until array.length()).map { array.getDouble(it) }.let { TextBox(it[0], it[1], it[2], it[3]) }

    /** Otomatik telefon okuması: en üstteki mesaj (başlık okunmasa da) balon, her cevap seçeneği kendi satırı. */
    @Test
    fun sharedRoleVectors() {
        val panels = root.getJSONArray("roles")
        for (i in 0 until panels.length()) {
            val panel = panels.getJSONObject(i)
            val lines = panel.getJSONArray("lines").let { all ->
                (0 until all.length()).map { all.getJSONObject(it) }.map {
                    val box = box(it.getJSONArray("box"))
                    TextLine(it.getString("text"), box, phoneBox = box)
                }
            }
            val expected = panel.getJSONArray("groups").let { all ->
                (0 until all.length()).map { all.getJSONArray(it).let { pair -> listOf(pair.getString(0), pair.getString(1)) } }
            }
            val groups = GamePhoneText.groups(GamePhoneText.forTranslation(Reading(lines)))
            assertEquals(panel.getString("name"), expected,
                groups.map { listOf(it.phone?.role?.wire ?: "-", it.paragraphs.joinToString("\n")) })
        }
    }

    /** Not yalnız kısa etiket; ortalı cümle cevap seçeneğidir. */
    @Test
    fun centeredSentenceIsAnOptionNotANote() {
        fun row(text: String, left: Double, right: Double) = PhoneChat.Row(emptyList(), TextBox(left, 0.8, right, 0.82), text)
        assertEquals(ScreenPhoneCard.Role.NOTE, PhoneChat.role(listOf(row("Today 9:41 PM", 0.38, 0.62))))
        assertEquals(ScreenPhoneCard.Role.NOTE, PhoneChat.role(listOf(row("New messages", 0.32, 0.66))))
        assertEquals(ScreenPhoneCard.Role.OPTION, PhoneChat.role(listOf(row("Thanks for the heads up.", 0.21, 0.77))))
        assertEquals(ScreenPhoneCard.Role.OPTION,
            PhoneChat.role(listOf(row("Yeah I don't need your", 0.3, 0.7), row("opinion thanks.", 0.3, 0.6))))
        assertEquals(listOf(Role.INCOMING, Role.OPTION, Role.OPTION), PhoneChat.withOptions(listOf(Role.INCOMING, Role.OUTGOING, Role.OPTION)))
        assertEquals(listOf(Role.OUTGOING, Role.INCOMING, Role.OPTION), PhoneChat.withOptions(listOf(Role.OUTGOING, Role.INCOMING, Role.OPTION)))
        assertEquals(listOf(Role.INCOMING, Role.OUTGOING, Role.NOTE), PhoneChat.withOptions(listOf(Role.INCOMING, Role.OUTGOING, Role.NOTE)))
    }

    /** Yanda Panel: seçenekler oyuncunun tarafında ayrı balonlar, ikisi de aynı renkte. */
    @Test
    fun optionsShareOneLookInThePanel() {
        val handset = ScreenPhoneCard.Handset(GamePhoneGeometry.Pose(0.6087, 0.1026, 0.5528, 0.8395), 16.0 / 9)
        fun item(text: String, role: ScreenPhoneCard.Role, top: Double, surface: TextSurface?) =
            ScreenTranslation.Item(text, "$text (tr)", TextBox(0.5, top, 0.62, top + 0.03), 0.016, surface = surface,
                phone = ScreenPhoneCard.Placement(role, TextBox(0.2, top, 0.8, top + 0.03)))
        val blue = TextSurface("#3058D0", "#FFFFFF")
        val laid = ScreenPhoneCard.layout(listOf(item("Hello there friend", ScreenPhoneCard.Role.INCOMING, 0.4, null),
            item("Thanks for the heads up.", ScreenPhoneCard.Role.OPTION, 0.65, GamePhonePalette.neutral),
            item("Yeah I don't need your opinion thanks.", ScreenPhoneCard.Role.OPTION, 0.72, blue)), handset)
        val options = laid.filter { it.source != "Hello there friend" && !ScreenPhoneCard.isBackdrop(it) }
        assertEquals(2, options.size)
        assertTrue(options.all { it.panel == ScreenPhoneCard.PanelPart.MINE && it.look?.align == "right" })
        assertEquals(blue, options[0].surface)
        assertEquals(blue, options[1].surface)
        assertTrue(options[0].box.bottom < options[1].box.top)
    }

    /** Saydam pencere: uzun ilk mesaj dar sütuna sığmayınca düşmez; sütun genişler (gerekirse yazı küçülür). */
    @Test
    fun stackedPanelKeepsTheLongFirstMessage() {
        fun part(text: String, panel: ScreenPhoneCard.PanelPart, top: Double) =
            ScreenTranslation.Item(text, text, TextBox(0.72, top, 0.9, top + 0.05), 0.03, panel = panel)
        val long = "Seni 10 numaralı odadaki misafirimizle gördüm. Bil diye söylüyorum, misafir kurallarını çiğnediği için " +
            "birçok kez uyarıldı. Onun yüzünden daha fazla belaya girmeni istemem. L."
        val items = listOf(
            part(ScreenPhoneCard.BACKDROP_TEXT, ScreenPhoneCard.PanelPart.CARD, 0.2).copy(box = TextBox(0.6, 0.1, 0.9, 0.9), aligned = true),
            part("Yeni mesajlar", ScreenPhoneCard.PanelPart.NOTE, 0.25), part(long, ScreenPhoneCard.PanelPart.THEIRS, 0.3),
            part("DAHA FAZLA yazım hatasıydı. Tabii ki HERHANGİ BİR sorun demek istedim.", ScreenPhoneCard.PanelPart.THEIRS, 0.55),
            part("Haber verdiğin için sağ ol.", ScreenPhoneCard.PanelPart.MINE, 0.65),
            part("Evet, senin fikrine ihtiyacım yok, sağ ol.", ScreenPhoneCard.PanelPart.MINE, 0.72),
        )
        val panel = ScreenPhoneCard.panel(items)!!
        val stacked = ScreenPhoneCard.stacked(panel, 1600.0, 420.0, 20.0)
        assertEquals("en üstteki mesaj düşmez", panel.messages.map { it.translation }, stacked.messages.map { it.translation })
        assertTrue(stacked.messages.last().box.bottom <= 1 + 1e-9)
        assertTrue(stacked.card.box.right - stacked.card.box.left > ScreenPhoneCard.STACKED_SHARE)
        assertEquals(stacked, ScreenPhoneCard.stacked(panel, 1600.0, 420.0, 20.0))
        val roomy = ScreenPhoneCard.stacked(panel, 1600.0, 1600.0, 20.0)
        assertEquals(20.0, roomy.card.lineHeight * 1600 * 0.85, 1e-9)
        assertEquals(400.0, (roomy.card.box.right - roomy.card.box.left) * 1600, 1e-6)
        assertEquals(panel.messages.size, roomy.messages.size)
    }

    /** Günlük: okunan satırların türü ve ilk sözcükleri; özet değişince, en çok 5 sn'de bir. */
    @Test
    fun rowSummaryAndRateLimit() {
        fun group(text: String, role: ScreenPhoneCard.Role) = ScreenTranslation.Group(listOf(text), TextBox(0.0, 0.0, 1.0, 0.1), 0.02,
            phone = ScreenPhoneCard.Placement(role, TextBox(0.0, 0.0, 1.0, 0.1)))
        val groups = listOf(group("Linda", ScreenPhoneCard.Role.HEADER), group("I saw you with our guest from room 10.", ScreenPhoneCard.Role.INCOMING),
            group("Thanks for the heads up.", ScreenPhoneCard.Role.OPTION), group("New messages", ScreenPhoneCard.Role.NOTE))
        assertEquals("header: Linda | bubble: I saw you with… | option: Thanks for the heads… | note: New messages",
            PhoneChat.rowSummary(groups))
        val log = PhoneRowsLog()
        assertEquals("telefon satırları: " + PhoneChat.rowSummary(groups), log.line(groups, 1_000))
        assertNull(log.line(groups, 20_000))
        assertNull(log.line(groups.take(2), 2_000))
        assertNotNull(log.line(groups.take(2), 7_000))
        assertNull(log.line(emptyList(), 30_000))
    }
}
