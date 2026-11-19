// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.translation

import com.couchsubs.mobile.core.SubtitleSegmenter
import com.couchsubs.mobile.core.TextMatch
import com.couchsubs.mobile.core.TextTranslator
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.io.InterruptedIOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Çevrimiçi anahtarın durumu (ayarlardaki "Dene" ve ana ekrandaki uyarı için). */
/**
 * Çevrimiçi çeviri anahtarı denendiğinde ne çıktı. BUSY: hizmete ulaşıldı ama şu an yoğun (5xx), yanıt zamanında
 * gelmedi ya da dakikalık sınıra takıldı; anahtar reddedilmedi, internet de çalışıyor (Windows/Mac ile aynı).
 */
enum class OnlineKeyState {
    VALID, INVALID, QUOTA_EXCEEDED, MODEL_REJECTED, UNREACHABLE, BUSY;

    companion object {
        /** İstek hatasının türü: zaman aşımı yoğunluktur (hizmete ulaşıldı, yanıt gelmedi), diğer ağ hataları ulaşılamadır. */
        fun of(error: Exception): OnlineKeyState = when (error) {
            is OnlineException -> error.state
            is SocketTimeoutException -> BUSY
            else -> UNREACHABLE
        }
    }
}

/** [rateLimited]: hizmet 429 döndü (DeepL: çok sık istek); bekleme süresince istek gönderilmez. */
class OnlineException(val state: OnlineKeyState, val rateLimited: Boolean = false) : IOException("online translation failed: $state")

/**
 * Hizmetin bildirdiği dakikalık istek sınırı aşımı (429; Windows: AiRateLimit). [retryAfterMs]: hizmetin önerdiği
 * bekleme ("retryDelay"), [requestsPerMinute]: bildirdiği dakikalık istek sınırı ("quotaValue"); yoksa null.
 */
data class AiRateLimit(val retryAfterMs: Long? = null, val requestsPerMinute: Int? = null)

/** Dakikalık sınır aşıldı: gün sınırından farklı olarak kısa sürer, kullanıcıya hata gösterilmez. */
class AiRateLimitedException(val limit: AiRateLimit) : IOException("rate limited")

/** Yapay zekâ hizmetleri (Windows: AiProvider, Mac: AIProvider). */
enum class AiProvider(val id: String, val displayName: String) {
    GEMINI("gemini", "Gemini"), OPENAI("openai", "OpenAI"), CLAUDE("claude", "Claude");
}

/** Çevrimiçi motorun yapay zekâ hizmeti (DeepL ve ücretsiz motorda null). */
val com.couchsubs.mobile.settings.EngineChoice.aiProvider: AiProvider?
    get() = when (this) {
        com.couchsubs.mobile.settings.EngineChoice.GEMINI -> AiProvider.GEMINI
        com.couchsubs.mobile.settings.EngineChoice.OPENAI -> AiProvider.OPENAI
        com.couchsubs.mobile.settings.EngineChoice.CLAUDE -> AiProvider.CLAUDE
        else -> null
    }

/** Listedeki bir model ve onunla gönderilen ayarlar (ortak ai-models.json). */
data class AiModel(
    val id: String,
    val label: String,
    val effort: String? = null,
    val thinking: String? = null,
    val freeTier: Boolean = false,
    val requestsPerMinute: Int? = null,
) {
    companion object {
        /** Kayıtlı kimlikteki model; kayıt yoksa ya da listede yoksa listenin ilki (varsayılan; Mac ve iPhone ile aynı). */
        fun selected(models: List<AiModel>, id: String?): AiModel? = models.firstOrNull { it.id == id } ?: models.firstOrNull()

        /** Uygulamayla gelen ai-models.json; okunamazsa boş. */
        fun load(context: android.content.Context): Map<String, List<AiModel>> = try {
            parse(context.assets.open("ai-models.json").use { String(it.readBytes(), Charsets.UTF_8) })
        } catch (error: Exception) {
            emptyMap()
        }

        /** ai-models.json: hizmet adı → modeller; "_comment" gibi dizi olmayan alanlar atlanır. */
        fun parse(json: String): Map<String, List<AiModel>> {
            val root = JSONObject(json)
            val result = mutableMapOf<String, List<AiModel>>()
            for (name in root.keys()) {
                val array = root.optJSONArray(name) ?: continue
                val models = (0 until array.length()).mapNotNull { array.optJSONObject(it) }.map { item ->
                    AiModel(
                        item.getString("id"), item.getString("label"),
                        item.optString("effort").ifEmpty { null }, item.optString("thinking").ifEmpty { null },
                        item.optBoolean("freeTier", false),
                        if (item.has("requestsPerMinute")) item.optInt("requestsPerMinute") else null,
                    )
                }
                if (models.isNotEmpty()) result[name] = models
            }
            return result
        }
    }
}

/**
 * Anahtar kaydedilmeden önce denenir (Mac/iPhone: DeepLTranslator.check ve AITranslationCore.test ile aynı kural):
 * DeepL'de kullanım sorgulanır, yapay zekâ hizmetinde örnek bir satır çevrilir. Geçerli, kotası dolmuş ya da modeli
 * reddedilen anahtar kabul edilir (anahtar doğrudur); geçersiz ya da ulaşılamayan anahtar kaydedilmez.
 */
object KeyCheck {
    /** Denemede çevrilen örnek satır (iPhone ile aynı). */
    const val SAMPLE = "KRATOS: We go now. Stay close, boy."

    fun accepted(state: OnlineKeyState) =
        state == OnlineKeyState.VALID || state == OnlineKeyState.QUOTA_EXCEEDED || state == OnlineKeyState.MODEL_REJECTED ||
            state == OnlineKeyState.BUSY

