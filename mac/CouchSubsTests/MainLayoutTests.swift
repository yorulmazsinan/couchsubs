// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import RemotePlay
import SwiftUI
import XCTest
@testable import CouchSubs

/// Ana ekranın sol sütunu hiçbir durumda kendi genişliğinden taşmaz (taşınca karolar sağ sütuna dayanıyor,
/// kenarları kesiliyordu).
@MainActor
final class MainLayoutTests: XCTestCase {
    private func model(output: SubtitleOutput, running: Bool, clickThrough: Bool) -> AppModel {
        let store = MemoryStore()
        store.save(Data(repeating: 1, count: 8), for: StoreKey.accountId)
        store.save(RegisteredConsole(host: "192.168.1.253", name: "PS5-789", registKey: Data(repeating: 0x31, count: 16),
                                     morning: Data(repeating: 2, count: 16)), for: StoreKey.console)
        store.save(LGTV(name: "LG TV", host: "192.168.1.153"), for: StoreKey.tv)
        store.save("tv-key", for: StoreKey.tvKey)
        let model = AppModel(services: FakeServices(), store: store, defaults: .isolated())
        model.step = .done
        model.settings.output = output
        model.settings.overlayClickThrough = clickThrough
        model.isRunning = running
        return model
    }

    private var states: [(SubtitleOutput, Bool, Bool)] {
        SubtitleOutput.allCases.flatMap { output in [false, true].flatMap { running in [false, true].map { (output, running, $0) } } }
    }

    /// Sütunun en dar hâlinde de içerik sığar: yazılar satıra iner, hiçbir öğe sütundan geniş en az genişlik istemez.
    func testControlsFitTheNarrowestColumn() {
        for (output, running, click) in states {
            let model = model(output: output, running: running, clickThrough: click)
            for width in [MainView.controlsColumnMin, Theme.size("mainColumn")] {
                let host = NSHostingController(rootView: MainControls().environmentObject(model).appSurface())
                let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
                XCTAssertLessThanOrEqual(size.width, width, "\(output) çalışıyor=\(running) tıklama=\(click) sütun=\(width)")
            }
        }
    }

    /// Kaydırma alanı içeriğe genişlik önermese de (ideal ölçü) sütun kendi genişliğinde kalır. İçeriğin ideal
    /// genişliği sütundan geniştir; sütun genişliği sabitlenmeseydi taşardı.
    func testColumnKeepsItsWidthWhenMeasuredAtIdealSize() {
        let width = Theme.size("mainColumn")
        for (output, running, click) in states {
            let model = model(output: output, running: running, clickThrough: click)
            let ideal = NSHostingView(rootView: MainControls().environmentObject(model).appSurface()).fittingSize.width
            XCTAssertGreaterThan(ideal, width, "\(output): içeriğin ideal genişliği sütundan dar; test anlamını yitirdi")
            let column = NSHostingView(rootView: ControlsColumn(width: width).environmentObject(model).appSurface())
            XCTAssertEqual(column.fittingSize.width, width, "\(output) çalışıyor=\(running) tıklama=\(click)")
            let documents = laidOutScrollContent(column, width: width)
            XCTAssertFalse(documents.isEmpty)
            for document in documents {
                XCTAssertLessThanOrEqual(document, width, "\(output) çalışıyor=\(running) tıklama=\(click)")
            }
            print("MainLayoutTests: \(output) kaydırma içeriği \(documents) / sütun \(width), ideal \(ideal)")
        }
    }

    /// Görünümü pencerede yerleştirir; kaydırma alanlarının içerik (belge) genişliklerini verir.
    private func laidOutScrollContent(_ view: NSView, width: CGFloat) -> [CGFloat] {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        _ = view.fittingSize
        view.layoutSubtreeIfNeeded()
        defer { window.close() }
        return scrollViews(in: view).compactMap { $0.documentView?.frame.width }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
