// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * "Ekranı çevir": karenin tamamı bir kez okunur, yazılar yerlerine göre gruplara ayrılır (menü, görev paneli, bilgi
 * kutusu, altyazı...) ve hepsi tek istekte çevrilir. TV ve telefon her çeviriyi kendi İngilizce yazısının üstüne, o
 * yazının boyutunda koyar (Mac/iPhone ScreenTranslation.swift ve Windows ScreenTranslation.cs ile aynı kurallar).
 */
object ScreenTranslation {
    /** Ekrandaki bir yazı grubu. */
    data class Group(
        /** Ayrı ayrı çevrilecek parçalar (başlık, cümle, menü satırı...). */
        val paragraphs: List<String>,
        /** Karedeki yeri, kenarlara oranla. */
        val box: TextBox,
        /** Satırlarının tipik yüksekliği, karenin yüksekliğine oranla; yazı boyu buna göre seçilir. */
        val lineHeight: Double,
    )

    data class Item(
        val source: String,
        /** Parçaların çevirisi, her parça ayrı satırda. */
        val translation: String,
        val box: TextBox,
        val lineHeight: Double,
    ) {
        /** Birden çok parça var: satır satır, sola yaslı gösterilir. */
        val paragraphs: Boolean get() = translation.contains('\n')
    }

    /** Kalabalık ekranda ekranı kutuyla doldurmamak ve çeviriyi uzatmamak için en çok bu kadar grup çevrilir. */
    const val MAX_GROUPS = 30

    /**
     * Grupları sırayla çevirir; her grup çevrilince o ana kadarki sonuçlarla [progress] çağrılır. Çevirisi aslıyla aynı
     * olan (ad, sayı, zaten Türkçe yazı) grup gösterilmez. [cancelled] true dönerse iş bırakılır.
     */
    fun translateGroups(
        reading: Reading, translate: (String) -> String, cancelled: () -> Boolean = { false }, progress: (List<Item>) -> Unit = {},
    ): List<Item> {
        val items = mutableListOf<Item>()
        for (group in groups(reading)) {
            if (cancelled()) return items
            val translated = group.paragraphs.map { translate(it) }
            val item = item(group, translated) ?: continue
            items.add(item)
            progress(items.toList())
        }
        return items
    }

    /**
     * Çevirmen parçaları tek istekte çevirebiliyorsa (yapay zekâ) ekranın bütün parçaları birlikte gider ve sonuç bir
     * kerede gelir; yoksa gruplar sırayla çevrilip hazırlandıkça bildirilir.
     */
    fun translate(
        reading: Reading, translator: TextTranslator, cancelled: () -> Boolean = { false }, progress: (List<Item>) -> Unit = {},
    ): List<Item> {
        if (!translator.translatesTogether) return translateGroups(reading, { translator.translate(it) }, cancelled, progress)
        val groups = groups(reading)
        val paragraphs = groups.flatMap { it.paragraphs }
        if (paragraphs.isEmpty()) return emptyList()
        val translations = translator.translateAll(paragraphs)
        if (cancelled()) return emptyList()
        val items = mutableListOf<Item>()
        var next = 0
        for (group in groups) {
            val count = group.paragraphs.size
            val translated = (next until next + count).map { if (it < translations.size) translations[it] else paragraphs[it] }
            next += count
            item(group, translated)?.let(items::add)
        }
        if (items.isNotEmpty()) progress(items.toList())
        return items
    }

    /** Grubun gösterilecek çevirisi; çevirisi aslıyla aynıysa (ad, sayı, zaten Türkçe yazı) null. */
    private fun item(group: Group, translations: List<String>): Item? {
        var changed = false
        val texts = group.paragraphs.zip(translations).map { (paragraph, translation) ->
            val text = translation.trim().ifEmpty { paragraph }
            changed = changed || !TextMatch.isSimilar(TextMatch.normalize(paragraph), TextMatch.normalize(text), 0.90)
            text
        }
        if (!changed) return null
        return Item(group.paragraphs.joinToString("\n"), texts.joinToString("\n"), group.box, group.lineHeight)
    }

    /**
     * Satırları gruplara toplar. Kumanda ipuçları ve yazı tanıma çöpleri atılır; harfi olmayan ya da tek harfli satırlar
     * ("23m", "9", "+") göstergedir, çevrilmez. Bir satır, üstündeki satırın hemen altındaysa, yatayda onunla üst üste
     * biniyorsa ve yazı boyu benziyorsa o gruba katılır. Gruplar yukarıdan aşağı, en çok [MAX_GROUPS].
     */
    fun groups(reading: Reading): List<Group> {
        val lines = reading.withoutButtonPrompts().withoutOcrNoise().lines
            .filter { it.box != null && ScreenText.isWords(it.text) }
            .sortedBy { it.box!!.top }
        val groups = mutableListOf<MutableList<TextLine>>()
        for (line in lines) {
            val index = groups.indexOfLast { belongs(line.box!!, it.last().box!!) }
            if (index >= 0) groups[index].add(line) else groups.add(mutableListOf(line))
        }
        return groups.take(MAX_GROUPS).map { group ->
            val heights = group.map { it.box!!.bottom - it.box!!.top }.sorted()
            val box = group.drop(1).fold(group[0].box!!) { total, line -> total.union(line.box!!) }
            Group(ScreenText.paragraphs(group), box, heights[heights.size / 2])
        }
    }

    /** Alt satır üsttekinin hemen altında (arada satır yüksekliğinin %80'inden az), yatayda onunla üst üste ve yazı boyu benzer. */
    private fun belongs(lower: TextBox, upper: TextBox): Boolean {
        val a = upper.bottom - upper.top
        val b = lower.bottom - lower.top
        if (maxOf(a, b) > minOf(a, b) * 1.6) return false
        if (lower.top - upper.bottom >= maxOf(a, b) * 0.8 || lower.top < upper.top) return false
        val overlap = minOf(lower.right, upper.right) - maxOf(lower.left, upper.left)
        val narrower = minOf(lower.right - lower.left, upper.right - upper.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    /** Çevirilerin ekranda kalma süresi (ms): yazı çoksa daha uzun; düğmeye yeniden basınca hemen kalkar. */
    fun displayMilliseconds(items: List<Item>): Int =
        minOf(60000, maxOf(12000, 8000 + items.sumOf { it.translation.length } * 50))
}
