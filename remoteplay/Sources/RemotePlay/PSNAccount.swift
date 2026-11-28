// SPDX-License-Identifier: AGPL-3.0-only
// PSN girişiyle Remote Play kaydı için gereken hesap kimliğini alır.
// Akış ve istemci bilgileri chiaki-ng'den (gui/include/psnaccountid.h, gui/src/psnaccountid.cpp).

import Foundation

public enum PSNAccount {
    /// PSN girişinin nerede ve neden bittiği; kullanıcıya ayrı ayrı anlatılır (Windows'taki PsnLoginFailure).
    public enum PSNError: Error, Equatable {
        /// Yönlendirmede ne kod ne de Sony'nin hatası var.
        case noCode
        /// Sony girişi tamamlamadı (yönlendirmede `error=...` ya da token isteği 400/401/403); ayrıntı Sony'nin hatası.
        case refused(status: Int?, detail: String?)
        /// Sony çok fazla deneme dedi (HTTP 429 ya da hata metninde "too many").
        case rateLimited(status: Int?, detail: String?)
        case http(Int, detail: String?)
        /// Sony'ye ulaşılamadı ya da yanıt zamanında gelmedi.
        case network(String)
        case badResponse
    }

    static let clientId = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!
    static let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"

    public static let redirectPrefix = "https://remoteplay.dl.playstation.net/remoteplay/redirect"

