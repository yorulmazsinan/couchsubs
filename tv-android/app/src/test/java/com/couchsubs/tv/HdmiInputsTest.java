// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

import org.junit.Test;

public class HdmiInputsTest {
    @Test
    public void cecNamesOfTheConsolesAreRecognised() {
        assertTrue(HdmiInputs.looksLikeConsole("PS5"));
        assertTrue(HdmiInputs.looksLikeConsole("PlayStation 5"));
        assertTrue(HdmiInputs.looksLikeConsole("SONY PS 5"));
        assertTrue(HdmiInputs.looksLikeConsole("Xbox Series X"));
        assertFalse(HdmiInputs.looksLikeConsole("Soundbar"));
        assertFalse(HdmiInputs.looksLikeConsole(null));
    }

    @Test
    public void inputsAreOrderedByTheirNumber() {
        assertEquals(2, HdmiInputs.lastNumber("com.mediatek.tvinput/.hdmi.HDMIInputService/HW2"));
        assertEquals(10, HdmiInputs.lastNumber("…/HW10"));
        assertEquals(Long.MAX_VALUE, HdmiInputs.lastNumber("hdmi"));
    }

    // --- Açılışta giriş seçimi (#367) ---

    private static HdmiInputs.Choice input(int port, String device, boolean connected, boolean disconnected) {
        return new HdmiInputs.Choice(port, "HW" + port, device, connected, disconnected);
    }

    /** #367: CEC kapalı, birden çok giriş bağlı görünüyor, kayıt yok. Eskiden HDMI 1 açılıyordu; artık seçici. */
    @Test
    public void unknownConsoleInputDoesNotFallBackToHdmi1() {
        List<HdmiInputs.Choice> inputs = Arrays.asList(
                input(1, null, true, false), input(2, null, false, true), input(3, null, true, false));
        HdmiInputs.Pick pick = HdmiInputs.pick(inputs, 0, 0);
        assertEquals(0, pick.port);
        assertNull(pick.reason);
    }

    @Test
    public void noConnectedInputAndNothingSavedAsksTheUser() {
        List<HdmiInputs.Choice> inputs = Arrays.asList(input(1, null, false, false), input(2, null, false, false));
        assertEquals(0, HdmiInputs.pick(inputs, 0, 0).port);
    }

    @Test
    public void cecConsoleNameWinsOverEverything() {
        List<HdmiInputs.Choice> inputs = Arrays.asList(
                input(1, "Soundbar", true, false), input(2, null, true, false), input(3, "PlayStation 5", true, false));
        HdmiInputs.Pick pick = HdmiInputs.pick(inputs, 1, 2);
        assertEquals(3, pick.port);
        assertEquals(HdmiInputs.Pick.CONSOLE, pick.reason);
    }

    @Test
    public void xboxIsFoundByItsCecName() {
        List<HdmiInputs.Choice> inputs = Arrays.asList(input(1, null, true, false), input(4, "Xbox", true, false));
        assertEquals(4, HdmiInputs.pick(inputs, 0, 0).port);
    }

    @Test
    public void savedChoiceComesBeforeTheLastAndTheActiveInput() {
        List<HdmiInputs.Choice> inputs = Arrays.asList(
                input(1, null, true, false), input(2, null, false, false), input(3, null, false, false));
        HdmiInputs.Pick pick = HdmiInputs.pick(inputs, 3, 2);
        assertEquals(3, pick.port);
        assertEquals(HdmiInputs.Pick.SAVED, pick.reason);
    }

    @Test
    public void lastInputIsUsedWhenNothingIsSaved() {
        List<HdmiInputs.Choice> inputs = Arrays.asList(
                input(1, null, true, false), input(2, null, true, false), input(3, null, false, false));
        HdmiInputs.Pick pick = HdmiInputs.pick(inputs, 0, 3);
        assertEquals(3, pick.port);
        assertEquals(HdmiInputs.Pick.LAST, pick.reason);
    }

    @Test
    public void lastInputIsSkippedWhenTheTvSaysItIsEmpty() {
        List<HdmiInputs.Choice> inputs = Arrays.asList(input(1, null, true, false), input(3, null, false, true));
        HdmiInputs.Pick pick = HdmiInputs.pick(inputs, 0, 3);
        assertEquals(1, pick.port);
        assertEquals(HdmiInputs.Pick.ACTIVE, pick.reason);
    }

