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

    /// <summary>Açık bir bağdaştırıcının IPv4 adresi; bu bilgisayarın TV'ye söylenecek adresi bunların arasından seçilir.</summary>
    public sealed record AdapterAddress(string Name, string Description, NetworkInterfaceType Type, IPAddress Address, IPAddress Mask, bool HasGateway);

    /// <summary>Açık (loopback dışı) bağdaştırıcıların IPv4 adresleri.</summary>
    public static IReadOnlyList<AdapterAddress> Ipv4Adapters()
    {
        var found = new List<AdapterAddress>();
        try
        {
            foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (network.OperationalStatus != OperationalStatus.Up || network.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                var properties = network.GetIPProperties();
                var hasGateway = properties.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
                foreach (var unicast in properties.UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    found.Add(new AdapterAddress(network.Name, network.Description, network.NetworkInterfaceType, unicast.Address,
                        unicast.IPv4Mask ?? IPAddress.Any, hasGateway));
                }
            }
        }
        catch (NetworkInformationException) { }
        return found;
    }

    /// <summary>Adında ya da açıklamasında bunlardan biri geçen bağdaştırıcı sanaldır (VPN, sanal makine, WSL…).</summary>
    private static readonly string[] VirtualMarkers =
    [
        "virtual", "vethernet", "hyper-v", "virtualbox", "vmware", "vmnet", "wsl", "docker", "tailscale", "zerotier",
        "wireguard", "wintun", "tap-", "tap ", "openvpn", "vpn", "hamachi", "radmin", "nordlynx", "forticlient",
        "fortinet", "anyconnect", "globalprotect", "pangp", "npcap", "loopback", "bluetooth", "teredo", "isatap",
    ];

    /// <summary>
    /// VPN, sanal makine ve WSL bağdaştırıcıları da 192.168.x.x/10.x.x.x adresi taşır ama TV onlara ulaşamaz; Samsung'un
    /// "Host PC IP" alanına bunlardan biri yazılınca TV bağlantıyı kesiyordu (2026-11-13, Duhan Ay, 65U8000F).
    /// </summary>
    public static bool IsVirtual(string name, string description, NetworkInterfaceType type)
    {
        if (type is NetworkInterfaceType.Tunnel or NetworkInterfaceType.Ppp) return true;
        var text = $"{name} {description}".ToLowerInvariant();
        return VirtualMarkers.Any(text.Contains);
    }

    private static bool SameSubnet(AdapterAddress adapter, IPAddress target)
    {
        var mask = adapter.Mask.GetAddressBytes();
        var address = adapter.Address.GetAddressBytes();
        var wanted = target.GetAddressBytes();
        return mask.Length == 4 && mask.Any(b => b != 0) && Enumerable.Range(0, 4).All(i => (address[i] & mask[i]) == (wanted[i] & mask[i]));
    }

    /// <summary>
    /// TV'nin ulaşacağı bu bilgisayar adresi. Sıra: TV ile aynı ağdaki gerçek bağdaştırıcı, sonra varsayılan ağ geçidi olan
    /// gerçek bağdaştırıcı (Wi-Fi ya da Ethernet), sonra herhangi bir gerçek ev ağı adresi; sanal bağdaştırıcı ancak başka
    /// adres yoksa seçilir. TV adresi bilinmiyorsa (<paramref name="near"/> null) aynı ağ adımı atlanır.
    /// </summary>
    public static string? ChooseComputerAddress(IReadOnlyList<AdapterAddress> adapters, IPAddress? near)
    {
        var real = adapters.Where(a => !IsVirtual(a.Name, a.Description, a.Type)).ToList();
        if (near is { AddressFamily: AddressFamily.InterNetwork })
        {
            var sameNetwork = real.Where(a => SameSubnet(a, near)).OrderByDescending(a => a.HasGateway).FirstOrDefault()
                              ?? adapters.FirstOrDefault(a => SameSubnet(a, near));
            if (sameNetwork is not null) return sameNetwork.Address.ToString();
        }
        var best = real.FirstOrDefault(a => a.HasGateway && IsPrivate(a.Address))
                   ?? real.FirstOrDefault(a => IsPrivate(a.Address))
                   ?? real.FirstOrDefault()
                   ?? adapters.FirstOrDefault(a => IsPrivate(a.Address))
                   ?? adapters.FirstOrDefault();
        return best?.Address.ToString();
    }

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
