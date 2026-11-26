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
    /** "GTA 6 Telefon Mesajları: Yanda Panel / Balonların Üstünde" ve panelin yazı boyu; her gönderide okunur. */
    private val panel: () -> PhonePanelOptions = { PhonePanelOptions() },
    /** Telefonun açılışları arasında kalan çeviriler ve panelin yazı boyu ([PhoneMemory]); izleyici verir. */
    private val memory: PhoneMemory = PhoneMemory(),
) {
    companion object {
        const val ID = SubtitleServer.GAME_PHONE_ID
        const val INTERVAL_MS = 450L

        /**
         * Gönderilecek düzen: Yanda Panel'de telefonun mesajları yanındaki sohbet panelinde ([ScreenPhoneCard.layout]; ana
         * ekran yazıları yerinde kalır), Balonların Üstünde'de her çeviri kendi balonunun yerinde (çevirisi aslıyla aynı
         * olanlar atılır). Telefonun yeri bilinmiyorsa balonlar yerinde kalır (Mac: PhoneRegionSession.arranged).
         */
        fun arranged(items: List<ScreenTranslation.Item>, pose: GamePhoneGeometry.Pose?, aspect: Double,
                     options: PhonePanelOptions, line: Double? = null): List<ScreenTranslation.Item> {
            if (!options.enabled || pose == null || items.isEmpty()) return items.filter { !it.unchanged }
            return ScreenPhoneCard.layout(items, ScreenPhoneCard.Handset(pose, aspect), options.textScale, line)
                .filter { !it.unchanged }
        }

        /**
         * Aynı balon ekranda yerini izler, ama küçük OCR kutu farkları yazı boyunu ve satır kırılımını, renk örneği de
         * zemini sürekli değiştirmesin: genişlik %5'ten, yükseklik %10'dan, satır yüksekliği %15'ten az oynadıysa ve
         * renkler 16 basamaktan yakınsa son gönderilen değer kalır. Aynı yerde iki eş mesaj varsa ayırt edilemez,
         * dokunulmaz (Windows RegionWatcher.StablePhoneBlocks ile aynı).
         */
        fun steady(items: List<ScreenTranslation.Item>, previous: List<ScreenTranslation.Item>): List<ScreenTranslation.Item> =
            items.map { item ->
                // Aynı balon ([PhoneSteady.match]: aynı çeviri, OCR'la biraz farklı okunsa da aynı mesaj) ilk okunuşunu ve
                // tarafını (gelen/giden/not) korur: bir harf ya da hiza oynadı diye gönderi yenilenmez (Mac ile aynı).
                val before = PhoneSteady.match(item, previous) ?: return@map item
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
                    // Yazı rengi zeminin aynı yanında kaldıysa eskisi kalır (örnek bir siyah bir koyu gri okunuyordu); seçimde
                    // (siyahtan beyaza) değişim izlenir.
                    val ink = nearColor(surface.foreground, old.foreground, 16) ||
                        PhoneSteady.sameInk(surface.foreground, old.foreground, surface.background)
                    surface = surface.copy(
                        foreground = if (ink) old.foreground else surface.foreground,
                        background = if (nearColor(surface.background, old.background, 16)) old.background else surface.background,
                    )
                    // İki ayrı okunur paletin karışımı kontrastı düşürebilir: o zaman güncel çift kullanılır.
                    if (surface != old && surface != item.surface && contrast(surface.background, surface.foreground) < 4.5) surface = item.surface
                }
                val role = before.phone?.role
                item.copy(source = before.source, box = box, lineHeight = line, surface = surface,
                    phone = if (role != null) item.phone?.copy(role = role) else item.phone)
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
    private var nextBubble = 0
    private var anchors: List<Anchor> = emptyList()
    private var needsWork = false
    private var emptyOnce = false
    private val rescue = TailRescue()
    /** Çevirisi tam gösterilen son sayfa: tek okumalık OCR sapmasını gerçek değişiklikten ayırmak için. */
    private var shownPage: Page? = null
    /** Son okuma kaç turdur bekletiliyor (en çok [PhoneSteady.HOLD_TURNS]); sonra okuma her durumda ilerler. */
    private var holds = 0
    /** Ekrandaki sayfanın türü (sohbet listesi mi) ve öbür türü veren ardışık okuma sayısı ([PhoneSteady.KIND_TURNS]). */
    private var shownList: Boolean? = null
    private var kindVotes = 0
    /** Bir önceki taze okuma (bekletilse de): kaydırmayı ([PhoneSteady.scrolled]) ölçmek için. */
    private var lastRead: Page? = null
    /** Son taze okuma bir öncekine göre kaydırma: bekletme, konum sabitleme ve turda tek balon çevirisi atlanır. */
    private var scrolling = false
    /** Altyazı günlüğü: mesaj çevrilmediğinde ya da bekletildiğinde nedeni ([DropLog]; Mac/iPhone ve Windows ile aynı). */
    @Volatile var onLog: ((String) -> Unit)? = null
    private val drops = DropLog()
    /** Telefonun sessiz yolları ([PhoneTrace]); izleyici verir ki telefon her açılışta sınır baştan başlamasın. */
    @Volatile var trace = DropLog()

    /** Mesajın düşürülme ya da bekletilme nedeni ([DropLog]: aynı neden + metin yinelenmez, dakikada sınırlı). */
    private fun note(component: String, reason: String, text: String) {
        drops.note(component, reason, IconText.plain(text), onLog)
    }
    /** Okumanın art arda doğrulanamadığı tur sayısı ([missed]). */
    private var absences = 0
    private var recheck = false
    /** Son gönderilen bloklar ve o anki telefon boyu ([steady]). */
    private var sent: List<ScreenTranslation.Item> = emptyList()
    private var sentScale = 0.0
    /** Son gönderinin ayarı: ayar değişince aynı mesajlar yeni düzende yeniden gönderilir. */
    private var sentOptions: PhonePanelOptions? = null
    /** Son gönderilen düzen ve Yanda Panel'in dayandığı telefon yeri ([PhoneSteady.steadyPose], [PhoneSteady.samePicture]). */
    private var sentShown: List<ScreenTranslation.Item> = emptyList()
    /** Yanda Panel'in kilitli telefon yeri ve yazı boyu (#1152): el titremesiyle değişmez; hafızada kalır. */
    private val panelSteady get() = memory.steady
    /** Boş okumanın art arda kaç turdur sürdüğü: [PhoneSteady.MISS_TURNS] tur (~1,35 sn) sürmeden ekran silinmez. */
    private var empties = 0

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
        shownList = null
        kindVotes = 0
        publish(emptyList())
    }

    fun visit(packLookup: ((String) -> PackMatch?)?, skipsTurkish: Boolean, english: Boolean) {
        if (latest == null) return
        update(packLookup, skipsTurkish, english)
    }

    private fun read(capture: PhoneCapture, signature: ByteArray): Page {
        val region = capture.region
        val raw = GamePhoneReader.read(capture.image, region, capture.pose, rescue, reader)
        // Eğik ekranın düzeltilmiş okuması hiç satır vermedi: önceden sessizdi (#1251).
        if (raw.lines.isEmpty()) trace.note(PhoneTrace.COMPONENT, PhoneTrace.EMPTY_FLAT, "Phone", onLog)
        val reading = GamePhoneText.forTranslation(raw)
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
        // Kaydırma yalnız bu turun taze okumasında ölçülür; görüntü değişmeyen turda önceki turdan kalmaz.
        scrolling = false
        val start = latest ?: run { clearMissing(); return }
        val signature = start.image.signature(start.region)
        val changed = page?.let {
            !it.region.isClose(start.region, 0.01) || RegionSignature.changed(it.signature, signature) ||
                it.pixels.changed(start.image, start.region)
        } ?: true
        var fresh = false
        if (changed || emptyOnce || recheck) {
            recheck = false
            fresh = true
            val next = try {
                read(start, signature)
            } catch (error: Exception) {
                page = null
                note("PhoneSession", "okunamadı (${error.message})", "")
                return
            }
            // Sohbet kaydırıldıysa (eşleşen balonların hepsi aynı yöne kaydı) bekletilmez, yeni balonlar hemen çevrilir.
            val before = lastRead
            lastRead = next
            scrolling = before != null && scrolled(before, next)
            if (scrolling) note("PhoneSteady", "kaydırma algılandı, bekletme ve konum sabitleme atlandı", text(next))
            // Yerinde duran iki komşu arasından düşen balon ya da uzun mesajdaki birkaç bozuk harf tek okumada ekrandan
            // silinmez, çeviri yenilenmez: sonraki tur mutlaka yeniden okur; aynı görünen gerçek değişiklik o turda ilerler.
            val previous = shownPage
            if (!scrolling && holds < PhoneSteady.HOLD_TURNS && previous != null && previous.region.isClose(next.region, 0.01) &&
                (missingInteriorBubble(previous, next) ||
                    (sameLayout(previous, next, start.image) && GamePhoneText.hasAdjacentOcrEdits(text(previous), text(next))))) {
                if (holds == 0) {
                    val why = if (missingInteriorBubble(previous, next)) "balon düştü" else "harf oynaması"
                    note("PhoneSteady", "okuma ${PhoneSteady.HOLD_TURNS} tura dek bekletildi ($why)", text(next))
                }
                holds++
                recheck = true
                return
            }
            holds = 0
            page = next
        } else if (!needsWork) {
            // "GTA 6 Telefon Mesajları" ayarı değişti: aynı sayfa yeni düzende hemen gösterilir.
            val shown = page
            if (shown != null && rendered.isNotEmpty() && sentOptions != panel())
                publish(items(shown, availableTranslations(shown.bubbles.map { it.group }, packLookup, skipsTurkish)))
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
        // Sayfanın türü (liste/sohbet) tek okumayla değişmez: telefon sallanırken bölüm başlığı bir okumada kaçınca panel
        // liste ile sohbet balonları arasında gidip geliyordu (LG, beta.93). Öbür tür art arda [PhoneSteady.KIND_TURNS]
        // okumada gelirse geçilir; arada aynı tür gelirse sayaç sıfırlanır. iPhone ile aynı.
        val list = isList(current)
        val shownKind = shownList
        if (fresh && current.bubbles.isNotEmpty() && shownKind != null && shownKind != list && rendered.isNotEmpty()) {
            kindVotes++
            if (kindVotes < PhoneSteady.KIND_TURNS) {
                note("PhoneSteady", "sayfa türü değişti (${if (list) "liste" else "sohbet"}), bir okuma daha bekleniyor", text(current))
                page = null
                return
            }
        }
        if (current.bubbles.isNotEmpty()) kindVotes = 0
        if (current.bubbles.isEmpty()) {
            // Ekranda çeviri varsa [PhoneSteady.MISS_TURNS] tur boş kalmadan silinmez: telefonun ekranı kısa süre
            // okunamayınca panel kaybolup geri geliyordu (X, 22 Kas; Mac ile aynı).
            empties++
            if (rendered.isEmpty() || empties >= PhoneSteady.MISS_TURNS) {
                if (rendered.isNotEmpty()) {
                    note("PhoneSteady", "${PhoneSteady.MISS_TURNS} tur boş okundu, çeviri silindi", rendered.joinToString(" ") { it.source })
                }
                publish(emptyList())
                shownList = null
                emptyOnce = false
                empties = 0
            } else {
                emptyOnce = true
            }
            needsWork = false
            return
        }
        emptyOnce = false
        empties = 0
        shownList = list
        val groups = current.bubbles.map { it.group }
        val paragraphs = groups.flatMap { it.paragraphs }
        var available = availableTranslations(groups, packLookup, skipsTurkish)
        // Önce yalnız güncel sayfayla eşleşen balonlar kalır. Örneğin yeni WhatUp yanıtı ağdayken önceki yanıtın üstü
        // kendi özgün yazısıyla görünür, bitmiş komşu balonlar okunabilir.
        publish(items(current, available))
        var missing = paragraphs.filter { available[it] == null }
        if (missing.isEmpty()) {
            val shown = shownPage
            if (shown != null && text(shown) != text(current)) {
                note("PhoneSession", "mesajlar değişti, hepsinin çevirisi hazır sayıldı, motora gitmedi", text(current))
            }
            needsWork = false
            return
        }
        // Ücretsiz motorda turda tek balon çevrilir; kaydırmada görünen yeni balonların hepsi tek istekte gider.
        if (!translator.translatesTogether && !scrolling) {
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
        // Listede "…" ile kesilmiş önizleme kesik çevrilir, yarım sözcük uydurulmaz ([GamePhoneText.cutInput]).
        // "…" koymadan satır sonunda kesilmiş önizleme de kesik çevrilir ([GamePhoneText.clippedInput]); motora "..." ile
        // gider, sonu tamamlanmaz (Sinan Bey, beta.100 3399).
        // Sohbet dışı ekranın kartlarında da (gönderinin "…" ile kesilmiş açıklaması, haber başlığı) sonu tamamlanmaz
        // (Sinan Bey, beta.100 3416: "Pour some goddamn sugar o…" tamamlanarak çevriliyordu).
        val previews = groups.filter { it.phone?.role == ScreenPhoneCard.Role.PREVIEW || it.phone?.role == ScreenPhoneCard.Role.CARD }
            .flatMap { it.paragraphs }.toSet()
        val clipped = groups.filter { it.phone?.role == ScreenPhoneCard.Role.PREVIEW && (it.phone?.spot?.right ?: 0.0) >= GamePhoneText.CLIP_EDGE }
            .flatMap { it.paragraphs }.toSet()
        val cuts = missing.map { source ->
            if (source !in previews) null
            else GamePhoneText.cutInput(source) ?: if (source in clipped) GamePhoneText.clippedInput(source) else null
        }
        val inputs = missing.zip(cuts).map { (source, cut) ->
            val text = IconText.protect(cut?.let(GamePhoneText::cutHint) ?: source).text
            if (english) GamePhoneText.englishModelInput(text) else text
        }
        try {
            // Aynı çevirmen örneğinin bağlamına iki iş parçacığı birden yazmasın (ek alanların ön çevirisi).
            val result = synchronized(translator) { translator.translateAll(inputs) }
            if (closed) return
            if (result.size != inputs.size) {
                needsWork = true
                note("PhoneSession", "çevrilemedi (motor ${result.size}/${inputs.size} yanıt)", missing.joinToString(" "))
                return
            }
            for ((index, pair) in missing.zip(result).withIndex()) {
                val (source, translated) = pair
                if (translated.isBlank()) {
                    note("PhoneSession", "motor boş çeviri döndü, gösterilmedi", source)
                    continue
                }
                val shown = if (cuts[index] == null) translated
                    else GamePhoneText.cutTranslation(GamePhoneText.keepingLeadingSymbol(source, translated))
                remember(source, shown)
                available[source] = shown
            }
        } catch (error: Exception) {
            needsWork = true
            note("PhoneSession", "çevrilemedi (${error.message})", missing.joinToString(" "))
            return
        }
        val last = latest ?: return
        if (last.image !== verified.image && !matches(current, last)) {
            verified = last
            current = reread(verified) ?: run { missed(); return }
            available = availableTranslations(current.bubbles.map { it.group }, packLookup, skipsTurkish)
        }
        if (closed) return
        publish(items(current, available))
        needsWork = current.bubbles.any { bubble -> bubble.group.paragraphs.any { available[it] == null } }
        if (!needsWork) shownPage = current
    }

    /** İki okuma arasında sohbet kaydı mı ([PhoneSteady.scrolled]; üstler ve satır yüksekliği telefon bölgesine oranlı). */
    private fun scrolled(before: Page, after: Page): Boolean {
        fun placed(page: Page): List<PhoneSteady.Placed> {
            val height = page.region.bottom - page.region.top
            if (height <= 0) return emptyList()
            return page.bubbles.map { PhoneSteady.Placed(it.group.paragraphs.joinToString("\n"), (it.group.box.top - page.region.top) / height) }
        }
        val height = after.region.bottom - after.region.top
        val lines = after.bubbles.map { it.group.lineHeight }.sorted()
        if (height <= 0 || lines.isEmpty()) return false
        return PhoneSteady.scrolled(placed(before), placed(after), lines[lines.size / 2] / height)
    }

    private fun isList(page: Page): Boolean = PhoneSteady.isList(page.bubbles.map { it.group.phone?.role })

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
                if (missing || i == 0 || before[i].group.paragraphs.any { !memory.knows(it) }) return false
                missing = true
                prior = before[i + 1].group
                if (prior.paragraphs != block.paragraphs) return false
            }
            if (abs(block.box.left - prior.box.left) > 0.012 || abs(block.box.right - prior.box.right) > 0.012 ||
                abs(block.box.top - prior.box.top) > 0.012 || abs(block.box.bottom - prior.box.bottom) > 0.012) return false
        }
        // Kalanlar yerinde, yalnız en alttaki balon düştü: yeni mesaj eklenir, silinmez; bu da bir OCR atlamasıdır.
        return missing || before.last().group.paragraphs.none { !memory.knows(it) }
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

    /**
     * Okuma sürerken gelen son kareyi yeniden okur ve kabul eder. Bu okuma sürerken bir kare daha gelmesi okumayı geçersiz
     * kılmaz: GTA 6'nın telefonu elde durur, her karede birkaç piksel sallanır, yazı pikselleri ([GamePhonePage]) ardışık
     * iki karede hiç aynı kalmıyordu (gerçek kayıtta 100 ms arayla %2, 300 ms arayla hiç). Önceden yeniden okuma da
     * "doğrulanamadı" sayılıyor, üç turda çeviri siliniyor, mesajlar yalnız telefonun tam durduğu nadir anlarda çevriliyordu
     * (#1202, #1197, #1193, #1170). Sayfa gerçekten değiştiyse sonraki tur zaten yeniden okur (Mac/iPhone ve Windows ile aynı).
     */
    private fun reread(capture: PhoneCapture): Page? {
        if (closed) return null
        val fresh = try {
            read(capture, capture.image.signature(capture.region))
        } catch (error: Exception) {
            return null
        }
        if (closed || latest == null) return null
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
        shownList = null
        kindVotes = 0
        lastRead = null
        scrolling = false
        holds = 0
        recheck = false
        emptyOnce = false
        empties = 0
        needsWork = false
        publish(emptyList())
    }

    private fun remember(source: String, translation: String) = memory.remember(source, translation)

    /**
     * Paketten, hafızadan ya da zaten Türkçe olduğu için hazır çeviriler. Kişinin adı (sohbet başlığı) çevrilmez: "Rose"
     * "Gül" olmasın; panelin başlığında aslıyla görünür (Mac ile aynı).
     */
    private fun availableTranslations(
        groups: List<ScreenTranslation.Group>, packLookup: ((String) -> PackMatch?)?, skipsTurkish: Boolean,
    ): MutableMap<String, String> {
        val result = HashMap<String, String>()
        for (group in groups) for (text in group.paragraphs) {
            if (group.phone?.role?.keepsText == true) {
                result[text] = text
                continue
            }
            // Ekranda aynı yerde duran balonun daha bozuk okunuşu da yeniden çevrilmez ([PhoneSteady.shownTranslation]).
            // Listedeki kesik önizlemenin tam mesajı sohbette çevrildiyse o çevirinin başı + "..." ([GamePhoneText.knownPreview]).
            val known = packLookup?.invoke(IconText.plain(text))?.text ?: memory.translation(text)
                ?: (if (group.paragraphs.size == 1) PhoneSteady.shownTranslation(IconText.plain(text), group.phone?.spot, rendered) else null)
                ?: (if (group.phone?.role == ScreenPhoneCard.Role.PREVIEW) GamePhoneText.knownPreview(IconText.plain(text), memory.known) else null)
                ?: if (skipsTurkish && TurkishText.isSure(text)) text else null
            if (known != null) result[text] = known else result.remove(text)
        }
        return result
    }

    /**
     * Çevirisi hazır balonlar. Panelde çevirisi aslıyla aynı mesajlar ("ok", ad) da görünür (sohbet eksik kalmasın);
     * balonların üstünde ise atılır, özgün yazı görünür kalır.
     */
    private fun items(page: Page, translations: Map<String, String>): List<ScreenTranslation.Item> {
        val keepUnchanged = panel().enabled
        return page.bubbles.mapNotNull { bubble ->
            val group = bubble.group
            // Motorun aynı cümleyi art arda iki kez yazdığı çeviri tek kez gösterilir ([GamePhoneText.withoutRepeat]).
            val result = group.paragraphs.mapNotNull {
                GamePhoneText.keepIdentifiers(it, translations[it]?.let(GamePhoneText::withoutRepeat))
            }
            if (result.size != group.paragraphs.size) return@mapNotNull null
            ScreenTranslation.item(group, group.paragraphs.map(IconText::protect), result, keepUnchanged)?.copy(surface = bubble.style)
        }
    }

    private fun publish(fresh: List<ScreenTranslation.Item>): Unit = synchronized(this) {
        // Kapanan telefonun bekleyen çevirisi oyunun üstüne çizilmez.
        if (closed && fresh.isNotEmpty()) return
        // Telefon gerçekten yakınlaşıp uzaklaşınca (%3) balonların yerindeki görünüşü hemen yenilenir (Balonların Üstünde).
        page?.region?.let { region ->
            val scale = region.bottom - region.top
            if (abs(scale - sentScale) > sentScale * 0.03) {
                sentScale = scale
                sent = emptyList()
            }
        }
        // Yanda Panel'in dayandığı telefon yeri ve yazı boyu ise el titremesiyle değişmez ([PhonePanelSteady]): yalnız
        // belirgin ve kalıcı yakınlaşma/kaymada yenilenir. Ekran silinince sonraki gönderi baştan ölçer.
        val now = lastPass ?: 0L
        val capture = latest
        if (fresh.isEmpty()) panelSteady.reset()
        val placed = if (fresh.isEmpty()) null else capture?.pose?.let { panelSteady.steadyPose(it, now) }
        val aspect = capture?.let { it.image.width.toDouble() / maxOf(1, it.image.height) } ?: (16.0 / 9)
        // Aynı mesaj bir kez ([PhoneSteady.withoutRepeats]); ekrandaki mesajın Türkçesi okuma okuma değişmez
        // ([PhoneSteady.keptTranslations]; Mac ile aynı).
        val unique = PhoneSteady.withoutRepeats(fresh).let { if (rendered.isEmpty()) it else PhoneSteady.keptTranslations(it, rendered) }
        // Kaydırmada balonlar yeni yerlerine hemen geçer (konum sabitleme atlanır); boy, satır yüksekliği ve renk
        // kararlılığı ([steady]) sürer.
        var items = when {
            sent.isEmpty() -> unique
            scrolling -> steady(unique, sent)
            else -> PhoneSteady.steadyPositions(steady(unique, sent), sent, aspect)
        }
        val options = panel()
        // Yazı boyu grup için bir kez ölçülür, kilitlidir ([PhonePanelSteady.steadyLine]); Balonların Üstünde'de de bütün
        // mesaj balonları bu tek boyda ([PhoneSteady.uniformLine]).
        val line = if (fresh.isEmpty()) null else panelSteady.steadyLine(ScreenPhoneCard.measuredLine(items), now)
        if (!options.enabled) items = PhoneSteady.uniformLine(items, line)
        sent = items
        if (rendered == items && (sentOptions == options || items.isEmpty())) return
        val sameOptions = sentOptions == options
        rendered = items
        sentOptions = options
        // Panel telefonun el titremesiyle kaymaz, yazı boyu değişmez ([PhonePanelSteady]); aynı görünen gönderi yinelenmez.
        var shown = arranged(items, placed?.pose, aspect, options, line)
        // Liste kartlarının avatarı, rozeti ve seçim çerçevesi kareden (satır başına bir kez kesilip saklanır;
        // [PhoneListLook]). Android'de yapışık çeviri yok: kutular her zaman karenin koordinatında.
        capture?.let { shown = memory.rows.apply(shown, it.image) }
        if (sameOptions) shown = PhoneSteady.steadyCard(shown, sentShown)
        if (sameOptions && PhoneSteady.samePicture(shown, sentShown)) {
            // Çeviriler aynı ama özgün mesajlar değişti: yeni mesaj TV'ye gitmedi (yalnız bu durum günlüğe; Mac ile aynı).
            val sources = shown.map { it.source }
            if (sources != sentShown.map { it.source }) {
                note("PhoneSteady", "samePicture: görüntü aynı sayıldı, gönderilmedi", sources.joinToString(" "))
            }
            return
        }
        sentShown = shown
        val box = shown.map { it.box }.reduceOrNull { a, b -> a.union(b) }
        val heights = shown.map { it.lineHeight }.sorted()
        sender.sendRegion(ID, shown.filter { !ScreenPhoneCard.isBackdrop(it) }.joinToString("\n") { it.translation }, box,
            if (heights.isEmpty()) null else heights[heights.size / 2], null, shown.takeIf { it.isNotEmpty() })
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
