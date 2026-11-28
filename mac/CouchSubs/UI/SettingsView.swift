// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Yazı boyutu, yeri, arka planı, rengi; görünüm ayarları bilgisayar ekranındaki pencereye de uygulanır.
struct AppearanceCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Yeni arayüzde yazı boyutu, zemin ve renkler Ayarlar › Altyazı Görünümü'nde; burada yer ve biçim kalır.
        Card {
            // Yer ayarları TV ve OBS katmanı içindir; bilgisayar ekranındaki altyazı penceresi sürüklenerek taşınır (Genzo, 2026-11-13:
            // "ekrandaki konum ayarı işlemiyor").
            if model.settings.output.showsOnTV || model.settings.output == .obs {
                DSSelectRow(title: "Placement", selection: $model.settings.style.placement,
                            options: [(SubtitlePlacement.cover, String(localized: "Over the English subtitle")), (SubtitlePlacement.above, String(localized: "Above the English subtitle")), (SubtitlePlacement.below, String(localized: "Below the English subtitle")), (SubtitlePlacement.fixed, String(localized: "Fixed position"))],
                            hint: model.settings.style.placement == .fixed ? nil : "The translation follows where the game shows its own subtitle.")
                if model.settings.style.placement == .fixed {
                    // Sürüklerken TV'de örnek altyazı görünür; böylece yeri doğrudan ekranda ayarlanır.
                    DSSliderRow(title: "Position on Screen", valueText: percentText(Double(model.settings.style.bottomPercent)),
                                value: Binding(get: { Double(model.settings.style.bottomPercent) },
                                               set: { model.settings.style.bottomPercent = Int($0.rounded()) }),
                                range: 0...85, step: 1,
                                hint: "The left end is the bottom of the screen. You can also move subtitles with the ▲ and ▼ buttons on the TV remote.") { editing in
                        if editing { model.sendTestSubtitle() }
                    }
                }
            }
            DSSelectRow(title: "Background area", selection: $model.settings.style.backgroundShape,
                        options: [(SubtitleBackgroundShape.fit, String(localized: "Fit the text")), (SubtitleBackgroundShape.band, String(localized: "Full-width band"))],
                        hint: "A full-width band also covers the sides of the English subtitle.")
            SwitchRow(title: "Bold text", isOn: $model.settings.style.bold)
            SwitchRow(title: "Keep previous lines above in fast dialogue", isOn: $model.settings.style.stackPrevious,
                      hint: "When off, each new line replaces the previous one. Needs TV app 0.9.16 or later.")
            if model.settings.output.showsOnTV, model.tv?.brand == .androidTV {
                AndroidDisplayModePicker(mode: $model.settings.style.displayMode)
            }
        }
    }
}

struct LanguageCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            DSSelectRow(title: "Game language", selection: $model.settings.sourceLanguage,
                        options: [("en", String(localized: "English")), ("ja", String(localized: "Japanese")), ("de", String(localized: "German")), ("fr", String(localized: "French")), ("es", String(localized: "Spanish"))])
        }
    }
}

/// Bölge önizlemesi, son PS5 karesiyle (kare değişince yalnız bu görünüm yeniden çizilir).
struct LiveRegionPreview: View {
    @Binding var settings: UserSettings
    @ObservedObject var preview: FramePreview

    var body: some View {
        RegionPreview(region: settings.region, frame: preview.image, centered: settings.keepAreaCentered) { settings.setCustomRegion($0) }
    }
}

/// Altyazı bölgesi (hazır seçimler, canlı önizleme, Özel'de kaydırıcılar) ve ekranı çevirme kısayolu.
struct AreaCards: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AreaProfileCard(areas: model.gameAreas)
        GameProfilesCard(areas: model.gameAreas)
        Card {
            DSTabs(selection: Binding(get: { model.settings.areaPreset }, set: { model.settings.selectAreaPreset($0) }),
                   items: AreaPreset.allCases.map { ($0, $0.newTitle) })
            LiveRegionPreview(settings: $model.settings, preview: model.framePreview)
            if model.settings.areaPreset == .custom { CustomAreaSliders(settings: $model.settings) }
            SwitchRow(title: "Keep centered", isOn: $model.settings.keepAreaCentered)
            Button(HotkeyText.title(model.settings, .snapshot, String(localized: "Refresh picture (%@)"))) { model.requestSnapshot() }
                .buttonStyle(.secondary)
            HintText(text: "Adjust the frame so it covers where the game shows its subtitles.")
            // "Ortalı kalır" yalnız Ortada tut açıkken yazılır.
            if model.settings.keepAreaCentered {
                HintText(text: "Drag the frame to move it, or drag an edge or corner to resize it; the subtitle area stays centered.")
            } else {
                HintText(text: "Drag the frame to move it, or drag an edge or corner to resize it.")
            }
        }
        ExtraAreasCard()
        Card {
            SwitchRow(title: "Translate On-Screen Text Automatically", isOn: $model.settings.autoScreenText)
            HintText(text: "Text boxes that appear on screen (objectives, help, messages) are found and translated in place. Counters, the map and short labels are skipped.")
            // Türler yalnız ayar açıkken görünür; dört platformda aynı ad ve sıra (bkz. ScreenTextKind).
            if model.settings.autoScreenText { ScreenTextKindRows(settings: $model.settings) }
            Divider().overlay(Color.csBorder)
            SwitchRow(title: "Set on-screen text apart from subtitles", isOn: $model.settings.setTextApart)
            HintText(text: "On-screen text keeps its own colours and place, and never looks like the subtitle box.")
            Divider().overlay(Color.csBorder)
            SwitchRow(title: "Use ready areas for known games", isOn: $model.settings.gameAreaPresets)
            HintText(text: "When a game with ready areas (such as GTA 6) is being played, its help box and messages are read and translated automatically. Your own extra areas take precedence.")
            Divider().overlay(Color.csBorder)
            SwitchRow(title: "Translate the GTA 6 Phone", isOn: $model.settings.translatesGamePhone)
            // Dört platformda aynı ad ve seçenekler (iPhone: Profile, Windows: SettingsWindow, Android: ProfileScreens);
            // otomatik telefon okumasına ve "Ekranı çevir"e uygulanır, varsayılan Yanda Panel.
            DSTabs(selection: $model.settings.phoneMessagesPanel, items: [(true, "Side Panel"), (false, "On the Bubbles")])
            HintText(text: "Side Panel: the chat is shown next to the phone, the other person on the left and you on the right. On the Bubbles: each message is translated on top of its own bubble.")
        }
        Card(title: LocalizedStringKey(HotkeyText.title(model.settings, .screen, String(localized: "Translate the screen (%@)")))) {
            HintText(text: LocalizedStringKey(HotkeyText.sentence(model.settings, .screen,
                String(localized: "Press %@ while playing: every text on the screen is translated once and shown on the TV in its own place. Press again to remove the translations."))))
        }
        // Serbest alan (Windows: FreeAreaCard): görüntü donar, fareyle seçilen yer bir kez çevrilir.
        Card(title: LocalizedStringKey(HotkeyText.title(model.settings, .freeArea, String(localized: "Free area (%@)")))) {
            HintText(text: LocalizedStringKey(HotkeyText.sentence(model.settings, .freeArea,
                String(localized: "Press %@ while playing: the picture freezes on the PC, drag over any part of it to translate that part once. Esc closes."))))
            ResultTargetPicker(target: $model.settings.freeAreaTarget)
            HintText(text: LocalizedStringKey(HotkeyText.sentence(model.settings, .pauseSubtitles,
                String(localized: "%@ pauses or resumes the live subtitle translation, which helps when you translate areas."))))
            HintText(text: "The shortcuts work only while translating, so the keys stay free in other apps. You can change them under Keyboard shortcuts.")
        }
    }
}

/// "Bu oyunun alanları": alanlar oynanan oyuna kaydedilir, o oyun yeniden oynanınca kendiliğinden gelir. Profil etkinse
/// hangi oyunun alanları olduğu ve kaydedilmemiş değişiklikte "Profile kaydet" (Windows, iPhone ve Android ile aynı).
struct AreaProfileCard: View {
    @ObservedObject var areas: GameAreas
    /// Alanlar değişince (kaydedilmemiş değişiklik) kart yenilenir.
    @EnvironmentObject private var model: AppModel
    @State private var confirmDelete = false

