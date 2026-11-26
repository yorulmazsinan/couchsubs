// SPDX-License-Identifier: AGPL-3.0-only
// Oyun paketleri › Paketi içe aktar: topluluk çeviri dosyası (JSON, TXT, iki dilli SRT) seçilir, önizlenir ve bu
// telefona paket olarak kurulur (Mac, Windows ve Android ile aynı akış; ayrıştırma core'daki GamePackImporter).
// Dosya yalnız okunur, hiçbir yere gönderilmez; paket PackStore.importedDirectory'de kalır.

import CouchSubsCore
import SwiftUI
import UniformTypeIdentifiers

/// Paket ekranındaki "İçe aktarılan paketler" bölümü: içe aktarma düğmesi, liste ve silme.
struct ImportedPacksSection: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var choosing = false
    @State private var reading = false
    @State private var selection: PackImportSelection?
    @State private var error: String?
    @State private var deleting: GamePackLibrary.Info?

    private static let types: [UTType] = [.json, .plainText] + [UTType(filenameExtension: "srt")].compactMap { $0 }

    /// İçe aktarılan paketler: kurulu paketlerden dosyası içe aktarma klasöründe olanlar (en son okunur, kazanır).
    private var imported: [GamePackLibrary.Info] {
        model.installedPacks.filter { PackImportFiles.exists($0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.inline) {
            Text("Imported packs").font(Mobile.TypeScale.headline)
            Text("Add a community translation file (JSON, TXT or bilingual SRT) as a game pack. The file stays on this phone and is not sent anywhere.")
                .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !imported.isEmpty {
            Tile {
                ForEach(Array(imported.enumerated()), id: \.element.id) { index, pack in
                    if index > 0 { RowDivider() }
                    HStack(spacing: Mobile.Space.gap) {
                        VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                            Text(verbatim: pack.title).font(Mobile.TypeScale.headline).lineLimit(2)
                            Text(PacksScreen.linesText(pack.entries)).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                        }
                        Spacer(minLength: Mobile.Space.inline)
                        Button("Delete", role: .destructive) { deleting = pack }
                            .buttonStyle(.plain)
                            .font(Mobile.TypeScale.headline)
                            .foregroundStyle(Mobile.Palette.danger)
                    }
                    .frame(minHeight: Mobile.Control.row)
                }
            }
        }
        if let error { MobileNote(text: error) }
        Button("Import Pack…") {
            error = nil
            choosing = true
        }
        .buttonStyle(.mobileSecondary)
        .disabled(reading)
        .fileImporter(isPresented: $choosing, allowedContentTypes: Self.types, onCompletion: read)
        .sheet(item: $selection) { selection in
            PackImportSheet(selection: selection)
        }
        .confirmationDialog("Delete pack?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { pack in
            Button("Delete", role: .destructive) { delete(pack) }
        } message: { pack in
            Text(String(format: String(localized: "%@ is removed from this phone. To use it again, import the file again."), pack.title))
        }
    }

    private func read(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            self.error = String(localized: "The translation file could not be read.")
            return
        }
        reading = true
        Task {
            defer { reading = false }
            do {
                selection = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= GamePackImporter.maxFileBytes else { throw GamePackImporter.ImportError.fileTooLarge }
                    let data = try GamePackImporter.read(fileAt: url)
                    let preview = try GamePackImporter.parse(data, fileName: url.lastPathComponent)
                    // Kaç satır kabul edildi, kaçı neden atlandı (#1355).
                    SubtitleLog.write(preview.logLine(fileName: url.lastPathComponent))
                    return PackImportSelection(fileName: url.lastPathComponent, preview: preview)
                }.value
            } catch is GamePackImporter.ImportError {
                self.error = String(localized: "The translation file could not be imported. Check its format and encoding.")
            } catch {
                self.error = String(localized: "The translation file could not be read.")
            }
        }
    }

    private func delete(_ pack: GamePackLibrary.Info) {
        deleting = nil
        let packs = model.packs
        Task {
            await Task.detached(priority: .userInitiated) {
                PackImportFiles.remove(pack.id)
                packs.reload()
            }.value
            model.reloadPackList()
        }
    }
}

/// İçe aktarma klasöründeki paket dosyaları (`<id>.json`).
enum PackImportFiles {
    static func file(_ id: String) -> URL { PackStore.importedDirectory.appendingPathComponent(id + ".json") }

    static func exists(_ id: String) -> Bool {
        id.hasPrefix("community-") && FileManager.default.fileExists(atPath: file(id).path)
    }

    static func remove(_ id: String) {
        guard id.hasPrefix("community-"), !id.contains("/") else { return }
        try? FileManager.default.removeItem(at: file(id))
    }
}

private struct PackImportSelection: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let preview: GamePackImportPreview
}

