// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class HdmiSessionTest {
    private static final String HDMI2 = "com.mediatek.tvinput/.hdmi.HDMIInputService/HW3";
    private static final String HDMI3 = "com.mediatek.tvinput/.hdmi.HDMIInputService/HW4";

    @Test
    public void inputIsReleasedWhenTheScreenLeaves() {
        // #453: kumandadan Giriş › HDMI 2 seçilince CouchSubs girişi tutmaya devam ediyordu; TV'nin ekranı yeşil kalıyordu.
        HdmiSession session = new HdmiSession();
        assertTrue(session.want(HDMI2));
        assertTrue(session.toBackground());
        assertFalse("ikinci kez bırakılacak bir şey yok", session.toBackground());
    }

    @Test
    public void nothingToReleaseWhenNoInputWasOpened() {
        HdmiSession session = new HdmiSession();
        assertFalse(session.toBackground());
        assertNull(session.toForeground());
    }

    @Test
    public void sameInputReopensWhenTheScreenReturns() {
        HdmiSession session = new HdmiSession();
        session.want(HDMI2);
        session.toBackground();
        assertEquals(HDMI2, session.toForeground());
        assertTrue(session.want(HDMI2));
    }

    @Test
    public void requestWhileInBackgroundIsRememberedNotOpened() {
        // Bilgisayar arka plandayken HDMI numarasını değiştirdi: TV'nin kendi ekranındaki girişi elinden alma.
        HdmiSession session = new HdmiSession();
        session.want(HDMI2);
        session.toBackground();
        assertFalse(session.want(HDMI3));
        assertFalse("açılmayan giriş bırakılmaz", session.toBackground());
        assertEquals(HDMI3, session.toForeground());
    }

    @Test
    public void noRetuneInBackground() {
        HdmiSession session = new HdmiSession();
        session.want(HDMI2);
        assertTrue(session.canRetune(HDMI2));
        session.toBackground();
        assertFalse(session.canRetune(HDMI2));
        session.toForeground();
        assertFalse("öne gelince önce yeniden açılır", session.canRetune(HDMI2));
        session.want(HDMI2);
        assertTrue(session.canRetune(HDMI2));
    }

    @Test
    public void retuneOnlyForTheCurrentInput() {
        HdmiSession session = new HdmiSession();
        session.want(HDMI2);
        session.want(HDMI3);
        assertFalse(session.canRetune(HDMI2));
        assertTrue(session.canRetune(HDMI3));
    }

    @Test
    public void clearedInputIsNotReopened() {
        // Katmana geçildi: TV girişi kendi ekranında gösteriyor, uygulama öne gelse de girişi geri almaz.
        HdmiSession session = new HdmiSession();
        session.want(HDMI2);
        session.clear();
        assertNull(session.input());
        assertFalse(session.toBackground());
        assertNull(session.toForeground());
    }
}
