// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Paketteki satırın bulanık imzası: OCR'ın bozduğu satırı (harf hatası, birleşmiş sözcük) bulmak için. canon metnin
 * boşlukları atılır, OCR'ın karıştırdığı harfler birleştirilir (l/1/ı/j → i, 0 → o, 5 → s), kalan dizinin her farklı
 * üçlüsü FNV-1a 64 ile özetlenip m bitten birine düşer (Bloom kümesi; m uzunlukla büyür: 64/128/256). Her bit onlarca
 * farklı üçlünün ortak izidir ve sıra tutulmaz: İngilizce metin geri çıkarılamaz. Mac (PackFuzzy.swift), Windows
 * (PackFuzzy.cs) ve paket betiğiyle (augment.py, common.py) birebir aynı; ortak deneme verisi fuzzy-vectors.json.
 */
object PackFuzzy {
    /** Bundan kısa satırda bulanık arama yok. */
    const val MIN_LENGTH = 16
    /** Bloom kümesinin en büyük boyu (32 bayt). */
    const val MAX_BITS = 256
    /** Üçlü başına bit. */
    const val BITS_PER_GRAM = 3
    /** Türkçesi farklı en yakın ikinci aday en az bu kadar geride olmalı. */
    const val MARGIN = 5.0

    /**
     * Kabul edilen bulanık adayda ortak bitler rastlantının en az bu kadar standart sapma üstünde olmalı ([evidence]).
     * Kısa satırın 64 bitlik imzasında yüz binlerce aday arasında rastlantıyla eşiği geçen ilgisiz satır çıkıyordu
     * ("No n0, the wealth was all Mother's." → "He could use some clothes."). Mac ve Windows ile aynı.
     */
    const val MINIMUM_EVIDENCE = 5.0
    /**
     * OCR izi olmayan okumada tek yönlü kapsamada kısa tarafın adayda olmayan en çok bit sayısı: temiz okuma ya uzun
     * satırın tam bir parçasıdır ya da başka bir satırdır.
     */
    const val CLEAN_MISSING = 0

    /** Ortak bitlerin rastlantıya göre fazlası (standart sapma cinsinden), sorgu ve aday yönünden. */
    class Evidence(val query: Double, val entry: Double)

    /**
     * Ortak bitlerin rastlantıya göre ne kadar fazla olduğu, iki yönden: sorgunun bitleri adayın doluluğuyla ve adayın
     * bitleri sorgunun doluluğuyla rastlantıda ne kadar örtüşürdü.
     */
    fun evidence(both: Int, inQuery: Int, inEntry: Int, bits: Int): Evidence {
        val fillQuery = inQuery.toDouble() / bits
        val fillEntry = inEntry.toDouble() / bits
        fun z(count: Int, fill: Double): Double {
            val mean = count * fill
            val spread = Math.sqrt(count * fill * (1 - fill))
            return if (spread > 0) (both - mean) / spread else 0.0
        }
        return Evidence(z(inQuery, fillEntry), z(inEntry, fillQuery))
    }

    /** OCR izi olmayan satır neredeyse aynı olmalı: (uzunluk sınırı, en düşük benzerlik). */
    private val cleanMinimum = listOf(24 to 90.0, 256 to 80.0)
    /** OCR izi olan satır: (uzunluk sınırı, en düşük benzerlik). */
    private val damagedMinimum = listOf(24 to 70.0, 40 to 60.0, 256 to 55.0)

    /**
     * Tek yönlü kapsama (yarım ya da fazlalıklı okuma): iki taraf da en az [minLength] harf; kısa tarafın en az [inner]'ı
     * uzun tarafta; uzun tarafın en az [partial]'ı (satır yarım okunmuş) ya da [extra]'sı (okumada fazlalık var: köşe
     * yazısı, çöp) kısa tarafta; benzerlik `inner - penalty` sayılır. Fazlalık az olmalı: iki ayrı altyazının birleştiği
     * okuma tek bir altyazıya çıkmasın.
     */
    object Containment {
        const val minLength = 22
        const val inner = 90.0
        const val partial = 25.0
        const val extra = 55.0
        const val penalty = 10.0
    }

    /**
     * Fazlalıklı okumada yan cümle denetimi ([clauseHashes]): okuma birden çok cümle ya da yan cümleyse en az [letters]
     * harfli her birinin üçlülerinin en az [covered]'ı kısa adayda olmalı. İki altyazı yan yana okununca ("Hey, look. …
     * But listen, I got some other work.") ikinci cümle adayda yoktur: yalnız birinin Türkçesi gösterilmez, satır cümle
     * cümle aranır ya da motora gider.
     */
    object SentenceCheck {
        const val letters = 6
        const val covered = 30.0
    }

    private const val CLAUSE_ENDERS = ".!?…,;:"
    /** Ardından küçük harf gelse de bölen işaretler (yan cümle). */
    private const val CLAUSE_MARKS = ",;:"
    private const val CLAUSE_CLOSERS = "\"'”’)]"

