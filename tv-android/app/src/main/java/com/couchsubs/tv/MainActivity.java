// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import android.app.Activity;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.media.tv.TvContract;
import android.media.tv.TvInputManager;
import android.media.tv.TvTrackInfo;
import android.media.tv.TvView;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.util.List;

/**
 * İki modda çalışır (bkz. DisplayMode; varsayılan Otomatik: izin varsa katman, yoksa uygulama içi):
 * - Uygulama içinde: HDMI girişini TvView ile tam ekran gösterir; üstünde şeffaf WebView'de LG ve Samsung'la
 *   ortak arayüz çalışır. Görüntü hiç gelmezse (bazı TV'lerde TvView siyah kalıyor) ve izin varsa katmana geçer.
 * - Katman: HDMI'yı TV kendi giriş ekranında gösterir, altyazıyı OverlayService üstte çizer. Bu ekran yalnız servisi
 *   başlatıp kapanır; servis çalışırken CouchSubs yeniden açılırsa katman kapanır.
 *
 * Google Play paketinde katman modu yoktur (BuildConfig.OVERLAY_MODE; bkz. docs/play-store-tv.md): orada yalnız uygulama
 * içinde çalışır, katman gerektiğinde ne yapılacağı anlatılır.
 */
public class MainActivity extends Activity implements TvPage.Host {
    /** Katman servisi uygulamayı kendisi açtı (izin yok ya da bilgisayarda "Uygulama içinde" seçildi). */
    static final String EXTRA_FROM_OVERLAY = "fromOverlay";
    /** Katman açılamadı; neden DisplayMode.FAILED_* (uygulama yeniden katmana geçmez, nedeni gösterir). */
    static final String EXTRA_OVERLAY_FAILED = "overlayFailed";
    private static final String EXTRA_DISPLAY_MODE = "displayMode";
    /** CouchSubs ekranı TV'nin kendi giriş ekranından kendini geri aldı (bkz. ScreenReclaim): ekran ve mod değişmez. */
    private static final String EXTRA_RECLAIM = "reclaim";
    /**
     * Bilgisayar/telefon uygulamayı kapatıp yeniden açmadan önce kibarca kapanmasını ister
     * ({@code am start -n com.couchsubs.tv/.MainActivity --ez exit true}; bkz. {@link #exit()}). #1221: eskiden doğrudan
     * {@code am force-stop} gönderiliyordu; işlem öldürülünce HDMI girişi bırakılmıyor (TvView.reset çalışmıyor),
     * MediaTek'li Philips Google TV'lerde HDMI TV kapatılıp açılana kadar siyah kalıyordu.
     */
    static final String EXTRA_EXIT = "exit";
    private static final long WATCH_EVERY_MS = 1000;
    private static final long HELP_VISIBLE_MS = 25_000;
    /** Giriş seçicide bundan çok düğme varsa yan yana sığmaz, alt alta dizilir. */
    private static final int CHOICES_IN_ROW = 3;

    // design/tokens.json, koyu görünüm (TV her zaman koyu): seçici ve yardım kutusu sayfadaki panelle aynı dilde.
    private static final int SURFACE = 0xFF1C1E23;
    private static final int SURFACE2 = 0xFF25282F;
    private static final int TEXT_PRIMARY = 0xFFF3EEE4;
    private static final int ACCENT = 0xFFF5B83D;
    private static final int ACCENT_HI = 0xFFFFCF6B;
    private static final int ON_ACCENT = 0xFF17181B;
    private static final int BORDER = 0xFF30333A;
    /** Odaktaki düğme biraz büyür: uzaktan bakınca odak yalnız renkle değil boyutla da seçilsin. */
    private static final float FOCUS_SCALE = 1.05f;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private TvView tvView;
    private TvPage page;
    private LinearLayout helpBox;
    private TextView help;
    /** Görüntü gelmeyince açılan giriş seçicinin düğmeleri (her HDMI girişi için bir tane). */
    private LinearLayout choices;
    private boolean pickerShown;
    private boolean pickerClosed;
    private String launchParams = "";
    /** Son açılan HDMI girişi; ekran önden çekilince bırakılır, öne gelince ya da bağlantı kopunca yeniden açılır. */
    private final HdmiSession session = new HdmiSession();
    /** Ekran kullanıcının seçimiyle arka plana gidiyor (onUserLeaveHint: Ana ekran, başka uygulama); bkz. onStop. */
    private boolean userLeaving;
    private int retuneAttempts;
    private final FallbackWatch watch = new FallbackWatch();
    private boolean watching;
    /** Kullanıcı katman açıkken CouchSubs'ı kumandadan açtı: bu ekran kayıtlı tercih katman olsa da uygulama içinde kalır. */
    private boolean leftOverlay;
    /** Ekran önde mi; arka plandayken görüntü izlenmez. */
    private boolean resumed;
    private final Runnable watchTick = this::checkFallback;
    private final Runnable hideHelpTask = this::hideHelp;
    /** Sayfanın WebView işleminin gidişleri (bkz. pageGone). */
    private final PageRestarts pageRestarts = new PageRestarts();
    /** Görüntü geldikten sonraki kesinti: bir kez yeniden açılır, olmazsa söylenir (bkz. PictureOutage). */
    private final PictureOutage outage = new PictureOutage();
    /** Sinyal değişirken TV'nin kendi giriş ekranı öne gelince CouchSubs'ın geri alınması (#794). */
    private final ScreenReclaim reclaim = new ScreenReclaim();
    /** Ekranın son duraklatıldığı an (onPause). */
    private long pausedAt = -1;
    /** Giriş tutulurken (ekran yalnız duraklatılmış) görüntü gitti ya da bağlantı koptu: öne dönünce giriş yeniden açılır. */
    private boolean lostWhilePaused;
    private static final String STATE_LEFT_OVERLAY = "leftOverlay";
    private boolean outageWatching;
    private final Runnable outageTick = this::checkOutage;
    /** Uygulama içi bilerek seçiliyken katmana geçilmedi: ekran öne gelince söylenecek durum (0: yok). */
    private int keptInAppNotice;
    /** Uygulama içi bilerek seçiliyken görüntü gelmedi: giriş seçiciden önce giriş bir kez yeniden açıldı. */
    private boolean inAppRetuned;
    /** Bilgi panelindeki TvView durumu; sayfanın iş parçacığından okunur. */
    private volatile String tvState = "idle";
    /** Bilgi panelinin ses tanısı (bkz. AudioState): TvView'in bildirdiği ses parçası sayısı (-1: henüz yok), seçili mi. */
    private volatile int audioTracks = -1;
    private volatile boolean audioSelected;
    /**
     * Giriş bırakılınca kısa süre sonra bir kez daha bırakılır: oturum o anda kuruluyorsa ilk bırakma onu kaçırabilir ve
     * aynı HDMI'yı tek oturuma veren TV'lerde (Philips, Thomson) TV'nin kendi giriş ekranı siyah kalır (#643, #453).
     * Arada giriş yeniden açıldıysa (sıra numarası değişti) ikinci bırakma çalışmaz. Ekran kapandıktan sonra da çalışsın
     * diye kendi Handler'ındadır.
     */
    private static final long SECOND_RELEASE_MS = 400;
    private static final Handler RELEASE = new Handler(Looper.getMainLooper());
    private int releaseGeneration;

