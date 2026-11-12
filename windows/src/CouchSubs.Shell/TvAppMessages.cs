// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using CouchSubs.Core.LgTv;

namespace CouchSubs.Shell;

/// <summary>TV uygulaması kurulamayınca gösterilen metin: ne yapılacağı, ayrıntı ve (Samsung'da) gönderilecek günlük.</summary>
public static class TvAppMessages
{
    /// <summary>Samsung'u tam yeniden başlatma: güç tuşu yaklaşık 2 saniye basılı tutulur.</summary>
    public const string RestartTip =
        "To restart a Samsung TV fully, hold the power button on the remote for about 2 seconds until it turns off; a short press only puts it on standby.";

    /// <summary>TV uygulaması açıkken Samsung kendi kendine başka kaynağa geçiyorsa (HDMI-CEC).</summary>
    public const string SourceSwitchTip =
        "If the TV keeps switching to HDMI 1 or another source while the CouchSubs TV app is open, turn off Anynet+ (HDMI-CEC) and Auto Source Switching on the TV: Settings › All Settings › Connection › External Device Manager.";

    /// <param name="samsungLog">Samsung kurulum günlüğünün yolu; Samsung hatalarında metnin sonunda yazar.</param>
    public static string Problem(TvAppState state, TvBrand brand, Localizer text, string samsungLog)
    {
        if (state.Error is not { } error) return "";
        var result = text[Key(error, brand)];
        var samsung = brand == TvBrand.Samsung;
        if (state.Reason is { } reason)
            result += $"\n\n{text[samsung ? "Details:" : "TV says:"]} {reason}";
        if (!samsung) return result;
        if (error is DevModeError.InstallFailed or DevModeError.CertificateRejected)
            result += "\n\n" + text["If the TV shows “Server under maintenance”, it cannot reach Samsung's servers: check the TV's internet connection and its date and time, restart the TV and try again."];
        // Samsung kısa basışta yalnız bekleme moduna geçer; "yeniden başlatın" diyen hatalarda nasıl yapılacağı yazılır.
        if (error is DevModeError.Unreachable or DevModeError.InstallFailed or DevModeError.CertificateRejected)
            result += "\n\n" + text[RestartTip];
        // TV kurulum sırasında HDMI-CEC yüzünden başka kaynağa geçerse bağlantı kopar.
        if (error is DevModeError.ConnectionLost)
            result += "\n\n" + text[SourceSwitchTip];
        return result + "\n\n" + text.Format("If this keeps happening, send us this file: %@", samsungLog);
    }

    /// <summary>
    /// TV'ye bağlanılamayınca ne yapılacağı. Samsung'da izin kutusu süresinde onaylanmadıysa ya da TV reddettiyse bunu
    /// söyler; önceden hepsi "TV yanıt vermedi" diyordu ve kullanıcı kutu çıkana kadar körlemesine yeniden deniyordu.
    /// </summary>
    public static string PairingProblem(Exception error, TvBrand brand, Localizer text)
    {
        const string noAnswer = "The TV did not respond. Make sure it is on and on the same network.";
        if (brand == TvBrand.Samsung)
        {
            if (error is SsapException { Reason: "rejected" })
                return text["The TV refused the connection. Allow CouchSubs in Settings › General › External Device Manager › Device Connection Manager › Device List on the TV, then press Connect again."];
            // Bağlantı kuruldu ama izin 60 saniyede gelmedi (ya da TV bekletip kapattı).
            if (error is OperationCanceledException || error is SsapException { Reason: "cannot connect" })
                return text["The TV's permission box was not accepted within 60 seconds. If no box appeared, open the TV's home screen and press Connect again. If CouchSubs was denied before, allow it in Settings › General › External Device Manager › Device Connection Manager › Device List."];
            return text[noAnswer];
        }
        // TV yanıt verdi ama reddetti ya da süre doldu: gerçek nedeni göster.
        return error is SsapException ssap && ssap.Reason != "cannot connect" ? $"{text[noAnswer]} ({ssap.Reason})" : text[noAnswer];
    }

    /// <summary>Hatanın ne yapılacağını söyleyen metninin anahtarı (İngilizcesi).</summary>
    public static string Key(DevModeError error, TvBrand brand) => error switch
    {
        DevModeError.KeyServerOff => "Key Server is off. Turn it on in the Developer Mode app and keep the app on screen.",
        DevModeError.WrongPassphrase => "The passphrase is not correct. Check it on the TV screen.",
        DevModeError.KeyRefused => "The TV refused the key. Open Key Server and type the passphrase again.",
        DevModeError.Unreachable when brand == TvBrand.Samsung =>
            "The TV did not accept this computer. In the TV's Developer Mode window, check that Host PC IP is this computer's address, then restart the TV.",
        DevModeError.Unreachable => "The TV did not respond. Make sure it is on and on the same network.",
        DevModeError.ToolMissing => "Windows' OpenSSH Client is missing. Add it in Settings › System › Optional features and try again.",
        DevModeError.TooOld => "This Samsung TV is too old for the CouchSubs TV app (2017 models and later are supported).",
        DevModeError.SignInFailed => "Samsung sign-in did not complete. Try again and finish signing in on the page that opens.",
        DevModeError.CertificateFailed => "Samsung did not issue the signing certificate. Try again in a few minutes.",
        DevModeError.NotApproved => "Debugging was not allowed on the TV. Try again and choose Allow on the TV.",
        DevModeError.NotEnoughSpace => "The TV is out of free space. Remove an app you do not use from the TV and try again.",
        DevModeError.CertificateMismatch =>
            "A CouchSubs TV app signed on another computer is still on the TV and could not be removed. On the TV, open Apps, select CouchSubs, delete it and try again.",
        DevModeError.CertificateRejected =>
            "The TV did not accept the signing certificate. Make sure the TV is connected to the internet (it checks the certificate with Samsung) and its date and time are right (Settings › General › System Manager › Time), then try again. CouchSubs gets a new certificate, so you sign in to Samsung once more.",
        DevModeError.TvClockWrong =>
            "The TV's clock is behind, so the new certificate is not valid for it yet. Set the TV's date and time (Settings › General › System Manager › Time) or wait a few minutes, then try again.",
        DevModeError.PackageBlocked =>
            "The TV refuses CouchSubs because an earlier CouchSubs is still registered on it (Tizen error 118, -22), even if it no longer appears among the apps. If CouchSubs is among the TV's apps, delete it there and try again. Otherwise reset Smart Hub (Settings › Support › Device Care › Self Diagnosis › Reset Smart Hub; menu names differ a little by model) and try again. Resetting Smart Hub also removes the other apps you downloaded.",
        DevModeError.ConnectionLost =>
            "The connection to the TV dropped during the install. Keep the TV on and on the same network as this computer, then try again.",
        _ => "The TV app could not be installed. Try again; if it fails again, send us the reason below.",
    };
}
