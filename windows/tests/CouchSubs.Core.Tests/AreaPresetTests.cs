// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Altyazı alanının hazır seçimleri ve Özel bölgenin kaydırıcıları (Mac: AreaPresetTests).</summary>
public class AreaPresetTests
{
    [Fact]
    public void PresetRegions()
    {
        Assert.Equal(new CropRegion(), AreaPreset.Bottom.Region());
        Assert.Equal(new CropRegion(0.03, 0.38, 0.14, 0.86), AreaPreset.Top.Region());
        Assert.Equal(new CropRegion(0, 1, 0, 1), AreaPreset.Full.Region());
        Assert.Null(AreaPreset.Custom.Region());
    }

    [Fact]
    public void MatchingFindsThePresetWithinTolerance()
    {
        Assert.Equal(AreaPreset.Bottom, AreaPresets.Matching(new CropRegion()));
        Assert.Equal(AreaPreset.Top, AreaPresets.Matching(new CropRegion(0.0305, 0.3795, 0.14, 0.86)));
        Assert.Equal(AreaPreset.Full, AreaPresets.Matching(new CropRegion(0, 1, 0, 1)));
        Assert.Equal(AreaPreset.Custom, AreaPresets.Matching(new CropRegion(0.62, 0.97, 0.14, 0.87)));
        Assert.Equal(AreaPreset.Custom, AreaPresets.Matching(new CropRegion(0.5, 0.9, 0.1, 0.9)));
    }

    [Fact]
    public void VerticalPercentIsTopAndHeight()
    {
        var (position, height) = new CropRegion(0.6, 0.9, 0.1, 0.9).VerticalPercent();
        Assert.Equal(60, position, 6);
        Assert.Equal(30, height, 6);
    }

    [Fact]
    public void WithVerticalKeepsLeftAndRight()
    {
        var region = new CropRegion(0.62, 0.97, 0.2, 0.8).WithVertical(40, 25);
        Assert.Equal(0.4, region.Top, 6);
        Assert.Equal(0.65, region.Bottom, 6);
        Assert.Equal(0.2, region.Left);
        Assert.Equal(0.8, region.Right);
    }

    [Fact]
    public void WithVerticalClampsHeightAndStaysInsideTheFrame()
    {
        var thin = new CropRegion().WithVertical(50, 1);
        Assert.Equal(0.05, thin.Bottom - thin.Top, 6);
        var tall = new CropRegion().WithVertical(10, 150);
        Assert.Equal(0, tall.Top, 6);
        Assert.Equal(1, tall.Bottom, 6);
        // Aşağı taşan bölge yukarı kayar.
        var low = new CropRegion().WithVertical(90, 30);
        Assert.Equal(0.7, low.Top, 6);
        Assert.Equal(1, low.Bottom, 6);
        var above = new CropRegion().WithVertical(-20, 30);
        Assert.Equal(0, above.Top, 6);
        Assert.Equal(0.3, above.Bottom, 6);
    }
}
