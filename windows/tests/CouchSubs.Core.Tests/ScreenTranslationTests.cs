// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

public class ScreenTranslationTests
{
    private static readonly Frame Image = Frame.Blank(64, 64);

    private static TextLine Line(string text, double left, double top, double right, double height = 0.03) =>
        new(text, new TextBox(left, top, right, top + height));

    [Fact]
    public void LinesFarApartBecomeSeparateGroups()
    {
        // Sol üstte görev paneli, sağ altta bilgi kutusu, ortada altyazı.
        var groups = ScreenTranslation.Groups(new Reading([
            Line("Find the blacksmith in", 0.05, 0.10, 0.30),
            Line("the village square", 0.05, 0.135, 0.25),
            Line("Press the lever to open the gate.", 0.40, 0.85, 0.60),
            Line("New item unlocked", 0.75, 0.60, 0.95),
        ]));
        Assert.Equal(3, groups.Count);
        Assert.Equal(["Find the blacksmith in the village square"], groups[0].Paragraphs);
        Assert.Equal(0.05, groups[0].Box.Left, 6);
        Assert.Equal(0.165, groups[0].Box.Bottom, 6);
        Assert.Equal(0.03, groups[0].LineHeight, 6);
        Assert.Equal(["New item unlocked"], groups[1].Paragraphs);
        Assert.Equal(["Press the lever to open the gate."], groups[2].Paragraphs);
    }

    [Fact]
    public void LinesOnTheSameRowButFarApartAreSeparate()
    {
        var groups = ScreenTranslation.Groups(new Reading([Line("Settings", 0.05, 0.05, 0.15), Line("Back to menu", 0.80, 0.05, 0.95)]));
        Assert.Equal(2, groups.Count);
    }

    [Fact]
    public void MenuLinesAreTranslatedOneByOne()
    {
        var groups = ScreenTranslation.Groups(new Reading([
            Line("Map", 0.05, 0.30, 0.15), Line("Inventory", 0.05, 0.34, 0.20), Line("Settings", 0.05, 0.38, 0.18),
        ]));
        Assert.Single(groups);
        Assert.Equal(["Map", "Inventory", "Settings"], groups[0].Paragraphs);
    }

