// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

public class OcrNoiseTests
{
    /// Süslü yazıda bir sözcük her karede başka çöpe dönüşüyordu.
    [Theory]
    [InlineData("Across the deep waters, Pbo ou$3e went, hoping a boat would carry him home.",
                "Across the deep waters, Pbo went, hoping a boat would carry him home.")]
    [InlineData("Across the deep waters2aljd O went, Hoping a boat.", "Across the deep waters O went, Hoping a boat.")]
    [InlineData("He left 3e, at dawn.", "He left, at dawn.")]
    public void GarbledWordsAreRemoved(string line, string expected) => Assert.Equal(expected, OcrNoise.Clean(line));

    [Theory]
    [InlineData("Turn on the PS5 now.")]
    [InlineData("Hold R2-D2 still.")]
    [InlineData("It costs $500.")]
    [InlineData("Meet me at 3:00pm.")]
    [InlineData("The 2nd gate is 100m away.")]
    [InlineData("Run at 60fps, 4K.")]
    [InlineData("Score x2!")]
    [InlineData("Year 1984.")]
    [InlineData("I can't — wait…")]
    [InlineData("\"Kratos!\" she said.")]
    [InlineData("Mk2 rifle, 9.5kg.")]
    [InlineData("L1 + R1 Spartan Rage")]
    public void UsualTokensAreKept(string line) => Assert.Equal(line, OcrNoise.Clean(line));

    /// <summary>Mafia'da görülen "?!" ve kutu kenarı artıkları; Mac'teki OcrNoiseTests ile aynı örnekler.</summary>
    [Theory]
    [InlineData("?! Where do you think you're going?", "Where do you think you're going?")]
    [InlineData("Where do you think you're going ?!", "Where do you think you're going?!")]
    [InlineData("Get in the car, Enzo. ?!", "Get in the car, Enzo.")]
    [InlineData("Wait, ?! Don Salieri wants you.", "Wait, Don Salieri wants you.")]
    [InlineData(". Get in the car.", "Get in the car.")]
    [InlineData("| Get in the car, Enzo.", "Get in the car, Enzo.")]
    [InlineData("Get in the car, Enzo. |", "Get in the car, Enzo.")]
    [InlineData("Leave it. l", "Leave it.")]
    public void StrayPunctuationAndBoxEdgesAreRemoved(string line, string expected) => Assert.Equal(expected, OcrNoise.Clean(line));

    [Theory]
    [InlineData("l don't know, Don Salieri.", "I don't know, Don Salieri.")]
    [InlineData("| don't know.", "I don't know.")]
    [InlineData("l'm telling you, l saw him.", "I'm telling you, I saw him.")]
    [InlineData("|'ll be right back.", "I'll be right back.")]
    [InlineData("You and l've been here before.", "You and I've been here before.")]
    public void MisreadPronounBecomesI(string line, string expected) => Assert.Equal(expected, OcrNoise.Clean(line));

    [Theory]
    [InlineData("What?! The door opened by itself!")]
    [InlineData("- Where? - Home.")]
    [InlineData("Wait... what?")]
    [InlineData("I... I don't know.")]
    [InlineData("\"Run!\" he said.")]
    [InlineData("So, you're Enzo?")]
    [InlineData("... and then he left.")]
    [InlineData("Wait ... what?")]
    [InlineData("I said no!")]
    [InlineData("Leave it, I said.")]
    [InlineData("Press L to aim.")]
    public void RealPunctuationIsKept(string line) => Assert.Equal(line, OcrNoise.Clean(line));

    [Fact]
    public void ReadingDropsLinesThatWereOnlyNoise()
    {
        var reading = new Reading([new TextLine("We go now."), new TextLine("ou$3e 2aljd")]).WithoutOcrNoise();
        Assert.Equal("We go now.", reading.Text);
    }
}

public class ReadingChoiceTests
{
    [Fact]
    public void CleanReadingScoresHigherThanGarbled()
    {
        Assert.True(OcrNoise.Score("CESARE: Wait for me!") > OcrNoise.Score("- CESAREiVJütt'h!"));
        Assert.True(OcrNoise.Score("We go to McDonald's now.") > 0);
        Assert.True(OcrNoise.Score("T hats the[lil Should be quiet now.") < OcrNoise.Score("That should be quiet now."));
    }

    /// Geçişte üst üste solan iki altyazının karışık okuması çöp sayılır; olağan cümleler, kısaltmalar ve "Hmm" sayılmaz.
    [Theory]
    [InlineData("Gtt solkolfege.", true)]
    [InlineData("- CESAREiVJütt'h!", true)]
    [InlineData("Wrrk thng.", true)]
    [InlineData("Hold the gate.", false)]
    [InlineData("The FBI and the NPC agents.", false)]
    [InlineData("Hmm, I don't know about that, boy.", false)]
    [InlineData("Go to college.", false)]
    public void GarbledReadingsAreRecognised(string text, bool garbled) => Assert.Equal(garbled, OcrNoise.LooksGarbled(text));

    /// Koyu kenarlı beyaz yazı siyaha, parlak zemin ve kenar beyaza döner.
    [Fact]
    public void WhiteTextOnlyKeepsOutlinedWhiteAndDropsBrightBackground()
    {
        var frame = Frame.Blank(60, 20);
        void Paint(int x0, int x1, byte value)
        {
            for (var y = 0; y < 20; y++)
                for (var x = x0; x < x1; x++)
                {
                    var i = y * frame.Stride + x * 4;
                    frame.Pixels[i] = frame.Pixels[i + 1] = frame.Pixels[i + 2] = value;
                    frame.Pixels[i + 3] = 255;
                }
        }
        Paint(0, 30, 230);   // parlak kum: yakınında koyu yok
        Paint(40, 44, 20);   // yazının koyu kenarı
        Paint(44, 48, 250);  // beyaz harf
        var result = TextImage.WhiteTextOnly(frame, radius: 3);
        byte At(int x) => result.Pixels[10 * result.Stride + x * 4];
        Assert.Equal(255, At(5));   // zemin
        Assert.Equal(0, At(45));    // harf
        Assert.Equal(255, At(41));  // kenar
    }
}
