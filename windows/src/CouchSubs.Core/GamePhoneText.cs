// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.RegularExpressions;

namespace CouchSubs.Core;

internal static partial class GamePhoneText
{
    // Hesap ve etiket satırı zaten telefonun üstünde okunabilir. Çeviri kutusu onu örtmesin.
    [GeneratedRegex(@"(?<![\p{L}\p{N}_])[@#][\p{L}\p{N}_]+(?:[.-][\p{L}\p{N}_]+)*")]
    private static partial Regex Identifier();

    // Aynı uzun mesajda yan yana iki kısa sözcükte birer harf oynamış ("it out" → "ct ocut").
    // Tek kelimelik seçenekler, eklenen/silinen sözcükler, sayılar ve olumsuzluklar doğrudan işlenir.
    internal static bool HasAdjacentOcrEdits(string shown, string next)
    {
        var before = TextMatch.Normalize(shown).Split(' ');
        var after = TextMatch.Normalize(next).Split(' ');
        if (before.Length < 9 || before.Length != after.Length) return false;
        int first = 0, last = before.Length - 1;
        while (first <= last && before[first] == after[first]) first++;
        while (last > first && before[last] == after[last]) last--;
        if (last != first + 1) return false;
        for (int i = first; i <= last; i++)
        {
            var a = before[i];
            var b = after[i];
            int length = Math.Max(a.Length, b.Length);
            if (Math.Min(a.Length, b.Length) < 2 || length > 6 || !a.All(char.IsLetter) || !b.All(char.IsLetter)
                || !TextMatch.IsSimilar(a, b, 1.0 - 1.0 / length)) return false;
        }
        return !TextMatch.AddsMeaning(next, shown) && !TextMatch.AddsMeaning(shown, next);
    }

    internal static bool ContainsIdentifier(string text) =>
        (text.Contains('@') || text.Contains('#')) && Identifier().IsMatch(text);

    // Sayıyla başlayan gerçek mesaj sözcüklerini altyazı gürültü filtresinden geçir.
    // @hesap, etiket, ürün ve yer kodlarının içini değiştirme.
    [GeneratedRegex(@"(?<![\p{L}\p{N}_@#.-])(?:2gether|4u)(?![\p{L}\p{N}_])")]
    private static partial Regex ChatWord();

    [GeneratedRegex(@"(?<![\p{L}\p{N}_@#])(?:IO|I0|lO|l0)(?=\s+min(?:s|utes?)?\b)")]
    private static partial Regex MisreadTenMinutes();

    internal static bool IsWrittenChatWord(string token) => (token.Contains('2') || token.Contains('4')) && ChatWord().IsMatch(token);

    internal static string EnglishModelInput(string text)
    {
        // Açık bir süre birimi yoksa I/1 veya O/0 hakkında karar verme.
        if (text.Contains("min", StringComparison.Ordinal)) text = MisreadTenMinutes().Replace(text, "10");
        return !IsWrittenChatWord(text) ? text :
            ChatWord().Replace(text, word => word.Value == "2gether" ? "together" : "for you");
    }

    private static bool IsTag(string word) => word.Length > 1 && word[0] is '@' or '#'
        && Identifier().Match(word) is { Success: true, Index: 0 } token && token.Length == word.Length;

    internal static string? KeepIdentifiers(string source, string? translation)
    {
        if (string.IsNullOrEmpty(translation) || !ContainsIdentifier(source)) return translation;
        var names = Identifier().Matches(source).Select(m => m.Value).ToList();
        bool unexpected = false;
        var restored = Identifier().Replace(translation, match =>
        {
            int i = names.FindIndex(n => string.Equals(n, match.Value, StringComparison.OrdinalIgnoreCase));
            if (i < 0) { unexpected = true; return match.Value; }
            string original = names[i];
            names.RemoveAt(i);
            return original;
        });
        // Yanlış kişiye yönlendiren çeviriyi göstermemek için bu bloğun aslı ekranda kalır.
        return unexpected || names.Count != 0 ? null : restored;
    }

