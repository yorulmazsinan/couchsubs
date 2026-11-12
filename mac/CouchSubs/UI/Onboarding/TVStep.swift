// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import SwiftUI

struct TVStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var tvs: [LGTV] = []
    @State private var searching = false
    @State private var working = false
    @State private var error: String?
    /// Bağlanılan TV'nin markası (Samsung'da izin kutusu ayrıca anlatılır).
    @State private var pairingBrand: TVBrand?

    var body: some View {
        StepLayout(title: "Connect your TV",
                   message: "Turn on the TV. When you press Connect, the TV asks for permission once — accept it with the remote. If the CouchSubs TV app is missing, this screen helps you install it.") {
            VStack(alignment: .leading, spacing: Theme.space("l")) {
                if let tv = model.tv {
                    DoneLabel(text: tv.name)
                }
                Card {
                    HStack {
                        Text(verbatim: "TV").font(.csHeadline)
                        if searching { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Search again") { Task { await search() } }.buttonStyle(.secondary).disabled(searching)
                    }
                    if tvs.isEmpty && !searching {
                        HintText(text: "No LG or Samsung TV found. Make sure the TV is on and on the same network.")
                    }
                    ForEach(tvs, id: \.host) { tv in
                        HStack {
                            Text(verbatim: "\(tv.name) — \(tv.host)")
                            Spacer()
                            Button("Connect") { Task { await pair(tv) } }.buttonStyle(.primary).disabled(working)
                        }
                    }
                }
                Card {
                    HStack {
                        Text(verbatim: "Android TV / Google TV")
                        Spacer()
                        Button("Select") { Task { await pair(LGTV(name: "Android TV", host: "", brand: .androidTV)) } }
                            .buttonStyle(.secondary).disabled(working)
                    }
                    HintText(text: "Vestel, Arçelik, Beko, Grundig, Philips and other TVs running Android TV.")
                }
                // TV'si olmayanlar (PS5 monitörde ya da PS Remote Play bilgisayarda): TV kurulumu atlanır.
                Card {
                    HStack {
                        Text("No TV? Show on the computer screen").font(.csBody.weight(.semibold))
                        Spacer()
                        Button("Select") { model.useComputerScreen() }
                            .buttonStyle(.secondary).disabled(working)
                    }
                    HintText(text: "Subtitles appear in a window over the game or PS Remote Play. You can connect a TV later.")
                }
                if working {
                    HStack(spacing: Theme.space("s")) {
                        ProgressView().controlSize(.small)
                        if pairingBrand == .samsung {
                            Text("Accept the permission box on the TV with the remote (Allow). CouchSubs waits 60 seconds.")
                                .foregroundStyle(Color.csSecondary)
                        } else {
                            Text("Accept the request on the TV…").foregroundStyle(Color.csSecondary)
                        }
                    }
                }
                ErrorText(error: error)
                TVAppCard()
                // Uygulamayla TV paketi gelmediyse (geliştirici derlemesi) rehber gösterilir.
                if let tv = model.tv, tv.brand != .lg, !model.canInstallTVApp {
                    Card(title: "CouchSubs TV app") {
                        Text("Install the CouchSubs TV app on this TV using the guide and open it. It finds this computer by itself.")
                        Link("Open the guide", destination: AppIdentity.tvGuideURL)
                    }
                }
            }
        }
        .task {
            // Kurulum yarıda kaldıysa (ör. TV uygulaması kurulurken kapatıldı) eşleşmiş TV'deki uygulamaya yeniden bakılır.
            if model.hasTV, model.tvApp == .unknown { Task { await model.refreshTVApp() } }
            await search()
        }
    }

    private func search() async {
        searching = true
        tvs = await model.discoverTVs()
        searching = false
    }

    private func pair(_ tv: LGTV) async {
        working = true
        pairingBrand = tv.brand
        error = nil
        do { try await model.pair(tv) } catch { self.error = Self.pairingMessage(for: error, brand: tv.brand) }
        working = false
        pairingBrand = nil
    }

    /// Bağlanamayınca ne yapılacağı. Samsung'da izin kutusu süresinde onaylanmadıysa ya da TV reddettiyse bunu söyler;
    /// önceden hepsi "TV yanıt vermedi" diyordu ve kullanıcı kutu çıkana kadar körlemesine yeniden deniyordu.
    static func pairingMessage(for error: Error, brand: TVBrand) -> String {
        if brand == .samsung, let samsung = error as? SamsungClient.SamsungError {
            switch samsung {
            case .rejected:
                return String(localized: "The TV refused the connection. Allow CouchSubs in Settings › General › External Device Manager › Device Connection Manager › Device List on the TV, then press Connect again.")
            case .cannotConnect:
                return String(localized: "The TV's permission box was not accepted within 60 seconds. If no box appeared, open the TV's home screen and press Connect again. If CouchSubs was denied before, allow it in Settings › General › External Device Manager › Device Connection Manager › Device List.")
            }
        }
        return String(localized: "The TV did not respond. Make sure it is on and on the same network.")
    }
}
