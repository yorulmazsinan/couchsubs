// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct SecondAccountStep: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        StepLayout(title: "A second PSN account",
                   message: "CouchSubs watches the game through Remote Play. If it used your own account, the PS5 would turn off your controller. With a second account you keep playing undisturbed.") {
            VStack(alignment: .leading, spacing: Theme.space("l")) {
                NumberedRow(number: 1, text: "Create a free account at playstation.com with a different email address.")
                NumberedRow(number: 2, text: "On the PS5, choose Add User and sign in once with the new account.")
                NumberedRow(number: 3, text: "Still as the new user, go to Settings › System › Remote Play and turn on Enable Remote Play.")
                NumberedRow(number: 4, text: "Switch back to your own user. You only do this once.")
                // Kol ikinci hesaba atanırsa ana hesapla açılan oyun onu kendi kolu saymaz (GitHub #231).
                HintText(text: "When you turn on the controller to play, choose your MAIN account on the PS5. Don't play with the second account CouchSubs signs in with, or the controller will turn off by itself or won't work in the game.")
                // PS5 bağlıyken "Uzaktan Oynama bağlandı" yazısı kalıcıdır; bildirim ayarı değil, bu ayar gizler (GitHub #177).
                HintText(text: "To hide the \"Remote Play connected\" message on the screen: on the PS5, go to Settings › System › Remote Play and turn on Hide Remote Play Connection Status Pop-Up. Do it for both your main account and the second account.")
                // İkinci hesabı olmayanlar: görüntü bu Mac'teki Remote Play penceresinden okunur, PSN girişi ve PS5
                // eşleştirmesi atlanır.
                Card {
                    HStack {
                        Text("No second account? Read the Remote Play window").font(.csBody.weight(.semibold))
                        Spacer()
                        Button("Select") { model.useRemotePlayWindow() }
                            .buttonStyle(.secondary)
                    }
                    HintText(text: "CouchSubs reads the subtitles from PS Remote Play or chiaki-ng on this Mac. No second account or PS5 pairing is needed. You can connect a TV later.")
                    if !model.remotePlayInstalled(.automatic) {
                        Text("PS Remote Play and chiaki-ng aren't installed on this Mac.").foregroundStyle(Color.csSecondary)
                        HStack {
                            Button("Download PS Remote Play") { model.openDownload(for: .sony) }.buttonStyle(.secondary)
                            Button("Download chiaki-ng") { model.openDownload(for: .chiaki) }.buttonStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
