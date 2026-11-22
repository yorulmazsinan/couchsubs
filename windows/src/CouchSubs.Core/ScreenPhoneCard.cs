// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// "Ekranı çevir"de GTA 6 telefonu: eğik telefon ekranının üstüne yazmak okunmuyordu (yazı küçük, ekran yamuk). Telefon
/// karede bulunursa (<see cref="GamePhoneGeometry"/>) ekranındaki satırlar düz ekrana taşınıp ayrı gruplanır
/// (<see cref="PhoneChat"/>) ve çevirileri telefonun hemen yanına, ekranda yer olan tarafa, telefon boyunda açık renkli bir
/// "mesaj kartı" olarak dizilir: en üstte kişi adı, altında her mesaj kendi balonunda (giden sağda mavi, gelen solda beyaz),
/// sohbet listesinde ad + önizleme satırları. Balonların yüksekliği Türkçenin kaç satır tutacağına göre hesaplanır, üst üste
/// binmez; kart dolarsa en eski mesajlar düşer. Yanda yer yoksa kart telefonun üstüne konur. Telefon dışındaki yazılar kendi
/// yerlerinde kalır. Kart TV'ye ve masaüstüne sıradan stilli öğeler olarak gider (zemin, başlık, balonlar), ayrı bir çizim
/// gerekmez (Mac: ScreenPhoneCard.swift, Android: ScreenPhoneCard.kt; ortak deneme dosyası Fixtures/phone-chat.json).
/// </summary>
public static class ScreenPhoneCard
{
    /// <summary>Kartın zemini: yazısı yalnız bölünmez boşluk olan öğe, kartın tamamını kaplar; balonlar üstüne çizilir.</summary>
    public const string BackdropText = " ";
    internal static readonly PhoneTextStyle CardColor = new("#F2F2F7", "#1C1C1E");
    internal static readonly PhoneTextStyle IncomingColor = new("#FFFFFF", "#1C1C1E");
    internal static readonly PhoneTextStyle OutgoingColor = new("#0A84FF", "#FFFFFF");
    /// <summary>Telefonla kart arasındaki boşluk ve kartın ekran kenarından payı (ekran genişliğine oranla).</summary>
    internal const double Gap = 0.008;
    /// <summary>Kart için yanda en az bu kadar yer olmalı; yoksa kart telefonun üstüne konur.</summary>
    internal const double MinWidth = 0.12;
    /// <summary>
    /// Kartın istenen eni: telefonun bu katı, en az <see cref="CardMin"/> (yanda yer varsa). Telefon boyundaki dar kartta
    /// Türkçe mesajlar çok satıra bölünüyor, balonlar iç içe görünüyordu.
    /// </summary>
    internal const double CardScale = 1.4, CardMin = 0.22;
    /// <summary>Mesajlar telefon boyuna sığmazsa kart ekranın bu payına kadar yukarı ve aşağı uzar; yine sığmazsa eski mesajlar düşer.</summary>
    internal const double ScreenMargin = 0.03;
    /// <summary>
    /// Balonlar arası boşluk, balonun iç dolgusu (üst + alt toplamı) ve satır aralığı; satır yüksekliğine oranla. TV yazıyı
    /// kutunun üstüne yaslar: dolgu, son satırın altında da boşluk bırakır. Önceden balonlar arası 0,35 satırdı, mesajlar
    /// birbirine yapışık görünüyordu.
    /// </summary>
    internal const double BubbleSpacing = 0.6, BubblePadding = 0.6, LineSpacing = 1.2;
    /// <summary>Balonun kart genişliğine oranı (en çok) ve en az.</summary>
    internal const double BubbleShare = 0.8, BubbleMin = 0.3;
    /// <summary>Kartta yazı boyu (kare yüksekliğine oranla) en az bu: telefonun küçük yazısı TV'de okunsun (1080p'de ~24 nokta).</summary>
    internal const double MinLine = 0.022;
    /// <summary>Bir harfin ortalama genişliği, satır yüksekliğine oranla (TV'nin yazı tipinde Türkçe metinle ölçüldü, ~0,5).</summary>
    internal const double CharWidth = 0.5;

