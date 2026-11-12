// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class AreaPresetTests: XCTestCase {
    func testBottomIsTheDefaultRegion() {
        XCTAssertEqual(AreaPreset.bottom.region, CropRegion())
        XCTAssertEqual(UserSettings().areaPreset, .bottom)
        XCTAssertNil(AreaPreset.custom.region)
    }

    func testMatchingFindsPresetOrCustom() {
        XCTAssertEqual(AreaPreset.matching(CropRegion()), .bottom)
        XCTAssertEqual(AreaPreset.matching(CropRegion(top: 0, bottom: 1, left: 0, right: 1)), .full)
        XCTAssertEqual(AreaPreset.matching(CropRegion(top: 0.03, bottom: 0.38, left: 0.14, right: 0.86)), .top)
        XCTAssertEqual(AreaPreset.matching(CropRegion(top: 0.5, bottom: 0.9)), .custom)
    }

    func testOldSettingsWithoutPresetInferItFromTheRegion() throws {
        let old = #"{"region":{"top":0,"bottom":1,"left":0,"right":1},"sourceLanguage":"en"}"#
        XCTAssertEqual(try JSONDecoder().decode(UserSettings.self, from: Data(old.utf8)).areaPreset, .full)
        let custom = #"{"region":{"top":0.5,"bottom":0.9,"left":0.1,"right":0.9}}"#
        let settings = try JSONDecoder().decode(UserSettings.self, from: Data(custom.utf8))
        XCTAssertEqual(settings.areaPreset, .custom)
        XCTAssertEqual(settings.region, CropRegion(top: 0.5, bottom: 0.9, left: 0.1, right: 0.9))
    }

    func testPresetRoundTrips() throws {
        var settings = UserSettings()
        settings.selectAreaPreset(.top)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.areaPreset, .top)
        XCTAssertEqual(decoded.region, AreaPreset.top.region)
    }

    func testCustomKeepsTheRegionAndManualEditsBecomeCustom() {
        var settings = UserSettings()
        settings.selectAreaPreset(.full)
        settings.selectAreaPreset(.custom)
        XCTAssertEqual(settings.region, AreaPreset.full.region)
        settings.selectAreaPreset(.bottom)
        settings.setCustomRegion(settings.region.withVertical(position: 40, height: 20))
        XCTAssertEqual(settings.areaPreset, .custom)
    }

    func testVerticalSlidersClampInsideTheFrame() {
        let region = CropRegion()
        let moved = region.withVertical(position: 40, height: 20)
        XCTAssertEqual(moved.top, 0.4, accuracy: 1e-9)
        XCTAssertEqual(moved.bottom, 0.6, accuracy: 1e-9)
        XCTAssertEqual(moved.left, region.left)
        XCTAssertEqual(moved.right, region.right)
        // Alta taşan bölge yukarı kayar; yükseklik en az %5.
        let low = region.withVertical(position: 95, height: 30)
        XCTAssertEqual(low.top, 0.7, accuracy: 1e-9)
        XCTAssertEqual(low.bottom, 1, accuracy: 1e-9)
        let thin = region.withVertical(position: 10, height: 1)
        XCTAssertEqual(thin.bottom - thin.top, CropRegion.minimumSize, accuracy: 1e-9)
        let percent = moved.verticalPercent
        XCTAssertEqual(percent.position, 40, accuracy: 1e-9)
        XCTAssertEqual(percent.height, 20, accuracy: 1e-9)
    }

    func testDragMovesAndResizesWithinTheFrame() {
        let region = CropRegion(top: 0.6, bottom: 0.9, left: 0.2, right: 0.8)
        let moved = region.moved(dx: 0.5, dy: 0.5)
        XCTAssertEqual(moved.right, 1, accuracy: 1e-9)
        XCTAssertEqual(moved.bottom, 1, accuracy: 1e-9)
        XCTAssertEqual(moved.right - moved.left, 0.6, accuracy: 1e-9)
        let resized = region.resized(right: 0.1, bottom: 2)
        XCTAssertEqual(resized.right, region.left + CropRegion.minimumSize, accuracy: 1e-9)
        XCTAssertEqual(resized.bottom, 1, accuracy: 1e-9)
    }
}
