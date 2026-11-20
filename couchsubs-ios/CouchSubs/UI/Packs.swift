// SPDX-License-Identifier: AGPL-3.0-only
// Oyun paketleri (tuvaldeki Telefon · Paketler). Paketler herkese ücretsiz: uygulamayla gelir, sunucudan güncellenir.

import CouchSubsCore
import SwiftUI

struct PacksScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var app: AppModel
    /// "Paketleri şimdi güncelle"ye basıldı, sonuç bekleniyor: sayfa bulanıklaşır, ortada gösterge döner.
    @State private var updating = false
    @State private var result: UpdateAlert?
    @State private var showResult = false

    var body: some View {
        MobileScreen {
            BackHeader(title: "Game packs") {
                MobilePill(text: String(localized: "Free"))
            }
        } content: {
            Text("The pack is chosen by itself when the game opens. Lines not in the pack are translated with the engine you chose.")
                .font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary)
            Tile {
                Toggle(isOn: $model.settings.gamePacks) {
                    VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                        Text("Use the ready Turkish translations of game packs").font(Mobile.TypeScale.headline)
                        Text(Self.summary(model.installedPacks) + " · " + String(localized: "offline"))
                            .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    }
                }
                .tint(Mobile.Palette.accent)
            }
            switch app.packStatus {
            case .downloading:
                HStack(spacing: Mobile.Space.inline) {
                    ProgressView().tint(Mobile.Palette.pro)
                    Text("Updating the packs…").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                }
            case .failed(let reason): MobileNote(text: reason, tone: Mobile.Palette.secondary)
            default: EmptyView()
            }
            if !model.installedPacks.isEmpty {
                Text("Tap a game to turn its pack on or off.")
                    .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
            }
            BentoGrid {
                ForEach(model.installedPacks) { pack in
                    packTile(pack)
                }
            }
            ImportedPacksSection()
            Tile {
                HStack(spacing: Mobile.Space.gap) {
                    MobileTileIcon(symbol: "arrow.down.circle")
                    VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                        Text("New games are coming").font(Mobile.TypeScale.headline)
                        Text("New packs arrive by themselves, free").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    }
                }
            }
        } bottom: {
            Button(action: updateNow) {
                if busy { Text("Updating…") } else { Text("Update the packs now") }
            }
            .buttonStyle(.mobileSecondary)
            .disabled(busy || AppConfig.packsBaseURL == nil)
        }
        .overlay {
            if updating {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    VStack(spacing: Mobile.Space.gap) {
                        ProgressView().controlSize(.large).tint(Mobile.Palette.pro)
                        Text("Updating the packs…").font(Mobile.TypeScale.headline).foregroundStyle(Mobile.Palette.text)
                    }
                    .padding(Mobile.Space.tile * 1.5)
                    .background(Mobile.Palette.surface2.opacity(0.9), in: RoundedRectangle(cornerRadius: Mobile.Radius.tile))
                    .accessibilityElement(children: .combine)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: updating)
        .alert(result?.title ?? "", isPresented: $showResult, presenting: result) { alert in
            if alert.retry {
                Button("Try again", action: updateNow)
                Button("Close", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            Text(verbatim: alert.message)
        }
        .onAppear { app.analytics.screen("packs") }
    }

    /// Elle ya da açılıştaki güncelleme sürüyor.
    private var busy: Bool { updating || app.packStatus == .downloading }

    private func updateNow() {
        guard !updating else { return }
        updating = true
        Task {
            let outcome = await app.updatePacksNow()
            updating = false
            guard let outcome else { return }
            result = UpdateAlert(outcome)
            showResult = true
        }
    }

    /// Güncellemenin sonucu: başlık, metin ve (hatada) "Yeniden dene".
    struct UpdateAlert {
        let title: String
        let message: String
        let retry: Bool

        init(_ outcome: AppModel.PackUpdateOutcome) {
            switch outcome {
            case .upToDate:
                title = String(localized: "Packs are up to date")
                message = String(localized: "The packs are already up to date.")
                retry = false
            case let .updated(summary):
                title = String(localized: "Packs updated")
                message = Self.describe(summary)
                retry = false
            case let .failed(reason, summary):
                title = String(localized: "The packs could not be updated")
                message = ([reason, String(localized: "The packs on this phone are still used.")]
                           + (summary.isEmpty ? [] : [Self.describe(summary)])).joined(separator: "\n\n")
                retry = true
            }
        }

        /// "2 paket güncellendi: Grand Theft Auto VI (+12.300 satır), Red Dead Redemption 2 (+800 satır)."
        static func describe(_ summary: PackUpdateSummary) -> String {
            var parts: [String] = []
            let updated = summary.updated, added = summary.added
            if !updated.isEmpty {
                let list = updated.map(Self.updatedItem).joined(separator: ", ")
                parts.append(updated.count == 1 ? String(format: String(localized: "1 pack updated: %@."), list)
                             : String(format: String(localized: "%lld packs updated: %@."), updated.count, list))
            }
            if !added.isEmpty {
                let list = added.map { String(format: String(localized: "%1$@ (%2$@ lines)"), $0.title, $0.lines.formatted()) }
                    .joined(separator: ", ")
                parts.append(added.count == 1 ? String(format: String(localized: "1 pack added: %@."), list)
                             : String(format: String(localized: "%lld packs added: %@."), added.count, list))
            }
            if summary.newLines > 0 {
                parts.append(String(format: String(localized: "%@ new lines in total."), summary.newLines.formatted()))
            }
            return parts.joined(separator: "\n")
        }

        private static func updatedItem(_ change: PackUpdateSummary.Change) -> String {
            if change.lineDelta > 0 {
                return String(format: String(localized: "%1$@ (+%2$@ lines)"), change.title, change.lineDelta.formatted())
            }
            if change.lineDelta < 0 {
                return String(format: String(localized: "%1$@ (%2$@ fewer lines)"), change.title, (-change.lineDelta).formatted())
            }
            return String(format: String(localized: "%@ (translations revised)"), change.title)
        }
    }

    /// Paket karosu: dokununca paket açılır ya da kapanır (Android ile aynı). Kapalıysa soluk ve "Kapalı"; son satırı
    /// veren paketse çerçeveli ve "Oynanıyor".
    private func packTile(_ pack: GamePackLibrary.Info) -> some View {
        let on = !model.disabledPacks.contains(pack.id)
        let playing = model.isRunning && model.packInUse == pack.title
        return Button { model.togglePack(pack.id) } label: {
            Tile(emphasis: playing ? .selected : .none) {
                HStack(alignment: .top) {
                    GameMonogram(code: Self.code(pack.title))
                    Spacer(minLength: Mobile.Space.inline)
                    if playing {
                        MobilePill(text: String(localized: "Now playing"), dot: true, compact: true)
                    } else if !on {
                        MobilePill(text: String(localized: "Off"), compact: true)
                    }
                }
                Spacer(minLength: Mobile.Space.inline)
                Text(verbatim: pack.title).font(Mobile.TypeScale.headline).lineLimit(2)
                Text(Self.linesText(pack.entries)).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
            }
            .opacity(on && model.settings.gamePacks ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(on ? "On" : "Off"))
    }

    /// "Grand Theft Auto V" → "GTA", "Mafia: The Old Country" → "MTO".
    static func code(_ title: String) -> String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count == 1 { return String(words[0].prefix(3)).uppercased() }
        return String(words.prefix(3).compactMap(\.first)).uppercased()
    }

    /// "190 bin satır"
    static func linesText(_ entries: Int) -> String {
        entries >= 1000 ? String(format: String(localized: "%lld thousand lines"), entries / 1000)
            : String(format: String(localized: "%lld lines"), entries)
    }

    /// "6 oyun · 517 bin satır"
    static func summary(_ packs: [GamePackLibrary.Info]) -> String {
        String(format: String(localized: "%lld games"), packs.count) + " · " + linesText(packs.reduce(0) { $0 + $1.entries })
    }
}
