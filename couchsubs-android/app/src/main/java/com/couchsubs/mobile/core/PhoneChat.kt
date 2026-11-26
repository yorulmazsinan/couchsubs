// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/**
 * "Ekranı çevir"de GTA 6 telefonunun ekranındaki satırlar: önce telefonun düz ekranına taşınır ([ScreenPhoneCard.Handset],
 * eğik telefonda da sol/sağ kenar ekranın kenarına göre ölçülür), sonra ekranın ne olduğu çıkarılır. Sohbet ekranında
 * her balon bir parça olur (balonun satırları birleşir); balon telefonun hangi kenarına yaslıysa gelen ya da giden
 * mesajdır. Sohbet listesinde kişi adları çevrilmez, son mesaj önizlemeleri çevrilir. Ana ekran (hava durumu, bildirim
 * sayacı, simge ızgarası) sohbet değildir: yazıları yerinde çevrilir, uygulama adları çevrilmez. Mac/iPhone (PhoneChat.swift) ve
 * Windows (PhoneChat.cs) aynı kuralları ve eşikleri uygular; ortak deneme dosyası fixtures/phone-chat.json.
 */
object PhoneChat {
    /** Satır, merkezi düz ekranda bu payla dışarıda kalsa da telefonundur (kutular kenarda biraz taşabilir). */
    const val INSIDE_SLACK = 0.05
    /** Düz ekranda bu kadar dışarı taşan satır telefonun yazısı değildir (telefonun arkasından geçen altyazı, tabela). */
    const val OUTSIDE_REACH = 0.3
    /** Ekranın üst/alt kenarından bu kadar dışarı taşan satır kesiktir (sohbet kaymış, satırın yarısı görünüyor). */
    const val EDGE_CUT = 0.015
    /** Kesik satır: yüksekliği ortanca satırın bu kadarından az (başlığın altına girmiş ilk satır, alt kenardaki son satır). */
    const val CUT_HEIGHT = 0.6
    /** Fotoğrafın içindeki yazı: ortanca satırın bu kadar katından yüksek (en az üç satır varken). */
    const val PHOTO_HEIGHT = 2.0
    /** Aynı balonun iki satırı arasındaki boşluk ortanca satır yüksekliğinin bu kadarından az; balonlar arası daha geniş. */
    const val BUBBLE_GAP = 0.6
    /** Aynı balonun satırları solda bu kadar hizalı (ekran genişliğine oranla); sağa yaslı balonda sağda [RIGHT_ALIGN]. */
    const val LEFT_ALIGN = 0.04
    const val RIGHT_ALIGN = 0.03
    /** Kenar payı oranı: balonun bir yandaki payı öbür yandakinin bu kadarından azsa o yana yaslıdır. */
    const val SIDE_RATIO = 0.6
    /** İki yanı da bundan dar balon (ekranı dolduran uzun mesaj) yaslı sayılmaz; tarafı balonun rengi söyler. */
    const val WIDE_MARGIN = 0.15
    /** Ortalı kısa satır (saat, "Today", "Delivered"): merkezi ortadan en çok bu kadar uzak, iki yanda en az [NOTE_MARGIN] pay. */
    const val NOTE_CENTER = 0.06
    const val NOTE_MARGIN = 0.2
    /** Başlık (kişi adı): ekranın üst bu kadarında, ortalıysa merkezi ortadan en çok [HEADER_CENTER] uzak. */
    const val HEADER_BAND = 0.2
    const val HEADER_CENTER = 0.12
    /** Aynı satırda yan yana okunan parçalar (emoji satırı böler) aradaki boşluk satır yüksekliğinin bu katından azsa birleşir. */
    const val ROW_JOIN = 2.0