    /**
     * Satırın cümle ve yan cümleleri: . ! ? … (yinelenebilir, isteğe bağlı kapanış tırnağı ya da ayraç) ardından boşluk
     * ve büyük harf, ya da , ; : … ve üç nokta ardından boşluk. Tek noktadan sonra küçük harfle süren yer ("seriously.
     * nis seriously") bölünmez: OCR çöpüdür, ayrı cümle değil. Mac'teki `PackFuzzy.clauses` ile aynı.
     */
    fun clauses(text: String): List<String> {
        val points = text.codePoints().toArray()
        val output = mutableListOf<String>()
        var begin = 0
        var index = 0
        fun inSet(set: String, point: Int) = point <= 0xffff && set.indexOf(point.toChar()) >= 0
        fun cut(end: Int) {
            val clause = String(points, begin, end - begin).trim()
            if (clause.isNotEmpty()) output.add(clause)
        }
        while (index < points.size) {
            if (!inSet(CLAUSE_ENDERS, points[index])) { index++; continue }
            var end = index
            while (end < points.size && inSet(CLAUSE_ENDERS, points[end])) end++
            while (end < points.size && inSet(CLAUSE_CLOSERS, points[end])) end++
            var next = end
            while (next < points.size && isSpace(points[next])) next++
            // Üç nokta da küçük harfle süren yan cümleyi ayırır ("to escape... if we're able").
            var dots = 0
            var soft = false
            for (position in index until end) {
                if (inSet(CLAUSE_MARKS, points[position]) || points[position] == '…'.code) soft = true
                if (points[position] == '.'.code) dots++
            }
            if (next > end && next < points.size && (soft || dots > 1 || Character.isUpperCase(points[next]))) {
                cut(end)
                begin = next
            }
            index = maxOf(next, index + 1)
        }
        cut(points.size)
        // SentenceCheck.letters harften kısa yan cümle ("Bye," "Dad.") sonrakine (sonuncuysa öncekine) eklenir.
        val merged = mutableListOf<String>()
        var pending = ""
        for (clause in output) {
            val joined = if (pending.isEmpty()) clause else "$pending $clause"
            if (folded(joined).size < SentenceCheck.letters) pending = joined else { merged.add(joined); pending = "" }
        }
        if (pending.isNotEmpty()) {
            if (merged.isNotEmpty()) merged[merged.size - 1] = merged.last() + " " + pending else merged.add(pending)
        }
        return merged
    }

    /**
     * Fazlalıklı okumanın denetlenecek yan cümleleri: her biri için üçlü kümesi seçenekleri (biri kısa adayda yeterince
     * varsa yan cümle tamam). Köşe yazısına benzeyen yan cümle atlanır; ilk yan cümlenin başındaki ve sonuncunun
     * sonundaki en çok üç büyük harfli sözcük ("Mirror Park Errr.", "… in a state Vinewood Hills") köşe yazısı olabilir,
     * onlarsız hâli de seçenektir. Seçeneklerden biri [SentenceCheck.letters] harften kısaysa yan cümle denetlenmez.
     * Okuma tek yan cümleyse boş.
     */
    fun clauseHashes(text: String): List<List<LongArray>> {
        val parts = clauses(text)
        if (parts.size < 2) return emptyList()
        val output = mutableListOf<List<LongArray>>()
        for ((position, part) in parts.withIndex()) {
            if (overlayLike(part)) continue
            val tokens = words(part).map { String(it, 0, it.size) }
            val options = mutableListOf(part)
            for (count in 1..3) {
                if (count >= tokens.size) break
                if (position == 0 && tokens.take(count).all(::capitalized)) options.add(tokens.drop(count).joinToString(" "))
                if (position == parts.size - 1 && tokens.takeLast(count).all(::capitalized)) options.add(tokens.dropLast(count).joinToString(" "))
            }
            val folds = options.map(::folded)
            if (folds.any { it.size < SentenceCheck.letters }) continue
            output.add(folds.map(::trigramHashes))
        }
        return output
    }

    /** Büyük harfle başlayan, yalnız harf ve rakamlı sözcük (köşe yazısı sözcüğü: "Vinewood", "LOSNN"). */
    fun capitalized(word: String): Boolean {
        val points = word.codePoints().toArray()
        return points.isNotEmpty() && Character.isUpperCase(points[0]) && points.all { isLetter(it) || isDigit(it) }
    }

    /**
     * Köşe yazısına benzeyen parça: "•" içerir ya da en çok dört sözcük, noktalama yok ve her sözcük büyük harfle başlar
     * ("San Andreas", "First Person • zoom"). Fazlalık sayılır, cümle değil.
     */
    fun overlayLike(text: String): Boolean {
        if (text.contains('•')) return true
        val tokens = words(text).map { String(it, 0, it.size) }
        return tokens.isNotEmpty() && tokens.size <= 4 && tokens.all(::capitalized)
    }

