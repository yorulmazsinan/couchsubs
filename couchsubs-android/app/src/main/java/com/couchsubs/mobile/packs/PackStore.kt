// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.packs

import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** Sunucudaki bir paket (server/packs: GET /v1/packs). */
data class RemotePack(val id: String, val title: String, val version: Long, val sha256: String, val size: Long, val entries: Int)

/** Paket indirilemedi; [status] HTTP kodu (429: sınır aşıldı), ağ hatasında null. */
class PackDownloadException(val status: Int?, message: String) : IOException(message)

/** Paket sunucusu (gerçeği [HttpPackServer]; testlerde sahtesi). */
interface PackServer {
    fun list(): List<RemotePack>
    fun download(id: String): ByteArray
}

/**
 * Sunucudaki yeni ve güncellenen oyun paketleri (ücretsiz, hesapsız): sunucudan indirilir, SHA-256 ile doğrulanıp uygulamanın klasöründe saklanır; açılışta,
 * günde bir ve PS5'te yeni oyun başlayınca yenilenir. Sürümü değişmeyen paket yeniden indirilmez; sunucudan kalkan paket silinir. Bozuk ya da yarım dosya hiçbir
 * zaman yüklenmez (önce geçici dosyaya yazılır, doğrulanınca yerine konur). Uygulamayla gelen paketlerle aynı
 * kimlikteki indirilmiş paket onların yerine geçer (bkz. GamePackLibrary).
 */
