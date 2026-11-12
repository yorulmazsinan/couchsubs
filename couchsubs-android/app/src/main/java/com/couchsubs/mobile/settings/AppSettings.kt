// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.settings

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.couchsubs.mobile.core.SubtitlePlacement
import com.couchsubs.mobile.core.SubtitleStyle
import com.couchsubs.mobile.core.SubtitleTextColor
import com.couchsubs.mobile.remoteplay.RegisteredConsole
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Altyazının gösterileceği yer. */
enum class SubtitleTarget { TV, PHONE }

/** Çeviri motoru: ücretsiz cihaz üstü (ML Kit) ya da kullanıcının anahtarıyla çevrimiçi hizmet. */
enum class EngineChoice { FREE, DEEPL, GEMINI, OPENAI, CLAUDE }

/**
 * Anahtarlar ve PS5 kaydı Android Keystore'daki (donanım destekli, dışarı çıkarılamayan) AES-GCM anahtarıyla şifrelenip
 * saklanır. Windows'taki SecureStore (DPAPI) ve Mac'teki Anahtar Zinciri karşılığı. Uygulama silinince gider.
 */
class SecretStore(context: Context) {
    private val prefs = context.getSharedPreferences("secrets", Context.MODE_PRIVATE)
    private val alias = "couchsubs-secrets"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    fun put(name: String, value: String?) {
        if (value.isNullOrEmpty()) {
            prefs.edit().remove(name).apply()
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(name, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    /** Bütün şifreli değerler ve anahtarın kendisi silinir. */
    fun clear() {
        prefs.edit().clear().commit()
        try {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias)
        } catch (error: Exception) {
        }
    }

    fun get(name: String): String? {
        val stored = prefs.getString(name, null) ?: return null
        return try {
            val sealed = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, 12))
            String(cipher.doFinal(sealed, 12, sealed.size - 12), Charsets.UTF_8)
        } catch (error: Exception) {
            // Anahtar silinmiş (ör. yedekten geri yükleme): değer okunamaz, yeniden girilir.
            null
        }
    }
}

