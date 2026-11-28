// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using Role = CouchSubs.Core.ScreenPhoneCard.Role;

namespace CouchSubs.Core.Tests;

public class GamePhoneTextTests
{
    private static TextLine Line(string text, double y, double left = 0.20, double right = 0.80) =>
        new(text, new TextBox(left, y, right, y + 0.031));

    [Theory]
    [InlineData("Meet me there ..", "Meet me there...")]
    [InlineData("Meet me there ...", "Meet me there...")]
    [InlineData("Meet me there...", "Meet me there...")]
    [InlineData("Meet me at 6.", "Meet me at 6.")]
    public void PreviewEllipsisHasOneSpellingWithoutCompletingTheLastWord(string preview, string expected)
    {
        var reading = new Reading([Line("Suggested", .02), Line("Jordan", .10), Line(preview, .14),
            Line("Chase", .22), Line("Call me back.", .26), Line("Messages", .40),
            Line("Robin", .50), Line("On my way.", .54)]);
        Assert.Contains(GamePhoneText.ForTranslation(reading).Lines, line => line.Text == expected);
    }

    [Theory]
    [InlineData("Go", "No")]
    [InlineData("Meet me at the back gate with 24 red bags.", "Meet me at the back gate with 25 bed bags.")]
    [InlineData("We can do it now if you bring the truck.", "We can not do it now if you bring the truck.")]
    [InlineData("I heard they all went to the left door.", "I heard they all went to the rear door.")]
    [InlineData("That was all I needed to hear from your friend.", "The next message just came in from the office.")]
    public void ShortRepliesAndMeaningChangesDoNotWaitForOcrConfirmation(string oldText, string nextText)
    {
        Assert.False(GamePhoneText.HasAdjacentOcrEdits(oldText, nextText));
    }

    [Fact]
    public void SocialCaptionStaysAboveOriginalTags()
    {
        var words = new TextWord[] {
            new("Meet", new(0.12, 0.68, 0.24, 0.71)),
            new("me", new(0.26, 0.68, 0.34, 0.71)),
            new("#NightRide", new(0.38, 0.68, 0.92, 0.71)) };
        var reading = new Reading([Line("@vice.305", 0.63), new("Meet me #NightRide", new(0.12, 0.68, 0.92, 0.71), Words: words),
            Line("#sunset #leonida", 0.73), Line("Tell @vice.305 to wait.", 0.80)]);
        var result = GamePhoneText.ForTranslation(reading);
        var groups = GamePhoneText.Groups(result);
        Assert.Equal(["Meet me #NightRide", "Tell @vice.305 to wait."], groups.SelectMany(g => g.Paragraphs));
        Assert.Equal(words[^1].Box.Right, result.Lines[0].Box!.Value.Right);
    }

    [Fact]
    public void MessageStillRefersToTheSameAccountAfterTranslation()
    {
        const string source = "Send the photo to @KaterinaDiva.";
        Assert.Equal("Fotoğrafı @KaterinaDiva'ya gönder.", GamePhoneText.KeepIdentifiers(source, "Fotoğrafı @katerinadiva'ya gönder."));
        Assert.Null(GamePhoneText.KeepIdentifiers(source, "Fotoğrafı ona gönder."));
        Assert.Null(GamePhoneText.KeepIdentifiers(source, "Fotoğrafı @Joey'e gönder."));
        var candidate = RegionWatcher.MakeCandidate(new Reading([Line(source, 0.55)]), new CropRegion(), phone: true);
        Assert.Equal([source], candidate.Paragraphs);
    }

