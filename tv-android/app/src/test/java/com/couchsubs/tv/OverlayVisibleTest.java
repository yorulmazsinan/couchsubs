// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/**
 * Katmandaki altyazı sayfası hiçbir koşulda gizlenerek açılmaz. 0.9.42'de sayfa yüklenene kadar görünmez tutuluyordu
 * (setAlpha(0), onPageFinished'te 1); bazı Android TV'lerde katman bir daha görünmedi ve altyazı HDMI görüntüsünün
 * üstüne hiç çıkmadı. WebView JVM'de çalışmadığı için kural kaynak üzerinde denetlenir.
 */
public class OverlayVisibleTest {
    private static String source(String name) throws Exception {
        File file = new File("src/main/java/com/couchsubs/tv/" + name);
        assertTrue(file.getAbsolutePath(), file.isFile());
        return new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
    }

    @Test
    public void altyaziSayfasiGizlenmez() throws Exception {
        for (String name : new String[] {"TvPage.java", "OverlayService.java"}) {
            String code = source(name);
            assertFalse(name + ": sayfa alfa ile gizlenmemeli", code.contains("setAlpha("));
            assertFalse(name + ": sayfa görünmez yapılmamalı", code.contains("View.INVISIBLE") || code.contains("View.GONE"));
        }
    }

    @Test
    public void sayfaSeffafZemindeAcilir() throws Exception {
        assertTrue(source("TvPage.java").contains("setBackgroundColor(Color.TRANSPARENT)"));
    }

    /**
     * Android 12L/13+ dokunmaya kapalı (FLAG_NOT_TOUCHABLE) bindirme penceresinin alfasını
     * getMaximumObscuringOpacityForTouch'a (0.8) indirir (DisplayPolicy.adjustWindowParamsLw). Katman öyle açılınca
     * "Tam" koyulukta bile çeviri kutusu yarı saydam kalıyordu (Philips OLED810 Google TV).
     */
    @Test
    public void katmanPenceresiOpaklikSinirinaTakilmaz() throws Exception {
        String code = source("OverlayService.java");
        assertFalse("katman penceresi FLAG_NOT_TOUCHABLE ile açılmamalı",
                code.contains("LayoutParams.FLAG_NOT_TOUCHABLE"));
        assertTrue("pencere alfası tam olmalı", code.contains("layout.alpha = 1f"));
        assertTrue("odak alınmamalı (kumanda TV'de kalır)", code.contains("LayoutParams.FLAG_NOT_FOCUSABLE"));
        assertTrue("dokunmalar sayfada yutulmalı", code.contains("setOnTouchListener((view, event) -> true)"));
    }
}
