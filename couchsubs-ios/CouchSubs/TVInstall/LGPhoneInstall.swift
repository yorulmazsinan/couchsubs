// SPDX-License-Identifier: AGPL-3.0-only
// Android'deki tv/lg (LgInstaller.kt, LegacyPemKey.kt, JschShell.kt) ve ui/LgInstallScreen.kt'nin Swift karşılığı:
// LG webOS uygulamasını geliştirici modu üzerinden bu iPhone'dan kurmak ve güncellemek. Anahtar Key Server'dan (9991)
// bir kez alınır ve TV ekranındaki parolayla çözülür; paket 9922'deki SSH'den (SshClient.swift) "cat > dosya" ile
// yüklenir, luna-send-pub ile kurulur. Masaüstündeki DevModeInstaller ile aynı komutlar.

import CommonCrypto
import CouchSubsCore
import CryptoKit
import Foundation
import SwiftUI

// MARK: - Hatalar

/// LG kurulumunda çıkan sorunlar; arayüz her birine ne yapılacağını söyler.
enum LGInstallError: Equatable {
    /// 9922 yanıt vermiyor: geliştirici modu kapalı ya da TV başka ağda.
    case unreachable
    /// Developer Mode uygulamasında Key Server kapalı.
    case keyServerOff
    case wrongPassphrase
    /// TV anahtarı reddetti (geliştirici modu yeniden açılınca TV yeni anahtar üretir).
    case keyRefused
    case notEnoughSpace, installFailed, connectionLost, packageMissing
    /// TV'de com.couchsubs.tv kimliğiyle başka bir uygulama kurulu (appinfo.json'daki ad ya da yapımcı bizim değil);
    /// kullanıcı onaylamadan kaldırılmaz.
    case foreignApp
    /// TV paketi "ipk verified failed" (errorCode -5) ile reddetti ve TV'nin saati çok geride (paketteki dosya tarihleri
    /// ona göre gelecekte). Kullanıcı TV'nin saatini düzeltir (masaüstündeki DevModeError.tvClockWrong).
    case tvClockWrong
}

struct LGInstallFailure: Error, CustomStringConvertible {
    let error: LGInstallError
    var detail: String?
    var description: String { detail.map { "\(error): \($0)" } ?? "\(error)" }
}

// MARK: - Anahtar

/// Key Server'ın verdiği parolalı anahtarı (eski PEM: "Proc-Type: 4,ENCRYPTED") uygulamanın içinde çözer.
enum LegacyPemKey {
    static func isLegacyEncrypted(_ pem: String) -> Bool { pem.contains("Proc-Type: 4,ENCRYPTED") }

    /// Çözer ve parolasız PEM döner; parola yanlışsa `wrongPassphrase`.
    static func decrypt(_ pem: String, passphrase: String) throws -> String {
        guard let header = pem.range(of: #"-----BEGIN ([A-Z ]+?) PRIVATE KEY-----"#, options: .regularExpression),
              let info = pem.range(of: #"DEK-Info:\s*([A-Za-z0-9-]+),([0-9A-Fa-f]+)\s*"#, options: .regularExpression) else {
            throw LGInstallFailure(error: .installFailed, detail: "PEM başlığı okunamadı")
        }
        let kind = pem[header].dropFirst("-----BEGIN ".count).dropLast(" PRIVATE KEY-----".count)
        let fields = pem[info].dropFirst("DEK-Info:".count).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard fields.count == 2 else { throw LGInstallFailure(error: .installFailed, detail: "PEM başlığı okunamadı") }
        let cipherName = fields[0].uppercased()
        let iv = hex(String(fields[1]))
        let body = pem[info.upperBound...]
        guard let end = body.range(of: "-----END") else { throw LGInstallFailure(error: .installFailed, detail: "PEM sonu bulunamadı") }
        guard let encrypted = Data(base64Encoded: String(body[..<end.lowerBound].filter { !$0.isWhitespace })) else {
            throw LGInstallFailure(error: .installFailed, detail: "PEM gövdesi okunamadı")
        }
        let algorithm: CCAlgorithm
        let keyLength: Int
        switch cipherName {
        case "DES-EDE3-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithm3DES), 24)
        case "AES-128-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 16)
        case "AES-192-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 24)
        case "AES-256-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 32)
        default: throw LGInstallFailure(error: .installFailed, detail: "Desteklenmeyen şifre: \(cipherName)")
        }
        let key = deriveKey(password: Array(passphrase.utf8), salt: Array(iv.prefix(8)), length: keyLength)
        let input = [UInt8](encrypted)
        var output = [UInt8](repeating: 0, count: input.count + 32)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), algorithm, CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                             input, input.count, &output, output.count, &moved)
        // Yanlış parolada dolgu hemen hemen her zaman bozuk çıkar; tutsa bile çözülen veri bir ASN.1 dizisi olmalı.
        guard status == kCCSuccess else { throw LGInstallFailure(error: .wrongPassphrase) }
        let plain = Array(output.prefix(moved))
        guard looksLikeDer(plain) else { throw LGInstallFailure(error: .wrongPassphrase) }
        let base64 = Data(plain).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(kind) PRIVATE KEY-----\n\(base64)\n-----END \(kind) PRIVATE KEY-----\n"
    }

    /// TV parolayı büyük harfle gösterir; küçük harfle yazılmışsa büyük harfli hâli de denenir.
    static func decryptWithCaseFallback(_ pem: String, passphrase: String) throws -> String {
        do {
            return try decrypt(pem, passphrase: passphrase)
        } catch let failure as LGInstallFailure where failure.error == .wrongPassphrase && passphrase != passphrase.uppercased() {
            return try decrypt(pem, passphrase: passphrase.uppercased())
        }
    }

    /// OpenSSL'in EVP_BytesToKey'i (MD5, tek tur): eski PEM anahtarlarının parola türetmesi.
    static func deriveKey(password: [UInt8], salt: [UInt8], length: Int) -> [UInt8] {
        var key: [UInt8] = []
        var previous: [UInt8] = []
        while key.count < length {
            previous = Array(Insecure.MD5.hash(data: previous + password + salt))
            key += previous
        }
        return Array(key.prefix(length))
    }

    private static func looksLikeDer(_ data: [UInt8]) -> Bool {
        guard data.count >= 4, data[0] == 0x30 else { return false }
        let first = Int(data[1])
        var length = first
        var offset = 2
        if first >= 0x80 {
            let bytes = first & 0x7F
            guard bytes > 0, bytes <= 3, data.count >= 2 + bytes else { return false }
            length = 0
            for index in 0..<bytes { length = length << 8 | Int(data[2 + index]) }
            offset = 2 + bytes
        }
        return offset + length == data.count
    }

    private static func hex(_ text: String) -> [UInt8] {
        let characters = Array(text)
        return stride(from: 0, to: characters.count - 1, by: 2).map { UInt8(String(characters[$0...$0 + 1]), radix: 16) ?? 0 }
    }

    /// Parolasız PEM'den (PKCS#1 "RSA PRIVATE KEY" ya da PKCS#8 "PRIVATE KEY") RSA anahtarı.
    static func rsaKey(pem: [UInt8]) throws -> RsaKey {
        let text = String(decoding: pem, as: UTF8.self)
        guard text.contains("PRIVATE KEY"), !isLegacyEncrypted(text) else { throw TVCryptoError("anahtar PEM değil") }
        let der = [UInt8](Der.fromPem(Data(pem)))
        if text.contains("BEGIN RSA PRIVATE KEY") { return try RsaKey(pkcs1: Data(der)) }
        if text.contains("BEGIN PRIVATE KEY"), let parts = try? Der.parse(der).first?.children, parts.count >= 3, parts[2].tag == 0x04 {
            return try RsaKey(pkcs1: Data(parts[2].content))
        }
        throw TVCryptoError("anahtar biçimi desteklenmiyor")
    }
}

