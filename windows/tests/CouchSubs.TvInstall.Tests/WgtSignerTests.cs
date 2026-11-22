// SPDX-License-Identifier: AGPL-3.0-only

using System.IO.Compression;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Cryptography.Xml;
using System.Text;
using System.Xml;
using CouchSubs.TvInstall.Samsung;
using TizenSdb.SigningManager;

namespace CouchSubs.TvInstall.Tests;

/// <summary>
/// Tizen 2.x TV'ler (2016) için SHA-256 imza (#638). Bilinen girdinin özetleri Android'deki WgtSignerTest ve iPhone'daki
/// WgtSignerTests ile aynıdır; imza .NET'in kendi XML kanonikleştiricisiyle bağımsız doğrulanır, SHA-512 çıktısı da
/// gerçek TV'lerde çalışan TizenSdb imzasıyla karşılaştırılır.
/// </summary>
public class WgtSignerTests
{
    private const string Dsig = "http://www.w3.org/2000/09/xmldsig#";

    private static readonly (string Name, string Text)[] Files = [("config.xml", "<widget/>"), ("index.html", "<p>merhaba</p>")];

    private static List<WgtSigner.Entry> Entries() =>
        Files.Select(file => new WgtSigner.Entry(file.Name, Encoding.UTF8.GetBytes(file.Text))).ToList();

    [Fact]
    public void KnownInputGivesKnownSha256Digests()
    {
        Assert.Equal("EY7MvyaBrTJqCTlmhv1sr4UMN5v2uF5KXyQLW3VbiAA=", WgtSigner.Digest("<widget/>"u8.ToArray(), WgtDigest.Sha256));
        Assert.Equal("6KF08mjdP2RJgT9dsGq+QSvYwK9Gf1evjAdB8iPWFUM=", WgtSigner.Digest("<p>merhaba</p>"u8.ToArray(), WgtDigest.Sha256));
        Assert.Equal("lpo8tUDs054eLlBQXiDPVDVKfw30ZZdtkRs1jd7H5K8=", PropDigest("AuthorSignature", WgtDigest.Sha256));
        Assert.Equal("u/jU3U4Zm5ihTMSjKGlGYbWzDfRkGphPPHx3gJIYEJ4=", PropDigest("DistributorSignature", WgtDigest.Sha256));
        Assert.Equal("fd26f785814408973737073c499f19c6fce194dad6ec3f3cf3205a640ff5d975", SignedInfoHash(WgtDigest.Sha256));
    }

    [Fact]
    public void KnownInputGivesKnownSha512Digests()
    {
        Assert.Equal("hSUufNpfpXKCyTwglfu2Zrqtt8W2nXG1K6Vfy7fwYUMDL5lpBwC0EgpxeKlzb9I40BrzBklgo31V7Pl1ZqoOTQ==",
            WgtSigner.Digest("<widget/>"u8.ToArray(), WgtDigest.Sha512));
        Assert.Equal("aXbSAVgmAz0GsBUeZ1UmNDRrxkWhDUVGb45dZcNRq429wX3X+x6kaXT3NdNDTSNVTU+ypkysPMGvQY10fG1EWQ==",
            PropDigest("AuthorSignature", WgtDigest.Sha512));
        Assert.Equal("844e74e1b6dd5518e71f58ee694827115d657d623d35bb6711216ac8c74c6e27", SignedInfoHash(WgtDigest.Sha512));
    }

    [Fact]
    public void SignedInfoNamesTheChosenAlgorithms()
    {
        var sha256 = WgtSigner.SignedInfo(Entries(), "x", WgtDigest.Sha256);
        Assert.Contains("<SignatureMethod Algorithm=\"http://www.w3.org/2001/04/xmldsig-more#rsa-sha256\">", sha256);
        Assert.Contains("<DigestMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#sha256\">", sha256);
        Assert.DoesNotContain("sha512", sha256);
        Assert.Contains("<CanonicalizationMethod Algorithm=\"http://www.w3.org/2001/10/xml-exc-c14n#\">", sha256);
        var sha512 = WgtSigner.SignedInfo(Entries(), "x", WgtDigest.Sha512);
        Assert.Contains("xmldsig-more#rsa-sha512", sha512);
        Assert.Contains("xmlenc#sha512", sha512);
        Assert.DoesNotContain("sha256", sha512);
    }

