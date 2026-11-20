// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Hazır ek alanın (oyuna göre sabit bölge, [GameAreaPresets]) içindeki yazı gerçekten oyunun arayüz kutusunda mı: oyun
 * yanlış seçiliyse (PS5 ana ekranı, başka oyun) ya da bölgede yalnız oyun dünyası varsa (tabela, plaka, poster)
 * çevrilmez. Bölge 96 × 48 noktaya örneklenir, 8 × 8 hücreye bölünür; her hücrede azınlık parlaklık kümesi yazı,
 * çoğunluk zemindir. Yazılı hücrenin zemini düz (sapma ≤ 22 ve %70'i ortancanın ±20'sinde) ise hücre düzdür. Kanıt: en az
 * 3 düz yazılı hücre ya da yazılı hücrelerin %60'ı düz. Windows (UiPanel.cs) ve Mac/iPhone (UiPanel.swift) aynı kurallar.
 */
object UiPanel {
    const val GRID_X = 96
    const val GRID_Y = 48
    const val CELLS = 8
    private const val TEXT_SHARE = 0.04
    private const val MIN_CONTRAST = 60.0
    private const val GROUND_DEVIATION = 22.0
    private const val GROUND_SHARE = 0.7
    private const val GROUND_TONE = 20
    private const val FLAT_CELLS = 0.6
    private const val MIN_FLAT_CELLS = 3

    /** Bölgede düz panel üstünde yazı var mı. */
    fun hasText(frame: GrayFrame): Boolean {
        if (!frame.isValid || frame.width < 8 || frame.height < 8) return false
        val luma = IntArray(GRID_X * GRID_Y)
        for (gy in 0 until GRID_Y) {
            val y = ((2L * gy + 1) * frame.height / (2 * GRID_Y)).toInt()
            for (gx in 0 until GRID_X) {
                val x = ((2L * gx + 1) * frame.width / (2 * GRID_X)).toInt()
                luma[gy * GRID_X + gx] = frame.at(x, y)
            }
        }
        return hasText(luma)
    }

    /** [GRID_X] × [GRID_Y] parlaklık değerleri (satır satır) üzerinde karar. */
    internal fun hasText(luma: IntArray): Boolean {
        val cellW = GRID_X / CELLS
        val cellH = GRID_Y / CELLS
        var textCells = 0
        var flat = 0
        val cell = IntArray(cellW * cellH)
        for (cy in 0 until CELLS) for (cx in 0 until CELLS) {
            var n = 0
            for (y in cy * cellH until (cy + 1) * cellH) for (x in cx * cellW until (cx + 1) * cellW) cell[n++] = luma[y * GRID_X + x]
            when (classify(cell)) {
                Cell.FLAT -> { textCells++; flat++ }
                Cell.BUSY -> textCells++
                Cell.EMPTY -> Unit
            }
        }
        return flat >= MIN_FLAT_CELLS || (textCells > 0 && flat >= textCells * FLAT_CELLS)
    }

    private enum class Cell { EMPTY, FLAT, BUSY }

    private fun classify(values: IntArray): Cell {
        val threshold = otsu(values)
        var above = 0
        var aboveSum = 0.0
        var belowSum = 0.0
        for (value in values) if (value > threshold) { above++; aboveSum += value } else belowSum += value
        val below = values.size - above
        if (above == 0 || below == 0) return Cell.EMPTY
        val textBright = above <= below
        val text = if (textBright) above else below
        if (text < values.size * TEXT_SHARE || abs(aboveSum / above - belowSum / below) < MIN_CONTRAST) return Cell.EMPTY
        val ground = values.filter { (it > threshold) != textBright }.sorted()
        val mean = ground.average()
        val deviation = sqrt(ground.sumOf { (it - mean) * (it - mean) } / ground.size)
        val median = ground[ground.size / 2]
        val near = ground.count { abs(it - median) <= GROUND_TONE }
        return if (deviation <= GROUND_DEVIATION && near >= ground.size * GROUND_SHARE) Cell.FLAT else Cell.BUSY
    }

    private fun otsu(values: IntArray): Int {
        val histogram = IntArray(256)
        var sum = 0.0
        for (value in values) { histogram[value]++; sum += value }
        var sumBack = 0.0
        var best = -1.0
        var weightBack = 0
        var threshold = 127
        for (i in 0 until 256) {
            weightBack += histogram[i]
            if (weightBack == 0) continue
            val weightFore = values.size - weightBack
            if (weightFore == 0) break
            sumBack += i.toDouble() * histogram[i]
            val meanBack = sumBack / weightBack
            val meanFore = (sum - sumBack) / weightFore
            val between = weightBack.toDouble() * weightFore * (meanBack - meanFore) * (meanBack - meanFore)
            if (between > best) { best = between; threshold = i }
        }
        return threshold
    }
}
