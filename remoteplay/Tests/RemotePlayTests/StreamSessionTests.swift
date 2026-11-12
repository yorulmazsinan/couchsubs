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
        XCTAssertEqual(DisconnectReason(quit: CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_DISCONNECTED), .network)
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
        XCTAssertEqual(StreamSession.pickMoved([a], name: "other"), a)
        XCTAssertEqual(StreamSession.pickMoved([a, b], name: "PS5-B"), b)
        XCTAssertNil(StreamSession.pickMoved([a, b], name: "other"))
        XCTAssertNil(StreamSession.pickMoved([], name: "PS5-A"))
    }
}
