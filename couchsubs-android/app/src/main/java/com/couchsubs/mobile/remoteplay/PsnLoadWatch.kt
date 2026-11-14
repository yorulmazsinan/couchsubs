// SPDX-License-Identifier: AGPL-3.0-only
// Sony giriş sayfasının açılıp açılmadığına karar verir. Sayaç ekran açıldığı anda başlar ve WebView'in olaylarına
// bağlı değildir: WebView hiç yüklemeye başlamasa, çerez silme hiç dönmese ya da Sony'nin sayfası kendi yükleme
// simgesinde takılsa da süre dolunca hata ekranı çıkar (kullanıcı sonsuz yükleme ekranında kalmaz).
package com.couchsubs.mobile.remoteplay

class PsnLoadWatch(private val startedAtMs: Long) {
    /** Ana sayfa en az bir kez onPageFinished verdi. */
    var pageFinished = false
        private set

    /** Sony'nin sayfasında kullanıcının dokunabileceği bir alan (e-posta kutusu, düğme) çizildi; sayaç durur. */
    var ready = false
        private set

    /** Yönlendirme yakalandı (giriş bitti); sayaç durur. */
    var redirected = false
        private set

    fun onPageFinished() {
        pageFinished = true
    }

    /** Sayfadaki giriş alanı ve düğme sayısı (evaluateJavascript sonucu). */
    fun onInteractiveCount(result: String?) {
        if ((result?.trim('"')?.toIntOrNull() ?: 0) > 0) ready = true
    }

    fun onRedirect() {
        redirected = true
    }

    /** [nowMs] anında giriş sayfası hâlâ kullanılamıyorsa nedeni; yoksa null. */
    fun problemAt(nowMs: Long): PsnPageProblem? = when {
        ready || redirected -> null
        nowMs - startedAtMs < LOAD_TIMEOUT_MS -> null
        // Sayfa geldi ama Sony'nin uygulaması çizilmedi (boş ya da kendi yükleme simgesinde takıldı).
        pageFinished -> PsnPageProblem.BLANK
        else -> PsnPageProblem.TIMEOUT
    }

    companion object {
        /** Ekran açıldıktan sonra Sony'nin giriş formu bu sürede çıkmazsa hata ekranı. */
        const val LOAD_TIMEOUT_MS = 20_000L

        /** Önceki oturumun çerezlerini silmek için en çok bu kadar beklenir; sonra sayfa yine açılır. */
        const val COOKIE_WAIT_MS = 2_000L

        /** Sayfa yüklendikten sonra giriş formunun çizilip çizilmediğine bu aralıkla bakılır. */
        const val READY_POLL_MS = 1_000L

        /** Sayfada kullanıcının dokunabileceği öğe sayısı. */
        const val INTERACTIVE_SCRIPT = "document.querySelectorAll('input:not([type=hidden]),button').length"
    }
}
