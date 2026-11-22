// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/**
 * "Ekranı çevir"in telefon kartı sohbeti izler. Önceden kart tek bir karenin çevirisiydi: telefonda başka bir sohbete
 * geçince kart eski sohbette kalıyor, süresi dolunca kayboluyordu; yeni sohbet ancak düğmeye yeniden basınca geliyordu.
 * Kart ekrandayken uygulama telefonu düzenli aralıkla ([INTERVAL_MS]) yoklar: telefonun ekranı değişip bir yoklama boyunca
 * durulunca (sohbet değişti, yeni mesaj geldi, sohbet kaydı) ekran yeniden çevrilir; değişmeyen telefonda kart ekranda
 * kalır; telefon art arda [MISS_TURNS] yoklamada bulunamazsa (kapandı) kart kalkar. Yeniden çeviri [PhoneChatMemory] ile
 * hızlıdır: daha önce görülen sohbetin mesajları çevirmene gitmez (Mac/iPhone: ScreenPhoneFollow.swift, Windows:
 * ScreenPhoneFollow.cs; ortak deneme dosyası fixtures/phone-chat.json `follow` bölümü).
 */
class ScreenPhoneFollow(
    /** Çeviriler balonların üstünde, yerinde (kartsız): ekran değişir değişmez [Step.HIDE]. */
    val hidesOnChange: Boolean = false,
) {
    /** Yoklamanın kararı; [wire] Mac ve Windows'taki adı (ortak deneme dosyası). */
    enum class Step(val wire: String) {
        /** Bir şey yapma (telefon kıpırdıyor). */
        WAIT("wait"),
        /** Telefonun ekranı değişti ve duruldu: ekranı yeniden çevir. */
        REFRESH("refresh"),
        /** Telefon aynı: kart ekranda kalsın (süresi uzatılır). */
        KEEP("keep"),
        /** Telefon kapandı: kartı kaldır, izlemeyi bırak. */
        STOP("stop"),
        /**
         * Telefonun ekranı değişti (sohbet kaydı ya da değişti), henüz durulmadı: yerindeki mesaj çevirileri hemen kalksın
         * (artık başka balonların üstündeler); durulunca [REFRESH] gelir. Yalnız [hidesOnChange] açıkken.
         */
        HIDE("hide"),
    }

    private class Look(val box: TextBox, val signature: ByteArray)

    private var baseline: Look? = null
    private var pending: Look? = null
    private var misses = 0

    /** Ekran bu telefon görüntüsüyle çevrildi (kartın dayandığı hâl). */
    @Synchronized
    fun settled(box: TextBox, signature: ByteArray) {
        baseline = Look(box, signature)
        pending = null
        misses = 0
    }

    /** Bir yoklama: telefonun yeri ve ekranının izi (telefon yoksa null). */
    @Synchronized
    fun step(box: TextBox?, signature: ByteArray?): Step {
        if (box == null || signature == null) {
            misses++
            pending = null
            return if (misses >= MISS_TURNS) Step.STOP else Step.WAIT
        }
        misses = 0
        val look = Look(box, signature)
        val base = baseline ?: run {
            baseline = look
            return Step.KEEP
        }
        if (!differs(base, look)) {
            pending = null
            return Step.KEEP
        }
        val last = pending
        if (last != null && !differs(last, look)) {
            pending = null
            return Step.REFRESH
        }
        val first = pending == null
        pending = look
        return if (hidesOnChange && first) Step.HIDE else Step.WAIT
    }

    companion object {
        /** Yoklama aralığı (ms). */
        const val INTERVAL_MS = 700L
        /** Telefon bu kadar yoklama art arda bulunamazsa kapanmış sayılır. */
        const val MISS_TURNS = 3
        /** Telefon bu kadar yer değiştirirse (kenarlara oranla) kart yeniden dizilir. */
        const val MOVE_TOLERANCE = 0.02
        /**
         * Telefonun ekranı bu paydan fazla değişirse (iz örneklerinin) değişmiş sayılır. Elde sallanan telefonun kenar
         * kıpırtısı birkaç örnektir; sohbet değişince ya da yeni mesajla kayınca ekranın çoğu değişir.
         */
        const val CHANGE_SHARE = 0.08
        /** Bir iz örneği bundan fazla değişirse değişmiş sayılır (sıkıştırma kıpırtısı sayılmaz). */
        const val SAMPLE_CHANGE = 24

        private fun differs(a: Look, b: Look): Boolean =
            abs(a.box.left - b.box.left) > MOVE_TOLERANCE || abs(a.box.right - b.box.right) > MOVE_TOLERANCE ||
                abs(a.box.top - b.box.top) > MOVE_TOLERANCE || abs(a.box.bottom - b.box.bottom) > MOVE_TOLERANCE ||
                changedShare(a.signature, b.signature) > CHANGE_SHARE

        /** İki izin değişen örneklerinin payı (boyları farklıysa tümü). */
        internal fun changedShare(a: ByteArray, b: ByteArray): Double {
            if (a.size != b.size || a.isEmpty()) return 1.0
            var changed = 0
            for (i in a.indices) if (abs((a[i].toInt() and 0xff) - (b[i].toInt() and 0xff)) > SAMPLE_CHANGE) changed++
            return changed.toDouble() / a.size
        }

        /** Karedeki telefonun yeri ve ekranının izi; telefon yoksa null. */
        fun look(image: PhoneImage): Pair<TextBox, ByteArray>? {
            val phone = ScreenPhoneCard.phone(image) ?: return null
            val box = phone.bounds
            return Pair(box, image.signature(CropRegion(box.top, box.bottom, box.left, box.right)))
        }
    }
}

/**
 * Telefon sohbetlerinin çevirileri, sohbetin başlığıyla (kişi adı) birlikte saklanır: başka bir sohbete geçip geri
 * dönünce mesajlar yeniden çevrilmez, kart hemen dolar. Çevirmen ya da hedef dil değişince uygulama yenisini kurar.
 */
class PhoneChatMemory {
    private val saved = HashMap<String, String>()
    private val order = ArrayDeque<String>()

    private fun key(chat: String, source: String) = chat + "\u001F" + source

    @Synchronized
    fun translation(chat: String, source: String): String? = saved[key(chat, source)]

    @Synchronized
    fun remember(chat: String, source: String, translation: String) {
        if (translation.isBlank()) return
        val key = key(chat, source)
        if (!saved.containsKey(key)) {
            if (order.size >= CAPACITY) saved.remove(order.removeFirst())
            order.addLast(key)
        }
        saved[key] = translation
    }

    val count: Int @Synchronized get() = saved.size

    companion object {
        /** En çok bu kadar mesaj saklanır; dolunca en eskisi düşer. */
        const val CAPACITY = 600
    }
}
