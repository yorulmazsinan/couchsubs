// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import XCTest

/// İlk istekte verilen ağ hatasını atar, sonrakileri "[tr] cümle" diye çevirir.
private final class FlakyDeepL: URLProtocol {
    nonisolated(unsafe) static var requests = 0
    /// İlk istekte atılacak hata; nil ise istek başarılı.
    nonisolated(unsafe) static var firstError: URLError.Code?
    /// Verilirse her yanıt bu durum koduyla döner.
    nonisolated(unsafe) static var status: Int?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        if Self.requests == 1, let code = Self.firstError {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let texts = body["text"] as? [String] ?? []
        let reply = try! JSONSerialization.data(withJSONObject: ["translations": texts.map { ["text": "[tr] " + $0] }])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status ?? 200, httpVersion: nil,
                                                              headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlakyDeepL.self]
        return URLSession(configuration: configuration)
    }
}

private final class RecordingLocal: TextTranslator {
    private(set) var calls: [String] = []
    func translate(_ text: String) async throws -> String {
        calls.append(text)
        return "yerel: " + text
    }
}

/// Windows'taki DeepLTranslatorTests.DroppedKeepAliveConnectionIsRetriedOnce ile aynı kurallar (#433).
final class DeepLConnectionTests: XCTestCase {
    override func setUp() {
        FlakyDeepL.requests = 0
        FlakyDeepL.firstError = nil
        FlakyDeepL.status = nil
    }

    private func make(_ local: RecordingLocal) -> DeepLTranslator {
        DeepLTranslator(key: "abc:fx", fallback: local, session: FlakyDeepL.session())
    }

    /// Sözlük açıkken sözlükteki adı ("Soul") içeren satır önbellekten geldiğinde dublaj kaybolmaz: önbellek çeviride
    /// kullanılan sözlük anahtarıyla okunur (Windows'taki DeepLTranslatorTests ile aynı).
    func testDubbingSurvivesGlossaryCacheHit() async throws {
        let cache = TranslationCache()
        let text = "Soul, run. Stay close."
        let first = DeepLTranslator(key: "abc:fx", fallback: RecordingLocal(), session: FlakyDeepL.session(), cache: cache,
                                    glossary: .builtInOnly())
        let translated = try await first.translate(text)
        let expected = first.spokenLines(for: text)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertTrue(DeepLMarkup.cacheKey(text, glossary: .builtIn) != text, "satır sözlük anahtarıyla saklanmalı")
        // Yeni oturum: konuşma belleği boş, çeviri önbellekten gelir.
        let requests = FlakyDeepL.requests
        let local = RecordingLocal()
        let second = DeepLTranslator(key: "abc:fx", fallback: local, session: FlakyDeepL.session(), cache: cache,
                                     glossary: .builtInOnly())
        XCTAssertEqual(second.spokenLines(for: text), expected)
        let again = try await second.translate(text)
        XCTAssertEqual(again, translated)
        XCTAssertEqual(FlakyDeepL.requests, requests)
        XCTAssertTrue(local.calls.isEmpty)
    }

    /// Açık tutulan bağlantıyı sunucu sessizce kapatmışsa satır yedek çeviriye düşmeden bir kez daha denenir.
    func testDroppedKeepAliveConnectionIsRetriedOnce() async throws {
        FlakyDeepL.firstError = .networkConnectionLost
        let local = RecordingLocal()
        let result = try await make(local).translate("Open the door.")
        XCTAssertEqual(result, "[tr] Open the door.")
        XCTAssertEqual(FlakyDeepL.requests, 2)
        XCTAssertTrue(local.calls.isEmpty)
    }

    /// Zaman aşımında satır zaten bekledi: yeniden denenmez, yerel çeviriye düşer.
    func testTimeoutIsNotRetried() async throws {
        FlakyDeepL.firstError = .timedOut
        let local = RecordingLocal()
        let result = try await make(local).translate("Open the door.")
        XCTAssertEqual(result, "yerel: Open the door.")
        XCTAssertEqual(FlakyDeepL.requests, 1)
    }

    /// DeepL'in yanıtladığı hatalar (çok sık istek, kota, anahtar) yeniden denenmez.
    func testServiceErrorsAreNotRetried() async throws {
        for status in [429, 456, 403] {
            FlakyDeepL.requests = 0
            FlakyDeepL.status = status
            let result = try await make(RecordingLocal()).translate("Run!")
            XCTAssertEqual(result, "yerel: Run!", "\(status)")
            XCTAssertEqual(FlakyDeepL.requests, 1, "\(status)")
        }
    }

    func testDroppedConnectionClassification() {
        XCTAssertTrue(DeepLTranslator.isDroppedConnection(URLError(.networkConnectionLost)))
        XCTAssertTrue(DeepLTranslator.isDroppedConnection(URLError(.secureConnectionFailed)))
        XCTAssertFalse(DeepLTranslator.isDroppedConnection(URLError(.timedOut)))
        XCTAssertFalse(DeepLTranslator.isDroppedConnection(URLError(.cancelled)))
    }

    /// Hata sonrası bekleme 15 sn; sıcak tutma 40 sn'de bir, son çeviriden sonra 10 dk (Windows ve Android ile aynı).
    func testTimings() {
        XCTAssertEqual(DeepLTranslator.retryAfter, 15)
        XCTAssertEqual(DeepLConnectionWarmer.keepWarmEvery, 40)
        XCTAssertEqual(DeepLConnectionWarmer.keepWarmFor, 600)
    }

    /// Son çeviriden sonra 10 dk sıcak tutulur, sonra durur; yeni çeviri yeniden başlatır.
    func testWarmerStopsAfterIdleWindow() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }
        let clock = Clock()
        let warmer = DeepLConnectionWarmer(now: { clock.now }, ping: { _ in })
        XCTAssertNil(warmer.nextPing())
        warmer.touch(key: "abc:fx")
        XCTAssertEqual(warmer.nextPing(), "abc:fx")
        clock.now += DeepLConnectionWarmer.keepWarmFor
        XCTAssertEqual(warmer.nextPing(), "abc:fx")
        clock.now += 1
        XCTAssertNil(warmer.nextPing())
        warmer.touch(key: "abc:fx")
        XCTAssertEqual(warmer.nextPing(), "abc:fx")
    }
}
