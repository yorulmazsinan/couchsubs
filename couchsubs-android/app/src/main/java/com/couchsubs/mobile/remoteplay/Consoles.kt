// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import java.net.Inet4Address
import java.net.NetworkInterface

/** Ağda bulunan PS5. */
data class ConsoleInfo(val host: String, val name: String, val isAwake: Boolean)

/** PS5'e kaydedilmiş bu telefonun bağlantı bilgileri (Windows: RegisteredConsole). Şifreli saklanır. */
class RegisteredConsole(val host: String, val name: String, val registKey: ByteArray, val morning: ByteArray) {
    /** Uyandırma için kayıt anahtarının onaltılık değeri. */
    val wakeCredential: Long?
        get() {
            val end = registKey.indexOf(0).let { if (it < 0) registKey.size else it }
            val text = String(registKey, 0, end, Charsets.US_ASCII)
            return try {
                java.lang.Long.parseUnsignedLong(text, 16)
            } catch (error: NumberFormatException) {
                null
            }
        }

    fun withHost(newHost: String) = RegisteredConsole(newHost, name, registKey, morning)
}

/** Kaydın kullanıcıya anlatılan sonucu (Windows: RegistrationFailure). */
enum class RegistrationFailure { WRONG_ACCOUNT, WRONG_CODE, IN_USE, VERSION_MISMATCH, CONSOLE_CRASHED, BAD_ADDRESS, NO_ANSWER, NO_REPLY, FAILED }

class RegistrationException(val failure: RegistrationFailure, val reason: Int? = null, val detail: String? = null) :
    Exception("PS5 registration failed: $failure ${detail ?: ""}")

object Registration {
    private const val INVALID_PSN_ID = 0x80108b02.toInt()
    private const val REGIST_FAILED = 0x80108b09.toInt()
    private const val IN_USE = 0x80108b10.toInt()
    private const val VERSION = 0x80108b11.toInt()
    private const val CRASH = 0x80108b15.toInt()
    private const val SEARCH_ATTEMPTS = 3
    private const val REASON_PREFIX = "Reported Application Reason: "

    /** PS5'in gösterdiği 8 haneli kod; boşluk, tire, nokta atlanır. Başka karakter ya da 8'den farklı hane: null. */
    fun parsePin(text: String?): Int? {
        if (text == null) return null
        val digits = StringBuilder(8)
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            index += Character.charCount(codePoint)
            if (Character.isWhitespace(codePoint) || codePoint.toChar() in "-–._") continue
            if (Character.getType(codePoint) != Character.DECIMAL_DIGIT_NUMBER.toInt()) return null
            digits.append(Character.digit(codePoint, 10))
        }
        return if (digits.length == 8) digits.toString().toLong().toInt() else null
    }

    /** PS5'in bildirdiği nedenden ya da libchiaki'nin hata satırlarından kullanıcıya anlatılacak hata. */
    fun failureFrom(reason: Int?, errors: List<String>): RegistrationFailure {
        fun any(vararg needles: String) = errors.any { line -> needles.any { line.contains(it) } }
        return when {
            reason == INVALID_PSN_ID -> RegistrationFailure.WRONG_ACCOUNT
            reason == REGIST_FAILED -> RegistrationFailure.WRONG_CODE
            reason == IN_USE -> RegistrationFailure.IN_USE
            reason == VERSION -> RegistrationFailure.VERSION_MISMATCH
            reason == CRASH -> RegistrationFailure.CONSOLE_CRASHED
            reason != null -> RegistrationFailure.FAILED
            any("getaddrinfo") -> RegistrationFailure.BAD_ADDRESS
            any("search response", "connect for search", "send search", "Regist search failed", "connect for request", "Regist connect failed") ->
                RegistrationFailure.NO_ANSWER
            any("response HTTP header", "receiving response content", "receive response content") -> RegistrationFailure.NO_REPLY
            else -> RegistrationFailure.FAILED
        }
    }

    fun detailFrom(errors: List<String>): String? {
        errors.firstOrNull { it.contains(REASON_PREFIX) }?.let { return it.substringAfter(REASON_PREFIX) }
        return errors.firstOrNull()
    }

    /** PS5'in "Cihazı Bağla" ekranındaki kodla kayıt olur (bloklar, en çok ~30 sn × deneme). */
    fun register(host: String, accountId: ByteArray, pin: Int): RegisteredConsole {
        require(accountId.size == 8) { "PSN account id must be 8 bytes" }
        if (!NativeBridge.available) throw RegistrationException(RegistrationFailure.FAILED, detail = "native library missing")
        var attempt = 1
        while (true) {
            val outcome = NativeOutcome()
            NativeBridge.register(host, accountId, pin, outcome)
            if (outcome.code == 0) {
                return RegisteredConsole(host, outcome.nickname ?: "PS5", outcome.registKey!!, outcome.morning!!)
            }
            val lines = outcome.errorLines
            val reported = if (outcome.code == 1 && outcome.reason != 0) outcome.reason else null
            val failure = when (outcome.code) {
                1 -> failureFrom(reported, lines)
                2 -> RegistrationFailure.NO_REPLY
                else -> RegistrationFailure.FAILED
            }
            // Kod PS5'e gitmeden biten arama aşamasında paket kaybı olabilir; yeniden denemek güvenlidir.
            if (failure != RegistrationFailure.NO_ANSWER || attempt >= SEARCH_ATTEMPTS)
                throw RegistrationException(failure, reported, detailFrom(lines))
            attempt++
            Thread.sleep(500)
        }
    }
}

