// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// "Ekranı çevir": karenin tamamı bir kez okunur, yazılar yerlerine göre gruplara ayrılır (menü, görev paneli, bilgi
/// kutusu, altyazı...) ve her grup ayrı çevrilir. TV her çeviriyi kendi İngilizce yazısının üstüne, o yazının
/// boyutunda koyar. Sürekli çalışmaz; kullanıcı tuşa basınca bir kez yapılır (Mac: CouchSubsCore/ScreenTranslation.swift).
/// </summary>
public static class ScreenTranslation
{
    /// <summary>Ekrandaki bir yazı grubu.</summary>
    /// <param name="Paragraphs">Grubun ayrı ayrı çevrilecek parçaları (başlık, cümle, menü satırı...).</param>
    /// <param name="Box">Grubun karedeki yeri, kenarlara oranla.</param>
    /// <param name="LineHeight">Satırlarının tipik yüksekliği, karenin yüksekliğine oranla; TV yazı boyunu buna göre seçer.</param>
    /// <param name="Icons">Her parçadaki kumanda simgeleri, parçadaki <see cref="ButtonIcons.Marker"/> sırasıyla.</param>
    public sealed record Group(IReadOnlyList<string> Paragraphs, TextBox Box, double LineHeight,
                               IReadOnlyList<IReadOnlyList<IconSlot>>? Icons = null);

    /// <param name="Translation">Parçaların çevirisi, her parça ayrı satırda.</param>
    /// <param name="Icons">Çevirinin içindeki kumanda simgeleri (kareden kesilmiş); TV <c>Translation</c>'ın o yerine koyar.</param>
    public sealed record Item(string Source, string Translation, TextBox Box, double LineHeight,
                              IReadOnlyList<IconPlacement>? Icons = null)
    {
        public PhoneTextStyle? Style { get; init; }
        /// <summary>Otomatik ekran yazısında özgün yazının görünüşü; TV ve masaüstü çeviriyi bu stilde çizer.</summary>
        public TextLook? Look { get; init; }
        /// <summary>Birden çok parça var: TV satır satır, sola yaslı gösterir.</summary>
        public bool Paragraphs => Translation.Contains('\n');
    }

    /// <summary>
    /// Kalabalık ekranda TV'yi kutuyla doldurmamak ve çeviriyi uzatmamak için en çok bu kadar grup çevrilir; fazlası
    /// olunca en az yazısı olanlar (tek sözcüklük etiketler) bırakılır.
    /// </summary>
    public const int MaxGroups = 30;

    /// <summary>
    /// Kareyi okuyup gruplarını sırayla çevirir. Her grup çevrilince o ana kadarki bütün sonuçlarla
    /// <paramref name="progress"/> çağrılır; böylece TV çeviriler hazırlandıkça dolar. Çevirisi aslıyla aynı olan
    /// (ad, sayı, zaten Türkçe yazı) grup gösterilmez. Çevirmen kullanılamıyorsa <see cref="TranslatorException"/> fırlatır.
    /// </summary>
    public static async Task<IReadOnlyList<Item>> TranslateAsync(
        Frame frame, ITextReader reader, ITextTranslator translator,
        Action<IReadOnlyList<Item>>? progress = null, CancellationToken cancellationToken = default)
    {
        // Küçük karede (720p) köşe yazıları birkaç piksel boyundadır; büyütmek yazı tanımanın onları da bulmasını sağlar.
        // ReadScreen: altyazıya göre seçilmiş hazırlık değil, karenin bütün yazıları (bkz. ITextReader.ReadScreen).
        var reading = await Task.Run(() => reader.ReadScreen(frame.Height < 900 ? frame.Scaled(2) : frame), cancellationToken)
            .ConfigureAwait(false);
        return await TranslateAsync(reading, translator, progress, cancellationToken, frame).ConfigureAwait(false);
    }

