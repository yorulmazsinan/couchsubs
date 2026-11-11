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

    fun clean(line: String): String {
        val kept = mutableListOf<String>()
        val tokens = line.split(Regex("\\s+")).filter { it.isNotEmpty() }
        for ((index, token) in tokens.withIndex()) {
            val (lead, core, trail) = split(token)
            // Tek başına "l" ya da "|" çoğu zaman yanlış okunmuş "I"dır; ardından küçük harfle süren sözcük gelmiyorsa
            // altyazı kutusunun kenarıdır ("| Get in the car."), atılır.
            val pronoun = misreadI(core)
            if (pronoun != null) {
                val next = if (index + 1 < tokens.size) tokens[index + 1].firstOrNull { it.isLetter() } ?: '\u0000' else '\u0000'
                if (pronoun != "I" || next.isLowerCase()) kept.add(lead + pronoun + trail)
                continue
            }
            // Yalnız "?!", ".", "," gibi işaretlerden oluşan parça: satır başında ya da cümle bittikten sonra yazı tanımanın
            // uydurmasıdır; sözcükten ayrı düşmüşse sözcüğe yapışır ("going ?!").
            if (core.isEmpty() && isStrayPunctuation(token)) {
                if (kept.isNotEmpty() && kept.last().last() !in ".?!…,;:") kept[kept.size - 1] = kept.last() + token
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
            val letters = core.count { it.isLetter() }
            if (letters == 0) continue
            val clean = cleanCore(core) == core && normalCase(core) && core.none { it in "[]()" }
            score += if (clean) letters else -2 * letters
        }
        return score
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
