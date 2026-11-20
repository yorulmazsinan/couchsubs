// SPDX-License-Identifier: AGPL-3.0-only

using System.Numerics;

namespace CouchSubs.Core;

/// <summary>
/// Ekran yazılarını kendiliğinden bulur (görev, yardım kutusu, mesaj; oyundan bağımsız, sabit bölge yok). Kare 32x18
/// karoya bölünür, her karodan 12x12 nokta örneği alınır: koyu ya da yarı saydam zeminde açık renk yazı taşıyan ve en az
/// 300 ms durgun kalan karolar birleşip geçici ek alan olur (<see cref="WatchedArea.Auto"/>). OCR, paket ve canlı çeviri,
/// yerinde gösterme ve boşalınca kaldırma <see cref="RegionWatcher"/>'dadır. Okunup yazı bulunmayan ya da gürültü çıkan
/// alan (harita, para, saat) <see cref="Reject"/> ile bildirilir; karoları görüntü değişmedikçe yeniden önerilmez.
/// Mac/iPhone (ScreenTextDetector.swift) ve Android (ScreenTextDetector.kt) aynı kuralları ve eşikleri uygular.
/// </summary>
public sealed class ScreenTextDetector
{
    public const int Columns = 32;
    public const int Rows = 18;
    /// <summary>Karo başına bir kenardaki örnek sayısı (12x12 = 144 nokta).</summary>
    public const int Samples = 12;
    /// <summary>İki örnek arasında en az bu kadar süre geçer (en çok 10 Hz).</summary>
    public const int SampleIntervalMs = 100;
    /// <summary>Karo bu kadar süre durgun kalınca aday olur.</summary>
    public const int StableMs = 300;
    /// <summary>Alanın hiçbir karosu bu kadar süre aday olmazsa alan çıkar.</summary>
    public const int ExpireMs = 700;
    /// <summary>En çok bu kadar otomatik alan.</summary>
    public const int MaxAreas = 4;
    public const string AreaName = "Screen text";

    private const int Bright = 160;
    private const int Dark = 100;
    private const int MaskChange = 6;
    private const double MaxShare = 0.35;
    private const double KeepOverlap = 0.30;

    private struct Tile
    {
        public Mask Last;
        public bool HasLast;
        public long StableSince;
        public Mask Rejected;
        public bool IsRejected;
    }

    private record struct Mask(ulong A, ulong B, ulong C)
    {
        public readonly int Distance(Mask other) =>
            BitOperations.PopCount(A ^ other.A) + BitOperations.PopCount(B ^ other.B) + BitOperations.PopCount(C ^ other.C);
    }

    /// <summary>Karo dikdörtgeni (sütun/satır, iki uç dahil).</summary>
    private readonly record struct Cells(int Left, int Top, int Right, int Bottom)
    {
        public int Area => (Right - Left + 1) * (Bottom - Top + 1);

        public double Overlap(Cells other)
        {
            var w = Math.Min(Right, other.Right) - Math.Max(Left, other.Left) + 1;
            var h = Math.Min(Bottom, other.Bottom) - Math.Max(Top, other.Top) + 1;
            return w <= 0 || h <= 0 ? 0 : (double)(w * h) / Math.Min(Area, other.Area);
        }
    }

    private sealed class Tracked(string id, Cells cells, List<int> tiles, long seen)
    {
        public string Id { get; } = id;
        public Cells Cells { get; set; } = cells;
        public List<int> Tiles { get; set; } = tiles;
        public long Seen { get; set; } = seen;
    }

    private readonly object gate = new();
    private readonly Tile[] tiles = new Tile[Columns * Rows];
    private readonly List<Tracked> tracked = [];
    private long? lastSample;
    private int counter;

    /// <summary>Şu an önerilen otomatik alanlar.</summary>
    public IReadOnlyList<WatchedArea> Areas
    {
        get { lock (gate) return Current(); }
    }

    /// <summary>Örnek zamanı geldi mi (son örnekten en az <see cref="SampleIntervalMs"/> geçti).</summary>
    public bool Due(long now)
    {
        lock (gate) return lastSample is null || now - lastSample.Value >= SampleIntervalMs;
    }

