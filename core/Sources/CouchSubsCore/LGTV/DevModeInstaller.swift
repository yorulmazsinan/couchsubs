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
    /// Samsung: TV Tizen 2.4'ten (2016) eski.
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
    /// TV'nin saati geride. Samsung: sertifika ona göre henüz geçerli değil. LG: TV paketi "ipk verified failed"
    /// (errorCode -5) ile reddetti; paketteki dosya tarihleri TV'ye göre gelecekte.
    case tvClockWrong
    /// Samsung: TV, silinmiş eski kopyanın kaydı yüzünden uygulamayı kabul etmiyor ([118, -22]).
    case packageBlocked
    /// Kurulum sırasında TV bağlantısı koptu.
    case connectionLost
    /// TV'de CouchSubs'ın kimliğiyle (Android paket adı, LG uygulama kimliği, Samsung paket kimliği) başka bir uygulama
    /// kurulu; kaldırıp CouchSubs'ı kurmak için kullanıcı onayı gerekir.
    case foreignApp
    /// LG: SSH (9922) bağlanmıyor ama Key Server (9991) yanıt veriyor; geliştirici modu açık görünüyor, TV kurulum
    /// bağlantısını reddediyor (Dev Mode Status açıldıktan sonra TV yeniden başlamamış ya da webOS Hub'lı TV'nin yazılımında
    /// bu kapı kapalı; #200, #1116). iPhone/Android'deki LGUnreachableReason.restartNeeded ile aynı durum ve metin.
    case devConnectionClosed
    /// Kayıtlı adreste TV hiç yanıt vermiyor (kapılar zaman aşımında, adreste cihaz yok) ve TV ağda yeniden aranınca da
    /// bulunamadı (`TVReach`). "Geliştirici modu kapalı" ya da "Key Server kapalı" denmez: TV'de ikisi açık olabilir.
    case tvNotResponding
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
    /// SSH bağlanmayınca Key Server'ın (9991) yanıt verip vermediğine bakar (denemelerde ağa çıkılmaz).
    private let keyServerOpen: @Sendable (String) async -> Bool

    /// - Parameters:
    ///   - installTimeout: TV'nin kurulum sonucunu (installed ya da hata) bekleme süresi.
    ///   - verifyTimeout: Sonuçtan sonra sürümün appinfo.json'da görünmesini bekleme süresi (nil: 30 sn, sonuç yoksa 60 sn).
    public init(host: String, keyFile: URL, runner: CommandRunning,
                pollInterval: Duration = .seconds(2), installTimeout: Duration = .seconds(180), verifyTimeout: Duration? = nil,
                keyServerOpen: @escaping @Sendable (String) async -> Bool = { host in
                    await DevModeInstaller.isPortOpen(host: host, port: DevModeInstaller.keyServerPort, timeout: .milliseconds(1500))
                }) {
        self.keyServerOpen = keyServerOpen
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

    /// Key Server'ın (TV'deki Developer Mode uygulaması) anahtarı verdiği port.
    public static let keyServerPort: UInt16 = 9991

    /// TV'de geliştirici modu açık mı? Kapalıysa portlar yanıt vermez. SSH (9922) ya da Key Server (9991) yanıt verirse
    /// açık sayılır: yalnız SSH'a bakılırken TV'de Key Server ve parola göründüğü halde SSH geç yanıt verince parola alanı
    /// hiç çıkmıyordu (#94).
    public static func isDevModeOn(host: String, timeout: Duration = .seconds(2)) async -> Bool {
        async let ssh = isPortOpen(host: host, port: port, timeout: timeout)
        async let keyServer = isPortOpen(host: host, port: keyServerPort, timeout: timeout)
        let (sshOpen, keyServerOpen) = await (ssh, keyServer)
        return sshOpen || keyServerOpen
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

    /// Adres geçersizse nil (eskiden zorla açılıyordu).
    static func keyURL(host: String) -> URL? { URL(string: "http://\(host):\(keyServerPort)/webos_rsa") }

    /// Key Server'dan anahtarı alır ve TV ekranındaki parolayla çözer.
    public static func fetchKey(host: String, passphrase: String, runner: CommandRunning) async throws -> String {
        guard let url = keyURL(host: host) else { throw DevModeError.unreachable }
        var request = URLRequest(url: url)
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

    /// TV'deki sürüm (kurulu değilse nil). TV'de com.couchsubs.tv kimliğiyle başka bir uygulama varsa (appinfo.json'daki ad
    /// CouchSubs ya da üretici Enmera değil) `DevModeFailure(.foreignApp)` fırlatır: sürümü bizimkinden yüksekse "güncel"
    /// sayılıp o açılıyordu; kullanıcı onaylamadan üstüne kurulmaz. Windows'taki CheckInstalledVersionAsync ile aynı.
    public func checkInstalledVersion() async throws -> String? {
        let info = try await ssh("cat \(Self.appInfoPath)").output
        let version = Self.version(fromAppInfo: info)
        if let version, Self.isForeignAppInfo(info) {
            throw DevModeFailure(.foreignApp, detail: "\"\(Self.appInfoField(info, "title") ?? "")\" (\(Self.appInfoField(info, "vendor") ?? "")) \(version)")
        }
        return version
    }

    /// CouchSubs'ın appinfo.json'ındaki ad ve üretici (tv-webos/appinfo.json).
    static let ourTitle = "CouchSubs", ourVendor = "Enmera"

    /// appinfo.json'daki ad CouchSubs değil ya da üretici Enmera değil. Alan yoksa yabancı sayılmaz.
    static func isForeignAppInfo(_ text: String) -> Bool {
        func differs(_ key: String, _ ours: String) -> Bool {
            guard let value = appInfoField(text, key) else { return false }
            return value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(ours) != .orderedSame
        }
        return differs("title", ourTitle) || differs("vendor", ourVendor)
    }

    static func appInfoField(_ text: String, _ key: String) -> String? {
        guard let found = text.range(of: #""\#(key)"\s*:\s*"[^"]*""#, options: .regularExpression) else { return nil }
        let match = text[found]
        guard let colon = match.firstIndex(of: ":"), let open = match[colon...].firstIndex(of: "\"") else { return nil }
        return String(match[match.index(after: open)..<match.index(before: match.endIndex)])
    }

    /// TV'deki com.couchsubs.tv'yi kaldırır (ares-install --remove'un luna çağrısı); kaldırma TV'de arka planda sürdüğü
    /// için appinfo.json gidene kadar (en çok 20 sn) beklenir. Yalnız kullanıcı "Kaldırıp Kur" deyince çağrılır.
    static let removeCommand =
        "/usr/bin/luna-send-pub -n 1 'luna://com.webos.appInstallService/dev/remove' '{\"id\":\"com.couchsubs.tv\",\"subscribe\":false}'; " +
        "i=0; while [ -f \(appInfoPath) ] && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done"

    /// TV'de açık com.couchsubs.tv'yi kapatır (ares-launch --close'un luna çağrısı) ve webOS'un süreci bırakması için kısa
    /// bekler. beta.89 (LG, Mac): 0.9.81'den 0.9.84'e güncellenen TV'de appinfo.json 0.9.84 diyordu, açık uygulama ise
    /// 0.9.81'in kodunu çalıştırmayı sürdürüyordu: kurulumdan sonra uygulama kapatılmıyordu, açma komutu açık uygulamayı
    /// yalnız öne getiriyor (webOSRelaunch), sayfa diskten yeniden okunmuyordu. Kurulumdan sonra ve çalışan sürüm kurulu
    /// sürümden eskiyse uygulama önce kapatılır, sonra açılır. iPhone, Android ve Windows'taki komutla aynı.
    public static let closeCommand =
        "/usr/bin/luna-send-pub -n 1 'luna://com.webos.applicationManager/closeByAppId' '{\"id\":\"com.couchsubs.tv\"}'; sleep 2"

    /// Uygulamayı kapatır; açık değilse ya da TV reddederse kurulum yine başarılıdır. TV'nin yanıtını döner (günlük için).
    @discardableResult
    public func closeApp() async -> String {
        ((try? await ssh(Self.closeCommand).output) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// - Returns: TV'nin yanıtı (günlük için).
    @discardableResult
    public func removeApp() async throws -> String {
        try await ssh(Self.removeCommand).output.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Paket TV'ye eksiksiz ulaştı mı? (wc yoksa ya da çıktı okunamazsa denetim atlanır; iPhone, Android, Windows aynı.)
        if let expected = (try? FileManager.default.attributesOfItem(atPath: package.path)[.size] as? NSNumber)?.intValue,
           let size = Int(try await ssh("wc -c < '\(remote)'").output.trimmingCharacters(in: .whitespacesAndNewlines)), size != expected {
            throw DevModeFailure(.installFailed, detail: "paket TV'ye eksik ya da bozuk ulaştı: \(size)/\(expected) bayt")
        }

        let wait = max(1, Int((Double(installTimeout.components.seconds) + Double(installTimeout.components.attoseconds) / 1e18).rounded(.up)))
        let response = try await ssh(Self.installCommand(remotePackage: remote, waitSeconds: wait))
        let outcome = Self.parseInstallReplies(response.output)
        if outcome.failed {
            let reason = outcome.reason.flatMap { $0.isEmpty ? nil : $0 } ?? "kurulum başarısız: \(Self.short(response.output))"
            // "ipk verified failed" (-5): TV'nin saati okunur; çok gerideyse kullanıcıya saati düzeltmesi söylenir.
            let verify = Self.isPackageVerifyFailure(reason)
            var clock: String?
            if verify { clock = try? await ssh(Self.clockCommand).output }
            _ = try? await ssh("rm -f '\(remote)'")
            if verify { throw Self.verifyFailure(reason: reason, tvClock: clock, now: Date()) }
            throw Self.failure(reason, evidence: response.output)
        }

        // TV "installed" dese de (ya da sonucu okunamadıysa) sürüm appinfo.json'dan doğrulanır.
        let end = ContinuousClock.now + (verifyTimeout ?? .seconds(outcome.installed ? 30 : 60))
        while true {
            if try await installedVersion() == version {
                _ = try? await ssh("rm -f '\(remote)'")
                // Açık (eski) uygulama kapatılır; sonra açılan uygulama yeni sürümü diskten yükler (bkz. closeCommand).
                await closeApp()
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
        for line in output.deviceLines {
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

    // MARK: - Paket doğrulaması (errorCode -5)

    /// TV'nin saati (UTC, saniye). webOS'un kurulum servisi paketi GNU tar ile açar ve tar'ın her uyarısını hata sayar:
    /// paketteki dosya tarihleri TV'nin saatine göre gelecekteyse kurulum "ipk verified failed" (errorCode -5) ile
    /// reddedilir (LG OLED CX/webOS 5'te ağ saati alınamayınca saat 2020-01-01'e döner). Paket artık tarihleri 2010'a
    /// çekilmiş gelir (scripts/normalize-ipk.py); TV'nin saati yine de günlüğe yazılır ve çok gerideyse kullanıcıya
    /// saati düzeltmesi söylenir. iPhone, Android ve Windows'taki komut, eşik ve ayrıntı metniyle aynı.
    public static let clockCommand = "date +%s"
    /// TV bu kadar saniyeden fazla geride ise sebep saattir.
    public static let maxClockLag = 600

    /// TV paketi doğrulayamadı mı ("ipk verified failed", errorCode -5)?
    public static func isPackageVerifyFailure(_ text: String) -> Bool {
        text.range(of: #"verif|errorCode -5\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// TV'nin saati bu cihazınkinden kaç saniye geride (eksi: ileride); okunamazsa nil.
    public static func clockLag(tvClock: String?, now: Date) -> Int? {
        guard let tv = tvClock.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return nil }
        return Int(now.timeIntervalSince1970) - tv
    }

    /// -5 hatasının ayrıntısı: TV'nin sebebi ve iki saat ("ipk verified failed (errorCode -5); TV saati … UTC, bu cihaz
    /// … UTC (TV 3600 sn geride)"). Saat çok gerideyse ilk değer true (saati düzeltmek gerekir).
    public static func verifyFailureDetail(reason: String, tvClock: String?, now: Date) -> (clockWrong: Bool, detail: String) {
        guard let lag = clockLag(tvClock: tvClock, now: now) else { return (false, "\(reason); TV saati okunamadı") }
        let here = Int(now.timeIntervalSince1970)
        let side = lag >= 0 ? "\(lag) sn geride" : "\(-lag) sn ileride"
        return (lag > maxClockLag, "\(reason); TV saati \(utc(here - lag)) UTC, bu cihaz \(utc(here)) UTC (TV \(side))")
    }

    static func verifyFailure(reason: String, tvClock: String?, now: Date) -> DevModeFailure {
        let result = verifyFailureDetail(reason: reason, tvClock: tvClock, now: now)
        return DevModeFailure(result.clockWrong ? .tvClockWrong : .installFailed, detail: result.detail)
    }

    public static func utc(_ seconds: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
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

    /// SSH (9922) bağlanmadığında atılan hata: Key Server (9991) yanıt veriyorsa `.devConnectionClosed` (TV'nin sebebiyle).
    static func unreachableFailure(keyServerOpen: Bool, output: String) -> Error {
        guard keyServerOpen else { return DevModeError.unreachable }
        let detail = short(output)
        return detail.isEmpty ? DevModeError.devConnectionClosed : DevModeFailure(.devConnectionClosed, detail: detail)
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

    /// Eski webOS sürümlerinin SSH sunucusu (dropbear) yalnız bu anahtar değişimlerini bilir; macOS'un ssh'ı bunları
    /// kendiliğinden önermez ve bağlantı "no matching key exchange method" ile kurulmaz. iPhone (SshClient), Android
    /// (JschShell) ve Windows (SSH.NET) aynı yöntemleri zaten kabul ediyor.
    static let legacyKex = "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1"

    /// `ssh`'a verilen seçenekler ve hedef (komut hariç).
    static func sshArguments(host: String, keyFile: URL, legacyKex: Bool = true) -> [String] {
        var arguments = [
            "-p", String(port), "-i", keyFile.path,
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "LogLevel=ERROR",
            // TV'nin anahtarı her fabrika ayarında değişir ve eski türdedir.
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
        ]
        if legacyKex { arguments += ["-o", Self.legacyKex] }
        return arguments + ["prisoner@\(host)"]
    }

    /// ssh bu seçeneği tanımadı mı (ileride bir macOS bu yöntemleri derlemeden çıkarırsa)? O zaman seçeneksiz denenir.
    static func rejectsLegacyKex(_ result: CommandResult) -> Bool {
        result.status == 255 && result.output.contains("KexAlgorithms")
    }

    /// TV yanıt verdi ama iki taraf ortak bir yöntemde anlaşamadı mı? "TV yanıt vermedi" demek yanıltır; sebep gösterilir.
    static func isNegotiationProblem(_ output: String) -> Bool {
        output.contains("no matching") || output.contains("Unable to negotiate")
    }

    private func ssh(_ command: String, input: URL? = nil) async throws -> CommandResult {
        var result = try await runner.run("/usr/bin/ssh", Self.sshArguments(host: host, keyFile: keyFile) + [command], input: input)
        if Self.rejectsLegacyKex(result) {
            result = try await runner.run("/usr/bin/ssh", Self.sshArguments(host: host, keyFile: keyFile, legacyKex: false) + [command], input: input)
        }
        if result.status == 255 {
            if result.output.contains("Permission denied") { throw DevModeError.keyRefused }
            if Self.isNegotiationProblem(result.output) { throw DevModeFailure(.unreachable, detail: Self.short(result.output)) }
            // SSH kapalı ama Key Server açıksa sorun ağ değil: "TV yanıt vermedi" yerine ne yapılacağı söylenir.
            let keyServer = await keyServerOpen(host)
            throw Self.unreachableFailure(keyServerOpen: keyServer, output: result.output)
        }
        return result
    }
}

/// Bir sonucu yalnız bir kez bildirir.
final class Once: @unchecked Sendable {
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
