// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.text.Normalizer
import java.util.Locale

/**
 * Oynanan oyun. PS5'in keşif yanıtı çalışan oyunu çoğu zaman bildirmiyor (running-app-titleid boş); oyun üç yoldan bilinir,
 * öncelik sırasıyla: PS5'in bildirdiği ([setConsole]), kullanıcının elle seçtiği ([choose]) ve okunan satırların art arda
 * aynı hazır paketten gelmesi (son 20 satırın en az 5'i yalnız o pakette bulunan satırsa, [noteLine]). Elle seçim paket
 * çoğunluğunun önüne geçer: paketi olmayan oyunda ortak satırlar başka oyunun paketinden gelip oyunu değiştirmesin (#218).
 * Bilinen oyun ortak havuza giden satırlara eklenir ([LinePool.setGame]); sunucu aynı oyunun satırlarını ayrı pakete toplar. Hiçbiri yoksa
 * çeviri başladıktan iki dakika sonra bir kez "Hangi oyunu oynuyorsunuz?" sorulur ([shouldAsk]).
 * Mac ve iPhone'daki GameSense.swift ve Windows'taki GameSense.cs ile aynı kurallar.
 */
class GameSense {
    /**
     * [REMEMBERED]: kullanıcının önceki bir çeviri oturumunda seçtiği oyun (uygulama açık kaldıkça kalır). Kayıtlı alanlar
     * bu oyunda sessizce uygulanmaz, sorulur: kullanıcı başka oyuna geçip seçimi değiştirmediyse eski oyunun profili
     * uygulanıyor, yeni oyunda yapılan alan değişiklikleri de eski oyunun profiline kaydediliyordu.
     */
    enum class Source { CONSOLE, PACK, USER, REMEMBERED }

    /** Seçim bir çeviri oturumu sürerken yapıldı; sonraki oturumda [Source.REMEMBERED] sayılır. */
    private var chosenWhileRunning = false
    /** Seçim önceki bir oturumdan kaldı. */
    private var carried = false
    private var running = false

    private val lock = Any()
    private val recent = ArrayDeque<String?>()
    private val titles = HashMap<String, String>()
    private var console: RunningGame? = null
    private var pack: RunningGame? = null
    private var packId: String? = null
    private var chosen: RunningGame? = null
    private var asked = false
    /** Bu oturumda "telefon aranmıyor" satırı yazıldı ([shouldLogPhoneIdle]). */
    private var phoneIdleLogged = false

    /** Havuza giden oyun: PS5'in bildirdiği, yoksa kullanıcının seçtiği, yoksa paketten tanınan. */
    val current: RunningGame? get() = synchronized(lock) { console ?: chosen ?: pack }

    val source: Source?
        get() = synchronized(lock) {
            when {
                console != null -> Source.CONSOLE
                chosen != null -> if (carried) Source.REMEMBERED else Source.USER
                pack != null -> Source.PACK
                else -> null
            }
        }

    /**
     * Paket aramasının sınırlanacağı oyun ([GamePackLibrary.limitToGame]): kullanıcı elle seçtiyse ve PS5 bir oyun
     * bildirmiyorsa seçilen oyunun adı; yoksa null (bütün paketlerde aranır).
     */
    val packLimit: String? get() = synchronized(lock) { if (console == null) chosen?.name else null }

    /**
     * Bir satır gösterildi. [packId]/[title]: satır yalnız tek bir pakette bulunan anahtarla geldiyse o paket
     * ([GamePackLibrary.takeDistinctiveHit]); motorla çevrildiyse ya da birkaç pakette ortaksa null. Oyun yeni tanındıysa true.
     */
    fun noteLine(packId: String?, title: String?): Boolean = synchronized(lock) {
        val id = packId?.takeIf { it != GENERAL_PACK }
        recent.addLast(id)
        while (recent.size > WINDOW) recent.removeFirst()
        if (id == null) return false
        if (title != null) titles[id] = title
        if (id == this.packId || recent.count { it == id } < THRESHOLD) return false
        val game = RunningGame.named(titles[id] ?: id, titleIdFromPack(id)) ?: return false
        pack = game
        this.packId = id
        true
    }

    /**
     * PS5'in bildirdiği oyun (keşif yanıtı; bilinmiyorsa null). PS5 elle seçilenden başka bir oyun bildirirse elle seçim
     * eskimiştir ve silinir: yoksa PS5 bildirmeyi bırakınca (bağlantı kopunca) eski oyun geri gelir, paket araması da yine
     * yalnız onun paketinde yapılır (#227 sonrası "oyun değişince eski oyunda kalıyor").
     */
    fun setConsole(game: RunningGame?) = synchronized(lock) {
        console = game
        val reported = game?.name
        val picked = chosen?.name
        if (reported != null && picked != null && GameName.key(reported) != GameName.key(picked)) chosen = null
    }

