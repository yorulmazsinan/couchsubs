// SPDX-License-Identifier: AGPL-3.0-only

using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using CouchSubs.TvInstall.Samsung;

namespace CouchSubs.TvInstall.Tests;

/// <summary>Samsung kurulum hatalarının ayrımı ve eski kopyayı kaldırıp yeniden kurma (gerçek TV olmadan).</summary>
public class SamsungInstallTests
{
    private const string Success = "Push complete.\napp_id[CouchSubsT.CouchSubs] installing[100]\nspend time for pkgcmd is [1234]ms\ncmd_ret:0";
    private const string Mismatch = "app_id[CouchSubsT.CouchSubs] install failed[118, -12]\nreason: Check certificate error : :Package with the same id and different certificate has been already installed.:<-12>\ncmd_ret:0";
    private const string AuthorMismatch = "app_id[CouchSubsT.CouchSubs] install failed[118, -11], reason: Author certificate not match :";
    private const string InvalidFormat = "app_id[CouchSubsT.CouchSubs] install failed[118, -12]\nreason: Check certificate error : :Invalid format of certificate in signature.:<-2>";
    private const string NotYetValid = "install failed[118, -12] Check certificate error : :Certificate in signature is not valid yet.:<-7>";
    private const string Blocked = "app_id[CouchSubsT.CouchSubs] install failed[118, -22]\nreason: Security error : :Invalid function parameter was given:<2>";

    [Theory]
    [InlineData(Success, "None")]
    [InlineData(Mismatch, "CertificateMismatch")]
    [InlineData(AuthorMismatch, "CertificateMismatch")]
    [InlineData("install failed[118012]", "CertificateMismatch")]
    [InlineData(InvalidFormat, "CertificateRejected")]
    [InlineData("install failed[118, -12] Check certificate error : :Certificate in signature is expired.:<-6>", "CertificateRejected")]
    [InlineData(NotYetValid, "CertificateNotYetValid")]
    [InlineData(Blocked, "PackageBlocked")]
    [InlineData("install failed[118022]", "PackageBlocked")]
    [InlineData("app_id[CouchSubsT.CouchSubs] download failed[116]", "NotEnoughSpace")]
    [InlineData("install failed[118, -4] operation not allowed", "Incompatible")]
    [InlineData("error: transport connection closed", "ConnectionLost")]
    [InlineData("install failed: IOException: Remote closed channel before sending OKAY", "Other")]
    [InlineData("app_id[CouchSubsT.CouchSubs] install failed[118]", "Other")]
    public void InstallOutputIsClassified(string output, string expected) =>
        Assert.Equal(expected, SamsungInstallDiagnostics.Classify(output).ToString());

    /// 2017 (Tizen 3.0) ve sonrası kurulur; Tizen 3.0–4.0 TV'ler kurulumdan önce cihaz profilini ister.
    [Theory]
    [InlineData("2.4", true, false)]
    [InlineData("2.3.1", true, false)]
    [InlineData("3.0", false, true)]
    [InlineData("4.0", false, true)]
    [InlineData("4.0.0", false, true)]
    [InlineData("5.0", false, false)]
    [InlineData("6.5", false, false)]
    [InlineData("9.0", false, false)]
    [InlineData("", false, false)]
    public void TizenVersionGate(string platform, bool tooOld, bool needsProfile)
    {
        Assert.Equal(tooOld, SamsungTvInstaller.IsTooOld(platform));
        Assert.Equal(needsProfile, SamsungTvInstaller.NeedsDeviceProfile(platform));
    }

