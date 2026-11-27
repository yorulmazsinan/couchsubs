// SPDX-License-Identifier: AGPL-3.0-only
// CouchSubs TV uygulaması (webOS ve Tizen ortak).
// HDMI girişini tam ekran gösterir, üstüne CouchSubs uygulamasından gelen altyazıyı basar.
// TV'ye özgü işler platform.js'tedir. Eski TV tarayıcıları için ES5 ile yazıldı.
(function () {
  'use strict';

  // TV uygulamasının sürümü: appinfo.json, tv-tizen/config.xml ve tv-android/app/build.gradle ile aynı tutulur.
  var APP_VERSION = '0.9.124';
  var t = window.t;
  var config = window.COUCHSUBS_CONFIG || {};
  var platform = window.COUCHSUBS_PLATFORM;
  var KEY = { RED: 403, GREEN: 404, YELLOW: 405, BLUE: 406, LEFT: 37, UP: 38, RIGHT: 39, DOWN: 40, OK: 13, BACK: platform.backKey };
  // Sayfa ölçüleri pageSize()/pageRect() ile alınır (platform sayfayı CSS zoom ile ölçeklerse window.COUCHSUBS_ZOOM;
  // Samsung 0.9.55'ten beri ölçeklemez, değer tanımsız yani 1).

  // --- Sayfa ölçüsü (#1098) ---
  // Eski LG'de (43LH590V, webOS 3.x, Chromium 38) platform.js sayfayı CSS zoom ile 1920x1080 uzayına sığdırır
  // (COUCHSUBS_ZOOM 0.6667). Chromium 38 kök öğenin clientWidth/clientHeight'ını ve getBoundingClientRect'i zaten bu
  // ölçekli uzayda (1920x1080) verir; yeni Chromium ekran pikselinde (1280x720). 0.9.115'te ölçüler her yerde zoom'a bir
  // kez daha bölünüyordu: eski LG sayfayı 2880x1620 sandı (tanı satırı "y 159-244/1619.9"), "Ekranı çevir" kutuları,
  // oyunun altyazısının yerine göre konan çeviri, telefon ve örtü 1,5 kat uzağa, ekranın sağ ve alt üçte birinin dışına
  // çiziliyordu (yalnız yüzdeyle konan deneme altyazısı görünüyordu). Sayfanın uzayı ekranı kaplayan sabit bir ölçü
  // öğesinin offset ölçüsüdür (iki tarayıcıda da ölçekli uzay); dikdörtgenlerin ölçeği aynı öğenin dikdörtgeni / offset
  // ölçüsüdür (Chromium 38'de 1, yeni Chromium'da zoom). Ölçek yoksa (bütün diğer TV'ler) eski ölçüler aynen kullanılır.
  var pageProbe = null;
  // inner: ölçek yokken innerWidth/innerHeight (kutu yerleşimi), yoksa kök öğenin clientWidth/clientHeight'ı.
  function pageSize(inner) {
    var root = document.documentElement || {};
    var width = (inner ? 0 : root.clientWidth) || window.innerWidth || 1920;
    var height = (inner ? 0 : root.clientHeight) || window.innerHeight || 1080;
    var zoom = window.COUCHSUBS_ZOOM || 1;
    if (zoom === 1) return { width: width, height: height, scale: 1 };
    try {
      if (!pageProbe || !pageProbe.parentNode) {
        pageProbe = document.createElement('div');
        pageProbe.id = 'page-probe';
        pageProbe.style.cssText = 'position:fixed;left:0;top:0;width:100%;height:100%;visibility:hidden;pointer-events:none;z-index:-1';
        (document.body || document.documentElement).appendChild(pageProbe);
      }
      var w = pageProbe.offsetWidth;
      var h = pageProbe.offsetHeight;
      if (w > 0 && h > 0) {
        var r = pageProbe.getBoundingClientRect();
        var scale = r.width > 0 ? r.width / w : 1;
        return { width: w, height: h, scale: Math.abs(scale - 1) < 0.005 ? 1 : scale };
      }
    } catch (e) {}
    return { width: width / zoom, height: height / zoom, scale: zoom };
  }

  // Ekrandaki dikdörtgen (getBoundingClientRect, getClientRects) sayfa uzayında.
  function pageRect(r, scale) {
    var s = scale || pageSize().scale;
    if (s === 1 || !r) return r;
    return { left: r.left / s, top: r.top / s, right: r.right / s, bottom: r.bottom / s, width: r.width / s, height: r.height / s };
  }

  // Tanı satırı için: sayfanın uzayı ve dikdörtgen ölçeği ("pg 1920x1080 r 0.67"; ölçek yoksa boş).
  function pageText() {
    if ((window.COUCHSUBS_ZOOM || 1) === 1) return '';
    var page = pageSize();
    return 'pg ' + Math.round(page.width) + 'x' + Math.round(page.height) + ' r ' + Math.round(page.scale * 100) / 100;
  }

  var server = null;
  var eventSource = null;
  // Kumandayla seçilen port kayıtlıysa o kullanılır, yoksa PS5 otomatik aranır.
  var savedPort = Number(load('hdmi'));
  var hdmiPort = savedPort || 1;
  // Gösterilen HDMI girişi (showHdmi çağrılınca) ve altyazı akışına bildirilen giriş. Bilgisayar/telefon bekçisi PS
  // tuşunun TV'yi bu girişe geçirmesini kullanıcının başka girişe geçmesinden ayırır (/events?hdmi=2).
  var shownPort = 0;
  var streamPort = 0;

  var bottomPercent = 7;
  // Çevirinin yeri: oyundaki İngilizce altyazının üstünü örterek (cover), üstünde (above), altında (below)
  // ya da sabit yükseklikte (fixed). Yeri bildirmeyen eski CouchSubs sürümlerinde sabit kalır.
  var PLACEMENTS = { cover: 1, above: 1, below: 1, fixed: 1 };
  var placement = 'fixed';
  // Gösterilen satırın oyundaki İngilizce altyazının yeri (ekrana oranla), bilinmiyorsa null.
  var currentBox = null;
  var lastCoverBox = null;

  // Hızlı konuşma: yeni satır öncekinden bu süre içinde gelirse önceki okunamamış olabilir. Önceki çeviri yeni satırın
  // üstünde küçük ve soluk olarak bir süre daha kalır, sonra solarak kalkar. Üç kişi art arda konuşursa iki önceki satır
  // da en üstte daha soluk durur; ekranda en çok üç satır olur.
  var STACK_WITHIN_MS = 1500;
  var PREVIOUS_HOLD_MS = 1500;
  var PREVIOUS_FADE_MS = 400;
  // Yeni satırla yer değiştirmedikçe hiçbir satır bundan kısa görünmez.
  var MIN_VISIBLE_MS = 1200;
  var shownAt = 0;
  var shownParagraphs = false;
  // Bilgisayardaki "Hızlı konuşmada önceki satırları üstte göster" ayarı (kapalıysa yeni satır eskisinin yerine geçer).
  // Ayar bilgisayardan gelene kadar son bilinen değer kullanılır; hiç gelmediyse açıktır (eski davranış).
  var stackPrevious = load('stackPrevious') !== '0';
  // Üstteki satırlar: 'subtitle-prev' bir önceki, 'subtitle-prev2' iki önceki. Her birinin kendi zamanlayıcıları var.
  var previousTimers = { 'subtitle-prev': [null, null], 'subtitle-prev2': [null, null] };

  var hideTimer = null;
  var panelTimer = null;
  // Gösterilen satırın kalkacağı an (showSubtitle) ve bilgisayardan gelen son satır: uygulama arka plana düşüp (PS tuşu,
  // TV girişe geçti) geri geldiğinde ya da bağlantı yeniden kurulunca süresi dolmamışsa yeniden çizilir.
  var shownUntil = 0;
  var lastLine = null;
  var RESTORE_MIN_MS = 800;

  // Bilgisayarın "temizle" olayı satırı bundan erken kaldırmaz: oyundaki satır çeviri gelirken kalkmışsa yazı TV'de
  // bir an görünüp kayboluyordu. Süre, bilgisayarın okuma süresi kuralıyla aynıdır; üst sınırı daha kısadır.
  var HOLD_MAX_MS = 5000;
  var holdUntil = 0;
  // Bağlantı bir an koptuğunda yazı silinmez; ancak bu süre içinde geri gelmezse silinir.
  var DROP_HIDE_MS = 6000;
  var dropTimer = null;

  // Panelde görünen tanı bilgisi: "yazı TV'ye gelmiyor" bildirimlerinde sebebi buradan okuruz.
  // regions/big: gelen ek alan ve "ekranı çevir" olayları ile çizilmeyen aşırı büyük kutular; speechWeb/speechElement:
  // dublajın hangi yoldan çalındığı (LG ve Samsung'da <audio> yolu HDMI görüntüsünü karartabiliyor).
  var diag = { subtitles: 0, clears: 0, drops: 0, backgrounded: 0, lastHide: '-', place: '-', error: '',
    regions: 0, big: 0, speechWeb: 0, speechElement: 0, keep: null };

  function $(id) { return document.getElementById(id); }

  // Bağlı bilgisayar/telefon `link` olayında kendi paketindeki TV uygulamasının sürümünü (`latest`) bildirir. Bu
  // sürümden eskiyse panel "TV uygulaması eski" der: kullanıcı TV'deki eski uygulamayı panelin fotoğrafından da görür
  // (GitHub #1199: LG'de 0.9.71 kalmıştı, düzeltme 0.9.94'teydi). Eski bilgisayar/telefon `latest` göndermez.
  var senderLatest = '';

  // Sürüm karşılaştırması (0.9.100 > 0.9.99); yalnız rakam ve nokta.
  function versionNewer(a, b) {
    var x = String(a).split('.'), y = String(b).split('.');
    for (var i = 0; i < Math.max(x.length, y.length); i++) {
      var p = parseInt(x[i] || '0', 10) || 0, q = parseInt(y[i] || '0', 10) || 0;
      if (p !== q) return p > q;
    }
    return false;
  }

  function outdatedText() {
    return senderLatest && versionNewer(senderLatest, APP_VERSION) ? t('appOutdated').replace('%1', senderLatest) : '';
  }

  function renderVersion() {
    var el = $('app-version');
    if (!el) return;
    var outdated = outdatedText();
    el.textContent = APP_VERSION + (outdated ? ' · ' + outdated : '');
    el.className = outdated ? 'bad' : 'muted';
  }

  function renderDiag() {
    var el = $('st-diag');
    if (!el) return;
    var outdated = outdatedText();
    el.textContent = (outdated ? outdated + ' · ' : '') + 'sub ' + diag.subtitles + ' · clear ' + diag.clears + ' · drop ' + diag.drops +
      ' · bg ' + diag.backgrounded + (diag.revived ? ' · revived ' + diag.revived : '') + ' · hide ' + diag.lastHide + ' · ' + diag.place +
      (window.__screenSaverStatus ? ' · saver ' + window.__screenSaverStatus : '') +
      (tvlogLast ? ' · tv ' + tvlogLast : '') +
      (diag.error ? ' · err ' + diag.error : '');
    renderPlatformDiag();
  }

  // İkinci tanı satırı: HDMI görüntüsünün durumu ve TV'nin kendisi (platform.diagnostics; LG'de <video>'nun durumu ve
  // webOS sürümü, Android TV'de görüntü modu, TvView durumu ve cihaz), ardından sayfanın çizdiği kutular. "Ekran siyah,
  // ses var" bildirimlerinde görüntü mü düşmüş, yoksa sayfa mı üstünü örtmüş, fotoğraftan anlaşılsın.
  function renderPlatformDiag() {
    var el = $('st-platform');
    // Yalnız panel açıkken hesaplanır (her altyazıda değil).
    if (!el || !$('panel') || $('panel').className === 'hidden') return;
    var text = '';
    try { text = typeof platform.diagnostics === 'function' ? String(platform.diagnostics() || '') : ''; } catch (e) { text = ''; }
    var size = pageText();
    // keep: görev satırının üstü (ekranın yüzdesi) ve altyazının ondan kaçmak için kayması (bkz. clearObjective).
    var page = (size ? size + ' · ' : '') + 'reg ' + diag.regions + ' · big ' + diag.big + ' · ' + coverageText() +
      (diag.keep !== null && diag.keep !== undefined ? ' · keep ' + diag.keep + '%' + (objectiveShift ? ' ' + objectiveShift + 'px' : '') : '') +
      (diag.speechWeb || diag.speechElement ? ' · tts w' + diag.speechWeb + ' a' + diag.speechElement : '') +
      // Dublaj çalarken açık Web Audio bağlamı (dublaj hiç çalmadıysa bağlam yoktur, HDMI sesine karışamaz).
      (audioContext ? ' ac ' + audioContext.state : '');
    el.textContent = (text ? text + ' · ' : '') + page;
    $('row-platform').style.display = '';
    fitPanel();
  }

  // Bilgi paneli ekrana sığmazsa (uzun tanı satırları; Samsung Odyssey G9'da panelin altı ekranın dışında kalıyordu,
  // oyun modunda daha da büyüyordu, #886) sol üst köşesinden küçültülür: alttaki tuş listesi kesilmez. Ölçü görünen
  // alandır (sayfa ya da görsel görünüm hangisi küçükse); panelin üst ve sol boşluğu altta ve sağda da bırakılır.
  var PANEL_MIN_SCALE = 0.5;
  function setPanelScale(panel, scale) {
    var value = scale < 1 ? 'scale(' + scale + ')' : '';
    panel.style.webkitTransformOrigin = panel.style.transformOrigin = '0 0';
    panel.style.webkitTransform = value;
    panel.style.transform = value;
  }

  function fitPanel() {
    var panel = $('panel');
    if (!panel || panel.className === 'hidden') return;
    try {
      var page = pageSize();
      var width = page.width;
      var height = page.height;
      var visual = window.visualViewport;
      // Görsel görünüm ekran pikselindedir; sayfa uzayına çevrilir.
      if (visual && visual.height > 0 && visual.width > 0 && (window.COUCHSUBS_ZOOM || 1) === 1) {
        width = Math.min(width, visual.width);
        height = Math.min(height, visual.height);
      }
      // Doğal ölçü (offset ölçüleri dönüşümden etkilenmez).
      var top = panel.offsetTop;
      var left = panel.offsetLeft;
      var scale = Math.min(1, (height - top * 2) / panel.offsetHeight, (width - left * 2) / panel.offsetWidth);
      if (!(scale > 0)) scale = 1;
      setPanelScale(panel, Math.max(PANEL_MIN_SCALE, Math.round(scale * 1000) / 1000));
    } catch (e) {}
  }

  // Sayfanın oyunun üstüne çizdiği kutular: sayısı ve en büyüğünün ekrana oranı ("ovl 2 max 4%").
  function coverageText() {
    var count = 0;
    var largest = 0;
    try {
      var width = pageSize(true).width;
      var height = pageSize(true).height;
      var boxes = document.querySelectorAll('#screen .item, #regions .item, #regions .region, #subtitle-cover');
      for (var i = 0; i < boxes.length; i++) {
        var rect = pageRect(boxes[i].getBoundingClientRect());
        if (!(rect.width > 0 && rect.height > 0)) continue;
        count++;
        largest = Math.max(largest, rect.width * rect.height / (width * height));
      }
    } catch (e) {}
    return 'ovl ' + count + (count ? ' max ' + Math.round(largest * 100) + '%' : '');
  }

  function noteError(message) {
    diag.error = String(message).slice(0, 120);
    renderDiag();
  }

  window.onerror = function (message, source, line) {
    noteError(message + ' @' + line);
    return false;
  };

  document.addEventListener('visibilitychange', function () {
    if (document.hidden) diag.backgrounded++;
    renderDiag();
  });

  // Panel açıkken tanı satırları tazelenir (görüntünün durumu olay olmadan da değişir).
  setInterval(function () {
    var panel = $('panel');
    if (panel && panel.className !== 'hidden') renderDiag();
  }, 2000);

  function load(key) {
    try { return window.localStorage.getItem('couchsubs.' + key); } catch (e) { return null; }
  }

  function save(key, value) {
    try { window.localStorage.setItem('couchsubs.' + key, String(value)); } catch (e) {}
  }

  // Anahtar sunucuya aittir: telefon ve bilgisayar arasında geçişte birbirine gönderilmez.
  function serverKey(address) {
    try { return (JSON.parse(load('keys') || '{}') || {})[address.replace(/\/+$/, '')] || ''; } catch (e) { return ''; }
  }

  function saveServerKey(address, key) {
    if (!/^[A-Za-z0-9_-]{22}$/.test(key || '')) return;
    var keys;
    try { keys = JSON.parse(load('keys') || '{}') || {}; } catch (e) { keys = {}; }
    keys[address.replace(/\/+$/, '')] = key;
    save('keys', JSON.stringify(keys));
  }

  function authenticatedUrl(address, path) {
    var key = serverKey(address);
    return address + path + (key ? (path.indexOf('?') < 0 ? '?' : '&') + 'k=' + encodeURIComponent(key) : '');
  }

  // --- TV olay günlüğü (0.9.116) ---
  // "Ekran sürekli göz kırpıyor, gidip geliyor" bildirimlerinde (beta.102-104) nedeni yalnız panelin fotoğrafından okuyorduk.
  // Artık görüntüyü karartabilen her olay (HDMI'nin yeniden kurulması/açılması, sayfanın yenilenmesi, uygulamanın yeniden
  // açılması ya da ekranın yeniden kurulması, Android TV'de kapanma isteği) nedeniyle birlikte bilgisayarın/telefonun
  // günlüğüne gider: `GET /tvlog?m=<satır>&a=<kaç sn önce>`. Aynı türden satır TVLOG_GAP_MS'de bir (arada atlananlar
  // "+n" olarak sayılır), TVLOG_WINDOW_MS'de en çok TVLOG_WINDOW_MAX satır. Gönderilemeyenler localStorage'da bekler
  // (sayfa yenilense de kaybolmaz), en çok TVLOG_PENDING_MAX. Eski bilgisayar/telefon /tvlog'u tanımaz (404): satır atılır.
  // Platformun kendi olayları (Android TV: MainActivity) platform.takeEvents ile alınır.
  var TVLOG_KEY = 'tvlog';
  var TVLOG_GAP_MS = 15000;
  var TVLOG_WINDOW_MS = 10 * 60000;
  var TVLOG_WINDOW_MAX = 20;
  var TVLOG_PENDING_MAX = 20;
  var TVLOG_TEXT_MAX = 160;
  var tvlogKinds = {};
  var tvlogTimes = [];
  var tvlogBusy = false;
  var tvlogLast = '';

  function tvlogPending() {
    try {
      var list = JSON.parse(load(TVLOG_KEY) || '[]');
      return Object.prototype.toString.call(list) === '[object Array]' ? list : [];
    } catch (e) {
      return [];
    }
  }

  function tvLog(text) {
    var line = String(text == null ? '' : text).replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/^\s+|\s+$/g, '');
    if (!line) return;
    if (line.length > TVLOG_TEXT_MAX) line = line.slice(0, TVLOG_TEXT_MAX);
    var now = Date.now();
    // Tür: parantezden önceki kısım ("hdmi rebuild (ev stalled)" → "hdmi rebuild").
    var kind = line.replace(/\s*\(.*$/, '');
    var slot = tvlogKinds[kind] || (tvlogKinds[kind] = { at: 0, skipped: 0 });
    if (slot.at && now - slot.at < TVLOG_GAP_MS) {
      slot.skipped++;
      return;
    }
    while (tvlogTimes.length && now - tvlogTimes[0] >= TVLOG_WINDOW_MS) tvlogTimes.shift();
    if (tvlogTimes.length >= TVLOG_WINDOW_MAX) {
      slot.skipped++;
      return;
    }
    tvlogTimes.push(now);
    if (slot.skipped) line += ' +' + slot.skipped;
    slot.at = now;
    slot.skipped = 0;
    tvlogLast = line;
    var pending = tvlogPending();
    pending.push({ t: now, m: line });
    while (pending.length > TVLOG_PENDING_MAX) pending.shift();
    save(TVLOG_KEY, JSON.stringify(pending));
    renderDiag();
    flushTvLog();
  }
  window.COUCHSUBS_TVLOG = tvLog;

  // Bekleyen satırları sırayla gönderir (yalnız akış açıkken). Ağ hatasında durur, sonra yeniden dener.
  function flushTvLog() {
    if (typeof platform.takeEvents === 'function') {
      var events = [];
      try { events = platform.takeEvents() || []; } catch (e) { events = []; }
      for (var i = 0; i < events.length; i++) tvLog(events[i]);
    }
    if (tvlogBusy || !server || !eventSource || eventSource.readyState !== 1 || !window.XMLHttpRequest) return;
    var pending = tvlogPending();
    if (!pending.length) return;
    var item = pending[0] || {};
    var age = Math.max(0, Math.round((Date.now() - (Number(item.t) || Date.now())) / 1000));
    var xhr = new XMLHttpRequest();
    var settled = false;
    tvlogBusy = true;
    function done(sent) {
      if (settled) return;
      settled = true;
      tvlogBusy = false;
      if (!sent) return;
      var rest = tvlogPending();
      if (rest.length && rest[0].t === item.t && rest[0].m === item.m) rest.shift();
      save(TVLOG_KEY, JSON.stringify(rest));
      if (rest.length) setTimeout(flushTvLog, 0);
    }
    // Yanıt geldiyse (204 ya da eski sunucunun 404'ü) satır gitmiş sayılır; ağ hatasında bekler.
    xhr.onload = function () { done(true); };
    xhr.onerror = function () { done(false); };
    xhr.ontimeout = function () { done(false); };
    try {
      xhr.open('GET', authenticatedUrl(server, '/tvlog?m=' + encodeURIComponent(String(item.m || '')) + '&a=' + age));
      xhr.timeout = 4000;
      xhr.send();
    } catch (e) {
      done(false);
    }
  }
  setInterval(flushTvLog, 10000);

  function setStatus(id, text, cls) {
    var el = $(id);
    el.textContent = text;
    el.className = cls || '';
  }

  // --- Başlatma parametreleri ---

  function parseParams(raw) {
    if (!raw) return {};
    if (typeof raw === 'object') return raw;
    try { return JSON.parse(raw) || {}; } catch (e) { return {}; }
  }

  // Parametrelerdeki sunucu ve HDMI tercihini uygular; sunucu değiştiyse yeniden bağlanır.
  function applyParams(params) {
    if (params.hdmi >= 1 && params.hdmi <= 4) chooseHdmiFromComputer(Number(params.hdmi));
    if (params.server) {
      var address = params.server.replace(/\/+$/, '');
      var oldKey = serverKey(address);
      if (params.key) saveServerKey(address, params.key);
      // Adresi bilgisayar ya da telefon kendisi verdi: bağlanınca kimliği "kendi CouchSubs'ı" olarak kaydedilir.
      adoptAddress = address;
      if (address !== server || oldKey !== serverKey(address)) {
        save('server', address);
        connect(address);
      } else if (eventSource && eventSource.readyState === 1) {
        learnServer(server);
      }
    }
  }

  // --- HDMI görüntüsü ---

  // Bilgi panelindeki giriş: numara, TV'nin giriş listesindeki adı (LG) ve nasıl seçildiği.
  function hdmiText(port, how) {
    var label = '';
    try { label = typeof platform.inputLabel === 'function' ? platform.inputLabel(port) : ''; } catch (e) {}
    var text = String(port) + (label && label !== 'HDMI ' + port ? ' — ' + label : '');
    if (how) text += ' (' + t(how) + ')';
    else if (Number(load('hdmi')) === port) text += ' (' + t('manualInput') + ')';
    return text;
  }

  // Kullanıcı girişi kendisi seçti (sayı tuşu, ◀▶, giriş kutusu): seçim saklanır, otomatik deneme sırası bırakılır.
  function chooseHdmi(port) {
    autoQueue = [];
    hdmiPort = port;
    save('hdmi', hdmiPort);
    showHdmi(hdmiPort);
  }

  // Bilgisayarın/telefonun bildirdiği giriş (açılış parametresi `hdmi`, stil `hdmiInput`). Zaten gösterilen girişse
  // yalnız saklanır, görüntüye dokunulmaz (TV uygulaması 0.9.80, #1055): aynı girişi yeniden açmak <video>'yu bırakıp
  // yeniden kuruyor, ekran kararıp "HDR" yazısıyla geri geliyordu; bilgisayar her yeniden açışta aynı değeri gönderirse
  // bu her seferinde olurdu. Kumandayla aynı girişin yeniden seçilmesi (chooseHdmi) eskisi gibi yeniden kurar.
  function chooseHdmiFromComputer(port) {
    if (port === shownPort && port === hdmiPort) {
      autoQueue = [];
      save('hdmi', port);
      return;
    }
    chooseHdmi(port);
  }

  function showHdmi(port) {
    setStatus('st-hdmi', hdmiText(port));
    shownPort = port;
    // Akış başka girişle açılmışsa bilgisayar/telefon yeni girişi öğrensin diye yeniden açılır (giriş değişince bir kez).
    if (eventSource && server && streamPort !== port && !pausedByHidden && !demoRunning()) connectStream(server);
    var statuses = {
      loading: ['loading', 'muted'],
      ready: ['videoReady', 'ok'],
      playing: ['playing', 'ok'],
      inputError: ['inputError', 'bad'],
      sourceError: ['sourceError', 'bad']
    };
    watchPicture(port);
    platform.showHdmi(port, $('video-host'), function (kind) {
      setStatus('st-video', t(statuses[kind][0]), statuses[kind][1]);
      // Giriş değişince çözünürlük de değişir; görüntü gelince yeniden okunur.
      if (kind === 'playing') watchResolution();
      notePicture(port, kind);
    });
  }

  // --- HDMI görüntüsünün çözünürlüğü ---
  // TV'nin bildirdiği giriş çözünürlüğü ve yenileme hızı panelde gösterilir ("3840×2160 · 60 Hz"): uygulama içinde
  // PS5 görüntüsünün 1080p'ye düştüğü bildirimlerini doğrulamak için. Yalnız bildiren platformlarda (Samsung) görünür.
  function formatResolution(info) {
    if (!info || !(info.width > 0) || !(info.height > 0)) return '';
    var text = Math.round(info.width) + '×' + Math.round(info.height);
    var hz = Number(info.frequency);
    if (hz > 0) text += ' · ' + (Math.abs(hz - Math.round(hz)) < 0.05 ? Math.round(hz) : hz.toFixed(2)) + ' Hz';
    return text;
  }

  function showResolution(info) {
    var text = formatResolution(info);
    $('row-resolution').style.display = text ? '' : 'none';
    if (text) setStatus('st-resolution', text, 'muted');
  }

  // Samsung'da HDMI penceresinin istenen/kabul edilen ölçüsü ve TV'nin bildirdiği ekran ölçüleri (#304): ultrawide
  // monitör fotoğrafında hangi denemenin reddedildiği görünsün. Platform bildirmezse satır gizli kalır.
  function watchPictureWindow() {
    if (typeof platform.pictureDiagnostics !== 'function') return;
    try {
      platform.pictureDiagnostics(function (text) {
        $('row-window').style.display = text ? '' : 'none';
        if (text) setStatus('st-window', text, 'muted');
        // Panelin gerçek ölçüsü HDMI açılırken okunur; Sarı tuş listede ona göre görünür (#304).
        formatKeys();
        fitPanel();
      });
    } catch (e) {}
  }

  function watchResolution() {
    if (typeof platform.videoResolution !== 'function') return;
    try { platform.videoResolution(showResolution); } catch (e) {}
  }

  // --- HDMI görüntüsü gelmiyor ---
  // LG'de HDMI girişi <video> ile (ext://hdmi), Samsung'da TVWindow ile açılır. Giriş açılamazsa ya da 10 sn içinde
  // görüntü gelmezse ekran sessizce siyah kalıyordu (LG QNED: "Çeviriyi başlat"a basınca TV kararıyor). Artık nedeni ve
  // HDMI girişi düğmeleri gösterilir; doğru girişte de siyahsa TV'nin kendi girişine dönüp altyazıyı telefonda izlemek
  // önerilir. Android TV'deki giriş seçiciyle (#155) aynı akış; Android bunu kendi ekranında yaptığından orada kapalıdır.

  var NO_PICTURE_MS = 10000;
  var pictureTimer = null;
  var pictureOk = false;
  var noPictureClosed = false;
  var noPictureFocus = 0;
  var noPictureActions = [];
  // Kutu görüntü yokken değil, konsolun girişini sormak için açık (#360): görüntü gelince kendiliğinden kapanmaz.
  var choosingInput = false;
  // Otomatik seçimde görüntü gelmezse sırayla denenecek girişler (platform.findConsolePort'un adayları; yalnız LG verir).
  var autoQueue = [];

  function watchPicture(port) {
    clearTimeout(pictureTimer);
    pictureOk = false;
    noPictureClosed = false;
    hideNoPicture();
    if (!platform.noPictureHelp) return;
    pictureTimer = setTimeout(function () {
      // Bazı TV'ler görüntüyü gösterip 'playing' olayını hiç göndermiyor; görüntü varsa kutu açılmaz.
      if (pictureOk || (platform.hasPicture && platform.hasPicture())) return;
      if (tryNextInput(port)) return;
      showNoPicture(port, false);
    }, NO_PICTURE_MS);
  }

  // Otomatik seçilen girişte görüntü gelmedi (LG: soundbar/AV cihazı ya da başka cihaz konsolun önüne geçti): TV'nin
  // giriş listesindeki sıradaki aday denenir, saklanmaz. Aday kalmayınca giriş kutusu açılır. Kullanıcı girişi kendisi
  // seçtiyse (autoQueue boş) denenmez.
  function tryNextInput(port) {
    if (port !== hdmiPort || demoRunning()) return false;
    while (autoQueue.length && autoQueue[0] === port) autoQueue.shift();
    if (!autoQueue.length) return false;
    var next = autoQueue.shift();
    hdmiPort = next;
    showHdmi(next);
    setStatus('st-hdmi', hdmiText(next, 'tryingInput'));
    return true;
  }

  function notePicture(port, kind) {
    if (port !== hdmiPort) return;
    if (kind === 'ready' || kind === 'playing') {
      pictureOk = true;
      clearTimeout(pictureTimer);
      if (!choosingInput) hideNoPicture();
    } else if (kind === 'inputError' || kind === 'sourceError') {
      clearTimeout(pictureTimer);
      if (tryNextInput(port)) return;
      if (platform.noPictureHelp) showNoPicture(port, true);
    }
  }

  function noPictureShown() { return $('no-picture').className !== 'hidden'; }

  function showNoPicture(port, failed) {
    if (noPictureClosed || pictureOk || demoRunning()) return;
    // Neden ve ne yapılacağı düğmelerin üstünde; uzun "hâlâ siyah mı" açıklaması (index.html, #no-picture-help)
    // düğmelerin altında, küçük ve ikincil renkte durur.
    choosingInput = false;
    showChoices(port, t('noPictureTitle'),
      t(failed ? 'noPictureError' : 'noPicture').replace('%1', port) + ' ' + t('noPictureChoose'), true);
  }

  // TV'ye birden çok HDMI cihazı bağlı ve konsolun girişi tahmin edildi (Samsung girişteki cihazın adını vermez).
  // Görüntü gelse de kullanıcıya sorulur: bilgisayar da TV'ye bağlıyken uygulama Xbox yerine bilgisayarın ekranını
  // açıyor, kullanıcı test altyazısını bilgisayarın görüntüsünün üstünde görüp oyunda çeviri çıkmıyor sanıyordu (#360).
  // Seçilen giriş kaydedilir; sonraki açılışlarda sorulmaz.
  function askConsoleInput(port) {
    if (noPictureClosed || demoRunning()) return;
    choosingInput = true;
    showChoices(port, t('pickInputTitle'), t('pickInput').replace('%1', port), false);
  }

  function showChoices(port, title, text, stillBlackHelp) {
    $('no-picture-title').textContent = title;
    $('no-picture-text').textContent = text;
    $('no-picture-help').style.display = stillBlackHelp ? '' : 'none';
    var box = $('no-picture-choices');
    box.innerHTML = '';
    var actions = [];
    for (var i = 1; i <= 4; i++) actions.push({ label: 'HDMI ' + i, port: i });
    actions.push({ label: t('noPictureExit'), exit: true });
    actions.push({ label: t('noPictureClose'), close: true });
    for (var j = 0; j < actions.length; j++) {
      var button = document.createElement('div');
      button.className = 'button' + (actions[j].port === port ? ' current' : '');
      button.textContent = actions[j].label;
      button.addEventListener('click', choiceClick(actions[j], j));
      // LG Magic Remote: işaretçinin üstünde durduğu düğme seçili olur; Tamam ve oklar oradan devam eder.
      button.addEventListener('mouseover', choiceHover(j));
      actions[j].el = button;
      box.appendChild(button);
    }
    noPictureActions = actions;
    $('panel').className = 'hidden';
    $('waiting').className = 'hidden';
    $('no-picture').className = '';
    // Açık olandan sonraki giriş seçili gelir (HDMI 1 açıksa HDMI 2).
    focusNoPicture(port % 4);
  }

  function choiceClick(action, index) {
    return function (e) {
      e.stopPropagation();
      // Tamam tuşu işaretçi görünürken tıklama da gönderir; tuşla seçilen bir daha seçilmez.
      if (Date.now() - lastOkKey < 400) return;
      focusNoPicture(index);
      runNoPicture(action);
    };
  }

  function choiceHover(index) {
    return function () {
      if (index !== noPictureFocus) focusNoPicture(index);
    };
  }

  function focusNoPicture(index) {
    var count = noPictureActions.length;
    noPictureFocus = (index + count) % count;
    for (var i = 0; i < count; i++) {
      var el = noPictureActions[i].el;
      el.className = el.className.replace(' focused', '') + (i === noPictureFocus ? ' focused' : '');
    }
  }

  // ▲▼: düğmeler iki satıra bölünürse (uzun dil, dar ekran) bir üst/alt satırda yatayda en yakın düğmeye geçer.
  // Tek satırda yerinde kalır (◀▶ zaten sırayla gezer).
  function focusNoPictureRow(step) {
    var current = noPictureActions[noPictureFocus].el;
    var top = current.offsetTop;
    var center = current.offsetLeft + current.offsetWidth / 2;
    var best = -1, bestRow = 0, bestSide = 0;
    for (var i = 0; i < noPictureActions.length; i++) {
      var el = noPictureActions[i].el;
      var row = (el.offsetTop - top) * step;
      // Aynı satırdakiler (birkaç piksel fark dahil) ve ters yöndekiler atlanır.
      if (row <= 2) continue;
      var side = Math.abs(el.offsetLeft + el.offsetWidth / 2 - center);
      if (best < 0 || row < bestRow - 2 || (Math.abs(row - bestRow) <= 2 && side < bestSide)) {
        best = i;
        bestRow = row;
        bestSide = side;
      }
    }
    if (best >= 0) focusNoPicture(best);
  }

  function runNoPicture(action) {
    if (action.exit) {
      hideNoPicture();
      leaving = true;
      platform.exit(true);
    } else if (action.close) {
      closeNoPicture();
    } else {
      chooseHdmi(action.port);
      showPanel(true);
    }
  }

  // Kullanıcı kutuyu kapattı: başka giriş seçilene ya da uygulama yeniden başlatılana kadar yeniden açılmaz.
  function closeNoPicture() {
    noPictureClosed = true;
    hideNoPicture();
  }

  function hideNoPicture() {
    var el = $('no-picture');
    if (!el || el.className === 'hidden') return;
    choosingInput = false;
    el.className = 'hidden';
    if (!server && !demoRunning()) $('waiting').className = '';
  }

  // Açılışta girişi açar. Platform girişi kendisi seçebiliyorsa (Android TV: CEC'teki konsol adı, kayıtlı seçim, son
  // görüntü gelen giriş, tek bağlı giriş) o kullanılır; bulunamazsa HDMI 1 açılmaz, kullanıcıya giriş seçici gösterilir
  // (#367: PS5 HDMI 3'teyken TV HDMI 1'e geçiyordu). Diğer TV'lerde kayıtlı giriş ya da HDMI 1 açılır, PS5 aranır.
  function startHdmi() {
    if (!platform.pickPort) {
      showHdmi(hdmiPort);
      if (!savedPort) autoSelectConsole();
      return;
    }
    platform.pickPort(savedPort, function (port, auto) {
      if (!port) {
        setStatus('st-hdmi', t('consoleNotFound'), 'bad');
        platform.chooseInput();
        return;
      }
      hdmiPort = port;
      showHdmi(port);
      if (auto) setStatus('st-hdmi', port + ' (' + t('auto') + ')');
    });
  }

  // connected: bağlı HDMI sayısı (yalnız Samsung bildirir). Birden çoksa seçim tahmindir, giriş kullanıcıya sorulur.
  // candidates: görüntü gelmezse sırayla denenecek girişler (LG; ilki port).
  function autoSelectConsole(onNotFound) {
    platform.findConsolePort(function (port, label, connected, candidates) {
      var guessed = connected > 1;
      autoQueue = port && candidates && candidates.length > 1 ? candidates.slice() : [];
      if (!port) {
        if (guessed) askConsoleInput(hdmiPort);
        return onNotFound && onNotFound();
      }
      if (port !== hdmiPort) {
        hdmiPort = port;
        showHdmi(port);
      }
      setStatus('st-hdmi', port + ' — ' + label + ' (' + t('auto') + ')');
      if (guessed) askConsoleInput(port);
    });
  }

  // --- Altyazı ---

  // Kutunun sayıları geçerli mi (0–1 arası, sağ soldan, alt üstten büyük).
  function validBox(box) {
    if (!box || typeof box !== 'object') return null;
    var keys = ['left', 'top', 'right', 'bottom'];
    for (var i = 0; i < keys.length; i++) {
      var value = box[keys[i]];
      if (typeof value !== 'number' || value < 0 || value > 1) return null;
    }
    return box.right > box.left && box.bottom > box.top ? box : null;
  }

  function fillText(el, text, icons) {
    /* Çevirinin içindeki kumanda simgeleri ("Koşmak için [△] basılı tut"): bilgisayar simgeyi oyun karesinden kesip
       PNG olarak gönderir; icons = [{at, src}], at düz metindeki yeridir. Simge yoksa düz metin yazılır. */
    el.textContent = '';
    var list = [];
    for (var i = 0; icons && i < icons.length; i++) {
      var icon = icons[i];
      if (icon && typeof icon.at === 'number' && typeof icon.src === 'string' && icon.src.indexOf('data:image/') === 0) {
        list.push(icon);
      }
    }
    if (!list.length) {
      el.textContent = text;
      return;
    }
    list.sort(function (a, b) { return a.at - b.at; });
    var position = 0;
    for (var j = 0; j < list.length; j++) {
      var at = Math.max(position, Math.min(text.length, Math.floor(list[j].at)));
      if (at > position) el.appendChild(document.createTextNode(text.slice(position, at)));
      var image = document.createElement('img');
      image.className = 'icon';
      image.alt = '';
      image.src = list[j].src;
      el.appendChild(image);
      position = at;
    }
    if (position < text.length) el.appendChild(document.createTextNode(text.slice(position)));
  }

  // --- Konuşan rengi ---
  // Bilgisayar altyazıdaki konuşan adlarını ve renklerini gönderir: speakerNames = [{name, color}] ("Konuşan adını
  // renklendir" ayarı açıksa; eski sürümler aynı listeyi speakers adıyla gönderir; hiç göndermeyen eski bilgisayarda yazı
  // tek renk kalır). Yalnız satır başındaki "Ad:" o konuşanın renginde yazılır, cümle kullanıcının yazı renginde kalır.
  // Renk bilgisayarda addan hesaplanır: aynı karakter her cihazda hep aynı renktir.
  function speakerMap(list) {
    if (!list || typeof list.length !== 'number') return null;
    var map = null;
    for (var i = 0; i < list.length && i < 16; i++) {
      var item = list[i];
      if (!item || typeof item.name !== 'string' || !item.name || item.name.length > 40) continue;
      if (typeof item.color !== 'string' || !/^#[0-9A-Fa-f]{6}$/.test(item.color)) continue;
      map = map || {};
      map[item.name] = item.color;
    }
    return map;
  }

  // Metnin parçaları: [{text, color}] (renksiz parçada color null). Ad yalnız satır başında aranır ve yalnız "Ad:"
  // boyanır; cümle ve bölünmüş devam satırları kullanıcının yazı renginde kalır (TV 0.9.79; önceden bütün satır
  // boyanıyor, "Yazı rengi" beyazken altyazı renkli görünüyordu).
  // wholeLine (Karakter Adı › "Tüm Satır", style.wholeLine): ad ve cümle, devam satırlarıyla birlikte sonraki konuşanın
  // adına dek o konuşanın renginde (Mac, iPhone, Windows ve Android ile aynı).
  function speakerSegments(text, map, wholeLine) {
    if (!map) return [{ text: text, color: null }];
    var segments = [];
    var start = 0;
    var lineStart = 0;
    var running = null;
    while (lineStart <= text.length) {
      var found = null;
      var end = 0;
      for (var name in map) {
        if (!Object.prototype.hasOwnProperty.call(map, name)) continue;
        if (text.substr(lineStart, name.length) !== name) continue;
        var at = lineStart + name.length;
        if (text.charAt(at) === ' ') at++;
        var after = text.charAt(at);
        if ((after === ':' || after === '\uFF1A') && (!found || name.length > found.length)) {
          found = name;
          end = at + 1;
        }
      }
      if (found) {
        if (lineStart > start) segments.push({ text: text.slice(start, lineStart), color: running });
        if (wholeLine) {
          running = map[found];
          start = lineStart;
        } else {
          segments.push({ text: text.slice(lineStart, end), color: map[found] });
          start = end;
        }
      }
      var next = text.indexOf('\n', lineStart);
      if (next < 0) break;
      lineStart = next + 1;
    }
    if (start < text.length || !segments.length) segments.push({ text: text.slice(start), color: running });
    return segments;
  }

  // Yeni arayüzdeki "Karakter Adı" rengi yalnız adı boyar (style.nameOnly). 0.9.79'dan beri speakerSegments zaten
  // yalnız "Ad:" bölümünü renkli verir; bu ayrım yeni arayüzle uyum için kalıyor (cümle hiçbir durumda boyanmaz).
  var speakerNameOnly = false;
  // Karakter Adı › Tüm Satır (style.wholeLine): cümle de konuşanın renginde. Alanı göndermeyen bilgisayarda yalnız ad.
  var speakerWholeLine = false;

  function paintSpeakers(el, text, map) {
    var segments = speakerSegments(text, map, speakerWholeLine);
    if (segments.length === 1 && !segments[0].color) return;
    el.textContent = '';
    for (var i = 0; i < segments.length; i++) {
      if (!segments[i].color) {
        el.appendChild(document.createTextNode(segments[i].text));
        continue;
      }
      var colored = segments[i].text;
      var rest = '';
      if (speakerNameOnly && !speakerWholeLine) {
        var colon = colored.search(/[:：]/);
        if (colon >= 0) {
          rest = colored.slice(colon + 1);
          colored = colored.slice(0, colon + 1);
        }
      }
      var span = document.createElement('span');
      span.className = 'speaker';
      span.baseColor = segments[i].color;
      span.style.color = dimmedColor(el.id, segments[i].color);
      span.textContent = colored;
      el.appendChild(span);
      if (rest) el.appendChild(document.createTextNode(rest));
    }
  }

  // --- Uzun çeviriyi bölme ---
  // Uzun çeviri en çok 3 satıra, kelime sınırından ve dengeli bölünür; 3 satıra sığmazsa yazı biraz küçülür (en çok
  // %75'e kadar). Konuşan adı ("ARTHUR:") sonraki sözcükle birleşik kalır, hep ilk satırdadır. Satır sınırı TV'de
  // ekran genişliğidir (aşağıda wrapToWidth); 42 karakter kuralı yalnız ölçüm yapılamazsa kullanılır. Mac, Windows,
  // Android ve OBS (SubtitleWrap) hâlâ 42 karakter kuralını uygular.
  var WRAP_MAX_CHARS = 42;
  var WRAP_MAX_LINES = 3;
  var WRAP_MIN_SCALE = 1;
  var fontBase = 46;

  function wrapTokens(text) {
    var words = text.split(/\s+/).filter(function (w) { return w; });
    for (var i = 0; i < Math.min(3, words.length); i++) {
      var w = words[i];
      if (w.charAt(w.length - 1) === ':' || w.charAt(w.length - 1) === '\uFF1A') {
        if (i + 1 < words.length) words.splice(0, i + 2, words.slice(0, i + 2).join(' '));
        break;
      }
    }
    return words;
  }

  function wrapWidth(words, from, to) {
    var sum = to - from - 1;
    for (var i = from; i < to; i++) sum += words[i].length;
    return sum;
  }

  function wrapBalance(words, lines) {
    var count = words.length;
    var best = null;
    function consider(cuts) {
      var edges = [0].concat(cuts, [count]);
      var longest = 0;
      var spread = 0;
      for (var i = 0; i < edges.length - 1; i++) {
        var width = wrapWidth(words, edges[i], edges[i + 1]);
        longest = Math.max(longest, width);
        spread += width * width;
      }
      if (!best || longest < best.longest || (longest === best.longest && spread < best.spread)) {
        best = { longest: longest, spread: spread, cuts: cuts };
      }
    }
    var a, b;
    if (lines === 2 || count < 3) {
      for (a = 1; a < count; a++) consider([a]);
    } else {
      for (a = 1; a < count - 1; a++) for (b = a + 1; b < count; b++) consider([a, b]);
    }
    if (!best) return words.join(' ');
    var all = [0].concat(best.cuts, [count]);
    var out = [];
    for (var i = 0; i < all.length - 1; i++) out.push(words.slice(all[i], all[i + 1]).join(' '));
    return out.join('\n');
  }

  // TV'de bölme karakter sayısına değil ekrandaki gerçek genişliğe göredir: Türkçe çoğu zaman İngilizceden uzun olduğu
  // için 42 karakter sınırı, ekranda bol yer varken tek satırlık cümleyi dar ve iki satırlık bir kutuya çeviriyordu.
  // Yazı altyazı alanına (ekranın %84'ü, iç boşluk düşülerek) tek satır sığıyorsa bölünmez; sığmıyorsa en az satıra
  // dengeli bölünür; 3 satıra da sığmazsa küçülür. Ölçüm yapılamazsa (canvas yok) eski karakter kuralı geçerlidir.
  var WRAP_WIDTH = 0.84;
  var measureContext = null;

  function lineWidths(el, text, size) {
    try {
      if (!measureContext) measureContext = document.createElement('canvas').getContext('2d');
      var style = window.getComputedStyle(el);
      measureContext.font = style.fontWeight + ' ' + size + 'px ' + style.fontFamily;
      var widest = 0;
      text.split('\n').forEach(function (line) { widest = Math.max(widest, measureContext.measureText(line).width); });
      return widest > 0 ? widest : null;
    } catch (e) {
      return null;
    }
  }

  // Örtü modunda çeviri İngilizce yazının biçimini alır. Örtü İngilizceyi kapatacak boyda kalmak zorunda; çeviri
  // ekran genişliğine göre bölününce iki satırlık İngilizcenin üstünde tek uzun satır kalıyor, örtü hem geniş hem
  // yüksek olup ortasında boşluklu, kalın bir siyah kutu çıkıyordu. Ekrana sığan her satır sayısı (1-3) için örtü ile
  // çevirinin birleşik kutusunun alanı hesaplanır, en küçüğü seçilir: iki satırlık İngilizcede çeviri de aynı
  // genişlikte iki satıra bölünür, tek satırlıkta (Türkçe biraz uzun da olsa) tek satır kalır. Bir satır daha ancak
  // kutuyu en az %20 küçültüyorsa eklenir: sığan çeviri yine gereksiz yere bölünmesin.
  var COVER_LINE_GAIN = 0.8;
  function wrapToCover(text, words, el, size, room, cover) {
    var style = window.getComputedStyle(el);
    var ratio = parseFloat(style.lineHeight) / parseFloat(style.fontSize) || 1.25;
    var best = null;
    for (var lines = 1; lines <= Math.min(WRAP_MAX_LINES, words.length); lines++) {
      var candidate = lines === 1 ? text : wrapBalance(words, lines);
      var width = lineWidths(el, candidate, size);
      if (!width || width > room) continue;
      // İç boşluk: yanlarda toplam bir yazı boyu, üstte ve altta 0.24em.
      var area = Math.max(cover.width, width + size) * Math.max(cover.height, size * (ratio * lines + 0.48));
      if (!best || area < best.area * COVER_LINE_GAIN) best = { text: candidate, area: area };
    }
    return best ? { text: best.text, scale: 1 } : null;
  }

  function coverSize(textId) {
    if (textId !== 'subtitle-text' || placement !== 'cover' || !currentBox) return null;
    var width = pageSize().width;
    var height = pageSize().height;
    var box = coverBounds(screenBox(currentBox, isOverlay()), isOverlay());
    return {
      width: bandShape ? width : (box.right - box.left) * width,
      height: (box.bottom - box.top) * height
    };
  }

  function wrapToWidth(text, el, size, cover) {
    var viewport = pageSize().width;
    // Yatay iç boşluk iki yanda 0.5em: toplam bir yazı boyu.
    var room = viewport * WRAP_WIDTH - size;
    var width = lineWidths(el, text, size);
    if (!width || room <= 0) return null;
    var words = wrapTokens(text);
    if (cover && words.length >= 2) {
      var shaped = wrapToCover(text, words, el, size, room, cover);
      if (shaped) return shaped;
    }
    if (width <= room) return { text: text, scale: 1 };
    if (words.length < 2) return { text: text, scale: 1 };
    var candidate = text;
    for (var lines = 2; lines <= WRAP_MAX_LINES; lines++) {
      candidate = wrapBalance(words, Math.min(lines, words.length));
      if (lines >= words.length) break;
      if ((lineWidths(el, candidate, size) || Infinity) <= room) return { text: candidate, scale: 1 };
    }
    var widest = lineWidths(el, candidate, size) || room;
    return { text: candidate, scale: Math.max(WRAP_MIN_SCALE, Math.min(1, room / widest)) };
  }

  // "Örtsün"de yazı boyu sabittir (Mac/Windows: CoverFontScale, OBS katmanı: coverWrap): her satır kullanıcının seçtiği
  // boyda, örtü çeviriye göre genişler. Yazı 3 satıra sığmıyorsa küçülmez: 3 dengeli satıra bölünür, tarayıcı daha uzun
  // satırı kendisi böler ve örtü onunla büyür. X'te bildirildi (beta.89, TV 0.9.84; "Örtsün" + "Yazı kadar"): eskiden
  // 3 satıra sığmayan tek bir satır yazıyı %80'e indiriyor, boy ayarı değişene dek öyle bırakıyordu; TV'de yazı boyu
  // satırdan satıra değişiyor, çeviri sıkışıyordu.

  // Sabit boyda 42 karakter kuralı (ölçüm yapılamayan tarayıcıda): satır başına 42 karakter, en çok 3 satır.
  function wrapAt(text) {
    var length = Array.from ? Array.from(text).length : text.length;
    if (length <= WRAP_MAX_CHARS || text.indexOf('\n') >= 0) return { text: text, scale: 1 };
    var words = wrapTokens(text);
    if (words.length < 2) return { text: text, scale: 1 };
    var lines = Math.min(WRAP_MAX_LINES, Math.max(2, Math.ceil(length / WRAP_MAX_CHARS)));
    return { text: wrapBalance(words, Math.min(lines, words.length)), scale: 1 };
  }

  // Örtü modunda satırın bölünmesi; yazı boyu çarpanı hep 1.
  function coverWrap(text, el, base, cover) {
    if (text.indexOf('\n') >= 0) return { text: text, scale: 1 };
    var words = wrapTokens(text);
    var viewport = pageSize().width;
    var room = viewport * WRAP_WIDTH - base;
    var width = lineWidths(el, text, base);
    if (!width || room <= 0) return wrapAt(text);
    if (words.length < 2) return { text: text, scale: 1 };
    var shaped = wrapToCover(text, words, el, base, room, cover);
    if (shaped) return shaped;
    // 3 satıra sığmadı: aynı boyda 3 dengeli satır, tarayıcı uzun satırı kendisi böler.
    return { text: wrapBalance(words, Math.min(WRAP_MAX_LINES, words.length)), scale: 1 };
  }

  function wrapSubtitle(text, el, size, cover) {
    if (text.indexOf('\n') >= 0) return { text: text, scale: 1 };
    var measured = el && size ? wrapToWidth(text, el, size, cover) : null;
    if (measured) return measured;
    var length = Array.from ? Array.from(text).length : text.length;
    if (length <= WRAP_MAX_CHARS) return { text: text, scale: 1 };
    var words = wrapTokens(text);
    if (words.length < 2) return { text: text, scale: 1 };
    var scale = Math.min(1, Math.max(WRAP_MIN_SCALE, WRAP_MAX_CHARS * WRAP_MAX_LINES / length));
    var cap = Math.floor(WRAP_MAX_CHARS / scale);
    var lines = Math.min(WRAP_MAX_LINES, Math.max(2, Math.ceil(length / cap)));
    return { text: wrapBalance(words, Math.min(lines, words.length)), scale: scale };
  }

  // Satırı yazar. Sayfadaki metin bölünmüş hâlidir; karşılaştırmalar için özgün metin elementte kalır.
  function setLineText(textId, text, paragraphs, baseSize, speakers) {
    var el = $(textId);
    // Konuşma satırı alt sınırın altına inmez (bilgisayardan gelen boy ne olursa olsun); bölme bu boyla ölçülür.
    if (!paragraphs) baseSize = Math.max(baseSize, dialogueMinFont());
    // Önceki satır için daraltılmış kutu (fitBox) yeni satır ölçülmeden önce bırakılır: yoksa yeni satır eski satırın dar
    // kutusunda ölçülüyor, fazladan satıra bölünmüş sayılıp yazı gereksiz yere küçülüyordu (0.9.42).
    el.style.width = '';
    // Sabit yazı boyu "Örtsün" ve "Yazı kadar" zeminde (Mac, Windows ve OBS katmanı ile aynı); bant eskisi gibi bölünür.
    var cover = paragraphs ? null : coverSize(textId);
    var stable = cover && !bandShape;
    var wrapped = paragraphs ? { text: text, scale: 1 } : stable ? coverWrap(text, el, baseSize, cover)
      : wrapSubtitle(text, el, baseSize, cover);
    el.rawText = text;
    el.speakers = speakers || null;
    el.textContent = wrapped.text;
    paintSpeakers(el, wrapped.text, el.speakers);
    el.style.whiteSpace = 'pre-line';
    // Konuşma altyazısı her zaman sayfanın olağan yazı tipinde ve genişliğinde (style.css; #1255).
    el.style.fontFamily = '';
    el.style.fontStretch = '';
    var size = Math.round(baseSize * wrapped.scale);
    el.style.fontSize = size + 'px';
    if (paragraphs) return fitBox(el);
    // Konuşma altyazısı hiçbir modda küçülmez ve sıkıştırılmaz (TV uygulaması 0.9.92): uzun satır bölünür, kutu büyür.
    // Önceden "Üstünde" ve bantta sığmayan satır %75'e, yükseklik sınırına göre daha da küçülüyordu.
    fitBox(el);
  }

  // Arka plan yalnız yazıyı kaplasın: tarayıcı bölünmüş bir satırı genişliğe sığdıramayıp kendisi yeniden kırınca
  // inline-block kutu en geniş hâline (max-width) açılıyor, yazı ortada dar kalıyor, iki yanda boş siyah alan oluşuyordu.
  // Kutu, yazının gerçek genişliğine (en uzun satır + iç boşluk) indirilir. Bantta kutu bilerek ekran genişliğindedir;
  // örtü (#subtitle-cover) ayrı bir kutudur, bundan etkilenmez. Ölçülemeyen (gizli) satırda ve Range'i olmayan
  // tarayıcıda kutu eskisi gibi kalır.
  function fitBox(el) {
    el.style.width = '';
    if (bandShape || !document.createRange) return;
    // Ölçüm eski TV tarayıcısında hata verirse kutu eskisi gibi (geniş) kalır; altyazının gösterilmesi bundan etkilenmez.
    try {
      var range = document.createRange();
      range.selectNodeContents(el);
      var rects = range.getClientRects ? range.getClientRects() : null;
      if (!rects || !rects.length) return;
      var scale = pageSize().scale;
      var left = Infinity;
      var right = -Infinity;
      for (var i = 0; i < rects.length; i++) {
        if (!(rects[i].width > 0)) continue;
        left = Math.min(left, rects[i].left / scale);
        right = Math.max(right, rects[i].right / scale);
      }
      if (!(right > left)) return;
      var style = window.getComputedStyle(el);
      var pad = (parseFloat(style.paddingLeft) || 0) + (parseFloat(style.paddingRight) || 0);
      var needed = Math.ceil(right - left + pad) + 1;
      if (pageRect(el.getBoundingClientRect(), scale).width - needed > 4) el.style.width = needed + 'px';
    } catch (e) {
      el.style.width = '';
    }
  }

  // Tarayıcı, bölünmüş satırlardan birini genişliğe sığdıramadığı için kendiliğinden satır açtı mı.
  function extraLines(el, lines) {
    var style = window.getComputedStyle(el);
    var line = parseFloat(style.lineHeight);
    if (!line) return false;
    var text = el.clientHeight - (parseFloat(style.paddingTop) || 0) - (parseFloat(style.paddingBottom) || 0);
    return text > line * lines + line / 2;
  }

  var SUBTITLE_MAX_HEIGHT = 0.24;
  var SUBTITLE_MIN_FONT = 16;

  function rawText(id) {
    var el = $(id);
    return el.rawText !== undefined ? el.rawText : el.textContent;
  }

  // paragraphs: görev paneli gibi başlık ve maddeli yazılar satır satır, sola yaslı gösterilir.
  // replaces: bilgisayar bu satırı öncekinin uzamış ya da düzelmiş okuması saydı (bkz. replacesCurrent).
  function showSubtitle(text, duration, box, paragraphs, replaces, speakers) {
    var now = Date.now();
    var current = rawText('subtitle-text');
    // Önceki satır kısa göründüyse yeni satırın üstünde kalır. Aynı cümlenin başka bir okunuşu (ya da yeniden gelen
    // satır) ikinci çeviri gibi durmasın diye üste çıkmaz; görev paneli gibi çok satırlı yazılar da üst üste binmez.
    if (replacesCurrent(replaces, paragraphs)) {
      // Üstteki daha eski satırlar olduğu gibi kalır.
    } else if (stackPrevious && $('subtitle').className !== 'hidden' && current && now - shownAt < STACK_WITHIN_MS &&
        !paragraphs && !shownParagraphs && !sameLine(current, text) && !withinLines(current, text)) {
      showPrevious(current, $('subtitle-text').speakers);
    } else if (!withinLines(current, text) || paragraphs) {
      hidePrevious();
    }
    // Aynı anda konuşan kişiler bilgisayarda tek satırda birleşir (her konuşan kendi satırında): üstte kalan önceki satır
    // yeni satırın içinde zaten varsa ikinci kez görünmez.
    dropRepeated(text);
    shownAt = now;
    shownParagraphs = !!paragraphs;
    holdUntil = shownAt + Math.min(HOLD_MAX_MS, 2000 + text.length * 60);
    currentBox = validBox(box);
    // Oyundaki altyazının yeri gelmezse son bilinen yer kullanılır (Mac, Windows ve OBS katmanı ile aynı): "Örtsün"de orası
    // örtülür, "Üstünde"/"Altında"da çeviri onun üstünde/altında kalır. Eskiden "Üstünde"de yeri gelmeyen satır sabit
    // yüksekliğe (alttan %7) iniyor, alttaki İngilizce satırın üstüne biniyordu (X, beta.89, TCL Android TV).
    if (!currentBox && placement !== 'fixed' && !paragraphs) currentBox = lastCoverBox;
    if (currentBox && !paragraphs) lastCoverBox = currentBox;
    setLineText('subtitle-text', text, paragraphs, fontBase, speakers);
    $('subtitle-text').style.textAlign = paragraphs ? 'left' : '';
    $('subtitle').className = '';
    layout();
    setStatus('st-last', text.length > 40 ? text.slice(0, 40) + '…' : text);
    notePlace();
    clearTimeout(hideTimer);
    // Geçersiz ya da çok kısa süre yazıyı gösterir göstermez kaldırmasın.
    var ms = duration > 0 ? Math.max(MIN_VISIBLE_MS, duration) : Math.min(8000, 2000 + text.length * 60);
    shownUntil = now + ms;
    hideTimer = setTimeout(function () { hideSubtitle('timer'); }, ms);
  }

  // Yazının ekrandaki gerçek yeri ve görünürlüğü (tanı için).
  function notePlace() {
    var el = $('subtitle-text');
    var rect = pageRect(el.getBoundingClientRect());
    var height = pageSize().height;
    diag.place = 'y ' + Math.round(rect.top) + '-' + Math.round(rect.bottom) + '/' + Math.round(height) + ' ' +
      window.getComputedStyle($('subtitle')).visibility + ' f' + window.getComputedStyle(el).fontSize +
      // "Örtsün": örtünün zemini ve önceki satırların örtü yüzünden kaydığı pay (TV kullanıcı günlüğünde doğrulansın diye).
      (placement === 'cover' ? ' cov ' + ($('subtitle-cover').className === 'hidden' ? 'none' : 'on') +
        (parseFloat(el.style.marginTop) > 0 ? ' lift ' + Math.round(parseFloat(el.style.marginTop)) : '') : '');
    renderDiag();
  }

  // reason: yazıyı neyin kaldırdığı; panelde görünen süreyle birlikte sebebi gösterir.
  function hideSubtitle(reason) {
    clearTimeout(hideTimer);
    if ($('subtitle').className !== 'hidden') {
      diag.lastHide = (reason || '?') + ' ' + (Date.now() - shownAt) + 'ms';
      renderDiag();
    }
    $('subtitle').className = 'hidden';
    $('subtitle-cover').className = 'hidden';
    hidePrevious();
    // Altyazıdan kaçmak için kayan görev/ekran yazısı kutusu altyazı kalkınca kendi yerine döner. Eskiden kayık kalıyordu:
    // görevin Türkçesi bir sonraki altyazıya dek yerinden oynamış duruyor, altındaki İngilizce görev açıkta kalıyordu
    // (GTA 6, "Search near the turbine").
    avoidRegions();
  }

  // Bilgisayardan gelen "temizle": yazı okunacak kadar görünmediyse kalan süre dolunca kaldırılır.
  function onClear() {
    diag.clears++;
    renderDiag();
    var left = holdUntil - Date.now();
    if (left <= 0 || $('subtitle').className === 'hidden') return hideSubtitle('clear');
    clearTimeout(hideTimer);
    hideTimer = setTimeout(function () { hideSubtitle('clear-held'); }, left);
  }

  // Bilgisayar, daktilo efektinde büyüyen ya da belirirken yarım okunan cümlenin her okunuşunu ayrı çevirir; bunlar
  // üst üste yığılınca aynı cümlenin iki üç çevirisi görünüyordu. "replace" ile gelen satır öncekinin yerine geçer.
  function replacesCurrent(replaces, paragraphs) {
    return replaces === true && !paragraphs && $('subtitle').className !== 'hidden' && !!$('subtitle-text').textContent;
  }

  // Önceki satır üste çıkar. Orada hâlâ görünen bir satır varsa o da bir üst sıraya (iki önceki) kayar; en çok üç satır.
  function showPrevious(text, speakers) {
    var older = $('subtitle-prev');
    var olderText = rawText('subtitle-prev-text');
    if (older.className === '' && olderText && !sameLine(olderText, text)) {
      showSlot('subtitle-prev2', olderText, $('subtitle-prev-text').speakers);
    } else {
      hideSlot('subtitle-prev2');
    }
    showSlot('subtitle-prev', text, speakers);
  }

  function showSlot(id, text, speakers) {
    var timers = previousTimers[id];
    clearTimeout(timers[0]);
    clearTimeout(timers[1]);
    setLineText(id + '-text', text, false, Math.round(fontBase * 0.8), speakers);
    $(id).className = '';
    fitBox($(id + '-text'));
    timers[0] = setTimeout(function () {
      $(id).className = 'fading';
      timers[1] = setTimeout(function () { hideSlot(id); }, PREVIOUS_FADE_MS);
    }, PREVIOUS_HOLD_MS);
  }

  function hideSlot(id) {
    var timers = previousTimers[id];
    clearTimeout(timers[0]);
    clearTimeout(timers[1]);
    if ($(id).className === 'hidden') return;
    $(id).className = 'hidden';
    // Önceki satır kalkınca ondan kaçan görev/ekran yazısı kutusu yerine yaklaşır.
    avoidRegions();
  }

  function hidePrevious() {
    hideSlot('subtitle-prev');
    hideSlot('subtitle-prev2');
  }

  // a'nın her satırı b'nin satırlarından biriyle aynı mı (sameLine): b, a'yı da içeren çok konuşanlı satır.
  function withinLines(a, b) {
    if (!a || !b || String(b).indexOf('\n') < 0) return false;
    var mine = String(a).split('\n');
    var theirs = String(b).split('\n');
    for (var i = 0; i < mine.length; i++) {
      if (!plainText(mine[i])) continue;
      var found = false;
      for (var j = 0; j < theirs.length && !found; j++) found = sameLine(mine[i], theirs[j]);
      if (!found) return false;
    }
    return true;
  }

  function dropRepeated(text) {
    var ids = ['subtitle-prev', 'subtitle-prev2'];
    for (var i = 0; i < ids.length; i++) {
      if ($(ids[i]).className !== 'hidden' && withinLines(rawText(ids[i] + '-text'), text)) hideSlot(ids[i]);
    }
  }

  // Büyük-küçük harf ve noktalama dışında aynı mı, ya da biri ötekinin başı/devamı mı ("Kapı" → "Kapı daha fazla…").
  function sameLine(a, b) {
    var x = plainText(a);
    var y = plainText(b);
    if (!x || !y) return x === y;
    // Boşluklar karşılaştırmaya girmez (OCR boşluğu bazen yutar ya da fazladan koyar). Tek sözcüklük satır ise
    // ancak öteki satırda tam sözcük olarak geçerse aynıdır: "No!" ve "Not now!" farklı altyazılardır.
    var cx = x.replace(/ /g, '');
    var cy = y.replace(/ /g, '');
    if (cx === cy) return true;
    if (cx.indexOf(cy) >= 0) return y.indexOf(' ') >= 0 || (' ' + x + ' ').indexOf(' ' + y + ' ') >= 0;
    if (cy.indexOf(cx) >= 0) return x.indexOf(' ') >= 0 || (' ' + y + ' ').indexOf(' ' + x + ' ') >= 0;
    return false;
  }

  function plainText(text) {
    return String(text).toLowerCase().replace(/[.,!?;:…"'“”‘’«»()\[\]\-–—]+/g, '').replace(/\s+/g, ' ').trim();
  }

  // --- Ekranı çevir ---
  // Bilgisayar ekranın tamamını okuyup her yazı grubunun çevirisini yeriyle gönderir. Her çeviri kendi İngilizce
  // yazısını örter; yazı boyu o yazının satır yüksekliğinden seçilir, Türkçe uzun gelirse sığana kadar küçülür.

  var screenTimer = null;
  var SCREEN_PAD = 0.004;
  var SCREEN_MIN_FONT = 14;

  // Çeviri kutusu ekranın yarısından büyükse çizilmez: böyle bir kutu oyunun üstünü koyu zeminle kaplar, ekran "siyah"
  // görünür. Gerçek yazı kutuları (altyazı, görev, telefon, menü) bundan çok küçüktür; bu boy ancak hatalı okumadan gelir.
  var BIG_BOX_AREA = 0.5;

  function tooBig(box) {
    if ((box.right - box.left) * (box.bottom - box.top) <= BIG_BOX_AREA) return false;
    diag.big++;
    return true;
  }

  function phoneColor(value) {
    return typeof value === 'string' && value.length === 7 && /^#[0-9a-f]{6}$/i.test(value);
  }

  // Otomatik bulunan ekran yazısı (bilgisayar "auto-<n>" alanı) özgün yazının görünüşüyle gelir: surface {background,
  // foreground, flat} zemin ve yazı rengi, style {bold, condensed, align, upper}. Zemin her yüzeyde (harita, oyun dünyası
  // da) tam opaktır: önceden düz olmayan zeminde %94 opaktı, altındaki İngilizce harfler ("uture", "KM") seçiliyordu (#827). Büyük harf çeviriyi bilgisayar zaten büyütür. Alanları göndermeyen eski bilgisayarda
  // kutu eskisi gibi siyah kalır.
  var STYLED_MIN_SCALE = 0.8;
  var STYLED_LABEL_MIN_SCALE = 0.6;
  // GTA 6 telefonunun mesajı kendi balonunun üstünde ("bubble"): Türkçe balona sığana kadar satır kırılır ve yazı en çok
  // %25 küçülür; okunabilirlik sınırı 1080p'de 22 piksel (önceden %35 ve 18 pikseldi, yazı çok küçük kalıyordu). Yine sığmazsa balon aşağı doğru uzar (yazı kesilmez).
  var BUBBLE_MIN_SCALE = 0.75;
  var BUBBLE_MIN_FONT = 22;
  // Gömülü dar yazı tipi önce (style.css @font-face, Barlow Condensed, OFL; TV uygulaması 0.9.109): oyunun dar-kalın BÜYÜK
  // HARF yazısına en yakın açık lisanslı aile; menü ve kutu çiziminde. Yüklenemezse sistemin dar ailesi.
  var EMBEDDED_CONDENSED = '"CouchSubs Condensed"';
  var CONDENSED_FONT = EMBEDDED_CONDENSED + ', "Roboto Condensed", "Arial Narrow", "Helvetica Neue Condensed", "LG Smart UI Condensed", sans-serif';

  // Konuşma satırı dar yazı tipi almaz ve yatayda sıkışmaz (TV uygulaması 0.9.103; #1224, #1255, #1259). Oyunun altyazısı
  // ekran yazısı olarak da okunabiliyor (menü durumunda altyazı alanı dışlanmaz): "Ne?", "Yoldan çık." gibi kısa replik
  // etiket sayılıp dar aileyle ve %10 sıkışarak çiziliyordu. Konuşma satırı: konuşan adıyla başlar ("Lucia: Evet.") ya da
  // küçük harf taşıyan tek satır olup cümle sonu noktalamasıyla biter. Menü sekmesi, düğme ve başlık böyle bitmez; çok
  // satırlı görev/bilgi metni özgün görünüşünde kalır. Bilgisayardaki kural: ScreenFit.isDialogue (Mac, iPhone),
  // ScreenFit.IsDialogue (Windows), ScreenFit.isDialogue (Android).
  var SPEAKER_PREFIX = /^[A-ZÇĞİÖŞÜ][^:：\n]{0,30}[:：]\s+\S/;
  var SPOKEN_END = /[.!?…]["'”’»)\]]*$/;
  // Konuşma satırının en küçük yazı boyu: sayfa yüksekliğinin %2,2'si (1080'de 24, 720'de 16 CSS pikseli; TV uygulaması
  // 0.9.107, #1255, #1259). Konuşma satırı hiçbir TV'de ve hiçbir yolda (altyazı, ekran yazısı olarak okunan replik) bunun
  // altına küçülmez, yatayda sıkışmaz, dar aile almaz: sığmazsa satır kırılır, kutu büyür.
  var DIALOGUE_MIN_SHARE = 0.022;

  function dialogueMinFont(height) {
    var page = height || pageSize().height;
    return Math.max(12, Math.round(page * DIALOGUE_MIN_SHARE));
  }

  // Boy ve genişlik kuralları (alt sınır, iki yana genişleme) yalnız kesin konuşma satırında: konuşan adıyla başlayan ya
  // da en çok beş sözcüklük replik. Görev/hedef cümlesi de küçük harfli ve noktalı olabilir; o özgün kutusunda kalır.
  var SPOKEN_MAX_WORDS = 5;
  function isSpoken(text, rows) {
    if (!isDialogue(text, rows)) return false;
    var line = String(text || '').replace(/^\s+|\s+$/g, '');
    return SPEAKER_PREFIX.test(line) || line.split(/\s+/).length <= SPOKEN_MAX_WORDS;
  }

  function rowsOf(item) {
    return item && item.paragraphs === true ? 2 : item && item.rows;
  }

  function isDialogue(text, rows) {
    var line = String(text || '').replace(/^\s+|\s+$/g, '');
    if (!line) return false;
    if (SPEAKER_PREFIX.test(line)) return true;
    return !(rows > 1) && line.indexOf('\n') < 0 && SPOKEN_END.test(line) && line !== line.toUpperCase();
  }

  // Android TV'de dar aile hiç istenmez: sayfanın WebView'ı Roboto'yu sistemin değişken yazı tipinden alır; dar genişlikle
  // bir kez çizilen Roboto aynı sayfadaki konuşma altyazısına da dar geçiyordu (TCL ve Beko Android TV, Katman; altyazı
  // kutusu İngilizceden dar, harfler yatayda üst üste). Ekran yazısı orada olağan genişlikte çizilir; yerleşim yazıyı
  // ölçtüğü için sığmayan çeviri yine küçülür ya da satır kırılır.
  function condensedLook(item) {
    return !!(item && item.style && item.style.condensed === true) && !window.AndroidTV &&
      !isDialogue(item.text, item.paragraphs === true ? 2 : item.rows);
  }

  // Öğeye özgün yazının görünüşü uygulandı mı.
  function applyLook(el, item) {
    var surface = item.surface;
    if (!surface || !phoneColor(surface.background) || !phoneColor(surface.foreground)) return false;
    el.style.backgroundColor = surface.background;
    el.style.color = surface.foreground;
    el.style.textShadow = 'none';
    var style = item.style;
    if (style && typeof style === 'object') {
      if (style.bold === true) el.style.fontWeight = '700';
      else if (style.bold === false) el.style.fontWeight = '400';
      if (condensedLook(item)) {
        el.style.fontFamily = CONDENSED_FONT;
        el.style.fontStretch = 'condensed';
      }
      if (style.align === 'left' || style.align === 'center' || style.align === 'right') el.style.textAlign = style.align;
    }
    return true;
  }

  // Yalnız aşağıdaki bağımsız kutular büyümeyi sınırlar; kaynakta zaten üst üste olan
  // kutuların yerini değiştirmeyiz. Aynı hesap bütün sonuçlar için yapılır, sıra önemli değildir.
  function screenBottom(items, box, left, width, screenWidth, screenHeight, pad, minWidth) {
    var bottom = screenHeight;
    for (var j = 0; j < items.length; j++) {
      var other = items[j];
      var next = validBox(other && other.box);
      if (!next || !other.text || next.top < box.bottom) continue;
      var nextLeft = Math.max(0, next.left - pad) * screenWidth;
      var nextWidth = Math.max(minWidth, (Math.min(1, next.right + pad) * screenWidth - nextLeft));
      if (left < nextLeft + nextWidth && left + width > nextLeft)
        bottom = Math.min(bottom, Math.max(0, next.top - pad) * screenHeight);
    }
    return bottom;
  }

  // GTA 6 telefonunun yanındaki sohbet paneli (TV uygulaması 0.9.75; bilgisayar öğelere "panel" alanını ekler: card, title,
  // theirs, mine, note). Panel yuvarlak köşeli, yarı saydam koyu kartta akışla çizilir: üstte kişinin adı, altında
  // mesajlar sırayla (karşı taraf solda krem, oyuncu sağda amber balon, not ortada); sığmayan en eski mesajlar düşer,
  // son mesajlar görünür kalır. Sağ altta sade kanepe simgesi. Mac, Windows, iPhone ve Android aynı çizimi yapar.
  // Alanı göndermeyen eski bilgisayarda öğeler eskisi gibi yerinde çizilir.
  var PANEL_PARTS = { title: true, theirs: true, mine: true, note: true, row: true };
  var PANEL_OPACITY = 0.88;
  var PANEL_COUCH = [[3, 1, 18, 8, 2.5], [0, 5, 5, 8, 2], [19, 5, 5, 8, 2], [4, 8, 16, 5, 1.5], [2, 13, 2, 3, 0.8], [20, 13, 2, 3, 0.8]];

  // Sohbet listesinin satırı: sola yaslı not (bilgisayar `style.align` gönderir). Bölüm başlığının soluk yazı rengi.
  var PANEL_NOTE_INK = '#A9A59C';
  function panelListRow(item) {
    return !!item && item.panel === 'note' && !!item.style && typeof item.style === 'object' && item.style.align === 'left';
  }

  function panelCard(items) {
    for (var i = 0; i < (items || []).length; i++) {
      if (items[i] && items[i].panel === 'card' && validBox(items[i].box)) return items[i];
    }
    return null;
  }

  function translucent(hex, alpha) {
    var value = parseInt(hex.slice(1), 16);
    return 'rgba(' + ((value >> 16) & 255) + ',' + ((value >> 8) & 255) + ',' + (value & 255) + ',' + alpha + ')';
  }

  function couchIcon() {
    var ns = 'http://www.w3.org/2000/svg';
    var svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', '0 0 24 16');
    svg.setAttribute('class', 'panel-couch');
    for (var i = 0; i < PANEL_COUCH.length; i++) {
      var part = PANEL_COUCH[i];
      var rect = document.createElementNS(ns, 'rect');
      rect.setAttribute('x', part[0]);
      rect.setAttribute('y', part[1]);
      rect.setAttribute('width', part[2]);
      rect.setAttribute('height', part[3]);
      rect.setAttribute('rx', part[4]);
      svg.appendChild(rect);
    }
    return svg;
  }

  // Panel ve mesajları yerinde güncellenir (TV uygulaması 0.9.78; X, 22 Kas: "yazılar sürekli oynuyor"): aynı mesajın satırı
  // (anahtarı: parçası, yazısı, aynı yazının kaçıncı tekrarı) yeniden yaratılmaz, yeni mesaj alta eklenir, düşen mesaj
  // kalkar. Panel gerçekten yer değiştirince CSS geçişiyle bir kerede kayar.
  function placePanel(host, items, card, width, height, panel) {
    var box = validBox(card.box);
    if (!panel) {
      panel = document.createElement('div');
      panel.className = 'phone-panel';
    }
    panel.couchsubsBox = box;
    panel.style.left = (box.left * 100) + '%';
    panel.style.top = (box.top * 100) + '%';
    panel.style.width = Math.round((box.right - box.left) * width) + 'px';
    panel.style.height = Math.round((box.bottom - box.top) * height) + 'px';
    var line = typeof card.line === 'number' && card.line > 0 ? card.line * height : 0.022 * height;
    panel.style.fontSize = Math.max(Math.round(BUBBLE_MIN_FONT * height / 1080), Math.round(line * 0.95)) + 'px';
    panel.style.borderRadius = Math.max(6, Math.round(18 * height / 1080)) + 'px';
    var surface = card.surface;
    var custom = surface && phoneColor(surface.background) && phoneColor(surface.foreground);
    panel.style.backgroundColor = custom ? translucent(surface.background, PANEL_OPACITY) : '';
    panel.style.color = custom ? surface.foreground : '';
    var title = null, messages = [];
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      if (!item || typeof item.text !== 'string' || !item.text || !PANEL_PARTS[item.panel]) continue;
      if (item.panel === 'title') title = item;
      else messages.push(item);
    }
    messages.sort(function (a, b) { return ((validBox(a.box) || {}).top || 0) - ((validBox(b.box) || {}).top || 0); });
    // Bilgisayar paneli hizalı gönderdiyse (card.aligned) parçalar kutularının yerinde çizilir; akışla hizalı çizim arasında
    // geçişte panelin içi baştan kurulur.
    var aligned = card.aligned === true;
    if (!!panel.couchsubsAligned !== aligned) {
      while (panel.firstChild) panel.removeChild(panel.firstChild);
      panel.couchsubsAligned = aligned;
    }
    panel.className = aligned ? 'phone-panel aligned' : 'phone-panel';
    if (aligned) return placeAlignedPanel(host, panel, box, title, messages, width, height, line);
    var name = null, list = null, couch = null;
    for (var c = 0; c < panel.children.length; c++) {
      var child = panel.children[c];
      var kind = child.getAttribute('class') || '';
      if (kind === 'panel-title') name = child;
      else if (kind === 'panel-messages') list = child;
      else if (kind === 'panel-couch') couch = child;
    }
    if (title) {
      if (!name) {
        name = document.createElement('div');
        name.className = 'panel-title';
      }
      if (name.textContent !== title.text) name.textContent = title.text;
      if (panel.firstChild !== name) panel.insertBefore(name, panel.firstChild);
    } else if (name) panel.removeChild(name);
    if (!list) {
      list = document.createElement('div');
      list.className = 'panel-messages';
      panel.appendChild(list);
    }
    var old = {};
    for (var r = 0; r < list.children.length; r++) {
      var key = list.children[r].couchsubsKey;
      if (key) (old[key] = old[key] || []).push(list.children[r]);
    }
    var seen = {}, rows = [], previous = null;
    for (var j = 0; j < messages.length; j++) {
      var message = messages[j];
      // Sohbet listesinin satırı (TV uygulaması 0.9.101; LG, beta.93): sola yaslı not; kişi adı ve bölüm başlığı kalın,
      // önizleme adın hemen altında (Mac, Windows, iPhone ve Android PhonePanelView ile aynı). Eski TV ortalı not çizer.
      var listed = panelListRow(message);
      var strong = listed && message.style.bold === true;
      var tight = listed && !strong && previous && panelListRow(previous) && previous.style.bold === true &&
        !(previous.surface && String(previous.surface.foreground).toUpperCase() === PANEL_NOTE_INK);
      var base = message.panel + (listed ? (strong ? '+list+strong' : '+list') : '') + '|' + message.text;
      seen[base] = (seen[base] || 0) + 1;
      var rowKey = base + '#' + seen[base];
      var colors = message.surface;
      var paint = colors && phoneColor(colors.background) && phoneColor(colors.foreground)
        ? (message.panel !== 'note' ? colors.background : '') + '/' + colors.foreground : '';
      var row = old[rowKey] && old[rowKey].shift();
      var bubble;
      var rowClass = 'panel-row ' + message.panel + (listed ? ' list' : '') + (strong ? ' strong' : '') + (tight ? ' tight' : '');
      previous = message;
      if (row && row.couchsubsPaint === paint) {
        bubble = row.firstChild;
        // Üstündeki satır değişince yalnız aralık sınıfı güncellenir; satır yeniden yaratılmaz.
        if (row.className !== rowClass) row.className = rowClass;
      } else {
        row = document.createElement('div');
        row.className = rowClass;
        bubble = document.createElement('div');
        bubble.className = 'panel-bubble';
        fillText(bubble, message.text, message.icons);
        if (paint) {
          if (message.panel !== 'note') bubble.style.backgroundColor = colors.background;
          bubble.style.color = colors.foreground;
        }
        row.appendChild(bubble);
        row.couchsubsKey = rowKey;
        row.couchsubsPaint = paint;
      }
      rows.push(row);
    }
    // Sıra yalnız değiştiyse taşınır; yerinde kalan satıra dokunulmaz.
    for (var k = 0; k < rows.length; k++) {
      if (list.children[k] !== rows[k]) list.insertBefore(rows[k], list.children[k] || null);
    }
    while (list.children.length > rows.length) list.removeChild(list.lastChild);
    if (!couch) couch = couchIcon();
    if (couch.parentNode !== panel || panel.lastChild !== couch) panel.appendChild(couch);
    if (panel.parentNode !== host) host.appendChild(panel);
    // Sığmayan en eski mesajlar düşer: son mesajlar görünür kalır.
    while (list.children.length > 1 && list.scrollHeight > list.clientHeight + 1) list.removeChild(list.firstChild);
    return panel;
  }

  // Hizalı panel (TV uygulaması 0.9.106; Sinan Bey'in beğendiği görünüm): zemin kartı ve kanepe simgesi yok; her Türkçe
  // balon bilgisayarın gönderdiği kutuda, telefondaki İngilizce balonuyla aynı yükseklikte, oyunun üstünde doğrudan
  // çizilir (telefonun balon renginde, %85 örtülü; gelen sola, giden sağa yaslı). Kişi adı üstte küçük başlık, not ve liste
  // satırları koyu yarı saydam zeminde. Satırlar anahtarla yeniden kullanılır (yazısı ve rengi aynı satır yeniden
  // yaratılmaz); yeri değişen satır kısa CSS geçişiyle kayar. Gerçek yazı bilgisayarın tahmininden uzun çıkarsa alttaki
  // satırlar en az kaydırmayla (bilgisayarın bıraktığı aralık korunarak) aşağı itilir, panel aşağı uzar; yazı küçülmez.
  // Mac, Windows, iPhone ve Android (PhonePanelAligned, PhoneBlocksCanvas, PhonePanel) aynı kutuları çizer.
  var PANEL_BUBBLE_OPACITY = 0.85;
  // Panel gelirken ve telefon kalkınca kaybolurken solma süresi (ms; style.css phone-panel-in, .leaving ile aynı).
  var PANEL_FADE_MS = 250;

  // Telefon listesinin tek kartı (TV uygulaması 0.9.110; Sinan Bey, beta.100 3399): ad ve önizleme ayrı haplar
  // dağınıktı. Her satır telefondaki satırın Türkçe kopyası: telefonun satır kartı renginde yuvarlak köşeli kart, solda
  // oyundan kesilmiş avatar (okunmamış kırmızı nokta resmin içinde), kalın ad ve altında önizleme, sağ üstte rozet,
  // seçili satırda telefondaki renkte çerçeve. Ana ekran bileşeni ("Hatırlatıcılar / 6 Bildirim") aynı kart. Ölçüler
  // satır yüksekliğine oranla (ScreenPhoneCard.avatarLines 2,2, avatarGap 0,5, rowPadding 0,45); Mac, Windows, iPhone ve
  // Android (PhoneListCard, PhoneBlocksCanvas, PhonePanel) aynı kartı çizer. Eski TV kartı tanımaz, `text`'i (ad ve
  // önizleme iki satır) yerinde çizer.
  function listImage(src) {
    return typeof src === 'string' && src.indexOf('data:image/png;base64,') === 0 && src.length < 200000 ? src : '';
  }

  function listCardKey(card) {
    return [card.name || '', card.preview || '', listImage(card.avatar), listImage(card.badge),
      phoneColor(card.selected) ? card.selected : '', card.widget === true ? 'w' : ''].join('\u001f');
  }

  function listCard(card, colors, line) {
    var el = document.createElement('div');
    el.className = 'panel-card' + (card.widget === true ? ' widget' : '');
    if (colors && phoneColor(colors.background)) el.style.backgroundColor = translucent(colors.background, PANEL_BUBBLE_OPACITY);
    if (colors && phoneColor(colors.foreground)) el.style.color = colors.foreground;
    if (phoneColor(card.selected)) {
      el.style.boxShadow = 'inset 0 0 0 ' + Math.max(2, Math.round(line * 0.12)) + 'px ' + card.selected;
    }
    var avatar = listImage(card.avatar);
    if (avatar) {
      var face = document.createElement('img');
      face.className = 'panel-avatar';
      face.src = avatar;
      el.appendChild(face);
    } else el.className += ' bare';
    var badge = listImage(card.badge);
    if (badge) {
      var mark = document.createElement('img');
      mark.className = 'panel-badge';
      mark.src = badge;
      el.appendChild(mark);
      el.className += ' badged';
    }
    var text = document.createElement('div');
    text.className = 'panel-card-text';
    if (typeof card.name === 'string' && card.name) {
      var name = document.createElement('div');
      name.className = 'panel-card-name';
      name.textContent = card.name;
      text.appendChild(name);
    }
    if (typeof card.preview === 'string' && card.preview) {
      var preview = document.createElement('div');
      preview.className = 'panel-card-preview';
      preview.textContent = card.preview;
      text.appendChild(preview);
    }
    el.appendChild(text);
    return el;
  }

  function placeAlignedPanel(host, panel, box, title, messages, width, height, line) {
    panel.style.backgroundColor = 'transparent';
    // Yazı boyu tam piksele yuvarlanmaz: 720p, 1080p ve 4K'da ekrana oranı (ve satır kırılımı) aynı kalır.
    panel.style.fontSize = Math.max(BUBBLE_MIN_FONT * height / 1080, line * 0.95).toFixed(2) + 'px';
    var parts = title ? [title].concat(messages) : messages;
    var old = {};
    for (var r = 0; r < panel.children.length; r++) {
      var key = panel.children[r].couchsubsKey;
      if (key) (old[key] = old[key] || []).push(panel.children[r]);
    }
    var seen = {}, rows = [], previous = null;
    for (var j = 0; j < parts.length; j++) {
      var item = parts[j];
      var at = validBox(item.box);
      if (!at) continue;
      var part = item === title ? 'title' : item.panel;
      var listed = panelListRow(item);
      var strong = listed && item.style.bold === true;
      var base = part + (listed ? (strong ? '+list+strong' : '+list') : '') + '|' + item.text;
      seen[base] = (seen[base] || 0) + 1;
      var rowKey = base + '#' + seen[base];
      var colors = item.surface;
      var paint = colors && phoneColor(colors.background) && phoneColor(colors.foreground)
        ? colors.background + '/' + colors.foreground : '';
      // Liste kartı (TV uygulaması 0.9.110): avatar, ad, önizleme, rozet ve seçim çerçevesi kartın görünüşüdür.
      var listing = part === 'row' && item.row && typeof item.row === 'object' ? item.row : null;
      if (listing) paint += '|' + listCardKey(listing);
      var row = old[rowKey] && old[rowKey].shift();
      var rowClass = 'panel-row ' + part + (listed ? ' list' : '') + (strong ? ' strong' : '');
      if (!row || row.couchsubsPaint !== paint) {
        row = document.createElement('div');
        if (listing) {
          row.appendChild(listCard(listing, colors, line));
        } else {
          var bubble = document.createElement('div');
          bubble.className = 'panel-bubble';
          fillText(bubble, item.text, item.icons);
          if (paint) {
            bubble.style.backgroundColor = translucent(colors.background, PANEL_BUBBLE_OPACITY);
            bubble.style.color = colors.foreground;
          }
          row.appendChild(bubble);
        }
        row.couchsubsKey = rowKey;
        row.couchsubsPaint = paint;
      }
      if (row.className !== rowClass) row.className = rowClass;
      var left = Math.round((at.left - box.left) * width), top = Math.round((at.top - box.top) * height);
      var rowWidth = Math.max(1, Math.round((at.right - at.left) * width));
      // Kart en az telefondaki satır boyunda (bilgisayarın kutusu); Türkçe uzunsa kart uzar, alttakiler itilir.
      if (listing) {
        var least = Math.max(1, Math.round((at.bottom - at.top) * height)) + 'px';
        if (row.firstChild.style.minHeight !== least) row.firstChild.style.minHeight = least;
      }
      if (row.style.left !== left + 'px') row.style.left = left + 'px';
      if (row.style.width !== rowWidth + 'px') row.style.width = rowWidth + 'px';
      // Çakışmada korunacak aralık: bilgisayarın bıraktığı (üstteki satırın tahmini altından bu satırın üstüne), en çok
      // balonlar arası olağan boşluk (satırın 0,6'sı; ScreenPhoneCard.bubbleSpacing).
      var gap = previous ? Math.max(0, Math.min(top - previous.planned, Math.round(line * 0.6))) : 0;
      rows.push({ row: row, top: top, gap: gap });
      previous = { planned: Math.round((at.bottom - box.top) * height) };
    }
    // Sıra yalnız değiştiyse taşınır; yerinde kalan satıra dokunulmaz. Panelde artık olmayan satırlar kalkar.
    for (var k = 0; k < rows.length; k++) {
      if (panel.children[k] !== rows[k].row) panel.insertBefore(rows[k].row, panel.children[k] || null);
    }
    while (panel.children.length > rows.length) panel.removeChild(panel.lastChild);
    if (panel.parentNode !== host) host.appendChild(panel);
    // Gerçek yükseklikle çakışma denetimi: satır ancak üsttekinin gerçek altına (aralıkla) binerse, en az kaydırmayla itilir.
    var bottom = 0;
    for (var m = 0; m < rows.length; m++) {
      var place = m === 0 ? rows[m].top : Math.max(rows[m].top, bottom + rows[m].gap);
      if (rows[m].row.style.top !== place + 'px') rows[m].row.style.top = place + 'px';
      bottom = place + rows[m].row.offsetHeight;
    }
    var cardHeight = Math.round((box.bottom - box.top) * height);
    panel.style.height = Math.max(cardHeight, bottom) + 'px';
    return panel;
  }

  // Yeriyle gelen çevirileri (ekranı çevir öğeleri, ek alan blokları) kendi İngilizce yazılarının üstüne koyar.
  // Oyun telefonunun öğeleri yerinde güncellenir (TV uygulaması 0.9.78): aynı yazının kutusu (anahtarı: yazısı ve kaçıncı
  // tekrarı) yeniden yaratılmaz; yeri değişirse CSS geçişiyle kayar, kalkan yazının kutusu kaldırılır.
  function takeChildren(host) {
    var taken = { panel: null, items: {}, all: [] };
    for (var i = 0; i < host.children.length; i++) {
      var child = host.children[i];
      taken.all.push(child);
      if (child.className === 'phone-panel' || child.className === 'phone-panel aligned') taken.panel = child;
      else if (child.couchsubsKey) (taken.items[child.couchsubsKey] = taken.items[child.couchsubsKey] || []).push(child);
    }
    return taken;
  }

  function placeItems(host, items, regionId) {
    var phone = regionId === 'game-phone';
    var width = pageSize(true).width;
    var height = pageSize(true).height;
    var pad = phone ? 0.001 : SCREEN_PAD;
    var minWidth = phone ? 1 : 80;
    var card = panelCard(items);
    var reuse = phone ? takeChildren(host) : null;
    var kept = [], seen = {}, order = 0, exact = [];
    if (card) {
      var panel = placePanel(host, items, card, width, height, reuse && reuse.panel);
      kept.push(panel);
      if (host.children[order] !== panel) host.insertBefore(panel, host.children[order] || null);
      order++;
    }
    for (var i = 0; i < (items || []).length; i++) {
      var item = items[i];
      if (card && item && (item.panel === 'card' || PANEL_PARTS[item.panel])) continue;
      var box = validBox(item && item.box);
      if (!box || !item.text || tooBig(box)) continue;
      // Bilgisayar özgün görünüşü ölçüp gönderdiyse yerinde birebir çizim (placeExact); telefon ve balon eski yolda.
      // Ekran yazısı olarak okunan konuşma satırı birebir yolda küçülebiliyordu (tek sözcük kutuya sığana kadar); o
      // fitStyled'da çizilir: sıkışmaz, alt sınırın altına inmez (#1255).
      // İkiz balonun yazısı (bildirim mesajı kısa replik gibi bitse de) balonda kalır; boyu göndericide alt sınırda.
      if (!phone && setApart && item.bubble !== true && isExact(item) &&
          (exactMode(item) === 'twin' || !isSpoken(item.text, item.rows))) {
        exact.push(item);
        continue;
      }
      var el = null;
      if (reuse) {
        seen[item.text] = (seen[item.text] || 0) + 1;
        var key = item.text + '#' + seen[item.text];
        el = reuse.items[key] && reuse.items[key].shift();
        if (el) {
          // Stil baştan yazılır; yer değeri değişirse geçiş eski yerden başlar.
          el.removeAttribute('style');
          el.textContent = '';
        }
      }
      if (!el) el = document.createElement('div');
      if (reuse) el.couchsubsKey = key;
      el.className = item.paragraphs === true ? 'item paragraphs' : 'item';
      // Özgün yazının yeri: aynı yeri çizen başka katmanın kutusuyla karşılaştırılır (resolveLayers).
      el.couchsubsBox = box;
      var styled = false;
      if (phone) {
        el.className += ' phone';
        var surface = item.surface;
        if (surface && phoneColor(surface.background) && phoneColor(surface.foreground)) {
          el.style.backgroundColor = surface.background;
          el.style.color = surface.foreground;
        }
      } else if (setApart && (regionId ? (regionId.indexOf('auto-') === 0 || (item.style && typeof item.style === 'object'))
        : (item.style && typeof item.style === 'object'))) {
        // Yalnız özgün görünüşü taşıyan bloklar: elle tanımlanmış ek alanların kutusu eskisi gibi siyah kalır.
        // "Ekranı çevir" öğeleri de artık özgün görünüşüyle gelir (eski bilgisayar göndermez): otomatik ekran yazısı gibi
        // çizilir; GTA 6 telefon kartının zemini ve balonları da bunlardır. "Ekran yazılarını altyazıdan ayır" kapalıysa
        // (setApart: false) bunlar da altyazı gibi siyah kutuda.
        styled = applyLook(el, item);
      }
      fillText(el, item.text, item.icons);
      // Yandaki kenar payı bilgisayarın verdiği alanda kalır (room): tuş simgesinin üstüne binmez (#1203).
      var room = !phone && validBox(item.room);
      var padLeft = room ? Math.min(pad, Math.max(0, box.left - room.left)) : pad;
      var padRight = room ? Math.min(pad, Math.max(0, room.right - box.right)) : pad;
      var left = Math.max(0, box.left - padLeft);
      var top = Math.max(0, box.top - pad);
      var boxHeight = (box.bottom - box.top + 2 * pad) * height;
      el.style.left = (left * 100) + '%';
      el.style.top = (top * 100) + '%';
      var itemWidth = Math.max(room ? 1 : minWidth, (Math.min(1, box.right + padRight) - left) * width);
      if (regionId) itemWidth = Math.min(itemWidth, (1 - left) * width);
      el.style.width = itemWidth + 'px';
      // Bir piksel pay, tarayıcının kesirli koordinat/scrollHeight yuvarlamasını karşılar.
      var available = Math.max(0, Math.floor(screenBottom(items, box, left * width, itemWidth, width, height, pad, minWidth) - top * height) - 1);
      el.style.minHeight = Math.min(Math.round(boxHeight), available) + 'px';
      var line = typeof item.line === 'number' && item.line > 0 ? item.line * height : box.bottom * height - box.top * height;
      var floor = phone ? Math.max(10, Math.round(12 * height / 1080)) : SCREEN_MIN_FONT;
      // Konuşma satırı (ekran yazısı olarak okunmuş replik) alt sınırın altına küçülmez (#1255).
      var spoken = !phone && item.bubble !== true && isSpoken(item.text, item.rows);
      if (spoken) floor = Math.max(floor, dialogueMinFont(height));
      var size = Math.max(floor, Math.min(96, Math.round(line * 0.95)));
      // Özgün görünüşlü yazı özgün genişlikte kalır: Türkçe uzunsa önce satır kırılır, sığmazsa yazı en çok %20 küçülür,
      // yine sığmazsa kutu aşağı uzar.
      // Menü şeridindeki kısa etiket ("OFF" → "KAPALI", en çok iki sözcük) tek satır kalır, şeridin dışına taşmaz: gerekirse
      // yazı en çok %40 küçülür.
      // Özgün yazı tek satırsa ("ROB VICKI'S BOSS" başlığı) Türkçesi de önce tek satırda tutulur, sığmazsa küçülür; en
      // küçük boyda da sığmıyorsa satır kırılır.
      var singleOriginal = boxHeight <= line * 1.6 + 2 * pad * height;
      var bubble = styled && item.bubble === true;
      if (styled && !bubble) {
        // Özgün görünüşlü çeviri özgün yazının birebir yerinde ve boyunda (fitStyled).
        if (reuse) {
          kept.push(el);
          if (host.children[order] !== el) host.insertBefore(el, host.children[order] || null);
          order++;
        } else host.appendChild(el);
        fitStyled(el, item, box, width, height, pad, line);
        continue;
      }
      var label = styled && !bubble && item.text.indexOf('\n') < 0 && (item.text.split(/\s+/).length <= 2 || singleOriginal);
      if (styled) floor = Math.max(label ? 10 : SCREEN_MIN_FONT, Math.round(size * (label ? STYLED_LABEL_MIN_SCALE : STYLED_MIN_SCALE)));
      if (bubble) {
        floor = Math.min(size, Math.max(Math.round(BUBBLE_MIN_FONT * height / 1080), Math.round(size * BUBBLE_MIN_SCALE)));
        el.className += ' bubble';
      }
      if (label) {
        el.style.whiteSpace = 'nowrap';
        // Tek satırlık etiket özgün satırın dikey ortasında durur (yazı küçülse de özgün yazının yerinde).
        el.style.lineHeight = Math.max(1, Math.round(Math.min(boxHeight, available)) - 4) + 'px';
      }
      el.style.fontSize = size + 'px';
      if (reuse) {
        kept.push(el);
        if (host.children[order] !== el) host.insertBefore(el, host.children[order] || null);
        order++;
      } else host.appendChild(el);
      while (label && el.scrollWidth > el.clientWidth && size > floor) {
        size = Math.max(floor, size - 1);
        el.style.fontSize = size + 'px';
      }
      if (label && el.scrollWidth > el.clientWidth + 1 && item.text.split(/\s+/).length > 2) {
        el.style.whiteSpace = '';
        el.style.lineHeight = '';
      }
      // En küçük boyda da sığmayan kısa etiket kesilmez: kutu hizasına göre (ortalıysa iki yana, sağa yaslıysa sola)
      // gerektiği kadar genişler; özgün zemin rengiyle şeridin üstünde durur.
      if (label && el.style.whiteSpace === 'nowrap' && el.scrollWidth > el.clientWidth + 1) {
        var extra = el.scrollWidth - el.clientWidth + 2;
        var align = item.style && item.style.align;
        var shift = align === 'right' ? extra : align === 'left' ? 0 : extra / 2;
        var newLeft = Math.max(0, Math.min(width - itemWidth - extra, left * width - shift));
        el.style.left = newLeft + 'px';
        el.style.width = (itemWidth + extra) + 'px';
      }
      // Türkçe çoğu zaman İngilizceden uzundur: kutu biraz uzayabilir, daha fazlası için yazı küçülür.
      var limit = Math.min(available, phone || styled ? boxHeight + 1 : Math.max(boxHeight * 1.5, line * 2.6));
      while (el.scrollHeight > limit && size > floor) {
        size = Math.max(floor, size - 2);
        el.style.fontSize = size + 'px';
      }
      // En küçük okunabilir boyutta da sığmayan metni kesmeyiz/gizlemeyiz.
      // Bu uç durumda eski doğal büyüme davranışı korunur.
    }
    if (exact.length) placeExact(host, exact, width, height);
    if (reuse) {
      for (var r = 0; r < reuse.all.length; r++) {
        if (kept.indexOf(reuse.all[r]) < 0 && reuse.all[r].parentNode === host) host.removeChild(reuse.all[r]);
      }
    }
  }

  // Özgün görünüşlü çeviri ("Ekranı çevir", otomatik ekran yazısı) özgün yazının birebir yerinde (TV uygulaması 0.9.99;
  // ScreenFit.lines ile aynı sıra): yazının alanı özgün yazının kutusudur ve yana hiç genişlemez. Türkçe uzunsa sırasıyla:
  // yalnız en çok iki sözcüklük tek satırlık etikette (menü sekmesi, düğme) yazı yatayda en çok %10 sıkışır; yazı boyu
  // küçülür (tek satırlık etiket %50'ye, çok satırlı yazı %60'a kadar); satır kırılır ve kutu aşağı uzar.
  // Yazı boyunun alt sınırı konuşma altyazısı boyunun %60'ı (ekranla ölçeklenir): kısa özgün satırın boyuna kilitlenmez,
  // gerekirse özgünden büyük çizilir, kutu aşağı büyür. Önceden kısa cümleler de %15'e kadar sıkışıyor, özgün satır
  // yüksekliğine kilitleniyordu: "dar ve basık" görünüyordu.
  // Kenar payı yalnız bilgisayarın verdiği alanda (room: yandaki simgeden, fotoğraftan ve komşu yazıdan önce biter); alan
  // yoksa yanda kenar payı yok. Önceden kutu simgeye kadar yana genişliyor, son çarede ekranın kenarına kadar uzuyordu: tuş
  // simgesinin (△ ○ ✕ □, R2, L1) ve menü simgesinin üstüne biniyor, hangi tuşa basılacağı görünmüyordu (#1203).
  var FIT_FIRST_SQUEEZE = 0.9;
  var FIT_SQUEEZE_STEP = 0.05;
  var FIT_MIN_SCALE = 0.6;
  var FIT_LAST_SCALE = 0.5;
  var FIT_SCALE_STEP = 0.05;
  var FIT_FLOOR_SHARE = 0.6;

  function fitStyled(el, item, box, width, height, pad, line) {
    var label = item.text.indexOf('\n') < 0 && !(item.rows > 1);
    var x0 = box.left * width, x1 = box.right * width, y0 = box.top * height, y1 = box.bottom * height;
    var room = validBox(item.room);
    var words = item.text.split(/\s+/).length;
    // Konuşma satırı ("Ne?", "Yoldan çık.") etiket gibi sıkışmaz (#1255).
    var spoken = isSpoken(item.text, label ? 1 : rowsOf(item));
    var squeezable = label && words <= 2 && !isDialogue(item.text, 1);
    var padX = pad * width, padY = pad * height;
    var pl = room ? Math.min(padX, Math.max(0, x0 - room.left * width)) : 0;
    var pr = room ? Math.min(padX, Math.max(0, room.right * width - x1)) : 0;
    // Alan gelmediyse kutunun kenarı tam piksele dışa yuvarlanır: özgün yazının kenarındaki kesirli piksel sütunu
    // görünmesin (alan gelince kenar payı onu zaten örter, simgeye bir piksel bile yaklaşılmaz).
    if (!room) {
      pl = x0 - Math.floor(x0);
      pr = Math.ceil(x1) - x1;
    }
    var rows = label ? 1 : (item.rows > 1 ? item.rows : Math.max(1, Math.round((y1 - y0) / Math.max(1, line))));
    var size = Math.max(10, Math.min(96 * height / 1080, Math.round(line * 0.95)));
    var subtitle = typeof fontBase === 'number' && fontBase > 0 ? fontBase : 46;
    // Alt sınır yalnız cümlede (en az üç sözcük ya da çok satırlı yazı); kısa etiket simgeye taşmasın diye küçülebilir.
    var floor = squeezable ? 0 : FIT_FLOOR_SHARE * subtitle * height / 1080 / size;
    // Konuşma satırı ayrıca sayfa yüksekliğine göre alt sınırın altına inmez (#1255).
    if (spoken) floor = Math.max(floor, dialogueMinFont(height) / size);
    var inner = document.createElement('span');
    while (el.firstChild) inner.appendChild(el.firstChild);
    el.appendChild(inner);
    var pitch = Math.max(1, (y1 - y0) / rows);
    inner.style.display = 'block';
    inner.style.whiteSpace = label ? 'nowrap' : (item.paragraphs === true ? 'pre-line' : 'normal');
    el.style.whiteSpace = label ? 'nowrap' : '';
    el.style.top = (y0 - padY) + 'px';
    el.style.minHeight = '';
    // Sıkıştırılan yazının kutusu sağ kenarı yerinde kalarak sola doğru genişletilir ve sağ kenarından ölçeklenir: görünen
    // yeri yazının alanıdır, sığmayan yarı sola taşar (kaydırma payına girmez; eski Chromium dönüşümü saymıyordu).
    inner.style.transformOrigin = '100% 50%';
    inner.style.webkitTransformOrigin = '100% 50%';
    var squeeze = 1, scale = Math.max(1, floor);
    function place() {
      var font = Math.max(8, size * scale);
      // Tek satırlık etiket özgün satırın ortasında; küçülen ya da satıra inen yazının satır aralığı yazı boyundan (kutu
      // alttaki satırın üstüne az uzasın); alt sınırla büyüyen yazının satırı da büyür (basık görünmesin).
      var gap = scale > 1 ? Math.max(pitch, font * 1.15) : label ? pitch : scale < 1 ? Math.min(pitch, font * 1.05) : pitch;
      el.style.fontSize = font + 'px';
      el.style.lineHeight = gap + 'px';
      inner.style.lineHeight = gap + 'px';
      el.style.left = (x0 - pl) + 'px';
      el.style.width = (x1 - x0 + pl + pr) + 'px';
      el.style.padding = padY + 'px ' + pr + 'px ' + padY + 'px ' + pl + 'px';
      // Yükseklik en az özgün kutununki; kesirli piksel yuvarlaması yazıyı kutudan taşırmasın diye sabit değil.
      el.style.minHeight = (y1 - y0 + 2 * padY) + 'px';
      inner.style.width = ((x1 - x0) / squeeze) + 'px';
      var transform = squeeze === 1 ? '' : 'scaleX(' + squeeze + ')';
      inner.style.transform = transform;
      inner.style.webkitTransform = transform;
      inner.style.marginLeft = ((x1 - x0) - (x1 - x0) / squeeze) + 'px';
    }
    // Yatayda taşıyor mu (tek satır ya da satıra sığmayan sözcük).
    function wide() { return inner.scrollWidth > (x1 - x0) / squeeze + 1; }
    function fits() { return !wide() && (label || inner.scrollHeight <= (y1 - y0) + 1); }
    function squeezeTo(least) {
      while (wide() && squeeze > least + 1e-6) {
        squeeze = Math.max(least, Math.round((squeeze - FIT_SQUEEZE_STEP) * 100) / 100);
        place();
      }
    }
    function shrinkTo(least, until, below) {
      if (!below) least = Math.max(least, floor);
      while (!until() && scale > least + 1e-6) {
        scale = Math.max(least, Math.round((scale - FIT_SCALE_STEP) * 100) / 100);
        place();
      }
    }
    place();
    // 0) Konuşma satırı altyazı gibi davranır: özgün İngilizce kutu dar olsa da ("What?" → "Ne?", "Lucia: Maybe." →
    // "Lucia: Evet, belki.") kutu özgün yazının ortasından iki yana, ekranın %84'üne kadar genişler; sözcük başına bir
    // satıra bölünmüş küçük ve dar kutu çizilmez (#1255). Daha uzunsa satır kırılır.
    if (spoken && label && wide()) {
      var natural = Math.min(width * 0.84, inner.scrollWidth + 2);
      var middle = (x0 + x1) / 2;
      x0 = Math.max(0, Math.min(middle - natural / 2, width - natural));
      x1 = Math.min(width, x0 + natural);
      place();
    }
    // 1) Yalnız en çok iki sözcüklük etiket (menü sekmesi, düğme) yatayda en çok %10 sıkışır.
    if (squeezable) squeezeTo(FIT_FIRST_SQUEEZE);
    // 2) Yazı küçülür (alt sınırın altına inmeden).
    shrinkTo(label ? FIT_LAST_SCALE : FIT_MIN_SCALE, fits);
    if (fits()) return;
    // 3) Satır kırılır, kutu aşağı uzar (yana değil).
    if (label && words > 1) {
      label = false;
      // Satır aralığı tek satırlık kutunun yüksekliği değil, satırın kendisi: önceden satır sayısı gelmeyen görev kartı
      // açıklamasının iki satırı arasında koca bir boşluk açılıyordu (Sinan Bey, beta.93).
      pitch = Math.max(1, Math.min(pitch, line * 1.25));
      inner.style.whiteSpace = 'normal';
      el.style.whiteSpace = '';
      squeeze = 1;
      place();
    }
    // 4) Satıra sığmayan tek sözcük: yazı (alt sınırın da altına) küçülür; etiketse en çok %10 sıkışır. Yana taşmamak alt
    // sınırdan önce gelir.
    // Konuşma satırı alt sınırın altına inmez: sığmayan tek sözcükte kutu iki yana (ekran içinde) genişler.
    if (spoken) {
      if (wide()) {
        var grown = inner.scrollWidth + 2;
        x0 = Math.max(0, Math.min(x0 - (grown - (x1 - x0)) / 2, width - grown));
        x1 = Math.min(width, x0 + grown);
        place();
      }
      return;
    }
    shrinkTo(FIT_LAST_SCALE, function () { return !wide(); }, true);
    if (squeezable) squeezeTo(FIT_FIRST_SQUEEZE);
    // Paragrafta kutunun yüksekliği sabit değil (en az özgün kutununki): yazı sığana kadar aşağı uzar.
  }

  // --- Yerinde birebir çizim (TV uygulaması 0.9.102) ---
  // Bilgisayar her yazının özgün görünüşünü kareden ölçüp gönderir (TV pikselleri okuyamaz): cover (özgün yazıyı tam örten
  // kutu), bg / bg2 + bgDir (zemin ya da degrade), bgPat (desenli zemin; bg ortalama renk), fg, weight, upper, align, lineH
  // (özgün satır aralığı), grow (hizanın açık tarafındaki boş alan) ve group (aynı listedeki etiketler). Kutu tam örtü
  // sınırında, opak, köşesiz ve gölgesiz çizilir; arayüz Türkçe yapılmış gibi görünsün (Sinan Bey, beta.93: yarı saydam,
  // renkli, kayık kutular amatör görünüyordu). Yerleşim Mac, Windows, iPhone ve Android'deki ScreenFit.exact ile aynı
  // sıradadır: grubun yazı boyu üyelerin özgün boyunun ortancası; sığmayan etiket boş alana uzar (yazı boyu sabit); boş alan
  // yetmezse grubun tamamı birlikte küçülür (en çok EXACT_GROUP_MIN); yine sığmazsa satır kırılır, kutu aşağı uzar; tek
  // sözcük yine sığmıyorsa yalnız o küçülür. Çok satırlı yazı özgün genişlikte ve satır aralığında kalır. Yazı hiçbir
  // zaman "…" ile kesilmez. Alanları göndermeyen eski bilgisayarda eski çizim sürer.
  var EXACT_FONT = 0.95;
  var EXACT_GROUP_MIN = 0.7;
  var EXACT_PARAGRAPH_MIN = 0.8;
  var EXACT_WRAP_GAP = 1.2;

  function isExact(item) {
    return !!(item && typeof item.text === 'string' && item.text && phoneColor(item.bg) && phoneColor(item.fg)
      && validBox(item.cover) && validBox(item.box));
  }

  function exactWrap(words, limit, measure) {
    var lines = [], current = '';
    for (var i = 0; i < words.length; i++) {
      var next = current ? current + ' ' + words[i] : words[i];
      if (current && measure(next) > limit + 0.5) {
        lines.push(current);
        current = words[i];
      } else current = next;
    }
    if (current || !lines.length) lines.push(current);
    return lines;
  }

  function exactWords(text) {
    var words = text.split(/\s+/), result = [];
    for (var i = 0; i < words.length; i++) if (words[i]) result.push(words[i]);
    return result;
  }

  // Saf yerleşim (ScreenFit.exact): items piksel cinsinden {text, left, top, right, bottom, growLeft, growRight, line, pitch,
  // rows, align, group}; measure(text, size, index) yazının genişliği. Dönen: {left, top, width, height, fontSize, lines,
  // lineHeight, rowHeight}.
  function exactLayout(items, measure) {
    var base = [], members = {}, i;
    for (i = 0; i < items.length; i++) {
      base.push(EXACT_FONT * items[i].line);
      if (typeof items[i].group === 'number') (members[items[i].group] = members[items[i].group] || []).push(i);
    }
    var key, list, k;
    for (key in members) {
      if (!Object.prototype.hasOwnProperty.call(members, key) || members[key].length < 2) continue;
      list = members[key];
      var sizes = [];
      for (k = 0; k < list.length; k++) sizes.push(base[list[k]]);
      sizes.sort(function (a, b) { return a - b; });
      for (k = 0; k < list.length; k++) base[list[k]] = sizes[Math.floor(sizes.length / 2)];
    }
    function isLabel(item) { return !(item.rows > 1) && item.text.indexOf('\n') < 0; }
    var natural = [], scale = [];
    for (i = 0; i < items.length; i++) {
      natural.push(isLabel(items[i]) ? measure(items[i].text, base[i], i) : 0);
      scale.push(isLabel(items[i]) && natural[i] > 0 && !items[i].keepSize
        ? Math.max(EXACT_GROUP_MIN, Math.min(1, (items[i].growRight - items[i].growLeft) / natural[i])) : 1);
    }
    for (key in members) {
      if (!Object.prototype.hasOwnProperty.call(members, key) || members[key].length < 2) continue;
      list = members[key];
      var least = 1;
      for (k = 0; k < list.length; k++) least = Math.min(least, scale[list[k]]);
      for (k = 0; k < list.length; k++) scale[list[k]] = least;
    }
    var result = [];
    for (i = 0; i < items.length; i++) {
      var item = items[i];
      result.push(isLabel(item) ? exactLabel(item, i, base[i], scale[i], natural[i], measure)
        : exactParagraph(item, i, base[i], measure));
    }
    return result;
  }

  function exactLabel(item, index, base, scale, natural, measure) {
    var coverWidth = item.right - item.left, coverHeight = item.bottom - item.top;
    var font = base * scale, avail = item.growRight - item.growLeft, width = natural * scale;
    var lines = [item.text], gap = coverHeight, j;
    function at(text) { return measure(text, font, index); }
    if (width > avail + 0.5) {
      var words = exactWords(item.text);
      var widest = 0;
      for (j = 0; j < words.length; j++) widest = Math.max(widest, at(words[j]));
      if (words.length >= 2) {
        // Satır kırılır; satıra sığmayan sözcük varsa yazı yalnız bu öğede küçülür (yana taşmaz).
        if (widest > avail + 0.5) font *= avail / widest;
        lines = exactWrap(words, avail, at);
      } else {
        font *= avail / Math.max(1e-9, width);
      }
      width = 0;
      for (j = 0; j < lines.length; j++) width = Math.max(width, at(lines[j]));
      if (lines.length > 1) gap = Math.max(coverHeight / lines.length, font * EXACT_WRAP_GAP);
    }
    var boxWidth = Math.max(coverWidth, Math.min(avail, width));
    var left = item.align === 'right' ? item.right - boxWidth
      : item.align === 'center' ? item.left - (boxWidth - coverWidth) / 2 : item.left;
    left = Math.min(Math.max(left, item.growLeft), item.growRight - boxWidth);
    return { left: left, top: item.top, width: boxWidth, height: Math.max(coverHeight, lines.length * gap), fontSize: font,
      lines: lines, lineHeight: gap, rowHeight: gap };
  }

  function exactParagraph(item, index, base, measure) {
    var coverWidth = item.right - item.left, coverHeight = item.bottom - item.top;
    var factor = 1;
    // Özgün bir satırın yüksekliği (kenar payıyla): son satır tam aralık değil, bu kadar yer kaplar.
    var row = Math.max(base * 1.05, coverHeight - (Math.max(1, item.rows || 1) - 1) * item.pitch);
    function layout() {
      var font = base * factor, gap = Math.max(item.pitch, base * 1.05) * factor, lines = [];
      var parts = item.text.split('\n');
      for (var p = 0; p < parts.length; p++) {
        var words = exactWords(parts[p]);
        lines = lines.concat(words.length ? exactWrap(words, coverWidth, function (t) { return measure(t, font, index); }) : ['']);
      }
      return { font: font, lines: lines, gap: gap };
    }
    function tall(laid) { return (laid.lines.length - 1) * laid.gap + row * factor; }
    var laid = layout();
    while (!item.keepSize && tall(laid) > coverHeight + 1 && factor > EXACT_PARAGRAPH_MIN + 1e-6) {
      factor = Math.max(EXACT_PARAGRAPH_MIN, Math.round((factor - 0.05) * 100) / 100);
      laid = layout();
    }
    var widest = 0;
    for (var j = 0; j < laid.lines.length; j++) widest = Math.max(widest, measure(laid.lines[j], laid.font, index));
    // Satıra sığmayan tek sözcük: yazı küçülür (yana taşmaz).
    if (widest > coverWidth + 0.5) {
      factor *= coverWidth / widest;
      laid = layout();
    }
    return { left: item.left, top: item.top, width: coverWidth, height: Math.max(coverHeight, tall(laid)), fontSize: laid.font,
      lines: laid.lines, lineHeight: laid.gap, rowHeight: row * factor };
  }

  // Satırların düz metindeki başlangıcı (simgeler satırına dağıtılsın diye).
  function lineStarts(text, lines) {
    var starts = [], from = 0;
    for (var i = 0; i < lines.length; i++) {
      var at = lines[i] ? text.indexOf(lines[i].split(' ')[0], from) : from;
      if (at < 0) at = from;
      starts.push(at);
      from = at + lines[i].length;
    }
    return starts;
  }

  // Birebir çizimde dar aile: Android TV'de de gömülü aile kullanılır (ayrı aile adı, sistemin değişken Roboto'su dar
  // genişliğe geçmez; konuşma satırına hiç verilmez, #1297).
  function exactFamily(item) {
    if (condensedLook(item)) return CONDENSED_FONT;
    var dialogue = !item || isDialogue(item.text, item.paragraphs === true ? 2 : item.rows);
    return window.AndroidTV && item && item.style && item.style.condensed === true && !dialogue ? EMBEDDED_CONDENSED + ', sans-serif' : '';
  }

  // --- Çizim kipleri (TV uygulaması 0.9.108) ---
  // Bilgisayar her yazı için kip seçer (TextPaint.mode): "cover" özgünü örter (yukarıdaki çizim); "beside" kutu çizmez,
  // Türkçe özgünün yanındaki boş alana (spot, spotRoom içinde uzar) özgün stilde, okunurluk için yumuşak konturla yazılır
  // (Sinan Bey: "SELAMLA  GREET"); "twin" özgün paneli örtmez, aynı zemin, köşe (radius), kuyruk (tail) ve kişi resmiyle
  // (icon {src, box}) küçük bir ikiz panel (twinBox, scale katında yazı) çizer, genişliği içeriğe göre (#1296). Eski
  // bilgisayar bu alanları göndermez: örtme sürer. Mac/iPhone ExactScreenText, Windows ScreenTextCanvas, Android
  // PhoneSubtitleActivity aynı kuralla çizer.
  function exactMode(item) {
    if (!item || (item.mode !== 'beside' && item.mode !== 'twin') || !validBox(item.spot) || !validBox(item.spotRoom)) {
      return 'cover';
    }
    if (item.mode === 'twin' && !validBox(item.twinBox)) return 'cover';
    return item.mode;
  }

  // Yerleşim girdisi (ScreenFit.ExactInput ile aynı): örtmeyen kipte yazı spot'ta, spotRoom içinde; ikizde yazı scale
  // katında; yanına yazılan Türkçe özgüne yaslanır (solundaysa sağa, sağındaysa sola). Grup örtmede ve yanına yazmada
  // (listede bütün Türkçeler aynı boyda); ikizde yazı küçülmez (keepSize: satır kırılır, kutu uzar; TV 0.9.109).
  function exactInput(item, width, height) {
    var mode = exactMode(item), cover = item.cover;
    var box = mode === 'cover' ? cover : item.spot;
    var grow = mode === 'cover' ? validBox(item.grow) : item.spotRoom;
    var scale = mode === 'twin' && typeof item.scale === 'number' && item.scale > 0 ? item.scale : 1;
    var line = (typeof item.line === 'number' && item.line > 0 ? item.line * height : (cover.bottom - cover.top) * height) * scale;
    var pitch = typeof item.lineH === 'number' && item.lineH > 0 ? item.lineH * height * scale : line;
    var align = item.align === 'right' || item.align === 'center' ? item.align : 'left';
    if (mode === 'beside') {
      if (box.right <= cover.left) align = 'right';
      else if (box.left >= cover.right) align = 'left';
    }
    return { text: item.text, left: box.left * width, top: box.top * height, right: box.right * width,
      bottom: box.bottom * height, growLeft: Math.min(box.left, grow ? grow.left : box.left) * width,
      growRight: Math.max(box.right, grow ? grow.right : box.right) * width, line: line, pitch: pitch,
      rows: item.rows > 1 || item.text.indexOf('\n') >= 0 ? Math.max(2, item.rows || 2) : 1,
      align: align, group: mode !== 'twin' && typeof item.group === 'number' ? item.group : null,
      keepSize: mode === 'twin' };
  }

  // Okunurluk konturu: açık yazıda koyu, koyu yazıda açık.
  function exactHalo(fg, size) {
    var r = parseInt(fg.slice(1, 3), 16), g = parseInt(fg.slice(3, 5), 16), b = parseInt(fg.slice(5, 7), 16);
    var halo = 0.299 * r + 0.587 * g + 0.114 * b > 127.5 ? 'rgba(0,0,0,0.85)' : 'rgba(255,255,255,0.85)';
    var blur = Math.max(1, Math.round(size * 0.08));
    return '0 0 ' + blur + 'px ' + halo + ', 0 1px 0 ' + halo;
  }

  // İkizin kenar çizgisi (TV 0.9.109; özgün kutunun hemen dışındaki ince düz şerit, GTA 6 kartının üstündeki renkli
  // çizgi): panelin dışına, her yanda kendi kalınlığında; kutunun yeri değişmez.
  function exactEdge(panel, edge, height, left, top) {
    if (!edge || !phoneColor(edge.color)) return;
    var sides = ['top', 'right', 'bottom', 'left'], widths = {}, any = false;
    for (var s = 0; s < sides.length; s++) {
      var v = typeof edge[sides[s]] === 'number' && edge[sides[s]] > 0 ? Math.max(1, Math.round(edge[sides[s]] * height)) : 0;
      widths[sides[s]] = v;
      any = any || v > 0;
    }
    if (!any) return;
    panel.style.borderStyle = 'solid';
    panel.style.borderColor = edge.color;
    panel.style.borderWidth = widths.top + 'px ' + widths.right + 'px ' + widths.bottom + 'px ' + widths.left + 'px';
    panel.style.left = (left - widths.left) + 'px';
    panel.style.top = (top - widths.top) + 'px';
    panel.style.width = (parseFloat(panel.style.width) + widths.left + widths.right) + 'px';
    panel.style.height = (parseFloat(panel.style.height) + widths.top + widths.bottom) + 'px';
  }

  // Tek satırlık yazının (tek yazı ya da aynı satırdaki tuş istemleri) ikizi yazıyı her yanda en çok TWIN_PAD_LINES satır
  // aşar, yanlarda yazının genişliği kadar da (TV 0.9.115). beta.103 bilgisayarı koyu oyun dünyasını (ekranın altındaki
  // karartı) kutu sanıp tuş çubuğundaki "◯ Back"ı ekranın yarısı boyunda dev siyah ikize yazabiliyordu (TCL Android TV);
  // TV eski bilgisayarda da ikizi yazının çevresine kırpar. Alt alta yazılı kutu (bildirim: ad ve gövde) dokunulmaz.
  var TWIN_PAD_LINES = 3;
  function twinFrame(items, key, width, height) {
    var first = null, ul = Infinity, ut = Infinity, ur = -Infinity, ub = -Infinity, line = 0, members = [];
    for (var j = 0; j < items.length; j++) {
      var tb = items[j].twinBox;
      if (exactMode(items[j]) !== 'twin' || [tb.left, tb.top, tb.right, tb.bottom].join(',') !== key) continue;
      if (!first) first = tb;
      members.push(items[j]);
    }
    for (j = 0; j < members.length; j++) {
      var s = members[j].spot;
      if (members[j].rows > 1 || String(members[j].text).indexOf('\n') >= 0) return first;
      ul = Math.min(ul, s.left * width); ur = Math.max(ur, s.right * width);
      ut = Math.min(ut, s.top * height); ub = Math.max(ub, s.bottom * height);
      line = Math.max(line, (typeof members[j].line === 'number' && members[j].line > 0 ? members[j].line : s.bottom - s.top) * height);
    }
    // Alt alta duran yazılar (satırları örtüşmeyen) gerçek kutudur.
    for (j = 0; j < members.length; j++) {
      for (var k = j + 1; k < members.length; k++) {
        if (members[j].spot.bottom <= members[k].spot.top || members[k].spot.bottom <= members[j].spot.top) return first;
      }
    }
    var padY = TWIN_PAD_LINES * line, padX = Math.max(padY, ur - ul);
    var left = Math.max(first.left * width, ul - padX), right = Math.min(first.right * width, ur + padX);
    var top = Math.max(first.top * height, ut - padY), bottom = Math.min(first.bottom * height, ub + padY);
    if (left <= first.left * width && right >= first.right * width && top <= first.top * height &&
      bottom >= first.bottom * height) return first;
    return { left: left / width, top: top / height, right: right / width, bottom: bottom / height };
  }

  // İkiz paneller (aynı twinBox'ı paylaşan öğeler tek panel), yazılardan önce host'a eklenir. Genişlik içeriğe göre: en
  // sağdaki yazı ya da resim + sol iç boşluk. Dönen: eklenen öğeler.
  function exactTwins(host, items, placed, width, height) {
    var drawn = [], seen = {};
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      if (exactMode(item) !== 'twin') continue;
      var t = item.twinBox, key = [t.left, t.top, t.right, t.bottom].join(',');
      if (seen[key]) continue;
      seen[key] = true;
      t = twinFrame(items, key, width, height);
      var left = t.left * width, least = Infinity, right = 0, bottom = 0, spotBottom = 0, j;
      for (j = 0; j < items.length; j++) {
        var other = items[j].twinBox;
        if (exactMode(items[j]) !== 'twin' || [other.left, other.top, other.right, other.bottom].join(',') !== key) continue;
        least = Math.min(least, placed[j].left);
        right = Math.max(right, placed[j].left + placed[j].width);
        bottom = Math.max(bottom, placed[j].top + placed[j].height);
        spotBottom = Math.max(spotBottom, items[j].spot.bottom * height);
      }
      var pad = Math.max(0, (least === Infinity ? left : least) - left);
      var icon = item.icon && typeof item.icon.src === 'string' && item.icon.src.indexOf('data:image/') === 0 &&
        validBox(item.icon.box) ? item.icon : null;
      if (icon) right = Math.max(right, icon.box.right * width);
      // Yükseklik de içeriğe göre: Türkçe uzunsa (satır kırıldı) kutu aşağı uzar, alt iç boşluk özgündeki kadar kalır.
      var top = t.top * height, h = Math.max((t.bottom - t.top) * height, bottom + (t.bottom * height - spotBottom) - top);
      var radius = typeof item.radius === 'number' && item.radius > 0 ? item.radius * height : 0;
      // Genişlik içeriğe göre, özgün kutudan dar değil (ikiz özgünün aynısı).
      var panelWidth = Math.max(1, right + pad - left, (t.right - t.left) * width);
      // Ekranın dışına taşan ikiz (TV 0.9.113; Sinan Bey, beta.100 3419: "- HARİTA GÜNCELLENDİ!" sağ kenardan kesikti)
      // yazılarıyla birlikte sola kayar; ekrandan genişse sol kenardan başlar.
      var shift = Math.max(0, Math.min(left, left + panelWidth - width));
      if (shift > 0) {
        left -= shift;
        for (j = 0; j < items.length; j++) {
          var moved = items[j].twinBox;
          if (exactMode(items[j]) !== 'twin' || [moved.left, moved.top, moved.right, moved.bottom].join(',') !== key) continue;
          placed[j].left -= shift;
        }
      }
      var panel = document.createElement('div');
      panel.className = 'item exact twin';
      panel.style.left = left + 'px';
      panel.style.top = top + 'px';
      panel.style.width = panelWidth + 'px';
      panel.style.height = h + 'px';
      panel.style.backgroundColor = item.bg;
      panel.style.borderRadius = radius + 'px';
      exactEdge(panel, item.edge, height, left, top);
      if (item.tail === 'left' || item.tail === 'right') {
        panel.style[item.tail === 'left' ? 'borderBottomLeftRadius' : 'borderBottomRightRadius'] = '0';
        // Balonun kuyruğu: alt köşeden aşağı küçük üçgen (kenarlık hilesi; ES5, svg yok).
        var tail = document.createElement('div');
        tail.className = 'exact-tail';
        tail.style.position = 'absolute';
        tail.style.top = h + 'px';
        tail.style.width = '0';
        tail.style.height = '0';
        tail.style.borderTop = Math.max(1, radius * 0.6) + 'px solid ' + item.bg;
        if (item.tail === 'left') {
          tail.style.left = '0';
          tail.style.borderRight = Math.max(1, radius) + 'px solid transparent';
        } else {
          tail.style.right = '0';
          tail.style.borderLeft = Math.max(1, radius) + 'px solid transparent';
        }
        panel.appendChild(tail);
      }
      if (icon) {
        var img = document.createElement('img');
        img.className = 'exact-portrait';
        img.src = icon.src;
        img.style.position = 'absolute';
        img.style.left = (icon.box.left * width - shift - left) + 'px';
        img.style.top = (icon.box.top * height - top) + 'px';
        img.style.width = ((icon.box.right - icon.box.left) * width) + 'px';
        img.style.height = ((icon.box.bottom - icon.box.top) * height) + 'px';
        img.style.borderRadius = '50%';
        panel.appendChild(img);
      }
      host.appendChild(panel);
      drawn.push(panel);
    }
    return drawn;
  }

  // Birebir öğeleri çizer: host'a eklenen kutular (sırayla).
  function placeExact(host, items, width, height) {
    var probe = document.createElement('span');
    probe.style.position = 'absolute';
    probe.style.visibility = 'hidden';
    probe.style.whiteSpace = 'pre';
    probe.style.left = '-10000px';
    probe.style.top = '0';
    host.appendChild(probe);
    var scale = pageSize().scale;
    var inputs = [];
    for (var i = 0; i < items.length; i++) inputs.push(exactInput(items[i], width, height));
    function measure(text, size, index) {
      probe.style.fontFamily = exactFamily(items[index]);
      probe.style.fontWeight = items[index].weight === 700 ? '700' : '400';
      probe.style.fontSize = size + 'px';
      probe.textContent = text;
      // Ölçü yukarı yuvarlanır: kesirli piksel yazıyı kutudan taşırmasın.
      return Math.ceil(pageRect(probe.getBoundingClientRect(), scale).width) + 1;
    }
    var placed = exactLayout(inputs, measure);
    host.removeChild(probe);
    var drawn = exactTwins(host, items, placed, width, height);
    for (var n = 0; n < items.length; n++) {
      var source = items[n], place = placed[n], mode = exactMode(source);
      // Yazı ekranın sağ kenarından taşmaz (TV 0.9.113): sığmayan kutu sola kayar.
      place.left = Math.max(0, Math.min(place.left, width - place.width));
      var el = document.createElement('div');
      el.className = mode === 'cover' ? 'item exact' : 'item exact ' + mode;
      el.couchsubsBox = validBox(source.box);
      el.style.left = place.left + 'px';
      el.style.top = place.top + 'px';
      el.style.width = place.width + 'px';
      el.style.height = place.height + 'px';
      el.style.backgroundColor = mode === 'cover' ? source.bg : 'transparent';
      if (mode === 'beside') el.style.textShadow = exactHalo(source.fg, place.fontSize);
      if (mode === 'cover' && phoneColor(source.bg2) && (source.bgDir === 'h' || source.bgDir === 'v')) {
        var webkit = '-webkit-linear-gradient(' + (source.bgDir === 'h' ? 'left' : 'top') + ', ' + source.bg + ', ' + source.bg2 + ')';
        var standard = 'linear-gradient(' + (source.bgDir === 'h' ? 'to right' : 'to bottom') + ', ' + source.bg + ', ' + source.bg2 + ')';
        el.style.backgroundImage = webkit;
        el.style.backgroundImage = standard;
      }
      el.style.color = source.fg;
      el.style.fontWeight = source.weight === 700 ? '700' : '400';
      el.style.fontFamily = exactFamily(source);
      el.style.fontSize = place.fontSize + 'px';
      el.style.textAlign = inputs[n].align;
      var starts = lineStarts(source.text, place.lines);
      for (var k = 0; k < place.lines.length; k++) {
        var row = document.createElement('div');
        row.className = 'exact-line';
        row.style.top = (k * place.lineHeight) + 'px';
        row.style.height = place.rowHeight + 'px';
        row.style.lineHeight = place.rowHeight + 'px';
        var icons = [];
        for (var c = 0; source.icons && c < source.icons.length; c++) {
          var icon = source.icons[c], end = k + 1 < starts.length ? starts[k + 1] : source.text.length + 1;
          if (icon && typeof icon.at === 'number' && icon.at >= starts[k] && icon.at < end) {
            icons.push({ at: icon.at - starts[k], src: icon.src });
          }
        }
        fillText(row, place.lines[k], icons);
        el.appendChild(row);
      }
      host.appendChild(el);
      drawn.push(el);
    }
    return drawn;
  }

  function showScreen(items, duration) {
    var host = $('screen');
    // "Ekran çevriliyor…" yazısı sonuçların üstünde kalmasın.
    hideSubtitle('screen');
    host.innerHTML = '';
    host.className = '';
    placeItems(host, items);
    clearTimeout(screenTimer);
    screenTimer = setTimeout(hideScreen, duration || 20000);
    resolveLayers();
  }

  function hideScreen() {
    clearTimeout(screenTimer);
    $('screen').className = 'hidden';
    $('screen').innerHTML = '';
    resolveLayers();
  }

  // --- Ek alanlar ---
  // Bilgisayar altyazının yanında ekranın köşelerindeki yazıları da (görev, telefon mesajı, bildirim) sürekli okur ve
  // her alanın çevirisini "region" olayıyla gönderir: {id, text, box, line}. Çeviri İngilizce yazının yerinde küçük bir
  // kutuda durur; ekranın sağ yarısındaki kutu sağa, alt yarısındaki alta yaslanır, Türkçe uzun gelirse kutu ekranın
  // içine doğru büyür. Alanda birbirinden ayrı duran yazılar varsa "blocks" her grubun çevirisini kendi yeriyle taşır
  // ve her biri "ekranı çevir"deki gibi kendi yazısının üstüne konur. Boş "text" o alanın kutusunu, "region-clear"
  // hepsini kaldırır. Ana altyazıya dokunulmaz.

  var regionBoxes = {};
  // Güvenlik ağı (#1198): telefon kartı dışındaki alan, gönderici REGION_LIFE_MS boyunca ne yeniler ne temizlerse
  // kendiliğinden kalkar. Gönderici gösterdiği alanları her 5 sn'de bir "keep" bayrağıyla yeniden gönderir (Mac, iPhone:
  // SubtitleServer.refreshRegions, Windows: RefreshRegions, Android: refreshRegions); kaçan temizleme komutu yüzünden
  // oyundan kalkmış yazının çevirisi TV'de sonsuza dek kalmaz. Eski göndericiler yenilemez: alan 15 sn'de kalkar.
  var REGION_LIFE_MS = 15000;
  var REGION_PAD = 0.004;
  var REGION_MIN_FONT = 18;
  var REGION_MAX_FONT = 44;

  // Telefon gönderisinin TV'de görünen içeriği (TV uygulaması 0.9.105; X, 22 Kas: "her saniye şekli de hareketi de
  // değişiyor"): panelin mesajları, kişi adı ve notları kartın içinde akışla çizilir, kutuları çizimi değiştirmez. Yalnız
  // kutuları oynayan aynı içerik yeniden dizilmez, yazı boyu yeniden hesaplanmaz (bilgisayardaki PhoneSteady.samePicture ile
  // aynı kural); panelin zemini ve panel dışındaki her öğe yeriyle karşılaştırılır.
  // Hizalı panelde (card.aligned, TV uygulaması 0.9.106) parçalar kutularının yerinde çizilir: kutuları da karşılaştırılır
  // (bilgisayar küçük oynamayı zaten göndermez, PhoneSteady.samePicture).
  function phonePayload(blocks) {
    var card = panelCard(blocks);
    var flow = card && card.aligned !== true;
    var parts = [];
    for (var i = 0; i < blocks.length; i++) {
      var block = blocks[i];
      if (flow && block && PANEL_PARTS[block.panel]) {
        var copy = {};
        for (var key in block) if (Object.prototype.hasOwnProperty.call(block, key) && key !== 'box') copy[key] = block[key];
        parts.push(copy);
      } else parts.push(block);
    }
    return JSON.stringify(parts);
  }

  function showRegion(data) {
    var id = data && typeof data.id === 'string' ? data.id : '';
    if (!id) return;
    var box = validBox(data.box);
    if (typeof data.text !== 'string' || !data.text || !box) return hideRegion(id);
    diag.regions++;
    // Alanda ayrı duran yazı grupları (görev başlığı ve ayrı sütundaki hedef) kendi yerleriyle gelir: her biri "ekranı
    // çevir"deki gibi kendi İngilizce yazısının üstüne konur. Bloksuz olayda alanın çevirisi tek kutuda kalır.
    var blocks = Array.isArray(data.blocks) ? data.blocks : null;
    var kind = blocks && blocks.length ? 'region-blocks' : 'region';
    var el = regionBoxes[id];
    var now = Date.now();
    // Göndericinin yenilemesi (keep): aynı alan yeniden çizilmez, katmanların sırası değişmez; yalnız ömrü uzar.
    var raw = JSON.stringify([data.text, data.box, data.line || 0, data.icons || null, data.blocks || null]);
    if (data.keep === true && el && el.couchsubsRaw === raw) {
      el.couchsubsSeen = now;
      return;
    }
    // Oyun telefonunun aynı gönderisi yeniden çizilmez; değişen gönderi yerinde güncellenir (placeItems, placePanel).
    var phoneBlocks = id === 'game-phone' && kind === 'region-blocks';
    var payload = phoneBlocks ? phonePayload(blocks) + JSON.stringify(box) : null;
    if (phoneBlocks && el && el.className === kind && el.couchsubsPayload === payload) {
      el.couchsubsStamp = ++regionStamp;
      el.couchsubsSeen = now;
      return;
    }
    // Alan yerinde güncellenince katman sırası korunur (resolveLayers): yalnız yeni gelen alan eskisinin önüne geçer.
    // Önceden her güncelleme sırayı yeniliyordu; aynı yeri çizen iki alan (görev kartı, ekran yazısı, hazır alan) her
    // okumada birbirinin yerine geçip gidip geliyordu (beta.106).
    var stamp = el && el.couchsubsStamp ? el.couchsubsStamp : 0;
    // Bloklar her olayda baştan dizilir; tek kutudan bloklara (ya da tersine) geçen alanın eski kutusu kalkar.
    if (el && (el.className !== kind || (kind === 'region-blocks' && !phoneBlocks))) {
      hideRegion(id);
      el = null;
    }
    if (!el) {
      el = document.createElement('div');
      el.className = kind;
      $('regions').appendChild(el);
      regionBoxes[id] = el;
    }
    $('regions').className = '';
    el.couchsubsRaw = raw;
    el.couchsubsSeen = now;
    // En son gelen alan, kendisiyle aynı yeri çizen eski alanın önüne geçer (resolveLayers); güncellenen alan yerini korur.
    el.couchsubsStamp = stamp || ++regionStamp;
    el.couchsubsBox = box;
    if (kind === 'region-blocks') {
      el.couchsubsPayload = payload;
      placeItems(el, blocks, id);
      resolveLayers();
      avoidRegions();
      return;
    }
    if (tooBig(box)) return hideRegion(id);
    var width = pageSize(true).width;
    var height = pageSize(true).height;
    fillText(el, data.text, data.icons);
    el.style.left = el.style.right = el.style.top = el.style.bottom = '';
    if ((box.left + box.right) / 2 > 0.5) {
      el.style.right = (Math.max(0, 1 - box.right - REGION_PAD) * 100) + '%';
    } else {
      el.style.left = (Math.max(0, box.left - REGION_PAD) * 100) + '%';
    }
    if ((box.top + box.bottom) / 2 > 0.5) {
      el.style.bottom = (Math.max(0, 1 - box.bottom - REGION_PAD) * 100) + '%';
    } else {
      el.style.top = (Math.max(0, box.top - REGION_PAD) * 100) + '%';
    }
    var boxWidth = (Math.min(1, box.right + REGION_PAD) - Math.max(0, box.left - REGION_PAD)) * width;
    var boxHeight = (Math.min(1, box.bottom + REGION_PAD) - Math.max(0, box.top - REGION_PAD)) * height;
    var hasLine = typeof data.line === 'number' && data.line > 0;
    var singleLine = hasLine && box.bottom - box.top <= data.line * 1.4 && data.text.indexOf('\n') < 0;
    el.style.minWidth = Math.round(boxWidth) + 'px';
    el.style.maxWidth = Math.round(Math.max(boxWidth, width * (singleLine ? 0.35 : 0.3))) + 'px';
    el.style.minHeight = Math.round(boxHeight) + 'px';
    var line = hasLine ? data.line * height : 30;
    var size = Math.max(REGION_MIN_FONT, Math.min(REGION_MAX_FONT, Math.round(line * 0.9)));
    el.style.fontSize = size + 'px';
    // Tek satırlık yardım yazısını kendi satırında tut; uzun mesajın kutusu biraz büyüyebilir.
    var limit = Math.round(singleLine ? boxHeight : Math.max(boxHeight * 1.35, line * 2.4));
    while (el.scrollHeight > limit && size > SCREEN_MIN_FONT) {
      size = Math.max(SCREEN_MIN_FONT, size - 2);
      el.style.fontSize = size + 'px';
    }
    resolveLayers();
    avoidRegions();
  }

  function hideRegion(id) {
    var el = regionBoxes[id];
    if (!el) return;
    delete regionBoxes[id];
    // Hizalı telefon paneli (0.9.106) telefon ekrandan kalkınca yumuşakça kaybolur (CSS .leaving), sonra kaldırılır.
    if (id === 'game-phone' && el.querySelector && el.querySelector('.phone-panel.aligned')) {
      el.className += ' leaving';
      setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, PANEL_FADE_MS);
    } else $('regions').removeChild(el);
    resolveLayers();
    avoidRegions();
  }

  // --- Aynı yerde tek çizim (#827) ---
  // "Ekranı çevir" ve ek alanlar (otomatik ekran yazısı dahil) ayrı katmanlarda çizilir. Aynı yazıyı iki katman birden
  // çizince (GTA 6 haritası, görev listesi) kutular üst üste biniyor, alttakinin yazısı üsttekinin arasından görünüyordu.
  // Kutusu başka bir katmanın kutusuyla, küçüğünün alanının en az COVER_SHARE'i kadar örtüşen çeviri gizlenir: "Ekranı
  // çevir" ekrandayken onunki, ek alanlar arasında en son gelen kalır (yeni olan eskisinin yerine geçer). Ekranı çevir
  // kalkınca ya da üstteki alan silinince gizlenenler yeniden görünür. Oyun telefonu kartı bu kurala girmez.
  // Bilgisayardaki kural: ScreenTranslation.coverShare (Mac, iPhone), CoverShare (Windows), COVER_SHARE (Android).
  var COVER_SHARE = 0.25;
  var SCREEN_RANK = 1e15;
  // Görev satırı (auto-mission) ekrandayken onun yerini çizen otomatik ekran yazısı görevin yerine geçmez: menü durumu
  // bir an açılıp kapanınca görevin kırpık okuması ("arch near the turbi") yeni alan olarak geliyor, görevin Türkçesini
  // gizliyordu (GTA 6). Görev yalnız "Ekranı çevir"in altında kalır.
  var MISSION_ID = 'auto-mission';
  var MISSION_RANK = SCREEN_RANK - 1;
  var regionStamp = 0;

  function overlapShare(a, b) {
    var width = Math.min(a.right, b.right) - Math.max(a.left, b.left);
    var height = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
    if (!(width > 0) || !(height > 0)) return 0;
    var smaller = Math.min((a.right - a.left) * (a.bottom - a.top), (b.right - b.left) * (b.bottom - b.top));
    return smaller > 0 ? Math.min(1, width * height / smaller) : 0;
  }

  function layerParts() {
    var parts = [];
    var screen = $('screen');
    if (screen && screen.className !== 'hidden') {
      for (var i = 0; i < screen.children.length; i++) {
        var item = screen.children[i];
        if (item.couchsubsBox) parts.push({ el: item, box: item.couchsubsBox, rank: SCREEN_RANK, layer: 'screen' });
      }
    }
    for (var id in regionBoxes) {
      if (!Object.prototype.hasOwnProperty.call(regionBoxes, id) || id === 'game-phone') continue;
      var host = regionBoxes[id];
      var list = host.className === 'region-blocks' ? host.children : [host];
      for (var j = 0; j < list.length; j++) {
        if (list[j].couchsubsBox) parts.push({ el: list[j], box: list[j].couchsubsBox, rank: id === MISSION_ID ? MISSION_RANK : host.couchsubsStamp || 0, layer: id });
      }
    }
    return parts;
  }

  function resolveLayers() {
    var parts = layerParts();
    for (var i = 0; i < parts.length; i++) {
      var covered = false;
      for (var j = 0; j < parts.length && !covered; j++) {
        covered = parts[j].layer !== parts[i].layer && parts[j].rank > parts[i].rank &&
          overlapShare(parts[i].box, parts[j].box) >= COVER_SHARE;
      }
      parts[i].el.style.visibility = covered ? 'hidden' : '';
    }
  }

  // --- Ekran yazısı ile altyazının ayrımı: hiçbir iki çeviri kutusu üst üste binmez ---
  // Görev/hedef satırı çoğu oyunda altyazıya bitişik (ikisi de altta ortada). Altyazının yeri kullanıcının seçimidir ve
  // hiçbir ekran yazısı onu değiştirmez: altyazıyla üst üste binecek ek alan/ekran yazısı kutusu kendisi, yalnız
  // gerektiği kadar (aralarında küçük boşlukla) altyazıdan uzağa kayar; kaydığı yer ekranın dışındaysa öbür yana.
  // Ortak çakışma çözücü (X, beta.100, GTA 6 kalabalık sahne: "çeviriler üst üste", "görevlerin yarısı üst üste"):
  // sabit kutular altyazının bütün yığınıdır (son satır, önceki iki satır, örtü) ve oyun telefonu; eskiden yalnız son satır
  // ölçülüyor, görev kutusu önceki satırların üstüne biniyordu. Ek alanların ve "Ekranı çevir"in kutuları da birbirine
  // göre çözülür (eskiden yalnız altyazıya göre; kayan görev kutusu ekran yazısı ikizinin üstüne düşüyordu): sırayla görev
  // kutusu, "Ekranı çevir", sonra ek alanlar eskiden yeniye yerleşir; her biri, kendinden önce yerleşmiş başka katmanın
  // kutularıyla kesişmeyen ve ekranın içinde kalan en küçük dikey kaymayı alır. Aynı alanın kendi kutuları (menü ikizleri)
  // placeItems'ta yerleşir, birbirine göre kaydırılmaz. Gizlenen (resolveLayers) kutu yer kaplamaz.
  var AVOID_GAP = 0.006;
  var setApart = true;

  function setShift(el, dy) {
    var value = dy ? 'translateY(' + Math.round(dy) + 'px)' : '';
    el.style.webkitTransform = value;
    el.style.transform = value;
  }

  function regionParts() {
    var parts = [];
    var screen = $('screen');
    if (screen && screen.className !== 'hidden') {
      for (var s = 0; s < screen.children.length; s++) parts.push({ el: screen.children[s], layer: 'screen', rank: 1 });
    }
    for (var id in regionBoxes) {
      // Oyun telefonu kaydırılmaz; altyazı telefonun üstüne binmez, kendisi kayar (avoidPhone).
      if (!Object.prototype.hasOwnProperty.call(regionBoxes, id) || id === 'game-phone') continue;
      var host = regionBoxes[id];
      var list = host.className === 'region-blocks' ? host.children : [host];
      // Görev kutusu ilk yerleşir (yerinden en az oynayan o olur); diğerleri eskiden yeniye.
      var rank = id === MISSION_ID ? 0 : 2 + (host.couchsubsStamp || 0);
      for (var i = 0; i < list.length; i++) parts.push({ el: list[i], layer: id, rank: rank });
    }
    parts.sort(function (a, b) { return a.rank - b.rank; });
    return parts;
  }

  // Altyazı yığınının ekrandaki kutuları (son satır, önceki satırlar, örtü); gizliyse boş.
  function subtitleRects() {
    var rects = [];
    var el = $('subtitle');
    if (!el || el.className === 'hidden') return rects;
    var ids = ['subtitle-text', 'subtitle-prev-text', 'subtitle-prev2-text', 'subtitle-cover'];
    for (var i = 0; i < ids.length; i++) {
      var part = $(ids[i]);
      if (!part || (ids[i] === 'subtitle-cover' && part.className === 'hidden')) continue;
      var r = pageRect(part.getBoundingClientRect());
      if (r.width > 0 && r.height > 0) rects.push({ left: r.left, top: r.top, right: r.right, bottom: r.bottom });
    }
    return rects;
  }

  function rectsMeet(a, b, gap) {
    return a.right > b.left && a.left < b.right && a.bottom + gap > b.top && a.top - gap < b.bottom;
  }

  // r kutusunun, placed içindeki başka katman kutularıyla kesişmeyen ve ekranda kalan en küçük dikey kayması.
  // Hiçbiri yoksa en az kutuyla kesişen ekran içi kayma (o da yoksa 0).
  function freeShift(r, layer, placed, gap, height) {
    var candidates = [0];
    for (var i = 0; i < placed.length; i++) {
      var o = placed[i].rect;
      if (placed[i].layer === layer || r.right <= o.left || r.left >= o.right) continue;
      candidates.push(Math.floor(o.top - gap - r.bottom), Math.ceil(o.bottom + gap - r.top));
    }
    candidates.sort(function (a, b) { return Math.abs(a) - Math.abs(b) || a - b; });
    var best = 0, bestHits = Infinity;
    for (var c = 0; c < candidates.length; c++) {
      var dy = candidates[c];
      if (r.top + dy < 0 || r.bottom + dy > height) continue;
      var moved = { left: r.left, right: r.right, top: r.top + dy, bottom: r.bottom + dy };
      var hits = 0;
      for (var j = 0; j < placed.length; j++) {
        if (placed[j].layer !== layer && rectsMeet(moved, placed[j].rect, gap)) hits++;
      }
      if (!hits) return dy;
      if (hits < bestHits) { best = dy; bestHits = hits; }
    }
    return best;
  }

  function avoidRegions() {
    var parts = regionParts();
    for (var i = 0; i < parts.length; i++) setShift(parts[i].el, 0);
    clearObjective();
    avoidPhone();
    if (!parts.length) return;
    var height = pageSize().height;
    var gap = Math.max(4, Math.round(height * AVOID_GAP));
    var placed = [];
    var fixed = subtitleRects();
    for (var f = 0; f < fixed.length; f++) placed.push({ rect: fixed[f], layer: 'subtitle' });
    var phone = phoneRect();
    if (phone) placed.push({ rect: phone, layer: 'game-phone' });
    for (var j = 0; j < parts.length; j++) {
      var el = parts[j].el;
      if (el.style.visibility === 'hidden') continue;
      var b = pageRect(el.getBoundingClientRect());
      if (!(b.width > 0) || !(b.height > 0)) continue;
      var r = { left: b.left, top: b.top, right: b.right, bottom: b.bottom };
      var dy = freeShift(r, parts[j].layer, placed, gap, height);
      setShift(el, dy);
      placed.push({ rect: { left: r.left, right: r.right, top: r.top + dy, bottom: r.bottom + dy }, layer: parts[j].layer });
    }
  }

  // --- Altyazı görev satırını örtmez ---
  // Bilgisayar ekrandaki görev satırının karedeki yerini gönderir ("objective" olayı; altyazıda "keep"). Kullanıcı
  // bildirimi (X, beta.100–104, GTA 6): "Örtsün"de iki satırlık Türkçe İngilizce satırın ortasına göre büyüyor, alttaki
  // görev satırının ("Get in the speedboat") üst yarısını örtüyordu. Altyazının son satırı ve örtüsü görev satırının (ve
  // yerindeki görev çevirisi kutusunun) üstüne kayar; "Altında"da çeviri İngilizce satırın üstüne geçer. Görev satırı
  // altyazının özgün yerinin ortasından yukarıdaysa (altyazı görevin kendisiyse) kayma olmaz. Eski bilgisayar göndermez.
  var objectiveBox = null;
  var objectiveShift = 0;

  function setObjective(box) {
    objectiveBox = validBox(box);
    diag.keep = objectiveBox ? Math.round(objectiveBox.top * 100) : null;
  }

  function clearObjective() {
    objectiveShift = 0;
    var el = $('subtitle');
    var cover = $('subtitle-cover');
    if (!el || !cover) return;
    cover.style.webkitTransform = '';
    cover.style.transform = '';
    setSubtitleShift(0, 0);
    if (!objectiveBox || SUBTITLE_BAND || el.className === 'hidden') return;
    var page = pageSize();
    var width = page.width;
    var height = page.height;
    var keep = screenBox(objectiveBox, isOverlay());
    var source = currentBox ? screenBox(currentBox, isOverlay()) : null;
    if (source && keep.top < (source.top + source.bottom) / 2) return;
    var top = keep.top * height;
    var line = (keep.bottom - keep.top) * height;
    // Görev satırının yerindeki Türkçesi (kehribar kutu) de örtülmez.
    var mission = regionBoxes[MISSION_ID];
    if (mission) {
      var list = mission.className === 'region-blocks' ? mission.children : [mission];
      for (var m = 0; m < list.length; m++) {
        if (list[m].style.visibility === 'hidden') continue;
        var r = pageRect(list[m].getBoundingClientRect());
        if (r.width > 0 && r.height > 0 && r.bottom > top && r.top >= top - 2 * line) top = Math.min(top, r.top);
      }
    }
    var limit = top - Math.max(4, Math.round(height * AVOID_GAP));
    var rects = [pageRect($('subtitle-text').getBoundingClientRect())];
    if (cover.className !== 'hidden') rects.push(pageRect(cover.getBoundingClientRect()));
    var upper = Infinity, bottom = -Infinity, left = Infinity, right = -Infinity;
    for (var i = 0; i < rects.length; i++) {
      var b = rects[i];
      if (!(b.width > 0) || !(b.height > 0)) continue;
      upper = Math.min(upper, b.top);
      bottom = Math.max(bottom, b.bottom);
      left = Math.min(left, b.left);
      right = Math.max(right, b.right);
    }
    if (!(bottom > limit) || right <= keep.left * width || left >= keep.right * width) return;
    var dy = limit - bottom;
    // "Altında": İngilizce satır ile görev satırı arasında yer yok; çeviri İngilizce satırın üstüne geçer.
    if (placement === 'below' && source && cover.className === 'hidden') {
      dy = Math.min(dy, source.top * height - Math.round(height * PLACE_GAP) - bottom);
    }
    if (upper + dy < 0) dy = -upper;
    if (dy >= 0) return;
    objectiveShift = Math.round(dy);
    setSubtitleShift(0, 0);
    if (cover.className !== 'hidden') {
      cover.style.webkitTransform = 'translateY(' + objectiveShift + 'px)';
      cover.style.transform = 'translateY(' + objectiveShift + 'px)';
    }
  }

  // --- Altyazı telefonun üstüne binmez ---
  // Oyun telefonunun çevirisi (game-phone) mesaj balonlarının üstünde, yerinde durur. Altyazı telefonla üst üste
  // binerse telefonun çevirisi okunmuyordu (X, beta.79: "telefon çevirisi altyazının altında kalıyor"). Altyazı telefonun
  // yanına (yazının sığdığı, daha geniş boş yana), sığmazsa telefonun üstüne ya da altına kayar; telefon kalkınca yerine
  // döner. Telefon kutusu balonların toplamıdır.
  var PHONE_GAP = 0.01;

  function phoneRect() {
    var host = regionBoxes['game-phone'];
    if (!host) return null;
    var list = host.className === 'region-blocks' ? host.children : [host];
    var rect = null;
    for (var i = 0; i < list.length; i++) {
      var r = pageRect(list[i].getBoundingClientRect());
      if (!(r.width > 0) || !(r.height > 0)) continue;
      rect = rect ? { left: Math.min(rect.left, r.left), top: Math.min(rect.top, r.top),
        right: Math.max(rect.right, r.right), bottom: Math.max(rect.bottom, r.bottom) }
        : { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
    }
    return rect;
  }

  function setSubtitleShift(dx, dy) {
    var el = $('subtitle');
    dy = (dy || 0) + objectiveShift;
    var value = dx || dy ? 'translate(' + Math.round(dx || 0) + 'px, ' + Math.round(dy) + 'px)' : '';
    el.style.webkitTransform = value;
    el.style.transform = value;
  }

  function avoidPhone() {
    var el = $('subtitle');
    if (!el || !$('subtitle-text')) return;
    setSubtitleShift(0, 0);
    var phone = el.className === 'hidden' ? null : phoneRect();
    if (!phone) return;
    var sub = pageRect($('subtitle-text').getBoundingClientRect());
    if (!(sub.width > 0) || !(sub.height > 0)) return;
    var width = pageSize().width;
    var height = pageSize().height;
    var gap = Math.max(4, Math.round(width * PHONE_GAP));
    if (sub.right + gap <= phone.left || sub.left - gap >= phone.right ||
        sub.bottom + gap <= phone.top || sub.top - gap >= phone.bottom) return;
    var margin = Math.round(width * SIDE_MIN);
    var roomLeft = phone.left - gap - margin;
    var roomRight = width - margin - phone.right - gap;
    var fitsLeft = sub.width <= roomLeft;
    var fitsRight = sub.width <= roomRight;
    if (fitsLeft || fitsRight) {
      var left = fitsLeft && (!fitsRight || roomLeft >= roomRight);
      setSubtitleShift(left ? phone.left - gap - sub.right : phone.right + gap - sub.left, 0);
      return;
    }
    // Yanda yer yok: telefonun üstüne, olmazsa altına; ikisi de ekran dışındaysa yerinde kalır.
    var up = phone.top - gap - sub.bottom;
    var down = phone.bottom + gap - sub.top;
    if (sub.top + up >= 0) setSubtitleShift(0, up);
    else if (sub.bottom + down <= height) setSubtitleShift(0, down);
  }

  // Ömrü dolan alanları kaldırır (telefon kartı hariç: onu gönderici kendisi kaldırır). Kaldırılanların kimlikleri döner.
  function expireRegions(now) {
    var gone = [];
    for (var id in regionBoxes) {
      if (!Object.prototype.hasOwnProperty.call(regionBoxes, id) || id === 'game-phone') continue;
      if (now - (regionBoxes[id].couchsubsSeen || 0) >= REGION_LIFE_MS) gone.push(id);
    }
    for (var i = 0; i < gone.length; i++) hideRegion(gone[i]);
    return gone;
  }

  // TV yeniden bağlandı: gönderici o an gösterdiği alanların kimliklerini yollar ("region-sync"), ardından her birini
  // "keep" ile yeniden gönderir. Listede olmayan alan (kopukken kaçan temizleme komutu) kalkar.
  function syncRegions(data) {
    var ids = data && Array.isArray(data.ids) ? data.ids : [];
    var gone = [];
    for (var id in regionBoxes) {
      if (Object.prototype.hasOwnProperty.call(regionBoxes, id) && ids.indexOf(id) < 0) gone.push(id);
    }
    for (var i = 0; i < gone.length; i++) hideRegion(gone[i]);
    return gone;
  }

  function hideRegions() {
    for (var id in regionBoxes) {
      if (Object.prototype.hasOwnProperty.call(regionBoxes, id)) $('regions').removeChild(regionBoxes[id]);
    }
    regionBoxes = {};
    $('regions').className = 'hidden';
    resolveLayers();
    avoidRegions();
  }

  // Konum hem CouchSubs uygulamasından hem kumandanın oklarıyla ayarlanır. Kumandayla
  // seçilen konum, uygulamadaki ayar değişene kadar korunur (son değiştiren geçerlidir).
  // Alttan en az %3: ekran kenarı taşan (overscan) TV'lerde altyazının alt satırı kesilmesin.
  var BOTTOM_MIN_PERCENT = 3;

  // Tizen 2.3 (2015 Samsung, #761): HDMI penceresi sayfanın önünde, ekranın üst kısmında; çeviri alttaki şeritte kalır
  // (platform.subtitleBand, ekran yüksekliğinin yüzdesi). Şeridi olmayan platformda 0.
  var SUBTITLE_BAND = Number(platform.subtitleBand) || 0;

  function setBottom(percent) {
    var top = SUBTITLE_BAND ? Math.max(BOTTOM_MIN_PERCENT, SUBTITLE_BAND - 15) : 85;
    bottomPercent = Math.max(BOTTOM_MIN_PERCENT, Math.min(top, percent));
    layout();
  }

  var SIDE_MIN = 0.05;
  var PLACE_GAP = 0.024;

  // Altyazıyı seçilen yerleşime göre konumlar. İngilizce altyazının yeri bilinmiyorsa sabit yükseklik kullanılır.
  function layout() {
    var el = $('subtitle');
    var cover = $('subtitle-cover');
    // Şeritli platformda oyundaki altyazının yeri pencerenin içinde kalır, oraya çizilen çeviri görünmezdi: hep şerit.
    var box = placement === 'fixed' || !currentBox || SUBTITLE_BAND ? null : screenBox(currentBox, isOverlay());
    el.style.left = '8%';
    el.style.right = '8%';
    el.style.top = 'auto';
    el.style.bottom = bottomPercent + '%';
    cover.className = 'hidden';
    $('subtitle-text').style.background = ownBackground();
    $('subtitle-text').style.marginTop = '';
    // Altyazı yokken (ör. ayar değişince yeniden yerleşirken) örtü tek başına boş siyah kutu olarak kalmasın.
    if (!box || el.className === 'hidden') return avoidRegions();

    var height = pageSize().height;
    // "Üstünde"/"Altında": çevirinin kutusu ile İngilizce satır arasında ekran yüksekliğinin %2,4'ü (1080'de 26 piksel,
    // 46 piksellik yazıda satır yüksekliğinin ~%45'i) boşluk. Eskiden %1,2 (13 piksel) idi; oyunun bildirdiği kutu harflere
    // sıkı oturduğundan çevirinin zemini İngilizce yazıya değiyormuş gibi görünüyordu (X, beta.90). OBS katmanı ile aynı.
    var gap = Math.round(height * PLACE_GAP);
    var mode = placement;
    // Ekranın kenarında yer yoksa öbür yana geçilir.
    if (mode === 'below' && box.bottom > 0.88) mode = 'above';
    if (mode === 'above' && box.top < 0.12) mode = 'below';

    // Yatayda İngilizce satırın ortasına hizalanır; yanlarda güvenli alan (1920'de 96 piksel, %5) kadar boşluk kalır.
    var center = (box.left + box.right) / 2;
    var half = Math.max(0.3, Math.min(center, 1 - center));
    el.style.left = (Math.max(SIDE_MIN, center - half) * 100) + '%';
    el.style.right = (Math.max(SIDE_MIN, 1 - center - half) * 100) + '%';

    if (mode === 'cover') {
      // İngilizce yazı koyu bir zeminle örtülür, çeviri onun ortasına gelir.
      var middle = (1 - (box.top + box.bottom) / 2) * height;
      el.style.bottom = Math.max(0, Math.round(middle - $('subtitle-text').offsetHeight / 2)) + 'px';
      var textRect = pageRect($('subtitle-text').getBoundingClientRect());
      placeCover(cover, box, textRect);
      // Zemini örtü verir; çevirinin kendi yarı saydam zemini örtünün üstünde ikinci bir kutu gibi görünmesin.
      $('subtitle-text').style.background = 'transparent';
      liftPrevious(cover, textRect);
    } else if (mode === 'above') {
      // Katmanda TV resmi büyütüp büyütmediği bilinmez (OVERLAY_ZOOM): iki yerin de üstünde kalınır, çakışma olmaz.
      el.style.bottom = Math.round((1 - Math.min(box.top, currentBox.top)) * height + gap) + 'px';
    } else {
      el.style.bottom = 'auto';
      el.style.top = Math.round(Math.max(box.bottom, currentBox.bottom) * height + gap) + 'px';
    }
    keepOnScreen(el, cover);
    avoidRegions();
  }

  // Örtü İngilizce satırın kutusunu (biraz paylı) kaplar. Türkçe daha uzun ya da daha çok satırsa örtü çevirinin
  // kutusunu da içine alacak kadar büyür: eskiden çevirinin yarı saydam zemini siyah örtüden taşıyor, ekranda boyları
  // farklı iki kutu görünüyordu. Örtü çevirinin zeminini tamamen kapladığından ikisi tek bir siyah kutu gibi görünür.
  var COVER_PAD = 0.012;

  // Katman modu (Android TV, #473): HDMI'yı CouchSubs değil TV'nin kendi giriş ekranı çizer ve resmi çoğu TV'de kenar
  // taşmasıyla (overscan) %5'e kadar büyütür. İngilizce satırın yeri bilgisayarın gördüğü karedeki yeridir; ekranda daha
  // geniş ve kenara doğru kaymış durur. Örtü kareye göre çizilince İngilizce satırdan dar kalıyor, yazı yanlardan
  // görünüyordu (arka plan "Tam" olsa da saydam sanılıyordu). Uygulama içinde (TvView) resim büyütülmez; orada değişmez.
  var OVERLAY_ZOOM = 1.05;
  var OVERLAY_PAD = 0.01;

  function isOverlay() {
    return (' ' + ((document.body && document.body.className) || '') + ' ').indexOf(' overlay ') >= 0;
  }

  // Karedeki kutunun ekrandaki yeri: katmanda ekran ortasına göre büyütülmüş, uygulama içinde aynı.
  function screenBox(box, overlay) {
    if (!overlay) return box;
    function at(value) { return Math.max(0, Math.min(1, 0.5 + (value - 0.5) * OVERLAY_ZOOM)); }
    return { left: at(box.left), top: at(box.top), right: at(box.right), bottom: at(box.bottom) };
  }

  // Örtünün kapladığı alan (ekranın oranı olarak): satırın kutusu ve iki yanında pay. Katmanda pay biraz daha geniştir:
  // TV resmi hiç büyütmese de büyütülmüş kutu ile bu pay İngilizce satırı yine kaplar.
  function coverBounds(box, overlay) {
    var pad = COVER_PAD + (overlay ? OVERLAY_PAD : 0);
    return { left: box.left - pad, top: box.top - pad, right: box.right + pad, bottom: box.bottom + pad };
  }

  function placeCover(cover, box, text) {
    var width = pageSize().width;
    var height = pageSize().height;
    var bounds = coverBounds(box, isOverlay());
    var left = bounds.left * width;
    var top = bounds.top * height;
    var right = bounds.right * width;
    var bottom = bounds.bottom * height;
    if (text && text.width > 0 && text.height > 0) {
      left = Math.min(left, text.left);
      top = Math.min(top, text.top);
      right = Math.max(right, text.right);
      bottom = Math.max(bottom, text.bottom);
    }
    // Tam genişlik bandı: oyundaki İngilizce yazı yan yana taşsa da görünmesin diye örtü ekranın iki kenarına uzanır.
    if (bandShape) { left = 0; right = width; }
    cover.style.left = Math.round(left) + 'px';
    // Çeviri gibi alttan konumlanır: sayfanın yüksekliği sonradan değişirse (Android TV ölçeklemesi) ikisi birlikte kayar.
    cover.style.top = 'auto';
    cover.style.bottom = Math.round(height - bottom) + 'px';
    cover.style.width = Math.round(right - left) + 'px';
    cover.style.height = Math.round(bottom - top) + 'px';
    // Örtü her koyulukta tam opaktır (ownBackground); koyuluğu göndermeyen eski sürümlerde style.css'teki opak siyah.
    cover.style.background = coverBackground;
    cover.className = '';
  }

  // Bazı TV'lerde (Samsung, Android TV) sayfanın bildirdiği yükseklik ekranla uyuşmayabiliyor; altyazı ekranın
  // dışına düşerse hiç görünmüyordu. Yerleştirilen altyazı görünür alanda değilse sabit yüksekliğe döner.
  function keepOnScreen(el, cover) {
    var rect = pageRect(el.getBoundingClientRect());
    var viewHeight = pageSize().height;
    var viewWidth = pageSize().width;
    var visible = rect.height > 0 && rect.top >= -2 && rect.bottom <= viewHeight + 2 && rect.right > 0 && rect.left < viewWidth;
    if (visible) return;
    el.style.left = '8%';
    el.style.right = '8%';
    el.style.top = 'auto';
    el.style.bottom = bottomPercent + '%';
    cover.className = 'hidden';
    $('subtitle-text').style.background = ownBackground();
    $('subtitle-text').style.marginTop = '';
  }

  // "Örtsün"de önceki satırlar örtünün üstünde durur. Örtü İngilizce altyazının kutusu kadardır; aynı anda konuşan iki üç
  // kişinin İngilizcesi (çok satırlı altyazı) Türkçeden yüksekse örtü Türkçenin üstüne taşar, üste yığılan önceki satırlar
  // örtünün içine biniyordu (X, burakgr0, beta.102 sonrası: "hala ufaktan birbirine karışıyor"). Son satırın üst payı
  // örtünün taşan kısmı kadar büyür: yığın yukarı kayar, son satırın kendi yeri değişmez (yığın alttan konumlanır).
  function liftPrevious(cover, textRect) {
    var coverRect = pageRect(cover.getBoundingClientRect());
    if (!textRect || !coverRect || !(coverRect.height > 0)) return;
    var lift = Math.ceil(textRect.top - coverRect.top);
    $('subtitle-text').style.marginTop = lift > 0 ? lift + 'px' : '';
  }

  // Çevirinin kendi zemini. "Örtsün"de (örtü çizilemeyen, yeri gelmeyen satırda da) zemin hep tam opaktır: oyundaki
  // altyazıyı kapatmak bu yerleşimin işi. Eskiden örtü ve bu zemin "Zemin koyuluğu"nu izliyordu (#225); varsayılan %72'de
  // ve kaydırıcı düşükken İngilizce satır Türkçenin altından görünüyor, test yazısı zeminsiz kalıyordu (X, MertTurna19, TV).
  // Saydam zemin isteyen "Üstünde"/"Altında"/"Sabit"i seçer; orada koyuluk aynen geçerlidir. "Zeminsiz" (koyuluk 0) her
  // yerleşimde zeminsizdir (coverBackground 'transparent').
  function ownBackground() {
    return placement === 'cover' && !SUBTITLE_BAND ? coverBackground || 'rgb(0, 0, 0)' : textBackground;
  }

  // Çevirinin zemini (bilgisayardaki "Zemin koyuluğu"); boşsa style.css'teki varsayılan. Örtü varken saydam olur.
  var textBackground = '';

  // Örtünün zemini: seçilen zemin renginde, koyuluktan bağımsız tam opak (boşsa style.css'teki opak siyah) ve tam genişlik
  // bant mı; eski bilgisayar uygulamaları alanı göndermez, yazı kadar kalır.
  var coverBackground = '';
  var bandShape = false;

  // body'deki tek bir sınıfı açar ya da kapatır; diğerleri kalır. Eskiden className baştan yazılıyordu ve Android TV
  // katmanının 'overlay' sınıfı ilk style olayında siliniyordu.
  function setBodyClass(name, on) {
    var body = document.body;
    if (!body) return;
    var rest = (' ' + body.className + ' ').replace(' ' + name + ' ', ' ');
    body.className = (on ? rest + name : rest).replace(/^\s+|\s+$/g, '').replace(/\s+/g, ' ');
  }

  // Bilgisayardaki "Yazı rengi" seçimi; bilinmeyen değer gelirse renk değişmez.
  var TEXT_COLORS = { white: '#FFFFFF', yellow: '#FFE135' };

  // Zemin "Koyu" (%100) mü ve rengi ne. Koyu zeminde önceki satırların kutusu da tam opaktır; soluklaştırma yalnız
  // yazıya uygulanır (aşağıda dimmedColor). Eskiden kutunun kendisi %75/%60 saydamlaşıyor (style.css, #subtitle-prev
  // opacity) ve zemin ayrıca %83'e iniyordu: OLED'de karanlık sahnede önceki satırlar gri kutu gibi görünüyordu.
  var solidBackground = false;
  var backgroundRgb = [0, 0, 0];
  var textColorValue = '#FFFFFF';
  // Önceki satırların soluklukları (style.css'teki #subtitle-prev / #subtitle-prev2 opaklığıyla aynı).
  var PREVIOUS_DIM = { 'subtitle-prev-text': 0.75, 'subtitle-prev2-text': 0.6 };

  // Siyah seçeneği (#101014) ve eski varsayılan (#0c0e12) TV'de saf siyah (#000) çizilir. OLED'de piksel kapanır;
  // 16/16/20 gibi "neredeyse siyah" ise karanlık sahnede ve HDR'de oyunun gerçek siyahının üstünde gri kalkıyordu.
  // Lacivert, koyu gri gibi renkli seçenekler olduğu gibi kalır.
  function tvBackgroundRgb(rgb) {
    return Math.max(rgb[0], rgb[1], rgb[2]) <= 24 ? [0, 0, 0] : rgb;
  }

  // Koyu zeminde önceki satırın yazı rengi: kutu opak kaldığı için soluklaştırma, rengin zemine doğru karıştırılmasıyla
  // yapılır (opak zeminde opaklıkla aynı sonuç). Koyu değilse ya da renk "#RRGGBB" değilse renk olduğu gibi kalır;
  // o zaman soluklaştırmayı style.css'teki opaklık yapar.
  function dimmedColor(id, color) {
    var factor = PREVIOUS_DIM[id];
    var rgb = hexRgb(color);
    if (!solidBackground || !factor || !rgb) return color;
    var mixed = [];
    for (var i = 0; i < 3; i++) mixed.push(Math.round(backgroundRgb[i] + (rgb[i] - backgroundRgb[i]) * factor));
    return 'rgb(' + mixed.join(', ') + ')';
  }

  // Önceki satırların yazı ve konuşan adı renklerini güncel zemine göre yeniden boyar (ayar değişince).
  function paintPreviousColors() {
    for (var id in PREVIOUS_DIM) {
      if (!PREVIOUS_DIM.hasOwnProperty(id)) continue;
      var el = $(id);
      el.style.color = dimmedColor(id, textColorValue);
      var spans = el.getElementsByTagName('span');
      for (var i = 0; i < spans.length; i++) {
        if (spans[i].baseColor) spans[i].style.color = dimmedColor(id, spans[i].baseColor);
      }
    }
  }

  // "#RRGGBB" → [r, g, b]; geçersizse null.
  function hexRgb(hex) {
    if (typeof hex !== 'string' || !/^#[0-9A-Fa-f]{6}$/.test(hex)) return null;
    var value = parseInt(hex.slice(1), 16);
    return [(value >> 16) & 255, (value >> 8) & 255, value & 255];
  }

  function applyStyle(style) {
    if (style.fontSize) {
      fontBase = style.fontSize;
      $('subtitle-text').style.fontSize = style.fontSize + 'px';
      // Önceki satırlar %80 boyda; konuşma satırı alt sınırının altına inmez (#1255).
      var previous = Math.max(dialogueMinFont(), Math.round(style.fontSize * 0.8));
      $('subtitle-prev-text').style.fontSize = previous + 'px';
      $('subtitle-prev2-text').style.fontSize = previous + 'px';
    }
    if (PLACEMENTS[style.placement]) placement = style.placement;
    bandShape = style.backgroundShape === 'band';
    // "Ekran yazılarını altyazıdan ayır" (alanı göndermeyen eski bilgisayarda açık).
    setApart = style.setApart !== false;
    setBodyClass('band', bandShape);
    if (typeof style.background === 'number') {
      var alpha = Math.max(0, Math.min(100, style.background)) / 100;
      // Zemin saydamsa yazıya sert kontur eklenir (style.css, body.thin-bg).
      // "Zeminsiz" (koyuluk 0) "Örtsün"de de zeminsizdir; o zaman yazıya kontur eklenir.
      setBodyClass('thin-bg', alpha < 0.5 && (placement !== 'cover' || alpha === 0));
      // Yeni arayüz zemin rengini gönderir (style.backgroundColor, "#RRGGBB"); göndermeyen bilgisayarda siyah.
      // Siyah seçeneği saf siyah çizilir (tvBackgroundRgb).
      var rgb = tvBackgroundRgb(hexRgb(style.backgroundColor) || [0, 0, 0]);
      var base = rgb[0] + ', ' + rgb[1] + ', ' + rgb[2];
      backgroundRgb = rgb;
      // "Koyu" (%100): bütün kutular (önceki satırlar ve örtü dahil) tam opak; yarı saydam katman kalmaz.
      solidBackground = style.background >= 100;
      setBodyClass('solid-bg', solidBackground);
      textBackground = solidBackground ? 'rgb(' + base + ')' : 'rgba(' + base + ', ' + alpha + ')';
      // "Zeminsiz" seçildiyse örtü de çizilmez (beta.105, #1378: zeminsiz seçim tam opak kutuya dönüyordu, X).
      coverBackground = alpha > 0 ? 'rgb(' + base + ')' : 'transparent';
      var previousBackground = solidBackground ? textBackground : 'rgba(' + base + ', ' + (alpha * 0.83).toFixed(2) + ')';
      $('subtitle-text').style.background = ownBackground();
      $('subtitle-prev-text').style.background = previousBackground;
      $('subtitle-prev2-text').style.background = previousBackground;
    }
    speakerNameOnly = style.nameOnly === true;
    speakerWholeLine = style.wholeLine === true;
    // Ayarı göndermeyen bilgisayar (eski Windows sürümü, Mac) eski davranışı bekler: önceki satırlar üstte kalır.
    // Yoksa bir kez kapatılan ayar başka bilgisayara bağlanınca da kapalı kalırdı.
    stackPrevious = typeof style.stackPrevious === 'boolean' ? style.stackPrevious : true;
    save('stackPrevious', stackPrevious ? '1' : '0');
    if (!stackPrevious) hidePrevious();
    if (typeof style.bold === 'boolean') {
      $('subtitle-text').style.fontWeight = style.bold ? '700' : '400';
      $('subtitle-prev-text').style.fontWeight = style.bold ? '700' : '400';
      $('subtitle-prev2-text').style.fontWeight = style.bold ? '700' : '400';
    }
    // Yeni arayüzün yazı rengi (style.textHex) eski beyaz/sarı seçiminin önüne geçer.
    var textColor = hexRgb(style.textHex) ? style.textHex : TEXT_COLORS[style.textColor];
    if (textColor) {
      textColorValue = textColor;
      $('subtitle-text').style.color = textColor;
    }
    paintPreviousColors();
    // Ekrandaki yazı yeni ayarlarla yeniden bölünür: yazı boyu, kalınlık, yerleşim ve bant bölmeyi değiştirir.
    var shown = rawText('subtitle-text');
    if ($('subtitle-text').rawText !== undefined && shown) setLineText('subtitle-text', shown, !!shownParagraphs, fontBase, $('subtitle-text').speakers);
    layout();
    // Kurulumda bilgisayarda seçilen TV girişi: yalnız değer değişince açılır (TV'de elle seçilen giriş ezilmez).
    if (style.hdmiInput >= 1 && style.hdmiInput <= 4 && String(style.hdmiInput) !== load('appHdmi')) {
      save('appHdmi', style.hdmiInput);
      chooseHdmiFromComputer(Number(style.hdmiInput));
    }
    if (style.bottomPercent >= 0 && String(style.bottomPercent) !== load('appBottom')) {
      save('appBottom', style.bottomPercent);
      save('bottom', '');
      setBottom(style.bottomPercent);
    }
  }

  function nudgeSubtitle(step) {
    // Yer oyundaki altyazıya bağlıysa kumandayla taşınmaz.
    if (placement !== 'fixed' && !SUBTITLE_BAND) return;
    setBottom(bottomPercent + step);
    save('bottom', bottomPercent);
    // Nereye gittiği görülsün diye yazı yoksa örnek gösterilir.
    if ($('subtitle').className === 'hidden') showSubtitle(t('positionPreview'), 2500);
  }

  // --- Sunucu bağlantısı (Server-Sent Events) ---

  // Kapatılan (yerine yenisi açılan ya da arka planda bırakılan) akıştan geç gelen olay yok sayılır: eski bilgisayarın
  // altyazısı yeni bilgisayarınkinin üstüne yazılmaz.
  function onEvent(name, handler) {
    var source = eventSource;
    source.addEventListener(name, function (e) {
      if (source !== eventSource) return;
      lastActivity = Date.now();
      var data;
      try {
        data = JSON.parse(e.data);
      } catch (err) {
        noteError(name + ': bad json');
        return;
      }
      try {
        handler(data);
      } catch (err) {
        noteError(name + ': ' + err.message);
      }
    });
  }

  var connectionGeneration = 0;
  var pairingTimer = null;
  // Eşleştirme kodu ekranda beklerken tarama aynı adresi bulursa bağlantı baştan kurulmaz (kod kaybolmasın).
  var pairingActive = false;
  // Reddedilen eşleştirme kendiliğinden yeniden başlamaz (bilgisayarda/telefonda pencere art arda açılırdı); Tamam ile
  // yeniden denenir.
  var pairingFailed = false;
  function stopPairing() { pairingActive = false; pairingFailed = true; setPairing(t('pairRetry')); }
  // Süresi dolan ya da telefonda/bilgisayarda düşen istek (çeviri durdurulup başlatıldı, uygulama yeniden açıldı, iki
  // dakikada onaylanmadı) ve ulaşmayan istek kendiliğinden yeniden gönderilir (GitHub #737). Eskiden TV "Eşleştirme
  // tamamlanmadı, Tamam'a basın"da kalıyor, yeni istek göndermiyordu; telefonda çeviri sürse de onay penceresi hiç
  // çıkmıyordu.
  var PAIR_RETRY_MS = 3000;
  // Art arda yanıtsız kalan (ya da bozuk yanıt alan) eşleştirme isteği sayısı. GitHub #1058 (LG UK6470, iPhone): istek
  // telefona ulaşmadığında TV birkaç saniyede bir sessizce yeniden deniyor, bu arada kod olmadan "Bu kodu telefon/
  // bilgisayarda karşılaştırıp onaylayın" yazıyordu; kullanıcı olmayan kodu arıyordu. Artık kod gelene kadar "kod
  // isteniyor" yazar; ikinci yanıtsız denemeden sonra ne yapılacağı ve nedeni (tanı için) görünür.
  var pairMisses = 0;
  var PAIR_MISSES_BEFORE_HINT = 2;
  // failure: isteğin neden tamamlanmadığı ("pair 0": yanıt yok, "pair 500": bozuk yanıt); yoksa kodun süresi doldu ya
  // da istek telefonda düştü (yanıt geldi, yeni kod istenir).
  function notePairMiss(failure) {
    if (failure) {
      pairMisses++;
      noteError(failure);
    } else pairMisses = 0;
    setPairing(pairMisses >= PAIR_MISSES_BEFORE_HINT ? t('pairNoAnswer') + ' [' + failure + ']' : t('pairAsking'));
  }
  function retryPairing(address, generation, ms, failure) {
    pairingActive = false;
    pairingFailed = false;
    notePairMiss(failure);
    clearTimeout(pairingTimer);
    pairingTimer = setTimeout(function () { if (generation === connectionGeneration) connect(address); }, ms || PAIR_RETRY_MS);
  }
  // Eşleştirme kodu ve yönlendirmesi bekleme kutusunun dışında, her şeyin üstünde durur (X @Eaglaris, 20 Kas: Android
  // TV'de kod hiç görünmedi, bilgisayarda onaylayınca bağlandı). Kod bekleme kutusunun içindeydi; o kutu katman modunda
  // hep gizli (tv-android/platform.js), panel ya da "görüntü yok" kutusu açılınca da gizleniyor ve bağlanılacak adres
  // bilindiği için geri gelmiyordu. Yazı boş olana kadar (onay, süre dolması) görünür kalır.
  function setPairing(text) {
    var el = $('pairing');
    el.textContent = text;
    el.className = text ? '' : 'hidden';
  }
  function pairRequest(method, address, path, done) {
    var xhr = new XMLHttpRequest(), finished = false;
    function finish(data, status) { if (finished) return; finished = true; done(data, status || 0); }
    xhr.onload = function () {
      var data = null;
      if (xhr.status === 200) { try { data = JSON.parse(xhr.responseText); } catch (e) {} }
      finish(data, xhr.status);
    };
    xhr.onerror = xhr.ontimeout = function () { finish(null); };
    try { xhr.open(method, address + path); xhr.timeout = 4000; xhr.send(); }
    catch (e) { finish(null); }
  }
  function connect(address) {
    address = address.replace(/\/+$/, '');
    var generation = ++connectionGeneration;
    clearTimeout(pairingTimer);
    pairingActive = false;
    pairingFailed = false;
    // Arka plandayken bağlanılmaz; adres akılda tutulur, uygulama öne gelince bağlanır (bkz. dropWhileHidden).
    if (pausedByHidden) {
      server = address;
      return;
    }
    if (eventSource) eventSource.close();
    eventSource = null;
    if (address !== server) {
      failures = 0;
      // Never replay an old server's subtitle when the newly selected stream opens.
      lastLine = null;
      hideSubtitle('server-change');
    }
    server = address;
    pairRequest('GET', address, '/hello', function (hello, status) {
      if (generation !== connectionGeneration) return;
      if (!hello || hello.app !== 'couchsubs') {
        // Eşleştirme sürerken CouchSubs yanıt vermez olduysa (telefonda uygulama kapandı/arka plana düştü, adres
        // değişti) "kod isteniyor" yazısı takılı kalmaz; ağ taranırken ne yapılacağı görünür.
        var asking = $('pairing').textContent;
        if (asking && asking !== t('pairRetry') && asking !== t('pairClosed')) notePairMiss('hello ' + status);
        scanForServer();
        return;
      }
      // Do not restart discovery while waiting for human approval.
      cancelScan();
      if (hello.auth !== 1) { connectStream(address); return; }
      var identities;
      try { identities = JSON.parse(load('server-identities') || '{}'); } catch (e) { identities = {}; }
      // Kimlik, /hello'daki kurulum kimliğidir (GitHub #425; bilgisayarı seçmek için de kullanılır).
      var identity = /^[A-Za-z0-9-]{1,64}$/.test(hello.id || '') ? hello.id : '';
      var saved = identity && identities[identity];
      // Aynı sunucu DHCP ile taşınmışsa eski onay kullanılabilir. Anahtar yenilendiyse eski anahtar doğrulanmaz ve
      // TV yeniden eşleşme ister.
      if (saved) saveServerKey(address, saved);
      var key = serverKey(address);
      if (key) {
        pairRequest('GET', address, '/pair?validate=1&k=' + encodeURIComponent(key), function (result, status) {
          if (generation !== connectionGeneration) return;
          if (result && result.state === 'valid') { remember(key); connectStream(address); }
          // Yanıt gelmedi (ağ bir an koptu, sunucu yeniden açılıyor): anahtar geçerli olabilir, boşuna onay istenmez.
          else if (!status) retryPairing(address, generation, 5000, 'validate 0');
          else beginPair();
        });
      } else beginPair();
      function remember(value) {
        saveServerKey(address, value);
        if (identity) { identities[identity] = value; save('server-identities', JSON.stringify(identities)); }
      }
      function beginPair() {
        pairingActive = true;
        $('waiting').className = '';
        // Eşleştirmeye kapalı sunucuya ya da yanıt vermeyen isteğe yeniden denerken yönlendirme yazısı her denemede silinip
        // gelmesin. Kod gelmeden "bu kodu karşılaştırın" yazılmaz (#1058).
        if (pairMisses < PAIR_MISSES_BEFORE_HINT && $('pairing').textContent !== t('pairClosed')) setPairing(t('pairAsking'));
        pairRequest('POST', address, '/pair', function (ticket, status) {
          if (generation !== connectionGeneration) return;
          if (status === 409) {
            // Bilgisayar/telefon şu an eşleştirme kabul etmiyor (çeviri sürmüyor, "TV eşleştir" açılmamış ya da başka
            // istek bekliyor). "Eşleştirme tamamlanmadı, Tamam'a basın" yazıp Tamam'ı boşa bastırmak yerine ne yapılacağı
            // söylenir ve birkaç saniyede bir kendiliğinden yeniden denenir; onay penceresi açılınca kod hemen çıkar.
            pairingActive = false;
            pairingFailed = true;
            pairMisses = 0;
            setPairing(t('pairClosed'));
            pairingTimer = setTimeout(function () { if (generation === connectionGeneration) connect(address); }, 5000);
            return;
          }
          if (!ticket || !/^[A-Za-z0-9_-]{22}$/.test(ticket.id || '') || !/^[0-9]{6}$/.test(ticket.code || '')) {
            // İstek ulaşmadı ya da yanıt bozuk: "tamamlanmadı" denmez, birkaç saniye sonra yeniden denenir.
            retryPairing(address, generation, 5000, 'pair ' + status);
            return;
          }
          var deadline = Date.now() + 120000;
          pairMisses = 0;
          setPairing(t('pairCode') + ' ' + ticket.code + ' — ' + t('pairServer'));
          setStatus('st-conn', t('pairCode') + ' ' + ticket.code, 'muted');
          function poll() {
            if (generation !== connectionGeneration) return;
            if (Date.now() >= deadline) { retryPairing(address, generation); return; }
            pairRequest('GET', address, '/pair?id=' + encodeURIComponent(ticket.id), function (result) {
              if (generation !== connectionGeneration) return;
              if (result && result.state === 'approved' && /^[A-Za-z0-9_-]{22}$/.test(result.key || '')) {
                remember(result.key); setPairing(''); connectStream(address); return;
              }
              // Reddedildi: Tamam beklenir. Süresi doldu ya da istek düştü: yeni istek gönderilir.
              if (result && result.state === 'expired') {
                if (result.rejected === true) stopPairing(); else retryPairing(address, generation);
                return;
              }
              pairingTimer = setTimeout(poll, 1500);
            });
          }
          poll();
        });
      }
    });
  }

  function connectStream(address) {
    address = address.replace(/\/+$/, '');
    pairingActive = false;
    setPairing('');
    if (pausedByHidden) {
      server = address;
      return;
    }
    if (demoRunning()) stopDemo();
    if (eventSource) eventSource.close();
    eventSource = null;
    if (address !== server) failures = 0;
    server = address;
    $('waiting').className = 'hidden';
    setStatus('st-server', address);
    if (!window.EventSource) {
      setStatus('st-conn', t('noEventSource'), 'bad');
      return;
    }
    setStatus('st-conn', t('connecting'), 'muted');
    streamPort = shownPort;
    // Sürüm (v) akışla bildirilir: bilgisayar ve telefon TV'deki uygulamanın eski kaldığını LG geliştirici moduna
    // bağlanamasa da bununla anlar ve "TV uygulamasını güncelle" der (GitHub #884, #891). 0.9.69'den eski TV
    // uygulamaları v göndermez; CouchSubs v'siz TV'yi eski sayar.
    eventSource = new EventSource(authenticatedUrl(address, '/events?v=' + APP_VERSION + (shownPort ? '&hdmi=' + shownPort : '')));
    lastActivity = Date.now();
    // Bu bağlantının akışı. Kapatılmış eski akışın sırada bekleyen geri çağrıları (onopen, onerror, ping, olaylar) yok
    // sayılır: eski akışın geç gelen hatası o anki bağlantı numarasını okuyup 5 sn sonra eski adrese yeniden bağlanıyordu.
    var source = eventSource;
    eventSource.onopen = function () {
      if (source !== eventSource) return;
      lastActivity = Date.now();
      failures = 0;
      clearTimeout(pairingTimer);
      cancelScan();
      clearTimeout(dropTimer);
      dropTimer = null;
      setStatus('st-conn', t('connected'), 'ok');
      learnServer(address);
      restoreLastLine();
      flushTvLog();
    };
    eventSource.onerror = function () {
      if (source !== eventSource) return;
      var failedGeneration = connectionGeneration;
      clearTimeout(pairingTimer);
      pairingTimer = setTimeout(function () { if (failedGeneration === connectionGeneration) connect(address); }, 5000);
      // Bağlantı kısa süre içinde geri gelmezse eski altyazı ekranda asılı kalmasın. Bir anlık kopma yazıyı silmez.
      diag.drops++;
      renderDiag();
      if (dropTimer === null) {
        dropTimer = setTimeout(function () {
          dropTimer = null;
          hideSubtitle('drop');
          hideScreen();
          hideRegions();
        }, DROP_HIDE_MS);
      }
      setStatus('st-conn', t('reconnecting'), 'bad');
      // Bilgisayarın adresi değişmiş ya da altyazı kaynağı başka cihaz olmuş olabilir.
      noteFailure();
    };
    // Bilgisayar 15 sn'de bir "ping" gönderir; gelmezse bağlantı yarı kopmuştur (bkz. watchConnection).
    linkId = null;
    eventSource.addEventListener('ping', function () {
      if (source !== eventSource) return;
      lastActivity = Date.now();
      pingSeen = true;
      sendAck();
    });
    // Yeni bilgisayar/telefon akışın kimliğini bildirir; TV her ping'de alındı gönderir (bkz. sendAck).
    onEvent('link', function (data) {
      linkId = /^[A-Za-z0-9]{1,64}$/.test(data.id || '') ? data.id : null;
      ackMisses = 0;
      senderLatest = /^[0-9.]{1,20}$/.test(data.latest || '') ? data.latest : '';
      renderVersion();
      renderDiag();
      sendAck();
    });
    onEvent('subtitle', function (data) {
      diag.subtitles++;
      renderDiag();
      if (!data.text) return;
      // Yeni bilgisayar/telefon `speakerNames` gönderir; eski sürüm `speakers` gönderir, o da yalnız adı boyar.
      var speakers = data.speakerNames || data.speakers;
      if (data.paragraphs !== true) setObjective(data.keep);
      showSubtitle(data.text, data.duration, data.box, data.paragraphs === true, data.replace === true,
        speakerMap(speakers));
      lastLine = { text: data.text, box: data.box, paragraphs: data.paragraphs === true, speakers: speakers, until: shownUntil };
    });
    onEvent('clear', function () {
      // Oyundaki satır kalktı: geri gelişte yeniden çizilmez (tutma süresi yine onClear'da).
      lastLine = null;
      onClear();
    });
    // Ekrandaki görev satırının yeri değişti (bkz. clearObjective).
    onEvent('objective', function (data) {
      setObjective(data.box);
      avoidRegions();
    });
    onEvent('screen', function (data) { showScreen(data.items, data.duration); });
    onEvent('screen-clear', hideScreen);
    onEvent('region', showRegion);
    onEvent('region-clear', hideRegions);
    onEvent('region-sync', syncRegions);
    onEvent('exit', function () { leaving = true; platform.exit(); });
    onEvent('style', applyStyle);
    onEvent('speech', function (data) { if (data.url && data.url.charAt(0) === '/' && data.url.charAt(1) !== '/') playSpeech(authenticatedUrl(server, data.url)); });
    onEvent('speech-stop', stopSpeech);
  }

  // --- Bağlantı bekçisi ---
  // Bazı TV'lerde bağlantı yarı kopar: EventSource "bağlı" görünür ama hiçbir şey gelmez, ya da kapanıp (CLOSED) bir daha
  // denemez. Altyazılar ancak kullanıcı uygulamaya dokununca geri geliyordu. Bekçi bu iki durumda bağlantıyı yeniden kurar.
  // Sessizlik sınırı yalnız ping gönderen bilgisayarlarda uygulanır (eski sürümler ping göndermez).

  var SILENCE_LIMIT_MS = 45000;
  var lastActivity = 0;
  var pingSeen = false;

  function watchConnection() {
    if (!server || !eventSource || demoRunning()) return;
    var closed = eventSource.readyState === 2;
    var silent = pingSeen && Date.now() - lastActivity > SILENCE_LIMIT_MS;
    if (closed || silent) {
      diag.drops++;
      renderDiag();
      pingSeen = false;
      connect(server);
    }
  }

  setInterval(watchConnection, 10000);
  setInterval(function () { expireRegions(Date.now()); }, 1000);

  // --- Alındı ---
  // Ping yalnız bilgisayardan/telefondan TV'ye gidiyordu: TV uygulaması arka plana düşüp askıya alınınca (LG, Android TV)
  // TV'nin ağ katmanı bağlantıyı açık tutuyor, telefon/bilgisayar saatlerce "Bağlı" gösteriyor ama altyazı ekrana
  // gelmiyordu (LG + iPhone, 20-25 dk sonra; CouchSubs'tan çıkıp girince düzeliyordu). Akış `link` olayıyla kimliğini
  // bildirirse TV her ping'de `/ack?c=<kimlik>` gönderir; alındı kesilince bilgisayar/telefon bağlantıyı kapatıp
  // "Yeniden bağlanılıyor" der, TV uygulamasını yeniden öne getirir. 404: bilgisayar bu akışı artık tanımıyor (yeniden
  // açıldı, bağlantıyı kopmuş saydı): TV beklemeden yeniden bağlanır. `link` göndermeyen eski sürümlere alındı gitmez.
  //
  // Alındı üst üste ACK_MISS_LIMIT kez ulaşmazsa (ağ hatası, zaman aşımı, 404 dışı hata) TV de yeniden bağlanır: bilgisayar
  // /telefon 3 alındısız ping turundan sonra akışı kapatıyor, TV ise bağlantıyı açık görüp "Bağlı" diyor ve bir daha
  // bağlanmıyordu (#1248, Samsung 2020; bilgisayar uygulamayı her 30-60 sn'de öne getirdiği halde). Sınır karşı tarafınkinden
  // (3) küçüktür: TV akış kapanmadan yenisini kurar.
  var linkId = null;
  var ACK_MISS_LIMIT = 2;
  var ackMisses = 0;

  function sendAck() {
    if (!linkId || !server || !eventSource) return;
    var id = linkId, source = eventSource, xhr = new XMLHttpRequest(), settled = false;
    function current() { return id === linkId && source === eventSource && !pausedByHidden; }
    function missed() {
      if (settled) return;
      settled = true;
      if (!current()) return;
      ackMisses++;
      if (ackMisses < ACK_MISS_LIMIT) return;
      ackMisses = 0;
      linkId = null;
      diag.drops++;
      renderDiag();
      connect(server);
    }
    xhr.onload = function () {
      if (settled) return;
      if (xhr.status === 404) {
        settled = true;
        if (!current()) return;
        ackMisses = 0;
        linkId = null;
        diag.drops++;
        renderDiag();
        connect(server);
        return;
      }
      if (xhr.status >= 200 && xhr.status < 300) {
        settled = true;
        if (current()) ackMisses = 0;
        return;
      }
      missed();
    };
    xhr.onerror = missed;
    xhr.ontimeout = missed;
    try { xhr.open('GET', authenticatedUrl(server, '/ack?c=' + encodeURIComponent(id))); xhr.timeout = 4000; xhr.send(); }
    catch (e) { missed(); }
  }

  // --- Türkçe dublaj ---
  // Bilgisayar her cümleyi seslendirip adresini gönderir; TV oyunun sesiyle birlikte çalar. Bilgisayar sıradakini
  // bu ses bitince gönderir; yine de üst üste gelirse eskisi kesilir.
  //
  // Ses Web Audio ile çalınır (katkı: Kadir Eker). <audio> öğesi TV'nin donanım medya oynatıcısını kullanır;
  // Samsung'da (TVWindow) ve LG'de (ext://hdmi) bu oynatıcı HDMI görüntüsüyle aynı yolu paylaştığından seslendirme
  // başlayınca oyun ekranı kararıyordu. Web Audio yalnız ses çıkışını kullanır. AudioContext olmayan ya da açılamayan,
  // sesi başlatmayan (askıda kalan) TV'de eski <audio> yoluna dönülür. Android TV sayfası <audio> ile çalar: HDMI'yi
  // TvView gösterir, karışmaz; platform.js de dublajı uygulama arka plandayken <audio> üzerinden susturur.
  //
  // Her cümlenin kaynağı bitince ayrılır; AudioContext bir süre boş kalınca kapatılır, sıradaki cümlede yeniden açılır.
  // <audio> yolunda her cümlenin oynatıcısı bitince, kesilince ya da hata verince bırakılır (src boşaltılıp load()).
  // Samsung'da duraklatılmış ya da bitmiş ama bırakılmamış oynatıcı sesi tutuyor, HDMI'deki oyunun ve PS5'in sesi
  // dublaj kapatılsa da uygulama kapanana dek gelmiyordu; açık kalan ses çıkışı aynı sorunu yapmasın.

  var SPEECH_FETCH_TIMEOUT_MS = 15000;
  var AUDIO_RESUME_WAIT_MS = 1500;
  var AUDIO_IDLE_MS = 10000;
  var speech = null; // çalan <audio>
  var speechSource = null; // çalan AudioBufferSourceNode
  var speechRequest = null;
  var speechToken = 0; // her yeni cümle ya da durdurma artırır; geç inen/çözülen eski ses çalınmaz
  var pendingToken = 0; // indirilip çözülmekte olan cümlenin numarası
  var audioContext = null;
  var audioIdleTimer = null;
  var webAudioFailed = false;

  function webAudio() {
    if (webAudioFailed || platform.speechElement) return null;
    if (audioContext) return audioContext;
    var Context = window.AudioContext || window.webkitAudioContext;
    if (!Context) return null;
    try { audioContext = new Context(); } catch (e) { audioContext = null; }
    return audioContext;
  }

  function playSpeech(url) {
    stopSpeech();
    clearTimeout(audioIdleTimer);
    var token = speechToken;
    var context = webAudio();
    if (!context) {
      diag.speechElement++;
      playSpeechElement(url);
      return;
    }
    diag.speechWeb++;
    pendingToken = token;
    var request = new XMLHttpRequest();
    speechRequest = request;
    var failed = function () {
      if (speechRequest === request) speechRequest = null;
      if (token !== speechToken) return;
      pendingToken = 0;
      idleAudio();
    };
    request.onload = function () {
      if (speechRequest === request) speechRequest = null;
      if (token !== speechToken) return;
      if (request.status !== 200 || !request.response) return failed();
      decodeSpeech(context, request.response, function (buffer) {
        if (token !== speechToken) return;
        pendingToken = 0;
        startSource(context, buffer, url, token);
      }, failed);
    };
    request.onerror = failed;
    request.ontimeout = failed;
    try {
      request.open('GET', url, true);
      request.responseType = 'arraybuffer';
      request.timeout = SPEECH_FETCH_TIMEOUT_MS;
      request.send();
    } catch (e) {
      failed();
    }
  }

  // Eski WebKit'te decodeAudioData söz (Promise) döndürmez; yenisinde hem geri çağrı hem söz çalışır, biri sayılır.
  function decodeSpeech(context, data, onDecoded, onFailed) {
    var settled = false;
    var ok = function (buffer) {
      if (settled) return;
      settled = true;
      onDecoded(buffer);
    };
    var fail = function () {
      if (settled) return;
      settled = true;
      onFailed();
    };
    try {
      var promise = context.decodeAudioData(data, ok, fail);
      if (promise && promise.then) promise.then(ok, fail);
    } catch (e) {
      fail();
    }
  }

  function startSource(context, buffer, url, token) {
    var source = null;
    try {
      source = context.createBufferSource();
      source.buffer = buffer;
      source.connect(context.destination);
      source.onended = function () { releaseSource(source); };
      speechSource = source;
      source.start(0);
    } catch (e) {
      if (source) releaseSource(source);
      fallBackToElement(url);
      return;
    }
    if (context.state !== 'suspended' || !context.resume) return;
    // TV otomatik oynatmaya izin vermedi ya da ses çıkışını açmadı: kısa sürede başlamazsa <audio>'ya dönülür.
    try {
      var resumed = context.resume();
      if (resumed && resumed.then) resumed.then(null, function () { /* aşağıdaki bekleme karar verir */ });
    } catch (e) { /* yok */ }
    setTimeout(function () {
      if (token !== speechToken || speechSource !== source || context.state !== 'suspended') return;
      releaseSource(source);
      fallBackToElement(url);
    }, AUDIO_RESUME_WAIT_MS);
  }

  function fallBackToElement(url) {
    webAudioFailed = true;
    closeAudio();
    playSpeechElement(url);
  }

  function releaseSource(source) {
    if (speechSource === source) speechSource = null;
    source.onended = null;
    try { source.disconnect(); } catch (e) { /* yok */ }
    idleAudio();
  }

  function idleAudio() {
    clearTimeout(audioIdleTimer);
    if (!audioContext) return;
    audioIdleTimer = setTimeout(function () {
      if (speechSource || pendingToken === speechToken) return;
      closeAudio();
    }, AUDIO_IDLE_MS);
  }

  function closeAudio() {
    clearTimeout(audioIdleTimer);
    var context = audioContext;
    if (!context) return;
    try {
      var result = null;
      if (context.close) {
        audioContext = null;
        result = context.close();
      } else if (context.suspend) {
        result = context.suspend();
      }
      if (result && result.then) result.then(null, function () { /* yok */ });
    } catch (e) {
      audioContext = null;
    }
  }

  function playSpeechElement(url) {
    var audio = null;
    try {
      audio = new Audio(url);
      speech = audio;
      audio.addEventListener('ended', function () { releaseSpeech(audio); });
      audio.addEventListener('error', function () { releaseSpeech(audio); });
      var played = audio.play();
      if (played && played.catch) played.catch(function () { releaseSpeech(audio); });
    } catch (e) {
      if (audio) releaseSpeech(audio);
      speech = null;
    }
  }

  function releaseSpeech(audio) {
    if (speech === audio) speech = null;
    if (audio.couchsubsReleased) return;
    audio.couchsubsReleased = true;
    try { audio.pause(); } catch (e) { /* yok */ }
    try {
      audio.removeAttribute('src');
      audio.load();
    } catch (e) { /* yok */ }
  }

  function stopSpeech() {
    speechToken++;
    if (speechRequest) {
      var request = speechRequest;
      speechRequest = null;
      try { request.abort(); } catch (e) { /* yok */ }
    }
    if (speechSource) {
      var source = speechSource;
      try { source.stop(0); } catch (e) { /* yok */ }
      releaseSource(source);
    }
    if (speech) releaseSpeech(speech);
    idleAudio();
  }

  // --- Bilgisayarı ağda bulma ---
  // Bilgisayar TV uygulamasını açamıyorsa adres gelmez; kayıtlı adres de eskiyebilir (altyazı kaynağı başka cihaz oldu
  // ya da cihazın IP'si değişti). Uygulama o zaman ağı tarar: TV'nin kendi ağını (adresini söyleyebiliyorsa) ve kayıtlı
  // adresin ağını. Kayıtlı adres art arda FAILS_BEFORE_SCAN kez yanıt vermezse tarama kısa süre içinde başlar.
  // Eskiden üç hata bekleniyordu (~10 sn); modem yeniden başlayıp gönderici yeni adres alınca altyazı o kadar geç dönüyordu.
  // Artık ilk hatadan sonra aranır. TV'nin ağı /24'ten büyükse (ör. /22, /23) TV'nin gerçek ağ maskesi kullanılır; tarama
  // en çok /22 (4 x 254 adres) ile sınırlıdır, daha geniş ağlarda TV'nin çevresindeki /22 taranır.

  var SERVER_PORT = 8787;
  var SCAN_PARALLEL = 24;
  var SCAN_TIMEOUT_MS = 1200;
  var SCAN_PAUSE_MS = 30000;
  var SCAN_SOON_MS = 3000;
  var FAILS_BEFORE_SCAN = 1;
  // En geniş taranan ağ: /22 (1024 adres). Daha büyük maskeler buna daraltılır.
  var WIDEST_SCAN_PREFIX = 22;
  // TV kendi adresini söyleyemiyor ve kayıtlı adres de yoksa taranacak yaygın ev ağları (modemlerin varsayılanları,
  // sırayla). Eskiden bu durumda tarama listesi boş kalıyor, hiçbir adres denenmiyordu: telefondan ya da başlatma
  // parametresi vermeyen yoldan kurulan TV (eski webOS, adresini vermeyen Samsung) "Ağda CouchSubs aranıyor…" ekranında
  // kalıyor, telefon "TV uygulaması bekleniyor" diyordu (#469, #484). Bir ağda CouchSubs bulununca sonrakiler taranmaz.
  var GUESS_SUBNETS = ['192.168.1', '192.168.0', '10.0.0', '192.168.2', '192.168.100', '192.168.31', '192.168.50',
    '192.168.178', '10.0.1', '192.168.10', '192.168.3', '192.168.8', '192.168.88'];
  var scanTimer = null;
  var scanDue = 0;
  var scanning = false;
  var failures = 0;

  // Bekleyen tarama daha erken başlayacaksa korunur. Eskiden her bağlantı hatası zamanlayıcıyı baştan kuruyordu;
  // EventSource birkaç saniyede bir yeniden denediğinden 30 sn hiç dolmuyor, tarama hiç başlamıyordu.
  function scheduleScan(delay) {
    if (scanning) return;
    if (delay === undefined) delay = SCAN_PAUSE_MS;
    var due = Date.now() + delay;
    if (scanTimer !== null && scanDue <= due) return;
    clearTimeout(scanTimer);
    scanDue = due;
    scanTimer = setTimeout(function () {
      scanTimer = null;
      scanForServer();
    }, delay);
  }

  function cancelScan() {
    clearTimeout(scanTimer);
    scanTimer = null;
  }

  // Bağlantı hatası: kayıtlı adres art arda birkaç kez yanıt vermediyse ağ hemen taranır, yoksa bir süre beklenir.
  function noteFailure() {
    failures++;
    scheduleScan(failures >= FAILS_BEFORE_SCAN ? SCAN_SOON_MS : SCAN_PAUSE_MS);
  }

  function subnetOf(address) {
    var match = /^(?:https?:\/\/)?(\d+\.\d+\.\d+)\.\d+(?::\d+)?\/?$/.exec(address || '');
    return match ? match[1] : null;
  }

  // Ağ maskesinin önek uzunluğu: 22, "22", "/22" ya da "255.255.252.0"; okunamazsa null.
  function prefixLength(mask) {
    if (mask === null || mask === undefined || mask === '') return null;
    var text = String(mask).replace(/^\//, '');
    if (/^\d{1,2}$/.test(text)) {
      var n = Number(text);
      return n >= 0 && n <= 32 ? n : null;
    }
    var parts = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(text);
    if (!parts) return null;
    var bits = 0, ended = false;
    for (var i = 1; i <= 4; i++) {
      var octet = Number(parts[i]);
      if (octet > 255) return null;
      for (var b = 7; b >= 0; b--) {
        if (octet & (1 << b)) {
          if (ended) return null;
          bits++;
        } else ended = true;
      }
    }
    return bits;
  }

  // TV'nin adresi ve ağ maskesinden taranacak /24 blokları (TV'ninki önce). Maske yoksa ya da /24 ve dar ise yalnız
  // TV'nin /24'ü; /23 ve /22'de ağın bütün blokları; /22'den geniş ağlarda TV'nin çevresindeki /22 (en çok 4 blok).
  function subnetsFor(ip, mask) {
    var own = subnetOf(ip);
    if (!own) return [];
    var bits = prefixLength(mask);
    if (bits === null || bits >= 24) return [own];
    if (bits < WIDEST_SCAN_PREFIX) bits = WIDEST_SCAN_PREFIX;
    var parts = own.split('.');
    var third = Number(parts[2]);
    var size = 1 << (24 - bits);
    var start = third - third % size;
    var list = [own];
    for (var i = start; i < start + size; i++) if (i !== third) list.push(parts[0] + '.' + parts[1] + '.' + i);
    return list;
  }
  window.__subnetsFor = subnetsFor;

  // Bekleme ekranındaki durum satırı: TV'nin adresi (biliniyorsa; telefonda elle yazılabilir) ve aramanın sürdüğü.
  // Adres ayrıca sorulmaz, taramanın zaten sorduğu adres kullanılır.
  var tvAddress = null;

  function renderWaitingStatus() {
    var el = $('waiting-status');
    if (!el) return;
    el.textContent = (tvAddress ? t('waitingAddress').replace('%1', tvAddress) + ' · ' : '') + t('waitingSearching');
  }

  // Taranacak ağlar: TV'nin kendi ağı, sonra kayıtlı adresin ağı (aynıysa bir kez); ikisi de yoksa yaygın ev ağları (guessed).
  function scanSubnets(done) {
    var fromServer = subnetOf(server);
    function finish(ip, mask) {
      if (ip && ip !== tvAddress) {
        tvAddress = ip;
        renderWaitingStatus();
      }
      var list = subnetsFor(ip, mask);
      if (fromServer && list.indexOf(fromServer) < 0) list.push(fromServer);
      if (list.length) return done(list, false);
      done(GUESS_SUBNETS.slice(), true);
    }
    if (!platform.localAddress) return finish(null);
    var answered = false;
    function once(ip, mask) {
      if (answered) return;
      answered = true;
      finish(ip, mask);
    }
    // Adresi soran servis yanıt vermezse tarama kayıtlı adresin ağıyla sürer.
    setTimeout(function () { once(null); }, 3000);
    try {
      platform.localAddress(once);
    } catch (e) {
      once(null);
    }
  }

  // --- Kendi CouchSubs'ını tanıma (GitHub #425) ---
  // Aynı ağda iki bilgisayar/telefon CouchSubs çalıştırınca TV eskiden taramada ilk yanıt verene bağlanıyordu; iki evin
  // (ya da iki odanın) altyazıları karışıyordu. CouchSubs /hello yanıtında kurulum kimliğini ("id") ve bağlı TV sayısını
  // ("tvs") verir. TV bağlandığı CouchSubs'ın kimliğini kaydeder; taramada önce onu, yoksa TV'si bağlı olmayanı seçer.
  var serverId = load('serverId');
  // Bu adrese bağlanınca kimlik, kayıtlı kimlik olmasa da kaydedilir (adresi bilgisayar başlatma parametresiyle verdi).
  var adoptAddress = null;
  // Bağlı olunan CouchSubs kayıtlı kimlik değil (kendisi kapalıyken bulunan): kendi CouchSubs'ı dönünce ona geçilir.
  var fallback = false;
  // Bağlı olunan CouchSubs /hello'da "live":0 dedi (çeviri yok ya da altyazı TV'ye gitmiyor).
  var idleServer = false;
  var FALLBACK_SCAN_MS = 60000;

  function helloInfo(text) {
    try {
      var info = JSON.parse(text);
      return info && typeof info === 'object' ? info : {};
    } catch (e) {
      return {};
    }
  }

  // Taramada bulunanlar ({ address, id, tvs }) arasından bağlanılacak CouchSubs; emin olunamıyorsa null.
  // 1) Kayıtlı kimlik. 2) TV'si bağlı olmayan tek CouchSubs (başka TV'ye hizmet eden, başka evin/odanın kurulumudur).
  // 3) Kayıtlı kimlik varsa başkası seçilmez. 4) İlk kez açılan TV: TV'si bağlı olmayan ilk, o da yoksa ilk bulunan.
  // Önce çeviren (/hello "live":1) CouchSubs: kayıtlı kimlik çeviriyorsa o; değilse çeviren ve başka TV'ye hizmet etmeyen
  // (current: şu an bağlı olunan adres, kendi bağlantımız sayılmaz) tek CouchSubs. Kayıtlı CouchSubs boştayken (ör.
  // bilgisayar açık bırakılmış, çeviri telefondan) TV ona bağlı kalıyor, "bağlı" görünüp altyazı hiç gelmiyordu. live
  // bildirmeyen eski CouchSubs'ta kural eskisi gibidir.
  function pickServer(found, savedId, current) {
    var i, idle = [], live = [];
    for (i = 0; i < found.length; i++) if (savedId && found[i].id === savedId && found[i].live === 1) return found[i];
    for (i = 0; i < found.length; i++) {
      if (found[i].live === 1 && (!(found[i].tvs > 0) || found[i].address === current)) live.push(found[i]);
    }
    if (live.length === 1) return live[0];
    for (i = 0; i < found.length; i++) if (savedId && found[i].id === savedId) return found[i];
    for (i = 0; i < found.length; i++) if (!(found[i].tvs > 0)) idle.push(found[i]);
    if (idle.length === 1) return idle[0];
    if (savedId) return null;
    return idle[0] || found[0] || null;
  }
  window.__pickServer = pickServer;

  // Bağlantı açılınca CouchSubs'ın kimliği sorulur. Kayıtlı kimlik yoksa ya da adres parametreyle geldiyse kaydedilir;
  // başka bir kimlikse (kendi CouchSubs'ı kapalı, ya da modem adresleri değiştirmiş) kendi CouchSubs'ı aranmaya devam edilir.
  function learnServer(address) {
    var adopt = adoptAddress === address;
    if (adopt) adoptAddress = null;
    probe(address, function (ok, info) {
      if (address !== server) return;
      var id = ok && info.id ? String(info.id) : null;
      if (!id) {
        fallback = false;
        idleServer = false;
        return;
      }
      if (adopt || !serverId) {
        serverId = id;
        save('serverId', id);
      }
      var wasFallback = fallback;
      fallback = id !== serverId;
      // Bağlanılan CouchSubs çevirmiyor: ağda çeviren başka bir CouchSubs var mı diye arada bir bakılır (pickServer).
      var wasIdle = idleServer;
      idleServer = info.live === 0;
      if (fallback) scheduleScan(wasFallback ? FALLBACK_SCAN_MS : SCAN_SOON_MS);
      else if (idleServer) scheduleScan(wasIdle ? FALLBACK_SCAN_MS : SCAN_SOON_MS);
    });
  }

  function probe(address, done) {
    var request = new XMLHttpRequest();
    var finished = false;
    function finish(ok, info) {
      if (finished) return;
      finished = true;
      done(ok, info || {});
    }
    request.onload = function () {
      var ok = request.status === 200 && request.responseText.indexOf('couchsubs') >= 0;
      finish(ok, ok ? helloInfo(request.responseText) : null);
    };
    request.onerror = function () { finish(false); };
    request.ontimeout = function () { finish(false); };
    try {
      request.open('GET', address + '/hello');
      request.timeout = SCAN_TIMEOUT_MS;
      request.send();
    } catch (e) {
      finish(false);
    }
  }

  function scanForServer() {
    if (scanning) return;
    cancelScan();
    scanning = true;
    scanSubnets(function (subnets, guessed) {
      var addresses = [];
      for (var s = 0; s < subnets.length; s++) {
        for (var host = 1; host <= 254; host++) addresses.push('http://' + subnets[s] + '.' + host + ':' + SERVER_PORT);
      }
      var next = 0, active = 0, done = false, found = [];
      // Tahmin edilen ağlar birer birer taranır: CouchSubs bulunan ağda durulur (bilinen ağlar hep birlikte).
      var stop = guessed ? Math.min(254, addresses.length) : addresses.length;
      function pump() {
        // Tahminli tarama uzun sürer; bu arada CouchSubs adresini kendisi verip bağlantı açıldıysa tarama bırakılır.
        if (guessed && !done && !fallback && !idleServer && eventSource && eventSource.readyState === 1) {
          done = true;
          scanning = false;
          return;
        }
        while (!done && active < SCAN_PARALLEL && next < stop) {
          active++;
          tryAddress(addresses[next++]);
        }
        if (done || active || next < stop) return;
        if (found.length || stop >= addresses.length) return finish(pickServer(found, serverId, server));
        stop = Math.min(stop + 254, addresses.length);
        pump();
      }
      // Kayıtlı kimlik bulununca tarama hemen biter (boştaysa bitmez: çeviren başka CouchSubs aranır); yoksa bütün ağ
      // taranıp aralarından seçilir (eskiden ilk bulunan).
      function tryAddress(address) {
        probe(address, function (ok, info) {
          active--;
          if (done) return;
          if (ok) {
            var entry = { address: address, id: info.id ? String(info.id) : null, tvs: typeof info.tvs === 'number' ? info.tvs : null,
              live: typeof info.live === 'number' ? info.live : null };
            found.push(entry);
            if (serverId && entry.id === serverId && entry.live !== 0) return finish(entry);
          }
          pump();
        });
      }
      function finish(choice) {
        done = true;
        scanning = false;
        if (!choice) {
          scheduleScan(fallback || idleServer ? FALLBACK_SCAN_MS : SCAN_PAUSE_MS);
          return;
        }
        if (choice.address === server) idleServer = choice.live === 0;
        // Bulunan adres kaydedilir: TV bir sonraki açılışta eski adrese takılmasın.
        save('server', choice.address);
        // Aynı bilgisayarsa EventSource kendisi yeniden bağlanır; kapanıp vazgeçtiyse (CLOSED) yeniden kurulur.
        // Eşleştirme beklemiyor (ya da Tamam'ı beklemiyor) ve bağlantı da yoksa (bilgisayar kapalıyken /hello yanıtsız
        // kalmıştı) yeniden kurulur.
        if (choice.address !== server || (eventSource ? eventSource.readyState === 2 : !pairingActive && !pairingFailed)) connect(choice.address);
        else if (fallback || idleServer) scheduleScan(FALLBACK_SCAN_MS);
      }
      pump();
    });
  }

  // --- Demo ---
  // Mağaza incelemesi ve ilk kez açanlar için: PS5 ve bilgisayar olmadan örnek altyazılar gösterilir.

  // next: sonraki satıra kadar geçen süre. Kısa olanlar hızlı konuşmayı gösterir: önceki satır üstte soluk kalır.
  var DEMO_LINE_MS = 3200;
  var DEMO_GAP_MS = 700;
  var DEMO_FAST_MS = 1000;
  var DEMO_LINES = [
    { text: 'Buraya ayıracak vaktimiz yok.', next: DEMO_LINE_MS + DEMO_GAP_MS },
    { text: 'MİRA: Kapı daha fazla dayanmayacak!', next: DEMO_LINE_MS + DEMO_GAP_MS },
    { text: 'Yakın dur.', next: DEMO_FAST_MS },
    { text: 'İlerideki yol tehlikeli.', next: DEMO_LINE_MS + DEMO_GAP_MS },
    { text: 'Bekle! Sen de kimsin?', next: DEMO_FAST_MS },
    { text: 'Silahını indir!', next: DEMO_LINE_MS + DEMO_GAP_MS },
    { text: 'Bu iş henüz bitmedi.', next: DEMO_LINE_MS + DEMO_GAP_MS }
  ];
  var demoTimer = null;
  var demoIndex = 0;

  function demoRunning() { return demoTimer !== null; }

  function nextDemoLine() {
    var line = DEMO_LINES[demoIndex];
    showSubtitle(line.text, DEMO_LINE_MS);
    demoIndex = (demoIndex + 1) % DEMO_LINES.length;
    demoTimer = setTimeout(nextDemoLine, line.next);
  }

  function startDemo() {
    if (demoRunning()) return;
    hidePanel();
    $('waiting').className = 'hidden';
    $('demo-badge').className = '';
    demoIndex = 0;
    nextDemoLine();
  }

  function stopDemo() {
    clearTimeout(demoTimer);
    demoTimer = null;
    hideSubtitle('demo');
    $('demo-badge').className = 'hidden';
    // Uygulamaya bağlı değilse bekleme ekranına dönülür.
    if (!server) $('waiting').className = '';
  }

  // Geri tuşu: önce ipucu, demo ya da panel kapanır; giriş ekranında TV'nin ana ekranına dönülür.
  function goBack() {
    if (sourceTipShown()) return hideSourceTip();
    if (noPictureShown()) return closeNoPicture();
    if (demoRunning()) return stopDemo();
    if ($('panel').className !== 'hidden') return hidePanel();
    // Kullanıcı kendisi çıkıyor: uygulama tümüyle kapanır, HDMI girişini bırakır (platform.exit(true)).
    leaving = true;
    platform.exit(true);
  }

  // --- TV kendiliğinden HDMI'ya geçiyor (Samsung) ---
  // Samsung'da Anynet+ (HDMI-CEC) ya da Otomatik Kaynak Değiştirme açıkken TV, PS5'ten sinyal gelince CouchSubs'ı
  // arka plana atıp kendi HDMI girişine geçebiliyor: çeviri bir an görünüp kayboluyor. Uygulama açıldıktan ya da öne
  // geldikten kısa süre sonra arka plana düşerse, ya da kısa sürede birkaç kez düşerse bu not edilir; uygulama yeniden
  // göründüğünde ipucu gösterilir. Not localStorage'da durur: TV uygulamayı kapatıp sonra yeniden açsa da ipucu çıkar.
  // Yalnız ipucu menüleri Samsung'a uyan platformda (platform.sourceSwitchTip) çalışır.

  var SOURCE_SWITCH_SOON_MS = 10000;
  var SOURCE_SWITCH_REPEAT = 3;
  var SOURCE_SWITCH_WINDOW_MS = 300000;
  var SOURCE_TIP_MS = 30000;
  var visibleSince = Date.now();
  var hiddenTimes = [];
  var leaving = false; // Geri tuşuyla çıkılıyor: arka plana düşmesi kendiliğinden değil.
  var sourceTipTimer = null;

  function noteHidden() {
    if (!platform.sourceSwitchTip || leaving) return;
    var now = Date.now();
    hiddenTimes.push(now);
    while (hiddenTimes.length && now - hiddenTimes[0] > SOURCE_SWITCH_WINDOW_MS) hiddenTimes.shift();
    if (now - visibleSince < SOURCE_SWITCH_SOON_MS || hiddenTimes.length >= SOURCE_SWITCH_REPEAT) {
      save('sourceSwitch', now);
    }
  }

  function noteVisible() {
    visibleSince = Date.now();
    maybeShowSourceTip();
  }

  function maybeShowSourceTip() {
    if (!platform.sourceSwitchTip || !load('sourceSwitch')) return;
    save('sourceSwitch', '');
    $('source-tip').className = '';
    clearTimeout(sourceTipTimer);
    sourceTipTimer = setTimeout(hideSourceTip, SOURCE_TIP_MS);
  }

  function sourceTipShown() { return $('source-tip').className !== 'hidden'; }

  function hideSourceTip() {
    clearTimeout(sourceTipTimer);
    $('source-tip').className = 'hidden';
  }

  // --- Arka plandayken bağlantıyı bırakma (Samsung) ---
  // Samsung uygulamayı arka plana atınca (Anynet+, Otomatik Kaynak Değiştirme, Home tuşu) sayfa duraklar ama bağlantı
  // açık kalır. Bilgisayar TV uygulamasının bağlı olduğunu sanıp onu yeniden açmıyordu; altyazı ekrana gelmiyordu.
  // Bağlantı bırakılınca bilgisayar uygulamayı birkaç saniye içinde yeniden öne getirir (TvKeeper). Yalnız bu davranışı
  // isteyen platformda (platform.closeWhenHidden) çalışır.
  var pausedByHidden = false;

  function dropWhileHidden() {
    if (!platform.closeWhenHidden || leaving || pausedByHidden || !eventSource) return;
    pausedByHidden = true;
    eventSource.close();
    eventSource = null;
    clearTimeout(dropTimer);
    dropTimer = null;
    cancelScan();
    // Öne gelince eski altyazı ekranda asılı kalmasın.
    hideSubtitle('hidden');
    hideScreen();
    hideRegions();
    setStatus('st-conn', t('reconnecting'), 'bad');
  }

  // Bağlantı arka planda bırakılmıştı ve yeniden kuruluyor: true.
  function resumeAfterHidden() {
    if (!pausedByHidden) return false;
    pausedByHidden = false;
    if (server) connect(server);
    return true;
  }

  // --- Öne gelince altyazıyı hemen geri getirme (LG, Android TV) ---
  // PS tuşu (HDMI-CEC) TV'yi PS5'in girişine geçirince uygulama arka plana düşer; bilgisayar/telefon bekçisi onu 1-2 sn
  // içinde geri getirir. Arka plandayken bağlantı kopmuş ya da yeniden denemede bekliyor olabilir: eskiden bağlantı
  // bekçisinin 10 sn'lik turu ya da tarayıcının yeniden denemesi beklenir, bu arada çeviri gelmiyordu. Öne gelince (ve
  // bilgisayar uygulamayı yeniden açınca) bağlantı açık değilse ya da sessizleşmişse hemen yeniden kurulur; süresi
  // dolmamış son satır yeniden çizilir.
  var REVIVE_SILENCE_MS = 20000;

  function reviveStream() {
    if (!server || pausedByHidden || pairingActive || demoRunning()) return;
    var open = eventSource && eventSource.readyState === 1;
    if (open && !(pingSeen && Date.now() - lastActivity > REVIVE_SILENCE_MS)) {
      restoreLastLine();
      return;
    }
    diag.revived = (diag.revived || 0) + 1;
    renderDiag();
    connect(server);
  }

  // Son satır hâlâ geçerliyse (süresi dolmadı, "temizle" gelmedi) ve ekranda değilse kalan süresiyle yeniden çizilir.
  function restoreLastLine() {
    if (!lastLine || $('subtitle').className !== 'hidden') return;
    var left = lastLine.until - Date.now();
    if (left < RESTORE_MIN_MS) { lastLine = null; return; }
    showSubtitle(lastLine.text, left, lastLine.box, lastLine.paragraphs, false, speakerMap(lastLine.speakers));
  }

  function pageVisibility(hidden) {
    if (hidden) {
      noteHidden();
      dropWhileHidden();
    } else {
      if (!resumeAfterHidden()) reviveStream();
      noteVisible();
    }
  }
  // Ekranın görünmez olduğunu document.hidden'dan başka yoldan bilen platform (Android TV: Activity onStop/onStart) çağırır.
  window.__pageHidden = pageVisibility;

  document.addEventListener('visibilitychange', function () { pageVisibility(document.hidden); });

  // --- Panel ve kumanda ---

  // "1–4: HDMI girişi · 0: …" satırını tuş başına bir satıra böler; tuş adı vurgu renginde.
  function formatKeys() {
    var el = $('keys');
    // Her seferinde i18n metninden kurulur: Samsung panelin ölçüsünü sonradan öğrenince liste yeniden kurulur.
    var text = t('keys');
    // Samsung'da Sarı her zaman listede: geniş yüzeyde (21:9, 32:9) HDMI görüntüsünü sığdırır ya da ekranı doldurur
    // (#304); 16:9 yüzeyde sıradaki görüntü yöntemini (100%, 21:9 ve 32:9 tam genişlik) dener.
    var modes = pictureModes();
    if (modes) text += ' · ' + t(pictureStep(modes) ? 'keyPictureSize' : 'keyPicture');
    var parts = text.split(' · ');
    el.innerHTML = '';
    for (var i = 0; i < parts.length; i++) {
      var colon = parts[i].indexOf(':');
      var row = document.createElement('div');
      row.className = 'key';
      var key = document.createElement('b');
      key.textContent = colon > 0 ? parts[i].slice(0, colon) : '';
      row.appendChild(key);
      row.appendChild(document.createTextNode(colon > 0 ? parts[i].slice(colon + 1).trim() : parts[i]));
      el.appendChild(row);
    }
  }

  function pictureModes() {
    try { return typeof platform.pictureModes === 'function' ? platform.pictureModes() : null; } catch (e) { return null; }
  }

  // Samsung'un görüntü yöntemleri (tv-tizen/platform.js): yöntemin sırası ve sayısı [1, 3]; geniş ekranın
  // sığdır/doldur seçiminde null.
  function pictureStep(mode) {
    try {
      var list = typeof platform.pictureModeList === 'function' ? platform.pictureModeList() : null;
      var index = list ? list.indexOf(mode) : -1;
      return index >= 0 ? [index + 1, list.length] : null;
    } catch (e) {
      return null;
    }
  }

  // Sarı: geniş ekranda HDMI görüntüsü 16:9 tam yükseklik (yanlarda siyah) ya da ekranın tamamı (gerilmiş); 4K
  // Samsung'da sıradaki pencere yöntemi.
  function togglePicture() {
    if (!pictureModes()) return;
    var mode = platform.togglePicture();
    var step = pictureStep(mode);
    showSubtitle(step ? t('pictureSize').replace('%1', step[0]).replace('%2', step[1]) :
      t(mode === 'fill' ? 'pictureFill' : 'pictureFit'), 3000);
  }

  // Panel açıkken bekleme kutusu kapanır: ikisi üst üste binince yazılar okunmuyor.
  function showPanel(autoHide) {
    hidePanelTip();
    $('waiting').className = 'hidden';
    $('panel').className = '';
    renderDiag();
    clearTimeout(panelTimer);
    if (autoHide) panelTimer = setTimeout(autoHidePanel, 8000);
  }

  // Panel kendiliğinden kapandı: ilk açılışlarda panele nasıl dönüleceği söylenir.
  function autoHidePanel() {
    hidePanel();
    maybeShowPanelTip();
  }

  function hidePanel() {
    $('panel').className = 'hidden';
    if (!server && !demoRunning()) $('waiting').className = '';
  }

  function togglePanel() {
    if ($('panel').className === 'hidden') showPanel(false); else hidePanel();
  }

  // --- Panel ipucu ---
  // Bağlanınca panel 8 sn görünüp kapanır; ekranda yalnız konsolun HDMI görüntüsü kalır. Kullanıcı uygulamanın onu
  // "PlayStation ekranına attığını", uygulamaya ve ayarlara giremediğini sanıyordu. İlk PANEL_TIP_LAUNCHES açılışta panel
  // kendiliğinden kapanınca altta kısa bir ipucu çıkar: Tamam paneli açar, altyazı ayarları telefonda ya da
  // bilgisayardadır. Herhangi bir tuş ipucunu kapatır; Geri yalnız ipucunu kapatır, uygulamadan çıkmaz.
  var PANEL_TIP_LAUNCHES = 3;
  var PANEL_TIP_MS = 15000;
  var panelTipTimer = null;
  var panelTipDone = false; // Bu açılışta ipucu gösterildi ya da gösterilmeyecek.

  function maybeShowPanelTip() {
    if (panelTipDone || !server || demoRunning() || sourceTipShown() || noPictureShown()) return;
    if ($('panel').className !== 'hidden') return;
    panelTipDone = true;
    var shown = Number(load('panelTips')) || 0;
    if (shown >= PANEL_TIP_LAUNCHES) return;
    save('panelTips', shown + 1);
    $('panel-tip').className = '';
    clearTimeout(panelTipTimer);
    panelTipTimer = setTimeout(hidePanelTip, PANEL_TIP_MS);
  }

  function panelTipShown() { return $('panel-tip').className !== 'hidden'; }

  function hidePanelTip() {
    clearTimeout(panelTipTimer);
    $('panel-tip').className = 'hidden';
  }

  // Sayı tuşu olmayan kumandalar için: panel açıkken sol ve sağ HDMI girişini değiştirir.
  function stepHdmi(step) {
    chooseHdmi((hdmiPort + step + 3) % 4 + 1);
    showPanel(true);
  }

  // Sihirli kumandada işaretçi görünürken Tamam tuşu keydown yerine tıklama gönderir; tuş sonrası gelen tıklama sayılmaz.
  var lastOkKey = 0;
  document.addEventListener('click', function () {
    if (Date.now() - lastOkKey < 400) return;
    hidePanelTip();
    if (sourceTipShown()) hideSourceTip();
    else if (noPictureShown()) return;
    else if (pairingFailed && server) connect(server);
    else if ($('waiting').className !== 'hidden') startDemo();
    else if (!demoRunning()) togglePanel();
  });

  document.addEventListener('keydown', function (e) {
    var code = e.keyCode;
    if (panelTipShown()) {
      hidePanelTip();
      // Geri yalnız ipucunu kapatır; Tamam ve diğer tuşlar her zamanki işini de yapar (Tamam paneli açar).
      if (code === KEY.BACK) { e.preventDefault(); return; }
    }
    if (code === KEY.OK) lastOkKey = Date.now();
    if (code === KEY.OK && sourceTipShown()) {
      hideSourceTip();
    } else if (noPictureShown() && (code === KEY.LEFT || code === KEY.RIGHT)) {
      focusNoPicture(noPictureFocus + (code === KEY.RIGHT ? 1 : -1));
      e.preventDefault();
    } else if (noPictureShown() && (code === KEY.UP || code === KEY.DOWN)) {
      focusNoPictureRow(code === KEY.DOWN ? 1 : -1);
      e.preventDefault();
    } else if (noPictureShown() && code === KEY.OK) {
      runNoPicture(noPictureActions[noPictureFocus]);
    } else if (code === 48) { // 0: elle seçimi unut, konsolu yeniden ara
      save('hdmi', '');
      autoSelectConsole(function () {
        setStatus('st-hdmi', hdmiPort + ' (' + t('consoleNotFound') + ')', 'bad');
      });
      showPanel(true);
    } else if (code >= 49 && code <= 52) { // 1–4: elle seçim, saklanır
      chooseHdmi(code - 48);
      showPanel(true);
    } else if (code === KEY.RED) {
      showSubtitle(t('localTest'), 4000);
    } else if (code === KEY.GREEN) {
      togglePanel();
    } else if (code === KEY.YELLOW) {
      togglePicture();
    } else if (code === KEY.BLUE) {
      if (demoRunning()) stopDemo(); else startDemo();
    } else if (code === KEY.OK && pairingFailed && server) {
      connect(server);
    } else if (code === KEY.OK && $('waiting').className !== 'hidden') {
      startDemo();
    } else if (code === KEY.OK && !demoRunning()) {
      togglePanel();
    } else if ((code === KEY.LEFT || code === KEY.RIGHT) && $('panel').className !== 'hidden') {
      stepHdmi(code === KEY.RIGHT ? 1 : -1);
    } else if (code === KEY.BACK) {
      goBack();
      e.preventDefault();
    } else if (code === KEY.UP || code === KEY.DOWN) {
      nudgeSubtitle(code === KEY.UP ? 3 : -3);
      e.preventDefault();
    }
  });

  // Uygulama zaten açıkken yeniden başlatılırsa (ör. CouchSubs onu öne getirdiğinde) parametreler burada gelir.
  // Aynı adresle yeniden açılış (bekçi PS tuşundan sonra uygulamayı öne getirdi): bağlantı açık değilse hemen kurulur.
  platform.onRelaunch(function (raw) {
    // LG: kurulumdan sonra webOS eski sayfayı tuttuysa öne gelişte diskteki yeni sürüm yüklenir (tv-webos/platform.js).
    if (platform.reloadIfStale) platform.reloadIfStale(APP_VERSION);
    var before = connectionGeneration;
    applyParams(parseParams(raw));
    if (connectionGeneration !== before || document.hidden) return;
    // Samsung (platform.reconnectOnRelaunch): bilgisayar/telefon uygulamayı yalnız TV'yi bağlı görmediğinde açar. Bağlantı
    // TV'de açık görünse de karşı taraf onu kapatmıştır (alındı gitmedi, #1248): beklemeden yeniden kurulur. Eskiden
    // sayfa açık bağlantıya güveniyor, bilgisayar uygulamayı her seferinde boşuna öne getiriyordu. Sayfa görünür ama arka
    // planda bırakılan bağlantı geri kurulmamışsa (öne gelişin visibilitychange'i gelmedi) o kurulur.
    if (platform.reconnectOnRelaunch) {
      if (resumeAfterHidden()) return;
      if (server && !pausedByHidden && !pairingActive && !demoRunning()) {
        diag.revived = (diag.revived || 0) + 1;
        renderDiag();
        connect(server);
        return;
      }
    }
    reviveStream();
  });

  platform.init();
  if (platform.reloadIfStale) platform.reloadIfStale(APP_VERSION);
  window.applyI18n();
  formatKeys();
  var savedBottom = load('bottom') || load('appBottom');
  if (savedBottom) setBottom(Number(savedBottom));
  startHdmi();

  renderVersion();
  watchPictureWindow();
  renderDiag();
  renderWaitingStatus();
  // Önceki açılışta TV kendiliğinden kaynağa geçtiyse ipucu şimdi gösterilir.
  maybeShowSourceTip();
  var initial = parseParams(platform.launchParams());
  var address = initial.server || load('server') || config.server;
  applyParams(initial);
  if (!server) {
    if (address) connect(address); else $('waiting').className = '';
  }
  if (!server) scanForServer();
  // Bekleme ekranı açıksa panel kendiliğinden açılmaz; yeşil tuşla açılabilir.
  if (server) showPanel(true); else hidePanel();
})();
