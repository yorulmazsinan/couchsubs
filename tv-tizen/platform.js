// SPDX-License-Identifier: AGPL-3.0-only
// Tizen'e (Samsung TV) özgü işler. webOS karşılığı: tv-webos/platform.js
// HDMI görüntüsü resmî TVWindow API'siyle HTML katmanının arkasında gösterilir.
(function () {
  'use strict';

  var KEYS = ['0', '1', '2', '3', '4', 'ColorF0Red', 'ColorF1Green', 'ColorF2Yellow', 'ColorF3Blue'];
  // Çözünürlük değişikliği dinleyicisi (bir kez kurulur) ve güncel değeri alan işlev.
  var resolutionListener = null;
  var resolutionCallback = null;
  // HDMI görüntüsü uygulama yüzeyinin tamamını kaplar (yüzde, ekran kökenli; Samsung TVWindow API).
  var FULL_SCREEN = ['0', '0', '100%', '100%'];
  // 16:9'dan belirgin geniş yüzey (21:9 = 2,33; 3440x1440 = 2,39; 32:9 = 3,56). 16:9 (1,78) ve yuvarlama payı altında.
  var WIDE_RATIO = 1.9;
  // Sayfa her TV'de 1080 CSS piksel yükseklikte düzenlenir (index.html: width=1920); geniş ekranda da öyle kalır.
  var PAGE_HEIGHT = 1080;
  // 16:9 (ve dar) yüzeyde görünüm genişliği: ortak index.html'deki gibi.
  var NARROW_WIDTH = 1920;

  // --- Uygulama yüzeyi ve koordinat uzayı (0.9.55) ---
  // Samsung'un "Managing Screen Resolution" belgesi: UHD (4K, 8K) Samsung TV'de web uygulamasının standart çözünürlüğü
  // 1920x1080'dir; TV uygulamayı ve TVWindow'un HDMI düzlemini panele kendisi büyütür. Sayfa ve TVWindow pikseli aynı
  // 1920x1080 uzayındadır, '100%' penceresi paneli doldurur.
  // 0.9.27–0.9.54 config.xml'de base_screen_resolution=fullscreen vardı. Bu değer Samsung'un base_screen_resolution
  // belgesinde yok (belgede yalnız "extensive", yalnız 23TV_PREMIUM2 model grubunda); 4K/8K TV'de uygulama yüzeyini
  // panelin kendi pikselinde açıyor (QE75QN900A: 'scr 3840x2160 ... vv 2'). TVWindow ise 1920x1080 uzayında kalıp
  // büyütülmeden çiziliyordu: PS5 görüntüsü sol üst çeyrekte. 0.9.47–0.9.54'teki Sarı yöntemleri (görünümü genişletip
  // daraltma, CSS zoom, 8K genişlik) bu yüzeyi düzeltemedi. Ayar kaldırıldı, paketin görünümü sabit width=1920
  // (scripts/package-tizen.sh): Samsung belgesindeki standart yapı.
  // Tanı satırı uzayı yazar: 'space std 1920x1080' (standart uzay) ya da 'space native 3840x2160 page 1920x1080'
  // (yüzey panel pikselinde; olmaması gerekir).
  function viewportFor(width, height) {
    if (!(width > 0) || !(height > 0)) return null;
    var ratio = width / height;
    return ratio >= WIDE_RATIO ? 'width=' + Math.round(PAGE_HEIGHT * ratio) : null;
  }

  // Yüzey 16:9'dan genişse (ultra geniş ekran, sabit 1920 görünümde 1920x804 ölçülür) sayfa 1080 yükseklikte ekran
  // genişliğinde düzenlenir (3440x1440 için 2580); app.js yerleşimi innerWidth/innerHeight'tan hesaplar. 16:9'da 1920.
  function fitWideScreen() {
    try {
      var content = viewportFor(window.innerWidth, window.innerHeight) || 'width=' + NARROW_WIDTH;
      var meta = document.querySelector('meta[name="viewport"]');
      if (meta && meta.getAttribute && meta.getAttribute('content') === content) return;
      if (meta) meta.setAttribute('content', content);
    } catch (e) {}
  }

  // --- Geniş yüzeyde HDMI penceresi (#304) ---
  // Samsung TVWindow belgesi: show() dikdörtgeni görüntü alanının sınırları içinde olmalıdır, dışına taşan dikdörtgen
  // NotSupportedError ile reddedilir; başarı geri çağrısı da yalnız istenen dikdörtgeni aynen geri verir (gerçek ölçüyü
  // söylemez). Dikdörtgen tek koordinat sisteminde, Samsung'un '100%' penceresi için bildirdiği alanın (getRect, 'px')
  // ya da o yoksa sayfanın içinde istenir; hiçbir zaman eksi köken ya da alandan büyük ölçü istenmez.
  // PS5 16:9 verir: varsayılan 'fit' alan yüksekliğinde 16:9 (yanlarda siyah), 'fill' alanın tamamı ('100%').
  // Her denemenin sonucu ve bildirilen ölçüler bilgi panelindeki "Pencere" satırına yazılır (pictureDiagnostics).
  var PICTURE_KEY = 'couchsubs.picture';
  var shownPort = null;
  var pictureLog = '';
  var pictureListener = null;
  // Kabul edilen özel pencere (Samsung koordinatında [x, y, w, h]); yoksa null ('100%' penceresi).
  var acceptedRect = null;
  // PS5 menüden oyuna geçince HDMI sinyali değişir (çözünürlük, kare hızı, HDR) ve Samsung pencereyi kendiliğinden
  // '100%'e döndürür (#304). Sinyal değişince pencere kısa gecikmeyle yeniden istenir; ayrıca açık özel pencere birkaç
  // saniyede bir getRect ile sınanır, başka ölçüye dönmüşse yeniden istenir.
  var REWINDOW_DELAYS = [700, 2500];
  var WATCH_INTERVAL = 5000;
  var rewindowTimers = [];
  var watchTimer = null;
  // getRect kabul edilen pencereyi geri vermiyorsa (TV gerçek ölçüyü söylemiyor) sınama yapılmaz: yoksa pencere boşuna
  // birkaç saniyede bir yeniden çizilirdi.
  var rectTrusted = true;
  // Son çözünürlük bildirimi; aynısı yeniden gelirse pencere yenilenmez.
  var lastResolution = null;
  // Ekranın fiziksel ölçüsündeki istek bir kez reddedildiyse bu TV sayfa koordinatı kullanıyor; yeniden denenmez.
  var physicalRejected = false;

  function pictureMode() {
    try { return window.localStorage.getItem(PICTURE_KEY) === 'fill' ? 'fill' : 'fit'; } catch (e) { return 'fit'; }
  }

  function parseRect(rect) {
    if (!rect || rect.length !== 4) return null;
    var out = [];
    for (var i = 0; i < 4; i++) {
      var text = String(rect[i]);
      if (text.indexOf('%') >= 0) return null;
      var value = parseFloat(text);
      if (isNaN(value)) return null;
      out.push(value);
    }
    return out[0] >= 0 && out[1] >= 0 && out[2] > 0 && out[3] > 0 ? out : null;
  }

  // area: '100%' penceresinin kapladığı alan [x, y, w, h] (Samsung'un koordinatında). Dönen dikdörtgen hep bu alanın
  // içindedir. 16:9 (ve dar) alanda, 'fill' seçiminde ya da 16:9 kutu alanla aynıysa null: '100%' penceresi kalır.
  function pictureRect(area, mode) {
    if (!area || !(area[2] > 0) || !(area[3] > 0)) return null;
    if (area[2] / area[3] < WIDE_RATIO || mode === 'fill') return null;
    var height = Math.floor(area[3]);
    var width = Math.min(Math.floor(area[2]), Math.round(height * 16 / 9));
    if (area[2] - width < 2) return null;
    var x = Math.max(0, Math.round(area[0] + (area[2] - width) / 2));
    var y = Math.max(0, Math.round(area[1]));
    return [x + 'px', y + 'px', width + 'px', height + 'px'];
  }

  function rectText(rect) {
    if (!rect) return '-';
    var out = [];
    for (var i = 0; i < rect.length; i++) out.push(String(rect[i]).replace('px', ''));
    return out.join(',');
  }

  function errorText(e) {
    return e ? String(e.name || e.code || e.message || e).slice(0, 40) : 'error';
  }

  function notePicture(text) {
    pictureLog = text;
    if (pictureListener) {
      try { pictureListener(text); } catch (e) {}
    }
  }

  // Uygulama yüzeyinin koordinat uzayı: ekran sayfadan belirgin büyük değilse standart (sayfa pikseli = TVWindow pikseli,
  // TV panele büyütür), büyükse yüzey panel pikselinde ('native').
  function spaceText() {
    var page = [window.innerWidth, window.innerHeight];
    var scr = screenSize();
    if (scr && scr[0] > page[0] * 1.05 && scr[1] > page[1] * 1.05) {
      return ' · space native ' + sizeText(scr) + ' page ' + sizeText(page);
    }
    return ' · space std ' + sizeText(page);
  }

  // TV'nin bildirdiği ölçüler: hangi koordinat sisteminin geçerli olduğunu bir sonraki fotoğraftan okumak için.
  function reportedSizes() {
    var parts = [];
    try {
      if (window.screen) parts.push('scr ' + window.screen.width + 'x' + window.screen.height);
    } catch (e) {}
    try { if (window.devicePixelRatio) parts.push('dpr ' + window.devicePixelRatio); } catch (e) {}
    try { parts.push('page ' + window.innerWidth + 'x' + window.innerHeight); } catch (e) {}
    try {
      if (window.visualViewport && window.visualViewport.scale) parts.push('vv ' + window.visualViewport.scale);
    } catch (e) {}
    return parts.join(' ') + panelNote + spaceText();
  }

  // Samsung'un o an gösterdiği pencerenin piksel ölçüsü (getRect). API yoksa ya da hata verirse callback(null).
  function readRect(callback) {
    var called = false;
    var once = function (value) { if (!called) { called = true; callback(value); } };
    try {
      if (!tizen.tvwindow.getRect) return once(null);
      var result = tizen.tvwindow.getRect(function (rect) { once(rect); }, function () { once(null); }, 'px', 'MAIN');
      // Eski sürümler sonucu doğrudan döndürür.
      if (result && result.length === 4) once(result);
    } catch (e) {
      once(null);
    }
  }

  function later(callback, ms) {
    try { return setTimeout(callback, ms); } catch (e) { return null; }
  }

  function cancel(timer) {
    try { if (timer !== null) clearTimeout(timer); } catch (e) {}
  }

  function isWide() {
    return viewportFor(window.innerWidth, window.innerHeight) !== null;
  }

  function sameRect(a, b) {
    if (!a || !b) return false;
    for (var i = 0; i < 4; i++) if (Math.abs(a[i] - b[i]) > 2) return false;
    return true;
  }

  // '100%'ten başka bir pencere gerekiyor mu: geniş yüzey, kabul edilmiş özel pencere ya da Sarı ile seçilmiş tam
  // genişlik yöntemi. Tizen 2.3'te pencere hep sabit üst alandadır (aşağıda), yeniden istenmez.
  function customWindow() {
    if (FRONT_ONLY) return false;
    return isWide() || acceptedRect !== null || method() !== 'full';
  }

  // --- Tizen 2.3: HDMI penceresi hep sayfanın önünde (2015 Samsung TV'ler, #761) ---
  // TVWindow show()'un zPosition değişkeni (BEHIND) Tizen 2.4'te geldi; 2.3'te pencere her zaman sayfanın ÖNÜNDE çizilir
  // (Samsung TVWindow belgesi: "FRONT ... behaves in the same way as it did before Tizen 2.4"). '100%' pencere bu yüzden
  // HDMI girişi açılır açılmaz (2-3 sn) sayfanın tamamını örtüyordu: uygulama "kayboluyor", çeviri TV'de görünmüyordu.
  // 2.3'te pencere ekranın üst %75'ine 16:9 olarak açılır (ortada), çeviri alttaki boş şeritte gösterilir
  // (subtitleBand; app.js altyazıyı bu şeride sabitler). Bekleme ekranı, panel, eşleştirme kodu, ipuçları ya da demo
  // görünürken pencere gizlenir (tvwindow.hide), kapanınca yeniden açılır: yoksa pencere onları da örterdi.
  var FRONT_RECT = ['12.5%', '0%', '75%', '75%'];
  var FRONT_BAND = 25;
  var FRONT_COVERS = ['waiting', 'panel', 'no-picture', 'pairing', 'source-tip', 'panel-tip', 'demo-badge'];
  var FRONT_POLL = 500;

  // Önce Tizen'in kendi bildirdiği sürüm, okunamazsa tarayıcı kimliğindeki "Tizen 2.3".
  function tizenVersion() {
    var version = '';
    try {
      version = String(tizen.systeminfo.getCapability('http://tizen.org/feature/platform.version') || '');
    } catch (e) {}
    if (version) return version;
    try {
      var match = /Tizen\s+(\d+\.\d+)/.exec(navigator.userAgent || '');
      return match ? match[1] : '';
    } catch (e) {
      return '';
    }
  }

  // '2.3', '2.3.1' → true; '2.4', '3.0', okunamayan → false (bugünkü davranış).
  function versionBelow(text, major, minor) {
    var match = /^(\d+)\.(\d+)/.exec(String(text || ''));
    if (!match) return false;
    var a = Number(match[1]);
    var b = Number(match[2]);
    return a < major || (a === major && b < minor);
  }

  var TIZEN_VERSION = tizenVersion();
  var FRONT_ONLY = versionBelow(TIZEN_VERSION, 2, 4);
  var frontWanted = false;
  var frontShown = false;
  var frontTimer = null;

  // Pencerenin örteceği bir kutu (bekleme ekranı, panel, ipucu ...) görünüyor mu?
  function pageCovered() {
    try {
      for (var i = 0; i < FRONT_COVERS.length; i++) {
        var el = document.getElementById(FRONT_COVERS[i]);
        if (el && !/(^|\s)hidden(\s|$)/.test(el.className || '')) return true;
      }
    } catch (e) {}
    return false;
  }

  function frontShow(done, failed) {
    try {
      tizen.tvwindow.show(function () {
        frontShown = true;
        notePicture(reportedSizes() + ' · tizen ' + TIZEN_VERSION + ' front ' + rectText(FRONT_RECT) + ' ok');
        if (done) done();
      }, function (e) {
        notePicture(reportedSizes() + ' · tizen ' + TIZEN_VERSION + ' front fail ' + errorText(e));
        if (failed) failed(e);
      }, FRONT_RECT, 'MAIN');
    } catch (e) {
      notePicture(reportedSizes() + ' · tizen ' + TIZEN_VERSION + ' front fail ' + errorText(e));
      if (failed) failed(e);
    }
  }

  function frontHide() {
    frontShown = false;
    try {
      tizen.tvwindow.hide(function () {}, function () {}, 'MAIN');
    } catch (e) {}
    notePicture(pictureLog.replace(/ · hidden$/, '') + ' · hidden');
  }

  // Kutular açılıp kapandıkça pencere gizlenir ya da yeniden açılır.
  function syncFront() {
    if (!frontWanted) return;
    var covered = pageCovered();
    if (covered && frontShown) frontHide();
    else if (!covered && !frontShown) frontShow(null, null);
  }

  function watchFront() {
    if (frontTimer !== null) return;
    try {
      frontTimer = setInterval(syncFront, FRONT_POLL);
    } catch (e) {
      frontTimer = false;
    }
  }

  // --- Panelin gerçek ölçüsü (#304, tanı ve tam genişlik yöntemi için) ---
  // Ultra geniş Samsung monitör (0.9.53): 'scr 1920x1080 dpr 1 page 1920x1080 vv 1 · panel 1920x1080 1.78 scr (dsp
  // 1920x1080 154x87mm cap 1920x1080)'. Her kaynak 1920x1080 diyebiliyor; panel bu yüzden birkaç kaynaktan okunur, en
  // büyüğü alınır:
  //   dsp: Tizen SystemInfo DISPLAY resolutionWidth/Height (piksel) ve physicalWidth/Height (milimetre)
  //   cap: tizen.systeminfo.getCapability screen.width/screen.height
  //   model: webapis.productinfo getRealModel/getModel; Samsung monitörlerinde boy model adında (LS34…: 21:9 3440x1440,
  //          LS49…: 32:9 5120x1440, LS57…: 32:9 7680x2160)
  // Piksel ölçüsü 1920x1080 kalıp yalnız milimetre oranı genişse panel 1440 yükseklikte varsayılır ('~' ile yazılır).
  // Panel okunamasa da Sarı tuş Samsung'da her zaman çalışır (aşağıda: yöntemler).
  var panel = null;
  var panelNote = '';
  var panelReading = null;
  var PANEL_WAIT = 1000;
  var MONITOR_PANELS = { '34': [3440, 1440], '49': [5120, 1440], '57': [7680, 2160] };

  function modelPanel(name) {
    var match = /(?:^|[^0-9A-Z])L?[SC](34|49|57)[A-Z]/i.exec(String(name || ''));
    return match ? MONITOR_PANELS[match[1]] : null;
  }

  function productModel() {
    try {
      var info = webapis.productinfo;
      var real = typeof info.getRealModel === 'function' ? info.getRealModel() : '';
      return real || (typeof info.getModel === 'function' ? info.getModel() : '') || '';
    } catch (e) {
      return '';
    }
  }

  function capabilitySize() {
    try {
      var w = Number(tizen.systeminfo.getCapability('http://tizen.org/feature/screen.width'));
      var h = Number(tizen.systeminfo.getCapability('http://tizen.org/feature/screen.height'));
      return w > 0 && h > 0 ? [w, h] : null;
    } catch (e) {
      return null;
    }
  }

  function screenSize() {
    try {
      var w = window.screen && window.screen.width;
      var h = window.screen && window.screen.height;
      return w > 0 && h > 0 ? [w, h] : null;
    } catch (e) {
      return null;
    }
  }

  function sizeText(size) {
    return size ? size[0] + 'x' + size[1] : '-';
  }

  // display: DISPLAY özelliği (yoksa null). Sonuç {w, h, ratio, from} ya da null; panelNote tanı satırına yazılır.
  function computePanel(display) {
    var dsp = display && display.resolutionWidth > 0 && display.resolutionHeight > 0 ?
      [Number(display.resolutionWidth), Number(display.resolutionHeight)] : null;
    var mm = display && display.physicalWidth > 0 && display.physicalHeight > 0 ?
      [Math.round(display.physicalWidth), Math.round(display.physicalHeight)] : null;
    var cap = capabilitySize();
    var model = productModel();
    var candidates = [['scr', screenSize()], ['dsp', dsp], ['cap', cap], ['model', modelPanel(model)]];
    var best = null;
    var from = '';
    for (var i = 0; i < candidates.length; i++) {
      var size = candidates[i][1];
      if (size && (!best || size[0] * size[1] > best[0] * best[1] * 1.05)) {
        best = size;
        from = candidates[i][0];
      }
    }
    if (mm && best && mm[0] / mm[1] >= WIDE_RATIO && best[0] / best[1] < WIDE_RATIO) {
      // Piksel ölçüsü 16:9 bildiriliyor ama panel geniş: yükseklik 1440 varsayılır.
      var height = Math.max(best[1], 1440);
      best = [Math.round(height * mm[0] / mm[1]), height];
      from = '~mm';
    }
    panelNote = ' · panel ' + (best ? sizeText(best) + ' ' + (best[0] / best[1]).toFixed(2) + ' ' + from : '-') +
      ' (dsp ' + sizeText(dsp) + (mm ? ' ' + mm[0] + 'x' + mm[1] + 'mm' : '') + ' cap ' + sizeText(cap) +
      (model ? ' ' + String(model).slice(0, 20) : '') + ')' + udText();
    return best ? { w: best[0], h: best[1], ratio: best[0] / best[1], from: from } : null;
  }

  // DISPLAY bir kez okunur (zaman aşımında onsuz); callback panel bilindikten sonra çağrılır.
  function readPanel(callback) {
    if (panel !== null) return callback(panel);
    if (panelReading) return panelReading.push(callback);
    panelReading = [callback];
    var settled = false;
    var settle = function (display) {
      if (settled) return;
      settled = true;
      panel = computePanel(display) || false;
      var waiting = panelReading;
      panelReading = null;
      for (var i = 0; i < waiting.length; i++) {
        try { waiting[i](panel); } catch (e) {}
      }
    };
    try {
      tizen.systeminfo.getPropertyValue('DISPLAY', function (info) { settle(info); }, function () { settle(null); });
    } catch (e) {
      settle(null);
    }
    if (!settled) later(function () { settle(null); }, PANEL_WAIT);
  }

  // Webapis ürün bilgisi: panel 4K/8K mı (tanı satırı için; API yoksa boş).
  function udText() {
    try {
      var info = webapis.productinfo;
      if (typeof info.is8KPanelSupported === 'function' && info.is8KPanelSupported()) return ' 8k';
      if (typeof info.isUdPanelSupported === 'function' && info.isUdPanelSupported()) return ' 4k';
    } catch (e) {}
    return '';
  }

  // --- Görüntü yöntemleri (16:9 yüzey; Sarı tuş, #304) ---
  // Samsung'da Sarı her zaman çalışır ve şu yöntemler arasında döner (seçim saklanır, panelde "Görüntü yöntemi n/3"):
  //   full:   '100%' penceresi; varsayılan ve belgedeki yol (4K/8K/1080p TV'de görüntü paneli doldurur)
  //   wide21: 21:9 tam genişlik (ultra geniş monitör uygulamaya 16:9 yüzey verdiğinde)
  //   wide32: 32:9 tam genişlik
  // Tam genişlik yöntemi önce pencereyi alan yüksekliğinde ve oranın genişliğinde ister (21:9: 2560x1080; panel okunduysa
  // onun oranı, 3440x1440 için 2580x1080). Samsung alanın dışını reddederse (belge: NotSupportedError) sayfa kısa süre o
  // genişlikte açılır, '100%' o ölçüde istenir ve görünüm 1920'ye döner. Samsung belgesine göre geniş uygulama yüzeyi
  // yalnız 23TV_PREMIUM2 grubunda var; monitör yüzeyi 16:9 tutuyorsa iki deneme de reddedilir ya da '100%' kalır, sonuç
  // Pencere satırında.
  var METHOD_KEY = 'couchsubs.samsungPicture';
  var METHODS = ['full', 'wide21', 'wide32'];
  // Görünüm değişikliğinden sonra innerWidth'in yenilenmesi için beklenen süre (ms).
  var VIEWPORT_DELAY = 300;
  // Son başlatılan tam genişlik denemesi: görünüm beklemesi sürerken yenisi başlarsa (sinyal, Sarı) eskisi bırakılır.
  var wideRun = 0;

  function method() {
    try {
      var stored = window.localStorage.getItem(METHOD_KEY);
      return METHODS.indexOf(stored) >= 0 ? stored : 'full';
    } catch (e) {
      return 'full';
    }
  }

  // Tam genişlik yönteminin en-boy oranı: panel okunduysa ve yönteme uyuyorsa onunki, yoksa 21:9 (64:27) ya da 32:9.
  function methodRatio(name) {
    var ratio = panel ? panel.ratio : 0;
    if (name === 'wide21') return ratio >= WIDE_RATIO && ratio < 2.9 ? ratio : 64 / 27;
    return ratio >= 2.9 ? ratio : 32 / 9;
  }

  function setViewport(content) {
    try {
      var meta = document.querySelector('meta[name="viewport"]');
      if (meta) meta.setAttribute('content', content);
    } catch (e) {}
  }

  function showFull(ok, fail) {
    try {
      tizen.tvwindow.show(ok, fail, FULL_SCREEN, 'MAIN', 'BEHIND');
    } catch (e) {
      fail(e);
    }
  }

  // line: tanı satırının başı; area: '100%' penceresinin alanı.
  function showWide(line, name, area, done) {
    var run = ++wideRun;
    var width = Math.round(area[3] * methodRatio(name));
    var rect = [Math.round(area[0]) + 'px', Math.round(area[1]) + 'px', width + 'px', Math.floor(area[3]) + 'px'];
    var tried = [];
    acceptedRect = null;
    var finish = function () {
      readRect(function (now) {
        var reported = parseRect(now);
        if (acceptedRect && reported) rectTrusted = sameRect(reported, acceptedRect);
        notePicture(line + ' ' + tried.join(' ') + (now ? ' · now ' + rectText(now) : '') + ' · vw ' + window.innerWidth);
        done();
      });
    };
    var byViewport = function () {
      setViewport('width=' + width);
      later(function () {
        if (run !== wideRun) return done();
        var seen = window.innerWidth;
        if (!(seen > NARROW_WIDTH * 1.05)) {
          // Görünüm genişlemedi: '100%' zaten açık.
          tried.push('vw ' + seen + ' kept');
          fitWideScreen();
          return finish();
        }
        showFull(function () {
          tried.push('vw ' + seen + ' ok');
          fitWideScreen();
          finish();
        }, function (e) {
          tried.push('vw ' + seen + ' fail ' + errorText(e));
          fitWideScreen();
          showFull(finish, finish);
        });
      }, VIEWPORT_DELAY);
    };
    try {
      tizen.tvwindow.show(function () {
        acceptedRect = parseRect(rect);
        tried.push(rectText(rect) + ' ok');
        finish();
      }, function (e) {
        tried.push(rectText(rect) + ' fail ' + errorText(e));
        byViewport();
      }, rect, 'MAIN', 'BEHIND');
    } catch (e) {
      tried.push(rectText(rect) + ' fail ' + errorText(e));
      byViewport();
    }
  }

  // TV olay günlüğü (app.js tvLog, 0.9.116; yoksa sessiz): görüntüyü yeniden çizdiren her şey nedeniyle yazılır.
  function tvLog(text) {
    try { if (typeof window.COUCHSUBS_TVLOG === 'function') window.COUCHSUBS_TVLOG(text); } catch (e) {}
  }

  // HDMI açıkken pencere yeniden istenir (sinyal değişti ya da Samsung ölçüyü bozdu).
  function rewindow(why) {
    if (shownPort === null || !customWindow()) return;
    tvLog('hdmi rewindow (' + why + ')');
    try {
      showWindow(function () {}, function () {}, why);
    } catch (e) {}
  }

  function scheduleRewindow(why) {
    if (shownPort === null || !customWindow()) return;
    for (var i = 0; i < rewindowTimers.length; i++) cancel(rewindowTimers[i]);
    rewindowTimers = [];
    for (var j = 0; j < REWINDOW_DELAYS.length; j++) {
      rewindowTimers.push(later(function () { rewindow(why); }, REWINDOW_DELAYS[j]));
    }
  }

  // Kabul edilen özel pencere hâlâ duruyor mu? Samsung '100%'e döndürdüyse yeniden istenir. Her yeniden istek HDMI
  // görüntüsünü yeniden çizdirir (bazı TV'lerde parlaklık bir an oynar): dakikada RESET_LIMIT kezden fazla bozuluyorsa
  // sınama bırakılır, sinyal değişince ya da giriş yeniden açılınca yeniden başlar.
  var RESET_LIMIT = 3;
  var resetTimes = [];
  var watchOff = false;

  function checkWindow() {
    if (shownPort === null || !acceptedRect || !rectTrusted || watchOff) return;
    readRect(function (now) {
      var rect = parseRect(now);
      if (!rect || !acceptedRect || sameRect(rect, acceptedRect)) return;
      var time = new Date().getTime();
      while (resetTimes.length && time - resetTimes[0] >= 60000) resetTimes.shift();
      if (resetTimes.length >= RESET_LIMIT) {
        watchOff = true;
        notePicture(pictureLog + ' · watch off');
        return;
      }
      resetTimes.push(time);
      rewindow('reset ' + rectText(now));
    });
  }

  function watchWindow() {
    if (watchTimer !== null) return;
    try {
      watchTimer = setInterval(checkWindow, WATCH_INTERVAL);
    } catch (e) {
      watchTimer = false;
    }
  }

  // Sinyal değişince (PS5 menü → oyun) gelen çözünürlük bildirimi: app.js'nin gösterdiği değer ve pencerenin yenilenmesi.
  function onResolution(info) {
    if (resolutionCallback) {
      try { resolutionCallback(info || null); } catch (e) {}
    }
    var key = resolutionKey(info);
    if (key === lastResolution) return;
    lastResolution = key;
    resetTimes = [];
    watchOff = false;
    scheduleRewindow('signal ' + key);
  }

  function resolutionKey(info) {
    return info ? [info.width, info.height, info.frequency, info.type].join('/') : '-';
  }

  function listenResolution() {
    if (resolutionListener !== null) return;
    try {
      resolutionListener = tizen.tvwindow.addVideoResolutionChangeListener(onResolution, 'MAIN');
    } catch (e) {
      resolutionListener = false;
    }
  }

  // Ekranın fiziksel ölçüsü '100%' penceresinin alanından belirgin büyükse (yüzey panel pikselinde, 'space native') o
  // ölçü; değilse null. Böyle yüzeyde '100%' penceresi sayfanın CSS ölçüsünde çizilebilir: önce fiziksel ölçü istenir.
  function screenArea(area) {
    var size = screenSize();
    return size && size[0] > area[2] * 1.05 && size[1] > area[3] * 1.05 ? [0, 0, size[0], size[1]] : null;
  }

  function wholeRect(area) {
    return [Math.round(area[0]) + 'px', Math.round(area[1]) + 'px', Math.floor(area[2]) + 'px', Math.floor(area[3]) + 'px'];
  }

  // Pencereyi '100%' açar. Geniş yüzeyde seçime göre 16:9 kutuya küçültür; 16:9 yüzeyde Sarı ile seçilen tam genişlik
  // yöntemini dener. Ekran '100%' alanından büyükse önce ekranın fiziksel ölçüsünde istenir (Samsung sınır dışını
  // reddeder; reddederse alan ölçüsüne düşülür). Hepsi reddedilirse '100%' kalır.
  // why: yeniden istemenin nedeni (tanı satırının başına yazılır; ilk açılışta yok).
  function showWindow(done, failed, why) {
    if (FRONT_ONLY) {
      frontWanted = true;
      watchFront();
      return frontShow(function () {
        syncFront();
        done();
      }, failed);
    }
    var wide = isWide();
    var mode = wide ? pictureMode() : method();
    var prefix = why ? why + ' → ' : '';
    wideRun++;
    tizen.tvwindow.show(function () {
      readRect(function (full) {
        var area = parseRect(full) || [0, 0, window.innerWidth, window.innerHeight];
        var line = prefix + reportedSizes() + ' · 100% ok · area ' + (parseRect(full) ? '' : 'page ') + rectText(area) + ' · ' + mode;
        if (!wide && mode !== 'full') return showWide(line, mode, area, done);
        var targets = [];
        var physical = physicalRejected ? null : screenArea(area);
        if (physical) targets.push(pictureRect(physical, mode) || wholeRect(physical));
        var boxed = wide ? pictureRect(area, mode) : null;
        if (boxed) targets.push(boxed);
        if (!targets.length) {
          acceptedRect = null;
          notePicture(line);
          return done();
        }
        var tried = [];
        var finish = function (target, result) {
          acceptedRect = result === 'ok' ? parseRect(target) : null;
          readRect(function (now) {
            var reported = parseRect(now);
            if (result === 'ok' && reported) rectTrusted = sameRect(reported, parseRect(target));
            notePicture(line + ' ' + tried.join(' ') + (now ? ' · now ' + rectText(now) : ''));
            done();
          });
        };
        var attempt = function (index, lastError) {
          if (index >= targets.length) {
            // Yalnız fiziksel ölçü reddedildiyse pencere zaten '100%'.
            if (physical && targets.length === 1) return finish(null, 'fail ' + errorText(lastError));
            // Reddedilen kutudan sonra pencere '100%' kalsın (Samsung son başarılı ölçüyü korur; yine de yeniden iste).
            var fail = 'fail ' + errorText(lastError);
            showFull(function () { finish(null, fail); }, function () { finish(null, fail); });
            return;
          }
          var target = targets[index];
          var rejected = function (e) {
            if (physical && index === 0) physicalRejected = true;
            tried.push(rectText(target) + ' fail ' + errorText(e));
            attempt(index + 1, e);
          };
          try {
            tizen.tvwindow.show(function () {
              tried.push(rectText(target) + ' ok');
              finish(target, 'ok');
            }, rejected, target, 'MAIN', 'BEHIND');
          } catch (e) {
            rejected(e);
          }
        };
        attempt(0, null);
      });
    }, function (e) {
      notePicture(prefix + reportedSizes() + ' · 100% fail ' + errorText(e));
      failed(e);
    }, FULL_SCREEN, 'MAIN', 'BEHIND');
  }

  // Samsung ağ API'sindeki IPv4 adresi (izin: network.public); API yoksa ya da adres boşsa null.
  function samsungIp() {
    try {
      var ip = webapis.network.getIp();
      return /^\d+\.\d+\.\d+\.\d+$/.test(ip || '') && ip !== '0.0.0.0' ? ip : null;
    } catch (e) {
      return null;
    }
  }

  function hdmiSources(callback) {
    try {
      tizen.systeminfo.getPropertyValue('VIDEOSOURCE', function (info) {
        var isHdmi = function (source) { return source.type === 'HDMI'; };
        callback((info.connected || []).filter(isHdmi), (info.disconnected || []).filter(isHdmi));
      }, function () { callback([], []); });
    } catch (e) {
      callback([], []);
    }
  }

  // CouchSubs uygulaması TV uygulamasını açarken parametreleri PAYLOAD içinde verir.
  function paramsOf(appControl) {
    var data = (appControl && appControl.data) || [];
    for (var i = 0; i < data.length; i++) {
      if (data[i].key !== 'PAYLOAD' || !data[i].value || !data[i].value.length) continue;
      try {
        var payload = JSON.parse(data[i].value[0]);
        return payload && payload.values !== undefined ? payload.values : payload;
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  function requestedParams() {
    try {
      return paramsOf(tizen.application.getCurrentApplication().getRequestedAppControl().appControl);
    } catch (e) {
      return null;
    }
  }

  // app.js yerleşimi ölçmeden önce; platform.js ondan önce yüklenir.
  fitWideScreen();
  // Panel ölçüsü erkenden okunur: tam genişlik yönteminin oranı ve tanı satırı için.
  readPanel(function () {});

  window.COUCHSUBS_PLATFORM = {
    backKey: 10009,

    // Birim testi için (scripts/tv-tizen.test.js).
    viewportFor: viewportFor,
    samsungIp: samsungIp,
    modelPanel: modelPanel,
    pictureRect: pictureRect,

    // HDMI penceresi denemelerinin sonucu ve TV'nin bildirdiği ölçüler (#304); app.js bilgi panelinde gösterir.
    pictureDiagnostics: function (callback) {
      pictureListener = callback;
      if (pictureLog) callback(pictureLog);
    },

    // Sarı tuş Samsung'da her zaman vardır (app.js tuş listesinde gösterir). Geniş yüzeyde (21:9, 32:9) HDMI görüntüsü:
    // 'fit' 16:9 tam yükseklik, 'fill' ekranı doldurur (gerer). 16:9 yüzeyde görüntü yöntemi: 'full' | 'wide21' | 'wide32'.
    pictureModes: function () {
      // Tizen 2.3'te pencere sabit üst alanda: Sarı'nın yöntemleri yok.
      if (FRONT_ONLY) return null;
      return isWide() ? pictureMode() : method();
    },
    // Sarı'nın sırayla geçtiği görüntü yöntemleri; app.js "Görüntü yöntemi 2/3" yazar. Geniş yüzeyde null (sığdır/doldur).
    pictureModeList: function () {
      return isWide() ? null : METHODS.slice();
    },
    togglePicture: function (onStatus) {
      var next;
      if (!isWide()) {
        next = METHODS[(METHODS.indexOf(method()) + 1) % METHODS.length];
        try { window.localStorage.setItem(METHOD_KEY, next); } catch (e) {}
      } else {
        next = pictureMode() === 'fill' ? 'fit' : 'fill';
        try { window.localStorage.setItem(PICTURE_KEY, next); } catch (e) {}
      }
      if (shownPort !== null) {
        var failed = function () { if (onStatus) onStatus('inputError'); };
        try {
          showWindow(function () { if (onStatus) onStatus('playing'); }, failed);
        } catch (e) {
          failed();
        }
      }
      return next;
    },

    // Anynet+ (HDMI-CEC) ya da Otomatik Kaynak Değiştirme TV'yi kendiliğinden HDMI'ya geçirirse uygulama ipucu
    // gösterir (app.js). Menü adları Samsung'unkiler; başka TV'lerde gösterilmez.
    sourceSwitchTip: true,
    // HDMI girişi açılamazsa app.js nedenini ve giriş seçimini gösterir.
    noPictureHelp: true,
    // Arka plana düşen uygulama bağlantıyı kapatır: Samsung önplandaki uygulamayı söylemediği için bilgisayar
    // uygulamayı ancak bağlantı yoksa yeniden açar (TvKeeper).
    closeWhenHidden: true,
    // Tizen 2.3: HDMI penceresi sayfanın önünde ve ekranın üst kısmında; çeviri alttaki bu yükseklikte (yüzde) şeritte
    // kalmalı (app.js). Tizen 2.4 ve sonrasında 0: pencere sayfanın arkasında, çeviri her yerde görünür.
    subtitleBand: FRONT_ONLY ? FRONT_BAND : 0,
    // Birim testi için.
    tizenVersion: TIZEN_VERSION,

    init: function () {
      // Renk ve sayı tuşları istenmezse TV kendisi kullanır.
      for (var i = 0; i < KEYS.length; i++) {
        try { tizen.tvinputdevice.registerKey(KEYS[i]); } catch (e) {}
      }
      // Oyun TV kumandasına dokunmadan oynanır; TV boşta sanıp ekran koruyucuyu açmasın (Samsung AppCommon API).
      // Eski TV'lerde API yoksa sessizce geçilir.
      try {
        webapis.appcommon.setScreenSaver(webapis.appcommon.AppCommonScreenSaverState.SCREEN_SAVER_OFF);
      } catch (e) {}
    },

    launchParams: requestedParams,

    // Çalışan uygulama yeniden açıldı (appcontrol). Geliştirici bağlantısıyla açmada (sdb was_execute) parametre gelmez;
    // eskiden yalnız parametreli açılış bildiriliyordu ve "resumed" ile öne getirilen sayfa kopan akışı yeniden kurmuyordu
    // (#1248). Artık her yeniden açılış bildirilir (parametre yoksa null).
    onRelaunch: function (callback) {
      window.addEventListener('appcontrol', function () {
        tvLog('relaunch (appcontrol)');
        callback(requestedParams());
      });
    },
    // Bilgisayar/telefon Samsung'da uygulamayı yalnız TV'yi bağlı görmediğinde açar: yeniden açılışta bağlantı açık görünse
    // de yeniden kurulur (app.js).
    reconnectOnRelaunch: true,

    // onStatus: 'loading' | 'ready' | 'playing' | 'inputError' | 'sourceError'
    showHdmi: function (port, host, onStatus) {
      onStatus('loading');
      hdmiSources(function (connected, disconnected) {
        var all = connected.concat(disconnected);
        var source = all.filter(function (s) { return s.number === port; })[0];
        if (!source) return onStatus('sourceError');
        var failed = function () { onStatus('inputError'); };
        // Pencere yöntemi panelin gerçek ölçüsüne göre seçilir; okunmadıysa önce okunur.
        readPanel(function () {
          try {
            tvLog('hdmi open ' + port + (shownPort === null ? ' (start)' : shownPort === port ? ' (same input reselected)' : ' (input changed)'));
            tizen.tvwindow.setSource(source, function () {
              shownPort = port;
              resetTimes = [];
              watchOff = false;
              showWindow(function () { onStatus('playing'); }, failed);
              listenResolution();
              watchWindow();
            }, failed);
          } catch (e) {
            failed();
          }
        });
      });
    },

    // TV'nin ağ adresi; bilgisayarı aramak için.
    localAddress: function (callback) {
      function read(property, otherwise) {
        try {
          tizen.systeminfo.getPropertyValue(property, function (info) {
            // subnetMask: app.js /24'ten büyük ağları da tarar (en çok /22).
            if (info && info.ipAddress) callback(info.ipAddress, info.subnetMask || null); else otherwise();
          }, otherwise);
        } catch (e) {
          otherwise();
        }
      }
      // Tizen'in sistem bilgisi adres vermezse Samsung'un ağ API'si (webapis.network.getIp) sorulur; o da yoksa null.
      // Adres bilinmeyince app.js yaygın ev ağlarını tarar (#484).
      read('ETHERNET_NETWORK', function () {
        read('WIFI_NETWORK', function () { callback(samsungIp()); });
      });
    },

    // Tek bağlı HDMI varsa odur; birden çoksa TV'nin o anki girişi tercih edilir. Tizen girişteki cihazın adını
    // vermez, bu yüzden birden çok bağlı girişte seçim tahmindir: üçüncü değer bağlı HDMI sayısıdır, app.js bu
    // durumda kullanıcıya girişi sorar. Bilgisayar da TV'ye HDMI ile bağlıyken TV'nin o anki girişi bilgisayarınki
    // oluyordu; TV uygulaması Xbox yerine bilgisayarın ekranını gösteriyor, altyazı oyunun üstüne çıkmıyordu (#360).
    findConsolePort: function (callback) {
      hdmiSources(function (connected) {
        var pick = connected.length === 1 ? connected[0] : null;
        if (!pick && connected.length > 1) {
          try {
            var current = tizen.tvwindow.getSource();
            pick = connected.filter(function (s) { return s.number === current.number && current.type === 'HDMI'; })[0] || null;
          } catch (e) {}
        }
        callback(pick ? pick.number : null, pick ? 'HDMI ' + pick.number : null, connected.length);
      });
    },

    // HDMI görüntüsünün çözünürlüğü ve yenileme hızı (TVWindow API: getVideoResolution). İlk değer hemen, sonrakiler
    // değiştikçe callback'e gelir; dinleyici bir kez kurulur. API yoksa ya da hata verirse callback(null): gösterilmez.
    videoResolution: function (callback) {
      resolutionCallback = callback;
      var report = function (info) {
        // İlk değer pencereyi yenilemez; yalnız sonraki değişiklik yeniler.
        if (lastResolution === null && info) lastResolution = resolutionKey(info);
        if (resolutionCallback) resolutionCallback(info || null);
      };
      var fail = function () { report(null); };
      listenResolution();
      try {
        var result = tizen.tvwindow.getVideoResolution(report, fail, 'MAIN');
        // Eski sürümler sonucu doğrudan döndürür.
        if (result && result.width) report(result);
      } catch (e) {
        fail();
      }
    },

    exit: function () {
      try { tizen.application.getCurrentApplication().exit(); } catch (e) {}
    }
  };
})();
