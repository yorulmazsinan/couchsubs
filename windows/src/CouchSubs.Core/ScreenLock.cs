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
/// </list>
/// Yalnız gönderilenleri süzer. Mac/iPhone (ScreenLock.swift) ve Android (ScreenLock.kt) aynı kurallar. İş parçacığına
/// dayanıklıdır (her çağrı kendi kilidinde).
/// </summary>
internal sealed class ScreenLock
{
    /// <summary>Kilidin altındaki alan: otomatik ekran yazısı; görev kutusu ve kenar bildirimi kendi yuvasında kalır.</summary>
    internal static bool Covers(string id) =>
        ScreenTextAreas.IsAuto(id) && id != MissionLine.AreaId && !ScreenNotices.IsNotice(id);

    internal readonly record struct Block(string Key, TextBox Box);

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

    internal sealed class Slot
    {
        public required string Key { get; init; }
        public required TextBox Box { get; init; }
        public bool Observed { get; init; } = true;
        public string? Id { get; set; }
        public ScreenTranslation.Item? Item { get; set; }
        public required string Seen { get; set; }
        public int SeenPasses { get; set; }
        public ScreenTranslation.Item? Pending { get; set; }

        public Slot Copy() => new()
        {
            Key = Key, Box = Box, Observed = Observed, Id = Id, Item = Item, Seen = Seen, SeenPasses = SeenPasses, Pending = Pending,
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
                if (!Similar(block.Key, fresh[b].Key)) changed++;
            }
            else
            {
                gone++;
                if (fresh.Any(other => Similar(other.Key, block.Key))) moved++;
            }
        }
        return new Diff(gone, fresh.Count - used.Count, changed, moved, Math.Max(old.Count, fresh.Count));
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
                // Kilit yokken gönderi olduğu gibi geçer.
                if (payload is null) displayed.Remove(id); else displayed[id] = payload;
                return [new Send(id, payload)];
            }
            // Kilitliyken kutu kalkmaz; yeni kutu eklenmez; bloksuz gönderi kilidin dışında kalır.
            if (payload?.Blocks is not { Count: > 0 } items) return [];
            if (!frames.ContainsKey(id)) frames[id] = new Payload("", payload.Box, payload.LineHeight, payload.Icons, null);
            var touched = new SortedSet<string>(StringComparer.Ordinal);
            foreach (var item in items)
            {
                if (SlotFor(item.Box) is not { } slot) continue;
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
            return [.. touched.Select(Render).OfType<Send>()];
        }
    }

    private static bool SameIcons(IReadOnlyList<IconPlacement>? a, IReadOnlyList<IconPlacement>? b) =>
        (a?.Count ?? 0) == (b?.Count ?? 0) && (a is null || b is null || a.SequenceEqual(b));

    /// <summary>Turun sonu: bu turda okunan bütün ekran yazısı blokları. Kilitlenir, açılır ya da bekleyen yazı güncellenir.</summary>
    internal List<Send> Observe(IReadOnlyList<Block> blocks, long now)
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
                    Block? read = null;
                    var best = 0.0;
                    foreach (var block in blocks)
                    {
                        var o = Overlap(block.Box, slot.Box);
                        if (o >= SamePlace && o > best) { read = block; best = o; }
                    }
                    if (read is not { } r)
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
                var layout = slots.Where(s => s.Observed).Select(s => new Block(s.Key, s.Box)).ToList();
                var diff = Compare(layout, blocks);
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
                return [.. touched.Select(Render).OfType<Send>()];
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
        slots = [.. blocks.Select(b => new Slot { Key = b.Key, Box = b.Box, Seen = b.Key, SeenPasses = SteadyPasses })];
        frames = [];
        // Çizili kutular yuvalarına oturur; yuvası olmayan çizili kutu da yerinde kalır (kendi yuvası olur).
        foreach (var (id, payload) in displayed.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            frames[id] = new Payload("", payload.Box, payload.LineHeight, payload.Icons, null);
            foreach (var item in payload.Blocks ?? [])
            {
                if (SlotFor(item.Box) is { Item: null } slot)
                {
                    slot.Item = item;
                    slot.Id = id;
                }
                else
                {
                    var key = Key(item.Source);
                    slots.Add(new Slot { Key = key, Box = item.Box, Observed = false, Id = id, Item = item, Seen = key, SeenPasses = 0 });
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
        foreach (var id in displayed.Keys.Union(intended.Keys).Distinct().OrderBy(id => id, StringComparer.Ordinal).ToList())
        {
            var want = intended.GetValueOrDefault(id);
            if (want is null ? displayed.ContainsKey(id) : !want.Same(displayed.GetValueOrDefault(id))) sends.Add(new Send(id, want));
        }
        displayed = new Dictionary<string, Payload>(intended);
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

    private Slot? SlotFor(TextBox box)
    {
        Slot? best = null;
        var bestOverlap = SamePlace;
        foreach (var slot in slots)
        {
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

    private Send? Render(string id)
    {
        var items = slots.Where(s => s.Id == id).Select(s => s.Item).OfType<ScreenTranslation.Item>()
            .OrderBy(i => i.Box.Top).ThenBy(i => i.Box.Left).ToList();
        if (items.Count == 0) return null;
        var frame = frames.GetValueOrDefault(id);
        var payload = new Payload(string.Join("\n", items.Select(i => i.Translation)), frame?.Box ?? items[0].Box,
                                  frame?.LineHeight ?? items[0].LineHeight, frame?.Icons, items);
        if (payload.Same(displayed.GetValueOrDefault(id))) return null;
        displayed[id] = payload;
        return new Send(id, payload);
    }
}
