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
        Assert.False(response.Headers.Contains("Access-Control-Allow-Origin"));
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

    /// <summary>Ek alanın çevirisi kendi olayıyla gider (eski TV uygulamaları tanımadığı olayı yok sayar; Mac ile aynı).</summary>
    [Fact]
    public async Task StreamsRegionTranslationsAndTheirClear()
    {
        using var server = new SubtitleServer(0);
        var received = new List<SubtitleEvent>();
        server.EventSent += received.Add;
        var port = await server.StartAsync();
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 1);
        var box = new TextBox(0.7, 0.05, 0.95, 0.12);
        server.SendRegion("q", "Demirciyi bul", box, 0.03);
        server.SendRegion("q", "", null);
        server.ClearRegions();

        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var lines = await ReadLines(reader, "event: region-clear");
        Assert.Contains("event: region", lines);
        Assert.Contains("data: {\"box\":{\"bottom\":0.12,\"left\":0.7,\"right\":0.95,\"top\":0.05},\"id\":\"q\",\"line\":0.03,\"text\":\"Demirciyi bul\"}", lines);
        Assert.Contains("data: {\"id\":\"q\",\"text\":\"\"}", lines);
        Assert.Equal([new SubtitleEvent(SubtitleEventKind.Region, "Demirciyi bul", Id: "q", Box: box), new SubtitleEvent(SubtitleEventKind.Region, "", Id: "q"),
                      new SubtitleEvent(SubtitleEventKind.RegionClear)], received);
    }

    /// <summary>Ek alanın ayrı yazı grupları <c>blocks</c> ile kendi yerleriyle gider; birleşik <c>text</c> eski TV'ler için kalır.</summary>
    [Fact]
    public async Task StreamsRegionBlocksBesideTheJoinedText()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 1);
        var box = new TextBox(0.6, 0.05, 0.95, 0.2);
        server.SendRegion("q", "Find\nGo", box, 0.03, null,
                          [new ScreenTranslation.Item("Find", "Find", new TextBox(0.7, 0.05, 0.95, 0.08), 0.03),
                           new ScreenTranslation.Item("Go", "Go", new TextBox(0.6, 0.15, 0.7, 0.2), 0.04)]);
        // Boşalan alanda blok gönderilmez.
        server.SendRegion("q", "", null, null, null, [new ScreenTranslation.Item("Go", "Go", new TextBox(0.6, 0.15, 0.7, 0.2), 0.04)]);
        server.ClearRegions();

        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var lines = await ReadLines(reader, "event: region-clear");
        Assert.Contains("data: {\"blocks\":[{\"box\":{\"bottom\":0.08,\"left\":0.7,\"right\":0.95,\"top\":0.05},\"line\":0.03,\"text\":\"Find\"}," +
                        "{\"box\":{\"bottom\":0.2,\"left\":0.6,\"right\":0.7,\"top\":0.15},\"line\":0.04,\"text\":\"Go\"}]," +
                        "\"box\":{\"bottom\":0.2,\"left\":0.6,\"right\":0.95,\"top\":0.05},\"id\":\"q\",\"line\":0.03,\"text\":\"Find\\nGo\"}", lines);
        Assert.Contains("data: {\"id\":\"q\",\"text\":\"\"}", lines);
    }

    /// <summary>Eşleştirilmiş TV anahtarlı bağlantıda da ek alan bloklarını (<c>blocks</c>) aynen alır; eski (anahtarsız)
    /// bağlantılar kapalıyken anahtarsız istek reddedilir.</summary>
    [Fact]
    public async Task KeyedStreamCarriesRegionBlocks()
    {
        using var server = new SubtitleServer(0, allowLegacy: false);
        var port = await server.StartAsync();
        using var anonymous = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        Assert.Equal(System.Net.HttpStatusCode.Unauthorized, anonymous.StatusCode);
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events?k={server.AccessKey}", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 1);
        server.SendRegion("q", "Find\nGo", new TextBox(0.6, 0.05, 0.95, 0.2), 0.03, null,
                          [new ScreenTranslation.Item("Find", "Find", new TextBox(0.7, 0.05, 0.95, 0.08), 0.03),
                           new ScreenTranslation.Item("Go", "Go", new TextBox(0.6, 0.15, 0.7, 0.2), 0.04)]);
        server.ClearRegions();

        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var lines = await ReadLines(reader, "event: region-clear");
        Assert.Contains("data: {\"blocks\":[{\"box\":{\"bottom\":0.08,\"left\":0.7,\"right\":0.95,\"top\":0.05},\"line\":0.03,\"text\":\"Find\"}," +
                        "{\"box\":{\"bottom\":0.2,\"left\":0.6,\"right\":0.7,\"top\":0.15},\"line\":0.04,\"text\":\"Go\"}]," +
                        "\"box\":{\"bottom\":0.2,\"left\":0.6,\"right\":0.95,\"top\":0.05},\"id\":\"q\",\"line\":0.03,\"text\":\"Find\\nGo\"}", lines);
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

    /// <summary>"Ekranı çevir" sonuçları da pencereye gider: altyazı yalnız bilgisayardayken (TV yok) hiçbir yerde görünmüyordu.</summary>
    [Fact]
    public void LocalListenerGetsScreenTranslations()
    {
        using var server = new SubtitleServer(0);
        var received = new List<SubtitleEvent>();
        server.EventSent += received.Add;
        var box = new TextBox(0.1, 0.1, 0.4, 0.2);
        server.SendScreen([new ScreenTranslation.Item("Map\nInventory", "Harita\nEnvanter", box, 0.03), new ScreenTranslation.Item("Leave", "Ayrıl", box, 0.03)], 12000);
        server.ClearScreen();
        Assert.Equal([new SubtitleEvent(SubtitleEventKind.Screen, "Harita\nEnvanter\nAyrıl", 12000, Paragraphs: true), new SubtitleEvent(SubtitleEventKind.ScreenClear)], received);
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
        server.SendStyle(new SubtitleStyle(58, 10, SubtitlePlacement.Above, 40, true, SubtitleTextColor.Yellow, TvDisplayMode.Overlay, true, SubtitleBackgroundShape.Band));

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
        // Varsayılan: önceki satırlar üstte kalır (eski davranış); ayar TV'ye gider.
        Assert.Contains("\"stackPrevious\":true", data);
        // Tam genişlik bandı TV'ye gider; eski kayıtta alan yoksa yazı kadar kalır.
        Assert.Contains("\"backgroundShape\":\"band\"", data);
        Assert.Equal(SubtitleBackgroundShape.Fit, System.Text.Json.JsonSerializer.Deserialize<SubtitleStyle>("{\"FontSize\":58}")!.BackgroundShape);
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
        Assert.Equal(new SubtitleStyle(58, 12, SubtitlePlacement.Cover, 90, false), style);
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
        using var server = new SubtitleServer(0) { InstanceId = "3f2a-b9" };
        var port = await server.StartAsync();
        using var http = new HttpClient();
        var body = await http.GetStringAsync($"http://127.0.0.1:{port}/hello");
        Assert.Equal("{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"3f2a-b9\",\"tvs\":0}", body);
        Assert.DoesNotContain(server.AccessKey, body);
    }

    /// <summary>Kurulum kimliği kalıcıdır: aynı ağdaki iki CouchSubs'ı TV bununla ayırır (GitHub #425).</summary>
    [Fact]
    public void InstallationIdIsStable()
    {
        using var first = new SubtitleServer(0);
        using var second = new SubtitleServer(0);
        Assert.False(string.IsNullOrEmpty(first.InstanceId));
        Assert.Equal(first.InstanceId, second.InstanceId);
        Assert.Equal("{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"ab\",\"tvs\":2}", SubtitleServer.HelloBody("a\"b", 2));
    }

    // Yeni tarayıcılı TV'ler (Tizen 9.0) yerel ağdaki sunucuya ön istekte izin başlığı ister.
    [Fact]
    public async Task PreflightAllowsPrivateNetworkAccess()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        using var http = new HttpClient();
        // TV uygulamasının kökeni paketli uygulamadır (webOS/Tizen "null"); yabancı kökenlere izin verilmez.
        using var request = new HttpRequestMessage(HttpMethod.Options, $"http://127.0.0.1:{port}/events?k={server.AccessKey}");
        request.Headers.Add("Origin", "null");
        request.Headers.Add("Access-Control-Request-Private-Network", "true");
        using var response = await http.SendAsync(request);
        Assert.Equal(System.Net.HttpStatusCode.NoContent, response.StatusCode);
        Assert.Equal("true", Assert.Single(response.Headers.GetValues("Access-Control-Allow-Private-Network")));
        Assert.Equal("null", Assert.Single(response.Headers.GetValues("Access-Control-Allow-Origin")));
        Assert.Contains("POST", Assert.Single(response.Headers.GetValues("Access-Control-Allow-Methods")));
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
