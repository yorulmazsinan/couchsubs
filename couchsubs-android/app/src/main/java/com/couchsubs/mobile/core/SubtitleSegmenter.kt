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
        "^(?<label>(?<name>\\p{Lu}[\\p{Lu}\\d'’.\\-]+(?:[ ]\\p{Lu}[\\p{Lu}\\d'’.\\-]*){0,2}|\\p{Lu}\\p{Ll}[\\p{L}'’.\\-]*(?:[ ]\\p{Lu}[\\p{L}'’.\\-]*){0,2}):)\\s+"
    )

    /** Büyük harfle başlayıp iki noktayla biten ama ad olmayan oyun başlıkları; bunlar çevrilir. */
    private val notNames = setOf(
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
            // Etiketli ya da tireli satır yeni bir konuşmadır; diğer satırlar sarmadır, birleştirilir.
            if (speakerLabel(line) != null || dialogueDash.containsMatchIn(line)) flushBlock()
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
 * cümleyse her cümle ayrı. Parçalı aramada parçaların hepsi bulunmalıdır, yoksa satır motorla çevrilir.
 */
object PackLookup {
    /** Kütüphanedeki (açık) paketlerde arar; sonuçta satırın son bulunan parçasının paketi yazılır. */
    fun match(library: GamePackLibrary, text: String): PackMatch? {
        var lastPack: String? = null
        val found = match(text) { line -> library.findWithPack(line)?.also { lastPack = it.packId }?.text }
        return found?.copy(packId = lastPack)
    }

    /** [find]: tek bir metnin (tamamının) paketteki Türkçesi. */
    fun match(text: String, find: (String) -> String?): PackMatch? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
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
            if (all) return result(pieces, translations)
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

    /** Tek satır: başında konuşmacı etiketi ya da diyalog tiresi varsa önce onsuz hâli, sonra tamamı. */
    private fun single(line: String, find: (String) -> String?): Pair<List<SubtitleSegmenter.Piece>, List<String?>>? {
        val split = SubtitleSegmenter.split(line)
        if (split.size > 1 && !split[0].translate && split.none { it.text == "\n" }) {
            val body = split.drop(1).joinToString("") { it.text }
            find(body)?.let { turkish ->
                return listOf(split[0], SubtitleSegmenter.Piece(body, true)) to listOf(null, turkish)
            }
        }
        val whole = find(line) ?: return null
        return listOf(SubtitleSegmenter.Piece(line, true)) to listOf(whole)
    }

    private fun result(pieces: List<SubtitleSegmenter.Piece>, translations: List<String?>): PackMatch =
        PackMatch(pieces.indices.joinToString("") { translations[it] ?: pieces[it].text })
}
