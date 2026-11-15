// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.translation

import com.couchsubs.mobile.core.SubtitleSegmenter
import com.couchsubs.mobile.core.TextTranslator
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.Locale

private val turkish = Locale("tr", "TR")

/**
 * Çevrilmiş satır ve cümlelerin kalıcı önbelleği (Mac/iPhone ve Windows'taki `TranslationCache` ile aynı dosya biçimi).
 * Oyunlar aynı satırları oturumdan oturuma tekrarlar; diskte duran çeviri 0 ms sürer, çevrimiçi kotadan da yemez. Her
 * motor ve dil çifti kendi dosyasını kullanır: motor değişince eski motorun çevirisi gösterilmez.
 *
 * Dosya her satırı bir JSON dizisi (`["kaynak","çeviri"]`) olan, sonuna eklenen bir kayıttır. Bellekte en çok [limit]
 * kayıt tutulur; en uzun süredir kullanılmayanlar atılır. Dosya kayıt sınırının iki katına uzayınca bellektekilerle
 * yeniden yazılır. Disk hatası çeviriyi durdurmaz: önbellek o zaman yalnız bellekte çalışır.
 */
class TranslationCache(private val file: File? = null, limit: Int = DEFAULT_LIMIT) {
    companion object {
        const val DEFAULT_LIMIT = 20_000
        /** Dosya adındaki biçim sürümü. */
        const val FORMAT_VERSION = 1

        /** Motor ve dil çiftine göre dosya: `v1-mlkit_p2-en-tr.jsonl`. */
        fun file(directory: File, engine: String, source: String, target: String): File =
            File(directory, listOf("v$FORMAT_VERSION", engine, source, target).joinToString("-") { safe(it) } + ".jsonl")

        private val opened = mutableMapOf<String, TranslationCache>()

        /** Aynı dosya için hep aynı önbellek döner; çevirmen her oturumda yeniden kurulsa da dosya bir kez okunur. */
        fun shared(directory: File, engine: String, source: String = "en", target: String = "tr"): TranslationCache {
            val path = file(directory, engine, source, target)
            return synchronized(opened) { opened.getOrPut(path.absolutePath) { TranslationCache(path) } }
        }

        private fun safe(part: String) = part.map { if (it.isLetterOrDigit() || it == '_') it else '_' }.joinToString("")

        private fun line(key: String, value: String): String = JSONArray().put(key).put(value).toString() + "\n"
    }

    private val limit = maxOf(1, limit)
    private val entries = HashMap<String, Pair<String, Long>>()
    private var tick = 0L
    private var loaded = false
    /** Dosyadaki satır sayısı (yinelenenler ve atılanlar dahil). */
    private var fileLines = 0

    val count: Int get() = synchronized(this) { loadIfNeeded(); entries.size }

    fun get(key: String): String? = synchronized(this) {
        loadIfNeeded()
        val entry = entries[key] ?: return null
        entries[key] = entry.first to ++tick
        entry.first
    }

    fun store(key: String, value: String) {
        if (key.isEmpty() || value.isEmpty()) return
        synchronized(this) {
            loadIfNeeded()
            val same = entries[key]?.first == value
            entries[key] = value to ++tick
            if (same) return
            evictIfNeeded()
            append(key, value)
        }
    }

    /** Dosyayı ilk kullanımda okur (çeviri iş parçacığında; arayüzü bekletmez). */
    private fun loadIfNeeded() {
        if (loaded) return
        loaded = true
        val file = file ?: return
        val lines = try {
            if (!file.exists()) return
            file.readLines(Charsets.UTF_8)
        } catch (error: IOException) {
            return
        }
        for (line in lines) {
            if (line.isEmpty()) continue
            fileLines++
            try {
                val pair = JSONArray(line)
                if (pair.length() != 2) continue
                val key = pair.optString(0)
                val value = pair.optString(1)
                if (key.isEmpty() || value.isEmpty()) continue
                entries[key] = value to ++tick
            } catch (error: JSONException) {
                // Yarım yazılmış satır atlanır.
            }
        }
        evictIfNeeded()
        if (fileLines > entries.size + limit / 2) rewrite()
    }

