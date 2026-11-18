// SPDX-License-Identifier: AGPL-3.0-only
// TV uygulamasını bilgisayarsız, bu iPhone'dan kurmak ve güncellemek (Android'deki TvInstallScreen, AndroidTvInstallScreen,
// LgInstallScreen ile aynı akış). Ayarlar'dan, altyazı hedefi ekranından ve ana ekrandaki güncelleme kartından açılır.

import CouchSubsCore
import SafariServices
import SwiftUI
import WebKit

/// Kurulumun durumu (her marka için aynı).
enum TVInstallPhase: Equatable {
    case idle
    case working(InstallStep)
    case done(version: String, installed: Bool)
    case failed(text: String)

    var isWorking: Bool { if case .working = self { true } else { false } }
    var isDone: Bool { if case .done = self { true } else { false } }
}

struct TVInstallScreen: View {
    @EnvironmentObject private var model: PhoneModel
    /// Ana ekrandaki "TV uygulamasını güncelle": o TV'nin kurulumu kendiliğinden başlar.
    var update: TVAppUpdate?
    /// Kurulum bitince "Ana ekrana geç" (Android'deki onDone); verilmezse ekran kapanır.
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var brand: TVBrand?
    @State private var working = false

    private func finish() { if let onDone { onDone() } else { dismiss() } }

    var body: some View {
        MobileScreen {
            BackHeader(title: LocalizedStringKey(TVText.title))
        } content: {
            if let brand {
                if !working {
                    SegmentedTabs(options: [TVBrand.samsung: "Samsung", .lg: "LG", .androidTV: "Android TV"], selection: Binding(
                        get: { brand }, set: { self.brand = $0 }))
                }
                switch brand {
                case .samsung: SamsungInstallSection(update: update?.brand == .samsung ? update : nil, working: $working, onDone: finish)
                case .androidTV: AndroidTVInstallSection(update: update?.brand == .androidTV ? update : nil, working: $working, onDone: finish)
                case .lg: LGInstallSection(update: update?.brand == .lg ? update : nil, working: $working, onDone: finish)
                }
            } else {
                HStack(spacing: Mobile.Space.gap) {
                    ProgressView().tint(Mobile.Palette.accent)
                    Text(verbatim: TVText.searching).font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary)
                }
            }
        } bottom: {
            EmptyView()
        }
        .task {
            guard brand == nil else { return }
            // Marka: güncellenen TV, bu telefonun kurduğu TV, eşlenen TV; yoksa ağda ilk görülen TV.
            if let known = update?.brand ?? model.installedTVApp?.brand ?? model.tv?.brand {
                brand = known
            } else {
                brand = await model.discoverTVs().first?.brand ?? .samsung
            }
        }
    }
}

// MARK: - Ortak parçalar

/// Kurulum adımının metni.
func installStepText(_ step: InstallStep) -> String {
    switch step {
    case .pairing: TVText.stepPairing
    case .approveOnTV: TVText.stepApprove
    case .key: TVText.stepKey
    case .openPlay: TVText.stepPlay
    case .connecting: TVText.stepConnecting
    case .reading: TVText.stepReading
    case .signIn: TVText.stepSignin
    case .certificate: TVText.stepCertificate
    case .signing: TVText.stepSigning
    case .installing: TVText.stepInstalling
    case .uninstalling: TVText.stepUninstalling
    case .launching: TVText.stepLaunching
    }
}

/// Başlık, açıklama ve bilgi notu.
struct InstallIntro: View {
    let body1: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.inline) {
            Text(verbatim: body1).font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: note).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Numaralı adımlar karosu.
struct InstallSteps: View {
    let title: String
    let steps: [String]
    var highlight: String?
    var after: [String] = []

