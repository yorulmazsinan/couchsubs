// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import android.annotation.TargetApi;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InterfaceAddress;
import java.net.NetworkInterface;
import java.util.Collections;

/**
 * LG ve Samsung'la ortak arayüzü (altyazı, üst üste satırlar, renk, boyut) çalıştıran şeffaf WebView ve sayfanın
 * "AndroidTV" köprüsü. Uygulama içi mod (MainActivity) ve katman modu (OverlayService) aynı sayfayı kullanır;
 * HDMI'yı nasıl gösterecekleri kendilerine kalır.
 */
final class TvPage {
    /** Sayfayı barındıran taraf. Hepsi UI iş parçacığında çağrılır. */
    interface Host {
        void showHdmi(int port);

        /** Konsolun girişi bulunamadı: hiçbir giriş açılmaz, kullanıcıdan girişi seçmesi istenir (#367). */
        void chooseInput();

        void exit();

        /** Bilgisayar görüntü modunu değiştirdi (yeni mod kaydedildikten sonra çağrılır). */
        void displayModeChanged(String mode);

        /**
         * Sayfanın WebView işlemi (renderer) çöktü ya da sistem onu kapattı. Bu sayfa artık kullanılamaz: kaldırılıp yenisi
         * kurulmalı. Android 8+ bunu bildirir; ele alınmazsa uygulamanın tamamı kapanır (#616).
         */
        void pageGone(boolean crashed);

        /**
         * Bilgi panelinin tanı satırı için görüntü modu ve HDMI görüntüsünün durumu ("mode inApp · tv available").
         * Sayfanın iş parçacığından çağrılır; yalnız iş parçacığı güvenli alanlar okunmalı.
         */
        String diagnostics();
    }

    private static final String TAG = "CouchSubsPage";

    private static final String PREFS = "couchsubs";
    private static final String KEY_DISPLAY_MODE = "displayMode";

    final WebView webView;
    private final Context context;
    private final Host host;
    private final boolean overlay;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private String launchParams;

    TvPage(Context context, Host host, String launchParams, boolean overlay) {
        this(context, host, launchParams, overlay, false);
    }