    /// <summary>
    /// Çeviriye gidecek satırlar. Sohbet listesi (Mesajlar ekranı: "Suggested", "Messages", kişi adı ve altında son mesajın
    /// önizlemesi) tanınırsa her satır rolüyle işaretlenir (<see cref="TextLine.ListRole"/>): kişi adı (çevrilmez, kalın),
    /// önizleme (altında, çevrilir), bölüm başlığı. Liste için kişi adı sütununda en az üç "ad + önizleme" çifti ve bir bölüm
    /// başlığı (ya da başlık okunamadıysa "…" ile kesilmiş en az iki önizleme) gerekir. Önceden iki başlığın ikisi de
    /// okunmalıydı: sallanan telefonda biri her okumada kaçıyor, liste bir sohbet balonları bir düz satırlar olarak gidip
    /// geliyordu (LG, beta.93). Kişi adları da atılıyordu; şimdi listede adıyla görünür. Mac ile aynı.
    ///
    /// Liste değilse ve ekran sohbet dışıysa (<see cref="PhoneScreen.KindOf"/>: gönderi, haber, makale, hava, fitness,
    /// ayarlar, eklenti) satırlar kartlarına ayrılır (<see cref="TextLine.PhoneCard"/>); çevrilmeyen satırlar (kullanıcı adı,
    /// saat, geri düğmesi, konum, fotoğraf yazısı, kaynak adı) atılır. Ana ekran kendi kurallarında kalır
    /// (<see cref="PhoneChat.IsHomeScreen"/>; Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal static Reading ForTranslation(Reading reading)
    {
        var list = Listed(reading);
        if (list.Lines.Any(line => line.ListRole.HasValue) || PhoneChat.IsHomeScreen(list.Lines)) return list;
        return Screen(reading) ?? list;
    }

    /// <summary>Sohbet dışı ekranın kartları (<see cref="PhoneScreen.Cards"/>); ekran sohbetse ya da satırların düz yeri bilinmiyorsa null.</summary>
    internal static Reading? Screen(Reading reading)
    {
        var all = reading.Lines.Where(line => line.PhoneBox.HasValue).ToList();
        if (all.Count == 0) return null;
        var lines = all.Select(line => new PhoneScreen.Line(line.Text, line.PhoneBox!.Value)).ToList();
        var kind = PhoneScreen.KindOf(lines);
        if (kind == PhoneScreen.Kind.Chat) return null;
        var result = new List<TextLine>();
        var cards = PhoneScreen.Cards(lines, kind);
        for (var number = 0; number < cards.Count; number++)
        {
            var card = cards[number];
            for (var position = 0; position < card.Lines.Count; position++)
                result.Add(all[card.Lines[position]] with
                {
                    ListRole = ScreenPhoneCard.Role.Card,
                    PhoneCard = new PhoneScreen.Mark(number, card.Titled && position == 0, card.Bold),
                });
        }
        return new Reading(result);
    }

    private static Reading Listed(Reading reading)
    {
        var lines = new List<TextLine>();
        foreach (var line in reading.Lines)
        {
            var words = line.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (words.Any(IsTag) && words.All(w => IsTag(w) || !w.Any(char.IsLetterOrDigit))) continue;
            lines.Add(line);
        }

        // Kişi adını tek başına büyük harften çıkarmak "May" gibi kısa gerçek mesajları kaybettirir.
        // Yalnız aynı sütunda tekrarlanan ad/önizleme düzeni ve bir başlık (ya da kesik önizlemeler) varsa liste sayılır.
        lines = lines.Select(l => SectionLabel(l.Text) is { } label ? l with { Text = label } : l).ToList();
        var headed = lines.Any(l => SectionLabel(l.Text) is not null);
        var order = Enumerable.Range(0, lines.Count).Where(i => LayoutBox(lines[i]).HasValue)
            .OrderBy(i => LayoutBox(lines[i])!.Value.Top).ToList();
        var names = new List<int>();
        var previews = new HashSet<int>();
        for (int i = 0; i + 1 < order.Count; i++)
        {
            var name = order[i];
            var preview = order[i + 1];
            if (!lines[preview].Text.Trim().Contains(' ') || !IsContactPair(lines[name], lines[preview])) continue;
            names.Add(name);
            previews.Add(preview);
            i++;
        }
        if (names.Count < 3) return new Reading(lines);
        var first = LayoutBox(lines[names[0]])!.Value;
        var last = LayoutBox(lines[names[^1]])!.Value;
        if (last.Top <= first.Top) return new Reading(lines);
        if (!headed && previews.Count(i => IsCut(lines[i].Text)) < 2) return new Reading(lines);
        double slope = (last.Left - first.Left) / (last.Top - first.Top);
        bool InNameColumn(TextLine line) => LayoutBox(line) is { } box &&
            Math.Abs(box.Left - (first.Left + slope * (box.Top - first.Top))) <= 0.06;
        if (!names.All(i => InNameColumn(lines[i]))) return new Reading(lines);
        // Listeyi uzun önizlemeler doğruladı. Aynı satır düzenindeki "Okay" gibi kısa bir yanıt
        // tek başına kişi adına benziyor diye ad sayılmaz; önizlemesi olarak kalır.
        for (int i = 0; i + 1 < order.Count; i++)
        {
            var name = order[i];
            var preview = order[i + 1];
            if (!InNameColumn(lines[name]) || previews.Contains(name) || names.Contains(preview) ||
                lines[preview].Text.Trim().Contains(' ') || !LooksLikeName(lines[preview].Text) ||
                !IsContactPair(lines[name], lines[preview])) continue;
            names.Add(name);
            previews.Add(preview);
            i++;
        }
        // Önizlemesi boş kişilerin adı da aynı eğik sütunda, aynı satır düzenindedir.
        return new Reading(lines.Select((line, index) =>
            previews.Contains(index) ? PreviewPunctuation(line) with { ListRole = ScreenPhoneCard.Role.Preview }
            : SectionLabel(line.Text) is not null ? line with { ListRole = ScreenPhoneCard.Role.Heading }
            : InNameColumn(line) && (names.Contains(index) || LooksLikeName(line.Text)) ? line with { ListRole = ScreenPhoneCard.Role.Contact }
            : line with { ListRole = ScreenPhoneCard.Role.Preview }));
    }

