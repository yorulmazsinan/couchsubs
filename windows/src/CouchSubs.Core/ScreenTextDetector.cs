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

    /// <summary>
    /// Kontur yazı karosu (576 noktada): açık harf noktaları ve koyu kontur noktaları ikisi de 24..288; geri kalanı orta ton
    /// (açık harita, yarı saydam kartın haritaya binen yanı). Yalnız menüde (açık sahne yazı sanılmasın). Mac ile aynı.
    /// </summary>
    internal static bool Outlined(int bright, int dark) =>
        bright is >= BrightMin and <= BrightMax && dark is >= BrightMin and <= BrightMax;
    private const double MaxShare = 0.35;
    private const double KeepOverlap = 0.30;

    private struct Tile
    {
        public bool HasLast;
        public long StableSince;
        public bool IsRejected;
        /// <summary>Karo okununca tuş ipucu ya da görev/HUD yazısı çıktı (<see cref="MarkHud"/>): menü için sayılmaz.</summary>
        public bool IsHud;
        public bool Quiet;
        /// <summary>Karonun ortalama parlaklığı (harita düzeni: koyu panel ↔ açık harita).</summary>
        public double Mean;
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
    internal readonly record struct Cells(int Left, int Top, int Right, int Bottom)
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
    /// <summary>Menüye girildiği örnekteki bileşenlerin karoları: menü bunlar yerinde durdukça sürer (<see cref="IsMenu"/>).</summary>
    private HashSet<int> menuAnchors = [];
    /// <summary>Menüye girilen an ve süresi dolan menünün bittiği an (bundan önce belirmiş yazılar yeniden menü sayılmaz).</summary>
    private long menuEnteredAt;
    private long? menuFloor;

    /// <summary>
    /// Menüde hiçbir yazı değişmeden bu kadar süre geçince menü durumu biter. Karanlık sahnede birlikte beliren sabit HUD
    /// yazıları da menü sanılabiliyor; menü durumu altyazıyı en çok bu kadar susturur (Mac/iPhone, Android ile aynı).
    /// </summary>
    public const int MenuLifeMs = 5000;

    /// <summary>Tanı: her örnekte bileşenler, bölgeleri ve kanıtları (gerçek kare doğrulaması günlüğe yazar).</summary>
    internal Action<string>? Diagnose { get; set; }

    private static string Fmt(CropRegion r) => FormattableString.Invariant($"[{r.Left:0.00}-{r.Right:0.00} x {r.Top:0.00}-{r.Bottom:0.00}]");

    /// <summary>Tanı satırları (harita düzeni bulundu/bitti); uygulama altyazı günlüğüne yazar. Kilidin dışında çağrılır.</summary>
    public Action<string>? OnLog { get; set; }
    private List<string> notes = [];
    private string? mapPanelSeen;

    /// <summary>Son örnekte harita düzeni (#1365) tanındı.</summary>
    public bool InMapLayout
    {
        get { lock (gate) return mapPanelSeen is not null; }
    }

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
        try
        {
            return SampleLocked(frame, now, excluded, subtitle);
        }
        finally
        {
            // Tanı satırları kilidin dışında yazılır.
            List<string> pending;
            lock (gate)
            {
                pending = notes;
                notes = [];
            }
            foreach (var line in pending) OnLog?.Invoke(line);
        }
    }

    private bool SampleLocked(Frame frame, long now, IReadOnlyList<CropRegion> excluded, CropRegion? subtitle)
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
                    var (bright, dark, deviation, darkSum, darkSquares, mean) = Measure(frame, column, row, sampleMask);
                    ref var tile = ref tiles[index];
                    tile.Mean = mean;
                    (tile.DarkSum, tile.DarkSquares, tile.DarkCount) = (darkSum, darkSquares, dark);
                    var previous = lastMasks.AsSpan(index * Words, Words);
                    tile.Quiet = deviation < QuietDeviation;
                    if (!tile.HasLast || Distance(previous, sampleMask) > MaskChange) (tile.StableSince, tile.IsHud) = (now, false);
                    sampleMask.CopyTo(previous);
                    tile.HasLast = true;
                    if (tile.IsRejected && Distance(rejectedMasks.AsSpan(index * Words, Words), sampleMask) > MaskChange) tile.IsRejected = false;
                    // Menüde açık zeminde koyu yazı da (seçili menü satırı: açık degrade şerit, koyu "Map"; #1267). Seçili satır
                    // aday olmuyor, alan onu dışarıda bırakıyordu: "Map" seçim kayana dek çevrilmiyordu. Menü dışında açık sahne
                    // (gökyüzü, kar) yazı sanılmasın diye yalnız menüde (Mac ile aynı).
                    // Menüde kontur yazı da (#1268): GTA 6 haritasının tuş listesi ("2D VIEW", "ADD MARKER") ve görev satırı
                    // doğrudan açık, desenli haritanın üstünde beyaz harf + koyu kontur; yarı saydam kartın haritaya binen
                    // yarısı da yalnız orta tonda. Tuş listesinden yalnız hazır alana düşen "RECENTER" çevriliyor, kartın
                    // yazısı kartın ortasında kesiliyordu (Mac ile aynı).
                    var textLike = (bright is >= BrightMin and <= BrightMax && dark >= DarkMin)
                        || (menu && dark is >= BrightMin and <= BrightMax && bright >= DarkMin)
                        || (menu && Outlined(bright, dark));
                    anywhere[index] = textLike && now - tile.StableSince >= StableMs && !tile.IsRejected && !Excluded(column, row, excluded);
                    candidate[index] = anywhere[index] && (subtitle is not { } area || !Excluded(column, row, [area]));
                }
            var inMenu = IsMenu(Components(candidate), candidate, now);
            // Menüde altyazı alanındaki satırlar da menünün parçasıdır (alttaki seçenekler, tuş çubuğu).
            if (inMenu) candidate = anywhere;
            var all = Components(candidate);
            // Menü dışında yalnız arayüz kanıtı olan bileşen alan olur: düz panel zemini ve yerinde sabitlik. Oyun dünyasındaki
            // yazı (poster, plaka, tabela) dokulu zeminde ya da kamerayla kayarak durur, çevrilmez.
            List<(Cells Cells, List<int> Tiles)> components;
            if (inMenu) components = MenuColumns(all);
            else
            {
                // Bölgeleri kesişen bileşenler tek alan (tuş çubuğu iki alana bölünüp kesik okunuyordu); sütunda hizalı en az üç
                // etiket (tuş çubuğu) dokulu zeminde de arayüzdür.
                var (merged, aligned) = Merge([.. all.Where(item => item.Tiles.Count >= 2)]);
                Diagnose?.Invoke(string.Join(", ", merged.Select((item, index) =>
                    $"{Fmt(Region(item.Cells))}{(aligned[index] || RowsAligned(item.Tiles) ? " hizalı" : "")}{(IsInterface(item.Cells, item.Tiles, now) ? " panel" : "")}")));
                components = [.. merged.Where((item, index) => IsInterface(item.Cells, item.Tiles, now)
                                                             || ((aligned[index] || RowsAligned(item.Tiles)) && item.Tiles.All(tile => now - tiles[tile].StableSince >= UiStableMs)))];
            }
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

    /// <summary>
    /// Alan okundu ve yazısı tuş ipucu ya da görev/HUD yazısı (<see cref="RegionWatcher.Hud"/>): karoları menü için gereken
    /// <see cref="MenuComponents"/> bileşene sayılmaz (görüntü değişene dek). GTA 6 balık tutma sahnesinde (#1240) ipucu ve
    /// görev yazısı birlikte belirip menü sanılıyordu; alan çevrilmeye devam eder.
    /// </summary>
    public void MarkHud(string id)
    {
        lock (gate)
        {
            if (tracked.FirstOrDefault(item => item.Id == id) is not { } area) return;
            foreach (var index in area.Tiles) tiles[index].IsHud = true;
        }
    }

    /// <summary>
    /// Altyazı alanında konuşma satırı (konuşan adıyla) okundu: ekranda menü yoktur. Menü durumu hemen biter (menü alanları
    /// kalkar) ve <see cref="DialogueMs"/> boyunca yeniden açılmaz (#1240). Gerçek menüde (duraklatma, ayarlar, harita)
    /// altyazı alanında konuşma satırı olmaz.
    /// </summary>
    public void NoteDialogue(long now)
    {
        lock (gate)
        {
            // Menünün geçmiş listesi az önce okundu: konuşan adlı satır listenin satırıdır (kaydırırken tek satır okunabilir).
            if (listAt is { } listed && now - listed <= ListMs) return;
            dialogueAt = now;
            if (!menu) return;
            menu = false;
            menuFloor = now;
            menuAnchors = [];
            tracked.RemoveAll(item => item.Menu);
        }
    }

    /// <summary>Konuşma satırı okunduktan sonra bu kadar süre menü durumu açılmaz.</summary>
    public const int DialogueMs = 1500;
    private long? dialogueAt;

    /// <summary>Menü listesi okunduktan sonra bu kadar süre konuşan adlı satır menüyü bitirmez, menü de süresi dolmuş sayılmaz.</summary>
    public const int ListMs = 1500;
    private long? listAt;

    /// <summary>
    /// Altyazı alanında menünün geçmiş listesi okundu (Reading.IsHistoryList, Sinan Bey beta.100 3380-3383): ekranda menü
    /// vardır. Menü durumu liste durdukça sürer (<see cref="MenuLifeMs"/> dolmaz; listeye bakarken menü bitip satırlar dünya
    /// yazısı sayılıyor, kimi satır çevrilmiyordu) ve <see cref="ListMs"/> boyunca konuşan adlı satır
    /// (<see cref="NoteDialogue"/>) menüyü bitirmez (Mac/iPhone, Android ile aynı).
    /// </summary>
    public void NoteList(long now)
    {
        lock (gate) listAt = now;
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
            menuAnchors = [];
            menuFloor = null;
            dialogueAt = null;
            listAt = null;
            mapPanelSeen = null;
            notes = [];
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

    private static (int Bright, int Dark, double Deviation, long DarkSum, long DarkSquares, double Mean) Measure(Frame frame, int column, int row, ulong[] mask)
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
        return (bright, dark, Math.Sqrt(Math.Max(0, (double)squares / Points - mean * mean)), darkSum, darkSquares, mean);
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
    /// Tek bileşen içinde hizalı etiket sütunu: en az üç satırda karoların sağ (ya da sol) ucu aynı (±1 karo), öbür ucu
    /// dağınık (etiketler farklı uzunlukta: tuş çubuğu "RECENTER / 3D VIEW / ADD MARKER"). Dokulu zeminde de arayüzdür.
    /// </summary>
    private static bool RowsAligned(List<int> component)
    {
        var rows = component.GroupBy(index => index / Columns)
            .Select(row => (Left: row.Min(index => index % Columns), Right: row.Max(index => index % Columns))).ToList();
        if (rows.Count < 3) return false;
        int Spread(Func<(int Left, int Right), int> edge) => rows.Max(edge) - rows.Min(edge);
        return (Spread(row => row.Right) <= 1 && Spread(row => row.Left) >= 2)
            || (Spread(row => row.Left) <= 1 && Spread(row => row.Right) >= 2);
    }

    /// <summary>
    /// Bileşenleri birleştirir: (1) bölgeleri kesişenler (yatayda en çok iki, dikeyde hiç boş karo arası), (2) sağ ya da
    /// sol kenarı hizalı, aralarında en çok iki boş satır olan en az üç bileşen (sütundaki etiketler: tuş çubuğu). Birleşen
    /// alan ekranın %35'ini aşarsa birleşmez. <c>Aligned</c>: hizalı etiket sütunu (arayüz kanıtı).
    /// </summary>
    /// <summary>Aynı karo satırındaki bileşenler arasında en çok bu kadar sütun (iki uç arası) olunca birleşir.</summary>
    internal const int RowReach = 3;
    /// <summary>Aynı satırda iki yanı da en az iki karo genişse (sekme adları) bu kadar sütun aralığa kadar birleşir.</summary>
    internal const int WideRowReach = 4;

    internal static (List<(Cells Cells, List<int> Tiles)> Components, List<bool> Aligned) Merge(List<(Cells Cells, List<int> Tiles)> input)
    {
        var items = input.Select(item => (item.Cells, Tiles: new List<int>(item.Tiles), Aligned: false)).ToList();
        static Cells Join(Cells a, Cells b) => new(Math.Min(a.Left, b.Left), Math.Min(a.Top, b.Top), Math.Max(a.Right, b.Right), Math.Max(a.Bottom, b.Bottom));
        bool Small(Cells cells) => cells.Area <= MaxShare * Columns * Rows;
        for (var changed = true; changed;)
        {
            changed = false;
            for (var i = 0; i < items.Count && !changed; i++)
                for (var j = i + 1; j < items.Count && !changed; j++)
                {
                    var (a, b) = (items[i].Cells, items[j].Cells);
                    var horizontal = Math.Max(a.Left, b.Left) - Math.Min(a.Right, b.Right) - 1;
                    var vertical = Math.Max(a.Top, b.Top) - Math.Min(a.Bottom, b.Bottom) - 1;
                    // Aynı satırdaki bileşenler (menü şeridinin sekmeleri) iki boş karoya kadar birleşir: seçili sekme renkli
                    // olduğu için aday olmuyor, iki yanındaki alanlar onu ortadan kesiyordu ("MAP" → "M", #859).
                    var sameRow = Math.Max(a.Top, b.Top) <= Math.Min(a.Bottom, b.Bottom);
                    // İki yanı da en az iki karo genişse (sekme adı) üç boş karoya kadar; tek karoluk etiket (tekerlek menü) eskisi gibi.
                    var wide = a.Right - a.Left >= 1 && b.Right - b.Left >= 1;
                    if (horizontal > (sameRow ? (wide ? WideRowReach : RowReach) - 1 : 2) || vertical > 0 || !Small(Join(a, b))) continue;
                    items[i] = (Join(a, b), [.. items[i].Tiles, .. items[j].Tiles], items[i].Aligned || items[j].Aligned);
                    items.RemoveAt(j);
                    changed = true;
                }
        }
        // Hizalı etiket sütunları: sağ ya da sol kenarı aynı (±1 karo), üst üste dizili (aralarında en çok 2 boş satır).
        foreach (var right in new[] { true, false })
        {
            var ordered = items.Select((item, index) => (item, index)).OrderBy(pair => pair.item.Cells.Top).ToList();
            var used = new HashSet<int>();
            foreach (var (start, startIndex) in ordered)
            {
                if (used.Contains(startIndex)) continue;
                var stack = new List<int> { startIndex };
                var last = start.Cells;
                var edge = right ? start.Cells.Right : start.Cells.Left;
                foreach (var (next, nextIndex) in ordered)
                {
                    if (nextIndex == startIndex || used.Contains(nextIndex) || next.Cells.Top <= last.Bottom) continue;
                    if (next.Cells.Top - last.Bottom - 1 > 2) break;
                    if (Math.Abs((right ? next.Cells.Right : next.Cells.Left) - edge) > 1) continue;
                    stack.Add(nextIndex);
                    last = next.Cells;
                }
                if (stack.Count < 3) continue;
                var cells = stack.Select(index => items[index].Cells).Aggregate(Join);
                if (!Small(cells)) continue;
                foreach (var index in stack) used.Add(index);
            }
            if (used.Count == 0) continue;
            // Her yığın tek alan olur.
            var groups = new List<List<int>>();
            foreach (var index in used.OrderBy(index => items[index].Cells.Top))
            {
                var group = groups.FirstOrDefault(list =>
                {
                    var bottom = list.Max(member => items[member].Cells.Bottom);
                    var edge = right ? items[list[0]].Cells.Right : items[list[0]].Cells.Left;
                    return items[index].Cells.Top - bottom - 1 <= 2 && Math.Abs((right ? items[index].Cells.Right : items[index].Cells.Left) - edge) <= 1;
                });
                if (group is null) groups.Add([index]);
                else group.Add(index);
            }
            var next0 = items.Where((_, index) => !used.Contains(index)).ToList();
            foreach (var group in groups)
                next0.Add((group.Select(index => items[index].Cells).Aggregate(Join), [.. group.SelectMany(index => items[index].Tiles)], group.Count >= 3));
            items = next0;
        }
        return ([.. items.Select(item => (item.Cells, item.Tiles))], [.. items.Select(item => item.Aligned)]);
    }

    /// <summary>
    /// Menü durumu: en az üç ayrı bileşen var ve bileşenlerin dışındaki karoların çoğu düşük kenar enerjili (bulanık ya da
    /// karartılmış zemin). Menüye ilk girişte bileşenlerin en çok 300 ms arayla birlikte belirmiş olması da gerekir;
    /// menüde gezinirken (seçim çerçevesi değişince) durum, menüye girildiğindeki bileşenlerden biri (karolarının en az
    /// <see cref="KeepOverlap"/> kadarı) yerinde durdukça korunur (Mac/iPhone ve Android ile aynı). Eskiden yalnız "en az üç
    /// bileşen ve sakin zemin" yetiyordu: GTA 6 "Gone Fishing" (gece) menüden sonra görev yazısı, PS5 bildirimi ve HUD üç
    /// bileşen, karanlık zemin sakin sayıldı; menü durumu bitmedi, altyazı bütün oturum okunmadı.
    /// </summary>
    /// <summary>Menü durumu <see cref="MenuLifeMs"/> dolduğu için bitti (<see cref="IsMenu"/>); <see cref="Update"/> bir kez kullanır.</summary>
    private bool menuExpired;

    private bool IsMenu(List<(Cells Cells, List<int> Tiles)> all, bool[] candidate, long now)
    {
        // Konuşma satırı az önce okundu: menü yok (#1240).
        if (dialogueAt is { } spoken && now - spoken <= DialogueMs)
        {
            NotePanel(null, 0);
            return false;
        }
        // Tuş ipucu ve görev/HUD yazısı (MarkHud) menü bileşeni sayılmaz; zeminin sakinliğinde yazı karosu olarak kalır.
        var components = all.Where(item => !item.Tiles.All(index => tiles[index].IsHud)).ToList();
        var inside = all.SelectMany(item => item.Tiles).ToHashSet();
        var outside = Enumerable.Range(0, tiles.Length).Where(index => !inside.Contains(index)).ToList();
        var quietShare = outside.Count == 0 ? 0 : (double)outside.Count(index => tiles[index].Quiet) / outside.Count;
        // Harita düzeni (#1365): keskin harita sakin zemin ve üç bileşen şartını karşılamıyor; düzen tanınınca eşikler
        // gevşer. Düzen yoksa eşikler eskisi gibi.
        var panel = components.Count >= MapComponents && quietShare >= MapQuietShare
            ? MapPanel(index => candidate[index] || inside.Contains(index), now) : null;
        NotePanel(panel, quietShare);
        if (components.Count < (panel is null ? MenuComponents : MapComponents)
            || quietShare < (panel is null ? MenuQuietShare : MapQuietShare)) return false;
        if (menu && components.Any(item => item.Tiles.Count(menuAnchors.Contains) >= KeepOverlap * item.Tiles.Count))
        {
            // Harita düzeni yerinde: oyuncu haritaya hareketsiz baksa da menü sürer (MenuLifeMs dolmaz); süresi dolunca
            // liste, görev kartı ve tuş çubuğu menü dışı alanlara bölünüyordu (#1365).
            if (panel is not null) return true;
            // Menüde bir şey değişmeden (gezinme, seçim) MenuLifeMs geçti: menü sayılmaz, altyazı yeniden gösterilir. Aynı
            // yazılar yeniden menü sayılmaz; menü ancak sonradan beliren yazılarla yeniden açılır (menuFloor).
            var activity = menuAnchors.Count == 0 ? menuEnteredAt : menuAnchors.Max(index => tiles[index].StableSince);
            // Menünün geçmiş listesi altyazı alanında okunuyor (NoteList): menü yerinde, süresi dolmaz.
            if (listAt is { } listed && now - listed <= ListMs) activity = Math.Max(activity, listed);
            if (now - Math.Max(activity, menuEnteredAt) <= MenuLifeMs) return true;
            menuFloor = now;
            menuExpired = true;
            return false;
        }
        var appeared = components.Select(item => item.Tiles.Max(index => tiles[index].StableSince)).ToList();
        if (appeared.Max() - appeared.Min() > MenuTogetherMs) return false;
        if (menuFloor is { } floor && appeared.Any(time => time <= floor)) return false;
        if (!menu) menuEnteredAt = now;
        menuAnchors = components.SelectMany(item => item.Tiles).ToHashSet();
        return true;
    }

    /// <summary>
    /// Harita düzeni (#1365, GTA 6 Harita › STORY): ekranın bir yanında tam boy koyu panel (görev listesi), yanında geniş,
    /// açık ve keskin harita. Harita ayrıntılı olduğu için bileşen dışı karoların yalnız ~%55'i sakin
    /// (<see cref="MenuQuietShare"/> %60'ın altında); tuş çubuğu menü dışında aday olmadığından çoğu karede yalnız iki
    /// bileşen (liste, görev kartı) var. Ekran menü sayılmıyor, liste, kart ve tuş çubuğu ayrı alanlara (hazır
    /// Help/Messages alanları dahil) bölünüyordu. Düzen tanınınca menü için <see cref="MapComponents"/> bileşen ve
    /// <see cref="MapQuietShare"/> sakin zemin yeter. Oyun sahnesi düzeni karşılamaz: panel ekranın tam boyunda ve koyu,
    /// kenarı keskin; yanındaki alanın büyük bölümü ondan belirgin açık ve yerinde sabit; panelde en az üç karo satırlık
    /// liste var. Mac/iPhone ve Android aynı.
    /// </summary>
    public const double MapQuietShare = 0.4;
    public const int MapComponents = 2;
    /// <summary>Panelin genişliği (karo): ekranın ~%15'i ile ~%45'i arası.</summary>
    internal const int MapPanelMinColumns = 5, MapPanelMaxColumns = 14;
    /// <summary>Panel zemini: karo ortalaması bundan koyu.</summary>
    internal const double MapPanelDark = 90;
    /// <summary>Harita karoları panelin ortanca tonundan en az bu kadar açık.</summary>
    internal const double MapContrast = 35;
    /// <summary>Panel dışındaki yazısız karoların en az bu kadarı harita tonunda ve yerinde sabit.</summary>
    internal const double MapShare = 0.7;
    /// <summary>Panelin karo satırlarının en az bu kadarı panel (koyu ya da yazı): panel tam boy.</summary>
    internal const double MapRows = 0.9;

    /// <summary>
    /// Harita düzeninin paneli: yanı (sol: true) ve genişliği (karo). Yoksa null. <paramref name="text"/>: yazı karosu (aday
    /// ya da bileşen). Menüde aday kuralı genişleyince (kontur yazı) haritanın yazıları da aday olur, liste bileşeni onlarla
    /// birleşip büyüyebilir; düzen bileşenlere değil karolara bakar, menü gidip gelmez.
    /// </summary>
    private (bool Left, int Width)? MapPanel(Func<int, bool> text, long now) =>
        MapPanel(text, index => (tiles[index].Mean, now - tiles[index].StableSince >= UiStableMs));

    /// <summary>
    /// <paramref name="tile"/>: karonun ortalama parlaklığı ve yerinde sabit olup olmadığı (testler sentetik karolarla çağırır).
    /// </summary>
    internal static (bool Left, int Width)? MapPanel(Func<int, bool> inside, Func<int, (double Mean, bool Steady)> tile)
    {
        foreach (var left in new[] { true, false })
        {
            // k: panelin dış kenarından içeri doğru sütun sırası.
            int Column(int k) => left ? k : Columns - 1 - k;
            for (var width = MapPanelMinColumns; width <= MapPanelMaxColumns; width++)
            {
                var ground = new List<double>();
                var panelRows = 0;
                for (var row = 0; row < Rows; row++)
                {
                    var own = 0;
                    for (var k = 0; k < width; k++)
                    {
                        var index = row * Columns + Column(k);
                        if (inside(index)) { own++; continue; }
                        var mean = tile(index).Mean;
                        if (mean < MapPanelDark) own++;
                        ground.Add(mean);
                    }
                    if (own >= 0.6 * width) panelRows++;
                }
                if (panelRows < MapRows * Rows || ground.Count == 0
                    || ground.Count(value => value < MapPanelDark) < 0.85 * ground.Count) continue;
                ground.Sort();
                var light = ground[ground.Count / 2] + MapContrast;
                // Panelin kenarı: içteki son sütun panel, dıştaki ilk sütun harita.
                int edgeIn = 0, edgeOut = 0;
                for (var row = 0; row < Rows; row++)
                {
                    int a = row * Columns + Column(width - 1), b = row * Columns + Column(width);
                    if (inside(a) || tile(a).Mean < MapPanelDark) edgeIn++;
                    if (inside(b) || tile(b).Mean >= light) edgeOut++;
                }
                if (edgeIn < 0.75 * Rows || edgeOut < 0.75 * Rows) continue;
                // Harita: panel dışındaki yazısız karoların çoğu açık ve yerinde sabit (oyun sahnesinde kamera oynar).
                int mapTiles = 0, lit = 0, steady = 0;
                for (var row = 0; row < Rows; row++)
                    for (var k = width; k < Columns; k++)
                    {
                        var index = row * Columns + Column(k);
                        if (inside(index)) continue;
                        mapTiles++;
                        var t = tile(index);
                        if (t.Mean >= light) lit++;
                        if (t.Steady) steady++;
                    }
                if (mapTiles == 0 || lit < MapShare * mapTiles || steady < MapShare * mapTiles) continue;
                // Panelde liste: en az üç karo satırında panelin dış yarısında yazı.
                var list = 0;
                for (var row = 0; row < Rows; row++)
                    for (var k = 0; k < Math.Max(1, width / 2); k++)
                        if (inside(row * Columns + Column(k))) { list++; break; }
                if (list >= 3) return (left, width);
            }
        }
        return null;
    }

    /// <summary>Harita düzeninin bulunuşu ve bitişi günlüğe bir kez yazılır (<see cref="OnLog"/>; #1365 tanısı).</summary>
    private void NotePanel((bool Left, int Width)? panel, double quietShare)
    {
        var seen = panel is { } p ? $"{(p.Left ? "sol" : "sağ")} {p.Width}" : null;
        if (seen == mapPanelSeen) return;
        var ended = mapPanelSeen is not null;
        mapPanelSeen = seen;
        if (panel is { } found)
            notes.Add($"ekran menüsü: harita düzeni bulundu ({(found.Left ? "sol" : "sağ")} panel {found.Width} karo, "
                      + $"sakin zemin %{(int)Math.Round(quietShare * 100, MidpointRounding.AwayFromZero)})");
        else if (ended)
            notes.Add("ekran menüsü: harita düzeni bitti");
    }

    /// <summary>
    /// Menüde aynı sütunda (sol kenarları en çok <see cref="ColumnSlack"/> karo farklı; iki tek satırlık bileşende aynı karo)
    /// alt alta duran bileşenler arada bir boş karo satırı olsa da birleşir: dikey menünün satırları tek alanda okunur,
    /// Türkçeleri tek grupta aynı yana yazılır. Satır aralığı karo boyuna denk gelince bir satır ("Settings") ayrı alana düşüp
    /// kendi başına yerleşiyordu (#1339). Mac ve Android aynı.
    /// </summary>
    internal const int ColumnSlack = 1;

    internal static List<(Cells Cells, List<int> Tiles)> MenuColumns(List<(Cells Cells, List<int> Tiles)> input)
    {
        var items = input.Select(item => (item.Cells, Tiles: new List<int>(item.Tiles))).ToList();
        for (var changed = true; changed;)
        {
            changed = false;
            for (var i = 0; i < items.Count && !changed; i++)
                for (var j = i + 1; j < items.Count && !changed; j++)
                {
                    var (a, b) = (items[i].Cells, items[j].Cells);
                    // Tek satırlık iki bileşende (ortalı başlık ve alt başlığı) sol kenar aynı karoda olmalı.
                    var slack = a.Bottom > a.Top || b.Bottom > b.Top ? ColumnSlack : 0;
                    if (Math.Abs(a.Left - b.Left) > slack || a.Top > b.Bottom + 2 || b.Top > a.Bottom + 2) continue;
                    var union = new Cells(Math.Min(a.Left, b.Left), Math.Min(a.Top, b.Top), Math.Max(a.Right, b.Right), Math.Max(a.Bottom, b.Bottom));
                    if (union.Area > MaxShare * Columns * Rows) continue;
                    items[i] = (union, [.. items[i].Tiles, .. items[j].Tiles]);
                    items.RemoveAt(j);
                    changed = true;
                }
        }
        return [.. items.Select(item => (item.Cells, item.Tiles))];
    }

    private void Update(List<(Cells Cells, List<int> Tiles)> components, bool[] candidate, long now, bool inMenu)
    {
        var closed = menu && !inMenu;
        menu = inMenu;
        // Menü kapandı: karoları artık aday olmayan menü alanları hemen kalkar (700 ms beklemez). Karoları hâlâ yerinde
        // duran alan (seçim gezinirken menü durumu bir örnek düşse de) kalır; kutusu yanıp sönmez.
        // Süre dolup biten menüde yazılar yerinde dursa da bütün menü alanları kalkar: oyun menüden çıkınca çevirileri TV'de
        // kalıyordu (#1198). RegionWatcher kalkan alana boş çeviri gönderir.
        if (closed) tracked.RemoveAll(item => item.Menu && (menuExpired || !item.Tiles.Any(index => candidate[index])));
        menuExpired = false;
        var matched = new HashSet<Tracked>();
        foreach (var (cells, list) in components)
        {
            var existing = tracked.Where(item => !matched.Contains(item)).FirstOrDefault(item => item.Cells.Overlap(cells) >= KeepOverlap);
            if (existing is null)
            {
                if (tracked.Count >= (inMenu ? MenuMaxAreas : MaxAreas)) continue;
                existing = new Tracked(ScreenTextAreas.Prefix + ++counter, cells, list, now);
                tracked.Add(existing);
            }
            // Bölge en az bir karo kayınca güncellenir (Cells karo biriminde olduğundan her fark bir karodur).
            existing.Cells = cells;
            existing.Tiles = list;
            existing.Seen = now;
            existing.Menu = inMenu;
            matched.Add(existing);
        }
        // Bileşenlerden birinin içinde kalan eşleşmemiş alan (birleşen menü sütununun eski parçası) ikinci kez okunmaz.
        tracked.RemoveAll(item => !matched.Contains(item) && components.Any(component => component.Cells.Overlap(item.Cells) >= 1));
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
/// <summary>Kendiliğinden bulunan ekran yazısı alanlarının kimliği ("auto-1", "auto-2" …).</summary>
public static class ScreenTextAreas
{
    public const string Prefix = "auto-";
    public static bool IsAuto(string? id) => id is not null && id.StartsWith(Prefix, StringComparison.Ordinal);
}

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

    /// <summary>
    /// Menüde güveni düşük okuma (#1365): yazı tanıma satırdan en çok <see cref="UnsureConfidence"/> kadar emin ve satır
    /// arayüz sözlüğünde yok. Bozuk okumalar ("scarch rol the onuin Ape", "AUD MARNER SET DESTINATION") paketle eşleşmeyip
    /// çeviri motoruna gidiyor, saçma çeviriler çıkıyordu ("Onur ape'de arama yap"). Kayıtlı Vision okumalarında 0,5 güvenli
    /// satırların çoğu bozuk ("Earpc", "NAOE", "Stetahus"); sözlükteki etiket ("EXIT") güvensiz de olsa çevrilir.
    /// </summary>
    public const double UnsureConfidence = 0.5;

    public static bool IsUnsure(TextLine line) =>
        line.Confidence is { } confidence && confidence <= UnsureConfidence
        && UiCommands.TranslateLabelLoosely(IconText.Plain(line.Text).Trim(' ', '\t')) is null;

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
