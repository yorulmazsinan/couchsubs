// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Sessizlik bekçisi (Mac SilenceWatchTests ve Android SilenceWatchTest ile aynı örnekler).</summary>
public class SilenceWatchTests
{
    [Theory]
    [InlineData("We should reach the lighthouse before dark.", true)]
    [InlineData("JASON: Get in the car", true)]
    [InlineData("Hey, look, we don't wanna get caught out here, man.", true)]
    [InlineData("I need 5 more minutes, okay?", true)]
    [InlineData("SETTINGS", false)]
    [InlineData("Search the camp for Donnie", false)]
    [InlineData("RETRY CHECKPOINT RESTART MISSION", false)]
    [InlineData("Okay.", false)]
    [InlineData("$1,250 in 3 days.", false)]
    [InlineData("Collect the packages", false)]
    [InlineData("LUREPREDATOR / L35₽", false)]
    public void OnlySpeechLikeLinesCount(string text, bool speech) => Assert.Equal(speech, SilenceWatch.IsSpeech(text));

    [Fact]
    public void FiresAfterTenSilentSecondsOncePerLineAndAtMostEveryTenSeconds()
    {
        var watch = new SilenceWatch();
        const string line = "We should reach the lighthouse before dark.";
        Assert.Null(watch.Due([line], 0));
        Assert.Null(watch.Due([line], 9_900));
        Assert.Equal(line, watch.Due([line], 10_000));
        watch.Fired(line, 10_000);
        // Aynı satır bir daha gönderilmez.
        Assert.Null(watch.Due([line], 20_000));
        const string next = "Don't let him see you, stay low.";
        Assert.Null(watch.Due([next], 21_000));
        Assert.Null(watch.Due([next], 30_000));
        Assert.Equal(next, watch.Due([next], 31_000));
        watch.Fired(next, 31_000);
        // Bir çeviri gönderildi: sessizlik yeniden başlar.
        watch.Sent();
        const string third = "Where the hell is Donnie now?";
        Assert.Null(watch.Due([third], 32_000));
        Assert.Null(watch.Due([third], 41_000));
        Assert.Equal(third, watch.Due([third], 42_000));
        // Konuşma kesilirse süre baştan başlar.
        var gap = new SilenceWatch();
        Assert.Null(gap.Due([line], 0));
        Assert.Null(gap.Due(["SETTINGS"], 5_000));
        Assert.Null(gap.Due([line], 6_000));
        Assert.Null(gap.Due([line], 15_000));
        Assert.Equal(line, gap.Due([line], 16_000));
    }
}
