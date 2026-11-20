// SPDX-License-Identifier: AGPL-3.0-only
// TV uygulamasının metinleri. Dil TV'nin diline göre seçilir; Türkçe değilse İngilizce.
(function () {
  'use strict';

  var TEXTS = {
    tr: {
      pairCode: 'TV kodu:',
      pairRetry: 'Eşleştirme tamamlanmadı. Yeniden denemek için Tamam tuşuna basın.',
      // Sunucu eşleştirmeye kapalı (409): çeviri sürmüyor ve onay penceresi açılmamış. TV birkaç saniyede bir yeniden dener.
      pairClosed: 'Eşleştirme için telefonda/bilgisayarda Çeviriyi başlat\'a ya da Ayarlar\'daki TV eşleştir\'e basın; kod burada çıkar.',
      pairServer: 'Bu kodu telefon/bilgisayarda karşılaştırıp onaylayın.',
      // Telefondan kuranların çoğunun bilgisayarı yoktur: önce telefon söylenir (#113).
      waiting: 'Telefonda (ya da bilgisayarda) CouchSubs\'ı açıp Çeviriyi başlat\'a basın.',
      waitingHint: 'Bilgisayar gerekmez. Altyazı hedefi TV olsun, telefon ve TV aynı Wi-Fi\'da olsun: CouchSubs bu TV\'yi bulup altyazıları buraya gönderir.',
      panelTitle: 'CouchSubs',
      hdmi: 'HDMI',
      lastSubtitle: 'Son altyazı',
      resolution: 'Görüntü',
      pictureWindow: 'Pencere',
      diagnostics: 'Tanı',
      server: 'Uygulama',
      connection: 'Bağlantı',
      loading: '(yükleniyor)',
      videoReady: '(görüntü geldi)',
      playing: '(oynatılıyor)',
      inputError: '(hata: giriş açılamadı)',
      sourceError: '(hata: kaynak desteklenmiyor)',
      auto: 'otomatik',
      consoleNotFound: 'konsol bulunamadı',
      noEventSource: 'Bu TV desteklenmiyor (EventSource yok)',
      connecting: 'bağlanıyor…',
      connected: 'bağlı',
      reconnecting: 'bağlantı yok, yeniden deneniyor…',
      none: '—',
      keys: 'Tamam: bu panel · ◀▶: HDMI girişi (panel açıkken) · 1–4: HDMI girişi · 0: konsolu otomatik bul · ▲▼: altyazıyı yukarı/aşağı taşı · Kırmızı: test altyazısı · Mavi: demo · Yeşil: bu panel',
      localTest: 'Test: bu yazı oyunun üstünde görünüyor mu?',
      keyPicture: 'Sarı: görüntüyü ekrana sığdır / ekranı doldur',
      pictureFit: 'Görüntü: tam yükseklik, 16:9 (Sarı: ekranı doldur)',
      pictureFill: 'Görüntü: ekranı doldurur, gerilir (Sarı: 16:9)',
      positionPreview: 'Altyazı burada görünecek',
      waitingAddress: 'Bu TV\'nin adresi: %1',
      waitingSearching: 'Ağda CouchSubs aranıyor…',
      demoButton: 'Demoyu izle',
      demoBadge: 'DEMO',
      demoHint: 'Örnek: oyunun İngilizce altyazısı Türkçe olarak burada görünür. Çıkmak için Geri.',
      sourceSwitchTitle: 'TV kendiliğinden HDMI\'ya geçti.',
      sourceSwitchHint: 'Ayarlar › Tüm Ayarlar › Bağlantı › Harici Cihaz Yöneticisi\'nde Anynet+ (HDMI-CEC) ve Otomatik Kaynak Değiştirme\'yi kapatın.',
      sourceSwitchClose: 'Kapatmak için Tamam ya da Geri.',
      panelTipTitle: 'CouchSubs paneli için Tamam\'a basın.',
      panelTipHint: 'Bağlantı ve HDMI girişi paneldedir. Altyazı ayarları telefondaki ya da bilgisayardaki CouchSubs\'ın Ayarlar bölümündedir.',
      noPictureTitle: 'TV\'nin HDMI görüntüsü alınamadı',
      noPicture: 'HDMI %1 girişinden görüntü gelmiyor.',
      noPictureError: 'HDMI %1 girişi bu uygulamada açılamadı.',
      noPictureChoose: 'PS5 başka girişe bağlıysa aşağıdan seçin (◀▶ ve Tamam, ya da 1–4 sayı tuşları).',
      noPictureStillBlack: 'Doğru girişte de siyah mı? PS5\'te HDR açıksa kapatın (Ayarlar › Ekran ve Video › Video Çıkışı › HDR: Kapalı): Uzaktan Oynatma açıkken HDR görüntü kararabiliyor. Olmazsa bu TV HDMI görüntüsünü uygulamalara vermiyor ya da HDCP engelliyordur: PS5\'te Ayarlar › Sistem › HDMI › HDCP\'yi Etkinleştir\'i kapatmayı deneyin. Olmazsa CouchSubs\'tan çıkın, TV\'yi kumandadan PS5\'in HDMI girişine alın ve altyazıyı telefon ya da bilgisayar ekranından izleyin.',
      noPictureExit: 'Çık, TV girişine dön',
      noPictureClose: 'Kapat',
      pickInputTitle: 'Konsol hangi HDMI girişinde?',
      pickInput: 'TV\'ye birden çok HDMI cihazı bağlı; HDMI %1 açıldı. Arkada oyun yerine bilgisayarın ya da başka bir cihazın görüntüsü varsa konsolun (PS5, Xbox) girişini aşağıdan seçin (◀▶ ve Tamam, ya da 1–4 sayı tuşları). Seçiminiz hatırlanır.'
    },
    en: {
      pairCode: 'TV code:',
      pairRetry: 'Pairing did not finish. Press OK to try again.',
      pairClosed: 'To pair, press Start translation or Pair TV in Settings on your phone/computer; the code appears here.',
      pairServer: 'Compare this code and approve on your phone/computer.',
      waiting: 'Open CouchSubs on your phone (or computer) and start translating.',
      waitingHint: 'No computer needed. Set the subtitle target to TV and keep the phone and TV on the same Wi-Fi: CouchSubs finds this TV and sends subtitles here.',
      panelTitle: 'CouchSubs',
      hdmi: 'HDMI',
      lastSubtitle: 'Last subtitle',
      resolution: 'Picture',
      pictureWindow: 'Window',
      diagnostics: 'Diagnostics',
      server: 'App',
      connection: 'Connection',
      loading: '(loading)',
      videoReady: '(picture received)',
      playing: '(playing)',
      inputError: '(error: input could not be opened)',
      sourceError: '(error: source not supported)',
      auto: 'automatic',
      consoleNotFound: 'console not found',
      noEventSource: 'This TV is not supported (no EventSource)',
      connecting: 'connecting…',
      connected: 'connected',
      reconnecting: 'disconnected, retrying…',
      none: '—',
      keys: 'OK: this panel · ◀▶: HDMI input (panel open) · 1–4: HDMI input · 0: find console automatically · ▲▼: move subtitles up/down · Red: test subtitle · Blue: demo · Green: this panel',
      localTest: 'Test: is this text shown on top of the game?',
      keyPicture: 'Yellow: fit picture / fill screen',
      pictureFit: 'Picture: full height, 16:9 (Yellow: fill screen)',
      pictureFill: 'Picture: fills the screen, stretched (Yellow: 16:9)',
      positionPreview: 'Subtitles will appear here',
      waitingAddress: 'This TV\'s address: %1',
      waitingSearching: 'Looking for CouchSubs on the network…',
      demoButton: 'Watch the demo',
      demoBadge: 'DEMO',
      demoHint: 'Example: the game\'s English subtitles appear here in Turkish. Press Back to exit.',
      sourceSwitchTitle: 'The TV switched to HDMI by itself.',
      sourceSwitchHint: 'Turn off Anynet+ (HDMI-CEC) and Auto Source Switching in Settings › All Settings › Connection › External Device Manager.',
      sourceSwitchClose: 'Press OK or Back to close.',
      panelTipTitle: 'Press OK for the CouchSubs panel.',
      panelTipHint: 'Connection and HDMI input are in the panel. Subtitle settings are under Settings in CouchSubs on your phone or computer.',
      noPictureTitle: 'No HDMI picture from the TV',
      noPicture: 'No picture from HDMI %1.',
      noPictureError: 'HDMI %1 could not be opened in this app.',
      noPictureChoose: 'If the PS5 is on another input, choose it below (◀▶ and OK, or number keys 1–4).',
      noPictureStillBlack: 'Still black on the right input? If HDR is on, turn it off on the PS5 (Settings › Screen and Video › Video Output › HDR: Off): with Remote Play active an HDR picture can turn dark. Otherwise this TV may not hand its HDMI picture to apps, or HDCP blocks it: try turning off Settings › System › HDMI › Enable HDCP on the PS5. Otherwise exit CouchSubs, switch the TV to the PS5\'s HDMI input with the remote and read the subtitles on your phone or computer.',
      noPictureExit: 'Exit to the TV input',
      noPictureClose: 'Close',
      pickInputTitle: 'Which HDMI input is the console on?',
      pickInput: 'More than one HDMI device is connected to the TV; HDMI %1 is open. If you see the computer or another device instead of the game, choose the console\'s (PS5, Xbox) input below (◀▶ and OK, or number keys 1–4). Your choice is remembered.'
    }
  };

  var lang = (navigator.language || 'en').toLowerCase().indexOf('tr') === 0 ? 'tr' : 'en';

  window.t = function (key) {
    return (TEXTS[lang] && TEXTS[lang][key]) || TEXTS.en[key] || key;
  };

  // data-i18n niteliği taşıyan öğelerin metnini doldurur.
  window.applyI18n = function () {
    var nodes = document.querySelectorAll('[data-i18n]');
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].textContent = window.t(nodes[i].getAttribute('data-i18n'));
    }
  };
})();
