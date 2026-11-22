// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

/**
 * HDMI sinyali değişirken TV'nin kendi giriş ekranı CouchSubs'ı önden itince ekranın geri alınıp alınmayacağı (#794).
 *
 * GitHub #794 (birden çok Android TV): "uygulamayı açtık; PlayStation açılınca, TV'de HDR devreye girince ya da kenarda bir
 * bildirim gelince normal HDMI girişine geçiyor, uygulamaya yeniden girmek gerekiyor". PS5 açılınca ya da görüntü biçimi
 * (HDR, çözünürlük) değişince TV sistemi kendi HDMI oynatıcısını öne çekiyor (tahmin: HDMI-CEC "etkin kaynak" ya da
 * üreticinin giriş uygulaması; TV'den TV'ye değişiyor). Bu, kullanıcının çıkması değildir: görüntü uygulamada zaten
 * gelmişse ve ekran sinyal olayından hemen sonra önden çekildiyse CouchSubs kısa süre sonra kendini yeniden öne getirir.
 *
 * Kullanıcının kendisi çıkmasıyla karışmasın diye:
 * - yalnız TvView'in sinyal olayından (görüntü geldi/gitti, bağlantı koptu, görüntü boyu ya da görüntü izi gerçekten
 *   değişti) en çok {@link #SIGNAL_WINDOW_MS} sonra;
 * - CouchSubs'ın kendi açtığı girişin ilk {@link #AFTER_TUNE_MS}'sindeki olaylar sayılmaz (açılışta Ana tuşu);
 * - kullanıcı ekran çekilmeden hemen önce ({@link #USER_KEY_MS} içinde) kumandada bir tuşa bastıysa sayılmaz;
 * - dakikada en çok {@link #MAX_PER_MINUTE} kez (TV ile sonsuz itişme olmasın).
 *
 * X'te bildirildi (TCL Google TV, 0.9.56 sonrası): "son güncellemeden sonra ayarlar tuşu uygulamadan atıyor". Tahmin (kod;
 * gerçek TV'de doğrulanmadı): bazı TV'ler görüntü değişmeden de boy/iz olayı gönderiyor (onVideoSizeChanged aynı boyla,
 * onTracksChanged aynı izlerle). Ayarlar tuşu hızlı ayarlar panelini açınca ekran o olaydan hemen sonra önden çekilmiş
 * oluyor, panel devralma sayılıyordu: CouchSubs 0,8 sn sonra kendini panelin üstüne getiriyor, birkaç denemede hak dolunca
 * katmana geçip ekranını kapatıyordu (uygulamadan atılma). Artık boy/iz olayı yalnız gerçekten değiştiyse sayılır ve
 * kullanıcının bastığı tuştan hemen sonraki çekilme devralma değildir.
 *
 * Android'e bağlı değildir; zaman dışarıdan verilir (bkz. ScreenReclaimTest).
 */
final class ScreenReclaim {
    static final long SIGNAL_WINDOW_MS = 3_000;
    static final long AFTER_TUNE_MS = 3_000;
    static final int MAX_PER_MINUTE = 3;
    /** Ekran önden çekildikten sonra geri alınmadan önce beklenen süre (TV'nin ekranı açılmasını bitirsin). */
    static final long DELAY_MS = 800;
    /** Ekran bundan kısa süre önce basılan tuştan sonra çekildiyse kullanıcı kendisi bir şey açmıştır (Ayarlar, Giriş). */
    static final long USER_KEY_MS = 2_000;

    private long lastSignal = -1;
    private long lastKey = -1;
    private final long[] reclaims = new long[MAX_PER_MINUTE];
    private int next;
    private int width = -1;
    private int height = -1;
    private String tracks;

    ScreenReclaim() {
        java.util.Arrays.fill(reclaims, -1);
    }

