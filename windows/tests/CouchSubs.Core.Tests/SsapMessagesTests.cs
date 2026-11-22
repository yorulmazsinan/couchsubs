// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json.Nodes;
using CouchSubs.Core.LgTv;

namespace CouchSubs.Core.Tests;

public class SsapMessagesTests
{
    [Fact]
    public void RegisterAsksForPromptPairingWithLaunchPermissions()
    {
        var message = JsonNode.Parse(SsapMessages.Register(null))!;
        Assert.Equal("register", (string?)message["type"]);
        var payload = message["payload"]!;
        Assert.Equal("PROMPT", (string?)payload["pairingType"]);
        Assert.Null(payload["client-key"]);
        var permissions = payload["manifest"]!["permissions"]!.AsArray().Select(p => (string?)p).ToList();
        Assert.Contains("LAUNCH", permissions);
        Assert.Contains("READ_RUNNING_APPS", permissions);
    }

    [Fact]
    public void RegisterCarriesStoredClientKey() =>
        Assert.Equal("abc123", (string?)JsonNode.Parse(SsapMessages.Register("abc123"))!["payload"]!["client-key"]);

    [Fact]
    public void LaunchRequestCarriesAppIdAndParams()
    {
        var payload = new JsonObject { ["id"] = "com.couchsubs.tv", ["params"] = new JsonObject { ["server"] = "http://1.2.3.4:8787" } };
        var message = JsonNode.Parse(SsapMessages.Request("7", "ssap://system.launcher/launch", payload))!;
        Assert.Equal("request", (string?)message["type"]);
        Assert.Equal("7", (string?)message["id"]);
        Assert.Equal("ssap://system.launcher/launch", (string?)message["uri"]);
        Assert.Equal("com.couchsubs.tv", (string?)message["payload"]!["id"]);
        Assert.Equal("http://1.2.3.4:8787", (string?)message["payload"]!["params"]!["server"]);
    }

    [Fact]
    public void SsdpResponseYieldsHost()
    {
        const string response = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.1.153:1990/abc/description.xml\r\nST: urn:lge-com:service:webos-second-screen:1\r\nSERVER: WebOS/4.4.0 UPnP/1.0\r\n\r\n";
        Assert.Equal("192.168.1.153", LgDiscovery.HostFromSsdpResponse(response));
        Assert.Null(LgDiscovery.HostFromSsdpResponse("HTTP/1.1 200 OK\r\nST: urn:other\r\n\r\n"));
    }

    // Sorulan hedefi aynen geri söyleyen yanıt LG diye doğrulanmaz: Android TV "LG TV" diye listeleniyor, Bağlan "TV yanıt
    // vermedi" diyordu (X, Toshiba Android TV, Mac'te görüldü; Windows'ta aynı kural).
    [Fact]
    public void EchoedSearchTargetIsNotTakenAsLg()
    {
        const string lg = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.153:1990/abc/description.xml\r\nST: urn:lge-com:service:webos-second-screen:1\r\nSERVER: WebOS/4.4.0 UPnP/1.0\r\n\r\n";
        Assert.Equal(new LgDiscovery.SsdpHit("192.168.1.153", true), LgDiscovery.HitFromSsdpResponse(lg));
        const string lgNoServer = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.153:1990/x.xml\r\nST: urn:lge-com:service:webos-second-screen:1\r\n\r\n";
        Assert.True(LgDiscovery.HitFromSsdpResponse(lgNoServer)!.Confirmed);
        const string echo = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.133:49152/description.xml\r\nST: urn:lge-com:service:webos-second-screen:1\r\nUSN: uuid:5f9ec1b3-ed59-1900-4530-00a0ded0e7e6::urn:lge-com:service:webos-second-screen:1\r\nSERVER: Linux/4.9.125 UPnP/1.0 Portable SDK for UPnP devices/1.6.18\r\n\r\n";
        Assert.Equal(new LgDiscovery.SsdpHit("192.168.1.133", false), LgDiscovery.HitFromSsdpResponse(echo));
        Assert.Equal(new CouchSubs.Core.LgTv.LgTv("Android TV", "192.168.1.133", TvBrand.AndroidTv), LgDiscovery.ClassifyUnconfirmed("192.168.1.133", null, false, true));
        Assert.Null(LgDiscovery.ClassifyUnconfirmed("192.168.1.133", null, false, false));
        Assert.Equal(new CouchSubs.Core.LgTv.LgTv("[LG] webOS TV", "192.168.1.133"), LgDiscovery.ClassifyUnconfirmed("192.168.1.133", "[LG] webOS TV", false, true));
        Assert.Equal(new CouchSubs.Core.LgTv.LgTv("LG TV", "192.168.1.133"), LgDiscovery.ClassifyUnconfirmed("192.168.1.133", null, true, true));
        Assert.True(LgDiscovery.IsSsapGreeting("Hello world\n"));
        Assert.False(LgDiscovery.IsSsapGreeting("Hello World!"));
        Assert.False(LgDiscovery.IsLgDescription("<root><device><manufacturer>Vestel</manufacturer></device></root>"));
        // Yanlış etiketlenen Android TV kapalı LG'nin "yeni adresi" sanılmaz.
        Assert.Null(TvLocator.Moved(new CouchSubs.Core.LgTv.LgTv("[LG] webOS TV", "192.168.1.20"), [new CouchSubs.Core.LgTv.LgTv("Android TV", "192.168.1.133", TvBrand.AndroidTv)]));
    }

    // webOS 3.x (2017) ikinci ekran hedefine cevap vermiyor; "ssdp:all" yanıtı LG olarak tanınır, başka cihaz alınmaz (#498).
    [Fact]
    public void SsdpAllResponseFromOldWebOsIsRecognised()
    {
        const string root = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.40:1259/\r\nST: upnp:rootdevice\r\nUSN: uuid:LGTV2017-1234::upnp:rootdevice\r\nSERVER: Linux/3.10.19-32.afro.4 UPnP/1.0 LGE WebOS TV LGE_DLNA_SDK/1.6.0\r\n\r\n";
        Assert.Equal("192.168.1.40", LgDiscovery.HostFromSsdpResponse(root, LgDiscovery.AllTarget));
        const string netflix = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.40:9080\r\nST: urn:mdx-netflix-com:service:target:1\r\nUSN: uuid:LGTV2017-1234::urn:mdx-netflix-com:service:target:1\r\n\r\n";
        Assert.Equal("192.168.1.40", LgDiscovery.HostFromSsdpResponse(netflix, LgDiscovery.AllTarget));
        const string router = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.1:49152/desc.xml\r\nST: upnp:rootdevice\r\nUSN: uuid:abcd::upnp:rootdevice\r\nSERVER: Linux UPnP/1.0 MiniUPnPd\r\n\r\n";
        Assert.Null(LgDiscovery.HostFromSsdpResponse(router, LgDiscovery.AllTarget));
        // Asıl aramada yalnız ikinci ekran servisi sayılır.
        Assert.Null(LgDiscovery.HostFromSsdpResponse(root));
    }

    [Theory]
    [InlineData("192.168.1.40", "192.168.1.40")]
    [InlineData(" http://192.168.1.40:3000/ ", "192.168.1.40")]
    [InlineData("192,168,1,40", "192.168.1.40")]
    [InlineData("192.168.001.040", "192.168.1.40")]
    [InlineData("192.168.1", null)]
    [InlineData("192.168.1.400", null)]
    [InlineData("lgtv", null)]
    [InlineData("", null)]
    public void ManualTvAddressIsCleaned(string input, string? expected) =>
        Assert.Equal(expected, LgDiscovery.NormalizeHost(input));
}
