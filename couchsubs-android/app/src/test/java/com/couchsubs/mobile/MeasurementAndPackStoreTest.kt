// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile

import com.couchsubs.mobile.account.MeasurementPolicy
import com.couchsubs.mobile.packs.PackDownloadException
import com.couchsubs.mobile.packs.PackServer
import com.couchsubs.mobile.packs.PackStore
import com.couchsubs.mobile.packs.RemotePack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class MeasurementPolicyTest {
    @Test
    fun usageDataSwitchControlsEverything() {
        val off = MeasurementPolicy.flags(usageData = false, welcomeSeen = true)
        assertFalse(off.analyticsCollection)
        assertFalse(off.crashReports)
        assertFalse(off.metaEvents)

        val on = MeasurementPolicy.flags(usageData = true, welcomeSeen = true)
        assertTrue(on.analyticsCollection)
        assertTrue(on.crashReports)
        assertTrue(on.metaEvents)
    }

    @Test
    fun metaEventsWaitForWelcome() {
        val flags = MeasurementPolicy.flags(usageData = true, welcomeSeen = false)
        assertTrue(flags.analyticsCollection)
        assertFalse(flags.metaEvents)
    }
}

class PackStoreTest {
    private class FakeServer(var packs: List<RemotePack>, val files: MutableMap<String, ByteArray>) : PackServer {
        val downloads = mutableListOf<String>()
        var status: Int? = null
        override fun list() = packs
        override fun download(id: String): ByteArray {
            status?.let { throw PackDownloadException(it, "HTTP $it") }
            downloads.add(id)
            return files[id] ?: throw PackDownloadException(404, "missing")
        }
    }

    private fun remote(id: String, data: ByteArray, version: Long = 1) = RemotePack(id, id.uppercase(), version, PackStore.sha256(data), data.size.toLong(), 1)

    private val gta = "gta".toByteArray()
    private val rdr = "rdr".toByteArray()

    @Test
    fun downloadsVerifiesAndReusesPacks() {
        val dir = Files.createTempDirectory("packs").toFile()
        var now = 1_000L
        val server = FakeServer(listOf(remote("gta-v", gta), remote("rdr2", rdr)), mutableMapOf("gta-v" to gta, "rdr2" to rdr))
        val store = PackStore(dir, server, { now })
        assertEquals(listOf("gta-v", "rdr2"), store.refresh().downloaded)
        assertEquals(setOf("gta-v.json.gz", "rdr2.json.gz"), store.files().map { it.name }.toSet())
        // Haftası dolmadan sunucuya bakılmaz.
        now += 60_000
        assertTrue(store.refresh().skipped)
        // Zorla yenilemede aynı sürüm yeniden inmez.
        assertEquals(emptyList<String>(), store.refresh(force = true).downloaded)
        assertEquals(listOf("gta-v", "rdr2"), server.downloads)
    }

    @Test
    fun weeklyRefreshUpdatesChangedAndRemovesDroppedPacks() {
        val dir = Files.createTempDirectory("packs").toFile()
        var now = 1_000L
        val server = FakeServer(listOf(remote("gta-v", gta), remote("rdr2", rdr)), mutableMapOf("gta-v" to gta, "rdr2" to rdr))
        val store = PackStore(dir, server, { now })
        store.refresh()
        val newGta = "gta v2".toByteArray()
        server.files["gta-v"] = newGta
        server.packs = listOf(remote("gta-v", newGta, version = 2))
        now += PackStore.REFRESH_INTERVAL_MS
        val result = store.refresh()
        assertEquals(listOf("gta-v"), result.downloaded)
        assertEquals(listOf("rdr2"), result.removed)
        assertEquals("gta v2", File(dir, "gta-v.json.gz").readText())
        assertFalse(File(dir, "rdr2.json.gz").exists())
        assertEquals(2L, store.installed().single().version)
    }

    @Test
    fun corruptDownloadIsNeverInstalled() {
        val dir = Files.createTempDirectory("packs").toFile()
        val server = FakeServer(listOf(remote("gta-v", gta)), mutableMapOf("gta-v" to "tampered".toByteArray()))
        val store = PackStore(dir, server)
        assertEquals(emptyList<String>(), store.refresh().downloaded)
        assertTrue(store.files().isEmpty())
        assertFalse(File(dir, "gta-v.json.gz").exists())
        // Kontrol zamanı ilerlemez: sonraki açılışta yeniden denenir.
        server.files["gta-v"] = gta
        assertEquals(listOf("gta-v"), store.refresh().downloaded)
    }

