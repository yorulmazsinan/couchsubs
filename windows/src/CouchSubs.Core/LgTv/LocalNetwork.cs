// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace CouchSubs.Core.LgTv;

/// <summary>Bilgisayarın yerel ağ adresleri ve TV aramak için taranacak komşu adresler.</summary>
public static class LocalNetwork
{
    /// <summary>Açık ağ bağdaştırıcılarının özel (ev ağı) IPv4 adresleri.</summary>
    public static IReadOnlyList<IPAddress> PrivateAddresses()
    {
        try
        {
            return
            [
                .. NetworkInterface.GetAllNetworkInterfaces()
                    .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback
                                && !IsContainerBridge(n.Name))
                    .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                    .Select(a => a.Address)
                    .Where(a => a.AddressFamily == AddressFamily.InterNetwork && IsPrivate(a)),
            ];
        }
        catch (NetworkInformationException)
        {
            return [];
        }
    }

    /// <summary>
    /// Linux'ta Docker ve sanal makine köprüleri (docker0, br-…, veth…, virbr…) de özel adres taşır ama arkalarında TV
    /// ya da PS5 yoktur; her biri ağ taramasına 254 adres ekleyip aramayı yarım dakikaya çıkarıyordu.
    /// </summary>
    public static bool IsContainerBridge(string interfaceName) =>
        OperatingSystem.IsLinux() && (interfaceName.StartsWith("docker", StringComparison.Ordinal) || interfaceName.StartsWith("br-", StringComparison.Ordinal)
                                      || interfaceName.StartsWith("veth", StringComparison.Ordinal) || interfaceName.StartsWith("virbr", StringComparison.Ordinal));

    public static bool IsPrivate(IPAddress address)
    {
        var b = address.GetAddressBytes();
        return b.Length == 4 && (b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168));
    }

    /// <summary>Her yerel adresin /24 ağındaki diğer adresler (kendisi hariç), tekrarsız.</summary>
    public static IEnumerable<string> ScanTargets(IEnumerable<IPAddress> locals)
    {
        var seen = new HashSet<string>();
        foreach (var local in locals)
        {
            var bytes = local.GetAddressBytes();
            for (var last = 1; last < 255; last++)
            {
                if (last == bytes[3]) continue;
                var candidate = $"{bytes[0]}.{bytes[1]}.{bytes[2]}.{last}";
                if (seen.Add(candidate)) yield return candidate;
            }
        }
    }

    /// <summary>Verilen portu açık olan adresler.</summary>
    public static async Task<IReadOnlyList<string>> HostsWithOpenPortAsync(int port, TimeSpan connectTimeout,
        CancellationToken cancellationToken = default)
    {
        var found = new System.Collections.Concurrent.ConcurrentBag<string>();
        await Parallel.ForEachAsync(ScanTargets(PrivateAddresses()),
            new ParallelOptions { MaxDegreeOfParallelism = 64, CancellationToken = cancellationToken },
            async (host, token) =>
            {
                using var client = new TcpClient();
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                timeout.CancelAfter(connectTimeout);
                try
                {
                    await client.ConnectAsync(host, port, timeout.Token);
                    found.Add(host);
                }
                catch (Exception error) when (error is SocketException or OperationCanceledException) { }
            });
        cancellationToken.ThrowIfCancellationRequested();
        return [.. found.OrderBy(h => IPAddress.Parse(h).GetAddressBytes()[3])];
    }
}
