// SPDX-License-Identifier: AGPL-3.0-only
namespace CouchSubs.Core;

/// <summary>
/// Ekran kilidi (Sinan Bey: "stabil olsun artık"). Bütün ekran okuması (250–500 ms'de bir) her turda her bloğun kutusuna
/// yeniden karar veriyordu: kutular titriyor, yer değiştiriyor, kalkıp geliyor, yazılar birbirinin yerine geçiyordu. Ekran
/// yazısı katmanı (otomatik ekran yazısı; altyazı, görev kutusu <see cref="MissionLine.AreaId"/>, kenar bildirimi ve telefon
/// hariç) artık kilitlenir:
/// <list type="bullet">
/// <item>Kilit: blokların kümesi art arda <see cref="SteadyPasses"/> turda aynı (aynı yazılar aşağı yukarı aynı yerlerde)
/// okununca o ekranın düzeni kilitlenir. Her blok bir yuvadır; kutusu, yeri, boyu ve çevirisi sabittir.</item>
/// <item>Küçük değişiklik (imleç gezdi, sayaç/saat ilerledi, bir bloğun yazısı biraz değişti): kutu taşınmaz, eklenmez,
/// kalkmaz. Yalnız var olan kutunun yazısı güncellenir, o da yuvanın okuması <see cref="SteadyPasses"/> tur aynı kaldıysa.</item>
/// <item>Açılma: blokların <see cref="ChangeShare"/> kadarı gitti/yeni geldi/yerinde başka yazı oldu, ya da düzen tutmuyor;
/// art arda <see cref="ChangePasses"/> turda. Ekran yazısı <see cref="EmptyMs"/>'ten uzun kalkınca da açılır, katman
/// temizlenir.</item>
/// <item>Ekran önbelleği: kilitli ekranın yuvaları yazılarının sadeleştirilmiş kümesiyle saklanır; aynı ekrana dönülünce
/// aynı çeviriler aynı kutularda hemen çizilir.</item>
/// <item>Her kilit ve açılış günlüğe nedeni ve blok sayısıyla bir satır yazılır.</item>
/// <item>Hazır alanlar da (#1391, <c>preset-*</c>: GTA 6 sol üstteki yardım ve sağdaki mesaj alanı) kilidin altında: harita
/// ve görev listesi menü durumu bir an kapanınca hazır alandan, sonra yine otomatik alandan okunuyor; hazır alanın kutuları
/// kilitsiz kalıp her turda yeniden karar veriliyor, otomatik alanın kutularının üstüne biniyordu (beta.108).</item>
/// <item>Yollar arası çakışma (#1391): aynı yeri iki yol (görev kutusu, otomatik ekran yazısı, hazır alan) birden çizerse
/// sabit öncelikle (<see cref="Rank"/>) yalnız biri kalır: görev kutusu &gt; otomatik ekran yazısı &gt; hazır alan. Kilide
/// giren bloklar da aynı öncelikle birleşir (<see cref="Merge"/>).</item>
/// </list>
/// Yalnız gönderilenleri süzer. Mac/iPhone (ScreenLock.swift) ve Android (ScreenLock.kt) aynı kurallar. İş parçacığına
/// dayanıklıdır (her çağrı kendi kilidinde).
/// </summary>
internal sealed class ScreenLock
{
    /// <summary>Kilidin altındaki alan: otomatik ekran yazısı; görev kutusu ve kenar bildirimi kendi yuvasında kalır.</summary>
    internal static bool Covers(string id) =>
        (ScreenTextAreas.IsAuto(id) || GameAreaPresets.IsPreset(id)) && id != MissionLine.AreaId && !ScreenNotices.IsNotice(id);

    /// <summary>Kilidin altındaki alan; <see cref="Routes"/> kapalıyken (beta.108 davranışı, yalnız denemelerin önce/sonra
    /// sayısı) hazır alan kilide girmez.</summary>
    internal bool CoversArea(string id) => Covers(id) && (Routes || !GameAreaPresets.IsPreset(id));

    /// <summary>Hazır alanlar kilide girer ve yollar arası çakışma çözülür (#1391). false yalnız denemelerde (beta.108).</summary>
    internal bool Routes { get; set; } = true;

    /// <summary>Yolun önceliği (küçük olan kalır): görev kutusu, otomatik ekran yazısı, hazır alan, diğer.</summary>
    internal static int Rank(string id)
    {
        if (id == MissionLine.AreaId) return 0;
        if (ScreenTextAreas.IsAuto(id)) return 1;
        if (GameAreaPresets.IsPreset(id)) return 2;
        return 3;
    }

    /// <summary>Kilidin dışında kalıp yine de üstüne çizilmeyecek yol (görev kutusu).</summary>
    internal static bool Blocks(string id) => id == MissionLine.AreaId;

