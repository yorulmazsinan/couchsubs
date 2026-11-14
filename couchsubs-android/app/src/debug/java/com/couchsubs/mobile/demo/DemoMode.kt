// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.demo

import android.app.Activity
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.util.Log
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.remoteplay.FrameSourceFactory
import com.couchsubs.mobile.remoteplay.FrameSources
import com.couchsubs.mobile.remoteplay.RegisteredConsole
import com.couchsubs.mobile.ui.MainActivity
import java.io.File

/**
 * Demo kipi (yalnız debug yapısı): PS5 yerine kayıtlı bir klip oynatılır, uygulamanın geri kalanı (okuma, çeviri,
 * altyazı, ön plan hizmeti bildirimi) gerçekteki gibi çalışır. Play ekran görüntüleri ve hizmet videosu içindir.
 *
 * Açmak (klip uygulamanın dış dosya klasörüne konur ya da yolu verilir):
 *   adb push demo-ps5.mp4 /sdcard/Android/data/com.couchsubs.mobile/files/demo-ps5.mp4
 *   adb shell am start -n com.couchsubs.mobile/.demo.DemoActivity --ez demo true [--es clip <yol>] [--es name PS5] [--ef speed 0.5]
 * Yavaş öykünücüde 960x540 bir klip ve 0.5 hız, yazı tanımanın her altyazıyı yakalamasına yeter.
 * Kapatmak: aynı komut --ez demo false ile (sahte PS5 eşlemesi de silinir).
 */
object DemoMode {
    private const val TAG = "CouchSubsDemo"
    const val CLIP_NAME = "demo-ps5.mp4"
    /** Sahte eşlemenin adresi; demo kapatılırken yalnız bu eşleme silinir. */
    const val DEMO_HOST = "demo.invalid"

    private fun prefs(context: Context) = context.getSharedPreferences("demo", Context.MODE_PRIVATE)

    fun enabled(context: Context) = prefs(context).getBoolean("enabled", false)

    /** Oynatma hızı (1 gerçek zaman; 0.25–1 arası). */
    fun speed(context: Context): Double = prefs(context).getFloat("speed", 1f).toDouble().coerceIn(0.25, 1.0)

    /** Klibin yolu: verilen yol, yoksa dış dosya klasörü, yoksa iç dosya klasöründeki demo-ps5.mp4. */
    fun clip(context: Context): File? {
        val given = prefs(context).getString("clip", null)?.let(::File)
        val candidates = listOfNotNull(given, context.getExternalFilesDir(null)?.let { File(it, CLIP_NAME) }, File(context.filesDir, CLIP_NAME))
        return candidates.firstOrNull { it.canRead() }
    }

    /** Demo açıksa kare kaynağını klip kaynağıyla değiştirir (açılışta ve etkinleştirilince). */
    fun install(context: Context) {
        if (!enabled(context)) {
            FrameSources.replacement = null
            return
        }
        val app = context.applicationContext
        FrameSources.replacement = FrameSourceFactory { ctx, onFrame, onState ->
            val file = clip(app) ?: throw IllegalStateException("Demo klibi bulunamadı ($CLIP_NAME)")
            DemoFrameSource(ctx, file, speed(app), onFrame, onState)
        }
        Log.i(TAG, "Demo kaynağı kuruldu: ${clip(app) ?: "klip yok"}")
    }

    fun enable(context: Context, clipPath: String?, name: String, speed: Float) {
        prefs(context).edit().putBoolean("enabled", true).putString("clip", clipPath).putFloat("speed", speed).apply()
        val settings = Services.settings
        // Ana ekranın "bağlı" görünmesi için sahte PSN kimliği ve PS5 eşlemesi (anahtarlar kullanılmaz).
        if (settings.accountId == null) settings.accountId = ByteArray(8)
        settings.console = RegisteredConsole(DEMO_HOST, name, ByteArray(16), ByteArray(16))
        install(context)
    }

    fun disable(context: Context) {
        prefs(context).edit().clear().apply()
        val settings = Services.settings
        if (settings.console?.host == DEMO_HOST) {
            settings.console = null
            if (settings.accountId?.all { it == 0.toByte() } == true) settings.accountId = null
        }
        install(context)
    }
}

/** adb ile demo kipini açar ya da kapatır, ardından ana ekranı açar. */
class DemoActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.getBooleanExtra("demo", true))
            DemoMode.enable(this, intent.getStringExtra("clip"), intent.getStringExtra("name") ?: "PS5", intent.getFloatExtra("speed", 1f))
        else DemoMode.disable(this)
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        finish()
    }
}

/** Uygulama açılırken (Application'dan önce) demo açıksa kaynağı kurar; veri sunmaz. */
class DemoInstaller : ContentProvider() {
    override fun onCreate(): Boolean {
        context?.let(DemoMode::install)
        return true
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
