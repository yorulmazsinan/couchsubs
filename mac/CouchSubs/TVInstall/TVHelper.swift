// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import Foundation
import RemotePlay

/// Samsung ve Android TV kurulumunu yapan gömülü yardımcıdan gelen olay.
enum TVInstallEvent: Equatable, Sendable {
    /// Samsung hesabıyla giriş gerekiyor; sayfa tarayıcıda açılmalı.
    case signIn(URL)
    /// Android TV ekranında hata ayıklama izni soruluyor.
    case approveOnTV
    case progress(String)
}

/// TV kurulum günlüğü: ~/Library/Logs/CouchSubs/tvinstall.log (Windows'ta %LOCALAPPDATA%\CouchSubs\tvinstall.log).
/// Samsung kurulumunun her adımını yardımcı yazar; yardımcı açılamaz ya da sonuç vermeden kapanırsa uygulama da buraya
/// yazar. Kurulum olmazsa kullanıcı bu dosyayı gönderir.
enum TVInstallLog {
    /// Kullanıcıya hata iletisinde gösterilen yol (sandbox'ta kapsayıcının içindeki yol).
    static var displayPath: String { RemotePlayLog.userPath(file) }

    static var file: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/CouchSubs/tvinstall.log")
    }

    private static let lock = NSLock()

    static func write(_ line: String, to file: URL = file) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = "[" + formatter.string(from: Date()) + "] " + line + "\n"
        lock.withLock {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.fileExists(atPath: file.path) else {
                    try Data(text.utf8).write(to: file)
                    return
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
            } catch {
                // Günlük yazılamasa da kurulum sürer.
            }
        }
    }
}

/// Uygulamanın içindeki `couchsubs-tv-helper` aracını çalıştırır (kaynağı windows/src/CouchSubs.TvHelper; Windows
/// uygulaması aynı kitaplığı doğrudan kullanır). Her çıktı satırı bir JSON olaydır.
enum TVHelper {
    static var executable: URL? { Bundle.main.url(forAuxiliaryExecutable: "couchsubs-tv-helper") }

