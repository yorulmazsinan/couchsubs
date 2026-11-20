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
        val hash = digest.get()!!.digest(canon.toByteArray(Charsets.UTF_8))
        return hash.take(8).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private val digest = ThreadLocal.withInitial { MessageDigest.getInstance("SHA-256") }

    /** Anahtarın sayı hâli doğrudan (hex dizesi kurulmadan; `number(key(text))` ile aynı); harf ya da rakam yoksa null. */
    fun keyNumber(text: String): Long? = canonNumber(canon(text))

    /** Zaten canon olan metnin anahtar sayısı; boşsa null. */
    fun canonNumber(canon: String): Long? {
        if (canon.isEmpty()) return null
        return java.nio.ByteBuffer.wrap(digest.get()!!.digest(canon.toByteArray(Charsets.UTF_8))).long
    }

    /** [canonNumber], canon metnin UTF-8 baytlarının ilk [size] tanesinden (boş olmamalı). */
    fun canonNumber(bytes: ByteArray, size: Int): Long {
        val sha = digest.get()!!
        sha.update(bytes, 0, size)
        return java.nio.ByteBuffer.wrap(sha.digest()).long
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
 * ayrı gösterdiği parçalar ve çok cümleli satırların cümleleri; aynı düzen) ve `fuzzy` (OCR'ın bozduğu satırı bulmak
 * için imzalar, bkz. [PackFuzzy]) taşır.
 *
 * Telefonda bellek sınırlıdır (uygulamayla gelen altı pakette ~520 bin satır): satırlar sıralı anahtar dizisi ve tek bir
 * UTF-8 bayt bloğunda tutulur (~30 MB; HashMap<Long, String> bunun üç katından fazlasını isterdi), ikili aramayla bulunur.
 * Dosya da akış hâlinde okunur ([PackJson]); bütün JSON bir nesne ağacına dönüştürülmez.
 */
