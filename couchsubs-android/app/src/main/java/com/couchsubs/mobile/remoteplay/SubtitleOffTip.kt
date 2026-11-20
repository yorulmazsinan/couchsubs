// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

/**
 * "Oyunun kendi altyazısını açın" ipucu ne zaman görünür (Mac/iPhone: CouchSubsCore SubtitleOffTip, Windows:
 * CouchSubs.Shell.SubtitleOffTip ile aynı kural).
 *
 * En sık şikâyet "çeviri gelmiyor, yalnız test yazısı çıkıyor" (GitHub #503, #554, #566, #572): görüntü geliyor ama oyunda
 * altyazı kapalı ya da altyazı alanında hiç satır yok. CouchSubs sesi değil, ekrandaki altyazıyı okur. Görüntü [AFTER_MS]
 * boyunca kesintisiz geldiği hâlde bu çeviride tek satır gösterilmediyse ipucu görünür; ilk satırda kalkar. Görüntü hiç
 * gelmiyorsa görünmez (o zaman sorun altyazı değil bağlantıdır ve ayrı söylenir).
 */
object SubtitleOffTip {
    const val AFTER_MS = 60_000L

    /** [streaming]: görüntü kaynağı bağlı. [sawLine]: bu çeviride satır gösterildi. [framesForMs]: görüntünün ne zamandır geldiği. */
    fun visible(streaming: Boolean, sawLine: Boolean, framesForMs: Long?): Boolean =
        streaming && !sawLine && framesForMs != null && framesForMs >= AFTER_MS

    /**
     * Görüntünün bu bağlantıda ilk geldiği an: bağlı değilken null; bağlıyken kare sayacı ilk değiştiğinde [now], sonra
     * korunur. [framesBefore]/[framesNow]: iki ölçümdeki toplam kare sayısı (yeniden bağlanınca yeni oturumun sayacı
     * sıfırdan başlar; azalması da kare geldiği anlamına gelir).
     */
    fun framesSince(previous: Long?, streaming: Boolean, framesBefore: Long, framesNow: Long, now: Long): Long? = when {
        !streaming -> null
        previous != null -> previous
        framesNow != framesBefore -> now
        else -> null
    }
}
