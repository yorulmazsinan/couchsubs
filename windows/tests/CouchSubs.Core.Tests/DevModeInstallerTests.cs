// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core.LgTv;
using Xunit;

namespace CouchSubs.Core.Tests;

public class DevModeInstallerTests
{
    private sealed class FakeShell : IRemoteShell
    {
        public List<(string Command, string? Input)> Calls { get; } = [];
        public Func<string, CommandResult?> Answer { get; set; } = _ => null;
        public Func<string, Exception?> Failure { get; set; } = _ => null;
        public Task<CommandResult> RunAsync(string command, string? inputFile = null)
        {
            Calls.Add((command, inputFile));
            if (Failure(command) is { } error) throw error;
            return Task.FromResult(Answer(command) ?? new CommandResult(0, ""));
        }
    }

    /// <summary>10 baytlık geçici paket; kurulum TV'deki boyutu bununla karşılaştırır.</summary>
    private static string Package()
    {
        var file = Path.Combine(Path.GetTempPath(), $"couchsubs-test-{Guid.NewGuid():N}.ipk");
        File.WriteAllBytes(file, new byte[10]);
        return file;
    }

    private static DevModeInstaller Installer(FakeShell shell) =>
        new(shell, TimeSpan.FromMilliseconds(1), TimeSpan.FromMilliseconds(200), TimeSpan.FromMilliseconds(200));

    private static bool IsInstall(string line) => line.Contains("appInstallService");

