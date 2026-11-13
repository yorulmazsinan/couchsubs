// SPDX-License-Identifier: AGPL-3.0-only

using System.Text;
using System.Text.Json;

namespace CouchSubs.Core;

/// <summary>
/// Ücretsiz çevirinin terim sözlüğü (Mac: Glossary.swift, aynı biçim ve kurallar). Dosya biçimi:
/// <c>{ "game": "God of War", "terms": { "Leviathan Axe": "Leviathan Baltası" }, "keep": ["Kratos", "Atreus"] }</c>.
/// <c>terms</c> İngilizce terimi verilen Türkçeyle değiştirir, <c>keep</c> adları olduğu gibi bırakır. Eşleşme büyük/küçük
/// harfe bakmaz, yalnız tam sözcüklerde olur, uzun terim önce gelir ("Leviathan Axe", "Axe"dan önce).
/// <c>keepExact</c> da adları bırakır ama yalnız yazıldığı gibi (büyük/küçük harf aynı) geçince: aynı zamanda sıradan
/// bir sözcük olan adlar için ("Soul" kahramanın adıyken "soul" ruh demek; Phantom Blade Zero).
/// Uygulamayla gelen genel sözlüğün üstüne kullanıcının klasöründeki <c>*.json</c> dosyaları eklenir (ad sırasıyla;
/// aynı terimde sonraki dosya kazanır).
/// </summary>
public sealed class Glossary
{
    /// <summary>Küçük harfli İngilizce → (sözlükte yazıldığı gibi İngilizce, Türkçe, yalnız aynı büyük/küçük harfle mi).</summary>
    private readonly Dictionary<string, (string English, string Turkish, bool Exact)> _terms;
    /// <summary>Uzundan kısaya terimler; arama bu sırayla yapılır.</summary>
    private readonly List<(string English, string Turkish, bool Exact)> _ordered;

    public static Glossary Empty { get; } = new([]);

    private static readonly Lazy<Glossary> BuiltInValue = new(LoadBuiltIn);

    /// <summary>Uygulamayla gelen genel oyun terimleri (core/Sources/CouchSubsCore/Resources/glossary-en-tr.json).</summary>
    public static Glossary BuiltIn => BuiltInValue.Value;

