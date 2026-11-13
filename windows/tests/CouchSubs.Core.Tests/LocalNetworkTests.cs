// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using CouchSubs.Core.LgTv;
using Xunit;

namespace CouchSubs.Core.Tests;

public class LocalNetworkTests
{
    [Fact]
    public void ScanCoversTheWholeHomeNetworkExceptThisComputer()
    {
        var targets = LocalNetwork.ScanTargets([IPAddress.Parse("192.168.1.40")]).ToList();
        Assert.Equal(253, targets.Count);
        Assert.Contains("192.168.1.1", targets);
        Assert.Contains("192.168.1.254", targets);
        Assert.DoesNotContain("192.168.1.40", targets);
    }

    [Fact]
    public void TwoAdaptersOnTheSameNetworkAreScannedOnce()
    {
        var targets = LocalNetwork.ScanTargets([IPAddress.Parse("10.0.0.5"), IPAddress.Parse("10.0.0.6")]).ToList();
        Assert.Equal(targets.Count, targets.Distinct().Count());
    }

    [Fact]
    public void OnlyHomeNetworkAddressesArePrivate()
    {
        Assert.True(LocalNetwork.IsPrivate(IPAddress.Parse("192.168.0.10")));
        Assert.True(LocalNetwork.IsPrivate(IPAddress.Parse("172.20.1.1")));
        Assert.True(LocalNetwork.IsPrivate(IPAddress.Parse("10.1.2.3")));
        Assert.False(LocalNetwork.IsPrivate(IPAddress.Parse("8.8.8.8")));
        Assert.False(LocalNetwork.IsPrivate(IPAddress.Parse("172.32.0.1")));
    }

    // Host PC IP: VPN ve sanal bağdaştırıcılar seçilmez (Duhan Ay, 2026-11-13).
    private static LocalNetwork.AdapterAddress Adapter(string name, string description, string address, bool gateway,
        System.Net.NetworkInformation.NetworkInterfaceType type = System.Net.NetworkInformation.NetworkInterfaceType.Ethernet) =>
        new(name, description, type, IPAddress.Parse(address), IPAddress.Parse("255.255.255.0"), gateway);

    private static readonly LocalNetwork.AdapterAddress Wifi = Adapter("Wi-Fi", "Intel(R) Wi-Fi 6 AX201 160MHz", "192.168.1.34", true,
        System.Net.NetworkInformation.NetworkInterfaceType.Wireless80211);
    private static readonly LocalNetwork.AdapterAddress HyperV = Adapter("vEthernet (WSL)", "Hyper-V Virtual Ethernet Adapter", "172.24.80.1", false);
    private static readonly LocalNetwork.AdapterAddress VirtualBox = Adapter("Ethernet 2", "VirtualBox Host-Only Ethernet Adapter", "192.168.56.1", false);
    private static readonly LocalNetwork.AdapterAddress Vpn = Adapter("ProtonVPN", "WireGuard Tunnel", "10.2.0.2", true);

    [Fact]
    public void TheAdapterOnTheTvsNetworkIsChosen() =>
        Assert.Equal("192.168.1.34", LocalNetwork.ChooseComputerAddress([HyperV, VirtualBox, Vpn, Wifi], IPAddress.Parse("192.168.1.171")));

    [Fact]
    public void WithoutATvAddressWifiWinsOverVpnAndVirtualMachines()
    {
        Assert.Equal("192.168.1.34", LocalNetwork.ChooseComputerAddress([HyperV, VirtualBox, Vpn, Wifi], null));
        Assert.Equal("192.168.1.34", LocalNetwork.ChooseComputerAddress([Vpn, HyperV, Wifi], IPAddress.Parse("10.0.0.9")));
    }

    [Fact]
    public void AVirtualAdapterIsUsedOnlyWhenNothingElseExists()
    {
        Assert.Equal("10.2.0.2", LocalNetwork.ChooseComputerAddress([Vpn], null));
        Assert.Null(LocalNetwork.ChooseComputerAddress([], null));
    }

    [Fact]
    public void VirtualAdaptersAreRecognised()
    {
        Assert.True(LocalNetwork.IsVirtual(HyperV.Name, HyperV.Description, HyperV.Type));
        Assert.True(LocalNetwork.IsVirtual(VirtualBox.Name, VirtualBox.Description, VirtualBox.Type));
        Assert.True(LocalNetwork.IsVirtual(Vpn.Name, Vpn.Description, Vpn.Type));
        Assert.False(LocalNetwork.IsVirtual(Wifi.Name, Wifi.Description, Wifi.Type));
        Assert.False(LocalNetwork.IsVirtual("Ethernet", "Realtek PCIe GbE Family Controller", System.Net.NetworkInformation.NetworkInterfaceType.Ethernet));
    }
}
