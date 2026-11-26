// SPDX-License-Identifier: AGPL-3.0-only

#if os(macOS)
import CoreGraphics
import Foundation

/// Ayrı süreçte yazı tanıma (#679): asıl süreçteki Vision takılınca okumayı sürdüren yedek.
///
/// Vision'ın kilidi süreç genelindedir; takılan isteği bu süreçte hiçbir şey aşamaz (bkz. `ReadRescuer`). Yardımcı süreç
/// uygulamanın kendi çalıştırılabilir dosyasıdır (`--ocr-helper` ile); kareyi stdin'den alır, satırları stdout'a yazar.
/// Takılırsa öldürülür ve yenisi açılır.
///
/// Yardımcı önce **hızlı** düzeyde okur: hızlı düzey Neural Engine modelini kullanmaz, soğuk açılışta bile
/// milisaniyelerde döner (isabetli düzey macOS 27'de ilk açılışta modeli 30–90 sn derler). Asıl okuyucu
/// `accurateAfterMs`'dir düzelmediyse ikinci bir yardımcıda isabetli düzey denenir; o hazır olunca okumalar ona geçer.
public enum OcrHelper {
    /// Uygulama bu argümanla açıldıysa pencere açmadan yardımcı olarak çalışır.
    public static let argument = "--ocr-helper"

    struct Header: Codable {
        var width: Int
        var height: Int
        var language: String
        var fast: Bool
    }

    struct Line: Codable {
        var t: String
        var c: Double?
        /// Kutu: sol, üst, sağ, alt.
        var b: [Double]?
        var w: [Word]?
    }

    struct Word: Codable {
        var t: String
        var b: [Double]
    }

    struct Reply: Codable {
        var lines: [Line]?
        var error: String?
    }

    public enum Failure: Error, Equatable {
        /// Yardımcı açılamadı ya da okuma sürerken kapandı.
        case closed
        case failed(String)
    }

    static func encode(_ reading: Reading) -> [Line] {
        reading.lines.map { line in
            Line(t: line.text, c: line.confidence, b: line.box.map(array),
                 w: line.words?.map { Word(t: $0.text, b: array($0.box)) })
        }
    }

    static func decode(_ lines: [Line]) -> Reading {
        Reading(lines: lines.map { line in
            TextLine(line.t, box: line.b.flatMap(box), confidence: line.c,
                     words: line.w?.compactMap { word in box(word.b).map { TextWord(word.t, box: $0) } })
        })
    }

    private static func array(_ box: TextBox) -> [Double] { [box.left, box.top, box.right, box.bottom] }

    private static func box(_ values: [Double]) -> TextBox? {
        values.count == 4 ? TextBox(left: values[0], top: values[1], right: values[2], bottom: values[3]) : nil
    }

    /// Karenin RGBA baytları (8 bit, satır başına `width * 4`).
    static func pixels(of image: CGImage) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var data = Data(count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }

    static func image(from data: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, data.count == width * height * 4, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Çerçeveleme: [uzunluk: UInt32 BE][bayt]

    static func write(_ data: Data, to fd: Int32) -> Bool {
        var length = UInt32(data.count).bigEndian
        let head = Data(bytes: &length, count: 4)
        return writeAll(head, to: fd) && writeAll(data, to: fd)
    }

    static func read(from fd: Int32, limit: Int = 256 * 1024 * 1024) -> Data? {
        guard let head = readExactly(4, from: fd) else { return nil }
        let length = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard length <= limit else { return nil }
        return readExactly(length, from: fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    private static func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        let complete: Bool = data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let got = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
                if got < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if got == 0 { return false }
                offset += got
            }
            return true
        }
        return complete ? data : nil
    }

    // MARK: - Yardımcı süreç tarafı

    /// Yardımcının ana döngüsü: stdin kapanınca (uygulama kapandı) çıkar. Uygulama, yardımcı Vision'da takılıyken
    /// kapanırsa stdin okunamaz; bu yüzden ayrıca üst süreç izlenir.
    public static func serve(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
                             recognize: (CGImage, String, Bool) throws -> Reading = { try VisionReader.recognize($0, language: $1, fast: $2) }) {
        // Her istek kendi autorelease havuzunda (#1390). Bu döngü run loop'suz ana iş parçacığında döner; havuz hiç
        // boşalmadığından Vision'ın autorelease ettiği nesneler (istek, sonuçlar, IOSurface tamponları) ve karenin
        // CGImage'ı süreç kapanana dek kalıyordu: yardımcı her okumada ~2,5 MB büyüyüp onlarca GB'a çıkıyor, Mac takas
        // alanını doldurup kilitleniyordu.
        while autoreleasepool(invoking: { answerOne(input: input, output: output, recognize: recognize) }) {}
    }

