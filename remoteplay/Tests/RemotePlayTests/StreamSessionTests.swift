// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import RemotePlay
import CChiaki

final class FrameThrottleTests: XCTestCase {
    func testThirtyFramesPerSecondPassAtMostFourTimes() {
        var clock = Date(timeIntervalSince1970: 0)
        var throttle = FrameThrottle(minInterval: 0.25, now: { clock })
        var passed = 0
        for _ in 0..<30 {
            if throttle.shouldPass() { passed += 1 }
            clock.addTimeInterval(1.0 / 30)
        }
        XCTAssertLessThanOrEqual(passed, 5)
        XCTAssertGreaterThanOrEqual(passed, 4)
    }
}

final class ReconnectPolicyTests: XCTestCase {
    func testBackoffDoublesUpToThirtySeconds() {
        var policy = ReconnectPolicy()
        XCTAssertEqual((0..<7).map { _ in policy.nextDelay() }, [2, 4, 8, 16, 30, 30, 30])
    }

    func testResetStartsOver() {
        var policy = ReconnectPolicy()
        _ = policy.nextDelay(); _ = policy.nextDelay()
        policy.reset()
        XCTAssertEqual(policy.nextDelay(), 2)
    }

    /// Bağlanıp birkaç saniyede düşen oturum aralığı sıfırlamaz: aç-kapa döngüsü 2 sn'de bir değil, giderek seyrek döner.
    func testShortSessionsKeepBackingOff() {
        var policy = ReconnectPolicy()
        let start = Date(timeIntervalSince1970: 0)
        var delays: [Int] = []
        for round in 0..<6 {
            let connected = start.addingTimeInterval(Double(round) * 100)
            policy.connected(at: connected)
            policy.ended(at: connected.addingTimeInterval(5))
            delays.append(policy.nextDelay())
        }
        XCTAssertEqual(delays, [2, 4, 8, 16, 30, 30])
    }

    func testAStableSessionStartsTheBackoffOver() {
        var policy = ReconnectPolicy()
        _ = policy.nextDelay(); _ = policy.nextDelay(); _ = policy.nextDelay()
        let connected = Date(timeIntervalSince1970: 0)
        policy.connected(at: connected)
        policy.ended(at: connected.addingTimeInterval(ReconnectPolicy.stableAfter + 1))
        XCTAssertEqual(policy.nextDelay(), 2)
    }

    func testInUseWaitsAtLeastEightSeconds() {
        var policy = ReconnectPolicy()
        XCTAssertEqual(policy.nextDelay(inUse: true), 8)
        XCTAssertEqual(policy.nextDelay(inUse: true), 16)
        XCTAssertEqual(policy.nextDelay(inUse: true), 30)
    }
}

/// Kablosuz ağda akış sık kopuyordu (GitHub #388, #401): on dakikada iki kopmadan sonra 720p istenir.
final class QualityFallbackTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    func testTwoDropsWithinWindowLowerTo720p() {
        var quality = QualityFallback()
        XCTAssertFalse(quality.dropped(at: start))
        XCTAssertFalse(quality.lowered)
        XCTAssertTrue(quality.dropped(at: start.addingTimeInterval(120)))
        XCTAssertTrue(quality.lowered)
        // Bir kez düşürülür; sonraki kopmalar yeniden bildirmez.
        XCTAssertFalse(quality.dropped(at: start.addingTimeInterval(130)))
        XCTAssertTrue(quality.lowered)
    }

    func testDropsFarApartKeep1080p() {
        var quality = QualityFallback()
        XCTAssertFalse(quality.dropped(at: start))
        XCTAssertFalse(quality.dropped(at: start.addingTimeInterval(QualityFallback.window + 1)))
        XCTAssertFalse(quality.dropped(at: start.addingTimeInterval(2 * QualityFallback.window + 2)))
        XCTAssertFalse(quality.lowered)
    }

    func testOnlyNetworkLikeDropsCount() {
        XCTAssertTrue(QualityFallback.countsAsDrop(.network))
        XCTAssertTrue(QualityFallback.countsAsDrop(.other(PictureWatchdog.reason)))
        XCTAssertFalse(QualityFallback.countsAsDrop(.inUse))
        XCTAssertFalse(QualityFallback.countsAsDrop(.rejected(0x80108bff)))
        XCTAssertFalse(QualityFallback.countsAsDrop(.registrationInvalid))
        XCTAssertFalse(QualityFallback.countsAsDrop(.stopped))
    }
}

