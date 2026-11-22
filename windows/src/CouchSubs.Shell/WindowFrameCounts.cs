// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell;

/// <summary>
/// Pencere yakalamanın dakikalık kare sayımı (GitHub #822). Mac'te Remote Play penceresinden altyazı ~10,6 sn arayla
/// okunuyordu ve günlükte nedeni görünmüyordu: kareler mi gelmiyor, okuma mı beklemede, ayırt edilemiyordu. Dakikada bir
/// "pencere kareleri: 600/dk, boş: 12, yedek: 0" yazılır (Mac: WindowFrameCounts, core/…/WindowCapture.swift). "boş":
/// gelip okumaya verilmeyen kare (Mac'te değişmeyen ekranın boş karesi, Windows'ta hız sınırı ya da önceki kopya sürerken
/// atlanan kare). Kareler ayrı iş parçacıklarından sayılır; kilitlidir.
/// </summary>
public sealed class WindowFrameCounts
{
    private readonly object gate = new();
    private int frames;
    private int idle;
    private int fallback;

    /// <summary>Okumaya verilen kare (yakalama akışından).</summary>
    public void Delivered() { lock (gate) frames++; }
    /// <summary>Gelip okumaya verilmeyen kare.</summary>
    public void Idle() { lock (gate) idle++; }
    /// <summary>Yedek yakalamadan (PrintWindow) okumaya verilen kare.</summary>
    public void Fallback() { lock (gate) fallback++; }

    /// <summary>Son dakikanın günlük satırı; sayaçlar sıfırlanır.</summary>
    public string MinuteLine()
    {
        lock (gate)
        {
            var line = $"pencere kareleri: {frames}/dk, boş: {idle}, yedek: {fallback}";
            frames = idle = fallback = 0;
            return line;
        }
    }
}
