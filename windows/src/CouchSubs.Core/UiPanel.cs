// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Hazır ek alanın (oyuna göre sabit bölge, <see cref="GameAreaPresets"/>) içindeki yazı gerçekten oyunun arayüz kutusunda
/// mı: oyun yanlış seçiliyse (PS5 ana ekranı, başka oyun) ya da bölgede yalnız oyun dünyası varsa (tabela, plaka, poster)
/// çevrilmez. Ölçüt dünya yazısı elemesiyle (#682) aynı: yazının arkasındaki zemin düz ya da yarı saydam düz panel olmalı.
/// Bölge hücrelere bölünür; her hücrede azınlık parlaklık kümesi yazı, çoğunluk zemindir (açık zeminde koyu yazı da olur).
/// Yalnız yazılı hücrelerin zeminine bakılır: yardım kutusu bölgenin bir köşesinde durur, kalanı oyun dünyasıdır.
/// Mac/iPhone (UiPanel.swift) ve Android (UiPanel.kt) aynı kuralları uygular.
/// </summary>
public static class UiPanel
{
    /// <summary>Örnek ızgarası (bölge başına GridX × GridY nokta), hücre ızgarası (Cells × Cells; hücre 12 × 6 nokta).</summary>
    public const int GridX = 96, GridY = 48, Cells = 8;
    /// <summary>Hücre yazılı sayılır: azınlık (yazı) noktaları hücrenin %4–%50'si ve iki küme arasında en az bu kadar fark.</summary>
    public const double TextShare = 0.04;
    public const int MinContrast = 60;
    /// <summary>Zemin düz: yazılı hücredeki zemin noktalarının sapması en çok 22 ve en az %70'i ortancanın ±20'sinde.</summary>
    public const double GroundDeviation = 22, GroundShare = 0.7, GroundTone = 20;
    /// <summary>
    /// Kanıt: yazılı hücrelerin en az %60'ı düz zeminde ya da en az <see cref="MinFlatCells"/> yazılı hücre düz zeminde
    /// (yardım kutusu bölgenin bir köşesinde, kalanı oyun dünyası).
    /// </summary>
    public const double FlatCells = 0.6;
    public const int MinFlatCells = 3;

    /// <summary>Bölgede düz panel üstünde yazı var mı.</summary>
    public static bool HasText(Frame crop)
    {
        if (crop.Width < 8 || crop.Height < 8) return false;
        var luma = new int[GridX * GridY];
        for (var gy = 0; gy < GridY; gy++)
        {
            var y = (int)((2L * gy + 1) * crop.Height / (2 * GridY));
            for (var gx = 0; gx < GridX; gx++)
            {
                var x = (int)((2L * gx + 1) * crop.Width / (2 * GridX));
                var p = y * crop.Stride + x * 4;
                luma[gy * GridX + gx] = (299 * crop.Pixels[p + 2] + 587 * crop.Pixels[p + 1] + 114 * crop.Pixels[p]) / 1000;
            }
        }
        int cellW = GridX / Cells, cellH = GridY / Cells, textCells = 0, flatCells = 0;
        var cell = new int[cellW * cellH];
        for (var cy = 0; cy < Cells; cy++)
            for (var cx = 0; cx < Cells; cx++)
            {
                var n = 0;
                for (var y = cy * cellH; y < (cy + 1) * cellH; y++)
                    for (var x = cx * cellW; x < (cx + 1) * cellW; x++)
                        cell[n++] = luma[y * GridX + x];
                switch (Classify(cell))
                {
                    case Cell.Flat: textCells++; flatCells++; break;
                    case Cell.Busy: textCells++; break;
                }
            }
        return flatCells >= MinFlatCells || (textCells > 0 && flatCells >= textCells * FlatCells);
    }

    private enum Cell { Empty, Flat, Busy }

    private static Cell Classify(int[] values)
    {
        var threshold = Otsu(values);
        int above = 0;
        double aboveSum = 0, belowSum = 0;
        foreach (var value in values)
        {
            if (value > threshold) { above++; aboveSum += value; }
            else belowSum += value;
        }
        var below = values.Length - above;
        if (above == 0 || below == 0) return Cell.Empty;
        var textBright = above <= below;
        var text = textBright ? above : below;
        if (text < values.Length * TextShare || Math.Abs(aboveSum / above - belowSum / below) < MinContrast) return Cell.Empty;
        var ground = values.Where(value => (value > threshold) != textBright).ToList();
        var mean = ground.Average();
        var deviation = Math.Sqrt(ground.Sum(v => (v - mean) * (v - mean)) / ground.Count);
        ground.Sort();
        var median = ground[ground.Count / 2];
        var near = ground.Count(v => Math.Abs(v - median) <= GroundTone);
        return deviation <= GroundDeviation && near >= ground.Count * GroundShare ? Cell.Flat : Cell.Busy;
    }

    private static int Otsu(int[] values)
    {
        var histogram = new int[256];
        double sum = 0;
        foreach (var value in values) { histogram[value]++; sum += value; }
        double sumBack = 0, best = -1;
        int weightBack = 0, threshold = 127;
        for (var i = 0; i < 256; i++)
        {
            weightBack += histogram[i];
            if (weightBack == 0) continue;
            var weightFore = values.Length - weightBack;
            if (weightFore == 0) break;
            sumBack += i * (double)histogram[i];
            var meanBack = sumBack / weightBack;
            var meanFore = (sum - sumBack) / weightFore;
            var between = (double)weightBack * weightFore * (meanBack - meanFore) * (meanBack - meanFore);
            if (between > best) { best = between; threshold = i; }
        }
        return threshold;
    }
}
