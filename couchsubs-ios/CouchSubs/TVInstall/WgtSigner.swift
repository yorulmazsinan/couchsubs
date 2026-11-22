// SPDX-License-Identifier: AGPL-3.0-only
// İmza biçimi TizenSdb.Core'un TizenResigner'ından (MIT, Patrick Stel) taşındı: https://github.com/PatrickSt1991/tizen-sdb
// Android'deki WgtSigner.kt'nin Swift karşılığı.

import CryptoKit
import Foundation

/// Sıkıştırmasız (stored) zip: uygulamayla gelen imzasız paket böyle üretilir, imzalı paket de böyle yazılır.
enum StoredZip {
    struct Entry {
        let name: String
        let data: [UInt8]
    }

    struct Unsupported: Error, CustomStringConvertible {
        let description: String
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
    private static func readLE16(_ bytes: [UInt8], _ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }

    /// Merkez dizinden dosyaları okur; yalnız sıkıştırmasız kayıtlar desteklenir.
    static func read(_ zip: [UInt8]) throws -> [Entry] {
        guard zip.count >= 22 else { throw Unsupported(description: "zip çok kısa") }
        var end = zip.count - 22
        while end >= 0, readLE32(zip, end) != 0x0605_4B50 { end -= 1 }
        guard end >= 0 else { throw Unsupported(description: "zip sonu bulunamadı") }
        let count = readLE16(zip, end + 10)
        var offset = Int(readLE32(zip, end + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= zip.count, readLE32(zip, offset) == 0x0201_4B50 else { throw Unsupported(description: "zip dizini bozuk") }
            let method = readLE16(zip, offset + 10)
            let size = Int(readLE32(zip, offset + 20))
            let nameLength = readLE16(zip, offset + 28), extraLength = readLE16(zip, offset + 30), commentLength = readLE16(zip, offset + 32)
            let local = Int(readLE32(zip, offset + 42))
            let name = String(decoding: zip[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength
            guard method == 0 else { throw Unsupported(description: "\(name): sıkıştırılmış kayıt") }
            let localName = readLE16(zip, local + 26), localExtra = readLE16(zip, local + 28)
            let start = local + 30 + localName + localExtra
            guard start + size <= zip.count else { throw Unsupported(description: "\(name): kayıt bozuk") }
            entries.append(Entry(name: name, data: Array(zip[start..<start + size])))
        }
        return entries
    }

    static func write(_ entries: [Entry]) -> [UInt8] {
        var out: [UInt8] = []
        var directory: [UInt8] = []
        for entry in entries {
            let name = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = out.count
            // Sürüm 20, bayrak 0x0800 (UTF-8 ad), yöntem 0, tarih 1980-01-01.
            let common = le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21) + le32(crc) + le32(UInt32(entry.data.count))
                + le32(UInt32(entry.data.count)) + le16(name.count) + le16(0)
            out += le32(0x0403_4B50) + common + name + entry.data
            directory += le32(0x0201_4B50) + le16(20) + common + le16(0) + le16(0) + le16(0) + le32(0) + le32(UInt32(offset)) + name
        }
        let start = out.count
        out += directory
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
            + le32(UInt32(directory.count)) + le32(UInt32(start)) + le16(0)
        return out
    }
}

/// Tizen web uygulaması paketini (.wgt) imzalar: `author-signature.xml` ve `signature1.xml` (W3C Widget Signature).
/// Özet ve imza `Digest` ile seçilir: SHA-512 (bugünkü Tizen Studio ve TizenSdb gibi; #71'de Tizen 2.4'te de çalıştı),
/// Tizen 2.x TV'lerde (2016) ikinci denemedeki yalın pakette SHA-256 (#638, #890). Kanonik biçimler doğrudan üretilir (Android'deki WgtSigner ile aynı metin).
enum WgtSigner {
    private static let dsig = "http://www.w3.org/2000/09/xmldsig#"
    private static let dsp = "http://www.w3.org/2009/xmldsig-properties"
    private static let excC14n = "http://www.w3.org/2001/10/xml-exc-c14n#"
    private static let c14n11 = "http://www.w3.org/2006/12/xml-c14n11"

    /// İmzadaki özet ve imza algoritması.
    enum Digest {
        /// W3C Widget Signature'ın zorunlu tuttuğu, Tizen 2.x SDK'sının ürettiği biçim; Tizen 2.x'te yalnız yalın pakette.
        case sha256
        /// Bugünkü Tizen Studio'nun ve TizenSdb'nin ürettiği biçim (her TV; Tizen 2.x'te ilk deneme, #890).
        case sha512

        var signatureMethod: String {
            self == .sha256 ? "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256" : "http://www.w3.org/2001/04/xmldsig-more#rsa-sha512"
        }

        var digestMethod: String {
            self == .sha256 ? "http://www.w3.org/2001/04/xmlenc#sha256" : "http://www.w3.org/2001/04/xmlenc#sha512"
        }

        var algorithm: SecKeyAlgorithm {
            self == .sha256 ? .rsaSignatureMessagePKCS1v15SHA256 : .rsaSignatureMessagePKCS1v15SHA512
        }
    }

    struct Signer {
        let key: RsaKey
        /// Yaprak önce, kök yok.
        let chain: [TVCertificate]
    }

    static func sign(_ wgt: [UInt8], author: Signer, distributor: Signer, digest: Digest = .sha512) throws -> [UInt8] {
        let files = try StoredZip.read(wgt).filter { entry in
            let lower = entry.name.lowercased()
            return !entry.name.hasSuffix("/") && !lower.hasSuffix("author-signature.xml") && !lower.hasSuffix("signature1.xml")
        }
        let authorSignature = StoredZip.Entry(name: "author-signature.xml", data: try signature("AuthorSignature", files, author, digest))
        let distributorSignature = StoredZip.Entry(name: "signature1.xml", data: try signature("DistributorSignature", [authorSignature] + files, distributor, digest))
        return StoredZip.write([authorSignature, distributorSignature] + files)
    }

    static func signature(_ id: String, _ files: [StoredZip.Entry], _ signer: Signer, _ digest: Digest = .sha512) throws -> [UInt8] {
        let info = signedInfo(files, propDigest: self.digest(Array(propObject(id, canonical: true).utf8), digest), digest)
        let value = try signer.key.sign(digest.algorithm, Data(canonicalSignedInfo(info).utf8))
        var xml = "<Signature xmlns=\"\(dsig)\" Id=\"\(attr(id))\">"
        xml += info
        xml += "<SignatureValue>\(value.base64EncodedString())</SignatureValue>"
        xml += "<KeyInfo><X509Data>"
        for certificate in signer.chain {
            xml += "<X509Certificate>\n" + wrap76(certificate.der.base64EncodedString()) + "\n</X509Certificate>"
        }
        xml += "</X509Data></KeyInfo>"
        xml += propObject(id, canonical: false)
        xml += "</Signature>"
        return Array(xml.utf8)
    }

    static func signedInfo(_ files: [StoredZip.Entry], propDigest: String, _ digest: Digest = .sha512) -> String {
        var xml = "<SignedInfo>"
        xml += "<CanonicalizationMethod Algorithm=\"\(excC14n)\"></CanonicalizationMethod>"
        xml += "<SignatureMethod Algorithm=\"\(digest.signatureMethod)\"></SignatureMethod>"
        for file in files {
            xml += "<Reference URI=\"\(attr(file.name))\">"
            xml += "<DigestMethod Algorithm=\"\(digest.digestMethod)\"></DigestMethod>"
            xml += "<DigestValue>\(self.digest(file.data, digest))</DigestValue></Reference>"
        }
        xml += "<Reference URI=\"#prop\"><Transforms><Transform Algorithm=\"\(c14n11)\"></Transform></Transforms>"
        xml += "<DigestMethod Algorithm=\"\(digest.digestMethod)\"></DigestMethod><DigestValue>\(propDigest)</DigestValue></Reference>"
        xml += "</SignedInfo>"
        return xml
    }

    static func canonicalSignedInfo(_ signedInfo: String) -> String {
        "<SignedInfo xmlns=\"\(dsig)\">" + signedInfo.dropFirst("<SignedInfo>".count)
    }

    static func propObject(_ id: String, canonical: Bool) -> String {
        let role = id == "AuthorSignature" ? "author" : "distributor"
        let target = attr("#\(id)")
        func property(_ name: String, _ child: String, _ uri: String?) -> String {
            let uriText = uri.map { " URI=\"\(attr($0))\"" } ?? ""
            return "<SignatureProperty Id=\"\(name)\" Target=\"\(target)\"><dsp:\(child)\(uriText)></dsp:\(child)></SignatureProperty>"
        }
        return (canonical ? "<Object xmlns=\"\(dsig)\" Id=\"prop\">" : "<Object Id=\"prop\">")
            + "<SignatureProperties xmlns:dsp=\"\(dsp)\">"
            + property("profile", "Profile", "http://www.w3.org/ns/widgets-digsig#profile")
            + property("role", "Role", "http://www.w3.org/ns/widgets-digsig#role-\(role)")
            + property("identifier", "Identifier", nil)
            + "</SignatureProperties></Object>"
    }

    static func digest(_ data: [UInt8], _ digest: Digest = .sha512) -> String {
        digest == .sha256 ? Data(SHA256.hash(data: data)).base64EncodedString() : Data(SHA512.hash(data: data)).base64EncodedString()
    }

    static func attr(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case "\"": out += "&quot;"
            case "\t": out += "&#x9;"
            case "\n": out += "&#xA;"
            case "\r": out += "&#xD;"
            default: out.append(character)
            }
        }
        return out
    }

    private static func wrap76(_ text: String) -> String {
        var lines: [Substring] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            lines.append(rest.prefix(76))
            rest = rest.dropFirst(76)
        }
        return lines.joined(separator: "\n")
    }
}
