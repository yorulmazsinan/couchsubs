// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>Yazının yeri, içinde bulunduğu alanın kenarlarına oranla (0–1, üstten ve soldan).</summary>
public readonly record struct TextBox(double Left, double Top, double Right, double Bottom)
{
    public TextBox Union(TextBox other) =>
        new(Math.Min(Left, other.Left), Math.Min(Top, other.Top), Math.Max(Right, other.Right), Math.Max(Bottom, other.Bottom));

    /// <summary>Bu kutu <paramref name="area"/> içindeki oranlarsa, aynı yerin <paramref name="area"/>'yı içeren çerçevedeki oranları.</summary>
    public TextBox PlacedIn(TextBox area)
    {
        var width = area.Right - area.Left;
        var height = area.Bottom - area.Top;
        return new(area.Left + (Left * width), area.Top + (Top * height), area.Left + (Right * width), area.Top + (Bottom * height));
    }

    /// <summary>
    /// Ekranın ortasındaki altyazının kutusu ortaya göre simetrik genişletilir. Açık zeminde ya da renkli yazıda yazı
    /// tanıma satırın bir ucunu okuyamayabilir; kutu yalnız okunan parçayı örterse İngilizcenin geri kalanı yanda görünür
    /// ve çeviri ortalanmamış durur. Ortadan uzak (köşedeki) yazıya dokunulmaz (Mac: TextBox.centeredOnScreen).
    /// </summary>
    public TextBox CenteredOnScreen()
    {
        var middle = (Left + Right) / 2;
        if (middle <= 0.3 || middle >= 0.7) return this;
        return this with { Left = Math.Max(0, Math.Min(Left, 1 - Right)), Right = Math.Min(1, Math.Max(Right, 1 - Left)) };
    }
}

/// <summary>
/// Yazı tanımanın bulduğu bir satır; kutu okunan alana göredir, bilinmiyorsa null. Güven 0–1'dir; okuyucu vermiyorsa
/// null (Windows'un yazı tanıması vermez).
/// </summary>
/// <param name="Words">Okuyucu sözcüklerin yerini de veriyorsa (Windows yazı tanıması) sözcükler, satırla aynı oranlarda;
/// kumanda simgesini bulmak için (<see cref="ButtonIcons"/>).</param>
/// <param name="Icons">Metindeki her <see cref="ButtonIcons.Marker"/> için, sırasıyla, simgenin yeri ve okunan hali.</param>
public sealed record TextLine(string Text, TextBox? Box = null, double? Confidence = null,
                              IReadOnlyList<TextWord>? Words = null, IReadOnlyList<IconSlot>? Icons = null)
{
    // Balonlar düz telefon ekranında gruplanır; Box, TV'de gösterim için oyun görüntüsündeki kutudur.
    internal TextBox? PhoneBox { get; init; }
    /// <summary>
    /// Telefonun sohbet listesinde (<see cref="GamePhoneText.ForTranslation"/>) satırın rolü: kişi adı, önizleme ya da bölüm
    /// başlığı. Liste değilse null. Mac ile aynı.
    /// </summary>
    internal ScreenPhoneCard.Role? ListRole { get; init; }
}

/// <summary>Yazı tanımanın bulduğu bir sözcük ve yeri (okunan alanın kenarlarına oranla).</summary>
public sealed record TextWord(string Text, TextBox Box);

/// <summary>
/// Yazının içindeki kumanda simgesi ("Hold △ to sprint"). Yazı tanıma simgeyi harf sanar ("A", "Ä") ya da hiç okumaz;
/// <paramref name="Text"/> okunan hali (boş olabilir), <paramref name="Box"/> karedeki yeri, <paramref name="Image"/>
/// kareden kesilen simgenin PNG'si (data: adresi; kesilemediyse null).
/// </summary>
public sealed record IconSlot(TextBox Box, string Text, string? Image = null);

/// <summary>Bir karenin okunan satırları, yukarıdan aşağı (Mac: CouchSubsCore/Reading.swift).</summary>
public sealed class Reading
{
    public static readonly Reading Empty = new([]);

    public Reading(IEnumerable<TextLine> lines) =>
        Lines = [.. lines.Where(line => !string.IsNullOrWhiteSpace(line.Text))];

    public IReadOnlyList<TextLine> Lines { get; }

    /// <summary>Satırları ayrı ayrı bilinmeyen okuyucular için: her satır sonu bir satırdır.</summary>
    public static Reading FromText(string text) =>
        new(text.Replace("\r\n", "\n").Split('\n').Select(line => new TextLine(line.Trim())));

    public string Text => string.Join('\n', Lines.Select(line => line.Text));

    /// <summary>
    /// Aynı satırdaki iki sözcük arasındaki boşluk (piksel) ayrı yazılara mı işaret ediyor? Yalnız hem satır yüksekliğinin
    /// dört katından hem görüntü genişliğinin %12'sinden genişse: soldaki menü ile sağdaki gösterge böyle ayrılır.
    /// Daha dar boşluk çoğunlukla okunamayan sözcüklerdir (açık zemindeki ince altyazıda yazı tanıma bazı sözcükleri
    /// atlar); orada bölmek cümleyi parçalara ayırır, parçanın çevirisi anlamsızlaşır ve kutusu satırı örtmez (GTA V).
    /// </summary>
    public static bool IsSeparateText(double gap, double lineHeight, double imageWidth) =>
        gap > lineHeight * 4 && gap > imageWidth * 0.12;

    /// <summary>Bütün satırları içine alan kutu; hiçbir satırın yeri bilinmiyorsa null.</summary>
    public TextBox? Box
    {
        get
        {
            TextBox? total = null;
            foreach (var line in Lines)
                if (line.Box is { } box) total = total?.Union(box) ?? box;
            return total;
        }
    }

    /// <summary>Satırların ortalama tanıma güveni (0–1); okuyucu güven vermiyorsa null.</summary>
    public double? Confidence =>
        Lines.Where(line => line.Confidence is not null).Select(line => line.Confidence!.Value).ToList() is { Count: > 0 } values
            ? values.Average() : null;

    /// <summary>
    /// Oyunun düğme ipuçları ("R2 Swing", "△ Pick up", "Press @ to open the map") çıkarılmış hali; bunlar altyazı
    /// değildir. Simgesi bulunmuş satır (<see cref="WithButtonIcons"/>; "Ekranı çevir" ve ek alanlar) kalır: simgesiyle
    /// çevrilir, düğme görünür. Simgesi bulunamayan ipucu atılır; çevrilmediği için üstü örtülmez, düğme yine görünür.
    /// </summary>
    public Reading WithoutButtonPrompts() =>
        new(Lines.Where(line => line.Icons is { Count: > 0 } || !ButtonPrompts.IsPrompt(line.Text)));

