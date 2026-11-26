// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.RegularExpressions;

namespace CouchSubs.Core;

/// <summary>
/// GTA 6 telefonunun sohbet dışı ekranları (sosyal akış gönderisi, haber listesi ve makale, hava, fitness, ayarlar, eklenti
/// sayfası). Sinan Bey (beta.100, 3416–3425): bu ekranların Türkçesi ya telefonun üstüne kutularla yazılıyor ya da sohbet
/// balonu sanılıp dev balonlarla çiziliyordu; gönderinin açıklaması üç balona bölünüyor, yer adı ve kaynak adı çevriliyordu.
/// Artık ekranın türü çıkarılır (<see cref="KindOf"/>) ve sohbet dışı ekranın yazıları telefondaki yapının Türkçe kopyası
/// olarak kartlara ayrılır (<see cref="Cards"/>): her satır kartı, makale başlığı ya da gövdesi, gönderinin açıklaması tek
/// kart; kartlar telefonun yanındaki panelde, mesaj listesi kartlarıyla aynı görünüşte (<see cref="ScreenPhoneCard.Role.Card"/>).
/// Çevrilmeyenler: kullanıcı adı (@…), saat ("7PM"), geri düğmesi, gönderinin konum satırı ve fotoğrafın içindeki yazı,
/// haberin kaynak adı. Mac/iPhone (PhoneScreen.swift) ve Android (PhoneScreen.kt) aynı kuralları ve eşikleri uygular; ortak
/// deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/phone-screens.json.
/// </summary>
internal static class PhoneScreen
{
    internal enum Kind
    {
        /// <summary>Sohbet (balonlar) ya da tanınmayan ekran: eski kurallar.</summary>
        Chat,
        /// <summary>Uygulama ekranı (haber, makale, hava, fitness, ayarlar, eklenti): satırlar kart.</summary>
        App,
        /// <summary>Sosyal akış gönderisi: kullanıcı adının altındaki açıklama tek kart, gerisi çevrilmez.</summary>
        Post,
    }

    /// <summary>Ekrandaki bir satır: yazısı ve düz ekrandaki yeri (0–1).</summary>
    internal readonly record struct Line(string Text, TextBox Spot)
    {
        public double Height => Spot.Bottom - Spot.Top;
        public int Words => WordsOf(Text).Length;
    }

    /// <summary>Satırın kartı (<see cref="TextLine.PhoneCard"/>).</summary>
    internal readonly record struct Mark(int Card, bool Title = false, bool Bold = false);

    /// <summary>
    /// Bir kart: satırlarının sırası (<c>lines</c> içindeki yerleri, yukarıdan aşağı) ve başlığı. <c>Titled</c>: ilk satır
    /// kartın kalın başlığı ("Strength Workout" / "Level 3/4"); <c>Bold</c>: kartın tamamı başlık (makale başlığı).
    /// </summary>
    internal sealed record Card(IReadOnlyList<int> Lines, bool Titled = false, bool Bold = false);

    /// <summary>
    /// Uygulama ekranı için en az bu kadar kısa satır (en çok <see cref="ShortWords"/> sözcük, cümle sonu yok) ve satırların
    /// en az <see cref="ShortShare"/>'i kısa olmalı (sohbette mesajlar cümledir).
    /// </summary>
    internal const int ShortRows = 3, ShortWords = 3;
    internal const double ShortShare = 0.5;
    /// <summary>"…" ile kesilmiş en az bu kadar satır (haber listesi): uygulama ekranı.</summary>
    internal const int CutRows = 2;
    /// <summary>
    /// Karttaki iki satır arasındaki boşluk satır yüksekliğinin bu kadarından azsa aynı karttır; sol kenarlar
    /// <see cref="LeftAlign"/> içinde hizalı ve yükseklikler en çok <see cref="HeightRatio"/> katı farklı olmalı.
    /// </summary>
    internal const double RowGap = 0.7, LeftAlign = 0.06, HeightRatio = 1.35;
    /// <summary>Kartın satır yüksekliği sayfanın ortancasının bu katından büyükse kart başlıktır (makale başlığı, kalın).</summary>
    internal const double TitleHeight = 1.25;
    /// <summary>Gönderinin açıklaması kullanıcı adının en çok bu kadar satır altında başlar; açıklama satırları arası <see cref="RowGap"/>.</summary>
    internal const double CaptionGap = 1.6;
    /// <summary>Açıklama satırları kullanıcı adının (ya da ilk açıklama satırının) sol kenarına bu kadar hizalı.</summary>
    internal const double CaptionAlign = 0.12;

    private static readonly Regex Time = new(@"^\d{1,2}(?::\d{2})?\s?(?:[AaPp]\.?\s?[Mm]\.?|ᴬᴹ|ᴾᴹ)$", RegexOptions.CultureInvariant);

