// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Text;
using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// TV sayfasının bilgisayardan sunulması (ince kabuk, docs/tv-ince-kabuk.md). Ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/tv-app-bundle.json (Mac TVAppBundleTests, Android TvAppBundleTest ve
/// scripts/tv-shell.test.js ile aynı).
/// </summary>
public class TvAppBundleTests
{
    private static readonly HttpClient Http = new();

    private static JsonElement Fixture() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("tv-app-bundle.json"))).RootElement;

    private static Dictionary<string, byte[]> Files(JsonElement fixture) =>
        fixture.GetProperty("files").EnumerateObject().ToDictionary(p => p.Name, p => Encoding.UTF8.GetBytes(p.Value.GetString()!));

    [Fact]
    public void SharedVectors()
    {
        var fixture = Fixture();
        var bundle = TvAppBundle.Create(Files(fixture))!;
        Assert.NotNull(bundle);
        Assert.Equal(fixture.GetProperty("version").GetString(), bundle.Version);
        Assert.Equal(fixture.GetProperty("shellApi").GetInt32(), bundle.ShellApi);
        Assert.Equal(TvAppBundle.Paths, bundle.Files.Select(f => f.Path));
        foreach (var file in bundle.Files)
        {
            Assert.Equal(fixture.GetProperty("sha256").GetProperty(file.Path).GetString(), file.Sha256);
            Assert.Equal(fixture.GetProperty("sizes").GetProperty(file.Path).GetInt32(), file.Data.Length);
        }
        Assert.Equal(fixture.GetProperty("canonical").GetString(), bundle.Canonical);
        var key = fixture.GetProperty("key").GetString()!;
        Assert.Equal(fixture.GetProperty("hmac").GetString(), TvAppBundle.Signature(bundle.Canonical, key));
        var manifest = JsonDocument.Parse(bundle.Manifest(key)).RootElement;
        Assert.Equal(fixture.GetProperty("hmac").GetString(), manifest.GetProperty("hmac").GetString());
        Assert.Equal(1, manifest.GetProperty("format").GetInt32());
        Assert.Equal(TvAppBundle.Paths, manifest.GetProperty("files").EnumerateArray().Select(f => f.GetProperty("path").GetString()));
    }

    [Fact]
    public void RejectsPagesWithoutVersionOrShellApi()
    {
        var fixture = Fixture();
        foreach (var invalid in fixture.GetProperty("invalid").EnumerateArray())
        {
            var files = Files(fixture);
            files["app.js"] = Encoding.UTF8.GetBytes(invalid.GetProperty("app.js").GetString()!);
            Assert.Null(TvAppBundle.Create(files));
        }
        var missing = Files(fixture);
        missing.Remove("style.css");
        Assert.Null(TvAppBundle.Create(missing));
    }

    [Fact]
    public void FileLookupOnlyForOwnVersion()
    {
        var bundle = TvAppBundle.Create(Files(Fixture()))!;
        Assert.Equal("app.js", bundle.FileAt("/tv/app/0.9.80/app.js")?.Path);
        Assert.Null(bundle.FileAt("/tv/app/0.9.79/app.js"));
        Assert.Null(bundle.FileAt("/tv/app/0.9.80/platform.js"));
        Assert.Null(bundle.FileAt("/tv/app/0.9.80/../app.js"));
        Assert.Null(bundle.FileAt("/tv/app/0.9.80/x/app.js"));
    }

    /// <summary>Uygulamaya gömülü TV sayfası (tv-webos) paketlenebilir: sürümü TV uygulamasıyla aynı.</summary>
    [Fact]
    public void EmbeddedPageIsServable()
    {
        var bundle = TvAppBundle.Bundled;
        Assert.NotNull(bundle);
        var appinfo = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("../../../../tv-webos/appinfo.json"))).RootElement;
        Assert.Equal(appinfo.GetProperty("version").GetString(), bundle!.Version);
        Assert.True(bundle.ShellApi >= 1);
    }

    [Fact]
    public async Task ServesSignedManifestAndFilesOnlyWithKey()
    {
        var fixture = Fixture();
        var key = fixture.GetProperty("key").GetString()!;
        using var server = new SubtitleServer(0, key: key, allowLegacy: true) { TvApp = TvAppBundle.Create(Files(fixture)) };
        var port = await server.StartAsync();
        var root = $"http://127.0.0.1:{port}";

        // Eski TV'lere tanınan anahtarsız geçiş /tv/app'e uygulanmaz.
        using (var open = await Http.GetAsync(root + "/tv/app/manifest")) Assert.Equal(HttpStatusCode.Unauthorized, open.StatusCode);
        using (var wrong = await Http.GetAsync(root + "/tv/app/manifest?k=AAAAAAAAAAAAAAAAAAAAAA")) Assert.Equal(HttpStatusCode.Unauthorized, wrong.StatusCode);

        using var request = new HttpRequestMessage(HttpMethod.Get, root + "/tv/app/manifest?k=" + key);
        request.Headers.Add("Origin", "null");
        using var response = await Http.SendAsync(request);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.True(response.Headers.CacheControl?.NoStore);
        Assert.Equal("null", response.Headers.GetValues("Access-Control-Allow-Origin").Single());
        var manifest = JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement;
        Assert.Equal(fixture.GetProperty("hmac").GetString(), manifest.GetProperty("hmac").GetString());

        using var file = await Http.GetAsync(root + "/tv/app/0.9.80/app.js?k=" + key);
        Assert.Equal(HttpStatusCode.OK, file.StatusCode);
        Assert.Equal(fixture.GetProperty("files").GetProperty("app.js").GetString(), await file.Content.ReadAsStringAsync());
        Assert.True(file.Headers.CacheControl?.Private);
        Assert.Equal(TimeSpan.FromDays(365), file.Headers.CacheControl?.MaxAge);
        Assert.Equal("application/javascript; charset=utf-8", file.Content.Headers.ContentType?.ToString());
        Assert.Equal(fixture.GetProperty("sizes").GetProperty("app.js").GetInt32(), file.Content.Headers.ContentLength);

        using (var old = await Http.GetAsync(root + "/tv/app/0.9.70/app.js?k=" + key)) Assert.Equal(HttpStatusCode.NotFound, old.StatusCode);
        server.TvApp = null;
        using (var none = await Http.GetAsync(root + "/tv/app/manifest?k=" + key)) Assert.Equal(HttpStatusCode.NotFound, none.StatusCode);
    }
}
