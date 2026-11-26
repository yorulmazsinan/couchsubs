// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Vision

public protocol TextReader: Sendable {
    func read(_ image: CGImage) throws -> String
    /// `deep` false ise boş bölgede büyütülmüş okuma denenmez (işlemciyi çok daha az yorar).
    func read(_ image: CGImage, deep: Bool) throws -> String
    /// Satırlar ayrı ayrı ve görüntüdeki yerleriyle.
    func readLines(_ image: CGImage, deep: Bool) throws -> Reading
}

extension TextReader {
    public func read(_ image: CGImage, deep: Bool) throws -> String { try read(image) }
    public func readLines(_ image: CGImage, deep: Bool) throws -> Reading { Reading(text: try read(image, deep: deep)) }
}

/// Apple Vision ile cihaz üstünde yazı tanıma. Satırlar yukarıdan aşağı sıralanır.
public struct VisionReader: TextReader {
    public var language = "en"

    public init(language: String = "en") {
        self.language = language
    }

    public func read(_ image: CGImage) throws -> String {
        try readLines(image, deep: true).lines.map(\.text).joined(separator: " ")
    }

    public func read(_ image: CGImage, deep: Bool) throws -> String {
        try readLines(image, deep: deep).lines.map(\.text).joined(separator: " ")
    }