final class PictureWatchdogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    /// Hata: istenen IDR karesi de bozuk gelince libchiaki yeniden istemiyor, bağlantı açık kalıp hiç kare gelmiyordu;
    /// oturum hiç yeniden kurulmuyor, altyazı ancak uygulamayı kapatıp açınca dönüyordu.
    func testConnectedWithoutPictureForEightSecondsIsStalled() {
        var watchdog = PictureWatchdog()
        watchdog.connected(at: start)
        for second in 1...120 { watchdog.picture(at: start.addingTimeInterval(Double(second))) }
        // İki dakika görüntü geldi, sonra kesildi.
        XCTAssertNil(watchdog.stalled(at: start.addingTimeInterval(127)))
        XCTAssertEqual(watchdog.stalled(at: start.addingTimeInterval(128)), PictureWatchdog.stallAfter)
    }

    /// Olağan FEC duraklaması (IDR bir saniyeden kısa sürede gelir) oturumu yeniden kurdurmaz.
    func testShortGapIsNotAStall() {
        var watchdog = PictureWatchdog()
        watchdog.connected(at: start)
        watchdog.picture(at: start.addingTimeInterval(1))
        watchdog.picture(at: start.addingTimeInterval(2.5))
        XCTAssertNil(watchdog.stalled(at: start.addingTimeInterval(9)))
    }

    /// Bağlandıktan sonra ilk kare hiç gelmezse de yakalanır.
    func testNoFirstPictureIsStalled() {
        var watchdog = PictureWatchdog()
        watchdog.connected(at: start)
        XCTAssertNotNil(watchdog.stalled(at: start.addingTimeInterval(PictureWatchdog.stallAfter)))
    }

    /// Hata: hiç görüntü gelmeyen oturum sonsuza dek yeniden kuruluyordu ("Yeniden bağlanılıyor…"). Art arda 3
    /// görüntüsüz oturumdan sonra durulur; görüntü gelirse sayaç sıfırlanır (Android'deki eşi ile aynı).
    func testNoPictureSessionsGiveUpAfterThree() {
        var watchdog = PictureWatchdog()
        watchdog.connected(at: start)
        XCTAssertEqual(watchdog.afterStall(), .reconnect)
        watchdog.ended()
        watchdog.connected(at: start)
        watchdog.picture(at: start.addingTimeInterval(1))
        XCTAssertEqual(watchdog.noPictureSessions, 0)
        XCTAssertEqual(watchdog.afterStall(), .reconnect)
        for _ in 1..<PictureWatchdog.maxNoPictureSessions {
            watchdog.connected(at: start)
            XCTAssertEqual(watchdog.afterStall(), .reconnect)
        }
        watchdog.connected(at: start)
        XCTAssertEqual(watchdog.afterStall(), .giveUp)
        watchdog.reset()
        XCTAssertEqual(watchdog.noPictureSessions, 0)
    }

    /// Bağlı değilken (bağlanıyor, koptu, durduruldu) görüntü beklenmez; geç gelen eski kare de bekçiyi kurmaz.
    func testNotConnectedIsNeverStalled() {
        var watchdog = PictureWatchdog()
        watchdog.picture(at: start)
        XCTAssertNil(watchdog.stalled(at: start.addingTimeInterval(600)))
        watchdog.connected(at: start)
        watchdog.ended()
        XCTAssertNil(watchdog.stalled(at: start.addingTimeInterval(600)))
    }
}

final class RegisteredConsoleTests: XCTestCase {
    func testWakeCredentialIsHexOfRegistKey() {
        let console = RegisteredConsole(host: "192.168.1.253", name: "PS5", registKey: Data("1a2b3c4d".utf8) + Data(repeating: 0, count: 8),
                                        morning: Data(repeating: 7, count: 16))
        XCTAssertEqual(console.wakeCredential, 0x1a2b3c4d)
    }
}

