// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Uçtan uca: telefonun gerçek [SubtitleServer]'ı ile Android TV uygulamasının sayfası (tv-webos/app.js +
 * tv-android/platform.js, Node'da, Android 8 WebView'ine göre kısıtlı; scripts/tv-live-page.js). Sayfa eşleşmiş anahtarla
 * bağlanır, altyazıyı sayar ("sub 1") ve çizer. Windows'ta TvPageEndToEndTests, Mac/iPhone'da TVPageEndToEndTests.
 * Node yoksa atlanır (CI'da hata).
 */
class TvPageEndToEndTest {
    @Test
    fun androidTvPageCountsAndShowsSubtitleFromPhone() {
        val script = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "scripts/tv-live-page.js") }.firstOrNull { it.isFile }
        val node = ((System.getenv("PATH") ?: "").split(File.pathSeparator) + listOf("/opt/homebrew/bin", "/usr/local/bin"))
            .flatMap { listOf(File(it, "node"), File(it, "node.exe")) }.firstOrNull { it.canExecute() }
        if (System.getenv("CI") == "true") assertTrue("Node ya da scripts/tv-live-page.js bulunamadı", script != null && node != null)
        assumeTrue(script != null && node != null)

        val server = SubtitleServer(port = 0, instanceId = "0f8e7d6c-1111-2222-3333-444455556666")
        val port = server.start()
        val process = ProcessBuilder(node!!.path, script!!.path, "http://127.0.0.1:$port", server.accessKey).start()
        val lines = CopyOnWriteArrayList<String>()
        val reader = Thread { process.inputStream.bufferedReader(Charsets.UTF_8).forEachLine { lines.add(it) } }.apply { isDaemon = true; start() }
        fun waitFor(prefix: String): String {
            val deadline = System.currentTimeMillis() + 10_000
            while (true) {
                lines.firstOrNull { it.startsWith(prefix) }?.let { return it }
                assertTrue("TV sayfası \"$prefix\" yazmadı. Çıktı:\n${lines.joinToString("\n")}", System.currentTimeMillis() < deadline)
                Thread.sleep(25)
            }
        }
        try {
            waitFor("status bağlı")
            server.sendSubtitle("Merhaba dünya, bu bir deneme.", 4000, null, false)
            waitFor("shown Merhaba dünya, bu bir deneme.")
            assertFalse(waitFor("diag sub 1 ").contains(" err "))
        } finally {
            process.outputStream.close()
            if (!process.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) process.destroyForcibly()
            reader.join(1000)
            server.stop()
        }
    }
}
