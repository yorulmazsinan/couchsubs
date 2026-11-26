// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Altyazı hattının göndericisi: ekranda menü varken ([ScreenTextDetector.menu]) altyazı satırları hemen gönderilmez,
 * bekletilir; temizleme geçer. Menü kapanınca ([poll]) bekletilen satır sessizce düşmez (#1240): menü [SHORT_MENU_MS]'den
 * kısa sürdüyse bekletilen bütün satırlar, yoksa son [HOLD_MS] içinde gelen en son konuşma satırı ([SilenceWatch.isSpeech];
 * menü etiketi değil) gönderilir. Eskiden menü sırasında altyazı hiç okunmuyordu: GTA 6'nın karanlık balık tutma
 * sahnesinde tuş ipucu ve görev yazısı birlikte belirip menü sanılınca her seferinde bir iki konuşma satırı kayboluyordu.
 * Geçişler ve bekletilen/gönderilen satırlar günlüğe yazılır ([DropLog]). Windows (MenuPausedSender.cs) ve Mac/iPhone
 * (MenuHeldSender.swift) aynı kurallar.
 */
class MenuHeldSender(
    private val inner: SubtitleSender,
    private val inMenu: () -> Boolean,
    private val log: ((String) -> Unit)? = null,
    private val clock: () -> Long = monotonicClock,
) : SubtitleSender {
    companion object {
        /** Menü kapanınca bundan eski bekletilen satır gönderilmez (ekrandan çoktan kalkmıştır). */
        const val HOLD_MS = 5000L
        /** Bundan kısa süren menü durumu yanlış algıdır: bekletilen bütün satırlar hemen gönderilir. */
        const val SHORT_MENU_MS = 300L

        /** Menü durumu değişince günlüğe yazılan satır (Mac/iPhone ve Windows ile aynı metin). */
        fun menuLog(inMenu: Boolean): String =
            if (inMenu) "ekran menüsü açık: altyazı bekletiliyor" else "ekran menüsü kapandı: altyazı gösteriliyor"
    }

    private class Held(val text: String, val durationMs: Int, val box: TextBox?, val replaces: Boolean, val at: Long)

    private val lock = Any()
    private val drops = DropLog(clock, log)
    private val held = mutableListOf<Held>()
    private var paused = false
    private var pausedAt = 0L

    /**
     * Menü durumunu yeniden okur; menü kapandıysa bekletilen satırları gönderir. Hizmet her karede çağırır (menü
     * kapandıktan sonra yeni satır gelmese de bekletilen satır gitsin). Şu an menü var mı döner.
     */
    fun poll(): Boolean {
        val (menu, release) = synchronized(lock) { observe() }
        release.forEach { inner.sendSubtitle(it.text, it.durationMs, it.box, it.replaces) }
        return menu
    }

    override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {
        val (menu, release) = synchronized(lock) {
            val result = observe()
            if (result.first) {
                held += Held(text, durationMs, box, replaces, clock())
                drops.note("Menü", "menü sırasında bekletildi", text)
            }
            result
        }
        release.forEach { inner.sendSubtitle(it.text, it.durationMs, it.box, it.replaces) }
        if (!menu) inner.sendSubtitle(text, durationMs, box, replaces)
    }

    override fun clear() = inner.clear()

    /** Görev satırının yeri menüde de bekletilmez. */
    override fun sendObjective(box: TextBox?) = inner.sendObjective(box)

    /**
     * Altyazı alanında menünün geçmiş listesi okundu ([SubtitlePipeline.onList]): menü sırasında bekletilen satırlar
     * listenin satırlarıdır (kaydırırken tek satır okunabiliyor), menü kapanınca altyazı olarak gönderilmez.
     */
    fun forget(): Unit = synchronized(lock) {
        for (line in held) drops.note("Menü", "menü listesinin satırı, gönderilmedi", line.text)
        held.clear()
    }

    private fun observe(): Pair<Boolean, List<Held>> {
        val menu = inMenu()
        if (menu == paused) return menu to emptyList()
        paused = menu
        val time = clock()
        if (menu) {
            pausedAt = time
            log?.invoke(menuLog(true))
            return true to emptyList()
        }
        val lasted = time - pausedAt
        val release = if (lasted < SHORT_MENU_MS) held.toList()
        else listOfNotNull(held.lastOrNull { time - it.at <= HOLD_MS && SilenceWatch.isSpeech(it.text) })
        for (line in held) {
            drops.note("Menü", if (line in release) "menü kapanınca gönderildi" else "menü sırasında bekletildi, gönderilmedi", line.text)
        }
        held.clear()
        log?.invoke("${menuLog(false)} ($lasted ms)")
        return false to release
    }
}
