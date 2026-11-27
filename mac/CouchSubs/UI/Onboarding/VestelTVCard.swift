// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

/// Vestel Linux TV (deneysel): TEK TUŞLA kurulum — TV IP'si girilince uygulama TV'ye bağlanır, istemciyi kendi kopyalar
/// ve başlatır, sonra eşleşme kodu gelir. Bilgisayar TV'ye kalıcı bir şey yazmaz (her şey /tmp'de; TV yeniden başlayınca
/// silinir). İstemci TV'den bu Mac'e bağlanır (`/pair`, TV uygulamalarıyla aynı). Elle kurulum yedek olarak altta durur.
/// Seçili TV Vestel Linux değilse görünmez.
struct VestelTVCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var copied = false
    @State private var showManual = false

    var body: some View {
        if let tv = model.tv, tv.brand == .vestelLinux {
            Card(title: "Vestel Linux TV (experimental)") {
                if model.tvClients > 0 {
                    DoneLabel(text: String(localized: "The TV client is connected to this Mac."))
                } else {
                    Label("The TV client is not connected.", systemImage: "circle.dashed")
                        .font(.csBody.weight(.semibold))
                        .foregroundStyle(Color.csSecondary)
                }
                HintText(text: "Experimental: tested on a Vestel 55UD8400 (MB130); other Vestel models may differ. Nothing is installed on the TV permanently; restarting the TV removes it.")
                Text(verbatim: String(format: String(localized: "TV: %@ · This Mac: %@ (port %@)"),
                                      tv.host, model.computerAddress ?? "?", String(model.serverPort)))
                    .font(.csCallout).foregroundStyle(Color.csSecondary).textSelection(.enabled)

                // --- Tek tuş ---
                if let step = model.vestelInstallStep {
                    HStack(spacing: Theme.space("s")) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: step.rawValue).font(.csCallout).foregroundStyle(Color.csSecondary)
                    }
                } else {
                    Button("Install and start on the TV") { Task { await model.installVestelClientOneTap() } }
                        .buttonStyle(.primary)
                        .disabled(model.vestelClientURL == nil || model.computerAddress == nil)
                }
                if model.vestelClientURL == nil {
                    ErrorText(error: String(localized: "This build of CouchSubs does not include the Vestel TV client."))
                }
                if let error = model.vestelInstallError {
                    ErrorText(error: error)
                }
                HintText(text: "One tap: the app opens a shell on the TV over its test-tool socket, downloads the client, runs it, and closes the shell. Then a 6-digit code appears at the bottom of the TV — approve the request on this Mac.")

                Button("Pair TV") { Task { await model.openTVPairing() } }.buttonStyle(.secondary)

                if model.settings.output == .computer {
                    ErrorText(error: String(localized: "Subtitles are set to show only on this computer, so the TV client receives nothing. Choose TV or Both under Show subtitles on."))
                }

                // --- Elle kurulum (yedek) ---
                DisclosureGroup(isExpanded: $showManual) {
                    VStack(alignment: .leading, spacing: Theme.space("s")) {
                        HintText(text: "Use this only if one-tap install fails. It needs a TV shell (developer access).")
                        if model.vestelClientURL != nil {
                            Button("Show the TV client in Finder") { model.revealVestelClient() }.buttonStyle(.secondary)
                        }
                        if let command = model.vestelClientCommand {
                            HStack {
                                Text(verbatim: command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Button(copied ? "Copied" : "Copy") {
                                    model.copyVestelCommand()
                                    copied = true
                                }.buttonStyle(.secondary)
                            }
                        }
                    }
                } label: {
                    Text("Manual install (advanced)").font(.csCallout.weight(.semibold))
                }
            }
        }
    }
}