    /// <summary>Başka yolun kutusuyla (küçüğünün alanına oranla) en az bu kadar örtüşen kutu çakışır.</summary>
    internal const double RouteOverlap = 0.1;

    /// <summary>Öğenin TV'de kapladığı yerler: özgün yazının kutusu, örtüsü, yanına yazılan ya da ikiz kutusu.</summary>
    internal static List<TextBox> Footprint(ScreenTranslation.Item item)
    {
        var result = new List<TextBox> { item.Box };
        if (item.Paint is { } paint)
        {
            result.Add(paint.Cover);
            if (paint.Spot is { } spot) result.Add(spot);
            if (paint.Twin is { } twin) result.Add(twin);
        }
        return result;
    }

    internal static List<List<TextBox>> Footprints(Payload payload)
    {
        if (payload.Blocks is { Count: > 0 } items) return [.. items.Select(Footprint)];
        return payload.Box is { } box ? [[box]] : [];
    }

    internal static bool Clash(IReadOnlyList<TextBox> a, IReadOnlyList<TextBox> b) =>
        a.Any(x => b.Any(y => Overlap(x, y) >= RouteOverlap));

    private static IOrderedEnumerable<string> ByRank(IEnumerable<string> ids) =>
        ids.OrderBy(Rank).ThenBy(id => id, StringComparer.Ordinal);

    /// <summary>Turun blokları alan alan: yüksek öncelikli yolun bloğuyla aynı yerdeki alçak yol bloğu atılır (aynı satırı iki
    /// yol okudu). Aynı öncelikteki alanlar olduğu gibi kalır.</summary>
    internal List<Block> Merge(IReadOnlyList<(string Id, IReadOnlyList<Block> Blocks)> areas)
    {
        if (!Routes) return [.. areas.SelectMany(a => a.Blocks)];
        var kept = new List<(int Rank, TextBox Box)>();
        var result = new List<Block>();
        foreach (var area in areas.OrderBy(a => Rank(a.Id)).ThenBy(a => a.Id, StringComparer.Ordinal))
        {
            var rank = Rank(area.Id);
            var fresh = area.Blocks.Where(b => !kept.Any(k => k.Rank < rank && Overlap(k.Box, b.Box) >= RouteOverlap)).ToList();
            kept.AddRange(fresh.Select(b => (rank, b.Box)));
            result.AddRange(fresh.Select(b => b with { Route = rank }));
        }
        return result;
    }

    /// <summary>Okunan blok; <c>Route</c>: bloğu okuyan yolun önceliği (<see cref="Rank"/>; <see cref="Merge"/> yazar).</summary>
    internal readonly record struct Block(string Key, TextBox Box, int Route = 1);

    internal sealed record Payload(string Text, TextBox? Box, double? LineHeight, IReadOnlyList<IconPlacement>? Icons,
                                   IReadOnlyList<ScreenTranslation.Item>? Blocks)
    {
        public bool Same(Payload? other) =>
            other is not null && Text == other.Text && Box == other.Box && LineHeight == other.LineHeight
            && ReferenceEquals(Icons, other.Icons)
            && (Blocks is null ? other.Blocks is null : other.Blocks is not null && Blocks.SequenceEqual(other.Blocks));
    }

    /// <summary>Gönderilecek alan; <c>Payload</c> null ise kutu kalkar. <c>Forget</c>: izleyici alanın durumunu unutmalı.</summary>
    internal sealed record Send(string Id, Payload? Payload, bool Forget = false);

    internal const int SteadyPasses = 2;
    internal const double ChangeShare = 0.35;
    internal const int ChangePasses = 2;
    internal const long EmptyMs = 1000;
    internal const double SamePlace = 0.5;
    internal const int CacheLimit = 16;
    /// <summary>Yeri okunmayan yuva (#1391: GTA 6 haritasında menü durumu bir an kapanınca menü alanları kalkıyor, hazır alan
    /// okuyordu) bu kadar süre ekran değişikliğine sayılmaz; daha uzun sürerse gitmiş sayılır.</summary>
    internal const long UnreadMs = 1500;

    internal sealed class Slot
    {
        public required string Key { get; init; }
        public required TextBox Box { get; init; }
        /// <summary>Yuvayı okuyan yolun önceliği: daha alçak yol (hazır alan) bu yuvayı doldurmaz, yazısını değiştirmez (#1391:
        /// hazır alanın kesik okuması "Keep an eye or" görev listesinin satırına yazılıyordu).</summary>
        public int Route { get; init; } = 1;
        public bool Observed { get; init; } = true;
        public string? Id { get; set; }
        public ScreenTranslation.Item? Item { get; set; }
        public required string Seen { get; set; }
        public int SeenPasses { get; set; }
        public ScreenTranslation.Item? Pending { get; set; }
        /// <summary>Yuvanın yeri bu turdan beri okunan hiçbir alanın içinde değil (<see cref="UnreadMs"/>).</summary>
        public long? UnreadSince { get; set; }

