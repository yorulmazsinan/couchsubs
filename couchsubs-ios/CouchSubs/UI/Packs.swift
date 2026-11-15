// SPDX-License-Identifier: AGPL-3.0-only
// Oyun paketleri (tuvaldeki Telefon · Paketler). Paketler herkese ücretsiz: uygulamayla gelir, sunucudan güncellenir.

import CouchSubsCore
import SwiftUI

struct PacksScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var app: AppModel

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
            Button("Update the packs now") { Task { await app.refreshPacks(force: true) } }
                .buttonStyle(.mobileSecondary)
                .disabled(app.packStatus == .downloading || AppConfig.packsBaseURL == nil)
        }
        .onAppear { app.analytics.screen("packs") }
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
