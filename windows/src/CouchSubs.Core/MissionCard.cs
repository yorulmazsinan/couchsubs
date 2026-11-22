// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// GTA 6 haritasında bir göreve ya da konuma basınca açılan bilgi kartı: BÜYÜK HARFLİ görev adı, altında (varsa) kısa
/// alt başlık satırları, bir iki cümlelik açıklama ve en altta kısa ayrıntı satırları (ödül, uzaklık). Kart yazıların
/// dizilişinden tanınır: başlığın hemen altında, aynı sol kenarda başlayan cümle satırları; kart ekranın bir parçası
/// kadar dardır, yardım kutularının durduğu sol üst köşede değildir ve (kare varsa) düz bir panelin üstündedir.
///
/// Tanınan kartın parçaları ayrı ayrı çevrilir ve kendi yerlerinde, özgün stilde çizilir (başlık büyük harfle): başlık
/// açıklamanın ilk cümlesine katılmaz, uzun başlık da ayrı kalır. Otomatik ekran yazısında kart "Görev ve hedef yazısı"
/// türündendir (<see cref="ScreenTextKind.Mission"/>), menüde açılsa da. Mac/iPhone (MissionCard.swift) ve Android
/// (MissionCard.kt) aynı kuralları ve eşikleri uygular; ortak deneme dosyası Fixtures/mission-card.json.
/// </summary>
internal static class MissionCard
{
    /// <summary>Başlık en çok bu kadar sözcük.</summary>
    internal const int TitleWords = 7;
    /// <summary>Açıklamanın ilk satırı başlığın altından en çok başlık yüksekliğinin bu katı aşağıda başlar.</summary>
    internal const double TitleGap = 1.4;
    /// <summary>Açıklama satırları arasında en çok satır yüksekliğinin bu katı boşluk; paragraf arası <see cref="ParagraphGap"/>.</summary>
    internal const double LineGap = 1.0, ParagraphGap = 2.2;
    /// <summary>Ayrıntı satırları (ödül, uzaklık) açıklamanın altından en çok bu kat aşağıda ve en çok <see cref="DetailWords"/> sözcük.</summary>
    internal const double DetailGap = 1.8;
    internal const int DetailWords = 5;
    /// <summary>Sol kenarların hizası, satır yüksekliğinin bu katı (kare 16:9 sayılır; yatayda ~1 harf).</summary>
    internal const double Alignment = 0.9;
    /// <summary>Kart ekranın en çok bu kadarı genişliğindedir (tam genişlik yazı kart değildir).</summary>
    internal const double MaxWidth = 0.55;
    /// <summary>Açıklama en az bu kadar sözcük.</summary>
    internal const int BodyWords = 6;
    /// <summary>Başlığın solundaki görev resmi en çok başlık yüksekliğinin bu katı genişliktedir; açıklama resmin altından başlar.</summary>
    internal const double PictureWidth = 2.5;

    /// <summary>Bulunan kart: satırların sırası (verilen listede), yukarıdan aşağı.</summary>
    internal sealed record Card(IReadOnlyList<int> Title, IReadOnlyList<int> Subtitles, IReadOnlyList<int> Body,
                                IReadOnlyList<int> Details)
    {
        public IReadOnlyList<int> All => [.. Title, .. Subtitles, .. Body, .. Details];
    }

