// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/** Yazının yeri, içinde bulunduğu alanın kenarlarına oranla (0–1, üstten ve soldan). */
data class TextBox(val left: Double, val top: Double, val right: Double, val bottom: Double) {
    fun union(other: TextBox) =
        TextBox(minOf(left, other.left), minOf(top, other.top), maxOf(right, other.right), maxOf(bottom, other.bottom))

    /** Bu kutu [area] içindeki oranlarsa, aynı yerin [area]'yı içeren çerçevedeki oranları. */
    fun placedIn(area: TextBox): TextBox {
        val width = area.right - area.left
        val height = area.bottom - area.top
        return TextBox(area.left + left * width, area.top + top * height, area.left + right * width, area.top + bottom * height)
    }

    /**
     * Ekranın ortasındaki altyazının kutusu ortaya göre simetrik genişletilir: yazı tanıma satırın bir ucunu
     * okuyamazsa çeviri yine ortalanır ve İngilizcenin tamamını örter. Köşedeki yazıya dokunulmaz.
     */
    fun centeredOnScreen(): TextBox {
        val middle = (left + right) / 2
        if (middle <= 0.3 || middle >= 0.7) return this
        return copy(left = maxOf(0.0, minOf(left, 1 - right)), right = minOf(1.0, maxOf(right, 1 - left)))
    }
}

/** Karede okunan alan (oranlar); masaüstüyle aynı varsayılan: alt orta bölge. */
data class CropRegion(val top: Double = 0.62, val bottom: Double = 0.97, val left: Double = 0.14, val right: Double = 0.86) {
    val box get() = TextBox(left, top, right, bottom)
}

/** Yazı tanımanın bulduğu bir satır; kutu okunan alana göredir, bilinmiyorsa null. */
data class TextLine(val text: String, val box: TextBox? = null)

/** Bir karenin okunan satırları, yukarıdan aşağı (Windows: Reading.cs, Mac: Reading.swift). */
class Reading(lines: List<TextLine>) {
    val lines: List<TextLine> = lines.filter { it.text.isNotBlank() }

    companion object {
        val Empty = Reading(emptyList())

        fun fromText(text: String) = Reading(text.replace("\r\n", "\n").split('\n').map { TextLine(it.trim()) })

        /** Aynı satırdaki iki sözcük arasındaki boşluk ayrı yazılara mı işaret ediyor (menü ile gösterge gibi). */
        fun isSeparateText(gap: Double, lineHeight: Double, imageWidth: Double) =
            gap > lineHeight * 4 && gap > imageWidth * 0.12

        private fun wordCount(text: String) = text.split(Regex("\\s+")).count { it.isNotEmpty() }
    }

    val text: String get() = lines.joinToString("\n") { it.text }

    /** Bütün satırları içine alan kutu; hiçbir satırın yeri bilinmiyorsa null. */
    val box: TextBox?
        get() {
            var total: TextBox? = null
            for (line in lines) line.box?.let { total = total?.union(it) ?: it }
            return total
        }

    /** Oyunun düğme ipuçları ("R2 Swing", "△ Pick up") çıkarılmış hali; bunlar altyazı değildir. */
    fun withoutButtonPrompts() = Reading(lines.filter { !ButtonPrompts.isPrompt(it.text) })

    /** Yazı tanımanın uydurduğu sözcük çöpleri ("ou$3e") ayıklanmış hali. */
    fun withoutOcrNoise() = Reading(lines.map { it.copy(text = OcrNoise.clean(it.text)) })

    /**
     * Alandaki altyazı bloğu: satırlar yerlerine göre bloklara ayrılır; ortalanmış ve menü olmayan en alttaki blok
     * altyazıdır. Ortalanmış blok yoksa en az üç sözcüklü, menü olmayan en alttaki blok alınır. Satırların yeri
     * bilinmiyorsa okuma olduğu gibi kalır. [area]: okunan alanın karedeki yeri.
     */
    fun subtitleBlock(area: TextBox): Reading {
        if (lines.isEmpty() || lines.any { it.box == null }) return this
        val blocks = mutableListOf<MutableList<TextLine>>()
        for (line in lines.sortedBy { it.box!!.top }) {
            val placed = line.box!!.placedIn(area)
            val index = blocks.indexOfLast { belongs(placed, it, area) }
            if (index >= 0) blocks[index].add(line) else blocks.add(mutableListOf(line))
        }
        val candidates = blocks.map { Reading(it) }.filter { !it.isMenu }
        val centered = candidates.filter { reading ->
            val placed = reading.box!!.placedIn(area)
            abs((placed.left + placed.right) / 2 - 0.5) <= 0.12
        }
        if (centered.isNotEmpty()) return centered.maxBy { it.box!!.bottom }
        return candidates.filter { wordCount(it.text) >= 3 }.maxByOrNull { it.box!!.bottom } ?: Empty
    }

    private fun belongs(box: TextBox, block: List<TextLine>, area: TextBox): Boolean {
        val last = block.last().box!!.placedIn(area)
        val height = maxOf(box.bottom - box.top, last.bottom - last.top)
        if (box.top - last.bottom >= height * 0.8 || box.top < last.top) return false
        val overlap = minOf(box.right, last.right) - maxOf(box.left, last.left)
        val narrower = minOf(box.right - box.left, last.right - last.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    /** Alt alta kısa ve noktalamasız satırlar ("MAP", "HELP", "SOCIAL CLUB") menüdür, konuşma değil. */
    internal val isMenu: Boolean
        get() = lines.size >= 3 && lines.all { wordCount(it.text) <= 3 && !SubtitleStabilizer.endsSentence(it.text) }
}

/** Oyunların kumanda ipuçlarını tanır: "R2 Swing", "L1 + R1 Spartan Rage", "△ Pick up", "Press ✕ to jump". */
object ButtonPrompts {
    private val buttons = setOf(
        "r1", "r2", "r3", "l1", "l2", "l3", "options", "touchpad",
        "✕", "×", "⨯", "✖", "○", "◯", "●", "□", "▢", "◻", "■", "△", "▲", "⨂",
    )
    /** Simge yazı tanımada harfe dönüşebilir; yalnız ipucu kalıbında düğme sayılır. */
    private val lookalikes = setOf("X", "O")
    private val verbs = setOf("press", "hold", "tap", "push", "use", "mash", "release")
    private val separators = Regex("[ \\t+/]+")
    private const val BRACKETS = "()[]{}<>「」"

    private fun isButton(token: String) = token.lowercase() in buttons

    fun isPrompt(line: String): Boolean {
        val tokens = line.split(separators).map { it.trim { c -> c in BRACKETS } }.filter { it.isNotEmpty() }
        if (tokens.isEmpty()) return false
        val first = tokens[0]
        val words = tokens.count { !isButton(it) && it.any { c -> c.isLetter() } }
        if (isButton(first)) return words <= 5
        if (isButton(tokens.last()) && words <= 4 && !SubtitleStabilizer.endsSentence(line)) return true
        if (first in lookalikes && tokens.size in 2..4 && tokens[1][0].isUpperCase() && !SubtitleStabilizer.endsSentence(line))
            return true
        if (first.lowercase() in verbs && tokens.size in 2..10) return isButton(tokens[1]) || tokens[1] in lookalikes
        return false
    }
}