    private fun evictIfNeeded() {
        if (entries.size <= limit) return
        // Her seferinde tek kayıt atmak yerine onda biri atılır; sıralama seyrek yapılır.
        val drop = entries.size - limit + limit / 10
        entries.entries.sortedBy { it.value.second }.take(drop).map { it.key }.forEach { entries.remove(it) }
    }

    private fun append(key: String, value: String) {
        val file = file ?: return
        if (fileLines >= limit * 2) return rewrite()
        try {
            file.parentFile?.mkdirs()
            file.appendText(line(key, value), Charsets.UTF_8)
            fileLines++
        } catch (error: IOException) {
            // Disk dolu ya da yazılamıyor: önbellek bellekte çalışmaya devam eder.
        }
    }

    /** Dosyayı bellektekilerle, en eski kullanılandan yeniye doğru yeniden yazar. */
    private fun rewrite() {
        val file = file ?: return
        try {
            file.parentFile?.mkdirs()
            val temporary = File(file.parentFile, file.name + ".tmp")
            temporary.bufferedWriter(Charsets.UTF_8).use { out ->
                for ((key, entry) in entries.entries.sortedBy { it.value.second }) out.write(line(key, entry.first))
            }
            if (!temporary.renameTo(file)) {
                file.delete()
                temporary.renameTo(file)
            }
            fileLines = entries.size
        } catch (error: IOException) {
            // Yazılamadıysa eski dosya yerinde kalır.
        }
    }
}

/**
 * Ücretsiz çevirinin terim sözlüğü (Mac/iPhone: Glossary.swift, Windows: Glossary.cs; aynı biçim ve kurallar). Dosya:
 * `{ "game": "God of War", "terms": { "Leviathan Axe": "Leviathan Baltası" }, "keep": ["Kratos"], "keepExact": ["Soul"] }`.
 * `terms` İngilizce terimi verilen Türkçeyle değiştirir, `keep` adları olduğu gibi bırakır; `keepExact` adları yalnız
 * yazıldığı gibi (büyük/küçük harf aynı) geçince bırakır. Eşleşme büyük/küçük harfe bakmaz, yalnız tam sözcüklerde olur,
 * uzun terim önce gelir. Uygulamayla gelen genel sözlüğün üstüne `files/glossary/*.json` dosyaları eklenir.
 */
class Glossary private constructor(private val terms: Map<String, Term>) {
    /** Metinde bulunan terim: konumu (UTF-16), sözlükteki İngilizcesi ve Türkçesi. */
    data class TermMatch(val start: Int, val length: Int, val english: String, val turkish: String)

    internal data class Term(val english: String, val turkish: String, val exact: Boolean)

    /** Uzundan kısaya terimler; arama bu sırayla yapılır. */
    private val ordered: List<Term> = terms.values.sortedWith(compareByDescending<Term> { it.english.length }.thenBy { it.english })

    /** Büyük harfle kalması gereken sözcükler (küçük harfle); `normalizeCase`'e ad olarak verilir. */
    val capitalWords: Set<String> = buildSet {
        // `keepExact` adları sıradan sözcük de olduğundan büyük harfe çevrilmez.
        for (term in ordered) if (!term.exact && term.english.any { it.isUpperCase() })
            for (word in term.english.split(' ')) if (word.length >= 2) add(word.lowercase(Locale.ROOT))
    }

    /** Sözlüğün içeriğinden kısa bir iz; terim içeren satırların önbellek anahtarına girer. */
    val fingerprint: String = makeFingerprint(ordered)

    val size: Int get() = terms.size
    val isEmpty: Boolean get() = terms.isEmpty()