    /// <summary>Telefonun "…" ile kestiği önizleme ("Hey this is Joey from Coa..."). Mac ile aynı.</summary>
    internal static bool IsCut(string text)
    {
        var value = text.Trim();
        return value.EndsWith("...", StringComparison.Ordinal) || value.EndsWith('…');
    }

    private static readonly HashSet<string> DanglingWords =
    [
        "a", "an", "the", "of", "to", "in", "on", "at", "for", "from", "with", "by", "about", "and", "but", "or", "so",
        "than", "my", "your", "his", "her", "its", "our", "their", "this", "that", "is", "are", "was", "were", "be", "i",
        "you", "we", "they", "it", "if", "as",
    ];

    /// <summary>
    /// Kesik önizlemenin çevrilecek kısmı: telefon son sözcüğü yarıda keser ("Coa...", "in t..."), yazı tanıma da üç
    /// noktanın önündeki boşluğu güvenilir okumaz; son sözcük her zaman atılır, ardından kalan bağlaç/edat ("from", "in",
    /// "than") da. Çeviri "..." ile biter (<see cref="CutTranslation"/>): önceden "Hey this is Joey from Coa..." "Selam,
    /// ben Coa'dan Joey..." çevriliyor, yarım sözcük uyduruluyordu. Kesik değilse ya da geriye bir sözcük bile kalmazsa
    /// null. Mac ile aynı.
    /// </summary>
    internal static string? CutInput(string text)
    {
        if (!IsCut(text)) return null;
        var value = text.Trim().TrimEnd('.', '…');
        var words = value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
        if (words.Count < 2) return null;
        words.RemoveAt(words.Count - 1);
        while (words.Count > 1 && DanglingWords.Contains(TrimPunctuation(words[^1].ToLowerInvariant()))) words.RemoveAt(words.Count - 1);
        var core = string.Join(' ', words).TrimEnd(',', ';', ':', '-', '–', '—').Trim();
        return core.Any(char.IsLetter) ? core : null;
    }

    private static string TrimPunctuation(string word)
    {
        int start = 0, end = word.Length;
        while (start < end && char.IsPunctuation(word[start])) start++;
        while (end > start && char.IsPunctuation(word[end - 1])) end--;
        return word[start..end];
    }

    /// <summary>
    /// Önizleme satırın sağ kenarına bu kadar yakınsa (düz ekranda) ve cümle sonu yoksa telefon onu "…" koymadan kesmiştir
    /// ("$ in your mailbox. You bailed": aslı "...You bailed me out again bro!").
    /// </summary>
    internal const double ClipEdge = 0.88;