    var body: some View {
        let active = model.settings.activeAreaProfile == nil ? nil : areas.activeGame
        let target = areas.target
        let unsaved = model.settings.areasDifferFromProfile
        Card(title: "Areas for this game") {
            if let active {
                Text(verbatim: String(format: String(localized: "These areas are saved for %@."), active)).font(.csBody)
                HintText(text: unsaved ? "Your changes are not saved yet; they are dropped when translating stops."
                                       : "They come back by themselves whenever you play this game.")
            } else if let target {
                Text("These are your general areas.").font(.csBody)
                Text(verbatim: String(format: String(localized: "Save them for %@ and they come back by themselves the next time you play it."), target))
                    .font(.csCallout)
                    .foregroundStyle(Color.csSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Areas can be saved for a game while translating, once the game being played is known.").font(.csBody)
                HintText(text: "The played game is shown on the home screen; you can choose it there.")
            }
            if target != nil || active != nil {
                HStack(spacing: Theme.space("s")) {
                    if let target, areas.targetHasOtherProfile {
                        // Oynanan oyunun kayıtlı alanları uygulanmadı: üzerine yazılmaz, istenirse kullanılır.
                        Button(String(format: String(localized: "Use the saved areas for %@"), target)) {
                            if let key = AreaProfiles.key(target, source: model.settings.areaSource) { areas.use(key) }
                        }
                        .buttonStyle(.secondary)
                    } else if let target, active == nil || unsaved {
                        Button(active == nil ? String(format: String(localized: "Save for %@"), target) : String(localized: "Save to profile")) {
                            areas.save()
                        }
                        .buttonStyle(.secondary)
                    }
                    if active != nil {
                        Button("Delete profile") { confirmDelete = true }.buttonStyle(.secondary)
                    }
                }
            }
        }
        .confirmationDialog(String(format: String(localized: "Delete the saved areas for %@?"), active ?? ""), isPresented: $confirmDelete) {
            Button("Delete profile", role: .destructive) { areas.delete() }
        }
    }
}

/// "Oyun profilleri": her oyunun kendi alanları. Listede olmayan oyun adı yazılarak eklenir; profil seçilir, yeniden
/// adlandırılır, çoğaltılır, silinir. Profil seçmek oynanan oyunu da o yapar (Windows, iPhone ve Android ile aynı).
struct GameProfilesCard: View {
    @ObservedObject var areas: GameAreas
    @EnvironmentObject private var model: AppModel
    @State private var editing: GameProfileEditing?
    @State private var name = ""
    @State private var problem: String?
    @State private var deleting: AreaProfile?

