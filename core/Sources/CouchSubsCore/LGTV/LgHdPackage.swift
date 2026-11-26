// SPDX-License-Identifier: AGPL-3.0-only
// Windows'taki LgHdPackage.cs ve Android'deki LgHdPackage.kt ile aynı. iPhone (LGPhoneInstall) de bunu kullanır.

import Foundation

/// LG Full HD webOS 3.x TV'lere (2016-2017; 43LH590V, #1098) 1280x720 paket.
///
/// LG: Full HD modellerin grafik çözünürlüğü en çok 1280x720; uygulamanın çözünürlüğü appinfo.json'daki `resolution`
/// ile belirlenir (varsayılan 1920x1080) ve LG, Full HD modeller için ayrı bir 1280x720 paket önerir
/// (webostv.developer.lge.com, "Supported App Resolution"). 43LH590V'de 1920x1080 paket sayfayı 1920x1080 CSS pikselinde
/// düzenliyor ama yalnız sol üst 1280x720'sini çiziyordu: görünüm etiketi (0.9.113) de sayfa açılırken alınan görünüm
/// (0.9.117) de bunu değiştirmedi; ekranın sağ ve alt üçte biri (alttaki altyazı, sağdaki çeviriler) boş kaldı.
/// Kurulumdan önce TV'nin modeli, UHD olup olmadığı ve webOS sürümü sorulur (webOSTV.js deviceInfo'nun okuduğu luna
/// servisi); Full HD webOS 3.x TV'de paketteki appinfo.json'un `resolution` değeri 1280x720 yapılır. Sayfa 1280x720
/// görünümde açılır, tv-webos/platform.js onu CSS zoom ile 1920x1080 uzayına sığdırır. Diğer bütün LG'lere paket
/// değişmeden gider.
public enum LgHdPackage {
    public static let resolution = "1280x720"

    /// TV'nin modeli, UHD olup olmadığı ve SDK (webOS) sürümü.
    public static let systemInfoCommand =
        "/usr/bin/luna-send-pub -n 1 'luna://com.webos.service.tv.systemproperty/getSystemInfo' " +
        "'{\"keys\":[\"modelName\",\"UHD\",\"sdkVersion\"]}'"

    public struct Screen: Equatable, Sendable {
        public var model: String?
        public var uhd: Bool?
        public var sdkVersion: String?
        /// 1280x720 paket kurulacak mı?
        public var hd: Bool

        /// Günlük satırı: "43LH590V-ZE, UHD false, sdk 03.70.50 → 1280x720".
        public var summary: String {
            "\(model ?? "?"), UHD \(uhd.map { $0 ? "true" : "false" } ?? "?"), sdk \(sdkVersion ?? "?") → " +
                (hd ? resolution : "1920x1080")
        }
    }

