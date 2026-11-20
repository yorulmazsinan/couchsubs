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
    /// <summary>
    /// Karo başına bir kenardaki örnek sayısı (24x24 = 576 nokta). 12x12 örnek ince açık yazıya isabet etmiyordu (gerçek
    /// kare doğrulaması, GTA 6 kontrol şemasının sol sütunu); eşikler nokta sayısıyla orantılı.
    /// </summary>
    public const int Samples = 24;
    private const int Points = Samples * Samples;
    private const int Words = Points / 64;
    /// <summary>İki örnek arasında en az bu kadar süre geçer (en çok 10 Hz).</summary>
    public const int SampleIntervalMs = 100;
    /// <summary>Karo bu kadar süre durgun kalınca aday olur.</summary>
    public const int StableMs = 300;
    /// <summary>Alanın hiçbir karosu bu kadar süre aday olmazsa alan çıkar.</summary>
    public const int ExpireMs = 700;
    /// <summary>En çok bu kadar otomatik alan.</summary>
    public const int MaxAreas = 4;
    /// <summary>Menü durumunda en çok bu kadar otomatik alan (tekerlek menünün etiketleri, başlık, alt başlık).</summary>
    public const int MenuMaxAreas = 12;
    /// <summary>Menü durumu için en az bu kadar ayrı bileşen birlikte belirmeli.</summary>
    public const int MenuComponents = 3;
    /// <summary>Menünün bileşenleri en çok bu kadar arayla belirmiş olmalı.</summary>
    public const int MenuTogetherMs = 300;
    /// <summary>Bileşen dışındaki karoların en az bu kadarı düşük kenar enerjili (bulanık/karartılmış zemin) olmalı.</summary>
    public const double MenuQuietShare = 0.6;
    /// <summary>Karo içi parlaklık sapması bundan küçükse karo düşük kenar enerjilidir.</summary>
    public const double QuietDeviation = 18;
    public const string AreaName = "Screen text";

    private const int Bright = 160;
    private const int Dark = 100;
    /// <summary>Karo maskesinin "değişti" sayılması için en az farklı nokta (144 noktada 6 idi; orantılı).</summary>
    private const int MaskChange = 24;
    /// <summary>Yazı benzeri karo: parlak nokta sayısı bu aralıkta ve koyu nokta en az bu kadar (144'te 6..72, 36).</summary>
    private const int BrightMin = 24, BrightMax = 288, DarkMin = 144;
    private const double MaxShare = 0.35;
    private const double KeepOverlap = 0.30;

    private struct Tile
    {
        public bool HasLast;
        public long StableSince;
        public bool IsRejected;
        public bool Quiet;
        // Zemin (koyu) örneklerinin toplamları: panel zemini kanıtı için.
        public long DarkSum, DarkSquares;
        public int DarkCount;
    }

    /// <summary>Arayüz kanıtı: zemin örneklerinin parlaklık sapması en çok bu kadar (düz ya da yarı saydam düz panel).</summary>
    public const double GroundDeviation = 22;
    /// <summary>Zemin karolarının en az bu kadarı aynı tonda (±<see cref="GroundTone"/>).</summary>
    public const double GroundShare = 0.7;
    public const double GroundTone = 20;
    /// <summary>Arayüz kanıtı: bileşen en az bu kadar yerinde sabit kalmış olmalı.</summary>
    public const int UiStableMs = 600;

    // Karo maskeleri düz dizilerde (karo başına Words adet 64 bitlik sözcük): her örnekte ayırma yok.
    private readonly ulong[] lastMasks = new ulong[Columns * Rows * Words];
    private readonly ulong[] rejectedMasks = new ulong[Columns * Rows * Words];
    private readonly ulong[] sampleMask = new ulong[Words];

    private static int Distance(ReadOnlySpan<ulong> a, ReadOnlySpan<ulong> b)
    {
        var sum = 0;
        for (var i = 0; i < a.Length; i++) sum += BitOperations.PopCount(a[i] ^ b[i]);
        return sum;
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
        public bool Menu { get; set; }
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
    private bool menu;

    /// <summary>Son örnekte ekranda menü vardı (bulanık zeminde birlikte beliren en az üç yazı).</summary>
    public bool InMenu
    {
        get { lock (gate) return menu; }
    }

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
    /// Kareyi örnekler ve alanları günceller. <paramref name="excluded"/>: kullanıcının etkin ek alanları ve hazır alanlar
    /// (merkezi bunların içinde kalan karo aday olmaz). <paramref name="subtitle"/>: altyazı alanı; menü durumunda dışlanmaz
    /// (menünün alttaki satırları ve tuş çubuğu da okunur). Alan listesi değiştiyse true.
    /// </summary>
    public bool Sample(Frame frame, long now, IReadOnlyList<CropRegion> excluded, CropRegion? subtitle = null)
    {
        lock (gate)
        {
            if (lastSample is { } last && now - last < SampleIntervalMs) return false;
            lastSample = now;
            var before = Current();
            var anywhere = new bool[tiles.Length];
            var candidate = new bool[tiles.Length];
            for (var row = 0; row < Rows; row++)
                for (var column = 0; column < Columns; column++)
                {
                    var index = row * Columns + column;
                    var (bright, dark, deviation, darkSum, darkSquares) = Measure(frame, column, row, sampleMask);
                    ref var tile = ref tiles[index];
                    (tile.DarkSum, tile.DarkSquares, tile.DarkCount) = (darkSum, darkSquares, dark);
                    var previous = lastMasks.AsSpan(index * Words, Words);
                    tile.Quiet = deviation < QuietDeviation;
                    if (!tile.HasLast || Distance(previous, sampleMask) > MaskChange) tile.StableSince = now;
                    sampleMask.CopyTo(previous);
                    tile.HasLast = true;
                    if (tile.IsRejected && Distance(rejectedMasks.AsSpan(index * Words, Words), sampleMask) > MaskChange) tile.IsRejected = false;
                    var textLike = bright is >= BrightMin and <= BrightMax && dark >= DarkMin;
                    anywhere[index] = textLike && now - tile.StableSince >= StableMs && !tile.IsRejected && !Excluded(column, row, excluded);
                    candidate[index] = anywhere[index] && (subtitle is not { } area || !Excluded(column, row, [area]));
                }
            var inMenu = IsMenu(Components(candidate), now);
            // Menüde altyazı alanındaki satırlar da menünün parçasıdır (alttaki seçenekler, tuş çubuğu).
            if (inMenu) candidate = anywhere;
            var all = Components(candidate);
            // Menü dışında yalnız arayüz kanıtı olan bileşen alan olur: düz panel zemini ve yerinde sabitlik. Oyun dünyasındaki
            // yazı (poster, plaka, tabela) dokulu zeminde ya da kamerayla kayarak durur, çevrilmez.
            var components = inMenu ? all : [.. all.Where(item => item.Tiles.Count >= 2 && IsInterface(item.Cells, item.Tiles, now))];
            Update([.. components.OrderByDescending(item => item.Tiles.Count).Take(inMenu ? MenuMaxAreas : MaxAreas)], candidate, now, inMenu);
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
                lastMasks.AsSpan(index * Words, Words).CopyTo(rejectedMasks.AsSpan(index * Words, Words));
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
            Array.Clear(lastMasks);
            Array.Clear(rejectedMasks);
            tracked.Clear();
            lastSample = null;
            menu = false;
        }
    }

    /// <summary>
    /// Bileşen bir arayüz kutusu mu: kutusundaki zemin (koyu) örneklerinin parlaklık sapması en çok
    /// <see cref="GroundDeviation"/> ve zemin karolarının en az %70'i aynı tonda (düz ya da yarı saydam düz panel); karoları
    /// en az <see cref="UiStableMs"/> yerinde sabit.
    /// </summary>
    private bool IsInterface(Cells cells, List<int> component, long now)
    {
        if (component.Any(index => now - tiles[index].StableSince < UiStableMs)) return false;
        long sum = 0, squares = 0, count = 0;
        var means = new List<double>();
        for (var row = cells.Top; row <= cells.Bottom; row++)
            for (var column = cells.Left; column <= cells.Right; column++)
            {
                ref var tile = ref tiles[row * Columns + column];
                if (tile.DarkCount == 0) continue;
                sum += tile.DarkSum;
                squares += tile.DarkSquares;
                count += tile.DarkCount;
                if (tile.DarkCount >= Points / 10) means.Add((double)tile.DarkSum / tile.DarkCount);
            }
        if (count == 0 || means.Count == 0) return false;
        var mean = (double)sum / count;
        var deviation = Math.Sqrt(Math.Max(0, (double)squares / count - mean * mean));
        if (deviation > GroundDeviation) return false;
        var median = means.Order().ElementAt(means.Count / 2);
        return means.Count(value => Math.Abs(value - median) <= GroundTone) >= GroundShare * means.Count;
    }

    private static (int Bright, int Dark, double Deviation, long DarkSum, long DarkSquares) Measure(Frame frame, int column, int row, ulong[] mask)
    {
        Array.Clear(mask);
        var x0 = (long)column * frame.Width / Columns;
        var x1 = (long)(column + 1) * frame.Width / Columns;
        var y0 = (long)row * frame.Height / Rows;
        var y1 = (long)(row + 1) * frame.Height / Rows;
        var pixels = frame.Pixels;
        int bright = 0, dark = 0, bit = 0;
        long sum = 0, squares = 0, darkSum = 0, darkSquares = 0;
        for (var sy = 0; sy < Samples; sy++)
        {
            var y = (int)(y0 + (2 * sy + 1) * (y1 - y0) / (2 * Samples));
            var line = y * frame.Stride;
            for (var sx = 0; sx < Samples; sx++, bit++)
            {
                var x = (int)(x0 + (2 * sx + 1) * (x1 - x0) / (2 * Samples));
                var p = line + x * 4;
                var luma = (299 * pixels[p + 2] + 587 * pixels[p + 1] + 114 * pixels[p]) / 1000;
                sum += luma;
                squares += luma * luma;
                if (luma >= Bright)
                {
                    bright++;
                    mask[bit >> 6] |= 1UL << (bit & 63);
                }
                else if (luma <= Dark)
                {
                    dark++;
                    darkSum += luma;
                    darkSquares += luma * luma;
                }
            }
        }
        var mean = (double)sum / Points;
        return (bright, dark, Math.Sqrt(Math.Max(0, (double)squares / Points - mean * mean)), darkSum, darkSquares);
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
            var cells = new Cells(list.Min(i => i % Columns), list.Min(i => i / Columns), list.Max(i => i % Columns), list.Max(i => i / Columns));
            // Ekranın büyük bölümünü kaplayan bileşen yazı kutusu değil, sahne dokusudur.
            if (cells.Area > MaxShare * Columns * Rows) continue;
            result.Add((cells, list));
        }
        return result;
    }

    /// <summary>
    /// Menü durumu: en az üç ayrı bileşen var ve bileşenlerin dışındaki karoların çoğu düşük kenar enerjili (bulanık ya da
    /// karartılmış zemin). Menüye ilk girişte bileşenlerin en çok 300 ms arayla birlikte belirmiş olması da gerekir;
    /// menüde gezinirken (seçim çerçevesi değişince) durum korunur.
    /// </summary>
    private bool IsMenu(List<(Cells Cells, List<int> Tiles)> components, long now)
    {
        if (components.Count < MenuComponents) return false;
        var inside = components.SelectMany(item => item.Tiles).ToHashSet();
        var outside = Enumerable.Range(0, tiles.Length).Where(index => !inside.Contains(index)).ToList();
        if (outside.Count == 0 || outside.Count(index => tiles[index].Quiet) < MenuQuietShare * outside.Count) return false;
        if (menu) return true;
        var appeared = components.Select(item => item.Tiles.Max(index => tiles[index].StableSince)).ToList();
        return appeared.Max() - appeared.Min() <= MenuTogetherMs;
    }

    private void Update(List<(Cells Cells, List<int> Tiles)> components, bool[] candidate, long now, bool inMenu)
    {
        var closed = menu && !inMenu;
        menu = inMenu;
        // Menü kapandı: karoları artık aday olmayan menü alanları hemen kalkar (700 ms beklemez). Karoları hâlâ yerinde
        // duran alan (seçim gezinirken menü durumu bir örnek düşse de) kalır; kutusu yanıp sönmez.
        if (closed) tracked.RemoveAll(item => item.Menu && !item.Tiles.Any(index => candidate[index]));
        var matched = new HashSet<Tracked>();
        foreach (var (cells, list) in components)
        {
            var existing = tracked.Where(item => !matched.Contains(item)).FirstOrDefault(item => item.Cells.Overlap(cells) >= KeepOverlap);
            if (existing is null)
            {
                if (tracked.Count >= (inMenu ? MenuMaxAreas : MaxAreas)) continue;
                existing = new Tracked("auto-" + ++counter, cells, list, now);
                tracked.Add(existing);
            }
            // Bölge en az bir karo kayınca güncellenir (Cells karo biriminde olduğundan her fark bir karodur).
            existing.Cells = cells;
            existing.Tiles = list;
            existing.Seen = now;
            existing.Menu = inMenu;
            matched.Add(existing);
        }
        foreach (var item in tracked)
            if (!matched.Contains(item) && item.Tiles.Any(index => candidate[index])) item.Seen = now;
        tracked.RemoveAll(item => now - item.Seen >= ExpireMs);
    }

    private List<WatchedArea> Current() =>
        [.. tracked.Select(item => new WatchedArea(item.Id, AreaName, Region(item.Cells)) { Auto = true, Menu = item.Menu })];

    /// <summary>
    /// Karo dikdörtgeni dikeyde yarım, yatayda bir karo genişletilmiş, 0..1'e kırpılmış bölge (yarım karo sözcüğün başını
    /// kesiyordu: "RECENTER" → "CENTER").
    /// </summary>
    private static CropRegion Region(Cells cells) => new(
        Math.Max(0, (cells.Top - 0.5) / Rows), Math.Min(1, (cells.Bottom + 1.5) / Rows),
        Math.Max(0, (cells.Left - 1.0) / Columns), Math.Min(1, (cells.Right + 2.0) / Columns));
}