    var body: some View {
        let profiles = model.settings.gameProfiles
        Card(title: "Game profiles") {
            HintText(text: "Each game keeps its own subtitle area and extra areas. A game that isn't in the list can be added by typing its name; one profile never overwrites another.")
            ForEach(profiles, id: \.key) { profile in
                if editing == .rename(profile.key) || editing == .duplicate(profile.key) {
                    editor
                } else {
                    row(profile)
                }
                Divider().overlay(Color.csBorder)
            }
            if editing == .new {
                editor
            } else {
                Button("New game profile") { begin(.new, name: model.gameChoice.game?.name ?? "") }.buttonStyle(.secondary)
            }
        }
        .confirmationDialog(String(format: String(localized: "Delete the saved areas for %@?"), deleting?.game ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete profile", role: .destructive) { if let deleting { areas.delete(deleting.key) } }
        }
    }

    private func row(_ profile: AreaProfile) -> some View {
        HStack(spacing: Theme.space("s")) {
            Text(verbatim: profile.game).font(.csBody).lineLimit(1)
            if model.settings.activeAreaProfile == profile.key {
                Text("In use").font(.csCaption).foregroundStyle(Color.csSecondary)
            }
            Spacer(minLength: Theme.space("m"))
            if model.settings.activeAreaProfile != profile.key {
                Button("Use") { areas.use(profile.key) }.buttonStyle(.secondary)
            }
            Menu {
                Button("Rename") { begin(.rename(profile.key), name: profile.game) }
                Button("Duplicate") { begin(.duplicate(profile.key), name: "") }
                Button("Delete profile", role: .destructive) { deleting = profile }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(Text("More"))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.space("s")) {
            TextField("Game name", text: $name)
                .textFieldStyle(CSTextFieldStyle())
                .onSubmit(commit)
            if let problem {
                Text(verbatim: problem).font(.csCallout).foregroundStyle(Color.csSecondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.space("s")) {
                Button(commitTitle) { commit() }
                .buttonStyle(.secondary)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { editing = nil }
                    .buttonStyle(.plain)
                    .font(.csCaption.weight(.semibold))
                    .foregroundStyle(Color.csSecondary)
            }
        }
    }

    private var commitTitle: LocalizedStringKey {
        switch editing {
        case .rename?: "Rename"
        case .duplicate?: "Duplicate"
        case .new?, nil: "Save current areas"
        }
    }

    private func begin(_ mode: GameProfileEditing, name: String) {
        editing = mode
        self.name = name
        problem = nil
    }

    private func commit() {
        guard let editing else { return }
        let edit: AreaProfiles.Edit = switch editing {
        case .new: areas.saveAs(name)
        case .rename(let key): areas.rename(key, to: name)
        case .duplicate(let key): areas.duplicate(key, as: name)
        }
        switch edit {
        case .done: self.editing = nil
        case .exists: problem = String(format: String(localized: "There is already a profile for %@."), name.trimmingCharacters(in: .whitespacesAndNewlines))
        case .empty, .missing: problem = String(localized: "Type the game's name.")
        }
    }
}

/// Oyun profilleri kartında hangi işlem için ad yazılıyor.
enum GameProfileEditing: Equatable {
    case new, rename(String), duplicate(String)
}

/// Altyazının yanında sürekli okunan ek alanlar: görev yazısı, bildirim, telefon mesajı. Her biri adlandırılır, açılıp
/// kapatılır; çerçevesi canlı önizlemede sürüklenir (Windows: SettingsView.xaml › EXTRA AREAS, aynı düzen).
struct ExtraAreasCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card(title: "Extra areas") {
            // Sınır 3'ten kaldırıldı; ilk üçünün kısayolu var (Num 1–3), sonrakiler kısayolsuz.
            HintText(text: "Also reads small text next to the subtitle, such as objectives, phone messages or notifications. Each area is read once a second and translated again when the text changes; the translation appears on the TV next to that text.")
            // Tam ekranda ek alanlar okunmaz (bkz. activeExtraAreas); ayarları korunur, düzenlenebilir.
            if model.settings.extraAreasPausedByFullScreen, !model.settings.extraAreas.isEmpty {
                HintText(text: "Extra areas aren't read while the subtitle area is Full screen, because the whole screen is already read. They're read again when you pick another area.")
            }
            ForEach(model.settings.extraAreas) { area in
                ExtraAreaEditor(id: area.id, settings: $model.settings, preview: model.framePreview)
                    .opacity(model.settings.extraAreasPausedByFullScreen ? 0.5 : 1)
            }
            HStack(spacing: DS.space("m")) {
                if model.settings.extraAreas.isEmpty {
                    Text("No extra areas yet.").dsMuted()
                    Spacer(minLength: DS.space("s"))
                }
                if model.settings.canAddExtraArea {
                    // Menü yok: yeni alan boş bir köşenin hazır yeriyle eklenir; yeri alanın içindeki seçiciden değişir.
                    Button {
                        let preset = Self.nextPreset(model.settings.extraAreas)
                        model.settings.addExtraArea(preset, name: preset.defaultName)
                    } label: {
                        HStack(spacing: DS.space("xs")) {
                            Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
                            Text("Add Extra Area")
                        }
                    }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Henüz kullanılmayan ilk hazır yer (görev, bildirim, telefon); hepsi kullanıldıysa görev (Windows: NextPreset).
    static func nextPreset(_ areas: [ExtraArea]) -> ExtraAreaPreset {
        ExtraAreaPreset.allCases.first { preset in !areas.contains { preset.region.isClose(to: $0.region) } } ?? .quest
    }
}

/// Bir ek alanın düzenleyicisi: üstte ad (sade giriş) + kısayol rozeti + küçük Kaldır; altında Sürekli Oku anahtarı,
/// yer seçici, önizleme ve Sonucu Göster seçici. Açıklamalar ilgili denetimin altında, birer kısa cümle.
struct ExtraAreaEditor: View {
    let id: String
    @Binding var settings: UserSettings
    /// Önizleme ayrı görünümde izlenir: her yeni karede yalnız önizleme yeniden çizilir, ad alanı ve seçimler değil.
    let preview: FramePreview

    var body: some View {
        if let area = settings.extraAreas.first(where: { $0.id == id }) {
            let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
            let preset = ExtraAreaPreset.matching(area.region)
            VStack(alignment: .leading, spacing: DS.unitGap) {
                HStack(spacing: DS.space("s")) {
                    ExtraAreaNameField(name: Binding(get: { area.name }, set: { name in settings.updateExtraArea(id: id) { $0.name = name } }))
                    if let keys = shortcutKeys { DSKeys(keys: keys) } else { DSBadge(text: "No Shortcut") }
                    Button { settings.removeExtraArea(id: id) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(DSTextButtonStyle())
                }
                DSSwitchRow(title: "Keep Reading This Area", subtitle: "Read about once a second while translating.",
                            isOn: Binding(get: { area.enabled }, set: { on in settings.updateExtraArea(id: id) { $0.enabled = on } }),
                            divider: false)
                DSUnit(title: "Place", hint: placeHint(preset)) {
                    DSTabs(selection: Binding(get: { preset }, set: { next in
                        guard let next else { return }
                        settings.updateExtraArea(id: id) { area in
                            // Ad hâlâ eski yerin hazır adıysa (ör. "Görev") yeni yerin adı verilir; kullanıcının adı korunur.
                            let old = ExtraAreaPreset.matching(area.region)
                            if area.name.isEmpty || area.name == old?.defaultName { area.name = next.defaultName }
                            area.region = next.region
                        }
                    }), items: Self.presetTabs)
                }
                ExtraAreaPreview(region: area.region, preview: preview) { region in
                    settings.updateExtraArea(id: id) { $0.region = region }
                }
                // Kısayolla bir kez okunan alanın sonucunun yeri (Windows: ek bölgenin "Sonucu Göster"i).
                ResultTargetPicker(target: Binding(get: { area.target }, set: { target in settings.updateExtraArea(id: id) { $0.target = target } }),
                                   hint: shortcutKeys == nil ? nil : "Press its shortcut while playing to translate this area once, even with CouchSubs in the background.")
            }
            .padding(DS.space("m"))
            .background(Color.dsSurface, in: shape)
            .overlay(shape.strokeBorder(Color.dsTileBorder))
        }
    }

    private static let presetTabs: [(ExtraAreaPreset?, LocalizedStringKey)] =
        [(.quest, "Quest"), (.notification, "Notification"), (.phone, "Phone"), (nil, "Custom")]

    /// İlk üç alanın kısayol tuşları (ör. "Num 1", "⌃⇧1"); dördüncü ve sonrakilerin kısayolu yok.
    private var shortcutKeys: [String]? {
        guard let number = settings.extraAreas.firstIndex(where: { $0.id == id }).map({ $0 + 1 }),
              let action = HotkeyAction.areaActions.dropFirst(number - 1).first else { return nil }
        let keys = HotkeyTable.keys(settings.hotkeys, action).map(\.label)
        return keys.isEmpty ? nil : keys
    }

    private func placeHint(_ preset: ExtraAreaPreset?) -> LocalizedStringKey {
        switch preset {
        case .quest: "Top right of the screen."
        case .notification: "Bottom left of the screen."
        case .phone: "Bottom right of the screen."
        case nil: "Drag the frame on the picture to place it."
        }
    }
}

/// Ek alanın adı: kenarlıksız sade giriş (başlık gibi görünür); üzerine gelince ya da yazarken alan zemini ve ince halka.
private struct ExtraAreaNameField: View {
    @Binding var name: String
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        // Uygulamadaki bütün giriş kutuları gibi tam yuvarlak (DSFieldChrome); kalem simgesi kutunun içinde sağda.
        DSFieldChrome {
            TextField("Area Name", text: $name)
                .textFieldStyle(.plain)
                .font(.dsBodyStrong)
        } trailing: {
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dsFaint)
                .padding(.trailing, DS.space("xs"))
                .accessibilityHidden(true)
        }
    }
}

/// "Sonucu Göster": kısayolla bir kez okunan alanın çevirisi TV'de, bu Mac'te ya da ikisinde de (Windows ile aynı seçim).
struct ResultTargetPicker: View {
    @Binding var target: ResultTarget
    var hint: LocalizedStringKey?

    var body: some View {
        DSUnit(title: "Show the Result", hint: hint) {
            DSTabs(selection: $target, items: [(ResultTarget.tv, "On the TV"), (.pc, "On This Mac"), (.both, "On Both")])
        }
    }
}

/// Ek alanın önizlemesi, son PS5 karesiyle (kare değişince yalnız bu görünüm yeniden çizilir).
struct ExtraAreaPreview: View {
    let region: CropRegion
    @ObservedObject var preview: FramePreview
    let onChange: (CropRegion) -> Void

    var body: some View {
        RegionPreview(region: region, frame: preview.image, onChange: onChange)
    }
}

extension ExtraAreaPreset {
    /// Seçimin ekrandaki adı.
    var title: LocalizedStringKey {
        switch self {
        case .quest: "Quest (top right)"
        case .notification: "Notification (bottom left)"
        case .phone: "Phone (bottom right)"
        }
    }

    /// Yeni alanın adı (kullanıcı değiştirebilir).
    var defaultName: String {
        switch self {
        case .quest: String(localized: "Quest")
        case .notification: String(localized: "Notification")
        case .phone: String(localized: "Phone")
        }
    }
}

struct OBSCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var obsCopied = false

    /// OBS'de "Tarayıcı kaynağı" adresi; OBS çoğunlukla CouchSubs ile aynı bilgisayarda çalışır.
    private var obsAddress: String { "http://localhost:\(model.serverPort)/obs?k=\(model.subtitleAccessKey)" }

    var body: some View {
        Card {
            HintText(text: "Streaming with a capture card? In OBS add a Browser source with this address (width 1920, height 1080). The Turkish subtitles appear over the game on your screen and on the stream.")
            AddressRow(address: obsAddress)
            HintText(text: "If OBS runs on another computer, use this Mac's network address instead of localhost. The overlay only shows subtitles while the translation is running.")
            if let networkAddress {
                HintText(text: "Your streaming app does not accept localhost (TikTok LIVE Studio, for example)? Use this address with the computer's network address:")
                AddressRow(address: networkAddress)
            }
            Button("Pair TV") { Task { await model.openTVPairing() } }.buttonStyle(.secondary)
            Button("Renew access key") { model.rotateSubtitleKey() }.buttonStyle(.secondary)
            if model.legacyTVWarning { HintText(text: "The TV app is old. Update it.") }
        }
        StreamWindowCard()
    }

    /// Aynı adres bu Mac'in ağ adresiyle; localhost'u kabul etmeyen yayın programları için.
    private var networkAddress: String? {
        AppModel.localAddress(near: nil).map { "http://\($0):\(model.serverPort)/obs?k=\(model.subtitleAccessKey)" }
    }
}

/// Kopyalanabilir adres satırı.
struct AddressRow: View {
    let address: String
    @State private var copied = false
    @Environment(\.csNewLook) private var newLook

    var body: some View {
        // Yeni arayüzde ayrı Kopyala düğmesi yok: tam yuvarlak kutu, kopyala simgesi kutunun içinde (DSCopyField).
        if newLook {
            DSCopyField(text: address)
        } else {
            legacy
        }
    }

    private var legacy: some View {
        HStack(spacing: Theme.space("m")) {
            Text(verbatim: address)
                .font(.csBody.monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, Theme.space("l"))
                .frame(maxWidth: .infinity, minHeight: Theme.size("buttonHeight"), alignment: .leading)
                .background(Color.csSurface2, in: RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous))
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
                copied = true
            }
            .buttonStyle(.secondary)
            .resetsAfterDelay($copied)
        }
    }
}

/// Şeffaflık tanımayan yayın programları için düz zeminli altyazı penceresi (bkz. StreamWindow.swift).
struct StreamWindowCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card(title: "Stream window") {
            HintText(text: "For streaming apps without a transparent browser source (TikTok LIVE Studio, Streamlabs and others): open the stream window, add it with Window capture (the window is called CouchSubs Stream) and remove its background with a Chroma key filter.")
            DSUnit(title: "Background") {
                DSTabs(selection: $model.streamBackground,
                       items: [(StreamBackground.green, "Green"), (.black, "Black"), (.magenta, "Magenta")])
            }
            Button(model.streamWindowOpen ? "Close the stream window" : "Open the stream window") {
                model.streamWindowOpen.toggle()
            }
            .buttonStyle(.secondary)
            HintText(text: "Keep the window open and uncovered while streaming. Subtitles appear in it while the translation is running, even when they are shown only on the TV.")
        }
    }
}

