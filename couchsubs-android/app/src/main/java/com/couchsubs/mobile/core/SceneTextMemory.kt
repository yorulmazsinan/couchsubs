// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Az önce sahne yazısı sayılıp atılan satır (plaka, tabela, telefon mesajı) bir sonraki karede başka okununca altyazı
 * olmaz. Altyazı kapısı ([SceneText], [Reading.subtitleBlock], telefon süzgeci) her kareye ayrı karar verir; yazı tanıma
 * aynı tabelayı kare kare başka okuduğu için bir karede atılan yazı ötekinde kuralın dışında kalıp çevriliyordu.
 * Kullanıcı bildirimi (#1411, GTA 6, Mac, beta-105, "Ekran yazılarını otomatik çevir" ve telefon okuması kapalı):
 * plakanın "GOOD TIME STATE" yazısı çoğu karede "plaka/tabela" sayılıp atılıyor, "NECE / & COCOTIME STATE O." okunan
 * karede ise çevriliyordu; telefon bir karede bulunup mesajı atıldıktan sonra telefon ıskalanınca aynı mesaj altyazı
 * olarak çevriliyordu; sola yaslı sohbet mesajı bir karede "menü açıklaması" sayılıp ötekinde çevriliyordu.
 * Güvenilir nedenle ([remembers]) atılan satırlar [HOLD_MS] boyunca hatırlanır; okumadaki satır onlardan birine
 * [SIMILARITY] oranında benziyorsa altyazı bloğu seçilmeden çıkarılır. Kamerayla kayan yazı, düşük güven, ortadaki kısa
 * satır, ürün yazısı ve menü listesi hatırlanmaz; [MIN_LETTERS] harften kısa satır ne hatırlanır ne çıkarılır,
 * [EXACT_LETTERS] harften kısa satır yalnız harfleri birebir aynıysa çıkarılır; konuşan adlı satır hiç çıkarılmaz; süre
 * her atılışta tazelenir. Mac/iPhone (SceneTextMemory.swift) ve Windows (SceneTextMemory.cs) aynı kuralları ve eşikleri
 * uygular; ortak deneme dosyası fixtures/scene-text-memory.json.
 */
class SceneTextMemory {
    companion object {
        /** Atılan satır bu kadar süre hatırlanır (son atılışından). */
        const val HOLD_MS = 8000L
        /** Boşluklar dışında en az bu kadar harf/rakamlı satır hatırlanır ve karşılaştırılır. */
        const val MIN_LETTERS = 5
        /** Bu kadar harften kısa satırlar yalnız harfleri (boşluksuz) birebir aynıysa aynı yazı sayılır. */
        const val EXACT_LETTERS = 10
        /** Sadeleştirilmiş iki satırın Levenshtein benzerliği bu orandan azsa aynı yazı sayılmaz. */
        const val SIMILARITY = 0.75
        /** En çok bu kadar satır hatırlanır (en eskisi düşer). */
        const val CAPACITY = 40
        /** Telefonun ekranında okunup atılan satırın nedeni. */
        const val PHONE_REASON = "telefon yazısı"
        /** Günlükte atılma nedeni (ardından ilk atılışın nedeni yazılır). */
        const val REASON = "az önce sahne yazısı sayılan satırın yeniden okunuşu"

        private val REMEMBERED = setOf(
            SceneText.SIGN_REASON, SceneText.NUMBER_REASON, SceneText.PLATE_NUMBER_REASON, SceneText.MENU_ITEM_REASON,
            SceneText.TILTED_REASON, InkTone.REASON, Reading.OFF_BAND_REASON, PHONE_REASON,
        )

        /** Bu nedenle atılan satır hatırlanır mı. */
        fun remembers(reason: String) = reason in REMEMBERED

        private fun letters(key: String) = key.replace(" ", "")
        private fun isLongEnough(key: String) = letters(key).length >= MIN_LETTERS
    }

    private data class Entry(val text: String, val reason: String, val seenAt: Long)

    private val entries = mutableListOf<Entry>()

    /** Son [filter] çağrısında çıkarılan satırlar ve ilk atılışlarının nedeni (günlük için). */
    var removed: List<Pair<TextLine, String>> = emptyList()
        private set

    /** Atılan satırları hatırlar ([reason] hatırlanan nedenlerden değilse hiçbir şey yapmaz). [time]: milisaniye saati. */
    fun remember(lines: List<String>, reason: String, time: Long) {
        if (!remembers(reason)) return
        for (line in lines) {
            val key = TextMatch.normalize(line)
            if (!isLongEnough(key)) continue
            entries.removeAll { it.text == key }
            entries.add(Entry(key, reason, time))
        }
        while (entries.size > CAPACITY) entries.removeAt(0)
    }

    /** Okumanın az önce atılan satırlara benzeyenleri çıkarılmış hali. */
    fun filter(reading: Reading, time: Long): Reading {
        val out = mutableListOf<Pair<TextLine, String>>()
        removed = out
        entries.removeAll { time - it.seenAt > HOLD_MS || time < it.seenAt }
        if (entries.isEmpty()) return reading
        val kept = mutableListOf<TextLine>()
        for (line in reading.lines) {
            val entry = match(line.text)
            if (entry != null) out.add(line to entry.reason) else kept.add(line)
        }
        return if (out.isEmpty()) reading else Reading(kept)
    }

    /** Bu nedenle hatırlanan satırları unutur (oyunun altyazısı koyu yazı sayılınca [InkTone.REASON]). */
    fun forget(reason: String) {
        entries.removeAll { it.reason == reason }
    }

    fun reset() {
        entries.clear()
        removed = emptyList()
    }

    /** Satırın benzediği hatırlanan satır (en yenisi); yoksa null. */
    private fun match(text: String): Entry? {
        if (SpeakerPrefix.split(text) != null) return null
        val key = TextMatch.normalize(text)
        if (!isLongEnough(key)) return null
        val own = letters(key)
        return entries.lastOrNull { entry ->
            val other = letters(entry.text)
            if (own.length < EXACT_LETTERS || other.length < EXACT_LETTERS) own == other
            else TextMatch.isSimilar(key, entry.text, SIMILARITY)
        }
    }
}
