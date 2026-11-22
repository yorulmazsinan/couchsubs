// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import com.couchsubs.mobile.BuildConfig
import com.couchsubs.mobile.core.LogShare
import java.io.File

/**
 * Profil › Hakkında › "Günlükleri paylaş": bu uygulamanın günlüğü (logcat; Remote Play, altyazı ve TV satırları; iPhone'daki
 * remoteplay.log ve altyazi.log'un karşılığı) ve varsa tvinstall.log tek metin dosyasında, kişisel veri maskelenmiş
 * ([LogShare]) paylaşım sayfasıyla gönderilir (Mesajlar, Gmail, Drive, Quick Share). Dosya önbellekte
 * (cache/logs/couchsubs-logs.txt) FileProvider ile verilir.
 */
internal fun shareLogs(context: Context) {
    val app = context.applicationContext
    Thread {
        val logcat = runCatching {
            val process = ProcessBuilder("logcat", "-d", "-v", "threadtime", "--pid=${android.os.Process.myPid()}")
                .redirectErrorStream(true).start()
            process.inputStream.bufferedReader().use { it.readText() }.takeLast(LogShare.MAX_BYTES_PER_LOG)
        }.getOrNull()
        val header = "CouchSubs Android ${BuildConfig.VERSION_NAME} · Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}) · " +
            "${Build.MANUFACTURER} ${Build.MODEL}"
        val text = LogShare.combined(header, listOf(
            "logcat (Remote Play, altyazı)" to logcat,
            "tvinstall.log" to runCatching { LogShare.tail(File(app.filesDir, "tvinstall.log")) }.getOrNull(),
        ))
        val file = runCatching {
            File(app.cacheDir, "logs").apply { mkdirs() }.resolve(LogShare.FILE_NAME).apply { writeText(text) }
        }.getOrNull() ?: return@Thread
        val uri = FileProvider.getUriForFile(app, "${app.packageName}.logs", file)
        val send = Intent(Intent.ACTION_SEND).setType("text/plain")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .putExtra(Intent.EXTRA_SUBJECT, "CouchSubs ${LogShare.FILE_NAME}")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri(LogShare.FILE_NAME, uri)
        Handler(Looper.getMainLooper()).post {
            runCatching {
                context.startActivity(Intent.createChooser(send, null)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
    }.start()
}