    /// <summary>İmza ve bütün özetler, bu sınıfın yazdığı metne güvenmeden doğrulanır.</summary>
    [Fact]
    public void Sha256SignatureIsValidAndCoversEveryFile()
    {
        using var profile = new Profile();
        var wgt = profile.Wgt();
        WgtSigner.SignInPlace(wgt, profile.Author, profile.Distributor, Profile.Password, WgtDigest.Sha256);

        using var zip = ZipFile.OpenRead(wgt);
        Assert.Equal(new[] { "author-signature.xml", "signature1.xml", "config.xml", "index.html" }, zip.Entries.Select(e => e.FullName));
        var content = zip.Entries.ToDictionary(e => e.FullName, Read);
        Assert.StartsWith($"<Signature xmlns=\"{Dsig}\" Id=\"AuthorSignature\">", Encoding.UTF8.GetString(content["author-signature.xml"]));

        Assert.Equal(["config.xml", "index.html", "#prop"], Validate(content, "author-signature.xml", "AuthorSignature", profile.Key));
        Assert.Equal(["author-signature.xml", "config.xml", "index.html", "#prop"],
            Validate(content, "signature1.xml", "DistributorSignature", profile.Key));
    }

    /// <summary>
    /// SHA-512 seçilince yazar imzası, gerçek TV'lerde (Tizen 5.0 ve üstü) çalışan TizenSdb imzasıyla bayt bayt aynıdır:
    /// aynı SignedInfo ve aynı kanonik biçim. SHA-256 çıktısının farkı yalnız algoritmadır.
    /// </summary>
    [Fact]
    public async Task Sha512SignatureEqualsTizenSdbs()
    {
        using var profile = new Profile();
        var ours = profile.Wgt();
        var theirs = profile.Wgt();
        WgtSigner.SignInPlace(ours, profile.Author, profile.Distributor, Profile.Password, WgtDigest.Sha512);
        await TizenWgtSigner.ReSignWgtWithCertsInPlace(theirs, profile.Author, profile.Distributor, Profile.Password);

        var mine = Parse(ReadEntry(ours, "author-signature.xml"));
        var reference = Parse(ReadEntry(theirs, "author-signature.xml"));
        Assert.Equal(Text(reference, "SignatureValue"), Text(mine, "SignatureValue"));
        Assert.Equal(Texts(reference, "DigestValue"), Texts(mine, "DigestValue"));
        Assert.Equal(Texts(reference, "X509Certificate"), Texts(mine, "X509Certificate"));
    }

