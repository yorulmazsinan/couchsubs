// SPDX-License-Identifier: AGPL-3.0-only

using System.IO.Compression;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using CouchSubs.TvInstall.Samsung;

namespace CouchSubs.TvInstall.Tests;

/// <summary>
/// 2016 Samsung TV'lerde (Tizen 2.x) config.xml #71'de çalışan pakete döner (#621); yeni TV'lerde paket değişmez.
/// Android'deki LegacyTizenPackageTest ile aynı vakalar.
/// </summary>
public class LegacyTizenPackageTests
{
    /// <summary>Depodaki gerçek config.xml.</summary>
    private static string Config([CallerFilePath] string source = "") =>
        File.ReadAllText(Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..", "tv-tizen", "config.xml"));

    private static string Wgt(string config)
    {
        var path = Path.Combine(Directory.CreateTempSubdirectory().FullName, "app.wgt");
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var (name, text) in new[] { ("config.xml", config), ("index.html", "<p>x</p>") })
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
    [InlineData("2.4.0", true)]
    [InlineData("2.4", true)]
    [InlineData("3.0", false)]
    [InlineData("4.0", false)]
    [InlineData("6.5", false)]
    [InlineData("", false)]
    public void AppliesOnlyToTizen2(string platform, bool applies) =>
        Assert.Equal(applies, LegacyTizenPackage.Applies(platform));

    [Fact]
    public void NetworkPublicAndScreenSettingAreRemovedOtherPrivilegesStay()
    {
        var config = Config();
        Assert.Contains("privilege/network.public\"", config);
        var wgt = Wgt(config);
        Assert.True(LegacyTizenPackage.Adapt(wgt));
        var adapted = Read(wgt, "config.xml");
        var withoutComments = Regex.Replace(adapted, @"<!--[\s\S]*?-->", "");
        Assert.DoesNotContain("network.public", withoutComments);
        Assert.DoesNotContain("<tizen:metadata", withoutComments);
        foreach (var kept in new[] { "tv.window", "tv.inputdevice", "application.launch", "internet", "network.get" })
            Assert.Contains($"http://tizen.org/privilege/{kept}\"", withoutComments);
        Assert.Contains("required_version=\"2.4\"", withoutComments);
        // Satır silinince XML hâlâ ayrışır; dosya başında BOM yok.
        XDocument.Parse(adapted);
        Assert.StartsWith("<?xml", adapted);
    }

    /// <summary>Yalın paket (#638): SHA-256 imzalı tam paket de yalın [118] alırsa denenir.</summary>
    [Fact]
    public void LeanPackageAlsoDropsProfileAndTwoPrivileges()
    {
        var wgt = Wgt(Config());
        Assert.True(LegacyTizenPackage.Adapt(wgt, lean: true));
        var adapted = Read(wgt, "config.xml");
        var withoutComments = Regex.Replace(adapted, @"<!--[\s\S]*?-->", "");
        foreach (var removed in new[] { "network.public", "<tizen:metadata", "<tizen:profile", "application.launch", "network.get" })
            Assert.DoesNotContain(removed, withoutComments);
        foreach (var kept in new[] { "tv.window", "tv.inputdevice", "internet" })
            Assert.Contains($"http://tizen.org/privilege/{kept}\"", withoutComments);
        Assert.Contains("required_version=\"2.4\"", withoutComments);
        Assert.Contains("<tizen:application id=\"CouchSubsT.CouchSubs\" package=\"CouchSubsT\"", withoutComments);
        XDocument.Parse(adapted);
    }

    /// <summary>
    /// Tizen 2.x'e giden config.xml, #71'de 40KU7000'de çalışan paketinkiyle (testdata/tizen/config-71.xml) öğe öğe ve
    /// öznitelik öznitelik aynıdır; yalnız widget sürümü farklıdır. Android'deki LegacyTizenPackageTest ile aynı vaka.
    /// </summary>
    [Fact]
    public void AdaptedConfigMatchesTheIssue71Config()
    {
        var wgt = Wgt(Config());
        LegacyTizenPackage.Adapt(wgt);
        var ours = Shape(Read(wgt, "config.xml"));
        var working = Shape(Issue71Config());
        Assert.Equal(working, ours);
    }

    private static string Issue71Config([CallerFilePath] string source = "") =>
        File.ReadAllText(Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..", "testdata", "tizen", "config-71.xml"));

    /// <summary>config.xml'in öğeleri sırasıyla: ad, öznitelikler (widget sürümü hariç) ve metin; açıklamalar yok.</summary>
    private static List<string> Shape(string config) =>
        XDocument.Parse(config).Root!.DescendantsAndSelf().Select(element =>
            element.Name + " " + string.Join(" ", element.Attributes()
                .Where(a => !(element == element.Document!.Root && a.Name == "version"))
                .Select(a => $"{a.Name}={a.Value}").Order(StringComparer.Ordinal)) +
            (element.HasElements ? "" : " :" + element.Value.Trim())).ToList();

    [Fact]
    public void OtherFilesStayTheSame()
    {
        var wgt = Wgt(Config());
        LegacyTizenPackage.Adapt(wgt);
        using (var zip = ZipFile.OpenRead(wgt))
            Assert.Equal(new[] { "config.xml", "index.html" }, zip.Entries.Select(e => e.FullName));
        Assert.Equal("<p>x</p>", Read(wgt, "index.html"));
    }

    [Fact]
    public void PackageWithoutThoseLinesIsUnchanged()
    {
        var wgt = Wgt("<widget><tizen:privilege name=\"http://tizen.org/privilege/internet\"/></widget>");
        var before = File.ReadAllBytes(wgt);
        Assert.False(LegacyTizenPackage.Adapt(wgt));
        Assert.Equal(before, File.ReadAllBytes(wgt));
    }
}
