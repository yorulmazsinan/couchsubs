// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CouchSubs.Core;

/// <summary>
/// design/tokens.json: renkler, yazı boyutları, boşluklar, köşeler (parıltı yok). Mac uygulaması da aynı dosyayı kullanır;
/// bir değeri değiştirmek için yalnız o dosya düzenlenir.
/// </summary>
public sealed class DesignTokens
{
    public sealed record ColorPair(string Light, string Dark)
    {
        public string For(bool dark) => dark ? Dark : Light;
    }

    public sealed record FontToken(double Size, string Weight);

    public required string Name { get; init; }
    public required Dictionary<string, ColorPair> Color { get; init; }
    public required Dictionary<string, FontToken> Font { get; init; }
    public required Dictionary<string, double> Space { get; init; }
    public required Dictionary<string, double> Radius { get; init; }
    public required Dictionary<string, double> Size { get; init; }

    public static DesignTokens Shared { get; } = Load();

    private static DesignTokens Load()
    {
        using var stream = typeof(DesignTokens).Assembly.GetManifestResourceStream("tokens.json")
            ?? throw new InvalidOperationException("tokens.json uygulamaya gömülmemiş");
        var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true, UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip };
        return JsonSerializer.Deserialize<DesignTokens>(stream, options) ?? throw new InvalidOperationException("tokens.json bozuk");
    }

    /// <summary>"#RRGGBB" → 0–1 aralığında kırmızı, yeşil, mavi.</summary>
    public static (double R, double G, double B)? Rgb(string hex)
    {
        if (hex.Length != 7 || hex[0] != '#' || !uint.TryParse(hex.AsSpan(1), NumberStyles.HexNumber, null, out var value)) return null;
        return (((value >> 16) & 0xFF) / 255.0, ((value >> 8) & 0xFF) / 255.0, (value & 0xFF) / 255.0);
    }

    /// <summary>WCAG 2 kontrast oranı (1–21).</summary>
    public static double Contrast(string a, string b)
    {
        static double Luminance(string hex)
        {
            var (r, g, b) = Rgb(hex) ?? (0, 0, 0);
            static double Linear(double c) => c <= 0.03928 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
            return (0.2126 * Linear(r)) + (0.7152 * Linear(g)) + (0.0722 * Linear(b));
        }
        var (x, y) = (Luminance(a), Luminance(b));
        return (Math.Max(x, y) + 0.05) / (Math.Min(x, y) + 0.05);
    }
}
