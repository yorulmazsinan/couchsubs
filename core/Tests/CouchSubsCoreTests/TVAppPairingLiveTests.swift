// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore

/// TV uygulamasının kendisi (tv-webos/app.js, Node'da `scripts/tv-pair-live.js` ile) gerçek ağ üzerinden bu sunucuyla
/// eşleşir: eşleştirme isteği, telefondaki onay ve altyazı akışı uçtan uca (GitHub #737). Node yoksa atlanır.
/// `COUCHSUBS_TV_APP_DIR` verilirse o klasördeki (eski sürüm) app.js denenir.
final class TVAppPairingLiveTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func node() throws -> URL {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let node = URL(fileURLWithPath: dir).appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: node.path) { return node }
        }
        throw XCTSkip("node yok")
    }

    /// TV uygulamasını çalıştırır; çıkış kodu ve çıktısı döner.
    private func runTV(_ address: String, environment: [String: String] = [:], seconds: Int = 20) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = try node()
        var args = [Self.repo.appendingPathComponent("scripts/tv-pair-live.js").path, address]
        let dir = ProcessInfo.processInfo.environment["COUCHSUBS_TV_APP_DIR"] ?? Self.repo.appendingPathComponent("tv-webos").path
        args += [dir, String(seconds)]
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // waitUntilExit, süreç bittikten sonra çağrılınca XCTest'in çalışma döngüsünde takılabiliyor: bitiş bildirimle beklenir.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let output = await Task.detached { String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }.value
        let finished = await Task.detached { exited.wait(timeout: .now() + .seconds(seconds + 10)) == .success }.value
        guard finished else { process.terminate(); XCTFail("TV uygulaması süresinde kapanmadı"); return (-1, output) }
        return (process.terminationStatus, output)
    }

    /// Onay: telefonda "Bu TV eşleşsin mi?" penceresi açılır ve kullanıcı onaylar.
    private func approving(_ server: SubtitleServer) {
        server.onPairingRequest = { ticket in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { _ = server.pairing.resolve(ticket.id, accept: true) }
        }
    }

    private func posts(_ output: String) -> Int { output.components(separatedBy: "xhr: POST /pair").count - 1 }

    func testFreshTVPairsAndOpensTheStream() async throws {
        let server = SubtitleServer(port: 0)
        approving(server)
        let port = try await server.start()
        defer { server.stop() }
        server.pairing.setSession(true)
        let (status, output) = try await runTV("http://127.0.0.1:\(port)")
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("STREAM_OPEN"), output)
    }

    /// Dün eşleşmiş TV: kayıtlı anahtar geçerli, onaysız bağlanır.
    func testPairedTVConnectsWithItsSavedKey() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        server.pairing.setSession(true)
        let (status, output) = try await runTV("http://127.0.0.1:\(port)", environment: ["TV_KEY": server.accessKey])
        XCTAssertEqual(status, 0, output)
        XCTAssertFalse(output.contains("POST /pair"), output)
    }

    /// Telefon yeni anahtarla geldi (yeniden kurulum, anahtar yenilendi): TV eski anahtarla yeniden eşleşir.
    func testTVWithStaleKeyPairsAgain() async throws {
        let server = SubtitleServer(port: 0)
        approving(server)
        let port = try await server.start()
        defer { server.stop() }
        server.pairing.setSession(true)
        let (status, output) = try await runTV("http://127.0.0.1:\(port)", environment: ["TV_KEY": SubtitleAccess.createKey()])
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("POST /pair"), output)
    }

    /// GitHub #737: TV kod beklerken telefondaki istek düştü (çeviri durdurulup başlatıldı, iOS uygulamayı kapatıp açtı,
    /// onay iki dakikada verilmedi). Eskiden TV "Eşleştirme tamamlanmadı, Tamam'a basın"da kalıyor, kendisi yeni istek
    /// göndermiyordu; telefonda çeviri sürse de "Bu TV eşleşsin mi?" penceresi hiç çıkmıyordu. TV kendiliğinden yeniden
    /// ister, telefonda yeni pencere açılır, onaylanınca bağlanır.
    func testTVAsksAgainWhenThePhoneDropsTheRequest() async throws {
        let server = SubtitleServer(port: 0)
        let seen = Counter()
        server.onPairingRequest = { ticket in
            if seen.next() == 1 {
                // Telefonda çeviri durdu ve yeniden başladı: bekleyen istek silindi.
                server.pairing.setSession(false)
                server.pairing.setSession(true)
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { _ = server.pairing.resolve(ticket.id, accept: true) }
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        server.pairing.setSession(true)
        let (status, output) = try await runTV("http://127.0.0.1:\(port)")
        XCTAssertEqual(status, 0, output)
        XCTAssertEqual(seen.value, 2, output)
        XCTAssertTrue(output.contains("STREAM_OPEN"), output)
    }

    /// Telefonda "Reddet": TV durur, yeni istek için Tamam beklenir (telefonda pencere art arda açılmaz).
    func testRejectedTVWaitsForOK() async throws {
        let server = SubtitleServer(port: 0)
        server.onPairingRequest = { ticket in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { _ = server.pairing.resolve(ticket.id, accept: false) }
        }
        let port = try await server.start()
        defer { server.stop() }
        server.pairing.setSession(true)
        let (status, output) = try await runTV("http://127.0.0.1:\(port)", environment: ["TV_AFTER_FAIL_MS": "12000"])
        XCTAssertEqual(status, 2, output)
        XCTAssertEqual(posts(output), 1, output)
    }

    /// TV, telefonda çeviri başlamadan açıldı: eşleştirme kapalıyken istek reddedilir (409), TV birkaç saniyede bir
    /// kendisi yeniden dener; çeviri başlayınca pencere açılır, onaylanınca bağlanır.
    func testTVWaitsUntilThePhoneOpensPairing() async throws {
        let server = SubtitleServer(port: 0)
        approving(server)
        let port = try await server.start()
        defer { server.stop() }
        // Eşleştirme kapalıyken ilk istek reddedilir (409); TV birkaç saniye sonra yeniden dener.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { server.pairing.setSession(true) }
        let (status, output) = try await runTV("http://127.0.0.1:\(port)")
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("STREAM_OPEN"), output)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
