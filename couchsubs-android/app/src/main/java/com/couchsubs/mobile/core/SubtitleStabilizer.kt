// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

enum class StabilizerKind { NONE, TRANSLATE, CLEAR, RESTORE }

/** Okuma hattının bir kareye vereceği tepki. */
data class StabilizerAction(val kind: StabilizerKind, val text: String? = null) {
    companion object {
        val None = StabilizerAction(StabilizerKind.NONE)
        val Clear = StabilizerAction(StabilizerKind.CLEAR)
        fun translate(text: String) = StabilizerAction(StabilizerKind.TRANSLATE, text)
        /** Az önce kalkan satır geri geldi; çevirisi yeniden gösterilir, yeniden çevrilmez (metin: ilk gönderilen hali). */
        fun restore(text: String) = StabilizerAction(StabilizerKind.RESTORE, text)
    }
}

/** Tekdüze milisaniye saati (duvar saati değişse de geri gitmez); testlerde sahtesi verilir. */
val monotonicClock: () -> Long = { System.nanoTime() / 1_000_000 }

/**
 * Kare kare gelen OCR çıktısını izler; altyazı kararlı hale gelince çevrilmesini, ekrandan kalkınca TV'den
 * temizlenmesini ister. Aynı altyazıyı tekrar göndermez. Kararlar okuma hızına değil saate bağlıdır.
 * Windows'taki SubtitleStabilizer.cs ile aynı kurallar.
 */
class SubtitleStabilizer(
    private val similarity: Double = 0.85,
    private val stableFrames: Int = 2,
    private val clearAfterMs: Int = CLEAR_AFTER_MS,
    clock: (() -> Long)? = null,
) {
    companion object {
        /** Bölge bu kadar boş kalırsa altyazı kalkmış sayılır; parlak arka planda kaçan birkaç okuma silmez. */
        const val CLEAR_AFTER_MS = 800
        /** Kalkan satır bu süre içinde geri gelirse aynı satırdır (okuma kaçmıştı); yeniden çevrilmez. */
        const val RESTORE_WITHIN_MS = 1500
        /** Çevirisi başarısız olan satır en erken bu kadar sonra yeniden denenir. */
        const val RETRY_AFTER_MS = 1000
        private const val HISTORY_SIZE = 5

        /** Satır nokta, ünlem, soru ya da üç noktayla bitiyor mu (kapanan tırnak ve parantezler yok sayılır). */
        fun endsSentence(raw: String): Boolean {
            val text = raw.trim().trimEnd('"', '\'', '”', '’', '»', ')', ']')
            return text.isNotEmpty() && text.last() in ".!?…"
        }
    }

    private data class Left(val rows: String, val raw: String, val leftAt: Long)

    private val now: () -> Long = clock ?: monotonicClock
    private var candidate = ""
    private var candidateCount = 0
    /** Ekrandaki (gönderilmiş) satır: sadeleştirilmiş satırlar alt alta, ve ilk okunduğu hali. */
    private var sent = ""
    private var sentRaw = ""
    private var emptySince: Long? = null
    private val history = mutableListOf<Left>()
    private var forgotten = ""
    private var retryAt = 0L

    fun feed(rawText: String): StabilizerAction {
        val time = now()
        val text = TextMatch.normalize(rawText)
        // 3 karakterden kısa okumalar (gürültü, tek simge) boş kare sayılır.
        if (text.length < 3) {
            candidate = ""
            candidateCount = 0
            val since = emptySince ?: time.also { emptySince = it }
            if (sent.isNotEmpty() && time - since >= clearAfterMs) {
                leaveScreen(time)
                return StabilizerAction.Clear
            }
            return StabilizerAction.None
        }

        emptySince = null
        if (TextMatch.isSimilar(text, candidate, similarity)) {
            candidateCount++
        } else {
            candidate = text
            candidateCount = 1
        }
        // Daktilo efektinde metin büyürken aday değişir; noktalamayla biten satır ilk karede gider.
        val ready = candidateCount >= stableFrames || endsSentence(rawText)
        // Gönderilenin gürültülü yeniden okuması yeni satır değildir.
        if (!ready || isSame(text, sent)) return StabilizerAction.None

        // Az önce kalkan satır geri geldiyse okuma birkaç kare kaçmıştır: çevirisi yeniden gösterilir.
        val index = history.indexOfLast { time - it.leftAt <= RESTORE_WITHIN_MS && isSame(text, it.rows) }
        if (index >= 0) {
            val back = history.removeAt(index)
            leaveScreen(time)
            sent = back.rows
            sentRaw = back.raw
            return StabilizerAction.restore(back.raw)
        }
        // Çevirisi az önce başarısız olan satır her karede yeniden istenmez.
        if (forgotten.isNotEmpty() && time < retryAt && isSame(text, forgotten)) return StabilizerAction.None

        leaveScreen(time)
        forgotten = ""
        sentRaw = rawText.trim()
        sent = TextMatch.normalizeRows(sentRaw)
        return StabilizerAction.translate(sentRaw)
    }

    private fun isSame(text: String, rows: String) = rows.isNotEmpty() && TextMatch.isSameSubtitle(text, rows)

    private fun leaveScreen(time: Long) {
        if (sent.isEmpty()) return
        history.add(Left(sent, sentRaw, time))
        if (history.size > HISTORY_SIZE) history.removeAt(0)
        sent = ""
        sentRaw = ""
    }

    /** Çeviri kaynağıyla neredeyse aynıysa metin zaten hedef dildedir (ör. konsolun Türkçe menüleri). */
    fun shouldSend(source: String, translation: String) =
        !TextMatch.isSimilar(TextMatch.normalize(source), TextMatch.normalize(translation), 0.90)

    /** Son gönderilen satırı unutur (çevirisi başarısız oldu); ekranda kaldıkça en erken [RETRY_AFTER_MS] sonra yeniden çevrilir. */
    fun forgetSent() {
        if (sent.isNotEmpty()) forgotten = sent
        retryAt = now() + RETRY_AFTER_MS
        sent = ""
        sentRaw = ""
        candidate = ""
        candidateCount = 0
    }

    fun reset(): StabilizerAction {
        candidate = ""
        candidateCount = 0
        emptySince = null
        history.clear()
        forgotten = ""
        if (sent.isEmpty()) return StabilizerAction.None
        sent = ""
        sentRaw = ""
        return StabilizerAction.Clear
    }
}
