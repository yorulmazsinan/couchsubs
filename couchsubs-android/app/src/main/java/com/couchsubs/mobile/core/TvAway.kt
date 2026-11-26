// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * #1303: telefon uygulaması arka plandayken TV ile bağlantı koptu mu; koptuysa kullanıcıya "CouchSubs'ı açık tutun" denir
 * (arka plandayken bildirim, dönüşte ana ekranda not). Kullanıcı "altyazı bir süre TV'ye geliyor, sonra yalnız telefonda
 * kalıyor" diyordu; neden hiç söylenmiyordu.
 *
 * Askıya alınan uygulamada kopma dönüşte görülür (TV bağlı değil ya da dönüşten hemen sonra kopuyor): dönüşten sonraki
 * kısa süre ([grace]) de "arka plandayken koptu" sayılır. Uyarı bir arka plan gezisinde bir kez verilir. Mac/iPhone
 * çekirdeğindeki TVAway ile aynı kural. Zamanlar saniye.
 */
class TvAway(val grace: Double = DEFAULT_GRACE) {
    companion object {
        /** Dönüşten sonra bu kadar saniye içinde gelen kopma, arka planda kopmuş sayılır. */
        const val DEFAULT_GRACE = 5.0
    }

    /** Uygulama şu an arka planda mı. */
    var away = false
        private set
    /** Arka plana geçerken TV bağlı mıydı. */
    private var linkedWhenLeft = false
    private var returnedAt: Double? = null
    /** Bu gezide uyarı verildi. */
    private var warned = false

    /** Uygulama arka plana geçti; [linked]: TV uygulaması o anda bağlı mı. */
    @Synchronized fun left(linked: Boolean) {
        away = true
        linkedWhenLeft = linked
        returnedAt = null
        warned = false
    }

    /** Uygulama öne döndü. TV giderken bağlıydı ve şimdi bağlı değilse true: uyarı gösterilir. */
    @Synchronized fun returned(now: Double, linked: Boolean): Boolean {
        val wasAway = away
        away = false
        returnedAt = now
        if (!wasAway || !linkedWhenLeft || linked) return false
        return warn()
    }

    /** Bağlı TV uygulamasının bağlantısı koptu. Uygulama arka plandaysa ya da az önce döndüyse (TV giderken bağlıydı) true. */
    @Synchronized fun lost(now: Double): Boolean {
        if (away) return warn()
        val back = returnedAt ?: return false
        if (!linkedWhenLeft || now - back > grace) return false
        return warn()
    }

    /** Çeviri durdu ya da başladı: geçmiş unutulur. */
    @Synchronized fun reset() {
        away = false
        linkedWhenLeft = false
        returnedAt = null
        warned = false
    }

    private fun warn(): Boolean {
        if (warned) return false
        warned = true
        return true
    }
}
