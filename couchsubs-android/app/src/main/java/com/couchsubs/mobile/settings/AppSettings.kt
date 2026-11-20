// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.settings

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.couchsubs.mobile.core.AreaProfile
import com.couchsubs.mobile.core.AreaProfiles
import com.couchsubs.mobile.core.AreaSet
import com.couchsubs.mobile.core.AreaStore
import com.couchsubs.mobile.core.SubtitlePlacement
import com.couchsubs.mobile.core.toJson
import com.couchsubs.mobile.core.SubtitleStyle
import com.couchsubs.mobile.core.SubtitleTextColor
import com.couchsubs.mobile.remoteplay.LoginPasscode
import com.couchsubs.mobile.remoteplay.RegisteredConsole
import com.couchsubs.mobile.translation.AiProvider
import com.couchsubs.mobile.tv.InstalledTv
import com.couchsubs.mobile.tv.LgSessionRenewalPolicy
import com.couchsubs.mobile.tv.TvBrand
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Okunan konsol: PlayStation (varsayılan, Remote Play) ya da Xbox (Beta, ev yayını). */
enum class ConsolePlatform { PLAYSTATION, XBOX }

/** Altyazının gösterileceği yer. */
enum class SubtitleTarget { TV, PHONE }

/** Çeviri motoru: ücretsiz cihaz üstü (ML Kit) ya da kullanıcının anahtarıyla çevrimiçi hizmet. */
enum class EngineChoice { FREE, DEEPL, GEMINI, OPENAI, CLAUDE }

/**
 * "Ekran yazılarını otomatik çevir" bir kerelik göçü (Windows AutoScreenTextMigration, Mac/iPhone
 * migratingAutoScreenText ile aynı kural). Göç işareti varsa null (bir şey yapılmaz); yoksa ayar kapatılıp işaret
 * konur. Ayar açıktıysa — açık kaydedilmiş ya da hiç değiştirilmemiş eski kurulumda (beta.63 varsayılanı açıktı) —
 * kullanıcıya bir kez bilgi gösterilir; yeni kurulumda (kayıt yok) gösterilmez.
 */
object AutoScreenTextMigration {
    data class Step(val notice: Boolean)

    /** [stored]: kayıttaki değer (yoksa null); [existing]: kayıt dosyasında başka ayar var (eski kurulum). */
    fun apply(reset: Boolean, stored: Boolean?, existing: Boolean): Step? =
        if (reset) null else Step(notice = stored ?: existing)
}

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
class AppSettings(context: Context) : AreaStore {
    private val prefs: SharedPreferences = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    val secrets = SecretStore(context)

    /** Kuruluma özel; sunucu durdurulup başlatılınca değişmez. */
    val subtitleAccessKey: String
        get() = synchronized(AppSettings::class.java) {
            secrets.get("subtitleAccessKey")?.takeIf { it.isNotEmpty() }
                ?: com.couchsubs.mobile.core.SubtitleAccess.createKey().also { secrets.put("subtitleAccessKey", it) }
        }

    fun renewSubtitleAccessKey(): String = synchronized(AppSettings::class.java) {
        com.couchsubs.mobile.core.SubtitleAccess.createKey().also { secrets.put("subtitleAccessKey", it) }
    }

    var onboarded: Boolean
        get() = prefs.getBoolean("onboarded", false)
        set(value) = prefs.edit().putBoolean("onboarded", value).apply()

    /** Kurulumda PSN girişi ve PS5 eşlemesi "Şimdilik geç" ile atlandı; eşleme sonra Ayarlar'dan yapılır. */
    var setupSkipped: Boolean
        get() = prefs.getBoolean("setupSkipped", false)
        set(value) = prefs.edit().putBoolean("setupSkipped", value).apply()

    var target: SubtitleTarget
        get() = enumOr(prefs.getString("target", null), SubtitleTarget.TV)
        set(value) = prefs.edit().putString("target", value.name).apply()

