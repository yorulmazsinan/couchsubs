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

/** Paket indirilemedi; [status] HTTP kodu (403: abonelik yok, 401: oturum geçersiz), ağ hatasında null. */
class PackDownloadException(val status: Int?, message: String) : IOException(message)

/** Paket sunucusu (gerçeği [HttpPackServer]; testlerde sahtesi). */
interface PackServer {
    fun list(): List<RemotePack>
    /** [idToken]: Firebase ID token'ı. */
    fun download(id: String, idToken: String): ByteArray
}

/**
 * Abonenin oyun paketleri: sunucudan indirilir, SHA-256 ile doğrulanıp uygulamanın klasöründe saklanır, haftada bir
 * yenilenir. Sürümü değişmeyen paket yeniden indirilmez; sunucudan kalkan paket silinir. Bozuk ya da yarım dosya hiçbir
 * zaman yüklenmez (önce geçici dosyaya yazılır, doğrulanınca yerine konur).
 */
class PackStore(
    private val directory: File,
    private val server: PackServer,
    private val idToken: () -> String?,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    companion object {
        const val REFRESH_INTERVAL_MS = 7L * 24 * 60 * 60 * 1000
        private const val MANIFEST = "packs.state"

        fun sha256(data: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    data class Local(val id: String, val title: String, val version: Long, val sha256: String)

    /** Yenilemenin sonucu: indirilen ve silinen paketler; [skipped] true ise süresi gelmediği için bakılmadı. */
    data class Refresh(val downloaded: List<String> = emptyList(), val removed: List<String> = emptyList(), val skipped: Boolean = false)

    private val lock = Any()

    /** Doğrulanmış, yüklenmeye hazır paket dosyaları. */
    fun files(): List<File> = synchronized(lock) {
        manifest().second.mapNotNull { local -> packFile(local.id).takeIf { it.isFile } }
    }

    fun installed(): List<Local> = synchronized(lock) { manifest().second }

    val lastCheck: Long get() = synchronized(lock) { manifest().first }

    /**
     * Süresi geldiyse (ya da [force]) sunucuya bakar ve değişen paketleri indirir (bloklar). Liste alınamazsa elde
     * olanlar kalır. Abonelik yoksa ([PackDownloadException] 403) paketler silinir: aboneliği biten kullanıcıda kalmaz.
     */
    fun refresh(force: Boolean = false): Refresh = synchronized(lock) {
        val (checked, current) = manifest()
        if (!force && current.isNotEmpty() && clock() - checked < REFRESH_INTERVAL_MS) return Refresh(skipped = true)
        val remote = server.list()
        val token = idToken() ?: throw PackDownloadException(401, "not signed in")
        directory.mkdirs()
        val kept = mutableListOf<Local>()
        val downloaded = mutableListOf<String>()
        for (pack in remote) {
            val existing = current.firstOrNull { it.id == pack.id }
            val file = packFile(pack.id)
            if (existing != null && existing.version == pack.version && existing.sha256.equals(pack.sha256, ignoreCase = true) &&
                file.isFile && sha256(file.readBytes()).equals(pack.sha256, ignoreCase = true)
            ) {
                kept.add(existing)
                continue
            }
            val data = try {
                server.download(pack.id, token)
            } catch (error: PackDownloadException) {
                if (error.status == 403) {
                    clearLocked()
                    throw error
                }
                // Bu paket şimdi inmedi: eski sürümü varsa o kalır, sonraki yenilemede yeniden denenir.
                if (existing != null && file.isFile) kept.add(existing.copy(version = -1))
                continue
            }
            if (!sha256(data).equals(pack.sha256, ignoreCase = true)) {
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
        }
        val removed = current.map { it.id }.filter { id -> remote.none { it.id == id } }
        removed.forEach { packFile(it).delete() }
        // Bir paket inemediyse (sürüm -1) bir sonraki açılışta yeniden denensin diye kontrol zamanı ilerletilmez.
        val retry = kept.any { it.version == -1L }
        writeManifest(if (retry) checked else clock(), kept)
        Refresh(downloaded, removed)
    }

    /** Hesap silinince ya da abonelik bitince. */
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

/** server/packs Worker'ı. */
class HttpPackServer(private val baseUrl: String) : PackServer {
    override fun list(): List<RemotePack> {
        val body = String(request("$baseUrl/v1/packs", null), Charsets.UTF_8)
        val packs = JSONObject(body).optJSONArray("packs") ?: return emptyList()
        return (0 until packs.length()).map { index ->
            val item = packs.getJSONObject(index)
            RemotePack(item.getString("id"), item.optString("title"), item.optLong("version"), item.getString("sha256"),
                item.optLong("size"), item.optInt("entries"))
        }
    }

    override fun download(id: String, idToken: String): ByteArray = request("$baseUrl/v1/packs/$id", idToken)

    private fun request(url: String, token: String?): ByteArray {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 15_000
            connection.readTimeout = 60_000
            token?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
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
}
