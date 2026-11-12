// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

/// "Geçmiş": bu ve önceki oturumlarda çevrilen son satırlar (en yenisi üstte); her satır ve liste kopyalanabilir.
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copiedAll = false
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("gap")) {
            Text("History").font(.csDisplay)
            HintText(text: LocalizedStringKey(String(format: String(localized: "The last %lld translated lines are kept on this computer."),
                                                     SubtitleHistory.defaultLimit)))
            if model.history.entries.isEmpty {
                Spacer()
                HintText(text: "No subtitles yet. Lines translated in this and earlier sessions appear here.")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.history.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().overlay(Color.csBorder) }
                            HistoryEntryRow(entry: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tile()
            }
            HStack(spacing: Theme.space("m")) {
                Button(copiedAll ? "Copied" : "Copy all") {
                    copy(SubtitleHistory.plainText(model.history.entries))
                    copiedAll = true
                }
                .buttonStyle(.secondary)
                .disabled(model.history.entries.isEmpty)
                Button("Clear") { confirmClear = true }
                    .buttonStyle(CSButtonStyle(kind: .danger))
                    .disabled(model.history.entries.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(CSButtonStyle(kind: .primary, height: "buttonLarge"))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.space("screen"))
        .frame(width: 640, height: Theme.size("windowHeight") - 2 * Theme.space("screen"))
        .confirmationDialog("Clear the history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.clearHistory() }
        } message: {
            Text("All saved lines are removed from this computer.")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Bir satır: saat ve kaynak (paket ya da çeviri motoru) üstte, Türkçe, altında İngilizcesi; sağda kopyala.
private struct HistoryEntryRow: View {
    let entry: SubtitleHistory.Entry
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.space("m")) {
            VStack(alignment: .leading, spacing: Theme.space("hair")) {
                Text(verbatim: "\(entry.date.formatted(date: .omitted, time: .standard)) · \(origin)")
                    .font(.csCaption.monospacedDigit())
                    .foregroundStyle(Color.csSecondary)
                Text(verbatim: entry.translation)
                    .font(.csBody)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: entry.source)
                    .font(.csCaption)
                    .foregroundStyle(Color.csSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(entry.translation)\n\(entry.source)", forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.csSecondary)
            .help(Text(copied ? "Copied" : "Copy"))
            .accessibilityLabel(Text("Copy"))
        }
        .padding(.vertical, Theme.space("m"))
    }

    private var origin: String {
        entry.origin == .pack ? String(localized: "Pack") : String(localized: "Translation engine")
    }
}
