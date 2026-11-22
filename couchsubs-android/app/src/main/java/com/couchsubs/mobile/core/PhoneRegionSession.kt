// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/** Telefon açıkken alınan kare ve o karedeki telefonun pozu. Kare kopyadır; çağrıdan sonra da geçerlidir. */
class PhoneCapture(val image: PhoneImage, val pose: GamePhoneGeometry.Pose) {
    val region: CropRegion get() = pose.bounds
}

/**
 * Tek telefon açılışının son karesi, okunmuş balonları ve birebir çevirileri. Ana altyazı ve elle seçilen bölgeler kendi
 * saatlerinde kalır. Telefon kapanınca bu oturum tekrar kullanılmaz (Mac/iPhone PhoneRegionSession.swift, Windows
 * RegionWatcher.Phone.cs ile aynı kurallar).
 *
 * Android'de kare yalnız izleyicinin telefonu bulduğu örneklerde kopyalanır ([GamePhoneTracker.INTERVAL_MS]); her
 * [PhoneCapture] telefonun o karede görüldüğü anlamına gelir, ayrıca yeniden aranmaz. [observe] ve [close] kare iş
 * parçacığından, [visit] ek alanların iş parçacığından çağrılır.
 */
internal class PhoneRegionSession(
    private val reader: (GamePhoneReader.Flat) -> Reading,
    private val translator: TextTranslator,
    private val sender: RegionSender,
) {
    companion object {
        const val ID = SubtitleServer.GAME_PHONE_ID
        const val INTERVAL_MS = 450L

        /**
         * Aynı balon ekranda yerini izler, ama küçük OCR kutu farkları yazı boyunu ve satır kırılımını, renk örneği de
         * zemini sürekli değiştirmesin: genişlik %5'ten, yükseklik %10'dan, satır yüksekliği %15'ten az oynadıysa ve
         * renkler 16 basamaktan yakınsa son gönderilen değer kalır. Aynı yerde iki eş mesaj varsa ayırt edilemez,
         * dokunulmaz (Windows RegionWatcher.StablePhoneBlocks ile aynı).
         */
        fun steady(items: List<ScreenTranslation.Item>, previous: List<ScreenTranslation.Item>): List<ScreenTranslation.Item> =
            items.map { item ->
                var match: ScreenTranslation.Item? = null
                for (old in previous) {
                    if (old.source != item.source || old.translation != item.translation ||
                        abs(old.box.left - item.box.left) > 0.05 || abs(old.box.top - item.box.top) > 0.05) continue
                    if (match != null) return@map item
                    match = old
                }
                val before = match ?: return@map item
                var box = item.box
                val width = box.right - box.left
                val height = box.bottom - box.top
                val oldWidth = before.box.right - before.box.left
                val oldHeight = before.box.bottom - before.box.top
                if (oldWidth > 0 && abs(width - oldWidth) <= oldWidth * 0.05) box = box.copy(right = minOf(1.0, box.left + oldWidth))
                if (oldHeight > 0 && abs(height - oldHeight) <= oldHeight * 0.10) box = box.copy(bottom = minOf(1.0, box.top + oldHeight))
                val line = if (abs(item.lineHeight - before.lineHeight) <= before.lineHeight * 0.15) before.lineHeight else item.lineHeight
                var surface = item.surface
                val old = before.surface
                if (surface != null && old != null) {
                    // Ön ve arka renk ayrı ayrı: seçimin gerçek yazı/zemin rengi değişimi korunur.
                    surface = surface.copy(
                        foreground = if (nearColor(surface.foreground, old.foreground, 16)) old.foreground else surface.foreground,
                        background = if (nearColor(surface.background, old.background, 16)) old.background else surface.background,
                    )
                    // İki ayrı okunur paletin karışımı kontrastı düşürebilir: o zaman güncel çift kullanılır.
                    if (surface != old && surface != item.surface && contrast(surface.background, surface.foreground) < 4.5) surface = item.surface
                }
                item.copy(box = box, lineHeight = line, surface = surface)
            }

        /** Kanallar en çok [tolerance] farklı (palet sekizli basamaklara yuvarlar; bir basamak sıkıştırma titreşimidir). */
        fun nearColor(a: String, b: String, tolerance: Int): Boolean {
            if (a == b) return true
            if (a.length != 7 || b.length != 7) return false
            for (i in 1 until 7 step 2) {
                val x = a.substring(i, i + 2).toIntOrNull(16) ?: return false
                val y = b.substring(i, i + 2).toIntOrNull(16) ?: return false
                if (abs(x - y) > tolerance) return false
            }
            return true
        }

        /** WCAG 2 kontrast oranı (1–21). */
        fun contrast(a: String, b: String): Double {
            fun luminance(hex: String): Double {
                val value = hex.removePrefix("#").toIntOrNull(16) ?: 0
                fun linear(n: Int): Double {
                    val c = n / 255.0
                    return if (c <= 0.03928) c / 12.92 else Math.pow((c + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * linear((value shr 16) and 0xff) + 0.7152 * linear((value shr 8) and 0xff) + 0.0722 * linear(value and 0xff)
            }
            val x = luminance(a)
            val y = luminance(b)
            return (maxOf(x, y) + 0.05) / (minOf(x, y) + 0.05)
        }
    }

    private class Bubble(val group: ScreenTranslation.Group, val style: TextSurface)

    private class Page(val region: CropRegion, val signature: ByteArray, val pixels: GamePhonePage, val bubbles: List<Bubble>)

    private class Anchor(val prefix: String, val x: Double, val y: Double)

    @Volatile private var latest: PhoneCapture? = null
    @Volatile private var closed = false
    private var lastPass: Long? = null
    private var page: Page? = null
    private var rendered: List<ScreenTranslation.Item> = emptyList()
    private val translations = HashMap<String, String>()
    private val keys = ArrayList<String>()
    private var nextBubble = 0
    private var anchors: List<Anchor> = emptyList()
    private var needsWork = false
    private var emptyOnce = false
    private val rescue = TailRescue()
    /** Çevirisi tam gösterilen son sayfa: tek okumalık OCR sapmasını gerçek değişiklikten ayırmak için. */
    private var shownPage: Page? = null
    /** Son okuma kaç turdur bekletiliyor (en çok [PhoneSteady.HOLD_TURNS]); sonra okuma her durumda ilerler. */
    private var holds = 0
    /** Okumanın art arda doğrulanamadığı tur sayısı ([missed]). */
    private var absences = 0
    private var recheck = false
    /** Son gönderilen bloklar ve o anki telefon boyu ([steady]). */
    private var sent: List<ScreenTranslation.Item> = emptyList()
    private var sentScale = 0.0

    fun observe(capture: PhoneCapture) {
        if (!closed) latest = capture
    }

    fun beginIfDue(time: Long): Boolean {
        if (latest == null) return false
        lastPass?.let { if (time - it < INTERVAL_MS) return false }
        lastPass = time
        return true
    }

    fun close(): Unit = synchronized(this) {
        closed = true
        latest = null
        publish(emptyList())
    }

    fun visit(packLookup: ((String) -> PackMatch?)?, skipsTurkish: Boolean, english: Boolean) {
        if (latest == null) return
        update(packLookup, skipsTurkish, english)
    }

    private fun read(capture: PhoneCapture, signature: ByteArray): Page {
        val region = capture.region
        val reading = GamePhoneText.forTranslation(GamePhoneReader.read(capture.image, region, capture.pose, rescue, reader))
        val place = region.box
        val groups = GamePhoneText.groups(reading)
        val icons = if (groups.any { it.icons != null }) capture.image.gray(region) else null
        val bubbles = ScreenTranslation.withImages(groups, icons).map { group ->
            val box = group.box.placedIn(place)
            Bubble(group.copy(box = box, lineHeight = group.lineHeight * (region.bottom - region.top)), GamePhonePalette.sample(capture.image, box))
        }
        return Page(region, signature, GamePhonePage(capture.image, region, reading), bubbles)
    }

    private fun update(packLookup: ((String) -> PackMatch?)?, skipsTurkish: Boolean, english: Boolean) {
        val start = latest ?: run { clearMissing(); return }
        val signature = start.image.signature(start.region)
        val changed = page?.let {
            !it.region.isClose(start.region, 0.01) || RegionSignature.changed(it.signature, signature) ||
                it.pixels.changed(start.image, start.region)
        } ?: true
        if (changed || emptyOnce || recheck) {
            recheck = false
            val fresh = try {
                read(start, signature)
            } catch (error: Exception) {
                page = null
                return
            }
            // Yerinde duran iki komşu arasından düşen balon ya da uzun mesajdaki birkaç bozuk harf tek okumada ekrandan
            // silinmez, çeviri yenilenmez: sonraki tur mutlaka yeniden okur; aynı görünen gerçek değişiklik o turda ilerler.
            val previous = shownPage
            if (holds < PhoneSteady.HOLD_TURNS && previous != null && previous.region.isClose(fresh.region, 0.01) &&
                (missingInteriorBubble(previous, fresh) ||
                    (sameLayout(previous, fresh, start.image) && GamePhoneText.hasAdjacentOcrEdits(text(previous), text(fresh))))) {
                holds++
                recheck = true
                return
            }
            holds = 0
            page = fresh
        } else if (!needsWork) {
            return
        }
        if (closed) return
        var current = page ?: return
        var verified = latest ?: return
        // Okuma sürerken farklı bir sayfa gelmişse eski sayfadan yeni çeviri isteği çıkarma.
        if (start.image !== verified.image && !matches(current, verified)) {
            current = reread(verified) ?: run { missed(); return }
        }
        absences = 0
        if (closed) return
        if (current.bubbles.isEmpty()) {
            if (emptyOnce || rendered.isEmpty()) {
                publish(emptyList())
                emptyOnce = false
            } else {
                emptyOnce = true
            }
            needsWork = false
            return
        }
        emptyOnce = false
        val groups = current.bubbles.map { it.group }
        val paragraphs = groups.flatMap { it.paragraphs }
        var available = availableTranslations(paragraphs, packLookup, skipsTurkish)
        // Önce yalnız güncel sayfayla eşleşen balonlar kalır. Örneğin yeni WhatUp yanıtı ağdayken önceki yanıtın üstü
        // kendi özgün yazısıyla görünür, bitmiş komşu balonlar okunabilir.
        publish(items(current, available))
        var missing = paragraphs.filter { available[it] == null }
        if (missing.isEmpty()) {
            needsWork = false
            return
        }
        if (!translator.translatesTogether) {
            followPage(current)
            for (offset in groups.indices) {
                val index = (nextBubble + offset) % groups.size
                val lead = groups[index].paragraphs.filter { available[it] == null }
                if (lead.any(GamePhoneText::isMessagePreview)) {
                    missing = lead
                    nextBubble = (index + 1) % groups.size
                    break
                }
            }
        }
        missing = missing.distinct()
        val inputs = missing.map {
            val text = IconText.protect(it).text
            if (english) GamePhoneText.englishModelInput(text) else text
        }
        try {
            // Aynı çevirmen örneğinin bağlamına iki iş parçacığı birden yazmasın (ek alanların ön çevirisi).
            val result = synchronized(translator) { translator.translateAll(inputs) }
            if (closed) return
            if (result.size != inputs.size) {
                needsWork = true
                return
            }
            for ((source, translated) in missing.zip(result)) if (translated.isNotBlank()) {
                remember(source, translated)
                available[source] = translated
            }
        } catch (error: Exception) {
            needsWork = true
            return
        }
        val last = latest ?: return
        if (last.image !== verified.image && !matches(current, last)) {
            verified = last
            current = reread(verified) ?: run { missed(); return }
            available = availableTranslations(current.bubbles.flatMap { it.group.paragraphs }, packLookup, skipsTurkish)
        }
        if (closed) return
        publish(items(current, available))
        needsWork = current.bubbles.any { bubble -> bubble.group.paragraphs.any { available[it] == null } }
        if (!needsWork) shownPage = current
    }

    private fun text(page: Page): String = page.bubbles.flatMap { it.group.paragraphs }.joinToString(" ")

    /**
     * Yalnız tek iç balon eksilmiş: kalanların yazısı ve kutuları aynı sırada aynı yerde (0,012), eksilen ilk balon değil
     * ve çevirisi gösteriliyordu. Bu bir OCR atlaması olabilir; kaydırma, yeni yazı ya da sayfanın kapanması buna takılmaz.
     */
    private fun missingInteriorBubble(previous: Page, current: Page): Boolean {
        val before = previous.bubbles
        val now = current.bubbles
        if (now.size < 2 || before.size != now.size + 1) return false
        var missing = false
        for (i in now.indices) {
            val block = now[i].group
            var prior = before[if (missing) i + 1 else i].group
            if (prior.paragraphs != block.paragraphs) {
                if (missing || i == 0 || before[i].group.paragraphs.any { translations[it] == null }) return false
                missing = true
                prior = before[i + 1].group
                if (prior.paragraphs != block.paragraphs) return false
            }
            if (abs(block.box.left - prior.box.left) > 0.012 || abs(block.box.right - prior.box.right) > 0.012 ||
                abs(block.box.top - prior.box.top) > 0.012 || abs(block.box.bottom - prior.box.bottom) > 0.012) return false
        }
        // Kalanlar yerinde, yalnız en alttaki balon düştü: yeni mesaj eklenir, silinmez; bu da bir OCR atlamasıdır.
        return missing || before.last().group.paragraphs.none { translations[it] == null }
    }

    /** Aynı yerleşim: balon sayısı ve sınırları aynı, kutular iki pikselden az oynamış, zemin/yazı rengi yakın. */
    private fun sameLayout(previous: Page, current: Page, frame: PhoneImage): Boolean {
        val dx = 2.0 / frame.width
        val dy = 2.0 / frame.height
        if (previous.bubbles.size != current.bubbles.size) return false
        return previous.bubbles.zip(current.bubbles).all { (a, b) ->
            a.group.paragraphs.size == b.group.paragraphs.size &&
                abs(a.group.box.left - b.group.box.left) <= dx && abs(a.group.box.right - b.group.box.right) <= dx &&
                abs(a.group.box.top - b.group.box.top) <= dy && abs(a.group.box.bottom - b.group.box.bottom) <= dy &&
                abs(a.group.lineHeight - b.group.lineHeight) <= dy &&
                nearColor(a.style.background, b.style.background, 8) && nearColor(a.style.foreground, b.style.foreground, 8)
        }
    }

    private fun matches(page: Page, capture: PhoneCapture): Boolean =
        page.region.isClose(capture.region, 0.01) && !page.pixels.changed(capture.image, capture.region)

    private fun reread(capture: PhoneCapture): Page? {
        if (closed) return null
        val fresh = try {
            read(capture, capture.image.signature(capture.region))
        } catch (error: Exception) {
            return null
        }
        val last = latest ?: return null
        if (closed || !(last.image === capture.image || matches(fresh, last))) return null
        page = fresh
        return fresh
    }

    /**
     * Okuma bu turda doğrulanamadı (telefon kaydı, kare değişti). Çeviriler hemen silinmez: tek turluk ıska çevirileri
     * kaldırıp geri getiriyor, ekranda gidip geliyordu. Art arda [PhoneSteady.MISS_TURNS] turdan sonra silinir (telefon
     * gerçekten kapanınca izleyici oturumu zaten kapatır).
     */
    private fun missed() {
        absences++
        // Ekran kalsa da sonraki tur mutlaka yeniden okur. Eskiden okunan sayfa kalıyordu: çeviri bu turda geldiyse ve
        // telefon aynı görünüşe döndüyse sayfa "değişmedi" sayılıyor, hazır çeviri hiç gösterilmiyordu (GitHub #822, X:
        // "çeviri ya hiç gelmiyor ya da geç geliyor"; Mac/iPhone ile aynı, Windows zaten yeniden okuyordu).
        if (absences >= PhoneSteady.MISS_TURNS) clearMissing() else recheck = true
    }

    private fun clearMissing() {
        absences = 0
        page = null
        shownPage = null
        holds = 0
        recheck = false
        emptyOnce = false
        needsWork = false
        publish(emptyList())
    }

    private fun remember(source: String, translation: String) {
        if (translations[source] == null) {
            if (keys.size >= 2 * ScreenTranslation.MAX_GROUPS) translations.remove(keys.removeAt(0))
            keys.add(source)
        }
        translations[source] = translation
    }

    private fun availableTranslations(
        paragraphs: List<String>, packLookup: ((String) -> PackMatch?)?, skipsTurkish: Boolean,
    ): MutableMap<String, String> {
        val result = HashMap<String, String>()
        for (text in paragraphs) {
            val known = packLookup?.invoke(IconText.plain(text))?.text ?: PhoneSteady.translation(text, translations)
                ?: if (skipsTurkish && TurkishText.isSure(text)) text else null
            if (known != null) result[text] = known else result.remove(text)
        }
        return result
    }

    private fun items(page: Page, translations: Map<String, String>): List<ScreenTranslation.Item> =
        page.bubbles.mapNotNull { bubble ->
            val group = bubble.group
            val result = group.paragraphs.mapNotNull { GamePhoneText.keepIdentifiers(it, translations[it]) }
            if (result.size != group.paragraphs.size) return@mapNotNull null
            ScreenTranslation.item(group, group.paragraphs.map(IconText::protect), result)?.copy(surface = bubble.style)
        }

    private fun publish(fresh: List<ScreenTranslation.Item>): Unit = synchronized(this) {
        // Kapanan telefonun bekleyen çevirisi oyunun üstüne çizilmez.
        if (closed && fresh.isNotEmpty()) return
        // Telefon gerçekten yakınlaşıp uzaklaşınca (%3) yeni boyutlar hemen kullanılır; yoksa aynı balonun görünüşü sabit.
        page?.region?.let { region ->
            val scale = region.bottom - region.top
            if (abs(scale - sentScale) > sentScale * 0.03) {
                sentScale = scale
                sent = emptyList()
            }
        }
        val items = if (sent.isEmpty()) fresh else steady(fresh, sent)
        sent = items
        if (rendered == items) return
        rendered = items
        val box = items.map { it.box }.reduceOrNull { a, b -> a.union(b) }
        val heights = items.map { it.lineHeight }.sorted()
        sender.sendRegion(ID, items.joinToString("\n") { it.translation }, box,
            if (heights.isEmpty()) null else heights[heights.size / 2], null, items.takeIf { it.isNotEmpty() })
    }

    /** Mesaj listesi kaydıysa (önizlemeler başka yerde) sıradaki balon baştan seçilir. */
    private fun followPage(page: Page) {
        val w = page.region.right - page.region.left
        val h = page.region.bottom - page.region.top
        val current = page.bubbles.mapNotNull { bubble ->
            val first = bubble.group.paragraphs.firstOrNull()?.takeIf(GamePhoneText::isMessagePreview) ?: return@mapNotNull null
            Anchor(TextMatch.normalize(first).split(' ').filter { it.isNotEmpty() }.take(3).joinToString(" "),
                (bubble.group.box.left - page.region.left) / w, (bubble.group.box.top - page.region.top) / h)
        }
        if (current.isNotEmpty()) {
            if (current.none { b -> anchors.any { a -> a.prefix == b.prefix && abs(a.x - b.x) <= 0.10 && abs(a.y - b.y) <= 0.08 } }) nextBubble = 0
            anchors = current
        }
    }
}
