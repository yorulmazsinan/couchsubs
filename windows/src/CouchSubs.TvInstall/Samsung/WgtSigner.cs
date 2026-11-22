// SPDX-License-Identifier: AGPL-3.0-only
// İmza biçimi TizenSdb.Core'un TizenResigner'ından (MIT, Patrick Stel): https://github.com/PatrickSt1991/tizen-sdb
// Android'deki WgtSigner.kt ve iPhone'daki WgtSigner.swift ile aynı metni üretir.

using System.IO.Compression;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace CouchSubs.TvInstall.Samsung;

/// <summary>İmzadaki özet ve imza algoritması.</summary>
internal enum WgtDigest
{
    /// <summary>
    /// rsa-sha256 + sha256: W3C Widget Signature'ın zorunlu tuttuğu, Tizen 2.x SDK'sının ürettiği biçim. Tizen 2.x
    /// TV'lerde (2016) yalnız ikinci denemedeki yalın pakette kullanılır (#638, #890).
    /// </summary>
    Sha256,
    /// <summary>
    /// rsa-sha512 + sha512: bugünkü Tizen Studio'nun ve TizenSdb'nin ürettiği biçim. #71'de 40KU7000'e (Tizen 2.4) kurulan
    /// paket de Apps2Samsung'un TizenSdb'siyle böyle imzalanmıştı; Tizen 2.x'te ilk deneme bununla yapılır (#890; Windows/Mac
    /// o denemede de TizenSdb'yi kullanır, telefonlar bu biçimi).
    /// </summary>
    Sha512,
}

/// <summary>
/// Tizen web uygulaması paketini (.wgt) imzalar: <c>author-signature.xml</c> ve <c>signature1.xml</c> (W3C Widget
/// Signature). Tizen 3.0 ve üstünde imzayı TizenSdb atar (SHA-512, sabit); bu sınıf özet algoritması seçilebilsin diye
/// vardır ve yalnız Tizen 2.x TV'lerde kullanılır. Kanonik biçimler doğrudan üretilir (telefonlardaki imzalayıcıyla aynı).
/// </summary>
internal static class WgtSigner
{
    private const string Dsig = "http://www.w3.org/2000/09/xmldsig#";
    private const string Dsp = "http://www.w3.org/2009/xmldsig-properties";
    private const string ExcC14n = "http://www.w3.org/2001/10/xml-exc-c14n#";
    private const string C14n11 = "http://www.w3.org/2006/12/xml-c14n11";

    internal sealed record Entry(string Name, byte[] Data);

    /// <summary>İmza için anahtar ve sertifika zinciri (yaprak önce, kök yok).</summary>
    internal sealed record Signer(RSA Key, IReadOnlyList<byte[]> Chain);

    internal static string SignatureMethod(WgtDigest digest) => digest == WgtDigest.Sha256
        ? "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
        : "http://www.w3.org/2001/04/xmldsig-more#rsa-sha512";

    internal static string DigestMethod(WgtDigest digest) => digest == WgtDigest.Sha256
        ? "http://www.w3.org/2001/04/xmlenc#sha256"
        : "http://www.w3.org/2001/04/xmlenc#sha512";

    /// <summary>Paketi yerinde yeniden imzalar; eski imza dosyaları atılır, diğer dosyaların sırası korunur.</summary>
    public static void SignInPlace(string wgtPath, string authorP12, string distributorP12, string password, WgtDigest digest)
    {
        using var author = Load(authorP12, password);
        using var distributor = Load(distributorP12, password);
        File.WriteAllBytes(wgtPath, Sign(File.ReadAllBytes(wgtPath), author.Signer, distributor.Signer, digest));
    }