    /// <summary>
    /// Yazı tanımanın uydurduğu sözcük çöpleri ("ou$3e", "waters2aljd") ayıklanmış hali; çevirmen bunları olduğu
    /// gibi taşıyıp TV'de anlamsız harfler gösteriyordu.
    /// </summary>
    public Reading WithoutOcrNoise() => WithoutOcrNoise(false);
    internal Reading WithoutOcrNoise(bool keepIdentifiers) =>
        new(Lines.Select(line => line with { Text = OcrNoise.Clean(line.Text, keepIdentifiers) }));

    /// <summary>
    /// Aynı satırda yan yana okunan parçalar soldan sağa tek satır olur. Renkli konuşan adını ("Arthur:", RDR2) yazı
    /// tanıma cümleden ayrı okuyabiliyor; parçalar yalnız üst kenarlarına göre dizilince ad cümlenin sonuna düşüyor ya da
    /// ayrı blok sayılıp atılıyordu. Yatayda aralarında en çok <see cref="RowGap"/> (alan genişliğine oranla) olan
    /// parçalar birleşir; uzaktaki köşe yazısı ayrı kalır (Mac: Reading.joiningRows, Android: Reading.joiningRows).
    ///
    /// Tek başına okunan konuşan adı ("Lucia:", <see cref="SpeakerPrefix.NameOnly"/>) cümlesine katılır: aynı satırdaysa
    /// daha gevşek ölçüyle (renkli adın kutusu cümleninkinden kaymış ya da biraz uzak okunabiliyor; <see cref="NameRowOverlap"/>,
    /// <see cref="NameRowGap"/>), cümlenin hemen üstündeyse (<see cref="NameAboveGap"/>) altındaki satırın başına. Kullanıcı
    /// bildirimi (X): konuşan adı diyalogların yalnız ~%20'sinde görünüyordu. Ayrı satır kalan ad, aynı kişi konuşmayı
    /// sürdürdükçe değişmeden durduğu için görev/HUD satırı sayılıp (<see cref="StickyRows"/>) atılıyor, ad yalnız konuşan
    /// değişince görünüyordu; aynı satırda ama ayrı okunan ad ise ayrı blok sayılıp hiç gösterilmiyordu. Yerleri
    /// bilinmeyen satırlarda ad alttaki satıra katılır.
    /// </summary>
    public Reading JoiningRows()
    {
        if (Lines.Count < 2) return this;
        if (Lines.Any(line => line.Box is null)) return JoiningSpeakerNames();
        var rows = new List<TextLine>();
        foreach (var line in Lines.OrderBy(line => line.Box!.Value.Left))
        {
            var box = line.Box!.Value;
            var index = rows.FindIndex(row =>
                SameRow(box, row.Box!.Value) || (SpeakerPrefix.NameOnly(row.Text) is not null && NameRow(box, row.Box!.Value)));
            if (index >= 0)
            {
                var row = rows[index];
                rows[index] = new TextLine(row.Text + " " + line.Text, row.Box!.Value.Union(box), MinConfidence(row, line));
            }
            else
            {
                rows.Add(line);
            }
        }
        return new Reading(rows.OrderBy(row => row.Box!.Value.Top)).JoiningSpeakerNames();
    }

    /// <summary><see cref="JoiningRows"/>: aynı satırdaki iki parça arasındaki en büyük boşluk (alan genişliğine oranla).</summary>
    public const double RowGap = 0.05;
    /// <summary>Tek başına okunan adın sağındaki cümle aynı satırda sayılır: dikeyde küçük yüksekliğin en az bu kadarı örtüşür,</summary>
    public const double NameRowOverlap = 0.3;
    /// <summary>ve aralarındaki boşluk en çok bu kadar (alan genişliğine oranla).</summary>
    public const double NameRowGap = 0.12;
    /// <summary>Tek başına okunan adın altındaki cümle ona aittir: aradaki boşluk en çok satır yüksekliğinin bu katı.</summary>
    public const double NameAboveGap = 1.5;

    private static double? MinConfidence(TextLine a, TextLine b) =>
        a.Confidence is { } x && b.Confidence is { } y ? Math.Min(x, y) : a.Confidence ?? b.Confidence;

    private static bool SameRow(TextBox next, TextBox row)
    {
        var overlap = Math.Min(next.Bottom, row.Bottom) - Math.Max(next.Top, row.Top);
        var smaller = Math.Min(next.Bottom - next.Top, row.Bottom - row.Top);
        if (smaller <= 0 || overlap < smaller * 0.6) return false;
        return next.Left - row.Right <= RowGap;
    }

    /// <summary><paramref name="next"/>, solundaki tek başına ad (<paramref name="name"/>) ile aynı satırda mı.</summary>
    private static bool NameRow(TextBox next, TextBox name)
    {
        var overlap = Math.Min(next.Bottom, name.Bottom) - Math.Max(next.Top, name.Top);
        var smaller = Math.Min(next.Bottom - next.Top, name.Bottom - name.Top);
        if (smaller <= 0 || overlap < smaller * NameRowOverlap) return false;
        return next.Left - name.Right <= NameRowGap;
    }

    /// <summary>
    /// Tek başına okunan ad, altındaki cümle satırının başına katılır (bkz. <see cref="JoiningRows"/>). Satırın kutusu
    /// cümleninkidir, yatayda adı da kapsar: yükseklik cümle satırınınki kalır, blok ayırma ve yazı boyu karşılaştırması bozulmaz.
    /// </summary>
    private Reading JoiningSpeakerNames()
    {
        var result = Lines.ToList();
        var index = 0;
        while (index < result.Count)
        {
            if (SpeakerPrefix.NameOnly(result[index].Text) is not { } name || SentenceBelow(index, result) is not { } partner)
            {
                index++;
                continue;
            }
            var line = result[partner];
            var label = result[index];
            var box = line.Box;
            if (line.Box is { } own && label.Box is { } named)
                box = new TextBox(Math.Min(own.Left, named.Left), own.Top, Math.Max(own.Right, named.Right), own.Bottom);
            result[partner] = new TextLine(name + ": " + line.Text.Trim(), box, MinConfidence(label, line));
            result.RemoveAt(index);
        }
        return result.Count == Lines.Count ? this : new Reading(result);
    }

