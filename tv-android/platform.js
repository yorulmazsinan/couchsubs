// SPDX-License-Identifier: AGPL-3.0-only
// Android TV'ye özgü işler; asıl iş MainActivity.java ve OverlayService.java'dadır. webOS karşılığı: tv-webos/platform.js
(function () {
  'use strict';

  var bridge = window.AndroidTV;
  var hdmiStatus = function () {};
  var relaunch = function () {};
  // Katman modu: sayfa TV'nin kendi HDMI ekranının üstündeki, kumandanın ulaşmadığı şeffaf pencerede çalışır.
  var overlay = !!(bridge.isOverlay && bridge.isOverlay());
  // Bağlantı bu süre içinde gelmezse katmanda küçük kırmızı nokta görünür.
  var DOT_AFTER_MS = 5000;
  var dot = null;
  var dotTimer = null;

  // Uygulamadan çıkılınca (Ana ekran, başka uygulama) Türkçe dublaj susar, öne gelince yeniden duyulur. Ortak sayfa sesi
  // new Audio(...) ile çalar; burada sarılır ki çalan ve arka plandayken başlayan ses kısılsın. Zamanlama değişmez.
  var NativeAudio = window.Audio;
  var muted = false;
  var lastAudio = null;
  if (NativeAudio) {
    var TrackedAudio = function (url) {
      var audio = url === undefined ? new NativeAudio() : new NativeAudio(url);
      audio.muted = muted;
      lastAudio = audio;
      return audio;
    };
    TrackedAudio.prototype = NativeAudio.prototype;
    window.Audio = TrackedAudio;
  }
  // Uygulama içi modda ekran arka plana düşünce (TV kendi HDMI oynatıcısını öne çekti: TCL Google TV'de PS5 60 Hz'e
  // geçince; Ana ekran) altyazı bağlantısı bırakılır, öne gelince yeniden kurulur (Samsung'daki closeWhenHidden). Eskiden
  // bağlantı arka planda açık kalıyordu: telefon/bilgisayar "TV bağlı" görüyor, deneme yazısı bile görünmeyen sayfaya
  // gidiyordu; Android'in arka plan uygulamalarını dondurması da bağlantıyı yarı açık bırakıyordu. Bağlantı düşünce
  // telefon/bilgisayar "CouchSubs'ı TV'de açın" der. Katman penceresi hep görünür: orada bırakılmaz.
  window.__onBackground = function (hidden) {
    muted = !!hidden;
    if (lastAudio) lastAudio.muted = muted;
    if (!overlay && window.__pageHidden) window.__pageHidden(!!hidden);
  };

  window.__onHdmiStatus = function (kind) { hdmiStatus(kind); };
  window.__onRelaunch = function (raw) { relaunch(raw); };
  // Kumanda tuşunu sayfaya iletir (Geri ve renk tuşları sayfaya kendiliğinden gelmez).
  window.__onKey = function (code) {
    var event = new Event('keydown', { cancelable: true });
    event.keyCode = code;
    document.dispatchEvent(event);
  };

  // Bağlantı kopukken katmanda sağ üstte küçük bir nokta; bağlıyken hiçbir şey görünmez.
  function connection(open) {
    if (!dot) return;
    if (open) {
      clearTimeout(dotTimer);
      dotTimer = null;
      dot.className = 'hidden';
      return;
    }
    if (dotTimer !== null || dot.className !== 'hidden') return;
    dotTimer = setTimeout(function () {
      dotTimer = null;
      dot.className = '';
    }, DOT_AFTER_MS);
  }

  function setupOverlay() {
    var style = document.createElement('style');
    // Bekleme kutusu ve demo kumandayla kapatılamaz; oyunun üstünde asılı kalmasın.
    style.textContent = 'body.overlay #waiting, body.overlay #demo-badge { display: none !important; }' +
      '#overlay-dot { position: absolute; top: 32px; right: 32px; width: 14px; height: 14px; border-radius: 50%;' +
      ' background: #F28B82; opacity: 0.8; z-index: 50; }' +
      '#overlay-dot.hidden { display: none; }';
    document.head.appendChild(style);
    document.body.className += ' overlay';
    dot = document.createElement('div');
    dot.id = 'overlay-dot';
    dot.className = 'hidden';
    document.body.appendChild(dot);
    connection(false);
  }

  // Ortak sayfanın EventSource'u sarılır: bilgisayarın görüntü modu seçimi (style olayındaki displayMode) Android'e
  // iletilir, bağlantı durumu katmandaki noktayı yönetir. Sayfanın kendi dinleyicileri olduğu gibi çalışır.
  var NativeSource = window.EventSource;
  if (NativeSource) {
    var Source = function (url, options) {
      var source = options === undefined ? new NativeSource(url) : new NativeSource(url, options);
      source.addEventListener('open', function () { connection(true); });
      source.addEventListener('error', function () { connection(source.readyState === 1); });
      source.addEventListener('style', function (e) {
        var mode;
        try { mode = JSON.parse(e.data).displayMode; } catch (err) { return; }
        if (typeof mode === 'string' && bridge.setDisplayMode) bridge.setDisplayMode(mode);
      });
      return source;
    };
    Source.prototype = NativeSource.prototype;
    Source.CONNECTING = 0;
    Source.OPEN = 1;
    Source.CLOSED = 2;
    window.EventSource = Source;
  }

  window.COUCHSUBS_PLATFORM = {
    backKey: 4,

    // Dublaj <audio> ile çalınır (LG ve Samsung'da Web Audio): HDMI'yi TvView gösterdiği için karışmaz, yukarıdaki
    // sarmalayıcı da sesi arka planda susturabilir.
    speechElement: true,

    // Uygulama içi modda arka plandayken bağlantı bırakılır (bkz. __onBackground); katmanda bırakılmaz.
    closeWhenHidden: !overlay,

    init: function () {
      // Android TV'nin güvenli alanı (yanlarda 48dp, üstte 27dp: 1080p'de 96 ve 54 piksel, TV-OV) artık ortak
      // style.css'in varsayılanıdır; burada ayrıca kurulmaz.
      if (overlay) setupOverlay();
      // Panelde Android uygulamasının kendi sürümü görünsün (ortak sayfadaki sayı LG ve Samsung'unkidir).
      var version = bridge.appVersion ? bridge.appVersion() : '';
      if (version) {
        window.addEventListener('load', function () {
          var el = document.getElementById('app-version');
          if (el) el.textContent = version;
        });
      }
    },

    launchParams: function () { return bridge.launchParams(); },

    onRelaunch: function (callback) { relaunch = callback; },

    // onStatus: 'loading' | 'ready' | 'playing' | 'inputError' | 'sourceError'
    showHdmi: function (port, host, onStatus) {
      hdmiStatus = onStatus;
      onStatus('loading');
      bridge.showHdmi(port);
    },

    // Yalnız "0" tuşundan sonra çağrılır (elle seçim bırakıldı): uygulamanın kaydettiği giriş de unutulur.
    findConsolePort: function (callback) {
      if (bridge.forgetInput) bridge.forgetInput();
      var port = bridge.consolePort();
      callback(port > 0 ? port : null, port > 0 ? 'HDMI ' + port : null);
    },

    // Açılışta açılacak giriş (#367): CEC'te PS5/Xbox adı, kayıtlı seçim, son görüntü gelen giriş, tek bağlı giriş.
    // Bulunamazsa port null: HDMI 1 açılmaz, chooseInput() giriş seçiciyi gösterir. auto: kendiliğinden bulundu.
    pickPort: !bridge.pickPort ? null : function (saved, callback) {
      var parts = String(bridge.pickPort(saved || 0)).split(':');
      var port = Number(parts[0]) || null;
      var reason = parts[1] || '';
      callback(port, reason === 'console' || reason === 'active');
    },

    chooseInput: function () { bridge.chooseInput(); },

    localAddress: function (callback) { callback(bridge.localAddress() || null); },

    // Bilgi panelindeki ikinci tanı satırı: görüntü modu (uygulama içinde / katman), TvView'in durumu, cihazın üreticisi,
    // modeli, Android ve WebView sürümü. Eski TV uygulamasının köprüsünde yoktur; o zaman yalnız WebView sürümü yazar.
    diagnostics: function () {
      var text = '';
      try { text = bridge.diagnostics ? String(bridge.diagnostics() || '') : ''; } catch (e) { text = ''; }
      var chrome = /Chrom(?:e|ium)\/([\d.]+)/.exec(window.navigator.userAgent || '');
      return (text ? text + ' · ' : '') + 'WebView ' + (chrome ? chrome[1] : '?');
    },

    exit: function () { bridge.exit(); }
  };
})();
