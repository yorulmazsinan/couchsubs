// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * GTA 6 telefonunun otomatik okumasında önceden günlüğe hiçbir şey yazmayan yollar (#1251): telefon açıldı/kapandı, telefon
 * oynadığı için açılmadı, eğik ekranın düzeltilmiş okuması boş geldi (tur atlama satırları Mac/iPhone ve Windows'ta; Android'de
 * kare yalnız izleyici telefonu bulduğunda alınır). Satırlar [DropLog] ile sınırlıdır (aynı satır 60 sn'de bir, dakikada en
 * çok 20). Windows (PhoneTrace.cs) ve Mac/iPhone (PhoneTrace.swift) aynı metinler.
 */
object PhoneTrace {
    const val COMPONENT = "PhoneTrace"
    const val OPENED = "telefon açıldı"
    const val CLOSED = "telefon kapandı"

    /** Telefon kapandı: kaç ms görülmedi, kaç örnekte bulunamadı (#1334: çevirinin kalkma gecikmesi günlükte görünsün). */
    fun closed(afterMs: Long, misses: Int) = "$CLOSED ($afterMs ms görülmedi, $misses ıska)"
    const val MISSING = "PhoneMissing: telefon bu karede bulunamadı, tur atlandı"
    const val EMPTY_FLAT = "eğik ekran düzeltilmiş okuması boş"

    /** Telefon bulundu ama önceki örnekten çok oynadı; iki uyumlu gözlem olmadığı için açılmadı. */
    fun moving(share: Double) = "telefon oynuyor, açılmadı (%${percent(share)} oynama)"

    /** Okunacak karede telefon izlenen yerden çok uzakta: tur atlandı. */
    fun displaced(share: Double) = "telefon karede yerinde değil, tur atlandı (%${percent(share)} oynama)"

    /** Oranın yüzdesi (tam sayı). */
    fun percent(share: Double): Int = (share * 100).roundToInt()

    /** İki bölgenin en çok oynayan kenarı (kareye oranla). */
    fun shift(a: CropRegion, b: CropRegion): Double =
        max(max(abs(a.top - b.top), abs(a.bottom - b.bottom)), max(abs(a.left - b.left), abs(a.right - b.right)))
}
