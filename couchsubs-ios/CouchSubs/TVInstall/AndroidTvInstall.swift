// SPDX-License-Identifier: AGPL-3.0-only
// Android'deki tv/android (AdbConnection.kt, AdbTls.kt, AdbPairing.kt, AndroidTvInstaller.kt) Swift karşılığı.
// Protokol: AOSP packages/modules/adb (protocol.txt, pairing_connection). Google'ın adb aracı dağıtılmaz.

import CryptoKit
import CouchSubsCore
import Foundation

enum AndroidInstallError: Equatable, Sendable {
    /// TV yanıt vermedi ya da ağ hata ayıklaması kapalı.
    case unreachable
    /// TV'de "hata ayıklamaya izin verilsin mi" sorusu onaylanmadı.
    case notApproved
    /// Kablosuz hata ayıklama portu bu telefonu tanımıyor: önce eşleme kodu ile eşlenmeli.
    case notPaired
    case pairingFailed
    /// TV'deki kopya başka anahtarla imzalı (ör. Google Play'den); kullanıcı onaylarsa kaldırılır.
    case replaceNeeded
    case notEnoughSpace, installFailed, connectionLost, packageMissing
    /// TV'de com.couchsubs.tv adıyla başka bir uygulama kurulu (imza sertifikası bizim değil); kullanıcı onaylamadan
    /// kaldırılmaz.
    case foreignApp
}

struct AndroidInstallFailure: Error, CustomStringConvertible {
    let error: AndroidInstallError
    var detail: String?
    var installedFromPlay = false
    var description: String { detail.map { "\(error): \($0)" } ?? "\(error)" }
}

/// ADB istemcisi: bağlantı, RSA kimlik doğrulama (TV'de onay sorusu), kablosuz hata ayıklamada TLS ve kanallar.
final class AdbConnection: WireConnection {
    static let defaultPort: UInt16 = 5555
    static let keyName = "couchsubs@iphone"
    private var relay: LoopbackRelay?
    private var tls: TLSStream?
    var secure: Bool { tls != nil }