    var engine: EngineChoice
        get() = enumOr(prefs.getString("engine", null), EngineChoice.FREE)
        set(value) = prefs.edit().putString("engine", value.name).apply()

    /**
     * Hizmetin seçili yapay zekâ modeli (ai-models.json'daki kimlik); kayıt yoksa ya da listede yoksa listenin ilki
     * (varsayılan) kullanılır. Adlar Mac/iPhone UserSettings ile aynı: geminiModel, openAIModel, claudeModel.
     */
    fun aiModel(provider: AiProvider): String? = prefs.getString(modelKey(provider), null)
    fun setAiModel(provider: AiProvider, id: String) = prefs.edit().putString(modelKey(provider), id).apply()

    /**
     * Ayarlardaki "Ek talimat" (#306): yapay zekâ çevirmeninin sistem talimatının sonuna eklenir; boşsa hiçbir şey
     * değişmez. Ad iPhone UserSettings ile aynı: aiInstruction.
     */
    var aiInstruction: String
        get() = prefs.getString("aiInstruction", null).orEmpty()
        set(value) = prefs.edit().putString("aiInstruction", value.trim()).apply()

    private fun modelKey(provider: AiProvider) = when (provider) {
        AiProvider.GEMINI -> "geminiModel"
        AiProvider.OPENAI -> "openAIModel"
        AiProvider.CLAUDE -> "claudeModel"
    }

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

    /** Oynanan oyun paketle tanınmazsa çeviri başladıktan iki dakika sonra bir kez sorulur (bkz. GameSense). */
    var askGame: Boolean
        get() = prefs.getBoolean("askGame", true)
        set(value) = prefs.edit().putBoolean("askGame", value).apply()

    /** Altyazıdaki konuşan adı ("ARTHUR: …") çeviride gösterilir; kapalıysa yalnız Türkçe cümle görünür. */
    var showSpeakerNames: Boolean
        get() = prefs.getBoolean("showSpeakerNames", true)
        set(value) = prefs.edit().putBoolean("showSpeakerNames", value).apply()

    /**
     * "Bilinen oyunlarda hazır alanları kullan": tabloda satırı olan oyunda (GTA 6) yardım kutusu ve mesajlar
     * kendiliğinden okunur ([com.couchsubs.mobile.core.GameAreaPresets]). Eski kayıtlarda yoktur; açık başlar.
     */
    var gameAreaPresets: Boolean
        get() = prefs.getBoolean("gameAreaPresets", true)
        set(value) = prefs.edit().putBoolean("gameAreaPresets", value).apply()

    /**
     * "Ekran yazılarını otomatik çevir": ekranda beliren yazı kutuları (görev, yardım, mesaj) bulunup kendi yerinde
     * çevrilir; oyundan bağımsızdır. Deneysel: varsayılan kapalı (beta.63'te açık geliyordu; oyun dünyasındaki poster ve
     * plakaları da çeviriyordu). Kullanıcı Ayarlar'dan açar. Değiştirilince göç bilgisi kalkar.
     */
    var autoScreenText: Boolean
        get() = prefs.getBoolean("autoScreenText", false)
        set(value) {
            prefs.edit().putBoolean("autoScreenText", value).apply()
            autoScreenTextNotice = false
        }

    init {
        migrateAutoScreenText()
    }

    /**
     * Bir kerelik göç (Windows AutoScreenTextMigration, Mac/iPhone migratingAutoScreenText ile aynı kural): işaret yoksa
     * ayar kapatılır, işaret konur. Ayar açıktıysa (beta.63'te açık kaydedilmiş ya da hiç değiştirilmemiş eski kurulum)
     * bu süreçte bir kez "deneysel; Ayarlar'dan açabilirsiniz" bilgisi gösterilir. Yeni kurulumda bilgi yok.
     */
    private fun migrateAutoScreenText() {
        val stored = if (prefs.contains("autoScreenText")) prefs.getBoolean("autoScreenText", false) else null
        val step = AutoScreenTextMigration.apply(prefs.getBoolean("autoScreenTextReset", false), stored, prefs.all.isNotEmpty())
            ?: return
        prefs.edit().putBoolean("autoScreenText", false).putBoolean("autoScreenTextReset", true).apply()
        if (step.notice) autoScreenTextNotice = true
    }

