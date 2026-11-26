// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Telefon listesi kartları (Sinan Bey, beta.100 3397/3399/3400): kişi satırı (avatar, kalın ad, altında önizleme) ve ana
/// ekran bileşeni tek kart; sohbetin üstündeki ad çizilmez; "…" koymadan kesilmiş önizleme kesik çevrilir, "$" düşmez;
/// avatar, rozet ve seçim çerçevesi kareden bir kez kesilir (PhoneListLook). Mac ScreenPhoneCardTests /
/// PhoneRegionSessionTests ile aynı kurallar.
/// </summary>
public class PhoneListCardTests
{
    private static readonly double[] Upright = [0.78, 0.17, 0.78, 0.85];

    private static ScreenPhoneCard.Handset Handset(double[] pose, double aspect = 16.0 / 9) =>
        new(new GamePhoneGeometry.Pose(pose[0], pose[1], pose[2], pose[3]), aspect);

    private static ScreenTranslation.Item OnPhone(string source, string translation, ScreenPhoneCard.Role role, double top,
                                                  double left = 0.3, double right = 0.7, bool unchanged = false) =>
        new(source, translation, new TextBox(0.74, 0.2 + top * 0.6, 0.86, 0.22 + top * 0.6), 0.018)
        {
            Unchanged = unchanged, Phone = new ScreenPhoneCard.Placement(role, new TextBox(left, top, right, top + 0.03)),
        };

    private static List<ScreenTranslation.Item> List() =>
    [
        OnPhone("Messages", "Mesajlar", ScreenPhoneCard.Role.Heading, 0.05, 0.05, 0.4),
        OnPhone("Cal", "Cal", ScreenPhoneCard.Role.Contact, 0.15, 0.3, 0.4, unchanged: true),
        OnPhone("$ in your mailbox. You bailed", "$ posta kutunda. Beni...", ScreenPhoneCard.Role.Preview, 0.19, 0.3, 0.95),
        OnPhone("Brian", "Brian", ScreenPhoneCard.Role.Contact, 0.30, 0.3, 0.42, unchanged: true),
        OnPhone("Ok. There's some cash in t...", "Tamam. Biraz para...", ScreenPhoneCard.Role.Preview, 0.34, 0.3, 0.95),
    ];

    /// <summary>
    /// Ad ve önizleme tek kart (avatar, kalın ad, altında önizleme): kartın üstü adın İngilizcesiyle aynı hizada, boyu en az
    /// avatar boyunda; bölüm başlığı not olarak kalır; kart telefonun boş tarafında.
    /// </summary>
    [Fact]
    public void ContactAndPreviewBecomeOneCardAlignedWithTheEnglishName()
    {
        var phone = Handset(Upright);
        var items = List();
        var laid = ScreenPhoneCard.Layout(items, phone);
        Assert.Equal(laid, ScreenPhoneCard.Layout(items, phone));
        var panel = ScreenPhoneCard.PanelOf(laid)!;
        Assert.Null(panel.Title);
        Assert.Equal([ScreenPhoneCard.PanelPart.Note, ScreenPhoneCard.PanelPart.Row, ScreenPhoneCard.PanelPart.Row],
                     panel.Messages.Select(item => item.Panel!.Value));
        Assert.Equal("Mesajlar", panel.Messages[0].Translation);
        Assert.True(panel.Messages[0].Look?.Bold);
        var cal = panel.Messages[1];
        Assert.Equal(new ScreenPhoneCard.ListRow("Cal", "$ posta kutunda. Beni..."), cal.ListRow);
        Assert.Equal("Cal\n$ in your mailbox. You bailed", cal.Source);
        Assert.Equal("Cal\n$ posta kutunda. Beni...", cal.Translation);
        Assert.False(cal.ListRow!.Widget);
        Assert.NotNull(cal.ListRow.PortraitSpot);
        Assert.NotNull(cal.ListRow.BadgeSpot);
        Assert.NotNull(cal.ListRow.FrameSpot);
        Assert.Equal(ScreenPhoneCard.AlignedTop(items[1], cal.LineHeight), cal.Box.Top, 9);
        Assert.True(cal.Box.Bottom - cal.Box.Top >= ScreenPhoneCard.AvatarLines * cal.LineHeight - 1e-9);
        Assert.Equal(ScreenPhoneCard.RowColor, cal.Style);
        Assert.True(panel.Messages[1].Box.Bottom <= panel.Messages[2].Box.Top + 1e-9);
        Assert.True(cal.Box.Right <= phone.Bounds.Left + 1e-9);
        // JSON: panel "row", içerik "row" nesnesinde (arama yerleri gönderilmez).
        var json = SubtitleServer.ItemJson(cal, phone: true);
        Assert.Equal("row", json["panel"]);
        var row = Assert.IsType<SortedDictionary<string, object>>(json["row"]);
        Assert.Equal(new[] { "name", "preview" }, row.Keys.ToArray());
        // Arama yerleri görünüş karşılaştırmasına girmez (#1279).
        Assert.Equal(cal.ListRow, cal.ListRow with { PortraitSpot = null, BadgeSpot = new TextBox(0, 0, 1, 1) });
        Assert.NotEqual(cal.ListRow, cal.ListRow with { Selected = "#1E6FE0" });
        Assert.False(PhoneSteady.SamePicture(laid, [.. laid.Select(item => item.ListRow is { } r ? item with { ListRow = r with { Badge = "x" } } : item)]));

        // Telefon solda: kart sağda.
        var left = ScreenPhoneCard.Layout(items, Handset([0.22, 0.17, 0.22, 0.85]));
        Assert.True(left.First(item => item.Panel == ScreenPhoneCard.PanelPart.Row).Box.Left
                    >= Handset([0.22, 0.17, 0.22, 0.85]).Bounds.Right - 1e-9);
    }

