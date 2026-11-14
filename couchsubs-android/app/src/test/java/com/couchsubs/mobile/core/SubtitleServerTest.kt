// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
            "event: style\ndata: {\"background\":72,\"bold\":false,\"bottomPercent\":7,\"displayMode\":\"inApp\",\"fontSize\":46," +
                "\"placement\":\"cover\",\"textColor\":\"white\"}\n\n",
            SubtitleServer.styleFrame(SubtitleStyle()),
        )
        assertTrue(SubtitleServer.styleFrame(SubtitleStyle(displayMode = TvDisplayMode.OVERLAY, textColor = SubtitleTextColor.YELLOW))
            .contains("\"displayMode\":\"overlay\""))
    }

    @Test
    fun helloIdentifiesTheServer() {
        val server = SubtitleServer(0)
        val port = server.start()
        try {
            Socket("127.0.0.1", port).use { socket ->
                socket.getOutputStream().write("GET /hello HTTP/1.1\r\nHost: x\r\n\r\n".toByteArray())
                val response = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
                assertTrue(response, response.startsWith("HTTP/1.1 200 OK"))
                assertTrue(response.contains("Access-Control-Allow-Origin: *"))
                assertTrue(response.endsWith("{\"app\":\"couchsubs\"}"))
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
}
