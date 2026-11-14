// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Çeviri motoru. Bloklayarak çevirir (hattın kendi iş parçacığında çağrılır); başarısızsa istisna atar. */
fun interface TextTranslator {
    fun translate(text: String): String
}

/** Gösterilen bir çeviri: nereden geldiği ("paket" ya da "motor") ve paketse hangi oyunun paketi. */
data class ShownPair(val source: String, val translation: String, val origin: String, val packId: String? = null)

/**
 * Okunan satırlar → kararlılık → paket / çeviri → TV (Windows: SubtitlePipeline.cs, aynı kurallar). Yazı tanıma
 * çağıranda yapılır; çeviri ayrı bir iş parçacığında sırayla yürür: aynı anda yalnız bir çeviri sürer, bir tane de
 * sırada bekler (en yenisi), hızlı konuşmada araya giren satırlar atlanır.
 */
class SubtitlePipeline(
    private val translator: TextTranslator,
    private val sender: SubtitleSender,
    clock: (() -> Long)? = null,
    /** Testlerde çeviri aynı iş parçacığında yapılır. */
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs translate").apply { isDaemon = true } },
) {
    companion object {
        /** Satır ekrandan bundan uzun süre önce kalktıysa geç gelen çevirisi gösterilmez. */
        const val LATE_RESULT_MS = 1000
        private const val REMEMBERED_PAIRS = 8

        /** Satır ekrandan kalktıktan sonra gelen çevirinin TV'de kalacağı süre (TV uygulamasıyla aynı kural). */
        fun readingTime(text: String) = minOf(8000, 2000 + text.length * 60)
    }

    private class Request(val number: Int, val source: String, val box: TextBox?, val session: Int) {
        @Volatile var leftAt: Long? = null
    }

    private data class Pair3(val number: Int, val source: String, val translation: String?)

    private val lock = Any()
    private val now: () -> Long = clock ?: monotonicClock
    private val stabilizer = SubtitleStabilizer(clock = now)
    private var lastRequested = 0
    private var lastShown = 0
    private var inFlight: Request? = null
    private var pending: Request? = null
    private var lineOnScreen: Int? = null
    private val pairs = mutableListOf<Pair3>()
    private var session = 0

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

    /** Bir karenin okuması ve okunan alanın karedeki yeri. */
    fun process(raw: Reading, area: TextBox) {
        // Kumanda ipuçları ve yazı tanıma çöpleri çevrilmez; yalnız altyazı bloğu çevrilir.
        val reading = raw.withoutButtonPrompts().withoutOcrNoise().subtitleBlock(area)
        val after: (() -> Unit)? = synchronized(lock) {
            val action = stabilizer.feed(reading.text)
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
        for (request in listOf(inFlight, pending)) if (request != null && request.number == number && request.leftAt == null) request.leftAt = time
        lineOnScreen = null
    }

    private fun enqueue(source: String, box: TextBox?): (() -> Unit)? {
        val request = Request(++lastRequested, source, box, session)
        lineOnScreen = request.number
        packLookup?.invoke(source)?.let { return showPacked(request, it) }
        val missed = onPackMissed
        if (inFlight != null) {
            pending = request
        } else {
            inFlight = request
            executor.execute { pump(request) }
        }
        return missed?.let { callback -> { callback(source) } }
    }

    private fun showPacked(request: Request, packed: PackMatch): (() -> Unit)? {
        pending = null
        packHits++
        val source = request.source
        val translated = packed.text
        val shouldSend = stabilizer.shouldSend(source, translated)
        remember(request.number, source, if (shouldSend) translated else null)
        if (!shouldSend) return null
        lastShown = request.number
        sender.sendSubtitle(translated, 15000, request.box)
        val shown = onPairShown
        return { shown?.invoke(ShownPair(source, translated, "paket", packed.packId)) }
    }

    private fun restore(source: String, box: TextBox?): (() -> Unit)? {
        val index = pairs.indexOfLast { it.source == source }
        if (index >= 0) {
            val pair = pairs[index]
            lineOnScreen = pair.number
            pair.translation?.let { sender.sendSubtitle(it, 15000, box) }
            return null
        }
        // Çevirisi henüz gelmediyse istek sürüyordur; satır yeniden ekranda sayılır.
        for (request in listOf(inFlight, pending)) {
            if (request == null || request.source != source || request.session != session) continue
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
                var next = pending
                pending = null
                val left = next?.leftAt
                if (next != null && (next.session != session || (left != null && now() - left > LATE_RESULT_MS))) next = null
                inFlight = next
                if (next == null) return
                request = next
            }
        }
    }

    private fun translate(request: Request) {
        val source = request.source
        val translated = try {
            translator.translate(source)
        } catch (error: Exception) {
            synchronized(lock) {
                if (request.session != session) return
                // Model eksikse ya da geçici hata olduysa satır ekranda kaldıkça (saniyede en çok bir kez) yeniden denenir.
                if (request.number == lineOnScreen) stabilizer.forgetSent()
            }
            onTranslationResult?.invoke(error)
            return
        }
        onTranslationResult?.invoke(null)
        synchronized(lock) {
            if (request.session != session) return
            val shouldSend = stabilizer.shouldSend(source, translated)
            remember(request.number, source, if (shouldSend) translated else null)
            if (request.number <= lastShown || !shouldSend) return
            val onScreen = request.number == lineOnScreen
            val left = request.leftAt
            // Satır ekrandan çoktan kalktıysa çevirisi sonraki sahnenin üstüne düşmesin.
            if (!onScreen && left != null && now() - left > LATE_RESULT_MS) return
            lastShown = request.number
            sender.sendSubtitle(translated, if (onScreen) 15000 else readingTime(translated), request.box)
        }
        onPairShown?.invoke(ShownPair(source, translated, "motor"))
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
        pending = null
        pairs.clear()
        if (stabilizer.reset() == StabilizerAction.Clear) sender.clear()
    }

    fun shutdown() {
        executor.shutdownNow()
    }
}
