// SPDX-License-Identifier: AGPL-3.0-only
// Xbox yayınının canlı tutulması, durunca gösterilen metnin türü, günlük özeti, anahtar kare isteği ve tanı satırı.
// Windows'taki XboxSessionHealthTests.cs ve XboxFirstFrameWatchTests.cs ile aynı durumlar.

import XCTest
@testable import CouchSubsCore

final class XboxSessionHealthTests: XCTestCase {
    func testSingleKeepaliveFailureDoesNotEndTheStream() {
        var keepalive = XboxKeepalive()
        XCTAssertFalse(keepalive.failed())
        XCTAssertFalse(keepalive.failed())
        keepalive.succeeded()
        XCTAssertEqual(keepalive.failures, 0)
        XCTAssertFalse(keepalive.failed())
    }

    func testThreeConsecutiveKeepaliveFailuresEndTheStream() {
        var keepalive = XboxKeepalive()
        XCTAssertFalse(keepalive.failed())
        XCTAssertFalse(keepalive.failed())
        XCTAssertTrue(keepalive.failed())
        XCTAssertEqual(keepalive.failures, XboxKeepalive.maxFailures)
    }

    func testStopIsClassifiedFromTheReason() {
        XCTAssertEqual(XboxStop.classify("{\"code\":\"ServerInUse\"}"), .busy)
        XCTAssertEqual(XboxStop.classify("AlreadyStreaming"), .busy)
        XCTAssertEqual(XboxStop.classify("{\"code\":\"ConsoleOffline\"}"), .consoleUnavailable)
        XCTAssertEqual(XboxStop.classify("StreamingDisabled"), .consoleUnavailable)
        XCTAssertEqual(XboxStop.classify("Xbox WebRTC failed"), .other)
        XCTAssertEqual(XboxStop.classify(nil), .other)
        // Hata türü meşgulse neden ne olursa olsun; ilk kare gelmeyince (consoleUnavailable) "ulaşılamadı" denmez.
        XCTAssertEqual(XboxStop.classify("?", kind: .busy), .busy)
        XCTAssertEqual(XboxStop.classify("Xbox'tan 20 sn içinde görüntü gelmedi", kind: .consoleUnavailable), .other)
    }

    func testReasonIsShortened() {
        let short = XboxStop.shorten("Xbox service HTTP 500: " + String(repeating: "x", count: 600))
        XCTAssertEqual(short.count, XboxStop.reasonLimit)
        XCTAssertTrue(short.hasPrefix("Xbox service HTTP 500: "))
        XCTAssertTrue(short.hasSuffix("…"))
        XCTAssertEqual(XboxStop.shorten("  a\n  b\t c "), "a b c")
        XCTAssertEqual(XboxStop.shorten("  ", fallback: "network"), "network")
        XCTAssertEqual(XboxStop.shorten(nil), "?")
    }

    func testSummarySeparatesNoPictureFromPictureThenDrop() {
        XCTAssertEqual(XboxStop.summary(reason: "WebRTC failed", frames: 0, secondsSinceFirstFrame: nil),
                       "bağlantı bitti: WebRTC failed; kare 0, ilk kareden sonra ilk kare yok")
        XCTAssertEqual(XboxStop.summary(reason: nil, frames: 1200, secondsSinceFirstFrame: 95),
                       "bağlantı bitti: durduruldu; kare 1200, ilk kareden sonra 95 sn")
        XCTAssertEqual(XboxStop.summary(reason: "x", frames: 3, acks: 2, secondsSinceFirstFrame: 1),
                       "bağlantı bitti: x; kare 3, onay 2, ilk kareden sonra 1 sn")
    }
}

final class XboxFirstFrameWatchTests: XCTestCase {
    /// 0-30 sn arasını 500 ms'lik adımlarla yürütür (oturumdaki saat gibi); isteklerin ve tanıların anları.
    private func run(_ watch: inout XboxFirstFrameWatch, untilMs: Int = 30_000, readyAtMs: Int = 0, frameAtMs: Int? = nil) -> (keyframes: [Int], stats: [Int]) {
        var keyframes: [Int] = [], stats: [Int] = []
        for t in stride(from: 0, through: untilMs, by: 500) {
            if let frameAtMs, t >= frameAtMs { watch.frameArrived() }
            let step = watch.tick(sinceConnectedMs: t, keyframeReady: t >= readyAtMs)
            if step.requestKeyframe { keyframes.append(t) }
            if step.logStats { stats.append(t) }
        }
        return (keyframes, stats)
    }

    func testKeyframeIsRequestedEveryTwoAndAHalfSecondsForTwentySeconds() {
        var watch = XboxFirstFrameWatch()
        XCTAssertEqual(run(&watch).keyframes, [0, 2500, 5000, 7500, 10_000, 12_500, 15_000, 17_500, 20_000])
        XCTAssertEqual(watch.keyframesRequested, 9)
    }

    func testKeyframeWaitsUntilTrackAndControlChannelAreReady() {
        var watch = XboxFirstFrameWatch()
        let keyframes = run(&watch, readyAtMs: 1500).keyframes
        XCTAssertEqual(keyframes[0], 1500)
        XCTAssertEqual(keyframes[1], 4000)
        XCTAssertTrue(keyframes.allSatisfy { $0 <= 20_000 })
    }

