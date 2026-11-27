// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;

namespace CouchSubs.Core;

/// <summary>
/// Oyun dünyasındaki yazı (tabela, tişört, plaka, afiş) altyazı alanına düşse de altyazı değildir. Alt bölge karenin
/// üçte birinden büyüktür (yükseklikte %35, genişlikte %72); GTA 6'da yürüyen karakterin tişörtü ya da sokaktaki tabela
/// o alana girince altyazı bloğu seçiliyor, ekranda altyazı yokken tek başına çevriliyordu (X bildirimleri, beta.73).
/// Altyazı bloğu seçilirken (<see cref="Reading.SubtitleBlock"/>) şu bloklar atılır; konuşan adı taşıyan blok hep
/// altyazıdır:
/// eğik satır (en az üç sözcük; perspektifli tabela: sözcüklerin dikey ortası satır boyunca tek yöne kayıyor ya da satır
/// kutusu sözcük boyunun <see cref="TiltedLineHeight"/> katından yüksek), düşük güvenli kısa blok (en çok
/// <see cref="LowConfidenceWords"/> sözcük, ortalama güven <see cref="LowConfidence"/>'tan az), karenin ortasındaki kısa,
/// noktalamasız tek satır (en çok üç sözcük; altyazı ve görev satırı karenin alt ya da üst kenarına yakındır,
/// <see cref="EdgeBand"/>), plaka/tabela: alt alta kısa, büyük harfli satırlar (<see cref="IsSign"/>) ve harfsiz sayı
/// (<see cref="IsNumber"/>); altyazının yerinde de.
/// Gerçek altyazı asla atılmaz (GitHub #822): altyazısı alttaki %22'lik şeridin biraz üstünde duran oyunlarda kısa
/// altyazıların hepsi "ortadaki kısa satır" sayılıp atılıyordu. Altyazı biçimindeki blok (ortalanmış, alt şeritte, en az
/// iki sözcük) düşük güvenle de atılmaz; bu oturumda kesin altyazı okunan yükseklikteki blok
/// (<see cref="SubtitleBand"/>) yalnız eğikse atılır. Atılan bloğun nedeni altyazı günlüğüne yazılır
/// (<see cref="Reason"/>). Mac/iPhone (SceneText.swift) ve Android (SceneText.kt) aynı kuralları ve eşikleri uygular;
/// ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/scene-text.json.
/// </summary>
public static class SceneText
{
    /// <summary>Sözcüklerin dikey ortası ilk sözcükten sonuncuya bu kadar sözcük boyu kayarsa satır eğiktir.</summary>
    public const double TiltShift = 0.6;
    /// <summary>Satır kutusu sözcüklerin ortanca boyunun bu katından yüksekse satır eğiktir.</summary>
    public const double TiltedLineHeight = 1.8;
    public const double LowConfidence = 0.4;
    public const int LowConfidenceWords = 5;
    /// <summary>Kısa ve noktalamasız tek satır en çok bu kadar sözcüktür.</summary>
    public const int ShortWords = 3;
    /// <summary>Karenin alt ve üst kenarından bu kadarı (karenin yüksekliğine oranla) altyazı şerididir.</summary>
    public const double EdgeBand = 0.22;
    /// <summary>Ortalanmış sayılmak için bloğun yatay ortasının karenin ortasından en çok uzaklığı.</summary>
    public const double CenterTolerance = 0.12;

    /// <summary>
    /// <paramref name="block"/> bir sahne yazısı mı. Satır kutuları <paramref name="area"/>'ya oranlıdır;
    /// <paramref name="area"/> okunan alanın karedeki yeridir.
    /// </summary>
    public static bool IsSceneText(Reading block, TextBox area, SubtitleBand? band = null) => Reason(block, area, band) is not null;

