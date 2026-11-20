// SPDX-License-Identifier: AGPL-3.0-only

using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using CouchSubs.TvInstall.Android;

namespace CouchSubs.TvInstall.Tests;

public class AdbConnectionTests
{
    /// <summary>Android TV'nin adbd'si gibi davranan sahte sunucu.</summary>
    private sealed class FakeAdbd : IAsyncDisposable
    {
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;
        /// <summary>Daha önce onaylanmış anahtar; null ise ilk bağlantıda onay istenir.</summary>
        public RSA? TrustedKey { get; set; }
        public bool ApproveNewKeys { get; set; } = true;
        public byte[]? ReceivedPublicKey { get; private set; }
        public MemoryStream ReceivedData { get; } = new();
        public string? OpenedService { get; private set; }
        /// <summary>Açılan bütün hizmetler, sırasıyla (ör. kurulumdan sonra izin ve açma komutları).</summary>
        public List<string> OpenedServices { get; } = [];
        public string Reply { get; set; } = "Success\n";
        private Task? serving;

        public FakeAdbd() => listener.Start();

        public void Serve() => serving = Task.Run(ServeAsync);

        private async Task ServeAsync()
        {
            using var client = await listener.AcceptTcpClientAsync();
            var stream = client.GetStream();
            async Task Send(uint command, uint a0, uint a1, byte[] data) =>
                await stream.WriteAsync(AdbConnection.Encode(command, a0, a1, data));

            var cnxn = await AdbConnection.ReadPacketAsync(stream, default);
            Assert.Equal(AdbConnection.Cnxn, cnxn.Command);

            var token = RandomNumberGenerator.GetBytes(20);
            await Send(AdbConnection.Auth, AdbConnection.AuthToken, 0, token);
            var signature = await AdbConnection.ReadPacketAsync(stream, default);
            Assert.Equal(AdbConnection.AuthSignature, signature.Arg0);
            var accepted = TrustedKey?.VerifyHash(token, signature.Data, HashAlgorithmName.SHA1, RSASignaturePadding.Pkcs1) == true;
            if (!accepted)
            {
                await Send(AdbConnection.Auth, AdbConnection.AuthToken, 0, RandomNumberGenerator.GetBytes(20));
                var publicKey = await AdbConnection.ReadPacketAsync(stream, default);
                Assert.Equal(AdbConnection.AuthPublicKey, publicKey.Arg0);
                ReceivedPublicKey = publicKey.Data;
                if (!ApproveNewKeys)
                {
                    client.Close();
                    return;
                }
            }
            await Send(AdbConnection.Cnxn, AdbConnection.Version, 4096, Encoding.ASCII.GetBytes("device::ro.product.name=tv;\0"));

            while (true)
            {
                AdbConnection.Packet packet;
                try { packet = await AdbConnection.ReadPacketAsync(stream, default); }
                catch (EndOfStreamException) { return; }
                catch (IOException) { return; }
                switch (packet.Command)
                {
                    case AdbConnection.Open:
                        OpenedService = Encoding.UTF8.GetString(packet.Data).TrimEnd('\0');
                        OpenedServices.Add(OpenedService);
                        await Send(AdbConnection.Okay, 77, packet.Arg0, []);
                        if (!OpenedService.StartsWith("exec:"))
                        {
                            await Send(AdbConnection.Wrte, 77, packet.Arg0, Encoding.UTF8.GetBytes(Reply));
                            await Send(AdbConnection.Clse, 77, packet.Arg0, []);
                        }
                        else if (ExpectedLength(OpenedService) == 0)
                        {
                            await Send(AdbConnection.Wrte, 77, packet.Arg0, Encoding.UTF8.GetBytes(Reply));
                            await Send(AdbConnection.Clse, 77, packet.Arg0, []);
                        }
                        break;
                    case AdbConnection.Wrte:
                        ReceivedData.Write(packet.Data);
                        await Send(AdbConnection.Okay, 77, packet.Arg0, []);
                        if (ReceivedData.Length >= ExpectedLength(OpenedService!))
                        {
                            await Send(AdbConnection.Wrte, 77, packet.Arg0, Encoding.UTF8.GetBytes(Reply));
                            await Send(AdbConnection.Clse, 77, packet.Arg0, []);
                        }
                        break;
                }
            }
        }

        private static long ExpectedLength(string service) =>
            service.Contains("-S ") ? long.Parse(service[(service.LastIndexOf("-S ", StringComparison.Ordinal) + 3)..]) : 0;

        public async ValueTask DisposeAsync()
        {
            listener.Stop();
            if (serving is not null) await serving;
        }
    }

    [Fact]
    public async Task NewComputerSendsItsKeyAndWaitsForApproval()
    {
        await using var tv = new FakeAdbd();
        tv.Serve();
        using var key = RSA.Create(2048);
        var asked = false;
        await using (var adb = await AdbConnection.ConnectAsync("127.0.0.1", tv.Port, key, () => asked = true))
        {
            Assert.Equal("Success\n", await adb.RunAsync("shell:echo"));
        }
        Assert.True(asked);
        Assert.NotNull(tv.ReceivedPublicKey);
        // Açık anahtar: base64(android_pubkey) + " kullanıcı@makine" + NUL
        var text = Encoding.ASCII.GetString(tv.ReceivedPublicKey!).TrimEnd('\0');
        var blob = Convert.FromBase64String(text.Split(' ')[0]);
        Assert.Equal(AdbConnection.EncodePublicKey(key), blob);
    }

