// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.translation

import com.couchsubs.mobile.core.SubtitleSegmenter
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
 * çalışır). Masaüstündeki yerel modeldeki gibi cümle cümle çevrilir, konuşmacı etiketi ve tireler olduğu gibi kalır.
 */
class MlKitTranslator : TextTranslator, AutoCloseable {
    private val translator = Translation.getClient(
        TranslatorOptions.Builder().setSourceLanguage(TranslateLanguage.ENGLISH).setTargetLanguage(TranslateLanguage.TURKISH).build()
    )
    private val cache = TranslationCache()

    /** Model yoksa indirir (bloklar). [wifiOnly]: hücresel veride indirme. */
    fun prepare(wifiOnly: Boolean = false, timeoutSeconds: Long = 300) {
        val conditions = DownloadConditions.Builder().apply { if (wifiOnly) requireWifi() }.build()
        await(translator.downloadModelIfNeeded(conditions), timeoutSeconds)
    }

    override fun translate(text: String): String {
        cache.get(text)?.let { return it }
        val pieces = SubtitleSegmenter.split(text)
        val result = pieces.joinToString("") { piece ->
            if (!piece.translate) piece.text
            else cache.get(piece.text) ?: await(translator.translate(SubtitleSegmenter.normalizeCase(piece.text)), 10)
                .also { cache.store(piece.text, it) }
        }
        cache.store(text, result)
        return result
    }

    override fun close() = translator.close()

    private fun <T> await(task: com.google.android.gms.tasks.Task<T>, seconds: Long): T = try {
        Tasks.await(task, seconds, TimeUnit.SECONDS)
    } catch (error: ExecutionException) {
        throw IOException("ML Kit: ${error.cause?.message}", error.cause)
    } catch (error: TimeoutException) {
        throw IOException("ML Kit timeout", error)
    }
}