    /** Açık CouchSubs ekranı (yoksa null): bilgisayarın/telefonun adres yayını ona iletilir (bkz. AddressReceiver). */
    private static volatile MainActivity current;

    /** Bilgisayar/telefon adresini bildirdi: açık sayfa o adrese geçer; ekran ve görüntü modu değişmez. */
    static void deliver(String params) {
        MainActivity activity = current;
        if (activity == null) return;
        activity.runOnUiThread(() -> {
            if (activity.page == null || activity.isFinishing()) return;
            activity.launchParams = params;
            activity.page.relaunch(params);
        });
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        current = this;
        Intent intent = getIntent();
        if (intent != null && intent.getBooleanExtra(EXTRA_EXIT, false)) {
            // Kapanma isteği uygulama kapalıyken geldi (ya da yalnız katman çalışıyordu): hiçbir giriş açılmaz, katman da kapanır.
            if (OverlayService.running) OverlayService.stop(this);
            finishAndRemoveTask();
            return;
        }
        launchParams = paramsOf(intent);
        TvPage.storeDisplayMode(this, intent.getStringExtra(EXTRA_DISPLAY_MODE));
        // Ekran sistemce yeniden kurulduysa (ayar değişikliği) kullanıcının katmandan çıktığı unutulmaz: yoksa kayıtlı
        // katman tercihiyle ekran kapanıp katmana geçilirdi.
        if (savedInstanceState != null) leftOverlay = savedInstanceState.getBoolean(STATE_LEFT_OVERLAY, false);

        if (OverlayService.running && !intent.getBooleanExtra(EXTRA_FROM_OVERLAY, false)) {
            if (DisplayMode.whileOverlay(launchParams) == DisplayMode.Relaunch.FORWARD_TO_OVERLAY) {
                // Bilgisayar uygulamayı yeni adresle açtı: katman sürer, adres ona iletilir.
                OverlayService.start(this, launchParams);
                finish();
                return;
            }
            // Kumandadan yeniden açıldı: katman kapanır, CouchSubs ekranı açılır (panel görünsün; eskiden uygulama da
            // kapanıyordu ve kullanıcı ekrana hiç ulaşamıyordu).
            OverlayService.stop(this);
            Toast.makeText(this, R.string.overlay_stopped, Toast.LENGTH_LONG).show();
            leftOverlay = true;
        }

        String preference = TvPage.storedDisplayMode(this);
        DisplayMode.Start start = DisplayMode.atLaunch(preference, overlayAllowed(),
                intent.getStringExtra(EXTRA_OVERLAY_FAILED), leftOverlay);
        if (start == DisplayMode.Start.OVERLAY) {
            if (startOverlay()) {
                if (DisplayMode.AUTO.equals(preference)) tellAutoOverlay();
                return;
            }
            start = DisplayMode.Start.IN_APP_OVERLAY_FAILED;
        }
        showInApp();
        if (start == DisplayMode.Start.IN_APP_NEEDS_PERMISSION) showPermissionHelp(R.string.overlay_permission_needed);
        else if (start == DisplayMode.Start.IN_APP_OVERLAY_FAILED) showOverlayFailed();
    }

    /**
     * Otomatik tercihle katmanda açıldı: kullanıcıya kısa bilgi. TV girişleri uygulamalara açmıyorsa (TV HDMI'ya kendisi
     * geçemez) her seferinde girişin elle seçilmesi söylenir; yoksa yalnız ilk kez, uygulama içine nasıl dönüleceğiyle.
     */
    private void tellAutoOverlay() {
        if (HdmiInputs.list(this).isEmpty()) {
            Toast.makeText(this, R.string.overlay_started_manual_input, Toast.LENGTH_LONG).show();
        } else if (TvPage.firstAutoOverlay(this)) {
            Toast.makeText(this, R.string.overlay_auto, Toast.LENGTH_LONG).show();
        }
    }

    /** Katman açılabilir mi: bu derlemede var (Play paketinde yok) ve "Diğer uygulamaların üzerinde göster" izni verilmiş. */
    private boolean overlayAllowed() {
        return BuildConfig.OVERLAY_MODE && OverlayService.canDrawOverlays(this);
    }

    /**
     * Kendiliğinden (görüntü gelmedi, TV HDMI'yı kendine aldı, geri alma hakkı doldu) katmana geçilebilir mi: izin var ve
     * kullanıcı bilerek Uygulama içinde seçmedi (bkz. DisplayMode.mayAutoSwitch).
     */
    private boolean autoOverlayAllowed() {
        return DisplayMode.mayAutoSwitch(TvPage.storedDisplayMode(this), overlayAllowed());
    }

    /** Katmana geçilebilecekken yalnız kullanıcının Uygulama içinde seçimi yüzünden uygulama içinde kalınıyor. */
    /**
     * Uygulama içi seçili ama TV ekranı geri vermiyor: CouchSubs arkada kalınca altyazı hiç görünmez (X, üç kullanıcı).
     * Katman bu TV'de bozuk bilinmiyorsa ona geçilir (bkz. DisplayMode.rescueToOverlay). Geçildiyse true.
     */
    private boolean rescueToOverlay() {
        if (!DisplayMode.rescueToOverlay(TvPage.storedDisplayMode(this), overlayAllowed(), TvPage.overlayBroken(this))) {
            return false;
        }
        switchToOverlay(R.string.in_app_rescued_overlay);
        return isFinishing();
    }

    private boolean keptInApp() {
        return DisplayMode.keptInApp(TvPage.storedDisplayMode(this), overlayAllowed());
    }