    /// - Parameter onApprovalNeeded: TV bu telefonu ilk kez görüyor; ekranda onay sorusu çıktı. Hata atarsa vazgeçilir.
    static func connect(host: String, port: UInt16, key: AdbKey, onApprovalNeeded: () throws -> Void = {},
                        approvalTimeout: TimeInterval = 90, connectTimeout: TimeInterval = 5) throws -> AdbConnection {
        let socket: PosixSocket
        do {
            socket = try PosixSocket.connect(host: host, port: port, timeout: connectTimeout)
        } catch {
            throw AndroidInstallFailure(error: .unreachable, detail: "\(host):\(port): \(error)")
        }
        let connection = AdbConnection(stream: socket, checkSum: false, firstLocalId: 0)
        do {
            try connection.handshake(key, onApprovalNeeded, approvalTimeout)
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    private func handshake(_ key: AdbKey, _ onApprovalNeeded: () throws -> Void, _ approvalTimeout: TimeInterval) throws {
        stream.readTimeout = 10
        let offered = 256 * 1024
        try send(WireFrame(command: WireFrame.cnxn, arg0: 0x0100_0001, arg1: UInt32(offered), payload: Array("host::\u{0}".utf8)))
        var signed = false
        var waiting = false
        while true {
            let packet: WireFrame
            do {
                packet = try WireFrame.read(reader, checkSum: false, maxPayload: 1024 * 1024)
            } catch {
                let kind: AndroidInstallError = tls != nil ? .notPaired : waiting ? .notApproved : .unreachable
                throw AndroidInstallFailure(error: kind, detail: "\(error)")
            }
            switch packet.command {
            case WireFrame.cnxn:
                maxData = min(offered, packet.arg1 == 0 ? 4096 : Int(packet.arg1))
                output.readTimeout = 120
                return
            case WireFrame.stls:
                // Kablosuz hata ayıklama: TV yalnız eşleştirmede öğrendiği anahtarın sertifikasını kabul eder.
                try send(WireFrame(command: WireFrame.stls, arg0: 0x0100_0000, arg1: 0))
                do {
                    let identity = try TLSIdentity.make(key: key.key, certificateFile: key.certificateFile)
                    let relay = try LoopbackRelay(upstream: stream, leftover: reader.leftover)
                    let session = try TLSStream(host: "127.0.0.1", port: relay.port, identity: identity)
                    self.relay = relay
                    tls = session
                    reader = StreamReader(session)
                    output = session
                    session.readTimeout = 10
                } catch {
                    throw AndroidInstallFailure(error: .notPaired, detail: "TLS: \(error)")
                }
            case WireFrame.auth where packet.arg0 == 1 && !signed:
                signed = true
                try send(WireFrame(command: WireFrame.auth, arg0: 2, arg1: 0, payload: try key.signAdbToken(packet.payload)))
            case WireFrame.auth where packet.arg0 == 1:
                // İmza tanınmadı: TV bu anahtarı ilk kez görüyor; açık anahtarı gönderince TV kullanıcıya sorar.
                if waiting { throw AndroidInstallFailure(error: .notApproved, detail: "TV anahtarı yine sordu") }
                try onApprovalNeeded()
                try send(WireFrame(command: WireFrame.auth, arg0: 3, arg1: 0, payload: Array((key.publicKeyLine(Self.keyName) + "\u{0}").utf8)))
                waiting = true
                output.readTimeout = approvalTimeout
            default:
                throw AndroidInstallFailure(error: .unreachable, detail: String(format: "beklenmeyen paket %08x", packet.command))
            }
        }
    }

    /// Dosyayı TV'ye gönderir (sync: SEND "yol,kip", DATA…, DONE).
    func push(_ data: [UInt8], to remotePath: String, mode: Int = 0o644) throws {
        let channel = try open("sync:")
        defer { channel.close() }
        try channel.write(syncPacket("SEND", ArraySlice(Array("\(remotePath),\(0o100000 | mode)".utf8))))
        var offset = 0
        while offset < data.count {
            let size = min(64 * 1024, data.count - offset)
            try channel.write(syncPacket("DATA", data[offset..<offset + size]))
            offset += size
        }
        try channel.write(Array("DONE".utf8) + le32(UInt32(Date().timeIntervalSince1970)))
        let header = try channel.readExactly(8)
        let id = String(decoding: header.prefix(4), as: UTF8.self)
        let length = Int(readLE32(header, 4))
        if id == "OKAY" { return }
        let message = id == "FAIL" && (1...4096).contains(length) ? String(decoding: try channel.readExactly(length), as: UTF8.self) : id
        throw ConnectFailed(description: "ADB sync: FAIL: \(message)")
    }

    override func close() {
        tls?.close()
        relay?.close()
        super.close()
    }
}

/// Android 11+ "Cihazı eşleme kodu ile eşle" (AOSP pairing_connection, pairing_auth): TLS 1.3, SPAKE2, AES-128-GCM.
enum AdbPairing {
    static let exportedKeyLabel = Array("adb-label\u{0}".utf8)
    static let peerInfoSize = 8192

    static func pair(host: String, port: UInt16, code: String, key: AdbKey) throws {
        let identity: SecIdentity
        let tls: TLSStream
        do {
            identity = try TLSIdentity.make(key: key.key, certificateFile: key.certificateFile)
        } catch {
            throw AndroidInstallFailure(error: .pairingFailed, detail: "TLS kimliği: \(error)")
        }
        do {
            tls = try TLSStream(host: host, port: port, identity: identity, timeout: 10)
        } catch {
            throw AndroidInstallFailure(error: .pairingFailed, detail: "TLS: \(error)")
        }
        defer { tls.close() }
        tls.readTimeout = 15
        guard let exported = tls.exportKeyingMaterial(label: exportedKeyLabel, length: 64) else {
            throw AndroidInstallFailure(error: .pairingFailed, detail: "TLS anahtar dışa aktarımı yok")
        }
        let reader = StreamReader(tls)
        let spake = Spake2(alice: true, password: Array(code.trimmingCharacters(in: .whitespaces).utf8) + exported)
        try writePacket(tls, type: 0, spake.message)
        let theirs = try readPacket(reader, type: 0)
        guard let material = spake.finish(theirs) else { throw AndroidInstallFailure(error: .pairingFailed, detail: "geçersiz SPAKE2 mesajı") }
        var cipher = PairingCipher(material)
        var info = [UInt8](repeating: 0, count: peerInfoSize)
        let line = Array(key.publicKeyLine(AdbConnection.keyName).utf8)
        info.replaceSubrange(1..<(1 + min(line.count, peerInfoSize - 1)), with: line.prefix(peerInfoSize - 1))
        try writePacket(tls, type: 1, try cipher.encrypt(info))
        let answer = try readPacket(reader, type: 1)
        guard cipher.decrypt(answer) != nil else { throw AndroidInstallFailure(error: .pairingFailed, detail: "eşleştirme kodu yanlış") }
    }

    static func writePacket(_ stream: ByteStream, type: UInt8, _ payload: [UInt8]) throws {
        try stream.write([1, type] + be32(UInt32(payload.count)) + payload)
    }

    static func readPacket(_ reader: StreamReader, type: UInt8) throws -> [UInt8] {
        let header: [UInt8]
        do {
            header = try reader.readExactly(6)
        } catch {
            throw AndroidInstallFailure(error: .pairingFailed, detail: "TV eşleştirmeyi kapattı: \(error)")
        }
        let length = Int(UInt32(header[2]) << 24 | UInt32(header[3]) << 16 | UInt32(header[4]) << 8 | UInt32(header[5]))
        guard header[0] == 1, header[1] == type, length <= peerInfoSize * 2 else {
            throw AndroidInstallFailure(error: .pairingFailed, detail: "beklenmeyen eşleştirme paketi \(header[0])/\(header[1])/\(length)")
        }
        return try reader.readExactly(length)
    }

    /// adb'nin Aes128Gcm'i: HKDF-SHA256 ("adb pairing_auth aes-128-gcm key"), her yönde 0'dan sayan nonce.
    struct PairingCipher {
        private let key: SymmetricKey
        private var encrypted: UInt64 = 0
        private var decrypted: UInt64 = 0

        init(_ material: [UInt8]) {
            key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: Data(),
                                         info: Data("adb pairing_auth aes-128-gcm key".utf8), outputByteCount: 16)
        }

        private func nonce(_ sequence: UInt64) -> AES.GCM.Nonce {
            var bytes = [UInt8](repeating: 0, count: 12)
            for index in 0..<8 { bytes[index] = UInt8(truncatingIfNeeded: sequence >> (8 * UInt64(index))) }
            return try! AES.GCM.Nonce(data: bytes)
        }

        mutating func encrypt(_ plain: [UInt8]) throws -> [UInt8] {
            let box = try AES.GCM.seal(plain, using: key, nonce: nonce(encrypted))
            encrypted += 1
            return Array(box.ciphertext) + Array(box.tag)
        }

        mutating func decrypt(_ sealed: [UInt8]) -> [UInt8]? {
            guard sealed.count >= 16 else { return nil }
            let current = decrypted
            decrypted += 1
            guard let box = try? AES.GCM.SealedBox(nonce: nonce(current), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16)) else { return nil }
            return (try? AES.GCM.open(box, using: key)).map(Array.init)
        }
    }
}

