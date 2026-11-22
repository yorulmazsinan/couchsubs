// SPDX-License-Identifier: AGPL-3.0-only
// Android'deki tv/samsung (SamsungInstaller.kt, SamsungCertificates.kt, SamsungCsr.kt, SamsungLogin.kt,
// SamsungDiagnostics.kt, SamsungTvInfo.kt) Swift karşılığı. Sertifika uç noktaları, giriş akışı ve hata kodlarının
// anlamları Apps2Samsung'dan (MIT, Patrick Stel); masaüstündeki windows/src/CouchSubs.TvInstall/Samsung ile aynı mantık.

import CouchSubsCore
import Foundation

// MARK: - Ortak

/// Kurulumun ilerleyişi; arayüz her adımı yazar. pairing ve approveOnTV Android TV'nin, key LG'nindir.
enum InstallStep: Equatable, Sendable {
    case connecting, reading, signIn, certificate, signing, installing, uninstalling, launching, pairing, approveOnTV, key, openPlay
}

/// Her adım ve TV'nin bütün yanıtları buraya yazılır (Android'deki tvinstall.log).
final class InstallLog: @unchecked Sendable {
    static let shared = InstallLog(file: TVPaths.root.appendingPathComponent("tvinstall.log"))
    let file: URL
    private let lock = NSLock()

    init(file: URL) { self.file = file }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = "\(format.string(from: Date())) \(line)\n"
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 512 * 1024 {
            try? FileManager.default.removeItem(at: file)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: file)
        }
    }
}

enum TVPaths {
    static let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CouchSubs", isDirectory: true).appendingPathComponent("tv", isDirectory: true)
    static func directory(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
}

enum Versions {
    /// Sayısal karşılaştırma: 0.10.0, 0.9.9'dan yenidir.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for index in 0..<max(x.count, y.count) {
            let left = index < x.count ? x[index] : 0, right = index < y.count ? y[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
    }
}

// MARK: - Hatalar ve tanı

enum SamsungInstallError: Equatable, Sendable {
    /// Geliştirici modu kapalı ya da Host PC IP bu telefonunki değil.
    case unreachable, loginFailed, certificateFailed, tooOld, installFailed, notEnoughSpace, certificateMismatch,
         certificateRejected, tvClockWrong, packageBlocked, connectionLost
}

struct SamsungInstallFailure: Error, CustomStringConvertible {
    let error: SamsungInstallError
    var detail: String?
    var description: String { detail.map { "\(error): \($0)" } ?? "\(error)" }
}

enum SamsungDiagnostics {
    enum Problem { case none, connectionLost, notEnoughSpace, certificateMismatch, certificateRejected, certificateNotYetValid, packageBlocked, incompatible, other }

    static func failed(_ log: String) -> Bool {
        has(log, "install failed") || has(log, "val[fail]") || has(log, "not enough space") || has(log, "download failed[116]") || isConnectionLost(log)
    }

    static func classify(_ log: String) -> Problem {
        guard failed(log) else { return .none }
        if isConnectionLost(log) { return .connectionLost }
        if has(log, "install failed[118, -4]") || has(log, "install failed[118, -19]") || has(log, "install failed[118019]") { return .incompatible }
        if has(log, "download failed[116]") || has(log, "not enough space") { return .notEnoughSpace }
        let certificate = has(log, "install failed[118, -12]") || has(log, "install failed[118012]")
            || has(log, "install failed[118, -11]") || has(log, "install failed[118011]")
        if certificate && has(log, "Check certificate error") && !has(log, "same id and different certificate") {
            return has(log, "not valid yet") ? .certificateNotYetValid : .certificateRejected
        }
        if certificate || has(log, "Author certificate not match") { return .certificateMismatch }
        if has(log, "install failed[118, -22]") || has(log, "install failed[118022]") { return .packageBlocked }
        return .other
    }

    static func removingOldCopyMayHelp(_ problem: Problem) -> Bool { [.certificateMismatch, .packageBlocked, .other].contains(problem) }

    /// İki deneme de sebepsiz (yalın `[118]`) başarısızsa başka biçimde hazırlanmış paket denenir (Tizen 2.x, #638).
    static func alternativeMayHelp(_ first: Problem, _ retry: Problem) -> Bool { first == .other && retry == .other }

    static func toError(_ problem: Problem) -> SamsungInstallError {
        switch problem {
        case .connectionLost: .connectionLost
        case .notEnoughSpace: .notEnoughSpace
        case .certificateMismatch: .certificateMismatch
        case .certificateRejected: .certificateRejected
        case .certificateNotYetValid: .tvClockWrong
        case .packageBlocked: .packageBlocked
        default: .installFailed
        }
    }

    static func summary(_ log: String) -> String {
        let lines = log.deviceLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.isEmpty { return "TV yanıt vermedi" }
        var key: [String] = []
        for line in lines where ["fail", "error", "reason", "not match", "space"].contains(where: { line.localizedCaseInsensitiveContains($0) }) {
            if !key.contains(line) { key.append(line) }
            if key.count == 3 { break }
        }
        let text = key.isEmpty ? lines.suffix(3).joined(separator: " | ") : key.joined(separator: " | ")
        return text.count <= 400 ? text : String(text.prefix(400)) + "…"
    }

    private static func isConnectionLost(_ log: String) -> Bool {
        has(log, "transport connection") || has(log, "connection reset by peer") || has(log, "broken pipe")
    }

