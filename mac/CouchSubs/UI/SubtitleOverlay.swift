// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import Combine
import SwiftUI

/// Bilgisayar ekranındaki altyazı penceresi: kenarsız, her pencerenin (tam ekran uygulamalar dahil) üstünde, saydam
/// zeminli bir panel. Odağı almaz; "Tıklamalar geçsin" açıkken fare alttaki pencereye (oyun, PS Remote Play) gider.
/// Satırlar TV uygulamasıyla aynı yığından gelir (bkz. AppModel+ComputerScreen.swift). Yeri, genişliği ve ekranı
/// macOS'un pencere kaydıyla hatırlanır.
@MainActor
final class SubtitleOverlayController {
    private weak var model: AppModel?
    private var panel: OverlayPanel?
    private let geometry = OverlayGeometry()
    private var moveStart: (mouse: NSPoint, frame: NSRect)?
    private var screenObserver: NSObjectProtocol?
    private var modelChanges: AnyCancellable?
    /// Pencereyi etkileyen son durum; model her değiştiğinde (ör. yeni satır) pencere boşuna yeniden ölçülmesin.
    private var shown: Shown?

    private struct Shown: Equatable {
        let visible: Bool
        let ignoresMouse: Bool
        let adjusting: Bool
        let fontSize: Int
    }

    static let autosaveName = "CouchSubsSubtitleWindow"
    static let minWidth: CGFloat = 320

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        update()
        // Modeldeki görünürlük, tıklama ve yazı boyu değişince pencere güncellenir. objectWillChange değişiklikten önce
        // gelir; güncelleme bir sonraki turda yeni değerlerle yapılır.
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        }
    }

    private func update() {
        guard let model else { return }
        let visible = model.overlayVisible
        let ignoresMouse = model.overlayIgnoresMouse
        let fontSize = model.settings.style.fontSize
        let state = Shown(visible: visible, ignoresMouse: ignoresMouse, adjusting: model.overlayAdjusting, fontSize: fontSize)
        guard state != shown else { return }
        shown = state
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel(model)
        panel.ignoresMouseEvents = ignoresMouse
        panel.adjusting = model.overlayAdjusting
        fit(panel, fontSize: fontSize)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel(_ model: AppModel) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        // Tüm masaüstlerinde ve tam ekran uygulamaların (PS Remote Play, oyun) üstünde görünür.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let content = SubtitleOverlayView(geometry: geometry, actions: OverlayActions(
            move: { [weak self] in self?.move() },
            resize: { [weak self] edge in self?.resize(edge) },
            endMove: { [weak self] in self?.moveStart = nil }))
            .environmentObject(model)
        let host = FirstMouseHostingView(rootView: content)
        // Pencerenin boyunu içerik değil kullanıcı (ve yazı boyu) belirler.
        host.sizingOptions = []
        panel.contentView = host
        if !panel.setFrameUsingName(Self.autosaveName) || !Self.isOnScreen(panel.frame) {
            panel.setFrame(Self.defaultFrame(), display: false)
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model, let panel = self.panel else { return }
                self.fit(panel, fontSize: model.settings.style.fontSize)
            }
        }
        self.panel = panel
        return panel
    }

    /// Yazı boyu TV'deki gibi 1080 satırlık ekrana göredir; pencerenin bulunduğu ekranın yüksekliğine ölçeklenir.
    /// Pencere en çok üç satıra (ve satırların kaymasına) yetecek kadar yüksektir; alt kenarı sabit kalır.
    private func fit(_ panel: NSPanel, fontSize: Int) {
        let screen = panel.screen ?? NSScreen.main
        let scale = (screen?.frame.height ?? 1080) / 1080
        if geometry.scale != scale { geometry.scale = scale }
        let font = CGFloat(fontSize) * scale
        let height = (font * 8.1 + 140 * scale).rounded()
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// Sürüklemenin başındaki fare yeri ve pencere çerçevesi.
    private func dragStart() -> (mouse: NSPoint, frame: NSRect)? {
        guard let panel else { return nil }
        if moveStart == nil { moveStart = (NSEvent.mouseLocation, panel.frame) }
        return moveStart
    }

    /// Fare imlecinin ekrandaki yeriyle taşınır; ekranlar arasında da çalışır.
    private func move() {
        guard let panel, let start = dragStart() else { return }
        let mouse = NSEvent.mouseLocation
        var frame = start.frame
        frame.origin.x += mouse.x - start.mouse.x
        frame.origin.y += mouse.y - start.mouse.y
        panel.setFrame(frame, display: true)
    }

    /// Kenardan genişletme: ortası yerinde kalır, iki yana eşit büyür.
    private func resize(_ edge: HorizontalEdge) {
        guard let panel, let start = dragStart() else { return }
        let delta = NSEvent.mouseLocation.x - start.mouse.x
        let grow = edge == .trailing ? delta : -delta
        let screenWidth = panel.screen?.frame.width ?? start.frame.width
        let width = min(screenWidth, max(Self.minWidth, start.frame.width + 2 * grow))
        var frame = start.frame
        frame.origin.x = start.frame.midX - width / 2
        frame.size.width = width
        panel.setFrame(frame, display: true)
    }

    /// İlk açılışta ana ekranın altında, ortada, ekranın %70'i genişliğinde.
    private static func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = (screen.width * 0.7).rounded()
        return NSRect(x: screen.midX - width / 2, y: screen.minY + screen.height * 0.04, width: width, height: 400)
    }

    /// Kayıtlı yer artık bağlı olmayan bir ekrandaysa pencere ana ekrana döner.
    private static func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(frame) }
    }
}

