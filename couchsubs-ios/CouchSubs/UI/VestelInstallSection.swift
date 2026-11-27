// SPDX-License-Identifier: AGPL-3.0-only
// Vestel Linux TV (deneysel): istemciyi bu iPhone'dan TV'ye kurmak; Mac'teki VestelTVCard'ın tek tuşla kurulumunun
// aynısı (core VestelInstall). Ön koşul (bir kez): TV'nin test aracı soketi (1986) USB'deki DevProfile ile açılmış olmalı.
// TV'ye kalıcı bir şey yazılmaz; TV yeniden başlayınca istemci gider, kurulum yeniden yapılır.

import CouchSubsCore
import SwiftUI

struct VestelInstallSection: View {
    @EnvironmentObject private var model: PhoneModel
    @Binding var working: Bool
    let onDone: () -> Void
    @State private var address = ""
    @State private var failure: String?
    /// İstemci TV'de başlatıldı; eşleşme isteği bekleniyor.
    @State private var launched = false

    private var host: String? { ManualAddress.normalize(address) }
    private var connected: Bool {
        model.tv?.brand == .vestelLinux && model.tv?.host == host && model.hasTV && model.tvClients > 0
    }

    var body: some View {
        InstallIntro(body1: String(localized: "Vestel TVs with Vestel's own system (not Android TV), experimental. Automatic search is not available; the address is in the TV's network settings."),
                     note: String(localized: "Experimental: tested on a Vestel 55UD8400 (MB130); other Vestel models may differ. Nothing is installed on the TV permanently; restarting the TV removes it."))
        TVAddressField(label: TVText.address, text: $address)
        InstallSteps(title: String(localized: "Vestel Linux TV (experimental)"),
                     steps: [String(localized: "1. Once: turn on the TV's test-tool socket with a DevProfile file on a USB stick (service menu 4725 › USB Diagnostic), then turn the TV off and on after a minute."),
                             String(localized: "2. Type the TV's IP address above and tap Install and start on the TV."),
                             String(localized: "3. A 6-digit code appears at the bottom of the TV; approve the request on this phone.")])
        if model.vestelClientURL == nil {
            InstallErrorBox(text: String(localized: "This build of CouchSubs does not include the Vestel TV client."))
        }
        if let step = model.vestelInstallStep {
            Tile {
                HStack(spacing: Mobile.Space.gap) {
                    ProgressView().tint(Mobile.Palette.accent)
                    Text(verbatim: step.rawValue).font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: Mobile.Control.row, alignment: .leading)
            }
        } else if connected {
            Tile(emphasis: .selected) {
                Label(String(localized: "The TV client is connected to this phone."), systemImage: "checkmark.circle.fill")
                    .font(Mobile.TypeScale.headline).foregroundStyle(Mobile.Palette.successText)
            }
        } else if launched {
            MobileNote(text: String(localized: "The client is running on the TV. Approve the pairing request on this phone."))
        }
        if let failure { InstallErrorBox(text: failure) }
        Group {
            if connected {
                Button(TVText.goHome, action: onDone).buttonStyle(.mobilePrimary)
            } else {
                Button(failure == nil ? String(localized: "Install and start on the TV") : TVText.retry) { install() }
                    .buttonStyle(.mobilePrimary)
                    .disabled(working || host == nil || model.vestelClientURL == nil
                              || NetworkAddress.isOwnAddress(address, own: phoneAddress(near: nil)))
            }
        }
        .task {
            if address.isEmpty, model.tv?.brand == .vestelLinux, let saved = model.tv?.host { address = saved }
        }
    }

    private func install() {
        guard let host else { return }
        working = true
        failure = nil
        launched = false
        Task {
            do {
                // TV önce Vestel Linux olarak kaydedilir (altyazı hedefi TV olur); istemci bağlanınca eşleşir.
                if !(model.hasTV && model.tv?.brand == .vestelLinux && model.tv?.host == host) {
                    try await model.pair(LGTV(name: "Vestel Linux TV", host: host, brand: .vestelLinux))
                }
                try await model.installVestelClient(host: host)
                launched = true
            } catch {
                InstallLog.shared.write("Vestel kurulumu başarısız: \(error)")
                failure = Self.message(for: error)
            }
            working = false
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case VestelInstall.Failure.testToolUnreachable:
            String(localized: "Could not reach the TV. Check the IP address, that the TV is on, and that its test-tool socket is open.")
        case VestelInstall.Failure.shellUnreachable:
            String(localized: "The TV did not open a shell. Try again.")
        case PhoneModel.VestelPhoneError.noClient:
            String(localized: "This build of CouchSubs does not include the Vestel TV client.")
        case PhoneModel.VestelPhoneError.noAddress, VestelInstall.Failure.badAddress:
            TVText.phoneIpUnknown
        default:
            String(localized: "Installation failed. Try again.")
        }
    }
}