    /**
     * Her yan cümlenin seçeneklerinden birinin üçlülerinin en az [SentenceCheck.covered]'ı (rastlantıdan arındırılmış)
     * adayın Bloom'unda mı. [entry]: dizindeki kelimeler, [offset]ten başlayarak bits / 64 tane; [inEntry]: adaydaki 1 bit.
     */
    fun coversClauses(clauses: List<List<LongArray>>, entry: LongArray, offset: Int, bits: Int, inEntry: Int): Boolean {
        val fill = inEntry.toDouble() / bits
        if (fill >= 1) return false
        fun covered(hashes: LongArray): Boolean {
            val words = bloom(hashes, bits)
            var both = 0
            var inClause = 0
            for (index in words.indices) {
                both += java.lang.Long.bitCount(words[index] and entry[offset + index])
                inClause += java.lang.Long.bitCount(words[index])
            }
            if (inClause == 0) return true
            return 100.0 * (both.toDouble() / inClause - fill) / (1 - fill) >= SentenceCheck.covered
        }
        return clauses.all { options -> options.any(::covered) }
    }

    private val fold = mapOf(
        'l'.code to 'i'.code, '1'.code to 'i'.code, 'ı'.code to 'i'.code, 'j'.code to 'i'.code, '0'.code to 'o'.code,
        '5'.code to 's'.code, 'æ'.code to 'a'.code, 'ø'.code to 'o'.code, 'œ'.code to 'o'.code, 'ß'.code to 's'.code,
    )

    /** Yazı tanımanın sık karıştırdığı harf dizileri (canon metinde, küçük harf): okunan → asıl olabilecek. */
    val confusions = listOf(
        "rn" to "m", "m" to "rn", "cl" to "d", "d" to "cl", "vv" to "w", "ri" to "n", "n" to "ri", "li" to "h",
        "l" to "i", "i" to "l", "1" to "l", "1" to "i", "0" to "o", "5" to "s", "j" to "i", "c" to "e", "e" to "c",
        "a" to "o", "o" to "a", "h" to "b", "b" to "h", "f" to "t", "t" to "f", "u" to "v", "v" to "u", "y" to "v",
        "v" to "y", "q" to "g", "g" to "q",
    )
    /** Tek düzeltmeyle denenecek en kısa ve en uzun canon satır (harf sayısı); daha uzun satırda bulanık imza yeter. */
    const val VARIANT_MINIMUM = 6
    const val VARIANT_MAXIMUM = 48

    /**
     * Satırın tek bir OCR düzeltmesiyle olabileceği canon hâller: karıştırılan harf dizisi değişir, bir harf düşer,
     * sözcük ikiye bölünür (OCR boşluğu ya da kesme işaretini yuttu: "cant" → "can t") ya da iki sözcük birleşir. Pakette
     * tam anahtarla aranırlar; bulanık imzanın yetmediği kısa satırlar içindir. Mac'teki `PackFuzzy.variants` ile aynı küme.
     */
    fun variants(text: String): List<String> {
        val canon = PackKey.canon(text)
        val points = canon.codePoints().toArray()
        val count = points.size
        if (count < VARIANT_MINIMUM || count > VARIANT_MAXIMUM) return emptyList()
        // at[i]: i. harfin metindeki yeri (UTF-16), at[count] = metnin boyu.
        val at = IntArray(count + 1)
        for (index in 1..count) at[index] = at[index - 1] + Character.charCount(points[index - 1])
        val output = HashSet<String>()
        fun add(cut: Int, middle: String, resume: Int) {
            val value = StringBuilder(canon.length + 2).append(canon, 0, at[cut]).append(middle).append(canon, at[resume], canon.length).toString()
            if (value.isNotEmpty() && !value.startsWith(' ') && !value.endsWith(' ') && !value.contains("  ")) output.add(value)
        }
        for (index in 0 until count) {
            for ((read, real) in confusions) {
                // Karışan diziler ASCII: harf sayısı UTF-16 boyuna eşit.
                if (index + read.length > count || at[index + read.length] - at[index] != read.length ||
                    !canon.regionMatches(at[index], read, 0, read.length)) continue
                add(index, real, index + read.length)
            }
            add(index, "", index + 1)
            if (points[index] != ' '.code && index > 0 && points[index - 1] != ' '.code) add(index, " ", index)
        }
        output.remove(canon)
        return output.sorted()
    }

    /** İkinci tur düzeltmelerin en kısa ve en uzun canon satırı (harf sayısı). */
    const val EDIT_MINIMUM = 10
    const val EDIT_MAXIMUM = 40
    /** İki karışıklığın birden deneneceği en uzun canon satır. */
    const val EDIT_PAIRS = 32

