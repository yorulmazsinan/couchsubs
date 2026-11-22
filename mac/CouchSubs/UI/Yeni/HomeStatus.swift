// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

/// Ana ekranın "Sorun Var" durumu (tuval 10): sağ sütunda Durum ve Canlı Akış yerine sessizlik nedeni kartı. Yalnız
/// uygulamanın gerçekten bildiği nedenler gösterilir (uydurma neden yok); öncelik sırası yukarıdan aşağıya.
enum HomeProblem: Equatable {
    /// Çeviri sürüyor ama görüntü gelmiyor (bağlantı koptu ya da 20 sn'dir bağlanıyor).
    case pictureStopped
    /// Yazı tanıma takıldı ve yedek okuyucu da okuyamıyor.
    case readingStuck
    /// Yazı tanıma yanıt vermiyor; altyazılar yedek okuyucudan geliyor.
    case readingRescued
    /// Yazı tanıma art arda hata veriyor; değer diskteki boş yer (GB).
    case readingFailed(Double)
    /// Seçili diller için çeviri dil paketi yok ya da bu Mac'te çeviri yok.
    case translator(TranslatorStatus)
    /// Görüntü bir dakikadır geliyor ama okunan alanda hiç altyazı yok.
    case areaEmpty
    /// Çeviri sürüyor, altyazı TV'ye gidiyor ama TV uygulaması bağlı değil.
    case tvNotConnected

    @MainActor static func current(_ model: AppModel, now: Date = Date()) -> HomeProblem? {
        if model.translatorStatus != .ready { return .translator(model.translatorStatus) }
        guard model.isRunning, !model.demoMode else { return nil }
        if model.readingStuck { return .readingStuck }
        if let free = model.readingFailedFreeGB { return .readingFailed(free) }
        switch model.sessionState {
        case .disconnected: return .pictureStopped
        case .connecting:
            let since = model.lastFrameAt ?? model.sessionStartedAt ?? now
            if now.timeIntervalSince(since) > 20 { return .pictureStopped }
        case .streaming: break
        }
        if model.readingRescued { return .readingRescued }
        if model.settings.output.showsOnTV, model.hasTV, model.tvClients == 0, model.tv != nil { return .tvNotConnected }
        if model.showsSubtitleOffTip { return .areaEmpty }
        return nil
    }
}

/// Sessizlik nedeni kartı: solda 4 pt kırmızı şerit, "%lld SN SESSİZ", neden başlığı, açıklama, çözüm düğmeleri.
struct ProblemCard: View {
    @EnvironmentObject private var model: AppModel
    let problem: HomeProblem
    @ObservedObject var ticker: HomeTicker
    @State private var done: Set<String> = []

    var body: some View {
        DSCard(spacing: DS.space("s"), accent: .dsLive) {
            HStack(spacing: DS.space("xs")) {
                Circle().fill(Color.dsLive).frame(width: 8, height: 8)
                DSMonoLabel(silenceLabel, color: .dsLive)
            }
            Text(title).font(.dsH3).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: message).dsMuted(.system(size: 14))
            VStack(spacing: DS.space("xs")) { fixes }
                .padding(.top, DS.space("xxs"))
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .transition(.opacity.combined(with: .offset(y: -8)))
    }

    private var silence: Int {
        let since = model.sessionHistory.first?.date ?? model.sessionStartedAt ?? ticker.now
        return max(0, Int(ticker.now.timeIntervalSince(since)))
    }

    private var silenceLabel: LocalizedStringKey {
        model.isRunning ? LocalizedStringKey(String(format: String(localized: "%lld S SILENT"), silence)) : "PROBLEM"
    }

    private var title: LocalizedStringKey {
        switch problem {
        case .pictureStopped:
            if let last = model.lastFrameAt {
                return LocalizedStringKey(String(format: String(localized: "The PS5 picture hasn't arrived for %lld seconds."),
                                                 max(1, Int(ticker.now.timeIntervalSince(last)))))
            }
            return "Picture Stopped"
        case .readingStuck, .readingFailed: return "macOS can't read the text on the screen."
        case .readingRescued: return "macOS text reading isn't responding. Subtitles continue with the backup reader."
        case .translator(let status):
            return status == .needsDownload ? "The language pack isn't downloaded." : "Translation isn't available on this Mac."
        case .areaEmpty: return "No text is visible in the area being read."
        case .tvNotConnected: return "The TV app isn't connected."
        }
    }

