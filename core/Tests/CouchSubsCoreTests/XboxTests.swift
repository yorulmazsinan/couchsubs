// SPDX-License-Identifier: AGPL-3.0-only
// Xbox (Beta): jeton ayrıştırma, giriş zinciri, ev yayını uçları, Teredo, kanal iletileri ve oturum durum makinesi.
// Android'deki XboxTest.kt ile aynı durumlar.

import XCTest
@testable import CouchSubsCore

private final class FakeHTTP: XboxHTTP, @unchecked Sendable {
    struct Call { let method: String; let url: String; let headers: [String: String]; let body: String? }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    private let answer: (String, String, String?) -> XboxHTTPResponse

    init(_ answer: @escaping (String, String, String?) -> XboxHTTPResponse) { self.answer = answer }

    func request(_ method: String, _ url: String, headers: [String: String], body: String?) async throws -> XboxHTTPResponse {
        lock.lock(); calls.append(Call(method: method, url: url, headers: headers, body: body)); lock.unlock()
        let response = answer(method, url, body)
        // Durum -1: ağ hatası (istek kesildi).
        if response.status == -1 { throw XboxError(.network, "offline") }
        return response
    }
}

private func ok(_ json: String) -> XboxHTTPResponse { XboxHTTPResponse(status: 200, body: Data(json.utf8)) }
private func status(_ code: Int, _ json: String = "") -> XboxHTTPResponse { XboxHTTPResponse(status: code, body: Data(json.utf8)) }
private let now = ISO8601DateFormatter().date(from: "2026-11-16T10:00:00Z")!