/// İkinci hesabın PS5 giriş şifresi (isteğe bağlı, 4 hane, Anahtarlık'ta). PS5 isterse oturum açılırken gönderilir.
struct LoginPasscodeCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var passcode = ""
    @State private var invalid = false

    var body: some View {
        Card {
            HintText(text: "Only needed if the second account has a login passcode on the PS5. CouchSubs enters it when the PS5 asks. It is kept in the Keychain.")
            if model.hasLoginPasscode {
                HStack(spacing: Theme.space("m")) {
                    Text("Passcode saved.").font(.csBody)
                    Spacer()
                    Button("Remove passcode") { model.removeLoginPasscode() }.buttonStyle(.secondary)
                }
            } else {
                HStack(spacing: Theme.space("m")) {
                    SecureField("4 digits", text: $passcode).textFieldStyle(CSTextFieldStyle())
                    Button("Save") {
                        invalid = !model.setLoginPasscode(passcode)
                        if !invalid { passcode = "" }
                    }
                    .buttonStyle(.secondary)
                    .disabled(passcode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if invalid {
                    Text("Enter the 4-digit passcode.").font(.csCallout).foregroundStyle(Color.csSecondary)
                }
            }
        }
    }
}

/// Görüntünün nereden okunduğu: CouchSubs PS5'e kendisi bağlanır (ikinci hesap) ya da oyun bu Mac'teki Sony PS Remote
/// Play uygulamasında oynanır ve CouchSubs onun penceresini okur (bkz. `RemotePlayWindowStream`). Çeviri sürerken
/// değiştirilirse yeni kaynakla yeniden başlar.
struct FrameSourceCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Card {
            DSSelectRow(title: "Read the picture from", selection: $model.settings.frameSource,
                        options: [(FrameSource.ps5, String(localized: "The PS5 (second account)")), (FrameSource.remotePlayWindow, String(localized: "Remote Play window on this Mac")), (FrameSource.captureWindow, String(localized: "OBS projector or game window"))])
            if model.settings.frameSource == .remotePlayWindow {
                DSSelectRow(title: "Remote Play app", selection: $model.settings.remotePlayApp,
                            options: [(RemotePlayApp.automatic, String(localized: "Whichever is open")), (RemotePlayApp.sony, String(localized: "PS Remote Play (Sony)")), (RemotePlayApp.chiaki, String(localized: "chiaki-ng"))])
                HintText(text: "Play in PS Remote Play or chiaki-ng on this Mac; CouchSubs reads only that window, so no second account is needed. Show the subtitles on the computer screen, and allow Screen Recording for CouchSubs when macOS asks.")
                // Kurulu olanlar "Kurulu", olmayanlar resmi indirme sayfasına giden düğmeyle (ikisi de denenebilir).
                HStack {
                    Text("PS Remote Play (Sony)")
                    Spacer()
                    if model.remotePlayInstalled(.sony) {
                        Text("Installed").foregroundStyle(Color.csSecondary)
                    } else {
                        Button("Download PS Remote Play") { model.openDownload(for: .sony) }.buttonStyle(.secondary)
                    }
                }
                HStack {
                    Text("chiaki-ng")
                    Spacer()
                    if model.remotePlayInstalled(.chiaki) {
                        Text("Installed").foregroundStyle(Color.csSecondary)
                    } else {
                        Button("Download chiaki-ng") { model.openDownload(for: .chiaki) }.buttonStyle(.secondary)
                    }
                }
            } else if model.settings.frameSource == .captureWindow {
                CaptureWindowPanel()
            } else {
                HintText(text: "CouchSubs connects to the PS5 with the second account. Sony's PS Remote Play can't be used at the same time.")
                if model.needsPS5Link {
                    HStack {
                        Text("The PS5 is not linked yet. Sign in with the second account and pair the PS5.")
                        Spacer()
                        Button("Link account") {
                            model.linkPS5Account()
                            dismiss()
                        }
                        .buttonStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Xbox seçiliyken "Görüntüyü al" (#853; Windows'taki Görüntü kaynağı kartının Xbox seçenekleri): CouchSubs Xbox'a kendisi
/// bağlanır ya da oyun Xbox uygulamasında / play.xbox.com'da / capture card ile OBS'te oynanır ve CouchSubs yalnız seçilen
/// pencereyi okur; o zaman Xbox'a hiç bağlanmaz (Xbox aynı anda tek bağlantıya izin verir, kullanıcının oturumu düşerdi).
struct XboxFrameSourceCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            DSSelectRow(title: "Read the picture from", selection: $model.settings.xboxFrameSource,
                        options: [(XboxFrameSource.xbox, String(localized: "Xbox (this app connects)")), (XboxFrameSource.captureWindow, String(localized: "OBS projector or game window"))])
            HintText(text: "If you play in the Xbox app, on play.xbox.com or with a capture card in OBS, choose this window; CouchSubs doesn't connect to the Xbox separately (the Xbox allows only one connection at a time).")
            if model.readsXboxWindow { CaptureWindowPanel() }
        }
    }
}

/// Uygulamanın görünümü: koyu (varsayılan, onaylı tasarım), açık ya da sistemle aynı. Tüm pencerelere anında uygulanır.
struct AppThemeCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            DSSelectRow(title: "Appearance", selection: $model.settings.appearance,
                        options: [(AppAppearance.dark, String(localized: "Dark")), (AppAppearance.light, String(localized: "Light")), (AppAppearance.system, String(localized: "Same as system"))])
        }
    }
}

struct AboutCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        Card {
            HStack(spacing: Theme.space("m")) {
                Button("About CouchSubs") { model.showAbout = true }.buttonStyle(.secondary)
                Spacer()
                Button("Set up again…") { confirmReset = true }.buttonStyle(.danger)
            }
        }
        .confirmationDialog("Set up again?", isPresented: $confirmReset) {
            Button("Set up again", role: .destructive) {
                model.resetSetup()
                dismiss()
            }
        } message: {
            Text("The saved PS5, account and TV connection will be removed.")
        }
    }
}

