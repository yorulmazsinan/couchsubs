// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Menü ekranında çevirinin biçimi ayardan gelir, her okumada yeniden seçilmez (#1365, Ayarlar › Ekran yazıları ›
/// "Menülerde İngilizcenin üstünü ört"). beta.105 testinde GTA 6 haritasında aynı satır art arda okumalarda örtü, yan,
/// üst/alt ya da haritada yüzen ikiz kutu oluyordu (5 dakikada 237 yan, 139 örtü, 37 ikiz): <see cref="TextPainter"/> kipi
/// satırın çevresindeki boş alana ve zemin desenine göre seçiyor, kayan harita ve seçim çubuğu bunları her karede
/// değiştiriyordu.
/// </summary>
/// <remarks>
/// Menüdeki otomatik alanın çizimleri <see cref="TextPainter"/>'ın ölçtüğü örtü kutusu, zemin ve yazı rengiyle kalır; yalnız
/// yerleşim kilitlenir. Yerleşim yalnız yazıların kutularından çıkar (kare noktalarına bakılmaz): aynı ekran her okumada
/// aynı çizilir.
/// <list type="bullet">
/// <item>B, üstünü ört (<c>cover</c>): her yazı kendi yerinde, ölçülen zemin renginde örtülür; kartın başlığı ve metni ayrı
/// ayrı örtülür, kişi resmi ve simgeler açıkta kalır.</item>
/// <item>A, yanına yaz (varsayılan): her satırın Türkçesi İngilizcesinin hemen yanına, koyu zeminli etikete (<c>label</c>)
/// yazılır: sola yaslı satırda sağına, sağa yaslı satırda (tuş çubuğu) soluna; satırın simgesi ve komşu yazılar örtülmez.
/// Yanına sığmayan etiket (sekme şeridi, sıkışık tuş çubuğu) altına, olmazsa üstüne yazılır; şeridin bir sekmesi altına
/// yazıldıysa öbür sekmeler de altına, biri hiçbir yere sığmazsa şeridin hepsi örtülür (şerit bir bütün). Listede
/// Türkçeler tek sütunda başlar (sola yaslı listede en uzun satırın sağında). Hiçbir yere sığmayan satır örtülür.
/// Haritanın görev kartının (<c>cards</c>) çevirisi kartın hemen altına (yer yoksa üstüne), kartın zemininde, kişi
/// resmiyle ikiz kart olarak gelir; ikisine de yer yoksa ya da kart bir listenin parçasıysa (Görevler ekranı: sol kenarı
/// kartla hizalı başka yazılar) kartın satırları da yanına yazılır.</item>
/// <item>İki biçimde de satırın üstüne/altına küçük yazma, haritaya uzak ikiz kutu ve iki satırı tek kutuda birleştirme
/// olmaz; etiketler başka yazının ya da ikiz kartın üstüne binmez.</item>
/// </list>
/// Kutular kareye oranla (0…1); <c>aspect</c>: karenin genişlik/yükseklik oranı. Mac (MenuLayout.swift) ve Android
/// (MenuLayout.kt) aynı kuralı, aynı eşikleri kullanır; ortak deneme dosyası Fixtures/menu-layout.json.
/// </remarks>
public static class MenuLayout
{
    /// <summary>Yanına yazılan Türkçenin etiket zemini (TV yarı saydam çizer, yazı açık renk).</summary>
    public const string LabelColor = "#121419";
    /// <summary>Türkçe ile İngilizce (ya da satırın simgesi) arası, satır yüksekliğinin katı.</summary>
    public const double GapLines = 0.4;
    /// <summary>Satırın yanındaki simge okunan kutuda değilse simge için bırakılan yer, satır yüksekliğinin katı.</summary>
    public const double IconLines = 1.2;
    /// <summary>Yanına yazılan Türkçenin en çok uzayabileceği yer: İngilizcenin BesideMax katı artı bir satır, en az ReachLines.</summary>
    public const double BesideMax = 1.6;
    public const double ReachLines = 12.0;
    /// <summary>Yanında bu kadar yer (İngilizcenin genişliğinin payı) yoksa Türkçe altına/üstüne yazılır.</summary>
    public const double RoomShare = 0.6;
    /// <summary>Aynı satırda sayılmak için dikey örtüşme (kısa kutunun payı).</summary>
    public const double SameRow = 0.3;
    /// <summary>
    /// Etiket bir yazıya ancak etiketin boyunun bu payından çok binerse çakışır (sıkışık listede komşu satırların okunan
    /// kutuları birkaç nokta örtüşür).
    /// </summary>
    public const double TouchShare = 0.25;
    /// <summary>Aynı satırda bu kadar yakın (satır yüksekliğinin katı) iki yazı tek şerittir: biri altına/üstüne yazıldıysa öbürü de.</summary>
    public const double StripGapLines = 4.0;
    /// <summary>Ekran kenarından bırakılan pay, satır yüksekliğinin katı.</summary>
    public const double EdgeLines = 0.2;
    /// <summary>İkiz kartın kart yazılarının çevresindeki iç boşluğu ve kartla arası, satır yüksekliğinin katı.</summary>
    public const double CardPadLines = 0.5;
    public const double CardGapLines = 0.3;
    /// <summary>Kart dışı bir yazının sol kenarı kartınkine bu kadar yakınsa (satır yüksekliğinin katı) kart bir listenin parçasıdır.</summary>
    public const double ColumnLines = 1.0;
    /// <summary>Alt alta iki satır bu kadar (satır yüksekliğinin katı) aralıkla aynı listenin sütunundadır.</summary>
    public const double ColumnGapLines = 1.5;