    /**
     * "Ekran yazılarını altyazıdan ayır": ek alan ve otomatik ekran yazısı kutuları özgün rengini ve zeminini korur,
     * altyazı kutusuna benzemez (zemin yoksa zeminsiz, koyu gölgeli). Eski kayıtlarda yoktur; açık başlar.
     */
    var setTextApart: Boolean
        get() = prefs.getBoolean("setTextApart", true)
        set(value) = prefs.edit().putBoolean("setTextApart", value).apply()

    /** "Konuşana göre renk": konuşan adlı satır (ad ve cümle) o konuşanın renginde görünür. Eski kayıtlarda yoktur; açık başlar. */
    var speakerColors: Boolean
        get() = prefs.getBoolean("speakerColors", true)
        set(value) = prefs.edit().putBoolean("speakerColors", value).apply()

    /**
     * Xbox ev yayınında oyunun sesi bu telefonda çalınır. Xbox uzaktan oynatma sürerken sesi istemciye verip TV'yi
     * susturabilir; kapalıyken ses hiçbir yerden gelmeyebilir, bu yüzden varsayılan açık. PS5'i etkilemez.
     */
    var xboxAudioOnDevice: Boolean
        get() = prefs.getBoolean("xboxAudioOnDevice", true)
        set(value) = prefs.edit().putBoolean("xboxAudioOnDevice", value).apply()

    /** Değişmeyen altyazı bölgesi 20 yerine en fazla 2 kare yeniden kullanılır (Mac/Windows ile aynı); varsayılan kapalı. */
    var fastSubtitleDetection: Boolean
        get() = prefs.getBoolean("fastSubtitleDetection", false)
        set(value) = prefs.edit().putBoolean("fastSubtitleDetection", value).apply()

    /** Bu PS5'te son seçilen oyun ("Hangi oyunu oynuyorsunuz?" kartının ilk önerisi). */
    fun lastGame(console: String): String? = prefs.getString("lastGame.$console", null)

    fun rememberGame(console: String, name: String) = prefs.edit().putString("lastGame.$console", name).apply()

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

    /** TV'deki altyazı kutusunun koyuluğu, yüzde (100: tamamen opak; oyundaki İngilizce yazıyı kapatır). */
    var tvBackground: Int
        get() = prefs.getInt("tvBackground", 90).coerceIn(0, 100)
        set(value) = prefs.edit().putInt("tvBackground", value.coerceIn(0, 100)).apply()

    var tvBackgroundShape: com.couchsubs.mobile.core.SubtitleBackgroundShape
        get() = enumOr(prefs.getString("tvBackgroundShape", null), com.couchsubs.mobile.core.SubtitleBackgroundShape.FIT)
        set(value) = prefs.edit().putString("tvBackgroundShape", value.name).apply()

    /** Hızlı konuşmada önceki satırları üstte tut: varsayılan açık (Windows, Mac ve iPhone ile aynı). */
    var stackPrevious: Boolean
        get() = prefs.getBoolean("stackPrevious", true)
        set(value) = prefs.edit().putBoolean("stackPrevious", value).apply()

    /**
     * Android TV'de PS5 görüntüsünün nasıl gösterileceği. Bazı TV'lerde (ör. TCL) uygulama içindeki görüntü siyah kalıyor;
     * Katman'da TV, PS5'i kendi HDMI girişinde gösterir, altyazı üstte çıkar (Mac, Windows ve iPhone ile aynı seçim).
     */
    var tvDisplayMode: com.couchsubs.mobile.core.TvDisplayMode
        get() = enumOr(prefs.getString("tvDisplayMode", null), com.couchsubs.mobile.core.TvDisplayMode.IN_APP)
        set(value) = prefs.edit().putString("tvDisplayMode", value.name).apply()

