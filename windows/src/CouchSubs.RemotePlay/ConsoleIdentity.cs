// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.RemotePlay;

/// <summary>
/// Kayıtlı PS5'i ağda tanıma kuralı (Mac/iPhone <c>ConsoleIdentity</c>, Android <c>ConsoleIdentity</c> ile aynı).
/// PS5'in değişmeyen kimliği keşif yanıtındaki <c>host-id</c>'dir (PS5'in MAC adresi, 12 onaltılık hane; kayıtta PS5'in
/// bildirdiği MAC ile aynı). Eskiden PS5 yalnız adıyla eşleniyordu: ad değişince yeni adreste bulunamıyor, aynı adlı iki
/// PS5'te emin olunamıyordu. Kimliği bilinen kayıt kimlikle eşlenir; eski kayıtta (kimlik yok) ad kuralı geçerlidir ve PS5
/// adıyla bir kez bulununca kimliği kayda yazılır.
/// </summary>
public static class ConsoleIdentity
{
    /// <summary>Kimliğin karşılaştırılan biçimi: yalnız onaltılık haneler, büyük harf. Boş ya da tamamı sıfır kimlik null.</summary>
    public static string? Normalized(string? raw)
    {
        if (raw is null) return null;
        var hex = new string([.. raw.ToUpperInvariant().Where(Uri.IsHexDigit)]);
        return hex.Length == 0 || hex.All(c => c == '0') ? null : hex;
    }

    /// <summary>Kayıt yanıtındaki MAC'ten (6 bayt) kimlik; boşsa null.</summary>
    internal static string? FromMac(ReadOnlySpan<byte> mac) => Normalized(Convert.ToHexString(mac[..Math.Min(6, mac.Length)]));

    /// <summary>Aramaya yanıt veren PS5 kayıtlı PS5 mi: iki tarafta da kimlik varsa kimlik (ad bakılmaz), yoksa ad (boşluk ve
    /// harf büyüklüğü gözetilmez; kayıtta ad yoksa her yanıt kabul edilir).</summary>
    public static bool IsRegistered(ConsoleInfo info, RegisteredConsole console) =>
        console.HostId is { } wanted && info.HostId is { } found ? wanted == found : MatchesName(info, console.Name);

    internal static bool MatchesName(ConsoleInfo info, string name) =>
        name.Trim().Length == 0 || string.Equals(info.Name.Trim(), name.Trim(), StringComparison.OrdinalIgnoreCase);

    /// <summary>Ağda bulunanlar arasından kayıtlı PS5 (tek eşleşen); emin olunamazsa null (başka PS5'e geçilmez, GitHub #425).</summary>
    public static ConsoleInfo? PickMoved(IReadOnlyList<ConsoleInfo> found, RegisteredConsole console)
    {
        var matches = found.Where(c => IsRegistered(c, console)).ToList();
        return matches.Count == 1 ? matches[0] : null;
    }

    /// <summary>Eşleşen yanıttan öğrenilenlerle kayıt: yeni adres, (eski kayıtta) kimlik ve kimlikle eşlendiyse PS5'in yeni adı.
    /// Değişen bir şey yoksa null.</summary>
    public static RegisteredConsole? Updated(RegisteredConsole console, ConsoleInfo info)
    {
        var byId = console.HostId is not null && console.HostId == info.HostId;
        // Ad yalnız gerçekten değiştiyse yazılır (harf ya da boşluk farkı değişiklik sayılmaz).
        var renamed = byId && info.Name.Trim().Length > 0 && !MatchesName(info, console.Name);
        var name = renamed ? info.Name.Trim() : console.Name;
        var hostId = console.HostId ?? info.HostId;
        if (info.Host == console.Host && hostId == console.HostId && name == console.Name) return null;
        return console with { Host = info.Host, Name = name, HostId = hostId };
    }

    /// <summary>Kayıt güncellenince günlüğe giden satır (Mac ve Android'de aynı metin).</summary>
    public static string ChangeLine(RegisteredConsole old, RegisteredConsole updated)
    {
        var parts = new List<string>();
        if (old.Host != updated.Host)
            parts.Add($"PS5 yeni adreste bulundu: {old.Host} → {updated.Host} ({(old.HostId is not null ? "host-id ile" : "adıyla")})");
        if (old.HostId is null && updated.HostId is { } id) parts.Add($"PS5 kimliği kayda yazıldı: {id}");
        if (old.Name != updated.Name) parts.Add($"PS5'in adı değişmiş: {old.Name} → {updated.Name}");
        return string.Join("; ", parts);
    }
}

