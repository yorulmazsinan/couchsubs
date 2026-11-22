// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

final class SpeechScriptTests: XCTestCase {
    private func lines(_ text: String) -> [SpokenLine] {
        let pieces = SubtitleSegmenter.split(text)
        return SpeechScript.lines(pieces: pieces, translations: pieces.map { $0.translate ? "TR " + $0.text : nil })
    }

    func testSpeakerLabelsBelongToTheirSentences() {
        let result = lines("KRATOS: We go now. Stay close.\nATREUS: Okay.")
        XCTAssertEqual(result.map(\.speaker), ["KRATOS", "KRATOS", "ATREUS"])
        XCTAssertEqual(result[0].english, "We go now.")
        XCTAssertEqual(result[0].turkish, "TR We go now.")
    }

    func testDialogueDashesStartNewTurns() {
        let result = lines("- Where are we?\n- Home.")
        XCTAssertEqual(result.map(\.speaker), [nil, nil])
        XCTAssertEqual(result.map(\.newTurn), [true, true])
    }

    func testUnlabeledLinesHaveNoSpeaker() {
        XCTAssertEqual(lines("The bridge is gone.").map(\.speaker), [nil])
    }

    /// Çeviri arka planda yazar, okuma hattı ana iş parçacığında okur; ikisi aynı anda olunca çökmemeli (kapasite dolup
    /// boşaltılırken de).
    func testSpeechMemoryIsSafeAcrossThreads() {
        let memory = SpeechMemory()
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<2_000 {
                let text = "line \(worker) \(index)"
                if worker % 2 == 0 {
                    memory.store([SpokenLine(english: text, turkish: "satır")], for: text)
                } else {
                    _ = memory["line \(worker - 1) \(index)"]
                }
            }
        }
        memory.store([SpokenLine(english: "Go.", turkish: "Git.")], for: "Go.")
        XCTAssertEqual(memory["Go."]?.map(\.turkish), ["Git."])
        XCTAssertNil(memory["never stored"])
    }
}

final class SpeechTextTests: XCTestCase {
    func testEmotionComesFromTheEnglishLine() {
        XCTAssertEqual(SpeechEmotion.guess(english: "Get back! This is not your fight."), .angry)
        XCTAssertEqual(SpeechEmotion.guess(english: "What?! The door opened by itself!"), .surprised)
        XCTAssertEqual(SpeechEmotion.guess(english: "I'm sorry. I couldn't save her."), .sad)
        XCTAssertEqual(SpeechEmotion.guess(english: "We did it! We're going home."), .happy)
        XCTAssertEqual(SpeechEmotion.guess(english: "Breathe, boy. Take your time."), .calm)
        XCTAssertNil(SpeechEmotion.guess(english: "We need to cross the river."))
    }

    func testTextStartsLowercaseWithTheTagFirst() {
        XCTAssertEqual(SpeechText.prepare("Geri çekil!", emotion: .angry), "[kızgın] geri çekil!")
        XCTAssertEqual(SpeechText.prepare("İleri gidelim.  Hemen…"), "ileri gidelim. hemen...")
        XCTAssertEqual(SpeechText.prepare("Ne?! Kapı açıldı!!"), "ne? kapı açıldı!")
        XCTAssertEqual(SpeechText.prepare("Işığı kapat."), "ışığı kapat.")
    }

    func testNumbersAreSpelledOut() {
        XCTAssertEqual(TurkishNumbers.words(1250), "bin iki yüz elli")
        XCTAssertEqual(TurkishNumbers.words(2_000_105), "iki milyon yüz beş")
        XCTAssertEqual(TurkishNumbers.words(100), "yüz")
        XCTAssertEqual(TurkishNumbers.spellOut(in: "3 kapı, %20 şans, saat 14:30, 3,5 metre, 1.500 altın"),
                       "üç kapı, yüzde yirmi şans, saat on dört otuz, üç virgül beş metre, bin beş yüz altın")
        XCTAssertEqual(TurkishNumbers.spellOut(in: "09:05"), "dokuz sıfır beş")
    }
}

final class VoiceCastTests: XCTestCase {
    func testEachCharacterKeepsItsVoice() {
        var cast = VoiceCast()
        let kratos = cast.voice(for: SpokenLine(speaker: "KRATOS", english: "", turkish: ""))
        let freya = cast.voice(for: SpokenLine(speaker: "Freya", english: "", turkish: ""))
        let atreus = cast.voice(for: SpokenLine(speaker: "ATREUS", english: "", turkish: ""))
        XCTAssertEqual(kratos.gender, .male)
        XCTAssertEqual(freya.gender, .female)
        XCTAssertEqual(atreus.gender, .male)
        XCTAssertNotEqual(kratos, atreus)
        XCTAssertNotEqual(kratos, cast.narrator, "anlatıcı sesi karakterlere en son verilir")
        XCTAssertEqual(cast.voice(for: SpokenLine(speaker: "Kratos", english: "", turkish: "")), kratos)
    }

