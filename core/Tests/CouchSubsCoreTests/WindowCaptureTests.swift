// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

/// Seçilen pencereden okuma: ayarın saklanması, pencere listesinin süzülmesi ve kayıtlı seçimin eşlenmesi.
final class WindowCaptureTests: XCTestCase {
    private let obs = WindowCaptureTarget(processName: "obs64", title: "Fullscreen Projector (Scene)")

    private func window(_ id: UInt32, _ process: String, _ title: String, width: Double = 1280, height: Double = 720,
                        layer: Int = 0, onScreen: Bool = true, own: Bool = false) -> CaptureWindowInfo {
        CaptureWindowInfo(id: id, processName: process, title: title, width: width, height: height, layer: layer,
                          isOnScreen: onScreen, isOwn: own)
    }

    // MARK: - Ayar

    func testNewAndExistingSettingsHaveNoCaptureWindow() throws {
        XCTAssertNil(UserSettings().captureWindow)
        let old = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"frameSource":"remotePlayWindow","gamePacks":false}"#.utf8))
        XCTAssertNil(old.captureWindow)
        XCTAssertEqual(old.frameSource, .remotePlayWindow)
        XCTAssertFalse(old.gamePacks)
    }

    func testCaptureWindowRoundTrips() throws {
        var settings = UserSettings()
        settings.frameSource = .captureWindow
        settings.captureWindow = obs
        let saved = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.frameSource, .captureWindow)
        XCTAssertEqual(saved.captureWindow, obs)
    }

    func testBrokenCaptureWindowOpensEmptyAndKeepsOtherSettings() throws {
        let saved = try JSONDecoder().decode(UserSettings.self,
                                             from: Data(#"{"frameSource":"captureWindow","captureWindow":"obs","targetLanguage":"de"}"#.utf8))
        XCTAssertEqual(saved.frameSource, .captureWindow)
        XCTAssertNil(saved.captureWindow)
        XCTAssertEqual(saved.targetLanguage, "de")
    }

    /// Seçilen pencere de Remote Play penceresi gibi pencere alanlarını kullanır (Windows'taki `AreaSource`).
    func testCaptureWindowUsesWindowAreas() {
        var settings = UserSettings()
        settings.frameSource = .captureWindow
        XCTAssertEqual(settings.areaSource, .window)
    }

    func testOnlyACompleteTargetCanBeRead() {
        XCTAssertTrue(obs.isComplete)
        XCTAssertFalse(WindowCaptureTarget(processName: "", title: "Gameplay").isComplete)
        XCTAssertFalse(WindowCaptureTarget(processName: "game", title: "  ").isComplete)
    }

    // MARK: - Liste

    /// Windows'taki `ListCaptureWindows` kuralları: kendi pencerelerimiz, başlıksızlar, küçükler ve sıradan pencere
    /// olmayanlar (menü çubuğu, Dock, yüzen paneller) seçilemez.
    func testListLeavesOutOwnUntitledSmallAndNonNormalWindows() {
        let windows = [
            window(1, "OBS", "Fullscreen Projector (Scene)"),
            window(2, "CouchSubs", "CouchSubs", own: true),
            window(3, "Game", ""),
            window(4, "Game", "   "),
            window(5, "Game", "Launcher", width: 399, height: 720),
            window(6, "Game", "Toolbar", width: 1280, height: 249),
            window(7, "Dock", "Dock", layer: 20),
            window(8, "", "Orphan"),
        ]
        XCTAssertEqual(CaptureWindows.selectable(windows), [WindowCaptureTarget(processName: "OBS", title: "Fullscreen Projector (Scene)")])
    }

    func testListIsDistinctTrimmedAndSortedByAppThenTitle() {
        let windows = [
            window(1, "obs", "Projector B"),
            window(2, "Game", " Gameplay "),
            window(3, "obs", "Projector A"),
            window(4, "obs", "Projector A"),
            window(5, "Game", "Exactly minimum", width: 400, height: 250),
        ]
        XCTAssertEqual(CaptureWindows.selectable(windows), [
            WindowCaptureTarget(processName: "Game", title: "Exactly minimum"),
            WindowCaptureTarget(processName: "Game", title: "Gameplay"),
            WindowCaptureTarget(processName: "obs", title: "Projector A"),
            WindowCaptureTarget(processName: "obs", title: "Projector B"),
        ])
    }

    // MARK: - Eşleme

    func testMatchNeedsBothAppAndTitle() {
        let windows = [
            window(1, "obs64", "Preview"),
            window(2, "game", "Fullscreen Projector (Scene)"),
            window(3, "OBS64", "Fullscreen Projector (Scene)"),
        ]
        // Uygulama adı büyük/küçük harfe bakmaz (Windows'taki süreç adı gibi); başlık birebir eşleşir.
        XCTAssertEqual(CaptureWindows.match(obs, in: windows)?.id, 3)
        XCTAssertNil(CaptureWindows.match(WindowCaptureTarget(processName: "obs64", title: "fullscreen projector (scene)"), in: windows))
    }

    /// Pencere kapandıysa başka pencereye (ya da bütün masaüstüne) geçilmez.
    func testClosedWindowMatchesNothing() {
        XCTAssertNil(CaptureWindows.match(obs, in: [window(1, "obs64", "Preview"), window(2, "game", "Gameplay")]))
        XCTAssertNil(CaptureWindows.match(obs, in: []))
        XCTAssertNil(CaptureWindows.match(WindowCaptureTarget(processName: "", title: ""), in: [window(1, "", "")]))
    }

    func testMatchNeverPicksOurOwnOrATinyWindow() {
        let windows = [
            window(1, "obs64", "Fullscreen Projector (Scene)", own: true),
            window(2, "obs64", "Fullscreen Projector (Scene)", width: 200, height: 100),
        ]
        XCTAssertNil(CaptureWindows.match(obs, in: windows))
    }

    func testMatchPrefersOnScreenThenLargest() {
        let windows = [
            window(1, "obs64", "Fullscreen Projector (Scene)", width: 3840, height: 2160, onScreen: false),
            window(2, "obs64", "Fullscreen Projector (Scene)", width: 800, height: 600),
            window(3, "obs64", "Fullscreen Projector (Scene)", width: 1920, height: 1080),
        ]
        XCTAssertEqual(CaptureWindows.match(obs, in: windows)?.id, 3)
        XCTAssertEqual(CaptureWindows.match(obs, in: [windows[0]])?.id, 1)
    }

    // MARK: - Seçim listesi

    func testSavedWindowThatIsNotOpenStaysFirstInTheList() {
        let game = WindowCaptureTarget(processName: "game", title: "Gameplay")
        let options = CaptureWindows.options(saved: obs, open: [game])
        XCTAssertEqual(options, [.init(target: obs, isOpen: false), .init(target: game, isOpen: true)])
        XCTAssertEqual(CaptureWindows.label(options[0], notOpen: "Not currently open"),
                       "Fullscreen Projector (Scene) (obs64) — Not currently open")
        XCTAssertEqual(CaptureWindows.label(options[1], notOpen: "Not currently open"), "Gameplay (game)")
    }

    func testOpenSavedWindowIsNotRepeated() {
        XCTAssertEqual(CaptureWindows.options(saved: obs, open: [obs]), [.init(target: obs, isOpen: true)])
        XCTAssertEqual(CaptureWindows.options(saved: nil, open: []), [])
    }

    // MARK: - Siyah kare

    func testBlackFramesWarnOnceAndClearOnTheFirstPicture() {
        var watch = BlackFrameWatch(limit: 3)
        XCTAssertNil(watch.note(black: true))
        XCTAssertNil(watch.note(black: true))
        XCTAssertEqual(watch.note(black: true), .warn)
        XCTAssertNil(watch.note(black: true))
        XCTAssertEqual(watch.note(black: false), .clear)
        XCTAssertNil(watch.note(black: false))
    }

    func testAPictureBetweenBlackFramesRestartsTheCount() {
        var watch = BlackFrameWatch(limit: 3)
        XCTAssertNil(watch.note(black: true))
        XCTAssertNil(watch.note(black: true))
        XCTAssertNil(watch.note(black: false))
        XCTAssertNil(watch.note(black: true))
        XCTAssertNil(watch.note(black: true))
        XCTAssertEqual(watch.note(black: true), .warn)
    }

    func testBlackSampleLooksAtColourNotAlpha() {
        var black = [UInt8](repeating: 0, count: 4 * 2000)
        for index in stride(from: 3, to: black.count, by: 4) { black[index] = 255 }
        XCTAssertTrue(black.withUnsafeBytes(BlackFrameWatch.isBlack(bgra:)))
        // Örneklenen pikseller: 0. ve 997.
        black[4 * 997 + 1] = 40
        XCTAssertFalse(black.withUnsafeBytes(BlackFrameWatch.isBlack(bgra:)))
    }

    /// OBS'in Program/Önizleme projektörü (ve ana penceresi) CouchSubs'ın OBS katmanını da içerir: Kaynak projektörü
    /// önerilir. Kaynak projektörü ve OBS olmayan pencere için ipucu yok (Windows: ObsProjectorTests).
    func testSourceProjectorHintForObsProgramProjector() {
        func hint(_ process: String, _ title: String) -> Bool {
            CaptureWindows.needsSourceProjectorHint(WindowCaptureTarget(processName: process, title: title))
        }
        XCTAssertTrue(hint("OBS", "Projector - Program"))
        XCTAssertTrue(hint("obs64", "Windowed Projector (Preview)"))
        XCTAssertTrue(hint("OBS Studio", "OBS 31.1.2 - Profil: Yayın - Sahneler: GTA"))
        XCTAssertFalse(hint("OBS", "Projector - Source: Capture Card"))
        XCTAssertFalse(hint("obs64", "Projektör - Kaynak: Yakalama kartı"))
        XCTAssertFalse(hint("obs64", "Windowed Projector (Source) - Elgato"))
        XCTAssertFalse(hint("RemotePlay", "PS Remote Play"))
        XCTAssertFalse(hint("Jobs Viewer", "Program"))
        XCTAssertFalse(CaptureWindows.needsSourceProjectorHint(nil))
    }
}

/// Seçilen pencereden kare gelmiyorsa nedeni altyazi.log'a yazılır (#566). Windows'taki `WindowCaptureWatchTests` ile
/// aynı vektörler.
final class WindowCaptureWatchTests: XCTestCase {
    func testNothingIsReportedBeforeFiveSeconds() {
        XCTAssertNil(WindowCaptureWatch().tick(sinceStart: 4.9))
    }

    func testNoFramesFromTheSystemIsReportedThenRepeatedEveryThirtySeconds() {
        let watch = WindowCaptureWatch()
        let first = watch.tick(sinceStart: 5)
        XCTAssertNotNil(first)
        XCTAssertTrue(first?.contains("macOS hiç kare vermedi") == true)
        XCTAssertNil(watch.tick(sinceStart: 6))
        XCTAssertNil(watch.tick(sinceStart: 34))
        XCTAssertNotNil(watch.tick(sinceStart: 35))
    }

    func testCopyFailureIsReportedWithTheError() {
        let watch = WindowCaptureWatch()
        watch.arrived()
        XCTAssertTrue(watch.failed("COMException: The parameter is incorrect."))
        watch.arrived()
        XCTAssertFalse(watch.failed("COMException: The parameter is incorrect."))
        let note = watch.tick(sinceStart: 5)
        XCTAssertTrue(note?.contains("2 kare kopyalanamadı") == true)
        XCTAssertTrue(note?.contains("The parameter is incorrect.") == true)
    }

    func testStuckCopyIsReported() {
        let watch = WindowCaptureWatch()
        watch.arrived()
        watch.copyStarted(at: 1)
        XCTAssertTrue(watch.tick(sinceStart: 5)?.contains("kopyalama 4000 ms'dir bitmedi") == true)
    }

    func testFirstDeliveredFrameSilencesTheWatch() {
        let watch = WindowCaptureWatch()
        watch.arrived()
        XCTAssertTrue(watch.frameDelivered())
        XCTAssertFalse(watch.frameDelivered())
        XCTAssertTrue(watch.delivered)
        XCTAssertNil(watch.tick(sinceStart: 60))
    }

    func testFallsBackWhenNoFrameReachesReadingWithinFiveSeconds() {
        let watch = WindowCaptureWatch()
        XCTAssertFalse(watch.shouldFallBack(sinceStart: 4.9))
        XCTAssertTrue(watch.shouldFallBack(sinceStart: 5))
    }

    func testFallsBackWhenFramesArriveButNoneCanBeCopied() {
        let watch = WindowCaptureWatch()
        watch.arrived()
        watch.copyStarted(at: 0.5)
        XCTAssertTrue(watch.shouldFallBack(sinceStart: 6))
    }

    func testWorkingCaptureNeverFallsBack() {
        let watch = WindowCaptureWatch()
        watch.arrived()
        XCTAssertTrue(watch.frameDelivered())
        XCTAssertFalse(watch.shouldFallBack(sinceStart: 60))
    }

    func testClockJumpWritesOneReport() {
        let watch = WindowCaptureWatch()
        XCTAssertNotNil(watch.tick(sinceStart: 200))
        XCTAssertNil(watch.tick(sinceStart: 201))
    }
}

/// Dakikalık kare sayımı: günlük satırı ve sıfırlama (GitHub #822).
final class WindowFrameCountsTests: XCTestCase {
    func testMinuteLineCountsAndResets() {
        let counts = WindowFrameCounts()
        for _ in 0..<3 { counts.delivered() }
        counts.idle()
        counts.fallback()
        counts.fallback()
        XCTAssertEqual(counts.minuteLine(), "pencere kareleri: 3/dk, boş: 1, yedek: 2")
        XCTAssertEqual(counts.minuteLine(), "pencere kareleri: 0/dk, boş: 0, yedek: 0")
    }
}
