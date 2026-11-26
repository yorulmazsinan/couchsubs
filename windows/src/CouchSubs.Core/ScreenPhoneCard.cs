// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>"GTA 6 Telefon Mesajları" ayarı ve panelin yazı çarpanı (Mac: PhonePanelOptions).</summary>
public sealed record PhonePanelOptions(bool Enabled = true, double TextScale = 1);

/// <summary>
/// GTA 6 telefonunun sohbet paneli ("Ekranı çevir" ve otomatik telefon okuması): eğik telefon ekranının üstüne yazmak
/// okunmuyordu (yazı küçük, ekran yamuk, monitörde balonların yeri kayıyor). Telefon karede bulunursa
/// (<see cref="GamePhoneGeometry"/>) ekranındaki satırlar düz ekrana taşınıp ayrı gruplanır (<see cref="PhoneChat"/>,
/// <see cref="GamePhoneText.Groups"/>) ve çevirileri telefonun hemen yanına (telefon solda ise sağına, sağda ise soluna; yanda
/// yer yoksa altına), telefon boyunda koyu, yarı saydam bir sohbet paneli olarak dizilir: en üstte kişi adı (çevrilmez), altında
/// her mesaj kendi balonunda (karşı taraf solda açık zeminde, oyuncu sağda amber zeminde). Panel dolarsa en eski mesajlar
/// düşer. Yazı boyu altyazı boyutu ayarına bağlıdır. Panel stilli öğeler olarak gider ve her öğe panel parçasını taşır
/// (<see cref="PanelPart"/>, JSON <c>panel</c>): yeni çiziciler paneli akışla çizer, eski TV öğeleri yerinde çizer
/// (Mac: ScreenPhoneCard.swift, Android: ScreenPhoneCard.kt; ortak deneme dosyası Fixtures/phone-chat.json).
/// </summary>
public static class ScreenPhoneCard
{
    /// <summary>
    /// Panelin parçası; JSON'da <c>panel</c> alanının değeri (card, title, theirs, mine, note, row). <c>Row</c>: sohbet
    /// listesinin bir satırı ya da ana ekran bileşeni tek kartta (<see cref="ListRow"/>: avatar, kalın ad, altında önizleme,
    /// rozet, seçili satır çerçevesi). TV uygulaması 0.9.110; eski TV öğeyi yerinde, ad ve önizleme iki satır çizer.
    /// </summary>
    public enum PanelPart { Card, Title, Theirs, Mine, Note, Row }

    public static string Json(this PanelPart part) => part switch
    {
        PanelPart.Card => "card",
        PanelPart.Title => "title",
        PanelPart.Theirs => "theirs",
        PanelPart.Mine => "mine",
        PanelPart.Row => "row",
        _ => "note",
    };

    /// <summary>
    /// Liste kartının içeriği (<see cref="PanelPart.Row"/>; JSON <c>row</c>). Sinan Bey (beta.100, 3399): ad ve önizleme
    /// ayrı haplar dağınıktı; telefondaki satırın Türkçe kopyası tek kartta. Avatar ve rozet oyundan kesilir (küçük PNG,
    /// aynı satırda bir kez kesilip saklanır; <see cref="PhoneListLook"/>), seçili satırın çerçevesi kareden okunur.
    /// Görünüşü aynı mı karşılaştırmasına karedeki arama yerleri girmez (el titremesiyle oynar; #1279). Mac ile aynı.
    /// </summary>
    /// <param name="Name">Kalın ad (kişi adı çevrilmez; bileşen başlığı çevrilir). Boşsa yalnız önizleme.</param>
    /// <param name="Preview">Adın altındaki önizleme (çeviri; kesikse "..." ile biter). Boş olabilir (yalnız emoji önizleme).</param>
    public sealed record ListRow(string Name, string Preview)
    {
        /// <summary>Oyundan kesilmiş avatar ya da bileşen simgesi (PNG data: adresi); yoksa null.</summary>
        public string? Avatar { get; init; }
        /// <summary>Sağdaki rozet (gönder/konum simgesi; PNG data: adresi); yoksa null.</summary>
        public string? Badge { get; init; }
        /// <summary>Seçili satırın çerçeve rengi (telefonda mavi); seçili değilse null.</summary>
        public string? Selected { get; init; }
        /// <summary>Ana ekran bileşeni ("Hatırlatıcılar / 6 Bildirim").</summary>
        public bool Widget { get; init; }
        /// <summary>Karede avatarın, rozetin ve seçim çerçevesinin aranacağı yerler (kesmek için; gönderilmez).</summary>
        public TextBox? PortraitSpot { get; init; }
        public TextBox? BadgeSpot { get; init; }
        public TextBox? FrameSpot { get; init; }

        public bool Equals(ListRow? other) =>
            other is not null && Name == other.Name && Preview == other.Preview && Avatar == other.Avatar
            && Badge == other.Badge && Selected == other.Selected && Widget == other.Widget;

        public override int GetHashCode() => HashCode.Combine(Name, Preview, Avatar, Badge, Selected, Widget);
    }

