// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile

import com.couchsubs.mobile.account.ConsentChoice
import com.couchsubs.mobile.account.ConsentPolicy
import com.couchsubs.mobile.account.EntitlementSnapshot
import com.couchsubs.mobile.account.PackAccess
import com.couchsubs.mobile.account.PackGate
import com.couchsubs.mobile.account.PlanKind
import com.couchsubs.mobile.account.Pricing
import com.couchsubs.mobile.packs.PackDownloadException
import com.couchsubs.mobile.packs.PackServer
import com.couchsubs.mobile.packs.PackStore
import com.couchsubs.mobile.packs.RemotePack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Locale

class ConsentTest {
    @Test
    fun nothingIsCollectedBeforeTheUserDecides() {
        val flags = ConsentPolicy.flags(ConsentChoice(decided = false, analytics = true, ads = true), adsEnabledRemote = true, umpCanRequestAds = true)
        assertFalse(flags.analyticsCollection)
        assertFalse(flags.crashReports)
        assertFalse(flags.metaEnabled)
        assertFalse(flags.adUserData)
        assertFalse(flags.showAds)
    }

    @Test
    fun analyticsAndAdsAreSeparate() {
        val analyticsOnly = ConsentPolicy.flags(ConsentChoice(true, analytics = true, ads = false), false, true)
        assertTrue(analyticsOnly.analyticsCollection)
        assertTrue(analyticsOnly.analyticsStorage)
        assertFalse(analyticsOnly.adStorage)
        assertFalse(analyticsOnly.metaEnabled)
        assertTrue(analyticsOnly.nonPersonalizedAds)

        val adsOnly = ConsentPolicy.flags(ConsentChoice(true, analytics = false, ads = true), false, true)
        assertFalse(adsOnly.analyticsCollection)
        assertTrue(adsOnly.metaEnabled)
        assertTrue(adsOnly.adPersonalization)
        assertFalse(adsOnly.nonPersonalizedAds)
    }

    @Test
    fun adsStayOffUnlessRemoteConfigAndUmpAllow() {
        val choice = ConsentChoice(true, analytics = true, ads = true)
        assertFalse(ConsentPolicy.flags(choice, adsEnabledRemote = false, umpCanRequestAds = true).showAds)
        assertFalse(ConsentPolicy.flags(choice, adsEnabledRemote = true, umpCanRequestAds = false).showAds)
        assertTrue(ConsentPolicy.flags(choice, adsEnabledRemote = true, umpCanRequestAds = true).showAds)
        // Reklam ölçümüne izin vermeyen kullanıcıya da (açılırsa) kişiselleştirilmemiş reklam gider.
        val declined = ConsentPolicy.flags(ConsentChoice(true, analytics = false, ads = false), true, true)
        assertTrue(declined.showAds)
        assertTrue(declined.nonPersonalizedAds)
    }
}

class EntitlementTest {
    private val now = 1_800_000_000_000L

    @Test
    fun activeEntitlementMapsToAccess() {
        val access = PackAccess.from(mapOf("packs" to EntitlementSnapshot(true, now + 86_400_000, true, "couchsubs_packs_annual:yillik")), now)
        assertTrue(access.active)
        assertTrue(access.willRenew)
        assertEquals(PlanKind.ANNUAL, access.plan)
    }

    @Test
    fun missingExpiredOrOtherEntitlementsGiveNoAccess() {
        assertFalse(PackAccess.from(emptyMap(), now).active)
        assertFalse(PackAccess.from(mapOf("other" to EntitlementSnapshot(true, null, false, "x")), now).active)
        assertFalse(PackAccess.from(mapOf("packs" to EntitlementSnapshot(false, now + 1000, false, "couchsubs_packs_monthly")), now).active)
        // SDK önbelleği etkin dese de süresi geçmiş hak kapalıdır.
        assertFalse(PackAccess.from(mapOf("packs" to EntitlementSnapshot(true, now - 1000, false, "couchsubs_packs_monthly")), now).active)
        // Süresiz (ömür boyu) hak.
        assertTrue(PackAccess.from(mapOf("packs" to EntitlementSnapshot(true, null, false, null)), now).active)
    }