/// Oyun paketleri: masaüstünde ücretsiz; kurulu paketler karolar hâlinde, altta paket ve ortak havuz anahtarları
/// (Windows'taki ayarlarla aynı düzen).
struct GamePacksPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var choosingImport = false
    @State private var readingImport = false
    @State private var importSelection: GamePackImportSelection?
    @State private var importError: String?
    /// "Paketleri şimdi güncelle"ye basıldı, sonuç bekleniyor.
    @State private var updating = false
    @State private var updateResult: PackUpdateAlert?
    @State private var showUpdateResult = false
    /// Kurulduğu az önce görülen paketin adı ("Paket kuruldu" başarı anı).
    @State private var celebrated: String?
    @State private var knownPacks: Set<String> = []
    private let columns = [GridItem(.flexible(), spacing: Theme.space("gap"), alignment: .top),
                           GridItem(.flexible(), spacing: Theme.space("gap"), alignment: .top)]
    private let importTypes: [UTType] = [.json, .plainText] + [UTType(filenameExtension: "srt")].compactMap { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space("l")) {
            packList
        }
        .fileImporter(isPresented: $choosingImport, allowedContentTypes: importTypes, onCompletion: readImport)
        .sheet(item: $importSelection) { selection in
            GamePackImportSheet(selection: selection)
        }
        .alert(updateResult?.title ?? "", isPresented: $showUpdateResult, presenting: updateResult) { alert in
            if alert.retry {
                Button("Try again", action: updateNow)
                Button("Close", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            Text(verbatim: alert.message)
        }
    }

    private func updateNow() {
        guard !updating else { return }
        updating = true
        Task {
            let outcome = await model.updatePacksNow()
            updating = false
            guard let outcome else { return }
            updateResult = PackUpdateAlert(outcome, stillUsed: String(localized: "The packs on this computer are still used."))
            showUpdateResult = true
        }
    }

    /// Tuval 21: üstte anahtarlar kartı, altında "KURULU PAKETLER" listesi (kapak, ad, satır sayısı, rozet) ve Paketleri
    /// Şimdi Güncelle / Paket İçe Aktar… (yeni arayüz; Windows aynı düzen).
    @ViewBuilder private var packList: some View {
        DSCard(spacing: DS.space("xxs"), scrolls: false) {
            DSSwitchRow(title: "Use Game Packs",
                        subtitle: "Ready Turkish translations for some games. A line found in the pack appears instantly without going to the translation engine.",
                        isOn: $model.settings.gamePacks)
            if model.settings.usesGamePacks {
                DSSwitchRow(title: "Game Pack Only",
                            subtitle: "Show only subtitles matched in a game pack. Skip lines without a match.",
                            isOn: $model.settings.packOnlySubtitles)
            }
            DSSwitchRow(title: "Send the English Subtitles Read to the Shared Pool",
                        subtitle: "Only the game's English text is sent, anonymously. It helps make better Turkish translations for everyone.",
                        isOn: $model.settings.sharePool)
            // Telefonlardaki Profil › Kullanım verisi ile aynı ad ve açıklama; ölçüm bu derlemede yoksa (Mac App Store) gizli.
            if model.usage.isConfigured {
                DSSwitchRow(title: "Usage Data", subtitle: "Error and usage statistics", isOn: $model.settings.usageData)
            }
            DSSwitchRow(title: "Ask Which Game I'm Playing",
                        subtitle: "If no pack recognises the game, asked once two minutes after translation starts.",
                        isOn: $model.settings.askGame, divider: false)
        }
        DSCard(spacing: DS.space("m"), scrolls: false) {
            DSCardHeader(LocalizedStringKey(model.installedPacks.isEmpty ? "Installed packs"
                                            : String(format: String(localized: "Installed packs · %lld"), GameCatalog.packShelf(model.installedPacks).count))) {
                // Telefonlardaki "Paketleri şimdi güncelle" (Packs.swift): beklerken "Güncelleniyor…", sonuç uyarıda.
                Button(updating ? "Updating Packs…" : "Update Packs Now", action: updateNow)
                    .buttonStyle(DSButtonStyle(kind: .compact, busy: updating))
                    .disabled(updating || !model.canUpdatePacks)
                Button("Import Pack…") {
                    importError = nil
                    choosingImport = true
                }
                .buttonStyle(DSButtonStyle(kind: .compact, busy: readingImport))
                .disabled(readingImport)
            }
            if let importError {
                DSNoticeBox(tone: .error, text: LocalizedStringKey(importError))
            }
            if let celebrated {
                // "Paket kuruldu" başarı anı (≤ 1 sn ışın + yaylı tik); birkaç saniye sonra raf geri gelir.
                DSSuccessMoment(title: "Pack Installed", message: LocalizedStringKey(celebrated))
                    .padding(.vertical, DS.space("m"))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if model.installedPacks.isEmpty {
                Text("No game pack is installed.").dsMuted()
            } else {
                // Kapak rafı (Perde): 3:4 kapaklar; şu an oynanan oyunun kapağı amber halka + kapak ışımasıyla seçili.
                // Oyunun "(ek satırlar)" paketi asıl paketin kapağında (#353).
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: DS.space("m"), alignment: .top)],
                          alignment: .leading, spacing: DS.space("l")) {
                    ForEach(GameCatalog.packShelf(model.installedPacks)) { pack in
                        PackTile(pack: pack, playing: pack.titles.contains { GameName.key($0) == GameName.key(model.gameChoice.game?.name ?? "") })
                    }
                }
                .padding(.vertical, DS.space("xs"))
            }
        }
        .animation(DS.animation(.page, reduced: !model.settings.transitionAnimations), value: celebrated)
        .onChange(of: GameCatalog.packShelf(model.installedPacks).map(\.id)) { ids in
            // Yeni paket geldiyse (içe aktarma, güncelleme) başarı anı; ilk yükleme ve silme sayılmaz.
            defer { knownPacks = Set(ids) }
            guard !knownPacks.isEmpty, let added = GameCatalog.packShelf(model.installedPacks).first(where: { !knownPacks.contains($0.id) }) else { return }
            celebrated = added.title
        }
        .onAppear { knownPacks = Set(GameCatalog.packShelf(model.installedPacks).map(\.id)) }
        .task(id: celebrated) {
            guard celebrated != nil else { return }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            celebrated = nil
        }
    }

    private func readImport(_ result: Result<URL, Error>) {
        guard case .success(let sourceURL) = result else {
            importError = String(localized: "The translation file could not be read.")
            return
        }

        readingImport = true
        Task {
            defer { readingImport = false }
            do {
                importSelection = try await Task.detached(priority: .userInitiated) {
                    let access = sourceURL.startAccessingSecurityScopedResource()
                    defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
                    let size = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= GamePackImporter.maxFileBytes else { throw GamePackImporter.ImportError.fileTooLarge }
                    let data = try GamePackImporter.read(fileAt: sourceURL)
                    let preview = try GamePackImporter.parse(data, fileName: sourceURL.lastPathComponent)
                    // Kaç satır kabul edildi, kaçı neden atlandı (#1355).
                    SubtitleLog.write(preview.logLine(fileName: sourceURL.lastPathComponent))
                    return GamePackImportSelection(sourceURL: sourceURL, preview: preview)
                }.value
            } catch is GamePackImporter.ImportError {
                importError = String(localized: "The translation file could not be imported. Check its format and encoding.")
            } catch {
                importError = String(localized: "The translation file could not be read.")
            }
        }
    }
}

struct GamePackImportSelection: Identifiable, Sendable {
    let id = UUID()
    let sourceURL: URL
    let preview: GamePackImportPreview
}

