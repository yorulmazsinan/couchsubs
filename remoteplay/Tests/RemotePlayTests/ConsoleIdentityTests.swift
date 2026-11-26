// SPDX-License-Identifier: AGPL-3.0-only

import CChiaki
@testable import RemotePlay
import XCTest

/// PS5'i kimliğiyle (keşifteki host-id) tanıma: ad değişse de, aynı adlı iki PS5 olsa da doğru PS5 bulunur; eski kayıt
/// kimliği ilk bulunuşta öğrenir (Windows ConsoleIdentityTests, Android ConsoleIdentityTest ile aynı durumlar).
final class ConsoleIdentityTests: XCTestCase {
    private func saved(host: String = "192.168.1.20", name: String = "PS5-A", hostId: String? = "1C98C1AABBCC") -> RegisteredConsole {
        RegisteredConsole(host: host, name: name, registKey: Data("0123abcd".utf8), morning: Data(repeating: 7, count: 16), hostId: hostId)
    }

    func testHostIdIsNormalized() {
        XCTAssertEqual(ConsoleIdentity.normalized("1c:98:c1:aa:bb:cc"), "1C98C1AABBCC")
        XCTAssertEqual(ConsoleIdentity.normalized(" 1c98c1aabbcc\r"), "1C98C1AABBCC")
        XCTAssertNil(ConsoleIdentity.normalized(""))
        XCTAssertNil(ConsoleIdentity.normalized("000000000000"))
        XCTAssertNil(ConsoleIdentity.normalized(nil))
        XCTAssertEqual(ConsoleIdentity.hostId(mac: [0x1C, 0x98, 0xC1, 0xAA, 0xBB, 0xCC]), "1C98C1AABBCC")
        XCTAssertNil(ConsoleIdentity.hostId(mac: [0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(ConsoleInfo(host: "h", name: "n", isAwake: true, hostId: "1c98c1aabbcc").hostId, "1C98C1AABBCC")
    }

    /// PS5'in adı değişti: kimlik tuttuğu için yeni adreste yine bulunur ve kayıttaki ad güncellenir.
    func testRenamedConsoleIsFoundByHostId() {
        let console = saved()
        let renamed = ConsoleInfo(host: "192.168.1.44", name: "Salon PS5", isAwake: true, hostId: "1C98C1AABBCC")
        XCTAssertTrue(ConsoleIdentity.isRegistered(renamed, console))
        XCTAssertEqual(ConsoleIdentity.pickMoved([renamed], console), renamed)
        let updated = ConsoleIdentity.updated(console, with: renamed)
        XCTAssertEqual(updated?.host, "192.168.1.44")
        XCTAssertEqual(updated?.name, "Salon PS5")
        XCTAssertEqual(updated?.hostId, "1C98C1AABBCC")
        XCTAssertEqual(updated?.registKey, console.registKey)
    }

    /// Aynı adlı iki PS5: kimlikli kayıt doğru olanı seçer; kayıtlı adreste yanıt veren öteki PS5 kayıtlı sayılmaz.
    func testTwoConsolesWithTheSameNameAreToldApart() {
        let console = saved()
        let mine = ConsoleInfo(host: "192.168.1.31", name: "PS5-A", isAwake: false, hostId: "1C98C1AABBCC")
        let other = ConsoleInfo(host: "192.168.1.20", name: "PS5-A", isAwake: true, hostId: "F8461C000001")
        XCTAssertFalse(ConsoleIdentity.isRegistered(other, console))
        XCTAssertEqual(ConsoleIdentity.pickMoved([other, mine], console), mine)
        // Kimliksiz (eski) kayıtta iki aynı ad emin olunamaz: hiçbirine geçilmez.
        XCTAssertNil(ConsoleIdentity.pickMoved([other, mine], saved(hostId: nil)))
    }

    /// Eski kayıt (kimlik yok): adıyla bulunur, kimliği kayda yazılır; ad değişmez. Sonraki aramalar kimlikle olur.
    func testLegacyRecordLearnsHostIdOnFirstMatch() {
        let legacy = saved(hostId: nil)
        let found = ConsoleInfo(host: "192.168.1.20", name: "ps5-a", isAwake: true, hostId: "1C98C1AABBCC")
        XCTAssertTrue(ConsoleIdentity.isRegistered(found, legacy))
        let learned = ConsoleIdentity.updated(legacy, with: found)
        XCTAssertEqual(learned?.hostId, "1C98C1AABBCC")
        XCTAssertEqual(learned?.host, "192.168.1.20")
        XCTAssertEqual(learned?.name, "PS5-A")
        XCTAssertEqual(ConsoleIdentity.changeLine(from: legacy, to: learned!), "PS5 kimliği kayda yazıldı: 1C98C1AABBCC")
        // Aynı yanıt ikinci kez bir şey değiştirmez (günlük ve kayıt yazılmaz).
        XCTAssertNil(ConsoleIdentity.updated(learned!, with: found))
    }

    /// Eski biçimde saklanmış kayıt (hostId alanı yok) okunur; yeni alan kaydedilip geri okunur.
    func testStoredRecordWithoutHostIdStillDecodes() throws {
        let old = #"{"host":"192.168.1.20","name":"PS5-A","registKey":"MDEyM2FiY2Q=","morning":"BwcHBwcHBwcHBwcHBwcHBw=="}"#
        let console = try JSONDecoder().decode(RegisteredConsole.self, from: Data(old.utf8))
        XCTAssertNil(console.hostId)
        XCTAssertEqual(console.wakeCredential, 0x0123abcd)
        let roundTrip = try JSONDecoder().decode(RegisteredConsole.self, from: JSONEncoder().encode(saved()))
        XCTAssertEqual(roundTrip.hostId, "1C98C1AABBCC")
        XCTAssertEqual(saved().withHost("10.0.0.5").hostId, "1C98C1AABBCC")
    }

    func testMoveIsLoggedWithHowItWasFound() {
        let moved = saved().withHost("192.168.1.44")
        XCTAssertEqual(ConsoleIdentity.changeLine(from: saved(), to: moved), "PS5 yeni adreste bulundu: 192.168.1.20 → 192.168.1.44 (host-id ile)")
        XCTAssertEqual(ConsoleIdentity.changeLine(from: saved(hostId: nil), to: saved(host: "192.168.1.44", hostId: nil)),
                       "PS5 yeni adreste bulundu: 192.168.1.20 → 192.168.1.44 (adıyla)")
    }

    /// Kayıt yanıtındaki MAC kimlik olarak kayda girer.
    func testRegistrationStoresTheConsoleMac() {
        var host = ChiakiRegisteredHost()
        RemotePlay.copy(Data("PS5-123".utf8), into: &host.server_nickname)
        RemotePlay.copy(Data("0123abcd".utf8), into: &host.rp_regist_key)
        RemotePlay.copy(Data(repeating: 7, count: 16), into: &host.rp_key)
        RemotePlay.copy(Data([0x1C, 0x98, 0xC1, 0xAA, 0xBB, 0xCC]), into: &host.server_mac)
        guard case .success(let console) = Registration.result(type: CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS, host: host,
                                                               reason: nil, errors: []) else { return XCTFail("Başarı bekleniyordu") }
        XCTAssertEqual(console.hostId, "1C98C1AABBCC")
    }

    /// İlk tarama hemen; bulunamazsa 10 sn, 30 sn, 1 dk, 2 dk, sonra hep 5 dk beklenir (#1366). Bağlantı kopunca yine hemen.
    func testRelocateScheduleShortensAfterAFailure() {
        var schedule = RelocateSchedule()
        let now = Date()
        XCTAssertTrue(schedule.isDue(now))
        for wait in [10.0, 30, 60, 120, 300, 300] {
            schedule.searched(found: false, now: now)
            XCTAssertFalse(schedule.isDue(now.addingTimeInterval(wait - 1)))
            XCTAssertTrue(schedule.isDue(now.addingTimeInterval(wait)))
        }
        schedule.connectionFailed()
        XCTAssertTrue(schedule.isDue(now))
        schedule.searched(found: true, now: now)
        XCTAssertTrue(schedule.isDue(now))
    }

    /// Kayıtlı adres sessiz: ağ taranır, PS5 kimliğiyle yeni adreste bulunur, kayıt güncellenir ve bildirilir.
    func testFinderRelocatesAndReportsTheNewAddress() {
        let mine = ConsoleInfo(host: "192.168.1.44", name: "PS5-A", isAwake: true, hostId: "1C98C1AABBCC")
        let other = ConsoleInfo(host: "192.168.1.20", name: "PS5-A", isAwake: true, hostId: "F8461C000001")
        var asked: [String?] = []
        let finder = ConsoleFinder(console: saved()) { host in
            asked.append(host)
            return host == nil ? [other, mine] : host == "192.168.1.20" ? [other] : []
        }
        var reported: RegisteredConsole?
        finder.onChange = { reported = $0 }
        let result = finder.locate()
        XCTAssertEqual(result.info, mine)
        XCTAssertEqual(result.atHost, other)
        XCTAssertEqual(asked, ["192.168.1.20", nil])
        XCTAssertEqual(reported?.host, "192.168.1.44")
        XCTAssertEqual(finder.console.host, "192.168.1.44")
        // Yeni adreste yanıt geliyor: ağ yeniden taranmaz, kayıt yeniden yazılmaz.
        reported = nil
        asked = []
        let finder2 = ConsoleFinder(console: finder.console) { host in asked.append(host); return host == "192.168.1.44" ? [mine] : [] }
        finder2.onChange = { reported = $0 }
        XCTAssertEqual(finder2.locate().info, mine)
        XCTAssertEqual(asked, ["192.168.1.44"])
        XCTAssertNil(reported)
    }

    /// PS5 bulunamadı: sonraki tarama 10 sn bekler (her denemede ağ taranmaz).
    func testFinderDoesNotRescanImmediatelyAfterAMiss() {
        var scans = 0
        let finder = ConsoleFinder(console: saved()) { host in
            if host == nil { scans += 1 }
            return []
        }
        XCTAssertNil(finder.locate().info)
        XCTAssertNil(finder.locate().info)
        XCTAssertEqual(scans, 1)
        finder.connectionFailed()
        XCTAssertNil(finder.locate().info)
        XCTAssertEqual(scans, 2)
    }

    /// Bağlıyken çalışan oyun yoklaması (`sweep: false`) kayıtlı adres sessiz de olsa ağı hiç taramaz (#1366).
    func testLocateWithoutSweepNeverScansTheNetwork() {
        var asked: [String?] = []
        let finder = ConsoleFinder(console: saved()) { host in asked.append(host); return [] }
        XCTAssertNil(finder.locate(sweep: false).info)
        XCTAssertNil(finder.locate(sweep: false).info)
        XCTAssertEqual(asked, ["192.168.1.20", "192.168.1.20"])
    }

    /// Tarama yalnız iki tur gönderir; birkaç adrese soru her turda gider (#1366).
    func testSweepSendsOnlyTwoRounds() {
        XCTAssertTrue(SweepPacing.isSweep(255))
        XCTAssertFalse(SweepPacing.isSweep(1))
        XCTAssertEqual((0..<6).filter { SweepPacing.sendsInRound($0, targetCount: 255) }, [0, 1])
        XCTAssertEqual((0..<6).filter { SweepPacing.sendsInRound($0, targetCount: 1) }, [0, 1, 2, 3, 4, 5])
        // 254 adres 4 ms arayla: saniyede en çok 250 paket.
        XCTAssertLessThanOrEqual(1000 / SweepPacing.paceMilliseconds, 250)
    }

    /// Ağ yükü satırı: ilk olay hemen, sonrakiler dakikada bir tek satırda.
    func testNetworkLoadWritesAtMostOneLinePerMinute() {
        let lines = LockedLines()
        let load = NetworkLoad(write: { lines.append($0) })
        let start = Date()
        load.discovery(sweep: true, packets: 510, now: start)
        XCTAssertEqual(lines.all, ["Ağ yükü (son 0 sn): PS5 ağ taraması 1 kez, 510 paket; tek adres sorgusu 0 kez, 0 paket; PS5'e yeniden bağlanma 0"])
        for second in 1...59 { load.discovery(sweep: false, packets: 4, now: start.addingTimeInterval(Double(second))) }
        load.retry(now: start.addingTimeInterval(59))
        XCTAssertEqual(lines.all.count, 1)
        load.discovery(sweep: true, packets: 500, now: start.addingTimeInterval(60))
        XCTAssertEqual(lines.all.last, "Ağ yükü (son 59 sn): PS5 ağ taraması 1 kez, 500 paket; tek adres sorgusu 59 kez, 236 paket; PS5'e yeniden bağlanma 1")
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
