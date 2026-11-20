// SPDX-License-Identifier: AGPL-3.0-only
using System.Security.Cryptography;
namespace CouchSubs.Core;

/// <summary>Kısa kod yalnız insan karşılaştırmasıdır; teslim için ayrı 128 bit istek sırrı gerekir.</summary>
public sealed class SubtitlePairing(Func<long>? clock = null)
{
    public sealed record Ticket(string Id, string Code);
    private readonly object gate = new();
    private readonly Func<long> now = clock ?? (() => Environment.TickCount64);
    private bool session;
    private long manualUntil, expires, cooldown;
    private Ticket? ticket;
    private bool approved;
    public void SetSession(bool active) { lock (gate) { session = active; if (!active) Clear(); } }
    public void Open() { lock (gate) manualUntil = now() + 120000; }
    public void Reset() { lock (gate) Clear(); }
    private void Clear() { ticket = null; approved = false; manualUntil = 0; cooldown = 0; }
    private void Expire() { if (ticket is not null && now() >= expires) { ticket = null; approved = false; cooldown = now() + 10000; } }
    public Ticket? Begin()
    {
        lock (gate)
        {
            Expire();
            if ((!session && now() >= manualUntil) || ticket is not null || now() < cooldown) return null;
            ticket = new(SubtitleAccess.CreateKey(), RandomNumberGenerator.GetInt32(100000, 1000000).ToString(System.Globalization.CultureInfo.InvariantCulture));
            expires = now() + 120000;
            approved = false;
            return ticket;
        }
    }
    public bool Resolve(string id, bool accept)
    {
        lock (gate)
        {
            Expire();
            if (ticket?.Id != id || approved) return false;
            if (accept) approved = true;
            else { ticket = null; cooldown = now() + 10000; }
            return true;
        }
    }
    /// <summary>Onay yanıtı kaybolursa aynı TV süre dolmadan tekrar alabilir. Yeni istek eskisini ezmez.</summary>
    public string Poll(string id)
    {
        lock (gate)
        {
            Expire();
            return ticket?.Id == id ? approved ? "approved" : "pending" : "expired";
        }
    }
}