    /**
     * TV'de çevirinin yeri: İngilizce altyazının üstünü örtsün (varsayılan), üstünde, altında ya da sabit yükseklikte.
     * Üstünde/altında seçilince oyundaki İngilizce altyazı da görünür (Mac ve Windows'taki Yeri seçimi, iPhone ile aynı).
     */
    var tvPlacement: SubtitlePlacement
        get() = enumOr(prefs.getString("tvPlacement", null), SubtitlePlacement.COVER)
        set(value) = prefs.edit().putString("tvPlacement", value.name).apply()

    /** Sabit yerdeyken altyazının ekranın altından yüksekliği, yüzde (0-85; TV uygulamasıyla aynı sınır). */
    var tvBottomPercent: Int
        get() = prefs.getInt("tvBottomPercent", 7).coerceIn(0, 85)
        set(value) = prefs.edit().putInt("tvBottomPercent", value.coerceIn(0, 85)).apply()

    /** TV'deki yazı boyu: 36, 46, 58, 72. */
    var tvFontSize: Int
        get() = prefs.getInt("tvFontSize", 46)
        set(value) = prefs.edit().putInt("tvFontSize", value).apply()

    /**
     * TV'ye giden görünüm. Yazı boyu Ayarlar › Altyazı görünümündeki ölçekle TV'deki varsayılana (46) göre büyür
     * (iPhone ile aynı: %120 → 55); eskiden ölçek yalnız telefon ekranını değiştiriyor, TV hep 46 kalıyordu.
     */
    val style: SubtitleStyle
        get() = SubtitleStyle(fontSize = scaledFontSize(tvFontSize, subtitleScale), placement = tvPlacement,
            bottomPercent = tvBottomPercent, background = tvBackground, backgroundShape = tvBackgroundShape, textColor = textColor, stackPrevious = stackPrevious,
            displayMode = tvDisplayMode)

    /** Altyazının arandığı bölge (Ayarlar › Altyazı alanı; iPhone ile aynı hazır seçimler ve Özel). */
    var region: com.couchsubs.mobile.core.CropRegion
        get() = com.couchsubs.mobile.core.cropRegionFrom(prefs.getString("region", null)?.let { runCatching { JSONObject(it) }.getOrNull() })
            ?: com.couchsubs.mobile.core.CropRegion()
        set(value) = prefs.edit().putString("region", value.toJson().toString()).apply()

    var areaPreset: com.couchsubs.mobile.core.AreaPreset
        get() = prefs.getString("areaPreset", null)?.let { name -> runCatching { com.couchsubs.mobile.core.AreaPreset.valueOf(name) }.getOrNull() }
            ?: com.couchsubs.mobile.core.AreaPreset.matching(region)
        set(value) = prefs.edit().putString("areaPreset", value.name).apply()

    /**
     * "Ortada tut": altyazı alanının çerçevesi kenarından boyutlandırılırken karşı kenar da aynı kadar oynar, alan ortalı
     * kalır (oyunların çoğu altyazıyı ortalar). Kapalıysa yalnız tutulan kenar oynar (sola yaslı ya da köşedeki altyazı).
     * Eski kayıtlarda yoktur; açık başlar (iPhone: keepAreaCentered, Windows: KeepAreaCentered).
     */
    var keepAreaCentered: Boolean
        get() = prefs.getBoolean("keepAreaCentered", true)
        set(value) = prefs.edit().putBoolean("keepAreaCentered", value).apply()

    /** Hazır seçim: bölgesi de kaydedilir (Özel'de kayıtlı bölge kalır). */
    fun selectAreaPreset(preset: com.couchsubs.mobile.core.AreaPreset) {
        preset.region?.let { region = it }
        areaPreset = preset
    }

