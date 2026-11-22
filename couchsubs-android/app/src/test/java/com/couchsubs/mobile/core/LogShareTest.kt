// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * "Günlükleri paylaş": paylaşılan dosyada kişisel veri kalmaz. Kurallar ortak deneme dosyasından (fixtures/log-redaction.json,
 * core/Tests/CouchSubsCoreTests/Fixtures kopyası; iPhone/Mac LogShareTests.swift aynı dosyayı okur).
 */
class LogShareTest {
    @Test fun sharedRedactionCases() {
        val cases = JSONArray(Fixtures.text("log-redaction.json"))
        assertTrue(cases.length() > 10)
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            assertEquals(case.getString("input"), case.getString("expected"), LogShare.redact(case.getString("input")))
        }
    }

    @Test fun combinesLogsAndMarksMissing() {
        val text = LogShare.combined("CouchSubs Android 1.0", listOf(
            "logcat" to "PS5 kaydı başlıyor: 192.168.1.20, hesap kimliği q83vEjRWeJA=",
            "tvinstall.log" to null,
        ))
        assertTrue(text.startsWith("CouchSubs Android 1.0\n\n===== logcat =====\n\nPS5 kaydı başlıyor: 192.168.1.20, hesap kimliği ***\n"))
        assertFalse(text.contains("q83vEjRWeJA"))
        assertTrue(text.endsWith("===== tvinstall.log =====\n\n(yok)\n"))
    }

    @Test fun tailKeepsWholeLines() {
        val file = File.createTempFile("log-share", ".log")
        try {
            assertNull(LogShare.tail(File(file.path + ".yok")))
            file.writeText("a".repeat(LogShare.MAX_BYTES_PER_LOG) + "\nson satır\n")
            assertEquals("son satır\n", LogShare.tail(file))
        } finally {
            file.delete()
        }
    }
}

/** "Bağlanıyor…" 30 sn'yi geçince nedeni söylenir (core LogShareTests.swift ve Windows ConnectingHintTests ile aynı). */
class ConnectingHintTest {
    @Test fun reasonAfterThirtySeconds() {
        assertNull(ConnectingHint.reason(29_000, ConnectStep.WAKING))
        assertEquals(ConnectStep.WAKING, ConnectingHint.reason(30_000, ConnectStep.WAKING))
        assertEquals(ConnectStep.OPENING, ConnectingHint.reason(45_000, ConnectStep.OPENING))
        assertEquals(ConnectStep.NO_ANSWER, ConnectingHint.reason(60_000, null))
    }
}
