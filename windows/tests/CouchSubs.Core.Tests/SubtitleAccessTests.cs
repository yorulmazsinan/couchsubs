// SPDX-License-Identifier: AGPL-3.0-only
using System.Net;
using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

public class SubtitleAccessTests
{
    [Fact]
    public void SharedAccessVectors()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("subtitle-access.json")));
        var key = fixture.RootElement.GetProperty("key").GetString()!;
        foreach (var row in fixture.RootElement.GetProperty("requests").EnumerateArray())
        foreach (var path in new[] { "/events", "/speech/1.wav", "/voices/sample.wav", "/published.bin" })
        {
            var origin = row.GetProperty("origin").GetString();
            var request = SubtitleAccess.Parse($"GET {path}{row.GetProperty("query").GetString()} HTTP/1.1\r\nHost: localhost:8787\r\n" +
                (origin is null ? "" : $"Origin: {origin}\r\n"))!;
            Assert.Equal(row.GetProperty("status").GetInt32(), SubtitleAccess.Authorize(request, key, row.GetProperty("legacy").GetBoolean(), out var legacy));
            Assert.Equal(row.GetProperty("usedLegacy").GetBoolean(), legacy);
            // Paketli (http olmayan) ve kabul edilen her Origin aynen geri yansıtılır.
            Assert.Equal(row.GetProperty("status").GetInt32() != 403 && origin is not null && !origin.StartsWith("http") ? $"Access-Control-Allow-Origin: {origin}\r\nVary: Origin\r\n" : "", SubtitleAccess.Cors(request));
        }
        foreach (var peer in fixture.RootElement.GetProperty("peers").EnumerateObject())
            Assert.Equal(peer.Value.GetBoolean(), SubtitleAccess.IsLocalPeer(IPAddress.Parse(peer.Name)));
    }

    /// <summary>
    /// TV olay satırı (/tvlog, TV 0.9.116): nedeniyle günlüğe; eski satıra yaşı eklenir, denetim karakteri ve uzun satır
    /// kırpılır, 10 dakikada en çok 30 satır (Mac/iPhone ve Android'de aynı).
    /// </summary>
    [Fact]
    public void TvEventLineIsCleanedAndRateLimited()
    {
        var log = new SubtitleAccess.TvEventLog();
        var t0 = new DateTime(2026, 11, 26, 12, 0, 0, DateTimeKind.Utc);
        Assert.Equal("TV uygulaması olayı: hdmi rebuild (ev stalled blind 61s #1)", log.Line("hdmi rebuild (ev stalled blind 61s #1)", "0", t0));
        Assert.Equal("TV uygulaması olayı: exit intent (keeper, running) (42 sn önce)", log.Line("exit intent (keeper, running)", "42", t0));
        Assert.Equal("TV uygulaması olayı: a b c", log.Line("a\nb\u0000c\u0085", "-3", t0));
        Assert.Null(log.Line("   ", "0", t0));
        Assert.Null(log.Line(null, null, t0));
        Assert.Equal("TV uygulaması olayı: ".Length + 200, log.Line(new string('x', 400), "x", t0)!.Length);
        var limited = new SubtitleAccess.TvEventLog();
        for (var i = 0; i < 35; i++) Assert.Equal(i < 30, limited.Line("hdmi tune (loop " + i + ")", "0", t0) is not null);
        Assert.Equal("TV uygulaması olayı: page reload (stale 0.9.116>0.9.115) (sınır yüzünden 5 satır yazılmadı)",
            limited.Line("page reload (stale 0.9.116>0.9.115)", "0", t0 + SubtitleAccess.TvEventLog.Window));
    }

    /// <summary>Reddedilen Origin günlüğe değeriyle bir kez yazılır; en çok 16 farklı değer (Mac/iPhone ve Android'de aynı).</summary>
    [Fact]
    public void RejectedOriginIsLoggedOnce()
    {
        var log = new SubtitleAccess.RejectedOrigins();
        var request = SubtitleAccess.Parse("POST /pair HTTP/1.1\r\nHost: 192.168.1.20:8787\r\nOrigin: http://other.example\r\n")!;
        Assert.Equal(403, SubtitleAccess.Authorize(request, "anahtar", true, out _));
        Assert.Equal("altyazı sunucusu isteği reddetti (403): Origin \"http://other.example\" kabul edilmedi (yol /pair, Host 192.168.1.20:8787)", log.Line(request));
        Assert.Null(log.Line(request));
        for (var index = 0; index < 20; index++)
        {
            var other = SubtitleAccess.Parse($"GET /events HTTP/1.1\r\nHost: a\r\nOrigin: http://o{index}.example\r\n")!;
            Assert.Equal(index < 15, log.Line(other) is not null);
        }
    }

    [Theory]
    [InlineData("Origin: null\r\nOrigin: null")]
    [InlineData("Host: localhost\r\nHost: other")]
    [InlineData(" Origin: null")]
    public void RejectsAmbiguousHeaders(string headers) =>
        Assert.Null(SubtitleAccess.Parse("GET /events HTTP/1.1\r\n" + headers));

    /// İkinci ekran eski TV'lere tanınan anahtarsız geçişten yararlanmaz (Mac ve Android'de aynı durumlar).
    [Theory]
    [InlineData("/view", 401)]
    [InlineData("/view?k=yanlis", 401)]
    [InlineData("/view?k=anahtar", 200)]
    [InlineData("/events?viewer=second", 401)]
    [InlineData("/events?viewer=second&k=anahtar", 200)]
    [InlineData("/events", 200)]
    [InlineData("/events?viewer=obs", 200)]
    public void SecondScreenAlwaysNeedsTheKey(string target, int status)
    {
        var request = SubtitleAccess.Parse($"GET {target} HTTP/1.1\r\nHost: 192.168.1.20:8787")!;
        Assert.Equal(status, SubtitleAccess.Authorize(request, "anahtar", true, out _));
        var same = SubtitleAccess.Parse("GET /events?viewer=second&k=anahtar HTTP/1.1\r\nHost: 192.168.1.20:8787\r\nOrigin: http://192.168.1.20:8787")!;
        Assert.Equal(200, SubtitleAccess.Authorize(same, "anahtar", true, out _));
    }

    [Fact]
    public void RandomKeysAndDuplicateQuery()
    {
        var first = SubtitleAccess.CreateKey();
        Assert.Matches("^[A-Za-z0-9_-]{22}$", first);
        Assert.NotEqual(first, SubtitleAccess.CreateKey());
        var request = SubtitleAccess.Parse($"GET /events?k={first}&k={first} HTTP/1.1\r\nHost: localhost")!;
        Assert.Equal(401, SubtitleAccess.Authorize(request, first, true, out _));
    }

    [Fact]
    public async Task KeylessObsPageIsNotReportedAsOldTvApp()
    {
        using var server = new SubtitleServer(0, key: "AAAAAAAAAAAAAAAAAAAAAA", allowLegacy: true);
        var port = await server.StartAsync();
        using var http = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}"), Timeout = TimeSpan.FromSeconds(5) };
        using var obs = await http.GetAsync("/events?viewer=obs", HttpCompletionOption.ResponseHeadersRead);
        Assert.Equal(HttpStatusCode.OK, obs.StatusCode);
        Assert.False(server.HasLegacyClient);
        using var tv = await http.GetAsync("/events", HttpCompletionOption.ResponseHeadersRead);
        Assert.Equal(HttpStatusCode.OK, tv.StatusCode);
        Assert.True(server.HasLegacyClient);
    }

    [Fact]
    public async Task RotationClosesStreamsAndProtectsFiles()
    {
        using var server = new SubtitleServer(0, key: "AAAAAAAAAAAAAAAAAAAAAA", allowLegacy: false);
        var port = await server.StartAsync();
        using var http = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}"), Timeout = TimeSpan.FromSeconds(5) };
        using var missing = await http.GetAsync("/events");
        Assert.Equal(HttpStatusCode.Unauthorized, missing.StatusCode);
        using var stream = await http.GetAsync("/events?k=" + server.AccessKey, HttpCompletionOption.ResponseHeadersRead);
        Assert.Equal(HttpStatusCode.OK, stream.StatusCode);
        Assert.Equal(1, server.ConnectedClients);
        var old = server.AccessKey;
        server.RotateKey(SubtitleAccess.CreateKey());
        Assert.Equal(0, server.ConnectedClients);
        using var expired = await http.GetAsync("/events?k=" + old);
        Assert.Equal(HttpStatusCode.Unauthorized, expired.StatusCode);
        using var current = await http.GetAsync("/events?k=" + server.AccessKey, HttpCompletionOption.ResponseHeadersRead);
        Assert.Equal(HttpStatusCode.OK, current.StatusCode);
        using var foreignRequest = new HttpRequestMessage(HttpMethod.Get, "/events?k=" + server.AccessKey);
        foreignRequest.Headers.Add("Origin", "https://foreign.example");
        using var foreign = await http.SendAsync(foreignRequest);
        Assert.Equal(HttpStatusCode.Forbidden, foreign.StatusCode);
        Assert.False(foreign.Headers.Contains("Access-Control-Allow-Origin"));
        using var page = await http.GetAsync("/obs");
        Assert.Equal(HttpStatusCode.OK, page.StatusCode);
        Assert.DoesNotContain(server.AccessKey, await page.Content.ReadAsStringAsync());
        server.Publish([1, 2, 3], "/published.bin", "application/octet-stream");
        using var fileMissing = await http.GetAsync("/published.bin");
        Assert.Equal(HttpStatusCode.Unauthorized, fileMissing.StatusCode);
        Assert.Equal(new byte[] { 1, 2, 3 }, await http.GetByteArrayAsync("/published.bin?k=" + server.AccessKey));
    }
}