    companion object {
        val Empty = Glossary(emptyMap())

        fun parse(json: String): Glossary {
            val root = JSONObject(json)
            val terms = mutableMapOf<String, Term>()
            root.optJSONObject("terms")?.let { map ->
                // Sözlük sırası JSON'da tanımsız; aynı sonucu vermek için anahtar sırasıyla eklenir.
                for (key in map.keys().asSequence().sorted()) (map.opt(key) as? String)?.let { add(terms, key, it) }
            }
            root.optJSONArray("keep")?.let { list -> for (i in 0 until list.length()) (list.opt(i) as? String)?.let { add(terms, it, it) } }
            root.optJSONArray("keepExact")?.let { list ->
                for (i in 0 until list.length()) (list.opt(i) as? String)?.let { add(terms, it, it, exact = true) }
            }
            return Glossary(terms)
        }

        private fun add(terms: MutableMap<String, Term>, english: String, turkish: String, exact: Boolean = false) {
            val en = collapse(english)
            val tr = collapse(turkish)
            // Harfsiz terim her yerde eşleşirdi; yer tutucu sayısı sınırlı olduğundan çok uzun terim de alınmaz.
            if (en.none { it.isLetter() } || tr.isEmpty() || en.length > 80) return
            terms[en.lowercase(Locale.ROOT)] = Term(en, tr, exact)
        }

        /** Sözlükleri birleştirir; aynı terimde sonraki kazanır. */
        fun merge(glossaries: List<Glossary>): Glossary {
            val terms = mutableMapOf<String, Term>()
            for (glossary in glossaries) terms.putAll(glossary.terms)
            return Glossary(terms)
        }

        /** Genel sözlük ([builtIn], uygulamayla gelen metin) ve klasördeki `*.json` dosyaları; bozuk dosya atlanır. */
        fun load(builtIn: String?, directory: File?): Glossary {
            val all = mutableListOf<Glossary>()
            builtIn?.let { runCatching { parse(it) }.getOrNull()?.let(all::add) }
            directory?.listFiles { file -> file.name.endsWith(".json") }?.sortedBy { it.name }?.forEach { file ->
                runCatching { parse(file.readText(Charsets.UTF_8)) }.getOrNull()?.let(all::add)
            }
            return merge(all)
        }

        /** Uygulamanın sözlüğü: assets/glossary-en-tr.json ve files/glossary/*.json. */
        fun load(context: android.content.Context): Glossary = load(
            runCatching { context.assets.open("glossary-en-tr.json").use { String(it.readBytes(), Charsets.UTF_8) } }.getOrNull(),
            File(context.filesDir, "glossary"),
        )

        private fun collapse(text: String) = text.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

        /** FNV-1a (32 bit), terimler İngilizcesine göre sıralı (Mac/iPhone ile aynı hesap). */
        private fun makeFingerprint(terms: List<Term>): String {
            var hash = 2_166_136_261L
            val sorted = terms.sortedWith { a, b -> compareBytes(a.english.lowercase(Locale.ROOT).toByteArray(), b.english.lowercase(Locale.ROOT).toByteArray()) }
            for (term in sorted) {
                val text = term.english.lowercase(Locale.ROOT) + "\u0001" + term.turkish + (if (term.exact) "\u0003" else "") + "\u0002"
                for (byte in text.toByteArray(Charsets.UTF_8)) {
                    hash = ((hash xor (byte.toLong() and 0xff)) * 16_777_619L) and 0xffffffffL
                }
            }
            return "g" + String.format(Locale.ROOT, "%08x", hash)
        }

        private fun compareBytes(a: ByteArray, b: ByteArray): Int {
            for (i in 0 until minOf(a.size, b.size)) {
                val diff = (a[i].toInt() and 0xff) - (b[i].toInt() and 0xff)
                if (diff != 0) return diff
            }
            return a.size - b.size
        }
    }

    /** Terimin Türkçesi; yoksa null. */
    fun turkish(english: String): String? = terms[collapse(english).lowercase(Locale.ROOT)]?.turkish

