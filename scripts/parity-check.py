#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Platform eşitliği denetimi (KALICI KURAL: Windows = Mac, Android = iPhone). Üç karşılaştırma yapar (üçüncüsü:
# CAPABILITIES, ortak çekirdek yeteneklerinin ve ortak deneme dosyalarının her platformda bulunması):
#  1. Masaüstü ayarları: Windows UserSettings kaydının (windows/src/CouchSubs.Shell/Contracts.cs) alanları ile Mac'in
#     kullandığı ortak UserSettings'in (core/.../AppSettings.swift) alanları. Ad büyük/küçük harf gözetmeden eşlenir.
#  2. Telefon ayar ekranları: iPhone Profil/Ayarlar ekranlarının (couchsubs-ios/CouchSubs/UI/Profile.swift, DubbingTile.swift) kullandığı
#     Localizable.xcstrings anahtarları ile Android Profil/Ayarlar ekranlarının (ui/ProfileScreens.kt, DubbingTile.kt) kullandığı
#     strings.xml metinleri. Eşleme İngilizce metinle yapılır (Android values-en metni = xcstrings anahtarı).
#  4. Altyazı biçimi alanları (TV'ye giden `style`): core SubtitleStyle (Mac, iPhone), Windows SubtitleStyle kaydı ve Android
#     SubtitleStyle veri sınıfı aynı alanları taşımalı.
#  5. Ayar ekranı metinleri Mac ↔ iPhone: Mac yeni arayüzünün Ayarlar sayfasındaki (mac/CouchSubs/UI/Yeni/SettingsPage.swift) her
#     katalog anahtarı iPhone uygulamasında da kullanılmalı (Android = iPhone kuralı 2. karşılaştırmayla Android'e taşır).
#  6. Telefon ayar modeli: Android AppSettings'in kalıcı ayarları ile ortak UserSettings + SubtitleStyle alanları (iPhone).
# Yeni bir ayar tek platformda birleşemez: bu altı karşılaştırmadan biri kırmızı olur.
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
IOS_SCREENS = [ROOT / "couchsubs-ios" / "CouchSubs" / "UI" / name for name in ("Profile.swift", "SettingsPages.swift", "DubbingTile.swift", "LocalAISection.swift")] + [
    ROOT / "mac" / "CouchSubs" / "UI" / name for name in ("DubbingVoiceText.swift", "LocalAIText.swift", "Yeni/SubtitlePalette.swift")]
ANDROID_SCREENS = [ROOT / "couchsubs-android" / "app" / "src" / "main" / "java" / "com" / "couchsubs" / "mobile" / "ui" / name
                   for name in ("ProfileScreens.kt", "SettingsPages.kt", "DubbingTile.kt", "LocalAiSection.kt", "PairedTvCard.kt")]
