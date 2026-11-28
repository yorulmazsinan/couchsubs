// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Otomatik telefon okumasında çevirinin kararlılığı. Aynı mesajın OCR'la bir iki harfi farklı okunuşu yeni mesaj
/// sayılıyor, balon bir an özgün diline dönüp yeniden çevriliyor, çeviri her seferinde biraz değişiyordu; telefon tek
/// karede bulunamayınca da bütün çeviriler silinip geri geliyordu ("sürekli git gel yapıyor", X'teki bildirim). Mac/iPhone
/// (PhoneSteady.swift) ve Android (PhoneSteady.kt) aynı eşikleri kullanır.
/// </summary>
internal static class PhoneSteady
{
    /// <summary>Telefon art arda bu kadar turda bulunamazsa ya da okuma doğrulanamazsa çeviriler silinir.</summary>
    internal const int MissTurns = 3;
    /// <summary>Yan yana bozuk harfler en çok bu kadar tur bekletilir.</summary>
    internal const int HoldTurns = 2;
    /// <summary>
    /// Eksik düzen ancak sekiz ardışık okumada (~4 sn) doğrulanırsa gösterilen sohbeti değiştirir: ekran bir an parlayınca
    /// okunamayan balonlar silinip yalnız tek balon kalıyordu (X, 28 Kas, beta.108). Kaydırma ve başka sohbet beklemez.
    /// </summary>
    internal const int DegradedTurns = 8;
    /// <summary>
    /// Sayfanın türü (sohbet listesi ya da sohbet) ancak bu kadar ardışık okuma aynı yeni türü verirse değişir: sallanan
    /// telefonda tek okumada bölüm başlığı kaçınca TV'deki panel liste ile balonlar arasında her saniye gidip geliyordu
    /// (LG, beta.93). Mac ile aynı.
    /// </summary>
    internal const int KindTurns = 2;

    /// <summary>Okumanın grupları sohbet listesi mi (kişi adı, önizleme, bölüm başlığı).</summary>
    internal static bool IsList(IEnumerable<ScreenPhoneCard.Role?> roles) =>
        roles.Any(role => role is ScreenPhoneCard.Role.Contact or ScreenPhoneCard.Role.Preview or ScreenPhoneCard.Role.Heading);

    /// <summary>Aynı mesaj sayılmak için sadeleştirilmiş iki okumanın benzerliği (Levenshtein oranı) en az bu.</summary>
    internal const double SameMessage = 0.9;
    /// <summary>Kısa satırda bir harf anlamı değiştirir ("Ok" / "On"): benzer okuma yalnız bu kadar harften uzun mesajda kullanılır.</summary>
    internal const int MinimumLetters = 8;

    /// <summary>
    /// Mesajın bilinen çevirisi: birebir aynı okunuşunki, yoksa aynı mesajın OCR'la biraz farklı okunuşununki. Sayı ya da
    /// olumsuzluk ekleyen/düşüren okuma ("at 5" / "at 6", "can" / "can't") aynı mesaj sayılmaz. Birden çok aday varsa
    /// kayıt sırasında ilk eşleşen kullanılır.
    /// </summary>
    internal static string? Translation(string source, IReadOnlyDictionary<string, string> known, IEnumerable<string>? order = null)
    {
        if (known.TryGetValue(source, out var exact)) return exact;
        foreach (var old in order ?? known.Keys)
            if (SameReading(source, old)) return known[old];
        return null;
    }

