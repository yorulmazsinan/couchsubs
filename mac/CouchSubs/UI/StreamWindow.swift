// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import Combine
import SwiftUI

/// "Yayın penceresi": şeffaflık tanımayan yayın programları (TikTok LIVE Studio, Streamlabs, OBS dışındakiler) için
/// düz renkli zeminde altyazı çizen sıradan bir pencere. Programda "Pencere yakalama" ile eklenir, zemin chroma key ile
/// silinir. Başlığı sabittir ki yakalama listesinde bulunsun. Saydam altyazı penceresinden (SubtitleOverlay.swift)
/// ayrıdır; satırlar aynı yığından gelir (bkz. AppModel+ComputerScreen.swift).
@MainActor
final class StreamWindowController: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var window: NSWindow?
    private var modelChanges: AnyCancellable?

    static let autosaveName = "CouchSubsStreamWindow"

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        modelChanges = model.$streamWindowOpen.removeDuplicates().sink { [weak self] open in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(open) } }
        }
    }

    private func show(_ open: Bool) {
        guard let model else { return }
        guard open else {
            window?.orderOut(nil)
            return
        }
        let window = self.window ?? makeWindow(model)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(_ model: AppModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = Self.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Yakalanan görüntü 16:9 kalsın; yayın programında kaynak oranı bozulmaz.
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentMinSize = NSSize(width: 480, height: 270)
        window.contentView = NSHostingView(rootView: StreamWindowView().environmentObject(model))
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        self.window = window
        return window
    }

    /// Yayın programının pencere listesinde görünen ad; altyazıya göre değişmez (Türkçede "CouchSubs Yayın").
    static var title: String { String(localized: "CouchSubs Stream") }

    func windowWillClose(_ notification: Notification) {
        model?.streamWindowOpen = false
    }
}

/// Pencerenin içeriği: düz zemin ve TV'deki altyazı kutusu (yazı boyu 1080 satırlık ekrana göre pencereye ölçeklenir).
struct StreamWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            let scale = max(0.2, proxy.size.height / 1080)
            VStack(spacing: 14 * scale) {
                // Sürekli okunan ek alanların çevirisi saydam penceredeki gibi üstte, alanın yanına yaslı.
                VStack(spacing: 10 * scale) {
                    // Ekran yazıları (bloklu) aşağıda kendi yerlerinde çizilir.
                    ForEach(model.overlayRegions.filter { $0.items == nil }) { regionBox($0, scale: scale) }
                }
                .padding(.top, 16 * scale)
                Spacer(minLength: 0)
                ForEach(model.overlayLines) { line(line: $0, scale: scale) }
            }
            .padding(.horizontal, 24 * scale)
            .padding(.bottom, proxy.size.height * 0.07)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background {
                if !model.overlayPhoneItems.isEmpty { GamePhoneBlocks(items: model.overlayPhoneItems) }
                let screenText = model.overlayRegions.flatMap { $0.items ?? [] }
                if !screenText.isEmpty { ScreenTextBlocks(items: screenText) }
            }
        }
        .background(Self.color(model.streamBackground))
    }

    static func color(_ background: StreamBackground) -> Color {
        let rgb = background.rgb
        return Color(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }

    /// Ek alanın çevirisi: altyazıdan küçük, tam koyu kutu (düz zeminde chroma key bozulmasın).
    private func regionBox(_ region: OverlayRegion, scale: CGFloat) -> some View {
        let style = model.settings.style
        let size = max(12, CGFloat(style.fontSize) * scale * 0.55)
        let alignment: Alignment = switch region.side {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(verbatim: region.text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(SubtitleOverlayView.color(style.textColor))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6 * scale)
            .padding(.horizontal, 14 * scale)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 8 * scale))
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func line(line: SubtitleStack.Line, scale: CGFloat) -> some View {
        let style = model.settings.style
        let current = line.role == .current
        // Uzun çeviri en çok 3 satıra dengeli bölünür; 3 satıra sığmazsa yazı biraz küçülür (bkz. SubtitleWrap).
        let wrapped = line.wrapped
        let size = CGFloat(style.fontSize) * scale * (current ? 1 : 0.8) * CGFloat(wrapped.scale)
        // Düz zeminde yarı saydam kutu zeminle karışır, chroma key'i bozar; kutu tam koyu (ya da hiç yok).
        let alpha = StreamBackground.boxOpacity(background: style.background)
        let opacity: Double = switch line.role {
        case .current: 1
        case .previous: 0.6
        case .older: 0.45
        }
        let weight: Font.Weight = style.bold ? .bold : .semibold
        let alignment: TextAlignment = line.paragraphs ? .leading : .center
        let vertical: CGFloat = (current ? 10 : 6) * scale
        let horizontal: CGFloat = (current ? 26 : 20) * scale
        let corner: CGFloat = 10 * scale
        // Soluk üst satırlar kutunun içinde yazı renginden soldurulur; pencere zeminiyle karışan saydamlık olmaz.
        let textOpacity: Double = alpha > 0 ? opacity : 1
        let shadowRadius: CGFloat = alpha > 0 ? 0 : 2 * scale
        let shown: Double = line.fading ? 0 : 1
        let colored = model.settings.speakerColors && !line.paragraphs
        let text = SubtitleOverlayView.subtitleText(wrapped.text, colored: colored,
                                                    base: SubtitleOverlayView.color(style.textColor))
            .font(.system(size: size, weight: weight))
        return text
            .opacity(textOpacity)
            .multilineTextAlignment(alignment)
            .lineSpacing(size * 0.3)
            .shadow(color: .black, radius: shadowRadius, x: 0, y: shadowRadius)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, vertical)
            .padding(.horizontal, horizontal)
            .background(Color.black.opacity(alpha), in: RoundedRectangle(cornerRadius: corner))
            .opacity(shown)
            .animation(.linear(duration: SubtitleStack.previousFade), value: line.fading)
    }
}

