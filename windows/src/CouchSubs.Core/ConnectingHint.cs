// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>Oturumun bağlanırken son bildirdiği adım (Mac/iPhone RemotePlay <c>ConnectStep</c>, Android ile aynı).</summary>
public enum ConnectStep
{
    /// <summary>PS5 aramaya yanıt vermedi; yine de bağlanılıyor.</summary>
    NoAnswer,
    /// <summary>PS5 dinlenmedeydi; uyandırma gönderildi.</summary>
    Waking,
    /// <summary>PS5 yanıt verdi; oturum açılıyor.</summary>
    Opening,
}

/// <summary>
/// PS5 bağlantısı 30 sn'den uzun "Bağlanıyor…"da kalınca durum satırının altında nedeni söylenir: PS5 uyandırılıyor, PS5
/// aramaya yanıt vermiyor (açık mı, aynı ağda mı) ya da yanıt verdi ama oturum açılmıyor (core ConnectingHint.swift ve
/// Android ConnectingHint.kt ile aynı kural ve metinler).
/// </summary>
public static class ConnectingHint
{
    /// <summary>Bu süreden sonra neden gösterilir.</summary>
    public static readonly TimeSpan After = TimeSpan.FromSeconds(30);

    /// <summary><paramref name="elapsed"/> süredir bağlanılıyorsa gösterilecek neden; daha kısa sürdüyse null.</summary>
    public static string? Text(TimeSpan elapsed, ConnectStep? step, Localizer text)
    {
        if (elapsed < After) return null;
        return step switch
        {
            ConnectStep.Waking => text["The PS5 is being woken from rest mode. This can take up to a minute."],
            ConnectStep.Opening => text["The PS5 answered, but the connection is taking long. If it doesn't connect, stop and start translating again."],
            _ => text["The PS5 is not answering. Make sure it is on and on the same network as this device."],
        };
    }
}