    /// <summary>
    /// "…" olmadan kesilmiş önizlemenin çevrilecek kısmı: sözcükler kalır (son sözcük tam görünüyor), sondaki bağlaç/edat
    /// atılır. Sinan Bey (beta.100, 3399): "$ in your mailbox. You bailed" bağlamsız çevrilip "Posta kutunda. Beni aradın"
    /// oluyordu. Cümle sonuyla biten ya da tek sözcüklük önizleme kesik sayılmaz (null). Mac ile aynı.
    /// </summary>
    internal static string? ClippedInput(string text)
    {
        var value = text.Trim();
        if (value.Length == 0 || ".!?…\"')".Contains(value[^1])) return null;
        var words = value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
        if (words.Count < 2) return null;
        while (words.Count > 1 && DanglingWords.Contains(TrimPunctuation(words[^1].ToLowerInvariant()))) words.RemoveAt(words.Count - 1);
        var core = string.Join(' ', words).TrimEnd(',', ';', ':', '-', '–', '—').Trim();
        return core.Any(char.IsLetter) ? core : null;
    }

    /// <summary>Kesik önizlemenin motora giden hâli: sonuna "..." eklenir; motor metnin kesik olduğunu görür, sonunu tamamlamaz.</summary>
    internal static string CutHint(string core) => core + "...";

    /// <summary>Kaynağın başındaki para simgesi ("$ in your mailbox") çeviride düştüyse başa geri konur. Mac ile aynı.</summary>
    internal static string KeepingLeadingSymbol(string source, string translation)
    {
        var value = source.Trim();
        if (value.Length == 0 || char.GetUnicodeCategory(value[0]) != System.Globalization.UnicodeCategory.CurrencySymbol
            || translation.Contains(value[0])) return translation;
        var glued = value.Length > 1 && !char.IsWhiteSpace(value[1]);
        return value[0] + (glued ? "" : " ") + translation.Trim();
    }

