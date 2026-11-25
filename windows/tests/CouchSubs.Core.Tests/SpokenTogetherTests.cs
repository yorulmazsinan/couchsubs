// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Kalabalık sahnede aynı anda konuşan kişilerin alt alta duran ayrı blokları tek altyazıda, her biri kendi satırında ve
/// adıyla birleşir (X, beta.100). Ortalı, eşit aralıklı üç konuşma satırı menü listesi sayılmaz. Mac/iPhone
/// (SpokenTogetherTests) ve Android (SpokenTogetherTest) aynı vakalar.
/// </summary>
public class SpokenTogetherTests
{
    private static readonly TextBox Area = new(0, 0, 1, 1);

    private static TextLine Line(string text, double top, double height = 0.04)
    {
        var half = text.Length * 0.0065;
        return new(text, new TextBox(0.5 - half, top, 0.5 + half, top + height));
    }

    private static TextLine Left(string text, double top, double height = 0.04) =>
        new(text, new TextBox(0.1, top, 0.1 + (text.Length * 0.012), top + height));

    [Fact]
    public void TwoSpeakersAtOnceAreJoinedInOrder()
    {
        var reading = new Reading([Line("Vendor: You want the usual today?", 0.74), Line("Driver: Move your cart, man.", 0.82)]);
        var block = reading.SubtitleBlock(Area);
        Assert.Equal("Vendor: You want the usual today?\nDriver: Move your cart, man.", block.Text);
        Assert.Equal(0.74, block.Box!.Value.Top, 9);
        Assert.Equal(0.86, block.Box!.Value.Bottom, 9);
    }

    [Fact]
    public void ThreeEvenlySpacedSpeakersAreJoinedNotAMenuList()
    {
        var reading = new Reading([
            Line("Tourist: Which way to the beach?", 0.66),
            Line("Guard: Keep walking.", 0.74),
            Line("Kid: Look at that car over there!", 0.82),
        ]);
        Assert.False(reading.IsHistoryList);
        Assert.Equal("Tourist: Which way to the beach?\nGuard: Keep walking.\nKid: Look at that car over there!",
            reading.SubtitleBlock(Area).Text);
    }

    [Fact]
    public void WrappedSpeechStaysWithItsSpeaker()
    {
        var reading = new Reading([
            Line("Tourist: Excuse me, which way is", 0.62),
            Line("the beach from here?", 0.665),
            Line("Guard: Keep walking.", 0.74),
        ]);
        Assert.Equal("Tourist: Excuse me, which way is\nthe beach from here?\nGuard: Keep walking.", reading.SubtitleBlock(Area).Text);
    }

    [Fact]
    public void LeftAlignedHistoryListIsStillAList()
    {
        var reading = new Reading([
            Left("Staff: Hi there.", 0.3),
            Left("Customer: One coffee, please.", 0.38),
            Left("Staff: Coming right up.", 0.46),
        ]);
        Assert.True(reading.IsHistoryList);
        Assert.Empty(reading.SubtitleBlock(Area).Lines);
    }

    [Fact]
    public void FarApartSpeakerIsNotJoined()
    {
        var reading = new Reading([Line("Vendor: Fresh fruit!", 0.5), Line("Driver: Move it.", 0.82)]);
        Assert.Equal("Vendor: Fresh fruit!", reading.SubtitleBlock(Area).Text);
    }

    [Fact]
    public void ObjectiveBetweenSpeakersStopsTheJoin()
    {
        var reading = new Reading([
            Line("Vendor: You want the usual today?", 0.66),
            Line("Go to the market.", 0.735, 0.02),
            Line("Driver: Move your cart, man.", 0.8),
        ]);
        Assert.Equal("Vendor: You want the usual today?", reading.SubtitleBlock(Area).Text);
    }

    [Fact]
    public void DifferentTextSizeIsNotJoined()
    {
        var reading = new Reading([Line("Vendor: Fresh fruit!", 0.7), Line("Driver: Move it.", 0.8, 0.07)]);
        Assert.Equal("Vendor: Fresh fruit!", reading.SubtitleBlock(Area).Text);
    }
}