    /// <summary>
    /// Kareyi örnekler ve alanları günceller. <paramref name="excluded"/>: altyazı alanı ve kullanıcının etkin ek alanları
    /// (merkezi bunların içinde kalan karo aday olmaz). Alan listesi değiştiyse true.
    /// </summary>
    public bool Sample(Frame frame, long now, IReadOnlyList<CropRegion> excluded)
    {
        lock (gate)
        {
            if (lastSample is { } last && now - last < SampleIntervalMs) return false;
            lastSample = now;
            var before = Current();
            var candidate = new bool[tiles.Length];
            for (var row = 0; row < Rows; row++)
                for (var column = 0; column < Columns; column++)
                {
                    var index = row * Columns + column;
                    var (mask, bright, dark) = Measure(frame, column, row);
                    ref var tile = ref tiles[index];
                    if (!tile.HasLast || tile.Last.Distance(mask) > MaskChange) tile.StableSince = now;
                    tile.Last = mask;
                    tile.HasLast = true;
                    if (tile.IsRejected && tile.Rejected.Distance(mask) > MaskChange) tile.IsRejected = false;
                    var textLike = bright is >= 6 and <= 72 && dark >= 36;
                    candidate[index] = textLike && now - tile.StableSince >= StableMs && !tile.IsRejected
                        && !Excluded(column, row, excluded);
                }
            Update(Components(candidate), candidate, now);
            return !before.SequenceEqual(Current());
        }
    }

    /// <summary>
    /// Alan okundu ama yazı bulunmadı ya da gürültüydü: karoları bu görüntüde reddedilir (görüntü belirgin değişene dek
    /// yeniden önerilmez) ve alan çıkar.
    /// </summary>
    public void Reject(string id)
    {
        lock (gate)
        {
            var area = tracked.FirstOrDefault(item => item.Id == id);
            if (area is null) return;
            foreach (var index in area.Tiles)
            {
                tiles[index].Rejected = tiles[index].Last;
                tiles[index].IsRejected = true;
            }
            tracked.Remove(area);
        }
    }

    /// <summary>Çeviri durdu ya da oturum sıfırlandı: alanlar ve karo durumu silinir.</summary>
    public void Reset()
    {
        lock (gate)
        {
            Array.Clear(tiles);
            tracked.Clear();
            lastSample = null;
        }
    }

    private static (Mask Mask, int Bright, int Dark) Measure(Frame frame, int column, int row)
    {
        var x0 = (long)column * frame.Width / Columns;
        var x1 = (long)(column + 1) * frame.Width / Columns;
        var y0 = (long)row * frame.Height / Rows;
        var y1 = (long)(row + 1) * frame.Height / Rows;
        var pixels = frame.Pixels;
        ulong a = 0, b = 0, c = 0;
        int bright = 0, dark = 0, bit = 0;
        for (var sy = 0; sy < Samples; sy++)
        {
            var y = (int)(y0 + (2 * sy + 1) * (y1 - y0) / (2 * Samples));
            var line = y * frame.Stride;
            for (var sx = 0; sx < Samples; sx++, bit++)
            {
                var x = (int)(x0 + (2 * sx + 1) * (x1 - x0) / (2 * Samples));
                var p = line + x * 4;
                var luma = (299 * pixels[p + 2] + 587 * pixels[p + 1] + 114 * pixels[p]) / 1000;
                if (luma >= Bright)
                {
                    bright++;
                    if (bit < 64) a |= 1UL << bit;
                    else if (bit < 128) b |= 1UL << (bit - 64);
                    else c |= 1UL << (bit - 128);
                }
                else if (luma <= Dark) dark++;
            }
        }
        return (new Mask(a, b, c), bright, dark);
    }

    private static bool Excluded(int column, int row, IReadOnlyList<CropRegion> excluded)
    {
        var x = (column + 0.5) / Columns;
        var y = (row + 0.5) / Rows;
        foreach (var region in excluded)
            if (x >= region.Left && x <= region.Right && y >= region.Top && y <= region.Bottom) return true;
        return false;
    }