    /// <summary>
    /// Menüdeki çizimler ayardaki biçime kilitlenir. <paramref name="cards"/>: görev kartlarının parçaları (her kart için
    /// <paramref name="paints"/> sıraları); <paramref name="cover"/>: B (üstünü ört), false: A (yanına yaz).
    /// <paramref name="portrait"/>: ikiz kurulacak kartın parçalarında kişi resmi yoksa kartın parçaları ve zemini verilip resim
    /// (kutusu ve kesilmiş görüntüsü) kareden aranır (<see cref="TextPainter.CardPortrait(IReadOnlyList{TextBox}, IReadOnlyList{int}, string, double, Frame)"/>;
    /// ikiz kart resimsiz kalmasın).
    /// </summary>
    public static List<TextPaint> Locked(IReadOnlyList<TextPaint> paints, IReadOnlyList<TextPainter.Target> targets,
                                         IReadOnlyList<IReadOnlyList<int>> cards, bool cover, double aspect,
                                         Func<IReadOnlyList<int>, string, (TextBox Box, string? Image)?>? portrait = null)
    {
        if (paints.Count != targets.Count || paints.Count == 0) return paints.ToList();
        var result = paints.Select(Plain).ToList();
        if (cover) return result;
        var taken = Enumerable.Range(0, paints.Count).Select(i => paints[i].Cover.Union(targets[i].Box)).ToList();
        var done = new HashSet<int>();
        var twins = new List<TextBox>();
        foreach (var raw in cards)
        {
            // Kutusu boş (genişliği ya da yüksekliği olmayan) parça ikize girmez.
            var card = raw.Where(m => m >= 0 && m < paints.Count && !done.Contains(m)
                && paints[m].Cover.Right - paints[m].Cover.Left > 1e-9 && paints[m].Cover.Bottom - paints[m].Cover.Top > 1e-9).ToList();
            if (card.Count == 0) continue;
            var made = CardTwin(card, paints, targets, taken, twins, aspect, portrait);
            if (made is null) continue;
            foreach (var (m, paint) in made) result[m] = paint;
            done.UnionWith(card);
            twins.Add(made[0].Paint.Twin!.Value);
        }
        var vertical = new HashSet<int>();
        var basis = result.ToList();
        for (var i = 0; i < paints.Count; i++)
        {
            if (done.Contains(i)) continue;
            var (paint, below) = Beside(i, paints, targets, taken, twins, aspect, basis[i], side: true);
            result[i] = paint;
            if (below) vertical.Add(i);
        }
        var free = Enumerable.Range(0, paints.Count).Where(i => !done.Contains(i)).ToList();
        // Şerit bir bütün: aynı satırda yakın yazılar (sekme şeridi, tuş çubuğu) tek biçimde çizilir. Hepsi yanına sığıyorsa
        // yanına; değilse hepsi altına/üstüne; biri de sığmazsa hepsi örtülür (şeritte kimi Türkçe yanında, kimi altında, kimi
        // örtülü kalıyordu).
        foreach (var strip in Strips(free, paints, targets, taken, aspect))
        {
            if (strip.Count < 2 || strip.All(i => result[i].Mode == PaintMode.Beside && !vertical.Contains(i))) continue;
            var tried = strip.Select(i => Beside(i, paints, targets, taken, twins, aspect, basis[i], side: false)).ToList();
            var below = tried.All(t => t.Below);
            for (var k = 0; k < strip.Count; k++)
            {
                result[strip[k]] = below ? tried[k].Paint : basis[strip[k]];
                if (below) vertical.Add(strip[k]);
                else vertical.Remove(strip[k]);
            }
        }
        // Liste bir sütun: alt alta, aynı yana yaslı satırların yanına yazılan Türkçeleri tek sütunda başlar (sola yaslı
        // listede en uzun satırın sağında, sağa yaslı listede en uzun satırın solunda). Bir satıra orada yer yoksa liste
        // her satırın yanında kalır.
        var side = free.Where(i => result[i].Mode == PaintMode.Beside && !vertical.Contains(i) && result[i].Spot is not null).ToList();
        foreach (var right in new[] { false, true })
        {
            var members = side.Where(i => (targets[i].Align == "right") == right)
                .OrderBy(i => paints[i].Cover.Top).ThenBy(i => i).ToList();
            var used = new HashSet<int>();
            foreach (var start in members)
            {
                if (!used.Add(start)) continue;
                var column = new List<int> { start };
                foreach (var b in members)
                {
                    if (used.Contains(b)) continue;
                    var last = column[^1];
                    var line = Math.Max(targets[last].LineHeight, targets[b].LineHeight);
                    var edgeA = right ? taken[start].Right : taken[start].Left;
                    var edgeB = right ? taken[b].Right : taken[b].Left;
                    if (Math.Abs(edgeA - edgeB) <= ColumnLines * line / Math.Max(0.1, aspect)
                        && paints[b].Cover.Top >= paints[last].Cover.Top
                        && paints[b].Cover.Top - paints[last].Cover.Bottom <= ColumnGapLines * line)
                    {
                        used.Add(b);
                        column.Add(b);
                    }
                }
                if (column.Count < 2) continue;
                var x = right ? column.Min(i => result[i].Spot!.Value.Right) : column.Max(i => result[i].Spot!.Value.Left);
                var aligned = column.Select(i => BesideAt(i, x, right, paints, targets, taken, twins, aspect, result[i])).ToList();
                if (aligned.Any(p => p is null)) continue;
                for (var k = 0; k < column.Count; k++) result[column[k]] = aligned[k]!;
            }
        }
        return result;
    }

