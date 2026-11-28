// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Altyazı hattının kendi telefon takibinde ekran ışığıyla tutma ([PhoneGlow]; izleyiciyle aynı eşikler ve süre). #1443
 * (beta-108 Mac günlüğü): altyazı hattı telefonu karanlıkta ~1 sn'de bir bırakıyordu ("telefon kalktı" / "telefon
 * bulundu"), bırakınca telefonun mesajları altyazı sayılıp çevriliyordu (#5 "lot so if you're having any this is a", #6).
 * Telefon bulununca ekranın ışığı kaydedilir; ıskada son yerinde ışık tutuyorsa telefon bırakılmaz
 * ([SubtitlePipeline.heldPhone]). Mac/iPhone (PhoneGlow.swift) ve Windows (PhoneGlowKeeper.cs) aynı.
 */
class PhoneGlowKeeper {
    private var recorded: PhoneGlow.Glow? = null
    private var recordedAt: Long? = null
    private var seenAt = 0L
    private var holding = false

    /** Dönüş: telefon ışığıyla tutuluyor mu ve tutma bu aramada başladıysa ölçülen ışık (günlük için). */
    class Result(val holds: Boolean, val began: PhoneGlow.Glow?)

    /**
     * Bu aramanın sonucu: [found] bulunan telefon (yoksa null), [shown] süzgecin tuttuğu telefon; [measure] karede verilen
     * yerin ışığı.
     */
    @Synchronized
    fun observe(found: GamePhoneGeometry.Pose?, shown: GamePhoneGeometry.Pose?, now: Long,
                measure: (GamePhoneGeometry.Pose) -> PhoneGlow.Glow?): Result {
        if (found != null) {
            seenAt = now
            val at = recordedAt
            if (at == null || now < at || now - at >= GamePhoneTracker.PRINT_REFRESH_MS) {
                recorded = measure(found)?.takeIf { PhoneGlow.lit(it) }
                recordedAt = now
            }
            holding = false
            return Result(false, null)
        }
        if (shown == null) {
            reset()
            return Result(false, null)
        }
        val kept = recorded
        val current = if (kept != null && now >= seenAt && now - seenAt < PhoneGlow.HOLD_MS) measure(shown) else null
        if (kept == null || current == null || !PhoneGlow.holds(kept, current)) {
            holding = false
            return Result(false, null)
        }
        val began = if (holding) null else current
        holding = true
        return Result(true, began)
    }

    @Synchronized
    fun reset() {
        recorded = null
        recordedAt = null
        seenAt = 0L
        holding = false
    }
}
