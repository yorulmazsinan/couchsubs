// SPDX-License-Identifier: AGPL-3.0-only

import CChiaki
import Foundation

/// PS5'e kaydedilmiş bu cihazın bağlantı bilgileri. Anahtarlıkta saklanır.
public struct RegisteredConsole: Codable, Equatable, Sendable {
    public let host: String
    public let name: String
    /// 16 baytlık kayıt anahtarı (ASCII onaltılık, sıfırla doldurulmuş).
    public let registKey: Data
    /// 16 baytlık oturum anahtarı ("morning").
    public let morning: Data

    public init(host: String, name: String, registKey: Data, morning: Data) {
        self.host = host
        self.name = name
        self.registKey = registKey
        self.morning = morning
    }

    /// Uyandırma için kayıt anahtarının onaltılık değeri.
    public var wakeCredential: UInt64? {
        let end = registKey.firstIndex(of: 0) ?? registKey.endIndex
        return UInt64(String(decoding: registKey[..<end], as: UTF8.self), radix: 16)
    }

    func withHost(_ newHost: String) -> RegisteredConsole {
        RegisteredConsole(host: newHost, name: name, registKey: registKey, morning: morning)
    }
}

public enum Registration {
    /// Kod PS5'e gitmeden biten aşama (arama tek UDP paketiyle yapılır); paket kaybında yeniden denemek güvenlidir.
    ///
    /// Yalnız arama yanıtsız kaldıysa (`noAnswer`) yeniden denenir. PS5 aramaya bir kez yanıt verdikten sonra yeni aramayı
    /// reddeder ("Connection refused"); eskiden PS5 yanıt verip bağlantı açılamayınca iki deneme daha yapılıyor, ikisi de
    /// reddediliyor ve kullanıcı ilk (asıl) hata yerine "Connection refused"u görüp PS5'in bağlanmayı reddettiğini
    /// sanıyordu (GitHub #590: 12 eşleştirmenin hepsinde 2. ve 3. deneme reddedildi, hiçbiri tutmadı).
    static let searchAttempts = 3

    /// Bu hatadan sonra aynı kodla yeniden denensin mi.
    static func shouldRetry(_ error: RegistrationError, attempt: Int) -> Bool {
        error.kind == .noAnswer && attempt < searchAttempts
    }