class PackStore(
    val directory: File,
    private val server: PackServer,
    private val clock: () -> Long = System::currentTimeMillis,
    /**
     * Uygulamayla gelen paketlerin SHA-256'sı (kimlik → özet). Sunucudaki sürümü bununla aynı olan paket indirilmez:
     * eskiden ilk açılışta uygulamada zaten olan dokuz paket (~29 MB) yeniden iniyordu; yeni paket (ör. GTA 6) sırasını
     * bunların arkasında bekliyor, yavaş bağlantıda "Paketleri güncelle" dakikalarca "güncelleniyor"da kalıyordu.
     */
    private val bundledHashes: () -> Map<String, String> = { emptyMap() },
) {
    companion object {
        /** Açılışta ve günde bir bakılır (iPhone'daki PackStore ile aynı); havuzdan her gece üretilen `pool-*` paketleri en geç bir gün sonra gelir. */
        const val REFRESH_INTERVAL_MS = 24L * 60 * 60 * 1000
        /** PS5'te yeni bir oyun tanınınca son bakış bundan eskiyse hemen bakılır (o oyunun paketi yeni çıkmış olabilir). */
        const val GAME_CHECK_MS = 10L * 60 * 1000
        private const val MANIFEST = "packs.state"

        fun sha256(data: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    data class Local(val id: String, val title: String, val version: Long, val sha256: String)

    /**
     * Yenilemenin sonucu: indirilen ve silinen paketler; [skipped] true ise süresi gelmediği için bakılmadı. [failed]: inemeyen
     * ya da doğrulanamayan paketler (sonraki yenilemede yeniden denenir); [offline] true ise hepsi ağ hatasıyla inemedi.
     */
    data class Refresh(
        val downloaded: List<String> = emptyList(),
        val removed: List<String> = emptyList(),
        val skipped: Boolean = false,
        val failed: List<String> = emptyList(),
        val offline: Boolean = false,
        /** İnen paketler (sunucudaki başlık ve satır sayısıyla); "Paketleri güncelle" özeti için ([PackUpdateSummary]). */
        val downloadedPacks: List<RemotePack> = emptyList(),
    )

    private val lock = Any()

    /** Doğrulanmış, yüklenmeye hazır paket dosyaları. */
    fun files(): List<File> = synchronized(lock) {
        manifest().second.mapNotNull { local -> packFile(local.id).takeIf { it.isFile } }
    }

    fun installed(): List<Local> = synchronized(lock) { manifest().second }

    val lastCheck: Long get() = synchronized(lock) { manifest().first }

    /**
     * Son bakış [maxAgeMs]'den eskiyse (ya da [force]) sunucuya bakar ve değişen paketleri indirir (bloklar). Liste
     * alınamazsa elde olanlar kalır; inemeyen paket bir sonraki açılışta yeniden denenir.
     */
    fun refresh(force: Boolean = false, maxAgeMs: Long = REFRESH_INTERVAL_MS): Refresh = synchronized(lock) {
        val (checked, current) = manifest()
        // Bütün paketler uygulamayla geliyorsa liste boş kalır; o zaman da son bakış zamanı geçerlidir.
        if (!force && (current.isNotEmpty() || checked > 0) && clock() - checked < maxAgeMs) return Refresh(skipped = true)
        val remote = server.list()
        val bundled = if (remote.isEmpty()) emptyMap() else bundledHashes()
        directory.mkdirs()
        val kept = mutableListOf<Local>()
        val downloaded = mutableListOf<String>()
        val downloadedPacks = mutableListOf<RemotePack>()
        val failed = mutableListOf<String>()
        var networkFailures = 0
        var retry = false
        for (pack in remote) {
            val existing = current.firstOrNull { it.id == pack.id }
            val file = packFile(pack.id)
            // Uygulamayla gelen sürüm sunucudakiyle aynı: indirilmez, eskiden inmiş farklı bir sürüm varsa silinir
            // (uygulamayla gelen kullanılır).
            if (bundled[pack.id]?.equals(pack.sha256, ignoreCase = true) == true) {
                if (file.isFile) file.delete()
                continue
            }
            if (existing != null && existing.version == pack.version && existing.sha256.equals(pack.sha256, ignoreCase = true) &&
                file.isFile && sha256(file.readBytes()).equals(pack.sha256, ignoreCase = true)
            ) {
                kept.add(existing)
                continue
            }
            val data = try {
                server.download(pack.id)
            } catch (error: PackDownloadException) {
                // Bu paket şimdi inmedi: eski sürümü varsa o kalır, sonraki yenilemede yeniden denenir.
                retry = true
                failed.add(pack.id)
                if (error.status == null) networkFailures++
                if (existing != null && file.isFile) kept.add(existing.copy(version = -1))
                continue
            }
            if (!sha256(data).equals(pack.sha256, ignoreCase = true)) {
                retry = true
                failed.add(pack.id)
                if (existing != null && file.isFile) kept.add(existing.copy(version = -1))
                continue
            }
            val temporary = File(directory, "${pack.id}.download")
            temporary.writeBytes(data)
            if (!temporary.renameTo(file)) {
                file.delete()
                if (!temporary.renameTo(file)) throw IOException("cannot store ${pack.id}")
            }
            kept.add(Local(pack.id, pack.title, pack.version, pack.sha256.lowercase()))
            downloaded.add(pack.id)
            downloadedPacks.add(pack)
        }
        val removed = current.map { it.id }.filter { id -> remote.none { it.id == id } }
        removed.forEach { packFile(it).delete() }
        // Başarısız indirme ya da checksum doğrulaması sonraki yenilemede yeniden denensin diye kontrol zamanı ilerletilmez.
        writeManifest(if (retry) checked else clock(), kept)
        Refresh(downloaded, removed, failed = failed, offline = failed.isNotEmpty() && networkFailures == failed.size,
            downloadedPacks = downloadedPacks)
    }

    /** Ayarlardan "indirilen paketleri sil". */
    fun clear() = synchronized(lock) { clearLocked() }

    private fun clearLocked() {
        directory.listFiles()?.forEach { it.delete() }
    }

    private fun packFile(id: String) = File(directory, "$id.json.gz")

    private fun manifest(): Pair<Long, List<Local>> {
        val file = File(directory, MANIFEST)
        if (!file.isFile) return 0L to emptyList()
        return try {
            val json = JSONObject(file.readText())
            val packs = json.optJSONArray("packs")
            val list = (0 until (packs?.length() ?: 0)).mapNotNull { packs!!.optJSONObject(it) }.map {
                Local(it.getString("id"), it.optString("title", it.getString("id")), it.optLong("version"), it.optString("sha256"))
            }
            json.optLong("checked") to list
        } catch (error: JSONException) {
            0L to emptyList()
        }
    }

    private fun writeManifest(checked: Long, packs: List<Local>) {
        val json = JSONObject().put("checked", checked).put("packs", org.json.JSONArray(packs.map {
            JSONObject().put("id", it.id).put("title", it.title).put("version", it.version).put("sha256", it.sha256)
        }))
        val temporary = File(directory, "$MANIFEST.tmp")
        temporary.writeText(json.toString())
        if (!temporary.renameTo(File(directory, MANIFEST))) {
            File(directory, MANIFEST).delete()
            temporary.renameTo(File(directory, MANIFEST))
        }
    }
}

/**
 * server/packs Worker'ı. [baseUrls]: birincil adres (workers.dev) ve yedekleri (couchsubs-packs.enmeraapps.com); bazı ağlar
 * (DNS, reklam engelleyici, operatör) *.workers.dev'e ulaşamıyor (#583). Her istek son çalışan adresten başlar; ağ hatası,
 * zaman aşımı ya da 5xx olursa sıradakini dener. 4xx (404, 429) sunucunun gerçek cevabıdır, başka adres denenmez. Çalışan
 * adres bu nesne yaşadıkça (uygulama açıkken) hatırlanır; o da düşerse sıra yeniden baştan dolaşılır.
 */
class HttpPackServer(
    baseUrls: List<String>,
    private val fetch: (String) -> ByteArray = ::httpGet,
) : PackServer {
    constructor(baseUrl: String) : this(listOf(baseUrl))

    val baseUrls: List<String> = baseUrls.map { it.trim().trimEnd('/') }.filter { it.isNotEmpty() }.distinct()

    /** Son başarılı adresin sırası. */
    @Volatile var preferred = 0
        private set

    override fun list(): List<RemotePack> {
        val body = String(request("/v1/packs"), Charsets.UTF_8)
        // Eksik/null ya da bozuk liste başarısız yanıttır, boş liste değildir: boş sayılırsa indirilmiş paketler silinir.
        val packs = try {
            JSONObject(body).optJSONArray("packs")
        } catch (error: JSONException) {
            null
        } ?: throw PackDownloadException(null, "invalid pack list")
        return (0 until packs.length()).map { index ->
            val item = packs.getJSONObject(index)
            RemotePack(item.getString("id"), item.optString("title"), item.optLong("version"), item.getString("sha256"),
                item.optLong("size"), item.optInt("entries"))
        }
    }

    override fun download(id: String): ByteArray = request("/v1/packs/$id")

    private fun request(path: String): ByteArray {
        if (baseUrls.isEmpty()) throw PackDownloadException(null, "no pack server")
        val start = preferred.coerceIn(0, baseUrls.size - 1)
        var last: PackDownloadException? = null
        for (step in baseUrls.indices) {
            val index = (start + step) % baseUrls.size
            try {
                val data = fetch(baseUrls[index] + path)
                preferred = index
                return data
            } catch (error: PackDownloadException) {
                if (!retryable(error.status)) throw error
                last = error
            }
        }
        throw last ?: PackDownloadException(null, "network")
    }

    companion object {
        /** Ağ hatası (status null) ya da 5xx: başka adres denenir. */
        fun retryable(status: Int?): Boolean = status == null || status >= 500
    }
}

/** Düz GET; 2xx değilse [PackDownloadException] (ağ hatasında status null). */
private fun httpGet(url: String): ByteArray {
    val connection = URL(url).openConnection() as HttpURLConnection
    try {
        connection.connectTimeout = 15_000
        connection.readTimeout = 60_000
        // Liste sunucudan `max-age=300` ile geliyor: bir HTTP önbelleği kurulsa bile "Paketleri güncelle" eski listeyi
        // okumasın, her bakışta sunucuya gidilsin (iPhone'da da liste önbelleği atlar).
        connection.useCaches = false
        connection.setRequestProperty("Cache-Control", "no-cache")
        val status = connection.responseCode
        if (status !in 200..299) throw PackDownloadException(status, "HTTP $status")
        return connection.inputStream.use { it.readBytes() }
    } catch (error: PackDownloadException) {
        throw error
    } catch (error: IOException) {
        throw PackDownloadException(null, error.message ?: "network")
    } finally {
        connection.disconnect()
    }
}