    /// <summary>
    /// <paramref name="index"/>teki tek başına adın cümlesi: altındaki (üst kenarı adın ortasının altında), aradaki boşluğu
    /// satır yüksekliğinin en çok <see cref="NameAboveGap"/> katı olan, yatayda adla örtüşen en yakın satır. Satır kendisi
    /// adla başlamaz, harf taşır. Yerler bilinmiyorsa hemen sonraki satır.
    /// </summary>
    private static int? SentenceBelow(int index, List<TextLine> lines)
    {
        static bool Sentence(string text) =>
            text.Any(char.IsLetter) && SpeakerPrefix.NameOnly(text) is null && SpeakerPrefix.Parse(text) is null;
        if (lines[index].Box is not { } name)
        {
            var next = index + 1;
            return next < lines.Count && lines[next].Box is null && Sentence(lines[next].Text) ? next : null;
        }
        var height = name.Bottom - name.Top;
        int? best = null;
        for (var other = index + 1; other < lines.Count; other++)
        {
            if (lines[other].Box is not { } box || !Sentence(lines[other].Text)) continue;
            var gap = box.Top - name.Bottom;
            if (box.Top < name.Top + height / 2 || gap > NameAboveGap * Math.Max(height, box.Bottom - box.Top)) continue;
            if (Math.Min(box.Right, name.Right) - Math.Max(box.Left, name.Left) <= 0) continue;
            if (best is null || box.Top < lines[best.Value].Box!.Value.Top) best = other;
        }
        return best;
    }

    /// <summary>
    /// Alandaki altyazı bloğu. Seçilen alanda altyazının yanında menü ("MAP / HELP / SETTINGS" alt alta), köşedeki
    /// gösterge ("9", "PHOTO MODE") da okunuyordu; hepsi tek cümle gibi çevrilip TV'de bütün alanı kaplayan kutuyla
    /// gösteriliyordu. Satırlar yerlerine göre bloklara ayrılır; ortalanmış ve menü olmayan en alttaki blok altyazıdır.
    /// Ortalanmış blok yoksa en az üç sözcüklü, menü olmayan en alttaki blok alınır. Satırların yeri bilinmiyorsa
    /// okuma olduğu gibi kalır. <paramref name="area"/>, okunan alanın karedeki yeridir (Mac: Reading.subtitleBlock).
    /// Tek satırlık etkileşim/HUD etiketi ("TAKE AMMO PACK (0/3)", <see cref="ButtonPrompts.IsActionLabel"/>) ve sahne
    /// yazısı (tabela, tişört; <see cref="SceneText"/>) altyazı bloğu sayılmaz. <paramref name="band"/>: bu oturumda
    /// altyazının okunduğu yükseklikler; <paramref name="dropped"/>: sahne yazısı sayılıp atılan her blok ve nedeni
    /// (altyazı günlüğü için). "Tam ekran" alanda ekranın kenarındaki bildirim kartı (<see cref="ScreenNotices.IsNotice(TextBox)"/>)
    /// altyazı bloğu sayılmaz, <paramref name="notices"/> ile bildirilir (satır kutuları alana oranlı); kendi yerinde
    /// çevrilir. Önceden ortalanmış blok yokken altyazı seçilip ekranın ortasında çiziliyordu. <paramref name="age"/>:
    /// satırın ne kadar süredir değişmeden okunduğu (<see cref="StickyRows.UnchangedMs"/>); verilirse
    /// <see cref="StaleMs"/>'dir değişmeyen ortalı blok, yanında yeni beliren ortalı blok varken seçilmez, atlanan blok
    /// <paramref name="stale"/> ile bildirilir. <paramref name="darkInk"/>: satır kutusu açık zeminde koyu yazı mı
    /// (<see cref="InkTone.Sampler"/>; kâğıt ilan sahne yazısıdır, GitHub #1124); verilmezse renge bakılmaz.
    /// </summary>
    public Reading SubtitleBlock(TextBox area, SubtitleBand? band = null, Action<Reading, string>? dropped = null,
                                 Action<Reading>? notices = null, Func<string, long?>? age = null,
                                 Action<Reading>? stale = null, Func<TextBox, bool>? darkInk = null)
    {
        if (Lines.Count == 0 || Lines.Any(line => line.Box is null)) return IsActionLabel ? Empty : this;
        // Menünün konuşma/yardım geçmişi listesi (IsHistoryList) altyazı değildir: hiçbir satırı altyazı seçilmez.
        if (IsHistoryList)
        {
            dropped?.Invoke(this, ListReason);
            return Empty;
        }
        var blocks = new List<List<TextLine>>();
        foreach (var line in Lines.OrderBy(line => line.Box!.Value.Top))
        {
            var box = line.Box!.Value.PlacedIn(area);
            var index = blocks.FindLastIndex(block => Belongs(box, block, area, line.Text));
            if (index >= 0) blocks[index].Add(line);
            else blocks.Add([line]);
        }
        // Tabela, tişört, plaka gibi sahne yazısı (SceneText) altyazı alanına düşse de altyazı değildir.
        var candidates = blocks.SelectMany(WithoutSignLines).Select(block => new Reading(block)).Where(reading =>
        {
            if (reading.IsMenu || reading.IsActionLabel) return false;
            if (SceneText.Reason(reading, area, band, darkInk) is not { } reason) return true;
            dropped?.Invoke(reading, reason);
            return false;
        }).Where(reading =>
        {
            if (!ScreenNotices.IsWholeScreen(area) || !ScreenNotices.IsNotice(reading.Box!.Value.PlacedIn(area))) return true;
            notices?.Invoke(reading);
            return false;
        }).ToList();
        var centered = candidates.Where(reading =>
        {
            var box = reading.Box!.Value.PlacedIn(area);
            return Math.Abs(((box.Left + box.Right) / 2) - 0.5) <= 0.12;
        }).ToList();
        // Görev satırı altyazıyla aynı anda belirince ayrı blok olur (aralık ya da yazı boyu farkı): konuşan adı taşıyan
        // blok altyazıdır ("Lucia: …" görevin üstünde de dursa).
        centered = WithoutStale(centered, age, stale);
        // Aynı anda konuşan kişilerin alt alta duran ayrı blokları (SpokenTogether) tek altyazıda, her biri kendi satırında.
        if (centered.FirstOrDefault(IsSpoken) is { } spoken) return SpokenTogether(spoken, centered, area);
        if (centered.Count > 0)
        {
            var lowest = centered.MaxBy(reading => reading.Box!.Value.Bottom)!;
            return ObjectiveBelow(lowest, centered, area) ?? lowest;
        }
        return candidates.Where(reading => WordCount(reading.Text) >= 3).MaxBy(reading => reading.Box!.Value.Bottom) ?? Empty;
    }

