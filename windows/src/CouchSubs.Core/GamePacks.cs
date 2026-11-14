// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using CouchSubs.Core.Dubbing;

namespace CouchSubs.Core;

/// <summary>
/// Oyun paketinin anahtarı: ekranda okunan İngilizce satırın sadeleştirilmiş hâlinin SHA-256'sının ilk 8 baytı (hex).
/// Paketlerde İngilizce metin yoktur, yalnız bu anahtar ve Türkçesi. Mac'teki CouchSubsCore/GamePacks.swift ile
/// birebir aynı adımlar; ortak deneme verisi core/Tests/CouchSubsCoreTests/Fixtures/golden-vectors.json.
/// </summary>
public static class PackKey
{
    /// <summary>Biçim etiketi: en çok 40 karakterlik <c>&lt;…&gt;</c> ("&lt;b&gt;", "&lt;/&gt;").</summary>
    internal const int MaxTagLength = 40;

    /// <summary>
    /// 1. etiketler boşluk olur, 2. NFKC, 3. küçük harf, 4. NFD ile aksan ve işaretler atılır,
    /// 5. harf ve rakam dışındaki her şey boşluk olur, 6. boşluklar teklenir, baş ve son kırpılır.
    /// </summary>
    public static string Canon(string text)
    {
        // .NET'in değişmez küçük harfi "İ"yi (U+0130) olduğu gibi bırakıyor; Python ve Swift Unicode'un tam eşlemesiyle
        // "i" + üst nokta yapar (nokta 4. adımda atılır). Aynı sonuç için önce o eşleme uygulanır.
        var lowered = Normalize(StripTags(text), NormalizationForm.FormKC).Replace("İ", "i̇", StringComparison.Ordinal).ToLowerInvariant();
        var output = new StringBuilder(lowered.Length);
        var gap = false;
        foreach (var rune in Normalize(lowered, NormalizationForm.FormD).EnumerateRunes())
        {
            switch (Rune.GetUnicodeCategory(rune))
            {
                case UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark:
                    continue;
                case UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
                    or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
                    or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber:
                    if (gap && output.Length > 0) output.Append(' ');
                    gap = false;
                    output.Append(rune.ToString());
                    break;
                default:
                    gap = true;
                    break;
            }
        }
        return output.ToString();
    }

    /// <summary>16 haneli küçük harf hex anahtar; satırda harf ya da rakam yoksa null.</summary>
    public static string? Key(string text)
    {
        var canon = Canon(text);
        if (canon.Length == 0) return null;
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(canon));
        return Convert.ToHexStringLower(hash, 0, 8);
    }

    /// <summary>Anahtarın sayı hâli (sözlükte daha az yer tutar); geçersizse null.</summary>
    public static ulong? Number(string key) =>
        key.Length == 16 && ulong.TryParse(key, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var value) ? value : null;

    /// <summary>
    /// <c>&lt;…&gt;</c> etiketlerini (en çok 40 karakter, içinde &lt; ya da &gt; yok) <paramref name="replacement"/> ile değiştirir.
    /// Python'daki <c>re.sub(r"&lt;[^&lt;&gt;]{0,40}&gt;", " ", s)</c> ile aynı: kod noktası sayılır.
    /// </summary>
    public static string StripTags(string text, string replacement = " ")
    {
        if (!text.Contains('<')) return text;
        var runes = text.EnumerateRunes().ToArray();
        var output = new StringBuilder(text.Length);
        var index = 0;
        while (index < runes.Length)
        {
            if (runes[index].Value == '<')
            {
                var end = index + 1;
                while (end < runes.Length && end - index - 1 <= MaxTagLength && runes[end].Value != '<' && runes[end].Value != '>') end++;
                if (end < runes.Length && runes[end].Value == '>' && end - index - 1 <= MaxTagLength)
                {
                    output.Append(replacement);
                    index = end + 1;
                    continue;
                }
            }
            output.Append(runes[index].ToString());
            index++;
        }
        return output.ToString();
    }

    /// <summary>Bozuk UTF-16 (tek başına vekil karakter) normalleştirmeyi durdurmasın.</summary>
    private static string Normalize(string text, NormalizationForm form)
    {
        try { return text.Normalize(form); }
        catch (ArgumentException)
        {
            var clean = new StringBuilder(text.Length);
            foreach (var rune in text.EnumerateRunes()) clean.Append(rune.ToString());
            return clean.ToString().Normalize(form);
        }
    }
}

