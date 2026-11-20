// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Text;
using System.Text.Json;

namespace CouchSubs.Core.Tests;

/// <summary>Paket sunucusunun yerine geçen sahte HTTP: liste ve dosyalar bellekte.</summary>
internal sealed class FakePackServer : HttpMessageHandler
{
    public List<RemotePack> Packs { get; } = [];
    public Dictionary<string, byte[]> Files { get; } = [];
    public HttpStatusCode ListStatus { get; set; } = HttpStatusCode.OK;
    public string? ListPayload { get; set; }
    public List<string> Downloads { get; } = [];

    public void Add(string id, long version, string content)
    {
        var data = Encoding.UTF8.GetBytes(content);
        Packs.RemoveAll(p => p.Id == id);
        Packs.Add(new RemotePack(id, id, version, PackUpdater.Sha256(data), data.Length, 1));
        Files[id] = data;
    }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var path = request.RequestUri!.AbsolutePath;
        if (path == "/v1/packs")
            return Task.FromResult(new HttpResponseMessage(ListStatus) { Content = new StringContent(ListPayload ?? JsonSerializer.Serialize(new { packs = Packs })) });
        var id = path[(path.LastIndexOf('/') + 1)..];
        Downloads.Add(id);
        return Task.FromResult(Files.TryGetValue(id, out var data)
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(data) }
            : new HttpResponseMessage(HttpStatusCode.NotFound));
    }
}

