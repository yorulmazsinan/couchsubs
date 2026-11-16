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
    enum class Source { CONSOLE, PACK, USER }

    private val lock = Any()
    private val recent = ArrayDeque<String?>()
    private val titles = HashMap<String, String>()
    private var console: RunningGame? = null
    private var pack: RunningGame? = null
    private var packId: String? = null
    private var chosen: RunningGame? = null
    private var asked = false

    /** Havuza giden oyun: PS5'in bildirdiği, yoksa kullanıcının seçtiği, yoksa paketten tanınan. */
    val current: RunningGame? get() = synchronized(lock) { console ?: chosen ?: pack }

    val source: Source?
        get() = synchronized(lock) {
            when {
                console != null -> Source.CONSOLE
                chosen != null -> Source.USER
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

    /** PS5'in bildirdiği oyun (keşif yanıtı; bilinmiyorsa null). */
    fun setConsole(game: RunningGame?) = synchronized(lock) { console = game }

    /** Kullanıcının seçimi ("Hangi oyunu oynuyorsunuz?" ya da "Değiştir"); null seçimi siler. */
    fun choose(name: String?) = synchronized(lock) {
        chosen = RunningGame.named(name)
        asked = true
    }

    /** Yeni çeviri oturumu: paket penceresi ve soru sıfırlanır; kullanıcının seçimi uygulama açık kaldıkça kalır. */
    fun startSession() = synchronized(lock) {
        recent.clear()
        pack = null
        packId = null
        console = null
        asked = false
    }

    /** Kart gösterilmeli mi: ayar açık, bu oturumda sorulmadı, oyun hiçbir yoldan bilinmiyor ve çeviri iki dakikadır sürüyor. */
    fun shouldAsk(runningForMs: Long, enabled: Boolean): Boolean = synchronized(lock) {
        enabled && !asked && console == null && pack == null && chosen == null && runningForMs >= ASK_AFTER_MS
    }

    /** Kart gösterildi ya da "Sorma"ya basıldı: bu oturumda bir daha sorulmaz. */
    fun markAsked() = synchronized(lock) { asked = true }

    companion object {
        /** Bakılan son satır sayısı ve tanımak için aynı paketten gelmesi gereken satır sayısı. */
        const val WINDOW = 20
        const val THRESHOLD = 5
        /** Çeviri başladıktan bu kadar sonra oyun hâlâ bilinmiyorsa sorulur. */
        const val ASK_AFTER_MS = 120_000L
        /** Oyunu bilinmeyen satırların ortak paketi (server/pool/src/autopack.js GENERAL): bir oyun değildir. */
        const val GENERAL_PACK = "pool-genel"

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
        var words = text.split(' ').filter { it.isNotEmpty() }.map { ROMAN[it] ?: it }
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

    /** Paket listesinden oyun adları (ortak havuz paketi bir oyun değildir). */
    fun packGames(packs: List<GamePackLibrary.Info>): List<String> =
        packs.filter { it.id != GameSense.GENERAL_PACK }.map { it.title }
}