    @Test
    fun rateLimitedDownloadKeepsTheOldVersionAndRetries() {
        val dir = Files.createTempDirectory("packs").toFile()
        var now = 1_000L
        val server = FakeServer(listOf(remote("gta-v", gta)), mutableMapOf("gta-v" to gta))
        val store = PackStore(dir, server, { now })
        store.refresh()
        val newGta = "gta v2".toByteArray()
        server.files["gta-v"] = newGta
        server.packs = listOf(remote("gta-v", newGta, version = 2))
        server.status = 429
        now += PackStore.REFRESH_INTERVAL_MS
        assertEquals(emptyList<String>(), store.refresh().downloaded)
        assertEquals("gta", File(dir, "gta-v.json.gz").readText())
        // Kontrol zamanı ilerlemedi: sınır kalkınca hemen yeniden denenir.
        server.status = null
        now += 1000
        assertEquals(listOf("gta-v"), store.refresh().downloaded)
    }

    @Test
    fun failedFirstDownloadRetriesWhileAnotherPackIsKept() {
        val dir = Files.createTempDirectory("packs").toFile()
        var now = 1_000L
        val existing = remote("gta-v", gta)
        val newPack = remote("rdr2", rdr)
        val server = FakeServer(listOf(existing), mutableMapOf("gta-v" to gta))
        val store = PackStore(dir, server, { now })
        store.refresh()
        val existingMetadata = store.installed().single()
        val existingFile = File(dir, "gta-v.json.gz")
        val existingContents = existingFile.readBytes()

        server.packs = listOf(existing, newPack)
        now += PackStore.REFRESH_INTERVAL_MS
        assertEquals(emptyList<String>(), store.refresh().downloaded)
        assertEquals(listOf(existingMetadata), store.installed())
        assertTrue(existingFile.readBytes().contentEquals(existingContents))

        server.files["rdr2"] = rdr
        now += 1_000L
        assertEquals(listOf("rdr2"), store.refresh(maxAgeMs = 5_000L).downloaded)
        assertEquals(setOf("gta-v", "rdr2"), store.installed().map { it.id }.toSet())
        assertEquals(existingMetadata, store.installed().first { it.id == "gta-v" })
        assertTrue(existingFile.readBytes().contentEquals(existingContents))
        assertEquals(listOf("gta-v", "rdr2", "rdr2"), server.downloads)
    }

    @Test
    fun checksumMismatchOnFirstDownloadRetriesWhileAnotherPackIsKept() {
        val dir = Files.createTempDirectory("packs").toFile()
        var now = 1_000L
        val existing = remote("gta-v", gta)
        val newPack = remote("rdr2", rdr)
        val server = FakeServer(listOf(existing), mutableMapOf("gta-v" to gta, "rdr2" to "tampered".toByteArray()))
        val store = PackStore(dir, server, { now })
        store.refresh()
        val existingMetadata = store.installed().single()
        val existingFile = File(dir, "gta-v.json.gz")
        val existingContents = existingFile.readBytes()

        server.packs = listOf(existing, newPack)
        now += PackStore.REFRESH_INTERVAL_MS
        assertEquals(emptyList<String>(), store.refresh().downloaded)
        assertEquals(listOf(existingMetadata), store.installed())
        assertTrue(existingFile.readBytes().contentEquals(existingContents))
        assertFalse(File(dir, "rdr2.json.gz").exists())

        server.files["rdr2"] = rdr
        now += 1_000L
        assertEquals(listOf("rdr2"), store.refresh(maxAgeMs = 5_000L).downloaded)
        assertEquals(existingMetadata, store.installed().first { it.id == "gta-v" })
        assertTrue(existingFile.readBytes().contentEquals(existingContents))
        assertEquals(listOf("gta-v", "rdr2", "rdr2"), server.downloads)
    }

    @Test
    fun downloadedPacksLoadIntoTheLibrary() {
        val dir = Files.createTempDirectory("packs").toFile()
        val pack = com.couchsubs.mobile.core.Fixtures.bytes("pack-wrapped.json.gz")
        val store = PackStore(dir, FakeServer(listOf(remote("test-game", pack)), mutableMapOf("test-game" to pack)))
        store.refresh()
        val library = com.couchsubs.mobile.core.GamePackLibrary(null, store.files().first().parentFile)
        assertEquals(listOf("test-game"), library.infos.map { it.id })
        assertEquals("Yere yat!", library.find("Get Down!"))
    }