    /** Kullanıcının seçimi ("Hangi oyunu oynuyorsunuz?" ya da "Değiştir"); null seçimi siler. */
    fun choose(name: String?) = synchronized(lock) {
        chosen = RunningGame.named(name)
        chosenWhileRunning = running
        carried = false
        asked = true
    }

    /**
     * Yeni çeviri oturumu: paket penceresi ve soru sıfırlanır; kullanıcının seçimi uygulama açık kaldıkça kalır. Önceki
     * oturumda yapılan seçim bu oturumda [Source.REMEMBERED] olur; çeviri dururken yapılan seçim (Ayarlar'da oyun profili
     * seçildi) bu oturum içindir, [Source.USER] kalır.
     */
    fun startSession() = synchronized(lock) {
        recent.clear()
        pack = null
        packId = null
        console = null
        asked = false
        phoneIdleLogged = false
        carried = chosen != null && chosenWhileRunning
        running = true
    }

    /** Çeviri oturumu bitti. */
    fun endSession() = synchronized(lock) { running = false }

    /** Kart gösterilmeli mi: ayar açık, bu oturumda sorulmadı, oyun hiçbir yoldan bilinmiyor ve çeviri iki dakikadır sürüyor. */
    fun shouldAsk(runningForMs: Long, enabled: Boolean): Boolean = synchronized(lock) {
        enabled && !asked && console == null && pack == null && chosen == null && runningForMs >= ASK_AFTER_MS
    }

    /** Kart gösterildi ya da "Sorma"ya basıldı: bu oturumda bir daha sorulmaz. */
    fun markAsked() = synchronized(lock) { asked = true }

    /**
     * GTA 6 telefonu yalnız oyun GTA 6 olarak bilinince aranır. Telefon çevirisi açık, çeviri iki dakikadır sürüyor ve oyun
     * hiçbir yoldan bilinmiyorsa oturumda bir kez true: günlüğe [PHONE_IDLE_LOG] yazılır (#1443: telefon hiç aranmıyordu,
     * günlükte tek satır yoktu). Windows, Mac ve iPhone ile aynı kural.
     */
    fun shouldLogPhoneIdle(runningForMs: Long, readsPhone: Boolean): Boolean = synchronized(lock) {
        if (!readsPhone || phoneIdleLogged || console != null || pack != null || chosen != null || runningForMs < ASK_AFTER_MS) return false
        phoneIdleLogged = true
        true
    }

    /**
     * Xbox çevirisi başladı. Xbox çalışan oyunu bildirmez: oyun başka yoldan bilinmiyorsa kullanıcının Xbox için son seçtiği
     * oyun ([lastChosen]) kendiliğinden kullanılır ([Source.REMEMBERED]; ana ekranda görünür, değiştirilebilir). Hiç seçim
     * yoksa oyuna özel okumalar (GTA 6 telefonu) kapalı kalır. Günlüğe yazılacak tek satırı döndürür (Windows, Mac, iPhone
     * ile aynı metin).
     */
    fun startXbox(lastChosen: String?): String = synchronized(lock) {
        val game = RunningGame.named(lastChosen)
        if (console == null && chosen == null && pack == null && game != null) {
            chosen = game
            carried = true
            chosenWhileRunning = true
            asked = true
        }
        val name = (console ?: chosen ?: pack)?.name
        if (name == null) XBOX_UNKNOWN_LOG else xboxRecalledLog(name)
    }

    companion object {
        /** Bakılan son satır sayısı ve tanımak için aynı paketten gelmesi gereken satır sayısı. */
        const val WINDOW = 20
        const val THRESHOLD = 5
        /** Çeviri başladıktan bu kadar sonra oyun hâlâ bilinmiyorsa sorulur. */
        const val ASK_AFTER_MS = 120_000L
        /** Oyunu bilinmeyen satırların ortak paketi (server/pool/src/autopack.js GENERAL): bir oyun değildir. */
        const val GENERAL_PACK = "pool-genel"
        /** Xbox'ta son seçilen oyunun saklandığı ad (Xbox'un adından bağımsız, Xbox'a özel). */
        const val XBOX_CONSOLE = "Xbox"
        const val PHONE_IDLE_LOG = "telefon aranmıyor: oynanan oyun bilinmiyor (PS5 bildirmedi, okunan satırlar bir oyun paketiyle eşleşmedi); GTA 6 telefonu için ana ekrandan oyunu seçin"
        /** Oyun okunan satırlardan tanındı (paketler kapalıyken de, #1443). */
        fun recognizedLog(name: String) = "oyun okunan satırlardan tanındı: $name"
        const val XBOX_UNKNOWN_LOG = "Xbox: oyun tanınmadı, oyuna özel okumalar (telefon) kapalı"
        fun xboxRecalledLog(name: String) = "Xbox: son seçilen oyun kullanılıyor: $name"
        fun xboxChosenLog(name: String) = "Xbox: oyun elle seçildi: $name"

        /** Kimliğiyle toplanmış otomatik paket ("pool-ppsa01234", "pool-cusa00419-00") oyunun kimliğini taşır. */
        fun titleIdFromPack(id: String): String? =
            if (!id.startsWith("pool-")) null else RunningGame.normalizedTitleId(id.removePrefix("pool-").replace('-', '_'))
    }
}