    /** Metindeki terimler: tam sözcük, uzun terim önce; çakışan kısa terim alınmaz. Sonuç metindeki sıraya göredir. */
    fun find(text: String): List<TermMatch> {
        if (ordered.isEmpty() || text.isEmpty()) return emptyList()
        val found = mutableListOf<TermMatch>()
        for (term in ordered) {
            var start = 0
            while (start < text.length) {
                val index = text.indexOf(term.english, start, ignoreCase = !term.exact)
                if (index < 0) break
                val end = index + term.english.length
                if (isBoundary(text, index - 1) && isBoundary(text, end) && found.none { index < it.start + it.length && it.start < end })
                    found.add(TermMatch(index, term.english.length, term.english, term.turkish))
                start = index + 1
            }
        }
        return found.sortedBy { it.start }
    }

    fun matches(text: String): Boolean = find(text).isNotEmpty()

    private fun isBoundary(text: String, index: Int): Boolean =
        index < 0 || index >= text.length || !text[index].isLetterOrDigit()
}

/**
 * Sözlük teriminin Türkçe eki (Mac/iPhone: TurkishSuffix.swift, Windows: TurkishSuffix.cs; aynı kurallar). Çeviri motoru
 * yer tutucu ada bir ek koyar ("Zarmon'a"); ek, hâli korunarak gerçek terime göre yeniden kurulur: ünlü uyumu,
 * kaynaştırma (Freya'ya), ünsüz benzeşmesi (Kratos'ta), özel ad kesmeyle, cins ad bitişik ve yumuşayarak (kılıcı),
 * çok sözcüklü dar ünlüyle biten terim tamlama (Leviathan Baltası'nı).
 */
object TurkishSuffix {
    private val vowels = setOf('a', 'e', 'ı', 'i', 'o', 'ö', 'u', 'ü')
    private val backVowels = setOf('a', 'ı', 'o', 'u')
    private val roundedVowels = setOf('o', 'u', 'ö', 'ü')
    private val highVowels = setOf('ı', 'i', 'u', 'ü')
    private val voiceless = setOf('f', 's', 't', 'k', 'ç', 'ş', 'h', 'p')
    /** Daha uzun "ek" büyük olasılıkla ek değildir; dokunulmaz. */
    private const val MAX_SUFFIX_LENGTH = 12

    /** [term] + ek. [suffix] motorun yer tutucuya koyduğu ektir (kesmesiz); boşsa terim döner. */
    fun attach(term: String, suffix: String, apostrophe: Char = '\''): String {
        if (term.isEmpty() || suffix.isEmpty()) return term
        val body = suffix.lowercase(turkish).toMutableList()
        if (body.size > MAX_SUFFIX_LENGTH || !body.all { it.isLetter() }) return term + apostrophe + suffix

        val proper = term.first().isUpperCase()
        val lastWord = (term.split(' ').lastOrNull() ?: term).lowercase(turkish)
        val lastLetter = lastWord.lastOrNull { it.isLetter() } ?: ' '
        var lastVowel = lastWord.lastOrNull { it in vowels }
        // Ünlüsüz kısaltma ("XP", "HP") harf adlarıyla okunur: "iks-pe" → ince, ünlüyle biter.
        val endsWithVowel = lastVowel == null || lastLetter in vowels
        if (lastVowel == null) lastVowel = 'e'
        val compound = ' ' in term && lastLetter in highVowels && lastWord.length >= 3
        val isVoiceless = !endsWithVowel && lastLetter in voiceless

        // Baştaki kaynaştırma harfi yer tutucuya göreydi ("Zarmon" ünsüzle biter); atılır.
        if (body.size >= 2 && body[0] == 'y' && (body[1] in vowels || body[1] == 'l')) body.removeAt(0)
        else if (body.size >= 3 && body[0] == 'n' && body[1] in highVowels && body[2] == 'n') body.removeAt(0)

        val genitive = body.size >= 2 && body[0] in highVowels && body[1] == 'n' && (body.size == 2 || body[2] !in vowels)
        val instrumental = body.size >= 2 && body[0] == 'l' && (body[1] == 'a' || body[1] == 'e') && !(body.size >= 3 && body[2] == 'r')
        var buffer = ""
        if (body[0] in vowels) {
            if (compound || (endsWithVowel && genitive)) buffer = "n" else if (endsWithVowel) buffer = "y"
        } else if (body[0] == 'd' || body[0] == 't') {
            if (compound) buffer = "n"
            body[0] = if (compound || !isVoiceless) 'd' else 't'
        } else if (instrumental && (endsWithVowel || compound)) {
            buffer = "y"
        }

        val harmonized = harmonize(body, lastVowel)
        if (proper) return term + apostrophe + buffer + harmonized
        val stem = if (buffer.isEmpty() && harmonized.first() in vowels) soften(term) else term
        return stem + buffer + harmonized
    }

