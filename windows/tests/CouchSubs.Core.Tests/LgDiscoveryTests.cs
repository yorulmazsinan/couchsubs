// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Net.Sockets;
using System.Text;
using CouchSubs.Core.LgTv;
using Tv = CouchSubs.Core.LgTv.LgTv;

namespace CouchSubs.Core.Tests;

public class LgDiscoveryTests
{
    /// Elle yazılan adresteki TV'nin türü: Android TV artık LG sayılmıyor (Mac'teki ManualTVTests ile aynı vakalar).
    [Fact]
    public void ManualAddressIsClassifiedByWhatTheTvAnswers()
    {
        const string host = "192.168.1.60";
        Assert.Equal(new ManualTv(new Tv("Samsung Q80", host, TvBrand.Samsung), true),
            LgDiscovery.ClassifyManual(host, "Samsung Q80", null, false, true));
        // Yeni LG'lerde Google Cast portu da açık olabilir: LG yanıt verdiyse LG'dir.
        Assert.Equal(new ManualTv(new Tv("LG OLED", host), true), LgDiscovery.ClassifyManual(host, null, "LG OLED", false, true));
        Assert.Equal(new ManualTv(new Tv("LG TV", host), true), LgDiscovery.ClassifyManual(host, null, null, true, true));
        Assert.Equal(new ManualTv(new Tv("Android TV", host, TvBrand.AndroidTv), true), LgDiscovery.ClassifyManual(host, null, null, false, true));
        // Hiçbir yoklamaya yanıt yok (ör. webOS 3): eskisi gibi LG sayılır ama tanınmadığı bilinir.
        Assert.Equal(new ManualTv(new Tv("LG TV", host), false), LgDiscovery.ClassifyManual(host, null, null, false, false));
        Assert.Equal(new[] { 5555, 6466, 8008, 8009 }, LgDiscovery.AndroidPorts.Order());
    }

    /// 1990'da ad veren her cihaz LG değildir: yalnız LG/webOS cihaz tanımı LG adı verir (X, Toshiba Android TV, Windows:
    /// elle yazılan adres LG diye ekleniyordu). 3000'de de yalnız webOS'un "Hello world" yanıtı sayılır.
    [Fact]
    public void ManualLgEvidenceMustComeFromWebOs()
    {
        Assert.Equal("[LG] webOS TV UK7550",
            LgDiscovery.LgNameIn("<root><device><friendlyName> [LG] webOS TV UK7550 </friendlyName><manufacturer>LG Electronics</manufacturer></device></root>"));
        Assert.Equal("LG TV", LgDiscovery.LgNameIn("<root><device><modelName>webOS TV</modelName></device></root>"));
        Assert.Null(LgDiscovery.LgNameIn("<root><device><friendlyName>Toshiba TV</friendlyName><manufacturer>Vestel</manufacturer></device></root>"));
        Assert.Null(LgDiscovery.LgNameIn(null));
        Assert.False(LgDiscovery.IsSsapGreeting(null));
        Assert.False(LgDiscovery.IsSsapGreeting("<html>Node</html>"));
        Assert.Equal(new ManualTv(new Tv("Android TV", "192.168.1.133", TvBrand.AndroidTv), true),
            LgDiscovery.ClassifyManual("192.168.1.133", null, LgDiscovery.LgNameIn("<device><friendlyName>Toshiba</friendlyName></device>"),
                LgDiscovery.IsSsapGreeting("<html></html>"), true));
    }

    private const string TvResponse =
        "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.153:1990/abc/description.xml\r\nST: urn:lge-com:service:webos-second-screen:1\r\n\r\n";

    private static UdpReceiveResult Reply(string text) =>
        new(Encoding.ASCII.GetBytes(text), new IPEndPoint(IPAddress.Parse("192.168.1.153"), 1900));

    /// <summary>Sırayla verilen yanıtları ya da hataları döner; bitince süre dolmuş gibi iptal eder.</summary>
    private static Func<CancellationToken, ValueTask<UdpReceiveResult>> Script(params object[] steps)
    {
        var queue = new Queue<object>(steps);
        return token =>
        {
            if (queue.Count == 0) throw new OperationCanceledException(token);
            return queue.Dequeue() switch
            {
                Exception error => throw error,
                string text => ValueTask.FromResult(Reply(text)),
                _ => throw new InvalidOperationException(),
            };
        };
    }

    // Windows'ta portu kapalı bir adresten gelen ICMP yanıtı sonraki okumada 10054 olarak gelir; uygulama çöküyordu (#556).
    [Fact]
    public async Task ConnectionResetDuringSearchIsSkippedAndSearchContinues()
    {
        var hosts = await LgDiscovery.ReceiveHosts(
            Script(new SocketException((int)SocketError.ConnectionReset), new SocketException((int)SocketError.ConnectionReset), TvResponse),
            LgDiscovery.SearchTarget, CancellationToken.None);
        Assert.Equal(["192.168.1.153"], hosts);
    }

    [Fact]
    public async Task OtherSocketErrorEndsSearchWithHostsFoundSoFar()
    {
        var hosts = await LgDiscovery.ReceiveHosts(
            Script(TvResponse, new SocketException((int)SocketError.NetworkDown), TvResponse),
            LgDiscovery.SearchTarget, CancellationToken.None);
        Assert.Equal(["192.168.1.153"], hosts);
    }

    [Fact]
    public async Task DeadlineEndsSearchWithoutError()
    {
        var hosts = await LgDiscovery.ReceiveHosts(Script(), LgDiscovery.SearchTarget, CancellationToken.None);
        Assert.Empty(hosts);
    }
}
