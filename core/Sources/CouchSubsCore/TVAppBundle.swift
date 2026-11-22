// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

/// TV uygulamasının sayfa kodu (ince kabuk, docs/tv-ince-kabuk.md). TV'de kurulu kabuk bağlandığı bilgisayardan/telefondan
/// bu dosyaları `GET /tv/app/manifest` ve `GET /tv/app/<sürüm>/<dosya>` ile alır; böylece TV uygulaması masaüstü ya da
/// telefon güncellenince yeniden kurulmadan güncellenir. Windows `TvAppBundle.cs`, Android `TvAppBundle.kt` ile aynı.
///
/// Bütünlük: liste (manifest) eşleşme anahtarıyla HMAC-SHA256 imzalıdır, her dosyanın SHA-256 özeti listededir. Kabuk
/// imzayı ve özetleri doğrulamadan kodu çalıştırmaz.
public struct TVAppBundle: Sendable {
    /// Sunulan dosyalar ve sırası (index.html'den yalnız `<body>` işaretlemesi kullanılır).
    public static let paths = ["index.html", "style.css", "i18n.js", "app.js"]
    /// Liste biçimi; imzalanan metnin ilk satırı `couchsubs-tv-app/<biçim>`.
    public static let format = 1
    public static let prefix = "/tv/app/"
    public static let manifestPath = "/tv/app/manifest"

    public struct File: Sendable {
        public let path: String
        public let data: Data
        public let sha256: String
    }

    /// Sayfanın sürümü (app.js `APP_VERSION`).
    public let version: String
    /// Sayfanın istediği kabuk arayüzü sürümü (app.js `SHELL_API`). Daha eski kabuk sayfayı yüklemez, kendi yedeğiyle açılır.
    public let shellAPI: Int
    public let files: [File]

    /// Dört dosyanın hepsi varsa ve app.js sürümü ile kabuk arayüzü sürümünü bildiriyorsa paket kurulur.
    public init?(files: [String: Data]) {
        var list: [File] = []
        for path in Self.paths {
            guard let data = files[path], !data.isEmpty else { return nil }
            list.append(File(path: path, data: data, sha256: Self.hex(Data(SHA256.hash(data: data)))))
        }
        guard let app = String(data: files["app.js"]!, encoding: .utf8),
              let version = Self.match(#"var APP_VERSION = '([0-9]+(?:\.[0-9]+){1,3})';"#, in: app),
              let shell = Self.match(#"var SHELL_API = ([0-9]{1,3});"#, in: app), let api = Int(shell), api >= 1 else { return nil }
        self.version = version
        shellAPI = api
        self.files = list
    }

    /// Klasördeki dosyalardan (tv-webos ya da uygulama paketindeki kopyası).
    public static func load(directory: URL) -> TVAppBundle? {
        var files: [String: Data] = [:]
        for path in paths { files[path] = try? Data(contentsOf: directory.appendingPathComponent(path)) }
        return TVAppBundle(files: files)
    }

    /// Uygulama paketindeki TV sayfası: Mac ve iPhone uygulamaları tv-webos klasörünü kaynak olarak taşır
    /// (mac/project.yml, couchsubs-ios/project.yml). Yoksa (geliştirme derlemesi) `/tv/app` 404 döner, TV yedeğiyle açılır.
    public static let bundled: TVAppBundle? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        return load(directory: resources.appendingPathComponent("tv-webos", isDirectory: true))
    }()

    public static func isPath(_ path: String) -> Bool { path.hasPrefix(prefix) }

    /// İmzalanan metin: biçim, sürüm, kabuk arayüzü ve her dosya için "ad boyut özet" satırı.
    public var canonical: String {
        var text = "couchsubs-tv-app/\(Self.format)\n\(version)\n\(shellAPI)\n"
        for file in files { text += "\(file.path) \(file.data.count) \(file.sha256)\n" }
        return text
    }

    public static func signature(_ canonical: String, key: String) -> String {
        hex(Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: Data(key.utf8)))))
    }

    /// `GET /tv/app/manifest` yanıtı.
    public func manifest(key: String) -> Data {
        let json: [String: Any] = [
            "format": Self.format, "version": version, "shellApi": shellAPI,
            "files": files.map { ["path": $0.path, "size": $0.data.count, "sha256": $0.sha256] as [String: Any] },
            "hmac": Self.signature(canonical, key: key),
        ]
        return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    }

    /// `/tv/app/<sürüm>/<dosya>`: yalnız bu paketin sürümü ve listedeki dosyalar.
    public func file(at path: String) -> File? {
        guard path.hasPrefix(Self.prefix) else { return nil }
        let rest = path.dropFirst(Self.prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard rest.count == 2, rest[0] == version else { return nil }
        return files.first { $0.path == rest[1] }
    }

    public static func contentType(_ path: String) -> String {
        if path.hasSuffix(".html") { return "text/html; charset=utf-8" }
        if path.hasSuffix(".css") { return "text/css; charset=utf-8" }
        return "application/javascript; charset=utf-8"
    }

    /// Sürümlü adresteki dosya değişmez: TV tarayıcısı önbellekte tutabilir (kabuk yine de özeti doğrular).
    public static let fileCache = "private, max-age=31536000, immutable"

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(found.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
