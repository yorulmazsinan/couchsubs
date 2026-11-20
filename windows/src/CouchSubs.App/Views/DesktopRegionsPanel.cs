// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using RegionBox = CouchSubs.Core.TextBox;

namespace CouchSubs.App.Views;

/// <summary>Dar masaüstü pencerelerinde telefon metni yalnız HUD ile konuşma arasında kalan yere çizilir.</summary>
internal sealed class DesktopRegionsPanel : DockPanel
{
    private readonly StackPanel hud = new() { VerticalAlignment = VerticalAlignment.Top };
    private readonly Border phone = new() { ClipToBounds = true };

    public DesktopRegionsPanel(StackPanel subtitles, double bottomInset = 0)
    {
        IsHitTestVisible = false;
        // Normal ek alanlar önceki gibi üstte dizilir. Konuşmanın zemini tamamen saydam olsa da
        // alttaki harflerin arkasında telefon harfleri kalmaması için satırların gerçek boyunu ayır.
        SetDock(hud, Dock.Top);
        Children.Add(hud);
        var reserved = new Border { Margin = new Thickness(0, 0, 0, bottomInset) };
        reserved.SetBinding(HeightProperty, new Binding(nameof(ActualHeight)) { Source = subtitles });
        SetDock(reserved, Dock.Bottom);
        Children.Add(reserved);
        Children.Add(phone);
    }

    public void ShowRegions(Dictionary<string, (string Text, RegionBox? Box, IReadOnlyList<CouchSubs.Core.ScreenTranslation.Item>? Blocks)> regions,
                            Func<string, RegionBox?, IReadOnlyList<CouchSubs.Core.ScreenTranslation.Item>?, Border> makeBox)
    {
        hud.Children.Clear();
        phone.Child = null;
        foreach (var (id, region) in regions.OrderBy(pair => pair.Value.Box?.Top ?? 0))
        {
            var box = makeBox(region.Text, region.Box, region.Blocks);
            if (id == "game-phone")
            {
                box.VerticalAlignment = VerticalAlignment.Top;
                phone.Child = box;
            }
            else hud.Children.Add(box);
        }
    }
}
