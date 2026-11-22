// SPDX-License-Identifier: AGPL-3.0-only
// Telefondan TV kurulumunun şifreleme parçaları: DER (ASN.1) yazıcı/okuyucu, RSA anahtarı (Security), X.509 tarihleri.
// Android'deki SamsungCsr.kt'nin Der'i ve java.security karşılıkları.

import CryptoKit
import CouchSubsCore
import Foundation
import Security

enum Der {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        let length = content.count
        switch length {
        case ..<0x80: out.append(UInt8(length))
        case ..<0x100: out += [0x81, UInt8(length)]
        case ..<0x10000: out += [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        default: out += [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
        return out + content
    }

    static func sequence(_ items: [UInt8]...) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [UInt8]...) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    static func integer(_ value: Int) -> [UInt8] { tlv(0x02, [UInt8(value)]) }
    /// Büyük-endian işaretsiz tam sayı (gerekirse baştaki 0 eklenir).
    static func integer(bytes: [UInt8]) -> [UInt8] {
        var value = Array(bytes.drop { $0 == 0 })
        if value.isEmpty { value = [0] }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return tlv(0x02, value)
    }
    static func utf8(_ text: String) -> [UInt8] { tlv(0x0C, Array(text.utf8)) }
    static func ia5(_ text: String, tag: UInt8 = 0x16) -> [UInt8] { tlv(tag, Array(text.utf8)) }
    static func octets(_ content: [UInt8]) -> [UInt8] { tlv(0x04, content) }
    static func bits(_ content: [UInt8]) -> [UInt8] { tlv(0x03, [0] + content) }
    static let null: [UInt8] = [0x05, 0x00]
    static func boolean(_ value: Bool) -> [UInt8] { tlv(0x01, [value ? 0xFF : 0]) }
    static func utcTime(_ date: Date) -> [UInt8] {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(format.string(from: date).utf8))
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        var out: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for part in parts.dropFirst(2) {
            var groups: [UInt8] = []
            var value = part
            repeat {
                groups.append(UInt8(value & 0x7F))
                value >>= 7
            } while value > 0
            for index in stride(from: groups.count - 1, through: 0, by: -1) { out.append(groups[index] | (index > 0 ? 0x80 : 0)) }
        }
        return tlv(0x06, out)
    }

    /// Bir DER öğesi: etiket ve içerik.
    struct Element {
        let tag: UInt8
        let content: ArraySlice<UInt8>
        /// İçerikteki öğeler (SEQUENCE, SET, açık etiketli).
        var children: [Element] { (try? Der.parse(Array(content))) ?? [] }
    }

    struct Malformed: Error {}

    /// Ardışık öğeleri okur.
    static func parse(_ bytes: [UInt8]) throws -> [Element] {
        var elements: [Element] = []
        var index = 0
        while index < bytes.count {
            guard index + 2 <= bytes.count else { throw Malformed() }
            let tag = bytes[index]
            var length = Int(bytes[index + 1])
            index += 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count > 0, count <= 4, index + count <= bytes.count else { throw Malformed() }
                length = 0
                for byte in bytes[index..<index + count] { length = length << 8 | Int(byte) }
                index += count
            }
            guard index + length <= bytes.count else { throw Malformed() }
            elements.append(Element(tag: tag, content: bytes[index..<index + length]))
            index += length
        }
        return elements
    }

    static func pem(_ der: [UInt8], label: String = "CERTIFICATE REQUEST") -> Data {
        let body = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----".utf8)
    }

    /// PEM metninden DER (PEM değilse veri olduğu gibi döner).
    static func fromPem(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") else { return data }
        let body = text.deviceLines.filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? data
    }
}

struct TVCryptoError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// 2048 bit RSA anahtarı (sdb/adb kimliği ve Samsung imza sertifikaları). Dosyada PKCS#1 DER olarak durur.
struct RsaKey {
    let privateKey: SecKey

    static func generate() throws -> RsaKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw TVCryptoError("RSA anahtarı üretilemedi: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return RsaKey(privateKey: key)
    }

    init(privateKey: SecKey) { self.privateKey = privateKey }

