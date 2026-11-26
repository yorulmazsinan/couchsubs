// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// Yerinde birebir çizim: göndericinin kareden ölçtükleri (`TextPainter`: örtü kutusu, zemin/degrade/desen, boş alan,
/// grup) ve çizicilerin ortak yerleşimi (`ScreenFit.exact`). Ortak deneme dosyası Fixtures/text-paint.json (Windows
/// TextPaintTests.cs, Android TextPaintTest.kt ve TV scripts/tv-exact-fit.test.js aynı vakalar).
final class TextPaintTests: XCTestCase {
    struct Fixture: Decodable {
        struct Background: Decodable { let kind: String; let from: String; let to: String?; let cell: Int? }
        struct Rect: Decodable { let box: [Int]; let color: String; let radius: Int?; let tail: String? }
        struct Target: Decodable {
            let box: [Double]; let line: Double; let rows: Int; let bg: String; let fg: String; let upper: Bool; let align: String
            let words: Int?; let kind: String?; let prompt: Bool?
        }
        struct Expect: Decodable {
            let cover: [Double]?; let bg: String?; let bg2: String??; let bgDir: String?; let patterned: Bool?
            let grow: [Double]??; let group: Int??; let pitch: Double?; let side: String??

            enum CodingKeys: String, CodingKey { case cover, bg, bg2, bgDir, patterned, grow, group, pitch, side }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                cover = try c.decodeIfPresent([Double].self, forKey: .cover)
                bg = try c.decodeIfPresent(String.self, forKey: .bg)
                bg2 = c.contains(.bg2) ? .some(try c.decodeIfPresent(String.self, forKey: .bg2)) : nil
                bgDir = try c.decodeIfPresent(String.self, forKey: .bgDir)
                patterned = try c.decodeIfPresent(Bool.self, forKey: .patterned)
                grow = c.contains(.grow) ? .some(try c.decodeIfPresent([Double].self, forKey: .grow)) : nil
                group = c.contains(.group) ? .some(try c.decodeIfPresent(Int.self, forKey: .group)) : nil
                pitch = try c.decodeIfPresent(Double.self, forKey: .pitch)
                side = c.contains(.side) ? .some(try c.decodeIfPresent(String.self, forKey: .side)) : nil
            }
        }
        struct Paint: Decodable {
            let id: String; let width: Int; let height: Int; let background: Background; let rects: [Rect]
            let targets: [Target]; let expect: [Expect]
        }
        struct ModeExpect: Decodable {
            let mode: String; let spot: [Double]?; let room: [Double]?; let twin: [Double]?; let radius: Double?
            let scale: Double?; let tail: String?; let portrait: [Double]?; let portraitTwin: [Double]?
            let edge: [Double]?
        }
        struct ModePaint: Decodable {
            let id: String; let width: Int; let height: Int; let background: Background; let rects: [Rect]
            let targets: [Target]; let expect: [ModeExpect]
            /// Verilirse: ikiz özgün yazıyı her yanda en çok bu kadar satır aşar, yanına yazılan Türkçenin yeri özgünün
            /// satır yüksekliğinde ve genişliğinde, Türkçeler birbirine binmez (tuş çubuğu, beta.103).
            let hug: Double?
        }
        struct ExactItem: Decodable {
            let text: String; let box: [Double]; let grow: [Double]?; let line: Double; let pitch: Double?; let rows: Int?
            let align: String; let group: Int?
        }
        struct Placement: Decodable {
            let left: Double; let top: Double; let width: Double; let height: Double; let fontSize: Double; let lines: [String]
            let lineHeight: Double; let rowHeight: Double
        }
        struct Exact: Decodable { let id: String; let charWidth: Double; let items: [ExactItem]; let expect: [Placement]? }
        let paint: [Paint]
        let exact: [Exact]
        let modes: [ModePaint]
    }

    static func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/text-paint.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Yapay karenin noktası: zemin, üstüne sırayla çizilen dikdörtgenler.
    static func pixel(_ frame: Fixture.Paint, _ x: Int, _ y: Int) -> TextPainter.RGB {
        pixel(rects: frame.rects, background: frame.background, width: frame.width, height: frame.height, x, y)
    }

    /// Yuvarlak köşeli dikdörtgen: köşe karesindeki nokta, merkezi köşe dairesinin içindeyse boyanır; `tail` köşesi köşeli.
    static func inside(_ rect: Fixture.Rect, _ x: Int, _ y: Int) -> Bool {
        let b = rect.box
        guard x >= b[0] && x < b[2] && y >= b[1] && y < b[3] else { return false }
        guard let r = rect.radius, r > 0 else { return true }
        let px = Double(x) + 0.5, py = Double(y) + 0.5, rr = Double(r)
        let left = px < Double(b[0]) + rr, right = px > Double(b[2]) - rr
        let top = py < Double(b[1]) + rr, bottom = py > Double(b[3]) - rr
        guard (left || right) && (top || bottom) else { return true }
        if bottom && ((left && rect.tail == "left") || (right && rect.tail == "right")) { return true }
        let cx = left ? Double(b[0]) + rr : Double(b[2]) - rr, cy = top ? Double(b[1]) + rr : Double(b[3]) - rr
        return (px - cx) * (px - cx) + (py - cy) * (py - cy) <= rr * rr
    }

    static func pixel(rects: [Fixture.Rect], background: Fixture.Background, width: Int, height: Int, _ x: Int, _ y: Int)
        -> TextPainter.RGB {
        for rect in rects.reversed() where inside(rect, x, y) { return TextPainter.rgb(rect.color) }
        let frame = (background: background, width: width, height: height)
        let from = TextPainter.rgb(frame.background.from), to = TextPainter.rgb(frame.background.to ?? frame.background.from)
        func mix(_ f: Double) -> TextPainter.RGB {
            (Int((Double(from.r) + Double(to.r - from.r) * f).rounded()), Int((Double(from.g) + Double(to.g - from.g) * f).rounded()),
             Int((Double(from.b) + Double(to.b - from.b) * f).rounded()))
        }
        switch frame.background.kind {
        case "h": return mix(Double(x) / Double(frame.width - 1))
        case "v": return mix(Double(y) / Double(frame.height - 1))
        case "checker":
            let cell = frame.background.cell ?? 6
            return (x / cell + y / cell) % 2 == 0 ? from : to
        default: return from
        }
    }

    static func align(_ text: String) -> TextLook.Align { TextLook.Align(rawValue: text) ?? .left }

    /// Renkler kanal başına en çok 4 farklı.
    static func near(_ a: String, _ b: String) -> Bool { TextPainter.distance(TextPainter.rgb(a), TextPainter.rgb(b)) <= 4 }

    func testSharedPaintVectors() throws {
        for frame in try Self.fixture().paint {
            let w = Double(frame.width), h = Double(frame.height)
            let targets = frame.targets.map { t in
                TextPainter.Target(box: TextBox(left: t.box[0] / w, top: t.box[1] / h, right: t.box[2] / w, bottom: t.box[3] / h),
                                   lineHeight: t.line / h, rows: t.rows, background: t.bg, foreground: t.fg, upper: t.upper,
                                   align: Self.align(t.align), words: t.words ?? 0)
            }
            let paints = TextPainter.paints(targets, width: frame.width, height: frame.height) { Self.pixel(frame, $0, $1) }
            XCTAssertEqual(paints.count, frame.expect.count, frame.id)
            for (k, expect) in frame.expect.enumerated() where k < paints.count {
                let paint = paints[k], name = "\(frame.id)#\(k)"
                if let cover = expect.cover {
                    let got = [paint.cover.left * w, paint.cover.top * h, paint.cover.right * w, paint.cover.bottom * h]
                    for (a, b) in zip(got, cover) { XCTAssertEqual(a, b, accuracy: 1.01, "\(name) örtü \(got)") }
                }
                if let bg = expect.bg { XCTAssertTrue(Self.near(paint.background, bg), "\(name) zemin \(paint.background) ≠ \(bg)") }
                if let bg2 = expect.bg2 {
                    if let bg2 { XCTAssertTrue(paint.background2.map { Self.near($0, bg2) } ?? false, "\(name) bg2 \(String(describing: paint.background2))") }
                    else { XCTAssertNil(paint.background2, name) }
                }
                if let direction = expect.bgDir { XCTAssertEqual(paint.direction?.rawValue, direction, name) }
                if let patterned = expect.patterned { XCTAssertEqual(paint.patterned, patterned, name) }
                if let grow = expect.grow {
                    if let grow {
                        XCTAssertNotNil(paint.grow, name)
                        XCTAssertEqual((paint.grow?.left ?? -1) * w, grow[0], accuracy: 1.01, "\(name) uzama solu")
                        XCTAssertEqual((paint.grow?.right ?? -1) * w, grow[1], accuracy: 1.01, "\(name) uzama sağı")
                    } else { XCTAssertNil(paint.grow, name) }
                }
                if let group = expect.group { XCTAssertEqual(paint.group, group, name) }
                if let pitch = expect.pitch { XCTAssertEqual(paint.pitch * h, pitch, accuracy: 0.5, name) }
                if let side = expect.side { XCTAssertEqual(paint.iconSide?.rawValue, side, "\(name) simge yanı") }
            }
        }
    }

    /// Çizim kipi (`TextPaint.mode`): desenli zeminde yanına yazma (önce sol, yer yoksa sağ), simge örtülmez, köşeli düz
    /// kutu örtülür, yuvarlak panel küçük ikizle (resim, kuyruk) üstte ya da altta, yer yoksa örtme; menü ve türsüz yazı
    /// hep örtülür. Ortak vakalar Fixtures/text-paint.json → modes (Windows, Android aynı).
    func testSharedModeVectors() throws {
        var out: [String: Any] = [:]
        for frame in try Self.fixture().modes {
            let w = Double(frame.width), h = Double(frame.height)
            let targets = frame.targets.map { t in
                TextPainter.Target(box: TextBox(left: t.box[0] / w, top: t.box[1] / h, right: t.box[2] / w, bottom: t.box[3] / h),
                                   lineHeight: t.line / h, rows: t.rows, background: t.bg, foreground: t.fg, upper: t.upper,
                                   align: Self.align(t.align), words: t.words ?? 0,
                                   kind: t.kind.flatMap(ScreenTextKind.init(rawValue:)), prompt: t.prompt ?? false)
            }
            let paints = TextPainter.paints(targets, width: frame.width, height: frame.height) { x, y in
                Self.pixel(rects: frame.rects, background: frame.background, width: frame.width, height: frame.height, x, y)
            }
            func px(_ b: TextBox?) -> [Double]? {
                b.map { [($0.left * w * 100).rounded() / 100, ($0.top * h * 100).rounded() / 100,
                         ($0.right * w * 100).rounded() / 100, ($0.bottom * h * 100).rounded() / 100] }
            }
            out[frame.id] = paints.map { p -> [String: Any] in
                var e: [String: Any] = ["mode": p.mode.rawValue]
                if let spot = px(p.spot) { e["spot"] = spot }
                if let room = px(p.spotRoom) { e["room"] = [room[0], room[2]] }
                if let twin = px(p.twin) {
                    e["twin"] = twin
                    e["radius"] = (p.radius * h * 100).rounded() / 100
                    e["scale"] = p.scale
                    e["tail"] = p.tail ?? NSNull()
                    e["portrait"] = px(p.portrait) ?? NSNull()
                    if let face = px(p.portraitTwin) { e["portraitTwin"] = face }
                    if let edge = p.edge { e["edge"] = [edge.top * h, edge.right * h, edge.bottom * h, edge.left * h].map { ($0 * 100).rounded() / 100 } }
                }
                return e
            }
            XCTAssertEqual(paints.count, frame.expect.count, frame.id)
            for (k, (paint, e)) in zip(paints, frame.expect).enumerated() {
                let name = "\(frame.id)#\(k)"
                XCTAssertEqual(paint.mode.rawValue, e.mode, name)
                func near(_ got: [Double]?, _ want: [Double]?, _ what: String, _ tolerance: Double = 1.01) {
                    guard let want else { return }
                    guard let got, got.count == want.count else { return XCTFail("\(name) \(what) yok") }
                    for (a, b) in zip(got, want) { XCTAssertEqual(a, b, accuracy: tolerance, "\(name) \(what) \(got)") }
                }
                near(px(paint.spot), e.spot, "spot")
                near(px(paint.spotRoom).map { [$0[0], $0[2]] }, e.room, "room")
                near(px(paint.twin), e.twin, "twin")
                if let radius = e.radius { XCTAssertEqual(paint.radius * h, radius, accuracy: 1.5, "\(name) radius") }
                if let scale = e.scale { XCTAssertEqual(paint.scale, scale, accuracy: 0.001, name) }
                if e.twin != nil { XCTAssertEqual(paint.tail, e.tail, "\(name) kuyruk") }
                if e.twin != nil, e.portrait == nil { XCTAssertNil(paint.portrait, "\(name) resim") }
                near(px(paint.portrait), e.portrait, "portrait")
                near(px(paint.portraitTwin), e.portraitTwin, "portraitTwin")
                near(paint.edge.map { [$0.top * h, $0.right * h, $0.bottom * h, $0.left * h] }, e.edge, "edge", 0.51)
                if let hug = frame.hug {
                    let t = frame.targets[k], pad = hug * t.line
                    if let twin = paint.twin {
                        XCTAssertTrue(twin.right * w - twin.left * w <= t.box[2] - t.box[0] + 2 * pad
                                      && twin.bottom * h - twin.top * h <= t.box[3] - t.box[1] + 2 * pad, "\(name) dev ikiz \(px(twin)!)")
                    }
                    if let spot = paint.spot, paint.mode == .beside {
                        let cover = paint.cover
                        XCTAssertEqual(spot.bottom * h - spot.top * h, cover.bottom * h - cover.top * h, accuracy: 0.5, "\(name) satır yüksekliği")
                        XCTAssertLessThanOrEqual(spot.bottom * h - spot.top * h, t.box[3] - t.box[1] + 2.0 * Double(TextPainter.marginMax), name)
                        XCTAssertEqual(spot.right * w - spot.left * w, cover.right * w - cover.left * w, accuracy: 0.5, "\(name) genişlik")
                        for (j, other) in paints.enumerated() where j > k && other.mode == .beside {
                            guard let o = other.spot else { continue }
                            XCTAssertFalse(min(o.right, spot.right) > max(o.left, spot.left) && min(o.bottom, spot.bottom) > max(o.top, spot.top),
                                           "\(name) ile #\(j) binişiyor")
                        }
                    }
                }
                // Örtmeyen kipte Türkçe özgün yazıya (ve kutunun ucundaki simgeye) binmez; ikiz özgün paneli örtmez.
                if paint.mode != .cover, let room = paint.spotRoom {
                    let target = frame.targets[k].box
                    XCTAssertFalse(room.right * w > target[0] + 0.5 && room.left * w < target[2] - 0.5
                                   && room.bottom * h > target[1] + 0.5 && room.top * h < target[3] - 0.5, "\(name) özgüne biner")
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["TEXT_PAINT_MODES_OUT"] {
            try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }

    static func exactInputs(_ vector: Fixture.Exact) -> [ScreenFit.ExactInput] {
        vector.items.map { item in
            ScreenFit.ExactInput(text: item.text, left: item.box[0], top: item.box[1], right: item.box[2], bottom: item.box[3],
                                 growLeft: item.grow?[0], growRight: item.grow?[1], line: item.line, pitch: item.pitch,
                                 rows: item.rows ?? 1, align: align(item.align), group: item.group)
        }
    }

    func testSharedExactVectors() throws {
        var out: [[String: Any]] = []
        for vector in try Self.fixture().exact {
            let placed = ScreenFit.exact(Self.exactInputs(vector)) { text, size in Double(text.count) * vector.charWidth * size }
            out.append(["id": vector.id, "expect": placed.map { p -> [String: Any] in
                ["left": round(p.left * 100) / 100, "top": round(p.top * 100) / 100, "width": round(p.width * 100) / 100,
                 "height": round(p.height * 100) / 100, "fontSize": round(p.fontSize * 100) / 100, "lines": p.lines,
                 "lineHeight": round(p.lineHeight * 100) / 100, "rowHeight": round(p.rowHeight * 100) / 100]
            }])
            guard let expect = vector.expect else { continue }
            XCTAssertEqual(placed.count, expect.count, vector.id)
            for (p, e) in zip(placed, expect) {
                let name = "\(vector.id) \(e.lines)"
                XCTAssertEqual(p.lines, e.lines, name)
                XCTAssertEqual(p.left, e.left, accuracy: 0.05, name)
                XCTAssertEqual(p.top, e.top, accuracy: 0.05, name)
                XCTAssertEqual(p.width, e.width, accuracy: 0.05, name)
                XCTAssertEqual(p.height, e.height, accuracy: 0.05, name)
                XCTAssertEqual(p.fontSize, e.fontSize, accuracy: 0.05, name)
                XCTAssertEqual(p.lineHeight, e.lineHeight, accuracy: 0.05, name)
                XCTAssertEqual(p.rowHeight, e.rowHeight, accuracy: 0.05, name)
            }
        }
        if ProcessInfo.processInfo.environment["TEXT_PAINT_OUT"] != nil {
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        }
    }

    /// Kurallar ortak dosyadan bağımsız da: grup içinde yazı boyu eşit, uzun çeviri boş alana uzar, kutu simgeye/ekran
    /// kenarına taşmaz, yazı kesilmez.
    func testGroupKeepsOneSizeAndGrowsIntoFreeSide() throws {
        let vector = try XCTUnwrap(Self.fixture().exact.first { $0.id == "grup-esit-boy-bos-alana-uzar" })
        let inputs = Self.exactInputs(vector)
        let placed = ScreenFit.exact(inputs) { text, size in Double(text.count) * vector.charWidth * size }
        XCTAssertEqual(Set(placed.map { ($0.fontSize * 100).rounded() }).count, 1, "grubun yazı boyu tek")
        for (input, p) in zip(inputs, placed) {
            XCTAssertEqual(p.lines.joined(separator: " "), input.text, "yazı kesilmez")
            XCTAssertEqual(p.left + p.width, input.right, accuracy: 0.01, "sağ kenar (simge tarafı) yerinde")
            XCTAssertGreaterThanOrEqual(p.left, input.growLeft - 0.01, "boş alanın dışına taşmaz")
            XCTAssertEqual(p.lines.count, 1, "boş alan varken satır kırılmaz")
        }
        // "HEDEF BELİRLE" kendi kutusundan uzun: boş sol tarafa uzar, yazı boyu küçülmez.
        XCTAssertLessThan(placed[3].left, inputs[3].left)
        XCTAssertEqual(placed[3].fontSize, ScreenFit.exactFont * 20, accuracy: 0.01)
    }

    func testWholeGroupShrinksTogetherWhenNoRoom() throws {
        let vector = try XCTUnwrap(Self.fixture().exact.first { $0.id == "bos-alan-yok-grup-birlikte-kuculur" })
        let inputs = Self.exactInputs(vector)
        let placed = ScreenFit.exact(inputs) { text, size in Double(text.count) * vector.charWidth * size }
        XCTAssertEqual(Set(placed.map { ($0.fontSize * 100).rounded() }).count, 1, "grup birlikte küçülür")
        XCTAssertLessThan(placed[0].fontSize, ScreenFit.exactFont * 20)
        for (input, p) in zip(inputs, placed) {
            XCTAssertGreaterThanOrEqual(p.left, input.growLeft - 0.01)
            XCTAssertLessThanOrEqual(p.left + p.width, input.growRight + 0.01)
            XCTAssertEqual(p.lines.joined(separator: " "), input.text)
        }
    }

    /// Gerçek kare (testdata/frames/gta6-menu-harita.jpg): harita ipuçları tek grup, sağa yaslı; uzun çeviri boş sola uzar;
    /// zemin mavi degradenin rengi (koyu kutu değil); görev kartının üç satırlık açıklaması özgün satır aralığında.
    func testRealMapHints() throws {
        let url = ScreenFitTests.directory.appendingPathComponent("gta6-menu-harita.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Kayıtlı okumanın kutuları (simge kırpılmış): RECENTER, 2D VIEW, ADD MARKER, SET DESTINATION, EXIT.
        let boxes: [[Double]] = [[0.8689, 0.7194, 0.9334, 0.7544], [0.8791, 0.766, 0.9334, 0.8018],
                                 [0.8499, 0.8135, 0.9334, 0.852], [0.8268, 0.8632, 0.9334, 0.8996], [0.9055, 0.9147, 0.9334, 0.9483]]
        let targets = boxes.map { b in
            TextPainter.Target(box: TextBox(left: b[0], top: b[1], right: b[2], bottom: b[3]), lineHeight: 0.036, rows: 1,
                               background: "#0A6BEB", foreground: "#FFFFFF", upper: true, align: .right)
        }
        let paints = TextPainter.paints(targets, frame: image)
        XCTAssertEqual(paints.count, 5)
        XCTAssertEqual(Set(paints.compactMap(\.group)).count, 1, "ipuçları tek grup")
        XCTAssertTrue(paints.allSatisfy { $0.group != nil })
        for paint in paints {
            let bg = TextPainter.rgb(paint.background)
            XCTAssertGreaterThan(bg.b, 180, "zemin mavi: \(paint.background)")
            XCTAssertLessThan(bg.r, 60, "zemin mavi: \(paint.background)")
            // Simge (x ≈ 0.94) tarafına taşmaz.
            XCTAssertLessThan(paint.cover.right, 0.9405)
            XCTAssertNotNil(paint.grow, "sol taraf boş")
            XCTAssertLessThan(paint.grow!.left, paint.cover.left - 0.05)
        }
    }

    /// Kapsama: tek sözcüklük menü/ipucu etiketi kısa metin filtresine takılmaz; logo ve stilize başlık çevrilmez.
    @MainActor
    func testShortUiLabelsAreTranslatedAndTitleMarksKept() {
        func candidate(_ text: String) -> RegionWatcher.Candidate {
            RegionWatcher.Candidate(paragraphs: [text], box: nil, lineHeight: nil, key: text)
        }
        for label in ["Map", "Settings", "EXIT", "Help", "Photo Studio", "Set Destination"] {
            XCTAssertTrue(RegionWatcher.isUiLabel(candidate(label), uiCommands: true), label)
            if !label.contains(" ") { XCTAssertTrue(ScreenTextNoise.isNoise(label, menu: false), "eski filtre \(label) etiketini atıyordu") }
            XCTAssertFalse(ScreenTextNoise.isNoise(label, menu: true), label)
        }
        XCTAssertFalse(RegionWatcher.isUiLabel(candidate("Map"), uiCommands: false), "yalnız İngilizceden Türkçeye")
        XCTAssertFalse(RegionWatcher.isUiLabel(candidate("Bonus"), uiCommands: true))
        for title in ["VI", "Grand Theft Auto VI", "GRAND THEFT AUTO", "GTA VI", "Rockstar Games"] {
            XCTAssertTrue(ScreenTranslation.keepsNames(title), title)
        }
        for text in ["Map", "VIEW", "Grand prize", "I told you"] { XCTAssertFalse(ScreenTranslation.keepsNames(text), text) }
    }

    /// Beta.100 (3407–3409): tek satır okunan sekme çubuğu her karede aynı çevrilir (motora gitmez); kart başlıkları ve
    /// sekme adları sözlükte; haritanın yer adı ve soluk okunan parçası çevrilmez.
    func testTabBarIsStableAndPlaceNamesKept() {
        XCTAssertEqual(UiCommands.translateLabelLoosely("JASON & LUCIA MAP BRIEF"), "JASON & LUCIA HARİTA ÖZET")
        XCTAssertEqual(UiCommands.translateLabelLoosely("JASON & LUCIA MAP BRIEF PROGRESS"), "JASON & LUCIA HARİTA ÖZET İLERLEME")
        XCTAssertEqual(UiCommands.translateLabelLoosely("MAP BRIEF"), "HARİTA ÖZET")
        XCTAssertNil(UiCommands.translateTabs("Map Brief"), "yalnız BÜYÜK HARFLİ çubuk")
        XCTAssertNil(UiCommands.translateTabs("MAP SOMETHING"), "sözlükte olmayan sözcük motora gider")
        for label in ["VEHICLES", "WEAPONS", "ANIMALS", "ADD MARKER", "Map"] { XCTAssertNotNil(UiCommands.translateLabel(label), label) }
        for place in ["Peregrine Bay", "Shoeless Keys", "Key Lento", "Gambit Bay", "ne Bay"] {
            XCTAssertTrue(ScreenTranslation.keepsNames(place), place)
        }
        for text in ["Add Marker", "Bay", "Go to the Bay", "KEY BINDINGS", "Ambient Sound"] {
            XCTAssertFalse(ScreenTranslation.keepsNames(text), text)
        }
    }

    /// Beta.100 (3385): menüdeki otomatik alanla kesişen hazır alan okunmaz (tuş listesi iki alana bölünmesin).
    @MainActor
    func testPresetYieldsToMenuArea() {
        let phone = ExtraArea(id: GameAreaPresets.phoneId, name: "Messages", region: CropRegion(top: 0.45, bottom: 0.80, left: 0.72, right: 0.99))
        var menu = ExtraArea(id: "auto-1", name: ScreenTextDetector.areaName, region: CropRegion(top: 0.70, bottom: 0.96, left: 0.80, right: 0.98), auto: true)
        XCTAssertEqual(RegionWatcher.yieldingPresets([phone, menu]).map(\.id), [phone.id, "auto-1"], "menü dışında hazır alan kalır")
        menu.menu = true
        XCTAssertEqual(RegionWatcher.yieldingPresets([phone, menu]).map(\.id), ["auto-1"])
        menu.region = CropRegion(top: 0.05, bottom: 0.12, left: 0.4, right: 0.9)
        XCTAssertEqual(RegionWatcher.yieldingPresets([phone, menu]).map(\.id), [phone.id, "auto-1"], "kesişmeyen hazır alan kalır")
    }

    /// #1268, #1270: harfi/rakamı olmayan parça (yön tuşu simgesinin "-" okunuşu, renkli nokta "•") sözcük sayılmaz; simge
    /// kutunun ucunda bulunur, kutu simgenin üstüne çizilmez.
    func testLetterlessTokensAreNotWords() {
        XCTAssertEqual(TextPainter.words("- SMASH 'N' GRABS"), 3)
        XCTAssertEqual(TextPainter.words("• Objective"), 1)
        XCTAssertEqual(TextPainter.words("+ CLUBS"), 1)
        XCTAssertEqual(TextPainter.words("Buck's Jewelry & Pawn"), 3)
        XCTAssertEqual(TextPainter.words("I Map"), 1)
        XCTAssertEqual(TextPainter.words("2D VIEW"), 2)
        XCTAssertEqual(TextPainter.words("$1,000 - $10,000"), 2)
        // Simge parçası + üç sözcük: dört parça, soldaki simge bulunur.
        let line = 20.0
        let spans: [(Int, Int)] = [(0, 20), (28, 90), (98, 112), (120, 180)]
        let found = TextPainter.iconSpans(l: 0, r: 180, line: line, words: TextPainter.words("- SMASH 'N' GRABS"),
                                          align: .left) { x in spans.contains { x >= $0.0 && x < $0.1 } }
        XCTAssertNotNil(found.left)
        XCTAssertEqual(found.textLeft, 28)
    }

    /// #1255: kare dışına taşan kutu (sol, sağ, üst, alt) boş alan taramasını sonsuz döngüye sokmaz; ölçüm biter ve
    /// kutular kareye kırpılır. Nokta okuması `GamePhonePixels.offset` gibi kenara sabitlenir; sayaç bütçeyi aşarsa
    /// (eski kodda sonsuz döngü) farklı renk döner ki deneme takılmasın, sonra bütçe aşımı hata sayılır.
    func testPaintsEndsWhenBoxOverflowsFrame() {
        let width = 200, height = 100, budget = 2_000_000
        let boxes = [
            TextBox(left: -0.08, top: 0.4, right: 0.3, bottom: 0.6),
            TextBox(left: 0.7, top: 0.4, right: 1.08, bottom: 0.6),
            TextBox(left: 0.3, top: -0.1, right: 0.6, bottom: 0.15),
            TextBox(left: 0.3, top: 0.85, right: 0.6, bottom: 1.1),
            TextBox(left: -0.2, top: -0.2, right: 1.2, bottom: 1.2),
        ]
        for box in boxes {
            var calls = 0
            let target = TextPainter.Target(box: box, lineHeight: 0.1, rows: 1, background: "#202020", foreground: "#F0F0F0",
                                            upper: false, align: .center)
            let paints = TextPainter.paints([target], width: width, height: height) { x, y in
                calls += 1
                if calls > budget { return (255, 0, 0) }
                let cx = min(width - 1, max(0, x)), cy = min(height - 1, max(0, y))
                // Kutunun ortasında yazı noktaları.
                let ink = Double(cx) / Double(width) > max(0, box.left) + 0.02 && Double(cx) / Double(width) < min(1, box.right) - 0.02
                    && cy % 4 == 0 && Double(cy) / Double(height) > max(0, box.top) && Double(cy) / Double(height) < min(1, box.bottom)
                return ink ? (240, 240, 240) : (32, 32, 32)
            }
            XCTAssertLessThanOrEqual(calls, budget, "sonsuz döngü: \(box)")
            XCTAssertEqual(paints.count, 1)
            guard let paint = paints.first else { continue }
            for b in [paint.cover] + (paint.grow.map { [$0] } ?? []) {
                XCTAssertGreaterThanOrEqual(b.left, 0, "\(box)"); XCTAssertGreaterThanOrEqual(b.top, 0, "\(box)")
                XCTAssertLessThanOrEqual(b.right, 1, "\(box)"); XCTAssertLessThanOrEqual(b.bottom, 1, "\(box)")
                XCTAssertLessThanOrEqual(b.left, b.right, "\(box)"); XCTAssertLessThanOrEqual(b.top, b.bottom, "\(box)")
            }
        }
    }
}
