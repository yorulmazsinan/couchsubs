// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Bilgisayar ya da telefon, TV'de zaten çalışan CouchSubs'a kendi adresini ekranı öne çekmeden bildirir
 * ({@code am broadcast -a com.couchsubs.tv.action.ADDRESS -n com.couchsubs.tv/.AddressReceiver --es params '{...}'}).
 *
 * X @conmeyz (Philips 55PUS7303, Android 8): "TV'de bağlı görünüyor, panelde sub 0; silip yükleyince düzeldi". Uygulama
 * çalışırken kayıtlı eski bir adrese (aynı bilgisayarın eski portu, başka bir CouchSubs) bağlı kalırsa bilgisayar onu
 * bulamıyordu: 0.9.56'dan (#805) beri bilgisayar/telefon çalışan uygulamaya {@code am start} göndermiyor (ekranı öne
 * çekip katmana atıyordu), adresini de hiç iletmiyordu. Yayın ekranı ve görüntü modunu değiştirmez; adres yalnız açık
 * sayfaya (uygulama içi ya da katman) gider, sayfa o adrese geçer (app.js applyParams).
 *
 * Yalnız ADB kabuğu gönderebilir: alıcı {@code android.permission.DUMP} ister (kabukta var, sıradan uygulamalarda yok).
 */
public final class AddressReceiver extends BroadcastReceiver {
    static final String ACTION = "com.couchsubs.tv.action.ADDRESS";
    static final String EXTRA_PARAMS = "params";

    @Override
    public void onReceive(Context context, Intent intent) {
        String params = intent == null ? null : intent.getStringExtra(EXTRA_PARAMS);
        if (!usable(params)) return;
        MainActivity.deliver(params);
        OverlayService.deliver(params);
    }

    /** Sayfaya verilebilecek parametre: boş olmayan, kısa bir JSON nesnesi. */
    static boolean usable(String params) {
        if (params == null) return false;
        String value = params.trim();
        return value.length() > 2 && value.length() <= 2048 && value.charAt(0) == '{' && value.charAt(value.length() - 1) == '}';
    }
}
