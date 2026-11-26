// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Locale

/** OCR çıktılarını karşılaştırmak için sadeleştirme ve gürültüye dayanıklı benzerlik (Windows: TextMatch.cs). */
object TextMatch {
    /** Küçük harf, yalnız harf/rakam, tek boşluk. */
    fun normalize(s: String): String {
        val builder = StringBuilder(s.length)
        for (c in s.lowercase(Locale.ROOT)) builder.append(if (isAlphanumeric(c)) c else ' ')
        return builder.toString().split(' ').filter { it.isNotEmpty() }.joinToString(" ")
    }

    /** Levenshtein oranı [threshold] ve üstündeyse benzer sayılır. Boş metin hiçbir metne benzemez. */
    fun isSimilar(a: String, b: String, threshold: Double = 0.85): Boolean {
        if (a == b) return a.isNotEmpty()
        if (a.isEmpty() || b.isEmpty()) return false
        var previous = IntArray(b.length + 1) { it }
        var row = IntArray(b.length + 1)
        for (i in 1..a.length) {
            row[0] = i
            for (j in 1..b.length)
                row[j] = minOf(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
            val swap = previous
            previous = row
            row = swap
        }
        return 1 - previous[b.length].toDouble() / maxOf(a.length, b.length) >= threshold
    }

    /** Boşluksuz harf dizisinin en az bu kadar uzun olması gerekir; kısa satırda bir harf bile anlamı değiştirir. */
    const val SAME_LETTERS_MINIMUM = 6

    /**
     * Sadeleştirilmiş iki okuma boşluklar atılınca neredeyse aynı mı. Bozuk okumada OCR bir sözcüğü bölebilir ya da iki
     * sözcüğü birleştirebilir ("That smo e..." / "That smoke...", #296); sözcük sayısı değişince sözcük sözcük
     * karşılaştırma aynı satırı tanımaz. Çağıran, okumalardan birinin bozuk olduğunu ayrıca denetler (Windows: TextMatch.cs).
     */
    fun sameLetters(a: String, b: String): Boolean {
        val x = a.replace(" ", "")
        val y = b.replace(" ", "")
        return minOf(x.length, y.length) >= SAME_LETTERS_MINIMUM && isSimilar(x, y, 0.8)
    }

    /** Satırları ayrı ayrı sadeleştirip alt alta birleştirir; [isSameSubtitle] kaçırılan satırı bundan anlar. */
    fun normalizeRows(s: String): String =
        s.replace("\r\n", "\n").split('\n').map(::normalize).filter { it.isNotEmpty() }.joinToString("\n")

    /**
     * Yeni okuma, gönderilmiş altyazının yeniden okuması mı (sadeleştirilmiş metinler; [sent] satırları alt alta).
     * Süslü yazı tipinde ya da solarken OCR bir iki sözcüğü her karede başka çöpe çevirir ya da iki satırlık altyazının
     * bir satırını kaçırır; sözcükler aynı kalır. Başına ya da sonuna sözcük eklenmiş metin yenidir; sondan kısalmış metin
     * ancak tam bir satırı eksikse aynı altyazıdır.
     */
    fun isSameSubtitle(reread: String, sent: String): Boolean {
        val rows = sent.split('\n')
        val flat = rows.joinToString(" ")
        // Gönderilende olmayan olumsuzluk ya da sayı taşıyan okuma, karakterce ne kadar benzese de başka bir cümledir.
        if (addsMeaning(reread, flat)) return false
        val x = cleanWords(reread)
        val y = cleanWords(flat)
        // Uzayan metin (daktilo efekti ya da aynı sözlerle başlayan yeni satır) karakterce benzese de yenidir.
        if (y.isNotEmpty() && x.size > y.size && (startsWith(x, y) || endsWith(x, y))) return false
        if (isSimilar(reread, flat)) return true
        // Baştan ya da sondan kesilmiş okuma: yalnız tam satırları okunduysa aynıdır, yoksa başka bir cümledir.
        if (x.isNotEmpty() && x.size < y.size && (startsWith(y, x) || endsWith(y, x)))
            return isWholeRows(x.size, rows, startsWith(y, x))
        val remaining = y.toMutableList()
        val sentCount = remaining.size
        var shared = 0
        for (word in x) if (remaining.remove(word)) shared++
        // Arasından çöp sözcükler düşmüş okuma: yeni okumanın sözcüklerinin hemen hepsi gönderilende var.
        if (x.size in 4..sentCount && shared >= x.size * 0.85) return true
        // Kısa satırda tek sözcük anlamı değiştirir; orada yalnız karakter benzerliği geçerli.
        val longer = maxOf(x.size, sentCount)
        val shorter = minOf(x.size, sentCount)
        if (shorter < 6 || shorter.toDouble() / longer < 0.75) return false
        return shared.toDouble() / longer >= 0.75
    }

    /**
     * Yeni satır, az önce gösterilen satırın uzamış ya da düzelmiş okuması mı: daktilo efektinde büyüyen cümle
     * ("We do not have" → "We do not have time."), belirirken yarım okunan satır, bir iki sözcüğü başka okunan aynı
     * cümle. TV böyle bir çeviriyi öncekinin üstüne yığmaz, yerine koyar. Ham metinler verilir (Mac: TextMatch.isRevision).
     */
    fun isRevision(new: String, old: String): Boolean {
        val x = normalize(new)
        val y = normalize(old)
        if (x.isEmpty() || y.isEmpty()) return false
        if (isLooseGrowth(new, old) || isLooseGrowth(old, new)) return true
        if (isSimilar(x, y, 0.8)) return true
        val a = cleanWords(x)
        val b = cleanWords(y)
        val shorter = minOf(a.size, b.size)
        val longer = maxOf(a.size, b.size)
        if (shorter < 5) return false
        if (similarity(a, b) >= 0.65) return true
        val remaining = b.toMutableList()
        var shared = 0
        for (word in a) if (remaining.remove(word)) shared++
        return shared.toDouble() / longer >= 0.7
    }

    /**
     * Okuma, gönderilmiş satırın aynı cümleyi bozuk okuyan ve ondan daha iyi olmayan bir yeniden okuması mı (açık zeminde
     * her karede bir iki sözcüğü başka okunan cümle, GTA V, #26). Daha çok sözcük okuyan (puanı belirgin yüksek) okuma
     * kötü sayılmaz, yeniden çevrilir (Mac: TextMatch.isWorseReread).
     */
    fun isWorseReread(reread: String, sent: String): Boolean {
        val a = normalize(reread)
        val b = normalize(sent)
        val x = cleanWords(a)
        val y = cleanWords(b)
        if (x.size < 5 || y.isEmpty() || isGrowth(reread, sent) || isGrowth(sent, reread) || addsMeaning(reread, sent)) return false
        val reads = similarity(x, y) >= 0.65 || isSimilar(a, b, 0.75)
        return reads && OcrNoise.score(reread) < OcrNoise.score(sent) + 4
    }

    /** Olumsuzluk sözcükleri; kesme işaretini kaçıran okumalar ("dont", "cant") da sayılır. */
    private val negations = setOf(
        "not", "no", "never", "nothing", "nobody", "none", "nowhere", "neither", "nor", "cannot",
        "dont", "doesnt", "didnt", "cant", "wont", "isnt", "arent", "wasnt", "werent", "aint",
        "couldnt", "shouldnt", "wouldnt", "havent", "hasnt", "hadnt", "mustnt", "neednt",
    )

    /**
     * [reread], [sent]'te olmayan bir anlam işareti taşıyor mu: daha çok olumsuzluk ya da gönderilende bulunmayan bir sayı.
     * Bu farklar karakterce küçüktür ("I can do that for you right now." / "I can't do that for you right now.": 0.94) ama cümleyi tersine çevirir; ilk kare
     * olumsuzluğu kaçırıp hızlı yoldan gittiyse doğru okuma yeniden okuma sayılıp atılıyordu. Yalnız EKLENEN işaret
     * sayılır: işareti düşüren okuma çoğu zaman OCR kaybıdır. Rakam karışmış sözcük ("n0t") harfe çevrilip sayılır;
     * kesmenin tek başına kalan "t"si bilinen bir olumsuz kısaltmayı tamamladığında olumsuzluktur (Windows: TextMatch.AddsMeaning).
     */
    fun addsMeaning(reread: String, sent: String): Boolean {
        val words = normalize(reread).split(' ').filter { it.isNotEmpty() }
        val sentWords = normalize(sent).split(' ').filter { it.isNotEmpty() }
        val (rereadNegations, numbers) = meaningMarks(words)
        val (sentNegations, sentNumbers) = meaningMarks(sentWords)
        if (rereadNegations > sentNegations) return true
        if (numbers.isEmpty()) return false
        val remaining = sentNumbers.toMutableList()
        val added = numbers.toMutableList()
        // Eşit uzunlukta sözcük konumunu, eksik/ek sözcükte eşleşen baş/son bölümü kullan.
        // Baştaki "I", başka konumdaki gerçek "5 → 1" değişimini gizlememeli.
        if (words.size == sentWords.size) {
            for (i in words.indices)
                if (words[i] != sentWords[i] && sameGlyphWord(words[i], sentWords[i])) added.remove(words[i])
        } else {
            var prefix = 0
            while (prefix < minOf(words.size, sentWords.size) && sameGlyphWord(words[prefix], sentWords[prefix])) {
                if (words[prefix] != sentWords[prefix]) added.remove(words[prefix])
                prefix++
            }
            var i = words.lastIndex
            var j = sentWords.lastIndex
            while (i >= prefix && j >= prefix && sameGlyphWord(words[i], sentWords[j])) {
                if (words[i] != sentWords[j]) added.remove(words[i])
                i--; j--
            }
        }
        for (number in added) if (!remaining.remove(number)) return true
        return false
    }

    private fun sameGlyphWord(word: String, sent: String): Boolean =
        word == sent || (word.all { it in '0'..'9' } && foldDigits(word) == sent)

    private fun meaningMarks(words: List<String>): Pair<Int, List<String>> {
        var count = 0
        val numbers = mutableListOf<String>()
        for ((i, original) in words.withIndex()) {
            if (original.all { it in '0'..'9' }) {
                numbers.add(original)
                continue
            }
            val word = if (original.any { it in '0'..'9' }) foldDigits(original) else original
            if (word in negations || (word == "t" && i > 0 && (foldDigits(words[i - 1]) + "t") in negations)) count++
        }
        return count to numbers
    }

    /** OCR'ın harfle karıştırdığı rakamlar harfe çevrilir ("n0t" → "not"). */
    private fun foldDigits(word: String): String = word.map {
        when (it) { '0' -> 'o'; '1' -> 'i'; '3' -> 'e'; '4' -> 'a'; '5' -> 's'; '7' -> 't'; '8' -> 'b'; else -> it }
    }.joinToString("")

    /** [new], [old]'un sonuna sözcük eklenmiş hali mi (daktilo efekti; satırın başı okunmamışsa başına eklenmiş hali). */
    fun isGrowth(new: String, old: String): Boolean {
        val x = normalize(new).split(' ').filter { it.isNotEmpty() }
        val y = normalize(old).split(' ').filter { it.isNotEmpty() }
        if (y.isEmpty() || x.size <= y.size) return false
        return startsWith(x, y) || (y.size >= 2 && endsWith(x, y))
    }

    /** Levenshtein oranı (sözcük dizileri için). */
    private fun similarity(x: List<String>, y: List<String>): Double {
        if (x.isEmpty() || y.isEmpty()) return if (x.isEmpty() && y.isEmpty()) 1.0 else 0.0
        var previous = IntArray(y.size + 1) { it }
        for (i in 1..x.size) {
            val row = IntArray(y.size + 1)
            row[0] = i
            for (j in 1..y.size) row[j] = minOf(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + if (x[i - 1] == y[j - 1]) 0 else 1)
            previous = row
        }
        return 1 - previous[y.size].toDouble() / maxOf(x.size, y.size)
    }

    /** Gevşek uzamada eski okumanın en az bu kadar harfi olmalı; kısa satırda bir harf bile anlamı değiştirir. */
    const val LOOSE_GROWTH_LETTERS = 12

    /**
     * [new], [old]'un uzamış hali mi; eski okumanın sözcükleri yazı tanıma farkıyla başka okunmuş olabilir. Uzun satır
     * aşama aşama belirir (daktilo efekti) ya da iki satırlık altyazının önce ilk satırı okunur; her okumada bir iki harf
     * başka çıkınca ("Enzo" / "Enz0", "family" / "farnily") [isGrowth] sözcük sözcük eşleşmeyi bulamıyor, yarım okumanın
     * çevirisi tamamının çevirisiyle üst üste duruyor, sırada bekleyen yarım okumalar da tek tek çevrilip gecikme
     * birikiyordu (beta-104, Mafia: The Old Country). Boşluksuz harf dizisinde eski okuma yenisinin başına (satırın başı
     * okunmamışsa sonuna) %85 benziyorsa uzamadır (Mac: TextMatch.isLooseGrowth, Windows: TextMatch.IsLooseGrowth).
     */
    fun isLooseGrowth(new: String, old: String): Boolean {
        if (isGrowth(new, old)) return true
        val x = normalize(new).split(' ').filter { it.isNotEmpty() }
        val y = normalize(old).split(' ').filter { it.isNotEmpty() }
        if (y.size < 3 || x.size < y.size) return false
        val a = x.joinToString("")
        val b = y.joinToString("")
        if (b.length < LOOSE_GROWTH_LETTERS || a.length < b.length + 3) return false
        return isSimilar(a.take(b.length), b, 0.85) || isSimilar(a.takeLast(b.length), b, 0.85)
    }

    /** Uzun satır sayılan okumanın en az harf sayısı ([isJitterOf]). */
    const val JITTER_LETTERS = 30

    /**
     * [reread], [shown]'ın yalnız yazı tanıma farkıyla başka okunmuş hali mi (uzun satır): bir iki harf başka ("Enz0",
     * "y0u"), sonuna çöp parça eklenmiş ("quietly. Il"), cümle ortasında kesilmiş ya da arada bir sözcüğü düşmüş okuma.
     * Böyle okuma motora yeniden gitmez; ekrandaki (ya da beklenen) çevirisi kalır. Anlam işareti (olumsuzluk, sayı)
     * ekleyen ya da düşüren, gerçek sözcükle uzayan, cümle sonuyla biten kısa ve bozuk sözcüğü onaran okuma
     * (SubtitleStabilizer düzeltmesi, #854) farklıdır, yeniden çevrilir. Yalnız uzun satırlarda ([JITTER_LETTERS])
     * geçerlidir (Mac: TextMatch.isJitter, Windows: TextMatch.IsJitterOf).
     */
    fun isJitterOf(reread: String, shown: String): Boolean {
        val x = normalize(reread).split(' ').filter { it.isNotEmpty() }
        val y = normalize(shown).split(' ').filter { it.isNotEmpty() }
        val a = x.joinToString("")
        val b = y.joinToString("")
        if (minOf(a.length, b.length) < JITTER_LETTERS) return false
        if (addsMeaning(reread, shown) || addsMeaning(shown, reread)) return false
        if (x.size == y.size) return isSimilar(a, b, 0.9) && !SubtitleStabilizer.repairsWords(x, y)
        // Cümle ortasında kesilen okuma (satırın bir bölümü okunamadı): gösterilen tamamı kalır. Cümle sonuyla biten kısa
        // okuma aynı sözlerle başlayan ayrı bir söz olabilir; ona dokunulmaz.
        if (x.size < y.size) {
            return !SubtitleStabilizer.endsSentence(reread) && (isLooseGrowth(shown, reread) || isSimilar(a, b, 0.9))
        }
        // Uzayan okuma ancak eklenen parçalar çöpse aynı satırdır; gerçek sözcükle uzayan satır yeniden çevrilir.
        val prefix = startsWith(x, y)
        val suffix = endsWith(x, y)
        if (prefix || suffix) return (if (prefix) x.drop(y.size) else x.dropLast(y.size)).all(::isJunkToken)
        return isSimilar(a, b, 0.9) && x.count { !isJunkToken(it) } <= y.size
    }

    /** İngilizcede tek başına geçen kısa sözcükler (Windows: SubtitleStabilizer.ShortWords). */
    private val shortWords = setOf(
        "a", "i", "o", "an", "am", "as", "at", "be", "by", "do", "go", "ha", "he", "hi", "if", "in", "is", "it", "me", "mr",
        "ms", "mrs", "dr", "st", "my", "no", "of", "oh", "ok", "on", "or", "so", "to", "tv", "uh", "um", "up", "us", "we", "ya", "ye",
    )

    /** Yazı tanımanın uydurduğu parça: bilinen kısa sözcük olmayan 1–2 harf ya da sözcük olamayacak harf dizisi. */
    internal fun isJunkToken(word: String): Boolean = (word.length <= 2 && word !in shortWords) || OcrNoise.isNonWord(word)

    private fun startsWith(words: List<String>, part: List<String>) = words.take(part.size) == part

    private fun endsWith(words: List<String>, part: List<String>) = words.takeLast(part.size) == part

    private fun isWholeRows(count: Int, rows: List<String>, fromStart: Boolean): Boolean {
        var total = 0
        for (row in if (fromStart) rows else rows.reversed()) {
            total += cleanWords(row).size
            if (total == count) return true
            if (total > count) return false
        }
        return false
    }

    // Tek harfler ("a", "I" ya da OCR'ın uydurduğu "O") karşılaştırmaya bir şey katmaz.
    private fun cleanWords(normalized: String): List<String> =
        normalized.split(' ').filter { it.length > 1 && it.none(::isNumber) }

    /** .NET'teki char.IsNumber: Nd, Nl, No. */
    internal fun isNumber(c: Char): Boolean = when (Character.getType(c).toByte()) {
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }

    private fun isAlphanumeric(c: Char): Boolean = when (Character.getType(c).toByte()) {
        Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
        Character.MODIFIER_LETTER, Character.OTHER_LETTER,
        Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK,
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }
}
