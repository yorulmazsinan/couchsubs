// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import CoreGraphics
import Foundation

/// Kutu örtme testinde geçme sınırı: beklenen altyazının yazı piksellerinin en az bu kadarı örtülmeli.
let coverPass = 0.95

struct FrameResult: Codable {
    var id: String
    var game: String
    var expected: String?
    /// TV'ye giden altyazıların kaynağı (okunan İngilizce satır).
    var sent: [String] = []
    var captured: Bool?
    var falseAccept: Bool?
    /// Piksel testi: beklenen altyazının yazı piksellerinin çizim kutusuyla örtülen oranı.
    var coverage: Double?
    var phoneExpected: String
    var phoneDetected: String
    var mapExpected: Bool
    var mapDetected: Bool
    /// Ekran yazısı denetimi geçti mi ("Ekranı çevir" ve otomatik ekran yazısı); beklenen yoksa nil.
    var screen: Bool?
    var screenNotes: [String]?
}

struct ScenarioResult: Codable {
    var name: String
    var passed: Bool
    var detail: String
}

struct Summary: Codable {
    struct Metric: Codable {
        var passed: Int
        var total: Int
        var rate: Double { total == 0 ? 1 : Double(passed) / Double(total) }
        enum CodingKeys: String, CodingKey { case passed, total }
    }
    var core: String
    /// Altyazı satırı yakalama (yüksek iyi).
    var capture: Metric
    /// Yanlış kabul: tabela/tişört ya da altyazısız karede gönderilen satır (düşük iyi).
    var falseAccept: Metric
    /// Telefon sınıflama (yok / sohbet / ana ekran / liste).
    var phone: Metric
    /// Harita görev kartı sınıflama.
    var map: Metric
    /// Çizim kutusu beklenen altyazıyı örtüyor (yakalanan satırlarda, piksel testi ≥ %95).
    var cover: Metric
    /// Telefon çevirisi senaryoları (çeviri gelince telefonda gösteriliyor).
    var phoneTranslation: Metric
    /// Konuşan adı sonradan okunan satır tek çeviriyle, aynı satırın yerine geçerek gösteriliyor (adsız + adlı iki satır yok).
    var speaker: Metric
    /// Ekran yazısı: menü sekmeleri ayrı, görev başlığı/açıklaması ayrı, özel ad çevrilmez, fotoğraf örtülmez, özgün renk.
    var screen: Metric
    var frames: [FrameResult]
    var scenarios: [ScenarioResult]
    var speakerScenarios: [ScenarioResult]
}

@MainActor
final class Runner {
    let directory: URL
    let manifest: Manifest
    let words: [String: String]
    let reader = CachedReader(base: VisionReader(language: "en"))
    var images: [String: CGImage] = [:]
    let verbose: Bool
    /// Ayrıntılı: hattın bütün günlüğü (FRAME_REGRESSION_LOG=1).
    let verboseAll = ProcessInfo.processInfo.environment["FRAME_REGRESSION_LOG"] == "1"

