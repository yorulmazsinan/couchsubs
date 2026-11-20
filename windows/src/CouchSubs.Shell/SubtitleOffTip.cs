// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell;

/// <summary>
/// "Oyunun kendi altyazısını açın" ipucu ne zaman görünür (Mac/iPhone: CouchSubsCore SubtitleOffTip, Android:
/// SubtitleOffTip.kt ile aynı kural).
///
/// En sık şikâyet "çeviri gelmiyor, yalnız test yazısı çıkıyor" (GitHub #503, #554, #566, #572): görüntü geliyor ama oyunda
/// altyazı kapalı ya da altyazı alanında hiç satır yok. CouchSubs sesi değil, ekrandaki altyazıyı okur. Görüntü
/// <see cref="After"/> boyunca geldiği hâlde bu çeviride tek satır okunup gösterilmediyse ipucu görünür; ilk satırda kalkar.
/// Görüntü hiç gelmiyorsa görünmez (o zaman sorun altyazı değil, bağlantıdır ve ayrı söylenir).
/// </summary>
public static class SubtitleOffTip
{
    public static readonly TimeSpan After = TimeSpan.FromSeconds(60);

    /// <param name="streaming">Görüntü kaynağı şu an bağlı.</param>
    /// <param name="sawLine">Bu çeviride en az bir altyazı satırı gösterildi.</param>
    /// <param name="framesFor">Görüntünün kesintisiz ne zamandır geldiği (hiç gelmediyse null).</param>
    public static bool IsVisible(bool streaming, bool sawLine, TimeSpan? framesFor) =>
        streaming && !sawLine && framesFor is { } duration && duration >= After;
}