    /// <summary>
    /// İki okuma aynı mesaj mı: birebir aynı, sadeleştirilmiş hali aynı (soru işareti ikisinde de ya da hiçbirinde; "Ok." /
    /// "ok" kısa satırda da aynı mesaj) ya da en az <see cref="MinimumLetters"/> harfli iki uzun mesajda yalnız OCR artığı farklı:
    /// kesme işareti, noktalama, "rn" / "m", yan yana iki bozuk sözcük ya da en çok <see cref="SlipWords"/> sözcükte tek harf
    /// kayması. Gerçek sözcük değişimi ("here" / "there"), sayı ya da olumsuzluk ekleyen/düşüren okuma aynı sayılmaz (Mac ile aynı).
    /// </summary>
    internal static bool SameReading(string a, string b)
    {
        if (a == b) return true;
        string x = TextMatch.Normalize(a), y = TextMatch.Normalize(b);
        if (x.Length == 0 || y.Length == 0 || TextMatch.AddsMeaning(a, b) || TextMatch.AddsMeaning(b, a)) return false;
        // Kısa satırda soru işareti anlam taşır ("Ok?" / "Ok."); uzun mesajda düşen soru işareti OCR'ın kaçırdığı noktalamadır.
        if (x == y) return a.Contains('?') == b.Contains('?') || x.Count(char.IsLetter) >= MinimumLetters;
        if (x.Count(char.IsLetter) < MinimumLetters || y.Count(char.IsLetter) < MinimumLetters) return false;
        // Uzun cümlede gerçek bir sözcüğün değişmesi ("here" / "there") benzerlik eşiğini geçebilir.
        // Yalnız OCR'ın karıştırdığı harfler, kesme işareti ve noktalama artığı eşleşir.
        // Bitişik ya da ayrık okunan sözcük ("Yo Istill" / "Yo I still") da aynı mesajdır.
        string x2 = ReadingLetters(a), y2 = ReadingLetters(b);
        return x2 == y2 || x2.Replace(" ", "") == y2.Replace(" ", "") || GamePhoneText.HasAdjacentOcrEdits(a, b) || LetterSlips(a, b);
    }

    /// <summary>Aynı mesajın okunuşunda en çok bu kadar sözcükte tek harf kayabilir.</summary>
    internal const int SlipWords = 2;
    /// <summary>Tek harf kayması yalnız en az bu kadar harfli sözcükte aranır ("cold" / "bold" gibi kısa sözcükler anlam taşır).</summary>
    private const int SlipLetters = 5;

    /// <summary>
    /// Sözcük sayısı aynı, en çok <see cref="SlipWords"/> sözcükte OCR'ın tek harf kayması: aynı uzunlukta tek harf değişimi
    /// ("breathabie") ya da yan yana yinelenen harf ("SOMETHINnG"). Başa harf eklenmesi ("here" / "there") eşleşmez
    /// (X, 28 Kas, beta.107: her kayma yeni çeviri istiyor, Türkçe her turda değişiyordu).
    /// </summary>
    private static bool LetterSlips(string a, string b)
    {
        string[] x = ReadingLetters(a).Split(' '), y = ReadingLetters(b).Split(' ');
        if (x.Length != y.Length) return false;
        int slips = 0;
        for (int i = 0; i < x.Length; i++)
            if (x[i] != y[i] && (++slips > SlipWords || !LetterSlip(x[i], y[i]))) return false;
        return slips > 0;
    }

    private static bool LetterSlip(string p, string q)
    {
        if (Math.Min(p.Length, q.Length) < SlipLetters || !p.All(char.IsLetter) || !q.All(char.IsLetter)) return false;
        if (p.Length == q.Length) return p.Where((c, i) => c != q[i]).Count() == 1;
        var (shorter, longer) = p.Length < q.Length ? (p, q) : (q, p);
        if (longer.Length != shorter.Length + 1) return false;
        for (int i = 1; i < longer.Length; i++)
            if (longer[i] == longer[i - 1] && longer.Remove(i, 1) == shorter) return true;
        return false;
    }

