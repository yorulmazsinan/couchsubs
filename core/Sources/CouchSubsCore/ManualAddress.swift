// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Elle yazılan PS5 ya da TV adresi. Kullanıcılar "192.168.1.5:3000", "http://192.168.1.5", sonda boşluk ya da (Türkçe
/// sayı klavyesinde nokta olmadığı için) "192,168,1,5" yazıyordu. TV'de böyle bir adresle kurulan bağlantı adresi
/// geçersiz çıkıp uygulamayı kapatıyordu. Adres burada temizlenir; temizlendikten sonra da adres olmayan giriş reddedilir.
public enum ManualAddress {
    /// Baştaki/sondaki boşluk, "http://" gibi önek, ":3000" gibi port ve "/..." yolu atılır, virgüller noktaya döner.
    /// IPv4 (dört 0–255 parça) ya da ağ adı (ör. "lgwebostv.local") kabul edilir; başka her şey nil.
    public static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let end = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<end]) }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        // Tek iki nokta port ayırır; daha fazlası IPv6'dır (TV'ler IPv4 adresiyle eşleşir).
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy(\.isASCIIDigit) else { return nil }
            text = String(parts[0])
        } else if parts.count > 2 {
            return nil
        }
        if text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if text.allSatisfy({ $0.isASCIIDigit || $0 == "." }) { return ipv4(text) }
        return isHostName(text) ? text.lowercased() : nil
    }

    private static func ipv4(_ text: String) -> String? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var values: [Int] = []
        for octet in octets {
            guard (1...3).contains(octet.count), let value = Int(octet), (0...255).contains(value) else { return nil }
            values.append(value)
        }
        return values.map(String.init).joined(separator: ".")
    }

    /// Harf, rakam ve tireden oluşan, en az bir harf içeren etiketler (RFC 1123).
    private static func isHostName(_ text: String) -> Bool {
        guard text.count <= 253, text.contains(where: \.isASCIILetter) else { return false }
        return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCIILetter || $0.isASCIIDigit || $0 == "-" }
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