struct GamePackImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let selection: GamePackImportSelection
    @State private var title: String
    @State private var installing = false
    @State private var confirmReplacement = false
    @State private var installError: String?

    init(selection: GamePackImportSelection) {
        self.selection = selection
        _title = State(initialValue: selection.preview.suggestedTitle ?? selection.sourceURL.deletingPathExtension().lastPathComponent)
    }

    private var canInstall: Bool {
        !installing && !selection.preview.entries.isEmpty && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let preview = selection.preview
        VStack(alignment: .leading, spacing: Theme.space("m")) {
            Text("Import game pack").font(.csTitle)
            VStack(alignment: .leading, spacing: Theme.space("xs")) {
                Text("Game title")
                TextField("Game title", text: $title)
                    .textFieldStyle(CSTextFieldStyle())
                    .labelsHidden()
                    .disabled(installing)
            }
            // Kabul edilen ve nedenine göre atlanan kayıtlar (#1355; telefonlar ve Windows aynı satırlar).
            Grid(alignment: .leading, horizontalSpacing: Theme.space("gap"), verticalSpacing: Theme.space("xs")) {
                countRow("Usable entries", preview.acceptedCount)
                if !preview.segments.isEmpty { countRow("Sentence segments", preview.segments.count) }
                countRow("Skipped records", preview.skippedCount)
                ForEach(PackImportReport.reasons(preview), id: \.label) { row in
                    countRow(LocalizedStringKey(row.label), row.count)
                }
                countRow("Duplicate pairs", preview.duplicateCount)
                countRow("Conflicting entries", preview.conflictCount)
            }
            if let note = PackImportReport.fuzzyNote(preview) {
                Text(LocalizedStringKey(note)).font(.dsCaption).foregroundStyle(preview.fuzzyDropped ? Color.csWarning : Color.dsMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if selection.preview.entries.isEmpty {
                Text("The file contains no usable translations.")
                    .foregroundStyle(Color.csWarning)
            }
            ErrorText(error: installError)
            HStack {
                if installing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(CSButtonStyle(kind: .secondary, height: "buttonLarge"))
                    .keyboardShortcut(.cancelAction)
                    .disabled(installing)
                Button("Install pack") { install(replacing: false) }
                    .buttonStyle(CSButtonStyle(kind: .primary, height: "buttonLarge"))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInstall)
            }
        }
        .padding(Theme.space("screen"))
        .frame(width: 440, alignment: .leading)
        .appSurface()
        .interactiveDismissDisabled(installing)
        .alert("Replace game pack?", isPresented: $confirmReplacement) {
            Button("Cancel", role: .cancel) {}
            Button("Replace pack", role: .destructive) { install(replacing: true) }
        } message: {
            Text("A game pack with this ID already exists. Replacing it will overwrite the installed pack.")
        }
    }

    private func countRow(_ label: LocalizedStringKey, _ count: Int) -> some View {
        GridRow {
            Text(label)
            Text(count, format: .number).monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }

    private func install(replacing: Bool) {
        guard canInstall else { return }
        installError = nil
        installing = true
        let title = self.title
        let selection = self.selection
        let packs = model.packs
        Task {
            defer { installing = false }
            do {
                model.installedPacks = try await Task.detached(priority: .userInitiated) {
                    let sourceURL = selection.sourceURL
                    let access = sourceURL.startAccessingSecurityScopedResource()
                    defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
                    try GamePackImporter.install(selection.preview, title: title, directory: GamePackLibrary.userDirectory,
                                                 replacing: replacing, sourceURL: sourceURL)
                    SubtitleLog.write(selection.preview.installLog(title: title))
                    packs.reload()
                    return packs.packs
                }.value
                dismiss()
            } catch GamePackImporter.ImportError.destinationExists {
                confirmReplacement = true
            } catch GamePackImporter.ImportError.sourceIsDestination {
                installError = String(localized: "The selected file is already at the install location. Choose a different game title.")
            } catch {
                installError = String(localized: "The game pack could not be installed.")
            }
        }
    }
}

/// Paket karosu: oyunun kısaltması, adı ve satır sayısı.
struct PackTile: View {
    let pack: PackShelfItem
    /// Şu an oynanan oyunun paketi: kapak seçili (amber halka + kapak ışıması).
    var playing = false
    /// Kapak değişince karo yeniden çizilir (dosya aynı adla değişir).
    @State private var coverVersion = 0
    @State private var coverFailed = false

    /// Adın kelimelerinin baş harfleri (en çok üç): "Red Dead Redemption 2" → "RDR".
    private var initials: String {
        let words = pack.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return String(words.prefix(3).compactMap(\.first)).uppercased()
    }

    /// Kullanıcının seçtiği kapak (Windows ile aynı: yalnız bu bilgisayarda, ~/Library/Application Support/CouchSubs/covers).
    private var cover: NSImage? {
        _ = coverVersion
        guard let file = GameCoverStore.url(for: pack.id), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return NSImage(contentsOf: file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space("xs")) {
            // Kapak (Perde oyun kapağı; görsel yoksa adından türeyen degrade); tıklayınca kapak seçilir, sağ tıkta seç/kaldır
            // (Windows ile aynı).
            Button(action: chooseCover) {
                DSGameCover(title: pack.title, image: cover.map { Image(nsImage: $0) }, status: playing ? "Playing" : nil,
                            selected: playing, width: 120)
            }
            .buttonStyle(DSFocusPlainStyle(cornerRadius: DS.radius("cover")))
            .help(Text("Choose game cover…"))
            .accessibilityLabel(Text(verbatim: pack.title))
            .contextMenu {
                Button("Choose game cover…", action: chooseCover)
                Button("Remove game cover") {
                    GameCoverStore.remove(for: pack.id)
                    coverVersion += 1
                }
                .disabled(cover == nil)
            }
            HStack(spacing: DS.space("xxs")) {
                Circle().fill(Color.dsSuccess).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(verbatim: String(format: String(localized: "%@ lines"), pack.entries.formatted()))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.dsMuted)
                    .lineLimit(1)
            }
            if coverFailed {
                Text("The game cover could not be saved.").font(.dsCaption).foregroundStyle(Color.dsLive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 120, alignment: .leading)
    }

    /// Resim seçilir, ortasından kare kesilip 128 piksellik PNG olarak kaydedilir (Windows ChoosePackCover ile aynı).
    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose game cover…")
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coverFailed = false
        do {
            try GameCoverStore.save(try Self.thumbnail(of: url), for: pack.id)
            coverVersion += 1
        } catch {
            coverFailed = true
        }
    }

    enum CoverError: Error { case unreadable }

    static func thumbnail(of url: URL, side target: Int = 128) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { throw CoverError.unreadable }
        let side = min(image.width, image.height)
        guard side > 0, let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)),
              let context = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CoverError.unreadable }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let thumb = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: thumb).representation(using: .png, properties: [:])
        else { throw CoverError.unreadable }
        return png
    }
}

/// Açık/kapalı ayar: başlık (`body`) solda, anahtar sağda. Onay kutusu kullanılmaz.
/// Otomatik ekran yazısında hangi türler çevrilir (iPhone: Profile, Windows: SettingsWindow, Android: ProfileScreens).
struct ScreenTextKindRows: View {
    @Binding var settings: UserSettings

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space("s")) {
            Text("Which on-screen text to translate").font(.dsBodyStrong).foregroundStyle(Color.dsText)
            // Telefon türü ayrı satır değil: tek "GTA 6 Telefonunu Çevir" anahtarı onu da yazar (`translatesGamePhone`).
            SwitchRow(title: "Mission and objective text", isOn: $settings.screenTextMission)
            SwitchRow(title: "Help boxes and actions (button prompts)", isOn: $settings.screenTextHelp)
            SwitchRow(title: "Menus (pause, map, settings)", isOn: $settings.screenTextMenus)
            SwitchRow(title: "Write the translation beside menu text", isOn: $settings.screenTextBeside)
            SwitchRow(title: "Other on-screen text", isOn: $settings.screenTextOther)
            HintText(text: "Translate the screen always translates everything.")
        }
        .padding(.leading, Theme.space("m"))
    }
}

struct SwitchRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    /// Yeni arayüzde açıklama anahtarın birimine girer (başlığın altında); eski arayüzde çağıran ayrıca yazar.
    var hint: LocalizedStringKey?
    @Environment(\.csNewLook) private var newLook

    var body: some View {
        // Yeni arayüzde anahtar satırın başında, yazının solunda (amber); DSSwitchRow ile aynı birim.
        if newLook {
            DSSwitchRow(title: title, subtitle: hint, isOn: $isOn)
        } else {
            VStack(alignment: .leading, spacing: Theme.space("s")) {
                legacy
                if let hint { HintText(text: hint) }
            }
        }
    }

    private var legacy: some View {
        HStack(spacing: Theme.space("m")) {
            Text(title).font(.csBody).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.space("m"))
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.csAccent)
        }
    }
}

/// Çeviri motoru: ücretsiz cihaz üstü çeviri ya da kullanıcının kendi anahtarıyla DeepL, Gemini, OpenAI, Claude
/// (Windows'taki ayarlarla aynı düzen).
/// Android TV'de PS5 görüntüsünün nasıl gösterileceği; bazı TV'lerde (ör. TCL) uygulama içindeki görüntü siyah kalıyor.
struct AndroidDisplayModePicker: View {
    @Binding var mode: TVDisplayMode

    var body: some View {
        DSSelectRow(title: "Picture mode", selection: $mode,
                    options: [(TVDisplayMode.auto, String(localized: "Automatic (recommended)")), (TVDisplayMode.inApp, String(localized: "Inside the app")), (TVDisplayMode.overlay, String(localized: "Overlay (for a black screen)"))])
        HintText(text: "Automatic uses Overlay whenever the TV app allows it: the TV shows the PS5 on its own HDMI input and the subtitles appear on top. On some TVs the picture stays black inside the CouchSubs TV app. To show the PS5 inside the CouchSubs TV app instead, choose Inside the app; the TV app then never switches to Overlay by itself: if no picture arrives, it reopens the HDMI input and lists the inputs, and you can choose Overlay there. With Overlay the TV also keeps its picture mode, Game mode and HDR. The TV app from Google Play has no Overlay mode: there Automatic stays inside the app, and the TV says so on screen if Overlay is chosen.")
    }
}

