// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;

namespace CouchSubs.Core;

/// <summary>
/// Çevrilmiş satır ve cümlelerin kalıcı önbelleği (Mac'teki <c>TranslationCache</c> ile aynı dosya biçimi).
/// Oyunlar aynı satırları oturumdan oturuma tekrarlar ("Stay close.", "Over here!"); diskte duran çeviri 0 ms sürer,
/// DeepL kotasından da yemez. Her çeviri motoru ve dil çifti kendi dosyasını kullanır: motor değişince eski motorun
/// çevirisi gösterilmez.
/// </summary>
/// <remarks>
/// Dosya her satırı bir JSON dizisi (<c>["kaynak","çeviri"]</c>) olan, sonuna eklenen bir kayıttır. Bellekte en çok
/// <c>limit</c> kayıt tutulur; en uzun süredir kullanılmayanlar atılır. Dosya kayıt sınırının iki katına uzayınca
/// bellektekilerle yeniden yazılır. Disk hatası çeviriyi durdurmaz: önbellek o zaman yalnız bellekte çalışır.
/// </remarks>
public sealed class TranslationCache
{
    public const int DefaultLimit = 20_000;
    /// <summary>Dosya adındaki biçim sürümü: çeviri öncesi temizlik kuralları değişince eski çeviriler bırakılabilsin.</summary>
    public const int FormatVersion = 1;

    private static readonly UTF8Encoding NoBom = new(false);
    private static readonly ConcurrentDictionary<string, TranslationCache> Opened = new(StringComparer.OrdinalIgnoreCase);

    private readonly string? _file;
    private readonly int _limit;
    private readonly object _gate = new();
    private readonly Dictionary<string, (string Value, long Used)> _entries = new(StringComparer.Ordinal);
    private long _tick;
    private bool _loaded;
    /// <summary>Dosyadaki satır sayısı (yinelenenler ve atılanlar dahil).</summary>
    private int _fileLines;

    /// <param name="file">null ise önbellek yalnız bellekte tutulur (testler, geçici çevirmenler).</param>
    /// <param name="engine">Motor adı (<see cref="Shared"/> verir); altyazı günlüğünde çevirinin hangi motordan geldiği görünür.</param>
    public TranslationCache(string? file = null, int limit = DefaultLimit, string? engine = null)
    {
        _file = file;
        _limit = Math.Max(1, limit);
        Engine = engine;
    }

    /// <summary>Motor adı (<see cref="Shared"/> ile açılanlarda).</summary>
    public string? Engine { get; }

    /// <summary>Motor ve dil çiftine göre dosya: <c>v1-opus_mt-en-tr.jsonl</c>.</summary>
    public static string FileFor(string directory, string engine, string source, string target) =>
        Path.Combine(directory, string.Join('-', new[] { $"v{FormatVersion}", engine, source, target }.Select(Safe)) + ".jsonl");

    /// <summary>Aynı dosya için hep aynı önbellek döner; çevirmen her oturumda yeniden kurulsa da dosya bir kez okunur.</summary>
    public static TranslationCache Shared(string directory, string engine, string source, string target) =>
        Opened.GetOrAdd(FileFor(directory, engine, source, target), file => new TranslationCache(file, engine: engine));

    public int Count
    {
        get { lock (_gate) { LoadIfNeeded(); return _entries.Count; } }
    }

    public bool TryGet(string key, out string value)
    {
        lock (_gate)
        {
            LoadIfNeeded();
            if (_entries.TryGetValue(key, out var entry))
            {
                _entries[key] = (entry.Value, ++_tick);
                value = entry.Value;
                TranslationProbe.Current?.NoteHit();
                return true;
            }
            value = "";
            return false;
        }
    }

    public void Store(string key, string value)
    {
        if (string.IsNullOrEmpty(key) || string.IsNullOrEmpty(value)) return;
        lock (_gate)
        {
            LoadIfNeeded();
            var same = _entries.TryGetValue(key, out var old) && old.Value == value;
            _entries[key] = (value, ++_tick);
            if (same) return;
            EvictIfNeeded();
            Append(key, value);
            TranslationProbe.Current?.NoteFresh(Engine);
        }
    }

