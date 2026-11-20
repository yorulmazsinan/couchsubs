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

    /// Konuşana göre renk açıkken adlı satır `speakers` alanını taşır; adsız satırda ve ayar kapalıyken alan yoktur.
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
        XCTAssertFalse(data[0].contains("speakers"))
        XCTAssertTrue(data[1].contains("\"speakers\":[{"))
        XCTAssertTrue(data[1].contains("\"name\":\"Mattia\"") && data[1].contains("#90CAF9"))
        XCTAssertTrue(data[1].contains("\"name\":\"Lucia\"") && data[1].contains("#F06292"))
        XCTAssertFalse(data[2].contains("speakers"))
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

    /// "Ekranı çevir" sonuçları da pencereye gider: altyazı yalnız bilgisayardayken (TV yok) hiçbir yerde görünmüyordu.
    func testLocalListenerGetsScreenTranslations() {
        let server = SubtitleServer(port: 0)
        let received = LockedEvents()
        server.onEvent = { received.append($0) }
        let box = TextBox(left: 0.1, top: 0.1, right: 0.4, bottom: 0.2)
        server.sendScreen([ScreenTranslation.Item(source: "Map\nInventory", translation: "Harita\nEnvanter", box: box, lineHeight: 0.03),
                           ScreenTranslation.Item(source: "Leave", translation: "Ayrıl", box: box, lineHeight: 0.03)], durationMs: 12000)
        server.clearScreen()
        XCTAssertEqual(received.all, [.screen(text: "Harita\nEnvanter\nAyrıl", durationMs: 12000), .screenClear])
    }

    func testHelloIdentifiesTheApp() async throws {
        let server = SubtitleServer(port: 0, instanceId: "3f2a-b9")
        let port = try await server.start()
        defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/hello")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNil((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"app":"couchsubs","auth":1,"id":"3f2a-b9","tvs":0}"#)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(server.accessKey))
    }

    /// Kurulum kimliği kalıcıdır: aynı ağdaki iki CouchSubs'ı TV bununla ayırır (GitHub #425).
    func testInstallationIdIsStable() {
        let first = SubtitleServer.installationId
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(SubtitleServer.installationId, first)
        XCTAssertEqual(SubtitleServer.helloBody(id: "a\"b", tvs: 2), #"{"app":"couchsubs","auth":1,"id":"ab","tvs":2}"#)
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
                                             textColor: .white, displayMode: .inApp))
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
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SubtitleEvent] = []
    func append(_ event: SubtitleEvent) { lock.withLock { events.append(event) } }
    var all: [SubtitleEvent] { lock.withLock { events } }
}