    /// Bir isteği okur (başlık, kare), yanıtını yazar. Giriş kapandıysa ya da yanıt yazılamadıysa false.
    static func answerOne(input: Int32, output: Int32, recognize: (CGImage, String, Bool) throws -> Reading) -> Bool {
        guard let head = read(from: input, limit: 64 * 1024),
              let header = try? JSONDecoder().decode(Header.self, from: head),
              let body = read(from: input) else { return false }
        let reply = answer(header, body, recognize: recognize)
        guard let data = try? JSONEncoder().encode(reply) else { return false }
        return write(data, to: output)
    }

    static func answer(_ header: Header, _ body: Data, recognize: (CGImage, String, Bool) throws -> Reading) -> Reply {
        guard let frame = image(from: body, width: header.width, height: header.height) else { return Reply(error: "kare çözülemedi") }
        do {
            return Reply(lines: encode(try recognize(frame, header.language, header.fast)))
        } catch {
            return Reply(error: "\(error)")
        }
    }

    /// Bir sürecin belleği: yerleşik (RSS) ve footprint (sıkıştırılmış ve takastaki kirli bellek dahil; Etkinlik
    /// Monitörü'nün "Bellek"i).
    public struct Memory: Equatable, Sendable {
        public var resident: UInt64
        public var footprint: UInt64
        public init(resident: UInt64, footprint: UInt64) {
            self.resident = resident
            self.footprint = footprint
        }
        /// Sınırla karşılaştırılan değer: takasa itilen bellek RSS'te görünmez, footprint'te görünür.
        public var used: UInt64 { max(resident, footprint) }
        public var text: String { "\(footprint / 1_048_576) MB (yerleşik \(resident / 1_048_576) MB)" }
    }

    /// Sürecin belleği; ölçülemezse nil.
    public static func memory(of pid: pid_t) -> Memory? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        return Memory(resident: info.ri_resident_size, footprint: info.ri_phys_footprint)
    }

    /// Uygulamanın `main`'inden çağrılır; dönmez.
    public static func runAsHelper() -> Never {
        let parent = getppid()
        Thread.detachNewThread {
            // Üst süreç öldüyse (launchd'ye devredildiyse) yardımcı da kapanır.
            while getppid() == parent { Thread.sleep(forTimeInterval: 2) }
            exit(0)
        }
        serve()
        exit(0)
    }
}

/// Çalışan bir yardımcı süreç; istekler sırayla, senkron.
final class OcrHelperProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(executable: URL, arguments: [String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        // Yardımcı kapanmışken yazmak süreci SIGPIPE ile öldürmesin; yazma hata döner.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
    }

    func recognize(_ image: CGImage, language: String, fast: Bool) throws -> Reading {
        guard let pixels = OcrHelper.pixels(of: image),
              let head = try? JSONEncoder().encode(OcrHelper.Header(width: image.width, height: image.height, language: language, fast: fast))
        else { throw OcrHelper.Failure.failed("kare hazırlanamadı") }
        let fd = input.fileHandleForWriting.fileDescriptor
        guard OcrHelper.write(head, to: fd), OcrHelper.write(pixels, to: fd),
              let data = OcrHelper.read(from: output.fileHandleForReading.fileDescriptor),
              let reply = try? JSONDecoder().decode(OcrHelper.Reply.self, from: data) else { throw OcrHelper.Failure.closed }
        if let error = reply.error { throw OcrHelper.Failure.failed(error) }
        return OcrHelper.decode(reply.lines ?? [])
    }

    var pid: pid_t { process.processIdentifier }

    /// Süreci öldürür; süren `recognize` `closed` ile döner.
    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        try? input.fileHandleForWriting.close()
    }

    deinit { kill() }
}

/// `ReadQueue`'nun Mac'teki yedeği: yardımcı süreçte okur.
public final class OcrHelperRescuer: ReadRescuer, @unchecked Sendable {
    /// Asıl okuyucu bu kadar süredir düzelmediyse isabetli düzey ikinci bir yardımcıda denenir (model derlemesi
    /// çoğunlukla bundan önce biter ve asıl okuyucuya dönülür).
    public static let defaultAccurateAfterMs = 120_000
    /// İsabetli yardımcının ilk okuması (model derlemesi dahil) en çok bu kadar beklenir.
    public static let accurateProbeLimitMs = 240_000
    /// Yardımcı art arda bu kadar kez açılamaz ya da kapanırsa yedek kullanılmaz (`ReadQueueError.stuck`).
    public static let maxLaunchFailures = 3