    [Fact]
    public void TitleInBigLettersIsNotMergedWithTheSmallTextBelow()
    {
        var groups = ScreenTranslation.Groups(new Reading([
            Line("Chapter One", 0.30, 0.20, 0.70, 0.08),
            Line("The journey begins in the north.", 0.30, 0.29, 0.70, 0.03),
        ]));
        Assert.Equal(2, groups.Count);
        Assert.Equal(0.08, groups[0].LineHeight, 6);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void FullWidthHeadingDoesNotAbsorbOneOfTwoColumns(bool reversed)
    {
        var lines = new[] {
            Line("Available missions", 0.05, 0.10, 0.95),
            Line("Find the blacksmith in", 0.05, 0.14, 0.43),
            Line("Bring the medicine to", 0.57, 0.14, 0.95),
            Line("the village square.", 0.05, 0.18, 0.40),
            Line("the northern camp.", 0.57, 0.18, 0.92),
        };
        var groups = ScreenTranslation.Groups(new Reading(reversed ? lines.Reverse().ToArray() : lines));
        Assert.Equal(3, groups.Count);
        var heading = Assert.Single(groups, g => g.Paragraphs.Contains("Available missions"));
        Assert.Single(heading.Paragraphs);
        Assert.Equal(0.13, heading.Box.Bottom, 6);
        Assert.Contains(groups, g => g.Paragraphs.SequenceEqual(new[] { "Find the blacksmith in the village square." }) && g.Box.Right < 0.5);
        Assert.Contains(groups, g => g.Paragraphs.SequenceEqual(new[] { "Bring the medicine to the northern camp." }) && g.Box.Left > 0.5);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void FullWidthFooterDoesNotJoinEitherColumn(bool reversed)
    {
        var lines = new[] {
            Line("Find the blacksmith in", 0.05, 0.14, 0.43),
            Line("Bring the medicine to", 0.57, 0.14, 0.95),
            Line("the village square.", 0.05, 0.18, 0.40),
            Line("the northern camp.", 0.57, 0.18, 0.92),
            Line("Choose a destination", 0.05, 0.22, 0.95),
        };
        var groups = ScreenTranslation.Groups(new Reading(reversed ? lines.Reverse().ToArray() : lines));
        Assert.Equal(3, groups.Count);
        var footer = Assert.Single(groups, g => g.Paragraphs.Contains("Choose a destination"));
        Assert.Single(footer.Paragraphs);
        Assert.Equal(0.22, footer.Box.Top, 6);
        Assert.Contains(groups, g => g.Paragraphs.SequenceEqual(new[] { "Find the blacksmith in the village square." }));
        Assert.Contains(groups, g => g.Paragraphs.SequenceEqual(new[] { "Bring the medicine to the northern camp." }));
    }

    [Theory]
    [InlineData(0.05, 0.4)]
    [InlineData(0.30, 0.70)]
    [InlineData(0.60, 0.95)]
    public void WrappedParagraphKeepsNarrowOrIndentedContinuation(double left, double right)
    {
        var groups = ScreenTranslation.Groups(new Reading([
            Line("Find the blacksmith in", 0.05, 0.10, 0.95),
            Line("the village square.", left, 0.14, right),
        ]));
        Assert.Equal(new[] { "Find the blacksmith in the village square." }, Assert.Single(groups).Paragraphs);
    }

    [Fact]
    public void NearbyUnrelatedColumnDoesNotDetachTheLocalHeading()
    {
        var groups = ScreenTranslation.Groups(new Reading([
            Line("Current objective", 0.05, 0.10, 0.43),
            Line("Find the blacksmith in", 0.05, 0.14, 0.43),
            Line("Bring the medicine to", 0.57, 0.14, 0.95),
            Line("the village square.", 0.05, 0.18, 0.40),
            Line("the northern camp.", 0.57, 0.18, 0.92),
        ]));
        Assert.Equal(2, groups.Count);
        Assert.Contains(groups, g => g.Paragraphs.SequenceEqual(new[] { "Current objective", "Find the blacksmith in the village square." }));
    }

    [Fact]
    public void FilteredControllerPromptDoesNotCreateAColumnBoundary()
    {
        var groups = ScreenTranslation.Groups(new Reading([
            Line("Find the blacksmith in", 0.05, 0.10, 0.95),
            Line("the village square.", 0.05, 0.14, 0.43),
            Line("R2 Swing", 0.57, 0.14, 0.95),
        ]));
        Assert.Equal(new[] { "Find the blacksmith in the village square." }, Assert.Single(groups).Paragraphs);
    }

    [Fact]
    public async Task SeparatingTheHeadingKeepsTranslationInputsAndText()
    {
        var translator = new InputRecorder();
        var items = await ScreenTranslation.TranslateAsync(Image, new LinesReader(new Reading([
            Line("Available missions", 0.05, 0.10, 0.95),
            Line("Find the blacksmith in", 0.05, 0.14, 0.43),
            Line("Bring the medicine to", 0.57, 0.14, 0.95),
            Line("the village square.", 0.05, 0.18, 0.40),
            Line("the northern camp.", 0.57, 0.18, 0.92),
        ])), translator);
        Assert.Equal(3, items.Count);
        Assert.Equal(new[] { "Available missions", "Find the blacksmith in the village square.", "Bring the medicine to the northern camp." }, items.Select(i => i.Source));
        Assert.Equal(items.Select(i => i.Source), translator.Requested);
        Assert.Equal(new[] { "Türkçe sonuç 1", "Türkçe sonuç 2", "Türkçe sonuç 3" }, items.Select(i => i.Translation));
    }

    /// <summary>
    /// Silah menüsü: iki sütunda aralıklı 29 etiket, altta bilgi kutusu. Windows OCR kutuları harflere sıkı oturur;
    /// alt uzantısı olmayan satırın ("...can be") altındaki boşluk satır yüksekliğinin %90'ı olunca son satır ayrı grup
    /// oluyor, 31. grup olduğu için de hiç çevrilmiyordu: TV'de bilgi kutusunun son satırı İngilizce kalıyordu.
    /// </summary>
    private static List<TextLine> LoadoutMenu(int labels)
    {
        var lines = new List<TextLine>();
        for (var i = 0; i < labels; i++)
        {
            var (left, right) = i % 2 == 0 ? (0.05, 0.20) : (0.78, 0.95);
            lines.Add(Line($"Weapon slot {(char)('A' + (i % 26))}{i}", left, 0.04 + (i / 2 * 0.045), right, 0.02));
        }
        lines.Add(Line("Weapons lost during a mission can be", 0.30, 0.75, 0.70, 0.025));
        lines.Add(Line("recovered from a weapon locker.", 0.30, 0.7975, 0.62, 0.025));
        return lines;
    }

    [Fact]
    public void LastLineOfAnInfoBoxIsNotLeftOut()
    {
        var groups = ScreenTranslation.Groups(new Reading(LoadoutMenu(29)));
        Assert.Contains(groups, g => g.Paragraphs.SequenceEqual(new[] { "Weapons lost during a mission can be recovered from a weapon locker." }));
        Assert.DoesNotContain(groups, g => g.Paragraphs.Contains("recovered from a weapon locker."));
    }

    [Fact]
    public void CrowdedScreenKeepsTheGroupsWithTheMostText()
    {
        var lines = LoadoutMenu(40);
        var groups = ScreenTranslation.Groups(new Reading(lines));
        Assert.Equal(ScreenTranslation.MaxGroups, groups.Count);
        Assert.Equal("Weapons lost during a mission can be recovered from a weapon locker.", groups[^1].Paragraphs.Single());
        // Kalanlar yine yukarıdan aşağı sıralıdır.
        Assert.Equal(groups.OrderBy(g => g.Box.Top).Select(g => g.Box.Top), groups.Select(g => g.Box.Top));
    }

    [Fact]
    public void LowercaseLineAfterAFinishedSentenceFarBelowStaysSeparate()
    {
        var groups = ScreenTranslation.Groups(new Reading([
            Line("Weapons can be recovered.", 0.30, 0.75, 0.70, 0.025),
            Line("then continue on later", 0.30, 0.7975, 0.62, 0.025),
            Line("and this one is far below", 0.30, 0.88, 0.62, 0.025),
        ]));
        Assert.Equal(3, groups.Count);
    }

    [Fact]
    public void NumbersAndPromptsAreNotTranslated()
    {
        var groups = ScreenTranslation.Groups(new Reading([
            Line("23m", 0.50, 0.05, 0.55), Line("9", 0.90, 0.05, 0.92), Line("R2 Swing", 0.80, 0.90, 0.95),
            Line("HP 120/300", 0.05, 0.90, 0.20),
        ]));
        Assert.Equal(["HP 120/300"], Assert.Single(groups).Paragraphs);
    }

    [Fact]
    public void LinesWithoutPlacesAreSkipped() =>
        Assert.Empty(ScreenTranslation.Groups(new Reading([new TextLine("Find the blacksmith.")])));

    [Fact]
    public async Task EveryGroupIsTranslatedAndProgressIsReported()
    {
        var reported = new List<int>();
        var items = await ScreenTranslation.TranslateAsync(Image, new LinesReader(new Reading([
            Line("Find the blacksmith.", 0.05, 0.10, 0.30),
            Line("Bring him three iron bars.", 0.05, 0.135, 0.30),
            Line("Leave the camp", 0.60, 0.80, 0.90),
        ])), new FakeTranslator(), list => reported.Add(list.Count));
        Assert.Equal(2, items.Count);
        Assert.Equal("TR: Find the blacksmith.\nTR: Bring him three iron bars.", items[0].Translation);
        Assert.True(items[0].Paragraphs);
        Assert.False(items[1].Paragraphs);
        Assert.Equal([1, 2], reported);
    }

    [Fact]
    public async Task TextThatTranslatesToItselfIsNotShown()
    {
        var items = await ScreenTranslation.TranslateAsync(Image, new LinesReader(new Reading([
            Line("KRATOS", 0.05, 0.10, 0.30), Line("Open the door.", 0.50, 0.80, 0.70),
        ])), new SameNameTranslator());
        Assert.Equal("Kapıyı aç.", Assert.Single(items).Translation);
    }

    [Fact]
    public async Task UnavailableTranslatorIsReported()
    {
        var translator = new FakeTranslator { Error = new TranslatorException(TranslatorStatus.NeedsDownload) };
        await Assert.ThrowsAsync<TranslatorException>(() => ScreenTranslation.TranslateAsync(
            Image, new LinesReader(new Reading([Line("Open the door.", 0.5, 0.8, 0.7)])), translator));
    }

    [Theory]
    [InlineData(0, 12000)]
    [InlineData(200, 18000)]
    [InlineData(5000, 60000)]
    public void DisplayTimeGrowsWithTextButIsBounded(int length, int expected) =>
        Assert.Equal(expected, ScreenTranslation.DisplayMilliseconds([new("a", new string('a', length), new TextBox(0, 0, 1, 1), 0.03)]));

    [Fact]
    public async Task ScreenIsReadWithTheScreenReadingNotTheSubtitleChoice()
    {
        // GTA 6 telefon ekranı: altyazı okuması pakete/sözlüğe uyan hazırlığı seçer ve yalnız bir satır kalır; "Ekranı
        // çevir" ise karenin bütün yazılarını okumalı (X: "yalnız altyazıyı çeviriyor").
        var reader = new SubtitleOnlyReader(
            subtitle: new Reading([Line("Lmk how it's going", 0.40, 0.50, 0.60)]),
            screen: new Reading([
                Line("Lmk how it's going", 0.40, 0.50, 0.60),
                Line("Meet me at the marina tonight.", 0.40, 0.30, 0.65),
                Line("Mission objectives updated", 0.05, 0.05, 0.30),
            ]));
        var translator = new InputRecorder();
        var items = await ScreenTranslation.TranslateAsync(Frame.Blank(1920, 1080), reader, translator);
        Assert.Equal(0, reader.SubtitleReads);
        Assert.Equal(1, reader.ScreenReads);
        Assert.Equal(3, items.Count);
        Assert.Contains("Mission objectives updated", translator.Requested);
        Assert.Contains("Meet me at the marina tonight.", translator.Requested);
    }

    [Fact]
    public void CombinedKeepsTheRawReadingAndAddsOnlyLinesItMissed()
    {
        var raw = new Reading([Line("Mission objectives updated", 0.05, 0.05, 0.30), Line("Lmk how it's", 0.40, 0.50, 0.55)]);
        var white = new Reading([
            Line("Lmk how it's going", 0.40, 0.50, 0.60),   // ham okumada zaten var (üst üste): eklenmez
            Line("I'm on my way.", 0.40, 0.85, 0.60),       // ham okuma açık zeminde bulamamış: eklenir
        ]);
        var combined = ScreenTranslation.Combined(raw, white);
        Assert.Equal(["Mission objectives updated", "Lmk how it's", "I'm on my way."], combined.Lines.Select(line => line.Text));
    }

    [Fact]
    public void FallbackReaderForwardsTheScreenReading()
    {
        var primary = new SubtitleOnlyReader(Reading.Empty, new Reading([Line("Menu", 0.1, 0.1, 0.2)]));
        var reading = new FallbackTextReader(primary, null).ReadScreen(Image);
        Assert.Equal(1, primary.ScreenReads);
        Assert.Equal("Menu", reading.Text);
    }

    /// <summary>Altyazı okumasında yalnız altyazıyı, ekran okumasında bütün yazıları bulan okuyucu.</summary>
    private sealed class SubtitleOnlyReader(Reading subtitle, Reading screen) : ITextReader
    {
        public int SubtitleReads { get; private set; }
        public int ScreenReads { get; private set; }
        public string Read(Frame image) => ReadLines(image, true).Text;
        public Reading ReadLines(Frame image, bool deep)
        {
            SubtitleReads++;
            return subtitle;
        }
        public Reading ReadScreen(Frame image)
        {
            ScreenReads++;
            return screen;
        }
    }

    private sealed class InputRecorder : ITextTranslator
    {
        public List<string> Requested { get; } = [];
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            Requested.Add(text);
            return Task.FromResult("Türkçe sonuç " + Requested.Count);
        }
    }

    private sealed class SameNameTranslator : ITextTranslator
    {
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default) =>
            Task.FromResult(text == "Open the door." ? "Kapıyı aç." : text);
    }
}