final class XboxTokenTests: XCTestCase {
    func testUserTokenGetsExpiresOn() throws {
        let token = try XboxUserToken.fromResponse(try parseJSON(#"{"access_token":"A","refresh_token":"R","expires_in":3600}"#), now: now)
        XCTAssertEqual(token.secondsValid(now: now), 3600)
        let restored = try XCTUnwrap(XboxUserToken.parse(token.serialize()))
        XCTAssertEqual(restored.accessToken, "A")
        XCTAssertEqual(restored.secondsValid(now: now), 3600)
        let next = try XboxUserToken.fromResponse(try parseJSON(#"{"access_token":"B","expires_in":10}"#), now: now, previous: token)
        XCTAssertEqual(next.refreshToken, "R")
    }

    func testWindowsStoredTokenAndBadInput() throws {
        let stored = #"{"access_token":"EwA","refresh_token":"M.C5","expires_in":3600,"expires_on":"2026-11-16T10:30:00.123Z"}"#
        XCTAssertEqual(XboxUserToken.parse(stored)?.secondsValid(now: now), 1800)
        XCTAssertNil(XboxUserToken.parse(#"{"access_token":"A"}"#))
        XCTAssertNil(XboxUserToken.parse("bozuk"))
    }

    func testXstsWithSevenFractionDigits() throws {
        let token = try XboxXstsToken.parse(try parseJSON(#"{"NotAfter":"2026-11-16T10:16:00.1234567Z","Token":"T","DisplayClaims":{"xui":[{"uhs":"123"}]}}"#))
        XCTAssertEqual(token.userHash, "123")
        XCTAssertEqual(token.secondsValid(now: now), 960)
    }

    func testHomeEndpointDefaultRegion() throws {
        let endpoint = try XboxHomeEndpoint.parse(try parseJSON(#"""
            {"gsToken":"G","durationInSeconds":14400,"offeringSettings":{"regions":[
            {"baseUri":"https://weu.example/","isDefault":false},{"baseUri":"https://uks.example/","isDefault":true}]}}
            """#), now: now)
        XCTAssertEqual(endpoint.baseURL, "https://uks.example")
        XCTAssertEqual(endpoint.expiresAt, now.addingTimeInterval(14400))
        XCTAssertThrowsError(try XboxHomeEndpoint.parse(try parseJSON(#"{"gsToken":"G","offeringSettings":{"regions":[]}}"#), now: now))
    }

    func testDeviceCodeAndPollClassification() throws {
        let code = try XboxDeviceCode.parse(try parseJSON(#"{"user_code":"ABCD","device_code":"D","verification_uri":"https://www.microsoft.com/link","expires_in":900,"interval":0}"#))
        XCTAssertEqual(code.interval, 1)
        XCTAssertEqual(DeviceCodePoll.classify(status: 400, body: Data(#"{"error":"authorization_pending"}"#.utf8)), .pending)
        XCTAssertEqual(DeviceCodePoll.classify(status: 400, body: Data(#"{"error":"expired_token"}"#.utf8)), .expired)
        XCTAssertEqual(DeviceCodePoll.classify(status: 400, body: Data(#"{"error":"authorization_declined"}"#.utf8)), .declined)
        XCTAssertEqual(DeviceCodePoll.classify(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)), .failed)
        XCTAssertEqual(DeviceCodePoll.classify(status: 503, body: Data()), .pending)
    }

    func testConsoleList() throws {
        let list = XboxConsole.parseList(try parseJSON(#"""
            {"result":[{"id":"F1","name":"Salon","consoleType":"XboxSeriesX","consoleStreamingEnabled":true,"remoteManagementEnabled":true},
            {"id":"F2","name":"Oda","consoleType":"XboxOne","consoleStreamingEnabled":true,"remoteManagementEnabled":false},{"name":"x"}]}
            """#))
        XCTAssertEqual(list.map(\.id), ["F1", "F2"])
        XCTAssertTrue(list[0].streamingEnabled)
        XCTAssertFalse(list[1].streamingEnabled)
    }

    func testFormBodyMatchesAndroid() {
        XCTAssertEqual(formBody([("scope", "xboxlive.signin openid"), ("grant_type", "urn:ietf:params")]),
                       "scope=xboxlive.signin+openid&grant_type=urn%3Aietf%3Aparams")
    }
}

final class XboxAuthTests: XCTestCase {
    func testDeviceCodeFlow() async throws {
        let polls = Counter()
        let http = FakeHTTP { _, url, _ in
            if url.hasSuffix("/devicecode") { return ok(#"{"user_code":"U","device_code":"D","verification_uri":"u","expires_in":900,"interval":5}"#) }
            return polls.next() < 3 ? status(400, #"{"error":"authorization_pending"}"#) : ok(#"{"access_token":"A","refresh_token":"R","expires_in":3600}"#)
        }
        let saved = Box()
        let auth = XboxAuth(http: http, clock: { now }, sleep: { _ in }, onUserToken: { saved.value = $0?.accessToken })
        let code = try await auth.startDeviceCode()
        XCTAssertTrue(http.calls[0].body!.contains("client_id=\(XboxAuth.clientId)"))
        _ = try await auth.pollDeviceCode(code)
        XCTAssertEqual(saved.value, "A")
        let signedIn = await auth.signedIn
        XCTAssertTrue(signedIn)
    }

    func testDeviceCodePollSurvivesNetworkDrops() async throws {
        // Kullanıcı Safari'deyken arka plandaki istek kesilir; giriş bitmemeli, onay gelince tamamlanmalı.
        let polls = Counter()
        let http = FakeHTTP { _, _, _ in
            switch polls.next() {
            case 1: return status(400, #"{"error":"authorization_pending"}"#)
            case 2, 3: return status(-1)
            default: return ok(#"{"access_token":"A","refresh_token":"R","expires_in":3600}"#)
            }
        }
        let auth = XboxAuth(http: http, clock: { now }, sleep: { _ in })
        let token = try await auth.pollDeviceCode(XboxDeviceCode(userCode: "U", deviceCode: "D", verificationURI: "u", expiresIn: 900, interval: 5))
        XCTAssertEqual(token.accessToken, "A")
        XCTAssertEqual(http.calls.count, 4)
    }

    func testChainRefreshesAndCaches() async throws {
        let expired = try XboxUserToken.fromResponse(try parseJSON(#"{"access_token":"OLD","refresh_token":"R","expires_in":30}"#), now: now)
        let http = FakeHTTP { _, url, body in
            if url.hasSuffix("/token") { return ok(#"{"access_token":"NEW","refresh_token":"R2","expires_in":3600}"#) }
            if url.contains("user.auth") {
                XCTAssertTrue(body!.contains("d=NEW"))
                return ok(#"{"Token":"XBL","NotAfter":"2026-11-30T00:00:00Z","DisplayClaims":{"xui":[{"uhs":"H"}]}}"#)
            }
            if url.contains("xsts.auth") { return ok(#"{"Token":"XSTS","NotAfter":"2026-11-17T00:00:00Z","DisplayClaims":{"xui":[{"uhs":"H"}]}}"#) }
            return ok(#"{"gsToken":"GS","durationInSeconds":14400,"offeringSettings":{"regions":[{"baseUri":"https://uks.example/","isDefault":true}]}}"#)
        }
        let auth = XboxAuth(http: http, clock: { now }, sleep: { _ in }, userToken: expired)
        let home = try await auth.homeEndpoint()
        XCTAssertEqual(home.baseURL, "https://uks.example")
        let count = http.calls.count
        _ = try await auth.homeEndpoint()
        XCTAssertEqual(http.calls.count, count)
    }

    func testXstsNoProfile() async throws {
        let token = try XboxUserToken.fromResponse(try parseJSON(#"{"access_token":"A","refresh_token":"R","expires_in":3600}"#), now: now)
        let http = FakeHTTP { _, url, _ in
            url.contains("user.auth") ? ok(#"{"Token":"XBL","NotAfter":"2026-11-30T00:00:00Z","DisplayClaims":{"xui":[{"uhs":"H"}]}}"#)
                : status(401, #"{"XErr":2148916233}"#)
        }
        let auth = XboxAuth(http: http, clock: { now }, userToken: token)
        do {
            _ = try await auth.xsts(XboxAuth.rpXboxLive)
            XCTFail()
        } catch let error as XboxError {
            XCTAssertEqual(error.kind, .noXboxAccount)
        }
    }
}

final class XboxHomeTests: XCTestCase {
    private func tokens(_ url: String) -> XboxHTTPResponse? {
        if url.contains("user.auth") || url.contains("xsts.auth") { return ok(#"{"Token":"X","NotAfter":"2026-11-30T00:00:00Z","DisplayClaims":{"xui":[{"uhs":"H"}]}}"#) }
        if url.contains("/v2/login/user") { return ok(#"{"gsToken":"GS","durationInSeconds":14400,"offeringSettings":{"regions":[{"baseUri":"https://uks.example/","isDefault":true}]}}"#) }
        if url.contains("login.live.com") { return ok(#"{"access_token":"LPT"}"#) }
        return nil
    }

    private func auth(_ http: XboxHTTP) throws -> XboxAuth {
        XboxAuth(http: http, clock: { now }, userToken: try XboxUserToken.fromResponse(try parseJSON(#"{"access_token":"A","refresh_token":"R","expires_in":3600}"#), now: now))
    }

    func testPlayUsesBridgeHeaders() async throws {
        let http = FakeHTTP { _, url, _ in self.tokens(url) ?? ok(#"{"sessionPath":"v5/sessions/home/ABC"}"#) }
        let home = XboxHome(auth: try auth(http), http: http, sleep: { _ in })
        let id = try await home.play(consoleId: "F1")
        XCTAssertEqual(id, "ABC")
        let call = try XCTUnwrap(http.calls.first { $0.url.hasSuffix("/play") })
        XCTAssertEqual(call.headers["Authorization"], "Bearer GS")
        XCTAssertEqual(call.headers["X-MS-Device-Info"], XboxHome.deviceInfo)
        let body = try parseJSON(call.body!)
        XCTAssertEqual(body["serverId"] as? String, "F1")
        XCTAssertEqual((body["settings"] as? JSON)?["nanoVersion"] as? String, "V3;WebrtcTransport.dll")
        XCTAssertNotNil(try? parseJSON(XboxHome.deviceInfo))
    }

    func testSdpExchangeWaitsAndTimesOut() async throws {
        let gets = Counter()
        let http = FakeHTTP { method, url, _ in
            if let t = self.tokens(url) { return t }
            if method == "POST" { return status(202) }
            return gets.next() < 3 ? status(204)
                : ok(jsonText(["exchangeResponse": #"{"messageType":"answer","sdp":"v=0 answer"}"#]))
        }
        let answer = try await XboxHome(auth: try auth(http), http: http, sleep: { _ in }).sdp("S", offer: "v=0")
        XCTAssertEqual(answer, "v=0 answer")

        let never = FakeHTTP { method, url, _ in self.tokens(url) ?? status(method == "POST" ? 202 : 204) }
        do {
            _ = try await XboxHome(auth: try auth(never), http: never, sleep: { _ in }).sdp("S", offer: "v=0")
            XCTFail()
        } catch let error as XboxError {
            XCTAssertEqual(error.kind, .timeout)
        }
        XCTAssertEqual(never.calls.filter { $0.method == "GET" && $0.url.hasSuffix("/sdp") }.count, XboxHome.exchangeAttempts)
    }

    func testIceAddsTeredoCandidates() async throws {
        let remote = #"[{"candidate":"a=candidate:1 1 UDP 100 2001:0000:4136:e378:8000:63bf:3fff:fdd2 1234 typ host ","sdpMLineIndex":0,"sdpMid":"0"},{"candidate":"a=end-of-candidates","sdpMLineIndex":0,"sdpMid":"0"}]"#
        let http = FakeHTTP { method, url, _ in self.tokens(url) ?? (method == "POST" ? status(202) : ok(jsonText(["exchangeResponse": remote]))) }
        let list = try await XboxHome(auth: try auth(http), http: http, sleep: { _ in })
            .ice("S", candidates: [XboxIceCandidate(candidate: "candidate:1 1 udp 1 192.168.1.5 50000 typ host", sdpMid: "0", sdpMLineIndex: 0)])
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list[0].candidate, "a=candidate:10 1 UDP 1 192.0.2.45 9002 typ host ")
        XCTAssertEqual(list[1].candidate, "a=candidate:10 1 UDP 1 192.0.2.45 40000 typ host ")
        XCTAssertEqual(list[0].sdpLine, "candidate:10 1 UDP 1 192.0.2.45 9002 typ host")
        XCTAssertNil(list[3].sdpLine)
    }

    /// Wi-Fi'daki Xbox SDP/ICE yanıtını geç verince 7,5 sn'de bırakılıyordu; artık 30 sn beklenir.
    func testExchangeWaitsThirtySeconds() {
        let total = (0..<XboxHome.exchangeAttempts).map { XboxHome.exchangeDelayMs(attempt: $0) }.reduce(0, +)
        XCTAssertEqual(total, 30_000)
        XCTAssertEqual(XboxHome.exchangeDelayMs(attempt: 0), 250)
        XCTAssertEqual(XboxHome.exchangeDelayMs(attempt: XboxHome.exchangeAttempts - 1), 1000)
    }

    /// Hizmet jetonu süresinden önce reddedilince bir kez yenilenip istek yinelenir; yeniden giriş istenmez.
    func testUnauthorizedRefreshesTokenOnce() async throws {
        let logins = Counter()
        let keepalives = Counter()
        let http = FakeHTTP { _, url, _ in
            if url.contains("/v2/login/user") { _ = logins.next() }
            if let t = self.tokens(url) { return t }
            return keepalives.next() == 1 ? status(401) : status(204)
        }
        try await XboxHome(auth: try auth(http), http: http, sleep: { _ in }).keepalive("S")
        XCTAssertEqual(logins.next(), 3)
    }

    /// Kapatma isteği bir kez başarısız olunca oturum Xbox'ta açık kalıyordu; yinelenir, 404 kapanmış sayılır.
    func testCloseRetriesAndTreatsMissingAsClosed() async throws {
        let deletes = Counter()
        let flaky = FakeHTTP { method, url, _ in
            if let t = self.tokens(url) { return t }
            return method == "DELETE" && deletes.next() < 3 ? status(500) : status(204)
        }
        let closed = await XboxHome(auth: try auth(flaky), http: flaky, sleep: { _ in }).close("S")
        XCTAssertTrue(closed.closed)
        let gone = FakeHTTP { _, url, _ in self.tokens(url) ?? status(404) }
        let missing = await XboxHome(auth: try auth(gone), http: gone, sleep: { _ in }).close("S")
        XCTAssertTrue(missing.closed)
        let down = FakeHTTP { _, url, _ in self.tokens(url) ?? status(503) }
        let failed = await XboxHome(auth: try auth(down), http: down, sleep: { _ in }).close("S")
        XCTAssertFalse(failed.closed)
        XCTAssertEqual(down.calls.filter { $0.method == "DELETE" }.count, XboxSessionClose.delaysMs.count)
    }

    func testBusyClassified() {
        XCTAssertEqual(XboxHome.serviceError(status(400, #"{"code":"ServerInUse"}"#)).kind, .busy)
        XCTAssertEqual(XboxHome.serviceError(status(401)).kind, .signInRequired)
    }
}

final class XboxProtocolTests: XCTestCase {
    func testTeredo() {
        let info = Teredo.inspect("2001:0000:4136:e378:8000:63bf:3fff:fdd2")
        XCTAssertEqual(info?.client4, "192.0.2.45")
        XCTAssertEqual(info?.udpPort, 40000)
        XCTAssertEqual(Teredo.parseIPv6("2001::1"), [0x2001, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertNil(Teredo.parseIPv6("192.168.1.1"))
        XCTAssertNil(Teredo.parseIPv6("2001:::1"))
        XCTAssertNil(Teredo.parseIPv6("2001:0:1"))
    }

    func testClientMetadataPacket() {
        let packet = XboxChannels.clientMetadataPacket(timestampMs: 1234.5)
        XCTAssertEqual(packet.count, 15)
        XCTAssertEqual(packet[0], 8)
        XCTAssertEqual(packet[1], 0)
        XCTAssertEqual(packet[14], 2)
        let bits = packet[6..<14].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        XCTAssertEqual(Double(bitPattern: bits), 1234.5)
    }

    func testFrameAckPacketMatchesPlayer() {
        // Input/Packet.ts: 14 bayt başlık + 1 bayt sayı + kare başına 28 bayt; tür 1 = Metadata.
        let frames = [XboxFrameAck(serverDataKey: 5, arrivalMs: 100, decodedMs: 104), XboxFrameAck(serverDataKey: 3000, arrivalMs: 116, decodedMs: 120)]
        let packet = XboxChannels.frameAckPacket(sequence: 7, timestampMs: 130, frames: frames)
        XCTAssertEqual(packet.count, 14 + 1 + 28 * 2)
        func u32(_ offset: Int) -> UInt32 { packet[offset..<offset + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        XCTAssertEqual(packet[0], 1)
        XCTAssertEqual(u32(2), 7)
        XCTAssertEqual(packet[14], 2)
        XCTAssertEqual((0..<7).map { u32(15 + $0 * 4) }, [5, 100, 100, 104, 104, 130, 130])
        XCTAssertEqual(u32(15 + 28), 3000)
    }

    func testMessagesAndMunging() throws {
        let messages = try XboxChannels.configurationMessages().map { try parseJSON($0) }
        XCTAssertEqual(messages.count, 6)
        XCTAssertEqual(messages[0]["target"] as? String, "/streaming/systemUi/configuration")
        XCTAssertTrue(XboxChannels.isHandshakeAck(#"{"type":"HandshakeAck"}"#))
        XCTAssertFalse(XboxChannels.isHandshakeAck("{bozuk"))
        XCTAssertEqual(XboxChannels.mungeOffer("a=fmtp:111 useinbandfec=1\r\na=fmtp:112 useinbandfec=1"),
                       "a=fmtp:111 useinbandfec=1; stereo=1\r\na=fmtp:112 useinbandfec=1")
        XCTAssertEqual(XboxHome.sessionId(["sessionPath": "v5/sessions/home/ABC"]), "ABC")
        XCTAssertNil(XboxHome.sessionId([:]))
    }
}

final class XboxSessionMachineTests: XCTestCase {
    func testHappyPath() {
        var m = XboxSessionMachine()
        XCTAssertEqual(m.start(), .play)
        XCTAssertEqual(m.played(), .pollState(delayMs: 0))
        XCTAssertEqual(m.status("Provisioning", errorDetails: nil), .pollState(delayMs: 1000))
        XCTAssertEqual(m.status("ReadyToConnect", errorDetails: nil), .connect)
        XCTAssertEqual(m.connected(), .pollState(delayMs: 1000))
        XCTAssertEqual(m.status("ReadyToConnect", errorDetails: nil), .pollState(delayMs: 1000))
        XCTAssertEqual(m.status("Provisioned", errorDetails: nil), .negotiate)
        XCTAssertTrue(m.streaming())
        XCTAssertFalse(m.streaming())
    }

    func testTimeoutFailureAndStop() {
        var m = XboxSessionMachine(maxPolls: 2)
        _ = m.start(); _ = m.played()
        XCTAssertEqual(m.status("Provisioning", errorDetails: nil), .pollState(delayMs: 1000))
        XCTAssertEqual(m.status("Provisioning", errorDetails: nil), .retry(delayMs: 5000))
        XCTAssertEqual(m.start(), .play)
        _ = m.played()
        // Konsol yayını reddetti: yeniden denenmez.
        XCTAssertEqual(m.status("Failed", errorDetails: #"{"code":"ServerInUse"}"#), .retry(delayMs: nil))
        if case let .failed(kind, _, willRetry, _) = m.phase { XCTAssertEqual(kind, .busy); XCTAssertFalse(willRetry) } else { XCTFail() }
        XCTAssertEqual(m.fail(.signInRequired, "giriş"), .retry(delayMs: nil))
        m.stop()
        XCTAssertEqual(m.start(), .nothing)
        XCTAssertEqual(m.fail(.network, "x"), .nothing)
    }

    func testErrorDetailsStopsRetrying() {
        var m = XboxSessionMachine()
        _ = m.start(); _ = m.played()
        // Boş ayrıntı hata sayılmaz.
        XCTAssertEqual(m.status("Provisioning", errorDetails: #"{"code":null,"message":null}"#), .pollState(delayMs: 1000))
        XCTAssertEqual(m.status("Provisioning", errorDetails: #"{"code":"Conflict","message":"x"}"#), .retry(delayMs: nil))
    }

    /// Oynanan (görüntü gelmiş) yayın koparsa kullanıcıya sormadan en çok iki kez, geri çekilerek (5, 15 sn) yeniden
    /// bağlanılır; ikisi de kısa sürede koparsa durulur ve sınırın dolduğu bildirilir ("Xbox bağlantısı koptu"). Görüntü hiç
    /// gelmediyse yine tek deneme. Android'deki realDropReconnectsSilentlyUpToTwoTimes ve Windows'taki aynı adlı testle aynı.
    func testRealDropReconnectsSilentlyUpToTwoTimes() {
        let now = FakeClock()
        var m = XboxSessionMachine(clock: { now.value })
        _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil); _ = m.streaming()
        now.value += 120_000
        XCTAssertEqual(m.maxRetries, 2)
        XCTAssertEqual(m.fail(.network, "kopma"), .retry(delayMs: 5000))
        XCTAssertEqual(m.phase, .failed(.network, message: "kopma", willRetry: true, attempt: 1))
        XCTAssertFalse(m.dropLimitReached)
        // Yeniden bağlanma da kısa sürede koptu: 15 sn sonra yine denenir, üçüncü kopmada durulur.
        _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil); _ = m.streaming()
        now.value += 10_000
        XCTAssertEqual(m.fail(.serverClosed, "Xbox görüntü kanalını kapattı"), .retry(delayMs: 15_000))
        XCTAssertEqual(m.phase, .failed(.serverClosed, message: "Xbox görüntü kanalını kapattı", willRetry: true, attempt: 2))
        _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil); _ = m.streaming()
        now.value += 10_000
        XCTAssertEqual(m.fail(.serverClosed, "Xbox görüntü kanalını kapattı"), .retry(delayMs: nil))
        XCTAssertTrue(m.dropLimitReached)
        // Bağlanırken hata (görüntü hiç gelmedi): eskisi gibi en çok bir deneme.
        var fresh = XboxSessionMachine()
        XCTAssertEqual(fresh.maxRetries, 1)
        XCTAssertEqual(fresh.fail(.network, "kopma"), .retry(delayMs: 5000))
        XCTAssertEqual(fresh.fail(.network, "kopma"), .retry(delayMs: nil))
    }

    func testRetryLine() {
        XCTAssertEqual(XboxEndCause.retryLine(attempt: 2, of: 3, delayMs: 15_000), "sessiz yeniden bağlanma 2/3: 15 sn sonra")
        XCTAssertEqual(XboxEndCause.retryLine(attempt: 4, of: 3, delayMs: 15_000), "sessiz yeniden bağlanma ek deneme: 15 sn sonra")
    }

    func testHealthyStreamResetsRetries() {
        let now = FakeClock()
        var m = XboxSessionMachine(clock: { now.value })
        _ = m.fail(.network, "kopma")
        _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil); _ = m.streaming()
        now.value += Double(XboxSessionMachine.defaultHealthyStreamMs)
        XCTAssertEqual(m.fail(.network, "kopma"), .retry(delayMs: 5000))
        // Kısa süren yayın sayacı sıfırlamaz: ikinci deneme daha uzun bekler.
        _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil); _ = m.streaming()
        now.value += 1_000
        XCTAssertEqual(m.fail(.network, "kopma"), .retry(delayMs: 15_000))
    }

    /// #1252: birkaç dakikada bir kopan yayın. Eskiden sayaç 60 sn'lik yayından sonra sıfırlanıyordu: her kopmada yeniden
    /// bağlanılıyor, Xbox'ta "uzaktan yürütme durdu / başladı" bildirimi sonsuza dek tekrarlanıyordu. Artık sayaç ancak 10 dk
    /// sağlıklı yayından sonra sıfırlanır ve 10 dk içinde en çok iki sessiz yeniden bağlanma yapılır; sonra durulur.
    func testStreamDroppingEveryFewMinutesStopsAfterTwoReconnects() {
        let now = FakeClock()
        var m = XboxSessionMachine(clock: { now.value })
        var retries: [Int?] = []
        for _ in 0..<10 where !m.dropLimitReached {
            _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil); _ = m.streaming()
            now.value += 3 * 60_000
            guard case let .retry(delay) = m.fail(.network, "Xbox ICE bağlantısı koptu (failed)") else { return XCTFail() }
            retries.append(delay)
            now.value += Double(delay ?? 0)
        }
        XCTAssertEqual(retries, [5000, 15_000, nil])
        XCTAssertTrue(m.dropLimitReached)
        XCTAssertEqual(XboxEndCause.limitLine, "sessiz yeniden bağlanma sınırı doldu (10 dk içinde en çok 2): yeniden denenmiyor, yayın durdu")
    }

    /// Kopmadan sonraki ret için tanınan deneme de oturum sınırına sayılır: döngüye ek bildirim katmaz.
    func testGraceRetryCountsTowardsTheSessionLimit() {
        let now = FakeClock()
        var m = XboxSessionMachine(clock: { now.value })
        _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil); _ = m.streaming()
        now.value += 3 * 60_000
        XCTAssertEqual(m.fail(.network, "kopma"), .retry(delayMs: 5000))
        // Xbox eski oturumu bırakmadan yenisini reddetti: bir kez, 15 sn sonra denenir (ikinci deneme).
        _ = m.start(); _ = m.played()
        XCTAssertEqual(m.status("Failed", errorDetails: nil), .retry(delayMs: 15_000))
        _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil); _ = m.streaming()
        now.value += 3 * 60_000
        XCTAssertEqual(m.fail(.network, "kopma"), .retry(delayMs: nil))
        XCTAssertTrue(m.dropLimitReached)
    }

    /// #1216'nın amacı: tek, kısa bir Wi-Fi takılması kullanıcı fark etmeden kapanır; seyrek kopmalar da hep sessiz.
    func testSingleDropIsSilentAndRareDropsStaySilent() {
        let now = FakeClock()
        var m = XboxSessionMachine(clock: { now.value })
        for _ in 0..<5 {
            _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil); _ = m.streaming()
            now.value += 25 * 60_000
            XCTAssertEqual(m.fail(.network, "kopma"), .retry(delayMs: 5000))
            XCTAssertFalse(m.dropLimitReached)
            now.value += 5000
        }
        // Takılmada ilk deneme Xbox eski oturumu bırakmadan düştü: ikinci deneme yine sessiz.
        _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil)
        XCTAssertEqual(m.fail(.network, "kopma"), .retry(delayMs: 15_000))
        XCTAssertFalse(m.dropLimitReached)
    }

    /// Görüntü akarken başarısız canlı tutma (404 dahil) yayını kapatmaz; görüntü durmuşsa eskisi gibi kapatır.
    func testKeepaliveFailureDoesNotEndAFlowingStream() {
        XCTAssertFalse(XboxKeepalive.shouldEnd(gone: true, exhausted: false, pictureFlowing: true))
        XCTAssertFalse(XboxKeepalive.shouldEnd(gone: false, exhausted: true, pictureFlowing: true))
        XCTAssertTrue(XboxKeepalive.shouldEnd(gone: true, exhausted: false, pictureFlowing: false))
        XCTAssertTrue(XboxKeepalive.shouldEnd(gone: false, exhausted: true, pictureFlowing: false))
        XCTAssertFalse(XboxKeepalive.shouldEnd(gone: false, exhausted: false, pictureFlowing: false))
    }

    /// Eskiden görüntüsüz her bağlantı ~60 sn sürüp dört kez açılıp kapanıyordu (Xbox'ta "uzaktan oynatma başlatıldı / durduruldu").
    func testConnectionsWithoutPictureStopAfterTwoAttempts() {
        var m = XboxSessionMachine()
        XCTAssertEqual(m.fail(.noFirstFrame, "görüntü yok"), .retry(delayMs: 5000))
        XCTAssertEqual(m.fail(.noFirstFrame, "görüntü yok"), .retry(delayMs: nil))
        if case let .failed(kind, _, willRetry, _) = m.phase { XCTAssertEqual(kind, .noFirstFrame); XCTAssertFalse(willRetry) } else { XCTFail() }
        XCTAssertEqual(XboxStop.classify("Xbox WebRTC bağlantısı kesildi", kind: .noFirstFrame), .noPicture)
    }

    /// #1432: ses gelip görüntü gelmeyen bağlantı yeniden denenmez; ekranda "Xbox'u tam kapatıp açın" (Windows ve Android'le aynı).
    func testAudioWithoutPictureIsNotRetriedAndAsksForAFullRestart() {
        let reason = XboxFirstFrameWatch.noPictureReason(audioOnly: true)
        XCTAssertEqual(reason, "Xbox'tan 30 sn içinde görüntü gelmedi (ses geliyor, görüntü 0 bayt)")
        XCTAssertEqual(XboxFirstFrameWatch.noPictureReason(audioOnly: false), "Xbox'tan 30 sn içinde görüntü gelmedi")
        XCTAssertTrue(XboxStop.isAudioOnly(reason))
        XCTAssertEqual(XboxStop.classify(reason, kind: .noFirstFrame), .stuckPicture)
        XCTAssertEqual(XboxStop.classify(XboxFirstFrameWatch.noPictureReason(audioOnly: false), kind: .noFirstFrame), .noPicture)
        var m = XboxSessionMachine()
        XCTAssertEqual(m.fail(.noFirstFrame, reason), .retry(delayMs: nil))
        if case let .failed(kind, _, willRetry, _) = m.phase { XCTAssertEqual(kind, .noFirstFrame); XCTAssertFalse(willRetry) } else { XCTFail() }
        XCTAssertFalse(m.dropLimitReached)
        var plain = XboxSessionMachine()
        XCTAssertEqual(plain.fail(.noFirstFrame, XboxFirstFrameWatch.noPictureReason(audioOnly: false)), .retry(delayMs: 5000))
    }

    /// #871: Xbox kartında Xbox'ın JSON hata nesnesi olduğu gibi görünüyordu.
    static let cloudServiceTimeout = #"{"message":"Agent : -2147019873 : Timed out waiting for Cloud Streaming Service to be ready. at xbox\\streaming\\manager"}"#

    func testCloudStreamingServiceTimeoutIsReadableAndNotRetried() {
        let reason = Self.cloudServiceTimeout
        XCTAssertEqual(XboxStop.errorCode(reason), "0x8007139F")
        XCTAssertEqual(XboxStop.errorCode(reason), XboxStop.serviceNotReadyCode)
        XCTAssertEqual(XboxStop.classify(reason, kind: .consoleUnavailable), .serviceNotReady)
        XCTAssertEqual(XboxStop.classify("Xbox service HTTP 500: " + reason), .serviceNotReady)
        XCTAssertTrue(XboxStop.errorMessage(reason)!.hasPrefix(#"Agent : -2147019873 : Timed out waiting for Cloud Streaming Service to be ready. at xbox\streaming"#))
        // errorDetails olarak da HTTP hatası olarak da gelse yeniden denenmez.
        var fromState = XboxSessionMachine()
        _ = fromState.start(); _ = fromState.played()
        XCTAssertEqual(fromState.status("Provisioning", errorDetails: reason), .retry(delayMs: nil))
        var fromHTTP = XboxSessionMachine()
        XCTAssertEqual(fromHTTP.fail(.service, "Xbox service HTTP 500: " + reason), .retry(delayMs: nil))
        if case let .failed(_, _, willRetry, _) = fromHTTP.phase { XCTAssertFalse(willRetry) } else { XCTFail() }
    }

    func testUnknownXboxErrorShowsOnlyTheCode() {
        let reason = #"{"message":"Agent : -2147024891 : Access is denied."}"#
        XCTAssertEqual(XboxStop.classify(reason), .startFailed)
        XCTAssertEqual(XboxStop.displayReason(reason, .startFailed), "0x80070005")
        XCTAssertEqual(XboxStop.displayReason(#"{"code":"Conflict","message":"x"}"#, .startFailed), "Conflict")
        XCTAssertEqual(XboxStop.errorCode("hr 0x8007139f"), "0x8007139F")
        XCTAssertEqual(XboxStop.errorCode(#"{"code":null,"message":"x"}"#), nil)
        XCTAssertEqual(XboxStop.classify(#"{"message":"something odd"}"#), .other)
        XCTAssertEqual(XboxStop.displayReason(#"{"message":"something odd"}"#, .other), "something odd")
        XCTAssertEqual(XboxStop.displayReason(#"Xbox service HTTP 500: {"x":1}"#, .other), "Xbox service HTTP 500")
        XCTAssertEqual(XboxStop.displayReason("Xbox WebRTC bağlantısı kesildi", .other), "Xbox WebRTC bağlantısı kesildi")
        // Bilinmeyen hata yeniden deneme kuralını değiştirmez.
        var m = XboxSessionMachine()
        XCTAssertEqual(m.fail(.service, reason), .retry(delayMs: 5000))
    }

    func testPictureResetsTheNoPictureStreak() {
        let now = FakeClock()
        var m = XboxSessionMachine(clock: { now.value })
        XCTAssertEqual(m.fail(.noFirstFrame, "görüntü yok"), .retry(delayMs: 5000))
        _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil); _ = m.streaming()
        now.value += Double(XboxSessionMachine.defaultHealthyStreamMs)
        // Görüntü geldi: görüntüsüz bağlantı dizisi baştan sayılır, bu görüntüsüz bağlantı durdurmaz.
        XCTAssertEqual(m.fail(.noFirstFrame, "görüntü yok"), .retry(delayMs: 5000))
    }

    /// "Bir kez kopunca tekrar bağlanmıyor": görüntü gelmiş yayın koptuktan sonra Xbox eski oturumu bırakmadan yenisini
    /// reddedebiliyor. Bu ret bir kez, uzun beklenip denenir; ikinci ret yayını durdurur.
    func testRefusalAfterDropIsRetriedOnce() {
        var m = XboxSessionMachine()
        _ = m.start(); _ = m.played(); _ = m.status("Provisioned", errorDetails: nil); _ = m.streaming()
        XCTAssertEqual(m.fail(.network, "kopma"), .retry(delayMs: 5000))
        _ = m.start(); _ = m.played()
        XCTAssertEqual(m.status("Failed", errorDetails: XboxSessionMachineTests.cloudServiceTimeout), .retry(delayMs: XboxSessionMachine.reconnectGraceMs))
        _ = m.start(); _ = m.played()
        XCTAssertEqual(m.status("Failed", errorDetails: #"{"code":"Conflict"}"#), .retry(delayMs: nil))
        // Görüntü hiç gelmeden gelen ret eskisi gibi denenmez.
        var fresh = XboxSessionMachine()
        _ = fresh.start(); _ = fresh.played()
        XCTAssertEqual(fresh.status("Failed", errorDetails: #"{"code":"Conflict"}"#), .retry(delayMs: nil))
    }

    func testEndCauseAndSummary() {
        XCTAssertEqual(XboxEndCause.of(.serverClosed), .server)
        XCTAssertEqual(XboxEndCause.of(.timeout), .timeout)
        XCTAssertEqual(XboxEndCause.of(.noFirstFrame), .timeout)
        XCTAssertEqual(XboxEndCause.of(.network), .network)
        XCTAssertEqual(XboxEndCause.of(.noPicture), .network)
        XCTAssertEqual(XboxEndCause.line(.serverClosed, "Xbox görüntü kanalını kapattı"), "kapanma nedeni: sunucu kapattı (Xbox görüntü kanalını kapattı)")
        XCTAssertEqual(XboxStop.summary(reason: "x", frames: 3, acks: 2, secondsSinceFirstFrame: 1, cause: .network),
                       "bağlantı bitti (ağ): x; kare 3, onay 2, ilk kareden sonra 1 sn")
        XCTAssertTrue(XboxKeepalive.sessionGone("Xbox service HTTP 404: "))
        XCTAssertFalse(XboxKeepalive.sessionGone("Xbox service HTTP 500: "))
    }

    func testOutOfOrderIgnored() {
        var m = XboxSessionMachine()
        XCTAssertEqual(m.played(), .nothing)
        XCTAssertEqual(m.status("Provisioned", errorDetails: nil), .nothing)
        XCTAssertFalse(m.streaming())
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private final class FakeClock: @unchecked Sendable {
    var value: Double = 1_000
}

private final class Box: @unchecked Sendable {
    var value: String?
}