    /// <summary>
    /// En alttaki blok, hemen üstündeki konuşmanın altına onunla aynı anda gelen görev satırı mı: tek satır ve üstündeki
    /// ortalanmış bloktan (arada en çok üç satır boyu) belirgin kısa (<see cref="StickyRows.JoinedShare"/>). Öyleyse
    /// altyazı üstteki bloktur. Kullanıcı bildirimi (X, beta.69, GTA 6): "John'u takip et" konuşmayla birlikte belirince
    /// en alttaki blok olarak altyazı seçiliyor, konuşma hiç çevrilmiyordu. Görev ekranda kalınca sonraki konuşmalarda
    /// <see cref="StickyRows"/> onu ayırır.
    /// </summary>
    private static Reading? ObjectiveBelow(Reading lowest, List<Reading> centered, TextBox area)
    {
        if (lowest.Lines.Count != 1) return null;
        var box = lowest.Box!.Value.PlacedIn(area);
        var height = box.Bottom - box.Top;
        var above = centered.Where(reading => !ReferenceEquals(reading, lowest))
            .Where(reading => reading.Box!.Value.PlacedIn(area) is var other && other.Bottom <= box.Top + height * 0.25
                              && box.Top - other.Bottom <= height * 3)
            .MaxBy(reading => reading.Box!.Value.Bottom);
        if (above is null) return null;
        // Görev yazısı konuşmadan belirgin küçük yazıyla (IsSmallerObjective): konuşma kısa olsa da ("Okay.") altyazı
        // üstteki bloktur; görev uzun diye konuşmayı yutmaz.
        if (above.Lines[^1].Box is { } upperBox && upperBox.PlacedIn(area) is var upper
            && IsSmallerObjective(lowest.Text, height, upper.Bottom - upper.Top, above.Lines[^1].Text)) return above;
        return Letters(lowest.Text) <= StickyRows.JoinedShare * Letters(above.Text) ? above : null;
    }

    /// <summary>
    /// Konuşma satırı, altındaki görev/hedef satırının yazısından en az bu kat büyükse görev ayrı bloktur
    /// (<see cref="IsSmallerObjective"/>). Büyük harfle başlayan kuyruksuz kısa satırın ("Go on.") kutusu en çok ~1,45 kat
    /// alçak çıkar; GTA 6 ve RDR2'nin görev yazısı konuşmanın yarısından da küçüktür (Mac/Android: aynı eşik).
    /// </summary>
    internal const double ObjectiveScale = 1.6;

    /// <summary>
    /// <paramref name="text"/> satırı, üstündeki konuşma satırının (yüksekliği <paramref name="upper"/>) altında duran
    /// görev/hedef yazısı mı: konuşan adı taşımıyor, büyük harfle başlıyor, ikisi de küçük harf taşıyor (BÜYÜK HARFLİ
    /// tabela satırları bölünmez) ve yazısı konuşmanınkinden en az
    /// <see cref="ObjectiveScale"/> kat küçük. Kullanıcı bildirimi (beta.100, GTA 6): kısa görev yazısı (en çok üç sözcük)
    /// konuşmanın devamı sayılıp yazı boyu karşılaştırılmıyor, "Come on Lose the cops" diye tek altyazı çevriliyordu.
    /// Küçük harfle başlayan devam satırı ("now.") bu kurala girmez (GitHub #715; Mac/Android: aynı kural).
    /// </summary>
    internal static bool IsSmallerObjective(string text, double height, double upper, string spoken)
    {
        if (height <= 0 || SpeakerPrefix.Parse(text) is not null || !text.Any(char.IsLower) || !spoken.Any(char.IsLower))
            return false;
        var first = text.FirstOrDefault(char.IsLetter);
        return first != default && char.IsUpper(first) && upper >= ObjectiveScale * height;
    }

    private static int Letters(string text) => text.Count(char.IsLetter);

    /// <summary>
    /// Konuşmayla aynı bloğa düşen plaka/tabela satırları ayrı blok olur (sonra <see cref="SceneText"/> ya da
    /// <see cref="IsActionLabel"/> ile atılır). Kullanıcı bildirimi (GitHub #1052, GTA 6, beta.84): plaka konuşmanın hemen
    /// üstünde durunca aynı bloğa katılıyor, "FLORIANA / Dunk: Yo. How you know that was me?" diye çevriliyor, plaka
    /// okundukça aynı replik yeniden işleniyordu. Ayrılan: konuşan adlı satırın üstündeki kısa büyük harfli satırlar
    /// (<see cref="SceneText.IsSignLine"/>; konuşan adı yeni konuşmanın ilk satırıdır) ve küçük harfli konuşmanın altında,
    /// cümlenin devamı olmayan, rakam taşıyan kısa büyük harfli satır ("AKB 51"). Tümü büyük harfli altyazının devamı
    /// ("LUCIA: GET / DOWN!", "I'm with the / FBI.") ayrılmaz (Mac: Reading.withoutSignLines, Android: Reading.withoutSignLines).
    /// </summary>
    internal static List<List<TextLine>> WithoutSignLines(List<TextLine> block)
    {
        var speaker = Enumerable.Range(1, Math.Max(0, block.Count - 1))
            .FirstOrDefault(i => SpeakerPrefix.Parse(block[i].Text) is not null, -1);
        if (speaker > 0 && block.Take(speaker).All(line => SceneText.IsSignLine(line.Text)))
            return [block.Take(speaker).ToList(), .. WithoutSignLines(block.Skip(speaker).ToList())];
        if (block.Count < 2 || SpeakerPrefix.Parse(block[0].Text) is null || !block[0].Text.Any(char.IsLower)) return [block];
        var cut = Enumerable.Range(1, block.Count - 1).FirstOrDefault(i =>
            SceneText.IsSignLine(block[i].Text) && block[i].Text.Any(char.IsDigit) && !Continues(block[i - 1].Text, block[i].Text), -1);
        return cut > 0 ? [block.Take(cut).ToList(), block.Skip(cut).ToList()] : [block];
    }

    /// <summary>
    /// Ortalı blok bu kadar süredir hiç değişmediyse ve yanında ondan en az <see cref="StickyRows.YoungerByMs"/> daha yeni
    /// (kırıntı olmayan) ortalı blok varsa altyazı sayılmaz. Kullanıcı bildirimi (GitHub #933, GTA 6): karakter TV izlerken
    /// haber programının alt bandı konuşma altyazısının altında duruyor, en alttaki ortalı blok olarak her karede bant
    /// seçiliyor, konuşma hiç çevrilmiyordu. Bant çoğu zaman "EXCLUSIVE: …", "BREAKING NEWS: …" diye başlıyor, konuşan adı
    /// sanılıp her zaman altyazı seçiliyordu. Tek ortalı blok (değişmeyen uzun cümle) seçilmeye devam eder. Konuşan adlı
    /// sabit blok yalnız yanındaki yeni blok en az üç sözcüklü bir cümleyse atlanır: kısa görev/HUD yazısı uzun konuşmayı
    /// geçmez (Mac: Reading.staleMs, Android: Reading.STALE_MS).
    /// </summary>
    public const int StaleMs = 5000;