    /// Çerezsiz ve önbelleksiz oturum: URLSession.shared Sony'nin çerezlerini uygulamanın kalıcı çerez deposunda tutuyordu;
    /// bağlantılar sıfırlansa da sonraki girişte eski oturumun çerezleri gönderilmesin.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// Uygulama içi tarayıcıda açılacak Sony giriş sayfası.
    public static let authorizeURL: URL = {
        var components = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "service_entity", value: "urn:service-entity:psn"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectPrefix),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "request_locale", value: "en_US"),
            URLQueryItem(name: "ui", value: "pr"),
            URLQueryItem(name: "service_logo", value: "ps"),
            URLQueryItem(name: "layout_type", value: "popup"),
            URLQueryItem(name: "smcid", value: "remoteplay"),
            URLQueryItem(name: "prompt", value: "always"),
            URLQueryItem(name: "PlatformPrivacyWs1", value: "minimal"),
        ]
        return components.url!
    }()

    /// Giriş bitince tarayıcının gittiği yönlendirme adresinden tek kullanımlık kodu çıkarır.
    public static func code(fromRedirect url: URL) -> String? {
        guard url.absoluteString.hasPrefix(redirectPrefix) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    /// Sony girişi tamamlamadıysa yönlendirmedeki hata ("access_denied: ... (4002)"); yoksa nil.
    public static func error(fromRedirect url: URL) -> String? {
        guard url.absoluteString.hasPrefix(redirectPrefix),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let error = items.first(where: { $0.name == "error" })?.value, !error.isEmpty else { return nil }
        // Sony açıklamadaki boşlukları "+" ile yazar.
        let description = items.first { $0.name == "error_description" }?.value?.replacingOccurrences(of: "+", with: " ")
        let code = items.first { $0.name == "error_code" }?.value
        return describe(error: error, description: description, code: code)
    }

    /// Tarayıcıda giriş yapan kullanıcının yapıştırdığı (ya da panoya kopyaladığı) metinden yönlendirme adresi. Adres
    /// çubuğundan kopyalanan metnin başında ya da sonunda boşluk, tırnak, ya da adresin önünde başka yazı olabilir; adres
    /// remoteplay.dl.playstation.net yönlendirmesi değilse ya da içinde kod veya Sony hatası yoksa nil. Windows'taki
    /// `PsnAccount.RedirectFromPastedText` ve Android'deki `redirectFromText` ile aynı kural.
    public static func redirect(fromPastedText text: String?) -> URL? {
        guard let text, let start = text.range(of: redirectPrefix, options: .caseInsensitive) else { return nil }
        let rest = text[start.upperBound...].prefix { !$0.isWhitespace && !"\"'<>".contains($0) }
        guard let url = URL(string: redirectPrefix + rest) else { return nil }
        if let code = code(fromRedirect: url), !code.isEmpty { return url }
        return error(fromRedirect: url) != nil ? url : nil
    }

    /// Sony'nin giriş sayfası arka plan çağrısı başarısız olunca "Can't connect to the server" yazar. Uygulama içi
    /// tarayıcıda bu görülürse giriş sistem tarayıcısına taşınır; tarayıcıda aynı giriş çalışıyor. Windows'taki
    /// `PsnAccount.LooksServerUnreachable` ile aynı kural.
    public static func looksServerUnreachable(_ pageText: String?) -> Bool {
        guard let pageText else { return false }
        return pageText.range(of: #"(?:(?:can|could)(?:\s?not|n?[\u2019']t)|unable to) connect to the server"#,
                              options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Sayfa metni yalnız Sony'nin kendi sayfalarından dinlenir.
    public static func isSonyHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["sony.com", "sonyentertainmentnetwork.com", "playstation.com", "playstation.net"].contains { host.hasSuffix($0) }
    }

    /// Giriş penceresinin yakaladığı yönlendirmeden hesap kimliği. Sony'nin hatası, HTTP hatası, ağ hatası ve anlaşılamayan
    /// yanıt ayrı ayrı `PSNError` olur.
    public static func accountId(fromRedirect url: URL) async throws -> Data {
        if let code = code(fromRedirect: url), !code.isEmpty { return try await accountId(code: code) }
        guard let error = error(fromRedirect: url) else { throw PSNError.noCode }
        throw looksRateLimited(error) ? PSNError.rateLimited(status: nil, detail: error) : PSNError.refused(status: nil, detail: error)
    }

    static func describe(error: String, description: String?, code: String?) -> String {
        var text = error
        if let description, !description.isEmpty { text += ": \(description)" }
        if let code, !code.isEmpty { text += " (\(code))" }
        return text
    }

    static func looksRateLimited(_ text: String?) -> Bool {
        guard let text = text?.lowercased() else { return false }
        return text.contains("too many") || text.contains("too_many") || text.contains("rate limit")
    }

    /// Sony'nin JSON hatasından "error: error_description (error_code)".
    static func sonyError(_ object: [String: Any]) -> String? {
        func text(_ name: String) -> String? {
            switch object[name] {
            case let value as String: value
            case let value as NSNumber: value.stringValue
            default: nil
            }
        }
        guard let error = text("error"), !error.isEmpty else { return nil }
        return describe(error: error, description: text("error_description"), code: text("error_code"))
    }

    /// Başarısız HTTP yanıtından hata: 429 çok fazla deneme, 400/401/403 Sony kodu kabul etmedi, kalanı sunucu hatası.
    static func failure(status: Int, body: Data) -> PSNError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        var detail = object.flatMap(sonyError)
        if detail == nil, let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            detail = String(text.prefix(200))
        }
        if status == 429 || looksRateLimited(detail) { return .rateLimited(status: status, detail: detail) }
        if [400, 401, 403].contains(status) { return .refused(status: status, detail: detail) }
        return .http(status, detail: detail)
    }

    /// Kodu token'a, token'ı hesap kimliğine (8 bayt) çevirir. Token saklanmaz.
    public static func accountId(code: String) async throws -> Data {
        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "redirect_uri", value: redirectPrefix),
        ]
        tokenRequest.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let token = try await json(for: tokenRequest)
        guard let accessToken = token["access_token"] as? String else {
            guard let error = sonyError(token) else { throw PSNError.badResponse }
            throw looksRateLimited(error) ? PSNError.rateLimited(status: nil, detail: error) : PSNError.refused(status: nil, detail: error)
        }

        var infoRequest = URLRequest(url: tokenURL.appendingPathComponent(accessToken))
        infoRequest.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        let info = try await json(for: infoRequest)
        guard let userId = info["user_id"] as? String, let bytes = accountIdBytes(userId: userId) else { throw PSNError.badResponse }
        return bytes
    }

    /// Ondalık `user_id`'yi 8 baytlık little-endian dizisine çevirir.
    static func accountIdBytes(userId: String) -> Data? {
        guard let value = UInt64(userId) else { return nil }
        return withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Base64 PSN hesap kimliği: boşluklar atılır, çözülen değer tam 8 bayt olmalı (12 karakter).
    public static func accountId(fromBase64 value: String) -> Data? {
        let trimmed = value.filter { !$0.isWhitespace }
        guard trimmed.count == 12, let data = Data(base64Encoded: trimmed), data.count == 8 else { return nil }
        return data
    }

    private static var basicAuth: String {
        "Basic " + Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
    }

    private static func json(for request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PSNError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw failure(status: http.statusCode, body: data)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw PSNError.badResponse }
        return object
    }
}
