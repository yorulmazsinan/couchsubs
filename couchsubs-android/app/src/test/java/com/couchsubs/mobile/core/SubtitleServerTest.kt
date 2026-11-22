// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.Socket

/** TV uygulamalarının (LG, Samsung, Android TV) okuduğu olay biçimi: Windows'taki SubtitleServerTests ile aynı çıktı. */
class SubtitleServerTest {
    @Test
    fun subtitleFrameMatchesDesktop() {
        val frame = SubtitleServer.subtitleFrame("Merhaba", 4000, TextBox(0.25, 0.8, 0.75, 0.87499), at = 1700000000000)
        assertEquals(
            "event: subtitle\ndata: {\"at\":1700000000000,\"box\":{\"bottom\":0.875,\"left\":0.25,\"right\":0.75,\"top\":0.8}," +
                "\"duration\":4000,\"text\":\"Merhaba\"}\n\n",
            frame,
        )
    }

    @Test
    fun turkishLettersAndQuotesAreEncodedLikeSystemTextJson() {
        val frame = SubtitleServer.subtitleFrame("Işığı \"aç\"\nşimdi", 15000, null, at = 1)
        assertEquals("event: subtitle\ndata: {\"at\":1,\"duration\":15000,\"text\":\"Işığı \\\"aç\\\"\\nşimdi\"}\n\n", frame)
    }

    @Test
    fun boxValuesAreClampedAndRounded() {
        assertEquals("{\"bottom\":1,\"left\":0,\"right\":0.1235,\"top\":0.5}",
            Json.write(SubtitleServer.boxJson(TextBox(-0.2, 0.5, 0.12345678, 1.7))))
    }

    @Test
    fun clearAndStyleFrames() {
        assertEquals("event: clear\ndata: {}\n\n", SubtitleServer.clearFrame())
        assertEquals(
            "event: style\ndata: {\"background\":90,\"backgroundShape\":\"fit\",\"bold\":false,\"bottomPercent\":7,\"displayMode\":\"inApp\",\"fontSize\":46," +
                "\"placement\":\"cover\",\"setApart\":true,\"stackPrevious\":true,\"textColor\":\"white\"}\n\n",
            SubtitleServer.styleFrame(SubtitleStyle()),
        )
        assertTrue(SubtitleServer.styleFrame(SubtitleStyle(displayMode = TvDisplayMode.OVERLAY, textColor = SubtitleTextColor.YELLOW))
            .contains("\"displayMode\":\"overlay\""))
        val band = SubtitleServer.styleFrame(SubtitleStyle(background = 100, backgroundShape = SubtitleBackgroundShape.BAND))
        assertTrue(band.contains("\"background\":100") && band.contains("\"backgroundShape\":\"band\""))
        // "Önceki satırları üstte tut" kapalıysa TV'ye false gider (Windows ve Mac ile aynı).
        assertTrue(SubtitleServer.styleFrame(SubtitleStyle(stackPrevious = false)).contains("\"stackPrevious\":false"))
        // "Ekran yazılarını altyazıdan ayır" kapalıysa TV'ye false gider (yoksa açık sayılır).
        assertTrue(SubtitleServer.styleFrame(SubtitleStyle(), setApart = false).contains("\"setApart\":false"))
    }

    @Test
    fun helloIdentifiesTheServer() {
        val server = SubtitleServer(0, instanceId = "3f2a-b9")
        val port = server.start()
        try {
            Socket("127.0.0.1", port).use { socket ->
                socket.getOutputStream().write("GET /hello HTTP/1.1\r\nHost: x\r\n\r\n".toByteArray())
                val response = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
                assertTrue(response, response.startsWith("HTTP/1.1 200 OK"))
                assertTrue(!response.contains("Access-Control-Allow-Origin:"))
                // Kurulum kimliği ve bağlı TV sayısı: aynı ağdaki iki CouchSubs'ı TV bununla ayırır (GitHub #425).
                assertTrue(response, response.endsWith("{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"3f2a-b9\",\"tvs\":0,\"live\":0}"))
                assertEquals("{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"ab\",\"tvs\":2,\"live\":0}", SubtitleServer.helloBody("a\"b", 2))
                assertEquals("{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"x\",\"tvs\":0,\"live\":1}", SubtitleServer.helloBody("x", 0, true))
                assertFalse(response.contains(server.accessKey))
            }
        } finally {
            server.stop()
        }
    }

    @Test
    fun streamsStyleSubtitleClearAndPing() {
        val server = SubtitleServer(0, pingIntervalMs = 200, clock = { 42 })
        val port = server.start()
        try {
            server.sendStyle(SubtitleStyle())
            Socket("127.0.0.1", port).use { socket ->
                socket.soTimeout = 5000
                socket.getOutputStream().write("GET /events HTTP/1.1\r\nHost: x\r\n\r\n".toByteArray())
                val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
                val lines = mutableListOf<String>()
                fun readUntil(until: String) {
                    while (true) {
                        val line = reader.readLine() ?: return
                        lines.add(line)
                        if (line == until) return
                    }
                }
                readUntil("retry: 2000")
                assertTrue(lines.contains("Content-Type: text/event-stream; charset=utf-8"))
                readUntil("event: style")
                val deadline = System.currentTimeMillis() + 3000
                while (server.connectedClients != 1 && System.currentTimeMillis() < deadline) Thread.sleep(10)
                assertEquals(1, server.connectedClients)
                server.sendSubtitle("Merhaba", 4000, null)
                server.clear()
                readUntil("event: clear")
                assertTrue(lines.contains("data: {\"at\":42,\"duration\":4000,\"text\":\"Merhaba\"}"))
                readUntil("event: ping")
                assertEquals("data: {}", reader.readLine())
            }
        } finally {
            server.stop()
        }
    }