/** Uygulama ayarları; gizli olanlar [SecretStore]'da. */
class AppSettings(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    val secrets = SecretStore(context)

    var onboarded: Boolean
        get() = prefs.getBoolean("onboarded", false)
        set(value) = prefs.edit().putBoolean("onboarded", value).apply()

    var target: SubtitleTarget
        get() = enumOr(prefs.getString("target", null), SubtitleTarget.TV)
        set(value) = prefs.edit().putString("target", value.name).apply()

    var engine: EngineChoice
        get() = enumOr(prefs.getString("engine", null), EngineChoice.FREE)
        set(value) = prefs.edit().putString("engine", value.name).apply()

    /** Seçilen yapay zekâ modeli (listede yoksa varsayılan kullanılır). */
    var aiModel: String?
        get() = prefs.getString("aiModel", null)
        set(value) = prefs.edit().putString("aiModel", value).apply()

    var packsEnabled: Boolean
        get() = prefs.getBoolean("packsEnabled", true)
        set(value) = prefs.edit().putBoolean("packsEnabled", value).apply()

    var disabledPacks: Set<String>
        get() = prefs.getStringSet("disabledPacks", emptySet()) ?: emptySet()
        set(value) = prefs.edit().putStringSet("disabledPacks", value).apply()

    /** Ortak havuz: varsayılan açık (masaüstüyle aynı), ayarlardan kapatılır. */
    var sharePool: Boolean
        get() = prefs.getBoolean("sharePool", true)
        set(value) = prefs.edit().putBoolean("sharePool", value).apply()

    var keepScreenOn: Boolean
        get() = prefs.getBoolean("keepScreenOn", true)
        set(value) = prefs.edit().putBoolean("keepScreenOn", value).apply()

    /** Telefon ekranındaki altyazının yazı boyu (sp). */
    var phoneTextSize: Int
        get() = prefs.getInt("phoneTextSize", 34)
        set(value) = prefs.edit().putInt("phoneTextSize", value).apply()

    var textColor: SubtitleTextColor
        get() = enumOr(prefs.getString("textColor", null), SubtitleTextColor.WHITE)
        set(value) = prefs.edit().putString("textColor", value.name).apply()

    /** TV'deki yazı boyu: 36, 46, 58, 72. */
    var tvFontSize: Int
        get() = prefs.getInt("tvFontSize", 46)
        set(value) = prefs.edit().putInt("tvFontSize", value).apply()

    val style: SubtitleStyle
        get() = SubtitleStyle(fontSize = tvFontSize, placement = SubtitlePlacement.COVER, textColor = textColor)

    /** PSN hesap kimliği (8 bayt, base64). */
    var accountId: ByteArray?
        get() = secrets.get("accountId")?.let { Base64.decode(it, Base64.NO_WRAP) }?.takeIf { it.size == 8 }
        set(value) = secrets.put("accountId", value?.let { Base64.encodeToString(it, Base64.NO_WRAP) })

    var console: RegisteredConsole?
        get() = secrets.get("console")?.let {
            try {
                val json = JSONObject(it)
                RegisteredConsole(
                    json.getString("host"), json.getString("name"),
                    Base64.decode(json.getString("registKey"), Base64.NO_WRAP), Base64.decode(json.getString("morning"), Base64.NO_WRAP),
                )
            } catch (error: Exception) {
                null
            }
        }
        set(value) = secrets.put("console", value?.let {
            JSONObject().put("host", it.host).put("name", it.name)
                .put("registKey", Base64.encodeToString(it.registKey, Base64.NO_WRAP))
                .put("morning", Base64.encodeToString(it.morning, Base64.NO_WRAP)).toString()
        })

    /** Hedef seçiminde görülen TV'nin adı (ana ekrandaki "Altyazı · Salon TV"). */
    var tvName: String?
        get() = prefs.getString("tvName", null)
        set(value) = prefs.edit().putString("tvName", value).apply()

    /** Son okuma oturumunun süresi (ms). */
    var lastSessionMs: Long
        get() = prefs.getLong("lastSessionMs", 0)
        set(value) = prefs.edit().putLong("lastSessionMs", value).apply()

    /** Altyazı yazı ölçeği, yüzde (80–160; tasarım: Ayarlar › Altyazı görünümü). */
    var subtitleScale: Int
        get() = prefs.getInt("subtitleScale", 100)
        set(value) = prefs.edit().putInt("subtitleScale", value.coerceIn(80, 160)).apply()

    /** Profil › Kullanım verisi: hata ve kullanım istatistikleri (Firebase, Meta olay adları). Varsayılan açık. */
    var usageData: Boolean
        get() = prefs.getBoolean("usageData", true)
        set(value) = prefs.edit().putBoolean("usageData", value).apply()

    /** Tanıtım (3 sayfa) ve ana ekran turu (4 adım) bir kez gösterilir. */
    var welcomeSeen: Boolean
        get() = prefs.getBoolean("welcomeSeen", false)
        set(value) = prefs.edit().putBoolean("welcomeSeen", value).apply()

    var tourShown: Boolean
        get() = prefs.getBoolean("tourShown", false)
        set(value) = prefs.edit().putBoolean("tourShown", value).apply()

    /** Bildirim tercihleri: bağlantı koptuğunda ve yeni paket geldiğinde. */
    var notifyDisconnect: Boolean
        get() = prefs.getBoolean("notify.disconnect", true)
        set(value) = prefs.edit().putBoolean("notify.disconnect", value).apply()

    var notifyNewPacks: Boolean
        get() = prefs.getBoolean("notify.packs", true)
        set(value) = prefs.edit().putBoolean("notify.packs", value).apply()

    fun apiKey(engine: EngineChoice): String? = secrets.get("key." + engine.name)
    fun setApiKey(engine: EngineChoice, key: String?) = secrets.put("key." + engine.name, key?.trim())

    private inline fun <reified T : Enum<T>> enumOr(name: String?, fallback: T): T =
        name?.let { runCatching { enumValueOf<T>(it) }.getOrNull() } ?: fallback
}