    /** DeepL: /usage; bu ay kota dolduysa QUOTA_EXCEEDED. Bloklar. */
    fun deepL(key: String, http: Http = Http.Default): OnlineKeyState {
        val trimmed = key.trim()
        if (trimmed.isEmpty()) return OnlineKeyState.INVALID
        return try {
            val (status, body) = http.send("GET", DeepLTranslator.baseUrl(trimmed) + "usage",
                mapOf("Authorization" to "DeepL-Auth-Key $trimmed"), null, 6000)
            if (status !in 200..299) return DeepLTranslator.failure(status)
            val usage = JSONObject(body)
            val count = usage.optLong("character_count", 0)
            val limit = usage.optLong("character_limit", 0)
            if (limit > 0 && count >= limit) OnlineKeyState.QUOTA_EXCEEDED else OnlineKeyState.VALID
        } catch (error: IOException) {
            OnlineKeyState.UNREACHABLE
        } catch (error: JSONException) {
            OnlineKeyState.UNREACHABLE
        }
    }

    /** Yapay zekâ hizmeti: örnek satır seçilen modelle çevrilir. Bloklar. */
    fun ai(provider: AiProvider, key: String, model: AiModel, http: Http = Http.Default): OnlineKeyState {
        if (key.isBlank()) return OnlineKeyState.INVALID
        return try {
            val request = AiRequest.build(provider, key, model, listOf(SAMPLE), emptyList())
            val (status, body) = http.send("POST", request.url, request.headers, request.body, 15000)
            // Dakikalık sınıra takıldıysa anahtar geçerlidir, hizmet şu an yoğundur (bakiye bitmedi).
            if (status !in 200..299) return if (AiRequest.rateLimit(status, body) != null) OnlineKeyState.BUSY else AiRequest.failure(status, body)
            AiRequest.translations(AiRequest.text(provider, body), 1)
            OnlineKeyState.VALID
        } catch (error: IOException) {
            OnlineKeyState.of(error)
        } catch (error: JSONException) {
            OnlineKeyState.UNREACHABLE
        }
    }
}

/** Basit HTTP: gövde gönderir, durum kodu ve yanıt gövdesi döner (testlerde sahtesi verilir). */
fun interface Http {
    fun send(method: String, url: String, headers: Map<String, String>, body: String?, timeoutMs: Int): Pair<Int, String>

    companion object {
        val Default = Http { method, url, headers, body, timeoutMs ->
            val connection = URL(url).openConnection() as HttpURLConnection
            try {
                connection.requestMethod = method
                connection.connectTimeout = timeoutMs
                connection.readTimeout = timeoutMs
                headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
                if (body != null) {
                    connection.doOutput = true
                    connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                }
                val status = connection.responseCode
                val stream = if (status >= 400) connection.errorStream else connection.inputStream
                status to (stream?.use { String(it.readBytes(), Charsets.UTF_8) } ?: "")
            } finally {
                connection.disconnect()
            }
        }
    }
}

/**
 * Cümle cümle çeviren çevrimiçi motorların ortak düzeni (Windows: DeepLTranslator ve AiTranslator): konuşmacı
 * etiketleri çevrilmez, önbellekteki cümleler yeniden gönderilmez, hata olursa o satır yerel motorla çevrilir ve bir
 * dakika hizmet denenmez. Dakikalık istek sınırında ([budget] bitti ya da hizmet 429 ile dakikalık sınırı bildirdi) hata
 * gösterilmez: satır sessizce yerel motorla çevrilir, hizmet en çok 20 saniye dinlenir (Windows ve iPhone ile aynı).
 */
