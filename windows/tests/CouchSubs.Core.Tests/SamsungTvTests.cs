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

    /// <summary>
    /// #637, #511: kurulu olmayan uygulamaya DEEP_LINK gidince Smart Hub "Sunucu bakım altında (1544007)" diyor; önce
    /// TV'nin kurulu uygulama listesine bakılır.
    /// </summary>
    [Fact]
    public void KnownInstalledAppLaunchesWithoutTheList()
    {
        // Uygulama bu TV'den daha önce bağlandı ya da bu cihaz kurdu: listeye bakılmaz, liste "yok" dese de açılır.
        Assert.False(SamsungAppKnowledge.ChecksList(knownInstalled: true));
        Assert.Equal("DEEP_LINK", SamsungAppKnowledge.ActionFor(true, SamsungAppPresence.Missing));
        Assert.Equal("DEEP_LINK", SamsungAppKnowledge.ActionFor(true, null));
        // Hiç bağlanmamış ve kurulum kaydı yok: liste belirler; listede yoksa komut gönderilmez (#637).
        Assert.True(SamsungAppKnowledge.ChecksList(knownInstalled: false));
        Assert.Null(SamsungAppKnowledge.ActionFor(false, SamsungAppPresence.Missing));
        Assert.Equal("DEEP_LINK", SamsungAppKnowledge.ActionFor(false, SamsungAppPresence.Installed(2)));
        Assert.Equal("NATIVE_LAUNCH", SamsungAppKnowledge.ActionFor(false, SamsungAppPresence.Installed(4)));
        Assert.Equal("DEEP_LINK", SamsungAppKnowledge.ActionFor(false, null));
    }

    [Fact]
    public void ConnectedTvIsRememberedAsInstalled()
    {
        var host = "192.0.2." + Random.Shared.Next(1, 250);
        var saved = new List<string>();
        var before = SamsungAppKnowledge.Changed;
        SamsungAppKnowledge.Changed = saved.Add;
        try
        {
            Assert.False(SamsungAppKnowledge.IsKnown(host));
            SamsungAppKnowledge.Mark(host);
            SamsungAppKnowledge.Mark(host);
            Assert.True(SamsungAppKnowledge.IsKnown(" " + host + " "));
            Assert.Equal([host], saved);
            SamsungAppKnowledge.Forget(host);
            Assert.False(SamsungAppKnowledge.IsKnown(host));
            Assert.False(SamsungAppKnowledge.IsKnown(null));
        }
        finally { SamsungAppKnowledge.Changed = before; }
    }

    [Fact]
    public void InstalledAppListDecidesLaunch()
    {
        var request = JsonNode.Parse(SamsungMessages.InstalledAppsRequest)!;
        Assert.Equal("ed.installedApp.get", request["params"]!["event"]!.GetValue<string>());

        const string listed = "{\"data\":{\"data\":[{\"appId\":\"111299001912\",\"app_type\":2,\"name\":\"YouTube\"}," +
                              "{\"appId\":\"CouchSubsT.CouchSubs\",\"app_type\":2,\"name\":\"CouchSubs\"}]},\"event\":\"ed.installedApp.get\",\"from\":\"host\"}";
        Assert.Equal(SamsungAppPresence.Installed(2), SamsungMessages.InstalledApp(listed, "CouchSubsT.CouchSubs"));
        Assert.Equal(SamsungAppPresence.Missing, SamsungMessages.InstalledApp(listed.Replace("CouchSubsT.CouchSubs", "Baska.App"), "CouchSubsT.CouchSubs"));
        Assert.Null(SamsungMessages.InstalledApp("{\"event\":\"ed.edenTV.update\",\"data\":{}}", "CouchSubsT.CouchSubs"));
        Assert.Null(SamsungMessages.InstalledApp("not json", "CouchSubsT.CouchSubs"));

        Assert.Equal("DEEP_LINK", SamsungMessages.ActionType(2));
        Assert.Equal("DEEP_LINK", SamsungMessages.ActionType(null));
        Assert.Equal("NATIVE_LAUNCH", SamsungMessages.ActionType(4));
        var native = JsonNode.Parse(SamsungMessages.Launch("A.B", new Dictionary<string, string>(), "NATIVE_LAUNCH"))!;
        Assert.Equal("NATIVE_LAUNCH", native["params"]!["data"]!["action_type"]!.GetValue<string>());
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
