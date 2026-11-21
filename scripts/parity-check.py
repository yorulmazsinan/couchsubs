#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Platform eşitliği denetimi (KALICI KURAL: Windows = Mac, Android = iPhone). Üç karşılaştırma yapar (üçüncüsü:
# CAPABILITIES, ortak çekirdek yeteneklerinin ve ortak deneme dosyalarının her platformda bulunması):
#  1. Masaüstü ayarları: Windows UserSettings kaydının (windows/src/CouchSubs.Shell/Contracts.cs) alanları ile Mac'in
#     kullandığı ortak UserSettings'in (core/.../AppSettings.swift) alanları. Ad büyük/küçük harf gözetmeden eşlenir.
#  2. Telefon ayar ekranları: iPhone Profil/Ayarlar ekranlarının (couchsubs-ios/CouchSubs/UI/Profile.swift, DubbingTile.swift) kullandığı
#     Localizable.xcstrings anahtarları ile Android Profil/Ayarlar ekranlarının (ui/ProfileScreens.kt, DubbingTile.kt) kullandığı
#     strings.xml metinleri. Eşleme İngilizce metinle yapılır (Android values-en metni = xcstrings anahtarı).
# Bir tarafta olup öbüründe olmayan her şey ya eşlenmeli ya da scripts/parity-allowlist.json'da gerekçesiyle yazılmalı.
# İzin listesindeki bir kayıt artık fark değilse o da hatadır (liste eskimesin).
# Kullanım: python3 scripts/parity-check.py   (fark varsa çıkış kodu 1)
import json, pathlib, re, sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "scripts" / "parity-allowlist.json"
CATALOG = ROOT / "mac" / "CouchSubs" / "Resources" / "Localizable.xcstrings"
WIN_SETTINGS = ROOT / "windows" / "src" / "CouchSubs.Shell" / "Contracts.cs"
CORE_SETTINGS = ROOT / "core" / "Sources" / "CouchSubsCore" / "Pipeline" / "AppSettings.swift"
IOS_SCREENS = [ROOT / "couchsubs-ios" / "CouchSubs" / "UI" / name for name in ("Profile.swift", "DubbingTile.swift", "LocalAISection.swift")] + [
    ROOT / "mac" / "CouchSubs" / "UI" / name for name in ("DubbingVoiceText.swift", "LocalAIText.swift")]
ANDROID_SCREENS = [ROOT / "couchsubs-android" / "app" / "src" / "main" / "java" / "com" / "couchsubs" / "mobile" / "ui" / name
                   for name in ("ProfileScreens.kt", "DubbingTile.kt", "LocalAiSection.kt")]
ANDROID_EN = ROOT / "couchsubs-android" / "app" / "src" / "main" / "res" / "values-en" / "strings.xml"
CORE_FIXTURES = ROOT / "core" / "Tests" / "CouchSubsCoreTests" / "Fixtures"
ANDROID_FIXTURES = ROOT / "couchsubs-android" / "app" / "src" / "test" / "resources" / "fixtures"

_CORE = "core/Sources/CouchSubsCore/"
_WIN = "windows/src/CouchSubs.Core/"
_DROID = "couchsubs-android/app/src/main/java/com/couchsubs/mobile/core/"
_CORE_TESTS = "core/Tests/CouchSubsCoreTests/"
_WIN_TESTS = "windows/tests/CouchSubs.Core.Tests/"
_DROID_TESTS = "couchsubs-android/app/src/test/java/com/couchsubs/mobile/core/"