    private static readonly System.Text.RegularExpressions.Regex EchoedLetter = new(@"(\p{L}),\1\b",
        System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    private static string ReadingLetters(string text) =>
        TextMatch.Normalize(EchoedLetter.Replace(text, "$1").Replace('’', '\'')
            .Replace("'l ", "'ll ", StringComparison.OrdinalIgnoreCase).Replace("'", ""))
            .Replace("rn", "m").Replace('q', 'g').Replace('l', 'i'); // OCR'ın sık karıştırdığı harfler ("flnd" / "find").

    /// <summary>Aynı yerdeki balonun başı, sonu ya da aradaki satırı eksik okunmuş mu.</summary>
    internal static bool TruncatedReading(string read, string shown)
    {
        static string Normalized(string text) => TextMatch.Normalize(text.Replace("'", "").Replace("’", ""));
        string shorter = Normalized(read), full = Normalized(shown);
        if (shorter.Length == 0 || shorter.Length >= full.Length) return false;
        if (full.StartsWith(shorter, StringComparison.Ordinal)
            && (full[shorter.Length] == ' ' || shorter.Length >= MinimumLetters)) return true;
        if (TextMatch.AddsMeaning(read, shown)) return false;
        if (TextMatch.IsGrowth(shown, read)) return true;
        // Bitişik okunan sözcüklerle de eksik okuma: boşluksuz hâli tam metnin içinde.
        if (shorter.Length >= MinimumLetters && full.Replace(" ", "").Contains(shorter.Replace(" ", ""), StringComparison.Ordinal))
            return true;
        var words = shorter.Split(' ');
        if (words.Length < 3) return false;
        int kept = 0;
        foreach (var word in full.Split(' '))
            if (word == words[kept] && ++kept == words.Length) return true;
        return false;
    }

    /// <summary>Önceki iki komşu balonun tek kutuda okunuşu; ikincisi yarım da kalabilir.</summary>
    internal static bool MergedReading(string read, string first, string second)
    {
        var combined = first + " " + second;
        return SameReading(read, combined)
            || (TextMatch.IsGrowth(read, first) && TruncatedReading(read, combined));
    }

    // Ekrandaki balonların kararlılığı (X, 22 Kas, GTA 6 telefonu: "yazılar sürekli oynuyor okumak çok zor, balonların
    // içinde de aynı hata var"). Her OCR turunda balon kutuları birkaç piksel oynuyor, telefonun bulunan yeri titriyordu;
    // her turda yeni kutular gönderiliyor, TV paneli ve balonları yeniden diziyordu. Mac/iPhone ve Android aynı kural.

    /// <summary>Aynı balonun yeri, satır yüksekliğinin bu payından az oynadıysa son çizilen yerde kalır (histerezis).</summary>
    internal const double PositionShare = 0.25;
    /// <summary>Yanda Panel'in dayandığı telefon yeri, kutusunun her kenarı bu kadardan (kareye oranla) az oynadıysa sabit kalır.</summary>
    internal const double PoseSlack = 0.015;

    /// <summary>
    /// Kaydırma: önceki okumayla eşleşen balonların hepsi dikeyde satır yüksekliğinin bu payından fazla, aynı yöne kaydıysa
    /// sohbet kaydırılıyor (<see cref="Scrolled"/>).
    /// </summary>
    internal const double ScrollShare = 0.5;

    /// <summary>
    /// Telefon kaydırıldı mı (GitHub #1202, #1197, #1193, #1170: "kaydırınca yenilenmiyor"). Kaydırma sırasında
    /// <see cref="HoldTurns"/> bekletmesi ve konum sabitleme (<see cref="SteadyPositions"/>) atlanır, görünen yeni balonların
    /// hepsi tek istekte çevrilir. <c>Top</c>'lar ve <paramref name="lineHeight"/> telefon bölgesine oranlıdır. Güncel her
    /// balon, öncekilerden henüz eşlenmemiş ilk <see cref="SameReading"/> eşiyle eşlenir; en az bir eşleşme olmalı ve
    /// hepsinin dikey kayması <see cref="ScrollShare"/> × satır yüksekliğinden büyük ve aynı yönde olmalı. Mac/iPhone ve
    /// Android aynı kural.
    /// </summary>
    internal static bool Scrolled(IReadOnlyList<(string Text, double Top)> previous, IReadOnlyList<(string Text, double Top)> current,
                                  double lineHeight)
    {
        if (lineHeight <= 0) return false;
        var used = new bool[previous.Count];
        int pairs = 0, direction = 0;
        foreach (var bubble in current)
        {
            int index = -1;
            for (int i = 0; i < previous.Count; i++)
                if (!used[i] && SameReading(previous[i].Text, bubble.Text)) { index = i; break; }
            if (index < 0) continue;
            used[index] = true;
            double dy = bubble.Top - previous[index].Top;
            if (Math.Abs(dy) <= ScrollShare * lineHeight) return false;
            int sign = Math.Sign(dy);
            if (direction != 0 && sign != direction) return false;
            direction = sign;
            pairs++;
        }
        return pairs > 0;
    }

    /// <summary>
    /// Balonların yeri: önceki gönderiyle eşleşen balonlar (<see cref="Match"/>) küçük oynamada (satır yüksekliğinin
    /// <see cref="PositionShare"/>'i; yatayda kare oranıyla) son çizilen yerde kalır. Eşleşenlerin yarısından çoğu eşiği aşarsa
    /// (telefon kıpırdadı, sohbet kaydı) hepsi birlikte, tek seferde yeni yerine geçer; tek başına eşiği aşan balon kendi
    /// yerine geçer. Boyu değişmeyen balonun kutusu birebir öncekidir. <paramref name="aspect"/>: karenin eni / boyu.
    /// </summary>
    internal static IReadOnlyList<ScreenTranslation.Item> SteadyPositions(IReadOnlyList<ScreenTranslation.Item> items,
        IReadOnlyList<ScreenTranslation.Item> previous, double aspect)
    {
        double ratio = Math.Max(0.1, aspect);
        bool Still(TextBox box, ScreenTranslation.Item old)
        {
            double limit = PositionShare * old.LineHeight;
            return Math.Abs(box.Top - old.Box.Top) <= limit && Math.Abs(box.Left - old.Box.Left) <= limit / ratio;
        }
        var pairs = new List<(int Index, ScreenTranslation.Item Old)>();
        for (int i = 0; i < items.Count; i++)
            if (Match(items[i], previous) is { } old) pairs.Add((i, old));
        int moved = pairs.Count(pair => !Still(items[pair.Index].Box, pair.Old));
        if (pairs.Count == 0 || 2 * moved > pairs.Count) return items;
        var result = items.ToList();
        foreach (var (index, old) in pairs)
        {
            var box = items[index].Box;
            if (!Still(box, old)) continue;
            double width = box.Right - box.Left, height = box.Bottom - box.Top;
            double oldWidth = old.Box.Right - old.Box.Left, oldHeight = old.Box.Bottom - old.Box.Top;
            result[index] = items[index] with
            {
                Box = new TextBox(old.Box.Left, old.Box.Top,
                    Math.Abs(width - oldWidth) < 1e-9 ? old.Box.Right : Math.Min(1, old.Box.Left + width),
                    Math.Abs(height - oldHeight) < 1e-9 ? old.Box.Bottom : Math.Min(1, old.Box.Top + height))
            };
        }
        return result;
    }

    /// <summary>İki yazı rengi zeminin aynı yanında mı (ikisi de zeminden koyu ya da ikisi de açık; algılanan parlaklıkla).</summary>
    internal static bool SameInk(string a, string b, string background)
    {
        static int? Brightness(string hex)
        {
            if (hex.Length != 7 || hex[0] != '#' || !int.TryParse(hex.AsSpan(1), System.Globalization.NumberStyles.HexNumber, null, out var value))
                return null;
            return (((value >> 16) & 0xFF) * 299 + ((value >> 8) & 0xFF) * 587 + (value & 0xFF) * 114) / 1000;
        }
        if (Brightness(a) is not { } x || Brightness(b) is not { } y || Brightness(background) is not { } z) return false;
        return (x < z) == (y < z);
    }

    /// <summary>
    /// Önceki gönderide bu balonun eşi: aynı çeviri ve parça, aynı okuma (<see cref="SameReading"/>), sol üst köşesi 0,05
    /// içinde. Aynı yerde iki eş varsa null.
    /// </summary>
    internal static ScreenTranslation.Item? Match(ScreenTranslation.Item item, IReadOnlyList<ScreenTranslation.Item> previous)
    {
        ScreenTranslation.Item? found = null;
        foreach (var old in previous)
        {
            if (old.Translation != item.Translation || old.Panel != item.Panel || Math.Abs(old.Box.Left - item.Box.Left) > .05
                || Math.Abs(old.Box.Top - item.Box.Top) > .05 || !SameReading(old.Source, item.Source)) continue;
            if (found is not null) return null;
            found = old;
        }
        return found;
    }

    /// <summary>Yanda Panel'in dayandığı telefon: yeni yerin kutusu öncekinden her kenarda <see cref="PoseSlack"/>'ten az oynadıysa önceki yer.</summary>
    internal static GamePhoneGeometry.Pose SteadyPose(GamePhoneGeometry.Pose pose, GamePhoneGeometry.Pose? anchor)
    {
        if (anchor is not { } previous) return pose;
        CropRegion a = pose.Bounds, b = previous.Bounds;
        bool still = Math.Abs(a.Left - b.Left) <= PoseSlack && Math.Abs(a.Right - b.Right) <= PoseSlack
            && Math.Abs(a.Top - b.Top) <= PoseSlack && Math.Abs(a.Bottom - b.Bottom) <= PoseSlack;
        return still ? previous : pose;
    }

    // Kararlı çıktı (X, 22 Kas: "sağ tarafta kutu çıkarıyorsun ama her saniye şekli de hareketi de değişiyor"). Telefonun
    // yazısı değişmedikçe çizilen Türkçe birebir aynı kalır: aynı mesaj aynı çeviriyle ve bir kez, gruptaki bütün balonlar
    // tek boyda; panelin kutusu yalnız telefon gerçekten kıpırdayınca kayar. Mac/iPhone ve Android aynı kural, aynı eşikler.

    /// <summary>Art arda gelmeyen iki öğe ancak bu kadar harften uzunsa aynı mesaj sayılıp sonraki atılır.</summary>
    internal const int RepeatLetters = 12;
    /// <summary>Telefonda aynı yerde duran balonun okunuşları bu benzerlikten yüksekse aynı mesajdır (<see cref="SameBubble"/>).</summary>
    internal const double SameSpotMessage = 0.8;
    /// <summary>Aynı yer: düz ekrandaki sol üst köşeleri bu kadar içinde.</summary>
    internal const double SameSpotShare = 0.05;

    /// <summary>
    /// Aynı mesaj panelde bir kez: telefondaki öğelerden bir öncekiyle aynı mesajı taşıyan (<see cref="SameReading"/>) art
    /// arda öğe atılır; araları açık iki öğeden sonraki ancak uzun mesajsa (<see cref="RepeatLetters"/>) atılır. Telefon
    /// dışındaki öğelere dokunulmaz (Mac ile aynı).
    /// </summary>
    internal static IReadOnlyList<ScreenTranslation.Item> WithoutRepeats(IReadOnlyList<ScreenTranslation.Item> items)
    {
        var kept = new List<ScreenTranslation.Item>();
        foreach (var item in items)
        {
            if (item.Phone is null)
            {
                kept.Add(item);
                continue;
            }
            var onPhone = kept.Where(old => old.Phone is not null).ToList();
            bool isLong = TextMatch.Normalize(item.Source).Count(char.IsLetter) >= RepeatLetters;
            bool repeated = false;
            for (int i = 0; i < onPhone.Count && !repeated; i++)
                repeated = SameReading(onPhone[i].Source, item.Source) && (i == onPhone.Count - 1 || isLong);
            if (!repeated) kept.Add(item);
        }
        return kept;
    }

    /// <summary>
    /// İki okuma aynı balon mu: aynı mesaj (<see cref="SameReading"/>) ya da telefonun ekranında aynı yerde
    /// (<see cref="SameSpotShare"/>) ve en az <see cref="MinimumLetters"/> harfli iki uzun okuma <see cref="SameSpotMessage"/>
    /// kadar benzer; sayı ya da olumsuzluk ekleyen/düşüren okuma aynı sayılmaz (Mac ile aynı).
    /// </summary>
    internal static bool SameBubble(string a, TextBox? spotA, string b, TextBox? spotB)
    {
        if (SameReading(a, b)) return true;
        if (spotA is not { } x || spotB is not { } y || Math.Abs(x.Top - y.Top) > SameSpotShare || Math.Abs(x.Left - y.Left) > SameSpotShare
            || TextMatch.AddsMeaning(a, b) || TextMatch.AddsMeaning(b, a)) return false;
        string p = TextMatch.Normalize(a), q = TextMatch.Normalize(b);
        return TruncatedReading(b, a) && p.Count(char.IsLetter) >= MinimumLetters && q.Count(char.IsLetter) >= MinimumLetters
            && TextMatch.IsSimilar(p, q, SameSpotMessage);
    }

    /// <summary>Ekranda aynı yerde duran aynı balonun gösterilen çevirisi (<see cref="SameBubble"/>); yoksa null.</summary>
    internal static string? ShownTranslation(string source, TextBox? spot, IReadOnlyList<ScreenTranslation.Item>? shown) =>
        shown?.FirstOrDefault(item => item.Phone is not null && !item.Unchanged && item.Icons is null && !item.Translation.Contains('\n')
            && SameBubble(item.Source, item.Phone.Spot, source, spot))?.Translation;

    /// <summary>
    /// Önceki gönderide aynı balon (<see cref="SameBubble"/>) varsa öğe onun kaynağını ve çevirisini aynen alır: aynı İngilizce
    /// için Türkçe her okumada yeniden üretilmez. Her önceki öğe en çok bir kez kullanılır (Mac ile aynı).
    /// </summary>
    internal static IReadOnlyList<ScreenTranslation.Item> KeptTranslations(IReadOnlyList<ScreenTranslation.Item> items,
                                                                          IReadOnlyList<ScreenTranslation.Item> previous)
    {
        var used = new HashSet<int>();
        return items.Select(item =>
        {
            for (int i = 0; i < previous.Count; i++)
            {
                var old = previous[i];
                if (used.Contains(i) || (old.Phone is null) != (item.Phone is null) || old.Unchanged != item.Unchanged
                    || !SameBubble(old.Source, old.Phone?.Spot, item.Source, item.Phone?.Spot)) continue;
                used.Add(i);
                return item with { Source = old.Source, Translation = old.Translation, Icons = old.Icons };
            }
            return item;
        }).ToList();
    }

    /// <summary>Gruptaki bütün mesaj balonları tek yazı boyunda (<paramref name="line"/>: kilitli ölçüm); kişinin adı ve telefon dışı öğeler kendi boyunda.</summary>
    internal static IReadOnlyList<ScreenTranslation.Item> UniformLine(IReadOnlyList<ScreenTranslation.Item> items, double? line)
    {
        if (line is not { } value || value <= 0) return items;
        return items.Select(item => item.Phone?.Role is { } role && role.InCard() && role is not ScreenPhoneCard.Role.Header
            and not ScreenPhoneCard.Role.Contact ? item with { LineHeight = value } : item).ToList();
    }

    /// <summary>
    /// Panelin zemini (kart) kısalmaz: yeni kart öncekiyle aynı yanda, aynı genişlikte ve onun içinde kalıyorsa önceki kart
    /// kalır; telefon gerçekten kıpırdayınca yeni kart geçer (Mac ile aynı).
    /// </summary>
    internal static IReadOnlyList<ScreenTranslation.Item> SteadyCard(IReadOnlyList<ScreenTranslation.Item> shown,
                                                                     IReadOnlyList<ScreenTranslation.Item>? previous)
    {
        int index = -1;
        for (int i = 0; i < shown.Count && index < 0; i++) if (shown[i].Panel == ScreenPhoneCard.PanelPart.Card) index = i;
        if (index < 0 || previous?.FirstOrDefault(item => item.Panel == ScreenPhoneCard.PanelPart.Card)?.Box is not { } old) return shown;
        var box = shown[index].Box;
        const double near = 1e-9;
        if (Math.Abs(box.Left - old.Left) >= near || Math.Abs(box.Right - old.Right) >= near
            || box.Top < old.Top - near || box.Bottom > old.Bottom + near) return shown;
        var result = shown.ToList();
        result[index] = result[index] with { Box = old };
        return result;
    }

    /// <summary>
    /// İki gönderi TV'de ve masaüstünde aynı görünür mü. Panelin mesajları, kişi adı ve notları akışla çizilir: yalnız sırası,
    /// yazısı ve rengi önemlidir; panelin zemini ve panel dışındaki her öğe yeriyle aynı olmalıdır.
    /// </summary>
    internal static bool SamePicture(IReadOnlyList<ScreenTranslation.Item> a, IReadOnlyList<ScreenTranslation.Item> b)
    {
        if (a.Count != b.Count) return false;
        // Hizalı panelde parçalar kutularının yerinde çizilir: kutuları da aynı olmalı (Mac ile aynı).
        var aligned = a.Any(item => item.Panel == ScreenPhoneCard.PanelPart.Card && item.Aligned);
        for (int i = 0; i < a.Count; i++)
        {
            var (x, y) = (a[i], b[i]);
            bool icons = x.Icons is null ? y.Icons is null : y.Icons is not null && x.Icons.SequenceEqual(y.Icons);
            if (x.Panel != y.Panel || x.Translation != y.Translation || x.Style != y.Style || x.Look != y.Look || !icons
                || x.Bubble != y.Bubble || x.LineHeight != y.LineHeight || x.Aligned != y.Aligned
                || !Equals(x.ListRow, y.ListRow)) return false;
            if ((aligned || x.Panel is null or ScreenPhoneCard.PanelPart.Card) && x.Box != y.Box) return false;
        }
        return true;
    }
}

/// <summary>
/// Yanda Panel'in yazı boyu ve yeri oturum boyunca kararlı (#1152, GTA 6: "telefon titreyince sohbet panelinin yazıları
/// büyüyüp küçülüyor, balonlar yer değiştiriyor"). Panel ilk ölçümde kilitlenir: telefonun yeri ancak belirgin biçimde
/// (boyu <see cref="SizeShare"/>'den, ortası boyunun <see cref="MoveShare"/>'inden fazla) ve kesintisiz
/// <see cref="SettleMs"/> boyunca başka yerdeyse, satır yüksekliği ancak kilitliden <see cref="SizeShare"/>'den fazla ve
/// kesintisiz <see cref="SettleMs"/> boyunca farklıysa yenilenir; telefonun boyu belirgin değişip yeni yer benimsenince
/// yazı boyu yeniden ölçülür. Mac/iPhone (PhonePanelSteady, PhoneSteady.swift) ve Android (PhoneSteady.kt) aynı kuralı,
/// aynı eşikleri kullanır.
/// </summary>
internal sealed class PhonePanelSteady
{
    internal const double SizeShare = 0.25;
    internal const double MoveShare = 0.1;
    internal const long SettleMs = 1000;

