// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace CouchSubs.Core;

/// <summary>İçe aktarılan dosyada atlanan kaydın nedeni (Mac/iPhone, Android ve günlükte aynı adlar).</summary>
public enum GamePackSkipReason
{
    /// <summary>İngilizce satırda harf ya da rakam yok, ya da hazır paketteki anahtar 16 haneli onaltılık sayı değil.</summary>
    InvalidKey,
    /// <summary>Türkçesi boş ya da metin değil.</summary>
    EmptyTranslation,
    /// <summary>SRT kaydı dört satır değil, numara ya da zaman bozuk; TXT satırında ayraç yok.</summary>
    MalformedRecord,
    /// <summary>Aynı İngilizce satır aynı Türkçeyle bir kez daha (bir kez kurulur).</summary>
    Duplicate,
    /// <summary>Aynı İngilizce satır farklı Türkçelerle: hiçbiri kurulmaz.</summary>
    Conflict,
}

public static class GamePackSkipReasons
{
    /// <summary>Swift'teki ad (ortak deneme dosyası bu adları kullanır).</summary>
    public static string Name(this GamePackSkipReason reason) => reason switch
    {
        GamePackSkipReason.InvalidKey => "invalidKey",
        GamePackSkipReason.EmptyTranslation => "emptyTranslation",
        GamePackSkipReason.MalformedRecord => "malformedRecord",
        GamePackSkipReason.Duplicate => "duplicate",
        _ => "conflict",
    };

    /// <summary>Günlükteki adı.</summary>
    public static string LogName(this GamePackSkipReason reason) => reason switch
    {
        GamePackSkipReason.InvalidKey => "İngilizcesi ya da anahtarı geçersiz",
        GamePackSkipReason.EmptyTranslation => "Türkçesi boş",
        GamePackSkipReason.MalformedRecord => "biçimi bozuk",
        GamePackSkipReason.Duplicate => "tekrar",
        _ => "çakışan",
    };
}

public sealed class GamePackImportPreview
{
    internal GamePackImportPreview(string? suggestedTitle, IReadOnlyDictionary<string, string> entries,
        IReadOnlyDictionary<GamePackSkipReason, int> skipped, IReadOnlyDictionary<string, string>? segments = null,
        string? fuzzy = null, bool fuzzyDropped = false)
    {
        SuggestedTitle = suggestedTitle;
        Entries = entries;
        Segments = segments ?? new Dictionary<string, string>();
        Skipped = skipped.Where(pair => pair.Value > 0).ToDictionary(pair => pair.Key, pair => pair.Value);
        Fuzzy = fuzzy;
        FuzzyDropped = fuzzyDropped;
        InvalidCount = Count(GamePackSkipReason.InvalidKey) + Count(GamePackSkipReason.EmptyTranslation)
            + Count(GamePackSkipReason.MalformedRecord);
        DuplicateCount = Count(GamePackSkipReason.Duplicate);
        ConflictCount = Count(GamePackSkipReason.Conflict);
    }

    private int Count(GamePackSkipReason reason) => Skipped.GetValueOrDefault(reason);

    public string? SuggestedTitle { get; }
    public IReadOnlyDictionary<string, string> Entries { get; }
    public int InvalidCount { get; }
    public int DuplicateCount { get; }
    public int ConflictCount { get; }
    /// <summary>Hazır paketin (biçim 2) cümle parçaları.</summary>
    public IReadOnlyDictionary<string, string> Segments { get; }
    /// <summary>Atlanan kayıtlar, nedenine göre (sıfır olanlar yok).</summary>
    public IReadOnlyDictionary<GamePackSkipReason, int> Skipped { get; }
    /// <summary>Hazır paketin OCR hatalarına dayanıklı arama verisi (<c>fuzzy</c> JSON nesnesi), pakete olduğu gibi yazılır.</summary>
    public string? Fuzzy { get; }
    /// <summary>Dosyada OCR verisi vardı ama bazı satırlar atlandığı için artık tutmuyor; kurulmaz.</summary>
    public bool FuzzyDropped { get; }
    /// <summary>Kurulacak satırlar (tam satırlar ve parçalar).</summary>
    public int AcceptedCount => Entries.Count + Segments.Count;
    /// <summary>Atlanan kayıtların toplamı.</summary>
    public int SkippedCount => Skipped.Values.Sum();