    /** Düz ekrandaki satır; [spot] düz ekrandaki yeri (0–1, ekranın kenarlarına göre). */
    internal data class Row(val lines: List<TextLine>, val spot: TextBox, val text: String) {
        val height: Double get() = spot.bottom - spot.top
        val center: Double get() = (spot.left + spot.right) / 2
        val words: Int get() = text.split(Regex("\\s+")).count { it.isNotEmpty() }
    }

    /** Telefonun içinde mi (merkezi düz ekranda, satır ekranın dışına taşmıyor). */
    fun onScreen(spot: TextBox): Boolean {
        val u = (spot.left + spot.right) / 2
        val v = (spot.top + spot.bottom) / 2
        return u >= -INSIDE_SLACK && u <= 1 + INSIDE_SLACK && v >= -INSIDE_SLACK && v <= 1 + INSIDE_SLACK &&
            spot.left >= -OUTSIDE_REACH && spot.right <= 1 + OUTSIDE_REACH
    }

    /** Ana ekranda yan yana okunan parçalar yalnız bu kadar yakınsa birleşir (simge etiketleri arasında daha geniş boşluk var). */
    const val HOME_JOIN = 1.0
    /**
     * Ana ekranda bir bloğun (bileşen başlığı ve içeriği, bildirimin satırları) iki satırı arasındaki boşluk ortanca satırın
     * bu kadarından az.
     */
    const val HOME_GAP = 0.8
    /** Simge ızgarası: aynı hizada en az bu kadar uygulama adı. */
    const val GRID_LABELS = 3
    /** Hava durumu ("76°", "24 °C") ve bildirim sayacı ("10 Notifications", "3 new messages"): yalnız ana ekranda olur. */
    private val WEATHER = Regex("""^[-−]?\d{1,3}\s?[°º˚]\s?[CFcf]?$""")
    private val COUNTER = Regex(
        """^\d{1,3}\s+(?:new\s+)?(?:notifications?|reminders?|alerts?|messages?|missed\s+calls?|e-?mails?|updates?)$""",
        RegexOption.IGNORE_CASE)

    /**
     * Telefonun satırlarını (kutuları bilinen, süzülmüş) parçalara ayırır; her grup `phone` bilgisini taşır. [raw]:
     * telefondaki süzülmemiş satırlar (harfsiz satırlar da: hava durumu ana ekranı belli eder).
     */
    fun groups(lines: List<TextLine>, handset: ScreenPhoneCard.Handset, raw: List<TextLine> = emptyList()): List<ScreenTranslation.Group> {
        val single = lines.mapNotNull { line -> line.box?.let { Row(listOf(line), handset.flat(it), clean(line.text)) } }
            .filter { row -> row.text.count { it.isLetter() } >= 2 }.sortedBy { it.spot.top }
        val rows = joinedRows(single).toMutableList()
        if (rows.isEmpty()) return emptyList()
        val median = rows.map { it.height }.sorted()[rows.size / 2]
        rows.removeAll { it.spot.top < -EDGE_CUT || it.spot.bottom > 1 + EDGE_CUT }
        // Ana ekran (saat, hava, bileşenler, simge ızgarası) sohbet değildir: kart kurulmaz, yazılar yerinde çevrilir.
        val home = joinedRows(single, HOME_JOIN).filter { it.spot.top >= -EDGE_CUT && it.spot.bottom <= 1 + EDGE_CUT }
        if (isHome(home, raw)) return homeGroups(home, median, handset)
        var header: Row? = null
        if (rows.isNotEmpty() && isHeader(rows[0])) header = rows.removeAt(0)
        if (rows.size >= 3) rows.removeAll { it.height > median * PHOTO_HEIGHT }
        // Kaymış sohbetin en üstteki ve en alttaki yarım satırı okunmaz, çevrilmez.
        if (rows.isNotEmpty() && rows.first().height < median * CUT_HEIGHT) rows.removeAt(0)
        if (rows.isNotEmpty() && rows.last().height < median * CUT_HEIGHT) rows.removeAt(rows.size - 1)

        val result = mutableListOf<ScreenTranslation.Group>()
        val list = contactList(rows, median)
        if (list != null) {
            // Listenin başındaki ortalı olmayan başlık bir kişi değil bölüm adıdır ("Messages"): çevrilir.
            header?.let {
                val role = if (abs(it.center - 0.5) <= HEADER_CENTER) ScreenPhoneCard.Role.HEADER else ScreenPhoneCard.Role.HEADING
                result.add(group(listOf(it), role, handset))
            }
            rows.forEachIndexed { index, row -> result.add(group(listOf(row), list[index], handset)) }
            return result
        }
        // Sohbet dışı ekran (gönderi, haber, makale, hava, fitness, ayarlar, eklenti): kartlar ([PhoneScreen]; otomatik
        // telefon okumasıyla aynı kural).
        screenGroups(if (raw.isEmpty()) lines else raw, handset)?.let { return it }
        header?.let { result.add(group(listOf(it), ScreenPhoneCard.Role.HEADER, handset)) }
        val bubble = mutableListOf<Row>()
        fun finish() {
            if (bubble.isEmpty()) return
            result.add(group(bubble.toList(), role(bubble), handset))
            bubble.clear()
        }
        for (row in rows) {
            if (bubble.isNotEmpty() && !continues(row, bubble.last(), bubble[0], median)) finish()
            bubble.add(row)
        }
        finish()
        return result
    }

