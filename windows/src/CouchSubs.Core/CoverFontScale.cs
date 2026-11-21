// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// "Örtsün" yerleşiminde yazı boyu kararlıdır (Mac: CoverFontScale, TV ve OBS sayfası aynı kuralı uygular). Kullanıcının
/// seçtiği boy kullanılır, kutu çeviriye göre genişler; yazı ancak 3 satıra sığmıyorsa bir kademe küçülür (seçilen boyun
/// %80'i) ve asla büyütülmez. Küçülen boy oturum boyunca (yazı boyu değişene dek) kalır: ardışık satırlarda boy bir büyük
/// bir küçük zıplamasın.
/// </summary>
public sealed class CoverFontScale
{
    /// <summary>Tek kademe: seçilen boyun %80'i. Bundan küçüğe inilmez.</summary>
    public const double Step = 0.8;

    private int? fontSize;

    public bool Shrunk { get; private set; }

    /// <summary>Satırın yazı boyu çarpanı (1 ya da <see cref="Step"/>). Yazı boyu ayarı değişince kademe sıfırlanır.
    /// <paramref name="maxChars"/>: satır başına karakter tabanı (bilgisayar penceresi <see cref="SubtitleWrap.DesktopMaxChars"/>).</summary>
    public double Scale(string text, int fontSize, int maxChars = SubtitleWrap.MaxChars)
    {
        if (this.fontSize != fontSize)
        {
            this.fontSize = fontSize;
            Shrunk = false;
        }
        if (!text.Contains('\n') && SubtitleWrap.FitChars(text, maxChars).Scale < 1) Shrunk = true;
        return Shrunk ? Step : 1;
    }
}
