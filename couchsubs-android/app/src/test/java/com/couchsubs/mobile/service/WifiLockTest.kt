// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.service

import org.junit.Assert.assertEquals
import org.junit.Test

class WifiLockTest {
    // android.net.wifi.WifiManager sabitleri (JVM testinde sayıyla).
    private val highPerf = 3
    private val lowLatency = 4

    @Test
    fun screenOffKeepsAWifiLockOnAndroid10AndLater() {
        // Yalnız düşük gecikme kilidi ekran kapanınca etkisiz kalıyordu (telefon kilitlenince çeviri duruyordu).
        assertEquals(listOf(highPerf, lowLatency), wifiLockModes(29))
        assertEquals(listOf(highPerf, lowLatency), wifiLockModes(36))
    }

    @Test
    fun olderAndroidUsesHighPerf() {
        assertEquals(listOf(highPerf), wifiLockModes(26))
    }
}
