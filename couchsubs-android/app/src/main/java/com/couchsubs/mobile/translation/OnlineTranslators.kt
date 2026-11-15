// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.translation

import com.couchsubs.mobile.core.SubtitleSegmenter
import com.couchsubs.mobile.core.TextTranslator
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.Locale

/** Çevrimiçi anahtarın durumu (ayarlardaki "Dene" ve ana ekrandaki uyarı için). */
enum class OnlineKeyState { VALID, INVALID, QUOTA_EXCEEDED, MODEL_REJECTED, UNREACHABLE }

class OnlineException(val state: OnlineKeyState) : IOException("online translation failed: $state")

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
        state == OnlineKeyState.VALID || state == OnlineKeyState.QUOTA_EXCEEDED || state == OnlineKeyState.MODEL_REJECTED

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
            if (status !in 200..299) return AiRequest.failure(status, body)
            AiRequest.translations(AiRequest.text(provider, body), 1)
            OnlineKeyState.VALID
        } catch (error: OnlineException) {
            error.state
        } catch (error: IOException) {
            OnlineKeyState.UNREACHABLE
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
 * dakika hizmet denenmez.
 */
abstract class SentenceTranslator<C>(
    private val local: TextTranslator?,
    protected val cache: TranslationCache = TranslationCache(),
    private val clock: () -> Long = System::currentTimeMillis,
) : TextTranslator {
    private val names = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private var pausedUntil = 0L

    @Volatile var lastError: OnlineKeyState? = null
        private set
    @Volatile var onFailureChanged: ((OnlineKeyState?) -> Unit)? = null

    /** [sentences] cümlelerini aynı sırada çevirir; hata durumunda [OnlineException] ya da [IOException]. */
    protected abstract fun request(sentences: List<String>, context: C): List<String>

    /** Bu satırdan önce gösterilenler (bağlam); satırı da sonrakilerin bağlamına ekler. */
    protected abstract fun context(text: String): C

    protected open fun remember(text: String, translation: String) {}

    /** Önbellek anahtarı (DeepL'de sözlük terimi içeren satıra sözlüğün izi girer). */
    protected open fun cacheKey(text: String): String = text

    /** Büyük harfle kalacak ek sözcükler (sözlükteki adlar). */
    protected open val extraNames: Set<String> get() = emptySet()

    override fun translate(text: String): String {
        val context = context(text)
        cache.get(cacheKey(text))?.let { return it.also { remember(text, it) } }
        if (clock() < pausedUntil) return fallback(text)
        val pieces = SubtitleSegmenter.split(text)
        for (name in pieces.mapNotNull(SubtitleSegmenter::labelName))
            name.split(' ').filter { it.length >= 2 }.forEach { names.add(it.lowercase(Locale.ROOT)) }
        val known = names.toSet() + extraNames
        val translations = pieces.map { if (it.translate) cache.get(cacheKey(it.text)) else null }.toMutableList()
        val missing = pieces.indices.filter { pieces[it].translate && translations[it] == null }
        val sources = missing.map { SubtitleSegmenter.normalizeCase(pieces[it].text, known) }
        val translated = try {
            if (sources.isEmpty()) emptyList() else request(sources, context).also { report(null) }
        } catch (error: IOException) {
            report((error as? OnlineException)?.state ?: OnlineKeyState.UNREACHABLE)
            pausedUntil = clock() + 60_000
            return fallback(text)
        } catch (error: JSONException) {
            report(OnlineKeyState.UNREACHABLE)
            pausedUntil = clock() + 60_000
            return fallback(text)
        }
        for ((i, index) in missing.withIndex()) {
            translations[index] = translated[i]
            cache.store(cacheKey(pieces[index].text), translated[i])
        }
        val result = pieces.indices.joinToString("") { translations[it] ?: pieces[it].text }
        cache.store(cacheKey(text), result)
        remember(text, result)
        return result
    }

    private fun fallback(text: String): String =
        (local ?: throw IOException("no local translator")).translate(text).also { remember(text, it) }

    /** Toplu çeviride ("ekranı çevir") hizmet şu an dinleniyor mu (son hatadan sonra bir dakika denenmez). */
    protected fun paused(): Boolean = clock() < pausedUntil

    /** Toplu çeviri hizmetten döndü: hata durumu temizlenir. */
    protected fun succeeded() = report(null)

    /** Toplu çeviri hata verdi: hata bildirilir ve bir dakika hizmet denenmez. */
    protected fun failed(error: Exception) {
        report((error as? OnlineException)?.state ?: OnlineKeyState.UNREACHABLE)
        pausedUntil = clock() + 60_000
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
) : SentenceTranslator<String>(fallback, cache) {
    private val key = key.trim()
    private val recent = ArrayDeque<String>()

    override fun cacheKey(text: String) = DeepLMarkup.cacheKey(text, glossary)
    override val extraNames: Set<String> get() = glossary.capitalWords

    companion object {
        /** Kalıcı önbellek dosyasındaki motor adı (iPhone ile aynı). */
        const val ENGINE_ID = "deepl"

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

    override fun context(text: String): String = synchronized(recent) {
        val context = recent.joinToString("\n")
        if (recent.lastOrNull() != text) {
            recent.addLast(text)
            if (recent.size > 3) recent.removeFirst()
        }
        context
    }

    override fun request(sentences: List<String>, context: String): List<String> {
        // Sözlükteki adlar etiketle korunur; etiket varsa istek XML olarak gider, diğer cümleler de kaçırılır.
        val wrapped = sentences.map { DeepLMarkup.wrap(it, glossary) }
        val tagged = wrapped.any { it != null }
        val sources = if (tagged) sentences.indices.map { wrapped[it] ?: DeepLMarkup.escape(sentences[it]) } else sentences
        val (status, response) = http.send(
            "POST", baseUrl(key) + "translate",
            mapOf("Authorization" to "DeepL-Auth-Key $key", "Content-Type" to "application/json"), body(sources, context, tagged), 4000,
        )
        if (status !in 200..299) throw OnlineException(failure(status))
        val list = JSONObject(response).optJSONArray("translations") ?: throw OnlineException(OnlineKeyState.UNREACHABLE)
        if (list.length() != sentences.size) throw OnlineException(OnlineKeyState.UNREACHABLE)
        val reply = (0 until list.length()).map { list.getJSONObject(it).getString("text") }
        return if (tagged) reply.map(DeepLMarkup::unwrap) else reply
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
            "Reply with only the translation, no explanations, notes or quotes."

    /** Bağlam satırı: daha önce gösterilmiş İngilizce ve (biliniyorsa) Türkçesi. */
    data class ContextLine(val source: String, val translation: String? = null)

    fun userMessage(sentences: List<String>, context: List<ContextLine>, game: String? = null): String {
        val parts = mutableListOf<String>()
        if (!game.isNullOrEmpty()) parts.add("Game: $game")
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
        maxOutputTokens: Int = MAX_OUTPUT_TOKENS,
    ): AiHttpRequest {
        val trimmed = key.trim()
        val user = userMessage(sentences, context)
        return when (provider) {
            AiProvider.GEMINI -> {
                val config = JSONObject().put("maxOutputTokens", maxOutputTokens)
                model.thinking?.let { config.put("thinkingConfig", JSONObject().put("thinkingLevel", it)) }
                val body = JSONObject()
                    .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", SYSTEM_PROMPT))))
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
                        .put(JSONObject().put("role", "developer").put("content", SYSTEM_PROMPT))
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
                    .put("system", SYSTEM_PROMPT)
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
        if (trimmed.startsWith("```")) trimmed = trimmed.split('\n').drop(1).filter { !it.startsWith("```") }.joinToString("\n").trim()
        val start = trimmed.indexOf('[')
        val end = trimmed.lastIndexOf(']')
        // org.json tırnaksız öğeleri de kabul eder ("[gülüyor]" → "gülüyor", "[Evet, efendim.]" → iki öğe); yalnız
        // ilk öğesi tırnaklı (ya da boş) dizi JSON sayılır, gerisi tırnaksız dizi kuralıyla okunur.
        val quoted = start >= 0 && trimmed.substring(start + 1).trimStart().let { it.startsWith('"') || it.startsWith(']') }
        if (quoted && end > start) {
            try {
                val array = JSONArray(trimmed.substring(start, end + 1))
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

    fun failure(status: Int, body: String): OnlineKeyState {
        val message = body.lowercase(Locale.ROOT)
        return when {
            status == 401 || status == 403 -> OnlineKeyState.INVALID
            status == 402 || status == 429 -> OnlineKeyState.QUOTA_EXCEEDED
            status == 400 && ("api_key_invalid" in message || "api key not valid" in message) -> OnlineKeyState.INVALID
            status == 400 && ("credit balance" in message || "insufficient_quota" in message) -> OnlineKeyState.QUOTA_EXCEEDED
            status == 400 || status == 404 -> OnlineKeyState.MODEL_REJECTED
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
) : SentenceTranslator<List<AiRequest.ContextLine>>(fallback, cache) {
    companion object {
        /** Kalıcı önbellek dosyasındaki motor adı (iPhone ile aynı: "gemini:<model>"). */
        fun engineId(provider: AiProvider, model: AiModel) = "${provider.id}:${model.id}"

        /** "Ekranı çevir"de bir istekte giden en çok parça; kalabalık ekran birkaç isteğe bölünür (iPhone ile aynı). */
        const val SCREEN_BATCH = 40
        /** "Ekranı çevir"de beklenen en uzun süre: bütün ekranın çevirisi tek yanıtta gelir. */
        const val SCREEN_TIMEOUT_MS = 30_000
    }

    override val translatesTogether: Boolean get() = true

    /**
     * "Ekranı çevir": birbirinden bağımsız parçalar (menü satırı, görev yazısı...) tek istekte, aynı sırada çevrilir
     * (parça başına istek dakikalık hakkı bitirirdi; Mac/iPhone AITranslationCore.translateAll ile aynı). Önbellekteki
     * parçalar gönderilmez. Hata olursa kalan parçalar yerel motorla çevrilir; o da yoksa hata yukarı çıkar.
     */
    override fun translateAll(texts: List<String>): List<String> {
        val results = texts.map { cache.get(it) }.toMutableList()
        val missing = texts.indices.filter { results[it] == null }
        var stopped = paused()
        for (chunk in missing.chunked(SCREEN_BATCH)) {
            if (stopped) break
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            val sentences = chunk.map { texts[it] }
            try {
                val request = AiRequest.build(provider, key, model, sentences, emptyList(), AiRequest.SCREEN_OUTPUT_TOKENS)
                val (status, body) = http.send("POST", request.url, request.headers, request.body, SCREEN_TIMEOUT_MS)
                if (status !in 200..299) throw OnlineException(AiRequest.failure(status, body))
                val translated = AiRequest.translations(AiRequest.text(provider, body), sentences.size)
                succeeded()
                for ((index, translation) in chunk.zip(translated)) {
                    results[index] = translation
                    cache.store(texts[index], translation)
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
    private val recent = ArrayDeque<AiRequest.ContextLine>()

    override fun context(text: String): List<AiRequest.ContextLine> = synchronized(recent) {
        val context = recent.toList()
        if (recent.lastOrNull()?.source != text) {
            recent.addLast(AiRequest.ContextLine(text))
            if (recent.size > 3) recent.removeFirst()
        }
        context
    }

    /** Gösterilen satırın çevirisi sonraki satırların bağlamına girer. */
    override fun remember(text: String, translation: String) {
        synchronized(recent) {
            val index = recent.indexOfLast { it.source == text }
            if (index >= 0) recent[index] = recent[index].copy(translation = translation)
        }
    }

    override fun request(sentences: List<String>, context: List<AiRequest.ContextLine>): List<String> {
        val request = AiRequest.build(provider, key, model, sentences, context)
        val (status, body) = http.send("POST", request.url, request.headers, request.body, 5000)
        if (status !in 200..299) throw OnlineException(AiRequest.failure(status, body))
        return AiRequest.translations(AiRequest.text(provider, body), sentences.size)
    }
}