    internal GamePhoneGeometry.Pose? Pose { get; private set; }
    internal double? Line { get; private set; }
    private long? poseSince;
    private long? lineSince;
    /// <summary>
    /// Son kilitli yazı boyu ve o andaki telefon boyu: telefon kapanıp açılınca yazı boyu baştan ölçülmez; telefon aynı
    /// boydaysa (<see cref="SizeShare"/> içinde) aynı boy kalır. <see cref="Reset"/> bunu silmez, <see cref="Forget"/> siler.
    /// </summary>
    internal (double Line, double Height)? Remembered { get; private set; }

    /// <summary>Panelin dayanacağı telefon yeri; <c>Resized</c>: boyu belirgin değişti (ya da ilk yer).</summary>
    internal (GamePhoneGeometry.Pose Pose, bool Resized) SteadyPose(GamePhoneGeometry.Pose found, long now)
    {
        if (Pose is not { } locked)
        {
            Pose = found;
            poseSince = null;
            // Aynı boydaki telefon yeniden açıldı: yazı boyu öncekiyle aynı kalır.
            if (Line is null && Remembered is { } remembered && remembered.Height > 0
                && Math.Abs(Height(found) / remembered.Height - 1) <= SizeShare)
            {
                Line = remembered.Line;
                return (found, false);
            }
            return (found, true);
        }
        if (SameSpot(found, locked))
        {
            poseSince = null;
            return (locked, false);
        }
        if (poseSince is not { } since || now - since < SettleMs)
        {
            poseSince ??= now;
            return (locked, false);
        }
        poseSince = null;
        if (Resized(found, locked))
        {
            Pose = found;
            Line = null;
            lineSince = null;
            return (found, true);
        }
        // Boyu aynı kalan telefon yalnız yer değiştirdi: panel telefona sabit uzaklıkla, aynı boyda izler.
        var moved = Shifted(locked, found);
        Pose = moved;
        return (moved, false);
    }