    /** Satırın başındaki ve sonundaki harfsiz, rakamsız kırıntılar (emoji ya da simge yanlış okunmuş: "©", "•", "♡") atılır. */
    fun clean(text: String): String {
        val words = text.split(Regex("\\s+")).filter { it.isNotEmpty() }.toMutableList()
        // Para simgesi ("$ in your mailbox") mesajın parçasıdır.
        fun junk(word: String) = word.none { it.isLetter() || it.isDigit() || Character.getType(it) == Character.CURRENCY_SYMBOL.toInt() } &&
            !word.all { ".,!?…'\"-:;()".indexOf(it) >= 0 }
        while (words.isNotEmpty() && junk(words.first())) words.removeAt(0)
        while (words.isNotEmpty() && junk(words.last())) words.removeAt(words.size - 1)
        return words.joinToString(" ")
    }

    /** Aynı yükseklikte yan yana okunmuş parçalar (arada emoji ya da simge) tek satır olur. */
    internal fun joinedRows(rows: List<Row>, join: Double = ROW_JOIN): List<Row> {
        val result = mutableListOf<Row>()
        for (row in rows) {
            val index = result.indexOfLast { sameRow(it, row, join) }
            if (index >= 0) {
                val (a, b) = if (result[index].spot.left <= row.spot.left) result[index] to row else row to result[index]
                result[index] = Row(a.lines + b.lines, a.spot.union(b.spot), a.text + " " + b.text)
            } else {
                result.add(row)
            }
        }
        return result.sortedBy { it.spot.top }
    }

    private fun sameRow(a: Row, b: Row, join: Double): Boolean {
        if (!sameBand(a, b)) return false
        val gap = maxOf(a.spot.left, b.spot.left) - minOf(a.spot.right, b.spot.right)
        // Yatay boşluk ekran genişliğine, satır yüksekliği ekran yüksekliğine oranla; ikisi aynı ölçüye çevrilir.
        return gap * ScreenPhoneCard.Handset.SCREEN_SHAPE <= maxOf(a.height, b.height) * join
    }

    /** İki satır aynı yükseklikte (dikeyde en az yarı yarıya üst üste). */
    private fun sameBand(a: Row, b: Row): Boolean =
        minOf(a.spot.bottom, b.spot.bottom) - maxOf(a.spot.top, b.spot.top) >= minOf(a.height, b.height) * 0.5

