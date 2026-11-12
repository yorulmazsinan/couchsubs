// SPDX-License-Identifier: AGPL-3.0-only
// CouchSubs TV uygulaması (webOS ve Tizen ortak).
// HDMI girişini tam ekran gösterir, üstüne CouchSubs uygulamasından gelen altyazıyı basar.
// TV'ye özgü işler platform.js'tedir. Eski TV tarayıcıları için ES5 ile yazıldı.
(function () {
  'use strict';

  // TV uygulamasının sürümü: appinfo.json, tv-tizen/config.xml ve tv-android/app/build.gradle ile aynı tutulur.
  var APP_VERSION = '0.9.16';
  var t = window.t;
  var config = window.COUCHSUBS_CONFIG || {};
  var platform = window.COUCHSUBS_PLATFORM;
  var KEY = { RED: 403, GREEN: 404, BLUE: 406, LEFT: 37, UP: 38, RIGHT: 39, DOWN: 40, OK: 13, BACK: platform.backKey };

  var server = null;
  var eventSource = null;
  // Kumandayla seçilen port kayıtlıysa o kullanılır, yoksa PS5 otomatik aranır.
  var savedPort = Number(load('hdmi'));
  var hdmiPort = savedPort || 1;

  var bottomPercent = 7;
  // Çevirinin yeri: oyundaki İngilizce altyazının üstünü örterek (cover), üstünde (above), altında (below)
  // ya da sabit yükseklikte (fixed). Yeri bildirmeyen eski CouchSubs sürümlerinde sabit kalır.
  var PLACEMENTS = { cover: 1, above: 1, below: 1, fixed: 1 };
  var placement = 'fixed';
  // Gösterilen satırın oyundaki İngilizce altyazının yeri (ekrana oranla), bilinmiyorsa null.
  var currentBox = null;

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

  // Bilgisayarın "temizle" olayı satırı bundan erken kaldırmaz: oyundaki satır çeviri gelirken kalkmışsa yazı TV'de
  // bir an görünüp kayboluyordu. Süre, bilgisayarın okuma süresi kuralıyla aynıdır; üst sınırı daha kısadır.
  var HOLD_MAX_MS = 5000;
  var holdUntil = 0;
  // Bağlantı bir an koptuğunda yazı silinmez; ancak bu süre içinde geri gelmezse silinir.
  var DROP_HIDE_MS = 6000;
  var dropTimer = null;

  // Panelde görünen tanı bilgisi: "yazı TV'ye gelmiyor" bildirimlerinde sebebi buradan okuruz.
  var diag = { subtitles: 0, clears: 0, drops: 0, backgrounded: 0, lastHide: '-', place: '-', error: '' };

  function $(id) { return document.getElementById(id); }

  function renderDiag() {
    var el = $('st-diag');
    if (!el) return;
    el.textContent = 'sub ' + diag.subtitles + ' · clear ' + diag.clears + ' · drop ' + diag.drops +
      ' · bg ' + diag.backgrounded + ' · hide ' + diag.lastHide + ' · ' + diag.place +
      (window.__screenSaverStatus ? ' · saver ' + window.__screenSaverStatus : '') +
      (diag.error ? ' · err ' + diag.error : '');
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

  function load(key) {
    try { return window.localStorage.getItem('couchsubs.' + key); } catch (e) { return null; }
  }

  function save(key, value) {
    try { window.localStorage.setItem('couchsubs.' + key, String(value)); } catch (e) {}
  }

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
    if (params.hdmi >= 1 && params.hdmi <= 4) {
      hdmiPort = Number(params.hdmi);
      save('hdmi', hdmiPort);
      showHdmi(hdmiPort);
    }
    if (params.server && params.server !== server) {
      save('server', params.server);
      connect(params.server);
    }
  }

  // --- HDMI görüntüsü ---

  function showHdmi(port) {
    setStatus('st-hdmi', String(port));
    var statuses = {
      loading: ['loading', 'muted'],
      ready: ['videoReady', 'ok'],
      playing: ['playing', 'ok'],
      inputError: ['inputError', 'bad'],
      sourceError: ['sourceError', 'bad']
    };
    platform.showHdmi(port, $('video-host'), function (kind) {
      setStatus('st-video', t(statuses[kind][0]), statuses[kind][1]);
    });
  }

  function autoSelectConsole(onNotFound) {
    platform.findConsolePort(function (port, label) {
      if (!port) return onNotFound && onNotFound();
      if (port !== hdmiPort) {
        hdmiPort = port;
        showHdmi(port);
      }
      setStatus('st-hdmi', port + ' — ' + label + ' (' + t('auto') + ')');
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

  // paragraphs: görev paneli gibi başlık ve maddeli yazılar satır satır, sola yaslı gösterilir.
  // replaces: bilgisayar bu satırı öncekinin uzamış ya da düzelmiş okuması saydı (bkz. replacesCurrent).
  function showSubtitle(text, duration, box, paragraphs, replaces) {
    var now = Date.now();
    var current = $('subtitle-text').textContent;
    // Önceki satır kısa göründüyse yeni satırın üstünde kalır. Aynı cümlenin başka bir okunuşu (ya da yeniden gelen
    // satır) ikinci çeviri gibi durmasın diye üste çıkmaz; görev paneli gibi çok satırlı yazılar da üst üste binmez.
    if (replacesCurrent(replaces, paragraphs)) {
      // Üstteki daha eski satırlar olduğu gibi kalır.
    } else if (stackPrevious && $('subtitle').className !== 'hidden' && current && now - shownAt < STACK_WITHIN_MS &&
        !paragraphs && !shownParagraphs && !sameLine(current, text)) {
      showPrevious(current);
    } else {
      hidePrevious();
    }
    shownAt = now;
    shownParagraphs = !!paragraphs;
    holdUntil = shownAt + Math.min(HOLD_MAX_MS, 2000 + text.length * 60);
    currentBox = validBox(box);
    $('subtitle-text').textContent = text;
    $('subtitle-text').style.whiteSpace = paragraphs ? 'pre-line' : '';
    $('subtitle-text').style.textAlign = paragraphs ? 'left' : '';
    $('subtitle').className = '';
    layout();
    setStatus('st-last', text.length > 40 ? text.slice(0, 40) + '…' : text);
    notePlace();
    clearTimeout(hideTimer);
    // Geçersiz ya da çok kısa süre yazıyı gösterir göstermez kaldırmasın.
    var ms = duration > 0 ? Math.max(MIN_VISIBLE_MS, duration) : Math.min(8000, 2000 + text.length * 60);
    hideTimer = setTimeout(function () { hideSubtitle('timer'); }, ms);
  }

  // Yazının ekrandaki gerçek yeri ve görünürlüğü (tanı için).
  function notePlace() {
    var el = $('subtitle-text');
    var rect = el.getBoundingClientRect();
    var height = document.documentElement.clientHeight || window.innerHeight || 0;
    diag.place = 'y ' + Math.round(rect.top) + '-' + Math.round(rect.bottom) + '/' + height + ' ' +
      window.getComputedStyle($('subtitle')).visibility + ' f' + window.getComputedStyle(el).fontSize;
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
  function showPrevious(text) {
    var older = $('subtitle-prev');
    var olderText = $('subtitle-prev-text').textContent;
    if (older.className === '' && olderText && !sameLine(olderText, text)) {
      showSlot('subtitle-prev2', olderText);
    } else {
      hideSlot('subtitle-prev2');
    }
    showSlot('subtitle-prev', text);
  }

  function showSlot(id, text) {
    var timers = previousTimers[id];
    clearTimeout(timers[0]);
    clearTimeout(timers[1]);
    $(id + '-text').textContent = text;
    $(id).className = '';
    timers[0] = setTimeout(function () {
      $(id).className = 'fading';
      timers[1] = setTimeout(function () { hideSlot(id); }, PREVIOUS_FADE_MS);
    }, PREVIOUS_HOLD_MS);
  }

  function hideSlot(id) {
    var timers = previousTimers[id];
    clearTimeout(timers[0]);
    clearTimeout(timers[1]);
    $(id).className = 'hidden';
  }

  function hidePrevious() {
    hideSlot('subtitle-prev');
    hideSlot('subtitle-prev2');
  }

  // Büyük-küçük harf ve noktalama dışında aynı mı, ya da biri ötekinin başı/devamı mı ("Kapı" → "Kapı daha fazla…").
  function sameLine(a, b) {
    var x = plainText(a);
    var y = plainText(b);
    if (!x || !y) return x === y;
    return x === y || x.indexOf(y) >= 0 || y.indexOf(x) >= 0;
  }

  function plainText(text) {
    return String(text).toLowerCase().replace(/[\s.,!?;:…"'“”‘’«»()\[\]\-–—]+/g, '');
  }

  // --- Ekranı çevir ---
  // Bilgisayar ekranın tamamını okuyup her yazı grubunun çevirisini yeriyle gönderir. Her çeviri kendi İngilizce
  // yazısını örter; yazı boyu o yazının satır yüksekliğinden seçilir, Türkçe uzun gelirse sığana kadar küçülür.

  var screenTimer = null;
  var SCREEN_PAD = 0.004;
  var SCREEN_MIN_FONT = 14;

  function showScreen(items, duration) {
    var host = $('screen');
    // "Ekran çevriliyor…" yazısı sonuçların üstünde kalmasın.
    hideSubtitle('screen');
    host.innerHTML = '';
    host.className = '';
    var width = window.innerWidth || 1920;
    var height = window.innerHeight || 1080;
    for (var i = 0; i < (items || []).length; i++) {
      var item = items[i];
      var box = validBox(item && item.box);
      if (!box || !item.text) continue;
      var el = document.createElement('div');
      el.className = item.paragraphs === true ? 'item paragraphs' : 'item';
      el.textContent = item.text;
      var left = Math.max(0, box.left - SCREEN_PAD);
      var top = Math.max(0, box.top - SCREEN_PAD);
      var boxHeight = (box.bottom - box.top + 2 * SCREEN_PAD) * height;
      el.style.left = (left * 100) + '%';
      el.style.top = (top * 100) + '%';
      el.style.width = Math.max(80, (Math.min(1, box.right + SCREEN_PAD) - left) * width) + 'px';
      el.style.minHeight = Math.round(boxHeight) + 'px';
      var line = typeof item.line === 'number' && item.line > 0 ? item.line * height : box.bottom * height - box.top * height;
      var size = Math.max(SCREEN_MIN_FONT, Math.min(96, Math.round(line * 0.95)));
      el.style.fontSize = size + 'px';
      host.appendChild(el);
      // Türkçe çoğu zaman İngilizceden uzundur: kutu biraz uzayabilir, daha fazlası için yazı küçülür.
      var limit = Math.max(boxHeight * 1.5, line * 2.6);
      while (el.scrollHeight > limit && size > SCREEN_MIN_FONT) {
        size -= 2;
        el.style.fontSize = size + 'px';
      }
    }
    clearTimeout(screenTimer);
    screenTimer = setTimeout(hideScreen, duration || 20000);
  }

  function hideScreen() {
    clearTimeout(screenTimer);
    $('screen').className = 'hidden';
    $('screen').innerHTML = '';
  }

  // Konum hem CouchSubs uygulamasından hem kumandanın oklarıyla ayarlanır. Kumandayla
  // seçilen konum, uygulamadaki ayar değişene kadar korunur (son değiştiren geçerlidir).
  function setBottom(percent) {
    bottomPercent = Math.max(0, Math.min(85, percent));
    layout();
  }

  // Altyazıyı seçilen yerleşime göre konumlar. İngilizce altyazının yeri bilinmiyorsa sabit yükseklik kullanılır.
  function layout() {
    var el = $('subtitle');
    var cover = $('subtitle-cover');
    var box = placement === 'fixed' ? null : currentBox;
    el.style.left = '8%';
    el.style.right = '8%';
    el.style.top = 'auto';
    el.style.bottom = bottomPercent + '%';
    cover.className = 'hidden';
    // Altyazı yokken (ör. ayar değişince yeniden yerleşirken) örtü tek başına boş siyah kutu olarak kalmasın.
    if (!box || el.className === 'hidden') return;

    var height = document.documentElement.clientHeight || window.innerHeight || 1080;
    var gap = Math.round(height * 0.012);
    var mode = placement;
    // Ekranın kenarında yer yoksa öbür yana geçilir.
    if (mode === 'below' && box.bottom > 0.88) mode = 'above';
    if (mode === 'above' && box.top < 0.12) mode = 'below';

    // Yatayda İngilizce satırın ortasına hizalanır.
    var center = (box.left + box.right) / 2;
    var half = Math.max(0.3, Math.min(center, 1 - center));
    el.style.left = (Math.max(0.02, center - half) * 100) + '%';
    el.style.right = (Math.max(0.02, 1 - center - half) * 100) + '%';

    if (mode === 'cover') {
      // İngilizce yazı koyu bir zeminle örtülür, çeviri onun ortasına gelir.
      var pad = 0.012;
      cover.style.left = ((box.left - pad) * 100) + '%';
      cover.style.top = ((box.top - pad) * 100) + '%';
      cover.style.width = ((box.right - box.left + 2 * pad) * 100) + '%';
      cover.style.height = ((box.bottom - box.top + 2 * pad) * 100) + '%';
      cover.className = '';
      var middle = (1 - (box.top + box.bottom) / 2) * height;
      el.style.bottom = Math.max(0, Math.round(middle - $('subtitle-text').offsetHeight / 2)) + 'px';
    } else if (mode === 'above') {
      el.style.bottom = Math.round((1 - box.top) * height + gap) + 'px';
    } else {
      el.style.bottom = 'auto';
      el.style.top = Math.round(box.bottom * height + gap) + 'px';
    }
    keepOnScreen(el, cover);
  }

  // Bazı TV'lerde (Samsung, Android TV) sayfanın bildirdiği yükseklik ekranla uyuşmayabiliyor; altyazı ekranın
  // dışına düşerse hiç görünmüyordu. Yerleştirilen altyazı görünür alanda değilse sabit yüksekliğe döner.
  function keepOnScreen(el, cover) {
    var rect = el.getBoundingClientRect();
    var viewHeight = document.documentElement.clientHeight || window.innerHeight || 1080;
    var viewWidth = document.documentElement.clientWidth || window.innerWidth || 1920;
    var visible = rect.height > 0 && rect.top >= -2 && rect.bottom <= viewHeight + 2 && rect.right > 0 && rect.left < viewWidth;
    if (visible) return;
    el.style.left = '8%';
    el.style.right = '8%';
    el.style.top = 'auto';
    el.style.bottom = bottomPercent + '%';
    cover.className = 'hidden';
  }

  // Bilgisayardaki "Yazı rengi" seçimi; bilinmeyen değer gelirse renk değişmez.
  var TEXT_COLORS = { white: '#FFFFFF', yellow: '#FFE135' };

  function applyStyle(style) {
    if (style.fontSize) {
      $('subtitle-text').style.fontSize = style.fontSize + 'px';
      $('subtitle-prev-text').style.fontSize = Math.round(style.fontSize * 0.8) + 'px';
      $('subtitle-prev2-text').style.fontSize = Math.round(style.fontSize * 0.8) + 'px';
    }
    if (PLACEMENTS[style.placement]) placement = style.placement;
    if (typeof style.background === 'number') {
      var alpha = Math.max(0, Math.min(100, style.background)) / 100;
      $('subtitle-text').style.background = 'rgba(0, 0, 0, ' + alpha + ')';
      $('subtitle-prev-text').style.background = 'rgba(0, 0, 0, ' + (alpha * 0.83).toFixed(2) + ')';
      $('subtitle-prev2-text').style.background = 'rgba(0, 0, 0, ' + (alpha * 0.83).toFixed(2) + ')';
    }
    // Ayarı göndermeyen bilgisayar (eski Windows sürümü, Mac) eski davranışı bekler: önceki satırlar üstte kalır.
    // Yoksa bir kez kapatılan ayar başka bilgisayara bağlanınca da kapalı kalırdı.
    stackPrevious = typeof style.stackPrevious === 'boolean' ? style.stackPrevious : true;
    save('stackPrevious', stackPrevious ? '1' : '0');
    if (!stackPrevious) hidePrevious();
    if (typeof style.bold === 'boolean') {
      $('subtitle-text').style.fontWeight = style.bold ? '700' : '600';
      $('subtitle-prev-text').style.fontWeight = style.bold ? '700' : '600';
      $('subtitle-prev2-text').style.fontWeight = style.bold ? '700' : '600';
    }
    if (TEXT_COLORS[style.textColor]) {
      $('subtitle-text').style.color = TEXT_COLORS[style.textColor];
      $('subtitle-prev-text').style.color = TEXT_COLORS[style.textColor];
      $('subtitle-prev2-text').style.color = TEXT_COLORS[style.textColor];
    }
    layout();
    if (style.bottomPercent >= 0 && String(style.bottomPercent) !== load('appBottom')) {
      save('appBottom', style.bottomPercent);
      save('bottom', '');
      setBottom(style.bottomPercent);
    }
  }

  function nudgeSubtitle(step) {
    // Yer oyundaki altyazıya bağlıysa kumandayla taşınmaz.
    if (placement !== 'fixed') return;
    setBottom(bottomPercent + step);
    save('bottom', bottomPercent);
    // Nereye gittiği görülsün diye yazı yoksa örnek gösterilir.
    if ($('subtitle').className === 'hidden') showSubtitle(t('positionPreview'), 2500);
  }

  // --- Sunucu bağlantısı (Server-Sent Events) ---

  function onEvent(name, handler) {
    eventSource.addEventListener(name, function (e) {
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

  function connect(address) {
    if (demoRunning()) stopDemo();
    if (eventSource) eventSource.close();
    server = address;
    $('waiting').className = 'hidden';
    setStatus('st-server', address);
    if (!window.EventSource) {
      setStatus('st-conn', t('noEventSource'), 'bad');
      return;
    }
    setStatus('st-conn', t('connecting'), 'muted');
    eventSource = new EventSource(address + '/events');
    lastActivity = Date.now();
    eventSource.onopen = function () {
      lastActivity = Date.now();
      clearTimeout(scanTimer);
      clearTimeout(dropTimer);
      dropTimer = null;
      setStatus('st-conn', t('connected'), 'ok');
    };
    eventSource.onerror = function () {
      // Bağlantı kısa süre içinde geri gelmezse eski altyazı ekranda asılı kalmasın. Bir anlık kopma yazıyı silmez.
      diag.drops++;
      renderDiag();
      if (dropTimer === null) {
        dropTimer = setTimeout(function () {
          dropTimer = null;
          hideSubtitle('drop');
          hideScreen();
        }, DROP_HIDE_MS);
      }
      setStatus('st-conn', t('reconnecting'), 'bad');
      // Bilgisayarın adresi değişmiş olabilir.
      scheduleScan();
    };
    // Bilgisayar 15 sn'de bir "ping" gönderir; gelmezse bağlantı yarı kopmuştur (bkz. watchConnection).
    eventSource.addEventListener('ping', function () {
      lastActivity = Date.now();
      pingSeen = true;
    });
    onEvent('subtitle', function (data) {
      diag.subtitles++;
      renderDiag();
      if (data.text) showSubtitle(data.text, data.duration, data.box, data.paragraphs === true, data.replace === true);
    });
    onEvent('clear', onClear);
    onEvent('screen', function (data) { showScreen(data.items, data.duration); });
    onEvent('screen-clear', hideScreen);
    onEvent('style', applyStyle);
    onEvent('speech', function (data) { if (data.url) playSpeech(server + data.url); });
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
      playSpeechElement(url);
      return;
    }
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
  // Bilgisayar TV uygulamasını açamıyorsa adres gelmez. Adresini söyleyebilen TV'lerde uygulama aynı ağı tarar.

  var SERVER_PORT = 8787;
  var SCAN_PARALLEL = 24;
  var SCAN_TIMEOUT_MS = 1200;
  var SCAN_PAUSE_MS = 30000;
  var scanTimer = null;
  var scanning = false;

  function scheduleScan() {
    if (!platform.localAddress || scanning) return;
    clearTimeout(scanTimer);
    scanTimer = setTimeout(scanForServer, SCAN_PAUSE_MS);
  }

  function probe(address, done) {
    var request = new XMLHttpRequest();
    var finished = false;
    function finish(ok) {
      if (finished) return;
      finished = true;
      done(ok);
    }
    request.onload = function () { finish(request.status === 200 && request.responseText.indexOf('couchsubs') >= 0); };
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
    if (scanning || !platform.localAddress) return;
    platform.localAddress(function (ip) {
      var match = /^(\d+\.\d+\.\d+)\.\d+$/.exec(ip || '');
      if (!match) return scheduleScan();
      scanning = true;
      var next = 1, active = 0, found = false;
      function pump() {
        while (!found && active < SCAN_PARALLEL && next <= 254) {
          active++;
          tryAddress('http://' + match[1] + '.' + (next++) + ':' + SERVER_PORT);
        }
        if (!found && !active && next > 254) {
          scanning = false;
          scheduleScan();
        }
      }
      function tryAddress(address) {
        probe(address, function (ok) {
          active--;
          if (found) return;
          if (!ok) return pump();
          found = true;
          scanning = false;
          // Aynı bilgisayarsa EventSource kendisi yeniden bağlanır; kapanıp vazgeçtiyse (CLOSED) yeniden kurulur.
          if (address !== server || (eventSource && eventSource.readyState === 2)) {
            save('server', address);
            connect(address);
          }
        });
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
    if (demoRunning()) return stopDemo();
    if ($('panel').className !== 'hidden') return hidePanel();
    leaving = true;
    platform.exit();
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

  document.addEventListener('visibilitychange', function () {
    if (document.hidden) noteHidden(); else noteVisible();
  });

  // --- Panel ve kumanda ---

  // "1–4: HDMI girişi · 0: …" satırını tuş başına bir satıra böler; tuş adı vurgu renginde.
  function formatKeys() {
    var el = $('keys');
    var parts = el.textContent.split(' · ');
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

  // Panel açıkken bekleme kutusu kapanır: ikisi üst üste binince yazılar okunmuyor.
  function showPanel(autoHide) {
    $('waiting').className = 'hidden';
    $('panel').className = '';
    clearTimeout(panelTimer);
    if (autoHide) panelTimer = setTimeout(hidePanel, 8000);
  }

  function hidePanel() {
    $('panel').className = 'hidden';
    if (!server && !demoRunning()) $('waiting').className = '';
  }

  function togglePanel() {
    if ($('panel').className === 'hidden') showPanel(false); else hidePanel();
  }

  // Sayı tuşu olmayan kumandalar için: panel açıkken sol ve sağ HDMI girişini değiştirir.
  function stepHdmi(step) {
    hdmiPort = (hdmiPort + step + 3) % 4 + 1;
    save('hdmi', hdmiPort);
    showHdmi(hdmiPort);
    showPanel(true);
  }

  // Sihirli kumandada işaretçi görünürken Tamam tuşu keydown yerine tıklama gönderir; tuş sonrası gelen tıklama sayılmaz.
  var lastOkKey = 0;
  document.addEventListener('click', function () {
    if (Date.now() - lastOkKey < 400) return;
    if (sourceTipShown()) hideSourceTip();
    else if ($('waiting').className !== 'hidden') startDemo();
    else if (!demoRunning()) togglePanel();
  });

  document.addEventListener('keydown', function (e) {
    var code = e.keyCode;
    if (code === KEY.OK) lastOkKey = Date.now();
    if (code === KEY.OK && sourceTipShown()) {
      hideSourceTip();
    } else if (code === 48) { // 0: elle seçimi unut, konsolu yeniden ara
      save('hdmi', '');
      autoSelectConsole(function () {
        setStatus('st-hdmi', hdmiPort + ' (' + t('consoleNotFound') + ')', 'bad');
      });
      showPanel(true);
    } else if (code >= 49 && code <= 52) { // 1–4
      hdmiPort = code - 48;
      save('hdmi', hdmiPort);
      showHdmi(hdmiPort);
      showPanel(true);
    } else if (code === KEY.RED) {
      showSubtitle(t('localTest'), 4000);
    } else if (code === KEY.GREEN) {
      togglePanel();
    } else if (code === KEY.BLUE) {
      if (demoRunning()) stopDemo(); else startDemo();
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
  platform.onRelaunch(function (raw) { applyParams(parseParams(raw)); });

  platform.init();
  window.applyI18n();
  formatKeys();
  var savedBottom = load('bottom') || load('appBottom');
  if (savedBottom) setBottom(Number(savedBottom));
  showHdmi(hdmiPort);
  if (!savedPort) autoSelectConsole();

  $('app-version').textContent = APP_VERSION;
  renderDiag();
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