    [Fact]
    public void TextingShorthandSurvivesOcrCleanupAndReachesTranslation()
    {
        const string source = "We're in this 2gether. I left it 4u.";
        var candidate = RegionWatcher.MakeCandidate(new Reading([Line(source, 0.5)]), new CropRegion(), phone: true);
        Assert.Equal([source], candidate.Paragraphs);
        Assert.Equal("We're in this together. I left it for you.", GamePhoneText.EnglishModelInput(candidate.Paragraphs[0]));
        const string identifiers = "Use B4, @4u, #2gether or gate C4.";
        Assert.Equal(identifiers, GamePhoneText.EnglishModelInput(identifiers));
        Assert.Equal("10 min out.", GamePhoneText.EnglishModelInput("IO min out."));
        Assert.Equal("IO port. I owe him.", GamePhoneText.EnglishModelInput("IO port. I owe him."));
    }

    [Fact]
    public void ContactsStayOnScreenAndIncompletePreviewsAreKeptAsRead()
    {
        var rows = new Reading([Line("Suggestions", 0.04), Line("Chase", 0.12), Line("call me after ...", 0.16),
            Line("May", 0.25), Line("Don't leave yet.", 0.29), Line("Messages", 0.42),
            Line("Rose", 0.54), Line("Meet me at 06:40.", 0.58)]);
        var kept = GamePhoneText.ForTranslation(rows);
        Assert.Equal(["Suggestions", "Chase", "call me after...", "May", "Don't leave yet.", "Messages", "Rose", "Meet me at 06:40."],
            kept.Lines.Select(l => l.Text));
        Assert.Equal([Role.Heading, Role.Contact, Role.Preview, Role.Contact, Role.Preview, Role.Heading, Role.Contact, Role.Preview],
            kept.Lines.Select(l => l.ListRole));
        Assert.DoesNotContain(GamePhoneText.Groups(kept), g => g.Paragraphs.Count > 1);
        // Tek başlık da yeter: sallanan telefonda biri bir okumada kaçabilir.
        Assert.Equal([Role.Contact, Role.Preview, Role.Contact, Role.Preview, Role.Heading, Role.Contact, Role.Preview],
            GamePhoneText.ForTranslation(new Reading(rows.Lines.Skip(1))).Lines.Select(l => l.ListRole));
        // Başlıksız ve kesik önizlemesiz üç ad-yanıt çifti liste sayılmaz.
        var plain = rows.Lines.Where(l => GamePhoneText.SectionLabel(l.Text) is null && !l.Text.EndsWith("...", StringComparison.Ordinal));
        Assert.All(GamePhoneText.ForTranslation(new Reading(plain)).Lines, l => Assert.Null(l.ListRole));
    }

    /// <summary>
    /// Başlığın simgesi yazı tanımada tek harf ya da işaret olarak okunur ("g Suggested"): artık atılır, satır yine başlıktır.
    /// Başlık içeren gerçek cümle başlık değildir (Mac ile aynı).
    /// </summary>
    [Theory]
    [InlineData("g Suggested", true)]
    [InlineData("✱ Suggested", true)]
    [InlineData("Suggested", true)]
    [InlineData("Messages ☆", true)]
    [InlineData("• Messages", true)]
    [InlineData("O Messages", true)]
    [InlineData("Suggested items", false)]
    [InlineData("My Messages", false)]
    [InlineData("Messages from Joey", false)]
    [InlineData("Send Messages now", false)]
    public void HeadingIconResidueIsDropped(string text, bool heading)
    {
        Assert.Equal(heading, GamePhoneText.SectionLabel(text) is not null);
    }

