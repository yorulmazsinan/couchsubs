// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CouchSubs.Core;

/// <summary>
/// Çevrilen altyazılar, en yenisi başta: bu oturumun ve önceki oturumların son <see cref="Limit"/> satırı. Hızlı geçen bir
/// satır sonradan yeniden okunabilsin diye tutulur ("Geçmiş" penceresi). Uygulama küçük bir JSON dosyasına yazar
/// (<see cref="Save"/>), açılışta okur (<see cref="Load"/>). Mac'teki CouchSubsCore/SubtitleHistory.swift ile aynı biçim.
/// Kilitsizdir; uygulama yalnız arayüz iş parçacığında kullanır.
/// </summary>
public sealed class SubtitleHistory
{
    /// <param name="Date">Satırın çevrildiği an (UTC; ekranda yerel saatle gösterilir).</param>
    /// <param name="Origin">Oyun paketinden mi, çeviri motorundan mı geldi.</param>
    public sealed record Entry(int Id, DateTime Date, string Source, string Translation, LineOrigin Origin);

    /// <summary>Varsayılan satır sayısı (dosya en çok ~200 KB olur).</summary>
    public const int DefaultLimit = 200;
    /// <summary>Bir satırın kaydedilen en uzun hâli (dosya şişmesin).</summary>
    public const int MaxTextLength = 500;

    private readonly List<Entry> entries = [];
    private int nextId;

    public SubtitleHistory(int limit = DefaultLimit) => Limit = Math.Max(1, limit);

    public int Limit { get; }

    /// <summary>Satırlar, en yenisi başta.</summary>
    public IReadOnlyList<Entry> Entries => entries;

    /// <summary>
    /// Yeni çeviriyi başa ekler. Aynı satırın yeniden okuması (benzer kaynak metin) yeni kayıt açmaz, son kaydı günceller.
    /// Boş çeviri eklenmez.
    /// </summary>
    /// <returns>Geçmiş değiştiyse true.</returns>
    public bool Add(string source, string translation, LineOrigin origin = LineOrigin.Engine, DateTime? date = null)
    {
        var text = Clip(translation.Trim());
        if (text.Length == 0) return false;
        source = Clip(source);
        var when = (date ?? DateTime.UtcNow).ToUniversalTime();
        if (entries.Count > 0 && TextMatch.IsSimilar(TextMatch.Normalize(entries[0].Source), TextMatch.Normalize(source)))
        {
            entries[0] = new Entry(entries[0].Id, when, source, text, origin);
            return true;
        }
        entries.Insert(0, new Entry(nextId++, when, source, text, origin));
        if (entries.Count > Limit) entries.RemoveRange(Limit, entries.Count - Limit);
        return true;
    }

    /// <summary><paramref name="date"/> anından (ör. oturumun başından) sonra çevrilen satırlar.</summary>
    public IReadOnlyList<Entry> EntriesSince(DateTime date)
    {
        var since = date.ToUniversalTime();
        return [.. entries.Where(entry => entry.Date >= since)];
    }

    public void Clear() => entries.Clear();

    /// <summary>Aynı satırlarla bağımsız kopya (dosyaya başka iş parçacığında yazmak için).</summary>
    public SubtitleHistory Copy()
    {
        var copy = new SubtitleHistory(Limit) { nextId = nextId };
        copy.entries.AddRange(entries);
        return copy;
    }

    /// <summary>Satırlar düz metin olarak (kopyalamak için): her satırda yerel saat, Türkçe ve İngilizcesi.</summary>
    public static string PlainText(IEnumerable<Entry> entries, TimeZoneInfo? timeZone = null) =>
        string.Join("\n\n", entries.Select(entry =>
        {
            var local = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(entry.Date, DateTimeKind.Utc), timeZone ?? TimeZoneInfo.Local);
            return $"[{local.ToString("HH:mm:ss", CultureInfo.InvariantCulture)}] {entry.Translation}\n{entry.Source}";
        }));

    // --- Dosya ---

    /// <summary>%LOCALAPPDATA%\CouchSubs\history.json.</summary>
    public static string DefaultFile { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CouchSubs", "history.json");

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        // Türkçe harfler dosyada okunur kalsın (ı yerine ı).
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new JsonStringEnumConverter<LineOrigin>(JsonNamingPolicy.CamelCase), new UtcSeconds() },
    };

    private sealed record Stored(int Version, List<Entry> Entries);

    /// <summary>Dosyadaki geçmiş; dosya yoksa ya da bozuksa boş geçmiş.</summary>
    public static SubtitleHistory Load(string path, int limit = DefaultLimit)
    {
        var history = new SubtitleHistory(limit);
        try
        {
            if (JsonSerializer.Deserialize<Stored>(File.ReadAllText(path), Json)?.Entries is not { } stored) return history;
            history.entries.AddRange(stored.Where(entry => entry is { Source: not null, Translation: not null }).Take(history.Limit));
            history.nextId = history.entries.Count == 0 ? 0 : history.entries.Max(entry => entry.Id) + 1;
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException or NotSupportedException or FormatException) { }
        return history;
    }

    /// <summary>Geçmişi dosyaya yazar (önce geçici dosyaya, sonra yerine koyarak; yarım dosya kalmaz).</summary>
    public void Save(string path)
    {
        if (Path.GetDirectoryName(path) is { Length: > 0 } folder) Directory.CreateDirectory(folder);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(new Stored(1, [.. entries]), Json));
        File.Move(temporary, path, overwrite: true);
    }

    private static string Clip(string text) => text.Length > MaxTextLength ? text[..MaxTextLength] : text;

    /// <summary>
    /// Tarih saniyesine kadar ve UTC olarak yazılır ("2026-11-12T10:00:00Z"): Mac'in ISO 8601 okuyucusu kesirli saniyeyi
    /// kabul etmez. Okurken her ISO 8601 biçimi kabul edilir.
    /// </summary>
    private sealed class UtcSeconds : JsonConverter<DateTime>
    {
        public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            DateTime.Parse(reader.GetString() ?? throw new JsonException(), CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);

        public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
    }
}