    /**
     * Yazı tanımanın birbirine benzettiği harfler (canon, küçük harf): okunan → asıl olabilecek. İkinci tur düzeltmede
     * bir harf yalnız bunlardan birine döner: herhangi bir harfe dönmek "honey" → "money" gibi başka gerçek satırlara
     * çıkıyordu. Mac ve Windows ile aynı tablo.
     */
    val lookalikes: Map<Char, String> = mapOf(
        'a' to "oecusdq", 'b' to "hkdlp", 'c' to "eoa", 'd' to "aobq", 'e' to "coa", 'f' to "tlir", 'g' to "qyp", 'h' to "bnk",
        'i' to "ljtfr", 'j' to "il", 'k' to "hbx", 'l' to "ijtf", 'm' to "n", 'n' to "mhru", 'o' to "aecudq", 'p' to "qgb",
        'q' to "gpo", 'r' to "nfti", 's' to "z", 't' to "flir", 'u' to "vnoa", 'v' to "uyw", 'w' to "v", 'x' to "ky",
        'y' to "vgx", 'z' to "s", '0' to "o", '1' to "il", '5' to "s", '6' to "b", '8' to "b", '9' to "g",
    )
    private val lookalikeBytes: Array<ByteArray> = Array(128) { code ->
        lookalikes[code.toChar()]?.toByteArray(Charsets.US_ASCII) ?: ByteArray(0)
    }
    private val alphabet = "abcdefghijklmnopqrstuvwxyz".toByteArray(Charsets.US_ASCII)
    private val confusionBytes by lazy {
        confusions.map { (read, real) -> read.toByteArray(Charsets.US_ASCII) to real.toByteArray(Charsets.US_ASCII) }
    }

    /**
     * İkinci tur düzeltmeler: [variants] pakette hiçbir satıra çıkmazsa denenir. Bir harf benzediği bir harf olur
     * ([lookalikes]), yutulmuş bir harf eklenir ("abut" → "about") ya da [EDIT_PAIRS]'ten kısa satırda iki karışıklık
     * birden düzelir ("l'm rnad" → "i'm mad"). Yalnız [EDIT_MINIMUM]..[EDIT_MAXIMUM] harfli satırlarda; [variants]taki ve
     * satırın kendisi olan hâller yoktur. Sıralı canon metinler (denemeler için; arama [editKeys] ile). Mac'teki
     * `PackFuzzy.edits` ile aynı küme.
     */
    fun edits(text: String): List<String> {
        val output = HashSet<String>()
        forEachEdit(text) { bytes, size -> output.add(String(bytes, 0, size, Charsets.UTF_8)) }
        output.removeAll(variants(text).toSet())
        output.remove(PackKey.canon(text))
        return output.sorted()
    }

    /** [edits]'in anahtarları ([PackKey.canonNumber]), metne çevirmeden. */
    fun editKeys(text: String): Set<Long> {
        val output = HashSet<Long>()
        forEachEdit(text) { bytes, size -> output.add(PackKey.canonNumber(bytes, size)) }
        for (variant in variants(text)) PackKey.canonNumber(variant)?.let { output.remove(it) }
        PackKey.canonNumber(PackKey.canon(text))?.let { output.remove(it) }
        return output
    }

    /**
     * İkinci tur adaylar, UTF-8 baytlarıyla (yinelenebilir; [body]'ye tampon ve boyu). Değişen ve eklenen harfler
     * ASCII'dir; UTF-8'de ASCII baytı çok baytlı bir harfin içinde geçmez, bu yüzden karışıklıklar bayt bayt aranabilir.
     */
    private fun forEachEdit(text: String, body: (ByteArray, Int) -> Unit) {
        val canon = PackKey.canon(text)
        val points = canon.codePoints().toArray()
        if (points.size < EDIT_MINIMUM || points.size > EDIT_MAXIMUM) return
        val bytes = canon.toByteArray(Charsets.UTF_8)
        // at[i]: i. harfin bayt konumu; at[count]: bayt sayısı.
        val at = IntArray(points.size + 1)
        for (index in points.indices) {
            val point = points[index]
            at[index + 1] = at[index] + when {
                point < 0x80 -> 1
                point < 0x800 -> 2
                point < 0x10000 -> 3
                else -> 4
            }
        }
        var buffer = ByteArray(bytes.size + 8)
        fun emit(cut: Int, middle: ByteArray, middleSize: Int, resume: Int, source: ByteArray) {
            val size = cut + middleSize + source.size - resume
            if (size > buffer.size) buffer = ByteArray(size + 8)
            System.arraycopy(source, 0, buffer, 0, cut)
            System.arraycopy(middle, 0, buffer, cut, middleSize)
            System.arraycopy(source, resume, buffer, cut + middleSize, source.size - resume)
            body(buffer, size)
        }
        val one = ByteArray(1)
        for (index in 0..points.size) {
            val cut = at[index]
            for (letter in alphabet) {
                one[0] = letter
                emit(cut, one, 1, cut, bytes)
            }
            if (index == points.size || points[index] >= 128) continue
            for (letter in lookalikeBytes[points[index]]) {
                one[0] = letter
                emit(cut, one, 1, at[index + 1], bytes)
            }
        }
        if (points.size > EDIT_PAIRS) return
        for (variant in variants(text)) {
            val source = variant.toByteArray(Charsets.UTF_8)
            for (index in source.indices) {
                for ((read, real) in confusionBytes) {
                    if (index + read.size > source.size) continue
                    var same = true
                    for (offset in read.indices) if (source[index + offset] != read[offset]) { same = false; break }
                    if (same) emit(index, real, real.size, index + read.size, source)
                }
            }
        }
    }

