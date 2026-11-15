// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv

import android.content.Context
import java.io.File

/**
 * Uygulamayla gelen TV paketleri (derlemede son GitHub sürümünden indirilir, bkz. build.gradle tvReleasePackages):
 * `assets/tv/tv-packages.properties` hangi sürümden geldiklerini yazar.
 */
object TvPackages {
    const val ANDROID_TV_APK = "couchsubs-androidtv.apk"
    private const val INDEX = "tv/tv-packages.properties"

    /** `anahtar=değer` satırları. */
    fun parse(text: String): Map<String, String> = text.lineSequence().map { it.trim() }
        .filter { it.isNotEmpty() && !it.startsWith("#") && '=' in it }
        .associate { it.substringBefore('=').trim() to it.substringAfter('=').trim() }

    fun index(context: Context): Map<String, String> =
        runCatching { context.assets.open(INDEX).use { parse(String(it.readBytes(), Charsets.UTF_8)) } }.getOrDefault(emptyMap())

    const val LG_IPK = "couchsubs-lg.ipk"

    /** LG paketi, sürümdeki adı (`com.couchsubs.tv_0.9.18_all.ipk`) ve sürümü; paket yoksa null. */
    fun lg(context: Context): Triple<ByteArray, String, String>? {
        val name = index(context)[LG_IPK] ?: return null
        val version = com.couchsubs.mobile.tv.lg.LgInstaller.versionOfPackage(name) ?: return null
        return runCatching { context.assets.open("tv/$LG_IPK").use { it.readBytes() } }.getOrNull()?.let { Triple(it, name, version) }
    }

    /** Android TV paketi ve sürümü (APK'nın kendisinden okunur); paket yoksa null. */
    fun androidTv(context: Context): Pair<File, String?>? {
        if (ANDROID_TV_APK !in index(context)) return null
        val file = File(context.cacheDir, ANDROID_TV_APK)
        return try {
            context.assets.open("tv/$ANDROID_TV_APK").use { input -> file.outputStream().use { input.copyTo(it) } }
            file to context.packageManager.getPackageArchiveInfo(file.path, 0)?.versionName
        } catch (error: Exception) {
            null
        }
    }
}
