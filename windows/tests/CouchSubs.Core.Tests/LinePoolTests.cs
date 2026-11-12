// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace CouchSubs.Core.Tests;

/// <summary>Sunucunun yerine geçen sahte HTTP: gelen istekleri saklar, sıradaki yanıtı döner (null: ulaşılamadı).</summary>
internal sealed class FakePoolServer : HttpMessageHandler
{
    private readonly object gate = new();
    public List<(HttpMethod Method, Uri Url, string Body)> Received { get; } = [];
    public Queue<Func<HttpResponseMessage>?> Replies { get; } = new();
    public Func<HttpResponseMessage>? Fallback { get; set; } = () => new HttpResponseMessage(HttpStatusCode.OK);

    public List<List<JsonElement>> Batches
    {
        get
        {
            lock (gate)
                return [.. Received.Select(r => JsonDocument.Parse(r.Body).RootElement.GetProperty("lines").EnumerateArray().ToList())];
        }
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
        Func<HttpResponseMessage>? reply;
        lock (gate)
        {
            Received.Add((request.Method, request.RequestUri!, body));
            reply = Replies.Count > 0 ? Replies.Dequeue() : Fallback;
        }
        return reply is null ? throw new HttpRequestException("ulaşılamadı") : reply();
    }
}

internal sealed class PoolClock
{
    public DateTimeOffset Now { get; set; } = DateTimeOffset.FromUnixTimeSeconds(1_793_000_000);
}

public class LinePoolTests
{
    private readonly string file = Path.Combine(Path.GetTempPath(), "pool-" + Guid.NewGuid(), "pool.json");
    private readonly FakePoolServer server = new();
    private readonly PoolClock clock = new();

    private LinePool MakePool(bool enabled = true) =>
        new(file, "1.2.3", new Uri("https://example.test/v1/lines"), "windows", enabled, server, () => clock.Now);

    [Fact]
    public async Task DisabledPoolSendsNothing()
    {
        Assert.True(LinePool.EnabledByDefault);
        var pool = MakePool(enabled: false);
        pool.Offer("Don Torrisi wants you.");
        await pool.FlushAsync();
        Assert.Empty(pool.Queued);
        Assert.Empty(server.Received);
    }

    [Fact]
    public void LinesAreDeduplicatedByKey()
    {
        var pool = MakePool();
        pool.Offer("  Don Torrisi wants you.  ");
        pool.Offer("DON TORRISI WANTS YOU!");
        pool.Offer("Who is that over there?");
        Assert.Equal(["Don Torrisi wants you.", "Who is that over there?"], pool.Queued.Select(l => l.Text));
        Assert.Equal(PackKey.Key("Don Torrisi wants you."), pool.Queued[0].Key);
        Assert.Equal("2026-10-26T07:33:20Z", pool.Queued[0].FirstSeen);
    }

    [Fact]
    public void FiltersSkipShortLongAndNoisyLines()
    {
        Assert.True(LinePool.Accepts("Get down!"));
        Assert.False(LinePool.Accepts("Okay."));
        Assert.False(LinePool.Accepts("..."));
        Assert.False(LinePool.Accepts(string.Concat(Enumerable.Repeat("word ", 61))));
        Assert.False(LinePool.Accepts("We need ou$3e now"));
        Assert.False(LinePool.Accepts("HP 100/100 MP 25/50"));
        Assert.True(LinePool.Accepts("Give me 50 dollars, Enzo."));
    }

    /// <summary>Havuzda en çok görülen "satırlar" PS5'in Türkçe arayüzü ve onun yazı tanıma bozmalarıydı; İngilizce oyun satırı değiller.</summary>
    [Theory]
    [InlineData("Oturum Açtı")]
    [InlineData("Oturum Aqtl")]
    [InlineData("Oturum Aqtl.")]
    [InlineData("Sifirlama Seqenekleri")]
    [InlineData("Sifirlama Seqenekleri.")]
    [InlineData("PS5 Sistemini Yeniden Baslat")]
    [InlineData("PS5 Sistemini Yeniden Baslat.")]
    [InlineData("Oyunu Kapat")]
    [InlineData("Ana Ekranda Tut")]
    [InlineData("Lütfen bekleyin..")]
    [InlineData("Ekran ve Video")]
    [InlineData("ilerlemenizi takip edin Kupalar")]
    [InlineData("Keşfet PS5 ile ilgili Öne Çıkanlar")]
    [InlineData("Ekran görüntüsü kaydedildi.")]
    [InlineData("Kupa kazandınız!")]
    [InlineData("John signed in.")]
    [InlineData("You've earned a trophy!")]
    [InlineData("Please do not quit or turn off your console while the Rockstar cloud save icon is showing.")]
    [InlineData("GO to the")]
    [InlineData("Take out the trash and the")]
    [InlineData("it Auto V's Story Mode.")]
    [InlineData("FREE MONTH OF GTA+")]
    [InlineData("PHOTO MODE SELECT")]
    [InlineData("Main menu")]
    [InlineData("Hold on")]
    public void RejectsTurkishSystemTextAndFragments(string line) => Assert.False(LinePool.Accepts(line), line);