    var body: some View {
        Tile {
            Text(verbatim: title).font(Mobile.TypeScale.headline)
            ForEach(steps, id: \.self) { step in
                Text(verbatim: step).font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let highlight { Text(verbatim: highlight).font(Mobile.TypeScale.title).foregroundStyle(Mobile.Palette.accent).textSelection(.enabled) }
            ForEach(after, id: \.self) { step in
                Text(verbatim: step).font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Ağda görülen bir TV satırı.
struct InstallCandidateRow: View {
    let name: String
    let detail: String
    var status: (String, Bool)?
    let selected: Bool

    var body: some View {
        Tile(emphasis: selected ? .selected : .none) {
            HStack(spacing: Mobile.Space.gap) {
                MobileTileIcon(symbol: "tv")
                VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                    Text(verbatim: name).font(Mobile.TypeScale.headline)
                    Text(verbatim: detail).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    if let status {
                        Text(verbatim: status.0).font(Mobile.TypeScale.caption).foregroundStyle(status.1 ? Mobile.Palette.success : Mobile.Palette.warning)
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Mobile.Palette.accent) }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Kurulumun sonucu: ilerleme, başarı ya da ne yapılacağı (ve günlüğü paylaşma).
struct InstallResult: View {
    let phase: TVInstallPhase

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .working(let step):
            Tile {
                HStack(spacing: Mobile.Space.gap) {
                    ProgressView().tint(Mobile.Palette.accent)
                    Text(verbatim: installStepText(step)).font(Mobile.TypeScale.body).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .done(let version, let installed):
            Tile(emphasis: .selected) {
                Label(installed ? TVText.done(version) : TVText.upToDate(version), systemImage: "checkmark.circle.fill")
                    .font(Mobile.TypeScale.headline).foregroundStyle(Mobile.Palette.text)
                Text(verbatim: TVText.next)
                    .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let text):
            MobileNote(text: text)
            ShareLink(item: InstallLog.shared.file) { Text(verbatim: TVText.shareLog) }
                .font(Mobile.TypeScale.caption).tint(Mobile.Palette.accent)
        }
    }
}

/// Telefonun TV ile aynı ağdaki adresi (Samsung'da Host PC IP olarak yazılır).
func phoneAddress(near host: String?) -> String? { NetworkAddress.near(host?.isEmpty == false ? host : nil) }

/// TV'nin adresi yazılan alan (Android'deki TvAddressField ile aynı): etiket adresin TV'de nerede yazdığını söyler, altında
/// bu telefonun adresi durur. İki kullanıcı TV'nin kutusuna telefonun/bilgisayarın adresini yazmıştı (#343); aynısı
/// yazılınca kurulum düğmesi kapanır ve uyarı çıkar.
struct TVAddressField: View {
    let label: String
    @Binding var text: String
    var placeholder: String? = TVText.addressExample
    var keyboard: UIKeyboardType = .decimalPad

    var body: some View {
        let phone = phoneAddress(near: nil)
        VStack(alignment: .leading, spacing: Mobile.Space.hair) {
            Text(verbatim: label).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
            TextField(placeholder ?? label, text: $text)
                .textFieldStyle(MobileFieldStyle()).keyboardType(keyboard).autocorrectionDisabled().textInputAutocapitalization(.never)
            if NetworkAddress.isOwnAddress(text, own: phone) {
                MobileNote(text: TVText.addressIsPhone)
            } else if let phone {
                Text(verbatim: TVText.addressNotPhone(phone)).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
            }
        }
    }
}

/// Ağın /24 bölümünde `port`u açık adresler (Android'deki gibi en çok 32 paralel deneme).
func scanSubnet(port: UInt16, near host: String?) async -> [String] {
    guard let phone = phoneAddress(near: host), let dot = phone.lastIndex(of: ".") else { return [] }
    let prefix = phone[..<dot]
    let addresses = (1...254).map { "\(prefix).\($0)" }.filter { $0 != phone }
    return await withTaskGroup(of: String?.self) { group in
        var found: [String] = []
        var next = 0
        func add() {
            guard next < addresses.count else { return }
            let address = addresses[next]
            next += 1
            group.addTask { PosixSocket.isOpen(host: address, port: port, timeout: 0.7) ? address : nil }
        }
        for _ in 0..<32 { add() }
        while let result = await group.next() {
            if let result { found.append(result) }
            add()
        }
        return found.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }
}

/// Kurulum, bloklayan kodu arka planda çalıştırır; adımlar ana iş parçacığına gelir.
func runInstall<T: Sendable>(_ work: @escaping @Sendable (@escaping @Sendable (InstallStep) -> Void) throws -> T,
                             progress: @escaping @MainActor (InstallStep) -> Void) async throws -> T {
    try await Task.detached(priority: .userInitiated) {
        try work { step in Task { @MainActor in progress(step) } }
    }.value
}

// MARK: - Samsung

struct SamsungInstallSection: View {
    @EnvironmentObject private var model: PhoneModel
    let update: TVAppUpdate?
    @Binding var working: Bool
    let onDone: () -> Void
    @State private var candidates: [(tv: LGTV, info: SamsungTvInfo?)]?
    @State private var host = ""
    @State private var manual = false
    @State private var phase = TVInstallPhase.idle
    @State private var login: SamsungLogin.Listener?
    @State private var started = false

    var body: some View {
        InstallIntro(body1: TVText.body, note: TVText.samsungNote)
        Text(verbatim: TVText.tvs).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
        if let candidates {
            if candidates.isEmpty { MobileNote(text: TVText.none, tone: Mobile.Palette.secondary) }
            ForEach(candidates, id: \.tv.host) { item in
                Button { if !phase.isWorking { host = item.tv.host } } label: {
                    InstallCandidateRow(name: item.info?.name ?? item.tv.name, detail: [item.info?.model, item.tv.host].compactMap { $0 }.joined(separator: " · "),
                                        status: developerState(item.info), selected: host == item.tv.host)
                }
                .buttonStyle(.plain)
            }
        } else {
            ProgressView().tint(Mobile.Palette.accent)
        }
        if manual {
            TVAddressField(label: TVText.address, text: $host, keyboard: .decimalPad)
        } else if !phase.isWorking {
            Button(TVText.notFound) { manual = true }.buttonStyle(.mobileGhost)
        }
        InstallSteps(title: TVText.stepsTitle, steps: [TVText.step1, TVText.step2, TVText.step3],
                     highlight: phoneAddress(near: host) ?? TVText.phoneIpUnknown, after: [TVText.step4])
        Text(verbatim: TVText.signinNote).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary).fixedSize(horizontal: false, vertical: true)
        InstallResult(phase: phase)
        Group {
            if phase.isDone {
                Button(TVText.goHome, action: onDone).buttonStyle(.mobilePrimary)
            } else {
                Button(phase == .idle || phase.isWorking ? TVText.button : TVText.retry) { install() }
                    .buttonStyle(.mobilePrimary)
                    .disabled(phase.isWorking || host.trimmingCharacters(in: .whitespaces).isEmpty
                              || NetworkAddress.isOwnAddress(host, own: phoneAddress(near: nil)))
            }
        }
            .task { await search() }
            .sheet(isPresented: Binding(get: { login != nil }, set: { if !$0 { login?.close(); login = nil } })) {
                SamsungSignInSheet { login?.close(); login = nil }
            }
    }

    private func developerState(_ info: SamsungTvInfo?) -> (String, Bool)? {
        guard let mode = info?.developerMode else { return nil }
        if !mode { return (TVText.devOff, false) }
        if let ip = info?.developerIp, let phone = phoneAddress(near: host), ip != phone { return (TVText.devOtherIp(ip), false) }
        return (TVText.devOn, true)
    }

    private func search() async {
        guard candidates == nil else { return }
        if let update { host = update.host }
        var found = await SamsungDiscovery.search()
        if let known = model.tv, known.brand == .samsung, !known.host.isEmpty, !found.contains(where: { $0.host == known.host }) { found.insert(known, at: 0) }
        var list: [(tv: LGTV, info: SamsungTvInfo?)] = []
        for tv in found { list.append((tv, await SamsungTvInfo.fetch(host: tv.host))) }
        candidates = list
        if host.isEmpty, let first = list.first { host = first.tv.host }
        if list.isEmpty { manual = true }
        if update != nil, !started {
            started = true
            install()
        }
    }

    private func install() {
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        phase = .working(.connecting)
        working = true
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            defer {
                working = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do {
                let result = try await runInstall({ progress in
                    try SamsungInstaller(host: target, signIn: {
                        // Giriş sayfası açılır; Samsung jetonu bu telefondaki dinleyiciye gönderince devam edilir.
                        let listener = try SamsungLogin.Listener()
                        DispatchQueue.main.async { login = listener }
                        defer { DispatchQueue.main.async { login = nil } }
                        return try listener.await(timeout: 600)
                    }, progress: progress).ensureInstalled(wgt: { try TVPackages.samsungPackage() }, version: TVPackages.samsungVersion)
                }, progress: { step in if phase.isWorking { phase = .working(step) } })
                phase = .done(version: result.version, installed: result.installed)
                await model.tvAppInstalled(brand: .samsung, host: target, port: nil, version: result.version)
            } catch let failure as SamsungInstallFailure {
                phase = .failed(text: failureText(failure, phone: phoneAddress(near: target)))
            } catch {
                phase = .failed(text: TVText.errFailed + "\n\n" + TVText.details("\(error)"))
            }
        }
    }

    private func failureText(_ failure: SamsungInstallFailure, phone: String?) -> String {
        var text: String = switch failure.error {
        case .unreachable: TVText.errUnreachable(phone ?? "?")
        case .tooOld: TVText.errTooOld
        case .loginFailed: TVText.errLogin
        case .certificateFailed: TVText.errCertificate
        case .notEnoughSpace: TVText.errSpace
        case .certificateMismatch: TVText.errMismatch
        case .certificateRejected: TVText.errRejected
        case .tvClockWrong: TVText.errClock
        case .packageBlocked: TVText.errBlocked
        case .connectionLost: TVText.errConnection
        case .installFailed: TVText.errFailed
        }
        if let detail = failure.detail, !detail.isEmpty { text += "\n\n" + TVText.details(detail) }
        if failure.error == .installFailed || failure.error == .certificateRejected { text += "\n\n" + TVText.maintenance }
        return text
    }
}

/// Samsung'un giriş sayfası (uygulama içinde): sayfa jetonu bu telefonun localhost'undaki dinleyiciye gönderir.
struct SamsungSignInSheet: View {
    let onClose: () -> Void
    @State private var safari = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Mobile.Space.gap) {
                IconButton(symbol: "xmark", label: "Close", action: onClose)
                Text(verbatim: TVText.signinTitle).font(Mobile.TypeScale.title)
                Spacer()
                IconButton(symbol: "safari", label: "Safari") { safari = true }
            }
            .padding(Mobile.Space.screen)
            SamsungWebView(url: SamsungLogin.authorizeURL)
        }
        .background(Mobile.Palette.bg)
        .sheet(isPresented: $safari) { SafariView(url: SamsungLogin.authorizeURL) }
    }
}

struct SamsungWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.isOpaque = false
        view.backgroundColor = UIColor(Mobile.Palette.bg)
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Safari görünümü: uygulama önde kaldığı için localhost dinleyicisi girişi yine alır.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

// MARK: - Android TV

struct AndroidTVInstallSection: View {
    @EnvironmentObject private var model: PhoneModel
    let update: TVAppUpdate?
    @Binding var working: Bool
    let onDone: () -> Void
    @State private var candidates: [(host: String, debugging: Bool)]?
    @State private var address = ""
    @State private var wireless = false
    @State private var pairAddress = ""
    @State private var pairCode = ""
    @State private var phase = TVInstallPhase.idle
    @State private var replaceNeeded = false
    @State private var started = false

    var body: some View {
        InstallIntro(body1: TVText.androidBody, note: TVText.androidNote)
        Text(verbatim: TVText.androidTvs).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
        if let candidates {
            if candidates.isEmpty { MobileNote(text: TVText.androidNone, tone: Mobile.Palette.secondary) }
            ForEach(candidates, id: \.host) { item in
                Button { if !phase.isWorking { address = item.host } } label: {
                    InstallCandidateRow(name: "Android TV", detail: item.host,
                                        status: item.debugging ? (TVText.androidDebugOn, true) : (TVText.androidDebugOff, false),
                                        selected: AndroidTvInstaller.parseAddress(address)?.0 == item.host)
                }
                .buttonStyle(.plain)
            }
        } else {
            ProgressView().tint(Mobile.Palette.accent)
        }
        Text(verbatim: TVText.androidMode).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
        SegmentedTabs(options: [false: LocalizedStringKey(TVText.androidModeNetwork), true: LocalizedStringKey(TVText.androidModeWireless)],
                      selection: $wireless)
        TVAddressField(label: wireless ? TVText.androidAddressWireless : TVText.androidAddress, text: $address,
                       placeholder: wireless ? nil : TVText.addressExample, keyboard: .numbersAndPunctuation)
        if wireless {
            TextField(TVText.androidPairAddress, text: $pairAddress)
                .textFieldStyle(MobileFieldStyle()).keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField(TVText.androidPairCode, text: $pairCode).textFieldStyle(MobileFieldStyle()).keyboardType(.numberPad)
        }
        InstallSteps(title: TVText.androidStepsTitle,
                     steps: wireless ? [TVText.androidStep1, TVText.androidWirelessStep2, TVText.androidWirelessStep3]
                        : [TVText.androidStep1, TVText.androidStep2, TVText.androidStep3])
        InstallResult(phase: phase)
        if replaceNeeded, !phase.isWorking {
            Button(TVText.androidReplace) { install(allowReplace: true) }.buttonStyle(.mobileDestructive)
        }
        Group {
            if phase.isDone {
                Button(TVText.goHome, action: onDone).buttonStyle(.mobilePrimary)
            } else {
                Button(phase == .idle || phase.isWorking ? TVText.button : TVText.retry) { install() }
                    .buttonStyle(.mobilePrimary)
                    .disabled(phase.isWorking || address.trimmingCharacters(in: .whitespaces).isEmpty
                              || NetworkAddress.isOwnAddress(address, own: phoneAddress(near: nil)))
            }
        }
            .task { await search() }
    }

    private func search() async {
        guard candidates == nil else { return }
        if let update { address = update.port.map { "\(update.host):\($0)" } ?? update.host }
        let known = [update?.host, model.installedTVApp?.brand == .androidTV ? model.installedTVApp?.host : nil,
                     model.tv?.brand == .androidTV ? model.tv?.host : nil].compactMap { $0 }.filter { !$0.isEmpty }
        if update != nil, !started {
            started = true
            install()
        }
        let open = await scanSubnet(port: AdbConnection.defaultPort, near: known.first)
        var list = open.map { (host: $0, debugging: true) }
        for host in known where !list.contains(where: { $0.host == host }) { list.insert((host, false), at: 0) }
        candidates = list
        if address.isEmpty, let first = list.first(where: { $0.debugging }) ?? list.first { address = first.host }
    }

    private func install(allowReplace: Bool = false) {
        guard let target = AndroidTvInstaller.parseAddress(address, defaultPort: wireless ? 0 : AdbConnection.defaultPort), target.1 > 0 else {
            phase = .failed(text: TVText.androidNeedPort)
            return
        }
        let code = pairCode.filter(\.isNumber)
        var pairing: AndroidTvInstaller.Pairing?
        if wireless, !code.isEmpty {
            guard let pair = AndroidTvInstaller.parseAddress(pairAddress, defaultPort: 0), pair.1 > 0 else {
                phase = .failed(text: TVText.androidNeedPairPort)
                return
            }
            pairing = AndroidTvInstaller.Pairing(port: pair.1, code: code)
        }
        let selectedPairing = pairing
        replaceNeeded = false
        phase = .working(pairing != nil ? .pairing : .connecting)
        working = true
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            defer {
                working = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do {
                guard TVPackages.androidVersion != nil else { throw AndroidInstallFailure(error: .packageMissing) }
                let result = try await runInstall({ progress in
                    try AndroidTvInstaller(host: target.0, port: target.1, pairing: selectedPairing, progress: progress)
                        .ensureInstalled(apk: { try TVPackages.androidPackage() }, version: TVPackages.androidVersion, allowReplace: allowReplace)
                }, progress: { step in if phase.isWorking { phase = .working(step) } })
                phase = .done(version: result.version, installed: result.installed)
                await model.tvAppInstalled(brand: .androidTV, host: target.0, port: target.1 == AdbConnection.defaultPort ? nil : target.1, version: result.version)
            } catch let failure as AndroidInstallFailure {
                replaceNeeded = failure.error == .replaceNeeded
                phase = .failed(text: failureText(failure))
            } catch {
                phase = .failed(text: TVText.errFailed + "\n\n" + TVText.details("\(error)"))
            }
        }
    }

    /// Kaldırıp kurmadan sonra da TV "imza tutmuyor" dedi: `pm uninstall` TV'de işe yaramadı. 0.9.18 ve önceki TV
    /// paketleri her derlemede değişen geliştirme anahtarıyla imzalıydı; bunlar yalnız kaldırılıp yeniden kurularak güncellenir.
    private func mustRemoveOnTV(_ failure: AndroidInstallFailure) -> Bool {
        failure.error == .installFailed && AndroidTvInstaller.needsReplace(failure.detail ?? "")
    }

    private func failureText(_ failure: AndroidInstallFailure) -> String {
        let advice: String = switch failure.error {
        case .unreachable: TVText.androidErrUnreachable
        case .notApproved: TVText.androidErrNotApproved
        case .notPaired: TVText.androidErrNotPaired
        case .pairingFailed: TVText.androidErrPairing
        case .replaceNeeded: failure.installedFromPlay ? TVText.androidErrPlayCopy : TVText.androidErrOtherCopy
        case .notEnoughSpace: TVText.errSpace
        case .connectionLost: TVText.errConnection
        case .packageMissing: TVText.errPackageMissing
        // Kaldırıp kurma denendi ama TV eski kopyayı kaldırmadı (imza yine tutmuyor): kullanıcı TV'de elle kaldırır.
        case .installFailed: mustRemoveOnTV(failure) ? TVText.androidErrRemoveManually : TVText.errFailed
        }
        guard failure.error != .replaceNeeded, !mustRemoveOnTV(failure), let detail = failure.detail, !detail.isEmpty else { return advice }
        return advice + "\n\n" + TVText.details(detail)
    }
}

// MARK: - Ana ekrandaki güncelleme kartı

/// TV'deki uygulama telefondaki paketten eski: tek dokunuşla güncellenir (kurulum ekranı açılır ve kendiliğinden başlar).
struct TVAppUpdateTile: View {
    let update: TVAppUpdate
    let action: () -> Void

    var body: some View {
        Tile(emphasis: .selected) {
            HStack(spacing: Mobile.Space.inline) {
                MobileTileIcon(symbol: "arrow.triangle.2.circlepath", tint: .accent)
                Text(verbatim: TVText.updateTitle).font(Mobile.TypeScale.headline)
            }
            Text(verbatim: TVText.updateVersions(update.installed, update.bundled)).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
            Button(TVText.updateButton, action: action).buttonStyle(.mobileSecondary)
        }
    }
}
