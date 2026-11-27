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
    /// Aramada çıkmayan TV'nin elle yazılan adresi (webOS 3.x gibi, #498).
    @State private var manualHost = ""
    @State private var adding = false
    /// Vestel Linux TV'nin elle yazılan adresi (otomatik arama yok).
    @State private var vestelHost = ""

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
                    HintText(text: "TV not in the list? Enter its IP address (on the TV under Settings › Network).")
                    HStack {
                        TextField("IP address, e.g. 192.168.1.20", text: $manualHost)
                            .textFieldStyle(CSTextFieldStyle())
                            .onSubmit { Task { await addManual() } }
                        Button("Add") { Task { await addManual() } }.buttonStyle(.secondary).disabled(adding)
                    }
                    // Alanın hangi TV'ler için olduğu: yazılan adresin türü TV'ye sorulur, Android TV de tanınır.
                    HintText(text: "For LG, Samsung and Android TV / Google TV: CouchSubs asks the TV at this address which kind it is.")
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
                // Vestel'in kendi Linux'u (Android olmayan Vestel TV'ler): TV'deki yerel istemci bu Mac'e bağlanır. Deneysel.
                Card {
                    HStack(spacing: Theme.space("s")) {
                        Text(verbatim: "Vestel Linux TV")
                        Text("Experimental").font(.csCaption).foregroundStyle(Color.csWarning)
                        Spacer()
                    }
                    HintText(text: "Vestel TVs that run Vestel's own system instead of Android TV (for example 2017 models). A small client on the TV connects to this Mac.")
                    HStack {
                        TextField("TV IP address, e.g. 192.168.1.54", text: $vestelHost)
                            .textFieldStyle(CSTextFieldStyle())
                            .onSubmit { Task { await chooseVestel() } }
                        Button("Select") { Task { await chooseVestel() } }.buttonStyle(.secondary).disabled(working)
                    }
                    HintText(text: "Automatic search is not available for these TVs yet. You can find the IP address in the TV's network settings.")
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
                VestelTVCard()
                // Uygulamayla TV paketi gelmediyse (geliştirici derlemesi) rehber gösterilir. Vestel Linux'un kendi kartı var.
                if let tv = model.tv, tv.brand != .lg, tv.brand != .vestelLinux, !model.canInstallTVApp {
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

    /// Elle yazılan adres listeye eklenir; TV'nin türü (LG, Samsung, Android TV) TV'ye sorulur (`ManualTV`). Android TV'de
    /// "Bağlan" Android TV akışını o adresle başlatır; önceden adres LG sayılıyor, LG eşleştirmesi "TV yanıt vermedi"
    /// diyordu. Hiçbir yoklamaya yanıt gelmezse TV LG sayılır (webOS 3 cihaz tanımını her zaman vermiyor) ve bu söylenir.
    private func addManual() async {
        error = nil
        guard let host = ManualAddress.normalize(manualHost) else {
            error = String(localized: "This is not a valid IP address. Type it like 192.168.1.20, without http:// or a port number.")
            return
        }
        guard !tvs.contains(where: { $0.host == host }) else { return }
        adding = true
        let manual = await ManualTV.tv(at: host)
        tvs.append(manual.tv)
        if !manual.recognised {
            error = String(format: String(localized: "No TV at %@ answered as an LG, Samsung or Android TV, so it was added as an LG TV. If it is an Android TV / Google TV, press Select under Android TV / Google TV below."), host)
        }
        manualHost = ""
        adding = false
    }

    /// Vestel Linux TV: adres doğrulanır ve TV seçilir. Bilgisayar TV'ye bağlanmaz; adres bu Mac'in TV'ye bakan ağ
    /// adresini bulmak (TV'deki komut) ve kullanıcıya göstermek içindir.
    private func chooseVestel() async {
        error = nil
        guard let host = ManualAddress.normalize(vestelHost) else {
            error = String(localized: "This is not a valid IP address. Type it like 192.168.1.20, without http:// or a port number.")
            return
        }
        await pair(LGTV(name: "Vestel Linux TV", host: host, brand: .vestelLinux))
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
            case .notInstalled:
                break
            }
        }
        // Vestel Linux'ta bilgisayar TV'ye bağlanmaz; burada yalnız altyazı sunucusu açılamamış olabilir.
        if brand == .vestelLinux {
            return String(localized: "CouchSubs could not start its subtitle server. Close other apps that may use the same port and try again.")
        }
        return String(localized: "The TV did not respond. Make sure it is on and on the same network.")
    }
}
