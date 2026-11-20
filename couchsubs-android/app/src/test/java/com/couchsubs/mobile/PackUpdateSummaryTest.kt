// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile

import com.couchsubs.mobile.packs.PackDownloadException
import com.couchsubs.mobile.packs.PackServer
import com.couchsubs.mobile.packs.PackStore
import com.couchsubs.mobile.packs.PackUpdateOutcome
import com.couchsubs.mobile.packs.PackUpdateSummary
import com.couchsubs.mobile.packs.RemotePack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/** "Paketleri güncelle" sonucunun özeti (iPhone'daki PackUpdateSummaryTests ile aynı durumlar). */
class PackUpdateSummaryTest {
    private fun pack(id: String, title: String, entries: Int, data: ByteArray = id.toByteArray(), version: Long = 1) =
        RemotePack(id, title, version, PackStore.sha256(data), data.size.toLong(), entries)

    @Test
    fun updatedAndAddedPacks() {
        val summary = PackUpdateSummary.of(
            listOf("gta-6" to 74_673, "rdr-2" to 20_000, "elden-ring" to 37_951),
            listOf(pack("gta-6", "Grand Theft Auto VI", 86_973), pack("rdr-2", "Red Dead Redemption 2", 20_800),
                pack("death-stranding-2", "Death Stranding 2", 23_132)))
        assertEquals(listOf("gta-6", "rdr-2"), summary.updated.map { it.id })
        assertEquals(listOf(12_300, 800), summary.updated.map { it.lineDelta })
        assertEquals(listOf("death-stranding-2"), summary.added.map { it.id })
        assertEquals(12_300 + 800 + 23_132, summary.newLines)
    }

    @Test
    fun shrinkingPackDoesNotReduceNewLinesAndDuplicatesCountOnce() {
        val summary = PackUpdateSummary.of(listOf("a" to 1000, "b" to 400, "b" to 500),
            listOf(pack("a", "A", 900), pack("b", "B", 700), pack("b", "B", 700)))
        assertEquals(listOf(-100, 200), summary.changes.map { it.lineDelta })
        assertEquals(200, summary.newLines)
    }

    @Test
    fun outcomes() {
        assertEquals(PackUpdateOutcome.UpToDate, PackUpdateOutcome.of(listOf("a" to 1), PackStore.Refresh(), null))
        val offline = PackUpdateOutcome.of(emptyList(), null, PackDownloadException(null, "network"))
        assertEquals(PackUpdateOutcome.Reason.OFFLINE, (offline as PackUpdateOutcome.Failed).reason)
        val rate = PackUpdateOutcome.of(emptyList(), null, PackDownloadException(429, "HTTP 429")) as PackUpdateOutcome.Failed
        assertEquals(PackUpdateOutcome.Reason.RATE_LIMITED, rate.reason)
        val server = PackUpdateOutcome.of(emptyList(), null, PackDownloadException(503, "HTTP 503")) as PackUpdateOutcome.Failed
        assertEquals(PackUpdateOutcome.Reason.SERVER to 503, server.reason to server.status)
    }

    /** Elle güncellemede sürümü artan paket gerçekten iner ve özette satır farkıyla görünür; biri inemezse ötekiler yine özette. */
    @Test
    fun forcedRefreshDownloadsNewVersionAndSummarizes() {
        val dir = Files.createTempDirectory("packs").toFile()
        val v4 = "gta-6 v4".toByteArray()
        val v5 = "gta-6 v5".toByteArray()
        val other = "rdr".toByteArray()
        val files = mutableMapOf("gta-6" to v4)
        var listing = listOf(pack("gta-6", "Grand Theft Auto VI", 74_673, v4, 4))
        val server = object : PackServer {
            override fun list() = listing
            override fun download(id: String) = files[id] ?: throw PackDownloadException(404, "missing")
        }
        val store = PackStore(dir, server, clock = { 1_000L })
        store.refresh(force = true)
        // Sunucuda v5 çıktı ve yeni bir paket eklendi; son bakış daha yeni olsa da elle güncelleme (force) bakar.
        files["gta-6"] = v5
        listing = listOf(pack("gta-6", "Grand Theft Auto VI", 86_973, v5, 5), pack("rdr-2", "Red Dead Redemption 2", 800, other))
        val result = store.refresh(force = true)
        val outcome = PackUpdateOutcome.of(listOf("gta-6" to 74_673), result, null)
        assertTrue(outcome is PackUpdateOutcome.Failed) // rdr-2 dosyası yok (404)
        val summary = (outcome as PackUpdateOutcome.Failed).summary
        assertEquals(PackUpdateOutcome.Reason.PARTIAL, outcome.reason)
        assertEquals(listOf(12_300), summary.updated.map { it.lineDelta })
        assertEquals(5L, store.installed().single { it.id == "gta-6" }.version)

        files["rdr-2"] = other
        val fixed = PackUpdateOutcome.of(listOf("gta-6" to 86_973), store.refresh(force = true), null)
        assertEquals(listOf("rdr-2"), (fixed as PackUpdateOutcome.Updated).summary.added.map { it.id })
    }
}
