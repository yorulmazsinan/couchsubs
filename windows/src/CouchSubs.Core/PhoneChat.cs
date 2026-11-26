// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.RegularExpressions;

namespace CouchSubs.Core;

/// <summary>
/// "Ekranı çevir"de GTA 6 telefonunun ekranındaki satırlar: önce telefonun düz ekranına taşınır
/// (<see cref="ScreenPhoneCard.Handset"/>, eğik telefonda da sol/sağ kenar ekranın kenarına göre ölçülür), sonra ekranın ne
/// olduğu çıkarılır. Sohbet ekranında her balon bir parça olur (balonun satırları birleşir); balon telefonun hangi kenarına
/// yaslıysa gelen ya da giden mesajdır. Sohbet listesinde kişi adları çevrilmez, son mesaj önizlemeleri çevrilir. Ana ekran
/// (hava durumu, bildirim sayacı, simge ızgarası) sohbet değildir: yazıları yerinde çevrilir, uygulama adları çevrilmez. Mac/iPhone
/// (PhoneChat.swift) ve Android (PhoneChat.kt) aynı kuralları ve eşikleri uygular; ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/phone-chat.json.
/// </summary>
internal static class PhoneChat
{
    /// <summary>Satır, merkezi düz ekranda bu payla dışarıda kalsa da telefonundur (kutular kenarda biraz taşabilir).</summary>
    internal const double InsideSlack = 0.05;
    /// <summary>Düz ekranda bu kadar dışarı taşan satır telefonun yazısı değildir (telefonun arkasından geçen altyazı, tabela).</summary>
    internal const double OutsideReach = 0.3;
    /// <summary>Ekranın üst/alt kenarından bu kadar dışarı taşan satır kesiktir (sohbet kaymış, satırın yarısı görünüyor).</summary>
    internal const double EdgeCut = 0.015;
    /// <summary>Kesik satır: yüksekliği ortanca satırın bu kadarından az (başlığın altına girmiş ilk satır, alt kenardaki son satır).</summary>
    internal const double CutHeight = 0.6;
    /// <summary>Fotoğrafın içindeki yazı: ortanca satırın bu kadar katından yüksek (en az üç satır varken).</summary>
    internal const double PhotoHeight = 2.0;
    /// <summary>Aynı balonun iki satırı arasındaki boşluk ortanca satır yüksekliğinin bu kadarından az; balonlar arası daha geniş.</summary>
    internal const double BubbleGap = 0.6;
    /// <summary>Aynı balonun satırları solda bu kadar hizalı (ekran genişliğine oranla); sağa yaslı balonda sağda <see cref="RightAlign"/>.</summary>
    internal const double LeftAlign = 0.04, RightAlign = 0.03;
    /// <summary>Kenar payı oranı: balonun bir yandaki payı öbür yandakinin bu kadarından azsa o yana yaslıdır.</summary>
    internal const double SideRatio = 0.6;
    /// <summary>İki yanı da bundan dar balon (ekranı dolduran uzun mesaj) yaslı sayılmaz; tarafı balonun rengi söyler.</summary>
    internal const double WideMargin = 0.15;
    /// <summary>Ortalı kısa satır (saat, "Today", "Delivered"): merkezi ortadan en çok bu kadar uzak, iki yanda en az <see cref="NoteMargin"/> pay.</summary>
    internal const double NoteCenter = 0.06, NoteMargin = 0.2;
    /// <summary>Başlık (kişi adı): ekranın üst bu kadarında, ortalıysa merkezi ortadan en çok <see cref="HeaderCenter"/> uzak.</summary>
    internal const double HeaderBand = 0.2, HeaderCenter = 0.12;
    /// <summary>Aynı satırda yan yana okunan parçalar (emoji satırı böler) aradaki boşluk satır yüksekliğinin bu katından azsa birleşir.</summary>
    internal const double RowJoin = 2.0;

    /// <summary>Düz ekrandaki satır; <paramref name="Spot"/> düz ekrandaki yeri (0–1, ekranın kenarlarına göre).</summary>
    internal sealed record Row(IReadOnlyList<TextLine> Lines, TextBox Spot, string Text)
    {
        public double Height => Spot.Bottom - Spot.Top;
        public double Center => (Spot.Left + Spot.Right) / 2;
        public int Words => WordsOf(Text).Length;
    }

