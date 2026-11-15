// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Çeviri motoru. Bloklayarak çevirir (hattın kendi iş parçacığında çağrılır); başarısızsa istisna atar. */
fun interface TextTranslator {
    fun translate(text: String): String

    /** Birbirinden bağımsız metinleri ("ekranı çevir"deki menü satırları, görev yazıları) aynı sırada çevirir. */
    fun translateAll(texts: List<String>): List<String> = texts.map(::translate)

    /** [translateAll] hepsini tek istekte çevirir (yapay zekâ); öyleyse ekran çevirisi parça parça istek göndermez. */
    val translatesTogether: Boolean get() = false
}

/**
 * Gösterilen bir çeviri: nereden geldiği ("paket" ya da "motor") ve paketse hangi oyunun paketi. Ölçümler (iPhone'daki
 * LineMetrics ile aynı): yazı tanımanın süresi, çevirinin süresi (paketse yok) ve karenin geldiği andan TV'ye gönderildiği
 * ana kadar geçen süre; bilinmeyen değer null.
 */
data class ShownPair(
    val source: String,
    val translation: String,
    val origin: String,
    val packId: String? = null,
    val ocrMs: Int? = null,
    val translationMs: Int? = null,
    val totalMs: Int? = null,
)

/**
 * Okunan satırlar → kararlılık → paket / çeviri → TV (Windows: SubtitlePipeline.cs, Mac/iPhone: SubtitlePipeline.swift,
 * aynı kurallar). Yazı tanıma çağıranda yapılır; çeviri ayrı bir iş parçacığında sırayla yürür: aynı anda yalnız bir
 * çeviri sürer, en çok [MAX_WAITING] satır sırada bekler; bekleyen satırın uzamış ya da düzelmiş okuması gelirse eskisi
 * sıradan çıkar.
 */
