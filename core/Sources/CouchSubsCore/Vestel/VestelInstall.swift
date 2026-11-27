// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network

/// Vestel Linux TV'ye yerel altyazı istemcisini TEK ADIMDA kurar ve başlatır (deneysel).
///
/// Vestel'in kendi Linux'unda test aracı soketi (TCP 1986) gönderilen satırı root olarak çalıştırır (bu TV'de doğrulandı).
/// ÖN KOŞUL: 1986 firmware'de kapalıdır; tek seferlik DevProfile (TesttoolSocket=True, USB + servis menüsü 4725 → USB
/// Diagnostic → güç döngüsü) ile açılır. Akış: 1986'dan `telnetd` 2323'te açılır → 2323 kabuğuna indir+çalıştır komutu
/// yollanır → istemci CouchSubs bilgisayarından (`http://<mac>:<port>/vestel-tv-client`) kendini indirir, çalışır ve
/// bilgisayara bağlanıp eşleşir → telnetd kapatılır (kalıcı açık port bırakılmaz). TV'ye hiçbir kalıcı dosya yazılmaz;
/// her şey `/tmp`'dedir ve TV yeniden başlayınca silinir.
///
/// Komut üretimi (saf) test edilebilir; ağ çalıştırması NWConnection iledir. İstemci yalnız TV içindir; Mac'te çalışmaz.
public enum VestelInstall {
    public static let testToolPort: UInt16 = 1986
    public static let shellPort: UInt16 = 2323
    /// İstemcinin bilgisayardan indirileceği yol (SubtitleServer anahtarsız sunar).
    public static let downloadPath = "/vestel-tv-client"

    public enum Step: String, Sendable {
        case reach = "TV'ye ulaşılıyor"
        case shell = "TV'de kabuk açılıyor"
        case run = "İstemci indiriliyor ve başlatılıyor"
        case done = "İstemci çalışıyor, eşleşme bekleniyor"
    }

    public enum Failure: Error, Sendable {
        case badAddress                 // Mac IP yok ya da güvenli değil
        case testToolUnreachable        // 1986 kapalı/erişilemez (TV destekli mi?)
        case shellUnreachable           // telnetd 2323 açılmadı
        case sendFailed
    }

    /// Mac IP'si kabuk komutuna gömüldüğü için katı doğrulanır (IPv4; komut enjeksiyonu engellenir).
    public static func safeIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isNumber) && (Int(p) ?? 999) <= 255 }
    }

    /// 1986'ya gönderilecek satır: telnetd'yi 2323'te /bin/sh ile başlat (bu TV'de doğrulandı).
    static let openShellLine = "/bin/telnetd -p 2323 -l /bin/sh\n"

    /// 2323 kabuğuna gönderilecek tek satır: eskisini durdur, indir, çalıştırılabilir yap, ayrık başlat, telnetd'yi kapat.
    /// Anahtar yok: istemci bilgisayara bağlanınca eşleşme kodunu kendisi alır.
    static func installLine(macAddress: String, serverPort: Int, closeShell: Bool = true) -> String {
        let url = "http://\(macAddress):\(serverPort)\(downloadPath)"
        var c = "cd /tmp && kill $(pidof couchsubs-vestel-tv) 2>/dev/null; "
        c += "wget -q \(url) -O couchsubs-vestel-tv && chmod +x couchsubs-vestel-tv && "
        c += "nohup ./couchsubs-vestel-tv \(macAddress) \(serverPort) >/tmp/couchsubs.log 2>&1 &"
        if closeShell { c += " sleep 2; kill $(pidof telnetd) 2>/dev/null" }
        return c + "\n"
    }

    /// TV'ye tek adımda kurar. `progress` ana aşamaları bildirir (UI için). Başarı: istemci çalıştırıldı — eşleşme
    /// isteği birazdan CouchSubs'ta görünür. Hata fırlatırsa UI elle kuruluma yönlendirir.
    public static func run(host: String, macAddress: String, serverPort: Int,
                           progress: @Sendable @escaping (Step) -> Void) async throws {
        guard safeIPv4(macAddress) else { throw Failure.badAddress }

        progress(.reach)
        // 1) 1986: telnetd'yi aç. Yanıt beklenmez (soket komutu çalıştırıp kapatabilir).
        do { try await send(host: host, port: testToolPort, line: openShellLine, waitReplyMs: 0) }
        catch { throw Failure.testToolUnreachable }

        progress(.shell)
        // telnetd'nin portu açması için kısa bekleme.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        progress(.run)
        // 2) 2323 kabuğu: indir+çalıştır. Birkaç kez denenir (telnetd geç açılabilir).
        let line = installLine(macAddress: macAddress, serverPort: serverPort)
        var launched = false
        for attempt in 0..<3 {
            do { try await send(host: host, port: shellPort, line: line, waitReplyMs: 2500); launched = true; break }
            catch { if attempt < 2 { try? await Task.sleep(nanoseconds: 1_200_000_000) } }
        }
        if !launched { throw Failure.shellUnreachable }

        progress(.done)
    }

    /// Bir TCP bağlantısı aç, satırı gönder, isteğe bağlı kısa süre yanıt bekle, kapat. Yanıt içeriği kullanılmaz;
    /// amaç komutun kabuğa yazılabilmesi. `waitReplyMs=0` ise gönderir göndermez kapatır.
    static func send(host: String, port: UInt16, line: String, waitReplyMs: Int) async throws {
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finished = Locked(false)
            func finish(_ result: Result<Void, Error>) {
                guard finished.swap(true) == false else { return }
                cont.resume(with: result)
            }
            // Bağlantı kurulamazsa/zaman aşımına uğrarsa hata.
            let timeout = DispatchWorkItem { finish(.failure(Failure.sendFailed)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(6), execute: timeout)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(line.utf8), completion: .contentProcessed { error in
                        if let error { timeout.cancel(); finish(.failure(error)); return }
                        if waitReplyMs <= 0 { timeout.cancel(); finish(.success(())); return }
                        // Yanıtı kısa süre bekle (kabuğun komutu işlemesine zaman tanı), sonra başarı say.
                        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(waitReplyMs)) {
                            timeout.cancel(); finish(.success(()))
                        }
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in }
                    })
                case .failed(let error), .waiting(let error):
                    timeout.cancel(); finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }
}

/// Küçük atomik bayrak (continuation'ın tek sefer tamamlanması için).
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func swap(_ new: T) -> T { lock.lock(); defer { lock.unlock() }; let old = value; value = new; return old }
}
