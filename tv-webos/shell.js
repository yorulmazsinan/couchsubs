// SPDX-License-Identifier: AGPL-3.0-only
// CouchSubs TV kabuğu (ince kabuk, docs/tv-ince-kabuk.md). TV'de kurulu kalan kısım platform.js (HDMI, kumanda, TV'ye
// özgü çağrılar), config.js ve bu dosyadır; sayfanın kendisi (index.html'in gövdesi, style.css, i18n.js, app.js) paketle
// gelen yedektir. Eşleşmiş bilgisayar ya da telefon daha yeni sayfa sunuyorsa (GET /tv/app/manifest) kabuk onu indirir,
// eşleşme anahtarıyla imzayı (HMAC-SHA256) ve her dosyanın SHA-256 özetini doğrular, saklar ve sayfayı yeniden açar;
// sonraki açılışlarda saklanan sayfa yedeğin yerine çalışır. Doğrulanmayan, yerel ağdan gelmeyen ya da bu kabuğun
// arayüzünden (SHELL_API) yenisini isteyen kod çalıştırılmaz. Eski TV tarayıcıları (webOS 3 / Chromium 38, Tizen 2.4)
// için ES5 ile yazıldı; fetch, Promise, crypto.subtle kullanılmaz.
(function () {
  'use strict';

  // TV uygulamasının (kabuğun) sürümü: appinfo.json, tv-tizen/config.xml, tv-android/app/build.gradle ve paketle gelen
  // app.js'in APP_VERSION'ıyla aynı tutulur (scripts/tv-shell.test.js denetler).
  var SHELL_VERSION = '0.9.72';
  // Kabuğun sayfaya verdiği arayüzün sürümü (ShellAPI). Sayfa kendi app.js'inde SHELL_API ile hangi sürümü istediğini
  // bildirir; bu kabuktan yenisini isteyen sayfa yüklenmez. Arayüz değişince (platform.js'e sayfanın şart koştuğu yeni
  // bir çağrı eklenince) ikisi birlikte artırılır.
  var SHELL_API = 1;
  var PATHS = ['index.html', 'style.css', 'i18n.js', 'app.js'];
  var CACHE_KEY = 'couchsubs.shell.page';
  var BAD_KEY = 'couchsubs.shell.bad';
  var RELOAD_KEY = 'couchsubs.shell.reload';
  // Aynı sunucu bu süre içinde yeniden sorulmaz (bağlantı her koptuğunda liste indirilmesin).
  var CHECK_GAP_MS = 10 * 60 * 1000;
  var TIMEOUT_MS = 10000;

  function load(key) {
    try { return window.localStorage.getItem(key); } catch (e) { return null; }
  }
  function save(key, value) {
    try { window.localStorage.setItem(key, value); return true; } catch (e) { return false; }
  }
  function drop(key) {
    try { window.localStorage.removeItem(key); } catch (e) {}
  }
  function now() { return new Date().getTime(); }

  // --- SHA-256 ve HMAC-SHA256 (FIPS 180-4, RFC 2104) ---
  // Girdi "bayt dizesi"dir: her karakter 0-255 arası bir bayt (utf8() ile).
  var K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];

  function utf8(text) { return unescape(encodeURIComponent(text)); }

  function sha256Bytes(bytes) {
    var length = bytes.length;
    var words = [];
    var i;
    for (i = 0; i < length; i++) words[i >> 2] |= (bytes.charCodeAt(i) & 0xff) << (24 - (i % 4) * 8);
    words[length >> 2] |= 0x80 << (24 - (length % 4) * 8);
    var total = (((length + 8) >> 6) + 1) * 16;
    for (i = words.length; i < total; i++) words[i] = 0;
    // Bit uzunluğu son iki sözcükte (2^32 bayttan kısa girdiler için üst sözcük yalnız taşmayı taşır).
    words[total - 2] = Math.floor(length / 0x20000000);
    words[total - 1] = (length * 8) | 0;
    var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
    var w = new Array(64);
    for (var block = 0; block < total; block += 16) {
      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (var t = 0; t < 64; t++) {
        if (t < 16) w[t] = words[block + t] | 0;
        else {
          var x = w[t - 15], y = w[t - 2];
          var s0 = ((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3);
          var s1 = ((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10);
          w[t] = (w[t - 16] + s0 + w[t - 7] + s1) | 0;
        }
        var S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
        var ch = (e & f) ^ (~e & g);
        var t1 = (h + S1 + ch + K[t] + w[t]) | 0;
        var S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
        var maj = (a & b) ^ (a & c) ^ (b & c);
        var t2 = (S0 + maj) | 0;
        h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0;
      h4 = (h4 + e) | 0; h5 = (h5 + f) | 0; h6 = (h6 + g) | 0; h7 = (h7 + h) | 0;
    }
    var out = '';
    var state = [h0, h1, h2, h3, h4, h5, h6, h7];
    for (i = 0; i < 8; i++) {
      out += String.fromCharCode((state[i] >>> 24) & 0xff, (state[i] >>> 16) & 0xff, (state[i] >>> 8) & 0xff, state[i] & 0xff);
    }
    return out;
  }

  function hex(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i++) out += (0x100 + bytes.charCodeAt(i)).toString(16).slice(1);
    return out;
  }

  function sha256(text) { return hex(sha256Bytes(utf8(text))); }

  function hmacSha256(key, text) {
    var k = utf8(key);
    if (k.length > 64) k = sha256Bytes(k);
    var inner = '', outer = '';
    for (var i = 0; i < 64; i++) {
      var byte = i < k.length ? k.charCodeAt(i) : 0;
      inner += String.fromCharCode(byte ^ 0x36);
      outer += String.fromCharCode(byte ^ 0x5c);
    }
    return hex(sha256Bytes(outer + sha256Bytes(inner + utf8(text))));
  }

  // Uzunluğu belli iki onaltılık özeti karşılaştırır; ilk farkta durmaz.
  function sameHex(a, b) {
    if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
  }

  // --- Sürüm, adres ve liste denetimi ---

  var VERSION = /^[0-9]+(\.[0-9]+){1,3}$/;
  var KEY = /^[A-Za-z0-9_-]{22}$/;

  // a, b'den yeni mi ("0.9.75" > "0.9.72").
  function newer(a, b) {
    var x = String(a).split('.'), y = String(b).split('.');
    for (var i = 0; i < Math.max(x.length, y.length); i++) {
      var left = Number(x[i] || 0), right = Number(y[i] || 0);
      if (left !== right) return left > right;
    }
    return false;
  }

  // Yalnız yerel ağdaki (özel IPv4, bağlantı yerel ya da benzersiz yerel IPv6) http adresleri. Ad (mac.local) kabul
  // edilmez: adı çözen sunucu başka biri olabilir. CouchSubs TV'ye adresini IP olarak verir.
  function localServer(address) {
    var match = /^http:\/\/(\[[0-9a-fA-F:]+\]|[0-9]{1,3}(?:\.[0-9]{1,3}){3})(?::([0-9]{1,5}))?\/?$/.exec(String(address || ''));
    if (!match) return null;
    var host = match[1];
    if (host.charAt(0) === '[') {
      var v6 = host.slice(1, -1).toLowerCase();
      if (!/^(f[cd][0-9a-f]{0,2}:|fe[89ab][0-9a-f]?:)/.test(v6)) return null;
    } else {
      var p = host.split('.');
      for (var i = 0; i < 4; i++) if (Number(p[i]) > 255) return null;
      var a = Number(p[0]), b = Number(p[1]);
      var ok = a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
        (a === 169 && b === 254) || (a === 100 && b >= 64 && b <= 127);
      if (!ok) return null;
    }
    if (match[2] && !(Number(match[2]) > 0 && Number(match[2]) < 65536)) return null;
    return 'http://' + host + (match[2] ? ':' + match[2] : '');
  }

  function canonical(manifest) {
    var text = 'couchsubs-tv-app/1\n' + manifest.version + '\n' + manifest.shellApi + '\n';
    for (var i = 0; i < manifest.files.length; i++) {
      var file = manifest.files[i];
      text += file.path + ' ' + file.size + ' ' + file.sha256 + '\n';
    }
    return text;
  }

  // Liste biçimi ve imzası; sorun varsa nedeni, yoksa ''.
  function checkManifest(manifest, key) {
    if (!manifest || manifest.format !== 1) return 'format';
    if (typeof manifest.version !== 'string' || !VERSION.test(manifest.version)) return 'version';
    if (typeof manifest.shellApi !== 'number' || manifest.shellApi < 1 || manifest.shellApi % 1 !== 0) return 'shellApi';
    var files = manifest.files;
    if (!files || files.length !== PATHS.length) return 'files';
    for (var i = 0; i < PATHS.length; i++) {
      var file = files[i];
      if (!file || file.path !== PATHS[i] || typeof file.size !== 'number' || !(file.size > 0) ||
          typeof file.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(file.sha256)) return 'files';
    }
    if (!sameHex(hmacSha256(key, canonical(manifest)), manifest.hmac)) return 'hmac';
    return '';
  }

  // --- Saklanan sayfa ---

  function readCache() {
    var raw = load(CACHE_KEY);
    if (!raw) return null;
    var page;
    try { page = JSON.parse(raw); } catch (e) { page = null; }
    if (!page || typeof page.version !== 'string' || !VERSION.test(page.version) || !page.files || !page.sizes) return null;
    // Kabuk güncellendiyse (yedek sayfa saklanandan yeni ya da aynı) saklanan bırakılır.
    if (!newer(page.version, SHELL_VERSION) || !(page.shellApi >= 1 && page.shellApi <= SHELL_API)) return null;
    if (load(BAD_KEY) === page.version) return null;
    for (var i = 0; i < PATHS.length; i++) {
      var text = page.files[PATHS[i]];
      // Özet indirirken doğrulandı; saklanan kayıt tek parçadır. Açılışı yavaşlatmamak için yalnız boyu denetlenir.
      if (typeof text !== 'string' || utf8(text).length !== page.sizes[PATHS[i]]) return null;
    }
    return page;
  }

  // --- Sayfayı başlatma ---

  var page = { version: SHELL_VERSION, source: 'bundled' };
  var note = '';
  var started = false;

  function body(html) {
    var start = html.search(/<body[^>]*>/i);
    var end = html.search(/<\/body>/i);
    if (start < 0) return '';
    var inner = html.slice(html.indexOf('>', start) + 1, end > start ? end : html.length);
    return inner.replace(/<script\b[\s\S]*?<\/script>/gi, '');
  }

  // Uzak sayfanın gövdesi kabuğun gövdesinin yerine geçer. Görüntü katmanı (#video-host) kabuğunki kalır; panel
  // simgesinin adı platforma göre değişebildiği için (Samsung: panel-icon.png) kabuğun kullandığı ad korunur.
  function applyMarkup(html) {
    var markup = body(html);
    if (!markup) throw new Error('no body');
    var logo = document.querySelector('#panel .logo');
    var icon = logo && logo.getAttribute('src');
    if (icon && icon !== 'icon.png') markup = markup.replace(/src="icon\.png"/g, 'src="' + icon + '"');
    var holder = document.createElement('div');
    holder.innerHTML = markup;
    var root = document.body;
    var anchor = null;
    var keep = document.getElementById('video-host');
    var nodes = [];
    var i;
    for (i = 0; i < root.childNodes.length; i++) nodes.push(root.childNodes[i]);
    for (i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      if (node.nodeName === 'SCRIPT') { if (!anchor) anchor = node; continue; }
      if (node !== keep) root.removeChild(node);
    }
    while (holder.firstChild) {
      var next = holder.firstChild;
      if (keep && next.id === 'video-host') {
        holder.removeChild(next);
        root.insertBefore(keep, anchor);
        continue;
      }
      root.insertBefore(next, anchor);
    }
  }

  function applyStyle(css) {
    var links = document.getElementsByTagName('link');
    for (var i = links.length - 1; i >= 0; i--) {
      if (/(^|\/)style\.css$/.test(links[i].getAttribute('href') || '')) links[i].parentNode.removeChild(links[i]);
    }
    var style = document.createElement('style');
    style.id = 'page-style';
    style.appendChild(document.createTextNode(css));
    document.getElementsByTagName('head')[0].appendChild(style);
  }

  function inject(code, name) {
    var script = document.createElement('script');
    script.setAttribute('data-page', name);
    script.text = code + '\n//# sourceURL=couchsubs-page/' + name;
    document.body.appendChild(script);
  }

  function reload() {
    try { window.location.reload(); } catch (e) {}
  }

  function startRemote(cached) {
    page = { version: cached.version, source: 'remote' };
    started = false;
    try {
      applyStyle(cached.files['style.css']);
      applyMarkup(cached.files['index.html']);
      inject(cached.files['i18n.js'], 'i18n.js');
      inject(cached.files['app.js'], 'app.js');
    } catch (e) {
      note = 'remote ' + cached.version + ': ' + e.message;
    }
    if (started) return true;
    // Sayfa açılamadı (sözdizimi hatası, eski tarayıcıda olmayan bir çağrı): bu sürüm bir daha denenmez, yedekle açılır.
    save(BAD_KEY, cached.version);
    drop(CACHE_KEY);
    reload();
    return false;
  }

  function startBundled() {
    page = { version: SHELL_VERSION, source: 'bundled' };
    // Ayrıştırma sırasında yazılan betikler hemen bu betikten sonra, sırayla çalışır (eski davranışın aynısı).
    document.write('<script src="i18n.js"><\/script><script src="app.js"><\/script>');
  }

  // --- Güncelleme denetimi ---

  var checking = false;
  var lastCheck = {};

  function request(url, done) {
    var xhr = new XMLHttpRequest(), finished = false;
    function finish(text) { if (finished) return; finished = true; done(text); }
    xhr.onload = function () { finish(xhr.status === 200 ? xhr.responseText : null); };
    xhr.onerror = xhr.ontimeout = function () { finish(null); };
    try {
      xhr.open('GET', url);
      xhr.timeout = TIMEOUT_MS;
      if (xhr.overrideMimeType) xhr.overrideMimeType('text/plain; charset=utf-8');
      xhr.send();
    } catch (e) { finish(null); }
  }

  function finishCheck(reason) {
    checking = false;
    if (reason) note = reason;
  }

  // Sayfa sunucuya bağlanınca çağırır (eşleşme anahtarıyla). Sunucu daha yeni ve doğrulanan bir sayfa sunuyorsa saklanır
  // ve sayfa yeniden açılır.
  function connected(address, key) {
    // Anahtarsız (eşleşmemiş) sunucudan sayfa istenmez.
    if (!KEY.test(key || '') || checking) return;
    var base = localServer(address);
    if (!base) { note = 'update: not local'; return; }
    if (lastCheck[base] && now() - lastCheck[base] < CHECK_GAP_MS) return;
    lastCheck[base] = now();
    checking = true;
    var query = '?k=' + encodeURIComponent(key);
    request(base + '/tv/app/manifest' + query, function (text) {
      var manifest = null;
      try { manifest = text ? JSON.parse(text) : null; } catch (e) { manifest = null; }
      // Sunucu sayfa sunmuyor (eski CouchSubs ya da geliştirme derlemesi): yedekte kalınır.
      if (!manifest) { finishCheck(''); return; }
      var problem = checkManifest(manifest, key);
      if (problem) { finishCheck('update rejected: ' + problem); return; }
      if (!newer(manifest.version, page.version)) { finishCheck(''); return; }
      if (manifest.shellApi > SHELL_API) { finishCheck('update ' + manifest.version + ' needs shell api ' + manifest.shellApi); return; }
      if (load(BAD_KEY) === manifest.version) { finishCheck('update ' + manifest.version + ' failed before'); return; }
      var reloaded = null;
      try { reloaded = JSON.parse(load(RELOAD_KEY) || 'null'); } catch (e) { reloaded = null; }
      if (reloaded && reloaded.version === manifest.version && now() - reloaded.at < CHECK_GAP_MS) {
        finishCheck('update ' + manifest.version + ' not applied');
        return;
      }
      var files = {}, sizes = {};
      var index = 0;
      (function next() {
        if (index === PATHS.length) {
          var stored = JSON.stringify({ version: manifest.version, shellApi: manifest.shellApi, files: files, sizes: sizes });
          if (!save(CACHE_KEY, stored)) { finishCheck('update ' + manifest.version + ': storage full'); return; }
          save(RELOAD_KEY, JSON.stringify({ version: manifest.version, at: now() }));
          finishCheck('update ' + manifest.version);
          reload();
          return;
        }
        var entry = manifest.files[index];
        request(base + '/tv/app/' + manifest.version + '/' + entry.path + query, function (content) {
          if (content === null) { finishCheck('update ' + manifest.version + ': ' + entry.path + ' not loaded'); return; }
          var bytes = '';
          try { bytes = utf8(content); } catch (e) { bytes = ''; }
          if (bytes.length !== entry.size || !sameHex(hex(sha256Bytes(bytes)), entry.sha256)) {
            finishCheck('update rejected: ' + entry.path + ' sha256');
            return;
          }
          files[entry.path] = content;
          sizes[entry.path] = entry.size;
          index++;
          next();
        });
      })();
    });
  }

  // --- Kabuk arayüzü (ShellAPI v1) ---
  // Sayfa platforma yalnız bunlarla erişir: COUCHSUBS_SHELL.platform (platform.js'in COUCHSUBS_PLATFORM nesnesi),
  // window.COUCHSUBS_CONFIG ve aşağıdaki çağrılar. Ayrıntı docs/tv-ince-kabuk.md.
  window.COUCHSUBS_SHELL = {
    api: SHELL_API,
    version: SHELL_VERSION,
    platform: window.COUCHSUBS_PLATFORM,
    config: window.COUCHSUBS_CONFIG || {},
    // Çalışan sayfa: { version, source: 'bundled' | 'remote' }.
    page: function () { return { version: page.version, source: page.source }; },
    // Sayfa açılışını bitirince çağırır; çağırmayan uzak sayfa bozuk sayılır.
    started: function () { started = true; },
    connected: connected,
    // Bilgi panelinin tanı satırı için.
    status: function () {
      return 'shell ' + SHELL_VERSION + (page.source === 'remote' ? ' · page ' + page.version + ' remote' : '') +
        (note ? ' · ' + note : '');
    },
    // Testler için (scripts/tv-shell.test.js).
    _test: { sha256: sha256, hmac: hmacSha256, canonical: canonical, checkManifest: checkManifest, newer: newer,
      localServer: localServer, readCache: readCache, body: body }
  };

  var cached = null;
  try { cached = readCache(); } catch (e) { cached = null; }
  if (!cached) {
    startBundled();
    return;
  }
  var pending = null;
  try { pending = JSON.parse(load(RELOAD_KEY) || 'null'); } catch (e) { pending = null; }
  if (pending && pending.version === cached.version) drop(RELOAD_KEY);
  // Açılamazsa sayfa yeniden yüklenir ve yedekle açılır (bkz. startRemote).
  startRemote(cached);
})();