/// Key Server'dan alınıp çözülmüş anahtarlar, TV adresine göre (yedeklenmeyen klasörde).
enum LGKeys {
    private static func file(_ host: String) -> URL {
        let name = host.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression)
        return TVPaths.directory("lg").appendingPathComponent(name + ".key")
    }

    static func load(_ host: String) -> [UInt8]? { (try? Data(contentsOf: file(host))).map { [UInt8]($0) } }

    static func save(_ host: String, key: [UInt8]) {
        var directory = TVPaths.directory("lg")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        try? Data(key).write(to: file(host), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ host: String) { try? FileManager.default.removeItem(at: file(host)) }
}

// MARK: - Kabuk

/// TV'de komut çalıştırır; `input` verilirse komutun girişine yazılır ve giriş kapatılır.
protocol LGShell {
    func run(_ command: String, input: [UInt8]?) throws -> CommandResult
}

/// LG geliştirici modunun SSH sunucusu (9922, kullanıcı prisoner); her komut ayrı bağlantı (Android'deki JschShell).
struct SshShell: LGShell {
    let host: String
    let key: [UInt8]
    var port: UInt16 = LGInstaller.port
    var user = "prisoner"
    var connectTimeout: TimeInterval = 8
    var commandTimeout: TimeInterval = 5 * 60

    func run(_ command: String, input: [UInt8]?) throws -> CommandResult {
        let rsa: RsaKey
        do {
            rsa = try LegacyPemKey.rsaKey(pem: key)
        } catch {
            throw LGInstallFailure(error: .keyRefused, detail: "anahtar okunamadı: \(error)")
        }
        let session: SshSession
        do {
            session = try SshSession.connect(host: host, port: port, user: user, key: rsa, timeout: connectTimeout)
        } catch let error as SshError {
            throw LGInstallFailure(error: error.kind == .auth ? .keyRefused : .unreachable, detail: error.description)
        }
        defer { session.close() }
        do {
            let result = try session.exec(command, input: input, timeout: commandTimeout)
            return CommandResult(status: Int32(truncatingIfNeeded: result.status), output: String(decoding: result.stdout + result.stderr, as: UTF8.self))
        } catch {
            throw LGInstallFailure(error: .connectionLost, detail: "\(error)")
        }
    }
}

// MARK: - Kurulum

/// TV uygulamasını LG'nin geliştirici modu üzerinden kurar ve günceller (Android'deki LgInstaller ile aynı).
struct LGInstaller {
    static let port: UInt16 = 9922
    static let keyServerPort: UInt16 = 9991
    static let appId = "com.couchsubs.tv"
    private static let appInfo = "/media/developer/apps/usr/palm/applications/\(appId)/appinfo.json"
    static let tempDir = "/media/developer/temp"
    private static let installLog = "\(tempDir)/couchsubs-install.log"
    private static let sessionToken = "/var/luna/preferences/devmode_enabled"

