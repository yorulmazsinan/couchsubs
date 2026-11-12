// SPDX-License-Identifier: AGPL-3.0-only
// Tizen'e (Samsung TV) özgü işler. webOS karşılığı: tv-webos/platform.js
// HDMI görüntüsü resmî TVWindow API'siyle HTML katmanının arkasında gösterilir.
(function () {
  'use strict';

  var KEYS = ['0', '1', '2', '3', '4', 'ColorF0Red', 'ColorF1Green', 'ColorF3Blue'];

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

  window.COUCHSUBS_PLATFORM = {
    backKey: 10009,

    // Anynet+ (HDMI-CEC) ya da Otomatik Kaynak Değiştirme TV'yi kendiliğinden HDMI'ya geçirirse uygulama ipucu
    // gösterir (app.js). Menü adları Samsung'unkiler; başka TV'lerde gösterilmez.
    sourceSwitchTip: true,

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
            tizen.tvwindow.show(function () { onStatus('playing'); }, failed,
              ['0', '0', '100%', '100%'], 'MAIN', 'BEHIND');
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
      read('ETHERNET_NETWORK', function () {
        read('WIFI_NETWORK', function () { callback(null); });
      });
    },

    // Tek bağlı HDMI varsa odur; birden çoksa TV'nin o anki girişi tercih edilir.
    findConsolePort: function (callback) {
      hdmiSources(function (connected) {
        var pick = connected.length === 1 ? connected[0] : null;
        if (!pick && connected.length > 1) {
          try {
            var current = tizen.tvwindow.getSource();
            pick = connected.filter(function (s) { return s.number === current.number && current.type === 'HDMI'; })[0] || null;
          } catch (e) {}
        }
        callback(pick ? pick.number : null, pick ? 'HDMI ' + pick.number : null);
      });
    },

    exit: function () {
      try { tizen.application.getCurrentApplication().exit(); } catch (e) {}
    }
  };
})();