/// CouchSubs'ın Android TV uygulamasını (com.couchsubs.tv) ağ üzerinden kurar (Android'deki AndroidTvInstaller).
final class AndroidTvInstaller {
    static let packageName = "com.couchsubs.tv"
    private static let tempApk = "/data/local/tmp/couchsubs-tv.apk"

    struct Pairing: Sendable {
        let port: UInt16
        let code: String
    }

    struct Result: Sendable {
        let version: String
        let installed: Bool
    }

    static let playURL = URL(string: "https://play.google.com/store/apps/details?id=\(packageName)")!
    static let openPlayCommand = "shell:am start -a android.intent.action.VIEW -d market://details?id=\(packageName)"

    /// CouchSubs TV Google Play'de herkese açık mı (sayfa 200)? Ağ yoksa ya da sayfa yoksa false. Bloklar.
    static func isListedOnPlay(timeout: TimeInterval = 5) -> Bool {
        var request = URLRequest(url: playURL)
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var listed = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            listed = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return listed
    }

    static func hasPlayStore(_ output: String) -> Bool {
        output.deviceLines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "package:com.android.vending" }
    }

    let host: String
    let port: UInt16
    private let adbKey: () throws -> AdbKey
    private let pairing: Pairing?
    /// Play'de herkese açıksa ve TV'de Play Store varsa uygulama Play'den kurulur.
    private let playListed: () -> Bool
    private let playWait: TimeInterval
    private let playPoll: TimeInterval
    private let progress: (InstallStep) -> Void
    private let log: InstallLog

    init(host: String, port: UInt16, adbKey: @escaping () throws -> AdbKey = { try AdbKey.loadOrCreate(TVPaths.directory("adb").appendingPathComponent("adbkey")) },
         pairing: Pairing? = nil, progress: @escaping (InstallStep) -> Void = { _ in }, log: InstallLog = .shared,
         playListed: @escaping () -> Bool = { AndroidTvInstaller.isListedOnPlay() }, playWait: TimeInterval = 240, playPoll: TimeInterval = 3) {
        self.playListed = playListed
        self.playWait = playWait
        self.playPoll = playPoll
        self.host = host
        self.port = port
        self.adbKey = adbKey
        self.pairing = pairing
        self.progress = progress
        self.log = log
    }

    static func versionFromDumpsys(_ output: String) -> String? { match(#"versionName=(\S+)"#, output) }
    /// dumpsys'teki kullanıcı satırları ("User 0: ceDataInode=… installed=true …"): kullanıcı numarası → kurulu mu.
    private static func usersFromDumpsys(_ output: String) -> [String: Bool] {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*User (\d+):.*?\binstalled=(true|false)\b"#,
                                                   options: .anchorsMatchLines) else { return [:] }
        var users: [String: Bool] = [:]
        for found in regex.matches(in: output, range: NSRange(output.startIndex..., in: output)) {
            guard let user = Range(found.range(at: 1), in: output), let value = Range(found.range(at: 2), in: output) else { continue }
            if users[String(output[user])] == nil { users[String(output[user])] = output[value] == "true" }
        }
        return users
    }

    /// dumpsys sürüm söylüyor ama uygulama TV'nin ana kullanıcısında (User 0) kurulu değil: kaydı kalmış (#352, #389) ya da
    /// TV uygulamayı yalnız ana kullanıcıdan kaldırmış, çocuk/ikincil profilde bırakmış (#528). Kullanıcı satırı yoksa
    /// (eski Android) kalıntı sayılmaz. Android'deki AndroidTvInstaller.isLeftover ile aynıdır.
    static func isLeftover(_ output: String) -> Bool {
        guard versionFromDumpsys(output) != nil else { return false }
        let users = usersFromDumpsys(output)
        guard !users.isEmpty else { return false }
        return users["0"] == false || !users.values.contains(true)
    }
    /// Kalıntı ama APK başka bir profilde kurulu: `pm install-existing --user 0` ile APK göndermeden geri getirilir (#528).
    static func canInstallExisting(_ output: String) -> Bool { isLeftover(output) && usersFromDumpsys(output).values.contains(true) }
    static let installExistingCommand = "shell:pm install-existing --user 0 \(packageName)"
    static func installExistingSucceeded(_ output: String) -> Bool { output.contains("installed for user") }
    /// TV'de kurulu CouchSubs sürümü; yoksa ya da yalnız kaydı kalmışsa nil.
    static func installedVersionFromDumpsys(_ output: String) -> String? { isLeftover(output) ? nil : versionFromDumpsys(output) }
    static func installedFromPlay(_ output: String) -> Bool { match(#"installerPackageName=(\S+)"#, output) == "com.android.vending" }
    static func looksFailed(_ output: String) -> Bool {
        ["Error", "Exception", "Unknown", "not allowed"].contains { output.range(of: $0, options: .caseInsensitive) != nil }
    }
    /// CouchSubs TV'nin imza sertifikasının (CN=CouchSubs TV, O=Enmera; SHA-256 5FFE122E…CBAD0D5FB) dumpsys'te görünen
    /// özeti: Android `Signature.hashCode()` (sertifikanın DER baytlarının `Arrays.hashCode`'u) onaltılık. Play'in uygulama
    /// imza anahtarı da budur, Play'den kurulan kopyada da aynıdır.
    static let ownSignature = "32d37cf9"

    /// dumpsys'teki imza özetleri: `signatures=PackageSignatures{…}` satırındaki ilk `[…]` (yeni biçim
    /// "version:2, signatures:[32d37cf9], past signatures:[]", eski biçim "{41ab21 [32d37cf9]}"). Okunamazsa boş.
    static func signatureHashes(_ output: String) -> [String] {
        guard let line = output.deviceLines.first(where: { $0.contains("signatures=PackageSignatures{") }),
              let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { return [] }
        return line[line.index(after: open)..<close].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// TV'deki com.couchsubs.tv'nin imzası bizim mi (özet okunduysa ve bizimkiyse).
    static func signatureIsOurs(_ output: String) -> Bool { signatureHashes(output).contains(ownSignature) }

    /// TV'de com.couchsubs.tv var ama imzası bizim değil: aynı paket adını kullanan başka bir uygulama. İmza okunamazsa
    /// bilinmiyor sayılır (başka uygulama değil); o zaman TV kurulumda INSTALL_FAILED_UPDATE_INCOMPATIBLE der.
    /// Mac, Windows ve Android'deki denetimle aynı.
    static func isForeign(_ output: String) -> Bool {
        let hashes = signatureHashes(output)
        return versionFromDumpsys(output) != nil && !hashes.isEmpty && !hashes.contains(ownSignature)
    }

    static func needsReplace(_ output: String) -> Bool {
        output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") || output.contains("INSTALL_FAILED_VERSION_DOWNGRADE")
    }
    static func isStorageProblem(_ output: String) -> Bool {
        output.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") || output.range(of: "No space left", options: .caseInsensitive) != nil
    }
    static func streamInstallUnsupported(_ output: String) -> Bool { !output.contains("Success") && !output.contains("Failure") }

    /// "192.168.1.5:37123" → (adres, port); port yoksa `defaultPort`.
    static func parseAddress(_ text: String, defaultPort: UInt16 = AdbConnection.defaultPort) -> (String, UInt16)? {
        // Türkçe klavyeyle yazılan virgüller ("192,168,1,20:41235") noktaya döner; port korunur.
        let value = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !value.isEmpty else { return nil }
        guard let colon = value.lastIndex(of: ":") else { return (value, defaultPort) }
        guard let port = UInt16(value[value.index(after: colon)...]), port > 0 else { return nil }
        let address = value[..<colon].trimmingCharacters(in: .whitespaces)
        return address.isEmpty ? nil : (address, port)
    }

    private static func match(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(found.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// TV'deki sürüm (kurmadan). TV onay sorarsa (bu telefon tanınmıyor) vazgeçilir: sessiz denetim TV'de pencere açmaz.
    func installedVersion() throws -> String? {
        let adb = try AdbConnection.connect(host: host, port: port, key: try adbKey(),
                                            onApprovalNeeded: { throw AndroidInstallFailure(error: .notApproved, detail: "onay gerekiyor") })
        defer { adb.close() }
        return Self.installedVersionFromDumpsys(try adb.run("shell:dumpsys package \(Self.packageName)"))
    }

    /// Uygulama eksikse ya da eskiyse kurar ve açar. `allowReplace`: TV'deki bizim imzalı ama kurulamayan (daha yeni) kopya
    /// kaldırılsın mı. `replaceForeign`: TV'de com.couchsubs.tv adıyla başka bir uygulama varsa kullanıcı onayladı; o
    /// kaldırılıp CouchSubs kurulur.
    func ensureInstalled(apk: () throws -> [UInt8], version: String?, allowReplace: Bool = false, replaceForeign: Bool = false) throws -> Result {
        log.write("--- Android TV kurulumu (iPhone) başlıyor: TV \(host):\(port), paket \(version ?? "?")"
            + (pairing.map { ", eşleme portu \($0.port)" } ?? ""))
        do {
            let result = try installCore(apk: apk, version: version, allowReplace: allowReplace, replaceForeign: replaceForeign)
            log.write(result.installed ? "Kurulum tamam." : "TV'de \(result.version) sürümü var; kurulum gerekmedi.")
            return result
        } catch let failure as AndroidInstallFailure {
            log.write("HATA \(failure.error): \(failure.detail ?? "")")
            throw failure
        } catch {
            log.write("Bağlantı koptu: \(error)")
            throw AndroidInstallFailure(error: .connectionLost, detail: "\(error)")
        }
    }

    private func installCore(apk: () throws -> [UInt8], version: String?, allowReplace: Bool, replaceForeign: Bool) throws -> Result {
        let key = try adbKey()
        if let pairing {
            progress(.pairing)
            try AdbPairing.pair(host: host, port: pairing.port, code: pairing.code, key: key)
            log.write("Eşleme tamam (port \(pairing.port)).")
        }
        progress(.connecting)
        let adb = try AdbConnection.connect(host: host, port: port, key: key, onApprovalNeeded: { [log, progress] in
            log.write("TV bu telefonu ilk kez görüyor; onay bekleniyor.")
            progress(.approveOnTV)
        })
        defer { adb.close() }
        log.write("ADB bağlantısı kuruldu (\(adb.secure ? "TLS" : "düz"), en çok \(adb.maxData) bayt).")
        progress(.reading)
        var dumpsys = try adb.run("shell:dumpsys package \(Self.packageName)")
        if Self.isForeign(dumpsys) {
            // Aynı paket adıyla başka bir uygulama (kalıntısı dahil): onaysız hiçbir şey silinmez, geri de getirilmez.
            let other = "imza \(Self.signatureHashes(dumpsys).joined(separator: ",")), sürüm \(Self.versionFromDumpsys(dumpsys) ?? "?")"
            guard replaceForeign else { throw AndroidInstallFailure(error: .foreignApp, detail: "TV'de aynı paket adıyla başka bir uygulama var: \(other)") }
            progress(.uninstalling)
            log.write("TV'deki başka uygulama kaldırılıyor (kullanıcı onayladı; \(other)): \((try? adb.run("shell:pm uninstall \(Self.packageName)")) ?? "?")")
            dumpsys = try adb.run("shell:dumpsys package \(Self.packageName)")
        }
        let oursConfirmed = Self.signatureIsOurs(dumpsys)
        if Self.canInstallExisting(dumpsys) {
            // TV uygulamayı yalnız ana kullanıcıdan kaldırmış, başka profilde duruyor: APK göndermeden geri getirilir (#528).
            let existing = (try? adb.run(Self.installExistingCommand)) ?? ""
            log.write("CouchSubs TV başka bir profilde kurulu; ana kullanıcıya geri getiriliyor: \(existing.trimmingCharacters(in: .whitespacesAndNewlines))")
            if Self.installExistingSucceeded(existing) { dumpsys = try adb.run("shell:dumpsys package \(Self.packageName)") }
        }
        let installed = Self.installedVersionFromDumpsys(dumpsys)
        let fromPlay = Self.installedFromPlay(dumpsys)
        if Self.isLeftover(dumpsys) { log.write("TV'de CouchSubs'ın kaydı kalmış ama uygulama kurulu değil; yeniden kuruluyor.") }
        log.write("TV'deki CouchSubs: \(installed ?? "yok")\(fromPlay ? " (Google Play'den)" : "")")
        if let installed, let version, !Versions.isNewer(version, than: installed) {
            grantOverlay(adb)
            launch(adb)
            return Result(version: installed, installed: false)
        }
        // CouchSubs TV Play'de ve TV'de Play Store varsa Play'den kurulur/güncellenir (Play kopyası kendiliğinden güncel
        // kalır). Kullanıcı Play sayfasında Yükle'ye basmazsa APK ile kurulur.
        if let result = try installFromPlay(adb, before: installed, fromPlay: fromPlay) { return result }
        progress(.installing)
        let bytes = try apk()
        var output = try install(adb, bytes)
        // İmza tutmuyor (ya da imzası bizim olduğu doğrulanmamış kopya daha yeni): TV'deki uygulama bizim olmayabilir; sessizce
        // kaldırılmaz, aynı "başka uygulama" sorusu sorulur.
        if Self.needsReplace(output), output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") || !oursConfirmed {
            guard replaceForeign else {
                throw AndroidInstallFailure(error: .foreignApp, detail: output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            progress(.uninstalling)
            log.write("TV'deki başka imzalı kopya kaldırılıyor (kullanıcı onayladı): \((try? adb.run("shell:pm uninstall \(Self.packageName)")) ?? "?")")
            progress(.installing)
            output = try install(adb, bytes)
        } else if Self.needsReplace(output) {
            guard allowReplace else {
                throw AndroidInstallFailure(error: .replaceNeeded, detail: output.trimmingCharacters(in: .whitespacesAndNewlines), installedFromPlay: fromPlay)
            }
            progress(.uninstalling)
            log.write("Eski kopya kaldırılıyor (kullanıcı onayladı): \((try? adb.run("shell:pm uninstall \(Self.packageName)")) ?? "?")")
            progress(.installing)
            output = try install(adb, bytes)
        }
        guard output.contains("Success") else {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AndroidInstallFailure(error: Self.isStorageProblem(output) ? .notEnoughSpace : .installFailed, detail: trimmed.isEmpty ? "TV yanıt vermedi" : trimmed)
        }
        grantOverlay(adb)
        let after = Self.installedVersionFromDumpsys((try? adb.run("shell:dumpsys package \(Self.packageName)")) ?? "")
        launch(adb)
        return Result(version: after ?? version ?? "", installed: true)
    }

    /// TV'de Play sayfasını açar ve kurulmasını bekler; olunca izin verip uygulamayı açar. Olmazsa nil: APK ile kurulur.
    private func installFromPlay(_ adb: AdbConnection, before: String?, fromPlay: Bool) throws -> Result? {
        guard playListed() else { return nil }
        if !fromPlay, !Self.hasPlayStore((try? adb.run("shell:pm list packages com.android.vending")) ?? "") {
            log.write("TV'de Play Store yok; APK ile kuruluyor.")
            return nil
        }
        let opened = try adb.run(Self.openPlayCommand)
        log.write("Play sayfası açılıyor: \(opened.trimmingCharacters(in: .whitespacesAndNewlines))")
        if opened.range(of: "Error", options: .caseInsensitive) != nil { return nil }
        progress(.openPlay)
        let deadline = Date().addingTimeInterval(playWait)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: playPoll)
            let now = Self.installedVersionFromDumpsys(try adb.run("shell:dumpsys package \(Self.packageName)"))
            if let now, now != before {
                log.write("Play'den kuruldu: \(now)")
                grantOverlay(adb)
                launch(adb)
                return Result(version: now, installed: true)
            }
        }
        log.write("Play'den \(Int(playWait)) sn içinde kurulmadı; APK ile kuruluyor.")
        return nil
    }

    /// Android 7+: paket yöneticisine akıtılır; olmazsa gönderilip `pm install`.
    private func install(_ adb: AdbConnection, _ apk: [UInt8]) throws -> String {
        let streamed: String
        do {
            streamed = try adb.run("exec:cmd package install -r -S \(apk.count)", input: apk)
        } catch let failure as AndroidInstallFailure {
            throw failure
        } catch {
            streamed = "exec: \(error)"
        }
        log.write("cmd package install çıktısı: \(streamed.trimmingCharacters(in: .whitespacesAndNewlines))")
        if !Self.streamInstallUnsupported(streamed) { return streamed }
        try adb.push(apk, to: Self.tempApk)
        let output = try adb.run("shell:pm install -r \(Self.tempApk)")
        log.write("pm install çıktısı: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        _ = try? adb.run("shell:rm -f \(Self.tempApk)")
        return output
    }

    /// "Diğer uygulamaların üzerinde göster" izni (katman modu); verilemezse kurulum yine başarılıdır.
    private func grantOverlay(_ adb: AdbConnection) {
        var output = (try? adb.run("shell:appops set \(Self.packageName) SYSTEM_ALERT_WINDOW allow")) ?? "Error"
        if Self.looksFailed(output) { output = (try? adb.run("shell:pm grant \(Self.packageName) android.permission.SYSTEM_ALERT_WINDOW")) ?? "Error" }
        log.write("Üstte gösterme izni: \(Self.looksFailed(output) ? "verilemedi (\(output.trimmingCharacters(in: .whitespacesAndNewlines)))" : "verildi")")
    }

    private func launch(_ adb: AdbConnection) {
        progress(.launching)
        log.write("Uygulama açılıyor: \(((try? adb.run(Self.startCommand(launchParams))) ?? "açılamadı").trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// Uygulama açılırken verilecek başlatma parametreleri (`{"server":"http://…"}`); TV telefonu ağda aramadan bağlanır.
    var launchParams: String?

    /// Uygulamayı açan ADB komutu; `launchParams` varsa `--es params '…'` ile (Windows'taki StartCommand ile aynı kural).
    static func startCommand(_ launchParams: String?) -> String {
        let command = "shell:am start -n \(packageName)/.MainActivity"
        // TV'de sh çalıştırır: değer tek tırnak içinde gider; tek tırnak ve satır sonu içeren değer hiç gönderilmez.
        guard let launchParams, !launchParams.isEmpty,
              !launchParams.contains(where: { $0 == "'" || $0.isNewline || $0 == "\0" }) else { return command }
        return "\(command) --es params '\(launchParams)'"
    }

    /// TV'de çalışan CouchSubs'a adresi bildiren yayın (TV uygulamasındaki AddressReceiver): ekranı öne çekmez, görüntü
    /// modunu değiştirmez. Parametre yoksa ya da kabukta güvenle gönderilemiyorsa nil (Windows'taki AddressCommand ile aynı).
    static func addressCommand(_ launchParams: String?) -> String? {
        guard let launchParams, !launchParams.isEmpty,
              !launchParams.contains(where: { $0 == "'" || $0.isNewline || $0 == "\0" }) else { return nil }
        return "shell:am broadcast -a \(packageName).action.ADDRESS -n \(packageName)/.AddressReceiver --es params '\(launchParams)'"
    }

    /// Yalnız sunucu adresi gider; erişim anahtarı gitmez (Android TV kullanıcı onaylı eşleştirmeyle bağlanır).
    static func launchParams(server: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["server": server], options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Kurulu uygulamayı telefonun adresiyle açar (kurmadan, sessizce): TV onay sorarsa vazgeçilir. Bloklar. Uygulama TV'de
    /// zaten çalışıyorsa (ekranı önde ya da arkada, ya da katmanı) `am start` gönderilmez, `AndroidTVApp.alreadyRunning`
    /// döner: `am start` çalışan uygulamayı öne çekiyor, TV uygulaması da parametreli açılışta katmana dönüp ekranı
    /// kapatıyordu (X, Android TV 8, beta.74; Windows ve Android telefonla aynı).
    func open(launchParams: String?, connectTimeout: TimeInterval = 3) throws -> String {
        let adb = try AdbConnection.connect(host: host, port: port, key: try adbKey(),
                                            onApprovalNeeded: { throw AndroidInstallFailure(error: .notApproved, detail: "onay gerekiyor") },
                                            connectTimeout: connectTimeout)
        defer { adb.close() }
        if AndroidTVApp.isRunning((try? adb.run(AndroidTVApp.runningCommand)) ?? "") {
            // Çalışan uygulama telefona bağlı değil (bekçi yalnız o zaman açar): kayıtlı eski bir adrese bağlı kalmış olabilir.
            // Adres ekranı öne çekmeden bildirilir (TV 0.9.63+; eski TV uygulaması yok sayar). Windows/Mac ve Android'le aynı.
            if let address = Self.addressCommand(launchParams) { _ = try? adb.run(address) }
            return AndroidTVApp.alreadyRunning
        }
        return try adb.run(Self.startCommand(launchParams)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Android TV'de CouchSubs TV'yi telefonun adresiyle açar (ADB açıksa). Ne zaman açılacağı `AndroidTVOpenRule`'dadır: bu
/// çeviride bağlanmış uygulama bir daha açılmaz, hiç bağlanmadıysa en çok üç kez, 30 sn arayla; TV'de zaten çalışıyorsa
/// `am start` gönderilmez (Mac, Windows ve Android telefonla aynı kural).
///
/// Eskiden telefon Android TV'ye hiç dokunmuyor, TV uygulaması telefonu ağı (yalnız 8787 portunu) tarayarak bulmak
/// zorunda kalıyordu: TV başka alt ağdaysa, tarama telefonu kaçırırsa ya da telefonun portu değiştiyse "Ağda CouchSubs
/// aranıyor…"da kalıyordu (TestFlight, 20 Kas). Adres verilince TV doğrudan bağlanır ve adresi saklar; ADB kapalıysa
/// (Play'den kurulan TV) sessizce vazgeçilir, tarama yolu sürer.
final class AndroidTVKeeper: KeeperControlling, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let launchParams: String?
    private let appConnected: @Sendable () -> Bool
    private let open: @Sendable (String, UInt16, String?) throws -> String
    private let log: @Sendable (String) -> Void
    /// Her açma denemesinin sonucu (ana ekrandaki satır): açıldıysa nil.
    private let onOpenResult: @Sendable (TVOpenProblem?) -> Void
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var rule: AndroidTVOpenRule
    private var lastResult: String?

    init(host: String, port: UInt16, server: String, appConnected: @escaping @Sendable () -> Bool,
         relaunchInterval: TimeInterval = AndroidTVOpenRule.defaultInterval, maxOpens: Int = AndroidTVOpenRule.defaultMaxOpens,
         open: @escaping @Sendable (String, UInt16, String?) throws -> String = { host, port, params in
             try AndroidTvInstaller(host: host, port: port).open(launchParams: params)
         }, log: @escaping @Sendable (String) -> Void = { InstallLog.shared.write($0) },
         onOpenResult: @escaping @Sendable (TVOpenProblem?) -> Void = { _ in }) {
        self.host = host
        self.onOpenResult = onOpenResult
        self.port = port
        launchParams = AndroidTvInstaller.launchParams(server: server)
        self.appConnected = appConnected
        rule = AndroidTVOpenRule(maxOpens: maxOpens, interval: relaunchInterval)
        self.open = open
        self.log = log
    }

    /// Bir kontrol: `AndroidTVOpenRule` izin verirse açmayı dener. Bloklar.
    func tick(now: Date = Date()) {
        guard !host.isEmpty else { return }
        let connected = appConnected()
        lock.lock()
        let due = rule.shouldTry(connected: connected, now: now.timeIntervalSinceReferenceDate)
        lock.unlock()
        guard due else { return }
        let result: String
        do {
            let output = try open(host, port, launchParams)
            // Uygulama TV'de çalışırken bulunduysa `am start` gönderilmedi: açılış sayılmaz.
            if output != AndroidTVApp.alreadyRunning {
                lock.lock()
                rule.opened()
                lock.unlock()
            }
            result = "açıldı: \(output)"
            onOpenResult(nil)
        } catch {
            result = "açılamadı: \(error)"
            onOpenResult(Self.problem(error))
        }
        // Aynı sonuç her denemede yeniden yazılmaz.
        lock.lock()
        let changed = lastResult != result
        lastResult = result
        lock.unlock()
        if changed { log("Android TV (\(host):\(port)) telefonun adresiyle \(result)") }
    }

    /// Açılamamanın nedeni: TV hata ayıklama iznini onaylamadıysa (ADB eşleşmesi yok) ayrı, gerisi "ulaşılamıyor".
    static func problem(_ error: Error) -> TVOpenProblem {
        switch (error as? AndroidInstallFailure)?.error {
        case .notApproved, .notPaired: .debugNotApproved
        default: .debugOff
        }
    }

    func start(interval: Duration) {
        stop()
        loop = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// "Otomatik açmayı dene" ya da öne dönüş: sayaç sıfırlanır, sonraki kontrol beklemeden dener (uygulama bağlıysa ya da
    /// TV'de çalışıyorsa yine açılmaz).
    func reconnect() {
        lock.lock()
        rule.reset()
        lock.unlock()
    }

    deinit { loop?.cancel() }
}

/// Android TV kurulumunda hangi bağlantı yolunun seçileceği (Android'deki AdbMode ile aynı kural, GitHub #478).
///
/// Yeni Android TV ve Google TV'lerde eski ADB portu 5555 kapalıdır; bunlara yalnız "Kablosuz hata ayıklama" (eşleme kodu ve
/// her açılışta değişen port) ile bağlanılır. Eskiden ekran hep "USB/ağ hata ayıklama" sekmesinde açılıyor, 5555'e
/// bağlanılamayınca yalnız küçük bir notta "kablosuz hata ayıklama ayrı port kullanır" yazıyordu; kullanıcılar fark etmiyordu.
enum AdbMode {
    /// Seçilen TV'de 5555 açık değilse kablosuz hata ayıklama sekmesi seçilir.
    static func prefersWireless(legacyAdbReachable: Bool) -> Bool { !legacyAdbReachable }

    /// Ağ hata ayıklamasıyla (5555) TV'ye bağlanılamadı: belirgin "Kablosuz hata ayıklamayla dene" düğmesi gösterilir.
    static func offersWireless(wireless: Bool, error: AndroidInstallError?) -> Bool {
        !wireless && error == .unreachable
    }

    /// Kablosuz sekmeye geçerken adresteki port bırakılır (kablosuz hata ayıklamanın portu farklıdır, TV'den yazılır).
    static func hostOnly(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) else { return trimmed }
        return String(parts[0])
    }
}
