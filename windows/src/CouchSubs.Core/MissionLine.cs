// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Görev/hedef satırı altyazıdan ayrı, kendi yerinde: altyazı hattının altyazı bloğundan çıkardığı satırlardan
/// (<see cref="StickyRows.Removed"/>) konuşan adı taşımayan ve en az <see cref="SettleMs"/> ekranda kalan satırlar görevdir.
/// Bölgesi "auto-mission" ek alanı olarak sürekli okunur, çevirisi özgün stilinde kendi yerinde görünür (RegionWatcher).
/// Görev yerinde durdukça bölge değişmez: altyazı her değiştiğinde görev kutusu yeniden gönderilmez, yanıp sönmez.
/// Mac/iPhone (MissionLine.swift) ve Android (MissionLine.kt) aynı kuralları uygular.
/// </summary>
public sealed class MissionLine
{
    public const string AreaId = "auto-mission";
    /// <summary>Satır bu kadar ekranda kalınca görev sayılır.</summary>
    public const int SettleMs = 3000;
    /// <summary>Bu kadar görülmeyen satır ekrandan kalkmış sayılır.</summary>
    public const int ForgetMs = 1500;
    /// <summary>
    /// Görev sayılmış (kendi kutusunda gösterilen) satır ancak bu kadar görülmezse kalkar (histerezis): tek okumada ya da
    /// kamera geçişinde kaçan görev satırının kutusu kalkıp gelmez (Sinan Bey, GTA 6 beta.105; Mac/iPhone ve Android aynı).
    /// </summary>
    public const int HoldMs = 4000;
    /// <summary>
    /// Görev çevirisinin kutusu: koyu kehribar zemin, beyaz yazı. Kullanıcı bildirimi (beta.100): görev yazısının Türkçesi
    /// altyazıyla ve öbür ekran yazılarıyla aynı görünüyor, hangisinin görev olduğu anlaşılmıyordu. TV ve önizlemeler bu
    /// zemini öğenin Style'ından çizer (Mac/iPhone: MissionLine.style, Android: MissionLine.STYLE).
    /// </summary>
    public static readonly PhoneTextStyle Style = new("#7A4E00", "#FFFFFF");
    /// <summary>Görev çevirisinin başındaki hedef imi (yaygın yazı tiplerinde bulunan dolu üçgen; emoji değildir).</summary>
    public const string Marker = "\u25BA ";

    private sealed class Track(string text, string source, long since, TextBox box)
    {
        public string Text { get; } = text;
        public string Source { get; } = source;
        public long Since { get; } = since;
        public long LastSeen { get; set; } = since;
        public TextBox Box { get; set; } = box;
        /// <summary>Görev sayıldı (SettleMs doldu): HoldMs histerezisi ve Claim uygulanır.</summary>
        public bool Settled { get; set; }
    }

    private readonly List<Track> tracks = [];

    /// <summary>Görevin karedeki bölgesi; görev yoksa null.</summary>
    public CropRegion? Region { get; private set; }

    /// <summary>
    /// Ekranda duran görev satırlarının karedeki yeri (<see cref="SettleMs"/> dolmadan da): TV ve OBS sayfası altyazı
    /// kutusunu bunun üstüne taşır, kutu oyundaki görev satırını örtmez. Kullanıcı bildirimi (X, beta.100–104, GTA 6):
    /// "Örtsün"de iki satırlık Türkçe İngilizce satırın ortasına göre büyüyor, alttaki görev satırının ("Get in the
    /// speedboat") üst yarısını kapatıyordu. Okuma kutusunun küçük oynaması değer değiştirmez. Mac/iPhone ve Android aynı.
    /// </summary>
    public TextBox? Clearance { get; private set; }

    /// <summary>
    /// Son <see cref="Observe"/>'da <see cref="SettleMs"/> dolmadan ekrandan kalkan (görev sayılmayan) satırlar, özgün
    /// metinleriyle; altyazı günlüğü için. Mac/iPhone ve Android aynıdır.
    /// </summary>
    public IReadOnlyList<string> Dropped { get; private set; } = [];