    /// <summary>Telefondaki yazının kartta ne olduğu.</summary>
    public enum Role
    {
        /// <summary>Sohbetin başlığı (kişi adı); çevrilmez.</summary>
        Header,
        /// <summary>Gelen mesaj (sola yaslı balon).</summary>
        Incoming,
        /// <summary>Giden mesaj (sağa yaslı balon).</summary>
        Outgoing,
        /// <summary>Tarafı belirsiz mesaj (rengine bakılır).</summary>
        Message,
        /// <summary>Ortalı kısa satır: saat, "Today", "Delivered".</summary>
        Note,
        /// <summary>Sohbet listesinde kişi adı (çevrilmez).</summary>
        Contact,
        /// <summary>Sohbet listesinde son mesaj önizlemesi.</summary>
        Preview,
        /// <summary>Sohbet listesinde bölüm başlığı ("Messages").</summary>
        Heading,
        /// <summary>Ana ekranın yazısı (bileşen, bildirim): sohbet değildir, karta girmez; kendi yerinde, özgün stilinde çizilir.</summary>
        Home,
    }

    /// <summary>Çevirmene gitmez, aslıyla gösterilir (ad).</summary>
    internal static bool KeepsText(this Role role) => role is Role.Header or Role.Contact;

    /// <summary>Kartta dizilir (ana ekranın yazıları yerinde kalır).</summary>
    internal static bool InCard(this Role role) => role != Role.Home;

    /// <summary>Telefondaki bir grubun rolü ve düz ekrandaki yeri (0–1).</summary>
    public sealed record Placement(Role Role, TextBox Spot);

    /// <summary>
    /// Karedeki telefon: sınır kutusu ve ekranın ekseni (hoparlörden alt çentiğe). Eğik telefonun ekranındaki her nokta düz
    /// ekrana (u: soldan sağa, v: yukarıdan aşağı, 0–1) taşınabilir; <see cref="GamePhoneReader"/>'ın düzeltmesinin tersidir.
    /// </summary>
    public sealed record Handset
    {
        public TextBox Bounds { get; }
        private readonly double topX, topY, bottomX, bottomY;
        /// <summary>Karenin genişliği / yüksekliği.</summary>
        private readonly double aspect;
        /// <summary>Düz ekranın eni / boyu (telefon okuyucusunun ekran oranı: 0,52 / 0,915).</summary>
        internal const double ScreenShape = 0.52 / 0.915;

        internal Handset(GamePhoneGeometry.Pose pose, double aspect)
        {
            var region = pose.Bounds;
            Bounds = new TextBox(region.Left, region.Top, region.Right, region.Bottom);
            (topX, topY, bottomX, bottomY) = (pose.TopX, pose.TopY, pose.BottomX, pose.BottomY);
            this.aspect = aspect;
        }

        /// <summary>Ekranın yüksekliği, kare yüksekliğine oranla.</summary>
        internal double ScreenHeight => (bottomY - topY) * 0.915;

        /// <summary>Karenin genişliği / yüksekliği.</summary>
        internal double Aspect => aspect;

        /// <summary>Düz ekrandaki noktanın karedeki yeri (kenarlara oranla).</summary>
        internal (double X, double Y) Point(double u, double v)
        {
            double dx = bottomX - topX, dy = bottomY - topY;
            double t = 0.04 + 0.915 * v, side = (u - 0.5) * 0.52;
            return (topX + dx * t + side * dy / aspect, topY + dy * t - side * dx * aspect * (0.52 + v * 0.30));
        }

        /// <summary>Karedeki noktanın düz ekrandaki yeri (Newton adımlarıyla; dönüşüm neredeyse doğrusal, dört adım yeter).</summary>
        internal (double U, double V) Screen(double x, double y)
        {
            double dx = bottomX - topX, dy = bottomY - topY;
            double u = 0.5, v = ((y - topY) / dy - 0.04) / 0.915;
            for (var i = 0; i < 4; i++)
            {
                var p = Point(u, v);
                double ex = p.X - x, ey = p.Y - y;
                double a = 0.52 * dy / aspect, b = 0.915 * dx;
                double c = -0.52 * dx * aspect * (0.52 + 0.30 * v), d = 0.915 * dy - (u - 0.5) * 0.52 * dx * aspect * 0.30;
                var det = a * d - b * c;
                if (Math.Abs(det) <= 1e-12) break;
                u -= (d * ex - b * ey) / det;
                v -= (a * ey - c * ex) / det;
            }
            return (u, v);
        }