    /// <summary>Yabancı addaki tek ü/ö/ç, sözcük içi eşleşmeler ve noktalamayla biten kısa satırlar İngilizce satırı düşürmez.</summary>
    [Theory]
    [InlineData("Herr Müller will see you now.")]
    [InlineData("This place was designed in a hurry.")]
    [InlineData("Tell Sam I signed the deal.")]
    [InlineData("I lie to you, you lie to me.")]
    [InlineData("DON TORRISI WANTS YOU!")]
    [InlineData("Get down!")]
    [InlineData("Who's there?")]
    [InlineData("Line number 7 here")]
    [InlineData("We need to move before the cops show up")]
    public void KeepsEnglishGameLines(string line) => Assert.True(LinePool.Accepts(line), line);

    [Fact]
    public async Task BatchesAreAtMostTwoHundredLines()
    {
        var pool = MakePool();
        for (var i = 0; i < 450; i++) pool.Offer($"This is line number {i} of the test");
        await pool.FlushAsync();
        Assert.Equal([200, 200, 50], server.Batches.Select(b => b.Count));
        Assert.Empty(pool.Queued);
        var body = JsonDocument.Parse(server.Received[0].Body).RootElement;
        Assert.Equal(["app", "install", "lines", "platform"], body.EnumerateObject().Select(p => p.Name).Order());
        Assert.Equal("1.2.3", body.GetProperty("app").GetString());
        Assert.Equal("windows", body.GetProperty("platform").GetString());
        Assert.True(Guid.TryParse(body.GetProperty("install").GetString(), out _));
        Assert.Equal(["firstSeen", "key", "text"], server.Batches[0][0].EnumerateObject().Select(p => p.Name).Order());
        Assert.Equal(HttpMethod.Post, server.Received[0].Method);
        // Gönderilen satır yeniden kuyruğa girmez.
        pool.Offer("This is line number 3 of the test");
        Assert.Empty(pool.Queued);
    }

    [Fact]
    public async Task QueueSurvivesRestartAndUnreachableServer()
    {
        server.Fallback = null;
        var pool = MakePool();
        pool.Offer("Don Torrisi wants you.");
        await pool.FlushAsync();
        Assert.Single(server.Received);

        var reopened = MakePool();
        Assert.Equal(["Don Torrisi wants you."], reopened.Queued.Select(l => l.Text));
        Assert.Equal(pool.InstallId, reopened.InstallId);
        server.Fallback = () => new HttpResponseMessage(HttpStatusCode.OK);
        await reopened.FlushAsync();
        Assert.Empty(reopened.Queued);
    }

    [Fact]
    public async Task TooManyRequestsWaitsForRetryAfter()
    {
        server.Replies.Enqueue(() =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.TooManyRequests);
            response.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromSeconds(120));
            return response;
        });
        var pool = MakePool();
        pool.Offer("Don Torrisi wants you.");
        await pool.FlushAsync();
        await pool.FlushAsync();
        Assert.Single(server.Received);
        clock.Now += TimeSpan.FromSeconds(121);
        await pool.FlushAsync();
        Assert.Equal(2, server.Received.Count);
        Assert.Empty(pool.Queued);
    }

    [Fact]
    public void QueueKeepsTheNewestFiveThousand()
    {
        var pool = MakePool();
        for (var i = 0; i < LinePool.MaxQueue + 10; i++) pool.Offer($"Line number {i} here");
        Assert.Equal(LinePool.MaxQueue, pool.Queued.Count);
        Assert.Equal("Line number 10 here", pool.Queued[0].Text);
    }

    [Fact]
    public async Task TurningOffDropsTheQueue()
    {
        var pool = MakePool();
        pool.Offer("Don Torrisi wants you.");
        pool.SetEnabled(false);
        await pool.FlushAsync();
        Assert.Empty(pool.Queued);
        Assert.Empty(server.Received);
    }

    [Fact]
    public void RetryAfterAcceptsSecondsAndDates()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_793_000_000);
        Assert.Equal(TimeSpan.FromSeconds(30), LinePool.RetryDelay(new RetryConditionHeaderValue(TimeSpan.FromSeconds(30)), now));
        Assert.Equal(TimeSpan.FromSeconds(60), LinePool.RetryDelay(null, now));
        Assert.Equal(TimeSpan.FromSeconds(120), LinePool.RetryDelay(RetryConditionHeaderValue.Parse("Mon, 26 Oct 2026 07:35:20 GMT"), now));
    }
}
