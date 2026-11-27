// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore

#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO

/// Sinan Bey (GTA 6, beta.105): görev kutusu ekranda kararsızdı: yanıp sönüyor, biçim değiştiriyor, yer değiştiriyor,
/// bazen altyazı olarak çevriliyordu. Gerçek kare okumalarıyla (testdata/frames/ocr: gta6-854-gorev-1/2/3,
/// pencere-kare-2/5-gorev) art arda okumalar: görev tek başına, konuşmayla birlikte, konuşma susunca yine tek başına, bir
/// okumada görev satırı kaçıyor ("kare@0": yalnız konuşma), iki saniyelik boş okuma (kamera geçişi), sonra görev gerçekten
/// kalkıyor. Altyazı hattı (`SubtitlePipeline`) ve görev kutusunu çizen ek alan (`RegionWatcher`, "auto-mission") birlikte
/// koşar. Görev kutusu bir kez belirir, yeri ve boyu değişmez, çevirisi bir kez istenir, ıskada kalkmaz, görev gerçekten
/// kalkınca bir kez kalkar; görev altyazı kutusuna dönmez, konuşma görev sayılmaz. Windows (MissionSteadyTests.cs) ve
/// Android (MissionSteadyTest.kt) aynı okumalarla aynı sonucu verir.
@MainActor
final class MissionSteadyTests: XCTestCase {
    struct Fixture: Decodable {
        struct Word: Decodable { let text: String; let box: [Double] }
        struct Line: Decodable { let text: String; let box: [Double]?; let confidence: Double?; let words: [Word]? }
        let region: [Double]
        let lines: [Line]
    }
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../testdata/frames").standardized
    }
    static func box(_ v: [Double]) -> TextBox { TextBox(left: v[0], top: v[1], right: v[2], bottom: v[3]) }
    static let subtitleArea = CropRegion(top: 0.62, bottom: 0.97, left: 0.14, right: 0.86)

    /// "kare" kaydı olduğu gibi; "kare@0" karenin yalnız 0. satırı (bu okumada görev satırı kaçtı); "-" boş okuma;
    /// "a+b" iki okumanın satırları birlikte (aynı karede görev satırı ve açık telefon).
    static func reading(_ id: String) throws -> Reading {
        if id == "-" { return .empty }
        if id.contains("+") {
            return Reading(lines: try id.split(separator: "+").flatMap { try reading(String($0)).lines })
        }
        let parts = id.split(separator: "@")
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("ocr/\(parts[0]).json")))
        XCTAssertEqual(f.region, [subtitleArea.left, subtitleArea.top, subtitleArea.right, subtitleArea.bottom])
        let keep = parts.count > 1 ? Int(parts[1]) : nil
        return Reading(lines: f.lines.enumerated().filter { keep == nil || $0.offset == keep }.map(\.element).map { l in
            TextLine(l.text, box: l.box.map(box), confidence: l.confidence, words: l.words?.map { TextWord($0.text, box: box($0.box)) })
        })
    }

    private final class Reader: TextReader, @unchecked Sendable {
        var next: () -> Reading
        init(_ next: @escaping () -> Reading) { self.next = next }
        func read(_ image: CGImage) throws -> String { try readLines(image, deep: false).text }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading { next() }
    }
    final class Sender: SubtitleSending {
        var subtitles: [String] = []
        var objectives: [TextBox?] = []
        func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { subtitles.append(text) }
        func clear() {}
        func sendObjective(_ box: TextBox?) { objectives.append(box) }
    }
    final class Translator: TextTranslator {
        var requested: [String] = []
        func translate(_ text: String) async throws -> String { requested.append(text); return "Çeviri: " + text }
    }
    final class Overlay: RegionSending {
        var sent: [(text: String, box: TextBox?)] = []
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            if id == MissionLine.areaId { sent.append((text, box)) }
        }
        func clearRegions() {}
    }

    struct Run {
        /// `onMissionChanged` değerleri (görev kutusunun alanı; nil: kalktı).
        var regions: [CropRegion?] = []
        /// Görev bölgesi belirdiğinde gönderilmiş altyazı sayısı.
        var subtitlesBeforeMission: Int?
        var sender = Sender()
        var requested: [String] = []
        var watcherRequested: [String] = []
        var overlay = Overlay()
        /// Altyazı hattının günlüğü.
        var log: [String] = []
    }

    /// Altyazı hattı 250 ms'de bir okur; görev kutusunun alanı (varsa) 500 ms'de bir okunur ve alanın içindeki satırlar
    /// (aynı karenin okuması) alana oranla verilir.
    func run(_ ids: [String]) async throws -> Run {
        let frames = try ids.map { try Self.reading($0) }
        // Telefonlu okumada kare telefonun gerçek karesidir: altyazı hattı telefonu piksellerden bulur (`ScreenPhoneCard.search`).
        var photos: [String: CGImage] = [:]
        for id in Set(ids) {
            guard let phone = id.split(separator: "+").map(String.init).first(where: { $0.hasPrefix("gta6-telefon") }) else { continue }
            let url = Self.directory.appendingPathComponent(phone.split(separator: "@")[0] + ".jpg")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            photos[id] = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        var time = 0, index = 0
        var result = Run()
        let translator = Translator()
        let pipeline = SubtitlePipeline(reader: Reader { frames[index] }, translator: translator, server: result.sender, clock: { time })
        pipeline.packWait = 0; pipeline.cleanWait = 0
        pipeline.onLog = { result.log.append($0) }
        var region: CropRegion?
        pipeline.onMissionChanged = { region = $0; result.regions.append($0) }
        let area = Self.subtitleArea
        let place = TextBox(left: area.left, top: area.top, right: area.right, bottom: area.bottom)
        let watchTranslator = Translator()
        let watcher = RegionWatcher(reader: Reader {
            guard let region else { return .empty }
            let r = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
            return Reading(lines: frames[index].lines.compactMap { line in
                guard let b = line.box?.placed(in: place), b.top >= r.top, b.bottom <= r.bottom else { return nil }
                let h = r.bottom - r.top, w = r.right - r.left
                return TextLine(line.text, box: TextBox(left: (b.left - r.left) / w, top: (b.top - r.top) / h,
                                                        right: (b.right - r.left) / w, bottom: (b.bottom - r.top) / h),
                                confidence: line.confidence)
            })
        }, translator: watchTranslator, server: result.overlay, clock: { time })
        func image(_ shade: UInt8) -> CGImage {
            let width = 320, height = 180
            var pixels = [UInt8](repeating: shade, count: width * height)
            let context = pixels.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            }
            return context!.makeImage()!
        }
        // Aynı okuma aynı görüntü: alan izi yalnız okuma değişince değişir.
        var shades: [String: UInt8] = [:]
        for (i, id) in ids.enumerated() {
            index = i
            let shade = shades[id] ?? UInt8(40 + 20 * shades.count)
            shades[id] = shade
            let frame = photos[id] ?? image(shade)
            await pipeline.process(frame, region: area)
            await pipeline.waitForTranslations()
            if region != nil, result.subtitlesBeforeMission == nil { result.subtitlesBeforeMission = result.sender.subtitles.count }
            if i % 2 == 0 {
                let areas = region.map { [ExtraArea(id: MissionLine.areaId, name: "Mission", region: $0, auto: true)] } ?? []
                await watcher.pass(frame, areas: areas)
            }
            time += 250
        }
        result.requested = translator.requested
        result.watcherRequested = watchTranslator.requested
        return result
    }

    static func rep(_ id: String, _ n: Int) -> [String] { Array(repeating: id, count: n) }

    static let speedboat: [String] = {
        let g1 = "gta6-854-gorev-1", g2 = "gta6-854-gorev-2", g3 = "gta6-854-gorev-3"
        return rep(g1, 4) + rep(g2, 12) + rep(g3, 16) + rep(g3 + "@0", 8) + rep(g3, 16) + rep(g2, 8) + rep(g1, 2)
            + rep(g3, 8) + rep("-", 8) + rep(g3, 16) + rep("-", 28)
    }()
    static let plane: [String] = {
        let p2 = "pencere-kare-2-gorev", p5 = "pencere-kare-5-gorev"
        return rep(p2, 12) + rep(p5, 16) + rep(p5 + "@0", 8) + rep(p5, 12) + rep(p2, 8) + rep("-", 8) + rep(p5, 16)
            + rep("-", 28)
    }()

    private func assertSteady(_ ids: [String], objective: String, dialogue: String, file: StaticString = #filePath,
                              line: UInt = #line) async throws {
        let run = try await run(ids)
        let regions = run.regions.map { $0.map { String(format: "%.3f-%.3f", $0.top, $0.bottom) } ?? "nil" }
        // Görev kutusu bir kez belirdi ve görev gerçekten kalkınca bir kez kalktı (ıskada, konuşma susunca kalkmadı).
        XCTAssertEqual(run.regions.count, 2, "görev bölgesi: \(regions)", file: file, line: line)
        XCTAssertNotNil(run.regions.first ?? nil, file: file, line: line)
        XCTAssertNil(run.regions.last ?? CropRegion(), file: file, line: line)
        // Bölge yalnız görev satırı: konuşma görev sayılıp bölgeye katılmadı.
        if let region = run.regions.first ?? nil {
            XCTAssertLessThan(region.bottom - region.top, 0.08, "görev bölgesi konuşmayı da kapsıyor: \(regions)", file: file, line: line)
        }
        // Altyazı kutusunun kaçacağı yer bir kez bildirildi, bir kez kalktı (altyazı aşağı yukarı sıçramaz).
        XCTAssertEqual(run.sender.objectives.count, 2, "\(run.sender.objectives)", file: file, line: line)
        // Görev kutusu belirdikten sonra görev satırı altyazı olarak çevrilmedi (biçim değiştirmez).
        let after = run.sender.subtitles.dropFirst(run.subtitlesBeforeMission ?? 0)
        XCTAssertFalse(after.contains { $0.contains(objective) }, "altyazılar: \(run.sender.subtitles)", file: file, line: line)
        // Konuşma altyazı olarak çevrildi.
        XCTAssertTrue(run.requested.contains { $0.contains(dialogue) }, "istekler: \(run.requested)", file: file, line: line)
        // Görev kutusu (TV'deki çizim): bir kez gönderildi, yeri ve boyu hep aynı, çevirisi bir kez istendi; tek boş
        // gönderim en sonda (görev kalktı).
        let drawn = run.overlay.sent.filter { !$0.text.isEmpty }
        XCTAssertEqual(drawn.count, 1, "görev kutusu: \(run.overlay.sent.map(\.text))", file: file, line: line)
        XCTAssertEqual(Set(drawn.compactMap { $0.box.map { "\($0)" } }).count, 1, file: file, line: line)
        XCTAssertEqual(run.watcherRequested.count, 1, "görev çevirisi: \(run.watcherRequested) kutu: \(drawn.map { $0.box.map { "\($0)" } ?? "" })", file: file, line: line)
        XCTAssertEqual(run.overlay.sent.last?.text, "", file: file, line: line)
        XCTAssertEqual(run.overlay.sent.filter { $0.text.isEmpty }.count, 1, file: file, line: line)
    }

    func testSpeedboatObjectiveBoxStaysSteadyAcrossReads() async throws {
        try await assertSteady(Self.speedboat, objective: "Speedboat", dialogue: "Somebody's happy to be free")
    }

    func testPlaneObjectiveBoxStaysSteadyAcrossReads() async throws {
        try await assertSteady(Self.plane, objective: "Follow the plane", dialogue: "Okay.")
    }

    /// Beta.106 (3 kullanıcı): telefon, görev ve hedef çevirileri birbirinin yerine geçiyordu. Görev kutusu kurulduktan sonra
    /// telefon açılır (gerçek telefon karesi `gta6-telefon-sohbet-1`, telefonu altyazı hattı piksellerden bulur) ve görev satırı
    /// telefonun yanında görünmeye devam eder; sonra telefon kapanır. Görev kutusu telefon yüzünden kalkmaz, yer değiştirmez;
    /// telefonun mesajları altyazıya da görev kutusuna da girmez.
    func testPhoneAndObjectiveStayIndependent() async throws {
        let g3 = "gta6-854-gorev-3", phone = "gta6-854-gorev-2+gta6-telefon-sohbet-1"
        let ids = Self.rep("gta6-854-gorev-2", 12) + Self.rep(g3, 16) + Self.rep(phone, 24) + Self.rep(g3, 12)
            + Self.rep(phone, 8) + Self.rep(g3, 8) + Self.rep("-", 28)
        let run = try await run(ids)
        // Telefon gerçek kareden bulundu (telefonun mesajları bu yüzden altyazı sayılmadı).
        XCTAssertTrue(run.log.contains { $0.hasPrefix("telefon bulundu") }, "\(run.log)")
        XCTAssertEqual(run.regions.count, 2, "görev bölgesi: \(run.regions)")
        XCTAssertNil(run.regions.last ?? CropRegion())
        XCTAssertEqual(run.sender.objectives.count, 2, "\(run.sender.objectives)")
        let messages = ["amigo", "ANYTHING", "bring it"]
        XCTAssertFalse(run.sender.subtitles.contains { s in messages.contains { s.contains($0) } }, "\(run.sender.subtitles)")
        XCTAssertFalse(run.sender.subtitles.dropFirst(run.subtitlesBeforeMission ?? 0).contains { $0.contains("Speedboat") },
                       "\(run.sender.subtitles)")
        let drawn = run.overlay.sent.filter { !$0.text.isEmpty }
        XCTAssertEqual(drawn.count, 1, "görev kutusu: \(run.overlay.sent.map(\.text))")
        XCTAssertFalse(drawn.contains { d in messages.contains { d.text.contains($0) } })
        XCTAssertEqual(run.overlay.sent.filter { $0.text.isEmpty }.count, 1)
    }

    /// Görev tek başına, geçmişi yokken (gta6-20-gorev) altyazı olarak çevrilmeye devam eder: yalnız görev sayılmış satır
    /// altyazıdan alınır.
    func testLoneObjectiveWithoutHistoryIsStillTheSubtitle() async throws {
        let run = try await run(Self.rep("gta6-20-gorev", 8))
        XCTAssertTrue(run.sender.subtitles.contains { $0.contains("Follow the plane") }, "\(run.sender.subtitles)")
        XCTAssertEqual(run.regions.count, 0)
    }

    /// Görev sayılmış satırın kutusu tek bir ıskada (`holdMs` dolmadan) kalkmaz; `holdMs` geçince kalkar.
    func testSettledObjectiveSurvivesAMissButNotALongAbsence() {
        var mission = MissionLine()
        let area = TextBox(left: 0, top: 0, right: 1, bottom: 1)
        let objective = [TextLine("Get in the Speedboat", box: TextBox(left: 0.45, top: 0.94, right: 0.62, bottom: 0.97))]
        var changes = 0
        for time in stride(from: 0, through: 4000, by: 250) where mission.observe(objective, area: area, at: time) { changes += 1 }
        XCTAssertNotNil(mission.region)
        XCTAssertEqual(changes, 1)
        // 2 sn ıska (eski kural 1,5 sn'de kaldırıyordu).
        for time in stride(from: 4250, through: 6250, by: 250) { XCTAssertFalse(mission.observe([], area: area, at: time)) }
        XCTAssertNotNil(mission.region)
        // Iskadan sonra dönen satır görev kutusunda kalır (altyazıya alınmaz).
        let back = mission.claim(Reading(lines: [TextLine("Lucia: Go.", box: TextBox(left: 0.4, top: 0.85, right: 0.6, bottom: 0.9))]
                                         + [TextLine("Get in the speedbat", box: TextBox(left: 0.45, top: 0.941, right: 0.62, bottom: 0.971))]),
                                 area: area)
        XCTAssertEqual(back.kept.lines.map(\.text), ["Lucia: Go."])
        XCTAssertEqual(back.claimed.map(\.text), ["Get in the speedbat"])
        XCTAssertFalse(mission.observe(back.claimed, area: area, at: 6500))
        // Görev gerçekten kalkınca `holdMs` sonra kutu kalkar.
        XCTAssertFalse(mission.observe([], area: area, at: 6500 + MissionLine.holdMs))
        XCTAssertTrue(mission.observe([], area: area, at: 6750 + MissionLine.holdMs))
        XCTAssertNil(mission.region)
    }
}
#endif