abstract class SentenceTranslator<C>(
    private val local: TextTranslator?,
    protected val cache: TranslationCache = TranslationCache(),
    private val clock: () -> Long = System::currentTimeMillis,
    private val budget: RequestBudget? = null,
) : TextTranslator {
    companion object {
        /** Hata sonrası bu süre hizmet denenmez (DeepL daha kısa bekler: [DeepLTranslator.RETRY_AFTER_MS]). */
        const val RETRY_AFTER_MS = 60_000L
        /** Dakikalık sınır aşılınca en çok bu kadar beklenir (hizmet bekleme önermezse de bu kadar). */
        const val RATE_LIMIT_PAUSE_MS = 20_000L
    }

    private val names = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    /** Cümle içinde çeviriden korunan konuşan adları (#287); yapay zekâya istemde adıyla söylenir. */
    private val speakers = SpeakerNameGuard()
    private var pausedUntil = 0L
    /** Bekleme hizmetin 429 yanıtından mı; öyleyse yerel çeviri olmasa da istek gönderilmez. */
    private var pauseRateLimited = false

    @Volatile var lastError: OnlineKeyState? = null
        private set
    @Volatile var onFailureChanged: ((OnlineKeyState?) -> Unit)? = null

    /** [sentences] cümlelerini aynı sırada çevirir ([game]: oynanan oyun, yapay zekâya bağlam); hata durumunda
     *  [OnlineException] ya da [IOException]. */
    protected abstract fun request(sentences: List<String>, context: C, game: String?, names: List<String>): List<String>

    /** Bu satırdan önce gösterilenler (bağlam); satırı da sonrakilerin bağlamına ekler. */
    protected abstract fun context(text: String, game: String?): C

    protected open fun remember(text: String, translation: String, game: String?) {}

    /** Önbellek anahtarı (DeepL'de sözlük terimi içeren satıra sözlüğün izi girer; yapay zekâda oyun adı). */
    protected open fun cacheKey(text: String, game: String?): String = text

    /** Oynanan oyun (yalnız yapay zekâ kullanır); bilinmiyorsa null. */
    protected open fun game(): String? = null

    /** Hata sonrası hizmetin denenmediği süre. */
    protected open val retryAfterMs: Long get() = RETRY_AFTER_MS

    /** 429 (çok sık istek) sonrası en az bekleme; DeepL Windows ve Mac/iPhone gibi kendi süresini kullanır. */
    protected open val rateLimitPauseMs: Long get() = RATE_LIMIT_PAUSE_MS

    /** Hata sonrası bekleme; 429'da (çok sık istek) en az [rateLimitPauseMs] ve yerel çeviri olmasa da istek gitmez. */
    private fun pauseAfter(error: Exception?) {
        val rateLimited = (error as? OnlineException)?.rateLimited == true
        pausedUntil = clock() + if (rateLimited) maxOf(retryAfterMs, rateLimitPauseMs) else retryAfterMs
        pauseRateLimited = rateLimited
    }

    /** Büyük harfle kalacak ek sözcükler (sözlükteki adlar). */
    protected open val extraNames: Set<String> get() = emptySet()

    /** Konuşan adını öğrenir ("OLD MAN" → "old", "man"); korunacak adlar ayrıca. */
    override fun noteSpeaker(name: String) {
        name.split(' ').filter { it.length >= 2 }.forEach { names.add(it.lowercase(Locale.ROOT)) }
        speakers.learn(name)
        local?.noteSpeaker(name)
    }

    override fun translate(text: String): String {
        // Arama, istek ve kayıt aynı oyunla yapılır; oyun işlem sırasında değişse de sonuç başka oyuna yazılmaz.
        val game = game()
        val context = context(text, game)
        cache.get(cacheKey(text, game))?.let { return it.also { remember(text, it, game) } }
        val pieces = SubtitleSegmenter.split(text)
        for (name in pieces.mapNotNull(SubtitleSegmenter::labelName)) noteSpeaker(name)
        val known = names.toSet() + extraNames
        val translations = pieces.map { if (it.translate) cache.get(cacheKey(it.text, game)) else null }.toMutableList()
        val missing = pieces.indices.filter { pieces[it].translate && translations[it] == null }
        val sources = missing.map { SubtitleSegmenter.normalizeCase(pieces[it].text, known) }
        // Hizmetin beklemesi yalnız eksik çeviriler içindir; önbellekteki parçalar yerel motor istemez. Hata sonrası
        // beklemede yerel çeviri yoksa (indirilmemiş, açılamadı) satır düşmesin: hizmet yine denenir. 429 beklemesi kalır.
        if (sources.isNotEmpty() && clock() < pausedUntil) {
            if (pauseRateLimited) return fallback(text, game)
            tryLocal(text)?.let { remember(text, it, game); return it }
        }
        // Dakikalık hak bittiyse satır sessizce yerel çeviriyle çevrilir (hata değildir). Hak uygulamanın temkinli
        // tahminidir; yerel çeviri yoksa satır denenmeden düşmesin, istek yine gönderilir.
        if (sources.isNotEmpty() && budget?.take() == false) tryLocal(text)?.let { remember(text, it, game); return it }
        val translated = try {
            if (sources.isEmpty()) emptyList()
            else request(sources, context, game, SpeakerNameGuard.occurring(speakers.protected, sources.joinToString("\n"), exact = true))
                .also { report(null) }
        } catch (error: AiRateLimitedException) {
            rateLimited(error.limit)
            return fallback(text, game)
        } catch (error: IOException) {
            report(OnlineKeyState.of(error))
            pauseAfter(error)
            return fallback(text, game)
        } catch (error: JSONException) {
            report(OnlineKeyState.UNREACHABLE)
            pauseAfter(null)
            return fallback(text, game)
        }
        var local = false
        for ((i, index) in missing.withIndex()) {
            val piece = pieces[index].text
            // Model dizide bu cümleyi boş bıraktıysa (bozuk OCR okumasında olabiliyor, #296) yanıt yok sayılır.
            val empty = translated[i].isBlank()
            if (retriesEcho && (empty || isEcho(piece, translated[i]))) {
                val retried = tryLocal(piece)
                if (retried != null && retried.isNotBlank() && !isEcho(piece, retried)) {
                    // Yerel çeviri bu motorun önbelleğine yazılmaz.
                    translations[index] = retried
                    local = true
                    continue
                }
            }
            if (empty) {
                // Yerel çeviri de yoksa cümle olduğu gibi kalır; boş satır gösterilmez, sonuç önbelleğe yazılmaz.
                local = true
                continue
            }
            translations[index] = translated[i]
            cache.store(cacheKey(piece, game), translated[i])
        }
        val result = pieces.indices.joinToString("") { translations[it] ?: pieces[it].text }
        if (!local) cache.store(cacheKey(text, game), result)
        remember(text, result, game)
        return result
    }

    /**
     * Çevirmeden geri verilen cümle yerel motorla yeniden denensin mi (yalnız yapay zekâ; Windows ve iPhone'da da
     * yalnız AiTranslator/AITranslationCore yapar).
     */
    protected open val retriesEcho: Boolean get() = false

    /**
     * Model cümleyi çevirmeden geri verdi mi (hattın "zaten hedef dilde" eşiğiyle aynı). Küçük yerel modeller İngilizce
     * cümleyi sık sık olduğu gibi döndürüyor ("You think I'm on the run?"); hat bunu Türkçe sanıp hiç göstermiyor,
     * önbellek de öyle saklıyordu (#245).
     */
    private fun isEcho(source: String, translation: String) =
        TextMatch.isSimilar(TextMatch.normalize(source), TextMatch.normalize(translation), 0.90)

    /**
     * Cümle cihaz üstü çeviriyle denenir; yerel çeviri yoksa ya da hata verirse null. Geri verilen cümlede o da aynı
     * kalırsa (ad, konsolun Türkçe menüsü) çevrilecek bir şey yoktur ve modelin yanıtı önbelleğe yazılır; hizmet
     * beklerken null dönerse istek yine gönderilir.
     */
    private fun tryLocal(text: String): String? =
        try {
            local?.translate(text)
        } catch (error: InterruptedException) {
            throw error
        } catch (error: Exception) {
            null
        }

    private fun fallback(text: String, game: String?): String =
        (local ?: throw IOException("no local translator")).translate(text).also { remember(text, it, game) }

    /** Toplu çeviride ("ekranı çevir") hizmet şu an dinleniyor mu (son hatadan sonra bir dakika denenmez). */
    protected fun paused(): Boolean = clock() < pausedUntil

    /** Toplu çevirinin tek isteği kullanıcının tuşa basmasıyla gider: hak bitmiş olsa da gönderilir, ama sayılır. */
    protected fun countRequest() {
        budget?.take()
    }

    /** Toplu çeviri hizmetten döndü: hata durumu temizlenir. */
    protected fun succeeded() = report(null)

    /** Toplu çeviri hata verdi: hata bildirilir ve bir dakika hizmet denenmez (dakikalık sınırda uyarısız, kısa). */
    protected fun failed(error: Exception) {
        if (error is AiRateLimitedException) return rateLimited(error.limit)
        report(OnlineKeyState.of(error))
        pauseAfter(error)
    }

    /**
     * Dakikalık sınır: hizmetin önerdiği kadar (en az 1, en çok 20 saniye) beklenir, ana ekranda uyarı çıkmaz; hizmet
     * daha düşük sınır bildirdiyse ona inilir.
     */
    private fun rateLimited(limit: AiRateLimit) {
        limit.requestsPerMinute?.let { budget?.lower(it) }
        pausedUntil = clock() + (limit.retryAfterMs ?: RATE_LIMIT_PAUSE_MS).coerceIn(1_000L, RATE_LIMIT_PAUSE_MS)
        pauseRateLimited = true
    }

    /** Hizmet yanıt vermeyen parçalar yerel motorla çevrilir; yerel motor yoksa hata yukarı çıkar. */
    protected fun localTranslation(text: String): String =
        (local ?: throw IOException("no local translator")).translate(text)

    private fun report(state: OnlineKeyState?) {
        if (lastError == state) return
        lastError = state
        onFailureChanged?.invoke(state)
    }
}

