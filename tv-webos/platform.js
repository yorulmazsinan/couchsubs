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
    // yüzden her açılışta yeni bir ad kullanılır; kayıt yine reddedilirse birkaç kez başka adla denenir.
    init: function () {
      var BASE = 'com.couchsubs.tv';
      var MAX_ATTEMPTS = 4;
      var stamp = new Date().getTime().toString(36);
      var attempt = 0;
      // Köprü nesneleri çöpe gitmesin; abonelik uygulama açık kaldıkça sürer.
      window.__screenSaverBridges = [];

      function register() {
        var client = BASE + '.' + stamp + (attempt ? '.' + attempt : '');
        attempt++;
        var bridge = new PalmServiceBridge();
        var failed = false;
        bridge.onservicecallback = function (message) {
          var request;
          try { request = JSON.parse(message); } catch (e) { return; }
          if (!request) return;
          // Panelin tanı satırı için: kayıt reddedildiyse sebebi, kabul edildiyse ertelenen istek sayısı.
          if (request.returnValue === false) {
            window.__screenSaverStatus = 'denied: ' + (request.errorText || request.errorCode) +
              (attempt < MAX_ATTEMPTS ? ' (retry)' : '');
            if (!failed && attempt < MAX_ATTEMPTS) {
              failed = true;
              setTimeout(function () { try { register(); } catch (e) {} }, 1000);
            }
            return;
          }
          if (request.timestamp === undefined) {
            if (!window.__screenSaverCount) window.__screenSaverStatus = 'registered';
            return;
          }
          window.__screenSaverCount = (window.__screenSaverCount || 0) + 1;
          window.__screenSaverStatus = 'deferred ' + window.__screenSaverCount;
          var reply = new PalmServiceBridge();
          reply.call('luna://com.webos.service.tvpower/power/responseScreenSaverRequest',
            JSON.stringify({ clientName: client, ack: false, timestamp: request.timestamp }));
          window.__screenSaverReply = reply;
        };
        bridge.call('luna://com.webos.service.tvpower/power/registerScreenSaverRequest',
          JSON.stringify({ subscribe: true, clientName: client }));
        window.__screenSaverBridges.push(bridge);
        window.__screenSaverBridge = bridge;
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
    showHdmi: function (port, host, onStatus) {
      host.innerHTML = '';

      var video = document.createElement('video');
      video.autoplay = true;
      var source = document.createElement('source');
      source.setAttribute('type', 'service/webos-external');
      source.setAttribute('src', 'ext://hdmi:' + port);
      video.appendChild(source);

      onStatus('loading');
      video.addEventListener('loadeddata', function () { onStatus('ready'); });
      video.addEventListener('playing', function () { onStatus('playing'); });
      video.addEventListener('error', function () { onStatus('inputError'); });
      source.addEventListener('error', function () { onStatus('sourceError'); });

      host.appendChild(video);
    },

    // TV'nin giriş listesinden oyun konsolunun bağlı olduğu HDMI portunu bulur.
    // Bulamazsa callback'i null ile çağırır.
    findConsolePort: function (callback) {
      var done = false;
      function finish(port, label) {
        if (done) return;
        done = true;
        callback(port, label);
      }
      try {
        var bridge = new PalmServiceBridge();
        bridge.onservicecallback = function (msg) {
          var devices;
          try { devices = JSON.parse(msg).devices || []; } catch (e) { return finish(null); }
          var hdmi = devices.filter(function (d) { return /^HDMI_/.test(d.id); });
          // Konsol dinlenme modundayken giriş etkin görünmez ama etiketi kalır; etkin olan tercih edilir.
          var consoles = hdmi.filter(function (d) {
            return d.spdSourceDeviceInfo === 'GAME' || /playstation|ps5/i.test((d.label || '') + ' ' + (d.spdProductDescription || ''));
          });
          var pick = consoles.filter(function (d) { return d.activate; })[0] || consoles[0] ||
            hdmi.filter(function (d) { return d.activate; })[0];
          finish(pick ? pick.port : null, pick ? pick.label : null);
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

    exit: function () {
      if (window.PalmSystem && window.PalmSystem.platformBack) window.PalmSystem.platformBack();
    }
  };
})();
