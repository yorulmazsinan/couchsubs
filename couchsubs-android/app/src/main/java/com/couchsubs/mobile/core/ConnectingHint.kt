// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/** Oturumun bağlanırken son bildirdiği adım (Mac/iPhone RemotePlay `ConnectStep`, Windows ile aynı). */
enum class ConnectStep {
    /** PS5 aramaya yanıt vermedi; yine de bağlanılıyor. */
    NO_ANSWER,

    /** PS5 dinlenmedeydi; uyandırma gönderildi. */
    WAKING,

    /** PS5 yanıt verdi; oturum açılıyor. */
    OPENING,
}

/**
 * PS5 bağlantısı 30 sn'den uzun "Bağlanıyor…"da kalınca durum satırının altında nedeni söylenir: PS5 uyandırılıyor, PS5
 * aramaya yanıt vermiyor (açık mı, aynı ağda mı) ya da yanıt verdi ama oturum açılmıyor (core ConnectingHint.swift ve
 * Windows ConnectingHint.cs ile aynı kural; metinler strings.xml'de connecting_hint_*).
 */
object ConnectingHint {
    const val AFTER_MS = 30_000L

    /** [elapsedMs] süredir bağlanılıyorsa söylenecek neden; daha kısa sürdüyse null. Adım bilinmiyorsa "yanıt vermiyor". */
    fun reason(elapsedMs: Long, step: ConnectStep?): ConnectStep? =
        if (elapsedMs < AFTER_MS) null else step ?: ConnectStep.NO_ANSWER
}