    /// <summary>Günlük satırı (Mac/iPhone ve Android ile aynı metin): kaç satır kabul edildi, kaçı neden atlandı.</summary>
    public string LogLine(string fileName)
    {
        var line = new StringBuilder($"Paket içe aktarma ({fileName}): {AcceptedCount} satır kabul edildi");
        if (Segments.Count > 0) line.Append($" ({Entries.Count} tam satır, {Segments.Count} parça)");
        line.Append($", {SkippedCount} kayıt atlandı");
        var reasons = Enum.GetValues<GamePackSkipReason>().Where(Skipped.ContainsKey)
            .Select(reason => $"{Skipped[reason]} {reason.LogName()}").ToList();
        if (reasons.Count > 0) line.Append(" (").Append(string.Join(", ", reasons)).Append(')');
        if (Fuzzy is not null) line.Append("; OCR'a dayanıklı arama verisi var");
        if (FuzzyDropped) line.Append("; OCR'a dayanıklı arama verisi atlanan satırlar yüzünden kurulmadı");
        return line.ToString();
    }

    /// <summary>Paket kurulunca günlüğe yazılan satır (Mac/iPhone ve Android ile aynı metin).</summary>
    public string InstallLog(string title)
    {
        title = title.Trim();
        return $"Paket kuruldu: {title} ({GamePackImporter.MakeId(title)}), {AcceptedCount} satır";
    }
}

public static partial class GamePackImporter
{
    /// <summary>İçe aktarılan çeviri dosyası için üst sınır (bellek taşmasını önler).</summary>
    public const int MaxFileBytes = 64 * 1024 * 1024;

    private static readonly UTF8Encoding StrictUtf8 = new(false, throwOnInvalidBytes: true);

    public static GamePackImportPreview Parse(byte[] data, string fileName)
    {
        if (data.Length > MaxFileBytes) throw new InvalidDataException("The file is too large.");
        var bytes = data.AsMemory();
        if (bytes.Span.StartsWith("\uFEFF"u8)) bytes = bytes[3..];
        string source;
        try { source = StrictUtf8.GetString(bytes.Span); }
        catch (DecoderFallbackException error) { throw new InvalidDataException("The file is not valid UTF-8.", error); }

        var pairs = new Pairs();
        switch (Path.GetExtension(fileName).ToLowerInvariant())
        {
            case ".json":
                return ParseJsonPreview(bytes, pairs);
            case ".txt":
                ParseText(source, pairs);
                break;
            case ".srt":
                ParseSrt(source, pairs);
                break;
            default:
                throw new InvalidDataException("Unsupported translation file type.");
        }
        return new GamePackImportPreview(null, pairs.Entries.AsReadOnly(), pairs.Skipped);
    }

    private static GamePackImportPreview ParseJsonPreview(ReadOnlyMemory<byte> bytes, Pairs pairs)
    {
        var segments = new Pairs();
        var title = ParseJson(bytes, pairs, segments, out var fuzzy);
        var skipped = new Dictionary<GamePackSkipReason, int>(pairs.Skipped);
        foreach (var (reason, count) in segments.Skipped) skipped[reason] = skipped.GetValueOrDefault(reason) + count;
        // OCR'a dayanıklı arama verisi paketteki bütün anahtarların sırasına bağlı: satır atlandıysa tutmaz.
        string? kept = null;
        if (fuzzy is not null)
        {
            List<ulong> order = [.. pairs.Entries.Keys.Union(segments.Entries.Keys)
                .Select(key => PackKey.Number(key)).OfType<ulong>().Order()];
            using var document = JsonDocument.Parse(fuzzy);
            if (PackFuzzyIndex.Decode(document.RootElement, order) is not null) kept = fuzzy;
        }
        return new GamePackImportPreview(title, pairs.Entries.AsReadOnly(), skipped, segments.Entries.AsReadOnly(),
            kept, fuzzy is not null && kept is null);
    }

