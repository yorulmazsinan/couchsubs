// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/** Yazının yeri, içinde bulunduğu alanın kenarlarına oranla (0–1, üstten ve soldan). */
data class TextBox(val left: Double, val top: Double, val right: Double, val bottom: Double) {
    fun union(other: TextBox) =
        TextBox(minOf(left, other.left), minOf(top, other.top), maxOf(right, other.right), maxOf(bottom, other.bottom))

    /** Bu kutu [area] içindeki oranlarsa, aynı yerin [area]'yı içeren çerçevedeki oranları. */
    fun placedIn(area: TextBox): TextBox {
        val width = area.right - area.left
        val height = area.bottom - area.top
        return TextBox(area.left + left * width, area.top + top * height, area.left + right * width, area.top + bottom * height)
    }

    /**
     * Ekranın ortasındaki altyazının kutusu ortaya göre simetrik genişletilir: yazı tanıma satırın bir ucunu
     * okuyamazsa çeviri yine ortalanır ve İngilizcenin tamamını örter. Köşedeki yazıya dokunulmaz.
     */
    fun centeredOnScreen(): TextBox {
        val middle = (left + right) / 2
        if (middle <= 0.3 || middle >= 0.7) return this
        return copy(left = maxOf(0.0, minOf(left, 1 - right)), right = minOf(1.0, maxOf(right, 1 - left)))
    }
}

/** Karede okunan alan (oranlar); masaüstüyle aynı varsayılan: alt orta bölge. */
data class CropRegion(val top: Double = 0.62, val bottom: Double = 0.97, val left: Double = 0.14, val right: Double = 0.86) {
    val box get() = TextBox(left, top, right, bottom)
}

/**
 * Yazı tanımanın bulduğu bir satır; kutu okunan alana göredir, bilinmiyorsa null. [words]: okuyucu sözcüklerin yerini de
 * veriyorsa (ML Kit) sözcükler, satırla aynı oranlarda; kumanda simgesini bulmak için ([ButtonIcons]). [icons]: metindeki
 * her [ButtonIcons.MARKER] için, sırasıyla, simgenin yeri ve okunan hali.
 */
data class TextLine(
    val text: String, val box: TextBox? = null, val words: List<TextWord>? = null, val icons: List<IconSlot>? = null,
    /** Okuyucunun güveni (0–1); bilinmiyorsa null. Otomatik ekran yazısında düşük güvenli satır çevrilmez. */
    val confidence: Float? = null,
    /** Oyun telefonunda satırın düzleştirilmiş ekrandaki yeri ([GamePhoneReader]); [box] karedeki gerçek yeridir. */
    val phoneBox: TextBox? = null,
    /**
     * Telefonun sohbet listesinde ([GamePhoneText.forTranslation]) satırın rolü: kişi adı, önizleme ya da bölüm başlığı.
     * Liste değilse null. iPhone ile aynı.
     */
    internal val listRole: ScreenPhoneCard.Role? = null,
)

/** Yazı tanımanın bulduğu bir sözcük ve yeri (okunan alanın kenarlarına oranla). */
data class TextWord(val text: String, val box: TextBox)

/**
 * Yazının içindeki kumanda simgesi ("Hold △ to sprint"). Yazı tanıma simgeyi harf sanır ("A", "Ä") ya da hiç okumaz;
 * [text] okunan hali (boş olabilir), [box] karedeki yeri, [image] kareden kesilen simgenin PNG'si (data: adresi;
 * kesilemediyse null). Windows: Reading.cs IconSlot.
 */
data class IconSlot(val box: TextBox, val text: String, val image: String? = null)

/** Bir karenin okunan satırları, yukarıdan aşağı (Windows: Reading.cs, Mac: Reading.swift). */
class Reading(lines: List<TextLine>) {
    val lines: List<TextLine> = lines.filter { it.text.isNotBlank() }

