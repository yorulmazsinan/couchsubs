// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv

/**
 * TV'nin adresi yazılan alanlar için: kullanıcı TV'nin kutusuna bu telefonun adresini yazdıysa (Samsung'da Host PC IP
 * olarak yazılacak olan) kurulum başlamaz, uyarılır (#343). Kablosuz hata ayıklamadaki port (`:41235`) atılır.
 */
object TvAddress {
    fun isPhoneAddress(address: String, phoneIp: String?): Boolean {
        if (phoneIp.isNullOrBlank()) return false
        val host = address.trim().substringBefore(':')
        return host.isNotEmpty() && host == phoneIp.trim()
    }
}
