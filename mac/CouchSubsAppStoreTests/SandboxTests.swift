// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import XCTest
@testable import CouchSubs

/// Mac App Store sürümü App Sandbox'ta çalışır. Bu testler uygulamanın içinde (sandbox'lı) koşar ve her özelliğin
/// sandbox'ta gerçekten çalıştığını ya da bilerek kapatıldığını sınar (docs/app-store.md).
final class SandboxTests: XCTestCase {
    func testRunsInsideTheSandbox() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"], "Uygulama sandbox'ta değil")
        XCTAssertTrue(NSHomeDirectory().contains("/Library/Containers/"), NSHomeDirectory())
        XCTAssertTrue(Distribution.isAppStore)
    }

    /// Altyazı sunucusu (TV uygulaması, OBS) sandbox'ta dinler ve yanıt verir (network.server).
    func testSubtitleServerListens() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/obs")!)
        XCTAssertNotNil(response as? HTTPURLResponse)
    }

    /// Günlükler kapsayıcıda; iletideki yol kullanıcının Finder'da bulacağı yoldur.
    func testLogPathsPointIntoTheContainer() {
        XCTAssertTrue(TVInstallLog.displayPath.hasPrefix("~/Library/Containers/com.couchsubs.ios/"), TVInstallLog.displayPath)
    }

    /// Samsung ve Android TV kurulum yardımcısı uygulamanın sandbox'ını miras alarak açılır.
    func testTVHelperRunsInheritingTheSandbox() async throws {
        let helper = try XCTUnwrap(TVHelper.executable, "couchsubs-tv-helper uygulamada yok")
        let result = try await ProcessRunner().run(helper.path, ["self-test"], input: nil)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("\"event\":\"done\""), result.output)
    }

    /// Dublaj ses motoru sandbox'ta açılır.
    func testPocketTTSStarts() async throws {
        let tts = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "pocket-tts"), "pocket-tts uygulamada yok")
        let result = try await ProcessRunner().run(tts.path, ["--help"], input: nil)
        XCTAssertEqual(result.status, 0, result.output)
    }

    /// LG kurulumu /usr/bin/ssh-keygen ile anahtarı çözer: sandbox'ta açılır ve kapsayıcıdaki dosyaya yazar.
    func testSSHKeygenWorksOnContainerFiles() async throws {
        let key = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: key); try? FileManager.default.removeItem(at: key.appendingPathExtension("pub")) }
        let keygen = try await ProcessRunner().run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path], input: nil)
        XCTAssertEqual(keygen.status, 0, keygen.output)
        // DevModeInstaller.fetchKey'in yaptığı gibi parola değiştirme.
        let reencrypt = try await ProcessRunner().run("/usr/bin/ssh-keygen", ["-q", "-p", "-P", "", "-N", "", "-f", key.path], input: nil)
        XCTAssertEqual(reencrypt.status, 0, reencrypt.output)
    }

    /// LG kurulumu /usr/bin/ssh çalıştırır: sandbox'ta açılır ve bağlanmayı dener (engellenirse "Operation not
    /// permitted" ya da açılış hatası olurdu).
    func testSSHStartsAndConnects() async throws {
        let ssh = try await ProcessRunner().run("/usr/bin/ssh", [
            "-p", "9", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "prisoner@127.0.0.1", "true",
        ], input: nil)
        XCTAssertEqual(ssh.status, 255, ssh.output)
        XCTAssertTrue(ssh.output.contains("Connection refused"), ssh.output)
    }
}