    companion object {
        val Empty = Reading(emptyList())

        /** Altyazının okunduğu yükseklikten uzak ortalanmamış blok atılınca günlüğe yazılan neden (GitHub #1293). */
        internal const val OFF_BAND_REASON = "ortalanmamış, altyazının okunduğu yükseklikten uzak (menü açıklaması)"

        /** [isMenu]: menü satırlarının sol ya da sağ kenarı bu kadar içinde hizalı (okunan alana oranla). */
        const val MENU_EDGE = 0.012

        /** Ayrı konuşma blokları arasındaki en büyük boşluk (satır yüksekliğine oranla); bkz. spokenTogether. */
        const val TOGETHER_GAP = 3.0
        /** Menü listesi sayılıp atılan okumanın günlük nedeni ([isHistoryList]). */
        const val LIST_REASON = "menü listesi (eşit aralıklı satırlar), altyazı değil"
        /** Liste satırlarının aralığı satır yüksekliğinin en az bu katı (altyazının satırları bitişiktir). */
        const val LIST_PITCH = 1.8
        /** Aralık bundan büyükse ayrı yazılardır. */
        const val LIST_MAX_PITCH = 4.0
        /** Ardışık aralıklar en çok bu oranda farklı. */
        const val LIST_SPREAD = 1.3

        /**
         * Ortalı blok bu kadar süredir hiç değişmediyse ve yanında ondan en az [StickyRows.YOUNGER_BY_MS] daha yeni (kırıntı
         * olmayan) ortalı blok varsa altyazı sayılmaz. Kullanıcı bildirimi (GitHub #933, GTA 6): karakter TV izlerken haber
         * programının alt bandı konuşma altyazısının altında duruyor, en alttaki ortalı blok olarak her karede bant
         * seçiliyor, konuşma hiç çevrilmiyordu. Bant çoğu zaman "EXCLUSIVE: …", "BREAKING NEWS: …" diye başlıyor, konuşan
         * adı sanılıp her zaman altyazı seçiliyordu. Tek ortalı blok (değişmeyen uzun cümle) seçilmeye devam eder. Konuşan
         * adlı sabit blok yalnız yanındaki yeni blok en az üç sözcüklü bir cümleyse atlanır: kısa görev/HUD yazısı uzun
         * konuşmayı geçmez (Mac: Reading.staleMs, Windows: Reading.StaleMs).
         */
        const val STALE_MS = 5000L

        /** [joiningRows]: aynı satırdaki iki parça arasındaki en büyük boşluk (alan genişliğine oranla). */
        const val ROW_GAP = 0.05

        /** Tek başına okunan adın sağındaki cümle aynı satırda sayılır: dikeyde küçük yüksekliğin en az bu kadarı örtüşür, */
        const val NAME_ROW_OVERLAP = 0.3

        /** ve aralarındaki boşluk en çok bu kadar (alan genişliğine oranla). */
        const val NAME_ROW_GAP = 0.12

        /** Tek başına okunan adın altındaki cümle ona aittir: aradaki boşluk en çok satır yüksekliğinin bu katı. */
        const val NAME_ABOVE_GAP = 1.5

        /**
         * Aynı bloğun satırları arasındaki en büyük boşluk (satır yüksekliğine oranla). GTA 6 gibi geniş satır aralıklı
         * altyazılarda 0,6 eşiği iki satırlı altyazıyı iki bloğa bölüyor, yalnız biri çevriliyordu (GitHub #822); 0,8 geri
         * geldi. Alttaki satır üsttekinin devamıysa [CONTINUATION_GAP] geçerlidir (Mac/Windows: aynı eşikler).
         */
        const val LINE_GAP = 0.8

        /**
         * Konuşma satırı, altındaki görev/hedef satırının yazısından en az bu kat büyükse görev ayrı bloktur
         * ([isSmallerObjective]). Büyük harfle başlayan kuyruksuz kısa satırın ("Go on.") kutusu en çok ~1,45 kat alçak
         * çıkar; GTA 6 ve RDR2'nin görev yazısı konuşmanın yarısından da küçüktür (Mac/Windows: aynı eşik).
         */
        const val OBJECTIVE_SCALE = 1.6
        const val CONTINUATION_GAP = 1.3

        /**
         * [CONTINUATION_GAP] yalnız üstteki satır en az bu kadar sözcükken geçerlidir: altyazının sarılmış ilk satırı uzundur.
         * Tek sözcüklük üst satır (GTA 6 telefon bildiriminde gönderenin adı "Cal", altında "Checked th…") geniş boşlukla
         * alttakine katılınca altyazı seçiliyordu (gerçek kare gta6-n4-bildirim; Mac/Windows: aynı eşik).
         */
        const val CONTINUATION_MIN_WORDS = 3

        fun fromText(text: String) = Reading(text.replace("\r\n", "\n").split('\n').map { TextLine(it.trim()) })

        /** Aynı satırdaki iki sözcük arasındaki boşluk ayrı yazılara mı işaret ediyor (menü ile gösterge gibi). */
        fun isSeparateText(gap: Double, lineHeight: Double, imageWidth: Double) =
            gap > lineHeight * 4 && gap > imageWidth * 0.12

        private fun wordCount(text: String) = text.split(Regex("\\s+")).count { it.isNotEmpty() }

        /**
         * [next] satırı [upper]'ın devamı mı: üstteki cümle bitmemiş (nokta, ünlem, soru işaretiyle bitmiyor) ve alttaki
         * küçük harfle başlıyor ya da üstteki virgül/tireyle bitiyor ya da alttaki en çok üç sözcük. Konuşan adlı alt satır
         * ("Lucia: …") yeni konuşmadır, devam sayılmaz (Windows: Reading.Continues, Mac: Reading.continues).
         */
        fun continues(upper: String, next: String): Boolean {
            val top = upper.trim()
            val below = next.trim()
            if (top.isEmpty() || below.isEmpty() || SubtitleStabilizer.endsSentence(top)) return false
            if (SpeakerPrefix.split(below) != null) return false
            val first = below.firstOrNull { it.isLetter() }
            return (first != null && first.isLowerCase()) || top.endsWith(",") || top.endsWith("-") || top.endsWith("—") ||
                wordCount(below) <= 3
        }
    }

    val text: String get() = lines.joinToString("\n") { it.text }

    /** Bütün satırları içine alan kutu; hiçbir satırın yeri bilinmiyorsa null. */
    val box: TextBox?
        get() {
            var total: TextBox? = null
            for (line in lines) line.box?.let { total = total?.union(it) ?: it }
            return total
        }

    /** Oyunun düğme ipuçları ("R2 Swing", "△ Pick up") çıkarılmış hali; bunlar altyazı değildir. */
    /**
     * Düğme ipuçları ("R2 Swing", "Press @ to open the map") çıkarılmış hali. Simgesi bulunmuş satır (`withButtonIcons`;
     * "Ekranı çevir" ve ek alanlar) kalır: simgesiyle çevrilir, düğme görünür. Simgesi bulunamayan ipucu atılır; çevrilmediği
     * için üstü örtülmez (Windows: WithoutButtonPrompts).
     */
    fun withoutButtonPrompts() = Reading(lines.filter { !it.icons.isNullOrEmpty() || !ButtonPrompts.isPrompt(it.text) })

    /** Yazı tanımanın uydurduğu sözcük çöpleri ("ou$3e") ayıklanmış hali. */
    fun withoutOcrNoise(keepIdentifiers: Boolean = false) = Reading(lines.map { it.copy(text = OcrNoise.clean(it.text, keepIdentifiers)) })

    /** Yazının içindeki kumanda simgeleri [ButtonIcons.MARKER] ile işaretlenmiş hali (bkz. [ButtonIcons.mark]). */
    fun withButtonIcons() = Reading(ButtonIcons.joinHints(this).lines.map { ButtonIcons.mark(it) })