    /// <summary>
    /// Blok sahne yazısıysa atılma nedeni (altyazı günlüğü için), değilse null. <paramref name="darkInk"/>: satır kutusu
    /// (okunan alanın görüntüsüne oranla) açık zeminde koyu yazı mı (<see cref="InkTone.Sampler"/>); verilmezse renge bakılmaz.
    /// </summary>
    public static string? Reason(Reading block, TextBox area, SubtitleBand? band = null, Func<TextBox, bool>? darkInk = null)
    {
        if (block.Lines.Count == 0 || SpeakerPrefix.Parse(block.Lines[0].Text) is not null) return null;
        if (block.Lines.Any(line => line.Box is null) || block.Box is not { } whole) return null;
        // Kâğıt ilan altyazının yerinde de atılır (GitHub #1124).
        if (darkInk is not null && InkTone.IsDarkBlock(block, darkInk)) return InkTone.Reason;
        var box = whole.PlacedIn(area);
        var words = WordCount(block.Text);
        var middle = (box.Top + box.Bottom) / 2;
        // Plaka ve tabela altyazının yerinde de atılır (GitHub #1052).
        if (IsSign(block)) return SignReason;
        if (IsNumber(block.Text)) return NumberReason;
        // Plaka numarası ("HV85.", "BN25 32."; #1411) altyazının yerinde de atılır.
        if (IsPlateNumber(block.Text)) return PlateNumberReason;
        // Bu oturumda altyazının okunduğu yükseklik: yalnız eğik tabela ve tuş simgeli menü eylemi atılır.
        var learned = band?.Contains(box) == true;
        // Silah çarkı, mağaza ve menü satırı (GitHub #1285, #1293); rakamlı büyük harfli ad yalnız altyazının yüksekliği
        // dışında (beta.103 kaçan altyazı).
        if (IsMenuItem(block, learned)) return MenuItemReason;
        // Altyazı biçimi: ortalanmış, karenin alt şeridinde, en az iki sözcük.
        var subtitleLike = IsCentered(box) && middle >= 1 - EdgeBand && words >= 2;
        if (block.Lines.Any(IsTilted) && !subtitleLike) return TiltedReason;
        if (learned || subtitleLike) return null;
        if (block.Confidence is { } confidence && confidence < LowConfidence && words <= LowConfidenceWords)
            return $"düşük tanıma güveni ({confidence.ToString("0.00", CultureInfo.InvariantCulture)})";
        if (block.Lines.Count == 1 && words <= ShortWords && !LooksSpoken(block.Lines[0].Text) && middle > EdgeBand && middle < 1 - EdgeBand)
            return "karenin ortasında kısa satır";
        return null;
    }

    /// <summary>Sözcük yerleri biliniyorsa satır eğik mi (perspektifli tabela, yan duran tişört). Altyazı yatay yazılır.</summary>
    internal static bool IsTilted(TextLine line)
    {
        if (line.Words is not { Count: >= 3 } words || line.Box is not { } box) return false;
        var heights = words.Select(word => word.Box.Bottom - word.Box.Top).OrderBy(height => height).ToList();
        var median = heights[heights.Count / 2];
        if (median <= 0) return false;
        if (box.Bottom - box.Top > TiltedLineHeight * median) return true;
        var middles = words.OrderBy(word => word.Box.Left).Select(word => (word.Box.Top + word.Box.Bottom) / 2).ToList();
        var shift = middles[^1] - middles[0];
        if (Math.Abs(shift) <= TiltShift * median) return false;
        // Tek yöne kayma: aradaki sözcükler geri dönmez (yazı tanımanın kutu oynaması sözcük boyunun %15'i kadar).
        var direction = shift > 0 ? 1.0 : -1.0;
        return middles.Zip(middles.Skip(1)).All(pair => (pair.Second - pair.First) * direction >= -0.15 * median);
    }