    private static string[] WordsOf(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    /// <summary>Telefonun içinde mi (merkezi düz ekranda, satır ekranın dışına taşmıyor).</summary>
    internal static bool OnScreen(TextBox spot)
    {
        double u = (spot.Left + spot.Right) / 2, v = (spot.Top + spot.Bottom) / 2;
        return u >= -InsideSlack && u <= 1 + InsideSlack && v >= -InsideSlack && v <= 1 + InsideSlack
            && spot.Left >= -OutsideReach && spot.Right <= 1 + OutsideReach;
    }

    /// <summary>Ana ekranda yan yana okunan parçalar yalnız bu kadar yakınsa birleşir (simge etiketleri arasında daha geniş boşluk var).</summary>
    internal const double HomeJoin = 1.0;
    /// <summary>
    /// Ana ekranda bir bloğun (bileşen başlığı ve içeriği, bildirimin satırları) iki satırı arasındaki boşluk ortanca satırın
    /// bu kadarından az.
    /// </summary>
    internal const double HomeGap = 0.8;
    /// <summary>Simge ızgarası: aynı hizada en az bu kadar uygulama adı.</summary>
    internal const int GridLabels = 3;
    /// <summary>Hava durumu ("76°", "24 °C") ve bildirim sayacı ("10 Notifications", "3 new messages"): yalnız ana ekranda olur.</summary>
    private static readonly Regex Weather = new(@"^[-−]?\d{1,3}\s?[°º˚]\s?[CFcf]?$", RegexOptions.CultureInvariant);
    private static readonly Regex Counter = new(
        @"^\d{1,3}\s+(?:new\s+)?(?:notifications?|reminders?|alerts?|messages?|missed\s+calls?|e-?mails?|updates?)$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>
    /// Telefonun satırlarını (kutuları bilinen, süzülmüş) parçalara ayırır; her grup <c>Phone</c> bilgisini taşır.
    /// <paramref name="raw"/>: telefondaki süzülmemiş satırlar (harfsiz satırlar da: hava durumu ana ekranı belli eder).
    /// </summary>
    internal static IReadOnlyList<ScreenTranslation.Group> Groups(IReadOnlyList<TextLine> lines, ScreenPhoneCard.Handset handset,
                                                                  IReadOnlyList<TextLine>? raw = null)
    {
        List<Row> single = [.. lines.Where(line => line.Box is not null)
            .Select(line => new Row([line], handset.Flat(line.Box!.Value), Clean(line.Text)))
            .Where(row => row.Text.Count(char.IsLetter) >= 2)
            .OrderBy(row => row.Spot.Top)];
        var rows = JoinedRows(single);
        if (rows.Count == 0) return [];
        var median = rows.Select(row => row.Height).OrderBy(h => h).ElementAt(rows.Count / 2);
        rows.RemoveAll(row => row.Spot.Top < -EdgeCut || row.Spot.Bottom > 1 + EdgeCut);
        // Ana ekran (saat, hava, bileşenler, simge ızgarası) sohbet değildir: kart kurulmaz, yazılar yerinde çevrilir.
        var home = JoinedRows(single, HomeJoin);
        home.RemoveAll(row => row.Spot.Top < -EdgeCut || row.Spot.Bottom > 1 + EdgeCut);
        if (IsHome(home, raw ?? [])) return HomeGroups(home, median, handset);
        Row? header = null;
        if (rows.Count > 0 && IsHeader(rows[0]))
        {
            header = rows[0];
            rows.RemoveAt(0);
        }
        if (rows.Count >= 3) rows.RemoveAll(row => row.Height > median * PhotoHeight);
        // Kaymış sohbetin en üstteki ve en alttaki yarım satırı okunmaz, çevrilmez.
        if (rows.Count > 0 && rows[0].Height < median * CutHeight) rows.RemoveAt(0);
        if (rows.Count > 0 && rows[^1].Height < median * CutHeight) rows.RemoveAt(rows.Count - 1);

        var result = new List<ScreenTranslation.Group>();
        if (ContactList(rows, median) is { } list)
        {
            // Listenin başındaki ortalı olmayan başlık bir kişi değil bölüm adıdır ("Messages"): çevrilir.
            if (header is not null)
                result.Add(Group([header], Math.Abs(header.Center - 0.5) <= HeaderCenter ? ScreenPhoneCard.Role.Header
                    : ScreenPhoneCard.Role.Heading, handset));
            for (var i = 0; i < rows.Count; i++) result.Add(Group([rows[i]], list[i], handset));
            return result;
        }
        // Sohbet dışı ekran (gönderi, haber, makale, hava, fitness, ayarlar, eklenti): kartlar (PhoneScreen; otomatik telefon
        // okumasıyla aynı kural).
        if (ScreenGroups(raw is { Count: > 0 } ? raw : lines, handset) is { } cards) return cards;
        if (header is not null) result.Add(Group([header], ScreenPhoneCard.Role.Header, handset));
        var bubble = new List<Row>();
        void Finish()
        {
            if (bubble.Count == 0) return;
            result.Add(Group(bubble, RoleOf(bubble), handset));
            bubble = [];
        }
        foreach (var row in rows)
        {
            if (bubble.Count > 0 && !Continues(row, bubble[^1], bubble[0], median)) Finish();
            bubble.Add(row);
        }
        Finish();
        var roles = WithOptions([.. result.Select(group => group.Phone!.Role)]);
        for (var i = 0; i < result.Count; i++) result[i] = result[i] with { Phone = result[i].Phone! with { Role = roles[i] } };
        return result;
    }

    /// <summary>Satırın başındaki ve sonundaki harfsiz, rakamsız kırıntılar (emoji ya da simge yanlış okunmuş: "©", "•", "♡") atılır.</summary>
    internal static string Clean(string text)
    {
        var words = WordsOf(text).ToList();
        // Para simgesi ("$ in your mailbox") mesajın parçasıdır.
        static bool Junk(string word) =>
            !word.Any(c => char.IsLetter(c) || char.IsNumber(c) || char.GetUnicodeCategory(c) == System.Globalization.UnicodeCategory.CurrencySymbol)
            && !word.All(c => ".,!?…'\"-:;()".Contains(c));
        while (words.Count > 0 && Junk(words[0])) words.RemoveAt(0);
        while (words.Count > 0 && Junk(words[^1])) words.RemoveAt(words.Count - 1);
        return string.Join(' ', words);
    }

    /// <summary>Aynı yükseklikte yan yana okunmuş parçalar (arada emoji ya da simge) tek satır olur.</summary>
    internal static List<Row> JoinedRows(IReadOnlyList<Row> rows, double join = RowJoin)
    {
        var result = new List<Row>();
        foreach (var row in rows)
        {
            var index = result.FindLastIndex(other => SameRow(other, row, join));
            if (index >= 0)
            {
                var (a, b) = result[index].Spot.Left <= row.Spot.Left ? (result[index], row) : (row, result[index]);
                result[index] = new Row([.. a.Lines, .. b.Lines], a.Spot.Union(b.Spot), a.Text + " " + b.Text);
            }
            else
            {
                result.Add(row);
            }
        }
        return [.. result.OrderBy(row => row.Spot.Top)];
    }

    private static bool SameRow(Row a, Row b, double join)
    {
        if (!SameBand(a, b)) return false;
        var gap = Math.Max(a.Spot.Left, b.Spot.Left) - Math.Min(a.Spot.Right, b.Spot.Right);
        // Yatay boşluk ekran genişliğine, satır yüksekliği ekran yüksekliğine oranla; ikisi aynı ölçüye çevrilir.
        return gap * ScreenPhoneCard.Handset.ScreenShape <= Math.Max(a.Height, b.Height) * join;
    }

    /// <summary>İki satır aynı yükseklikte (dikeyde en az yarı yarıya üst üste).</summary>
    private static bool SameBand(Row a, Row b) =>
        Math.Min(a.Spot.Bottom, b.Spot.Bottom) - Math.Max(a.Spot.Top, b.Spot.Top) >= Math.Min(a.Height, b.Height) * 0.5;

    /// <summary>
    /// Ana ekran mı: hava durumu satırı, bildirim sayacı ("10 Notifications") ya da aynı hizada en az üç uygulama adı (simge
    /// ızgarası). Sohbette bunların hiçbiri olmaz; tek başına kısa bir yanıt ("Ok") ana ekran sayılmaz.
    /// </summary>
    internal static bool IsHome(IReadOnlyList<Row> rows, IReadOnlyList<TextLine> raw)
    {
        if (raw.Any(line => Weather.IsMatch(line.Text.Trim(' ', '\t')))) return true;
        if (rows.Any(row => Counter.IsMatch(row.Text))) return true;
        var labels = rows.Where(row => IsAppLabel(row.Text) && (row.Spot.Top + row.Spot.Bottom) / 2 >= HeaderBand).ToList();
        return labels.Any(label => labels.Count(other => SameBand(other, label)) >= GridLabels);
    }

    /// <summary>
    /// Uygulama başlatıcı (gerçek ana ekran): bildirim sayacı ya da simge ızgarası var. Yalnız hava satırı ("71°") olan ekran
    /// hava uygulamasıdır: oradaki tek sözcüklük satırlar ("Now", "Sunset") uygulama adı değildir, çevrilir (Sinan Bey,
    /// beta.100 3422; Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal static bool IsLauncher(IReadOnlyList<Row> rows)
    {
        if (rows.Any(row => Counter.IsMatch(row.Text))) return true;
        var labels = rows.Where(row => IsAppLabel(row.Text) && (row.Spot.Top + row.Spot.Bottom) / 2 >= HeaderBand).ToList();
        return labels.Any(label => labels.Count(other => SameBand(other, label)) >= GridLabels);
    }

    /// <summary>Uygulama adı gibi: bir-iki sözcük, hepsi harf ve büyük harfle başlıyor, rakam ve noktalama yok ("WhatUp", "Camera").</summary>
    internal static bool IsAppLabel(string text)
    {
        var words = WordsOf(text);
        return words.Length is >= 1 and <= 2
            && words.All(word => char.IsUpper(word[0]) && word.All(c => char.IsLetter(c) || c is '-' or '\'' or '&'));
    }

    /// <summary>
    /// Ana ekranın blokları: arada dar boşluk ve solda aynı hizada duran satırlar (bileşenin başlığı ve içeriği, bildirimin
    /// satırları) bir blok; yan yana duranlar ayrı.
    /// </summary>
    internal static List<List<Row>> HomeBlocks(IReadOnlyList<Row> rows, double median)
    {
        var blocks = new List<List<Row>>();
        foreach (var row in rows)
        {
            // Bileşenin sayacı ("6 Notifications") başlığın altındadır ama başlığın solunda simge olduğundan sol hizası
            // başlıktan önde başlar: yine aynı bloktur (WidgetIndent kadar).
            if (blocks.Count > 0 && blocks[^1][^1] is var last && blocks[^1][0] is var first
                && row.Spot.Top - last.Spot.Bottom < median * HomeGap && row.Spot.Top >= last.Spot.Top && !SameBand(row, last)
                && (Math.Abs(row.Spot.Left - first.Spot.Left) <= LeftAlign
                    || (blocks[^1].Count == 1 && IsCounter(row.Text) && first.Spot.Left - row.Spot.Left <= WidgetIndent
                        && row.Spot.Left <= first.Spot.Left)))
                blocks[^1].Add(row);
            else
                blocks.Add([row]);
        }
        return blocks;
    }

    /// <summary>Bileşen başlığının solundaki simgenin payı (düz ekran genişliğine oranla).</summary>
    internal const double WidgetIndent = 0.2;

    /// <summary>Bildirim sayacı ("6 Notifications", "3 new messages").</summary>
    internal static bool IsCounter(string text) => Counter.IsMatch(text.Trim(' ', '\t'));

    /// <summary>
    /// Ana ekran bileşeni: kısa başlık ve hemen altında sayaç ("Reminders / 6 Notifications"). Sinan Bey (beta.100, 3397):
    /// bileşen çevrilmiyordu; panelde tek kart olur (<see cref="ScreenPhoneCard.Role.Widget"/>; Mac ile aynı).
    /// </summary>
    internal static bool IsWidget(IReadOnlyList<Row> block) =>
        block.Count == 2 && IsCounter(block[1].Text) && !IsCounter(block[0].Text) && block[0].Words is >= 1 and <= 3;

    /// <summary>Blok tek başına duran kısa bir ad: uygulamanın adı (simge etiketi, "WhatUp"); çevrilmez.</summary>
    internal static bool IsAppName(IReadOnlyList<Row> block) => block.Count == 1 && IsAppLabel(block[0].Text);

    /// <summary>
    /// Otomatik telefon panelinin (<see cref="GamePhoneText.Groups"/>) satırları ana ekransa uygulama adları atılmış hâli;
    /// saat ve hava harfsiz satır olarak zaten çevrilmez, bileşen ve bildirim yazıları kendi yerinde kalır. Satırların yeri
    /// düz ekranda (<c>PhoneBox</c>) bilinmiyorsa ya da ekran ana ekran değilse satırlar olduğu gibi döner ("Ekranı çevir"
    /// ile aynı kural).
    /// </summary>
    internal static IReadOnlyList<TextLine> WithoutAppNames(IReadOnlyList<TextLine> lines)
    {
        if (!IsHomeScreen(lines)) return lines;
        var rows = HomeRows(lines);
        var median = rows.Select(row => row.Height).OrderBy(h => h).ElementAt(rows.Count / 2);
        var names = IsLauncher(rows) ? HomeBlocks(rows, median).Where(IsAppName).SelectMany(block => block[0].Lines).ToList() : [];
        // Saat ("7PM", "10 PM") çevrilmez (Sinan Bey, beta.100 3422: "10PM" "22:00" yazılıyordu).
        return [.. lines.Where(line => line.Text.Count(char.IsLetter) >= 2 && !PhoneScreen.IsTime(line.Text)
                                       && !names.Any(name => name.Text == line.Text && name.PhoneBox == line.PhoneBox))];
    }

    /// <summary>
    /// Satırlar (düz ekrandaki yerleri bilinen) telefonun ana ekranı mı; sohbet panelinde ana ekran yazıları kendi yerinde
    /// kalır (<see cref="GamePhoneText.Roles"/>; Mac ile aynı).
    /// </summary>
    internal static bool IsHomeScreen(IReadOnlyList<TextLine> lines)
    {
        if (lines.Count == 0 || !lines.All(line => line.PhoneBox.HasValue)) return false;
        var rows = HomeRows(lines);
        return rows.Count > 0 && IsHome(rows, lines);
    }

    private static List<Row> HomeRows(IReadOnlyList<TextLine> lines)
    {
        List<Row> single = [.. lines.Select(line => new Row([line], line.PhoneBox!.Value, Clean(line.Text)))
            .Where(row => row.Text.Count(char.IsLetter) >= 2).OrderBy(row => row.Spot.Top)];
        return [.. JoinedRows(single, HomeJoin)];
    }

    /// <summary>
    /// Ana ekranın yazıları: bir arada duran satırlar (bileşenin başlığı ve içeriği, bildirimin satırları) birer blok, her
    /// satır kendi yerinde ayrı çevrilir (alt satıra sarılmış cümle birleşir). Tek başına duran kısa ad (simge etiketi,
    /// "WhatUp") uygulamanın adıdır, çevrilmez; saat ve hava zaten harfsiz satırlarla birlikte atılmıştır. Gruplar
    /// <see cref="ScreenPhoneCard.Role.Home"/> rolündedir: kart kurulmaz, özgün stilinde yerinde çizilir.
    /// </summary>
    internal static IReadOnlyList<ScreenTranslation.Group> HomeGroups(IReadOnlyList<Row> rows, double median, ScreenPhoneCard.Handset handset)
    {
        var result = new List<ScreenTranslation.Group>();
        var launcher = IsLauncher(rows);
        foreach (var block in HomeBlocks([.. rows.Where(row => !PhoneScreen.IsTime(row.Text))], median))
        {
            if (launcher && IsAppName(block)) continue;
            if (IsWidget(block))
            {
                var boxes = block.SelectMany(row => row.Lines).Where(line => line.Box is not null).Select(line => line.Box!.Value).ToList();
                var widget = Group([block[0]], ScreenPhoneCard.Role.Widget, handset);
                result.Add(widget with
                {
                    Paragraphs = [block[0].Text, block[1].Text],
                    Box = boxes.Skip(1).Aggregate(boxes[0], (a, b) => a.Union(b)),
                    Phone = new ScreenPhoneCard.Placement(ScreenPhoneCard.Role.Widget, block[0].Spot.Union(block[1].Spot)),
                });
                continue;
            }
            var piece = new List<Row>();
            foreach (var row in block)
            {
                var continues = row.Text.FirstOrDefault(char.IsLetter) is var letter && char.IsLower(letter)
                    && piece.Count > 0 && !EndsSentence(piece[^1].Text);
                if (piece.Count > 0 && !continues)
                {
                    result.Add(Group(piece, ScreenPhoneCard.Role.Home, handset));
                    piece = [];
                }
                piece.Add(row);
            }
            if (piece.Count > 0) result.Add(Group(piece, ScreenPhoneCard.Role.Home, handset));
        }
        return result;
    }

    /// <summary>
    /// Sohbet dışı ekranın kartları (<see cref="PhoneScreen.KindOf"/>/<see cref="PhoneScreen.Cards"/>, satırların düz ekrandaki
    /// yeriyle); ekran sohbetse null. Ekranın üst/alt kenarından taşan kesik satırlar kartlara girmez (Mac/iPhone ve Android
    /// ile aynı).
    /// </summary>
    internal static IReadOnlyList<ScreenTranslation.Group>? ScreenGroups(IReadOnlyList<TextLine> lines, ScreenPhoneCard.Handset handset)
    {
        var boxed = lines.Where(line => line.Box is not null).ToList();
        var all = boxed.Select(line => new PhoneScreen.Line(Clean(line.Text), handset.Flat(line.Box!.Value))).ToList();
        var kind = PhoneScreen.KindOf(all);
        if (kind == PhoneScreen.Kind.Chat) return null;
        var result = new List<ScreenTranslation.Group>();
        foreach (var card in PhoneScreen.Cards(all, kind))
        {
            var rows = card.Lines.Where(i => all[i].Spot.Top >= -EdgeCut && all[i].Spot.Bottom <= 1 + EdgeCut).ToList();
            if (rows.Count == 0) continue;
            var titled = card.Titled && rows.Count >= 2 && rows[0] == card.Lines[0];
            var paragraphs = PhoneScreen.Paragraphs(new PhoneScreen.Card(rows, titled, card.Bold), all);
            var boxes = rows.Select(i => boxed[i].Box!.Value).ToList();
            var spots = rows.Select(i => all[i].Spot).ToList();
            var heights = spots.Select(spot => spot.Bottom - spot.Top).Order().ToList();
            result.Add(new ScreenTranslation.Group(paragraphs, boxes.Skip(1).Aggregate(boxes[0], (a, b) => a.Union(b)),
                heights[(heights.Count - 1) / 2] * handset.ScreenHeight)
            {
                Phone = new ScreenPhoneCard.Placement(ScreenPhoneCard.Role.Card, spots.Skip(1).Aggregate(spots[0], (a, b) => a.Union(b)),
                    titled, card.Bold),
            });
        }
        return result;
    }

    /// <summary>Başlık: ekranın en üstündeki kısa, cümle olmayan satır; ortalı ya da (solda avatarın yanında) ad gibi yazılmış.</summary>
    internal static bool IsHeader(Row row)
    {
        var v = (row.Spot.Top + row.Spot.Bottom) / 2;
        if (v >= HeaderBand || row.Words is < 1 or > 4 || EndsSentence(row.Text)) return false;
        return Math.Abs(row.Center - 0.5) <= HeaderCenter || LooksLikeName(row.Text);
    }

    /// <summary>Ad gibi: bir-üç sözcük, her biri büyük harf ya da rakamla başlar, virgül ve cümle sonu yok.</summary>
    internal static bool LooksLikeName(string text)
    {
        var words = WordsOf(text);
        if (words.Length is < 1 or > 3 || text.Contains(',') || EndsSentence(text)) return false;
        return words.All(word => char.IsUpper(word[0]) || char.IsNumber(word[0]));
    }

    internal static bool EndsSentence(string text)
    {
        var trimmed = text.Trim(' ', '\t');
        return trimmed.Length > 0 && ".!?…".Contains(trimmed[^1]);
    }

    /// <summary>
    /// Sohbet listesi: en az iki "ad + hemen altında aynı hizada önizleme" çifti ve satırların çoğu bu çiftlerde. Liste ise
    /// her satırın rolü, değilse null.
    /// </summary>
    internal static ScreenPhoneCard.Role[]? ContactList(IReadOnlyList<Row> rows, double median)
    {
        var roles = Enumerable.Repeat(ScreenPhoneCard.Role.Heading, rows.Count).ToArray();
        int pairs = 0, index = 0;
        while (index + 1 < rows.Count)
        {
            Row name = rows[index], preview = rows[index + 1];
            if (LooksLikeName(name.Text) && preview.Words >= 2 && Math.Abs(name.Spot.Left - preview.Spot.Left) <= LeftAlign
                && preview.Spot.Top - name.Spot.Bottom <= median * 0.7 && name.Spot.Left < 0.5)
            {
                roles[index] = ScreenPhoneCard.Role.Contact;
                roles[index + 1] = ScreenPhoneCard.Role.Preview;
                pairs++;
                index += 2;
            }
            else
            {
                index++;
            }
        }
        if (pairs < 2 || pairs * 2 * 10 < rows.Count * 6) return null;
        // Çifte girmeyen ad gibi satırlar bölüm başlığıdır ("Messages"), uzunlar tek başına önizlemedir.
        for (var i = 0; i < rows.Count; i++)
            if (roles[i] == ScreenPhoneCard.Role.Heading && !LooksLikeName(rows[i].Text)) roles[i] = ScreenPhoneCard.Role.Preview;
        return roles;
    }

    /// <summary>Satır, açık balonun devamı mı: arada dar boşluk ve aynı hiza (solda; sağa yaslı balonda sağda da olur).</summary>
    private static bool Continues(Row row, Row last, Row first, double median)
    {
        if (row.Spot.Top - last.Spot.Bottom >= median * BubbleGap) return false;
        if (Math.Abs(row.Spot.Left - first.Spot.Left) <= LeftAlign) return true;
        return Math.Min(row.Spot.Left, first.Spot.Left) > 0.2 && Math.Abs(row.Spot.Right - last.Spot.Right) <= RightAlign;
    }

    /// <summary>
    /// Balonun rolü yaslı olduğu kenardan: sağa yaslı giden, sola yaslı gelen; ortalı kısa etiket not; iki yanı da dar (ekranı
    /// dolduran) balon belirsiz, tarafı kartta balonun renginden seçilir. Ortalı ama etiket olmayan balon (cümle ya da birden
    /// çok satır) sohbetin altındaki cevap seçeneğidir: X (26 Kas, beta.104) "Thanks for the heads up." ortalı tek satır
    /// olduğu için not sayılıp soluk ortalı yazıyla, öbür seçenek sarı giden balonla çiziliyordu (Mac ile aynı).
    /// </summary>
    internal static ScreenPhoneCard.Role RoleOf(IReadOnlyList<Row> bubble)
    {
        var spot = bubble.Skip(1).Aggregate(bubble[0].Spot, (a, b) => a.Union(b.Spot));
        double left = Math.Max(0, spot.Left), right = Math.Max(0, 1 - spot.Right);
        if (Math.Abs((spot.Left + spot.Right) / 2 - 0.5) <= NoteCenter && left >= NoteMargin && right >= NoteMargin)
            return bubble.Count == 1 && IsNoteLabel(string.Join(' ', bubble.Select(row => row.Text)))
                ? ScreenPhoneCard.Role.Note : ScreenPhoneCard.Role.Option;
        if (left < WideMargin && right < WideMargin) return ScreenPhoneCard.Role.Message;
        if (right < left * SideRatio) return ScreenPhoneCard.Role.Outgoing;
        if (left < right * SideRatio) return ScreenPhoneCard.Role.Incoming;
        return ScreenPhoneCard.Role.Message;
    }

    /// <summary>Not satırı en çok bu kadar sözcük ("Today 9:41 PM", "New messages", "Delivered").</summary>
    internal const int NoteWords = 4;

    /// <summary>Ortalı not gibi kısa etiket: en çok <see cref="NoteWords"/> sözcük ve cümle sonu yok.</summary>
    internal static bool IsNoteLabel(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        return words is >= 1 and <= NoteWords && !EndsSentence(text);
    }

    /// <summary>
    /// Cevap seçenekleri sohbetin en altında art arda durur: en alttaki oyuncu tarafı balonlar (giden, seçenek) arasında en az
    /// bir seçenek varsa hepsi seçenektir; her biri ayrı satır, aynı görünüşte çizilir. Roller yukarıdan aşağı (Mac ile aynı).
    /// </summary>
    internal static IReadOnlyList<ScreenPhoneCard.Role> WithOptions(IReadOnlyList<ScreenPhoneCard.Role> roles)
    {
        var start = roles.Count;
        while (start > 0 && roles[start - 1] is ScreenPhoneCard.Role.Option or ScreenPhoneCard.Role.Outgoing) start--;
        var result = roles.ToArray();
        if (!roles.Skip(start).Contains(ScreenPhoneCard.Role.Option)) return result;
        for (var i = start; i < result.Length; i++) result[i] = ScreenPhoneCard.Role.Option;
        return result;
    }

    /// <summary>Özette her grubun ilk bu kadar sözcüğü.</summary>
    internal const int RowSummaryWords = 4;

    /// <summary>
    /// Okunan telefon satırlarının günlük özeti: her grubun türü (başlık, balon, seçenek, not, liste, kart) ve ilk sözcükleri
    /// (X, 26 Kas: en üstteki mesaj çevrilmiyordu; Mac PhoneChat.rowSummary ve Android ile aynı biçim).
    /// </summary>
    internal static string RowSummary(IEnumerable<ScreenTranslation.Group> groups) => string.Join(" | ", groups.Select(group =>
    {
        var kind = group.Phone?.Role switch
        {
            ScreenPhoneCard.Role.Header => "header",
            ScreenPhoneCard.Role.Incoming or ScreenPhoneCard.Role.Outgoing or ScreenPhoneCard.Role.Message => "bubble",
            ScreenPhoneCard.Role.Option => "option",
            ScreenPhoneCard.Role.Note => "note",
            ScreenPhoneCard.Role.Contact or ScreenPhoneCard.Role.Preview or ScreenPhoneCard.Role.Heading => "list",
            null => "row",
            _ => "card",
        };
        var words = string.Join(' ', group.Paragraphs).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return $"{kind}: {string.Join(' ', words.Take(RowSummaryWords))}{(words.Length > RowSummaryWords ? "…" : "")}";
    }));

    /// <summary>Satırlar tek parça olur: satır sonunda tireyle bölünmüş sözcük boşluksuz birleşir.</summary>
    private static ScreenTranslation.Group Group(IReadOnlyList<Row> rows, ScreenPhoneCard.Role role, ScreenPhoneCard.Handset handset)
    {
        var text = "";
        foreach (var row in rows)
        {
            if (text.Length == 0) text = row.Text;
            else if (text.EndsWith('-')) text += row.Text;
            else text += " " + row.Text;
        }
        var boxes = rows.SelectMany(row => row.Lines).Where(line => line.Box is not null).Select(line => line.Box!.Value).ToList();
        var spot = rows.Skip(1).Aggregate(rows[0].Spot, (a, b) => a.Union(b.Spot));
        // Eğik telefonda okunan kutu satırın eğimini de kapsar; yazı boyu düz ekrandaki yükseklikten gelir.
        var heights = rows.Select(row => row.Height).OrderBy(h => h).ToList();
        return new ScreenTranslation.Group([text], boxes.Skip(1).Aggregate(boxes[0], (a, b) => a.Union(b)),
            heights[heights.Count / 2] * handset.ScreenHeight)
        {
            Phone = new ScreenPhoneCard.Placement(role, spot),
        };
    }
}