    func testFirstFrameStopsKeyframesAndStats() {
        var watch = XboxFirstFrameWatch()
        let result = run(&watch, frameAtMs: 6000)
        XCTAssertEqual(result.keyframes, [0, 2500, 5000])
        XCTAssertEqual(result.stats, [])
        XCTAssertTrue(watch.frameSeen)
        XCTAssertEqual(watch.tick(sinceConnectedMs: 40_000, keyframeReady: true), XboxWatchStep())
    }

    func testStatsStartAfterTenSecondsAndRepeatEveryTenWithoutFrame() {
        var watch = XboxFirstFrameWatch()
        XCTAssertEqual(run(&watch, untilMs: 60_000).stats, [10_000, 20_000, 30_000, 40_000, 50_000, 60_000])
    }

    func testStalledClockDoesNotWriteMissedStatsTwice() {
        var watch = XboxFirstFrameWatch()
        XCTAssertTrue(watch.tick(sinceConnectedMs: 35_000, keyframeReady: false).logStats)
        XCTAssertFalse(watch.tick(sinceConnectedMs: 35_500, keyframeReady: false).logStats)
        XCTAssertTrue(watch.tick(sinceConnectedMs: 40_000, keyframeReady: false).logStats)
    }

    func testKeyframeRequestMatchesPlayer() {
        XCTAssertEqual(XboxFirstFrameWatch.keyframeRequest, "{\"message\":\"videoKeyframeRequested\",\"ifrRequested\":true}")
    }

    private func report(_ json: String) throws -> [XboxStat] {
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        return entries.map { XboxStat(type: $0["type"] as? String ?? "", id: $0["id"] as? String ?? "", members: $0) }
    }

    func testDiagnosticLineSummarisesVideoCandidatePairAndPicture() throws {
        let stats = try report("""
            [
              {"type":"transport","id":"T01","selectedCandidatePairId":"CP2"},
              {"type":"candidate-pair","id":"CP1","localCandidateId":"L1","remoteCandidateId":"R1","state":"failed","nominated":false},
              {"type":"candidate-pair","id":"CP2","localCandidateId":"L2","remoteCandidateId":"R2","state":"succeeded","nominated":true},
              {"type":"local-candidate","id":"L2","candidateType":"host","protocol":"udp","networkType":"ethernet"},
              {"type":"remote-candidate","id":"R2","candidateType":"srflx","protocol":"udp"},
              {"type":"inbound-rtp","id":"IA","kind":"audio","packetsReceived":900},
              {"type":"inbound-rtp","id":"IV","kind":"video","packetsReceived":1234,"bytesReceived":567890.0,"packetsLost":3,
               "framesDecoded":0,"framesDropped":0,"keyFramesDecoded":0,"pliCount":4,"decoderImplementation":"VideoToolbox"}
            ]
            """)
        XCTAssertEqual(
            XboxStreamStats.describe(sinceConnectedMs: 10_400, frameSeen: false, keyframes: 5, stats: stats, picture: XboxStreamStats.picture(trackState: "LIVE")),
            "tanı (10 sn, ilk kare yok): keyframe isteği 5; video paket 1234, bayt 567890, kayıp 3, çözülen 0, düşen 0, anahtar kare 0, PLI 4, "
                + "çözücü VideoToolbox; aday yerel host/udp ağ ethernet, uzak srflx, durum succeeded; görüntü parça LIVE")
    }

    func testDiagnosticLineWithoutVideoOrSelectedPair() throws {
        let stats = try report(#"[{"type":"candidate-pair","id":"CP1","state":"in-progress","nominated":false}]"#)
        XCTAssertEqual(XboxStreamStats.describe(sinceConnectedMs: 20_000, frameSeen: false, keyframes: 0, stats: stats, picture: "görüntü parça ENDED"),
                       "tanı (20 sn, ilk kare yok): keyframe isteği 0; video yok; aday seçilmedi; görüntü parça ENDED")
    }

    func testNominatedSucceededPairIsUsedWhenTransportHasNoSelection() throws {
        let stats = try report("""
            [{"type":"candidate-pair","id":"CP1","localCandidateId":"L1","remoteCandidateId":"R1","state":"succeeded","nominated":true},
             {"type":"local-candidate","id":"L1","candidateType":"relay","protocol":"tcp"}]
            """)
        let line = XboxStreamStats.describe(sinceConnectedMs: 10_000, frameSeen: false, keyframes: 1, stats: stats, picture: "görüntü")
        XCTAssertTrue(line.contains("aday yerel relay/tcp ağ ?, uzak ?, durum succeeded;"), line)
    }

    func testDiagnosticLineNamesTheNegotiatedCodec() throws {
        let stats = try report("""
            [{"type":"inbound-rtp","id":"IV","kind":"video","packetsReceived":258,"bytesReceived":0,"codecId":"C1"},
             {"type":"codec","id":"C1","mimeType":"video/H264","sdpFmtpLine":"level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f"}]
            """)
        let line = XboxStreamStats.describe(sinceConnectedMs: 10_000, frameSeen: false, keyframes: 4, stats: stats, picture: "görüntü")
        XCTAssertTrue(line.contains("çözücü ?, kodek video/H264 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f; aday seçilmedi"), line)
        XCTAssertTrue(XboxStreamStats.types.contains("codec"))
    }

    func testFirstFrameLimitIsThirtySeconds() {
        XCTAssertEqual(XboxFirstFrameWatch.firstFrameLimitMs, 30_000)
    }
}