        public Slot Copy() => new()
        {
            Key = Key, Box = Box, Route = Route, Observed = Observed, Id = Id, Item = Item, Seen = Seen, SeenPasses = SeenPasses,
            Pending = Pending, UnreadSince = UnreadSince,
        };
    }

    private sealed record Saved(List<Slot> Slots, Dictionary<string, Payload> Frames);

    private readonly object gate = new();
    private bool locked;
    private List<Slot> slots = [];
    private List<Block>? previous;
    private long? emptySince;
    private int changing;
    private List<Block>? changingTo;
    private string lockKey = "";
    private readonly Dictionary<string, Payload> intended = [];
    private Dictionary<string, Payload> displayed = [];
    private Dictionary<string, Payload> frames = [];
    private readonly Dictionary<string, Saved> cache = [];
    private readonly List<string> cacheOrder = [];
    /// <summary>Kilidin dışındaki öncelikli yolların (görev kutusu) TV'de duran kutuları (<see cref="Blocker"/>).</summary>
    private readonly Dictionary<string, Payload> blockers = [];
    /// <summary>Tanı (#1391): son yazılan yol çakışması ve bir an okunmayan yuva sayısı (değişince bir satır).</summary>
    private string routeLogged = "";
    private int unreadLogged;
    /// <summary>Son çözümde öncelikli yolun altında kalıp çizilmeyen öğe sayısı, alan alan.</summary>
    private readonly Dictionary<string, int> hidden = [];
    public Action<string>? Log { get; set; }
    public int Locks { get; private set; }
    public int Unlocks { get; private set; }
    public int CacheHits { get; private set; }

    public bool Locked { get { lock (gate) return locked; } }
    public bool Holds { get { lock (gate) return locked || displayed.Count > 0; } }
    public IReadOnlyCollection<string> DisplayedIds { get { lock (gate) return [.. displayed.Keys]; } }
    internal Payload? Displayed(string id) { lock (gate) return displayed.GetValueOrDefault(id); }

    internal static string Key(string text) => RegionWatcher.TextKey([IconText.Plain(text)]);

    internal static bool Similar(string a, string b) => a == b || TextMatch.IsSimilar(a, b, 0.75);