    /** canon metin, boşluksuz ve OCR'ın karıştırdığı harfler birleşmiş (kod noktaları). */
    fun folded(text: String): IntArray =
        PackKey.canon(text).codePoints().filter { it != ' '.code }.map { fold[it] ?: it }.toArray()

    /** Uzunluğa göre Bloom boyu (bit). */
    fun bits(length: Int): Int {
        var bits = 64
        while (bits < MAX_BITS && length * BITS_PER_GRAM > bits) bits *= 2
        return bits
    }

    fun trigramHashes(points: IntArray): LongArray {
        if (points.size < 3) return LongArray(0)
        val hashes = LinkedHashSet<Long>()
        val buffer = ByteArray(4)
        for (index in 0..points.size - 3) {
            var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
            for (offset in 0 until 3) {
                val written = utf8(points[index + offset], buffer)
                for (b in 0 until written) {
                    hash = hash xor (buffer[b].toLong() and 0xff)
                    hash *= 0x100000001b3L
                }
            }
            hashes.add(hash)
        }
        return hashes.toLongArray()
    }

    private fun utf8(codePoint: Int, out: ByteArray): Int = when {
        codePoint < 0x80 -> { out[0] = codePoint.toByte(); 1 }
        codePoint < 0x800 -> {
            out[0] = (0xc0 or (codePoint shr 6)).toByte(); out[1] = (0x80 or (codePoint and 0x3f)).toByte(); 2
        }
        codePoint < 0x10000 -> {
            out[0] = (0xe0 or (codePoint shr 12)).toByte(); out[1] = (0x80 or ((codePoint shr 6) and 0x3f)).toByte()
            out[2] = (0x80 or (codePoint and 0x3f)).toByte(); 3
        }
        else -> {
            out[0] = (0xf0 or (codePoint shr 18)).toByte(); out[1] = (0x80 or ((codePoint shr 12) and 0x3f)).toByte()
            out[2] = (0x80 or ((codePoint shr 6) and 0x3f)).toByte(); out[3] = (0x80 or (codePoint and 0x3f)).toByte(); 4
        }
    }

    fun bloom(hashes: LongArray, bits: Int): LongArray {
        val words = LongArray(bits / 64)
        for (hash in hashes) {
            val bit = (hash and (bits - 1).toLong()).toInt()
            words[bit shr 6] = words[bit shr 6] or (1L shl (bit and 63))
        }
        return words
    }

    /**
     * İki yönlü, rastlantıdan arındırılmış kapsama (0-100): min(sorgunun üçlülerinin adayda olanı, adayınkinin sorguda
     * olanı). [entry]: dizindeki kelimeler, [offset]ten başlayarak bits / 64 tane.
     */
    fun similarity(query: LongArray, entry: LongArray, offset: Int, bits: Int): Double {
        var both = 0
        var inQuery = 0
        var inEntry = 0
        for (index in 0 until bits / 64) {
            val q = query[index]
            val e = entry[offset + index]
            both += java.lang.Long.bitCount(q and e)
            inQuery += java.lang.Long.bitCount(q)
            inEntry += java.lang.Long.bitCount(e)
        }
        return score(both, inQuery, inEntry, bits)
    }

    /** Benzerlik, bit sayılarından (ortak, sorgudaki, adaydaki). */
    fun score(both: Int, inQuery: Int, inEntry: Int, bits: Int): Double {
        if (inQuery == 0 || inEntry == 0) return 0.0
        val fillQuery = inQuery.toDouble() / bits
        val fillEntry = inEntry.toDouble() / bits
        if (fillQuery >= 1 || fillEntry >= 1) return 0.0
        return 100.0 * minOf(
            (both.toDouble() / inQuery - fillEntry) / (1 - fillEntry),
            (both.toDouble() / inEntry - fillQuery) / (1 - fillQuery),
        )
    }

    /** Rastlantıdan arındırılmış tek yönlü kapsamalar (0-100): sorgunun adayda olanı ([Coverage.query]), adayın sorguda olanı. */
    class Coverage(val query: Double, val entry: Double)

