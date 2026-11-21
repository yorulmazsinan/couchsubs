// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import Combine
import SwiftUI

/// Bilgisayar ekranındaki altyazı penceresi: kenarsız, her pencerenin (tam ekran uygulamalar dahil) üstünde, saydam
/// zeminli bir panel. Odağı almaz; "Tıklamalar geçsin" açıkken fare alttaki pencereye (oyun, PS Remote Play) gider.
/// Satırlar TV uygulamasıyla aynı yığından gelir (bkz. AppModel+ComputerScreen.swift). "Altyazıyı konumlandır" ile
/// sürüklenir, kenarlarından boyutlanır; çift tık, Enter ya da Bitti yeri, boyu ve ekranı kaydeder (OverlayFrameMemory),
/// Esc vazgeçer.
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

    /// Eski sürümlerin macOS pencere kaydı; yeni kayıt yoksa bir kez okunur.
    static let autosaveName = "CouchSubsSubtitleWindow"
    /// "Altyazıyı konumlandır" ile kaydedilen yer, ekran ve boy (OverlayFrameMemory, JSON).
    static let frameKey = "couchsubs.overlayFrame"
    static let minWidth: CGFloat = 320
    /// Yüksekliğin yazı boyundan hesaplanana oranı (üst ya da alt kenardan değişir).
    private var heightScale: Double = 1
    /// Düzenleme başlarken pencerenin yeri ve oranı; Esc ile buraya dönülür.
    private var editStart: (frame: NSRect, heightScale: Double)?
    private var committed = false

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        model.overlayCommit = { [weak self] in self?.commit() }
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
        let wasAdjusting = shown?.adjusting ?? false
        shown = state
        // Düzenleme kaydedilmeden kapandı (Esc, altyazı bilgisayardan kalktı): pencere eski yerine döner.
        if wasAdjusting, !state.adjusting {
            if !committed, let start = editStart, let panel {
                heightScale = start.heightScale
                panel.setFrame(start.frame, display: true)
            }
            editStart = nil
            committed = false
        }
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel(model)
        panel.ignoresMouseEvents = ignoresMouse
        panel.adjusting = model.overlayAdjusting
        fit(panel, fontSize: fontSize)
        if !panel.isVisible { panel.orderFrontRegardless() }
        if state.adjusting, !wasAdjusting {
            editStart = (panel.frame, heightScale)
            committed = false
            // Enter ve Esc için klavye bu panele gelir (uygulama öne gelmez, oyun arkada kalır).
            panel.makeKey()
        }
    }

    /// Yeni yeri, ekranı ve boyu kaydeder (Bitti, çift tık, Enter).
    private func commit() {
        guard let panel, let model else { return }
        let base = Double(baseHeight(panel, fontSize: model.settings.style.fontSize))
        if let memory = OverlayFrameMemory(frame: panel.frame, baseHeight: base, displays: Self.displays()),
           let data = try? JSONEncoder().encode(memory) {
            UserDefaults.standard.set(data, forKey: Self.frameKey)
        }
        committed = true
    }

    /// Bağlı ekranlar: kimlik (CGDirectDisplayID), ad ve çerçeve.
    private static func displays() -> [OverlayFrameMemory.Display] {
        NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return OverlayFrameMemory.Display(id: id, name: screen.localizedName, frame: screen.frame)
        }
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
            resizeHeight: { [weak self] edge in self?.resizeHeight(edge) },
            endMove: { [weak self] in self?.moveStart = nil }))
            .environmentObject(model)
        let host = FirstMouseHostingView(rootView: content)
        // Pencerenin boyunu içerik değil kullanıcı (ve yazı boyu) belirler.
        host.sizingOptions = []
        panel.contentView = host
        panel.onCommit = { [weak model] in model?.commitOverlayEdit() }
        panel.onCancel = { [weak model] in model?.overlayAdjusting = false }
        // Kayıtlı ekran bağlıysa ona göre; yoksa eski sürümün pencere kaydı; o da yoksa ana ekranın altında ortada.
        // Pencere artık her taşınışta kendiliğinden kaydedilmez: yalnız Bitti, çift tık ya da Enter kaydeder.
        let base = Double(baseHeight(panel, fontSize: model.settings.style.fontSize))
        if let data = UserDefaults.standard.data(forKey: Self.frameKey),
           let memory = try? JSONDecoder().decode(OverlayFrameMemory.self, from: data),
           let frame = memory.frame(baseHeight: base, displays: Self.displays()) {
            heightScale = OverlayFrameMemory.clampHeightScale(memory.heightScale)
            panel.setFrame(frame, display: false)
        } else if !panel.setFrameUsingName(Self.autosaveName) || !Self.isOnScreen(panel.frame) {
            panel.setFrame(Self.defaultFrame(), display: false)
        }
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
        let size = screen?.frame.size ?? CGSize(width: 1920, height: 1080)
        if geometry.screen != size { geometry.screen = size }
        let height = (baseHeight(panel, fontSize: fontSize) * CGFloat(heightScale)).rounded()
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// Yazı boyundan hesaplanan yükseklik (oran 1), pencerenin bulunduğu ekrana göre.
    private func baseHeight(_ panel: NSPanel, fontSize: Int) -> CGFloat {
        let scale = ((panel.screen ?? NSScreen.main)?.frame.height ?? 1080) / 1080
        return (CGFloat(fontSize) * scale * 8.1 + 140 * scale).rounded()
    }

    /// Üst ya da alt kenardan boy: karşı kenar yerinde kalır; oran kaydedilir, yazı boyu değişince korunur.
    private func resizeHeight(_ edge: VerticalEdge) {
        guard let panel, let model, let start = dragStart() else { return }
        let delta = NSEvent.mouseLocation.y - start.mouse.y
        let base = baseHeight(panel, fontSize: model.settings.style.fontSize)
        heightScale = OverlayFrameMemory.heightScale(height: Double(start.frame.height + (edge == .top ? delta : -delta)), baseHeight: Double(base))
        let height = (base * CGFloat(heightScale)).rounded()
        var frame = start.frame
        // macOS'ta y yukarı doğru artar: üst kenar sürüklenirken alt kenar, alt kenar sürüklenirken üst kenar sabit.
        if edge == .bottom { frame.origin.y = start.frame.maxY - height }
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

/// "Yazı kadar" örtü kutusu: en az `minimum` boyunda (oyundaki altyazı ve pay), ama genişliği pencereye sığar; taşan kutu
/// pencerenin kenarında kesilirdi (Windows: SubtitleOverlayWindow'daki `room`). Yazı kutunun ortasında kalır. `minimum` nil ise
/// kutu yazı kadardır.
struct CoverFrame: Layout {
    var minimum: CGSize?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let child = subviews.first?.sizeThatFits(proposal) ?? .zero
        guard let minimum else { return child }
        let room = proposal.width.map { $0.isFinite ? $0 : minimum.width } ?? minimum.width
        return CGSize(width: max(child.width, min(minimum.width, room)), height: max(child.height, minimum.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: proposal)
    }
}

/// Yazı ölçeği ve ekran boyu (pencerenin bulunduğu ekrana göre).
@MainActor
final class OverlayGeometry: ObservableObject {
    @Published var scale: CGFloat = 1
    /// Pencerenin bulunduğu ekranın boyu (nokta): oyundaki altyazının ekrandaki boyu buna göre hesaplanır.
    @Published var screen = CGSize(width: 1920, height: 1080)
}

struct OverlayActions {
    let move: () -> Void
    let resize: (HorizontalEdge) -> Void
    let resizeHeight: (VerticalEdge) -> Void
    let endMove: () -> Void
}

/// Odağı yalnız yeri ayarlanırken alabilen panel; oyun ya da PS Remote Play klavyeyi kaybetmez. Ayarlanırken Enter
/// kaydeder, Esc vazgeçer.
final class OverlayPanel: NSPanel {
    var adjusting = false
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { adjusting }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        guard adjusting else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: onCommit?() // Return, sayısal tuş takımındaki Enter
        case 53: onCancel?() // Esc
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if adjusting { onCancel?() } else { super.cancelOperation(sender) }
    }
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
                    // Çift tık yeni yeri kaydeder (Enter ve Bitti gibi).
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.commitOverlayEdit() })
                adjustBar
                resizeHandles
                heightHandles
            }
            VStack(spacing: 14 * scale) {
                // Kendiliğinden bulunan ekran yazıları (items) saydam pencerede gösterilmez: bu pencere kullanıcının seçtiği
                // altyazı yeridir (beta.63: oyunun her yerindeki yazılar altyazının üstüne yığılıyordu). Yayın penceresinde ve
                // TV'de kendi yerinde çizilirler.
                ForEach(model.overlayRegions.filter { $0.items == nil }) { regionBox($0) }
                if model.overlayPhoneItems.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    GamePhoneBlocks(items: model.overlayPhoneItems)
                        .layoutPriority(-1)
                }
                if lines.isEmpty, adjusting {
                    line(SubtitleStack.Line(id: 0, text: String(localized: "Subtitles appear here."), role: .current,
                                            paragraphs: false, fading: false))
                }
                ForEach(lines) { line($0) }
            }
            .padding(.horizontal, model.settings.style.backgroundShape == .band ? 0 : 24 * scale)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drag to move, drag the edges to resize.")
                        .font(.csCallout.weight(.semibold))
                    Text("Double-click or press Enter to save, Esc to cancel.")
                        .font(.csCallout)
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                Button("Done") { model.commitOverlayEdit() }
                    .buttonStyle(.primary)
            }
            .padding(Theme.space("m"))
            // Üst kenardaki boy tutamağıyla çakışmasın.
            .padding(.top, 10)
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

    private var heightHandles: some View {
        VStack {
            heightHandle(.top)
            Spacer()
            heightHandle(.bottom)
        }
    }

    private func heightHandle(_ edge: VerticalEdge) -> some View {
        Capsule()
            .fill(Color.csAccent)
            .frame(width: 48, height: 6)
            .frame(width: 120, height: 14)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in actions.resizeHeight(edge) }
                .onEnded { _ in actions.endMove() })
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
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
        // Uzun çeviri en çok 3 satıra dengeli bölünür; 3 satıra sığmazsa yazı biraz küçülür (bkz. SubtitleWrap).
        let wrapped = line.wrapped
        let size = CGFloat(style.fontSize) * scale * (current ? 1 : 0.8) * CGFloat(wrapped.scale)
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
        // Bant: kutu pencerenin tüm genişliğini kaplar, oyundaki İngilizce yazıyı yan yana da gizler.
        let band = style.backgroundShape == .band
        let corner: CGFloat = band ? 0 : 10 * scale
        // "Yazı kadar" ve örtü: güncel satırın kutusu en az oyundaki altyazının ekrandaki kutusu kadar (her yana pay). Çeviri
        // kısa kalınca oyunun altyazısı kutunun yanlarından taşıyordu; çeviri daha uzunsa kutu yine yazı kadar büyür.
        let covers = !band && current && !line.paragraphs && style.placement == .cover && model.overlayCover?.text == line.text
        let cover: CGSize? = covers ? OverlayCover.size(of: model.overlayCover?.box, screen: geometry.screen, scale: scale) : nil
        let shown: Double = line.fading ? 0 : opacity
        let colored = model.settings.speakerColors && !line.paragraphs
        let text = Self.subtitleText(wrapped.text, colored: colored, base: Self.color(style.textColor), book: model.speakerBook)
            .font(.system(size: size, weight: weight))
        let padded = text
            .multilineTextAlignment(alignment)
            .lineSpacing(size * 0.3)
            .shadow(color: .black, radius: shadowRadius, x: 0, y: shadowRadius)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, vertical)
            .padding(.horizontal, horizontal)
        return CoverFrame(minimum: cover) { padded }
            .frame(maxWidth: band ? .infinity : nil)
            .background(Color.black.opacity(alpha), in: RoundedRectangle(cornerRadius: corner))
            .opacity(shown)
            .animation(.linear(duration: SubtitleStack.previousFade), value: line.fading)
            .contentShape(Rectangle())
            .gesture(moveGesture)
    }

    /// Ek alanın çevirisi: altyazıdan küçük, koyu zeminli kutu; oyundaki yazının bulunduğu yana yaslı. Kendiliğinden
    /// bulunan ekran yazısının blokları özgün yazının renkleri ve görünüşüyle çizilir.
    @ViewBuilder
    private func regionBox(_ region: OverlayRegion) -> some View {
        let style = model.settings.style
        let size = max(12, CGFloat(style.fontSize) * scale * 0.55)
        let alignment: Alignment = switch region.side {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        if let items = region.items {
            VStack(alignment: .leading, spacing: 4 * scale) {
                ForEach(items.indices, id: \.self) { index in
                    StyledScreenText.label(items[index], size: size)
                        .padding(.vertical, 4 * scale)
                        .padding(.horizontal, 10 * scale)
                        .background(StyledScreenText.background(items[index]), in: RoundedRectangle(cornerRadius: 4 * scale))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
            .gesture(moveGesture)
        } else {
            plainRegionBox(region, size: size, alignment: alignment)
        }
    }

    private func plainRegionBox(_ region: OverlayRegion, size: CGFloat, alignment: Alignment) -> some View {
        let style = model.settings.style
        return Text(verbatim: region.text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(model.settings.setTextApart ? .white : Self.color(style.textColor))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6 * scale)
            .padding(.horizontal, 14 * scale)
            // "Ekran yazılarını altyazıdan ayır": stili bilinmeyen ek alan kutusu altyazı kutusuna benzemesin; zeminsiz,
            // beyaz ve koyu gölgeli (Windows ile aynı).
            .background(Color.black.opacity(model.settings.setTextApart ? 0 : 0.85), in: RoundedRectangle(cornerRadius: 8 * scale))
            .shadow(color: .black.opacity(model.settings.setTextApart ? 1 : 0), radius: 3 * scale)
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
            .gesture(moveGesture)
    }

    /// Altyazı yazısı. Konuşana göre renk açıksa "Mattia: …" satırı (bölünmüş devamıyla) o konuşanın renginde
    /// (bkz. `SpeakerColors`); adsız satırlar ve görev paneli gibi paragraflar `base` renginde kalır.
    static func subtitleText(_ text: String, colored: Bool, base: Color, book: SpeakerColorBook? = nil) -> Text {
        guard colored else { return Text(verbatim: text).foregroundColor(base) }
        return SpeakerColors.segments(in: text, book: book).reduce(Text(verbatim: "")) { result, segment in
            let color = segment.color.flatMap(speakerColor) ?? base
            return result + Text(verbatim: segment.text).foregroundColor(color)
        }
    }

    private static func speakerColor(_ hex: String) -> Color? {
        guard let (r, g, b) = SpeakerColors.rgb(hex) else { return nil }
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    /// TV uygulamasındaki renklerle aynı (beyaz, #FFE135).
    static func color(_ color: SubtitleTextColor) -> Color {
        switch color {
        case .white: .white
        case .yellow: Color(red: 1, green: 0xE1 / 255, blue: 0x35 / 255)
        }
    }
}