class GamePack private constructor(
    val id: String,
    val title: String,
    private val entries: Table,
    private val segments: Table,
    /** Bulanık imzalar (biçim 2); yoksa ya da bozuksa null. */
    internal val fuzzy: PackFuzzyIndex?,
) {
    /** Sıralı anahtarlar ve UTF-8 metin bloğu. */
    internal class Table(private val keys: LongArray, private val offsets: IntArray, private val blob: ByteArray) {
        val size get() = keys.size

        operator fun get(key: Long): String? {
            val index = java.util.Arrays.binarySearch(keys, key)
            if (index < 0) return null
            return String(blob, offsets[index], offsets[index + 1] - offsets[index], Charsets.UTF_8)
        }

        fun contains(key: Long) = java.util.Arrays.binarySearch(keys, key) >= 0

        companion object {
            val EMPTY = Table(LongArray(0), IntArray(1), ByteArray(0))
        }
    }

    /**
     * Satırları geldiği sırayla düz dizilere yazar, sonunda anahtara göre sıralı [Table] kurar. Satır başına nesne
     * (HashMap düğümü, Long, String) tutulmaz: GTA V gibi büyük paket açılırken bellek tepe noktası birkaç kat düşer.
     */
    internal class TableBuilder {
        private var keys = LongArray(1024)
        private var ends = IntArray(1024)
        private var count = 0
        /** Tamponu kopyalamadan okunabilen bayt akışı (toByteArray() bütün metni bir kez daha kopyalardı). */
        private class Bytes : java.io.ByteArrayOutputStream(1 shl 16) {
            fun raw(): ByteArray = buf
        }
        private val blob = Bytes()

        val isEmpty get() = count == 0

        fun add(key: Long, text: String) {
            if (count == keys.size) {
                keys = keys.copyOf(count * 2)
                ends = ends.copyOf(count * 2)
            }
            blob.write(text.toByteArray(Charsets.UTF_8))
            keys[count] = key
            ends[count] = blob.size()
            count++
        }

        fun build(): Table {
            if (count == 0) return Table.EMPTY
            val bytes = blob.raw()
            // Kararlı sıralama: aynı anahtarın kayıtları geliş sırasıyla yan yana kalır, sonuncusu alınır.
            val order = (0 until count).sortedWith { a, b -> keys[a].compareTo(keys[b]) }
            var unique = 0
            var total = 0
            for (position in order.indices) {
                val index = order[position]
                if (position + 1 < order.size && keys[order[position + 1]] == keys[index]) continue
                unique++
                total += ends[index] - start(index)
            }
            val sortedKeys = LongArray(unique)
            val offsets = IntArray(unique + 1)
            val text = ByteArray(total)
            var slot = 0
            var at = 0
            for (position in order.indices) {
                val index = order[position]
                if (position + 1 < order.size && keys[order[position + 1]] == keys[index]) continue
                val from = start(index)
                val length = ends[index] - from
                System.arraycopy(bytes, from, text, at, length)
                sortedKeys[slot] = keys[index]
                offsets[slot] = at
                at += length
                slot++
            }
            offsets[unique] = at
            return Table(sortedKeys, offsets, text)
        }

        private fun start(index: Int) = if (index == 0) 0 else ends[index - 1]
    }

    /** Tam satır sayısı (parçalar hariç). */
    val size: Int get() = entries.size

    /** Anahtarın (sayı hâli) tam satır Türkçesi. */
    operator fun get(key: Long): String? = entries[key]

    /** Anahtarın parça ("segments") Türkçesi. */
    fun segment(key: Long): String? = segments[key]

    /** Anahtar pakette (tam satır ya da parça) var mı. */
    fun contains(key: Long) = entries.contains(key) || segments.contains(key)

    companion object {
        /** [name]: dosya adı uzantısız ("mafia-the-old-country"); düz biçimde kimlik ve başlık olur. */
        fun decode(data: ByteArray, name: String): GamePack {
            val json = if (data.size >= 2 && data[0] == 0x1f.toByte() && data[1] == 0x8b.toByte()) decompress(data) else data
            val entries = TableBuilder()
            val segments = TableBuilder()
            // İmzaların sırası: dosyadaki bütün geçerli anahtarlar (Türkçesi boş kalanlar da); imzalar yoksa atılır.
            var order = LongArray(1024)
            var orderCount = 0
            fun add(target: TableBuilder, key: String, value: String) {
                val number = PackKey.number(key.lowercase(Locale.ROOT)) ?: return
                if (orderCount == order.size) order = order.copyOf(orderCount * 2)
                order[orderCount++] = number
                val text = cleaned(value)
                // Aynı anahtar iki kez varsa sonraki kazanır (TableBuilder.build).
                if (text.isNotEmpty()) target.add(number, text)
            }
            val parsed = PackJson.parse(json, { key, value -> add(entries, key, value) }, { key, value -> add(segments, key, value) })
            if (!parsed.wrapped) {
                parsed.rootStrings.forEach { (key, value) -> add(entries, key, value) }
                return build(name, name, entries, TableBuilder())
            }
            if (parsed.format != null && parsed.format != 1.0 && parsed.format != 2.0) throw InvalidPackException("Desteklenmeyen paket biçimi")
            val id = parsed.id?.takeIf { it.isNotEmpty() } ?: name
            if (entries.isEmpty) throw InvalidPackException("Pakette satır yok")
            val fuzzy = parsed.fuzzy?.let { PackFuzzyIndex.decode(it, unsignedUnique(order, orderCount)) }
            return GamePack(id, parsed.title?.takeIf { it.isNotEmpty() } ?: id, entries.build(), segments.build(), fuzzy)
        }

        private fun build(id: String, title: String, entries: TableBuilder, segments: TableBuilder): GamePack {
            if (entries.isEmpty) throw InvalidPackException("Pakette satır yok")
            return GamePack(id, title, entries.build(), segments.build(), null)
        }

        /** İlk [count] anahtar işaretsiz sayı sırasıyla, tekrarsız (paket betiği anahtarları UInt64 olarak sıralar). */
        private fun unsignedUnique(keys: LongArray, count: Int): LongArray {
            val sorted = LongArray(count) { keys[it] xor Long.MIN_VALUE }
            sorted.sort()
            var unique = 0
            for (index in sorted.indices) {
                if (unique > 0 && sorted[unique - 1] == sorted[index]) continue
                sorted[unique++] = sorted[index]
            }
            return LongArray(unique) { sorted[it] xor Long.MIN_VALUE }
        }

        /** Paketteki Türkçede de oyunun biçim etiketleri kalmış olabilir ("<b><h>…</>"); TV'de görünmesinler. */
        fun cleaned(text: String): String {
            if (!text.contains('<')) return text.trim()
            return PackKey.stripTags(text, "").split(' ').filter { it.isNotEmpty() }.joinToString(" ").trim()
        }

        /**
         * Açılmış boyut gzip'in son 4 baytında yazar (ISIZE); dizi bir kerede o boyutta ayrılır. readBytes() büyüyen
         * tamponla açılmış boyutun yaklaşık üç katı geçici bellek isterdi (GTA V: 18 MB JSON).
         */
        private fun decompress(data: ByteArray): ByteArray = try {
            val size = if (data.size >= 18) (data[data.size - 4].toInt() and 0xff) or ((data[data.size - 3].toInt() and 0xff) shl 8) or
                ((data[data.size - 2].toInt() and 0xff) shl 16) or ((data[data.size - 1].toInt() and 0xff) shl 24) else -1
            GZIPInputStream(ByteArrayInputStream(data), 1 shl 16).use { input ->
                if (size !in 0..MAX_EXACT_SIZE) return@use input.readBytes()
                val out = ByteArray(size)
                var at = 0
                while (at < size) {
                    val count = input.read(out, at, size - at)
                    if (count < 0) break
                    at += count
                }
                // Boyut tutmadıysa (birden çok gzip üyesi ya da bozuk dosya) güvenli yola dönülür.
                if (at != size || input.read() != -1) GZIPInputStream(ByteArrayInputStream(data)).use { it.readBytes() } else out
            }
        } catch (error: IOException) {
            throw InvalidPackException("Paket açılamadı", error)
        }

        private const val MAX_EXACT_SIZE = 256 shl 20
    }
}