    fun coverage(both: Int, inQuery: Int, inEntry: Int, bits: Int): Coverage {
        if (inQuery == 0 || inEntry == 0) return Coverage(0.0, 0.0)
        val fillQuery = inQuery.toDouble() / bits
        val fillEntry = inEntry.toDouble() / bits
        if (fillQuery >= 1 || fillEntry >= 1) return Coverage(0.0, 0.0)
        return Coverage(
            100.0 * (both.toDouble() / inQuery - fillEntry) / (1 - fillEntry),
            100.0 * (both.toDouble() / inEntry - fillQuery) / (1 - fillQuery),
        )
    }

    /** (uzunluk, Bloom baytları) — paket betiğinin yazdığıyla aynı; satır çok kısaysa null. */
    fun signature(text: String): Pair<Int, ByteArray>? {
        val points = folded(text)
        if (points.size < MIN_LENGTH) return null
        val length = minOf(points.size, 255)
        val words = bloom(trigramHashes(points), bits(length))
        val bytes = ByteBuffer.allocate(words.size * 8).order(ByteOrder.LITTLE_ENDIAN)
        for (word in words) bytes.putLong(word)
        return length to bytes.array()
    }

    /** Kabul için en düşük benzerlik (0-100), OCR izine ve uzunluğa göre. */
    fun required(length: Int, damaged: Boolean): Double {
        val table = if (damaged) damagedMinimum else cleanMinimum
        return table.firstOrNull { length < it.first }?.second ?: table.last().second
    }

    private const val EDGE = ".,!?;:'\"()[]-…“”’‘"
    private const val TYPOGRAPHIC = "’‘“”—–…"

    fun isLetter(codePoint: Int) = Character.isLetter(codePoint)

    /** Ondalık rakam ya da rakam değerli işaret ("²", "①"); Mac'te numericType decimal/digit. */
    fun isDigit(codePoint: Int): Boolean = Character.isDigit(codePoint) ||
        (Character.getType(codePoint) == Character.OTHER_NUMBER.toInt() && Character.getNumericValue(codePoint) in 0..9)

    /** Boşluk karakteri (Unicode; Mac'teki isWhitespace). */
    fun isSpace(codePoint: Int) = Character.isWhitespace(codePoint) || Character.isSpaceChar(codePoint)

    /** Boşluklarla ayrılan sözcükler (kod noktası dizileri). */
    fun words(text: String): List<IntArray> {
        val points = text.codePoints().toArray()
        val words = mutableListOf<IntArray>()
        var start = -1
        for (index in 0..points.size) {
            val space = index == points.size || isSpace(points[index])
            if (space && start >= 0) {
                words.add(points.copyOfRange(start, index))
                start = -1
            } else if (!space && start < 0) {
                start = index
            }
        }
        return words
    }

    /**
     * OCR izi: İngilizce satırda ASCII dışı harf ya da işaret, sözcük içinde harf olmayan işaret ya da rakam, tek harfli
     * garip sözcük, çok uzun (birleşmiş) sözcük. İzi olmayan satırın neredeyse aynı olması gerekir: temiz ama pakette
     * olmayan satır büyük olasılıkla başka bir satırdır.
     */
    fun damaged(text: String): Boolean {
        if (text.codePoints().anyMatch { it > 127 && (it > 0xffff || TYPOGRAPHIC.indexOf(it.toChar()) < 0) }) return true
        for (word in words(text)) {
            var from = 0
            var to = word.size
            while (from < to && word[from] <= 0xffff && EDGE.indexOf(word[from].toChar()) >= 0) from++
            while (to > from && word[to - 1] <= 0xffff && EDGE.indexOf(word[to - 1].toChar()) >= 0) to--
            val core = word.copyOfRange(from, to)
            if (core.isEmpty()) continue
            for (index in 1 until core.size - 1) {
                if (isLetter(core[index - 1]) && isLetter(core[index + 1]) && !isLetter(core[index]) &&
                    core[index] != '\''.code && core[index] != '’'.code && core[index] != '-'.code) return true
            }
            for (index in 1 until core.size) {
                val previous = core[index - 1]
                val current = core[index]
                if ((isLetter(previous) && isDigit(current)) || (isDigit(previous) && isLetter(current))) return true
            }
            if (core.size == 1 && isLetter(core[0]) && core[0] !in intArrayOf('a'.code, 'A'.code, 'I'.code, 'o'.code, 'O'.code)) return true
            if (core.size > 14) return true
        }
        return false
    }
}

/**
 * Bir paketin bulanık dizini: imzalı satırlar uzunluğa göre sıralı (aynı uzunlukta anahtar sırasıyla), Bloom kelimeleri
 * ardışık. Telefonda bellek az olduğu için satır başına yalnız anahtar (8 bayt) ve Bloom kelimeleri tutulur; uzunluk ve
 * kelime yeri uzunluk kovalarından ([start], [wordStart]) çıkar, bit sayısı aramada sayılır (Mac ve Windows bunları
 * ayrıca saklar; sonuç aynı).
 */
