// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import XCTest

/// `/v2/usage` isteğine verilen yanıtı ya da ağ hatasını döndürür; gelen isteğin adresini ve başlığını saklar.
private final class UsageStub: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var error: URLError.Code?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let code = Self.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                                              headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageStub.self]
        return URLSession(configuration: configuration)
    }
}

/// "Kaydet ve dene"nin her sonucu (Windows: DeepLTranslatorTests.Check*, Android: DeepLUsageTest ile aynı kurallar).
final class DeepLKeyCheckTests: XCTestCase {
    private let key = "0f3c1a2b-1111-2222-3333-444455556666:fx"

    override func setUp() {
        UsageStub.status = 200
        UsageStub.body = Data(#"{"character_count":1200,"character_limit":500000}"#.utf8)
        UsageStub.error = nil
        UsageStub.requests = []
    }

    private func check(_ key: String) async -> OnlineKeyCheck {
        await DeepLTranslator.check(key: key, session: UsageStub.session())
    }

    func testValidKeyReturnsUsage() async {
        let result = await check(key)
        XCTAssertEqual(result, OnlineKeyCheck(state: .valid, used: 1200, limit: 500_000))
        XCTAssertEqual(UsageStub.requests.first?.url?.host, "api-free.deepl.com")
    }

    /// Yapıştırırken araya giren görünmez karakterler (bölünmez boşluk, sıfır genişlikli boşluk, BOM, yumuşak tire, satır
    /// sonu, sekme) silinir; istek temiz anahtarla ücretsiz adrese gider.
    func testInvisibleCharactersAreRemovedEverywhere() async {
        let pasted = "\u{FEFF} 0f3c1a2b-1111\u{00A0}-2222-\u{200B}3333-4444\n55556666\u{00AD}:fx\t\r\n"
        XCTAssertEqual(DeepLKey.clean(pasted), key)
        let result = await check(pasted)
        XCTAssertEqual(result.state, .valid)
        XCTAssertEqual(UsageStub.requests.first?.value(forHTTPHeaderField: "Authorization"), "DeepL-Auth-Key \(key)")
        XCTAssertEqual(UsageStub.requests.first?.url?.host, "api-free.deepl.com")
        XCTAssertEqual(DeepLTranslator.baseURL(for: key + "\u{200B}").host, "api-free.deepl.com")
    }

    /// Temizlendikten sonra ASCII olmayan harf kalırsa istek gönderilmez (önceden 502 / -1004 → "ulaşılamadı" oluyordu).
    func testNonASCIIKeyIsMalformedWithoutRequest() async {
        let result = await check("0f3c1a2b-1111-2222-ş333-444455556666:fx")
        XCTAssertEqual(result, OnlineKeyCheck(state: .invalid, reason: .malformedKey))
        XCTAssertTrue(UsageStub.requests.isEmpty)
    }

    func testEmptyKeyIsInvalid() async {
        let result = await check(" \u{200B}\n")
        XCTAssertEqual(result.state, .invalid)
        XCTAssertTrue(UsageStub.requests.isEmpty)
    }

    func testProKeyGoesToProEndpoint() async {
        _ = await check("0f3c1a2b-1111-2222-3333-444455556666")
        XCTAssertEqual(UsageStub.requests.first?.url?.host, "api.deepl.com")
    }

    func testForbiddenIsInvalid() async {
        UsageStub.status = 403
        let result = await check(key)
        XCTAssertEqual(result, OnlineKeyCheck(state: .invalid, reason: .httpStatus(403)))
    }

    func testQuotaStatusIsQuotaExceeded() async {
        UsageStub.status = 456
        let result = await check(key)
        XCTAssertEqual(result.state, .quotaExceeded)
    }

    /// 429 ağ hatası değildir: anahtar reddedilmedi, DeepL çok sık istek aldığını bildirdi (Sinan Bey'in Mac'indeki durum).
    func testTooManyRequestsIsBusyNotUnreachable() async {
        UsageStub.status = 429
        let result = await check(key)
        XCTAssertEqual(result, OnlineKeyCheck(state: .busy, reason: .rateLimited))
        XCTAssertEqual(result.logDescription, "busy (HTTP 429 (çok sık istek))")
    }

    func testServerErrorKeepsStatusCode() async {
        UsageStub.status = 503
        let result = await check(key)
        XCTAssertEqual(result, OnlineKeyCheck(state: .unreachable, reason: .httpStatus(503)))
    }

    func testNetworkErrorIsUnreachable() async {
        UsageStub.error = .notConnectedToInternet
        let result = await check(key)
        XCTAssertEqual(result, OnlineKeyCheck(state: .unreachable, reason: .network(URLError.Code.notConnectedToInternet.rawValue)))
    }

    /// Pro/sınırsız hesap: sınır 1e12 (sınır yok), ek alanlar ve ondalıklı sayılar çözümlemeyi bozmaz.
    func testProUsageWithExtraFieldsAndHugeLimit() async {
        UsageStub.body = Data(#"{"character_count":5947223,"character_limit":1000000000000,"products":[{"product_type":"translate"}],"api_key_character_limit":1000000000000,"start_time":"2025-05-13T09:18:42Z"}"#.utf8)
        let result = await check(key)
        XCTAssertEqual(result, OnlineKeyCheck(state: .valid, used: 5_947_223, limit: OnlineKeyCheck.unlimited))
    }

    func testMissingOrOddUsageFieldsStillValid() async {
        UsageStub.body = Data(#"{"character_count":12.0}"#.utf8)
        let missing = await check(key)
        XCTAssertEqual(missing, OnlineKeyCheck(state: .valid, used: 12, limit: 0))

        UsageStub.body = Data(#"{"character_count":"7","character_limit":1e30}"#.utf8)
        let huge = await check(key)
        XCTAssertEqual(huge, OnlineKeyCheck(state: .valid, used: 7, limit: .max))

        UsageStub.body = Data(#"{"character_count":99999999999999999999999,"character_limit":true}"#.utf8)
        let overflow = await check(key)
        XCTAssertEqual(overflow, OnlineKeyCheck(state: .valid, used: .max, limit: 0))

        // JSON olmayan 200 yanıtı (otel/kafe ağının giriş sayfası gibi) DeepL'den gelmemiştir: ağ hatası.
        UsageStub.body = Data("<html>".utf8)
        let portal = await check(key)
        XCTAssertEqual(portal, OnlineKeyCheck(state: .unreachable, reason: .network(URLError.Code.cannotParseResponse.rawValue)))
    }

    func testUsedUpLimitIsQuotaExceeded() async {
        UsageStub.body = Data(#"{"character_count":500000,"character_limit":500000}"#.utf8)
        let result = await check(key)
        XCTAssertEqual(result.state, .quotaExceeded)
    }
}
