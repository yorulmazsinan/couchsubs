// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using CouchSubs.Shell;

namespace CouchSubs.App.Services;

/// <summary>
/// Windows Güvenlik Duvarı'nda CouchSubs.exe'ye gelen bağlantı izni. Kurallar COM ile (HNetCfg.FwPolicy2) yönetici
/// gerekmeden okunur; kural yönetici izniyle (UAC) netsh ile eklenir.
/// </summary>
/// <remarks>
/// Velopack uygulamayı %LOCALAPPDATA%\CouchSubsApp\current\CouchSubs.exe yoluna kurar ve güncellemede aynı klasörü
/// yeniler; yol sürümle değişmediği için kural güncellemelerden sonra da geçerli kalır.
/// </remarks>
internal sealed class WindowsFirewall : IFirewall
{
    private const string RuleName = "CouchSubs";
    // NET_FW_PROFILE2_DOMAIN, _PRIVATE, _PUBLIC
    private static readonly int[] Profiles = [1, 2, 4];
    // NET_FW_IP_PROTOCOL_TCP, _UDP; 256 = herhangi biri
    private static readonly int[] Protocols = [6, 17];
    private const int AnyProtocol = 256;
    private const int Inbound = 1;
    private const int Allow = 1;

    private static string? ExePath => Environment.ProcessPath;

    public bool HasRule()
    {
        if (ExePath is not { } exe) return true;
        var type = Type.GetTypeFromProgID("HNetCfg.FwPolicy2");
        if (type is null) return true;
        dynamic policy = Activator.CreateInstance(type)!;
        // Her (profil, protokol) için: izin kuralı var mı, engelleme kuralı var mı. Windows'ta engelleme kuralı izni ezer;
        // kullanıcı ilk açılıştaki soruyu kapattıysa Windows bu exe için engelleme kuralı yazmış olabilir.
        var allowed = new bool[Profiles.Length, Protocols.Length];
        var blocked = new bool[Profiles.Length, Protocols.Length];
        foreach (dynamic rule in (IEnumerable)policy.Rules)
        {
            if (!(bool)rule.Enabled || (int)rule.Direction != Inbound) continue;
            if (!SamePath((string?)rule.ApplicationName, exe)) continue;
            var profiles = (int)rule.Profiles;
            var protocol = (int)rule.Protocol;
            var isAllow = (int)rule.Action == Allow;
            for (var p = 0; p < Profiles.Length; p++)
            {
                if ((profiles & Profiles[p]) == 0) continue;
                for (var q = 0; q < Protocols.Length; q++)
                {
                    if (protocol != AnyProtocol && protocol != Protocols[q]) continue;
                    if (isAllow) allowed[p, q] = true; else blocked[p, q] = true;
                }
            }
        }
        for (var p = 0; p < Profiles.Length; p++)
        {
            // Güvenlik duvarı bu profilde kapalıysa kural gerekmez.
            if (!FirewallEnabled(policy, Profiles[p])) continue;
            for (var q = 0; q < Protocols.Length; q++)
                if (!allowed[p, q] || blocked[p, q]) return false;
        }
        return true;
    }

    /// <summary>
    /// Tek UAC sorusuyla: bu exe'nin gelen bağlantı kurallarının hepsi (Windows'un yazdığı engelleme kuralları da) silinir,
    /// yerine her profilde, her protokolde izin veren tek kural eklenir.
    /// </summary>
    public async Task<bool> AddRuleAsync()
    {
        if (ExePath is not { } exe) return false;
        var program = $"program=\"{exe}\"";
        var command = $"netsh advfirewall firewall delete rule name=all dir=in {program} >nul"
                      + $" & netsh advfirewall firewall add rule name=\"{RuleName}\" dir=in action=allow {program} enable=yes profile=any protocol=any";
        try
        {
            // /s: cmd yalnız baştaki ve sondaki tırnağı atar; yoldaki tırnaklar korunur.
            using var process = Process.Start(new ProcessStartInfo("cmd.exe", $"/s /c \"{command}\"")
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            });
            if (process is null) return false;
            await process.WaitForExitAsync();
        }
        catch (Win32Exception)
        {
            // Kullanıcı Windows'un izin sorusunda Hayır dedi.
            return false;
        }
        try { return await Task.Run(HasRule); }
        catch (Exception) { return true; }
    }

    /// <summary>Kaldırmada kural silinir. Yönetici izni gerekir; yoksa sessizce vazgeçilir (kalan kural zararsızdır).</summary>
    public static void RemoveRuleQuietly()
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo("netsh.exe", $"advfirewall firewall delete rule name=\"{RuleName}\" dir=in")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
            });
            process?.WaitForExit(10_000);
        }
        catch (Exception) { }
    }

    /// <summary>Ağ listesi COM'u (NetworkListManager): kategori 0 = Ortak, 1 = Özel, 2 = Etki alanı.</summary>
    public bool HasPublicNetwork()
    {
        try
        {
            var type = Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B"));
            if (type is null) return false;
            dynamic manager = Activator.CreateInstance(type)!;
            foreach (dynamic connection in (IEnumerable)manager.GetNetworkConnections())
            {
                if (!(bool)connection.IsConnected) continue;
                if ((int)connection.GetNetwork().GetCategory() == 0) return true;
            }
        }
        catch (Exception) { }
        return false;
    }

    private static bool FirewallEnabled(dynamic policy, int profile)
    {
        try { return (bool)policy.FirewallEnabled[profile]; }
        catch (Exception) { return true; }
    }

    private static bool SamePath(string? ruleApp, string exe)
    {
        if (string.IsNullOrEmpty(ruleApp)) return false;
        try
        {
            var expanded = Path.GetFullPath(Environment.ExpandEnvironmentVariables(ruleApp));
            return string.Equals(expanded, Path.GetFullPath(exe), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception) { return false; }
    }
}