struct TranslationCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        let engine = model.settings.translationEngine
        Card(title: "Translation engine") {
            EngineTiles(engine: $model.settings.translationEngine)
            HintText(text: Self.explanation(engine))
            if engine != .free, model.settings.sourceLanguage != "en" {
                HintText(text: "Online engines translate English games only. For other game languages the free translation is used.")
            }
            switch engine {
            case .free:
                // Ücretsiz çeviri zayıf kalıyor; ücretsiz Gemini anahtarı en kolay iyileştirme.
                HStack(spacing: Theme.space("m")) {
                    Text("For better translation, get a free Gemini key.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Get a free key") {
                        model.chooseFreeGemini()
                        openURL(AIProvider.gemini.keyPage)
                    }
                    .buttonStyle(.secondary)
                }
            case .deepL: DeepLKeySection()
            case .gemini, .openAI, .claude:
                if let provider = engine.aiProvider { AIKeySection(provider: provider).id(provider) }
            case .local: LocalAISection()
            }
            // Ek talimat (#306) yalnız yapay zekâ motorlarında (Gemini, OpenAI, Claude, yerel model); DeepL'de yoktur.
            if engine.aiProvider != nil { AIInstructionSection() }
            if engine == .gemini {
                Toggle("I use a paid Gemini API key", isOn: $model.settings.geminiPaidTier)
                HintText(text: "Paid API keys may incur charges. Google still enforces quotas.")
                HintText(text: FreeGemini.privacy)
                if !model.settings.geminiPaidTier {
                    HintText(text: FreeGemini.limit)
                }
            }
        }
        Card(title: "Advanced") {
            SwitchRow(title: "Check unchanged subtitle areas more often", isOn: $model.settings.fastSubtitleDetection)
            HintText(text: "When the subtitle area looks unchanged, read it again after 2 frames instead of 20. Uses more CPU.")
            // Windows'taki iki bekleme kaydırıcısı (aynı metin, aralık 0–1 sn, 0,1 sn adım; varsayılan 0,8 ve 0,3 sn).
            HintText(text: "These waits only delay lines that were read badly; most lines are shown without waiting. A shorter wait shows those lines sooner but lets more wrong translations through.")
            WaitSlider(title: "Wait for a misread line", ms: $model.settings.misreadWaitMs)
            HintText(text: "When a line is read with words that are not in the dictionary, a better reading is awaited for at most this long. Measured in GTA V, translations from misread lines compared with 0 s: 0.2 s → 77%, 0.4 s → 49%, 0.6 s → 41%, 0.8 s (recommended) → 34%, 1.0 s → 31%.")
            WaitSlider(title: "Wait for a half-read line", ms: $model.settings.partialWaitMs)
            HintText(text: "When a line looks cut off (no sentence ending, such as a mission text with a colored word), the full line is awaited for at most this long. Its effect is small: at 0 s a few more lines arrive cut off. Recommended: 0.3 s.")
            Button("Restore defaults") {
                model.settings.misreadWaitMs = SubtitlePipeline.packWaitMs
                model.settings.partialWaitMs = SubtitlePipeline.cleanWaitMs
            }
            .buttonStyle(.secondary)
        }
    }

    private static func explanation(_ engine: TranslationEngine) -> LocalizedStringKey {
        switch engine {
        case .free: "Free. Apple's translation runs on this Mac; subtitle text never leaves it."
        case .deepL: "Optional. With your own free DeepL key, translations read more naturally. Subtitle text is sent to DeepL; when DeepL cannot be reached, the translation model on this computer takes over."
        case .gemini: "Google's AI translates with the game's tone and keeps names as they are. Subtitle text is sent to Google with your own key, and any cost is billed to your Google account. When Gemini cannot be reached, the free translation takes over."
        case .openAI: "OpenAI's AI translates with the game's tone and keeps names as they are. Subtitle text is sent to OpenAI with your own key, and any cost is billed to your OpenAI account. When OpenAI cannot be reached, the free translation takes over."
        case .claude: "Anthropic's Claude translates with the game's tone and keeps names as they are. Subtitle text is sent to Anthropic with your own key, and any cost is billed to your Anthropic account. When Claude cannot be reached, the free translation takes over."
        case .local: "Free, with no quota. An AI model on this computer (Ollama or LM Studio) translates; subtitle text never leaves it. Speed depends on your computer. When the model cannot be reached, the free translation takes over."
        }
    }

    /// Çevrimiçi motor hatasının kullanıcıya söylenişi (ayarlar ve ana ekran aynı metni kullanır). Yerel modelde
    /// `server` sunucunun adresini ve modeli iletiye koyar.
    static func describe(_ state: OnlineKeyState, engine: TranslationEngine, server: LocalAIServer? = nil) -> String {
        OnlineIssueText.describe(state, engine: engine, server: server,
                                 keychainFailure: String(localized: "The API key could not be saved to the Mac keychain."))
    }

    /// Yerel model sunucusunun (Ollama, LM Studio) hatası; sunucunun türüne göre ne yapılacağı söylenir (Windows ile aynı).
    static func describeLocal(_ state: OnlineKeyState, server: LocalAIServer?) -> String {
        LocalAIText.describe(state, server: server, keychainFailure: String(localized: "The API key could not be saved to the Mac keychain."))
    }
}

/// Çeviri motoru seçimi: altı karo (iki sıra), seçili olan sarı çerçeveli ve parlak.
struct EngineTiles: View {
    @Binding var engine: TranslationEngine
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.space("m"), alignment: .top), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.space("m")) {
            ForEach(TranslationEngine.allCases, id: \.self) { option in
                EngineTile(option: option, selected: option == engine) { engine = option }
            }
        }
    }
}

struct EngineTile: View {
    let option: TranslationEngine
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.space("hair")) {
                Text(verbatim: name).font(.csHeadline).foregroundStyle(Color.csText)
                Text(caption).font(.csCaption).foregroundStyle(Color.csSecondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            // Seçili olmayan karo üzerine gelince yüzey-2 zemin alır.
            .tile(selected ? .active : .plain, padding: Theme.space("m"), fill: hovering && !selected ? Color.csSurface2 : Color.csSurface)
        }
        // Zemini karo değiştirir; düğme biçemi yalnız klavye odağının çerçevesini çizer.
        .buttonStyle(RowButtonStyle(radius: "card", hoverFill: nil))
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var name: String {
        option == .free ? String(localized: "Free") : option.displayName
    }

    private var caption: LocalizedStringKey {
        switch option {
        case .free: "On this computer, offline"
        case .deepL, .gemini: "With a free key"
        case .openAI, .claude: "With your own key"
        case .local: "Ollama or LM Studio, no quota"
        }
    }
}

/// DeepL anahtarı: kaydedilince bu ayki kullanım görünür.
struct DeepLKeySection: View {
    @EnvironmentObject private var model: AppModel
    @State private var key = ""
    @State private var checking = false
    @State private var status: OnlineKeyCheck?