final class ConsoleSubnetTests: XCTestCase {
    func testSlash24ListsOtherHosts() {
        let hosts = Console.hosts(address: 0xC0A8_010A, netmask: 0xFFFF_FF00)   // 192.168.1.10/24
        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, 0xC0A8_0101)
        XCTAssertEqual(hosts.last, 0xC0A8_01FE)
        XCTAssertFalse(hosts.contains(0xC0A8_010A))
    }

    func testCellularAdapterIsNotSearched() {
        XCTAssertTrue(Console.isCellular("pdp_ip0"))
        XCTAssertFalse(Console.isCellular("en0"))
    }

    func testLargeNetworksAreSkipped() {
        XCTAssertTrue(Console.hosts(address: 0x0A00_0001, netmask: 0xFFFF_0000).isEmpty)
    }
}

final class StreamSessionLifecycleTests: XCTestCase {
    /// Bağlanamayan bir adreste yeniden deneme beklerken durdurup bırakmak çökmemeli ve bloklamamalı.
    func testStopWhileReconnectingDoesNotCrashOrBlock() throws {
        var session: StreamSession? = StreamSession(
            console: RegisteredConsole(host: "127.0.0.1", name: "test", registKey: Data(repeating: 0x31, count: 16), morning: Data(repeating: 1, count: 16)),
            accountId: Data(repeating: 1, count: 8))
        let disconnected = expectation(description: "kopma bildirildi")
        disconnected.assertForOverFulfill = false
        session?.onState = { if case .disconnected = $0 { disconnected.fulfill() } }
        session?.start()
        wait(for: [disconnected], timeout: 15)

        let begin = Date()
        session?.stop()
        XCTAssertLessThan(Date().timeIntervalSince(begin), 0.2)
        session = nil
        // Bekleyen yeniden deneme bloğu çalışacağı zamanı geçir; süreç hâlâ ayaktaysa çökme yok.
        Thread.sleep(forTimeInterval: 3)
    }

    /// GitHub #21: oturum iş parçacığı çalışırken sahibi (`StreamSession`) bırakılıp oturum arka planda kapatılınca
    /// kapanan iş parçacığı günlüğe yazar. Günlük kutuyla birlikte yaşamalı; yoksa serbest kalmış belleğe yazılır.
    /// İş parçacığı 9295 portunda bağlanıp yanıt bekleyen sessiz bir dinleyiciyle canlı tutulur. Bozuk sürümü
    /// kesin yakalamak için `MallocScribble=1` ile çalıştırılabilir (serbest bellek 0x55 ile dolar).
    func testSessionThreadLogsIntoLiveLoggerWhileTornDownAfterOwnerIsGone() throws {
        let listener: SilentListener
        do { listener = try SilentListener(port: 9295) } catch { throw XCTSkip("9295 portu kullanılamıyor: \(error)") }
        defer { listener.close() }

        weak var weakLogger: ChiakiLogger?
        var box: ChiakiSessionBox? = ChiakiSessionBox(generation: 1, owner: nil)
        weakLogger = box?.logger
        let console = RegisteredConsole(host: "127.0.0.1", name: "test", registKey: Data(repeating: 0x31, count: 16),
                                        morning: Data(repeating: 1, count: 16))
        XCTAssertTrue(box!.initialize(console: console, accountId: Data(repeating: 1, count: 8)).isSuccess)
        XCTAssertTrue(chiaki_session_start(box!.pointer).isSuccess)
        XCTAssertTrue(listener.waitForConnection(timeout: 10), "oturum iş parçacığı PS5'e bağlanmayı denemedi")

        // Sahibi gitmiş, oturum hâlâ açık: StreamSession'ın deinit'i gibi kapatma arka planda.
        let closed = expectation(description: "oturum kapandı")
        let pending = box!
        box = nil
        DispatchQueue.global().async {
            pending.tearDown()
            closed.fulfill()
        }
        wait(for: [closed], timeout: 15)
        XCTAssertNotNil(weakLogger, "günlük, kutu yaşarken bırakılmamalı")
        _ = pending
    }
}

