// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// GTA 6'nın sağ alttaki bildirim kartı (gelen arama "Withheld Number", mesaj önizlemesi, uyarı): açık renkli, köşesi
/// yuvarlak düz kart; solda simge, üstte kalın başlık, altında koyu yazılı gövde. Kullanıcı bildirimi (GitHub #1443, X'te
/// başkaları da: "sağ alt mesajlar çevrilmiyor"): kartın yalnız başlığı (otomatik ekran yazısı) çevriliyor, gövdesi hiç
/// çevrilmiyordu. İki neden: kenar bildirimi yolu (<see cref="ScreenNotices"/>) yalnız altyazı alanı "Tam ekran"ken
/// çalışıyordu; alt şerit altyazı alanı kartın bir kısmını kesince gövde "koyu yazı açık zeminde (kâğıt/tabela)"
/// (<see cref="InkTone"/>) sayılıp atılıyordu. Otomatik ekran yazısı da menü dışında yalnız koyu zemindeki açık yazıyı bulur.
///
/// Artık oyun GTA 6 iken (ekran yazısı ya da telefon çevirisi açık) altyazı alanında okunan blok, sahne yazısı
/// süzgeçlerinden ve görev/HUD ayıklamasından önce kart mı diye bakılır (<see cref="Split"/>): bloğun kutusu karenin
/// sağında (<see cref="IsCandidate"/>) ve karede çevresinde düz, açık renkli, kapalı bir kart bulunuyor (<see cref="Bounds"/>).
/// Kart blokları altyazıya girmez; kartın bütün yeri (alan kartı kesse de) "auto-notice-&lt;n&gt;" ek alanı olur
/// (<see cref="ScreenNotices.Observe"/>), başlık ve gövde kendi yerinde, kartın üstüne örtülerek çevrilir. Altyazı alanının
/// ortasındaki kâğıt ilan ve tabela kart sayılmaz; onları <see cref="InkTone"/> atmaya devam eder.
///
/// Kart araması karenin <see cref="GridWidth"/> × <see cref="GridHeight"/> örnek ağında yapılır (karenin çözünürlüğünden
/// bağımsız): kutunun içinin üst çeyreği kartın zemini (en az <see cref="LightGround"/>), kutu her yöne bir örnek
/// satırı/sütunu kadar büyütülür; büyütülen satırın en az <see cref="GroundShare"/> kadarı zemin, en çok
/// <see cref="OtherShare"/> kadarı zeminden de mürekkepten de farklıysa satır kartındır. Kart kapalıdır: dört yanının en çok
/// <see cref="EdgeReach"/> örnek dışında kart rengi biter, karenin kenarına değmez, boyu sınırlıdır, sağ kenarı karenin
/// sağına yakındır. Kartın kutusunda kendi başına aranamayan blok (simgenin yanındaki kısa başlık) bulunan kartın içindeyse
/// o karta katılır. Mac/iPhone (NoticeCard.swift) ve Android (NoticeCard.kt) aynı kuralları ve eşikleri uygular; ortak
/// deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/notice-card.json.
/// </summary>
public static class NoticeCard
{
    public const int GridWidth = 480;
    public const int GridHeight = 270;
    /// <summary>Kartın zemini (kutunun içinin üst çeyreği) en az bu kadar açık. Kart yarı saydam beyazdır: gündüz ~230, gece ~150.</summary>
    public const int LightGround = 120;
    public const int Tolerance = 24;
    public const int InkGap = 60;
    public const double GroundShare = 0.3;
    public const double OtherShare = 0.15;
    public const double MinInk = 0.03;
    public const double MaxInk = 0.5;
    public const double MinLeft = 0.5;
    public const double MinCenter = 0.6;
    public const double MinRight = 0.85;
    public const double MaxRight = 0.995;
    public const double CardLeft = 0.45;
    public const double MinWidth = 0.1;
    public const double MaxWidth = 0.35;
    public const double MinHeight = 0.04;
    public const double MaxHeight = 0.35;
    public const double EdgeShare = 0.5;
    public const int EdgeReach = 3;
    public const int Margin = 2;

    /// <summary>Altyazı hattı bildirim kartı arar mı: çeviri sürüyor, oyun GTA 6 ve ekran yazısı ya da telefon çevirisi açık.</summary>
    public static bool Enabled(bool running, string? game, bool screenText, bool phone) =>
        running && game is not null && GameName.Key(game) == "gta 6" && (screenText || phone);