        /// <summary>
        /// Karedeki satır kutusunun düz ekrandaki yeri. Eğik ekranda okunan kutu satırın eğimini de kapsar: satırın gerçek
        /// yüksekliği kutunun yüksekliğinden eğimin payı düşülerek bulunur.
        /// </summary>
        internal TextBox Flat(TextBox box)
        {
            double cx = (box.Left + box.Right) / 2, cy = (box.Top + box.Bottom) / 2;
            var center = Screen(cx, cy);
            double dx = bottomX - topX, dy = bottomY - topY;
            var slope = (-0.52 * dx * aspect * (0.52 + 0.30 * center.V)) / (0.52 * dy / aspect);
            var left = Screen(box.Left, cy + slope * (box.Left - cx)).U;
            var right = Screen(box.Right, cy + slope * (box.Right - cx)).U;
            var height = box.Bottom - box.Top;
            var upright = Math.Max(height - Math.Abs(slope) * (box.Right - box.Left), height * 0.35);
            var half = upright / ScreenHeight / 2;
            return new TextBox(left, center.V - half, right, center.V + half);
        }
    }

    /// <summary>
    /// Satır (karedeki kutusu) telefonun ekranında mı: düz ekrandaki ortası ekranın içinde ve iki yanı ekranın kenarlarını
    /// <see cref="SideSlack"/>'ten çok aşmıyor. Altyazı hattı bu satırları okumaz (SubtitlePipeline.FindsPhone). Telefonun
    /// önünden geçen geniş altyazı satırı telefonun ekranından taşar, telefon yazısı sayılmaz (Mac/iPhone:
    /// ScreenPhoneCard.holds, Android: ScreenPhoneCard.holds).
    /// </summary>
    public static bool Holds(TextBox box, Handset handset)
    {
        var flat = handset.Flat(box);
        var v = (flat.Top + flat.Bottom) / 2;
        return v >= -ScreenSlack && v <= 1 + BelowSlack && flat.Left >= -SideSlack && flat.Right <= 1 + SideSlack;
    }

    /// <summary>
    /// Holds: satırın ortası ekranın üst kenarını bu kadar, yanları ekranın kenarlarını SideSlack kadar aşabilir. Alt kenarda
    /// pay BelowSlack: telefonun alt gövdesi örtülünce telefon kısa bulunuyor, son mesajlar ekranın altında kalıyordu
    /// (gerçek kare gta6-telefon-sohbet-2; Mac ile aynı).
    /// </summary>
    internal const double ScreenSlack = 0.03, SideSlack = 0.12, BelowSlack = 0.25;

    /// <summary>Öğe kartın zemini mi (masaüstü listesi ve düz metin bunu atlar).</summary>
    public static bool IsBackdrop(ScreenTranslation.Item item) => string.IsNullOrWhiteSpace(item.Translation);

    /// <summary>Okunan karede telefon varsa yeri ve eğikliği; akla yatkın olmayan aday yok sayılır.</summary>
    public static Handset? Phone(Frame frame)
    {
        if (!GamePhoneGeometry.TryLocate(frame, out var pose) || !GamePhoneTracker.Plausible(pose.Bounds, frame)) return null;
        return new Handset(pose, frame.Width / (double)Math.Max(1, frame.Height));
    }

    /// <summary>
    /// Kartın yeri: telefonun yanında, telefon boyunda; iki yanda da yer yoksa telefonun üstünde. İki yanda da yer varsa
    /// kart başka çevirilerin (<paramref name="avoiding"/>) üstüne en az binen yana, eşitse daha geniş boş kalan yana konur.
    /// </summary>
    internal static TextBox CardBox(TextBox phone, IReadOnlyList<TextBox>? avoiding = null)
    {
        var others = avoiding ?? [];
        double roomLeft = phone.Left - 2 * Gap, roomRight = 1 - phone.Right - 2 * Gap;
        var wanted = Math.Max((phone.Right - phone.Left) * CardScale, CardMin);
        TextBox? Side(bool right)
        {
            var width = Math.Min(wanted, right ? roomRight : roomLeft);
            if (width < MinWidth) return null;
            var left = right ? phone.Right + Gap : phone.Left - Gap - width;
            return new TextBox(left, phone.Top, left + width, phone.Bottom);
        }
        // Önce daha geniş yan; öbür yan ancak başka çevirilerin üstüne daha az binerse seçilir.
        var candidates = new[] { Side(roomLeft < roomRight), Side(roomLeft >= roomRight) }
            .Where(box => box is not null).Select(box => box!.Value).ToList();
        if (candidates.Count == 0)
            return new TextBox(Math.Max(0, phone.Left), phone.Top, Math.Min(1, phone.Right), phone.Bottom);
        var best = candidates[0];
        foreach (var candidate in candidates.Skip(1))
            if (Covered(candidate, others) < Covered(best, others) - 1e-9) best = candidate;
        return best;
    }

