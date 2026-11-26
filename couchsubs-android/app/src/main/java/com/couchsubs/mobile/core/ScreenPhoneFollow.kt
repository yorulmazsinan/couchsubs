// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * "Ekranı çevir"in telefon kartı sohbeti izler. Önceden kart tek bir karenin çevirisiydi: telefonda başka bir sohbete
 * geçince kart eski sohbette kalıyor, süresi dolunca kayboluyordu; yeni sohbet ancak düğmeye yeniden basınca geliyordu.
 * Kart ekrandayken uygulama telefonu düzenli aralıkla ([INTERVAL_MS]) yoklar: telefonun ekranı değişip bir yoklama boyunca
 * durulunca (sohbet değişti, yeni mesaj geldi, sohbet kaydı) ekran yeniden çevrilir; değişmeyen telefonda kart ekranda
 * kalır; telefon art arda [MISS_TURNS] yoklamada bulunamazsa (kapandı) kart kalkar. Yeniden çeviri [PhoneChatMemory] ile
 * hızlıdır: daha önce görülen sohbetin mesajları çevirmene gitmez (Mac/iPhone: ScreenPhoneFollow.swift, Windows:
 * ScreenPhoneFollow.cs; ortak deneme dosyası fixtures/phone-chat.json `follow` bölümü).
 *
 * Elde sallanan telefon (#1253, #1326): GTA 6'nın telefonu elde durur, her karede birkaç piksel kayar. Önceden kutunun
 * kenarı %2 oynayınca ya da iz örneklerinin %8'i değişince ekran "değişti" sayılıyor, yerindeki çeviriler ilk yoklamada
 * kalkıyordu ([Step.HIDE]); yeniden çeviri için iki yoklamanın aynı çıkması gerekiyordu, sallanan telefon bunu nadiren
 * veriyordu: "Ekranı çevir"in çevirisi 1–2 sn'de kayboluyordu. Artık iz telefonun kendi koordinatında, hücre ortalamasıyla
 * alınır ([look]), iki iz yatayda [MAX_SHIFT] hücreye dek kaydırılarak karşılaştırılır, kenar payı [MOVE_TOLERANCE];
 * çeviriler ancak art arda [HIDE_TURNS] yoklama değişirse kalkar.
 */
class ScreenPhoneFollow(
    /** Çeviriler balonların üstünde, yerinde (kartsız): ekran durulmadan değişmeye devam ederse [Step.HIDE]. */
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
         * Telefonun ekranı art arda [HIDE_TURNS] yoklama değişti, henüz durulmadı: yerindeki mesaj çevirileri kalksın
         * (artık başka balonların üstündeler); durulunca [REFRESH] gelir. Yalnız [hidesOnChange] açıkken.
         */
        HIDE("hide"),
    }

    private class Look(val box: TextBox, val signature: ByteArray)

    private var baseline: Look? = null
    private var pending: Look? = null
    private var misses = 0
    /** Baştaki hâlinden art arda değişen yoklama sayısı. */
    private var changes = 0
    /** Altyazı günlüğü: çevirinin neden gizlendiği, yeniden çevrildiği ya da kalktığı (sınırlı; testlerde yazılmaz). */
    private val drops = DropLog()

    /** Ekran bu telefon görüntüsüyle çevrildi (kartın dayandığı hâl). */
    @Synchronized
    fun settled(box: TextBox, signature: ByteArray) {
        baseline = Look(box, signature)
        pending = null
        misses = 0
        changes = 0
    }

    /** Bir yoklama: telefonun yeri ve ekranının izi (telefon yoksa null). */
    @Synchronized
    fun step(box: TextBox?, signature: ByteArray?): Step {
        if (box == null || signature == null) {
            misses++
            pending = null
            changes = 0
            if (misses >= MISS_TURNS) note("telefon $misses yoklamadır yok, çeviri kalktı")
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
            changes = 0
            return Step.KEEP
        }
        changes++
        val last = pending
        if (last != null && !differs(last, look)) {
            pending = null
            changes = 0
            note("telefon ekranı değişti ve duruldu, yeniden çevriliyor (${describe(base, look)})")
            return Step.REFRESH
        }
        pending = look
        if (!hidesOnChange || changes != HIDE_TURNS) return Step.WAIT
        note("telefon ekranı $changes yoklamadır değişiyor, yerindeki çeviriler gizlendi (${describe(base, look)})")
        return Step.HIDE
    }

    private fun note(reason: String) = drops.note("ScreenPhoneFollow", reason, "")

    companion object {
        /** Yoklama aralığı (ms). */
        const val INTERVAL_MS = 700L
        /** Telefon bu kadar yoklama art arda bulunamazsa kapanmış sayılır. */
        const val MISS_TURNS = 3
        /**
         * Telefon bu kadar yer değiştirirse (kenarlara oranla) kart yeniden dizilir. Önceden 0,02'ydi: elde sallanan
         * telefonun bulunan kutusu bundan çok oynuyordu.
         */
        const val MOVE_TOLERANCE = 0.04
        /**
         * Yerindeki çeviriler ancak telefonun ekranı art arda bu kadar yoklama (baştaki hâlinden) değişirse kalkar; tek
         * yoklamalık değişim (sallanma, geçiş karesi) kaldırmaz. Değişip duruldıysa zaten [Step.REFRESH] gelir.
         */
        const val HIDE_TURNS = 2
        /**
         * Telefonun ekranı bu paydan fazla değişirse (iz örneklerinin) değişmiş sayılır. Elde sallanan telefonun kıpırtısı
         * (hücre ortalaması ve kaydırmalı karşılaştırmadan sonra) birkaç örnektir; sohbet değişince ya da yeni mesajla
         * kayınca ekranın çoğu değişir. Önceden 0,08'di.
         */
        const val CHANGE_SHARE = 0.12
        /**
         * Bir iz örneği bundan fazla değişirse değişmiş sayılır (sıkıştırma kıpırtısı ve kelime kenarının hücre içinde
         * kayması sayılmaz; balon zemini ile yazı arasındaki fark bundan çok büyüktür). Önceden 24'tü.
         */
        const val SAMPLE_CHANGE = 32
        /**
         * İki iz yatayda en çok bu kadar hücre kaydırılarak karşılaştırılır (telefonun bulunan kutusu elde birkaç piksel
         * kayar; bir hücre telefon eninin 1/64'ü). Dikeyde kaydırılmaz: yeni mesajla sohbetin kayması değişim sayılmalı.
         */
        const val MAX_SHIFT = 2
        /**
         * İzin her hücresi, hücrenin bu kadar sütun × satır alt örneğinin ortalamasıdır (birkaç piksellik kayma hücrenin
         * değerini az oynatır; önceden hücrenin tek ortadaki pikseliydi, yazı satırına denk gelip gelmemesi değişiyordu).
         */
        const val SUB_COLUMNS = 4
        const val SUB_ROWS = 8

        private fun differs(a: Look, b: Look): Boolean =
            shift(a.box, b.box) > MOVE_TOLERANCE || changedShare(a.signature, b.signature) > CHANGE_SHARE

        /** İki kutunun en çok oynayan kenarı (kareye oranla). */
        internal fun shift(a: TextBox, b: TextBox): Double =
            max(max(abs(a.left - b.left), abs(a.right - b.right)), max(abs(a.top - b.top), abs(a.bottom - b.bottom)))

        /** Günlük için: izin değişen payı ve kutunun oynaması (yüzde). */
        private fun describe(a: Look, b: Look): String =
            "%${PhoneTrace.percent(changedShare(a.signature, b.signature))} değişim, %${PhoneTrace.percent(shift(a.box, b.box))} oynama"

        /**
         * İki izin değişen örneklerinin payı: yatayda [MAX_SHIFT] hücreye dek kaydırmaların en küçüğü, örtüşen sütunlarda
         * (boyları farklıysa tümü).
         */
        internal fun changedShare(a: ByteArray, b: ByteArray): Double {
            if (a.size != b.size || a.isEmpty()) return 1.0
            val width = RegionSignature.WIDTH
            fun sample(bytes: ByteArray, index: Int) = bytes[index].toInt() and 0xff
            if (a.size % width != 0) {
                var changed = 0
                for (i in a.indices) if (abs(sample(a, i) - sample(b, i)) > SAMPLE_CHANGE) changed++
                return changed.toDouble() / a.size
            }
            val rows = a.size / width
            var best = 1.0
            for (dx in -MAX_SHIFT..MAX_SHIFT) {
                var changed = 0
                var total = 0
                for (y in 0 until rows) {
                    for (x in max(0, -dx) until min(width, width - dx)) {
                        total++
                        if (abs(sample(a, y * width + x) - sample(b, y * width + x + dx)) > SAMPLE_CHANGE) changed++
                    }
                }
                if (total > 0) best = min(best, changed.toDouble() / total)
            }
            return best
        }

        /**
         * Karedeki telefonun yeri ve ekranının izi; telefon yoksa null. İz telefonun kutusundan (telefonun koordinatında)
         * alınır, her hücresi alt örneklerin ortalamasıdır ([signature]).
         */
        fun look(image: PhoneImage): Pair<TextBox, ByteArray>? {
            val phone = ScreenPhoneCard.phone(image) ?: return null
            val box = phone.bounds
            return Pair(box, signature(image, CropRegion(box.top, box.bottom, box.left, box.right)))
        }

        /**
         * [region]'ın [RegionSignature.WIDTH] × [RegionSignature.HEIGHT] gri izi; her hücre [SUB_COLUMNS] × [SUB_ROWS] alt
         * örneğin (alt hücrenin ortasındaki piksel) ortalaması (Mac/iPhone ve Windows aynı hesap).
         */
        internal fun signature(image: PhoneImage, region: CropRegion): ByteArray {
            val width = RegionSignature.WIDTH
            val height = RegionSignature.HEIGHT
            if (image.width <= 0 || image.height <= 0) return ByteArray(width * height)
            val fineWidth = width * SUB_COLUMNS
            val fineHeight = height * SUB_ROWS
            val left = region.left * image.width
            val top = region.top * image.height
            val w = (region.right - region.left) * image.width
            val h = (region.bottom - region.top) * image.height
            val fine = ByteArray(fineWidth * fineHeight)
            for (y in 0 until fineHeight) {
                val sy = (top + (y + 0.5) * h / fineHeight).toInt().coerceIn(0, image.height - 1)
                for (x in 0 until fineWidth) {
                    val sx = (left + (x + 0.5) * w / fineWidth).toInt().coerceIn(0, image.width - 1)
                    fine[y * fineWidth + x] = (image.tone(sx, sy) shr 8).toByte()
                }
            }
            return average(fine, width, height)
        }

        /** İnce örnekleri (genişlik·[SUB_COLUMNS] × yükseklik·[SUB_ROWS]) hücre ortalamasına indirir. */
        internal fun average(fine: ByteArray, width: Int, height: Int): ByteArray {
            val stride = width * SUB_COLUMNS
            val out = ByteArray(width * height)
            for (y in 0 until height) {
                for (x in 0 until width) {
                    var sum = 0
                    for (j in 0 until SUB_ROWS) {
                        val row = (y * SUB_ROWS + j) * stride + x * SUB_COLUMNS
                        for (i in 0 until SUB_COLUMNS) sum += fine[row + i].toInt() and 0xff
                    }
                    out[y * width + x] = (sum / (SUB_COLUMNS * SUB_ROWS)).toByte()
                }
            }
            return out
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