    /// <summary>Telefonun yüksekliği (kareye oranla).</summary>
    internal static double Height(GamePhoneGeometry.Pose pose) => pose.Bounds.Bottom - pose.Bounds.Top;

    /// <summary><paramref name="locked"/> telefonun, ortası <paramref name="found"/>'unkine gelecek biçimde kaydırılmış hali.</summary>
    internal static GamePhoneGeometry.Pose Shifted(GamePhoneGeometry.Pose locked, GamePhoneGeometry.Pose found)
    {
        if (Math.Abs((found.BottomY - found.TopY) - (locked.BottomY - locked.TopY)) < 1e-9
            && Math.Abs((found.BottomX - found.TopX) - (locked.BottomX - locked.TopX)) < 1e-9) return found;
        CropRegion a = locked.Bounds, b = found.Bounds;
        double dx = (b.Left + b.Right - a.Left - a.Right) / 2, dy = (b.Top + b.Bottom - a.Top - a.Bottom) / 2;
        return new GamePhoneGeometry.Pose(locked.TopX + dx, locked.TopY + dy, locked.BottomX + dx, locked.BottomY + dy);
    }

    /// <summary>Panelin satır yüksekliği (<see cref="ScreenPhoneCard.MeasuredLine"/>); ölçüm yoksa kilitli değer.</summary>
    internal double? SteadyLine(double? measured, long now)
    {
        var result = LockedLine(measured, now);
        if (result is { } line && Pose is { } pose) Remembered = (line, Height(pose));
        return result;
    }