    /// <summary>Saydam pencerede liste kartı en az avatar boyunda, yazısı avatarın sağında.</summary>
    [Fact]
    public void StackedListCardIsAtLeastAnAvatarTall()
    {
        var laid = ScreenPhoneCard.Layout(List(), Handset(Upright));
        var stacked = ScreenPhoneCard.Stacked(ScreenPhoneCard.PanelOf(laid)!, 1600, 900, 20);
        var card = stacked.Messages.First(item => item.Panel == ScreenPhoneCard.PanelPart.Row);
        Assert.True(card.Box.Bottom - card.Box.Top >= (ScreenPhoneCard.AvatarLines + 2 * ScreenPhoneCard.RowPadding) * card.LineHeight - 1e-9);
    }

    /// <summary>Otomatik telefon panelinde ana ekranın bileşeni (başlık + sayaç) tek grup, iki parça; panelde tek kart.</summary>
    [Fact]
    public void HomeWidgetIsGroupedAndTranslatedAsTwoLines()
    {
        ScreenTranslation.Group Home(string text, double left, double top, double right) =>
            new([text], new TextBox(0.74, 0.2 + top * 0.6, 0.86, 0.22 + top * 0.6), 0.018)
            {
                Phone = new ScreenPhoneCard.Placement(ScreenPhoneCard.Role.Home, new TextBox(left, top, right, top + 0.03)),
            };
        var groups = GamePhoneText.Widgets([Home("Reminders", 0.2, 0.3, 0.45), Home("6 Notifications", 0.08, 0.335, 0.4),
                                            Home("Hey whats up man", 0.08, 0.6, 0.8)]);
        Assert.Equal(2, groups.Count);
        Assert.Equal(["Reminders", "6 Notifications"], groups[0].Paragraphs);
        Assert.Equal(ScreenPhoneCard.Role.Widget, groups[0].Phone!.Role);
        Assert.Equal(ScreenPhoneCard.Role.Home, groups[1].Phone!.Role);
        // Başlık ve sayaç tek satır okunduysa ikiye ayrılır.
        var joined = GamePhoneText.Widgets([Home("Reminders 10 Notifications", 0.08, 0.3, 0.6)]);
        Assert.Equal(["Reminders", "10 Notifications"], Assert.Single(joined).Paragraphs);
        Assert.Equal(ScreenPhoneCard.Role.Widget, joined[0].Phone!.Role);
        Assert.Null(GamePhoneText.WidgetParts("See you 10 minutes"));
        Assert.True(PhoneChat.IsCounter("6 Notifications"));
        Assert.False(PhoneChat.IsCounter("Reminders"));

        var items = new List<ScreenTranslation.Item>
        {
            new("Reminders\n6 Notifications", "Hatırlatıcılar\n6 Bildirim", groups[0].Box, 0.018) { Phone = groups[0].Phone },
            new("Hey whats up man", "Naber adamım", groups[1].Box, 0.018) { Phone = groups[1].Phone },
        };
        var laid = ScreenPhoneCard.Layout(items, Handset(Upright));
        var widget = Assert.Single(laid, item => item.Panel == ScreenPhoneCard.PanelPart.Row && item.ListRow?.Widget == true);
        Assert.Equal("Hatırlatıcılar", widget.ListRow.Name);
        Assert.Equal("6 Bildirim", widget.ListRow.Preview);
        Assert.NotNull(widget.ListRow.PortraitSpot);
        Assert.Null(widget.ListRow.BadgeSpot);
        // Bildirim yazısı da telefonun üstüne yazılmaz: panelde avatarsız kart olur (Sinan Bey, beta.100 3422; Mac ile aynı).
        Assert.Contains(laid, item => item.Panel == ScreenPhoneCard.PanelPart.Row && item.ListRow is { Widget: false, Preview: "Naber adamım" });
    }