    /// <summary>
    /// Plaka ya da tabela: en az iki satır ve her satır <see cref="IsSignLine"/>; noktalama yalnız son satırın sonunda ve o
    /// satır tek sözcükse olabilir (yazı tanıma plakanın kenarını "." ya da "!" okuyor: "AKB / GLORIANA.", "AK8 / FLORIA!").
    /// Kullanıcı bildirimi (GitHub #1052, GTA 6, beta.84): plaka iki-üç satır okunduğu için tek satır kuralına takılmıyor,
    /// altyazının yerinde durduğu için de (<see cref="SubtitleBand"/>) çevriliyordu ("AKB / FLORIANA", "DISCOVER 28 / AKB /
    /// GLORIANA."). Altyazı satırı en çok üç sözcükken sarılmaz; kısa bağırma replikleri ("NO! / GET DOWN!") ilk satırda
    /// noktalama taşıdığı için kalır, konuşan adlı blok hep altyazıdır (Mac: SceneText.isSign, Android: SceneText.isSign).
    /// </summary>
    internal static bool IsSign(Reading block)
    {
        if (block.Lines.Count < 2 || !block.Lines.All(line => IsSignLine(line.Text))) return false;
        if (block.Lines.Take(block.Lines.Count - 1).Any(line => LooksSpoken(line.Text))) return false;
        var last = block.Lines[^1].Text;
        return !LooksSpoken(last) || WordCount(last) <= 1;
    }

    /// <summary>
    /// Plaka/tabela satırı: kısa (en çok <see cref="SignLineLength"/> karakter ve en çok <see cref="ShortWords"/> sözcük),
    /// küçük harfsiz, en az bir büyük harf; soru işareti, tire ile başlayan karşılıklı konuşma ve konuşan adı yok.
    /// Büyük/küçük harfi olmayan yazıya (Japonca) dokunulmaz.
    /// </summary>
    internal static bool IsSignLine(string text)
    {
        var line = text.Trim();
        if (line.Length == 0 || line.Length > SignLineLength || !line.Any(char.IsUpper) || line.Any(char.IsLower)) return false;
        if (line.Contains('?') || "-–—".Contains(line[0]) || SpeakerPrefix.Parse(line) is not null) return false;
        return WordCount(line) <= ShortWords;
    }

    /// <summary>Plaka/tabela satırının en çok karakteri ("C118 DISCOVER 76").</summary>
    internal const int SignLineLength = 20;

    /// <summary>Harfsiz sayı ("82403610."): plaka numarası, sayaç; altyazı değildir.</summary>
    internal const string MenuItemReason = "menü/mağaza satırı (tuş simgeli eylem ya da rakamlı büyük harfli ad)";
    internal const string SignReason = "plaka/tabela (kısa büyük harfli satırlar)";
    internal const string NumberReason = "harfsiz sayı";
    internal const string PlateNumberReason = "plaka numarası (harfli rakamlı kısa yazı)";
    internal const string TiltedReason = "eğik satır (tabela)";

    /// <summary>
    /// Silah çarkı, mağaza ve menü satırı (GitHub #1285, #1293; GTA 6, ekran yazısı çevirisi kapalıyken): altyazı alanına
    /// düşen "srow LONGARMS O TAKE AMMO", "SHOW SHIRT (1/3) A BUY O BU", "IN LJ TYPE 9 SMG" konuşma sanılıp bozuk
    /// çevriliyordu. Hiçbir satırı konuşma izi (<see cref="LooksSpoken"/>) taşımayan blokta: tuş simgesinin okunuşunun
    /// ("O", "X", "A", "•", simge) hemen ardından menü eylemi (<see cref="MenuActions"/>) ya da küçük harfsiz, en az bir
    /// sözcüklü ve rakamlı yazı (ürün/silah adı, fiyat). Konuşan adlı blok ve noktalamalı bağırma altyazı kalır (Mac:
    /// SceneText.isMenuItem, Android: isMenuItem). Rakamlı büyük harfli yazı yalnız kanıtla atılır (beta.103, iki kullanıcı:
    /// "bazı altyazıları kaçırıyor"): bu oturumda altyazının okunduğu yükseklikteyse (<paramref name="learned"/>) ya da
    /// kişi zamiri taşıyorsa ("I NEED 50 GRAND") noktalamasız bağırma altyazıdır. Tuş simgesi + menü eylemi her yerde atılır.
    /// </summary>
    internal static bool IsMenuItem(Reading block, bool learned = false)
    {
        if (block.Lines.Any(line => LooksSpoken(line.Text))) return false;
        var tokens = block.Lines.SelectMany(line => line.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).ToList();
        for (var i = 0; i + 1 < tokens.Count; i++)
            if (IsGlyph(tokens[i]) && MenuActions.Contains(tokens[i + 1])) return true;
        if (learned || tokens.Any(token => Pronouns.Contains(token.Replace('’', '\'')))) return false;
        var text = block.Text;
        return text.Any(char.IsUpper) && !text.Any(char.IsLower) && tokens.Any(token => token.Any(char.IsDigit))
            && tokens.Any(token => token.Count(char.IsLetter) >= 2);
    }