# 3. Ortak çekirdek yetenekleri: her yetenek her platformda (Mac/iPhone ortak çekirdeği, Windows, Android) kodda bulunmalı
# ve ortak deneme dosyasını okuyan testi olmalı. (platform, dosya, düzenli ifade) üçlüleri; biri eksikse denetim kırmızı.
# Android'de "RECENTER 13" gibi yanlış okunmuş tuş simgesi kutuda kalıyordu: markFree yalnız Mac ve Windows'taydı (#860).
CAPABILITIES = {
    "Görüntüden tuş simgesi bulma (markFree)": [
        ("mac", _CORE + "ButtonIcons.swift", r"static func markFree\("),
        ("windows", _WIN + "ButtonIcons.cs", r"public static TextLine MarkFree\("),
        ("android", _DROID + "ButtonIcons.kt", r"fun markFree\("),
    ],
    "Renksiz simge denetimi (portre/harita simge sayılmaz)": [
        ("mac", _CORE + "ButtonIcons.swift", r"static func isColourless\("),
        ("windows", _WIN + "ButtonIcons.cs", r"static bool IsColourless\("),
        ("android", _DROID + "ButtonIcons.kt", r"fun isColourless\("),
    ],
    "\"Ekranı çevir\"de satır ucundaki kısa parçayı görüntüden doğrulama (hasShortEdge)": [
        ("mac", _CORE + "ScreenTranslation.swift", r"hasShortEdge\(line\) \? ButtonIcons\.markFree"),
        ("windows", _WIN + "ScreenTranslation.cs", r"HasShortEdge\(line\) \? ButtonIcons\.MarkFree"),
        ("android", _DROID + "ScreenTranslation.kt", r"hasShortEdge\(line\) -> ButtonIcons\.markFree"),
    ],
    "Ek alanda görüntüden tuş simgesi (otomatik alanda yalnız renksiz)": [
        ("mac", _CORE + "RegionWatcher.swift", r"withButtonIcons\(frame: frame, monochrome: auto\)"),
        ("windows", _WIN + "RegionWatcher.cs", r"WithButtonIcons\(frame, monochrome: auto\)"),
        ("android", _DROID + "Areas.kt", r"withButtonIcons\(frame, color, monochrome = auto\)"),
    ],
    "Otomatik/hazır alanda kısa etiketler ayrı blok (autoGroups)": [
        ("mac", _CORE + "RegionWatcher.swift", r"static func autoGroups\("),
        ("windows", _WIN + "RegionWatcher.cs", r"AutoGroups\("),
        ("android", _DROID + "Areas.kt", r"fun autoGroups\("),
    ],
    "Ortak deneme dosyası free-button-icons.json": [
        ("mac", _CORE_TESTS + "FreeButtonIconsTests.swift", r"free-button-icons\.json"),
        ("windows", _WIN_TESTS + "FreeButtonIconsTests.cs", r"free-button-icons\.json"),
        ("android", _DROID_TESTS + "FreeButtonIconsTest.kt", r"free-button-icons\.json"),
    ],
    "Arayüz sözlüğü: tuş çubuğu sözlük biçimiyle, menü etiketi özgün biçimiyle (translate / translateLabel / translateLabelLoosely)": [
        ("mac", _CORE + "UiCommands.swift", r"static func translateLabelLoosely\("),
        ("windows", _WIN + "UiCommands.cs", r"public static string\? TranslateLabelLoosely\("),
        ("android", _DROID + "UiCommands.kt", r"fun translateLabelLoosely\("),
    ],
    "Ortak deneme dosyası ui-commands.json": [
        ("mac", _CORE_TESTS + "UiCommandsTests.swift", r"ui-commands\.json"),
        ("windows", _WIN_TESTS + "UiCommandsTests.cs", r"ui-commands\.json"),
        ("android", _DROID_TESTS + "UiCommandsTest.kt", r"ui-commands\.json"),
    ],
    "Ortak deneme dosyası screen-menu.json": [
        ("mac", _CORE_TESTS + "ScreenMenuBarTests.swift", r"screen-menu\.json"),
        ("windows", _WIN_TESTS + "ScreenMenuBarTests.cs", r"screen-menu\.json"),
        ("android", _DROID_TESTS + "ScreenMenuBarTest.kt", r"screen-menu\.json"),
    ],
    "Ortak deneme dosyası mission-card.json": [
        ("mac", _CORE_TESTS + "MissionCardTests.swift", r"mission-card\.json"),
        ("windows", _WIN_TESTS + "MissionCardTests.cs", r"mission-card\.json"),
        ("android", _DROID_TESTS + "MissionCardTest.kt", r"mission-card\.json"),
    ],
    # Yalnız masaüstü (#853): Xbox seçiliyken görüntü Xbox uygulaması / play.xbox.com / capture card ile OBS penceresinden
    # okunur, CouchSubs Xbox'a bağlanmaz. iPhone ve Android'de okunacak bilgisayar penceresi yoktur; telefonlarda bu seçim
    # bilinçli olarak yoktur (Android = iPhone eşitliği bozulmaz). Windows = Mac eşitliği burada denetlenir.
    "Xbox'ta seçilen pencereden okuma, Xbox'a bağlanmadan (yalnız masaüstü)": [
        ("mac", "mac/CouchSubs/AppModel+CaptureWindow.swift", r"var readsXboxWindow: Bool"),
        ("mac", "mac/CouchSubs/UI/XboxViews.swift", r"model\.useXboxWindow\(\)"),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"public bool XboxReadsWindow =>"),
        ("windows", "windows/src/CouchSubs.App/Views/Steps/XboxLoginStep.xaml.cs", r"Controller\.UseXboxWindow\(\)"),
    ],
    "Gerçek kare ekran yazısı ölçütü (menü, görev listesi)": [
        ("mac", "tools/frame-regression/Sources/frame-regression/ScreenCheck.swift", r"func checkScreen\("),
        ("android", _DROID_TESTS + "ScreenFramesTest.kt", r"ocr/screen/"),
    ],
}


