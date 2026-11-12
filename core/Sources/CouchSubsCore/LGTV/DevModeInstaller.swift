// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// Dış komut çalıştıran her şey (gerçekte `ProcessRunner`).
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], input: URL?) async throws -> CommandResult
}

/// TV uygulamasını kurarken çıkan sorunlar (LG, Samsung ve Android TV ortak).
public enum DevModeError: Error, Equatable {
    case unreachable, keyServerOff, wrongPassphrase, keyRefused, installFailed
    /// Samsung: TV Tizen 3.0'dan (2017) eski.
    case tooOld
    /// Samsung hesabıyla giriş tamamlanmadı.
    case signInFailed
    /// Samsung TV'ye özel sertifikayı vermedi.
    case certificateFailed
    /// Android: TV'de hata ayıklama izni verilmedi.
    case notApproved
    /// TV kurulumda yer kalmadığını söyledi.
    case notEnoughSpace
    /// Samsung: TV'de başka sertifikayla imzalı eski kopya var ve kaldırılamadı.
    case certificateMismatch
    /// Samsung: TV imza sertifikasını reddetti (internet, saat ya da sertifika).
    case certificateRejected
    /// Samsung: TV'nin saati geride; sertifika ona göre henüz geçerli değil.
    case tvClockWrong
    /// Samsung: TV, silinmiş eski kopyanın kaydı yüzünden uygulamayı kabul etmiyor ([118, -22]).
    case packageBlocked
    /// Kurulum sırasında TV bağlantısı koptu.
    case connectionLost
}

/// Kurulum hatası ve TV'nin verdiği sebep (luna yanıtındaki errorText/reason ya da komut çıktısı).
public struct DevModeFailure: Error, Equatable, CustomStringConvertible {
    public let error: DevModeError
    public let detail: String

    public init(_ error: DevModeError, detail: String) {
        self.error = error
        self.detail = detail
    }

    public var description: String { "\(error): \(detail)" }
}

/// TV uygulamasını LG'nin geliştirici modu üzerinden kurar ve günceller.
/// Geliştirici modu açık TV 9922 portunda SSH bekler; anahtar Key Server'dan bir kez alınır.
public struct DevModeInstaller: Sendable {
    public static let port: UInt16 = 9922
    static let appInfoPath = "/media/developer/apps/usr/palm/applications/com.couchsubs.tv/appinfo.json"
    static let tempDir = "/media/developer/temp"
    static let installLog = "\(tempDir)/couchsubs-install.log"

    /// ares-install gibi paket TV'ye kendi adıyla yüklenir (`/media/developer/temp/com.couchsubs.tv_0.9.6_all.ipk`).
    static func remotePackage(_ package: URL) -> String { "\(tempDir)/\(package.lastPathComponent)" }

    private let host: String
    private let keyFile: URL
    private let runner: CommandRunning
    private let pollInterval: Duration
    private let installTimeout: Duration
    private let verifyTimeout: Duration?

    /// - Parameters:
    ///   - installTimeout: TV'nin kurulum sonucunu (installed ya da hata) bekleme süresi.
    ///   - verifyTimeout: Sonuçtan sonra sürümün appinfo.json'da görünmesini bekleme süresi (nil: 30 sn, sonuç yoksa 60 sn).
    public init(host: String, keyFile: URL, runner: CommandRunning,
                pollInterval: Duration = .seconds(2), installTimeout: Duration = .seconds(180), verifyTimeout: Duration? = nil) {
        self.host = host
        self.keyFile = keyFile
        self.runner = runner
        self.pollInterval = pollInterval
        self.installTimeout = installTimeout
        self.verifyTimeout = verifyTimeout
    }

    // MARK: - Sürümler

    /// `com.couchsubs.tv_0.6.1_all.ipk` → `0.6.1`
    public static func version(ofPackage name: String) -> String? {
        let parts = name.split(separator: "_")
        guard name.hasSuffix(".ipk"), parts.count >= 3 else { return nil }
        return String(parts[1])
    }