    /** TvView bir sinyal olayı bildirdi; tunedAt: CouchSubs girişi en son ne zaman açtı (-1: açmadı). */
    void signal(long now, long tunedAt) {
        if (tunedAt >= 0 && now - tunedAt < AFTER_TUNE_MS) return;
        lastSignal = now;
    }

    /** Görüntü boyu bildirildi: yalnız önceki bildirimden farklıysa sinyal olayıdır (giriş açılınca ilk bildirim sayılmaz). */
    void videoSize(long now, long tunedAt, int newWidth, int newHeight) {
        boolean known = width >= 0;
        boolean changed = newWidth != width || newHeight != height;
        width = newWidth;
        height = newHeight;
        if (known && changed) signal(now, tunedAt);
    }

    /** Görüntü izleri bildirildi (imza: görüntü izlerinin kimliği, boyu, kare hızı): yalnız değiştiyse sinyal olayıdır. */
    void videoTracks(long now, long tunedAt, String signature) {
        boolean known = tracks != null;
        boolean changed = !signature.equals(tracks);
        tracks = signature;
        if (known && changed) signal(now, tunedAt);
    }

    /**
     * Giriş yeniden açıldı: görüntü boyu ve izleri yeniden öğrenilir. Girişi açtıran tuş (seçicide 1-4) sonraki çekilmeyi
     * kullanıcının işi saydırmaz: bazı TV'ler girişi 1-2 sn sonra kendi oynatıcısında açar (#42), o devralmadır.
     */
    void tuned() {
        width = -1;
        height = -1;
        tracks = null;
        lastKey = -1;
    }

    /** Kullanıcı kumandada bir tuşa bastı (ekran öndeyken). */
    void userKey(long now) {
        lastKey = now;
    }

    /** Ekran pausedAt'te önden çekildi: hemen önce kullanıcı bir tuşa basmış mıydı. */
    boolean userActedBefore(long pausedAt) {
        return lastKey >= 0 && pausedAt >= lastKey && pausedAt - lastKey <= USER_KEY_MS;
    }

    /** Ekran önden çekilince ne yapılacağı. */
    enum Action {
        /** Devralma değil (kullanıcı çıktı ya da sinyal olayı yok): eski davranış. */
        NONE,
        /** CouchSubs ekranı geri öne getirilir. */
        RECLAIM,
        /**
         * Devralma ama dakikadaki geri alma hakkı doldu (TV sürekli geri itiyor): izin varsa katmana geçilir. Yoksa
         * CouchSubs arkada kalır; altyazı bağlantısı açık olduğundan bilgisayar/telefon TV'yi "bağlı" görür ama
         * yazı görünmeyen ekrana çizilir (bkz. MainActivity.onStop).
         */
        GIVE_UP
    }

    /**
     * Ekran önden çekildi (onPause anı, pausedAt): ne yapılsın. played: görüntü bu açılışta uygulamada geldi mi.
     * RECLAIM dönerse geri alma sayılır.
     */
    Action onTakenAway(long pausedAt, boolean played) {
        if (!played || lastSignal < 0 || pausedAt < lastSignal || pausedAt - lastSignal > SIGNAL_WINDOW_MS) return Action.NONE;
        // Aynı sinyal olayı ikinci kez sayılmaz.
        lastSignal = -1;
        // Kullanıcı kendisi bir şey açtı (Ayarlar tuşuyla hızlı ayarlar, Giriş tuşu): geri alınmaz, katmana da geçilmez.
        if (userActedBefore(pausedAt)) return Action.NONE;
        long oldest = reclaims[next];
        if (oldest >= 0 && pausedAt - oldest < 60_000) return Action.GIVE_UP;
        reclaims[next] = pausedAt;
        next = (next + 1) % MAX_PER_MINUTE;
        return Action.RECLAIM;
    }

    boolean shouldReclaim(long pausedAt, boolean played) {
        return onTakenAway(pausedAt, played) == Action.RECLAIM;
    }
}