/**
 * Kullanıcının DeepL anahtarıyla çeviri; son 3 satır `context` olarak gider (ücretlendirilmez). Sözlükteki adlar ve
 * terimler etiketle korunur ([DeepLMarkup], iPhone ile aynı).
 */
class DeepLTranslator(
    key: String,
    fallback: TextTranslator?,
    private val http: Http = Http.Default,
    cache: TranslationCache = TranslationCache(),
    private val glossary: Glossary = Glossary.Empty,
    private val playedGame: (() -> String?)? = null,
) : SentenceTranslator<String>(fallback, cache) {
    private val key = key.trim()
    private val recent = ArrayDeque<String>()
    private var recentGame: String? = null
    /** Gerçek bağlantıyla (testlerin sahte [Http]'si değil) çalışırken bağlantıyı sıcak tutan. */
    private val warmer = if (http === Http.Default && this.key.isNotEmpty()) DeepLConnectionWarmer.Shared else null

    init {
        // Oturum başında ısınır, oyun boyunca sıcak kalır.
        warmer?.touch(this.key)
    }

    override val retryAfterMs: Long get() = DeepLTranslator.RETRY_AFTER_MS
    override val rateLimitPauseMs: Long get() = DeepLTranslator.RETRY_AFTER_MS

    override fun translate(text: String): String {
        warmer?.touch(key)
        return super.translate(text)
    }

    override fun game(): String? = playedGame?.invoke()?.trim()

    override fun cacheKey(text: String, game: String?) = DeepLMarkup.cacheKey(text, glossary)
    override val extraNames: Set<String> get() = glossary.capitalWords

    companion object {
        /** Kalıcı önbellek dosyasındaki motor adı (iPhone ile aynı). */
        const val ENGINE_ID = "deepl"
        /** Hata sonrası bu süre DeepL denenmez; 1 dk oyunda çok uzundu (Windows ve Mac/iPhone ile aynı). */
        const val RETRY_AFTER_MS = 15_000L

        /**
         * Yeniden denenecek ağ hatası: bağlantı koptu, sıfırlandı vb. Zaman aşımı ([java.net.SocketTimeoutException]) ve
         * kesinti denenmez; DeepL'in durum kodları (429, 456, 403) [OnlineException] olarak gelir, denenmez.
         */
        fun isDroppedConnection(error: IOException) =
            error !is OnlineException && error !is InterruptedIOException && !Thread.currentThread().isInterrupted

        /** Ücretsiz anahtarlar ":fx" ile biter ve ayrı adrese gider. */
        fun baseUrl(key: String) = if (key.trim().endsWith(":fx")) "https://api-free.deepl.com/v2/" else "https://api.deepl.com/v2/"

        fun body(sentences: List<String>, context: String?, tagged: Boolean = false): String = JSONObject()
            .put("text", JSONArray(sentences))
            .put("source_lang", "EN")
            .put("target_lang", "TR")
            .apply { if (!context.isNullOrEmpty()) put("context", context) }
            // Oyun konuşması: "siz" değil "sen".
            .put("formality", "prefer_less")
            .put("preserve_formatting", true)
            .apply {
                // Etiketli terimler çevrilmez.
                if (tagged) put("tag_handling", "xml").put("ignore_tags", JSONArray().put(DeepLMarkup.TAG))
            }
            .toString()

        fun failure(status: Int) = when (status) {
            401, 403 -> OnlineKeyState.INVALID
            456 -> OnlineKeyState.QUOTA_EXCEEDED
            else -> OnlineKeyState.UNREACHABLE
        }
    }

    override fun context(text: String, game: String?): String = synchronized(recent) {
        if (recentGame != game) {
            recent.clear()
            recentGame = game
        }
        val context = recent.joinToString("\n")
        if (recent.lastOrNull() != text) {
            recent.addLast(text)
            if (recent.size > 3) recent.removeFirst()
        }
        context
    }

    override fun request(sentences: List<String>, context: String, game: String?, names: List<String>): List<String> {
        // Sözlükteki adlar etiketle korunur; etiket varsa istek XML olarak gider, diğer cümleler de kaçırılır.
        val wrapped = sentences.map { DeepLMarkup.wrap(it, glossary) }
        val tagged = wrapped.any { it != null }
        val sources = if (tagged) sentences.indices.map { wrapped[it] ?: DeepLMarkup.escape(sentences[it]) } else sentences
        val send = {
            http.send(
                "POST", baseUrl(key) + "translate",
                mapOf("Authorization" to "DeepL-Auth-Key $key", "Content-Type" to "application/json"), body(sources, context, tagged), 4000,
            )
        }
        val (status, response) = try {
            send()
        } catch (error: IOException) {
            // Açık tutulan bağlantıyı sunucu sessizce kapatmış olabilir: yeni bağlantıyla hemen bir kez daha denenir,
            // yedek çeviriye (ve DeepL'in beklemesine) ancak ikinci hata düşürür.
            if (!isDroppedConnection(error)) throw error
            send()
        }
        if (status !in 200..299) throw OnlineException(failure(status), rateLimited = status == 429)
        val list = JSONObject(response).optJSONArray("translations") ?: throw OnlineException(OnlineKeyState.UNREACHABLE)
        if (list.length() != sentences.size) throw OnlineException(OnlineKeyState.UNREACHABLE)
        val reply = (0 until list.length()).map { list.getJSONObject(it).getString("text") }
        return if (tagged) reply.map(DeepLMarkup::unwrap) else reply
    }
}

