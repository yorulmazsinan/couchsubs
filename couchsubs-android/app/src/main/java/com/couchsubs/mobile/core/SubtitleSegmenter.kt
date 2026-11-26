// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Locale

/**
 * Altyazıyı modele cümle cümle verir; konuşmacı etiketi ("ATREUS:", "Kratos:") ve diyalog tirelerine dokunulmaz.
 * Mac'teki SubtitleSegmenter.swift ve Windows'taki SubtitleSegmenter.cs ile aynı kurallar.
 */
object SubtitleSegmenter {
    /** Çevrilecek bir parça ya da olduğu gibi kalacak ayraç/etiket. */
    data class Piece(val text: String, val translate: Boolean)

    // Etiket: satır ya da cümle başında, en çok üç sözcüklü ad ve iki nokta. Ya tümü büyük harf ("ATREUS:", "OLD MAN:")
    // ya da her sözcüğü büyük harfle başlayan ("Kratos:", "Mimir Head:").
    private val speakerLabel = Regex(
        "^(?<label>(?<name>\\p{Lu}[\\p{Lu}\\d'’.\\-]+(?:[ ]\\p{Lu}[\\p{Lu}\\d'’.\\-]*){0,2}|\\p{Lu}\\p{Ll}[\\p{L}'’.\\-]*(?:[ ]\\p{Lu}[\\p{L}'’.\\-]*){0,2}):)(?:\\s+|$)"
    )

    /** Büyük harfle başlayıp iki noktayla biten ama ad olmayan oyun başlıkları; bunlar çevrilir. */
    internal val notNames = setOf(
        "note", "warning", "tip", "hint", "objective", "objectives", "quest", "goal", "new", "reward", "rewards",
        "location", "chapter", "mission", "task", "tutorial", "update", "info", "status", "level", "controls",
        "press", "hold", "tap", "remember", "example", "question", "answer", "result", "results", "time",
        "listen", "look", "wait", "okay", "ok", "well", "so", "yes", "no", "now", "then", "and", "but",
    )

    private val dialogueDash = Regex("^(?<dash>[-–—]+)\\s*")
    // Cümle sonu: . ! ? … ardından isteğe bağlı kapanış tırnağı/parantez ve boşluk. Java'nın geriye bakışı sınırlı uzunluk
    // ister; sonlandırıcıdan sonraki kapanışlar için 10 karakter yeter (.NET'teki [.!?…]+[…]* ile aynı sonuç).
    private val sentenceGap = Regex("(?<=[.!?…][\"'”’)\\]]{0,10})\\s+")
    private val whitespace = Regex("\\s+")

    /** Noktadan sonra cümle bitmeyen kısaltmalar ("Mr. Smith"). */
    private val abbreviations = setOf(
        "mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "mt", "vs", "etc", "e.g", "i.e", "lt", "sgt", "capt", "gen", "col",
    )

    /** Satır başındaki konuşmacı etiketi; tek sözcüklü başlıklar ("Note:", "Objective:") ad sayılmaz. */
    private fun speakerLabel(text: String): MatchResult? {
        val match = speakerLabel.find(text) ?: return null
        val name = match.groups["name"]!!.value
        return if (!name.contains(' ') && name.lowercase(Locale.ROOT) in notNames) null else match
    }

    /** Etiket parçasındaki ad ("ATREUS: " → "ATREUS"); etiket değilse null. */
    fun labelName(piece: Piece): String? =
        if (!piece.translate && piece.text.endsWith(": ")) piece.text.dropLast(2) else null

    fun split(text: String): List<Piece> {
        val pieces = mutableListOf<Piece>()
        val block = StringBuilder()
        var pendingSeparator = ""
        fun flushBlock() {
            if (block.isEmpty()) return
            if (pendingSeparator.isNotEmpty()) pieces.add(Piece(pendingSeparator, false))
            addBlock(pieces, block.toString())
            block.clear()
            pendingSeparator = "\n"
        }
        for (raw in text.replace("\r\n", "\n").split('\n')) {
            val line = raw.trim()
            if (line.isEmpty()) continue
            // Etiketli ya da tireli satır yeni bir konuşmadır; diğer satırlar sarmadır, birleştirilir. Altyazı seçicinin
            // konuşan adı saydığı satır (SpeakerPrefix: "JASON : …", "Lucia：…") da yeni konuşmadır; aynı anda konuşan iki
            // kişinin satırı tek satıra birleşiyordu (beta.103 bildirimi; Windows, Mac ve iPhone aynı).
            if (speakerLabel(line) != null || SpeakerPrefix.split(line) != null || dialogueDash.containsMatchIn(line)) flushBlock()
            if (block.isNotEmpty()) block.append(' ')
            block.append(line)
        }
        flushBlock()
        return pieces
    }

