// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

/**
 * Katman boşta mı (beta.104: Vestel UA9600'de sağ üstte turuncu/pembe nokta). Katman penceresi bilgisayar/telefon
 * kapandıktan sonra da açık kalıyordu: sayfa bağlantı kopukken sağ üste küçük bir nokta koyuyordu, ön plan servisi de
 * TV'nin belleği boşaltılana ya da TV yeniden başlatılana kadar sürüyordu. Nokta artık yok; bağlantı EXIT_AFTER_MS
 * boyunca hiç kurulmazsa (bilgisayar/telefon kapandı, uyudu, ağ gitti) katman kendini kapatır. Bilgisayar/telefon geri
 * gelince CouchSubs'ı TV'de yeniden açar (ADB), katman yeniden kurulur.
 *
 * Zaman dışarıdan verilir (bkz. OverlayIdleTest).
 */
final class OverlayIdle {
    /** Bağlantısız geçen bu süreden sonra katman kapanır. Bilgisayarın kısa kopmaları (yeniden bağlanma) bunun altında. */
    static final long EXIT_AFTER_MS = 2 * 60_000;

    private boolean connected;
    private long since;

    /** Pencere açıldı: sayfa henüz bağlı değil, süre şimdi başlar. */
    void started(long now) {
        connected = false;
        since = now;
    }

    /** Sayfanın bağlantısı açıldı ya da koptu; durum değiştiyse true. */
    boolean connection(boolean open, long now) {
        if (open == connected) return false;
        connected = open;
        since = now;
        return true;
    }

    boolean connected() { return connected; }

    /** Bağlantı açıkken -1; kopuksa katmanın kapanacağı an. */
    long exitAt() { return connected ? -1 : since + EXIT_AFTER_MS; }

    /** Katman boşta kaldı mı (bağlantı EXIT_AFTER_MS'dir yok). */
    boolean expired(long now) { return !connected && now - since >= EXIT_AFTER_MS; }

    /** Bağlantının son değiştiği andan bu yana geçen süre (sn), günlük satırı için. */
    long secondsSince(long now) { return Math.max(0, (now - since) / 1000); }
}
