// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Altyazı hattının son okuduğu satırlar ve altyazı alanı: ekran yazısı (otomatik dedektör, hazır alanlar, görev satırı,
/// "Ekranı çevir") altyazıyı ikinci kez çizmesin. Kullanıcı bildirimi (X, beta.65/66): "Ekran yazılarını otomatik
/// çevir" açıkken altyazının çevirisi hem seçilen altyazı konumunda hem oyunun altyazısının tam üstünde görünüyordu.
/// Dedektör yalnız merkezi altyazı alanında kalan karoları dışlıyordu; alanın kenarına taşan satırın karoları (iki
/// satırlı altyazının alan dışında kalan üst satırı, alandan geniş satırın uçları) aday oluyor, bulunan alan yarım/bir
/// karo genişletildiği için altyazının kendisini de okuyordu. Hazır GTA 6 mesaj alanı da (0,72–0,99 x 0,45–0,80)
/// varsayılan altyazı alanıyla (0,14–0,86 x 0,62–0,97) kesişiyor, geniş altyazının sağ ucunu okuyordu. Görev satırının
/// bölgesi de (<see cref="MissionLine"/>) altyazı alanının içindedir; görev kalkıp yerine altyazı gelince altyazı orada
/// da okunuyordu.
/// <para>
/// Kural: ekran yazısı okumasında altyazı alanında altyazı satırının yerine düşen satır (bkz.
/// <see cref="IsSubtitlePlace"/>), son altyazı satırının hemen üstüne/altına taşan aynı boydaki satır ve altyazı hattının
/// son <see cref="WindowMs"/> içinde okuduğu metne benzeyen satır atılır. Menü durumunda ve görev satırının kendi alanında
/// yalnız metin eşleşmesi uygulanır (menü satırları altyazı alanında da olabilir; görev satırı altyazı alanının içindedir).
/// Karede okunan kendi çevirimiz de (OBS Program projektörü, bkz. <see cref="OwnSubtitles"/>) metinden atılır. Mac/iPhone (SubtitleEcho.swift) ve
/// Android (SubtitleEcho.kt) aynı kuralları uygular. İş parçacığı güvenlidir.
/// </para>
/// </summary>
public sealed class SubtitleEcho
{
    /// <summary>Altyazı hattının okuduğu metin bu kadar süre hatırlanır (ekran yazısı turu 0,5–1 sn arayla okur).</summary>
    public const int WindowMs = 6000;
    /// <summary>Altyazı satırına bitişik satır kuralı bu kadar süre geçerlidir (altyazı ekrandayken).</summary>
    public const int AdjacentMs = 1500;
    /// <summary>Kısa okuma, uzun satırın parçası sayılmak için en az bu kadar harf/rakam taşımalı…</summary>
    internal const int PartMinimum = 10;
    /// <summary>…ve uzun satırın en az bu kadarı olmalı (altyazıda geçen kısa görev yazısı "Get to the docks" atılmasın).</summary>
    internal const double PartShare = 0.4;
    /// <summary>Bu kadar büyük altyazı alanı (Tam ekran) yerle dışlanmaz.</summary>
    internal const double WholeScreen = 0.6;

    private sealed class Line(string text, TextBox? box, long at)
    {
        public string Text { get; } = text;
        public TextBox? Box { get; set; } = box;
        public long At { get; set; } = at;
    }

    private readonly object gate = new();
    private readonly Func<long> clock;
    private readonly List<Line> lines = [];
    private CropRegion? region;
    private OwnSubtitles? own;

    /// <summary>Altyazı hattının gösterdiği çeviriler (hat verir): karede okunan kendi altyazımız ekran yazısı olarak da çevrilmez.</summary>
    public OwnSubtitles? Own
    {
        get { lock (gate) return own; }
        set { lock (gate) own = value; }
    }

    public SubtitleEcho(Func<long>? clock = null) => this.clock = clock ?? (() => Environment.TickCount64);

    /// <summary>Altyazı hattı her işlediği karede çağırır: <paramref name="block"/> altyazı bloğunun satırları (yeri <paramref name="region"/>'a oranla).</summary>
    public void Record(Reading block, CropRegion region)
    {
        var time = clock();
        var place = new TextBox(region.Left, region.Top, region.Right, region.Bottom);
        lock (gate)
        {
            this.region = region;
            foreach (var line in block.Lines)
            {
                var text = TextMatch.Normalize(IconText.Plain(line.Text));
                if (text.Length < 3) continue;
                var box = line.Box?.PlacedIn(place);
                var existing = lines.FirstOrDefault(item => item.Text == text);
                if (existing is not null)
                {
                    existing.At = time;
                    existing.Box = box ?? existing.Box;
                }
                else lines.Add(new Line(text, box, time));
            }
            lines.RemoveAll(item => time - item.At > WindowMs);
            if (lines.Count > 64) lines.RemoveRange(0, lines.Count - 64);
        }
    }

    /// <summary>Okuma durdu ya da hat sıfırlandı.</summary>
    public void Reset()
    {
        lock (gate)
        {
            lines.Clear();
            region = null;
        }
    }

    /// <summary>Altyazı hattı son <see cref="WindowMs"/> içinde bir altyazı okudu ("Ekranı çevir" yer kuralını yalnız o zaman uygular).</summary>
    public bool HasRecent
    {
        get
        {
            var time = clock();
            lock (gate) return lines.Any(item => time - item.At <= WindowMs);
        }
    }