    /// <summary>Kutunun başka kutularla örtüşen alanı.</summary>
    internal static double Covered(TextBox box, IReadOnlyList<TextBox> others) =>
        others.Sum(other => Math.Max(0, Math.Min(box.Right, other.Right) - Math.Max(box.Left, other.Left))
                            * Math.Max(0, Math.Min(box.Bottom, other.Bottom) - Math.Max(box.Top, other.Top)));

    private sealed record Row(ScreenTranslation.Item Item, double Width, double Height, string Side);

    /// <summary>
    /// Telefondaki öğeleri (<c>Phone</c> bilgisi olanlar) kart olarak dizer. Telefonda çevrilmiş öğe yoksa liste olduğu gibi
    /// döner. Çevrilmemiş öğeler (<c>Unchanged</c>: kişi adı, "ok") kartta aslıyla görünür; kart dışındakiler sonra atılır.
    /// Balonlar arasında en az <see cref="BubbleSpacing"/> satır boşluk kalır; mesajlar telefon boyuna sığmazsa kart uzar,
    /// yine sığmazsa en eski mesajlar düşer. Kartın altında kalan başka bir çeviri kartın dışına, yanına alınır.
    /// </summary>
    public static IReadOnlyList<ScreenTranslation.Item> Layout(IReadOnlyList<ScreenTranslation.Item> items, Handset handset)
    {
        var onPhone = items.Where(item => item.Phone?.Role.InCard() == true).OrderBy(item => item.Phone!.Spot.Top).ToList();
        if (!onPhone.Any(item => !item.Unchanged)) return items;
        var others = items.Where(item => item.Phone?.Role.InCard() != true).ToList();
        var card = CardBox(handset.Bounds, [.. others.Where(item => !item.Unchanged).Select(item => item.Box)]);
        var cardWidth = card.Right - card.Left;
        var heights = onPhone.Select(item => item.LineHeight).OrderBy(h => h).ToList();
        var line = Math.Max(MinLine, heights[heights.Count / 2]);
        double pad = cardWidth * 0.05, padY = line * 0.4, spacing = line * BubbleSpacing;
        static TextLook Flat(string align, bool bold) => new(bold, false, align, false, true);

        var body = onPhone;
        ScreenTranslation.Item? header = null;
        if (body.Count > 0 && body[0].Phone!.Role == Role.Header)
        {
            header = body[0];
            body = body.Skip(1).ToList();
        }
        var headerHeight = header is null ? 0 : line * 1.4 + spacing;

        // Her satırın kartta kaplayacağı yer: genişliği rolünden, yüksekliği Türkçenin o genişlikte kaç satır tuttuğundan.
        var rows = body.Select(item =>
        {
            var role = item.Phone!.Role == Role.Message ? (IsBlue(item.Style) ? Role.Outgoing : Role.Incoming) : item.Phone!.Role;
            var bubble = role is Role.Incoming or Role.Outgoing;
            var widest = (bubble ? BubbleShare : 1) * cardWidth - (bubble ? 0 : 2 * pad);
            var inner = widest - 2 * pad;
            var lines = Wrap(item.Translation, (int)(inner * handset.Aspect / (line * CharWidth)));
            var longest = lines.Max(l => l.Length) * line * CharWidth / handset.Aspect + 2 * pad;
            var width = bubble ? Math.Min(widest, Math.Max(cardWidth * BubbleMin, longest)) : widest;
            var side = role == Role.Outgoing ? "right" : role == Role.Note ? "center" : "left";
            var placed = item with
            {
                Unchanged = false, LineHeight = line,
                Style = role switch { Role.Outgoing => OutgoingColor, Role.Incoming => IncomingColor, _ => CardColor },
                Look = Flat(side, role is Role.Contact or Role.Heading),
            };
            var inside = line * (bubble ? BubblePadding : 0.3);
            return new Row(placed, width, lines.Count * line * LineSpacing + inside, side);
        }).ToList();
        // Mesajlar telefon boyuna sığmazsa kart önce aşağı, sonra yukarı uzar (ekranın kenar payına kadar).
        double Needed() => 2 * padY + headerHeight + rows.Sum(row => row.Height) + spacing * Math.Max(0, rows.Count - 1);
        double top = card.Top, bottom = card.Bottom;
        var extra = Needed() - (bottom - top);
        if (extra > 0)
        {
            var down = Math.Min(extra, Math.Max(0, 1 - ScreenMargin - bottom));
            bottom += down;
            extra -= down;
            top -= Math.Min(extra, Math.Max(0, top - ScreenMargin));
            card = new TextBox(card.Left, top, card.Right, bottom);
        }
        // Yine sığmazsa en eski (en üstteki) satırlar düşer: son mesajlar görünür kalır.
        while (rows.Count > 1 && Needed() > card.Bottom - card.Top + 1e-9) rows.RemoveAt(0);

        var result = new List<ScreenTranslation.Item>(others);
        // Kartın altında kalan başka bir çeviri kartın telefondan uzak yanına alınır; oraya sığmazsa yerinde kalır.
        var cardOnLeft = card.Right <= handset.Bounds.Left + 1e-9;
        for (var i = 0; i < result.Count; i++)
        {
            if (result[i].Unchanged || Covered(result[i].Box, [card]) <= 0) continue;
            var box = result[i].Box;
            var width = box.Right - box.Left;
            var left = cardOnLeft ? card.Left - Gap - width : card.Right + Gap;
            if (left >= 0 && left + width <= 1) result[i] = result[i] with { Box = new TextBox(left, box.Top, left + width, box.Bottom) };
        }
        result.Add(new ScreenTranslation.Item("", BackdropText, card, line) { Style = CardColor, Look = Flat("left", false) });

        var bodyTop = card.Top + padY;
        if (header is not null)
        {
            var placed = header with
            {
                Unchanged = false,
                Box = new TextBox(card.Left + pad, bodyTop, card.Right - pad, bodyTop + line * 1.4),
                LineHeight = line, Style = CardColor, Look = Flat("center", true),
            };
            result.Add(placed);
            bodyTop = placed.Box.Bottom + spacing;
        }
        var limit = card.Bottom - padY;
        // Önce telefondaki yerine (oranla) yakın, üsttekinin altında; taşan satırlar alttan yukarı itilir.
        var phone = handset.Bounds;
        var tops = new double[rows.Count];
        var cursor = bodyTop;
        for (var i = 0; i < rows.Count; i++)
        {
            var wanted = phone.Top + rows[i].Item.Phone!.Spot.Top * (phone.Bottom - phone.Top);
            tops[i] = Math.Max(wanted, cursor);
            cursor = tops[i] + rows[i].Height + spacing;
        }
        var floor = limit;
        for (var i = rows.Count - 1; i >= 0; i--)
        {
            tops[i] = Math.Max(bodyTop, Math.Min(tops[i], floor - rows[i].Height));
            floor = tops[i] - spacing;
        }
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var left = row.Side == "right" ? card.Right - pad - row.Width
                : row.Side == "center" ? (card.Left + card.Right - row.Width) / 2 : card.Left + pad;
            result.Add(row.Item with { Box = new TextBox(left, tops[i], left + row.Width, tops[i] + row.Height) });
        }
        return result;
    }

    /// <summary>Metni sözcük sözcük en çok <paramref name="perLine"/> harflik satırlara böler (çok uzun sözcük kendi satırında kalır).</summary>
    internal static List<string> Wrap(string text, int perLine)
    {
        var limit = Math.Max(4, perLine);
        var lines = new List<string>();
        foreach (var paragraph in text.Split('\n'))
        {
            var current = "";
            foreach (var word in paragraph.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            {
                if (current.Length == 0) current = word;
                else if (current.Length + 1 + word.Length <= limit) current += " " + word;
                else
                {
                    lines.Add(current);
                    current = word;
                }
            }
            lines.Add(current);
        }
        return lines;
    }

    /// <summary>Balonun okunan rengi belirgin mavi mi (giden mesaj balonu): mavi kanal kırmızı ve yeşilin ortalamasından en az 40 fazla.</summary>
    internal static bool IsBlue(PhoneTextStyle? style)
    {
        if (style?.Background is not { Length: 7 } hex || hex[0] != '#'
            || !int.TryParse(hex.AsSpan(1), System.Globalization.NumberStyles.HexNumber, null, out var value)) return false;
        int r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF;
        return b - (r + g) / 2 >= 40;
    }
}
