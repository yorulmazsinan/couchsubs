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
            Assert.Equal(origin is "null" or "file://" or "app://couchsubs" ? $"Access-Control-Allow-Origin: {origin}\r\nVary: Origin\r\n" : "", SubtitleAccess.Cors(request));
        }
        foreach (var peer in fixture.RootElement.GetProperty("peers").EnumerateObject())
            Assert.Equal(peer.Value.GetBoolean(), SubtitleAccess.IsLocalPeer(IPAddress.Parse(peer.Name)));
    }

    [Theory]
    [InlineData("Origin: null\r\nOrigin: null")]
    [InlineData("Host: localhost\r\nHost: other")]
    [InlineData(" Origin: null")]
    public void RejectsAmbiguousHeaders(string headers) =>
        Assert.Null(SubtitleAccess.Parse("GET /events HTTP/1.1\r\n" + headers));

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
