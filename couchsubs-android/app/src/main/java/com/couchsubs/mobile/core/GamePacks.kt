// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale
import java.util.zip.GZIPInputStream

/**
 * Oyun paketinin anahtarı: ekranda okunan İngilizce satırın sadeleştirilmiş hâlinin SHA-256'sının ilk 8 baytı (hex).
 * Mac (GamePacks.swift), Windows (GamePacks.cs) ve paket hazırlayan Python betiğiyle (canon.py) birebir aynı adımlar;
 * ortak deneme verisi core/Tests/CouchSubsCoreTests/Fixtures/golden-vectors.json.
 */
object PackKey {
    /** Biçim etiketi: en çok 40 karakterlik `<…>` ("<b>", "</>"). */
    const val MAX_TAG_LENGTH = 40

    /**
     * 1. etiketler boşluk olur, 2. NFKC, 3. küçük harf, 4. NFD ile aksan ve işaretler atılır,
     * 5. harf ve rakam dışındaki her şey boşluk olur, 6. boşluklar teklenir, baş ve son kırpılır.
     */
    fun canon(text: String): String {
        // Locale.ROOT küçük harfi Python'un str.lower()'ı gibi tam eşlemedir: "İ" → "i" + üst nokta (nokta 4. adımda atılır).
        val lowered = Normalizer.normalize(stripTags(text), Normalizer.Form.NFKC).lowercase(Locale.ROOT)
        val decomposed = Normalizer.normalize(lowered, Normalizer.Form.NFD)
        val output = StringBuilder(decomposed.length)
        var gap = false
        var index = 0
        while (index < decomposed.length) {
            val codePoint = decomposed.codePointAt(index)
            index += Character.charCount(codePoint)
            when (Character.getType(codePoint).toByte()) {
                Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK -> continue
                Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
                Character.MODIFIER_LETTER, Character.OTHER_LETTER,
                Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> {
                    if (gap && output.isNotEmpty()) output.append(' ')
                    gap = false
                    output.appendCodePoint(codePoint)
                }
                else -> gap = true
            }
        }
        return output.toString()
    }