/**
 * Oyun adının karşılaştırma anahtarı (sunucudaki server/pool/src/games.js gameKey ile aynı): küçük harf, aksansız, noktalama
 * yok, Roma rakamı sayıya, bilinen uzun adlar kısaltmaya. "Grand Theft Auto VI" ve "GTA 6" → "gta 6".
 */
object GameName {
    private val ALIASES = listOf(
        "grand theft auto" to "gta", "call of duty" to "cod", "red dead redemption" to "rdr", "ea sports fc" to "fc",
        "ea sports" to "",
    )
    private val ROMAN = mapOf(
        "ii" to "2", "iii" to "3", "iv" to "4", "v" to "5", "vi" to "6", "vii" to "7", "viii" to "8", "ix" to "9",
        "x" to "10", "xi" to "11", "xii" to "12", "xiii" to "13", "xiv" to "14", "xv" to "15", "xvi" to "16",
    )

    fun key(value: String): String {
        // Marka işaretleri önce atılır (NFKD "™"yi "TM" yapar).
        val folded = Normalizer.normalize(value.replace(Regex("[™®©]"), " "), Normalizer.Form.NFKD).lowercase(Locale.ROOT)
        val text = StringBuilder()
        var previous = 0
        var index = 0
        while (index < folded.length) {
            var cp = folded.codePointAt(index)
            index += Character.charCount(cp)
            val type = Character.getType(cp)
            if (type == Character.NON_SPACING_MARK.toInt() || type == Character.COMBINING_SPACING_MARK.toInt() ||
                type == Character.ENCLOSING_MARK.toInt()) continue
            if (cp == '\''.code || cp == '’'.code || cp == '`'.code) continue
            if (cp == 'ı'.code) cp = 'i'.code
            if (cp == '&'.code) {
                text.append(" and ")
                previous = ' '.code
                continue
            }
            val alphanumeric = Character.isLetter(cp) || Character.isDigit(cp)
            if (!alphanumeric) cp = ' '.code
            // "gta6" → "gta 6" (harf ve rakam ayrılır).
            if (alphanumeric && ((Character.isLetter(previous) && Character.isDigit(cp)) ||
                    (Character.isDigit(previous) && Character.isLetter(cp)))) text.append(' ')
            text.appendCodePoint(cp)
            previous = cp
        }
        val rawWords = text.split(' ').filter { it.isNotEmpty() }
        // Preserve literal franchise letters but keep established Roman sequel keys.
        val megaManX = rawWords.take(3) == listOf("mega", "man", "x")
        var words = rawWords.mapIndexed { i, w ->
            val next = rawWords.getOrNull(i + 1)
            val literal = (w == "x" && ((megaManX && i == 2) || next == "men")) ||
                (w == "v" && next == "rally")
            if (literal) w else ROMAN[w] ?: w
        }
        if (words.size > 1 && words.first() == "the") words = words.drop(1)
        var joined = " " + words.joinToString(" ") + " "
        for ((long, short) in ALIASES) joined = joined.replace(" $long ", if (short.isEmpty()) " " else " $short ")
        return joined.split(' ').filter { it.isNotEmpty() }.joinToString(" ").take(80).trim()
    }
}

