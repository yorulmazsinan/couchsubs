// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>"Ekran yazılarını altyazıdan ayır": style olayının setApart alanı (TV ve OBS çizimi buna göre).</summary>
public class SetApartTests
{
    private static readonly HttpClient Http = new();

    private static async Task<string?> FirstStyle(SubtitleServer server, int port)
    {
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        while (await reader.ReadLineAsync() is { } line)
            if (line.StartsWith("data:") && line.Contains("fontSize")) return line;
        return null;
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task StyleCarriesSetApart(bool apart)
    {
        using var server = new SubtitleServer(0) { SetApart = apart };
        var port = await server.StartAsync();
        server.SendStyle(new SubtitleStyle());
        Assert.Contains($"\"setApart\":{(apart ? "true" : "false")}", await FirstStyle(server, port));
    }

    [Fact]
    public void SetApartIsOnByDefault() => Assert.True(new SubtitleServer(0).SetApart);
}
