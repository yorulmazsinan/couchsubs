// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

public class SubtitleServerTests
{
    private static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };

    private static async Task WaitUntil(Func<bool> condition, int timeoutMs = 3000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "Koşul zamanında sağlanmadı");
            await Task.Delay(20);
        }
    }

    private static async Task<List<string>> ReadLines(StreamReader reader, string until)
    {
        var lines = new List<string>();
        while (await reader.ReadLineAsync() is { } line)
        {
            lines.Add(line);
            if (line == until) break;
        }
        return lines;
    }

    [Fact]
    public async Task StreamsSubtitleAndClearEventsWithCors()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();

        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("*", response.Headers.GetValues("Access-Control-Allow-Origin").Single());
        Assert.StartsWith("text/event-stream", response.Content.Headers.ContentType?.ToString());

        await WaitUntil(() => server.ConnectedClients == 1);
        server.SendSubtitle("Merhaba", 4000, new TextBox(0.25, 0.8, 0.75, 0.87499));
        // Aynı cümlenin uzamış okuması: TV öncekinin üstüne yığmaz, yerine koyar.
        server.SendSubtitle("Merhaba dostum", 4000, replaces: true);
        server.Clear();

        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var lines = await ReadLines(reader, "event: clear");
        Assert.Contains("event: subtitle", lines);
        Assert.Contains(lines, l => l.StartsWith("data:") && l.Contains("\"text\":\"Merhaba\"") && l.Contains("\"duration\":4000")
            && l.Contains("\"box\":{\"bottom\":0.875,\"left\":0.25,\"right\":0.75,\"top\":0.8}") && !l.Contains("replace"));
        Assert.Contains(lines, l => l.StartsWith("data:") && l.Contains("\"text\":\"Merhaba dostum\"") && l.Contains("\"replace\":true"));
    }

    /// TV yarı açık bağlantıyı adlı "ping" olayının gelmemesinden anlar; yorum satırını EventSource görmez.
    [Fact]
    public async Task PingIsSentAsNamedEvent()
    {
        using var server = new SubtitleServer(0, TimeSpan.FromMilliseconds(50));
        var port = await server.StartAsync();
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var lines = await ReadLines(reader, "event: ping");
        Assert.Equal("event: ping", lines[^1]);
        Assert.Equal("data: {}", await reader.ReadLineAsync());
    }

    [Fact]
    public async Task StreamsScreenTranslationsAndTheirClear()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 1);
        server.SendScreen([
            new("Map\nSettings", "Harita\nAyarlar", new TextBox(0.05, 0.3, 0.2, 0.4), 0.03),
            new("Open the door.", "Kapıyı aç.", new TextBox(0.4, 0.8, 0.6, 0.84), 0.04),
        ], 12000);
        server.ClearScreen();

        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var lines = await ReadLines(reader, "event: screen-clear");
        Assert.Contains("event: screen", lines);
        Assert.Contains(lines, l => l.StartsWith("data:") && l.Contains("\"duration\":12000") &&
            l.Contains("{\"box\":{\"bottom\":0.4,\"left\":0.05,\"right\":0.2,\"top\":0.3},\"line\":0.03,\"paragraphs\":true,\"text\":\"Harita\\nAyarlar\"}") &&
            l.Contains("{\"box\":{\"bottom\":0.84,\"left\":0.4,\"right\":0.6,\"top\":0.8},\"line\":0.04,\"text\":\"Kapıyı aç.\"}"));
    }

    [Fact]
    public async Task ObsOverlayIsServedAndNotCountedAsTv()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();

        using var page = await Http.GetAsync($"http://127.0.0.1:{port}/obs");
        Assert.Equal(HttpStatusCode.OK, page.StatusCode);
        Assert.StartsWith("text/html", page.Content.Headers.ContentType?.ToString());
        Assert.Contains("/events?viewer=obs", await page.Content.ReadAsStringAsync());

        // OBS katmanı olayları alır ama "TV bağlı" sayısına katılmaz.
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events?viewer=obs", HttpCompletionOption.ResponseHeadersRead);
        await Task.Delay(200);
        Assert.Equal(0, server.ConnectedClients);
        server.SendSubtitle("Merhaba", 4000);
        server.Clear();
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        Assert.Contains("event: subtitle", await ReadLines(reader, "event: clear"));
    }

    /// Altyazı yalnız bilgisayar ekranındayken TV'ye altyazı gitmez; OBS katmanı ve dublaj sesi gitmeye devam eder.
    [Fact]
    public async Task SubtitlesSkipTvsWhenTvOutputIsOff()
    {
        using var server = new SubtitleServer(0) { SendsToTv = false };
        var port = await server.StartAsync();
        using var tv = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        using var obs = await Http.GetAsync($"http://127.0.0.1:{port}/events?viewer=obs", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 1);
        await Task.Delay(200);
        server.SendSubtitle("Merhaba", 4000);
        server.Clear();
        server.StopSpeech();

        using var obsReader = new StreamReader(await obs.Content.ReadAsStreamAsync());
        Assert.Contains("event: subtitle", await ReadLines(obsReader, "event: clear"));
        using var tvReader = new StreamReader(await tv.Content.ReadAsStreamAsync());
        Assert.DoesNotContain("event: subtitle", await ReadLines(tvReader, "event: speech-stop"));
    }

    /// Bilgisayar ekranındaki pencere sunucudan geçen altyazıyı alır; sunucu başlamamış olsa da.
    [Fact]
    public void LocalListenerGetsSubtitleAndClear()
    {
        using var server = new SubtitleServer(0);
        var received = new List<SubtitleEvent>();
        server.EventSent += received.Add;
        server.SendSubtitle("Merhaba", 4000, null, true);
        server.Clear();
        Assert.Equal([new SubtitleEvent(SubtitleEventKind.Subtitle, "Merhaba", 4000, true), SubtitleEvent.Cleared], received);
    }

    [Fact]
    public async Task TurkishTextIsSentAsUtf8()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 1);
        server.SendSubtitle("Kapıyı tut, evlat!", 4000);
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var lines = await ReadLines(reader, "");
        lines = await ReadLines(reader, "");
        Assert.Contains(lines, l => l.Contains("Kapıyı tut, evlat!"));
    }

    [Fact]
    public async Task NewClientReceivesLastStyle()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        server.SendStyle(new SubtitleStyle(58, 10, SubtitlePlacement.Above, 40, true, SubtitleTextColor.Yellow, TvDisplayMode.Overlay));

        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        string? data = null;
        while (await reader.ReadLineAsync() is { } line)
            if (line.StartsWith("data:")) { data = line; break; }
        Assert.Contains("\"fontSize\":58", data);
        Assert.Contains("\"bottomPercent\":10", data);
        Assert.Contains("\"placement\":\"above\"", data);
        Assert.Contains("\"background\":40", data);
        Assert.Contains("\"bold\":true", data);
        Assert.Contains("\"textColor\":\"yellow\"", data);
        Assert.Contains("\"displayMode\":\"overlay\"", data);
    }

    [Fact]
    public void DisplayModeIsSavedAndOldSettingsStayInsideTheApp()
    {
        var old = System.Text.Json.JsonSerializer.Deserialize<SubtitleStyle>("{\"FontSize\":58}");
        Assert.Equal(TvDisplayMode.InApp, old!.DisplayMode);
        var saved = System.Text.Json.JsonSerializer.Serialize(old with { DisplayMode = TvDisplayMode.Overlay });
        Assert.Contains("\"Overlay\"", saved);
        Assert.Equal(TvDisplayMode.Overlay, System.Text.Json.JsonSerializer.Deserialize<SubtitleStyle>(saved)!.DisplayMode);
    }

    [Fact]
    public void OldSavedStyleGetsNewDefaults()
    {
        var style = System.Text.Json.JsonSerializer.Deserialize<SubtitleStyle>("{\"FontSize\":58,\"BottomPercent\":12}");
        Assert.Equal(new SubtitleStyle(58, 12, SubtitlePlacement.Cover, 72, false), style);
        var again = System.Text.Json.JsonSerializer.Deserialize<SubtitleStyle>(System.Text.Json.JsonSerializer.Serialize(style! with { Placement = SubtitlePlacement.Below }));
        Assert.Equal(SubtitlePlacement.Below, again!.Placement);
    }

    [Fact]
    public async Task ClientCountDropsWhenClientDisconnects()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 1);
        response.Dispose();
        await WaitUntil(() => server.ConnectedClients == 0);
    }

    [Fact]
    public async Task HelloIdentifiesTheApp()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        using var http = new HttpClient();
        Assert.Equal("{\"app\":\"couchsubs\"}", await http.GetStringAsync($"http://127.0.0.1:{port}/hello"));
    }

    [Fact]
    public async Task UnknownPathIs404()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/nope");
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }
}
