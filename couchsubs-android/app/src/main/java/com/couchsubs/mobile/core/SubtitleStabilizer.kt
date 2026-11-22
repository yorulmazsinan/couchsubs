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

        /**
         * Okuma, adlı gönderilen satırın ("JASON: Gidelim.") adı okunamamış hali mi ("Gidelim."). Ad sonradan okunan
         * satırın tersi (bkz. SubtitlePipeline.nameRead): ad bir görünüp bir kaybolunca cümle yeniden çevrilip TV'de
         * adsız ve adlı iki kez görünmesin (Mac: isUnnamedReread, Windows: IsUnnamedReread).
         */
        fun isUnnamedReread(raw: String, sentRaw: String): Boolean {
            if (sentRaw.isEmpty() || SpeakerPrefix.split(raw) != null) return false
            val named = SpeakerPrefix.split(sentRaw) ?: return false
            val rows = TextMatch.normalizeRows(named.body)
            return rows.isNotEmpty() && TextMatch.isSameSubtitle(TextMatch.normalize(raw), rows)
        }
        /**
         * Okuma boş döndüğü halde satırın yeri, satır son okunduğundan beri değişmediyse (bölge izi,
         * [RegionSignature.changed]) yazı hâlâ oradadır, yazı tanıma kaçırmıştır: parlak zeminde beyaz yazı saniyelerce
         * okunamıyor, TV'deki Türkçe İngilizce dururken siliniyordu (It Takes Two, 2026-11-13). Satırın yeri değişince
         * her zamanki [CLEAR_AFTER_MS] sayılır. Değişmeyen yerde de satır en çok bu kadar tutulur (Mac/iPhone ile aynı).
         */
        const val HOLD_UNCHANGED_MS = 4000
        /** Kalkan satır bu süre içinde geri gelirse aynı satırdır (okuma kaçmıştı); yeniden çevrilmez. */
        const val RESTORE_WITHIN_MS = 1500
        /** Çevirisi başarısız olan satır en erken bu kadar sonra yeniden denenir. */
        const val RETRY_AFTER_MS = 1000
        /**
         * Çöp gibi okunan satır ([OcrNoise.looksGarbled]) ancak bu kadar süre aynı okununca gider. Altyazılar geçişte üst
         * üste solarken yazı tanıma iki satırı karıştırıp birkaç kare aynı çöpü okuyabiliyordu ("- Nat) but, you knpw.
         * shit, I m", GTA V, #26); süslü ama gerçekten öyle duran yazı yine çevrilir.
         */
        const val GARBLED_STABLE_MS = 700
        private const val HISTORY_SIZE = 5

        /** Satır nokta, ünlem, soru ya da üç noktayla bitiyor mu (kapanan tırnak ve parantezler yok sayılır). */
        fun endsSentence(raw: String): Boolean {
            val text = raw.trim().trimEnd('"', '\'', '”', '’', '»', ')', ']')
            return text.isNotEmpty() && text.last() in ".!?…"
        }

        /**
         * Okumanın gönderilenden farklı her sözcüğü onun onarılmış hali mi: gönderilendeki sözcük ya sözcük değil
         * ([OcrNoise.isNonWord]: "ijz") ya da yenisinin baştan/sondan kesilmiş parçası ("eedboat" → "speedboat").
         */
        fun repairsWords(words: List<String>, old: List<String>): Boolean {
            var changed = false
            for ((next, previous) in words.zip(old)) {
                if (next == previous) continue
                changed = true
                val fragment = next.length > previous.length && (next.endsWith(previous) || next.startsWith(previous))
                if (!fragment && !(OcrNoise.isNonWord(previous) && !OcrNoise.isNonWord(next))) return false
            }
            return changed
        }
    }

    private data class Left(val rows: String, val raw: String, val leftAt: Long)

    private val now: () -> Long = clock ?: monotonicClock
    private var candidate = ""
    private var candidateCount = 0
    private var candidateSince = 0L
    /** Ekrandaki (gönderilmiş) satır: sadeleştirilmiş satırlar alt alta, ve ilk okunduğu hali. */
    private var sent = ""
    private var sentRaw = ""
    /** Retry/withdraw state can clear while the previous subtitle still needs an output clear. */
    private var clearPending = false
    private var emptySince: Long? = null
    /** Boş okunan bölgede satırın yerinin değiştiği (ya da yeri bilinmediği için kalkmış sayıldığı) an. */
    private var goneSince: Long? = null
    /** Ekrandaki satırın son okunduğu karenin bölge izi ve satırın bölgedeki yeri. */
    private var lastSeen: Pair<ByteArray, TextBox>? = null
    private val history = mutableListOf<Left>()
    private var forgotten = ""
    private var retryAt = 0L
    /** Gönderilen satırın kaç kez aynı okunduğu ve gönderilenden farklı okunan, art arda gelen aynı okuma (düzeltme adayı). */
    private var sentReads = 0
    private data class Correction(val text: String, val raw: String, val count: Int)
    private var correction: Correction? = null

    /**
     * [signature]: karenin bölge izi ([RegionSignature.of]); verilmezse boş okuma hep kalkma sayılır.
     * [box]: okunan yazının bölgedeki yeri (bölgenin kenarlarına oranla).
     */
    fun feed(rawText: String, signature: ByteArray? = null, box: TextBox? = null): StabilizerAction {
        val time = now()
        val text = TextMatch.normalize(rawText)
        // 3 karakterden kısa okumalar (gürültü, tek simge) boş kare sayılır.
        if (text.length < 3) {
            candidate = ""
            candidateCount = 0
            val since = emptySince ?: time.also { emptySince = it }
            if (sent.isEmpty() && !clearPending) return StabilizerAction.None
            // Satırın yeri son okunduğu kareden beri değişmediyse yazı tanıma kaçırmıştır; kalkma sayılmaz.
            if (goneSince == null && !looksUnchanged(signature)) goneSince = time
            val gone = goneSince?.let { time - it >= clearAfterMs } ?: false
            if (gone || time - since >= HOLD_UNCHANGED_MS) {
                leaveScreen(time)
                return StabilizerAction.Clear
            }
            return StabilizerAction.None
        }

        emptySince = null
        goneSince = null
        if (TextMatch.isSimilar(text, candidate, similarity)) {
            candidateCount++
        } else {
            candidate = text
            candidateCount = 1
            candidateSince = time
        }
        // Daktilo efektinde metin büyürken aday değişir; noktalamayla biten satır ilk karede gider. Çöp gibi okunan satır
        // (altyazılar geçişte üst üste solarken karışan okuma) beklemeden gitmez; geçiş süresinden uzun kararlıysa gider.
        val ready = if (OcrNoise.looksGarbled(rawText)) candidateCount >= stableFrames && time - candidateSince >= GARBLED_STABLE_MS
            else candidateCount >= stableFrames || endsSentence(rawText)
        // Gönderilenin gürültülü yeniden okuması yeni satır değildir. Adlı gönderilen satırın ("JASON: …") renkli adı bir
        // karede okunamadıysa adsız okuması da aynı satırdır.
        if (isSame(text, sent) || isUnnamedReread(rawText, sentRaw)) {
            remember(signature, box)
            return corrected(text, rawText)?.let { StabilizerAction.translate(it) } ?: StabilizerAction.None
        }
        if (!ready) return StabilizerAction.None
        // Aynı cümlenin bir iki sözcüğü başka okunmuş, daha iyi olmayan okuması da yeni satır değildir; çevrilseydi TV'de
        // aynı cümlenin iki üç çevirisi üst üste dururdu. Daha çok sözcük okuyan okuma yeniden çevrilir (TV yerine koyar).
        if (sentRaw.isNotEmpty() && TextMatch.isWorseReread(rawText, sentRaw)) {
            remember(signature, box)
            return StabilizerAction.None
        }

        // Az önce kalkan satır geri geldiyse okuma birkaç kare kaçmıştır: çevirisi yeniden gösterilir.
        val index = history.indexOfLast { time - it.leftAt <= RESTORE_WITHIN_MS && isSame(text, it.rows) }
        if (index >= 0) {
            val back = history.removeAt(index)
            leaveScreen(time)
            sent = back.rows
            sentRaw = back.raw
            remember(signature, box)
            return StabilizerAction.restore(back.raw)
        }
        // Çevirisi az önce başarısız olan satır her karede yeniden istenmez.
        if (forgotten.isNotEmpty() && time < retryAt && isSame(text, forgotten)) return StabilizerAction.None

        leaveScreen(time)
        forgotten = ""
        sentRaw = rawText.trim()
        sent = TextMatch.normalizeRows(sentRaw)
        sentReads = 1
        correction = null
        remember(signature, box)
        return StabilizerAction.translate(sentRaw)
    }

    /**
     * Gönderilen satır ilk karesinde bir sözcüğü bozuk okunmuş olabilir: yazı belirirken (ya da renkli sözcük açık zeminde)
     * "lives" "Ijz", "speedboat" "eedboat" okunuyor, satır noktalamayla bittiği için ilk karede gidiyordu. Sonraki
     * okumalar aynı satır sayıldığından ([isSame]) doğrusu hiç çevrilmiyor, TV'de bozuk sözcüklü çeviri kalıyordu (GitHub
     * #854, GTA 6). Gönderilenle aynı sayıda sözcüklü, ondan farklı bir okuma art arda en az [stableFrames] kez okunur,
     * puanı da ([OcrNoise.score]: daha çok düzgün harf) yüksekse ve ya gönderilenden daha çok kez okunduysa ya da farklı
     * sözcükleri gönderilenin onarılmış hali ise ([repairsWords]) düzeltmedir: yeniden çevrilir (hat onu gösterilenin
     * yerine koyar). Düzeltilen satır bir daha düzeltilmez. Mac/iPhone (SubtitleStabilizer.swift) ve Windows
     * (SubtitleStabilizer.cs) aynı kuralı uygular.
     */
    private fun corrected(text: String, rawText: String): String? {
        if (sentReads <= 0) return null
        val shown = TextMatch.normalize(sentRaw)
        if (text == shown) {
            sentReads++
            return null
        }
        val raw = rawText.trim()
        val current = correction
        val candidate = if (current != null && current.text == text) Correction(text, raw, current.count + 1) else Correction(text, raw, 1)
        correction = candidate
        val words = text.split(' ').filter { it.isNotEmpty() }
        val old = shown.split(' ').filter { it.isNotEmpty() }
        if (candidate.count < stableFrames || words.size != old.size || OcrNoise.score(candidate.raw) <= OcrNoise.score(sentRaw) ||
            !(candidate.count > sentReads || repairsWords(words, old))) return null
        sentRaw = candidate.raw
        sent = TextMatch.normalizeRows(sentRaw)
        // Düzeltme kesindir: aynı satır bir daha düzeltilmez (iki okuma arasında gidip gelmesin).
        sentReads = 0
        correction = null
        return sentRaw
    }

    /** Ekrandaki satır bu karede okundu: bölgenin izi ve satırın yeri saklanır (yer bilinmiyorsa hiçbiri). */
    private fun remember(signature: ByteArray?, box: TextBox?) {
        lastSeen = if (signature != null && box != null) signature to box else null
    }

    /** Bu karede satırın yeri, satırın son okunduğu karedekiyle aynı mı (izi ve yeri bilinmiyorsa hayır). */
    private fun looksUnchanged(signature: ByteArray?): Boolean {
        val seen = lastSeen ?: return false
        if (signature == null) return false
        return !RegionSignature.changed(seen.first, signature, RegionSignature.CHANGE_THRESHOLD, seen.second)
    }

    private fun isSame(text: String, rows: String) = rows.isNotEmpty() && TextMatch.isSameSubtitle(text, rows)

    private fun leaveScreen(time: Long) {
        if (sent.isNotEmpty()) {
            history.add(Left(sent, sentRaw, time))
            if (history.size > HISTORY_SIZE) history.removeAt(0)
            sent = ""
            sentRaw = ""
        }
        sentReads = 0
        correction = null
        lastSeen = null
        clearPending = false
    }

    /** Çeviri kaynağıyla neredeyse aynıysa metin zaten hedef dildedir (ör. konsolun Türkçe menüleri). */
    fun shouldSend(source: String, translation: String) =
        !TextMatch.isSimilar(TextMatch.normalize(source), TextMatch.normalize(translation), 0.90)

    /**
     * Az önce çevrilmek üzere verilen satırı hat yok saydı (bekleyen satırın arasına giren bozuk okuma): satır gönderilmemiş
     * sayılır, ekranda kaldıkça sonraki okumada yeniden verilir. Yoksa gerçek bir yeni satır "gönderildi" sayılıp hiç
     * çevrilmiyordu (Windows: WithdrawSent, Mac/iPhone: withdrawSent).
     */
    fun withdrawSent() {
        if (sent.isNotEmpty()) clearPending = true
        sent = ""
        sentRaw = ""
        if (!clearPending) lastSeen = null
    }

    /** Son gönderilen satırı unutur (çevirisi başarısız oldu); ekranda kaldıkça en erken [RETRY_AFTER_MS] sonra yeniden çevrilir. */
    fun forgetSent() {
        if (sent.isNotEmpty()) {
            forgotten = sent
            clearPending = true
        }
        retryAt = now() + RETRY_AFTER_MS
        sent = ""
        sentRaw = ""
        if (!clearPending) lastSeen = null
        candidate = ""
        candidateCount = 0
    }

    fun reset(): StabilizerAction {
        candidate = ""
        candidateCount = 0
        emptySince = null
        goneSince = null
        lastSeen = null
        history.clear()
        forgotten = ""
        val shouldClear = sent.isNotEmpty() || clearPending
        sent = ""
        sentRaw = ""
        sentReads = 0
        correction = null
        clearPending = false
        return if (shouldClear) StabilizerAction.Clear else StabilizerAction.None
    }
}
