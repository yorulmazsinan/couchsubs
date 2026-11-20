// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.TvInstall.Tests;

/// <summary>"Günlüğü kopyala": kurulum günlüğünün sonu panoya gider (telefonlardaki "Kurulum günlüğünü paylaş" gibi).</summary>
public class InstallLogTests
{
    private static string TempLog() => Path.Combine(Directory.CreateTempSubdirectory().FullName, "tvinstall.log");

    [Fact]
    public void TailIsTheWholeLogWhenItIsShort()
    {
        var path = TempLog();
        var log = new InstallLog(path);
        log.Write("--- LG kurulumu başlıyor: TV 192.168.1.20, paket 0.9.43");
        log.Write("HATA InstallFailed: FAILED_IPKG_INSTALL");
        var tail = InstallLog.ReadTail(path);
        Assert.Contains("] --- LG kurulumu başlıyor: TV 192.168.1.20, paket 0.9.43\n", tail);
        Assert.EndsWith("] HATA InstallFailed: FAILED_IPKG_INSTALL\n", tail);
    }

    [Fact]
    public void TailKeepsOnlyTheEndOfALongLog()
    {
        var path = TempLog();
        File.WriteAllText(path, new string('a', 100) + "son satır");
        Assert.Equal("aason satır", InstallLog.ReadTail(path, 11));
        Assert.Equal(100 + 9, InstallLog.ReadTail(path).Length);
    }

    [Fact]
    public void MissingLogGivesAnEmptyTail()
    {
        Assert.Equal("", InstallLog.ReadTail(TempLog()));
        Assert.Equal("", InstallLog.ReadTail(null));
    }
}
