// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * TV olay günlüğü (0.9.116): görüntüyü karartabilen her şey (HDMI girişinin yeniden açılması, ekranın yeniden kurulması ya
 * da geri alınması, sayfanın yeniden kurulması, bilgisayarın/telefonun kapanma isteği) nedeniyle birlikte yazılır.
 * "Son TV güncellemesinden sonra ekran sürekli göz kırpıyor, gidip geliyor" (beta.102-104) bildirimlerinde neden yalnız
 * panelin fotoğrafından okunabiliyordu. Satırlar sayfaya verilir (TvPage: platform.takeEvents), sayfa da bilgisayarın/
 * telefonun günlüğüne gönderir (app.js tvLog, {@code /tvlog}).
 *
 * Satırlar SharedPreferences'ta bekler: kapanma isteğinde ekran hemen kapanır, satır sonraki açılışta gider. Aynı türden
 * satır GAP_MS'de bir (arada atlananlar "+n" olarak sayılır), WINDOW_MS'de en çok WINDOW_MAX satır, en çok PENDING_MAX
 * bekleyen satır. Zaman dışarıdan verilir (bkz. TvEventsTest).
 */
final class TvEvents {
    static final long GAP_MS = 15_000;
    static final long WINDOW_MS = 10 * 60_000;
    static final int WINDOW_MAX = 20;
    static final int PENDING_MAX = 20;
    static final int TEXT_MAX = 160;
    /** Bekleyen satır bundan eskiyse sayfaya verilirken yaşı eklenir ("(12s ago)"). */
    static final long AGE_NOTE_MS = 5_000;

    /** Bekleyen satırların saklandığı yer ("zaman\tsatır" satırları). */
    interface Store {
        String read();
        void write(String value);
    }

    private static final String KEY = "tvEvents";
    private static TvEvents shared;

    private final Store store;
    private final Map<String, long[]> kinds = new HashMap<>();
    private final List<Long> times = new ArrayList<>();

    TvEvents(Store store) {
        this.store = store;
    }

    /** Uygulamanın tek günlüğü (ekran ve katman servisi aynı satırları paylaşır). */
    static synchronized TvEvents of(Context context) {
        if (shared == null) {
            SharedPreferences prefs = context.getApplicationContext().getSharedPreferences("couchsubs", Context.MODE_PRIVATE);
            shared = new TvEvents(new Store() {
                @Override public String read() { return prefs.getString(KEY, ""); }
                // commit: kapanma isteğinde işlem hemen ardından öldürülebilir.
                @Override public void write(String value) { prefs.edit().putString(KEY, value).commit(); }
            });
        }
        return shared;
    }

    /** Satırı yazar; sınır yüzünden atlandıysa false. now: saat (ms, duvar saati). */
    synchronized boolean add(String text, long now) {
        String line = clean(text);
        if (line.isEmpty()) return false;
        int paren = line.indexOf(" (");
        String kind = paren > 0 ? line.substring(0, paren) : line;
        long[] slot = kinds.get(kind);
        if (slot == null) kinds.put(kind, slot = new long[] {Long.MIN_VALUE, 0});
        if (slot[0] != Long.MIN_VALUE && now - slot[0] < GAP_MS) {
            slot[1]++;
            return false;
        }
        while (!times.isEmpty() && now - times.get(0) >= WINDOW_MS) times.remove(0);
        if (times.size() >= WINDOW_MAX) {
            slot[1]++;
            return false;
        }
        times.add(now);
        if (slot[1] > 0) line += " +" + slot[1];
        slot[0] = now;
        slot[1] = 0;
        List<String> pending = read();
        pending.add(now + "\t" + line);
        while (pending.size() > PENDING_MAX) pending.remove(0);
        store.write(join(pending));
        return true;
    }

    /** Bekleyen satırları verir ve siler; eski satırlara yaşı eklenir. */
    synchronized List<String> take(long now) {
        List<String> out = new ArrayList<>();
        for (String entry : read()) {
            int tab = entry.indexOf('\t');
            if (tab <= 0) continue;
            long at;
            try {
                at = Long.parseLong(entry.substring(0, tab));
            } catch (NumberFormatException e) {
                continue;
            }
            String line = entry.substring(tab + 1);
            long age = now - at;
            out.add(age >= AGE_NOTE_MS ? line + " (" + (age / 1000) + "s ago)" : line);
        }
        if (!out.isEmpty()) store.write("");
        return out;
    }

    private List<String> read() {
        List<String> list = new ArrayList<>();
        String raw = store.read();
        if (raw == null || raw.isEmpty()) return list;
        for (String entry : raw.split("\n")) if (!entry.isEmpty()) list.add(entry);
        return list;
    }

    private static String join(List<String> lines) {
        StringBuilder out = new StringBuilder();
        for (String line : lines) out.append(out.length() == 0 ? "" : "\n").append(line);
        return out.toString();
    }

    /** Denetim karakterleri boşluğa çevrilir (satır sonu ve sekme ayırıcıdır), en çok TEXT_MAX karakter. */
    static String clean(String text) {
        if (text == null) return "";
        String line = text.replaceAll("[\\u0000-\\u001f\\u007f]+", " ").trim();
        return line.length() > TEXT_MAX ? line.substring(0, TEXT_MAX) : line;
    }
}
