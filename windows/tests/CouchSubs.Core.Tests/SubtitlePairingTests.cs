// SPDX-License-Identifier: AGPL-3.0-only
using System.Text.Json;
using CouchSubs.Core;
namespace CouchSubs.Core.Tests;
public class SubtitlePairingTests
{
    [Fact] public void SharedLifecycleVectors()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("subtitle-pairing.json")));
        foreach (var scenario in fixture.RootElement.EnumerateArray())
        {
            long time = 1000;
            var pairing = new SubtitlePairing(() => time);
            var id = "";
            foreach (var step in scenario.GetProperty("steps").EnumerateArray())
            {
                var who = step.TryGetProperty("wrong", out var wrong) && wrong.GetBoolean() ? "not-the-request-secret" : id;
                switch (step.GetProperty("op").GetString())
                {
                    case "session": pairing.SetSession(step.GetProperty("value").GetBoolean()); break;
                    case "open": pairing.Open(); break;
                    case "reset": pairing.Reset(); break;
                    case "advance": time += step.GetProperty("ms").GetInt64(); break;
                    case "begin":
                        var ticket = pairing.Begin();
                        Assert.Equal(step.GetProperty("ok").GetBoolean(), ticket is not null);
                        if (ticket is not null) { Assert.Matches("^[A-Za-z0-9_-]{22}$", ticket.Id); Assert.Matches("^[0-9]{6}$", ticket.Code); id = ticket.Id; }
                        break;
                    case "resolve": Assert.Equal(step.GetProperty("ok").GetBoolean(), pairing.Resolve(who, step.GetProperty("accept").GetBoolean())); break;
                    case "poll": Assert.Equal(step.GetProperty("state").GetString(), pairing.Poll(who)); break;
                }
            }
        }
    }
    [Fact] public async Task WireRequiresLocalApprovalAndInvalidatesOnRotation()
    {
        using var server = new SubtitleServer(0, allowLegacy: false);
        var port = await server.StartAsync();
        using var http = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}") };
        using var closed = await http.PostAsync("/pair", null);
        Assert.Equal(409, (int)closed.StatusCode);
        server.Pairing.Open();
        using var foreign = new HttpRequestMessage(HttpMethod.Post, "/pair");
        foreign.Headers.Add("Origin", "https://foreign.example");
        using var rejected = await http.SendAsync(foreign);
        Assert.Equal(403, (int)rejected.StatusCode);
        using var created = await http.PostAsync("/pair", null);
        using var ticket = JsonDocument.Parse(await created.Content.ReadAsStringAsync());
        var id = ticket.RootElement.GetProperty("id").GetString()!;
        var pending = await http.GetStringAsync("/pair?id=" + id);
        Assert.DoesNotContain(server.AccessKey, pending);
        Assert.DoesNotContain(server.AccessKey, await http.GetStringAsync("/hello"));
        Assert.True(server.Pairing.Resolve(id, true));
        Assert.Contains(server.AccessKey, await http.GetStringAsync("/pair?id=" + id));
        Assert.DoesNotContain(server.AccessKey, await http.GetStringAsync("/pair?id=wrong"));
        server.RotateKey(SubtitleAccess.CreateKey());
        Assert.DoesNotContain(server.AccessKey, await http.GetStringAsync("/pair?id=" + id));
        Assert.Contains("expired", await http.GetStringAsync("/pair?id=" + id));
    }
}