    /// <summary>
    /// Tizen 2.x'teki ilk deneme (#890): #71'de 40KU7000'e kurulan paket Apps2Samsung'un TizenSdb'siyle SHA-512 imzalıydı;
    /// Windows/Mac bu paketi aynı TizenSdb'yle, telefonlar WgtSigner'ın SHA-512'siyle imzalar. İki paket de bağımsız
    /// doğrulanır (imza, her dosyanın SHA-512 özeti, referans sırası); dosya listesi ve sırası, her dosyanın sıkıştırma
    /// yöntemi (deflate) ve paket dosyalarının dağıtıcı özetleri aynıdır. Yazar imzası dosyasının baytları farklı yazılır
    /// (TizenSdb boş öğeleri kısa kapatır), kanonik biçimi ve imza değeri aynıdır (Sha512SignatureEqualsTizenSdbs).
    /// </summary>
    [Fact]
    public async Task LegacySha512PackageMatchesTheIssue71Signer()
    {
        using var profile = new Profile();
        var ours = profile.Wgt();
        var theirs = profile.Wgt();
        WgtSigner.SignInPlace(ours, profile.Author, profile.Distributor, Profile.Password, WgtDigest.Sha512);
        await TizenWgtSigner.ReSignWgtWithCertsInPlace(theirs, profile.Author, profile.Distributor, Profile.Password);

        foreach (var wgt in new[] { ours, theirs })
        {
            using var zip = ZipFile.OpenRead(wgt);
            var content = zip.Entries.ToDictionary(e => e.FullName, Read);
            Assert.Equal(["config.xml", "index.html", "#prop"],
                Validate(content, "author-signature.xml", "AuthorSignature", profile.Key, WgtDigest.Sha512));
            Assert.Equal(["author-signature.xml", "config.xml", "index.html", "#prop"],
                Validate(content, "signature1.xml", "DistributorSignature", profile.Key, WgtDigest.Sha512));
        }
        Assert.Equal(Methods(theirs), Methods(ours));
        Assert.Equal(["author-signature.xml", "signature1.xml", "config.xml", "index.html"], Methods(ours).Select(e => e.Name));
        Assert.All(Methods(ours), entry => Assert.Equal(8, entry.Method));
        var mine = Texts(Parse(ReadEntry(ours, "signature1.xml")), "DigestValue");
        var reference = Texts(Parse(ReadEntry(theirs, "signature1.xml")), "DigestValue");
        Assert.Equal(reference.Skip(1), mine.Skip(1));
    }

    /// <summary>Zip'in merkezi dizinindeki her girdi: ad ve sıkıştırma yöntemi (0 stored, 8 deflate), dosyadaki sırayla.</summary>
    private static List<(string Name, int Method)> Methods(string wgt)
    {
        var bytes = File.ReadAllBytes(wgt);
        var entries = new List<(string, int)>();
        for (var i = 0; i + 46 <= bytes.Length; i++)
        {
            if (BitConverter.ToUInt32(bytes, i) != 0x02014b50) continue;
            var method = BitConverter.ToUInt16(bytes, i + 10);
            var nameLength = BitConverter.ToUInt16(bytes, i + 28);
            entries.Add((Encoding.UTF8.GetString(bytes, i + 46, nameLength), method));
            i += 45 + nameLength;
        }
        return entries;
    }

    private static string PropDigest(string id, WgtDigest digest) =>
        WgtSigner.Digest(Encoding.UTF8.GetBytes(WgtSigner.PropObject(id, canonical: true)), digest);

