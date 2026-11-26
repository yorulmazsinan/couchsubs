// SPDX-License-Identifier: AGPL-3.0-only

using System.IO.Compression;
using System.Text;
using System.Text.Json;
using CouchSubs.Core.LgTv;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// #1098: LG 43LH590V (Full HD, webOS 3.x) sayfanın yalnız sol üst 1280x720'sini çiziyordu. Kurulumda Full HD webOS 3.x
/// TV'ye paket appinfo.json'da 1280x720 çözünürlükle gider. Ortak vakalar core/Tests/CouchSubsCoreTests/Fixtures/
/// lg-hd-package.json (Mac/iPhone LgHdPackageTests.swift ve Android LgHdPackageTest.kt aynı dosyayı okur).
/// </summary>
[Collection(ChildProcessGuardTests.Group)]
public class LgHdPackageTests
{
    private static JsonElement Fixture() =>
        JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("lg-hd-package.json"))).RootElement;

    private static byte[] Ipk(JsonElement fixture) => Convert.FromBase64String(fixture.GetProperty("package").GetString()!);

    private const string AppInfo = "usr/palm/applications/com.couchsubs.tv/appinfo.json";

    /// <summary>tar'daki dosyalar (ad → içerik).</summary>
    private static Dictionary<string, string> Files(byte[] ipk)
    {
        var members = LgHdPackage.ReadAr(ipk)!;
        var data = members.Single(m => m.Name == "data.tar.gz");
        using var input = new GZipStream(new MemoryStream(data.Body), CompressionMode.Decompress);
        using var raw = new MemoryStream();
        input.CopyTo(raw);
        var tar = raw.ToArray();
        var files = new Dictionary<string, string>();
        var offset = 0;
        while (offset + 512 <= tar.Length && tar.AsSpan(offset, 512).IndexOfAnyExcept((byte)0) >= 0)
        {
            var name = Encoding.UTF8.GetString(tar, offset, 100).TrimEnd('\0');
            var size = Convert.ToInt32(Encoding.ASCII.GetString(tar, offset + 124, 12).Trim('\0', ' '), 8);
            files[name] = Encoding.UTF8.GetString(tar, offset + 512, size);
            offset += 512 + (size + 511) / 512 * 512;
        }
        return files;
    }

    [Fact]
    public void OnlyFullHdWebOs3TvsGetThe720pPackage()
    {
        foreach (var item in Fixture().GetProperty("systemInfo").EnumerateArray())
        {
            var screen = LgHdPackage.ScreenOf(item.GetProperty("reply").GetString()!);
            var note = item.GetProperty("note").GetString();
            Assert.True(item.GetProperty("hd").GetBoolean() == screen.Hd, note);
            Assert.True(item.GetProperty("model").ValueKind == JsonValueKind.Null
                ? screen.Model is null
                : item.GetProperty("model").GetString() == screen.Model, note);
        }
        Assert.Equal("43LH590V-ZE, UHD false, sdk 03.70.50 → 1280x720",
            LgHdPackage.ScreenOf(Fixture().GetProperty("systemInfo")[0].GetProperty("reply").GetString()!).Summary);
    }

    [Fact]
    public void AppInfoResolutionBecomes720pAndNothingElseChanges()
    {
        var fixture = Fixture();
        var original = Ipk(fixture);
        var adapted = LgHdPackage.Adapt(original);
        Assert.NotNull(adapted);
        var before = Files(original);
        var after = Files(adapted!);
        Assert.Equal(fixture.GetProperty("appInfo").GetString(), before[AppInfo]);
        Assert.Equal(fixture.GetProperty("adaptedAppInfo").GetString(), after[AppInfo]);
        Assert.Contains("\"resolution\": \"1280x720\" ,", after[AppInfo]);
        using (JsonDocument.Parse(after[AppInfo])) { }
        Assert.Equal(fixture.GetProperty("appJs").GetString(), after["usr/palm/applications/com.couchsubs.tv/app.js"]);
        Assert.Equal(before.Count, after.Count);
        foreach (var (name, text) in before.Where(f => f.Key != AppInfo)) Assert.Equal(text, after[name]);
        var a = LgHdPackage.ReadAr(original)!;
        var b = LgHdPackage.ReadAr(adapted!)!;
        Assert.Equal(new[] { "debian-binary", "control.tar.gz", "data.tar.gz" }, a.Select(m => m.Name));
        Assert.Equal(a.Select(m => m.Name), b.Select(m => m.Name));
        Assert.Equal(a[0].Body, b[0].Body);
        Assert.Equal(a[1].Body, b[1].Body);
        // Zaten 1280x720 olan paket bir daha değişmez; bozuk paket değişmez.
        Assert.Null(LgHdPackage.Adapt(adapted!));
        Assert.Null(LgHdPackage.Adapt("not an ipk"u8.ToArray()));
    }

    private sealed class FakeShell(string reply) : IRemoteShell
    {
        public List<(string Command, string? Input, byte[]? Bytes)> Calls { get; } = [];
        public Task<CommandResult> RunAsync(string command, string? inputFile = null)
        {
            Calls.Add((command, inputFile, inputFile is null ? null : File.ReadAllBytes(inputFile)));
            if (command == LgHdPackage.SystemInfoCommand) return Task.FromResult(new CommandResult(0, reply));
            if (command.Contains("appinfo.json")) return Task.FromResult(new CommandResult(0, "\"version\": \"0.9.122\""));
            return Task.FromResult(new CommandResult(0, ""));
        }
    }

    private static async Task<(FakeShell Shell, string Package, string Note)> InstallAsync(string reply)
    {
        var folder = Path.Combine(Path.GetTempPath(), $"lg-hd-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(folder);
        var package = Path.Combine(folder, "com.couchsubs.tv_0.9.122_all.ipk");
        File.WriteAllBytes(package, Ipk(Fixture()));
        var shell = new FakeShell(reply);
        var installer = new DevModeInstaller(shell, TimeSpan.FromMilliseconds(1), TimeSpan.FromMilliseconds(200), TimeSpan.FromMilliseconds(200));
        var note = await installer.InstallAsync(package, "0.9.122");
        return (shell, package, note);
    }

    [Fact]
    public async Task FullHdWebOs3TvGetsTheAdaptedPackageUnderTheSameName()
    {
        var fixture = Fixture();
        var (shell, package, note) = await InstallAsync(fixture.GetProperty("systemInfo")[0].GetProperty("reply").GetString()!);
        Assert.Equal("LG paketi: 43LH590V-ZE, UHD false, sdk 03.70.50 → 1280x720", note);
        var upload = shell.Calls.First(c => c.Input is not null);
        Assert.NotEqual(package, upload.Input);
        Assert.Equal(Path.GetFileName(package), Path.GetFileName(upload.Input));
        Assert.Contains("cat > '/media/developer/temp/com.couchsubs.tv_0.9.122_all.ipk'", upload.Command);
        Assert.Equal(fixture.GetProperty("adaptedAppInfo").GetString(), Files(upload.Bytes!)[AppInfo]);
        // Geçici kopya silinir.
        Assert.False(File.Exists(upload.Input));
        Directory.Delete(Path.GetDirectoryName(package)!, recursive: true);
    }

    [Fact]
    public async Task OtherTvsGetThePackageUnchanged()
    {
        var oled = Fixture().GetProperty("systemInfo").EnumerateArray()
            .First(c => c.GetProperty("model").ValueKind == JsonValueKind.String && c.GetProperty("model").GetString() == "OLED55C24LA")
            .GetProperty("reply").GetString()!;
        foreach (var reply in new[] { oled, "" })
        {
            var (shell, package, note) = await InstallAsync(reply);
            var upload = shell.Calls.First(c => c.Input is not null);
            Assert.Equal(package, upload.Input);
            Assert.Equal(Ipk(Fixture()), upload.Bytes);
            Assert.EndsWith("→ 1920x1080", note);
            Directory.Delete(Path.GetDirectoryName(package)!, recursive: true);
        }
    }
}
