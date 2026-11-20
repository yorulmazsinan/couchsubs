// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Altyazı hedefinde ağda TV bulunamayınca ne yapılacağı söylenir: monitör kullanan kullanıcı "Ağda TV bulunamadı"da
 * kalmıştı. Yönlendirme ekrandaki gerçek düğme adlarını ("TV uygulamasını bu telefondan kur", "Bu telefonda") anmalı;
 * düğmenin adı değişirse bu test uyarır. Türkçe ve İngilizce.
 */
class TargetHintTextTest {
    private fun strings(folder: String): Map<String, String> {
        val file = listOf("src/main/res/$folder/strings.xml", "app/src/main/res/$folder/strings.xml").map(::File).first { it.exists() }
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).getElementsByTagName("string")
        return (0 until nodes.length).associate { i ->
            val node = nodes.item(i)
            node.attributes.getNamedItem("name").nodeValue to node.textContent.replace("\\'", "'")
        }
    }

    @Test
    fun noTvHintNamesInstallButtonAndPhoneChoice() {
        for (folder in listOf("values", "values-en")) {
            val s = strings(folder)
            val hint = s.getValue("target_tvs_none_help")
            assertTrue("$folder: $hint", hint.contains(s.getValue("tvinstall_entry")))
            assertTrue("$folder: $hint", hint.contains(s.getValue("target_phone")))
            // Monitör ya da akıllı olmayan TV anılır.
            assertTrue("$folder: $hint", hint.contains(if (folder == "values") "Monitör" else "monitor"))
        }
    }
}