/// <summary>
/// Bir oyunun çeviri paketi. Dosya gzip'li JSON'dur: <c>{"format":1,"id":…,"title":…,"entries":{anahtar: Türkçe}}</c>;
/// yalnız <c>{anahtar: Türkçe}</c> nesnesi de kabul edilir (adı dosya adından gelir). Biçim 2 ayrıca <c>segments</c>
/// (oyunun ayrı gösterdiği parçalar, çok cümleli satırların cümleleri ve Türkçesi İngilizcesiyle aynı satırlar; aynı
/// <c>{anahtar: Türkçe}</c> düzeni) ve <c>fuzzy</c> (OCR'ın bozduğu satırı bulmak için imzalar, bkz. <see cref="PackFuzzy"/>)
/// taşır; İngilizce metin yine yoktur.
/// </summary>
public sealed class GamePack(string id, string title, IReadOnlyDictionary<ulong, string> entries,
    IReadOnlyDictionary<ulong, string>? segments = null, IReadOnlyList<ulong>? keys = null, PackFuzzyIndex? fuzzy = null)
{
    public string Id { get; } = id;
    public string Title { get; } = title;
    public IReadOnlyDictionary<ulong, string> Entries { get; } = entries;
    public IReadOnlyDictionary<ulong, string> Segments { get; } = segments ?? new Dictionary<ulong, string>();
    /// <summary>Paketteki bütün anahtarlar (entries + segments), sayı sırasıyla: satırın hangi paketten geldiği buradan bulunur.</summary>
    internal IReadOnlyList<ulong> Keys { get; } = keys ?? [.. entries.Keys.Concat(segments?.Keys ?? []).Distinct().Order()];
    internal PackFuzzyIndex? Fuzzy { get; } = fuzzy;

    /// <param name="name">Dosya adı uzantısız ("mafia-the-old-country"); düz biçimde kimlik ve başlık olur.</param>
    /// <exception cref="InvalidDataException">Dosya paket değil ya da bozuk.</exception>
    public static GamePack Decode(byte[] data, string name)
    {
        var json = data.Length >= 2 && data[0] == 0x1f && data[1] == 0x8b ? Decompress(data) : data;
        JsonDocument document;
        try { document = JsonDocument.Parse(json); }
        catch (JsonException error) { throw new InvalidDataException("Paket JSON değil", error); }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Paket JSON nesnesi değil");
            var id = name;
            var title = name;
            var raw = root;
            JsonElement? rawSegments = null;
            if (root.TryGetProperty("entries", out var wrapped) && wrapped.ValueKind == JsonValueKind.Object)
            {
                if (root.TryGetProperty("format", out var format) && format.ValueKind == JsonValueKind.Number
                    && format.GetDouble() is not (1 or 2))
                    throw new InvalidDataException("Desteklenmeyen paket biçimi");
                raw = wrapped;
                if (root.TryGetProperty("segments", out var segmentsJson) && segmentsJson.ValueKind == JsonValueKind.Object)
                    rawSegments = segmentsJson;
                if (root.TryGetProperty("id", out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } given) id = given;
                title = root.TryGetProperty("title", out var named) && named.ValueKind == JsonValueKind.String && named.GetString() is { Length: > 0 } titled
                    ? titled : id;
            }
            // İmzaların sırası: dosyadaki bütün geçerli anahtarlar (Türkçesi boş kalanlar da), sayı sırasıyla.
            var order = new HashSet<ulong>();
            Dictionary<ulong, string> Read(JsonElement element)
            {
                var result = new Dictionary<ulong, string>();
                foreach (var entry in element.EnumerateObject())
                {
                    if (entry.Value.ValueKind != JsonValueKind.String || PackKey.Number(entry.Name.ToLowerInvariant()) is not { } number) continue;
                    order.Add(number);
                    var text = Cleaned(entry.Value.GetString() ?? "");
                    if (text.Length > 0) result[number] = text;
                }
                return result;
            }
            var entries = Read(raw);
            var segments = rawSegments is { } segmentsElement ? Read(segmentsElement) : [];
            if (entries.Count == 0) throw new InvalidDataException("Pakette satır yok");
            List<ulong> keys = [.. order.Order()];
            var fuzzy = root.TryGetProperty("fuzzy", out var fuzzyJson) ? PackFuzzyIndex.Decode(fuzzyJson, keys) : null;
            return new GamePack(id, title, entries, segments, keys, fuzzy);
        }
    }

    /// <summary>Paketteki Türkçede de oyunun biçim etiketleri kalmış olabilir ("&lt;b&gt;&lt;h&gt;…&lt;/&gt;"); TV'de görünmesinler.</summary>
    internal static string Cleaned(string text)
    {
        if (!text.Contains('<')) return text.Trim();
        return string.Join(' ', PackKey.StripTags(text, "").Split(' ', StringSplitOptions.RemoveEmptyEntries)).Trim();
    }

    private static byte[] Decompress(byte[] data)
    {
        try
        {
            using var input = new GZipStream(new MemoryStream(data), CompressionMode.Decompress);
            using var output = new MemoryStream();
            input.CopyTo(output);
            return output.ToArray();
        }
        catch (Exception error) when (error is InvalidDataException or IOException)
        {
            throw new InvalidDataException("Paket açılamadı", error);
        }
    }
}

