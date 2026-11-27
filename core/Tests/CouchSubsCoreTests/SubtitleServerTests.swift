// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class SubtitleServerTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Koşul zamanında sağlanmadı"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func readLines(_ bytes: URLSession.AsyncBytes, until stop: String) async throws -> [String] {
        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
            if line == stop { break }
        }
        return lines
    }

    func testStreamsSubtitleAndClearEventsWithCors() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }

        let (bytes, response) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertNil(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
        XCTAssertTrue(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true)

        try await waitUntil { server.connectedClients == 1 }
        server.sendSubtitle("Merhaba", durationMs: 4000, box: TextBox(left: 0.25, top: 0.8, right: 0.75, bottom: 0.874_99))
        // Aynı cümlenin uzamış okuması: TV öncekinin üstüne yığmaz, yerine koyar.
        server.sendSubtitle("Merhaba dostum", durationMs: 4000, replaces: true)
        server.clear()

        let lines = try await readLines(bytes, until: "event: clear")
        XCTAssertTrue(lines.contains("event: subtitle"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("data:") && $0.contains("\"text\":\"Merhaba\"") && $0.contains("\"duration\":4000")
            && $0.contains("\"box\":{\"bottom\":0.875,\"left\":0.25,\"right\":0.75,\"top\":0.8}") && !$0.contains("replace") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("data:") && $0.contains("\"text\":\"Merhaba dostum\"") && $0.contains("\"replace\":true") })
    }

    /// TV uygulaması gösterdiği HDMI girişini akışa bağlanırken bildirir; bekçi PS tuşunu bununla tanır.
    func testRemembersTheHdmiInputTheTVAppShows() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        XCTAssertNil(server.consolePort)
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?hdmi=3")!)
        try await waitUntil { server.connectedClients == 1 }
        XCTAssertEqual(server.consolePort, 3)
        bytes.task.cancel()
        XCTAssertNil(SubtitleServer.hdmiPort("9"))
        XCTAssertNil(SubtitleServer.hdmiPort("12"))
        XCTAssertNil(SubtitleServer.hdmiPort(nil))
        XCTAssertEqual(SubtitleServer.hdmiPort("4"), 4)
    }

    /// TV uygulaması sürümünü akışla bildirir; bildirmeyen TV (0.9.69'den eski) eski sayılır, OBS sayılmaz (#884, #891).
    func testRemembersTheTVAppVersionAndTreatsSilentTVsAsOld() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        XCTAssertNil(server.tvAppVersion)
        let (obs, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?viewer=obs")!)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(server.tvAppVersion)
        let (old, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?hdmi=2")!)
        try await waitUntil { server.tvAppVersion != nil }
        XCTAssertEqual(server.tvAppVersion, "")
        let (fresh, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?v=0.9.69&hdmi=2")!)
        try await waitUntil { server.tvAppVersion == "0.9.69" }
        obs.task.cancel(); old.task.cancel(); fresh.task.cancel()
        XCTAssertEqual(SubtitleServer.tvAppVersion("0.9.70<script>"), "")
        XCTAssertTrue(SubtitleServer.isTVAppOutdated(reported: "", bundled: "0.9.69"))
        XCTAssertTrue(SubtitleServer.isTVAppOutdated(reported: "0.9.49", bundled: "0.9.69"))
        XCTAssertFalse(SubtitleServer.isTVAppOutdated(reported: "0.9.69", bundled: "0.9.69"))
        XCTAssertFalse(SubtitleServer.isTVAppOutdated(reported: "0.9.70", bundled: "0.9.69"))
        XCTAssertFalse(SubtitleServer.isTVAppOutdated(reported: "", bundled: ""))
    }

    /// İki TV'li ev (LG OLED ve TCL Google TV): öbür TV'nin bildirdiği sürüm kayıtlı TV'ninki sayılmaz. Adreslerden biri
    /// bilinmiyorsa (adressiz Android TV, yerel olmayan bağlantı) kayıtlı TV sayılır. Windows ve Android ile aynı.
    func testTVAppReportOnlyConcernsTheSavedTV() {
        XCTAssertTrue(SubtitleServer.isFromSavedTV(reporter: "192.168.1.40", saved: "192.168.1.40"))
        XCTAssertTrue(SubtitleServer.isFromSavedTV(reporter: "192.168.1.40", saved: " 192.168.1.40 "))
        XCTAssertTrue(SubtitleServer.isFromSavedTV(reporter: "192.168.1.40", saved: "::ffff:192.168.1.40"))
        XCTAssertFalse(SubtitleServer.isFromSavedTV(reporter: "192.168.1.41", saved: "192.168.1.40"))
        XCTAssertTrue(SubtitleServer.isFromSavedTV(reporter: "", saved: "192.168.1.40"))
        XCTAssertTrue(SubtitleServer.isFromSavedTV(reporter: "192.168.1.41", saved: ""))
        XCTAssertTrue(SubtitleServer.isFromSavedTV(reporter: "192.168.1.41", saved: nil))
        XCTAssertEqual(SubtitleServer.otherTVReportLine(reporter: "192.168.1.41", saved: "192.168.1.40", version: ""),
                       "TV uygulaması kayıtlı TV'den (192.168.1.40) değil, başka bir TV'den (192.168.1.41) bağlandı, sürüm < 0.9.69; "
                       + "kayıtlı TV için güncelleme ya da kurulum önerilmiyor.")
    }

    /// TV akışı TV ya da ağ tarafından kapanınca nedeni, ne kadar açık kaldığı ve son alındı günlükte (Windows ve Android aynı).
    func testTVClosedLineNamesReasonUptimeAndLastAck() {
        XCTAssertEqual(SubtitleServer.tvClosedLine(why: "TV kapattı", host: "192.168.1.40", openSeconds: 183, ackSecondsAgo: 14),
                       "TV bağlantısı koptu (TV kapattı): 192.168.1.40, 183 sn açıktı, son alındı 14 sn önce; TV yeniden bağlanacak")
        XCTAssertEqual(SubtitleServer.tvClosedLine(why: "yazma hatası", host: "", openSeconds: -1, ackSecondsAgo: nil),
                       "TV bağlantısı koptu (yazma hatası): ?, 0 sn açıktı, son alındı yok; TV yeniden bağlanacak")
    }

    /// Eski TV uygulaması (sürüm bildirmeyen; 0.9.7'den önceki sürümler `clear` gelir gelmez satırı kaldırır): `clear`
    /// ona satırın en az görünme süresi dolunca gider, yeni TV'ye hemen. Arada yeni satır gelirse eski `clear` hiç gitmez.
    func testClearReachesOldTVAppsOnlyAfterTheLineWasReadable() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let (old, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        let (fresh, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?v=0.9.71")!)
        try await waitUntil { server.connectedClients == 2 }
        func clears(_ bytes: URLSession.AsyncBytes) -> Task<[(String, Date)], Error> {
            Task {
                var seen: [(String, Date)] = []
                for try await line in bytes.lines where line.hasPrefix("event: ") {
                    seen.append((line, Date()))
                    if line == "event: clear" { break }
                }
                return seen
            }
        }
        let oldEvents = clears(old)
        let freshEvents = clears(fresh)
        let start = Date()
        server.sendSubtitle("Selam", durationMs: 4000)
        server.clear()
        // Satır kalkmadan yeni satır geldi: eski TV'ye bekleyen `clear` gitmez, yenisininki süresi dolunca gider.
        try await Task.sleep(nanoseconds: 500_000_000)
        server.sendSubtitle("Yeni", durationMs: 4000)
        server.clear()
        let freshSeen = try await freshEvents.value
        let oldSeen = try await oldEvents.value
        let freshClear = try XCTUnwrap(freshSeen.first { $0.0 == "event: clear" })
        XCTAssertLessThan(freshClear.1.timeIntervalSince(start), 1, "Yeni TV satırı kendisi tutar: clear hemen gider")
        XCTAssertEqual(oldSeen.map(\.0).filter { $0 == "event: subtitle" }.count, 2, "Eski TV iki satırı da alır")
        let oldClear = try XCTUnwrap(oldSeen.first { $0.0 == "event: clear" })
        // İkinci satır 0,5 sn'de geldi; 4 harf → 2,24 sn tutulur.
        XCTAssertGreaterThan(oldClear.1.timeIntervalSince(start), 2.5)
        XCTAssertEqual(SubtitleServer.legacyClearHold(textLength: 4), 2.24, accuracy: 0.001)
        XCTAssertEqual(SubtitleServer.legacyClearHold(textLength: 500), 5)
        old.task.cancel(); fresh.task.cancel()
    }

    /// Konuşan adını renklendir açıkken adlı satır `speakerNames` alanını taşır; adsız satırda ve ayar kapalıyken alan yoktur.
    func testSubtitleCarriesSpeakerColorsWhenEnabled() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        try await waitUntil { server.connectedClients == 1 }
        server.sendSubtitle("Mattia: Gidelim.", durationMs: 4000)
        server.speakerColors = true
        server.sendSubtitle("Mattia: Gidelim.\nLucia: Tamam.", durationMs: 4000)
        server.sendSubtitle("Adsız satır", durationMs: 4000)
        server.clear()

        let data = try await readLines(bytes, until: "event: clear").filter { $0.hasPrefix("data:") && $0.contains("\"text\"") }
        XCTAssertEqual(data.count, 3)
        XCTAssertFalse(data[0].contains("speaker"))
        XCTAssertTrue(data[1].contains("\"speakerNames\":[{"))
        // Eski alan gitmez: 0.9.79'dan eski TV uygulamaları onunla bütün satırı boyuyordu.
        XCTAssertFalse(data[1].contains("\"speakers\""))
        XCTAssertTrue(data[1].contains("\"name\":\"Mattia\"") && data[1].contains("#F76AB7"))
        XCTAssertTrue(data[1].contains("\"name\":\"Lucia\"") && data[1].contains("#2AD5E5"))
        XCTAssertFalse(data[2].contains("speaker"))
    }

    /// Telefon, sunucu düştüyse (iOS arka planda dinleyiciyi kapatır) bunu `isListening` ile anlar ve aynı nesneyi
    /// yeniden başlatır; yeniden başlatılan sunucu yine bağlantı kabul eder.
    func testIsListeningFollowsStartStopAndRestart() async throws {
        let server = SubtitleServer(port: 0)
        XCTAssertFalse(server.isListening)
        _ = try await server.start()
        XCTAssertTrue(server.isListening)
        server.stop()
        XCTAssertFalse(server.isListening)
        let port = try await server.start()
        defer { server.stop() }
        XCTAssertTrue(server.isListening)
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/hello")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    /// Sabit portta (TV'nin ağda aradığı 8787) kapatılıp hemen yeniden açılan sunucu aynı portu geri alır. Eskiden
    /// kapanan dinleyici portu henüz bırakmadan yenisi "Address already in use" alıyor, telefon rastgele bir porta
    /// düşüyor, ağı yalnız 8787'de tarayan TV uygulaması telefonu bir daha bulamıyordu.
    func testRestartOnFixedPortKeepsThePort() async throws {
        let probe = SubtitleServer(port: 0)
        let port = try await probe.start()
        probe.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let server = SubtitleServer(port: port)
        defer { server.stop() }
        for _ in 0..<5 {
            let started = try await server.start()
            XCTAssertEqual(started, port)
            server.stop()
        }
        let again = try await server.start()
        XCTAssertEqual(again, port)
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/hello")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    /// TV yarı açık bağlantıyı adlı "ping" olayının gelmemesinden anlar; yorum satırını EventSource görmez.
    func testPingIsSentAsNamedEvent() async throws {
        let server = SubtitleServer(port: 0, pingInterval: 0.05)
        let port = try await server.start()
        defer { server.stop() }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
            if lines.suffix(2) == ["event: ping", "data: {}"] { break }
        }
        XCTAssertEqual(Array(lines.suffix(2)), ["event: ping", "data: {}"])
    }

    /// TV akışı `link` olayıyla kimliğini alır; `/ack` bilinen kimliğe 204, bilinmeyene 404 döner (TV hemen yeniden bağlanır).
    func testTVStreamGetsALinkIdThatAcksAccept() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        var link: String?
        var previous = ""
        for try await line in bytes.lines {
            if previous == "event: link", line.hasPrefix("data:") {
                let json = try JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                link = json?["id"] as? String
                break
            }
            previous = line
        }
        let id = try XCTUnwrap(link)
        XCTAssertTrue(id.count == 16 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        let (_, ok) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/ack?c=\(id)")!)
        XCTAssertEqual((ok as? HTTPURLResponse)?.statusCode, 204)
        let (_, unknown) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/ack?c=nope")!)
        XCTAssertEqual((unknown as? HTTPURLResponse)?.statusCode, 404)
    }

    /// `link` olayı bu cihazdaki TV paketinin sürümünü (`latest`) taşır; TV daha eskiyse paneli "TV uygulaması eski" der.
    func testLinkCarriesBundledTVAppVersion() async throws {
        let server = SubtitleServer(port: 0)
        server.latestTVAppVersion = "0.9.95"
        let port = try await server.start()
        defer { server.stop() }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?v=0.9.71")!)
        var latest: String?
        var previous = ""
        for try await line in bytes.lines {
            if previous == "event: link", line.hasPrefix("data:") {
                let json = try JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                latest = json?["latest"] as? String
                break
            }
            previous = line
        }
        XCTAssertEqual(latest, "0.9.95")
    }

    /// OBS gibi izleyiciler alındı göndermez; onlara `link` gitmez.
    func testViewersGetNoLink() async throws {
        let server = SubtitleServer(port: 0, pingInterval: 0.05)
        let port = try await server.start()
        defer { server.stop() }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?viewer=obs")!)
        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
            if line == "event: ping" { break }
        }
        XCTAssertFalse(lines.contains("event: link"))
    }

    /// Alındı gönderip susan TV (askıya alınan LG uygulaması) kopmuş sayılır: bağlantı kapanır, sayı düşer, `onTVStale`
    /// çağrılır. Hiç alındı göndermeyen eski TV uygulaması bağlı kalır.
    func testTVThatStopsAckingIsDroppedButOldTVsStay() async throws {
        let server = SubtitleServer(port: 0, pingInterval: 0.1)
        let stale = Locked(false)
        server.onTVStale = { stale.set(true) }
        let port = try await server.start()
        defer { server.stop() }

        let old = Task {
            let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
            for try await _ in bytes.lines {}
        }
        defer { old.cancel() }
        try await waitUntil { server.connectedClients == 1 }

        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?v=0.9.76")!)
        var link: String?
        var previous = ""
        for try await line in bytes.lines {
            if previous == "event: link", line.hasPrefix("data:") {
                link = (try JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any])?["id"] as? String
                break
            }
            previous = line
        }
        let id = try XCTUnwrap(link)
        try await waitUntil { server.connectedClients == 2 }
        // Birkaç ping turu boyunca alındı gelir: bağlantı açık kalır.
        for _ in 0..<5 {
            _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/ack?c=\(id)")!)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(server.connectedClients, 2)
        XCTAssertFalse(stale.value)
        // TV susar (askıya alındı): 3 ping turu sonra bağlantı kapanır; eski TV kalır.
        try await waitUntil { server.connectedClients == 1 }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(server.connectedClients, 1)
        // #1055: TV'nin başka bağlantısı açıkken bekçi yenilenmez (yenilenen bekçi LG'de uygulamayı yeniden başlatıyordu).
        XCTAssertFalse(stale.value)
        let (_, gone) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/ack?c=\(id)")!)
        XCTAssertEqual((gone as? HTTPURLResponse)?.statusCode, 404)
    }

    /// #1055: TV'nin tek bağlantısı susunca `onTVStale` bir kez çağrılır; alındı gönderen TV ping turları boyunca
    /// hiç düşmez.
    func testOnlyTheLastSilentTVConnectionRenewsTheKeeper() async throws {
        let server = SubtitleServer(port: 0, pingInterval: 0.1)
        let stale = Locked(0)
        server.onTVStale = { stale.set(stale.value + 1) }
        let port = try await server.start()
        defer { server.stop() }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?v=0.9.80")!)
        var link: String?
        var previous = ""
        for try await line in bytes.lines {
            if previous == "event: link", line.hasPrefix("data:") {
                link = (try JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any])?["id"] as? String
                break
            }
            previous = line
        }
        let id = try XCTUnwrap(link)
        try await waitUntil { server.connectedClients == 1 }
        for _ in 0..<10 {
            _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/ack?c=\(id)")!)
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        XCTAssertEqual(server.connectedClients, 1)
        XCTAssertEqual(stale.value, 0)
        try await waitUntil { server.connectedClients == 0 }
        try await waitUntil { stale.value == 1 }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(stale.value, 1)
    }

    func testStreamsScreenTranslationsAndTheirClear() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        try await waitUntil { server.connectedClients == 1 }
        server.sendScreen([
            .init(source: "Map\nSettings", translation: "Harita\nAyarlar", box: TextBox(left: 0.05, top: 0.3, right: 0.2, bottom: 0.4), lineHeight: 0.03),
            .init(source: "Open the door.", translation: "Kapıyı aç.", box: TextBox(left: 0.4, top: 0.8, right: 0.6, bottom: 0.84), lineHeight: 0.04),
        ], durationMs: 12000)
        server.clearScreen()

        let lines = try await readLines(bytes, until: "event: screen-clear")
        XCTAssertTrue(lines.contains("event: screen"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("data:") && $0.contains("\"duration\":12000")
            && $0.contains("{\"box\":{\"bottom\":0.4,\"left\":0.05,\"right\":0.2,\"top\":0.3},\"line\":0.03,\"paragraphs\":true,\"text\":\"Harita\\nAyarlar\"}")
            && $0.contains("\"line\":0.04,\"text\":\"Kapıyı aç.\"}") })
    }

    /// Ek alanın çevirisi kendi olayıyla gider (eski TV uygulamaları tanımadığı olayı yok sayar).
    func testStreamsRegionTranslationsAndTheirClear() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let received = LockedEvents()
        server.onEvent = { received.append($0) }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        try await waitUntil { server.connectedClients == 1 }
        let box = TextBox(left: 0.7, top: 0.05, right: 0.95, bottom: 0.12)
        server.sendRegion(id: "q", text: "Demirciyi bul", box: box, lineHeight: 0.03)
        server.sendRegion(id: "q", text: "", box: nil)
        server.clearRegions()

        let lines = try await readLines(bytes, until: "event: region-clear")
        XCTAssertTrue(lines.contains("event: region"))
        XCTAssertTrue(lines.contains(#"data: {"box":{"bottom":0.12,"left":0.7,"right":0.95,"top":0.05},"id":"q","line":0.03,"text":"Demirciyi bul"}"#), "\(lines)")
        XCTAssertTrue(lines.contains(#"data: {"id":"q","text":""}"#), "\(lines)")
        XCTAssertEqual(received.all, [.region(id: "q", text: "Demirciyi bul", box: box), .region(id: "q", text: "", box: nil), .regionClear])
    }

    /// #1198: yeniden bağlanan TV o an gösterilen alanları alır (`region-sync` ve `keep`'li olaylar); kopukken kaçan
    /// temizleme komutu yüzünden kalmış alanları TV listeye bakıp kaldırır.
    func testNewStreamGetsTheLiveRegionsAfterASync() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let box = TextBox(left: 0.7, top: 0.05, right: 0.95, bottom: 0.12)
        server.sendRegion(id: "q", text: "Demirciyi bul", box: box, lineHeight: 0.03)
        server.sendRegion(id: "game-phone", text: "Neredesin?", box: box, lineHeight: 0.03)
        server.sendRegion(id: "gone", text: "Eski", box: box, lineHeight: 0.03)
        server.sendRegion(id: "gone", text: "", box: nil)
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
            if line.contains(#""id":"q""#) { break }
        }
        let sync = try XCTUnwrap(lines.firstIndex(of: "event: region-sync"))
        XCTAssertEqual(lines[sync + 1], #"data: {"ids":["game-phone","q"]}"#)
        XCTAssertTrue(lines.contains { $0.contains(#""id":"game-phone""#) && $0.contains(#""keep":true"#) }, "\(lines)")
        XCTAssertTrue(lines.last!.contains(#""keep":true"#))
        XCTAssertFalse(lines.contains { $0.contains(#""id":"gone""#) })

        server.clearRegions()
        let (again, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        var next: [String] = []
        for try await line in again.lines {
            next.append(line)
            if line.hasPrefix(#"data: {"ids""#) { break }
        }
        XCTAssertEqual(next.last, #"data: {"ids":[]}"#)
    }

    /// Gösterilen alanlar düzenli yenilenir (TV'deki 15 sn'lik ömür dolmasın); telefon kartı yenilenmez.
    func testLiveRegionsAreRefreshedExceptThePhoneCard() async throws {
        let server = SubtitleServer(port: 0)
        server.regionRefreshInterval = 0.05
        let port = try await server.start()
        defer { server.stop() }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        try await waitUntil { server.connectedClients == 1 }
        let box = TextBox(left: 0.7, top: 0.05, right: 0.95, bottom: 0.12)
        server.sendRegion(id: "game-phone", text: "Neredesin?", box: box, lineHeight: 0.03)
        server.sendRegion(id: "q", text: "Demirciyi bul", box: box, lineHeight: 0.03)
        var lines: [String] = []
        var refreshes = 0
        for try await line in bytes.lines {
            lines.append(line)
            if line.contains(#""id":"q""#), line.contains(#""keep":true"#) { refreshes += 1 }
            if refreshes == 3 { break }
        }
        XCTAssertFalse(lines.contains { $0.contains(#""id":"game-phone""#) && $0.contains(#""keep":true"#) }, "\(lines)")
    }

    func testOnlyPhoneBlocksCarryNativeSurfaceOnTVAndDesktop() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let received = LockedEvents()
        server.onEvent = { received.append($0) }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        try await waitUntil { server.connectedClients == 1 }
        let box = TextBox(left: 0.4, top: 0.45, right: 0.55, bottom: 0.50)
        var item = ScreenTranslation.Item(source: "Reply", translation: "Yanıtla", box: box, lineHeight: 0.05)
        item.style = PhoneTextStyle(background: "#123456", foreground: "#ABCDEF")
        for id in ["q", "game-phone"] {
            server.sendRegion(id: id, text: item.translation, box: box, lineHeight: item.lineHeight, icons: nil, blocks: [item])
        }
        server.sendRegion(id: "game-phone", text: "", box: nil)
        server.clearRegions()

        let lines = try await readLines(bytes, until: "event: region-clear")
        let phone = try XCTUnwrap(lines.first { $0.contains(#""id":"game-phone""#) && $0.contains(#""blocks""#) })
        XCTAssertTrue(phone.contains(##""surface":{"background":"#123456","foreground":"#ABCDEF"}"##))
        let manual = try XCTUnwrap(lines.first { $0.contains(#""id":"q""#) })
        XCTAssertFalse(manual.contains(#""surface""#))
        XCTAssertEqual(received.all, [.region(id: "q", text: item.translation, box: box), .gamePhone([item]), .gamePhone([]), .regionClear])

        item.style = PhoneTextStyle(background: "transparent", foreground: "#ABCDEF")
        XCTAssertNil(SubtitleServer.json(item, phone: true)["surface"])
    }

    func testSpeechIsAnnouncedAndServed() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }

        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        try await waitUntil { server.connectedClients == 1 }
        let wav = SpeechAudio(samples: [0, 0.5], sampleRate: 24000).wav
        server.sendSpeech(wav, durationMs: 1200)
        server.clear()

        let lines = try await readLines(bytes, until: "event: clear")
        XCTAssertTrue(lines.contains("event: speech"))
        XCTAssertTrue(lines.contains(#"data: {"duration":1200,"url":"\/speech\/1.wav"}"#) || lines.contains(#"data: {"duration":1200,"url":"/speech/1.wav"}"#), "\(lines)")

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/speech/1.wav")!)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        XCTAssertEqual(data, wav)
    }

    func testPublishedFileIsServed() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        server.publish(Data([1, 2, 3]), at: "/voices/male_1.wav")
        try await waitUntil { true }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/voices/male_1.wav")!)
        XCTAssertEqual(data, Data([1, 2, 3]))
    }

    func testNewClientReceivesLastStyle() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        server.sendStyle(SubtitleStyle(fontSize: 58, bottomPercent: 10, placement: .above, background: 40, bold: true, textColor: .yellow,
                                       displayMode: .overlay))

        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        var sawStyle = false
        for try await line in bytes.lines where line.hasPrefix("data:") {
            sawStyle = line.contains("\"fontSize\":58") && line.contains("\"bottomPercent\":10") && line.contains("\"placement\":\"above\"")
                && line.contains("\"background\":40") && line.contains("\"bold\":true")
                && line.contains("\"textColor\":\"yellow\"") && line.contains("\"displayMode\":\"overlay\"")
            break
        }
        XCTAssertTrue(sawStyle)
    }

    func testClientCountDropsWhenClientDisconnects() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }

        let task = Task {
            let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
            for try await _ in bytes.lines {}
        }
        try await waitUntil { server.connectedClients == 1 }
        task.cancel()
        try await waitUntil { server.connectedClients == 0 }
    }

    func testObsOverlayIsServedAndNotCountedAsTv() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }

        let (page, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/obs")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("/events?viewer=obs"))

        // OBS katmanı olayları alır ama "TV bağlı" sayısına katılmaz.
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?viewer=obs")!)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(server.connectedClients, 0)
        server.sendSubtitle("Merhaba", durationMs: 4000)
        server.clear()
        let lines = try await readLines(bytes, until: "event: clear")
        XCTAssertTrue(lines.contains("event: subtitle"))
    }

    /// İkinci ekran: sayfa ve akışı anahtarsız (eski TV geçişi açıkken de) ya da yanlış anahtarla açılmaz; doğru
    /// anahtarla sayfa gelir, akış TV sayılmaz ve altyazı hedefi TV değilken de altyazıyı alır.
    func testSecondScreenNeedsTheKeyAndAlwaysGetsSubtitles() async throws {
        let server = SubtitleServer(port: 0, key: "dogru-anahtar", allowLegacy: true)
        let port = try await server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        for target in ["/view", "/view?k=yanlis", "/events?viewer=second", "/events?viewer=second&k=yanlis"] {
            let (_, response) = try await URLSession.shared.data(from: URL(string: base + target)!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401, target)
        }
        let (page, response) = try await URLSession.shared.data(from: URL(string: base + "/view?k=dogru-anahtar")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let html = String(decoding: page, as: UTF8.self)
        XCTAssertTrue(html.contains("/events?viewer=second&k="))
        XCTAssertTrue(html.contains("wakeLock"))

        server.sendsToTV = false
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: base + "/events?viewer=second&k=dogru-anahtar")!)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(server.connectedClients, 0)
        XCTAssertFalse(server.hasLegacyClient)
        server.sendSubtitle("Merhaba", durationMs: 4000)
        server.clear()
        let lines = try await readLines(bytes, until: "event: clear")
        XCTAssertTrue(lines.contains { $0.hasPrefix("data:") && $0.contains("\"text\":\"Merhaba\"") })
    }

    func testSecondScreenAddressCarriesTheKey() {
        XCTAssertEqual(SecondScreen.address(host: "192.168.1.20", port: 8787, key: "a-b_C9"), "http://192.168.1.20:8787/view?k=a-b_C9")
        XCTAssertEqual(SecondScreen.address(host: "fe80::1", port: 8787, key: "k"), "http://[fe80::1]:8787/view?k=k")
        XCTAssertNotNil(SecondScreen.qrImage(for: "http://192.168.1.20:8787/view?k=a-b_C9"))
    }

    /// Şeffaflık tanımayan yayın programları için düz zemin (?bg=green) ve OBS'te kapalı ipucu; adresteki
    /// parametreler sayfayı değiştirmez, aynı dosya gelir.
    func testObsOverlayOffersSolidBackgroundAndHint() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/obs?bg=green&hint=1")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let page = String(decoding: data, as: UTF8.self)
        for background in StreamBackground.allCases {
            XCTAssertTrue(page.contains("\(background.rawValue): '#"), "sayfada \(background.rawValue) zemini yok")
        }
        XCTAssertTrue(page.contains("window.obsstudio"))
        XCTAssertTrue(page.contains("-webkit-font-smoothing: antialiased"))
    }

    func testStreamBackgroundDefaultsToGreenAndOpaqueBox() {
        XCTAssertEqual(StreamBackground(stored: nil), .green)
        XCTAssertEqual(StreamBackground(stored: "bozuk"), .green)
        XCTAssertEqual(StreamBackground(stored: "magenta"), .magenta)
        XCTAssertEqual(StreamBackground.green.rgb.green, 0xFF)
        XCTAssertEqual(StreamBackground.boxOpacity(background: 60), 1)
        XCTAssertEqual(StreamBackground.boxOpacity(background: 0), 0)
    }

    /// Altyazı yalnız bilgisayar ekranındayken TV'ye altyazı gitmez; OBS katmanı ve dublaj sesi gitmeye devam eder.
    func testSubtitlesSkipTVsWhenTVOutputIsOff() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        server.sendsToTV = false
        let (tv, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        let (obs, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?viewer=obs")!)
        try await waitUntil { server.connectedClients == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        server.sendSubtitle("Merhaba", durationMs: 4000)
        server.stopSpeech()
        server.clear()

        let obsLines = try await readLines(obs, until: "event: clear")
        XCTAssertTrue(obsLines.contains("event: subtitle"))
        let tvLines = try await readLines(tv, until: "event: speech-stop")
        XCTAssertFalse(tvLines.contains("event: subtitle"))
    }

    /// #268: çıkış olayı TV'ye gider, OBS katmanına gitmez; tamamlanınca bildirilir.
    func testExitTVAppReachesTVsOnly() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let (tv, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        let (obs, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?viewer=obs")!)
        try await waitUntil { server.connectedClients == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        let sent = expectation(description: "çıkış yazıldı")
        server.exitTVApp { sent.fulfill() }
        await fulfillment(of: [sent], timeout: 3)
        server.stopSpeech()

        let tvLines = try await readLines(tv, until: "event: speech-stop")
        XCTAssertTrue(tvLines.contains("event: exit"))
        let obsLines = try await readLines(obs, until: "event: speech-stop")
        XCTAssertFalse(obsLines.contains("event: exit"))
    }

    /// Bilgisayar ekranındaki pencere sunucudan geçen altyazıyı alır; sunucu başlamamış olsa da.
    func testLocalListenerGetsSubtitleAndClear() {
        let server = SubtitleServer(port: 0)
        let received = LockedEvents()
        server.onEvent = { received.append($0) }
        server.sendSubtitle("Merhaba", durationMs: 4000)
        server.clear()
        XCTAssertEqual(received.all, [.subtitle(text: "Merhaba", durationMs: 4000, paragraphs: false), .clear])
    }

    /// Altyazının oyundaki yeri pencereye de gider: "Yazı kadar" kutu oyunun altyazısını örtecek kadar büyür.
    func testLocalListenerGetsTheSubtitleBox() {
        let server = SubtitleServer(port: 0)
        let received = LockedEvents()
        server.onEvent = { received.append($0) }
        let box = TextBox(left: 0.25, top: 0.8, right: 0.75, bottom: 0.9)
        server.sendSubtitle("Merhaba", durationMs: 4000, box: box)
        XCTAssertEqual(received.all, [.subtitle(text: "Merhaba", durationMs: 4000, paragraphs: false, box: box)])
    }

    /// "Ekranı çevir" sonuçları da pencereye gider: altyazı yalnız bilgisayardayken (TV yok) hiçbir yerde görünmüyordu.
    func testLocalListenerGetsScreenTranslations() {
        let server = SubtitleServer(port: 0)
        let received = LockedEvents()
        server.onEvent = { received.append($0) }
        let box = TextBox(left: 0.1, top: 0.1, right: 0.4, bottom: 0.2)
        let items = [ScreenTranslation.Item(source: "Map\nInventory", translation: "Harita\nEnvanter", box: box, lineHeight: 0.03),
                     ScreenTranslation.Item(source: "", translation: ScreenPhoneCard.backdropText, box: box, lineHeight: 0.03),
                     ScreenTranslation.Item(source: "Leave", translation: "Ayrıl", box: box, lineHeight: 0.03)]
        server.sendScreen(items, durationMs: 12000)
        server.clearScreen()
        // Telefon kartının zemini düz metne girmez; öğeler yerleriyle pencereye de gider.
        XCTAssertEqual(received.all, [.screen(text: "Harita\nEnvanter\nAyrıl", durationMs: 12000, items: items), .screenClear])
    }

    func testHelloIdentifiesTheApp() async throws {
        let server = SubtitleServer(port: 0, instanceId: "3f2a-b9")
        let port = try await server.start()
        defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/hello")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNil((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"app":"couchsubs","auth":1,"id":"3f2a-b9","tvs":0,"live":0}"#)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(server.accessKey))
    }

    /// `/hello`'daki `live`: çeviri sürüyor ve altyazı TV'ye gidiyorsa 1. TV boştaki kayıtlı CouchSubs yerine çevireni seçer.
    func testHelloSaysWhetherSubtitlesGoToTheTV() async throws {
        let server = SubtitleServer(port: 0, instanceId: "3f2a-b9")
        let port = try await server.start()
        defer { server.stop() }
        func hello() async throws -> String {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/hello")!)
            return String(decoding: data, as: UTF8.self)
        }
        server.pairing.setSession(true)
        let live = try await hello()
        XCTAssertTrue(live.hasSuffix(#","live":1}"#), live)
        server.sendsToTV = false
        let screenOnly = try await hello()
        XCTAssertTrue(screenOnly.hasSuffix(#","live":0}"#), screenOnly)
    }

    /// Kurulum kimliği kalıcıdır: aynı ağdaki iki CouchSubs'ı TV bununla ayırır (GitHub #425).
    func testInstallationIdIsStable() {
        let first = SubtitleServer.installationId
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(SubtitleServer.installationId, first)
        XCTAssertEqual(SubtitleServer.helloBody(id: "a\"b", tvs: 2), #"{"app":"couchsubs","auth":1,"id":"ab","tvs":2,"live":0}"#)
        XCTAssertEqual(SubtitleServer.helloBody(id: "x", tvs: 0, live: true), #"{"app":"couchsubs","auth":1,"id":"x","tvs":0,"live":1}"#)
    }

    func testUnknownPathIs404() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }

        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/nope")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    func testOldSavedStyleGetsNewDefaults() throws {
        let style = try JSONDecoder().decode(SubtitleStyle.self, from: Data(#"{"fontSize":58,"bottomPercent":12}"#.utf8))
        XCTAssertEqual(style, SubtitleStyle(fontSize: 58, bottomPercent: 12, placement: .cover, background: 90, bold: false,
                                             textColor: .white, displayMode: .auto))
    }

    func testBackgroundShapeIsSentAndOldStyleDefaultsToFit() throws {
        var style = SubtitleStyle(background: 100)
        XCTAssertEqual(style.backgroundShape, .fit)
        XCTAssertEqual(style.json["backgroundShape"] as? String, "fit")
        style.backgroundShape = .band
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(decoded.backgroundShape, .band)
        XCTAssertEqual(style.json["background"] as? Int, 100)
        XCTAssertEqual(style.json["backgroundShape"] as? String, "band")
        let unknown = try JSONDecoder().decode(SubtitleStyle.self, from: Data(#"{"backgroundShape":"yeni"}"#.utf8))
        XCTAssertEqual(unknown.backgroundShape, .fit)
    }

    func testDisplayModeIsSavedAndRestored() throws {
        var style = SubtitleStyle()
        style.displayMode = .overlay
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(decoded.displayMode, .overlay)
        XCTAssertEqual(style.json["displayMode"] as? String, "overlay")
    }

    /// Eski kayıttaki "inApp" (eski varsayılan) Otomatik'tir ve TV'ye yine "inApp" gider; bilerek seçilen uygulama içi
    /// "inAppOnly" gider (Philips/TCL'de uygulama içi siyah: Otomatik izin varsa katmanda açar).
    func testOldInAppIsAutomaticAndChosenInAppIsSentApart() throws {
        XCTAssertEqual(SubtitleStyle().displayMode, .auto)
        let old = try JSONDecoder().decode(SubtitleStyle.self, from: Data(#"{"displayMode":"inApp"}"#.utf8))
        XCTAssertEqual(old.displayMode, .auto)
        XCTAssertEqual(old.json["displayMode"] as? String, "inApp")
        var chosen = SubtitleStyle()
        chosen.displayMode = .inApp
        XCTAssertEqual(chosen.json["displayMode"] as? String, "inAppOnly")
        XCTAssertEqual(try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(chosen)).displayMode, .inApp)
    }

    /// "Hızlı konuşmada önceki satırları üstte tut": varsayılan açık, TV'ye `stackPrevious` olarak gider, eski ayar dosyasında yoksa açık kalır.
    func testStackPreviousIsSentSavedAndDefaultsOn() throws {
        var style = SubtitleStyle()
        XCTAssertEqual(style.json["stackPrevious"] as? Bool, true)
        style.stackPrevious = false
        XCTAssertEqual(style.json["stackPrevious"] as? Bool, false)
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(style))
        XCTAssertFalse(decoded.stackPrevious)
        XCTAssertTrue(try JSONDecoder().decode(SubtitleStyle.self, from: Data("{}".utf8)).stackPrevious)
    }

    /// "Ekran yazılarını altyazıdan ayır": `style` olayı `setApart` alanını taşır (varsayılan açık); eski ayarlar açık gelir.
    func testStyleCarriesSetApart() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let (bytes, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        try await waitUntil { server.connectedClients == 1 }
        server.sendStyle(SubtitleStyle())
        server.setApart = false
        server.sendStyle(SubtitleStyle())
        server.clear()
        let styles = try await readLines(bytes, until: "event: clear").filter { $0.hasPrefix("data:") && $0.contains("fontSize") }
        XCTAssertEqual(styles.count, 2)
        XCTAssertTrue(styles[0].contains("\"setApart\":true"))
        XCTAssertTrue(styles[1].contains("\"setApart\":false"))
        XCTAssertTrue(try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8)).setTextApart)
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SubtitleEvent] = []
    func append(_ event: SubtitleEvent) { lock.withLock { events.append(event) } }
    var all: [SubtitleEvent] { lock.withLock { events } }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
}
