// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

/// Annex-B (başlangıç kodlu) H.264 akışını NAL birimlerine ayırır.
enum AnnexB {
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(index: Int, length: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i + 3, 3))
                i += 3
            } else {
                i += 1
            }
        }
        var units: [Data] = []
        for (n, start) in starts.enumerated() {
            var end = n + 1 < starts.count ? starts[n + 1].index - 3 : bytes.count
            // 4 baytlık başlangıç kodunun baştaki sıfırı önceki birime ait değildir.
            if n + 1 < starts.count, end > start.index, bytes[end - 1] == 0 { end -= 1 }
            if end > start.index { units.append(Data(bytes[start.index..<end])) }
        }
        return units
    }
}

/// PS5'ten gelen H.264 kareleri donanımla (VideoToolbox) çözer.
/// Her kare çözülmelidir (sonraki kareler öncekilere dayanır); görüntü yalnız istendiğinde üretilir.
final class H264FrameDecoder {
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    /// Çözme hatası bu çözücüde günlüğe yazıldı mı (her oturumda bir kez). Hata eskiden sessizce yutuluyordu: görüntü
    /// gelmeyince yalnız "görüntü gelmiyor" görünüyordu; iPhone arka plandayken donanım çözücüsü reddedebilir.
    private var loggedFailure = false

    /// Çözücü servisi koptuğu için oturumun kaç kez yeniden kurulduğu (günlüğe ilk birkaçı yazılır).
    private var rebuilds = 0

    deinit {
        if let session { Self.close(session) }
    }

    /// Bu hatadan sonra oturum yeniden kurulup kare bir kez daha denenir. Geçersiz oturum: uykudan sonra. Arıza ve
    /// şimdilik yok: çözücü servisi (VTDecoderXPCService) çöktü ya da bellek sıkışmasında sistemce kapatıldı (#1390);
    /// eskiden ölü oturuma her kare yeniden veriliyor, görüntü bir daha gelmiyordu.
    static func rebuildsSession(after status: OSStatus) -> Bool {
        status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr || status == kVTVideoDecoderNotAvailableNowErr
    }

    /// Oturumu kapatır: önce süren çözme bitirilir, sonra geçersiz kılınır (kapanmış oturuma geç gelen kare bırakılmasın).
    private static func close(_ session: VTDecompressionSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }

    func decode(annexB: Data, makeImage: Bool = true) -> CGImage? {
        var slices: [Data] = []
        var newSPS: Data?
        var newPPS: Data?
        for nal in AnnexB.nalUnits(in: annexB) {
            switch nal.first.map({ $0 & 0x1F }) {
            case 7: newSPS = nal
            case 8: newPPS = nal
            case 1, 5: slices.append(nal)
            default: break
            }
        }
        if let newSPS, let newPPS, newSPS != sps || newPPS != pps {
            sps = newSPS
            pps = newPPS
            makeSession()
        }
        guard session != nil, format != nil, !slices.isEmpty else { return nil }

        // VideoToolbox başlangıç kodu değil, 4 baytlık uzunluk önekli birimler bekler.
        var avcc = Data()
        for slice in slices {
            var length = UInt32(slice.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(slice)
        }
        var (status, output) = decodeFrame(avcc)
        if Self.rebuildsSession(after: status) {
            // Aynı parametrelerle yeniden kurup bir kez daha dene.
            rebuilds += 1
            if status != kVTInvalidSessionErr, rebuilds <= 3 {
                RemotePlayLog.write("Görüntü çözücü: oturum yeniden kuruluyor (OSStatus \(status), \(rebuilds). kez)")
            }
            makeSession()
            (status, output) = decodeFrame(avcc)
        }
        if status != noErr { noteFailure("kare çözülemedi (OSStatus \(status))") }
        guard status == noErr, makeImage, let pixelBuffer = output else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return image
    }

    private func decodeFrame(_ avcc: Data) -> (OSStatus, CVPixelBuffer?) {
        guard let session, let format, let sample = makeSampleBuffer(avcc, format: format) else { return (kVTInvalidSessionErr, nil) }
        var output: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            if status == noErr { output = imageBuffer }
        }
        return (status, output)
    }

    func invalidateSessionForTesting() {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    private func makeSession() {
        if let session { Self.close(session) }
        session = nil
        format = nil
        guard let sps, let pps else { return }

        var description: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return }

        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        var newSession: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                                   imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                   decompressionSessionOut: &newSession)
        guard created == noErr else { return noteFailure("çözücü açılamadı (OSStatus \(created))") }
        format = description
        session = newSession
    }

    private func noteFailure(_ text: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        RemotePlayLog.write("Görüntü çözücü: \(text)")
    }

    private func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