CORE_STYLE = ROOT / "core" / "Sources" / "CouchSubsCore" / "SubtitleServer.swift"
WIN_STYLE = ROOT / "windows" / "src" / "CouchSubs.Core" / "SubtitleServer.cs"
ANDROID_STYLE = ROOT / "couchsubs-android" / "app" / "src" / "main" / "java" / "com" / "couchsubs" / "mobile" / "core" / "SubtitleServer.kt"
ANDROID_SETTINGS = ROOT / "couchsubs-android" / "app" / "src" / "main" / "java" / "com" / "couchsubs" / "mobile" / "settings" / "AppSettings.kt"
MAC_SETTINGS_PAGE = ROOT / "mac" / "CouchSubs" / "UI" / "Yeni" / "SettingsPage.swift"
IOS_APP = ROOT / "couchsubs-ios" / "CouchSubs"
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
    "GTA 6 telefon paneli saydam altyazı penceresinde kartsız balonlar (stacked)": [
        ("mac", _CORE + "ScreenPhoneCard.swift", r"public static func stacked\("),
        ("mac", "mac/CouchSubs/UI/StreamWindow.swift", r"ScreenPhoneCard\.stacked\("),
        ("windows", _WIN + "ScreenPhoneCard.cs", r"public static ChatPanel Stacked\("),
        ("windows", "windows/src/CouchSubs.App/Views/PhoneBlocksCanvas.cs", r"ScreenPhoneCard\.Stacked\("),
        ("android", _DROID + "ScreenPhoneCard.kt", r"fun stacked\("),
        ("mac", _CORE_TESTS + "ScreenPhoneCardTests.swift", r"func testStackedPanelInTheOverlayWindowKeepsTheAlignedLook"),
        ("windows", _WIN_TESTS + "ScreenPhoneCardTests.cs", r"void StackedPanelInTheOverlayWindowKeepsTheAlignedLook"),
        ("android", _DROID_TESTS + "ScreenPhoneCardTest.kt", r"fun stackedPanelInTheOverlayWindowKeepsTheAlignedLook"),
    ],
    "Menüde seçim/liste kaydında satır farkı, değişmeyen satır kalkmaz (carriedRows, #1359, #1362)": [
        ("mac", _CORE + "RegionWatcher.swift", r"static func carriedRows\("),
        ("windows", _WIN + "RegionWatcher.cs", r"CarriedRows\("),
        ("android", _DROID + "Areas.kt", r"fun carriedRows\("),
        ("mac", _CORE_TESTS + "MenuRowsTests.swift", r"func testSharedCarriedRows"),
        ("windows", _WIN_TESTS + "MenuRowsTests.cs", r"void SharedCarriedRows"),
        ("android", _DROID_TESTS + "MenuRowsTest.kt", r"fun sharedCarriedRows"),
    ],
    "Menü sekme şeridi: uçta simge olsa da sekmelere bölünür, gruplar satır satır soldan sağa dizilir (#1372)": [
        ("mac", _CORE + "ScreenTranslation.swift", r"static func textHeight\("),
        ("windows", _WIN + "ScreenTranslation.cs", r"static double TextHeight\("),
        ("android", _DROID + "ScreenTranslation.kt", r"fun textHeight\("),
        ("mac", _CORE + "RegionWatcher.swift", r"static func readingOrder\("),
        ("windows", _WIN + "RegionWatcher.cs", r"ReadingOrder\("),
        ("android", _DROID + "Areas.kt", r"fun readingOrder\("),
        ("mac", _CORE + "ScreenTranslation.swift", r"static func isNamePair\("),
        ("windows", _WIN + "ScreenTranslation.cs", r"static bool IsNamePair\("),
        ("android", _DROID + "ScreenTranslation.kt", r"fun isNamePair\("),
        ("mac", _CORE_TESTS + "TabStripTests.swift", r"func testTabsKeepTheirOrderEveryFrame"),
        ("windows", _WIN_TESTS + "TabStripTests.cs", r"void TabsKeepTheirOrderEveryFrame"),
        ("android", _DROID_TESTS + "TabStripTest.kt", r"fun tabsKeepTheirOrderEveryFrame"),
    ],
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
    # Sinan Bey beta.100 (3380-3383): menünün geçmiş listesi altyazı sanılmaz, satır parçaları birleşir, kesik satır
    # çevrilmez, liste kayınca eski kutular kalkar; her platformun altyazı hattında ve ekran yazısında olmalı.
    "Menü geçmiş listesi (IsHistoryList, JoinedPieces, CutAtAreaEdge, ListMoved, NoteList)": [
        ("mac", _CORE + "Reading.swift", r"public var isHistoryList"),
        ("mac", _CORE + "RegionWatcher.swift", r"static func listMoved\("),
        ("mac", _CORE + "ScreenTextDetector.swift", r"public func noteList\("),
        ("mac", "mac/CouchSubs/AppModel.swift", r"pipeline\.onList"),
        ("mac", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"pipeline\.onList"),
        ("windows", _WIN + "Reading.cs", r"public bool IsHistoryList"),
        ("windows", _WIN + "RegionWatcher.cs", r"static bool ListMoved\("),
        ("windows", _WIN + "ScreenTextDetector.cs", r"public void NoteList\("),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"ListRead ="),
        ("android", _DROID + "Reading.kt", r"val isHistoryList"),
        ("android", _DROID + "Areas.kt", r"fun listMoved\("),
        ("android", _DROID + "ScreenTextDetector.kt", r"fun noteList\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/service/TranslationService.kt", r"onList ="),
        ("mac", _CORE_TESTS + "MenuListTests.swift", r"menu-list\.json"),
        ("windows", _WIN_TESTS + "MenuListTests.cs", r"menu-list\.json"),
        ("android", _DROID_TESTS + "MenuListTest.kt", r"menu-list\.json"),
    ],
    "Ortak deneme dosyası screen-menu.json": [
        ("mac", _CORE_TESTS + "ScreenMenuBarTests.swift", r"screen-menu\.json"),
        ("windows", _WIN_TESTS + "ScreenMenuBarTests.cs", r"screen-menu\.json"),
        ("android", _DROID_TESTS + "ScreenMenuBarTest.kt", r"screen-menu\.json"),
    ],
    # GitHub #1365: menüde çevirinin biçimi ayardan (üstünü ört / yanına koyu etikete yaz), her okumada yeniden seçilmez.
    "Menüde biçim ayardan: üstünü ört ya da yanına etikete yaz, kart ikizi kişi resmiyle (MenuLayout, menu-layout.json, card-portrait.json)": [
        ("mac", _CORE + "MenuLayout.swift", r"public static func locked\("),
        ("windows", _WIN + "MenuLayout.cs", r"public static List<TextPaint> Locked\("),
        ("android", _DROID + "MenuLayout.kt", r"fun locked\("),
        ("mac", _CORE + "RegionWatcher.swift", r"MenuLayout\.locked\("),
        ("windows", _WIN + "RegionWatcher.cs", r"MenuLayout\.Locked\("),
        ("android", _DROID + "Areas.kt", r"MenuLayout\.locked\("),
        ("mac", _CORE + "SubtitleServer.swift", r'result\["label"\]'),
        ("windows", _WIN + "SubtitleServer.cs", r'json\["label"\]'),
        ("android", _DROID + "SubtitleServer.kt", r'json\["label"\]'),
        ("mac", _CORE_TESTS + "MenuLayoutTests.swift", r"menu-layout\.json"),
        ("windows", _WIN_TESTS + "MenuLayoutTests.cs", r"menu-layout\.json"),
        ("android", _DROID_TESTS + "MenuLayoutTest.kt", r"menu-layout\.json"),
        ("mac", _CORE + "TextPaint.swift", r"static func cardPortrait\("),
        ("windows", _WIN + "TextPaint.cs", r"public static TextBox\? CardPortrait\("),
        ("android", _DROID + "TextPaint.kt", r"fun cardPortrait\("),
        ("mac", _CORE_TESTS + "MenuLayoutTests.swift", r"card-portrait\.json"),
        ("windows", _WIN_TESTS + "MenuLayoutTests.cs", r"card-portrait\.json"),
        ("android", _DROID_TESTS + "MenuLayoutTest.kt", r"card-portrait\.json"),
    ],
    "Ortak deneme dosyası mission-card.json": [
        ("mac", _CORE_TESTS + "MissionCardTests.swift", r"mission-card\.json"),
        ("windows", _WIN_TESTS + "MissionCardTests.cs", r"mission-card\.json"),
        ("android", _DROID_TESTS + "MissionCardTest.kt", r"mission-card\.json"),
    ],
    # GitHub #1124: altyazı alanındaki duvar ilanı (açık zeminde koyu yazı) altyazı sayılıyordu; kural ve oturumda kendini
    # kapatması (koyu altyazılı oyun) her platformun altyazı hattında olmalı.
    "Açık zeminde koyu yazı altyazı değil (InkTone, DarkInkStyle)": [
        ("mac", _CORE + "InkTone.swift", r"static func isDarkOnLight\("),
        ("mac", _CORE + "Pipeline/SubtitlePipeline.swift", r"InkTone\.sampler\("),
        ("windows", _WIN + "InkTone.cs", r"public static bool IsDarkOnLight\("),
        ("windows", _WIN + "SubtitlePipeline.cs", r"InkTone\.Sampler\("),
        ("android", _DROID + "InkTone.kt", r"fun isDarkOnLight\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/service/TranslationService.kt", r"InkTone\.sampler\("),
    ],
    "Ortak deneme dosyası dark-ink.json": [
        ("mac", _CORE_TESTS + "InkToneTests.swift", r"dark-ink\.json"),
        ("windows", _WIN_TESTS + "InkToneTests.cs", r"dark-ink\.json"),
        ("android", _DROID_TESTS + "InkToneTest.kt", r"dark-ink\.json"),
    ],
    # Dublajda adından cinsiyeti anlaşılmayan karakter kadın sesine düşüyordu (GTA 6 Jason): "Tanınmayan karakterlerin
    # sesi" dört platformda aynı seçim, eski kayıt bir kez düzeltilir.
    "Dublajda tanınmayan karakterin sesi (setUnknownGender) ve eski kaydın düzeltilmesi": [
        ("mac", _CORE + "Dubbing/VoiceCast.swift", r"func setUnknownGender\("),
        ("mac", _CORE + "Dubbing/VoiceCast.swift", r"func upgradingRules\("),
        ("mac", "mac/CouchSubs/UI/DubbingCard.swift", r"setUnknownGender\("),
        ("mac", "couchsubs-ios/CouchSubs/UI/DubbingTile.swift", r"setUnknownGender\("),
        ("windows", _WIN + "Dubbing/VoiceCast.cs", r"public void SetUnknownGender\("),
        ("windows", _WIN + "Dubbing/VoiceCast.cs", r"private void UpgradeRules\("),
        ("windows", "windows/src/CouchSubs.App/Views/DubbingCard.xaml.cs", r"SetUnknownGender\("),
        ("android", _DROID + "Dubbing.kt", r"fun setUnknownGender\("),
        ("android", _DROID + "Dubbing.kt", r"fun upgradeRules\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/ui/DubbingTile.kt", r"setUnknownGender\("),
    ],
    "Ortak deneme dosyası voice-cast.json": [
        ("mac", _CORE_TESTS + "DubbingTests.swift", r"voice-cast\.json"),
        ("windows", _WIN_TESTS + "DubbingTests.cs", r"voice-cast\.json"),
        ("android", _DROID_TESTS + "DubbingTest.kt", r"voice-cast\.json"),
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
    # GitHub #854/#882: HUD kırıntısı görev sayılmaz, kırıntı konuşmayı attırmaz, ilk karede bozuk sözcük düzeltilir.
    "Okuma kırıntısı (isCrumb) ve bozuk sözcük düzeltmesi (repairsWords)": [
        ("mac", _CORE + "OcrNoise.swift", r"static func isCrumb\("),
        ("windows", _WIN + "OcrNoise.cs", r"public static bool IsCrumb\("),
        ("android", _DROID + "OcrNoise.kt", r"fun isCrumb\("),
        ("mac", _CORE + "SubtitleStabilizer.swift", r"static func repairsWords\("),
        ("windows", _WIN + "SubtitleStabilizer.cs", r"static bool RepairsWords\("),
        ("android", _DROID + "SubtitleStabilizer.kt", r"fun repairsWords\("),
        ("mac", _CORE + "MissionLine.swift", r"static func isCandidate\("),
        ("windows", _WIN + "MissionLine.cs", r"static bool IsCandidate\("),
        ("android", _DROID + "MissionLine.kt", r"fun isCandidate\("),
    ],
    "Ortak deneme dosyası ocr-crumbs.json": [
        ("mac", _CORE_TESTS + "OcrCrumbsTests.swift", r"ocr-crumbs\.json"),
        ("windows", _WIN_TESTS + "OcrCrumbsTests.cs", r"ocr-crumbs\.json"),
        ("android", _DROID_TESTS + "OcrCrumbsTest.kt", r"ocr-crumbs\.json"),
    ],
    # beta.89 (Mac, PS5 Türkçe ana ekranı): harfleri düz okunan Türkçe menü satırı paketle eşleşip çevriliyor, bozuk
    # parçası ("One [Ikan Ipufl") TV'de altyazı oluyor, döngü değişmeyen ekranda her 2,5 sn'de bir yineleniyordu.
    "Türkçe menü satırı, parçası ve çöp okuma altyazı sayılmaz; karara bağlanan satır ekranda durdukça sessiz (SettledText)": [
        ("mac", _CORE + "Pipeline/SettledText.swift", r"func isTargetFragment\("),
        ("windows", _WIN + "SettledText.cs", r"public bool IsTargetFragment\("),
        ("android", _DROID + "SettledText.kt", r"fun isTargetFragment\("),
        ("mac", _CORE + "TurkishText.swift", r"static func isFolded\("),
        ("windows", _WIN + "TurkishText.cs", r"public static bool IsFolded\("),
        ("android", _DROID + "TurkishText.kt", r"fun isFolded\("),
        ("mac", _CORE + "OcrNoise.swift", r"static func looksBracketGarbled\("),
        ("windows", _WIN + "OcrNoise.cs", r"public static bool LooksBracketGarbled\("),
        ("android", _DROID + "OcrNoise.kt", r"fun looksBracketGarbled\("),
        ("mac", _CORE + "Pipeline/SubtitlePipeline.swift", r"if quietDrop\(source, box: box\) \{ return \}"),
        ("windows", _WIN + "SubtitlePipeline.cs", r"if \(QuietDrop\(source, box\)\) return null;"),
        ("android", _DROID + "SubtitlePipeline.kt", r"if \(quietDrop\(source, box\)\) return null"),
        ("mac", _CORE + "GamePacks.swift", r"if TurkishText\.looksTurkish\(text\) \{ return nil \}"),
        ("windows", "windows/src/CouchSubs.Translation/PackLookup.cs", r"if \(TurkishText\.LooksTurkish\(text\)\) return null;"),
        ("android", _DROID + "SubtitleSegmenter.kt", r"if \(TurkishText\.looksTurkish\(text\)\) return null"),
    ],
    # GitHub #1259: kamerayla kayan plaka/tabela altyazı alanına girse de altyazı sayılmaz; dört platformun hattında da.
    "Kamerayla kayan yazıyı altyazıdan çıkarma (SceneMotion)": [
        ("mac", _CORE + "Pipeline/SubtitlePipeline.swift", r"sceneMotion\.filter\("),
        ("windows", _WIN + "SubtitlePipeline.cs", r"sceneMotion\.Filter\("),
        ("android", _DROID + "SubtitlePipeline.kt", r"sceneMotion\.filter\("),
    ],
    # Sinan Bey beta.101: hareketsiz ürün/ambalaj yazısı (bira kutusu, süt kartonu) altyazı ve ekran yazısı sayılmaz.
    "Ürün/ambalaj yazısını altyazıdan çıkarma (PackageText)": [
        ("mac", _CORE + "Pipeline/SubtitlePipeline.swift", r"PackageText\.filter\("),
        ("windows", _WIN + "SubtitlePipeline.cs", r"PackageText\.Filter\("),
        ("android", _DROID + "SubtitlePipeline.kt", r"PackageText\.filter\("),
    ],
    "Ürün/ambalaj yazısını otomatik ekran yazısından çıkarma (PackageText)": [
        ("mac", _CORE + "RegionWatcher.swift", r"PackageText\.filter\("),
        ("windows", _WIN + "RegionWatcher.cs", r"PackageText\.Filter\("),
        ("android", _DROID + "Areas.kt", r"PackageText\.filter\("),
    ],
    "Ürün/marka adı çevrilmez (isProductName)": [
        ("mac", _CORE + "ScreenTranslation.swift", r"isProductName\(plain\)"),
        ("windows", _WIN + "ScreenTranslation.cs", r"IsProductName\(plain\)"),
        ("android", _DROID + "ScreenTranslation.kt", r"isProductName\(plain\)"),
    ],
    "Ortak deneme dosyası package-text.json": [
        ("mac", _CORE_TESTS + "PackageTextTests.swift", r"package-text\.json"),
        ("windows", _WIN_TESTS + "PackageTextTests.cs", r"package-text\.json"),
        ("android", _DROID_TESTS + "PackageTextTest.kt", r"package-text\.json"),
    ],
    "Ortak deneme dosyası scene-motion.json": [
        ("mac", _CORE_TESTS + "SceneMotionTests.swift", r"scene-motion\.json"),
        ("windows", _WIN_TESTS + "SceneMotionTests.cs", r"scene-motion\.json"),
        ("android", _DROID_TESTS + "SceneMotionTest.kt", r"scene-motion\.json"),
    ],
    "Ortak deneme dosyası settled-text.json": [
        ("mac", _CORE_TESTS + "SettledTextTests.swift", r"settled-text\.json"),
        ("windows", _WIN_TESTS + "SettledTextTests.cs", r"settled-text\.json"),
        ("android", _DROID_TESTS + "SettledTextTest.kt", r"settled-text\.json"),
    ],
    # beta-104 (Mafia: The Old Country): aşama aşama beliren uzun satır tek altyazı (gevşek uzama), yazı tanıma farkıyla
    # okunan uzun satır motora bir kez gider, altyazının gecikme dökümü 30 sn'de bir günlükte.
    "Ortak deneme dosyası growing-lines.json": [
        ("mac", _CORE_TESTS + "GrowingLinesTests.swift", r"growing-lines\.json"),
        ("windows", _WIN_TESTS + "GrowingLinesTests.cs", r"growing-lines\.json"),
        ("android", _DROID_TESTS + "GrowingLinesTest.kt", r"growing-lines\.json"),
    ],
    "Uzun satırda gevşek uzama, yazı tanıma farkı ve altyazı gecikme dökümü": [
        ("mac", _CORE + "TextMatch.swift", r"static func isLooseGrowth\("),
        ("windows", _WIN + "TextMatch.cs", r"public static bool IsLooseGrowth\("),
        ("android", _DROID + "TextMatch.kt", r"fun isLooseGrowth\("),
        ("mac", _CORE + "TextMatch.swift", r"static func isJitter\("),
        ("windows", _WIN + "TextMatch.cs", r"public static bool IsJitterOf\("),
        ("android", _DROID + "TextMatch.kt", r"fun isJitterOf\("),
        ("mac", "mac/CouchSubs/AppModel.swift", r"pipeline\.onTiming = "),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"pipeline\.onTiming = "),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"built\.TimingLog = "),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/service/TranslationService.kt", r"onTiming = \{ Log\.i\(TAG, it\) \}"),
    ],
    # GitHub #884/#891: TV uygulaması sürümünü altyazı akışıyla bildirir (/events?v=); eskiyse dört platformda da ana
    # ekranda "TV uygulamasını güncelle" çıkar (LG geliştirici modu kapalı / anahtar başka cihazdayken de).
    "Eski TV uygulamasını akıştaki sürümden tanıma ve ana ekranda güncelleme önerisi": [
        ("mac", _CORE + "SubtitleServer.swift", r"static func isTVAppOutdated\("),
        ("windows", _WIN + "SubtitleServer.cs", r"public static bool IsTvAppOutdated\("),
        ("android", _DROID + "SubtitleServer.kt", r"fun isTvAppOutdated\("),
        ("mac", "mac/CouchSubs/AppModel.swift", r"func tvAppReported\("),
        ("mac", "mac/CouchSubs/UI/Yeni/HomeStatus.swift", r"model\.updateTVApp\(\)"),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"public void TvAppReported\("),
        ("windows", "windows/src/CouchSubs.App/Views/MainView.xaml.cs", r"controller\.UpdateTvAppAsync\(\)"),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"func tvAppReported\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/TvAppUpdate.kt", r"fun reported\("),
    ],
    # beta.89 (LG): kurulumdan sonra webOS eski süreci tutuyordu (paket 0.9.84, açık uygulama 0.9.81). Dört platform da kurulumdan
    # sonra açık uygulamayı kapatır (closeByAppId), çalışan sürümü denetler, eskiyse bir kez daha kapatıp açar, yine eskiyse
    # "TV'de CouchSubs'ı kapatıp yeniden açın" der. TV sayfası (tv-webos/platform.js) da diskteki sürüm yeniyse yeniden yüklenir.
    "LG kurulumdan sonra açık uygulamayı kapatıp açma ve çalışan sürüm denetimi": [
        ("mac", _CORE + "LGTV/DevModeInstaller.swift", r"public func closeApp\("),
        ("mac", _CORE + "LGTV/TVAppRunningCheck.swift", r"public mutating func report\("),
        ("mac", _CORE + "LGTV/SSAPClient.swift", r"public func reopenApp\("),
        ("mac", "mac/CouchSubs/AppModel.swift", r"private func lgRunningReported\("),
        ("windows", _WIN + "LgTv/DevModeInstaller.cs", r"public async Task<string> CloseAppAsync\("),
        ("windows", _WIN + "LgTv/TvAppRunningCheck.cs", r"public TvAppRunningVerdict Report\("),
        ("windows", _WIN + "LgTv/TvKeeper.cs", r"public void ReopenApp\("),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"private bool LgRunningReported\("),
        ("ios", "couchsubs-ios/CouchSubs/TVInstall/LGPhoneInstall.swift", r"static let closeCommand"),
        ("ios", "couchsubs-ios/CouchSubs/TVInstall/LGPhoneInstall.swift", r"runningVersion: String\? = nil"),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"private func lgRunningReported\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/lg/LgInstaller.kt", r"const val CLOSE_COMMAND"),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/lg/LgInstaller.kt", r"runningVersion: String\? = null"),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/lg/TvAppRunningCheck.kt", r"fun report\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/TvAppUpdate.kt", r"internal fun lgRunningReported\("),
    ],
    # "Ekranı çevir" özgün yazının birebir yerinde ve boyunda: kutunun genişleyebileceği alan simgelere kadar (room), kutu
    # yalnız yazıyı kapsar, sütun/şerit hizası, eş öğeler aynı boyda. TV (tv-webos fitStyled) bu alanlarla çizer.
    "Ekran yazısı yerleşimi (ScreenFit: room, rows, hiza, eş boy)": [
        ("mac", _CORE + "ScreenFit.swift", r"static func fitted\("),
        ("windows", _WIN + "ScreenFit.cs", r"public static IReadOnlyList<ScreenTranslation.Item> Fitted\("),
        ("android", _DROID + "ScreenFit.kt", r"fun fitted\("),
        ("mac", _CORE_TESTS + "ScreenFitTests.swift", r"screen-fit\.json"),
        ("windows", _WIN_TESTS + "ScreenFitTests.cs", r"screen-fit\.json"),
        ("android", _DROID_TESTS + "ScreenFitTest.kt", r"screen-fit\.json"),
    ],
    # Ekran yazısı takibi: özgün yazı kalkınca çevirisi aynı karede kalkar (kutunun gri izinin ilintisi), her uygulama her
    # karede sunucuya verir.
    "Ekran yazısı takibi (ScreenPresence)": [
        ("mac", _CORE + "ScreenPresence.swift", r"mutating func visible\("),
        ("windows", _WIN + "ScreenPresence.cs", r"public IReadOnlyList<bool> Visible\("),
        ("android", _DROID + "ScreenPresence.kt", r"fun visible\("),
        ("mac", "mac/CouchSubs/AppModel.swift", r"server\.observe\(frame\)"),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"server\.observe\(frame\)"),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"server\.Observe\(frame\)"),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/service/TranslationService.kt", r"live\.observe"),
        ("mac", _CORE_TESTS + "ScreenPresenceTests.swift", r"screen-presence\.json"),
        ("windows", _WIN_TESTS + "ScreenPresenceTests.cs", r"screen-presence\.json"),
        ("android", _DROID_TESTS + "ScreenPresenceTest.kt", r"screen-presence\.json"),
    ],
    # Ekran yazısının görünüşü oturum boyunca kilitli: öğe türü başına boy, kalınlık, renk ilk ölçümde; yalnız belirgin
    # (%25+) ve kalıcı (1 sn+) değişimde yenilenir. "Ekranı çevir" ve otomatik ekran yazısı sunucuda aynı kilitten geçer.
    "Ekran yazısı kararlı stil kilidi (ScreenStyleLock)": [
        ("mac", _CORE + "ScreenStyleLock.swift", r"mutating func steady\("),
        ("windows", _WIN + "ScreenStyleLock.cs", r"public IReadOnlyList<ScreenTranslation.Item> Steady\("),
        ("android", _DROID + "ScreenStyleLock.kt", r"fun steady\("),
        ("mac", _CORE + "SubtitleServer.swift", r"steadied\(items"),
        ("windows", _WIN + "SubtitleServer.cs", r"Steadied\(\["),
        ("android", _DROID + "SubtitleServer.kt", r"steadied\(items"),
        ("mac", _CORE_TESTS + "ScreenStyleLockTests.swift", r"screen-style-lock\.json"),
        ("windows", _WIN_TESTS + "ScreenStyleLockTests.cs", r"screen-style-lock\.json"),
        ("android", _DROID_TESTS + "ScreenStyleLockTest.kt", r"screen-style-lock\.json"),
    ],
    # Çapa takibi: telefonun/kartın dörtgeni her karede OCR'sız, alt piksel izlenir (izdüşümsel Lucas-Kanade); çeviri
    # katmanı bu dönüşümle taşınır (docs/ekran-capasi.md).
    "Ekran çapası takibi (ScreenAnchor)": [
        ("mac", _CORE + "ScreenAnchor.swift", r"public func track\("),
        ("windows", _WIN + "ScreenAnchor.cs", r"public Fix\? Track\("),
        ("android", _DROID + "ScreenAnchor.kt", r"fun track\("),
        ("mac", _CORE_TESTS + "ScreenAnchorTests.swift", r"screen-anchor\.json"),
        ("windows", _WIN_TESTS + "ScreenAnchorTests.cs", r"screen-anchor\.json"),
        ("android", _DROID_TESTS + "ScreenAnchorTest.kt", r"screen-anchor\.json"),
    ],
    # Bilgisayar/telefon ekranında özgün stilli ekran yazısı oyun karesindeki kendi yerinde (hizalı liste değil), ortak
    # satır yerleşimiyle.
    "Ekran yazısı masaüstünde/telefonda yerinde çizim": [
        ("mac", "mac/CouchSubs/UI/StreamWindow.swift", r"struct ScreenTextBlocks"),
        ("windows", "windows/src/CouchSubs.App/Views/ScreenTextCanvas.cs", r"ScreenFit\.Layout\("),
        ("windows", "windows/src/CouchSubs.App/Views/StreamWindow.cs", r"screenTextLayer\.Show\("),
        ("ios", "couchsubs-ios/CouchSubs/UI/Home.swift", r"ScreenFit\.lines\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/ui/PhoneSubtitleActivity.kt", r"ScreenFit\.lines\("),
    ],
    # Çizicilerin ortak satır yerleşimi: yazı boyu sabit, önce yatay sıkıştırma, sonra room içinde genişleme (TV fitStyled).
    "Ekran yazısı çizici yerleşimi (ScreenFit.lines)": [
        ("mac", _CORE + "ScreenFit.swift", r"public static func lines\("),
        ("windows", _WIN + "ScreenFit.cs", r"public static Lines Layout\("),
        ("android", _DROID + "ScreenFit.kt", r"fun lines\("),
        ("mac", _CORE_TESTS + "ScreenFitTests.swift", r"func testSharedLineVectors\("),
        ("windows", _WIN_TESTS + "ScreenFitTests.cs", r"public void SharedLineVectors\("),
        ("android", _DROID_TESTS + "ScreenFitTest.kt", r"fun sharedLineVectors\("),
    ],
    # Yerinde birebir çizim: gönderici kareden örtü kutusu, zemin/degrade, satır aralığı, boş alan ve grubu ölçer
    # (TextPainter); çiziciler ortak yerleşimle çizer (ScreenFit.exact; TV placeExact). Ortak vakalar text-paint.json.
    "Ekran yazısı yerinde birebir çizim (TextPainter, ScreenFit.exact)": [
        ("mac", _CORE + "TextPaint.swift", r"public static func paints\("),
        ("windows", _WIN + "TextPaint.cs", r"public static IReadOnlyList<TextPaint> Paints\("),
        ("android", _DROID + "TextPaint.kt", r"fun paints\("),
        ("mac", _CORE + "ScreenFit.swift", r"public static func exact\("),
        ("windows", _WIN + "ScreenFit.cs", r"public static IReadOnlyList<ExactPlacement> Exact\("),
        ("android", _DROID + "ScreenFit.kt", r"fun exact\("),
        ("mac", _CORE_TESTS + "TextPaintTests.swift", r"text-paint\.json"),
        ("windows", _WIN_TESTS + "TextPaintTests.cs", r"text-paint\.json"),
        ("android", _DROID_TESTS + "TextPaintTest.kt", r"text-paint\.json"),
        ("mac", "mac/CouchSubs/UI/StreamWindow.swift", r"ExactScreenText\("),
        ("ios", "couchsubs-ios/CouchSubs/UI/Home.swift", r"ExactScreenText\("),
        ("windows", "windows/src/CouchSubs.App/Views/ScreenTextCanvas.cs", r"ScreenFit\.Exact\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/ui/PhoneSubtitleActivity.kt", r"ScreenFit\.exact\("),
    ],
    "Gerçek kare ekran yazısı ölçütü (menü, görev listesi)": [
        ("mac", "tools/frame-regression/Sources/frame-regression/ScreenCheck.swift", r"func checkScreen\("),
        ("android", _DROID_TESTS + "ScreenFramesTest.kt", r"ocr/screen/"),
    ],
    # Telefonda günlükler (iPhone: remoteplay.log + altyazi.log + tvinstall.log; Android: uygulamanın logcat'i +
    # tvinstall.log) tek dosyada, kişisel veri maskelenmiş paylaşılır (Profil › Hakkında). Masaüstünde (Mac, Windows) aynı
    # iş "Günlük dosyasını göster" düğmesidir (dosya kullanıcının kendi diskinde, Finder/Dosya Gezgini'nde seçili açılır).
    "Günlük paylaşma (telefonda maskelenmiş dosya, masaüstünde \"Günlük dosyasını göster\")": [
        ("mac", "mac/CouchSubs/UI/Onboarding/ConsoleStep.swift", r"private func showLogFile\(\)"),
        ("windows", "windows/src/CouchSubs.App/Views/Steps/LogFile.cs", r"public static void Show\(\)"),
        ("ios", _CORE + "LogShare.swift", r"public static func redact\("),
        ("ios", "couchsubs-ios/CouchSubs/UI/Profile.swift", r"ShareLink\(item: PhoneLogsZip\(\)"),
        ("android", _DROID + "LogShare.kt", r"fun redact\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/ui/ProfileScreens.kt", r"shareLogs\(context\)"),
    ],
    "Ortak deneme dosyası log-redaction.json": [
        ("ios", _CORE_TESTS + "LogShareTests.swift", r"log-redaction\.json"),
        ("android", _DROID_TESTS + "LogShareTest.kt", r"log-redaction\.json"),
    ],
    # Sinan Bey'in iPhone'u (1.0.4) PS5'te 1 dk "Bağlanıyor…"da kaldı, neden görünmüyordu: 30 sn'den sonra durum satırının
    # altında PS5 uyandırılıyor / yanıt vermiyor (aynı ağda mı) / yanıt verdi ama açılmıyor yazar.
    "\"Bağlanıyor…\" 30 sn'yi geçince nedeni (ConnectingHint)": [
        ("mac", _CORE + "ConnectingHint.swift", r"public static func text\(seconds:"),
        ("mac", "mac/CouchSubs/AppModel.swift", r"ConnectingHint\.text\("),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"ConnectingHint\.text\("),
        ("windows", _WIN + "ConnectingHint.cs", r"public static string\? Text\("),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"ConnectingHint\.Text\("),
        ("android", _DROID + "ConnectingHint.kt", r"fun reason\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/service/TranslationService.kt", r"ConnectingHint\.reason\("),
    ],
    # Mac (beta.80, PS5, GTA 6): ekranda diyalog varken altyazı günlüğü dakikalarca boştu; altyazının okunmadığı (menü), boş
    # okunduğu, süzgeçte kaldığı ya da okumanın hata verdiği günlükte görünmüyordu.
    "Altyazı alanında yazı çıkmayınca nedeni günlükte (QuietReads)": [
        ("mac", _CORE + "Pipeline/SubtitlePipeline.swift", r"struct QuietReads"),
        ("mac", "mac/CouchSubs/AppModel.swift", r"pipeline\?\.skipForMenu\(\)"),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"\.skipForMenu\(\)"),
        ("mac", _CORE_TESTS + "QuietReadsTests.swift", r"class QuietReadsTests"),
        ("windows", _WIN + "SubtitlePipeline.cs", r"class QuietReads"),
        ("windows", _WIN_TESTS + "QuietReadsTests.cs", r"class QuietReadsTests"),
        ("android", _DROID + "SubtitlePipeline.kt", r"class QuietReads"),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/service/TranslationService.kt", r"skipForMenu\(\)"),
        ("android", _DROID_TESTS + "QuietReadsTest.kt", r"class QuietReadsTest"),
    ],
    # Xbox çalışan oyunu bildirmez: oyun seçilmezse GTA 6 telefonu hiç açılmıyordu (X'te iki kullanıcı). Xbox için son seçilen
    # oyun kendiliğinden kullanılır, hiç seçim yoksa Oyun karosu vurgulanır ve not görünür; günlükte tek satır.
    "Xbox'ta son seçilen oyun ve oyun bilinmiyorsa Oyun karosu notu (xboxNeedsGame)": [
        ("mac", _CORE + "GameSense.swift", r"public func startXbox\(lastChosen:"),
        ("mac", _CORE + "GameChoice.swift", r"sense\.startXbox\(lastChosen: lastPlayed\)"),
        ("mac", "mac/CouchSubs/AppModel.swift", r"gameChoice\.start\(console: consoleName, xbox: isXbox\)"),
        ("mac", "mac/CouchSubs/UI/Yeni/HomeStatus.swift", r"choice\.xboxNeedsGame"),
        ("mac", _CORE_TESTS + "GameSenseTests.swift", r"func testXboxStartUsesTheLastChosenGameOrLogsThatTheGameIsUnknown\("),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"gameChoice\.start\(console: consoleName, xbox: xbox != nil\)"),
        ("ios", "couchsubs-ios/CouchSubs/UI/GameAsk.swift", r"choice\.xboxNeedsGame"),
        ("windows", _WIN + "GameSense.cs", r"public string StartXbox\("),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"gameSense\.StartXbox\(LastPlayedGame\)"),
        ("windows", "windows/src/CouchSubs.App/Views/MainView.xaml.cs", r"controller\.XboxNeedsGame"),
        ("windows", _WIN_TESTS + "GameSenseTests.cs", r"void XboxStartUsesTheLastChosenGameOrLogsThatTheGameIsUnknown\("),
        ("android", _DROID + "GameSense.kt", r"fun startXbox\(lastChosen:"),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/service/PlayedGame.kt", r"sense\.startXbox\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/ui/GameAskCard.kt", r"status\.xboxNeedsGame"),
        ("android", _DROID_TESTS + "GameSenseTest.kt", r"fun xboxStartUsesTheLastChosenGameOrLogsThatTheGameIsUnknown\("),
    ],
    # beta.89: TV'nin adresi değişince kayıtlı adres sessiz kalıyor, kurulum "Key Server kapalı" diyordu; eşli TV kaldırılamıyordu.
    "Kayıtlı TV adresi sessizse TV'yi ağda yeniden bulma (TVReach; reddedilen bağlantı yanıt sayılır)": [
        ("mac", _CORE + "LGTV/TVReach.swift", r"public static func responds\(host: String, brand: TVBrand"),
        ("mac", _CORE + "LGTV/TVReach.swift", r"public static func locate\("),
        ("mac", _CORE_TESTS + "TVReachTests.swift", r"func testSilentAddressFindsSameTVAtNewAddress\("),
        ("mac", "mac/CouchSubs/AppModel.swift", r"func locateTV\(force: Bool"),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"func relocateForInstall\("),
        ("windows", _WIN + "LgTv/TvReach.cs", r"public static async Task<bool> RespondsAsync\("),
        ("windows", _WIN + "LgTv/TvReach.cs", r"LocateAsync\("),
        ("windows", _WIN_TESTS + "TvReachTests.cs", r"TvReach"),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/TvReach.kt", r"fun responds\(host: String, brand: TvBrand"),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/TvReach.kt", r"fun locate\("),
        ("android", "couchsubs-android/app/src/test/java/com/couchsubs/mobile/tv/TvReachTest.kt", r"TvReach"),
    ],
    "Eşli TV kartı: kendiliğinden yeniden bulma, Yeniden Ara, IP Adresi Gir, Eşleşmeyi Kaldır": [
        ("mac", "mac/CouchSubs/AppModel.swift", r"func checkTVReachable\(\)"),
        ("mac", "mac/CouchSubs/AppModel.swift", r"func searchTVAgain\(\)"),
        ("mac", "mac/CouchSubs/AppModel.swift", r"func useTVAddress\("),
        ("mac", "mac/CouchSubs/AppModel.swift", r"func removeTVPairing\(\)"),
        ("mac", "mac/CouchSubs/UI/Yeni/SettingsPage.swift", r"model\.removeTVPairing\(\)"),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"func checkTVReachable\(\)"),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"func searchTVAgain\(\)"),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"func useTVAddress\("),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"func removeTVPairing\(\)"),
        ("ios", "couchsubs-ios/CouchSubs/UI/SettingsPages.swift", r"model\.removeTVPairing\(\)"),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"public async Task CheckTvReachableAsync\(\)"),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"public async Task<bool> SearchTvAgainAsync\(\)"),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"public async Task<bool> UseTvAddressAsync\("),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"public void RemoveTvPairing\(\)"),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/TvRelocation.kt", r"fun checkTvReachable\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/TvRelocation.kt", r"fun searchTvAgain\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/TvRelocation.kt", r"fun useTvAddress\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/TvRelocation.kt", r"fun removeTvPairing\("),
    ],
    # #1158: Samsung'da TV'den silinen uygulama "kurulu" görünüyordu; liste/vd_applist "yok" deyince kayıt silinir ve
    # kurulum bağlantısı reddedilince metin menüyü, iki ayarı ve bu cihazın adresini söyler.
    "Samsung: TV'den silinen uygulamanın \"kurulu\" kaydı silinir, Host PC IP adımı adresle yazılır": [
        ("mac", _CORE + "LGTV/SamsungTV.swift", r"public func appMissing\(host: String\?\) -> Bool"),
        ("mac", _CORE + "LGTV/SamsungTV.swift", r"SamsungAppKnowledge\.forgetsOnList\(presence\)"),
        ("mac", "mac/CouchSubs/AppModel.swift", r"func samsungAppMissing\(host: String\)"),
        ("mac", "mac/CouchSubs/UI/Onboarding/TVAppCard.swift", r"static func hostPcSteps\("),
        ("ios", "couchsubs-ios/CouchSubs/PhoneModel.swift", r"func samsungAppMissing\(host: String\)"),
        ("ios", "couchsubs-ios/CouchSubs/TVInstall/SamsungInstall.swift", r"func installedPresence\(\)"),
        ("ios", "couchsubs-ios/CouchSubs/UI/TVInstallScreen.swift", r"TVText\.hostPcSteps\("),
        ("windows", _WIN + "LgTv/SamsungTv.cs", r"public static bool AppMissing\(string\? host\)"),
        ("windows", _WIN + "LgTv/SamsungTv.cs", r"SamsungAppKnowledge\.ForgetsOnList\(presence\)"),
        ("windows", "windows/src/CouchSubs.Shell/AppController.cs", r"public void SamsungAppMissing\(string host\)"),
        ("windows", "windows/src/CouchSubs.Shell/TvAppMessages.cs", r"HostPcStepsLine"),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/TvAppUpdate.kt", r"fun samsungAppMissing\("),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/TvSessionLauncher.kt", r"samsungForgetsOnList\(knownStale, presence\)"),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/tv/samsung/SamsungInstaller.kt", r"fun installedPresence\(\)"),
        ("android", "couchsubs-android/app/src/main/java/com/couchsubs/mobile/ui/TvInstallScreen.kt", r"R\.string\.tvinstall_host_pc_steps"),
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


def core_style_fields():
    struct = body(CORE_STYLE.read_text(), "public struct SubtitleStyle")
    return set(re.findall(r"^    public var (\w+)", struct, re.M))


def windows_style_fields():
    text = WIN_STYLE.read_text()
    start = text.index("public sealed record SubtitleStyle(")
    params = text[start:text.index(")\n{", start)]
    return set(re.findall(r"^\s*[\w<>\[\]?, .]+?\s+(\w+)\s*=", params, re.M))


def android_style_fields():
    text = ANDROID_STYLE.read_text()
    start = text.index("data class SubtitleStyle(")
    params = text[start:text.index("\n)", start)]
    return set(re.findall(r"^\s*val (\w+)\s*:", params, re.M))


def android_settings_fields():
    cls = body(ANDROID_SETTINGS.read_text(), "class AppSettings(")
    return set(re.findall(r"^    (?:override )?var (\w+)\s*:", cls, re.M))


def catalog_keys(paths, catalog):
    found = set()
    for path in paths:
        for match in re.findall(r'"((?:[^"\\]|\\.)*)"', path.read_text()):
            key = match.replace('\\"', '"')
            if key in catalog:
                found.add(key)
    return found


def lowered(rules, left, right):
    return {"pairs": {a.lower(): b.lower() for a, b in rules.get("pairs", {}).items()},
            f"{left}_only": {k.lower(): v for k, v in rules.get(f"{left}_only", {}).items()},
            f"{right}_only": {k.lower(): v for k, v in rules.get(f"{right}_only", {}).items()}}


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

    core_style = {name.lower() for name in core_style_fields()}
    win_style = {name.lower() for name in windows_style_fields()}
    android_style = {name.lower() for name in android_style_fields()}
    style = rules["style_fields"]
    compare("Altyazı biçimi (Windows SubtitleStyle ↔ core SubtitleStyle)", "windows", win_style, "mac", core_style,
            lowered(style.get("windows_mac", {}), "windows", "mac"), problems)
    compare("Altyazı biçimi (Android SubtitleStyle ↔ core SubtitleStyle)", "android", android_style, "iphone", core_style,
            lowered(style.get("android_iphone", {}), "android", "iphone"), problems)

    mac_page = catalog_keys([MAC_SETTINGS_PAGE], catalog)
    iphone_all = catalog_keys(sorted(IOS_APP.rglob("*.swift")), catalog)
    allowed = rules["mac_settings_on_iphone"]
    for key in sorted(mac_page - iphone_all - set(allowed)):
        problems.append(f"Mac Ayarlar ↔ iPhone: '{key}' Mac'in Ayarlar sayfasında var, iPhone'da yok. iPhone'a (ve Android'e) ekleyin "
                        "ya da scripts/parity-allowlist.json › mac_settings_on_iphone'a gerekçesiyle yazın.")
    for key, reason in allowed.items():
        if not isinstance(reason, str) or not reason.strip():
            problems.append(f"Mac Ayarlar ↔ iPhone: '{key}' için gerekçe yok.")
        elif key not in mac_page or key in iphone_all:
            problems.append(f"Mac Ayarlar ↔ iPhone: izin listesindeki '{key}' artık fark değil; listeden çıkarın.")

    phone_core = {name.lower() for name in core_fields() | core_style_fields()}
    android_settings = {name.lower() for name in android_settings_fields()}
    compare("Telefon ayar modeli (Android AppSettings ↔ core UserSettings + SubtitleStyle)", "android", android_settings,
            "iphone", phone_core, lowered(rules["phone_settings"], "android", "iphone"), problems)

    capabilities(problems)

    if problems:
        print("Platform eşitliği denetimi başarısız (KALICI KURAL: Windows = Mac, Android = iPhone):")
        print("\n".join("  - " + p for p in problems))
        sys.exit(1)
    print(f"Tamam: {len(win)} Windows / {len(core)} ortak ayar alanı, {len(ios)} iPhone / {len(android)} Android ayar metni eşit; "
          f"{len(core_style)} altyazı biçimi alanı dört platformda, Mac Ayarlar'ın {len(mac_page)} metni iPhone'da, "
          f"{len(android_settings)} Android ayarı eşli; {len(CAPABILITIES)} ortak yetenek her platformda.")


main()
