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
    @Test fun registrationUsesPreviouslyApprovedTvCredential() {
        val payload = JSONObject(TvSessionLauncher.registerMessage("stored-tv-key")).getJSONObject("payload")
        assertEquals("stored-tv-key", payload.getString("client-key"))
        assertEquals("PROMPT", payload.getString("pairingType"))
        assertFalse(JSONObject(TvSessionLauncher.registerMessage(null)).getJSONObject("payload").has("client-key"))
    }
}