    /// <summary>Kartın zemini: yazısı yalnız bölünmez boşluk olan öğe, kartın tamamını kaplar; balonlar üstüne çizilir.</summary>
    public const string BackdropText = " ";
    /// <summary>Panelin renkleri (CouchSubs tasarım dili): koyu zemin (çiziciler %88 örtüyle çizer), karşı taraf krem, oyuncu amber.</summary>
    internal static readonly PhoneTextStyle CardColor = new("#141518", "#F3EEE4");
    internal static readonly PhoneTextStyle IncomingColor = new("#F3EEE4", "#17181B");
    internal static readonly PhoneTextStyle OutgoingColor = new("#F5B83D", "#17181B");
    /// <summary>Not ve liste başlığının soluk rengi; çizici (PhonePanelView) liste satırlarının arasını bununla ayırt eder.</summary>
    public static readonly PhoneTextStyle NoteColor = new("#141518", "#A9A59C");
    /// <summary>Panelin köşe yarıçapı (1080 satırlık ekranda piksel) ve zemin örtüsü.</summary>
    public const double PanelRadius = 18, PanelOpacity = 0.88;
    /// <summary>Kanepe simgesi: 24×16 ızgarada yuvarlak köşeli dikdörtgenler (x, y, en, boy, köşe); Mac ile aynı şekil.</summary>
    public static readonly (double X, double Y, double Width, double Height, double Radius)[] CouchGlyph =
        [(3, 1, 18, 8, 2.5), (0, 5, 5, 8, 2), (19, 5, 5, 8, 2), (4, 8, 16, 5, 1.5), (2, 13, 2, 3, 0.8), (20, 13, 2, 3, 0.8)];
    /// <summary>Telefonla kart arasındaki boşluk ve kartın ekran kenarından payı (ekran genişliğine oranla).</summary>
    internal const double Gap = 0.008;
    /// <summary>Kart için yanda en az bu kadar yer olmalı; yoksa kart telefonun altına (orada da yer yoksa üstüne) konur.</summary>
    internal const double MinWidth = 0.12, MinBelow = 0.18;
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
    /// <summary>Sohbet listesinde kişi adıyla altındaki önizleme arasındaki boşluk (satır yüksekliğine oranla). Mac ile aynı.</summary>
    internal const double ListGap = 0.1;
    /// <summary>Balonun kart genişliğine oranı (en çok) ve en az.</summary>
    internal const double BubbleShare = 0.8, BubbleMin = 0.3;
    /// <summary>Kartta yazı boyu (kare yüksekliğine oranla) en az bu: telefonun küçük yazısı TV'de okunsun (1080p'de ~24 nokta).</summary>
    internal const double MinLine = 0.022;
    /// <summary>
    /// Kartta yazı boyu en çok bu (altyazı boyutu çarpanıyla): telefon yazısıyla orantılı kalır. Sinan Bey (beta.100, 3416):
    /// gönderinin Türkçesi dev, her satıra bir sözcük düşen patlak balondu; ölçüm fotoğrafın içindeki büyük yazıyı (tabela)
    /// da alıyordu. 3417'deki küçük balon doğru boydur (1080p'de ~32 nokta satır). Mac/iPhone ve Android ile aynı.
    /// </summary>
    internal const double MaxLine = 0.03;
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
        /// <summary>Ana ekranın yazısı (bildirim): sohbet değildir, karta girmez; kendi yerinde, özgün stilinde çizilir.</summary>
        Home,
        /// <summary>Ana ekran bileşeni (başlık + sayaç: "Reminders / 6 Notifications"): panelde tek kart (<see cref="ListRow.Widget"/>).</summary>
        Widget,
        /// <summary>
        /// Sohbet dışı ekranın satırı ya da bloğu (<see cref="PhoneScreen"/>: uygulama satırı, makale başlığı/gövdesi,
        /// gönderinin açıklaması): panelde tek kart, mesaj listesi kartının görünüşünde (avatarsız).
        /// </summary>
        Card,
    }

    /// <summary>Çevirmene gitmez, aslıyla gösterilir (ad).</summary>
    internal static bool KeepsText(this Role role) => role is Role.Header or Role.Contact;

    /// <summary>
    /// Telefonun yanındaki panelde dizilir. Sinan Bey (beta.100, 3422): ana ekran ve hava yazıları da artık telefonun üstüne
    /// çizilmez, panelde kart olur (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal static bool InCard(this Role role) => true;

    /// <summary>
    /// Telefondaki bir grubun rolü ve düz ekrandaki yeri (0–1). Kartta (<see cref="Role.Card"/>): <paramref name="Titled"/>
    /// ilk paragraf kalın başlık, <paramref name="Bold"/> kartın tamamı başlık (makale başlığı).
    /// </summary>
    public sealed record Placement(Role Role, TextBox Spot, bool Titled = false, bool Bold = false);

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

        /// <summary>Telefonun ekseni (gevşek doğrulama için; <see cref="GamePhoneGeometry.TryLocate(Frame, GamePhoneGeometry.Pose?, out GamePhoneGeometry.Pose)"/>).</summary>
        internal GamePhoneGeometry.Pose Pose => new(topX, topY, bottomX, bottomY);

        /// <summary>Düz ekrandaki noktanın karedeki yeri (kenarlara oranla).</summary>
        internal (double X, double Y) Point(double u, double v)
        {
            double dx = bottomX - topX, dy = bottomY - topY;
            double t = 0.04 + 0.915 * v, side = (u - 0.5) * 0.52;
            return (topX + dx * t + side * dy / aspect, topY + dy * t - side * dx * aspect * (0.52 + v * 0.30));
        }

        /// <summary>Düz ekrandaki kutunun karedeki sınır kutusu (dört köşesinden; eğik telefonda biraz geniştir).</summary>
        internal TextBox FrameBox(TextBox box)
        {
            (double X, double Y)[] corners = [Point(box.Left, box.Top), Point(box.Right, box.Top), Point(box.Left, box.Bottom), Point(box.Right, box.Bottom)];
            return new TextBox(corners.Min(c => c.X), corners.Min(c => c.Y), corners.Max(c => c.X), corners.Max(c => c.Y));
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
    /// Doğrulanmamış telefon adayı (#1251, CandidateHoldMs) yalnız ekranının içindeki satırları bekletir: alt gövde payı
    /// (BelowSlack) yok ve konuşan adlı satır ("Lucia: …") hiç bekletilmez. Yanlış aday (yanları zayıf, telefon olmayan
    /// dikdörtgen) altındaki ya da önündeki altyazıyı 1,5 sn yutuyordu (beta.103 kaçan altyazı denetimi).
    /// Mac/iPhone (ScreenPhoneCard.holdsUnconfirmed) ve Android (holdsUnconfirmed) aynı.
    /// </summary>
    public static bool HoldsUnconfirmed(string text, TextBox box, Handset handset)
    {
        if (SpeakerPrefix.Parse(text) is not null) return false;
        var flat = handset.Flat(box);
        var v = (flat.Top + flat.Bottom) / 2;
        return v >= -ScreenSlack && v <= 1 + ScreenSlack && flat.Left >= -SideSlack && flat.Right <= 1 + SideSlack;
    }

    /// <summary>
    /// Holds: satırın ortası ekranın üst kenarını bu kadar, yanları ekranın kenarlarını SideSlack kadar aşabilir. Alt kenarda
    /// pay BelowSlack: telefonun alt gövdesi örtülünce telefon kısa bulunuyor, son mesajlar ekranın altında kalıyordu
    /// (gerçek kare gta6-telefon-sohbet-2; Mac ile aynı).
    /// </summary>
    internal const double ScreenSlack = 0.03, SideSlack = 0.12, BelowSlack = 0.25;

    /// <summary>Öğe kartın zemini mi (masaüstü listesi ve düz metin bunu atlar).</summary>
    public static bool IsBackdrop(ScreenTranslation.Item item) => string.IsNullOrWhiteSpace(item.Translation);

    /// <summary>
    /// Okunan karede telefon varsa yeri ve eğikliği; akla yatkın olmayan aday yok sayılır. <paramref name="near"/>: açık
    /// telefonun son yeri (bulunmuşsa); sıkı arama ıskalarsa orada gevşek doğrulama yapılır.
    /// </summary>
    public static Handset? Phone(Frame frame, Handset? near = null) => Phone(frame, near, out _);

    /// <summary>
    /// <see cref="Phone(Frame, Handset?)"/>; telefon bulunamazsa <paramref name="candidate"/>: sıkı aramada yanları zayıf
    /// kalan akla yatkın aday (<see cref="GamePhoneGeometry.Probe.Weak"/>), yoksa null. Aday telefon sayılmaz; altyazı hattı
    /// ekranındaki satırları kısa süre bekletir.
    /// </summary>
    internal static Handset? Phone(Frame frame, Handset? near, out Handset? candidate)
    {
        candidate = null;
        var aspect = frame.Width / (double)Math.Max(1, frame.Height);
        if (GamePhoneGeometry.TryLocate(frame, near?.Pose, out var pose, out var probe))
            return GamePhoneTracker.Plausible(pose.Bounds, frame) ? new Handset(pose, aspect) : null;
        if (probe.Weak is { } weak && GamePhoneTracker.Plausible(weak.Bounds, frame)) candidate = new Handset(weak, aspect);
        return null;
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
        {
            if (1 - ScreenMargin - (phone.Bottom + Gap) >= MinBelow)
            {
                var width = Math.Min(wanted, 1 - 2 * Gap);
                var left = Math.Min(Math.Max(Gap, (phone.Left + phone.Right - width) / 2), 1 - Gap - width);
                return new TextBox(left, phone.Bottom + Gap, left + width, 1 - ScreenMargin);
            }
            return new TextBox(Math.Max(0, phone.Left), phone.Top, Math.Min(1, phone.Right), phone.Bottom);
        }
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
    /// Telefondaki öğeleri (<c>Phone</c> bilgisi olanlar) telefonun yanındaki panelde dizer (Mac: ScreenPhoneCard.layout ile
    /// birebir). Telefonda çevrilmiş öğe yoksa liste olduğu gibi döner. Çevrilmemiş öğeler (<c>Unchanged</c>: kişi adı, "ok")
    /// panelde aslıyla görünür; panel dışındakiler sonra atılır. Hizalı panel (<c>Aligned</c>): her Türkçe balon telefondaki
    /// İngilizce balonuyla aynı yükseklikte durur (<see cref="AlignedTop"/>); çakışan balon en az kaydırmayla aşağı itilir
    /// (aralarında en az <see cref="BubbleSpacing"/> satır), panel gerekirse aşağı uzar; ekranın alt payına dayanınca satırlar
    /// alttan yukarı itilir, yukarıda da yer kalmazsa en eski mesajlar düşer. Yazı küçülmez. Balonlar telefonun balon
    /// renginde (<see cref="BubbleColor"/>). Kartın altında kalan başka bir çeviri kartın dışına, yanına alınır.
    /// <paramref name="lockedLine"/>: telefondaki satır yüksekliği yerine kullanılacak kilitli ölçüm
    /// (<see cref="PhonePanelSteady.SteadyLine"/>, #1152); verilmezse bu karenin ölçümü (<see cref="MeasuredLine"/>). Kartın
    /// kutusu, akışla çizen eski TV için bütün satırları ve dolguyu alacak boydadır.
    /// </summary>
    public static IReadOnlyList<ScreenTranslation.Item> Layout(IReadOnlyList<ScreenTranslation.Item> items, Handset handset,
                                                               double textScale = 1, double? lockedLine = null)
    {
        var onPhone = items.Where(item => item.Phone?.Role.InCard() == true).OrderBy(item => item.Phone!.Spot.Top).ToList();
        if (!onPhone.Any(item => !item.Unchanged)) return items;
        var others = items.Where(item => item.Phone?.Role.InCard() != true).ToList();
        var card = CardBox(handset.Bounds, [.. others.Where(item => !item.Unchanged).Select(item => item.Box)]);
        var cardWidth = card.Right - card.Left;
        var measured = lockedLine ?? MeasuredLine(onPhone) ?? 0;
        var scale = Math.Min(MaxScale, Math.Max(MinScale, textScale));
        var line = Math.Min(MaxLine * scale, Math.Max(MinLine * scale, measured));
        double pad = cardWidth * 0.05, padY = line * 0.4, spacing = line * BubbleSpacing;
        static TextLook Flat(string align, bool bold) => new(bold, false, align, false, true);

        // Sohbetin üstündeki kişi adı çizilmez (Sinan Bey, beta.100 3400/3402: "Cal" başlığı gereksiz); balonlar aynen kalır.
        // Sohbet dışı ekranda çevrilmeyen kart (kişi adı "Jason", yer adı) çizilmez.
        var body = onPhone.Where(item => item.Phone!.Role != Role.Header && !(IsCard(item.Phone.Role) && item.Unchanged)).ToList();
        // Sohbet dışı ekranın kartları tek renkte (telefonda en çok görünen satır kartı rengi): her kart kendi örneğiyle ayrı
        // renkte çiziliyordu (Sinan Bey, 3423: "stilleri tutarsız").
        var cardStyle = CommonStyle([.. body.Where(item => IsCard(item.Phone!.Role)).Select(item => item.Style)]);

        // Her satırın panelde kaplayacağı yer: genişliği rolünden, yüksekliği Türkçenin o genişlikte kaç satır tuttuğundan.
        // Sohbet listesinin satırı (ad + altındaki önizleme) ve ana ekran bileşeni tek kart olur (ListRowItem; Mac ile aynı).
        var rows = new List<Row>();
        var index = 0;
        while (index < body.Count)
        {
            var item = body[index];
            var role = item.Phone!.Role;
            index++;
            if (IsCard(role))
            {
                if (CardRow(item, cardStyle, handset, line, cardWidth - 2 * pad) is { } made)
                    rows.Add(new Row(made.Item, cardWidth - 2 * pad, made.Height, "left"));
                continue;
            }
            if (role is Role.Contact or Role.Preview or Role.Widget)
            {
                ScreenTranslation.Item? name = null, preview = null;
                if (role == Role.Contact)
                {
                    name = item;
                    if (index < body.Count && body[index].Phone?.Role == Role.Preview)
                    {
                        preview = body[index];
                        index++;
                    }
                }
                else if (role == Role.Preview)
                {
                    preview = item;
                }
                else
                {
                    name = item;
                }
                if (ListRowItem(name, preview, role == Role.Widget, handset, line, cardWidth - 2 * pad) is { } made)
                    rows.Add(new Row(made.Item, cardWidth - 2 * pad, made.Height, "left"));
                continue;
            }
            var kind = role == Role.Message ? (IsOutgoing(item.Style) ? Role.Outgoing : Role.Incoming) : role;
            var bubble = kind is Role.Incoming or Role.Outgoing;
            var widest = (bubble ? BubbleShare : 1) * cardWidth - (bubble ? 0 : 2 * pad);
            var inner = widest - 2 * pad;
            var lines = Wrap(item.Translation, (int)(inner * handset.Aspect / (line * CharWidth)));
            var longest = lines.Max(l => l.Length) * line * CharWidth / handset.Aspect + 2 * pad;
            var width = bubble ? Math.Min(widest, Math.Max(cardWidth * BubbleMin, longest)) : widest;
            var side = kind == Role.Outgoing ? "right" : kind == Role.Note ? "center" : "left";
            var placed = item with
            {
                Unchanged = false, LineHeight = line,
                Style = kind switch
                {
                    // Bölüm başlığı ("Önerilen", "Mesajlar") soluk ve kalın küçük başlık, sola yaslı; not ortalı (Mac ile aynı).
                    Role.Outgoing => BubbleColor(item.Style, OutgoingColor), Role.Incoming => BubbleColor(item.Style, IncomingColor),
                    _ => NoteColor,
                },
                Panel = kind switch { Role.Outgoing => PanelPart.Mine, Role.Incoming => PanelPart.Theirs, _ => PanelPart.Note },
                Look = Flat(side, kind == Role.Heading),
            };
            rows.Add(new Row(placed, width, lines.Count * line * LineSpacing + line * BubblePadding, side));
        }
        if (rows.Count == 0) return items;
        var limit = 1 - ScreenMargin;
        const double bodyTop = ScreenMargin;
        // Her balon kendi İngilizce balonunun yüksekliğinde; çakışan balon üsttekinin altına en az kaydırmayla itilir. Panel
        // ekranın alt kenar payını aşarsa satırlar alttan yukarı itilir; yukarıda da yer kalmazsa en eski satırlar düşer.
        double[] AlignedTops()
        {
            var tops = new double[rows.Count];
            for (var i = 0; i < rows.Count; i++)
            {
                var below = i == 0 ? bodyTop : tops[i - 1] + rows[i - 1].Height + spacing;
                tops[i] = Math.Max(AlignedTop(rows[i].Item, line), below);
            }
            var floor = limit;
            for (var i = rows.Count - 1; i >= 0; i--)
            {
                tops[i] = Math.Min(tops[i], floor - rows[i].Height);
                floor = tops[i] - spacing;
            }
            return tops;
        }
        var tops = AlignedTops();
        while (rows.Count > 1 && tops[0] < bodyTop - 1e-9)
        {
            rows.RemoveAt(0);
            tops = AlignedTops();
        }
        if (tops.Length > 0 && tops[0] < bodyTop) tops[0] = bodyTop;
        var contentTop = tops.Length > 0 ? tops[0] : card.Top;
        var contentBottom = rows.Count > 0 ? tops[^1] + rows[^1].Height : card.Bottom;
        // Kart: telefon boyunda, balonlar aşağı uzanırsa onlarla; eski TV'nin akışı (dolgu, aralıklar) da sığar.
        var flow = 2 * padY + rows.Sum(row => row.Height) + Math.Max(0, rows.Count - 1) * spacing;
        var cardTop = Math.Max(ScreenMargin, Math.Min(card.Top, contentTop));
        card = new TextBox(card.Left, cardTop, card.Right,
                           Math.Min(limit, Math.Max(Math.Max(card.Bottom, contentBottom + padY), cardTop + flow)));

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
        result.Add(new ScreenTranslation.Item("", BackdropText, card, line)
        {
            Style = CardColor, Look = Flat("left", false), Panel = PanelPart.Card, Aligned = true,
        });

        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var left = row.Side == "right" ? card.Right - pad - row.Width
                : row.Side == "center" ? (card.Left + card.Right - row.Width) / 2 : card.Left + pad;
            result.Add(row.Item with { Box = new TextBox(left, tops[i], left + row.Width, tops[i] + row.Height) });
        }
        return result;
    }

    /// <summary>Sohbet dışı ekranın kartı mı (ana ekranın yazısı da).</summary>
    internal static bool IsCard(Role role) => role is Role.Card or Role.Home;

    /// <summary>En çok görünen okunmuş renk (eşitlikte önce gelen); örnek yoksa null.</summary>
    internal static PhoneTextStyle? CommonStyle(IReadOnlyList<PhoneTextStyle?> styles)
    {
        var known = styles.OfType<PhoneTextStyle>()
            .Where(style => !string.Equals(style.Background, GamePhonePalette.Neutral.Background, StringComparison.OrdinalIgnoreCase)).ToList();
        PhoneTextStyle? best = null;
        var bestCount = 0;
        foreach (var style in known)
        {
            var count = known.Count(other => other == style);
            if (best is null || count > bestCount) (best, bestCount) = (style, count);
        }
        return best;
    }

    /// <summary>
    /// Sohbet dışı ekranın kartı: mesaj listesi kartının görünüşünde, avatarsız. Kalın başlık ("Strength Workout") ve altında
    /// yazı ("Level 3/4"), yalnız başlık (makale başlığı) ya da yalnız yazı (gönderinin açıklaması, ayar satırı). Kartın üstü
    /// İngilizcesiyle aynı hizada, boyu Türkçenin satır sayısına ve telefondaki bloğun boyuna göre (Mac/iPhone ve Android ile
    /// aynı).
    /// </summary>
    internal static (ScreenTranslation.Item Item, double Height)? CardRow(ScreenTranslation.Item item, PhoneTextStyle? style, Handset handset,
                                                                       double line, double width)
    {
        var parts = item.Translation.Split('\n');
        if (!parts.Any(part => part.Trim(' ', '\t').Length > 0)) return null;
        var placement = item.Phone;
        string title, below;
        if (placement?.Bold == true)
        {
            title = string.Join(' ', parts);
            below = "";
        }
        else if (placement?.Titled == true && parts.Length >= 2)
        {
            title = parts[0];
            below = string.Join(' ', parts.Skip(1));
        }
        else
        {
            title = "";
            below = string.Join(' ', parts);
        }
        var row = new ListRow(title, below) { Widget = false };
        var inset = RowPadding * line / handset.Aspect;
        var inner = width - 2 * inset;
        var perLine = (int)(inner * handset.Aspect / (line * CharWidth));
        var lines = (title.Length == 0 ? 0 : Wrap(title, perLine).Count) + (below.Length == 0 ? 0 : Wrap(below, perLine).Count);
        var needed = Math.Max(1, lines) * line * LineSpacing + 2 * RowPadding * line;
        var original = item.Box.Bottom - item.Box.Top + line * BubblePadding;
        var placed = item with
        {
            Unchanged = false,
            LineHeight = line,
            Style = BubbleColor(style ?? item.Style, RowColor),
            Look = new TextLook(false, false, "left", false, true),
            Panel = PanelPart.Row,
            ListRow = row,
        };
        return (placed, Math.Max(needed, original));
    }

    /// <summary>Liste kartının rengi okunamadıysa: GTA 6 telefonunun açık satır kartı.</summary>
    internal static readonly PhoneTextStyle RowColor = new("#F4F1EC", "#17181B");
    /// <summary>Liste kartında avatarın çapı, avatarla yazı arası ve kartın iç dolgusu (satır yüksekliğine oranla).</summary>
    public const double AvatarLines = 2.2, AvatarGap = 0.5, RowPadding = 0.45;

    /// <summary>
    /// Liste satırını (ad + önizleme) ya da ana ekran bileşenini tek kart yapar: kartın üstü adın İngilizcesiyle aynı hizada,
    /// boyu Türkçenin satır sayısına ve telefondaki satırın boyuna göre (hangisi büyükse; kartlar arası boşluk telefondakiyle
    /// orantılı kalır). Kart telefonun satır kartı renginde (önizlemenin örneklenen zemini). Avatarın, rozetin ve seçim
    /// çerçevesinin karedeki yeri <see cref="ListRow"/>'a yazılır; kesmek çağıranın işi (<see cref="PhoneListLook"/>).
    /// Mac: ScreenPhoneCard.listRow.
    /// </summary>
    internal static (ScreenTranslation.Item Item, double Height)? ListRowItem(ScreenTranslation.Item? name, ScreenTranslation.Item? preview,
                                                                           bool widget, Handset handset, double line, double width)
    {
        if ((name ?? preview) is not { } first) return null;
        string title, below;
        if (widget)
        {
            var parts = first.Translation.Split('\n', 2);
            title = parts[0];
            below = parts.Length > 1 ? parts[1] : "";
        }
        else
        {
            title = name?.Translation ?? "";
            below = preview?.Translation ?? "";
        }
        var row = new ListRow(title, below) { Widget = widget };
        var inset = RowPadding * line / handset.Aspect;
        var inner = width - 2 * inset - (AvatarLines + AvatarGap) * line / handset.Aspect;
        var wrapped = below.Length == 0 ? 0 : Wrap(below, (int)(inner * handset.Aspect / (line * CharWidth))).Count;
        var lines = (title.Length == 0 ? 0 : 1) + wrapped;
        var needed = Math.Max(Math.Max(1, lines) * line * LineSpacing, AvatarLines * line) + 2 * RowPadding * line;
        // Telefondaki satırın boyu (adın üstünden önizlemenin altına, dolguyla).
        var last = preview ?? first;
        var original = last.Box.Bottom - first.Box.Top + line * BubblePadding;
        // Karedeki yerler (düz ekrandan): avatar adın solunda, ad ve önizleme bloğunun ortasında; rozet satırın sağ ucunda,
        // ad hizasında; seçim çerçevesi satırın üst kenarı (adın biraz üstü).
        if (first.Phone?.Spot is { } top && last.Phone?.Spot is { } bottom)
        {
            const double shape = Handset.ScreenShape;
            if (widget)
            {
                // Bileşenin simgesi başlığın solunda (sayaç satırının sol hizasında), başlık satırı boyunda.
                var size = (top.Bottom - top.Top) * 0.5;
                row = row with
                {
                    PortraitSpot = handset.FrameBox(new TextBox(top.Left - size * 0.1 / shape, top.Top - size * 0.1,
                                                                top.Left + size * 1.1 / shape, top.Top + size * 1.1)),
                };
            }
            else
            {
                var block = Math.Max(1e-4, bottom.Bottom - top.Top);
                var center = (top.Top + bottom.Bottom) / 2;
                var size = block * 1.35;
                var right = Math.Min(top.Left, bottom.Left) - block * 0.1 / shape;
                double nameCenter = (top.Top + top.Bottom) / 2, badge = block * 0.62;
                row = row with
                {
                    PortraitSpot = handset.FrameBox(new TextBox(right - size / shape, center - size / 2, right, center + size / 2)),
                    BadgeSpot = handset.FrameBox(new TextBox(0.985 - badge / shape, nameCenter - badge / 2, 0.985, nameCenter + badge / 2)),
                    FrameSpot = handset.FrameBox(new TextBox(Math.Max(0.25, top.Left), top.Top - block * 0.6, 0.8, top.Top - block * 0.05)),
                };
            }
        }
        var item = first with
        {
            Source = widget ? first.Source : string.Join("\n", new[] { name?.Source, preview?.Source }.Where(text => text is not null)),
            Translation = string.Join("\n", new[] { title, below }.Where(text => text.Length > 0)),
            Unchanged = false,
            LineHeight = line,
            Style = BubbleColor(preview?.Style ?? first.Style, widget ? CardColor : RowColor),
            Look = new TextLook(false, false, "left", false, true),
            Panel = PanelPart.Row,
            ListRow = row,
        };
        return (item, Math.Max(needed, original));
    }

    /// <summary>
    /// Hizalı panelde satırın istenen üst kenarı: Türkçe yazının üstü İngilizce yazının üstünde (<c>Box</c>, karede); balon
    /// üst dolgusu kadar yukarıdan başlar (Mac ile aynı).
    /// </summary>
    internal static double AlignedTop(ScreenTranslation.Item item, double line) => item.Box.Top - line * BubblePadding / 2;

    /// <summary>Kişi adının (başlık) yüksekliği ve altındaki boşluk (satır yüksekliğine oranla); başlık balondan küçük.</summary>
    internal const double TitleHeight = 1.4, TitleGap = 0.3;
    /// <summary>Hizalı panelde balonların, notların ve başlığın zemin örtüsü.</summary>
    public const double BubbleOpacity = 0.85;

    /// <summary>
    /// Balonun rengi: telefondaki balondan örneklenen zemin ve yazı (<see cref="GamePhonePalette"/>); örnek yoksa ya da
    /// okunamadıysa (nötr yedek, geçersiz renk) <paramref name="fallback"/>. Örneğin yazısı zeminde okunmuyorsa (kontrast
    /// 4,5'ten az) zemine göre koyu ya da açık yazı (Mac ile aynı).
    /// </summary>
    internal static PhoneTextStyle BubbleColor(PhoneTextStyle? style, PhoneTextStyle fallback)
    {
        if (style is null || string.Equals(style.Background, GamePhonePalette.Neutral.Background, StringComparison.OrdinalIgnoreCase)
            || Rgb(style.Background) is not { } background) return fallback;
        if (Rgb(style.Foreground) is { } ink && Contrast(background, ink) >= 4.5) return style;
        const string dark = "#17181B", light = "#F3EEE4";
        return style with { Foreground = Contrast(background, Rgb(dark)!.Value) >= Contrast(background, Rgb(light)!.Value) ? dark : light };
    }

    private static (double R, double G, double B)? Rgb(string hex)
    {
        if (hex.Length != 7 || hex[0] != '#' || !int.TryParse(hex.AsSpan(1), System.Globalization.NumberStyles.HexNumber, null, out var value))
            return null;
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF);
    }

    /// <summary>İki rengin WCAG kontrast oranı.</summary>
    internal static double Contrast((double R, double G, double B) a, (double R, double G, double B) b)
    {
        static double Linear(double n)
        {
            var s = n / 255;
            return s <= 0.04045 ? s / 12.92 : Math.Pow((s + 0.055) / 1.055, 2.4);
        }
        static double Luminance((double R, double G, double B) c) => 0.2126 * Linear(c.R) + 0.7152 * Linear(c.G) + 0.0722 * Linear(c.B);
        double x = Luminance(a), y = Luminance(b);
        return (Math.Max(x, y) + 0.05) / (Math.Min(x, y) + 0.05);
    }

    /// <summary>Metni sözcük sözcük en çok <paramref name="perLine"/> harflik satırlara böler (çok uzun sözcük kendi satırında kalır).</summary>
    /// <summary>
    /// Kartta dizilecek telefon yazılarının satır yüksekliklerinin ortancası (panelin yazı boyu); yoksa null. Çift sayıda
    /// ölçümde küçük ortanca alınır: iki öğeden biri fotoğrafın içindeki büyük yazıysa (3416) panel onun boyunda çiziliyordu.
    /// </summary>
    public static double? MeasuredLine(IReadOnlyList<ScreenTranslation.Item> items)
    {
        var heights = items.Where(item => item.Phone?.Role.InCard() == true).Select(item => item.LineHeight).OrderBy(h => h).ToList();
        return heights.Count == 0 ? null : heights[(heights.Count - 1) / 2];
    }

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

    /// <summary>Çizilecek sohbet paneli: zemin, kişinin adı, mesajlar telefondaki sırasıyla ve panel dışındaki öğeler.</summary>
    public sealed record ChatPanel(ScreenTranslation.Item Card, ScreenTranslation.Item? Title,
                               IReadOnlyList<ScreenTranslation.Item> Messages, IReadOnlyList<ScreenTranslation.Item> Outside)
    {
        /// <summary>Hizalı panel: zemin çizilmez, her parça kendi kutusunun yerinde; değilse akışla, kartta.</summary>
        public bool Aligned => Card.Aligned;
    }

    /// <summary>Öğelerde panel varsa parçaları; yoksa null (Mac: ScreenPhoneCard.panel).</summary>
    public static ChatPanel? PanelOf(IReadOnlyList<ScreenTranslation.Item> items)
    {
        var card = items.FirstOrDefault(item => item.Panel == PanelPart.Card);
        if (card is null) return null;
        var parts = items.Where(item => item.Panel is { } part && part != PanelPart.Card).ToList();
        return new ChatPanel(card, parts.FirstOrDefault(item => item.Panel == PanelPart.Title),
                         [.. parts.Where(item => item.Panel != PanelPart.Title).OrderBy(item => item.Box.Top)],
                         [.. items.Where(item => item.Panel is null)]);
    }

    /// <summary>
    /// Saydam altyazı penceresindeki sohbet paneli (SubtitleOverlayWindow; Mac SubtitleOverlay): pencere oyun karesi değil,
    /// kullanıcının seçtiği alan olduğundan balonlar telefondaki İngilizce balonlarına hizalanamaz. Görünüm hizalı panelle
    /// aynıdır (koyu kart ve simge yok; her balon ayrı, telefonun balon renginde, <see cref="BubbleColor"/>): balonlar alanın
    /// telefon tarafındaki kenarında üstten alta, telefondaki sırasıyla ve aralarındaki boşlukla (en çok
    /// <see cref="StackedGapMax"/> satır) dizilir; gelen sola, giden sağa yaslı, kişi adı üstte küçük başlık. Yazı boyu
    /// <paramref name="font"/> (piksel, en az <see cref="StackedMinFont"/>); yazı küçülmez, sığmazsa en eski mesajlar düşer.
    /// Kutular alana oranla (0–1); <see cref="PhonePanelView"/> hizalı paneli çizer gibi çizer. Aynı girdi her zaman birebir
    /// aynı çıktı (#1279). Mac: ScreenPhoneCard.stacked, Android: ScreenPhoneCard.stacked.
    /// </summary>
    public static ChatPanel Stacked(ChatPanel panel, double width, double height, double font)
    {
        if (width <= 0 || height <= 0) return panel;
        font = Math.Max(StackedMinFont, font);
        // Çiziciler yazı boyunu satır yüksekliğinin 0,85'i alır (PhonePanelView.Aligned).
        var line = font / 0.85 / height;
        var aspect = width / height;
        var column = Math.Min(width * StackedShare, font * StackedChars) / width;
        var right = (panel.Card.Box.Left + panel.Card.Box.Right) / 2 > 0.5;
        var left = right ? 1 - column : 0;
        // Balonun yan dolgusu (çizicilerde yazı boyunun 0,6'sı), alana oranla.
        var padX = font * 0.6 / width;

        var card = panel.Card with { Box = new TextBox(left, 0, left + column, 1), LineHeight = line, Aligned = true };
        var title = panel.Title is { } head
            ? head with { Box = new TextBox(left, 0, left + column, line * TitleHeight), LineHeight = line }
            : null;
        var bodyTop = title is null ? 0 : line * (TitleHeight + TitleGap);

        var rows = panel.Messages.Select((source, index) =>
        {
            var bubble = source.Panel is PanelPart.Mine or PanelPart.Theirs;
            var item = source with
            {
                LineHeight = line,
                Style = source.Panel switch
                {
                    PanelPart.Mine => BubbleColor(source.Style, OutgoingColor),
                    PanelPart.Theirs => BubbleColor(source.Style, IncomingColor),
                    _ => source.Style,
                },
            };
            var widest = (bubble ? BubbleShare : 1) * column;
            // Liste kartında yazı avatarın sağında; kart en az avatar boyunda.
            var avatar = item.Panel == PanelPart.Row ? (AvatarLines + AvatarGap + 2 * RowPadding) * line / aspect : 0;
            var lines = Wrap(item.Translation, (int)((widest - 2 * padX - avatar) * aspect / (line * CharWidth)));
            // Telefondaki aralık satır yüksekliğine oranla korunur (önizleme kişi adının hemen altında kalır).
            var gap = BubbleSpacing;
            if (index > 0)
                gap = Math.Min(StackedGapMax, Math.Max(0, (source.Box.Top - panel.Messages[index - 1].Box.Bottom)
                                                         / Math.Max(1e-9, source.LineHeight)));
            var height = lines.Count * line * LineSpacing + line * BubblePadding;
            if (item.Panel == PanelPart.Row) height = Math.Max(lines.Count * line * LineSpacing, AvatarLines * line) + 2 * RowPadding * line;
            return (Item: item, Width: widest, Height: height, Gap: gap * line);
        }).ToList();
        // Sığmazsa en eski mesajlar düşer; tek kalan çok uzun mesaj yine çizilir (aşağıda kırpılır).
        double Bottom(int start)
        {
            var sum = bodyTop;
            for (var i = start; i < rows.Count; i++) sum += rows[i].Height + (i > start ? rows[i].Gap : 0);
            return sum;
        }
        var first = 0;
        while (first < rows.Count - 1 && Bottom(first) > 1 + 1e-9) first++;

        var messages = new List<ScreenTranslation.Item>();
        var top = bodyTop;
        for (var i = first; i < rows.Count; i++)
        {
            var row = rows[i];
            if (i > first) top += row.Gap;
            var x = row.Item.Panel == PanelPart.Mine ? left + column - row.Width : left;
            messages.Add(row.Item with { Box = new TextBox(x, top, x + row.Width, top + row.Height) });
            top += row.Height;
        }
        return new ChatPanel(card, title, messages, panel.Outside);
    }

    /// <summary>
    /// Saydam pencerede panelin yazısı en az bu boyda (piksel); sütunun eni alanın en çok <see cref="StackedShare"/>'i ve
    /// yazı boyunun <see cref="StackedChars"/> katı; balonlar arası boşluk en çok <see cref="StackedGapMax"/> satır.
    /// </summary>
    public const double StackedMinFont = 13;
    internal const double StackedShare = 0.45, StackedChars = 20, StackedGapMax = 1.2;

    /// <summary>Altyazı boyutu ayarının (TV pikseli, 1080p) panel yazısına çarpanı: varsayılan boyda 1.</summary>
    public static double TextScale(int fontSize) => Math.Min(MaxScale, Math.Max(MinScale, fontSize / (double)DefaultFontSize));
    internal const int DefaultFontSize = 46;
    internal const double MinScale = 0.75, MaxScale = 1.6;

    /// <summary>
    /// Tarafı hizadan belli olmayan balon oyuncunun mu: zemini belirgin mavi, doygun bir renk ya da açık mavimsi (GTA 6'nın
    /// giden balonu #D3DCF4; gelen balon kremdir).
    /// </summary>
    internal static bool IsOutgoing(PhoneTextStyle? style)
    {
        if (IsBlue(style)) return true;
        if (style?.Background is not { Length: 7 } hex || hex[0] != '#'
            || !int.TryParse(hex.AsSpan(1), System.Globalization.NumberStyles.HexNumber, null, out var value)) return false;
        int r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF;
        int max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
        return (max - min >= 70 && max >= 90) || (b - r >= 20 && b >= g);
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
