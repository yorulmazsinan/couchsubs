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

  // Ultrawide ekran (#304): Samsung yüzeyi config.xml'deki base_screen_resolution ile ve ancak sayfa
  // "width=device-width" görünümüyle açılırsa ekranın tamamı yapar (Samsung "21:9 Aspect Ratio Support" belgesi);
  // ortak index.html'in sabit "width=1920"si uygulamayı 16:9 kutuda tutuyordu. Samsung paketinde görünüm bu yüzden
  // device-width'tir (scripts/package-tizen.sh) ve burada asıl değerine getirilir. Geniş yüzeyde genişlik yüksekliği 1080
  // tutacak şekilde verilir (3440x1440 için 2580): yazı ve kutular 16:9 TV'dekiyle aynı boyda, app.js yerleşimi
  // innerWidth/innerHeight'tan hesaplandığı için ekrana yayılır. 16:9 yüzeyde null döner, görünüm eskisi gibi 1920 olur.
  function viewportFor(width, height) {
    if (!(width > 0) || !(height > 0)) return null;
    var ratio = width / height;
    return ratio >= WIDE_RATIO ? 'width=' + Math.round(PAGE_HEIGHT * ratio) : null;
  }

  function fitWideScreen() {
    try {
      var content = viewportFor(window.innerWidth, window.innerHeight) || 'width=' + NARROW_WIDTH;
      var meta = document.querySelector('meta[name="viewport"]');
      if (meta) meta.setAttribute('content', content);
    } catch (e) {}
  }

  // --- Geniş ekranda HDMI penceresi (#304) ---
  // Odyssey G8'de (3440x1440) TVWindow '100%' penceresi ekranın ortasında 2580x1080 piksellik bir kutuya çiziliyordu
  // (kullanıcı fotoğrafları: her iki yönde ekranın %75'i, ortalanmış; 0.9.22'de sayfa 16:9 kutudayken de aynı boy).
  // Samsung pencere ölçüsünü uygulamanın 1080 satırlık mantıksal yüzeyinde (show'un bildirdiği dikdörtgen) alıyor,
  // görüntü katmanında ise bunu fiziksel piksele büyütmeden ekranın ortasına koyuyor. Bu yüzden geniş ekranda pencere
  // fiziksel ölçüde istenir ve aynı merkeze göre konur: kutu ekran boyuna büyür. 16:9 TV'lerde bir şey değişmez.
  // PS5 16:9 verir: varsayılan 'fit' tam yükseklikte 16:9 (yanlarda siyah), 'fill' ekranın tamamı (görüntü gerilir).
  var PICTURE_KEY = 'couchsubs.picture';
  var shownPort = null;

  function pictureMode() {
    try { return window.localStorage.getItem(PICTURE_KEY) === 'fill' ? 'fill' : 'fit'; } catch (e) { return 'fit'; }
  }

  // Ekranın fiziksel ölçüsü: screen (cihaz pikseli) ya da sayfa yüzeyi x görünüm ölçeği.
  function physicalSize() {
    var candidates = [];
    try {
      var dpr = window.devicePixelRatio > 0 ? window.devicePixelRatio : 1;
      if (window.screen) candidates.push([window.screen.width * dpr, window.screen.height * dpr]);
    } catch (e) {}
    try {
      var scale = window.visualViewport && window.visualViewport.scale > 0 ? window.visualViewport.scale : 1;
      candidates.push([window.innerWidth * scale, window.innerHeight * scale]);
    } catch (e) {}
    var best = null;
    for (var i = 0; i < candidates.length; i++) {
      var c = candidates[i];
      if (c[0] > 0 && c[1] > 0 && (!best || c[1] > best[1])) best = c;
    }
    return best ? [Math.round(best[0]), Math.round(best[1])] : null;
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
    return out[2] > 0 && out[3] > 0 ? out : null;
  }

  // shown: show('100%') sonrası pencerenin mantıksal dikdörtgeni [x, y, w, h]; screen: fiziksel [w, h].
  // 16:9 (ve dar) ekranda ya da pencere zaten ekran boyundaysa null: '100%' penceresi kalır.
  function pictureRect(shown, screen, mode) {
    if (!shown || !screen || !(screen[0] > 0) || !(screen[1] > 0)) return null;
    if (screen[0] / screen[1] < WIDE_RATIO) return null;
    var width = mode === 'fill' ? screen[0] : Math.min(screen[0], Math.round(screen[1] * 16 / 9));
    var height = screen[1];
    if (Math.abs(width - shown[2]) < 2 && Math.abs(height - shown[3]) < 2) return null;
    var x = Math.round(shown[0] + (shown[2] - width) / 2);
    var y = Math.round(shown[1] + (shown[3] - height) / 2);
    return [x + 'px', y + 'px', width + 'px', height + 'px'];
  }

  // Pencereyi açar; geniş ekranda ölçüyü düzeltir. Samsung ekran dışına taşan (eksi) kökeni reddederse aynı ölçü
  // sol üst kökenle denenir, o da olmazsa '100%' penceresi (eski davranış) kalır.
  function showWindow(done, failed) {
    tizen.tvwindow.show(function (rect) {
      var target = pictureRect(parseRect(rect) || [0, 0, window.innerWidth, window.innerHeight], physicalSize(),
        pictureMode());
      if (!target) return done();
      var attempts = [target, ['0px', '0px', target[2], target[3]], FULL_SCREEN];
      var next = function (i) {
        try {
          tizen.tvwindow.show(function () { done(); }, function () {
            if (i + 1 < attempts.length) next(i + 1); else done();
          }, attempts[i], 'MAIN', 'BEHIND');
        } catch (e) {
          if (i + 1 < attempts.length) next(i + 1); else done();
        }
      };
      next(0);
    }, failed, FULL_SCREEN, 'MAIN', 'BEHIND');
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

  window.COUCHSUBS_PLATFORM = {
    backKey: 10009,

    // Birim testi için (scripts/tv-tizen.test.js).
    viewportFor: viewportFor,
    samsungIp: samsungIp,
    pictureRect: pictureRect,

    // Geniş ekranda (21:9, 32:9) HDMI görüntüsü: 'fit' 16:9 tam yükseklik, 'fill' ekranı doldurur (gerer). Sarı tuş
    // değiştirir (app.js); 16:9 TV'de yoktur.
    pictureModes: function () {
      return viewportFor(window.innerWidth, window.innerHeight) ? pictureMode() : null;
    },
    togglePicture: function (onStatus) {
      var next = pictureMode() === 'fill' ? 'fit' : 'fill';
      try { window.localStorage.setItem(PICTURE_KEY, next); } catch (e) {}
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

    onRelaunch: function (callback) {
      window.addEventListener('appcontrol', function () {
        var params = requestedParams();
        if (params) callback(params);
      });
    },

    // onStatus: 'loading' | 'ready' | 'playing' | 'inputError' | 'sourceError'
    showHdmi: function (port, host, onStatus) {
      onStatus('loading');
      hdmiSources(function (connected, disconnected) {
        var all = connected.concat(disconnected);
        var source = all.filter(function (s) { return s.number === port; })[0];
        if (!source) return onStatus('sourceError');
        var failed = function () { onStatus('inputError'); };
        try {
          tizen.tvwindow.setSource(source, function () {
            shownPort = port;
            showWindow(function () { onStatus('playing'); }, failed);
          }, failed);
        } catch (e) {
          failed();
        }
      });
    },

    // TV'nin ağ adresi; bilgisayarı aramak için.
    localAddress: function (callback) {
      function read(property, otherwise) {
        try {
          tizen.systeminfo.getPropertyValue(property, function (info) {
            if (info && info.ipAddress) callback(info.ipAddress); else otherwise();
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
        if (resolutionCallback) resolutionCallback(info || null);
      };
      var fail = function () { report(null); };
      try {
        var result = tizen.tvwindow.getVideoResolution(report, fail, 'MAIN');
        // Eski sürümler sonucu doğrudan döndürür.
        if (result && result.width) report(result);
      } catch (e) {
        fail();
      }
      if (resolutionListener === null) {
        try {
          resolutionListener = tizen.tvwindow.addVideoResolutionChangeListener(report, 'MAIN');
        } catch (e) {
          resolutionListener = false;
        }
      }
    },

    exit: function () {
      try { tizen.application.getCurrentApplication().exit(); } catch (e) {}
    }
  };
})();