def capabilities(problems):
    for name, places in CAPABILITIES.items():
        for platform, path, pattern in places:
            file = ROOT / path
            if not file.is_file() or not re.search(pattern, file.read_text()):
                problems.append(f"Ortak yetenek '{name}': {platform} tarafında yok ({path}).")
    # Android'in deneme dosyaları çekirdeğinkilerin kopyasıdır; ayrışırsa üç platform aynı vakaları koşmuyor demektir.
    for copy in sorted(ANDROID_FIXTURES.iterdir()):
        original = CORE_FIXTURES / copy.name
        if original.is_file() and original.read_bytes() != copy.read_bytes():
            problems.append(f"Ortak deneme dosyası {copy.name}: Android kopyası çekirdektekinden farklı; yeniden kopyalayın.")


def body(text, start):
    """`start` ile başlayan bildirimin { … } gövdesi."""
    i = text.index(start)
    j = text.index("{", i)
    depth = 0
    for k in range(j, len(text)):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                return text[j + 1:k]
    raise ValueError(start)


def windows_fields():
    record = body(WIN_SETTINGS.read_text(), "public sealed record UserSettings")
    return set(re.findall(r"^\s*public\s+[\w<>\[\]?, .]+?\s+(\w+)\s*\{\s*get;\s*init\b", record, re.M))


def core_fields():
    struct = body(CORE_SETTINGS.read_text(), "public struct UserSettings")
    return set(re.findall(r"^    public var (\w+)", struct, re.M))


def normalized(text):
    """Biçim yer tutucuları platforma göre değişir (%@, %lld, %1$s, %d): hepsi %@ sayılır."""
    return re.sub(r"%(\d+\$)?(@|lld|ld|d|s)", "%@", text)


def ios_texts(catalog):
    found = set()
    for path in IOS_SCREENS:
        for match in re.findall(r'"((?:[^"\\]|\\.)*)"', path.read_text()):
            key = match.replace('\\"', '"')
            if key in catalog:
                found.add(normalized(key))
    return found