    private var message: String {
        switch problem {
        case .pictureStopped:
            return String(localized: "The connection may have weakened. CouchSubs is trying to reconnect; if it doesn't, check that you're on the same Wi-Fi network as the PS5 and using 5 GHz.")
                + "\n\n" + model.ps5StatusText
        case .readingStuck:
            return String(localized: "Text reading got stuck. It usually recovers within a minute or two: macOS prepares its text model after the first launch or an update. Don't quit while waiting. If it doesn't recover, restart CouchSubs.")
        case .readingRescued:
            return String(localized: "This usually clears up within a minute or two: macOS prepares its text model after the first launch or an update. Reading may be a little less accurate until then. If it doesn't clear up, restart CouchSubs.")
        case .readingFailed(let free):
            return free < 10
                ? String(format: String(localized: "The disk is almost full (%.1f GB free). macOS needs free space to read text; free up a few GB and start the translation again."), free)
                : String(localized: "Restart the Mac and start the translation again.")
        case .translator(let status):
            if status == .needsDownload {
                return String(localized: "Open System Settings › General › Language & Region › Translation Languages and download both languages.")
            }
            return Translator.isAvailable ? "" : String(localized: "Apple's free translation needs macOS 26 or later. Game packs, DeepL and AI translation (Settings › Translation) work on this Mac.")
        case .areaEmpty:
            return String(localized: "Subtitles may appear somewhere else in this game. Try finding the area automatically or draw it yourself.")
                + " " + String(localized: "CouchSubs reads the English subtitles on screen, not the audio. Turn on the game's own subtitles.")
        case .tvNotConnected:
            let open = model.tv.map { String(localized: String.LocalizationValue(TVOpenText.openOnTV($0.brand))) } ?? ""
            let reason = TVOpenText.reason(model.tvOpenProblem).map { String(localized: String.LocalizationValue($0)) }
            return [open, reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n").replacingOccurrences(of: "**", with: "")
        }
    }

    @ViewBuilder private var fixes: some View {
        switch problem {
        case .pictureStopped:
            FixRow(id: "reconnect", title: "Reconnect Now", primary: true, done: $done) { model.reconnect() }
            FixRow(id: "test", title: "Open the Connection Test", done: $done) { model.step = .test }
        case .readingStuck, .readingRescued, .readingFailed:
            FixRow(id: "restart", title: "Restart CouchSubs Now", primary: true, done: $done) { model.relaunch() }
        case .translator(let status):
            if status == .needsDownload {
                FixRow(id: "lang", title: "Open Language and Region", primary: true, done: $done) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }
            }
            FixRow(id: "engine", title: "Advanced", done: $done) { model.openSettings(.advanced) }
        case .areaEmpty:
            FixRow(id: "draw", title: "Draw the Area Manually", primary: true, done: $done) { model.openSettings(.area) }
            FixRow(id: "auto", title: "Translate On-Screen Text Automatically",
                   state: model.settings.autoScreenText ? "On" : "Off", done: $done) { model.settings.autoScreenText.toggle() }
        case .tvNotConnected:
            FixRow(id: "open", title: LocalizedStringKey(TVOpenText.tryButton), primary: true, done: $done) { model.retryTVOpen() }
            if model.canReinstallTVApp {
                FixRow(id: "reinstall", title: "Reinstall the TV App", done: $done) { Task { await model.updateTVApp() } }
            } else if model.canReconnectTV {
                FixRow(id: "connect", title: "Connect TV", done: $done) { model.step = .tv }
            }
        }
    }
}

/// Çözüm satırı: 48 yükseklik, 16 köşe; ilki amber, öbürleri alan zemini; sağda mono durum ("Kapalı", "Yapıldı").
private struct FixRow: View {
    let id: String
    let title: LocalizedStringKey
    var state: LocalizedStringKey?
    var primary = false
    @Binding var done: Set<String>
    let action: () -> Void