/// Bağlantıyı kabul edip hiçbir şey yanıtlamayan TCP dinleyicisi (yalnız 127.0.0.1).
private final class SilentListener {
    private let socketFD: Int32
    private var accepted: [Int32] = []
    private let lock = NSLock()
    private let connected = DispatchSemaphore(value: 0)

    init(port: UInt16) throws {
        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socketFD, 4) == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(.EADDRINUSE)
        }
        let fd = socketFD
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0, let self else { return }
                self.lock.lock()
                self.accepted.append(client)
                self.lock.unlock()
                self.connected.signal()
            }
        }
    }

    func waitForConnection(timeout: TimeInterval) -> Bool {
        connected.wait(timeout: .now() + timeout) == .success
    }

    func close() {
        lock.lock()
        accepted.forEach { Darwin.close($0) }
        accepted.removeAll()
        lock.unlock()
        shutdown(socketFD, SHUT_RDWR)
        Darwin.close(socketFD)
    }
}

final class DisconnectReasonTests: XCTestCase {
    func testQuitReasonsMapToUserFacingCases() {
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE), .inUse)
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_STOPPED), .stopped)
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_SESSION_REQUEST_CONNECTION_REFUSED), .refused)
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_CTRL_CONNECTION_REFUSED), .refused)
        // TCP reddi eşleme sorunu değildir; yalnız PSN eşlemesinin reddi yeniden eşleme ister.
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_PSN_REGIST_FAILED), .registrationInvalid)
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_DISCONNECTED), .network)
    }

    /// GitHub #519: PS5'teki Uzaktan Oynatma çöktüyse İngilizce libchiaki metni (.other) değil, ayrı bir neden.
    func testConsoleRemotePlayCrashIsItsOwnReason() {
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_CRASH), .consoleRemotePlayCrashed)
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_CRASH, sessionRequestHint: .rejected(0x80108b10)),
                       .consoleRemotePlayCrashed)
        // PS5 aramaya yanıt vermese de "bulunamadı" sayılmaz; 720p'ye düşürme nedeni de değildir.
        XCTAssertEqual(DisconnectReason.classify(.consoleRemotePlayCrashed, searchAnswered: false, host: "192.168.1.70"),
                       .consoleRemotePlayCrashed)
        XCTAssertFalse(QualityFallback.countsAsDrop(.consoleRemotePlayCrashed))
    }

    /// "Unknown Session Request Error"ın asıl nedeni libchiaki'nin günlük satırındadır (satırlar session.c'deki gibi).
    func testSessionRequestLogLinesAreClassified() {
        XCTAssertEqual(DisconnectReason.sessionRequestHint(fromLog: "Reported Application Reason: 0x80108b09 (Regist failed, probably invalid PIN)"),
                       .registrationInvalid)
        XCTAssertEqual(DisconnectReason.sessionRequestHint(fromLog: "Reported Application Reason: 0x80108B02 (Invalid PSN ID)"),
                       .registrationInvalid)
        XCTAssertEqual(DisconnectReason.sessionRequestHint(fromLog: "Reported Application Reason: 0x80108bff (unknown)"),
                       .rejected(0x80108bff))
        // PS5 bu cihazın kayıt anahtarını eşli cihazlarında bulamadı: yeniden eşlenmeli (sonsuz yeniden deneme yok).
        XCTAssertEqual(DisconnectReason.sessionRequestHint(fromLog: "Reported Application Reason: 0x80108b26 (unknown)"),
                       .registrationInvalid)
        // PS5'te Uzaktan Oynatma kapalı (GitHub #9): kod korunur, ekranda ayarın yolu gösterilir.
        XCTAssertEqual(DisconnectReason.sessionRequestHint(fromLog: "Reported Application Reason: 0x80108b12 (unknown)"),
                       .rejected(DisconnectReason.remotePlayDisabled))
        XCTAssertNil(DisconnectReason.sessionRequestHint(fromLog: "Reported Application Reason: garbage"))
        XCTAssertEqual(DisconnectReason.sessionRequestHint(fromLog: "Session request connect failed eventually."), .network)
        XCTAssertEqual(DisconnectReason.sessionRequestHint(fromLog: "Failed to receive session request response"), .network)
        XCTAssertEqual(DisconnectReason.sessionRequestHint(fromLog: "Failed to send session request"), .network)
        XCTAssertNil(DisconnectReason.sessionRequestHint(fromLog: "Session request successful"))
        XCTAssertNil(DisconnectReason.sessionRequestHint(fromLog: "Failed to parse session request response"))
    }

    /// Günlükten anlaşılan neden yalnız bilinmeyen oturum isteği hatasının yerine geçer.
    func testSessionRequestHintRefinesOnlyUnknownSessionRequest() {
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_SESSION_REQUEST_UNKNOWN, sessionRequestHint: .registrationInvalid),
                       .registrationInvalid)
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_SESSION_REQUEST_UNKNOWN, sessionRequestHint: .network), .network)
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_SESSION_REQUEST_UNKNOWN, sessionRequestHint: .rejected(0x80108bff)),
                       .rejected(0x80108bff))
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_SESSION_REQUEST_UNKNOWN, sessionRequestHint: nil), .rejected(nil))
        // PS5 oturum isteğine yanıt verdi: reddetmesi "bulunamadı" değildir.
        XCTAssertEqual(DisconnectReason.classify(.rejected(nil), searchAnswered: false, host: "192.168.1.70"), .rejected(nil))
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE, sessionRequestHint: .network), .inUse)
        // PS5 aramaya yanıt vermediyse bağlanamama "bulunamadı"dır; geçersiz kayıt öyle kalır.
        XCTAssertEqual(DisconnectReason.classify(.registrationInvalid, searchAnswered: false, host: "192.168.1.70"), .registrationInvalid)
    }

    /// PS5 aramaya yanıt vermediyse ve oturum ağ hatasıyla düştüyse neden "bulunamadı"dır; yanıt verdiyse olduğu gibi kalır.
    func testMissingConsoleIsReportedAsNotFound() {
        XCTAssertEqual(DisconnectReason.classify(.network, searchAnswered: false, host: "192.168.1.70"), .notFound("192.168.1.70"))
        XCTAssertEqual(DisconnectReason.classify(.other("x"), searchAnswered: false, host: "192.168.1.70"), .notFound("192.168.1.70"))
        XCTAssertEqual(DisconnectReason.classify(.network, searchAnswered: true, host: "192.168.1.70"), .network)
        XCTAssertEqual(DisconnectReason.classify(.inUse, searchAnswered: false, host: "192.168.1.70"), .inUse)
    }

    /// Adresi değişen PS5 yalnız eminken seçilir (Windows'taki PickMoved).
    func testMovedConsoleIsPickedOnlyWhenCertain() {
        let a = ConsoleInfo(host: "192.168.1.20", name: "PS5-A", isAwake: true)
        let b = ConsoleInfo(host: "192.168.1.21", name: "PS5-B", isAwake: true)
        // Ağda tek PS5 olsa bile adı tutmuyorsa başka evin/odanın PS5'idir (GitHub #425).
        XCTAssertNil(StreamSession.pickMoved([a], name: "other"))
        XCTAssertEqual(StreamSession.pickMoved([a], name: "PS5-A"), a)
        XCTAssertEqual(StreamSession.pickMoved([a, b], name: "PS5-B"), b)
        XCTAssertNil(StreamSession.pickMoved([a, b], name: "other"))
        XCTAssertNil(StreamSession.pickMoved([], name: "PS5-A"))
    }

    /// Kayıtlı adreste başka PS5 yanıt verirse kayıtlı PS5 sayılmaz (GitHub #425).
    func testOtherConsoleAtSavedAddressIsNotTheRegisteredOne() {
        let a = ConsoleInfo(host: "192.168.1.20", name: "PS5-A", isAwake: true)
        XCTAssertTrue(StreamSession.isRegistered(a, name: "PS5-A"))
        XCTAssertFalse(StreamSession.isRegistered(a, name: "PS5-B"))
        XCTAssertTrue(StreamSession.isRegistered(a, name: ""))
    }
}