    /** 16 haneli küçük harf hex anahtar; satırda harf ya da rakam yoksa null. */
    fun key(text: String): String? {
        val canon = canon(text)
        if (canon.isEmpty()) return null
        val hash = MessageDigest.getInstance("SHA-256").digest(canon.toByteArray(Charsets.UTF_8))
        return hash.take(8).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    /** Anahtarın sayı hâli (sözlükte daha az yer tutar); geçersizse null. */
    fun number(key: String): Long? {
        if (key.length != 16 || !key.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        return java.lang.Long.parseUnsignedLong(key, 16)
    }

    /**
     * `<…>` etiketlerini (en çok 40 karakter, içinde < ya da > yok) [replacement] ile değiştirir. Python'daki
     * `re.sub(r"<[^<>]{0,40}>", " ", s)` ile aynı: kod noktası sayılır.
     */
    fun stripTags(text: String, replacement: String = " "): String {
        if (!text.contains('<')) return text
        val points = text.codePoints().toArray()
        val output = StringBuilder(text.length)
        var index = 0
        while (index < points.size) {
            if (points[index] == '<'.code) {
                var end = index + 1
                while (end < points.size && end - index - 1 <= MAX_TAG_LENGTH && points[end] != '<'.code && points[end] != '>'.code) end++
                if (end < points.size && points[end] == '>'.code && end - index - 1 <= MAX_TAG_LENGTH) {
                    output.append(replacement)
                    index = end + 1
                    continue
                }
            }
            output.appendCodePoint(points[index])
            index++
        }
        return output.toString()
    }
}

/** Dosya paket değil ya da bozuk. */
class InvalidPackException(message: String, cause: Throwable? = null) : IOException(message, cause)

/**
 * Bir oyunun çeviri paketi. Dosya gzip'li JSON'dur: `{"format":1|2,"id":…,"title":…,"entries":{anahtar: Türkçe}}`;
 * yalnız `{anahtar: Türkçe}` nesnesi de kabul edilir (adı dosya adından gelir). Biçim 2 ayrıca `segments` taşır (oyunun
 * ayrı gösterdiği parçalar ve çok cümleli satırların cümleleri; aynı düzen). Masaüstünün biçim 2'deki `fuzzy` imzaları
 * (OCR'ın bozduğu satırı bulma) telefonda henüz kullanılmıyor.
 *
 * Telefonda bellek sınırlıdır (uygulamayla gelen altı pakette ~520 bin satır): satırlar sıralı anahtar dizisi ve tek bir
 * UTF-8 bayt bloğunda tutulur (~30 MB; HashMap<Long, String> bunun üç katından fazlasını isterdi), ikili aramayla bulunur.
 * Dosya da akış hâlinde okunur ([PackJson]); bütün JSON bir nesne ağacına dönüştürülmez.
 */
class GamePack private constructor(val id: String, val title: String, private val entries: Table, private val segments: Table) {
    /** Sıralı anahtarlar ve UTF-8 metin bloğu. */
    internal class Table(private val keys: LongArray, private val offsets: IntArray, private val blob: ByteArray) {
        val size get() = keys.size

        operator fun get(key: Long): String? {
            val index = java.util.Arrays.binarySearch(keys, key)
            if (index < 0) return null
            return String(blob, offsets[index], offsets[index + 1] - offsets[index], Charsets.UTF_8)
        }

        companion object {
            fun of(map: Map<Long, String>): Table {
                val keys = map.keys.toLongArray().also { it.sort() }
                val offsets = IntArray(keys.size + 1)
                val blob = java.io.ByteArrayOutputStream(map.size * 48)
                for ((index, key) in keys.withIndex()) {
                    offsets[index] = blob.size()
                    blob.write(map.getValue(key).toByteArray(Charsets.UTF_8))
                }
                offsets[keys.size] = blob.size()
                return Table(keys, offsets, blob.toByteArray())
            }
        }
    }

    /** Tam satır sayısı (parçalar hariç). */
    val size: Int get() = entries.size

    /** Anahtarın (sayı hâli) tam satır Türkçesi. */
    operator fun get(key: Long): String? = entries[key]

    /** Anahtarın parça ("segments") Türkçesi. */
    fun segment(key: Long): String? = segments[key]

    companion object {
        /** [name]: dosya adı uzantısız ("mafia-the-old-country"); düz biçimde kimlik ve başlık olur. */
        fun decode(data: ByteArray, name: String): GamePack {
            val json = if (data.size >= 2 && data[0] == 0x1f.toByte() && data[1] == 0x8b.toByte()) decompress(data) else data
            val entries = HashMap<Long, String>()
            val segments = HashMap<Long, String>()
            fun add(target: HashMap<Long, String>, key: String, value: String) {
                val number = PackKey.number(key.lowercase(Locale.ROOT)) ?: return
                val text = cleaned(value)
                // Aynı anahtar iki kez varsa sonraki kazanır.
                if (text.isNotEmpty()) target[number] = text
            }
            val parsed = PackJson.parse(json, { key, value -> add(entries, key, value) }, { key, value -> add(segments, key, value) })
            if (!parsed.wrapped) {
                parsed.rootStrings.forEach { (key, value) -> add(entries, key, value) }
                return build(name, name, entries, emptyMap())
            }
            if (parsed.format != null && parsed.format != 1.0 && parsed.format != 2.0) throw InvalidPackException("Desteklenmeyen paket biçimi")
            val id = parsed.id?.takeIf { it.isNotEmpty() } ?: name
            return build(id, parsed.title?.takeIf { it.isNotEmpty() } ?: id, entries, segments)
        }

        private fun build(id: String, title: String, entries: Map<Long, String>, segments: Map<Long, String>): GamePack {
            if (entries.isEmpty()) throw InvalidPackException("Pakette satır yok")
            return GamePack(id, title, Table.of(entries), Table.of(segments))
        }

        /** Paketteki Türkçede de oyunun biçim etiketleri kalmış olabilir ("<b><h>…</>"); TV'de görünmesinler. */
        fun cleaned(text: String): String {
            if (!text.contains('<')) return text.trim()
            return PackKey.stripTags(text, "").split(' ').filter { it.isNotEmpty() }.joinToString(" ").trim()
        }

        private fun decompress(data: ByteArray): ByteArray = try {
            GZIPInputStream(ByteArrayInputStream(data)).use { it.readBytes() }
        } catch (error: IOException) {
            throw InvalidPackException("Paket açılamadı", error)
        }
    }
}

/** Pakette bulunan satırın Türkçesi ve hangi paketten geldiği (ana ekrandaki "… paketi kullanılıyor" için). */
data class PackMatch(val text: String, val packId: String? = null)

/**
 * Uygulamayla gelen ve kullanıcının klasörüne bırakılan paketler (Windows: GamePackLibrary). Sıra: uygulamanınkiler,
 * sonra kullanıcınınkiler (dosya adına göre); aynı anahtarda sonraki kazanır, aynı kimlikli pakette kullanıcının dosyası
 * uygulamanınkinin yerine geçer. Ayarlarda kapatılan paketlere bakılmaz.
 *
 * Masaüstü paketleri tek sözlükte birleştirir; burada her paket ayrı tutulur ve sondan başa aranır (aynı sonuç), böylece
 * satırın hangi oyunun paketinden geldiği bilinir.
 */
class GamePackLibrary(
    private val bundled: (() -> List<Pair<String, ByteArray>>)?,
    private val userDirectory: File?,
) {
    data class Info(val id: String, val title: String, val entries: Int, val builtIn: Boolean)

    private val lock = Any()
    private var loaded = false
    private var packs: List<Pair<GamePack, Boolean>> = emptyList()
    @Volatile private var disabled: Set<String> = emptySet()

    val infos: List<Info>
        get() = synchronized(lock) {
            loadIfNeeded()
            packs.map { (pack, builtIn) -> Info(pack.id, pack.title, pack.size, builtIn) }
        }

    /** Kapatılan paket kimlikleri (ayarlardan). */
    fun setDisabled(ids: Set<String>) {
        disabled = ids
    }

    fun reload() = synchronized(lock) {
        loaded = false
        loadIfNeeded()
    }

    /** Yüklemeyi şimdi yapar (açılışta arka planda; ilk altyazı beklemesin). */
    fun warmUp() {
        infos
    }

    /** Satırın tamamı için paketteki Türkçe ve paketin kimliği (parçalara bölme yok; bkz. [PackLookup]). */
    fun findWithPack(text: String): PackMatch? {
        val current = synchronized(lock) {
            loadIfNeeded()
            packs
        }
        if (current.isEmpty()) return null
        val number = PackKey.key(text)?.let(PackKey::number) ?: return null
        val off = disabled
        for (index in current.indices.reversed()) {
            val pack = current[index].first
            if (pack.id in off) continue
            pack[number]?.let { return PackMatch(it, pack.id) }
        }
        // Tam satır yoksa parçalar: bir oyunun tam satırı başka oyunun parçasına yenilmez (masaüstüyle aynı öncelik).
        for (index in current.indices.reversed()) {
            val pack = current[index].first
            if (pack.id in off) continue
            pack.segment(number)?.let { return PackMatch(it, pack.id) }
        }
        return null
    }

    fun find(text: String): String? = findWithPack(text)?.text

    private fun loadIfNeeded() {
        if (loaded) return
        loaded = true
        val list = mutableListOf<Pair<GamePack, Boolean>>()
        fun add(fileName: String, data: ByteArray, builtIn: Boolean) {
            val pack = try {
                GamePack.decode(data, baseName(fileName))
            } catch (error: InvalidPackException) {
                return
            }
            list.removeAll { it.first.id == pack.id }
            list.add(pack to builtIn)
        }
        bundled?.invoke()?.sortedBy { it.first }?.forEach { (name, data) -> if (isPackFile(name)) add(name, data, true) }
        userDirectory?.listFiles()?.filter { it.isFile && isPackFile(it.name) }?.sortedBy { it.name }?.forEach { file ->
            val data = try {
                file.readBytes()
            } catch (error: IOException) {
                return@forEach
            }
            add(file.name, data, false)
        }
        packs = list
    }

    companion object {
        fun isPackFile(name: String) = name.endsWith(".json.gz") || name.endsWith(".json")

        /** "mafia.json.gz" → "mafia" */
        fun baseName(fileName: String): String {
            var name = File(fileName).name
            for (suffix in listOf(".gz", ".json")) if (name.endsWith(suffix)) name = name.dropLast(suffix.length)
            return name
        }
    }
}