    private static func has(_ log: String, _ token: String) -> Bool { log.range(of: token, options: .caseInsensitive) != nil }

    /// `0 vd_applist` çıktısında CouchSubs'ın sürümü; satırlar `---- anahtar = değer ----` biçimindedir.
    static func installedVersion(_ listing: String) -> String? {
        var fields: [String: String] = [:]
        var found: String?
        func flush() {
            let ids = [fields["app_tizen_id"], fields["app_id"]]
            if found == nil, ids.contains(where: isCouchSubs), let version = fields["app_version"], !version.isEmpty { found = version }
            fields.removeAll()
        }
        let pattern = try! NSRegularExpression(pattern: #"^[\s-]*([A-Za-z_]+)\s*=\s*(.*?)[\s-]*$"#)
        for raw in listing.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if !raw.contains("="), raw.contains("----") {
                flush()
                continue
            }
            let range = NSRange(raw.startIndex..., in: raw)
            if let match = pattern.firstMatch(in: raw, range: range),
               let name = Range(match.range(at: 1), in: raw), let value = Range(match.range(at: 2), in: raw) {
                fields[raw[name].lowercased()] = raw[value].trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return found
    }

    private static func isCouchSubs(_ id: String?) -> Bool {
        guard let id = id?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return false }
        return id.caseInsensitiveCompare(SamsungInstaller.appId) == .orderedSame || id.caseInsensitiveCompare(SamsungInstaller.packageId) == .orderedSame
    }
}

// MARK: - TV bilgisi (8001)

/// `http://TV:8001/api/v2/` yanıtı: adı, modeli ve geliştirici modu (açık mı, Host PC IP'si ne).
struct SamsungTvInfo: Equatable, Sendable {
    let name: String?
    let model: String?
    let developerMode: Bool?
    let developerIp: String?
    /// Ekran çözünürlüğü ("3840x2160"; ultra geniş monitörde geniş yüzey için, #886).
    var resolution: String? = nil

    static func parse(_ data: Data) -> SamsungTvInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let device = json["device"] as? [String: Any] else { return nil }
        func text(_ name: String) -> String? {
            let value = (device[name] as? String)?.replacingOccurrences(of: "&quot;", with: "\"").trimmingCharacters(in: .whitespaces)
            return value?.isEmpty == false ? value : nil
        }
        return SamsungTvInfo(name: text("name"), model: text("modelName"),
                             developerMode: text("developerMode").map { $0 == "1" || $0.lowercased() == "true" },
                             developerIp: text("developerIP").flatMap { $0 == "0.0.0.0" ? nil : $0 },
                             resolution: text("resolution"))
    }

    /// Kurulumun eşzamanlı akışı için (bekler, en çok `timeout`); yanıt yoksa nil.
    static func fetchNow(host: String, timeout: TimeInterval = 1.5) -> SamsungTvInfo? {
        guard let url = URL(string: "http://\(host):8001/api/v2/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var reply: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            reply = data
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 0.5) == .success, let reply else { return nil }
        return parse(reply)
    }

    static func fetch(host: String, timeout: TimeInterval = 1.5) async -> SamsungTvInfo? {
        guard let url = URL(string: "http://\(host):8001/api/v2/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return parse(data)
    }
}

// MARK: - Sertifika isteği

enum SamsungCsr {
    static func author(_ key: RsaKey) throws -> Data { Der.pem(try request(key, name(Der.utf8("CouchSubs"), email: nil), extensions: nil)) }

    /// Dağıtıcı isteği: CN=TizenSDK; TV imzayı yalnız kendi DUID'i sertifikada yazılıysa kabul eder.
    static func distributor(_ key: RsaKey, duid: String, email: String) throws -> Data {
        let names = Der.sequence(Der.ia5("URN:tizen:packageid=", tag: 0x86), Der.ia5("URN:tizen:deviceid=\(duid)", tag: 0x86))
        let extensionValue = Der.sequence(Der.oid("2.5.29.17"), Der.octets(names))
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return Der.pem(try request(key, name(Der.utf8("TizenSDK"), email: trimmed.isEmpty ? nil : trimmed), extensions: Der.sequence(extensionValue)))
    }

    private static func name(_ commonName: [UInt8], email: String?) -> [UInt8] {
        let cn = Der.set(Der.sequence(Der.oid("2.5.4.3"), commonName))
        guard let email else { return Der.sequence(cn) }
        return Der.sequence(cn, Der.set(Der.sequence(Der.oid("1.2.840.113549.1.9.1"), Der.ia5(email))))
    }

    private static func request(_ key: RsaKey, _ subject: [UInt8], extensions: [UInt8]?) throws -> [UInt8] {
        let attributes = extensions.map { Der.tlv(0xA0, Der.sequence(Der.oid("1.2.840.113549.1.9.14"), Der.set($0))) } ?? Der.tlv(0xA0, [])
        let info = Der.sequence(Der.integer(0), subject, key.subjectPublicKeyInfo, attributes)
        let signature = try key.sign(.rsaSignatureMessagePKCS1v15SHA256, Data(info))
        return Der.sequence(info, Der.sequence(Der.oid("1.2.840.113549.1.1.11"), Der.null), Der.bits(Array(signature)))
    }
}

// MARK: - Sertifikalar

struct SamsungAccount: Sendable {
    let accessToken: String
    let userId: String
    let email: String
}

/// Bir TV için imza dosyaları: anahtar (PKCS#1) ve sertifikalar (DER), uygulamanın kendi klasöründe.
struct SigningProfile {
    let directory: URL
    var keyFile: URL { directory.appendingPathComponent("key.der") }
    var authorFile: URL { directory.appendingPathComponent("author.cer") }
    var distributorFile: URL { directory.appendingPathComponent("distributor.cer") }
    var deviceProfileFile: URL { directory.appendingPathComponent("device-profile.xml") }
    private var duidFile: URL { directory.appendingPathComponent("duid.txt") }