/// Yayın katmanının koordinatları telefondaki kaynak kutularıyla aynı, sol üst köşeye göre 0…1 aralığındadır.
struct GamePhoneBlocks: View {
    let items: [ScreenTranslation.Item]

    var body: some View {
        GeometryReader { proxy in
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let box = item.box
                let width = max(0, box.right - box.left) * proxy.size.width
                let height = max(0, box.bottom - box.top) * proxy.size.height
                Text(verbatim: item.translation)
                    .font(.system(size: max(1, item.lineHeight * proxy.size.height * 0.85), weight: .semibold))
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(Self.color(item.style?.foreground, fallback: .white))
                    .frame(width: width, height: height, alignment: .leading)
                    .background(Self.color(item.style?.background, fallback: .black))
                    .clipped()
                    .position(x: (box.left + box.right) * 0.5 * proxy.size.width,
                              y: (box.top + box.bottom) * 0.5 * proxy.size.height)
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private static func color(_ hex: String?, fallback: Color) -> Color {
        guard let hex, let (r, g, b) = DesignTokens.rgb(hex) else { return fallback }
        return Color(.sRGB, red: r, green: g, blue: b)
    }
}

/// Kendiliğinden bulunan ekran yazısının çevirisi özgün yazının stilinde: zemin ve yazı rengi, kalınlık, dar aile, hiza
/// (`TextLook`; BÜYÜK HARF çeviriye zaten uygulanmış gelir). Düz zeminde kutu tam opak, değilse %85 opak.
enum StyledScreenText {
    static func label(_ item: ScreenTranslation.Item, size: CGFloat) -> some View {
        let look = item.look
        let alignment: TextAlignment = switch look?.align {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
        return Text(verbatim: item.translation)
            .font(.system(size: size, weight: look?.bold == true ? .bold : .semibold).width(look?.condensed == true ? .condensed : .standard))
            .foregroundStyle(color(item.style?.foreground, fallback: .white))
            .multilineTextAlignment(alignment)
    }

    static func background(_ item: ScreenTranslation.Item) -> Color {
        color(item.style?.background, fallback: .black).opacity(item.look?.flat == false ? 0.85 : 1)
    }

    static func frameAlignment(_ item: ScreenTranslation.Item) -> Alignment {
        switch item.look?.align {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    static func color(_ hex: String?, fallback: Color) -> Color {
        guard let hex, let (r, g, b) = SpeakerColors.rgb(hex) else { return fallback }
        return Color(.sRGB, red: r, green: g, blue: b)
    }
}

/// Ekran yazısı blokları oyun karesindeki kendi yerlerinde (yayın penceresi 16:9 karenin kendisidir). Türkçe özgün
/// bloğun genişliğini aşmaz: satır kırılır, gerekirse yazı en çok %20 küçülür; yine sığmazsa kutu aşağı uzar.
struct ScreenTextBlocks: View {
    let items: [ScreenTranslation.Item]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(items.indices, id: \.self) { i in
                    let item = items[i]
                    let line = max(1, item.lineHeight * proxy.size.height)
                    let pad = line * 0.15
                    let width = max(0, item.box.right - item.box.left) * proxy.size.width + 2 * pad
                    StyledScreenText.label(item, size: line * 0.85)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: width, alignment: StyledScreenText.frameAlignment(item))
                        .padding(.vertical, pad)
                        .background(StyledScreenText.background(item))
                        .offset(x: item.box.left * proxy.size.width - pad, y: item.box.top * proxy.size.height - pad)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
        .allowsHitTesting(false)
    }
}
