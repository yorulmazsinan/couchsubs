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
    /// <summary>Telefon mesajlarının kendi balonlarının yerinde çizildiği katman (Mac GamePhoneBlocks).</summary>
    private readonly PhoneBlocksCanvas phoneBlocks;

    /// <param name="phoneLayer">
    /// Verilirse telefon mesajları bu katmanda (yayın penceresi: pencerenin tamamı oyun karesidir); verilmezse saydam
    /// pencerede HUD ile konuşma arasındaki alanda, karedeki yerlerine göre (Mac SubtitleOverlay ile aynı).
    /// </param>
    public DesktopRegionsPanel(StackPanel subtitles, double bottomInset = 0, PhoneBlocksCanvas? phoneLayer = null)
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
        phoneBlocks = phoneLayer ?? new PhoneBlocksCanvas();
        if (phoneLayer is null) phone.Child = phoneBlocks;
    }

    public void ShowRegions(Dictionary<string, (string Text, RegionBox? Box, IReadOnlyList<CouchSubs.Core.ScreenTranslation.Item>? Blocks)> regions,
                            Func<string, RegionBox?, IReadOnlyList<CouchSubs.Core.ScreenTranslation.Item>?, Border> makeBox)
    {
        hud.Children.Clear();
        IReadOnlyList<CouchSubs.Core.ScreenTranslation.Item>? messages = null;
        // "Ekranı çevir" ekrandayken onun yerindeki otomatik ekran yazısı blokları çizilmez (#827).
        foreach (var (id, region) in CouchSubs.Core.ScreenRegions.Visible(regions).OrderBy(pair => pair.Value.Box?.Top ?? 0))
        {
            // Telefonun her mesajı kendi balonunun yerinde ve renginde (TV, Mac, iPhone, Android ile aynı). Eskiden bloklar
            // tek kutuda alt alta dizilip ortaya/sola yaslanıyordu: kimin ne yazdığı belli olmuyordu.
            if (id == "game-phone" && region.Blocks is { Count: > 0 } blocks)
            {
                messages = blocks;
                continue;
            }
            hud.Children.Add(makeBox(region.Text, region.Box, region.Blocks));
        }
        phoneBlocks.Show(messages);
    }
}
