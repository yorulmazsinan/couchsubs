// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv
import com.couchsubs.mobile.R
import org.json.JSONObject
import org.junit.Test
import org.junit.Assert.*
class TvSessionLauncherTest {
    @Test fun bothBrandsReceiveServerAndKeyWithoutAdb() {
        val address = "http://192.168.1.4:8787"
        val key = "ABCDEFGHIJKLMNOPQRSTUV"
        val lg = JSONObject(TvSessionLauncher.launchMessage(TvBrand.LG, address, key)).getJSONObject("payload")
        assertEquals("com.couchsubs.tv", lg.getString("id"))
        val samsung = JSONObject(TvSessionLauncher.launchMessage(TvBrand.SAMSUNG, address, key)).getJSONObject("params").getJSONObject("data")
        assertEquals("CouchSubsT.CouchSubs", samsung.getString("appId"))
        for (params in listOf(lg.getJSONObject("params"), JSONObject(samsung.getString("metaTag")))) {
            assertEquals(address, params.getString("server")); assertEquals(key, params.getString("key"))
        }
    }
    /** #637, #511: kurulu olmayan uygulamaya DEEP_LINK gidince Smart Hub "Sunucu bakım altında (1544007)" diyor. */
    @Test fun samsungInstalledAppListDecidesLaunch() {
        assertEquals("ed.installedApp.get", JSONObject(TvSessionLauncher.SAMSUNG_INSTALLED_APPS_REQUEST).getJSONObject("params").getString("event"))
        val listed = """{"data":{"data":[{"appId":"111299001912","app_type":2,"name":"YouTube"},{"appId":"CouchSubsT.CouchSubs","app_type":2,"name":"CouchSubs"}]},"event":"ed.installedApp.get","from":"host"}"""
        assertEquals(TvSessionLauncher.SamsungAppPresence(true, 2), TvSessionLauncher.samsungInstalledApp(listed))
        assertEquals(TvSessionLauncher.SamsungAppPresence(false, null), TvSessionLauncher.samsungInstalledApp(listed.replace("CouchSubsT.CouchSubs", "Baska.App")))
        assertNull(TvSessionLauncher.samsungInstalledApp("""{"event":"ed.edenTV.update","data":{}}"""))
        assertNull(TvSessionLauncher.samsungInstalledApp("not json"))
        assertEquals("DEEP_LINK", TvSessionLauncher.samsungActionType(2))
        assertEquals("DEEP_LINK", TvSessionLauncher.samsungActionType(null))
        assertEquals("NATIVE_LAUNCH", TvSessionLauncher.samsungActionType(4))
        val native = JSONObject(TvSessionLauncher.launchMessage(TvBrand.SAMSUNG, "http://1.2.3.4:8787", "k", "NATIVE_LAUNCH"))
        assertEquals("NATIVE_LAUNCH", native.getJSONObject("params").getJSONObject("data").getString("action_type"))
    }
    /** beta.63: liste geliştirici moduyla kurulan uygulamayı içermiyorsa telefon uygulamayı hiç açmıyordu. */
    @Test fun samsungKnownInstalledAppLaunchesWithoutTheList() {
        val missing = TvSessionLauncher.SamsungAppPresence(false, null)
        // Uygulama bu TV'den daha önce bağlandı ya da bu telefon kurdu: liste "yok" dese de açılır.
        assertEquals("DEEP_LINK", TvSessionLauncher.samsungAction(true, missing))
        assertEquals("DEEP_LINK", TvSessionLauncher.samsungAction(true, null))
        // Hiç bağlanmamış ve kurulum kaydı yok: liste belirler; listede yoksa komut gönderilmez (#637).
        assertNull(TvSessionLauncher.samsungAction(false, missing))
        assertEquals("DEEP_LINK", TvSessionLauncher.samsungAction(false, TvSessionLauncher.SamsungAppPresence(true, 2)))
        assertEquals("NATIVE_LAUNCH", TvSessionLauncher.samsungAction(false, TvSessionLauncher.SamsungAppPresence(true, 4)))
        // Liste 3 sn'de gelmedi: kurulu olmayan uygulamaya DEEP_LINK Smart Hub'ı mağazaya yollar, TV "Samsung sunucusuna
        // bağlanılamıyor (AS400)" der (Samsung 7 Series 2018); komut gönderilmez, tvinstall.log'a yazılır.
        assertNull(TvSessionLauncher.samsungAction(false, null))
        assertTrue(TvSessionLauncher.samsungNotSentLine("1.2.3.4", null).contains("uygulama listesi 3 sn'de gelmedi; açma isteği gönderilmedi"))
        assertTrue(TvSessionLauncher.samsungNotSentLine("1.2.3.4", missing).contains("açma isteği gönderilmedi"))
        assertEquals(R.string.tv_open_not_installed, TvOpenProblem.reason(TvOpenProblem.NOT_INSTALLED))

        val unknown = InstalledTv(TvBrand.SAMSUNG, "192.168.1.40")
        assertFalse(TvSessionLauncher.samsungKnownInstalled(unknown, null))
        assertFalse(TvSessionLauncher.samsungKnownInstalled(unknown, "192.168.1.41"))
        assertTrue(TvSessionLauncher.samsungKnownInstalled(unknown, "192.168.1.40"))
        assertTrue(TvSessionLauncher.samsungKnownInstalled(unknown.copy(version = "0.9.44"), null))
        assertFalse(TvSessionLauncher.samsungKnownInstalled(InstalledTv(TvBrand.LG, "192.168.1.40", version = "0.9.44"), "192.168.1.40"))
    }
    @Test fun registrationUsesPreviouslyApprovedTvCredential() {
        val payload = JSONObject(TvSessionLauncher.registerMessage("stored-tv-key")).getJSONObject("payload")
        assertEquals("stored-tv-key", payload.getString("client-key"))
        assertEquals("PROMPT", payload.getString("pairingType"))
        assertFalse(JSONObject(TvSessionLauncher.registerMessage(null)).getJSONObject("payload").has("client-key"))
    }