    public static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    static func version(fromAppInfo text: String) -> String? {
        guard let found = text.range(of: #""version"\s*:\s*"[^"]+""#, options: .regularExpression) else { return nil }
        return text[found].split(separator: "\"").last.map(String.init)
    }

    // MARK: - Geliştirici modu

    /// TV'de geliştirici modu açık mı? Kapalıysa port yanıt vermez.
    public static func isDevModeOn(host: String, timeout: Duration = .seconds(2)) async -> Bool {
        await isPortOpen(host: host, port: port, timeout: timeout)
    }

    /// TCP portu bağlantı kabul ediyor mu? Samsung (26101) ve Android TV (5555) geliştirici modları için de kullanılır.
    public static func isPortOpen(host: String, port: UInt16, timeout: Duration = .seconds(2)) async -> Bool {
        guard !host.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let once = Once { result in
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.fire(true)
                case .failed, .waiting: once.fire(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            Task {
                try? await Task.sleep(for: timeout)
                once.fire(false)
            }
        }
    }

    static func keyURL(host: String) -> URL { URL(string: "http://\(host):9991/webos_rsa")! }

    /// Key Server'dan anahtarı alır ve TV ekranındaki parolayla çözer.
    public static func fetchKey(host: String, passphrase: String, runner: CommandRunning) async throws -> String {
        var request = URLRequest(url: keyURL(host: host))
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { throw DevModeError.keyServerOff }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw DevModeError.installFailed
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await runner.run("/usr/bin/ssh-keygen", ["-q", "-p", "-P", passphrase, "-N", "", "-f", file.path], input: nil)
        guard result.status == 0, let key = try? String(contentsOf: file, encoding: .utf8) else { throw DevModeError.wrongPassphrase }
        return key
    }

    // MARK: - Kurulum

    /// TV'deki sürüm; uygulama kurulu değilse nil.
    public func installedVersion() async throws -> String? {
        let result = try await ssh("cat \(Self.appInfoPath)")
        return Self.version(fromAppInfo: result.output)
    }

    /// Paketi TV'ye yükler ve ares-install'un yaptığı gibi kurar: kurulum aboneliği TV "installed" ya da hata diyene kadar
    /// açık kalır, paket ancak bundan sonra silinir. Eskiden `luna-send -n 1` ilk yanıttan sonra çıkıyordu; abonelik
    /// kapanınca bazı webOS sürümleri kurulumu yarıda bırakıyor, biz de sürüm görünmeyince "boş alan" hatası veriyorduk.
    /// Hata `DevModeFailure` olarak gelir; `detail` TV'nin verdiği sebeptir.
    public func install(package: URL, version: String) async throws {
        let remote = Self.remotePackage(package)
        // Önceki denemelerden kalan paketler TV'de yer kaplamasın.
        let upload = try await ssh(
            "mkdir -p \(Self.tempDir) && rm -f \(Self.tempDir)/com.couchsubs.tv_*.ipk \(Self.tempDir)/couchsubs.ipk && cat > '\(remote)'",
            input: package)
        guard upload.status == 0 else {
            throw Self.failure("yükleme çıkış kodu \(upload.status): \(Self.short(upload.output))", evidence: upload.output)
        }

        let wait = max(1, Int((Double(installTimeout.components.seconds) + Double(installTimeout.components.attoseconds) / 1e18).rounded(.up)))
        let response = try await ssh(Self.installCommand(remotePackage: remote, waitSeconds: wait))
        let outcome = Self.parseInstallReplies(response.output)
        if outcome.failed {
            _ = try? await ssh("rm -f '\(remote)'")
            let reason = outcome.reason.flatMap { $0.isEmpty ? nil : $0 } ?? "kurulum başarısız: \(Self.short(response.output))"
            throw Self.failure(reason, evidence: response.output)
        }

        // TV "installed" dese de (ya da sonucu okunamadıysa) sürüm appinfo.json'dan doğrulanır.
        let end = ContinuousClock.now + (verifyTimeout ?? .seconds(outcome.installed ? 30 : 60))
        while true {
            if try await installedVersion() == version {
                _ = try? await ssh("rm -f '\(remote)'")
                return
            }
            if ContinuousClock.now >= end { break }
            try await Task.sleep(for: pollInterval)
        }
        // Sonuç gelmediyse paket silinmez: kurulum TV'de sürüyor olabilir; bir sonraki deneme onu temizler.
        if outcome.installed { _ = try? await ssh("rm -f '\(remote)'") }
        throw DevModeFailure(.installFailed,
                             detail: "TV'de \(version) sürümü görünmedi; kurulum yanıtı (\(response.status)): \(Self.short(response.output))")
    }

    /// TV'de kurulumu başlatan kabuk komutu. `luna-send-pub -i` (ares-install'un kullandığı biçim) girişi açık kaldıkça
    /// aboneliği sürdürür; giriş `sleep`'ten gelir. Yanıtlar dosyaya yazılır; TV "installed" ya da hata dediğinde,
    /// luna-send kendiliğinden çıktığında ya da süre dolduğunda yanıtlar basılır ve luna-send kapatılır. sleep'in
    /// çıkışları SSH kanalına bağlı değildir; oturum onu beklemez.
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

    /// luna-send yanıtlarının sonucu; `reason` TV'nin verdiği sebeptir.
    struct InstallOutcome: Equatable {
        var installed = false
        var failed = false
        var reason: String?
    }

    /// luna-send'in satır satır JSON yanıtlarını ares-install gibi okur: `returnValue: false` ya da `details.state`
    /// içinde FAILED hata, `installed`/`SUCCESS` başarıdır.
    static func parseInstallReplies(_ output: String) -> InstallOutcome {
        var pending = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            pending += line.trimmingCharacters(in: .whitespacesAndNewlines)
            if pending.isEmpty { continue }
            guard pending.hasPrefix("{") else {
                // luna-send'in kendi yazısı (ör. "Error: ..."); ares de JSON olmayanı atlar.
                pending = ""
                continue
            }
            guard let reply = (try? JSONSerialization.jsonObject(with: Data(pending.utf8))) as? [String: Any] else {
                continue // Satır yarım; sonrakiyle birleşir.
            }
            pending = ""
            let details = reply["details"] as? [String: Any]
            let state = text(details?["state"]) ?? ""
            if (reply["returnValue"] as? Bool) == false {
                return InstallOutcome(failed: true, reason: reason(text(reply["errorText"]) ?? text(reply["errorMessage"]),
                                                                    code: text(reply["errorCode"])))
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

    /// TV ya da kabuk yer kalmadığını mı söylüyor?
    static func isStorageProblem(_ text: String) -> Bool {
        text.range(of: #"no space|not enough (free )?(space|storage)|insufficient (free )?(space|storage)|out of space|storage (is )?full|disk (is )?full|ENOSPC|lack of (space|storage)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func failure(_ detail: String, evidence: String) -> DevModeFailure {
        DevModeFailure(isStorageProblem(evidence) || isStorageProblem(detail) ? .notEnoughSpace : .installFailed, detail: detail)
    }

    private static func reason(_ text: String?, code: String?) -> String {
        let reason = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code, !code.isEmpty else { return reason }
        return "\(reason) (errorCode \(code))".trimmingCharacters(in: .whitespaces)
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber where !(number === kCFBooleanTrue || number === kCFBooleanFalse): number.stringValue
        default: nil
        }
    }

    private static func short(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 500 ? trimmed : String(trimmed.prefix(500)) + "…"
    }

    // MARK: - Süreyi uzatma

    static let sessionTokenPath = "/var/luna/preferences/devmode_enabled"

    static func renewURL(token: String) -> URL {
        URL(string: "https://developer.lge.com/secure/ResetDevModeSession.dev?sessionToken=\(token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")!
    }

    static func checkURL(token: String) -> URL {
        URL(string: "https://developer.lge.com/secure/CheckDevModeSession.dev?sessionToken=\(token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")!
    }

    /// Geliştirici modunun 1000 saatlik süresini baştan başlatır (TV'deki Developer Mode uygulamasının EXTEND düğmesi
    /// gibi). Oturum jetonu TV'den okunur ve LG'nin sunucusuna gönderilir; webOS Homebrew'un dev-manager-desktop aracının
    /// yaptığının aynısı. Başarısız olursa nil döner: süre dolmadan kullanıcı TV'den de uzatabilir.
    /// - Returns: Kalan süre (saat); bilinmiyorsa nil.
    public func renewSession(session: URLSession = .shared) async throws -> Int? {
        let token = try await ssh("cat \(Self.sessionTokenPath)").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(" ") else { return nil }
        guard let (renewed, _) = try? await session.data(from: Self.renewURL(token: token)),
              String(decoding: renewed, as: UTF8.self).localizedCaseInsensitiveContains("success") else { return nil }
        guard let (checked, _) = try? await session.data(from: Self.checkURL(token: token)) else { return nil }
        return Self.remainingHours(String(decoding: checked, as: UTF8.self))
    }

    /// LG'nin yanıtındaki kalan süre `999:58:40` (saat:dakika:saniye) biçimindedir.
    static func remainingHours(_ response: String) -> Int? {
        guard let found = response.range(of: #"\d{1,4}:\d{2}:\d{2}"#, options: .regularExpression) else { return nil }
        return Int(response[found].split(separator: ":")[0])
    }

    private func ssh(_ command: String, input: URL? = nil) async throws -> CommandResult {
        let result = try await runner.run("/usr/bin/ssh", [
            "-p", String(Self.port), "-i", keyFile.path,
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "LogLevel=ERROR",
            // TV'nin anahtarı her fabrika ayarında değişir ve eski türdedir.
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
            "prisoner@\(host)", command,
        ], input: input)
        if result.status == 255 {
            throw result.output.contains("Permission denied") ? DevModeError.keyRefused : DevModeError.unreachable
        }
        return result
    }
}

/// Bir sonucu yalnız bir kez bildirir.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var action: ((Bool) -> Void)?
    init(_ action: @escaping (Bool) -> Void) { self.action = action }
    func fire(_ value: Bool) {
        let current = lock.withLock { () -> ((Bool) -> Void)? in
            defer { action = nil }
            return action
        }
        current?(value)
    }
}

#if os(macOS)
/// Komutları `Process` ile çalıştırır (yalnız macOS: iOS'ta başka program çalıştırılamaz, LG kurulumu bu yüzden
/// iPhone/iPad'de yapılamaz).
public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], input: URL?) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}
#endif