    /// <summary>Blok kutusu (karede) bildirim kartı adayı mı: karenin sağında.</summary>
    public static bool IsCandidate(TextBox box) =>
        box.Right > box.Left && box.Bottom > box.Top && box.Left >= MinLeft && (box.Left + box.Right) / 2 >= MinCenter;

    /// <summary><paramref name="box"/> (karede) çevresindeki bildirim kartının karedeki yeri; kart yoksa null.</summary>
    public static TextBox? Bounds(TextBox box, int width, int height, Func<int, int, int> luma)
    {
        if (width <= 0 || height <= 0 || !IsCandidate(box)) return null;
        const int gw = GridWidth, gh = GridHeight;
        int Sample(int gx, int gy)
        {
            var x = Math.Min(width - 1, (int)((gx + 0.5) * width / gw));
            var y = Math.Min(height - 1, (int)((gy + 0.5) * height / gh));
            return Math.Clamp(luma(x, y), 0, 255);
        }
        var l = Math.Clamp((int)(box.Left * gw), 0, gw - 1);
        var r = Math.Clamp((int)(box.Right * gw) - 1, 0, gw - 1);
        var t = Math.Clamp((int)(box.Top * gh), 0, gh - 1);
        var b = Math.Clamp((int)(box.Bottom * gh) - 1, 0, gh - 1);
        if (r - l < 2 || b - t < 1) return null;
        var inside = new List<int>();
        for (var gy = t; gy <= b; gy++) for (var gx = l; gx <= r; gx++) inside.Add(Sample(gx, gy));
        var sorted = inside.Order().ToList();
        var ground = sorted[inside.Count * 3 / 4];
        if (ground < LightGround) return null;
        var ink = (double)inside.Count(v => v <= ground - InkGap) / inside.Count;
        if (ink < MinInk || ink > MaxInk) return null;
        bool IsCard(List<int> values)
        {
            int flat = 0, other = 0;
            foreach (var value in values)
            {
                if (Math.Abs(value - ground) <= Tolerance) flat++;
                else if (value > ground - InkGap) other++;
            }
            return flat >= GroundShare * values.Count && other <= OtherShare * values.Count;
        }
        List<int> Column(int gx) { var v = new List<int>(); for (var gy = t; gy <= b; gy++) v.Add(Sample(gx, gy)); return v; }
        List<int> Row(int gy) { var v = new List<int>(); for (var gx = l; gx <= r; gx++) v.Add(Sample(gx, gy)); return v; }
        var (l0, t0, b0) = (l, t, b);
        var grew = true;
        while (grew)
        {
            grew = false;
            if (r + 1 < gw && IsCard(Column(r + 1))) { r++; grew = true; }
            if (l > 0 && IsCard(Column(l - 1))) { l--; grew = true; }
            if (t > 0 && IsCard(Row(t - 1))) { t--; grew = true; }
            if (b + 1 < gh && IsCard(Row(b + 1))) { b++; grew = true; }
        }
        // Kart kapalıdır: karenin kenarına dayanmaz (açık gökyüzü, kar), yazının çevresinde kart payı vardır.
        if (l <= 0 || t <= 0 || r + 1 >= gw || b + 1 >= gh || l0 - l < Margin || (t0 - t) + (b - b0) < Margin) return null;
        bool Apart(List<int> values) => values.Count(v => Math.Abs(v - ground) <= Tolerance) <= EdgeShare * values.Count;
        // Kenarın hemen dışı yumuşak geçiş (kenar çizgisi, gölge) olabilir: en çok EdgeReach örnek dışarıda kart rengi biter.
        var reach = Enumerable.Range(1, EdgeReach).ToList();
        var outside = new[]
        {
            reach.Select(d => Column(Math.Max(0, l - d))), reach.Select(d => Column(Math.Min(gw - 1, r + d))),
            reach.Select(d => Row(Math.Max(0, t - d))), reach.Select(d => Row(Math.Min(gh - 1, b + d))),
        };
        if (!outside.All(side => side.Any(Apart))) return null;
        var card = new TextBox((double)l / gw, (double)t / gh, (double)(r + 1) / gw, (double)(b + 1) / gh);
        double w = card.Right - card.Left, h = card.Bottom - card.Top;
        if (card.Right < MinRight || card.Right > MaxRight || card.Left < CardLeft
            || w < MinWidth || w > MaxWidth || h < MinHeight || h > MaxHeight) return null;
        return card;
    }

