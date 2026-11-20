// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Ekranda zaten Türkçe olan satır (PS5'in Türkçe arayüzü): hedef dil Türkçeyken çevirmene gönderilmez (#289). Yazı
 * tanıma Türkçe harfleri bozduğu için ("Sistem Yazillml Güncellem€") çeviriden sonraki "aslıyla aynı" denetimi bu
 * satırları kaçırıyordu: motor bozuk harfleri düzeltip farklı bir metin döndürünce satır yeniden gösteriliyordu. Ölçüt
 * temkinlidir: Türkçe harf ve bilinen bir Türkçe sözcük birlikte bulunmalı; içinde Türkçe ad geçen İngilizce satır
 * ("Atatürk said...") çevrilir. Windows'taki TurkishText.cs ve Mac'teki TurkishText.swift ile aynı kurallar.
 */
object TurkishText {
    /** Türkçe harfler (ü, ö, ç İngilizce satırda ancak yabancı adda geçer; tek başına yetmez). */
    private val letters = setOf('ğ', 'Ğ', 'ş', 'Ş', 'ı', 'İ', 'ü', 'Ü', 'ö', 'Ö', 'ç', 'Ç')

    /**
     * Havuz süzgecinin sözcüklerine ek, Türkçe arayüzde sık geçen ve İngilizcede olmayan sözcükler (katlanmış hâlleriyle
     * karşılaştırılır; "sistem" yok: katlanınca İngilizce "system" ile bir harf farklı).
     */
    internal val commonWords = listOf(
        "daha", "sonra", "simdi", "degil", "haydi", "tamam", "evet", "hayir", "devam", "iptal", "giris", "guncelle",
        "guncellemesi", "yazilimi", "kurulum", "sirasinda", "sisteminizi", "sistemindeki", "kapatmayin", "baglanti",
        "baglantinizi", "uzaktan", "oynama", "dosyasi", "gostergesi", "kablosunu", "bir", "canli", "yayin",
    ).map { PoolFilter.fold(it).joinToString("") }

    private val known by lazy { PoolFilter.turkishWords + commonWords }

    /**
     * Tek sözcük, Türkçe harfi bozulmuş olsa da bilinen bir Türkçe sözcük mü ("Canli": yayın arayüzü). Otomatik ekran
     * yazısındaki kısa etiket içindir; İngilizce sözcük olan etiketler ("ON", "MAP") bu listede yoktur.
     */
    fun isKnownWord(text: String): Boolean = PoolFilter.fold(text).singleOrNull()?.let { it in known } ?: false

    /** Satır yüksek güvenle Türkçe mi: en az bir Türkçe harf ve en az bir bilinen Türkçe sözcük. */
    fun isSure(text: String): Boolean {
        if (text.none { it in letters }) return false
        return PoolFilter.fold(text).any { word -> known.any { PoolFilter.isClose(word, it) } }
    }
}
