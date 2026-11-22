// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

// Tuval 17–18: menü çubuğu penceresi, Hakkında, Sürüm Notları ve açılır reklam.

private struct CheckForUpdatesKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Sparkle'ın "Güncellemeleri Denetle…" eylemi (Mac App Store sürümünde nil; güncellemeyi App Store yapar).
    var checkForUpdates: (() -> Void)? {
        get { self[CheckForUpdatesKey.self] }
        set { self[CheckForUpdatesKey.self] = newValue }
    }
}

// MARK: Hakkında

/// Hakkında: logo, sürüm, lisans ve teşekkürler, Kaynak ve Güncellemeleri Denetle…, altta Enmera logosu ve
/// "Telif Hakkı © 2026 Enmera" (kişi adı yok).
struct NewAboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.checkForUpdates) private var checkForUpdates

    var body: some View {
        VStack(spacing: DS.space("s")) {
            HStack {
                DSMonoLabel("ABOUT")
                Spacer()
            }
            DSLogoMark(height: 64).padding(.top, DS.space("xs"))
            Text(verbatim: "CouchSubs").font(.dsH2)
            Text(verbatim: AppIdentity.version).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.dsMuted)
            Group {
                Text("Free and open source under the GNU AGPL-3.0 license.")
                Text("Remote Play connection by chiaki-ng (AGPL-3.0). Thanks to its developers.")
                Text("The Xbox home console picture uses the open source approach of Greenlight (MIT).")
                Text("CouchSubs is not affiliated with Sony Interactive Entertainment. PlayStation and PS5 are trademarks of Sony Interactive Entertainment Inc.")
                Text("CouchSubs is not affiliated with Microsoft. Xbox is a trademark of Microsoft Corporation.")
            }
            .dsMuted()
            .multilineTextAlignment(.center)
            HStack(spacing: DS.space("xs")) {
                Link(destination: AppIdentity.sourceURL) { Text("Source") }.buttonStyle(.dsSecondary)
                Link(destination: URL(string: "https://github.com/chiaki-ng/chiaki-ng")!) { Text(verbatim: "chiaki-ng") }.buttonStyle(.dsSecondary)
                if let checkForUpdates {
                    Button("Check for Updates…") { checkForUpdates() }.buttonStyle(.dsSecondary)
                }
            }
            .padding(.top, DS.space("xs"))
            VStack(spacing: DS.space("xs")) {
                Image("Enmera").resizable().aspectRatio(contentMode: .fit).frame(height: 16).opacity(0.85)
                    .accessibilityLabel(Text(verbatim: "Enmera"))
                Text("Copyright © 2026 Enmera").font(.system(size: 11)).foregroundStyle(Color.dsFaint)
            }
            .padding(.top, DS.space("xs"))
            Button("Close") { dismiss() }
                .buttonStyle(DSButtonStyle(kind: .primary, fullWidth: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, DS.space("xs"))
        }
        .padding(DS.space("l"))
        .frame(width: 460)
        .background(Color.dsSurface)
        .newLook()
    }
}

// MARK: Sürüm Notları

/// docs/surum-notlari.md'den (uygulamayla gelir): "Bu sürümde yeni" maddeleri ve bir önceki sürümün özeti.
enum ReleaseNotes {
    static func load() -> (current: [String], previous: [String]) {
        guard let url = Bundle.main.url(forResource: "surum-notlari", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], []) }
        return parse(text)
    }

    static func parse(_ text: String) -> (current: [String], previous: [String]) {
        var current: [String] = []
        var previous: [String] = []
        var inCurrent = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("**Bu sürümde yeni**") { inCurrent = true; continue }
            if inCurrent, line.hasPrefix("- ") { current.append(clean(String(line.dropFirst(2)))); continue }
            if inCurrent, line.hasPrefix("**"), previous.isEmpty, let colon = line.range(of: ":**") {
                previous = line[colon.upperBound...].split(separator: ",").map { clean(String($0)) }.filter { !$0.isEmpty }
                break
            }
        }
        return (current, previous)
    }

    /// Markdown kalın ve bağlantı işaretleri atılır; cümle büyük harfle başlar ve noktayla biter.
    private static func clean(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "**", with: "")
        value = value.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let first = value.first else { return "" }
        return String(first).uppercased(with: Locale(identifier: "tr")) + value.dropFirst() + "."
    }
}

