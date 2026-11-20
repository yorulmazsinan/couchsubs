// SPDX-License-Identifier: AGPL-3.0-only
// CouchSubs TV uygulaması (webOS ve Tizen ortak).
// HDMI girişini tam ekran gösterir, üstüne CouchSubs uygulamasından gelen altyazıyı basar.
// TV'ye özgü işler platform.js'tedir. Eski TV tarayıcıları için ES5 ile yazıldı.
(function () {
  'use strict';

  // TV uygulamasının sürümü: appinfo.json, tv-tizen/config.xml ve tv-android/app/build.gradle ile aynı tutulur.
  var APP_VERSION = '0.9.33';
  var t = window.t;
  var config = window.COUCHSUBS_CONFIG || {};
  var platform = window.COUCHSUBS_PLATFORM;
  var KEY = { RED: 403, GREEN: 404, YELLOW: 405, BLUE: 406, LEFT: 37, UP: 38, RIGHT: 39, DOWN: 40, OK: 13, BACK: platform.backKey };

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

  function showHdmi(port) {
    setStatus('st-hdmi', String(port));
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

  function watchPicture(port) {
    clearTimeout(pictureTimer);
    pictureOk = false;
    noPictureClosed = false;
    hideNoPicture();
    if (!platform.noPictureHelp) return;
    pictureTimer = setTimeout(function () {
      // Bazı TV'ler görüntüyü gösterip 'playing' olayını hiç göndermiyor; görüntü varsa kutu açılmaz.
      if (pictureOk || (platform.hasPicture && platform.hasPicture())) return;
      showNoPicture(port, false);
    }, NO_PICTURE_MS);
  }

  function notePicture(port, kind) {
    if (port !== hdmiPort) return;
    if (kind === 'ready' || kind === 'playing') {
      pictureOk = true;
      clearTimeout(pictureTimer);
      if (!choosingInput) hideNoPicture();
    } else if (kind === 'inputError' || kind === 'sourceError') {
      clearTimeout(pictureTimer);
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
      platform.exit();
    } else if (action.close) {
      closeNoPicture();
    } else {
      hdmiPort = action.port;
      save('hdmi', hdmiPort);
      showHdmi(hdmiPort);
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
  function autoSelectConsole(onNotFound) {
    platform.findConsolePort(function (port, label, connected) {
      var guessed = connected > 1;
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

  // --- Uzun çeviriyi bölme ---
  // Uzun çeviri en çok 3 satıra, kelime sınırından ve dengeli bölünür; 3 satıra sığmazsa yazı biraz küçülür (en çok
  // %75'e kadar). Konuşan adı ("ARTHUR:") sonraki sözcükle birleşik kalır, hep ilk satırdadır. Satır sınırı TV'de
  // ekran genişliğidir (aşağıda wrapToWidth); 42 karakter kuralı yalnız ölçüm yapılamazsa kullanılır. Mac, Windows,
  // Android ve OBS (SubtitleWrap) hâlâ 42 karakter kuralını uygular.
  var WRAP_MAX_CHARS = 42;
  var WRAP_MAX_LINES = 3;
  var WRAP_MIN_SCALE = 0.75;
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
    var width = document.documentElement.clientWidth || window.innerWidth || 1920;
    var height = document.documentElement.clientHeight || window.innerHeight || 1080;
    var box = coverBounds(screenBox(currentBox, isOverlay()), isOverlay());
    return {
      width: bandShape ? width : (box.right - box.left) * width,
      height: (box.bottom - box.top) * height
    };
  }

  function wrapToWidth(text, el, size, cover) {
    var viewport = document.documentElement.clientWidth || window.innerWidth || 1920;
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
  function setLineText(textId, text, paragraphs, baseSize) {
    var el = $(textId);
    var wrapped = paragraphs ? { text: text, scale: 1 } : wrapSubtitle(text, el, baseSize, coverSize(textId));
    el.rawText = text;
    el.textContent = wrapped.text;
    el.style.whiteSpace = 'pre-line';
    var size = Math.round(baseSize * wrapped.scale);
    el.style.fontSize = size + 'px';
    // Altyazı kutusu ekranın alt dörtte birini geçmez ve dengeli bölünmüş satırlar korunur: 3 satıra bölünüp %75'e
    // küçültülse de genişliğe sığmayan yazıda tarayıcı kendiliğinden yeni satır açıyordu. Yazı, hem yükseklik sınırına
    // hem bölünmüş satır sayısına sığana dek küçülür. Görev paneli gibi satır satır yazılar bu sınırın dışındadır.
    // Gizli satır (display: none) ölçülemez, 0 yüksekliğiyle döngüye girmez.
    if (paragraphs) return;
    var limit = (document.documentElement.clientHeight || window.innerHeight || 1080) * SUBTITLE_MAX_HEIGHT;
    var lines = wrapped.text.split('\n').length;
    while (size > SUBTITLE_MIN_FONT && (el.offsetHeight > limit || extraLines(el, lines))) {
      size -= 1;
      el.style.fontSize = size + 'px';
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
  function showSubtitle(text, duration, box, paragraphs, replaces) {
    var now = Date.now();
    var current = rawText('subtitle-text');
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
    setLineText('subtitle-text', text, paragraphs, fontBase);
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
    var olderText = rawText('subtitle-prev-text');
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
    setLineText(id + '-text', text, false, Math.round(fontBase * 0.8));
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

  // Yalnız aşağıdaki bağımsız kutular büyümeyi sınırlar; kaynakta zaten üst üste olan
  // kutuların yerini değiştirmeyiz. Aynı hesap bütün sonuçlar için yapılır, sıra önemli değildir.
  function screenBottom(items, box, left, width, screenWidth, screenHeight) {
    var bottom = screenHeight;
    for (var j = 0; j < items.length; j++) {
      var other = items[j];
      var next = validBox(other && other.box);
      if (!next || !other.text || next.top < box.bottom) continue;
      var nextLeft = Math.max(0, next.left - SCREEN_PAD) * screenWidth;
      var nextWidth = Math.max(80, (Math.min(1, next.right + SCREEN_PAD) * screenWidth - nextLeft));
      if (left < nextLeft + nextWidth && left + width > nextLeft)
        bottom = Math.min(bottom, Math.max(0, next.top - SCREEN_PAD) * screenHeight);
    }
    return bottom;
  }

  // Yeriyle gelen çevirileri (ekranı çevir öğeleri, ek alan blokları) kendi İngilizce yazılarının üstüne koyar.
  function placeItems(host, items) {
    var width = window.innerWidth || 1920;
    var height = window.innerHeight || 1080;
    for (var i = 0; i < (items || []).length; i++) {
      var item = items[i];
      var box = validBox(item && item.box);
      if (!box || !item.text) continue;
      var el = document.createElement('div');
      el.className = item.paragraphs === true ? 'item paragraphs' : 'item';
      fillText(el, item.text, item.icons);
      var left = Math.max(0, box.left - SCREEN_PAD);
      var top = Math.max(0, box.top - SCREEN_PAD);
      var boxHeight = (box.bottom - box.top + 2 * SCREEN_PAD) * height;
      el.style.left = (left * 100) + '%';
      el.style.top = (top * 100) + '%';
      var itemWidth = Math.max(80, (Math.min(1, box.right + SCREEN_PAD) - left) * width);
      el.style.width = itemWidth + 'px';
      // Bir piksel pay, tarayıcının kesirli koordinat/scrollHeight yuvarlamasını karşılar.
      var available = Math.max(0, Math.floor(screenBottom(items, box, left * width, itemWidth, width, height) - top * height) - 1);
      el.style.minHeight = Math.min(Math.round(boxHeight), available) + 'px';
      var line = typeof item.line === 'number' && item.line > 0 ? item.line * height : box.bottom * height - box.top * height;
      var size = Math.max(SCREEN_MIN_FONT, Math.min(96, Math.round(line * 0.95)));
      el.style.fontSize = size + 'px';
      host.appendChild(el);
      // Türkçe çoğu zaman İngilizceden uzundur: kutu biraz uzayabilir, daha fazlası için yazı küçülür.
      var limit = Math.min(available, Math.max(boxHeight * 1.5, line * 2.6));
      while (el.scrollHeight > limit && size > SCREEN_MIN_FONT) {
        size = Math.max(SCREEN_MIN_FONT, size - 2);
        el.style.fontSize = size + 'px';
      }
      // En küçük okunabilir boyutta da sığmayan metni kesmeyiz/gizlemeyiz.
      // Bu uç durumda eski doğal büyüme davranışı korunur.
    }
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
  }

  function hideScreen() {
    clearTimeout(screenTimer);
    $('screen').className = 'hidden';
    $('screen').innerHTML = '';
  }

  // --- Ek alanlar ---
  // Bilgisayar altyazının yanında ekranın köşelerindeki yazıları da (görev, telefon mesajı, bildirim) sürekli okur ve
  // her alanın çevirisini "region" olayıyla gönderir: {id, text, box, line}. Çeviri İngilizce yazının yerinde küçük bir
  // kutuda durur; ekranın sağ yarısındaki kutu sağa, alt yarısındaki alta yaslanır, Türkçe uzun gelirse kutu ekranın
  // içine doğru büyür. Alanda birbirinden ayrı duran yazılar varsa "blocks" her grubun çevirisini kendi yeriyle taşır
  // ve her biri "ekranı çevir"deki gibi kendi yazısının üstüne konur. Boş "text" o alanın kutusunu, "region-clear"
  // hepsini kaldırır. Ana altyazıya dokunulmaz.

  var regionBoxes = {};
  var REGION_PAD = 0.004;
  var REGION_MIN_FONT = 18;
  var REGION_MAX_FONT = 44;

  function showRegion(data) {
    var id = data && typeof data.id === 'string' ? data.id : '';
    if (!id) return;
    var box = validBox(data.box);
    if (!data.text || !box) return hideRegion(id);
    // Alanda ayrı duran yazı grupları (görev başlığı ve ayrı sütundaki hedef) kendi yerleriyle gelir: her biri "ekranı
    // çevir"deki gibi kendi İngilizce yazısının üstüne konur. Bloksuz olayda alanın çevirisi tek kutuda kalır.
    var blocks = Array.isArray(data.blocks) ? data.blocks : null;
    var kind = blocks && blocks.length ? 'region-blocks' : 'region';
    var el = regionBoxes[id];
    // Bloklar her olayda baştan dizilir; tek kutudan bloklara (ya da tersine) geçen alanın eski kutusu kalkar.
    if (el && (el.className !== kind || kind === 'region-blocks')) {
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
    if (kind === 'region-blocks') {
      placeItems(el, blocks);
      return;
    }
    var width = window.innerWidth || 1920;
    var height = window.innerHeight || 1080;
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
    var boxWidth = (box.right - box.left + 2 * REGION_PAD) * width;
    el.style.minWidth = Math.round(boxWidth) + 'px';
    el.style.maxWidth = Math.round(Math.max(boxWidth, width * 0.3)) + 'px';
    var line = typeof data.line === 'number' && data.line > 0 ? data.line * height : 30;
    el.style.fontSize = Math.max(REGION_MIN_FONT, Math.min(REGION_MAX_FONT, Math.round(line * 0.9))) + 'px';
  }

  function hideRegion(id) {
    var el = regionBoxes[id];
    if (!el) return;
    delete regionBoxes[id];
    $('regions').removeChild(el);
  }

  function hideRegions() {
    for (var id in regionBoxes) {
      if (Object.prototype.hasOwnProperty.call(regionBoxes, id)) $('regions').removeChild(regionBoxes[id]);
    }
    regionBoxes = {};
    $('regions').className = 'hidden';
  }

  // Konum hem CouchSubs uygulamasından hem kumandanın oklarıyla ayarlanır. Kumandayla
  // seçilen konum, uygulamadaki ayar değişene kadar korunur (son değiştiren geçerlidir).
  // Alttan en az %3: ekran kenarı taşan (overscan) TV'lerde altyazının alt satırı kesilmesin.
  var BOTTOM_MIN_PERCENT = 3;

  function setBottom(percent) {
    bottomPercent = Math.max(BOTTOM_MIN_PERCENT, Math.min(85, percent));
    layout();
  }

  var SIDE_MIN = 0.05;

  // Altyazıyı seçilen yerleşime göre konumlar. İngilizce altyazının yeri bilinmiyorsa sabit yükseklik kullanılır.
  function layout() {
    var el = $('subtitle');
    var cover = $('subtitle-cover');
    var box = placement === 'fixed' || !currentBox ? null : screenBox(currentBox, isOverlay());
    el.style.left = '8%';
    el.style.right = '8%';
    el.style.top = 'auto';
    el.style.bottom = bottomPercent + '%';
    cover.className = 'hidden';
    $('subtitle-text').style.background = textBackground;
    // Altyazı yokken (ör. ayar değişince yeniden yerleşirken) örtü tek başına boş siyah kutu olarak kalmasın.
    if (!box || el.className === 'hidden') return;

    var height = document.documentElement.clientHeight || window.innerHeight || 1080;
    var gap = Math.round(height * 0.012);
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
      placeCover(cover, box, $('subtitle-text').getBoundingClientRect());
      // Zemini örtü verir; çevirinin kendi yarı saydam zemini örtünün üstünde ikinci bir kutu gibi görünmesin.
      $('subtitle-text').style.background = 'transparent';
    } else if (mode === 'above') {
      el.style.bottom = Math.round((1 - box.top) * height + gap) + 'px';
    } else {
      el.style.bottom = 'auto';
      el.style.top = Math.round(box.bottom * height + gap) + 'px';
    }
    keepOnScreen(el, cover);
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
    var width = document.documentElement.clientWidth || window.innerWidth || 1920;
    var height = document.documentElement.clientHeight || window.innerHeight || 1080;
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
    // Örtü telefondaki "Arka plan koyuluğu"na uyar: eskiden hep %97'ydi, kaydırıcı %0'da da kutu opak kalıyordu.
    // %100 tamamen opaktır; koyuluğu göndermeyen eski sürümlerde style.css'teki %97 geçerlidir.
    cover.style.background = coverBackground;
    cover.className = '';
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
    $('subtitle-text').style.background = textBackground;
  }

  // Çevirinin zemini (bilgisayardaki "Zemin koyuluğu"); boşsa style.css'teki varsayılan. Örtü varken saydam olur.
  var textBackground = '';

  // Örtünün zemini (koyuluğa göre, %100'de tamamen opak; boşsa style.css'teki %97) ve tam genişlik bant mı; eski
  // bilgisayar uygulamaları alanı göndermez, yazı kadar kalır.
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

  function applyStyle(style) {
    if (style.fontSize) {
      fontBase = style.fontSize;
      $('subtitle-text').style.fontSize = style.fontSize + 'px';
      $('subtitle-prev-text').style.fontSize = Math.round(style.fontSize * 0.8) + 'px';
      $('subtitle-prev2-text').style.fontSize = Math.round(style.fontSize * 0.8) + 'px';
    }
    if (PLACEMENTS[style.placement]) placement = style.placement;
    bandShape = style.backgroundShape === 'band';
    setBodyClass('band', bandShape);
    if (typeof style.background === 'number') {
      var alpha = Math.max(0, Math.min(100, style.background)) / 100;
      // Zemin saydamsa yazıya sert kontur eklenir (style.css, body.thin-bg).
      setBodyClass('thin-bg', alpha < 0.5);
      // Saf siyah değil, hafif mavimsi siyah (#0c0e12): oyun görüntüsünün üstünde daha yumuşak durur.
      textBackground = 'rgba(12, 14, 18, ' + alpha + ')';
      coverBackground = style.background >= 100 ? '#0c0e12' : textBackground;
      $('subtitle-text').style.background = textBackground;
      $('subtitle-prev-text').style.background = 'rgba(12, 14, 18, ' + (alpha * 0.83).toFixed(2) + ')';
      $('subtitle-prev2-text').style.background = 'rgba(12, 14, 18, ' + (alpha * 0.83).toFixed(2) + ')';
    }
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
    if (TEXT_COLORS[style.textColor]) {
      $('subtitle-text').style.color = TEXT_COLORS[style.textColor];
      $('subtitle-prev-text').style.color = TEXT_COLORS[style.textColor];
      $('subtitle-prev2-text').style.color = TEXT_COLORS[style.textColor];
    }
    // Ekrandaki yazı yeni ayarlarla yeniden bölünür: yazı boyu, kalınlık, yerleşim ve bant bölmeyi değiştirir.
    var shown = rawText('subtitle-text');
    if ($('subtitle-text').rawText !== undefined && shown) setLineText('subtitle-text', shown, !!shownParagraphs, fontBase);
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

  var connectionGeneration = 0;
  var pairingTimer = null;
  // Eşleştirme kodu ekranda beklerken tarama aynı adresi bulursa bağlantı baştan kurulmaz (kod kaybolmasın).
  var pairingActive = false;
  // Eşleştirme kendiliğinden yeniden başlamaz (bilgisayarda yeni onay penceresi açılırdı); Tamam ile yeniden denenir.
  var pairingFailed = false;
  function stopPairing() { pairingActive = false; pairingFailed = true; $('pairing').textContent = t('pairRetry'); }
  function pairRequest(method, address, path, done) {
    var xhr = new XMLHttpRequest(), finished = false;
    function finish(data) { if (finished) return; finished = true; done(data); }
    xhr.onload = function () {
      var data = null;
      if (xhr.status === 200) { try { data = JSON.parse(xhr.responseText); } catch (e) {} }
      finish(data);
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
    if (address !== server) failures = 0;
    server = address;
    pairRequest('GET', address, '/hello', function (hello) {
      if (generation !== connectionGeneration) return;
      if (!hello || hello.app !== 'couchsubs') { scanForServer(); return; }
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
        pairRequest('GET', address, '/pair?validate=1&k=' + encodeURIComponent(key), function (result) {
          if (generation !== connectionGeneration) return;
          if (result && result.state === 'valid') { remember(key); connectStream(address); }
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
        $('pairing').textContent = t('pairServer');
        pairRequest('POST', address, '/pair', function (ticket) {
          if (generation !== connectionGeneration) return;
          if (!ticket || !/^[A-Za-z0-9_-]{22}$/.test(ticket.id || '') || !/^[0-9]{6}$/.test(ticket.code || '')) {
            stopPairing();
            pairingTimer = setTimeout(function () { if (generation === connectionGeneration) connect(address); }, 15000);
            return;
          }
          var deadline = Date.now() + 120000;
          $('pairing').textContent = t('pairCode') + ' ' + ticket.code + ' — ' + t('pairServer');
          setStatus('st-conn', t('pairCode') + ' ' + ticket.code, 'muted');
          function poll() {
            if (generation !== connectionGeneration) return;
            if (Date.now() >= deadline) { stopPairing(); return; }
            pairRequest('GET', address, '/pair?id=' + encodeURIComponent(ticket.id), function (result) {
              if (generation !== connectionGeneration) return;
              if (result && result.state === 'approved' && /^[A-Za-z0-9_-]{22}$/.test(result.key || '')) {
                remember(result.key); $('pairing').textContent = ''; connectStream(address); return;
              }
              if (result && result.state === 'expired') { stopPairing(); return; }
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
    eventSource = new EventSource(authenticatedUrl(address, '/events'));
    lastActivity = Date.now();
    eventSource.onopen = function () {
      lastActivity = Date.now();
      failures = 0;
      clearTimeout(pairingTimer);
      cancelScan();
      clearTimeout(dropTimer);
      dropTimer = null;
      setStatus('st-conn', t('connected'), 'ok');
      learnServer(address);
    };
    eventSource.onerror = function () {
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
    onEvent('region', showRegion);
    onEvent('region-clear', hideRegions);
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
  // Bilgisayar TV uygulamasını açamıyorsa adres gelmez; kayıtlı adres de eskiyebilir (altyazı kaynağı başka cihaz oldu
  // ya da cihazın IP'si değişti). Uygulama o zaman ağı tarar: TV'nin kendi ağını (adresini söyleyebiliyorsa) ve kayıtlı
  // adresin ağını. Kayıtlı adres art arda FAILS_BEFORE_SCAN kez yanıt vermezse tarama kısa süre içinde başlar.

  var SERVER_PORT = 8787;
  var SCAN_PARALLEL = 24;
  var SCAN_TIMEOUT_MS = 1200;
  var SCAN_PAUSE_MS = 30000;
  var SCAN_SOON_MS = 3000;
  var FAILS_BEFORE_SCAN = 3;
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
    function finish(ip) {
      if (ip && ip !== tvAddress) {
        tvAddress = ip;
        renderWaitingStatus();
      }
      var list = [];
      var own = subnetOf(ip);
      if (own) list.push(own);
      if (fromServer && fromServer !== own) list.push(fromServer);
      if (list.length) return done(list, false);
      done(GUESS_SUBNETS.slice(), true);
    }
    if (!platform.localAddress) return finish(null);
    var answered = false;
    function once(ip) {
      if (answered) return;
      answered = true;
      finish(ip);
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
  function pickServer(found, savedId) {
    var i, idle = [];
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
        return;
      }
      if (adopt || !serverId) {
        serverId = id;
        save('serverId', id);
      }
      var wasFallback = fallback;
      fallback = id !== serverId;
      if (fallback) scheduleScan(wasFallback ? FALLBACK_SCAN_MS : SCAN_SOON_MS);
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
        if (guessed && !done && !fallback && eventSource && eventSource.readyState === 1) {
          done = true;
          scanning = false;
          return;
        }
        while (!done && active < SCAN_PARALLEL && next < stop) {
          active++;
          tryAddress(addresses[next++]);
        }
        if (done || active || next < stop) return;
        if (found.length || stop >= addresses.length) return finish(pickServer(found, serverId));
        stop = Math.min(stop + 254, addresses.length);
        pump();
      }
      // Kayıtlı kimlik bulununca tarama hemen biter; yoksa bütün ağ taranıp aralarından seçilir (eskiden ilk bulunan).
      function tryAddress(address) {
        probe(address, function (ok, info) {
          active--;
          if (done) return;
          if (ok) {
            var entry = { address: address, id: info.id ? String(info.id) : null, tvs: typeof info.tvs === 'number' ? info.tvs : null };
            found.push(entry);
            if (serverId && entry.id === serverId) return finish(entry);
          }
          pump();
        });
      }
      function finish(choice) {
        done = true;
        scanning = false;
        if (!choice) {
          scheduleScan(fallback ? FALLBACK_SCAN_MS : SCAN_PAUSE_MS);
          return;
        }
        // Bulunan adres kaydedilir: TV bir sonraki açılışta eski adrese takılmasın.
        save('server', choice.address);
        // Aynı bilgisayarsa EventSource kendisi yeniden bağlanır; kapanıp vazgeçtiyse (CLOSED) yeniden kurulur.
        // Eşleştirme beklemiyor (ya da Tamam'ı beklemiyor) ve bağlantı da yoksa (bilgisayar kapalıyken /hello yanıtsız
        // kalmıştı) yeniden kurulur.
        if (choice.address !== server || (eventSource ? eventSource.readyState === 2 : !pairingActive && !pairingFailed)) connect(choice.address);
        else if (fallback) scheduleScan(FALLBACK_SCAN_MS);
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

  function resumeAfterHidden() {
    if (!pausedByHidden) return;
    pausedByHidden = false;
    if (server) connect(server);
  }

  document.addEventListener('visibilitychange', function () {
    if (document.hidden) {
      noteHidden();
      dropWhileHidden();
    } else {
      resumeAfterHidden();
      noteVisible();
    }
  });

  // --- Panel ve kumanda ---

  // "1–4: HDMI girişi · 0: …" satırını tuş başına bir satıra böler; tuş adı vurgu renginde.
  function formatKeys() {
    var el = $('keys');
    var text = el.textContent;
    // Geniş ekranlı Samsung'da (21:9, 32:9) Sarı tuş HDMI görüntüsünü sığdırır ya da ekranı doldurur (#304).
    if (pictureModes()) text += ' · ' + t('keyPicture');
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

  // Sarı: geniş ekranda HDMI görüntüsü 16:9 tam yükseklik (yanlarda siyah) ya da ekranın tamamı (gerilmiş).
  function togglePicture() {
    if (!pictureModes()) return;
    var mode = platform.togglePicture();
    showSubtitle(t(mode === 'fill' ? 'pictureFill' : 'pictureFit'), 3000);
  }

  // Panel açıkken bekleme kutusu kapanır: ikisi üst üste binince yazılar okunmuyor.
  function showPanel(autoHide) {
    hidePanelTip();
    $('waiting').className = 'hidden';
    $('panel').className = '';
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
    hdmiPort = (hdmiPort + step + 3) % 4 + 1;
    save('hdmi', hdmiPort);
    showHdmi(hdmiPort);
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
    } else if (code >= 49 && code <= 52) { // 1–4
      hdmiPort = code - 48;
      save('hdmi', hdmiPort);
      showHdmi(hdmiPort);
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
  platform.onRelaunch(function (raw) { applyParams(parseParams(raw)); });

  platform.init();
  window.applyI18n();
  formatKeys();
  var savedBottom = load('bottom') || load('appBottom');
  if (savedBottom) setBottom(Number(savedBottom));
  startHdmi();

  $('app-version').textContent = APP_VERSION;
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