def android_texts():
    english = {}
    for node in ET.parse(ANDROID_EN).getroot().iter("string"):
        english[node.get("name")] = "".join(node.itertext()).replace("\\'", "'").replace('\\"', '"')
    used = set()
    for path in ANDROID_SCREENS:
        used |= set(re.findall(r"R\.string\.([a-z0-9_]+)", path.read_text()))
    return {normalized(english[name]): name for name in used if name in english}


def compare(title, left_name, left, right_name, right, rules, problems):
    """`left` ve `right` kümeleri; `rules`: pairs (sol → sağ), <sol>_only ve <sağ>_only (gerekçeli)."""
    pairs = rules.get("pairs", {})
    left_only_allowed = rules.get(f"{left_name}_only", {})
    right_only_allowed = rules.get(f"{right_name}_only", {})
    for key, value in list(left_only_allowed.items()) + list(right_only_allowed.items()):
        if not isinstance(value, str) or not value.strip():
            problems.append(f"{title}: '{key}' için gerekçe yok.")
    matched_right = set()
    for a, b in pairs.items():
        if a not in left or b not in right:
            problems.append(f"{title}: eşleme '{a}' → '{b}' artık geçerli değil (biri yok); listeden çıkarın.")
        matched_right.add(b)
    left_rest = {k for k in left - right if k not in pairs}
    right_rest = {k for k in right - left if k not in matched_right}
    for key in sorted(left_rest - set(left_only_allowed)):
        problems.append(f"{title}: '{key}' yalnız {left_name} tarafında. Öbür platforma ekleyin ya da izin listesine gerekçesiyle yazın.")
    for key in sorted(right_rest - set(right_only_allowed)):
        problems.append(f"{title}: '{key}' yalnız {right_name} tarafında. Öbür platforma ekleyin ya da izin listesine gerekçesiyle yazın.")
    for key in sorted(set(left_only_allowed) - left_rest):
        problems.append(f"{title}: izin listesindeki '{key}' ({left_name}_only) artık fark değil; listeden çıkarın.")
    for key in sorted(set(right_only_allowed) - right_rest):
        problems.append(f"{title}: izin listesindeki '{key}' ({right_name}_only) artık fark değil; listeden çıkarın.")


def main():
    rules = json.loads(ALLOWLIST.read_text())
    problems = []

    win = {name.lower(): name for name in windows_fields()}
    core = {name.lower(): name for name in core_fields()}
    desktop = rules["desktop_settings"]
    desktop_rules = {
        "pairs": {a.lower(): b.lower() for a, b in desktop.get("pairs", {}).items()},
        "windows_only": {k.lower(): v for k, v in desktop.get("windows_only", {}).items()},
        "mac_only": {k.lower(): v for k, v in desktop.get("mac_only", {}).items()},
    }
    compare("Masaüstü ayarları (Windows UserSettings ↔ core UserSettings)", "windows", set(win), "mac", set(core),
            desktop_rules, problems)

    catalog = json.loads(CATALOG.read_text())["strings"]
    ios = ios_texts(catalog)
    android = android_texts()
    mobile = rules["mobile_settings"]
    mobile_rules = {
        "pairs": {normalized(a): normalized(b) for a, b in mobile.get("pairs", {}).items()},
        "iphone_only": {normalized(k): v for k, v in mobile.get("iphone_only", {}).items()},
        "android_only": {normalized(k): v for k, v in mobile.get("android_only", {}).items()},
    }
    compare("Telefon ayar ekranları (iPhone Profile.swift ↔ Android ProfileScreens.kt)", "iphone", ios, "android",
            set(android), mobile_rules, problems)

    capabilities(problems)

    if problems:
        print("Platform eşitliği denetimi başarısız (KALICI KURAL: Windows = Mac, Android = iPhone):")
        print("\n".join("  - " + p for p in problems))
        sys.exit(1)
    print(f"Tamam: {len(win)} Windows / {len(core)} ortak ayar alanı, {len(ios)} iPhone / {len(android)} Android ayar metni eşit; "
          f"{len(CAPABILITIES)} ortak yetenek her platformda.")


main()
