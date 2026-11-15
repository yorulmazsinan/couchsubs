// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.translation

import com.couchsubs.mobile.core.TextTranslator
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import java.io.IOException
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Ücretsiz, cihaz üstü çeviri: Google ML Kit EN→TR (model yaklaşık 30 MB, ilk kullanımda bir kez iner; sonra internetsiz
 * çalışır). iPhone ve Mac'teki ücretsiz metin hattıyla aynı ([FreeLineTranslator]): cümle cümle çevrilir, terim sözlüğü
 * korunur, kısa satır önceki cümleyle çevrilir, oyun deyimleri düz İngilizceye döner, Türkçe düzeltmeler yapılır.
 * [cache]: kalıcı önbellek (önceki oturumlarda çevrilmiş cümleler hiç çevrilmeden döner).
 */
class MlKitTranslator(
    private val cache: TranslationCache = TranslationCache(),
    private val glossary: Glossary = Glossary.Empty,
) : TextTranslator, AutoCloseable {
    companion object {
        /** Kalıcı önbellek dosyasındaki motor adı; metin hattı değişince ([FreeTranslation.PIPELINE_VERSION]) bu da değişir. */
        const val ENGINE_ID = "mlkit-p${FreeTranslation.PIPELINE_VERSION}"
    }

    private val translator = Translation.getClient(
        TranslatorOptions.Builder().setSourceLanguage(TranslateLanguage.ENGLISH).setTargetLanguage(TranslateLanguage.TURKISH).build()
    )
    private val line = FreeLineTranslator(cache, glossary, engine = ::machine)

    /** Model yoksa indirir (bloklar). [wifiOnly]: hücresel veride indirme. */
    fun prepare(wifiOnly: Boolean = false, timeoutSeconds: Long = 300) {
        val conditions = DownloadConditions.Builder().apply { if (wifiOnly) requireWifi() }.build()
        await(translator.downloadModelIfNeeded(conditions), timeoutSeconds)
    }

    override fun translate(text: String): String = line.translate(text)

    /**
     * Aynı modeli ve önbelleği kullanan, kendi satır bağlamı olan çevirmen (ek alanlar için: görev yazısı altyazının
     * kısa satırına bağlam olmasın).
     */
    fun separate(): TextTranslator = FreeLineTranslator(cache, glossary, engine = ::machine)

    /** Hazır metni ML Kit'e verir. */
    private fun machine(input: String): String = await(translator.translate(input), 10)

    override fun close() = translator.close()

    private fun <T> await(task: com.google.android.gms.tasks.Task<T>, seconds: Long): T = try {
        Tasks.await(task, seconds, TimeUnit.SECONDS)
    } catch (error: ExecutionException) {
        throw IOException("ML Kit: ${error.cause?.message}", error.cause)
    } catch (error: TimeoutException) {
        throw IOException("ML Kit timeout", error)
    }
}