    /// <summary>
    /// Okumanın (satır kutuları <paramref name="area"/>'ya oranlı) bildirim kartı blokları ile kalan satırları.
    /// <paramref name="card"/>: blok kutusu (karede) için kartın karedeki yeri. Aynı karta düşen bloklar (başlık ve gövde)
    /// tek karttır. Kart blokları karede (satır kutuları kareye oranlı) döner; kalan satırlar okumadaki sırasıyla.
    /// </summary>
    public static (Reading Kept, List<(Reading Block, TextBox Card)> Cards) Split(Reading reading, TextBox area,
                                                                                  Func<TextBox, TextBox?> card)
    {
        if (reading.Lines.Count == 0 || reading.Lines.Any(line => line.Box is null)) return (reading, []);
        var taken = new HashSet<TextLine>(ReferenceEqualityComparer.Instance);
        var cards = new List<(List<TextLine> Lines, TextBox Card)>();
        var missed = new List<(List<TextLine> Lines, TextBox Box)>();
        foreach (var block in Reading.Blocks(reading.Lines, area))
        {
            var box = block.Select(line => line.Box!.Value.PlacedIn(area)).Aggregate((a, c) => a.Union(c));
            if (!IsCandidate(box)) continue;
            if (card(box) is not { } found)
            {
                missed.Add((block, box));
                continue;
            }
            var at = cards.FindIndex(entry => Overlaps(entry.Card, found));
            if (at >= 0) cards[at] = ([.. cards[at].Lines, .. block], cards[at].Card.Union(found));
            else cards.Add((block, found));
            foreach (var line in block) taken.Add(line);
        }
        if (cards.Count == 0) return (reading, []);
        // Kartın içinde kalan öteki blok (simgenin yanındaki kısa başlık) da o karttır; kendi başına kart aranamasa da.
        foreach (var (lines, box) in missed)
        {
            var at = cards.FindIndex(entry => Contains(entry.Card, box));
            if (at < 0) continue;
            cards[at] = ([.. cards[at].Lines, .. lines], cards[at].Card);
            foreach (var line in lines) taken.Add(line);
        }
        var kept = new Reading(reading.Lines.Where(line => !taken.Contains(line)));
        var order = reading.Lines.Select((line, index) => (line, index)).ToDictionary(p => (object)p.line, p => p.index,
                                                                                         ReferenceEqualityComparer.Instance);
        return (kept, cards.Select(entry => (new Reading(entry.Lines.OrderBy(line => order[line])).PlacedIn(area), entry.Card)).ToList());
    }

    /// <summary>Kutu kartın içinde mi (yazı tanımanın kutu payıyla).</summary>
    internal static bool Contains(TextBox card, TextBox box)
    {
        const double pad = 0.005;
        return box.Left >= card.Left - pad && box.Right <= card.Right + pad && box.Top >= card.Top - pad && box.Bottom <= card.Bottom + pad;
    }

    /// <summary>İki kart aynı mı: küçüğünün alanının en az yarısı kadar örtüşüyor.</summary>
    internal static bool Overlaps(TextBox a, TextBox b)
    {
        var w = Math.Min(a.Right, b.Right) - Math.Max(a.Left, b.Left);
        var h = Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top);
        if (w <= 0 || h <= 0) return false;
        var smaller = Math.Min((a.Right - a.Left) * (a.Bottom - a.Top), (b.Right - b.Left) * (b.Bottom - b.Top));
        return w * h >= 0.5 * smaller;
    }

    /// <summary>Bütün kare (BGRA) için kart araması (<see cref="Bounds"/>); sağda aday blok yoksa kareye hiç bakılmaz.</summary>
    public static Func<TextBox, TextBox?> Sampler(Frame frame) => box =>
        !IsCandidate(box) || !frame.IsConsistent ? null : Bounds(box, frame.Width, frame.Height, (x, y) =>
        {
            var p = (y * frame.Stride) + (x * 4);
            int b = frame.Pixels[p], g = frame.Pixels[p + 1], r = frame.Pixels[p + 2];
            return ((299 * r) + (587 * g) + (114 * b)) / 1000;
        });
}