    var exists: Bool { [keyFile, authorFile, distributorFile].allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }

    func privateKey() throws -> RsaKey { try RsaKey(pkcs1: Data(contentsOf: keyFile)) }
    func author() throws -> TVCertificate { try TVCertificate(Data(contentsOf: authorFile)) }
    func distributor() throws -> TVCertificate { try TVCertificate(Data(contentsOf: distributorFile)) }

    /// Sertifikalar bir gün pay bırakılarak hâlâ geçerli mi?
    func isValid(now: Date = Date()) -> Bool {
        guard exists, let author = try? author(), let distributor = try? distributor() else { return false }
        let margin = now.addingTimeInterval(86_400)
        return [author, distributor].allSatisfy { $0.notBefore <= margin && $0.notAfter >= margin }
    }

    func isFor(_ duid: String) -> Bool {
        guard let text = try? String(contentsOf: duidFile, encoding: .utf8) else { return !FileManager.default.fileExists(atPath: duidFile.path) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == duid
    }

    func describe(_ duid: String) -> String {
        guard exists else { return "yok" }
        guard let author = try? author(), let distributor = try? distributor() else { return "okunamadı" }
        let state = !isFor(duid) ? "başka TV'nin" : isValid() ? "geçerli" : "süresi dolmuş"
        return "\(state); yazar \(author.notBefore)–\(author.notAfter), dağıtıcı \(distributor.notBefore)–\(distributor.notAfter), veren \(distributor.summary)"
    }

    func save(key: RsaKey, author: Data, distributor: Data, deviceProfile: Data, duid: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try key.pkcs1().write(to: keyFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try author.write(to: authorFile)
        try distributor.write(to: distributorFile)
        try deviceProfile.write(to: deviceProfileFile)
        try Data(duid.utf8).write(to: duidFile)
    }

    /// TV'nin reddettiği sertifikayı bir kenara koyar; bir sonraki kurulum yenisini ister.
    func discard() {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = directory.deletingLastPathComponent().appendingPathComponent("\(directory.lastPathComponent).rejected-\(stamp)")
        if (try? FileManager.default.moveItem(at: directory, to: target)) == nil { try? FileManager.default.removeItem(at: directory) }
    }
}

/// Samsung'dan TV'ye özel imza sertifikası alır (Tizen Studio'nun Certificate Manager'ı gibi).
struct SamsungCertificates {
    static let authorURL = "https://svdca.samsungqbe.com/apis/v3/authors"
    static let distributorProfileURL = "https://svdca.samsungqbe.com/apis/v1/distributors"
    static let distributorURL = "https://svdca.samsungqbe.com/apis/v3/distributors"
    let log: InstallLog

    /// Samsung'un geliştirici sertifikalarını veren ara sertifikalar (Tizen Studio'dan, uygulamayla gelir).
    static let authorities: [TVCertificate] = ["vd_tizen_dev_author_ca", "author_ca", "vd_tizen_dev_public2", "public2"].compactMap { name in
        guard let url = TVPackages.directory?.appendingPathComponent("samsung-ca/\(name).pem"), let data = try? Data(contentsOf: url) else { return nil }
        return try? TVCertificate(data)
    }

    /// İmzadaki zincir: yaprak ve onu veren Samsung ara sertifikası (kök yok).
    static func chain(_ leaf: TVCertificate) -> [TVCertificate] {
        let issuer = authorities.first { $0.normalizedSubject != nil && $0.normalizedSubject == leaf.normalizedIssuer && $0.normalizedSubject != $0.normalizedIssuer }
        return [leaf] + (issuer.map { [$0] } ?? [])
    }

    static func serverError(_ body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let parts = ["code", "errorCode", "error", "message", "errorMessage", "error_description"].compactMap { name -> String? in
                guard let value = json[name], value is String || value is NSNumber else { return nil }
                return "\(name)=\(value)"
            }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        return text.count <= 300 ? text : String(text.prefix(300)) + "…"
    }

    func create(duid: String, account: SamsungAccount, profile: SigningProfile) throws -> SigningProfile {
        let key = try RsaKey.generate()
        let authorCsr = try SamsungCsr.author(key)
        let distributorCsr = try SamsungCsr.distributor(key, duid: duid, email: account.email)
        let author = try post(Self.authorURL, body(account, authorCsr, "author.csr", distributor: false))
        let deviceProfile = try post(Self.distributorProfileURL, body(account, distributorCsr, "distributor.csr", distributor: true))
        let distributor = try post(Self.distributorURL, body(account, distributorCsr, "distributor.csr", distributor: true))
        try profile.save(key: key, author: try issued(author, "yazar").der, distributor: try issued(distributor, "dağıtıcı").der,
                         deviceProfile: deviceProfile, duid: duid)
        return profile
    }

    private func body(_ account: SamsungAccount, _ csr: Data, _ fileName: String, distributor: Bool) -> Multipart {
        var multipart = Multipart()
        multipart.field("access_token", account.accessToken)
        multipart.field("user_id", account.userId)
        multipart.field("platform", "VD")
        if distributor {
            multipart.field("privilege_level", "public")
            multipart.field("developer_type", "Individual")
        }
        multipart.file("csr", fileName, csr)
        return multipart
    }

    private func post(_ address: String, _ body: Multipart) throws -> Data {
        let url = URL(string: address)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.build()
        let done = DispatchSemaphore(value: 0)
        var reply: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: request) { data, response, error in
            reply = (data, response, error)
            done.signal()
        }.resume()
        done.wait()
        if let error = reply.2 {
            log.write("Sertifika sunucusuna ulaşılamadı (\(url.path)): \(error)")
            throw SamsungInstallFailure(error: .certificateFailed, detail: "Samsung'un sertifika sunucusuna (\(url.host ?? "")) ulaşılamadı: \(error.localizedDescription)")
        }
        let status = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
        let data = reply.0 ?? Data()
        log.write("Sertifika sunucusu \(url.path): \(status), \(data.count) bayt")
        guard (200...299).contains(status) else {
            let text = Self.serverError(data)
            log.write("Sertifika sunucusunun yanıtı: \(text)")
            throw SamsungInstallFailure(error: .certificateFailed, detail: "Samsung sertifika sunucusu \(url.path): \(status) \(text)")
        }
        return data
    }

    private func issued(_ data: Data, _ kind: String) throws -> TVCertificate {
        do {
            return try TVCertificate(data)
        } catch {
            let text = Self.serverError(data)
            log.write("Samsung'un \(kind) sertifikası okunamadı; yanıt: \(text)")
            throw SamsungInstallFailure(error: .certificateFailed, detail: "Samsung \(kind) sertifikası vermedi: \(text)")
        }
    }
}

struct Multipart {
    let boundary = "couchsubs-" + UUID().uuidString
    private var out = Data()
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        head("Content-Disposition: form-data; name=\"\(name)\"\r\nContent-Type: text/plain; charset=utf-8")
        out.append(Data(value.utf8))
        out.append(Data("\r\n".utf8))
    }

