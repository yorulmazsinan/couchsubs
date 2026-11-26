// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;

namespace CouchSubs.RemotePlay.Tests;

/// <summary>PS5'i kimliğiyle (keşifteki host-id) tanıma: ad değişse de, aynı adlı iki PS5 olsa da doğru PS5 bulunur; eski
/// kayıt kimliği ilk bulunuşta öğrenir (Mac/iPhone ConsoleIdentityTests, Android ConsoleIdentityTest ile aynı durumlar).</summary>
public class ConsoleIdentityTests
{
    private static RegisteredConsole Saved(string host = "192.168.1.20", string name = "PS5-A", string? hostId = "1C98C1AABBCC") =>
        new(host, name, "0123abcd"u8.ToArray(), new byte[16], hostId);

    [Fact]
    public void HostIdIsNormalized()
    {
        Assert.Equal("1C98C1AABBCC", ConsoleIdentity.Normalized("1c:98:c1:aa:bb:cc"));
        Assert.Equal("1C98C1AABBCC", ConsoleIdentity.Normalized(" 1c98c1aabbcc\r"));
        Assert.Null(ConsoleIdentity.Normalized(""));
        Assert.Null(ConsoleIdentity.Normalized("000000000000"));
        Assert.Null(ConsoleIdentity.Normalized(null));
        Assert.Equal("1C98C1AABBCC", ConsoleIdentity.FromMac([0x1C, 0x98, 0xC1, 0xAA, 0xBB, 0xCC]));
        Assert.Null(ConsoleIdentity.FromMac(new byte[6]));
        Assert.Equal("1C98C1AABBCC", new ConsoleInfo("h", "n", true, HostId: "1c98c1aabbcc").HostId);
    }

    /// <summary>PS5'in adı değişti: kimlik tuttuğu için yeni adreste yine bulunur ve kayıttaki ad güncellenir.</summary>
    [Fact]
    public void RenamedConsoleIsFoundByHostId()
    {
        var console = Saved();
        var renamed = new ConsoleInfo("192.168.1.44", "Salon PS5", true, HostId: "1C98C1AABBCC");
        Assert.True(ConsoleIdentity.IsRegistered(renamed, console));
        Assert.Equal(renamed, ConsoleIdentity.PickMoved([renamed], console));
        var updated = ConsoleIdentity.Updated(console, renamed);
        Assert.Equal("192.168.1.44", updated?.Host);
        Assert.Equal("Salon PS5", updated?.Name);
        Assert.Equal("1C98C1AABBCC", updated?.HostId);
        Assert.Same(console.RegistKey, updated?.RegistKey);
    }

    /// <summary>Aynı adlı iki PS5: kimlikli kayıt doğru olanı seçer; kayıtlı adreste yanıt veren öteki PS5 kayıtlı sayılmaz.</summary>
    [Fact]
    public void TwoConsolesWithTheSameNameAreToldApart()
    {
        var console = Saved();
        var mine = new ConsoleInfo("192.168.1.31", "PS5-A", false, HostId: "1C98C1AABBCC");
        var other = new ConsoleInfo("192.168.1.20", "PS5-A", true, HostId: "F8461C000001");
        Assert.False(ConsoleIdentity.IsRegistered(other, console));
        Assert.Equal(mine, ConsoleIdentity.PickMoved([other, mine], console));
        // Kimliksiz (eski) kayıtta iki aynı ad emin olunamaz: hiçbirine geçilmez.
        Assert.Null(ConsoleIdentity.PickMoved([other, mine], Saved(hostId: null)));
    }

    /// <summary>Eski kayıt (kimlik yok): adıyla bulunur, kimliği kayda yazılır; ad değişmez. Sonraki aramalar kimlikle olur.</summary>
    [Fact]
    public void LegacyRecordLearnsHostIdOnFirstMatch()
    {
        var legacy = Saved(hostId: null);
        var found = new ConsoleInfo("192.168.1.20", "ps5-a", true, HostId: "1C98C1AABBCC");
        Assert.True(ConsoleIdentity.IsRegistered(found, legacy));
        var learned = ConsoleIdentity.Updated(legacy, found)!;
        Assert.Equal("1C98C1AABBCC", learned.HostId);
        Assert.Equal("192.168.1.20", learned.Host);
        Assert.Equal("PS5-A", learned.Name);
        Assert.Equal("PS5 kimliği kayda yazıldı: 1C98C1AABBCC", ConsoleIdentity.ChangeLine(legacy, learned));
        Assert.Null(ConsoleIdentity.Updated(learned, found));
    }

    /// <summary>Eski biçimde saklanmış kayıt (HostId alanı yok) okunur; yeni alan kaydedilip geri okunur.</summary>
    [Fact]
    public void StoredRecordWithoutHostIdStillDecodes()
    {
        const string old = """{"Host":"192.168.1.20","Name":"PS5-A","RegistKey":"MDEyM2FiY2Q=","Morning":"BwcHBwcHBwcHBwcHBwcHBw=="}""";
        var console = JsonSerializer.Deserialize<RegisteredConsole>(old)!;
        Assert.Null(console.HostId);
        Assert.Equal(0x0123abcdUL, console.WakeCredential);
        var roundTrip = JsonSerializer.Deserialize<RegisteredConsole>(JsonSerializer.Serialize(Saved()))!;
        Assert.Equal("1C98C1AABBCC", roundTrip.HostId);
        Assert.Equal("1C98C1AABBCC", Saved().WithHost("10.0.0.5").HostId);
    }