    /**
     * Ana ekran mı: hava durumu satırı, bildirim sayacı ("10 Notifications") ya da aynı hizada en az üç uygulama adı (simge
     * ızgarası). Sohbette bunların hiçbiri olmaz; tek başına kısa bir yanıt ("Ok") ana ekran sayılmaz.
     */
    internal fun isHome(rows: List<Row>, raw: List<TextLine>): Boolean {
        if (raw.any { WEATHER.matches(it.text.trim(' ', '\t')) }) return true
        if (rows.any { COUNTER.matches(it.text) }) return true
        val labels = rows.filter { isAppLabel(it.text) && (it.spot.top + it.spot.bottom) / 2 >= HEADER_BAND }
        return labels.any { label -> labels.count { sameBand(it, label) } >= GRID_LABELS }
    }

    /**
     * Uygulama başlatıcı (gerçek ana ekran): bildirim sayacı ya da simge ızgarası var. Yalnız hava satırı ("71°") olan
     * ekran hava uygulamasıdır: oradaki tek sözcüklük satırlar ("Now", "Sunset") uygulama adı değildir, çevrilir
     * (Sinan Bey, beta.100 3422). Mac/iPhone ve Windows ile aynı.
     */
    internal fun isLauncher(rows: List<Row>): Boolean {
        if (rows.any { COUNTER.matches(it.text) }) return true
        val labels = rows.filter { isAppLabel(it.text) && (it.spot.top + it.spot.bottom) / 2 >= HEADER_BAND }
        return labels.any { label -> labels.count { sameBand(it, label) } >= GRID_LABELS }
    }

    /** Uygulama adı gibi: bir-iki sözcük, hepsi harf ve büyük harfle başlıyor, rakam ve noktalama yok ("WhatUp", "Camera"). */
    fun isAppLabel(text: String): Boolean {
        val words = text.split(Regex("\\s+")).filter { it.isNotEmpty() }
        return words.size in 1..2 && words.all { word ->
            word[0].isUpperCase() && word.all { it.isLetter() || it == '-' || it == '\'' || it == '&' }
        }
    }

    /**
     * Ana ekranın blokları: arada dar boşluk ve solda aynı hizada duran satırlar (bileşenin başlığı ve içeriği, bildirimin
     * satırları) bir blok; yan yana duranlar ayrı.
     */
    internal fun homeBlocks(rows: List<Row>, median: Double): List<List<Row>> {
        val blocks = mutableListOf<MutableList<Row>>()
        for (row in rows) {
            val block = blocks.lastOrNull()
            // Bileşenin sayacı ("6 Notifications") başlığın altındadır ama başlığın solunda simge olduğundan sol hizası
            // başlıktan önde başlar: yine aynı bloktur ([WIDGET_INDENT] kadar).
            if (block != null && row.spot.top - block.last().spot.bottom < median * HOME_GAP && row.spot.top >= block.last().spot.top &&
                !sameBand(row, block.last()) && (abs(row.spot.left - block[0].spot.left) <= LEFT_ALIGN ||
                    (block.size == 1 && isCounter(row.text) && block[0].spot.left - row.spot.left <= WIDGET_INDENT &&
                        row.spot.left <= block[0].spot.left))) {
                block.add(row)
            } else {
                blocks.add(mutableListOf(row))
            }
        }
        return blocks
    }

    /** Bileşen başlığının solundaki simgenin payı (düz ekran genişliğine oranla). */
    const val WIDGET_INDENT = 0.2

    /** Bildirim sayacı ("6 Notifications", "3 new messages"). */
    fun isCounter(text: String): Boolean = COUNTER.matches(text.trim())

    /**
     * Ana ekran bileşeni: kısa başlık ve hemen altında sayaç ("Reminders / 6 Notifications"). Sinan Bey (beta.100, 3397):
     * bileşen çevrilmiyordu; panelde tek kart olur ([ScreenPhoneCard.Role.WIDGET]).
     */
    internal fun isWidget(block: List<Row>): Boolean =
        block.size == 2 && isCounter(block[1].text) && !isCounter(block[0].text) && block[0].words in 1..3