    private let executable: URL
    private let arguments: [String]
    private let accurateAfterMs: Int
    private let lock = NSLock()
    private var fast: OcrHelperProcess?
    private var accurate: OcrHelperProcess?
    private var probe: OcrHelperProcess?
    private var probed = false
    private var since: Int?
    private var serving: OcrHelperProcess?
    private var busy = false
    private var closeWhenIdle = false
    private var launchFailures = 0
    /// İsabetli yardımcının bu yedek oturumunda kaç kez takılıp öldürüldüğü.
    private var accurateLosses = 0
    /// İsabetli yardımcı bu kadar kez takılırsa yedek oturumu boyunca hızlı düzeyde kalınır (her deneme modeli yükler).
    public static let maxAccurateLosses = 3
    /// Günlük için: yardımcı açıldı, isabetli düzeye geçildi, kapandı.
    public var onLog: (@Sendable (String) -> Void)?

    /// Yardımcının belleği bunu aşarsa (okuma bitince bakılır) yardımcı kapatılır, sonraki okuma yenisini açar (#1390).
    /// Sağlıklı yardımcı isabetli düzeyin modeliyle birlikte birkaç yüz MB'tır; bir sızıntı Mac'i takasa boğmadan durdurulur.
    public static let defaultMemoryCapBytes: UInt64 = 1536 << 20
    /// Okumalar sürdükçe yardımcının belleği en çok bu aralıkla günlüğe yazılır.
    public static let memoryLogIntervalMs = 60_000

    private let memoryCapBytes: UInt64
    private let memoryOf: @Sendable (pid_t) -> OcrHelper.Memory?
    private var lastMemoryLog: Int?
    private var memoryUnreadableNoted = false

    public init(executable: URL, arguments: [String] = [OcrHelper.argument], accurateAfterMs: Int = OcrHelperRescuer.defaultAccurateAfterMs,
                memoryCapBytes: UInt64 = OcrHelperRescuer.defaultMemoryCapBytes,
                memoryOf: @escaping @Sendable (pid_t) -> OcrHelper.Memory? = { OcrHelper.memory(of: $0) }) {
        self.executable = executable
        self.arguments = arguments
        self.accurateAfterMs = accurateAfterMs
        self.memoryCapBytes = memoryCapBytes
        self.memoryOf = memoryOf
    }

    /// Okumalar isabetli düzeydeki yardımcıdan mı geliyor.
    public var isAccurate: Bool { lock.withLock { accurate != nil } }

    /// Asıl okuyucu kilitli kalınca yedek kalıcı okuyucudur; isabetli düzeydeyse uyarı gerekmez (#1307).
    public var isFullQuality: Bool { isAccurate }

    /// İsabetli yardımcı takılıp öldürülünce isabetli düzey bu kadar sonra yeniden denenir (model artık derlenmiş;
    /// yeniden deneme hızlı döner). Eskiden oturum boyunca hızlı düzeyde kalınıyordu (#1307, 19:45).
    public static let accurateRetryMs = 30_000

    /// Kilit altında çağrılır: isabetli yardımcı kaybedildi; hızlıya düşülür, isabetli düzey `accurateRetryMs` sonra
    /// yeniden denenir.
    private func lostAccurate() {
        accurate = nil
        accurateLosses += 1
        guard accurateLosses < Self.maxAccurateLosses else { return }
        probed = false
        since = ReadQueue.uptimeMs() - max(0, accurateAfterMs - Self.accurateRetryMs)
    }

    public func recognize(_ image: CGImage, language: String) throws -> Reading {
        let (helper, isFast) = try lock.withLock { () throws -> (OcrHelperProcess, Bool) in
            guard launchFailures < Self.maxLaunchFailures else { throw ReadQueueError.stuck }
            closeWhenIdle = false
            let now = ReadQueue.uptimeMs()
            if since == nil { since = now }
            if accurate == nil, !probed, let since, now - since >= accurateAfterMs { startProbe(language: language) }
            let helper: OcrHelperProcess
            if let accurate {
                helper = accurate
            } else if let fast {
                helper = fast
            } else {
                do {
                    helper = try OcrHelperProcess(executable: executable, arguments: arguments)
                } catch {
                    launchFailures += 1
                    onLog?("yedek okuyucu açılamadı: \(error.localizedDescription)")
                    throw OcrHelper.Failure.closed
                }
                fast = helper
                onLog?("yedek okuyucu açıldı (ayrı süreç, hızlı düzey)")
            }
            serving = helper
            busy = true
            return (helper, helper === fast)
        }
        defer {
            lock.withLock {
                busy = false
                serving = nil
                if closeWhenIdle { close() }
            }
        }
        do {
            let reading = try helper.recognize(image, language: language, fast: isFast)
            lock.withLock { launchFailures = 0 }
            watchMemory(of: helper, isFast: isFast)
            return reading
        } catch OcrHelper.Failure.closed {
            lock.withLock {
                launchFailures += 1
                if fast === helper { fast = nil }
                if accurate === helper { lostAccurate() }
            }
            helper.kill()
            throw OcrHelper.Failure.closed
        }
    }