/// <summary>Pakette bulunan satırın Türkçesi ve seslendirilecek cümleleri.</summary>
public sealed record PackMatch(string Text, IReadOnlyList<SpokenLine> Spoken);

/// <summary>
/// Uygulamayla gelen ve kullanıcının klasörüne bırakılan paketler; hepsi tek bir sözlükte birleşir.
/// Sıra: uygulamanınkiler, sonra kullanıcınınkiler (dosya adına göre); aynı anahtarda sonraki kazanır,
/// aynı kimlikli pakette kullanıcının dosyası uygulamanınkinin yerine geçer.
/// </summary>
/// <param name="bundled">Uygulamayla gelen paket dosyaları (ad, içerik); verilmezse bu derlemeye gömülü olanlar.</param>
/// <param name="userDirectory">Denemecilerin yeni paket bıraktığı klasör.</param>
public sealed class GamePackLibrary(Func<IEnumerable<(string Name, byte[] Data)>>? bundled, string? userDirectory)
{
    /// <param name="BuiltIn">Kullanıcının klasöründen geldiyse false.</param>
    public sealed record Info(string Id, string Title, int Entries, bool BuiltIn);

    /// <summary>%LOCALAPPDATA%\CouchSubs\packs</summary>
    public static string UserDirectory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CouchSubs", "packs");

    private readonly object gate = new();
    private bool loaded;
    private Dictionary<ulong, string> entries = [];
    private IReadOnlyList<GamePack> loadedPacks = [];
    /// <summary>
    /// Son tam eşleşmenin geldiği paket: bulanık arama yalnız orada yapılır (oynanan oyun). Satır birden çok pakette
    /// varsa kapsam o paketlerden biri değilse ilkine geçer; hiç tam eşleşme olmadıysa bulanık arama yapılmaz.
    /// </summary>
    private int? scope;
    private IReadOnlyList<Info> infos = [];

    /// <summary>Uygulamaya gömülü paketler (core/Sources/CouchSubsCore/Resources/packs, ad: "packs/x.json.gz").</summary>
    public static IEnumerable<(string Name, byte[] Data)> EmbeddedPacks()
    {
        var assembly = typeof(GamePackLibrary).Assembly;
        foreach (var name in assembly.GetManifestResourceNames().Where(n => n.StartsWith("packs/", StringComparison.Ordinal)).Order(StringComparer.Ordinal))
        {
            using var stream = assembly.GetManifestResourceStream(name);
            if (stream is null) continue;
            using var memory = new MemoryStream();
            stream.CopyTo(memory);
            yield return (name["packs/".Length..], memory.ToArray());
        }
    }

    /// <summary>Kurulu paketler; ilk çağrıda yüklenir.</summary>
    public IReadOnlyList<Info> Packs
    {
        get { lock (gate) { LoadIfNeeded(); return infos; } }
    }

    /// <summary>Paketleri (yeniden) okur. Bozuk dosya sessizce atlanır.</summary>
    public void Reload()
    {
        lock (gate)
        {
            loaded = false;
            LoadIfNeeded();
        }
    }

    /// <summary>Yüklemeyi şimdi yapar (açılışta arka planda çağrılır; ilk altyazı beklemesin).</summary>
    public void WarmUp() => _ = Packs;

    /// <summary>Anahtarın Türkçesi.</summary>
    public string? Translation(string key)
    {
        if (PackKey.Number(key) is not { } number) return null;
        lock (gate)
        {
            LoadIfNeeded();
            return entries.GetValueOrDefault(number);
        }
    }

    /// <summary>
    /// Satırın tamamı için sözlükteki Türkçe (parçalara bölme yok; bkz. CouchSubs.Translation.PackLookup). Bulunursa
    /// bulanık aramanın kapsamı satırın paketine geçer.
    /// </summary>
    public string? Find(string text)
    {
        Dictionary<ulong, string> current;
        IReadOnlyList<GamePack> packs;
        lock (gate)
        {
            LoadIfNeeded();
            current = entries;
            packs = loadedPacks;
        }
        if (current.Count == 0 || PackKey.Key(text) is not { } key || PackKey.Number(key) is not { } number
            || !current.TryGetValue(number, out var turkish)) return null;
        var owners = new List<int>();
        for (var index = 0; index < packs.Count; index++)
            if (Contains(packs[index].Keys, number)) owners.Add(index);
        if (owners.Count > 0)
        {
            lock (gate)
                if (owners.Count == 1 || scope is not { } chosen || !owners.Contains(chosen)) scope = owners[0];
        }
        return turkish;
    }

