// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CouchSubsCore
import RemotePlay
import XCTest
@testable import CouchSubs

private final class FakeStream: StreamControlling {
    var onFrame: ((CGImage) -> Void)?
    var onState: ((SessionState) -> Void)?
    var onConsoleMoved: ((RegisteredConsole) -> Void)?
    private(set) var started = false
    private(set) var stopped = false
    func start() { started = true }
    func stop() { stopped = true }
    func reconnectNow() {}
}

private final class FakeServices: PhoneServices {
    var registerResult: Result<RegisteredConsole, Error> = .success(RegisteredConsole(host: "192.168.1.20", name: "PS5", registKey: Data(), morning: Data()))
    var launched = true
    let stream = FakeStream()

    func discoverConsoles() async -> [ConsoleInfo] { [ConsoleInfo(host: "192.168.1.20", name: "PS5", isAwake: true)] }
    func accountId(fromRedirect url: URL) async throws -> Data { Data([1, 2, 3]) }
    func register(host: String, accountId: Data, pin: UInt32) async throws -> RegisteredConsole { try registerResult.get() }
    func discoverTVs() async -> [LGTV] { [] }
    func pairTV(_ tv: LGTV, key: String?, server: String) async throws -> TVPairing { TVPairing(key: "key", launched: launched) }
    func makeStream(console: RegisteredConsole, accountId: Data) -> StreamControlling { stream }
    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void) -> KeeperControlling { IdleKeeper() }
    func checkDeepLKey(_ key: String) async -> OnlineKeyCheck { OnlineKeyCheck(state: key == "good" ? .valid : .invalid) }
    func testAIKey(provider: AIProvider, key: String, model: String?) async -> Result<String, AIFailure> {
        key == "good" ? .success("Merhaba") : .failure(.invalidKey)
    }
}

@MainActor
final class PhoneModelTests: XCTestCase {
    private var services: FakeServices!
    private var defaults: UserDefaults!

    override func setUp() {
        services = FakeServices()
        defaults = UserDefaults(suiteName: "PhoneModelTests-\(UUID().uuidString)")
    }

    private func makeModel() -> PhoneModel { PhoneModel(services: services, store: EphemeralStore(), defaults: defaults) }

    func testSetupFlowNeedsSignInAndPS5() async throws {
        let model = makeModel()
        XCTAssertEqual(model.step, .welcome)
        model.advance()
        XCTAssertEqual(model.step, .psnLogin)
        XCTAssertFalse(model.canAdvance)
        try await model.completePSNLogin(redirect: URL(string: "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=x")!)
        model.advance()
        XCTAssertEqual(model.step, .console)
        XCTAssertFalse(model.canAdvance)
        try await model.register(host: "192.168.1.20", pin: "1234 5678")
        model.advance()
        XCTAssertEqual(model.step, .output)
        XCTAssertFalse(model.canAdvance)
        model.usePhoneScreen()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(model.settings.output, .computer)
        XCTAssertTrue(model.canStart)
    }

    func testRegisterExplainsFailures() async {
        let model = makeModel()
        do {
            try await model.register(host: "192.168.1.20", pin: "123")
            XCTFail("kod kısa")
        } catch {
            XCTAssertEqual(error as? PhoneError, .invalidPin)
        }
        try? await model.completePSNLogin(redirect: URL(string: "https://example.com")!)
        services.registerResult = .failure(Registration.RegistrationError(.wrongCode, detail: "PS5 kodu"))
        do {
            try await model.register(host: "192.168.1.20", pin: "12345678")
            XCTFail("kod yanlış")
        } catch {
            XCTAssertEqual(error as? PhoneFailure, PhoneFailure(error: .wrongCode, detail: "PS5 kodu"))
        }
    }

    func testPairingRemembersMissingTVApp() async throws {
        services.launched = false
        let model = makeModel()
        try await model.pair(LGTV(name: "LG", host: "192.168.1.30", brand: .lg))
        XCTAssertTrue(model.hasTV)
        XCTAssertTrue(model.tvAppMissing)
        XCTAssertEqual(model.settings.output, .tv)
    }

    func testStartKeepsScreenAwakeAndStopReleasesIt() async throws {
        let model = makeModel()
        var awake: [Bool] = []
        model.keepScreenAwake = { awake.append($0) }
        try await model.completePSNLogin(redirect: URL(string: "https://example.com")!)
        try await model.register(host: "192.168.1.20", pin: "12345678")
        model.settings.output = .computer
        await model.start()
        XCTAssertTrue(model.isRunning)
        XCTAssertTrue(services.stream.started)
        model.stop()
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(services.stream.stopped)
        XCTAssertEqual(awake, [true, false])
    }

    func testPhoneScreenShowsSubtitlesOnlyWhenChosen() {
        let model = makeModel()
        model.clock = { 100 }
        model.settings.output = .tv
        model.phoneReceive(.subtitle(text: "Merhaba", durationMs: 4000, paragraphs: false))
        XCTAssertTrue(model.phoneLines.isEmpty)
        model.settings.output = .computer
        model.phoneReceive(.subtitle(text: "Merhaba", durationMs: 4000, paragraphs: false))
        XCTAssertEqual(model.phoneLines.map(\.text), ["Merhaba"])
        model.stop()
        XCTAssertTrue(model.phoneLines.isEmpty)
    }

    func testKeysAreTestedBeforeSaving() async {
        let model = makeModel()
        let rejected = await model.saveKey("bad", for: .deepL)
        XCTAssertFalse(rejected)
        XCTAssertFalse(model.hasKey(.deepL))
        let accepted = await model.saveKey("good", for: .gemini)
        XCTAssertTrue(accepted)
        XCTAssertTrue(model.hasKey(.gemini))
        XCTAssertEqual(model.settings.translationEngine, .gemini)
        model.removeKey(.gemini)
        XCTAssertEqual(model.settings.translationEngine, .free)
    }
}
