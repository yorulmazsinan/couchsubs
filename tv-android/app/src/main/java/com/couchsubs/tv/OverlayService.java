// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import android.Manifest;
import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.ActivityNotFoundException;
import android.content.ComponentName;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.graphics.PixelFormat;
import android.media.tv.TvContract;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.Toast;

import java.util.List;

/**
 * Katman modu: HDMI'yı TV kendi giriş ekranında gösterir, altyazı onun üstündeki şeffaf bir pencerede durur.
 * Bazı TV'lerde (TCL ve diğer bazı Android TV / Google TV'ler) uygulamanın içindeki TvView'de görüntü siyah kalıyor;
 * TV HDMI'yı kendisi çizdiğinde bu sorun olmaz. "Diğer uygulamaların üzerinde göster" izni gerekir (bilgisayar ADB ile
 * kurarken verir).
 *
 * Pencere odak almaz: kumanda TV'de ve oyunda normal çalışır, CouchSubs'ın kumanda tuşları bu modda yoktur. Dokunmaya
 * kapatılmaz (bkz. showWindow: Android 12L+ öyle pencereyi %80 opaklıkla çizer), dokunmalar sayfada yutulur.
 * Altyazıyı uygulama içindeki modla aynı sayfa çizer (TvPage), olaylar yine bilgisayardan SSE ile gelir.
 * Kapatmak için CouchSubs yeniden açılır. Bağlantı OverlayIdle.EXIT_AFTER_MS boyunca kurulmazsa (bilgisayar/telefon
 * kapandı) katman kendini kapatır; pencere boşken ekranda hiçbir şey çizilmez (beta.104'e kadar sağ üstte bağlantı
 * noktası vardı). Pencerenin eklenmesi ve kaldırılması nedeniyle TV olay günlüğüne yazılır (TvEvents).
 */
public class OverlayService extends Service implements TvPage.Host {
    private static final String TAG = "CouchSubsOverlay";
    private static final String EXTRA_PARAMS = "params";
    private static final String CHANNEL = "overlay";
    private static final int NOTIFICATION_ID = 1;
    /** Sayfa açılışta önce kayıtlı girişi, hemen ardından bulduğu konsolu ister; TV iki kez giriş değiştirmesin. */
    private static final long INPUT_SETTLE_MS = 500;

    /** Servis çalışıyor mu; MainActivity yeniden açıldığında katmanı kapatmak için bakar. */
    static volatile boolean running;
    /** Çalışan katman (yoksa null): bilgisayarın/telefonun adres yayını ona iletilir (bkz. AddressReceiver). */
    private static volatile OverlayService current;

    /** Bilgisayar/telefon adresini bildirdi: katmandaki sayfa o adrese geçer; TV'nin girişi değişmez. */
    static void deliver(String params) {
        OverlayService service = current;
        if (service == null) return;
        service.ui.post(() -> { if (service.page != null) service.page.relaunch(params); });
    }

    private final Handler ui = new Handler(Looper.getMainLooper());
    private WindowManager windows;
    private TvPage page;
    /** TV'nin en son geçirildiği giriş (0: henüz geçilmedi). */
    private int tunedPort;
    /** Bilgi panelinin tanı satırı için girişe nasıl geçildiği; sayfanın iş parçacığından okunur. */
    private volatile String inputState = "none";
    private int pendingPort;
    private final Runnable switchInput = () -> switchInput(pendingPort);
    /** WebView işleminin gidişleri (bkz. pageGone): kısa sürede çok giderse katman bırakılır. */
    private final PageRestarts restarts = new PageRestarts();
    /** Sayfanın bağlantısı: uzun süre yoksa katman kapanır (bkz. OverlayIdle). */
    private final OverlayIdle idle = new OverlayIdle();
    private final Runnable idleCheck = this::checkIdle;
    /** Servisin neden durdurulduğu (TvEvents "overlay remove" satırı); boşsa dışarıdan durduruldu (CouchSubs, ayarlar). */
    private String stopReason;
    /** Pencere donanımla mı yazılımla mı çizilir (#1074); ilk pencerede kurulur. */
    private OverlayDrawing drawing;
    /** Pencereye eklenen görünüm: donanımlıysa sayfanın WebView'i, yazılımlıysa onu saran çerçeve. */
    private View root;
    private boolean proofPending;
    private final Runnable proofSurvived = () -> {
        proofPending = false;
        if (page != null && drawing != null) drawing.survived();
    };
    private static final long PROOF_DRAW_DELAY_MS = 100;
    /** Donanım denemesinin kanıt çizimi: pencere yeniden çizilir (bkz. watchDraws). */
    private final Runnable proofDraw = () -> { if (root != null) root.invalidate(); };