    /**
     * [withButtonIcons], ayrıca fiilsiz yerlerdeki simgeler (tuş çubuğu, satır başı) [frame]'den (okunan görüntü)
     * doğrulanarak işaretlenir ([ButtonIcons.markFree]). [monochrome]: yalnız renksiz simgeler (otomatik ekran yazısı;
     * [color] gerekir). Mac ve Windows WithButtonIcons(frame) ile aynı.
     */
    fun withButtonIcons(frame: GrayFrame, color: ((Int, Int) -> Int)? = null, monochrome: Boolean = false) =
        Reading(withButtonIcons().lines.map { ButtonIcons.markFree(it, frame, color, monochrome) })

    /**
     * Aynı satırda yan yana okunan parçalar soldan sağa tek satır olur. Renkli konuşan adını ("Arthur:", RDR2) yazı
     * tanıma cümleden ayrı okuyabiliyor; parçalar yalnız üst kenarlarına göre dizilince ad cümlenin sonuna düşüyor ya da
     * ayrı blok sayılıp atılıyordu. Yatayda aralarında en çok [ROW_GAP] (alan genişliğine oranla) olan parçalar
     * birleşir; uzaktaki köşe yazısı ayrı kalır (Mac: Reading.joiningRows, Windows: Reading.JoiningRows).
     *
     * Tek başına okunan konuşan adı ("Lucia:", [SpeakerPrefix.nameOnly]) cümlesine katılır: aynı satırdaysa daha gevşek
     * ölçüyle (renkli adın kutusu cümleninkinden kaymış ya da biraz uzak okunabiliyor; [NAME_ROW_OVERLAP], [NAME_ROW_GAP]),
     * cümlenin hemen üstündeyse ([NAME_ABOVE_GAP]) altındaki satırın başına. Kullanıcı bildirimi (X): konuşan adı
     * diyalogların yalnız ~%20'sinde görünüyordu. Ayrı satır kalan ad, aynı kişi konuşmayı sürdürdükçe değişmeden durduğu
     * için görev/HUD satırı sayılıp ([StickyRows]) atılıyor, ad yalnız konuşan değişince görünüyordu; aynı satırda ama ayrı
     * okunan ad ise ayrı blok sayılıp hiç gösterilmiyordu. Yerleri bilinmeyen satırlarda ad alttaki satıra katılır.
     */
    fun joiningRows(): Reading {
        if (lines.size < 2) return this
        if (lines.any { it.box == null }) return joiningSpeakerNames()
        val rows = mutableListOf<TextLine>()
        for (line in lines.sortedBy { it.box!!.left }) {
            val box = line.box!!
            val index = rows.indexOfFirst { sameRow(box, it.box!!) || (SpeakerPrefix.nameOnly(it.text) != null && nameRow(box, it.box!!)) }
            if (index >= 0) {
                val row = rows[index]
                rows[index] = TextLine(row.text + " " + line.text, row.box!!.union(box))
            } else {
                rows.add(line)
            }
        }
        return Reading(rows.sortedBy { it.box!!.top }).joiningSpeakerNames()
    }

    private fun sameRow(next: TextBox, row: TextBox): Boolean {
        val overlap = minOf(next.bottom, row.bottom) - maxOf(next.top, row.top)
        val smaller = minOf(next.bottom - next.top, row.bottom - row.top)
        if (smaller <= 0 || overlap < smaller * 0.6) return false
        return next.left - row.right <= ROW_GAP
    }

    /** [next], solundaki tek başına ad ([name]) ile aynı satırda mı ([NAME_ROW_OVERLAP], [NAME_ROW_GAP]). */
    private fun nameRow(next: TextBox, name: TextBox): Boolean {
        val overlap = minOf(next.bottom, name.bottom) - maxOf(next.top, name.top)
        val smaller = minOf(next.bottom - next.top, name.bottom - name.top)
        if (smaller <= 0 || overlap < smaller * NAME_ROW_OVERLAP) return false
        return next.left - name.right <= NAME_ROW_GAP
    }

    /**
     * Tek başına okunan ad, altındaki cümle satırının başına katılır (bkz. [joiningRows]). Satırın kutusu cümleninkidir,
     * yatayda adı da kapsar: yükseklik cümle satırınınki kalır, blok ayırma ve yazı boyu karşılaştırması bozulmaz.
     */
    private fun joiningSpeakerNames(): Reading {
        val result = lines.toMutableList()
        var index = 0
        while (index < result.size) {
            val name = SpeakerPrefix.nameOnly(result[index].text)
            val partner = if (name != null) sentenceBelow(index, result) else null
            if (name == null || partner == null) {
                index++
                continue
            }
            val line = result[partner]
            val label = result[index]
            val own = line.box
            val named = label.box
            val box = if (own != null && named != null) {
                TextBox(minOf(own.left, named.left), own.top, maxOf(own.right, named.right), own.bottom)
            } else {
                own
            }
            val confidence = listOfNotNull(label.confidence, line.confidence).minOrNull()
            result[partner] = TextLine("$name: ${line.text.trim()}", box, confidence = confidence)
            result.removeAt(index)
        }
        return if (result.size == lines.size) this else Reading(result)
    }

    /**
     * [index]teki tek başına adın cümlesi: altındaki (üst kenarı adın ortasının altında), aradaki boşluğu satır
     * yüksekliğinin en çok [NAME_ABOVE_GAP] katı olan, yatayda adla örtüşen en yakın satır. Satır kendisi adla başlamaz,
     * harf taşır. Yerler bilinmiyorsa hemen sonraki satır.
     */
    private fun sentenceBelow(index: Int, lines: List<TextLine>): Int? {
        fun sentence(text: String) =
            text.any { it.isLetter() } && SpeakerPrefix.nameOnly(text) == null && SpeakerPrefix.split(text) == null
        val name = lines[index].box
        if (name == null) {
            val next = index + 1
            return if (next < lines.size && lines[next].box == null && sentence(lines[next].text)) next else null
        }
        val height = name.bottom - name.top
        return (index + 1 until lines.size).filter { other ->
            val box = lines[other].box
            box != null && sentence(lines[other].text) && box.top >= name.top + height / 2 &&
                box.top - name.bottom <= NAME_ABOVE_GAP * maxOf(height, box.bottom - box.top) &&
                minOf(box.right, name.right) - maxOf(box.left, name.left) > 0
        }.minByOrNull { lines[it].box!!.top }
    }