    /**
     * software: sayfa yazılımla çizilen pencerede (katman, bkz. OverlayDrawing) duruyor; WebView kendi katmanını da
     * yazılımla çizer, GPU yüzeyi istemez (#1074).
     */
    TvPage(Context context, Host host, String launchParams, boolean overlay, boolean software) {
        this.context = context;
        this.host = host;
        this.launchParams = launchParams;
        this.overlay = overlay;

        webView = new WebView(context);
        webView.setBackgroundColor(Color.TRANSPARENT);
        webView.setLayerType(software ? View.LAYER_TYPE_SOFTWARE : View.LAYER_TYPE_HARDWARE, null);
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(true);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        // Türkçe dublaj: bilgisayardan gelen ses kumandaya basılmadan çalabilsin.
        settings.setMediaPlaybackRequiresUserGesture(false);
        // Sayfanın 1920 piksellik viewport'u kullanılır ve ekrana sığdırılır (bkz. index.html); yoksa yazılar iki kat büyük.
        settings.setUseWideViewPort(true);
        settings.setLoadWithOverviewMode(true);
        settings.setSupportZoom(false);
        // Yazı boyunu yalnız sayfa belirler (#1255, #1259): cihazın yazı ölçeği (Ayarlar › Erişilebilirlik › Yazı boyutu)
        // ve WebView'in yazı otomatik boyutlandırması altyazıyı büyütüp küçültmez; Katman ve Uygulama içinde aynı.
        settings.setTextZoom(100);
        settings.setLayoutAlgorithm(WebSettings.LayoutAlgorithm.NORMAL);
        settings.setMinimumFontSize(1);
        settings.setMinimumLogicalFontSize(1);
        // Ölçek fiziksel piksel başına yüzde: 1920 CSS pikseli ekranın tam genişliğine sığar (1080p'de %100).
        webView.setInitialScale(fitScalePercent());
        webView.addJavascriptInterface(new Bridge(), "AndroidTV");
        webView.setWebViewClient(new PageClient());
        // Katman penceresi hiçbir zaman gizlenerek açılmaz. 0.9.42'de sayfa yüklenene kadar görünmez tutuluyordu (alfa 0,
        // yükleme bitince 1): bazı Android TV'lerde (Philips) katman bir daha görünmedi, altyazı HDMI görüntüsünün üstüne
        // hiç çıkmadı. Zemin zaten şeffaftır; yüklenmemiş sayfa görüntüyü örtmez.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Altyazı katmanı görünmese de (TV'nin HDMI ekranı öndeyken) WebView işlemi önemli sayılsın; düşük bellekli
            // TV'lerde sistem onu ilk kapatılacaklar arasına koymasın.
            webView.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false);
        }
    }

    /** WebView işlemi giderse uygulama kapanmasın diye bildirimi üstlenir (bkz. Host.pageGone). */
    private final class PageClient extends WebViewClient {
        private boolean gone;

        @TargetApi(Build.VERSION_CODES.O)
        @Override
        public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
            boolean crashed = detail.didCrash();
            Log.w(TAG, "WebView renderer gone: crashed=" + crashed + " priorityAtExit=" + detail.rendererPriorityAtExit()
                    + " overlay=" + overlay);
            if (!gone) {
                gone = true;
                ui.removeCallbacksAndMessages(null);
                host.pageGone(crashed);
            }
            return true;
        }
    }

    void load() {
        webView.loadUrl("file:///android_asset/tv/index.html");
    }

    /** Uygulama yeniden başlatıldı: yeni parametreler sayfaya iletilir. */
    void relaunch(String params) {
        if (params == null || params.isEmpty()) return;
        launchParams = params;
        evaluate("window.__onRelaunch(" + quoted(params) + ")");
    }

    String launchParams() { return launchParams; }

    void status(String kind) {
        evaluate("window.__onHdmiStatus(" + quoted(kind) + ")");
    }

    /** Uygulama arka plana geçti ya da öne geldi: arka plandayken dublaj sesi çıkmaz (bkz. platform.js). */
    void background(boolean hidden) {
        evaluate("window.__onBackground && window.__onBackground(" + hidden + ")");
    }

    void key(int code) {
        evaluate("window.__onKey(" + code + ")");
    }

    void destroy() {
        ui.removeCallbacksAndMessages(null);
        webView.destroy();
    }

    private void evaluate(String script) {
        ui.post(() -> webView.evaluateJavascript(script, null));
    }

    private static String quoted(String text) {
        return "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }

    /** Sayfanın 1920 CSS piksellik genişliğini ekranın fiziksel genişliğine sığdıran WebView ölçeği (yüzde). */
    private int fitScalePercent() {
        DisplayMetrics metrics = new DisplayMetrics();
        WindowManager windows = (WindowManager) context.getSystemService(Context.WINDOW_SERVICE);
        windows.getDefaultDisplay().getRealMetrics(metrics);
        int width = Math.max(metrics.widthPixels, metrics.heightPixels);
        return width > 0 ? Math.max(1, Math.round(width * 100f / 1920f)) : 0;
    }

    // --- Görüntü modu tercihi ---

    static String storedDisplayMode(Context context) {
        return DisplayMode.orAuto(prefs(context).getString(KEY_DISPLAY_MODE, null));
    }

    /** Yeni modu kaydeder; kayıtlı olandan farklıysa true döner. */
    static boolean storeDisplayMode(Context context, String mode) {
        if (!DisplayMode.isChange(storedDisplayMode(context), mode)) return false;
        prefs(context).edit().putString(KEY_DISPLAY_MODE, DisplayMode.normalize(mode)).apply();
        return true;
    }

    private static final String KEY_AUTO_OVERLAY_TOLD = "autoOverlayTold";

    /** Otomatik tercihle ilk kez katmanda açılıyor mu (bilgi bir kez gösterilir); işaret burada konur. */
    static boolean firstAutoOverlay(Context context) {
        SharedPreferences prefs = prefs(context);
        if (prefs.getBoolean(KEY_AUTO_OVERLAY_TOLD, false)) return false;
        prefs.edit().putBoolean(KEY_AUTO_OVERLAY_TOLD, true).apply();
        return true;
    }

    private static final String KEY_OVERLAY_BROKEN = "overlayBroken";

    /** Katman bu TV'de açılamadı ya da sayfası art arda çöktü (bkz. DisplayMode.rescueToOverlay). */
    static boolean overlayBroken(Context context) {
        return prefs(context).getBoolean(KEY_OVERLAY_BROKEN, false);
    }

    static void markOverlayBroken(Context context) {
        prefs(context).edit().putBoolean(KEY_OVERLAY_BROKEN, true).apply();
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private class Bridge {
        @JavascriptInterface
        public String launchParams() { return launchParams; }

        @JavascriptInterface
        public void showHdmi(int port) { ui.post(() -> host.showHdmi(port)); }

        @JavascriptInterface
        public int consolePort() { return HdmiInputs.consolePort(context); }

        /** Açılışta açılacak giriş (bkz. HdmiInputs.pick): "3:console" gibi; "0:" ise bilinmiyor. */
        @JavascriptInterface
        public String pickPort(int saved) {
            HdmiInputs.Pick pick = HdmiInputs.pick(context, saved);
            return pick.port + ":" + (pick.reason == null ? "" : pick.reason);
        }

        @JavascriptInterface
        public void chooseInput() { ui.post(host::chooseInput); }

        /** Kullanıcı "0" ile elle seçimi bıraktı: uygulamanın kaydettiği giriş de unutulur. */
        @JavascriptInterface
        public void forgetInput() { HdmiInputs.forget(context); }

        @JavascriptInterface
        public String localAddress() {
            try {
                for (NetworkInterface face : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                    if (!face.isUp() || face.isLoopback()) continue;
                    for (InetAddress address : Collections.list(face.getInetAddresses())) {
                        if (address instanceof Inet4Address && address.isSiteLocalAddress()) return address.getHostAddress();
                    }
                }
            } catch (Exception ignored) {
                return "";
            }
            return "";
        }

        /** localAddress'in ağ öneki (ör. 22); bilinemezse 0. Uygulama /24'ten büyük ağları da tarar (en çok /22). */
        @JavascriptInterface
        public int localPrefix() {
            try {
                for (NetworkInterface face : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                    if (!face.isUp() || face.isLoopback()) continue;
                    for (InterfaceAddress entry : face.getInterfaceAddresses()) {
                        InetAddress address = entry.getAddress();
                        if (address instanceof Inet4Address && address.isSiteLocalAddress()) return entry.getNetworkPrefixLength();
                    }
                }
            } catch (Exception ignored) {
                return 0;
            }
            return 0;
        }

        @JavascriptInterface
        public void exit() { ui.post(host::exit); }

        /** Bekleyen TV olay satırları (TvEvents), satır satır; sayfa bilgisayara/telefona gönderir (app.js tvLog). */
        @JavascriptInterface
        public String takeEvents() {
            StringBuilder out = new StringBuilder();
            for (String line : TvEvents.of(context).take(System.currentTimeMillis())) {
                out.append(out.length() == 0 ? "" : "\n").append(line);
            }
            return out.toString();
        }

        /** Sayfa katman penceresinde mi çalışıyor (kumanda yok, bekleme kutusu gizlenir). */
        @JavascriptInterface
        public boolean isOverlay() { return overlay; }

        /** Bilgisayarın style olayındaki displayMode; yalnız değişiklik ise modu değiştirir. */
        @JavascriptInterface
        public void setDisplayMode(String mode) {
            ui.post(() -> {
                if (storeDisplayMode(context, mode)) host.displayModeChanged(DisplayMode.normalize(mode));
            });
        }

        /** Bilgi panelinin tanı satırı: görüntü modu, TvView durumu, cihazın üreticisi, modeli ve Android sürümü. */
        @JavascriptInterface
        public String diagnostics() {
            String state;
            try {
                state = host.diagnostics();
            } catch (RuntimeException e) {
                state = "";
            }
            // TV'nin bildirdiği bütün girişler (#1292): HDMI girişi farklı türde görünen TV/projektörler buradan anlaşılır.
            String inputs = HdmiInputs.describe(context);
            return (state == null || state.isEmpty() ? "" : state + " · ") + Build.MANUFACTURER + " " + Build.MODEL
                    + " · Android " + Build.VERSION.RELEASE + " (" + Build.VERSION.SDK_INT + ")"
                    + (inputs.isEmpty() ? "" : " · inputs " + inputs);
        }

        /** Panelde görünen sürüm: Android uygulamasının kendi sürümü (ortak sayfadaki sayı diğer TV'lerinkidir). */
        @JavascriptInterface
        public String appVersion() {
            try {
                return context.getPackageManager().getPackageInfo(context.getPackageName(), 0).versionName;
            } catch (PackageManager.NameNotFoundException e) {
                return "";
            }
        }
    }
}