    fun setCustomRegion(value: com.couchsubs.mobile.core.CropRegion) {
        region = value
        areaPreset = com.couchsubs.mobile.core.AreaPreset.CUSTOM
    }

    /** Altyazının yanında sürekli okunan ek alanlar (görev, bildirim, telefon; en çok üç). Varsayılan: hiç yok. */
    var extraAreas: List<com.couchsubs.mobile.core.ExtraArea>
        get() = com.couchsubs.mobile.core.ExtraArea.listFromJson(prefs.getString("extraAreas", null))
        set(value) = prefs.edit().putString("extraAreas", com.couchsubs.mobile.core.ExtraArea.listToJson(value.take(com.couchsubs.mobile.core.ExtraArea.MAX_COUNT))).apply()

    /** Şu an okunan alanlar (altyazı alanı, hazır seçimi ve ek alanlar); oyuna göre alanlar bunu değiştirir. */
    override var areas: AreaSet
        get() = AreaSet(region, areaPreset, extraAreas)
        set(value) = prefs.edit()
            .putString("region", value.region.toJson().toString())
            .putString("areaPreset", value.areaPreset.name)
            .putString("extraAreas", com.couchsubs.mobile.core.ExtraArea.listToJson(value.extraAreas.take(com.couchsubs.mobile.core.ExtraArea.MAX_COUNT)))
            .apply()

    /** Oyuna göre kaydedilmiş alanlar (son kullanılan sonda, en çok [AreaProfiles.MAX_COUNT]). Eski kurulumlarda boş. */
    override var areaProfiles: List<AreaProfile>
        get() = AreaProfile.listFromJson(prefs.getString("areaProfiles", null))
        set(value) = prefs.edit().putString("areaProfiles", AreaProfile.listToJson(value.takeLast(AreaProfiles.MAX_COUNT))).apply()

    override var activeAreaProfile: String?
        get() = prefs.getString("activeAreaProfile", null)
        set(value) = prefs.edit().apply { if (value == null) remove("activeAreaProfile") else putString("activeAreaProfile", value) }.apply()

    override var generalAreas: AreaSet?
        get() = AreaSet.fromJson(prefs.getString("generalAreas", null)?.let { runCatching { JSONObject(it) }.getOrNull() })
        set(value) = prefs.edit().apply { if (value == null) remove("generalAreas") else putString("generalAreas", value.toJson().toString()) }.apply()

