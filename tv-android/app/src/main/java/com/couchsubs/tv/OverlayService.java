// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.PixelFormat;
import android.media.tv.TvContract;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.provider.Settings;
import android.view.WindowManager;
import android.widget.Toast;

/**
 * Katman modu: HDMI'yı TV kendi giriş ekranında gösterir, altyazı onun üstündeki şeffaf bir pencerede durur.
 * Bazı TV'lerde (TCL ve diğer bazı Android TV / Google TV'ler) uygulamanın içindeki TvView'de görüntü siyah kalıyor;
 * TV HDMI'yı kendisi çizdiğinde bu sorun olmaz. "Diğer uygulamaların üzerinde göster" izni gerekir (bilgisayar ADB ile
 * kurarken verir).
 *
 * Pencere odak ve dokunma almaz: kumanda TV'de ve oyunda normal çalışır, CouchSubs'ın kumanda tuşları bu modda yoktur.
 * Altyazıyı uygulama içindeki modla aynı sayfa çizer (TvPage), olaylar yine bilgisayardan SSE ile gelir.
 * Kapatmak için CouchSubs yeniden açılır.
 */
public class OverlayService extends Service implements TvPage.Host {
    private static final String EXTRA_PARAMS = "params";
    private static final String CHANNEL = "overlay";
    private static final int NOTIFICATION_ID = 1;
    /** Sayfa açılışta önce kayıtlı girişi, hemen ardından bulduğu konsolu ister; TV iki kez giriş değiştirmesin. */
    private static final long INPUT_SETTLE_MS = 500;

    /** Servis çalışıyor mu; MainActivity yeniden açıldığında katmanı kapatmak için bakar. */
    static volatile boolean running;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private WindowManager windows;
    private TvPage page;
    /** TV'nin en son geçirildiği giriş (0: henüz geçilmedi). */
    private int tunedPort;
    private int pendingPort;
    private final Runnable switchInput = () -> switchInput(pendingPort);

    static void start(Context context, String params) {
        Intent intent = new Intent(context, OverlayService.class).putExtra(EXTRA_PARAMS, params == null ? "" : params);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent);
        else context.startService(intent);
    }

    static void stop(Context context) {
        context.stopService(new Intent(context, OverlayService.class));
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        goForeground();
        String params = intent == null ? null : intent.getStringExtra(EXTRA_PARAMS);
        if (page == null) {
            if (!Settings.canDrawOverlays(this) || !showWindow(params == null ? "" : params)) {
                // İzin geri alınmış ya da pencere açılamadı: uygulama içi moda dönülür.
                stopSelf();
                openApp();
                return START_NOT_STICKY;
            }
            running = true;
        } else if (params != null && !params.isEmpty()) {
            // CouchSubs yeni adresle yeniden başlatıldı; TV başka bir uygulamaya geçmiş olabilir, giriş yeniden açılır.
            tunedPort = 0;
            page.relaunch(params);
        }
        return START_NOT_STICKY;
    }

    private boolean showWindow(String params) {
        windows = (WindowManager) getSystemService(WINDOW_SERVICE);
        page = new TvPage(this, this, params, true);
        int type = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                : WindowManager.LayoutParams.TYPE_PHONE;
        WindowManager.LayoutParams layout = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        // Katman da TV'den "en az görüntü işleme" ister (Android 11+); TV destekliyorsa oyun moduna geçer.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                layout.preferMinimalPostProcessing = true;
            } catch (RuntimeException ignored) {
            }
        }
        try {
            windows.addView(page.webView, layout);
        } catch (RuntimeException e) {
            page.destroy();
            page = null;
            return false;
        }
        page.load();
        return true;
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
            page.status("sourceError");
            Toast.makeText(this, getString(R.string.overlay_choose_input, port), Toast.LENGTH_LONG).show();
            return;
        }
        Intent view = new Intent(Intent.ACTION_VIEW, TvContract.buildChannelUriForPassthroughInput(id))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(view);
            tunedPort = port;
            page.status("ready");
        } catch (ActivityNotFoundException | SecurityException e) {
            // TV bu yolla girişe geçemiyor: kullanıcı girişi kumandadan seçer, altyazı yine üstte görünür.
            tunedPort = port;
            page.status("sourceError");
            Toast.makeText(this, getString(R.string.overlay_choose_input, port), Toast.LENGTH_LONG).show();
        }
    }

    @Override
    public void exit() { stopSelf(); }

    /** Bilgisayarda "Uygulama içinde" seçildi: katman kapanır, CouchSubs öne gelir. */
    @Override
    public void displayModeChanged(String mode) {
        if (!DisplayMode.IN_APP.equals(mode)) return;
        stopSelf();
        openApp();
    }

    private void openApp() {
        Intent open = new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(MainActivity.EXTRA_FROM_OVERLAY, true);
        try {
            startActivity(open);
        } catch (RuntimeException ignored) {
            // Arka plandan açılamadı; kullanıcı CouchSubs'ı kendisi açar.
        }
    }

    private void goForeground() {
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
    }

    @Override
    public void onDestroy() {
        running = false;
        ui.removeCallbacksAndMessages(null);
        if (page != null) {
            try { windows.removeView(page.webView); } catch (RuntimeException ignored) { /* pencere zaten yok */ }
            page.destroy();
            page = null;
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}
