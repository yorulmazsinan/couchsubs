// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Translation.Tests;

public class SubtitleSegmenterTests
{
    /// <summary>Çevrilecek parçalar köşeli parantezde, kalanlar olduğu gibi.</summary>
    private static string Render(string text) =>
        string.Concat(SubtitleSegmenter.Split(text).Select(p => p.Translate ? $"[{p.Text}]" : p.Text));

    [Theory]
    [InlineData("Wait!", "[Wait!]")]
    [InlineData("Boy! Focus. The draugr are still coming.", "[Boy!] [Focus.] [The draugr are still coming.]")]
    [InlineData("What is that?! It looks like a door.", "[What is that?!] [It looks like a door.]")]
    [InlineData("\"Run!\" he said. Then nothing.", "[\"Run!\" he said.] [Then nothing.]")]
    [InlineData("I know… but we must go.", "[I know… but we must go.]")]
    [InlineData("Wait... what is that?", "[Wait... what is that?]")]
    [InlineData("Mr. Smith is here. Dr. Jones too.", "[Mr. Smith is here.] [Dr. Jones too.]")]
    [InlineData("No. We go now.", "[No.] [We go now.]")]
    [InlineData("Kratos.", "[Kratos.]")]
    public void SplitsSentences(string text, string expected) => Assert.Equal(expected, Render(text));

    [Theory]
    [InlineData("ATREUS: Father, look over there!", "ATREUS: [Father, look over there!]")]
    [InlineData("ATREUS: Look! KRATOS: Stay behind me.", "ATREUS: [Look!] KRATOS: [Stay behind me.]")]
    [InlineData("SINDRI JR.: Hello there.", "SINDRI JR.: [Hello there.]")]
    [InlineData("Note: this is not a label.", "[Note: this is not a label.]")]
    [InlineData("Kratos: Stay close.", "Kratos: [Stay close.]")]
    [InlineData("Old Man: Who goes there?", "Old Man: [Who goes there?]")]
    [InlineData("Objective: Find the gate.", "[Objective: Find the gate.]")]
    public void KeepsSpeakerLabels(string text, string expected) => Assert.Equal(expected, Render(text));

    [Fact]
    public void JoinsWrappedLines()
    {
        Assert.Equal("[If we do not find the giant before nightfall, we will have to make camp.]",
            Render("If we do not find the giant before nightfall,\nwe will have to make camp."));
    }

    [Fact]
    public void KeepsLineBreaksBetweenSpeakers()
    {
        Assert.Equal("ATREUS: [Father, look!]\nKRATOS: [Stay behind me.]",
            Render("ATREUS: Father, look!\r\nKRATOS: Stay behind me."));
        Assert.Equal("- [Who are you?]\n- [A friend.]", Render("- Who are you?\n- A friend."));
    }

    /// <summary>
    /// Altyazı seçicinin konuşan adı saydığı her satır ("JASON : …", "Lucia：…") kendi satırında kalır; iki konuşanın sözü
    /// tek satıra birleşmez (beta.103 bildirimi; Mac ve Android aynı).
    /// </summary>
    [Theory]
    [InlineData("JASON : I'm coming.")]
    [InlineData("Jason：I'm coming.")]
    [InlineData("DJ Pooh: I'm coming.")]
    public void EverySpeakerLineStartsItsOwnRow(string second)
    {
        var pieces = SubtitleSegmenter.Split("Lucia: Get in the car.\n" + second);
        Assert.Contains(pieces, piece => !piece.Translate && piece.Text == "\n");
        Assert.DoesNotContain(pieces, piece => piece.Translate && piece.Text.Contains("Get in") && piece.Text.Contains("coming"));
    }

    [Theory]
    [InlineData("...", "...")]
    [InlineData("?!", "?!")]
    [InlineData("", "")]
    [InlineData("   ", "")]
    public void DoesNotTranslatePiecesWithoutLetters(string text, string expected) => Assert.Equal(expected, Render(text));

    [Theory]
    [InlineData("THE GATE WILL NOT HOLD MUCH LONGER.", "The gate will not hold much longer.")]
    [InlineData("I KNOW, BUT I CAN'T.", "I know, but I can't.")]
    [InlineData("WAIT!", "WAIT!")]
    [InlineData("KRATOS.", "KRATOS.")]
    [InlineData("Who are you?", "Who are you?")]
    [InlineData("NASA is here.", "NASA is here.")]
    public void NormalizesAllCapsSentences(string sentence, string expected) =>
        Assert.Equal(expected, SubtitleSegmenter.NormalizeCase(sentence));

    [Fact]
    public void KnownNamesStayCapitalized() =>
        Assert.Equal("The gate will not hold, Atreus.",
            SubtitleSegmenter.NormalizeCase("THE GATE WILL NOT HOLD, ATREUS.", new HashSet<string> { "atreus" }));
}