    [Fact]
    public void MoveIsLoggedWithHowItWasFound()
    {
        Assert.Equal("PS5 yeni adreste bulundu: 192.168.1.20 → 192.168.1.44 (host-id ile)",
                     ConsoleIdentity.ChangeLine(Saved(), Saved().WithHost("192.168.1.44")));
        Assert.Equal("PS5 yeni adreste bulundu: 192.168.1.20 → 192.168.1.44 (adıyla)",
                     ConsoleIdentity.ChangeLine(Saved(hostId: null), Saved(host: "192.168.1.44", hostId: null)));
    }

    /// <summary>İlk tarama hemen; bulunamazsa 10 sn, 30 sn, 1 dk, 2 dk, sonra hep 5 dk beklenir (#1366). Bağlantı kopunca yine hemen.</summary>
    [Fact]
    public void RelocateScheduleShortensAfterAFailure()
    {
        var schedule = new RelocateSchedule();
        var now = DateTime.UtcNow;
        Assert.True(schedule.IsDue(now));
        foreach (var wait in new[] { 10, 30, 60, 120, 300, 300 })
        {
            schedule.Searched(false, now);
            Assert.False(schedule.IsDue(now.AddSeconds(wait - 1)));
            Assert.True(schedule.IsDue(now.AddSeconds(wait)));
        }
        schedule.ConnectionFailed();
        Assert.True(schedule.IsDue(now));
        schedule.Searched(true, now);
        Assert.True(schedule.IsDue(now));
    }

    /// <summary>Kayıtlı adreste başka PS5 var: ağ taranır, PS5 kimliğiyle yeni adreste bulunur, kayıt güncellenip bildirilir.</summary>
    [Fact]
    public void FinderRelocatesAndReportsTheNewAddress()
    {
        var mine = new ConsoleInfo("192.168.1.44", "PS5-A", true, HostId: "1C98C1AABBCC");
        var other = new ConsoleInfo("192.168.1.20", "PS5-A", true, HostId: "F8461C000001");
        var asked = new List<string?>();
        var finder = new ConsoleFinder(Saved(), host =>
        {
            asked.Add(host);
            return host is null ? [other, mine] : host == "192.168.1.20" ? [other] : [];
        });
        RegisteredConsole? reported = null;
        finder.Changed += moved => reported = moved;
        var (info, atHost) = finder.Locate();
        Assert.Equal(mine, info);
        Assert.Equal(other, atHost);
        Assert.Equal(["192.168.1.20", null], asked);
        Assert.Equal("192.168.1.44", reported?.Host);
        Assert.Equal("192.168.1.44", finder.Console.Host);
    }

    /// <summary>PS5 bulunamadı: sonraki tarama 10 sn bekler (her denemede ağ taranmaz); bağlantı kopunca hemen taranır.</summary>
    [Fact]
    public void FinderDoesNotRescanImmediatelyAfterAMiss()
    {
        var scans = 0;
        var finder = new ConsoleFinder(Saved(), host =>
        {
            if (host is null) scans++;
            return [];
        });
        Assert.Null(finder.Locate().Info);
        Assert.Null(finder.Locate().Info);
        Assert.Equal(1, scans);
        finder.ConnectionFailed();
        Assert.Null(finder.Locate().Info);
        Assert.Equal(2, scans);
    }

    /// <summary>Bağlıyken çalışan oyun yoklaması (<c>sweep: false</c>) kayıtlı adres sessiz de olsa ağı hiç taramaz (#1366).</summary>
    [Fact]
    public void LocateWithoutSweepNeverScansTheNetwork()
    {
        var asked = new List<string?>();
        var finder = new ConsoleFinder(Saved(), host => { asked.Add(host); return []; });
        Assert.Null(finder.Locate(sweep: false).Info);
        Assert.Null(finder.Locate(sweep: false).Info);
        Assert.Equal(["192.168.1.20", "192.168.1.20"], asked);
    }

    /// <summary>Tarama yalnız iki tur gönderir, paketler 4 ms arayla; birkaç adrese soru her turda gider (#1366).</summary>
    [Fact]
    public void SweepSendsOnlyTwoPacedRounds()
    {
        Assert.True(SweepPacing.IsSweep(254));
        Assert.False(SweepPacing.IsSweep(1));
        Assert.Equal([0, 1], Enumerable.Range(0, 6).Where(r => SweepPacing.SendsInRound(r, 254)));
        Assert.Equal(Enumerable.Range(0, 6), Enumerable.Range(0, 6).Where(r => SweepPacing.SendsInRound(r, 1)));
        Assert.Equal(508, SweepPacing.PlannedPackets(254, 3000));
        Assert.Equal(4, SweepPacing.PlannedPackets(1, 2000));
        Assert.True(1000 / SweepPacing.PaceMs <= 250);
    }

    /// <summary>Ağ yükü satırı: ilk olay hemen, sonrakiler dakikada bir tek satırda.</summary>
    [Fact]
    public void NetworkLoadWritesAtMostOneLinePerMinute()
    {
        var lines = new List<string>();
        var load = new NetworkLoad(lines.Add);
        var start = new DateTime(2026, 11, 27, 0, 0, 0, DateTimeKind.Utc);
        load.Discovery(true, 508, start);
        Assert.Equal(["Ağ yükü (son 0 sn): PS5 ağ taraması 1 kez, 508 paket; tek adres sorgusu 0 kez, 0 paket; PS5'e yeniden bağlanma 0"], lines);
        for (var second = 1; second <= 59; second++) load.Discovery(false, 4, start.AddSeconds(second));
        load.Retry(start.AddSeconds(59));
        Assert.Single(lines);
        load.Discovery(true, 500, start.AddSeconds(60));
        Assert.Equal("Ağ yükü (son 59 sn): PS5 ağ taraması 1 kez, 500 paket; tek adres sorgusu 59 kez, 236 paket; PS5'e yeniden bağlanma 1",
                     lines[^1]);
    }
}
