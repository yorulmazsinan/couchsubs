// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import RemotePlay
import VideoToolbox

final class H264FrameDecoderTests: XCTestCase {
    /// Fixture'ı (ffmpeg testsrc2, 6 kare, Annex-B) PS5'in gönderdiği gibi kare kare böler.
    private func accessUnits() throws -> [Data] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample-1080p", withExtension: "h264", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let nals = AnnexB.nalUnits(in: data)
        var units: [Data] = []
        var current = Data()
        var hasSlice = false
        for nal in nals {
            let type = nal.first.map { $0 & 0x1F } ?? 0
            let isSlice = type == 1 || type == 5
            if (type == 7 || type == 9 || isSlice) && hasSlice {
                units.append(current)
                current = Data()
                hasSlice = false
            }
            current.append(contentsOf: [0, 0, 0, 1])
            current.append(nal)
            hasSlice = hasSlice || isSlice
        }
        if !current.isEmpty { units.append(current) }
        return units
    }

    func testFirstKeyframeDecodesTo1080p() throws {
        let decoder = H264FrameDecoder()
        let image = try XCTUnwrap(decoder.decode(annexB: try accessUnits()[0]))
        XCTAssertEqual(image.width, 1920)
        XCTAssertEqual(image.height, 1080)
    }

    func testFollowingFramesDecode() throws {
        let decoder = H264FrameDecoder()
        let units = try accessUnits()
        XCTAssertEqual(units.count, 6)
        for unit in units { XCTAssertNotNil(decoder.decode(annexB: unit)) }
    }

    /// Uykudan sonra VideoToolbox oturumu geçersizleşebilir; çözücü kendini yeniden kurmalı.
    func testRecoversFromInvalidatedSession() throws {
        let decoder = H264FrameDecoder()
        let keyframe = try accessUnits()[0]
        XCTAssertNotNil(decoder.decode(annexB: keyframe))
        decoder.invalidateSessionForTesting()
        XCTAssertNotNil(decoder.decode(annexB: keyframe))
    }

    /// Çözücü servisi koptuğunda (arıza, şimdilik yok) oturum da yeniden kurulur; bozuk veri gibi kare hataları kurmaz (#1390).
    func testServiceFailuresRebuildSession() {
        XCTAssertTrue(H264FrameDecoder.rebuildsSession(after: kVTInvalidSessionErr))
        XCTAssertTrue(H264FrameDecoder.rebuildsSession(after: kVTVideoDecoderMalfunctionErr))
        XCTAssertTrue(H264FrameDecoder.rebuildsSession(after: kVTVideoDecoderNotAvailableNowErr))
        XCTAssertFalse(H264FrameDecoder.rebuildsSession(after: kVTVideoDecoderBadDataErr))
        XCTAssertFalse(H264FrameDecoder.rebuildsSession(after: noErr))
    }

    func testGarbageDoesNotCrash() {
        let decoder = H264FrameDecoder()
        XCTAssertNil(decoder.decode(annexB: Data([0, 0, 0, 1, 0x65, 0xFF, 0x00, 0x12])))
        XCTAssertNil(decoder.decode(annexB: Data()))
    }
}
