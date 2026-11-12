// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct TestStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var sent = false

    /// TV seçilmediyse ("TV'm yok") örnek altyazı bu bilgisayarın ekranında görünür.
    private var onComputer: Bool { model.settings.output == .computer }

    var body: some View {
        StepLayout(title: "Let's test it",
                   message: onComputer ? "CouchSubs will show a sample subtitle on this computer's screen, at the bottom."
                       : "CouchSubs will send a sample subtitle to your TV. It should appear at the bottom of the screen, on top of the game.") {
            VStack(alignment: .leading, spacing: Theme.space("l")) {
                HStack(spacing: Theme.space("m")) {
                    Button("Send test subtitle") {
                        model.sendTestSubtitle()
                        sent = true
                    }
                    .buttonStyle(CSButtonStyle(kind: sent ? .secondary : .primary))
                    if onComputer {
                        Button("Adjust the subtitle window") { model.overlayAdjusting = true }
                            .buttonStyle(.secondary)
                            .disabled(model.overlayAdjusting)
                    }
                }
                if sent {
                    Card(title: onComputer ? "Do you see it on the screen?" : "Do you see it on the TV?") {
                        HStack(spacing: Theme.space("m")) {
                            Button("Yes, I see it") {
                                model.overlayAdjusting = false
                                model.advance()
                            }
                            .buttonStyle(.primary)
                            .keyboardShortcut(.defaultAction)
                            Button("No") { model.step = .tv }
                                .buttonStyle(.secondary)
                        }
                        HintText(text: onComputer ? "If you don't see it, send it again. It shows for a few seconds at the bottom of the screen."
                                     : "If you don't see it, make sure the CouchSubs TV app is open and connect the TV again.")
                    }
                }
                HintText(text: "CouchSubs sends the English subtitles it reads to a shared pool, anonymously, to make better Turkish translations for everyone. You can turn this off in Settings.")
            }
        }
    }
}
