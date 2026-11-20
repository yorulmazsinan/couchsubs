// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Kısa kod karşılaştırma içindir; teslim için ayrı 128 bit istek sırrı gerekir.
public final class SubtitlePairing: @unchecked Sendable {
    public struct Ticket: Sendable, Identifiable, Equatable { public let id: String; public let code: String }
    private let lock = NSLock()
    private let now: () -> Int64
    private var session = false
    private var manualUntil: Int64 = 0
    private var expires: Int64 = 0
    private var cooldown: Int64 = 0
    private var ticket: Ticket?
    private var approved = false
    public init(clock: @escaping () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }) { now = clock }
    public func setSession(_ active: Bool) { lock.lock(); defer { lock.unlock() }; session = active; if !active { clear() } }
    public func open() { lock.lock(); defer { lock.unlock() }; manualUntil = now() + 120000 }
    public func reset() { lock.lock(); defer { lock.unlock() }; clear() }
    private func clear() { ticket = nil; approved = false; manualUntil = 0; cooldown = 0 }
    private func expire() { if ticket != nil && now() >= expires { ticket = nil; approved = false; cooldown = now() + 10000 } }
    public func begin() -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        expire()
        guard (session || now() < manualUntil), ticket == nil, now() >= cooldown else { return nil }
        let result = Ticket(id: SubtitleAccess.createKey(), code: String(Int.random(in: 100000...999999)))
        ticket = result; expires = now() + 120000; approved = false
        return result
    }
    @discardableResult public func resolve(_ id: String, accept: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        expire()
        guard ticket?.id == id, !approved else { return false }
        if accept { approved = true } else { ticket = nil; cooldown = now() + 10000 }
        return true
    }
    public func poll(_ id: String) -> String {
        lock.lock(); defer { lock.unlock() }
        expire()
        return ticket?.id == id ? (approved ? "approved" : "pending") : "expired"
    }
}
