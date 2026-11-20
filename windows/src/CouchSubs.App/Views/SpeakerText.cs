// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using CouchSubs.Core;

namespace CouchSubs.App.Views;

/// <summary>
/// Konuşana göre renkli altyazı (bilgisayar ekranındaki pencere ve yayın penceresi): "Mattia: …" satırı o konuşanın
/// renginde yazılır (<see cref="SpeakerColors"/>; TV'deki ile aynı renk). Ad yoksa ya da ayar kapalıysa düz metin.
/// </summary>
internal static class SpeakerText
{
    /// <param name="shown">Ekrana yazılacak (sarılmış) metin.</param>
    /// <param name="source">Satırın özgün metni; konuşan adları buradan çıkarılır.</param>
    /// <param name="alpha">Renkli parçaların saydamlığı (yayın penceresinde soluk üst satırlar için).</param>
    public static void Fill(TextBlock block, string shown, string source, bool enabled, byte alpha = 255)
    {
        var names = enabled ? SpeakerColors.Speakers(source) : [];
        if (names.Count == 0)
        {
            block.Text = shown;
            return;
        }
        block.Inlines.Clear();
        foreach (var segment in SpeakerColors.Segments(shown, names))
        {
            var brush = segment.Color is { } hex ? new SolidColorBrush(Parse(hex, alpha)) : null;
            var parts = segment.Text.Split('\n');
            for (var index = 0; index < parts.Length; index++)
            {
                if (index > 0) block.Inlines.Add(new LineBreak());
                if (parts[index].Length == 0) continue;
                var run = new Run(parts[index]);
                if (brush is not null) run.Foreground = brush;
                block.Inlines.Add(run);
            }
        }
    }

    private static Color Parse(string hex, byte alpha) => Color.FromArgb(alpha,
        Convert.ToByte(hex.Substring(1, 2), 16), Convert.ToByte(hex.Substring(3, 2), 16), Convert.ToByte(hex.Substring(5, 2), 16));
}
