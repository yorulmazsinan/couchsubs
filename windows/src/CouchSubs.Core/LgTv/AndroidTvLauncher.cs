// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core.LgTv;

/// <summary>
/// Bekçinin Android TV'de TV uygulamasını açma yolu; Samsung'daki <see cref="SamsungLauncher"/> ile aynı kural (#1248).
/// Uygulama TV'de çalışırken bulunursa (<see cref="AndroidTvOpenRule.AlreadyRunning"/>: <c>am start</c> gönderilmedi, adres
/// yayınla bildirildi) ya da <c>am start</c> "zaten çalışıyor, öne getirildi" derse, uygulamaya kendisi bağlanması için
/// <see cref="SamsungLauncher.ResumeWait"/> (10 sn) tanınır; bağlanmazsa bir kez kapatılıp (<c>am force-stop</c>) temiz
/// açılır (<c>am start</c>). Bağlanırsa uygulamaya dokunulmaz. Mac/iPhone'daki AndroidTVLauncher ve Android telefondaki
/// openAndroidTv ile aynı.
/// </summary>
/// <remarks>
/// Eskiden Android TV'de bu yol yoktu: akışı kopan ama çalışmayı sürdüren TV uygulaması "zaten açık" sayılıyor, bekçi her
/// denemede yalnız adres yayını gönderiyordu; eski adrese takılmış ya da donmuş sayfa çeviri boyunca bağlanmıyordu.
/// </remarks>
/// <param name="open">Uygulamayı açar; argüman true ise önce kapatır (<c>am force-stop</c>). Çıktısı (ya da
/// <see cref="AndroidTvOpenRule.AlreadyRunning"/>) döner; açılamazsa hata fırlatır.</param>
/// <param name="appConnected">TV uygulaması bilgisayara bağlı mı (altyazı akışı açık).</param>
public sealed class AndroidTvLauncher(Func<bool, Task<string>> open, Func<bool> appConnected, TimeSpan? resumeWait = null,
                                      TimeSpan? poll = null, Action<string>? log = null)
{
    private readonly TimeSpan wait = resumeWait ?? SamsungLauncher.ResumeWait;
    private readonly TimeSpan every = poll ?? TimeSpan.FromMilliseconds(500);

    /// <summary>
    /// Açma sonucu uygulamanın zaten çalıştığını söylüyor mu: açıcı <c>am start</c> göndermedi ("zaten açık") ya da
    /// <c>am start</c> "Activity not started" dedi (ekran yalnız öne geldi). Samsung'daki "resumed"ın karşılığı.
    /// </summary>
    public static bool IsResumed(string output)
    {
        var text = output.Trim();
        return text == AndroidTvOpenRule.AlreadyRunning || text.Contains("Activity not started", StringComparison.Ordinal);
    }

    /// <summary>Açar; çalışan ama bağlanmayan uygulamayı bir kez kapatıp açar. Son açma çıktısı döner.</summary>
    public async Task<string> OpenAsync(CancellationToken cancellationToken = default)
    {
        var output = (await open(false)).Trim();
        if (!IsResumed(output)) return output;
        if (await WaitForConnectionAsync(cancellationToken)) return output;
        log?.Invoke($"Android TV: TV uygulaması çalışıyordu ({output}) ama {wait.TotalSeconds:0} sn'de bağlanmadı; kapatılıp (kapanma isteği, gerekirse am force-stop) yeniden açılıyor");
        return (await open(true)).Trim();
    }

    /// <summary>TV uygulaması <see cref="SamsungLauncher.ResumeWait"/> içinde bağlandıysa true.</summary>
    private async Task<bool> WaitForConnectionAsync(CancellationToken cancellationToken)
    {
        var deadline = DateTime.UtcNow + wait;
        while (DateTime.UtcNow < deadline)
        {
            if (appConnected()) return true;
            await Task.Delay(every, cancellationToken);
        }
        return appConnected();
    }
}