/// PS5 giriş şifresi: kayıtlıysa ilk istekte gönderilir; yoksa ya da yanlışsa oturum kapanır (döngü yok).
final class LoginPasscodeTests: XCTestCase {
    func testOnlyFourDigitsAreKept() {
        XCTAssertEqual(LoginPasscode.normalized(" 1234 "), "1234")
        XCTAssertEqual(LoginPasscode.normalized("0007"), "0007")
        XCTAssertNil(LoginPasscode.normalized(nil))
        XCTAssertNil(LoginPasscode.normalized(""))
        XCTAssertNil(LoginPasscode.normalized("123"))
        XCTAssertNil(LoginPasscode.normalized("12345"))
        XCTAssertNil(LoginPasscode.normalized("12a4"))
        XCTAssertNil(LoginPasscode.normalized("١٢٣٤"))
    }

    func testSavedPasscodeIsSentAsAsciiOnFirstRequest() {
        XCTAssertEqual(LoginPasscode.reply(saved: "1234", incorrect: false), .send(Data([0x31, 0x32, 0x33, 0x34])))
    }

    func testMissingPasscodeStopsTheSession() {
        XCTAssertEqual(LoginPasscode.reply(saved: nil, incorrect: false), .stop(.loginPasscode))
        XCTAssertEqual(LoginPasscode.reply(saved: "12", incorrect: false), .stop(.loginPasscode))
    }

