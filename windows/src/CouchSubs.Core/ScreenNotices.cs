// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Ekranın kenarındaki bildirim kartları (GTA 6: sağ altta telefona gelen mesajın önizlemesi, solda kayarak giren bildirim)
/// altyazı değildir, kendi yerinde çevrilir. Kullanıcı bildirimi (X, iki kişi): altyazı alanı "Tam ekran"ken bu kartlar
/// altyazı bloğu seçiliyordu (ortalanmış blok yokken en alttaki üç sözcüklü blok); çevirileri altyazının yerinde, ekranın
/// ortasında çiziliyor, art arda gelen kartlar orada üst üste toplanıyordu. Artık "Tam ekran" alanda
/// (<see cref="IsWholeScreen"/>) karenin bir yarısında kalan ve ortasından uzak blok (<see cref="IsNotice(TextBox)"/>) altyazı
/// bloğuna girmez (<see cref="Reading.SubtitleBlock"/>); bildirim olarak izlenir. Kayarak giren kartın kutusu her karede
/// kayar: kutu <see cref="SettleMs"/> boyunca yerinde durunca (kayma bitti) bölgesi "auto-notice-&lt;n&gt;" ek alanı olur,
/// çevirisi <see cref="RegionWatcher"/> ile özgün stilinde kendi yerinde görünür. Kart sonra yeniden kayarsa son geçerli yer
/// kalır; konumu belirsiz kart hiç çizilmez, asla ortaya çizilmez. Mac/iPhone (ScreenNotices.swift) ve Android
/// (ScreenNotices.kt) aynı kuralları ve eşikleri uygular; ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/screen-notice.json.
/// </summary>
public sealed class ScreenNotices
{
    public const string IdPrefix = "auto-notice-";
    /// <summary>Okunan alan karenin en az bu kadar genişliğini ve <see cref="TallArea"/> kadar yüksekliğini kaplıyorsa "Tam ekran".</summary>
    public const double WideArea = 0.85;
    public const double TallArea = 0.5;
    /// <summary>Bildirim bloğunun yatay ortası karenin ortasından en az bu kadar uzaktır (blok ortayı geçmez).</summary>
    public const double SideOffset = 0.2;
    /// <summary>Kutu bu kadar süre yerinde durunca (kayma bitti) bildirimin bölgesi gönderilir.</summary>
    public const int SettleMs = 400;
    /// <summary>Bu kadar görülmeyen bildirim ekrandan kalkmış sayılır.</summary>
    public const int ForgetMs = 1500;
    /// <summary>Kutunun kenarları bundan az oynarsa yerinde duruyor sayılır.</summary>
    public const double MoveTolerance = 0.006;
    /// <summary>En çok bu kadar bildirim aynı anda kendi yerinde çevrilir.</summary>
    public const int MaxCount = 3;

    public static bool IsWholeScreen(TextBox area) =>
        area.Right - area.Left >= WideArea && area.Bottom - area.Top >= TallArea;

    /// <summary>Kutu (karede) bir kenar bildirimi mi: karenin bir yarısında ve ortası karenin ortasından en az <see cref="SideOffset"/> uzak.</summary>
    public static bool IsNotice(TextBox box) =>
        box.Right > box.Left && box.Bottom > box.Top && (box.Right <= 0.5 || box.Left >= 0.5)
        && Math.Abs((box.Left + box.Right) / 2 - 0.5) >= SideOffset;

    /// <summary>Ek alan bir bildirim bölgesi mi.</summary>
    public static bool IsNotice(string id) => id.StartsWith(IdPrefix, StringComparison.Ordinal);

    private sealed class Track(int number, TextBox box, double line, long time)
    {
        public int Number { get; } = number;
        public TextBox Box { get; set; } = box;
        public double Line { get; set; } = line;
        public long Still { get; set; } = time;
        public long LastSeen { get; set; } = time;
        public CropRegion? Region { get; set; }
        /// <summary>Bildirim kartı (<see cref="NoticeCard"/>): kutu kartın bütün yeridir, bölge de odur.</summary>
        public bool Card { get; init; }
    }

    private readonly List<Track> tracks = [];
    private int counter;

    /// <summary>Şu an kendi yerinde okunan bildirim alanları.</summary>
    public IReadOnlyList<WatchedArea> Areas { get; private set; } = [];

