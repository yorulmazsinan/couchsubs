// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Arayüz sözlüğü: tuş çubuğu komutu sözlükteki biçimiyle ("Hedef belirle"), menü etiketi özgünün biçimiyle Türkçe
 * kurallarıyla ("İSTATİSTİKLER", "KIYAFETLER"). Ortak vakalar fixtures/ui-commands.json (core/Tests/CouchSubsCoreTests/
 * Fixtures kopyası; Mac UiCommandsTests.swift ve Windows UiCommandsTests.cs aynı dosyayı okur).
 */
class UiCommandsTest {
    private val root = JSONObject(Fixtures.text("ui-commands.json"))

    private fun check(name: String, function: (String) -> String?) {
        val cases = root.getJSONArray(name)
        assertTrue(cases.length() >= 5)
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val text = case.getString("text")
            val expected = if (case.isNull("expected")) null else case.getString("expected")
            assertEquals("$name(\"$text\")", expected, function(text))
        }
    }

    @Test
    fun sharedCasesMatchMacAndWindows() {
        check("translate", UiCommands::translate)
        check("translateLabel", UiCommands::translateLabel)
        check("translateLabelLoosely", UiCommands::translateLabelLoosely)
        check("withoutKeyGlyph", UiCommands::withoutKeyGlyph)
    }
}