    /**
     * Eski TV uygulaması (sürüm bildirmeyen; 0.9.7'den önceki sürümler `clear` gelir gelmez satırı kaldırır): `clear` ona
     * satırın en az görünme süresi dolunca gider, yeni TV'ye hemen. Arada yeni satır gelirse eski `clear` hiç gitmez
     * (Mac ve Windows ile aynı).
     */
    @Test
    fun clearReachesOldTvAppsOnlyAfterTheLineWasReadable() {
        val server = SubtitleServer(0)
        val port = server.start()
        try {
            fun open(path: String): BufferedReader {
                val socket = Socket("127.0.0.1", port)
                socket.soTimeout = 8000
                socket.getOutputStream().write("GET $path HTTP/1.1\r\nHost: x\r\n\r\n".toByteArray())
                return BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8)).also { reader ->
                    while (reader.readLine() != "retry: 2000") Unit
                }
            }
            val old = open("/events")
            val fresh = open("/events?v=0.9.71")
            val deadline = System.currentTimeMillis() + 3000
            while (server.connectedClients != 2 && System.currentTimeMillis() < deadline) Thread.sleep(10)
            assertEquals(2, server.connectedClients)
            fun events(reader: BufferedReader): MutableList<Pair<String, Long>> {
                val seen = mutableListOf<Pair<String, Long>>()
                while (true) {
                    val line = reader.readLine() ?: return seen
                    if (!line.startsWith("event: ")) continue
                    seen.add(line to System.currentTimeMillis())
                    if (line == "event: clear") return seen
                }
            }
            var oldSeen: List<Pair<String, Long>> = emptyList()
            val reading = Thread { oldSeen = events(old) }.apply { start() }
            val start = System.currentTimeMillis()
            server.sendSubtitle("Selam", 4000, null)
            server.clear()
            val freshSeen = events(fresh)
            assertTrue("Yeni TV satırı kendisi tutar: clear hemen gider", freshSeen.last().second - start < 1000)
            // Satır kalkmadan yeni satır geldi: eski TV'ye bekleyen clear gitmez, yenisininki süresi dolunca gider.
            Thread.sleep(500 - (System.currentTimeMillis() - start).coerceAtMost(500))
            server.sendSubtitle("Yeni", 4000, null)
            server.clear()
            reading.join(8000)
            assertEquals(2, oldSeen.count { it.first == "event: subtitle" })
            // İkinci satır 0,5 sn'de geldi; 4 harf → 2,24 sn tutulur.
            assertTrue(oldSeen.last().first == "event: clear" && oldSeen.last().second - start > 2500)
            assertEquals(2240L, SubtitleServer.legacyClearHoldMs(4))
            assertEquals(5000L, SubtitleServer.legacyClearHoldMs(500))
        } finally {
            server.stop()
        }
    }

    @Test
    fun subtitlesStayOffTheTvWhenShownOnThePhone() {
        val server = SubtitleServer(0)
        server.sendsToTv = false
        val events = mutableListOf<SubtitleEvent>()
        server.onEvent = { events.add(it) }
        server.sendSubtitle("Merhaba", 1000, null)
        server.clear()
        assertEquals(listOf(SubtitleEvent.Subtitle("Merhaba", 1000), SubtitleEvent.Cleared), events)
    }

    /** Altyazının oyundaki yeri olayla da gider (Mac/Windows'taki pencere "Yazı kadar" kutuyu onu örtecek kadar büyütür). */
    @Test
    fun localListenerGetsTheSubtitleBox() {
        val server = SubtitleServer(0)
        server.sendsToTv = false
        val events = mutableListOf<SubtitleEvent>()
        server.onEvent = { events.add(it) }
        val box = TextBox(0.25, 0.8, 0.75, 0.9)
        server.sendSubtitle("Merhaba", 4000, box)
        assertEquals(listOf(SubtitleEvent.Subtitle("Merhaba", 4000, box = box)), events)
    }

    /** Ekranın büyük kısmını kaplayan opak kutu TV'ye gitmez (LG'de "siyah ekran"; Windows/Mac ile aynı kural). */
    @Test
    fun dropsBoxesCoveringMostOfTheScreen() {
        fun item(box: TextBox) = ScreenTranslation.Item("Hi", "Selam", box, 0.03)
        val small = item(TextBox(0.5, 0.5, 0.6, 0.55))
        val huge = item(TextBox(0.0, 0.0, 1.0, 0.9))
        assertEquals("Selam" to listOf(small), SubtitleServer.guarded("Selam", TextBox(0.0, 0.0, 1.0, 0.9), listOf(small, huge)))
        assertEquals("", SubtitleServer.guarded("Selam", TextBox(0.0, 0.0, 1.0, 1.0), null).first)
        val many = (0 until 10).map { item(TextBox(0.0, it * 0.1, 0.5, it * 0.1 + 0.1)) }
        assertEquals("", SubtitleServer.guarded("y", TextBox(0.0, 0.0, 0.5, 1.0), many).first)
        assertEquals("Görev" to null, SubtitleServer.guarded("Görev", TextBox(0.7, 0.05, 0.95, 0.1), null))
        assertFalse(SubtitleServer.regionFrame("auto-1", "Selam", TextBox(0.0, 0.0, 1.0, 1.0), 0.03).contains("Selam"))
    }
}