/// Önizleme: oyunun adı (JSON'dan ya da dosya adından) ve sayılar; onaylanınca kurulur, aynı kimlik varsa sorulur.
private struct PackImportSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let selection: PackImportSelection
    @State private var title: String
    @State private var installing = false
    @State private var confirmReplacement = false
    @State private var installError: String?
    /// Perde başarı anı: paket kuruldu (ışın + yaylı tik + başarı titreşimi), kısa süre sonra sayfa kendiliğinden kapanır.
    @State private var installed = false

    init(selection: PackImportSelection) {
        self.selection = selection
        _title = State(initialValue: selection.preview.suggestedTitle
                       ?? URL(fileURLWithPath: selection.fileName).deletingPathExtension().lastPathComponent)
    }

    private var canInstall: Bool {
        !installing && !selection.preview.entries.isEmpty && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if installed { success } else { form }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Mobile.Space.screen)
        .fittedSheet()
        .sheetBackground(Mobile.Palette.surface)
        .interactiveDismissDisabled(installing)
        .alert("Replace game pack?", isPresented: $confirmReplacement) {
            Button("Cancel", role: .cancel) {}
            Button("Replace pack", role: .destructive) { install(replacing: true) }
        } message: {
            Text("A game pack with this ID already exists. Replacing it will overwrite the installed pack.")
        }
    }

    /// Paket kuruldu: eğik kapak + başarı anı, oyunun adı, "Kurulu" ve satır sayısı; tek düğme.
    private var success: some View {
        VStack(spacing: Mobile.Space.gap) {
            ZStack(alignment: .bottomTrailing) {
                DSCelebration(size: 56)
                DSCoverArt(seed: title)
                    .frame(width: 54, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: DS.radius("chip"), style: .continuous))
                    .rotationEffect(.degrees(-8))
                    .offset(x: -44, y: -6)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .accessibilityHidden(true)
            }
            Text(verbatim: title).font(Font.dsH3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Mobile.Space.inline) {
                DSStatusChip("Installed", tone: .ok, icon: "checkmark")
                DSStatusChip(LocalizedStringKey(PacksScreen.linesText(selection.preview.entries.count)), tone: .amber, dot: false)
            }
            Button("Done") { dismiss() }.buttonStyle(.mobilePrimary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            dismiss()
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.gap) {
            Text("Import game pack").font(Mobile.TypeScale.title)
            VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                Text("Game title").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                TextField("Game title", text: $title)
                    .textFieldStyle(MobileFieldStyle())
                    .disabled(installing)
            }
            // Kabul edilen ve nedenine göre atlanan kayıtlar (#1355; Mac, Windows ve Android aynı satırlar).
            VStack(spacing: Mobile.Space.hair) {
                let preview = selection.preview
                countRow("Usable entries", preview.acceptedCount)
                if !preview.segments.isEmpty { countRow("Sentence segments", preview.segments.count) }
                countRow("Skipped records", preview.skippedCount)
                ForEach(PackImportReport.reasons(preview), id: \.label) { row in
                    countRow(LocalizedStringKey(row.label), row.count)
                }
                countRow("Duplicate pairs", preview.duplicateCount)
                countRow("Conflicting entries", preview.conflictCount)
            }
            if let note = PackImportReport.fuzzyNote(selection.preview) {
                Text(LocalizedStringKey(note)).font(Mobile.TypeScale.caption)
                    .foregroundStyle(selection.preview.fuzzyDropped ? Mobile.Palette.danger : Mobile.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if selection.preview.entries.isEmpty {
                MobileNote(text: String(localized: "The file contains no usable translations."))
            }
            if let installError { MobileNote(text: installError, tone: Mobile.Palette.danger) }
            Button {
                install(replacing: false)
            } label: {
                HStack(spacing: Mobile.Space.inline) {
                    if installing { DSBarsLoader(color: .dsOnAmber) }
                    Text("Install pack")
                }
            }
            .buttonStyle(.mobilePrimary)
            .disabled(!canInstall)
            Button("Cancel") { dismiss() }
                .buttonStyle(.mobileGhost)
                .disabled(installing)
        }
    }

    private func countRow(_ label: LocalizedStringKey, _ count: Int) -> some View {
        HStack {
            Text(label).foregroundStyle(Mobile.Palette.secondary)
            Spacer()
            Text(count, format: .number).monospacedDigit()
        }
        .font(Mobile.TypeScale.body)
    }

    private func install(replacing: Bool) {
        guard canInstall else { return }
        installError = nil
        installing = true
        let title = self.title
        let preview = selection.preview
        let packs = model.packs
        Task {
            defer { installing = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try GamePackImporter.install(preview, title: title, directory: PackStore.importedDirectory, replacing: replacing)
                    SubtitleLog.write(preview.installLog(title: title))
                    packs.reload()
                }.value
                model.reloadPackList()
                withAnimation(.easeOut(duration: 0.2)) { installed = true }
            } catch GamePackImporter.ImportError.destinationExists {
                confirmReplacement = true
            } catch {
                Haptics.error()
                installError = String(localized: "The game pack could not be installed.")
            }
        }
    }
}