    init(pkcs1 data: Data) throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else {
            throw TVCryptoError("RSA anahtarı okunamadı")
        }
        privateKey = key
    }

    /// Dosyadan yükler; yoksa ya da okunamazsa yenisini üretip yazar.
    static func loadOrCreate(_ file: URL) throws -> RsaKey {
        // Dosya var ama okunamıyorsa (ör. telefon açılıştan beri kilitli) yenisi üretilmez: üzerine yazılan anahtarı TV
        // tanımaz, "hata ayıklamaya izin verilsin mi?" yeniden sorulur. Yalnız bozuk dosyanın yerine yenisi yazılır.
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            if let key = try? RsaKey(pkcs1: data) { return key }
        }
        let key = try generate()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.pkcs1().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return key
    }

    func pkcs1() throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else { throw TVCryptoError("anahtar dışa aktarılamadı") }
        return data
    }

    var publicKey: SecKey { SecKeyCopyPublicKey(privateKey)! }

    /// PKCS#1 RSAPublicKey (SEQUENCE { n, e }).
    var publicPkcs1: [UInt8] { Array((SecKeyCopyExternalRepresentation(publicKey, nil) as Data?) ?? Data()) }

    /// X.509 SubjectPublicKeyInfo.
    var subjectPublicKeyInfo: [UInt8] {
        Der.sequence(Der.sequence(Der.oid("1.2.840.113549.1.1.1"), Der.null), Der.bits(publicPkcs1))
    }

    /// Modül ve üs (büyük-endian, baştaki sıfırlar atılmış).
    var modulusAndExponent: (modulus: [UInt8], exponent: [UInt8]) {
        let parts = (try? Der.parse(publicPkcs1).first)??.children ?? []
        guard parts.count >= 2 else { return ([], []) }
        return (Array(parts[0].content.drop { $0 == 0 }), Array(parts[1].content.drop { $0 == 0 }))
    }

    func sign(_ algorithm: SecKeyAlgorithm, _ data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, data as CFData, &error) as Data? else {
            throw TVCryptoError("imzalanamadı: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return signature
    }
}

/// X.509 sertifikası: Security'nin vermediği geçerlilik tarihleri DER'den okunur.
struct TVCertificate {
    let der: Data
    let certificate: SecCertificate
    let notBefore: Date
    let notAfter: Date

    init(_ data: Data) throws {
        let der = Der.fromPem(data)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw TVCryptoError("sertifika okunamadı") }
        self.der = der
        self.certificate = certificate
        guard let root = try Der.parse(Array(der)).first, let tbs = root.children.first else { throw TVCryptoError("sertifika bozuk") }
        var fields = tbs.children
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        // serialNumber, signature, issuer, validity
        guard fields.count >= 4 else { throw TVCryptoError("sertifika bozuk") }
        let times = fields[3].children
        guard times.count == 2, let start = Self.time(times[0]), let end = Self.time(times[1]) else { throw TVCryptoError("sertifika tarihi okunamadı") }
        notBefore = start
        notAfter = end
    }

    private static func time(_ element: Der.Element) -> Date? {
        guard let text = String(bytes: element.content, encoding: .ascii) else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = element.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return format.date(from: text)
    }

    var normalizedIssuer: Data? { SecCertificateCopyNormalizedIssuerSequence(certificate) as Data? }
    var normalizedSubject: Data? { SecCertificateCopyNormalizedSubjectSequence(certificate) as Data? }
    var summary: String { (SecCertificateCopySubjectSummary(certificate) as String?) ?? "?" }
}

/// Kendinden imzalı sertifika (adb'nin TLS'i için; Android'de BouncyCastle ile üretiliyordu).
enum SelfSigned {
    static func certificate(key: RsaKey, commonName: String = "CouchSubs") throws -> Data {
        let name = Der.sequence(Der.set(Der.sequence(Der.oid("2.5.4.3"), Der.utf8(commonName))))
        let now = Date()
        let serial = UInt64(now.timeIntervalSince1970 * 1000)
        let serialBytes = (0..<8).map { UInt8(truncatingIfNeeded: serial >> (8 * (7 - $0))) }
        let algorithm = Der.sequence(Der.oid("1.2.840.113549.1.1.11"), Der.null)
        let basicConstraints = Der.sequence(Der.oid("2.5.29.19"), Der.boolean(true), Der.octets(Der.sequence(Der.boolean(true))))
        // keyCertSign | cRLSign | digitalSignature
        let keyUsage = Der.sequence(Der.oid("2.5.29.15"), Der.boolean(true), Der.octets(Der.tlv(0x03, [0x01, 0x86])))
        let tbs = Der.sequence(
            Der.tlv(0xA0, Der.integer(2)),
            Der.integer(bytes: serialBytes),
            algorithm,
            name,
            Der.sequence(Der.utcTime(now.addingTimeInterval(-86_400)), Der.utcTime(now.addingTimeInterval(10 * 365 * 86_400))),
            name,
            key.subjectPublicKeyInfo,
            Der.tlv(0xA3, Der.sequence(basicConstraints, keyUsage))
        )
        let signature = try key.sign(.rsaSignatureMessagePKCS1v15SHA256, Data(tbs))
        return Data(Der.sequence(tbs, algorithm, Der.bits(Array(signature))))
    }
}