/**
 * Ortak DeepL bağlantısını sıcak tutar (Windows: DeepLTranslator.KeepWarm, Mac/iPhone: DeepLConnectionWarmer): oturum
 * başında ve son çeviriden sonraki [KEEP_WARM_FOR_MS] boyunca her [KEEP_WARM_EVERY_MS]'de bir kullanım sorgusu
 * (`/v2/usage`; karakter kotasından yemez) gönderir. Boşta kalan bağlantı sunucuda genelde 60 sn'de kapanıyor,
 * sessizlikten sonraki ilk satır yeni TLS el sıkışmasını bekliyordu. Süre dolunca durur, sonraki çeviride yeniden başlar.
 */
class DeepLConnectionWarmer(
    private val clock: () -> Long = System::currentTimeMillis,
    private val scheduler: ScheduledExecutorService? = null,
    private val ping: (String) -> Unit,
) {
    companion object {
        const val KEEP_WARM_EVERY_MS = 40_000L
        const val KEEP_WARM_FOR_MS = 10 * 60_000L

        val Shared: DeepLConnectionWarmer by lazy {
            val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
                Thread(runnable, "deepl-keep-warm").apply { isDaemon = true }
            }
            DeepLConnectionWarmer(scheduler = executor) { key -> KeyCheck.deepL(key) }
        }
    }

    private var key = ""
    private var lastUsed = Long.MIN_VALUE / 2
    private var task: ScheduledFuture<*>? = null

    /** Anahtarı ve son kullanım anını yazar; sıcak tutma durmuşsa yeniden başlatır. */
    @Synchronized
    fun touch(key: String) {
        if (key.isBlank()) return
        this.key = key
        lastUsed = clock()
        if (task == null) task = scheduler?.scheduleWithFixedDelay({ tick() }, 0, KEEP_WARM_EVERY_MS, TimeUnit.MILLISECONDS)
    }

    /** Şimdi sorgu gönderilecek anahtar; son çeviriden bu yana [KEEP_WARM_FOR_MS] geçtiyse null (döngü durur). */
    @Synchronized
    fun nextPing(): String? {
        if (clock() - lastUsed > KEEP_WARM_FOR_MS || key.isEmpty()) {
            task?.cancel(false)
            task = null
            return null
        }
        return key
    }

    private fun tick() {
        val key = nextPing() ?: return
        try {
            ping(key)
        } catch (_: Exception) {
            // Sıcak tutma sessizdir: hata ana ekrana çıkmaz, sonraki turda yine denenir.
        }
    }
}

/** Hizmete giden istek: adres, başlıklar ve gövde (Windows: AiRequest.Build, aynı biçim). */
data class AiHttpRequest(val url: String, val headers: Map<String, String>, val body: String)

object AiRequest {
    const val MAX_OUTPUT_TOKENS = 1024
    /** "Ekranı çevir"in tek isteğinde çıktı sınırı: ekrandaki bütün yazılar birlikte döner (Mac/iPhone ile aynı). */
    const val SCREEN_OUTPUT_TOKENS = 8192

    const val SYSTEM_PROMPT =
        "You translate English video game subtitles into natural, spoken Turkish, the way people really talk. " +
            "Characters address each other informally (use \"sen\", not \"siz\") unless the line is clearly formal. " +
            "Keep character names, place names and speaker labels such as \"ATREUS:\" exactly as they are. " +
            "Keep line breaks. Keep the meaning and tone; do not add or leave out anything. " +
            // #296: OCR kaçan/yanlış harfler ve önceki altyazının devamı olan satırlar.
            "The text is read from the screen by OCR and may have misread or missing letters (\"Y u ave to ask?\", " +
            "\"Doesn't 00k good.\"); translate the line the speaker clearly meant. " +
            "A subtitle may continue the previous one (it starts in lowercase or with a word like \"and\"); " +
            "translate it so that it reads as that continuation. " +
            "Reply with only the translation, no explanations, notes or quotes."

    /** Kullanıcının ek talimatında en çok bu kadar karakter gider (fazlası kesilir). */
    const val MAX_INSTRUCTION_LENGTH = 1000

    /** Ayarlardaki "Ek talimat": baştaki/sondaki boşluk atılır, sınırdan uzunsa kesilir; boşsa null. */
    fun instruction(text: String?): String? {
        var trimmed = text?.trim().orEmpty()
        if (trimmed.length > MAX_INSTRUCTION_LENGTH) trimmed = trimmed.take(MAX_INSTRUCTION_LENGTH).trimEnd()
        return trimmed.ifEmpty { null }
    }

    /** Sistem talimatı: kullanıcının ek talimatı varsa sona eklenir (#306); boşsa [SYSTEM_PROMPT] olduğu gibi gider. */
    fun systemPrompt(instruction: String?): String =
        AiRequest.instruction(instruction)?.let { "$SYSTEM_PROMPT\n\n$it" } ?: SYSTEM_PROMPT

    /**
     * Ek talimatın önbellek etiketi: talimat değişince eski çeviriler dönmesin diye anahtarın başına girer. Talimat yoksa
     * null; o zaman anahtar eskisi gibidir ve önceki çeviriler geçerli kalır (iPhone, Mac ve Windows ile aynı).
     */
    fun instructionTag(instruction: String?): String? = AiRequest.instruction(instruction)?.let { extra ->
        MessageDigest.getInstance("SHA-256").digest(extra.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }.take(16)
    }

    /** Bağlam satırı: daha önce gösterilmiş İngilizce ve (biliniyorsa) Türkçesi. */
    data class ContextLine(val source: String, val translation: String? = null)

