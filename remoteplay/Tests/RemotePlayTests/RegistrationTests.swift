// SPDX-License-Identifier: AGPL-3.0-only

import CChiaki
import XCTest
@testable import RemotePlay

final class RegistrationReasonTests: XCTestCase {
    /// PS5'in red nedeni yalnız libchiaki günlüğünde gelir; oradan okunmalı.
    func testReasonIsReadFromChiakiLog() {
        XCTAssertEqual(Registration.reason(fromLog: "Reported Application Reason: 0x80108b02 (Invalid PSN ID)"), 0x80108b02)
        XCTAssertNil(Registration.reason(fromLog: "Regist waiting for response"))
    }

    func testPs5ReasonsMapToTheirOwnKind() {
        XCTAssertEqual(Registration.kind(reason: 0x80108b02, errors: []), .wrongAccount)
        XCTAssertEqual(Registration.kind(reason: 0x80108b09, errors: []), .wrongCode)
        XCTAssertEqual(Registration.kind(reason: 0x80108b10, errors: []), .inUse)
        XCTAssertEqual(Registration.kind(reason: 0x80108b11, errors: []), .versionMismatch)
        XCTAssertEqual(Registration.kind(reason: 0x80108b15, errors: []), .consoleCrashed)
        XCTAssertEqual(Registration.kind(reason: 0x80108bff, errors: []), .failed)
        XCTAssertEqual(Registration.kind(reason: nil, errors: []), .failed)
        // PS5 kod bildirdiyse arama aşaması geçilmiştir.
        XCTAssertEqual(Registration.kind(reason: 0x80108b09, errors: ["Regist timed out waiting for search response"]), .wrongCode)
    }

    /// PS5 kod bildirmediyse libchiaki'nin hata satırlarından nerede kalındığı anlaşılır (satırlar regist.c'den).
    func testChiakiErrorLinesAreClassified() {
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist timed out waiting for search response", "Regist search failed"]), .noAnswer)
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist failed to send search: Host is down", "Regist search failed"]), .noAnswer)
        // PS5 aramaya yanıt verdi, eşleştirme bağlantısı açılamadı: "yanıt vermedi" değil.
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist connect failed: Timeout, attempt 1 of 3", "Regist eventually failed to connect for request"]), .connectFailed)
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist failed to send search: No route to host", "Regist search failed"]), .localNetworkBlocked)
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist failed to getaddrinfo on 192.168.1.", "Regist eventually failed"]), .badAddress)
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist failed to receive response HTTP header", "Regist eventually failed"]), .noReply)
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist timed out receiving response content"]), .noReply)
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist response is missing RegistKey (or it was invalid)"]), .failed)
    }

    /// #590'daki remoteplay.log'un satırları: PS5 ilk aramaya yanıt verdi, bağlantı açılamadı; sonraki aramaları
    /// reddetti. Her aşama kendi türünü alır ve yalnız yanıtsız arama yeniden denenir.
    func testIssue590LinesAreClassified() {
        // Eşleştirme ekranı kapalıyken (ya da PS5 dinlenmedeyken) arama reddedilir.
        let refused = ["Regist failed to receive search response: Connection refused", "Regist search failed"]
        XCTAssertEqual(Registration.kind(reason: nil, errors: refused), .pairingClosed)
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist failed to receive search response: WSA error 10054", "Regist search failed"]), .pairingClosed)
        // Yamasız libchiaki nedeni yazmaz; yine de "PS5 yanıt vermedi" denmez.
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist connect failed: Network error", "Regist eventually failed to connect for request"]), .connectFailed)
        // Yamalı libchiaki errno'yu yazar: yerel ağ izni ve boş port kalmaması ayrı anlatılır.
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist connect failed: Network error (No route to host), attempt 1 of 3",
                                                               "Regist eventually failed to connect for request"]), .localNetworkBlocked)
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist connect failed: Network error (Can't assign requested address), attempt 3 of 3",
                                                               "Regist eventually failed to connect for request"]), .noFreePort)
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist connect failed: Network error (WSA error 10055), attempt 3 of 3",
                                                               "Regist eventually failed to connect for request"]), .noFreePort)
        XCTAssertEqual(Registration.kind(reason: nil, errors: ["Regist connect failed: could not create request socket (Too many open files), attempt 1 of 3",
                                                               "Regist eventually failed to connect for request"]), .noFreePort)
    }

    func testOnlyAnUnansweredSearchIsRetried() {
        XCTAssertTrue(Registration.shouldRetry(Registration.RegistrationError(.noAnswer), attempt: 1))
        XCTAssertTrue(Registration.shouldRetry(Registration.RegistrationError(.noAnswer), attempt: 2))
        XCTAssertFalse(Registration.shouldRetry(Registration.RegistrationError(.noAnswer), attempt: Registration.searchAttempts))
        let kinds: [Registration.RegistrationError.Kind] = [.pairingClosed, .connectFailed, .noFreePort, .localNetworkBlocked, .wrongCode, .noReply]
        for kind in kinds {
            XCTAssertFalse(Registration.shouldRetry(Registration.RegistrationError(kind), attempt: 1), kind.rawValue)
        }
    }

    func testDetailPrefersThePs5Reason() {
        XCTAssertEqual(Registration.detail(from: ["Regist received HTTP code 403", "Reported Application Reason: 0x80108b09 (Regist failed, probably invalid PIN)",
                                                  "Regist eventually failed"]), "0x80108b09 (Regist failed, probably invalid PIN)")
        XCTAssertEqual(Registration.detail(from: ["Regist received HTTP code 500", "Regist eventually failed"]), "Regist received HTTP code 500")
        XCTAssertNil(Registration.detail(from: []))
    }

    /// libchiaki'nin üç bitiş olayı da sonuca dönüşür; başarısız ve iptal edilen kayıt yok sayılmaz.
    func testEveryRegistEventTypeHasAResult() {
        var host = ChiakiRegisteredHost()
        RemotePlay.copy(Data("PS5-123".utf8), into: &host.server_nickname)
        RemotePlay.copy(Data("0123abcd".utf8), into: &host.rp_regist_key)
        RemotePlay.copy(Data(repeating: 7, count: 16), into: &host.rp_key)
        guard case .success(let console) = Registration.result(type: CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS, host: host,
                                                               reason: nil, errors: []) else { return XCTFail("Başarı bekleniyordu") }
        XCTAssertEqual(console.name, "PS5-123")
        XCTAssertEqual(console.wakeCredential, 0x0123abcd)

        XCTAssertEqual(failure(CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS, host: nil)?.kind, .failed)
        XCTAssertEqual(failure(CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS, host: ChiakiRegisteredHost())?.kind, .failed)
        XCTAssertEqual(failure(CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED)?.kind, .canceled)
        let failed = failure(CHIAKI_REGIST_EVENT_TYPE_FINISHED_FAILED, reason: 0x80108b02,
                             errors: ["Regist received HTTP code 403", "Reported Application Reason: 0x80108b02 (Invalid PSN ID)"])
        XCTAssertEqual(failed?.kind, .wrongAccount)
        XCTAssertEqual(failed?.reason, 0x80108b02)
        XCTAssertEqual(failed?.detail, "0x80108b02 (Invalid PSN ID)")
    }

    private func failure(_ type: ChiakiRegistEventType, host: ChiakiRegisteredHost? = nil, reason: UInt32? = nil,
                         errors: [String] = []) -> Registration.RegistrationError? {
        guard case .failure(let error) = Registration.result(type: type, host: host, reason: reason, errors: errors) else { return nil }
        return error
    }
}

