// SPDX-License-Identifier: AGPL-3.0-only
// #907: iPhone'da Xbox sesi kulaklıktan telefonun hoparlörüne geçiyordu. Ses oturumu medya oynatma oturumu olmalı,
// mikrofon açılmamalı, çıkış hiçbir yerde hoparlöre zorlanmamalı (iPhone ve Android telefon).

import Foundation
import XCTest
@testable import CouchSubsCore

final class PhoneAudioPolicyTests: XCTestCase {
    func testMediaSessionIsPlaybackWithoutMicrophoneOrSpeakerOverride() {
        let policy = PhoneAudioPolicy.media
        XCTAssertEqual(policy.category, "AVAudioSessionCategoryPlayback")
        XCTAssertEqual(policy.mode, "AVAudioSessionModeMoviePlayback")
        XCTAssertTrue(policy.mixesWithOthers, "telefonda çalan müzik kesilmemeli")
        XCTAssertFalse(policy.forcesSpeaker, "çıkış hoparlöre zorlanmamalı")
        XCTAssertFalse(policy.usesMicrophone, "mikrofon açılmamalı")
        XCTAssertEqual(PhoneAudioPolicy.playoutChannels, 1)
        XCTAssertEqual(PhoneAudioPolicy.playoutSampleRate, 48_000)
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Yorumlar dışındaki kod satırları (yorumlarda hatanın nedeni anlatılıyor).
    private func codeLines(in folder: String, extensions: Set<String>) -> [(String, String)] {
        let base = Self.root.appendingPathComponent(folder)
        guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var lines: [(String, String)] = []
        for case let url as URL in files where extensions.contains(url.pathExtension) && !url.path.contains("/build/") && !url.path.contains("/.build/") {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: "\n") {
                let code = line.components(separatedBy: "//").first ?? ""
                if !code.trimmingCharacters(in: .whitespaces).isEmpty { lines.append((url.lastPathComponent, code)) }
            }
        }
        return lines
    }

    func testIPhoneCodeNeverForcesSpeakerOrRecordingSession() {
        let lines = codeLines(in: "couchsubs-ios", extensions: ["swift"]) + codeLines(in: "remoteplay/Sources", extensions: ["swift"])
        XCTAssertFalse(lines.isEmpty, "kaynaklar bulunamadı")
        for forbidden in [".defaultToSpeaker", "overrideOutputAudioPort", ".playAndRecord", "RTCAudioSessionConfiguration"] {
            let hits = lines.filter { $0.1.contains(forbidden) }.map(\.0)
            XCTAssertTrue(hits.isEmpty, "\(forbidden) kulaklığı devre dışı bırakır: \(hits)")
        }
    }

    func testAndroidPhoneCodeNeverForcesSpeakerOrCallAudio() {
        let lines = codeLines(in: "couchsubs-android/app/src/main", extensions: ["kt", "java"])
        XCTAssertFalse(lines.isEmpty, "kaynaklar bulunamadı")
        for forbidden in ["setSpeakerphoneOn", "MODE_IN_COMMUNICATION", "USAGE_VOICE_COMMUNICATION", "STREAM_VOICE_CALL", "setCommunicationDevice"] {
            let hits = lines.filter { $0.1.contains(forbidden) }.map(\.0)
            XCTAssertTrue(hits.isEmpty, "\(forbidden) sesi hoparlöre/görüşme sesine zorlar: \(hits)")
        }
    }
}