    /// <summary>Dosyayı ilk kullanımda okur (çeviri arayüz iş parçacığının dışında olduğu için arayüzü bekletmez).</summary>
    private void LoadIfNeeded()
    {
        if (_loaded) return;
        _loaded = true;
        if (_file is null) return;
        string[] lines;
        try
        {
            if (!File.Exists(_file)) return;
            lines = File.ReadAllLines(_file, Encoding.UTF8);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return;
        }
        foreach (var line in lines)
        {
            if (line.Length == 0) continue;
            _fileLines++;
            string[]? pair;
            try { pair = JsonSerializer.Deserialize(line, CacheJson.Default.StringArray); }
            catch (JsonException) { continue; }
            if (pair is not { Length: 2 } || string.IsNullOrEmpty(pair[0]) || string.IsNullOrEmpty(pair[1])) continue;
            _entries[pair[0]] = (pair[1], ++_tick);
        }
        EvictIfNeeded();
        if (_fileLines > _entries.Count + _limit / 2) Rewrite();
    }

    private void EvictIfNeeded()
    {
        if (_entries.Count <= _limit) return;
        // Her seferinde tek kayıt atmak yerine onda biri atılır; sıralama seyrek yapılır.
        var drop = _entries.Count - _limit + _limit / 10;
        foreach (var key in _entries.OrderBy(entry => entry.Value.Used).Take(drop).Select(entry => entry.Key).ToList())
            _entries.Remove(key);
    }

    private void Append(string key, string value)
    {
        if (_file is null) return;
        if (_fileLines >= _limit * 2)
        {
            Rewrite();
            return;
        }
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            File.AppendAllText(_file, Line(key, value), NoBom);
            _fileLines++;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Disk dolu ya da yazılamıyor: önbellek bellekte çalışmaya devam eder.
        }
    }

    /// <summary>Dosyayı bellektekilerle, en eski kullanılandan yeniye doğru yeniden yazar.</summary>
    private void Rewrite()
    {
        if (_file is null) return;
        var builder = new StringBuilder();
        foreach (var (key, entry) in _entries.OrderBy(entry => entry.Value.Used)) builder.Append(Line(key, entry.Value));
        var temporary = _file + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            File.WriteAllText(temporary, builder.ToString(), NoBom);
            File.Move(temporary, _file, overwrite: true);
            _fileLines = _entries.Count;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Yazılamadıysa eski dosya yerinde kalır.
        }
    }

    private static string Line(string key, string value) =>
        JsonSerializer.Serialize([key, value], CacheJson.Default.StringArray) + "\n";

    private static string Safe(string part) =>
        new([.. part.Select(c => char.IsLetterOrDigit(c) || c == '_' ? c : '_')]);
}

/// <summary>
/// Bir çeviri isteğinde önbelleğin ne yaptığını sayar (altyazı günlüğü için; çeviriyi değiştirmez). Okuma hattı isteği
/// <see cref="Current"/> ayarlıyken çalıştırır (<see cref="AsyncLocal{T}"/>: çağrının bekledikleri de görür); önbellekten
/// dönen ve motorun yeni ürettiği (önbelleğe yeni yazılan) parçalar sayılır. Yedeğe düşen çevrimiçi motorda yeni parçayı
/// yedeğin önbelleği yazar; günlükte gerçekten çeviren motor görünür. Mac'teki <c>TranslationProbe</c> ile aynı.
/// </summary>
public sealed class TranslationProbe
{
    private static readonly AsyncLocal<TranslationProbe?> Local = new();
    private readonly object gate = new();
    private readonly List<string> fresh = [];
    private int hits;

    public static TranslationProbe? Current
    {
        get => Local.Value;
        set => Local.Value = value;
    }

    internal void NoteHit() { lock (gate) hits++; }

    internal void NoteFresh(string? engine) { lock (gate) fresh.Add(engine ?? ""); }

    public int Hits { get { lock (gate) return hits; } }

    /// <summary>"çeviri:&lt;motor&gt;" (motor yeni çevirdi), "önbellek" (her parça önbellekten geldi) ya da bilinmiyorsa "çeviri:&lt;yedek ad&gt;".</summary>
    public string Outcome(string fallbackEngine = "motor")
    {
        lock (gate)
        {
            if (fresh.Count > 0) return "çeviri:" + (fresh[^1].Length == 0 ? fallbackEngine : fresh[^1]);
            return hits > 0 ? "önbellek" : "çeviri:" + fallbackEngine;
        }
    }
}

[System.Text.Json.Serialization.JsonSerializable(typeof(string[]))]
internal sealed partial class CacheJson : System.Text.Json.Serialization.JsonSerializerContext;