/// <summary>
/// Tüm ağı tarayarak PS5 araması ne zaman yapılır (Mac <c>RelocateSchedule</c>, Android <c>RelocateSchedule</c> ile aynı).
/// Tarama pahalı (~1000 adres, 3 sn); PS5 kapalıyken her denemede yapılmaz. Eskiden iki tarama arası hep 30 sn'ydi; artık
/// bağlantı kopunca ilk denemede hemen, sonra 10 sn, 30 sn, 1 dk, 2 dk, sonra 5 dk arayla taranır (#1366: PS5 bulunamadıkça
/// tarama seyrelir). PS5 bulununca sıra baştan başlar.
/// </summary>
public sealed class RelocateSchedule
{
    public static readonly TimeSpan[] Delays =
    [
        TimeSpan.Zero, TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(30), TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(2),
        TimeSpan.FromMinutes(5),
    ];
    private DateTime next = DateTime.MinValue;
    private int misses;

    public bool IsDue(DateTime now) => now >= next;

    /// <summary>Tarama bitti: PS5 bulunduysa sonraki tarama hemen yapılabilir, bulunamadıysa bekleme uzar.</summary>
    public void Searched(bool found, DateTime now)
    {
        if (found)
        {
            misses = 0;
            next = DateTime.MinValue;
            return;
        }
        misses++;
        next = now + Delays[Math.Min(misses, Delays.Length - 1)];
    }

    /// <summary>Bağlantı başarısız oldu (akış koptu ya da PS5 bağlantıyı reddetti): sonraki denemede beklemeden taranır.</summary>
    public void ConnectionFailed()
    {
        misses = 0;
        next = DateTime.MinValue;
    }
}

/// <summary>
/// Kayıtlı PS5'i bulur: önce kayıtlı adreste, yanıt yoksa ya da yanıt veren başka bir PS5'se ağda (kimlikle). Oturum dışında
/// da kullanılır (çalışan oyun yoklaması); kayıt değişirse <see cref="Changed"/> çağrılır.
/// </summary>
public sealed class ConsoleFinder(RegisteredConsole console, Func<string?, IReadOnlyList<ConsoleInfo>>? discover = null)
{
    private readonly object gate = new();
    private readonly RelocateSchedule schedule = new();
    private readonly Func<string?, IReadOnlyList<ConsoleInfo>> discover = discover ?? LiveDiscover;
    private RegisteredConsole current = console;

    /// <summary>Kaydın değiştiği iş parçacığında çağrılır.</summary>
    public event Action<RegisteredConsole>? Changed;

    /// <summary><c>null</c> tüm ağı, adres yalnız o adresi sorar (bloklar).</summary>
    public static IReadOnlyList<ConsoleInfo> LiveDiscover(string? host) =>
        ConsoleDiscovery.Discover(host, TimeSpan.FromSeconds(host is null ? 3 : 2));

    public RegisteredConsole Console
    {
        get { lock (gate) return current; }
    }

    public void ConnectionFailed()
    {
        lock (gate) schedule.ConnectionFailed();
    }

    /// <summary>Kayıtlı adresi sorar. Yanıt veren kayıtlı PS5'se o (eski kayıtta kimliği öğrenilir). Değilse, <paramref name="sweep"/>
    /// açıksa ve tarama zamanıysa ağ taranır. <c>AtHost</c>: kayıtlı adreste yanıt veren (başka PS5 olabilir). Bloklar.
    /// <c>sweep: false</c>: ağ hiç taranmaz (bağlıyken çalışan oyun yoklaması, #1366).</summary>
    public (ConsoleInfo? Info, ConsoleInfo? AtHost) Locate(bool sweep = true)
    {
        var saved = Console;
        var atHost = discover(saved.Host).FirstOrDefault();
        if (atHost is not null && ConsoleIdentity.IsRegistered(atHost, saved))
        {
            Learn(atHost);
            return (atHost, atHost);
        }
        if (atHost is not null)
            RemotePlayLog.Note($"PS5: {saved.Host} adresinde başka PS5 yanıt verdi ({atHost.Name})" + (sweep ? $", {saved.Name} ağda aranıyor" : ""));
        return (sweep ? Relocate() : null, atHost);
    }

    /// <summary>Ağı tarar (zamanı geldiyse); kayıtlı PS5 bulunursa kayıt güncellenir.</summary>
    public ConsoleInfo? Relocate()
    {
        lock (gate)
            if (!schedule.IsDue(DateTime.UtcNow)) return null;
        var moved = ConsoleIdentity.PickMoved(discover(null), Console);
        lock (gate) schedule.Searched(moved is not null, DateTime.UtcNow);
        if (moved is not null) Learn(moved);
        return moved;
    }

    private void Learn(ConsoleInfo info)
    {
        RegisteredConsole old;
        RegisteredConsole? updated;
        lock (gate)
        {
            old = current;
            updated = ConsoleIdentity.Updated(old, info);
            if (updated is not null) current = updated;
        }
        if (updated is null) return;
        RemotePlayLog.Note(ConsoleIdentity.ChangeLine(old, updated));
        try { Changed?.Invoke(updated); }
        catch (Exception error) { RemotePlayLog.Write(0, $"ConsoleMoved handler: {error}"); }
    }
}