    /// <summary>Küçüğünün alanına oranla örtüşme.</summary>
    internal static double Overlap(TextBox a, TextBox b)
    {
        var w = Math.Min(a.Right, b.Right) - Math.Max(a.Left, b.Left);
        var h = Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top);
        if (w <= 0 || h <= 0) return 0;
        var small = Math.Min((a.Right - a.Left) * (a.Bottom - a.Top), (b.Right - b.Left) * (b.Bottom - b.Top));
        return small > 0 ? w * h / small : 0;
    }

    internal sealed record Diff(int Gone, int Fresh, int Changed, int Moved, int Total)
    {
        public double Share => Total == 0 ? 0 : (double)(Gone + Fresh + Changed) / Total;
    }

    /// <summary>Biri ötekinin parçası (#1391: menü durumu bir an kapanınca aynı paragraf satır satır okunuyor). En az 4 harf.</summary>
    internal static bool Part(string a, string b)
    {
        var (shorter, longer) = a.Length <= b.Length ? (a, b) : (b, a);
        return shorter.Length >= 4 && longer.Contains(shorter, StringComparison.Ordinal);
    }

    internal static Diff Compare(IReadOnlyList<Block> old, IReadOnlyList<Block> fresh)
    {
        var used = new HashSet<int>();
        int gone = 0, changed = 0, moved = 0;
        foreach (var block in old)
        {
            int? best = null;
            var bestOverlap = SamePlace;
            for (var j = 0; j < fresh.Count; j++)
            {
                if (used.Contains(j)) continue;
                var o = Overlap(block.Box, fresh[j].Box);
                if (o >= bestOverlap) { best = j; bestOverlap = o; }
            }
            if (best is { } b)
            {
                used.Add(b);
                if (!Similar(block.Key, fresh[b].Key) && !Part(block.Key, fresh[b].Key)) changed++;
            }
            else
            {
                gone++;
                if (fresh.Any(other => Similar(other.Key, block.Key))) moved++;
            }
        }
        // Eski bir bloğun yerinde onun parçası olan blok yeni sayılmaz (aynı yazı başka satırlara bölündü).
        var added = Enumerable.Range(0, fresh.Count)
            .Count(j => !used.Contains(j) && !old.Any(o => Overlap(o.Box, fresh[j].Box) >= SamePlace && Part(o.Key, fresh[j].Key)));
        return new Diff(gone, added, changed, moved, Math.Max(old.Count, fresh.Count));
    }

    /// <summary>Ekranın önbellek anahtarı: yazıların sadeleştirilmiş kümesi.</summary>
    internal static string ScreenKey(IEnumerable<Block> blocks) =>
        string.Join('\u001F', blocks.Select(b => b.Key).Where(k => k.Length > 0).Distinct().OrderBy(k => k, StringComparer.Ordinal));

    /// <summary>İzleyici bir alanı göndermek istiyor (<paramref name="payload"/> null: kutu kalkar).</summary>
    internal List<Send> Offer(string id, Payload? payload)
    {
        lock (gate)
        {
            if (payload is null) intended.Remove(id); else intended[id] = payload;
            if (!locked)
            {
                // Kilit yokken gönderi geçer; yollar arası çakışmada öncelikli yol kalır (Resolved).
                if (Routes) return Publish();
                if (payload is null) displayed.Remove(id); else displayed[id] = payload;
                return [new Send(id, payload)];
            }
            // Kilitliyken kutu kalkmaz; yeni kutu eklenmez; bloksuz gönderi kilidin dışında kalır.
            if (payload?.Blocks is not { Count: > 0 } items) return [];
            if (!frames.ContainsKey(id)) frames[id] = new Payload("", payload.Box, payload.LineHeight, payload.Icons, null);
            var touched = new SortedSet<string>(StringComparer.Ordinal);
            foreach (var item in items)
            {
                if (SlotFor(item.Box, Routes ? Rank(id) : 0) is not { } slot) continue;
                if (slot.Item is null)
                {
                    slot.Item = item;
                    slot.Id = id;
                    touched.Add(id);
                    continue;
                }
                if (slot.Item.Translation == item.Translation && SameIcons(slot.Item.Icons, item.Icons))
                {
                    // Yazı aynı; seçim gezdiyse (#1267) yalnız renkler güncellenir, kutu yerinde kalır.
                    slot.Pending = null;
                    if (Recoloured(slot.Item, item) is { } fresh)
                    {
                        slot.Item = fresh;
                        touched.Add(slot.Id ?? id);
                    }
                    continue;
                }
                if (Steady(slot, item))
                {
                    Apply(item, slot);
                    touched.Add(slot.Id ?? id);
                }
                else slot.Pending = item;
            }
            return Routes ? RenderAll(touched) : [.. touched.Select(Render).OfType<Send>()];
        }
    }

    /// <summary>Alanın yazısı kesin gitti (hazır alanın arayüz kutusu PanelMissTurns tur bulunamadı): kilitliyken de kutuları
    /// kalkar, yuvaları düzenden çıkar.</summary>
    internal List<Send> Withdraw(string id)
    {
        lock (gate)
        {
            if (!Routes) return Offer(id, null);
            intended.Remove(id);
            if (!locked) return Publish();
            slots.RemoveAll(s => s.Id == id);
            frames.Remove(id);
            var sends = new List<Send>();
            if (displayed.Remove(id)) sends.Add(new Send(id, null));
            // Kilitli ekranın bütün yazısı bu alanındı: kilit açılır.
            if (!slots.Any(s => s.Observed)) sends.AddRange(Unlock($"{id} alanının yazısı gitti", clear: false, [], settled: false));
            else sends.AddRange(RenderAll(new SortedSet<string>(StringComparer.Ordinal)));
            return sends;
        }
    }

    /// <summary>Kilidin dışındaki öncelikli yol (görev kutusu) TV'ye gitti ya da kalktı: onunla çakışan ekran yazısı
    /// çizilmez, kalkınca yeniden çizilir (öncelikli yolun kendi gönderisi izleyicide).</summary>
    internal List<Send> Blocker(string id, Payload? payload)
    {
        lock (gate)
        {
            if (!Routes) return [];
            var current = blockers.GetValueOrDefault(id);
            if (payload is null ? current is null : payload.Same(current)) return [];
            if (payload is null) blockers.Remove(id); else blockers[id] = payload;
            return locked ? RenderAll(new SortedSet<string>(StringComparer.Ordinal)) : Publish();
        }
    }

    private static bool SameIcons(IReadOnlyList<IconPlacement>? a, IReadOnlyList<IconPlacement>? b) =>
        (a?.Count ?? 0) == (b?.Count ?? 0) && (a is null || b is null || a.SequenceEqual(b));

    /// <summary>Turun sonu: bu turda okunan bütün ekran yazısı blokları. Kilitlenir, açılır ya da bekleyen yazı güncellenir.
    /// <paramref name="read"/>: bu turda yazı okunan alanların yeri ve yolu (Block.Box, Block.Route; null: bütün ekran okundu).
    /// Yuvanın yeri kendi yolundan ya da daha öncelikli yoldan okunmadıysa yuva <see cref="UnreadMs"/> dolana dek ekran
    /// değişikliğine sayılmaz.</summary>
    internal List<Send> Observe(IReadOnlyList<Block> blocks, long now, IReadOnlyList<Block>? read = null)
    {
        lock (gate)
        {
            if (blocks.Count == 0)
            {
                previous = null;
                var since = emptySince ?? now;
                emptySince = since;
                if (!locked || now - since <= EmptyMs) return [];
                return Unlock($"ekran yazısı {EmptyMs / 1000} sn'den uzun yok, katman temizlendi", clear: true, [], settled: false);
            }
            emptySince = null;
            if (locked)
            {
                foreach (var slot in slots.Where(s => s.Observed))
                {
                    Block? seen = null;
                    var best = 0.0;
                    foreach (var block in blocks)
                    {
                        if (block.Route > slot.Route) continue;
                        var o = Overlap(block.Box, slot.Box);
                        if (o >= SamePlace && o > best) { seen = block; best = o; }
                    }
                    if (seen is not { } r)
                    {
                        slot.SeenPasses = 0;
                        continue;
                    }
                    if (r.Key == slot.Seen) slot.SeenPasses++;
                    else
                    {
                        slot.Seen = r.Key;
                        slot.SeenPasses = 1;
                    }
                }
                foreach (var slot in slots)
                {
                    var unread = read is not null && !read.Any(area => area.Route <= slot.Route && Overlap(slot.Box, area.Box) >= SamePlace);
                    slot.UnreadSince = unread ? slot.UnreadSince ?? now : null;
                }
                var layout = slots.Where(s => s.Observed && (s.UnreadSince is not { } since || now - since > UnreadMs))
                    .Select(s => new Block(s.Key, s.Box)).ToList();
                // Kilitli ekranı kuran yoldan alçak yolun okuması (hazır alanın menü satırından kestiği parça, menü dışı okunan
                // harita tuşu) ekran değişikliğine kanıt sayılmaz (#1391); yalnız kendi yolunun yuvasının üstündeki okuması
                // sayılır. Kuran yol okumazsa yuvaları UnreadMs sonra gitmiş sayılır.
                var top = slots.Where(s => s.Observed).Select(s => s.Route).DefaultIfEmpty(int.MaxValue).Min();
                var evidence = Routes
                    ? blocks.Where(b => b.Route <= top
                        || slots.Any(s => s.Observed && s.Route == b.Route && Overlap(s.Box, b.Box) >= SamePlace)).ToList()
                    : blocks;
                var held = Routes ? slots.Count(s => s.Observed && s.UnreadSince is { } since && now - since <= UnreadMs) : 0;
                if (held != unreadLogged)
                {
                    if (held > 0) Log?.Invoke($"ekran yazısı yolları: {held} blok bir an okunmadı (alan önerilmedi ya da boş okundu), kilit korunuyor");
                    unreadLogged = held;
                }
                var diff = Compare(layout, evidence);
                if (diff.Share >= ChangeShare)
                {
                    // Ekran değişiyor: bekleyen yazı uygulanmaz; değişiklik sürerse kilit açılır.
                    changing++;
                    var settled = changingTo is { } before && before.Count == blocks.Count && Compare(before, blocks).Share == 0;
                    changingTo = [.. blocks];
                    if (changing < ChangePasses) return [];
                    var reason = diff.Moved > 0 && diff.Moved == diff.Gone && diff.Fresh == diff.Moved
                        ? $"yerleşim değişti ({diff.Moved} blok başka yerde)"
                        : $"ekran değişti ({diff.Gone} blok gitti, {diff.Fresh} yeni, {diff.Changed} blokta başka yazı)";
                    previous = [.. blocks];
                    return Unlock(reason, clear: false, blocks, settled);
                }
                changing = 0;
                changingTo = null;
                var touched = new SortedSet<string>(StringComparer.Ordinal);
                foreach (var slot in slots)
                {
                    if (slot.Pending is { } pending && Steady(slot, pending))
                    {
                        Apply(pending, slot);
                        if (slot.Id is { } id) touched.Add(id);
                    }
                }
                Save();
                return Routes ? RenderAll(touched) : [.. touched.Select(Render).OfType<Send>()];
            }
            if (Cached(blocks) is { } saved)
            {
                previous = [.. blocks];
                return Restore(saved, ScreenKey(blocks), blocks.Count);
            }
            var last = previous;
            previous = [.. blocks];
            if (last is null || last.Count != blocks.Count || Compare(last, blocks).Share != 0) return [];
            LockOn(blocks);
            return [];
        }
    }

    /// <summary>Kilit dışarıdan bırakıldı (telefon açıldı, ayar değişti): gösterilenler unutulur, önbellek kalır.</summary>
    internal void Release(string reason)
    {
        lock (gate)
        {
            if (locked)
            {
                Unlocks++;
                Log?.Invoke($"ekran kilidi açıldı: {reason}, {slots.Count} blok");
                Save();
            }
            locked = false;
            slots = [];
            previous = null;
            emptySince = null;
            changing = 0;
            changingTo = null;
            intended.Clear();
            displayed = [];
            frames = [];
        }
    }

    /// <summary>Oturum bitti: önbellek de unutulur.</summary>
    internal void Reset()
    {
        lock (gate)
        {
            Release("çeviri durdu");
            blockers.Clear();
            cache.Clear();
            cacheOrder.Clear();
        }
    }

    private void LockOn(IReadOnlyList<Block> blocks)
    {
        locked = true;
        Locks++;
        changing = 0;
        lockKey = ScreenKey(blocks);
        slots = [.. blocks.Select(b => new Slot { Key = b.Key, Box = b.Box, Route = b.Route, Seen = b.Key, SeenPasses = SteadyPasses })];
        frames = [];
        // Çizili kutular yuvalarına oturur; yuvası olmayan çizili kutu da yerinde kalır (kendi yuvası olur).
        foreach (var (id, payload) in displayed.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            frames[id] = new Payload("", payload.Box, payload.LineHeight, payload.Icons, null);
            foreach (var item in payload.Blocks ?? [])
            {
                if (SlotFor(item.Box, Routes ? Rank(id) : 0) is { Item: null } slot)
                {
                    slot.Item = item;
                    slot.Id = id;
                }
                else
                {
                    var key = Key(item.Source);
                    slots.Add(new Slot
                    {
                        Key = key, Box = item.Box, Route = Rank(id), Observed = false, Id = id, Item = item, Seen = key, SeenPasses = 0,
                    });
                }
            }
        }
        Log?.Invoke($"ekran kilidi: kilitlendi, {blocks.Count} blok ({slots.Count(s => s.Item is not null)} çevirili)");
        Save();
    }

    private Saved? Cached(IReadOnlyList<Block> blocks)
    {
        if (!cache.TryGetValue(ScreenKey(blocks), out var saved) || !saved.Slots.Any(s => s.Item is not null)) return null;
        var layout = saved.Slots.Where(s => s.Observed).Select(s => new Block(s.Key, s.Box)).ToList();
        return Compare(layout, blocks).Share < ChangeShare ? saved : null;
    }

    private List<Send> Restore(Saved saved, string key, int count)
    {
        locked = true;
        Locks++;
        CacheHits++;
        changing = 0;
        lockKey = key;
        slots = [.. saved.Slots.Select(s =>
        {
            var copy = s.Copy();
            copy.Seen = copy.Key;
            copy.SeenPasses = SteadyPasses;
            copy.Pending = null;
            copy.UnreadSince = null;
            return copy;
        })];
        frames = new Dictionary<string, Payload>(saved.Frames);
        Log?.Invoke($"ekran kilidi: önbellekten kilitlendi (aynı ekrana dönüldü), {count} blok");
        var sends = new List<Send>();
        var ids = slots.Select(s => s.Id).OfType<string>().ToHashSet();
        foreach (var id in displayed.Keys.Where(id => !ids.Contains(id)).OrderBy(id => id, StringComparer.Ordinal).ToList())
        {
            displayed.Remove(id);
            intended.Remove(id);
            sends.Add(new Send(id, null, Forget: true));
        }
        sends.AddRange(ids.OrderBy(id => id, StringComparer.Ordinal).Select(Render).OfType<Send>());
        return sends;
    }

    private List<Send> Unlock(string reason, bool clear, IReadOnlyList<Block> next, bool settled)
    {
        Unlocks++;
        Log?.Invoke($"ekran kilidi açıldı: {reason}, {slots.Count} blok");
        Save();
        locked = false;
        slots = [];
        frames = [];
        changing = 0;
        changingTo = null;
        var sends = new List<Send>();
        if (clear)
        {
            sends.AddRange(displayed.Keys.OrderBy(id => id, StringComparer.Ordinal).Select(id => new Send(id, null, Forget: true)));
            displayed = [];
            intended.Clear();
            return sends;
        }
        // Yeni ekran daha önce kilitlenmişse (menüye dönüldü) aynı kutular ve çevirilerle hemen çizilir.
        if (Cached(next) is { } saved) return Restore(saved, ScreenKey(next), next.Count);
        // İzleyicinin şimdiki durumu çizilir (yeni ekran).
        if (Routes) sends.AddRange(Publish());
        else
        {
            foreach (var id in displayed.Keys.Union(intended.Keys).Distinct().OrderBy(id => id, StringComparer.Ordinal).ToList())
            {
                var want = intended.GetValueOrDefault(id);
                if (want is null ? displayed.ContainsKey(id) : !want.Same(displayed.GetValueOrDefault(id))) sends.Add(new Send(id, want));
            }
            displayed = new Dictionary<string, Payload>(intended);
        }
        if (settled && next.Count > 0) LockOn(next);
        return sends;
    }

    /// <summary>Kilitli ekranın yuvaları önbelleğe yazılır.</summary>
    private void Save()
    {
        if (!locked || lockKey.Length == 0 || !slots.Any(s => s.Item is not null)) return;
        if (!cache.ContainsKey(lockKey))
        {
            cacheOrder.Add(lockKey);
            if (cacheOrder.Count > CacheLimit)
            {
                cache.Remove(cacheOrder[0]);
                cacheOrder.RemoveAt(0);
            }
        }
        cache[lockKey] = new Saved([.. slots.Select(s => s.Copy())], new Dictionary<string, Payload>(frames));
    }

    /// <summary>Kutunun yuvası; <paramref name="route"/>: gönderen yolun önceliği, daha öncelikli yolun yuvası seçilmez.</summary>
    private Slot? SlotFor(TextBox box, int route)
    {
        Slot? best = null;
        var bestOverlap = SamePlace;
        foreach (var slot in slots)
        {
            if (slot.Route < route) continue;
            var o = Overlap(slot.Box, box);
            if (o >= bestOverlap) { best = slot; bestOverlap = o; }
        }
        return best;
    }

    /// <summary>Yuvanın okuması en az <see cref="SteadyPasses"/> turdur aynı ve gelen yazı o okumanın yazısı.</summary>
    private static bool Steady(Slot slot, ScreenTranslation.Item item) =>
        slot.SeenPasses >= SteadyPasses && Similar(slot.Seen, Key(item.Source));

    /// <summary>Yazı güncellenir; kutu, yer, boy ve çizim ölçüleri yuvanınkidir.</summary>
    private static void Apply(ScreenTranslation.Item item, Slot slot)
    {
        if (slot.Item is not { } current) return;
        current = Recoloured(current, item) ?? current;
        slot.Item = current with { Source = item.Source, Translation = item.Translation, Icons = item.Icons };
        slot.Pending = null;
    }

    /// <summary>Zeminin parlaklığı bu kadar değiştiyse seçim gezmiştir (açık şerit koyuya ya da tersine).</summary>
    internal const int RecolourLuma = 60;

    /// <summary>"#RRGGBB" rengin parlaklığı (0–255).</summary>
    internal static int? Luma(string? hex)
    {
        if (hex is not { Length: 7 } || hex[0] != '#'
            || !int.TryParse(hex.AsSpan(1), System.Globalization.NumberStyles.HexNumber, null, out var value)) return null;
        return (299 * ((value >> 16) & 0xff) + 587 * ((value >> 8) & 0xff) + 114 * (value & 0xff)) / 1000;
    }

    internal static bool Recolours(string? a, string? b) =>
        Luma(a) is { } x && Luma(b) is { } y && Math.Abs(x - y) >= RecolourLuma;

    /// <summary>Seçim gezdi (#1267): yazının ve zeminin renkleri yeni okumadan; kutu, yer ve çizim ölçüleri yuvanınki. Değişen yoksa null.</summary>
    internal static ScreenTranslation.Item? Recoloured(ScreenTranslation.Item old, ScreenTranslation.Item fresh)
    {
        // Okumanın renk oynaması güncelleme değildir (kutu boşuna yeniden çizilmez).
        if (!Recolours(old.Style?.Background, fresh.Style?.Background) && !Recolours(old.Paint?.Background, fresh.Paint?.Background))
            return null;
        var style = fresh.Style ?? old.Style;
        var paint = old.Paint is { } p && fresh.Paint is { } f
            ? p with { Background = f.Background, Background2 = f.Background2, Direction = f.Direction, Patterned = f.Patterned }
            : old.Paint;
        if (Equals(style, old.Style) && Equals(paint, old.Paint)) return null;
        return old with { Style = style, Paint = paint };
    }

    /// <summary>İzleyicinin istediği, yollar arası çakışması çözülmüş hâli: alanlar öncelik sırasıyla yerleşir; daha öncelikli
    /// yolun kutusuyla çakışan öğe çizilmez, bütün öğeleri çakışan alan hiç gönderilmez.</summary>
    private Dictionary<string, Payload> Resolved()
    {
        var result = new Dictionary<string, Payload>();
        hidden.Clear();
        var boxes = new List<(int Rank, List<TextBox> Rects)>();
        foreach (var id in blockers.Keys.OrderBy(id => id, StringComparer.Ordinal))
            boxes.AddRange(Footprints(blockers[id]).Select(f => (Rank(id), f)));
        foreach (var id in ByRank(intended.Keys).ToList())
        {
            var payload = intended[id];
            var rank = Rank(id);
            bool Free(List<TextBox> rects) => !boxes.Any(b => b.Rank < rank && Clash(b.Rects, rects));
            if (payload.Blocks is not { Count: > 0 } items)
            {
                List<TextBox> rects = payload.Box is { } box ? [box] : [];
                if (!Free(rects))
                {
                    hidden[id] = 1;
                    continue;
                }
                boxes.Add((rank, rects));
                result[id] = payload;
                continue;
            }
            var keep = items.Where(item => Free(Footprint(item))).ToList();
            if (keep.Count < items.Count) hidden[id] = items.Count - keep.Count;
            if (keep.Count == 0) continue;
            boxes.AddRange(keep.Select(item => (rank, Footprint(item))));
            result[id] = keep.Count == items.Count
                ? payload
                : payload with { Blocks = keep, Text = string.Join("\n", keep.Select(i => i.Translation)) };
        }
        return result;
    }

    /// <summary>Kilitsizken TV'ye gidecekler: çakışması çözülmüş istek ile TV'de duran arasındaki fark.</summary>
    private List<Send> Publish()
    {
        var next = Resolved();
        var summary = string.Join(", ", hidden.OrderBy(h => h.Key, StringComparer.Ordinal).Select(h => $"{h.Key} {h.Value}"));
        if (summary != routeLogged)
        {
            if (summary.Length > 0) Log?.Invoke($"ekran yazısı yolları: öncelikli yolun kutusuyla çakışan kutu çizilmedi ({summary})");
            routeLogged = summary;
        }
        var sends = new List<Send>();
        foreach (var id in displayed.Keys.Union(next.Keys).Distinct().OrderBy(id => id, StringComparer.Ordinal).ToList())
        {
            var want = next.GetValueOrDefault(id);
            if (want is null ? displayed.ContainsKey(id) : !want.Same(displayed.GetValueOrDefault(id))) sends.Add(new Send(id, want));
        }
        displayed = next;
        return sends;
    }

    /// <summary>Kilitliyken yazısı değişen ve görünürlüğü değişen alanlar yeniden çizilir: bir yolun yuvası dolunca ya da görev
    /// kutusu gelip gidince alçak yolun çakışan öğesi gizlenir ya da yeniden görünür; kutular yerinde kalır.</summary>
    private List<Send> RenderAll(SortedSet<string> touched)
    {
        var sends = new List<Send>();
        foreach (var id in slots.Select(s => s.Id).OfType<string>().Distinct().OrderBy(id => id, StringComparer.Ordinal).ToList())
        {
            var shown = displayed.GetValueOrDefault(id)?.Blocks?.Count ?? 0;
            if (!touched.Contains(id) && shown == Visible(id).Count) continue;
            if (Render(id) is { } send) sends.Add(send);
        }
        return sends;
    }

    /// <summary>Alanın kilitli yuvalarından çizilecek öğeler: öncelikli yolun (görev kutusu, kilitli başka alanın yuvası)
    /// kutusuyla çakışan öğe çizilmez.</summary>
    private List<ScreenTranslation.Item> Visible(string id)
    {
        var all = slots.Where(s => s.Id == id).Select(s => s.Item).OfType<ScreenTranslation.Item>().ToList();
        if (!Routes || all.Count == 0) return all;
        var rank = Rank(id);
        var above = blockers.Where(b => Rank(b.Key) < rank).OrderBy(b => b.Key, StringComparer.Ordinal)
            .SelectMany(b => Footprints(b.Value)).ToList();
        foreach (var slot in slots)
        {
            if (slot.Id is { } owner && Rank(owner) < rank && slot.Item is { } item) above.Add(Footprint(item));
        }
        return [.. all.Where(item => !above.Any(a => Clash(a, Footprint(item))))];
    }

    private Send? Render(string id)
    {
        if (!slots.Any(s => s.Id == id && s.Item is not null)) return null;
        var items = Visible(id).OrderBy(i => i.Box.Top).ThenBy(i => i.Box.Left).ToList();
        if (items.Count == 0)
        {
            if (!displayed.Remove(id)) return null;
            return new Send(id, null);
        }
        var frame = frames.GetValueOrDefault(id);
        var payload = new Payload(string.Join("\n", items.Select(i => i.Translation)), frame?.Box ?? items[0].Box,
                                  frame?.LineHeight ?? items[0].LineHeight, frame?.Icons, items);
        if (payload.Same(displayed.GetValueOrDefault(id))) return null;
        displayed[id] = payload;
        return new Send(id, payload);
    }
}