    private void showInApp() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        if (getSystemService(TV_INPUT_SERVICE) != null) {
            tvView = new TvView(this);
            tvView.setCallback(new TvView.TvInputCallback() {
                @Override public void onConnectionFailed(String inputId) {
                    signalChanged();
                    tvState = "connection failed";
                    noVideo();
                    lostPicture();
                    retuneLater();
                }
                @Override public void onDisconnected(String inputId) {
                    signalChanged();
                    tvState = "disconnected";
                    noVideo();
                    lostPicture();
                    retuneLater();
                }
                @Override public void onVideoAvailable(String inputId) {
                    signalChanged();
                    tvState = "available";
                    retuneAttempts = 0;
                    watch.videoAvailable();
                    outage.available();
                    // Görüntü gelen giriş kaydedilir: sonraki açılışta konsol yeniden aranmadan bu açılır (#367).
                    HdmiInputs.remember(MainActivity.this, inputId);
                    hideHelp();
                    keepScreenOn(true);
                    status("playing");
                }
                @Override public void onVideoUnavailable(String inputId, int reason) {
                    signalChanged();
                    tvState = "unavailable: " + reasonName(reason);
                    lostPicture();
                    // PS5 oyuna girerken çözünürlük ya da HDR değiştirir; TV bunu kısa bir "ayarlanıyor" olarak bildirir.
                    // O arada ekran açık kalır, yoksa TV oyunun ortasında boşta sanıp ekran koruyucuya geçer.
                    if (reason == TvInputManager.VIDEO_UNAVAILABLE_REASON_TUNING
                            || reason == TvInputManager.VIDEO_UNAVAILABLE_REASON_BUFFERING) {
                        trouble();
                        return;
                    }
                    noVideo();
                }
                // HDR/çözünürlük değişimi çoğu TV'de bu ikisinden biriyle gelir (#794).
                // Yalnız gerçekten değiştiyse sayılır: bazı TV'ler aynı boyu/izleri yineleyip durur (bkz. ScreenReclaim).
                @Override public void onVideoSizeChanged(String inputId, int width, int height) {
                    if (resumed) reclaim.videoSize(SystemClock.elapsedRealtime(), watch.tunedAt(), width, height);
                }
                @Override public void onTracksChanged(String inputId, List<TvTrackInfo> tracks) {
                    audioTracks = audioTrackCount(tracks);
                    if (resumed) reclaim.videoTracks(SystemClock.elapsedRealtime(), watch.tunedAt(), videoSignature(tracks));
                }
                // Yalnız tanı (bkz. AudioState): TvView ses parçası seçti mi.
                @Override public void onTrackSelected(String inputId, int type, String trackId) {
                    if (type == TvTrackInfo.TYPE_AUDIO) audioSelected = trackId != null;
                }
            });
            // HDMI sesi tam sesle açılır. Android'in HDMI ses yolu (TvInputHardwareManager) uygulama ses düzeyi
            // vermeden 0'da başlar: Sony gibi TV'lerde oyun sesi uygulama açılınca kesiliyordu. TvView bu düzeyi
            // saklar, her yeni oturuma kendisi uygular.
            tvView.setStreamVolume(1f);
            root.addView(tvView);
        }

        page = new TvPage(this, this, launchParams, false);
        root.addView(page.webView);

        helpBox = new LinearLayout(this);
        helpBox.setOrientation(LinearLayout.VERTICAL);
        helpBox.setVisibility(View.GONE);
        // surface %90 saydam, 16 köşe (tokens radius.card); odaktaki düğme büyüyünce kenarda kırpılmasın.
        helpBox.setBackground(rounded((SURFACE & 0x00FFFFFF) | 0xE6000000, 16));
        helpBox.setClipChildren(false);
        helpBox.setClipToPadding(false);
        int pad = Math.round(28 * fitScale());
        helpBox.setPadding(pad, pad, pad, pad);
        help = new TextView(this);
        help.setTextColor(TEXT_PRIMARY);
        help.setTextSize(TypedValue.COMPLEX_UNIT_PX, 30 * fitScale());
        helpBox.addView(help);
        choices = new LinearLayout(this);
        choices.setOrientation(LinearLayout.HORIZONTAL);
        choices.setVisibility(View.GONE);
        choices.setClipChildren(false);
        choices.setClipToPadding(false);
        LinearLayout.LayoutParams choicesLayout = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        choicesLayout.topMargin = pad;
        helpBox.addView(choices, choicesLayout);
        FrameLayout.LayoutParams helpLayout = new FrameLayout.LayoutParams(
                Math.round(1400 * fitScale()), FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        helpLayout.topMargin = Math.round(60 * fitScale());
        root.addView(helpBox, helpLayout);

        setContentView(root);
        preferLowLatency();
        page.load();
        page.webView.requestFocus();
    }

    private static String reasonName(int reason) {
        switch (reason) {
            case TvInputManager.VIDEO_UNAVAILABLE_REASON_UNKNOWN: return "unknown";
            case TvInputManager.VIDEO_UNAVAILABLE_REASON_TUNING: return "tuning";
            case TvInputManager.VIDEO_UNAVAILABLE_REASON_WEAK_SIGNAL: return "weak signal";
            case TvInputManager.VIDEO_UNAVAILABLE_REASON_BUFFERING: return "buffering";
            case TvInputManager.VIDEO_UNAVAILABLE_REASON_AUDIO_ONLY: return "audio only";
            default: return "reason " + reason;
        }
    }

    /**
     * TvView sinyal olayı (görüntü geldi/gitti, boyut/iz değişti, bağlantı koptu). Yalnız ekran öndeyken sayılır: ekran
     * duraklatılınca giriş bırakılır, ondan sonraki olaylar bizimdir (bkz. ScreenReclaim).
     */
    private void signalChanged() {
        if (resumed) reclaim.signal(SystemClock.elapsedRealtime(), watch.tunedAt());
    }

    /** Görüntü izlerinin imzası (kimlik, boy, kare hızı); ses ve altyazı izleri sayılmaz. */
    private static String videoSignature(List<TvTrackInfo> tracks) {
        StringBuilder out = new StringBuilder();
        if (tracks == null) return "";
        for (TvTrackInfo track : tracks) {
            if (track == null || track.getType() != TvTrackInfo.TYPE_VIDEO) continue;
            out.append(track.getId()).append(':').append(track.getVideoWidth()).append('x').append(track.getVideoHeight())
                    .append('@').append(track.getVideoFrameRate()).append(';');
        }
        return out.toString();
    }

    /**
     * Görüntü bir kez geldikten sonra kesildi: kesinti izlenir (bkz. PictureOutage). Görüntü hiç gelmediyse bu iş
     * FallbackWatch'ındır.
     */
    private void lostPicture() {
        // Ekran yalnız duraklatılmışken (üstte panel ya da bildirim, giriş tutuluyor) görüntü gitti: öne dönünce giriş
        // yeniden açılır (bkz. onResume); arada yeniden denenmez, paneli açan TV'nin kendi işine karışılmaz.
        if (!resumed) lostWhilePaused = true;
        if (!resumed || !watch.played()) return;
        outage.lost(SystemClock.elapsedRealtime());
        if (!outageWatching) {
            outageWatching = true;
            handler.postDelayed(outageTick, WATCH_EVERY_MS);
        }
    }

    private void stopOutageWatch() {
        outageWatching = false;
        handler.removeCallbacks(outageTick);
        outage.reset();
    }

    /** Süren kesintide girişi bir kez bırakıp yeniden açar; yine gelmezse giriş seçiciyi ve Katman önerisini gösterir. */
    private void checkOutage() {
        outageWatching = false;
        if (isFinishing() || tvView == null || !resumed || !outage.active()) return;
        long now = SystemClock.elapsedRealtime();
        String id = session.input();
        boolean source = HdmiInputs.hasSource(this, id);
        if (id != null && outage.shouldRetune(now, source)) {
            resetQuietly(tvView);
            tune(id);
        } else if (outage.shouldTell(now, source) && !pickerShown && !pickerClosed) {
            showPicker(true);
        }
        if (outage.pending()) {
            outageWatching = true;
            handler.postDelayed(outageTick, WATCH_EVERY_MS);
        }
    }

    private static void resetQuietly(TvView view) {
        try {
            view.reset();
        } catch (RuntimeException ignored) {
            // Oturum zaten bırakılmış.
        }
    }