    /** Blok tek başına duran kısa bir ad: uygulamanın adı (simge etiketi, "WhatUp"); çevrilmez. */
    internal fun isAppName(block: List<Row>): Boolean = block.size == 1 && isAppLabel(block[0].text)

    /**
     * Otomatik telefon panelinin ([GamePhoneText.groups]) satırları ana ekransa uygulama adları atılmış hâli; saat ve hava
     * harfsiz satır olarak zaten çevrilmez, bileşen ve bildirim yazıları kendi yerinde kalır. Satırların yeri düz ekranda
     * (`phoneBox`) bilinmiyorsa ya da ekran ana ekran değilse satırlar olduğu gibi döner ("Ekranı çevir" ile aynı kural).
     */
    fun withoutAppNames(lines: List<TextLine>): List<TextLine> {
        if (!isHomeScreen(lines)) return lines
        val rows = homeRows(lines)
        val median = rows.map { it.height }.sorted()[rows.size / 2]
        val names = if (isLauncher(rows)) homeBlocks(rows, median).filter(::isAppName).flatMap { it[0].lines } else emptyList()
        // Saat ("7PM", "10 PM") çevrilmez (Sinan Bey, beta.100 3422: "10PM" "22:00" yazılıyordu).
        return lines.filter { line ->
            line.text.count { it.isLetter() } >= 2 && !PhoneScreen.isTime(line.text) &&
                names.none { it.text == line.text && it.phoneBox == line.phoneBox }
        }
    }

    /**
     * Satırlar (düz ekrandaki yerleri bilinen) telefonun ana ekranı mı; sohbet panelinde ana ekran yazıları kendi yerinde
     * kalır ([GamePhoneText.roles]; Mac ile aynı).
     */
    fun isHomeScreen(lines: List<TextLine>): Boolean {
        if (lines.isEmpty() || lines.any { it.phoneBox == null }) return false
        val rows = homeRows(lines)
        return rows.isNotEmpty() && isHome(rows, lines)
    }

    private fun homeRows(lines: List<TextLine>): List<Row> {
        val single = lines.map { Row(listOf(it), it.phoneBox!!, clean(it.text)) }
            .filter { row -> row.text.count { it.isLetter() } >= 2 }.sortedBy { it.spot.top }
        return joinedRows(single, HOME_JOIN)
    }

    /**
     * Ana ekranın yazıları: bir arada duran satırlar (bileşenin başlığı ve içeriği, bildirimin satırları) birer blok, her
     * satır kendi yerinde ayrı çevrilir (alt satıra sarılmış cümle birleşir). Tek başına duran kısa ad (simge etiketi,
     * "WhatUp") uygulamanın adıdır, çevrilmez; saat ve hava zaten harfsiz satırlarla birlikte atılmıştır. Gruplar
     * [ScreenPhoneCard.Role.HOME] rolündedir: kart kurulmaz, özgün stilinde yerinde çizilir.
     */
    internal fun homeGroups(rows: List<Row>, median: Double, handset: ScreenPhoneCard.Handset): List<ScreenTranslation.Group> {
        val result = mutableListOf<ScreenTranslation.Group>()
        val launcher = isLauncher(rows)
        for (block in homeBlocks(rows.filter { !PhoneScreen.isTime(it.text) }, median)) {
            if (launcher && isAppName(block)) continue
            if (isWidget(block)) {
                val boxes = block.flatMap { it.lines }.mapNotNull { it.box }
                result.add(group(listOf(block[0]), ScreenPhoneCard.Role.WIDGET, handset).copy(
                    paragraphs = listOf(block[0].text, block[1].text),
                    box = boxes.drop(1).fold(boxes[0]) { total, box -> total.union(box) },
                    phone = ScreenPhoneCard.Placement(ScreenPhoneCard.Role.WIDGET, block[0].spot.union(block[1].spot))))
                continue
            }
            val piece = mutableListOf<Row>()
            for (row in block) {
                val continues = row.text.firstOrNull { it.isLetter() }?.isLowerCase() == true &&
                    piece.isNotEmpty() && !endsSentence(piece.last().text)
                if (piece.isNotEmpty() && !continues) {
                    result.add(group(piece.toList(), ScreenPhoneCard.Role.HOME, handset))
                    piece.clear()
                }
                piece.add(row)
            }
            if (piece.isNotEmpty()) result.add(group(piece.toList(), ScreenPhoneCard.Role.HOME, handset))
        }
        return result
    }