    @Test
    fun planIsReadFromTheProductId() {
        assertEquals(PlanKind.MONTHLY, PlanKind.fromProduct("couchsubs_packs_monthly"))
        assertEquals(PlanKind.ANNUAL, PlanKind.fromProduct("couchsubs_packs_annual"))
        assertNull(PlanKind.fromProduct("something_else"))
        assertEquals("\$rc_annual", PlanKind.ANNUAL.packageId)
    }

    @Test
    fun gateNeedsSubscriptionAndTheSetting() {
        val active = PackAccess(true)
        assertTrue(PackGate.allowed(active, packsEnabled = true, debugFree = false))
        assertFalse(PackGate.allowed(active, packsEnabled = false, debugFree = false))
        assertFalse(PackGate.allowed(PackAccess.None, packsEnabled = true, debugFree = false))
        assertTrue(PackGate.allowed(PackAccess.None, packsEnabled = true, debugFree = true))
        assertFalse(PackGate.allowed(PackAccess.None, packsEnabled = false, debugFree = true))
    }

    @Test
    fun annualPriceIsShownPerMonth() {
        val tr = Locale("tr", "TR")
        assertEquals(java.text.NumberFormat.getCurrencyInstance(tr).apply { currency = java.util.Currency.getInstance("TRY") }.format(299),
            Pricing.perMonth(3_588_000_000L, "TRY", tr))
        assertEquals(25, Pricing.savingPercent(399_000_000L, 3_588_000_000L))
        assertEquals(0, Pricing.savingPercent(0, 1))
    }
}

class PackStoreTest {
    private class FakeServer(var packs: List<RemotePack>, val files: MutableMap<String, ByteArray>) : PackServer {
        val downloads = mutableListOf<String>()
        var status: Int? = null
        override fun list() = packs
        override fun download(id: String, idToken: String): ByteArray {
            assertEquals("token", idToken)
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
        val store = PackStore(dir, server, { "token" }, { now })
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
        val store = PackStore(dir, server, { "token" }, { now })
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
        val store = PackStore(dir, server, { "token" })
        assertEquals(emptyList<String>(), store.refresh().downloaded)
        assertTrue(store.files().isEmpty())
        assertFalse(File(dir, "gta-v.json.gz").exists())
        // Kontrol zamanı ilerlemez: sonraki açılışta yeniden denenir.
        server.files["gta-v"] = gta
        assertEquals(listOf("gta-v"), store.refresh().downloaded)
    }

    @Test
    fun endedSubscriptionRemovesPacks() {
        val dir = Files.createTempDirectory("packs").toFile()
        var now = 1_000L
        val server = FakeServer(listOf(remote("gta-v", gta)), mutableMapOf("gta-v" to gta))
        val store = PackStore(dir, server, { "token" }, { now })
        store.refresh()
        server.packs = listOf(remote("gta-v", "new".toByteArray(), version = 2))
        server.status = 403
        now += PackStore.REFRESH_INTERVAL_MS
        val error = assertThrows(PackDownloadException::class.java) { store.refresh() }
        assertEquals(403, error.status)
        assertTrue(store.files().isEmpty())
    }

    @Test
    fun signedOutUserCannotDownload() {
        val store = PackStore(Files.createTempDirectory("packs").toFile(), FakeServer(listOf(remote("gta-v", gta)), mutableMapOf()), { null })
        assertEquals(401, assertThrows(PackDownloadException::class.java) { store.refresh() }.status)
    }

    @Test
    fun downloadedPacksLoadIntoTheLibrary() {
        val dir = Files.createTempDirectory("packs").toFile()
        val pack = com.couchsubs.mobile.core.Fixtures.bytes("pack-wrapped.json.gz")
        val store = PackStore(dir, FakeServer(listOf(remote("test-game", pack)), mutableMapOf("test-game" to pack)), { "token" })
        store.refresh()
        val library = com.couchsubs.mobile.core.GamePackLibrary(null, store.files().first().parentFile)
        assertEquals(listOf("test-game"), library.infos.map { it.id })
        assertEquals("Yere yat!", library.find("Get Down!"))
    }
}