    [Fact]
    public async Task ApprovedComputerConnectsWithoutAsking()
    {
        using var key = RSA.Create(2048);
        await using var tv = new FakeAdbd { TrustedKey = key };
        tv.Serve();
        var asked = false;
        await using var adb = await AdbConnection.ConnectAsync("127.0.0.1", tv.Port, key, () => asked = true);
        Assert.False(asked);
        Assert.Null(tv.ReceivedPublicKey);
    }

    [Fact]
    public async Task RefusedApprovalIsReported()
    {
        await using var tv = new FakeAdbd { ApproveNewKeys = false };
        tv.Serve();
        using var key = RSA.Create(2048);
        var error = await Assert.ThrowsAsync<AndroidInstallException>(() =>
            AdbConnection.ConnectAsync("127.0.0.1", tv.Port, key, approvalTimeout: TimeSpan.FromSeconds(5)));
        Assert.Equal(AndroidInstallError.NotApproved, error.Error);
    }

    [Fact]
    public async Task ClosedPortIsUnreachable()
    {
        var free = new TcpListener(IPAddress.Loopback, 0);
        free.Start();
        var port = ((IPEndPoint)free.LocalEndpoint).Port;
        free.Stop();
        using var key = RSA.Create(2048);
        var error = await Assert.ThrowsAsync<AndroidInstallException>(() => AdbConnection.ConnectAsync("127.0.0.1", port, key));
        Assert.Equal(AndroidInstallError.Unreachable, error.Error);
    }

    [Fact]
    public async Task InputIsStreamedInChunks()
    {
        using var key = RSA.Create(2048);
        await using var tv = new FakeAdbd { TrustedKey = key };
        tv.Serve();
        var payload = RandomNumberGenerator.GetBytes(10_000);
        await using var adb = await AdbConnection.ConnectAsync("127.0.0.1", tv.Port, key);
        var reply = await adb.RunAsync($"exec:cmd package install -r -S {payload.Length}", new MemoryStream(payload));
        Assert.Equal("Success\n", reply);
        Assert.Equal(payload, tv.ReceivedData.ToArray());
    }

    [Fact]
    public void PublicKeyMatchesAndroidLayout()
    {
        using var key = RSA.Create(2048);
        var blob = AdbConnection.EncodePublicKey(key);
        Assert.Equal(524, blob.Length);
        Assert.Equal(64u, BinaryPrimitives.ReadUInt32LittleEndian(blob));
        var modulus = key.ExportParameters(false).Modulus!;
        var n = new BigInteger(blob.AsSpan(8, 256), isUnsigned: true, isBigEndian: false);
        Assert.Equal(new BigInteger(modulus, isUnsigned: true, isBigEndian: true), n);
        // n0inv * n[0] ≡ -1 (mod 2^32)
        var n0inv = BinaryPrimitives.ReadUInt32LittleEndian(blob.AsSpan(4));
        var n0 = BinaryPrimitives.ReadUInt32LittleEndian(blob.AsSpan(8));
        Assert.Equal(uint.MaxValue, unchecked(n0inv * n0));
        Assert.Equal(65537u, BinaryPrimitives.ReadUInt32LittleEndian(blob.AsSpan(520)));
    }