final class PinTests: XCTestCase {
    func testEightDigitsAreRead() {
        XCTAssertEqual(Registration.pin(from: "12345678"), 12345678)
        XCTAssertEqual(Registration.pin(from: "1234 5678"), 12345678)
        XCTAssertEqual(Registration.pin(from: " 1234-5678\n"), 12345678)
        XCTAssertEqual(Registration.pin(from: "01234567"), 1234567)
        // Tam genişlikli ve Arapça-Hint rakamlar
        XCTAssertEqual(Registration.pin(from: "１２３４５６７８"), 12345678)
        XCTAssertEqual(Registration.pin(from: "١٢٣٤٥٦٧٨"), 12345678)
    }

    func testOtherInputIsRejected() {
        XCTAssertNil(Registration.pin(from: ""))
        XCTAssertNil(Registration.pin(from: "1234567"))
        XCTAssertNil(Registration.pin(from: "123456789"))
        XCTAssertNil(Registration.pin(from: "1234567O"))
        XCTAssertNil(Registration.pin(from: "1234567½"))
        XCTAssertNil(Registration.pin(from: "①2345678"))
    }
}

final class DiscoveryTargetTests: XCTestCase {
    private func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }

    /// /24 ağda her adres, ağın yayın adresi ve genel yayın sorulur.
    func testSmallNetworkIsScannedAndBroadcast() {
        let targets = Console.targets(networks: [(ip(192, 168, 1, 10), ip(255, 255, 255, 0))])
        XCTAssertEqual(targets.count, 253 + 2)
        XCTAssertTrue(targets.contains(ip(192, 168, 1, 20)))
        XCTAssertFalse(targets.contains(ip(192, 168, 1, 10)))
        XCTAssertTrue(targets.contains(ip(192, 168, 1, 255)))
        XCTAssertTrue(targets.contains(0xFFFF_FFFF))
    }

    /// /16 Wi-Fi yanında bir sanal arayüz varken PS5'in ağına da (yayınla) sorulur; eskiden hiç sorulmuyordu.
    func testLargeNetworkIsStillBroadcastBesideAnotherInterface() {
        let targets = Console.targets(networks: [(ip(10, 0, 5, 7), ip(255, 255, 0, 0)), (ip(192, 168, 64, 1), ip(255, 255, 255, 0))])
        XCTAssertTrue(targets.contains(ip(10, 0, 255, 255)))
        XCTAssertTrue(targets.contains(0xFFFF_FFFF))
        XCTAssertFalse(targets.contains(ip(10, 0, 5, 8)))
        XCTAssertEqual(Set(targets).count, targets.count)
    }

    func testNoNetworkStillBroadcasts() {
        XCTAssertEqual(Console.targets(networks: []), [0xFFFF_FFFF])
    }
}

final class RemotePlayLogTests: XCTestCase {
    func testLinesAreWrittenOnlyWhenEnabled() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remoteplay-log-\(UUID())")
        let file = folder.appendingPathComponent("remoteplay.log")
        defer { try? FileManager.default.removeItem(at: folder) }
        RemotePlayLog.write("yazılmamalı")
        RemotePlayLog.enable(file: file)
        RemotePlayLog.write("PS5 kaydı başarısız (192.168.1.20, deneme 1): wrongCode")
        RemotePlayLog.disable()
        RemotePlayLog.write("bu da yazılmamalı")
        RemotePlayLog.flush()
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("PS5 kaydı başarısız (192.168.1.20, deneme 1): wrongCode"))
        XCTAssertFalse(text.contains("yazılmamalı"))
    }

    func testDisplayPathPointsToUserLogs() {
        XCTAssertTrue(RemotePlayLog.defaultFile.path.hasSuffix("Library/Logs/CouchSubs/remoteplay.log"))
        XCTAssertEqual(RemotePlayLog.displayPath, "~/Library/Logs/CouchSubs/remoteplay.log")
    }
}
