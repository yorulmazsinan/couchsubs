// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Windows;
using System.Windows.Markup;

namespace CouchSubs.App.Theme;

/// <summary>
/// Boşluk belirteci (Mac'teki <c>DS.space("…")</c> karşılığı). Tek kaynak <c>design/yeni-arayuz/tasarim.json › space</c>.
/// Ekran dosyalarında ham sayıyla boşluk yazılmaz (SpacingLintTests): <c>Margin="{t:Sp '0,unitTitle,0,0'}"</c>,
/// <c>Padding="{t:Sp 'm,0'}"</c>, <c>Width="{t:Sp m}"</c>. Parçalar belirteç adı ya da 0'dır; önüne "-" konursa eksi.
/// Bir, iki ya da dört parça (WPF Thickness sırası: sol, üst, sağ, alt). Hedef double ise tek parça beklenir.
/// </summary>
[MarkupExtensionReturnType(typeof(object))]
public sealed class Sp(string value) : MarkupExtension
{
    public string Value { get; } = value;

    public override object ProvideValue(IServiceProvider serviceProvider)
    {
        var target = (serviceProvider.GetService(typeof(IProvideValueTarget)) as IProvideValueTarget)?.TargetProperty;
        var type = target switch
        {
            DependencyProperty property => property.PropertyType,
            System.Reflection.PropertyInfo info => info.PropertyType,
            _ => typeof(Thickness),
        };
        if (type == typeof(double)) return V(Value);
        if (type == typeof(GridLength)) return new GridLength(V(Value));
        return T(Value);
    }

    /// <summary>Tek belirtecin değeri ("m" → 16, "-xs" → -8, "0" → 0).</summary>
    public static double V(string name)
    {
        var text = name.Trim();
        var sign = 1.0;
        if (text.StartsWith('-'))
        {
            sign = -1;
            text = text[1..];
        }
        if (text == "0") return 0;
        if (Palette.Space.TryGetValue(text, out var value)) return sign * value;
        throw new ArgumentException($"Bilinmeyen boşluk belirteci: {name} (tasarim.json › space)");
    }

    /// <summary>"m" / "m,0" / "0,unitTitle,0,0" → Thickness.</summary>
    public static Thickness T(string value)
    {
        var parts = value.Split(',', StringSplitOptions.TrimEntries);
        return parts.Length switch
        {
            1 => new Thickness(V(parts[0])),
            2 => new Thickness(V(parts[0]), V(parts[1]), V(parts[0]), V(parts[1])),
            4 => new Thickness(V(parts[0]), V(parts[1]), V(parts[2]), V(parts[3])),
            _ => throw new ArgumentException($"Boşluk belirteci bir, iki ya da dört parça olmalı: {value}"),
        };
    }

    /// <summary>Kodda: <c>Sp.T("0", "unitTitle", "0", "0")</c>.</summary>
    public static Thickness T(string left, string top, string right, string bottom) => new(V(left), V(top), V(right), V(bottom));

    public override string ToString() => Value.ToString(CultureInfo.InvariantCulture);
}
