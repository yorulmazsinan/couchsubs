// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CouchSubs.Core;

namespace CouchSubs.App.Views;

/// <summary>
/// Otomatik bulunan ekran yazısının çevirisi özgün yazının stilinde (bilgisayar ekranındaki pencere ve yayın penceresi):
/// her blok kendi zemin ve yazı renginde, kalın/dar yazı ailesiyle, özgün hizasıyla. Düz zeminde kutu tam opak, değilse
/// %85 opak (yayın penceresinde chroma key bozulmasın diye hep opak).
/// </summary>
internal static class StyledRegionBox
{
    private static readonly FontFamily Condensed = new("Arial Narrow, Segoe UI");
    private static readonly FontFamily Normal = new("Segoe UI");

    /// <summary>Stili bilinen blok yoksa null (eski kutu çizilir).</summary>
    public static Border? Make(IReadOnlyList<ScreenTranslation.Item>? blocks, double size, double scale, bool translucent)
    {
        if (blocks is null || !blocks.Any(block => block.Look is not null)) return null;
        var stack = new StackPanel();
        double middle = 0;
        foreach (var block in blocks)
        {
            var look = block.Look ?? new TextLook(false, false, "left", false, true);
            var surface = block.Style ?? TextStyleSampler.Neutral;
            var background = Parse(surface.Background, look.Flat || !translucent ? (byte)255 : (byte)217);
            middle += (block.Box.Left + block.Box.Right) / 2;
            stack.Children.Add(new Border
            {
                Background = new SolidColorBrush(background),
                CornerRadius = new CornerRadius(look.Flat ? 2 * scale : 6 * scale),
                Padding = new Thickness(10 * scale, 0.15 * size, 10 * scale, 0.15 * size),
                Margin = new Thickness(0, 0, 0, 4 * scale),
                HorizontalAlignment = look.Align switch { "center" => HorizontalAlignment.Center, "right" => HorizontalAlignment.Right, _ => HorizontalAlignment.Left },
                Child = new TextBlock
                {
                    Text = block.Translation,
                    FontSize = size,
                    FontFamily = look.Condensed ? Condensed : Normal,
                    FontWeight = look.Bold ? FontWeights.Bold : FontWeights.Normal,
                    Foreground = new SolidColorBrush(Parse(surface.Foreground, 255)),
                    TextWrapping = TextWrapping.Wrap,
                    TextAlignment = look.Align switch { "center" => TextAlignment.Center, "right" => TextAlignment.Right, _ => TextAlignment.Left },
                    LineHeight = size * 1.2,
                },
            });
        }
        middle /= blocks.Count;
        return new Border
        {
            Margin = new Thickness(0, 0, 0, 10 * scale),
            HorizontalAlignment = middle < 0.4 ? HorizontalAlignment.Left : middle > 0.6 ? HorizontalAlignment.Right : HorizontalAlignment.Center,
            Child = stack,
        };
    }

    /// <summary>Stili bilinmeyen ek alan çevirisi, altyazıdan ayrık: zeminsiz, beyaz, koyu gölgeli yazı.</summary>
    public static Border? Plain(string text, double size, double scale, CouchSubs.Core.TextBox? area)
    {
        if (text.Length == 0) return null;
        var middle = area is { } box ? (box.Left + box.Right) / 2 : 0.5;
        return new Border
        {
            Margin = new Thickness(0, 0, 0, 10 * scale),
            Padding = new Thickness(4 * scale, 0, 4 * scale, 0),
            HorizontalAlignment = middle < 0.4 ? HorizontalAlignment.Left : middle > 0.6 ? HorizontalAlignment.Right : HorizontalAlignment.Center,
            Child = new TextBlock
            {
                Text = text,
                FontSize = size,
                FontFamily = Normal,
                FontWeight = FontWeights.SemiBold,
                Foreground = Brushes.White,
                TextWrapping = TextWrapping.Wrap,
                LineHeight = size * 1.25,
                Effect = new System.Windows.Media.Effects.DropShadowEffect
                {
                    Color = Colors.Black, ShadowDepth = 0, BlurRadius = 6 * scale, Opacity = 1,
                },
            },
        };
    }

    private static Color Parse(string hex, byte alpha) => hex is { Length: 7 } && hex[0] == '#'
        ? Color.FromArgb(alpha, Convert.ToByte(hex.Substring(1, 2), 16), Convert.ToByte(hex.Substring(3, 2), 16), Convert.ToByte(hex.Substring(5, 2), 16))
        : Color.FromArgb(alpha, 0, 0, 0);
}