    private Glossary(Dictionary<string, (string English, string Turkish, bool Exact)> terms)
    {
        _terms = terms;
        _ordered = [.. terms.Values.OrderByDescending(t => t.English.Length).ThenBy(t => t.English, StringComparer.Ordinal)];
        var words = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (english, _, exact) in _ordered)
        {
            // Sözlükte büyük harfle yazılmış terimler ad sayılır: tümü büyük harfli cümlede de büyük harfle kalır.
            // keepExact adları sıradan sözcük de olduğundan büyük harfe çevrilmez ("I SOLD MY SOUL" → "soul").
            if (exact || !english.Any(char.IsUpper)) continue;
            foreach (var word in english.Split(' ', StringSplitOptions.RemoveEmptyEntries))
                if (word.Length >= 2) words.Add(word.ToLowerInvariant());
        }
        CapitalWords = words;
        Fingerprint = MakeFingerprint(_ordered);
    }

    public int Count => _terms.Count;
    public bool IsEmpty => _terms.Count == 0;

    /// <summary>Büyük harfle kalması gereken sözcükler (küçük harfle); <c>NormalizeCase</c>'e ad olarak verilir.</summary>
    public IReadOnlySet<string> CapitalWords { get; }

    /// <summary>Sözlüğün içeriğinden kısa bir iz; terim içeren satırların önbellek anahtarına girer, sözlük değişince yeniden çevrilir.</summary>
    public string Fingerprint { get; }

    /// <summary>Terimin Türkçesi; yoksa null.</summary>
    public string? Turkish(string english) =>
        _terms.TryGetValue(Normalize(english), out var term) ? term.Turkish : null;

    /// <summary>JSON sözlük dosyasını okur; biçim bozuksa <see cref="JsonException"/> ya da <see cref="FormatException"/> atar.</summary>
    public static Glossary Parse(string json)
    {
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new FormatException("Glossary must be a JSON object.");
        var terms = new Dictionary<string, (string, string, bool)>(StringComparer.Ordinal);
        if (root.TryGetProperty("terms", out var map) && map.ValueKind == JsonValueKind.Object)
            foreach (var entry in map.EnumerateObject())
                if (entry.Value.ValueKind == JsonValueKind.String) Add(terms, entry.Name, entry.Value.GetString()!);
        if (root.TryGetProperty("keep", out var keep) && keep.ValueKind == JsonValueKind.Array)
            foreach (var name in keep.EnumerateArray())
                if (name.ValueKind == JsonValueKind.String) Add(terms, name.GetString()!, name.GetString()!);
        if (root.TryGetProperty("keepExact", out var keepExact) && keepExact.ValueKind == JsonValueKind.Array)
            foreach (var name in keepExact.EnumerateArray())
                if (name.ValueKind == JsonValueKind.String) Add(terms, name.GetString()!, name.GetString()!, exact: true);
        return new Glossary(terms);
    }

    private static void Add(Dictionary<string, (string, string, bool)> terms, string english, string turkish, bool exact = false)
    {
        english = CollapseSpaces(english);
        turkish = CollapseSpaces(turkish);
        // Harfsiz terim her yerde eşleşirdi; yer tutucu sayısı sınırlı olduğundan çok uzun terim de alınmaz.
        if (!english.Any(char.IsLetter) || turkish.Length == 0 || english.Length > 80) return;
        terms[english.ToLowerInvariant()] = (english, turkish, exact);
    }

    /// <summary>Sözlükleri birleştirir; aynı terimde sonraki kazanır.</summary>
    public static Glossary Merge(IEnumerable<Glossary> glossaries)
    {
        var terms = new Dictionary<string, (string, string, bool)>(StringComparer.Ordinal);
        foreach (var glossary in glossaries)
            foreach (var (key, value) in glossary._terms) terms[key] = value;
        return new Glossary(terms);
    }

    /// <summary>Genel sözlük ve klasördeki <c>*.json</c> dosyaları; okunamayan ya da bozuk dosya atlanır.</summary>
    public static Glossary Load(string? directory)
    {
        var all = new List<Glossary> { BuiltIn };
        foreach (var file in UserFiles(directory))
        {
            try { all.Add(Parse(File.ReadAllText(file, Encoding.UTF8))); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or FormatException) { }
        }
        return Merge(all);
    }

    internal static IEnumerable<string> UserFiles(string? directory)
    {
        if (directory is null) return [];
        try
        {
            return Directory.Exists(directory)
                ? Directory.GetFiles(directory, "*.json").Order(StringComparer.Ordinal).ToArray()
                : [];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return []; }
    }

    /// <summary>
    /// Metindeki terimler: büyük/küçük harfe bakmadan (keepExact adları bakarak), tam sözcük, uzun terim önce; çakışan kısa terim alınmaz.
    /// Sonuç metindeki sıraya göredir.
    /// </summary>
    public IReadOnlyList<TermMatch> Find(string text)
    {
        var found = new List<TermMatch>();
        if (_ordered.Count == 0 || text.Length == 0) return found;
        foreach (var (english, turkish, exact) in _ordered)
        {
            var start = 0;
            while (start <= text.Length - english.Length)
            {
                var index = text.IndexOf(english, start, exact ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase);
                if (index < 0) break;
                var end = index + english.Length;
                if (IsBoundary(text, index - 1) && IsBoundary(text, end) && !found.Any(m => index < m.Start + m.Length && m.Start < end))
                    found.Add(new TermMatch(index, english.Length, english, turkish));
                start = index + 1;
            }
        }
        found.Sort((a, b) => a.Start.CompareTo(b.Start));
        return found;
    }

    public bool Matches(string text) => Find(text).Count > 0;

    /// <summary>Metinde bulunan terim: konumu, sözlükteki İngilizcesi ve Türkçesi.</summary>
    public readonly record struct TermMatch(int Start, int Length, string English, string Turkish);

    private static bool IsBoundary(string text, int index) =>
        index < 0 || index >= text.Length || !char.IsLetterOrDigit(text[index]);

    private static string Normalize(string english) => CollapseSpaces(english).ToLowerInvariant();

    private static string CollapseSpaces(string text) =>
        string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    /// <summary>FNV-1a (32 bit), terimler İngilizcesine göre sıralı; Mac'te de aynı hesap.</summary>
    private static string MakeFingerprint(IEnumerable<(string English, string Turkish, bool Exact)> terms)
    {
        var hash = 2166136261u;
        // exact işareti yalnız varsa eklenir; eski sözlüklerin izi değişmez.
        foreach (var (english, turkish, exact) in terms.OrderBy(t => t.English.ToLowerInvariant(), StringComparer.Ordinal))
            foreach (var b in Encoding.UTF8.GetBytes(english.ToLowerInvariant() + "\u0001" + turkish + (exact ? "\u0003" : "") + "\u0002"))
                hash = (hash ^ b) * 16777619u;
        return "g" + hash.ToString("x8");
    }

    private static Glossary LoadBuiltIn()
    {
        using var stream = typeof(Glossary).Assembly.GetManifestResourceStream("glossary-en-tr.json");
        if (stream is null) return Empty;
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return Parse(reader.ReadToEnd());
    }
}

/// <summary>
/// Kullanıcı sözlük klasörünü izler: dosyalar değişince (ad, boyut, değişiklik zamanı) sözlük yeniden okunur.
/// Klasöre en çok birkaç saniyede bir bakılır; her altyazıda diske gidilmez.
/// </summary>
public sealed class GlossaryStore
{
    private static readonly TimeSpan CheckEvery = TimeSpan.FromSeconds(5);

    private readonly string? _directory;
    private readonly Func<DateTimeOffset> _clock;
    private readonly object _gate = new();
    private Glossary? _current;
    private string _stamp = "";
    private DateTimeOffset _checkedAt = DateTimeOffset.MinValue;

    /// <param name="directory">Kullanıcı sözlüklerinin klasörü; null ise yalnız genel sözlük.</param>
    public GlossaryStore(string? directory, Func<DateTimeOffset>? clock = null)
    {
        _directory = directory;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>%LOCALAPPDATA%\CouchSubs\glossary</summary>
    public static string UserDirectory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CouchSubs", "glossary");

    /// <summary>Yalnız uygulamayla gelen sözlük (testler).</summary>
    public static GlossaryStore BuiltInOnly() => new(null);

    public Glossary Current
    {
        get
        {
            lock (_gate)
            {
                var now = _clock();
                if (_current is not null && now - _checkedAt < CheckEvery) return _current;
                _checkedAt = now;
                var stamp = Stamp();
                if (_current is null || stamp != _stamp)
                {
                    _current = Glossary.Load(_directory);
                    _stamp = stamp;
                }
                return _current;
            }
        }
    }

    private string Stamp()
    {
        var builder = new StringBuilder();
        foreach (var file in Glossary.UserFiles(_directory))
        {
            try
            {
                var info = new FileInfo(file);
                builder.Append(file).Append('|').Append(info.Length).Append('|').Append(info.LastWriteTimeUtc.Ticks).Append('\n');
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return builder.ToString();
    }
}
