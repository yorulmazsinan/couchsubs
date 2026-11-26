// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell.Tests;

/// <summary>Xbox oturumlarının kapanış sırası satırları (Android XboxCloseGateTest, iPhone/Mac XboxCloseGateTests ile aynı).</summary>
public class XboxCloseWaitTests
{
    [Fact]
    public void WaitLineMatchesThePhones()
    {
        Assert.Equal("önceki oturumun kapanması beklendi (1 oturum, 0.4 sn)",
            XboxCloseWait.Line(1, TimeSpan.FromMilliseconds(420), timedOut: false));
        Assert.Equal("önceki oturumun kapanması 10.0 sn'de bitmedi (2 oturum); yeni oturum yine açılıyor",
            XboxCloseWait.Line(2, TimeSpan.FromSeconds(10), timedOut: true));
    }

    [Fact]
    public void ExitLineNamesSessionsLeftOpen()
    {
        Assert.Equal("1/1 Xbox oturumu kapatıldı", XboxCloseWait.ExitLine(1, 1));
        Assert.Contains("açık kalmış olabilir", XboxCloseWait.ExitLine(2, 1));
    }

    [Fact]
    public void LimitsAreShort()
    {
        Assert.Equal(TimeSpan.FromSeconds(10), XboxCloseWait.WaitLimit);
        Assert.True(XboxCloseWait.ExitLimit <= TimeSpan.FromSeconds(2));
    }
}