    /**
     * Alandaki altyazı bloğu: satırlar yerlerine göre bloklara ayrılır; ortalanmış ve menü olmayan en alttaki blok
     * altyazıdır. Ortalanmış blok yoksa en az üç sözcüklü, menü olmayan en alttaki blok alınır. Satırların yeri
     * bilinmiyorsa okuma olduğu gibi kalır. [area]: okunan alanın karedeki yeri. Tek satırlık etkileşim/HUD etiketi
     * ("TAKE AMMO PACK (0/3)", [ButtonPrompts.isActionLabel]) ve sahne yazısı (tabela, tişört; [SceneText]) altyazı
     * bloğu sayılmaz. [band]: bu oturumda altyazının okunduğu yükseklikler; [dropped]: sahne yazısı sayılıp atılan her
     * blok ve nedeni (altyazı günlüğü için). "Tam ekran" alanda ekranın kenarındaki bildirim kartı ([ScreenNotices.isNotice])
     * altyazı bloğu sayılmaz, [notices] ile bildirilir (satır kutuları alana oranlı); kendi yerinde çevrilir. Önceden
     * ortalanmış blok yokken altyazı seçilip ekranın ortasında çiziliyordu. [age]: satırın ne kadar süredir değişmeden
     * okunduğu ([StickyRows.unchangedMs]); verilirse [STALE_MS]'dir değişmeyen ortalı blok, yanında yeni beliren ortalı
     * blok varken seçilmez, atlanan blok [stale] ile bildirilir. [darkInk]: satır kutusu açık zeminde koyu yazı mı
     * ([InkTone.sampler]; kâğıt ilan sahne yazısıdır, GitHub #1124); verilmezse renge bakılmaz.
     */
    fun subtitleBlock(
        area: TextBox, band: SubtitleBand? = null, notices: ((Reading) -> Unit)? = null,
        age: ((String) -> Long?)? = null, stale: ((Reading) -> Unit)? = null,
        darkInk: ((TextBox) -> Boolean)? = null,
        dropped: ((Reading, String) -> Unit)? = null,
    ): Reading {
        if (lines.isEmpty() || lines.any { it.box == null }) return if (isActionLabel) Empty else this
        // Menünün konuşma/yardım geçmişi listesi ([isHistoryList]) altyazı değildir: hiçbir satırı altyazı seçilmez.
        if (isHistoryList) {
            dropped?.invoke(this, LIST_REASON)
            return Empty
        }
        val blocks = mutableListOf<MutableList<TextLine>>()
        for (line in lines.sortedBy { it.box!!.top }) {
            val placed = line.box!!.placedIn(area)
            val index = blocks.indexOfLast { belongs(placed, line.text, it, area) }
            if (index >= 0) blocks[index].add(line) else blocks.add(mutableListOf(line))
        }
        // Tabela, tişört, plaka gibi sahne yazısı ([SceneText]) altyazı alanına düşse de altyazı değildir.
        val candidates = blocks.flatMap { withoutSignLines(it) }.map { Reading(it) }.filter { block ->
            if (block.isMenu || block.isActionLabel) return@filter false
            val reason = SceneText.reason(block, area, band, darkInk) ?: return@filter true
            dropped?.invoke(block, reason)
            false
        }.filter { block ->
            if (!ScreenNotices.isWholeScreen(area) || !ScreenNotices.isNotice(block.box!!.placedIn(area))) return@filter true
            notices?.invoke(block)
            false
        }
        val middle = candidates.filter { reading ->
            val placed = reading.box!!.placedIn(area)
            abs((placed.left + placed.right) / 2 - 0.5) <= 0.12
        }
        // Görev satırı altyazıyla aynı anda belirince ayrı blok olur (aralık ya da yazı boyu farkı): konuşan adı taşıyan
        // blok altyazıdır ("Lucia: …" görevin üstünde de dursa).
        val centered = withoutStale(middle, age, stale)
        // Aynı anda konuşan kişilerin alt alta duran ayrı blokları ([spokenTogether]) tek altyazıda, her biri kendi satırında.
        val spoken = centered.indexOfFirst { isSpoken(it) }
        if (spoken >= 0) return spokenTogether(spoken, centered, area)
        if (centered.isNotEmpty()) {
            val lowest = centered.indices.maxBy { centered[it].box!!.bottom }
            return objectiveBelow(lowest, centered, area) ?: centered[lowest]
        }
        // Ortalanmış blok yoksa en alttaki en az üç sözcüklü blok. Bu oturumda altyazının okunduğu yükseklik biliniyorsa
        // ondan uzak ortalanmamış blok altyazı değildir (GitHub #1293: kayıt menüsünün sola yaslı görev açıklaması
        // altyazı sanılıp çevriliyordu). Mac ve Windows aynı.
        return candidates.filter { block ->
            if (wordCount(block.text) < 3) return@filter false
            if (band == null || band.isEmpty || band.contains(block.box!!.placedIn(area))) return@filter true
            dropped?.invoke(block, OFF_BAND_REASON)
            false
        }.maxByOrNull { it.box!!.bottom } ?: Empty
    }

    /**
     * En alttaki blok, hemen üstündeki konuşmanın altına onunla aynı anda gelen görev satırı mı: tek satır ve üstündeki
     * ortalanmış bloktan (arada en çok üç satır boyu) belirgin kısa ([StickyRows.JOINED_SHARE]). Öyleyse altyazı üstteki
     * bloktur. Kullanıcı bildirimi (X, beta.69, GTA 6): "John'u takip et" konuşmayla birlikte belirince en alttaki blok
     * olarak altyazı seçiliyor, konuşma hiç çevrilmiyordu. Görev ekranda kalınca sonraki konuşmalarda [StickyRows] onu
     * ayırır (Windows ve Mac ile aynı).
     */
    private fun isSpoken(block: Reading): Boolean = SpeakerPrefix.split(block.lines[0].text) != null