    /// getSystemInfo yanıtı → karar. 2016 (LH) ve 2017 (LJ) Full HD serisi ya da UHD olmayan webOS 3.x TV 1280x720 alır;
    /// TV UHD diyorsa ya da yanıt okunamazsa paket değişmez.
    public static func screen(reply: String) -> Screen {
        let model = field(reply, "modelName").flatMap { $0.isEmpty ? nil : $0 }
        let uhd: Bool? = switch field(reply, "UHD")?.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
        let sdk = field(reply, "sdkVersion").flatMap { $0.isEmpty ? nil : $0 }
        let major = sdk.flatMap { text in Int(text.prefix(while: { $0.isNumber })) }
        let fhdLine = model.map { $0.range(of: #"^\d{2,3}L[HJ]\d"#, options: [.regularExpression, .caseInsensitive]) != nil } ?? false
        let hd = uhd != true && (fhdLine || (uhd == false && major == 3))
        return Screen(model: model, uhd: uhd, sdkVersion: sdk, hd: hd)
    }

    static func field(_ text: String, _ key: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""\#(key)"\s*:\s*(?:"([^"]*)"|([A-Za-z0-9.]+))"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: text) {
                return String(text[range]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Paket

    /// Paketteki appinfo.json'un `"resolution": "1920x1080"` değeri `"1280x720" ` olur (aynı uzunlukta; tar başlığı ve
    /// sağlaması değişmez). data.tar.gz yeniden sıkıştırılır, ar başlığındaki boyut yazılır; başka hiçbir bayt değişmez.
    /// Paket beklenen biçimde değilse ya da değer zaten değiştiyse nil.
    public static func adapt(_ ipk: [UInt8]) -> [UInt8]? {
        guard var members = readAr(ipk),
              let index = members.firstIndex(where: { $0.name == "data.tar.gz" }),
              var tar = try? [UInt8](Gzip.decompress(Data(members[index].body))),
              adaptTar(&tar) else { return nil }
        members[index].body = Gzip.compress(tar)
        return writeAr(members)
    }

    struct ArMember {
        var header: [UInt8]
        var body: [UInt8]
        var name: String {
            String(decoding: header[0..<16], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    static func readAr(_ data: [UInt8]) -> [ArMember]? {
        let magic = Array("!<arch>\n".utf8)
        guard data.count >= magic.count, Array(data[0..<magic.count]) == magic else { return nil }
        var members: [ArMember] = []
        var offset = magic.count
        while offset < data.count {
            guard offset + 60 <= data.count, data[offset + 58] == 0x60, data[offset + 59] == 0x0A else { return nil }
            let header = Array(data[offset..<(offset + 60)])
            guard let size = Int(String(decoding: header[48..<58], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
                  size >= 0, offset + 60 + size <= data.count else { return nil }
            members.append(ArMember(header: header, body: Array(data[(offset + 60)..<(offset + 60 + size)])))
            offset += 60 + size + (size & 1)
        }
        return members
    }

    static func writeAr(_ members: [ArMember]) -> [UInt8] {
        var out = Array("!<arch>\n".utf8)
        for member in members {
            var header = member.header
            let size = Array(String(member.body.count).utf8)
            for i in 0..<10 { header[48 + i] = i < size.count ? size[i] : 0x20 }
            out += header + member.body
            if member.body.count & 1 == 1 { out.append(0x0A) }
        }
        return out
    }

    /// tar'daki uygulama appinfo.json'unu bulur ve çözünürlüğü yazar. Değiştiyse true.
    static func adaptTar(_ tar: inout [UInt8]) -> Bool {
        var offset = 0
        while offset + 512 <= tar.count {
            let header = tar[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) { return false }
            func text(_ from: Int, _ count: Int) -> String {
                let slice = tar[(offset + from)..<(offset + from + count)]
                return String(decoding: slice.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let prefix = text(345, 155)
            let name = (prefix.isEmpty ? "" : prefix + "/") + text(0, 100)
            let octal = text(124, 12).trimmingCharacters(in: .whitespaces)
            guard let size = Int(octal.isEmpty ? "0" : octal, radix: 8), size >= 0 else { return false }
            let start = offset + 512
            guard start + size <= tar.count else { return false }
            if isAppInfo(name) {
                let original = String(decoding: tar[start..<(start + size)], as: UTF8.self)
                guard let adapted = adaptAppInfo(original) else { return false }
                let bytes = Array(adapted.utf8)
                guard bytes.count == size else { return false }
                tar.replaceSubrange(start..<(start + size), with: bytes)
                return true
            }
            offset = start + (size + 511) / 512 * 512
        }
        return false
    }

    static func isAppInfo(_ name: String) -> Bool {
        name.hasSuffix("/appinfo.json") && name.contains("palm/applications/")
    }

    /// `"resolution": "1920x1080"` → `"resolution": "1280x720" ` (uzunluk aynı); değer yoksa nil.
    public static func adaptAppInfo(_ text: String) -> String? {
        guard let found = text.range(of: #""resolution"\s*:\s*"1920x1080""#, options: .regularExpression) else { return nil }
        let value = text[found].replacingOccurrences(of: "\"1920x1080\"", with: "\"\(resolution)\" ")
        return text.replacingCharacters(in: found, with: value)
    }
}

extension Gzip {
    /// RFC 1952 gzip (başlık zamanı 0); gövde Foundation'ın DEFLATE sıkıştırıcısıyla.
    static func compress(_ data: [UInt8]) -> [UInt8] {
        let body = ((try? (Data(data) as NSData).compressed(using: .zlib)) as Data?).map { [UInt8]($0) } ?? stored(data)
        var out: [UInt8] = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff]
        out += body
        out += le32(crc32(data)) + le32(UInt32(truncatingIfNeeded: data.count))
        return out
    }

    /// Sıkıştırmasız DEFLATE blokları (sıkıştırıcı yoksa).
    static func stored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var offset = 0
        repeat {
            let count = min(65535, data.count - offset)
            let last: UInt8 = offset + count >= data.count ? 1 : 0
            out += [last, UInt8(count & 0xff), UInt8(count >> 8), UInt8(~count & 0xff), UInt8((~count >> 8) & 0xff)]
            out += data[offset..<(offset + count)]
            offset += count
        } while offset < data.count
        return out
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