    /**
     * HDMI girişini bırakır; kısa süre sonra bir kez daha bırakır (bkz. SECOND_RELEASE_MS). removeView: TvView ekrandan da
     * kaldırılır (çıkışta), yüzeyi de serbest kalsın.
     */
    private void releaseHdmi(boolean removeView, String why) {
        TvView view = tvView;
        if (view == null) return;
        tvState = "released (" + why + ")";
        keepScreenOn(false);
        resetQuietly(view);
        if (removeView) {
            ViewGroup parent = (ViewGroup) view.getParent();
            if (parent != null) parent.removeView(view);
            tvView = null;
        }
        int generation = ++releaseGeneration;
        RELEASE.postDelayed(() -> {
            if (generation == releaseGeneration) resetQuietly(view);
        }, SECOND_RELEASE_MS);
    }

    /** HDMI görüntüsü kesildi ya da gelmiyor. */
    private void noVideo() {
        keepScreenOn(false);
        trouble();
        status("inputError");
    }

    /**
     * Ekran yalnız HDMI görüntüsü oynarken açık tutulur; görüntü yokken (bekleme ekranı, demo, PS5 kapalı) TV kendi ekran
     * koruyucusuna geçebilir (Android TV kalite kuralları TV-BU ve TV-BY).
     */
    private void keepScreenOn(boolean on) {
        if (on) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    /**
     * PS5 TV'ye doğrudan bağlıyken TV HDMI ALLM ile oyun moduna geçer; görüntü bu uygulamanın içinden gelince TV bunu
     * bilemez. Android 11+ TV'lerde pencere "en az görüntü işleme" ister: TV bunu destekliyorsa oyun moduna ya da düşük
     * gecikmeye geçer (Window#setPreferMinimalPostProcessing). Desteklemeyen TV'de hiçbir şey olmaz.
     */
    private void preferLowLatency() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return;
        try {
            getWindow().setPreferMinimalPostProcessing(true);
        } catch (RuntimeException ignored) {
        }
    }

    /** 1920 piksellik sayfa ölçüsünü ekran pikseline çevirir (yardım kutusu sayfayla aynı boyda görünsün). */
    private float fitScale() {
        int width = getResources().getDisplayMetrics().widthPixels;
        int height = getResources().getDisplayMetrics().heightPixels;
        return Math.max(width, height) / 1920f;
    }

    // --- Katmana geçiş ---

    /** Katman servisini başlatıp bu ekranı kapatır; servis başlatılamadıysa ekran açık kalır ve false döner. */
    private boolean startOverlay() {
        if (!OverlayService.start(this, launchParams)) return false;
        finish();
        return true;
    }

    /** Uygulama içinden katmana: TvView girişi bırakır ki TV kendi ekranında açabilsin. */
    private void switchToOverlay(int message) {
        stopWatching();
        stopOutageWatch();
        String previous = session.input();
        releaseHdmi(false, "overlay");
        session.clear();
        if (!startOverlay()) {
            // Katman açılamadı: uygulama kapanmaz, nedeni söylenir, bırakılan giriş yeniden açılır.
            if (previous != null && tvView != null) tune(previous);
            showOverlayFailed();
            return;
        }
        // CouchSubs ekranı kapanır, katman arka planda sürer. TV girişleri uygulamalara açmıyorsa (#275) TV HDMI'ya
        // kendiliğinden geçmez: kullanıcı ana ekranda kalır ve uygulama "kapandı" sanılır. Bu yüzden ne yapılacağı söylenir.
        boolean manualInput = HdmiInputs.list(this).isEmpty();
        Toast.makeText(this, manualInput ? R.string.overlay_started_manual_input : message, Toast.LENGTH_LONG).show();
    }

    /**
     * Uygulama içi seçili olduğu için katmana geçilmedi ve CouchSubs arkada kaldı: hemen kısa yazı (ekran arkadayken de
     * görünür), CouchSubs yeniden açılınca panelde aynı durum.
     */
    private void keepInAppNotice(int message) {
        keptInAppNotice = message;
        Toast.makeText(this, message, Toast.LENGTH_LONG).show();
    }

    /** Katman açılamadı (TV pencereye ya da arka plan servisine izin vermedi): uygulama içinde kalınır, neden gösterilir. */
    private void showOverlayFailed() {
        showOverlayFailed(R.string.overlay_failed);
    }

    private void showOverlayFailed(int message) {
        if (help == null) return;
        if (pickerShown) {
            Toast.makeText(this, message, Toast.LENGTH_LONG).show();
            return;
        }
        help.setText(message);
        choices.setVisibility(View.GONE);
        helpBox.setVisibility(View.VISIBLE);
        handler.removeCallbacks(hideHelpTask);
        handler.postDelayed(hideHelpTask, HELP_VISIBLE_MS);
    }

    /** Görüntü gelmiyor: izleme başlar (yoksa), saat ilk sorunda başlar. */
    private void trouble() {
        if (!resumed) return;
        watch.trouble(SystemClock.elapsedRealtime());
        if (!watching && !watch.played()) {
            watching = true;
            handler.postDelayed(watchTick, WATCH_EVERY_MS);
        }
    }

    private void stopWatching() {
        watching = false;
        handler.removeCallbacks(watchTick);
    }

    private void checkFallback() {
        watching = false;
        if (isFinishing() || tvView == null || watch.played()) return;
        long now = SystemClock.elapsedRealtime();
        boolean source = HdmiInputs.hasSource(this, session.input());
        boolean permitted = autoOverlayAllowed();
        if (watch.shouldSwitch(now, source, permitted)) {
            switchToOverlay(R.string.overlay_fallback);
            return;
        }
        // Uygulama içi bilerek seçildi: katmana geçilmez (katman penceresinde çöken TV'ler, #1074). Seçiciden önce giriş bir
        // kez bırakılıp yeniden açılır; görüntü saati de yeniden başlar.
        String id = session.input();
        if (watch.noPicture(now) && keptInApp() && !inAppRetuned && id != null && !pickerShown && !pickerClosed) {
            inAppRetuned = true;
            watch.pause();
            resetQuietly(tvView);
            tune(id);
            return;
        }
        // Katmana geçilemiyor (Play paketi, izin yok ya da girişte cihaz görünmüyor): ekran siyah kalmasın, giriş seçici ve
        // ne yapılacağı gösterilir. Eskiden girişte cihaz görünmeyince (PS5 başka HDMI'da) hiçbir şey söylenmiyordu.
        if (watch.noPicture(now) && !pickerShown && !pickerClosed) {
            showPicker(source);
        }
        watching = true;
        handler.postDelayed(watchTick, WATCH_EVERY_MS);
    }