    private static string SignedInfoHash(WgtDigest digest)
    {
        var info = WgtSigner.SignedInfo(Entries(), PropDigest("AuthorSignature", digest), digest);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(WgtSigner.CanonicalSignedInfo(info))));
    }

    /// <summary>Bir imza dosyasını doğrular; referansların URI'lerini sırasıyla döner.</summary>
    private static List<string> Validate(Dictionary<string, byte[]> content, string file, string id, RSA key,
        WgtDigest digest = WgtDigest.Sha256)
    {
        var text = Encoding.UTF8.GetString(content[file]);
        var document = Parse(content[file]);
        Assert.Equal(Dsig, document.DocumentElement!.NamespaceURI);
        Assert.Equal(id, document.DocumentElement.GetAttribute("Id"));
        var names = new XmlNamespaceManager(document.NameTable);
        names.AddNamespace("ds", Dsig);
        Assert.Equal(WgtSigner.SignatureMethod(digest),
            document.SelectSingleNode("//ds:SignatureMethod/@Algorithm", names)!.Value);

        var signedInfo = Canonical(document.SelectSingleNode("//ds:SignedInfo", names)!, new XmlDsigExcC14NTransform());
        var signature = Convert.FromBase64String(Text(document, "SignatureValue"));
        Assert.True(key.VerifyData(signedInfo, signature,
            digest == WgtDigest.Sha256 ? HashAlgorithmName.SHA256 : HashAlgorithmName.SHA512, RSASignaturePadding.Pkcs1), "imza doğrulanmalı");

        var uris = new List<string>();
        foreach (XmlElement reference in document.SelectNodes("//ds:Reference", names)!)
        {
            var uri = reference.GetAttribute("URI");
            uris.Add(uri);
            Assert.Equal(WgtSigner.DigestMethod(digest), reference.SelectSingleNode("ds:DigestMethod/@Algorithm", names)!.Value);
            var data = uri == "#prop"
                ? Canonical(document.SelectSingleNode("//ds:Object[@Id='prop']", names)!, new XmlDsigC14NTransform())
                : content[uri];
            Assert.Equal(Convert.ToBase64String(digest == WgtDigest.Sha256 ? SHA256.HashData(data) : SHA512.HashData(data)), reference.SelectSingleNode("ds:DigestValue", names)!.InnerText);
        }
        // Zincir: yaprak; kendi imzaladığımız sertifikanın ara sertifikası yok, kök yazılmaz.
        Assert.Single(Texts(document, "X509Certificate"));
        Assert.Contains($"#role-{(id == "AuthorSignature" ? "author" : "distributor")}", text);
        return uris;
    }

    /// <summary>Düğümü, üst öğeden gelen ad alanlarıyla birlikte kanonikleştirir (TV'nin yaptığı gibi).</summary>
    private static byte[] Canonical(XmlNode node, Transform transform)
    {
        var copy = new XmlDocument { PreserveWhitespace = true };
        copy.AppendChild(copy.ImportNode(node, deep: true));
        transform.LoadInput(copy);
        using var stream = (Stream)transform.GetOutput(typeof(Stream));
        using var output = new MemoryStream();
        stream.CopyTo(output);
        return output.ToArray();
    }

    private static XmlDocument Parse(byte[] xml)
    {
        var document = new XmlDocument { PreserveWhitespace = true };
        document.LoadXml(Encoding.UTF8.GetString(xml));
        return document;
    }

    private static string Text(XmlDocument document, string name) => Texts(document, name).Single();

    private static List<string> Texts(XmlDocument document, string name) =>
        document.GetElementsByTagName(name, Dsig).Cast<XmlNode>().Select(node => node.InnerText.Trim()).ToList();

    private static byte[] Read(ZipArchiveEntry entry)
    {
        using var stream = entry.Open();
        using var output = new MemoryStream();
        stream.CopyTo(output);
        return output.ToArray();
    }

    private static byte[] ReadEntry(string wgt, string name)
    {
        using var zip = ZipFile.OpenRead(wgt);
        return Read(zip.GetEntry(name)!);
    }

    /// <summary>Kendi imzaladığımız sahte yazar ve dağıtıcı sertifikaları (aynı anahtar, Samsung'un verdiği gibi).</summary>
    private sealed class Profile : IDisposable
    {
        public const string Password = "parola";
        private readonly string directory = Directory.CreateTempSubdirectory().FullName;

        public RSA Key { get; } = RSA.Create(2048);
        public string Author => Path.Combine(directory, "author.p12");
        public string Distributor => Path.Combine(directory, "distributor.p12");

        public Profile()
        {
            File.WriteAllBytes(Author, SamsungCertificates.Pkcs12(SelfSigned("CN=Yazar"), Key, Password));
            File.WriteAllBytes(Distributor, SamsungCertificates.Pkcs12(SelfSigned("CN=Dagitici"), Key, Password));
        }

        private X509Certificate2 SelfSigned(string subject)
        {
            var request = new CertificateRequest(subject, Key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            using var withKey = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(1));
            return X509CertificateLoader.LoadCertificate(withKey.RawData);
        }

        public string Wgt()
        {
            var path = Path.Combine(directory, $"{Guid.NewGuid():N}.wgt");
            using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
            foreach (var (name, text) in Files)
            {
                using var entry = zip.CreateEntry(name).Open();
                entry.Write(Encoding.UTF8.GetBytes(text));
            }
            return path;
        }

        public void Dispose()
        {
            Key.Dispose();
            Directory.Delete(directory, recursive: true);
        }
    }
}
