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