    private double? LockedLine(double? measured, long now)
    {
        if (measured is not { } value || value <= 0) return Line;
        if (Line is not { } locked)
        {
            Line = value;
            lineSince = null;
            return value;
        }
        if (Math.Abs(value / locked - 1) <= SizeShare)
        {
            lineSince = null;
            return locked;
        }
        if (lineSince is not { } since || now - since < SettleMs)
        {
            lineSince ??= now;
            return locked;
        }
        Line = value;
        lineSince = null;
        return value;
    }

    /// <summary>Telefon kayboldu: sonraki bulunuşta yeri yeniden ölçülür; aynı boydaki telefonun yazı boyu hatırlanır.</summary>
    internal void Reset()
    {
        Pose = null;
        Line = null;
        poseSince = null;
        lineSince = null;
    }

    /// <summary>Çeviri durdu: her şey unutulur.</summary>
    internal void Forget()
    {
        Reset();
        Remembered = null;
    }

    /// <summary>Kenarlar <see cref="PhoneSteady.PoseSlack"/> içinde ya da boy <see cref="SizeShare"/> içinde ve ortası az kaymış.</summary>
    internal static bool SameSpot(GamePhoneGeometry.Pose a, GamePhoneGeometry.Pose b)
    {
        CropRegion x = a.Bounds, y = b.Bounds;
        if (Math.Abs(x.Left - y.Left) <= PhoneSteady.PoseSlack && Math.Abs(x.Right - y.Right) <= PhoneSteady.PoseSlack
            && Math.Abs(x.Top - y.Top) <= PhoneSteady.PoseSlack && Math.Abs(x.Bottom - y.Bottom) <= PhoneSteady.PoseSlack) return true;
        double height = y.Bottom - y.Top, width = y.Right - y.Left;
        if (height <= 0 || width <= 0 || Resized(a, b)) return false;
        return Math.Abs((x.Top + x.Bottom) - (y.Top + y.Bottom)) / 2 <= MoveShare * height
            && Math.Abs((x.Left + x.Right) - (y.Left + y.Right)) / 2 <= 2 * MoveShare * width;
    }

    /// <summary>Telefonun boyu belirgin değişti mi.</summary>
    internal static bool Resized(GamePhoneGeometry.Pose a, GamePhoneGeometry.Pose b)
    {
        double x = a.Bounds.Bottom - a.Bounds.Top, y = b.Bounds.Bottom - b.Bounds.Top;
        return y <= 0 || Math.Abs(x / y - 1) > SizeShare;
    }
}
