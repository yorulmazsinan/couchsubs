// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.service

import com.couchsubs.mobile.core.GameAreas
import com.couchsubs.mobile.core.GameCatalog
import com.couchsubs.mobile.core.GameName
import com.couchsubs.mobile.core.GamePackLibrary
import com.couchsubs.mobile.core.GameSense
import com.couchsubs.mobile.core.RunningGame
import com.couchsubs.mobile.core.restoreAreas
import com.couchsubs.mobile.settings.AppSettings

/**
 * Oynanan oyun: servisin okuma hattı ile ekranlar arasında (Mac ve iPhone'daki GameChoice ile aynı davranış). Servis
 * satırları ve PS5'in bildirdiğini verir, ekran kartı ([LiveStatus.askingGame]) ve "Oynanan oyun: X · Değiştir" satırını
 * ([LiveStatus.game]) gösterir. Seçim oturum boyunca geçerlidir ve PS5'in adıyla saklanır; aynı PS5'te sonraki oturumda
 * kartın ilk önerisi olur.
 */
object PlayedGame {
    val sense = GameSense()
    @Volatile private var console: String? = null
    @Volatile private var xbox = false
    /** Günlük satırı (servis logcat'e bağlar): Xbox'ta oyunun tanınmadığı ya da elle seçildiği. */
    @Volatile var log: (String) -> Unit = {}
    @Volatile private var settings: AppSettings? = null
    @Volatile private var startedAt = 0L
    @Volatile private var last: RunningGame? = null
    /** Günlüğe son yazılan paket sınırı ([GameName.key]). */
    @Volatile private var loggedLimit: String? = null
    /** Oyun değişti (servis havuza ve paket sunucusuna bağlar); oturum yokken null. */
    @Volatile var onChange: ((RunningGame?) -> Unit)? = null
    /**
     * Oyuna göre alanlar: oyun değişince kayıtlı alanlar uygulanır ya da önerilir (bkz. [GameAreas]). Ekranlar
     * [LiveStatus.areaProfileGame], [LiveStatus.offeredAreaProfileGame] ve [LiveStatus.areaProfileTarget]'ı okur.
     */
    val areas: GameAreas = GameAreas(changed = { publishAreas() }).also {
        // Ayarlar'da oyun profili seçilince ya da yeni profil açılınca oynanan oyun o olur.
        it.onChoose = { name -> choose(name) }
    }

    private fun publishAreas() {
        val state = areas
        LiveState.update {
            val game = state.activeGame
            it.copy(areaProfileGame = game, offeredAreaProfileGame = state.offeredGame, areaProfileTarget = state.target,
                areaProfileTargetSaved = state.targetHasOtherProfile,
                // Çeviri dururken Ayarlar'da profil seçilince de alanlar değişir.
                areasVersion = if (game != it.areaProfileGame || !state.running) it.areasVersion + 1 else it.areasVersion,
                profilesVersion = it.profilesVersion + 1)
        }
    }

    /** Kurulu paketlerin oyun adları (öneriler için). */
    @Volatile var packTitles: () -> List<String> = { emptyList() }
    /** Hazır paketler: kullanıcı elle oyun seçince satırlar yalnız o oyunun paketinde aranır ([GameSense.packLimit], #218). */
    @Volatile var packs: GamePackLibrary? = null
        set(value) {
            field = value
            value?.limitToGame(sense.packLimit)
            // Yeni kitaplık (yeni oturum): sınır yeniden yazılır.
            loggedLimit = null
            logLimit()
        }

    /** Seçilen oyunda hangi paketlerde aranacağı, değişince günlüğe bir kez (#1355: içe aktarılan paket okunuyor mu?). */
    private fun logLimit() {
        val library = packs ?: return
        val limit = sense.packLimit
        val key = limit?.let { GameName.key(it) }
        if (key == loggedLimit) return
        loggedLimit = key
        library.limitLog(limit)?.let { log(it) }
    }

