// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core
import java.security.SecureRandom

/** Kısa kod karşılaştırma içindir; anahtar yalnız ayrı 128 bit istek sırrıyla teslim edilir. */
class SubtitlePairing(private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {
    data class Ticket(val id: String, val code: String)
    private var session = false
    private var manualUntil = 0L
    private var expires = 0L
    private var cooldown = 0L
    private var ticket: Ticket? = null
    private var approved = false
    @Synchronized fun setSession(active: Boolean) { session = active; if (!active) clear() }
    @Synchronized fun open() { manualUntil = now() + 120000 }
    @Synchronized fun reset() { clear() }
    private fun clear() { ticket = null; approved = false; manualUntil = 0; cooldown = 0 }
    private fun expire() { if (ticket != null && now() >= expires) { ticket = null; approved = false; cooldown = now() + 10000 } }
    @Synchronized fun begin(): Ticket? {
        expire()
        if ((!session && now() >= manualUntil) || ticket != null || now() < cooldown) return null
        return Ticket(SubtitleAccess.createKey(), (100000 + SecureRandom().nextInt(900000)).toString()).also {
            ticket = it; expires = now() + 120000; approved = false
        }
    }
    @Synchronized fun resolve(id: String, accept: Boolean): Boolean {
        expire()
        if (ticket?.id != id || approved) return false
        if (accept) approved = true else { ticket = null; cooldown = now() + 10000 }
        return true
    }
    @Synchronized fun poll(id: String): String {
        expire()
        return if (ticket?.id == id) { if (approved) "approved" else "pending" } else "expired"
    }
}