    public static string MakeId(string title)
    {
        const int maxSlugLength = 80;
        var slug = new StringBuilder(maxSlugLength);
        var gap = false;
        foreach (var character in title)
        {
            if (!char.IsAsciiLetterOrDigit(character))
            {
                gap = slug.Length > 0;
                continue;
            }
            if (slug.Length + (gap ? 2 : 1) > maxSlugLength) break;
            if (gap) slug.Append('-');
            slug.Append(char.ToLowerInvariant(character));
            gap = false;
        }
        return "community-" + (slug.Length == 0 ? "game" : slug.ToString());
    }

    /// <summary>Checks whether the selected source and generated destination point to the same file.</summary>
    public static bool IsSourceDestination(string title, string directory, string sourcePath) =>
        SameFile(Path.GetFullPath(sourcePath), DestinationPath(Path.GetFullPath(directory), MakeId(title)));

    public static string Install(GamePackImportPreview preview, string title, string directory, bool replacing,
        string? sourcePath = null)
    {
        title = Nonblank(title) ?? throw new ArgumentException("A game title is required.", nameof(title));
        if (preview.Entries.Count == 0) throw new InvalidDataException("The pack has no usable translations.");

        var id = MakeId(title);
        directory = Path.GetFullPath(directory);
        var destination = DestinationPath(directory, id);
        if (sourcePath is not null && SameFile(Path.GetFullPath(sourcePath), destination))
            throw new InvalidOperationException("The source file is the pack destination.");

        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Guid.NewGuid():N}.tmp");
        var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        try
        {
            using (stream)
            {
                if (preview.Segments.Count == 0 && preview.Fuzzy is null)
                    JsonSerializer.Serialize(stream, new { format = 1, id, title, entries = preview.Entries });
                else
                    WriteFormatTwo(stream, preview, id, title);
            }
            Publish(temporary, destination, replacing);
        }
        finally
        {
            File.Delete(temporary);
        }
        return destination;
    }

    /// <summary>Parça ya da OCR verisi taşıyan paket: biçim 2 (<see cref="GamePack.Decode"/>).</summary>
    private static void WriteFormatTwo(Stream stream, GamePackImportPreview preview, string id, string title)
    {
        using var writer = new Utf8JsonWriter(stream);
        writer.WriteStartObject();
        writer.WriteNumber("format", 2);
        writer.WriteString("id", id);
        writer.WriteString("title", title);
        void Map(string name, IReadOnlyDictionary<string, string> map)
        {
            writer.WriteStartObject(name);
            foreach (var (key, value) in map) writer.WriteString(key, value);
            writer.WriteEndObject();
        }
        Map("entries", preview.Entries);
        if (preview.Segments.Count > 0) Map("segments", preview.Segments);
        if (preview.Fuzzy is not null)
        {
            writer.WritePropertyName("fuzzy");
            writer.WriteRawValue(preview.Fuzzy);
        }
        writer.WriteEndObject();
    }

    private static string DestinationPath(string fullDirectory, string id) => Path.Combine(fullDirectory, id + ".json");

    private static void Publish(string temporary, string destination, bool replacing)
    {
        if (OperatingSystem.IsWindows())
        {
            File.Move(temporary, destination, overwrite: replacing);
            return;
        }

        // The Unix File.Move without overwrite may check for existence before renaming.
        // A hard link checks and publishes the staged file in one operation.
        var result = replacing ? Rename(temporary, destination) : Link(temporary, destination);
        if (result != 0)
            throw new IOException($"Could not publish '{destination}'.", new Win32Exception(Marshal.GetLastPInvokeError()));
    }

    private static bool SameFile(string source, string destination)
    {
        if (source == destination) return true;

        if (OperatingSystem.IsWindows())
        {
            if (!File.Exists(source) || !File.Exists(destination)) return false;
            const FileShare sharing = FileShare.ReadWrite | FileShare.Delete;
            using var sourceHandle = File.OpenHandle(source, share: sharing);
            using var destinationHandle = File.OpenHandle(destination, share: sharing);
            // Compare volume and file IDs so casing, junctions and hard links cannot bypass the check.
            const int fileIdInfo = 18;
            if (!GetFileInformationByHandleEx(sourceHandle, fileIdInfo, out var sourceId, Marshal.SizeOf<FileId>())
                || !GetFileInformationByHandleEx(destinationHandle, fileIdInfo, out var destinationId, Marshal.SizeOf<FileId>()))
            {
                // Some volumes do not support file IDs. Use the resolved names instead.
                return SameResolvedPath(source, destination);
            }
            return sourceId.Equals(destinationId);
        }

        var resolved = RealPath(source);
        return resolved is not null && resolved == RealPath(destination);
    }

    internal static bool SameResolvedPath(string source, string destination) =>
        string.Equals(ResolvePath(source, isDirectory: false), ResolvePath(destination, isDirectory: false),
            StringComparison.OrdinalIgnoreCase);

    private static string ResolvePath(string path, bool isDirectory)
    {
        if (Path.GetDirectoryName(path) is not { } parent) return path;

        // Resolve directory junctions before looking for a link at the current component.
        var candidate = Path.Combine(ResolvePath(parent, isDirectory: true), Path.GetFileName(path));
        var target = isDirectory
            ? Directory.ResolveLinkTarget(candidate, returnFinalTarget: true)
            : File.ResolveLinkTarget(candidate, returnFinalTarget: true);
        return target is null ? candidate : ResolvePath(target.FullName, isDirectory);
    }

    private static string? RealPath(string path)
    {
        var nativePath = ResolveRealPath(path, IntPtr.Zero);
        if (nativePath == IntPtr.Zero) return null;
        try { return Marshal.PtrToStringUTF8(nativePath); }
        finally { Free(nativePath); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct FileId(ulong VolumeSerialNumber, ulong FileIdLow, ulong FileIdHigh);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass, out FileId info,
        int bufferSize);

    [LibraryImport("libc", EntryPoint = "link", StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    private static partial int Link(string existing, string destination);

    [LibraryImport("libc", EntryPoint = "rename", StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    private static partial int Rename(string existing, string destination);

    [LibraryImport("libc", EntryPoint = "realpath", StringMarshalling = StringMarshalling.Utf8)]
    private static partial IntPtr ResolveRealPath(string path, IntPtr buffer);

    [LibraryImport("libc", EntryPoint = "free")]
    private static partial void Free(IntPtr buffer);

    /// <summary>
    /// Hazır paket (biçim 1 ya da parça ve OCR verisi taşıyan biçim 2), <c>subtitles</c> zarfı ya da düz nesne. Biçim 2
    /// reddediliyordu: paket betiğiyle yapılan topluluk paketi hiç kurulamıyordu (#1355).
    /// </summary>
    private static string? ParseJson(ReadOnlyMemory<byte> bytes, Pairs pairs, Pairs segments, out string? fuzzy)
    {
        fuzzy = null;
        try
        {
            using var document = JsonDocument.Parse(bytes);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                throw new InvalidDataException("A translation JSON file must contain an object.");

            root.TryGetProperty("entries", out var entries);
            if (root.TryGetProperty("format", out var format) && format.ValueKind == JsonValueKind.Number)
            {
                var number = format.GetDouble();
                if (number is not (1 or 2)) throw new InvalidDataException("Unsupported translation pack format.");
                if (entries.ValueKind != JsonValueKind.Object)
                    throw new InvalidDataException("The pack entries must be a JSON object.");

                ReadPairs(entries, HashedKey, pairs);
                if (number == 2)
                {
                    if (root.TryGetProperty("segments", out var parts) && parts.ValueKind == JsonValueKind.Object)
                        ReadPairs(parts, HashedKey, segments);
                    if (root.TryGetProperty("fuzzy", out var signatures) && signatures.ValueKind == JsonValueKind.Object)
                        fuzzy = signatures.GetRawText();
                }
                return ReadTitle(root, "title") ?? ReadTitle(root, "game");
            }

            if (entries.ValueKind == JsonValueKind.Object)
                throw new InvalidDataException("The pack requires a supported format number.");
            if (root.TryGetProperty("subtitles", out var subtitles) && subtitles.ValueKind == JsonValueKind.Object)
            {
                ReadPairs(subtitles, PackKey.Key, pairs);
                return ReadTitle(root, "game") ?? ReadTitle(root, "title");
            }

            ReadPairs(root, PackKey.Key, pairs);
            return null;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException)
        {
            // JsonElement also throws when decoding a string with an invalid Unicode escape.
            throw new InvalidDataException("The file is not valid translation JSON.", error);
        }
    }

    private static void ReadPairs(JsonElement map, Func<string, string?> keyFor, Pairs pairs)
    {
        foreach (var member in map.EnumerateObject())
            pairs.Add(keyFor(member.Name), ReadString(member.Value));
    }

    private static string? ReadTitle(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) ? Nonblank(ReadString(value)) : null;

    private static string? ReadString(JsonElement value) =>
        value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static string? HashedKey(string key) =>
        key.Length == 16 && key.All(char.IsAsciiHexDigit) ? key.ToLowerInvariant() : null;

    private static string? Nonblank(string? text)
    {
        var trimmed = text?.Trim();
        return trimmed is { Length: > 0 } ? trimmed : null;
    }

    private static void ParseText(string source, Pairs pairs)
    {
        using var reader = new StringReader(source);
        while (reader.ReadLine() is { } line)
        {
            if (Nonblank(line) is not { } trimmed || trimmed.StartsWith('#')) continue;

            var index = line.IndexOf('\t');
            var width = 1;
            if (index < 0)
            {
                index = line.IndexOf(" = ", StringComparison.Ordinal);
                width = 3;
            }
            else if (index != line.LastIndexOf('\t'))
            {
                pairs.Skip(GamePackSkipReason.MalformedRecord);
                continue;
            }
            if (index < 0)
            {
                pairs.Skip(GamePackSkipReason.MalformedRecord);
                continue;
            }

            pairs.Add(PackKey.Key(line[..index]), line[(index + width)..]);
        }
    }

    private static void ParseSrt(string source, Pairs pairs)
    {
        using var reader = new StringReader(source);
        var cue = new List<string>(4);
        void FinishCue()
        {
            if (cue.Count == 0) return;
            if (cue.Count == 4 && cue[0].All(char.IsAsciiDigit) && ValidTiming(cue[1]))
                pairs.Add(PackKey.Key(cue[2]), cue[3]);
            else
                pairs.Skip(GamePackSkipReason.MalformedRecord);
            cue.Clear();
        }

        while (reader.ReadLine() is { } line)
        {
            if (Nonblank(line) is { } text) cue.Add(text);
            else FinishCue();
        }
        FinishCue();
    }

    private static bool ValidTiming(string line) =>
        line.Length == 29 && Timing().IsMatch(line) && line.AsSpan(0, 12).SequenceCompareTo(line.AsSpan(17, 12)) < 0;

    [GeneratedRegex(@"\A[0-9]{2}:[0-5][0-9]:[0-5][0-9],[0-9]{3} --> [0-9]{2}:[0-5][0-9]:[0-5][0-9],[0-9]{3}\z")]
    private static partial Regex Timing();

    private sealed class Pairs
    {
        // Keep every target of a conflicted key so later repeats still count.
        private readonly Dictionary<string, HashSet<string>> conflicts = [];
        private readonly Dictionary<GamePackSkipReason, int> counts = [];
        public Dictionary<string, string> Entries { get; } = [];

        public Dictionary<GamePackSkipReason, int> Skipped =>
            new(counts) { [GamePackSkipReason.Conflict] = conflicts.Count };

        public void Skip(GamePackSkipReason reason) => counts[reason] = counts.GetValueOrDefault(reason) + 1;

        public void Add(string? key, string? value)
        {
            if (key is null)
            {
                Skip(GamePackSkipReason.InvalidKey);
                return;
            }
            if (Nonblank(value) is not { } target)
            {
                Skip(GamePackSkipReason.EmptyTranslation);
                return;
            }
            if (conflicts.TryGetValue(key, out var targets))
            {
                if (!targets.Add(target)) Skip(GamePackSkipReason.Duplicate);
                return;
            }
            if (Entries.TryAdd(key, target)) return;

            var previous = Entries[key];
            if (previous == target)
            {
                Skip(GamePackSkipReason.Duplicate);
                return;
            }
            conflicts.Add(key, [previous, target]);
            Entries.Remove(key);
        }
    }
}
