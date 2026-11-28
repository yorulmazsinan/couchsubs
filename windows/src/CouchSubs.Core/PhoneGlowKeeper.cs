// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Altyazı hattının kendi telefon takibinde ekran ışığıyla tutma (<see cref="PhoneGlow"/>; izleyiciyle aynı eşikler ve süre).
/// #1443 (beta-108 Mac günlüğü): altyazı hattı telefonu karanlıkta ~1 sn'de bir bırakıyordu ("telefon kalktı" / "telefon
/// bulundu"), bırakınca telefonun mesajları altyazı sayılıp çevriliyordu (#5 "lot so if you're having any this is a", #6).
/// Telefon bulununca ekranın ışığı kaydedilir; ıskada son yerinde ışık tutuyorsa telefon bırakılmaz
/// (<see cref="SubtitlePipeline.HeldPhone"/>). Mac/iPhone (PhoneGlow.swift) ve Android (PhoneGlow.kt) aynı.
/// </summary>
internal sealed class PhoneGlowKeeper
{
    private PhoneGlow.Glow? recorded;
    private long? recordedAt;
    private long seenAt;
    private bool holding;

    /// <summary>
    /// Bu aramanın sonucu: <paramref name="found"/> bulunan telefon (yoksa null), <paramref name="shown"/> süzgecin tuttuğu
    /// telefon; <paramref name="measure"/> karede verilen yerin ışığı. Dönüş: telefon ışığıyla tutuluyor mu ve tutma bu
    /// aramada başladıysa ölçülen ışık (günlük için).
    /// </summary>
    internal (bool Holds, PhoneGlow.Glow? Began) Observe(GamePhoneGeometry.Pose? found, GamePhoneGeometry.Pose? shown, long now,
                                                        Func<GamePhoneGeometry.Pose, PhoneGlow.Glow?> measure)
    {
        if (found is { } seen)
        {
            seenAt = now;
            if (recordedAt is not { } at || now < at || now - at >= GamePhoneTracker.PrintRefreshMs)
            {
                recorded = measure(seen) is { } fresh && PhoneGlow.Lit(fresh) ? fresh : null;
                recordedAt = now;
            }
            holding = false;
            return (false, null);
        }
        if (shown is not { } last)
        {
            Reset();
            return (false, null);
        }
        if (recorded is not { } kept || now < seenAt || now - seenAt >= PhoneGlow.HoldMs
            || measure(last) is not { } current || !PhoneGlow.Holds(kept, current))
        {
            holding = false;
            return (false, null);
        }
        PhoneGlow.Glow? began = holding ? null : current;
        holding = true;
        return (true, began);
    }

    internal void Reset()
    {
        recorded = null;
        recordedAt = null;
        seenAt = 0;
        holding = false;
    }
}
