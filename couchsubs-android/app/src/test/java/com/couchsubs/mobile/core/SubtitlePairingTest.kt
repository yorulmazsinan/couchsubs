// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONArray
class SubtitlePairingTest {
    @Test fun sharedLifecycleVectors() {
        val scenarios = JSONArray(Fixtures.text("subtitle-pairing.json"))
        for (i in 0 until scenarios.length()) {
            var time = 1000L
            val pairing = SubtitlePairing { time }
            var id = ""
            val steps = scenarios.getJSONObject(i).getJSONArray("steps")
            for (j in 0 until steps.length()) {
                val step = steps.getJSONObject(j)
                val who = if (step.optBoolean("wrong")) "not-the-request-secret" else id
                when (step.getString("op")) {
                    "session" -> pairing.setSession(step.getBoolean("value"))
                    "open" -> pairing.open()
                    "reset" -> pairing.reset()
                    "advance" -> time += step.getLong("ms")
                    "begin" -> { val ticket = pairing.begin(); assertEquals(step.getBoolean("ok"), ticket != null)
                        if (ticket != null) { assertEquals(22, ticket.id.length); assertEquals(6, ticket.code.length); id = ticket.id } }
                    "resolve" -> assertEquals(step.getBoolean("ok"), pairing.resolve(who, step.getBoolean("accept")))
                    "poll" -> assertEquals(step.getString("state"), pairing.poll(who))
                }
            }
        }
    }

    @Test fun wireApprovalAndRotation() {
        val server = SubtitleServer(0, allowLegacy = false)
        val port = server.start()
        fun call(method: String, path: String, origin: String? = null): String = java.net.Socket("127.0.0.1", port).use { socket ->
            socket.soTimeout = 5000
            socket.getOutputStream().write(("$method $path HTTP/1.1\r\nHost: localhost:$port\r\n" + (origin?.let { "Origin: $it\r\n" } ?: "") + "\r\n").toByteArray())
            socket.getInputStream().readBytes().toString(Charsets.UTF_8)
        }
        try {
            assertTrue(call("POST", "/pair").startsWith("HTTP/1.1 409"))
            server.pairing.open()
            assertTrue(call("POST", "/pair", "https://foreign.example").startsWith("HTTP/1.1 403"))
            val ticket = org.json.JSONObject(call("POST", "/pair").substringAfter("\r\n\r\n"))
            val id = ticket.getString("id")
            assertFalse(call("GET", "/pair?id=$id").contains(server.accessKey))
            assertTrue(server.pairing.resolve(id, true))
            assertTrue(call("GET", "/pair?id=$id").contains(server.accessKey))
            assertFalse(call("GET", "/pair?id=wrong").contains(server.accessKey))
            server.rotateKey(SubtitleAccess.createKey())
            assertFalse(call("GET", "/pair?id=$id").contains(server.accessKey))
            assertTrue(call("GET", "/pair?id=$id").contains("expired"))
        } finally { server.stop() }
    }

    @Test fun obsPageIsPublicButItsEventsNeedTheKeyOutsideTransition() {
        val html = "<html>Türkçe altyazı</html>"
        val server = SubtitleServer(0, allowLegacy = false, obsOverlay = html)
        val port = server.start()
        try {
            java.net.Socket("127.0.0.1", port).use { socket ->
                socket.getOutputStream().write("GET /obs HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                val reply = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
                assertTrue(reply.startsWith("HTTP/1.1 200"))
                assertTrue(reply.contains("Content-Type: text/html; charset=utf-8"))
                assertTrue(reply.contains("Content-Length: ${html.toByteArray(Charsets.UTF_8).size}"))
                assertTrue(reply.endsWith(html)); assertFalse(reply.contains(server.accessKey))
            }
            java.net.Socket("127.0.0.1", port).use { socket ->
                socket.getOutputStream().write("GET /events?viewer=obs HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                assertTrue(socket.getInputStream().readBytes().toString(Charsets.UTF_8).startsWith("HTTP/1.1 401"))
            }
        } finally { server.stop() }
    }
}
