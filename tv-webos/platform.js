// SPDX-License-Identifier: AGPL-3.0-only
// webOS'a özgü işler. Tizen karşılığı: tv-tizen/platform.js
(function () {
  'use strict';

  window.COUCHSUBS_PLATFORM = {
    backKey: 461,

    // Oyun kumandayla oynanır, TV kumandasına dokunulmaz; TV bunu boşta sanıp ekran koruyucuya ve sonra uykuya
    // geçer. TV ekran koruyucuyu açmadan önce abonelere zaman damgalı bir istek yollar; ack:false yanıtı onu erteler
    // (Kodi'nin webOS sürümünün yaptığı gibi). Servis yoksa ya da izin verilmezse sessizce geçilir.
    init: function () {
      var CLIENT = 'com.couchsubs.tv';
      try {
        var register = new PalmServiceBridge();
        register.onservicecallback = function (message) {
          var request;
          try { request = JSON.parse(message); } catch (e) { return; }
          if (!request) return;
          // Panelin tanı satırı için: servis izin vermediyse sebebi, verdiyse ertelenen istek sayısı.
          if (request.returnValue === false) window.__screenSaverStatus = 'denied: ' + (request.errorText || request.errorCode);
          if (request.timestamp === undefined) return;
          window.__screenSaverCount = (window.__screenSaverCount || 0) + 1;
          window.__screenSaverStatus = 'deferred ' + window.__screenSaverCount;
          var reply = new PalmServiceBridge();
          reply.call('luna://com.webos.service.tvpower/power/responseScreenSaverRequest',
            JSON.stringify({ clientName: CLIENT, ack: false, timestamp: request.timestamp }));
          window.__screenSaverReply = reply;
        };
        register.call('luna://com.webos.service.tvpower/power/registerScreenSaverRequest',
          JSON.stringify({ subscribe: true, clientName: CLIENT }));
        // Köprü nesnesi çöpe gitmesin; abonelik uygulama açık kaldıkça sürer.
        window.__screenSaverBridge = register;
      } catch (e) {}
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
    localAddress: function (callback) {
      var done = false;
      function finish(ip) {
        if (done) return;
        done = true;
        callback(ip || null);
      }
      try {
        var bridge = new PalmServiceBridge();
        bridge.onservicecallback = function (msg) {
          var status;
          try { status = JSON.parse(msg) || {}; } catch (e) { return finish(null); }
          var wired = status.wired || {};
          var wifi = status.wifi || {};
          if (wired.state === 'connected' && wired.ipAddress) return finish(wired.ipAddress);
          if (wifi.state === 'connected' && wifi.ipAddress) return finish(wifi.ipAddress);
          finish(wired.ipAddress || wifi.ipAddress || null);
        };
        bridge.call('luna://com.webos.service.connectionmanager/getStatus', '{}');
        // Köprü nesnesi çöpe gitmesin diye geri çağrı gelene kadar tutulur.
        window.__netBridge = bridge;
        setTimeout(function () { finish(null); }, 2000);
      } catch (e) {
        finish(null);
      }
    },

    exit: function () {
      if (window.PalmSystem && window.PalmSystem.platformBack) window.PalmSystem.platformBack();
    }
  };
})();
