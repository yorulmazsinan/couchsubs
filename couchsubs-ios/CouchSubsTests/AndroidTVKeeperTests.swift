// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import XCTest
@testable import CouchSubs

/// iPhone + Android TV: TV uygulaması telefonun adresiyle açılır (TestFlight 20 Kas, GitHub #672). Eskiden telefon Android
/// TV'ye hiç dokunmuyor, TV uygulaması telefonu ağ taramasıyla bulamazsa "Ağda CouchSubs aranıyor…"da kalıyordu.
final class AndroidTVKeeperTests: XCTestCase {
    func testStartCommandCarriesTheServerAddress() {
        let params = AndroidTvInstaller.launchParams(server: "http://192.168.1.124:8787")
        XCTAssertEqual(params, #"{"server":"http://192.168.1.124:8787"}"#)
        XCTAssertEqual(AndroidTvInstaller.startCommand(params),
                       #"shell:am start -n com.couchsubs.tv/.MainActivity --es params '{"server":"http://192.168.1.124:8787"}'"#)
    }

    /// TV'de sh çalıştırır: tek tırnak ya da satır sonu içeren değer hiç gönderilmez (Windows'taki StartCommand ile aynı).
    func testStartCommandDropsUnsafeParams() {
        let plain = "shell:am start -n com.couchsubs.tv/.MainActivity"
        XCTAssertEqual(AndroidTvInstaller.startCommand(nil), plain)
        XCTAssertEqual(AndroidTvInstaller.startCommand(""), plain)
        XCTAssertEqual(AndroidTvInstaller.startCommand(#"{"server":"x'; reboot; '"}"#), plain)
        XCTAssertEqual(AndroidTvInstaller.startCommand("{\"a\":\"b\"}\nreboot"), plain)
    }

    /// Çalışan TV uygulamasına adres ekranı öne çekmeden yayınla bildirilir ("TV'de bağlı, panelde sub 0": eski adrese bağlı
    /// kalan uygulama). Windows'taki AddressCommand ve Android telefondaki addressCommand ile aynı.
    func testAddressCommandCarriesTheServerAddressWithoutStartingTheScreen() {
        let params = AndroidTvInstaller.launchParams(server: "http://192.168.1.124:8787")
        XCTAssertEqual(AndroidTvInstaller.addressCommand(params),
                       #"shell:am broadcast -a com.couchsubs.tv.action.ADDRESS -n com.couchsubs.tv/.AddressReceiver --es params '{"server":"http://192.168.1.124:8787"}'"#)
        XCTAssertNil(AndroidTvInstaller.addressCommand(nil))
        XCTAssertNil(AndroidTvInstaller.addressCommand(#"{"server":"x'; reboot; '"}"#))
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testOpensTheAppOnlyWhileItIsNotConnectedAndNotTooOften() {
        let opened = Calls(), logged = Calls()
        let connected = Calls()
        let keeper = AndroidTVKeeper(host: "192.168.1.120", port: 5555, server: "http://192.168.1.124:8787",
                                     appConnected: { connected.all.last == "1" }, relaunchInterval: 30,
                                     open: { host, port, params in opened.add("\(host):\(port) \(params ?? "-")"); return "Starting" },
                                     log: { logged.add($0) })
        let start = Date()
        keeper.tick(now: start)
        keeper.tick(now: start.addingTimeInterval(5))
        XCTAssertEqual(opened.all, [#"192.168.1.120:5555 {"server":"http://192.168.1.124:8787"}"#])
        keeper.tick(now: start.addingTimeInterval(31))
        XCTAssertEqual(opened.all.count, 2)
        // Aynı sonuç günlüğe bir kez yazılır.
        XCTAssertEqual(logged.all.count, 1)
        connected.add("1")
        keeper.tick(now: start.addingTimeInterval(120))
        XCTAssertEqual(opened.all.count, 2)
        // X, Android TV 8 (beta.74): bağlanmış uygulamanın bağlantısı düşünce (kullanıcı kumandadan açtı, başka girişe geçti)
        // bekçi onu bir daha açmaz; eskiden hemen `am start` gidiyor, ekran katmana atılıyordu.
        connected.add("0")
        keeper.tick(now: start.addingTimeInterval(121))
        keeper.tick(now: start.addingTimeInterval(300))
        XCTAssertEqual(opened.all.count, 2)
        // "Otomatik açmayı dene" sayacı sıfırlar.
        keeper.reconnect()
        keeper.tick(now: start.addingTimeInterval(301))
        XCTAssertEqual(opened.all.count, 3)
    }

    /// X (beta.77): "izni sürekli yeniden istiyor". Hiç bağlanmayan uygulama için en çok üç ADB bağlantısı açılır; TV'de zaten
    /// çalışıyorsa (`am start` gönderilmedi) ya da TV onay sorduysa da sayılır (eskiden sayılmıyor, 30 sn'de bir sınırsız
    /// bağlantı açılıyor, onaysız TV her seferinde soruyordu).
    func testAtMostThreeAdbConnectionsEvenWhenTheAppIsRunningOrNotApproved() {
        let opened = Calls()
        let running = Calls()
        let keeper = AndroidTVKeeper(host: "192.168.1.120", port: 5555, server: "http://192.168.1.124:8787",
                                     appConnected: { false }, relaunchInterval: 30,
                                     open: { _, _, _ in
                                         opened.add("try")
                                         if running.all.last == "approve" { throw AndroidInstallFailure(error: .notApproved, detail: "onay gerekiyor") }
                                         return AndroidTVApp.alreadyRunning
                                     }, log: { _ in })
        let start = Date()
        running.add("1")
        for step in 0..<20 { keeper.tick(now: start.addingTimeInterval(Double(step) * 31)) }
        XCTAssertEqual(opened.all.count, 3)
        running.add("approve")
        keeper.reconnect()
        for step in 20..<200 { keeper.tick(now: start.addingTimeInterval(Double(step) * 31)) }
        XCTAssertEqual(opened.all.count, 6)
    }

    func testConnectedAppNeverGetsAnAdbConnection() {
        let opened = Calls()
        let keeper = AndroidTVKeeper(host: "192.168.1.120", port: 5555, server: "http://192.168.1.124:8787",
                                     appConnected: { true }, relaunchInterval: 0,
                                     open: { _, _, _ in opened.add("try"); return "Starting" }, log: { _ in })
        let start = Date()
        for step in 0..<100 { keeper.tick(now: start.addingTimeInterval(Double(step) * 5)) }
        XCTAssertEqual(opened.all.count, 0)
    }

    func testClosedAdbIsSilentAndLoggedOnce() {
        let logged = Calls()
        let keeper = AndroidTVKeeper(host: "192.168.1.120", port: 5555, server: "http://192.168.1.124:8787", appConnected: { false },
                                     relaunchInterval: 0,
                                     open: { _, _, _ in throw AndroidInstallFailure(error: .unreachable, detail: "kapalı") },
                                     log: { logged.add($0) })
        keeper.tick()
        keeper.tick()
        XCTAssertEqual(logged.all.count, 1)
        XCTAssertTrue(logged.all[0].contains("açılamadı"))
    }

    /// Açılamamanın nedeni ana ekranda söylenir: hata ayıklama kapalı/ulaşılamıyor ile izin onaylanmadı ayrı.
    func testReportsWhyTheAppCouldNotBeOpened() {
        let results = Calls()
        let failure = Calls()
        let keeper = AndroidTVKeeper(host: "192.168.1.120", port: 5555, server: "http://192.168.1.124:8787", appConnected: { false },
                                     relaunchInterval: 0,
                                     open: { _, _, _ in
                                         switch failure.all.last {
                                         case "approve": throw AndroidInstallFailure(error: .notApproved, detail: "onay gerekiyor")
                                         case "off": throw AndroidInstallFailure(error: .unreachable, detail: "kapalı")
                                         default: return "Starting"
                                         }
                                     }, log: { _ in }, onOpenResult: { results.add($0?.rawValue ?? "ok") })
        failure.add("off")
        keeper.tick()
        failure.add("approve")
        keeper.tick()
        failure.add("none")
        keeper.tick()
        XCTAssertEqual(results.all, ["debugOff", "debugNotApproved", "ok"])
    }

    func testSavedWirelessPortIsUsedForTheSameTV() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "android-tv-keeper-tests"))
        defaults.removePersistentDomain(forName: "android-tv-keeper-tests")
        XCTAssertEqual(InstalledTVApp.adbPort(for: "192.168.1.120", defaults: defaults), 5555)
        let saved = InstalledTVApp(brand: .androidTV, host: "192.168.1.120", port: 41235, version: "0.9.43")
        defaults.set(try JSONEncoder().encode(saved), forKey: "tvAppInstalled")
        XCTAssertEqual(InstalledTVApp.adbPort(for: "192.168.1.120", defaults: defaults), 41235)
        XCTAssertEqual(InstalledTVApp.adbPort(for: "192.168.1.99", defaults: defaults), 5555)
    }
}
