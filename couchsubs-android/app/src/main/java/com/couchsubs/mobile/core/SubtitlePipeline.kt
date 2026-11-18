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

    /**
     * Hat satır başındaki konuşan adını ("PRICE: …") ayırıp çevirmene yalnız cümleyi verir; ad buradan öğrenilir ve
     * sonraki cümlelerin içinde geçince çeviriden korunur (#287).
     */
    fun noteSpeaker(name: String) {}
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
        /**
         * Bozuk okunan (OCR izi taşıyan) ve pakette bulunmayan satır en çok bu kadar bekletilir: aynı satırın düzgün
         * okuması gelirse o çevrilir (Windows: PackWaitMs).
         */
        const val PACK_WAIT_MS = 800
        /**
         * Temiz ama yarım olabilecek satırın (küçük harfle başlıyor ya da cümle sonu işareti yok) bekleme süresi. Telefon
         * yarım okumayı ("Get Franklin close to the") hemen çevirmene gönderiyordu; çeviri bilgisayardakinden kötü
         * görünüyordu (Windows: CleanWaitMs).
         */
        const val CLEAN_WAIT_MS = 300
        /** Çevrilen satırın daha iyi olmayan yeniden okuması bu süre içinde yeni satır sayılmaz. */
        const val REREAD_WITHIN_MS = 4000

        /** Satır ekrandan kalktıktan sonra gelen çevirinin TV'de kalacağı süre (TV uygulamasıyla aynı kural). */
        fun readingTime(text: String) = minOf(8000, 2000 + text.length * 60)
    }

    private class Request(val number: Int, val source: String, val box: TextBox?, val session: Int,
                          val capturedAt: Long? = null, val ocrMs: Int? = null) {
        /** Baştaki konuşan adı ("ARTHUR: …"); çeviriye yalnız cümle gider. */
        val prefix = SpeakerPrefix.split(source)
        @Volatile var leftAt: Long? = null
        /** Yerine aynı cümlenin uzamış okuması geldi (daktilo efekti); çevirisi gösterilmez. */
        @Volatile var superseded = false
        /**
         * Mevcut gösterim kurallarına göre elendi (daha yeni satır gösterildi ya da süresi doldu); iptali dinlemeyen
         * motorun sonucu da gösterilmez.
         */
        @Volatile var abandoned = false
    }

    private data class Pair3(val number: Int, val source: String, val translation: String?)

    /** Bekletilen okuma: kaynak, yer, bekletilmeye başlandığı an, en çok bekleme, puanı, ilk okunduğu kare. */
    private data class Held(val source: String, val box: TextBox?, val since: Long, val wait: Int, val score: Int,
                            val capturedAt: Long?, val ocrMs: Int?)

    /** Son çevrilen (motora ya da pakete giden) okuma, puanı ve zamanı. */
    private data class Sent(val source: String, val score: Int, val at: Long)

    private val lock = Any()
    private val now: () -> Long = clock ?: monotonicClock
    private val stabilizer = SubtitleStabilizer(clock = now)
    /** Konuşma değişirken sabit duran görev/HUD satırları (GTA 6). */
    private val stickyRows = StickyRows()
    private var lastRequested = 0
    private var lastShown = 0
    private var inFlight: Request? = null
    /** Çevirmenin şu an çalıştığı istek ve onu çalıştıran iş parçacığı (iptal için kesilir); çeviri sürmüyorsa null. */
    private var translating: Request? = null
    private var worker: Thread? = null
    private val waiting = mutableListOf<Request>()
    /** Son gösterilen satırın kaynağı: yeni satır onun düzelmiş okumasıysa TV yerine koyar. */
    private var lastShownSource: String? = null
    private var lineOnScreen: Int? = null
    private val pairs = mutableListOf<Pair3>()
    private var session = 0
    /** İşlenen karenin geldiği an (hattın saatiyle) ve okumasının süresi; ölçüm satırı için. */
    private var frameAt: Long? = null
    private var frameOcrMs: Int? = null
    private var held: Held? = null
    private var lastSent: Sent? = null
    private var lastClearAt = Long.MIN_VALUE

    /**
     * Yarım ya da bozuk okuma kısa süre bekletilip aynı satırın en iyi okuması mı çevrilsin (Windows'ta yazım denetimiyle
     * açık). Telefon uygulaması açar; kapalıyken her kararlı okuma hemen çevrilir.
     */
    @Volatile var holdReadings = false
    /** Bozuk okumanın bekleme süresi (0: beklenmez); testler değiştirir. */
    @Volatile var packWait = PACK_WAIT_MS
    /** Yarım olabilecek temiz okumanın bekleme süresi (0: beklenmez); testler değiştirir. */
    @Volatile var cleanWait = CLEAN_WAIT_MS

    private fun totalMs(request: Request): Int? = request.capturedAt?.let { maxOf(0, (now() - it).toInt()) }

    /** Oyun paketi: kararlı satırın hazır Türkçesi (yoksa null). Motordan önce bakılır. */
    @Volatile var packLookup: ((String) -> PackMatch?)? = null
    /** Konuşan adı ("ARTHUR: …") TV'ye giden çeviride gösterilir; kapalıysa yalnız cümle gider (her satırda sorulur). */
    @Volatile var showSpeakerNames: () -> Boolean = { true }
    /** Hedef dil Türkçe: yüksek güvenle Türkçe olan satır ([TurkishText.isSure]) çevirmene gönderilmez (#289). */
    @Volatile var skipsTurkish = true
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
        // Konuşma değişirken sabit duran görev/HUD satırı ("Get in the sea plane", GTA 6) altyazı bloğuna katılmaz.
        val rows = raw.withoutButtonPrompts().withoutOcrNoise().joiningRows()
        val reading = synchronized(lock) { stickyRows.filter(rows, now()) }.subtitleBlock(area)
        var flushed: (() -> Unit)? = null
        val after: (() -> Unit)? = synchronized(lock) {
            var action = stabilizer.feed(reading.text, signature, reading.box)
            val box = reading.box?.placedIn(area)?.centeredOnScreen()
            var fromHold: (() -> Unit)? = null
            held?.let { waiting ->
                val time = now()
                if (action.kind == StabilizerKind.TRANSLATE) {
                    // Bozuk ve yarım okumaların her biri kararlayıcıya yeni satır gibi görünür.
                    val source = action.text!!
                    val wait = maxOf(waiting.wait, waitFor(source))
                    if (findPack(source) != null) {
                        // Pakette bulundu: bekleyen okuma çevrilmez, bu okuma her zamanki yoldan gider.
                        held = null
                    } else if (TextMatch.addsMeaning(source, waiting.source) &&
                        TextMatch.isSimilar(TextMatch.normalize(source), TextMatch.normalize(waiting.source))) {
                        // Olumsuzluk/sayı düzeltmesi bekleyenin yerini alır; yanlış ilk okuma çevrilmez.
                        val merged = Rereads.keepMissingLines(source, waiting.source)
                        held = waiting.copy(source = merged, box = box ?: waiting.box, wait = wait, score = Rereads.score(merged))
                        action = StabilizerAction.None
                        lineLeft()
                        if (time - waiting.since >= wait) fromHold = flushHeld()
                    } else if ((Rereads.isRereadOf(source, waiting.source) || Rereads.isRereadOf(waiting.source, source)) &&
                        time - waiting.since < wait) {
                        // Aynı satırın başka bir okuması: daha iyisi tutulur, süre baştan başlamaz.
                        if (Rereads.score(source) > waiting.score) {
                            val merged = Rereads.keepMissingLines(source, waiting.source)
                            held = waiting.copy(source = merged, box = box ?: waiting.box, wait = wait, score = Rereads.score(merged))
                        }
                        action = StabilizerAction.None
                        lineLeft()
                    } else if (Rereads.looksMisread(waiting.source)) {
                        // Bekleyen bozuk okumaydı ve yerine başka bir okuma geldi: bozuk okuma çevrilmez.
                        held = null
                    } else if (Rereads.looksMisread(source) && time - waiting.since < waiting.wait) {
                        // Araya giren bozuk ve ilgisiz okuma bekleyeni bozmaz; yok sayılır.
                        // Kararlayıcı onu gönderilmiş saymasın: gerçek yeni satırsa bekleme bitince çevrilir.
                        stabilizer.withdrawSent()
                        action = StabilizerAction.None
                    } else {
                        // Bekleyen temiz bir satırdı, yerine başka satır geldi: önce o çevrilir.
                        flushed = flushHeld()
                    }
                } else if (action.kind != StabilizerKind.NONE) {
                    // Bölge boşaldı ya da eski satır geri geldi: bekleyen temiz satır çevrilir, bozuk okuma çevrilmez.
                    if (Rereads.looksMisread(waiting.source)) held = null else flushed = flushHeld()
                } else {
                    // Kararlayıcı aynı satır saydı; okuma daha iyiyse (ör. yarım okumanın tamamı) o tutulur.
                    val text = reading.text.trim()
                    var current = waiting
                    if (text.length >= 3 && Rereads.related(text, waiting.source) && Rereads.score(text) > waiting.score) {
                        val merged = Rereads.keepMissingLines(text, waiting.source)
                        current = waiting.copy(source = merged, box = box ?: waiting.box, score = Rereads.score(merged))
                        held = current
                    }
                    if (time - current.since >= current.wait) fromHold = flushHeld()
                }
            }
            val result = when (action.kind) {
                StabilizerKind.CLEAR -> {
                    lastClearAt = now()
                    lineLeft()
                    sender.clear()
                    null
                }
                StabilizerKind.TRANSLATE -> {
                    translateOrHold(action.text!!, box)
                }
                StabilizerKind.RESTORE -> {
                    lineLeft()
                    restore(action.text!!, box)
                }
                StabilizerKind.NONE -> fromHold
            }
            // Restore önce işlenir: geri görünen satırın leftAt bilgisi temizlenmeden iptal edilmemeli.
            abandonUndisplayableTranslation()
            result
        }
        // Olaylar kilidin dışında çağrılır.
        flushed?.invoke()
        after?.invoke()
    }

    /** Bekletilen okumayı çeviriye gönderir (lock tutulurken çağrılır). */
    private fun flushHeld(): (() -> Unit)? {
        val waiting = held ?: return null
        held = null
        return enqueue(waiting.source, waiting.box, waiting.capturedAt, waiting.ocrMs)
    }

    private fun findPack(source: String): PackMatch? {
        held?.let { pending ->
            if (isPackedFragment(source, pending.source) && Rereads.allLinesCovered(source, pending.source)
                && Rereads.score(source) <= pending.score) return null
        }
        val lookup = packLookup ?: return null
        return lookup(source) ?: SpeakerPrefix.split(source)?.let { lookup(it.body) }
    }

    /**
     * Bozuk ya da yarım olabilecek okuma hemen çevrilmez, kısa süre bekletilir; aynı satırın daha iyi okuması gelirse o
     * çevrilir. Temiz ve tam cümle ya da pakette bulunan satır beklemeden gider (Windows: TranslateOrHold).
     */
    private fun translateOrHold(source: String, box: TextBox?): (() -> Unit)? {
        if (restoreQueued(source)) return null
        if (!holdReadings) { lineLeft(); return enqueue(source, box) }
        val packed = findPack(source) != null
        // Az önce çevrilen satırın daha iyi olmayan yeniden okuması yeni satır değildir (TV'de üst üste binmesin).
        val time = now()
        lastSent?.let { last ->
            if ((!packed || (last.at > lastClearAt && isPackedFragment(source, last.source)))
                && time - last.at < REREAD_WITHIN_MS && Rereads.allLinesCovered(source, last.source) && Rereads.score(source) <= last.score) {
                lastSent = last.copy(at = time)
                return null
            }
        }
        lineLeft()
        if (packed) return enqueue(source, box)
        val wait = waitFor(source)
        if (wait <= 0) return enqueue(source, box)
        held = Held(source, box, time, wait, Rereads.score(source), frameAt, frameOcrMs)
        return null
    }

    // Paket eşleşmesi tek başına eksik parçayı yeni replik yapmaz. Tam kısa cümleler korunur.
    private fun isPackedFragment(source: String, previous: String): Boolean {
        if (Rereads.looksComplete(source)) return false
        val fragment = TextMatch.normalize(source)
        val full = TextMatch.normalize(previous)
        return fragment.isNotEmpty() && fragment.length < full.length && (" $full ").contains(" $fragment ")
    }

    /** Bozuksa [packWait], temiz ama yarım olabilecekse [cleanWait], temiz ve tam cümleyse 0. */
    private fun waitFor(source: String): Int = when {
        !holdReadings -> 0
        Rereads.looksMisread(source) -> maxOf(0, packWait)
        Rereads.looksComplete(source) -> 0
        else -> maxOf(0, cleanWait)
    }

    /**
     * Süren çeviri artık gösterilemeyecekse üretimi iptal eder (çeviri iş parçacığı kesilir), böylece sıradaki satır onu
     * beklemez. Yalnız iki durumda: daha yeni bir satır ekranda gösterilmişse, ya da satır [LATE_RESULT_MS]'ten önce
     * kalkmış, ekranda değil ve sırada gösterilebilir yeni bir satır bekliyorsa. Ekranda duran satır üretimi ne kadar
     * uzarsa uzasın iptal edilmez. İptal edilen satır ekrana geri gelirse ([restore]) yeniden çevrilir. Kesmeyi
     * dinlemeyen motorun sonucu da gösterilmez ve eşzamanlı ikinci üretim başlamaz. Windows ve Mac/iPhone aynı kuralları uygular.
     */
    private fun abandonUndisplayableTranslation() {
        val current = inFlight ?: return
        if (translating !== current || current.session != session || current.superseded || current.abandoned) return
        val time = now()
        fun late(request: Request) = request.leftAt.let { left -> left != null && time - left > LATE_RESULT_MS }
        val replaced = current.number < lastShown
        val expired = current.number > lastShown && current.number != lineOnScreen && late(current)
        if (!replaced && !expired) return
        val hasWaiting = waiting.any { it.session == session && !it.superseded && !it.abandoned && !late(it) }
        if (!replaced && !hasWaiting) return
        current.abandoned = true
        worker?.interrupt()
    }

    private fun lineLeft() {
        val number = lineOnScreen ?: return
        val time = now()
        for (request in requests()) if (request.number == number && request.leftAt == null) request.leftAt = time
        lineOnScreen = null
    }

    private fun enqueue(source: String, box: TextBox?, capturedAt: Long? = frameAt, ocrMs: Int? = frameOcrMs): (() -> Unit)? {
        val request = Request(++lastRequested, source, box, session, capturedAt, ocrMs)
        lineOnScreen = request.number
        lastSent = Sent(source, Rereads.score(source), now())
        packMatch(request)?.let { return showPacked(request, it) }
        if (skipsTurkish && TurkishText.isSure(source)) {
            remember(request.number, source, null)
            return null
        }
        val missed = onPackMissed
        val current = inFlight
        if (current == null) {
            inFlight = request
            executor.execute { pump(request) }
        } else {
            // Aynı cümlenin eski okuması sırada bekliyorsa çıkar; sıra dolduysa en eski bekleyen atlanır.
            waiting.removeAll { TextMatch.isRevision(source, it.source) && !TextMatch.isGrowth(it.source, source) }
            waiting.add(request)
            while (waiting.size > MAX_WAITING) waiting.removeAt(0)
            // Süren çeviri bu cümlenin yarım okumasınınsa (daktilo efekti) sonucu gösterilmez; tamamı sıradan çevrilir.
            if (!current.superseded && !current.abandoned && current.session == session && TextMatch.isGrowth(source, current.source)) current.superseded = true
        }
        return missed?.let { callback -> { callback(source) } }
    }

    // Tam okuma geri gelirse aradaki kısalmış kayıtları birleştir; sıra ve okuma zamanı korunur.
    // Doğrulanmış boş bölgeyi aşma: kısa metin ayrı bir replik olabilir.
    private fun restoreQueued(source: String): Boolean {
        val full = waiting.lastOrNull { it.source == source } ?: return false
        val left = full.leftAt ?: return false
        if (left <= lastClearAt) return false
        val fragment: (Request) -> Boolean = { it.number > full.number && TextMatch.isGrowth(source, it.source) }
        if (!waiting.any(fragment)) return false
        waiting.removeAll(fragment)
        lineLeft()
        full.leftAt = null
        lineOnScreen = full.number
        lastSent = Sent(source, Rereads.score(source), now())
        return true
    }

    /** Süren ve sırada bekleyen istekler. */
    private fun requests(): List<Request> = listOfNotNull(inFlight) + waiting

    /** Satır az önce gösterilenin uzamış ya da düzelmiş okuması mı (TV yerine koyar, üstüne yığmaz). */
    private fun revisesShown(source: String) = lastShownSource?.let { TextMatch.isRevision(source, it) } ?: false

    /** Paket önce adlı satırla, bulunmazsa adsız cümleyle aranır (paket anahtarları çoğu zaman adsızdır). */
    private fun packMatch(request: Request): PackMatch? {
        val lookup = packLookup ?: return null
        return lookup(request.source) ?: request.prefix?.let { lookup(it.body) }
    }

    /** Gösterilecek çeviri: konuşan adı ayara göre başa eklenir ya da atılır. */
    private fun present(translation: String, request: Request) =
        SpeakerPrefix.present(translation, request.source, showSpeakerNames())

    private fun showPacked(request: Request, packed: PackMatch): (() -> Unit)? {
        waiting.clear()
        packHits++
        val source = request.source
        val translated = present(packed.text, request)
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
        if (restoreQueued(source)) return null
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
            if (request.source != source || request.session != session || request.superseded || request.abandoned) continue
            request.leftAt = null
            lineOnScreen = request.number
            return null
        }
        return enqueue(source, box)
    }

    private fun pump(first: Request) {
        var request = first
        while (true) {
            synchronized(lock) {
                translating = request
                worker = Thread.currentThread()
            }
            try {
                translate(request)
            } catch (error: RuntimeException) {
                // Olay işleyicilerinden biri hata verse de sıra takılı kalmasın.
            }
            synchronized(lock) {
                // İptal kesmesi bu istekten sonraki çeviriye sızmasın: kesme yalnız kilit altında ve translating doluyken gelir.
                translating = null
                worker = null
                Thread.interrupted()
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
        val input = request.prefix?.body ?: source
        // Ayrılan ad çevirmene gitmez; cümle içinde geçtiğinde korunsun diye ayrıca bildirilir (#287).
        request.prefix?.let { translator.noteSpeaker(it.name) }
        val started = now()
        val sentence = try {
            translator.translate(input)
        } catch (error: Exception) {
            synchronized(lock) {
                // Yerine uzamış okuması gelen ya da bırakılan satırın çevirisi hata sayılmaz.
                if (request.session != session || request.superseded || request.abandoned) return
                // Model eksikse ya da geçici hata olduysa satır ekranda kaldıkça (saniyede en çok bir kez) yeniden denenir.
                if (request.number == lineOnScreen) {
                    stabilizer.forgetSent()
                    // Çevrilemeyen satırın yeniden okuması "az önce çevrilen" sayılıp atlanmasın; yeniden denensin.
                    if (lastSent?.source == request.source) lastSent = null
                }
            }
            onTranslationResult?.invoke(error)
            return
        }
        if (request.abandoned) return
        onTranslationResult?.invoke(null)
        val translated = present(sentence, request)
        val translationMs = maxOf(0, (now() - started).toInt())
        var total: Int? = null
        synchronized(lock) {
            if (request.session != session || request.abandoned) return
            val shouldSend = stabilizer.shouldSend(input, sentence)
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
        held = null
        lastSent = null
        lastClearAt = Long.MIN_VALUE
        waiting.clear()
        lastShownSource = null
        pairs.clear()
        stickyRows.reset()
        if (stabilizer.reset() == StabilizerAction.Clear) sender.clear()
    }

    fun shutdown() {
        executor.shutdownNow()
    }
}