    /**
     * Sohbet dışı ekranın kartları ([PhoneScreen.kind]/[PhoneScreen.cards], satırların düz ekrandaki yeriyle); ekran
     * sohbetse null. Ekranın üst/alt kenarından taşan kesik satırlar kartlara girmez. Mac/iPhone ve Windows ile aynı.
     */
    internal fun screenGroups(lines: List<TextLine>, handset: ScreenPhoneCard.Handset): List<ScreenTranslation.Group>? {
        val boxed = lines.filter { it.box != null }
        val all = boxed.map { PhoneScreen.Line(clean(it.text), handset.flat(it.box!!)) }
        val kind = PhoneScreen.kind(all)
        if (kind == PhoneScreen.Kind.CHAT) return null
        val result = mutableListOf<ScreenTranslation.Group>()
        for (card in PhoneScreen.cards(all, kind)) {
            val rows = card.lines.filter { all[it].spot.top >= -EDGE_CUT && all[it].spot.bottom <= 1 + EDGE_CUT }
            if (rows.isEmpty()) continue
            val titled = card.titled && rows.size >= 2 && rows[0] == card.lines[0]
            val paragraphs = PhoneScreen.paragraphs(PhoneScreen.Card(rows, titled, card.bold), all)
            val boxes = rows.map { boxed[it].box!! }
            val spots = rows.map { all[it].spot }
            val heights = spots.map { it.bottom - it.top }.sorted()
            result.add(ScreenTranslation.Group(paragraphs, boxes.drop(1).fold(boxes[0]) { total, box -> total.union(box) },
                heights[(heights.size - 1) / 2] * handset.screenHeight,
                phone = ScreenPhoneCard.Placement(ScreenPhoneCard.Role.CARD, spots.drop(1).fold(spots[0]) { total, spot -> total.union(spot) },
                    titled = titled, bold = card.bold)))
        }
        return result
    }

    /** Başlık: ekranın en üstündeki kısa, cümle olmayan satır; ortalı ya da (solda avatarın yanında) ad gibi yazılmış. */
    internal fun isHeader(row: Row): Boolean {
        val v = (row.spot.top + row.spot.bottom) / 2
        if (v >= HEADER_BAND || row.words !in 1..4 || endsSentence(row.text)) return false
        return abs(row.center - 0.5) <= HEADER_CENTER || looksLikeName(row.text)
    }