/** PS5'i ağda arar ve uyandırır (libchiaki'nin arama protokolü). */
object ConsoleDiscovery {
    /** [host] verilirse yalnız ona, yoksa telefonun bulunduğu /24 ağın bütün adreslerine sorar (bloklar). */
    fun discover(host: String?, timeoutMs: Int = 2000): List<ConsoleInfo> {
        if (!NativeBridge.available) return emptyList()
        val targets = if (host != null) listOf(host) else subnetAddresses()
        if (targets.isEmpty()) return emptyList()
        return NativeBridge.discover(targets.toTypedArray(), timeoutMs)?.mapNotNull { line ->
            val parts = line.split('\t')
            if (parts.size < 3) null else ConsoleInfo(parts[0], parts[1], parts[2] == "1")
        } ?: emptyList()
    }

    fun wake(console: RegisteredConsole) {
        val credential = console.wakeCredential ?: throw IllegalStateException("Registration key is not a wake credential")
        NativeBridge.wake(console.host, credential)
    }

    /** Birden çok PS5 varsa yalnız adı tutan seçilir (modem adresini değiştirmiş olabilir). */
    fun pickMoved(found: List<ConsoleInfo>, name: String): ConsoleInfo? {
        val same = found.filter { it.name == name }
        return when {
            same.size == 1 -> same[0]
            found.size == 1 -> found[0]
            else -> null
        }
    }

    /** Telefonun Wi-Fi ya da Ethernet adresinin /24 ağındaki diğer adresler. */
    fun subnetAddresses(): List<String> {
        val local = localIPv4() ?: return emptyList()
        val prefix = local.substringBeforeLast('.')
        return (1..254).map { "$prefix.$it" }.filter { it != local }
    }

    /** Özel ağdaki (192.168/10/172.16-31) ilk IPv4 adresi; hücresel ve VPN arayüzleri atlanır. */
    fun localIPv4(): String? = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && !it.name.startsWith("rmnet") && !it.name.startsWith("tun") }
            .sortedBy { if (it.name.startsWith("wlan")) 0 else 1 }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .map { it.hostAddress ?: "" }
            .firstOrNull { isPrivate(it) }
    } catch (error: Exception) {
        null
    }

    fun isPrivate(address: String): Boolean {
        val parts = address.split('.').mapNotNull { it.toIntOrNull() }
        if (parts.size != 4) return false
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && parts[1] in 16..31)
    }
}