    [Fact]
    public void InstalledVersionIsReadFromTheAppList()
    {
        const string rule = "\t------------------------------------------------------------------------";
        var listing = string.Join("\n",
            "\tApplication List for user 5001", "\tUser's Application ", "\t Name \t AppID ",
            rule,
            "\t-------------app_title  =  Jellyfin----------------------------",
            "\t-------------app_tizen_id  =  AprZAARz4r.Jellyfin-----------------",
            "\t-------------app_version  =  1.2.3-----------------------------",
            rule,
            "\t-------------app_title  =  CouchSubs----------------------------",
            "\t-------------app_tizen_id  =  CouchSubsT.CouchSubs----------------",
            "\t-------------app_version  =  0.9.7-----------------------------",
            rule,
            "\tapps count: 2");
        Assert.Equal("0.9.7", SamsungTvInstaller.InstalledVersion(listing));
        Assert.Null(SamsungTvInstaller.InstalledVersion(listing.Replace("CouchSubsT.CouchSubs", "Baska.App")));
        Assert.Null(SamsungTvInstaller.InstalledVersion("closed"));
        Assert.Null(SamsungTvInstaller.InstalledVersion(null));
    }

    [Fact]
    public void UnrelatedFailedWordIsNotAFailure()
    {
        Assert.False(SamsungInstallDiagnostics.Failed("Pull skipped or failed: not found\ninstalling[100]"));
        Assert.Equal(InstallProblem.None, SamsungInstallDiagnostics.Classify(""));
    }

    [Fact]
    public void SummaryKeepsTheTvsErrorLine()
    {
        var summary = SamsungInstallDiagnostics.Summary("Push complete.\n" + Blocked + "\ncmd_ret:0");
        Assert.Contains("install failed[118, -22]", summary);
        Assert.Contains("Security error", summary);
        Assert.DoesNotContain("Push complete", summary);
        Assert.Equal("TV yanıt vermedi", SamsungInstallDiagnostics.Summary(" "));
    }

    [Fact]
    public void ErrorsMapToSpecificCodes()
    {
        Assert.Equal(SamsungInstallError.CertificateMismatch, SamsungInstallDiagnostics.ToError(InstallProblem.CertificateMismatch));
        Assert.Equal(SamsungInstallError.CertificateRejected, SamsungInstallDiagnostics.ToError(InstallProblem.CertificateRejected));
        Assert.Equal(SamsungInstallError.TvClockWrong, SamsungInstallDiagnostics.ToError(InstallProblem.CertificateNotYetValid));
        Assert.Equal(SamsungInstallError.PackageBlocked, SamsungInstallDiagnostics.ToError(InstallProblem.PackageBlocked));
        Assert.Equal(SamsungInstallError.NotEnoughSpace, SamsungInstallDiagnostics.ToError(InstallProblem.NotEnoughSpace));
        Assert.Equal(SamsungInstallError.ConnectionLost, SamsungInstallDiagnostics.ToError(InstallProblem.ConnectionLost));
        Assert.Equal(SamsungInstallError.InstallFailed, SamsungInstallDiagnostics.ToError(InstallProblem.Incompatible));
    }

    [Fact]
    public async Task OldCopyWithAnotherCertificateIsRemovedAndInstalledAgain()
    {
        var tv = new FakeTv(Mismatch, Success);
        var log = TempLog();
        await SamsungTvInstaller.InstallWithRecoveryAsync(tv, null, log, CancellationToken.None);
        Assert.Equal(2, tv.Installs);
        Assert.Equal(["0 vd_appuninstall CouchSubsT", "0 vd_appuninstall CouchSubsT.CouchSubs"], tv.Commands);
        var text = File.ReadAllText(log.Path!);
        Assert.Contains("install failed[118, -12]", text);
        Assert.Contains("installing[100]", text);
    }

    [Fact]
    public async Task SuccessfulInstallRemovesNothing()
    {
        var tv = new FakeTv(Success);
        await SamsungTvInstaller.InstallWithRecoveryAsync(tv, null, new InstallLog(null), CancellationToken.None);
        Assert.Equal(1, tv.Installs);
        Assert.Empty(tv.Commands);
    }