    /** Ad gibi: bir-üç sözcük, her biri büyük harf ya da rakamla başlar, virgül ve cümle sonu yok. */
    fun looksLikeName(text: String): Boolean {
        val words = text.split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.size !in 1..3 || text.contains(',') || endsSentence(text)) return false
        return words.all { it[0].isUpperCase() || it[0].isDigit() }
    }

    fun endsSentence(text: String): Boolean = text.trim().lastOrNull()?.let { ".!?…".indexOf(it) >= 0 } ?: false

    /**
     * Sohbet listesi: en az iki "ad + hemen altında aynı hizada önizleme" çifti ve satırların çoğu bu çiftlerde. Liste
     * ise her satırın rolü, değilse null.
     */
    internal fun contactList(rows: List<Row>, median: Double): List<ScreenPhoneCard.Role>? {
        val roles = MutableList(rows.size) { ScreenPhoneCard.Role.HEADING }
        var pairs = 0
        var index = 0
        while (index + 1 < rows.size) {
            val name = rows[index]
            val preview = rows[index + 1]
            if (looksLikeName(name.text) && preview.words >= 2 && abs(name.spot.left - preview.spot.left) <= LEFT_ALIGN &&
                preview.spot.top - name.spot.bottom <= median * 0.7 && name.spot.left < 0.5) {
                roles[index] = ScreenPhoneCard.Role.CONTACT
                roles[index + 1] = ScreenPhoneCard.Role.PREVIEW
                pairs += 1
                index += 2
            } else {
                index += 1
            }
        }
        if (pairs < 2 || pairs * 2 * 10 < rows.size * 6) return null
        // Çifte girmeyen ad gibi satırlar bölüm başlığıdır ("Messages"), uzunlar tek başına önizlemedir.
        for (i in rows.indices) if (roles[i] == ScreenPhoneCard.Role.HEADING && !looksLikeName(rows[i].text)) roles[i] = ScreenPhoneCard.Role.PREVIEW
        return roles
    }

    /** Satır, açık balonun devamı mı: arada dar boşluk ve aynı hiza (solda; sağa yaslı balonda sağda da olur). */
    private fun continues(row: Row, last: Row, first: Row, median: Double): Boolean {
        if (row.spot.top - last.spot.bottom >= median * BUBBLE_GAP) return false
        if (abs(row.spot.left - first.spot.left) <= LEFT_ALIGN) return true
        return minOf(row.spot.left, first.spot.left) > 0.2 && abs(row.spot.right - last.spot.right) <= RIGHT_ALIGN
    }

    /**
     * Balonun rolü yaslı olduğu kenardan: sağa yaslı giden, sola yaslı gelen; ortalı kısa satır not; iki yanı da dar
     * (ekranı dolduran) balon belirsiz, tarafı kartta balonun renginden seçilir.
     */
    internal fun role(bubble: List<Row>): ScreenPhoneCard.Role {
        val spot = bubble.drop(1).fold(bubble[0].spot) { total, row -> total.union(row.spot) }
        val left = maxOf(0.0, spot.left)
        val right = maxOf(0.0, 1 - spot.right)
        if (bubble.size == 1 && abs((spot.left + spot.right) / 2 - 0.5) <= NOTE_CENTER && left >= NOTE_MARGIN && right >= NOTE_MARGIN)
            return ScreenPhoneCard.Role.NOTE
        if (left < WIDE_MARGIN && right < WIDE_MARGIN) return ScreenPhoneCard.Role.MESSAGE
        if (right < left * SIDE_RATIO) return ScreenPhoneCard.Role.OUTGOING
        if (left < right * SIDE_RATIO) return ScreenPhoneCard.Role.INCOMING
        return ScreenPhoneCard.Role.MESSAGE
    }

    /** Satırlar tek parça olur: satır sonunda tireyle bölünmüş sözcük boşluksuz birleşir. */
    private fun group(rows: List<Row>, role: ScreenPhoneCard.Role, handset: ScreenPhoneCard.Handset): ScreenTranslation.Group {
        var text = ""
        for (row in rows) {
            text = when {
                text.isEmpty() -> row.text
                text.endsWith("-") -> text + row.text
                else -> text + " " + row.text
            }
        }
        val boxes = rows.flatMap { it.lines }.mapNotNull { it.box }
        val spot = rows.drop(1).fold(rows[0].spot) { total, row -> total.union(row.spot) }
        // Eğik telefonda okunan kutu satırın eğimini de kapsar; yazı boyu düz ekrandaki yükseklikten gelir.
        val heights = rows.map { it.height }.sorted()
        return ScreenTranslation.Group(listOf(text), boxes.drop(1).fold(boxes[0]) { total, box -> total.union(box) },
            heights[heights.size / 2] * handset.screenHeight, phone = ScreenPhoneCard.Placement(role, spot))
    }
}
