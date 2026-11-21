// SPDX-License-Identifier: AGPL-3.0-only

#if os(macOS)
import Foundation
import XCTest
@testable import CouchSubsCore

/// Uçtan uca: gerçek `SubtitleServer` (Mac ve iPhone) ile Android TV uygulamasının sayfası (tv-webos/app.js +
/// tv-android/platform.js, Node'da, Android 8 WebView'ine göre kısıtlı; scripts/tv-live-page.js). Sayfa eşleşmiş anahtarla
/// bağlanır, altyazıyı sayar ("sub 1") ve çizer. Windows'ta TvPageEndToEndTests, Android telefonda TvPageEndToEndTest.
/// Node yoksa test atlanır (CI'da hata).
final class TVPageEndToEndTests: XCTestCase {
    func testAndroidTVPageCountsAndShowsSubtitleFromServer() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let page = try TVPage(port: port, key: server.accessKey)
        defer { page.stop() }

        try await page.waitFor("status bağlı")
        server.sendSubtitle("Merhaba dünya, bu bir deneme.", durationMs: 4000)
        try await page.waitFor("shown Merhaba dünya, bu bir deneme.")
        let diag = try await page.waitFor("diag sub 1 ")
        XCTAssertFalse(diag.contains(" err "), diag)
    }

    /// "TV'de bağlı, panelde sub 0": altyazı hedefi TV değilken altyazı TV'ye gitmez, bağlantı sürer.
    func testTVStaysConnectedWithZeroSubtitlesOnlyWhileOutputIsNotTV() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let page = try TVPage(port: port, key: server.accessKey)
        defer { page.stop() }

        try await page.waitFor("status bağlı")
        server.sendsToTV = false
        server.sendSubtitle("Gitmemeli", durationMs: 4000)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(page.lines.contains { $0.hasPrefix("diag sub 1") })
        XCTAssertEqual(server.connectedClients, 1)

        server.sendsToTV = true
        server.sendSubtitle("Şimdi gelmeli", durationMs: 4000)
        try await page.waitFor("shown Şimdi gelmeli")
        try await page.waitFor("diag sub 1 ")
    }
}

/// scripts/tv-live-page.js alt süreci.
private final class TVPage: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var collected: [String] = []
    private var partial = ""

    var lines: [String] { lock.lock(); defer { lock.unlock() }; return collected }

    init(port: UInt16, key: String) throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var script: URL?
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("scripts/tv-live-page.js")
            if FileManager.default.fileExists(atPath: candidate.path) { script = candidate; break }
            dir.deleteLastPathComponent()
        }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        let node = path.map { $0 + "/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let script, let node else {
            if ProcessInfo.processInfo.environment["CI"] == "true" { XCTFail("Node ya da scripts/tv-live-page.js bulunamadı") }
            throw XCTSkip("Node bulunamadı")
        }
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path, "http://127.0.0.1:\(port)", key]
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self, let text = String(data: handle.availableData, encoding: .utf8) else { return }
            self.lock.lock()
            self.partial += text
            while let end = self.partial.firstIndex(of: "\n") {
                self.collected.append(String(self.partial[..<end]))
                self.partial = String(self.partial[self.partial.index(after: end)...])
            }
            self.lock.unlock()
        }
        try process.run()
    }

    @discardableResult
    func waitFor(_ prefix: String, timeout: TimeInterval = 10) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let found = lines.first(where: { $0.hasPrefix(prefix) }) { return found }
            if Date() > deadline {
                XCTFail("TV sayfası \"\(prefix)\" yazmadı. Çıktı:\n\(lines.joined(separator: "\n"))")
                return ""
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}
#endif