    /// <summary>
    /// Sohbetten tam çevirisi bilinen mesajın kesik önizlemesi: önizlemenin (kesik ya da "…"sız kesilmiş) sadeleştirilmiş
    /// hâliyle başlayan bilinen en kısa mesajın çevirisinin aynı oranda başı + "...". Uydurma değil, sohbette gösterilen
    /// çevirinin kendisidir. Önizleme en az <see cref="PreviewLetters"/> harf olmalı; bulunmazsa null. Mac ile aynı.
    /// </summary>
    internal const int PreviewLetters = 8;
    internal static string? KnownPreview(string preview, IReadOnlyDictionary<string, string> known)
    {
        var core = preview.Trim().TrimEnd('.', '…');
        var words = TextMatch.Normalize(core).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // "…" ile kesilen önizlemenin son sözcüğü yarımdır ("Coa"): eşleşmeye girmez.
        var head = string.Join(' ', IsCut(preview) && words.Length > 1 ? words[..^1] : words);
        if (head.Count(char.IsLetter) < PreviewLetters) return null;
        var best = known
            .Where(pair =>
            {
                var full = TextMatch.Normalize(pair.Key);
                return full.Length > head.Length + 2 && full.StartsWith(head, StringComparison.Ordinal);
            })
            .OrderBy(pair => pair.Key.Length).ThenBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => (KeyValuePair<string, string>?)pair).FirstOrDefault();
        if (best is not { } chosen) return null;
        var ratio = head.Length / (double)Math.Max(1, TextMatch.Normalize(chosen.Key).Length);
        var target = (int)Math.Ceiling(chosen.Value.Length * ratio);
        var all = chosen.Value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var taken = new List<string>();
        var length = 0;
        foreach (var word in all)
        {
            if (taken.Count > 0 && length + 1 + word.Length > target + 2) break;
            length += (taken.Count == 0 ? 0 : 1) + word.Length;
            taken.Add(word);
        }
        if (taken.Count >= all.Length) return null;
        return CutTranslation(string.Join(' ', taken));
    }

    /// <summary>Kesik önizlemenin çevirisi: sondaki noktalama atılıp "..." eklenir (telefondaki gibi kesik görünür). Mac ile aynı.</summary>
    internal static string CutTranslation(string translation) =>
        translation.Trim().TrimEnd('.', ',', ';', ':', '…', '–', '—', '-').Trim() + "...";

    private static TextLine PreviewPunctuation(TextLine line)
    {
        // Liste sağ kenarda kesme işareti olarak üç nokta kullanıyor. Yalnız noktalama düzeltilir:
        // kırpılmış sözcüğün harfleri ve "ttv." gibi olası kısaltmalar tahmin edilmez.
        if (LayoutBox(line) is not { Right: >= .76 }) return line;
        int end = line.Text.Length, start = end;
        while (start > 0 && line.Text[start - 1] is '.' or ',' or '„') start--;
        if (end - start is < 2 or > 3 || line.Text[start] != '.') return line;
        int wordEnd = start;
        while (wordEnd > 0 && char.IsWhiteSpace(line.Text[wordEnd - 1])) wordEnd--;
        if (wordEnd == 0 || !char.IsLetter(line.Text[wordEnd - 1])) return line;
        if (wordEnd == start && line.Text.EndsWith("...", StringComparison.Ordinal)) return line;
        return line with { Text = line.Text[..wordEnd] + "..." };
    }

    private static TextBox? LayoutBox(TextLine line) => line.PhoneBox ?? line.Box;

    private static readonly string[] Headings = ["Messages", "Suggested", "Suggestions", "Öneriler", "Mesajlar"];

    /// <summary>
    /// Sohbet listesinin bölüm başlığı ("Suggested", "Messages"); değilse null. Başlığın yanındaki simge yazı tanımada tek
    /// harf ya da işaret olarak okunur ("g Suggested", "✱ Suggested", "Messages ☆"): o artık atılır. Önceden "g Suggested"
    /// başlık sayılmıyor, sallanan telefonda liste her okumada bir liste bir sohbet çiziliyor, TV'de "g Önerilen" yazıyordu.
    /// Simge artığı <see cref="ButtonIcons.IsIconToken"/> ile aynı tanımdadır (tek harf ya da işaret). Mac ile aynı.
    /// </summary>
    internal static string? SectionLabel(string text)
    {
        int first = 0, end = text.Length;
        while (first < end && !char.IsLetter(text[first])) first++;
        while (end > first && !char.IsLetter(text[end - 1])) end--;
        var value = text[first..end];
        if (Headings.Contains(value)) return value;
        var words = value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length is < 2 or > 3 || words.FirstOrDefault(Headings.Contains) is not { } heading) return null;
        var rest = words.Where(w => w != heading).ToArray();
        return rest.Length == words.Length - 1 &&
            rest.All(w => w.Length == 1 || ButtonIcons.IsIconToken(w) || !w.Any(char.IsLetter)) ? heading : null;
    }

    private static bool LooksLikeName(string text)
    {
        // Rehber, parantez içinde cihaz etiketi de gösterebilir.
        var label = text.Split('(', 2)[0].Trim();
        var words = label.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return SectionLabel(label) is null && words.Length is >= 1 and <= 4 && char.IsUpper(words[0][0]) &&
            words.All(w => (char.IsUpper(w[0]) || w is "de" or "du" or "of") &&
                           w.All(c => char.IsLetter(c) || c is '-' or '\''));
    }

    internal static bool IsMessagePreview(string text) =>
        text.Any(char.IsWhiteSpace) && SectionLabel(text) is null && !LooksLikeName(text);

    private static bool IsContactPair(TextLine name, TextLine preview)
    {
        var label = name.Text.Trim();
        bool lowerName = label.Length is >= 2 and <= 18 && label.All(char.IsLower);
        if (!LooksLikeName(label) && !lowerName) return false;
        var a = LayoutBox(name)!.Value;
        var b = LayoutBox(preview)!.Value;
        var h = a.Bottom - a.Top;
        return a.Left is > 0.10 and < 0.48 && Math.Abs(a.Left - b.Left) <= 0.06 &&
            b.Top > a.Top && b.Top - a.Bottom < h * 0.7 && b.Bottom - b.Top < h * 1.8;
    }

    // Konuşmada karşı kenara yaslanan yeni balon, önceki satır küçük harfle bitse bile ayrı çevrilir.
    /// <summary>
    /// Telefon ekranının blokları, kendi yerlerinde. Ana ekranda uygulama adları (WhatUp, simge etiketleri) çevrilmez
    /// (<see cref="PhoneChat.WithoutAppNames"/>); saat ve hava harfsiz satır olarak zaten atılır.
    /// </summary>
    internal static IReadOnlyList<ScreenTranslation.Group> Groups(Reading reading)
    {
        if (reading.Lines.Any(line => line.PhoneCard.HasValue)) return CardGroups(reading);
        var home = PhoneChat.IsHomeScreen(reading.Lines);
        reading = new Reading(PhoneChat.WithoutAppNames(reading.Lines));
        List<ScreenTranslation.Group> groups = [];
        List<TextLine> run = [];
        bool flat = reading.Lines.All(l => l.PhoneBox.HasValue);
        // Sohbet listesi (ForTranslation): her satır kendi satırıdır (ad ve altındaki önizleme ayrı), rolü okumadan gelir.
        bool listed = reading.Lines.Any(l => l.ListRole.HasValue);
        TextBox Layout(TextLine l) => (flat ? l.PhoneBox : l.Box)!.Value;
        void Finish()
        {
            if (run.Count == 0) return;
            if (flat)
            {
                var clean = WithoutRepeatedLines(new Reading(run).WithButtonIcons().WithoutButtonPrompts().WithoutOcrNoise(true).Lines
                    .Where(l => l.Box.HasValue && ScreenTranslation.IsWords(l.Text)).ToArray());
                if (clean.Length > 0)
                {
                    // Aynı balona sarılan satırlar birlikte çevrilir; TV konumu özgün oyun kutularından gelir.
                    var box = clean.Select(l => l.Box!.Value).Aggregate((a, b) => a.Union(b));
                    var heights = run.Select(l => Layout(l).Bottom - Layout(l).Top).Order().ToArray();
                    var icons = clean.SelectMany(l => l.Icons ?? []).ToArray();
                    // Düz ekrandaki yeri: sohbet panelinde tarafı (sol/sağ) ve sırası bundan çıkar (Roles).
                    var spot = run.Select(Layout).Aggregate((a, b) => a.Union(b));
                    groups.Add(new ScreenTranslation.Group([WithoutRepeat(string.Join(' ', clean.Select(l => l.Text)))], box,
                        heights[heights.Length / 2], icons.Length == 0 ? null : [icons])
                    {
                        Phone = new ScreenPhoneCard.Placement(
                            listed ? run[0].ListRole ?? ScreenPhoneCard.Role.Preview : ScreenPhoneCard.Role.Message, spot),
                    });
                }
            }
            else groups.AddRange(ScreenTranslation.Groups(new Reading(run), menuRows: false, keepIdentifiers: true));
            run.Clear();
        }
        foreach (var line in reading.Lines.Where(l => l.Box.HasValue).OrderBy(l => Layout(l).Top))
        {
            if (run.Count > 0)
            {
                var previous = run[^1];
                if (listed || BreaksBlock(Layout(previous), Layout(line), flat && EndsSentence(previous.Text))) Finish();
            }
            run.Add(line);
        }
        Finish();
        var kept = groups.Count <= ScreenTranslation.MaxGroups ? groups : groups.GetRange(0, ScreenTranslation.MaxGroups);
        if (listed && flat && kept.Count > 0) return kept;
        var placed = Roles(kept, home);
        return home ? Widgets(placed) : placed;
    }

    /// <summary>
    /// Sohbet dışı ekranın kartları (<see cref="ForTranslation"/> işaretledi): her kart bir grup, telefondaki sırasıyla.
    /// Başlıklı kartın başlığı ayrı paragraf (kalın çizilir), gövdesi tek paragraf; alt satıra sarılmış cümle birleşir
    /// (tireyle bölünmüş sözcük boşluksuz). Grubun rolü <see cref="ScreenPhoneCard.Role.Card"/>, düz ekrandaki yeri kartın
    /// satırlarının birleşimi (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal static IReadOnlyList<ScreenTranslation.Group> CardGroups(Reading reading)
    {
        var marked = reading.Lines.Where(line => line.PhoneCard.HasValue && line.Box.HasValue && line.PhoneBox.HasValue).ToList();
        var groups = new List<ScreenTranslation.Group>();
        foreach (var number in marked.Select(line => line.PhoneCard!.Value.Card).Distinct().Order())
        {
            var run = marked.Where(line => line.PhoneCard!.Value.Card == number).ToList();
            var clean = new Reading(run).WithoutOcrNoise(true).Lines
                .Where(line => line.Box.HasValue && line.PhoneBox.HasValue && ScreenTranslation.IsWords(line.Text)).ToList();
            if (clean.Count == 0) continue;
            var mark = run[0].PhoneCard!.Value;
            var titled = clean.Count >= 2 && clean[0].PhoneCard?.Title == true;
            static string Joined(IEnumerable<TextLine> lines)
            {
                var text = "";
                foreach (var line in lines)
                {
                    var part = line.Text.Trim(' ', '\t');
                    if (text.Length == 0) text = part;
                    else if (text.EndsWith('-')) text += part;
                    else text += " " + part;
                }
                return text;
            }
            IReadOnlyList<string> paragraphs = titled ? [clean[0].Text.Trim(' ', '\t'), Joined(clean.Skip(1))] : [Joined(clean)];
            var boxes = clean.Select(line => line.Box!.Value).ToList();
            var spots = clean.Select(line => line.PhoneBox!.Value).ToList();
            var heights = spots.Select(spot => spot.Bottom - spot.Top).Order().ToList();
            groups.Add(new ScreenTranslation.Group(paragraphs, boxes.Skip(1).Aggregate(boxes[0], (a, b) => a.Union(b)),
                heights[(heights.Count - 1) / 2])
            {
                Phone = new ScreenPhoneCard.Placement(ScreenPhoneCard.Role.Card, spots.Skip(1).Aggregate(spots[0], (a, b) => a.Union(b)),
                    titled, mark.Bold),
            });
        }
        return groups.Count <= ScreenTranslation.MaxGroups ? groups : groups.GetRange(0, ScreenTranslation.MaxGroups);
    }

    /// <summary>"Reminders 10 Notifications": bir-üç sözcüklük harfli başlık ve ardından sayaç; değilse null. Mac ile aynı.</summary>
    internal static (string Title, string Counter)? WidgetParts(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        for (var count = 1; count <= 3 && count < words.Length; count++)
        {
            string title = string.Join(' ', words[..count]), counter = string.Join(' ', words[count..]);
            if (PhoneChat.IsCounter(counter) && !title.Any(char.IsNumber) && title.Any(char.IsLetter)) return (title, counter);
        }
        return null;
    }

    /// <summary>
    /// Ana ekranda bileşen başlığı ve hemen altındaki sayaç ("Reminders" / "6 Notifications") tek grup olur: panelde tek kart
    /// (<see cref="ScreenPhoneCard.Role.Widget"/>; "Ekranı çevir"de <see cref="PhoneChat.IsWidget"/>). Başlığın solunda simge
    /// olduğundan ikisi ayrı blok okunuyordu ve bileşen çevrilmiyordu (Sinan Bey, beta.100 3397). Mac ile aynı.
    /// </summary>
    internal static IReadOnlyList<ScreenTranslation.Group> Widgets(IReadOnlyList<ScreenTranslation.Group> groups)
    {
        var result = new List<ScreenTranslation.Group>();
        foreach (var group in groups)
        {
            var text = string.Join(' ', group.Paragraphs);
            // Başlık ve sayaç tek satır grubu okunduysa ("Reminders 10 Notifications") ikiye ayrılır.
            if (group.Phone is { Role: ScreenPhoneCard.Role.Home } home && group.Paragraphs.Count == 1 && WidgetParts(text) is { } split)
            {
                result.Add(group with
                {
                    Paragraphs = [split.Title, split.Counter],
                    Icons = null,
                    Phone = new ScreenPhoneCard.Placement(ScreenPhoneCard.Role.Widget, home.Spot),
                });
                continue;
            }
            if (PhoneChat.IsCounter(text) && group.Phone?.Spot is { } spot && result.Count > 0 && result[^1] is var last
                && last.Phone?.Spot is { } above && last.Phone.Role == ScreenPhoneCard.Role.Home && last.Paragraphs.Count == 1
                && !PhoneChat.IsCounter(last.Paragraphs[0])
                && last.Paragraphs[0].Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length is >= 1 and <= 3
                && spot.Top >= above.Top && spot.Top - above.Bottom < (above.Bottom - above.Top) * PhoneChat.HomeGap
                && spot.Left <= above.Left + PhoneChat.LeftAlign && above.Left - spot.Left <= PhoneChat.WidgetIndent)
            {
                result[^1] = last with
                {
                    Paragraphs = [last.Paragraphs[0], text],
                    Box = last.Box.Union(group.Box),
                    Phone = new ScreenPhoneCard.Placement(ScreenPhoneCard.Role.Widget, above.Union(spot)),
                };
                continue;
            }
            result.Add(group);
        }
        return result;
    }

    /// <summary>
    /// Sohbet panelinde her grubun rolü ("Ekranı çevir"in <see cref="PhoneChat"/> kuralları, düz ekrandaki yerinden): en
    /// üstteki kısa ad satırı kişinin adıdır (çevrilmez), ortalı kısa satır not, sağa yaslı balon oyuncunun, sola yaslı
    /// karşı tarafın mesajı. Sohbet listesinde önizlemeler, ana ekranda bütün yazılar kendi yerinde kalır. Mac ile aynı.
    /// </summary>
    internal static IReadOnlyList<ScreenTranslation.Group> Roles(IReadOnlyList<ScreenTranslation.Group> groups, bool home)
    {
        if (!groups.All(group => group.Phone is not null)) return [.. groups.Select(group => group with { Phone = null })];
        var list = groups.Any(group => SectionLabel(string.Concat(group.Paragraphs)) is not null);
        var first = -1;
        for (var i = 0; i < groups.Count; i++)
            if (first < 0 || groups[i].Phone!.Spot.Top < groups[first].Phone!.Spot.Top) first = i;
        return [.. groups.Select((group, index) =>
        {
            var text = string.Join(' ', group.Paragraphs);
            var spot = group.Phone!.Spot;
            var row = new PhoneChat.Row([], spot, text);
            var role = home ? ScreenPhoneCard.Role.Home
                : index == first && !list && PhoneChat.IsHeader(row) ? ScreenPhoneCard.Role.Header
                : list ? (SectionLabel(text) is not null ? ScreenPhoneCard.Role.Heading : ScreenPhoneCard.Role.Preview)
                : PhoneChat.RoleOf([row]);
            return group with { Phone = new ScreenPhoneCard.Placement(role, spot) };
        })];
    }

    private static bool EndsSentence(string text) => text.TrimEnd().LastOrDefault() is '.' or '!' or '?';

    /// <summary>
    /// Art arda iki kez yazılmış metin ("A. B. A. B.") bir kez: OCR aynı satırı iki kutuda okuyunca ya da motor çeviriyi iki
    /// kez yazınca balonda aynı paragraf art arda iki kez görünüyordu (X, 22 Kas). Metin sözcük sözcük ikiye bölünür (en az
    /// dört sözcük); iki yarı aynı mesajsa (<see cref="PhoneSteady.SameReading"/>) ilk yarı kalır (Mac ile aynı).
    /// </summary>
    internal static string WithoutRepeat(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length < 4 || words.Length % 2 != 0) return text;
        int half = words.Length / 2;
        string first = string.Join(' ', words.Take(half)), second = string.Join(' ', words.Skip(half));
        if (!TextMatch.Normalize(first).Any(char.IsLetter) || !PhoneSteady.SameReading(first, second)) return text;
        return first;
    }

    /// <summary>
    /// Aynı balonda bir öncekiyle aynı (<see cref="PhoneSteady.SameReading"/>) ya da bir öncekinin içinde kalan satır atılır:
    /// soluk satır bazen hem tam hem parça olarak iki kutuda okunur (Mac ile aynı).
    /// </summary>
    internal static TextLine[] WithoutRepeatedLines(IReadOnlyList<TextLine> lines)
    {
        var kept = new List<TextLine>();
        foreach (var line in lines)
        {
            if (kept.Count > 0)
            {
                var previous = kept[^1];
                string a = TextMatch.Normalize(previous.Text), b = TextMatch.Normalize(line.Text);
                if (PhoneSteady.SameReading(previous.Text, line.Text)
                    || (b.Length >= 6 && 2 * b.Length >= a.Length && b.Count(char.IsLetter) >= 4 && a.Contains(b, StringComparison.Ordinal)))
                    continue;
            }
            kept.Add(line);
        }
        return [.. kept];
    }

    private static bool BreaksBlock(TextBox previous, TextBox next, bool afterFlatSentence)
    {
        // Düzeltilmiş telefon görüntüsünde satır arası dar, ardışık balonlar arasındaki boşluk daha geniştir.
        // Cümle sonunda bu aralığı kullan; aynı balonda alt satıra geçen ikinci cümle birlikte kalır.
        var lineHeight = Math.Max(previous.Bottom - previous.Top, next.Bottom - next.Top);
        if (next.Top - previous.Bottom > lineHeight * (afterFlatSentence ? 0.65 : 1)) return true;
        bool alignedLeft = Math.Abs(previous.Left - next.Left) <= 0.08;
        bool alignedRight = Math.Min(previous.Left, next.Left) > 0.25 && Math.Abs(previous.Right - next.Right) <= 0.045;
        return !alignedLeft && !alignedRight;
    }
}
