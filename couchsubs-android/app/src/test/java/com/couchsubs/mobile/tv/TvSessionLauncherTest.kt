// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv
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
    @Test fun registrationUsesPreviouslyApprovedTvCredential() {
        val payload = JSONObject(TvSessionLauncher.registerMessage("stored-tv-key")).getJSONObject("payload")
        assertEquals("stored-tv-key", payload.getString("client-key"))
        assertEquals("PROMPT", payload.getString("pairingType"))
        assertFalse(JSONObject(TvSessionLauncher.registerMessage(null)).getJSONObject("payload").has("client-key"))
    }
}
