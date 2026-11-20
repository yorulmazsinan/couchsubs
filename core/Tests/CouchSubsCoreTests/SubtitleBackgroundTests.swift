// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import XCTest
@testable import CouchSubsCore

final class SubtitleBackgroundTests: XCTestCase {
    private let width = 128
    private let height = 48

    func testKeepsSubtitleOnBluePanelInDarkSceneAndDropsOtherText() {
        var pixels = solid(20, 20, 20)
        fill(&pixels, left: 24, top: 16, right: 104, bottom: 32, red: 33, green: 33, blue: 46)
        fill(&pixels, left: 40, top: 21, right: 88, bottom: 27, red: 230, green: 230, blue: 230)
        let reading = Reading(lines: [
            TextLine("Hey, you've reached Brian Heder.", box: TextBox(left: 0.32, top: 20.0 / 48, right: 0.68, bottom: 27.0 / 48)),
            TextLine("PHOTO MODE", box: TextBox(left: 0.80, top: 0.30, right: 0.95, bottom: 0.36)),
        ])

        XCTAssertEqual(SubtitleBackground.filter(reading, pixels: pixels, width: width, height: height).text,
                       "Hey, you've reached Brian Heder.")
    }

    func testRejectsNeutralDarkPanel() {
        var pixels = solid(20, 20, 20)
        fill(&pixels, left: 24, top: 16, right: 104, bottom: 32, red: 33, green: 33, blue: 33)
        let reading = Reading(lines: [TextLine("Brian", box: TextBox(left: 0.32, top: 20.0 / 48,
                                                                     right: 0.68, bottom: 27.0 / 48))])
        XCTAssertTrue(SubtitleBackground.filter(reading, pixels: pixels, width: width, height: height).lines.isEmpty)
    }

    func testImageCoordinatesMatchTopDownBoxes() {
        var pixels = solid(20, 20, 20)
        // Panel altta olmalı: ortadaki panel, görüntü ters çevrilse de aynı yerde kalır.
        fill(&pixels, left: 24, top: 31, right: 104, bottom: 46, red: 33, green: 33, blue: 46)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let reading = Reading(lines: [
            TextLine("Menu text", box: TextBox(left: 0.4, top: 5.0 / 48, right: 0.6, bottom: 12.0 / 48)),
            TextLine("Yes.", box: TextBox(left: 0.4, top: 35.0 / 48, right: 0.6, bottom: 42.0 / 48)),
        ])
        XCTAssertEqual(SubtitleBackground.filter(reading, in: image).text, "Yes.")
    }

    /// #534: Mac'te zemin #3D3D51'e kadar açık geliyor; Windows'taki #21212E ile ikisi de panel. Yazı ve sahne değil.
    func testPanelColorFollowsChannelRelationNotFixedValue() {
        for (red, green, blue) in [(33, 33, 46), (61, 61, 81), (22, 22, 34), (36, 36, 52), (48, 50, 66), (80, 80, 100)] {
            XCTAssertTrue(SubtitleBackground.isPanelColor(red, green, blue), "\(red),\(green),\(blue)")
        }
        let notPanel = [(33, 33, 33), (61, 61, 61), (230, 230, 230), (255, 255, 255), (235, 200, 40), (250, 220, 90),
                        (20, 30, 70), (40, 60, 140), (70, 55, 40), (40, 60, 35), (90, 140, 200), (120, 120, 130),
                        (5, 5, 12)]
        for (red, green, blue) in notPanel {
            XCTAssertFalse(SubtitleBackground.isPanelColor(red, green, blue), "\(red),\(green),\(blue)")
        }
    }

    /// #534: PS5 karesi BT.709 etiketli gelir; başka uzaya çevrilmeden ham değerler sınanır, açık zemin de tutulur.
    func testReadsTaggedFrameInItsOwnColorSpace() {
        var pixels = solid(20, 20, 20)
        fill(&pixels, left: 24, top: 31, right: 104, bottom: 46, red: 61, green: 61, blue: 81)
        let space = CGColorSpace(name: CGColorSpace.itur_709)!
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let reading = Reading(lines: [
            TextLine("Menu text", box: TextBox(left: 0.4, top: 5.0 / 48, right: 0.6, bottom: 12.0 / 48)),
            TextLine("You know, I don't know.", box: TextBox(left: 0.3, top: 35.0 / 48, right: 0.7, bottom: 42.0 / 48)),
        ])
        XCTAssertEqual(SubtitleBackground.filter(reading, in: image).text, "You know, I don't know.")
    }

    func testKeepsSubtitleOnLighterMacPanel() {
        var pixels = solid(20, 20, 20)
        fill(&pixels, left: 24, top: 16, right: 104, bottom: 32, red: 61, green: 61, blue: 81)
        fill(&pixels, left: 40, top: 21, right: 88, bottom: 27, red: 230, green: 230, blue: 230)
        let reading = Reading(lines: [TextLine("Donnie dude.", box: TextBox(left: 0.32, top: 20.0 / 48,
                                                                            right: 0.68, bottom: 27.0 / 48))])
        XCTAssertEqual(SubtitleBackground.filter(reading, pixels: pixels, width: width, height: height).text, "Donnie dude.")
    }

    func testSettingDefaultsToOffAndSurvivesSave() throws {
        XCTAssertFalse(try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8)).watchSubtitleBackground)
        var settings = UserSettings()
        settings.watchSubtitleBackground = true
        XCTAssertTrue(try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(settings)).watchSubtitleBackground)
    }

    private func solid(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        fill(&pixels, left: 0, top: 0, right: width, bottom: height, red: red, green: green, blue: blue)
        return pixels
    }

    private func fill(_ pixels: inout [UInt8], left: Int, top: Int, right: Int, bottom: Int,
                      red: UInt8, green: UInt8, blue: UInt8) {
        for y in top..<bottom {
            for x in left..<right {
                let i = (y * width + x) * 4
                pixels[i] = red
                pixels[i + 1] = green
                pixels[i + 2] = blue
                pixels[i + 3] = 255
            }
        }
    }
}
