// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/**
 * Ortak havuz (varsayılan açık, ayarlardan kapatılabilir): hiçbir pakette bulunmayan İngilizce oyun satırları biriktirilir
 * ve beş dakikada bir (ve okuma dururken) sunucuya gönderilir; yeni paketler bunlardan hazırlanır. Yalnız satırın metni,
 * anahtarı ve ilk görüldüğü an gider; kimlik olarak kuruluma özgü rastgele bir UUID kullanılır. Mac ve Windows'taki
 * LinePool ile aynı kurallar ve aynı sunucu.
 */
class LinePool(
    private val file: File,
    private val app: String,
    private val endpoint: URL = URL(DEFAULT_ENDPOINT),
    private val platform: String = "android",
    enabled: Boolean = ENABLED_BY_DEFAULT,
    private val clock: () -> Long = System::currentTimeMillis,
    /** HTTP katmanı (gövde → durum kodu ve Retry-After saniyesi); testlerde sahtesi verilir. */
    private val post: ((URL, String) -> Pair<Int, Long?>)? = null,
) {
    companion object {
        const val ENABLED_BY_DEFAULT = true
        const val DEFAULT_ENDPOINT = "https://couchsubs-pool.enmera.workers.dev/v1/lines"
        const val BATCH_SIZE = 200
        const val MAX_QUEUE = 5000
        const val MAX_LENGTH = 300
        const val MIN_WORDS = 2
        const val FLUSH_INTERVAL_MS = 5 * 60 * 1000L
        private const val REMEMBERED_SENT = 20000
        private const val SAVE_INTERVAL_MS = 30_000L

        /** Havuza uygun satır: en az iki sözcük, en çok 300 karakter, arayüz ya da yazı tanıma çöpü gibi görünmüyor. */
        fun accepts(raw: String): Boolean {
            val text = raw.trim()
            if (text.isEmpty() || text.length > MAX_LENGTH) return false
            val words = text.split(Regex("\\s+")).count { word -> word.codePoints().anyMatch { Character.isLetter(it) } }
            return words >= MIN_WORDS && !looksLikeNoise(text)
        }

        /** Yazı tanıma çöpü içeren ("ou$3e") ya da harften çok rakam ve simge taşıyan ("100/100 HP 25%") satır. */
        fun looksLikeNoise(text: String): Boolean {
            if (PackKey.canon(OcrNoise.clean(text)) != PackKey.canon(text)) return true
            val visible = text.codePoints().filter { !Character.isWhitespace(it) }.toArray()
            val letters = visible.count { Character.isLetter(it) }
            return letters * 2 < visible.size
        }

        /** "2026-11-11T03:17:00Z" (UTC, saniye hassasiyeti). */
        fun timestamp(millis: Long): String =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date(millis))
    }

    data class Line(val text: String, val key: String, val firstSeen: String)

    private val lock = Any()
    private var install = UUID.randomUUID().toString()
    private val queue = mutableListOf<Line>()
    private val sent = ArrayDeque<String>()
    private val queuedKeys = HashSet<String>()
    private val sentKeys = HashSet<String>()
    private var retryAfter: Double? = null
    private var lastSave = 0L
    private var dirty = false
    private var enabled = enabled

    init {
        load()
    }

    val queued: List<Line> get() = synchronized(lock) { queue.toList() }
    val installId: String get() = install
    val isEnabled: Boolean get() = synchronized(lock) { enabled }

    /** Kapatılınca bekleyen satırlar da silinir: kullanıcı vazgeçtiyse hiçbir şey gitmez. */
    fun setEnabled(value: Boolean) = synchronized(lock) {
        enabled = value
        if (value || queue.isEmpty()) return@synchronized
        queue.clear()
        queuedKeys.clear()
        dirty = true
        saveLocked()
    }

    /** Okunan (pakette bulunmayan) satırı kuyruğa ekler; kapalıysa, filtreye takılırsa ya da zaten varsa bir şey yapmaz. */
    fun offer(raw: String) {
        val text = raw.trim()
        if (!accepts(text)) return
        val key = PackKey.key(text) ?: return
        synchronized(lock) {
            if (!enabled || key in queuedKeys || key in sentKeys) return
            queue.add(Line(text, key, timestamp(clock())))
            queuedKeys.add(key)
            // Sınır aşılırsa en eski satırlar düşer.
            while (queue.size > MAX_QUEUE) queuedKeys.remove(queue.removeAt(0).key)
            dirty = true
            if (clock() - lastSave >= SAVE_INTERVAL_MS) saveLocked()
        }
    }

    /** Kuyruğu 200'lük parçalar hâlinde gönderir (bloklar; arka planda çağrılır). 429'da sunucunun istediği kadar bekler. */
    fun flush() {
        try {
            while (true) {
                val batch: List<Line>
                val body: String
                synchronized(lock) {
                    if (!enabled || queue.isEmpty()) return
                    retryAfter?.let { if (clock() / 1000.0 < it) return }
                    batch = queue.take(BATCH_SIZE)
                    body = payload(batch)
                }
                val (status, retrySeconds) = try {
                    (post ?: ::httpPost)(endpoint, body)
                } catch (error: IOException) {
                    return
                }
                synchronized(lock) {
                    when {
                        status in 200..299 -> {
                            retryAfter = null
                            remove(batch, sent = true)
                        }
                        status == 429 -> {
                            val delay = (retrySeconds ?: 60L).coerceIn(1L, 86400L)
                            retryAfter = clock() / 1000.0 + delay
                            dirty = true
                            return
                        }
                        // Sunucu bu parçayı kabul etmiyor; yeniden göndermek düzeltmez.
                        status in 400..499 -> remove(batch, sent = false)
                        else -> return
                    }
                }
            }
        } finally {
            save()
        }
    }

    fun save() = synchronized(lock) { saveLocked() }

    private fun payload(batch: List<Line>): String = JSONObject()
        .put("install", install)
        .put("app", app)
        .put("platform", platform)
        .put("lines", JSONArray(batch.map { JSONObject().put("text", it.text).put("key", it.key).put("firstSeen", it.firstSeen) }))
        .toString()

    private fun remove(batch: List<Line>, sent: Boolean) {
        val keys = batch.map { it.key }.toSet()
        queue.removeAll { it.key in keys }
        queuedKeys.removeAll(keys)
        if (sent) {
            for (key in keys) if (sentKeys.add(key)) this.sent.addLast(key)
            while (this.sent.size > REMEMBERED_SENT) sentKeys.remove(this.sent.removeFirst())
        }
        dirty = true
    }

    private fun saveLocked() {
        if (!dirty) return
        try {
            file.parentFile?.mkdirs()
            val state = JSONObject()
                .put("install", install)
                .put("queue", JSONArray(queue.map { JSONObject().put("text", it.text).put("key", it.key).put("firstSeen", it.firstSeen) }))
                .put("sent", JSONArray(sent.toList()))
            retryAfter?.let { state.put("retryAfter", it) }
            val temporary = File(file.path + ".tmp")
            temporary.writeText(state.toString())
            if (!temporary.renameTo(file)) {
                file.delete()
                temporary.renameTo(file)
            }
        } catch (error: IOException) {
        } catch (error: JSONException) {
        }
        dirty = false
        lastSave = clock()
    }

    private fun load() {
        val state = try {
            JSONObject(file.readText())
        } catch (error: IOException) {
            return
        } catch (error: JSONException) {
            return
        }
        state.optString("install").takeIf { it.isNotEmpty() }?.let { install = it.lowercase(Locale.ROOT) }
        state.optJSONArray("queue")?.let { array ->
            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                val line = Line(item.optString("text"), item.optString("key"), item.optString("firstSeen"))
                if (line.key.isNotEmpty() && queuedKeys.add(line.key)) queue.add(line)
            }
        }
        state.optJSONArray("sent")?.let { array ->
            for (i in 0 until array.length()) array.optString(i).takeIf { it.isNotEmpty() }?.let { if (sentKeys.add(it)) sent.addLast(it) }
        }
        if (state.has("retryAfter")) retryAfter = state.optDouble("retryAfter")
    }

    private fun httpPost(url: URL, body: String): Pair<Int, Long?> {
        val connection = url.openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 20_000
            connection.readTimeout = 20_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val retry = connection.getHeaderField("Retry-After")?.trim()?.toLongOrNull()
            return status to retry
        } finally {
            connection.disconnect()
        }
    }
}