    mutating func file(_ name: String, _ fileName: String, _ data: Data) {
        head("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream")
        out.append(data)
        out.append(Data("\r\n".utf8))
    }

    private mutating func head(_ headers: String) { out.append(Data("--\(boundary)\r\n\(headers)\r\n\r\n".utf8)) }

    func build() -> Data { out + Data("--\(boundary)--\r\n".utf8) }
}

// MARK: - Samsung girişi

/// Samsung hesabıyla giriş: SignInGate sayfası jetonu `http://localhost:4794/signin/callback`'e POST eder; bu adresi
/// uygulamanın içindeki küçük dinleyici karşılar (Tizen Studio ve masaüstü de aynı yolu kullanır).
enum SamsungLogin {
    static let callbackPort: UInt16 = 4794
    static let callbackPath = "/signin/callback"
    private static let state = "accountcheckdogeneratedstatetext"

    static var authorizeURL: URL {
        let redirect = "http://localhost:\(callbackPort)\(callbackPath)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "https://account.samsung.com/accounts/be1dce529476c1a6d407c4c7578c31bd/signInGate?locale=&clientId=v285zxnl3h"
            + "&redirect_uri=\(redirect)&state=\(state)&tokenType=TOKEN")!
    }

    /// Gövde: `code=<JSON>&state=…`; JSON'da access_token, userId ve inputEmailID.
    static func parseCallback(_ body: String) -> SamsungAccount? {
        var stateValue: String?
        var code: String?
        for part in body.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == "state" { stateValue = decodeForm(pair[1]) }
            // '+' boşluğa çevrilmez (masaüstündeki Uri.UnescapeDataString gibi).
            if pair[0] == "code" { code = pair[1].removingPercentEncoding ?? pair[1] }
        }
        guard stateValue == state, let code, !code.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(code.utf8)) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty, let user = json["userId"] as? String, !user.isEmpty else { return nil }
        return SamsungAccount(accessToken: token, userId: user, email: json["inputEmailID"] as? String ?? "")
    }

    static func callbackProblem(_ body: String) -> String {
        let text = body.split(separator: "&").map { part -> String in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            let name = decodeForm(pair[0])
            return ["error", "error_description", "error_code", "state"].contains(name) ? "\(name)=\(decodeForm(pair.count > 1 ? pair[1] : ""))" : name
        }.joined(separator: ", ")
        return String(text.prefix(200))
    }

    private static func decodeForm(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }

    /// Geri dönüşü bekleyen dinleyici; yalnız 127.0.0.1'den bağlanılır. `close()` beklemeyi bitirir.
    final class Listener: @unchecked Sendable {
        private var fd: Int32 = -1
        private let lock = NSLock()
        private var cancelled = false

        init() throws {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SamsungInstallFailure(error: .loginFailed, detail: "soket açılamadı") }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = callbackPort.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(fd, 4) == 0 else {
                let reason = String(cString: strerror(errno))
                Darwin.close(fd)
                throw SamsungInstallFailure(error: .loginFailed, detail: "giriş dönüşü için localhost:\(callbackPort) açılamadı: \(reason)")
            }
        }

        func await(timeout: TimeInterval) throws -> SamsungAccount {
            defer { close() }
            let deadline = Date().addingTimeInterval(timeout)
            var rejected: String?
            while Date() < deadline {
                lock.lock()
                let current = fd, stopped = cancelled
                lock.unlock()
                if stopped || current < 0 { throw SamsungInstallFailure(error: .loginFailed, detail: "giriş iptal edildi") }
                var poller = pollfd(fd: current, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 500) > 0 else { continue }
                let client = accept(current, nil, nil)
                guard client >= 0 else { continue }
                defer { Darwin.close(client) }
                var timeout = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var yes: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                let (method, path, body) = readRequest(client)
                let isCallback = method == "POST" && path.hasPrefix(callbackPath)
                let account = isCallback ? parseCallback(body) : nil
                if isCallback && account == nil { rejected = callbackProblem(body) }
                respond(client, status: account != nil ? 200 : isCallback ? 400 : 404)
                if let account { return account }
            }
            throw SamsungInstallFailure(error: .loginFailed, detail: "giriş \(Int(timeout / 60)) dakika içinde tamamlanmadı"
                + (rejected.map { "; Samsung'un geri dönüşünde hesap bilgisi yoktu (\($0))" } ?? ""))
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }

        private func readRequest(_ client: Int32) -> (String, String, String) {
            var received: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var headerEnd = -1
            while headerEnd < 0 {
                let count = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, 16_384, 0) }
                if count <= 0 || received.count > 1024 * 1024 { return ("", "", "") }
                received += buffer.prefix(count)
                if received.count >= 4 {
                    for index in 0...(received.count - 4) where received[index] == 13 && received[index + 1] == 10 && received[index + 2] == 13 && received[index + 3] == 10 {
                        headerEnd = index
                        break
                    }
                }
            }
            let head = String(decoding: received[..<headerEnd], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ").map(String.init)
            let length = lines.first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
            var body = Array(received[(headerEnd + 4)...])
            while body.count < length {
                let count = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, 16_384, 0) }
                if count <= 0 { break }
                body += buffer.prefix(count)
            }
            return (request.first ?? "", request.count > 1 ? request[1] : "", String(decoding: body, as: UTF8.self))
        }

        private func respond(_ client: Int32, status: Int) {
            let page = status == 200 ? "<!doctype html><meta charset=utf-8><meta name=viewport content=\"width=device-width\"><title>CouchSubs</title>"
                + "<body style=\"font-family:system-ui;padding:2em\"><h2>Giriş tamam / Signed in</h2><p>CouchSubs'a dönebilirsiniz.<br>You can return to CouchSubs.</p>"
                : "Not found"
            let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : "Not Found"
            let body = Array(page.utf8)
            let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            let bytes = Array(head.utf8) + body
            _ = bytes.withUnsafeBytes { send(client, $0.baseAddress, bytes.count, 0) }
        }
    }
}