    /// <summary>
    /// Satırlardaki kartlar. <paramref name="lines"/> kareye oranla yerleşmiş (kutusu olmayan satır atlanır);
    /// <paramref name="place"/> verilirse kutular o alana oranlıdır ve önce kareye taşınır.
    /// </summary>
    internal static List<Card> Find(IReadOnlyList<TextLine> lines, TextBox? place = null)
    {
        var boxes = lines.Select(line => line.Box is { } b ? (place is { } p ? b.PlacedIn(p) : b) : (TextBox?)null).ToList();
        var order = Enumerable.Range(0, lines.Count).Where(i => boxes[i] is not null)
            .OrderBy(i => boxes[i]!.Value.Top).ToList();
        var used = new HashSet<int>();
        var cards = new List<Card>();
        TextBox B(int i) => boxes[i]!.Value;
        double Height(int i) => B(i).Bottom - B(i).Top;
        bool Aligned(int i, int j, double h) => Math.Abs(B(i).Left - B(j).Left) <= h * Alignment * 9 / 16;
        for (var position = 0; position < order.Count; position++)
        {
            var start = order[position];
            if (used.Contains(start) || !IsTitle(lines[start].Text)) continue;
            var title = new List<int> { start };
            var subtitles = new List<int>();
            var details = new List<int>();
            // Kartın sütunu: başlığın sol kenarının tümüyle solunda biten ya da kart genişliğinden sağda başlayan satır
            // (haritada kartın yanındaki uzaklık "124 ft", simge kırıntısı, yan menü) karta ait değildir; kartın satırları
            // arasına girip kartı bölüyordu (X: chiaki, harita kartı tanınmıyor, çevirisi sola kayıyordu).
            bool InColumn(int i) => B(i).Right > B(start).Left && B(i).Left < B(start).Left + MaxWidth;
            var rest = new Queue<int>(order.Skip(position + 1).Where(i => !used.Contains(i) && InColumn(i)));
            // Açıklamanın ilk satırı: cümle satırı ya da sözcükleri cümle gibi yazılmış kısa satır ("Nautical-themed
            // souvenir") ki altında küçük harfle süren cümle satırı var; böyle satır alt başlık değildir.
            bool OpensBody(int i, int? after)
            {
                if (IsSentence(lines[i].Text)) return true;
                return SentenceCased(lines[i].Text, 2) && after is { } next && Aligned(next, i, Height(i))
                       && lines[next].Text.Length > 0 && char.IsLower(lines[next].Text[0]) && IsSentence(lines[next].Text)
                       && Math.Abs(Height(next) - Height(i)) <= Height(i) * 0.3
                       && B(next).Top - B(i).Bottom <= Height(i) * LineGap;
            }
            int? Second() => rest.Count > 1 ? rest.ElementAt(1) : null;
            // Başlık iki satıra sarılmış olabilir.
            if (rest.TryPeek(out var wrapped) && IsTitle(lines[wrapped].Text) && Aligned(wrapped, start, Height(start))
                && B(wrapped).Top - B(start).Bottom <= Height(start) * 0.6)
                title.Add(rest.Dequeue());
            var last = title[^1];
            var titleHeight = Height(start);
            while (rest.TryPeek(out var next) && !OpensBody(next, Second()) && Words(lines[next].Text) <= DetailWords
                   && !IsTitle(lines[next].Text) && Aligned(next, start, titleHeight)
                   && B(next).Top - B(last).Bottom <= titleHeight * TitleGap)
            {
                subtitles.Add(next);
                last = next;
                rest.Dequeue();
            }
            // Başlığın solunda görev resmi (portre) olabilir: açıklama resmin altından, başlıktan daha solda başlar (#856).
            bool UnderTitle(int i) => Aligned(i, start, titleHeight)
                || (B(i).Left < B(start).Left && B(start).Left - B(i).Left <= titleHeight * PictureWidth * 9 / 16);
            if (!rest.TryPeek(out var first) || !OpensBody(first, Second()) || !UnderTitle(first)
                || B(first).Top - B(last).Bottom > titleHeight * TitleGap || Height(first) > titleHeight * 1.1) continue;
            var line = Height(first);
            var body = new List<int> { first };
            last = first;
            rest.Dequeue();
            // Alt satır cümlenin devamı: yazı boyu benzer; küçük harfle başlayan kısa son satır ("treasure.") harfleri kısa
            // diye daha alçak okunabilir. Sıradaki görevin BÜYÜK HARFLİ başlığı açıklamaya katılmaz (görev listesi).
            while (rest.TryPeek(out var next) && Aligned(next, first, line) && !IsTitle(lines[next].Text)
                   && (Math.Abs(Height(next) - line) <= line * 0.3
                       || (lines[next].Text.Length > 0 && char.IsLower(lines[next].Text[0]) && Height(next) <= line * 1.5
                           && !SubtitleStabilizer.EndsSentence(lines[last].Text.Trim()))))
            {
                var gap = B(next).Top - B(last).Bottom;
                // Satır ya cümlenin devamı (dar boşluk) ya da yeni bir açıklama paragrafı: daha geniş boşluk, önceki satır
                // cümleyi bitirmiş ve yeni satır ayrıntı satırından uzun bir cümle ("Distance 2.4 mi" ayrıntıdır).
                var paragraph = gap <= line * ParagraphGap && IsSentence(lines[next].Text) && Words(lines[next].Text) > 3
                                && SubtitleStabilizer.EndsSentence(lines[last].Text.Trim());
                if (!(gap <= line * LineGap || paragraph)) break;
                body.Add(next);
                last = next;
                rest.Dequeue();
            }
            var right = body.Max(i => B(i).Right);
            // Altında cümle olan BÜYÜK HARFLİ satır ayrıntı değil, sıradaki görevin başlığıdır.
            bool NextTitle(int i)
            {
                if (!IsTitle(lines[i].Text)) return false;
                var after = order.Where(j => B(j).Top > B(i).Bottom - 1e-9 && j != i).Select(j => (int?)j).FirstOrDefault();
                return after is { } a && IsSentence(lines[a].Text) && B(a).Top - B(i).Bottom <= Height(i) * TitleGap;
            }
            while (rest.TryPeek(out var next) && !NextTitle(next) && Words(lines[next].Text) <= DetailWords && Height(next) <= line * 1.3
                   && B(next).Top - B(last).Bottom <= line * DetailGap
                   && (Aligned(next, first, line) || Math.Abs(B(next).Right - right) <= line * Alignment * 9 / 16))
            {
                details.Add(next);
                last = next;
                rest.Dequeue();
            }
            var card = new Card(title, subtitles, body, details);
            var span = card.All.Select(B).ToList();
            if (body.Sum(i => Words(lines[i].Text)) < BodyWords || span.Max(b => b.Right) - span.Min(b => b.Left) > MaxWidth) continue;
            used.UnionWith(card.All);
            cards.Add(card);
        }
        return cards;
    }