    /// <summary>
    /// LG, beta.93: GTA 6 Mesajlar ekranı (fotoğraftaki sıra). Telefon sallanırken her okuma başka: başlığın simgesi bir "g"
    /// okunur, bir okunmaz; "Messages" bir okumada kaçar; kutular birkaç piksel oynar. Liste her okumada liste, satırlar aynı
    /// sırada ve aynı rolde kalır; kişi adları ayrı satırdır (Mac ile aynı).
    /// </summary>
    [Theory]
    [InlineData(0, "Suggested", true)]
    [InlineData(1, "g Suggested", true)]
    [InlineData(2, "✱ Suggested", false)]
    [InlineData(3, null, true)]
    [InlineData(4, null, false)]
    public void SwayingMessageListKeepsItsRolesInEveryRead(int index, string? suggested, bool messages)
    {
        var dy = 0.002 * index;
        TextLine Flat(string text, double y, double left, double right = 0.95)
        {
            var box = new TextBox(left + dy / 2, y + dy, right + dy / 2, y + dy + 0.031);
            return new TextLine(text, box) { PhoneBox = box };
        }
        var lines = new List<TextLine>();
        if (suggested is not null) lines.Add(Flat(suggested, 0.04, 0.05, 0.40));
        lines.AddRange([Flat("Cal", 0.10, 0.30, 0.38), Flat("$ in your mailbox. You bailed", 0.14, 0.30),
            Flat("Brian", 0.22, 0.30, 0.42), Flat("Ok. There's some cash in t...", 0.26, 0.30)]);
        if (messages) lines.Add(Flat("Messages", 0.33, 0.03, 0.30));
        lines.AddRange([Flat("Donnie", 0.40, 0.30, 0.45),
            Flat("Joey", 0.50, 0.30, 0.40), Flat("Hey this is Joey from Coa...", 0.54, 0.30),
            Flat("Lucia (Yolanda phone)", 0.62, 0.30, 0.70), Flat("Outside living better than ...", 0.66, 0.30),
            Flat("Shirley", 0.74, 0.30, 0.45), Flat("Oh that's nice hon. aren't ...", 0.78, 0.30),
            Flat("Rusty Anchor", 0.88, 0.30, 0.62)]);
        (string Text, Role Role)[] expected =
        [
            ("Suggested", Role.Heading), ("Cal", Role.Contact), ("$ in your mailbox. You bailed", Role.Preview),
            ("Brian", Role.Contact), ("Ok. There's some cash in t...", Role.Preview), ("Messages", Role.Heading),
            ("Donnie", Role.Contact), ("Joey", Role.Contact), ("Hey this is Joey from Coa...", Role.Preview),
            ("Lucia (Yolanda phone)", Role.Contact), ("Outside living better than...", Role.Preview),
            ("Shirley", Role.Contact), ("Oh that's nice hon. aren't...", Role.Preview), ("Rusty Anchor", Role.Contact),
        ];
        var wanted = expected.Where(e => (suggested is not null || e.Text != "Suggested") && (messages || e.Text != "Messages")).ToList();
        var groups = GamePhoneText.Groups(GamePhoneText.ForTranslation(new Reading(lines)));
        Assert.Equal(wanted.Select(e => e.Text), groups.Select(g => string.Concat(g.Paragraphs)));
        Assert.Equal(wanted.Select(e => (Role?)e.Role), groups.Select(g => g.Phone?.Role));
    }

    /// <summary>Kesik önizleme kesik çevrilir: yarım son sözcük ve sarkan edat çeviriye gitmez, çeviri "..." ile biter (Mac ile aynı).</summary>
    [Fact]
    public void CutPreviewIsTranslatedWithoutTheBrokenWord()
    {
        Assert.Equal("Hey this is Joey", GamePhoneText.CutInput("Hey this is Joey from Coa..."));
        Assert.Equal("Ok. There's some cash", GamePhoneText.CutInput("Ok. There's some cash in t..."));
        Assert.Equal("Outside living better", GamePhoneText.CutInput("Outside living better than..."));
        Assert.Equal("Oh that's nice hon.", GamePhoneText.CutInput("Oh that's nice hon. aren't..."));
        Assert.Equal("Call me", GamePhoneText.CutInput("Call me, then…"));
        Assert.Null(GamePhoneText.CutInput("Meet me at 6."));
        Assert.Null(GamePhoneText.CutInput("Coa..."));
        Assert.Equal("Selam, ben Joey...", GamePhoneText.CutTranslation("Selam, ben Joey."));
        Assert.Equal("Dışarıda yaşamak daha iyi...", GamePhoneText.CutTranslation("Dışarıda yaşamak daha iyi"));
    }