    private void showPermissionHelp(int message) {
        if (help == null || pickerShown) return;
        // Play paketinde izin işe yaramaz: katman modu yalnız bilgisayarın kurduğu sürümde var. Telefonda ya da
        // bilgisayarda Katman seçilince bu açıkça söylenir; seçim sessizce yok sayılmaz.
        help.setText(BuildConfig.OVERLAY_MODE
                ? getString(message) + "\n\n" + getString(R.string.overlay_permission_how)
                : getString(R.string.overlay_unavailable));
        choices.setVisibility(View.GONE);
        helpBox.setVisibility(View.VISIBLE);
        handler.removeCallbacks(hideHelpTask);
        handler.postDelayed(hideHelpTask, HELP_VISIBLE_MS);
    }

    /**
     * HDMI görüntüsü gelmiyor: nedenini ve TV'nin HDMI girişlerini gösterir, kullanıcı PS5'in girişini kumandayla seçer.
     * Yanlış giriş en sık neden: PS5'in girişi kendiliğinden bulunamazsa (birden çok bağlı giriş, CEC adı yok) HDMI 1
     * açılır. Doğru girişte de siyahsa TV görüntüyü uygulamaya vermiyordur ya da HDCP engelliyordur; o zaman TV'nin kendi
     * girişine geçmek ve altyazıyı telefonda izlemek önerilir. Seçici görüntü gelince ya da Geri/Kapat ile kapanır.
     */
    private void showPicker(boolean sourceConnected) {
        if (helpBox == null) return;
        pickerShown = true;
        handler.removeCallbacks(hideHelpTask);
        List<HdmiInputs.Choice> inputs = HdmiInputs.choices(this);
        choices.removeAllViews();
        StringBuilder text = new StringBuilder();
        Button focus = null;
        if (inputs.isEmpty()) {
            text.append(getString(R.string.hdmi_not_offered));
        } else {
            int port = tunedPort(inputs);
            if (port > 0) {
                text.append(getString(sourceConnected ? R.string.no_picture : R.string.no_picture_empty, port)).append(' ');
            } else if (session.input() == null) {
                // Konsolun girişi bulunamadı, hiçbir giriş açılmadı (bkz. chooseInput).
                text.append(getString(R.string.console_not_found)).append(' ');
            }
            text.append(getString(R.string.no_picture_choose));
            text.append("\n\n").append(getString(R.string.no_picture_still_black));
            for (HdmiInputs.Choice input : inputs) {
                Button button = choiceButton(choiceLabel(input));
                button.setOnClickListener(v -> choose(input.port));
                choices.addView(button);
                // Önce PS5 adıyla görünen, sonra açık olmayan bağlı giriş seçili gelir.
                boolean console = HdmiInputs.looksLikeConsole(input.device);
                if (console || (focus == null && input.connected && input.port != port)) focus = button;
            }
        }
        if (overlayAllowed()) {
            // Giriş boş göründüğü için ya da kullanıcı Uygulama içinde seçtiği için kendiliğinden geçilmedi
            // (FallbackWatch.shouldSwitch, DisplayMode.mayAutoSwitch); PS5 başka girişteyse ya da TV görüntüyü uygulamaya
            // vermiyorsa kullanıcı katmanı buradan kendisi seçer.
            if (keptInApp()) text.append("\n\n").append(getString(R.string.in_app_kept_no_picture));
            text.append("\n\n").append(getString(R.string.overlay_offer));
            Button overlay = choiceButton(getString(R.string.overlay_switch));
            overlay.setOnClickListener(v -> switchToOverlay(R.string.overlay_selected));
            choices.addView(overlay);
        } else if (BuildConfig.OVERLAY_MODE) {
            text.append("\n\n").append(getString(R.string.overlay_permission_how));
        } else {
            text.append("\n\n").append(getString(R.string.overlay_from_computer));
        }
        Button close = choiceButton(getString(R.string.picker_close));
        close.setOnClickListener(v -> closePicker());
        choices.addView(close);
        arrangeChoices();
        help.setText(text);
        choices.setVisibility(View.VISIBLE);
        helpBox.setVisibility(View.VISIBLE);
        (focus != null ? focus : choices.getChildAt(0)).requestFocus();
    }

    /** Açık girişin numarası, bilinmiyorsa 0. */
    private int tunedPort(List<HdmiInputs.Choice> inputs) {
        for (HdmiInputs.Choice input : inputs) {
            if (input.id.equals(session.input())) return input.port;
        }
        return 0;
    }

    private String choiceLabel(HdmiInputs.Choice input) {
        String label = "HDMI " + input.port;
        if (input.device != null) label += " · " + input.device;
        else if (input.connected) label += " · " + getString(R.string.picker_connected);
        return label;
    }

    /**
     * Seçici düğmesi (tokens.json; sayfadaki #no-picture düğmeleriyle aynı dil): durgunken surface2 zemin, 3 px border
     * çerçeve ve ana metin rengi; odakta accent zemin, beyaz çerçeve ve onAccent yazı (basılıyken accentHi), 12 köşe
     * (radius.control); odakta %5 büyür. Mavi ve gri sistem renkleri kullanılmaz.
     */
    private Button choiceButton(String label) {
        Button button = new Button(this);
        button.setText(label);
        button.setAllCaps(false);
        button.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        button.setTextColor(new ColorStateList(
                new int[][] {{android.R.attr.state_focused}, {android.R.attr.state_pressed}, {}},
                new int[] {ON_ACCENT, ON_ACCENT, TEXT_PRIMARY}));
        button.setTextSize(TypedValue.COMPLEX_UNIT_PX, 28 * fitScale());
        StateListDrawable background = new StateListDrawable();
        int stroke = Math.max(1, Math.round(3 * fitScale()));
        background.addState(new int[] {android.R.attr.state_pressed}, outlined(rounded(ACCENT_HI, 12), stroke, Color.WHITE));
        background.addState(new int[] {android.R.attr.state_focused}, outlined(rounded(ACCENT, 12), stroke, Color.WHITE));
        background.addState(new int[] {}, outlined(rounded(SURFACE2, 12), stroke, BORDER));
        button.setBackground(background);
        // Temanın gölge ve yükselme animasyonu düz yüzey kuralına aykırı.
        button.setStateListAnimator(null);
        int pad = Math.round(16 * fitScale());
        button.setPadding(2 * pad, pad, 2 * pad, pad);
        button.setFocusable(true);
        button.setOnFocusChangeListener((view, focused) -> {
            float scale = focused ? FOCUS_SCALE : 1f;
            view.animate().scaleX(scale).scaleY(scale).setDuration(120).start();
        });
        return button;
    }

    /**
     * Düğmeleri dizer: az düğme yan yana, {@link #CHOICES_IN_ROW}'dan çoksa (çok HDMI girişli TV) alt alta; yan yana
     * dizilince 1400 piksellik kutudan taşıyordu. Kumandada yan yana sol/sağ, alt alta yukarı/aşağı ile gezilir.
     */
    private void arrangeChoices() {
        int count = choices.getChildCount();
        boolean stacked = count > CHOICES_IN_ROW;
        choices.setOrientation(stacked ? LinearLayout.VERTICAL : LinearLayout.HORIZONTAL);
        int gap = Math.round(16 * fitScale());
        for (int i = 0; i < count; i++) {
            LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
            boolean last = i == count - 1;
            if (stacked) layout.bottomMargin = last ? 0 : gap;
            else layout.rightMargin = last ? 0 : gap;
            choices.getChildAt(i).setLayoutParams(layout);
        }
    }