    /// <summary>
    /// Okunmuş karenin gruplarını çevirir. Çevirmen parçaları tek istekte çevirebiliyorsa (yapay zekâ) ekranın bütün
    /// parçaları birlikte gider ve sonuç bir kerede gelir; yoksa gruplar sırayla çevrilip hazırlandıkça bildirilir.
    /// <paramref name="frame"/> okunan kareyse yazıların içindeki kumanda simgeleri ondan kesilip çeviriye konur.
    /// </summary>
    public static async Task<IReadOnlyList<Item>> TranslateAsync(
        Reading reading, ITextTranslator translator,
        Action<IReadOnlyList<Item>>? progress = null, CancellationToken cancellationToken = default, Frame? frame = null)
    {
        var items = new List<Item>();
        var groups = ReadGroups(reading, false, frame);
        if (frame is not null)
            groups = [.. groups.Select(group => group.Icons is null ? group
                : group with { Icons = [.. group.Icons.Select(icons => ButtonIcons.WithImages(icons, frame))] })];
        // Simgeler çeviride uydurma adlarla korunur (IconText).
        var protectedGroups = groups.Select(group => group.Paragraphs.Select(IconText.Protect).ToList()).ToList();
        if (translator.TranslatesTogether)
        {
            var paragraphs = protectedGroups.SelectMany(group => group.Select(p => p.Text)).ToList();
            if (paragraphs.Count == 0) return items;
            var translations = await translator.TranslateAllAsync(paragraphs, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            var next = 0;
            for (var g = 0; g < groups.Count; g++)
            {
                var group = groups[g];
                var translated = Enumerable.Range(next, group.Paragraphs.Count)
                    .Select(i => i < translations.Count ? translations[i] : "").ToList();
                next += group.Paragraphs.Count;
                if (Build(group, protectedGroups[g], translated) is { } item) items.Add(item);
            }
            if (items.Count > 0) progress?.Invoke([.. items]);
            return items;
        }
        for (var g = 0; g < groups.Count; g++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var group = groups[g];
            var translated = new List<string>(group.Paragraphs.Count);
            foreach (var paragraph in protectedGroups[g])
                translated.Add(await translator.TranslateAsync(paragraph.Text, cancellationToken).ConfigureAwait(false));
            if (Build(group, protectedGroups[g], translated) is not { } item) continue;
            items.Add(item);
            progress?.Invoke([.. items]);
        }
        return items;
    }

    /// <summary>Grubun gösterilecek çevirisi; çevirisi aslıyla aynıysa (ad, sayı, zaten Türkçe yazı) null.</summary>
    private static Item? Build(Group group, IReadOnlyList<(string Text, IReadOnlyList<string> Names)> prepared,
                               IReadOnlyList<string> translations)
    {
        var changed = false;
        var texts = new List<string>(group.Paragraphs.Count);
        var slots = new List<IconSlot>();
        for (var i = 0; i < group.Paragraphs.Count; i++)
        {
            var paragraph = group.Paragraphs[i];
            var text = translations[i].Trim();
            text = text.Length == 0 ? IconText.Indexed(paragraph, slots.Count) : IconText.Restore(text, prepared[i].Names, slots.Count);
            changed |= !TextMatch.IsSimilar(TextMatch.Normalize(IconText.Plain(paragraph)), TextMatch.Normalize(IconText.Plain(text)), 0.90);
            texts.Add(text);
            slots.AddRange(group.Icons is { } all && i < all.Count ? all[i] : []);
        }
        if (!changed) return null;
        var (translation, placements) = IconText.Render(string.Join('\n', texts), slots);
        return new Item(string.Join('\n', group.Paragraphs.Select(IconText.Plain)), translation, group.Box, group.LineHeight,
                        placements.Count > 0 ? placements : null);
    }

    /// <summary>
    /// Satırları gruplara toplar. Kumanda ipuçları ve yazı tanıma çöpleri atılır; harfi olmayan ya da tek harfli
    /// satırlar ("23m", "9", "+") göstergedir, çevrilmez. Bir satır, üstündeki satırın hemen altındaysa, yatayda onunla
    /// üst üste biniyorsa ve yazı boyu benziyorsa o gruba katılır; küçük harfle başlayan satır üstteki bitmemiş cümleye
    /// katılır (<see cref="Continues"/>). Gruplar yukarıdan aşağı; en çok <see cref="MaxGroups"/>, en çok yazısı olanlar.
    /// <paramref name="menuRows"/> açıksa yalnız kısa büyük harfli etiketlerden oluşan grup (oyun menüsü) satır satır
    /// ayrı gruplara bölünür (<see cref="IsMenuLabel"/>).
    /// </summary>
    public static IReadOnlyList<Group> Groups(Reading reading, bool menuRows = false) =>
        ReadGroups(reading, menuRows, null);

    internal static IReadOnlyList<Group> Groups(Reading reading, bool menuRows, bool keepIdentifiers) =>
        ReadGroups(reading, menuRows, null, keepIdentifiers);

    private static IReadOnlyList<Group> ReadGroups(Reading reading, bool menuRows, Frame? frame, bool keepIdentifiers = false)
    {
        var marked = reading.WithButtonIcons();
        // Tam ekranda yalnız aksi halde atılacak kumanda ipuçlarında kareye bak.
        if (frame is not null)
            marked = new Reading(marked.Lines.Select(line => line.Icons is not { Count: > 0 } && ButtonPrompts.IsPrompt(line.Text)
                ? ButtonIcons.MarkFree(line, frame) : line));
        var lines = marked.WithoutButtonPrompts().WithoutOcrNoise(keepIdentifiers).Lines
            .Where(line => line.Box is not null && IsWords(line.Text))
            .OrderBy(line => line.Box!.Value.Top)
            .ToList();
        return GroupsFromLines(lines, menuRows);
    }

    // Satırlar süzülmüş, kutulu ve yukarıdan aşağıya sıralıdır.
    internal static IReadOnlyList<Group> GroupsFromLines(IReadOnlyList<TextLine> lines, bool menuRows)
    {
        var groups = new List<List<TextLine>>();
        foreach (var line in lines)
        {
            var index = groups.FindLastIndex(group => Belongs(line.Box!.Value, group[^1].Box!.Value));
            // İki bağımsız sütuna değen geniş başlık/alt satır, sütunlardan birinin parçası değildir.
            if (index >= 0 && (BridgesColumns(groups[index][^1].Box!.Value, line.Box!.Value, lines)
                || BridgesColumns(line.Box!.Value, groups[index][^1].Box!.Value, lines))) index = -1;
            // Küçük harfle başlayan satır, üstündeki bitmemiş cümlenin devamıdır: satır aralığı biraz geniş ya da yanında
            // başka bir yazı olsa da o gruba katılır. Ayrı grup olunca yarım cümle tek başına çevriliyor (yapay zekâ
            // boş/aynı döndürüyor) ya da grup sınırına takılıp hiç çevrilmiyordu; bilgi kutusunun son satırı İngilizce kalıyordu.
            if (index < 0) index = groups.FindLastIndex(group => Continues(line, group[^1]));
            if (index >= 0) groups[index].Add(line);
            else groups.Add([line]);
        }
        // GTA 6'nın etkileşim menüsü ("HAIR △" / "GREET ✕" / "STYLIST L2"): her satırın sağında kendi tuş simgesi var.
        // Satırlar tek kutuda çevrilince kutu satır aralığını tutmuyor, çeviriler simgelerinin yanından kayıyordu ("SAÇ"
        // HAIR ile GREET arasına düşüyor, HAIR açıkta kalıyordu). Her satır ayrı grup olunca çevirisi kendi satırının
        // üstüne, simgesinin yanına konur.
        if (menuRows)
            groups = [.. groups.SelectMany(group => group.Count > 1 && group.All(line => IsMenuLabel(line.Text))
                ? group.Select(line => new List<TextLine> { line })
                : [group])];
        return [.. Busiest(groups).Select(group =>
        {
            var heights = group.Select(line => line.Box!.Value.Bottom - line.Box!.Value.Top).OrderBy(value => value).ToList();
            var box = group.Select(line => line.Box!.Value).Aggregate((a, b) => a.Union(b));
            var icons = ParagraphIcons(group);
            return new Group(Paragraphs(group), box, heights[heights.Count / 2], icons.Any(list => list.Count > 0) ? icons : null);
        })];
    }

    /// <summary>
    /// Kalabalık ekranda en çok yazısı olan <see cref="MaxGroups"/> grup, yukarıdan aşağı sırasıyla. Önceden en üstteki
    /// gruplar alınıyordu: menü ve gösterge etiketleri sınırı doldurunca ekranın alt yarısındaki bilgi kutusu ve
    /// açıklamalar hiç çevrilmiyordu ("Ekranı çevir yazıların yarısını çeviriyor").
    /// </summary>
    private static IEnumerable<List<TextLine>> Busiest(List<List<TextLine>> groups) =>
        groups.Count <= MaxGroups ? groups
            : groups.Select((group, index) => (Group: group, Index: index, Letters: group.Sum(line => line.Text.Count(char.IsLetter))))
                .OrderByDescending(entry => entry.Letters).ThenBy(entry => entry.Index)
                .Take(MaxGroups).OrderBy(entry => entry.Index).Select(entry => entry.Group);

    /// <summary>
    /// Alt satır, üstteki satırın bitmemiş cümlesini sürdürüyor: küçük harfle başlıyor, üstteki cümle sonu işaretiyle
    /// bitmiyor, yazı boyu benzer, yatayda üst üste ve arada satır yüksekliğinin bir buçuk katından az boşluk var.
    /// </summary>
    private static bool Continues(TextLine lower, TextLine upper)
    {
        var first = lower.Text.FirstOrDefault(char.IsLetter);
        if (!char.IsLower(first) || SubtitleStabilizer.EndsSentence(upper.Text.Trim())) return false;
        TextBox below = lower.Box!.Value, above = upper.Box!.Value;
        double a = above.Bottom - above.Top, b = below.Bottom - below.Top;
        if (Math.Max(a, b) > Math.Min(a, b) * 1.6) return false;
        if (below.Top - above.Bottom >= Math.Max(a, b) * 1.5 || below.Top < above.Top) return false;
        var overlap = Math.Min(below.Right, above.Right) - Math.Max(below.Left, above.Left);
        var narrower = Math.Min(below.Right - below.Left, above.Right - above.Left);
        return overlap > 0 && overlap >= narrower * 0.5;
    }

    // Geniş kutu, yan yana duran iki ayrı satırı birbirine bağlamasın. Yalnız filtrelenmiş OCR satırları kullanılır.
    private static bool BridgesColumns(TextBox wide, TextBox column, IReadOnlyList<TextLine> lines) =>
        lines.Any(line =>
        {
            var peer = line.Box!.Value;
            if (Math.Min(column.Right, peer.Right) > Math.Max(column.Left, peer.Left)) return false;
            var rowOverlap = Math.Min(column.Bottom, peer.Bottom) - Math.Max(column.Top, peer.Top);
            if (rowOverlap <= 0 || rowOverlap < Math.Min(column.Bottom - column.Top, peer.Bottom - peer.Top) * 0.5) return false;
            return (Belongs(column, wide) && Belongs(peer, wide))
                || (Belongs(wide, column) && Belongs(wide, peer));
        });

    /// <summary>Alt satır üsttekinin hemen altında (arada satır yüksekliğinin %80'inden az), yatayda onunla üst üste ve yazı boyu benzer.</summary>
    private static bool Belongs(TextBox lower, TextBox upper)
    {
        double a = upper.Bottom - upper.Top, b = lower.Bottom - lower.Top;
        if (Math.Max(a, b) > Math.Min(a, b) * 1.6) return false;
        if (lower.Top - upper.Bottom >= Math.Max(a, b) * 0.8 || lower.Top < upper.Top) return false;
        var overlap = Math.Min(lower.Right, upper.Right) - Math.Max(lower.Left, upper.Left);
        var narrower = Math.Min(lower.Right - lower.Left, upper.Right - upper.Left);
        return overlap > 0 && overlap >= narrower * 0.5;
    }

    /// <summary>
    /// Grubun satırlarını ayrı çevrilecek parçalara böler. Önceki satır cümleyi bitirdiyse ya da kısa bir başlık/menü
    /// satırıysa (en çok üç sözcük, noktalamasız) ve yeni satır büyük harfle başlıyorsa yeni parça başlar; yoksa satır
    /// öncekinin devamıdır (cümle iki satıra sarılmış).
    /// </summary>
    internal static IReadOnlyList<string> Paragraphs(IReadOnlyList<TextLine> lines)
    {
        var result = new List<string>();
        foreach (var line in lines.Select(line => line.Text.Trim()))
        {
            if (result.Count > 0 && !StartsNew(result[^1], line)) result[^1] += " " + line;
            else result.Add(line);
        }
        return result;
    }

    /// <summary><see cref="Paragraphs"/> ile aynı bölmede her parçanın kumanda simgeleri, metindeki sırasıyla.</summary>
    internal static IReadOnlyList<IReadOnlyList<IconSlot>> ParagraphIcons(IReadOnlyList<TextLine> lines)
    {
        var texts = new List<string>();
        var result = new List<List<IconSlot>>();
        foreach (var line in lines)
        {
            var text = line.Text.Trim();
            var icons = line.Icons ?? [];
            if (texts.Count > 0 && !StartsNew(texts[^1], text))
            {
                texts[^1] += " " + text;
                result[^1].AddRange(icons);
            }
            else
            {
                texts.Add(text);
                result.Add([.. icons]);
            }
        }
        return result;
    }

    private static bool StartsNew(string previous, string line) =>
        SubtitleStabilizer.EndsSentence(previous) ||
        (char.IsUpper(line[0]) && WordCount(previous) <= 3 && !previous.EndsWith(','));

    /// <summary>
    /// Oyun menüsünün bir satırı: en çok <see cref="MenuLabelWords"/> sözcük, küçük harf yok ("HAIR", "MAYBE LATER",
    /// "NECKLACE ($475)"). Bilgi kutusu ve konuşma büyük-küçük harf karışıktır; onlar bölünmez.
    /// </summary>
    internal static bool IsMenuLabel(string text) =>
        text.Any(char.IsLetter) && !text.Any(char.IsLower) && WordCount(text) <= MenuLabelWords;

    internal const int MenuLabelWords = 5;

    /// <summary>En az iki harfi ve iki harfli bir sözcüğü olan satır yazıdır; geri kalanı sayı ve simgedir.</summary>
    internal static bool IsWords(string text) =>
        text.Count(char.IsLetter) >= 2 &&
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Any(word => word.Count(char.IsLetter) >= 2);

    private static int WordCount(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    /// <summary>
    /// Karenin iki okunuşunu birleştirir: <paramref name="raw"/> (olduğu gibi okunan kare) bütünüyle alınır,
    /// <paramref name="extra"/>'dan (ör. yalnız beyaz yazı bırakılarak okunan kare; açık sahnedeki beyaz altyazıyı ancak o
    /// bulur) yalnız ham okumadaki hiçbir satırla üst üste binmeyen satırlar eklenir. Aynı yazı iki kez çevrilmez.
    /// </summary>
    public static Reading Combined(Reading raw, Reading extra)
    {
        var boxes = raw.Lines.Where(line => line.Box is not null).Select(line => line.Box!.Value).ToList();
        var added = extra.Lines.Where(line => line.Box is { } box && !boxes.Any(other => Overlaps(box, other)));
        return new Reading(raw.Lines.Concat(added).OrderBy(line => line.Box?.Top ?? 0));
    }

    private static bool Overlaps(TextBox a, TextBox b) =>
        Math.Min(a.Right, b.Right) > Math.Max(a.Left, b.Left) && Math.Min(a.Bottom, b.Bottom) > Math.Max(a.Top, b.Top);

    /// <summary>Çevirilerin TV'de kalma süresi (ms): yazı çoksa daha uzun; tuşa yeniden basınca hemen kalkar.</summary>
    public static int DisplayMilliseconds(IReadOnlyList<Item> items) =>
        Math.Clamp(8000 + (items.Sum(item => item.Translation.Length) * 50), 12000, 60000);
}
