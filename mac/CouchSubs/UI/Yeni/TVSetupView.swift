// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

/// Kurulum › "Altyazı TV'de Görünsün" (yeni arayüz). Solda ağdaki TV'ler (her biri tıklanabilir kart, sağda durum
/// rozeti ve Bağlan), bulunamazsa olası nedenler, "TV Listede Yok mu?" (marka + IP) ve TV'siz seçenek. Sağda bağlantı ve
/// kurulum çizelgesi, hata kutusu (ne oldu, neden, çözüm, Tekrar Dene / Günlüğü Kopyala), markaya göre "Kurulumdan Önce
/// TV'de" listesi ve TV'nin gösterdiği eşleşme kodu. İşlev eski TVStep / TVAppCard ile aynı; yeni durum uydurulmaz.
struct TVSetupStep: View {
    /// Yalnız ekran görüntüsü testi: sahte liste ve durumlar.
    struct Preview {
        var tvs: [LGTV] = []
        var searching = false
        var pairingHost: String?
        var pairError: String?
    }
    @MainActor static var preview: Preview?

    @EnvironmentObject private var model: AppModel
    @State private var tvs: [LGTV] = []
    @State private var searching = false
    @State private var pairingHost: String?
    @State private var pairingBrand: TVBrand?
    @State private var pairError: String?
    @State private var lastPaired: LGTV?

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            VStack(spacing: DS.space("l")) {
                listCard
                TVManualAddCard(tvs: $tvs)
                otherChoices
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: DS.space("l")) {
                if showsProgress { TVProgressCard(brand: brand, pairing: currentPairingHost != nil) }
                errorBox
                interactiveCard
                // Vestel Linux (deneysel): TV'ye bilgisayar bağlanmaz; tek tuşla kurulum ve eşleştirme kendi kartında.
                if model.tv?.brand == .vestelLinux { DSCard(scrolls: false) { VestelTVCard() } }
                if needsChecklist { TVChecklistCard(brand: brand) }
                PairingCodeCard()
            }
            .frame(width: 380)
        }
        .task {
            if let preview = Self.preview {
                tvs = preview.tvs
                searching = preview.searching
                pairingHost = preview.pairingHost
                pairError = preview.pairError
                return
            }
            // Kurulum yarıda kaldıysa eşleşmiş TV'deki uygulamaya yeniden bakılır.
            if model.hasTV, model.tvApp == .unknown { Task { await model.refreshTVApp() } }
            await search()
        }
    }

    private var currentPairingHost: String? { pairingHost }
    private var brand: TVBrand { pairingBrand ?? model.tv?.brand ?? tvs.first?.brand ?? .lg }

    private var showsProgress: Bool { currentPairingHost != nil || model.tv != nil }

    /// Ön koşul listesi TV uygulaması kurulu değilken görünür.
    private var needsChecklist: Bool {
        guard model.tv != nil || !tvs.isEmpty else { return false }
        switch model.tvApp {
        case .upToDate, .working, .pressInstallOnTV, .approveOnTV: return false
        default: return true
        }
    }

    // MARK: TV listesi

    private var listCard: some View {
        DSCard(scrolls: false) {
            DSCardHeader("TVs on This Network") {
                Button(searching ? "Searching…" : "Search Again") { Task { await search() } }
                    .buttonStyle(DSButtonStyle(kind: .compact, busy: searching))
                    .disabled(searching)
            }
            if tvs.isEmpty {
                if searching {
                    // Arama halkası: TV'ler bulundukça kart kart belirir.
                    VStack(spacing: DS.space("m")) {
                        DSSearchRings(size: 72)
                        Text("Scanning the network…").font(.dsBodyStrong).foregroundStyle(Color.dsText)
                        Text("Looking for LG, Samsung and Android TVs on the same network.").dsMuted().multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.space("m"))
                } else {
                    emptyState
                }
            } else {
                VStack(spacing: DS.space("xs")) {
                    ForEach(tvs, id: \.host) { tv in
                        row(tv).transition(.opacity.combined(with: .offset(y: 14)))
                    }
                }
            }
        }
    }

    /// TV kartı (Perde): simge karesi, ad + mono marka · adres, durum hapı ve kartta küçük "Bağlan"; seçiliyken amber
    /// kenar + ışıma.
    private func row(_ tv: LGTV) -> some View {
        let status = status(of: tv)
        let selected = model.tv?.host == tv.host || currentPairingHost == tv.host
        return DSTVCard(name: tv.name.isEmpty ? TVBrandMark.name(tv.brand) : tv.name, detail: "\(TVBrandMark.name(tv.brand)) · \(tv.host)",
                        status: status.text, statusTone: status.tone, selected: selected, action: { Task { await pair(tv) } }) {
            if status == .found || status == .failed {
                Text("Connect")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsText)
                    .padding(.horizontal, DS.space("s"))
                    .frame(height: DS.size("chip"))
                    .background(Color.dsSurfaceRaised, in: Capsule(style: .circular))
                    .overlay(Capsule(style: .circular).inset(by: 0.5).stroke(Color.dsBorder))
            }
        }
        .disabled(currentPairingHost != nil)
        .accessibilityLabel(Text(verbatim: "\(tv.name) \(tv.host)"))
    }

    private var emptyState: some View {
        DSUnit(title: "No TV Found") {
            VStack(alignment: .leading, spacing: DS.space("xs")) {
                ForEach(Array(Self.reasons.enumerated()), id: \.offset) { index, reason in
                    HStack(alignment: .firstTextBaseline, spacing: DS.space("xs")) {
                        Text(verbatim: "\(index + 1).").font(.dsSmall.monospacedDigit()).foregroundStyle(Color.dsMuted)
                        Text(reason).font(.dsSmall).foregroundStyle(Color.dsText).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("You can also enter the TV's IP address below.").dsMuted().padding(.top, DS.unitHintGap)
            }
        }
    }

    static let reasons: [LocalizedStringKey] = [
        "Is the TV on? Turn it on with the remote and wait for the home screen.",
        "Is the TV on the same Wi-Fi network as this Mac?",
        "Guest networks and access point (AP) isolation stop devices from seeing each other; use the main network.",
        "Turn off any VPN on this Mac.",
    ]

    private var otherChoices: some View {
        VStack(spacing: DS.space("xs")) {
            Button { Task { await pair(LGTV(name: "Android TV", host: "", brand: .androidTV)) } } label: {
                HStack(spacing: DS.space("s")) {
                    TVBrandMark(brand: .androidTV)
                    DSTitleBlock(title: "Android TV / Google TV", subtitle: "Vestel, Arçelik, Beko, Grundig, Philips and other TVs running Android TV.",
                                 titleFont: .dsBodyStrong)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsFaint)
                }
            }
            .buttonStyle(DSOptionStyle(selected: model.tv?.brand == .androidTV, minHeight: 64, radio: false))
            .disabled(currentPairingHost != nil)
            Button { model.useComputerScreen() } label: {
                HStack(spacing: DS.space("s")) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DS.radius("chip"), style: .continuous).fill(Color.dsField)
                        Image(systemName: "laptopcomputer").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dsMuted)
                    }
                    .frame(width: 40, height: 40)
                    DSTitleBlock(title: "No TV? Show on the Computer Screen",
                                 subtitle: "Subtitles appear in a window over the game or PS Remote Play. You can connect a TV later.",
                                 titleFont: .dsBodyStrong)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsFaint)
                }
            }
            .buttonStyle(DSOptionStyle(selected: false, minHeight: 64, radio: false))
            .disabled(currentPairingHost != nil)
        }
    }

    // MARK: Durum

    enum RowStatus: Equatable {
        case found, connecting, approveOnTV, paired, installing, installed, needsUpdate, failed

        var text: LocalizedStringKey {
            switch self {
            case .found: "Found"
            case .connecting: "Connecting…"
            case .approveOnTV: "Waiting for Approval on the TV"
            case .paired: "Paired"
            case .installing: "Installing…"
            case .installed: "Installed ✓"
            case .needsUpdate: "Update Needed"
            case .failed: "Error"
            }
        }

        var tone: DSStatusChip.Tone {
            switch self {
            case .found: .muted
            case .connecting, .approveOnTV, .paired, .installing: .amber
            case .installed: .ok
            case .needsUpdate, .failed: .live
            }
        }
    }

    private func status(of tv: LGTV) -> RowStatus {
        if currentPairingHost == tv.host {
            // LG ve Samsung bağlanırken TV'de izin sorulur.
            return tv.brand.connectsByItself ? .connecting : .approveOnTV
        }
        if pairError != nil, lastPaired?.host == tv.host { return .failed }
        guard model.tv?.host == tv.host else { return .found }
        if model.tvAppOutdated != nil { return .needsUpdate }
        switch model.tvApp {
        case .working, .pressInstallOnTV, .signIn: return .installing
        case .upToDate: return .installed
        case .failed, .needsPassphrase(error: .some(_)): return .failed
        case .approveOnTV: return .approveOnTV
        default: return .paired
        }
    }

    // MARK: Hata

    @ViewBuilder private var errorBox: some View {
        if let pairError {
            DSErrorBox(title: "Couldn't Connect to the TV", message: pairError) {
                if let lastPaired { Button("Try Again") { Task { await pair(lastPaired) } }.buttonStyle(DSButtonStyle(kind: .compact)) }
            }
        } else if case .failed(let error, let reason) = model.tvApp {
            DSErrorBox(title: TVErrorTitle.title(error), message: TVAppCard.message(for: error, brand: brand, reason: reason, address: model.computerAddress)) {
                Button("Try Again") { Task { await model.refreshTVApp() } }.buttonStyle(DSButtonStyle(kind: .compact))
                if error == .foreignApp {
                    Button("Remove the Old App on the TV") { Task { await model.replaceForeignTVApp() } }
                        .buttonStyle(DSButtonStyle(kind: .compact))
                }
            }
        } else if case .needsPassphrase(let error?) = model.tvApp {
            DSErrorBox(title: TVErrorTitle.title(error), message: TVAppCard.message(for: error, brand: .lg)) { EmptyView() }
        }
    }

    /// Eski karttaki etkileşimli durumlar (Samsung girişi, Host PC IP uyuşmazlığı, iki Android TV, Google Play'de Yükle).
    @ViewBuilder private var interactiveCard: some View {
        switch model.tvApp {
        case .signIn, .hostPcMismatch, .chooseAndroidTV, .pressInstallOnTV:
            DSCard(scrolls: false) { TVAppCard() }
        default:
            EmptyView()
        }
    }

    // MARK: İşler

    private func search() async {
        searching = true
        tvs = await model.discoverTVs()
        searching = false
    }

    private func pair(_ tv: LGTV) async {
        pairingHost = tv.host
        pairingBrand = tv.brand
        lastPaired = tv
        pairError = nil
        do { try await model.pair(tv) } catch { pairError = TVStep.pairingMessage(for: error, brand: tv.brand) }
        pairingHost = nil
    }
}

