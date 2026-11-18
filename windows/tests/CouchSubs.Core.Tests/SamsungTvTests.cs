// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using System.Text.Json.Nodes;
using CouchSubs.Core.LgTv;
using Xunit;
using Tv = CouchSubs.Core.LgTv.LgTv;

namespace CouchSubs.Core.Tests;

public class SamsungTvTests
{
    [Fact]
    public void AddressCarriesAppNameAndToken()
    {
        Assert.Equal("wss://192.168.1.20:8002/api/v2/channels/samsung.remote.control?name=Q291Y2hTdWJz",
            SamsungMessages.Url("192.168.1.20", null).ToString());
        Assert.EndsWith("&token=123", SamsungMessages.Url("192.168.1.20", "123").ToString());
    }

    [Fact]
    public void LaunchMessageCarriesParametersAsMetaTag()
    {
        var node = JsonNode.Parse(SamsungMessages.Launch("CouchSubsT.CouchSubs", new Dictionary<string, string> { ["server"] = "http://1.2.3.4:8787" }))!;
        Assert.Equal("ed.apps.launch", node["params"]!["event"]!.GetValue<string>());
        var data = node["params"]!["data"]!;
        Assert.Equal("CouchSubsT.CouchSubs", data["appId"]!.GetValue<string>());
        Assert.Equal("http://1.2.3.4:8787", JsonNode.Parse(data["metaTag"]!.GetValue<string>())!["server"]!.GetValue<string>());
    }

    [Fact]
    public void ConnectionResults()
    {
        Assert.Equal("55", SamsungMessages.ConnectResult("{\"event\":\"ms.channel.connect\",\"data\":{\"token\":\"55\"}}"));
        Assert.Equal("", SamsungMessages.ConnectResult("{\"event\":\"ms.channel.connect\",\"data\":{}}"));
        Assert.Null(SamsungMessages.ConnectResult("{\"event\":\"ms.channel.ready\"}"));
        Assert.Null(SamsungMessages.ConnectResult("not json"));
        Assert.Throws<SsapException>(() => SamsungMessages.ConnectResult("{\"event\":\"ms.channel.unauthorized\"}"));
        Assert.Throws<SsapException>(() => SamsungMessages.ConnectResult("{\"event\":\"ms.channel.timeOut\"}"));
    }

    /// #40: TV jetonsuz "connect" dönünce saklı jeton silinmemeli; silinirse her bağlantıda TV yeniden izin sorar.
    [Fact]
    public void EmptyTokenDoesNotReplaceSavedOne()
    {
        Assert.Equal("55", SamsungTokenHolder.KeptToken("55", ""));
        Assert.Equal("77", SamsungTokenHolder.KeptToken("55", "77"));
        Assert.Equal("", SamsungTokenHolder.KeptToken(null, ""));
    }

    /// #40: bekçinin bağlantısında TV yeni jeton verirse sonraki bağlantı onu kullanır ve jeton saklanır.
    [Fact]
    public void KeeperRemembersNewToken()
    {
        var saved = new List<string>();
        var holder = new SamsungTokenHolder("", saved.Add);
        holder.Received("");
        Assert.Empty(saved);
        holder.Received("88");
        Assert.Equal("88", holder.Current);
        holder.Received("88");
        holder.Received("");
        Assert.Equal("88", holder.Current);
        Assert.Equal(["88"], saved);
    }

    [Fact]
    public void DeviceNameIsRead()
    {
        Assert.Equal("[TV] Samsung QN70F", SamsungMessages.DeviceName("{\"device\":{\"name\":\"[TV] Samsung QN70F\"}}"));
        Assert.Null(SamsungMessages.DeviceName("{}"));
    }

    // Samsung'un 8001 yanıtından (kısaltılmış): geliştirici modu ve Host PC IP metin olarak gelir.
    private const string DevModeOn =
        "{\"device\":{\"name\":\"[TV] Samsung Q60\",\"developerMode\":\"1\",\"developerIP\":\"192.168.1.50\",\"ip\":\"192.168.1.20\"},\"type\":\"Samsung SmartTV\"}";

    [Fact]
    public void DeveloperModeAndHostPcIpAreRead()
    {
        Assert.True(SamsungMessages.DeveloperMode(DevModeOn));
        Assert.Equal("192.168.1.50", SamsungMessages.DeveloperIp(DevModeOn));
        Assert.False(SamsungMessages.DeveloperMode("{\"device\":{\"developerMode\":\"0\",\"developerIP\":\"0.0.0.0\"}}"));
        // "0.0.0.0" ve boş alan Host PC IP girilmemiş demek.
        Assert.Null(SamsungMessages.DeveloperIp("{\"device\":{\"developerMode\":\"0\",\"developerIP\":\"0.0.0.0\"}}"));
        Assert.Null(SamsungMessages.DeveloperIp("{\"device\":{\"developerIP\":\"\"}}"));
        // Bildirmeyen eski TV ve bozuk yanıt: bilinmiyor.
        Assert.Null(SamsungMessages.DeveloperMode("{\"device\":{\"name\":\"TV\"}}"));
        Assert.Null(SamsungMessages.DeveloperMode("<html>"));
        Assert.Null(SamsungMessages.DeveloperIp("{\"device\":[]}"));
        Assert.True(SamsungMessages.DeveloperMode("{\"device\":{\"developerMode\":1}}"));
    }

    [Fact]
    public void HostPcIpMismatchNeedsBothAddresses()
    {
        Assert.True(SamsungMessages.HostPcIpMismatch("192.168.1.50", "192.168.1.34"));
        Assert.False(SamsungMessages.HostPcIpMismatch("192.168.1.34", "192.168.1.34"));
        Assert.False(SamsungMessages.HostPcIpMismatch(null, "192.168.1.34"));
        Assert.False(SamsungMessages.HostPcIpMismatch("192.168.1.50", null));
    }

    [Fact]
    public void SavedTvWithoutBrandIsLg() =>
        Assert.Equal(TvBrand.Lg, JsonSerializer.Deserialize<Tv>("{\"Name\":\"LG TV\",\"Host\":\"1.2.3.4\"}")!.Brand);

    [Fact]
    public void LocatorDoesNotMoveToAnotherBrand() =>
        Assert.Null(TvLocator.Moved(new Tv("Salon", "1.1.1.1"), [new Tv("Salon", "1.1.1.2", TvBrand.Samsung)]));
}
