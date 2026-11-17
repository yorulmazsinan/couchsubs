// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.StateListDrawable;
import android.media.tv.TvContract;
import android.media.tv.TvInputManager;
import android.media.tv.TvView;
import android.os.Build;
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
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.util.List;

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
    private LinearLayout helpBox;
    private TextView help;
    /** Görüntü gelmeyince açılan giriş seçicinin düğmeleri (her HDMI girişi için bir tane). */
    private LinearLayout choices;
    private boolean pickerShown;
    private boolean pickerClosed;
    private String launchParams = "";
    /** Son açılan HDMI girişi; uygulama öne gelince ya da bağlantı kopunca yeniden açılır. */
    private String tunedInput;
    private int retuneAttempts;
    private final FallbackWatch watch = new FallbackWatch();
    private boolean watching;
    /** Ekran önde mi; arka plandayken görüntü izlenmez. */
    private boolean resumed;
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
                @Override public void onVideoUnavailable(String inputId, int reason) {
                    // PS5 oyuna girerken çözünürlük ya da HDR değiştirir; TV bunu kısa bir "ayarlanıyor" olarak bildirir.
                    // O arada ekran açık kalır, yoksa TV oyunun ortasında boşta sanıp ekran koruyucuya geçer.
                    if (reason == TvInputManager.VIDEO_UNAVAILABLE_REASON_TUNING
                            || reason == TvInputManager.VIDEO_UNAVAILABLE_REASON_BUFFERING) {
                        trouble();
                        return;
                    }
                    noVideo();
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
        helpBox.setBackgroundColor(0xE6202024);
        int pad = Math.round(28 * fitScale());
        helpBox.setPadding(pad, pad, pad, pad);
        help = new TextView(this);
        help.setTextColor(Color.WHITE);
        help.setTextSize(TypedValue.COMPLEX_UNIT_PX, 30 * fitScale());
        helpBox.addView(help);
        choices = new LinearLayout(this);
        choices.setOrientation(LinearLayout.HORIZONTAL);
        choices.setVisibility(View.GONE);
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
            // Giriş boş göründüğü için kendiliğinden geçilmedi (FallbackWatch.shouldSwitch); PS5 başka girişteyse ya da
            // TV görüntüyü uygulamaya vermiyorsa kullanıcı katmanı buradan seçer.
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
        help.setText(text);
        choices.setVisibility(View.VISIBLE);
        helpBox.setVisibility(View.VISIBLE);
        (focus != null ? focus : choices.getChildAt(0)).requestFocus();
    }

    /** Açık girişin numarası, bilinmiyorsa 0. */
    private int tunedPort(List<HdmiInputs.Choice> inputs) {
        for (HdmiInputs.Choice input : inputs) {
            if (input.id.equals(tunedInput)) return input.port;
        }
        return 0;
    }

    private String choiceLabel(HdmiInputs.Choice input) {
        String label = "HDMI " + input.port;
        if (input.device != null) label += " · " + input.device;
        else if (input.connected) label += " · " + getString(R.string.picker_connected);
        return label;
    }

    private Button choiceButton(String label) {
        Button button = new Button(this);
        button.setText(label);
        button.setAllCaps(false);
        button.setTextColor(Color.WHITE);
        button.setTextSize(TypedValue.COMPLEX_UNIT_PX, 28 * fitScale());
        StateListDrawable background = new StateListDrawable();
        background.addState(new int[] {android.R.attr.state_focused}, new ColorDrawable(0xFF3B82F6));
        background.addState(new int[] {}, new ColorDrawable(0xFF3A3A40));
        button.setBackground(background);
        int pad = Math.round(16 * fitScale());
        button.setPadding(2 * pad, pad, 2 * pad, pad);
        button.setFocusable(true);
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        layout.rightMargin = pad;
        button.setLayoutParams(layout);
        return button;
    }

    /**
     * Seçilen girişi açar. 1–4 sayfa üzerinden açılır (sayı tuşuyla aynı yol): seçim kaydedilir, sonraki açılışta da o
     * giriş gelir. Daha büyük numaralar doğrudan açılır. Yeni giriş için görüntü saati baştan başlar.
     */
    private void choose(int port) {
        hidePicker();
        pickerClosed = false;
        watch.pause();
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

    @Override
    public void exit() { finish(); }

    @Override
    public void displayModeChanged(String mode) {
        if (!DisplayMode.OVERLAY.equals(mode)) return;
        if (overlayAllowed()) switchToOverlay(R.string.overlay_selected);
        else if (pickerShown) Toast.makeText(this, BuildConfig.OVERLAY_MODE
                ? R.string.overlay_permission_needed : R.string.overlay_unavailable, Toast.LENGTH_LONG).show();
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
        // PS5 görüntüsü gelirken TV boşta sanmasın: giriş açılır açılmaz ekran açık tutulur; görüntü gerçekten yoksa
        // (PS5 kapalı, kablo çıktı) noVideo() bırakır.
        keepScreenOn(true);
        tvView.setStreamVolume(1f);
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
