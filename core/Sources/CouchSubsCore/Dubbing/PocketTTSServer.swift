// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// Ses motoru ayrı bir program olarak çalışır; iOS'ta başka program başlatılamadığı için yalnız macOS.
#if os(macOS)

/// Kyutai'nin pocket-tts programını (MIT) yerel sunucu olarak çalıştırır: model bir kez yüklenir, her cümle
/// `POST /tts` ile seslendirilir. Sunucu yalnız bu bilgisayardan (127.0.0.1) erişilebilir.
public actor PocketTTSServer {
    public enum ServerError: Error, Equatable {
        /// Program açılmadı ya da model yüklenemedi.
        case notReady
        case failed(String)
    }

    private let executable: URL
    private let config: URL
    private let defaultVoice: URL
    private let pidFile: URL?
    private let threads: Int
    private let process = LockedProcess()
    private var port: UInt16 = 0
    private var starting: Task<Void, Error>?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    /// `threads`: işlemcinin geri kalanı (oyun akışı, çeviri) yavaşlamasın diye sınırlı.
    public init(executable: URL, config: URL, defaultVoice: URL, pidFile: URL? = nil, threads: Int = 4) {
        self.executable = executable
        self.config = config
        self.defaultVoice = defaultVoice
        self.pidFile = pidFile
        self.threads = threads
    }

    /// Sunucu çalışmıyorsa başlatır ve modelin yüklenmesini bekler (ilk açılış birkaç saniye sürer).
    public func start() async throws {
        if process.isRunning, starting == nil { return }
        if let starting { return try await starting.value }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch() async throws {
        if let pidFile { Self.stopLeftover(pidFile) }
        let port = try Self.freePort()
        let child = Process()
        child.executableURL = executable
        child.arguments = ["serve", "--config", config.path, "--host", "127.0.0.1", "--port", String(port),
                           "--default-voice", defaultVoice.path]
        var environment = ProcessInfo.processInfo.environment
        environment["RAYON_NUM_THREADS"] = String(threads)
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        // Seslendirme, altyazı okuma ve çeviriyle yarışıp onları geciktirmesin: işlemciyi en son o alır.
        child.qualityOfService = .utility
        do { try child.run() } catch { throw ServerError.notReady }
        process.set(child)
        self.port = port
        if let pidFile { try? String(child.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8) }

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            guard child.isRunning else { throw ServerError.notReady }
            if let (_, response) = try? await session.data(from: URL(string: "http://127.0.0.1:\(port)/health")!),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        stop()
        throw ServerError.notReady
    }

    /// `voice`: sesin adresi (http://…, sunucu sesi bir kez hazırlayıp saklar).
    public func synthesize(_ text: String, voice: URL) async throws -> SpeechAudio {
        try await start()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tts")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(["text": text, "voice_url": voice.absoluteString]).utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServerError.failed(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try SpeechAudio(wav: data)
    }

    public func stop() {
        terminate()
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
    }

    /// Uygulama kapanırken eşzamanlı çağrılır.
    public nonisolated func terminate() {
        process.terminate()
    }

    // MARK: - Yardımcılar

    /// application/x-www-form-urlencoded gövde; değerlerdeki & = + gibi işaretler de kodlanır.
    public static func form(_ fields: KeyValuePairs<String, String>) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    /// Uygulama çökerse sunucu açık kalabilir; bir sonraki açılışta yalnız o PID, adı pocket-tts ise kapatılır.
    private static func stopLeftover(_ pidFile: URL) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
           URL(fileURLWithPath: String(cString: buffer)).lastPathComponent == "pocket-tts" {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// İşletim sisteminin verdiği boş bir yerel port.
    private static func freePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ServerError.notReady }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw ServerError.notReady }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// Uygulama kapanırken eşzamanlı sonlandırılabilen alt süreç.
private final class LockedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    var isRunning: Bool { lock.withLock { process?.isRunning == true } }

    func set(_ process: Process) { lock.withLock { self.process = process } }

    func terminate() {
        lock.withLock {
            if process?.isRunning == true { process?.terminate() }
            process = nil
        }
    }
}
#endif
