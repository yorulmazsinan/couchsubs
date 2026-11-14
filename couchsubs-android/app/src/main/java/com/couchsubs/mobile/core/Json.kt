// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.math.BigDecimal
import java.math.RoundingMode

/**
 * Masaüstündeki System.Text.Json çıktısıyla aynı küçük JSON yazıcı: anahtarlar sıralı (SortedDictionary), Türkçe harfler
 * kaçışsız (UnsafeRelaxedJsonEscaping), boşluksuz. TV uygulamaları bu biçimi okur; testler birebir karşılaştırır.
 */
object Json {
    /** [value]: String, Boolean, Int/Long, [Decimal], Map<String, Any?>, List<Any?> ya da null. */
    fun write(value: Any?): String = StringBuilder().also { append(it, value) }.toString()

    /** Dört basamağa yuvarlanmış, sondaki sıfırları atılmış oran (0.8750 → 0.875); masaüstündeki Round ile aynı. */
    class Decimal(value: Double) {
        val text: String = BigDecimal.valueOf(value.coerceIn(0.0, 1.0)).setScale(4, RoundingMode.HALF_EVEN)
            .stripTrailingZeros().toPlainString()
    }

    private fun append(out: StringBuilder, value: Any?) {
        when (value) {
            null -> out.append("null")
            is String -> string(out, value)
            is Boolean -> out.append(if (value) "true" else "false")
            is Int, is Long -> out.append(value.toString())
            is Decimal -> out.append(value.text)
            is Map<*, *> -> {
                out.append('{')
                value.entries.sortedBy { it.key as String }.forEachIndexed { index, entry ->
                    if (index > 0) out.append(',')
                    string(out, entry.key as String)
                    out.append(':')
                    append(out, entry.value)
                }
                out.append('}')
            }
            is List<*> -> {
                out.append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    append(out, item)
                }
                out.append(']')
            }
            else -> throw IllegalArgumentException("JSON: ${value::class}")
        }
    }

    private fun string(out: StringBuilder, text: String) {
        out.append('"')
        for (c in text) {
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (c < ' ' || c == '\u007F') out.append("\\u%04X".format(c.code)) else out.append(c)
            }
        }
        out.append('"')
    }
}