    /** Ekteki a/e ve ı/i/u/ü ünlülerini önceki ünlüye uydurur; "-ki" (Midgard'daki) değişmez. */
    internal fun harmonize(body: List<Char>, lastVowel: Char): String {
        val output = StringBuilder()
        var previous = lastVowel
        for ((index, original) in body.withIndex()) {
            var c = original
            val invariantKi = c == 'i' && index > 0 && body[index - 1] == 'k' && index == body.size - 1
            if (!invariantKi && (c == 'a' || c == 'e')) {
                c = if (previous in backVowels) 'a' else 'e'
            } else if (!invariantKi && c in highVowels) {
                val back = previous in backVowels
                val rounded = previous in roundedVowels
                c = if (back) (if (rounded) 'u' else 'ı') else (if (rounded) 'ü' else 'i')
            }
            if (c in vowels) previous = c
            output.append(c)
        }
        return output.toString()
    }

    /** Cins adın son p/ç/k'si ünlüyle başlayan ekten önce yumuşar; tek heceli sözcükler ve t yumuşamaz. */
    internal fun soften(term: String): String {
        if (term.length < 2) return term
        val last = term.last()
        val word = term.lowercase(turkish).split(' ').lastOrNull() ?: ""
        if (word.endsWith("nk")) return term.dropLast(1) + "g"
        if (word.count { it in vowels } < 2) return term
        return when (last) {
            'p' -> term.dropLast(1) + "b"
            'ç' -> term.dropLast(1) + "c"
            'k' -> term.dropLast(1) + "ğ"
            else -> term
        }
    }
}

/**
 * Sözlük terimlerini çeviriden korur (Mac/iPhone: TermProtection.swift, aynı kurallar). Terim çeviriden önce uydurma
 * bir özel adla ("Zarmon") değiştirilir; çeviri motoru özel adı olduğu gibi bırakıp ekini kesmeyle ekler. Çeviriden sonra
 * ad bulunur, yerine Türkçe terim konur ve ek terime göre yeniden kurulur. Ad çeviride yoksa sonuç güvenilmez (null).
 */
class TermProtector(private val glossary: Glossary, sources: List<String>) {
    /** Korunan terim: yer tutucusu ve yerine konacak Türkçe. */
    data class Slot(val placeholder: String, val english: String, val turkish: String)