    [Theory]
    [InlineData("Okay")]
    [InlineData("No")]
    [InlineData("Thanks")]
    public void SingleWordPreviewInAConfirmedListIsNotMistakenForAnotherContact(string message)
    {
        var rows = new Reading([Line("Suggestions", .02), Line("Chase", .09), Line("call me soon", .13),
            Line("May", .21), Line("Don't leave yet.", .25), Line("Messages", .34),
            Line("Rose", .42), Line("Meet me here.", .46), Line("Jason", .56), Line(message, .60),
            Line("Martin", .73), Line("Lucia", .85)]);
        var kept = GamePhoneText.ForTranslation(rows).Lines;
        Assert.Equal(["Suggestions", "Chase", "call me soon", "May", "Don't leave yet.", "Messages", "Rose", "Meet me here.",
            "Jason", message, "Martin", "Lucia"], kept.Select(l => l.Text));
        Assert.Equal(Role.Preview, kept.First(l => l.Text == message).ListRole);
        Assert.Equal(["Chase", "May", "Rose", "Jason", "Martin", "Lucia"],
            kept.Where(l => l.ListRole == Role.Contact).Select(l => l.Text));
    }

    /// <summary>X, 28 Kas, beta.108: grup sohbetinin virgüllü adı önizleme sanılıyor, liste kartı ikiye bölünüyordu.</summary>
    [Fact]
    public void GroupChatNamesWithCommasAreContacts()
    {
        var rows = new Reading([Line("Suggested", .02), Line("Andy", .09), Line("Here's my new addres...", .13),
            Line("Papa Audacity, Jaso", .21), Line("Might be hard to top t...", .25),
            Line("Yasmani, Jason, Luc", .33), Line("Got the thing.", .37), Line("Messages", .45),
            Line("Dre'Quan, Jason, Lu", .53), Line("Wooooooo!", .57), Line("smani, Jason, Lucia", .65), Line("Got it.", .69)]);
        var kept = GamePhoneText.ForTranslation(rows).Lines;
        Assert.Equal(["Andy", "Papa Audacity, Jaso", "Yasmani, Jason, Luc", "Dre'Quan, Jason, Lu", "smani, Jason, Lucia"],
            kept.Where(l => l.ListRole == Role.Contact).Select(l => l.Text));
        Assert.Equal(Role.Preview, kept.First(l => l.Text == "Got the thing.").ListRole);
    }

    [Theory]
    [InlineData(0.72)]
    [InlineData(1.03)]
    public void SameSideRepliesRemainSeparateAsThePhoneMoves(double bubbleSpacing)
    {
        const double h = .04;
        TextLine Flat(string text, double y, double x)
        {
            var box = new TextBox(x, y, .8, y + h);
            return new TextLine(text, box) { PhoneBox = box };
        }
        var y = .12 + h * (1 + bubbleSpacing);
        var next = y + h * (2.1 + bubbleSpacing);
        var reading = new Reading([Flat("Jason.", .12, .10), Flat("Kirk is paying.", y, .15),
            Flat("He is on his way.", y + h * 1.10, .15), Flat("Meet me outside.", next, .10)]);
        var groups = GamePhoneText.Groups(reading);
        Assert.Equal(["Jason.", "Kirk is paying. He is on his way.", "Meet me outside."],
            groups.SelectMany(group => group.Paragraphs));
    }

    [Fact]
    public void OpposingRepliesStaySeparateAndWrappedTextStaysTogether()
    {
        var reading = new Reading([Line("Find someone who", 0.30, 0.10, 0.69),
            Line("knows this road.", 0.334, 0.10, 0.64), Line("on my way", 0.372, 0.38, 0.93)]);
        var groups = GamePhoneText.Groups(reading);
        Assert.Equal(["Find someone who knows this road.", "on my way"], groups.SelectMany(g => g.Paragraphs));
        Assert.Equal(2, groups.Count);
    }
}
