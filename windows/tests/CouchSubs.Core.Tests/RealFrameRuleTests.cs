// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Gerçek kare doğrulamasında çıkan kusurların kuralları (GTA 6 yayın kareleri; kareler depoda değil).</summary>
public class RealFrameRuleTests
{
    [Theory]
    [InlineData("GEN.TR", true)]
    [InlineData("REPUBLIC OF", true)]
    [InlineData("GAMERS", true)]
    [InlineData("• Canli", true)]
    [InlineData("twitch.tv", true)]
    [InlineData("ROB VICKI'S BOSS", false)]
    [InlineData("Meet her at Delights.", false)]
    public void StreamOverlayTextIsNotGameText(string line, bool overlay) => Assert.Equal(overlay, ScreenTextNoise.IsOverlay(line));

    [Theory]
    [InlineData("1 Мар", "Harita")]        // Kiril М/а/р ve simgenin "1" diye okunuşu
    [InlineData("pi Settings", "Ayarlar")]
    [InlineData("R3 LOOK BEHIND", null)]
    [InlineData("R3 ZOOM", "R3 YAKINLAŞTIR")]
    [InlineData("EXIT OR", "ÇIKIŞ OR")]
    [InlineData("ADD MARKER O", "İŞARET EKLE O")]
    public void LabelsAreFoundDespiteOcrCrumbs(string label, string? turkish) =>
        Assert.Equal(turkish, UiCommands.TranslateLabelLoosely(label));

    [Fact]
    public void LabelsSeparatedByIconsAreTranslatedPieceByPiece() =>
        Assert.Equal($"ORTALA {ButtonIcons.Marker}", UiCommands.TranslateLabelLoosely($"RECENTER {ButtonIcons.Marker}"));

    [Fact]
    public void CutOffWordAtTheAreaEdgeAndOverlayLinesAreDropped()
    {
        var reading = new Reading(
        [
            new TextLine("KELI", new TextBox(0, 0.1, 0.12, 0.2)),
            new TextLine("ROB VICKI'S BOSS", new TextBox(0.2, 0.1, 0.6, 0.2)),
            new TextLine("GEN.TR", new TextBox(0.2, 0.5, 0.4, 0.6)),
        ]);
        var candidate = RegionWatcher.MakeCandidate(reading, new CropRegion(0.1, 0.5, 0.05, 0.6), auto: true);
        Assert.Equal(["ROB VICKI'S BOSS"], candidate.Paragraphs);
    }

    [Fact]
    public void ColourfulPortraitIsNotAButtonIcon()
    {
        var frame = Frame.Blank(40, 40);
        for (var p = 0; p < frame.Pixels.Length; p += 4)
        {
            frame.Pixels[p] = 200; frame.Pixels[p + 1] = 80; frame.Pixels[p + 2] = 240; frame.Pixels[p + 3] = 255;
        }
        Assert.False(ButtonIcons.IsColourless(frame, new TextBox(0, 0, 1, 1)));
        Array.Fill(frame.Pixels, (byte)230);
        Assert.True(ButtonIcons.IsColourless(frame, new TextBox(0, 0, 1, 1)));
    }
}