    private fun addBlock(pieces: MutableList<Piece>, original: String) {
        var block = whitespace.replace(original, " ")
        dialogueDash.find(block)?.let { dash ->
            pieces.add(Piece(dash.groups["dash"]!!.value + " ", false))
            block = block.substring(dash.value.length)
        }
        var first = true
        for (sentence in splitSentences(block)) {
            if (!first) pieces.add(Piece(" ", false))
            first = false
            var body = sentence
            speakerLabel(body)?.let { label ->
                pieces.add(Piece(label.groups["label"]!!.value + " ", false))
                body = body.substring(label.value.length)
            }
            if (body.isNotEmpty()) pieces.add(Piece(body, body.any { it.isLetter() }))
        }
    }

    private fun splitSentences(block: String): List<String> {
        val result = mutableListOf<String>()
        var start = 0
        for (gap in sentenceGap.findAll(block)) {
            val candidate = block.substring(start, gap.range.first)
            val after = gap.range.last + 1
            val next = if (after < block.length) block[after] else '\u0000'
            // "wait... what" gibi küçük harfle süren yer ve kısaltmalar cümle sonu değildir.
            if (next.isLowerCase() || endsWithAbbreviation(candidate)) continue
            result.add(candidate)
            start = after
        }
        if (start < block.length) result.add(block.substring(start))
        return result
    }

    private fun endsWithAbbreviation(sentence: String): Boolean {
        if (!sentence.endsWith('.')) return false
        val word = sentence.substring(sentence.lastIndexOf(' ') + 1, sentence.length - 1)
        // Tek harf ad baş harfidir ("J. R. R.").
        return (word.length == 1 && word[0].isUpperCase()) || word.lowercase(Locale.ROOT) in abbreviations
    }

    /**
     * Tümü büyük harfli cümleyi ("THE GATE WILL NOT HOLD.") cümle düzenine çevirir; model büyük harfli sözcükleri ad
     * sanıp çevirmeden bırakıyordu. Bilinen adlar (konuşmacı etiketlerinden öğrenilen) büyük harfle başlar.
     */
    fun normalizeCase(sentence: String, names: Set<String> = emptySet()): String {
        var letters = 0
        for (c in sentence) {
            if (c.isLowerCase()) return sentence
            if (c.isLetter()) letters++
        }
        if (letters < 2 || !sentence.trim().contains(' ')) return sentence
        val output = StringBuilder(sentence.length)
        val word = StringBuilder()
        var startOfSentence = true
        fun flushWord() {
            if (word.isEmpty()) return
            val lower = word.toString().lowercase(Locale.ROOT)
            val capital = startOfSentence || lower == "i" || lower in names
            output.append(if (capital) lower[0].uppercaseChar() + lower.substring(1) else lower)
            startOfSentence = false
            word.clear()
        }
        for (c in sentence) {
            if (c.isLetter() || c == '\'' || c == '’') {
                word.append(c)
                continue
            }
            flushWord()
            if (c == '.' || c == '!' || c == '?' || c == '…') startOfSentence = true
            output.append(c)
        }
        flushWord()
        return output.toString()
    }
}

/**
 * Satırı oyun paketinde arar (Windows: PackLookup.cs, Mac: GamePacks.swift). Sırayla: satırın tamamı; konuşmacı
 * etiketi ya da diyalog tiresi varsa onsuz hâli (etiket çeviriye eklenir); birden çok satırsa her satır ayrı; birden çok
 * cümleyse her cümle ayrı. Parçalı aramada parçaların hepsi bulunmalıdır, yoksa satır motorla çevrilir. Tam anahtarla
 * hiçbir yol tutmazsa aynı sıra bir kez daha denenir; bu kez her parça önce tam, sonra `nearest` ile (OCR hatalarına
 * dayanıklı) aranır.
 */