public sealed class PackUpdaterTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "updater-" + Guid.NewGuid());
    private readonly FakePackServer server = new();
    private DateTimeOffset now = DateTimeOffset.FromUnixTimeSeconds(1_793_000_000);
    private string Packs => Path.Combine(root, "packs");

    private PackUpdater Make() =>
        new(new Uri("https://packs.example.test"), Packs, Path.Combine(root, "packs-remote.json"), server, () => now);

    private string? Content(string id)
    {
        var file = Path.Combine(Packs, $"{id}.json.gz");
        return File.Exists(file) ? File.ReadAllText(file) : null;
    }

    /// <summary>
    /// Paket dosyasının değiştirilmesini engeller. Windows'ta açık dosyanın (FileShare.Delete yok) üstüne taşıma yapılamaz;
    /// macOS ve Linux'ta rename açık dosyayı umursamaz, orada klasör salt okunur yapılır (yazma ve taşıma ikisi de düşer).
    /// </summary>
    private static IDisposable BlockReplacement(string file)
    {
        if (OperatingSystem.IsWindows()) return new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
        var directory = Path.GetDirectoryName(file)!;
        var mode = File.GetUnixFileMode(directory);
        File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserExecute);
        return new Restore(() => File.SetUnixFileMode(directory, mode));
    }

    private sealed class Restore(Action action) : IDisposable
    {
        public void Dispose() => action();
    }

    public void Dispose()
    {
        try { Directory.Delete(root, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    [Fact]
    public async Task DownloadsVerifiesAndSkipsUntilAWeekPasses()
    {
        server.Add("gta-6", 1, "one");
        using var updater = Make();
        Assert.Equal(["gta-6"], (await updater.RefreshAsync()).Downloaded);
        Assert.Equal("one", Content("gta-6"));

        server.Add("gta-6", 2, "two");
        Assert.True((await updater.RefreshAsync()).Skipped);
        now += PackUpdater.RefreshInterval + TimeSpan.FromSeconds(1);
        Assert.Equal(["gta-6"], (await updater.RefreshAsync()).Downloaded);
        Assert.Equal("two", Content("gta-6"));

        var count = server.Downloads.Count;
        await updater.RefreshAsync(force: true);
        Assert.Equal(count, server.Downloads.Count);
    }

    [Fact]
    public async Task FailedReplacementRetainsInstalledPackAndRetries()
    {
        server.Add("gta-6", 1, "one");
        using var updater = Make();
        Assert.Equal(["gta-6"], (await updater.RefreshAsync()).Downloaded);
        var installedBefore = Assert.Single(updater.InstalledPacks);

        server.Add("gta-6", 2, "two");
        using (BlockReplacement(Path.Combine(Packs, "gta-6.json.gz")))
        {
            var failed = await updater.RefreshAsync(force: true);

            Assert.Empty(failed.Downloaded);
            Assert.Equal("one", Content("gta-6"));
            Assert.Equal(installedBefore with { Version = -1 }, Assert.Single(updater.InstalledPacks));
        }

        var retried = await updater.RefreshAsync();
        Assert.Equal(["gta-6"], retried.Downloaded);
        Assert.Equal("two", Content("gta-6"));
        Assert.Equal(2, Assert.Single(updater.InstalledPacks).Version);
    }

    [Fact]
    public async Task WrongChecksumIsNeverInstalled()
    {
        server.Add("gta-6", 1, "good");
        server.Files["gta-6"] = Encoding.UTF8.GetBytes("tampered");
        using var updater = Make();
        Assert.Empty((await updater.RefreshAsync()).Downloaded);
        Assert.Null(Content("gta-6"));
        Assert.Empty(updater.InstalledPacks);
    }

    /// <summary>Yeni bir paket inemediyse kontrol zamanı ilerlemez: başka paket duruyor olsa da sonraki bakışta yeniden denenir.</summary>
    [Fact]
    public async Task FailedNewPackIsRetriedWithoutWaitingADay()
    {
        server.Add("gta-6", 1, "one");
        using var updater = Make();
        await updater.RefreshAsync();

        server.Add("rdr-2", 1, "new");
        var good = server.Files["rdr-2"];
        server.Files.Remove("rdr-2");
        now += PackUpdater.RefreshInterval + TimeSpan.FromSeconds(1);
        Assert.Empty((await updater.RefreshAsync()).Downloaded);

        server.Files["rdr-2"] = good;
        now += TimeSpan.FromSeconds(60);
        var retried = await updater.RefreshAsync(maxAge: TimeSpan.FromMinutes(10));
        Assert.False(retried.Skipped);
        Assert.Equal(["rdr-2"], retried.Downloaded);
        Assert.Equal("one", Content("gta-6"));
    }

    [Fact]
    public async Task RemovedPackIsDeletedAndUnreachableServerKeepsPacks()
    {
        server.Add("gta-6", 1, "one");
        using var updater = Make();
        await updater.RefreshAsync();
        server.ListStatus = HttpStatusCode.ServiceUnavailable;
        Assert.True((await updater.RefreshAsync(force: true)).Failed);
        Assert.Equal("one", Content("gta-6"));
        server.ListStatus = HttpStatusCode.OK;
        server.Packs.Clear();
        Assert.Equal(["gta-6"], (await updater.RefreshAsync(force: true)).Removed);
        Assert.Null(Content("gta-6"));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"packs\":null}")]
    public async Task MissingPackListMustKeepInstalledPacks(string malformedList)
    {
        server.Add("gta-6", 1, "one");
        using var updater = Make();
        await updater.RefreshAsync();

        server.ListPayload = malformedList;
        var result = await updater.RefreshAsync(force: true);
        Assert.True(result.Failed);
        Assert.Empty(result.Removed);
        Assert.Equal("one", Content("gta-6"));
        Assert.Single(updater.InstalledPacks);
    }

    /// <summary>Kullanıcının klasöre kendisi bıraktığı aynı adlı dosyanın üstüne yazılmaz, silinmez.</summary>
    [Fact]
    public async Task UserFilesAreLeftAlone()
    {
        Directory.CreateDirectory(Packs);
        File.WriteAllText(Path.Combine(Packs, "gta-6.json.gz"), "mine");
        server.Add("gta-6", 1, "server");
        server.Add("../evil", 1, "x");
        using var updater = Make();
        Assert.Empty((await updater.RefreshAsync()).Downloaded);
        Assert.Equal("mine", Content("gta-6"));
        Assert.DoesNotContain("evil", server.Downloads);
        updater.Clear();
        Assert.Equal("mine", Content("gta-6"));
    }

    [Fact]
    public void AddressComesOnlyFromConfiguration()
    {
        var assembly = typeof(PackUpdaterTests).Assembly;
        Assert.Null(PackUpdater.ConfiguredBaseUrl("", assembly));
        Assert.Null(PackUpdater.ConfiguredBaseUrl("ftp://x", assembly));
        Assert.Equal("packs.example.test", PackUpdater.ConfiguredBaseUrl("https://packs.example.test", assembly)?.Host);
    }

    [Fact]
    public void PackIdsMatchTheServer()
    {
        Assert.True(PackUpdater.IsValidId("gta-6"));
        Assert.False(PackUpdater.IsValidId("-gta"));
        Assert.False(PackUpdater.IsValidId("../evil"));
        Assert.False(PackUpdater.IsValidId("GTA"));
    }
}
