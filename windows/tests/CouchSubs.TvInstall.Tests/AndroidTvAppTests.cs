// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.TvInstall.Tests;

public class AndroidTvAppTests
{
    private const string Installed = """
        Packages:
          Package [com.couchsubs.tv] (1a2b3c):
            versionCode=42 minSdk=24 targetSdk=34
            versionName=0.9.18
            User 0: ceDataInode=12345 installed=true hidden=false suspended=false stopped=false notLaunched=false enabled=0
        """;

    [Fact]
    public void InstalledAppIsNotALeftover() => Assert.False(AndroidTvApp.IsLeftover(Installed));

    // #352, #389: TV'den kaldırılan uygulamanın kaydı kalmış; dumpsys sürümü söylüyor ama hiçbir kullanıcıda kurulu değil.
    [Fact]
    public void RecordOfAnUninstalledAppIsALeftover() =>
        Assert.True(AndroidTvApp.IsLeftover(Installed.Replace("installed=true", "installed=false")));

    // #528: TV uygulamayı yalnız ana kullanıcıdan (User 0) kaldırmış, çocuk/ikincil profilde kurulu kalmış.
    [Fact]
    public void AppRemovedOnlyFromMainUserIsALeftoverThatCanBeBroughtBack()
    {
        var multiProfile = Installed.Replace("installed=true", "installed=false") +
                           "\n      User 10: ceDataInode=678 installed=true hidden=false\n";
        Assert.True(AndroidTvApp.IsLeftover(multiProfile));
        Assert.True(AndroidTvApp.CanInstallExisting(multiProfile));
        Assert.False(AndroidTvApp.CanInstallExisting(Installed.Replace("installed=true", "installed=false")));
    }

    [Fact]
    public void AppInstalledForMainUserIsNotALeftoverEvenIfAnotherProfileLacksIt() =>
        Assert.False(AndroidTvApp.IsLeftover(Installed + "\n      User 10: ceDataInode=678 installed=false hidden=false\n"));

    [Fact]
    public void InstallExistingOutputIsRead()
    {
        Assert.True(AndroidTvApp.InstallExistingSucceeded("Package com.couchsubs.tv installed for user: 0\n"));
        Assert.False(AndroidTvApp.InstallExistingSucceeded("Failure [NameNotFoundException]"));
    }

    [Fact]
    public void MissingPackageOrOldOutputWithoutUserLinesIsNotALeftover()
    {
        Assert.False(AndroidTvApp.IsLeftover("Unable to find package: com.couchsubs.tv"));
        Assert.False(AndroidTvApp.IsLeftover("    versionName=0.9.18\n"));
    }
}
