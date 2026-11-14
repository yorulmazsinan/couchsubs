// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.service

import com.couchsubs.mobile.core.ShownPair
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/** Okuma hattının arayüze gösterdiği durum (servis yazar, ekranlar okur). */
data class LiveStatus(
    val running: Boolean = false,
    /** Kısa durum metni: "PS5'e bağlanılıyor…", "Altyazılar okunuyor" gibi. */
    val phase: String = "",
    val connectedTvs: Int = 0,
    /** Son gösterilen çeviriler, yeniden eskiye. */
    val recent: List<ShownPair> = emptyList(),
    /** Telefon ekranında şu an gösterilen altyazı (yoksa boş). */
    val current: String = "",
    /** Son satırı veren oyun paketinin başlığı (ör. "GTA V"); paket kullanılmadıysa null. */
    val packInUse: String? = null,
    val error: String? = null,
    val framesReceived: Long = 0,
    /** Okumanın başladığı an (duvar saati, ms); süre göstergesi için. */
    val startedAt: Long = 0,
    /** Seçili çeviri motorunun görünen adı ("DeepL", "Ücretsiz"). */
    val engineLabel: String = "",
    /** Bu oturumda gösterilen satır ve paketten gelenler. */
    val shownLines: Int = 0,
    val packLines: Int = 0,
)

object LiveState {
    private const val RECENT = 20
    private val state = MutableStateFlow(LiveStatus())
    val status: StateFlow<LiveStatus> = state

    fun update(change: (LiveStatus) -> LiveStatus) = state.update(change)

    fun shown(pair: ShownPair, packTitle: String?) = state.update {
        // Paketten gelen son satırın oyunu, oturum boyunca "… paketi kullanılıyor" olarak kalır.
        it.copy(recent = (listOf(pair) + it.recent).take(RECENT), packInUse = packTitle ?: it.packInUse,
            shownLines = it.shownLines + 1, packLines = it.packLines + if (pair.origin == "paket") 1 else 0)
    }
}
