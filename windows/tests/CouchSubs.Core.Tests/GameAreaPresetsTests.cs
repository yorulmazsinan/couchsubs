// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Mac GameAreaPresetsTests ve Android GameAreaPresetsTest ile aynı tablo.</summary>
public class GameAreaPresetsTests
{
    [Theory]
    [InlineData("Grand Theft Auto VI")]
    [InlineData("GTA 6")]
    public void Gta6HasHelpAndMessageAreas(string game) =>
        Assert.Equal(["preset-help", "preset-phone"], GameAreaPresets.Areas(game).Select(area => area.Id));

    [Theory]
    [InlineData("Red Dead Redemption 2")]
    [InlineData(null)]
    [InlineData("")]
    public void OtherGamesHaveNone(string? game) => Assert.Empty(GameAreaPresets.Areas(game));

    [Fact]
    public void Gta6RegionsMatchTheSharedTable()
    {
        var areas = GameAreaPresets.Areas("GTA 6");
        Assert.Equal(new CropRegion(0.02, 0.28, 0.01, 0.36), areas[0].Region);
        Assert.Equal(new CropRegion(0.45, 0.80, 0.72, 0.99), areas[1].Region);
        Assert.All(areas, area => Assert.False(area.Auto));
    }
}