    /// <summary>Satır sonunda "…" olmadan kesilmiş önizleme: motora "..." ile gider, "$" korunur, para simgesi simge sayılmaz.</summary>
    [Fact]
    public void ClippedPreviewIsTranslatedAsCutAndKeepsTheCurrencySymbol()
    {
        Assert.Equal("$ in your mailbox. You bailed", GamePhoneText.ClippedInput("$ in your mailbox. You bailed"));
        Assert.Equal("You bailed me out", GamePhoneText.ClippedInput("You bailed me out to"));
        Assert.Null(GamePhoneText.ClippedInput("You bailed me out."));
        Assert.Null(GamePhoneText.ClippedInput("Bailed"));
        Assert.Equal("You bailed...", GamePhoneText.CutHint("You bailed"));
        Assert.Equal("$ posta kutunda", GamePhoneText.KeepingLeadingSymbol("$ in your mailbox", "posta kutunda"));
        Assert.Equal("$bende", GamePhoneText.KeepingLeadingSymbol("$5 on me", "bende")); // simge yazıya yapışıksa boşluksuz
        Assert.Equal("$ posta kutunda", GamePhoneText.KeepingLeadingSymbol("$ in your mailbox", "$ posta kutunda"));
        Assert.Equal("posta kutunda", GamePhoneText.KeepingLeadingSymbol("in your mailbox", "posta kutunda"));
        Assert.False(ButtonIcons.IsIconToken("$"));
        Assert.False(ButtonIcons.IsIconToken("€"));
        Assert.Equal("$ in your mailbox", PhoneChat.Clean("$ in your mailbox"));
        Assert.Equal("$ in your mailbox", OcrNoise.Clean("$ in your mailbox", keepIdentifiers: true));
    }

    /// <summary>Sohbette tam çevirisi bilinen mesajın kesik önizlemesi o çevirinin başıdır ("..."), uydurma değil.</summary>
    [Fact]
    public void CutPreviewOfAKnownMessageTakesTheStartOfItsTranslation()
    {
        var known = new Dictionary<string, string>
        {
            ["Hey this is Joey from Coach and Horses, call me back when you can"] = "Selam ben Joey, Coach and Horses'tan, müsait olunca beni ara",
            ["Something else entirely"] = "Bambaşka bir şey",
        };
        var preview = GamePhoneText.KnownPreview("Hey this is Joey from Coa...", known);
        Assert.NotNull(preview);
        Assert.StartsWith("Selam ben Joey", preview);
        Assert.EndsWith("...", preview);
        Assert.True(preview!.Length < known.First().Value.Length);
        Assert.Null(GamePhoneText.KnownPreview("Hi...", known));
        Assert.Null(GamePhoneText.KnownPreview("Nothing like this at all", known));
    }

    private static ScreenTranslation.Item ListItem() =>
        new("Cal\n$ in your mailbox", "Cal\n$ posta kutunda", new TextBox(0.1, 0.1, 0.5, 0.2), 0.02)
        {
            Panel = ScreenPhoneCard.PanelPart.Row,
            ListRow = new ScreenPhoneCard.ListRow("Cal", "$ posta kutunda")
            {
                PortraitSpot = new TextBox(0.0, 0.0, 0.25, 0.25),
                FrameSpot = new TextBox(0.0, 0.5, 1.0, 1.0),
            },
        };

    /// <summary>Avatar satır başına bir kez kesilir ve saklanır; seçim ancak art arda iki okumada değişir; mavi çerçeve bulunur.</summary>
    [Fact]
    public void ListLookCutsTheAvatarOnceAndVotesForTheSelection()
    {
        const int size = 64;
        (int R, int G, int B) Plain(int x, int y) => (200, 60, 60);
        (int R, int G, int B) Other(int x, int y) => (20, 200, 20);
        // Alt yarıda bir sıra belirgin mavi (seçim çerçevesi).
        (int R, int G, int B) Framed(int x, int y) => y is >= 40 and < 44 ? (30, 110, 224) : (200, 60, 60);
        var look = new PhoneListLook();
        var first = look.Apply([ListItem()], size, size, Plain)[0].ListRow!;
        Assert.NotNull(first.Avatar);
        Assert.StartsWith("data:image/png;base64,", first.Avatar);
        Assert.Null(first.Selected);
        // Avatar saklanır: başka renkli karede de aynı resim.
        var second = look.Apply([ListItem()], size, size, Other)[0].ListRow!;
        Assert.Equal(first.Avatar, second.Avatar);
        // Seçim tek okumada değişmez, art arda ikincisinde değişir.
        Assert.Null(look.Apply([ListItem()], size, size, Framed)[0].ListRow!.Selected);
        Assert.Equal("#1E6EE0", look.Apply([ListItem()], size, size, Framed)[0].ListRow!.Selected);
        // Temizlenince yeniden kesilir (ilk görülen satırda seçim hemen geçer).
        look.Clear();
        var fresh = look.Apply([ListItem()], size, size, Other)[0].ListRow!;
        Assert.NotEqual(first.Avatar, fresh.Avatar);
        Assert.Null(fresh.Selected);
        Assert.Equal("#1E6EE0", PhoneListLook.FrameColor(new TextBox(0, 0.5, 1, 1), size, size, Framed));
        Assert.Null(PhoneListLook.FrameColor(new TextBox(0, 0, 1, 0.5), size, size, Framed));
        // Avatar en çok AvatarMax piksel.
        Assert.True(PhoneListLook.AvatarMax == 48 && PhoneListLook.BadgeMax == 32);
    }
}
