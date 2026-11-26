// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Bir ekran yazısının yerinde, arayüz Türkçe yapılmış gibi çizilmesi için göndericinin kareden ölçtükleri (TV pikselleri
/// okuyamaz). Yalnız yazı değişince ölçülür (Mac: CouchSubsCore/TextPaint.swift, Android: TextPaint.kt; aynı kurallar ve
/// eşikler). TV'ye öğenin <c>bg</c>, <c>bg2</c>, <c>bgDir</c>, <c>bgPat</c>, <c>fg</c>, <c>weight</c>, <c>upper</c>,
/// <c>align</c>, <c>lineH</c>, <c>cover</c>, <c>grow</c>, <c>group</c> alanlarıyla (çizim kipi: <c>mode</c>, <c>spot</c>,
/// <c>spotRoom</c>, <c>twinBox</c>, <c>radius</c>, <c>scale</c>, <c>tail</c>, <c>icon</c>, <c>edge</c>) gider; eski TV
/// bunları yok sayıp eski çizimi sürdürür.
/// </summary>
/// <param name="Background">Kutunun zemini (degradede başlangıç ucu: sol ya da üst). Opak çizilir.</param>
/// <param name="Pitch">Satır aralığı (bir satırın üstünden ötekinin üstüne), kareye oranla; tek satırda satır yüksekliği.</param>
/// <param name="Cover">
/// Özgün yazıyı tam örten kutu: yazı tanıma kutusu ve dışına taşan harf noktaları, en çok <see cref="TextPainter.MarginMax"/>
/// piksel payla. Simgeye doğru taşmaz.
/// </param>
public sealed record TextPaint(string Background, double Pitch, TextBox Cover)
{
    /// <summary>Yatay degrade (soldan sağa).</summary>
    public const string Horizontal = "h";
    /// <summary>Dikey degrade (üstten alta).</summary>
    public const string Vertical = "v";

    /// <summary>Degradenin öbür ucu (sağ ya da alt); düz zeminde null.</summary>
    public string? Background2 { get; init; }
    /// <summary>Degradenin yönü: <see cref="Horizontal"/> ya da <see cref="Vertical"/>; düz zeminde null.</summary>
    public string? Direction { get; init; }
    /// <summary>Zemin desenli (harita, dünya): <see cref="Background"/> ortalama renktir.</summary>
    public bool Patterned { get; init; }
    /// <summary>
    /// Kutunun yana uzayabileceği alan (yalnız tek satırlık etikette, hizanın açık tarafında): o yönde başka yazı, simge ya da
    /// kutu yok, yalnız oyunun zemini var. Simgeyle ya da komşuyla arada <see cref="ScreenFit.GapLines"/> kadar boşluk kalır.
    /// null: uzayamaz.
    /// </summary>
    public TextBox? Grow { get; init; }
    /// <summary>
    /// Aynı listede alt alta (ya da aynı satırda) duran, özgün hâlinde aynı boydaki etiketlerin ortak numarası; grubun hepsi
    /// aynı yazı boyunda çizilir. null: tek başına.
    /// </summary>
    public int? Group { get; init; }
    /// <summary>
    /// Yazı tanıma kutusunun ucundaki simge (menü simgesi, tuş simgesi) yazının hangi yanında ("left", "right"): örtü ve uzama
    /// o simgeye girmez, yazı o yana yaslanır (TV'ye <c>align</c> olarak gider). null: simge yok.
    /// </summary>
    public string? IconSide { get; init; }

    /// <summary>
    /// Çizim kipi (<see cref="TextPainter.Target.Kind"/> verilince seçilir; yalnız otomatik ekran yazısında):
    /// <see cref="PaintMode.Cover"/>, <see cref="PaintMode.Beside"/> ya da <see cref="PaintMode.Twin"/> (Sinan Bey: oyun dünyasının üstünde opak yama
    /// görünmesin). TV'ye <c>mode</c> olarak gider; eski TV yok sayıp örter.
    /// </summary>
    public string Mode { get; init; } = PaintMode.Cover;
    /// <summary>
    /// beside/twin: Türkçenin yazıldığı kutu (yanına yazmada özgün yazının yanındaki boş alan, örtü boyunda; ikizde özgün
    /// yazının ikiz paneldeki yeri). TV'ye <c>spot</c>.
    /// </summary>
    public TextBox? Spot { get; init; }
    /// <summary><see cref="Spot"/>'un yana uzayabileceği alan (yalnız sol ve sağ kenarı anlamlı). TV'ye <c>spotRoom</c>.</summary>
    public TextBox? SpotRoom { get; init; }
    /// <summary>
    /// twin: ikiz panelin kutusu (özgün panelin yanında, altında ya da üstünde, aynı boyda; çizici içeriğe göre uzatır).
    /// TV'ye <c>twinBox</c>.
    /// </summary>
    public TextBox? Twin { get; init; }
    /// <summary>twin: panelin köşe yarıçapı (ikizde), kare yüksekliğine oranla. TV'ye <c>radius</c>.</summary>
    public double Radius { get; init; }
    /// <summary>twin: ikizin özgüne oranı (<see cref="TextPainter.TwinScale"/>): yazı boyu ve satır aralığı bu katta. TV'ye <c>scale</c>.</summary>
    public double Scale { get; init; } = 1;
    /// <summary>twin: konuşma balonunun kuyruğu hangi alt köşede ("left"/"right"); null: kuyruk yok. TV'ye <c>tail</c>.</summary>
    public string? Tail { get; init; }
    /// <summary>twin: panelin solundaki kare resim (kişi resmi): karedeki yeri (kesmek için).</summary>
    public TextBox? Portrait { get; init; }
    /// <summary>twin: kişi resminin ikiz paneldeki yeri.</summary>
    public TextBox? PortraitTwin { get; init; }
    /// <summary>
    /// Kesilmiş resim (PNG, data: adresi; en çok <see cref="TextPainter.PortraitMax"/> piksel); çağıran keser
    /// (<see cref="TextPainter.PortraitImage(TextBox, Frame)"/>). TV'ye <c>icon</c> ({src, box}).
    /// </summary>
    public string? PortraitImage { get; init; }
    /// <summary>
    /// twin: özgün panelin kenar çizgisi (panelin hemen dışındaki düz renkli ince şerit; GTA 6 kartının üstündeki renkli
    /// çizgi): ikiz de aynı çizgiyle çizilir. null: çizgi yok. TV'ye <c>edge</c> ({color, top, right, bottom, left}).
    /// </summary>
    public EdgeLine? Edge { get; init; }

    /// <summary>Kenar çizgisi: rengi ve her yandaki kalınlığı (kare yüksekliğine oranla; 0: o yanda çizgi yok).</summary>
    public sealed record EdgeLine(string Color, double Top, double Right, double Bottom, double Left);

    /// <summary>Bu ölçüler <paramref name="area"/> içindeki oranlarsa, aynı yerin <paramref name="area"/>'yı içeren çerçevedeki oranları.</summary>
    public TextPaint PlacedIn(TextBox area) => this with
    {
        Cover = Cover.PlacedIn(area),
        Grow = Grow?.PlacedIn(area),
        Pitch = Pitch * (area.Bottom - area.Top),
        Spot = Spot?.PlacedIn(area),
        SpotRoom = SpotRoom?.PlacedIn(area),
        Twin = Twin?.PlacedIn(area),
        Radius = Radius * (area.Bottom - area.Top),
        Portrait = Portrait?.PlacedIn(area),
        PortraitTwin = PortraitTwin?.PlacedIn(area),
        Edge = Edge is { } edge
            ? edge with
            {
                Top = edge.Top * (area.Bottom - area.Top), Right = edge.Right * (area.Bottom - area.Top),
                Bottom = edge.Bottom * (area.Bottom - area.Top), Left = edge.Left * (area.Bottom - area.Top),
            }
            : null,
    };
}

/// <summary>
/// Çizim kipleri (<see cref="TextPaint.Mode"/>; Mac TextPaint.Mode, Android aynı adlar). Sinan Bey, beta.100: oyun
/// arayüzünün hiçbir öğesi örtülmez; örtme yalnız son çare.
/// </summary>
public static class PaintMode
{
    /// <summary>
    /// Örtme: türü belli olmayan yazı ("Ekranı çevir"), telefon ve hiç boş yer bulunamayan yazı: özgün yazıyı örten kutu
    /// (eski davranış).
    /// </summary>
    public const string Cover = "cover";
    /// <summary>
    /// Yanına yazma: zeminsiz satır (soldaki dikey menü, sekme çubuğu, tuş/ipucu listesi, kart başlığı, oyun dünyasındaki
    /// istem): özgün yazı yerinde kalır, Türkçe arka plansız, özgün stille (renk, kalınlık, dar aile, büyük harf, kontur)
    /// yanındaki boş alana yazılır. Listede bütün Türkçeler aynı tarafta, aynı boyda ve hizada (sağa yaslı listede solda
    /// sağa yaslı tek sütun, sola yaslı listede sağda, sekme çubuğunda altta).
    /// </summary>
    public const string Beside = "beside";
    /// <summary>
    /// İkiz: kutu (görev paneli, harita mekân kartı, bildirim, ipucu kutusu, widget) örtülmez; en uygun boş yere (yan › alt
    /// › üst) özgün kutunun aynısı (zemin, kenar çizgisi, köşe, kuyruk, kişi resmi, iç boşluk, aynı yazı boyu) çizilir,
    /// Türkçenin tamamı oraya yazılır; kutu içeriğe göre uzar.
    /// </summary>
    public const string Twin = "twin";
}

/// <summary>
/// <see cref="TextPaint"/> ölçümü. Piksel erişimi soyuttur (<c>color(x, y)</c>): ortak deneme dosyası (core
/// Fixtures/text-paint.json) üç platformda aynı yapay kareyi kurar.
/// </summary>
public static class TextPainter
{
    /// <summary>
    /// Ölçülecek yazı: kareye oranla kutusu ve satır yüksekliği, özgün satır sayısı, sampler'ın bulduğu zemin/yazı rengi ve
    /// hizası ("left", "right", "center").
    /// </summary>
    /// <remarks>
    /// <c>Words</c>: okunan yazının sözcük sayısı (simge sanılan karakterler sayılmaz, <see cref="WordCount"/>); 0:
    /// bilinmiyor, kutunun ucundaki simge aranmaz. <c>Kind</c>: yazının türü; verilirse çizim kipi seçilir
    /// (<see cref="TextPaint.Mode"/>), null: hep örtme ("Ekranı çevir"). <c>Prompt</c>: yazı bir tuş istemi/eylemi ("Hold L2
    /// to aim"): düz zeminde de yanına yazılabilir.
    /// </remarks>
    public sealed record Target(TextBox Box, double LineHeight, int Rows, string Background, string Foreground, bool Upper,
                                string Align, int Words = 0, ScreenTextKind? Kind = null, bool Prompt = false);

