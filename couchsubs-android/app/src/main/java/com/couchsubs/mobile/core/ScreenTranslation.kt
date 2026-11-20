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
        /** Her parçadaki kumanda simgeleri, parçadaki [ButtonIcons.MARKER] sırasıyla; simge yoksa null. */
        val icons: List<List<IconSlot>>? = null,
    )

    data class Item(
        val source: String,
        /** Parçaların çevirisi, her parça ayrı satırda. */
        val translation: String,
        val box: TextBox,
        val lineHeight: Double,
        /** Çevirinin içindeki kumanda simgeleri (kareden kesilmiş); TV [translation]'ın o yerine koyar. */
        val icons: List<IconPlacement>? = null,
        /** Otomatik ekran yazısında özgün bloğun zemini ve yazı rengi ([TextStyleSampler]); `surface` alanıyla gider. */
        val surface: TextSurface? = null,
        /** Özgün yazının görünüşü (kalın, dar, hizalama, büyük harf); `style` alanıyla gider. */
        val look: TextLook? = null,
    ) {
        /** Birden çok parça var: satır satır, sola yaslı gösterilir. */
        val paragraphs: Boolean get() = translation.contains('\n')
    }

    /**
     * Kalabalık ekranda ekranı kutuyla doldurmamak ve çeviriyi uzatmamak için en çok bu kadar grup çevrilir; fazlası
     * olunca en az yazısı olanlar (tek sözcüklük etiketler) bırakılır.
     */
    const val MAX_GROUPS = 30

    /**
     * Grupları sırayla çevirir; her grup çevrilince o ana kadarki sonuçlarla [progress] çağrılır. Çevirisi aslıyla aynı
     * olan (ad, sayı, zaten Türkçe yazı) grup gösterilmez. [cancelled] true dönerse iş bırakılır. [frame] okunan kareyse
     * yazıların içindeki kumanda simgeleri ondan kesilip çeviriye konur.
     */
    fun translateGroups(
        reading: Reading, translate: (String) -> String, cancelled: () -> Boolean = { false }, frame: GrayFrame? = null,
        progress: (List<Item>) -> Unit = {},
    ): List<Item> {
        val items = mutableListOf<Item>()
        for (group in withImages(groups(reading), frame)) {
            if (cancelled()) return items
            // Simgeler çeviride uydurma adlarla korunur (IconText).
            val prepared = group.paragraphs.map { IconText.protect(it) }
            val translated = prepared.map { translate(it.text) }
            val item = item(group, prepared, translated) ?: continue
            items.add(item)
            progress(items.toList())
        }
        return items
    }

    /**
     * Çevirmen parçaları tek istekte çevirebiliyorsa (yapay zekâ) ekranın bütün parçaları birlikte gider ve sonuç bir
     * kerede gelir; yoksa gruplar sırayla çevrilip hazırlandıkça bildirilir. [frame] okunan kareyse yazıların içindeki
     * kumanda simgeleri ondan kesilip çeviriye konur.
     */
    fun translate(
        reading: Reading, translator: TextTranslator, cancelled: () -> Boolean = { false }, frame: GrayFrame? = null,
        progress: (List<Item>) -> Unit = {},
    ): List<Item> {
        if (!translator.translatesTogether) return translateGroups(reading, { translator.translate(it) }, cancelled, frame, progress)
        val groups = withImages(groups(reading), frame)
        // Simgeler çeviride uydurma adlarla korunur (IconText).
        val prepared = groups.map { group -> group.paragraphs.map { IconText.protect(it) } }
        val paragraphs = prepared.flatMap { group -> group.map { it.text } }
        if (paragraphs.isEmpty()) return emptyList()
        val translations = translator.translateAll(paragraphs)
        if (cancelled()) return emptyList()
        val items = mutableListOf<Item>()
        var next = 0
        for ((index, group) in groups.withIndex()) {
            val count = group.paragraphs.size
            // Gelmeyen çeviri boş kalır: parça aslıyla gösterilir.
            val translated = (next until next + count).map { if (it < translations.size) translations[it] else "" }
            next += count
            item(group, prepared[index], translated)?.let(items::add)
        }
        if (items.isNotEmpty()) progress(items.toList())
        return items
    }

    /** Simgeli grupların simgeleri [frame]'den kesilir; kare yoksa gruplar olduğu gibi kalır. */
    private fun withImages(groups: List<Group>, frame: GrayFrame?): List<Group> {
        if (frame == null) return groups
        return groups.map { group ->
            val icons = group.icons
            if (icons == null) group else group.copy(icons = icons.map { ButtonIcons.withImages(it, frame) })
        }
    }

    /** Grubun gösterilecek çevirisi; çevirisi aslıyla aynıysa (ad, sayı, zaten Türkçe yazı) null. */
    private fun item(group: Group, prepared: List<IconText.Protected>, translations: List<String>): Item? {
        var changed = false
        val texts = mutableListOf<String>()
        val slots = mutableListOf<IconSlot>()
        for ((i, paragraph) in group.paragraphs.withIndex()) {
            val translation = translations.getOrElse(i) { "" }.trim()
            val text = if (translation.isEmpty()) IconText.indexed(paragraph, slots.size)
            else IconText.restore(translation, prepared[i].names, slots.size)
            changed = changed ||
                !TextMatch.isSimilar(TextMatch.normalize(IconText.plain(paragraph)), TextMatch.normalize(IconText.plain(text)), 0.90)
            texts.add(text)
            group.icons?.getOrNull(i)?.let { slots.addAll(it) }
        }
        if (!changed) return null
        val rendered = IconText.render(texts.joinToString("\n"), slots)
        return Item(group.paragraphs.joinToString("\n") { IconText.plain(it) }, rendered.text, group.box, group.lineHeight,
            rendered.icons.takeIf { it.isNotEmpty() })
    }

    /**
     * Satırları gruplara toplar. Kumanda ipuçları ve yazı tanıma çöpleri atılır; harfi olmayan ya da tek harfli satırlar
     * ("23m", "9", "+") göstergedir, çevrilmez. Bir satır, üstündeki satırın hemen altındaysa, yatayda onunla üst üste
     * biniyorsa ve yazı boyu benziyorsa o gruba katılır; küçük harfle başlayan satır üstteki bitmemiş cümleye katılır
     * ([continues]). Gruplar yukarıdan aşağı; en çok [MAX_GROUPS], en çok yazısı olanlar.
     */
    fun groups(reading: Reading, keepPrompts: Boolean = false): List<Group> {
        val marked = reading.withButtonIcons()
        val lines = (if (keepPrompts) marked else marked.withoutButtonPrompts()).withoutOcrNoise().lines
            .filter { it.box != null && ScreenText.isWords(it.text) }
            .sortedBy { it.box!!.top }
        val groups = mutableListOf<MutableList<TextLine>>()
        for (line in lines) {
            var index = groups.indexOfLast { belongs(line.box!!, it.last().box!!) }
            if (index >= 0 && (bridgesColumns(groups[index].last().box!!, line.box!!, lines)
                || bridgesColumns(line.box!!, groups[index].last().box!!, lines))) index = -1
            // Küçük harfle başlayan satır, üstündeki bitmemiş cümlenin devamıdır: satır aralığı biraz geniş ya da yanında
            // başka bir yazı olsa da o gruba katılır. Ayrı grup olunca yarım cümle tek başına çevriliyor ya da grup
            // sınırına takılıp hiç çevrilmiyordu; bilgi kutusunun son satırı İngilizce kalıyordu.
            if (index < 0) index = groups.indexOfLast { continues(line, it.last()) }
            if (index >= 0) groups[index].add(line) else groups.add(mutableListOf(line))
        }
        return busiest(groups).map { group ->
            val heights = group.map { it.box!!.bottom - it.box!!.top }.sorted()
            val box = group.drop(1).fold(group[0].box!!) { total, line -> total.union(line.box!!) }
            val icons = ScreenText.paragraphIcons(group)
            Group(ScreenText.paragraphs(group), box, heights[heights.size / 2], if (icons.any { it.isNotEmpty() }) icons else null)
        }
    }

    /**
     * Kalabalık ekranda en çok yazısı olan [MAX_GROUPS] grup, yukarıdan aşağı sırasıyla. Önceden en üstteki gruplar
     * alınıyordu: menü ve gösterge etiketleri sınırı doldurunca ekranın alt yarısındaki bilgi kutusu hiç çevrilmiyordu.
     */
    private fun busiest(groups: List<List<TextLine>>): List<List<TextLine>> {
        if (groups.size <= MAX_GROUPS) return groups
        val letters = groups.map { group -> group.sumOf { line -> line.text.count { it.isLetter() } } }
        return groups.indices.sortedWith(compareByDescending<Int> { letters[it] }.thenBy { it })
            .take(MAX_GROUPS).sorted().map { groups[it] }
    }

    /**
     * Alt satır, üstteki satırın bitmemiş cümlesini sürdürüyor: küçük harfle başlıyor, üstteki cümle sonu işaretiyle
     * bitmiyor, yazı boyu benzer, yatayda üst üste ve arada satır yüksekliğinin bir buçuk katından az boşluk var.
     */
    private fun continues(lower: TextLine, upper: TextLine): Boolean {
        val first = lower.text.firstOrNull { it.isLetter() } ?: return false
        if (!first.isLowerCase() || SubtitleStabilizer.endsSentence(upper.text)) return false
        val below = lower.box ?: return false
        val above = upper.box ?: return false
        val a = above.bottom - above.top
        val b = below.bottom - below.top
        if (maxOf(a, b) > minOf(a, b) * 1.6) return false
        if (below.top - above.bottom >= maxOf(a, b) * 1.5 || below.top < above.top) return false
        val overlap = minOf(below.right, above.right) - maxOf(below.left, above.left)
        val narrower = minOf(below.right - below.left, above.right - above.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    // Geniş başlık/alt satır iki bağımsız sütundan birine katılmasın. Filtrelenmiş OCR satırlarına bakılır.
    private fun bridgesColumns(wide: TextBox, column: TextBox, lines: List<TextLine>): Boolean = lines.any { line ->
        val peer = line.box!!
        if (minOf(column.right, peer.right) > maxOf(column.left, peer.left)) return@any false
        val rowOverlap = minOf(column.bottom, peer.bottom) - maxOf(column.top, peer.top)
        if (rowOverlap <= 0 || rowOverlap < minOf(column.bottom - column.top, peer.bottom - peer.top) * 0.5) return@any false
        (belongs(column, wide) && belongs(peer, wide)) || (belongs(wide, column) && belongs(wide, peer))
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
