// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit
import Security
import Darwin

/// Windows ve Android ile aynı TV/OBS erişim politikası.
public enum SubtitleAccess {
    // Yalnız geçiş sürümü: sonraki sürümde false yapılmalı.
    public static let allowLegacyClients = true
    public static func createKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    public static func isLocalPeer(_ address: String) -> Bool {
        guard !address.isEmpty else { return false }
        let host = String(address.split(separator: "%", maxSplits: 1)[0])
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return withUnsafeBytes(of: v4) { localIPv4(Array($0)) }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b.prefix(10).allSatisfy({ $0 == 0 }) && b[10] == 255 && b[11] == 255 { return localIPv4(Array(b.suffix(4))) }
        return b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1
            || b[0] & 0xfe == 0xfc || b[0] == 0xfe && b[1] & 0xc0 == 0x80
    }
    /// Eşleştirme isteği gönderen TV'nin geri bağlanılacak adresi: IPv4'e eşlenmiş IPv6 (`::ffff:a.b.c.d`) düz IPv4 olur,
    /// bağlantı arayüzü (`%en0`) atılır. Bu cihazın kendisi (127.x, ::1; ikinci ekran sayfası) ve yerel olmayan adres TV
    /// sayılmaz: boş döner (Windows `SubtitleAccess.TvHost`, Android `SubtitleAccess.tvHost` ile aynı kural).
    public static func tvHost(fromPeer address: String) -> String {
        var host = String(address.split(separator: "%", maxSplits: 1).first ?? "")
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.lowercased().hasPrefix("::ffff:"), host.contains(".") { host = String(host.dropFirst(7)) }
        guard isLocalPeer(host) else { return "" }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return host.hasPrefix("127.") ? "" : host }
        return host == "::1" ? "" : host
    }
    private static func localIPv4(_ b: [UInt8]) -> Bool {
        b[0] == 127 || b[0] == 10 || b[0] == 172 && (16...31).contains(b[1])
            || b[0] == 192 && b[1] == 168 || b[0] == 169 && b[1] == 254
            || b[0] == 100 && (64...127).contains(b[1])
    }

    public struct Request: Sendable {
        public let method: String
        public let target: String
        public let origin: String?
        public let host: String
        public var path: String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]) }
        public func parameter(_ name: String) -> String? {
            guard let query = target.firstIndex(of: "?") else { return nil }
            var result: String?
            for pair in target[target.index(after: query)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard String(parts[0]).removingPercentEncoding == name else { continue }
                if result != nil { return "" }
                result = parts.count == 2 ? String(parts[1]).removingPercentEncoding ?? "" : ""
            }
            return result
        }
    }

    public static func parse(_ head: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].components(separatedBy: " ")
        guard first.count == 3, first[1].hasPrefix("/") else { return nil }
        var origin: String?
        var host: String?
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex, line.first?.isWhitespace == false else { return nil }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }) else { return nil }
            if name == "origin" { if origin != nil { return nil }; origin = value }
            if name == "host" { if host != nil { return nil }; host = value }
        }
        return Request(method: first[0], target: first[1], origin: origin, host: host ?? "")
    }

    private static func packagedOrigin(_ origin: String) -> Bool {
        // Paketli TV uygulamaları: webOS/Android TV "null", Samsung Tizen ise (en az 5.0'da, POST isteklerinde) "file://" gönderir.
        if origin == "null" || origin == "file://" { return true }
        guard let url = URLComponents(string: origin) else { return false }
        return url.scheme == "app" && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
            && ["", "/"].contains(url.path) && url.query == nil && url.fragment == nil
    }
    public static func originAllowed(_ request: Request) -> Bool {
        guard let value = request.origin else { return true }
        if packagedOrigin(value) { return true }
        guard let origin = URLComponents(string: value), origin.scheme == "http", origin.host != nil,
              origin.user == nil, origin.password == nil, ["", "/"].contains(origin.path), origin.query == nil, origin.fragment == nil,
              let local = URLComponents(string: "http://" + request.host), local.host != nil,
              local.user == nil, local.password == nil, ["", "/"].contains(local.path), local.query == nil, local.fragment == nil else { return false }
        return origin.host?.lowercased() == local.host?.lowercased() && (origin.port ?? 80) == (local.port ?? 80)
    }
    public static func cors(_ request: Request) -> String {
        guard let origin = request.origin, packagedOrigin(origin) else { return "" }
        return "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\n"
    }
    public static func authorize(_ request: Request, key: String, allowLegacy: Bool) -> (status: Int, legacy: Bool) {
        guard originAllowed(request) else { return (403, false) }
        if request.path == "/hello" || request.path == "/obs" || request.path == "/pair" { return (200, false) }
        let supplied = request.parameter("k")
        // İkinci ekran (sayfası ve akışı) eski TV'lere tanınan anahtarsız geçişten yararlanmaz: aynı ağdaki herkes açamaz.
        // TV sayfasının kodu (/tv/app) da: listesi eşleşme anahtarıyla imzalanır, anahtarsız istenemez.
        if supplied == nil && allowLegacy && !isSecondScreen(request) && !TVAppBundle.isPath(request.path) && (request.origin == nil || packagedOrigin(request.origin!)) { return (200, true) }
        guard let supplied else { return (401, false) }
        // CryptoKit doğrulaması sabit zamanlı karşılaştırır; sıradan String == kullanılmaz.
        let secret = SymmetricKey(data: Data(key.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(key.utf8), using: secret)
        return (HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data(supplied.utf8), using: secret) ? 200 : 401, false)
    }

    /// Başka bir cihazın tarayıcısında açılan altyazı sayfası (`/view`) ya da onun akışı (`/events?viewer=second`).
    public static func isSecondScreen(_ request: Request) -> Bool {
        request.path == SecondScreen.path || request.path == "/events" && request.parameter("viewer") == SecondScreen.viewer
    }
}