    /// <summary><paramref name="text"/> altyazı hattının son <see cref="WindowMs"/> içinde okuduğu bir satıra benziyor ya da onun parçası/bütünü.</summary>
    public bool IsEcho(string text)
    {
        if (Own?.IsOwn(text) == true) return true;
        var probe = TextMatch.Normalize(IconText.Plain(text));
        if (probe.Length < 3) return false;
        var time = clock();
        lock (gate)
            return lines.Any(line =>
            {
                if (time - line.At > WindowMs) return false;
                if (TextMatch.IsSimilar(probe, line.Text, 0.8)) return true;
                var (shorter, longer) = probe.Length <= line.Text.Length ? (probe, line.Text) : (line.Text, probe);
                return shorter.Length >= PartMinimum && shorter.Length >= PartShare * longer.Length
                    && longer.Contains(shorter, StringComparison.Ordinal);
            });
    }

    /// <summary>
    /// Karedeki (0..1) kutu altyazının yerinde mi: altyazı alanında (merkezi içinde ya da alanının en az yarısı) ve altyazı
    /// hattının son <see cref="WindowMs"/> içinde okuduğu bir satırın üstünde (<see cref="SameRow"/>), ya da son altyazı
    /// satırının hemen üstüne/altına taşan aynı boyda bir satır.
    /// <para>
    /// Alanın tamamı dışlanmaz. Kullanıcı bildirimi (X, beta.69, GTA 6): "Ekranı çevir" altyazıyı çeviriyor, telefon
    /// mesajlarını çevirmiyordu. Sağ alttaki telefon kartı (0,72–0,99 x 0,45–0,80) varsayılan altyazı alanıyla
    /// (0,14–0,86 x 0,62–0,97) kesişiyor; altyazı okunurken kartın 0,62'nin altındaki mesaj satırlarının merkezi alanın
    /// içinde kaldığı için hepsi atılıyordu (hazır mesaj alanında da). Altyazının kendisi metinle, alan kenarına taşan
    /// ve alana düşen parçaları altyazı satırının yerinden tanınır.
    /// </para>
    /// </summary>
    public bool IsSubtitlePlace(TextBox box)
    {
        var time = clock();
        lock (gate)
        {
            // Tam ekran (ya da ekranın çoğu) altyazı alanıyken yer kuralı uygulanmaz; metin eşleşmesi yeter.
            if (region is { } area && (area.Right - area.Left) * (area.Bottom - area.Top) < WholeScreen && Inside(box, area)
                && lines.Any(line => time - line.At <= WindowMs && line.Box is { } other && SameRow(box, other)))
                return true;
            return lines.Any(line => time - line.At <= AdjacentMs && line.Box is { } other && Adjacent(box, other));
        }
    }

    /// <summary>
    /// Kutu altyazı satırıyla aynı sırada (dikeyde örtüşüyor ya da arada satır boyunun yarısından az boşluk) ve yatayda
    /// dardakinin en az %80'i örtüşüyor: altyazının kendisi, parçası ya da aynı yere gelen yeni altyazı. Telefon kartının
    /// satırı geniş altyazıyla aynı sıradaysa bile yalnız ucu örtüşür, atılmaz.
    /// </summary>
    internal static bool SameRow(TextBox box, TextBox line)
    {
        double height = Math.Max(box.Bottom - box.Top, line.Bottom - line.Top);
        var gap = Math.Max(box.Top - line.Bottom, line.Top - box.Bottom);
        var overlap = Math.Min(box.Right, line.Right) - Math.Max(box.Left, line.Left);
        var narrower = Math.Min(box.Right - box.Left, line.Right - line.Left);
        return height > 0 && narrower > 0 && gap <= height * 0.5 && overlap >= narrower * 0.8;
    }

    /// <summary>
    /// Ekran yazısı okumasından altyazıya ait satırlar çıkarılmış hali. <paramref name="place"/>: okumanın karedeki yeri
    /// (satır kutuları ona oranla; verilmezse bütün kare). <paramref name="geometry"/>: yerle de dışla (menü durumu ve
    /// görev alanı dışında); metin eşleşmesi her zaman uygulanır.
    /// </summary>
    public Reading Filter(Reading reading, TextBox? place = null, bool geometry = true)
    {
        var frame = place ?? new TextBox(0, 0, 1, 1);
        var kept = reading.Lines.Where(line =>
            !IsEcho(line.Text) && !(geometry && line.Box is { } box && IsSubtitlePlace(box.PlacedIn(frame)))).ToList();
        return kept.Count == reading.Lines.Count ? reading : new Reading(kept);
    }

    internal static bool Inside(TextBox box, CropRegion region)
    {
        double x = (box.Left + box.Right) / 2, y = (box.Top + box.Bottom) / 2;
        if (x >= region.Left && x <= region.Right && y >= region.Top && y <= region.Bottom) return true;
        var w = Math.Min(box.Right, region.Right) - Math.Max(box.Left, region.Left);
        var h = Math.Min(box.Bottom, region.Bottom) - Math.Max(box.Top, region.Top);
        var area = (box.Right - box.Left) * (box.Bottom - box.Top);
        return w > 0 && h > 0 && area > 0 && w * h >= 0.5 * area;
    }

    /// <summary>
    /// Aynı boyda (±%30), yatayda örtüşen ve dikeyde en çok bir satır boyu aralıklı iki satır (iki satırlı altyazının alan
    /// dışında kalan satırı).
    /// </summary>
    internal static bool Adjacent(TextBox box, TextBox line)
    {
        double a = box.Bottom - box.Top, b = line.Bottom - line.Top;
        if (a <= 0 || b <= 0 || Math.Max(a, b) > Math.Min(a, b) * 1.3) return false;
        var gap = Math.Max(box.Top - line.Bottom, line.Top - box.Bottom);
        var overlap = Math.Min(box.Right, line.Right) - Math.Max(box.Left, line.Left);
        return gap <= b && overlap > 0.3 * Math.Min(box.Right - box.Left, line.Right - line.Left);
    }
}
