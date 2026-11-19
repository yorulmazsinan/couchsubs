// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

/**
 * Uygulama içindeki TvView'in HDMI girişini ne zaman tuttuğu (#453, #413).
 *
 * Eskiden CouchSubs arka plana düşünce (kumandadan Giriş › HDMI 2, Ana ekran, başka uygulama) TvView girişi bırakmıyordu;
 * bırakması yalnız uygulama kapanınca oluyordu. Aynı HDMI'yı tek oturuma veren TV'lerde (Thomson, Philips gibi MediaTek
 * tabanlı Android TV'ler) TV'nin kendi giriş ekranı o arada yeşil ya da siyah kalıyordu. Artık ekran önden çekilince
 * giriş bırakılır, son giriş hatırlanır ve ekran öne gelince yeniden açılır. Arka plandayken gelen giriş isteği (bilgisayar
 * HDMI numarasını değiştirdi, bağlantı koptu diye yeniden deneme) girişi açmaz, yalnız hatırlanır.
 *
 * Android'e bağlı değildir (bkz. HdmiSessionTest).
 */
final class HdmiSession {
    /** Son açılan ya da açılmak istenen giriş; null: yok. */
    private String input;
    /** TvView girişi şu an tutuyor mu. */
    private boolean open;
    private boolean background;

    /** Giriş açılmak isteniyor: ekran öndeyse true (şimdi açılır); arkadaysa yalnız hatırlanır, öne gelince açılır. */
    boolean want(String id) {
        input = id;
        if (background) return false;
        open = true;
        return true;
    }

    /** Ekran önden çekildi: TvView girişi tutuyorsa true (bırakılmalı). Giriş unutulmaz. */
    boolean toBackground() {
        background = true;
        boolean held = open;
        open = false;
        return held;
    }

    /** Ekran öne geldi: yeniden açılacak giriş, yoksa null. */
    String toForeground() {
        background = false;
        return input;
    }

    /** Bağlantı koptu diye yeniden deneme: yalnız ekran öndeyken ve aynı giriş hâlâ açıkken. */
    boolean canRetune(String id) {
        return open && !background && id != null && id.equals(input);
    }

    /** Giriş tamamen bırakıldı (katmana geçildi): öne gelince de açılmaz. */
    void clear() {
        input = null;
        open = false;
    }

    /** Son açılan giriş, yoksa null. */
    String input() { return input; }
}