    /** Android TV: uygulama telefonun adresiyle açılır, bağlanana kadar arada bir yeniden; anahtar gitmez (iPhone'daki gibi). */
    @Test fun androidTvIsOpenedWithThePhoneAddressUntilItConnects() {
        val opened = mutableListOf<String>()
        val logged = mutableListOf<String>()
        var rounds = 0
        TvSessionLauncher.keepAndroidTvOpen(InstalledTv(TvBrand.ANDROID_TV, "192.168.1.120", 41235), "http://192.168.1.124:8787",
            active = { rounds < 4 }, connected = { rounds >= 2 },
            open = { host, port, params -> opened += "$host:$port $params"; "Starting" }, log = { logged += it },
            sleep = { rounds++; false }, now = { rounds * 30_000L })
        assertEquals(List(2) { """192.168.1.120:41235 {"server":"http://192.168.1.124:8787"}""" }, opened)
        assertEquals(1, logged.size)
    }

    /**
     * X, Android TV 8 (Mac beta.74): bağlanmış uygulamanın bağlantısı düşünce (kullanıcı kumandadan açtı, başka girişe geçti)
     * bekçi onu bir daha açmaz; hiç bağlanmayan en çok üç kez açılır, TV'de zaten çalışıyorsa açılış sayılmaz. "Otomatik
     * açmayı dene" sayacı sıfırlar.
     */
    @Test fun androidTvIsNotReopenedOnceConnectedAndAtMostThreeTimesOtherwise() {
        var rounds = 0
        var opens = 0
        TvSessionLauncher.keepAndroidTvOpen(InstalledTv(TvBrand.ANDROID_TV, "192.168.1.120"), "http://192.168.1.124:8787",
            active = { rounds < 40 }, connected = { rounds == 3 }, open = { _, _, _ -> opens++; "Starting" },
            sleep = { rounds++; false }, now = { rounds * 5_000L })
        assertEquals(1, opens)

        rounds = 0
        var tries = 0
        TvSessionLauncher.keepAndroidTvOpen(InstalledTv(TvBrand.ANDROID_TV, "192.168.1.120"), "http://192.168.1.124:8787",
            active = { rounds < 120 }, connected = { false },
            open = { _, _, _ -> tries++; if (rounds < 30) com.couchsubs.mobile.tv.android.AndroidTvInstaller.ALREADY_RUNNING else "Starting" },
            sleep = { rounds++; rounds == 100 }, now = { rounds * 5_000L })
        // X (beta.77), "izni sürekli yeniden istiyor": "zaten açık" da bir ADB bağlantısıdır ve sayılır (eskiden sayılmıyor,
        // 30 sn'de bir sınırsız bağlantı açılıyordu). İlk 3 deneme; 100. turda yeniden dene: 3 deneme daha.
        assertEquals(3 + 3, tries)
    }

    /** X (beta.77): onaysız TV'de her ADB bağlantısı izin sorusu açar; çeviri boyunca en çok üç kez sorulur. */
    @Test fun unapprovedAndroidTvIsNotAskedOverAndOver() {
        var rounds = 0
        var tries = 0
        TvSessionLauncher.keepAndroidTvOpen(InstalledTv(TvBrand.ANDROID_TV, "192.168.1.120"), "http://192.168.1.124:8787",
            active = { rounds < 720 }, connected = { false },
            open = { _, _, _ -> tries++
                throw com.couchsubs.mobile.tv.android.AndroidInstallException(com.couchsubs.mobile.tv.android.AndroidInstallError.NOT_APPROVED) },
            sleep = { rounds++; false }, now = { rounds * 5_000L })
        assertEquals(3, tries)
    }

