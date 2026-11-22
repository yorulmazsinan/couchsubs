// SPDX-License-Identifier: AGPL-3.0-only
// webOS'a özgü işler. Tizen karşılığı: tv-tizen/platform.js
(function () {
  'use strict';

  var NETWORK_STATUS = ['luna://com.webos.service.connectionmanager/getStatus', 'luna://com.palm.connectionmanager/getStatus'];

  // connectionmanager/getStatus yanıtındaki adres: bağlı kablolu, sonra bağlı kablosuz, sonra herhangi biri; yoksa null.
  function addressFromStatus(msg) {
    var status;
    try { status = JSON.parse(msg) || {}; } catch (e) { return null; }
    var wired = status.wired || {};
    var wifi = status.wifi || {};
    if (wired.state === 'connected' && wired.ipAddress) return wired.ipAddress;
    if (wifi.state === 'connected' && wifi.ipAddress) return wifi.ipAddress;
    return wired.ipAddress || wifi.ipAddress || null;
  }

  // --- Konsolun girişi ---
  // luna://com.webos.service.eim/getAllInputStatus LG'nin TV belgelerinde yok (LG'nin geliştirici forumu: "giriş durumunu
  // veren bir API sağlanmıyor"); yanıtta yalnız bu uygulamanın 0.9'dan beri okuduğu alanlar kullanılır: id (HDMI_n),
  // port, label, activate (girişte sinyal var), spdSourceDeviceInfo (HDMI SPD bilgisi: 'GAME') ve
  // spdProductDescription (SPD'deki ürün adı). Başka alan varsayılmaz; alan yoksa sıra yine kurulur.
  // X'te LG OLED C2: PS5 soundbar üzerinden bağlı (soundbar TV'nin eARC girişinde, HDMI 2), çeviri başlayınca siyah
  // ekran. Sıra: konsol (sinyalli, sonra sinyalsiz), sinyalli başka cihaz, sinyalli ses cihazı (soundbar, AV alıcı;
  // görüntüyü konsoldan geçiriyor olabilir ama kendi adıyla görünüyorsa sona), en son sinyalsizler (aday değil).
  // İlk adayda görüntü gelmezse app.js sıradakini dener.
  var RANK_NONE = 4;
  var CONSOLE_NAME = /playstation|ps5|ps4|xbox/i;
  var AUDIO_NAME = /sound ?bar|receiver|\bavr\b|home ?(theat|cinema)|\bbar\b|sonos|bose|denon|marantz|onkyo|yamaha|harman|\bjbl\b|polk|klipsch|sennheiser|\bhw-|\bht-/i;
  var knownInputs = [];

  // devices: getAllInputStatus yanıtındaki liste. Dönen: HDMI girişleri {port, label, rank} sıralı (aynı sırada giriş
  // numarası küçük olan önce).
  function rankInputs(devices) {
    var out = [];
    for (var i = 0; i < (devices || []).length; i++) {
      var d = devices[i] || {};
      if (!/^HDMI_/.test(d.id || '')) continue;
      var port = Number(d.port) || Number(String(d.id).replace('HDMI_', '')) || 0;
      if (port < 1) continue;
      var name = (d.label || '') + ' ' + (d.spdProductDescription || '');
      var isConsole = d.spdSourceDeviceInfo === 'GAME' || CONSOLE_NAME.test(name);
      var rank;
      if (isConsole) rank = d.activate ? 0 : 1;
      else if (d.activate) rank = AUDIO_NAME.test(name) ? 3 : 2;
      else rank = RANK_NONE;
      out.push({ port: port, label: d.label || ('HDMI ' + port), rank: rank });
    }
    out.sort(function (a, b) { return a.rank - b.rank || a.port - b.port; });
    return out;
  }

  // --- HDMI görüntüsünün gözcüsü ---
  // HDMI girişi <video> ile (ext://hdmi) gösterilir. Görüntü oyunun ortasında kesilirse (ekran siyah, altyazı geliyor,
  // oyun arkada sürüyor) ya da uygulama arka plandan dönünce <video> kendiliğinden toparlanmıyordu; görüntü oynamayınca TV
  // de boşta sanıp ekran koruyucuya ve uykuya geçebiliyor. Gözcü <video>'yu izler, görüntü düşünce onu yeniden kurar.
  // Çalışan görüntüye dokunulmaz: yalnız açık bir bozulma işareti varsa kurulur (hata, kare yok, duraklamış, önce ilerleyen
  // sayaç durmuş) ve denemeler gittikçe seyrekleşir. Gerçek LG'de denenmedi; durum bilgi panelinde yazar (diagnostics).
  var CHECK_MS = 5000;
  // Yeni kurulan <video> bu süre "yükleniyor" sayılır.
  var GRACE_MS = 8000;
  // currentTime'ı ilerleten TV'de sayaç bu kadar durursa görüntü kesilmiştir.
  var STALL_MS = 15000;
  var BACKOFF_MS = [2000, 4000, 8000, 16000, 30000, 60000];
  var MAX_PER_MINUTE = 4;
  // Bu girişte görüntü hiç gelmediyse (yanlış giriş, konsol kapalı) birkaç denemeden sonra durulur.
  var NEVER_PLAYED_MAX = 3;
  var STEADY_MS = 30000;
  var REBUILD_GAP_MS = 1000;

  var hdmi = {
    port: 0, host: null, onStatus: null, video: null, builtAt: 0,
    played: false, everPlayed: false,
    rebuilds: 0, failures: 0, sincePort: 0, recent: [], reason: '', lastError: '', lastEvent: '',
    lastTime: -1, lastAdvanceAt: 0, advances: 0, playTried: false, sawUnpaused: false,
    pending: null, building: null, checkTimer: null, soonTimer: null, soonStrict: false, wasHidden: false,
    stalls: 0, stallNote: '', stallRebuiltAt: 0, stallTimer: null,
    stallVideo: null, stallTime: 0, stallRebuilds: []
  };

  function nowMs() { return new Date().getTime(); }

  function pageHidden() { return !!(document.hidden || document.webkitHidden); }

  function describeError(error) {
    if (!error) return '';
    return 'code ' + error.code + (error.message ? ' ' + String(error.message).slice(0, 40) : '');
  }

  // hard: boru hattı da bırakılır (yeniden kurmadan önce). Giriş değiştirirken eskisi gibi yalnız sayfadan çıkarılır.
  function releaseVideo(video, hard) {
    if (!video) return;
    if (hard) {
      try {
        video.pause();
        while (video.firstChild) video.removeChild(video.firstChild);
        video.removeAttribute('src');
        video.load();
      } catch (e) {}
    }
    try { if (video.parentNode) video.parentNode.removeChild(video); } catch (e2) {}
  }

  // --- HDMI sesi ---
  // X'te LG 55QNED86A6A (webOS 24/25, iPhone ile): "çeviri var ama ses gelmiyor; PS tuşuna basınca ses geliyor, çeviri
  // gidiyor". PS tuşu TV'yi HDMI-CEC ile kendi HDMI girişine geçirir, uygulama arkaya düşer: ses TV'nin kendi giriş
  // yolunda geliyor, uygulamanın içinde açılan <video> (ext://hdmi) yolunda gelmiyor. Bu sayfada sesi kısan bir şey yoktu;
  // yine de <video> açıkça sesli istenir: muted/defaultMuted false, volume 1. LG'nin webOS TV 5.0 SSS'i ses parçası
  // kapalı (audioTracks[i].enabled false) gelen içerikte sesin hiç çalmadığını ve parçanın açılması gerektiğini söylüyor;
  // hiçbir parça açık değilse ilki açılır. Gerçek LG'de denenmedi.
  // Bildirimlerin ortak yanı harici ses sistemi: X'te ikinci bir kullanıcı ses sistemine (soundbar) bağlıyken aynısını
  // yaşıyor, TV hoparlörüne geçince düzeliyor; aynı seride (QNED86T6A, #373) Bluetooth çıkışta ses gelmiyor, TV
  // hoparlöründe geliyordu. Tahmin: TV kendi girişinde PS5'in sıkıştırılmış sesini (Dolby/DTS) ARC/eARC'a olduğu gibi
  // geçiriyor, uygulamanın içindeki oynatıcı yolunda geçirmiyor. Bunu sayfa değiştiremez; geçici yol TV'nin Dijital Ses
  // Çıkışı'nı Otomatik/PCM ya da PS5'in Ses Biçimi'ni Linear PCM yapmak. TV'nin ses çıkışı ve ses düzeyi bilgi paneline
  // yazılır (soundOutput: tv_speaker, external_arc, external_optical, bt_soundbar ...).
  //
  // 0.9.48: X'te aynı model (55QNED86A6A, soundbar bağlı) "altyazı telefonda" seçilince (TV kendi girişinde) ses hem
  // soundbarda hem TV hoparlöründe geliyor, TV uygulaması öne gelince ikisinde de gidiyor. LG'nin TV belgelerinde HDMI'yi
  // uygulama içinde göstermenin resmi bir yolu yok (yol webosbrew'in belgelediği <video> + ext://hdmi). webOS OSE'nin
  // Chromium kaynağında bu <video> uMediaServer oynatıcısıyla açılır: istekte option.needAudio "noaudio" yoksa true
  // gider, ses çıkışı (audio sink) 'playing'de ses düzeyi yeniden verilerek bağlanır; yukarıdaki sesli istek bunu
  // sağlam tutar. Aynı kaynakta öğenin bir de ses odağı özelliği var (webosMediaFocus, olay webosmediafocuschange):
  // TV'de varsa odak açıkça istenir. Bağlanırken TV'nin sesi kısılı kalırsa (açılışta kısık değildi) LG'nin belgeli
  // com.webos.audio/setMuted ile bir kez açılır. İkisi de görüntüye dokunmaz; özellik yoksa ya da izin verilmezse eski
  // yol aynen sürer, sonuç tanı satırına yazılır (mf, tvmute). TV'nin dijital ses çıkışı (soundOutputDigital:
  // passThrough/auto/pcm) da okunur: tahmin, sıkıştırılmış ses (Dolby/DTS) uygulama içindeki yolda hiç çalınmıyor; PS5
  // Linear PCM'e alınınca düzeliyorsa bu doğrulanır. Gerçek LG'de denenmedi.
  //
  // 0.9.53: X'te LG OLED: "güncellemeden sonra çeviriyi başlatınca ekran siyah, oyun gelmiyor; önceden sorun yoktu".
  // 0.9.46'dan sonra HDMI yoluna yalnız bu ses adımları girdi; ses odağı ve ses parçası 'loadedmetadata'da, yani
  // görüntü daha gelmeden isteniyordu. Tahmin (gerçek TV'de doğrulanmadı): bazı webOS sürümlerinde bu istek <video>'nun
  // HDMI boru hattını askıya alıyor ya da yeniden kurduruyor. Artık:
  // - Görüntü gelene kadar <video> 0.9.46'daki gibi kurulur; ses adımı, ses ayarı okuma, odak hiçbiri yapılmaz.
  // - Adımlar görüntü SOUND_AFTER_MS kesintisiz geldikten sonra bir kez denenir, her biri hatası yutularak.
  // - Adımlardan sonra SOUND_WATCH_MS içinde görüntü düşerse (gözcü yeniden kurar ya da kullanıcı girişi yeniden seçer)
  //   ya da görüntü hiç gelmezse adımlar bu oturumda kapanır, <video> eski yolla kurulur.
  // - Ses odağı (webosMediaFocus) ve TV sesini açma (setMuted) varsayılan kapalıdır (COUCHSUBS_SOUND_STEPS ile açılır).
  // Tanı satırında "sx": wait (görüntü bekleniyor), on (adımlar yapıldı), off <neden> (kapatıldı); "rl": bilgisayarın ya
  // da telefonun uygulamayı yeniden açma sayısı (bekçi).
  //
  // 0.9.61 (#643, LG 55SK8500PLA, webOS 05.50.70, PS5 HDMI 2, soundbar): "görüntü gelip sonra siyah ekranda kalıyor".
  // Panel: "hdmi playing rs4 1920x1080 t= · ev stalled · snd on v100 tr1/1 out denied dig denied tv 8 sx on". Görüntü
  // geldi, 3 sn sonra ses adımları yapıldı (muted/defaultMuted yazıldı, settingsservice iki kez okundu ve reddetti,
  // com.webos.audio/getVolume okundu), sonra <video> 'stalled' oldu. Hangisinin bozduğu kanıtlanamıyor; bu adımlar hiç
  // doğrulanmamış tahminlerdi ve ikinci kez görüntü sorunuyla birlikte görüldü (#780). Üstelik bu TV currentTime'ı
  // ilerletmiyor (t=), <video> rs4 "oynuyor" diyor: gözcü bozulma görmüyor, 'stalled' olayı yalnız denetimi öne
  // çekiyordu, yani hiçbir şey yapılmıyor ve adımlar da kapanmıyordu. Artık:
  // - Ses adımlarının hiçbiri (sesli istek, ses parçası, ses ayarı/ses düzeyi okuma, odak, TV sesini açma) varsayılan
  //   olarak yapılmaz; yalnız window.COUCHSUBS_SOUND_STEPS verilirse yapılır. Tanıda "sx no".
  // - Görüntü geldikten sonra 'stalled' olayı gelirse 1,5 sn sonra bakılır: sayaç bu arada ilerlediyse görüntü akıyordur,
  //   dokunulmaz; değilse <video> 0.9.46 yoluyla bir kez yeniden kurulur; sonraki 30 sn 'stalled' olayı yalnız beklenir.
  //   Tanıda "stall <sayı> <eylem>": rebuilt (yeniden kuruldu), ok (görüntü akıyor), wait (30 sn dolmadı), nopic
  //   (görüntü hiç gelmemişti, gözcüye bırakıldı), busy (zaten kuruluyor ya da sınır doldu).
  //
  // 0.9.67 (#643, aynı TV, 0.9.63): "hdmi playing rs4 1920x1080 t= · rebuilt 1 (ev stalled) · ev stalled · stall 2 wait
  // · rl 6 · snd on v100 tr1/1 sx no", bg 2. "snd on" <video>'nun kısık olmadığıdır (audioText), ses adımları değil;
  // adımlar kapalı ("sx no"). Siyah kalmanın kod yolu: ilk 'stalled'dan sonra <video> yeniden kuruldu, ikinci 'stalled'
  // 30 sn içinde geldiği için yalnız "wait" yazıldı ve hiçbir şey yapılmadı; bu TV sayacı ilerletmediği (t=) ve rs4
  // "oynuyor" dediği için gözcü de bozulma görmedi: ekran kullanıcı girişi yeniden seçene kadar siyah. Ayrıca 'stalled'
  // denetimi ve arka plandan dönüşün sıkı denetimi aynı zamanlayıcıyı (soonTimer) kullanıyordu; hemen ardından gelen
  // webOSRelaunch (bilgisayarın bekçisi, "rl"), odak ya da ekran koruyucu sorusu onu gevşek denetimle siliyordu. Artık:
  // - 30 sn içinde gelen 'stalled' yok sayılmaz: 1,5 sn sonra sayaç ilerlememişse <video> artan aralıkla (2, 4, 8… sn,
  //   dakikada en çok 4) yeniden kurulur. Tanıda "stall <n> wait" sonra "rebuilt".
  // - 'stalled' denetiminin kendi zamanlayıcısı var; arka plandan dönüşün sıkı denetimi gevşek olaylarla gevşemez.
  // - Eski boru hattı bırakıldıktan sonra yenisi REBUILD_GAP_MS sonra açılır (kumandada aynı giriş numarası da). Tahmin
  //   (gerçek TV'de doğrulanmadı): webOS 4'te bırakma geç biterse yeni <video> "oynuyor" der ama görüntü gelmez.
  //
  // 0.9.73 (X, LG webOS): "son güncellemeden beri ekran yaklaşık dakikada bir 2 sn kararıp geri geliyor, sonra üstte HDR
  // yazısı çıkıyor". Bu, <video>'nun yeniden kurulmasıdır (eski boru hattı bırakılır, 1 sn sonra yenisi açılır, TV HDMI
  // ile yeniden el sıkışır ve HDR rozetini gösterir). #643'teki TV her yeni <video>'da birkaç saniye sonra 'stalled'
  // gönderiyor ("rebuilt 1 (ev stalled) · ev stalled") ve sayacı ilerletmiyor (t=); böyle bir TV'de görüntü sağlamken de
  // 0.9.67'nin kuralı her 'stalled'ı yeniden kurmaya çeviriyordu: yeni <video> yine 'stalled' olur, yine kurulur. Artan
  // aralık (BACKOFF_MS) 60 sn'de durduğu ve sıra hep dolu olduğu için (tick sayaç sıfırlamıyor) döngü ~66 sn'de bir kurmaya
  // oturuyordu; 0.9.61-0.9.66'da 30 sn içindeki ikinci 'stalled' beklendiği için yalnız bir kez kuruluyordu. Bu TV'lerde
  // sayfa siyah ekranla sağlam görüntüyü ayıramıyor (ikisinde de "hdmi playing rs4 t= · ev stalled"). Artık 'stalled'
  // yüzünden en çok STALL_REBUILD_MAX kez STALL_REBUILD_WINDOW_MS içinde kurulur (#643'ün siyah ekranına yine üç deneme);
  // sonra 'stalled' olayı yalnız yazılır ("stall <n> limit"), görüntüye dokunulmaz. Gözcünün açık bozulma işaretleri
  // (hata, kare yok, duraklama, durmuş sayaç) ve arka plandan dönüş denetimi değişmedi; kullanıcı girişi yeniden seçince
  // (sayı tuşu, ◀▶) sayaç sıfırlanır.
  var STALL_REBUILD_MAX = 3;
  var STALL_REBUILD_WINDOW_MS = 10 * 60000;
  var FOCUS_MAX = 3;
  var MUTE_CHECK_MS = 1500;
  var SOUND_AFTER_MS = 3000;
  var SOUND_WATCH_MS = 30000;
  var sound = {
    output: '', digital: '', volume: '', fixed: 0,
    mutedBefore: null, tvMute: '', focus: '', focusAsks: 0,
    steps: 'wait', why: '', doneFor: null, doneAt: 0, timer: null
  };
  var relaunches = 0;
  var STALL_CHECK_MS = 1500;
  var STALL_EVENT_WAIT_MS = 30000;

  // Ses adımları yalnız açıkça istenirse (window.COUCHSUBS_SOUND_STEPS) yapılır.
  function soundEnabled() { return !!window.COUCHSUBS_SOUND_STEPS; }

  // Görüntü SOUND_WATCH_MS içinde ses adımlarından sonra düştü ya da hiç gelmedi: adımlar bu oturumda kapanır.
  function soundOff(why) {
    if (sound.steps === 'off') return;
    sound.steps = 'off';
    sound.why = why;
    clearTimeout(sound.timer);
    sound.timer = null;
  }

  // Bu <video>'da ses adımları yapıldı ve görüntü o zamandan beri kısa süre oldu.
  function soundSuspect(video) {
    return !!video && sound.doneFor === video && nowMs() - sound.doneAt < SOUND_WATCH_MS;
  }

  function hasFrames(video) {
    return !video.error && (video.readyState >= 2 || video.videoWidth > 0);
  }

  // Görüntü geldi: adımlar kısa süre sonra, görüntü hâlâ varsa denenir.
  function soundSoon(video) {
    if (!soundEnabled() || sound.steps === 'off' || sound.timer !== null || sound.doneFor === video) return;
    sound.timer = setTimeout(function () {
      sound.timer = null;
      if (hdmi.video !== video || sound.steps === 'off' || sound.doneFor === video || !hasFrames(video)) return;
      applySound(video);
    }, SOUND_AFTER_MS);
  }

  function applySound(video) {
    var extra = window.COUCHSUBS_SOUND_STEPS || {};
    sound.doneFor = video;
    sound.doneAt = nowMs();
    sound.steps = 'on';
    try { readSoundSettings(); } catch (e) {}
    try { unmute(video); } catch (e2) {}
    if (extra.focus) {
      requestFocus(video);
      try {
        video.addEventListener('webosmediafocuschange', function () {
          if (hdmi.video === video && sound.steps !== 'off') requestFocus(video);
        });
      } catch (e3) {}
    }
    if (extra.tvUnmute) checkTvMute(video);
  }

  // getVolume yanıtındaki kısık bilgisi (yeni webOS volumeStatus.muteStatus, eskisi muted); yoksa null.
  function mutedFrom(reply) {
    var status = reply.volumeStatus || reply;
    if (typeof status.muteStatus === 'boolean') return status.muteStatus;
    if (typeof status.muted === 'boolean') return status.muted;
    return null;
  }

  function readVolume(callback) {
    try {
      var volume = new PalmServiceBridge();
      volume.onservicecallback = function (msg) {
        try {
          var reply = JSON.parse(msg) || {};
          var status = reply.volumeStatus || reply;
          var muted = mutedFrom(reply);
          if (status.volume !== undefined) sound.volume = String(status.volume) + (muted ? ' muted' : '');
          if (callback) callback(muted);
        } catch (e) {}
      };
      volume.call('luna://com.webos.audio/getVolume', '{}');
      window.__soundVolumeBridge = volume;
    } catch (e) {}
  }

  // <video>'nun ses odağı (webOS Chromium'un webosMediaFocus özelliği). Özellik yoksa hiçbir şey yapılmaz.
  function requestFocus(video) {
    try {
      if (!('webosMediaFocus' in video)) return;
      if (!video.webosMediaFocus && sound.focusAsks < FOCUS_MAX) {
        sound.focusAsks++;
        video.webosMediaFocus = true;
      }
      sound.focus = video.webosMediaFocus ? '1' : '0';
    } catch (e) {
      sound.focus = 'err';
    }
  }

  // Görüntü oynamaya başladıktan kısa süre sonra TV'nin sesi kısılmış mı bakılır; açılışta kısık değildiyse bir kez açılır.
  function checkTvMute(video) {
    setTimeout(function () {
      if (hdmi.video !== video || sound.tvMute) return;
      readVolume(function (muted) {
        if (hdmi.video !== video || sound.tvMute || muted !== true || sound.mutedBefore !== false) return;
        sound.tvMute = 'asked';
        try {
          var bridge = new PalmServiceBridge();
          bridge.onservicecallback = function (msg) {
            try {
              var reply = JSON.parse(msg) || {};
              sound.tvMute = reply.returnValue === false ? 'denied' : 'unmuted';
            } catch (e) {}
          };
          bridge.call('luna://com.webos.audio/setMuted', JSON.stringify({ muted: false }));
          window.__soundMuteBridge = bridge;
        } catch (e) {
          sound.tvMute = 'err';
        }
      });
    }, MUTE_CHECK_MS);
  }

  function unmute(video) {
    try {
      if (video.muted) sound.fixed++;
      video.muted = false;
      video.defaultMuted = false;
      if (video.volume !== undefined && video.volume < 1) video.volume = 1;
    } catch (e) {}
    try {
      var tracks = video.audioTracks;
      if (!tracks || !tracks.length) return;
      for (var i = 0; i < tracks.length; i++) if (tracks[i] && tracks[i].enabled) return;
      tracks[0].enabled = true;
      sound.fixed++;
    } catch (e2) {}
  }

  function audioText(video) {
    var text = 'snd';
    try {
      text += video.muted ? ' muted' : ' on';
      if (typeof video.volume === 'number') text += ' v' + Math.round(video.volume * 100);
      var tracks = video.audioTracks;
      if (tracks && tracks.length !== undefined) {
        var on = 0;
        for (var i = 0; i < tracks.length; i++) if (tracks[i] && tracks[i].enabled) on++;
        text += ' tr' + on + '/' + tracks.length;
      }
    } catch (e) {}
    if (sound.fixed) text += ' fixed ' + sound.fixed;
    if (sound.focus) text += ' mf ' + sound.focus;
    if (sound.output) text += ' out ' + sound.output;
    if (sound.digital) text += ' dig ' + sound.digital;
    if (sound.volume) text += ' tv ' + sound.volume;
    if (sound.tvMute) text += ' tvmute ' + sound.tvMute;
    text += soundEnabled() ? ' sx ' + sound.steps + (sound.why ? ' ' + sound.why : '') : ' sx no';
    return text;
  }

  // settingsservice'ten sesin tek bir anahtarı; okunamazsa 'denied' (izin yok) ya da boş.
  function readSoundKey(key, store, name) {
    try {
      var bridge = new PalmServiceBridge();
      bridge.onservicecallback = function (msg) {
        try {
          var reply = JSON.parse(msg) || {};
          var value = reply.settings && reply.settings[key];
          sound[store] = value ? String(value).slice(0, 24) : (reply.returnValue === false ? 'denied' : '');
        } catch (e) {}
      };
      bridge.call('luna://com.webos.settingsservice/getSystemSettings',
        JSON.stringify({ category: 'sound', keys: [key] }));
      window[name] = bridge;
    } catch (e) {}
  }

  // TV'nin ses çıkışı ve ses düzeyi (yalnız tanı için; hizmet yoksa ya da izin verilmezse yazılmaz).
  // Anahtarlar ayrı sorulur: TV'nin tanımadığı bir anahtar ötekinin yanıtını bozmasın. Kısık bilgisi görüntü açılmadan
  // önceki durumdur (checkTvMute bununla karşılaştırır).
  function readSoundSettings() {
    sound.mutedBefore = null;
    sound.tvMute = '';
    readSoundKey('soundOutput', 'output', '__soundOutputBridge');
    readSoundKey('soundOutputDigital', 'digital', '__soundDigitalBridge');
    readVolume(function (muted) { if (sound.mutedBefore === null) sound.mutedBefore = muted; });
  }

  function buildVideo() {
    // Görüntü gelene kadar 0.9.46'daki kurulumun aynısı (ses adımları: soundSoon).
    var video = document.createElement('video');
    video.autoplay = true;
    var source = document.createElement('source');
    source.setAttribute('type', 'service/webos-external');
    source.setAttribute('src', 'ext://hdmi:' + hdmi.port);
    video.appendChild(source);

    hdmi.video = video;
    hdmi.builtAt = nowMs();
    hdmi.played = false;
    hdmi.lastTime = -1;
    hdmi.lastAdvanceAt = hdmi.builtAt;
    hdmi.advances = 0;
    hdmi.playTried = false;
    hdmi.sawUnpaused = false;
    sound.focusAsks = 0;

    function current() { return hdmi.video === video; }
    function picture(kind) {
      return function () {
        if (!current()) return;
        hdmi.played = true;
        hdmi.everPlayed = true;
        hdmi.onStatus(kind);
        soundSoon(video);
      };
    }
    function suspect(name) {
      return function () {
        if (!current()) return;
        hdmi.lastEvent = name;
        if (name === 'stalled') return onStalled(video);
        checkSoon(1500, false);
      };
    }
    video.addEventListener('loadeddata', picture('ready'));
    video.addEventListener('playing', picture('playing'));
    video.addEventListener('error', function () {
      if (!current()) return;
      hdmi.lastError = describeError(video.error) || 'error';
      hdmi.onStatus('inputError');
      schedule('error');
    });
    source.addEventListener('error', function () {
      if (!current()) return;
      hdmi.lastError = 'source';
      hdmi.onStatus('sourceError');
    });
    // Bu olaylar çalışan görüntüde de gelebilir: tek başlarına yeniden kurdurmaz, yalnız denetimi öne çeker.
    var events = ['stalled', 'emptied', 'abort', 'ended', 'pause'];
    for (var i = 0; i < events.length; i++) video.addEventListener(events[i], suspect(events[i]));

    hdmi.host.appendChild(video);
  }

  // Görüntü geldikten sonra 'stalled' olayı (#643): sayaç (currentTime) bu 1,5 sn'de ilerlediyse görüntü akıyordur, dokunulmaz;
  // değilse <video> yeniden kurulur. Son yeniden kurmadan sonraki STALL_EVENT_WAIT_MS içinde gelen olay yok sayılmaz
  // (0.9.63'te sayılıyordu, ekran siyah kalıyordu): kurma gözcünün artan aralığıyla (BACKOFF_MS, dakikada en çok
  // MAX_PER_MINUTE) yapılır. Denetimin kendi zamanlayıcısı var: odak, yeniden başlatılma ya da ekran koruyucu sorusunun
  // denetimi (checkSoon) onu silmez.
  function onStalled(video) {
    hdmi.stalls++;
    if (!hdmi.played) {
      hdmi.stallNote = 'nopic';
      return checkSoon(STALL_CHECK_MS, false);
    }
    // Denetim zaten bekliyorsa ya da kurma sıradaysa art arda gelen olay onu ertelemez.
    if (hdmi.stallTimer !== null || hdmi.pending !== null || hdmi.building !== null) return;
    // Bu pencerede 'stalled' yüzünden yeterince kuruldu: TV olayı sağlam görüntüde de gönderiyor olabilir (0.9.73).
    if (stallLimitReached(nowMs())) {
      hdmi.stallNote = 'limit';
      return;
    }
    var waiting = !!hdmi.stallRebuiltAt && nowMs() - hdmi.stallRebuiltAt < STALL_EVENT_WAIT_MS;
    hdmi.stallNote = waiting ? 'wait' : 'check';
    hdmi.stallVideo = video;
    hdmi.stallTime = Number(video.currentTime);
    clearTimeout(hdmi.stallTimer);
    hdmi.stallTimer = setTimeout(function () {
      hdmi.stallTimer = null;
      if (hdmi.video !== video || !hdmi.host || pageHidden()) return;
      if (stallRecovered()) {
        hdmi.stallNote = 'ok';
        return;
      }
      if (hdmi.pending !== null || hdmi.building !== null || !schedule('ev stalled', !waiting, true)) {
        hdmi.stallNote = 'busy';
      }
    }, STALL_CHECK_MS);
  }

  // 'stalled' yüzünden son STALL_REBUILD_WINDOW_MS içinde STALL_REBUILD_MAX kez kuruldu mu.
  function stallLimitReached(now) {
    while (hdmi.stallRebuilds.length && now - hdmi.stallRebuilds[0] >= STALL_REBUILD_WINDOW_MS) hdmi.stallRebuilds.shift();
    return hdmi.stallRebuilds.length >= STALL_REBUILD_MAX;
  }

  // 'stalled' olayından sonra görüntü kendiliğinden akmaya devam etti mi (sayaç ilerledi ve başka bozulma yok).
  function stallRecovered() {
    var video = hdmi.video;
    return !!video && hdmi.stallVideo === video && Number(video.currentTime) > hdmi.stallTime && health(nowMs()) === '';
  }

  // Görüntü sağlamsa '', değilse neden.
  function health(now) {
    var video = hdmi.video;
    if (!video) return 'gone';
    if (!video.parentNode) return 'detached';
    if (video.error) return 'error';
    if (now - hdmi.builtAt < GRACE_MS) return '';
    if (!(video.readyState >= 2 || video.videoWidth > 0)) return hdmi.played ? 'lost' : 'no picture';
    if (video.paused || video.ended) {
      // Bu <video> hiç "oynuyor" görünmediyse (TV görüntüyü duraklamış sayarak gösteriyor olabilir) işaret sayılmaz.
      if (!hdmi.sawUnpaused) return '';
      if (hdmi.playTried) return 'paused';
      // Önce nazikçe: duraklamış görüntü yeniden oynatılır; bir sonraki denetimde hâlâ duruyorsa yeniden kurulur.
      hdmi.playTried = true;
      try {
        var promise = video.play();
        if (promise && typeof promise.then === 'function') promise.then(null, function () {});
      } catch (e) {}
      return '';
    }
    hdmi.playTried = false;
    hdmi.sawUnpaused = true;
    var time = Number(video.currentTime);
    if (time > hdmi.lastTime) {
      if (hdmi.lastTime >= 0) hdmi.advances++;
      hdmi.lastTime = time;
      hdmi.lastAdvanceAt = now;
    } else if (hdmi.advances >= 3 && now - hdmi.lastAdvanceAt >= STALL_MS) {
      // Sayaç bu <video>'da ilerliyordu, artık ilerlemiyor. Sayacı hiç ilerletmeyen TV'de bu işaret kullanılmaz.
      return 'stalled';
    }
    return '';
  }

  function mayRebuild() {
    return !!hdmi.host && (hdmi.everPlayed || hdmi.sincePort < NEVER_PLAYED_MAX);
  }

  function rebuild(reason) {
    hdmi.rebuilds++;
    hdmi.failures++;
    hdmi.sincePort++;
    hdmi.recent.push(nowMs());
    hdmi.reason = reason;
    if (reason === 'ev stalled') {
      hdmi.stallRebuiltAt = nowMs();
      hdmi.stallRebuilds.push(hdmi.stallRebuiltAt);
      hdmi.stallNote = 'rebuilt';
    }
    clearTimeout(hdmi.stallTimer);
    hdmi.stallTimer = null;
    var old = hdmi.video;
    // Görüntü 'stalled' oldu: ses adımları (açıkça istendiyse) bu oturumda kapanır, <video> eski yolla kurulur.
    if (reason === 'ev stalled') soundOff('stalled');
    // Görüntü ses adımlarından kısa süre sonra düştü ya da bu girişte hiç gelmedi: eski yola dönülür.
    if (soundSuspect(old)) soundOff('drop ' + reason);
    else if (!hdmi.played) soundOff('nopic');
    clearTimeout(sound.timer);
    sound.timer = null;
    hdmi.video = null;
    releaseVideo(old, true);
    hdmi.onStatus('loading');
    clearTimeout(hdmi.building);
    hdmi.building = setTimeout(function () {
      hdmi.building = null;
      if (hdmi.host) buildVideo();
    }, REBUILD_GAP_MS);
  }

  // Dakikadaki deneme sınırı dolduysa ne kadar beklenmeli (ms); dolmadıysa 0.
  function rateWait(now) {
    while (hdmi.recent.length && now - hdmi.recent[0] >= 60000) hdmi.recent.shift();
    return hdmi.recent.length >= MAX_PER_MINUTE ? 60000 - (now - hdmi.recent[0]) : 0;
  }

  // Yeniden kurmayı sıraya koyar: gittikçe seyrekleşen aralıkla (2, 4, 8… sn; en çok dakikada bir). immediate: bir olayın
  // ardından (öne gelme, ekran koruyucu sorusu) beklemeden; dakikadaki sınır yine geçerlidir.
  // force: beklerken "bozuk görünmüyor" olsa da kurulur (öne gelme, 'stalled' olayı). Sıraya kondu: true.
  function schedule(reason, immediate, force) {
    if (hdmi.pending !== null || hdmi.building !== null || !mayRebuild()) return false;
    var delay = immediate ? 0 : BACKOFF_MS[Math.min(hdmi.failures, BACKOFF_MS.length - 1)];
    delay = Math.max(delay, rateWait(nowMs()));
    hdmi.pending = setTimeout(function () {
      hdmi.pending = null;
      // Arka plandayken kurulmaz; öne gelince yeniden bakılır.
      if (pageHidden() || !hdmi.host) return;
      // Beklerken kendiliğinden düzeldiyse dokunulmaz.
      if (!force && reason !== 'resume' && health(nowMs()) === '') return;
      if (reason === 'ev stalled' && stallRecovered()) {
        hdmi.stallNote = 'ok';
        return;
      }
      rebuild(reason);
    }, delay);
    return true;
  }

  function tick() {
    hdmi.checkTimer = setTimeout(tick, CHECK_MS);
    if (pageHidden()) {
      hdmi.wasHidden = true;
      return;
    }
    if (hdmi.pending !== null || hdmi.building !== null || !hdmi.host) return;
    var now = nowMs();
    var reason = health(now);
    if (reason) schedule(reason);
    else if (hdmi.played && hdmi.failures && now - hdmi.builtAt >= STEADY_MS) hdmi.failures = 0;
  }

  // Bir olaydan (öne gelme, yeniden başlatılma, odak, ekran koruyucu sorusu) kısa süre sonra görüntüye bakar.
  // strict: uygulama gerçekten arka plandaydı. O zaman "bozuk görünmüyor" yetmez: sayaç ilerliyorsa görüntü vardır,
  // ilerlemiyorsa <video> yeniden kurulur (giriş ekranı zaten yeniden açılırken; çalışan oyunun ortasında değil).
  // Sıkı denetim bitmeden gelen gevşek denetim (öne gelişin hemen ardından webOSRelaunch ve odak gelir) onu gevşetmez.
  function checkSoon(delay, strict) {
    if (!hdmi.host) return;
    strict = !!strict || hdmi.soonStrict;
    hdmi.soonStrict = strict;
    clearTimeout(hdmi.soonTimer);
    hdmi.soonTimer = setTimeout(function () {
      hdmi.soonTimer = null;
      // Arka planda kalındıysa sıkılık öne gelişte yeniden verilir.
      hdmi.soonStrict = false;
      if (pageHidden() || hdmi.pending !== null || hdmi.building !== null || !hdmi.host) return;
      var now = nowMs();
      var reason = health(now);
      if (reason) return schedule(reason, true);
      if (!strict || now - hdmi.builtAt < GRACE_MS) return;
      var video = hdmi.video;
      var before = Number(video.currentTime);
      hdmi.soonStrict = true;
      hdmi.soonTimer = setTimeout(function () {
        hdmi.soonTimer = null;
        hdmi.soonStrict = false;
        if (pageHidden() || hdmi.video !== video || hdmi.pending !== null || hdmi.building !== null) return;
        if (Number(video.currentTime) > before) return;
        schedule('resume', true);
      }, 1500);
    }, delay);
  }

  function onVisibility() {
    if (pageHidden()) {
      hdmi.wasHidden = true;
      return;
    }
    var strict = hdmi.wasHidden;
    hdmi.wasHidden = false;
    checkSoon(1500, strict);
  }

  if (document.addEventListener) {
    document.addEventListener('visibilitychange', onVisibility);
    document.addEventListener('webkitvisibilitychange', onVisibility);
    document.addEventListener('webOSRelaunch', function () { relaunches++; checkSoon(1500, false); });
  }
  if (window.addEventListener) window.addEventListener('focus', function () { checkSoon(1500, false); });

  // TV'nin sürümü ve modeli (PalmSystem.deviceInfo; webOSTV.js'in okuduğu alanlar) ile tarayıcı sürümü.
  function systemText() {
    var text = 'webOS';
    try {
      var info = JSON.parse(window.PalmSystem.deviceInfo);
      text += ' ' + (info.platformVersion || '?') + (info.modelName ? ' ' + info.modelName : '');
    } catch (e) {}
    var chrome = /Chrom(?:e|ium)\/(\d+)/.exec((window.navigator && window.navigator.userAgent) || '');
    return text + (chrome ? ' cr' + chrome[1] : '');
  }

  function hdmiText() {
    var video = hdmi.video;
    var state;
    if (!hdmi.host) state = 'idle';
    else if (!video) state = 'rebuilding';
    else if (video.error) state = 'error';
    else if (video.readyState >= 2 || video.videoWidth > 0) state = video.paused ? 'paused' : 'playing';
    else state = hdmi.played ? 'lost' : 'loading';
    var text = 'hdmi ' + state;
    if (video) {
      text += ' rs' + video.readyState + ' ' + (video.videoWidth || 0) + 'x' + (video.videoHeight || 0) +
        (hdmi.advances >= 3 ? ' t+' : ' t=');
    }
    if (hdmi.rebuilds) text += ' · rebuilt ' + hdmi.rebuilds + ' (' + hdmi.reason + ')';
    if (hdmi.lastError) text += ' · last error ' + hdmi.lastError;
    if (hdmi.lastEvent) text += ' · ev ' + hdmi.lastEvent;
    if (hdmi.stalls) text += ' · stall ' + hdmi.stalls + (hdmi.stallNote ? ' ' + hdmi.stallNote : '');
    if (relaunches) text += ' · rl ' + relaunches;
    if (video) text += ' · ' + audioText(video);
    return text;
  }

  window.COUCHSUBS_PLATFORM = {
    backKey: 461,

    // HDMI görüntüsü gelmezse app.js nedenini ve giriş seçimini gösterir (Android TV bunu kendi ekranında yapar).
    noPictureHelp: true,

    // Görüntü 'playing' olayı gelmeden de gelmiş olabilir: <video> kare aldıysa görüntü var sayılır.
    hasPicture: function () {
      var video = document.querySelector('#video-host video');
      return !!video && (video.readyState >= 2 || video.videoWidth > 0);
    },

    // Oyun kumandayla oynanır, TV kumandasına dokunulmaz; TV bunu boşta sanıp ekran koruyucuya ve sonra uykuya
    // geçer. TV ekran koruyucuyu açmadan önce abonelere zaman damgalı bir istek yollar; ack:false yanıtı onu erteler
    // (Kodi'nin webOS sürümünün yaptığı gibi). Servis yoksa ya da izin verilmezse sessizce geçilir. Bu istek belgeli
    // değildir ve yeni webOS'ta (25) saat ekran koruyucusu yine geliyordu (#230); appinfo.json'daki belgeli
    // screenSaverProperties.preferredType 2 (OLED, webOS 5+) görüntü üstünde yazı gösteren uygulamalar içindir: tam
    // ekran görüntüde ekran koruyucu açılmaz, yalnız yazı alanı 30 dakikada yavaşça kısılır. LCD'de (ör. 55UQ81,
    // webOS 22) preferredType yok sayılır; orada ekran koruyucuyu yalnız bu erteleme durdurur (#555).
    //
    // tvpower kaydı sayfayla değil TV'nin süreciyle yaşar ve kapatılamaz: uygulama kapanıp yeniden açılınca (Hızlı
    // Başlatma+ ile TV'yi kapatıp açmak, TV uygulamasının güncellenmesi) eski kayıt ölü kalır, aynı adla yeniden kayıt
    // "already registered" (-3) hatası alır. Eskiden ad hep 'com.couchsubs.tv' idi: TV'nin sorusu yanıt vermeyen eski
    // kayda gidiyor, ekran koruyucu yine açılıyordu (fişten çekince düzelip ertesi gün geri gelmesi buna uyuyor). Bu
    // yüzden her açılışta yeni bir ad kullanılır.
    //
    // Yeni adla kayıt gerçek LG'de denenmedi; 0.9.40'tan sonra "TV uykuya geçmeye başladı" bildirimi geldi. Bu yüzden
    // yeni ad reddedilirse ya da 4 sn içinde hiç yanıt gelmezse eski sabit adla, o da olmazsa başka yeni adlarla denenir.
    // Kabul edilmiş kayıt sonradan düşerse (servis hata bildirir) yeniden kaydolunur; TV'nin sorusuna verilen yanıtın
    // sonucu da izlenir. Durum panelde hangi adla olduğuyla yazar: "registered (new)", "deferred 3 (fixed)",
    // "denied: … (new.2)", "no reply (new)", "reply failed: … @3 (new)".
    init: function () {
      var BASE = 'com.couchsubs.tv';
      var NO_REPLY_MS = 4000;
      var MAX_TOTAL = 10;
      var stamp = new Date().getTime().toString(36);
      var attempt = 0;
      // Açılışta en çok dört ad denenir; kabul edilmiş kayıt her düştüğünde iki deneme hakkı daha verilir.
      var limit = 4;
      var count = 0;
      // Köprü nesneleri çöpe gitmesin; abonelik uygulama açık kaldıkça sürer.
      window.__screenSaverBridges = [];

      // Deneme sırası: yeni ad, eski sabit ad, sonra başka yeni adlar.
      function nameFor(index) {
        if (index === 0) return [BASE + '.' + stamp, 'new'];
        if (index === 1) return [BASE, 'fixed'];
        return [BASE + '.' + stamp + '.' + (index - 1), 'new.' + (index - 1)];
      }

      function register() {
        if (attempt >= limit) return;
        var name = nameFor(attempt);
        var client = name[0];
        var label = name[1];
        attempt++;
        var bridge = new PalmServiceBridge();
        var accepted = false;
        var moved = false;

        function status(text) { window.__screenSaverStatus = text + ' (' + label + ')'; }

        // Bu ad işe yaramadı: nedeni yazılır, sıradaki adla denenir.
        function next(why) {
          if (moved) return;
          moved = true;
          status(why);
          if (attempt < limit) setTimeout(function () { try { register(); } catch (e) {} }, 1000);
        }

        bridge.onservicecallback = function (message) {
          var request;
          try { request = JSON.parse(message); } catch (e) { return; }
          if (!request) return;
          if (request.returnValue === false) {
            if (accepted) {
              // Kabul edilmiş kayıt düştü: yeniden kaydolunur.
              accepted = false;
              moved = false;
              limit = Math.min(MAX_TOTAL, Math.max(limit, attempt + 2));
            }
            next('denied: ' + (request.errorText || request.errorCode));
            return;
          }
          accepted = true;
          if (request.timestamp === undefined) {
            if (!count) status('registered');
            return;
          }
          // TV ekran koruyucuyu açmak üzere: ack:false erteler.
          count++;
          window.__screenSaverCount = count;
          status('deferred ' + count);
          var asked = count;
          var reply = new PalmServiceBridge();
          reply.onservicecallback = function (answer) {
            var result;
            try { result = JSON.parse(answer); } catch (e) { return; }
            if (result && result.returnValue === false) {
              status('reply failed: ' + (result.errorText || result.errorCode) + ' @' + asked);
            }
          };
          reply.call('luna://com.webos.service.tvpower/power/responseScreenSaverRequest',
            JSON.stringify({ clientName: client, ack: false, timestamp: request.timestamp }));
          window.__screenSaverReply = reply;
          // TV boşta saydı: görüntü gerçekten oynuyor mu, bakılır.
          checkSoon(1500, false);
        };
        bridge.call('luna://com.webos.service.tvpower/power/registerScreenSaverRequest',
          JSON.stringify({ subscribe: true, clientName: client }));
        window.__screenSaverBridges.push(bridge);
        window.__screenSaverBridge = bridge;
        setTimeout(function () { if (!accepted) next('no reply'); }, NO_REPLY_MS);
      }

      try { register(); } catch (e) {}
    },

    launchParams: function () {
      return window.PalmSystem && window.PalmSystem.launchParams;
    },

    onRelaunch: function (callback) {
      document.addEventListener('webOSRelaunch', function (e) { callback(e.detail); });
    },

    // onStatus: 'loading' | 'ready' | 'playing' | 'inputError' | 'sourceError'
    // Giriş açıldıktan sonra görüntü gözcüsü çalışır (yukarıda): görüntü düşerse <video> yeniden kurulur.
    showHdmi: function (port, host, onStatus) {
      clearTimeout(hdmi.pending);
      clearTimeout(hdmi.building);
      clearTimeout(hdmi.soonTimer);
      clearTimeout(hdmi.stallTimer);
      hdmi.pending = null;
      hdmi.building = null;
      hdmi.soonTimer = null;
      hdmi.soonStrict = false;
      hdmi.stallTimer = null;
      // Aynı giriş yeniden istendi (kullanıcı kumandada o girişin numarasına bastı): görüntü takıldıysa boru hattı da
      // bırakılıp baştan kurulur, yeni <video> gözcünün yeniden kurmasındaki gibi REBUILD_GAP_MS sonra açılır. Başka
      // girişe geçerken eskisi gibi yalnız sayfadan çıkarılır.
      var released = false;
      if (hdmi.video && port === hdmi.port && host === hdmi.host) {
        // Kullanıcı ses adımlarından hemen sonra girişi yeniden seçti (görüntü siyah): eski yola dönülür.
        if (soundSuspect(hdmi.video)) soundOff('reselect');
        releaseVideo(hdmi.video, true);
        released = true;
      }
      clearTimeout(sound.timer);
      sound.timer = null;
      hdmi.video = null;
      host.innerHTML = '';

      hdmi.port = port;
      hdmi.host = host;
      hdmi.onStatus = onStatus;
      hdmi.everPlayed = false;
      hdmi.failures = 0;
      hdmi.sincePort = 0;
      hdmi.stallRebuilds = [];

      onStatus('loading');
      if (released) {
        hdmi.building = setTimeout(function () {
          hdmi.building = null;
          if (hdmi.host === host && hdmi.port === port) buildVideo();
        }, REBUILD_GAP_MS);
      } else {
        buildVideo();
      }
      if (hdmi.checkTimer === null) hdmi.checkTimer = setTimeout(tick, CHECK_MS);
    },

    // Bilgi panelindeki ikinci tanı satırı: HDMI görüntüsünün durumu, yeniden kurma sayısı, son hata ve webOS sürümü.
    diagnostics: function () {
      return hdmiText() + ' · ' + systemText();
    },

    // Birim testi için (scripts/tv-webos-hdmi.test.js).
    rankInputs: rankInputs,

    // Son okunan giriş listesindeki etiket (bilgi panelinde "HDMI 2 — PS5"); bilinmiyorsa ''.
    inputLabel: function (port) {
      for (var i = 0; i < knownInputs.length; i++) if (knownInputs[i].port === port) return knownInputs[i].label;
      return '';
    },

    // TV'nin giriş listesinden oyun konsolunun bağlı olduğu HDMI portunu bulur (sıralama: rankInputs).
    // callback(port, label, connected, candidates): candidates görüntü gelmezse sırayla denenecek girişlerdir
    // (app.js). Bulamazsa callback'i null ile çağırır.
    findConsolePort: function (callback) {
      var done = false;
      function finish(port, label, candidates) {
        if (done) return;
        done = true;
        callback(port, label, undefined, candidates || []);
      }
      try {
        var bridge = new PalmServiceBridge();
        bridge.onservicecallback = function (msg) {
          var devices;
          try { devices = JSON.parse(msg).devices || []; } catch (e) { return finish(null); }
          var ranked = rankInputs(devices);
          knownInputs = ranked;
          var pick = ranked[0] && ranked[0].rank < RANK_NONE ? ranked[0] : null;
          var candidates = ranked.filter(function (d) { return d.rank < RANK_NONE; })
            .map(function (d) { return d.port; });
          finish(pick ? pick.port : null, pick ? pick.label : null, candidates);
        };
        bridge.call('luna://com.webos.service.eim/getAllInputStatus', '{}');
        // Köprü nesnesi çöpe gitmesin diye geri çağrı gelene kadar tutulur.
        window.__eimBridge = bridge;
        setTimeout(function () { finish(null); }, 3000);
      } catch (e) {
        finish(null);
      }
    },

    // TV'nin yerel ağdaki IPv4 adresi (kablolu öncelikli); bilinemezse null. Uygulama altyazı kaynağını bu ağda arar.
    // Önce yeni webOS'un hizmeti, yanıt vermezse ya da adres yoksa eski webOS'larınki (com.palm.connectionmanager, LG'nin
    // belgelediği ad) sorulur. Eskiden yalnız ilki soruluyordu; eski LG'lerde adres hiç bilinmiyordu (#469).
    localAddress: function (callback) {
      var done = false;
      function finish(ip) {
        if (done) return;
        done = true;
        callback(ip || null);
      }
      function ask(services, index) {
        if (done) return;
        if (index >= services.length) return finish(null);
        var answered = false;
        function next() {
          if (answered) return;
          answered = true;
          ask(services, index + 1);
        }
        try {
          var bridge = new PalmServiceBridge();
          bridge.onservicecallback = function (msg) {
            if (answered) return;
            var ip = addressFromStatus(msg);
            if (ip) {
              answered = true;
              return finish(ip);
            }
            next();
          };
          bridge.call(services[index], '{}');
          // Köprü nesnesi çöpe gitmesin diye geri çağrı gelene kadar tutulur.
          window['__netBridge' + index] = bridge;
          // İki hizmet birlikte app.js'in 3 sn beklemesine sığar.
          setTimeout(next, 1200);
        } catch (e) {
          next();
        }
      }
      ask(NETWORK_STATUS, 0);
    },

    // user: kullanıcı kumandadan kendisi çıkıyor (Geri). O zaman uygulama arka planda açık kalmaz, tümüyle kapanır
    // (window.close): HDMI girişi bırakılır, TV'nin kendi giriş ekranı serbest kalır. Çeviri durunca bilgisayarın
    // istediği çıkışta eskisi gibi yalnız geri dönülür; uygulama yeniden çağrıldığında hemen açılır.
    exit: function (user) {
      if (user) {
        hdmi.host = null;
        releaseVideo(hdmi.video, true);
        hdmi.video = null;
      }
      if (window.PalmSystem && window.PalmSystem.platformBack) window.PalmSystem.platformBack();
      if (user) setTimeout(function () { try { window.close(); } catch (e) {} }, 500);
    }
  };
})();
