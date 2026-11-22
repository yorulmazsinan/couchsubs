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
                               IReadOnlyList<IReadOnlyList<IconSlot>>? Icons = null)
    {
        /// <summary>GTA 6 telefonunun ekranındaki grubun rolü ve düz ekrandaki yeri (<see cref="PhoneChat"/>); telefon dışındaysa null.</summary>
        internal ScreenPhoneCard.Placement? Phone { get; init; }
    }

    /// <param name="Translation">Parçaların çevirisi, her parça ayrı satırda.</param>
    /// <param name="Icons">Çevirinin içindeki kumanda simgeleri (kareden kesilmiş); TV <c>Translation</c>'ın o yerine koyar.</param>
    public sealed record Item(string Source, string Translation, TextBox Box, double LineHeight,
                              IReadOnlyList<IconPlacement>? Icons = null)
    {
        public PhoneTextStyle? Style { get; init; }
        /// <summary>Özgün yazının görünüşü (otomatik ekran yazısı ve "Ekranı çevir"); TV ve masaüstü çeviriyi bu stilde çizer.</summary>
        public TextLook? Look { get; init; }
        /// <summary>Çevirisi aslıyla aynı (ad, "ok"): yalnız telefon kartında gösterilir, başka yerde atılır (<see cref="ScreenPhoneCard"/>).</summary>
        internal bool Unchanged { get; init; }
        /// <summary>Telefondaki yazının rolü ve düz ekrandaki yeri; kart bunlarla dizilir (<see cref="ScreenPhoneCard.Layout"/>).</summary>
        internal ScreenPhoneCard.Placement? Phone { get; init; }
        /// <summary>
        /// GTA 6 telefonunun mesajı kendi balonunun üstünde, yerinde (kartsız): TV çeviriyi balona sığdırır (yazı okunabilir
        /// sınıra kadar küçülür, satır kırılır; sığmazsa balon biraz aşağı uzar). Mac ile aynı.
        /// </summary>
        public bool Bubble { get; init; }
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
    public static Task<IReadOnlyList<Item>> TranslateAsync(
        Frame frame, ITextReader reader, ITextTranslator translator,
        Action<IReadOnlyList<Item>>? progress = null, CancellationToken cancellationToken = default) =>
        TranslateAsync(frame, reader, translator, null, progress, cancellationToken);

    /// <summary>
    /// Kareyi okuyup çevirir; <paramref name="echo"/> verilirse altyazı hattının okuduğu satırlar (metinle; son altyazı
    /// yakınsa altyazı alanındakiler de) çevrilmez: altyazı zaten kendi yerinde çevriliyor (bkz. <see cref="SubtitleEcho"/>).
    /// </summary>
    public static async Task<IReadOnlyList<Item>> TranslateAsync(
        Frame frame, ITextReader reader, ITextTranslator translator, SubtitleEcho? echo,
        Action<IReadOnlyList<Item>>? progress = null, CancellationToken cancellationToken = default)
    {
        var reading = await ReadAsync(frame, reader, echo, cancellationToken).ConfigureAwait(false);
        return await TranslateAsync(reading, translator, progress, cancellationToken, frame).ConfigureAwait(false);
    }

    /// <summary>
    /// Karenin bütün yazılarını okur; <paramref name="echo"/> verilirse altyazı hattının okuduğu satırlar atılır. Çeviriler
    /// ekrandayken tuşa yeniden basınca önce bu okunur ve izi (<see cref="Fingerprint"/>) öncekiyle karşılaştırılır.
    /// </summary>
    public static async Task<Reading> ReadAsync(Frame frame, ITextReader reader, SubtitleEcho? echo, CancellationToken cancellationToken = default)
    {
        // Küçük karede (720p) köşe yazıları birkaç piksel boyundadır; büyütmek yazı tanımanın onları da bulmasını sağlar.
        // ReadScreen: altyazıya göre seçilmiş hazırlık değil, karenin bütün yazıları (bkz. ITextReader.ReadScreen).
        var reading = await Task.Run(() => reader.ReadScreen(frame.Height < 900 ? frame.Scaled(2) : frame), cancellationToken)
            .ConfigureAwait(false);
        return echo is null ? reading : echo.Filter(reading, geometry: echo.HasRecent);
    }

    /// <summary>
    /// Okunmuş karenin gruplarını çevirir. Çevirmen parçaları tek istekte çevirebiliyorsa (yapay zekâ) ekranın bütün
    /// parçaları birlikte gider ve sonuç bir kerede gelir; yoksa gruplar sırayla çevrilip hazırlandıkça bildirilir.
    /// <paramref name="frame"/> okunan kareyse yazıların içindeki kumanda simgeleri ondan kesilip çeviriye konur, her
    /// çeviri özgün yazının stilinde (zemin ve yazı rengi, kalınlık, hiza, BÜYÜK HARF; otomatik ekran yazısıyla aynı,
    /// <see cref="TextStyleSampler"/>) kendi kutusunun yerine çizilir; karede GTA 6 telefonu varsa telefonun yazıları
    /// yanında bir mesaj kartında dizilir (<see cref="ScreenPhoneCard"/>). <paramref name="memory"/> verilirse çeviriler
    /// (telefon mesajları sohbetin başlığıyla) saklanır; aynı sohbete dönünce ya da kart yenilenince çevirmene gitmez
    /// (<see cref="PhoneChatMemory"/>). <paramref name="handset"/>: karesiz sınamalar için.
    /// </summary>
    public static async Task<IReadOnlyList<Item>> TranslateAsync(
        Reading reading, ITextTranslator translator,
        Action<IReadOnlyList<Item>>? progress = null, CancellationToken cancellationToken = default, Frame? frame = null,
        PhoneChatMemory? memory = null, ScreenPhoneCard.Handset? handset = null, bool phoneCard = true)
    {
        var items = new List<Item>();
        var phone = handset ?? (frame is null ? null : ScreenPhoneCard.Phone(frame));
        var groups = ReadGroups(reading, false, frame, wholeScreen: true, handset: phone);
        var chat = ChatTitle(groups);
        var keep = phone is not null;
        if (frame is not null)
            groups = [.. groups.Select(group => group.Icons is null ? group
                : group with { Icons = [.. group.Icons.Select(icons => ButtonIcons.WithImages(icons, frame))] })];
        // Simgeler çeviride uydurma adlarla korunur (IconText).
        var protectedGroups = groups.Select(group => group.Paragraphs.Select(IconText.Protect).ToList()).ToList();
        if (translator.TranslatesTogether)
        {
            // Sözlükteki kısa arayüz etiketleri ("SCROLL", "SEND", "BACK") ve telefondaki kişi adları çevirmene gitmez;
            // fiyatlar adla korunur.
            var sources = groups.SelectMany(group => group.Paragraphs).ToList();
            if (sources.Count == 0) return items;
            // Daha önce görülen sohbetin mesajları da (memory) gitmez.
            var owners = groups.SelectMany(group => group.Paragraphs.Select(_ => group)).ToList();
            var knowns = Enumerable.Range(0, sources.Count)
                .Select(i => Known(sources[i], owners[i]) ?? Remembered(sources[i], owners[i], chat, memory)).ToList();
            var prices = protectedGroups.SelectMany(group => group.Select(p => PriceText.Protect(p.Text))).ToList();
            var asked = Enumerable.Range(0, sources.Count).Where(i => knowns[i] is null).ToList();
            var answers = asked.Count == 0 ? []
                : await translator.TranslateAllAsync([.. asked.Select(i => prices[i].Text)], cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            var translations = knowns.Select(known => known ?? "").ToList();
            for (var k = 0; k < asked.Count && k < answers.Count; k++)
            {
                translations[asked[k]] = PriceText.Restore(answers[k], prices[asked[k]].Values);
                memory?.Remember(MemoryChat(owners[asked[k]], chat), sources[asked[k]], translations[asked[k]]);
            }
            var next = 0;
            for (var g = 0; g < groups.Count; g++)
            {
                var group = groups[g];
                var translated = Enumerable.Range(next, group.Paragraphs.Count)
                    .Select(i => i < translations.Count ? translations[i] : "").ToList();
                next += group.Paragraphs.Count;
                if (Build(group, protectedGroups[g], translated, keep) is { } item) items.Add(Styled(item, frame));
            }
            var all = Present(items, phone, phoneCard);
            if (all.Count > 0) progress?.Invoke(all);
            return all;
        }
        for (var g = 0; g < groups.Count; g++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var group = groups[g];
            var translated = new List<string>(group.Paragraphs.Count);
            for (var p = 0; p < group.Paragraphs.Count; p++)
            {
                var source = group.Paragraphs[p];
                if ((Known(source, group) ?? Remembered(source, group, chat, memory)) is { } known)
                {
                    translated.Add(known);
                    continue;
                }
                var prices = PriceText.Protect(protectedGroups[g][p].Text);
                var result = PriceText.Restore(
                    await translator.TranslateAsync(prices.Text, cancellationToken).ConfigureAwait(false), prices.Values);
                memory?.Remember(MemoryChat(group, chat), source, result);
                translated.Add(result);
            }
            if (Build(group, protectedGroups[g], translated, keep) is not { } item) continue;
            items.Add(Styled(item, frame));
            var shown = Present(items, phone, phoneCard);
            if (shown.Count > 0) progress?.Invoke(shown);
        }
        return Present(items, phone, phoneCard);
    }

    /// <summary>
    /// Oyun arayüzü sözlüğündeki kısa etiketin Türkçesi ("SCROLL" → "KAYDIR", "TIP" → "BAHŞİŞ VER"); simgeli ya da
    /// sözlükte olmayan parçada null (çevirmene gider).
    /// </summary>
    internal static string? Known(string paragraph, Group? group = null) =>
        // Telefondaki kişi adı (sohbet başlığı, listedeki ad) çevrilmez: "Rose" "Gül", "May" "Mayıs" olmasın.
        group?.Phone?.Role.KeepsText() == true ? paragraph
        // "JASON & LUCIA" gibi yalnız özel adlardan oluşan sekme/başlık çevrilmez (#859).
        : KeepsNames(paragraph) ? paragraph
        : paragraph.Contains(ButtonIcons.Marker) ? null : UiCommands.TranslateLabel(paragraph);

    /// <summary>Telefondaki sohbetin başlığı (kişi adı); sohbet listesinde ya da telefonsuz karede boş.</summary>
    internal static string ChatTitle(IReadOnlyList<Group> groups) =>
        groups.FirstOrDefault(group => group.Phone?.Role == ScreenPhoneCard.Role.Header)?.Paragraphs.FirstOrDefault() ?? "";

    /// <summary>Hafızadaki yeri: telefon mesajı sohbetin başlığıyla, telefon dışındaki yazı (görev, menü) başlıksız saklanır.</summary>
    internal static string MemoryChat(Group group, string chat) => group.Phone is null ? "" : chat;

    /// <summary>Bu sohbette (telefon dışındaki yazıda: bu ekranda) daha önce çevrilmiş parçanın çevirisi (<see cref="PhoneChatMemory"/>).</summary>
    internal static string? Remembered(string paragraph, Group group, string chat, PhoneChatMemory? memory) =>
        memory?.Translation(MemoryChat(group, chat), paragraph);

    /// <summary>
    /// Öğeye özgün yazının görünüşü: zemin ve yazı rengi, kalınlık, dar yazı, hiza; özgün yazı BÜYÜK HARFse çeviri de
    /// büyütülür. Önceden "Ekranı çevir" her yazıyı aynı siyah kutuda gösteriyordu, otomatik ekran yazısı ise özgün
    /// stilde; kullanıcılar çevirinin "ayrı bir kutuda" durduğunu söylüyordu.
    /// </summary>
    internal static Item Styled(Item item, Frame? frame)
    {
        if (frame is null) return item;
        var (surface, look) = TextStyleSampler.Sample(frame, item.Box, [], item.Source);
        return item with
        {
            Style = surface, Look = look,
            Translation = look.Upper ? TextStyleSampler.TurkishUpper(item.Translation) : item.Translation,
        };
    }

    /// <summary>
    /// Gösterilecek öğeler: telefon varsa <paramref name="card"/> açıkken kartı dizilir; kapalıyken (varsayılan ayar) her
    /// mesajın çevirisi kendi balonunun üstünde, balonun rengiyle yerinde kalır (<see cref="Item.Bubble"/>). Çevirisi aslıyla
    /// aynı öğeler (kart dışında; yerinde kişi adı) atılır, özgün yazı görünür kalır (Mac ile aynı).
    /// </summary>
    internal static IReadOnlyList<Item> Present(IReadOnlyList<Item> items, ScreenPhoneCard.Handset? phone, bool card = true) =>
        WithoutDuplicates([.. (phone is not null && card ? ScreenPhoneCard.Layout(items, phone)
            : items.Select(item => item with { Bubble = item.Phone?.Role is { } role && role != ScreenPhoneCard.Role.Home }))
            .Where(item => !item.Unchanged)]);

    // --- Aynı yerde tek çizim (#827) ---

    /// <summary>
    /// Aynı okumada iki satırın (ya da iki öğenin) kutusu küçüğünün alanının en az bu kadarı kadar örtüşüyorsa aynı yazının
    /// iki okunuşudur; yalnız harfi çok olanı kalır.
    /// </summary>
    public const double DuplicateShare = 0.5;

    /// <summary>
    /// Ayrı yollardan gelen iki çevirinin ("Ekranı çevir", otomatik ekran yazısı, ek alan) kutusu küçüğünün alanının en az
    /// bu kadarı kadar örtüşüyorsa aynı yazıyı çiziyorlardır; yalnız biri çizilir. Önceden GTA 6 haritasında ikisi üst üste
    /// çiziliyor, alttakinin yazısı üsttekinin arasından görünüyordu.
    /// </summary>
    public const double CoverShare = 0.25;

    /// <summary>İki kutunun kesişiminin küçük kutunun alanına oranı (0…1).</summary>
    public static double Overlap(TextBox a, TextBox b)
    {
        var width = Math.Min(a.Right, b.Right) - Math.Max(a.Left, b.Left);
        var height = Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top);
        if (width <= 0 || height <= 0) return 0;
        var smaller = Math.Min((a.Right - a.Left) * (a.Bottom - a.Top), (b.Right - b.Left) * (b.Bottom - b.Top));
        return smaller > 0 ? Math.Min(1, width * height / smaller) : 0;
    }

    private static int Letters(string text) => text.Count(char.IsLetter);

    /// <summary>
    /// Aynı yazının iki okunuşundan (yazı tanıma bir satırı hem bütün hem parça okuyabiliyor) yalnız harfi çok olanı kalır;
    /// eşitse önce gelen. Sıra korunur. Önceden ikisi ayrı çevrilip üst üste çiziliyordu ("Donnie'nin Paketini Bul" altında
    /// "Bulur").
    /// </summary>
    public static IReadOnlyList<TextLine> WithoutDuplicateLines(IReadOnlyList<TextLine> lines)
    {
        var counts = lines.Select(line => Letters(line.Text)).ToList();
        return [.. lines.Where((line, i) => line.Box is not { } box || !Enumerable.Range(0, lines.Count).Any(j =>
            j != i && lines[j].Box is { } other && Overlap(box, other) >= DuplicateShare
            && (counts[j] > counts[i] || (counts[j] == counts[i] && j < i))))];
    }

    /// <summary>
    /// Satırın başındaki ya da sonundaki simge kırıntısı (menüdeki harita/dükkân/ayar simgesi yazı tanımada "&lt;", "©",
    /// "@" ya da baştaki tek harf olarak okunur) satırdan atılır; kutu yalnız yazının sözcüklerini kapsar (#827). Önceden
    /// çeviri kutusu simgeyi de örtüyordu. Sözcük yerleri bilinmiyorsa harf sayısına göre kestirilir. Kumanda simgeli
    /// satıra (simge çeviride yerinde gösterilir), sayıya, noktalamaya ve geriye iki harf kalmayacaksa dokunulmaz.
    /// </summary>
    public static TextLine WithoutEdgeMarks(TextLine line)
    {
        if (line.Icons is { Count: > 0 } || line.Text.Contains(ButtonIcons.Marker) || line.Box is not { } box) return line;
        var measured = line.Words is { Count: > 0 };
        var words = measured ? line.Words! : ButtonIcons.Estimate(line.Text, box);
        int start = 0, end = words.Count;
        while (start < end - 1 && IsEdgeMark(words[start].Text, leading: true)) start++;
        while (end - 1 > start && IsEdgeMark(words[end - 1].Text, leading: false)) end--;
        if (start == 0 && end == words.Count) return line;
        var kept = words.Skip(start).Take(end - start).ToList();
        if (kept.Sum(word => Letters(word.Text)) < 2) return line;
        return line with
        {
            Text = string.Join(' ', kept.Select(word => word.Text)),
            Box = new TextBox(start > 0 ? kept[0].Box.Left : box.Left, box.Top,
                              end < words.Count ? kept[^1].Box.Right : box.Right, box.Bottom),
            Words = measured ? kept : null,
        };
    }

    /// <summary>Yalnız noktalamadan oluşan parça simge değildir ("...", "-").</summary>
    private const string Punctuation = ".,!?…:;-–—'\"’”";
    /// <summary>Kumanda tuşu yazısı ("(✕)", "△", "R1"): kontrol şemasında etiketin parçasıdır, çeviride de yazılır; atılmaz.</summary>
    private const string ButtonGlyphs = "✕×△○□◯⨯";

    /// <summary>
    /// Simge kırıntısı mı: harfi ve rakamı yok ve yalnız noktalama ya da kumanda tuşu değil ("&lt;", "©", "@"); satır
    /// başında tek harf de ("G Settings"; "a", "A", "I" sözcüktür).
    /// </summary>
    internal static bool IsEdgeMark(string word, bool leading)
    {
        var core = word.Trim("()[]{}".ToCharArray());
        if (word.Any(char.IsDigit) || word.Any(c => ButtonGlyphs.Contains(c)) || ButtonIcons.IsButtonName(core)
            || (word.Length > 1 && word[0] == '(' && word[^1] == ')')) return false;
        if (!word.Any(char.IsLetter)) return !word.All(c => Punctuation.Contains(c));
        return leading && word.Length == 1 && word is not ("a" or "A" or "I");
    }

    /// <summary>Telefon kartının parçası (zemin, balon, başlık): kart bilerek üst üste dizilir, çakışma kuralına girmez.</summary>
    internal static bool IsCardPart(Item item) => item.Phone is not null || ScreenPhoneCard.IsBackdrop(item);

    /// <summary>Aynı okumanın öğelerinden aynı yeri çizenlerin yalnız harfi çok olanı kalır (<see cref="DuplicateShare"/>); kart dokunulmaz.</summary>
    internal static IReadOnlyList<Item> WithoutDuplicates(IReadOnlyList<Item> items)
    {
        var counts = items.Select(item => Letters(item.Source)).ToList();
        return [.. items.Where((item, i) => IsCardPart(item) || !Enumerable.Range(0, items.Count).Any(j =>
            j != i && !IsCardPart(items[j]) && Overlap(item.Box, items[j].Box) >= DuplicateShare
            && (counts[j] > counts[i] || (counts[j] == counts[i] && j < i))))];
    }

    /// <summary>
    /// Katmanlar tek listede: sonra gelen öğe, kendisiyle çakışan (<see cref="CoverShare"/>) önceki öğelerin yerine geçer
    /// (yeni olan eskisini değiştirir). Telefon kartının parçaları dokunulmaz.
    /// </summary>
    public static IReadOnlyList<Item> Layered(IEnumerable<Item> items)
    {
        var result = new List<Item>();
        foreach (var item in items)
        {
            if (!IsCardPart(item)) result.RemoveAll(other => !IsCardPart(other) && Overlap(other.Box, item.Box) >= CoverShare);
            result.Add(item);
        }
        return result;
    }

    /// <summary>
    /// <paramref name="items"/>'tan <paramref name="top"/> öğelerinden biriyle çakışanlar (<see cref="CoverShare"/>) atılır:
    /// "Ekranı çevir" ekrandayken onun yazılarının yerindeki otomatik ekran yazısı ve ek alan kutuları çizilmez.
    /// </summary>
    public static IReadOnlyList<Item> Uncovered(IEnumerable<Item> items, IReadOnlyList<Item> top) =>
        [.. items.Where(item => !top.Any(other => Overlap(item.Box, other.Box) >= CoverShare))];

    /// <summary>Aynı ekranın iki okuması en az bu kadar benzer; yeni bir mesajın eklenmesi bile ekranı "değişmiş" yapar.</summary>
    public const double SameScreenSimilarity = 0.95;

    /// <summary>Ekranın yazılarının izi: tuşa yeniden basınca ekranın değişip değişmediği buna bakılarak anlaşılır.</summary>
    public static string Fingerprint(Reading reading) =>
        TextMatch.Normalize(string.Join(' ', Groups(reading).SelectMany(group => group.Paragraphs).Select(IconText.Plain)));

    /// <summary>
    /// İki iz aynı ekranın mı. Çeviriler ekrandayken tuşa yeniden basmak önceden hep onları kaldırıyordu: telefonda başka
    /// bir sohbete geçip basınca yeni sohbet çevrilmiyor, ekran boşalıyordu. Artık ekran değiştiyse yeni kare çevrilir,
    /// değişmediyse çeviriler kalkar (Mac ve Android ile aynı).
    /// </summary>
    public static bool IsSameScreen(string a, string b) =>
        a.Length == 0 || b.Length == 0 ? a == b : TextMatch.IsSimilar(a, b, SameScreenSimilarity);

    /// <summary>Grubun gösterilecek çevirisi; çevirisi aslıyla aynıysa (ad, sayı, zaten Türkçe yazı) null.</summary>
    private static Item? Build(Group group, IReadOnlyList<(string Text, IReadOnlyList<string> Names)> prepared,
                               IReadOnlyList<string> translations, bool keepUnchanged = false)
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
        if (!changed && !keepUnchanged) return null;
        var (translation, placements) = IconText.Render(string.Join('\n', texts), slots);
        return new Item(string.Join('\n', group.Paragraphs.Select(IconText.Plain)), translation, group.Box, group.LineHeight,
                        placements.Count > 0 ? placements : null) { Unchanged = !changed, Phone = group.Phone };
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

    /// <summary>
    /// <paramref name="wholeScreen"/> ("Ekranı çevir"): yazı tanımanın bozduğu fiyatlar düzelir (<see cref="PriceText.Repair"/>)
    /// ve tuş çubukları atılmaz, etiketlerine bölünür (<see cref="PromptPieces"/>): tuş simgeleri ve fiyatlar çeviriye
    /// girmez, ekranda görünür kalır; aynı satırdaki her seçenek kendi kutusunda çevrilir, çeviriler üst üste binmez.
    /// <paramref name="handset"/>: karede GTA 6 telefonu varsa ekranındaki satırlar ayrı gruplanır (<see cref="PhoneChat"/>:
    /// balon, başlık, liste).
    /// </summary>
    private static IReadOnlyList<Group> ReadGroups(Reading reading, bool menuRows, Frame? frame, bool keepIdentifiers = false,
                                                   bool wholeScreen = false, ScreenPhoneCard.Handset? handset = null)
    {
        var marked = (wholeScreen ? new Reading(reading.Lines.Select(Repaired)) : reading).WithButtonIcons();
        if (wholeScreen)
        {
            marked = new Reading(marked.Lines.SelectMany(line =>
                line.Icons is not { Count: > 0 } && line.Box is not null && (ButtonPrompts.IsPrompt(line.Text) || HasWideGap(line))
                    ? PromptPieces(line) : [line]));
            // Menü şeridinin sekmeleri ("JASON & LUCIA   MAP   BRIEF") tek satır okunsa da ayrı ayrı çevrilir (#859).
            var aspect = frame is not null ? (double)frame.Width / Math.Max(1, frame.Height) : 16.0 / 9.0;
            marked = new Reading(marked.Lines.SelectMany(line => MenuPieces(line, aspect, frame)));
        }
        // Tam ekranda yalnız aksi halde atılacak kumanda ipuçlarında kareye bak. "Ekranı çevir": satır ucundaki kısa parça
        // ("RECENTER 13", "EXIT O") okunmuş bir tuş simgesi olabilir; görüntüden doğrulanırsa simge olur, kutunun dışında
        // kalır (#860).
        if (frame is not null)
            marked = new Reading(marked.Lines.Select(line =>
                line.Icons is { Count: > 0 } ? line
                : ButtonPrompts.IsPrompt(line.Text) ? ButtonIcons.MarkFree(line, frame)
                : wholeScreen && HasShortEdge(line) ? ButtonIcons.MarkFree(line, frame, monochrome: true) : line));
        var lines = marked.WithoutButtonPrompts().WithoutOcrNoise(keepIdentifiers).Lines
            .Where(line => line.Box is not null && IsWords(line.Text))
            // Saat ve sayaç ("12:00 pm") çevrilmez.
            .Where(line => !wholeScreen || !IsClock(line.Text))
            .OrderBy(line => line.Box!.Value.Top).ThenBy(line => line.Box!.Value.Left)
            .ToList();
        // "Ekranı çevir": haritanın görev kartı kendi parçalarına ayrılır (başlık, açıklama, ayrıntılar; MissionCard).
        // Aynı yazının iki okunuşu tek satır kalır; satırın başındaki/sonundaki simge kutunun dışında kalır (#827).
        // Telefonun satırları girmez: eğik telefonda kutuları bilerek üst üste.
        IReadOnlyList<Group> Plain(IReadOnlyList<TextLine> all)
        {
            // "Ekranı çevir"de satırın başındaki/sonundaki kumanda simgesi kutunun dışında kalır, görünür (#860).
            var kept = WithoutDuplicateLines([.. all.Select(WithoutEdgeMarks).Select(line => wholeScreen ? WithoutEdgeIcons(line) : line)]);
            return wholeScreen ? WithMissionCards(kept, menuRows, frame) : GroupsFromLines(kept, menuRows);
        }
        if (handset is null) return Plain(lines);
        var onPhone = lines.Where(line => PhoneChat.OnScreen(handset.Flat(line.Box!.Value))).ToList();
        if (onPhone.Count == 0) return Plain(lines);
        // Süzülmemiş satırlar da gider: harfsiz hava durumu satırı ("76°") ana ekranı belli eder.
        var raw = reading.Lines.Where(line => line.Box is { } box && PhoneChat.OnScreen(handset.Flat(box))).ToList();
        return [.. Plain([.. lines.Where(line => !PhoneChat.OnScreen(handset.Flat(line.Box!.Value)))]),
                .. PhoneChat.Groups(onPhone, handset, raw)];
    }

    /// <summary>"Ekranı çevir"in grupları (kare olmadan); karede telefon varsa ekranının satırları ayrı gruplanır (sınamalar için).</summary>
    internal static IReadOnlyList<Group> ScreenGroups(Reading reading, ScreenPhoneCard.Handset? handset = null) =>
        ReadGroups(reading, false, null, wholeScreen: true, handset: handset);

    /// <summary>
    /// Satırlardaki görev kartları kendi gruplarıyla (kare varsa yalnız düz panelin üstündekiler), kalanlar her zamanki
    /// gibi. Kart tanınmadan başlık açıklamanın ilk cümlesine katılıyor, beş-altı sözcüklük başlık cümleyle birlikte
    /// çevriliyordu.
    /// </summary>
    internal static IReadOnlyList<Group> WithMissionCards(IReadOnlyList<TextLine> lines, bool menuRows, Frame? frame)
    {
        var cards = MissionCard.Find(lines)
            .Where(card => frame is null || MissionCard.OnPanel(frame, [.. card.All.Select(i => lines[i])])).ToList();
        var taken = cards.SelectMany(card => card.All).ToHashSet();
        var rest = Enumerable.Range(0, lines.Count).Where(i => !taken.Contains(i)).Select(i => lines[i]).ToList();
        return [.. LabelColumns(GroupsFromLines(rest, menuRows), rest).Concat(cards.SelectMany(card => MissionCard.Groups(card, lines)))
            .OrderBy(group => group.Box.Top)];
    }

    /// <summary>
    /// Bütün satırları kısa BÜYÜK HARFLİ etiket olan grup (tuş ipuçları sütunu, menü listesi) satır satır gruptur: her
    /// etiket kendi kutusunda, kendi yerinde çevrilir. Önceden sütun tek kutu oluyor, sağındaki tuş simgelerini de
    /// örtüyordu (#860).
    /// </summary>
    internal static IReadOnlyList<Group> LabelColumns(IReadOnlyList<Group> groups, IReadOnlyList<TextLine> lines) =>
        [.. groups.SelectMany(group =>
        {
            var own = lines.Where(line =>
            {
                var box = line.Box!.Value;
                double x = (box.Left + box.Right) / 2, y = (box.Top + box.Bottom) / 2;
                return x >= group.Box.Left - 1e-6 && x <= group.Box.Right + 1e-6 && y >= group.Box.Top - 1e-6 && y <= group.Box.Bottom + 1e-6;
            }).ToList();
            if (own.Count <= 1 || !own.All(line =>
                {
                    var plain = IconText.Plain(line.Text);
                    return WordCount(plain) <= MenuLabelWords && plain.Any(char.IsLetter) && !plain.Any(char.IsLower);
                }))
                return (IEnumerable<Group>)[group];
            return own.Select(line =>
            {
                var icons = ParagraphIcons([line]);
                return new Group(Paragraphs([line]), line.Box!.Value, line.Box!.Value.Bottom - line.Box!.Value.Top,
                                 icons.Any(list => list.Count > 0) ? icons : null);
            });
        })];

    /// <summary>Saat ya da sayaç ("12:00 pm", "x3"): harflerinden çok rakamı var, fiyat değil. Çevrilmez.</summary>
    internal static bool IsClock(string text) =>
        ScreenTextNoise.IsNoise(text, menu: true)
        && !text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Any(PriceText.IsMoney);

    /// <summary>Satırın ilk ya da son parçası en çok iki harflik (okunmuş tuş simgesi olabilir: "13", "O", "®").</summary>
    internal static bool HasShortEdge(TextLine line)
    {
        var parts = line.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= 2 && (parts[^1].Length <= 2 || parts[0].Length <= 2);
    }

    // --- Menü şeridi, özel adlar, kenardaki tuş simgesi (#856, #859, #860) ---

    /// <summary>
    /// Menü şeridinde sekmelerin arası: satır yüksekliğinin bu katından geniş boşluk sözcük arası değildir (sözcük arası
    /// yazı boyunun üçte biri kadardır). GTA 6 haritasının üst şeridi "JASON &amp; LUCIA   MAP   BRIEF   PROGRESS" tek satır
    /// okunuyor, sekmeler tek cümle sanılıp "LUCIA HARİTASI KISA İLERLEME RAPORU" diye çevriliyordu.
    /// </summary>
    public const double MenuGap = 0.9;

    /// <summary>
    /// BÜYÜK HARFLİ satırdaki geniş boşluklar (<see cref="MenuGap"/>) ayrı sekmelerdir: her sekme kendi satırı, kutusu kendi
    /// yazısı. Kare verilirse boşluklar görüntüden bulunur (<see cref="InkPieces"/>; yazı tanımanın sözcük kutuları boşluğu
    /// da kapsıyor), yoksa sözcük yerlerinden. Satırda simge varsa ya da satır büyük harf değilse dokunulmaz.
    /// <paramref name="aspect"/>: kutuların oranlandığı görüntünün genişlik/yükseklik oranı. İki harfi olmayan parça atılır.
    /// </summary>
    public static IReadOnlyList<TextLine> MenuPieces(TextLine line, double aspect = 16.0 / 9.0, Frame? frame = null)
    {
        if (line.Box is not { } box || line.Icons is { Count: > 0 } || !TextStyleSampler.IsUpper(line.Text) || WordCount(line.Text) < 2)
            return [line];
        var limit = (box.Bottom - box.Top) * MenuGap / Math.Max(0.1, aspect);
        if (frame is not null) return InkPieces(line, frame, limit);
        if (line.Words is not { Count: >= 2 } words) return [line];
        var runs = new List<List<TextWord>> { new() { words[0] } };
        foreach (var word in words.Skip(1))
        {
            if (word.Box.Left - runs[^1][^1].Box.Right > limit) runs.Add([]);
            runs[^1].Add(word);
        }
        if (runs.Count == 1) return [line];
        return [.. runs.Where(run => run.Sum(word => word.Text.Count(char.IsLetter)) >= 2).Select(run =>
        {
            var span = run.Select(word => word.Box).Aggregate((a, b) => a.Union(b));
            return new TextLine(string.Join(' ', run.Select(word => word.Text)), new TextBox(span.Left, box.Top, span.Right, box.Bottom),
                                line.Confidence, run);
        })];
    }

    /// <summary>
    /// Satırın yazı sütunları: kutudaki her sütunda zeminden (kutunun ortanca parlaklığı) belirgin ayrılan nokta var mı;
    /// <paramref name="gap"/>'ten geniş boş aralıklar yazıyı parçalara böler. Parçalar kareye oranla [sol, sağ].
    /// </summary>
    internal static List<(double Left, double Right)> InkSpans(Frame frame, TextBox box, double gap)
    {
        double left = Math.Max(0, box.Left) * frame.Width, top = Math.Max(0, box.Top) * frame.Height;
        double width = (Math.Min(1, box.Right) - Math.Max(0, box.Left)) * frame.Width;
        double height = (Math.Min(1, box.Bottom) - Math.Max(0, box.Top)) * frame.Height;
        if (width < 8 || height < 4) return [];
        var columns = Math.Max(8, Math.Min(800, (int)Math.Round(width)));
        const int rows = 12;
        var luma = new int[columns * rows];
        for (var y = 0; y < rows; y++)
        {
            var py = Math.Min(frame.Height - 1, (int)(top + (y + 0.5) * height / rows));
            for (var x = 0; x < columns; x++)
            {
                var px = Math.Min(frame.Width - 1, (int)(left + (x + 0.5) * width / columns));
                var p = py * frame.Stride + px * 4;
                luma[y * columns + x] = (299 * frame.Pixels[p + 2] + 587 * frame.Pixels[p + 1] + 114 * frame.Pixels[p]) / 1000;
            }
        }
        var median = luma.OrderBy(v => v).ElementAt(luma.Length / 2);
        var ink = Enumerable.Range(0, columns)
            .Select(x => Enumerable.Range(0, rows).Any(y => Math.Abs(luma[y * columns + x] - median) > 60)).ToArray();
        var step = (box.Right - box.Left) / columns;
        var blank = Math.Max(1, (int)Math.Ceiling(gap / Math.Max(1e-9, step)));
        var spans = new List<(double, double)>();
        var i = 0;
        while (i < columns)
        {
            if (!ink[i]) { i++; continue; }
            int end = i, run = 0;
            for (var probe = i + 1; probe < columns; probe++)
            {
                if (ink[probe]) { end = probe; run = 0; }
                else if (++run > blank) break;
            }
            spans.Add((box.Left + i * step, box.Left + (end + 1) * step));
            i = end + 1;
        }
        return spans;
    }

    /// <summary>
    /// Menü satırının sekmeleri: görüntüdeki geniş boşluklardan (<see cref="InkSpans"/>) bölünür. Sözcükler sırasıyla
    /// parçalara dağıtılır: her parçanın harf sayısı payı genişlik payına en yakın olacak biçimde (yazı tanımanın sözcük
    /// kutuları boşlukları da kapsadığı için yerlerine bakılmaz). Parça sayısı sözcüklerden çoksa dokunulmaz.
    /// </summary>
    internal static IReadOnlyList<TextLine> InkPieces(TextLine line, Frame frame, double gap)
    {
        if (line.Box is not { } box) return [line];
        var spans = InkSpans(frame, box, gap);
        var words = line.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (spans.Count < 2 || words.Length < spans.Count) return [line];
        int k = spans.Count, n = words.Length;
        var widths = spans.Select(span => span.Right - span.Left).ToArray();
        var totalWidth = widths.Sum();
        var sizes = words.Select(word => (double)word.Length).ToArray();
        var totalSize = sizes.Sum() + (n - k);
        // En iyi bölme: best[i, j] ilk i sözcük j parçada; parçanın payı sözcükleri ve aralarındaki boşluklar.
        var best = new double[n + 1, k + 1];
        var from = new int[n + 1, k + 1];
        for (var a = 0; a <= n; a++)
            for (var b = 0; b <= k; b++) best[a, b] = double.PositiveInfinity;
        best[0, 0] = 0;
        for (var i = 1; i <= n; i++)
            for (var j = 1; j <= Math.Min(i, k); j++)
                for (var start = j - 1; start < i; start++)
                {
                    if (double.IsPositiveInfinity(best[start, j - 1])) continue;
                    var size = sizes[start..i].Sum() + (i - start - 1);
                    var cost = best[start, j - 1] + Math.Abs(size / totalSize - widths[j - 1] / totalWidth);
                    if (cost < best[i, j]) (best[i, j], from[i, j]) = (cost, start);
                }
        var bounds = new List<int>();
        var at = n;
        for (var j = k; j > 0; j--)
        {
            bounds.Insert(0, from[at, j]);
            at = from[at, j];
        }
        bounds.Add(n);
        var result = new List<TextLine>();
        for (var j = 0; j < k; j++)
        {
            var text = string.Join(' ', words[bounds[j]..bounds[j + 1]]);
            if (text.Count(char.IsLetter) < 2) continue;
            result.Add(new TextLine(text, new TextBox(spans[j].Left, box.Top, spans[j].Right, box.Bottom), line.Confidence));
        }
        return result;
    }

    /// <summary>
    /// Yalnız özel adlardan oluşan yazı ("JASON &amp; LUCIA", "Bonnie &amp; Clyde"): "&amp;" ile bağlı, her biri bir iki
    /// sözcüklük (BÜYÜK HARFLİ yazıda tek sözcüklük), büyük harfle başlayan adlar. Çevirmene gitmez; çevirisi aslıdır (kutusu çizilmez, özgün yazı görünür kalır).
    /// </summary>
    public static bool KeepsNames(string text)
    {
        var parts = IconText.Plain(text).Trim().Split(" & ");
        if (parts.Length < 2) return false;
        // BÜYÜK HARFLİ yazıda her ad tek sözcük: "JASON & LUCIA MAP" (sekmeler tek satır okununca) ad değildir.
        var most = TextStyleSampler.IsUpper(IconText.Plain(text)) ? 1 : 2;
        return parts.All(part =>
        {
            var words = part.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            return words.Length >= 1 && words.Length <= most && words.All(word =>
                word.Count(char.IsLetter) >= 2 && word.All(c => char.IsLetter(c) || "'’-.".Contains(c))
                && char.IsUpper(word[0]) && !SpeakerNameGuard.NotNames.Contains(word.ToLowerInvariant()));
        });
    }

    private static readonly char[] IconBrackets = [' ', '(', ')', '[', ']'];

    /// <summary>
    /// Satırın başındaki ya da sonundaki kumanda simgesi (kareden tanınmış simge ya da okunmuş tuş adı: "RECENTER L3",
    /// "EXIT (○)") çeviriye girmez; kutu yalnız yazının sözcüklerini kapsar, simge ekranda görünür kalır. Önceden çeviri
    /// kutusu simgenin üstünü örtüyordu ("Ortala" L3'ü kapatıyordu, #860). Sözcük yerleri bilinmiyorsa harf sayısına göre
    /// kestirilir. Geriye tuş adı olmayan iki harfli bir sözcük kalmayacaksa (yalnız tuştan oluşan satır) dokunulmaz.
    /// </summary>
    public static TextLine WithoutEdgeIcons(TextLine line)
    {
        if (line.Box is not { } box) return line;
        var original = line.Text.Trim();
        var text = original;
        var icons = (line.Icons ?? []).ToList();
        if (text.Count(c => c == ButtonIcons.Marker) != icons.Count) return line;
        double left = box.Left, right = box.Right;
        // Kareden tanınmış simgeler (yazıda imle).
        while (icons.Count > 0 && text.Trim(IconBrackets) is { Length: > 0 } tail && tail[^1] == ButtonIcons.Marker)
        {
            text = tail[..^1].Trim(IconBrackets);
            right = Math.Min(right, icons[^1].Box.Left);
            icons.RemoveAt(icons.Count - 1);
        }
        while (icons.Count > 0 && text.Trim(IconBrackets) is { Length: > 0 } head && head[0] == ButtonIcons.Marker)
        {
            text = head[1..].Trim(IconBrackets);
            left = Math.Max(left, icons[0].Box.Right);
            icons.RemoveAt(0);
        }
        IReadOnlyList<TextWord>? words;
        if (text == original)
        {
            // Okunmuş tuş adı ("L3", "(R3)").
            if (text.Contains(ButtonIcons.Marker)) return line;
            var measured = line.Words is { Count: > 0 } && string.Join(' ', line.Words.Select(word => word.Text)) == text;
            var list = (measured ? line.Words! : ButtonIcons.Estimate(text, box)).ToList();
            while (list.Count > 1 && ButtonIcons.IsButtonName(list[^1].Text))
            {
                right = Math.Min(right, list[^1].Box.Left);
                list.RemoveAt(list.Count - 1);
            }
            while (list.Count > 1 && ButtonIcons.IsButtonName(list[0].Text))
            {
                left = Math.Max(left, list[0].Box.Right);
                list.RemoveAt(0);
            }
            text = string.Join(' ', list.Select(word => word.Text));
            words = measured ? list : null;
        }
        else
        {
            words = line.Words?.Where(word => word.Box.Left >= left - 1e-6 && word.Box.Right <= right + 1e-6).ToList();
        }
        if (text == original || right <= left
            || !text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
                .Any(word => word.Count(char.IsLetter) >= 2 && !ButtonIcons.IsButtonName(word))) return line;
        return line with
        {
            Text = text,
            Icons = icons.Count > 0 ? icons : null,
            Words = words is { Count: > 0 } ? words : null,
            Box = new TextBox(left, box.Top, right, box.Bottom),
        };
    }


    /// <summary>Satırın ve sözcüklerinin fiyat düzeltmesi (uzunluk değişmez).</summary>
    internal static TextLine Repaired(TextLine line) => line with
    {
        Text = PriceText.Repair(line.Text),
        Words = line.Words is { } words ? [.. words.Select(word => word with { Text = PriceText.Repair(word.Text) })] : null,
    };

    /// <summary>
    /// Tuş çubuğunun etiketleri: tuş adları ve simgeleri ("R1", "△", okunmuş "X"/"O"), fiyatlar ("$10") ve harfsiz
    /// parçalar ayırıcıdır, çeviriye girmez; aralarındaki her sözcük öbeği ayrı satır olur, kutusu sözcüklerinin yeri.
    /// Sözcük yerleri biliniyorsa geniş boşluk da ayırır ("TIP $10   ORDER   BARTENDER"). İki harfi olmayan öbek atılır.
    /// </summary>
    internal static IReadOnlyList<TextLine> PromptPieces(TextLine line)
    {
        if (line.Box is not { } box) return [line];
        var measured = line.Words is { Count: > 0 };
        var words = measured ? line.Words! : ButtonIcons.Estimate(line.Text, box);
        var gap = measured ? WideGap(words) : double.PositiveInfinity;
        var runs = new List<List<TextWord>> { new() };
        foreach (var word in words)
        {
            if (IsPromptSeparator(word.Text))
            {
                runs.Add([]);
                continue;
            }
            if (runs[^1].Count > 0 && word.Box.Left - runs[^1][^1].Box.Right > gap) runs.Add([]);
            runs[^1].Add(word);
        }
        return [.. runs.Where(run => run.Sum(word => word.Text.Count(char.IsLetter)) >= 2).Select(run =>
        {
            var span = run.Select(word => word.Box).Aggregate((a, b) => a.Union(b));
            return new TextLine(string.Join(' ', run.Select(word => word.Text)), new TextBox(span.Left, box.Top, span.Right, box.Bottom),
                                line.Confidence, run);
        })];
    }

    /// <summary>Sözcüklerin arasında bu kadar boşluk (harf başına ortalama genişliğin üç katı) ayrı seçenek demektir.</summary>
    private static double WideGap(IReadOnlyList<TextWord> words)
    {
        var chars = words.Sum(word => word.Text.Length);
        return chars == 0 ? double.PositiveInfinity : words.Sum(word => word.Box.Right - word.Box.Left) / chars * 3;
    }

    /// <summary>Sözcük yerleri bilinen satırda aynı satıra düşmüş ayrı seçenekler var mı (geniş boşluk).</summary>
    internal static bool HasWideGap(TextLine line)
    {
        if (line.Words is not { Count: >= 2 } words) return false;
        var gap = WideGap(words);
        return words.Zip(words.Skip(1)).Any(pair => pair.Second.Box.Left - pair.First.Box.Right > gap);
    }

    /// <summary>Tuş çubuğunda çeviriye girmeyen parça: tuş adı/simgesi, tek harf (okunmuş simge), fiyat ya da harfsiz parça.</summary>
    internal static bool IsPromptSeparator(string word)
    {
        var core = word.Trim('(', ')', '[', ']', '{', '}', '<', '>');
        // "&" sekme adının parçasıdır ("JASON & LUCIA"), ayırıcı değil.
        return ButtonIcons.IsButtonName(core) || PriceText.IsMoney(core) || (!core.Any(char.IsLetter) && core != "&")
            || (core.Length == 1 && core != "a");
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
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Any(word => word.Count(char.IsLetter) >= 2)
        && !IsDistance(text);

    /// <summary>
    /// Yalnız sayı ve uzaklık birimi: "124 ft", "4 ft", "2.4 mi", "300m", "1,2 km", "50 yd". Haritada kartın yanındaki uzaklık
    /// göstergedir, çevrilmez (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal static bool IsDistance(string text) =>
        System.Text.RegularExpressions.Regex.IsMatch(text, @"^\s*\d[\d.,]*\s?(ft|m|mi|km|yd|yds)\s*$",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);

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
