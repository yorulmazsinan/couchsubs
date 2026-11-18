// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TvAddressTest {
    @Test
    fun thePhonesOwnAddressIsRecognised() {
        assertTrue(TvAddress.isPhoneAddress("192.168.1.34", "192.168.1.34"))
        assertTrue(TvAddress.isPhoneAddress(" 192.168.1.34 ", "192.168.1.34"))
        // Kablosuz hata ayıklama: adres ve port.
        assertTrue(TvAddress.isPhoneAddress("192.168.1.34:41235", "192.168.1.34"))
    }

    @Test
    fun theTvsAddressOrAnUnknownPhoneIsFine() {
        assertFalse(TvAddress.isPhoneAddress("192.168.1.100", "192.168.1.34"))
        assertFalse(TvAddress.isPhoneAddress("192.168.1.34", null))
        assertFalse(TvAddress.isPhoneAddress("", "192.168.1.34"))
        assertFalse(TvAddress.isPhoneAddress("192.168.1.340", "192.168.1.34"))
    }
}
