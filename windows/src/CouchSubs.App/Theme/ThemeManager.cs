// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Media;
using CouchSubs.Core;
using Microsoft.Win32;

namespace CouchSubs.App.Theme;

/// <summary>
/// design/tokens.json'daki değerleri uygulama kaynaklarına çevirir. Renkler Windows'un uygulama
/// temasını (açık/koyu) izler; XAML bunları DynamicResource ile kullanır, tema değişince anında güncellenir.
/// </summary>
public static class ThemeManager
{
    private static readonly DesignTokens Tokens = DesignTokens.Shared;

    public static void Apply(ResourceDictionary resources, bool? forceDark = null)
    {
        var dark = forceDark ?? IsDarkTheme();
        foreach (var (name, pair) in Tokens.Color)
        {
            var color = ToColor(pair.For(dark));
            resources[$"{name}Color"] = color;
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            resources[$"{name}Brush"] = brush;
        }
        foreach (var (name, font) in Tokens.Font)
        {
            resources[$"{name}FontSize"] = font.Size;
            resources[$"{name}FontWeight"] = font.Weight switch
            {
                "bold" => FontWeights.Bold,
                "semibold" => FontWeights.SemiBold,
                "medium" => FontWeights.Medium,
                _ => FontWeights.Normal,
            };
        }
        foreach (var (name, value) in Tokens.Space)
        {
            resources[$"space.{name}"] = value;
            resources[$"pad.{name}"] = new Thickness(value);
        }
        foreach (var (name, value) in Tokens.Radius) resources[$"radius.{name}"] = new CornerRadius(value);
        foreach (var (name, value) in Tokens.Size) resources[$"size.{name}"] = value;
        // Pencere zemini düz renktir (hale, ışık ve degrade yok; docs/TASARIM.md).
        resources["windowBackgroundBrush"] = resources["backgroundBrush"];
    }

    /// <summary>Tema değişince kaynakları yeniler.</summary>
    public static void Follow(ResourceDictionary resources)
    {
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category == UserPreferenceCategory.General)
                Application.Current.Dispatcher.Invoke(() => Apply(resources));
        };
    }

    public static bool IsDarkTheme()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
    }

    private static Color ToColor(string hex)
    {
        var (r, g, b) = DesignTokens.Rgb(hex) ?? (0, 0, 0);
        return Color.FromRgb((byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));
    }
}