    internal static byte[] Sign(byte[] wgt, Signer author, Signer distributor, WgtDigest digest)
    {
        var files = ReadEntries(wgt);
        var authorSignature = new Entry("author-signature.xml", Signature("AuthorSignature", files, author, digest));
        var distributorSignature = new Entry("signature1.xml",
            Signature("DistributorSignature", [authorSignature, .. files], distributor, digest));
        using var output = new MemoryStream();
        using (var zip = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var entry in (Entry[])[authorSignature, distributorSignature, .. files])
            {
                using var stream = zip.CreateEntry(entry.Name, CompressionLevel.Optimal).Open();
                stream.Write(entry.Data);
            }
        }
        return output.ToArray();
    }

    internal static List<Entry> ReadEntries(byte[] wgt)
    {
        var files = new List<Entry>();
        using var zip = new ZipArchive(new MemoryStream(wgt, writable: false), ZipArchiveMode.Read);
        foreach (var entry in zip.Entries)
        {
            var name = entry.FullName;
            var lower = name.ToLowerInvariant();
            if (name.EndsWith('/') || lower.EndsWith("author-signature.xml") || lower.EndsWith("signature1.xml")) continue;
            using var data = new MemoryStream();
            using (var stream = entry.Open()) stream.CopyTo(data);
            files.Add(new Entry(name, data.ToArray()));
        }
        return files;
    }

    /// <summary>Bir imza dosyası (<c>&lt;Signature Id="…"&gt;</c>), XML bildirimi ve girinti olmadan.</summary>
    internal static byte[] Signature(string id, IReadOnlyList<Entry> files, Signer signer, WgtDigest digest)
    {
        var signedInfo = SignedInfo(files, Digest(Encoding.UTF8.GetBytes(PropObject(id, canonical: true)), digest), digest);
        var value = signer.Key.SignData(Encoding.UTF8.GetBytes(CanonicalSignedInfo(signedInfo)),
            digest == WgtDigest.Sha256 ? HashAlgorithmName.SHA256 : HashAlgorithmName.SHA512, RSASignaturePadding.Pkcs1);
        var xml = new StringBuilder();
        xml.Append($"<Signature xmlns=\"{Dsig}\" Id=\"{Attr(id)}\">");
        xml.Append(signedInfo);
        xml.Append("<SignatureValue>").Append(Convert.ToBase64String(value)).Append("</SignatureValue>");
        xml.Append("<KeyInfo><X509Data>");
        foreach (var certificate in signer.Chain)
            xml.Append("<X509Certificate>\n").Append(Wrap76(Convert.ToBase64String(certificate))).Append("\n</X509Certificate>");
        xml.Append("</X509Data></KeyInfo>");
        xml.Append(PropObject(id, canonical: false));
        xml.Append("</Signature>");
        return Encoding.UTF8.GetBytes(xml.ToString());
    }

    /// <summary>Dosyadaki SignedInfo (ad alanı üst öğeden gelir).</summary>
    internal static string SignedInfo(IReadOnlyList<Entry> files, string propDigest, WgtDigest digest)
    {
        var method = DigestMethod(digest);
        var xml = new StringBuilder("<SignedInfo>");
        xml.Append($"<CanonicalizationMethod Algorithm=\"{ExcC14n}\"></CanonicalizationMethod>");
        xml.Append($"<SignatureMethod Algorithm=\"{SignatureMethod(digest)}\"></SignatureMethod>");
        foreach (var file in files)
        {
            xml.Append("<Reference URI=\"").Append(Attr(file.Name)).Append("\">");
            xml.Append($"<DigestMethod Algorithm=\"{method}\"></DigestMethod>");
            xml.Append("<DigestValue>").Append(Digest(file.Data, digest)).Append("</DigestValue></Reference>");
        }
        xml.Append($"<Reference URI=\"#prop\"><Transforms><Transform Algorithm=\"{C14n11}\"></Transform></Transforms>");
        xml.Append($"<DigestMethod Algorithm=\"{method}\"></DigestMethod><DigestValue>").Append(propDigest).Append("</DigestValue></Reference>");
        xml.Append("</SignedInfo>");
        return xml.ToString();
    }

    /// <summary>Exclusive C14N: kullanılan varsayılan ad alanı kök öğede yazılır.</summary>
    internal static string CanonicalSignedInfo(string signedInfo) =>
        $"<SignedInfo xmlns=\"{Dsig}\">" + signedInfo["<SignedInfo>".Length..];

    /// <summary>
    /// <c>&lt;Object Id="prop"&gt;</c>: profil, rol (author ya da distributor) ve boş tanımlayıcı. Kanonik biçimde (C14N
    /// 1.1) üst öğeden gelen varsayılan ad alanı nesnenin kendisinde yazılır.
    /// </summary>
    internal static string PropObject(string id, bool canonical)
    {
        var role = id == "AuthorSignature" ? "author" : "distributor";
        var target = Attr($"#{id}");
        string Property(string name, string child, string? uri) =>
            $"<SignatureProperty Id=\"{name}\" Target=\"{target}\"><dsp:{child}{(uri is null ? "" : $" URI=\"{Attr(uri)}\"")}></dsp:{child}></SignatureProperty>";
        return (canonical ? $"<Object xmlns=\"{Dsig}\" Id=\"prop\">" : "<Object Id=\"prop\">") +
               $"<SignatureProperties xmlns:dsp=\"{Dsp}\">" +
               Property("profile", "Profile", "http://www.w3.org/ns/widgets-digsig#profile") +
               Property("role", "Role", $"http://www.w3.org/ns/widgets-digsig#role-{role}") +
               Property("identifier", "Identifier", null) +
               "</SignatureProperties></Object>";
    }

    internal static string Digest(byte[] data, WgtDigest digest) =>
        Convert.ToBase64String(digest == WgtDigest.Sha256 ? SHA256.HashData(data) : SHA512.HashData(data));

    /// <summary>Kanonik XML'deki öznitelik kaçışları.</summary>
    internal static string Attr(string value)
    {
        var text = new StringBuilder(value.Length);
        foreach (var c in value)
        {
            text.Append(c switch
            {
                '&' => "&amp;",
                '<' => "&lt;",
                '"' => "&quot;",
                '\t' => "&#x9;",
                '\n' => "&#xA;",
                '\r' => "&#xD;",
                _ => c.ToString(),
            });
        }
        return text.ToString();
    }

    private static string Wrap76(string text) => string.Join('\n', text.Chunk(76).Select(line => new string(line)));

    /// <summary>PKCS#12'den anahtar ve zincir: yaprak (anahtarı olan) önce, sonra dosyadaki ara sertifikalar; kök yazılmaz.</summary>
    private static Loaded Load(string path, string password)
    {
        var all = X509CertificateLoader.LoadPkcs12CollectionFromFile(path, password, SigningProfile.LoadFlags);
        var leaf = all.FirstOrDefault(certificate => certificate.HasPrivateKey)
                   ?? throw new CryptographicException($"{Path.GetFileName(path)}: özel anahtar yok");
        var key = leaf.GetRSAPrivateKey() ?? throw new CryptographicException($"{Path.GetFileName(path)}: RSA anahtarı yok");
        var chain = new List<byte[]> { leaf.RawData };
        chain.AddRange(all.Where(certificate => certificate.Thumbprint != leaf.Thumbprint && certificate.Subject != certificate.Issuer)
            .Select(certificate => certificate.RawData));
        return new Loaded(new Signer(key, chain), all);
    }

    private sealed record Loaded(Signer Signer, X509Certificate2Collection All) : IDisposable
    {
        public void Dispose()
        {
            Signer.Key.Dispose();
            foreach (var certificate in All) certificate.Dispose();
        }
    }
}