    /// <summary>
    /// Aynı satırda birbirine yakın (aralarında en çok <see cref="StripGapLines"/> satır) yazıların şeritleri; zincirleme
    /// (sekme şeridinin bütün sekmeleri). Sıra <paramref name="free"/> sırası.
    /// </summary>
    internal static List<List<int>> Strips(IReadOnlyList<int> free, IReadOnlyList<TextPaint> paints, IReadOnlyList<TextPainter.Target> targets,
                                           IReadOnlyList<TextBox> taken, double aspect)
    {
        var strips = new List<List<int>>();
        var seen = new HashSet<int>();
        foreach (var start in free)
        {
            if (!seen.Add(start)) continue;
            var strip = new List<int> { start };
            for (var q = 0; q < strip.Count; q++)
            {
                var a = strip[q];
                foreach (var b in free)
                {
                    if (seen.Contains(b)) continue;
                    TextBox ca = paints[a].Cover, cb = paints[b].Cover;
                    var lineX = Math.Max(1e-6, Math.Min(targets[a].LineHeight, targets[b].LineHeight)) / Math.Max(0.1, aspect);
                    if (OverlapY(ca, cb) >= SameRow * Math.Min(ca.Bottom - ca.Top, cb.Bottom - cb.Top)
                        && Math.Max(0, Math.Max(taken[a].Left, taken[b].Left) - Math.Min(taken[a].Right, taken[b].Right)) <= StripGapLines * lineX)
                    {
                        seen.Add(b);
                        strip.Add(b);
                    }
                }
            }
            strips.Add(strip);
        }
        return strips;
    }

    /// <summary>Satırın kendi kutusu simgesiyle birlikte (okunan kutu); simge okunmadıysa simge tarafına simge kadar yer.</summary>
    internal static TextBox Own(int i, IReadOnlyList<TextPaint> paints, IReadOnlyList<TextBox> taken, double lineX)
    {
        var c = paints[i].Cover;
        var own = taken[i];
        if (paints[i].IconSide == "left" && c.Left - own.Left < 0.5 * IconLines * lineX) own = own with { Left = c.Left - IconLines * lineX };
        if (paints[i].IconSide == "right" && own.Right - c.Right < 0.5 * IconLines * lineX) own = own with { Right = c.Right + IconLines * lineX };
        return own;
    }

