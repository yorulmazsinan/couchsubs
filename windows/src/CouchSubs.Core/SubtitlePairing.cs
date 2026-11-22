// SPDX-License-Identifier: AGPL-3.0-only
using System.Security.Cryptography;
namespace CouchSubs.Core;

/// <summary>
/// Kısa kod yalnız insan karşılaştırmasıdır; teslim için ayrı 128 bit istek sırrı gerekir. Kurallar Mac/iPhone
/// (CouchSubsCore/SubtitlePairing.swift) ve Android ile aynı; ortak deneme dosyası <c>subtitle-pairing.json</c>.
/// </summary>
public sealed class SubtitlePairing(Func<long>? clock = null)
{
    /// <param name="Host">
    /// İsteği gönderen TV'nin adresi (bkz. <see cref="SubtitleAccess.TvHost"/>); bilinmiyorsa boş. Onaylanınca bilgisayar
    /// bu TV'yi kendi TV kaydına alır (marka adresten yoklanır; bkz. <c>PairedTv</c>).
    /// </param>
    public sealed record Ticket(string Id, string Code, string Host = "");
    /// <summary>Onay bekleyen istek bu kadar eskiyse yeni istek onun yerini alır (bkz. <see cref="Begin"/>).</summary>
    public const long SupersedeAfterMs = 2000;
    private readonly object gate = new();
    private readonly Func<long> now = clock ?? (() => Environment.TickCount64);
    private bool session;
    private long manualUntil, expires, cooldown, began;
    private Ticket? ticket;
    private bool approved, delivered;
    /// <summary>
    /// Bilgisayarda reddedilen son istek: TV'ye <c>rejected</c> olarak söylenir. TV süresi dolan ya da düşen isteği kendisi
    /// yeniden ister, reddedileni istemez (Tamam bekler); yoksa reddedilen TV için pencere art arda açılırdı (GitHub #737).
    /// </summary>
    private string? rejected;
    /// <summary>Çeviri sürüyor mu (<see cref="SetSession"/>); <c>/hello</c>'daki <c>live</c> alanı.</summary>
    public bool InSession { get { lock (gate) return session; } }
    public void SetSession(bool active) { lock (gate) { session = active; if (!active) Clear(); } }
    public void Open() { lock (gate) manualUntil = now() + 120000; }
    public void Reset() { lock (gate) Clear(); }
    private void Clear() { ticket = null; approved = false; delivered = false; manualUntil = 0; cooldown = 0; rejected = null; }
    /// <summary>
    /// Süresi dolan isteğin bekleme süresi dolduğu andan sayılır. Eskiden ilk bakıldığı andan sayılıyordu: TV'de
    /// "Eşleştirme tamamlanmadı" çıktıktan sonra Tamam'a basınca istek on saniye boyunca reddediliyordu (409).
    /// </summary>
    private void Expire() { if (ticket is not null && now() >= expires) { ticket = null; approved = false; delivered = false; cooldown = expires + 10000; } }
    /// <summary>Eşleştirme açık mı (çeviri sürüyor ya da "TV eşleştir"in iki dakikası dolmadı).</summary>
    public bool IsOpen { get { lock (gate) return session || now() < manualUntil; } }
    /// <summary>Onay bekleyen istek (yoksa null). Arayüz kaçırdığı isteği buradan yeniden gösterir.</summary>
    public Ticket? Pending { get { lock (gate) { Expire(); return approved ? null : ticket; } } }
    /// <summary>
    /// TV'nin eşleştirme isteği. Onay bekleyen bir istek varken gelen yeni istek (TV uygulaması yeniden açıldı ya da TV'de
    /// Tamam ile yeniden denendi) <see cref="SupersedeAfterMs"/>'den eskiyse eskisinin yerini alır: bilgisayarda yeni kodla
    /// yeni pencere açılır. Eskiden eski istek iki dakika dolana kadar her yeni isteği engelliyordu. Anahtarı teslim
    /// edilmiş istek de yeni isteği engellemez.
    /// </summary>
    public Ticket? Begin(string host = "")
    {
        lock (gate)
        {
            Expire();
            if ((!session && now() >= manualUntil) || now() < cooldown) return null;
            if (ticket is not null && !(approved ? delivered : now() - began >= SupersedeAfterMs)) return null;
            ticket = new(SubtitleAccess.CreateKey(), RandomNumberGenerator.GetInt32(100000, 1000000).ToString(System.Globalization.CultureInfo.InvariantCulture), host);
            began = now();
            expires = began + 120000;
            approved = false;
            delivered = false;
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
            else { ticket = null; rejected = id; cooldown = now() + 10000; }
            return true;
        }
    }
    /// <summary>
    /// Onay yanıtı kaybolursa aynı TV süre dolmadan tekrar alabilir. Anahtar bir kez teslim edilince sıra boşalır: sonraki
    /// yeni istek (başka TV, yeniden açılan uygulama) eskisinin yerini alır. Durumlar: <c>pending</c>, <c>approved</c>,
    /// <c>rejected</c> (reddedildi) ya da <c>expired</c> (süresi doldu, yerini yenisi aldı, çeviri durdu). Sunucu
    /// <c>rejected</c>'ı eski TV uygulamaları için <c>expired</c> olarak, yanında <c>rejected: true</c> ile gönderir.
    /// </summary>
    public string Poll(string id)
    {
        lock (gate)
        {
            Expire();
            if (ticket?.Id != id) return id == rejected ? "rejected" : "expired";
            if (approved) delivered = true;
            return approved ? "approved" : "pending";
        }
    }
}
