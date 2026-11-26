// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Yazı tanımanın bozduğu satır çeviri motoruna gitmez (GitHub #1293). Windows'un yazı tanıması güven değeri vermediği için
 * düşük güven süzgeci (#1370) orada hiç çalışmıyordu; paketteki satırlar düzgün çıkarken paket dışındaki satırlar bozuk
 * okunup ("es aepressea arter Donnıas aeatIT", "pop ılırıe man -ın DööStet Seat") Gemini'ye gidiyor, TV'de anlamsız
 * çeviriler beliriyordu. Bu süzgeç yalnız metne bakar; her okuyucuda (ML Kit, Vision, Windows, PaddleOCR) aynı çalışır.
 *
 * Sözcük başına işaretler: İngilizce satırda yalnız Türkçede olan harf (ı, ş, ğ), sözcük içinde tuhaf büyük-küçük harf
 * ("aeatIT", "DööStet"), harflerin arasına girmiş rakam ("b1r") ve ünlüsüz sözcük ("flnd"). Satır ancak en az üç
 * sözcüklüyse, en az iki sözcük bozuksa, harflerinin en az üçte biri bozuk sözcüklerdeyse ve sözcüklerinin yarısından
 * azı sık İngilizce sözcükse bozuk sayılır; yalnız Türkçe harf yetmez (en az bir başka işaret gerekir). Ayrıca sık sözcük
 * ve ünlem olmayan sözcüklerde ünlü oranı beşte birin altındaysa ("Gtt rnnk flvd brrt") bozuktur. Kısa satırlar
 * ("Yeah.", "What?"), BÜYÜK HARF bağırma, adlar ("McDonald", "PlayStation"), ünlemler ("Hmm", "Pfft", "Nnngh"), sayılar
 * ve sohbet kısaltmaları dokunulmaz kalır. Mac/iPhone (ReadPlausibility.swift) ve Windows (ReadPlausibility.cs) aynı kurallar.
 */
object ReadPlausibility {
    internal enum class Signal(val text: String) {
        TURKISH("İngilizce satırda Türkçe harf"),
        DIGIT("sözcük içinde rakam"),
        MIXED_CASE("karışık büyük-küçük harf"),
        VOWELLESS("ünlüsüz sözcük"),
        LOW_VOWELS("ünlü oranı çok düşük"),
    }

    /** Satırın bozuk sayılma nedeni (günlük için, Türkçe); düzgünse null. */
    fun reason(text: String): String? {
        val words = words(text)
        if (words.size < 3) return null
        if (TurkishText.looksTurkish(text)) return null
        var letters = 0
        var bad = 0
        var badWords = 0
        var known = 0
        var judgedLetters = 0
        var judgedVowels = 0
        val reasons = mutableListOf<Signal>()
        for (word in words) {
            val wordLetters = word.filter { it.isLetter() }
            letters += wordLetters.length
            if (isKnown(word)) {
                known++
                continue
            }
            signal(word)?.let { signal ->
                bad += wordLetters.length
                badWords++
                if (signal !in reasons) reasons.add(signal)
            }
            // Ünlü oranı: yalnız Latin harfli, BÜYÜK HARF olmayan, ünlem harflerinden oluşmayan sözcükler.
            if (wordLetters.all(::isLatin) && !wordLetters.all { it.isUpperCase() } &&
                !wordLetters.lowercase().all { it in GRUNT_LETTERS }) {
                judgedLetters += wordLetters.length
                judgedVowels += wordLetters.count { it in VOWELS }
            }
        }
        if (known * 2 >= words.size) return null
        if (judgedLetters >= 12 && judgedVowels * 5 < judgedLetters) return Signal.LOW_VOWELS.text
        if (badWords < 2 || bad * 3 < letters || reasons.none { it != Signal.TURKISH }) return null
        return reasons.joinToString(", ") { it.text }
    }

    /** Sözcüğün bozukluk işareti (null: düzgün ya da Latin harfli değil). */
    internal fun signal(word: String): Signal? {
        val stem = word.takeWhile { it != '\'' && it != '’' }
        val letters = stem.filter { it.isLetter() }
        if (letters.isEmpty() || !letters.all(::isLatin)) return null
        if (word.any { it in TURKISH_ONLY }) return Signal.TURKISH
        if (stem.any { it.isLowerCase() } && digitInside(stem)) return Signal.DIGIT
        if (stem.split('-').any { part -> oddCase(part.filter { it.isLetter() }) }) return Signal.MIXED_CASE
        val lower = letters.lowercase()
        if (letters.length >= 3 && !letters.all { it.isUpperCase() } && letters.none { it in VOWELS } &&
            collapsed(lower) !in INTERJECTIONS && !lower.all { it in GRUNT_LETTERS }) return Signal.VOWELLESS
        return null
    }

    /** Satırın sözcükleri: harf ve rakam dizileri; araya giren kesme ve tire sözcüğü bölmez ("don't", "Sh-sh-shut"). */
    internal fun words(text: String): List<String> {
        val result = mutableListOf<String>()
        val current = StringBuilder()
        for (i in text.indices) {
            val c = text[i]
            if (c.isLetterOrDigit()) {
                current.append(c)
            } else if ((c == '\'' || c == '’' || c == '-') && current.isNotEmpty() && i + 1 < text.length && text[i + 1].isLetterOrDigit()) {
                current.append(c)
            } else if (current.isNotEmpty()) {
                result.add(current.toString())
                current.clear()
            }
        }
        if (current.isNotEmpty()) result.add(current.toString())
        return result.filter { word -> word.any { it.isLetter() } }
    }

    private fun isKnown(word: String): Boolean {
        val key = word.lowercase().replace('’', '\'')
        return key in COMMON || key in CHAT
    }

    /** Harf Latin alfabesinden mi (ASCII ya da U+00C0–U+024F). Başka yazıların (tam genişlik, Kiril, Japonca) sözcükleri yargılanmaz. */
    private fun isLatin(c: Char): Boolean = c.code < 0x80 || c.code in 0xC0..0x24F

    /** "b1r", "h3p": küçük harfli sözcükte harflerin arasına rakam girmiş. "PS5", "M4A1", "2nd", "100m" sayılmaz. */
    private fun digitInside(stem: String): Boolean {
        var i = 1
        while (i < stem.length) {
            if (stem[i].isDigit() && stem[i - 1].isLetter()) {
                var end = i
                while (end < stem.length && stem[end].isDigit()) end++
                if (end < stem.length && stem[end].isLetter()) return true
                i = end
            } else {
                i++
            }
        }
        return false
    }

    /**
     * Tuhaf büyük-küçük harf. ASCII sözcükte yalnız en az üç küçük harfle başlayıp sonra büyük harf taşıyan ("aeatIT");
     * "McDonald", "PlayStation", "iPhone", "eBay", "WebRTC" olağan. ASCII dışı harfli sözcükte baştaki dışında her büyük
     * harf ("DööStet"); tümü büyük harf olağan.
     */
    private fun oddCase(letters: String): Boolean {
        if (letters.length < 2 || letters.all { it.isUpperCase() } || letters.drop(1).all { it.isLowerCase() }) return false
        if (letters.all { it.code < 0x80 }) return letters.takeWhile { it.isLowerCase() }.length > 2
        return true
    }

    private fun collapsed(text: String): String {
        val result = StringBuilder()
        for (c in text) if (result.isEmpty() || result.last() != c) result.append(c)
        return result.toString()
    }

    private val VOWELS = "aeiouyäöüıàáâãåæèéêëìíîïòóôõøùúûýÿAEIOUYÄÖÜİÀÁÂÃÅÆÈÉÊËÌÍÎÏÒÓÔÕØÙÚÛÝ".toSet()
    private val TURKISH_ONLY = setOf('ı', 'İ', 'ş', 'Ş', 'ğ', 'Ğ')
    /** Ünlüsüz ama gerçek ünlemler (art arda tekrarlar tek harf sayılır; [OcrNoise] ile aynı). */
    private val INTERJECTIONS = setOf("hm", "m", "sh", "br", "gr", "pst", "pft", "tsk", "hrm", "z", "pht")
    /** Yalnız bu harflerden oluşan ünlüsüz sözcük inilti ya da ünlemdir ("Nnngh", "Hnnng", "Grrr", "Pfft"). */
    private val GRUNT_LETTERS = "hmngrszpfbt".toSet()

    /** Sohbet ve argo kısaltmaları (ünlüsüz olsalar da sözcüktür). */
    internal val CHAT = setOf(
        "thx", "pls", "plz", "omg", "lol", "lmao", "brb", "ttyl", "idk", "wtf", "smh", "tbh", "btw", "ppl", "msg", "txt",
        "bro", "ya", "u", "ur", "r", "k", "kk", "nvm", "rn", "wyd", "hmu", "gtg", "ty", "np", "yo", "sry", "tho", "cuz",
        "gonna", "wanna", "gotta", "dunno", "ain't", "y'all", "c'mon", "nah", "yep", "nope", "dude", "mr", "mrs", "ms", "dr",
    )

    /** En sık İngilizce sözcükler (konuşma dili ağırlıklı). Satırın yarısı bunlardansa satır bozuk sayılmaz. */
    internal val COMMON = setOf(
        "a", "about", "above", "after", "again", "against", "all", "almost", "alone", "along", "already", "also", "always",
        "am", "an", "and", "another", "any", "anyone", "anything", "are", "around", "as", "ask", "at", "away", "back", "bad",
        "be", "because", "been", "before", "behind", "being", "believe", "best", "better", "between", "big", "both", "boy",
        "bring", "but", "buy", "by", "call", "came", "can", "can't", "car", "check", "come", "cops", "could", "couldn't",
        "dad", "day", "dead", "did", "didn't", "die", "do", "does", "doesn't", "dog", "don't", "done", "door", "down",
        "drive", "each", "else", "end", "enough", "even", "ever", "every", "everyone", "everything", "eye", "face", "fact",
        "far", "feel", "few", "find", "fine", "first", "for", "found", "friend", "from", "fuck", "fucking", "get", "gets",
        "girl", "give", "go", "god", "going", "gone", "good", "got", "great", "guy", "guys", "had", "has", "hate", "have",
        "haven't", "he", "he's", "head", "hear", "hell", "help", "her", "here", "hey", "him", "his", "hold", "home", "hope",
        "house", "how", "i", "i'd", "i'll", "i'm", "i've", "if", "in", "inside", "into", "is", "isn't", "it", "it's", "job",
        "just", "keep", "kill", "kind", "know", "last", "leave", "left", "let", "let's", "life", "like", "listen", "little",
        "long", "look", "lot", "love", "made", "make", "man", "many", "may", "me", "mean", "men", "might", "mind", "miss",
        "mom", "money", "more", "most", "move", "much", "must", "my", "name", "need", "never", "new", "next", "nice",
        "night", "no", "not", "nothing", "now", "of", "off", "oh", "ok", "okay", "old", "on", "once", "one", "only", "or",
        "other", "our", "out", "over", "own", "people", "place", "play", "please", "police", "put", "real", "really",
        "right", "run", "said", "same", "saw", "say", "see", "seen", "she", "shit", "should", "show", "shut", "since", "so",
        "some", "someone", "something", "sorry", "still", "stop", "sure", "take", "talk", "tell", "than", "thank", "thanks",
        "that", "that's", "the", "their", "them", "then", "there", "there's", "these", "they", "they're", "thing", "think",
        "this", "those", "though", "thought", "through", "time", "to", "today", "together", "told", "tonight", "too", "took",
        "town", "try", "trying", "two", "up", "us", "use", "very", "wait", "want", "wanted", "was", "wasn't", "watch",
        "way", "we", "we're", "well", "went", "were", "what", "what's", "when", "where", "which", "while", "who", "why",
        "will", "with", "without", "won't", "work", "world", "would", "wouldn't", "yeah", "yes", "yet", "you", "you're",
        "your", "yourself",
    )

    /**
     * Bozuk satırın günlük satırı, seyreltilmiş: aynı metin [REPEAT_MS] içinde yeniden yazılmaz, bir dakikada en çok
     * [PER_MINUTE] satır (aşanlar sayılıp sonraki satırda bildirilir). Satır ekranda kaldıkça her karede yeniden okunur;
     * günlük her karede dolmasın.
     */
    class Log(private val clock: () -> Long = monotonicClock) {
        private val seen = HashMap<String, Long>()
        private var windowStart: Long? = null
        private var written = 0
        private var suppressed = 0

        /** Yazılacak satır; aynı metin yakın zamanda yazıldıysa ya da dakikalık sınır dolduysa null. */
        @Synchronized
        fun line(text: String, reason: String): String? {
            val excerpt = excerpt(text)
            val time = clock()
            seen[excerpt]?.let { if (time - it < REPEAT_MS) return null }
            val start = windowStart
            if (start != null && time - start < 60_000) {
                if (written >= PER_MINUTE) {
                    suppressed++
                    return null
                }
            } else {
                windowStart = time
                written = 0
            }
            written++
            seen[excerpt] = time
            if (seen.size > 128) seen.entries.removeAll { time - it.value >= REPEAT_MS }
            var line = "okuma bozuk görünüyor, çeviriye gönderilmedi: «$excerpt» ($reason)"
            if (suppressed > 0) {
                line += " (+$suppressed satır sınır yüzünden yazılmadı)"
                suppressed = 0
            }
            return line
        }

        companion object {
            const val REPEAT_MS = 60_000L
            const val PER_MINUTE = 10
            internal const val EXCERPT_LENGTH = 80

            internal fun excerpt(text: String): String {
                val flat = text.split('\n', '\r').map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" / ")
                return if (flat.length > EXCERPT_LENGTH) flat.take(EXCERPT_LENGTH - 1) + "…" else flat
            }
        }
    }
}