    /**
     * Kullanıcı iletisi: önceki satırlar (yalnız bağlam) ve çevrilecek cümleler. [names]: konuşan etiketlerinden öğrenilip
     * cümlelerde geçen adlar; model "Price"ı "Fiyat" diye çevirmesin diye adıyla söylenir (#287).
     */
    fun userMessage(sentences: List<String>, context: List<ContextLine>, game: String? = null, names: List<String> = emptyList()): String {
        val parts = mutableListOf<String>()
        if (!game.isNullOrEmpty()) parts.add("Game: $game")
        if (names.isNotEmpty()) parts.add("Character names (keep them exactly as written, do not translate them): ${names.joinToString(", ")}")
        if (context.isNotEmpty()) {
            val lines = mutableListOf("Previous subtitles, for context only (do not translate them again):")
            for (line in context) {
                lines.add("English: ${line.source}")
                line.translation?.let { lines.add("Turkish: $it") }
            }
            parts.add(lines.joinToString("\n"))
        }
        val list = JSONArray(sentences).toString()
        parts.add("Translate each string in this JSON array into Turkish. Reply with only a JSON array of ${sentences.size} " +
            "Turkish strings in the same order.\n$list")
        return parts.joinToString("\n\n")
    }

    fun build(
        provider: AiProvider, key: String, model: AiModel, sentences: List<String>, context: List<ContextLine>,
        maxOutputTokens: Int = MAX_OUTPUT_TOKENS, game: String? = null, names: List<String> = emptyList(),
        // Ayarlardaki "Ek talimat"; sistem talimatının sonuna eklenir, boşsa hiçbir şey değişmez.
        instruction: String? = null,
    ): AiHttpRequest {
        val trimmed = key.trim()
        val user = userMessage(sentences, context, game, names)
        val system = systemPrompt(instruction)
        return when (provider) {
            AiProvider.GEMINI -> {
                val config = JSONObject().put("maxOutputTokens", maxOutputTokens)
                model.thinking?.let { config.put("thinkingConfig", JSONObject().put("thinkingLevel", it)) }
                val body = JSONObject()
                    .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", system))))
                    .put("contents", JSONArray().put(JSONObject().put("role", "user").put("parts", JSONArray().put(JSONObject().put("text", user)))))
                    .put("generationConfig", config)
                AiHttpRequest(
                    "https://generativelanguage.googleapis.com/v1beta/models/${URLEncoder.encode(model.id, "UTF-8")}:generateContent",
                    mapOf("x-goog-api-key" to trimmed, "Content-Type" to "application/json"), body.toString(),
                )
            }
            AiProvider.OPENAI -> {
                val body = JSONObject()
                    .put("model", model.id)
                    .put("messages", JSONArray()
                        .put(JSONObject().put("role", "developer").put("content", system))
                        .put(JSONObject().put("role", "user").put("content", user)))
                    .put("max_completion_tokens", maxOutputTokens)
                model.effort?.let { body.put("reasoning_effort", it) }
                AiHttpRequest("https://api.openai.com/v1/chat/completions",
                    mapOf("Authorization" to "Bearer $trimmed", "Content-Type" to "application/json"), body.toString())
            }
            AiProvider.CLAUDE -> {
                val body = JSONObject()
                    .put("model", model.id)
                    .put("max_tokens", maxOutputTokens)
                    .put("system", system)
                    .put("messages", JSONArray().put(JSONObject().put("role", "user").put("content", user)))
                model.effort?.let { body.put("output_config", JSONObject().put("effort", it)) }
                model.thinking?.let { body.put("thinking", JSONObject().put("type", it)) }
                AiHttpRequest("https://api.anthropic.com/v1/messages",
                    mapOf("x-api-key" to trimmed, "anthropic-version" to "2023-06-01", "Content-Type" to "application/json"), body.toString())
            }
        }
    }

    /** Yanıttaki düz metin (düşünme bölümleri atlanır). */
    fun text(provider: AiProvider, json: String): String {
        val root = try {
            JSONObject(json)
        } catch (error: JSONException) {
            throw OnlineException(OnlineKeyState.UNREACHABLE)
        }
        val text = when (provider) {
            AiProvider.GEMINI -> root.optJSONArray("candidates")?.optJSONObject(0)?.optJSONObject("content")?.optJSONArray("parts")
                ?.let { parts -> (0 until parts.length()).mapNotNull { parts.optJSONObject(it) }.filter { !it.optBoolean("thought", false) }
                    .joinToString("") { it.optString("text") } }
            AiProvider.OPENAI -> root.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("message")?.optString("content")
            AiProvider.CLAUDE -> root.optJSONArray("content")?.let { blocks ->
                (0 until blocks.length()).mapNotNull { blocks.optJSONObject(it) }.filter { it.optString("type") == "text" }
                    .joinToString("") { it.optString("text") }
            }
        }
        if (text.isNullOrBlank()) throw OnlineException(OnlineKeyState.UNREACHABLE)
        return text
    }

    /** Yanıttaki JSON dizisi; tek cümlede model diziyi unutup düz metin dönerse o metin alınır. */
    fun translations(text: String, count: Int): List<String> {
        var trimmed = text.trim()
        // Düşünen modeller yanıtın başına <think>…</think> koyar; yalnız sonrası alınır.
        val thought = trimmed.lastIndexOf("</think>")
        if (thought >= 0) trimmed = trimmed.substring(thought + "</think>".length).trim()
        trimmed = stripControlTokens(trimmed)
        if (trimmed.startsWith("```")) trimmed = trimmed.split('\n').drop(1).filter { !it.startsWith("```") }.joinToString("\n").trim()
        val start = trimmed.indexOf('[')
        val end = trimmed.lastIndexOf(']')
        // org.json tırnaksız öğeleri de kabul eder ("[gülüyor]" → "gülüyor", "[Evet, efendim.]" → iki öğe); yalnız
        // ilk öğesi tırnaklı (ya da boş) dizi JSON sayılır, gerisi tırnaksız dizi kuralıyla okunur.
        val quoted = start >= 0 && trimmed.substring(start + 1).trimStart().let { it.startsWith('"') || it.startsWith(']') }
        if (quoted && end > start) {
            try {
                val array = JSONArray(withoutTrailingComma(trimmed.substring(start, end + 1)))
                if ((0 until array.length()).all { array.opt(it) is String }) {
                    if (array.length() != count) throw OnlineException(OnlineKeyState.UNREACHABLE)
                    return (0 until array.length()).map { array.getString(it).trim() }
                }
            } catch (error: JSONException) {
                // Dizi değil; düz metin olabilir.
            }
        }
        unquotedList(trimmed, count)?.let { return it }
        if (count != 1) throw OnlineException(OnlineKeyState.UNREACHABLE)
        return listOf(trimmed.trim('"', '“', '”'))
    }