class PackFuzzyIndex private constructor(
    private val keys: LongArray,
    private val words: LongArray,
    /** `start[n]`: uzunluğu n olan ilk satırın sırası (`start[256]` = satır sayısı). */
    private val start: IntArray,
    /** `wordStart[n]`: uzunluğu n olan ilk satırın ilk Bloom kelimesi. */
    private val wordStart: IntArray,
) {
    val count get() = keys.size

    /** Bellekte tuttuğu bayt (ölçüm için). */
    val bytes: Long get() = keys.size * 8L + words.size * 8L + (start.size + wordStart.size) * 4L

    companion object {
        /**
         * Paketteki "fuzzy" nesnesi ([PackJson.Fuzzy]). [order]: paketteki bütün anahtarlar (entries + segments, Türkçesi
         * boş olanlar da), işaretsiz sayı sırasıyla. Biçim tutmazsa null (paket yine de tam eşleşmeyle çalışır).
         */
        internal fun decode(fuzzy: PackJson.Fuzzy, order: LongArray): PackFuzzyIndex? {
            val mask = fuzzy.mask ?: return null
            val lengths = fuzzy.lengths ?: return null
            val blooms = fuzzy.blooms ?: return null
            if (fuzzy.version != 1.0 || fuzzy.count != order.size.toDouble() || mask.size != (order.size + 7) / 8) return null
            val total = lengths.size
            val start = IntArray(257)
            for (length in lengths) start[(length.toInt() and 0xff) + 1]++
            for (length in 1..256) start[length] += start[length - 1]
            val wordStart = IntArray(257)
            for (length in 1..256) wordStart[length] = wordStart[length - 1] + (start[length] - start[length - 1]) * (PackFuzzy.bits(length - 1) / 64)
            var expectedBytes = 0L
            for (length in lengths) expectedBytes += PackFuzzy.bits(length.toInt() and 0xff) / 8
            if (expectedBytes != blooms.size.toLong()) return null
            val keys = LongArray(total)
            val words = LongArray(blooms.size / 8)
            val next = start.copyOf()
            val source = ByteBuffer.wrap(blooms).order(ByteOrder.LITTLE_ENDIAN)
            // Dosyadaki sıra: imzalı anahtarlar sayı sırasıyla, Bloom'ları ardışık; uzunluğa göre sayarak sıralanır.
            var signed = 0
            var byteOffset = 0
            for (index in order.indices) {
                if ((mask[index shr 3].toInt() shr (index and 7)) and 1 == 0) continue
                if (signed >= total) return null
                val length = lengths[signed].toInt() and 0xff
                val perLine = PackFuzzy.bits(length) / 64
                val position = next[length]++
                keys[position] = order[index]
                val wordOffset = wordStart[length] + (position - start[length]) * perLine
                for (word in 0 until perLine) words[wordOffset + word] = source.getLong(byteOffset + word * 8)
                byteOffset += perLine * 8
                signed++
            }
            if (signed != total) return null
            return PackFuzzyIndex(keys, words, start, wordStart)
        }
    }

    private class Candidate(val score: Double, val key: Long, val evidence: Double)

    /**
     * Eşik, uzunluk ve ikinci aday şartlarını sağlayan en benzer satırın anahtarı; yoksa null. [translation]: anahtarın
     * Türkçesi (aynı Türkçeli iki aday birbirinin rakibi sayılmaz). Önce boyu yakın adaylar (benzerlik iki yönlü
     * kapsamanın küçüğü). Hiçbiri eşiği geçmezse boyu çok farklı adaylarda tek yönlü kapsamaya bakılır
     * ([PackFuzzy.Containment]): yarım okunan satır (iki satırlık altyazının bir satırı) uzun adayın içinde, köşe yazısı ya
     * da çöp eklenmiş okuma kısa adayın dışında kalır.
     */
    fun nearest(text: String, translation: (Long) -> String?): Long? {
        val points = PackFuzzy.folded(text)
        if (points.size < PackFuzzy.MIN_LENGTH || keys.isEmpty()) return null
        val length = minOf(points.size, 255)
        val damaged = PackFuzzy.damaged(text)
        val need = PackFuzzy.required(length, damaged)
        val floor = need - PackFuzzy.MARGIN
        val hashes = PackFuzzy.trigramHashes(points)
        // Sorgunun üç boydaki Bloom'u (64, 128, 256 bit) ve bit sayıları.
        val queries = arrayOf(PackFuzzy.bloom(hashes, 64), PackFuzzy.bloom(hashes, 128), PackFuzzy.bloom(hashes, 256))
        val queryOnes = IntArray(3) { tier -> queries[tier].sumOf { java.lang.Long.bitCount(it) } }
        val contain = PackFuzzy.Containment
        val close = ArrayList<Candidate>()
        val contained = ArrayList<Candidate>()
        // Okumanın yan cümle üçlüleri (PackFuzzy.clauseHashes); ilk fazlalıklı adayda hesaplanır.
        var clauses: List<List<LongArray>>? = null

        /** Boyu [lower]..[upper] olan adaylar: [wide] false ise iki yönlü benzerlik ([close]), true ise tek yönlü ([contained]). */
        fun scan(lower: Int, upper: Int, wide: Boolean) {
            for (entryLength in lower..upper) {
                val first = start[entryLength]
                val end = start[entryLength + 1]
                if (first == end) continue
                val bits = PackFuzzy.bits(entryLength)
                val perLine = bits / 64
                val tier = if (bits == 64) 0 else if (bits == 128) 1 else 2
                val query = queries[tier]
                val inQuery = queryOnes[tier]
                // Hızlı eleme için uzun ve kısa taraf (tek yönlü kapsamada).
                if (wide && (entryLength < contain.minLength || entryLength == length)) continue
                var offset = wordStart[entryLength]
                for (index in first until end) {
                    var both = 0
                    var inEntry = 0
                    for (word in 0 until perLine) {
                        val value = words[offset + word]
                        both += java.lang.Long.bitCount(query[word] and value)
                        inEntry += java.lang.Long.bitCount(value)
                    }
                    offset += perLine
                    if (!wide) {
                        val score = PackFuzzy.score(both, inQuery, inEntry, bits)
                        if (score >= floor) {
                            val z = PackFuzzy.evidence(both, inQuery, inEntry, bits)
                            close.add(Candidate(score, keys[index], minOf(z.query, z.entry)))
                        }
                        continue
                    }
                    // Kısa tarafın bitlerinin en az %90'ı ortak olmalı (hızlı eleme).
                    if (both * 10 < 9 * (if (entryLength > length) inQuery else inEntry)) continue
                    val cover = PackFuzzy.coverage(both, inQuery, inEntry, bits)
                    val longer = entryLength > length
                    val inner = if (longer) cover.query else cover.entry
                    val outer = if (longer) cover.entry else cover.query
                    val least = if (longer) contain.partial else contain.extra
                    if (inner < contain.inner || outer < least || inner - contain.penalty < floor) continue
                    // OCR izi olmayan okuma adayın içindeyse (ya da aday okumanın içindeyse) kısa tarafın bitlerinin
                    // hepsi ortak olmalı: temiz okuma ya tam parçadır ya da başka bir satırdır.
                    if (!damaged && (if (longer) inQuery else inEntry) - both > PackFuzzy.CLEAN_MISSING) continue
                    // Fazlalıklı okumada her yan cümle adayda olmalı: ikinci bir altyazının cümlesi fazlalık sayılmaz.
                    if (!longer) {
                        val found = clauses ?: PackFuzzy.clauseHashes(text).also { clauses = it }
                        if (found.isNotEmpty() && !PackFuzzy.coversClauses(found, words, offset - perLine, bits, inEntry)) continue
                    }
                    val z = PackFuzzy.evidence(both, inQuery, inEntry, bits)
                    contained.add(Candidate(inner - contain.penalty, keys[index], if (longer) z.query else z.entry))
                }
            }
        }

        /** En iyi aday; eşiği geçmiyorsa (null, false), Türkçesi farklı rakibi yakınsa (null, true). */
        fun pick(found: List<Candidate>): Pair<Long?, Boolean> {
            var best: Candidate? = null
            for (candidate in found) {
                val current = best
                if (current == null || candidate.score > current.score ||
                    (candidate.score == current.score && java.lang.Long.compareUnsigned(candidate.key, current.key) > 0)) best = candidate
            }
            if (best == null || best.score < need) return null to false
            if (best.evidence < PackFuzzy.MINIMUM_EVIDENCE) return null to true
            val turkish = translation(best.key)
            for (other in found) {
                if (other.key != best.key && other.score > best.score - PackFuzzy.MARGIN && translation(other.key) != turkish) return null to true
            }
            return best.key to false
        }

        // İki yönlü aday: boyu en çok ±%25 farklı (|aday - satır| * 4 <= satır).
        scan(length - length / 4, minOf(255, length + length / 4), wide = false)
        // Tek yönlü adaylara yalnız iki yönlü hiçbir aday eşiği geçmediyse bakılır: satırın 11/20'si ile 5/2'si arası
        // (fazlalıklı okumada aday satırın en az %55'i kadar olur).
        val (key, ambiguous) = pick(close)
        if (key != null || ambiguous || length < contain.minLength) return key
        scan(maxOf(contain.minLength, length * 11 / 20), minOf(255, length * 5 / 2), wide = true)
        if (contained.isEmpty()) return null
        return pick(close + contained).first
    }
}