    /// <summary>Aday karoların bileşenleri: 4-komşuluk ve aynı satırda en çok bir boş karo aralık.</summary>
    private static List<(Cells Cells, List<int> Tiles)> Components(bool[] candidate)
    {
        var parent = new int[candidate.Length];
        for (var i = 0; i < parent.Length; i++) parent[i] = i;
        int Find(int i)
        {
            while (parent[i] != i) i = parent[i] = parent[parent[i]];
            return i;
        }
        void Join(int i, int j) => parent[Find(i)] = Find(j);
        for (var row = 0; row < Rows; row++)
            for (var column = 0; column < Columns; column++)
            {
                var index = row * Columns + column;
                if (!candidate[index]) continue;
                if (column + 1 < Columns && candidate[index + 1]) Join(index, index + 1);
                else if (column + 2 < Columns && candidate[index + 2]) Join(index, index + 2);
                if (row + 1 < Rows && candidate[index + Columns]) Join(index, index + Columns);
            }
        var groups = new Dictionary<int, List<int>>();
        for (var i = 0; i < candidate.Length; i++)
            if (candidate[i])
            {
                var root = Find(i);
                if (!groups.TryGetValue(root, out var list)) groups[root] = list = [];
                list.Add(i);
            }
        var result = new List<(Cells, List<int>)>();
        foreach (var list in groups.Values)
        {
            if (list.Count < 2) continue;
            var cells = new Cells(list.Min(i => i % Columns), list.Min(i => i / Columns), list.Max(i => i % Columns), list.Max(i => i / Columns));
            // Ekranın büyük bölümünü kaplayan bileşen yazı kutusu değil, sahne dokusudur.
            if (cells.Area > MaxShare * Columns * Rows) continue;
            result.Add((cells, list));
        }
        return [.. result.OrderByDescending(item => item.Item2.Count).Take(MaxAreas)];
    }

    private void Update(List<(Cells Cells, List<int> Tiles)> components, bool[] candidate, long now)
    {
        var matched = new HashSet<Tracked>();
        foreach (var (cells, list) in components)
        {
            var existing = tracked.Where(item => !matched.Contains(item)).FirstOrDefault(item => item.Cells.Overlap(cells) >= KeepOverlap);
            if (existing is null)
            {
                if (tracked.Count >= MaxAreas) continue;
                existing = new Tracked("auto-" + ++counter, cells, list, now);
                tracked.Add(existing);
            }
            // Bölge en az bir karo kayınca güncellenir (Cells karo biriminde olduğundan her fark bir karodur).
            existing.Cells = cells;
            existing.Tiles = list;
            existing.Seen = now;
            matched.Add(existing);
        }
        foreach (var item in tracked)
            if (!matched.Contains(item) && item.Tiles.Any(index => candidate[index])) item.Seen = now;
        tracked.RemoveAll(item => now - item.Seen >= ExpireMs);
    }

    private List<WatchedArea> Current() => [.. tracked.Select(item => new WatchedArea(item.Id, AreaName, Region(item.Cells)) { Auto = true })];

    /// <summary>Karo dikdörtgeni her yandan yarım karo genişletilmiş, 0..1'e kırpılmış bölge.</summary>
    private static CropRegion Region(Cells cells) => new(
        Math.Max(0, (cells.Top - 0.5) / Rows), Math.Min(1, (cells.Bottom + 1.5) / Rows),
        Math.Max(0, (cells.Left - 0.5) / Columns), Math.Min(1, (cells.Right + 1.5) / Columns));
}

/// <summary>
/// Otomatik bulunan alanda okunan yazı çevrilmeye değer mi: sayaç, saat, para, tek sözcüklük etiket ya da büyük harfli
/// kısa tabela gürültüdür (Mac/Android: ScreenTextNoise ile aynı kurallar). Yalnız otomatik alanlarda uygulanır.
/// </summary>
public static class ScreenTextNoise
{
    public static bool IsNoise(string text)
    {
        var plain = IconText.Plain(text);
        var letters = plain.Count(char.IsLetter);
        var digits = plain.Count(char.IsDigit);
        if (letters < 8 || digits * 2 > letters) return true;
        var words = plain.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(token => token.Count(char.IsLetter) >= 2);
        if (words < 2) return true;
        return !plain.Any(char.IsLower) && words < 3;
    }
}
