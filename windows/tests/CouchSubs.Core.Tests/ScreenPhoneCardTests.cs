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
    /// Çeviriler balonların üstündeyken sohbet kayınca/değişince ilk yoklamada kalkmaz (elde sallanan telefon, #1253):
    /// durulunca yeniden çevrilir; durulmadan değişmeye devam ederse ikinci yoklamada kalkar. Kartlı izleme gizlemez (Mac
    /// ile aynı).
    /// </summary>
    [Fact]
    public void InPlaceTranslationsLeaveOnlyWhenTheChatKeepsChanging()
    {
        byte[] a = [.. Enumerable.Repeat((byte)40, 768)], b = [.. Enumerable.Repeat((byte)200, 768)];
        byte[] c = [.. Enumerable.Repeat((byte)120, 768)];
        var place = new TextBox(0.6, 0.2, 0.8, 0.85);
        var inPlace = new ScreenPhoneFollow { HidesOnChange = true };
        var card = new ScreenPhoneFollow();
        inPlace.Settled(place, a);
        card.Settled(place, a);
        Assert.Equal(ScreenPhoneFollow.Step.Keep, inPlace.Next(place, a));
        Assert.Equal(ScreenPhoneFollow.Step.Wait, inPlace.Next(place, b));
        Assert.Equal(ScreenPhoneFollow.Step.Refresh, inPlace.Next(place, b));
        inPlace.Settled(place, b);
        Assert.Equal(ScreenPhoneFollow.Step.Wait, inPlace.Next(place, a));
        Assert.Equal(ScreenPhoneFollow.Step.Hide, inPlace.Next(place, c));
        Assert.Equal(ScreenPhoneFollow.Step.Refresh, inPlace.Next(place, c));
        Assert.Equal(ScreenPhoneFollow.Step.Wait, card.Next(place, b));
        Assert.Equal(ScreenPhoneFollow.Step.Wait, card.Next(place, c));
        Assert.Equal(ScreenPhoneFollow.Step.Refresh, card.Next(place, c));
    }

    /// <summary>
    /// Elde sallanan telefonun izi (#1253): ince ızgarada birkaç örnek kayan sohbet, hücre ortalaması ve yatay kaydırmalı
    /// karşılaştırmayla değişmiş sayılmaz; yeni mesajla kayan sohbet değişmiş sayılır (Mac ve Android ile aynı deneme).
    /// </summary>
    [Fact]
    public void SwayingPhoneSignatureStaysTheSame()
    {
        const int width = ReadScheduler.SignatureWidth, height = ReadScheduler.SignatureHeight;
        const int fineWidth = width * ScreenPhoneFollow.SubColumns, fineHeight = height * ScreenPhoneFollow.SubRows;
        // Sohbet: 20 ince satırda bir balon (sırayla solda gri, sağda yeşil), balonun ortasında kelimeler.
        static byte[] Chat(int dx, int dy) => [.. Enumerable.Range(0, fineWidth * fineHeight).Select(index =>
        {
            int x = index % fineWidth - dx, y = index / fineWidth - dy;
            var k = (int)Math.Floor(y / 20.0);
            var r = y - k * 20;
            var (left, right, color) = k % 2 == 0 ? (8, 160, 80) : (96, 248, 140);
            if (r < 4 || r >= 16 || x < left || x >= right) return (byte)25;
            return (byte)(r >= 6 && r < 14 && (x - left) % 32 < 24 ? 200 : color);
        })];
        var still = ScreenPhoneFollow.Average(Chat(0, 0), width, height);
        foreach (var (dx, dy) in new[] { (2, 1), (-4, 1), (6, -1), (3, 0), (-2, -1), (5, 1) })
        {
            var swayed = ScreenPhoneFollow.Average(Chat(dx, dy), width, height);
            Assert.True(ScreenPhoneFollow.ChangedShare(still, swayed) <= ScreenPhoneFollow.ChangeShare, $"{dx},{dy}");
        }
        foreach (var scroll in new[] { 8, 10, 16 })
        {
            var moved = ScreenPhoneFollow.Average(Chat(0, -scroll), width, height);
            Assert.True(ScreenPhoneFollow.ChangedShare(still, moved) > ScreenPhoneFollow.ChangeShare, $"{scroll}");
        }
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

    /// <summary>
    /// Otomatik telefon okumasında Yanda Panel (varsayılan; Mac PhoneRegionSessionTests ile aynı düzen): grupların rolü düz
    /// ekrandaki yerinden (başlık, sola yaslı karşı taraf, sağa yaslı oyuncu); panel telefonun yanında, parçaları JSON'da
    /// "panel" alanıyla; Balonların Üstünde'de aslıyla aynı ad çizilmez, balonlar yerinde.
    /// </summary>
    [Fact]
    public void AutomaticPhoneReadingShowsTheChatInASidePanel()
    {
        ScreenTranslation.Group Spot(string text, double left, double top, double right) =>
            new([text], new TextBox(0.8, 0.2 + top * 0.6, 0.9, 0.22 + top * 0.6), 0.018)
            { Phone = new ScreenPhoneCard.Placement(ScreenPhoneCard.Role.Message, new TextBox(left, top, right, top + 0.04)) };
        var groups = GamePhoneText.Roles([Spot("Lucia", 0.40, 0.05, 0.60), Spot("Reply today.", 0.05, 0.30, 0.55),
                                          Spot("Open the camera.", 0.45, 0.50, 0.95)], home: false);
        Assert.Equal([ScreenPhoneCard.Role.Header, ScreenPhoneCard.Role.Incoming, ScreenPhoneCard.Role.Outgoing],
                     groups.Select(group => group.Phone!.Role));
        var items = new List<ScreenTranslation.Item>
        {
            new("Lucia", "Lucia", groups[0].Box, 0.018) { Phone = groups[0].Phone, Unchanged = true },
            new("Reply today.", "Bugün yanıtla.", groups[1].Box, 0.018) { Phone = groups[1].Phone },
            new("Open the camera.", "Kamerayı aç.", groups[2].Box, 0.018) { Phone = groups[2].Phone },
        };
        var pose = new GamePhoneGeometry.Pose(Upright[0], Upright[1], Upright[2], Upright[3]);
        var panel = RegionWatcher.ArrangedPhone(items, pose, 16.0 / 9, new PhonePanelOptions());
        // Sohbetin üstündeki kişi adı çizilmez (Sinan Bey, beta.100 3400/3402).
        Assert.Equal([ScreenPhoneCard.PanelPart.Card, ScreenPhoneCard.PanelPart.Theirs, ScreenPhoneCard.PanelPart.Mine],
                     panel.Select(item => item.Panel!.Value));
        Assert.Equal([ScreenPhoneCard.BackdropText, "Bugün yanıtla.", "Kamerayı aç."], panel.Select(item => item.Translation));
        var card = panel[0].Box;
        Assert.True(card.Right <= pose.Bounds.Left || card.Left >= pose.Bounds.Right);
        // Örneklenmiş renk yok: yedek renkler; panel hizalı.
        Assert.Equal(ScreenPhoneCard.IncomingColor, panel[1].Style);
        Assert.Equal(ScreenPhoneCard.OutgoingColor, panel[2].Style);
        Assert.True(panel[0].Aligned);
        Assert.True(panel[1].Box.Left < panel[2].Box.Left && panel[1].Box.Top < panel[2].Box.Top);
        Assert.Equal("card", ScreenPhoneCard.PanelPart.Card.Json());

        var bubbles = RegionWatcher.ArrangedPhone(items, pose, 16.0 / 9, new PhonePanelOptions(Enabled: false));
        Assert.Equal(["Bugün yanıtla.", "Kamerayı aç."], bubbles.Select(item => item.Translation));
        Assert.All(bubbles, item => Assert.Null(item.Panel));
        Assert.Equal(1.5, ScreenPhoneCard.TextScale(69), 9);
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
        // Sohbetin üstündeki kişi adı ("Brian") çizilmez (Sinan Bey, beta.100 3400/3402).
        Assert.Equal(4, laid.Count);
        Assert.DoesNotContain(laid, item => item.Translation == "Brian");
        var backdrop = laid[1];
        Assert.True(ScreenPhoneCard.IsBackdrop(backdrop));
        Assert.Equal(phone.Bounds.Top, backdrop.Box.Top);
        Assert.Equal(phone.Bounds.Bottom, backdrop.Box.Bottom);
        Assert.True(backdrop.Box.Right < phone.Bounds.Left);
        Assert.Equal(ScreenPhoneCard.MinLine, laid[2].LineHeight);
        var width = backdrop.Box.Right - backdrop.Box.Left;
        Assert.Equal(ScreenPhoneCard.IncomingColor, laid[2].Style);
        Assert.Equal(backdrop.Box.Left + width * 0.05, laid[2].Box.Left, 9);
        Assert.Equal(ScreenPhoneCard.OutgoingColor, laid[3].Style);
        Assert.Equal("right", laid[3].Look?.Align);
        Assert.Equal(backdrop.Box.Right - width * 0.05, laid[3].Box.Right, 9);
        // Satırlar üst üste binmez ve kartın içinde kalır.
        for (var i = 2; i + 1 < laid.Count; i++) Assert.True(laid[i].Box.Bottom <= laid[i + 1].Box.Top);
        Assert.All(laid.Skip(2), item => Assert.True(item.Box.Left >= backdrop.Box.Left && item.Box.Right <= backdrop.Box.Right
            && item.Box.Top >= backdrop.Box.Top && item.Box.Bottom <= backdrop.Box.Bottom));
    }

    /// <summary>
    /// Hizalı panel (Mac testAlignedPanelPutsEachBubbleAtTheHeightOfItsEnglishBubble ile aynı): her Türkçe balon telefondaki
    /// İngilizce balonuyla aynı yükseklikte (üst kenarı ±birkaç piksel), çakışan balon en az kaydırmayla aşağı itilir; balon
    /// telefonun balon renginde, giden sağa, gelen sola yaslı; kişi adı panelin üstünde küçük başlık; aynı içerik aynı çıktı.
    /// </summary>
    [Fact]
    public void AlignedPanelPutsEachBubbleAtTheHeightOfItsEnglishBubble()
    {
        var phone = Handset(Upright);
        ScreenTranslation.Item Message(string source, string translation, ScreenPhoneCard.Role role, double top, PhoneTextStyle? style) =>
            OnPhone(source, translation, role, (top - phone.Bounds.Top) / (phone.Bounds.Bottom - phone.Bounds.Top)) with
            {
                Box = new TextBox(0.72, top, 0.84, top + 0.02), Style = style,
            };
        var cream = new PhoneTextStyle("#F0E8E0", "#282828");
        var blue = new PhoneTextStyle("#D0D8F0", "#282828");
        var header = OnPhone("Brian", "Brian", ScreenPhoneCard.Role.Header, 0.02, unchanged: true) with { Box = new TextBox(0.76, 0.24, 0.80, 0.26) };
        List<ScreenTranslation.Item> items =
        [
            header,
            Message("Where are you", "Neredesin", ScreenPhoneCard.Role.Incoming, 0.30, cream),
            Message("On my way", "Yoldayım", ScreenPhoneCard.Role.Outgoing, 0.42, blue),
            // Uzun Türkçe: altındaki balonun İngilizcesiyle çakışır, o balon aşağı itilir.
            Message("Bring the stuff", string.Concat(Enumerable.Repeat("Malzemeleri getir hemen ", 6)), ScreenPhoneCard.Role.Incoming, 0.50, cream),
            Message("Ok", "Tamam", ScreenPhoneCard.Role.Outgoing, 0.53, null),
        ];
        var laid = ScreenPhoneCard.Layout(items, phone);
        Assert.Equal(laid, ScreenPhoneCard.Layout(items, phone));
        var panel = ScreenPhoneCard.PanelOf(laid)!;
        Assert.True(panel.Aligned);
        double line = panel.Card.LineHeight, pixel = 1.0 / 1080;
        var rows = panel.Messages;
        double[] english = [0.30, 0.42, 0.50];
        for (var i = 0; i < 3; i++)
            Assert.True(Math.Abs(rows[i].Box.Top + line * ScreenPhoneCard.BubblePadding / 2 - english[i]) <= 3 * pixel, rows[i].Translation);
        Assert.True(rows[3].Box.Top > ScreenPhoneCard.AlignedTop(items[4], line));
        Assert.Equal(rows[2].Box.Bottom + line * ScreenPhoneCard.BubbleSpacing, rows[3].Box.Top, 9);
        Assert.True(panel.Card.Box.Bottom >= rows[3].Box.Bottom);
        Assert.Equal(cream, rows[0].Style);
        Assert.Equal(blue, rows[1].Style);
        Assert.Equal(ScreenPhoneCard.OutgoingColor, rows[3].Style);
        Assert.True(rows[0].Box.Left < rows[1].Box.Left);
        Assert.Equal(rows[1].Box.Right, rows[3].Box.Right, 9);
        // Sohbetin üstündeki kişi adı çizilmez (Sinan Bey, beta.100 3400/3402); balonlar hizalı kalır.
        Assert.Null(panel.Title);
        Assert.DoesNotContain(laid, item => item.Panel == ScreenPhoneCard.PanelPart.Title || item.Translation == header.Translation);
        Assert.Equal(ScreenPhoneCard.IncomingColor, ScreenPhoneCard.BubbleColor(GamePhonePalette.Neutral, ScreenPhoneCard.IncomingColor));
        Assert.Equal("#17181B", ScreenPhoneCard.BubbleColor(new PhoneTextStyle("#F0E8E0", "#E8E0D8"), ScreenPhoneCard.IncomingColor).Foreground);
    }

    /// <summary>
    /// Saydam altyazı penceresi (Mac testStackedPanelInTheOverlayWindowKeepsTheAlignedLook ile aynı): hizalı panelin
    /// görünümü aynen (kartsız balonlar, telefonun balon rengi), balonlar alanın telefon tarafındaki kenarında alt alta,
    /// sırası ve aralıklarıyla; yazı alt sınırın altına inmez, küçülmez; aynı içerik birebir aynı çıktı.
    /// </summary>
    [Fact]
    public void StackedPanelInTheOverlayWindowKeepsTheAlignedLook()
    {
        static ScreenTranslation.Item Part(string text, ScreenPhoneCard.PanelPart panel, double top, double bottom,
                                           PhoneTextStyle? style = null, string align = "left") =>
            new(text, text, new TextBox(0.72, top, 0.9, bottom), 0.03)
            {
                Panel = panel, Style = style, Look = new TextLook(false, false, align, false, true),
            };
        var cream = new PhoneTextStyle("#F0E8E0", "#282828");
        List<ScreenTranslation.Item> items =
        [
            Part(ScreenPhoneCard.BackdropText, ScreenPhoneCard.PanelPart.Card, 0.2, 0.8) with { Aligned = true },
            Part("Brian", ScreenPhoneCard.PanelPart.Title, 0.2, 0.24),
            Part("Neredesin", ScreenPhoneCard.PanelPart.Theirs, 0.30, 0.36, cream),
            // Boşluk 0,6 satır (0,018): saydam pencerede de 0,6 satır kalır.
            Part("Yoldayım", ScreenPhoneCard.PanelPart.Mine, 0.378, 0.438, null, "right"),
            // Okunmayan yazı rengi: zemine göre koyu yazı.
            Part("Tamam", ScreenPhoneCard.PanelPart.Theirs, 0.6, 0.66, new PhoneTextStyle("#F0E8E0", "#E8E0D8")),
        ];
        var panel = ScreenPhoneCard.PanelOf(items)!;
        var stacked = ScreenPhoneCard.Stacked(panel, 1600, 400, 20);
        var again = ScreenPhoneCard.Stacked(ScreenPhoneCard.PanelOf(items)!, 1600, 400, 20);
        Assert.Equal(stacked.Card, again.Card);
        Assert.Equal(stacked.Title, again.Title);
        Assert.Equal(stacked.Messages, again.Messages);
        // Kartsız: hizalı panel olarak çizilir.
        Assert.True(stacked.Aligned);
        var line = stacked.Card.LineHeight;
        Assert.Equal(20, line * 400 * 0.85, 9);
        Assert.Equal(1, stacked.Card.Box.Right, 9);
        Assert.Equal(400, (stacked.Card.Box.Right - stacked.Card.Box.Left) * 1600, 6);
        var rows = stacked.Messages;
        Assert.Equal(["Neredesin", "Yoldayım", "Tamam"], rows.Select(row => row.Translation));
        Assert.Equal(stacked.Card.Box.Left, rows[0].Box.Left, 9);
        Assert.Equal(1, rows[1].Box.Right, 9);
        Assert.Equal(0.6 * line, rows[1].Box.Top - rows[0].Box.Bottom, 9);
        Assert.Equal(ScreenPhoneCard.StackedGapMax * line, rows[2].Box.Top - rows[1].Box.Bottom, 9);
        Assert.Equal(0, stacked.Title!.Box.Top);
        Assert.True(stacked.Title.Box.Bottom < rows[0].Box.Top);
        Assert.Equal(cream, rows[0].Style);
        Assert.Equal(ScreenPhoneCard.OutgoingColor, rows[1].Style);
        Assert.Equal("#17181B", rows[2].Style!.Foreground);
        // Telefon solda: sütun sol kenarda, giden balon sütunun sağında.
        var leftItems = items.ToList();
        leftItems[0] = leftItems[0] with { Box = new TextBox(0.1, 0.2, 0.3, 0.8) };
        var left = ScreenPhoneCard.Stacked(ScreenPhoneCard.PanelOf(leftItems)!, 1600, 400, 20);
        Assert.Equal(0, left.Card.Box.Left);
        Assert.Equal(left.Card.Box.Right, left.Messages[1].Box.Right, 9);
        // Punto alt sınırı.
        var tiny = ScreenPhoneCard.Stacked(panel, 1600, 400, 6);
        Assert.Equal(ScreenPhoneCard.StackedMinFont, tiny.Card.LineHeight * 400 * 0.85, 9);
        // Alan dolarsa yazı küçülmez, en eski mesajlar düşer; son mesaj görünür.
        var shortPanel = ScreenPhoneCard.Stacked(panel, 1600, 90, 20);
        Assert.Equal(20, shortPanel.Card.LineHeight * 90 * 0.85, 9);
        Assert.Equal("Tamam", shortPanel.Messages[^1].Translation);
        Assert.True(shortPanel.Messages.Count < 3);
        Assert.True(shortPanel.Messages[^1].Box.Bottom <= 1 + 1e-9);
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
        // Balon telefondaki balonun renginde (mavi giden, gri gelen); taraf da renkten (Mac ile aynı).
        Assert.Equal(ScreenPhoneCard.PanelPart.Mine, laid[1].Panel);
        Assert.Equal(blue.Style, laid[1].Style);
        Assert.Equal(ScreenPhoneCard.PanelPart.Theirs, laid[2].Panel);
        Assert.Equal(gray.Style, laid[2].Style);
        // Liste satırı (ad + önizleme) tek kart: sola yaslı, telefonun satır kartı renginde (örnek yoksa yedek).
        Assert.Equal(4, laid.Count);
        Assert.Equal(ScreenPhoneCard.PanelPart.Row, laid[3].Panel);
        Assert.Equal("left", laid[3].Look?.Align);
        Assert.Equal("Lucia", laid[3].ListRow?.Name);
        Assert.Equal("Geliyor musun?", laid[3].ListRow?.Preview);
        Assert.Equal("Lucia\nGeliyor musun?", laid[3].Translation);
        Assert.Equal(ScreenPhoneCard.RowColor, laid[3].Style);
    }

    /// <summary>
    /// Telefonun ana ekranı sohbet değildir; uygulama adı ("WhatUp") çevrilmez. Bileşen (başlık + sayaç: "Reminders /
    /// 10 Notifications") telefonun boş tarafında tek kart olur (Sinan Bey, beta.100 3397: bileşen çevrilmiyordu): kalın
    /// başlık, altında sayaç, kartın üstü bileşenin İngilizcesiyle aynı hizada; telefonun üstüne yazılmaz (Mac ile aynı).
    /// </summary>
    [Fact]
    public void HomeScreenWidgetBecomesOneCardBesideThePhone()
    {
        var vector = Vectors().GetProperty("cases").EnumerateArray().First(c => c.GetProperty("name").GetString()!.StartsWith("ana ekran: bildirim"));
        var phone = Handset(Numbers(vector.GetProperty("pose")), vector.GetProperty("aspect").GetDouble());
        var reading = new Reading(vector.GetProperty("lines").EnumerateArray()
            .Select(line => new TextLine(line.GetProperty("text").GetString()!, Box(Numbers(line.GetProperty("box"))))));
        var groups = ScreenTranslation.ScreenGroups(reading, phone);
        var words = new Dictionary<string, string> { ["Reminders"] = "Hatırlatıcılar", ["10 Notifications"] = "10 Bildirim" };
        var items = groups.Select(group => new ScreenTranslation.Item(string.Join('\n', group.Paragraphs),
            string.Join('\n', group.Paragraphs.Select(paragraph => words[paragraph])), group.Box, group.LineHeight)
        {
            Phone = group.Phone,
        }).ToList();
        var shown = ScreenTranslation.Present(items, phone);
        Assert.Equal(shown, ScreenTranslation.Present(items, phone)); // aynı içerik birebir aynı çıktı
        var cards = shown.Where(item => item.Panel == ScreenPhoneCard.PanelPart.Row).ToList();
        var card = Assert.Single(cards);
        var widget = card.ListRow!;
        Assert.True(widget.Widget);
        Assert.Equal("Hatırlatıcılar", widget.Name);
        Assert.Equal("10 Bildirim", widget.Preview);
        Assert.NotNull(widget.PortraitSpot); // bileşenin simgesi kesilir
        Assert.True(card.Box.Right <= phone.Bounds.Left + 1e-9 || card.Box.Left >= phone.Bounds.Right - 1e-9); // kart telefonun yanında
        Assert.Equal(ScreenPhoneCard.AlignedTop(items[0], card.LineHeight), card.Box.Top, 9);
        Assert.True(Math.Abs(card.Box.Top - groups[0].Box.Top) < 0.03); // kart bileşenin hizasında
        var json = SubtitleServer.ItemJson(card, phone: true);
        Assert.Equal("row", json["panel"]);
        var row = Assert.IsType<SortedDictionary<string, object>>(json["row"]);
        Assert.Equal(true, row["widget"]);
        Assert.Equal("Hatırlatıcılar", row["name"]);
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
                // İngilizce balonun karedeki kutusu (hizalı panel bu yüksekliğe dizer).
                var english = message.TryGetProperty("box", out var given) ? Box(Numbers(given)) : new TextBox(0.8, 0.2, 0.9, 0.22);
                items.Add(new ScreenTranslation.Item(message.GetProperty("source").GetString()!, message.GetProperty("translation").GetString()!,
                                                     english, message.GetProperty("line").GetDouble())
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
            for (var i = 0; i + 1 < rows.Count; i++)
            {
                Assert.True(rows[i + 1].Box.Top - rows[i].Box.Bottom >= line * 0.5 - 1e-9, name);
                // Hizalı: balon İngilizce balonunun yüksekliğinde; çakışırsa üsttekinin altına en az kaydırmayla itilir
                // (ekranın alt payına dayanmış panelde satırlar alttan yukarı itilir).
                var wanted = ScreenPhoneCard.AlignedTop(items.First(item => item.Source == rows[i + 1].Source), line);
                if (rows[^1].Box.Bottom < 1 - ScreenPhoneCard.ScreenMargin - 1e-9)
                    Assert.Equal(Math.Max(wanted, rows[i].Box.Bottom + line * ScreenPhoneCard.BubbleSpacing), rows[i + 1].Box.Top, 9);
            }
            Assert.True(laid[outsideCount].Aligned, name);
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
        // [taban, sayı, değer] ya da [taban, sayı, değer, şerit, kayma]: ilk "sayı" örnek "değer", gerisi "taban"; şerit
        // verilirse 64 sütunluk izde "şerit" genişliğinde, "kayma" sütun sağa kaymış dikey şeritler de "değer".
        static byte[] Signature(JsonElement spec)
        {
            var v = Numbers(spec).Select(n => (int)n).ToArray();
            return [.. Enumerable.Range(0, 768).Select(i =>
            {
                if (i < v[1]) return (byte)v[2];
                if (v.Length >= 5 && v[3] > 0 && (i % 64 - v[4] + 64) / v[3] % 2 == 1) return (byte)v[2];
                return (byte)v[0];
            })];
        }
        foreach (var vector in Vectors().GetProperty("follow").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString();
            var hides = vector.TryGetProperty("hides", out var flag) && flag.GetBoolean();
            var follow = new ScreenPhoneFollow { HidesOnChange = hides };
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

    /// <summary>
    /// Doğrulanmamış telefon adayı yalnız ekranının içindeki adsız satırları bekletir: telefonun altındaki satır ve konuşan
    /// adlı altyazı geçer (beta.103 kaçan altyazı; Mac ve Android aynı).
    /// </summary>
    [Fact]
    public void UnconfirmedCandidateHoldsOnlyUnnamedLinesOnItsScreen()
    {
        var phone = Handset([0.50375, 0.12444, 0.46125, 0.68444]);
        Assert.True(ScreenPhoneCard.HoldsUnconfirmed("Kingfishers a message. Hit", Box([0.39415, 0.47436, 0.54888, 0.52616]), phone));
        Assert.False(ScreenPhoneCard.HoldsUnconfirmed("Locating...", Box([0.3974, 0.74924, 0.4632, 0.79995]), phone));
        Assert.False(ScreenPhoneCard.HoldsUnconfirmed("Lucia: Hit the gas", Box([0.39415, 0.47436, 0.54888, 0.52616]), phone));
        Assert.False(ScreenPhoneCard.HoldsUnconfirmed("Get in", Box([0.46, 0.90, 0.54, 0.94]), phone));
    }

    private sealed class Fixed(string text) : ITextTranslator
    {
        public Task<string> TranslateAsync(string source, CancellationToken cancellationToken = default) => Task.FromResult(text);
    }
}