/** "Hangi oyunu oynuyorsunuz?" kartının önerileri: son oynanan, kurulu paketlerin oyunları ve popüler oyunlar. */
object GameCatalog {
    /** Paketi olmayan ama çok oynanan ya da yeni çıkan oyunlar (Mac, iPhone ve Windows'ta aynı liste). */
    val POPULAR = listOf(
        "Grand Theft Auto VI", "Grand Theft Auto V", "Red Dead Redemption 2", "Ghost of Yōtei", "Marvel's Spider-Man 2",
        "Death Stranding 2: On the Beach", "Elden Ring", "Elden Ring Nightreign", "Assassin's Creed Shadows",
        "Call of Duty: Black Ops 7", "Call of Duty: Black Ops 6", "Battlefield 6", "EA Sports FC 26",
        "Mafia: The Old Country", "The Last of Us Part II Remastered", "God of War Ragnarök", "Cyberpunk 2077",
        "Hogwarts Legacy", "Resident Evil Requiem", "Silent Hill f", "Metal Gear Solid Delta: Snake Eater", "Borderlands 4",
        "Kingdom Come: Deliverance II", "Clair Obscur: Expedition 33", "Final Fantasy VII Rebirth", "Stellar Blade",
        "Black Myth: Wukong", "Baldur's Gate 3", "Horizon Forbidden West", "Alan Wake 2",
        "Indiana Jones and the Great Circle", "Dying Light: The Beast", "Ghost of Tsushima", "Star Wars Outlaws",
        "The Witcher 3: Wild Hunt", "Monster Hunter Wilds", "Split Fiction", "Hollow Knight: Silksong",
        "Marvel's Wolverine", "Assassin's Creed Mirage", "Assassin's Creed Valhalla", "Assassin's Creed Odyssey",
        "Assassin's Creed Origins", "Call of Duty: Modern Warfare III", "Call of Duty: Modern Warfare II",
        "Call of Duty: Warzone", "Resident Evil 4", "Resident Evil Village", "Resident Evil 2", "Resident Evil 3",
        "Resident Evil 7: Biohazard", "Silent Hill 2", "The Last of Us Part I", "God of War",
    )

    /**
     * Öneriler (en çok [limit]): önce son oynanan, sonra paketlerin oyunları, sonra popüler oyunlar; aynı oyun bir kez. Arama
     * yazılmışsa adı ya da anahtarı aramayı içerenler, adı aramayla başlayanlar önde.
     */
    fun suggestions(query: String, packs: List<String>, last: String?, limit: Int = 8): List<String> {
        val seen = HashSet<String>()
        val all = (listOfNotNull(last) + packs + POPULAR).filter { name -> GameName.key(name).let { it.isNotEmpty() && seen.add(it) } }
        val wanted = GameName.key(query)
        if (wanted.isEmpty()) return all.take(limit)
        val found = all.filter { GameName.key(it).contains(wanted) }
        val (first, rest) = found.partition { GameName.key(it).startsWith(wanted) }
        return (first + rest).take(limit)
    }

    /** Paket listesinden oyun adları (ortak havuz paketi ve asıl paketi olan oyunun "(ek satırlar)" paketi oyun değildir). */
    fun packGames(packs: List<GamePackLibrary.Info>): List<String> =
        packs.filter { it.id != GameSense.GENERAL_PACK && !it.title.endsWith("(ek satırlar)") }.map { it.title }

    /** Havuzdan her gece üretilen ek paketin adındaki ek (server/pool/src/games.js EXTRA_SUFFIX). */
    const val EXTRA_SUFFIX = " (ek satırlar)"

    /**
     * Paketler ekranındaki karolar: oyunun asıl paketi ve havuzdan gelen "(ek satırlar)" paketi tek karoda birleşir
     * (#353: RDR2 ve Spider-Man 2 iki kez görünüyordu). Asıl paketi olmayan ek paket kendi karosunda kalır. Sıra korunur.
     * Mac/iPhone ve Windows'taki GameCatalog.packShelf ile aynı.
     */
    fun <T> packShelf(packs: List<T>, id: (T) -> String, title: (T) -> String, entries: (T) -> Int): List<PackShelfItem> {
        val items = mutableListOf<PackShelfItem>()
        val index = HashMap<String, Int>()
        for (pack in packs.filter { !title(it).endsWith(EXTRA_SUFFIX) }) {
            index.putIfAbsent(GameName.key(title(pack)), items.size)
            items += PackShelfItem(id(pack), title(pack), entries(pack), listOf(id(pack)), listOf(title(pack)))
        }
        for (pack in packs.filter { title(it).endsWith(EXTRA_SUFFIX) }) {
            val at = index[GameName.key(title(pack).removeSuffix(EXTRA_SUFFIX))]
            if (at != null) {
                val main = items[at]
                items[at] = main.copy(entries = main.entries + entries(pack), packIds = main.packIds + id(pack), titles = main.titles + title(pack))
            } else {
                items += PackShelfItem(id(pack), title(pack), entries(pack), listOf(id(pack)), listOf(title(pack)))
            }
        }
        val order = HashMap<String, Int>()
        packs.forEachIndexed { i, pack -> order.putIfAbsent(id(pack), i) }
        return items.sortedBy { order[it.id] ?: 0 }
    }

    fun packShelf(packs: List<GamePackLibrary.Info>): List<PackShelfItem> = packShelf(packs, { it.id }, { it.title }, { it.entries })
}

/** Paketler ekranında bir oyun: kimliği ve adı asıl paketin; satır sayısı ve kimlikler ek paketle birlikte. */
data class PackShelfItem(val id: String, val title: String, val entries: Int, val packIds: List<String>, val titles: List<String>)