// MARK: - Kurulum

/// CouchSubs'ın Samsung TV uygulamasını geliştirici modu açık TV'ye bu telefondan kurar. Çağrılar bloklar.
final class SamsungInstaller {
    static let appId = "CouchSubsT.CouchSubs"
    static let packageId = "CouchSubsT"
    static let minimumTizen = "2.4"
    static let deviceProfileUpTo = "4.0"

    struct Result: Sendable {
        let version: String
        let installed: Bool
    }

    let host: String
    private let profiles: URL
    private let adbKey: () throws -> AdbKey
    private let signIn: (() throws -> SamsungAccount)?
    private let progress: (InstallStep) -> Void
    private let log: InstallLog
    /// Son `vd_applist` okunabildi mi ("CouchSubs yok" ile "bilinmiyor" ayrılsın).
    private var lastListRead = false

    init(host: String, profiles: URL = TVPaths.directory("samsung"), adbKey: @escaping () throws -> AdbKey = { try AdbKey.loadOrCreate(TVPaths.directory("sdb").appendingPathComponent("adbkey")) },
         signIn: (() throws -> SamsungAccount)?, progress: @escaping (InstallStep) -> Void = { _ in }, log: InstallLog = .shared) {
        self.host = host
        self.profiles = profiles
        self.adbKey = adbKey
        self.signIn = signIn
        self.progress = progress
        self.log = log
    }

    static func isTooOld(_ platform: String) -> Bool { !platform.isEmpty && Versions.isNewer(minimumTizen, than: platform) }
    static func needsDeviceProfile(_ platform: String) -> Bool {
        !platform.isEmpty && !isTooOld(platform) && !Versions.isNewer(platform, than: deviceProfileUpTo)
    }
    /// Tizen 2.x'te cihaz profilinin konduğu klasör (Tizen Studio ve Apps2Samsung ile aynı).
    static let legacyDeviceProfileDirectory = "/home/developer"
    /// Cihaz profilinin TV'deki yolu: Tizen 3.0–4.0'da `sdk_toolpath`, Tizen 2.x'te (2016) `/home/developer`. 2.4 TV profili
    /// yalnız orada arar; #71'de çalışan kurulum (Apps2Samsung) oraya gönderiyordu, profili `/opt/usr/apps/tmp`'ye gönderen
    /// her 2.4 kurulumu `install failed[118]` verdi (#890). Windows/Mac ve Android ile aynı.
    static func deviceProfileRemotePath(_ platform: String, toolPath: String) -> String {
        (LegacyTizenPackage.applies(platform) ? legacyDeviceProfileDirectory : toolPath) + "/device-profile.xml"
    }
    /// `0 getduid` yanıtının ilk dolu satırı geçerli DUID ise onu verir. TV satırı CRLF ile bitirebilir
    /// (ör. "XTCK7KNUEHTUM\r\nXTCK7KNUEHTUM"); `split(separator: "\n")` bunu bölmediği için `deviceLines`.
    static func duid(fromGetduid output: String) -> String? {
        let first = output.deviceLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        return isDuid(first) ? first : nil
    }