    /**
     * Kalabalık sahnede birden çok kişi aynı anda konuşur (GTA 6 yan konuşmaları; X, beta.100): ekranda alt alta, her biri
     * konuşan adıyla başlayan 2–3 ayrı blok durur. Önceden yalnız en üstteki seçiliyor, öbürleri atılıyordu. Adla başlayan
     * ilk bloğun altındaki, yine adla başlayan, aynı yazı boyundaki (1,25 kat) ve arası en çok [TOGETHER_GAP] satır boyu olan
     * bloklar yukarıdan aşağı tek altyazıda birleşir: her konuşan kendi satırında, adıyla. Arada adsız blok (görev satırı)
     * varsa birleştirme orada durur. Mac/iPhone (Reading.spokenTogether) ve Windows (Reading.SpokenTogether) aynı.
     */
    private fun spokenTogether(index: Int, centered: List<Reading>, area: TextBox): Reading {
        val ordered = centered.indices.sortedBy { centered[it].box!!.top }
        val start = ordered.indexOf(index)
        if (start < 0) return centered[index]
        val lines = centered[index].lines.toMutableList()
        for (other in ordered.drop(start + 1)) {
            val block = centered[other]
            if (!isSpoken(block)) break
            val upper = lines.last().box?.placedIn(area) ?: break
            val lower = block.lines[0].box?.placedIn(area) ?: break
            val own = lower.bottom - lower.top
            val previous = upper.bottom - upper.top
            if (own <= 0 || previous <= 0 || maxOf(own, previous) > 1.25 * minOf(own, previous) ||
                lower.top < upper.bottom - minOf(own, previous) * 0.25 ||
                lower.top - upper.bottom > maxOf(own, previous) * TOGETHER_GAP) break
            lines += block.lines
        }
        return if (lines.size == centered[index].lines.size) centered[index] else Reading(lines)
    }

    /**
     * Satırlar ortaya hizalı ve boyları farklı mı (sol kenarları hizasız, ortaları hizalı): aynı anda konuşan kişilerin
     * ayrı altyazı blokları böyle durur (X, beta.100, GTA 6 kalabalık sahne). Menünün geçmiş listesi sola yaslıdır; üç
     * eşit aralıklı ortalı konuşma satırı liste sayılıp altyazının tamamı atılıyordu (Mac/iPhone ve Windows aynı).
     */
    private fun centeredSpeech(boxes: List<TextBox>): Boolean {
        val lefts = boxes.map { it.left }
        val centers = boxes.map { (it.left + it.right) / 2 }
        return lefts.max() - lefts.min() > MENU_EDGE * 2 && centers.max() - centers.min() <= MENU_EDGE * 2
    }

    private fun objectiveBelow(index: Int, centered: List<Reading>, area: TextBox): Reading? {
        val lowest = centered[index]
        if (lowest.lines.size != 1) return null
        val box = lowest.box!!.placedIn(area)
        val height = box.bottom - box.top
        val above = centered.indices.filter { other ->
            val placed = centered[other].box!!.placedIn(area)
            other != index && placed.bottom <= box.top + height * 0.25 && box.top - placed.bottom <= height * 3
        }.map { centered[it] }.maxByOrNull { it.box!!.bottom } ?: return null
        // Görev yazısı konuşmadan belirgin küçük yazıyla (isSmallerObjective): konuşma kısa olsa da ("Okay.") altyazı
        // üstteki bloktur; görev uzun diye konuşmayı yutmaz.
        val upper = above.lines.last().box?.placedIn(area)
        if (upper != null && isSmallerObjective(lowest.text, height, upper.bottom - upper.top, above.lines.last().text)) return above
        return if (letters(lowest.text) <= StickyRows.JOINED_SHARE * letters(above.text)) above else null
    }

    /**
     * [text] satırı, üstündeki konuşma satırının (yüksekliği [upper]) altında duran görev/hedef yazısı mı: konuşan adı
     * taşımıyor, büyük harfle başlıyor, ikisi de küçük harf taşıyor (BÜYÜK HARFLİ tabela satırları bölünmez) ve yazısı konuşmanınkinden en az [OBJECTIVE_SCALE] kat küçük. Kullanıcı bildirimi
     * (beta.100, GTA 6): kısa görev yazısı (en çok üç sözcük) konuşmanın devamı sayılıp yazı boyu karşılaştırılmıyor,
     * "Come on Lose the cops" diye tek altyazı çevriliyordu. Küçük harfle başlayan devam satırı ("now.") bu kurala
     * girmez (GitHub #715; Mac/Windows: aynı kural).
     */
    internal fun isSmallerObjective(text: String, height: Double, upper: Double, spoken: String): Boolean {
        if (height <= 0 || SpeakerPrefix.split(text) != null || text.none { it.isLowerCase() } || spoken.none { it.isLowerCase() }) {
            return false
        }
        val first = text.firstOrNull { it.isLetter() } ?: return false
        return first.isUpperCase() && upper >= OBJECTIVE_SCALE * height
    }

    private fun letters(text: String) = text.count { it.isLetter() }