    /// Okuma bitince yardımcının belleğine bakılır: dakikada bir günlüğe yazılır; sınırı aştıysa yardımcı kapatılır ve
    /// sonraki okuma yenisini açar (isabetli yardımcıysa isabetli düzey hemen yeniden denenir; model derlenmiş olduğundan
    /// hızlı döner). Kilit dışında çağrılır.
    private func watchMemory(of helper: OcrHelperProcess, isFast: Bool) {
        let level = isFast ? "hızlı" : "isabetli"
        guard let memory = memoryOf(helper.pid) else {
            let first: Bool = lock.withLock {
                defer { memoryUnreadableNoted = true }
                return !memoryUnreadableNoted
            }
            if first { onLog?("yedek okuyucunun belleği ölçülemedi (\(level) düzey)") }
            return
        }
        let now = ReadQueue.uptimeMs()
        if memory.used > memoryCapBytes {
            lock.withLock {
                lastMemoryLog = now
                if fast === helper { fast = nil }
                if accurate === helper {
                    accurate = nil
                    probed = false
                    since = now - accurateAfterMs
                }
            }
            helper.kill()
            onLog?("yedek okuyucu bellek sınırını aştı: \(memory.text), sınır \(memoryCapBytes / 1_048_576) MB; "
                   + "\(level) düzeydeki yardımcı kapatıldı, sonraki okumada yenisi açılacak")
            return
        }
        let due: Bool = lock.withLock {
            guard lastMemoryLog.map({ now - $0 >= Self.memoryLogIntervalMs }) ?? true else { return false }
            lastMemoryLog = now
            return true
        }
        if due { onLog?("yedek okuyucunun belleği: \(memory.text), \(level) düzey") }
    }

    /// Asıl okuyucu kilitli kaldı (#1333): yedek kalıcı okuyucudur, isabetli düzey bir sonraki okumada hemen denenir
    /// (`accurateAfterMs` beklenmez). Eskiden iki dakika hızlı düzeyde okunuyor, altyazılar bozuk geliyordu.
    public func preferFullQuality() {
        lock.withLock {
            guard accurate == nil, !probed else { return }
            since = ReadQueue.uptimeMs() - accurateAfterMs
        }
    }

    public func abandon() {
        let helper: OcrHelperProcess? = lock.withLock {
            let helper = serving
            if fast === helper { fast = nil }
            if accurate === helper { lostAccurate() }
            return helper
        }
        helper?.kill()
    }

    public func standDown() {
        lock.withLock {
            if busy { closeWhenIdle = true } else { close() }
        }
    }

    /// Kilit altında çağrılır.
    private func close() {
        let had = fast != nil || accurate != nil || probe != nil
        fast?.kill()
        accurate?.kill()
        probe?.kill()
        fast = nil
        accurate = nil
        probe = nil
        probed = false
        since = nil
        closeWhenIdle = false
        launchFailures = 0
        accurateLosses = 0
        if had { onLog?("yedek okuyucu kapatıldı") }
    }

    /// Kilit altında çağrılır: ikinci yardımcıda isabetli düzeyi dener; ilk okuması dönerse okumalar ona geçer.
    private func startProbe(language: String) {
        probed = true
        guard let helper = try? OcrHelperProcess(executable: executable, arguments: arguments) else { return }
        probe = helper
        onLog?("yedek okuyucu: isabetli düzey deneniyor")
        let blank = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        Thread.detachNewThread { [weak self] in
            let ready = blank.map { (try? helper.recognize($0, language: language, fast: false)) != nil } ?? false
            guard let self else { return helper.kill() }
            self.lock.withLock {
                guard self.probe === helper else { return helper.kill() }
                self.probe = nil
                if ready {
                    self.accurate = helper
                    self.onLog?("yedek okuyucu isabetli düzeye geçti")
                } else {
                    helper.kill()
                    self.onLog?("yedek okuyucu: isabetli düzey hazır olmadı, hızlı düzeyle sürüyor")
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(Self.accurateProbeLimitMs)) { [weak self] in
            // Hâlâ dönmediyse bırakılır; bekleyen `recognize` `closed` ile döner.
            let stuck = self?.lock.withLock { self?.probe === helper } ?? false
            if stuck { helper.kill() }
        }
    }
}
#endif