    /**
     * Çeviri başladı. [xbox]: Xbox oturumu; Xbox çalışan oyunu bildirmez, son oyun [GameSense.XBOX_CONSOLE] adıyla
     * hatırlanır ve oyun bilinmiyorsa kendiliğinden kullanılır.
     */
    fun start(console: String, settings: AppSettings, startedAt: Long, xbox: Boolean = false) {
        sense.startSession()
        this.xbox = xbox
        this.console = if (xbox) GameSense.XBOX_CONSOLE else console
        this.settings = settings
        if (xbox) log(sense.startXbox(settings.lastGame(GameSense.XBOX_CONSOLE)))
        this.startedAt = startedAt
        last = null
        LiveState.update { it.copy(askingGame = false) }
        // Uygulama oturum sürerken kapandıysa oyunun profili açık kalmış olabilir: önce genel alanlar geri gelir.
        settings.restoreAreas()
        areas.start(settings)
        publish()
    }

    /** Çeviri durdu: kart kapanır, oyun havuza artık gitmez. */
    fun stop() {
        sense.endSession()
        onChange = null
        // Bitmiş oturumun paket kitaplığı (bütün paketler açılmış hâlde) burada tutulmaz: tutulursa sonraki oturum yeni
        // kitaplığı eskisi bellekteyken açar, büyük pakette (GTA 6) bellek yetmez ve oturum paketsiz sürer (#1282).
        packs = null
        packTitles = { emptyList() }
        xbox = false
        areas.stop()
        LiveState.update { it.copy(askingGame = false, xboxNeedsGame = false) }
    }

    /** Servis periyodik olarak sorar (15 saniyede bir): süre doldu ve oyun bilinmiyorsa kart açılır. */
    fun checkAsk(now: Long) {
        val settings = settings ?: return
        if (!sense.shouldAsk(now - startedAt, settings.askGame && settings.sharePool)) return
        sense.markAsked()
        LiveState.update { it.copy(askingGame = true) }
    }

    /** Ekrana bir satır geldi; [fromPack]: hazır paketten. */
    fun noteLine(fromPack: Boolean, library: GamePackLibrary) {
        val hit = library.takeDistinctiveHit()
        val pack = if (fromPack) hit else null
        if (!sense.noteLine(pack?.id, pack?.title)) return
        LiveState.update { it.copy(askingGame = false) }
        publish()
    }

    /** PS5'in keşif yanıtındaki oyun (yoksa null). */
    fun consoleReported(game: RunningGame?) {
        sense.setConsole(game)
        publish()
    }

    /** Kullanıcı bir oyun seçti ya da adını yazdı. */
    fun choose(name: String) {
        val clean = RunningGame.normalizedName(name) ?: return
        sense.choose(clean)
        val console = console
        val settings = settings
        if (console != null && settings != null) settings.rememberGame(console, clean)
        if (xbox) log(GameSense.xboxChosenLog(clean))
        LiveState.update { it.copy(askingGame = false) }
        publish()
    }

    /** "Değiştir": kart elle açılır. */
    fun ask() {
        sense.markAsked()
        LiveState.update { it.copy(askingGame = true) }
    }

    /** "Sorma": bu oturumda bir daha sorulmaz. */
    fun dismiss() {
        sense.markAsked()
        LiveState.update { it.copy(askingGame = false) }
    }

    /** Bu PS5'te son seçilen oyun. */
    val lastPlayed: String? get() = console?.let { settings?.lastGame(it) }

    fun suggestions(query: String): List<String> = GameCatalog.suggestions(query, packTitles(), lastPlayed)

    private fun publish() {
        packs?.limitToGame(sense.packLimit)
        logLimit()
        val current = sense.current
        val needs = xbox && current == null
        LiveState.update { it.copy(game = current?.name, xboxNeedsGame = needs) }
        areas.follow(current, sense.source)
        if (current == last) return
        last = current
        onChange?.invoke(current)
    }
}