/// Yazı ölçeği (pencerenin bulunduğu ekrana göre).
@MainActor
final class OverlayGeometry: ObservableObject {
    @Published var scale: CGFloat = 1
}

struct OverlayActions {
    let move: () -> Void
    let resize: (HorizontalEdge) -> Void
    let endMove: () -> Void
}

/// Odağı yalnız yeri ayarlanırken alabilen panel; oyun ya da PS Remote Play klavyeyi kaybetmez.
final class OverlayPanel: NSPanel {
    var adjusting = false

    override var canBecomeKey: Bool { adjusting }
    override var canBecomeMain: Bool { false }
}

/// Öndeki uygulama değişmeden ilk tıklama da (taşıma, "Bitti") çalışsın.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pencerenin içeriği: TV'deki altyazı kutusunun aynısı (yazı boyu, renk, zemin, soluk üst satırlar).
struct SubtitleOverlayView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var geometry: OverlayGeometry
    let actions: OverlayActions

    private var scale: CGFloat { geometry.scale }

    var body: some View {
        let adjusting = model.overlayAdjusting
        let lines = model.overlayLines
        ZStack(alignment: .bottom) {
            if adjusting {
                RoundedRectangle(cornerRadius: Theme.radius("card"))
                    .fill(Color.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius("card"))
                        .strokeBorder(Color.csAccent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                    .gesture(moveGesture)
                adjustBar
                resizeHandles
            }
            VStack(spacing: 14 * scale) {
                Spacer(minLength: 0)
                if lines.isEmpty, adjusting {
                    line(SubtitleStack.Line(id: 0, text: String(localized: "Subtitles appear here."), role: .current,
                                            paragraphs: false, fading: false))
                }
                ForEach(lines) { line($0) }
            }
            .padding(.horizontal, 24 * scale)
            .padding(.bottom, 8 * scale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in actions.move() }
            .onEnded { _ in actions.endMove() }
    }

    private func resizeGesture(_ edge: HorizontalEdge) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { _ in actions.resize(edge) }
            .onEnded { _ in actions.endMove() }
    }

    private var adjustBar: some View {
        VStack {
            HStack(spacing: Theme.space("m")) {
                Text("Drag to move, drag the edges to resize.")
                    .font(.csCallout.weight(.semibold))
                    .foregroundStyle(.white)
                Button("Done") { model.overlayAdjusting = false }
                    .buttonStyle(.primary)
            }
            .padding(Theme.space("m"))
            Spacer()
        }
    }

    private var resizeHandles: some View {
        HStack {
            handle(.leading)
            Spacer()
            handle(.trailing)
        }
    }

    private func handle(_ edge: HorizontalEdge) -> some View {
        Capsule()
            .fill(Color.csAccent)
            .frame(width: 6, height: 48)
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(resizeGesture(edge))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func line(_ line: SubtitleStack.Line) -> some View {
        let style = model.settings.style
        let current = line.role == .current
        let size = CGFloat(style.fontSize) * scale * (current ? 1 : 0.8)
        let alpha = Double(max(0, min(100, style.background))) / 100 * (current ? 1 : 0.83)
        let opacity: Double = switch line.role {
        case .current: 1
        case .previous: 0.6
        case .older: 0.45
        }
        // Derleyici uzun zincirde tür çıkarımında takılmasın diye değerler önce hesaplanır (CI'daki Xcode).
        let weight: Font.Weight = style.bold ? .bold : .semibold
        let alignment: TextAlignment = line.paragraphs ? .leading : .center
        let shadowRadius: CGFloat = 2 * scale
        let vertical: CGFloat = (current ? 10 : 6) * scale
        let horizontal: CGFloat = (current ? 26 : 20) * scale
        let corner: CGFloat = 10 * scale
        let shown: Double = line.fading ? 0 : opacity
        let text = Text(verbatim: line.text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(Self.color(style.textColor))
        return text
            .multilineTextAlignment(alignment)
            .lineSpacing(size * 0.3)
            .shadow(color: .black, radius: shadowRadius, x: 0, y: shadowRadius)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, vertical)
            .padding(.horizontal, horizontal)
            .background(Color.black.opacity(alpha), in: RoundedRectangle(cornerRadius: corner))
            .opacity(shown)
            .animation(.linear(duration: SubtitleStack.previousFade), value: line.fading)
            .contentShape(Rectangle())
            .gesture(moveGesture)
    }

    /// TV uygulamasındaki renklerle aynı (beyaz, #FFE135).
    static func color(_ color: SubtitleTextColor) -> Color {
        switch color {
        case .white: .white
        case .yellow: Color(red: 1, green: 0xE1 / 255, blue: 0x35 / 255)
        }
    }
}