    @Test
    fun failedDownloadsAreReportedNotSwallowed() {
        // "Paketleri güncelle" hata verince ekranda yazsın diye: hangi paketin inmediği ve ağ hatası olup olmadığı döner.
        val dir = Files.createTempDirectory("packs").toFile()
        val server = FakeServer(listOf(remote("gta-6", gta), remote("gta-v", rdr)), mutableMapOf("gta-v" to rdr))
        val store = PackStore(dir, server)
        val missing = store.refresh(force = true)
        assertEquals(listOf("gta-v"), missing.downloaded)
        assertEquals(listOf("gta-6"), missing.failed)
        assertFalse(missing.offline)
        assertEquals(Services.PackStatus.FAILED, Services.packStatus(missing))

        val offline = object : PackServer {
            override fun list() = server.packs
            override fun download(id: String): ByteArray = throw PackDownloadException(null, "network")
        }
        val result = PackStore(Files.createTempDirectory("packs").toFile(), offline).refresh(force = true)
        assertEquals(listOf("gta-6", "gta-v"), result.failed)
        assertTrue(result.offline)
        assertEquals(Services.PackStatus.OFFLINE, Services.packStatus(result))

        server.files["gta-6"] = gta
        val fixed = store.refresh(force = true)
        assertEquals(listOf("gta-6"), fixed.downloaded)
        assertEquals(Services.PackStatus.READY, Services.packStatus(fixed))
    }

    @Test
    fun packsAlreadyBundledAreNotDownloadedAgain() {
        // Sunucudaki gibi: uygulamayla gelen paket (gta-v) sunucuda aynı özetle durur, yeni paket (gta-6) yalnız sunucuda.
        // Eskiden ilk açılışta bütün paketler iniyor, GTA 6 sırasını onların arkasında bekliyordu.
        val dir = Files.createTempDirectory("packs").toFile()
        var now = 1_000L
        val server = FakeServer(listOf(remote("gta-6", gta), remote("gta-v", rdr)), mutableMapOf("gta-6" to gta, "gta-v" to rdr))
        val store = PackStore(dir, server, { now }, bundledHashes = { mapOf("gta-v" to PackStore.sha256(rdr)) })
        val result = store.refresh(force = true)
        assertEquals(listOf("gta-6"), result.downloaded)
        assertEquals(listOf("gta-6"), server.downloads)
        assertEquals(Services.PackStatus.READY, Services.packStatus(result))
        assertEquals(setOf("gta-6.json.gz"), store.files().map { it.name }.toSet())
        // Sunucudaki sürüm değişince (uygulamadakinden yeni) iner.
        val newer = "gta v2".toByteArray()
        server.files["gta-v"] = newer
        server.packs = listOf(remote("gta-6", gta), remote("gta-v", newer, version = 2))
        assertEquals(listOf("gta-v"), store.refresh(force = true).downloaded)
        // Sunucu uygulamadakine dönerse inmiş kopya silinir, uygulamayla gelen kullanılır.
        server.packs = listOf(remote("gta-6", gta), remote("gta-v", rdr))
        store.refresh(force = true)
        assertFalse(File(dir, "gta-v.json.gz").exists())
        assertEquals(listOf("gta-6"), store.installed().map { it.id })
        // Süresi dolmadan yeniden bakılmaz.
        now += 60_000
        assertTrue(store.refresh().skipped)
    }

    @Test
    fun allBundledStillRemembersTheCheck() {
        val dir = Files.createTempDirectory("packs").toFile()
        var now = 1_000L
        val server = FakeServer(listOf(remote("gta-v", rdr)), mutableMapOf("gta-v" to rdr))
        val store = PackStore(dir, server, { now }, bundledHashes = { mapOf("gta-v" to PackStore.sha256(rdr)) })
        assertTrue(store.refresh(force = true).downloaded.isEmpty())
        now += 60_000
        // Liste boş kalsa da günde bir bakılır (her oyun değişiminde sunucuya gidilmez).
        assertTrue(store.refresh().skipped)
        assertTrue(server.downloads.isEmpty())
    }

    @Test
    fun packListErrorsMapToStatus() {
        assertEquals(Services.PackStatus.OFFLINE, Services.packStatus(PackDownloadException(null, "network")))
        assertEquals(Services.PackStatus.FAILED, Services.packStatus(PackDownloadException(503, "HTTP 503")))
        assertEquals(Services.PackStatus.FAILED, Services.packStatus(IllegalStateException("bad")))
    }

    @Test
    fun catalogShowsServerPacksNotYetDownloaded() {
        val local = listOf(com.couchsubs.mobile.core.GamePackLibrary.Info("gta-v", "Grand Theft Auto V", 190_566, true))
        val remote = listOf(RemotePack("gta-6", "Grand Theft Auto VI", 5, "a".repeat(64), 4_073_079, 86_973),
            RemotePack("gta-v", "Grand Theft Auto V", 1, "b".repeat(64), 8_165_110, 190_566))
        val catalog = Services.merge(local, remote)
        assertEquals(listOf("gta-v" to true, "gta-6" to false), catalog.map { it.id to it.installed })
    }
}
