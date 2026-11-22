// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core
import java.security.SecureRandom

/**
 * Kısa kod karşılaştırma içindir; anahtar yalnız ayrı 128 bit istek sırrıyla teslim edilir. Kurallar Mac/iPhone
 * (CouchSubsCore/SubtitlePairing.swift) ve Windows ile aynı; ortak deneme dosyası `subtitle-pairing.json`.
 */
class SubtitlePairing(private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {
    /**
     * [host]: isteği gönderen TV'nin adresi (bkz. [SubtitleAccess.tvHost]); bilinmiyorsa boş. Onaylanınca telefon bu TV'yi
     * kendi TV kaydına alır (marka adresten yoklanır; bkz. [com.couchsubs.mobile.tv.PairedTv]).
     */
    data class Ticket(val id: String, val code: String, val host: String = "")
    private var session = false
    private var manualUntil = 0L
    private var expires = 0L
    private var cooldown = 0L
    private var began = 0L
    private var ticket: Ticket? = null
    private var approved = false
    private var delivered = false
    /**
     * Telefonda reddedilen son istek: TV'ye `rejected` olarak söylenir. TV süresi dolan ya da düşen isteği kendisi yeniden
     * ister, reddedileni istemez (Tamam bekler); yoksa reddedilen TV için pencere art arda açılırdı (GitHub #737).
     */
    private var rejected: String? = null
    /** Çeviri sürüyor mu ([setSession]); `/hello`'daki `live` alanı. */
    val inSession: Boolean @Synchronized get() = session
    @Synchronized fun setSession(active: Boolean) { session = active; if (!active) clear() }
    @Synchronized fun open() { manualUntil = now() + 120000 }
    @Synchronized fun reset() { clear() }
    private fun clear() { ticket = null; approved = false; delivered = false; manualUntil = 0; cooldown = 0; rejected = null }
    /**
     * Süresi dolan isteğin bekleme süresi dolduğu andan sayılır. Eskiden ilk bakıldığı andan sayılıyordu: TV'de
     * "Eşleştirme tamamlanmadı" çıktıktan sonra Tamam'a basınca istek on saniye boyunca reddediliyordu (409).
     */
    private fun expire() { if (ticket != null && now() >= expires) { ticket = null; approved = false; delivered = false; cooldown = expires + 10000 } }
    /** Eşleştirme açık mı (çeviri sürüyor ya da "TV eşleştir"in iki dakikası dolmadı). */
    val isOpen: Boolean @Synchronized get() = session || now() < manualUntil
    /** Onay bekleyen istek (yoksa null). Arayüz kaçırdığı isteği buradan yeniden gösterir. */
    val pending: Ticket? @Synchronized get() { expire(); return if (approved) null else ticket }
    /**
     * TV'nin eşleştirme isteği. Onay bekleyen bir istek varken gelen yeni istek (TV uygulaması yeniden açıldı ya da
     * TV'de Tamam ile yeniden denendi) [SUPERSEDE_AFTER_MS]'den eskiyse eskisinin yerini alır: telefonda yeni kodla yeni
     * pencere açılır. Eskiden eski istek iki dakika dolana kadar her yeni isteği engelliyordu. Anahtarı teslim edilmiş
     * istek de yeni isteği engellemez.
     */
    @Synchronized fun begin(host: String = ""): Ticket? {
        expire()
        if ((!session && now() >= manualUntil) || now() < cooldown) return null
        if (ticket != null && !(if (approved) delivered else now() - began >= SUPERSEDE_AFTER_MS)) return null
        return Ticket(SubtitleAccess.createKey(), (100000 + SecureRandom().nextInt(900000)).toString(), host).also {
            ticket = it; began = now(); expires = began + 120000; approved = false; delivered = false
        }
    }
    @Synchronized fun resolve(id: String, accept: Boolean): Boolean {
        expire()
        if (ticket?.id != id || approved) return false
        if (accept) approved = true else { ticket = null; rejected = id; cooldown = now() + 10000 }
        return true
    }
    /**
     * İsteğin durumu: `pending`, `approved`, `rejected` (reddedildi) ya da `expired` (süresi doldu, yerini yenisi aldı,
     * çeviri durdu). Sunucu `rejected`'ı eski TV uygulamaları için `expired` olarak, yanında `rejected: true` ile gönderir.
     */
    @Synchronized fun poll(id: String): String {
        expire()
        if (ticket?.id != id) return if (id == rejected) "rejected" else "expired"
        if (approved) delivered = true
        return if (approved) "approved" else "pending"
    }

    companion object {
        /** Onay bekleyen istek bu kadar eskiyse yeni istek onun yerini alır (bkz. [begin]). */
        const val SUPERSEDE_AFTER_MS = 2000L
    }
}