    [Fact]
    public async Task MismatchThatStaysAfterRemovalIsReportedWithTheTvsWords()
    {
        var tv = new FakeTv(AuthorMismatch, AuthorMismatch);
        var error = await Assert.ThrowsAsync<SamsungInstallException>(() =>
            SamsungTvInstaller.InstallWithRecoveryAsync(tv, null, new InstallLog(null), CancellationToken.None));
        Assert.Equal(SamsungInstallError.CertificateMismatch, error.Error);
        Assert.Contains("Author certificate not match", error.Detail);
        Assert.Equal(2, tv.Installs);
    }

    [Fact]
    public async Task BlockedPackageIdIsReportedAfterOneRetry()
    {
        var tv = new FakeTv(Blocked, Blocked);
        var error = await Assert.ThrowsAsync<SamsungInstallException>(() =>
            SamsungTvInstaller.InstallWithRecoveryAsync(tv, null, new InstallLog(null), CancellationToken.None));
        Assert.Equal(SamsungInstallError.PackageBlocked, error.Error);
        Assert.Contains("118, -22", error.Detail);
        Assert.Equal(2, tv.Commands.Count);
    }

    [Theory]
    [InlineData(InvalidFormat, SamsungInstallError.CertificateRejected)]
    [InlineData(NotYetValid, SamsungInstallError.TvClockWrong)]
    [InlineData("download failed[116]", SamsungInstallError.NotEnoughSpace)]
    [InlineData("connection reset by peer", SamsungInstallError.ConnectionLost)]
    public async Task RemovingTheOldCopyIsNotTriedWhenItCannotHelp(string output, SamsungInstallError expected)
    {
        var tv = new FakeTv(output);
        var error = await Assert.ThrowsAsync<SamsungInstallException>(() =>
            SamsungTvInstaller.InstallWithRecoveryAsync(tv, null, new InstallLog(null), CancellationToken.None));
        Assert.Equal(expected, error.Error);
        Assert.Empty(tv.Commands);
        Assert.Equal(1, tv.Installs);
    }

    [Fact]
    public async Task FailingUninstallStillRetriesAndIsLogged()
    {
        var tv = new FakeTv(Mismatch, Success) { UninstallError = new IOException("Remote closed channel") };
        var log = TempLog();
        await SamsungTvInstaller.InstallWithRecoveryAsync(tv, null, log, CancellationToken.None);
        Assert.Equal(2, tv.Installs);
        Assert.Contains("Remote closed channel", File.ReadAllText(log.Path!));
    }