    /**
     * Konuşmayla aynı bloğa düşen plaka/tabela satırları ayrı blok olur (sonra [SceneText] ya da [isActionLabel] ile
     * atılır). Kullanıcı bildirimi (GitHub #1052, GTA 6, beta.84): plaka konuşmanın hemen üstünde durunca aynı bloğa
     * katılıyor, "FLORIANA / Dunk: Yo. How you know that was me?" diye çevriliyor, plaka okundukça aynı replik yeniden
     * işleniyordu. Ayrılan: konuşan adlı satırın üstündeki kısa büyük harfli satırlar ([SceneText.isSignLine]; konuşan
     * adı yeni konuşmanın ilk satırıdır) ve küçük harfli konuşmanın altında, cümlenin devamı olmayan, rakam taşıyan kısa
     * büyük harfli satır ("AKB 51"). Tümü büyük harfli altyazının devamı ("LUCIA: GET / DOWN!", "I'm with the / FBI.")
     * ayrılmaz (Mac: Reading.withoutSignLines, Windows: Reading.WithoutSignLines). Harfsiz sayı satırı (HUD sayacı, "88",
     * "19") konuşan adlı satırın üstündeyse ya da bloğun başındaysa da ayrılır (GitHub #1097: "88 / Lucia: …" tek altyazı
     * çevriliyordu).
     */
    private fun withoutSignLines(block: List<TextLine>): List<List<TextLine>> {
        val speaker = (1 until block.size).firstOrNull { SpeakerPrefix.split(block[it].text) != null }
        if (speaker != null && block.take(speaker).all { isHudLine(it.text) }) {
            return listOf(block.take(speaker)) + withoutSignLines(block.drop(speaker))
        }
        // Baştaki HUD satırları (en az biri harfsiz sayı: "14", "MANATEES / 10") büyük harfle başlayan, küçük harfli konuşmanın
        // üstünden ayrılır (GitHub #1097). Büyük harfli ürün satırı ("59 / PED T-SHIRT") bölünmez; SceneText onu bütün atar.
        // Konuşmanın ortasındaki sayı cevabı bölünmez.
        val hud = block.takeWhile { isHudLine(it.text) }.size
        if (hud in 1 until block.size && block.take(hud).any { SceneText.isNumber(it.text) } &&
            block[hud].text.firstOrNull { it.isLetter() }?.isUpperCase() == true && block[hud].text.any { it.isLowerCase() }) {
            return listOf(block.take(hud)) + withoutSignLines(block.drop(hud))
        }
        if (block.size < 2 || SpeakerPrefix.split(block[0].text) == null || block[0].text.none { it.isLowerCase() }) return listOf(block)
        val cut = (1 until block.size).firstOrNull { i ->
            SceneText.isSignLine(block[i].text) && block[i].text.any { it.isDigit() } && !continues(block[i - 1].text, block[i].text)
        } ?: return listOf(block)
        return listOf(block.take(cut), block.drop(cut))
    }

    /** Konuşan adlı satırın üstünde ayrılan satır: kısa büyük harfli tabela ya da harfsiz sayı (GitHub #1097). */
    private fun isHudLine(text: String) = SceneText.isSignLine(text) || SceneText.isNumber(text)

    /** [centered] blokların sabit olanları ([STALE_MS]) çıkarılmış hali; satır yaşı bilinmiyorsa olduğu gibi kalır. */
    private fun withoutStale(centered: List<Reading>, age: ((String) -> Long?)?, skipped: ((Reading) -> Unit)?): List<Reading> {
        if (age == null || centered.size < 2) return centered
        val ages = centered.map { block -> block.lines.mapNotNull { age(it.text) }.minOrNull() ?: 0L }
        val fresh = centered.indices.filter { ages[it] < STALE_MS && !OcrNoise.isCrumb(centered[it].text) }
        val youngest = fresh.minOfOrNull { ages[it] } ?: return centered
        val sentence = fresh.filter { wordCount(centered[it].text) >= 3 }.minOfOrNull { ages[it] }
        val stale = centered.indices.filter { index ->
            if (ages[index] < STALE_MS) return@filter false
            val rival = if (SpeakerPrefix.split(centered[index].lines[0].text) == null) youngest else sentence
            rival != null && ages[index] - rival >= StickyRows.YOUNGER_BY_MS
        }.toSet()
        if (stale.isEmpty()) return centered
        stale.sorted().forEach { skipped?.invoke(centered[it]) }
        return centered.indices.filter { it !in stale }.map { centered[it] }
    }