// MARK: Marka işareti

struct TVBrandMark: View {
    let brand: TVBrand

    static func name(_ brand: TVBrand) -> String {
        switch brand {
        case .lg: "LG"
        case .samsung: "Samsung"
        case .androidTV: "Android TV"
        case .vestelLinux: "Vestel Linux"
        }
    }

    var body: some View {
        let short = switch brand {
        case .lg: "LG"
        case .samsung: "SAMSUNG"
        case .androidTV: "Android"
        case .vestelLinux: "VESTEL"
        }
        Text(verbatim: short)
            .font(.system(size: brand == .lg ? 14 : 9, weight: .heavy))
            .foregroundStyle(Color.dsCharcoal)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 40, height: 40)
            .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.radius("chip"), style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: Elle ekleme

/// "TV Listede Yok mu?": marka seçici, tam yuvarlak IP kutusu ve kutunun içinde küçük Ekle; IP biçimi denetlenir.
struct TVManualAddCard: View {
    @Binding var tvs: [LGTV]
    @State private var brand: TVBrand = .lg
    @State private var host = ""
    @State private var error: String?

    var body: some View {
        DSCard(scrolls: false) {
            DSCardHeader("TV Not in the List?")
            DSUnit(title: "Brand") {
                DSTabs(selection: $brand, items: [(TVBrand.lg, "LG"), (.samsung, "Samsung"), (.androidTV, "Android TV"), (.vestelLinux, "Vestel Linux")])
            }
            DSUnit(title: "TV's IP Address", hint: hint) {
                DSFieldChrome(mono: true) {
                    TextField("IP address, e.g. 192.168.1.20", text: $host)
                        .textFieldStyle(.plain)
                        .onSubmit(add)
                } trailing: {
                    Button("Add", action: add)
                        .buttonStyle(DSButtonStyle(kind: .compact))
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let error {
                Text(verbatim: error).font(.dsSmall).foregroundStyle(Color.dsLiveText).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hint: LocalizedStringKey {
        switch brand {
        case .androidTV: "You can see the TV's address on the TV in Settings › Network & Internet."
        case .vestelLinux: "Vestel TVs with Vestel's own system (not Android TV), experimental. Automatic search is not available; the address is in the TV's network settings."
        default: "TV not in the list? Enter its IP address (on the TV under Settings › Network)."
        }
    }

    private func add() {
        guard let address = ManualAddress.normalize(host) else {
            error = String(localized: "This is not a valid IP address. Type it like 192.168.1.20, without http:// or a port number.")
            return
        }
        error = nil
        if !tvs.contains(where: { $0.host == address }) {
            tvs.append(LGTV(name: TVBrandMark.name(brand), host: address, brand: brand))
        }
        host = ""
    }
}

// MARK: Çizelge

/// Bağlan / Kur çizelgesi: Bağlanılıyor → TV'de Onay → Kuruluyor → Hazır. Durumlar modelin kendi durumlarından
/// (eşleştirme sürüyor, tvApp); bir adım uzun sürerse altında ipucu.
struct TVProgressCard: View {
    let brand: TVBrand
    let pairing: Bool
    @EnvironmentObject private var model: AppModel
    @State private var since = Date()
    @State private var slow = false

    enum Phase: Int { case pending, active, done, failed }

    private var steps: [(LocalizedStringKey, Phase, LocalizedStringKey?)] {
        let app = model.tvApp
        let paired = model.tv != nil && !pairing
        let installing: Bool = {
            switch app {
            case .working, .pressInstallOnTV, .signIn, .needsPassphrase, .devModeOff, .hostPcMismatch, .chooseAndroidTV: true
            default: false
            }
        }()
        let installed: Bool = { if case .upToDate = app { true } else { false } }()
        let failed: Bool = { if case .failed = app { true } else { false } }()
        let approveActive = (pairing && !brand.connectsByItself) || app == .approveOnTV
        let approveDone = paired && app != .approveOnTV && (!brand.connectsByItself || installing || installed)
        return [
            ("Connecting", pairing ? .active : paired ? .done : .pending, nil),
            ("Approve on the TV", approveActive ? .active : approveDone ? .done : .pending,
             "Confirm the permission shown on the TV screen with the remote."),
            ("Installing the TV App", failed ? .failed : installed ? .done : installing ? .active : .pending,
             "Keep the TV on and follow the steps on this screen; installing can take a minute."),
            ("Ready", installed ? .done : .pending, nil),
        ]
    }

    var body: some View {
        let list = steps
        let activeIndex = list.firstIndex { $0.1 == .active }
        let installed: Bool = { if case .upToDate = model.tvApp { true } else { false } }()
        DSCard(scrolls: false) {
            DSCardHeader("Connection and Install")
            // Adım çizelgesi: biten amber + tik, şimdiki amber halka (hata olunca da şimdiki; neden hata kutusunda).
            DSStepTimeline(steps: list.map(timelineStep))
            if installed {
                // TV uygulaması kuruldu: başarı anı (≤ 1 sn).
                DSSuccessMoment(title: "Ready")
            }
        }
        .onChange(of: activeIndex) { _ in
            since = Date()
            slow = false
        }
        .task(id: activeIndex) {
            // Bir adım 15 sn'den uzun sürerse altında ipucu.
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { slow = true }
        }
    }

    private func timelineStep(_ step: (LocalizedStringKey, Phase, LocalizedStringKey?)) -> DSStepTimeline.Step {
        let state: DSStepTimeline.Phase
        switch step.1 {
        case .done: state = .done
        case .active, .failed: state = .current
        case .pending: state = .todo
        }
        let detail: LocalizedStringKey? = step.1 == .active && slow ? step.2 : nil
        return DSStepTimeline.Step(title: step.0, detail: detail, state: state)
    }
}

// MARK: Ön koşullar

/// "Kurulumdan Önce TV'de": markaya göre numaralı kısa adımlar (metinler eski kurulum kartından). LG'de Key Server
/// parolası alanı, Samsung'da bu Mac'in adresi (Host PC IP) kopyala simgeli kutuda.
struct TVChecklistCard: View {
    let brand: TVBrand
    @EnvironmentObject private var model: AppModel
    @State private var passphrase = ""

    var body: some View {
        DSCard(scrolls: false) {
            DSCardHeader("Before Installing, on the TV")
            VStack(alignment: .leading, spacing: DS.space("s")) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    TVChecklistRow(number: index + 1, text: item.0, how: item.1)
                }
            }
            if brand == .samsung {
                DSUnit(title: "This Mac's Address (Host PC IP)", hint: otherAddresses) {
                    DSCopyField(text: model.computerAddress ?? "?")
                }
            }
            if brand == .lg {
                DSUnit(title: "Passphrase", hint: "Open the Developer Mode app on the TV, turn on Key Server and keep the app on screen. Type the Passphrase it shows.") {
                    DSFieldChrome(mono: true) {
                        TextField("Passphrase", text: $passphrase).textFieldStyle(.plain)
                    } trailing: {
                        Button("Install on the TV") { Task { await model.installTVApp(passphrase: passphrase) } }
                            .buttonStyle(DSButtonStyle(kind: .compact))
                            .disabled(passphrase.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .task(id: model.tvApp == .devModeOff) {
            // Geliştirici modu açılınca kendiliğinden devam eder (eski kartla aynı).
            while !Task.isCancelled, model.tvApp == .devModeOff {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await model.refreshTVApp()
            }
        }
    }

    private var otherAddresses: LocalizedStringKey? {
        let others = model.otherComputerAddresses
        return others.isEmpty ? nil : "If the TV does not accept this address, try one of this computer's other addresses: \(others.joined(separator: ", "))"
    }

    private var items: [(LocalizedStringKey, LocalizedStringKey?)] {
        switch brand {
        case .lg:
            [("1. Create a free account at webostv.developer.lge.com.", nil),
             ("2. On the TV, install Developer Mode from the LG Content Store and sign in.", nil),
             ("3. Turn on Dev Mode Status. The TV restarts and this screen continues by itself.", nil)]
        case .samsung:
            [("1. On the TV, open Apps and scroll to the very bottom of the page.", nil),
             ("2. There, press 1 2 3 4 5 on the remote (or type 12345 on the on-screen keypad). The Developer Mode window opens.", nil),
             ("3. Turn Developer mode On, type this computer's address as Host PC IP: \(model.computerAddress ?? "?") and press OK.", nil),
             ("4. Restart the TV: hold the power button on the remote and keep holding until the TV turns off and comes back on with the Samsung logo (about 5 seconds); letting go when it turns off only puts it on standby. If no logo appears, unplug the TV for 30 seconds. This screen continues by itself.",
              "Later you sign in once with a free Samsung account; Samsung needs it to sign the app for your TV.")]
        case .androidTV:
            [("1. On the TV, open Settings › Device Preferences › About (Google TV: Settings › System › About).", nil),
             ("2. Press OK on Build 7 times until it says you are a developer.", nil),
             ("3. Go back to Device Preferences (Google TV: System) › Developer options and turn on USB debugging. Turn on Network debugging too if you see it.",
              "Menu names differ a little by brand. If the app is already on the TV, you can skip this step.")]
        case .vestelLinux:
            [("1. Once: turn on the TV's test-tool socket with a DevProfile file on a USB stick (service menu 4725 › USB Diagnostic), then turn the TV off and on after a minute.",
              "Tested on a Vestel 55UD8400 (MB130). Without this step one-tap install cannot reach the TV."),
             ("2. Add the TV with its IP address above, press Connect, then Install and start on the TV.", nil)]
        }
    }
}

/// Ön koşul satırı: metin (başındaki numara metnin parçası), varsa küçük "Nasıl?" açılırı.
private struct TVChecklistRow: View {
    let number: Int
    let text: LocalizedStringKey
    let how: LocalizedStringKey?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.unitHintGap) {
            Text(text).font(.dsSmall).foregroundStyle(Color.dsText).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            if let how {
                Button {
                    withAnimation(DS.animation(.short, reduced: false)) { open.toggle() }
                } label: {
                    HStack(spacing: DS.space("xxs")) {
                        Text("How?")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(Color.dsAmberText)
                }
                .buttonStyle(.plain)
                if open { Text(how).dsMuted().transition(.opacity) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Hata kutusu

/// Hata kutusu: kırmızımsı ince kenarlık, başlık (ne oldu), açıklama paragrafları (neden ve çözüm, numaralı), altta
/// düğmeler ve her zaman "Günlüğü Kopyala".
struct DSErrorBox<Actions: View>: View {
    let title: LocalizedStringKey
    let message: String
    @ViewBuilder var actions: Actions
    @State private var copied = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
        let parts = message.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: DS.space("s")) {
            HStack(spacing: DS.space("xs")) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Color.dsLive).accessibilityHidden(true)
                Text(title).font(.dsBodyStrong).foregroundStyle(Color.dsText)
            }
            if let first = parts.first {
                Text(verbatim: first).font(.dsSmall).foregroundStyle(Color.dsText).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(Array(parts.dropFirst().enumerated()), id: \.offset) { index, part in
                HStack(alignment: .firstTextBaseline, spacing: DS.space("xs")) {
                    Text(verbatim: "\(index + 1).").font(.dsSmall.monospacedDigit()).foregroundStyle(Color.dsMuted)
                    Text(verbatim: part).font(.dsSmall).foregroundStyle(Color.dsMuted).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: DS.space("xs")) {
                actions
                Button(copied ? "Log Copied" : "Copy Log") { copyLog() }.buttonStyle(DSButtonStyle(kind: .compact))
            }
            .padding(.top, DS.space("xxs"))
        }
        .padding(DS.space("m"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsLiveSoft, in: shape)
        .overlay(shape.strokeBorder(Color.dsLiveRing, lineWidth: 1))
    }

    private func copyLog() {
        let header = "CouchSubs \(AppIdentity.version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        Task.detached(priority: .userInitiated) {
            guard let file = try? LogArchive.make(header: header) else { return }
            await MainActor.run {
                LogArchive.copyToPasteboard(file)
                copied = true
            }
        }
    }
}

/// Kurulum hatalarının kısa başlığı (ne oldu); ayrıntı ve çözüm TVAppCard.message'da.
enum TVErrorTitle {
    static func title(_ error: DevModeError) -> LocalizedStringKey {
        switch error {
        case .unreachable: "The TV Didn't Respond"
        case .devConnectionClosed: "The TV Refused the Connection"
        case .keyServerOff: "Key Server Is Off"
        case .wrongPassphrase: "Wrong Passphrase"
        case .keyRefused: "The TV Refused the Key"
        case .installFailed: "The TV App Couldn't Be Installed"
        case .tooOld: "This TV Is Too Old"
        case .signInFailed: "Samsung Sign-In Didn't Complete"
        case .certificateFailed: "No Signing Certificate"
        case .notApproved: "Debugging Wasn't Allowed"
        case .notEnoughSpace: "The TV Is Out of Space"
        case .certificateMismatch: "An Old Copy Is on the TV"
        case .certificateRejected: "The TV Rejected the Certificate"
        case .tvClockWrong: "The TV's Clock Is Behind"
        case .packageBlocked: "The TV Blocks CouchSubs"
        case .connectionLost: "The Connection Dropped"
        case .foreignApp: "Another App Is Installed"
        case .tvNotResponding: "The TV Isn't Responding"
        }
    }
}
