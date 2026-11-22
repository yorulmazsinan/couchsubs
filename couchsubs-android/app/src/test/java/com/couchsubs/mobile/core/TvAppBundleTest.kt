// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.io.File
import java.net.Socket
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * TV sayfasının telefondan sunulması (ince kabuk, docs/tv-ince-kabuk.md). Ortak deneme dosyası fixtures/tv-app-bundle.json
 * (Mac TVAppBundleTests, Windows TvAppBundleTests ve scripts/tv-shell.test.js ile aynı).
 */
class TvAppBundleTest {
    private val fixture = JSONObject(Fixtures.text("tv-app-bundle.json"))

    private fun files(): MutableMap<String, ByteArray> {
        val files = fixture.getJSONObject("files")
        return files.keys().asSequence().associateWith { files.getString(it).toByteArray(Charsets.UTF_8) }.toMutableMap()
    }

    @Test fun sharedVectors() {
        val bundle = TvAppBundle.create(files())!!
        assertEquals(fixture.getString("version"), bundle.version)
        assertEquals(fixture.getInt("shellApi"), bundle.shellApi)
        assertEquals(TvAppBundle.PATHS, bundle.files.map { it.path })
        for (file in bundle.files) {
            assertEquals(file.path, fixture.getJSONObject("sha256").getString(file.path), file.sha256)
            assertEquals(file.path, fixture.getJSONObject("sizes").getInt(file.path), file.data.size)
        }
        assertEquals(fixture.getString("canonical"), bundle.canonical)
        val key = fixture.getString("key")
        assertEquals(fixture.getString("hmac"), TvAppBundle.signature(bundle.canonical, key))
        val manifest = JSONObject(bundle.manifest(key))
        assertEquals(fixture.getString("hmac"), manifest.getString("hmac"))
        assertEquals(1, manifest.getInt("format"))
        val listed = manifest.getJSONArray("files")
        assertEquals(TvAppBundle.PATHS, (0 until listed.length()).map { listed.getJSONObject(it).getString("path") })
    }

    @Test fun rejectsPagesWithoutVersionOrShellApi() {
        val invalid = fixture.getJSONArray("invalid")
        for (i in 0 until invalid.length()) {
            val files = files()
            files["app.js"] = invalid.getJSONObject(i).getString("app.js").toByteArray(Charsets.UTF_8)
            assertNull(invalid.getJSONObject(i).getString("name"), TvAppBundle.create(files))
        }
        assertNull(TvAppBundle.create(files().apply { remove("style.css") }))
        assertNull(TvAppBundle.load { throw java.io.FileNotFoundException(it) })
    }

    @Test fun fileLookupOnlyForOwnVersion() {
        val bundle = TvAppBundle.create(files())!!
        assertEquals("app.js", bundle.fileAt("/tv/app/0.9.80/app.js")?.path)
        assertNull(bundle.fileAt("/tv/app/0.9.79/app.js"))
        assertNull(bundle.fileAt("/tv/app/0.9.80/platform.js"))
        assertNull(bundle.fileAt("/tv/app/0.9.80/../app.js"))
        assertNull(bundle.fileAt("/tv/app/0.9.80/x/app.js"))
    }

    /** Uygulamaya kopyalanan TV sayfası (tv-webos) paketlenebilir: sürümü TV uygulamasıyla aynı. */
    @Test fun repositoryPageIsServable() {
        val root = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "tv-webos") }.first { File(it, "appinfo.json").isFile }
        val bundle = TvAppBundle.load { File(root.parentFile, it).readBytes() }
        assertNotNull(bundle)
        assertEquals(JSONObject(File(root, "appinfo.json").readText()).getString("version"), bundle!!.version)
        assertTrue(bundle.shellApi >= 1)
    }

    private fun get(port: Int, target: String, origin: String? = null): String =
        Socket("127.0.0.1", port).use { socket ->
            socket.soTimeout = 5000
            socket.getOutputStream().write(("GET $target HTTP/1.1\r\nHost: x\r\n" + (origin?.let { "Origin: $it\r\n" } ?: "") + "\r\n").toByteArray())
            socket.getInputStream().readBytes().toString(Charsets.UTF_8)
        }

    @Test fun serverServesSignedManifestAndFilesOnlyWithKey() {
        val key = fixture.getString("key")
        val server = SubtitleServer(0, key = key, allowLegacy = true, tvApp = TvAppBundle.create(files()))
        val port = server.start()
        try {
            // Eski TV'lere tanınan anahtarsız geçiş /tv/app'e uygulanmaz.
            assertTrue(get(port, "/tv/app/manifest").startsWith("HTTP/1.1 401"))
            assertTrue(get(port, "/tv/app/manifest?k=AAAAAAAAAAAAAAAAAAAAAA").startsWith("HTTP/1.1 401"))
            val manifest = get(port, "/tv/app/manifest?k=$key", origin = "null")
            assertTrue(manifest, manifest.startsWith("HTTP/1.1 200 OK"))
            assertTrue(manifest, manifest.contains("Cache-Control: no-store\r\n"))
            assertTrue(manifest, manifest.contains("Access-Control-Allow-Origin: null\r\n"))
            assertEquals(fixture.getString("hmac"), JSONObject(manifest.substringAfter("\r\n\r\n")).getString("hmac"))

            val file = get(port, "/tv/app/0.9.80/app.js?k=$key")
            assertTrue(file, file.startsWith("HTTP/1.1 200 OK"))
            assertTrue(file, file.contains("Cache-Control: ${TvAppBundle.FILE_CACHE}\r\n"))
            assertTrue(file, file.contains("Content-Type: application/javascript; charset=utf-8\r\n"))
            assertTrue(file, file.contains("Content-Length: ${fixture.getJSONObject("sizes").getInt("app.js")}\r\n"))
            assertEquals(fixture.getJSONObject("files").getString("app.js"), file.substringAfter("\r\n\r\n"))

            assertTrue(get(port, "/tv/app/0.9.70/app.js?k=$key").startsWith("HTTP/1.1 404"))
            server.tvApp = null
            assertTrue(get(port, "/tv/app/manifest?k=$key").startsWith("HTTP/1.1 404"))
        } finally {
            server.stop()
        }
    }
}