    [Fact]
    public async Task KeyFileIsOnlyReadableByTheOwner()
    {
        var file = Path.Combine(Path.GetTempPath(), $"couchsubs-test-{Guid.NewGuid():N}");
        try
        {
            await DevModeInstaller.WritePrivateAsync(file, [1, 2, 3]);
            Assert.Equal([1, 2, 3], await File.ReadAllBytesAsync(file));
            if (!OperatingSystem.IsWindows())
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(file));
        }
        finally
        {
            File.Delete(file);
        }
    }

    [Fact]
    public void VersionIsReadFromThePackageName()
    {
        Assert.Equal("0.6.1", DevModeInstaller.VersionOfPackage("com.couchsubs.tv_0.6.1_all.ipk"));
        Assert.Null(DevModeInstaller.VersionOfPackage("notes.txt"));
    }

    [Fact]
    public void RemainingSessionTimeIsReadFromLgsReply()
    {
        Assert.Equal(999, DevModeInstaller.RemainingHours("{\"result\":\"success\",\"errorCode\":\"200\",\"errorMsg\":\"999:58:40\"}"));
        Assert.Null(DevModeInstaller.RemainingHours("{\"result\":\"fail\"}"));
        Assert.Equal("https://developer.lge.com/secure/ResetDevModeSession.dev?sessionToken=ab12", DevModeInstaller.RenewUrl("ab12").AbsoluteUri);
    }

    [Fact]
    public void VersionComparisonIsNumeric()
    {
        Assert.True(DevModeInstaller.IsNewer("0.10.0", "0.9.9"));
        Assert.False(DevModeInstaller.IsNewer("0.6.1", "0.6.1"));
        Assert.False(DevModeInstaller.IsNewer("0.6.0", "0.6.1"));
    }

    [Fact]
    public async Task MissingAppHasNoVersion()
    {
        var shell = new FakeShell { Answer = _ => new CommandResult(1, "No such file") };
        Assert.Null(await Installer(shell).InstalledVersionAsync());
    }

    [Fact]
    public async Task ConnectionProblemsReachTheCaller()
    {
        var refused = new FakeShell { Failure = _ => new DevModeException(DevModeError.KeyRefused) };
        var error = await Assert.ThrowsAsync<DevModeException>(() => Installer(refused).InstalledVersionAsync());
        Assert.Equal(DevModeError.KeyRefused, error.Error);
    }

    [Fact]
    public async Task InstallUploadsThenAsksTheTvToInstallAndWaitsForTheVersion()
    {
        var reads = 0;
        var shell = new FakeShell
        {
            Answer = line =>
            {
                if (!line.Contains("appinfo.json")) return null;
                reads++;
                return new CommandResult(0, reads < 3 ? "\"version\": \"0.4.0\"" : "\"version\": \"0.6.1\"");
            },
        };
        var package = Package();
        var remote = "/media/developer/temp/" + Path.GetFileName(package);
        await Installer(shell).InstallAsync(package, "0.6.1");
        Assert.Equal(package, shell.Calls[0].Input);
        // ares-install gibi: paket kendi adıyla yüklenir, eski CouchSubs paketleri önce silinir.
        Assert.Contains($"cat > '{remote}'", shell.Calls[0].Command);
        Assert.Contains("rm -f /media/developer/temp/com.couchsubs.tv_*.ipk", shell.Calls[0].Command);
        Assert.Contains($"wc -c < '{remote}'", shell.Calls[1].Command);
        Assert.Contains("luna://com.webos.appInstallService/dev/install", shell.Calls[2].Command);
        Assert.Contains($"\"ipkUrl\":\"{remote}\"", shell.Calls[2].Command);
        Assert.Contains($"rm -f '{remote}'", shell.Calls[^1].Command);
        Assert.All(shell.Calls.Skip(1), call => Assert.Null(call.Input));
    }

    [Fact]
    public void InstallCommandKeepsTheSubscriptionOpenUntilTheTvAnswers()
    {
        var command = DevModeInstaller.InstallCommand("/media/developer/temp/com.couchsubs.tv_0.9.6_all.ipk", 180);
        // -n 1 ilk yanıttan sonra aboneliği kapatıyordu; ares-install -i kullanır ve sonucu bekler.
        Assert.DoesNotContain("-n 1", command);
        Assert.Contains("/usr/bin/luna-send-pub -i 'luna://com.webos.appInstallService/dev/install'", command);
        Assert.Contains("{\"id\":\"com.ares.defaultName\",\"ipkUrl\":\"/media/developer/temp/com.couchsubs.tv_0.9.6_all.ipk\",\"subscribe\":true}", command);
        Assert.Contains("while [ $i -lt 180 ]", command);
        Assert.Contains("sleep 210 </dev/null 2>/dev/null |", command);
        Assert.Contains("kill $L", command);
    }

    [Fact]
    public void RepliesAreReadLikeAresInstall()
    {
        var progress = "{\"returnValue\":true,\"subscribed\":true}\n{\"details\":{\"state\":\"installing\"},\"returnValue\":true}\n";
        Assert.Equal(new DevModeInstaller.InstallOutcome(false, false, null), DevModeInstaller.ParseInstallReplies(progress));
        Assert.True(DevModeInstaller.ParseInstallReplies(progress + "{\"details\":{\"state\":\"installed\"},\"returnValue\":true}").Installed);
        Assert.True(DevModeInstaller.ParseInstallReplies("{\"details\":{\"state\":\"SUCCESS\"}}").Installed);

        var failed = DevModeInstaller.ParseInstallReplies(
            progress + "{\"details\":{\"state\":\"install failed\",\"reason\":\"Installation failure\",\"errorCode\":-5},\"returnValue\":true}");
        Assert.True(failed.Failed);
        Assert.Equal("Installation failure (errorCode -5)", failed.Reason);

        var refused = DevModeInstaller.ParseInstallReplies("{\"returnValue\":false,\"errorCode\":-1,\"errorText\":\"Denied method call\"}");
        Assert.Equal(new DevModeInstaller.InstallOutcome(false, true, "Denied method call (errorCode -1)"), refused);

        // Birden çok satıra bölünmüş yanıt ve JSON olmayan satırlar.
        var split = DevModeInstaller.ParseInstallReplies("Error: something\n{\"details\":\n{\"state\":\"installed\"}}\n");
        Assert.True(split.Installed);
    }

    [Fact]
    public async Task InstallReportsTheTvsReasonAndRemovesThePackage()
    {
        var shell = new FakeShell
        {
            Answer = line => IsInstall(line)
                ? new CommandResult(0, "{\"returnValue\":true}\n{\"details\":{\"state\":\"FAILED_IPK_INSTALL\",\"reason\":\"Invalid package\"},\"returnValue\":true}")
                : null,
        };
        var error = await Assert.ThrowsAsync<DevModeException>(() => Installer(shell).InstallAsync(Package(), "0.6.1"));
        Assert.Equal(DevModeError.InstallFailed, error.Error);
        Assert.Equal("Invalid package", error.Detail);
        Assert.Contains("rm -f '/media/developer/temp/couchsubs-test-", shell.Calls[^1].Command);
        Assert.DoesNotContain(shell.Calls, call => call.Command.Contains("appinfo.json"));
    }

    [Fact]
    public async Task StorageErrorsFromTheTvAreReportedAsMissingSpace()
    {
        var shell = new FakeShell
        {
            Answer = line => IsInstall(line)
                ? new CommandResult(0, "{\"details\":{\"state\":\"install failed\",\"reason\":\"Not enough space\"},\"returnValue\":true}")
                : null,
        };
        var error = await Assert.ThrowsAsync<DevModeException>(() => Installer(shell).InstallAsync(Package(), "0.6.1"));
        Assert.Equal(DevModeError.NotEnoughSpace, error.Error);

        var full = new FakeShell { Answer = line => line.Contains("cat >") ? new CommandResult(1, "cat: write error: No space left on device") : null };
        error = await Assert.ThrowsAsync<DevModeException>(() => Installer(full).InstallAsync(Package(), "0.6.1"));
        Assert.Equal(DevModeError.NotEnoughSpace, error.Error);
    }

    [Fact]
    public async Task InstalledReplyIsConfirmedByTheVersion()
    {
        var shell = new FakeShell
        {
            Answer = line => IsInstall(line) ? new CommandResult(0, "{\"details\":{\"state\":\"installed\"},\"returnValue\":true}")
                : line.Contains("appinfo.json") ? new CommandResult(0, "\"version\": \"0.6.1\"") : null,
        };
        await Installer(shell).InstallAsync(Package(), "0.6.1");
        Assert.Contains("rm -f '/media/developer/temp/couchsubs-test-", shell.Calls[^1].Command);
    }

    [Fact]
    public async Task InstallTimesOutWhenTheVersionNeverChanges()
    {
        var shell = new FakeShell { Answer = line => line.Contains("appinfo.json") ? new CommandResult(0, "\"version\": \"0.4.0\"") : null };
        var error = await Assert.ThrowsAsync<DevModeException>(() => Installer(shell).InstallAsync(Package(), "0.6.1"));
        Assert.Equal(DevModeError.InstallFailed, error.Error);
        // TV sonuç vermediyse kurulum sürüyor olabilir; paket silinmez.
        Assert.DoesNotContain(shell.Calls.Skip(1), call => call.Command.StartsWith("rm -f '"));
    }

    [Fact]
    public async Task IncompleteUploadIsReportedBeforeInstalling()
    {
        // Paket TV'ye eksik ulaştıysa kurulum denenmez; hata günlüğü iki boyutu da söyler.
        var shell = new FakeShell { Answer = line => line.Contains("wc -c") ? new CommandResult(0, "7\n") : null };
        var error = await Assert.ThrowsAsync<DevModeException>(() => Installer(shell).InstallAsync(Package(), "0.6.1"));
        Assert.Equal(DevModeError.InstallFailed, error.Error);
        Assert.Contains("7/10", error.Message);
        Assert.DoesNotContain(shell.Calls, call => call.Command.Contains("appInstallService"));
    }

    [Fact]
    public async Task FailedUploadStopsBeforeInstalling()
    {
        var shell = new FakeShell { Answer = line => line.Contains("cat >") ? new CommandResult(1, "disk full") : null };
        await Assert.ThrowsAsync<DevModeException>(() => Installer(shell).InstallAsync(Package(), "0.6.1"));
        Assert.DoesNotContain(shell.Calls, call => call.Command.Contains("appInstallService"));
    }

    [Fact]
    public async Task RealRunnerReadsOutputWithoutInput()
    {
        if (OperatingSystem.IsWindows()) return;
        var result = await new ProcessRunner().RunAsync("/bin/echo", ["merhaba"], null);
        Assert.Equal(new CommandResult(0, "merhaba\n"), result);
    }

    [Fact]
    public async Task RealRunnerPassesEmptyArgumentsAndInput()
    {
        if (OperatingSystem.IsWindows()) return;
        var file = Path.GetTempFileName();
        await File.WriteAllTextAsync(file, "merhaba");
        try
        {
            var result = await new ProcessRunner().RunAsync("/bin/cat", [], file);
            Assert.Equal(new CommandResult(0, "merhaba"), result);
        }
        finally
        {
            File.Delete(file);
        }
    }
}
