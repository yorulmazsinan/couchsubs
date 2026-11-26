// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.service

import com.couchsubs.mobile.core.ShownPair
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/** Okuma hattının arayüze gösterdiği durum (servis yazar, ekranlar okur). */
data class LiveStatus(
    val pairing: com.couchsubs.mobile.core.SubtitlePairing.Ticket? = null,
    val legacyTv: Boolean = false,
    val running: Boolean = false,
    /** Deneme modu: görüntü konsoldan değil uygulamadaki örnek karelerden (bkz. TranslationService.startDemo). */
    val demo: Boolean = false,
    /** Kısa durum metni: "PS5'e bağlanılıyor…", "Altyazılar okunuyor" gibi. */
    val phase: String = "",
    /** Konsol görüntüsü geliyor (oturum Streaming); arayüz [phase] metnini karşılaştırmak yerine buna bakar. */
    val streaming: Boolean = false,
    /** Bağlantının gittiği an (duvar saati, ms; bağlıyken null): "Yeniden bağlan" düğmesi (bkz. ReconnectOffer). */
    val notLiveSince: Long? = null,
    /** Oturum yeniden denemeyi bıraktı: "Yeniden bağlan" hemen görünür. */
    val gaveUp: Boolean = false,
    val connectedTvs: Int = 0,
    /**
     * TV bağlantısı çeviri sürerken koptu ya da TV alındı göndermeyi bıraktı (SubtitleServer.onTvStale); TV yeniden
     * bağlanana, çeviri durana ya da TranslationService.TV_RECONNECT_MS dolana kadar "yeniden bağlanılıyor" gösterilir.
     */
    val tvReconnecting: Boolean = false,
    /** TV uygulamasını kendiliğinden açmanın son denemesi neden olmadı (ana ekranda tek satır); açıldıysa null. */
    val tvOpenProblem: com.couchsubs.mobile.tv.TvOpenProblem? = null,
    /** Son gösterilen çeviriler, yeniden eskiye. */
    val recent: List<ShownPair> = emptyList(),
    /** Telefon ekranında şu an gösterilen altyazı (yoksa boş). */
    val current: String = "",
    /** Telefon ekranında güncelin üstünde soluk duran önceki altyazı (yoksa boş). */
    val previous: String = "",
    /** Telefon ekranındaki ek alan çevirileri (görev, telefon, bildirim). */
    val regions: List<com.couchsubs.mobile.core.SubtitleEvent.Region> = emptyList(),
    /** "Ekranı çevir" sonuçları (telefon ekranında yazının kendi yerinde); yoksa boş. */
    val screen: List<com.couchsubs.mobile.core.ScreenTranslation.Item> = emptyList(),
    /** "Ekranı çevir" düğmesinin durumu: çeviri sürüyor ya da sonuçlar ekranda. */
    val screenState: LiveStatus.ScreenState = LiveStatus.ScreenState.IDLE,
    /** Son satırı veren oyun paketinin başlığı (ör. "GTA V"); paket kullanılmadıysa null. */
    val packInUse: String? = null,
    val error: String? = null,
    val framesReceived: Long = 0,
    /** Görüntünün bu bağlantıda ilk geldiği an (duvar saati, ms); bağlı değilken null. */
    val framesSince: Long? = null,
    /** Görüntü bir dakikadır geliyor ama tek satır gösterilmedi: "oyunun kendi altyazısını açın" (bkz. SubtitleOffTip). */
    val subtitleOffTip: Boolean = false,
    /** GTA 6 telefonu ayarı kapalıyken telefon listesi altyazı yolunda atıldı: "Telefon çevirisi kapalı, açmak ister misiniz?". */
    val gamePhoneHint: Boolean = false,
    /** Okumanın başladığı an (duvar saati, ms); süre göstergesi için. */
    val startedAt: Long = 0,
    /** Seçili çeviri motorunun görünen adı ("DeepL", "Ücretsiz"). */
    val engineLabel: String = "",
    /**
     * Çevrimiçi motor (DeepL, yapay zekâ, yerel model) şu an çeviremiyor: nedeni (anahtar, kota, ağ) ana ekranda söylenir;
     * düzelince null (GitHub #1322; Mac, iPhone ve Windows'taki "… şu an çevirmiyor" uyarısıyla aynı).
     */
    val onlineIssue: com.couchsubs.mobile.translation.OnlineKeyState? = null,
    /** Bu oturumda gösterilen satır ve paketten gelenler. */
    val shownLines: Int = 0,
    val packLines: Int = 0,
    /** Oynanan oyun (PS5'in bildirdiği, paketten tanınan ya da seçilen; bkz. [PlayedGame]); bilinmiyorsa null. */
    val game: String? = null,
    /** "Hangi oyunu oynuyorsunuz?" kartı açık. */
    val askingGame: Boolean = false,
    /**
     * Xbox'ta çeviri sürüyor ve oyun bilinmiyor: Xbox oynanan oyunu bildirmez; Oyun satırı vurgulanır ve "oyunu seçin" notu
     * görünür (zorlayıcı kart açılmaz). Oyun seçilince kalkar (Mac/iPhone GameChoice.xboxNeedsGame, Windows ile aynı).
     */
    val xboxNeedsGame: Boolean = false,
    /** Uygulanan alan profilinin oyunu (bkz. [PlayedGame.areas]); genel alanlarda null. */
    val areaProfileGame: String? = null,
    /** Paketten tanınan oyunun kayıtlı alanları önerildi: "X için kayıtlı alanlar var. Kullanılsın mı?". */
    val offeredAreaProfileGame: String? = null,
    /** Alanların kaydedilebileceği oyun (çeviri sürüyor ve oyun biliniyor). */
    val areaProfileTarget: String? = null,
    /** Hedef oyunun kayıtlı alanları var ama uygulanmadı: "X için kaydet" yerine "Kayıtlı alanları kullan". */
    val areaProfileTargetSaved: Boolean = false,
    /** Alanlar profilden geldi ya da geri döndü: açık Ayarlar ekranı alanları yeniden okur. */
    val areasVersion: Int = 0,
    /** Oyun profilleri listesi değişti (eklendi, adı değişti, silindi, seçildi). */
    val profilesVersion: Int = 0,
) {
    /**
     * Sunucunun olayı telefon ekranına: yeni satır öncekini üste iter; aynı cümlenin uzamış ya da düzelmiş okuması
     * (`replaces`) öncekinin yerine geçer, üste yığılmaz (TV ve iPhone ile aynı). Temizlenince ekran boşalır.
     */
    enum class ScreenState { IDLE, WORKING, SHOWN }

    /** Kare sayacı güncellendi ([now]: duvar saati, ms): görüntü süresi ve "altyazıyı açın" ipucu yeniden hesaplanır. */
    fun withFrames(frames: Long, now: Long): LiveStatus {
        val since = com.couchsubs.mobile.remoteplay.SubtitleOffTip.framesSince(framesSince, streaming, framesReceived, frames, now)
        return copy(framesReceived = frames, framesSince = since,
            subtitleOffTip = running && !demo &&
                com.couchsubs.mobile.remoteplay.SubtitleOffTip.visible(streaming, shownLines > 0, since?.let { now - it }))
    }

    /** Bağlantı durumu değişti: koptuysa görüntü süresi baştan sayılır, ipucu kalkar. */
    fun withStreaming(streaming: Boolean): LiveStatus =
        if (streaming) copy(streaming = true) else copy(streaming = false, framesSince = null, subtitleOffTip = false)

    fun phoneEvent(event: com.couchsubs.mobile.core.SubtitleEvent): LiveStatus = when (event) {
        is com.couchsubs.mobile.core.SubtitleEvent.Subtitle ->
            copy(current = event.text, previous = if (event.replaces || current.isEmpty()) previous else current)
        com.couchsubs.mobile.core.SubtitleEvent.Cleared -> copy(current = "", previous = "")
        // Ek alanın çevirisi telefon ekranında da kendi yerinde küçük kutuda görünür (boş metin kutuyu kaldırır).
        is com.couchsubs.mobile.core.SubtitleEvent.Region ->
            copy(regions = regions.filter { it.id != event.id } + listOfNotNull(event.takeIf { it.text.isNotEmpty() }))
        com.couchsubs.mobile.core.SubtitleEvent.RegionsCleared -> copy(regions = emptyList())
        // Sunucu ekran çevirisini kendisi de yeniden gönderir (ScreenPresence: özgün yazı geri gelince). Kaldırılmış (IDLE)
        // çeviri bu olayla geri gelmez; yoksa düğme yeniden "Çevirileri kaldır" olup basınca ekranı baştan çeviriyordu (#1182).
        is com.couchsubs.mobile.core.SubtitleEvent.Screen ->
            if (screenState == ScreenState.IDLE) this else copy(screen = event.items, screenState = ScreenState.SHOWN)
        com.couchsubs.mobile.core.SubtitleEvent.ScreenCleared -> copy(screen = emptyList(), screenState = ScreenState.IDLE)
    }
}

object LiveState {
    private const val RECENT = 20
    private val state = MutableStateFlow(LiveStatus())
    val status: StateFlow<LiveStatus> = state

    fun update(change: (LiveStatus) -> LiveStatus) = state.update(change)

    fun shown(pair: ShownPair, packTitle: String?) = state.update {
        // Paketten gelen son satırın oyunu, oturum boyunca "… paketi kullanılıyor" olarak kalır.
        it.copy(recent = (listOf(pair) + it.recent).take(RECENT), packInUse = packTitle ?: it.packInUse,
            shownLines = it.shownLines + 1, packLines = it.packLines + if (pair.origin == "paket") 1 else 0,
            subtitleOffTip = false)
    }
}
