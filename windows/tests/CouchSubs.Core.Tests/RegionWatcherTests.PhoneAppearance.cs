// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

public partial class RegionWatcherTests
{
    [Fact]
    public void FailedPhoneSampleKeepsTheLastSampledBubbleColor()
    {
        var box = new TextBox(.3, .7, .9, .75);
        var before = new ScreenTranslation.Item("You still have that jumpsuit?", "Tulum hâlâ sende mi?", box, .025)
        {
            Phone = new ScreenPhoneCard.Placement(ScreenPhoneCard.Role.Outgoing, box),
            Style = new PhoneTextStyle("#3058D0", "#FFFFFF"),
        };
        foreach (var failed in new[] { null, GamePhonePalette.Neutral })
        {
            var next = before with { Style = failed };
            var item = Assert.Single(RegionWatcher.StablePhoneBlocks([next], [before]));
            Assert.Equal(before.Style, item.Style);
        }
    }

    [Fact]
    public async Task StablePhoneBubbleKeepsAppearanceWhenOtherBubblesArriveAndTracksRealZoom()
    {
        using var lifetime = new CancellationTokenSource();
        var phone = Phone with { Region = new CropRegion(.1, .9, 0, 1), PanelLifetime = lifetime.Token };
        var reader = new Reader { Lines = [Line("Call me.", .2, .05)] };
        var server = new Server();
        var watcher = new RegionWatcher(reader, new Translator(), server);
        await watcher.PassAsync(Shade(64), [phone]);
        var first = Assert.Single(server.Blocks[^1]!);

        // Aynı mesaj ekranda hareket ediyor; komşu balon geldikçe alanın anahtarı değişiyor.
        reader.Lines = [Line("Call me.", .23, .054), Line("Meet outside.", .74, .05)];
        var noisy = Shade(80);
        Array.Fill(noisy.Pixels, (byte)200, 18 * noisy.Stride, 4);
        await watcher.PassAsync(noisy, [phone]);
        await watcher.PassAsync(noisy, [phone]);
        var moved = Assert.Single(server.Blocks[^1]!, x => x.Source == "Call me.");
        Assert.Equal(first.LineHeight, moved.LineHeight);
        Assert.Equal(first.Style, moved.Style);
        Assert.True(moved.Box.Top > first.Box.Top + .01);
        Assert.Equal(first.Box.Bottom - first.Box.Top, moved.Box.Bottom - moved.Box.Top, 6);

        // Yalnız %5 gerçek yakınlaşma da önemsiz OCR farkıyla karışmamalı.
        await watcher.PassAsync(Shade(192), [phone with { Region = new CropRegion(.08, .92, 0, 1) }]);
        var zoomed = Assert.Single(server.Blocks[^1]!, x => x.Source == "Call me.");
        Assert.NotEqual(moved.LineHeight, zoomed.LineHeight);
        Assert.NotEqual(moved.Style, zoomed.Style);
    }

    [Fact]
    public void SelectionKeepsReadableContrastWhenOnlyTheSurfaceColorLooksStable()
    {
        var before = new ScreenTranslation.Item("Call me.", "Beni ara.", new TextBox(.1, .2, .4, .28), .06)
            { Style = new PhoneTextStyle("#686868", "#FFFFFF") };
        var selected = before with { Style = new PhoneTextStyle("#787878", "#000000") };
        var item = Assert.Single(RegionWatcher.StablePhoneBlocks([selected], [before]));
        Assert.Equal(selected.Style, item.Style);
    }

    [Fact]
    public void PhoneAppearanceFollowsNewSourceTranslationWidthAndSelectionColor()
    {
        var first = new ScreenTranslation.Item("Meet May.", "May ile buluş.", new TextBox(.1,.2,.4,.28), .06)
            { Style = new PhoneTextStyle("#B8C0D0", "#000000") };
        var jiggled = first with { Box = new TextBox(.11,.21,.42,.296), LineHeight = .064,
                                   Style = new PhoneTextStyle("#B0B8C8", "#000000") };
        var steady = Assert.Single(RegionWatcher.StablePhoneBlocks([jiggled], [first]));
        Assert.Equal(jiggled.Box.Left, steady.Box.Left);
        Assert.Equal(first.Box.Right - first.Box.Left, steady.Box.Right - steady.Box.Left, 6);
        Assert.Equal(first.Style, steady.Style);
        var selection = jiggled with { Style = new PhoneTextStyle("#B0B8C8","#FFFFFF"), Box = jiggled.Box with { Right = .49 } };
        var selected = Assert.Single(RegionWatcher.StablePhoneBlocks([selection], [steady]));
        Assert.Equal("#FFFFFF", selected.Style!.Foreground);
        Assert.Equal(selection.Box.Right, selected.Box.Right);
        foreach (var replaced in new[] { jiggled with { Source = "Meet Chase." },
                                         jiggled with { Translation = "May’i gör." } })
            Assert.Equal(replaced, Assert.Single(RegionWatcher.StablePhoneBlocks([replaced], [first])));
    }
}