    struct Result {
        let version: String
        let installed: Bool
    }

    let shell: LGShell
    var progress: (InstallStep) -> Void = { _ in }
    var log = InstallLog.shared
    var pollInterval: TimeInterval = 2
    var installTimeoutSeconds = 180
    var verifyTimeout: TimeInterval?

    /// LG'nin yanıtındaki kalan süre `999:58:40` (saat:dakika:saniye) biçimindedir.
    static func remainingHours(_ response: String) -> Int? {
        guard let found = response.range(of: #"\d{1,4}:\d{2}:\d{2}"#, options: .regularExpression) else { return nil }
        return Int(response[found].split(separator: ":")[0])
    }

    static func keyURL(_ host: String) -> URL? { URL(string: "http://\(host):\(keyServerPort)/webos_rsa") }

    /// ares-install gibi paket TV'ye kendi adıyla yüklenir.
    static func remotePackage(_ name: String) -> String { "\(tempDir)/\(name.split(separator: "/").last.map(String.init) ?? name)" }

    static func versionFromAppInfo(_ text: String) -> String? {
        guard let found = text.range(of: #""version"\s*:\s*"[^"]+""#, options: .regularExpression) else { return nil }
        return text[found].split(separator: "\"").last.map(String.init)
    }

    /// appinfo.json'daki bir metin alanı ("title", "vendor"); yoksa nil.
    static func fieldFromAppInfo(_ text: String, _ key: String) -> String? {
        // cat çıktısının başında/sonunda kabuk yazısı olabilir: yalnız { … } arası okunur.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any] else { return nil }
        return object[key] as? String
    }

    /// TV'deki com.couchsubs.tv bizim uygulamamız değil mi: appinfo.json'da ad CouchSubs değil ya da yapımcı Enmera değil.
    /// Alan yoksa (okunamadıysa) bizim sayılır. Mac, Windows ve Android'deki denetimle aynı.
    static func isForeignAppInfo(_ text: String) -> Bool {
        if let title = fieldFromAppInfo(text, "title")?.trimmingCharacters(in: .whitespaces),
           title.caseInsensitiveCompare("CouchSubs") != .orderedSame { return true }
        if let vendor = fieldFromAppInfo(text, "vendor")?.trimmingCharacters(in: .whitespaces),
           vendor.caseInsensitiveCompare("Enmera") != .orderedSame { return true }
        return false
    }

    /// Geliştirici modunda kurulu uygulamayı kaldıran komut (ares-install --remove gibi); appinfo.json silinene kadar
    /// (en çok 20 sn) bekler.
    static let removeCommand = "/usr/bin/luna-send-pub -n 1 'luna://com.webos.appInstallService/dev/remove' '{\"id\":\"\(appId)\",\"subscribe\":false}'; "
        + "i=0; while [ -f \(appInfo) ] && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done"

    /// Geliştirici modu açık mı (9922 yanıt veriyor mu)?
    static func isDevModeOn(_ host: String, timeout: TimeInterval = 1.5) -> Bool { PosixSocket.isOpen(host: host, port: port, timeout: timeout) }

    /// Bloklayan HTTP GET; yanıt 200 değilse ya da gelmezse nil.
    static func get(_ url: URL?, timeout: TimeInterval) -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { body = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 2)
        return body
    }

    /// Key Server'dan anahtarı alır (yanıt yoksa `keyServerOff`).
    static func downloadKey(_ host: String, timeout: TimeInterval = 5) throws -> [UInt8] {
        guard let data = get(keyURL(host), timeout: timeout) else { throw LGInstallFailure(error: .keyServerOff, detail: "Key Server yanıt vermedi") }
        return [UInt8](data)
    }

    /// Key Server'ın yanıtını parolasız PEM'e çevirir (TV'nin anahtarı eski PEM biçimindedir).
    static func decodeKey(_ response: [UInt8], passphrase: String) throws -> [UInt8] {
        let text = String(decoding: response, as: UTF8.self)
        guard text.contains("PRIVATE KEY") else { throw LGInstallFailure(error: .keyServerOff, detail: "Key Server anahtar yerine başka bir şey döndü") }
        if LegacyPemKey.isLegacyEncrypted(text) {
            return Array(try LegacyPemKey.decryptWithCaseFallback(text, passphrase: passphrase.trimmingCharacters(in: .whitespaces)).utf8)
        }
        // Parolasız PEM olduğu gibi kullanılır; başka biçim (ör. OpenSSH) okunamaz.
        guard (try? LegacyPemKey.rsaKey(pem: response)) != nil else {
            throw LGInstallFailure(error: .keyServerOff, detail: "anahtar okunamadı: biçim desteklenmiyor")
        }
        return response
    }

    /// TV'de kurulumu başlatan kabuk komutu (masaüstü ve Android ile aynı).
    static func installCommand(remotePackage: String, waitSeconds: Int) -> String {
        let parameters = "{\"id\":\"com.ares.defaultName\",\"ipkUrl\":\"\(remotePackage)\",\"subscribe\":true}"
        return [
            "rm -f \(installLog)",
            "sleep \(waitSeconds + 30) </dev/null 2>/dev/null | /usr/bin/luna-send-pub -i 'luna://com.webos.appInstallService/dev/install' '\(parameters)' >\(installLog) 2>&1 & L=$!",
            "i=0",
            "while [ $i -lt \(waitSeconds) ]; do grep -q -i -e '\"state\" *: *\"installed' -e 'failed' -e '\"returnValue\" *: *false' -e '\"state\" *: *\"success' \(installLog) 2>/dev/null && break; kill -0 $L 2>/dev/null || break; sleep 1; i=$((i+1)); done",
            "cat \(installLog)",
            "kill $L 2>/dev/null",
            "rm -f \(installLog)",
        ].joined(separator: "; ")
    }

    static func launchCommand() -> String { "/usr/bin/luna-send-pub -n 1 'luna://com.webos.applicationManager/launch' '{\"id\":\"\(appId)\"}'" }

    /// Açık uygulamayı kapatır (ares-launch --close gibi) ve webOS'un süreci bırakması için bekler. beta.89 (LG): kurulumdan
    /// sonra açık uygulama kapatılmıyordu; açma komutu onu yalnız öne getiriyor, TV eski sürümü çalıştırmayı sürdürüyordu.
    /// Masaüstündeki DevModeInstaller.closeCommand ile aynı.
    static let closeCommand = "/usr/bin/luna-send-pub -n 1 'luna://com.webos.applicationManager/closeByAppId' '{\"id\":\"\(appId)\"}'; sleep 2"

    struct InstallOutcome: Equatable {
        var installed = false
        var failed = false
        var reason: String?
    }

    /// luna-send'in satır satır JSON yanıtlarını ares-install gibi okur.
    static func parseInstallReplies(_ output: String) -> InstallOutcome {
        var pending = ""
        for line in output.deviceLines {
            pending += line.trimmingCharacters(in: .whitespacesAndNewlines)
            if pending.isEmpty { continue }
            guard pending.hasPrefix("{") else {
                pending = ""
                continue
            }
            guard let reply = (try? JSONSerialization.jsonObject(with: Data(pending.utf8))) as? [String: Any] else { continue }
            pending = ""
            let details = reply["details"] as? [String: Any]
            let state = text(details?["state"]) ?? ""
            if (reply["returnValue"] as? Bool) == false {
                return InstallOutcome(failed: true, reason: reason(text(reply["errorText"]) ?? text(reply["errorMessage"]), code: text(reply["errorCode"])))
            }
            if state.range(of: "failed", options: .caseInsensitive) != nil {
                return InstallOutcome(failed: true, reason: reason(text(details?["reason"]) ?? text(details?["errorText"]) ?? state,
                                                                    code: text(details?["errorCode"]) ?? text(reply["errorCode"])))
            }
            if state.range(of: "installed", options: .caseInsensitive) != nil || state.lowercased().hasPrefix("success") {
                return InstallOutcome(installed: true)
            }
        }
        return InstallOutcome()
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber where !(number === kCFBooleanTrue || number === kCFBooleanFalse): number.stringValue
        default: nil
        }
    }