    /// <summary>
    /// Kutunun ucundaki simgeyi yazıdan ayıran en dar boşluk, satır yüksekliğinin katı (harf arası bundan dardır; GTA 6
    /// menüsünde simgeyle yazı arası ~0,4 satır).
    /// </summary>
    public const double IconGapLines = 0.3;
    /// <summary>Simge parçasının genişliği satır yüksekliğinin bu katları arasında ("I" harfi gibi ince parça simge sayılmaz).</summary>
    public const double IconMinWide = 0.45;
    public const double IconMaxWide = 1.6;
    /// <summary>Simge sanılıp yazı olarak okunan karakterler (GTA 6 menü simgesi "I", "II"; tuş simgeleri).</summary>
    private const string IconGlyphs = "I|l![]()©®@○◯●□■△▲✕✖×◎⊗⊙";

    /// <summary>
    /// Okunan yazının sözcük sayısı: simge sanılan bir iki karakterlik parçalar ve harfi/rakamı olmayan parçalar sayılmaz
    /// ("I Map" → 1, "SELECT ⊗" → 1, "- SMASH 'N' GRABS" → 3, "• Objective" → 1). Menü simgesi (yön tuşu, renkli nokta)
    /// "-", "•", "+" diye okununca sözcük sayılıyor, simge bulunmuyordu: kutu simgenin üstüne çiziliyordu (#1268, #1270;
    /// Mac ile aynı).
    /// </summary>
    public static int WordCount(string text) =>
        IconText.Plain(text).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Count(token => !(token.Length <= 2 && token.All(c => IconGlyphs.Contains(c))) && token.Any(char.IsLetterOrDigit));

    /// <summary>
    /// Kutunun ([l, r), piksel) ucundaki simge: harf sütunları (<paramref name="ink"/>) <see cref="IconGapLines"/> satırdan
    /// geniş boşluklarla parçalara bölünür; parça sayısı sözcük sayısından çoksa uçtaki simge genişliğindeki
    /// (<see cref="IconMinWide"/>-<see cref="IconMaxWide"/> satır) parça simgedir. İki uç da uyarsa hizanın yanı (sola yaslıda
    /// sol, öbürlerinde sağ) önce; ikincisi ancak iki fazla parça varsa. Simgeler çıkınca kalan parça sözcüklerden çoksa simge
    /// yoktur. Dönen: simgeler ve onlar çıkınca yazının sol/sağ kenarı.
    /// </summary>
    internal static ((int L, int R)? Left, (int L, int R)? Right, int TextLeft, int TextRight) IconSpans(
        int l, int r, double line, int words, string align, Func<int, bool> ink)
    {
        if (words <= 0 || r - l < 2) return (null, null, l, r);
        var gap = Math.Max(2, RoundHalfUp(IconGapLines * line));
        var spans = new List<(int L, int R)>();
        int? start = null;
        int last = l, blank = 0;
        for (var x = l; x < r; x++)
        {
            if (ink(x))
            {
                start ??= x;
                last = x;
                blank = 0;
            }
            else if (start is { } s)
            {
                blank++;
                if (blank >= gap) { spans.Add((s, last + 1)); start = null; blank = 0; }
            }
        }
        if (start is { } open) spans.Add((open, last + 1));
        if (spans.Count < 2 || spans.Count <= words) return (null, null, l, r);
        bool IsIcon((int L, int R) span)
        {
            double wide = span.R - span.L;
            return wide >= IconMinWide * line && wide <= IconMaxWide * line;
        }
        var extra = spans.Count - words;
        var first = spans[0];
        var final = spans[^1];
        (int L, int R)? left = null, right = null;
        if (align == "left")
        {
            if (IsIcon(first)) left = first;
            if (IsIcon(final) && (left == null || extra >= 2)) right = final;
        }
        else
        {
            if (IsIcon(final)) right = final;
            if (IsIcon(first) && (right == null || extra >= 2)) left = first;
        }
        // Simgeler çıkınca kalan parçalar sözcüklerden çok olamaz: harfleri aralıklı tek sözcük simge sanılmaz.
        if (spans.Count - (left == null ? 0 : 1) - (right == null ? 0 : 1) > words) return (null, null, l, r);
        return (left, right, left != null ? spans[1].L : l, right != null ? spans[^2].R : r);
    }

    /// <summary>Nokta zeminden bu kadar (en büyük renk bileşeni farkı) uzak ve yazı rengine zeminden yakınsa harf noktasıdır.</summary>
    public const int InkDistance = 40;
    /// <summary>Bir satır/sütunun en az bu kadarı harf noktasıysa orada yazı sürer.</summary>
    public const double InkShare = 0.03;
    /// <summary>Kutu yazı tanıma kutusunun dışına en çok bu kadar satır yüksekliği uzar (taşan harf ucu).</summary>
    public const double ReachLines = 0.5;
    /// <summary>Çok satırlı yazıda tanıma kutusunun kaçırdığı satır ucu: örtü en çok bu kadar satır yüksekliği daha uzar ...</summary>
    public const double SpillLines = 8.0;
    /// <summary>... harf ve sözcük arasındaki boşluk en çok bu kadar satır yüksekliğiyse (sözcük arası ~0,25; sütun arası çok daha geniş).</summary>
    public const double BridgeLines = 0.45;

    /// <summary><paramref name="start"/>'tan <paramref name="step"/> yönünde harf sütunu aranır: boşluk <see cref="BridgeLines"/>
    /// satırı aşınca, engel (başka hedef, simge) gelince ya da <see cref="SpillLines"/> satır gidilince durur. Dönen: bulunan son
    /// harf sütunu (yoksa null). Mac/iPhone TextPainter.spill, Android TextPainter.spill ile aynı.</summary>
    internal static int? Spill(int start, int step, double line, Func<int, bool> ink, Func<int, bool> blocked)
    {
        int bridge = Math.Max(1, RoundHalfUp(BridgeLines * line)), most = Math.Max(1, RoundHalfUp(SpillLines * line));
        int? last = null;
        int blank = 0, x = start;
        while (Math.Abs(x - start) < most && !blocked(x))
        {
            if (ink(x)) { last = x; blank = 0; }
            else if (++blank > bridge) break;
            x += step;
        }
        return last;
    }
    /// <summary>Kenar payı: satır yüksekliğinin bu kadarı, en az 1, en çok <see cref="MarginMax"/> piksel.</summary>
    public const double MarginLines = 0.08;
    public const int MarginMax = 3;
    /// <summary>İki uç arasındaki fark (en büyük renk bileşeni) en az bu kadarsa zemin degradedir.</summary>
    public const int GradientStep = 10;
    /// <summary>Zeminin kendi içindeki sapması bundan büyükse zemin desenlidir.</summary>
    public const double PatternDeviation = TextStyleSampler.FlatDeviation;
    /// <summary>Kenar şeridinin ortalaması sampler'ın zemininden bu kadar uzaksa (seçili satırın kendi kutusu dar) sampler'ınki kalır.</summary>
    public const int TrustDistance = 48;
    /// <summary>Boş alan en çok bu kadar satır yüksekliği taranır.</summary>
    public const double GrowLines = 12.0;
    /// <summary>Aynı grup: satır yükseklikleri en çok bu oranda farklı (<see cref="ScreenFit.SameLine"/>).</summary>
    public const double SameLine = ScreenFit.SameLine;
    /// <summary>Aynı satırdaki tuş istemlerinde (tuş çubuğu) satır yüksekliği farkı en çok bu oranda (simge kimi kutuya katılır, #1360).</summary>
    public const double PromptLine = 0.35;

    private static int RoundHalfUp(double value) => (int)Math.Round(value, MidpointRounding.AwayFromZero);

    // Kip seçimi sabitleri (Mac TextPaint.swift, Android TextPaint.kt aynı).

    /// <summary>Panel taramasında nokta zeminden en çok bu kadar uzaksa (en büyük renk bileşeni farkı) panelin zeminidir.</summary>
    public const int PanelTolerance = 24;
    /// <summary>Bir satır/sütunun en az bu kadarı zemin (ya da yazı) ise panel o yöne sürer.</summary>
    public const double PanelShare = 0.7;
    /// <summary>Panel karenin en çok bu kadarı genişlikte/yükseklikte; daha büyüğü (gökyüzü, menünün kendisi) panel sayılmaz.</summary>
    public const double PanelMaxWidth = 0.45;
    public const double PanelMaxHeight = 0.35;
    /// <summary>Panel yazının her yanında en az bu kadar satır yüksekliği (en az 2 piksel) taşmalı; taşmıyorsa düz kutudur (örtülür).</summary>
    public const double PanelPadLines = 0.2;
    /// <summary>Tek satırlık tek yazının kutusu (ikiz) yazıyı her yanda en çok bu kadar satır yüksekliği aşar (yanlarda
    /// yazının genişliği kadar da olabilir); yalnız tuş istemlerinin kutusu her yanda en çok <see cref="PromptPadLines"/>.
    /// Daha büyük düz alan (koyu oyun dünyası, ekranın altındaki karartı) kutu değildir: ikizi dev bir kutu olurdu
    /// (beta.103, TCL Android TV; Mac TextPainter.labelPadLines, Android LABEL_PAD_LINES aynı).</summary>
    public const double LabelPadLines = 3.0;
    public const double PromptPadLines = 2.5;
    /// <summary>Köşe yuvarlak: panelin köşesinden köşegen boyunca en az bu kadar nokta zemin değil (aynı kenardaki iki köşede).</summary>
    public const int CornerMin = 2;
    /// <summary>Yanına yazmada bir sütunda/satırda yazı rengine (<see cref="BesideInk"/> kadar yakın) noktaların payı bundan azsa alan boştur.</summary>
    public const int BesideInk = 48;
    public const double BesideShare = 0.1;
    /// <summary>Türkçenin özgün yazıdan uzaklığı, satır yüksekliğinin katı.</summary>
    public const double BesideGapLines = 0.5;
    /// <summary>Yanına yazma alanı en çok özgün yazının bu katı (+ bir satır yüksekliği) genişlikte taranır.</summary>
    public const double BesideMax = 1.6;
    /// <summary>
    /// Listede (grup) Türkçe sütunu özgün yazıdan en çok bu kadar satır yüksekliği uzakta olabilir (kısa satırla sütun
    /// arasındaki boşluk da boş olmalı).
    /// </summary>
    public const double BesideReachLines = 12.0;
    /// <summary>İkiz panel özgün panelle aynı boyda (Sinan Bey, beta.100: "AYNI punto, küçültme yok"; #1296'daki 0,58 kalktı).</summary>
    public const double TwinScale = 1.0;
    /// <summary>Birden çok tek satırlık etiketin kutusunda yazıların kapladığı en küçük pay; altındaysa kutu değildir (#1362).</summary>
    public const double TwinFill = 0.08;
    /// <summary>İkizdeki yazı özgün panelin genişliğini en çok bu katı kadar aşabilir (boş yer varsa; kutu içeriğe göre uzar).</summary>
    public const double TwinWiden = 0.5;
    /// <summary>Kenar çizgisi en çok bu kadar piksel kalın aranır.</summary>
    public const int EdgeMax = 8;
    /// <summary>Kişi resmi (ikiz panelde gösterilir) en çok bu kadar piksel kenarlı kesilir.</summary>
    public const int PortraitMax = 40;