object PackLookup {
    /**
     * Kütüphanedeki (açık) paketlerde arar (bulanık arama oynanan oyunun paketinde); sonuçta satırın son bulunan parçasının
     * paketi yazılır. Türkçe satır ([TurkishText.looksTurkish]) aranmaz: anahtarlar İngilizcedir. PS5'in Türkçe menü satırı
     * ("Yakin zamanda olu...") GTA 6 paketindeki bozuk bir parçayla tam eşleşiyor, oyun tanınmamışken "paket:gta-6" diye
     * gösteriliyor ve bulanık aramanın kapsamını o pakete kaydırıyordu (beta.89; Mac: GamePackLibrary.match, Windows:
     * PackLookup.Match).
     */
    fun match(library: GamePackLibrary, text: String): PackMatch? {
        if (TurkishText.looksTurkish(text)) return null
        var lastPack: String? = null
        // Aynı parça bir aramada birkaç yoldan sorulabilir (etiketli/etiketsiz gövde aynı); bulanık sonuç bir kez hesaplanır.
        val asked = HashMap<String, PackMatch?>()
        val nearest = { line: String ->
            val near = if (asked.containsKey(line)) asked[line] else library.nearestWithPack(line).also { asked[line] = it }
            near?.also { lastPack = it.packId }?.text
        }
        val found = match(text, nearest) { line -> library.findWithPack(line)?.also { lastPack = it.packId }?.text }
        return found?.copy(packId = lastPack)
    }