    private val controlTokens = Regex("""</?s>|<\|[A-Za-z0-9_]{1,32}\|>|</?(?:start|end)_of_turn>|</?(?:eos|bos|pad)>""")
    private val trailingComma = Regex(""",\s*]$""")

    /**
     * Yerel modellerin metne sızan bitiş/rol işaretleri (`</s>`, `<|im_end|>`, `<|eot_id|>`, `<end_of_turn>` …) ekranda
     * görünmesin; yalnız bu kalıplar silinir, altyazıdaki başka yazılara dokunulmaz.
     */
    fun stripControlTokens(text: String): String = controlTokens.replace(text, "").trim()

    /** `["Bir.", "İki.",]` gibi sondaki fazla virgül JSON'u bozmasın. */
    fun withoutTrailingComma(text: String): String = trailingComma.replace(text, "]")

    /**
     * Tırnaksız dizi: bazı modeller JSON istense de `[Hareket etmemiz lazım.]` ya da `[Satır bir., Satır iki.]` döndürür.
     * Yalnız bütün yanıt köşeli parantez içindeyse ve öğe sayısı tam tutuyorsa alınır; tutmazsa null (her zamanki geri
     * dönüş). Cümle içi virgülde yanlış bölmemek için sıra: satır sonu, cümle sonu işaretinden (. ! ? … ") sonra gelen
     * virgül, en son düz virgül (Mac ve Windows ile aynı).
     */
    internal fun unquotedList(text: String, count: Int): List<String>? {
        if (count < 1 || text.length < 2 || !text.startsWith('[') || !text.endsWith(']')) return null
        val inner = text.substring(1, text.length - 1)
        fun clean(item: String): String = item.trim().removeSuffix(",").trim().trim('"', '“', '”').trim()
        val candidates = if (count == 1) listOf(listOf(inner)) else listOf(
            inner.split('\n').filter { it.isNotBlank() },
            sentenceSplit(inner),
            inner.split(','),
        )
        for (parts in candidates) {
            val items = parts.map(::clean)
            if (items.size == count && items.none { it.isEmpty() }) return items
        }
        return null
    }

    /** Cümle sonu işaretinden (. ! ? … " ”) hemen sonra gelen virgüllerden böler; işaret öğede kalır. */
    private fun sentenceSplit(text: String): List<String> {
        val parts = mutableListOf<String>()
        var start = 0
        var last: Char? = null
        for (i in text.indices) {
            val c = text[i]
            if (c == ',' && last != null && last in ".!?…\"”") {
                parts.add(text.substring(start, i))
                start = i + 1
            }
            if (!c.isWhitespace()) last = c
        }
        parts.add(text.substring(start))
        return parts
    }

    /**
     * 429 yalnız dakikalık sınırdan geldiyse onun ayrıntısı; gün sınırı, bakiye ya da tanınmayan 429 için null (bunlar
     * QUOTA_EXCEEDED olarak kullanıcıya gösterilir). Gemini'nin hata gövdesinde error.details[] içinde
     * google.rpc.QuotaFailure (violations[].quotaId, ör. "GenerateRequestsPerMinutePerProjectPerModel-FreeTier",
     * quotaValue "15") ve google.rpc.RetryInfo (retryDelay "37s") bulunur (Windows ve iPhone ile aynı).
     */
    fun rateLimit(status: Int, body: String): AiRateLimit? {
        if (status != 429) return null
        val details = try {
            JSONObject(body).optJSONObject("error")?.optJSONArray("details")
        } catch (error: JSONException) {
            null
        } ?: return null
        val items = (0 until details.length()).mapNotNull { details.optJSONObject(it) }
        val violations = items.flatMap { item ->
            item.optJSONArray("violations")?.let { array -> (0 until array.length()).mapNotNull { array.optJSONObject(it) } }
                ?: emptyList()
        }
        val ids = violations.mapNotNull { it.opt("quotaId") as? String }
        // Günlük sınır doldu: dakikalık beklemeyle geçmez, kullanıcı bilmeli.
        if (ids.any { "PerDay" in it } || ids.none { "PerMinute" in it }) return null
        val retry = items.firstNotNullOfOrNull { it.opt("retryDelay") as? String }
            ?.trimEnd('s')?.toDoubleOrNull()?.let { (it * 1000).toLong() }
        // İstek sınırı (token sınırı değil).
        val requests = violations.firstOrNull { (it.opt("quotaId") as? String)?.contains("Requests") == true }
        val perMinute = when (val value = requests?.opt("quotaValue")) {
            is String -> value.toIntOrNull()
            is Number -> value.toInt()
            else -> null
        }?.takeIf { it > 0 }
        return AiRateLimit(retry, perMinute)
    }

    /** Başarısız yanıtın hatası: dakikalık sınırsa [AiRateLimitedException], değilse [OnlineException]. */
    fun error(status: Int, body: String): IOException =
        rateLimit(status, body)?.let(::AiRateLimitedException) ?: OnlineException(failure(status, body))

    fun failure(status: Int, body: String): OnlineKeyState {
        val message = body.lowercase(Locale.ROOT)
        return when {
            status == 401 || status == 403 -> OnlineKeyState.INVALID
            status == 402 || status == 429 -> OnlineKeyState.QUOTA_EXCEEDED
            status == 400 && ("api_key_invalid" in message || "api key not valid" in message) -> OnlineKeyState.INVALID
            status == 400 && ("credit balance" in message || "insufficient_quota" in message) -> OnlineKeyState.QUOTA_EXCEEDED
            status == 400 || status == 404 -> OnlineKeyState.MODEL_REJECTED
            // Hizmete ulaşıldı ama şu an yoğun ya da arızalı (Gemini 503 "overloaded", Claude 529); internet çalışıyor.
            status == 408 || status in 500..599 -> OnlineKeyState.BUSY
            else -> OnlineKeyState.UNREACHABLE
        }
    }
}