    @Test
    public void singleConnectedInputIsTheConsole() {
        List<HdmiInputs.Choice> inputs = Arrays.asList(
                input(1, null, false, true), input(2, null, false, true), input(3, null, true, false));
        HdmiInputs.Pick pick = HdmiInputs.pick(inputs, 0, 0);
        assertEquals(3, pick.port);
        assertEquals(HdmiInputs.Pick.ACTIVE, pick.reason);
    }

    @Test
    public void numbersMissingOnThisTvAreIgnored() {
        List<HdmiInputs.Choice> inputs = Arrays.asList(input(1, null, true, false), input(2, null, true, false));
        assertEquals(0, HdmiInputs.pick(inputs, 4, 7).port);
    }

    @Test
    public void tvWithoutHdmiInputsForAppsAsksTheUser() {
        assertEquals(0, HdmiInputs.pick(Collections.<HdmiInputs.Choice>emptyList(), 3, 0).port);
    }

    // --- Seçilebilecek girişler (#1292) ---

    private static final int HDMI = android.media.tv.TvInputInfo.TYPE_HDMI;
    private static final int OTHER = android.media.tv.TvInputInfo.TYPE_OTHER;
    private static final int COMPONENT = android.media.tv.TvInputInfo.TYPE_COMPONENT;
    private static final int TUNER = android.media.tv.TvInputInfo.TYPE_TUNER;

    private static HdmiInputs.Entry entry(String id, int type, boolean passthrough, String parent) {
        return new HdmiInputs.Entry(id, type, passthrough, parent);
    }

    private static String ids(List<HdmiInputs.Entry> entries) {
        StringBuilder out = new StringBuilder();
        for (HdmiInputs.Entry e : entries) out.append(out.length() == 0 ? "" : ",").append(e.id);
        return out.toString();
    }

    /** HDMI girişleri varsa yalnız onlar: alt girişler (CEC), tuner ve TYPE_OTHER girişleri sayılmaz. */
    @Test
    public void hdmiInputsWinAndSubInputsAreSkipped() {
        List<HdmiInputs.Entry> all = Arrays.asList(
                entry("mtk/HW10", HDMI, true, null), entry("mtk/HW2", HDMI, true, null),
                entry("mtk/HDMI2-PS5", HDMI, true, "mtk/HW2"), entry("oem/AV1", OTHER, true, null),
                entry("tuner", TUNER, false, null));
        assertEquals("mtk/HW2,mtk/HW10", ids(HdmiInputs.select(all)));
    }

    /** #1292: projektör HDMI girişini TYPE_OTHER bildiriyor; eskiden liste boştu, uygulama içi mod kullanılamıyordu. */
    @Test
    public void projectorWithoutHdmiTypeFallsBackToOtherPassthroughInputs() {
        List<HdmiInputs.Entry> all = Arrays.asList(
                entry("com.wanbo.tvinput/.HdmiService/HW3", OTHER, true, null),
                entry("com.wanbo.tvinput/.HdmiService/HW1", COMPONENT, true, null),
                entry("com.example.app/.Channels", OTHER, false, null),
                entry("com.wanbo.tvinput/.HdmiService/HW3-cec", OTHER, true, "com.wanbo.tvinput/.HdmiService/HW3"));
        assertEquals("com.wanbo.tvinput/.HdmiService/HW1,com.wanbo.tvinput/.HdmiService/HW3", ids(HdmiInputs.select(all)));
    }

    @Test
    public void onlyAppInputsMeanNoInputs() {
        assertTrue(HdmiInputs.select(Arrays.asList(entry("tuner", TUNER, false, null),
                entry("app", OTHER, false, null))).isEmpty());
    }

    /** Bilgi paneline TV'nin bütün girişleri yazılır: kimliğin son parçası, türü, uygulama girişi, alt giriş. */
    @Test
    public void inputListIsDescribedForDiagnostics() {
        assertEquals("HW2 hdmi, PS5 hdmi/sub, HW3 other, Channels tuner/app",
                HdmiInputs.describe(Arrays.asList(entry("mtk/HW2", HDMI, true, null), entry("mtk/PS5", HDMI, true, "mtk/HW2"),
                        entry("oem/HW3", OTHER, true, null), entry("tv/Channels", TUNER, false, null))));
        assertEquals("", HdmiInputs.describe(Collections.<HdmiInputs.Entry>emptyList()));
    }
}
