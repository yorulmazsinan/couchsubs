// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Elle girilen 12 karakterli base64 PSN hesap kimliğinin doğrulaması (Mac/Windows/iPhone/Linux ile aynı kural). */
class PsnAccountTest {
    @Test
    fun base64AccountIdAcceptsEightBytesAndTrimsWhitespace() {
        val id = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8)
        val encoded = PsnAccount.accountIdText(id)
        assertArrayEquals(id, PsnAccount.accountIdFromBase64(encoded))
        assertArrayEquals(id, PsnAccount.accountIdFromBase64("  $encoded \n"))
        assertArrayEquals(id, PsnAccount.accountIdFromBase64("AQID BAUG\tBwg="))
    }

    @Test
    fun base64AccountIdRoundTripsWithDecimalUserId() {
        val bytes = PsnAccount.accountIdBytes("258")!!
        val encoded = PsnAccount.accountIdText(bytes)
        assertArrayEquals(bytes, PsnAccount.accountIdFromBase64(encoded))
    }

    @Test
    fun invalidBase64AccountIdIsRejected() {
        val invalid = listOf(
            null,
            "",
            "   ",
            "AQIDBAUGBw==", // 7 bayt
            "AQIDBAUGBwgJ", // 9 bayt
            "AQIDBAUGBw!=",
            "1234567890",
            "AQIDBAUGBwg",  // 11 karakter
        )
        for (value in invalid) {
            assertNull("Geçersiz değer kabul edildi: $value", PsnAccount.accountIdFromBase64(value))
        }
    }
}