    /**
     * #985: Android TV DHCP'den yeni adres aldı, kurulum onu yeni adreste bulup kaydı güncelledi. Bekçi eski adreste açmaya
     * çalışıp duruyordu; artık kayıtlı TV'nin yeni adresine geçer ve orada yeniden dener.
     */
    @Test fun androidTvKeeperFollowsTheNewAddress() {
        var rounds = 0
        val opened = mutableListOf<String>()
        val logged = mutableListOf<String>()
        var saved = InstalledTv(TvBrand.ANDROID_TV, "192.168.1.120")
        TvSessionLauncher.keepAndroidTvOpen(saved, "http://192.168.1.124:8787",
            active = { rounds < 12 }, connected = { false },
            open = { host, port, _ -> opened += "$host:$port"; throw java.io.IOException("ADB kapalı") }, log = { logged += it },
            sleep = { rounds++; if (rounds == 4) saved = InstalledTv(TvBrand.ANDROID_TV, "192.168.1.121"); false },
            now = { rounds * 30_000L }, current = { saved })
        assertEquals(listOf("192.168.1.120:5555", "192.168.1.120:5555", "192.168.1.120:5555",
            "192.168.1.121:5555", "192.168.1.121:5555", "192.168.1.121:5555"), opened)
        assertTrue(logged.any { it.contains("192.168.1.120:5555 → 192.168.1.121:5555") })
    }

    @Test fun connectedAndroidTvAppNeverGetsAnAdbConnection() {
        var rounds = 0
        var tries = 0
        TvSessionLauncher.keepAndroidTvOpen(InstalledTv(TvBrand.ANDROID_TV, "192.168.1.120"), "http://192.168.1.124:8787",
            active = { rounds < 720 }, connected = { true }, open = { _, _, _ -> tries++; "Starting" },
            sleep = { rounds++; false }, now = { rounds * 5_000L })
        assertEquals(0, tries)
    }

    @Test fun runningTvAppIsRecognised() {
        val installer = com.couchsubs.mobile.tv.android.AndroidTvInstaller
        assertTrue(installer.isRunning("    * Hist #0: ActivityRecord{6c1b2f0 u0 com.couchsubs.tv/.MainActivity t42}"))
        assertTrue(installer.isRunning("  * ServiceRecord{9f3e2a1 u0 com.couchsubs.tv/.OverlayService}"))
        assertFalse(installer.isRunning("    * Hist #0: ActivityRecord{2a1d9e1 u0 com.android.tv.launcher/.MainActivity t1}"))
        assertFalse(installer.isRunning("  mLastPausedActivity: ActivityRecord{6c1b2f0 u0 com.couchsubs.tv/.MainActivity t42}"))
        assertFalse(installer.isRunning("/system/bin/sh: grep: not found"))
        assertFalse(installer.isRunning(""))
    }

    @Test fun closedAdbOnAndroidTvIsSilentAndLoggedOnce() {
        val logged = mutableListOf<String>()
        var rounds = 0
        TvSessionLauncher.keepAndroidTvOpen(InstalledTv(TvBrand.ANDROID_TV, "192.168.1.120"), "http://192.168.1.124:8787",
            active = { rounds < 3 }, connected = { false },
            open = { _, port, _ -> assertEquals(5555, port); throw java.io.IOException("ADB kapalı") }, log = { logged += it },
            sleep = { rounds++; false }, now = { rounds * 30_000L })
        assertEquals(listOf("Android TV (192.168.1.120:5555) telefonun adresiyle açılamadı: ADB kapalı"), logged)
    }

    /** Mobil sürümü deneyen kullanıcı (21 Kas): açma sessizce başarısız oluyordu; nedeni ana ekrana bildirilir. */
    @Test fun androidTvReportsWhyItCouldNotOpen() {
        val results = mutableListOf<TvOpenProblem?>()
        var rounds = 0
        val failures = ArrayDeque(listOf<Exception?>(java.io.IOException("ADB kapalı"),
            com.couchsubs.mobile.tv.android.AndroidInstallException(com.couchsubs.mobile.tv.android.AndroidInstallError.NOT_APPROVED), null))
        TvSessionLauncher.keepAndroidTvOpen(InstalledTv(TvBrand.ANDROID_TV, "192.168.1.120"), "http://192.168.1.124:8787",
            active = { rounds < 3 }, connected = { false },
            open = { _, _, _ -> failures.removeFirst()?.let { throw it }; "Starting" }, sleep = { rounds++; false },
            onOpenResult = { results += it }, now = { rounds * 30_000L })
        assertEquals(listOf(TvOpenProblem.DEBUG_OFF, TvOpenProblem.DEBUG_NOT_APPROVED, null), results)
    }