    /// <summary>
    /// Altyazı bloğundan çıkarılan satırlar (yeri <paramref name="area"/>'ya oranla). Görev bölgesi değiştiyse true.
    /// </summary>
    public bool Observe(IReadOnlyList<TextLine> removed, TextBox area, long time)
    {
        foreach (var line in removed)
        {
            if (line.Box is not { } box || SpeakerPrefix.Parse(line.Text) is not null) continue;
            var text = TextMatch.Normalize(line.Text);
            if (text.Length < 3) continue;
            var placed = box.PlacedIn(area);
            if (!IsCandidate(line.Text, placed)) continue;
            var track = tracks.FirstOrDefault(item => TextMatch.IsSimilar(item.Text, text));
            if (track is null) tracks.Add(track = new Track(text, line.Text, time, placed));
            track.LastSeen = time;
            track.Box = placed;
        }
        var gone = tracks.Where(item => time - item.LastSeen > (item.Settled ? HoldMs : ForgetMs)).ToList();
        Dropped = [.. gone.Where(item => !item.Settled && item.LastSeen - item.Since < SettleMs).Select(item => item.Source)];
        tracks.RemoveAll(gone.Contains);
        foreach (var item in tracks.Where(item => time - item.Since >= SettleMs)) item.Settled = true;
        TextBox? shown = tracks.Count == 0 ? null : tracks.Select(item => item.Box).Aggregate((a, b) => a.Union(b));
        if (shown is not { } visible || Clearance is not { } kept || !Near(visible, kept)) Clearance = shown;
        var settled = tracks.Where(item => item.Settled).ToList();
        CropRegion? next = null;
        if (settled.Count > 0)
        {
            var union = settled.Select(item => item.Box).Aggregate((a, b) => a.Union(b));
            var line = settled.Min(item => item.Box.Bottom - item.Box.Top);
            next = new CropRegion(Math.Max(0, union.Top - 0.35 * line), Math.Min(1, union.Bottom + 0.35 * line),
                                  Math.Max(0, union.Left - 0.01), Math.Min(1, union.Right + 0.01));
            // Okuma kutusunun küçük oynaması bölgeyi değiştirmez (bölge değişirse görev yeniden okunur).
            if (Region is { } current && Within(next, current, line * 0.5)) next = current;
        }
        if (next == Region) return false;
        Region = next;
        return true;
    }

    /// <summary>
    /// Satır (kutusu karede) görev olabilir mi. Görev satırı ortadadır ve sözcüklerden oluşur; ekranın bir yanındaki HUD
    /// yazısı (<see cref="ScreenNotices.IsNotice(TextBox)"/>: GTA 6'da arama kartının yanındaki küçük yazı) ya da okuma
    /// kırıntısı (<see cref="OcrNoise.IsCrumb"/>) görev sayılıp kendi yerinde çevrilmez. Kullanıcı bildirimi (GitHub #882,
    /// GTA 6): telefon araması sürerken arama kartının yanında "kulaklı ar." diye küçük bir çeviri kutusu çıkıyordu.
    /// </summary>
    public static bool IsCandidate(string text, TextBox box) => !ScreenNotices.IsNotice(box) && !OcrNoise.IsCrumb(text);

    /// <summary>
    /// Görev sayılmış satırın okumadaki yeni okunuşları okumadan çıkarılır (Kept) ve görev satırı olarak Observe'a verilir
    /// (Claimed): görev tek başına kaldığında ya da ıskadan sonra döndüğünde altyazı kutusunda çevrilmez, sabit satır
    /// süzgeci de konuşmayı görev saymaz. Aynı yazı (TextMatch.IsSimilar), görevin yerinde (dikeyde örtüşür); konuşan adlı
    /// satır alınmaz (Mac/iPhone: MissionLine.claim, Android aynı).
    /// </summary>
    public (Reading Kept, IReadOnlyList<TextLine> Claimed) Claim(Reading reading, TextBox area)
    {
        var shown = tracks.Where(item => item.Settled).ToList();
        if (shown.Count == 0) return (reading, []);
        var kept = new List<TextLine>();
        var claimed = new List<TextLine>();
        foreach (var line in reading.Lines)
        {
            if (line.Box is not { } box || SpeakerPrefix.Parse(line.Text) is not null) { kept.Add(line); continue; }
            var placed = box.PlacedIn(area);
            var text = TextMatch.Normalize(line.Text);
            var ours = text.Length >= 3 && shown.Any(track =>
            {
                var height = Math.Min(placed.Bottom - placed.Top, track.Box.Bottom - track.Box.Top);
                var overlap = Math.Min(placed.Bottom, track.Box.Bottom) - Math.Max(placed.Top, track.Box.Top);
                return overlap >= 0.5 * height && TextMatch.IsSimilar(track.Text, text);
            });
            (ours ? claimed : kept).Add(line);
        }
        return claimed.Count == 0 ? (reading, []) : (new Reading(kept), claimed);
    }

    public void Reset()
    {
        tracks.Clear();
        Region = null;
        Clearance = null;
        Dropped = [];
    }

    /// <summary>İki kutu satır boyunun çeyreğinden az oynamış mı.</summary>
    internal static bool Near(TextBox a, TextBox b)
    {
        var tolerance = 0.25 * Math.Min(a.Bottom - a.Top, b.Bottom - b.Top);
        return Math.Abs(a.Top - b.Top) <= tolerance && Math.Abs(a.Bottom - b.Bottom) <= tolerance
            && Math.Abs(a.Left - b.Left) <= tolerance * 2 && Math.Abs(a.Right - b.Right) <= tolerance * 2;
    }

    private static bool Within(CropRegion a, CropRegion b, double tolerance) =>
        Math.Abs(a.Top - b.Top) <= tolerance && Math.Abs(a.Bottom - b.Bottom) <= tolerance
        && Math.Abs(a.Left - b.Left) <= tolerance * 2 && Math.Abs(a.Right - b.Right) <= tolerance * 2;
}