    private static func reason(_ text: String?, code: String?) -> String {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code, !code.isEmpty else { return value }
        return "\(value) (errorCode \(code))".trimmingCharacters(in: .whitespaces)
    }

    static func isStorageProblem(_ text: String) -> Bool {
        text.range(of: #"no space|not enough (free )?(space|storage)|insufficient (free )?(space|storage)|out of space|storage (is )?full|disk (is )?full|ENOSPC|lack of (space|storage)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func short(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 500 ? trimmed : String(trimmed.prefix(500)) + "…"
    }

    /// Geliştirici modunun 1000 saatlik süresini baştan başlatır (TV'deki EXTEND düğmesi). Kalan saati döner; olmazsa nil.
    func renewSession(timeout: TimeInterval = 10) throws -> Int? {
        let token = try shell.run("cat \(Self.sessionToken)", input: nil).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(" ") else { return nil }
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let renewed = Self.get(URL(string: "https://developer.lge.com/secure/ResetDevModeSession.dev?sessionToken=\(encoded)"), timeout: timeout),
              String(decoding: renewed, as: UTF8.self).localizedCaseInsensitiveContains("success") else { return nil }
        guard let checked = Self.get(URL(string: "https://developer.lge.com/secure/CheckDevModeSession.dev?sessionToken=\(encoded)"), timeout: timeout) else { return nil }
        return Self.remainingHours(String(decoding: checked, as: UTF8.self))
    }

    /// TV'deki sürüm; uygulama kurulu değilse nil.
    func installedVersion() throws -> String? { Self.versionFromAppInfo(try shell.run("cat \(Self.appInfo)", input: nil).output) }

    /// TV'deki CouchSubs `version`'dan eskiyse ya da yoksa `ipk`'yı kurar, sonra uygulamayı açar.
    /// `replaceForeign`: TV'de bizim kimliğimizle başka bir uygulama varsa kullanıcı onayladı; o kaldırılıp CouchSubs kurulur.
    /// `runningVersion`: TV'de açık uygulamanın bildirdiği sürüm (bağlı değilse nil). Paket güncel ama açık uygulama eskiyse
    /// uygulama kapatılıp açılır (beta.89).
    func ensureInstalled(ipk: [UInt8], packageName: String, version: String, replaceForeign: Bool = false,
                         runningVersion: String? = nil) throws -> Result {
        log.write("--- LG kurulumu (iPhone) başlıyor: paket \(packageName)")
        do {
            progress(.connecting)
            let appInfo = try shell.run("cat \(Self.appInfo)", input: nil).output
            var onTV = Self.versionFromAppInfo(appInfo)
            log.write("TV'deki CouchSubs: \(onTV ?? "yok")")
            if onTV != nil, Self.isForeignAppInfo(appInfo) {
                let other = "\(Self.fieldFromAppInfo(appInfo, "title") ?? "?") (\(Self.fieldFromAppInfo(appInfo, "vendor") ?? "?")) \(onTV ?? "")"
                // Onaysız hiçbir şey silinmez; ekran kullanıcıya sorar.
                guard replaceForeign else { throw LGInstallFailure(error: .foreignApp, detail: "TV'de aynı kimlikle başka bir uygulama var: \(other)") }
                progress(.uninstalling)
                let removed = try shell.run(Self.removeCommand, input: nil).output
                log.write("TV'deki başka uygulama kaldırıldı (kullanıcı onayladı): \(other): \(removed.trimmingCharacters(in: .whitespacesAndNewlines))")
                onTV = nil
            }
            if let onTV, !Versions.isNewer(version, than: onTV) {
                if let runningVersion, TVAppRunningCheck.isStale(running: runningVersion, installed: onTV) {
                    log.write("TV'deki paket \(onTV), çalışan CouchSubs \(runningVersion.isEmpty ? SubtitleServer.unreportedTVAppVersion : runningVersion); uygulama kapatılıp yeniden açılıyor.")
                    close()
                }
                launch()
                return Result(version: onTV, installed: false)
            }
            progress(.installing)
            try install(ipk: ipk, packageName: packageName, version: version)
            log.write("Kurulum tamam.")
            launch()
            return Result(version: version, installed: true)
        } catch let failure as LGInstallFailure {
            log.write("HATA \(failure.error): \(failure.detail ?? "")")
            throw failure
        } catch {
            log.write("Bağlantı koptu: \(error)")
            throw LGInstallFailure(error: .connectionLost, detail: "\(error)")
        }
    }

    /// Paketi TV'ye yükler ve ares-install gibi kurar; sürüm appinfo.json'dan doğrulanır.
    func install(ipk: [UInt8], packageName: String, version: String) throws {
        let remote = Self.remotePackage(packageName)
        // Önceki denemelerden kalan paketler TV'de yer kaplamasın.
        let upload = try shell.run("mkdir -p \(Self.tempDir) && rm -f \(Self.tempDir)/com.couchsubs.tv_*.ipk \(Self.tempDir)/couchsubs.ipk && cat > '\(remote)'", input: ipk)
        if upload.status != 0 { throw failure("yükleme çıkış kodu \(upload.status): \(Self.short(upload.output))", evidence: upload.output) }
        // Paket TV'ye eksiksiz ulaştı mı? (wc yoksa ya da çıktı okunamazsa denetim atlanır.)
        if let size = Int(try shell.run("wc -c < '\(remote)'", input: nil).output.trimmingCharacters(in: .whitespacesAndNewlines)), size != ipk.count {
            throw LGInstallFailure(error: .installFailed, detail: "paket TV'ye eksik ya da bozuk ulaştı: \(size)/\(ipk.count) bayt")
        }

        let response = try shell.run(Self.installCommand(remotePackage: remote, waitSeconds: installTimeoutSeconds), input: nil)
        log.write("Kurulum yanıtı (\(response.status)):\n\(response.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        let outcome = Self.parseInstallReplies(response.output)
        if outcome.failed {
            let reason = outcome.reason.flatMap { $0.isEmpty ? nil : $0 } ?? "kurulum başarısız: \(Self.short(response.output))"
            // "ipk verified failed" (-5): TV'nin saati okunur ve günlüğe yazılır; çok gerideyse kullanıcıya saati
            // düzeltmesi söylenir (masaüstündeki DevModeInstaller ile aynı komut, eşik ve ayrıntı).
            if DevModeInstaller.isPackageVerifyFailure(reason) {
                let clock = try? shell.run(DevModeInstaller.clockCommand, input: nil).output
                remove(remote)
                let result = DevModeInstaller.verifyFailureDetail(reason: reason, tvClock: clock, now: Date())
                log.write("LG paket doğrulaması reddedildi: \(result.detail)")
                throw LGInstallFailure(error: result.clockWrong ? .tvClockWrong : .installFailed, detail: result.detail)
            }
            remove(remote)
            throw failure(reason, evidence: response.output)
        }
        let limit = verifyTimeout ?? (outcome.installed ? 30 : 60)
        let started = Date()
        while true {
            if try installedVersion() == version {
                remove(remote)
                // Açık (eski) uygulama kapatılır; sonra açılan uygulama yeni sürümü diskten yükler (bkz. closeCommand).
                close()
                return
            }
            if Date().timeIntervalSince(started) >= limit { break }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        // Sonuç gelmediyse paket silinmez: kurulum TV'de sürüyor olabilir; bir sonraki deneme onu temizler.
        if outcome.installed { remove(remote) }
        throw LGInstallFailure(error: .installFailed, detail: "TV'de \(version) sürümü görünmedi; kurulum yanıtı (\(response.status)): \(Self.short(response.output))")
    }

    /// Açık uygulamayı kapatır; açık değilse ya da TV reddederse kurulum yine başarılıdır.
    func close() {
        do {
            log.write("TV'deki CouchSubs kapatıldı: \(try shell.run(Self.closeCommand, input: nil).output.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch {
            log.write("TV'deki CouchSubs kapatılamadı: \(error)")
        }
    }

    /// Kapatır ve yeniden açar (çalışan sürüm kurulu sürümden eskiyse).
    func restart() {
        close()
        launch()
    }

    /// Uygulamayı açar (ares-launch gibi); açılmasa da kurulum başarılıdır.
    private func launch() {
        progress(.launching)
        do {
            log.write("Uygulama açılıyor: \(try shell.run(Self.launchCommand(), input: nil).output.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch {
            log.write("Uygulama açılamadı (kurulum yine tamam): \(error)")
        }
    }

    private func failure(_ detail: String, evidence: String) -> LGInstallFailure {
        LGInstallFailure(error: Self.isStorageProblem(evidence) || Self.isStorageProblem(detail) ? .notEnoughSpace : .installFailed, detail: detail)
    }

    private func remove(_ remote: String) { _ = try? shell.run("rm -f '\(remote)'", input: nil) }
}

extension StoreKey {
    /// LG geliştirici modu için son başarılı uzatma anı; TV adresine göre saklanır.
    static func lgSessionRenewedAt(host: String) -> String {
        "lgSessionRenewedAt.\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}

enum LGSessionRenewalPolicy {
    private static let renewInterval: TimeInterval = 20 * 3600

    static func storageKey(_ host: String) -> String {
        StoreKey.lgSessionRenewedAt(host: host)
    }

    static func renewIfDue(
        now: Date,
        lastRenewedAt: Date?,
        saveRenewedAt: (Date) -> Void,
        renew: () -> Int?
    ) -> Int? {
        if let lastRenewedAt, now.timeIntervalSince(lastRenewedAt) < renewInterval { return nil }
        guard let hours = renew() else { return nil }
        saveRenewedAt(now)
        return hours
    }
}

enum LGPhoneInstall {
    /// Telefondaki LG paketi: içerik, sürümdeki adı ve sürümü.
    static func package() throws -> (ipk: [UInt8], name: String, version: String) {
        guard let name = TVPackages.lgName, let version = TVPackages.lgVersion else { throw LGInstallFailure(error: .packageMissing) }
        do {
            return (try TVPackages.lgPackage(), name, version)
        } catch {
            throw LGInstallFailure(error: .packageMissing, detail: "\(error)")
        }
    }

    /// TV'deki sürümü sessizce okur (kayıtlı anahtar ve açık geliştirici modu gerekir; parola sorulmaz). Bloklayan.
    static func installedVersion(host: String) -> String? {
        guard let key = LGKeys.load(host), LGInstaller.isDevModeOn(host) else { return nil }
        let installer = LGInstaller(shell: SshShell(host: host, key: key))
        guard let version = try? installer.installedVersion() else { return nil }
        renewSessionIfDue(installer, host: host)
        return version
    }

    /// TV'deki CouchSubs'ı kapatıp yeniden açar (kayıtlı anahtar ve açık geliştirici modu gerekir). Bloklayan. Kapatılamadıysa
    /// (anahtar yok, geliştirici modu kapalı) false.
    static func restartApp(host: String) -> Bool {
        guard let key = LGKeys.load(host), LGInstaller.isDevModeOn(host) else { return false }
        LGInstaller(shell: SshShell(host: host, key: key), log: InstallLog.shared).restart()
        return true
    }

    /// LG geliştirici modunun 1000 saatlik süresini günde en çok bir kez baştan başlatır (masaüstü ve Android gibi).
    static func renewSessionIfDue(_ installer: LGInstaller, host: String) {
        let defaults = UserDefaults.standard
        let key = StoreKey.lgSessionRenewedAt(host: host)
        let hours = LGSessionRenewalPolicy.renewIfDue(
            now: Date(),
            lastRenewedAt: defaults.object(forKey: key) as? Date,
            saveRenewedAt: { defaults.set($0, forKey: key) },
            renew: { (try? installer.renewSession()) ?? nil }
        )
        guard let hours else { return }
        InstallLog.shared.write("LG geliştirici modu uzatıldı: \(hours) saat kaldı")
    }
}

/// Geliştirici modunun SSH'si (9922) yanıt vermediğinde TV'nin durumu: diğer portlara bakılarak ayrılır.
///
/// TestFlight (19–20 Kas): bir kullanıcı 14 denemede hep "192.168.1.123:9922: Connection refused" aldı; ekranda yalnız
/// "TV yanıt vermedi… Dev Mode Status açık olsun" yazıyordu, oysa TV açıktı ve Key Server'ı da açmıştı. TV'nin başka
/// portları yanıt veriyorsa sorun adres ya da Wi-Fi değil, geliştirici modunun SSH'sidir; ne yapılacağı ona göre söylenir.
enum LGUnreachableReason: Equatable {
    /// Key Server (9991) açık ama SSH kapalı: Dev Mode Status açıldıktan sonra TV yeniden başlamamış.
    case restartNeeded
    /// TV bu adreste (3000/3001 yanıt veriyor) ama geliştirici modu kapalı ya da süresi dolmuş.
    case devModeOff
    /// Bu adreste hiçbir port yanıt vermiyor: TV kapalı, başka ağda ya da adresi değişmiş.
    case tvNotFound

    static func classify(keyServer: Bool, ssap: Bool) -> LGUnreachableReason {
        if keyServer { return .restartNeeded }
        return ssap ? .devModeOff : .tvNotFound
    }

    /// TV'nin Key Server (9991) ve kumanda (3000/3001) portlarına bakar. Bloklar.
    static func probe(_ host: String, timeout: TimeInterval = 1.5) -> LGUnreachableReason {
        let keyServer = PosixSocket.isOpen(host: host, port: LGInstaller.keyServerPort, timeout: timeout)
        let ssap = keyServer || PosixSocket.isOpen(host: host, port: 3001, timeout: timeout) || PosixSocket.isOpen(host: host, port: 3000, timeout: timeout)
        return classify(keyServer: keyServer, ssap: ssap)
    }
}

// MARK: - Ekran

struct LGInstallSection: View {
    @EnvironmentObject private var model: PhoneModel
    let update: TVAppUpdate?
    @Binding var working: Bool
    let onDone: () -> Void
    @State private var candidates: [(host: String, name: String, devMode: Bool)]?
    @State private var host = ""
    @State private var manual = false
    @State private var addressError = false
    @State private var passphrase = ""
    @State private var phase = TVInstallPhase.idle
    @State private var started = false
    @State private var foreignApp = false

    private var hasKey: Bool {
        let target = host.trimmingCharacters(in: .whitespaces)
        return !target.isEmpty && LGKeys.load(target) != nil
    }

    var body: some View {
        InstallIntro(body1: TVText.lgBody, note: TVText.lgSupported)
        InstallListTitle(text: TVText.lgTvs, searching: candidates == nil)
        if let candidates {
            if candidates.isEmpty { MobileNote(text: TVText.lgNone) }
            ForEach(candidates, id: \.host) { item in
                Button { if !phase.isWorking { host = item.host } } label: {
                    InstallCandidateRow(name: item.name, detail: item.host,
                                        status: item.devMode ? (TVText.devOn, true) : (TVText.devOff, false), selected: host == item.host)
                }
                .buttonStyle(.plain)
            }
        } else {
            InstallSearching()
        }
        if addressError {
            MobileNote(text: String(localized: "This is not a valid IP address. Type it like 192.168.1.20, without http:// or a port number."))
        }
        if manual {
            TextField(TVText.address, text: $host)
                .textFieldStyle(MobileFieldStyle()).keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
                .onChange(of: host) { _ in addressError = false }
        } else if !phase.isWorking {
            Button(TVText.notFound) { manual = true }.buttonStyle(.mobileGhost)
        }
        TextField(hasKey ? TVText.lgPassphraseSaved : TVText.lgPassphrase, text: Binding(
            get: { passphrase }, set: { passphrase = $0.trimmingCharacters(in: .whitespaces).uppercased() }))
            .textFieldStyle(MobileFieldStyle()).keyboardType(.asciiCapable).autocorrectionDisabled().textInputAutocapitalization(.characters)
        InstallSteps(title: TVText.lgStepsTitle, steps: [TVText.lgStep1, TVText.lgStep2, TVText.lgStep3, TVText.lgStep4])
        InfoBox(text: TVText.lgSessionNote, tone: Mobile.Palette.secondary)
        InstallResult(phase: phase)
        // Kurulum bitince ana düğme ana ekrana götürür; kurulumda kullanıcı 3. adımda kalıyordu (#113).
        Group {
            if phase.isDone {
                Button(TVText.goHome, action: onDone).buttonStyle(.mobilePrimary)
            } else {
                Button(phase == .idle || phase.isWorking ? TVText.button : TVText.retry) { install() }
                    .buttonStyle(.mobilePrimary)
                    .disabled(phase.isWorking || host.trimmingCharacters(in: .whitespaces).isEmpty || (passphrase.isEmpty && !hasKey))
            }
        }
            .task { await search() }
            .foreignAppAlert(isPresented: $foreignApp) { install(replaceForeign: true) }
    }

    private func search() async {
        guard candidates == nil else { return }
        if let update {
            host = update.host
        } else if host.isEmpty, let installed = model.installedTVApp, installed.brand == .lg {
            host = installed.host
        }
        // "TV uygulamasını güncelle"den gelindiyse ve anahtar kayıtlıysa kurulum hemen başlar; değilse parola beklenir.
        if update != nil, !started, hasKey {
            started = true
            install()
        }
        var found = await model.discoverTVs().filter { $0.brand == .lg }
        if let known = model.tv, known.brand == .lg, !known.host.isEmpty, !found.contains(where: { $0.host == known.host }) { found.insert(known, at: 0) }
        let list = await withTaskGroup(of: (Int, (host: String, name: String, devMode: Bool)).self) { group in
            for (index, tv) in found.enumerated() {
                group.addTask { (index, (tv.host, tv.name, LGInstaller.isDevModeOn(tv.host))) }
            }
            var items: [(Int, (host: String, name: String, devMode: Bool))] = []
            for await item in group { items.append(item) }
            return items.sorted { $0.0 < $1.0 }.map(\.1)
        }
        candidates = list
        if host.isEmpty, let first = list.first(where: { $0.devMode }) ?? list.first { host = first.host }
        if list.isEmpty { manual = true }
    }

    private func install(replaceForeign: Bool = false) {
        // Elle yazılan adres temizlenir ("192.168.1.5:3000", "http://…", virgüllü yazım); adres değilse söylenir.
        guard let typedTarget = ManualAddress.normalize(host) else {
            addressError = true
            return
        }
        addressError = false
        let typed = passphrase.trimmingCharacters(in: .whitespaces)
        // TV'de açık uygulamanın bildirdiği sürüm: paket güncel ama bu eskiyse uygulama kapatılıp açılır (beta.89).
        let running = model.runningTVAppVersion
        phase = .working(.connecting)
        working = true
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            defer {
                working = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
            // Kayıtlı TV'nin adresi hiç yanıt vermiyorsa TV ağda yeniden aranır (beta.89: modem TV'ye yeni adres vermişti,
            // eski adrese gidilip "Key Server kapalı" deniyordu). Bulunursa kurulum yeni adresle sürer.
            guard let target = await model.relocateForInstall(host: typedTarget, brand: .lg) else {
                phase = .failed(text: TVText.lgErrTvNotFound)
                candidates = nil
                manual = false
                await search()
                return
            }
            if target != typedTarget { host = target }
            do {
                let result = try await runInstall({ progress in
                    let package = try LGPhoneInstall.package()
                    let log = InstallLog.shared
                    func fresh() throws -> [UInt8] {
                        guard !typed.isEmpty else { throw LGInstallFailure(error: .keyRefused, detail: "parola yazılmadı") }
                        progress(.key)
                        let key = try LGInstaller.decodeKey(try LGInstaller.downloadKey(target), passphrase: typed)
                        LGKeys.save(target, key: key)
                        log.write("Key Server'dan anahtar alındı.")
                        return key
                    }
                    func attempt(_ key: [UInt8]) throws -> LGInstaller.Result {
                        let installer = LGInstaller(shell: SshShell(host: target, key: key), progress: progress, log: log)
                        let result = try installer.ensureInstalled(ipk: package.ipk, packageName: package.name, version: package.version,
                                                                  replaceForeign: replaceForeign, runningVersion: running)
                        // Masaüstündeki gibi: geliştirici modunun süresi günde bir uzatılır, kullanıcı TV'den uzatmaz.
                        LGPhoneInstall.renewSessionIfDue(installer, host: target)
                        return result
                    }
                    guard let saved = LGKeys.load(target) else { return try attempt(fresh()) }
                    do {
                        return try attempt(saved)
                    } catch let failure as LGInstallFailure where failure.error == .keyRefused {
                        // Geliştirici modu yeniden açılınca TV yeni anahtar üretir; eskisi bırakılır, parola yazıldıysa yenisi alınır.
                        LGKeys.remove(target)
                        log.write("Kayıtlı anahtar reddedildi; bırakıldı.")
                        return try attempt(fresh())
                    }
                }, progress: { step in if phase.isWorking { phase = .working(step) } })
                phase = .done(version: result.version, installed: result.installed)
                await model.tvAppInstalled(brand: .lg, host: target, port: nil, version: result.version)
            } catch let failure as LGInstallFailure where failure.error == .foreignApp {
                phase = .failed(text: TVText.foreignMessage)
                foreignApp = true
            } catch let failure as LGInstallFailure {
                // 9922 yanıt vermediyse neden: TV bu adreste mi, geliştirici modu mu kapalı (diğer portlara bakılır).
                var reason: LGUnreachableReason?
                if failure.error == .unreachable {
                    let found = await Task.detached(priority: .userInitiated) { LGUnreachableReason.probe(target) }.value
                    InstallLog.shared.write("9922 yanıt vermedi; TV'nin durumu: \(found)")
                    reason = found
                }
                phase = .failed(text: failureText(failure, reason: reason))
                // TV bu adreste yoksa adresi değişmiş olabilir: liste yeniden aranır.
                if reason == .tvNotFound {
                    candidates = nil
                    manual = false
                    await search()
                }
            } catch {
                phase = .failed(text: TVText.errFailed + "\n\n" + TVText.lgTvSays("\(error)"))
            }
        }
    }

    /// Ne yapılacağı (Android'deki lgFailureText) ve TV'nin verdiği ayrıntı.
    private func failureText(_ failure: LGInstallFailure, reason: LGUnreachableReason? = nil) -> String {
        let advice: String = switch failure.error {
        case .unreachable:
            switch reason {
            case .restartNeeded: TVText.lgErrRestartNeeded
            case .devModeOff: TVText.lgErrDevModeOff
            case .tvNotFound: TVText.lgErrTvNotFound
            case nil: TVText.lgErrUnreachable
            }
        case .keyServerOff: TVText.lgErrKeyServer
        case .wrongPassphrase: TVText.lgErrPassphrase
        case .keyRefused: TVText.lgErrKeyRefused
        case .notEnoughSpace: TVText.errSpace
        case .connectionLost: TVText.errConnection
        case .packageMissing: TVText.errPackageMissing
        // "ipk verified failed" (-5): saat yerindeyse de ne yapılacağı söylenir (Mac, Windows, Android aynı).
        case .installFailed where failure.detail.map(DevModeInstaller.isPackageVerifyFailure) == true: TVText.lgErrVerify
        case .installFailed: TVText.errFailed
        case .tvClockWrong: TVText.lgErrClock
        case .foreignApp: TVText.foreignMessage
        }
        guard failure.error != .wrongPassphrase, failure.error != .foreignApp, let detail = failure.detail, !detail.isEmpty else { return advice }
        return advice + "\n\n" + TVText.lgTvSays(detail)
    }
}
