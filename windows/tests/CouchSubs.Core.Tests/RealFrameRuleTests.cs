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
    [InlineData("R3 LOOK BEHIND", "R3 ARKANA BAK")] // "LOOK BEHIND" etiket sözlüğünde (#1362); baştaki tuş adı kalır
    [InlineData("R3 ZOOM", "R3 YAKINLAŞTIR")]
    [InlineData("EXIT OR", "ÇIK OR")]
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
        // Mavi haritada beyaz simge: kenarındaki mavimsi karışım renkli sayılmaz.
        for (var y = 0; y < 40; y++)
            for (var x = 0; x < 40; x++)
            {
                var p = y * frame.Stride + x * 4;
                var ring = Math.Abs(Math.Sqrt((x - 20) * (x - 20) + (y - 20) * (y - 20)) - 12);
                var mix = ring < 2 ? 1.0 : ring < 4 ? 0.5 : 0.0;
                (frame.Pixels[p], frame.Pixels[p + 1], frame.Pixels[p + 2], frame.Pixels[p + 3]) =
                    ((byte)(240 + (255 - 240) * mix), (byte)(116 + (255 - 116) * mix), (byte)(10 + (255 - 10) * mix), (byte)255);
            }
        Assert.True(ButtonIcons.IsColourless(frame, new TextBox(0, 0, 1, 1)));
        // GTA 6 haritasının açık mavi denizinde beyaz ✕ simgesi: deniz noktaları renkli sayılıp simge tanınmıyor, "SET
        // DESTINATION ✕" çevirisi simgeyi örtüyordu (Mac ve Android ile aynı durum).
        for (var y = 0; y < 40; y++)
            for (var x = 0; x < 40; x++)
            {
                var p = y * frame.Stride + x * 4;
                var ring = Math.Abs(Math.Sqrt((x - 20) * (x - 20) + (y - 20) * (y - 20)) - 12);
                (frame.Pixels[p], frame.Pixels[p + 1], frame.Pixels[p + 2], frame.Pixels[p + 3]) =
                    ring < 2 ? ((byte)255, (byte)255, (byte)255, (byte)255) : ((byte)0xBB, (byte)0x94, (byte)0x3A, (byte)255);
            }
        Assert.True(ButtonIcons.IsColourless(frame, new TextBox(0, 0, 1, 1)));
    }
}