    /// <summary>Başlık: en az üç harf, harflerinin çoğu büyük, en çok <see cref="TitleWords"/> sözcük, nokta ile bitmez.</summary>
    internal static bool IsTitle(string text)
    {
        var plain = IconText.Plain(text).Trim();
        return plain.Count(char.IsLetter) >= 3 && TextStyleSampler.IsUpper(plain) && Words(plain) is >= 1 and <= TitleWords
               && !plain.EndsWith('.');
    }

    /// <summary>
    /// Cümle satırı: en az üç sözcük, harflerinin en az %40'ı küçük ve ilkinden sonra küçük harfle başlayan bir sözcüğü
    /// var (her sözcüğü büyük harfle başlayan "Lucia · Story Mission" alt başlıktır).
    /// </summary>
    internal static bool IsSentence(string text) => SentenceCased(text, 3);

    /// <summary>En az <paramref name="words"/> sözcük, harflerin en az %40'ı küçük, ilkinden sonra küçük harfle başlayan sözcük var.</summary>
    internal static bool SentenceCased(string text, int words)
    {
        var letters = text.Where(char.IsLetter).ToList();
        var parts = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= words && letters.Count > 0 && letters.Count(char.IsLower) >= 0.4 * letters.Count
               && parts.Skip(1).Any(part => char.IsLower(part[0]));
    }

    private static int Words(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    /// <summary>Kartın kutusu yardım kutularının durduğu sol üst köşede mi (oradaki başlıklı kutu bir ipucudur, görev kartı değil).</summary>
    internal static bool InHelpCorner(TextBox box) => box.Left < 0.25 && box.Top < 0.3;

    /// <summary>Kart paneli düz zemin sayılırken izin verilen sapma, düz zemin eşiğinin bu katı.</summary>
    internal const double PanelSlack = 1.5;

    /// <summary>
    /// Kartın yazıları düz bir panelin üstünde mi (harita ya da oyun dünyasının dokulu zemininde duran yazı kart değildir).
    /// Harita kartı yarı saydamdır: arkadaki harita zemini satırdan satıra biraz değiştirir, sıkıştırılmış görüntüde harf
    /// kenarları da zemine karışır; kart bu yüzden düz zemin eşiğinin <see cref="PanelSlack"/> katına kadar paneldir
    /// (X: chiaki, harita kartı tanınmıyordu). Dokulu dünya zemini bu sınırın çok üstündedir.
    /// </summary>
    internal static bool OnPanel(Frame frame, IReadOnlyList<TextLine> lines)
    {
        var boxes = lines.Where(line => line.Box is not null).Select(line => line.Box!.Value).ToList();
        if (boxes.Count == 0) return false;
        var box = boxes.Skip(1).Aggregate(boxes[0], (a, b) => a.Union(b));
        return TextStyleSampler.Sample(frame, box, lines, string.Join(' ', lines.Select(line => line.Text)),
            TextStyleSampler.FlatDeviation * PanelSlack).Look.Flat;
    }

    /// <summary>Kartın çeviri grupları: başlık (sarılmışsa tek parça), alt başlıklar ve ayrıntılar tek tek, açıklama paragraflarıyla.</summary>
    internal static List<ScreenTranslation.Group> Groups(Card card, IReadOnlyList<TextLine> lines)
    {
        ScreenTranslation.Group Make(IReadOnlyList<int> indices, bool joined)
        {
            var own = indices.Select(i => lines[i]).ToList();
            var boxes = own.Select(line => line.Box!.Value).ToList();
            var heights = boxes.Select(b => b.Bottom - b.Top).Order().ToList();
            var icons = ScreenTranslation.ParagraphIcons(own);
            IReadOnlyList<string> paragraphs = joined ? [string.Join(' ', own.Select(line => line.Text.Trim(' ')))]
                : ScreenTranslation.Paragraphs(own);
            IReadOnlyList<IReadOnlyList<IconSlot>> slots = joined ? [icons.SelectMany(list => list).ToList()] : icons;
            return new ScreenTranslation.Group(paragraphs, boxes.Skip(1).Aggregate(boxes[0], (a, b) => a.Union(b)),
                heights[heights.Count / 2], slots.Any(list => list.Count > 0) ? slots : null);
        }
        return [Make(card.Title, true), .. card.Subtitles.Select(i => Make([i], true)), Make(card.Body, false),
                .. card.Details.Select(i => Make([i], true))];
    }
}