    init(directory: URL, verbose: Bool) throws {
        self.directory = directory
        self.verbose = verbose
        manifest = try Manifest.load(directory)
        let dictionary = directory.appendingPathComponent("sozluk.json")
        words = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: dictionary))) ?? [:]
        for frame in manifest.frames {
            guard let image = Images.load(directory.appendingPathComponent(frame.file)) else {
                throw NSError(domain: "frame-regression", code: 1, userInfo: [NSLocalizedDescriptionKey: "kare okunamadı: \(frame.file)"])
            }
            images[frame.id] = image
        }
    }

    func run(core: String) async -> Summary {
        var results: [String: FrameResult] = [:]
        for frame in manifest.frames {
            results[frame.id] = FrameResult(id: frame.id, game: frame.game, expected: frame.subtitle,
                                            phoneExpected: frame.phone ?? "none", phoneDetected: "none",
                                            mapExpected: frame.mapCard ?? false, mapDetected: false)
        }
        // 1) Altyazı hattı: oturum oturum, karenin sırasıyla.
        var sessions: [[Frame]] = []
        var index: [String: Int] = [:]
        for frame in manifest.frames {
            if let key = frame.session, let at = index[key] {
                sessions[at].append(frame)
            } else {
                if let key = frame.session { index[key] = sessions.count }
                sessions.append([frame])
            }
        }
        for session in sessions {
            await runSubtitles(session, into: &results)
        }
        // 2) Telefon ve harita kartı: bütün kare okunur.
        for frame in manifest.frames {
            let image = images[frame.id]!
            classify(frame, image, into: &results[frame.id]!)
        }
        // 3) Ekran yazısı (menü, görev listesi).
        for frame in manifest.frames where frame.screen != nil {
            let notes = await checkScreen(frame, images[frame.id]!)
            results[frame.id]!.screen = notes.isEmpty
            results[frame.id]!.screenNotes = notes.isEmpty ? nil : notes
        }
        // 4) Telefon çevirisi senaryoları.
        var scenarios: [ScenarioResult] = []
        for scenario in manifest.phoneScenarios {
            scenarios.append(await runPhone(scenario))
        }
        // 5) Konuşan adı sonradan okunan diyalog.
        var speakers: [ScenarioResult] = []
        for scenario in manifest.speakerScenarios {
            speakers.append(await runSpeaker(scenario))
        }
        let frames = manifest.frames.map { results[$0.id]! }
        func metric(_ values: [Bool]) -> Summary.Metric { Summary.Metric(passed: values.filter { $0 }.count, total: values.count) }
        return Summary(
            core: core,
            capture: metric(frames.compactMap(\.captured)),
            falseAccept: metric(frames.compactMap(\.falseAccept)),
            phone: metric(frames.map { $0.phoneExpected == $0.phoneDetected }),
            map: metric(frames.map { $0.mapExpected == $0.mapDetected }),
            cover: metric(frames.compactMap { $0.coverage.map { $0 >= coverPass } }),
            phoneTranslation: metric(scenarios.map(\.passed)),
            speaker: metric(speakers.map(\.passed)),
            screen: metric(frames.compactMap(\.screen)),
            frames: frames,
            scenarios: scenarios,
            speakerScenarios: speakers)
    }

    /// Ad örtülü kare (adsız okuma çevrilip gösterilir), sonra aynı kare adıyla: cümle bir kez çevrilmeli, adlı satır
    /// ekrandakinin yerine geçmeli (ya da yalnız adlı satır gitmeli) ve ad gösterilmeli.
    private func runSpeaker(_ scenario: SpeakerScenario) async -> ScenarioResult {
        guard let frame = manifest.frames.first(where: { $0.id == scenario.frame }), let image = images[frame.id],
              let hide = box(scenario.nameBox), let expected = frame.subtitle, let name = SpeakerPrefix.split(expected)?.name else {
            return ScenarioResult(name: scenario.name, passed: false, detail: "kare ya da adlı altyazı yok")
        }
        let unnamed = Images.hiding(image, hide)
        let blank = Images.blank(width: image.width, height: image.height)
        let translator = DictionaryTranslator(words: words)
        let server = SubtitleRecorder()
        var now = 1_000_000
        let queue = ReadQueue(label: "frame-regression-speaker", timeoutMs: 300_000)
        let pipeline = SubtitlePipeline(reader: reader, translator: translator, server: server, clock: { now }, readQueue: queue)
        pipeline.holdReadings = false
        var log: [String] = []
        pipeline.onLog = { log.append($0) }
        for (picture, count) in [(unnamed, 4), (image, 10), (blank, 6)] {
            for _ in 0..<count {
                await pipeline.process(picture, region: frame.cropRegion)
                await pipeline.waitForTranslations()
                now += 100
            }
        }
        let sent = server.sent.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let calls = translator.calls.map(\.source)
        var problems: [String] = []
        if sent.isEmpty { problems.append("hiç gönderilmedi") }
        if calls.count != 1 { problems.append("\(calls.count) çeviri (\(calls.map { "\"\($0)\"" }.joined(separator: ", ")))") }
        if sent.dropFirst().contains(where: { !$0.replaces }) { problems.append("ikinci gönderim yerine geçmiyor (TV'de iki satır)") }
        if let last = sent.last, !last.text.hasPrefix(name + ":") { problems.append("ad gösterilmedi (\(last.text))") }
        if verbose {
            print("— konuşan adı senaryosu \(scenario.name): \(sent.map { "\"\($0.text)\"\($0.replaces ? " (yerine)" : "")" }.joined(separator: ", "))")
            for line in log { print("    \(line)") }
        }
        return ScenarioResult(name: scenario.name, passed: problems.isEmpty,
                              detail: problems.isEmpty ? "\(sent.count) gönderim, tek çeviri, ad eklendi" : problems.joined(separator: "; "))
    }

    /// Bir oturumun kareleri aynı hattan geçer: her kare ~1 sn ekranda kalır, sonra 0,6 sn boş kare (altyazı kalkar).
    private func runSubtitles(_ frames: [Frame], into results: inout [String: FrameResult]) async {
        let translator = DictionaryTranslator(words: words)
        let server = SubtitleRecorder()
        var now = 1_000_000
        // Kendi okuma sırası, uzun süre sınırıyla: CI makinesinde ilk Vision okuması (model yükleme) uygulamanın 10 sn'lik
        // sınırını aşabiliyor; aşınca sıra "takılı" sayılıp sonraki okumalar atlanıyordu. Ölçülen okuma değil, seçim.
        let queue = ReadQueue(label: "frame-regression", timeoutMs: 300_000)
        let pipeline = SubtitlePipeline(reader: reader, translator: translator, server: server, clock: { now }, readQueue: queue)
        pipeline.holdReadings = false
        var log: [String] = []
        pipeline.onLog = { log.append($0) }
        for frame in frames {
            let image = images[frame.id]!
            let blank = Images.blank(width: image.width, height: image.height)
            let region = frame.cropRegion
            server.current = frame.id
            let before = server.sent.count
            let logBefore = log.count
            for _ in 0..<10 {
                await pipeline.process(image, region: region)
                now += 100
            }
            await pipeline.waitForTranslations()
            for _ in 0..<6 {
                await pipeline.process(blank, region: region)
                now += 100
            }
            await pipeline.waitForTranslations()
            let sent = server.sent[before...].filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let sources = sent.map { translator.source(of: $0.text) ?? $0.text }
            var result = results[frame.id]!
            result.sent = sources
            if let expected = frame.subtitle {
                let body = withoutSpeaker(expected)
                let hit = sent.indices.first { Self.matches(sources[$0], body) }
                result.captured = hit != nil
                if let hit, let expectedBox = box(frame.subtitleBox), let drawn = sent[hit].box {
                    result.coverage = Images.coverage(of: expectedBox, by: Self.drawn(drawn, frame: image), in: image)
                }
            }
            // Yanlış kabul: altyazısız karede gönderilen her satır, altyazılı karede tabela yazısı taşıyan satır.
            let signs = frame.signs ?? []
            if frame.subtitle == nil || !signs.isEmpty {
                let wrong = sources.contains { source in
                    frame.subtitle == nil || signs.contains { mentions(source, $0) && !mentions(frame.subtitle ?? "", $0) }
                }
                result.falseAccept = !wrong
            }
            results[frame.id] = result
            if verbose {
                print("— \(frame.id): \(sources.map { "\"\($0)\"" }.joined(separator: ", "))")
                for line in log[logBefore...] where verboseAll || line.contains("sahne yazısı") || line.contains("sabit satır") {
                    print("    \(line)")
                }
            }
        }
    }

    /// Giden satır beklenen altyazı mı: yazı tanıma farkına (%80 benzerlik) izin verilir; ayrı satırda duran konuşan adı
    /// ("MORI RANMARU", AC Shadows) bloğa katılmışsa da altyazı yakalanmıştır.
    static func matches(_ source: String, _ expected: String) -> Bool {
        let body = withoutSpeaker(source)
        if similarity(body, expected) >= 0.8 { return true }
        let lines = body.split(separator: "\n").map(String.init)
        guard lines.count > 1, lines[0].split(separator: " ").count <= 3, lines[0] == lines[0].uppercased() else { return false }
        return similarity(lines.dropFirst().joined(separator: " "), expected) >= 0.8
    }

    /// Örtme kutusunun kenar payı, 1080p ekranda nokta (`OverlayCover.margin`; eski çekirdeklerde o ad yok, değer aynı).
    static let coverMargin = 8.0

    /// TV'nin çizdiği kutu: altyazının kutusu, kenar payıyla.
    static func drawn(_ box: TextBox, frame: CGImage) -> TextBox {
        let dx = coverMargin / 1920, dy = coverMargin / 1080
        return TextBox(left: box.left - dx, top: box.top - dy, right: box.right + dx, bottom: box.bottom + dy)
    }

    private func classify(_ frame: Frame, _ image: CGImage, into result: inout FrameResult) {
        let reading = (try? reader.readLines(image, deep: false)) ?? .empty
        if let handset = ScreenPhoneCard.phone(in: image) {
            let groups = ScreenTranslation.groups(reading, frame: image, wholeScreen: true, handset: handset)
            let roles = Set(groups.compactMap { $0.phone?.role.rawValue })
            if roles.contains("home") {
                result.phoneDetected = "home"
            } else if !roles.isDisjoint(with: ["incoming", "outgoing", "message"]) {
                result.phoneDetected = "chat"
            } else if !roles.isDisjoint(with: ["contact", "preview"]) {
                result.phoneDetected = "list"
            } else {
                result.phoneDetected = "phone"
            }
        }
        let lines = reading.lines.filter { $0.box != nil }
        result.mapDetected = MissionCard.find(lines).contains { card in MissionCard.onPanel(image, card.all.map { lines[$0] }) }
    }

    /// GitHub #822 / #801: çeviri motordayken telefon bir turda doğrulanamıyor, sonra aynı görünüşe dönüyor. Gelen
    /// çeviri sonraki turda telefon kartında görünmeli.
    private func runPhone(_ scenario: PhoneScenario) async -> ScenarioResult {
        guard let phone = images[scenario.phone], let gone = images[scenario.gone] else {
            return ScenarioResult(name: scenario.name, passed: false, detail: "kare yok")
        }
        guard let pose = GamePhoneGeometry.locate(phone) else {
            return ScenarioResult(name: scenario.name, passed: false, detail: "telefon bulunamadı")
        }
        let translator = DictionaryTranslator(words: words)
        translator.holdFirst()
        let server = RegionRecorder()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        watcher.slowdown = { 1 }
        watcher.offer(phone, areas: [], phone: pose)
        guard await waitUntil({ translator.isHolding || !watcher.isBusy }), translator.isHolding else {
            return ScenarioResult(name: scenario.name, passed: false, detail: "telefon okunup çeviriye gitmedi")
        }
        watcher.offer(gone, areas: [], phone: pose)
        translator.release()
        _ = await waitUntil { !watcher.isBusy }
        clock += 450
        watcher.offer(phone, areas: [], phone: pose)
        _ = await waitUntil { !watcher.isBusy }
        // Gecikmeli tur: telefon izleyicisi kendi aralığıyla bir tur daha atabilir.
        for _ in 0..<4 {
            clock += 450
            watcher.offer(phone, areas: [], phone: pose)
            _ = await waitUntil { !watcher.isBusy }
        }
        let outputs = translator.calls.map(\.output)
        let shown = server.sent.last.map { last in outputs.contains { !$0.isEmpty && last.text.contains($0) } } ?? false
        return ScenarioResult(name: scenario.name, passed: shown,
                              detail: shown ? "çeviri gösterildi" : "çeviri gösterilmedi (\(server.sent.count) gönderim, \(outputs.count) çeviri)")
    }
}