    /**
     * Bölge, hazır seçimi ya da ek alanlar değişince (çeviri sürerken yeni bölge hemen okunur). Hazır seçim de dinlenir:
     * Tam ekran seçilince ek alanlar okunmaz, başka seçime dönünce yeniden okunur.
     */
    fun onAreasChanged(action: () -> Unit): SharedPreferences.OnSharedPreferenceChangeListener {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == "region" || key == "areaPreset" || key == "extraAreas" || key == "activeAreaProfile" || key == "gameAreaPresets") action()
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        return listener
    }

    /**
     * Altyazının gideceği yer (TV ya da telefon) değişince çağrılır. Çeviri sürerken Ayarlar'dan TV seçilir ya da
     * telefondan TV uygulaması kurulursa altyazı hemen TV'ye gider (iPhone: outputChanged ile aynı). Eskiden yeni seçim
     * ancak çeviri yeniden başlayınca geçerli oluyordu: TV bağlı göründüğü halde altyazı yalnız telefonda kalıyordu.
     */
    fun onTargetChanged(action: () -> Unit): SharedPreferences.OnSharedPreferenceChangeListener {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == "target") action()
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        return listener
    }

    /** Görünüm ayarı değişince (ölçek, renk) çağrılır; çeviri sürerken TV'ye yeni görünüm gider. */
    fun onStyleChanged(action: () -> Unit): SharedPreferences.OnSharedPreferenceChangeListener {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == "subtitleScale" || key == "textColor" || key == "tvFontSize" ||
                key == "tvBackground" || key == "tvBackgroundShape" || key == "stackPrevious" || key == "tvDisplayMode" ||
                key == "tvPlacement" || key == "tvBottomPercent") action()
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        return listener
    }

    fun removeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.unregisterOnSharedPreferenceChangeListener(listener)

    companion object {
        /** Otomatik ekran yazısı bu süreçte göçle kapatıldı: ana ekranda bir kez bilgi görünür. */
        @Volatile
        var autoScreenTextNotice = false
        /**
         * Yazı ölçeğinin sınırları, yüzde (iPhone ile aynı). Alt sınır eskiden %80'di (TV'de 37 piksel); TV'de en küçüğü
         * bile büyük kalıyordu (#218). %40, TV'de 18 piksel: Mac'teki (20) ve Windows'taki (16) en küçük boya denk.
         */
        const val MIN_SUBTITLE_SCALE = 40
        const val MAX_SUBTITLE_SCALE = 160

        /** Yüzde ölçekle yazı boyu (yuvarlanır). */
        fun scaledFontSize(base: Int, percent: Int): Int =
            Math.round(base * percent.coerceIn(MIN_SUBTITLE_SCALE, MAX_SUBTITLE_SCALE) / 100.0).toInt()
    }

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

    /** Konsol türü; seçilmediyse null (kurulumda sorulur). Eski kurulumlar PlayStation sayılır. */
    var platformChoice: ConsolePlatform?
        get() = prefs.getString("platform", null)?.let { name -> ConsolePlatform.entries.firstOrNull { it.name == name } }
        set(value) = prefs.edit().putString("platform", value?.name).apply()

    val platform: ConsolePlatform get() = platformChoice ?: ConsolePlatform.PLAYSTATION
    val xbox: Boolean get() = platform == ConsolePlatform.XBOX

    /** Microsoft kullanıcı jetonu (Windows'taki userToken JSON'u); Keystore ile şifreli. */
    var xboxUserToken: String?
        get() = secrets.get("xboxUserToken")
        set(value) = secrets.put("xboxUserToken", value)

    /** Seçilen Xbox (kimlik, ad). */
    var xboxConsole: com.couchsubs.mobile.xbox.XboxConsole?
        get() = com.couchsubs.mobile.xbox.XboxConsole.fromJson(prefs.getString("xboxConsole", null))
        set(value) = prefs.edit().putString("xboxConsole", value?.toJson()).apply()

    /** İkinci hesabın PS5 giriş şifresi (4 hane, isteğe bağlı); PS5 isterse oturum açılırken gönderilir. */
    var loginPasscode: String?
        get() = LoginPasscode.normalized(secrets.get("loginPasscode"))
        set(value) = secrets.put("loginPasscode", LoginPasscode.normalized(value))

    /** Hedef seçiminde görülen TV'nin adı (ana ekrandaki "Altyazı · Salon TV"). */
    var tvName: String?
        get() = prefs.getString("tvName", null)
        set(value) = prefs.edit().putString("tvName", value).apply()

    /** Son okuma oturumunun süresi (ms). */
    var lastSessionMs: Long
        get() = prefs.getLong("lastSessionMs", 0)
        set(value) = prefs.edit().putLong("lastSessionMs", value).apply()

    /** Çeviri sürerken son yazılan sağlık satırı (SessionHealth); süreç ölürse kapanış raporuna eklenir. */
    var lastHealth: String?
        get() = prefs.getString("lastHealth", null)
        set(value) = prefs.edit().putString("lastHealth", value).apply()

    /** Çeviri hizmeti çalışıyor mu; süreç ölünce true kalır, sonraki açılışta kapanışın çeviri sırasında olduğu anlaşılır. */
    var translating: Boolean
        get() = prefs.getBoolean("translating", false)
        set(value) = prefs.edit().putBoolean("translating", value).apply()

    /** Son raporlanan önceki kapanışın anı (ApplicationExitInfo.timestamp; bkz. ExitReport). */
    var lastExitReportAt: Long
        get() = prefs.getLong("lastExitReportAt", 0)
        set(value) = prefs.edit().putLong("lastExitReportAt", value).apply()

    /** Altyazı yazı ölçeği, yüzde (40–160; tasarım: Ayarlar › Altyazı görünümü). */
    var subtitleScale: Int
        get() = prefs.getInt("subtitleScale", 100).coerceIn(MIN_SUBTITLE_SCALE, MAX_SUBTITLE_SCALE)
        set(value) = prefs.edit().putInt("subtitleScale", value.coerceIn(MIN_SUBTITLE_SCALE, MAX_SUBTITLE_SCALE)).apply()

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

    /** Kurulum ekranında son seçilen marka; hiç seçilmediyse null (ekran ağda bulduğu TV'nin markasını seçer). */
    var tvInstallBrand: TvBrand?
        get() = prefs.getString("experimental.tvInstallBrand", null)?.let { runCatching { enumValueOf<TvBrand>(it) }.getOrNull() }
        set(value) = prefs.edit().putString("experimental.tvInstallBrand", value?.name).apply()

    /**
     * Bu telefonun TV uygulamasını kurduğu (ya da sürümüne baktığı) TV: marka, adres ve TV'deki sürüm. Uygulama açılınca
     * ve TV her bağlandığında bu TV'deki sürüme bakılır; telefondaki paketten eskiyse güncelleme önerilir.
     */
    /**
     * TV uygulamasının daha önce bağlandığı Samsung TV'nin adresi: o TV'de uygulamanın kurulu olduğu bilinir, açma
     * komutundan önce TV'nin kurulu uygulama listesine bakılmaz (bkz. TvSessionLauncher.samsungKnownInstalled).
     */
    var samsungAppSeenHost: String?
        get() = prefs.getString("tvApp.samsungSeenHost", null)
        set(value) = prefs.edit().putString("tvApp.samsungSeenHost", value).apply()

    var installedTv: InstalledTv?
        get() {
            val brand = prefs.getString("tvApp.brand", null)?.let { runCatching { enumValueOf<TvBrand>(it) }.getOrNull() } ?: return null
            val host = prefs.getString("tvApp.host", null)?.takeIf { it.isNotBlank() } ?: return null
            return InstalledTv(brand, host, prefs.getInt("tvApp.port", 0), prefs.getString("tvApp.version", null))
        }
        set(value) = prefs.edit().apply {
            if (value == null) listOf("tvApp.brand", "tvApp.host", "tvApp.port", "tvApp.version").forEach { remove(it) }
            else putString("tvApp.brand", value.brand.name).putString("tvApp.host", value.host).putInt("tvApp.port", value.port)
                .putString("tvApp.version", value.version)
        }.apply()

    /** LG geliştirici modu için son başarılı uzatma zamanı (ms), TV adresine göre saklanır. */
    fun lgSessionRenewedAt(host: String): Long? {
        val key = LgSessionRenewalPolicy.storageKey(host)
        return if (prefs.contains(key)) prefs.getLong(key, 0L) else null
    }

    fun setLgSessionRenewedAt(host: String, value: Long) {
        prefs.edit().putLong(LgSessionRenewalPolicy.storageKey(host), value).apply()
    }

    fun apiKey(engine: EngineChoice): String? = secrets.get("key." + engine.name)
    fun setApiKey(engine: EngineChoice, key: String?) = secrets.put("key." + engine.name, key?.trim())

    private inline fun <reified T : Enum<T>> enumOr(name: String?, fallback: T): T =
        name?.let { runCatching { enumValueOf<T>(it) }.getOrNull() } ?: fallback
}