    companion object {
        /** Türkçe ve İngilizcede sözcük değil, i/I içermez, ünsüzle biter ve kalın ünlülüdür. */
        val placeholders = listOf("Zarmon", "Velkor", "Dorvan", "Kelmar", "Tolvar", "Brandur", "Halvor", "Feldor")

        /** Yer tutucuları Türkçe terimle değiştirir; [expected] çıktıda geçmeli, [all] içindeki diğer adlar geçmemeli. */
        fun restore(output: String, expected: List<Slot>, all: List<Slot> = emptyList(), apostrophe: Char = '\''): String? {
            if (expected.isEmpty() && all.isEmpty()) return output
            for (slot in all) if (slot !in expected && pattern(slot.placeholder).containsMatchIn(output)) return null
            var text = output
            for (slot in expected) {
                val found = pattern(slot.placeholder).findAll(text).toList()
                if (found.isEmpty()) return null
                val builder = StringBuilder(text)
                for (match in found.asReversed()) {
                    val suffix = match.groups[1]?.value ?: match.groups[2]?.value ?: ""
                    var term = TurkishSuffix.attach(slot.turkish, suffix, apostrophe)
                    if (startsSentence(text, match.range.first)) term = capitalize(term)
                    builder.replace(match.range.first, match.range.last + 1, term)
                }
                text = builder.toString()
            }
            return text
        }

        /** Yer tutucu ve ardındaki ek: kesmeyle ("Zarmon'a", "Zarmon 'a") ya da bitişik ("Zarmona"). */
        private fun pattern(placeholder: String) =
            Regex("(?<![\\p{L}\\p{N}])$placeholder(?:\\s?['’`´](\\p{L}+)|(\\p{L}+))?(?![\\p{L}\\p{N}])", RegexOption.IGNORE_CASE)

        /** Metnin ya da cümlenin başı mı (önünde yalnız boşluk, tırnak, tire ya da cümle sonu var). */
        private fun startsSentence(text: String, index: Int): Boolean {
            var i = index - 1
            while (i >= 0) {
                val c = text[i]
                if (c.isWhitespace() || c in "\"“'‘(-–—¡¿") { i--; continue }
                return c in ".!?…"
            }
            return true
        }

        private fun capitalize(term: String): String {
            val first = term.firstOrNull() ?: return term
            if (!first.isLowerCase()) return term
            return first.toString().uppercase(turkish) + term.substring(1)
        }
    }

    private val free = placeholders.filter { name -> sources.none { it.contains(name, ignoreCase = true) } }.toMutableList()
    private val byTerm = mutableMapOf<String, Slot>()
    private val order = mutableListOf<Slot>()

    /** Bütün yer tutucular (bağlamdakiler dahil); çıktıda beklenmeyen ad kalmasın diye. */
    val allSlots: List<Slot> get() = order.toList()

    /** Terimleri yer tutucularla değiştirir; bu metinde kullanılan yer tutucular döner. */
    fun protect(text: String): Pair<String, List<Slot>> {
        val matches = glossary.find(text)
        if (matches.isEmpty()) return text to emptyList()
        val output = StringBuilder()
        val used = mutableListOf<Slot>()
        var position = 0
        for (match in matches) {
            val key = match.english.lowercase(Locale.ROOT)
            var slot = byTerm[key]
            if (slot == null) {
                // Ad kalmadıysa geri kalan terimler korunmaz; model onları kendi çevirir.
                if (free.isEmpty()) continue
                slot = Slot(free.removeAt(0), match.english, match.turkish)
                byTerm[key] = slot
                order.add(slot)
            }
            output.append(text, position, match.start).append(slot.placeholder)
            position = match.start + match.length
            if (slot !in used) used.add(slot)
        }
        output.append(text, position, text.length)
        return output.toString() to used
    }
}

/**
 * Ücretsiz (cihaz üstü) çevirinin ortak metin hattı (Mac/iPhone: FreeTranslation.swift, aynı adımlar ve sabitler): büyük
 * harf düzeni → oyun deyimleri → terim koruma → çeviri → terim ve ekleri → Türkçe düzeltmeler. Kısa satır (3 sözcük ve
 * altı) önceki cümleyle birlikte çevrilir; tek başına çevrilince hitap ve zamirler kayıyordu. Ayraçtan sonrası alınır,
 * ayrım belirsizse satır tek başına çevrilir.
 */
object FreeTranslation {
    /** Çeviri öncesi/sonrası kuralların sürümü; kalıcı önbelleğin motor adına girer (iPhone ile aynı sayı). */
    const val PIPELINE_VERSION = 2

    /** Bu sözcük sayısının altındaki cümle önceki cümleyle birlikte çevrilir. */
    const val SHORT_LINE_WORDS = 4

    /** Bağlam ile kısa satır arasındaki ayraç (OPUS-MT ve Apple'da da aynı; iki platform aynı davransın). */
    const val SEPARATOR = " *** "
    private const val SEPARATOR_CORE = "***"

    /** Önbellek anahtarında bağlam ile satırı ayıran karakter. */
    private const val KEY_JOIN = "\u001F"