/// <summary>
/// Otomatik bulunan alanda okunan yazı çevrilmeye değer mi: sayaç, saat, para, tek sözcüklük etiket ya da büyük harfli
/// kısa tabela gürültüdür (Mac/Android: ScreenTextNoise ile aynı kurallar). Yalnız otomatik alanlarda uygulanır.
/// </summary>
public static partial class ScreenTextNoise
{
    /// <summary>Yayıncı katmanının sık yazıları (logo, canlı yayın işareti); oyun yazısı değildir.</summary>
    private static readonly HashSet<string> Overlay = new(StringComparer.OrdinalIgnoreCase)
    {
        "GAMING", "GAMERS", "REPUBLIC OF", "REPUBLIC OF GAMERS", "ROG", "LIVE", "CANLI", "CANLİ",
    };

    [System.Text.RegularExpressions.GeneratedRegex(@"\b[\w-]+\.(?:com|net|org|tv|tr|gg|io|live|tk)\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase)]
    private static partial System.Text.RegularExpressions.Regex Domain();

    // Simge sözcüğün içinde (ardında harf var): "Delights." gibi sondaki noktalama tuhaf sayılmaz.
    [System.Text.RegularExpressions.GeneratedRegex(@"[bcçdfgğhjklmnpqrsştvwxyz]{3,}[^\p{L}\s]\p{L}", System.Text.RegularExpressions.RegexOptions.IgnoreCase)]
    private static partial System.Text.RegularExpressions.Regex ConsonantsAndSymbol();

    /// <summary>
    /// Yazı tanımanın bozuk okuması mı: harflerin %30'undan fazlası tuhaf sözcüklerde (sözcük içinde büyük-küçük harf
    /// karışık, art arda üç ünsüz ve simge, noktalamalı tek harf). Yalnız sözlükte ve pakette bulunmayan parçaya bakılır.
    /// </summary>
    public static bool IsGarbled(string text)
    {
        var plain = IconText.Plain(text);
        var letters = plain.Count(char.IsLetter);
        if (letters == 0) return false;
        var odd = 0;
        foreach (var word in plain.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var count = word.Count(char.IsLetter);
            var inner = word.Length > 1 ? word[1..] : "";
            var mixed = inner.Any(char.IsUpper) && inner.Any(char.IsLower);
            var single = count == 1 && word.Length > 1 && word.Any(char.IsPunctuation);
            if (mixed || single || ConsonantsAndSymbol().IsMatch(word)) odd += count;
        }
        return odd > 0.3 * letters;
    }

    /// <summary>Satır yayın katmanının yazısı mı (alan adı "GEN.TR", logo "REPUBLIC OF GAMERS", "• Canlı").</summary>
    public static bool IsOverlay(string line)
    {
        var text = IconText.Plain(line).Trim().TrimStart('•', '·', '●', ' ');
        return Domain().IsMatch(text) || Overlay.Contains(text);
    }

    /// <param name="menu">
    /// Menü durumunda (<see cref="WatchedArea.Menu"/>) kısa etiketler de çevrilir ("OFF", "ON", "OUTFITS"): yalnız harfsiz
    /// (sayı, simge, noktalama: "40", "100%") ve sayısı ağır basan ("x3") etiketler gürültüdür.
    /// </param>
    public static bool IsNoise(string text, bool menu = false)
    {
        var plain = IconText.Plain(text);
        var letters = plain.Count(char.IsLetter);
        var digits = plain.Count(char.IsDigit);
        if (letters == 0 || digits * 2 > letters) return true;
        if (menu) return false;
        if (letters < 8) return true;
        var words = plain.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(token => token.Count(char.IsLetter) >= 2);
        if (words < 2) return true;
        return !plain.Any(char.IsLower) && words < 3;
    }
}