    /**
     * Bloğun son satırının hemen altında ve yatayda onunla üst üste binen satır o bloğa aittir. Aradaki boşluk satır
     * yüksekliğinin [LINE_GAP] katından (devam satırında [CONTINUATION_GAP]) büyükse ya da yazı boyları 1,25 kattan çok farklıysa ayrı bloktur (altyazıya bitişik görev
     * satırı ayrılır; Windows ve Mac ile aynı). Yazı boyu yalnız iki satır da en az üç sözcükken karşılaştırılır ve alttaki
     * satır üsttekinin devamıysa ([continues]) hiç karşılaştırılmaz: satır kutusu harflere göre ölçülür, "now." gibi kısa ve
     * büyük harfsiz/kuyruksuz satırın kutusu daha alçak çıkıyor, cümlenin devamı ayrı blok sayılıp tek başına çevriliyordu
     * (GitHub #715).
     */
    private fun belongs(box: TextBox, text: String, block: List<TextLine>, area: TextBox): Boolean {
        val last = block.last().box!!.placedIn(area)
        val own = box.bottom - box.top
        val previous = last.bottom - last.top
        val height = maxOf(own, previous)
        // Konuşmanın altındaki küçük görev yazısı devam satırı sayılmaz (isSmallerObjective).
        if (isSmallerObjective(text, own, previous, block.last().text)) return false
        val upper = block.last().text
        val continuing = continues(upper, text)
        val wide = continuing && wordCount(upper) >= CONTINUATION_MIN_WORDS
        if (box.top - last.bottom > height * (if (wide) CONTINUATION_GAP else LINE_GAP) || box.top < last.top) return false
        val comparable = wordCount(text) >= 3 && wordCount(upper) >= 3 && !continuing
        if (comparable && maxOf(own, previous) > 1.25 * minOf(own, previous)) return false
        val overlap = minOf(box.right, last.right) - maxOf(box.left, last.left)
        val narrower = minOf(box.right - box.left, last.right - last.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    /** Alt alta kısa ve noktalamasız satırlar ("MAP", "HELP", "SOCIAL CLUB") menüdür, konuşma değil. */
    /**
     * Satırların yeri biliniyorsa sol ya da sağ kenarları [MENU_EDGE] içinde hizalı olmalı: ortalanmış kısa konuşma
     * satırları ("No / Wait / Go on") menü sanılıp atılmasın. Konuşan adıyla başlayan satır menü değildir (Mac/iPhone,
     * Windows ile aynı).
     */
    internal val isMenu: Boolean
        get() {
            if (lines.size < 3 || !lines.all {
                    wordCount(it.text) <= 3 && !SubtitleStabilizer.endsSentence(it.text) && SpeakerPrefix.split(it.text) == null
                }) return false
            val boxes = lines.mapNotNull { it.box }
            if (boxes.size != lines.size) return true
            fun aligned(edges: List<Double>) = edges.max() - edges.min() <= MENU_EDGE
            return aligned(boxes.map { it.left }) || aligned(boxes.map { it.right })
        }

    /**
     * Okuma menünün geçmiş listesi mi (GTA 6 duraklatma menüsü "Map Özeti": diyalog/yardım/görev geçmişi). Sinan Bey
     * beta.100 (3380-3383): listenin konuşan adlı satırlarından biri her karede altyazı sanılıp altta siyah kutuda
     * gösteriliyor, konuşan adı yüzünden menü durumu da bitiyordu (#1240). Liste: yatayda üst üste duran (aynı sütun),
     * aralarında boşluk olan ([LIST_PITCH]..[LIST_MAX_PITCH] satır boyu) ve eşit aralıklı ([LIST_SPREAD]) en az üç satır;
     * ya da konuşan adıyla başlayan, sol kenarları hizalı ([MENU_EDGE]) iki satır (Mac/iPhone: Reading.isHistoryList,
     * Windows: Reading.IsHistoryList).
     */
    val isHistoryList: Boolean
        get() {
            val rows = lines.filter { it.box != null && it.text.any(Char::isLetter) }.sortedBy { it.box!!.top }
            if (rows.size < 2) return false
            val heights = rows.map { it.box!!.bottom - it.box!!.top }.sorted()
            val height = heights[heights.size / 2]
            if (height <= 0) return false
            fun column(a: TextBox, b: TextBox): Boolean {
                val overlap = minOf(a.right, b.right) - maxOf(a.left, b.left)
                return overlap > 0 && overlap >= 0.5 * minOf(a.right - a.left, b.right - b.left)
            }
            for (start in rows.indices) {
                val run = mutableListOf(start)
                var first: Double? = null
                while (true) {
                    val current = run.last()
                    val next = (current + 1 until rows.size).firstOrNull { column(rows[current].box!!, rows[it].box!!) } ?: break
                    val pitch = rows[next].box!!.top - rows[current].box!!.top
                    if (pitch < LIST_PITCH * height || pitch > LIST_MAX_PITCH * height) break
                    val f = first
                    if (f != null && maxOf(pitch, f) > LIST_SPREAD * minOf(pitch, f)) break
                    if (f == null) first = pitch
                    run.add(next)
                }
                if (run.size >= 3 && !centeredSpeech(run.map { rows[it].box!! })) return true
                if (run.size == 2 && run.all { SpeakerPrefix.split(rows[it].text) != null } &&
                    kotlin.math.abs(rows[run[0]].box!!.left - rows[run[1]].box!!.left) <= MENU_EDGE) return true
            }
            return false
        }

    /** Tek başına okunan etkileşim/HUD etiketi (GTA 6: "SIT", "• ADD TO TRUNK"). */
    internal val isActionLabel: Boolean
        get() = lines.size == 1 && ButtonPrompts.isActionLabel(lines[0].text)
}

/** Oyunların kumanda ipuçlarını tanır: "R2 Swing", "L1 + R1 Spartan Rage", "△ Pick up", "Press ✕ to jump". */
object ButtonPrompts {
    private val buttons = setOf(
        "r1", "r2", "r3", "l1", "l2", "l3", "options", "touchpad",
        "✕", "×", "⨯", "✖", "○", "◯", "●", "□", "▢", "◻", "■", "△", "▲", "δ", "⨂",
    )
    /** Yalnız ayraçtan oluşan sözcük okunmuş simgedir: □ "[]", ○ "()". */
    private val bracketIcons = mapOf("[]" to "□", "()" to "○")
    /** Simge yazı tanımada harfe dönüşebilir; yalnız ipucu kalıbında düğme sayılır. */
    private val lookalikes = setOf("X", "O")
    private val verbs = setOf("press", "hold", "tap", "push", "use", "mash", "release")
    private val separators = Regex("[ \\t+/]+")
    private const val BRACKETS = "()[]{}<>「」"

    private fun isButton(token: String) = token.lowercase() in buttons

    fun isPrompt(line: String): Boolean {
        val tokens = line.split(separators).map { bracketIcons[it] ?: it.trim { c -> c in BRACKETS } }.filter { it.isNotEmpty() }
        if (tokens.isEmpty()) return false
        val first = tokens[0]
        val words = tokens.count { !isButton(it) && it.any { c -> c.isLetter() } }
        if (isButton(first)) return words <= 5
        if (isButton(tokens.last()) && words <= 4 && !SubtitleStabilizer.endsSentence(line)) return true
        if (first in lookalikes && tokens.size in 2..4 && tokens[1][0].isUpperCase() && !SubtitleStabilizer.endsSentence(line))
            return true
        // "A Turn Off": △ "A" diye okunur (#1203). Artikel "A" ile karışmasın diye ardındaki bütün sözcükler büyük harfle
        // başlamalı ("A little help" konuşmadır); BÜYÜK HARFLİ satır ("A LIBERTY CITY MEMOIR" kitap adı) ipucu değildir.
        if (first == "A" && tokens.size in 2..4 && !SubtitleStabilizer.endsSentence(line) &&
            tokens.drop(1).all { it[0].isUpperCase() } && line.any { it.isLowerCase() }) return true
        if (first.lowercase() in verbs && tokens.size in 2..10 && (isButton(tokens[1]) || tokens[1] in lookalikes)) return true
        return isIconPrompt(tokens, line)
    }

    private val connectors = setOf("and", "or")
    /** Büyük harfle yazılmış kısa İngilizce sözcükler tuş kalıntısı sayılmaz ("HOLD ON TO IT"). */
    private val shortWords = setOf("on", "up", "it", "in", "at", "out", "off", "me", "us", "him", "her", "my", "an", "the", "you", "its")
    /** "to"dan sonra eylem yerine bunlar gelirse konuşmadır ("Hold to your course"). */
    private val objects = setOf(
        "the", "a", "an", "my", "your", "his", "her", "our", "their", "me", "you", "him", "them", "us", "it", "this", "that",
    )

    /**
     * Tuş simgesinin yazı tanımadaki kalıntısı: harfsiz ("@", "•", "9"), tek karakter ("D", "i"; "a" hariç), tuş adı,
     * "and"/"or" ya da büyük harf içeren en çok üç karakter ("LI", "RE", "Rd", "RB").
     */
    private fun isIconRemnant(token: String): Boolean {
        if (token.none { it.isLetter() } || isButton(token) || token in lookalikes || token.lowercase() in connectors) return true
        if (token.length == 1) return token != "a"
        return token.length <= 3 && token.any { it.isUpperCase() } && token.lowercase() !in shortWords
    }

    /**
     * GTA 6: "Press/Hold/Use ... to ..." ipucunda tuş simgesi resimdir; yazı tanıma onu ya hiç okumaz ("Press  to open
     * the map") ya da harf/simge kalıntısı olarak okur ("Press @ to", "Hold I LI to", "Press [RB] to take cover").
     * Çevrilince tuş kaybolur ve konuşma yerine ipucu görünür. Fiil ile "to" arasında en çok üç kalıntı olabilir; ünlem,
     * soru, tırnak ya da konuşmacı adı (":") taşıyan satır ve "to"dan sonra eylem yerine nesne gelen satır ("Hold to
     * your course") konuşma sayılır (Mac: ButtonPrompts.isIconPrompt, Windows: ButtonPrompts.IsIconPrompt, havuz:
     * server/pool/src/prompts.js).
     */
    private fun isIconPrompt(tokens: List<String>, line: String): Boolean {
        if (line.any { it in "!?\"“”:" }) return false
        val all = tokens.dropWhile { token -> token.none { it.isLetter() } }
        if (all.size < 3 || all[0].lowercase() !in verbs) return false
        val to = (1 until all.size).firstOrNull { all[it].lowercase() == "to" } ?: return false
        if (to > 4 || !all.subList(1, to).all(::isIconRemnant)) return false
        val next = all.drop(to + 1).firstOrNull { token -> token.any { it.isLetter() } } ?: return false
        return all.size - to - 1 <= 10 && next.lowercase() !in objects
    }

    /**
     * `isIconPrompt` kalıbındaki satırın yazı tanıma sözcüklerinde fiilin ve "to"nun sırası; aralarında en az bir tuş
     * kalıntısı yoksa ya da kalıp tutmazsa null. Aradaki kalıntılar ("I LI", "(9 0", "2 and R2") simgenin okunuşudur:
     * `ButtonIcons.mark` onları kareden kesilecek simge yapar (Windows: ButtonPrompts.IconRemnantSpan).
     */
    internal fun iconRemnantSpan(words: List<String>, line: String): Pair<Int, Int>? {
        val tokens = line.split(separators).map { it.trim { c -> c in BRACKETS } }.filter { it.isNotEmpty() }
        if (!isIconPrompt(tokens, line)) return null
        val verb = words.indexOfFirst { word -> word.trim { c -> c in BRACKETS }.any { it.isLetter() } }
        if (verb < 0 || words[verb].trim { c -> c in BRACKETS }.lowercase() !in verbs) return null
        var end = verb + 2
        while (end < words.size && end <= verb + 4) {
            if (words[end].trim { c -> c in BRACKETS }.lowercase() == "to") {
                val between = words.subList(verb + 1, end)
                    .flatMap { it.split(separators) }
                    .map { it.trim { c -> c in BRACKETS } }
                    .filter { it.isNotEmpty() }
                return if (between.all(::isIconRemnant)) Pair(verb, end) else null
            }
            end++
        }
        return null
    }

    /** "and"/"or": iki tuş kalıntısının arasındaki bağlaç, simge değildir ("Release 2 and R2 to breathe out"). */
    internal fun isConnector(token: String) = token.lowercase() in connectors

    /**
     * Etkileşim/HUD etiketi: en çok üç sözcük, hiç küçük harf yok (en az bir büyük harf var), cümle sonu noktalaması
     * yok. GTA 6'nın etkileşim yazıları ("TAKE AMMO PACK (0/3)", "• ADD TO TRUNK", "TURN ON") ve ekipman yazıları
     * ("BENCH PRESS") altyazı gibi çevriliyordu (#404). Konuşma küçük harf içerir ya da noktalamayla biter ("Yes.",
     * "OKAY.", "WHAT?"); büyük/küçük harfi olmayan yazılara dokunulmaz. Yalnız tek başına okunan satıra uygulanır
     * (Mac: ButtonPrompts.isActionLabel, Windows: ButtonPrompts.IsActionLabel).
     */
    fun isActionLabel(line: String): Boolean {
        val words = line.split(Regex("\\s+")).count { word -> word.any { it.isLetter() } }
        return words in 1..3 && line.any { it.isUpperCase() } && line.none { it.isLowerCase() } &&
            !SubtitleStabilizer.endsSentence(line)
    }
}