    public func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
        deep ? try Self.firstLines(of: image, using: recognize) : try recognize(image)
    }

    /// Satırsız eski biçim (testler için): bulunan yazı tek metin olarak döner.
    public static func firstReading(of image: CGImage, using recognize: @escaping @Sendable (CGImage) throws -> String) throws -> String {
        try firstLines(of: image) { Reading(text: try recognize($0)) }.text
    }

    /// Vision geniş bölgede "Go!" gibi kısa satırları sık sık hiç bulmaz. Bölgede yazı çıkmazsa
    /// ortadaki şerit (altyazılar ortalıdır), sonra bölgenin tamamı büyütülerek yeniden okunur;
    /// yazı bulan ilk okuma kullanılır.
    ///
    /// İkisi **sırayla** okunur (#385, #507): Vision'ın metin tanıma kuyruğu (`VNCRImageReaderDetector`) seridir ve
    /// iki istek `DispatchQueue.concurrentPerform` ile aynı anda verildiğinde biri kuyrukta beklerken diğeri hiç
    /// dönmeyebiliyordu; okuma takılıyor, altyazı bir daha gelmiyordu. Bütün okumalar ayrıca `ReadQueue` ile tek sıradan
    /// geçer.
    public static func firstLines(of image: CGImage, using recognize: @escaping @Sendable (CGImage) throws -> Reading) throws -> Reading {
        let reading = try recognize(image)
        guard reading.lines.isEmpty else { return reading }

        // Şeritte bulunan satırın yeri şeridin değil bölgenin tamamının oranlarıyla verilir.
        let strip = stripRect(of: image, widthFraction: 0.4)
        let stripArea = TextBox(left: strip.minX / Double(image.width), top: 0, right: strip.maxX / Double(image.width), bottom: 1)
        if let found = try image.cropping(to: strip).flatMap({ scaled($0, by: 2) }).map({ try recognize($0).placed(in: stripArea) }),
           !found.lines.isEmpty {
            return found
        }
        // Bölgenin tamamı: büyütmenin uzun kenarı `maxFallbackDimension` ile sınırlanır; 4K bir bölgenin iki katı
        // tek başına saniyeler sürüyordu.
        if let found = try scaled(image, by: 2, maxDimension: maxFallbackDimension).map(recognize), !found.lines.isEmpty {
            return found
        }
        return .empty
    }

    /// Yedek okumada büyütülmüş görüntünün uzun kenarı (piksel). Altyazı için fazlasıyla yeterli.
    static let maxFallbackDimension = 1920

    private func recognize(_ image: CGImage) throws -> Reading {
        // Asıl okuyucu takılıyken (`ReadQueue`) okuma bu süreçteki Vision'a verilmez: o da aynı kilidi beklerdi (#679).
        if let rescuer = ReadQueue.activeRescuer { return try rescuer.recognize(image, language: language) }
        return try Self.recognize(image, language: language, fast: Self.useFastLevel)
    }

    /// Okuyucu yinelenerek takıldıysa (`ReadQueue`) okumalar bir süre (`ReadQueue.fastLevelHoldMs`) hızlı düzeyde
    /// yapılır; süre dolunca `ReadQueue` isabetli düzeye döner (#1210; eskiden uygulama yeniden açılana dek kalıcıydı).
    public static var useFastLevel: Bool {
        get { fastLevel.withLock { $0 } }
        set { fastLevel.withLock { $0 = newValue } }
    }
    private static let fastLevel = Locked(false)

    /// Bu süreçte isabetli düzeyde en az bir okuma bitti mi (model hazır). `ReadQueue` takılan okumayı bırakırken isteği
    /// ancak o zaman iptal eder: ilk açılışta model derlenirken iptal etmek derlemeyi her seferinde baştan başlatırdı.
    public static var hasReadAccurately: Bool {
        get { accurateDone.withLock { $0 } }
        set { accurateDone.withLock { $0 = newValue } }
    }
    private static let accurateDone = Locked(false)

    private final class Locked: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        func withLock<T>(_ body: (inout Bool) -> T) -> T { lock.withLock { body(&value) } }
    }

    /// Tek Vision isteği. `fast`: hızlı düzey; Neural Engine modelini kullanmaz, soğuk açılışta da hemen döner
    /// (yedek okuyucu bununla okur), isabeti biraz düşüktür.
    public static func recognize(_ image: CGImage, language: String, fast: Bool) throws -> Reading {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.recognitionLanguages = [language]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        if let cancellation = ReadQueue.currentCancellation {
            // Takılan istek bırakılınca iptal edilir (#1333): Vision'ın süreç genelindeki kilidini ancak böyle bırakır.
            // Eskiden bırakılan istek hiç dönmüyor, yeniden kurulan okuyucu da aynı kilitte takılıyordu.
            try cancellation.run(onCancel: { request.cancel() }) { try handler.perform([request]) }
        } else {
            try handler.perform([request])
        }
        if !fast, !hasReadAccurately { hasReadAccurately = true }
        let lines = (request.results ?? [])
            .compactMap { observation -> TextLine? in
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5 else { return nil }
                // Vision'ın kutusu sol alttan ölçülür; burada üstten ölçülür.
                let box = Self.textBox(observation.boundingBox)
                return TextLine(candidate.string.trimmingCharacters(in: .whitespacesAndNewlines), box: box,
                                confidence: Double(candidate.confidence), words: Self.words(of: candidate, in: box))
            }
            .sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
        return Reading(lines: lines)
    }

    private static func textBox(_ rect: CGRect) -> TextBox {
        TextBox(left: rect.minX, top: 1 - rect.maxY, right: rect.maxX, bottom: 1 - rect.minY)
    }

    /// Boşlukla ayrılan her sözcüğün yeri (`VNRecognizedText.boundingBox(for:)`); yazının içindeki kumanda simgesini
    /// bulmaya yarar (`ButtonIcons`, Windows: WindowsOcrReader sözcük kutuları). Vision bazı sürümlerde sözcük yerine
    /// bütün satırın kutusunu verebilir; sözcükler soldan sağa sıralı değilse ya da biri satırın neredeyse tamamını
    /// kaplıyorsa sözcük yerleri kullanılmaz (nil: yerler harf sayısına göre kestirilir).
    static func words(of candidate: VNRecognizedText, in line: TextBox) -> [TextWord]? {
        let text = candidate.string
        var words: [TextWord] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            guard let observation = try? candidate.boundingBox(for: word.startIndex..<word.endIndex) else { return nil }
            words.append(TextWord(String(word), box: textBox(observation.boundingBox)))
        }
        guard !words.isEmpty else { return nil }
        let lineWidth = line.right - line.left
        for (index, word) in words.enumerated() {
            guard word.box.right > word.box.left else { return nil }
            if words.count > 1, word.box.right - word.box.left >= lineWidth * 0.9 { return nil }
            if index > 0, word.box.left < words[index - 1].box.left { return nil }
        }
        return words
    }

    private static func stripRect(of image: CGImage, widthFraction: Double) -> CGRect {
        let width = Double(image.width) * widthFraction
        return CGRect(x: (Double(image.width) - width) / 2, y: 0, width: width, height: Double(image.height)).integral
    }

    private static func scaled(_ image: CGImage, by factor: Int, maxDimension: Int? = nil) -> CGImage? {
        var scale = Double(factor)
        let longest = max(image.width, image.height)
        if let maxDimension, longest > 0, Double(longest) * scale > Double(maxDimension) {
            scale = max(1, Double(maxDimension) / Double(longest))
        }
        let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
