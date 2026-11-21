// SPDX-License-Identifier: AGPL-3.0-only
// Xbox jeton biçimleri; Android'deki xbox/XboxTokens.kt ile birebir. Alan adları ve süre hesabı xal-node'daki gibi
// (MIT, unknownskl): Windows köprüsünün sakladığı userToken JSON'u burada da aynı biçimdedir.

import Foundation

/// Xbox hatasının kullanıcıya anlatılabilecek türü.
public enum XboxErrorKind: String, Sendable {
    /// Microsoft girişi yok ya da yenileme jetonu geçersiz.
    case signInRequired
    case codeExpired
    case signInDeclined
    /// Hesabın Xbox profili yok (XSTS 401).
    case noXboxAccount
    /// Xbox kapalı, uzaktan oynatma kapalı ya da yayın açılamadı.
    case consoleUnavailable
    case busy
    case timeout
    case network
    case service
    /// Görüntü geldikten sonra kesildi: bağlantı açık görünse de oturum yeniden kurulur (bkz. `XboxPictureWatch`).
    case noPicture
}

public struct XboxError: Error, Sendable {
    public let kind: XboxErrorKind
    public let message: String
    public init(_ kind: XboxErrorKind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

typealias JSON = [String: Any]

func parseJSON(_ data: Data) throws -> JSON {
    if data.isEmpty { return [:] }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? JSON else {
        throw XboxError(.service, "Xbox yanıtı okunamadı")
    }
    return object
}

func parseJSON(_ text: String) throws -> JSON { try parseJSON(Data(text.utf8)) }

func jsonText(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

/// ISO 8601 (Microsoft yedi kesir hanesi kullanır; ISO8601DateFormatter bunu her sürümde okumuyor).
func parseInstant(_ text: String?) -> Date? {
    guard var text, !text.isEmpty else { return nil }
    var fraction = 0.0
    if let dot = text.firstIndex(of: ".") {
        let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
        fraction = Double("0." + digits) ?? 0
        text.removeSubrange(dot..<text.index(dot, offsetBy: digits.count + 1))
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text).map { $0.addingTimeInterval(fraction) }
}

/// Microsoft kullanıcı jetonu: kalıcı saklanan tek jeton (Anahtar Zinciri).
public struct XboxUserToken {
    let json: JSON
    public var accessToken: String { json["access_token"] as? String ?? "" }
    public var refreshToken: String { json["refresh_token"] as? String ?? "" }
    public var expiresOn: Date { parseInstant(json["expires_on"] as? String) ?? .distantPast }

    public func secondsValid(now: Date) -> Int { Int(floor(expiresOn.timeIntervalSince(now))) }
    public func serialize() -> String { jsonText(json) }

    /// xal-node `TokenStore.setUserToken` gibi `expires_on = şimdi + expires_in`; yenileme jetonu yoksa öncekisi korunur.
    static func fromResponse(_ body: JSON, now: Date, previous: XboxUserToken? = nil) throws -> XboxUserToken {
        guard let access = body["access_token"] as? String, !access.isEmpty else {
            throw XboxError(.service, "Microsoft jeton yanıtında access_token yok")
        }
        var copy = body
        if (copy["refresh_token"] as? String ?? "").isEmpty, let old = previous?.refreshToken, !old.isEmpty { copy["refresh_token"] = old }
        let seconds = (body["expires_in"] as? NSNumber)?.doubleValue ?? 0
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        copy["expires_on"] = formatter.string(from: now.addingTimeInterval(seconds))
        return XboxUserToken(json: copy)
    }

    /// Saklanan metinden; bozuksa ya da yenileme jetonu yoksa nil.
    public static func parse(_ text: String?) -> XboxUserToken? {
        guard let text, let json = try? parseJSON(text) else { return nil }
        let token = XboxUserToken(json: json)
        return token.refreshToken.isEmpty ? nil : token
    }
}

/// Xbox Live kullanıcı jetonu ya da XSTS jetonu.
struct XboxXstsToken {
    let token: String
    let userHash: String
    let notAfter: Date
    func secondsValid(now: Date) -> Int { Int(floor(notAfter.timeIntervalSince(now))) }

    static func parse(_ body: JSON) throws -> XboxXstsToken {
        guard let token = body["Token"] as? String, !token.isEmpty else { throw XboxError(.service, "Xbox Live yanıtında Token yok") }
        let xui = ((body["DisplayClaims"] as? JSON)?["xui"] as? [JSON])?.first
        return XboxXstsToken(token: token, userHash: xui?["uhs"] as? String ?? "", notAfter: parseInstant(body["NotAfter"] as? String) ?? .distantPast)
    }
}

/// Ev yayını adresi ve jetonu (gssv `/v2/login/user`, varsayılan bölge).
struct XboxHomeEndpoint {
    let baseURL: String
    let token: String
    let expiresAt: Date

    static func parse(_ body: JSON, now: Date) throws -> XboxHomeEndpoint {
        let regions = (body["offeringSettings"] as? JSON)?["regions"] as? [JSON] ?? []
        let chosen = regions.first { $0["isDefault"] as? Bool == true } ?? regions.first
        var base = chosen?["baseUri"] as? String ?? ""
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { throw XboxError(.service, "Xbox ev yayını bölgesi gelmedi") }
        guard let token = body["gsToken"] as? String, !token.isEmpty else { throw XboxError(.service, "Xbox ev yayını jetonu gelmedi") }
        let seconds = (body["durationInSeconds"] as? NSNumber)?.doubleValue ?? 0
        return XboxHomeEndpoint(baseURL: base, token: token, expiresAt: now.addingTimeInterval(seconds > 0 ? seconds : 30 * 60))
    }
}

/// Microsoft cihaz kodu.
public struct XboxDeviceCode: Equatable {
    public let userCode: String
    public let deviceCode: String
    public let verificationURI: String
    public let expiresIn: Int
    public let interval: Int

    public init(userCode: String, deviceCode: String, verificationURI: String, expiresIn: Int, interval: Int) {
        self.userCode = userCode
        self.deviceCode = deviceCode
        self.verificationURI = verificationURI
        self.expiresIn = expiresIn
        self.interval = interval
    }

    static func parse(_ body: JSON) throws -> XboxDeviceCode {
        guard let user = body["user_code"] as? String, !user.isEmpty, let device = body["device_code"] as? String, !device.isEmpty else {
            throw XboxError(.service, "Microsoft cihaz kodu gelmedi")
        }
        return XboxDeviceCode(userCode: user, deviceCode: device,
                              verificationURI: body["verification_uri"] as? String ?? "https://www.microsoft.com/link",
                              expiresIn: (body["expires_in"] as? NSNumber)?.intValue ?? 900,
                              interval: max(1, (body["interval"] as? NSNumber)?.intValue ?? 5))
    }
}

/// Hesaptaki bir Xbox (smartglass `/lists/devices`).
public struct XboxConsole: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let model: String
    public let streamingEnabled: Bool
    public var powerState: String = ""

    public init(id: String, name: String, model: String, streamingEnabled: Bool, powerState: String = "") {
        self.id = id
        self.name = name
        self.model = model
        self.streamingEnabled = streamingEnabled
        self.powerState = powerState
    }

    /// Windows köprüsündeki gibi: yayın için `consoleStreamingEnabled` ve `remoteManagementEnabled` açık olmalı.
    static func parseList(_ body: JSON) -> [XboxConsole] {
        (body["result"] as? [JSON] ?? []).compactMap { c in
            guard let id = c["id"] as? String, !id.isEmpty else { return nil }
            return XboxConsole(id: id, name: c["name"] as? String ?? "", model: c["consoleType"] as? String ?? "",
                               streamingEnabled: (c["consoleStreamingEnabled"] as? Bool ?? false) && (c["remoteManagementEnabled"] as? Bool ?? false),
                               powerState: c["powerState"] as? String ?? "")
        }
    }
}

/// Okunan konsol türü.
public enum ConsolePlatform: String, Codable, Sendable {
    case playstation, xbox
}

public enum XboxStoreKey {
    /// UserDefaults: konsol türü.
    public static let platform = "platform"
    /// Anahtar Zinciri: Microsoft kullanıcı jetonu (Windows'taki userToken JSON'u) ve seçilen Xbox.
    public static let userToken = "xboxUserToken"
    public static let console = "xboxConsole"
}

/// Jeton değişikliğini (XboxAuth içinden) modele ileten kutu.
public final class XboxTokenSink: @unchecked Sendable {
    public var handler: ((XboxUserToken?) -> Void)?
    public init() {}
}

/// Cihaz kodu beklerken gelen hata yanıtı (RFC 8628).
enum DeviceCodePoll: Equatable {
    case pending, slowDown, expired, declined, failed

    static func classify(status: Int, body: Data) -> DeviceCodePoll {
        let error = (try? parseJSON(body))?["error"] as? String ?? ""
        switch error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "expired_token", "code_expired": return .expired
        case "authorization_declined", "access_denied": return .declined
        default: return status >= 500 ? .pending : .failed
        }
    }
}