    /// <summary>Satırın engelleri: öbür yazıların kutuları (sırasıyla) ve ikiz kartlar (sıra -1).</summary>
    internal static List<(int J, TextBox Box)> Others(int i, IReadOnlyList<TextBox> taken, IReadOnlyList<TextBox> twins) =>
        [.. Enumerable.Range(0, taken.Count).Where(j => j != i).Select(j => (j, taken[j])), .. twins.Select(t => (-1, t))];

    /// <summary>
    /// Yanına yazılan Türkçenin <paramref name="start"/>'tan (sola yaslıda sol kenarı, sağa yaslıda sağ kenarı) uzayabileceği
    /// son nokta: ekranın kenarı, en çok erişim, satırdaki yazı ya da ikiz kart. Karşıdan bakan komşu (sola yaslı satırın
    /// sağında sağa yaslı değer, "STYLE … SOUVENIR") arayı ortadan böler; ikisinin Türkçesi üst üste binmez.
    /// </summary>
    internal static double Limit(int i, double start, bool right, TextBox own, IReadOnlyList<TextPaint> paints,
                                 IReadOnlyList<TextPainter.Target> targets, IReadOnlyList<(int J, TextBox Box)> others, double aspect)
    {
        var c = paints[i].Cover;
        var lineX = Math.Max(1e-6, targets[i].LineHeight) / Math.Max(0.1, aspect);
        double gap = GapLines * lineX, edge = EdgeLines * lineX, eps = 1e-9, w = c.Right - c.Left;
        var reach = Math.Max(BesideMax * w + lineX, ReachLines * lineX);
        var touch = TouchShare * (c.Bottom - c.Top);
        if (!right)
        {
            var limit = Math.Min(1 - edge, start + reach);
            foreach (var (j, o) in others)
            {
                if (OverlapY(o, c) <= touch || o.Right <= start) continue;
                var facing = j >= 0 && targets[j].Align == "right" && o.Left >= own.Right - eps;
                limit = Math.Min(limit, facing ? (own.Right + o.Left - gap) / 2 : o.Left - gap);
            }
            return limit;
        }
        var low = Math.Max(edge, start - reach);
        foreach (var (j, o) in others)
        {
            if (OverlapY(o, c) <= touch || o.Left >= start) continue;
            var facing = j >= 0 && targets[j].Align != "right" && o.Right <= own.Left + eps;
            low = Math.Max(low, facing ? (o.Right + own.Left + gap) / 2 : o.Right + gap);
        }
        return low;
    }

    /// <summary>
    /// Yanına yazma, Türkçe <paramref name="x"/>'te başlarken (sola yaslıda sol kenarı, sağa yaslıda sağ kenarı; listenin
    /// sütunu): engeller <see cref="Limit"/> ile aynı; yer yoksa null.
    /// </summary>
    internal static TextPaint? BesideAt(int i, double x, bool right, IReadOnlyList<TextPaint> paints, IReadOnlyList<TextPainter.Target> targets,
                                        IReadOnlyList<TextBox> taken, IReadOnlyList<TextBox> twins, double aspect, TextPaint current)
    {
        var c = paints[i].Cover;
        var lineX = Math.Max(1e-6, targets[i].LineHeight) / Math.Max(0.1, aspect);
        var w = c.Right - c.Left;
        var reach = Math.Max(BesideMax * w + lineX, ReachLines * lineX);
        var limit = Limit(i, x, right, Own(i, paints, taken, lineX), paints, targets, Others(i, taken, twins), aspect);
        if (Math.Abs(limit - x) < RoomShare * Math.Min(w, reach) || (right ? limit > x : limit < x)) return null;
        return right
            ? current with { Spot = new TextBox(Math.Max(limit, x - w), c.Top, x, c.Bottom), SpotRoom = new TextBox(limit, c.Top, x, c.Bottom) }
            : current with { Spot = new TextBox(x, c.Top, Math.Min(limit, x + w), c.Bottom), SpotRoom = new TextBox(x, c.Top, limit, c.Bottom) };
    }

    /// <summary>Ölçülen örtü, zemin ve yazı rengi kalır; kip örtmeye döner, yanına yazma ve ikiz alanları silinir.</summary>
    internal static TextPaint Plain(TextPaint paint) => paint with
    {
        Mode = PaintMode.Cover, Spot = null, SpotRoom = null, Twin = null, Radius = 0, Scale = 1, Tail = null,
        Portrait = null, PortraitTwin = null, PortraitImage = null, PortraitSquare = false, Edge = null, Label = null,
    };

