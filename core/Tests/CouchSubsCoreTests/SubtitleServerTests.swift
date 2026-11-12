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
        XCTAssertEqual(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
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

    /// Bilgisayar ekranındaki pencere sunucudan geçen altyazıyı alır; sunucu başlamamış olsa da.
    func testLocalListenerGetsSubtitleAndClear() {
        let server = SubtitleServer(port: 0)
        let received = LockedEvents()
        server.onEvent = { received.append($0) }
        server.sendSubtitle("Merhaba", durationMs: 4000)
        server.clear()
        XCTAssertEqual(received.all, [.subtitle(text: "Merhaba", durationMs: 4000, paragraphs: false), .clear])
    }

    func testHelloIdentifiesTheApp() async throws {
        let server = SubtitleServer(port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/hello")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"app":"couchsubs"}"#)
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
        XCTAssertEqual(style, SubtitleStyle(fontSize: 58, bottomPercent: 12, placement: .cover, background: 72, bold: false,
                                             textColor: .white, displayMode: .inApp))
    }

    func testDisplayModeIsSavedAndRestored() throws {
        var style = SubtitleStyle()
        style.displayMode = .overlay
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(decoded.displayMode, .overlay)
        XCTAssertEqual(style.json["displayMode"] as? String, "overlay")
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SubtitleEvent] = []
    func append(_ event: SubtitleEvent) { lock.withLock { events.append(event) } }
    var all: [SubtitleEvent] { lock.withLock { events } }
}
