// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/**
 * Otomatik telefon okumasında çevirinin kararlılığı. Aynı mesajın OCR'la bir iki harfi farklı okunuşu yeni mesaj
 * sayılıyor, balon bir an özgün diline dönüp yeniden çevriliyor, çeviri her seferinde biraz değişiyordu; telefon tek
 * karede bulunamayınca da bütün çeviriler silinip geri geliyordu ("sürekli git gel yapıyor", X'teki bildirim). Mac/iPhone
 * (PhoneSteady.swift) ve Windows (PhoneSteady.cs) aynı eşikleri kullanır.
 */
object PhoneSteady {
    /** Okuma art arda bu kadar turda doğrulanamazsa çeviriler silinir. */
    const val MISS_TURNS = 3
    /** Yan yana bozuk harfler en çok bu kadar tur bekletilir. */
    const val HOLD_TURNS = 2
    /**
     * Eksik düzen (düşen, kesilen ya da komşusuyla birleşen balon) ancak sekiz ardışık okumada (~4 sn) doğrulanırsa gösterilen
     * sohbeti değiştirir (X, 28 Kas, beta.107; Windows ve Mac ile aynı).
     */
    const val DEGRADED_TURNS = 8
    /**
     * Sayfanın türü (sohbet listesi ya da sohbet) ancak bu kadar ardışık okuma aynı yeni türü verirse değişir: sallanan
     * telefonda tek okumada bölüm başlığı kaçınca TV'deki panel liste ile balonlar arasında her saniye gidip geliyordu
     * (LG, beta.93). iPhone ile aynı.
     */
    const val KIND_TURNS = 2

    /** Okumanın grupları sohbet listesi mi (kişi adı, önizleme, bölüm başlığı). */
    fun isList(roles: List<ScreenPhoneCard.Role?>): Boolean =
        roles.any { it == ScreenPhoneCard.Role.CONTACT || it == ScreenPhoneCard.Role.PREVIEW || it == ScreenPhoneCard.Role.HEADING }
    /** Aynı mesaj sayılmak için sadeleştirilmiş iki okumanın benzerliği (Levenshtein oranı) en az bu. */
    const val SAME_MESSAGE = 0.9
    /** Kısa satırda bir harf anlamı değiştirir ("Ok" / "On"): benzer okuma yalnız bu kadar harften uzun mesajda kullanılır. */
    const val MINIMUM_LETTERS = 8

    /**
     * Mesajın bilinen çevirisi: birebir aynı okunuşunki, yoksa aynı mesajın OCR'la biraz farklı okunuşununki. Sayı ya da
     * olumsuzluk ekleyen/düşüren okuma ("at 5" / "at 6", "can" / "can't") aynı mesaj sayılmaz. Birden çok aday varsa
     * kayıt sırasında ([order]) ilk eşleşen; sıra verilmezse sıralamada önce gelen (her platformda aynı sonuç).
     */
    fun translation(source: String, known: Map<String, String>, order: Iterable<String>? = null): String? {
        known[source]?.let { return it }
        for (old in order ?: known.keys.sorted()) if (sameReading(source, old)) return known[old]
        return null
    }

    /**
     * İki okuma aynı mesaj mı: birebir aynı, sadeleştirilmiş hali aynı (soru işareti ikisinde de ya da hiçbirinde; "Ok." /
     * "ok" kısa satırda da aynı mesaj) ya da en az [MINIMUM_LETTERS] harfli iki uzun mesajda yalnız OCR artığı farklı:
     * kesme işareti, noktalama, "rn" / "m", "l" / "i", yan yana iki bozuk sözcük ya da en çok [SLIP_WORDS] sözcükte tek harf
     * kayması. Gerçek sözcük değişimi ("here" / "there"), sayı ya da olumsuzluk ekleyen/düşüren okuma aynı sayılmaz
     * (Windows ve Mac ile aynı).
     */
    fun sameReading(a: String, b: String): Boolean {
        if (a == b) return true
        val x = TextMatch.normalize(a)
        val y = TextMatch.normalize(b)
        if (x.isEmpty() || y.isEmpty() || TextMatch.addsMeaning(a, b) || TextMatch.addsMeaning(b, a)) return false
        // Kısa satırda soru işareti anlam taşır ("Ok?" / "Ok."); uzun mesajda düşen soru işareti OCR'ın kaçırdığı noktalamadır.
        if (x == y) return a.contains('?') == b.contains('?') || x.count { it.isLetter() } >= MINIMUM_LETTERS
        if (x.count { it.isLetter() } < MINIMUM_LETTERS || y.count { it.isLetter() } < MINIMUM_LETTERS) return false
        // Uzun cümlede gerçek bir sözcüğün değişmesi ("here" / "there") benzerlik eşiğini geçebilir (X, 28 Kas, beta.107):
        // yalnız OCR'ın karıştırdığı harfler, kesme işareti ve noktalama artığı eşleşir.
        // Bitişik ya da ayrık okunan sözcük ("Yo Istill" / "Yo I still") da aynı mesajdır.
        val p = readingLetters(a)
        val q = readingLetters(b)
        return p == q || p.replace(" ", "") == q.replace(" ", "") || GamePhoneText.hasAdjacentOcrEdits(a, b) || letterSlips(a, b)
    }

    /** Aynı mesajın okunuşunda en çok bu kadar sözcükte tek harf kayabilir. */
    const val SLIP_WORDS = 2
    /** Tek harf kayması yalnız en az bu kadar harfli sözcükte aranır ("cold" / "bold" gibi kısa sözcükler anlam taşır). */
    private const val SLIP_LETTERS = 5
    private val ECHOED_LETTER = Regex("""(\p{L}),\1\b""", RegexOption.IGNORE_CASE)

    /**
     * Karşılaştırma için okunuşun harfleri: "it,t" → "it", "You'l " → "You'll ", kesme işareti atılır; "rn" / "m", "q" / "g"
     * ve "l" / "i" (OCR'ın sık karıştırdığı harfler, "flnd" / "find") birleştirilir.
     */
    fun readingLetters(text: String): String {
        val apostrophes = ECHOED_LETTER.replace(text, "$1").replace('’', '\'')
            .replace("'l ", "'ll ", ignoreCase = true).replace("'", "")
        return TextMatch.normalize(apostrophes).replace("rn", "m").replace('q', 'g').replace('l', 'i')
    }

    /**
     * Sözcük sayısı aynı, en çok [SLIP_WORDS] sözcükte OCR'ın tek harf kayması: aynı uzunlukta tek harf değişimi
     * ("breathabie") ya da yan yana yinelenen harf ("SOMETHINnG"). Başa harf eklenmesi ("here" / "there") eşleşmez.
     */
    private fun letterSlips(a: String, b: String): Boolean {
        val x = readingLetters(a).split(' ')
        val y = readingLetters(b).split(' ')
        if (x.size != y.size) return false
        var slips = 0
        for (i in x.indices) {
            if (x[i] == y[i]) continue
            if (++slips > SLIP_WORDS || !letterSlip(x[i], y[i])) return false
        }
        return slips > 0
    }

    private fun letterSlip(p: String, q: String): Boolean {
        if (minOf(p.length, q.length) < SLIP_LETTERS || !p.all { it.isLetter() } || !q.all { it.isLetter() }) return false
        if (p.length == q.length) return p.indices.count { p[it] != q[it] } == 1
        val (shorter, longer) = if (p.length < q.length) p to q else q to p
        if (longer.length != shorter.length + 1) return false
        for (i in 1 until longer.length)
            if (longer[i] == longer[i - 1] && longer.removeRange(i, i + 1) == shorter) return true
        return false
    }

    /** Aynı yerdeki balonun başı, sonu ya da aradaki satırı eksik okunmuş mu. */
    fun truncatedReading(read: String, shown: String): Boolean {
        fun normalized(text: String) = TextMatch.normalize(text.replace("'", "").replace("’", ""))
        val shorter = normalized(read)
        val full = normalized(shown)
        if (shorter.isEmpty() || shorter.length >= full.length) return false
        if (full.startsWith(shorter) && (full[shorter.length] == ' ' || shorter.length >= MINIMUM_LETTERS)) return true
        if (TextMatch.addsMeaning(read, shown)) return false
        if (TextMatch.isGrowth(shown, read)) return true
        // Bitişik okunan sözcüklerle de eksik okuma: boşluksuz hâli tam metnin içinde.
        if (shorter.length >= MINIMUM_LETTERS && full.replace(" ", "").contains(shorter.replace(" ", ""))) return true
        val words = shorter.split(' ')
        if (words.size < 3) return false
        var kept = 0
        for (word in full.split(' ')) if (word == words[kept] && ++kept == words.size) return true
        return false
    }

    /** Önceki iki komşu balonun tek kutuda okunuşu; ikincisi yarım da kalabilir. */
    fun mergedReading(read: String, first: String, second: String): Boolean {
        val combined = "$first $second"
        return sameReading(read, combined) || (TextMatch.isGrowth(read, first) && truncatedReading(read, combined))
    }

    // Ekrandaki balonların kararlılığı (X, 22 Kas, GTA 6 telefonu: "yazılar sürekli oynuyor okumak çok zor, balonların
    // içinde de aynı hata var"). Her OCR turunda balon kutuları birkaç piksel oynuyor, telefonun bulunan yeri titriyordu;
    // her turda yeni kutular gönderiliyor, TV paneli ve balonları yeniden diziyordu. Mac/iPhone ve Windows aynı kural.

    /** Aynı balonun yeri, satır yüksekliğinin bu payından az oynadıysa son çizilen yerde kalır (histerezis). */
    const val POSITION_SHARE = 0.25
    /** Yanda Panel'in dayandığı telefon yeri, kutusunun her kenarı bu kadardan (kareye oranla) az oynadıysa sabit kalır. */
    const val POSE_SLACK = 0.015

    /**
     * Balonların yeri: önceki gönderiyle eşleşen balonlar ([match]) küçük oynamada (satır yüksekliğinin [POSITION_SHARE]'i;
     * yatayda kare oranıyla) son çizilen yerde kalır. Eşleşenlerin yarısından çoğu eşiği aşarsa (telefon kıpırdadı, sohbet
     * kaydı) hepsi birlikte, tek seferde yeni yerine geçer; tek başına eşiği aşan balon kendi yerine geçer. Boyu değişmeyen
     * balonun kutusu birebir öncekidir. [aspect]: karenin eni / boyu.
     */
    fun steadyPositions(items: List<ScreenTranslation.Item>, previous: List<ScreenTranslation.Item>,
                        aspect: Double): List<ScreenTranslation.Item> {
        val ratio = maxOf(0.1, aspect)
        fun still(box: TextBox, old: ScreenTranslation.Item): Boolean {
            val limit = POSITION_SHARE * old.lineHeight
            return abs(box.top - old.box.top) <= limit && abs(box.left - old.box.left) <= limit / ratio
        }
        val pairs = items.mapIndexedNotNull { index, item -> match(item, previous)?.let { index to it } }
        val moved = pairs.count { (index, old) -> !still(items[index].box, old) }
        if (pairs.isEmpty() || 2 * moved > pairs.size) return items
        val result = items.toMutableList()
        for ((index, old) in pairs) {
            val box = items[index].box
            if (!still(box, old)) continue
            val width = box.right - box.left
            val height = box.bottom - box.top
            val oldWidth = old.box.right - old.box.left
            val oldHeight = old.box.bottom - old.box.top
            result[index] = items[index].copy(box = TextBox(old.box.left, old.box.top,
                if (abs(width - oldWidth) < 1e-9) old.box.right else minOf(1.0, old.box.left + width),
                if (abs(height - oldHeight) < 1e-9) old.box.bottom else minOf(1.0, old.box.top + height)))
        }
        return result
    }

    /** Kaydırma sayılmak için eşleşen balonların her biri en az satır yüksekliğinin bu katı kadar kaymalı. */
    const val SCROLL_SHARE = 0.5

    /** Kaydırma ölçüsünde bir balon: yazısı ve telefon bölgesine oranlı üst kenarı. */
    data class Placed(val text: String, val top: Double)

    /**
     * Telefonda sohbet kaydırıldı mı: önceki okumayla eşleşen balonların (aynı mesaj, [sameReading]) hepsi dikeyde aynı
     * yöne, satır yüksekliğinin [SCROLL_SHARE]'inden fazla kaydı. Kaydırmada bekletme ([HOLD_TURNS]) ve konum sabitleme
     * ([steadyPositions], stableBlocks) atlanır, görünen yeni balonlar tek istekte çevrilir (#1202, #1170, X: "kaydırınca
     * yenilenmiyor"). Üstler ve [lineHeight] telefon bölgesine oranlıdır. Her güncel balon, öncekilerden henüz eşlenmemiş
     * ilk aynı mesajla eşlenir. Mac/iPhone ve Windows aynı kuralı uygular.
     */
    fun scrolled(previous: List<Placed>, current: List<Placed>, lineHeight: Double): Boolean {
        if (lineHeight <= 0) return false
        val used = HashSet<Int>()
        val shifts = ArrayList<Double>()
        for (bubble in current) {
            val index = previous.indices.firstOrNull { it !in used && sameReading(previous[it].text, bubble.text) } ?: continue
            used += index
            shifts += bubble.top - previous[index].top
        }
        if (shifts.isEmpty() || shifts.any { abs(it) <= SCROLL_SHARE * lineHeight }) return false
        return shifts.all { it > 0 } || shifts.all { it < 0 }
    }

    /** İki yazı rengi zeminin aynı yanında mı (ikisi de zeminden koyu ya da ikisi de açık; algılanan parlaklıkla). */
    fun sameInk(a: String, b: String, background: String): Boolean {
        fun brightness(hex: String): Int? {
            if (hex.length != 7 || !hex.startsWith("#")) return null
            val value = hex.substring(1).toIntOrNull(16) ?: return null
            return (((value shr 16) and 0xFF) * 299 + ((value shr 8) and 0xFF) * 587 + (value and 0xFF) * 114) / 1000
        }
        val x = brightness(a) ?: return false
        val y = brightness(b) ?: return false
        val z = brightness(background) ?: return false
        return (x < z) == (y < z)
    }

    /** Önceki gönderide bu balonun eşi: aynı çeviri ve parça, aynı okuma ([sameReading]), sol üst köşesi 0,05 içinde; aynı yerde iki eş varsa null. */
    fun match(item: ScreenTranslation.Item, previous: List<ScreenTranslation.Item>): ScreenTranslation.Item? {
        var found: ScreenTranslation.Item? = null
        for (old in previous) {
            if (old.translation != item.translation || old.panel != item.panel || abs(old.box.left - item.box.left) > 0.05 ||
                abs(old.box.top - item.box.top) > 0.05 || !sameReading(old.source, item.source)) continue
            if (found != null) return null
            found = old
        }
        return found
    }

    /** Yanda Panel'in dayandığı telefon: yeni yerin kutusu öncekinden her kenarda [POSE_SLACK]'ten az oynadıysa önceki yer. */
    fun steadyPose(pose: GamePhoneGeometry.Pose, anchor: GamePhoneGeometry.Pose?): GamePhoneGeometry.Pose {
        if (anchor == null) return pose
        val a = pose.bounds
        val b = anchor.bounds
        val still = abs(a.left - b.left) <= POSE_SLACK && abs(a.right - b.right) <= POSE_SLACK &&
            abs(a.top - b.top) <= POSE_SLACK && abs(a.bottom - b.bottom) <= POSE_SLACK
        return if (still) anchor else pose
    }

    // Kararlı çıktı (X, 22 Kas: "sağ tarafta kutu çıkarıyorsun ama her saniye şekli de hareketi de değişiyor"). Telefonun
    // yazısı değişmedikçe çizilen Türkçe birebir aynı kalır: aynı mesaj aynı çeviriyle ve bir kez, gruptaki bütün balonlar
    // tek boyda; panelin kutusu yalnız telefon gerçekten kıpırdayınca kayar. Mac/iPhone ve Windows aynı kural, aynı eşikler.

    /** Art arda gelmeyen iki öğe ancak bu kadar harften uzunsa aynı mesaj sayılıp sonraki atılır. */
    const val REPEAT_LETTERS = 12
    /** Telefonda aynı yerde duran balonun okunuşları bu benzerlikten yüksekse aynı mesajdır ([sameBubble]). */
    const val SAME_SPOT_MESSAGE = 0.8
    /** Aynı yer: düz ekrandaki sol üst köşeleri bu kadar içinde. */
    const val SAME_SPOT = 0.05

    /**
     * Aynı mesaj panelde bir kez: telefondaki öğelerden bir öncekiyle aynı mesajı taşıyan ([sameReading]) art arda öğe
     * atılır; araları açık iki öğeden sonraki ancak uzun mesajsa ([REPEAT_LETTERS]) atılır. Telefon dışındaki öğelere
     * dokunulmaz (Mac ile aynı).
     */
    fun withoutRepeats(items: List<ScreenTranslation.Item>): List<ScreenTranslation.Item> {
        val kept = ArrayList<ScreenTranslation.Item>()
        for (item in items) {
            if (item.phone == null) {
                kept.add(item)
                continue
            }
            val onPhone = kept.filter { it.phone != null }
            val long = TextMatch.normalize(item.source).count { it.isLetter() } >= REPEAT_LETTERS
            val repeated = onPhone.indices.any { index ->
                sameReading(onPhone[index].source, item.source) && (index == onPhone.size - 1 || long)
            }
            if (!repeated) kept.add(item)
        }
        return kept
    }

    /**
     * İki okuma aynı balon mu: aynı mesaj ([sameReading]) ya da telefonun ekranında aynı yerde ([SAME_SPOT]) ve en az
     * [MINIMUM_LETTERS] harfli iki uzun okuma [SAME_SPOT_MESSAGE] kadar benzer; sayı ya da olumsuzluk ekleyen/düşüren okuma
     * aynı sayılmaz (Mac ile aynı).
     */
    fun sameBubble(a: String, spotA: TextBox?, b: String, spotB: TextBox?): Boolean {
        if (sameReading(a, b)) return true
        if (spotA == null || spotB == null || abs(spotA.top - spotB.top) > SAME_SPOT || abs(spotA.left - spotB.left) > SAME_SPOT ||
            TextMatch.addsMeaning(a, b) || TextMatch.addsMeaning(b, a)) return false
        val x = TextMatch.normalize(a)
        val y = TextMatch.normalize(b)
        return truncatedReading(b, a) && x.count { it.isLetter() } >= MINIMUM_LETTERS &&
            y.count { it.isLetter() } >= MINIMUM_LETTERS && TextMatch.isSimilar(x, y, SAME_SPOT_MESSAGE)
    }

    /** Ekranda aynı yerde duran aynı balonun gösterilen çevirisi ([sameBubble]); yoksa null. */
    fun shownTranslation(source: String, spot: TextBox?, shown: List<ScreenTranslation.Item>): String? =
        shown.firstOrNull {
            it.phone != null && !it.unchanged && it.icons == null && !it.translation.contains('\n') &&
                sameBubble(it.source, it.phone.spot, source, spot)
        }?.translation

    /**
     * Önceki gönderide aynı balon ([sameBubble]) varsa öğe onun kaynağını ve çevirisini aynen alır: aynı İngilizce için
     * Türkçe her okumada yeniden üretilmez. Her önceki öğe en çok bir kez kullanılır (Mac ile aynı).
     */
    fun keptTranslations(items: List<ScreenTranslation.Item>, previous: List<ScreenTranslation.Item>): List<ScreenTranslation.Item> {
        val used = HashSet<Int>()
        return items.map { item ->
            val index = previous.indices.firstOrNull { i ->
                val old = previous[i]
                i !in used && (old.phone != null) == (item.phone != null) && old.unchanged == item.unchanged &&
                    sameBubble(old.source, old.phone?.spot, item.source, item.phone?.spot)
            } ?: return@map item
            used.add(index)
            item.copy(source = previous[index].source, translation = previous[index].translation, icons = previous[index].icons)
        }
    }

    /** Gruptaki bütün mesaj balonları tek yazı boyunda ([line]: kilitli ölçüm); kişinin adı ve telefon dışı öğeler kendi boyunda. */
    fun uniformLine(items: List<ScreenTranslation.Item>, line: Double?): List<ScreenTranslation.Item> {
        if (line == null || line <= 0) return items
        return items.map { item ->
            val role = item.phone?.role
            if (role != null && role.inCard && role != ScreenPhoneCard.Role.HEADER && role != ScreenPhoneCard.Role.CONTACT)
                item.copy(lineHeight = line) else item
        }
    }

    /**
     * Panelin zemini (kart) kısalmaz: yeni kart öncekiyle aynı yanda, aynı genişlikte ve onun içinde kalıyorsa önceki kart
     * kalır; telefon gerçekten kıpırdayınca yeni kart geçer (Mac ile aynı).
     */
    fun steadyCard(shown: List<ScreenTranslation.Item>, previous: List<ScreenTranslation.Item>): List<ScreenTranslation.Item> {
        val index = shown.indexOfFirst { it.panel == ScreenPhoneCard.PanelPart.CARD }
        val old = previous.firstOrNull { it.panel == ScreenPhoneCard.PanelPart.CARD }?.box
        if (index < 0 || old == null) return shown
        val box = shown[index].box
        val near = 1e-9
        if (abs(box.left - old.left) >= near || abs(box.right - old.right) >= near ||
            box.top < old.top - near || box.bottom > old.bottom + near) return shown
        return shown.toMutableList().also { it[index] = it[index].copy(box = old) }
    }

    /**
     * İki gönderi TV'de ve ekranda aynı görünür mü. Panelin mesajları, kişi adı ve notları akışla çizilir: yalnız sırası,
     * yazısı ve rengi önemlidir; panelin zemini ve panel dışındaki her öğe yeriyle aynı olmalıdır.
     */
    fun samePicture(a: List<ScreenTranslation.Item>, b: List<ScreenTranslation.Item>): Boolean {
        if (a.size != b.size) return false
        // Hizalı panelde parçalar kutularının yerinde çizilir: kutuları da aynı olmalı (Mac ile aynı).
        val aligned = a.any { it.panel == ScreenPhoneCard.PanelPart.CARD && it.aligned }
        return a.zip(b).all { (x, y) ->
            x.panel == y.panel && x.translation == y.translation && x.surface == y.surface && x.look == y.look &&
                x.icons == y.icons && x.bubble == y.bubble && x.lineHeight == y.lineHeight && x.aligned == y.aligned &&
                x.listRow == y.listRow && ((!aligned && x.panel != null && x.panel != ScreenPhoneCard.PanelPart.CARD) || x.box == y.box)
        }
    }
}

/**
 * Yanda Panel'in yazı boyu ve yeri oturum boyunca kararlı (#1152, GTA 6: "telefon titreyince sohbet panelinin yazıları
 * büyüyüp küçülüyor, balonlar yer değiştiriyor"). Panel ilk ölçümde kilitlenir: telefonun yeri ancak belirgin biçimde
 * (boyu [SIZE_SHARE]'den, ortası boyunun [MOVE_SHARE]'inden fazla) ve kesintisiz [SETTLE_MS] boyunca başka yerdeyse,
 * satır yüksekliği ancak kilitliden [SIZE_SHARE]'den fazla ve kesintisiz [SETTLE_MS] boyunca farklıysa yenilenir;
 * telefonun boyu belirgin değişip yeni yer benimsenince yazı boyu yeniden ölçülür. Mac/iPhone (PhoneSteady.swift) ve
 * Windows (PhoneSteady.cs) aynı kuralı, aynı eşikleri kullanır.
 */
class PhonePanelSteady {
    companion object {
        const val SIZE_SHARE = 0.25
        const val MOVE_SHARE = 0.1
        const val SETTLE_MS = 1000L

        /** Kenarlar [PhoneSteady.POSE_SLACK] içinde ya da boy [SIZE_SHARE] içinde ve ortası az kaymış. */
        fun sameSpot(a: GamePhoneGeometry.Pose, b: GamePhoneGeometry.Pose): Boolean {
            val x = a.bounds
            val y = b.bounds
            val slack = PhoneSteady.POSE_SLACK
            if (abs(x.left - y.left) <= slack && abs(x.right - y.right) <= slack &&
                abs(x.top - y.top) <= slack && abs(x.bottom - y.bottom) <= slack) return true
            val height = y.bottom - y.top
            val width = y.right - y.left
            if (height <= 0 || width <= 0 || resized(a, b)) return false
            return abs((x.top + x.bottom) - (y.top + y.bottom)) / 2 <= MOVE_SHARE * height &&
                abs((x.left + x.right) - (y.left + y.right)) / 2 <= 2 * MOVE_SHARE * width
        }

        /** Telefonun boyu belirgin değişti mi. */
        fun resized(a: GamePhoneGeometry.Pose, b: GamePhoneGeometry.Pose): Boolean {
            val x = a.bounds.bottom - a.bounds.top
            val y = b.bounds.bottom - b.bounds.top
            return y <= 0 || abs(x / y - 1) > SIZE_SHARE
        }
    }

    /** Panelin dayanacağı telefon yeri; [resized]: boyu belirgin değişti (ya da ilk yer). */
    data class Placed(val pose: GamePhoneGeometry.Pose, val resized: Boolean)

    var pose: GamePhoneGeometry.Pose? = null
        private set
    var line: Double? = null
        private set
    private var poseSince: Long? = null
    private var lineSince: Long? = null
    /**
     * Son kilitli yazı boyu ve o andaki telefon boyu: telefon kapanıp açılınca yazı boyu baştan ölçülmez; telefon aynı
     * boydaysa ([SIZE_SHARE] içinde) aynı boy kalır. [reset] bunu silmez, [forget] siler.
     */
    var remembered: Pair<Double, Double>? = null
        private set

    fun steadyPose(found: GamePhoneGeometry.Pose, now: Long): Placed {
        val locked = pose
        if (locked == null) {
            pose = found
            poseSince = null
            // Aynı boydaki telefon yeniden açıldı: yazı boyu öncekiyle aynı kalır.
            val memory = remembered
            if (line == null && memory != null && memory.second > 0 && abs(height(found) / memory.second - 1) <= SIZE_SHARE) {
                line = memory.first
                return Placed(found, false)
            }
            return Placed(found, true)
        }
        if (sameSpot(found, locked)) {
            poseSince = null
            return Placed(locked, false)
        }
        val since = poseSince
        if (since == null || now - since < SETTLE_MS) {
            if (since == null) poseSince = now
            return Placed(locked, false)
        }
        poseSince = null
        if (resized(found, locked)) {
            pose = found
            line = null
            lineSince = null
            return Placed(found, true)
        }
        // Boyu aynı kalan telefon yalnız yer değiştirdi: panel telefona sabit uzaklıkla, aynı boyda izler.
        val moved = shifted(locked, found)
        pose = moved
        return Placed(moved, false)
    }

    /** Telefonun yüksekliği (kareye oranla). */
    private fun height(pose: GamePhoneGeometry.Pose): Double = pose.bounds.bottom - pose.bounds.top

    /** [locked] telefonun, ortası [found]'unkine gelecek biçimde kaydırılmış hali (boyu ve eğikliği aynı). */
    internal fun shifted(locked: GamePhoneGeometry.Pose, found: GamePhoneGeometry.Pose): GamePhoneGeometry.Pose {
        if (abs((found.bottomY - found.topY) - (locked.bottomY - locked.topY)) < 1e-9 &&
            abs((found.bottomX - found.topX) - (locked.bottomX - locked.topX)) < 1e-9) return found
        val a = locked.bounds
        val b = found.bounds
        val dx = (b.left + b.right - a.left - a.right) / 2
        val dy = (b.top + b.bottom - a.top - a.bottom) / 2
        return GamePhoneGeometry.Pose(locked.topX + dx, locked.topY + dy, locked.bottomX + dx, locked.bottomY + dy)
    }

    /** Panelin satır yüksekliği ([ScreenPhoneCard.measuredLine]); ölçüm yoksa kilitli değer. */
    fun steadyLine(measured: Double?, now: Long): Double? {
        val result = lockedLine(measured, now)
        val placed = pose
        if (result != null && placed != null) remembered = result to height(placed)
        return result
    }

    private fun lockedLine(measured: Double?, now: Long): Double? {
        if (measured == null || measured <= 0) return line
        val locked = line
        if (locked == null) {
            line = measured
            lineSince = null
            return measured
        }
        if (abs(measured / locked - 1) <= SIZE_SHARE) {
            lineSince = null
            return locked
        }
        val since = lineSince
        if (since == null || now - since < SETTLE_MS) {
            if (since == null) lineSince = now
            return locked
        }
        line = measured
        lineSince = null
        return measured
    }

    /** Telefon kayboldu: sonraki bulunuşta yeri yeniden ölçülür; aynı boydaki telefonun yazı boyu hatırlanır. */
    fun reset() {
        pose = null
        line = null
        poseSince = null
        lineSince = null
    }

    /** Çeviri durdu: her şey unutulur. */
    fun forget() {
        reset()
        remembered = null
    }
}
