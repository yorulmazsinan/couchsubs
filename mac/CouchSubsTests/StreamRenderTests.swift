// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI
import XCTest
@testable import CouchSubs

/// Yayın penceresinin ekran yazısı çizimini gerçek bir karenin üstüne görüntü olarak döker (yalnız yerel:
/// `COUCHSUBS_REAL_FRAMES` dizininde `kareler/K1.png` ve hattın olayları `cikti/mac/K1.json`; çıktı `cikti/mac/K1-mac.png`).
/// Kareler ve çıktılar depoya girmez.
@MainActor
final class StreamRenderTests: XCTestCase {
    func testRenderScreenTextOnARealFrame() throws {
        guard let path = ProcessInfo.processInfo.environment["COUCHSUBS_REAL_FRAMES"] else { throw XCTSkip("COUCHSUBS_REAL_FRAMES verilmedi") }
        let root = URL(fileURLWithPath: path)
        guard let frame = NSImage(contentsOf: root.appendingPathComponent("kareler/K1.png")),
              let data = try? Data(contentsOf: root.appendingPathComponent("cikti/mac/K1.json")),
              let events = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw XCTSkip("K1 yok") }
        var items: [ScreenTranslation.Item] = []
        for event in events {
            guard let data = event["data"] as? [String: Any], let blocks = data["blocks"] as? [[String: Any]] else { continue }
            items.removeAll { item in blocks.contains { ($0["text"] as? String) == item.translation } }
            for block in blocks {
                guard let box = block["box"] as? [String: Double], let text = block["text"] as? String else { continue }
                var item = ScreenTranslation.Item(source: text, translation: text,
                                                  box: TextBox(left: box["left"]!, top: box["top"]!, right: box["right"]!, bottom: box["bottom"]!),
                                                  lineHeight: (block["line"] as? Double) ?? 0.03)
                if let surface = block["surface"] as? [String: Any] {
                    item.style = PhoneTextStyle(background: surface["background"] as? String ?? "#000000",
                                                foreground: surface["foreground"] as? String ?? "#FFFFFF")
                    if let style = block["style"] as? [String: Any] {
                        item.look = TextLook(bold: style["bold"] as? Bool ?? false, condensed: style["condensed"] as? Bool ?? false,
                                             align: TextLook.Align(rawValue: style["align"] as? String ?? "left") ?? .left,
                                             upper: style["upper"] as? Bool ?? false, flat: surface["flat"] as? Bool ?? true)
                    }
                }
                items.append(item)
            }
        }
        let width: CGFloat = 1280
        let height = width * frame.size.height / frame.size.width
        // Çakışma denemesi: altyazı kutusu sağ alttaki tuş çubuğunun üst kısmına binsin; ekran yazısı kutuları kaymalı.
        let subtitle = CGRect(x: width * 0.55, y: height * 0.70, width: width * 0.4, height: height * 0.06)
        let view = ZStack(alignment: .topLeading) {
            Image(nsImage: frame).resizable().frame(width: width, height: height)
            ScreenTextBlocks(items: items, avoiding: subtitle)
            Text(verbatim: "Altyazı burada durur")
                .font(.system(size: subtitle.height * 0.5, weight: .semibold)).foregroundStyle(.white)
                .frame(width: subtitle.width, height: subtitle.height)
                .background(Color.black.opacity(0.75))
                .offset(x: subtitle.minX, y: subtitle.minY)
        }
        .frame(width: width, height: height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("cikti/mac/K1-mac.png"))
    }
}