    func testDashedTurnsAlternateVoices() {
        var cast = VoiceCast()
        let first = cast.voice(for: SpokenLine(newTurn: true, english: "", turkish: ""))
        let second = cast.voice(for: SpokenLine(newTurn: true, english: "", turkish: ""))
        let sameTurn = cast.voice(for: SpokenLine(english: "", turkish: ""))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second, sameTurn)
    }

    func testManualChoiceIsKeptAndSaved() throws {
        var cast = VoiceCast()
        cast.assign(.female3, to: "Mimir")
        let restored = try JSONDecoder().decode(VoiceCast.self, from: JSONEncoder().encode(cast))
        var copy = restored
        XCTAssertEqual(copy.voice(for: SpokenLine(speaker: "MIMIR", english: "", turkish: "")), .female3)
    }
}

final class SpeechAudioTests: XCTestCase {
    /// 24 kHz: 0,3 sn ses, 0,4 sn sessizlik, 0,3 sn ses, 0,5 sn sessizlik.
    private func sample() -> SpeechAudio {
        let rate = 24000
        func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * Double(rate))).map { sin(Float($0) * 0.1) * 0.5 } }
        func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * Double(rate))) }
        return SpeechAudio(samples: silence(0.2) + tone(0.3) + silence(0.4) + tone(0.3) + silence(0.5), sampleRate: rate)
    }

    func testLongPausesAreShortenedTo200ms() {
        let tightened = sample().tightened()
        // 0,3 + 0,2 + 0,3 sn konuşma, 0,03 sn baş, 0,08 sn son.
        XCTAssertEqual(tightened.duration, 0.91, accuracy: 0.03)
    }

    func testShortPausesStay() {
        let rate = 24000
        let tone = (0..<7200).map { sin(Float($0) * 0.1) * 0.5 }
        let audio = SpeechAudio(samples: tone + Array(repeating: 0, count: rate / 10) + tone, sampleRate: rate)
        XCTAssertEqual(audio.tightened(lead: 0, tail: 0).duration, audio.duration, accuracy: 0.02)
    }

    func testWAVRoundTrip() throws {
        let audio = SpeechAudio(samples: [0, 0.5, -0.5, 0.25], sampleRate: 24000)
        let decoded = try SpeechAudio(wav: audio.wav)
        XCTAssertEqual(decoded.sampleRate, 24000)
        XCTAssertEqual(decoded.samples.count, 4)
        XCTAssertEqual(decoded.samples[1], 0.5, accuracy: 0.001)
    }

    func testStreamedWAVWithUnknownSizeIsRead() throws {
        var data = SpeechAudio(samples: [0.5, 0.5], sampleRate: 24000).wav
        data.replaceSubrange(40..<44, with: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(try SpeechAudio(wav: data).samples.count, 2)
    }
}

final class DubbingModelTests: XCTestCase {
    func testLocalConfigPointsAtDownloadedFiles() {
        let original = """
        weights_path: hf://wite-tech/pocket-tts-turkish/model.safetensors
        flow_lm:
          lookup_table:
            tokenizer: sentencepiece
            tokenizer_path: hf://wite-tech/pocket-tts-turkish/tokenizer.model

        """
        let local = DubbingModel.localConfig(from: original, directory: URL(fileURLWithPath: "/tmp/model dir"))
        XCTAssertTrue(local.contains("weights_path: '/tmp/model dir/model.safetensors'"))
        XCTAssertTrue(local.contains("    tokenizer_path: '/tmp/model dir/tokenizer.model'"))
        XCTAssertTrue(local.hasSuffix("capitalize_first_letter: false\n"))
    }
}

/// Telefonlarda (ve Windows'ta "Hızlı" dublajda) cihazın kendi sesiyle karakterler ton ve hızla ayrılır; değerler
/// Windows WindowsVoiceModel.Tone ve Android DubbingVoice ile aynı.
final class SystemVoiceToneTests: XCTestCase {
    func testTonesMatchWindowsAndAndroid() {
        let tones = DubbingVoice.allCases.map { [$0.systemTone.pitch, $0.systemTone.rate] }
        XCTAssertEqual(tones, [[1.55, 1.1], [1.4, 1.0], [1.48, 1.05], [0.85, 0.95], [1.05, 1.15], [0.95, 1.05]])
    }

    func testPreparedTextForTheSystemVoiceHasNoEmotionTag() {
        XCTAssertEqual(SpeechText.prepare("Geri çekil!"), "geri çekil!")
    }
}