    var body: some View {
        let finished = done.contains(id)
        Button {
            action()
            done.insert(id)
        } label: {
            HStack {
                Text(title).font(.dsButtonSecondary).lineLimit(1)
                Spacer(minLength: DS.space("s"))
                if finished && state == nil {
                    Text("Completed").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Color.dsSuccessText)
                } else if let state {
                    Text(state).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Color.dsMuted)
                }
            }
            .foregroundStyle(primary && !finished ? Color.dsOnAmber : Color.dsText)
            .padding(.horizontal, DS.space("m"))
            .frame(height: DS.size("button"))
            .background(finished && state == nil ? Color.dsSuccessSoft : primary ? Color.dsAmber : Color.dsField,
                        in: RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Ana ekranın bilgi notları (sorun değil, bilgi): çökme raporu, TV uygulaması güncellemesi, PS5 ana hesap ipucu,
/// kayıtlı alan önerisi, kullanım verisi notu, çevrimiçi motorun hatası, kurulum eksikse deneme modu. Sağ sütunun
/// üstünde, en çok 240 yükseklikte kendi içinde kayar.
struct HomeNotices: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let items = notices
        if !items.isEmpty {
            ScrollView(.vertical) {
                VStack(spacing: DS.space("s")) {
                    ForEach(items, id: \.self) { notice($0) }
                }
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private enum Notice: Hashable {
        case crash, tvUpdate, tvOutdated, tvReinstall, testNotConnected, mainAccount, autoScreenText, usage, online, areas, setup
    }

    private var notices: [Notice] {
        var list: [Notice] = []
        if CrashNotice.shared.report != nil { list.append(.crash) }
        if model.tvAppUpdating && model.settings.output.showsOnTV { list.append(.tvUpdate) }
        else if model.hasTV, model.tvAppOutdated != nil, model.settings.output.showsOnTV { list.append(.tvOutdated) }
        else if model.hasTV, model.canReinstallTVApp, !model.isRunning, model.settings.output.showsOnTV { list.append(.tvReinstall) }
        if model.testTVNotConnected && model.tvClients == 0 { list.append(.testNotConnected) }
        if model.isRunning && MainAccountTip.isVisible(ps5: !model.isXbox && model.settings.frameSource == .ps5, demo: model.demoMode,
                                                       hasSubtitle: !model.lastTranslation.isEmpty, streaming: model.sessionState == .streaming) {
            list.append(.mainAccount)
        }
        if model.gameAreas.offeredGame != nil { list.append(.areas) }
        if model.isRunning, model.onlineIssue != nil { list.append(.online) }
        if model.showsAutoScreenTextNotice { list.append(.autoScreenText) }
        if model.showsUsageNotice { list.append(.usage) }
        if !model.canStart && !model.isRunning && !model.demoMode { list.append(.setup) }
        return list
    }

    @ViewBuilder private func notice(_ notice: Notice) -> some View {
        switch notice {
        case .crash: CrashReportCard()
        case .tvUpdate:
            VStack(alignment: .leading, spacing: DS.space("xs")) {
                TVAppCard()
                if case .upToDate = model.tvApp {
                    Button("OK") { model.dismissTVAppUpdate() }.buttonStyle(.dsSecondary)
                }
            }
            .noticeCard()
        case .tvOutdated:
            NoticeCard(text: String(format: String(localized: "TV app is out of date (%@ → %@)"),
                                    model.tvAppOutdated?.installed ?? "", model.tvAppOutdated?.bundled ?? "")) {
                Button("Update the TV App") { Task { await model.updateTVApp() } }
                    .buttonStyle(.dsSecondary)
                    .disabled(model.tvAppUpdating && model.tvApp == .working)
            }
        case .tvReinstall:
            NoticeCard(text: String(localized: "Waiting for the TV app")) {
                Button("Reinstall the TV App") { Task { await model.updateTVApp() } }
                    .buttonStyle(.dsSecondary)
                    .disabled(model.tvAppUpdating && model.tvApp == .working)
                if model.canChangeTV { Button("Change the TV") { model.step = .tv }.buttonStyle(.dsSecondary) }
            }
        case .testNotConnected:
            NoticeCard(text: String(localized: "The test subtitle did not reach the TV because the TV app is not connected. Open CouchSubs on the TV. If the TV shows a 6-digit code, don't type it anywhere: approve it in the “Pair this TV?” window that opens on this computer, then test again.")) { EmptyView() }
        case .mainAccount:
            NoticeCard(text: String(localized: "To play without the connection dropping: 1. On the PS5, start the game with your MAIN account first. 2. Then start translating. 3. Don't switch users during the game; when you turn on the controller, choose your MAIN account. Don't play with the second account CouchSubs signs in with, or the controller will turn off by itself or won't work in the game.")) { EmptyView() }
        case .areas:
            NoticeCard(text: String(format: String(localized: "There are saved areas for %@. Use them?"), model.gameAreas.offeredGame ?? "")) {
                Button("Use") { model.gameAreas.useOffered() }.buttonStyle(.dsPrimary)
                Button("No") { model.gameAreas.declineOffered() }.buttonStyle(.dsSecondary)
            }
        case .online:
            NoticeCard(text: String(format: String(localized: "%@ is not translating right now"), model.settings.onlineEngine.displayName) + ". "
                       + (model.onlineIssue.map { TranslationCard.describe($0, engine: model.settings.onlineEngine, server: model.settings.localAIServer) } ?? "")
                       + " " + String(localized: "Meanwhile the free translation is used.")) { EmptyView() }
        case .autoScreenText:
            NoticeCard(text: String(localized: "Automatic on-screen text translation is experimental; you can turn it on in Settings.")) { EmptyView() }
        case .usage:
            NoticeCard(text: String(localized: "CouchSubs measures how the app is used without linking it to you; no subtitle text, picture or account data is sent. You can turn this off in Settings › Game packs › Usage data.")) { EmptyView() }
        case .setup:
            NoticeCard(text: setupText) {
                DemoModeButton(kind: .secondary)
            }
        }
    }

    private var setupText: String {
        if model.remotePlayMissing {
            return String(localized: "The Remote Play app isn't installed on this Mac. Download it in Settings › Picture source.")
        }
        return model.ps5StatusText
    }
}

/// Kısa bilgi kartı: metin ve altında düğmeler.
private struct NoticeCard<Buttons: View>: View {
    let text: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space("s")) {
            Text(verbatim: text).font(.system(size: 13)).foregroundStyle(Color.dsText).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if !(Buttons.self == EmptyView.self) {
                HStack(spacing: DS.space("xs")) { buttons }
            }
        }
        .noticeCard()
    }
}

private extension View {
    func noticeCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
        return self
            .environment(\.csInsideCard, true)
            .padding(DS.space("m"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsSurface, in: shape)
            .overlay(shape.strokeBorder(Color.dsBorder))
            .overlay(alignment: .leading) { Color.dsAmber.frame(width: 4).clipShape(shape).allowsHitTesting(false) }
            .clipShape(shape)
    }
}
