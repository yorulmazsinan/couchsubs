// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Text.Json;
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

    /// <summary>Eski TV uygulaması (sürüm bildirmeyen; 0.9.7'den önceki sürümler <c>clear</c> gelir gelmez satırı kaldırır):
    /// <c>clear</c> ona satırın en az görünme süresi dolunca gider, yeni TV'ye hemen. Arada yeni satır gelirse eski
    /// <c>clear</c> hiç gitmez (Mac ve Android ile aynı).</summary>
    [Fact]
    public async Task ClearReachesOldTvAppsOnlyAfterTheLineWasReadable()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        using var old = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        using var fresh = await Http.GetAsync($"http://127.0.0.1:{port}/events?v=0.9.71", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 2);
        static async Task<List<(string Line, DateTime At)>> Events(HttpResponseMessage response)
        {
            using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
            var seen = new List<(string, DateTime)>();
            while (await reader.ReadLineAsync() is { } line)
            {
                if (!line.StartsWith("event: ")) continue;
                seen.Add((line, DateTime.UtcNow));
                if (line == "event: clear") break;
            }
            return seen;
        }
        var oldEvents = Events(old);
        var freshEvents = Events(fresh);
        var start = DateTime.UtcNow;
        server.SendSubtitle("Selam", 4000);
        server.Clear();
        // Satır kalkmadan yeni satır geldi: eski TV'ye bekleyen clear gitmez, yenisininki süresi dolunca gider.
        await Task.Delay(500);
        server.SendSubtitle("Yeni", 4000);
        server.Clear();
        var freshSeen = await freshEvents;
        var oldSeen = await oldEvents;
        Assert.True((freshSeen.First(e => e.Line == "event: clear").At - start).TotalSeconds < 1, "Yeni TV satırı kendisi tutar");
        Assert.Equal(2, oldSeen.Count(e => e.Line == "event: subtitle"));
        // İkinci satır 0,5 sn'de geldi; 4 harf → 2,24 sn tutulur.
        Assert.True((oldSeen.First(e => e.Line == "event: clear").At - start).TotalSeconds > 2.5);
        Assert.Equal(TimeSpan.FromMilliseconds(2240), SubtitleServer.LegacyClearHold(4));
        Assert.Equal(TimeSpan.FromSeconds(5), SubtitleServer.LegacyClearHold(500));
    }

    /// TV uygulaması gösterdiği HDMI girişini akışa bağlanırken bildirir; bekçi PS tuşunu bununla tanır.
    [Fact]
    public async Task RemembersTheHdmiInputTheTvAppShows()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        Assert.Null(server.ConsolePort);
        using (var obs = await Http.GetAsync($"http://127.0.0.1:{port}/events?viewer=obs&hdmi=1", HttpCompletionOption.ResponseHeadersRead))
        {
            await Task.Delay(100);
            Assert.Null(server.ConsolePort); // izleyici (OBS) giriş bildirmez
        }
        using (var response = await Http.GetAsync($"http://127.0.0.1:{port}/events?hdmi=3", HttpCompletionOption.ResponseHeadersRead))
        {
            await WaitUntil(() => server.ConnectedClients == 1);
            Assert.Equal(3, server.ConsolePort);
        }
        await WaitUntil(() => server.ConnectedClients == 0);
        Assert.Equal(3, server.ConsolePort); // bağlantı kopsa da akılda kalır
        Assert.Null(SubtitleServer.ParseHdmiPort("9"));
        Assert.Null(SubtitleServer.ParseHdmiPort("12"));
        Assert.Null(SubtitleServer.ParseHdmiPort(null));
        Assert.Equal(4, SubtitleServer.ParseHdmiPort("4"));
    }

    /// TV uygulaması sürümünü akışla bildirir; bildirmeyen TV (0.9.69'den eski) eski sayılır, OBS sayılmaz (#884, #891).
    [Fact]
    public async Task RemembersTheTvAppVersionAndTreatsSilentTvsAsOld()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        Assert.Null(server.TvAppVersion);
        using (var obs = await Http.GetAsync($"http://127.0.0.1:{port}/events?viewer=obs", HttpCompletionOption.ResponseHeadersRead))
        {
            await Task.Delay(100);
            Assert.Null(server.TvAppVersion);
        }
        using (var old = await Http.GetAsync($"http://127.0.0.1:{port}/events?hdmi=2", HttpCompletionOption.ResponseHeadersRead))
        {
            await WaitUntil(() => server.TvAppVersion is not null);
            Assert.Equal("", server.TvAppVersion);
        }
        using (var fresh = await Http.GetAsync($"http://127.0.0.1:{port}/events?v=0.9.69&hdmi=2", HttpCompletionOption.ResponseHeadersRead))
        {
            await WaitUntil(() => server.TvAppVersion == "0.9.69");
        }
        Assert.Equal("", SubtitleServer.ParseTvAppVersion("0.9.70<script>"));
        Assert.True(SubtitleServer.IsTvAppOutdated("", "0.9.69"));
        Assert.True(SubtitleServer.IsTvAppOutdated("0.9.49", "0.9.69"));
        Assert.False(SubtitleServer.IsTvAppOutdated("0.9.69", "0.9.69"));
        Assert.False(SubtitleServer.IsTvAppOutdated("0.9.70", "0.9.69"));
        Assert.False(SubtitleServer.IsTvAppOutdated("", ""));
    }

    /// <summary>İki TV'li ev (LG OLED ve TCL Google TV): öbür TV'nin bildirdiği sürüm kayıtlı TV'ninki sayılmaz. Adreslerden
    /// biri bilinmiyorsa (adressiz Android TV, yerel olmayan bağlantı) kayıtlı TV sayılır. Mac/iPhone ve Android ile aynı.</summary>
    [Fact]
    public void TvAppReportOnlyConcernsTheSavedTv()
    {
        Assert.True(SubtitleServer.IsFromSavedTv("192.168.1.40", "192.168.1.40"));
        Assert.True(SubtitleServer.IsFromSavedTv("192.168.1.40", " 192.168.1.40 "));
        Assert.True(SubtitleServer.IsFromSavedTv("192.168.1.40", "::ffff:192.168.1.40"));
        Assert.False(SubtitleServer.IsFromSavedTv("192.168.1.41", "192.168.1.40"));
        Assert.True(SubtitleServer.IsFromSavedTv("", "192.168.1.40"));
        Assert.True(SubtitleServer.IsFromSavedTv("192.168.1.41", ""));
        Assert.True(SubtitleServer.IsFromSavedTv("192.168.1.41", null));
        Assert.Equal("TV uygulaması kayıtlı TV'den (192.168.1.40) değil, başka bir TV'den (192.168.1.41) bağlandı, sürüm < 0.9.69; "
            + "kayıtlı TV için güncelleme ya da kurulum önerilmiyor.", SubtitleServer.OtherTvReportLine("192.168.1.41", "192.168.1.40", ""));
    }

    /// TV akışı TV ya da ağ tarafından kapanınca nedeni, ne kadar açık kaldığı ve son alındı günlükte (Mac/iPhone ve Android aynı).
    [Fact]
    public void TvClosedLineNamesReasonUptimeAndLastAck()
    {
        Assert.Equal("TV bağlantısı koptu (TV kapattı): 192.168.1.40, 183 sn açıktı, son alındı 14 sn önce; TV yeniden bağlanacak",
            SubtitleServer.TvClosedLine("TV kapattı", "192.168.1.40", 183, 14));
        Assert.Equal("TV bağlantısı koptu (yazma hatası): ?, 0 sn açıktı, son alındı yok; TV yeniden bağlanacak",
            SubtitleServer.TvClosedLine("yazma hatası", "", -1, null));
    }

    /// Konuşan adını renklendir açıkken adlı satır "speakerNames" alanını taşır (eski "speakers" hiç gitmez: 0.9.79'dan eski
    /// TV uygulamaları onunla bütün satırı boyuyordu); kapalıyken ve adsız satırda alan yoktur.
    [Fact]
    public async Task SubtitleCarriesSpeakerColorsOnlyWhenEnabled()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 1);
        server.SendSubtitle("Mattia: Kapat.", 4000);
        server.SpeakerColors = true;
        server.SendSubtitle("Mattia: Gel.\nLucia: Hayır.", 4000);
        server.SendSubtitle("Adsız satır.", 4000);
        server.Clear();

        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var lines = await ReadLines(reader, "event: clear");
        Assert.Contains(lines, l => l.Contains("Kapat.") && !l.Contains("speaker"));
        Assert.Contains(lines, l => l.Contains("Lucia: Hayır.")
            && !l.Contains("\"speakers\"") && l.Contains("\"speakerNames\":[{\"color\":\"#F76AB7\",\"name\":\"Mattia\"},{\"color\":\"#2AD5E5\",\"name\":\"Lucia\"}]"));
        Assert.Contains(lines, l => l.Contains("Adsız satır.") && !l.Contains("speaker"));
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

    /// <summary>
    /// #1198: yeni bağlanan TV önce gösterilen alanların listesini (<c>region-sync</c>; listede olmayanı kaldırır), sonra her
    /// alanın son çevirisini <c>keep</c> bayrağıyla alır. Temizlenmiş ya da boşalmış alan gelmez.
    /// </summary>
    [Fact]
    public async Task NewStreamGetsTheLiveRegionsAfterASync()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        server.SendRegion("q", "Demirciyi bul", new TextBox(0.7, 0.05, 0.95, 0.12), 0.03);
        server.SendRegion("game-phone", "Merhaba", null);
        server.SendRegion("gone", "Geçti", null);
        server.SendRegion("gone", "", null);

        using (var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead))
        {
            using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
            const string quest = "data: {\"box\":{\"bottom\":0.12,\"left\":0.7,\"right\":0.95,\"top\":0.05},\"id\":\"q\",\"keep\":true,\"line\":0.03,\"text\":\"Demirciyi bul\"}";
            var lines = await ReadLines(reader, quest);
            var sync = lines.IndexOf("event: region-sync");
            Assert.True(sync >= 0);
            Assert.Equal("data: {\"ids\":[\"game-phone\",\"q\"]}", lines[sync + 1]);
            var phone = lines.IndexOf("data: {\"id\":\"game-phone\",\"keep\":true,\"text\":\"Merhaba\"}");
            Assert.True(phone > sync);
            Assert.Equal("event: region", lines[phone - 1]);
            Assert.DoesNotContain(lines, line => line.Contains("Geçti"));
        }

        server.ClearRegions();
        using (var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead))
        {
            using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
            var lines = await ReadLines(reader, "event: region-sync");
            Assert.Equal("data: {\"ids\":[]}", await reader.ReadLineAsync());
            Assert.Equal("", await reader.ReadLineAsync());
            server.SendSubtitle("Sonra", 1000);
            Assert.Equal("event: subtitle", await reader.ReadLineAsync());
        }
    }

    /// <summary>#1198: gösterilen alanlar aralıkla <c>keep</c> bayrağıyla yenilenir (TV'deki ömrü dolmasın); telefon kartı hariç.</summary>
    [Fact]
    public async Task LiveRegionsAreRefreshedExceptThePhoneCard()
    {
        using var server = new SubtitleServer(0) { RegionRefreshInterval = TimeSpan.FromMilliseconds(50) };
        var port = await server.StartAsync();
        server.SendRegion("q", "Demirciyi bul", null);
        server.SendRegion("game-phone", "Merhaba", null);
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        const string refresh = "data: {\"id\":\"q\",\"keep\":true,\"text\":\"Demirciyi bul\"}";
        // Bağlanırken gelen yeniden gönderim, sonra iki yenileme.
        var lines = await ReadLines(reader, refresh);
        lines.AddRange(await ReadLines(reader, refresh));
        lines.AddRange(await ReadLines(reader, refresh));
        Assert.Equal(1, lines.Count(line => line.Contains("\"game-phone\",\"keep\"")));
        Assert.Equal(3, lines.Count(line => line == refresh));
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

    [Fact]
    public async Task OnlyPhoneBlocksSendValidColorsAndKeepTheLegacyText()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 1);
        var box = new TextBox(0.4, 0.2, 0.6, 0.25);
        var item = new ScreenTranslation.Item("Reply", "Yanıt", box, 0.025) { Style = new("#2173AD", "#FFFFFF") };
        server.SendRegion("game-phone", "Yanıt", box, 0.025, null, [item]);
        server.SendRegion("area1", "Yanıt", box, 0.025, null, [item]);
        server.SendRegion("game-phone", "Yanıt", box, 0.025, null, [item with { Style = new("transparent", "#FFFFFF") }]);
        server.ClearRegions();

        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var events = (await ReadLines(reader, "event: region-clear")).Where(l => l.StartsWith("data: ") && l.Contains("\"blocks\"")).ToList();
        Assert.Equal(3, events.Count);
        using var phone = JsonDocument.Parse(events[0][6..]);
        Assert.Equal("game-phone", phone.RootElement.GetProperty("id").GetString());
        Assert.Equal("Yanıt", phone.RootElement.GetProperty("text").GetString()); // Older receivers use the joined text.
        var surface = phone.RootElement.GetProperty("blocks")[0].GetProperty("surface");
        Assert.Equal("#2173AD", surface.GetProperty("background").GetString());
        Assert.Equal("#FFFFFF", surface.GetProperty("foreground").GetString());
        Assert.DoesNotContain("surface", events[1]);
        Assert.DoesNotContain("surface", events[2]);
    }

    /// Otomatik ekran yazısı blokları özgün stili taşır: surface (flat ile) ve style.
    [Fact]
    public async Task AutoScreenTextBlocksCarrySurfaceAndStyle()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 1);
        var box = new TextBox(0.02, 0.05, 0.3, 0.1);
        var item = new ScreenTranslation.Item("ROB VICKI'S BOSS", "VİCKİ'NİN PATRONUNU SOY", box, 0.03)
        {
            Style = new("#14161E", "#F0F0F0"),
            Look = new TextLook(Bold: true, Condensed: true, Align: "left", Upper: true, Flat: true),
        };
        server.SendRegion("auto-1", item.Translation, box, 0.03, null, [item]);
        server.ClearRegions();

        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var data = Assert.Single((await ReadLines(reader, "event: region-clear")).Where(l => l.StartsWith("data: ") && l.Contains("\"blocks\"")));
        Assert.Contains("\"surface\":{\"background\":\"#14161E\",\"flat\":true,\"foreground\":\"#F0F0F0\"}", data);
        Assert.Contains("\"style\":{\"align\":\"left\",\"bold\":true,\"condensed\":true,\"upper\":true}", data);
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

    /// İkinci ekran: sayfa ve akışı anahtarsız (eski TV geçişi açıkken de) ya da yanlış anahtarla açılmaz; doğru
    /// anahtarla sayfa gelir, akış TV sayılmaz ve altyazı hedefi TV değilken de altyazıyı alır (Mac ve Android ile aynı).
    [Fact]
    public async Task SecondScreenNeedsTheKeyAndAlwaysGetsSubtitles()
    {
        using var server = new SubtitleServer(0, key: "dogru-anahtar", allowLegacy: true) { SendsToTv = false };
        var port = await server.StartAsync();
        var root = $"http://127.0.0.1:{port}";
        foreach (var target in new[] { "/view", "/view?k=yanlis", "/events?viewer=second", "/events?viewer=second&k=yanlis" })
        {
            using var denied = await Http.GetAsync(root + target, HttpCompletionOption.ResponseHeadersRead);
            Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        }
        using var page = await Http.GetAsync(root + "/view?k=dogru-anahtar");
        Assert.Equal(HttpStatusCode.OK, page.StatusCode);
        Assert.StartsWith("text/html", page.Content.Headers.ContentType?.ToString());
        Assert.Contains("/events?viewer=second&k=", await page.Content.ReadAsStringAsync());

        using var response = await Http.GetAsync(root + "/events?viewer=second&k=dogru-anahtar", HttpCompletionOption.ResponseHeadersRead);
        await Task.Delay(200);
        Assert.Equal(0, server.ConnectedClients);
        Assert.False(server.HasLegacyClient);
        server.SendSubtitle("Merhaba", 4000);
        server.Clear();
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        Assert.Contains(await ReadLines(reader, "event: clear"), line => line.StartsWith("data:") && line.Contains("\"text\":\"Merhaba\""));
    }

    [Fact]
    public void SecondScreenAddressCarriesTheKey()
    {
        Assert.Equal("http://192.168.1.20:8787/view?k=a-b_C9", SecondScreen.Address("192.168.1.20", 8787, "a-b_C9"));
        Assert.Equal("http://[fe80::1]:8787/view?k=k", SecondScreen.Address("fe80::1", 8787, "k"));
        var modules = SecondScreen.QrModules("http://192.168.1.20:8787/view?k=a-b_C9");
        Assert.True(modules.Length >= 21);
        Assert.All(modules, row => Assert.Equal(modules.Length, row.Length));
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

    /// <summary>Altyazının oyundaki yeri bilgisayardaki pencereye de gider: "Yazı kadar" kutu oyunun altyazısını örtecek kadar büyür.</summary>
    [Fact]
    public void LocalListenerGetsTheSubtitleBox()
    {
        using var server = new SubtitleServer(0);
        var received = new List<SubtitleEvent>();
        server.EventSent += received.Add;
        var box = new TextBox(0.25, 0.8, 0.75, 0.9);
        server.SendSubtitle("Merhaba", 4000, box);
        Assert.Equal(box, Assert.Single(received).Box);
    }

    /// <summary>"Ekranı çevir" sonuçları da pencereye gider: altyazı yalnız bilgisayardayken (TV yok) hiçbir yerde görünmüyordu.</summary>
    [Fact]
    public void LocalListenerGetsScreenTranslations()
    {
        using var server = new SubtitleServer(0);
        var received = new List<SubtitleEvent>();
        server.EventSent += received.Add;
        var box = new TextBox(0.1, 0.1, 0.4, 0.2);
        ScreenTranslation.Item[] items =
        [
            new("Map\nInventory", "Harita\nEnvanter", box, 0.03), new("", ScreenPhoneCard.BackdropText, box, 0.03),
            new("Leave", "Ayrıl", box, 0.03),
        ];
        server.SendScreen(items, 12000);
        server.ClearScreen();
        // Telefon kartının zemini düz metne girmez; öğeler yerleriyle pencereye de gider.
        Assert.Equal(2, received.Count);
        Assert.Equal(new SubtitleEvent(SubtitleEventKind.Screen, "Harita\nEnvanter\nAyrıl", 12000, Paragraphs: true), received[0] with { Blocks = null });
        Assert.Equal(items, received[0].Blocks);
        Assert.Equal(new SubtitleEvent(SubtitleEventKind.ScreenClear), received[1]);
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
        var lines = await ReadLines(reader, "event: subtitle");
        lines.Add((await reader.ReadLineAsync())!);
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
        Assert.Equal(TvDisplayMode.Auto, old!.DisplayMode);
        var saved = System.Text.Json.JsonSerializer.Serialize(old with { DisplayMode = TvDisplayMode.Overlay });
        Assert.Contains("\"Overlay\"", saved);
        Assert.Equal(TvDisplayMode.Overlay, System.Text.Json.JsonSerializer.Deserialize<SubtitleStyle>(saved)!.DisplayMode);
    }

    /// Eski kayıttaki "InApp" (eski varsayılan) Otomatik'tir; bilerek seçilen uygulama içi ayrı kaydedilir ve TV'ye
    /// "inAppOnly" gider (Mac/iPhone ve Android ile aynı).
    [Fact]
    public void OldInAppIsAutomaticAndChosenInAppIsSavedApart()
    {
        var old = System.Text.Json.JsonSerializer.Deserialize<SubtitleStyle>("{\"DisplayMode\":\"InApp\"}");
        Assert.Equal(TvDisplayMode.Auto, old!.DisplayMode);
        Assert.Contains("\"InApp\"", System.Text.Json.JsonSerializer.Serialize(old));
        var chosen = System.Text.Json.JsonSerializer.Serialize(old with { DisplayMode = TvDisplayMode.InAppOnly });
        Assert.Equal(TvDisplayMode.InAppOnly, System.Text.Json.JsonSerializer.Deserialize<SubtitleStyle>(chosen)!.DisplayMode);
    }

    [Fact]
    public void OldSavedStyleGetsNewDefaults()
    {
        var style = System.Text.Json.JsonSerializer.Deserialize<SubtitleStyle>("{\"FontSize\":58,\"BottomPercent\":12}");
        Assert.Equal(new SubtitleStyle(58, 12, SubtitlePlacement.Cover, 90, false), style);
        var again = System.Text.Json.JsonSerializer.Deserialize<SubtitleStyle>(System.Text.Json.JsonSerializer.Serialize(style! with { Placement = SubtitlePlacement.Below }));
        Assert.Equal(SubtitlePlacement.Below, again!.Placement);
    }

    /// <summary>TV akışı <c>link</c> olayıyla kimliğini alır; alındı yalnız bağlı bağlantının kimliğine kabul edilir.</summary>
    [Fact]
    public async Task TvStreamGetsALinkIdThatAcksAccept()
    {
        using var server = new SubtitleServer(0);
        var port = await server.StartAsync();
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var lines = await ReadLines(reader, "event: link");
        Assert.Equal("event: link", lines[^1]);
        var data = await reader.ReadLineAsync();
        var id = JsonDocument.Parse(data!["data: ".Length..]).RootElement.GetProperty("id").GetString()!;
        Assert.Matches("^[A-Za-z0-9]{16}$", id);

        using var known = await Http.GetAsync($"http://127.0.0.1:{port}/ack?c={id}");
        Assert.Equal(HttpStatusCode.NoContent, known.StatusCode);
        using var unknown = await Http.GetAsync($"http://127.0.0.1:{port}/ack?c=bilinmeyen0000000");
        Assert.Equal(HttpStatusCode.NotFound, unknown.StatusCode);
        // OBS izleyicisi TV değildir: kimlik almaz.
        using var obs = await Http.GetAsync($"http://127.0.0.1:{port}/events?viewer=obs", HttpCompletionOption.ResponseHeadersRead);
        using var obsReader = new StreamReader(await obs.Content.ReadAsStreamAsync());
        var obsLines = await ReadLines(obsReader, "event: ping");
        Assert.DoesNotContain("event: link", obsLines);
    }

    /// <summary><c>link</c> olayı bu bilgisayardaki TV paketinin sürümünü (<c>latest</c>) taşır; TV daha eskiyse paneli
    /// "TV uygulaması eski" der (GitHub #1199).</summary>
    [Fact]
    public async Task LinkCarriesBundledTvAppVersion()
    {
        using var server = new SubtitleServer(0) { LatestTvAppVersion = "0.9.95" };
        var port = await server.StartAsync();
        using var response = await Http.GetAsync($"http://127.0.0.1:{port}/events?v=0.9.71", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        await ReadLines(reader, "event: link");
        var data = await reader.ReadLineAsync();
        Assert.Equal("0.9.95", JsonDocument.Parse(data!["data: ".Length..]).RootElement.GetProperty("latest").GetString());
    }

    /// <summary>Alındı gönderip susan TV (LG'de uygulama arka planda askıya alındı) kopmuş sayılır ve kapatılır; hiç alındı
    /// göndermeyen eski TV uygulamasına dokunulmaz.</summary>
    [Fact]
    public async Task TvThatStopsAckingIsDroppedButOldTvStays()
    {
        using var server = new SubtitleServer(0, TimeSpan.FromMilliseconds(100));
        var stale = 0;
        server.TvStale += () => Interlocked.Increment(ref stale);
        var port = await server.StartAsync();
        using var acking = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await acking.Content.ReadAsStreamAsync());
        await ReadLines(reader, "event: link");
        var id = JsonDocument.Parse((await reader.ReadLineAsync())!["data: ".Length..]).RootElement.GetProperty("id").GetString()!;
        using var old = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => server.ConnectedClients == 2);

        using var ack = await Http.GetAsync($"http://127.0.0.1:{port}/ack?c={id}");
        Assert.Equal(HttpStatusCode.NoContent, ack.StatusCode);
        // Alındı kesildi: 3 ping turu sonra bağlantı düşer.
        await WaitUntil(() => server.ConnectedClients == 1);
        using var again = await Http.GetAsync($"http://127.0.0.1:{port}/ack?c={id}");
        Assert.Equal(HttpStatusCode.NotFound, again.StatusCode);
        await Task.Delay(500);
        Assert.Equal(1, server.ConnectedClients);
        // #1055: TV'nin başka bağlantısı açıkken bekçi yenilenmez (yenilenen bekçi LG'de uygulamayı yeniden başlatıyordu).
        Assert.Equal(0, Volatile.Read(ref stale));
    }

    /// <summary>#1055: alındı gönderen TV ping turları boyunca düşmez; TV'nin tek bağlantısı susunca <see cref="SubtitleServer.TvStale"/>
    /// bir kez tetiklenir.</summary>
    [Fact]
    public async Task OnlyTheLastSilentTvConnectionRenewsTheKeeper()
    {
        using var server = new SubtitleServer(0, TimeSpan.FromMilliseconds(100));
        var stale = 0;
        server.TvStale += () => Interlocked.Increment(ref stale);
        var port = await server.StartAsync();
        using var acking = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await acking.Content.ReadAsStreamAsync());
        await ReadLines(reader, "event: link");
        var id = JsonDocument.Parse((await reader.ReadLineAsync())!["data: ".Length..]).RootElement.GetProperty("id").GetString()!;
        await WaitUntil(() => server.ConnectedClients == 1);
        for (var i = 0; i < 10; i++)
        {
            using var ack = await Http.GetAsync($"http://127.0.0.1:{port}/ack?c={id}");
            Assert.Equal(HttpStatusCode.NoContent, ack.StatusCode);
            await Task.Delay(80);
        }
        Assert.Equal(1, server.ConnectedClients);
        Assert.Equal(0, Volatile.Read(ref stale));
        await WaitUntil(() => server.ConnectedClients == 0);
        await WaitUntil(() => Volatile.Read(ref stale) == 1);
        await Task.Delay(400);
        Assert.Equal(1, Volatile.Read(ref stale));
    }

    /// <summary>#1055: ping turu gitmediyse (zamanlayıcı gecikti) TV'den alındı beklenmez: alındısız sayılan yalnız ping
    /// turlarıdır, geçen saat değil.</summary>
    [Fact]
    public async Task TvIsNotDroppedWhilePingsAreNotSent()
    {
        using var server = new SubtitleServer(0, TimeSpan.FromHours(1));
        var port = await server.StartAsync();
        using var acking = await Http.GetAsync($"http://127.0.0.1:{port}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await acking.Content.ReadAsStreamAsync());
        await ReadLines(reader, "event: link");
        var id = JsonDocument.Parse((await reader.ReadLineAsync())!["data: ".Length..]).RootElement.GetProperty("id").GetString()!;
        using var ack = await Http.GetAsync($"http://127.0.0.1:{port}/ack?c={id}");
        await WaitUntil(() => server.ConnectedClients == 1);
        for (var turn = 0; turn < SubtitleServer.AckMissLimit; turn++) Assert.False(server.DropSilentTvs());
        Assert.Equal(1, server.ConnectedClients);
        Assert.True(server.DropSilentTvs());
        Assert.Equal(0, server.ConnectedClients);
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
        Assert.Equal("{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"3f2a-b9\",\"tvs\":0,\"live\":0}", body);
        Assert.DoesNotContain(server.AccessKey, body);
        // Çeviri sürüyor ve altyazı TV'ye gidiyor: live 1; altyazı yalnız bilgisayar ekranındaysa 0.
        server.Pairing.SetSession(true);
        Assert.EndsWith(",\"live\":1}", await http.GetStringAsync($"http://127.0.0.1:{port}/hello"));
        server.SendsToTv = false;
        Assert.EndsWith(",\"live\":0}", await http.GetStringAsync($"http://127.0.0.1:{port}/hello"));
    }

    /// <summary>Kurulum kimliği kalıcıdır: aynı ağdaki iki CouchSubs'ı TV bununla ayırır (GitHub #425).</summary>
    [Fact]
    public void InstallationIdIsStable()
    {
        using var first = new SubtitleServer(0);
        using var second = new SubtitleServer(0);
        Assert.False(string.IsNullOrEmpty(first.InstanceId));
        Assert.Equal(first.InstanceId, second.InstanceId);
        Assert.Equal("{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"ab\",\"tvs\":2,\"live\":0}", SubtitleServer.HelloBody("a\"b", 2));
        Assert.Equal("{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"x\",\"tvs\":0,\"live\":1}", SubtitleServer.HelloBody("x", 0, true));
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