    /// PS5 şifreyi yeniden istiyorsa önceki yanlıştı: aynı şifre tekrar gönderilmez.
    func testIncorrectPasscodeIsNotResent() {
        XCTAssertEqual(LoginPasscode.reply(saved: "1234", incorrect: true), .stop(.loginPasscodeIncorrect))
    }
}

/// Kullanıcı PS5'i kapatınca (dinlenme modu) yeniden bağlanma döngüsü PS5'i yeniden açmamalı; eskiden açıyordu ve ana
/// ekran PS5 kapatılmış görünürken "PS5 bağlı" diyordu.
final class WakePolicyTests: XCTestCase {
    func testWakesOnlyBeforeFirstConnection() {
        var policy = WakePolicy()
        XCTAssertEqual(policy.action(awake: false), .wake)
        XCTAssertEqual(policy.action(awake: true), .connect)
        XCTAssertEqual(policy.action(awake: nil), .connect)
        policy.streamed()
        XCTAssertEqual(policy.action(awake: false), .waitUntilOn)
        XCTAssertEqual(policy.action(awake: true), .connect)
        XCTAssertEqual(policy.action(awake: nil), .connect)
    }

    func testNewStartWakesAgain() {
        var policy = WakePolicy()
        policy.streamed()
        policy.reset()
        XCTAssertEqual(policy.action(awake: false), .wake)
    }
}

final class CrashRetryLimitTests: XCTestCase {
    /// GitHub #519: PS5 çöktü dedikçe sonsuza kadar "Yeniden bağlanılıyor…" yerine iki denemeden sonra durulur.
    func testStopsAfterTwoRetries() {
        var limit = CrashRetryLimit()
        XCTAssertEqual(CrashRetryLimit.maxRetries, 2)
        XCTAssertTrue(limit.crashed())
        XCTAssertTrue(limit.crashed())
        XCTAssertFalse(limit.crashed())
        XCTAssertFalse(limit.crashed())
        XCTAssertEqual(limit.crashes, 4)
    }

    /// Çeviri yeniden başlatılınca, ağ değişince ya da bağlanınca sayaç baştan.
    func testResetAllowsRetriesAgain() {
        var limit = CrashRetryLimit()
        for _ in 0...CrashRetryLimit.maxRetries { _ = limit.crashed() }
        limit.reset()
        XCTAssertEqual(limit.crashes, 0)
        XCTAssertTrue(limit.crashed())
    }
}
