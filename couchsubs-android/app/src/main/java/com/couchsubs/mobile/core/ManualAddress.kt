// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Locale

/**
 * Elle yazılan PS5 ya da TV adresi (Mac/iPhone: ManualAddress.swift, aynı kurallar). Kullanıcılar "192.168.1.5:3000",
 * "http://192.168.1.5", sonda boşluk ya da (Türkçe sayı klavyesinde nokta olmadığı için) "192,168,1,5" yazıyordu; böyle
 * bir adresle kurulan bağlantı başarısız oluyordu (#50). Adres burada temizlenir; temizlendikten sonra da adres olmayan
 * giriş reddedilir.
 */
object ManualAddress {
    /**
     * Baştaki/sondaki boşluk, "http://" gibi önek, ":3000" gibi port ve "/..." yolu atılır, virgüller noktaya döner.
     * IPv4 (dört 0–255 parça) ya da ağ adı (ör. "lgwebostv.local") kabul edilir; başka her şey null.
     */
    fun normalize(input: String): String? {
        var text = input.trim().replace(',', '.')
        text.indexOf("://").takeIf { it >= 0 }?.let { text = text.substring(it + 3) }
        text.indexOfFirst { it in "/?#" }.takeIf { it >= 0 }?.let { text = text.substring(0, it) }
        val parts = text.split(':')
        // Tek iki nokta port ayırır; daha fazlası IPv6'dır (TV'ler IPv4 adresiyle eşleşir).
        if (parts.size == 2) {
            if (parts[1].isEmpty() || !parts[1].all(::isAsciiDigit)) return null
            text = parts[0]
        } else if (parts.size > 2) {
            return null
        }
        if (text.endsWith('.')) text = text.dropLast(1)
        if (text.isEmpty()) return null
        if (text.all { isAsciiDigit(it) || it == '.' }) return ipv4(text)
        return if (isHostName(text)) text.lowercase(Locale.ROOT) else null
    }

    private fun ipv4(text: String): String? {
        val octets = text.split('.')
        if (octets.size != 4) return null
        val values = octets.map { octet ->
            if (octet.length !in 1..3) return null
            octet.toIntOrNull()?.takeIf { it in 0..255 } ?: return null
        }
        return values.joinToString(".")
    }

    /** Harf, rakam ve tireden oluşan, en az bir harf içeren etiketler (RFC 1123). */
    private fun isHostName(text: String): Boolean {
        if (text.length > 253 || text.none(::isAsciiLetter)) return false
        return text.split('.').all { label ->
            label.length in 1..63 && label.first() != '-' && label.last() != '-' &&
                label.all { isAsciiLetter(it) || isAsciiDigit(it) || it == '-' }
        }
    }

    private fun isAsciiDigit(c: Char) = c in '0'..'9'
    private fun isAsciiLetter(c: Char) = c in 'a'..'z' || c in 'A'..'Z'
}
