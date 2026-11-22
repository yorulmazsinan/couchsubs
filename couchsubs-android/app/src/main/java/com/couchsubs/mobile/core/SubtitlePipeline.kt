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
         * sonra gelir; sınır 1 sn iken üç satırlık konuşmanın yalnız ilki görünüyordu. Süre satırın kalktığı andan, satır
         * sırada beklediyse çevirisinin başladığı andan sayılır: önceki satırların çevirisini bekleyen satır sıranın
         * gecikmesi yüzünden atılmaz.
         */
        const val LATE_RESULT_MS = 2500
        /**
         * Arkasından yeni satır gelmiş (konuşma sürüyor) satırın geç gelen çevirisi bu süreye kadar yine gösterilir; yeni
         * satır onun ardından gider, sıra bozulmaz. Daha eskisi hiçbir zaman gösterilmez. GitHub #893: yapay zekâ çevirisi
         * satır başına bir iki saniye sürüyor; art arda gelen satırların ilki yenisi geldikten 2,5 sn sonra çevrilince
         * atılıyor ya da yarıda bırakılıyordu, bazı satırlar TV'ye hiç gitmiyordu (ücretsiz motorda olmuyordu).
         */
        const val QUEUED_LATE_RESULT_MS = 8000
        /** Çeviri sürerken sırada en çok bu kadar satır bekler; daha eskisi atlanır (kuyruk konuşma hızıyla büyümesin). */
        const val MAX_WAITING = 4
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
        /** Ayarlardaki bekleme kaydırıcılarının üst sınırı ve hatta uygulanan en uzun bekleme (ms). */
        const val WAIT_SLIDER_MAX_MS = 1000
        const val MAX_WAIT_MS = 2000
        /** Çevrilen satırın daha iyi olmayan yeniden okuması bu süre içinde yeni satır sayılmaz. */
        const val REREAD_WITHIN_MS = 4000

        /** Satır ekrandan kalktıktan sonra gelen çevirinin TV'de kalacağı süre (TV uygulamasıyla aynı kural). */
        fun readingTime(text: String) = minOf(8000, 2000 + text.length * 60)
    }

    private class Request(source: String, val number: Int, val box: TextBox?, val session: Int,
                          val capturedAt: Long? = null, val ocrMs: Int? = null) {
        /** Ad sonradan okunursa ([nameRead]) adlı okumaya döner; çeviriye giden cümle aynı kalır. */
        @Volatile var source = source
        /** Baştaki konuşan adı ("ARTHUR: …"); çeviriye yalnız cümle gider. */
        @Volatile var prefix = SpeakerPrefix.split(source)
        @Volatile var leftAt: Long? = null
        /** Çevirisinin başladığı an (sırada bekliyorsa null). */
        @Volatile var startedAt: Long? = null
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
    /**
     * Gösterilen çeviriler: karede okunan kendi altyazımız (OBS Program projektörü) yeni satır sayılmaz (bkz.
     * [OwnSubtitles]). Telefonda OBS yolu yoktur; süzgeç Mac/Windows ile aynı kalsın diye burada da çalışır.
     */
    val own = OwnSubtitles(now)
    /** Günlüğe yazılmış son kendi altyazısı (her karede yeniden yazılmasın). */
    private var loggedOwn: String? = null
    /** Günlüğe yazılmış son telefon yazısı (her karede yeniden yazılmasın). */
    private var loggedPhone: String? = null
    /** Son gönderilen çevirinin İngilizce satırının yeri. */
    private var lastSentBox: TextBox? = null
    private val stabilizer = SubtitleStabilizer(clock = now)
    /** Konuşma değişirken sabit duran görev/HUD satırları (GTA 6). */
    private val stickyRows = StickyRows()
    /** Bu oturumda kesin altyazının okunduğu yükseklikler: oradaki kısa satır sahne yazısı sayılmaz ([SceneText]). */
    private val subtitleBand = SubtitleBand()
    /** Günlüğe yazılmış son sahne yazıları (her karede yeniden yazılmasın). */
    private val loggedSceneText = ArrayDeque<String>()
    /** Son günlüğe yazılan sabit blok ([logStale]; aynı bant her karede yazılmasın). */
    private var loggedStale = ""

    /** Altyazı günlüğü (Mac/iPhone `onLog`, Windows `Log`): şimdilik sahne yazısı sayılıp atılan bloklar. */
    var onLog: ((String) -> Unit)? = null

    /**
     * Altyazı alanında yazı çıkmayan sürenin tanısı ([QuietReads]); sessizlik [QuietReads.REPORT_AFTER_MS] sürerse nedeni
     * (okunmadı mı, boş mu okundu, süzgeçte mi kaldı, hata mı) günlüğe yazılır (Mac, iPhone, Windows ile aynı).
     */
    private var quiet = QuietReads(now())

    /**
     * Ekranda menü var (otomatik ekran yazısı menü durumunda) ve bu kare altyazı için okunmuyor. Eskiden bu atlama günlüğe
     * hiç yazılmıyordu: Mac'te (beta.80, PS5, GTA 6) ekranda diyalog varken altyazı günlüğüne dakikalarca hiçbir satır
     * düşmüyor, okunmadığı mı, boş mu okunduğu mu anlaşılmıyordu.
     */
    fun skipForMenu() {
        // Geçiş günlüğe hizmette yazılır (TranslationService); burada yalnız sessizlik özetine sayılır.
        val message = synchronized(lock) {
            quiet.menu++
            quietReport()
        }
        message?.let { onLog?.invoke(it) }
    }

    /** Altyazı okuması hata verdi (zaman aşımı dahil); kare boş sayılır, hata sessizlik özetine yazılır. */
    fun noteReadFailure(error: Throwable) {
        val message = synchronized(lock) {
            quiet.frames++
            quiet.reads++
            quiet.failures++
            quiet.lastError = error.message ?: error.javaClass.simpleName
            quietReport()
        }
        message?.let { onLog?.invoke(it) }
    }

    /** Kilit altında: `REPORT_AFTER_MS`'dir yazı çıkmadıysa özet döner, sayaç yeniden başlar. */
    private fun quietReport(): String? {
        val time = now()
        if (time - quiet.since < QuietReads.REPORT_AFTER_MS) return null
        return quiet.summary(time).also { quiet = QuietReads(time) }
    }

    /** Uzun süredir değişmeyen ortalı blok (haber bandı) yeni beliren bloğun yanında altyazı sayılmadı (GitHub #933). */
    private fun logStale(texts: List<String>) {
        val key = texts.joinToString("\n")
        if (key == loggedStale) return
        loggedStale = key
        if (texts.isEmpty()) return
        val excerpt = key.replace('\n', ' ').let { if (it.length > 120) it.take(120) + "…" else it }
        onLog?.invoke("sabit blok atlandı: \"$excerpt\" ${Reading.STALE_MS / 1000} sn'dir değişmiyor, yanında yeni ortalı blok var")
    }

    /** Sahne yazısı sayılıp atılan blok günlüğe nedeniyle bir kez yazılır (GitHub #822). */
    private fun logSceneText(text: String, reason: String) {
        val key = "$text|$reason"
        if (key in loggedSceneText) return
        loggedSceneText.addLast(key)
        if (loggedSceneText.size > 20) loggedSceneText.removeFirst()
        val excerpt = text.replace('\n', ' ').let { if (it.length > 120) it.take(120) + "…" else it }
        onLog?.invoke("sahne yazısı: \"$excerpt\" altyazı sayılmadı ($reason)")
    }
    private val mission = MissionLine()

    /**
     * Görev satırının bölgesi değişti (null: görev kalktı). Görev altyazıya girmez; bölgesi "auto-mission" ek alanı olarak
     * kendi yerinde ve özgün stilinde gösterilir (bkz. [MissionLine]).
     */
    @Volatile var onMissionChanged: ((CropRegion?) -> Unit)? = null
    private val notices = ScreenNotices()

    /**
     * Ekranın kenarındaki bildirim kartlarının alanları değişti (boş: hiç yok). Bildirim altyazıya girmez; alanları
     * "auto-notice-<n>" ek alanı olarak kendi yerinde ve özgün stilinde gösterilir (bkz. [ScreenNotices]).
     */
    @Volatile var onNoticesChanged: ((List<ExtraArea>) -> Unit)? = null
    /**
     * Altyazının son okunan satırları ve alanı; ekran yazısı okuyucuları bunlarla altyazıyı dışlar (bkz. [SubtitleEcho]).
     * Uygulama [SubtitleEcho.shared] verir.
     */
    @Volatile var echo: SubtitleEcho? = null
        set(value) {
            field = value
            value?.own = own
        }
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

    /**
     * Ayarlardaki "Bozuk okunan satır için bekleme" ve "Yarım okunan satır için bekleme" sürelerini uygular (Windows
     * ApplyWaits, Mac/iPhone applyWaits ile aynı sınırlar: 0–2 sn). Hat yeniden kurulmaz.
     */
    fun applyWaits(misreadMs: Int, partialMs: Int) {
        packWait = misreadMs.coerceIn(0, MAX_WAIT_MS)
        cleanWait = partialMs.coerceIn(0, MAX_WAIT_MS)
    }

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
    fun process(raw: Reading, area: TextBox, signature: ByteArray? = null, capturedAt: Long? = null, ocrMs: Int? = null,
                phone: ScreenPhoneCard.Handset? = null, reused: Boolean = false) {
        frameAt = capturedAt
        frameOcrMs = ocrMs
        synchronized(lock) {
            quiet.frames++
            if (!reused) {
                quiet.reads++
                if (raw.lines.isEmpty()) quiet.empty++
            }
        }
        // Kumanda ipuçları ve yazı tanıma çöpleri çevrilmez; yalnız altyazı bloğu çevrilir.
        // Konuşma değişirken sabit duran görev/HUD satırı ("Get in the sea plane", GTA 6) altyazı bloğuna katılmaz.
        // Karede kendi altyazımız (OBS Program projektörü, CouchSubs'ın OBS katmanı) varsa okunmaz (bkz. [OwnSubtitles]).
        var (seen, ownLines) = own.split(raw, area)
        // Karede açık GTA 6 telefonunun ekranındaki satırlar altyazı değildir ([ScreenPhoneCard.holds]); telefonun çevirisi
        // kendi yerindedir. Kullanıcı bildirimleri (X, beta.79): telefonun alt kısmındaki mesajlar (telefon ortaya yakın
        // tutulunca bütün sohbet) altyazı sanılıp ekranın ortasında tek uzun satır olarak çevriliyordu (Mac, Windows ile aynı).
        if (phone != null) {
            val kept = seen.lines.filter { line -> line.box?.let { !ScreenPhoneCard.holds(it.placedIn(area), phone) } ?: true }
            if (kept.size < seen.lines.size) {
                val text = seen.lines.filter { it !in kept }.joinToString(" ") { it.text }
                val fresh = synchronized(lock) { (text != loggedPhone).also { loggedPhone = text } }
                val excerpt = if (text.length > 120) text.take(120) + "…" else text
                if (fresh) onLog?.invoke("telefon yazısı: \"$excerpt\" telefonun ekranında, altyazı sayılmadı")
                seen = Reading(kept)
            }
        }
        if (ownLines.isNotEmpty()) {
            val fresh = synchronized(lock) { (ownLines[0].text != loggedOwn).also { loggedOwn = ownLines[0].text } }
            val excerpt = ownLines.joinToString(" ") { it.text }.let { if (it.length > 120) it.take(120) + "…" else it }
            if (fresh) onLog?.invoke("kendi altyazısı: \"$excerpt\" karede okundu, " +
                "yok sayıldı (görüntü kaynağı CouchSubs'ın OBS katmanını da içeriyor; OBS'te Kaynak projektörünü seçin)")
        }
        val rows = seen.withoutButtonPrompts().withoutOcrNoise().joiningRows()
        var missionChanged = false
        var missionRegion: CropRegion? = null
        var noticesChanged = false
        var noticeAreas: List<ExtraArea> = emptyList()
        var filteredRows = Reading(emptyList())
        val reading = synchronized(lock) {
            val filtered = stickyRows.filter(rows, now())
            filteredRows = filtered
            if (mission.observe(stickyRows.removed, area, now())) {
                missionChanged = true
                missionRegion = mission.region
            }
            // Bu oturumda altyazının okunduğu yükseklikteki kısa satır tabela sayılmaz; atılan blok günlüğe (GitHub #822).
            val edge = mutableListOf<Reading>()
            val staleTexts = mutableListOf<String>()
            val readAt = now()
            filtered.subtitleBlock(area, subtitleBand, notices = { block ->
                edge.add(Reading(block.lines.map { it.copy(box = it.box?.placedIn(area)) }))
            }, age = { stickyRows.unchangedMs(it, readAt) }, stale = { block -> staleTexts += block.lines.map { it.text } }) {
                block, reason -> logSceneText(block.text, reason)
            }.also {
                logStale(staleTexts)
                subtitleBand.record(it, area)
                if (notices.observe(edge, now())) {
                    noticesChanged = true
                    noticeAreas = notices.areas
                }
            }
        }
        // Kenardaki bildirim kartı altyazının yerinde (ekranın ortasında) değil, kendi yerinde çevrilir.
        if (noticesChanged) {
            onLog?.invoke(if (noticeAreas.isEmpty()) "kenar bildirimi kalktı" else "kenar bildirimi kendi yerinde gösteriliyor (${noticeAreas.size})")
            onNoticesChanged?.invoke(noticeAreas)
        }
        // Ekran yazısı okuyucuları altyazıyı ikinci kez çizmesin (bkz. [SubtitleEcho]).
        echo?.record(reading, area)
        val quietMessage = synchronized(lock) {
            if (reading.text.isBlank()) {
                if (filteredRows.lines.isNotEmpty()) quiet.dropped++ else if (raw.lines.isNotEmpty()) quiet.filtered++
                quietReport()
            } else {
                quiet = QuietReads(now())
                null
            }
        }
        quietMessage?.let { onLog?.invoke(it) }
        if (missionChanged) onMissionChanged?.invoke(missionRegion)
        var flushed: (() -> Unit)? = null
        val after: (() -> Unit)? = synchronized(lock) {
            // Altyazının yerinde yalnız kendi çevirimiz okunduysa (örtme ya da üst üste binen katman) satır kalkmış sayılmaz.
            val ownOnly = ownLines.isNotEmpty() && reading.lines.isEmpty() && OwnSubtitles.coversLine(ownLines, lastSentBox)
            var action = if (ownOnly) StabilizerAction.None else stabilizer.feed(reading.text, signature, reading.box)
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
                    clearScreen()
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
        val forced = synchronized(lock) {
            watchSilence(raw, listOf("kendi altyazısı" to ownLines, "telefon yazısı" to seen.lines,
                "kumanda ipucu ya da okuma gürültüsü" to rows.lines, "sabit satır (görev/HUD)" to filteredRows.lines,
                "altyazı bloğu seçilmedi (sahne yazısı, menü ya da başka blok)" to reading.lines), area)
        }
        // Olaylar kilidin dışında çağrılır.
        flushed?.invoke()
        after?.invoke()
        forced?.invoke()
    }

    /** Sessizlik bekçisi ([watchSilence]). */
    private var silence = SilenceWatch()

    /**
     * lock tutulurken çağrılır. Alanda konuşmaya benzeyen satır 10 sn okunup hiçbir şey gönderilmediyse süzgeçleri atlayıp
     * o satırı doğrudan çeviriye verir (en çok 10 sn'de bir, aynı satırı bir kez); hangi aşamanın tuttuğu günlüğe yazılır.
     * Kendi altyazımız ve telefon yazısı hiçbir zaman gönderilmez (Mac/iPhone, Windows ile aynı).
     */
    private fun watchSilence(raw: Reading, stages: List<Pair<String, List<TextLine>>>, area: TextBox): (() -> Unit)? {
        val candidate = silence.due(raw.lines.map { it.text }, now()) ?: return null
        val key = TextMatch.normalize(candidate)
        fun holds(lines: List<TextLine>) = lines.any { line ->
            val text = TextMatch.normalize(line.text)
            text.contains(key) || (text.isNotEmpty() && key.contains(text) && text.length * 2 >= key.length)
        }
        val holder = if (holds(stages[0].second)) stages[0].first
            else stages.drop(1).firstOrNull { !holds(it.second) }?.first ?: "kararlayıcı ya da bekleme (çeviri gönderilmedi)"
        if (holder == "kendi altyazısı" || holder == "telefon yazısı") return null
        silence.fired(candidate, now())
        val excerpt = candidate.replace('\n', ' ').let { if (it.length > 120) it.take(120) + "…" else it }
        onLog?.invoke("bekçi: \"$excerpt\" ${SilenceWatch.SILENCE_MS / 1000} sn'dir okunuyor, hiçbir şey gönderilmedi " +
            "(tutan: $holder); doğrudan çevriliyor")
        val box = raw.lines.firstOrNull { it.text == candidate }?.box?.placedIn(area)?.centeredOnScreen()
        lineLeft()
        return enqueue(candidate, box)
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
        nameRead(source)?.let { return it }
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

    /**
     * Konuşan adı sonradan okundu: ilk karede renkli ad okunamayıp cümle adsız gitmiş, sonraki karede aynı cümle
     * "JASON: …" diye okunmuş. Bu yeni satır değildir; cümle yeniden çevrilmez, ekrandaki (ya da süren) çeviriye ad
     * eklenir ve TV'de aynı satırın yerine geçer. Yoksa her diyalog satırı önce adsız beyaz, sonra adlı renkli iki kez
     * görünüyordu (X: "çift altyazı"). Ad sonradan okunduysa kilit bırakılınca çağrılacak olay (boş da olabilir), yoksa
     * null döner. Mac/iPhone (nameRead) ve Windows (NameRead) aynı kuralı uygular.
     */
    private fun nameRead(source: String): (() -> Unit)? {
        val prefix = SpeakerPrefix.split(source) ?: return null
        requests().lastOrNull {
            it.session == session && !it.superseded && !it.abandoned && it.prefix == null && sameSentence(prefix.body, it.source)
        }?.let { request ->
            request.source = source
            request.prefix = prefix
            request.leftAt = null
            lineOnScreen = request.number
            lastSent = Sent(source, Rereads.score(source), now())
            return {}
        }
        val shown = lineOnScreen ?: return null
        val lastSource = lastShownSource ?: return null
        if (shown != lastShown || SpeakerPrefix.split(lastSource) != null || !sameSentence(prefix.body, lastSource)) return null
        val previous = pairs.lastOrNull { it.number == shown && it.source == lastSource }?.translation ?: return null
        val translated = SpeakerPrefix.present(previous, source, showSpeakerNames())
        remember(shown, source, translated)
        lastSent = Sent(source, Rereads.score(source), now())
        lastShownSource = source
        if (translated == previous) return {}
        send(translated, source, 15000, lastSentBox, true)
        val pairShown = onPairShown
        return { pairShown?.invoke(ShownPair(source, translated, "motor", null, null, null, null)) }
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
     * beklemez. Yalnız iki durumda: daha yeni bir satır ekranda gösterilmişse, ya da satırın çevirisi artık geç ([isLate]),
     * satır ekranda değil ve sırada gösterilebilir yeni bir satır bekliyorsa. Ekranda duran satır üretimi ne kadar
     * uzarsa uzasın iptal edilmez. İptal edilen satır ekrana geri gelirse ([restore]) yeniden çevrilir. Kesmeyi
     * dinlemeyen motorun sonucu da gösterilmez ve eşzamanlı ikinci üretim başlamaz. Windows ve Mac/iPhone aynı kuralları uygular.
     */
    private fun abandonUndisplayableTranslation() {
        val current = inFlight ?: return
        if (translating !== current || current.session != session || current.superseded || current.abandoned) return
        val time = now()
        fun late(request: Request) = isLate(request, time)
        val replaced = current.number < lastShown
        val expired = current.number > lastShown && current.number != lineOnScreen && late(current)
        if (!replaced && !expired) return
        val hasWaiting = waiting.any { it.session == session && !it.superseded && !it.abandoned && !late(it) }
        if (!replaced && !hasWaiting) return
        current.abandoned = true
        worker?.interrupt()
    }

    /**
     * Satırın çevirisi artık gösterilemeyecek kadar geç mi (kilit tutulurken çağrılır). Ekrandaki satır hiçbir zaman geç
     * değildir. Süre satırın kalktığı andan, sırada beklediyse çevirisinin başladığı andan sayılır ([LATE_RESULT_MS]);
     * arkasından yeni satır gelmişse yeni satır onu beklediği için [QUEUED_LATE_RESULT_MS]'e kadar gösterilir
     * (GitHub #893). Windows ve Mac/iPhone aynı.
     */
    private fun isLate(request: Request, time: Long): Boolean {
        val left = request.leftAt ?: return false
        if (time - left > QUEUED_LATE_RESULT_MS) return true
        if (request.number < lastRequested) return false
        return time - maxOf(left, request.startedAt ?: time) > LATE_RESULT_MS
    }

    private fun lineLeft() {
        val number = lineOnScreen ?: return
        val time = now()
        for (request in requests()) if (request.number == number && request.leftAt == null) request.leftAt = time
        lineOnScreen = null
    }

    private fun enqueue(source: String, box: TextBox?, capturedAt: Long? = frameAt, ocrMs: Int? = frameOcrMs): (() -> Unit)? {
        val request = Request(source, ++lastRequested, box, session, capturedAt, ocrMs)
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
        send(translated, source, 15000, request.box, revisesShown(source))
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
                send(it, source, 15000, box, revisesShown(source))
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
                waiting.removeAll { it.session != session || isLate(it, time) }
                val next = if (waiting.isEmpty()) null else waiting.removeAt(0)
                inFlight = next
                if (next == null) return
                request = next
            }
        }
    }

    private fun translate(request: Request) {
        var source = request.source
        val input = request.prefix?.body ?: source
        // Ayrılan ad çevirmene gitmez; cümle içinde geçtiğinde korunsun diye ayrıca bildirilir (#287).
        request.prefix?.let { translator.noteSpeaker(it.name) }
        val started = now()
        request.startedAt = started
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
        var translated: String
        val translationMs = maxOf(0, (now() - started).toInt())
        var total: Int? = null
        synchronized(lock) {
            if (request.session != session || request.abandoned) return
            // Çeviri sürerken konuşan adı okunduysa ([nameRead]) çeviri adlı okumayla gösterilir.
            source = request.source
            translated = present(sentence, request)
            val shouldSend = stabilizer.shouldSend(input, sentence)
            remember(request.number, source, if (shouldSend) translated else null)
            if (request.number <= lastShown || !shouldSend || request.superseded) return
            val onScreen = request.number == lineOnScreen
            val left = request.leftAt
            // Satır ekrandan çoktan kalktıysa çevirisi sonraki sahnenin üstüne düşmesin.
            if (!onScreen && left != null && isLate(request, now())) return
            lastShown = request.number
            send(translated, source, if (onScreen) 15000 else readingTime(translated), request.box, revisesShown(source))
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
        quiet = QuietReads(now())
        silence = SilenceWatch()
        session++
        lineOnScreen = null
        held = null
        lastSent = null
        lastClearAt = Long.MIN_VALUE
        waiting.clear()
        lastShownSource = null
        pairs.clear()
        stickyRows.reset()
        subtitleBand.reset()
        loggedSceneText.clear()
        loggedStale = ""
        mission.reset()
        notices.reset()
        echo?.reset()
        loggedOwn = null
        loggedPhone = null
        if (stabilizer.reset() == StabilizerAction.Clear) clearScreen()
        own.reset()
        lastSentBox = null
    }

    /** Çeviri ekrana gider; kendi altyazısı süzgeci onu hatırlar. */
    private fun send(translation: String, source: String, durationMs: Int, box: TextBox?, replaces: Boolean) {
        synchronized(lock) { silence.sent() }
        own.record(translation, source, durationMs)
        lastSentBox = box
        sender.sendSubtitle(translation, durationMs, box, replaces)
    }

    private fun clearScreen() {
        own.cleared()
        sender.clear()
    }

    fun shutdown() {
        executor.shutdownNow()
    }
}

/** Adın ayrıldığı cümle, adsız okunan cümleyle aynı mı (yazı tanıma farkı kadar; olumsuzluk ya da sayı eklenmemiş). */
internal fun sameSentence(body: String, unnamed: String): Boolean {
    val a = TextMatch.normalize(body)
    val b = TextMatch.normalize(unnamed)
    if (a.isEmpty() || b.isEmpty()) return false
    return a == b || (TextMatch.isSimilar(a, b, 0.9) && !TextMatch.addsMeaning(body, unnamed) && !TextMatch.addsMeaning(unnamed, body))
}

/**
 * Altyazı alanında yazı çıkmayan pencerenin sayaçları (tanı): kaç kare geldi, kaçı okundu, okumalar boş mu döndü, satırlar
 * hangi süzgeçte kaldı, okuma hata mı verdi, menü yüzünden mi okunmadı (Mac/iPhone ve Windows: QuietReads).
 */
internal class QuietReads(val since: Long) {
    companion object {
        /** Bu kadar süre altyazı alanından yazı çıkmazsa günlüğe özet yazılır (sessizlik boyunca bu aralıkla bir satır). */
        const val REPORT_AFTER_MS = 60_000
    }

    var frames = 0
    var menu = 0
    var reads = 0
    /** Yazı tanıma alanda hiç satır bulmadı. */
    var empty = 0
    /** Satırlar kendi altyazısı, telefon yazısı, kumanda ipucu, gürültü ya da sabit satır olarak ayıklandı. */
    var filtered = 0
    /** Satırlar kaldı ama altyazı bloğu seçilmedi (sahne yazısı, kenar bildirimi). */
    var dropped = 0
    var failures = 0
    var lastError: String? = null

    fun summary(time: Long): String {
        var text = "altyazı alanında ${(time - since) / 1000} sn'dir yazı yok: $frames kare, $menu kare menü yüzünden okunmadı, " +
            "$reads okuma ($empty boş, $filtered ayıklandı, $dropped altyazı sayılmadı, $failures hata)"
        lastError?.let { text += "; son hata: $it" }
        return text
    }
}
