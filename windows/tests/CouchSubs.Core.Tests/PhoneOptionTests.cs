// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// X (26 Kas, beta.104, Windows + PS Remote Play): GTA 6 telefon sohbetinde en üstteki uzun mesaj çizilmiyordu, alttaki iki
/// cevap seçeneğinden biri sarı giden balon, öbürü soluk ortalı not olarak karışık görünüyordu. Ortak deneme dosyasının
/// <c>roles</c> bölümü (Mac PhoneOptionTests.swift, Android PhoneOptionTest.kt aynı durumlar).
/// </summary>
public class PhoneOptionTests
{
    private static JsonElement Vectors() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("phone-chat.json"))).RootElement;

    private static TextBox Box(JsonElement array)
    {
        var v = array.EnumerateArray().Select(value => value.GetDouble()).ToArray();
        return new TextBox(v[0], v[1], v[2], v[3]);
    }

    /// <summary>Otomatik telefon okuması: en üstteki mesaj (başlık okunmasa da) balon, her cevap seçeneği kendi satırı.</summary>
    [Fact]
    public void SharedRoleVectors()
    {
        foreach (var panel in Vectors().GetProperty("roles").EnumerateArray())
        {
            var reading = new Reading(panel.GetProperty("lines").EnumerateArray().Select(line =>
            {
                var box = Box(line.GetProperty("box"));
                return new TextLine(line.GetProperty("text").GetString()!, box) { PhoneBox = box };
            }));
            var expected = panel.GetProperty("groups").EnumerateArray()
                .Select(pair => $"{pair[0].GetString()}|{pair[1].GetString()}").ToList();
            var groups = GamePhoneText.Groups(GamePhoneText.ForTranslation(reading))
                .Select(group => $"{group.Phone?.Role.ToString().ToLowerInvariant() ?? "-"}|{string.Join('\n', group.Paragraphs)}").ToList();
            Assert.True(expected.SequenceEqual(groups), $"{panel.GetProperty("name").GetString()}: {string.Join(" / ", groups)}");
        }
    }

    /// <summary>Not yalnız kısa etiket; ortalı cümle cevap seçeneğidir.</summary>
    [Fact]
    public void CenteredSentenceIsAnOptionNotANote()
    {
        static PhoneChat.Row Row(string text, double left, double right) => new([], new TextBox(left, 0.8, right, 0.82), text);
        Assert.Equal(ScreenPhoneCard.Role.Note, PhoneChat.RoleOf([Row("Today 9:41 PM", 0.38, 0.62)]));
        Assert.Equal(ScreenPhoneCard.Role.Note, PhoneChat.RoleOf([Row("New messages", 0.32, 0.66)]));
        Assert.Equal(ScreenPhoneCard.Role.Option, PhoneChat.RoleOf([Row("Thanks for the heads up.", 0.21, 0.77)]));
        Assert.Equal(ScreenPhoneCard.Role.Option, PhoneChat.RoleOf([Row("Yeah I don't need your", 0.3, 0.7), Row("opinion thanks.", 0.3, 0.6)]));
        Assert.Equal([ScreenPhoneCard.Role.Incoming, ScreenPhoneCard.Role.Option, ScreenPhoneCard.Role.Option],
            PhoneChat.WithOptions([ScreenPhoneCard.Role.Incoming, ScreenPhoneCard.Role.Outgoing, ScreenPhoneCard.Role.Option]));
        Assert.Equal([ScreenPhoneCard.Role.Outgoing, ScreenPhoneCard.Role.Incoming, ScreenPhoneCard.Role.Option],
            PhoneChat.WithOptions([ScreenPhoneCard.Role.Outgoing, ScreenPhoneCard.Role.Incoming, ScreenPhoneCard.Role.Option]));
        Assert.Equal([ScreenPhoneCard.Role.Incoming, ScreenPhoneCard.Role.Outgoing, ScreenPhoneCard.Role.Note],
            PhoneChat.WithOptions([ScreenPhoneCard.Role.Incoming, ScreenPhoneCard.Role.Outgoing, ScreenPhoneCard.Role.Note]));
    }

    /// <summary>Yanda Panel: seçenekler oyuncunun tarafında ayrı balonlar, ikisi de aynı renkte.</summary>
    [Fact]
    public void OptionsShareOneLookInThePanel()
    {
        var handset = new ScreenPhoneCard.Handset(new GamePhoneGeometry.Pose(0.6087, 0.1026, 0.5528, 0.8395), 16.0 / 9);
        static ScreenTranslation.Item Make(string text, ScreenPhoneCard.Role role, double top, PhoneTextStyle? style) =>
            new(text, text + " (tr)", new TextBox(0.5, top, 0.62, top + 0.03), 0.016)
            {
                Phone = new ScreenPhoneCard.Placement(role, new TextBox(0.2, top, 0.8, top + 0.03)), Style = style,
            };
        var blue = new PhoneTextStyle("#3058D0", "#FFFFFF");
        var laid = ScreenPhoneCard.Layout([Make("Hello there friend", ScreenPhoneCard.Role.Incoming, 0.4, null),
                                           Make("Thanks for the heads up.", ScreenPhoneCard.Role.Option, 0.65, GamePhonePalette.Neutral),
                                           Make("Yeah I don't need your opinion thanks.", ScreenPhoneCard.Role.Option, 0.72, blue)], handset);
        var options = laid.Where(item => item.Source != "Hello there friend" && !ScreenPhoneCard.IsBackdrop(item)).ToList();
        Assert.Equal(2, options.Count);
        Assert.All(options, item => Assert.Equal(ScreenPhoneCard.PanelPart.Mine, item.Panel));
        Assert.All(options, item => Assert.Equal("right", item.Look?.Align));
        Assert.Equal(blue, options[0].Style);
        Assert.Equal(blue, options[1].Style);
        Assert.True(options[0].Box.Bottom < options[1].Box.Top);
    }

    /// <summary>Saydam pencere: uzun ilk mesaj dar sütuna sığmayınca düşmez; sütun genişler (gerekirse yazı küçülür).</summary>
    [Fact]
    public void StackedPanelKeepsTheLongFirstMessage()
    {
        static ScreenTranslation.Item Part(string text, ScreenPhoneCard.PanelPart panel, double top) =>
            new(text, text, new TextBox(0.72, top, 0.9, top + 0.05), 0.03) { Panel = panel };
        var longText = "Seni 10 numaralı odadaki misafirimizle gördüm. Bil diye söylüyorum, misafir kurallarını çiğnediği için "
            + "birçok kez uyarıldı. Onun yüzünden daha fazla belaya girmeni istemem. L.";
        List<ScreenTranslation.Item> items =
        [
            Part(ScreenPhoneCard.BackdropText, ScreenPhoneCard.PanelPart.Card, 0.2) with { Box = new TextBox(0.6, 0.1, 0.9, 0.9), Aligned = true },
            Part("Yeni mesajlar", ScreenPhoneCard.PanelPart.Note, 0.25), Part(longText, ScreenPhoneCard.PanelPart.Theirs, 0.3),
            Part("DAHA FAZLA yazım hatasıydı. Tabii ki HERHANGİ BİR sorun demek istedim.", ScreenPhoneCard.PanelPart.Theirs, 0.55),
            Part("Haber verdiğin için sağ ol.", ScreenPhoneCard.PanelPart.Mine, 0.65),
            Part("Evet, senin fikrine ihtiyacım yok, sağ ol.", ScreenPhoneCard.PanelPart.Mine, 0.72),
        ];
        var panel = ScreenPhoneCard.PanelOf(items)!;
        var stacked = ScreenPhoneCard.Stacked(panel, 1600, 420, 20);
        Assert.Equal(panel.Messages.Select(item => item.Translation), stacked.Messages.Select(item => item.Translation));
        Assert.True(stacked.Messages[^1].Box.Bottom <= 1 + 1e-9);
        Assert.True(stacked.Card.Box.Right - stacked.Card.Box.Left > ScreenPhoneCard.StackedShare);
        Assert.Equal(stacked.Messages, ScreenPhoneCard.Stacked(panel, 1600, 420, 20).Messages);
        var roomy = ScreenPhoneCard.Stacked(panel, 1600, 1600, 20);
        Assert.Equal(20, roomy.Card.LineHeight * 1600 * 0.85, 9);
        Assert.Equal(400, (roomy.Card.Box.Right - roomy.Card.Box.Left) * 1600, 6);
        Assert.Equal(panel.Messages.Count, roomy.Messages.Count);
    }

    /// <summary>Günlük: okunan satırların türü ve ilk sözcükleri; özet değişince, en çok 5 sn'de bir.</summary>
    [Fact]
    public void RowSummaryAndRateLimit()
    {
        static ScreenTranslation.Group Make(string text, ScreenPhoneCard.Role role) =>
            new([text], new TextBox(0, 0, 1, 0.1), 0.02) { Phone = new ScreenPhoneCard.Placement(role, new TextBox(0, 0, 1, 0.1)) };
        List<ScreenTranslation.Group> groups = [Make("Linda", ScreenPhoneCard.Role.Header),
            Make("I saw you with our guest from room 10.", ScreenPhoneCard.Role.Incoming),
            Make("Thanks for the heads up.", ScreenPhoneCard.Role.Option), Make("New messages", ScreenPhoneCard.Role.Note)];
        Assert.Equal("header: Linda | bubble: I saw you with… | option: Thanks for the heads… | note: New messages",
            PhoneChat.RowSummary(groups));
        var log = new PhoneRowsLog();
        Assert.Equal("telefon satırları: " + PhoneChat.RowSummary(groups), log.Line(groups, 1_000));
        Assert.Null(log.Line(groups, 20_000));
        Assert.Null(log.Line(groups.Take(2).ToList(), 2_000));
        Assert.NotNull(log.Line(groups.Take(2).ToList(), 7_000));
        Assert.Null(log.Line([], 30_000));
    }
}