    /// <summary>
    /// Yazının (örtü kutusu [l, r) x [t, b)) çevresindeki düz alan: kutu, satır/sütunlarının en az <see cref="PanelShare"/>'i
    /// zemin (<paramref name="like"/>: zemin, yazının kendi örtü kutusu ya da başka hedef; harf noktası sayılmaz, koyu oyun
    /// dünyası koyu yazıya benzer) olduğu sürece dört yana büyür. Karenin kenarına değen ya da
    /// <see cref="PanelMaxWidth"/>/<see cref="PanelMaxHeight"/>'tan büyük alan açık zemindir (gökyüzü, menünün kendisi): null.
    /// </summary>
    /// <summary>
    /// [from, until) aralığında step adımla alınan noktaların en az share'i ok mu (en az bir nokta). Sonuç belli olunca
    /// durur: kalan noktalar sonucu değiştiremez (ok yan etkisiz; bütün kare ölçümünde çağrı sayısı azalır, sonuç aynı).
    /// Mac/iPhone TextPaint.swift ve Android TextPaint.kt aynı.
    /// </summary>
    internal static bool ShareAtLeast(int from, int until, int step, double share, Func<int, bool> ok)
    {
        if (until <= from) return false;
        var total = (until - from + step - 1) / step;
        var need = share * total;
        int hits = 0, seen = 0;
        for (var at = from; at < until; at += step)
        {
            if (ok(at))
            {
                hits++;
                if (hits >= need) return true;
            }
            seen++;
            if (hits + (total - seen) < need) return false;
        }
        return hits >= need;
    }

    /// <summary>
    /// Boş alan sütunu/satırı (MeasureRoom): [from, until) noktalarından hiçbiri engel (null) değil ve yazı rengindekiler
    /// BesideShare'den az. İlk engelde ya da pay dolunca durur (sonuç aynı).
    /// </summary>
    internal static bool RoomOpen(int from, int until, Func<int, bool?> free)
    {
        if (until <= from) return false;
        var limit = BesideShare * (until - from);
        var ink = 0;
        for (var at = from; at < until; at++)
        {
            var cell = free(at);
            if (cell == null) return false;
            if (cell == true && ++ink >= limit) return false;
        }
        return true;
    }

    internal static (int L, int T, int R, int B)? FindPanel(int l, int t, int r, int b, int width, int height,
                                                           Func<int, int, bool> like)
    {
        bool Row(int y, int x0, int x1) => ShareAtLeast(x0, x1, Math.Max(1, (x1 - x0) / 64), PanelShare, x => like(x, y));
        bool Column(int x, int y0, int y1) => ShareAtLeast(y0, y1, Math.Max(1, (y1 - y0) / 64), PanelShare, y => like(x, y));
        if (r <= l || b <= t) return null;
        int maxW = (int)(PanelMaxWidth * width), maxH = (int)(PanelMaxHeight * height);
        int pl = Math.Max(0, l), pt = Math.Max(0, t), pr = Math.Min(width, r), pb = Math.Min(height, b);
        var grew = true;
        while (grew)
        {
            grew = false;
            while (pl > 0 && Column(pl - 1, pt, pb)) { pl--; grew = true; if (pr - pl > maxW) return null; }
            while (pr < width && Column(pr, pt, pb)) { pr++; grew = true; if (pr - pl > maxW) return null; }
            while (pt > 0 && Row(pt - 1, pl, pr)) { pt--; grew = true; if (pb - pt > maxH) return null; }
            while (pb < height && Row(pb, pl, pr)) { pb++; grew = true; if (pb - pt > maxH) return null; }
        }
        if (pl == 0 || pt == 0 || pr == width || pb == height) return null;
        return (pl, pt, pr, pb);
    }

    /// <summary>
    /// Panelin ([l, r) x [t, b)) köşe yarıçapı (piksel) ve konuşma balonunun kuyruğu: köşeler (<paramref name="ground"/>:
    /// yalnız zemin) köşegen boyunca taranır; üst ya da alt kenarın iki köşesinde en az <see cref="CornerMin"/> nokta zemin
    /// değilse panel yuvarlaktır, yarıçap köşegendeki mesafeden (k / (1 − 1/√2)). Üst köşeler yuvarlakken alt köşelerden
    /// yalnız biri köşeliyse o köşede balonun kuyruğu vardır ("left"/"right"). null: köşeli kutu.
    /// </summary>
    internal static (double Radius, string? Tail)? CornerRadius(int l, int t, int r, int b, Func<int, int, bool> ground)
    {
        var limit = Math.Max(1, Math.Min(r - l, b - t) / 4);
        int Corner(int x, int y, int dx, int dy)
        {
            var k = 0;
            while (k <= limit && !ground(x + (dx * k), y + (dy * k))) k++;
            return k;
        }
        int tl = Corner(l, t, 1, 1), tr = Corner(r - 1, t, -1, 1);
        int bl = Corner(l, b - 1, 1, -1), br = Corner(r - 1, b - 1, -1, -1);
        bool Round(int k) => k >= CornerMin && k <= limit;
        bool top = Round(tl) && Round(tr), bottom = Round(bl) && Round(br);
        if (!top && !bottom) return null;
        var ks = new List<int>();
        if (top) { ks.Add(tl); ks.Add(tr); }
        if (bottom) { ks.Add(bl); ks.Add(br); }
        var radius = (double)ks.Sum() / ks.Count / (1 - (1 / Math.Sqrt(2.0)));
        string? tail = !top || bottom ? null : !Round(bl) && Round(br) ? "left" : Round(bl) && !Round(br) ? "right" : null;
        return (radius, tail);
    }

