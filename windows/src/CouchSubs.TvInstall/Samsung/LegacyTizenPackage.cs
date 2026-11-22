// SPDX-License-Identifier: AGPL-3.0-only
// Android'deki LegacyTizenPackage.kt ve iPhone'daki LegacyTizenPackage.swift ile aynı.

using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace CouchSubs.TvInstall.Samsung;

/// <summary>
/// 2016 Samsung TV'ler (Tizen 2.x) için paketin config.xml'i, #71'de 40KU7000'de (Tizen 2.4) elle kurulup çalışan pakete
/// döndürülür. O paketten sonra eklenen iki satır çıkarılır:
/// <list type="bullet">
/// <item><c>network.public</c> izni (0.9.30): yalnız TV adresini bulmanın yedeği (webapis.network.getIp); platform.js
/// hatayı yutar, adres bulunamazsa app.js ev ağını tarar.</item>
/// <item><c>base_screen_resolution</c> ayarı (0.9.30): yalnız 21:9 / 32:9 Samsung monitörler için (#304); 2016 TV'lerde
/// yoktur.</item>
/// </list>
/// Tizen 2.4 tanımadığı satırı içeren paketi sebep yazmadan <c>install failed[118]</c> ile reddediyor; <c>power</c> izni
/// çıkarıldıktan sonra da (#497) 0.9.38 aynı hatayı verdi (#621). Yeni TV'lerde paket değişmez. Asıl eksik paket değil,
/// cihaz profilinin yeriydi (#890): Tizen 2.x profili <c>/home/developer</c>'da arar (<see cref="SamsungTvInstaller.DeviceProfileRemotePath"/>).
/// </summary>
internal static partial class LegacyTizenPackage
{
    /// <summary>Bu sürümden eski TV'lerde (Tizen 2.x) paket sadeleştirilir.</summary>
    private const string FirstModern = "3.0";

    public static bool Applies(string platform) => platform.Length > 0 && Versions.IsNewer(FirstModern, platform);

    /// <summary>Yalın pakette ayrıca çıkarılanlar (günlük için).</summary>
    internal const string LeanRemoved = "tizen:profile, application.launch, network.get";

    /// <summary>
    /// config.xml metninden iki satırı çıkarır. <paramref name="lean"/>: SHA-512 imzalı tam pakete TV yalın
    /// <c>install failed[118]</c> derse (#638, #890) aynı kurulumda bir kez denenen, SHA-256 imzalı yalın paket; <c>tizen:profile</c> satırı ile
    /// <c>application.launch</c> ve <c>network.get</c> izinleri de çıkar (uygulama bunlarsız da açılır; TV adresi ağ
    /// taramasıyla bulunur). Hangisinin tuttuğu günlükten görülür.
    /// </summary>
    internal static string AdaptConfig(string config, bool lean = false)
    {
        var adapted = ScreenResolution().Replace(NetworkPublic().Replace(config, ""), "");
        return lean ? LeanPrivileges().Replace(Profile().Replace(adapted, ""), "") : adapted;
    }

    /// <summary>
    /// Paketin (imzalanmadan önceki geçici kopyanın) config.xml'inden yukarıdaki satırlar çıkarılır; değişen bir şey
    /// yoksa dosyaya dokunulmaz. Değiştiyse true.
    /// </summary>
    public static bool Adapt(string wgtPath, bool lean = false)
    {
        string original;
        using (var read = ZipFile.OpenRead(wgtPath))
        {
            if (read.GetEntry("config.xml") is not { } entry) return false;
            using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
            original = reader.ReadToEnd();
        }
        var config = AdaptConfig(original, lean);
        if (config == original) return false;
        using var zip = ZipFile.Open(wgtPath, ZipArchiveMode.Update);
        using var stream = zip.GetEntry("config.xml")!.Open();
        var bytes = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(config);
        stream.SetLength(0);
        stream.Write(bytes);
        return true;
    }

    [GeneratedRegex("""[ \t]*<tizen:privilege name="http://developer\.samsung\.com/privilege/network\.public"\s*/>[ \t]*\r?\n?""")]
    private static partial Regex NetworkPublic();

    [GeneratedRegex("""[ \t]*<tizen:metadata key="http://tizen\.org/metadata/app_ui_type/base_screen_resolution"[^>]*/>[ \t]*\r?\n?""")]
    private static partial Regex ScreenResolution();

    [GeneratedRegex("""[ \t]*<tizen:profile\s[^>]*/>[ \t]*\r?\n?""")]
    private static partial Regex Profile();

    [GeneratedRegex("""[ \t]*<tizen:privilege name="http://tizen\.org/privilege/(application\.launch|network\.get)"\s*/>[ \t]*\r?\n?""")]
    private static partial Regex LeanPrivileges();
}