    /** Düz renkli, köşesi 1920 piksellik sayfa ölçüsünde verilen yuvarlak zemin. */
    private GradientDrawable rounded(int color, float radius) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(color);
        drawable.setCornerRadius(radius * fitScale());
        return drawable;
    }

    private static GradientDrawable outlined(GradientDrawable drawable, int width, int color) {
        drawable.setStroke(width, color);
        return drawable;
    }

    /**
     * Seçilen girişi açar. 1–4 sayfa üzerinden açılır (sayı tuşuyla aynı yol): seçim kaydedilir, sonraki açılışta da o
     * giriş gelir. Daha büyük numaralar doğrudan açılır. Yeni giriş için görüntü saati baştan başlar.
     */
    private void choose(int port) {
        hidePicker();
        pickerClosed = false;
        watch.pause();
        stopOutageWatch();
        // Seçim kalıcı: 4'ten büyük numaralar sayfada kaydedilmez, uygulama da kaydeder (#367).
        HdmiInputs.remember(this, HdmiInputs.idForPort(this, port));
        if (port >= 1 && port <= 4 && page != null) page.key(48 + port);
        else showHdmi(port);
    }

    /** Kullanıcı seçiciyi kapattı: başka giriş seçilene kadar yeniden açılmaz. */
    private void closePicker() {
        pickerClosed = true;
        hidePicker();
    }

    private void hidePicker() {
        pickerShown = false;
        hideHelp();
    }

    private void hideHelp() {
        if (helpBox != null) helpBox.setVisibility(View.GONE);
        if (choices != null && choices.getVisibility() == View.VISIBLE) {
            choices.setVisibility(View.GONE);
            choices.removeAllViews();
            pickerShown = false;
            if (page != null) page.webView.requestFocus();
        }
    }

    // --- TvPage.Host ---

    @Override
    public void showHdmi(int port) {
        String id = HdmiInputs.idForPort(this, port);
        if (tvView == null || id == null) {
            status("sourceError");
            // TV HDMI girişlerini uygulamalara hiç açmıyor (giriş listesi boş ya da TV giriş servisi yok): TvView'da
            // gösterilecek bir şey yok, hemen söylenir. Eskiden TV giriş servisi olmayan TV'lerde (#275) yalnız
            // "kaynak desteklenmiyor" yazıyordu; ne yapılacağı ve Katman söylenmiyordu.
            boolean noInputs = tvView == null || HdmiInputs.list(this).isEmpty();
            if (noInputs && !pickerShown && !pickerClosed) showPicker(false);
            return;
        }
        retuneAttempts = 0;
        tune(id);
    }

    /**
     * Konsolun girişi bulunamadı (CEC kapalı, birden çok giriş bağlı görünüyor, kayıtlı seçim yok): eskiden HDMI 1
     * açılıyordu (#367). Artık hiçbir giriş açılmaz, giriş seçici hemen gösterilir; seçilen giriş kaydedilir.
     */
    @Override
    public void chooseInput() {
        if (!pickerShown && !pickerClosed) showPicker(true);
    }

    /**
     * CouchSubs'tan çıkış (kumandada Geri, giriş seçicide "Çık", çeviri durunca bilgisayarın isteği): HDMI girişi
     * bırakılır, TvView ekrandan kaldırılır ve ekran görev listesinden de çıkarılarak kapanır; arkada giriş tutan bir şey
     * kalmaz.
     */
    @Override
    public void exit() {
        exit("exit");
    }

    private void exit(String why) {
        stopWatching();
        stopOutageWatch();
        handler.removeCallbacksAndMessages(null);
        session.clear();
        releaseHdmi(true, why);
        finishAndRemoveTask();
    }

    /** Bilgi panelinin tanı satırı: görüntü modu ve TvView'in durumu. */
    @Override
    public String diagnostics() {
        int retunes = outage.retunes();
        String sound = audioDiagnostics();
        return "mode inApp · tv " + tvState + (retunes > 0 ? " · retune " + retunes : "")
                + (sound.isEmpty() ? "" : " · " + sound);
    }

    /** Ses tanısı (yalnız okunur; sesi, odağı, ses parçasını değiştirmez). Okunamazsa boş. */
    private String audioDiagnostics() {
        try {
            AudioManager audio = (AudioManager) getSystemService(AUDIO_SERVICE);
            if (audio == null) return "";
            int volume = audio.getStreamVolume(AudioManager.STREAM_MUSIC);
            int max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
            boolean muted = Build.VERSION.SDK_INT >= 23 && audio.isStreamMute(AudioManager.STREAM_MUSIC);
            int[] outputs = types(audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS));
            int[] routed = null;
            if (Build.VERSION.SDK_INT >= 33) {
                try {
                    AudioAttributes media = new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA).build();
                    routed = types(audio.getAudioDevicesForAttributes(media).toArray(new AudioDeviceInfo[0]));
                } catch (RuntimeException e) {
                    routed = null;
                }
            }
            return AudioState.text(volume, max, muted, outputs, routed, audioTracks, audioSelected);
        } catch (RuntimeException e) {
            return "";
        }
    }

    private static int[] types(AudioDeviceInfo[] devices) {
        if (devices == null) return new int[0];
        int[] out = new int[devices.length];
        for (int i = 0; i < devices.length; i++) out[i] = devices[i].getType();
        return out;
    }

    private static int audioTrackCount(List<TvTrackInfo> tracks) {
        int count = 0;
        if (tracks == null) return 0;
        for (TvTrackInfo track : tracks) if (track != null && track.getType() == TvTrackInfo.TYPE_AUDIO) count++;
        return count;
    }

    @Override
    public void displayModeChanged(String mode) {
        // Otomatik seçildi: izin varsa katmana geçilir, yoksa uygulama içinde kalınır (izin istenmez).
        if (DisplayMode.AUTO.equals(mode)) {
            if (overlayAllowed()) switchToOverlay(R.string.overlay_selected);
            return;
        }
        if (!DisplayMode.OVERLAY.equals(mode)) return;
        if (overlayAllowed()) switchToOverlay(R.string.overlay_selected);
        else if (pickerShown) Toast.makeText(this, BuildConfig.OVERLAY_MODE
                ? R.string.overlay_permission_needed : R.string.overlay_unavailable, Toast.LENGTH_LONG).show();
        else showPermissionHelp(R.string.overlay_permission_needed);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent.getBooleanExtra(EXTRA_EXIT, false)) {
            // #1221: bilgisayar/telefon kapatıp yeniden açacak; HDMI girişi işlem öldürülmeden önce bırakılır.
            if (OverlayService.running) OverlayService.stop(this);
            exit("exit (keeper)");
            return;
        }
        TvPage.storeDisplayMode(this, intent.getStringExtra(EXTRA_DISPLAY_MODE));
        if (page == null || intent.getBooleanExtra(EXTRA_RECLAIM, false)) return;
        String params = paramsOf(intent);
        // Bilgisayarın/telefonun adresiyle gelen açılış ekranı değiştirmez (yalnız adres iletilir); kullanıcı katmandan
        // çıktıysa kumandadan yeniden açılış da onu katmana geri atmaz (bkz. DisplayMode.switchOnNewIntent).
        if (DisplayMode.switchOnNewIntent(params, leftOverlay, TvPage.storedDisplayMode(this), overlayAllowed())) {
            switchToOverlay(R.string.overlay_selected);
            return;
        }
        if (!params.isEmpty()) {
            launchParams = params;
            page.relaunch(params);
        }
    }

    private static String paramsOf(Intent intent) {
        String params = intent == null ? null : intent.getStringExtra("params");
        return params == null ? "" : params;
    }

    /** Geri ve renk tuşlarını sayfaya bildirir; diğerleri WebView'e kendiliğinden gider. */
    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        // Hemen ardından ekran önden çekilirse (Ayarlar tuşu hızlı ayarlar panelini açtı) bu kullanıcının işidir: devralma
        // sayılmaz (bkz. ScreenReclaim.userActedBefore).
        if (event.getAction() == KeyEvent.ACTION_DOWN) reclaim.userKey(SystemClock.elapsedRealtime());
        if (pickerShown && pickerKey(event)) return true;
        int code = pageKey(event.getKeyCode());
        if (code == 0 || page == null) return super.dispatchKeyEvent(event);
        if (event.getAction() == KeyEvent.ACTION_DOWN) page.key(code);
        return true;
    }

    /** Giriş seçici açıkken: Geri kapatır, 1–4 o girişi açar; ok tuşları ve Tamam düğmelere kendiliğinden gider. */
    private boolean pickerKey(KeyEvent event) {
        int key = event.getKeyCode();
        boolean digit = key >= KeyEvent.KEYCODE_1 && key <= KeyEvent.KEYCODE_4;
        if (key != KeyEvent.KEYCODE_BACK && !digit) return false;
        if (event.getAction() != KeyEvent.ACTION_DOWN) return true;
        if (digit) choose(key - KeyEvent.KEYCODE_0);
        else closePicker();
        return true;
    }

    private static int pageKey(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_BACK: return 4;
            case KeyEvent.KEYCODE_PROG_RED: return 403;
            case KeyEvent.KEYCODE_PROG_GREEN: return 404;
            case KeyEvent.KEYCODE_PROG_BLUE: return 406;
            default: return 0;
        }
    }

    /** Ekran önden çekilince bırakılan HDMI girişi (bkz. onPause) öne gelince yeniden açılır. */
    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        userLeaving = false;
        // Ekran yalnız duraklatıldıysa (üstte bildirim, giriş bırakılmadı) giriş yeniden açılmaz (#794); arada görüntü
        // gittiyse ya da bağlantı koptuysa açılır.
        boolean held = session.held() && !lostWhilePaused;
        lostWhilePaused = false;
        String id = session.toForeground();
        if (tvView != null && id != null && !held) tune(id);
        if (keptInAppNotice != 0) {
            showOverlayFailed(keptInAppNotice);
            keptInAppNotice = 0;
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putBoolean(STATE_LEFT_OVERLAY, leftOverlay);
    }

    /** Uygulamadan çıkılınca (Ana ekran, başka uygulama) Türkçe dublaj susar; altyazı bağlantısı sürer (TV-NP). */
    @Override
    protected void onStop() {
        super.onStop();
        // TV kendi HDMI oynatıcısını öne çekti (bkz. FallbackWatch.TAKEOVER_MS): altyazı onun üstünde, katmanda çizilir.
        // Görüntü uygulamada gelmişken kullanıcı kendisi çıktıysa (Ana ekran) bu devralma değildir: altyazı seçtiği ekranın
        // üstüne çizilmez.
        boolean leftByUser = userLeaving;
        userLeaving = false;
        // #794: PS5 açılınca, HDR devreye girince ya da bildirimle TV kendi HDMI ekranını öne çekti; görüntü uygulamada
        // geliyordu. Katmana geçilmez, CouchSubs ekranı kısa süre sonra geri alınır.
        // Geri alma hakkı dolduysa (TV sürekli geri itiyor) izin varsa katmana geçilir: eskiden CouchSubs arkada kalıyor,
        // altyazı bağlantısı açık olduğundan telefon/bilgisayar TV'yi "bağlı" görüyor ama yazı görünmeyen ekrana
        // çiziliyordu ("telefonda altyazı sürüyor, TV'de yok; test yazısı çıkıyor").
        ScreenReclaim.Action taken = isFinishing() || tvView == null ? ScreenReclaim.Action.NONE
                : reclaim.onTakenAway(pausedAt, watch.played());
        if (taken == ScreenReclaim.Action.RECLAIM) {
            releaseForBackground("taken over");
            if (page != null) page.background(true);
            handler.postDelayed(this::reclaimScreen, ScreenReclaim.DELAY_MS);
            return;
        }
        // Kullanıcı bilerek Uygulama içinde seçtiyse hiçbir otomatik durumda katmana geçilmez (DisplayMode.mayAutoSwitch):
        // katman penceresinde çöken TV'lerde (#1074) bu seçim tek güvenli yoldu, kendiliğinden geçiş onu boşa çıkarıyordu.
        boolean autoOverlay = autoOverlayAllowed();
        boolean keepInApp = keptInApp();
        if (taken == ScreenReclaim.Action.GIVE_UP) {
            if (autoOverlay) {
                switchToOverlay(R.string.overlay_fallback);
                if (isFinishing()) return;
            } else if (keepInApp && rescueToOverlay()) {
                return;
            } else if (keepInApp) {
                keepInAppNotice(R.string.in_app_kept_taken);
            }
        }
        // Kullanıcı tuşa basıp ekranı kendisi değiştirdiyse (Ayarlar, Giriş) TV'nin devralması sayılmaz, katmana geçilmez.
        boolean byKey = reclaim.userActedBefore(pausedAt);
        long now = SystemClock.elapsedRealtime();
        boolean takeover = !byKey && !isFinishing() && tvView != null && watch.takenOver(now, true, leftByUser);
        if (takeover && autoOverlay) {
            switchToOverlay(R.string.overlay_fallback);
            // Arka plandan ön plan servisi başlatılamadıysa (Android 12+ kısıtı) ekran açık kalır, normal yoldan devam.
            if (isFinishing()) return;
        } else if (takeover && keepInApp && taken != ScreenReclaim.Action.GIVE_UP) {
            // Uygulama içi seçili: katman yerine CouchSubs ekranı geri öne getirilir, giriş öne gelince yeniden açılır
            // (dakikada en çok ScreenReclaim.MAX_PER_MINUTE kez). Hak dolduysa CouchSubs arkada kalır, durum söylenir.
            if (reclaim.retake(now)) {
                keptInAppNotice = R.string.in_app_kept_reclaimed;
                releaseForBackground("taken over");
                if (page != null) page.background(true);
                handler.postDelayed(this::reclaimScreen, ScreenReclaim.DELAY_MS);
                return;
            }
            if (rescueToOverlay()) return;
            keepInAppNotice(R.string.in_app_kept_taken);
        }
        if (page != null) page.background(true);
        // Ekran artık görünmüyor: giriş onPause'da bırakılmadıysa (bildirimle duraklatılmıştı) şimdi bırakılır; arada
        // yeniden tutulmuş olmasın diye bir kez daha bırakılır.
        releaseForBackground("background");
        if (tvView != null && !resumed) resetQuietly(tvView);
    }

    /**
     * #794: TV'nin kendi giriş ekranından CouchSubs'ı geri öne getirir. Android 8-9'da her zaman; Android 10+ arka plandan
     * açma kısıtı yalnız "diğer uygulamaların üzerinde göster" izni olan uygulamaya izin verir (masaüstünün kurduğu APK'da
     * var, Play paketinde yok); izin yoksa sistem açmayı sessizce engeller, eski davranış kalır.
     */
    private void reclaimScreen() {
        if (resumed || isFinishing() || isDestroyed()) return;
        try {
            startActivity(new Intent(this, MainActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    .putExtra(EXTRA_RECLAIM, true));
        } catch (RuntimeException ignored) {
            // TV açmaya izin vermedi.
        }
    }

    /** Ekran önden çekildi: TvView girişi tutuyorsa bırakılır (giriş unutulmaz, öne gelince açılır). */
    private void releaseForBackground(String why) {
        if (tvView != null && session.toBackground()) releaseHdmi(false, why);
    }

    @Override
    protected void onUserLeaveHint() {
        super.onUserLeaveHint();
        userLeaving = true;
    }

    @Override
    protected void onStart() {
        super.onStart();
        if (page != null) page.background(false);
    }

    /**
     * Arka plandayken katmana geçilmez (kullanıcı başka bir şey izliyor olabilir); öne gelince saat yeniden başlar.
     * HDMI girişi bırakılır (#453): TV'nin kendi giriş ekranı açılırken CouchSubs girişi tutarsa aynı HDMI'yı tek
     * oturuma veren TV'lerde (Thomson, Philips) o ekran yeşil ya da siyah kalıyordu. onStop beklenmez: yeni ekran
     * (TV'nin HDMI oynatıcısı) bu ekranın onStop'undan önce açılır ve girişi o anda ister.
     */
    @Override
    protected void onPause() {
        super.onPause();
        resumed = false;
        pausedAt = SystemClock.elapsedRealtime();
        stopWatching();
        watch.pause();
        stopOutageWatch();
        // #794: ekran yalnız duraklatıldıysa (üstte yarı saydam bildirim ya da sistem penceresi; Android: onPause ekran hâlâ
        // görünürken de gelir, görünmez olunca onStop) giriş tutulur, görüntü kesilmez; onStop'ta bırakılır. Kullanıcı
        // başka ekrana geçiyorsa (onUserLeaveHint: Giriş, Ana ekran, başka uygulama) eskisi gibi hemen bırakılır (#453).
        // Kumandadaki tuşla açılan ekran da (Ayarlar tuşu: hızlı ayarlar paneli) kullanıcının geçişidir: 0.9.55'teki gibi
        // giriş hemen bırakılır, TV paneli kendi giriş ekranında açabilir; panel kapanınca giriş yeniden açılır.
        if (userLeaving || isFinishing() || reclaim.userActedBefore(pausedAt)) releaseForBackground("background");
    }

    /** Bağlantı koptuysa birkaç kez, gittikçe seyrek yeniden dener. */
    private void retuneLater() {
        String id = session.input();
        // Ekran duraklatılmışken (üstte panel) yeniden denenmez: giriş öne dönünce açılır (onResume, lostWhilePaused).
        if (tvView == null || !resumed || !session.canRetune(id) || retuneAttempts >= 5) return;
        retuneAttempts++;
        // Arka plana düşüldüyse yeniden denenmez: giriş TV'nin kendi ekranındadır.
        handler.postDelayed(() -> { if (resumed && session.canRetune(id)) tune(id); }, 1500L * retuneAttempts);
    }

    private void tune(String id) {
        // Kapanıyor (çıkış isteği): giriş yeniden açılmaz, bırakılan HDMI bırakılmış kalır (#1221).
        if (isFinishing() || tvView == null) return;
        // Ekran arka plandaysa giriş açılmaz, yalnız hatırlanır; öne gelince açılır (onResume).
        if (!session.want(id)) return;
        // Bekleyen gecikmeli bırakma bu yeni oturumu kapatmasın.
        releaseGeneration++;
        tvState = "tuning";
        audioTracks = -1;
        audioSelected = false;
        watch.tuned(SystemClock.elapsedRealtime());
        // Yeni oturum: görüntü boyu/izleri yeniden öğrenilir; girişi açtıran tuş (seçicide 1-4) TV'nin hemen ardından
        // gelen devralmasını kullanıcının işi saydırmasın (#42: TV girişi 1-2 sn sonra kendi oynatıcısında açar).
        reclaim.tuned();
        // PS5 görüntüsü gelirken TV boşta sanmasın: giriş açılır açılmaz ekran açık tutulur; görüntü gerçekten yoksa
        // (PS5 kapalı, kablo çıktı) noVideo() bırakır.
        keepScreenOn(true);
        tvView.setStreamVolume(1f);
        tvView.tune(id, TvContract.buildChannelUriForPassthroughInput(id));
        // Görüntü gelene kadar izlenir; hiç gelmezse katmana geçilir.
        trouble();
    }

    /**
     * Ekrandaki WebView işlemi çöktü ya da sistem kapattı (#616). Eskiden Android uygulamayı kapatıyordu. Sayfa aynı
     * yerde yeniden kurulur; kısa sürede birkaç kez yinelenirse yeniden kurulmaz, nedeni ekranda yazar.
     */
    @Override
    public void pageGone(boolean crashed) {
        if (page == null) return;
        ViewGroup parent = (ViewGroup) page.webView.getParent();
        int index = parent == null ? -1 : parent.indexOfChild(page.webView);
        String params = page.launchParams();
        if (parent != null) parent.removeView(page.webView);
        page.destroy();
        page = null;
        if (parent == null || isFinishing() || !pageRestarts.allow(SystemClock.elapsedRealtime())) {
            showOverlayFailed(R.string.page_renderer_failed);
            return;
        }
        handler.postDelayed(() -> {
            if (page != null || isFinishing() || isDestroyed()) return;
            page = new TvPage(this, this, params, false);
            parent.addView(page.webView, Math.min(index, parent.getChildCount()));
            page.load();
            if (!pickerShown) page.webView.requestFocus();
            if (!resumed) page.background(true);
        }, PageRestarts.DELAY_MS);
    }

    @Override
    protected void onDestroy() {
        if (current == this) current = null;
        handler.removeCallbacksAndMessages(null);
        releaseHdmi(true, "closed");
        if (page != null) page.destroy();
        super.onDestroy();
    }

    private void status(String kind) {
        if (page != null) page.status(kind);
    }
}