    /// <summary>Ortalı blokların sabit olanları (<see cref="StaleMs"/>) çıkarılmış hali; satır yaşı bilinmiyorsa aynen kalır.</summary>
    private static List<Reading> WithoutStale(List<Reading> centered, Func<string, long?>? age, Action<Reading>? skipped)
    {
        if (age is null || centered.Count < 2) return centered;
        var ages = centered.Select(block => block.Lines.Select(line => age(line.Text)).Where(value => value is not null)
            .Select(value => value!.Value).DefaultIfEmpty(0).Min()).ToList();
        var fresh = Enumerable.Range(0, centered.Count)
            .Where(i => ages[i] < StaleMs && !OcrNoise.IsCrumb(centered[i].Text)).ToList();
        if (fresh.Count == 0) return centered;
        long youngest = fresh.Min(i => ages[i]);
        var sentences = fresh.Where(i => WordCount(centered[i].Text) >= 3).ToList();
        long? sentence = sentences.Count > 0 ? sentences.Min(i => ages[i]) : null;
        var stale = Enumerable.Range(0, centered.Count).Where(i =>
        {
            if (ages[i] < StaleMs) return false;
            var rival = SpeakerPrefix.Parse(centered[i].Lines[0].Text) is null ? youngest : sentence;
            return rival is { } value && ages[i] - value >= StickyRows.YoungerByMs;
        }).ToHashSet();
        if (stale.Count == 0) return centered;
        foreach (var i in stale.Order()) skipped?.Invoke(centered[i]);
        return Enumerable.Range(0, centered.Count).Where(i => !stale.Contains(i)).Select(i => centered[i]).ToList();
    }

    /// <summary>
    /// Bloğun son satırının hemen altında ve yatayda onunla üst üste binen satır o bloğa aittir. Aradaki boşluk satır
    /// yüksekliğinin LineGap katından (devam satırında ContinuationGap) büyükse ya da yazı boyları 1,25 kattan çok farklıysa ayrı bloktur (altyazıya bitişik görev
    /// satırı ayrılır). Yazı boyu yalnız iki satır da en az üç sözcükken karşılaştırılır ve alttaki satır üsttekinin
    /// devamıysa (<see cref="Continues"/>) hiç karşılaştırılmaz: satır kutusu harflere göre ölçülür, "now." gibi kısa ve
    /// büyük harfsiz/kuyruksuz satırın kutusu daha alçak çıkıyor, cümlenin devamı ayrı blok sayılıp tek başına
    /// çevriliyordu (GitHub #715).
    /// </summary>
    /// <summary>
    /// Aynı bloğun satırları arasındaki en büyük boşluk (satır yüksekliğine oranla). GTA 6 gibi geniş satır aralıklı
    /// altyazılarda 0,6 eşiği iki satırlı altyazıyı iki bloğa bölüyor, yalnız biri çevriliyordu (GitHub #822); 0,8 geri geldi.
    /// Alttaki satır üsttekinin devamıysa <see cref="ContinuationGap"/> geçerlidir (Mac/Android: aynı eşikler).
    /// </summary>
    internal const double LineGap = 0.8;
    internal const double ContinuationGap = 1.3;
    /// <summary>
    /// <see cref="ContinuationGap"/> yalnız üstteki satır en az bu kadar sözcükken geçerlidir: altyazının sarılmış ilk satırı
    /// uzundur. Tek sözcüklük üst satır (GTA 6 telefon bildiriminde gönderenin adı "Cal", altında "Checked th…") geniş
    /// boşlukla alttakine katılınca altyazı seçiliyordu (gerçek kare gta6-n4-bildirim; Mac/Android: aynı eşik).
    /// </summary>
    internal const int ContinuationMinWords = 3;

    private static bool Belongs(TextBox box, List<TextLine> block, TextBox area, string text)
    {
        var last = block[^1].Box!.Value.PlacedIn(area);
        double own = box.Bottom - box.Top, previous = last.Bottom - last.Top;
        var height = Math.Max(own, previous);
        // Konuşmanın altındaki küçük görev yazısı devam satırı sayılmaz (IsSmallerObjective).
        if (IsSmallerObjective(text, own, previous, block[^1].Text)) return false;
        var continuing = Continues(block[^1].Text, text);
        var wide = continuing && WordCount(block[^1].Text) >= ContinuationMinWords;
        if (box.Top - last.Bottom > height * (wide ? ContinuationGap : LineGap) || box.Top < last.Top) return false;
        var comparable = WordCount(text) >= 3 && WordCount(block[^1].Text) >= 3 && !continuing;
        if (comparable && Math.Max(own, previous) > 1.25 * Math.Min(own, previous)) return false;
        var overlap = Math.Min(box.Right, last.Right) - Math.Max(box.Left, last.Left);
        var narrower = Math.Min(box.Right - box.Left, last.Right - last.Left);
        return overlap > 0 && overlap >= narrower * 0.5;
    }

    /// <summary>
    /// <paramref name="next"/> satırı <paramref name="upper"/>'ın devamı mı: üstteki cümle bitmemiş (nokta, ünlem, soru
    /// işaretiyle bitmiyor) ve alttaki küçük harfle başlıyor ya da üstteki virgül/tireyle bitiyor ya da alttaki en çok üç
    /// sözcük. Konuşan adlı alt satır ("Lucia: …") yeni konuşmadır, devam sayılmaz (Mac/Android: aynı kural).
    /// </summary>
    internal static bool Continues(string upper, string next)
    {
        var top = upper.Trim();
        var below = next.Trim();
        if (top.Length == 0 || below.Length == 0 || SubtitleStabilizer.EndsSentence(top)) return false;
        if (SpeakerPrefix.Parse(below) is not null) return false;
        var first = below.FirstOrDefault(char.IsLetter);
        return (first != default && char.IsLower(first)) || top.EndsWith(',') || top.EndsWith('-') || top.EndsWith('—')
               || WordCount(below) <= 3;
    }