/** Pakette bulunan satırın Türkçesi ve hangi paketten geldiği (ana ekrandaki "… paketi kullanılıyor" için). */
data class PackMatch(val text: String, val packId: String? = null)

/**
 * Uygulamayla gelen ve kullanıcının klasörüne bırakılan paketler (Windows: GamePackLibrary). Sıra: uygulamanınkiler,
 * sonra kullanıcınınkiler (dosya adına göre), en son içe aktarılanlar; aynı anahtarda sonraki kazanır, aynı kimlikli pakette kullanıcının dosyası
 * uygulamanınkinin yerine geçer. Ayarlarda kapatılan paketlere bakılmaz.
 *
 * Masaüstü paketleri tek sözlükte birleştirir; burada her paket ayrı tutulur ve sondan başa aranır (aynı sonuç), böylece
 * satırın hangi oyunun paketinden geldiği bilinir.
 */
class GamePackLibrary(
    /**
     * Uygulamayla gelen paketlerin adları ve okuyucuları. Dosyalar sırayla, biri çözülüp bırakıldıktan sonra okunur:
     * hepsi birden belleğe alınırsa zayıf telefonda bellek yetmiyordu (çeviri başlarken uygulama kapanıyordu).
     */
    private val bundled: (() -> List<Pair<String, () -> ByteArray>>)?,
    private val userDirectory: File?,
    /** Ayarlar › Oyun paketleri'nden içe aktarılan topluluk paketleri ([GamePackImporter]); en son okunur, çakışan satırda kazanır. */
    private val importedDirectory: File? = null,
) {
    data class Info(val id: String, val title: String, val entries: Int, val builtIn: Boolean)

    private val lock = Any()
    private var loaded = false
    private var packs: List<Pair<GamePack, Boolean>> = emptyList()
    @Volatile private var disabled: Set<String> = emptySet()
    /**
     * Son tam eşleşmenin geldiği paket ([packs] sırası): bulanık arama yalnız orada yapılır (oynanan oyun). Satır birden
     * çok pakette varsa kapsam o paketlerden biri değilse ilkine geçer; hiç tam eşleşme olmadıysa bulanık arama yapılmaz.
     */
    private var scope: Int? = null
    private var distinctive: Int? = null
    /** Elle seçilen oyunun adı ([GameName.key]); null ise bütün paketlerde aranır. */
    private var limitKey: String? = null
    /** Elle seçilen oyunun paketi (paket listesi, sınır ve kapalı paketlere göre; her satırda yeniden aranmaz). */
    private var limitCache: Triple<List<Pair<GamePack, Boolean>>, Pair<String, Set<String>>, Set<Int>>? = null

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

    /**
     * Kullanıcının elle seçtiği oyun ([GameSense.packLimit]). Verilirse satırlar yalnız o oyunun paketinde aranır (tam ve
     * bulanık), paketi yoksa ya da kapalıysa hiç aranmaz: paketi olmayan oyunda "Let's go." gibi kısa, genel satırlar
     * başka oyunların paketinden yanlış çeviri getiriyor, oyunu da o pakete kaydırıyordu (#218). null: bütün paketler.
     */
    fun limitToGame(name: String?) {
        val key = name?.let { GameName.key(it) }?.takeIf { it.isNotEmpty() }
        synchronized(lock) {
            if (key == limitKey) return
            limitKey = key
            scope = null
            distinctive = null
        }
    }

    /** Aramanın yapılacağı paketler: elle seçilen oyun varsa yalnız onun paketi (yoksa hiçbiri), sınırı yoksa hepsi. */
    private fun searched(current: List<Pair<GamePack, Boolean>>, key: String?): Set<Int>? {
        if (key == null) return null
        val off = disabled
        synchronized(lock) {
            limitCache?.let { (list, of, result) -> if (list === current && of == key to off) return result }
        }
        val index = current.indices.lastOrNull { index ->
            val pack = current[index].first
            pack.id != GameSense.GENERAL_PACK && pack.id !in off &&
                (GameName.key(pack.title) == key || GameName.key(pack.id) == key)
        }
        val result = setOfNotNull(index)
        synchronized(lock) { limitCache = Triple(current, key to off, result) }
        return result
    }

    /** Satırın tamamı için paketteki Türkçe ve paketin kimliği (parçalara bölme yok; bkz. [PackLookup]). */
    fun findWithPack(text: String): PackMatch? {
        val (current, key) = synchronized(lock) {
            loadIfNeeded()
            packs to limitKey
        }
        if (current.isEmpty()) return null
        val only = searched(current, key)
        if (only?.isEmpty() == true) return null
        val number = PackKey.keyNumber(text) ?: return null
        val found = lookup(current, number, only) ?: return null
        noteHit(current, number, only)
        return found
    }

    /**
     * Tam anahtar yoksa oynanan oyunun (son tam eşleşmenin paketi) paketinde en yakın satırın Türkçesi: önce tek OCR
     * düzeltmesiyle ([PackFuzzy.variants]) tam anahtar, sonra bulanık imza. Hiç tam eşleşme olmadıysa null.
     */
    fun nearestWithPack(text: String): PackMatch? {
        val (current, chosen, limit) = synchronized(lock) {
            loadIfNeeded()
            Triple(packs, scope, limitKey)
        }
        // Elle seçilen oyunda bulanık arama da hep onun paketinde (tam eşleşme beklenmez); paketi yoksa yapılmaz.
        val only = searched(current, limit)
        val index = if (only != null) only.firstOrNull() else chosen
        val pack = index?.let { current.getOrNull(it)?.first }?.takeIf { it.id !in disabled } ?: return null
        corrected(text, pack, current, only)?.let { return it }
        val key = pack.fuzzy?.nearest(text) { lookup(current, it, only)?.text } ?: return null
        return lookup(current, key, only)
    }

    /** Bulanık aramanın yapılacağı paketin kimliği (son tam eşleşmenin paketi); yoksa null. */
    val searchScope: String? get() = synchronized(lock) { scope?.let { packs.getOrNull(it)?.first?.id } }

    /**
     * Son tam eşleşmenin geldiği paketin başlığı; yoksa null. Tek satırla değişebilir: yapay zekâya giden oyun adı bu
     * değil, [GameSense.current]'tır (#27).
     */
    val scopeTitle: String? get() = synchronized(lock) { scope?.let { packs.getOrNull(it)?.first?.title } }

    /**
     * Tek OCR düzeltmesiyle ([PackFuzzy.variants], hiçbiri tutmazsa [PackFuzzy.editKeys]) [pack]'te tam bulunan satırın
     * Türkçesi; aynı turdaki düzeltmelerin hepsi aynı Türkçeye çıkmıyorsa null.
     */
    private fun corrected(text: String, pack: GamePack, current: List<Pair<GamePack, Boolean>>, only: Set<Int>?): PackMatch? {
        val rounds: List<() -> Collection<Long>> = listOf(
            {
                PackFuzzy.variants(text).mapNotNull { variant ->
                    // ASCII canon metin yeniden sadeleştirilince değişmez; Normalizer'a gitmeden özetlenir.
                    if (variant.all { it.code < 128 }) PackKey.canonNumber(variant) else PackKey.keyNumber(variant)
                }
            },
            { PackFuzzy.editKeys(text) },
        )
        for (round in rounds) {
            var found: PackMatch? = null
            for (number in round()) {
                if (!pack.contains(number)) continue
                val turkish = lookup(current, number, only) ?: continue
                if (found != null && found.text != turkish.text) return null
                found = turkish
            }
            if (found != null) return found
        }
        return null
    }

    /**
     * Son çağrıdan beri yalnız tek bir pakette bulunan satırın paketi; okununca silinir. Okunan satırlar art arda aynı
     * paketten geliyorsa oynanan oyun o pakettir ([GameSense]). Birkaç pakette ortak satırlar ("Okay.") sayılmaz.
     */
    fun takeDistinctiveHit(): Info? = synchronized(lock) {
        val index = distinctive
        distinctive = null
        index?.let { packs.getOrNull(it) }?.let { (pack, builtIn) -> Info(pack.id, pack.title, pack.size, builtIn) }
    }

    private fun noteHit(current: List<Pair<GamePack, Boolean>>, number: Long, only: Set<Int>?) {
        val off = disabled
        val owners = current.indices.filter {
            (only == null || it in only) && current[it].first.id !in off && current[it].first.contains(number)
        }
        val first = owners.firstOrNull() ?: return
        synchronized(lock) {
            if (packs !== current) return
            if (owners.size == 1) distinctive = first
            if (owners.size == 1 || scope !in owners) scope = first
        }
    }

    /**
     * Anahtarın Türkçesi: açık paketlerde sondan başa tam satır, yoksa parça (masaüstünün birleşik sözlüğüyle aynı).
     * [only]: yalnız bu paketlerde (elle seçilen oyun).
     */
    private fun lookup(current: List<Pair<GamePack, Boolean>>, number: Long, only: Set<Int>? = null): PackMatch? {
        val off = disabled
        for (index in current.indices.reversed()) {
            val pack = current[index].first
            if (pack.id in off || (only != null && index !in only)) continue
            pack[number]?.let { return PackMatch(it, pack.id) }
        }
        // Tam satır yoksa parçalar: bir oyunun tam satırı başka oyunun parçasına yenilmez (masaüstüyle aynı öncelik).
        for (index in current.indices.reversed()) {
            val pack = current[index].first
            if (pack.id in off || (only != null && index !in only)) continue
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
        bundled?.invoke()?.sortedBy { it.first }?.forEach { (name, read) ->
            if (!isPackFile(name)) return@forEach
            val data = try {
                read()
            } catch (error: IOException) {
                return@forEach
            }
            add(name, data, true)
        }
        for (directory in listOfNotNull(userDirectory, importedDirectory)) {
            directory.listFiles()?.filter { it.isFile && isPackFile(it.name) }?.sortedBy { it.name }?.forEach { file ->
                val data = try {
                    file.readBytes()
                } catch (error: IOException) {
                    return@forEach
                }
                add(file.name, data, false)
            }
        }
        packs = list
        scope = null
        distinctive = null
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
