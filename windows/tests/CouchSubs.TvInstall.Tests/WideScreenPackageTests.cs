// SPDX-License-Identifier: AGPL-3.0-only

using System.IO.Compression;
using System.Runtime.CompilerServices;
using System.Text;
using System.Xml.Linq;
using CouchSubs.TvInstall.Samsung;

namespace CouchSubs.TvInstall.Tests;

/// <summary>
/// 21:9 / 32:9 Samsung monitörde paket geniş uygulama yüzeyiyle kurulur (#886); TV'lerde değişmez. Android'deki
/// WideScreenPackageTest ve iPhone'daki WideScreenPackageTests ile aynı vakalar.
/// </summary>
public class WideScreenPackageTests
{
    private static string Repo([CallerFilePath] string source = "") =>
        Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..");

    private static string Wgt(string config, string page)
    {
        var path = Path.Combine(Directory.CreateTempSubdirectory().FullName, "app.wgt");
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var (name, text) in new[] { ("config.xml", config), ("index.html", page), ("app.js", "x") })
        {
            using var entry = zip.CreateEntry(name).Open();
            entry.Write(Encoding.UTF8.GetBytes(text));
        }
        return path;
    }

    private static string Read(string wgt, string name)
    {
        using var zip = ZipFile.OpenRead(wgt);
        using var reader = new StreamReader(zip.GetEntry(name)!.Open(), Encoding.UTF8);
        return reader.ReadToEnd();
    }

    [Theory]
    [InlineData("LS49CG954SUXEN", null, true)]   // Odyssey OLED G9 49" (32:9)
    [InlineData("LS34BG850SUXEN", null, true)]   // Odyssey OLED G8 34" (21:9)
    [InlineData("LS57CG952NUXEN", null, true)]   // Odyssey Neo G9 57"
    [InlineData(null, "5120x1440", true)]
    [InlineData(null, "3440x1440", true)]
    [InlineData("LS32BM801UUXEN", "3840x2160", false)] // 16:9 akıllı monitör
    [InlineData("QE75QN900A", "7680x4320", false)]
    [InlineData("QE55LS03B", "3840x2160", false)]       // The Frame
    [InlineData("UE60KU7000", "1920x1080", false)]
    [InlineData(null, null, false)]
    [InlineData("", "garbage", false)]
    public void AppliesOnlyToUltraWideMonitors(string? model, string? resolution, bool applies) =>
        Assert.Equal(applies, WideScreenPackage.Applies(model, resolution));

    [Fact]
    public void ScreenInfoIsReadFromThe8001Answer()
    {
        Assert.Equal(("LS49CG95", "5120x1440"),
            WideScreenPackage.ScreenInfo("{\"device\":{\"modelName\":\"LS49CG95\",\"resolution\":\"5120x1440\"}}"));
        Assert.Equal((null, null), WideScreenPackage.ScreenInfo("{\"device\":{\"name\":\"TV\"}}"));
        Assert.Equal((null, null), WideScreenPackage.ScreenInfo("not json"));
    }

    [Fact]
    public void RealPackageGetsWideSurfaceSettingAndViewport()
    {
        var config = File.ReadAllText(Path.Combine(Repo(), "tv-tizen", "config.xml"));
        var page = File.ReadAllText(Path.Combine(Repo(), "tv-webos", "index.html"));
        Assert.DoesNotContain("app_ui_type/base_screen_resolution\"", config);
        var wgt = Wgt(config, page);
        Assert.True(WideScreenPackage.Adapt(wgt));
        var adapted = Read(wgt, "config.xml");
        Assert.Contains(WideScreenPackage.Metadata, adapted);
        XDocument.Parse(adapted);
        Assert.StartsWith("<?xml", adapted);
        var html = Read(wgt, "index.html");
        Assert.Contains("<meta name=\"viewport\" content=\"width=device-width\">", html);
        Assert.DoesNotContain("content=\"width=1920\"", html);
        Assert.Equal("x", Read(wgt, "app.js"));
        // İkinci kez: değişen bir şey yok.
        Assert.False(WideScreenPackage.Adapt(wgt));
    }
}