    /// <summary>Alt alta kısa ve noktalamasız satırlar ("MAP", "HELP", "SOCIAL CLUB") menüdür, konuşma değil.</summary>
    /// <remarks>
    /// Satırların yeri biliniyorsa sol ya da sağ kenarları <see cref="MenuEdge"/> içinde hizalı olmalı: ortalanmış kısa
    /// konuşma satırları ("No / Wait / Go on") menü sanılıp atılmasın. Konuşan adıyla başlayan satır menü değildir
    /// (Mac/iPhone, Android ile aynı).
    /// </remarks>
    internal bool IsMenu
    {
        get
        {
            if (Lines.Count < 3 || !Lines.All(line => WordCount(line.Text) <= 3 && !SubtitleStabilizer.EndsSentence(line.Text)
                                                      && SpeakerPrefix.Parse(line.Text) is null)) return false;
            if (Lines.Any(line => line.Box is null)) return true;
            static bool Aligned(IEnumerable<double> edges) => edges.Max() - edges.Min() <= MenuEdge;
            return Aligned(Lines.Select(line => line.Box!.Value.Left)) || Aligned(Lines.Select(line => line.Box!.Value.Right));
        }
    }

    /// <summary>Menü satırlarının sol ya da sağ kenarı bu kadar içinde hizalı (okunan alana oranla).</summary>
    internal const double MenuEdge = 0.012;

    /// <summary>Menü listesi sayılıp atılan okumanın günlük nedeni (<see cref="IsHistoryList"/>).</summary>
    public const string ListReason = "menü listesi (eşit aralıklı satırlar), altyazı değil";
    /// <summary>Liste satırlarının aralığı satır yüksekliğinin en az bu katı (altyazının satırları bitişiktir).</summary>
    internal const double ListPitch = 1.8;
    /// <summary>Aralık bundan büyükse ayrı yazılardır.</summary>
    internal const double ListMaxPitch = 4.0;
    /// <summary>Ardışık aralıklar en çok bu oranda farklı.</summary>
    internal const double ListSpread = 1.3;

    /// <summary>
    /// Okuma menünün geçmiş listesi mi (GTA 6 duraklatma menüsü "Map Özeti": diyalog/yardım/görev geçmişi). Sinan Bey
    /// beta.100 (3380-3383): listenin konuşan adlı satırlarından biri her karede altyazı sanılıp altta siyah kutuda
    /// gösteriliyor, konuşan adı yüzünden menü durumu da bitiyordu (#1240). Liste: yatayda üst üste duran (aynı sütun),
    /// aralarında boşluk olan (<see cref="ListPitch"/>..<see cref="ListMaxPitch"/> satır boyu) ve eşit aralıklı
    /// (<see cref="ListSpread"/>) en az üç satır; ya da konuşan adıyla başlayan, sol kenarları hizalı
    /// (<see cref="MenuEdge"/>) iki satır (Mac/iPhone: Reading.isHistoryList, Android: Reading.isHistoryList).
    /// </summary>
    public bool IsHistoryList
    {
        get
        {
            var rows = Lines.Where(line => line.Box is not null && line.Text.Any(char.IsLetter))
                .OrderBy(line => line.Box!.Value.Top).ToList();
            if (rows.Count < 2) return false;
            var heights = rows.Select(line => line.Box!.Value.Bottom - line.Box!.Value.Top).OrderBy(h => h).ToList();
            var height = heights[heights.Count / 2];
            if (height <= 0) return false;
            static bool Column(TextBox a, TextBox b)
            {
                var overlap = Math.Min(a.Right, b.Right) - Math.Max(a.Left, b.Left);
                return overlap > 0 && overlap >= 0.5 * Math.Min(a.Right - a.Left, b.Right - b.Left);
            }
            for (var start = 0; start < rows.Count; start++)
            {
                var run = new List<int> { start };
                double? first = null;
                while (true)
                {
                    var current = run[^1];
                    var next = -1;
                    for (var j = current + 1; j < rows.Count; j++)
                        if (Column(rows[current].Box!.Value, rows[j].Box!.Value)) { next = j; break; }
                    if (next < 0) break;
                    var pitch = rows[next].Box!.Value.Top - rows[current].Box!.Value.Top;
                    if (pitch < ListPitch * height || pitch > ListMaxPitch * height) break;
                    if (first is { } f && Math.Max(pitch, f) > ListSpread * Math.Min(pitch, f)) break;
                    first ??= pitch;
                    run.Add(next);
                }
                if (run.Count >= 3 && !CenteredSpeech(run.Select(index => rows[index].Box!.Value).ToList())) return true;
                if (run.Count == 2 && run.All(index => SpeakerPrefix.Parse(rows[index].Text) is not null)
                    && Math.Abs(rows[run[0]].Box!.Value.Left - rows[run[1]].Box!.Value.Left) <= MenuEdge) return true;
            }
            return false;
        }
    }

    /// <summary>
    /// Satırlar ortaya hizalı ve boyları farklı mı (sol kenarları hizasız, ortaları hizalı): aynı anda konuşan kişilerin
    /// ayrı altyazı blokları böyle durur (X, beta.100, GTA 6 kalabalık sahne). Menünün geçmiş listesi sola yaslıdır; üç
    /// eşit aralıklı ortalı konuşma satırı liste sayılıp altyazının tamamı atılıyordu (Mac/iPhone ve Android aynı).
    /// </summary>
    internal static bool CenteredSpeech(IReadOnlyList<TextBox> boxes)
    {
        var lefts = boxes.Select(box => box.Left).ToList();
        var centers = boxes.Select(box => (box.Left + box.Right) / 2).ToList();
        return lefts.Max() - lefts.Min() > MenuEdge * 2 && centers.Max() - centers.Min() <= MenuEdge * 2;
    }

    private static bool IsSpoken(Reading block) => SpeakerPrefix.Parse(block.Lines[0].Text) is not null;

    /// <summary>Ayrı konuşma blokları arasındaki en büyük boşluk (satır yüksekliğine oranla).</summary>
    internal const double TogetherGap = 3.0;