    /// Yardımcının kalıcı dosyaları (ADB anahtarı, Samsung sertifikaları).
    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(AppIdentity.name, isDirectory: true)
    }

    /// Komutun sonucu: `done` olayında sürüm, `found` olayında bulunan TV adresleri.
    struct Result: Equatable, Sendable {
        var version: String?
        var installed = false
        var hosts: [String] = []
    }

    /// Yardımcının bir çıktı satırı.
    enum Line: Equatable {
        case event(TVInstallEvent)
        case finished(Result)
        case failed(DevModeFailure)
    }

    /// Komutu çalıştırır; `done` olayına kadar bekler. `error` olayı yardımcının verdiği sebeple `DevModeFailure` olur;
    /// yardımcı açılamaz ya da sonuç yazmadan kapanırsa da sebep (çıkış kodu, hata çıktısı) gösterilir ve günlüğe yazılır.
    static func run(_ arguments: [String], onEvent: @escaping @Sendable (TVInstallEvent) -> Void = { _ in }) async throws -> Result {
        guard let executable else {
            TVInstallLog.write("couchsubs-tv-helper uygulamanın içinde yok.")
            throw DevModeFailure(.installFailed, detail: "couchsubs-tv-helper uygulamanın içinde bulunamadı; CouchSubs'ı yeniden indirip kurun.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments + ["--exit-with-input"]
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        let command = arguments.first ?? ""

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                let once = Resumer(continuation)
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }
                do {
                    try process.run()
                } catch {
                    TVInstallLog.write("couchsubs-tv-helper açılamadı: \(error)")
                    once.resume(.failure(DevModeFailure(.installFailed, detail: "couchsubs-tv-helper açılamadı: \(error.localizedDescription)")))
                    return
                }
                let stderr = TailBuffer(limit: 16_384)
                let stderrDone = DispatchGroup()
                stderrDone.enter()
                DispatchQueue.global(qos: .utility).async {
                    readUntilEnd(errors.fileHandleForReading) { stderr.append($0) }
                    stderrDone.leave()
                }
                // Satırlar çıktı kapanana kadar sırayla okunur. Sonuç ancak bundan sonra "çöktü" sayılır: önceden
                // kapanış bildirimi son satırdan önce gelebiliyordu ve TV'nin verdiği sebep kayboluyordu.
                DispatchQueue.global(qos: .userInitiated).async {
                    let reader = LineReader()
                    readUntilEnd(output.fileHandleForReading) { data in
                        for line in reader.append(data) {
                            switch parse(line) {
                            case .event(let event)?: onEvent(event)
                            case .finished(let result)?: once.resume(.success(result))
                            case .failed(let failure)?:
                                TVInstallLog.write("\(command): \(failure.error): \(failure.detail)")
                                once.resume(.failure(failure))
                            case nil: break
                            }
                        }
                    }
                    _ = exited.wait(timeout: .now() + 5)
                    _ = stderrDone.wait(timeout: .now() + 2)
                    let status: Int32? = process.isRunning ? nil : process.terminationStatus
                    let errorText = stderr.text
                    if !errorText.isEmpty { TVInstallLog.write("\(command) hata çıktısı:\n\(errorText)") }
                    let failure = unfinished(status: status, stderr: errorText)
                    if once.resume(.failure(failure)) { TVInstallLog.write("\(command): \(failure.detail)") }
                }
            }
        } onCancel: {
            try? input.fileHandleForWriting.close()
            process.terminate()
        }
    }

    /// Bir çıktı satırını okur; olay değilse nil.
    static func parse(_ line: String) -> Line? {
        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        switch event["event"] as? String {
        case "login":
            guard let url = (event["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return .event(.signIn(url))
        case "approve": return .event(.approveOnTV)
        case "progress": return .event(.progress(event["step"] as? String ?? ""))
        case "done", "found":
            return .finished(Result(version: event["version"] as? String, installed: event["installed"] as? Bool ?? false,
                                    hosts: event["hosts"] as? [String] ?? []))
        case "error": return .failed(failure(code: event["code"] as? String, message: event["message"] as? String))
        default: return nil
        }
    }

    /// Yardımcının hatası ve verdiği sebep (TV'nin kurulum çıktısı, Samsung'un yanıtı, sdb hatası).
    static func failure(code: String?, message: String?) -> DevModeFailure {
        let detail = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return DevModeFailure(error(code: code), detail: detail.isEmpty ? (code ?? "") : detail)
    }

    /// Yardımcı sonuç yazmadan kapandı (çöktü ya da açılır açılmaz kapandı).
    static func unfinished(status: Int32?, stderr: String) -> DevModeFailure {
        let exit = status.map { "çıkış kodu \($0)" } ?? "kapanmadı"
        var detail = "couchsubs-tv-helper sonuç vermeden bitti (\(exit))"
        let lastLines = stderr.split(separator: "\n").suffix(3).joined(separator: " | ")
        if !lastLines.isEmpty { detail += ": " + String(lastLines.prefix(400)) }
        return DevModeFailure(.installFailed, detail: detail)
    }

    static func error(code: String?) -> DevModeError {
        switch code {
        case "Unreachable": .unreachable
        case "NotApproved": .notApproved
        case "LoginFailed": .signInFailed
        case "CertificateFailed": .certificateFailed
        case "TooOld": .tooOld
        case "NotEnoughSpace": .notEnoughSpace
        case "CertificateMismatch": .certificateMismatch
        case "CertificateRejected": .certificateRejected
        case "TvClockWrong": .tvClockWrong
        case "PackageBlocked": .packageBlocked
        case "ConnectionLost": .connectionLost
        default: .installFailed
        }
    }

    /// Dosya kapanana kadar okur (bekleyerek; ayrı iş parçacığında çağrılır).
    private static func readUntilEnd(_ handle: FileHandle, _ body: (Data) -> Void) {
        while true {
            let data = handle.availableData
            if data.isEmpty { return }
            body(data)
        }
    }
}

/// Parça parça gelen çıktıyı satırlara böler.
final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) -> [String] {
        lock.withLock {
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
    }
}

/// Hata çıktısının son kısmı (çok uzarsa baştan kırpılır).
final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit { data.removeFirst(data.count - limit) }
        }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// Devamı yalnız bir kez sürdürür.
private final class Resumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TVHelper.Result, Error>?

    init(_ continuation: CheckedContinuation<TVHelper.Result, Error>) { self.continuation = continuation }

    /// Bu çağrı sürdürdüyse true (daha önce sürdürülmüşse false).
    @discardableResult
    func resume(_ result: Swift.Result<TVHelper.Result, Error>) -> Bool {
        let current = lock.withLock { () -> CheckedContinuation<TVHelper.Result, Error>? in
            defer { continuation = nil }
            return continuation
        }
        current?.resume(with: result)
        return current != nil
    }
}