    /// PS5'in "Cihazı Bağla" ekranındaki 8 haneli kodla kayıt olur. Başarısızlıkta `RegistrationError`; her deneme
    /// ve sonucu remoteplay.log'a yazılır.
    public static func register(host: String, accountId: Data, pin: UInt32) async throws -> RegisteredConsole {
        RemotePlayLog.write("PS5 kaydı başlıyor: \(host), hesap kimliği \(accountId.base64EncodedString())")
        guard accountId.count == 8 else {
            let error = RegistrationError(.failed, detail: "PSN account id must be 8 bytes (\(accountId.count))")
            RemotePlayLog.write("PS5 kaydı başarısız (\(host)): \(error)")
            throw error
        }
        var attempt = 1
        while true {
            do {
                let console = try await registerOnce(host: host, accountId: accountId, pin: pin)
                RemotePlayLog.write("PS5 kaydı tamam (\(host)): \(console.name)")
                return console.withHost(host)
            } catch let error as RegistrationError {
                RemotePlayLog.write("PS5 kaydı başarısız (\(host), deneme \(attempt)): \(error)")
                guard shouldRetry(error, attempt: attempt) else { throw error }
            }
            attempt += 1
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// PS5'in gösterdiği 8 haneli kodu okur. Boşluk, tire ve nokta atlanır; başka bir karakter ya da 8'den farklı
    /// hane sayısı nil. Başka yazı sistemlerinin onluk rakamları da kabul edilir.
    public static func pin(from text: String) -> UInt32? {
        var digits = ""
        for character in text {
            if character.isWhitespace || "-–._".contains(character) { continue }
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
                  scalar.properties.numericType == .decimal, let value = character.wholeNumberValue else { return nil }
            digits += String(value)
        }
        guard digits.count == 8 else { return nil }
        return UInt32(digits)
    }

    private static func registerOnce(host: String, accountId: Data, pin: UInt32) async throws -> RegisteredConsole {
        let logger = ChiakiLogger()
        let regist = UnsafeMutablePointer<ChiakiRegist>.allocate(capacity: 1)
        let box = Box()
        var started = false
        defer {
            // Kayıt iş parçacığı geri çağrıdan sonra kapanır; beklemeyi ayrı bir kuyrukta yap.
            let wasStarted = started
            DispatchQueue.global().async {
                if wasStarted { chiaki_regist_fini(regist) }
                regist.deallocate()
                withExtendedLifetime(logger) {}
            }
        }

        // PS5'in red nedeni olaya değil yalnız günlüğe yazılır; olaydan önce aynı iş parçacığında gelir.
        logger.onMessage = { line, isError in
            if let reason = reason(fromLog: line) { box.reason = reason }
            if isError { box.errors.append(line) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            box.continuation = continuation
            host.withCString { hostPointer in
                var info = ChiakiRegistInfo()
                info.target = CHIAKI_TARGET_PS5_1
                info.host = hostPointer
                info.broadcast = false
                info.psn_online_id = nil
                copy(accountId, into: &info.psn_account_id)
                info.pin = pin
                info.console_pin = 0
                info.holepunch_info = nil
                info.rudp = nil

                let user = Unmanaged.passRetained(box).toOpaque()
                let error = chiaki_regist_start(regist, logger.pointer, &info, { event, user in
                    guard let user else { return }
                    let box = Unmanaged<Box>.fromOpaque(user).takeRetainedValue()
                    guard let event else {
                        return box.resume(.failure(RegistrationError(.failed, detail: "empty regist event")))
                    }
                    box.finish(event.pointee)
                }, user)
                if error.isSuccess {
                    started = true
                } else {
                    Unmanaged<Box>.fromOpaque(user).release()
                    box.resume(.failure(RegistrationError(.failed, detail: "regist start: \(ChiakiError(code: error))")))
                }
            }
        }
    }

    /// Eşleştirme hatası: ne olduğu (`kind`), PS5'in bildirdiği kod ve iletiye/günlüğe eklenen teknik ayrıntı.
    public struct RegistrationError: Error, Equatable, CustomStringConvertible {
        public enum Kind: String, Sendable {
            /// Sınıflanamayan hata (ayrıntıda libchiaki'nin satırı).
            case failed
            case canceled
            /// PS5 hesabı tanımadı: kod, uygulamada giriş yapılan hesabın PS5 kullanıcısından alınmamış.
            case wrongAccount
            /// PS5 kodu kabul etmedi: kod yanlış ya da süresi dolmuş.
            case wrongCode
            /// PS5 arama paketine yanıt vermedi: kod PS5'e hiç ulaşmadı (kapalı, dinlenme modunda, başka ağda).
            case noAnswer
            /// PS5 ağda ama aramayı reddetti ("Connection refused"): Cihazı Eşleştir ekranı açık değil, kodun süresi dolmuş
            /// ya da PS5 dinlenme modunda. Yeniden denemek aynı yere çıkar; ekran yeniden açılıp yeni kod girilmelidir.
            case pairingClosed
            /// PS5 aramaya yanıt verdi ama eşleştirme bağlantısı (TCP 9295) açılamadı.
            case connectFailed
            /// Bu cihazda yeni bağlantı için boş port ya da soket kalmadı (GitHub #590'daki şikâyet); yeniden başlatmak çözer.
            case noFreePort
            /// PS5 isteği aldı ama yanıtı zamanında gelmedi.
            case noReply
            case inUse
            case consoleCrashed
            case versionMismatch
            /// Girilen adres çözülemedi (yanlış yazılmış IP).
            case badAddress
            /// macOS yerel ağ izni kapalı: paket ağa hiç çıkamadı.
            case localNetworkBlocked
        }

        public let kind: Kind
        /// PS5'in bildirdiği RP-Application-Reason (ör. 0x80108b09); PS5 yanıt vermediyse nil.
        public let reason: UInt32?
        public let detail: String?

        public init(_ kind: Kind, reason: UInt32? = nil, detail: String? = nil) {
            self.kind = kind
            self.reason = reason
            self.detail = detail
        }

        public var description: String { detail.map { "\(kind.rawValue): \($0)" } ?? kind.rawValue }
    }

    static let reasonPrefix = "Reported Application Reason: "

    /// Boş port ya da soket kalmadığını söyleyen hata metinleri (macOS/Linux strerror ve Windows WSA kodları:
    /// 10049 WSAEADDRNOTAVAIL, 10055 WSAENOBUFS, 10024 WSAEMFILE).
    static let noFreePortErrors = ["assign requested address", "No buffer space", "Too many open files",
                                   "WSA error 10049", "WSA error 10055", "WSA error 10024"]

    /// PS5'in kodundan ve libchiaki'nin hata satırlarından hatanın türü.
    static func kind(reason: UInt32?, errors: [String]) -> RegistrationError.Kind {
        if let reason {
            switch reason {
            case UInt32(CHIAKI_RP_APPLICATION_REASON_INVALID_PSN_ID): return .wrongAccount
            case UInt32(CHIAKI_RP_APPLICATION_REASON_REGIST_FAILED): return .wrongCode
            case UInt32(CHIAKI_RP_APPLICATION_REASON_IN_USE): return .inUse
            case UInt32(CHIAKI_RP_APPLICATION_REASON_RP_VERSION): return .versionMismatch
            case UInt32(CHIAKI_RP_APPLICATION_REASON_CRASH): return .consoleCrashed
            default: return .failed
            }
        }
        func any(_ needles: [String]) -> Bool { errors.contains { line in needles.contains { line.contains($0) } } }
        if any(["getaddrinfo"]) { return .badAddress }
        // macOS yerel ağ izni yoksa paket gönderilemez: "No route to host" ya da "Operation not permitted".
        // libchiaki eskiden bağlantı hatasının nedenini yazmıyordu ("Network error"); yama (third-party/patches/
        // chiaki-regist-connect-retry.patch) errno'yu satıra ekler, bu sınıflama ancak onunla işler.
        if any(["send search", "for search", "Regist connect failed"]) && any(["No route to host", "not permitted"]) {
            return .localNetworkBlocked
        }
        if any(["send search", "for search", "Regist connect failed", "search response"]) && any(noFreePortErrors) {
            return .noFreePort
        }
        if any(["search response"]) && any(["Connection refused", "WSA error 10054"]) { return .pairingClosed }
        if any(["connect for request"]) { return .connectFailed }
        if any(["search response", "connect for search", "failed to send search", "Regist search failed",
                "Regist connect failed"]) { return .noAnswer }
        if any(["response HTTP header", "receiving response content", "receive response content"]) { return .noReply }
        return .failed
    }

    /// İletiye eklenen ayrıntı: PS5'in kodu, o yoksa libchiaki'nin ilk (en belirleyici) hata satırı.
    static func detail(from errors: [String]) -> String? {
        if let reported = errors.first(where: { $0.contains(reasonPrefix) }), let range = reported.range(of: reasonPrefix) {
            return String(reported[range.upperBound...])
        }
        return errors.first
    }

    /// "Reported Application Reason: 0x80108b02 (...)" satırından nedeni okur.
    static func reason(fromLog line: String) -> UInt32? {
        guard let range = line.range(of: reasonPrefix + "0x") else { return nil }
        return UInt32(line[range.upperBound...].prefix { $0.isHexDigit }, radix: 16)
    }

    /// libchiaki'nin bitiş olayından sonuç (testlerde olay elle kurulur).
    static func result(type: ChiakiRegistEventType, host: ChiakiRegisteredHost?, reason: UInt32?,
                       errors: [String]) -> Result<RegisteredConsole, RegistrationError> {
        switch type {
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
            guard let host else { return .failure(RegistrationError(.failed, detail: "success without host")) }
            let console = RegisteredConsole(host: "", name: string(of: host.server_nickname),
                                            registKey: data(of: host.rp_regist_key), morning: data(of: host.rp_key))
            // Anahtarsız kayıt sonra bağlanamaz; başarı sayılmaz.
            guard console.registKey.contains(where: { $0 != 0 }), console.morning.contains(where: { $0 != 0 }) else {
                return .failure(RegistrationError(.failed, detail: "empty registration key"))
            }
            return .success(console)
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
            return .failure(RegistrationError(.canceled, detail: detail(from: errors)))
        default:
            return .failure(RegistrationError(kind(reason: reason, errors: errors), reason: reason, detail: detail(from: errors)))
        }
    }

    private final class Box {
        var continuation: CheckedContinuation<RegisteredConsole, Error>?
        var reason: UInt32?
        var errors: [String] = []

        func finish(_ event: ChiakiRegistEvent) {
            let host = event.type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS ? event.registered_host?.pointee : nil
            switch Registration.result(type: event.type, host: host, reason: reason, errors: errors) {
            case .success(let console): resume(.success(console))
            case .failure(let error): resume(.failure(error))
            }
        }

        func resume(_ result: Result<RegisteredConsole, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
