// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// "Ekranı çevir": stil eşleşmeli yerinde çizim, GTA 6 telefon kartı ve yeniden basınca ekranın değişip değişmediği.
/// Telefonun satır kuralları ortak deneme dosyasından (core/Tests/CouchSubsCoreTests/Fixtures/phone-chat.json; Mac
/// ScreenPhoneCardTests.swift ve Android ScreenPhoneCardTest.kt aynı dosyayı okur).
/// </summary>
public class ScreenPhoneCardTests
{
    private static readonly TextBox Phone = new(0.72, 0.30, 0.96, 0.92);
    private static readonly double[] Upright = [0.78, 0.17, 0.78, 0.85];

    private static JsonElement Vectors() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("phone-chat.json"))).RootElement;

    private static double[] Numbers(JsonElement array) => [.. array.EnumerateArray().Select(value => value.GetDouble())];

    private static TextBox Box(double[] v) => new(v[0], v[1], v[2], v[3]);

    private static ScreenPhoneCard.Handset Handset(double[] pose, double aspect = 16.0 / 9) =>
        new(new GamePhoneGeometry.Pose(pose[0], pose[1], pose[2], pose[3]), aspect);

    private static string Name(ScreenPhoneCard.Role role) => role.ToString().ToLowerInvariant();

    private static ScreenTranslation.Item Item(string source, string translation, double left, double top, double right, bool unchanged = false) =>
        new(source, translation, new TextBox(left, top, right, top + 0.03), 0.025) { Unchanged = unchanged };

    private static ScreenTranslation.Item OnPhone(string source, string translation, ScreenPhoneCard.Role role, double top,
                                                  double left = 0.1, double right = 0.7, bool unchanged = false) =>
        new(source, translation, new TextBox(0.8, 0.2 + top * 0.6, 0.9, 0.22 + top * 0.6), 0.018)
        {
            Unchanged = unchanged, Phone = new ScreenPhoneCard.Placement(role, new TextBox(left, top, right, top + 0.03)),
        };

    /// <summary>
    /// Kartsız (varsayılan ayar): her mesajın çevirisi kendi balonunun yerinde, kart zemini yok; kişi adı çevrilmediği için
    /// özgün hâli görünür kalır; telefon dışındaki yazı balon sayılmaz (Mac ile aynı).
    /// </summary>
    [Fact]
    public void WithoutTheCardEachMessageStaysOnItsOwnBubble()
    {
        var incoming = OnPhone("Where are you man", "Neredesin adamım", ScreenPhoneCard.Role.Incoming, 0.2);
        var outgoing = OnPhone("On my way", "Yoldayım", ScreenPhoneCard.Role.Outgoing, 0.3, 0.6, 0.93);
        var shown = ScreenTranslation.Present([
            Item("Find the car", "Arabayı bul", 0.30, 0.10, 0.50),
            OnPhone("Brian", "Brian", ScreenPhoneCard.Role.Header, 0.06, unchanged: true), incoming, outgoing,
        ], Handset(Upright), card: false);
        Assert.Equal(["Arabayı bul", "Neredesin adamım", "Yoldayım"], shown.Select(item => item.Translation));
        Assert.Equal([false, true, true], shown.Select(item => item.Bubble));
        Assert.DoesNotContain(shown, ScreenPhoneCard.IsBackdrop);
        Assert.Equal(incoming.Box, shown[1].Box);
        Assert.Equal(outgoing.Box, shown[2].Box);
    }

    /// <summary>
    /// Çeviriler balonların üstündeyken sohbet kayınca/değişince ilk yoklamada kalkar (Hide), durulunca yeniden çevrilir;
    /// kartlı izleme eskisi gibi bekler (Mac ile aynı).
    /// </summary>
    [Fact]
    public void InPlaceTranslationsLeaveAsSoonAsTheChatMoves()
    {
        byte[] a = [.. Enumerable.Repeat((byte)40, 768)], b = [.. Enumerable.Repeat((byte)200, 768)];
        var place = new TextBox(0.6, 0.2, 0.8, 0.85);
        var inPlace = new ScreenPhoneFollow { HidesOnChange = true };
        var card = new ScreenPhoneFollow();
        inPlace.Settled(place, a);
        card.Settled(place, a);
        Assert.Equal(ScreenPhoneFollow.Step.Keep, inPlace.Next(place, a));
        Assert.Equal(ScreenPhoneFollow.Step.Hide, inPlace.Next(place, b));
        Assert.Equal(ScreenPhoneFollow.Step.Refresh, inPlace.Next(place, b));
        Assert.Equal(ScreenPhoneFollow.Step.Wait, card.Next(place, b));
        Assert.Equal(ScreenPhoneFollow.Step.Refresh, card.Next(place, b));
    }

    [Fact]
    public void SharedChatVectors()
    {
        foreach (var vector in Vectors().GetProperty("cases").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString();
            var phone = Handset(Numbers(vector.GetProperty("pose")), vector.GetProperty("aspect").GetDouble());
            var reading = new Reading(vector.GetProperty("lines").EnumerateArray()
                .Select(line => new TextLine(line.GetProperty("text").GetString()!, Box(Numbers(line.GetProperty("box"))))));
            var groups = ScreenTranslation.ScreenGroups(reading, phone);
            Assert.All(groups, group => Assert.NotNull(group.Phone));
            var expected = vector.GetProperty("groups").EnumerateArray()
                .Select(pair => $"{pair[0].GetString()}|{pair[1].GetString()}").ToList();
            Assert.True(expected.SequenceEqual(groups.Select(group => $"{Name(group.Phone!.Role)}|{string.Join('\n', group.Paragraphs)}")),
                $"{name}: {string.Join(" / ", groups.Select(group => $"{Name(group.Phone!.Role)}|{string.Join('\n', group.Paragraphs)}"))}");
        }
    }

    [Fact]
    public void SharedEdgeAndFlatVectors()
    {
        var all = Vectors();
        var outside = all.GetProperty("outside");
        var phone = Handset(Numbers(outside.GetProperty("pose")), outside.GetProperty("aspect").GetDouble());
        foreach (var entry in outside.GetProperty("boxes").EnumerateArray())
            Assert.Equal(entry.GetProperty("inside").GetBoolean(), PhoneChat.OnScreen(phone.Flat(Box(Numbers(entry.GetProperty("box"))))));
        foreach (var entry in all.GetProperty("flat").EnumerateArray())
        {
            var spot = Handset(Numbers(entry.GetProperty("pose")), entry.GetProperty("aspect").GetDouble())
                .Flat(Box(Numbers(entry.GetProperty("box"))));
            var flat = Numbers(entry.GetProperty("flat"));
            Assert.InRange(spot.Left, flat[0] - 0.02, flat[0] + 0.02);
            Assert.InRange(spot.Right, flat[2] - 0.02, flat[2] + 0.02);
            Assert.InRange((spot.Top + spot.Bottom) / 2, (flat[1] + flat[3]) / 2 - 0.006, (flat[1] + flat[3]) / 2 + 0.006);
            Assert.InRange(spot.Bottom - spot.Top, flat[3] - flat[1] - 0.012, flat[3] - flat[1] + 0.012);
        }
        foreach (var entry in all.GetProperty("cards").EnumerateArray())
        {
            var avoid = entry.TryGetProperty("avoid", out var others)
                ? others.EnumerateArray().Select(other => Box(Numbers(other))).ToList() : [];
            var card = ScreenPhoneCard.CardBox(Box(Numbers(entry.GetProperty("phone"))), avoid);
            var expected = Numbers(entry.GetProperty("card"));
            Assert.Equal(expected[0], card.Left, 9);
            Assert.Equal(expected[1], card.Top, 9);
            Assert.Equal(expected[2], card.Right, 9);
            Assert.Equal(expected[3], card.Bottom, 9);
        }
    }

    [Fact]
    public void PhoneMessagesBecomeACardBesideThePhone()
    {
        var phone = Handset(Upright);
        var laid = ScreenTranslation.Present([
            Item("Find the car", "Arabayı bul", 0.30, 0.10, 0.50),
            OnPhone("Brian", "Brian", ScreenPhoneCard.Role.Header, 0.06, unchanged: true),
            OnPhone("Where are you man", "Neredesin adamım", ScreenPhoneCard.Role.Incoming, 0.2),
            OnPhone("On my way", "Yoldayım", ScreenPhoneCard.Role.Outgoing, 0.3, 0.6, 0.93),
        ], phone);
        Assert.Equal("Arabayı bul", laid[0].Translation);
        Assert.Equal(5, laid.Count);
        var backdrop = laid[1];
        Assert.True(ScreenPhoneCard.IsBackdrop(backdrop));
        Assert.Equal(phone.Bounds.Top, backdrop.Box.Top);
        Assert.Equal(phone.Bounds.Bottom, backdrop.Box.Bottom);
        Assert.True(backdrop.Box.Right < phone.Bounds.Left);
        // Kişi adı çevrilmese de kartın başlığıdır: ortalı, kalın; yazı TV'de okunacak boyda.
        Assert.Equal("Brian", laid[2].Translation);
        Assert.Equal("center", laid[2].Look?.Align);
        Assert.True(laid[2].Look?.Bold);
        Assert.Equal(ScreenPhoneCard.MinLine, laid[2].LineHeight);
        var width = backdrop.Box.Right - backdrop.Box.Left;
        Assert.Equal(ScreenPhoneCard.IncomingColor, laid[3].Style);
        Assert.Equal(backdrop.Box.Left + width * 0.05, laid[3].Box.Left, 9);
        Assert.Equal(ScreenPhoneCard.OutgoingColor, laid[4].Style);
        Assert.Equal("right", laid[4].Look?.Align);
        Assert.Equal(backdrop.Box.Right - width * 0.05, laid[4].Box.Right, 9);
        // Satırlar üst üste binmez ve kartın içinde kalır.
        for (var i = 2; i + 1 < laid.Count; i++) Assert.True(laid[i].Box.Bottom <= laid[i + 1].Box.Top);
        Assert.All(laid.Skip(2), item => Assert.True(item.Box.Left >= backdrop.Box.Left && item.Box.Right <= backdrop.Box.Right
            && item.Box.Top >= backdrop.Box.Top && item.Box.Bottom <= backdrop.Box.Bottom));
    }

    [Fact]
    public void FullCardDropsTheOldestMessagesAndKeepsTheNewest()
    {
        var text = string.Concat(Enumerable.Repeat("Bu çok uzun bir mesajın Türkçesi ", 4));
        var items = Enumerable.Range(0, 9).Select(i => OnPhone($"message {i}", $"{i} {text}",
            i % 2 == 0 ? ScreenPhoneCard.Role.Incoming : ScreenPhoneCard.Role.Outgoing, 0.1 + i * 0.09)).ToList();
        var laid = ScreenPhoneCard.Layout(items, Handset(Upright));
        var card = laid[0].Box;
        var rows = laid.Skip(1).ToList();
        Assert.True(rows.Count < 9);
        Assert.Equal("message 8", rows[^1].Source);
        for (var i = 0; i + 1 < rows.Count; i++) Assert.True(rows[i].Box.Bottom <= rows[i + 1].Box.Top + 1e-9);
        Assert.True(rows[^1].Box.Bottom <= card.Bottom);
        Assert.True(rows[0].Box.Top >= card.Top);
    }

    [Fact]
    public void AmbiguousBubbleSideComesFromItsColorAndListRowsAreLeftAligned()
    {
        var blue = OnPhone("Sure thing", "Tabii", ScreenPhoneCard.Role.Message, 0.2, 0.05, 0.96) with
        {
            Style = new PhoneTextStyle("#1E6FE0", "#FFFFFF"),
        };
        var gray = OnPhone("Ok then", "Peki", ScreenPhoneCard.Role.Message, 0.4, 0.05, 0.96) with
        {
            Style = new PhoneTextStyle("#E5E5EA", "#000000"),
        };
        var laid = ScreenPhoneCard.Layout([blue, gray, OnPhone("Lucia", "Lucia", ScreenPhoneCard.Role.Contact, 0.6, unchanged: true),
            OnPhone("You coming?", "Geliyor musun?", ScreenPhoneCard.Role.Preview, 0.65)], Handset(Upright));
        Assert.Equal(ScreenPhoneCard.OutgoingColor, laid[1].Style);
        Assert.Equal(ScreenPhoneCard.IncomingColor, laid[2].Style);
        Assert.True(laid[3].Look?.Bold);
        Assert.Equal("left", laid[3].Look?.Align);
        Assert.Equal(ScreenPhoneCard.CardColor, laid[4].Style);
    }

    [Fact]
    public void HomeScreenIsTranslatedInPlaceWithoutACard()
    {
        // Telefonun ana ekranı sohbet değildir: kart kurulmaz, bileşenin yazıları kendi yerinde kalır, uygulama adı ("WhatUp")
        // çevrilmez. Önceden ana ekran sohbet kartı sayılıyor, çeviri telefonun yanında tek blok oluyordu (X'teki bildirim).
        var vector = Vectors().GetProperty("cases").EnumerateArray().First(c => c.GetProperty("name").GetString()!.StartsWith("ana ekran: bildirim"));
        var phone = Handset(Numbers(vector.GetProperty("pose")), vector.GetProperty("aspect").GetDouble());
        var reading = new Reading(vector.GetProperty("lines").EnumerateArray()
            .Select(line => new TextLine(line.GetProperty("text").GetString()!, Box(Numbers(line.GetProperty("box"))))));
        var groups = ScreenTranslation.ScreenGroups(reading, phone);
        var words = new Dictionary<string, string> { ["Reminders"] = "Hatırlatıcılar", ["10 Notifications"] = "10 Bildirim" };
        var items = groups.Select(group => new ScreenTranslation.Item(group.Paragraphs[0], words[group.Paragraphs[0]], group.Box, group.LineHeight)
        {
            Phone = group.Phone,
        }).ToList();
        var shown = ScreenTranslation.Present(items, phone);
        Assert.Equal(["Hatırlatıcılar", "10 Bildirim"], shown.Select(item => item.Translation));
        Assert.DoesNotContain(shown, ScreenPhoneCard.IsBackdrop);
        Assert.Equal(groups.Select(group => group.Box), shown.Select(item => item.Box));
        Assert.All(shown, item => Assert.True(item.Box.Left >= phone.Bounds.Left && item.Box.Right <= phone.Bounds.Right));
    }

    [Fact]
    public void AutomaticPanelSkipsAppNamesOnTheHomeScreen()
    {
        // Otomatik telefon panelinde (GamePhoneText.Groups, satırların yeri düz ekranda) da ana ekranın uygulama adları ve
        // saat/hava çevrilmez; bileşen ve bildirim yazıları kendi yerinde kalır. Sohbet satırları olduğu gibi kalır (ortak
        // deneme dosyasının panels bölümü; Mac ve Android aynı dosyayı okur).
        foreach (var panel in Vectors().GetProperty("panels").EnumerateArray())
        {
            var reading = new Reading(panel.GetProperty("lines").EnumerateArray().Select(line =>
            {
                var box = Box(Numbers(line.GetProperty("box")));
                return new TextLine(line.GetProperty("text").GetString()!, box) { PhoneBox = box };
            }));
            var expected = panel.GetProperty("groups").EnumerateArray().Select(text => text.GetString()).ToList();
            var groups = GamePhoneText.Groups(reading).Select(group => string.Join('\n', group.Paragraphs)).ToList();
            Assert.True(expected.SequenceEqual(groups), $"{panel.GetProperty("name").GetString()}: {string.Join(" / ", groups)}");
        }
    }

    [Fact]
    public void ShortChatReplyIsNotAHomeScreen()
    {
        var vector = Vectors().GetProperty("cases")[0];
        var lines = vector.GetProperty("lines").EnumerateArray()
            .Select(line => new TextLine(line.GetProperty("text").GetString()!, Box(Numbers(line.GetProperty("box"))))).ToList();
        lines.Add(new TextLine("Ok", new TextBox(0.84, 0.60, 0.86, 0.617)));
        var groups = ScreenTranslation.ScreenGroups(new Reading(lines), Handset(Upright));
        Assert.DoesNotContain(groups, group => group.Phone?.Role == ScreenPhoneCard.Role.Home);
        Assert.Equal(ScreenPhoneCard.Role.Header, groups[0].Phone!.Role);
    }

    [Fact]
    public void CardGoesRightWhenThePhoneIsOnTheLeft()
    {
        var left = Handset([0.20, 0.17, 0.20, 0.85]);
        var laid = ScreenPhoneCard.Layout([OnPhone("Where are you man", "Neredesin adamım", ScreenPhoneCard.Role.Incoming, 0.3)], left);
        Assert.True(laid[0].Box.Left > left.Bounds.Right);
    }

    [Fact]
    public void WithoutATranslatedPhoneTextNothingMovesAndUnchangedItemsAreDropped()
    {
        ScreenTranslation.Item[] items =
            [OnPhone("Donnie", "Donnie", ScreenPhoneCard.Role.Header, 0.06, unchanged: true), Item("Find the car", "Arabayı bul", 0.30, 0.10, 0.50)];
        Assert.Equal(["Arabayı bul"], ScreenTranslation.Present(items, Handset(Upright)).Select(item => item.Translation));
        Assert.Equal(["Arabayı bul"], ScreenTranslation.Present(items, null).Select(item => item.Translation));
    }

    /// <summary>Telefondaki kişi adı çevirmene gitmez ("Rose" → "Gül" olmasın); mesajlar gider.</summary>
    [Fact]
    public void ContactNamesAreNotSentToTheTranslator()
    {
        var vector = Vectors().GetProperty("cases")[0];
        var reading = new Reading(vector.GetProperty("lines").EnumerateArray()
            .Select(line => new TextLine(line.GetProperty("text").GetString()!, Box(Numbers(line.GetProperty("box"))))));
        var groups = ScreenTranslation.ScreenGroups(reading, Handset(Numbers(vector.GetProperty("pose"))));
        Assert.Equal("Brian", ScreenTranslation.Known("Brian", groups[0]));
        Assert.Null(ScreenTranslation.Known("Will do", groups[^1]));
    }

    /// <summary>Çeviriler artık özgün yazının stilinde: koyu kutudaki beyaz yazı koyu zeminde beyaz, BÜYÜK HARF yazı büyük harf.</summary>
    [Fact]
    public async Task TranslationsTakeTheLookOfTheOriginalText()
    {
        var frame = Frame.Blank(400, 60);
        for (var y = 0; y < 60; y++)
            for (var x = 0; x < 400; x++)
            {
                var ink = y is >= 15 and < 45 && x % 10 < 2;
                var p = y * frame.Stride + x * 4;
                (frame.Pixels[p], frame.Pixels[p + 1], frame.Pixels[p + 2], frame.Pixels[p + 3]) =
                    ink ? ((byte)240, (byte)240, (byte)240, (byte)255) : ((byte)30, (byte)22, (byte)20, (byte)255);
            }
        var box = new TextBox(0, 10.0 / 60, 1, 50.0 / 60);
        var items = await ScreenTranslation.TranslateAsync(new Reading([new TextLine("SCROLL THE LIST", box)]), new Fixed("listeyi kaydır"), frame: frame);
        var item = Assert.Single(items);
        Assert.Equal("#14161E", item.Style?.Background);
        Assert.True(item.Look?.Upper);
        Assert.Equal("LİSTEYİ KAYDIR", item.Translation);
    }

    /// <summary>Başka bir sohbete geçince ekranın izi değişir: tuşa yeniden basmak yeni sohbeti çevirir, çevirileri kaldırmaz.</summary>
    [Fact]
    public void AnotherChatIsADifferentScreen()
    {
        static string Screen(params string[] lines) => ScreenTranslation.Fingerprint(new Reading(
            lines.Select((text, i) => new TextLine(text, new TextBox(0.74, 0.35 + i * 0.08, 0.94, 0.38 + i * 0.08)))));
        var donnie = Screen("Donnie", "Where are you man", "Meet me at the docks");
        Assert.True(ScreenTranslation.IsSameScreen(donnie, Screen("Donnie", "Where are you man", "Meet me at the docks")));
        Assert.True(ScreenTranslation.IsSameScreen(donnie, Screen("Donnie", "Where are you rnan", "Meet me at the docks")));
        Assert.False(ScreenTranslation.IsSameScreen(donnie, Screen("Lucia", "Did you get the money", "Call me back")));
        Assert.False(ScreenTranslation.IsSameScreen(donnie, Screen("Donnie", "Where are you man", "Meet me at the docks", "Hurry up")));
        Assert.True(ScreenTranslation.IsSameScreen("", ""));
        Assert.False(ScreenTranslation.IsSameScreen("", donnie));
    }

    /// <summary>Masaüstü pencereleri stilli çevirileri ekran yazısı gibi gösterir; zemin ve stilsiz öğeler listede kalır.</summary>
    [Fact]
    public void DesktopWindowsShowStyledTranslationsAsARegion()
    {
        var look = new TextLook(false, false, "left", false, true);
        var styled = new SubtitleEvent(SubtitleEventKind.Screen, "Yoldayım", 12000, true, Blocks:
            [new ScreenTranslation.Item("", ScreenPhoneCard.BackdropText, Phone, 0.02) { Look = look }, Item("On my way", "Yoldayım", 0.5, 0.5, 0.7) with { Look = look }]);
        var region = ScreenRegions.Styled(styled, apart: true);
        Assert.NotNull(region);
        Assert.Equal(["Yoldayım"], region.Value.Blocks!.Select(item => item.Translation));
        Assert.Null(ScreenRegions.Styled(styled, apart: false));
        Assert.Null(ScreenRegions.Styled(styled with { Blocks = [Item("On my way", "Yoldayım", 0.5, 0.5, 0.7)] }, apart: true));
        Assert.Equal(3.0, ScreenRegions.NextChange(5.0, 3.0));
        Assert.Equal(5.0, ScreenRegions.NextChange(5.0, 0));
        Assert.Equal(3.0, ScreenRegions.NextChange(null, 3.0));
    }

    /// <summary>
    /// Sıkışık balonlar: balonlar arasında en az yarım satır boşluk, hepsi kartın içinde; mesajlar telefon boyuna sığmazsa
    /// kart ekranın kenar payına kadar uzar, yine sığmazsa en eskiler düşer; kartın altında kalan çeviri kartın yanına
    /// alınır (ortak deneme dosyasının layouts bölümü; Mac ve Android aynı sonucu bulur).
    /// </summary>
    [Fact]
    public void SharedLayoutVectors()
    {
        foreach (var vector in Vectors().GetProperty("layouts").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString();
            var phone = Handset(Numbers(vector.GetProperty("pose")));
            var items = new List<ScreenTranslation.Item>();
            if (vector.TryGetProperty("outside", out var outside))
                foreach (var entry in outside.EnumerateArray())
                    items.Add(new ScreenTranslation.Item(entry.GetProperty("source").GetString()!, entry.GetProperty("translation").GetString()!,
                                                         Box(Numbers(entry.GetProperty("box"))), 0.02));
            var outsideCount = items.Count;
            foreach (var message in vector.GetProperty("items").EnumerateArray())
            {
                var top = message.GetProperty("top").GetDouble();
                var role = Enum.Parse<ScreenPhoneCard.Role>(message.GetProperty("role").GetString()!, ignoreCase: true);
                items.Add(new ScreenTranslation.Item(message.GetProperty("source").GetString()!, message.GetProperty("translation").GetString()!,
                                                     new TextBox(0.8, 0.2, 0.9, 0.22), message.GetProperty("line").GetDouble())
                {
                    Unchanged = message.GetProperty("unchanged").GetBoolean(),
                    Phone = new ScreenPhoneCard.Placement(role, new TextBox(message.GetProperty("left").GetDouble(), top,
                                                                           message.GetProperty("right").GetDouble(), top + 0.03)),
                });
            }
            var laid = ScreenPhoneCard.Layout(items, phone);
            var card = laid[outsideCount].Box;
            Assert.True(ScreenPhoneCard.IsBackdrop(laid[outsideCount]), name);
            var rows = laid.Skip(outsideCount + 1).Where(item => item.Phone?.Role != ScreenPhoneCard.Role.Header).ToList();
            var line = rows[0].LineHeight;
            for (var i = 0; i + 1 < rows.Count; i++) Assert.True(rows[i + 1].Box.Top - rows[i].Box.Bottom >= line * 0.5 - 1e-9, name);
            Assert.All(laid.Skip(outsideCount + 1), item => Assert.True(item.Box.Left >= card.Left && item.Box.Right <= card.Right
                && item.Box.Top >= card.Top - 1e-9 && item.Box.Bottom <= card.Bottom + 1e-9, name));
            Assert.True(card.Top >= ScreenPhoneCard.ScreenMargin - 1e-9, name);
            Assert.True(card.Bottom <= 1 - ScreenPhoneCard.ScreenMargin + 1e-9, name);
            Assert.Equal(items[^1].Source, rows[^1].Source);
            for (var i = 0; i < outsideCount; i++) Assert.Equal(0, ScreenPhoneCard.Covered(laid[i].Box, [card]));
            if (vector.TryGetProperty("card", out var expectedCard)) AssertBox(Numbers(expectedCard), card, name);
            if (vector.TryGetProperty("kept", out var kept))
                Assert.True(kept.EnumerateArray().Select(value => value.GetString()).SequenceEqual(rows.Select(row => row.Source)),
                            $"{name}: {string.Join(", ", rows.Select(row => row.Source))}");
            if (vector.TryGetProperty("moved", out var moved))
            {
                var index = 0;
                foreach (var expected in moved.EnumerateArray()) AssertBox(Numbers(expected), laid[index++].Box, name);
            }
        }
    }

    private static void AssertBox(double[] expected, TextBox got, string? name)
    {
        double[] values = [got.Left, got.Top, got.Right, got.Bottom];
        for (var i = 0; i < 4; i++)
            Assert.True(Math.Abs(values[i] - expected[i]) <= 1e-6, $"{name}: [{string.Join(", ", values)}]");
    }

    /// <summary>
    /// Kart ekrandayken telefon izlenir: sohbet değişip durulunca yeniden çevrilir, değişmeyen telefonda kart kalır, telefon
    /// kapanınca kart kalkar; tek karelik ıska kartı kaldırmaz (ortak deneme dosyasının follow bölümü).
    /// </summary>
    [Fact]
    public void SharedFollowVectors()
    {
        static byte[] Signature(JsonElement spec)
        {
            var v = Numbers(spec);
            return [.. Enumerable.Range(0, 768).Select(i => (byte)(i < v[1] ? v[2] : v[0]))];
        }
        foreach (var vector in Vectors().GetProperty("follow").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString();
            var follow = new ScreenPhoneFollow();
            var index = 0;
            foreach (var step in vector.GetProperty("steps").EnumerateArray())
            {
                index++;
                if (step.TryGetProperty("settle", out var settle))
                {
                    follow.Settled(Box(Numbers(settle)), Signature(step.GetProperty("sig")));
                    continue;
                }
                var phone = step.GetProperty("phone");
                var got = phone.ValueKind == JsonValueKind.Null ? follow.Next(null, null)
                    : follow.Next(Box(Numbers(phone)), Signature(step.GetProperty("sig")));
                Assert.True(step.GetProperty("expect").GetString() == got.ToString().ToLowerInvariant(), $"{name} #{index - 1}: {got}");
            }
        }
    }

    /// <summary>
    /// Başka bir sohbete geçip dönünce eski sohbetin mesajları çevirmene yeniden gitmez: çeviriler sohbetin başlığıyla
    /// saklanır (PhoneChatMemory; ortak deneme dosyasının switch bölümü). Tek tek ve toplu çeviren motorda aynı.
    /// </summary>
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SwitchingChatsReusesTheirTranslations(bool together)
    {
        var all = Vectors();
        var plan = all.GetProperty("switch");
        var cases = all.GetProperty("cases").EnumerateArray().ToList();
        var memory = new PhoneChatMemory();
        var first = new Dictionary<string, string[]>();
        var expected = plan.GetProperty("calls").EnumerateArray().Select(value => value.GetInt32()).ToList();
        var index = 0;
        foreach (var chat in plan.GetProperty("chats").EnumerateArray().Select(value => value.GetString()!))
        {
            var vector = cases.First(c => c.GetProperty("name").GetString() == chat);
            var reading = new Reading(vector.GetProperty("lines").EnumerateArray()
                .Select(line => new TextLine(line.GetProperty("text").GetString()!, Box(Numbers(line.GetProperty("box"))))));
            var translator = new Counting(together);
            var items = await ScreenTranslation.TranslateAsync(reading, translator, memory: memory,
                handset: Handset(Numbers(vector.GetProperty("pose")), vector.GetProperty("aspect").GetDouble()));
            Assert.True(expected[index] == translator.Calls, $"{chat}: {translator.Calls}");
            index++;
            var texts = items.Select(item => item.Translation).ToArray();
            if (first.TryGetValue(chat, out var before)) Assert.Equal(before, texts);
            else first[chat] = texts;
        }
    }

    private sealed class Counting(bool together) : ITextTranslator
    {
        public int Calls;
        public bool TranslatesTogether => together;

        public Task<string> TranslateAsync(string source, CancellationToken cancellationToken = default)
        {
            Calls++;
            return Task.FromResult("TR " + source);
        }

        public Task<IReadOnlyList<string>> TranslateAllAsync(IReadOnlyList<string> sources, CancellationToken cancellationToken = default)
        {
            Calls += sources.Count;
            return Task.FromResult<IReadOnlyList<string>>([.. sources.Select(source => "TR " + source)]);
        }
    }

    /// <summary>
    /// Telefonun ekranındaki satırlar altyazı hattına girmez; telefonun önünden/altından geçen geniş altyazı girer
    /// (gerçek kare gta6-telefon-sohbet-2'nin telefonu; Mac ile aynı).
    /// </summary>
    [Fact]
    public void HoldsOnlyTheLinesOnThePhoneScreen()
    {
        var phone = Handset([0.50375, 0.12444, 0.46125, 0.68444]);
        Assert.True(ScreenPhoneCard.Holds(Box([0.39415, 0.47436, 0.54888, 0.52616]), phone));
        Assert.True(ScreenPhoneCard.Holds(Box([0.47965, 0.17571, 0.5218, 0.19897]), phone));
        Assert.True(ScreenPhoneCard.Holds(Box([0.3974, 0.74924, 0.4632, 0.79995]), phone));
        Assert.False(ScreenPhoneCard.Holds(Box([0.30, 0.86, 0.70, 0.91]), phone));
        Assert.False(ScreenPhoneCard.Holds(Box([0.46, 0.90, 0.54, 0.94]), phone));
        Assert.False(ScreenPhoneCard.Holds(Box([0.949, 0.93197, 0.99577, 0.95692]), phone));
    }

    private sealed class Fixed(string text) : ITextTranslator
    {
        public Task<string> TranslateAsync(string source, CancellationToken cancellationToken = default) => Task.FromResult(text);
    }
}
