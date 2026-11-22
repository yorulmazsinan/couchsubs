// SPDX-License-Identifier: AGPL-3.0-only

using System.IO.Compression;
using System.Text.Json;

namespace CouchSubs.Core.Tests;

/// <summary>Günlük maskeleme ve "Günlüğü Kopyala" zip'i (Mac LogShareTests / LogArchiveTests ile aynı ortak deneme dosyası).</summary>
public class LogShareTests
{
    public static IEnumerable<object[]> Cases()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("log-redaction.json")));
        foreach (var item in fixture.RootElement.EnumerateArray())
            yield return [item.GetProperty("input").GetString()!, item.GetProperty("expected").GetString()!];
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void RedactsLikeMacAndAndroid(string input, string expected) => Assert.Equal(expected, LogShare.Redact(input));

    [Fact]
    public void ZipHoldsMaskedRecentLogs()
    {
        var source = PackFixtures.TemporaryDirectory();
        var target = PackFixtures.TemporaryDirectory();
        File.WriteAllText(Path.Combine(source, "remoteplay.log"), "RP-RegistKey: 0a1b2c3d4e5f6a7b\n192.168.1.20 bağlandı\n");
        File.WriteAllText(Path.Combine(source, "altyazi.log.1"), "satır\n");
        File.WriteAllText(Path.Combine(source, "settings.json"), "{}");
        var old = Path.Combine(source, "eski.log");
        File.WriteAllText(old, "eski");
        File.SetLastWriteTime(old, DateTime.Now.AddDays(-30));

        var now = new DateTime(2026, 11, 22, 18, 30, 0);
        var zip = LogShare.MakeZip(source, target, "CouchSubs 1.0, Windows", now);

        Assert.Equal("CouchSubs-gunluk-20261122-1830.zip", Path.GetFileName(zip));
        using var archive = ZipFile.OpenRead(zip);
        var names = archive.Entries.Select(e => e.FullName).OrderBy(n => n).ToList();
        Assert.Equal(["CouchSubs-gunluk/altyazi.log.1", "CouchSubs-gunluk/bilgi.txt", "CouchSubs-gunluk/remoteplay.log"], names);
        using var reader = new StreamReader(archive.GetEntry("CouchSubs-gunluk/remoteplay.log")!.Open());
        var text = reader.ReadToEnd();
        Assert.Contains("RP-RegistKey: ***", text);
        Assert.Contains("192.168.1.20", text);
    }
}
