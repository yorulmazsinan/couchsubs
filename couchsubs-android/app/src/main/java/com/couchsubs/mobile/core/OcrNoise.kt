// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Süslü yazı tiplerinde, solan ya da titreyen altyazıda yazı tanıma bazı sözcükleri harf, rakam ve simge karışımı
 * çöpe çevirir ("ou$3e", "waters2aljd"). Sözcük ortasında simge ya da harflerle rakamların iç içe geçtiği parçalar
 * atılır; gerçek bir sözcüğe yapışmış çöp sözcükten ayrılır. "PS5", "R2", "2nd", "100m", "$500" gibi olağan biçimler
 * korunur (Mac ve Windows'taki OcrNoise ile aynı kurallar).
 */
object OcrNoise {
    private const val SYMBOLS = "$@#%^*_=|\\~<>{}¢£¥§©®°±µ¶¤"
    private val leadingNumber = Regex("^\\d+(?:m|km|ft|yd)?[.?!:;]?$")
    private val usual = Regex(
        "^(?:[A-Za-z]{1,4}\\d{1,4}|\\d+(?:st|nd|rd|th|s|k|K|m|km|kg|cm|mm|p|x|fps|hp|HP|XP|xp|v|V|D|d)|[xX]\\d{1,3}|\\d+[.,]\\d+[A-Za-z]{0,3}|\\d{1,2}[:.]\\d{2}(?:am|pm|AM|PM)?)$"
    )

    /** [keepIdentifiers]: oyun telefonundaki kullanıcı adı ve etiketler ("@vice.305", "#NightRide", "2gether") çöp sayılmaz. */
    fun clean(line: String, keepIdentifiers: Boolean = false): String {
        val kept = mutableListOf<String>()
        val tokens = line.split(Regex("\\s+")).filter { it.isNotEmpty() }
        for ((index, token) in tokens.withIndex()) {
            // Kumanda simgesinin yeri (ButtonIcons.MARKER) çöp değildir.
            if (token[0] == ButtonIcons.MARKER ||
                (keepIdentifiers && (GamePhoneText.containsIdentifier(token) || GamePhoneText.isWrittenChatWord(token)))) {
                kept.add(token)
                continue
            }
            val (lead, core, trail) = split(token)
            // Tek başına "l" ya da "|" çoğu zaman yanlış okunmuş "I"dır; ardından küçük harfle başlayan sözcük yoksa
            // ve token ?/! ile bitmiyorsa altyazı kutusunun kenarı olabilir.
            val pronoun = misreadI(core)
            if (pronoun != null) {
                val next = if (index + 1 < tokens.size) tokens[index + 1].firstOrNull { it.isLetter() } ?: '\u0000' else '\u0000'
                val endsQuestionOrExclamation = trail.any { it == '?' || it == '!' }
                if (pronoun != "I" || next.isLowerCase() || endsQuestionOrExclamation) kept.add(lead + pronoun + trail)
                continue
            }
            // Yalnız "?!", ".", "," gibi işaretlerden oluşan parça: satır başında ya da cümle bittikten sonra yazı tanımanın
            // uydurmasıdır; sözcükten ayrı düşmüşse sözcüğe yapışır ("going ?!").
            if (core.isEmpty() && isStrayPunctuation(token)) {
                if (kept.isNotEmpty() && kept.last().last() !in ".?!…,;:") kept[kept.size - 1] = kept.last() + token
                continue
            }
            // Harfsiz, rakamsız ve yalnız simgeden oluşan parça ("_", "~", "=") yazı tanımanın uydurmasıdır: renkli
            // sözcüğün açık zeminde kaybolan harfleri "_" okunuyordu ("Get in the _ eedboat", GitHub #854, GTA 6).
            if (isSymbolOnly(core)) {
                if (trail.isNotEmpty() && kept.isNotEmpty()) kept[kept.size - 1] = kept.last() + trail
                continue
            }
            val fixed = cleanCore(core)
            if (fixed != null) kept.add(lead + fixed + trail)
            // Atılan çöpün ardındaki noktalama cümleye aittir ("ou$3e," → virgül kalır).
            else if (trail.isNotEmpty() && kept.isNotEmpty()) kept[kept.size - 1] = kept.last() + trail
        }
        // Altyazının yanındaki göstergenin sayısı satırın başına yapışıyor ("9? We'll lose", "23m CESARE: Here!").
        if (kept.size >= 3 && leadingNumber.matches(kept[0]) && kept[1][0].isUpperCase()) kept.removeAt(0)
        return kept.joinToString(" ")
    }

    /** Bir okumanın ne kadar sözcük gibi göründüğü; aynı karenin iki okumasından iyisini seçmek için. */
    fun score(text: String): Int {
        var score = 0
        for (token in text.split(Regex("\\s+")).filter { it.isNotEmpty() }) {
            val core = split(token).second
            val letters = core.filter { it.isLetter() }
            if (letters.isEmpty()) continue
            val clean = cleanCore(core) == core && normalCase(core) && core.none { it in "[]()" } && !vowelless(letters)
            score += if (clean) letters.length else -2 * letters.length
        }
        return score
    }

    /**
     * Okuma çöp gibi mi: harflerinin altıda birinden çoğu bozuk sözcüklerde (karışık büyük-küçük harf, simge, ünlüsüz
     * "Gtt"). Altyazılar geçişte birbirinin üstüne solarken yazı tanıma iki satırı karıştırıp noktayla biten bir çöp
     * okuyabiliyor ("Gtt solkolfege."); nokta yüzünden ilk karede çevrilmesin (Mac: OcrNoise.looksGarbled).
     */
    fun looksGarbled(text: String): Boolean {
        var good = 0
        var bad = 0
        for (token in text.split(Regex("\\s+")).filter { it.isNotEmpty() }) {
            val core = split(token).second
            val letters = core.filter { it.isLetter() }
            if (letters.isEmpty()) continue
            val clean = cleanCore(core) == core && normalCase(core) && core.none { it in "[]()" } && !vowelless(letters)
            if (clean) good += letters.length else bad += letters.length
        }
        return bad * 6 > good + bad
    }

    /** Parça yalnız simgelerden mi oluşuyor (harf ve rakam yok, en az bir [SYMBOLS] imi). */
    private fun isSymbolOnly(core: String) =
        core.isNotEmpty() && core.none { it.isLetter() || TextMatch.isNumber(it) } && core.any { it in SYMBOLS }

    /**
     * Satır bir okuma kırıntısı mı: altyazı ya da görev değil, ekrandaki küçük bir göstergenin ya da solan satırın yazı
     * tanımadan kalan parçası ("one ready.", "ar.", "kulak"). En çok üç sözcüklü ve küçük harfle (ya da harf dışı bir
     * imle) başlayan, ya da hiç gerçek sözcük (en az iki harfli, ünlü taşıyan) taşımayan, ya da çöp gibi okunan satır.
     * Büyük harfle başlayan kısa konuşma ("Go!", "Okay.") kırıntı değildir. Kırıntı yanındaki uzun konuşmayı "eski"
     * gösterip altyazıdan attırmaz, görev satırı da sayılmaz ([StickyRows], [MissionLine]; GitHub #854, #882).
     * Mac/iPhone (OcrNoise.isCrumb) ve Windows (OcrNoise.IsCrumb) aynı kuralı uygular.
     */
    fun isCrumb(text: String): Boolean {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return true
        if (looksGarbled(trimmed)) return true
        val words = trimmed.split(Regex("\\s+")).filter { word -> word.any { it.isLetter() } }
        if (words.size > 3) return false
        val first = trimmed.firstOrNull { it.isLetter() || TextMatch.isNumber(it) }
        if (first != null && !(first.isLetter() && first.isUpperCase())) return true
        return words.none { word ->
            val letters = word.filter { it.isLetter() }.lowercase()
            letters.length >= 2 && letters.any { it in "aeiouyäöüıàáâèéêìíîòóôùúû" }
        }
    }

    /**
     * Sözcük (harfleri) İngilizcede bir sözcük olamaz: ünlüsüz ([vowelless]), İngilizcede hiç yan yana gelmeyen iki harf
     * taşıyor ("ijz": "jz") ya da harf-rakam/simge karışık. Yalnız aynı satırın iki okumasından hangisinin bozuk olduğuna
     * karar verirken kullanılır ([SubtitleStabilizer]); tek başına satır atmaz.
     */
    fun isNonWord(word: String): Boolean {
        val core = split(word).second
        val letters = core.filter { it.isLetter() }
        if (letters.length < 2) return false
        if (cleanCore(core) != core || vowelless(letters)) return true
        return letters.lowercase().zipWithNext { a, b -> "$a$b" }.any { it in impossiblePairs }
    }

    /** İngilizce sözcüklerde yan yana gelmeyen harf çiftleri (yazı tanımanın "lives" → "Ijz" gibi uydurmalarında çıkar). */
    private val impossiblePairs = setOf(
        "bx", "cj", "cv", "cx", "dx", "fq", "fx", "gq", "gx", "hx", "jc", "jf", "jg", "jq", "js", "jv", "jw", "jx", "jz",
        "kq", "kx", "mx", "px", "pz", "qb", "qc", "qd", "qf", "qg", "qh", "qj", "qk", "ql", "qm", "qn", "qp", "qr", "qs",
        "qt", "qv", "qw", "qx", "qy", "qz", "sx", "vb", "vf", "vh", "vj", "vm", "vp", "vq", "vw", "vx", "wx", "xj", "xx",
        "zj", "zq", "zx",
    )

    /** Üç ve daha çok harfli, ünlüsüz ve kısaltma olmayan (tümü büyük harf değil) sözcük: İngilizcede olmaz ("Gtt", "rnnk"). */
    private fun vowelless(letters: String): Boolean =
        letters.length >= 3 && !letters.all { it.isUpperCase() } && letters.lowercase().none { it in "aeiouyäöüıàáâèéêìíîòóôùúû" } &&
            collapsed(letters.lowercase()) !in interjections

    /** Ünlüsüz ama gerçek ünlemler ("Hmm", "Shh", "Brr", "Grr", "Psst", "Pfft", "Mmm", "Zzz", "Tsk"); art arda tekrarlar tek harf sayılır. */
    private val interjections = setOf("hm", "m", "sh", "br", "gr", "pst", "pft", "tsk", "hrm", "z", "pht")

    private fun collapsed(text: String): String {
        val result = StringBuilder()
        for (character in text) if (result.isEmpty() || result.last() != character) result.append(character)
        return result.toString()
    }

    private fun normalCase(core: String): Boolean {
        val letters = core.filter { it.isLetter() }
        if (letters.all { it.isUpperCase() } || letters.drop(1).all { it.isLowerCase() }) return true
        return letters.drop(1).count { it.isUpperCase() } == 1 && letters.count { it.isLowerCase() } >= 2
    }

    /** "l", "|", "l'm", "|'ll" → "I", "I'm", "I'll" (null: böyle bir okuma değil). */
    private fun misreadI(core: String): String? {
        if (core.isEmpty() || (core[0] != 'l' && core[0] != '|')) return null
        if (core.length == 1) return "I"
        if ((core[1] != '\'' && core[1] != '’') || core.substring(2) !in setOf("m", "ll", "ve", "d")) return null
        return "I" + core.substring(1)
    }

    /** Yalnız ? ! . , ; : işaretlerinden oluşan parça; üç nokta ("...") gerçek noktalamadır. */
    private fun isStrayPunctuation(token: String) =
        token.isNotEmpty() && token.all { it in "?!.,;:" } && !(token.length >= 2 && token.all { it == '.' })

    /** Sözcüğün kendisi; null ise tamamen çöptür. */
    private fun cleanCore(core: String): String? {
        val letters = core.count { it.isLetter() }
        val digits = core.count(TextMatch::isNumber)
        val hasSymbol = core.any { it in SYMBOLS }
        if (letters == 0) return core
        if (!hasSymbol && digits == 0) return core
        if (!hasSymbol && isUsualMix(core)) return core
        // Gerçek sözcüğe yapışmış çöp: baştaki en az 3 harf korunur ("waters2aljd" → "waters").
        val prefix = core.takeWhile { it.isLetter() || it == '\'' || it == '’' || it == '-' }
        return if (prefix.count { it.isLetter() } >= 3) prefix else null
    }

    private fun isUsualMix(core: String) = core.split('-').all { part -> part.none(TextMatch::isNumber) || usual.matches(part) }

    /** .NET'teki char.IsPunctuation / char.IsSymbol. */
    private fun isEdge(c: Char): Boolean {
        if (c in SYMBOLS) return false
        val type = Character.getType(c).toByte()
        val punctuation = type == Character.CONNECTOR_PUNCTUATION || type == Character.DASH_PUNCTUATION ||
            type == Character.START_PUNCTUATION || type == Character.END_PUNCTUATION ||
            type == Character.INITIAL_QUOTE_PUNCTUATION || type == Character.FINAL_QUOTE_PUNCTUATION ||
            type == Character.OTHER_PUNCTUATION
        val symbol = type == Character.MATH_SYMBOL || type == Character.CURRENCY_SYMBOL ||
            type == Character.MODIFIER_SYMBOL || type == Character.OTHER_SYMBOL
        return punctuation || symbol || c in "\"'“”‘’«»()[]"
    }

    private fun split(token: String): Triple<String, String, String> {
        var start = 0
        var end = token.length
        while (start < end && isEdge(token[start])) start++
        while (end > start && isEdge(token[end - 1])) end--
        return Triple(token.substring(0, start), token.substring(start, end), token.substring(end))
    }
}
