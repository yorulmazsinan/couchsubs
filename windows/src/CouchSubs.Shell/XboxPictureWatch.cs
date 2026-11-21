// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell;

/// <summary>Görüntü bekçisinin bir saat adımındaki kararı.</summary>
public enum XboxPictureVerdictKind { Fine, Warn, Recovered, Stalled }

/// <summary>Kararın türü ve (yalnız <see cref="XboxPictureVerdictKind.Stalled"/>'da) günlükteki neden.</summary>
public readonly record struct XboxPictureVerdict(XboxPictureVerdictKind Kind, string? Reason = null)
{
    public static readonly XboxPictureVerdict Fine = new(XboxPictureVerdictKind.Fine);
    public static readonly XboxPictureVerdict Warn = new(XboxPictureVerdictKind.Warn);
    public static readonly XboxPictureVerdict Recovered = new(XboxPictureVerdictKind.Recovered);
    public static XboxPictureVerdict Stalled(string reason) => new(XboxPictureVerdictKind.Stalled, reason);
}

/// <summary>
/// İlk kareden sonra Xbox görüntüsünün kesilip kesilmediği (PS5'teki PictureWatchdog'un Xbox karşılığı). Eskiden yayın
/// yalnız WebRTC bağlantısı <c>failed</c>/<c>closed</c> olunca ya da canlı tutma üç kez yanıtsız kalınca bitiyordu;
/// <c>disconnected</c> yalnız günlüğe yazılıyor, oynatıcı donmuş video öğesini okumaya göndermeyi sürdürüyordu: ana
/// ekran "bağlı" diyor, altyazı donuyor ve bir daha gelmiyordu (X'te kullanıcı bildirimi, iPhone + Xbox Series S).
/// Kare <see cref="WarnAfterMs"/> gelmezse (bağlantı <c>disconnected</c> iken 1 sn) uyarı gösterilir;
/// <see cref="StallAfterMs"/> gelmezse ya da bağlantı <c>failed</c> olursa oturum kapatılıp 5, 15, 45 sn aralıklarla
/// yeniden kurulur. CouchSubsCore XboxPictureWatch (iPhone, Mac) ve Android'deki XboxPictureWatch ile birebir.
/// </summary>
public sealed class XboxPictureWatch
{
    public const long WarnAfterMs = 5000;
    public const long StallAfterMs = 12_000;
    /// <summary>Bağlantı <c>disconnected</c> iken uyarı için yeterli boşluk (bağlantı takılınca kareler hemen kesilir).</summary>
    public const long IceWarnAfterMs = 1000;

    /// <summary>ICE/WebRTC bağlantı durumunun bekçiyi ilgilendiren kısmı.</summary>
    public enum Ice { Connected, Disconnected, Failed, Other }

    private long? lastFrameMs;
    private long? iceLostSinceMs;
    private bool iceFailed;

    /// <summary>Uyarı gösteriliyor.</summary>
    public bool Warned { get; private set; }

    public void FrameArrived(long atMs) => lastFrameMs = atMs;

    public void IceChanged(Ice state, long atMs)
    {
        switch (state)
        {
            case Ice.Connected: iceLostSinceMs = null; break;
            case Ice.Disconnected: iceLostSinceMs ??= atMs; break;
            case Ice.Failed: iceFailed = true; break;
        }
    }

    /// <summary>Oynatıcının bağlantı durumu metni (RTCPeerConnection connectionState / iceConnectionState).</summary>
    public static Ice IceFrom(string? state) => state switch
    {
        "connected" or "completed" => Ice.Connected,
        "disconnected" => Ice.Disconnected,
        "failed" => Ice.Failed,
        _ => Ice.Other,
    };

    /// <summary>Saniyede bir çağrılır. İlk kare gelmeden karar verilmez (ilk kare sınırı ayrı).</summary>
    public XboxPictureVerdict Tick(long atMs)
    {
        if (lastFrameMs is not { } last) return XboxPictureVerdict.Fine;
        var iceLost = iceLostSinceMs is not null;
        if (iceFailed) return XboxPictureVerdict.Stalled("Xbox ICE bağlantısı koptu (failed)");
        var gap = atMs - last;
        if (gap >= StallAfterMs)
            return XboxPictureVerdict.Stalled($"Xbox'tan {gap / 1000} sn'dir görüntü gelmiyor ({(iceLost ? "ICE disconnected" : "bağlantı açık görünüyor")})");
        var trouble = gap >= WarnAfterMs || (iceLost && gap >= IceWarnAfterMs);
        if (trouble && !Warned)
        {
            Warned = true;
            return XboxPictureVerdict.Warn;
        }
        if (!trouble && Warned)
        {
            Warned = false;
            return XboxPictureVerdict.Recovered;
        }
        return XboxPictureVerdict.Fine;
    }
}