    fun isShort(sentence: String): Boolean {
        val words = sentence.split(Regex("\\s+")).count { word -> word.any { it.isLetter() } }
        return words in 1 until SHORT_LINE_WORDS
    }

    /** Cümlenin önbellek anahtarı: bağlamla çevrildiyse bağlam da, sözlük terimi içeriyorsa sözlüğün izi de girer. */
    fun cacheKey(sentence: String, context: String?, glossary: Glossary): String {
        val basis = context?.let { it + KEY_JOIN + sentence } ?: sentence
        return if (glossary.matches(basis)) glossary.fingerprint + KEY_JOIN + basis else basis
    }

    /** Ayraçtan sonraki kısım; ayraç tam bir kez geçmiyorsa, iki yan da harf içermiyorsa ya da kısım çok uzunsa null. */
    fun afterSeparator(output: String, source: String): String? {
        val first = output.indexOf(SEPARATOR_CORE)
        if (first < 0 || output.indexOf(SEPARATOR_CORE, first + SEPARATOR_CORE.length) >= 0) return null
        val before = output.substring(0, first)
        val after = output.substring(first + SEPARATOR_CORE.length).trim()
        // "****" gibi yapışık yıldızlar da belirsizdir.
        if (after.startsWith("*") || before.endsWith("*")) return null
        if (before.none { it.isLetter() } || after.none { it.isLetter() }) return null
        if (after.length > 3 * source.length + 20) return null
        return after
    }

    /** Kaynakta kıvrık kesme varsa terimin eki de onunla ayrılır. */
    fun apostrophe(source: String): Char = if ('’' in source) '’' else '\''

    /**
     * Tek cümleyi çevirir. [normalize] büyük harf düzenini yapar, [engine] çeviri motorudur. Önce bağlamla (verildiyse),
     * olmazsa tek başına, terimler korunamadıysa korumasız çevrilir.
     */
    fun translate(sentence: String, context: String?, glossary: Glossary, normalize: (String) -> String, engine: (String) -> String): String {
        val apostrophe = apostrophe(sentence)
        fun prepare(text: String) = GameEnglish.plain(normalize(text))

        if (context != null) {
            val protector = TermProtector(glossary, listOf(sentence, context))
            val contextText = protector.protect(prepare(context)).first
            val (sentenceText, slots) = protector.protect(prepare(sentence))
            val output = engine(contextText + SEPARATOR + sentenceText)
            val after = afterSeparator(output, sentence)
            val restored = after?.let { TermProtector.restore(it, slots, protector.allSlots, apostrophe) }
            if (restored != null) return TurkishPostEdit.apply(sentence, restored)
        }

        val single = TermProtector(glossary, listOf(sentence))
        val (input, used) = single.protect(prepare(sentence))
        val translated = engine(input)
        if (used.isEmpty()) return TurkishPostEdit.apply(sentence, translated)
        TermProtector.restore(translated, used, single.allSlots, apostrophe)?.let { return TurkishPostEdit.apply(sentence, it) }
        // Model bir yer tutucuyu düşürdü: terimsiz ama eksiksiz çeviri, eksik terimli çeviriden iyidir.
        return TurkishPostEdit.apply(sentence, engine(prepare(sentence)))
    }
}

/**
 * Son gösterilen satır: kısa satırın bağlamı. Aynı satır yeniden okunursa aynı bağlam döner (çeviri ekranda
 * değişmesin); bağlam satırı çok önce gösterildiyse bağlam yoktur.
 */
class RecentLines(private val clock: () -> Long = System::currentTimeMillis) {
    companion object {
        const val MAX_AGE_MS = 20_000L
    }

    private data class Last(val text: String, val context: String?, val seen: Long)

    private var last: Last? = null

    /** Satırın gösterildiğini kaydeder; bu satırdan önce gösterilen satırı döner (yoksa null). */
    @Synchronized
    fun shown(text: String): String? {
        val now = clock()
        val previous = last
        if (previous != null && previous.text == text) {
            last = previous.copy(seen = now)
            return previous.context
        }
        val context = previous?.takeIf { now - it.seen <= MAX_AGE_MS }?.text
        last = Last(text, context, now)
        return context
    }
}