    /**
     * Servisi başlatır; başlatılamadıysa false döner ve çağıran uygulama içinde kalır. Android 12+ arka plandan ön plan
     * servisi başlatmayı kısıtlar (ForegroundServiceStartNotAllowedException), bazı TV'ler SecurityException atar;
     * eskiden bu istisna uygulamayı kapatırdı.
     */
    static boolean start(Context context, String params) {
        Intent intent = new Intent(context, OverlayService.class).putExtra(EXTRA_PARAMS, params == null ? "" : params);
        try {
            ComponentName started = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                    ? context.startForegroundService(intent)
                    : context.startService(intent);
            // Servis bu derlemede yoksa (Play paketi) null döner.
            return started != null;
        } catch (RuntimeException e) {
            Log.w(TAG, "overlay service could not start", e);
            return false;
        }
    }

    static boolean canDrawOverlays(Context context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return Settings.canDrawOverlays(context);
        }
        return context.checkCallingOrSelfPermission(Manifest.permission.SYSTEM_ALERT_WINDOW)
                == PackageManager.PERMISSION_GRANTED;
    }

    static void stop(Context context) {
        context.stopService(new Intent(context, OverlayService.class));
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (!goForeground()) {
            // TV ön plan servisine izin vermedi: katman açılamaz, uygulama içi moda dönülür ve nedeni söylenir.
            stop("foreground refused");
            if (page == null) {
                TvPage.markOverlayBroken(this);
                openApp(DisplayMode.FAILED_FOREGROUND);
            }
            return START_NOT_STICKY;
        }
        String params = intent == null ? null : intent.getStringExtra(EXTRA_PARAMS);
        if (page == null) {
            if (!canDrawOverlays(this)) {
                // İzin geri alınmış: uygulama içi moda dönülür, iznin nasıl verileceği gösterilir.
                stop("no permission");
                openApp(DisplayMode.FAILED_PERMISSION);
                return START_NOT_STICKY;
            }
            if (!showWindow(params == null ? "" : params)) {
                // İzin var ama TV katman penceresini açtırmadı (BadTokenException ya da benzeri).
                stop("window refused");
                TvPage.markOverlayBroken(this);
                openApp(DisplayMode.FAILED_WINDOW);
                return START_NOT_STICKY;
            }
            running = true;
            current = this;
        } else if (params != null && !params.isEmpty()) {
            // CouchSubs yeni adresle yeniden başlatıldı; TV başka bir uygulamaya geçmiş olabilir, giriş yeniden açılır.
            tunedPort = 0;
            page.relaunch(params);
        }
        return START_NOT_STICKY;
    }

    private boolean showWindow(String params) {
        windows = (WindowManager) getSystemService(WINDOW_SERVICE);
        if (drawing == null) drawing = new OverlayDrawing(new PrefsStore(this), lastExitNativeCrash(this));
        boolean software = drawing.software();
        page = new TvPage(this, this, params, true, software);
        root = software ? softwareRoot(page.webView) : page.webView;
        int type = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                : WindowManager.LayoutParams.TYPE_PHONE;
        WindowManager.LayoutParams layout = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        // Pencere bilerek dokunmaya kapatılmaz (FLAG_NOT_TOUCHABLE yok). Android 12L/13+ dokunmayı alttaki uygulamaya
        // geçiren bindirme penceresinin opaklığını InputManager#getMaximumObscuringOpacityForTouch (varsayılan 0.8) ile
        // sınırlar (DisplayPolicy.adjustWindowParamsLw, b/218777508): bütün pencere %80 çizilir, "Tam" koyulukta bile
        // çeviri kutusunun arkasından İngilizce altyazı görünürdü (Philips OLED810 Google TV). Opaklık sayfanın kendi
        // ayarıdır (Arka plan koyuluğu); pencere hep tam opak. Kumanda tuşları FLAG_NOT_FOCUSABLE ile TV'de ve oyunda
        // kalır; TV'de dokunmatik yok, olası dokunmalar (fare/hava faresi) yutulur, sayfada tıklanacak bir şey yok.
        layout.alpha = 1f;
        // Katman da TV'den "en az görüntü işleme" ister (Android 11+); TV destekliyorsa oyun moduna geçer.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                layout.preferMinimalPostProcessing = true;
            } catch (RuntimeException ignored) {
            }
        }
        page.webView.setOnTouchListener((view, event) -> true);
        drawing.windowShown(SystemClock.elapsedRealtime());
        try {
            windows.addView(root, layout);
        } catch (RuntimeException e) {
            Log.w(TAG, "overlay window could not be added", e);
            drawing.closed();
            page.destroy();
            page = null;
            root = null;
            return false;
        }
        // Pencerenin ilk çizimi bir sonraki karede: dinleyici eklendikten hemen sonra kurulsa da kaçmaz.
        if (!software) {
            watchDraws(root);
            // Altyazı gelmezse şeffaf sayfa hiç yeniden çizilmez, deneme açık kalır; süreç o arada başka nedenle ölürse
            // (güncelleme, kapatıp açma) TV yazılıma geçiyordu (#1255). Kanıt çizimi süre dolunca istenir.
            ui.postDelayed(proofDraw, OverlayDrawing.SETTLE_MS + PROOF_DRAW_DELAY_MS);
        }
        Log.i(TAG, "overlay window " + drawing.diagnostics());
        event("overlay add (" + (software ? "software" : "hardware") + ")");
        idle.started(SystemClock.elapsedRealtime());
        scheduleIdle();
        page.load();
        return true;
    }

    /** Sayfanın bağlantısı değişti: kopuksa katmanın kapanacağı an yeniden kurulur. */
    @Override
    public void connectionChanged(boolean open) {
        if (page == null) return;
        if (idle.connection(open, SystemClock.elapsedRealtime())) scheduleIdle();
    }

    private void scheduleIdle() {
        ui.removeCallbacks(idleCheck);
        long at = idle.exitAt();
        if (at < 0) return;
        ui.postDelayed(idleCheck, Math.max(0, at - SystemClock.elapsedRealtime()));
    }

    /** Bağlantı EXIT_AFTER_MS'dir yok: bilgisayar/telefon kapanmış, katman (pencere ve ön plan servisi) kapanır. */
    private void checkIdle() {
        if (page == null) return;
        long now = SystemClock.elapsedRealtime();
        if (!idle.expired(now)) {
            scheduleIdle();
            return;
        }
        Log.i(TAG, "overlay idle: no connection, closing");
        stop("idle, no connection " + idle.secondsSince(now) + "s");
    }

    /** Servisi durdurur; neden onDestroy'daki "overlay remove" satırına yazılır. */
    private void stop(String why) {
        if (stopReason == null) stopReason = why;
        stopSelf();
    }

    private void event(String line) {
        TvEvents.of(this).add(line, System.currentTimeMillis());
    }

    /**
     * Yazılımla çizilen pencerenin kökü (#1074). Android, üst penceresi olmayan bir pencereyi (servisin bindirmesi),
     * eklenen görünümün bağlamındaki uygulama bilgisinde donanım hızlandırma açıksa donanımla çizer (WindowManagerGlobal
     * .addView: FLAG_HARDWARE_ACCELERATED). Kök çerçevenin bağlamı bu bayrağı kapalı gösterir; uygulamanın geri kalanı
     * (CouchSubs ekranı) donanımla çizilmeye devam eder. Sayfa çerçevenin içinde, kendi katmanı da yazılımla.
     */
    private View softwareRoot(View content) {
        FrameLayout frame = new FrameLayout(new SoftwareWindowContext(this));
        frame.addView(content, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        return frame;
    }

    /** Donanımlı pencerenin HDMI açıkkenki çizimleri: biri SURVIVE_MS atlatılırsa donanım bu TV'de çalışıyor. */
    private void watchDraws(View view) {
        View watched = view;
        view.getViewTreeObserver().addOnDrawListener(new ViewTreeObserver.OnDrawListener() {
            @Override
            public void onDraw() {
                if (proofPending || page == null || root != watched) return;
                if (!drawing.proves(SystemClock.elapsedRealtime())) return;
                proofPending = true;
                ui.postDelayed(proofSurvived, OverlayDrawing.SURVIVE_MS);
            }
        });
    }

    /** Uygulama bilgisinde donanım hızlandırması kapalı görünen bağlam (bkz. softwareRoot). */
    private static final class SoftwareWindowContext extends ContextWrapper {
        private final ApplicationInfo info;

        SoftwareWindowContext(Context base) {
            super(base);
            info = new ApplicationInfo(base.getApplicationInfo());
            info.flags &= ~ApplicationInfo.FLAG_HARDWARE_ACCELERATED;
        }

        @Override
        public ApplicationInfo getApplicationInfo() { return info; }
    }

    /**
     * Uygulamanın önceki ana sürecinin son çıkışı yerel çökme miydi (#1255; bkz. OverlayDrawing). Android 10 ve öncesinde
     * ya da kayıt yoksa null: neden bilinmez, eski davranış.
     */
    static Boolean lastExitNativeCrash(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null;
        try {
            ActivityManager manager = (ActivityManager) context.getSystemService(ACTIVITY_SERVICE);
            if (manager == null) return null;
            String main = context.getApplicationInfo().processName;
            List<ApplicationExitInfo> exits = manager.getHistoricalProcessExitReasons(context.getPackageName(), 0, 8);
            for (ApplicationExitInfo exit : exits) {
                // Yalnız ana süreç; WebView'in yalıtılmış süreçleri sayılmaz. Liste en yeniden eskiye.
                if (main != null && !main.equals(exit.getProcessName())) continue;
                return exit.getReason() == ApplicationExitInfo.REASON_CRASH_NATIVE;
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "exit reasons unavailable", e);
        }
        return null;
    }

    /** OverlayDrawing'in kalıcı deposu; commit: deneme işareti çizimden (olası çökmeden) önce diskte olmalı. */
    private static final class PrefsStore implements OverlayDrawing.Store {
        private final SharedPreferences prefs;

        PrefsStore(Context context) { prefs = context.getSharedPreferences("couchsubs", Context.MODE_PRIVATE); }

        @Override
        public boolean get(String key) { return prefs.getBoolean(key, false); }

        @Override
        public void put(String key, boolean value) { prefs.edit().putBoolean(key, value).commit(); }
    }

    /** TV'yi kendi HDMI giriş ekranına geçirir; altyazı penceresi üstte kalır. */
    @Override
    public void showHdmi(int port) {
        if (page == null) return;
        if (port == tunedPort) {
            page.status("ready");
            return;
        }
        pendingPort = port;
        ui.removeCallbacks(switchInput);
        ui.postDelayed(switchInput, INPUT_SETTLE_MS);
    }

    private void switchInput(int port) {
        if (page == null) return;
        String id = HdmiInputs.idForPort(this, port);
        if (id == null) {
            // TV girişlerini uygulamalara açmıyor (#275): girişe biz geçemiyoruz, kullanıcı kumandadan geçer; altyazı
            // yine görüntünün üstünde çıkar. Eskiden yalnız "kaynak desteklenmiyor" yazıyordu.
            tunedPort = port;
            inputState = "HDMI " + port + " not offered";
            page.status("sourceError");
            Toast.makeText(this, getString(R.string.overlay_choose_input, port), Toast.LENGTH_LONG).show();
            return;
        }
        Intent view = new Intent(Intent.ACTION_VIEW, TvContract.buildChannelUriForPassthroughInput(id))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(view);
            tunedPort = port;
            inputState = "HDMI " + port + " opened";
            if (drawing != null) {
                drawing.inputOpened(SystemClock.elapsedRealtime());
                ui.removeCallbacks(proofDraw);
                ui.postDelayed(proofDraw, OverlayDrawing.INPUT_SETTLE_MS + PROOF_DRAW_DELAY_MS);
            }
            page.status("ready");
        } catch (ActivityNotFoundException | SecurityException e) {
            // TV bu yolla girişe geçemiyor: kullanıcı girişi kumandadan seçer, altyazı yine üstte görünür.
            tunedPort = port;
            inputState = "HDMI " + port + " refused";
            page.status("sourceError");
            Toast.makeText(this, getString(R.string.overlay_choose_input, port), Toast.LENGTH_LONG).show();
        }
    }

    @Override
    public void exit() { stop("exit"); }

    /** Bilgi panelinin tanı satırı: katman modu ve TV'nin girişe nasıl geçirildiği. */
    @Override
    public String diagnostics() {
        OverlayDrawing current = drawing;
        return "mode overlay · input " + inputState + (current == null ? "" : " · " + current.diagnostics());
    }

    /**
     * Katmandaki WebView işlemi çöktü ya da sistem kapattı (#616: Philips Android 8'de HDMI girişi açılınca). Eskiden
     * Android bunu ele alınmadı sayıp uygulamayı kapatıyordu, katman sessizce kayboluyordu. Sayfa yeniden kurulur; kısa
     * sürede birkaç kez yinelenirse katman bırakılır ve nedeni söylenir.
     *
     * Katman bırakılırken CouchSubs ekranı öne getirilmez (0.9.41'de getiriliyordu): katmanı kullanan TV'lerin çoğu HDMI'yı
     * uygulamanın içinde gösteremiyor. Oyunun ortasında açılan ekran orada siyah kalır, 10 sn sonra yeniden katmana geçilir
     * (FallbackWatch), sayfa yine gider ve görüntü tekrar tekrar kararır. Görüntü TV'nin kendi giriş ekranında kalır.
     */
    @Override
    public void pageGone(boolean crashed) {
        String params = page == null ? "" : page.launchParams();
        removeWindow(crashed ? "page crashed" : "page gone");
        // Donanımlı pencerede WebView işlemi çöktü: GPU yüzeyi ayrılamıyor olabilir (#1074), sonraki pencere yazılımla.
        if (crashed && drawing != null && drawing.rendererCrashed()) {
            Log.w(TAG, "overlay renderer crashed with hardware drawing; next window draws in software");
        }
        if (!restarts.allow(SystemClock.elapsedRealtime())) {
            Log.w(TAG, "overlay page keeps dying; leaving overlay mode");
            TvPage.markOverlayBroken(this);
            Toast.makeText(this, R.string.overlay_renderer_failed, Toast.LENGTH_LONG).show();
            stop("page keeps dying");
            return;
        }
        ui.postDelayed(() -> {
            if (!running || page != null) return;
            if (!showWindow(params == null ? "" : params)) {
                stop("window refused");
                TvPage.markOverlayBroken(this);
                openApp(DisplayMode.FAILED_WINDOW);
            }
        }, PageRestarts.DELAY_MS);
    }

    /**
     * Konsolun girişi bulunamadı: TV HDMI 1'e geçirilmez (#367), olduğu girişte kalır. Katmanda kumanda yok, seçici
     * gösterilemez; kullanıcı girişi TV'nin kumandasıyla seçer, altyazı yine üstte çıkar.
     */
    @Override
    public void chooseInput() {
        if (page == null) return;
        Toast.makeText(this, R.string.overlay_choose_console_input, Toast.LENGTH_LONG).show();
    }

    /** Bilgisayarda "Uygulama içinde" seçildi: katman kapanır, CouchSubs öne gelir. */
    @Override
    public void displayModeChanged(String mode) {
        if (!DisplayMode.IN_APP.equals(mode)) return;
        stop("in-app mode");
        openApp(null);
    }

    /** CouchSubs'ı öne getirir; failure doluysa katman açılamamıştır: ekran nedenini söyler, yeniden katmana geçmez. */
    private void openApp(String failure) {
        Intent open = new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(MainActivity.EXTRA_FROM_OVERLAY, true);
        if (failure != null) open.putExtra(MainActivity.EXTRA_OVERLAY_FAILED, failure);
        try {
            startActivity(open);
        } catch (RuntimeException ignored) {
            // Arka plandan açılamadı; kullanıcı CouchSubs'ı kendisi açar.
        }
    }

    /** Ön plan servisine geçer (Android 14'te tür zorunlu: specialUse). TV izin vermezse false döner, uygulama kapanmaz. */
    private boolean goForeground() {
        NotificationManager notifications = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notifications.createNotificationChannel(
                    new NotificationChannel(CHANNEL, "CouchSubs", NotificationManager.IMPORTANCE_LOW));
            builder = new Notification.Builder(this, CHANNEL);
        } else {
            builder = new Notification.Builder(this);
        }
        Notification notification = builder
                .setSmallIcon(R.mipmap.icon)
                .setContentTitle("CouchSubs")
                .setContentText(getString(R.string.overlay_running))
                .setOngoing(true)
                .build();
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }
            return true;
        } catch (RuntimeException e) {
            Log.w(TAG, "overlay service could not go foreground", e);
            return false;
        }
    }

    @Override
    public void onDestroy() {
        running = false;
        if (current == this) current = null;
        ui.removeCallbacksAndMessages(null);
        removeWindow(stopReason == null ? "service stopped" : stopReason);
        if (drawing != null) drawing.closed();
        super.onDestroy();
    }

    private void removeWindow(String why) {
        ui.removeCallbacks(proofSurvived);
        ui.removeCallbacks(proofDraw);
        ui.removeCallbacks(idleCheck);
        proofPending = false;
        if (page != null) {
            event("overlay remove (" + why + ")");
            try { windows.removeView(root); } catch (RuntimeException ignored) { /* pencere zaten yok */ }
            page.destroy();
            page = null;
        }
        root = null;
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}