/** Kullanıcının Gemini, OpenAI ya da Claude anahtarıyla çeviri; son 3 satır ve çevirileri bağlam olarak gider. */
class AiTranslator(
    private val provider: AiProvider,
    key: String,
    private val model: AiModel,
    fallback: TextTranslator?,
    private val http: Http = Http.Default,
    cache: TranslationCache = TranslationCache(),
    private val playedGame: (() -> String?)? = null,
    clock: () -> Long = System::currentTimeMillis,
    // Dakikalık istek hakkı; null ise modelin uygulama genelindeki ortak hakkı (Google sınırı proje ve model başına
    // sayar; çeviri hattı yeniden kurulsa da hak sıfırlanmaz). Modelin sınırı yoksa hak da yoktur.
    budget: RequestBudget? = null,
    // Ayarlardaki "Ek talimat" (#306): sistem talimatının sonuna eklenir; boşsa hiçbir şey değişmez. Her istekte
    // sorulur: Ayarlar'da değişince çalışan çeviri hattı yeni talimatı hemen kullanır (iPhone ile aynı).
    private val instruction: (() -> String?)? = null,
) : SentenceTranslator<List<AiRequest.ContextLine>>(fallback, cache, clock, budget ?: RequestBudget.shared(provider, model)) {
    companion object {
        /** Kalıcı önbellek dosyasındaki motor adı (iPhone ile aynı: "gemini:<model>"). */
        fun engineId(provider: AiProvider, model: AiModel) = "${provider.id}:${model.id}"

        /** "Ekranı çevir"de bir istekte giden en çok parça; kalabalık ekran birkaç isteğe bölünür (iPhone ile aynı). */
        const val SCREEN_BATCH = 40
        /** "Ekranı çevir"de beklenen en uzun süre: bütün ekranın çevirisi tek yanıtta gelir. */
        const val SCREEN_TIMEOUT_MS = 30_000
    }

    override val translatesTogether: Boolean get() = true

    override val retriesEcho: Boolean get() = true

    /**
     * "Ekranı çevir": birbirinden bağımsız parçalar (menü satırı, görev yazısı...) tek istekte, aynı sırada çevrilir
     * (parça başına istek dakikalık hakkı bitirirdi; Mac/iPhone AITranslationCore.translateAll ile aynı). Önbellekteki
     * parçalar gönderilmez. Hata olursa kalan parçalar yerel motorla çevrilir; o da yoksa hata yukarı çıkar.
     */
    override fun translateAll(texts: List<String>): List<String> {
        val game = game()
        val results = texts.map { cache.get(cacheKey(it, game)) }.toMutableList()
        val missing = texts.indices.filter { results[it] == null }
        var stopped = paused()
        for (chunk in missing.chunked(SCREEN_BATCH)) {
            if (stopped) break
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            val sentences = chunk.map { texts[it] }
            countRequest()
            try {
                val request = AiRequest.build(provider, key, model, sentences, emptyList(), AiRequest.SCREEN_OUTPUT_TOKENS, game,
                    instruction = scope.instruction)
                val (status, body) = http.send("POST", request.url, request.headers, request.body, SCREEN_TIMEOUT_MS)
                if (status !in 200..299) throw AiRequest.error(status, body)
                val translated = AiRequest.translations(AiRequest.text(provider, body), sentences.size)
                succeeded()
                for ((index, translation) in chunk.zip(translated)) {
                    results[index] = translation
                    cache.store(cacheKey(texts[index], game), translation)
                }
            } catch (error: IOException) {
                failed(error)
                stopped = true
            } catch (error: org.json.JSONException) {
                failed(error)
                stopped = true
            }
        }
        return texts.indices.map { results[it] ?: localTranslation(texts[it]) }
    }

    private val key = key.trim()

    /** Geçerli ek talimat ve önbellek etiketi; etiket yalnız talimat değişince yeniden hesaplanır. */
    private class InstructionScope(val instruction: String?, val tag: String?)
    @Volatile private var lastScope = InstructionScope(null, null)
    private val scope: InstructionScope
        get() {
            val current = AiRequest.instruction(instruction?.invoke())
            val last = lastScope
            if (last.instruction == current) return last
            return InstructionScope(current, AiRequest.instructionTag(current)).also { lastScope = it }
        }
    private val recent = ArrayDeque<AiRequest.ContextLine>()
    private var recentGame: String? = null

    override fun context(text: String, game: String?): List<AiRequest.ContextLine> = synchronized(recent) {
        if (recentGame != game) {
            recent.clear()
            recentGame = game
        }
        val context = recent.toList()
        if (recent.lastOrNull()?.source != text) {
            recent.addLast(AiRequest.ContextLine(text))
            if (recent.size > 3) recent.removeFirst()
        }
        context
    }

    /** Gösterilen satırın çevirisi sonraki satırların bağlamına girer. */
    override fun remember(text: String, translation: String, game: String?) {
        synchronized(recent) {
            if (recentGame != game) return
            val index = recent.indexOfLast { it.source == text }
            if (index >= 0) recent[index] = recent[index].copy(translation = translation)
        }
    }

    override fun game(): String? = playedGame?.invoke()?.trim()

    /**
     * Oyun bilinmiyorsa eski kayıtlar geçerlidir; biliniyorsa yalnız o oyunun sonucu kullanılır (Windows ve Mac ile aynı).
     * Ek talimat varsa anahtar onun etiketiyle başlar: talimat değişince eski çeviriler dönmez.
     */
    override fun cacheKey(text: String, game: String?): String {
        val key = if (game.isNullOrEmpty()) text else "$game\u001f$text"
        return scope.tag?.let { "i:$it\u001f$key" } ?: key
    }

    override fun request(sentences: List<String>, context: List<AiRequest.ContextLine>, game: String?, names: List<String>): List<String> {
        val request = AiRequest.build(provider, key, model, sentences, context, game = game, names = names, instruction = scope.instruction)
        val (status, body) = http.send("POST", request.url, request.headers, request.body, 5000)
        if (status !in 200..299) throw AiRequest.error(status, body)
        return AiRequest.translations(AiRequest.text(provider, body), sentences.size)
    }
}