    /// <summary>
    /// Kalabalık sahnede birden çok kişi aynı anda konuşur (GTA 6 yan konuşmaları; X, beta.100): ekranda alt alta, her biri
    /// konuşan adıyla başlayan 2–3 ayrı blok durur. Önceden yalnız en üstteki seçiliyor, öbürleri atılıyordu. Adla başlayan
    /// ilk bloğun altındaki, yine adla başlayan, aynı yazı boyundaki (1,25 kat) ve arası en çok <see cref="TogetherGap"/>
    /// satır boyu olan bloklar yukarıdan aşağı tek altyazıda birleşir: her konuşan kendi satırında, adıyla. Arada adsız blok
    /// (görev satırı) varsa birleştirme orada durur. Mac/iPhone (Reading.spokenTogether) ve Android (spokenTogether) aynı.
    /// </summary>
    private static Reading SpokenTogether(Reading first, List<Reading> centered, TextBox area)
    {
        var ordered = centered.OrderBy(reading => reading.Box!.Value.Top).ToList();
        var start = ordered.FindIndex(reading => ReferenceEquals(reading, first));
        if (start < 0) return first;
        var lines = first.Lines.ToList();
        foreach (var block in ordered.Skip(start + 1))
        {
            if (!IsSpoken(block) || lines[^1].Box is not { } upperBox || block.Lines[0].Box is not { } lowerBox) break;
            var upper = upperBox.PlacedIn(area);
            var lower = lowerBox.PlacedIn(area);
            double own = lower.Bottom - lower.Top, previous = upper.Bottom - upper.Top;
            if (own <= 0 || previous <= 0 || Math.Max(own, previous) > 1.25 * Math.Min(own, previous)
                || lower.Top < upper.Bottom - Math.Min(own, previous) * 0.25
                || lower.Top - upper.Bottom > Math.Max(own, previous) * TogetherGap) break;
            lines.AddRange(block.Lines);
        }
        return lines.Count == first.Lines.Count ? first : new Reading(lines);
    }

    /// <summary>Tek başına okunan etkileşim/HUD etiketi (GTA 6: "SIT", "• ADD TO TRUNK").</summary>
    internal bool IsActionLabel => Lines.Count == 1 && ButtonPrompts.IsActionLabel(Lines[0].Text);

    private static int WordCount(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    /// <summary>Satır kutularını <paramref name="area"/> içindeki oranlardan dış çerçevenin oranlarına taşır.</summary>
    public Reading PlacedIn(TextBox area) => new(Lines.Select(line => line with
    {
        Box = line.Box?.PlacedIn(area),
        Words = line.Words?.Select(word => word with { Box = word.Box.PlacedIn(area) }).ToList(),
        Icons = line.Icons?.Select(icon => icon with { Box = icon.Box.PlacedIn(area) }).ToList(),
    }));

    /// <summary>Yazının içindeki kumanda simgeleri <see cref="ButtonIcons.Marker"/> ile işaretlenmiş hali (bkz. <see cref="ButtonIcons.Mark"/>).</summary>
    public Reading WithButtonIcons() => new(ButtonIcons.JoinHints(this).Lines.Select(ButtonIcons.Mark));

    /// <summary>
    /// <see cref="WithButtonIcons()"/>, ayrıca fiilsiz yerlerdeki simgeler (tuş çubuğu, satır başı) <paramref name="frame"/>'den
    /// (okunan görüntü) doğrulanarak işaretlenir (<see cref="ButtonIcons.MarkFree"/>).
    /// </summary>
    /// <param name="monochrome">Yalnız renksiz simgeler (otomatik ekran yazısı; bkz. <see cref="ButtonIcons.MarkFree"/>).</param>
    public Reading WithButtonIcons(Frame frame, bool monochrome = false) =>
        new(ButtonIcons.JoinHints(this).Lines.Select(ButtonIcons.Mark).Select(line => ButtonIcons.MarkFree(line, frame, monochrome)));
}

/// <summary>
/// Oyunların ekranda gösterdiği kumanda ipuçlarını tanır: "R2 Swing", "L1 + R1 Spartan Rage", "△ Pick up",
/// "Press ✕ to jump". Konuşma satırları dokunulmadan kalır (Mac'teki ButtonPrompts ile aynı kurallar).
/// </summary>
public static class ButtonPrompts
{
    /// <summary>Her zaman kumanda düğmesi olan simgeler ve adlar (yazı tanıma bazen köşeli parantezle okur).</summary>
    private static readonly HashSet<string> Buttons = new(StringComparer.OrdinalIgnoreCase)
    {
        "R1", "R2", "R3", "L1", "L2", "L3", "OPTIONS", "TOUCHPAD",
        "✕", "×", "⨯", "✖", "○", "◯", "●", "□", "▢", "◻", "■", "△", "▲", "Δ", "⨂",
    };

    /// <summary>Yalnız ayraçtan oluşan sözcük okunmuş simgedir: □ "[]", ○ "()".</summary>
    private static readonly Dictionary<string, string> BracketIcons = new(StringComparer.Ordinal) { ["[]"] = "□", ["()"] = "○" };

    /// <summary>Simge yazı tanımada harfe dönüşebilir; yalnız ipucu kalıbında düğme sayılır.</summary>
    private static readonly HashSet<string> Lookalikes = new(StringComparer.Ordinal) { "X", "O" };

    private static readonly HashSet<string> Verbs = new(StringComparer.OrdinalIgnoreCase)
    {
        "press", "hold", "tap", "push", "use", "mash", "release",
    };

    private static readonly char[] Separators = [' ', '\t', '+', '/'];
    private static readonly char[] Brackets = ['(', ')', '[', ']', '{', '}', '<', '>', '「', '」'];

    public static bool IsPrompt(string line)
    {
        var tokens = line.Split(Separators, StringSplitOptions.RemoveEmptyEntries)
            .Select(token => BracketIcons.TryGetValue(token, out var icon) ? icon : token.Trim(Brackets))
            .Where(token => token.Length > 0)
            .ToList();
        if (tokens.Count == 0) return false;
        var first = tokens[0];
        var words = tokens.Count(token => !Buttons.Contains(token) && token.Any(char.IsLetter));

        // "R2 Swing", "△ Pick up", "L1 R1 Spartan Rage"
        if (Buttons.Contains(first)) return words <= 5;
        // "PHOTO MODE L1 + R1": düğme sonda, önünde kısa ve noktalamasız bir eylem adı.
        if (Buttons.Contains(tokens[^1]) && words <= 4 && !SubtitleStabilizer.EndsSentence(line)) return true;
        // "X Interact", "O Back": ardından kısa, büyük harfle başlayan, noktalamasız bir eylem gelir.
        if (Lookalikes.Contains(first) && tokens.Count is >= 2 and <= 4 && char.IsUpper(tokens[1][0]) &&
            !SubtitleStabilizer.EndsSentence(line))
            return true;
        // "A Turn Off": △ "A" diye okunur (#1203). Artikel "A" ile karışmasın diye ardındaki bütün sözcükler büyük harfle
        // başlamalı ("A little help" konuşmadır); BÜYÜK HARFLİ satır ("A LIBERTY CITY MEMOIR" kitap adı) ipucu değildir.
        if (first == "A" && tokens.Count is >= 2 and <= 4 && !SubtitleStabilizer.EndsSentence(line) &&
            tokens.Skip(1).All(token => char.IsUpper(token[0])) && line.Any(char.IsLower))
            return true;
        // "Press ✕ to jump", "Hold R2 to aim"
        if (Verbs.Contains(first) && tokens.Count is >= 2 and <= 10 &&
            (Buttons.Contains(tokens[1]) || Lookalikes.Contains(tokens[1])))
            return true;
        return IsIconPrompt(tokens, line);
    }