    /**
     * [find]: tek bir metnin (tamamının) paketteki Türkçesi. [nearest]: tam anahtar yoksa en benzer satırın Türkçesi
     * (bulanık arama); verilmezse yapılmaz.
     */
    fun match(text: String, nearest: ((String) -> String?)? = null, find: (String) -> String?): PackMatch? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        phase(trimmed, find)?.let { return it }
        if (nearest == null) return null
        return phase(trimmed) { line -> find(line) ?: nearest(line) }
    }

    private fun phase(trimmed: String, find: (String) -> String?): PackMatch? {
        single(trimmed, find)?.let { return result(it.first, it.second) }

        // Her satır ayrı bir altyazı olabilir (iki konuşmacı alt alta).
        val lines = trimmed.replace("\r\n", "\n").split('\n').map { it.trim() }.filter { it.isNotEmpty() }
        if (lines.size > 1) {
            val pieces = mutableListOf<SubtitleSegmenter.Piece>()
            val translations = mutableListOf<String?>()
            var all = true
            for (line in lines) {
                val found = single(line, find)
                if (found == null) {
                    // Altyazıyla aynı bloğa düşen köşe yazısı ("San Andreas", "First Person • zoom") atlanır.
                    if (isOverlay(line)) continue
                    all = false
                    break
                }
                if (pieces.isNotEmpty()) {
                    pieces.add(SubtitleSegmenter.Piece("\n", false))
                    translations.add(null)
                }
                pieces.addAll(found.first)
                translations.addAll(found.second)
            }
            if (all && pieces.isNotEmpty()) return result(pieces, translations)
        }

        // Cümle cümle (etiket, tire ve ayraçlar olduğu gibi kalır).
        val split = SubtitleSegmenter.split(trimmed)
        if (split.count { it.translate } <= 1) return null
        val sentences = ArrayList<String?>(split.size)
        for (piece in split) {
            if (!piece.translate) {
                sentences.add(null)
                continue
            }
            sentences.add(find(piece.text) ?: return null)
        }
        return result(split, sentences)
    }

    /**
     * Tek satır: başında konuşmacı etiketi ya da diyalog tiresi varsa ("- ENZO: ") önce onlarsız hâli (etiket/tire çeviriye
     * eklenir), sonra tamamı, sonra OCR'ın bozduğu etiketsiz hâli ([looseLabel]).
     */
    private fun single(line: String, find: (String) -> String?): Pair<List<SubtitleSegmenter.Piece>, List<String?>>? {
        val split = SubtitleSegmenter.split(line)
        val lead = split.takeWhile { !it.translate }
        if (lead.isNotEmpty() && lead.size < split.size && split.none { it.text == "\n" }) {
            val body = split.drop(lead.size).joinToString("") { it.text }
            find(body)?.let { turkish ->
                return (lead + SubtitleSegmenter.Piece(body, true)) to (List<String?>(lead.size) { null } + turkish)
            }
        }
        find(line)?.let { return listOf(SubtitleSegmenter.Piece(line, true)) to listOf(it) }
        val (label, body) = looseLabel(line) ?: return null
        val turkish = find(body) ?: return null
        return listOf(SubtitleSegmenter.Piece(label, false), SubtitleSegmenter.Piece(body, true)) to listOf(null, turkish)
    }

    /**
     * Altyazı olmayan köşe yazısı satırı: en çok dört sözcük; "•" içerir ("First Person • zoom") ya da noktalama yok ve
     * her sözcük büyük harfle başlar ("San Andreas", "Mirror Park", "LOSNN"). Yalnız başka satırlar pakette bulunduysa
     * atlanır. Uzun satırdaki "•" OCR lekesidir ("…with a colieague• Not that…"): o satır altyazıdır; atlanınca iki
     * satırlık altyazının yalnız ikinci satırının Türkçesi ("Seninle.") gösteriliyordu (#245).
     */
    fun isOverlay(line: String): Boolean {
        val words = PackFuzzy.words(line)
        if (words.isEmpty() || words.size > 4) return false
        if (line.contains('•')) return true
        return words.all { word -> Character.isUpperCase(word[0]) && word.all { PackFuzzy.isLetter(it) || PackFuzzy.isDigit(it) } }
    }

    /**
     * OCR'ın bozduğu konuşmacı etiketi: "-GAETANO:", "M]:", "li LUCA:", "MİNE GUARD•" (ilk 32 karakterde iki nokta ya da
     * • ve önündeki sözcükte küçük harf yok) ya da iki noktasız "SEBASTIAN Where…" (en çok üç büyük harfli sözcük, ardından
     * büyük harfle başlayan küçük harfli sözcük). (ekranda kalacak etiket, aranacak gövde) ya da null. Yalnız paket
     * aramasında yeniden deneme içindir.
     */
    fun looseLabel(line: String): Pair<String, String>? {
        val points = line.codePoints().toArray()
        fun text(start: Int, end: Int) = String(points, start, end - start)
        fun nameLike(token: IntArray, minimum: Int): Boolean {
            val letters = token.filter { PackFuzzy.isLetter(it) }
            return letters.size >= minimum && letters.none { Character.isLowerCase(it) }
        }
        fun isNumber(codePoint: Int) = when (Character.getType(codePoint).toByte()) {
            Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
            else -> false
        }
        for (index in 1 until minOf(points.size, 33)) {
            if (points[index] != ':'.code && points[index] != '•'.code) continue
            val last = PackFuzzy.words(text(0, index)).lastOrNull() ?: continue
            if (!nameLike(last, 1)) continue
            var start = index + 1
            while (start < points.size && !PackFuzzy.isLetter(points[start]) && !isNumber(points[start])) start++
            val body = text(start, points.size).trim()
            if (body.codePoints().noneMatch { PackFuzzy.isLetter(it) }) return null
            return text(0, index + 1).trim() + " " to body
        }
        var position = 0
        while (position < points.size && !PackFuzzy.isLetter(points[position])) position++
        repeat(3) {
            var end = position
            while (end < points.size && !PackFuzzy.isSpace(points[end])) end++
            if (end >= points.size || !Character.isUpperCase(points[position]) || !nameLike(points.copyOfRange(position, end), 2)) return null
            while (end < points.size && PackFuzzy.isSpace(points[end])) end++
            position = end
            if (position + 1 < points.size && Character.isUpperCase(points[position]) && Character.isLowerCase(points[position + 1])) {
                return text(0, position).trim() + " " to text(position, points.size).trim()
            }
        }
        return null
    }

    private fun result(pieces: List<SubtitleSegmenter.Piece>, translations: List<String?>): PackMatch =
        PackMatch(pieces.indices.joinToString("") { translations[it] ?: pieces[it].text })
}