struct ReleaseNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var which = 0
    private let notes = ReleaseNotes.load()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space("s")) {
            DSCardHeader("RELEASE NOTES")
            DSTabs(selection: $which, items: [(0, "This Version"), (1, "Previous")])
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: DS.space("s")) {
                    ForEach(Array((which == 0 ? notes.current : notes.previous).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: DS.space("s")) {
                            Circle().fill(Color.dsAmber).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                            Text(verbatim: line).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 360)
            Button("OK") { dismiss() }
                .buttonStyle(DSButtonStyle(kind: .primary, fullWidth: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(DS.space("l"))
        .frame(width: 520)
        .background(Color.dsSurface)
        .newLook()
    }
}

// MARK: Menü çubuğu

/// Menü çubuğu penceresi: başlık (konsol · TV ve durum rozeti), Çeviriyi Başlat/Durdur, Tıklamalar Alttaki Pencereye
/// Geçsin (kısayolu sağda), Altyazıları Konumlandır, CouchSubs'ı Aç. Yalnız altyazı bu bilgisayarın ekranındayken.
struct MenuBarPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space("s")) {
            HStack(spacing: DS.space("s")) {
                DSLogoMark(height: 18, breathing: false)
                    .frame(width: 40, height: 40)
                    .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.radius("control")))
                VStack(alignment: .leading, spacing: DS.space("xxs")) {
                    Text(verbatim: "CouchSubs").font(.dsBodyStrong)
                    Text(verbatim: subtitle).font(.dsCaption).foregroundStyle(Color.dsMuted).lineLimit(1)
                }
                Spacer(minLength: DS.space("xs"))
                DSBadge(text: model.isRunning ? "Translation On" : "Ready", tone: model.isRunning ? .ok : .unknown)
            }
            Group {
                if model.isRunning {
                    Button("Stop Translating") { model.stop() }.buttonStyle(DSButtonStyle(kind: .stop, fullWidth: true))
                } else {
                    Button("Start Translating") { Task { await model.start() } }
                        .buttonStyle(DSButtonStyle(kind: .primary, fullWidth: true))
                        .disabled(model.isStarting || !model.canStart)
                }
            }
            DSDivider()
            HStack(spacing: DS.space("m")) {
                DSSwitch(isOn: Binding(get: { model.settings.overlayClickThrough }, set: { model.settings.overlayClickThrough = $0 }))
                    .accessibilityLabel(Text("Clicks Pass to the Window Below"))
                DSTitleBlock(title: "Clicks Pass to the Window Below", subtitle: "Subtitles don't block clicks.",
                             titleFont: .system(size: 14, weight: .medium))
                if let key = HotkeyTable.keys(model.settings.hotkeys, .clickThrough).first {
                    Text(verbatim: key.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFaint)
                }
            }
            MenuRow(title: "Position the Subtitles") { model.overlayAdjusting = true }
            DSDivider()
            MenuRow(title: "Show CouchSubs", arrow: true) {
                if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            }
        }
        .padding(DS.space("m"))
        .frame(width: 340)
        .background(Color.dsSurface)
        .newLook()
    }

    private var subtitle: String {
        let console = model.isXbox ? "Xbox" : model.console.map { $0.name.isEmpty ? "PS5" : $0.name } ?? model.pictureSourceName
        return [console, model.tv?.name].compactMap { $0 }.joined(separator: " · ")
    }

    private struct MenuRow: View {
        let title: LocalizedStringKey
        var arrow = false
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Spacer()
                    if arrow { Text(verbatim: "→").foregroundStyle(Color.dsFaint) }
                }
                .padding(.horizontal, DS.space("s"))
                .frame(height: DS.size("tab"))
                .background(hovering ? Color.dsField : Color.clear, in: RoundedRectangle(cornerRadius: DS.radius("control")))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

// MARK: Açılır reklam

/// Açılır reklam: yalnız görsel (yazı/düğme yok), görselin oranına göre yatay ya da dikey, tıklanınca bağlantı; köşede ×
/// ve küçük REKLAM. Günde en çok 1; yalnız açılışta ya da çeviri durunca; çeviri sürerken, kurulumda, deneme modunda
/// asla. Üçüncü taraf reklam ağı yok. İçerik şimdilik yerel örnek (uzaktan liste sonra).
struct PopupAd: Identifiable, Equatable {
    let id: String
    /// Görselin en-boy oranı (genişlik / yükseklik); 1'den büyükse yatay açılır.
    let aspect: CGFloat
    let art: [Color]
    let url: URL

    static let samples: [PopupAd] = [
        PopupAd(id: "ornek-yatay", aspect: 16 / 9, art: [Color(red: 0.169, green: 0.176, blue: 0.2), Color(red: 0.961, green: 0.722, blue: 0.239)],
                url: AdCatalog.home),
    ]
}

@MainActor
enum PopupAdSchedule {
    private static let key = "popupAdShownDay"

    /// Bugün gösterilmediyse ve koşullar uygunsa gösterilecek reklam.
    static func next(model: AppModel, defaults: UserDefaults = .standard) -> PopupAd? {
        guard model.step == .done, !model.isRunning, !model.demoMode, !model.isStarting,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let ad = PopupAd.samples.first else { return nil }
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        guard defaults.double(forKey: key) < today else { return nil }
        defaults.set(today, forKey: key)
        return ad
    }
}

struct PopupAdView: View {
    let ad: PopupAd
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        let width: CGFloat = ad.aspect >= 1 ? 560 : 340
        Button {
            openURL(ad.url)
            close()
        } label: {
            ZStack {
                LinearGradient(colors: ad.art, startPoint: .topLeading, endPoint: .bottomTrailing)
                DSLogoMark(height: 72, breathing: false)
            }
            .frame(width: width, height: width / ad.aspect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Text(verbatim: "×").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Close"))
            .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            Text("AD").font(.dsAdTag).tracking(0.9).foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8).frame(height: 18).background(Color.black.opacity(0.35), in: Capsule()).padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.radius("card"), style: .continuous))
        .accessibilityLabel(Text("Advertisement"))
    }
}