    /// <summary>Menünün tuş eylemleri ("△ BUY", "○ TAKE AMMO", "□ ADD TO TRUNK"); büyük harfle yazılır.</summary>
    internal static readonly HashSet<string> MenuActions =
        ["BUY", "SELL", "TAKE", "EQUIP", "ADD", "REMOVE", "RENAME", "DELETE", "CUSTOMIZE", "PREVIEW", "PURCHASE"];

    /// <summary>
    /// Tuş simgesinin yazı tanımadaki okunuşu: "O" (○), "X" (✕), "A" (△) ya da harf ve rakam olmayan tek karakter
    /// ("•", "□", <see cref="ButtonIcons.Marker"/>).
    /// </summary>
    internal static bool IsGlyph(string token) =>
        token is "O" or "X" or "A" || (new System.Globalization.StringInfo(token).LengthInTextElements == 1
            && !token.Any(char.IsLetterOrDigit) && token is not ("-" or "–" or "—"));

    /// <summary>Büyük harfli konuşmanın kişi zamirleri: ürün, silah ve menü adında geçmez (<see cref="IsMenuItem"/>).</summary>
    internal static readonly HashSet<string> Pronouns =
        ["I", "I'M", "I'LL", "I'VE", "I'D", "ME", "MY", "YOU", "YOU'RE", "YOUR", "WE", "WE'RE", "US", "OUR",
         "HE", "SHE", "HIM", "HER", "THEY", "THEM"];

    internal static bool IsNumber(string text) => !text.Any(char.IsLetter) && text.Any(char.IsDigit);

    /// <summary>
    /// Plaka numarası: en çok <see cref="PlateTokens"/> parça, harfleri yalnız büyük Latin harfi (A–Z) ve en az bir parçada
    /// hem harf hem rakam ("HV85.", "EN25.", "BN25 32.", "A80 3."). Kullanıcı bildirimi (#1411, GTA 6, Mac, beta-105):
    /// arabanın plakası altyazı alanına girince numarası tek satır okunuyor, noktalı okunduğu için konuşma sanılıp
    /// çevriliyordu. Küçük harfli satır ("855, on scene now."), dört ve daha çok parçalı bağırma ("I NEED 50 GRAND") ve
    /// Latin dışı yazı (Japonca "あと3分だ") altyazı kalır (Mac: SceneText.isPlateNumber, Android: isPlateNumber).
    /// </summary>
    internal static bool IsPlateNumber(string text)
    {
        var tokens = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(token => new string(token.Where(char.IsLetterOrDigit).ToArray())).Where(token => token.Length > 0).ToList();
        if (tokens.Count == 0 || tokens.Count > PlateTokens) return false;
        if (!tokens.All(token => token.All(c => c is >= 'A' and <= 'Z' or >= '0' and <= '9'))) return false;
        return tokens.Any(token => token.Any(c => c is >= 'A' and <= 'Z') && token.Any(c => c is >= '0' and <= '9'));
    }

    /// <summary>Plaka numarasının en çok parçası (<see cref="IsPlateNumber"/>).</summary>
    internal const int PlateTokens = 3;

    internal static bool IsCentered(TextBox box) => Math.Abs((box.Left + box.Right) / 2 - 0.5) <= CenterTolerance;

    /// <summary>Konuşma izi: cümle sonu noktalaması, virgül, noktalı virgül ya da tırnak.</summary>
    internal static bool LooksSpoken(string text) =>
        SubtitleStabilizer.EndsSentence(text) || text.Any(c => ",;\"“”".Contains(c));

