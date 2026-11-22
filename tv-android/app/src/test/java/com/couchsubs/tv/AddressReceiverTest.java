// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class AddressReceiverTest {
    @Test
    public void acceptsOnlyShortJsonObjects() {
        assertTrue(AddressReceiver.usable("{\"server\":\"http://192.168.1.20:8787\"}"));
        assertTrue(AddressReceiver.usable(" {\"server\":\"http://192.168.1.20:51234\",\"key\":\"abcdefghijklmnopqrstuv\"} "));
        assertFalse(AddressReceiver.usable(null));
        assertFalse(AddressReceiver.usable(""));
        assertFalse(AddressReceiver.usable("{}"));
        assertFalse(AddressReceiver.usable("http://192.168.1.20:8787"));
        StringBuilder huge = new StringBuilder("{\"server\":\"");
        while (huge.length() < 3000) huge.append('a');
        assertFalse(AddressReceiver.usable(huge.append("\"}").toString()));
    }
}
