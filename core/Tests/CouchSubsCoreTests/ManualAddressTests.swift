// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Elle yazılan TV adresi (Instagram bildirimi: LG TV'nin IP'si elle girilince CouchSubs kapanıyordu).
final class ManualAddressTests: XCTestCase {
    func testCleansWhatUsersType() {
        XCTAssertEqual(ManualAddress.normalize("192.168.1.5"), "192.168.1.5")
        XCTAssertEqual(ManualAddress.normalize("  192.168.1.5 \n"), "192.168.1.5")
        XCTAssertEqual(ManualAddress.normalize("192.168.1.5:3000"), "192.168.1.5")
        XCTAssertEqual(ManualAddress.normalize("http://192.168.1.5"), "192.168.1.5")
        XCTAssertEqual(ManualAddress.normalize("ws://192.168.1.5:3000/"), "192.168.1.5")
        XCTAssertEqual(ManualAddress.normalize("192.168.1.5/"), "192.168.1.5")
        // Türkçe sayı klavyesinde nokta yerine virgül çıkar.
        XCTAssertEqual(ManualAddress.normalize("192,168,1,5"), "192.168.1.5")
        XCTAssertEqual(ManualAddress.normalize("192.168.001.005"), "192.168.1.5")
        XCTAssertEqual(ManualAddress.normalize("LGwebOSTV.local"), "lgwebostv.local")
    }

    func testRejectsWhatIsNotAnAddress() {
        for input in ["", "   ", "192.168.1", "192.168.1.256", "192.168.1.5.6", "192.168.1. 5", "192..1.5", "lg tv",
                      "fe80::1", "192.168.1.5:", "192.168.1.5:abc", "http://", "%", "-tv.local", "192.168.1.5\t6"] {
            XCTAssertNil(ManualAddress.normalize(input), input)
        }
    }

    /// Temizlenmiş her adresle bağlantı adresleri kurulabilir.
    func testNormalizedAddressesMakeValidEndpoints() throws {
        for input in ["192.168.1.5:3000", " 10.0.0.2 ", "http://172.16.0.9/", "lgwebostv.local"] {
            let host = try XCTUnwrap(ManualAddress.normalize(input))
            XCTAssertEqual(SSAPClient.endpoints(host: host).count, 2, input)
            XCTAssertNotNil(SamsungMessages.url(host: host, token: nil), input)
            XCTAssertNotNil(DevModeInstaller.keyURL(host: host), input)
        }
    }

    /// Kayıtlı ya da elle yazılmış bozuk adres uygulamayı kapatmaz: LG bağlantısı hatayla biter.
    func testBadHostFailsInsteadOfCrashing() async {
        XCTAssertTrue(SSAPClient.endpoints(host: "192.168.1.5:3000").isEmpty)
        let client = SSAPClient(tv: LGTV(name: "TV", host: "192.168.1.5:3000"), clientKey: nil)
        defer { client.close() }
        do {
            _ = try await client.connect()
            XCTFail("bağlanmamalıydı")
        } catch SSAPClient.SSAPError.cannotConnect {
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
    }

    func testKeyServerWithBadHostIsUnreachable() async {
        struct NoRunner: CommandRunning {
            func run(_ executable: String, _ arguments: [String], input: URL?) async throws -> CommandResult {
                CommandResult(status: 1, output: "")
            }
        }
        do {
            _ = try await DevModeInstaller.fetchKey(host: "fe80::1", passphrase: "ABC123", runner: NoRunner())
            XCTFail("anahtar alınmamalıydı")
        } catch {
            XCTAssertEqual(error as? DevModeError, .unreachable)
        }
    }
}