    var body: some View {
        if model.hasDeepLKey {
            Button("Remove key") {
                model.removeDeepLKey()
                status = nil
            }
            .buttonStyle(.secondary)
        } else {
            HStack(spacing: Theme.space("m")) {
                SecureField("DeepL API key", text: $key).textFieldStyle(CSTextFieldStyle())
                Button("Save and test") {
                    checking = true
                    Task {
                        status = await model.setDeepLKey(key)
                        if model.hasDeepLKey { key = "" }
                        checking = false
                    }
                }
                .buttonStyle(.secondary)
                .disabled(checking || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Link("Get a free DeepL API key", destination: URL(string: "https://www.deepl.com/pro-api")!)
                .font(.csCallout)
        }
        Group {
            if let status {
                Text(DeepLUsageText.describe(status, quotaUsedUp: String(localized: "This month's DeepL limit is used up. Until it renews, the translation model on this computer translates.")))
                    .font(.csCallout)
                    .foregroundStyle(Color.csSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            if model.hasDeepLKey { status = await model.deepLUsage() }
        }
    }

}

/// Yapay zekâ modeli (yalnız listedekiler), anahtar ve örnek satırla deneme.
struct AIKeySection: View {
    @EnvironmentObject private var model: AppModel
    let provider: AIProvider
    @State private var key = ""
    @State private var checking = false
    @State private var result: Result<String, AIFailure>?

    private var engine: TranslationEngine { TranslationEngine(provider) }

    var body: some View {
        // Model adı yazılamaz; yalnız ortak listedeki modeller seçilir.
        DSSelectRow(title: "Model", selection: Binding(get: { provider.model(model.settings.model(for: provider)).id },
                                                    set: { model.settings.setModel($0, for: provider) }),
                    options: provider.models.map { ($0.id, String(localized: String.LocalizationValue($0.label))) })
        if model.hasKey(engine) {
            HStack(spacing: Theme.space("m")) {
                DoneLabel(text: String(localized: "Key saved"))
                Spacer()
                Button(checking ? LocalizedStringKey("Testing…") : LocalizedStringKey("Test")) {
                    run { await model.testAIKey(for: provider) }
                }
                .buttonStyle(.secondary)
                .disabled(checking)
                Button("Remove key") {
                    model.removeKey(engine)
                    result = nil
                }
                .buttonStyle(.secondary)
            }
        } else {
            HStack(spacing: Theme.space("m")) {
                SecureField("API key", text: $key).textFieldStyle(CSTextFieldStyle()).disabled(checking)
                Button(checking ? LocalizedStringKey("Testing…") : LocalizedStringKey("Save and test")) {
                    let typed = key
                    run {
                        let result = await model.setAIKey(typed, for: provider)
                        if model.hasKey(engine) { key = "" }
                        return result
                    }
                }
                .buttonStyle(.secondary)
                .disabled(checking || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if model.settings.translationEngine == engine {
                HintText(text: "Add your key to start. Until then the free translation is used.")
            }
            Link(String(format: String(localized: "Get a %@ API key"), provider.displayName), destination: provider.keyPage)
                .font(.csCallout)
        }
        if let result {
            switch result {
            case .success(let sample):
                Text(String(format: String(localized: "It works. Sample translation: %@"), sample))
                    .font(.csCallout)
                    .foregroundStyle(Color.csSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failure(let failure):
                ErrorText(error: TranslationCard.describe(OnlineKeyState(failure), engine: engine))
            }
        }
    }

    private func run(_ work: @escaping () async -> Result<String, AIFailure>) {
        checking = true
        result = nil
        Task {
            result = await work()
            checking = false
        }
    }
}

/// Yerel model (Ollama, LM Studio): sunucu adresi, model adı (kullanıcı yazar), isteğe bağlı anahtar ve "Bağlantıyı
/// dene" (Windows'taki ayarlarla aynı). Adres ve model, alandan çıkınca ya da Return'e basınca kaydedilir; her tuşta
/// çeviri hattı yeniden kurulmasın.
/// Ayarlardaki "Ek talimat" (#306): yapay zekâ çevirmeninin talimatının sonuna eklenir. Alandan çıkınca kaydedilir; her
/// tuşta çeviri hattı yeniden kurulmaz (Windows ile aynı).
struct AIInstructionSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("s")) {
            Text("Extra instruction")
            TextField("Extra instruction", text: $text, prompt: Text("Example: Translate swear words without softening them."),
                      axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(CSTextFieldStyle())
                .focused($focused)
                .onChange(of: text) { value in
                    if value.count > AIRequest.maxInstructionLength { text = String(value.prefix(AIRequest.maxInstructionLength)) }
                }
            HintText(text: "Added to the end of the AI translator's instructions (up to 1000 characters). Leave it empty if you don't need it.")
        }
        .onAppear { text = model.settings.aiInstruction }
        .onChange(of: focused) { _ in commit() }
        .onDisappear(perform: commit)
    }

    private func commit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value != model.settings.aiInstruction { model.settings.aiInstruction = value }
    }
}

struct LocalAISection: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = ""
    @State private var modelName = ""
    @State private var key = ""
    @State private var checking = false
    @State private var result: Result<String, AIFailure>?
    @FocusState private var focused: Field?

    private enum Field { case address, model }

    var body: some View {
        Group {
            Grid(alignment: .leading, horizontalSpacing: Theme.space("m"), verticalSpacing: Theme.space("s")) {
                GridRow {
                    Text("Server address")
                    TextField("Server address", text: $address, prompt: Text(verbatim: LocalAIServer.ollamaURL))
                        .textFieldStyle(CSTextFieldStyle())
                        .focused($focused, equals: .address)
                        .onSubmit(commit)
                }
                GridRow {
                    Text("Model name")
                    TextField("Model name", text: $modelName, prompt: Text(verbatim: LocalAIServer.defaultModel))
                        .textFieldStyle(CSTextFieldStyle())
                        .focused($focused, equals: .model)
                        .onSubmit(commit)
                }
            }
            HStack(spacing: Theme.space("m")) {
                Button("Use Ollama") { use(LocalAIServer.ollamaURL) }.buttonStyle(.secondary)
                Button("Use LM Studio") { use(LocalAIServer.lmStudioURL) }.buttonStyle(.secondary)
                Spacer()
            }
            if LocalAIServer.normalize(address) == nil {
                ErrorText(error: String(format: String(localized: "This address is not valid. Example: %@"), LocalAIServer.ollamaURL))
            }
            HintText(text: "Type the model name as the server shows it. In Ollama, download it first: ollama pull qwen2.5:7b (downloaded models: ollama list). In LM Studio, load the model and start the local server.")
            if model.hasKey(.local) {
                HStack(spacing: Theme.space("m")) {
                    DoneLabel(text: String(localized: "Key saved"))
                    Spacer()
                    Button("Remove key") {
                        model.removeKey(.local)
                        result = nil
                    }
                    .buttonStyle(.secondary)
                }
            } else {
                SecureField("API key (optional)", text: $key).textFieldStyle(CSTextFieldStyle())
            }
            HStack(spacing: Theme.space("m")) {
                Button(checking ? LocalizedStringKey("Testing…") : LocalizedStringKey("Test connection")) { test() }
                    .buttonStyle(.secondary)
                    .disabled(checking || LocalAIServer.normalize(address) == nil)
                Spacer()
                Link("Download Ollama", destination: AIProvider.local.keyPage).font(.csCallout)
            }
            if let result {
                switch result {
                case .success(let sample):
                    Text(String(format: String(localized: "It works. Sample translation: %@"), sample))
                        .font(.csCallout)
                        .foregroundStyle(Color.csSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .failure(let failure):
                    ErrorText(error: TranslationCard.describe(OnlineKeyState(failure), engine: .local, server: model.settings.localAIServer))
                }
            }
        }
        .onAppear {
            address = model.settings.localAIBaseURL
            modelName = model.settings.localAIModel
        }
        .onChange(of: focused) { _ in commit() }
    }

    private func use(_ url: String) {
        address = url
        commit()
    }

    /// Yazılanı ayara yazar; değiştiyse eski deneme sonucu kalkar.
    private func commit() {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address != model.settings.localAIBaseURL || name != model.settings.localAIModel else { return }
        model.settings.localAIBaseURL = address
        model.settings.localAIModel = name
        result = nil
    }

    private func test() {
        commit()
        let typed = key
        checking = true
        result = nil
        Task {
            result = await model.testLocalAI(key: typed)
            if model.hasKey(.local) { key = "" }
            checking = false
        }
    }
}

/// Özel bölgenin dikey konumu ve yüksekliği (yüzde); yeni kaydırıcı satırıyla (Windows: CustomPanel, aynı düzen).
struct CustomAreaSliders: View {
    @Binding var settings: UserSettings

    var body: some View {
        let percent = settings.region.verticalPercent
        VStack(alignment: .leading, spacing: DS.space("m")) {
            DSSliderRow(title: "Vertical Position", valueText: percentText(percent.position),
                        value: Binding(get: { percent.position },
                                       set: { settings.setCustomRegion(settings.region.withVertical(position: $0, height: percent.height)) }),
                        range: 0...max(1, 100 - percent.height))
            DSSliderRow(title: "Height", valueText: percentText(percent.height),
                        value: Binding(get: { percent.height },
                                       set: { settings.setCustomRegion(settings.region.withVertical(position: percent.position, height: $0)) }),
                        range: CropRegion.minimumSize * 100...100)
        }
    }
}

/// Bekleme süresi kaydırıcısı: 0–1 sn, 0,1 sn adım; başlık solda, değer sağda ("0,8 sn"), altında tam genişlikte
/// kaydırıcı ve tek cümlelik açıklama. Değer milisaniye olarak saklanır (Windows: MisreadWait/PartialWait, aynı düzen).
struct WaitSlider: View {
    let title: LocalizedStringKey
    var hint: LocalizedStringKey?
    @Binding var ms: Int

    var body: some View {
        let seconds = Double(min(max(ms, 0), UserSettings.waitSliderMaxMs)) / 1000
        let unit = String(localized: "sec")
        DSSliderRow(title: title, valueText: "\(seconds.formatted(.number.precision(.fractionLength(1)))) \(unit)",
                    value: Binding(get: { seconds }, set: { ms = Int(($0 * 10).rounded()) * 100 }),
                    range: 0...Double(UserSettings.waitSliderMaxMs) / 1000, step: 0.1, hint: hint)
    }
}
