// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * TV uygulamasının sayfa kodu (ince kabuk, docs/tv-ince-kabuk.md). TV'de kurulu kabuk bağlandığı telefondan bu dosyaları
 * `GET /tv/app/manifest` ve `GET /tv/app/<sürüm>/<dosya>` ile alır; TV uygulaması CouchSubs güncellenince yeniden
 * kurulmadan güncellenir. Mac/iPhone `TVAppBundle.swift`, Windows `TvAppBundle.cs` ile aynı. Liste eşleşme anahtarıyla
 * HMAC-SHA256 imzalıdır, her dosyanın SHA-256 özeti listededir.
 */
class TvAppBundle private constructor(val version: String, val shellApi: Int, val files: List<File>) {
    class File(val path: String, val data: ByteArray, val sha256: String)

    /** İmzalanan metin: biçim, sürüm, kabuk arayüzü ve her dosya için "ad boyut özet" satırı. */
    val canonical: String
        get() = buildString {
            append("couchsubs-tv-app/").append(FORMAT).append('\n').append(version).append('\n').append(shellApi).append('\n')
            for (file in files) append(file.path).append(' ').append(file.data.size).append(' ').append(file.sha256).append('\n')
        }

    /** `GET /tv/app/manifest` yanıtı. */
    fun manifest(key: String): String = org.json.JSONObject()
        .put("format", FORMAT).put("version", version).put("shellApi", shellApi)
        .put("files", org.json.JSONArray().apply {
            for (file in files) put(org.json.JSONObject().put("path", file.path).put("size", file.data.size).put("sha256", file.sha256))
        })
        .put("hmac", signature(canonical, key))
        .toString()

    /** `/tv/app/<sürüm>/<dosya>`: yalnız bu paketin sürümü ve listedeki dosyalar. */
    fun fileAt(path: String): File? {
        if (!isPath(path)) return null
        val rest = path.substring(PREFIX.length).split('/')
        if (rest.size != 2 || rest[0] != version) return null
        return files.firstOrNull { it.path == rest[1] }
    }

    companion object {
        /** Sunulan dosyalar ve sırası (index.html'den yalnız `<body>` işaretlemesi kullanılır). */
        val PATHS = listOf("index.html", "style.css", "i18n.js", "app.js")
        const val FORMAT = 1
        const val PREFIX = "/tv/app/"
        const val MANIFEST_PATH = "/tv/app/manifest"
        /** Sürümlü adresteki dosya değişmez: TV tarayıcısı önbellekte tutabilir (kabuk yine de özeti doğrular). */
        const val FILE_CACHE = "private, max-age=31536000, immutable"
        /** Uygulamanın assets klasöründeki kopya (build.gradle: tv-webos'tan). */
        const val ASSET_DIR = "tv-webos"

        private val VERSION = Regex("""var APP_VERSION = '([0-9]+(?:\.[0-9]+){1,3})';""")
        private val SHELL_API = Regex("""var SHELL_API = ([0-9]{1,3});""")

        /** Dört dosyanın hepsi varsa ve app.js sürümü ile kabuk arayüzü sürümünü bildiriyorsa paket kurulur. */
        fun create(files: Map<String, ByteArray>): TvAppBundle? {
            val list = PATHS.map { path ->
                val data = files[path]?.takeIf { it.isNotEmpty() } ?: return null
                File(path, data, hex(MessageDigest.getInstance("SHA-256").digest(data)))
            }
            val app = files.getValue("app.js").toString(Charsets.UTF_8)
            val version = VERSION.find(app)?.groupValues?.get(1) ?: return null
            val api = SHELL_API.find(app)?.groupValues?.get(1)?.toIntOrNull()?.takeIf { it >= 1 } ?: return null
            return TvAppBundle(version, api, list)
        }

        /** `open`: dosyayı okuyan işlev (assets.open); dosya yoksa ya da okunamazsa paket yok. */
        fun load(open: (String) -> ByteArray): TvAppBundle? =
            runCatching { create(PATHS.associateWith { open("$ASSET_DIR/$it") }) }.getOrNull()

        fun isPath(path: String): Boolean = path.startsWith(PREFIX)

        fun signature(canonical: String, key: String): String {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(key.toByteArray(Charsets.UTF_8), "HmacSHA256"))
            return hex(mac.doFinal(canonical.toByteArray(Charsets.UTF_8)))
        }

        fun contentType(path: String): String = when {
            path.endsWith(".html") -> "text/html; charset=utf-8"
            path.endsWith(".css") -> "text/css; charset=utf-8"
            else -> "application/javascript; charset=utf-8"
        }

        private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