    private static string[] WordsOf(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    /// <summary>Saat ("7PM", "10 PM", "6:15PM"): çevrilmez.</summary>
    internal static bool IsTime(string text) => Time.IsMatch(text.Trim(' ', '\t'));

    /// <summary>Geri düğmesi ("&lt; Back", "‹ Back").</summary>
    internal static bool IsBack(string text)
    {
        var start = 0;
        while (start < text.Length && !char.IsLetter(text[start])) start++;
        return text[start..].Trim(' ', '\t').ToLowerInvariant() == "back";
    }

    /// <summary>Yalnız kullanıcı adı ya da etiket ("@offthehook_magazine", "@Cal_zone ✓").</summary>
    internal static bool IsHandle(string text)
    {
        var words = WordsOf(text);
        return words.Any(word => word[0] == '@' && word.Length >= 3)
            && words.All(word => word[0] == '@' || !word.Any(c => char.IsLetter(c) || char.IsNumber(c)));
    }

    /// <summary>Çevrilecek yazı mı: en az iki harf, saat, geri düğmesi ve kullanıcı adı değil.</summary>
    internal static bool IsWords(string text) =>
        text.Count(char.IsLetter) >= 2 && !IsTime(text) && !IsBack(text) && !IsHandle(text);

    internal static bool EndsSentence(string text)
    {
        var value = text.Trim(' ', '\t');
        return value.Length > 0 && ".!?".Contains(value[^1]);
    }

    internal static bool IsCut(string text) => GamePhoneText.IsCut(text);

    /// <summary>Kısa satır: en çok <see cref="ShortWords"/> sözcük, cümle sonu ve "…" yok ("Wallpaper", "Cardio Workout", "Level 1/4").</summary>
    internal static bool IsShort(string text)
    {
        var words = WordsOf(text).Length;
        return words is >= 1 and <= ShortWords && !EndsSentence(text) && !IsCut(text);
    }

    /// <summary>
    /// Ad gibi (kaynak adı, yer adı): bir-üç sözcük, her biri büyük harfle başlar, rakam ve cümle sonu yok
    /// ("Vice City Horn", "Weazel News", "Okchiloha Bay").
    /// </summary>
    internal static bool IsName(string text)
    {
        var words = WordsOf(text);
        if (words.Length is < 1 or > 3 || EndsSentence(text) || IsCut(text) || text.Any(char.IsNumber)) return false;
        return words.All(word => char.IsUpper(word[0]) && word.All(c => char.IsLetter(c) || "-'&.".Contains(c)));
    }

    /// <summary>
    /// Ekranın türü. <paramref name="lines"/>: telefondaki bütün satırlar (kullanıcı adları ve harfsiz satırlar da). Sohbet
    /// listesi ve ana ekran önce ayrılır (<see cref="GamePhoneText.ForTranslation"/>, <see cref="PhoneChat.IsHome"/>); burada
    /// yalnız sohbet / uygulama / gönderi.
    /// - Gönderi: sol yarıda bir kullanıcı adı satırı ("@THE_DONDIDDLER") ve altında yazı.
    /// - Uygulama: üstte geri düğmesi (makale), "…" ile kesilmiş en az <see cref="CutRows"/> satır (haber listesi) ya da en az
    ///   <see cref="ShortRows"/> kısa satır ve satırların en az <see cref="ShortShare"/>'i kısa, sağa yaslı (giden mesaj) balon yok.
    /// - Değilse sohbet.
    /// </summary>
    internal static Kind KindOf(IReadOnlyList<Line> lines)
    {
        var words = lines.Where(line => IsWords(line.Text)).ToList();
        if (lines.Any(line => IsHandle(line.Text) && line.Spot.Left < 0.5
                              && words.Any(other => other.Spot.Top >= line.Spot.Top + line.Height * 0.5)))
            return Kind.Post;
        if (lines.Any(line => IsBack(line.Text) && (line.Spot.Top + line.Spot.Bottom) / 2 < 0.15)) return Kind.App;
        if (words.Count == 0) return Kind.Chat;
        if (words.Count(line => IsCut(line.Text)) >= CutRows) return Kind.App;
        var shortRows = Labels(words);
        // Sağa yaslı, iki yanı da dolu olmayan çok sözcüklü satır: oyuncunun mesajı (sohbet).
        var outgoing = words.Any(line =>
        {
            double left = Math.Max(0, line.Spot.Left), right = Math.Max(0, 1 - line.Spot.Right);
            return line.Words >= 2 && left >= 0.2 && right < left * PhoneChat.SideRatio;
        });
        if (shortRows >= ShortRows && shortRows >= words.Count * ShortShare && !outgoing) return Kind.App;
        return Kind.Chat;
    }

    /// <summary>
    /// Kısa etiket satırlarının sayısı (<see cref="IsShort"/>): alt satıra sarılmış cümlenin parçası sayılmaz. Satır, hemen
    /// altındaki hizalı satır küçük harfle başlıyorsa (cümle sürüyor: "Dropped that stuff" / "off for you") ya da kendisi
    /// küçük harfle başlıyorsa ya da hemen üstündeki hizalı satır uzun bir cümle parçasıysa ("anything else AND I" / "MEAN
    /// ANYTHING u") etiket değildir.
    /// </summary>
    internal static int Labels(IReadOnlyList<Line> words)
    {
        var sorted = words.OrderBy(line => line.Spot.Top).ToList();
        static bool Joined(Line a, Line b) =>
            b.Spot.Top - a.Spot.Bottom <= RowGap * Math.Max(a.Height, b.Height) && Math.Abs(a.Spot.Left - b.Spot.Left) <= LeftAlign;
        static bool Lower(Line line) => line.Text.FirstOrDefault(char.IsLetter) is var letter && letter != default && char.IsLower(letter);
        return Enumerable.Range(0, sorted.Count).Count(index =>
        {
            var line = sorted[index];
            if (!IsShort(line.Text) || Lower(line)) return false;
            if (index + 1 < sorted.Count && Joined(line, sorted[index + 1]) && Lower(sorted[index + 1])) return false;
            if (index > 0 && Joined(sorted[index - 1], line) && sorted[index - 1].Words > ShortWords
                && !EndsSentence(sorted[index - 1].Text)) return false;
            return true;
        });
    }

    /// <summary>Sohbet dışı ekranın kartları (yukarıdan aşağı). Çevrilmeyen satırlar hiçbir karta girmez.</summary>
    internal static IReadOnlyList<Card> Cards(IReadOnlyList<Line> lines, Kind kind)
    {
        var order = Enumerable.Range(0, lines.Count).OrderBy(i => lines[i].Spot.Top).ToList();
        var heights = order.Where(i => IsWords(lines[i].Text)).Select(i => lines[i].Height).Order().ToList();
        if (heights.Count == 0) return [];
        var median = heights[(heights.Count - 1) / 2];
        return kind switch
        {
            Kind.Post => Captions(lines, order, median),
            Kind.App => AppCards(lines, order, median),
            _ => [],
        };
    }

    /// <summary>
    /// Gönderinin açıklaması: her kullanıcı adının altında, ona hizalı ve aralıksız satırlar tek kart. Fotoğrafın içindeki
    /// yazı, beğeni/yorum sayısı, konum satırı ("Okchiloha Bay") ve öbür satırlar çevrilmez.
    /// </summary>
    private static List<Card> Captions(IReadOnlyList<Line> lines, IReadOnlyList<int> order, double median)
    {
        var cards = new List<Card>();
        foreach (var handle in order.Where(i => IsHandle(lines[i].Text)))
        {
            var head = lines[handle];
            var taken = new List<int>();
            var last = head;
            foreach (var index in order.Where(i => IsWords(lines[i].Text)))
            {
                var line = lines[index];
                if (line.Spot.Top < head.Spot.Top + head.Height * 0.5) continue;
                var gap = line.Spot.Top - last.Spot.Bottom;
                var limit = (taken.Count == 0 ? CaptionGap : RowGap) * Math.Max(median, last.Height);
                var anchor = taken.Count == 0 ? head.Spot.Left : lines[taken[0]].Spot.Left;
                if (gap > limit || Math.Abs(line.Spot.Left - anchor) > CaptionAlign)
                {
                    // Aynı satırda yan yana okunan parça (emoji satırı böler) ya da aynı satırın ikinci okunuşu.
                    if (taken.Count > 0 && SameBand(lines[taken[^1]], line))
                    {
                        taken.Add(index);
                        continue;
                    }
                    break;
                }
                taken.Add(index);
                last = line;
            }
            if (taken.Count > 0) cards.Add(new Card(WithoutRepeats(taken, lines)));
        }
        return cards;
    }

    /// <summary>
    /// Uygulama ekranının kartları: arada dar boşluk, solda hizalı ve aynı boyda satırlar bir kart. Kartın ilk satırı kısa
    /// bir başlıksa ve alttaki satır yeni bir cümleyle başlıyorsa başlıktır ("Strength Workout" / "Level 3/4"); satırları
    /// sayfadan belirgin büyük kart başlıktır (makale başlığı). "…" ile kesilmiş başlığın ya da cümlenin altındaki ad satırı
    /// haberin kaynağıdır ("Vice City Horn"): çevrilmez.
    /// </summary>
    private static List<Card> AppCards(IReadOnlyList<Line> lines, IReadOnlyList<int> order, double median)
    {
        var blocks = new List<List<int>>();
        foreach (var index in order.Where(i => IsWords(lines[i].Text)))
        {
            var line = lines[index];
            if (blocks.Count > 0)
            {
                var block = blocks[^1];
                Line last = lines[block[^1]], first = lines[block[0]];
                if (SameBand(last, line))
                {
                    block.Add(index);
                    continue;
                }
                var gap = line.Spot.Top - last.Spot.Bottom;
                var ratio = Math.Max(line.Height, last.Height) / Math.Max(1e-6, Math.Min(line.Height, last.Height));
                // Kesik başlığın hemen altındaki satır (kaynak adı, simgesiyle biraz içeride) hizasız da aynı karttır.
                var aligned = Math.Abs(line.Spot.Left - first.Spot.Left) <= LeftAlign || IsCut(last.Text);
                if (gap <= RowGap * Math.Max(line.Height, last.Height) && aligned && ratio <= HeightRatio)
                {
                    block.Add(index);
                    continue;
                }
            }
            blocks.Add([index]);
        }
        var cards = new List<Card>();
        foreach (var block in blocks)
        {
            var rows = WithoutRepeats(block, lines);
            // Haberin kaynağı: kesik başlığın ya da cümlenin altındaki ad satırı.
            if (rows.Count >= 2 && IsName(lines[rows[^1]].Text)
                && rows.Take(rows.Count - 1).Any(i => IsCut(lines[i].Text) || EndsSentence(lines[i].Text) || lines[i].Words > ShortWords))
                rows.RemoveAt(rows.Count - 1);
            if (rows.Count == 0) continue;
            var heights = rows.Select(i => lines[i].Height).Order().ToList();
            var tall = heights[(rows.Count - 1) / 2] >= median * TitleHeight;
            var card = new Card(rows);
            if (tall)
                card = card with { Bold = true };
            else if (rows.Count >= 2 && IsShort(lines[rows[0]].Text)
                     && lines[rows[1]].Text.FirstOrDefault(c => char.IsLetter(c) || char.IsNumber(c)) is var next && next != default
                     && (char.IsUpper(next) || char.IsNumber(next)) && !SameBand(lines[rows[0]], lines[rows[1]]))
                card = card with { Titled = true };
            cards.Add(card);
        }
        return cards;
    }

    /// <summary>
    /// Kartın çevrilecek paragrafları: başlıklı kartta başlık ve gövde, değilse tek paragraf. Satırlar birleşir; satır
    /// sonunda tireyle bölünmüş sözcük boşluksuz.
    /// </summary>
    internal static IReadOnlyList<string> Paragraphs(Card card, IReadOnlyList<Line> lines)
    {
        string Joined(IEnumerable<int> part)
        {
            var text = "";
            foreach (var index in part)
            {
                var piece = lines[index].Text.Trim(' ', '\t');
                if (text.Length == 0) text = piece;
                else if (text.EndsWith('-')) text += piece;
                else text += " " + piece;
            }
            return text;
        }
        if (card.Lines.Count == 0) return [];
        return card.Titled && card.Lines.Count >= 2
            ? [Joined(card.Lines.Take(1)), Joined(card.Lines.Skip(1))]
            : [Joined(card.Lines)];
    }

    /// <summary>İki satır aynı yükseklikte (dikeyde en az yarı yarıya üst üste).</summary>
    internal static bool SameBand(Line a, Line b) =>
        Math.Min(a.Spot.Bottom, b.Spot.Bottom) - Math.Max(a.Spot.Top, b.Spot.Top) >= Math.Min(a.Height, b.Height) * 0.5;

    /// <summary>
    /// Aynı satırın ikinci okunuşu ya da başka bir satırın içinde kalan parçası atılır (Sinan Bey, 3419: "Pick up OFF THE
    /// HOOK" ayrı balon olarak da çiziliyordu). Uzun olan kalır.
    /// </summary>
    internal static List<int> WithoutRepeats(IReadOnlyList<int> rows, IReadOnlyList<Line> lines)
    {
        static string Key(string text)
        {
            var value = text.Trim(' ', '\t');
            while (value.Length > 0 && value[^1] is '.' or '…') value = value[..^1];
            return TextMatch.Normalize(value);
        }
        return [.. rows.Where(index =>
        {
            var mine = Key(lines[index].Text);
            if (mine.Count(char.IsLetter) < 4) return true;
            return !rows.Any(other =>
            {
                if (other == index) return false;
                var theirs = Key(lines[other].Text);
                if (theirs.Length < mine.Length) return false;
                // Eşit uzunlukta aynı yazı: önce okunan kalır.
                if (theirs == mine) return other < index;
                return theirs.Contains(mine, StringComparison.Ordinal);
            });
        })];
    }
}