    private static readonly HashSet<string> Connectors = new(StringComparer.OrdinalIgnoreCase) { "and", "or" };

    /// <summary>Büyük harfle yazılmış kısa İngilizce sözcükler tuş kalıntısı sayılmaz ("HOLD ON TO IT").</summary>
    private static readonly HashSet<string> ShortWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "on", "up", "it", "in", "at", "out", "off", "me", "us", "him", "her", "my", "an", "the", "you", "its",
    };

    /// <summary>"to"dan sonra eylem yerine bunlar gelirse konuşmadır ("Hold to your course").</summary>
    private static readonly HashSet<string> Objects = new(StringComparer.OrdinalIgnoreCase)
    {
        "the", "a", "an", "my", "your", "his", "her", "our", "their", "me", "you", "him", "them", "us", "it", "this", "that",
    };

    /// <summary>
    /// Tuş simgesinin yazı tanımadaki kalıntısı: harfsiz ("@", "•", "9"), tek karakter ("D", "i"; "a" hariç), tuş adı,
    /// "and"/"or" ya da büyük harf içeren en çok üç karakter ("LI", "RE", "Rd", "RB").
    /// </summary>
    private static bool IsIconRemnant(string token)
    {
        if (!token.Any(char.IsLetter) || Buttons.Contains(token) || Lookalikes.Contains(token) || Connectors.Contains(token))
            return true;
        if (token.Length == 1) return token != "a";
        return token.Length <= 3 && token.Any(char.IsUpper) && !ShortWords.Contains(token);
    }

    /// <summary>
    /// GTA 6: "Press/Hold/Use ... to ..." ipucunda tuş simgesi resimdir; yazı tanıma onu ya hiç okumaz ("Press  to open
    /// the map") ya da harf/simge kalıntısı olarak okur ("Press @ to", "Hold I LI to", "Press [RB] to take cover").
    /// Çevrilince tuş kaybolur ve konuşma yerine ipucu görünür. Fiil ile "to" arasında en çok üç kalıntı olabilir;
    /// ünlem, soru, tırnak ya da konuşmacı adı (":") taşıyan satır ve "to"dan sonra eylem yerine nesne gelen satır
    /// ("Hold to your course") konuşma sayılır (Mac: ButtonPrompts.isIconPrompt, Android: isIconPrompt, havuz:
    /// server/pool/src/prompts.js).
    /// </summary>
    private static bool IsIconPrompt(List<string> tokens, string line)
    {
        if (line.Any(c => "!?\"“”:".Contains(c))) return false;
        var all = tokens.SkipWhile(token => !token.Any(char.IsLetter)).ToList();
        if (all.Count < 3 || !Verbs.Contains(all[0])) return false;
        var to = all.FindIndex(1, token => token.Equals("to", StringComparison.OrdinalIgnoreCase));
        if (to < 1 || to > 4 || !all.Skip(1).Take(to - 1).All(IsIconRemnant)) return false;
        var next = all.Skip(to + 1).FirstOrDefault(token => token.Any(char.IsLetter));
        return next is not null && all.Count - to - 1 <= 10 && !Objects.Contains(next);
    }

    /// <summary>
    /// <see cref="IsIconPrompt"/> kalıbındaki satırın yazı tanıma sözcüklerinde fiilin ve "to"nun sırası; aralarında en
    /// az bir tuş kalıntısı yoksa ya da kalıp tutmazsa null. Aradaki kalıntılar ("I LI", "(9 0", "2 and R2") simgenin
    /// okunuşudur: <see cref="ButtonIcons.Mark"/> onları kareden kesilecek simge yapar ("Ekranı çevir" ve ek alanlarda
    /// ipucu simgesiyle çevrilir; ana altyazıda ipucu yine atılır).
    /// </summary>
    internal static (int Verb, int To)? IconRemnantSpan(IReadOnlyList<string> words, string line)
    {
        var tokens = line.Split(Separators, StringSplitOptions.RemoveEmptyEntries)
            .Select(token => token.Trim(Brackets)).Where(token => token.Length > 0).ToList();
        if (!IsIconPrompt(tokens, line)) return null;
        var verb = -1;
        for (var i = 0; i < words.Count && verb < 0; i++)
            if (words[i].Trim(Brackets).Any(char.IsLetter)) verb = i;
        if (verb < 0 || !Verbs.Contains(words[verb].Trim(Brackets))) return null;
        for (var to = verb + 2; to < words.Count && to <= verb + 4; to++)
        {
            if (!words[to].Trim(Brackets).Equals("to", StringComparison.OrdinalIgnoreCase)) continue;
            var between = words.Skip(verb + 1).Take(to - verb - 1)
                .SelectMany(word => word.Split(Separators, StringSplitOptions.RemoveEmptyEntries).Select(part => part.Trim(Brackets)))
                .Where(part => part.Length > 0);
            return between.All(IsIconRemnant) ? (verb, to) : null;
        }
        return null;
    }

    /// <summary>"and"/"or": iki tuş kalıntısının arasındaki bağlaç, simge değildir ("Release 2 and R2 to breathe out").</summary>
    internal static bool IsConnector(string token) => Connectors.Contains(token);

    /// <summary>
    /// Etkileşim/HUD etiketi: en çok üç sözcük, hiç küçük harf yok (en az bir büyük harf var), cümle sonu noktalaması
    /// yok. GTA 6'nın etkileşim yazıları ("TAKE AMMO PACK (0/3)", "• ADD TO TRUNK", "TURN ON") ve ekipman yazıları
    /// ("BENCH PRESS") simgeleri harfe dönüşerek okunuyor, altyazı gibi çevriliyordu (#404). Konuşma altyazısı küçük
    /// harf içerir ya da noktalamayla biter ("Yes.", "OKAY.", "WHAT?"); büyük/küçük harfi olmayan yazılara
    /// (Japonca) dokunulmaz. Yalnız tek başına okunan satıra uygulanır: tümü büyük harfli altyazının sarılmış
    /// satırı ("I TOLD YOU" / "NOT TO GO THERE.") bozulmaz (Mac: ButtonPrompts.isActionLabel).
    /// </summary>
    public static bool IsActionLabel(string line)
    {
        var words = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(word => word.Any(char.IsLetter));
        return words is >= 1 and <= 3 && line.Any(char.IsUpper) && !line.Any(char.IsLower) &&
            !SubtitleStabilizer.EndsSentence(line);
    }
}