    internal static int WordCount(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(word => word.Any(char.IsLetter));
}

/// <summary>
/// Bu oturumda kesin altyazı okunan yükseklikler (karenin yüksekliğine oranla). Altyazı her oyunda kendi yerinde durur;
/// orada okunan kısa satır ("Let's go") tabela sayılmaz (<see cref="SceneText.Reason"/>). Kesin altyazı: ortalanmış,
/// sahne yazısı sayılmayan ve en az dört sözcüklü, konuşma noktalamalı ya da konuşan adlı blok. Hat sıfırlanınca unutulur
/// (Mac: SubtitleBand, Android: SubtitleBand).
/// </summary>
public sealed class SubtitleBand
{
    /// <summary>En çok bu kadar yükseklik hatırlanır (en eskisi düşer).</summary>
    public const int Capacity = 6;
    /// <summary>Kesin altyazı sayılmak için en az sözcük (noktalaması ya da konuşan adı yoksa).</summary>
    public const int SureWords = 4;

    private readonly List<(double Top, double Bottom, double Line, string[] Texts)> spans = [];

    /// <summary>Bu oturumda hiç altyazı yüksekliği öğrenilmedi.</summary>
    public bool IsEmpty => spans.Count == 0;

    /// <summary>
    /// Hatırlanan yüksekliğin her yanındaki pay (satır boyuna oranla). GTA 6'da görev satırı ("Follow the plane") altyazının
    /// hemen altında belirir; pencere kaynağında orta noktası bir satır payının hemen dışında kalıyordu (Mac/Android: aynı).
    /// </summary>
    public const double Margin = 1.5;

    /// <summary>Kutunun (karede) dikey ortası hatırlanan bir altyazı yüksekliğine (<see cref="Margin"/> satır boyu payla) düşüyor mu.</summary>
    public bool Contains(TextBox box)
    {
        var middle = (box.Top + box.Bottom) / 2;
        return spans.Any(span => middle >= span.Top - Margin * span.Line && middle <= span.Bottom + Margin * span.Line);
    }

    /// <summary>
    /// Kutunun tamamı (üstü ve altı) oyunun konuşma altyazısının okunduğu tek bir yüksekliğin içinde mi (<see cref="Margin"/>
    /// satır boyu payla; <see cref="SceneTextMemory.Filter"/>). Yalnız konuşma izi taşıyan (konuşan adı ya da konuşma
    /// noktalaması, <see cref="SceneText.LooksSpoken"/>) bloktan öğrenilen yükseklik sayılır: noktalamasız dört sözcük
    /// ("A LIBERTY CITY MEMOIR") altyazı sanılıp öğrenilebiliyor. Satırlarından biri <paramref name="sceneText"/> olan
    /// yükseklik de sayılmaz (altyazı sanılıp öğrenilen telefon/tabela yazısı).
    /// </summary>
    public bool Holds(TextBox box, Func<string, bool>? sceneText = null) =>
        spans.Any(span => box.Top >= span.Top - Margin * span.Line && box.Bottom <= span.Bottom + Margin * span.Line
                          && span.Texts.Any(text => SpeakerPrefix.Parse(text) is not null || SceneText.LooksSpoken(text))
                          && (sceneText is null || !span.Texts.Any(sceneText)));

    /// <summary>Seçilen altyazı bloğu kesin altyazıysa yüksekliği hatırlanır. Satır kutuları alana oranlıdır.</summary>
    public void Record(Reading block, TextBox area)
    {
        if (block.Lines.Count == 0 || block.Box is not { } whole) return;
        var box = whole.PlacedIn(area);
        if (!SceneText.IsCentered(box)) return;
        var sure = SpeakerPrefix.Parse(block.Lines[0].Text) is not null || SceneText.WordCount(block.Text) >= SureWords
            || block.Lines.Any(line => SceneText.LooksSpoken(line.Text));
        if (!sure || SceneText.IsSceneText(block, area)) return;
        var line = (box.Bottom - box.Top) / block.Lines.Count;
        spans.RemoveAll(span => Math.Abs(span.Top - box.Top) < line / 2 && Math.Abs(span.Bottom - box.Bottom) < line / 2);
        spans.Add((box.Top, box.Bottom, line, [.. block.Lines.Select(row => row.Text)]));
        if (spans.Count > Capacity) spans.RemoveRange(0, spans.Count - Capacity);
    }

    public void Reset() => spans.Clear();
}