    /// <summary>
    /// Bu karenin bildirim blokları (satır kutuları karede) ve bildirim kartları (<see cref="NoticeCard"/>; kartın karedeki
    /// yeri, alan türünden bağımsız). Alan listesi değiştiyse true. Bildirim yokken de her karede çağrılır: görülmeyen
    /// bildirim <see cref="ForgetMs"/> sonra kalkar. Kartın bölgesi kartın kendisidir (başlık ve gövde birlikte okunur,
    /// çeviri kartı örter).
    /// </summary>
    public bool Observe(IReadOnlyList<Reading> blocks, long time, IReadOnlyList<TextBox>? cards = null)
    {
        var matched = new HashSet<Track>();
        foreach (var box in cards ?? [])
        {
            var track = tracks.FirstOrDefault(t => !matched.Contains(t) && t.Card && Same(t.Box, box));
            if (track is null)
            {
                tracks.Add(track = new Track(++counter, box, 0, time) { Card = true });
            }
            else
            {
                if (Moved(track.Box, box)) track.Still = time;
                track.Box = box;
                track.LastSeen = time;
            }
            matched.Add(track);
        }
        foreach (var block in blocks)
        {
            if (block.Box is not { } box || !IsNotice(box)) continue;
            var heights = block.Lines.Where(l => l.Box is not null).Select(l => l.Box!.Value.Bottom - l.Box!.Value.Top).ToList();
            var line = heights.Count > 0 ? heights.Min() : box.Bottom - box.Top;
            var track = tracks.FirstOrDefault(t => !matched.Contains(t) && !t.Card && Same(t.Box, box));
            if (track is null)
            {
                tracks.Add(track = new Track(++counter, box, line, time));
            }
            else
            {
                if (Moved(track.Box, box)) track.Still = time;
                track.Box = box;
                track.Line = line;
                track.LastSeen = time;
            }
            matched.Add(track);
        }
        tracks.RemoveAll(t => time - t.LastSeen > ForgetMs);
        foreach (var track in tracks.Where(t => time - t.Still >= SettleMs))
        {
            var next = track.Card ? CardRegion(track.Box) : RegionOf(track.Box, track.Line);
            // Okuma kutusunun küçük oynaması bölgeyi değiştirmez (bölge değişirse bildirim yeniden okunur).
            if (track.Region is { } current && Close(current, next)) continue;
            track.Region = next;
        }
        var areas = tracks.Where(t => t.Region is not null).Take(MaxCount)
            .Select(t => new WatchedArea(IdPrefix + t.Number, "Notice", t.Region!) { Auto = true }).ToList();
        if (areas.SequenceEqual(Areas)) return false;
        Areas = areas;
        return true;
    }

    public void Reset()
    {
        tracks.Clear();
        Areas = [];
    }

    /// <summary>Bölge: kutu ve her yanında pay (dikeyde satır boyunun %35'i, yatayda karenin %1'i), 0…1'e kırpılmış.</summary>
    internal static CropRegion RegionOf(TextBox box, double line) =>
        new(Math.Max(0, box.Top - 0.35 * line), Math.Min(1, box.Bottom + 0.35 * line),
            Math.Max(0, box.Left - 0.01), Math.Min(1, box.Right + 0.01));

    /// <summary>Bildirim kartının bölgesi: kartın kendisi, 0…1'e kırpılmış.</summary>
    internal static CropRegion CardRegion(TextBox box) =>
        new(Math.Max(0, box.Top), Math.Min(1, box.Bottom), Math.Max(0, box.Left), Math.Min(1, box.Right));

    /// <summary>
    /// İki kutu aynı bildirim mi: karenin aynı yarısında ve dikeyde (yana kayan kart) ya da yatayda (yukarı kayan kart)
    /// küçüğünün en az yarısı kadar örtüşüyor.
    /// </summary>
    internal static bool Same(TextBox a, TextBox b)
    {
        if ((a.Left + a.Right) / 2 < 0.5 != (b.Left + b.Right) / 2 < 0.5) return false;
        var vertical = Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top);
        var horizontal = Math.Min(a.Right, b.Right) - Math.Max(a.Left, b.Left);
        var rows = vertical > 0 && vertical >= 0.5 * Math.Min(a.Bottom - a.Top, b.Bottom - b.Top);
        var columns = horizontal > 0 && horizontal >= 0.5 * Math.Min(a.Right - a.Left, b.Right - b.Left)
            && Math.Max(a.Top, b.Top) - Math.Min(a.Bottom, b.Bottom) <= Math.Max(a.Bottom - a.Top, b.Bottom - b.Top);
        return rows || columns;
    }

    internal static bool Moved(TextBox a, TextBox b) =>
        Math.Abs(a.Left - b.Left) > MoveTolerance || Math.Abs(a.Top - b.Top) > MoveTolerance
        || Math.Abs(a.Right - b.Right) > MoveTolerance || Math.Abs(a.Bottom - b.Bottom) > MoveTolerance;

    private static bool Close(CropRegion a, CropRegion b) =>
        Math.Abs(a.Left - b.Left) <= MoveTolerance && Math.Abs(a.Top - b.Top) <= MoveTolerance
        && Math.Abs(a.Right - b.Right) <= MoveTolerance && Math.Abs(a.Bottom - b.Bottom) <= MoveTolerance;
}