    internal static double OverlapY(TextBox a, TextBox b) => Math.Max(0, Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top));

    internal static bool Overlaps(TextBox a, TextBox b) =>
        Math.Min(a.Right, b.Right) > Math.Max(a.Left, b.Left) && Math.Min(a.Bottom, b.Bottom) > Math.Max(a.Top, b.Top);

    internal static TextBox Shifted(TextBox box, double dy) => box with { Top = box.Top + dy, Bottom = box.Bottom + dy };

    /// <summary>
    /// A: satırın Türkçesi yanında (yer yoksa altında ya da üstünde), koyu etikette; hiçbir yere sığmazsa örtü
    /// (<paramref name="basis"/>). <paramref name="side"/>: false ise yanı denenmez (şeridin öbür sekmeleri). Below: Türkçe
    /// altına/üstüne yazıldı.
    /// </summary>
    internal static (TextPaint Paint, bool Below) Beside(int i, IReadOnlyList<TextPaint> paints, IReadOnlyList<TextPainter.Target> targets,
                                                         IReadOnlyList<TextBox> taken, IReadOnlyList<TextBox> twins, double aspect,
                                                         TextPaint basis, bool side)
    {
        var c = paints[i].Cover;
        var lineY = Math.Max(1e-6, targets[i].LineHeight);
        var lineX = lineY / Math.Max(0.1, aspect);
        double gap = GapLines * lineX, edge = EdgeLines * lineX, eps = 1e-9;
        double w = c.Right - c.Left, h = c.Bottom - c.Top;
        // Genişliği ya da yüksekliği olmayan kutu (bozuk okuma) yanına yazılmaz.
        if (w <= eps || h <= eps) return (basis, false);
        var reach = Math.Max(BesideMax * w + lineX, ReachLines * lineX);
        var own = Own(i, paints, taken, lineX);
        var others = Others(i, taken, twins);
        var p = basis with { Mode = PaintMode.Beside, Label = LabelColor };
        var touch = TouchShare * h;
        if (side && targets[i].Align != "right")
        {
            var left = own.Right + gap;
            var limit = Limit(i, left, false, own, paints, targets, others, aspect);
            if (limit - left >= RoomShare * Math.Min(w, reach))
            {
                return (p with
                {
                    Spot = new TextBox(left, c.Top, Math.Min(limit, left + w), c.Bottom),
                    SpotRoom = new TextBox(left, c.Top, limit, c.Bottom),
                }, false);
            }
        }
        else if (side)
        {
            var right = own.Left - gap;
            var limit = Limit(i, right, true, own, paints, targets, others, aspect);
            if (right - limit >= RoomShare * Math.Min(w, reach))
            {
                return (p with
                {
                    Spot = new TextBox(Math.Max(limit, right - w), c.Top, right, c.Bottom),
                    SpotRoom = new TextBox(limit, c.Top, right, c.Bottom),
                }, false);
            }
        }
        // Yanına sığmayan etiket (sekme şeridinin sekmesi, sıkışık tuş çubuğu) altına, olmazsa üstüne; aynı satırdaki
        // komşularla arasının ortasını geçmez (komşunun etiketiyle arada boşluk kalır), başka yazının üstüne binmez, uzadığı
        // alan da o bantta başka yazıya varmaz.
        var mates = Enumerable.Range(0, paints.Count).Where(j =>
            j != i && OverlapY(c, paints[j].Cover) >= SameRow * Math.Min(h, paints[j].Cover.Bottom - paints[j].Cover.Top));
        double l = Math.Max(edge, own.Left - 0.5 * w), r = Math.Min(1 - edge, own.Right + 0.5 * w);
        foreach (var j in mates)
        {
            var o = taken[j];
            if (o.Left >= own.Right - eps) r = Math.Min(r, (own.Right + o.Left) / 2 - gap);
            else if (o.Right <= own.Left + eps) l = Math.Max(l, (o.Right + own.Left) / 2 + gap);
        }
        var step = GapLines * lineY;
        foreach (var top in new[] { own.Bottom + step, own.Top - step - h })
        {
            var spot = new TextBox(c.Left, top, c.Right, top + h);
            if (spot.Top < 0 || spot.Bottom > 1) continue;
            if (others.Any(o => Math.Min(o.Box.Right, spot.Right) > Math.Max(o.Box.Left, spot.Left) && OverlapY(o.Box, spot) > touch)) continue;
            double bandLeft = l, bandRight = r;
            foreach (var (_, o) in others)
            {
                if (OverlapY(o, spot) <= touch) continue;
                if (o.Right <= c.Left + eps) bandLeft = Math.Max(bandLeft, o.Right + gap);
                else if (o.Left >= c.Right - eps) bandRight = Math.Min(bandRight, o.Left - gap);
            }
            return (p with { Spot = spot, SpotRoom = new TextBox(Math.Min(bandLeft, c.Left), top, Math.Max(bandRight, c.Right), top + h) }, true);
        }
        return (basis, false);
    }

    /// <summary>
    /// A: görev kartının ikizi kartın hemen altında (yer yoksa üstünde), kartın zemininde; başka yazının ya da ikizin
    /// üstüne binmez. İkisine de yer yoksa ya da kart bir listenin parçasıysa null (kartın satırları yanına yazılır; Görevler
    /// ekranında son görev ikiz kart, öbürleri yanında çiziliyordu).
    /// </summary>
    internal static List<(int Index, TextPaint Paint)>? CardTwin(IReadOnlyList<int> card, IReadOnlyList<TextPaint> paints,
                                                                IReadOnlyList<TextPainter.Target> targets, IReadOnlyList<TextBox> taken,
                                                                IReadOnlyList<TextBox> twins, double aspect,
                                                                Func<IReadOnlyList<int>, string, (TextBox Box, string? Image)?>? portrait = null)
    {
        var heights = card.Select(m => targets[m].LineHeight).OrderBy(x => x).ToList();
        var line = Math.Max(1e-6, heights[heights.Count / 2]);
        double padY = CardPadLines * line, padX = padY / Math.Max(0.1, aspect);
        var left = card.Min(m => taken[m].Left);
        if (Enumerable.Range(0, paints.Count).Any(j => !card.Contains(j) && Math.Abs(taken[j].Left - left) <= ColumnLines * line / Math.Max(0.1, aspect)))
            return null;
        // Kartın zemini: en büyük parçanın (açıklama) ölçülen zemini.
        static double Area(TextBox b) => (b.Right - b.Left) * (b.Bottom - b.Top);
        var largest = card.Aggregate((a, b) => Area(paints[b].Cover) > Area(paints[a].Cover) ? b : a);
        var fill = paints[largest].Background;
        // Kişi resmi: ölçümün bulduğu ya da kareden aranan; ikizde kartın bütün parçalarında aynı (TV ilkinden çizer).
        var face = card.Select(m => paints[m].Portrait).FirstOrDefault(f => f is not null);
        var image = card.Select(m => paints[m].PortraitImage).FirstOrDefault(i => i is not null);
        if (face is null && portrait?.Invoke(card, fill) is { } found)
        {
            face = found.Box;
            image = found.Image;
        }
        var union = taken[card[0]];
        foreach (var m in card) union = union.Union(taken[m]);
        if (face is { } seen) union = union.Union(seen);
        var box = new TextBox(union.Left - padX, union.Top - padY, union.Right + padX, union.Bottom + padY);
        var step = (box.Bottom - box.Top) + CardGapLines * line;
        var blockers = Enumerable.Range(0, paints.Count).Where(j => !card.Contains(j)).Select(j => taken[j]).Concat(twins).ToList();
        bool Free(TextBox b) => b.Top >= 0 && b.Bottom <= 1 && b.Left >= 0 && b.Right <= 1 && !blockers.Any(o => Overlaps(o, b));
        double dy;
        if (Free(Shifted(box, step))) dy = step;
        else if (Free(Shifted(box, -step))) dy = -step;
        else return null;
        var twin = Shifted(box, dy);
        return card.Select(m =>
        {
            var spot = Shifted(paints[m].Cover, dy);
            var p = Plain(paints[m]) with
            {
                Mode = PaintMode.Twin, Twin = twin, Radius = paints[m].Radius, Background = fill, Background2 = null,
                Direction = null, Patterned = false, Spot = spot,
                SpotRoom = new TextBox(spot.Left, spot.Top, Math.Max(spot.Right, twin.Right - padX), spot.Bottom),
                Edge = paints[m].Edge,
            };
            if (face is { } picture)
            {
                p = p with { Portrait = picture, PortraitTwin = Shifted(picture, dy), PortraitImage = image, PortraitSquare = true };
            }
            return (m, p);
        }).ToList();
    }
}
