// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.media.tv.TvContract;
import android.media.tv.TvView;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;
import android.widget.Toast;

/**
 * İki modda çalışır (bkz. DisplayMode):
 * - Uygulama içinde (varsayılan): HDMI girişini TvView ile tam ekran gösterir; üstünde şeffaf WebView'de LG ve Samsung'la
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
    private static final String EXTRA_DISPLAY_MODE = "displayMode";
    private static final long WATCH_EVERY_MS = 1000;
    private static final long HELP_VISIBLE_MS = 25_000;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private TvView tvView;
    private TvPage page;
    private TextView help;
    private String launchParams = "";
    /** Son açılan HDMI girişi; uygulama öne gelince ya da bağlantı kopunca yeniden açılır. */
    private String tunedInput;
    private int retuneAttempts;
    private final FallbackWatch watch = new FallbackWatch();
    private boolean watching;
    /** Ekran önde mi; arka plandayken görüntü izlenmez. */
    private boolean resumed;
    private boolean helpShown;
    private final Runnable watchTick = this::checkFallback;
    private final Runnable hideHelpTask = this::hideHelp;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Intent intent = getIntent();
        launchParams = paramsOf(intent);
        TvPage.storeDisplayMode(this, intent.getStringExtra(EXTRA_DISPLAY_MODE));

        if (OverlayService.running && !intent.getBooleanExtra(EXTRA_FROM_OVERLAY, false)) {
            if (!launchParams.isEmpty()) {
                // Bilgisayar uygulamayı yeni adresle açtı: katman sürer, adres ona iletilir.
                OverlayService.start(this, launchParams);
            } else {
                // Kumandadan yeniden açıldı: katman kapanır.
                OverlayService.stop(this);
                Toast.makeText(this, R.string.overlay_stopped, Toast.LENGTH_LONG).show();
            }
            finish();
            return;
        }

        DisplayMode.Start start = DisplayMode.atLaunch(TvPage.storedDisplayMode(this), overlayAllowed());
        if (start == DisplayMode.Start.OVERLAY) {
            startOverlay();
            return;
        }
        showInApp();
        if (start == DisplayMode.Start.IN_APP_NEEDS_PERMISSION) showPermissionHelp(R.string.overlay_permission_needed);
    }

    /** Katman açılabilir mi: bu derlemede var (Play paketinde yok) ve "Diğer uygulamaların üzerinde göster" izni verilmiş. */
    private boolean overlayAllowed() {
        return BuildConfig.OVERLAY_MODE && Settings.canDrawOverlays(this);
    }

    private void showInApp() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        if (getSystemService(TV_INPUT_SERVICE) != null) {
            tvView = new TvView(this);
            tvView.setCallback(new TvView.TvInputCallback() {
                @Override public void onConnectionFailed(String inputId) { noVideo(); retuneLater(); }
                @Override public void onDisconnected(String inputId) { noVideo(); retuneLater(); }
                @Override public void onVideoAvailable(String inputId) {
                    retuneAttempts = 0;
                    watch.videoAvailable();
                    hideHelp();
                    keepScreenOn(true);
                    status("playing");
                }
                @Override public void onVideoUnavailable(String inputId, int reason) { noVideo(); }
            });
            root.addView(tvView);
        }

        page = new TvPage(this, this, launchParams, false);
        root.addView(page.webView);

        help = new TextView(this);
        help.setVisibility(View.GONE);
        help.setTextColor(Color.WHITE);
        help.setTextSize(TypedValue.COMPLEX_UNIT_PX, 30 * fitScale());
        help.setBackgroundColor(0xE6202024);
        int pad = Math.round(28 * fitScale());
        help.setPadding(pad, pad, pad, pad);
        FrameLayout.LayoutParams helpLayout = new FrameLayout.LayoutParams(
                Math.round(1300 * fitScale()), FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        helpLayout.topMargin = Math.round(60 * fitScale());
        root.addView(help, helpLayout);

        setContentView(root);
        page.load();
        page.webView.requestFocus();
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

    /** 1920 piksellik sayfa ölçüsünü ekran pikseline çevirir (yardım kutusu sayfayla aynı boyda görünsün). */
    private float fitScale() {
        int width = getResources().getDisplayMetrics().widthPixels;
        int height = getResources().getDisplayMetrics().heightPixels;
        return Math.max(width, height) / 1920f;
    }

    // --- Katmana geçiş ---

    private void startOverlay() {
        OverlayService.start(this, launchParams);
        finish();
    }

    /** Uygulama içinden katmana: TvView girişi bırakır ki TV kendi ekranında açabilsin. */
    private void switchToOverlay(int message) {
        stopWatching();
        if (tvView != null) tvView.reset();
        tunedInput = null;
        Toast.makeText(this, message, Toast.LENGTH_LONG).show();
        startOverlay();
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
        boolean source = HdmiInputs.hasSource(this, tunedInput);
        boolean permitted = overlayAllowed();
        if (watch.shouldSwitch(now, source, permitted)) {
            switchToOverlay(R.string.overlay_fallback);
            return;
        }
        if (watch.needsPermission(now, source, permitted) && !helpShown) {
            showPermissionHelp(R.string.overlay_fallback_needs_permission);
        }
        watching = true;
        handler.postDelayed(watchTick, WATCH_EVERY_MS);
    }

    private void showPermissionHelp(int message) {
        if (help == null) return;
        helpShown = true;
        // Play paketinde izin işe yaramaz: katman modu yalnız bilgisayarın kurduğu sürümde var.
        help.setText(BuildConfig.OVERLAY_MODE
                ? getString(message) + "\n\n" + getString(R.string.overlay_permission_how)
                : getString(R.string.overlay_unavailable));
        help.setVisibility(View.VISIBLE);
        handler.removeCallbacks(hideHelpTask);
        handler.postDelayed(hideHelpTask, HELP_VISIBLE_MS);
    }

    private void hideHelp() {
        if (help != null) help.setVisibility(View.GONE);
    }

    // --- TvPage.Host ---

    @Override
    public void showHdmi(int port) {
        String id = HdmiInputs.idForPort(this, port);
        if (tvView == null || id == null) {
            status("sourceError");
            return;
        }
        retuneAttempts = 0;
        tune(id);
    }

    @Override
    public void exit() { finish(); }

    @Override
    public void displayModeChanged(String mode) {
        if (!DisplayMode.OVERLAY.equals(mode)) return;
        if (overlayAllowed()) switchToOverlay(R.string.overlay_selected);
        else showPermissionHelp(R.string.overlay_permission_needed);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        TvPage.storeDisplayMode(this, intent.getStringExtra(EXTRA_DISPLAY_MODE));
        if (page == null) return;
        if (DisplayMode.OVERLAY.equals(TvPage.storedDisplayMode(this)) && overlayAllowed()) {
            String params = paramsOf(intent);
            if (!params.isEmpty()) launchParams = params;
            switchToOverlay(R.string.overlay_selected);
            return;
        }
        String params = paramsOf(intent);
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
        int code = pageKey(event.getKeyCode());
        if (code == 0 || page == null) return super.dispatchKeyEvent(event);
        if (event.getAction() == KeyEvent.ACTION_DOWN) page.key(code);
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

    /** Bazı TV'ler (ör. TCL) uygulama arka plana gidince HDMI'yi bırakır; öne gelince görüntü yeniden açılır. */
    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        if (tvView != null && tunedInput != null) tune(tunedInput);
    }

    /** Uygulamadan çıkılınca (Ana ekran, başka uygulama) Türkçe dublaj susar; altyazı bağlantısı sürer (TV-NP). */
    @Override
    protected void onStop() {
        super.onStop();
        // TV kendi HDMI oynatıcısını öne çekti (bkz. FallbackWatch.TAKEOVER_MS): altyazı onun üstünde, katmanda çizilir.
        if (!isFinishing() && tvView != null && watch.takenOver(SystemClock.elapsedRealtime(), overlayAllowed())) {
            switchToOverlay(R.string.overlay_fallback);
            return;
        }
        if (page != null) page.background(true);
    }

    @Override
    protected void onStart() {
        super.onStart();
        if (page != null) page.background(false);
    }

    /** Arka plandayken katmana geçilmez (kullanıcı başka bir şey izliyor olabilir); öne gelince saat yeniden başlar. */
    @Override
    protected void onPause() {
        super.onPause();
        resumed = false;
        stopWatching();
        watch.pause();
    }

    /** Bağlantı koptuysa birkaç kez, gittikçe seyrek yeniden dener. */
    private void retuneLater() {
        if (tvView == null || tunedInput == null || retuneAttempts >= 5) return;
        retuneAttempts++;
        String id = tunedInput;
        handler.postDelayed(() -> { if (id.equals(tunedInput)) tune(id); }, 1500L * retuneAttempts);
    }

    private void tune(String id) {
        tunedInput = id;
        watch.tuned(SystemClock.elapsedRealtime());
        tvView.tune(id, TvContract.buildChannelUriForPassthroughInput(id));
        // Görüntü gelene kadar izlenir; hiç gelmezse katmana geçilir.
        trouble();
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (tvView != null) tvView.reset();
        if (page != null) page.destroy();
        super.onDestroy();
    }

    private void status(String kind) {
        if (page != null) page.status(kind);
    }
}