    static func isDuid(_ text: String) -> Bool { text.range(of: #"^[A-Za-z0-9_\-+=/]{8,}$"#, options: .regularExpression) != nil }
    static func safeName(_ duid: String) -> String { duid.replacingOccurrences(of: #"[^A-Za-z0-9_\-]"#, with: "_", options: .regularExpression) }

    func profile(for duid: String) -> SigningProfile { SigningProfile(directory: profiles.appendingPathComponent(Self.safeName(duid), isDirectory: true)) }

    /// TV'deki sürüm (kurmadan); TV'ye bağlanılamazsa hata.
    func installedVersion() throws -> String? {
        let device = try connect()
        defer { device.close() }
        return readInstalledVersion(device)
    }

    /// Kurulu TV uygulamasını geliştirici bağlantısıyla (sdb, `was_execute`) açar; arka plandaysa öne getirir (bekçi, bkz.
    /// `SamsungLauncher`; Mac ve Windows'taki samsung-open ile aynı). sdb izin sormaz, TV'de bildirim çıkarmaz.
    /// Geliştirici modu kapalıysa ya da Host PC IP başka cihazınsa false.
    func openApp() -> Bool {
        log.write("--- Samsung: TV uygulaması bağlı değil, açılıyor (TV \(host))")
        do {
            let device = try connect()
            defer { device.close() }
            let reply = try device.shell("0 was_execute \(Self.appId)")
            log.write("Uygulama açılıyor: \(reply.trimmingCharacters(in: .whitespacesAndNewlines))")
            return SamsungLauncher.sdbLaunched(reply)
        } catch {
            log.write("Uygulama açılamadı: \(error)")
            return false
        }
    }

    /// TV'deki CouchSubs yoksa ya da `version`'dan eskiyse imzalayıp kurar, sonra açar.
    func ensureInstalled(wgt: () throws -> [UInt8], version: String?) throws -> Result {
        log.write("--- Samsung kurulumu (iPhone) başlıyor: TV \(host), paket \(version ?? "?")")
        do {
            let result = try installCore(wgt: wgt, version: version)
            log.write(result.installed ? "Kurulum tamam." : "TV'de \(result.version) sürümü var; kurulum gerekmedi.")
            return result
        } catch let failure as SamsungInstallFailure {
            log.write("HATA \(failure.error): \(failure.detail ?? "")")
            throw failure
        } catch let error as StreamClosed {
            log.write("Bağlantı koptu: \(error)")
            throw SamsungInstallFailure(error: .connectionLost, detail: error.description)
        } catch let error as ConnectFailed {
            log.write("Bağlantı koptu: \(error)")
            throw SamsungInstallFailure(error: .connectionLost, detail: error.description)
        }
    }

    private func installCore(wgt: () throws -> [UInt8], version: String?) throws -> Result {
        progress(.connecting)
        let device = try connect()
        defer { device.close() }
        progress(.reading)
        let capabilities = try device.capability()
        let platform = capabilities["platform_version"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let toolPath = capabilities["sdk_toolpath"]?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "/opt/usr/apps/tmp"
        log.write("TV: Tizen \(platform.isEmpty ? "?" : platform), sdk_toolpath \(toolPath)")
        if Self.isTooOld(platform) { throw SamsungInstallFailure(error: .tooOld, detail: "Tizen \(platform)") }
        if !platform.isEmpty, Versions.isNewer("5.0", than: platform) { log.write("Tizen \(platform): 2016–2018 TV si, destek deneysel.") }

        let onTv = readInstalledVersion(device)
        // "CouchSubs yok" ile "liste okunamadı" ayrılsın (Tizen 2.x'te okunamayan listede kopya kaldırılmaz).
        let listRead = lastListRead
        if let version, let onTv, !Versions.isNewer(version, than: onTv) {
            launch(device)
            return Result(version: onTv, installed: false)
        }
        log.write(onTv == nil ? "TV'de CouchSubs görünmüyor; kuruluyor." : "TV'de \(onTv!) var, \(version ?? "yeni sürüm") kuruluyor.")

        let duid = try readDuid(device)
        log.write("DUID: \(duid)")
        var profile = profile(for: duid)
        log.write("Kayıtlı sertifika: \(profile.describe(duid))")
        if !profile.isValid() || !profile.isFor(duid) {
            guard let signIn else { throw SamsungInstallFailure(error: .loginFailed, detail: "giriş gerekiyor") }
            progress(.signIn)
            log.write("Samsung hesabıyla giriş bekleniyor.")
            let account = try signIn()
            log.write("Samsung girişi tamam; sertifika isteniyor.")
            progress(.certificate)
            profile = try SamsungCertificates(log: log).create(duid: duid, account: account, profile: profile)
            log.write("Yeni sertifika: \(profile.describe(duid))")
        }

        if Self.needsDeviceProfile(platform) { pushDeviceProfile(device, profile, platform, toolPath) }

        progress(.signing)
        let key = try profile.privateKey()
        // Tizen 2.x (2016): #71'de çalışan paket: o config.xml ve SHA-512 imza (Apps2Samsung'un TizenSdb'si, #890);
        // TV yine yalın [118] derse SHA-256 imzalı yalın paket (#638).
        let legacy = LegacyTizenPackage.applies(platform)
        let author = WgtSigner.Signer(key: key, chain: SamsungCertificates.chain(try profile.author()))
        let distributor = WgtSigner.Signer(key: key, chain: SamsungCertificates.chain(try profile.distributor()))
        let original = try wgt()
        func sign(_ unsigned: [UInt8], digest: WgtSigner.Digest = .sha512) throws -> [UInt8] {
            try WgtSigner.sign(unsigned, author: author, distributor: distributor, digest: digest)
        }
        // 21:9 / 32:9 Samsung monitör: geniş uygulama yüzeyi (#886; TV'lerde ve Tizen 2.x'te paket değişmez).
        var wide = false
        if !legacy {
            let info = SamsungTvInfo.fetchNow(host: host)
            log.write("Ekran: model \(info?.model ?? "?"), çözünürlük \(info?.resolution ?? "?")")
            wide = WideScreenPackage.applies(model: info?.model, resolution: info?.resolution)
            if wide { log.write("Ultra geniş monitör: paket geniş uygulama yüzeyiyle (base_screen_resolution, device-width) kuruluyor (#886).") }
        }
        let signed = try sign(legacy ? LegacyTizenPackage.adapt(original) : wide ? WideScreenPackage.adapt(original) : original)
        if legacy {
            log.write("Tizen \(platform): paketten network.public izni ve ultra geniş ekran ayarı çıkarıldı (#621).")
            log.write("Tizen \(platform): imza SHA-512 ile üretildi (#71'de çalışan paketle aynı).")
        }
        log.write("Paket imzalandı (\(signed.count) bayt).")
        progress(.installing)
        do {
            var lean = false
            try installWithRecovery(device, signed, toolPath, alternative: !legacy ? nil : {
                let package = try sign(LegacyTizenPackage.adapt(original, lean: true), digest: .sha256)
                lean = true
                self.log.write("Tizen \(platform): yalın paket hazırlandı (\(LegacyTizenPackage.leanRemovedNames) de çıkarıldı), imza SHA-256.")
                return ("yalın paket", package)
            }, keepExisting: legacy && (onTv != nil || !listRead))
            if legacy { log.write("Tizen \(platform): \(lean ? "yalın paket SHA-256" : "tam paket SHA-512") imzayla kuruldu.") }
        } catch let failure as SamsungInstallFailure {
            if failure.error == .certificateRejected {
                profile.discard()
                log.write("Kayıtlı sertifika bırakıldı; bir sonraki denemede yenisi alınacak.")
            }
            guard legacy, let onTv else { throw failure }
            // Tizen 2.x: TV'deki kopya (ör. Tizen Studio ile elle kurulmuş) yerinde; yeni paket kurulamadı diye
            // çalışan uygulama "kurulamadı" gösterilmez, o açılır (#638).
            log.write("Tizen \(platform): yeni paket kurulamadı (\(failure.error)); TV'deki CouchSubs \(onTv) korunuyor ve açılıyor.")
            launch(device)
            return Result(version: onTv, installed: false)
        }
        let after = readInstalledVersion(device)
        if let version, let after, Versions.isNewer(version, than: after) {
            throw SamsungInstallFailure(error: .installFailed, detail: "TV kurulumu bitirdi ama TV'de hâlâ \(after) sürümü var (\(version) kurulmalıydı)")
        }
        launch(device)
        return Result(version: after ?? version ?? "", installed: true)
    }

    private func install(_ device: SdbConnection, _ signed: [UInt8], _ toolPath: String) -> String {
        let remote = String(format: "%@/couchsubs-%08x.wgt", toolPath, UInt32.random(in: 0...UInt32.max))
        var output = ""
        do {
            try device.push(signed, to: remote)
            output += "Push complete.\n"
            output += try device.shell("0 vd_appinstall \(Self.appId) \(remote)")
        } catch {
            output += "\ninstall failed: \(error)\n"
        }
        return output
    }

    /// - Parameter alternative: İki deneme de sebepsiz (yalın `[118]`) başarısız olursa çağrılır: başka biçimde hazırlanmış
    ///   paketi adıyla döner; o paketle üçüncü kez denenir.
    /// - Parameter keepExisting: TV'deki kopyaya dokunulmaz (`vd_appuninstall` yok): Tizen 2.x'te TV'de CouchSubs varsa
    ///   ya da liste okunamadıysa. 2016 TV'de Tizen Studio ile elle kurulmuş, çalışan kopya kurtarma adımında silinmesin
    ///   (docs/tv-samsung.md, #638). Sebepsiz `[118]`'de `alternative` yine bir kez denenir.
    private func installWithRecovery(_ device: SdbConnection, _ signed: [UInt8], _ toolPath: String,
                                     alternative: (() throws -> (label: String, package: [UInt8]))? = nil,
                                     keepExisting: Bool = false) throws {
        let output = install(device, signed, toolPath)
        log.write("vd_appinstall çıktısı:\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        let problem = SamsungDiagnostics.classify(output)
        if problem == .none { return }
        log.write("Kurulum başarısız: \(problem)")
        if keepExisting, SamsungDiagnostics.removingOldCopyMayHelp(problem) {
            log.write("TV'de CouchSubs var ya da liste okunamadı (elle kurulmuş olabilir); eski kopya kaldırılmıyor.")
            if problem == .other, let alternative {
                let (label, package) = try alternative()
                let second = install(device, package, toolPath)
                log.write("İkinci deneme (\(label)) vd_appinstall çıktısı:\n\(second.trimmingCharacters(in: .whitespacesAndNewlines))")
                let secondProblem = SamsungDiagnostics.classify(second)
                if secondProblem == .none { return }
                throw SamsungInstallFailure(error: SamsungDiagnostics.toError(secondProblem), detail: SamsungDiagnostics.summary(second))
            }
            throw SamsungInstallFailure(error: SamsungDiagnostics.toError(problem), detail: SamsungDiagnostics.summary(output))
        }
        guard SamsungDiagnostics.removingOldCopyMayHelp(problem) else {
            throw SamsungInstallFailure(error: SamsungDiagnostics.toError(problem), detail: SamsungDiagnostics.summary(output))
        }
        progress(.uninstalling)
        func remove() -> String {
            var removal = ""
            for id in [Self.packageId, Self.appId] {
                removal += "\(id): " + ((try? device.shell("0 vd_appuninstall \(id)").trimmingCharacters(in: .whitespacesAndNewlines)) ?? "?") + "\n"
            }
            return removal
        }
        log.write("Eski kopya kaldırıldı mı:\n\(remove())")
        let retry = install(device, signed, toolPath)
        log.write("İkinci deneme vd_appinstall çıktısı:\n\(retry.trimmingCharacters(in: .whitespacesAndNewlines))")
        let retryProblem = SamsungDiagnostics.classify(retry)
        if retryProblem == .none { return }
        // TV iki kez de sebep söylemediyse (yalın [118]) ve başka biçimde hazırlanabilen paket varsa onunla bir kez daha.
        if SamsungDiagnostics.alternativeMayHelp(problem, retryProblem), let alternative {
            let (label, package) = try alternative()
            log.write("Eski kopya kaldırıldı mı:\n\(remove())")
            let last = install(device, package, toolPath)
            log.write("Üçüncü deneme (\(label)) vd_appinstall çıktısı:\n\(last.trimmingCharacters(in: .whitespacesAndNewlines))")
            let lastProblem = SamsungDiagnostics.classify(last)
            if lastProblem == .none { return }
            throw SamsungInstallFailure(error: SamsungDiagnostics.toError(lastProblem), detail: SamsungDiagnostics.summary(last))
        }
        throw SamsungInstallFailure(error: SamsungDiagnostics.toError(retryProblem), detail: SamsungDiagnostics.summary(retry))
    }

    private func readInstalledVersion(_ device: SdbConnection) -> String? {
        lastListRead = false
        guard let listing = try? device.shell("0 vd_applist") else {
            log.write("vd_applist okunamadı")
            return nil
        }
        lastListRead = true
        let version = SamsungDiagnostics.installedVersion(listing)
        log.write("vd_applist: \(version.map { "CouchSubs \($0)" } ?? "CouchSubs yok") (\(listing.count) karakter)")
        return version
    }

    private func launch(_ device: SdbConnection) {
        progress(.launching)
        let output = (try? device.shell("0 was_execute \(Self.appId)")) ?? "açılamadı"
        log.write("Uygulama açılıyor: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// Tizen 2.4–4.0: cihaz profili TV'ye gönderilir (`deviceProfileRemotePath`); Tizen 2.x'te `/home/developer`'a
    /// gönderilemezse `sdk_toolpath` denenir.
    private func pushDeviceProfile(_ device: SdbConnection, _ profile: SigningProfile, _ platform: String, _ toolPath: String) {
        guard let data = try? Data(contentsOf: profile.deviceProfileFile) else {
            log.write("Cihaz profili (device-profile.xml) yok; gönderilmeden kuruluyor.")
            return
        }
        let remote = Self.deviceProfileRemotePath(platform, toolPath: toolPath)
        let fallback = "\(toolPath)/device-profile.xml"
        for target in remote == fallback ? [remote] : [remote, fallback] {
            do {
                try device.push(Array(data), to: target)
                log.write("Cihaz profili gönderildi: \(target)")
                return
            } catch {
                log.write("Cihaz profili gönderilemedi (\(target)): \(error)")
            }
        }
    }

    private func connect() throws -> SdbConnection {
        do {
            let connection = try SdbConnection.connect(host: host, key: try adbKey())
            log.write("sdb bağlantısı kuruldu (\(host):\(SdbConnection.port)).")
            return connection
        } catch let failure as SamsungInstallFailure {
            throw failure
        } catch {
            throw SamsungInstallFailure(error: .unreachable, detail: "sdb \(host):\(SdbConnection.port): \(error)")
        }
    }

    private func readDuid(_ device: SdbConnection) throws -> String {
        var last = ""
        for _ in 0..<3 {
            last = (try? device.shell("0 getduid")) ?? ""
            if let duid = Self.duid(fromGetduid: last) { return duid }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw SamsungInstallFailure(error: .unreachable, detail: "TV kimliği (DUID) okunamadı; TV'nin yanıtı: \(last.isEmpty ? "boş" : last)")
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
