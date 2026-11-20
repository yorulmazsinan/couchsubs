// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

/**
 * Altyazı sayfasının WebView işlemi gidince (çökme ya da sistemin kapatması) sayfanın yeniden kurulup kurulmayacağı.
 * Arada bir giden işlem yeniden kurulur; WINDOW_MS içinde LIMIT kez gittiyse bu TV'de sayfa ayakta kalamıyordur,
 * sonsuz döngüye girilmez (#616).
 *
 * Android'e bağlı değildir; zaman dışarıdan verilir (bkz. PageRestartsTest).
 */
final class PageRestarts {
    static final int LIMIT = 3;
    static final long WINDOW_MS = 120_000;
    /** Yeniden kurmadan önce beklenir: sistem belleği yeni boşaltmışsa hemen kurulan sayfa da gider. */
    static final long DELAY_MS = 1_500;

    private final long[] times = new long[LIMIT];
    private int count;

    /** İşlem şimdi gitti: sayfa yeniden kurulsun mu? */
    boolean allow(long now) {
        int recent = 0;
        for (int i = 0; i < count; i++) if (now - times[i] < WINDOW_MS) times[recent++] = times[i];
        count = recent;
        if (count >= LIMIT) return false;
        times[count++] = now;
        return true;
    }
}
