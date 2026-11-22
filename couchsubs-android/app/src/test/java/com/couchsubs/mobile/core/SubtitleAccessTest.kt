// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.net.InetAddress
import java.net.Socket
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SubtitleAccessTest {
    @Test fun sharedAccessVectors() {
        val vectors = JSONObject(Fixtures.text("subtitle-access.json"))
        val rows = vectors.getJSONArray("requests")
        for (i in 0 until rows.length()) {
            val row = rows.getJSONObject(i)
            val origin = if (row.isNull("origin")) null else row.getString("origin")
            for (path in listOf("/events", "/speech/1.wav", "/voices/sample.wav", "/published.bin")) {
                val head = "GET $path${row.getString("query")} HTTP/1.1\r\nHost: localhost:8787\r\n" + (origin?.let { "Origin: $it\r\n" } ?: "")
                val request = SubtitleAccess.parse(head)!!
                val result = SubtitleAccess.authorize(request, vectors.getString("key"), row.getBoolean("legacy"))
                assertEquals(head, row.getInt("status"), result.status)
                assertEquals(head, row.getBoolean("usedLegacy"), result.legacy)
                val cors = if (origin == "null" || origin == "file://" || origin == "app://couchsubs") "Access-Control-Allow-Origin: $origin\r\nVary: Origin\r\n" else ""
                assertEquals(cors, SubtitleAccess.cors(request))
            }
        }
        val peers = vectors.getJSONObject("peers")
        for (address in peers.keys()) assertEquals(address, peers.getBoolean(address), SubtitleAccess.isLocalPeer(InetAddress.getByName(address)))
    }
    @Test fun keysAndAmbiguousRequests() {
        val key = SubtitleAccess.createKey()
        assertTrue(key.matches(Regex("[A-Za-z0-9_-]{22}")))
        assertNotEquals(key, SubtitleAccess.createKey())
        for (head in listOf("Origin: null\r\nOrigin: null", "Host: localhost\r\nHost: other", " Origin: null"))
            assertNull(SubtitleAccess.parse("GET /events HTTP/1.1\r\n$head"))
        val request = SubtitleAccess.parse("GET /events?k=$key&k=$key HTTP/1.1\r\nHost: localhost")!!
        assertEquals(401, SubtitleAccess.authorize(request, key, true).status)
    }
    @Test fun keylessObsPageIsNotReportedAsOldTvApp() {
        val server = SubtitleServer(port = 0, allowLegacy = true)
        val port = server.start()
        try {
            Socket("127.0.0.1", port).use { socket ->
                socket.soTimeout = 3000
                socket.getOutputStream().write("GET /events?viewer=obs HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                assertTrue(socket.getInputStream().bufferedReader().readLine().contains("200"))
                assertFalse(server.hasLegacyClient)
            }
            Socket("127.0.0.1", port).use { socket ->
                socket.soTimeout = 3000
                socket.getOutputStream().write("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                assertTrue(socket.getInputStream().bufferedReader().readLine().contains("200"))
                assertTrue(server.hasLegacyClient)
            }
        } finally { server.stop() }
    }
    /** TV uygulaması sürümünü akışla bildirir; bildirmeyen TV (0.9.69'den eski) eski sayılır, OBS sayılmaz (#884, #891). */
    @Test fun remembersTheTvAppVersionAndTreatsSilentTvsAsOld() {
        val server = SubtitleServer(port = 0, allowLegacy = true)
        val reported = mutableListOf<String>()
        server.onTvAppVersion = { synchronized(reported) { reported.add(it) } }
        val port = server.start()
        try {
            assertNull(server.tvAppVersion)
            for ((query, expected) in listOf("?viewer=obs" to null, "?hdmi=2" to "", "?v=0.9.69&hdmi=2" to "0.9.69")) {
                Socket("127.0.0.1", port).use { socket ->
                    socket.soTimeout = 3000
                    socket.getOutputStream().write("GET /events$query HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                    assertTrue(socket.getInputStream().bufferedReader().readLine().contains("200"))
                    assertEquals(query, expected, server.tvAppVersion)
                }
            }
            assertEquals(listOf("", "0.9.69"), synchronized(reported) { reported.toList() })
        } finally { server.stop() }
        assertEquals("", SubtitleServer.tvAppVersion("0.9.70<script>"))
        assertTrue(SubtitleServer.isTvAppOutdated("", "0.9.69"))
        assertTrue(SubtitleServer.isTvAppOutdated("0.9.49", "0.9.69"))
        assertFalse(SubtitleServer.isTvAppOutdated("0.9.69", "0.9.69"))
        assertFalse(SubtitleServer.isTvAppOutdated("0.9.70", "0.9.69"))
        assertFalse(SubtitleServer.isTvAppOutdated("", ""))
        val tv = com.couchsubs.mobile.tv.InstalledTv(com.couchsubs.mobile.tv.TvBrand.LG, "192.168.1.5")
        assertEquals(com.couchsubs.mobile.tv.TvAppStatus.Outdated(tv, "< 0.9.69", "0.9.69"),
            com.couchsubs.mobile.tv.TvAppUpdate.decide(tv, "", "0.9.69"))
        assertEquals(com.couchsubs.mobile.tv.TvAppStatus.UpToDate("0.9.69"), com.couchsubs.mobile.tv.TvAppUpdate.decide(tv, "0.9.69", "0.9.69"))
    }
    /** İkinci ekran eski TV'lere tanınan anahtarsız geçişten yararlanmaz (Mac ve Windows'ta aynı durumlar). */
    @Test fun secondScreenAlwaysNeedsTheKey() {
        val cases = listOf("/view" to 401, "/view?k=yanlis" to 401, "/view?k=anahtar" to 200, "/events?viewer=second" to 401,
            "/events?viewer=second&k=anahtar" to 200, "/events" to 200, "/events?viewer=obs" to 200)
        for ((target, status) in cases) {
            val request = SubtitleAccess.parse("GET $target HTTP/1.1\r\nHost: 192.168.1.20:8787\r\n")!!
            assertEquals(target, status, SubtitleAccess.authorize(request, "anahtar", true).status)
        }
        val same = SubtitleAccess.parse("GET /events?viewer=second&k=anahtar HTTP/1.1\r\nHost: 192.168.1.20:8787\r\nOrigin: http://192.168.1.20:8787\r\n")!!
        assertEquals(200, SubtitleAccess.authorize(same, "anahtar", true).status)
    }
    /** Doğru anahtarla sayfa gelir; akış TV sayılmaz ve altyazı yalnız telefondayken de altyazıyı alır. */
    @Test fun secondScreenPageAndStream() {
        val server = SubtitleServer(port = 0, key = "dogru-anahtar", allowLegacy = true, secondScreenPage = "<html>ikinci</html>")
        server.sendsToTv = false
        val port = server.start()
        try {
            for (target in listOf("/view", "/view?k=yanlis", "/events?viewer=second")) Socket("127.0.0.1", port).use { socket ->
                socket.soTimeout = 3000
                socket.getOutputStream().write("GET $target HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                assertTrue(target, socket.getInputStream().bufferedReader().readLine().contains("401"))
            }
            Socket("127.0.0.1", port).use { socket ->
                socket.soTimeout = 3000
                socket.getOutputStream().write("GET /view?k=dogru-anahtar HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                val response = socket.getInputStream().bufferedReader().readText()
                assertTrue(response.startsWith("HTTP/1.1 200"))
                assertTrue(response.contains("text/html"))
                assertTrue(response.endsWith("<html>ikinci</html>"))
            }
            Socket("127.0.0.1", port).use { socket ->
                socket.soTimeout = 3000
                socket.getOutputStream().write("GET /events?viewer=second&k=dogru-anahtar HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                val reader = socket.getInputStream().bufferedReader()
                assertTrue(reader.readLine().contains("200"))
                Thread.sleep(200)
                assertEquals(0, server.connectedClients)
                assertFalse(server.hasLegacyClient)
                server.sendSubtitle("Merhaba", 4000)
                var line = reader.readLine()
                while (line != null && !line.contains("Merhaba")) line = reader.readLine()
                assertTrue(line!!.startsWith("data:") && line.contains("\"text\":\"Merhaba\""))
            }
        } finally { server.stop() }
    }
    @Test fun secondScreenAddressCarriesTheKey() {
        assertEquals("http://192.168.1.20:8787/view?k=a-b_C9", SecondScreen.address("192.168.1.20", 8787, "a-b_C9"))
        assertEquals("http://[fe80::1]:8787/view?k=k", SecondScreen.address("fe80::1", 8787, "k"))
        val modules = SecondScreen.qrModules("http://192.168.1.20:8787/view?k=a-b_C9")
        assertTrue(modules.size >= 21)
        assertTrue(modules.all { it.size == modules.size })
    }
    @Test fun rotationRejectsPreviousKey() {
        val server = SubtitleServer(port = 0, allowLegacy = false)
        val port = server.start()
        try {
            val old = server.accessKey
            Socket("127.0.0.1", port).use { socket ->
                socket.soTimeout = 3000
                socket.getOutputStream().write("GET /events?k=$old HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                assertTrue(socket.getInputStream().bufferedReader().readLine().contains("200"))
                server.rotateKey(SubtitleAccess.createKey())
                assertEquals(0, server.connectedClients)
            }
            Socket("127.0.0.1", port).use { socket ->
                socket.soTimeout = 3000
                socket.getOutputStream().write("GET /events?k=$old HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                assertTrue(socket.getInputStream().bufferedReader().readLine().contains("401"))
            }
        } finally { server.stop() }
    }
}