    [Fact]
    public async Task InstallerSkipsUpToDateApp()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        using var key = AndroidTvInstaller.LoadOrCreateKey(dir);
        await using var tv = new FakeAdbd { TrustedKey = key, Reply = "  versionName=0.7.0\n  versionCode=1" };
        tv.Serve();
        var installer = new AndroidTvInstaller("127.0.0.1", dir, tv.Port);
        var (version, installed) = await installer.EnsureInstalledAsync("yok.apk", "0.7.0");
        Assert.Equal("0.7.0", version);
        Assert.False(installed);
        // Güncel uygulama da katman izni alır (eski CouchSubs kurmuşsa izin yoktur).
        Assert.Contains("shell:appops set com.couchsubs.tv SYSTEM_ALERT_WINDOW allow", tv.OpenedServices);
    }

    [Fact]
    public async Task InstallerGrantsOverlayPermissionBeforeOpeningTheApp()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        var apk = Path.Combine(dir, "couchsubs.apk");
        await File.WriteAllBytesAsync(apk, RandomNumberGenerator.GetBytes(3000));
        using var key = AndroidTvInstaller.LoadOrCreateKey(dir);
        // "Success": dumpsys'te sürüm yok (kurulu değil), kurulum başarılı, appops hata yazmadı.
        await using var tv = new FakeAdbd { TrustedKey = key };
        tv.Serve();
        var installer = new AndroidTvInstaller("127.0.0.1", dir, tv.Port);
        var (version, installed) = await installer.EnsureInstalledAsync(apk, "0.9.11");
        Assert.True(installed);
        Assert.Equal("0.9.11", version);
        var grant = tv.OpenedServices.IndexOf("shell:appops set com.couchsubs.tv SYSTEM_ALERT_WINDOW allow");
        var open = tv.OpenedServices.IndexOf("shell:am start -n com.couchsubs.tv/.MainActivity");
        Assert.True(grant >= 0 && open > grant, string.Join(" | ", tv.OpenedServices));
        Assert.DoesNotContain(tv.OpenedServices, s => s.StartsWith("shell:pm grant"));
    }

    /// <summary>Kurulumdan sonra uygulama altyazı sunucusunun adresiyle açılır (sunucu 8787 dışında olabilir, #617).</summary>
    [Fact]
    public async Task InstallerOpensTheAppWithLaunchParams()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        var apk = Path.Combine(dir, "couchsubs.apk");
        await File.WriteAllBytesAsync(apk, RandomNumberGenerator.GetBytes(3000));
        using var key = AndroidTvInstaller.LoadOrCreateKey(dir);
        await using var tv = new FakeAdbd { TrustedKey = key };
        tv.Serve();
        var installer = new AndroidTvInstaller("127.0.0.1", dir, tv.Port) { LaunchParams = "{\"server\":\"http://192.168.1.5:8790\"}" };
        await installer.EnsureInstalledAsync(apk, "0.9.11");
        Assert.Contains("shell:am start -n com.couchsubs.tv/.MainActivity --es params '{\"server\":\"http://192.168.1.5:8790\"}'",
            tv.OpenedServices);
    }

    [Theory]
    [InlineData(null, "shell:am start -n com.couchsubs.tv/.MainActivity")]
    [InlineData("", "shell:am start -n com.couchsubs.tv/.MainActivity")]
    [InlineData("{\"server\":\"http://10.0.0.2:8787\"}", "shell:am start -n com.couchsubs.tv/.MainActivity --es params '{\"server\":\"http://10.0.0.2:8787\"}'")]
    // Kabukta tırnaktan çıkabilecek değer gönderilmez; uygulama parametresiz açılır.
    [InlineData("{\"server\":\"x'; reboot; '\"}", "shell:am start -n com.couchsubs.tv/.MainActivity")]
    [InlineData("{\"a\":\"b\"}\nreboot", "shell:am start -n com.couchsubs.tv/.MainActivity")]
    public void StartCommandQuotesTheParams(string? launchParams, string expected) =>
        Assert.Equal(expected, AndroidTvInstaller.StartCommand(launchParams));

    [Fact]
    public async Task RefusedAppopsTriesPmGrantAndDoesNotFailTheInstall()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        using var key = AndroidTvInstaller.LoadOrCreateKey(dir);
        await using var tv = new FakeAdbd { TrustedKey = key, Reply = "  versionName=0.9.11\nError: Unknown operation string: SYSTEM_ALERT_WINDOW" };
        tv.Serve();
        var installer = new AndroidTvInstaller("127.0.0.1", dir, tv.Port);
        var (version, installed) = await installer.EnsureInstalledAsync("yok.apk", "0.9.11");
        Assert.Equal("0.9.11", version);
        Assert.False(installed);
        Assert.Contains("shell:pm grant com.couchsubs.tv android.permission.SYSTEM_ALERT_WINDOW", tv.OpenedServices);
    }

    [Fact]
    public void AppopsOutputIsReadAsSuccessOrFailure()
    {
        Assert.False(AndroidTvInstaller.LooksFailed(""));
        Assert.True(AndroidTvInstaller.LooksFailed("Error: Unknown operation string: FOO"));
        Assert.True(AndroidTvInstaller.LooksFailed("Security exception: uid 2000 does not have android.permission.MANAGE_APP_OPS_MODES"));
    }

    [Fact]
    public void KeyIsKeptBetweenRuns()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        using var first = AndroidTvInstaller.LoadOrCreateKey(dir);
        using var second = AndroidTvInstaller.LoadOrCreateKey(dir);
        Assert.Equal(first.ExportParameters(false).Modulus, second.ExportParameters(false).Modulus);
    }

    [Fact]
    public void VersionIsReadFromDumpsys()
    {
        Assert.Equal("0.7.0", AndroidTvInstaller.VersionFromDumpsys("Packages:\n    versionCode=1 minSdk=24\n    versionName=0.7.0\n"));
        Assert.Null(AndroidTvInstaller.VersionFromDumpsys("Unable to find package: com.couchsubs.tv"));
    }

    [Fact]
    public void ScanCoversTheLocalNetworkButNotThisComputer()
    {
        var targets = AndroidTvInstaller.ScanTargets([IPAddress.Parse("192.168.1.20")]).ToList();
        Assert.Equal(253, targets.Count);
        Assert.DoesNotContain("192.168.1.20", targets);
        Assert.Contains("192.168.1.1", targets);
        Assert.True(AndroidTvInstaller.IsPrivate(IPAddress.Parse("10.0.0.5")));
        Assert.False(AndroidTvInstaller.IsPrivate(IPAddress.Parse("8.8.8.8")));
    }
}
