// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using System.Text.Json.Nodes;
using CouchSubs.Shell;

namespace CouchSubs.Linux;

/// <summary>
/// Uygulamanın kalıcı klasörü. <c>COUCHSUBS_DATA</c> verilmişse orası (Docker'da /data), yoksa
/// <c>~/.local/share/CouchSubs</c>.
/// </summary>
public static class AppPaths
{
    public static string Data { get; } = Environment.GetEnvironmentVariable("COUCHSUBS_DATA") is { Length: > 0 } custom
        ? custom
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CouchSubs");

    public static string Models { get; } = Path.Combine(Data, "models");

    public static string Folder(string name) => Path.Combine(Data, name);
}

/// <summary>
/// Hesap kimliği, PS5 anahtarları ve TV anahtarı. Linux'ta Windows'un DPAPI'sinin karşılığı her kurulumda yoktur
/// (ekransız sunucuda anahtarlık çalışmaz); dosya yalnız sahibinin okuyabileceği izinle (0600) tutulur.
/// </summary>
public sealed class FileAppStore(string path) : IAppStore
{
    private readonly object gate = new();

    public static FileAppStore Default { get; } = new(Path.Combine(AppPaths.Data, "secure.json"));

    public void Save<T>(string key, T value)
    {
        lock (gate)
        {
            var all = ReadAll();
            all[key] = JsonSerializer.SerializeToNode(value);
            WriteAll(all);
        }
    }

    public T? Load<T>(string key)
    {
        lock (gate)
        {
            var node = ReadAll()[key];
            if (node is null) return default;
            try { return node.Deserialize<T>(); } catch (JsonException) { return default; }
        }
    }

    public void Remove(string key)
    {
        lock (gate)
        {
            var all = ReadAll();
            if (all.Remove(key)) WriteAll(all);
        }
    }

    private JsonObject ReadAll()
    {
        if (!File.Exists(path)) return [];
        try { return JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? []; }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException) { return []; }
    }

    private void WriteAll(JsonObject all)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, all.ToJsonString());
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        File.Move(temporary, path, overwrite: true);
    }
}

/// <summary>Sıradan ayarlar: veri klasöründe settings.json.</summary>
public sealed class FileSettingsStore : ISettingsStore
{
    private static readonly string FilePath = Path.Combine(AppPaths.Data, "settings.json");

    public UserSettings Load()
    {
        try { return JsonSerializer.Deserialize<UserSettings>(File.ReadAllText(FilePath)) ?? new UserSettings(); }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return new UserSettings(); }
    }

    public void Save(UserSettings settings)
    {
        Directory.CreateDirectory(AppPaths.Data);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(settings));
    }
}

/// <summary>Sunucu uykuya geçmez; yapılacak bir şey yok.</summary>
public sealed class NoSleepGuard : ISleepGuard
{
    public void Begin() { }
    public void End() { }
}