    [Fact]
    public void CertificateIssuedSlightlyInTheFutureIsStillUsable()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        WriteProfile(dir, DateTimeOffset.UtcNow.AddMinutes(10), DateTimeOffset.UtcNow.AddYears(1));
        var profile = SigningProfile.In(dir);
        Assert.True(profile.IsValid(DateTime.UtcNow), "bilgisayarın saati biraz geride diye yeni sertifika istenmez");
        Assert.False(profile.IsValid(DateTime.UtcNow.AddYears(2)), "süresi dolan sertifika yenilenir");
    }

    [Fact]
    public void ProfileOfAnotherTvIsNotUsed()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        WriteProfile(dir, DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(1));
        File.WriteAllText(Path.Combine(dir, "duid.txt"), "AAAAAAAAAAAAA");
        var profile = SigningProfile.In(dir);
        Assert.True(profile.IsFor("AAAAAAAAAAAAA"));
        Assert.False(profile.IsFor("BBBBBBBBBBBBB"));
        Assert.Contains("başka TV'nin", profile.Describe(DateTime.UtcNow, "BBBBBBBBBBBBB"));
        Assert.Contains("geçerli", profile.Describe(DateTime.UtcNow, "AAAAAAAAAAAAA"));
    }

    [Fact]
    public void RejectedCertificateIsSetAsideSoANewOneIsRequested()
    {
        var parent = Directory.CreateTempSubdirectory().FullName;
        var dir = Path.Combine(parent, "DUID1234");
        Directory.CreateDirectory(dir);
        WriteProfile(dir, DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(1));
        SigningProfile.Discard(dir);
        Assert.False(Directory.Exists(dir));
        Assert.False(SigningProfile.In(dir).Exists);
        Assert.Single(Directory.GetDirectories(parent, "DUID1234.rejected-*"));
    }

    [Fact]
    public void SamsungServerErrorIsReadable()
    {
        Assert.Equal("code=AUTH_FAIL, message=Invalid access token",
            SamsungCertificates.ServerError(Encoding.UTF8.GetBytes("{\"code\":\"AUTH_FAIL\",\"message\":\"Invalid access token\"}")));
        Assert.Equal("Service Unavailable", SamsungCertificates.ServerError(Encoding.UTF8.GetBytes(" Service Unavailable ")));
    }

    [Fact]
    public void CertificateServerAnswerThatIsNotACertificateIsACertificateError()
    {
        var certificates = new SamsungCertificates(new HttpClient());
        var error = Assert.Throws<SamsungInstallException>(() =>
            certificates.ReadIssued(Encoding.UTF8.GetBytes("{\"message\":\"server under maintenance\"}"), "dağıtıcı"));
        Assert.Equal(SamsungInstallError.CertificateFailed, error.Error);
        Assert.Contains("server under maintenance", error.Detail);
    }

    [Fact]
    public void CallbackProblemNeverShowsTheToken()
    {
        var problem = SamsungLogin.CallbackProblem("code=%7B%22access_token%22%3A%22gizli%22%7D&state=accountcheckdogeneratedstatetext&error=access_denied");
        Assert.Contains("error=access_denied", problem);
        Assert.Contains("code", problem);
        Assert.DoesNotContain("gizli", problem);
    }

    [Fact]
    public void LogIsWrittenAndKeptSmall()
    {
        var log = TempLog();
        log.Write("ilk satır");
        File.AppendAllText(log.Path!, new string('x', (int)InstallLog.MaxBytes + 10) + "\n");
        log.Write("son satır");
        var text = File.ReadAllText(log.Path!);
        Assert.Contains("son satır", text);
        Assert.DoesNotContain("ilk satır", text);
        Assert.True(text.Length < InstallLog.MaxBytes + 1000);
        new InstallLog(null).Write("yol yoksa yazılmaz");
    }

    private static InstallLog TempLog() =>
        new(Path.Combine(Directory.CreateTempSubdirectory().FullName, "logs", "tvinstall.log"));

    private static void WriteProfile(string dir, DateTimeOffset notBefore, DateTimeOffset notAfter)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=Deneme", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var withKey = request.CreateSelfSigned(notBefore, notAfter);
        var leaf = X509CertificateLoader.LoadCertificate(withKey.RawData);
        File.WriteAllBytes(Path.Combine(dir, "author.p12"), SamsungCertificates.Pkcs12(leaf, key, "parola"));
        File.WriteAllBytes(Path.Combine(dir, "distributor.p12"), SamsungCertificates.Pkcs12(leaf, key, "parola"));
        File.WriteAllText(Path.Combine(dir, "password.txt"), "parola");
    }

    /// <summary>Sırayla verilen kurulum çıktılarını döndüren sahte TV.</summary>
    private sealed class FakeTv(params string[] outputs) : ISamsungTvShell
    {
        public int Installs { get; private set; }
        public List<string> Commands { get; } = [];
        public Exception? UninstallError { get; init; }

        public Task<string> InstallAsync(CancellationToken cancellationToken) =>
            Task.FromResult(outputs[Math.Min(Installs++, outputs.Length - 1)]);

        public Task<string> ShellAsync(string command, CancellationToken cancellationToken)
        {
            Commands.Add(command);
            if (UninstallError is { } error) throw error;
            return Task.FromResult("uninstall completed");
        }
    }
}