    /// <summary>
    /// OCR hatalarına dayanıklı arama: oynanan oyunun paketinde (son tam eşleşmenin paketi) satıra en çok benzeyen
    /// satırın Türkçesi; benzerlik eşiği geçmezse ya da kapsam yoksa null.
    /// </summary>
    public string? Nearest(string text)
    {
        Dictionary<ulong, string> current;
        PackFuzzyIndex? index;
        lock (gate)
        {
            LoadIfNeeded();
            current = entries;
            index = scope is { } chosen && chosen < loadedPacks.Count ? loadedPacks[chosen].Fuzzy : null;
        }
        return index?.Nearest(text, key => current.GetValueOrDefault(key)) is { } found ? current.GetValueOrDefault(found) : null;
    }

    /// <summary>Bulanık aramanın yapılacağı paketin kimliği (son tam eşleşmenin paketi); yoksa null.</summary>
    public string? SearchScope
    {
        get { lock (gate) return scope is { } chosen && chosen < infos.Count ? infos[chosen].Id : null; }
    }

    /// <summary>Oynanan oyunun adı: son tam eşleşmenin geldiği paketin başlığı; yoksa null. Yapay zekâya bağlam olarak gider.</summary>
    public string? ScopeTitle
    {
        get { lock (gate) return scope is { } chosen && chosen < infos.Count ? infos[chosen].Title : null; }
    }

    private static bool Contains(IReadOnlyList<ulong> sorted, ulong key)
    {
        int low = 0, high = sorted.Count;
        while (low < high)
        {
            var middle = (low + high) / 2;
            if (sorted[middle] < key) low = middle + 1; else high = middle;
        }
        return low < sorted.Count && sorted[low] == key;
    }

    private void LoadIfNeeded()
    {
        if (loaded) return;
        loaded = true;
        var packs = new List<(GamePack Pack, bool BuiltIn)>();
        void Add(string fileName, byte[] data, bool builtIn)
        {
            GamePack pack;
            try { pack = GamePack.Decode(data, BaseName(fileName)); }
            catch (InvalidDataException) { return; }
            packs.RemoveAll(p => p.Pack.Id == pack.Id);
            packs.Add((pack, builtIn));
        }
        if (bundled is not null)
            foreach (var (name, data) in bundled().OrderBy(file => file.Name, StringComparer.Ordinal))
                if (IsPackFile(name)) Add(name, data, true);
        if (userDirectory is not null && Directory.Exists(userDirectory))
        {
            foreach (var file in Directory.EnumerateFiles(userDirectory).Where(f => IsPackFile(Path.GetFileName(f))).Order(StringComparer.Ordinal))
            {
                byte[] data;
                try { data = File.ReadAllBytes(file); }
                catch (IOException) { continue; }
                catch (UnauthorizedAccessException) { continue; }
                Add(Path.GetFileName(file), data, false);
            }
        }
        // Önce bütün paketlerin parçaları, sonra tam satırlar: bir oyunun tam satırı başka oyunun parçasına yenilmez.
        var merged = new Dictionary<ulong, string>(packs.Sum(p => p.Pack.Entries.Count + p.Pack.Segments.Count));
        foreach (var (pack, _) in packs)
            foreach (var (key, value) in pack.Segments) merged[key] = value;
        foreach (var (pack, _) in packs)
            foreach (var (key, value) in pack.Entries) merged[key] = value;
        entries = merged;
        loadedPacks = [.. packs.Select(p => p.Pack)];
        scope = null;
        infos = [.. packs.Select(p => new Info(p.Pack.Id, p.Pack.Title, p.Pack.Entries.Count, p.BuiltIn))];
    }

    private static bool IsPackFile(string name) =>
        name.EndsWith(".json.gz", StringComparison.Ordinal) || name.EndsWith(".json", StringComparison.Ordinal);

    /// <summary>"mafia.json.gz" → "mafia"</summary>
    internal static string BaseName(string fileName)
    {
        var name = Path.GetFileName(fileName);
        foreach (var suffix in new[] { ".gz", ".json" })
            if (name.EndsWith(suffix, StringComparison.Ordinal)) name = name[..^suffix.Length];
        return name;
    }
}