    /// <summary>
    /// Panelin solundaki kare resim (kişi resmi): panelin solu ile yazının arası, yazının satırı çevresinde (bir satır
    /// yüksekliği yukarı/aşağı); <paramref name="off"/> (zeminden belirgin ayrılan, başka yazı olmayan) noktaların sınırı. En
    /// az 0,8 satır yüksekliği (en az 6 piksel), en çok 4 satır yüksekliği, kareye yakın (0,75–1,33) ve yazıdan ayrıksa resimdir.
    /// </summary>
    internal static (int L, int T, int R, int B)? Portrait(int panelLeft, int panelTop, int panelBottom, int l, int t, int b,
                                                          double line, Func<int, int, bool> off)
    {
        int x0 = panelLeft + 2, x1 = l;
        int y0 = Math.Max(panelTop + 2, t - RoundHalfUp(line)), y1 = Math.Min(panelBottom - 2, b + RoundHalfUp(line));
        if (x1 <= x0 || y1 <= y0) return null;
        int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++)
            {
                if (!off(x, y)) continue;
                minX = Math.Min(minX, x);
                maxX = Math.Max(maxX, x);
                minY = Math.Min(minY, y);
                maxY = Math.Max(maxY, y);
            }
        if (maxX < 0) return null;
        int w = maxX - minX + 1, h = maxY - minY + 1;
        var least = Math.Max(6, RoundHalfUp(0.8 * line));
        if (w < least || h < least || w > 4 * line || h > 4 * line || w < 0.75 * h || w > 1.33 * h
            || maxX + 1 + Math.Max(2, RoundHalfUp(ScreenFit.GapLines * line)) > l) return null;
        return (minX, minY, maxX + 1, maxY + 1);
    }

    /// <summary>
    /// Kişi resmini kareden keser: en çok <paramref name="largest"/> (varsayılan <see cref="PortraitMax"/>; telefon
    /// listesinin avatarı <see cref="PhoneListLook.AvatarMax"/>) piksel kenarlı (en yakın nokta örneklemesi), opak PNG data: adresi.
    /// </summary>
    public static string? PortraitImage(TextBox box, int width, int height, Func<int, int, (int R, int G, int B)> color,
                                        int largest = PortraitMax)
    {
        int l = Math.Max(0, RoundHalfUp(box.Left * width)), t = Math.Max(0, RoundHalfUp(box.Top * height));
        int r = Math.Min(width, RoundHalfUp(box.Right * width)), b = Math.Min(height, RoundHalfUp(box.Bottom * height));
        if (r - l < 2 || b - t < 2) return null;
        var side = Math.Max(r - l, b - t);
        int ow = Math.Max(1, Math.Min(r - l, (r - l) * largest / side)), oh = Math.Max(1, Math.Min(b - t, (b - t) * largest / side));
        var pixels = new byte[ow * oh * 4];
        for (var j = 0; j < oh; j++)
            for (var i = 0; i < ow; i++)
            {
                var c = color(l + (i * (r - l) / ow), t + (j * (b - t) / oh));
                var p = ((j * ow) + i) * 4;
                // Kare BGRA (ButtonIcons.Png RGBA'ya çevirir).
                pixels[p] = (byte)Math.Clamp(c.B, 0, 255);
                pixels[p + 1] = (byte)Math.Clamp(c.G, 0, 255);
                pixels[p + 2] = (byte)Math.Clamp(c.R, 0, 255);
                pixels[p + 3] = 255;
            }
        return "data:image/png;base64," + Convert.ToBase64String(ButtonIcons.Png(new Frame(pixels, ow, oh, ow * 4)));
    }

    /// <summary>Kare üzerinden kişi resmi (BGRA noktalar).</summary>
    public static string? PortraitImage(TextBox box, Frame frame)
    {
        if (!frame.IsConsistent || frame.Width <= 0 || frame.Height <= 0) return null;
        return PortraitImage(box, frame.Width, frame.Height, (x, y) =>
        {
            var p = (y * frame.Stride) + (x * 4);
            return (frame.Pixels[p + 2], frame.Pixels[p + 1], frame.Pixels[p]);
        });
    }

    /// <summary>Yanına yazma için bir hedefin çevresindeki boş alan (piksel; döngüde ölçülür, kip kararı döngüden sonra verilir).</summary>
    internal sealed class Room
    {
        /// <summary>Örtü kutusu ve satır yüksekliği.</summary>
        public int L, T, R, B;
        public double Line;
        /// <summary>
        /// Türkçenin özgünden uzaklığı (<see cref="BesideGapLines"/>), öbür uçta engelden uzaklığı (<see cref="ScreenFit.GapLines"/>)
        /// ve en çok genişliği (<see cref="BesideMax"/>).
        /// </summary>
        public int Near, Far, Most;
        public bool IconLeft, IconRight;
        /// <summary>Örtünün solundan/sağından art arda boş sütun sayısı (en çok <c>Cap</c>; azsa alan bir engelle bitti).</summary>
        public int Left, Right, Cap;
        /// <summary>Altından/üstünden art arda boş satır sayısı.</summary>
        public int Down, Up;
        /// <summary>
        /// Altındaki/üstündeki yazı şeridinde (yakın boşluktan sonra örtü yüksekliği) solda/sağda art arda boş sütun (en çok
        /// <c>Half</c> + <c>Far</c>; Mac <c>side</c>).
        /// </summary>
        public int DownLeft, DownRight, UpLeft, UpRight, Half;
    }

    internal enum Side { Left, Right, Below, Above }

    /// <summary>Yanına yazma yeri (piksel): Türkçenin kutusu ve uzayabileceği sol/sağ sınır.</summary>
    internal record struct Spot(int L, int T, int R, int B, int RoomL, int RoomR);

    /// <summary>
    /// Boş alan ölçümü. <paramref name="free"/>: null başka hedef ya da simge (alan orada biter), true yazı rengine yakın
    /// nokta, false boş zemin. Bir sütun/satır, yazı rengindeki noktaları <see cref="BesideShare"/>'den azsa boştur.
    /// <paramref name="wall"/>: düz zeminli yazıda zemin de yazı rengi de olmayan nokta; sütununun en az <see cref="PanelShare"/>'i
    /// böyleyse (dikey panel kenarı, ayırıcı çizgi, başka renkte panel) yana uzanan alan orada biter. <paramref name="walls"/>
    /// false: desenli zemin, denetlenmez.
    /// </summary>
    internal static Room MeasureRoom(int l, int t, int r, int b, double line, int width, int height, bool iconLeft,
                                     bool iconRight, Func<int, int, bool?> free, bool walls = false, Func<int, int, bool>? wall = null)
    {
        int w = r - l, h = b - t;
        var room = new Room
        {
            L = l, T = t, R = r, B = b, Line = line, Near = Math.Max(2, RoundHalfUp(BesideGapLines * line)),
            Far = Math.Max(1, (int)Math.Ceiling(ScreenFit.GapLines * line)),
            Most = RoundHalfUp((BesideMax * Math.Max(0, w)) + line), IconLeft = iconLeft, IconRight = iconRight,
        };
        if (w <= 0 || h <= 0 || t < 0 || b > height) return room;
        bool Column(int x, int y0, int y1)
        {
            if (x < 0 || x >= width || y0 < 0 || y1 > height || y1 <= y0) return false;
            if (walls && wall is not null && ShareAtLeast(y0, y1, 1, PanelShare, y => wall(x, y))) return false;
            return RoomOpen(y0, y1, y => free(x, y));
        }
        bool Row(int y, int x0, int x1) =>
            y >= 0 && y < height && x0 >= 0 && x1 <= width && x1 > x0 && RoomOpen(x0, x1, x => free(x, y));
        int Run(int x, int step, int y0, int y1, int cap)
        {
            var n = 0;
            while (n < cap && Column(x + (step * n), y0, y1)) n++;
            return n;
        }
        int Rows(int y, int step, int cap)
        {
            var n = 0;
            while (n < cap && Row(y + (step * n), l, r)) n++;
            return n;
        }
        room.Cap = Math.Min(width, room.Near + room.Most + room.Far + RoundHalfUp(BesideReachLines * line));
        room.Left = iconLeft ? 0 : Run(l - 1, -1, t, b, room.Cap);
        room.Right = iconRight ? 0 : Run(r, 1, t, b, room.Cap);
        var vertical = room.Near + (2 * h);
        room.Down = Rows(b + room.Near, 1, vertical);
        room.Up = Rows(t - room.Near - 1, -1, vertical);
        room.Half = w / 2;
        int low = b + room.Near, high = t - room.Near - h;
        if (low + h <= height)
        {
            room.DownLeft = Run(l - 1, -1, low, low + h, room.Half + room.Far);
            room.DownRight = Run(r, 1, low, low + h, room.Half + room.Far);
        }
        if (high >= 0)
        {
            room.UpLeft = Run(l - 1, -1, high, high + h, room.Half + room.Far);
            room.UpRight = Run(r, 1, high, high + h, room.Half + room.Far);
        }
        return room;
    }

    /// <summary>
    /// Yanına yazma yeri (Sinan Bey: "SELAMLA  GREET"; beta.100: menülerde de). <paramref name="edge"/>: listede ortak kenar
    /// (solda Türkçenin sağ kenarı, sağda sol kenarı, altta üstü, üstte altı); null: hedefin kendi kenarından yakın boşluk
    /// kadar. Solda/sağda alan en az örtü genişliğinde olmalı (Türkçe <c>Most</c>'a kadar uzar); altta/üstte örtü yüksekliği
    /// kadar satır boş olmalı (Türkçe iki yana yarım genişliğe kadar uzar). Simgenin olduğu yana yazılmaz.
    /// </summary>
    internal static Spot? PlaceSpot(Room m, Side side, int? edge)
    {
        int w = m.R - m.L, h = m.B - m.T;
        if (w <= 0 || h <= 0) return null;
        int Usable(int n, int cap) => n - (n < cap ? m.Far : 0);
        (int L, int R) Spread(int left, int right)
        {
            var cap = m.Half + m.Far;
            return (m.L - Math.Max(0, Math.Min(m.Half, Usable(left, cap))), m.R + Math.Max(0, Math.Min(m.Half, Usable(right, cap))));
        }
        switch (side)
        {
            case Side.Left:
            {
                if (m.IconLeft) return null;
                var e = edge ?? (m.L - m.Near);
                var gap = m.L - e;
                if (gap < m.Near) return null;
                var room = Math.Min(m.Most, Usable(m.Left, m.Cap) - gap);
                if (room < w) return null;
                return new Spot(e - w, m.T, e, m.B, e - room, e);
            }
            case Side.Right:
            {
                if (m.IconRight) return null;
                var e = edge ?? (m.R + m.Near);
                var gap = e - m.R;
                if (gap < m.Near) return null;
                var room = Math.Min(m.Most, Usable(m.Right, m.Cap) - gap);
                if (room < w) return null;
                return new Spot(e, m.T, e + w, m.B, e, e + room);
            }
            case Side.Below:
            {
                var top = edge ?? (m.B + m.Near);
                if (top - m.B < m.Near || m.Down < top + h - (m.B + m.Near)) return null;
                var (roomL, roomR) = Spread(m.DownLeft, m.DownRight);
                return new Spot(m.L, top, m.R, top + h, roomL, roomR);
            }
            default:
            {
                var bottom = edge ?? (m.T - m.Near);
                if (m.T - bottom < m.Near || bottom - h < 0 || m.Up < m.T - m.Near - (bottom - h)) return null;
                var (roomL, roomR) = Spread(m.UpLeft, m.UpRight);
                return new Spot(m.L, bottom - h, m.R, bottom, roomL, roomR);
            }
        }
    }

    /// <summary>
    /// Panelin ([l, r) x [t, b)) kenar çizgisi: her yanda panelin hemen dışındaki 1…<see cref="EdgeMax"/> piksellik düz
    /// renkli şerit (satır/sütun noktalarının en az %80'i ortalamasına <see cref="PanelTolerance"/> kadar yakın, zeminden
    /// uzak) ve ötesinde o renk biter. Çizginin rengi ilk bulunan yanınki; öbür yanlar ancak aynı renkteyse. null: çizgi yok.
    /// </summary>
    internal static ((int R, int G, int B) Color, int Top, int Right, int Bottom, int Left)? Edges(
        int l, int t, int r, int b, int width, int height, (int R, int G, int B) ground, Func<int, int, bool> blocked,
        Func<int, int, (int R, int G, int B)> color)
    {
        bool InFrame((int X, int Y) p) => p.X >= 0 && p.X < width && p.Y >= 0 && p.Y < height;
        // Yanın k. dış çizgisinin rengi (düzse).
        (int R, int G, int B)? Strip(List<(int X, int Y)> points)
        {
            if (points.Count == 0 || !points.All(InFrame) || points.Any(p => blocked(p.X, p.Y))) return null;
            var colors = points.Select(p => color(p.X, p.Y)).ToList();
            var average = Mean(colors);
            if (colors.Count(c => Distance(c, average) <= PanelTolerance) < 0.8 * colors.Count) return null;
            return average;
        }
        List<(int X, int Y)> Horizontal(int y)
        {
            var step = Math.Max(1, (r - l) / 32);
            var points = new List<(int X, int Y)>();
            for (var x = l; x < r; x += step) points.Add((x, y));
            return points;
        }
        List<(int X, int Y)> Vertical(int x)
        {
            var step = Math.Max(1, (b - t) / 32);
            var points = new List<(int X, int Y)>();
            for (var y = t; y < b; y += step) points.Add((x, y));
            return points;
        }
        (int R, int G, int B)? reference = null;
        // Kalınlık: line(k) (k = 1, 2, …) aynı renkte sürdükçe; EdgeMax'a varan ya da karenin kenarına değen şerit çizgi değildir.
        int Thickness(Func<int, List<(int X, int Y)>> line)
        {
            if (Strip(line(1)) is not { } first || Distance(first, ground) <= PanelTolerance
                || (reference is { } known && Distance(known, first) > PanelTolerance)) return 0;
            var k = 1;
            while (k < EdgeMax && Strip(line(k + 1)) is { } next && Distance(next, first) <= PanelTolerance) k++;
            if (k >= EdgeMax || !line(k + 1).All(InFrame)) return 0;
            reference ??= first;
            return k;
        }
        var top = Thickness(k => Horizontal(t - k));
        var bottom = Thickness(k => Horizontal(b - 1 + k));
        var left = Thickness(k => Vertical(l - k));
        var right = Thickness(k => Vertical(r - 1 + k));
        if (reference is not { } found || top + bottom + left + right == 0) return null;
        return (found, top, right, bottom, left);
    }

    /// <summary>Ölçümler (hedeflerle aynı sırada). <paramref name="width"/>/<paramref name="height"/>: karenin piksel boyu.</summary>
    public static IReadOnlyList<TextPaint> Paints(IReadOnlyList<Target> targets, int width, int height,
                                                  Func<int, int, (int R, int G, int B)> color)
    {
        if (width <= 0 || height <= 0) return [];
        double fw = width, fh = height;
        // Hedeflerin piksel kutuları (öbür hedefler engeldir); karenin dışına taşan kutu kareye kırpılır (#1255).
        static int Pixel(double v, int size, bool up)
        {
            if (!double.IsFinite(v)) return v > 0 ? size : 0;
            var p = up ? Math.Ceiling(v * size) : Math.Floor(v * size);
            return (int)Math.Min(size, Math.Max(0, p));
        }
        var rects = targets.Select(t => (L: Pixel(t.Box.Left, width, false), T: Pixel(t.Box.Top, height, false),
                                         R: Pixel(t.Box.Right, width, true), B: Pixel(t.Box.Bottom, height, true))).ToArray();
        var result = new List<TextPaint>(targets.Count);
        // Kip seçimi için: örtü kutuları (piksel), satır yükseklikleri, zeminler ve panel adayları.
        var covers = new List<(int L, int T, int R, int B)>();
        var lines = new List<double>();
        var grounds = new List<(int R, int G, int B)>();
        var panels = new SortedDictionary<int, (int L, int T, int R, int B)>();
        // Yanına yazma için her hedefin çevresindeki boş alan (yalnız kipi seçilen yazıda).
        var rooms = new List<Room?>();
        // Bir hedefin kutusu (except hariç) bu noktada mı.
        bool RectHit(int x, int y, int? except)
        {
            for (var j = 0; j < rects.Length; j++)
                if (j != except && x >= rects[j].L && x < rects[j].R && y >= rects[j].T && y < rects[j].B) return true;
            return false;
        }
        for (var index = 0; index < targets.Count; index++)
        {
            var target = targets[index];
            var bg = Rgb(target.Background);
            var fg = Rgb(target.Foreground);
            var line = Math.Max(1, target.LineHeight * fh);
            bool IsInk((int R, int G, int B) c)
            {
                var toBg = Distance(c, bg);
                return toBg > InkDistance && Distance(c, fg) < toBg;
            }
            // Kutunun ucundaki kendi simgesi (0. adım): öbür hedefler gibi engeldir; araya ScreenFit.GapLines boşluk kalır.
            var zones = new List<(int L, int R)>();
            bool Others(int x, int y)
            {
                foreach (var zone in zones) if (x >= zone.L && x < zone.R) return true;
                for (var j = 0; j < rects.Length; j++)
                    if (j != index && x >= rects[j].L && x < rects[j].R && y >= rects[j].T && y < rects[j].B) return true;
                return false;
            }
            bool InkRow(int y, int x0, int x1)
            {
                if (y < 0 || y >= height || x1 <= x0) return false;
                var step = Math.Max(1, (x1 - x0) / 200);
                int n = 0, ink = 0;
                for (var x = Math.Max(0, x0); x < Math.Min(width, x1); x += step)
                {
                    if (Others(x, y)) return false;
                    n++;
                    if (IsInk(color(x, y))) ink++;
                }
                return n > 0 && ink >= Math.Max(2, (int)Math.Ceiling(InkShare * n));
            }
            bool InkColumn(int x, int y0, int y1)
            {
                if (x < 0 || x >= width || y1 <= y0) return false;
                int n = 0, ink = 0;
                for (var y = Math.Max(0, y0); y < Math.Min(height, y1); y++)
                {
                    if (Others(x, y)) return false;
                    n++;
                    if (IsInk(color(x, y))) ink++;
                }
                return n > 0 && ink >= Math.Max(1, (int)Math.Ceiling(InkShare * n));
            }
            var (l, t, r, b) = rects[index];
            // 0) Kutunun ucundaki simge (#1266, #1267): yazı tanıma kutusu menü/tuş simgesini de alıyordu; kutu simgenin
            // üstüne çiziliyor, simge kayboluyordu. Simge kutudan çıkar ve engel olur: örtü, kenar payı ve uzama ona girmez.
            bool iconLeft = false, iconRight = false;
            if (target.Rows <= 1)
            {
                int t0 = t, b0 = b;
                var found = IconSpans(l, r, line, target.Words, target.Align, x => InkColumn(x, t0, b0));
                var keep = (int)Math.Ceiling(ScreenFit.GapLines * line);
                if (found.Left is { } li) { zones.Add((li.L - keep, li.R + keep)); iconLeft = true; }
                if (found.Right is { } ri) { zones.Add((ri.L - keep, ri.R + keep)); iconRight = true; }
                l = found.TextLeft;
                r = found.TextRight;
            }
            int textLeft = l, textRight = r;
            // 1) Örtü: yazı tanıma kutusunun dışına taşan harf noktaları (bitişik satır/sütunlar) kutuya katılır.
            var reach = Math.Max(1, RoundHalfUp(ReachLines * line));
            var yy0 = b;
            while (yy0 < Math.Min(height, rects[index].B + reach) && InkRow(yy0, l, r)) yy0++;
            b = yy0;
            yy0 = t - 1;
            while (yy0 >= Math.Max(0, rects[index].T - reach) && InkRow(yy0, l, r)) yy0--;
            t = yy0 + 1;
            var xx0 = r;
            while (xx0 < Math.Min(width, textRight + reach) && InkColumn(xx0, t, b)) xx0++;
            r = xx0;
            xx0 = l - 1;
            while (xx0 >= Math.Max(0, textLeft - reach) && InkColumn(xx0, t, b)) xx0--;
            l = xx0 + 1;
            // 1b) Çok satırlı yazıda (görev/hedef cümlesi, harita kartı) tanıma kutusu satırın ucunu kaçırabiliyor: örtü
            // İngilizcenin yalnız bir kısmını kapatıyor, yanında "…çal om the", "…p rking lot." artığı kalıyordu (X, Myres88,
            // GTA 6 haritası). Kutunun dışında harf sürüyorsa (harf/sözcük arası en çok BridgeLines) örtü yazının sonuna
            // kadar uzar; başka hedefe ya da simgeye değmez. Tek satırlık etikette simge ayrımı bozulmasın diye yapılmaz.
            if (target.Rows > 1)
            {
                int top = t, bottom = b;
                bool SpillInk(int x) => InkColumn(x, top, bottom);
                bool SpillBlocked(int x)
                {
                    if (x < 0 || x >= width) return true;
                    for (var y = top; y < bottom; y++) if (Others(x, y)) return true;
                    return false;
                }
                if (Spill(r, 1, line, SpillInk, SpillBlocked) is { } right) r = right + 1;
                if (Spill(l - 1, -1, line, SpillInk, SpillBlocked) is { } left) l = left;
            }
            // Kenar payı: yazının yanındaki boş noktalar; ötesinde başka yazı/simge varsa pay ona değmez.
            var margin = Math.Max(1, Math.Min(MarginMax, RoundHalfUp(MarginLines * line)));
            int Pad(Func<int, bool> blank)
            {
                var k = 0;
                while (k < margin && blank(k + 1)) k++;
                return k;
            }
            bool OthersInColumn(int x)
            {
                for (var y = t; y < b; y++) if (Others(x, y)) return true;
                return false;
            }
            int tt = t, bb = b, ll = l, rr = r;
            var padL = Pad(k => ll - k >= 0 && !InkColumn(ll - k, tt, bb) && !OthersInColumn(ll - k));
            var padR = Pad(k => rr - 1 + k < width && !InkColumn(rr - 1 + k, tt, bb) && !OthersInColumn(rr - 1 + k));
            var padT = Pad(k => tt - k >= 0 && !InkRow(tt - k, ll, rr));
            var padB = Pad(k => bb - 1 + k < height && !InkRow(bb - 1 + k, ll, rr));
            int cl = l - padL, cr = r + padR, ct = t - padT, cb = b + padB;
            var cover = new TextBox(cl / fw, ct / fh, cr / fw, cb / fh);

            // 2) Zemin: kutunun üstündeki ve altındaki şerit (yanlarda simge olabilir); sol/sağ üçte bir ve üst/alt farkı.
            var strip = Math.Max(2, RoundHalfUp(0.25 * line));
            var samples = new List<((int R, int G, int B) C, double Fx, bool Top)>();
            void Collect(int y0, int y1, bool top)
            {
                if (y0 < 0 || y1 > height || y1 <= y0) return;
                var step = Math.Max(1, (cr - cl) / 64);
                var rowStep = Math.Max(1, (y1 - y0) / 4);
                var found = new List<((int R, int G, int B) C, double Fx, bool Top)>();
                for (var y = y0; y < y1; y += rowStep)
                {
                    for (var x = Math.Max(0, cl); x < Math.Min(width, cr); x += step)
                    {
                        if (Others(x, y)) return;
                        var c = color(x, y);
                        if (IsInk(c)) continue;
                        found.Add((c, (double)(x - cl) / Math.Max(1, cr - cl - 1), top));
                    }
                }
                samples.AddRange(found);
            }
            Collect(ct - strip, ct, top: true);
            Collect(cb, cb + strip, top: false);
            var paint = new TextPaint(target.Background, Pitch(target), cover)
            {
                IconSide = iconLeft == iconRight ? null : iconLeft ? "left" : "right",
            };
            if (samples.Count >= 16)
            {
                var all = samples.Select(s => s.C).ToList();
                var average = Mean(all);
                if (Distance(average, bg) <= TrustDistance)
                {
                    var left = samples.Where(s => s.Fx < 1.0 / 3).Select(s => s.C).ToList();
                    var right = samples.Where(s => s.Fx > 2.0 / 3).Select(s => s.C).ToList();
                    var above = samples.Where(s => s.Top).Select(s => s.C).ToList();
                    var below = samples.Where(s => !s.Top).Select(s => s.C).ToList();
                    // Desen: her parçanın kendi içindeki sapması (degrade kendi başına desen sayılmaz).
                    var parts = new[] { true, false }.SelectMany(side => Enumerable.Range(0, 3).Select(third =>
                            samples.Where(s => s.Top == side && Math.Min(2, (int)(s.Fx * 3)) == third).Select(s => s.C).ToList()))
                        .Where(part => part.Count >= 4).ToList();
                    var spread = parts.Count == 0 ? Deviation(all) : parts.Select(Deviation).Sum() / parts.Count;
                    var dh = left.Count >= 4 && right.Count >= 4 ? Distance(Mean(left), Mean(right)) : 0;
                    var dv = above.Count >= 4 && below.Count >= 4 ? Distance(Mean(above), Mean(below)) : 0;
                    if (spread > PatternDeviation)
                    {
                        paint = paint with { Patterned = true, Background = Hex(average) };
                    }
                    else if (dh >= GradientStep && dh >= dv)
                    {
                        // Üçte birlerin ortası 1/6 ve 5/6'da: uçlara doğrusal uzatılır.
                        var a = Mean(left);
                        var z = Mean(right);
                        paint = paint with { Background = Hex(Extend(a, z, 0.25)), Background2 = Hex(Extend(z, a, 0.25)), Direction = TextPaint.Horizontal };
                    }
                    else if (dv >= GradientStep)
                    {
                        var a = Mean(above);
                        var z = Mean(below);
                        // Şeritlerin ortası kutunun yarım şerit dışında: uçlar içeri doğru aradeğerlenir.
                        double span = cb - ct + strip;
                        var inward = span > 0 ? strip / 2.0 / span : 0;
                        paint = paint with { Background = Hex(Extend(a, z, -inward)), Background2 = Hex(Extend(z, a, -inward)), Direction = TextPaint.Vertical };
                    }
                    else
                    {
                        paint = paint with { Background = Hex(average) };
                    }
                }
            }

            // 3) Boş alan: tek satırlık etiket hizasının açık tarafına (sağa yaslıda sola, sola yaslıda sağa, ortalıda iki
            // yana) uzayabilir; başka yazıya, simgeye, kutu kenarına ya da karenin kenarına GapLines kala durur. Kutunun ucunda
            // simge varsa yalnız simgenin öbür yanına uzar (sağdaki tuş simgesinde sola, soldaki menü simgesinde sağa).
            if (target.Rows <= 1)
            {
                var sixth = Math.Max(1, (cb - ct) / 6);
                var band = new List<int>();
                for (var y = ct + sixth; y < Math.Max(ct + 1, cb - sixth); y += sixth) band.Add(Math.Min(height - 1, Math.Max(0, y)));
                var gap = (int)Math.Ceiling(ScreenFit.GapLines * line);
                var limit = RoundHalfUp(GrowLines * line);
                int Scan(int start, int step, (int R, int G, int B) first)
                {
                    var ground = first;
                    var x = start;
                    var end = step < 0 ? Math.Max(-1, start - limit) : Math.Min(width, start + limit);
                    // Sınır karşılaştırması ve adım sınırı: başlangıç karenin dışında kalsa da döngü biter (#1255).
                    var steps = 0;
                    while ((step < 0 ? x > end : x < end) && x >= 0 && x < width && steps <= width)
                    {
                        steps++;
                        var blocked = band.Any(y => Others(x, y));
                        for (var j = 0; j < rects.Length && !blocked; j++)
                            blocked = j != index && x >= rects[j].L && x < rects[j].R && rects[j].B > ct && rects[j].T < cb;
                        if (blocked) return x - (step * gap);
                        int sr = 0, sg = 0, sb = 0;
                        foreach (var y in band)
                        {
                            var c = color(x, y);
                            if (Distance(c, ground) > ScreenFit.InkDistance) return x - (step * gap);
                            sr += c.R; sg += c.G; sb += c.B;
                        }
                        var n = band.Count;
                        // Degrade zeminde zemin yavaşça izlenir (ScreenFit.WithRoom ile aynı).
                        ground = (((ground.R * 7) + (sr / n)) / 8, ((ground.G * 7) + (sg / n)) / 8, ((ground.B * 7) + (sb / n)) / 8);
                        x += step;
                    }
                    return step < 0 ? Math.Max(0, end + 1) : Math.Min(width, end);
                }
                var startColor = Rgb(paint.Background);
                var endColor = Rgb(paint.Background2 ?? paint.Background);
                int gl = cl, gr = cr;
                var toLeft = !iconLeft && (target.Align != "left" || iconRight);
                var toRight = !iconRight && (target.Align != "right" || iconLeft);
                if (band.Count > 0 && toLeft) gl = Math.Min(cl, Math.Max(0, Scan(cl - 1, -1, startColor) + 1));
                if (band.Count > 0 && toRight) gr = Math.Max(cr, Math.Min(width, Scan(cr, 1, endColor)));
                if (gl < cl || gr > cr) paint = paint with { Grow = new TextBox(gl / fw, cover.Top, gr / fw, cover.Bottom) };
            }

            // 5) Kip (yalnız türü verilen yazıda; telefon hep örtülür): düz zemini sınırlı bir alansa (panel) karar döngüden
            // sonra panel panel verilir (kutu: ikiz; listedeki satırın kendi şeridi/vurgusu: yanına yazma). Açık zeminde
            // (desenli zemin, degrade, karenin kenarına değen ya da çok büyük düz alan) Türkçe yanındaki boş alana yazılır;
            // listede bütün satırlar birlikte (aynı yan, aynı hiza). Yer bulunamazsa örtülür.
            covers.Add((cl, ct, cr, cb));
            lines.Add(line);
            grounds.Add(Rgb(paint.Background));
            if (target.Kind is { } kind && kind != ScreenTextKind.Phone)
            {
                var ground = Rgb(paint.Background);
                var self = index;
                var panel = paint.Patterned || paint.Background2 != null ? null
                    : FindPanel(cl, ct, cr, cb, width, height, (x, y) =>
                        RectHit(x, y, self) || (x >= cl && x < cr && y >= ct && y < cb) || Distance(color(x, y), ground) <= PanelTolerance);
                if (panel is { } found) panels[index] = found;
                // Düz zeminde boş alan zeminin bittiği yerde (panel kenarı, ayırıcı çizgi, başka panel) biter: kumanda şeması
                // önizlemesinde Türkçeler soldaki panele, seçicinin ve başlığın üstüne taşıyordu (#1362).
                var flat = !paint.Patterned && paint.Background2 == null;
                rooms.Add(MeasureRoom(cl, ct, cr, cb, line, width, height, iconLeft, iconRight,
                                      (x, y) => Others(x, y) ? null : Distance(color(x, y), fg) <= BesideInk,
                                      walls: flat,
                                      wall: (x, y) =>
                                      {
                                          var c = color(x, y);
                                          return Distance(c, ground) > ScreenFit.InkDistance && Distance(c, fg) > BesideInk;
                                      }));
            }
            else
            {
                rooms.Add(null);
            }
            result.Add(paint);
        }
        static bool Overlaps((int L, int T, int R, int B) a, (int L, int T, int R, int B) b) =>
            Math.Min(a.R, b.R) > Math.Max(a.L, b.L) && Math.Min(a.B, b.B) > Math.Max(a.T, b.T);
        // Listeler (Groups): aynı sütunda ya da aynı satırda duran, aynı boydaki tek satırlık etiketler.
        var iconed = Enumerable.Range(0, result.Count).Where(i => result[i].IconSide != null).ToHashSet();
        var lists = Groups(targets, iconed);
        var listOf = new Dictionary<int, int>();
        for (var k = 0; k < lists.Count; k++)
            foreach (var m in lists[k].Members) listOf[m] = k;

        // 6) Kutular (ikiz): kesişen paneller tek paneldir (bildirimin başlığı ve gövdesi, kartın başlığı, açıklaması ve
        // ayrıntıları), kutusu hepsinin birleşimi. Her yazı panelin içinde her yanda PanelPadLines boşlukla durmalı; durmuyorsa
        // panel yazının kendi şerididir (yanına yazılır). Tek satırlık tek yazılı panel listenin satırıysa (kart başlığının koyu
        // şeridi, seçili satırın açık vurgusu) kutu değil satırdır. İkiz özgünle aynı boyda (yazı, resim, köşe, iç boşluk, kenar
        // çizgisi), en uygun boş yere: yan (ekranın ortasına bakan yan önce) › alt › üst; başka yazıya, başka kutuya ve karenin
        // dışına taşmaz. Yer yoksa örtülür (son çare).
        // Zemini degrade ya da desenli ölçülen yazı (yarı saydam kartın altından harita görünüyor) başka yazının bulduğu panelin
        // içindeyse o paneldedir: kartın başlığı ve açıklaması ayrıntı satırlarıyla tek kart olur (beta.100 3407–3409: kartın
        // parçaları ayrı yamalarla örtülüyordu).
        // Kesişen paneller önce birleşir (yarı saydam kartta her yazının taraması kartın bir parçasında durabilir); yazının
        // örtüsünün en az %80'i birleşik panelin içindeyse yazı o paneldedir.
        var merged = new List<(int L, int T, int R, int B)>();
        foreach (var p in panels.Keys)
        {
            var box = panels[p];
            var changed = true;
            while (changed)
            {
                changed = false;
                var k = merged.FindIndex(o => Overlaps(o, box));
                if (k < 0) continue;
                var o = merged[k];
                merged.RemoveAt(k);
                box = (Math.Min(o.L, box.L), Math.Min(o.T, box.T), Math.Max(o.R, box.R), Math.Max(o.B, box.B));
                changed = true;
            }
            merged.Add(box);
        }
        for (var i = 0; i < targets.Count; i++)
        {
            if (rooms[i] == null || panels.ContainsKey(i)) continue;
            var c = covers[i];
            double area = Math.Max(1, (c.R - c.L) * (c.B - c.T));
            foreach (var p in merged)
            {
                double inside = Math.Max(0, Math.Min(p.R, c.R) - Math.Max(p.L, c.L)) * Math.Max(0, Math.Min(p.B, c.B) - Math.Max(p.T, c.T));
                if (inside < 0.8 * area) continue;
                panels[i] = p;
                break;
            }
        }
        // Tuş isteminin ve tek başına tek satırlık yazının kutusu yazıyı sarmalı: koyu oyun dünyası (gece, gölge, ekranın
        // altındaki karartı) da düz zemin gibi büyüyüp panel sanılabiliyor; tuş çubuğundaki "◯ Back" bu alanın ikizine,
        // ekranın altında dev siyah kutuya yazılıyordu (TCL Android TV, beta.103). Tek yazı her yanda en çok LabelPadLines
        // satır aşabilir (yanlarda yazının genişliği kadar da: kısa yazılı geniş kart); yalnız tuş istemlerinin kutusu her
        // yanda en çok PromptPadLines satır. Başka yazılı kutu (bildirim: ad, gövde, kişi resmi) bu sınırdan muaf.
        // Sarmayan alan kutu değildir, satırlar yanına yazılır (Mac TextPainter, Android TextPaint.kt aynı).
        bool Hugs(List<int> members, int l, int t, int r, int b)
        {
            var prompt = members.All(m => targets[m].Prompt);
            // Kendi kutusu olmayan düz etiketler (kumanda şeması önizlemesinde kolun çevresindeki "PARTNER MENU", "RUN",
            // "MOVE") koyu zeminin büyük bir parçasını panel sanıp ekranın ~%24×%33'ü boyunda ikiz kutuya yazılıyordu
            // (#1362). Hepsi tek satırlık birden çok etiketin kutusu, yazıları kutunun en az TwinFill'ini kaplamıyorsa
            // kutu değildir; etiketler yanına yazılır.
            if (members.Count >= 2 && members.All(m => targets[m].Rows <= 1))
            {
                var text = members.Sum(m => (covers[m].R - covers[m].L) * (covers[m].B - covers[m].T));
                if ((double)text < TwinFill * Math.Max(1, (r - l) * (b - t))) return false;
            }
            if (!members.All(m => targets[m].Rows <= 1) || !(prompt || members.Count == 1)) return true;
            int ul = members.Min(m => covers[m].L), ut = members.Min(m => covers[m].T);
            int ur = members.Max(m => covers[m].R), ub = members.Max(m => covers[m].B);
            var line = members.Max(m => lines[m]);
            // Aynı satırdaki birden çok tuş istemi (tuş çubuğu "◯ Geri  ✕ Seç") tek kutu değil, ayrı küçük etiketlerdir.
            if (members.Count >= 2 && prompt && members.Max(m => covers[m].T) < members.Min(m => covers[m].B)) return false;
            var padY = (prompt ? PromptPadLines : LabelPadLines) * line;
            var padX = prompt ? padY : Math.Max(padY, ur - ul);
            return ut - t <= padY && b - ub <= padY && ul - l <= padX && r - ur <= padX;
        }
        var keys = panels.Keys.ToList();
        var parent = keys.ToDictionary(i => i, i => i);
        int Root(int i) { while (parent[i] != i) i = parent[i]; return i; }
        foreach (var a in keys)
            foreach (var b in keys.Where(k => k > a))
                if (Overlaps(panels[a], panels[b])) parent[Root(b)] = Root(a);
        var boxes = new List<(List<int> Members, int L, int T, int R, int B)>();
        foreach (var members in keys.GroupBy(Root).Select(g => g.Order().ToList()).OrderBy(g => g[0]))
        {
            int l = members.Min(m => panels[m].L), t = members.Min(m => panels[m].T);
            int r = members.Max(m => panels[m].R), b = members.Max(m => panels[m].B);
            var padded = members.All(m =>
            {
                var c = covers[m];
                var pad = Math.Max(2, RoundHalfUp(PanelPadLines * lines[m]));
                return c.L - l >= pad && r - c.R >= pad && c.T - t >= pad && b - c.B >= pad;
            });
            var isBox = members.Count >= 2 || targets[members[0]].Rows > 1 || !listOf.ContainsKey(members[0]);
            if (padded && isBox && Hugs(members, l, t, r, b)) boxes.Add((members, l, t, r, b));
        }
        var boxed = boxes.SelectMany(box => box.Members).ToHashSet();
        var twins = new List<(int L, int T, int R, int B)>();
        foreach (var (members, l, t, r, b) in boxes)
        {
            var ground = grounds[members[0]];
            var line = lines[members[0]];
            // Zemin: panelin yazı dışındaki noktalarının ortalaması (yazının çevresindeki şeritten daha doğru ton).
            int sumR = 0, sumG = 0, sumB = 0, count = 0;
            int stepX = Math.Max(1, (r - l) / 24), stepY = Math.Max(1, (b - t) / 24);
            for (var y = t; y < b; y += stepY)
                for (var x = l; x < r; x += stepX)
                {
                    if (RectHit(x, y, null)) continue;
                    var c = color(x, y);
                    if (Distance(c, ground) > PanelTolerance) continue;
                    sumR += c.R;
                    sumG += c.G;
                    sumB += c.B;
                    count++;
                }
            var fill = count >= 8 ? (sumR / count, sumG / count, sumB / count) : ground;
            var corner = CornerRadius(l, t, r, b, (x, y) => Distance(color(x, y), ground) <= PanelTolerance);
            var edge = Edges(l, t, r, b, width, height, fill, (x, y) => RectHit(x, y, null), color);
            int el = edge?.Left ?? 0, et = edge?.Top ?? 0, er = edge?.Right ?? 0, eb = edge?.Bottom ?? 0;
            int ow = r - l + el + er, oh = b - t + et + eb, ox = l - el, oy = t - et;
            var gap = Math.Max(2, (int)Math.Ceiling(ScreenFit.GapLines * line));
            bool Blocked((int L, int T, int R, int B) a)
            {
                if (a.L < 0 || a.T < 0 || a.R > width || a.B > height) return true;
                for (var j = 0; j < rects.Length; j++)
                    if (!members.Contains(j) && Overlaps(a, rects[j])) return true;
                return boxes.Any(o => Overlaps(a, (o.L, o.T, o.R, o.B))) || twins.Any(o => Overlaps(a, o));
            }
            (int X, int Y)[] candidates = (l + r) / 2 < width / 2
                ? [(ox + ow + gap, oy), (ox - gap - ow, oy), (ox, oy + oh + gap), (ox, oy - gap - oh)]
                : [(ox - gap - ow, oy), (ox + ow + gap, oy), (ox, oy + oh + gap), (ox, oy - gap - oh)];
            (int X, int Y)? chosen = null;
            foreach (var candidate in candidates)
            {
                if (Blocked((candidate.X, candidate.Y, candidate.X + ow, candidate.Y + oh))) continue;
                chosen = candidate;
                break;
            }
            if (chosen is not { } at) continue;
            twins.Add((at.X, at.Y, at.X + ow, at.Y + oh));
            int dx = at.X - ox, dy = at.Y - oy;
            // İkizdeki Türkçe özgün panelden uzunsa ikiz sağa uzar (boş yer varsa, en çok TwinWiden).
            var widen = (int)(TwinWiden * (r - l));
            for (var j = 0; j < rects.Length; j++)
                if (!members.Contains(j) && rects[j].T < b + dy && rects[j].B > t + dy && rects[j].L >= r + dx)
                    widen = Math.Min(widen, rects[j].L - (r + dx) - er - gap);
            foreach (var other in boxes.Select(o => (L: o.L, T: o.T, R: o.R, B: o.B)).Append((L: l, T: t, R: r, B: b)))
                if (other.T < b + dy && other.B > t + dy && other.L >= r + dx)
                    widen = Math.Min(widen, other.L - (r + dx) - er - gap);
            widen = Math.Max(0, Math.Min(widen, width - (r + dx) - er));
            double X(int v) => (v + dx) / fw;
            double Y(int v) => (v + dy) / fh;
            (int L, int T, int R, int B)? face = null;
            foreach (var m in members)
            {
                if (face != null) break;
                face = Portrait(l, t, b, covers[m].L, covers[m].T, covers[m].B, lines[m],
                                (x, y) => !RectHit(x, y, null) && Distance(color(x, y), ground) > 2 * PanelTolerance);
            }
            var inset = Math.Max(gap, members.Min(m => covers[m].L - l));
            foreach (var m in members)
            {
                var c = covers[m];
                var align = targets[m].Align;
                var paint = result[m] with
                {
                    Mode = PaintMode.Twin,
                    Scale = TwinScale,
                    Tail = corner?.Tail,
                    Background = Hex(fill),
                    Background2 = null,
                    Direction = null,
                    Patterned = false,
                    Twin = new TextBox(X(l), Y(t), X(r), Y(b)),
                    Radius = (corner?.Radius ?? 0) / fh,
                    Spot = new TextBox(X(c.L), Y(c.T), X(c.R), Y(c.B)),
                    SpotRoom = new TextBox(align == "left" ? X(c.L) : X(l + inset), Y(c.T), Math.Max(X(c.R), X(r - inset + widen)), Y(c.B)),
                };
                if (edge is { } border)
                    paint = paint with { Edge = new TextPaint.EdgeLine(Hex(border.Color), border.Top / fh, border.Right / fh, border.Bottom / fh, border.Left / fh) };
                if (face is { } f)
                    paint = paint with
                    {
                        Portrait = new TextBox(f.L / fw, f.T / fh, f.R / fw, f.B / fh),
                        PortraitTwin = new TextBox(X(f.L), Y(f.T), X(f.R), Y(f.B)),
                    };
                result[m] = paint;
            }
        }

        // 7) Satırlar (yanına yazma): listede bütün satırlar aynı yana (sağa yaslı sütunda sol, sola yaslı sütunda sağ;
        // satırdaki sekme/kart başlıklarında hizanın açık yanı, sonra alt, sonra üst), sütunda Türkçeler tek hizada (sağa yaslı
        // listede sağ kenarları, sola yaslıda sol kenarları aynı), satırda aynı taban çizgisinde. Bir yan ancak listenin bütün
        // satırlarına yer varsa ve hiçbiri önceden yerleşen Türkçeye ya da ikiz kutuya binmiyorsa seçilir; değilse sıradaki yan
        // denenir (çakışma örtmeye döndürmez). Hiçbir yana birlikte sığmazsa en çok satırın sığdığı yan seçilir; sığmayan satır
        // kendi başına önce listenin yanlarını, sonra alt › üst dener (#1339: GTA 6 duraklatma menüsünde en uzun satır "Photo
        // Studio" sağa sığmayınca bütün liste dağılıyor, satırlar tek tek yerleşiyor, "Photo Studio" örtülüyordu). Listede
        // olmayan tek satır sol › sağ › alt › üst. Mac TextPaint.swift ve Android TextPaint.kt aynı.
        void Assign(int i, Spot spot) => result[i] = result[i] with
        {
            Mode = PaintMode.Beside,
            Spot = new TextBox(spot.L / fw, spot.T / fh, spot.R / fw, spot.B / fh),
            SpotRoom = new TextBox(spot.RoomL / fw, spot.T / fh, spot.RoomR / fw, spot.B / fh),
        };
        // Yerleşen Türkçelerin ve ikiz kutuların yeri (piksel): sonraki yerleşim bunlara binmez.
        var used = new List<(int L, int T, int R, int B)>(twins);
        bool Collides(Spot s) => used.Any(o => Overlaps(o, (s.L, s.T, s.R, s.B)));
        var placed = new HashSet<int>();
        var listSides = new Dictionary<int, List<Side>>();
        foreach (var list in lists)
        {
            var members = list.Members.Where(m => rooms[m] != null && !boxed.Contains(m)).ToList();
            if (members.Count < 2) continue;
            var ms = members.Select(m => rooms[m]!).ToList();
            var aligns = members.Select(m => targets[m].Align).ToList();
            // Çoğunluğun hizası; eşitlikte sıradaki ilk (sol, sağ, orta; Mac max(by:) ile aynı).
            var majority = "left";
            var most = -1;
            foreach (var candidate in new[] { "left", "right", "center" })
            {
                var n = aligns.Count(a => a == candidate);
                if (n <= most) continue;
                most = n;
                majority = candidate;
            }
            var sameRow = ms.Max(m => m.T) < ms.Min(m => m.B);
            var sides = new List<Side>();
            if (sameRow)
            {
                if (majority == "left") sides.Add(Side.Right);
                else if (majority == "right") sides.Add(Side.Left);
                sides.Add(Side.Below);
                sides.Add(Side.Above);
            }
            else
            {
                var tolerance = RoundHalfUp(0.5 * ms.Max(m => m.Line));
                var rightEdge = ms.Max(m => m.R) - ms.Min(m => m.R) <= tolerance;
                var leftEdge = ms.Max(m => m.L) - ms.Min(m => m.L) <= tolerance;
                bool? right = rightEdge && !leftEdge ? true : leftEdge && !rightEdge ? false : majority == "right" ? true
                    : majority == "left" ? false : null;
                sides.AddRange(right == false ? [Side.Right, Side.Left] : [Side.Left, Side.Right]);
            }
            foreach (var m in members) listSides[m] = sides;
            Side? bestSide = null;
            List<Spot?>? bestSpots = null;
            var bestFit = 0;
            foreach (var side in sides)
            {
                int? edge = side switch
                {
                    Side.Left => sameRow ? null : ms.Min(m => m.L - m.Near),
                    Side.Right => sameRow ? null : ms.Max(m => m.R + m.Near),
                    Side.Below => ms.Max(m => m.B + m.Near),
                    _ => ms.Min(m => m.T - m.Near),
                };
                var spots = ms.Select(m => PlaceSpot(m, side, edge)).ToList();
                if (side is Side.Below or Side.Above && spots.All(s => s != null))
                {
                    // Satırdaki komşular arasında Türkçeler ortadaki çizgiyi geçmez.
                    var order = Enumerable.Range(0, spots.Count).OrderBy(k => spots[k]!.Value.L).ToList();
                    for (var k = 0; k + 1 < order.Count; k++)
                    {
                        int a = order[k], b = order[k + 1];
                        var middle = (ms[a].R + ms[b].L) / 2;
                        var sa = spots[a]!.Value;
                        var sb = spots[b]!.Value;
                        spots[a] = sa with { RoomR = Math.Max(sa.R, Math.Min(sa.RoomR, middle)) };
                        spots[b] = sb with { RoomL = Math.Min(sb.L, Math.Max(sb.RoomL, middle)) };
                    }
                }
                spots = [.. spots.Select(s => s is { } v && !Collides(v) ? s : null)];
                var fit = spots.Count(s => s != null);
                if (fit > bestFit)
                {
                    bestFit = fit;
                    bestSide = side;
                    bestSpots = spots;
                }
                if (fit == spots.Count) break;
            }
            if (bestSide is not { } chosen || bestSpots is null) continue;
            for (var k = 0; k < members.Count; k++)
            {
                if (bestSpots[k] is not { } s) continue;
                Assign(members[k], s);
                used.Add((s.L, s.T, s.R, s.B));
                placed.Add(members[k]);
            }
            var preferred = new List<Side> { chosen };
            preferred.AddRange(sides.Where(s => s != chosen));
            foreach (var m in members) listSides[m] = preferred;
        }
        for (var i = 0; i < targets.Count; i++)
        {
            if (rooms[i] is not { } room || boxed.Contains(i) || placed.Contains(i)) continue;
            var order = listSides.TryGetValue(i, out var own) ? new List<Side>(own) : [Side.Left, Side.Right];
            foreach (var side in new[] { Side.Left, Side.Right, Side.Below, Side.Above })
                if (!order.Contains(side)) order.Add(side);
            foreach (var side in order)
            {
                if (PlaceSpot(room, side, null) is not { } spot || Collides(spot)) continue;
                Assign(i, spot);
                used.Add((spot.L, spot.T, spot.R, spot.B));
                break;
            }
        }
        // Çakışma: yanına yazılan Türkçenin uzayabileceği alan (spotRoom) başka bir Türkçenin alanına ya da ikiz kutuya binerse
        // alan aradaki çizgide kesilir (Türkçeler birbirine yaslanmaz). Türkçenin kendi yeri binerse (yerleşim çakışmayı
        // önlediği için seyrek) listede olmayan yazı örtmeye döner; menü/liste satırı hiç örtülmez (#1339).
        static bool BoxesOverlap(TextBox a, TextBox b) =>
            Math.Min(a.Right, b.Right) > Math.Max(a.Left, b.Left) && Math.Min(a.Bottom, b.Bottom) > Math.Max(a.Top, b.Top);
        const double eps = 1e-9;
        for (var i = 0; i < result.Count; i++)
        {
            if (result[i].Mode != PaintMode.Beside || result[i].SpotRoom is not { } mine || result[i].Spot is not { } spot) continue;
            var hit = false;
            for (var j = 0; j < result.Count; j++)
            {
                if (j == i) continue;
                var twin = result[j].Mode == PaintMode.Twin;
                TextBox? found = twin ? result[j].Twin : result[j].Mode == PaintMode.Beside ? result[j].Spot : null;
                if (found is not { } other || !BoxesOverlap(mine, other)) continue;
                if (BoxesOverlap(spot, other))
                {
                    if (twin || j < i) hit = true;
                    continue;
                }
                // Öbür Türkçe sağdaysa alan onun solunda, soldaysa sağında biter (ikizde kutunun kenarı; yanına yazmada iki
                // Türkçenin ortası).
                if (other.Left >= spot.Right - eps)
                {
                    var end = twin ? other.Left : (spot.Right + other.Left) / 2;
                    mine = mine with { Right = Math.Max(spot.Right, Math.Min(mine.Right, end)) };
                }
                else if (other.Right <= spot.Left + eps)
                {
                    var end = twin ? other.Right : (other.Right + spot.Left) / 2;
                    mine = mine with { Left = Math.Min(spot.Left, Math.Max(mine.Left, end)) };
                }
            }
            result[i] = result[i] with { SpotRoom = mine };
            if (hit && !listOf.ContainsKey(i)) result[i] = result[i] with { Mode = PaintMode.Cover, Spot = null, SpotRoom = null };
        }
        // 4) Grup: aynı sütunda (ortak sol ya da sağ kenar, düzenli aralık) ya da aynı satırda duran, BÜYÜK HARF'i ve satır
        // yüksekliği aynı tek satırlık etiketler.
        foreach (var (members, id) in lists)
            foreach (var i in members) result[i] = result[i] with { Group = id };
        // Aynı satırdaki tuş istemleri tek boyda ve tek taban çizgisinde (#1360): örtü kutusunun (ve yanına yazılan yerin)
        // üstü/altı ve satır aralığı grubun ortancası olur; TV grubun yazı boyunu bunlardan ölçer.
        static double Median(IEnumerable<double> values)
        {
            var s = values.Order().ToList();
            return s[s.Count / 2];
        }
        foreach (var (members, _) in lists)
        {
            if (members.Count < 2 || !members.Any(m => targets[m].Prompt || iconed.Contains(m))) continue;
            var groupCovers = members.Select(m => result[m].Cover).ToList();
            if (!(groupCovers.Max(c => c.Top) < groupCovers.Min(c => c.Bottom))) continue;
            var top = Median(groupCovers.Select(c => c.Top));
            var bottom = Median(groupCovers.Select(c => c.Bottom));
            var pitch = Median(members.Select(m => result[m].Pitch));
            var spots = members.Where(m => result[m].Mode == PaintMode.Beside && result[m].Spot != null)
                .Select(m => result[m].Spot!.Value).ToList();
            var spotTop = spots.Count == 0 ? top : Median(spots.Select(s => s.Top));
            foreach (var i in members)
            {
                var paint = result[i] with
                {
                    Cover = result[i].Cover with { Top = top, Bottom = bottom },
                    Pitch = pitch,
                };
                if (paint.Grow is { } grow) paint = paint with { Grow = new TextBox(grow.Left, top, grow.Right, bottom) };
                if (paint.Mode == PaintMode.Beside && paint.Spot is { } spot)
                {
                    var spotBottom = spotTop + (bottom - top);
                    paint = paint with { Spot = new TextBox(spot.Left, spotTop, spot.Right, spotBottom) };
                    if (paint.SpotRoom is { } room)
                        paint = paint with { SpotRoom = new TextBox(room.Left, spotTop, room.Right, spotBottom) };
                }
                result[i] = paint;
            }
        }
        return result;
    }

    /// <summary>Kare üzerinden ölçüm (BGRA noktalar).</summary>
    public static IReadOnlyList<TextPaint> Paints(IReadOnlyList<Target> targets, Frame frame)
    {
        if (!frame.IsConsistent || frame.Width <= 0 || frame.Height <= 0) return [];
        return Paints(targets, frame.Width, frame.Height, (x, y) =>
        {
            var p = (y * frame.Stride) + (x * 4);
            return (frame.Pixels[p + 2], frame.Pixels[p + 1], frame.Pixels[p]);
        });
    }

    /// <summary>Satır aralığı: çok satırlı yazıda kutudan ((satır sayısı - 1) aralık + bir satır yüksekliği), tek satırda satır yüksekliği.</summary>
    internal static double Pitch(Target target)
    {
        var height = target.Box.Bottom - target.Box.Top;
        if (target.Rows <= 1 || target.LineHeight <= 0) return target.LineHeight > 0 ? target.LineHeight : height;
        return Math.Max(target.LineHeight, (height - target.LineHeight) / (target.Rows - 1));
    }

    /// <summary>
    /// Grup üyeleri ve numarası (grubun en küçük sıra numarası); tek üyeli grup yok. <paramref name="iconed"/>: kutusunun
    /// ucunda tuş simgesi bulunan hedefler (<see cref="TextPaint.IconSide"/>); tuş istemi sayılır.
    /// </summary>
    internal static List<(List<int> Members, int Id)> Groups(IReadOnlyList<Target> targets, IReadOnlySet<int>? iconed = null)
    {
        iconed ??= new HashSet<int>();
        var labels = Enumerable.Range(0, targets.Count).Where(i => targets[i].Rows <= 1).ToList();
        var parent = labels.ToDictionary(i => i, i => i);
        int Root(int i) { while (parent[i] != i) i = parent[i]; return i; }
        static double Overlap(TextBox a, TextBox b) =>
            Math.Max(0, Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top)) / Math.Max(1e-9, Math.Min(a.Bottom - a.Top, b.Bottom - b.Top));
        foreach (var a in labels)
            foreach (var b in labels.Where(b => b > a))
            {
                var x = targets[a];
                var y = targets[b];
                var line = Math.Max(x.LineHeight, y.LineHeight);
                // Aynı satırdaki tuş istemi tuş çubuğudur (#1360: "PHOTO STUDIO ▢ · SELECT ✕ · BACK ○"): simgesi kutuya
                // katılmayan "SELECT" öbürlerinden ~%16 kısa okunup gruptan düşüyor, "SEÇ" öbürlerinden büyük ve aşağıda
                // çiziliyordu. Birinde tuş simgesi varsa satır yükseklikleri PromptLine'a kadar farklı olabilir.
                var prompt = x.Prompt || y.Prompt || iconed.Contains(a) || iconed.Contains(b);
                var limit = prompt && Overlap(x.Box, y.Box) >= 0.5 ? PromptLine : SameLine;
                if (x.Upper != y.Upper || Math.Abs(x.LineHeight - y.LineHeight) > limit * line) continue;
                // Satır yüksekliği kareye oranla; yatay pay aynı piksele denk gelsin diye en-boy oranı bilinmez, yarım satır
                // yüksekliğinin yarısı kadar (16:9'da ~0,28 satır) alınır.
                var tolerance = 0.5 * line * 9 / 16;
                var sameRow = Overlap(x.Box, y.Box) >= 0.5;
                var column = (Math.Abs(x.Box.Left - y.Box.Left) <= tolerance || Math.Abs(x.Box.Right - y.Box.Right) <= tolerance)
                    && Overlap(x.Box, y.Box) == 0 && Math.Abs(x.Box.Top - y.Box.Top) <= 3 * line;
                if (sameRow || column) parent[Root(a)] = Root(b);
            }
        return [.. labels.GroupBy(Root).Where(g => g.Count() >= 2)
            .Select(g => (Members: g.Order().ToList(), Id: g.Min())).OrderBy(g => g.Id)];
    }

    internal static (int R, int G, int B) Rgb(string hex) =>
        DesignTokens.Rgb(hex) is { } c ? (RoundHalfUp(c.R * 255), RoundHalfUp(c.G * 255), RoundHalfUp(c.B * 255)) : (0, 0, 0);

    internal static string Hex((int R, int G, int B) c) =>
        $"#{Math.Clamp(c.R, 0, 255):X2}{Math.Clamp(c.G, 0, 255):X2}{Math.Clamp(c.B, 0, 255):X2}";

    internal static int Distance((int R, int G, int B) a, (int R, int G, int B) b) =>
        Math.Max(Math.Abs(a.R - b.R), Math.Max(Math.Abs(a.G - b.G), Math.Abs(a.B - b.B)));

    internal static (int R, int G, int B) Mean(IReadOnlyList<(int R, int G, int B)> list)
    {
        var n = Math.Max(1, list.Count);
        return (list.Sum(c => c.R) / n, list.Sum(c => c.G) / n, list.Sum(c => c.B) / n);
    }

    /// <summary><paramref name="a"/>'dan <paramref name="b"/>'nin tersine <paramref name="share"/> kadar (eksiyse <paramref name="b"/>'ye doğru) uzatılmış renk.</summary>
    internal static (int R, int G, int B) Extend((int R, int G, int B) a, (int R, int G, int B) b, double share)
    {
        static int One(int x, int y, double share) => RoundHalfUp(x + ((x - y) * share));
        return (One(a.R, b.R, share), One(a.G, b.G, share), One(a.B, b.B, share));
    }

    internal static double Deviation(IReadOnlyList<(int R, int G, int B)> list)
    {
        if (list.Count == 0) return 0;
        static double Spread(IReadOnlyList<int> values)
        {
            var average = (double)values.Sum() / values.Count;
            return Math.Sqrt(values.Sum(v => (v - average) * (v - average)) / values.Count);
        }
        return (Spread([.. list.Select(c => c.R)]) + Spread([.. list.Select(c => c.G)]) + Spread([.. list.Select(c => c.B)])) / 3;
    }
}