class SubtitlePipeline(
    private val translator: TextTranslator,
    private val sender: SubtitleSender,
    clock: (() -> Long)? = null,
    /** Testlerde çeviri aynı iş parçacığında yapılır. */
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs translate").apply { isDaemon = true } },
) {
    companion object {
        /**
         * Satır ekrandan bundan uzun süre önce kalktıysa geç gelen çevirisi gösterilmez (sonraki sahnenin üstüne düşmesin).
         * Yavaş çeviride (ücretsiz motor, zayıf işlemci) art arda gelen satırların çevirisi satır kalktıktan bir iki saniye
         * sonra gelir; sınır 1 sn iken üç satırlık konuşmanın yalnız ilki görünüyordu.
         */
        const val LATE_RESULT_MS = 2500
        /** Çeviri sürerken sırada en çok bu kadar satır bekler; daha eskisi atlanır (kuyruk konuşma hızıyla büyümesin). */
        const val MAX_WAITING = 2
        private const val REMEMBERED_PAIRS = 8

        /** Satır ekrandan kalktıktan sonra gelen çevirinin TV'de kalacağı süre (TV uygulamasıyla aynı kural). */
        fun readingTime(text: String) = minOf(8000, 2000 + text.length * 60)
    }

    private class Request(val number: Int, val source: String, val box: TextBox?, val session: Int,
                          val capturedAt: Long? = null, val ocrMs: Int? = null) {
        @Volatile var leftAt: Long? = null
        /** Yerine aynı cümlenin uzamış okuması geldi (daktilo efekti); çevirisi gösterilmez. */
        @Volatile var superseded = false
    }

    private data class Pair3(val number: Int, val source: String, val translation: String?)

    private val lock = Any()
    private val now: () -> Long = clock ?: monotonicClock
    private val stabilizer = SubtitleStabilizer(clock = now)
    private var lastRequested = 0
    private var lastShown = 0
    private var inFlight: Request? = null
    private val waiting = mutableListOf<Request>()
    /** Son gösterilen satırın kaynağı: yeni satır onun düzelmiş okumasıysa TV yerine koyar. */
    private var lastShownSource: String? = null
    private var lineOnScreen: Int? = null
    private val pairs = mutableListOf<Pair3>()
    private var session = 0
    /** İşlenen karenin geldiği an (hattın saatiyle) ve okumasının süresi; ölçüm satırı için. */
    private var frameAt: Long? = null
    private var frameOcrMs: Int? = null

    private fun totalMs(request: Request): Int? = request.capturedAt?.let { maxOf(0, (now() - it).toInt()) }

    /** Oyun paketi: kararlı satırın hazır Türkçesi (yoksa null). Motordan önce bakılır. */
    @Volatile var packLookup: ((String) -> PackMatch?)? = null
    /** Hiçbir pakette bulunmayan kararlı satır (ortak havuz için). */
    @Volatile var onPackMissed: ((String) -> Unit)? = null
    /** Yeni çeviri gösterilince. */
    @Volatile var onPairShown: ((ShownPair) -> Unit)? = null
    /** Her çeviri denemesinden sonra (başarılıysa null). */
    @Volatile var onTranslationResult: ((Throwable?) -> Unit)? = null

    var packHits = 0
        private set

    /**
     * Bir karenin okuması ve okunan alanın karedeki yeri. [signature]: bölgenin izi ([RegionSignature.of]); okuma boş
     * dönse de satırın yeri değişmediyse satır silinmez (parlak zemin).
     */
    fun process(raw: Reading, area: TextBox, signature: ByteArray? = null, capturedAt: Long? = null, ocrMs: Int? = null) {
        frameAt = capturedAt
        frameOcrMs = ocrMs
        // Kumanda ipuçları ve yazı tanıma çöpleri çevrilmez; yalnız altyazı bloğu çevrilir.
        val reading = raw.withoutButtonPrompts().withoutOcrNoise().subtitleBlock(area)
        val after: (() -> Unit)? = synchronized(lock) {
            val action = stabilizer.feed(reading.text, signature, reading.box)
            val box = reading.box?.placedIn(area)?.centeredOnScreen()
            when (action.kind) {
                StabilizerKind.CLEAR -> {
                    lineLeft()
                    sender.clear()
                    null
                }
                StabilizerKind.TRANSLATE -> {
                    lineLeft()
                    enqueue(action.text!!, box)
                }
                StabilizerKind.RESTORE -> {
                    lineLeft()
                    restore(action.text!!, box)
                }
                StabilizerKind.NONE -> null
            }
        }
        // Olaylar kilidin dışında çağrılır.
        after?.invoke()
    }

    private fun lineLeft() {
        val number = lineOnScreen ?: return
        val time = now()
        for (request in requests()) if (request.number == number && request.leftAt == null) request.leftAt = time
        lineOnScreen = null
    }

    private fun enqueue(source: String, box: TextBox?): (() -> Unit)? {
        val request = Request(++lastRequested, source, box, session, frameAt, frameOcrMs)
        lineOnScreen = request.number
        packLookup?.invoke(source)?.let { return showPacked(request, it) }
        val missed = onPackMissed
        val current = inFlight
        if (current == null) {
            inFlight = request
            executor.execute { pump(request) }
        } else {
            // Aynı cümlenin eski okuması sırada bekliyorsa çıkar; sıra dolduysa en eski bekleyen atlanır.
            waiting.removeAll { TextMatch.isRevision(source, it.source) }
            waiting.add(request)
            while (waiting.size > MAX_WAITING) waiting.removeAt(0)
            // Süren çeviri bu cümlenin yarım okumasınınsa (daktilo efekti) sonucu gösterilmez; tamamı sıradan çevrilir.
            if (!current.superseded && current.session == session && TextMatch.isGrowth(source, current.source)) current.superseded = true
        }
        return missed?.let { callback -> { callback(source) } }
    }

    /** Süren ve sırada bekleyen istekler. */
    private fun requests(): List<Request> = listOfNotNull(inFlight) + waiting

    /** Satır az önce gösterilenin uzamış ya da düzelmiş okuması mı (TV yerine koyar, üstüne yığmaz). */
    private fun revisesShown(source: String) = lastShownSource?.let { TextMatch.isRevision(source, it) } ?: false

    private fun showPacked(request: Request, packed: PackMatch): (() -> Unit)? {
        waiting.clear()
        packHits++
        val source = request.source
        val translated = packed.text
        val shouldSend = stabilizer.shouldSend(source, translated)
        remember(request.number, source, if (shouldSend) translated else null)
        if (!shouldSend) return null
        lastShown = request.number
        sender.sendSubtitle(translated, 15000, request.box, revisesShown(source))
        lastShownSource = source
        val shown = onPairShown
        val total = totalMs(request)
        return { shown?.invoke(ShownPair(source, translated, "paket", packed.packId, request.ocrMs, null, total)) }
    }

    private fun restore(source: String, box: TextBox?): (() -> Unit)? {
        val index = pairs.indexOfLast { it.source == source }
        if (index >= 0) {
            val pair = pairs[index]
            lineOnScreen = pair.number
            pair.translation?.let {
                sender.sendSubtitle(it, 15000, box, revisesShown(source))
                lastShownSource = source
            }
            return null
        }
        // Çevirisi henüz gelmediyse istek sürüyordur; satır yeniden ekranda sayılır.
        for (request in requests()) {
            if (request.source != source || request.session != session || request.superseded) continue
            request.leftAt = null
            lineOnScreen = request.number
            return null
        }
        return enqueue(source, box)
    }

    private fun pump(first: Request) {
        var request = first
        while (true) {
            try {
                translate(request)
            } catch (error: RuntimeException) {
                // Olay işleyicilerinden biri hata verse de sıra takılı kalmasın.
            }
            synchronized(lock) {
                // Ekrandan çoktan kalkmış satır çevrilmez; çevirisi zaten gösterilmeyecekti.
                val time = now()
                waiting.removeAll { it.session != session || it.leftAt.let { left -> left != null && time - left > LATE_RESULT_MS } }
                val next = if (waiting.isEmpty()) null else waiting.removeAt(0)
                inFlight = next
                if (next == null) return
                request = next
            }
        }
    }

    private fun translate(request: Request) {
        val source = request.source
        val started = now()
        val translated = try {
            translator.translate(source)
        } catch (error: Exception) {
            synchronized(lock) {
                // Yerine uzamış okuması gelen satırın bırakılan çevirisi hata sayılmaz.
                if (request.session != session || request.superseded) return
                // Model eksikse ya da geçici hata olduysa satır ekranda kaldıkça (saniyede en çok bir kez) yeniden denenir.
                if (request.number == lineOnScreen) stabilizer.forgetSent()
            }
            onTranslationResult?.invoke(error)
            return
        }
        onTranslationResult?.invoke(null)
        val translationMs = maxOf(0, (now() - started).toInt())
        var total: Int? = null
        synchronized(lock) {
            if (request.session != session) return
            val shouldSend = stabilizer.shouldSend(source, translated)
            remember(request.number, source, if (shouldSend) translated else null)
            if (request.number <= lastShown || !shouldSend || request.superseded) return
            val onScreen = request.number == lineOnScreen
            val left = request.leftAt
            // Satır ekrandan çoktan kalktıysa çevirisi sonraki sahnenin üstüne düşmesin.
            if (!onScreen && left != null && now() - left > LATE_RESULT_MS) return
            lastShown = request.number
            sender.sendSubtitle(translated, if (onScreen) 15000 else readingTime(translated), request.box, revisesShown(source))
            lastShownSource = source
            total = totalMs(request)
        }
        onPairShown?.invoke(ShownPair(source, translated, "motor", null, request.ocrMs, translationMs, total))
    }

    private fun remember(number: Int, source: String, translation: String?) {
        pairs.removeAll { it.source == source }
        pairs.add(Pair3(number, source, translation))
        if (pairs.size > REMEMBERED_PAIRS) pairs.removeAt(0)
    }

    /** Okuma durunca TV'deki son altyazıyı kaldırır. */
    fun reset() = synchronized(lock) {
        session++
        lineOnScreen = null
        waiting.clear()
        lastShownSource = null
        pairs.clear()
        if (stabilizer.reset() == StabilizerAction.Clear) sender.clear()
    }

    fun shutdown() {
        executor.shutdownNow()
    }
}