    @Test fun openProblemDependsOnTheSavedKey() {
        assertEquals(TvOpenProblem.NOT_PAIRED, TvOpenProblem.shown(TvOpenProblem.UNREACHABLE, TvBrand.LG, hasKey = false))
        assertEquals(TvOpenProblem.UNREACHABLE, TvOpenProblem.shown(TvOpenProblem.UNREACHABLE, TvBrand.SAMSUNG, hasKey = true))
        assertEquals(TvOpenProblem.DEBUG_OFF, TvOpenProblem.shown(TvOpenProblem.DEBUG_OFF, TvBrand.ANDROID_TV, hasKey = false))
        assertNull(TvOpenProblem.shown(null, TvBrand.LG, hasKey = false))
        assertNotEquals(TvOpenProblem.openOnTv(TvBrand.ANDROID_TV), TvOpenProblem.openOnTv(TvBrand.LG))
        assertEquals(TvOpenProblem.openOnTv(TvBrand.SAMSUNG), TvOpenProblem.openOnTv(TvBrand.LG))
        assertNull(TvOpenProblem.reason(null))
        TvOpenProblem.entries.forEach { assertNotNull(TvOpenProblem.reason(it)) }
    }

    @Test fun lgKeeperReportsEachConnectAttempt() {
        val results = mutableListOf<TvOpenProblem?>()
        val control = object : LgControl {
            override fun foregroundAppId() = "com.couchsubs.tv"
            override fun launch() {}
            override fun close() {}
        }
        val controls = ArrayDeque(listOf<LgControl?>(null, control))
        var steps = 0
        LgKeeper.keep(open = { controls.removeFirstOrNull() }, active = { steps++ < 3 }, consolePort = { null }, sleep = { },
            onOpenResult = { results += it })
        assertEquals(listOf(TvOpenProblem.UNREACHABLE, null), results)
    }

    /** "Otomatik açmayı dene" LG'de TV'de ne açık olursa olsun CouchSubs'ı öne getirir. */
    @Test fun lgKeeperLaunchesOnRetry() {
        var launches = 0
        val control = object : LgControl {
            override fun foregroundAppId() = "com.webos.app.home"
            override fun launch() { launches++ }
            override fun close() {}
        }
        var steps = 0
        val retries = ArrayDeque(listOf(false, true))
        LgKeeper.keep(open = { control }, active = { steps++ < 3 }, consolePort = { null }, sleep = { },
            retry = { retries.removeFirstOrNull() ?: false })
        assertEquals(1, launches)
    }

    /** Samsung: eskiden Android telefon uygulamayı yalnız bir kez açmayı deniyordu; bağlı değilken yeniden açılır. */
    @Test fun samsungIsReopenedWhileTheAppIsAway() {
        // Her turda iki bekleme: 15 sn (açıldı mı) ve 30 sn'ye kalan.
        var sleeps = 0
        var opens = 0
        var notOpened = 0
        TvSessionLauncher.keepSamsungOpen(InstalledTv(TvBrand.SAMSUNG, "192.168.1.50"), connected = { sleeps >= 4 }, active = { sleeps < 6 },
            sleep = { sleeps++; false }, notOpened = { notOpened++ }) { opens++ }
        assertEquals(1, opens)
        assertEquals(2, notOpened)
        TvSessionLauncher.keepSamsungOpen(InstalledTv(TvBrand.LG, "192.168.1.50"), connected = { false }, active = { true }) { opens++ }
        assertEquals(1, opens)
    }

    /** "Otomatik açmayı dene" beklemeyi keser: "açmadı" denetimi atlanır, hemen açılır. */
    @Test fun samsungRetryOpensWithoutWaiting() {
        var sleeps = 0
        var opens = 0
        var notOpened = 0
        TvSessionLauncher.keepSamsungOpen(InstalledTv(TvBrand.SAMSUNG, "192.168.1.50"), connected = { false }, active = { opens < 1 },
            sleep = { sleeps++; true }, notOpened = { notOpened++ }) { opens++ }
        assertEquals(1, opens)
        assertEquals(1, sleeps)
        assertEquals(0, notOpened)
        assertTrue(com.couchsubs.mobile.tv.samsung.SamsungInstaller.sdbLaunched("app_id[CouchSubsT.CouchSubs] launched"))
        assertFalse(com.couchsubs.mobile.tv.samsung.SamsungInstaller.sdbLaunched("app_id[CouchSubsT.CouchSubs] launch failed"))
        assertEquals(com.couchsubs.mobile.R.string.tv_open_not_opened, TvOpenProblem.reason(TvOpenProblem.NOT_OPENED))
    }
}