/**
 * Ücretsiz motorun satır düzeyi (Mac/iPhone: FreeLineTranslator): satırı cümlelere böler, kısa cümleye bağlam seçer,
 * cümleleri önbellekten ya da motordan alır, hitabı satır bütününe göre düzeltir. Motor (ML Kit) dışarıdan verilir.
 */
class FreeLineTranslator(
    private val cache: TranslationCache = TranslationCache(),
    private val glossary: Glossary = Glossary.Empty,
    clock: () -> Long = System::currentTimeMillis,
    private val engine: (String) -> String,
) : TextTranslator {
    private val recent = RecentLines(clock)
    private val names = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    override fun translate(text: String): String {
        // Kısa cümlenin bağlamı: aynı satırdaki önceki cümle, yoksa bu satırdan önce gösterilen satırın son cümlesi.
        val previousLine = recent.shown(text)
        val pieces = SubtitleSegmenter.split(text)
        for (name in pieces.mapNotNull(SubtitleSegmenter::labelName))
            name.split(' ').filter { it.length >= 2 }.forEach { names.add(it.lowercase(Locale.ROOT)) }
        var previous = previousLine?.let { line -> SubtitleSegmenter.split(line).lastOrNull { it.translate }?.text }
        val translations = pieces.map { piece ->
            if (!piece.translate) null
            else {
                val context = if (FreeTranslation.isShort(piece.text)) previous else null
                translateSentence(piece.text, context).also { previous = piece.text }
            }
        }
        // Hitap satırın bütününe bakar ("Sana söyledim. Bekleyin!"); önbellekteki cümle çevirileri değişmez.
        val final = TurkishPostEdit.register(translations)
        return pieces.indices.joinToString("") { final[it] ?: pieces[it].text }
    }

    private fun translateSentence(sentence: String, context: String?): String {
        val key = FreeTranslation.cacheKey(sentence, context, glossary)
        cache.get(key)?.let { return it }
        val known = names.toSet() + glossary.capitalWords
        val result = FreeTranslation.translate(sentence, context, glossary, { SubtitleSegmenter.normalizeCase(it, known) }, engine)
        cache.store(key, result)
        return result
    }
}

/**
 * Sözlük terimlerini DeepL'e "çevirme" etiketiyle gönderir (Mac/iPhone: DeepLMarkup.swift, aynı kurallar). Terim
 * Türkçesiyle değiştirilip `<x>…</x>` içine alınır; istek `tag_handling: xml` ve `ignore_tags: ["x"]` ile gider.
 * Etiketsiz gönderilince DeepL "Soul began…" gibi cümlelerde adı sıradan sözcük gibi çeviriyordu.
 */
object DeepLMarkup {
    const val TAG = "x"

    /** Sözlükte geçen terim varsa etiketli (XML'e kaçırılmış) metin, yoksa null. */
    fun wrap(text: String, glossary: Glossary): String? {
        val matches = glossary.find(text)
        if (matches.isEmpty()) return null
        val result = StringBuilder()
        var cursor = 0
        for (match in matches) {
            result.append(escape(text.substring(cursor, match.start)))
            result.append("<$TAG>").append(escape(match.turkish)).append("</$TAG>")
            cursor = match.start + match.length
        }
        result.append(escape(text.substring(cursor)))
        return result.toString()
    }

    fun escape(text: String) = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    /** DeepL'in döndürdüğü etiketli çeviriden düz metin. */
    fun unwrap(text: String) = text.replace("<$TAG>", "").replace("</$TAG>", "")
        .replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")

    /** Terim içeren satırın önbellek anahtarına sözlüğün izi girer; sözlük değişince yeniden çevrilir. */
    fun cacheKey(text: String, glossary: Glossary) = if (glossary.matches(text)) glossary.fingerprint + "\u001F" + text else text
}
