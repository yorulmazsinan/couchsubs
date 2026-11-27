// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Menüde çevirinin biçimi ayardan gelir (#1365, <see cref="MenuLayout"/>): B üstünü örter, A Türkçeyi yanına koyu etikete
/// yazar (yanına sığmazsa altına/üstüne, şerit bir bütün), görev kartının ikizi kartın altında. Ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/menu-layout.json (Mac MenuLayoutTests.swift, Android MenuLayoutTest.kt aynı).
/// </summary>
public class MenuLayoutTests
{
    private static TextBox Box(JsonElement e)
    {
        var v = e.EnumerateArray().Select(x => x.GetDouble()).ToArray();
        return new TextBox(v[0], v[1], v[2], v[3]);
    }

    private static void Near(TextBox expected, TextBox? actual, string what)
    {
        Assert.True(actual is not null, $"{what}: kutu yok");
        var a = actual!.Value;
        var ok = Math.Abs(a.Left - expected.Left) < 1e-6 && Math.Abs(a.Top - expected.Top) < 1e-6
            && Math.Abs(a.Right - expected.Right) < 1e-6 && Math.Abs(a.Bottom - expected.Bottom) < 1e-6;
        Assert.True(ok, $"{what}: beklenen {expected}, çıkan {a}");
    }

    [Fact]
    public void SharedCases()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("menu-layout.json")));
        Assert.Equal(MenuLayout.LabelColor, document.RootElement.GetProperty("labelColor").GetString());
        foreach (var c in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            var id = c.GetProperty("id").GetString()!;
            var items = c.GetProperty("items").EnumerateArray().ToList();
            var paints = items.Select(i => new TextPaint(i.GetProperty("bg").GetString()!, i.GetProperty("line").GetDouble(),
                                                          Box(i.GetProperty("cover")))
            {
                IconSide = i.TryGetProperty("icon", out var icon) ? icon.GetString() : null,
                // Ölçümün seçtiği kip ne olursa olsun kilitlenir.
                Mode = PaintMode.Twin, Spot = Box(i.GetProperty("cover")), SpotRoom = Box(i.GetProperty("cover")),
                Twin = new TextBox(0, 0, 1, 1),
            }).ToList();
            var targets = items.Select(i => new TextPainter.Target(Box(i.GetProperty("box")), i.GetProperty("line").GetDouble(), 1,
                                                                   i.GetProperty("bg").GetString()!, "#F0F0F0", false,
                                                                   i.GetProperty("align").GetString()!)).ToList();
            var cards = c.GetProperty("cards").EnumerateArray()
                .Select(card => (IReadOnlyList<int>)card.EnumerateArray().Select(x => x.GetInt32()).ToList()).ToList();
            var result = MenuLayout.Locked(paints, targets, cards, c.GetProperty("cover").GetBoolean(), c.GetProperty("aspect").GetDouble());
            var expect = c.GetProperty("expect").EnumerateArray().ToList();
            Assert.Equal(expect.Count, result.Count);
            for (var k = 0; k < expect.Count; k++)
            {
                var e = expect[k];
                var p = result[k];
                var what = $"{id} / {items[k].GetProperty("name").GetString()}";
                Assert.True(e.GetProperty("mode").GetString() == p.Mode, $"{what}: kip {p.Mode}");
                Near(paints[k].Cover, p.Cover, what + " örtü");
                if (p.Mode == PaintMode.Cover)
                {
                    Assert.Null(p.Spot);
                    Assert.Null(p.Twin);
                    Assert.Null(p.Label);
                    continue;
                }
                Near(Box(e.GetProperty("spot")), p.Spot, what + " spot");
                Near(Box(e.GetProperty("room")), p.SpotRoom, what + " spotRoom");
                if (p.Mode == PaintMode.Beside)
                {
                    Assert.Equal(e.GetProperty("label").GetString(), p.Label);
                    Assert.Null(p.Twin);
                }
                else
                {
                    Near(Box(e.GetProperty("twin")), p.Twin, what + " twin");
                    Assert.Equal(e.GetProperty("bg").GetString(), p.Background);
                    Assert.Null(p.Label);
                }
            }
        }
    }

    /// <summary>
    /// İkiz kartın kişi resmi kareden bulunur (<see cref="TextPainter.CardPortrait(IReadOnlyList{TextBox}, IReadOnlyList{int}, string, double, Frame)"/>):
    /// başlığa yakın resim bulunur; harita, harf taşması ve resimsiz kart resim sayılmaz. Ortak deneme dosyası card-portrait.json.
    /// </summary>
    [Fact]
    public void CardPortraitSharedCases()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("card-portrait.json")));
        var root = document.RootElement;
        int width = root.GetProperty("width").GetInt32(), height = root.GetProperty("height").GetInt32();
        static (int R, int G, int B) Rgb(string hex) =>
            (Convert.ToInt32(hex[1..3], 16), Convert.ToInt32(hex[3..5], 16), Convert.ToInt32(hex[5..7], 16));
        foreach (var c in root.GetProperty("cases").EnumerateArray())
        {
            var id = c.GetProperty("id").GetString()!;
            var rects = c.GetProperty("rects").EnumerateArray()
                .Select(r => (Box: r.GetProperty("box").EnumerateArray().Select(v => v.GetInt32()).ToArray(), Color: Rgb(r.GetProperty("color").GetString()!)))
                .ToList();
            var ground = Rgb(c.GetProperty("base").GetString()!);
            (int R, int G, int B) Color(int x, int y)
            {
                for (var k = rects.Count - 1; k >= 0; k--)
                {
                    var b = rects[k].Box;
                    if (x >= b[0] && x < b[2] && y >= b[1] && y < b[3]) return rects[k].Color;
                }
                return ground;
            }
            var covers = c.GetProperty("covers").EnumerateArray().Select(e =>
            {
                var v = e.EnumerateArray().Select(n => n.GetDouble()).ToArray();
                return new TextBox(v[0] / width, v[1] / height, v[2] / width, v[3] / height);
            }).ToList();
            var card = c.GetProperty("card").EnumerateArray().Select(n => n.GetInt32()).ToList();
            var found = TextPainter.CardPortrait(covers, card, c.GetProperty("background").GetString()!,
                                                 c.GetProperty("line").GetDouble() / height, width, height, Color);
            var expect = c.GetProperty("expect");
            if (expect.ValueKind == JsonValueKind.Null)
            {
                Assert.True(found is null, $"{id}: resim bulunmamalı, bulunan {found}");
                continue;
            }
            var e = expect.EnumerateArray().Select(n => n.GetDouble()).ToArray();
            Near(new TextBox(e[0] / width, e[1] / height, e[2] / width, e[3] / height), found, id);
        }
    }

    /// <summary>İkiz kartta kişi resmi yoksa kareden aranan resim bütün parçalara konur ve ikiz kutu resmi de içine alır.</summary>
    [Fact]
    public void CardTwinTakesTheFoundPortrait()
    {
        var title = new TextPaint("#1E2A5A", 0.04, new TextBox(0.30, 0.30, 0.50, 0.34));
        var body = new TextPaint("#1E2A5A", 0.04, new TextBox(0.24, 0.36, 0.60, 0.44));
        var targets = new[] { title, body }.Select(p => new TextPainter.Target(p.Cover, 0.04, 1, "#1E2A5A", "#F0F0F0", false, "left")).ToList();
        var face = new TextBox(0.24, 0.29, 0.28, 0.35);
        var asked = 0;
        var result = MenuLayout.Locked([title, body], targets, [[0, 1]], cover: false, aspect: 1, (card, fill) =>
        {
            asked++;
            Assert.Equal("#1E2A5A", fill);
            return (face, "data:image/png;base64,AA==");
        });
        Assert.Equal(1, asked);
        foreach (var p in result)
        {
            Assert.Equal(PaintMode.Twin, p.Mode);
            Assert.Equal(face, p.Portrait);
            Assert.Equal("data:image/png;base64,AA==", p.PortraitImage);
            Assert.True(p.Twin!.Value.Left <= face.Left && p.PortraitTwin!.Value.Top > p.Twin.Value.Top - 1e-9, "ikiz resmi içine alır");
        }
        // Görev listesindeki kart ikiz kurulmaz: resim de aranmaz.
        var row = new TextPaint("#1E2A5A", 0.04, new TextBox(0.24, 0.10, 0.40, 0.14));
        var listTargets = targets.Prepend(new TextPainter.Target(row.Cover, 0.04, 1, "#1E2A5A", "#F0F0F0", false, "left")).ToList();
        MenuLayout.Locked([row, title, body], listTargets, [[1, 2]], cover: false, aspect: 1, (_, _) => { asked++; return null; });
        Assert.Equal(1, asked);
    }

    /// <summary>Etiket TV'ye yalnız yanına yazmada gider (eski TV yok sayar).</summary>
    [Fact]
    public void LabelGoesToTheTvOnlyBeside()
    {
        var paint = new TextPaint("#202020", 0.04, new TextBox(0.1, 0.1, 0.2, 0.14))
        {
            Mode = PaintMode.Beside, Spot = new TextBox(0.21, 0.1, 0.31, 0.14), SpotRoom = new TextBox(0.21, 0.1, 0.5, 0.14),
            Label = MenuLayout.LabelColor,
        };
        var json = SubtitleServer.ItemJson(Item(paint), phone: false);
        Assert.Equal(MenuLayout.LabelColor, json["label"]);
        Assert.False(SubtitleServer.ItemJson(Item(MenuLayout.Plain(paint)), phone: false).ContainsKey("label"));
    }

    /// <summary>
    /// Menüde biçim ayardan gelince satırın saklı kipi (<see cref="RegionWatcher.SteadyPaints"/>, menuCover): ayar değişince eski
    /// biçim kalmaz, A'da bir kez örtülen satır örtülü kalmaz, kart ikizi harita düzeninde kalır, menü dışı okumanın kipi menüye
    /// geçmez. Ortak deneme dosyası menu-steady.json (Mac, Android aynı).
    /// </summary>
    [Fact]
    public void MenuRowPaintFollowsTheSetting()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("menu-steady.json")));
        foreach (var sequence in document.RootElement.GetProperty("sequences").EnumerateArray())
        {
            var name = sequence.GetProperty("name").GetString();
            var memory = new Dictionary<string, RegionWatcher.RowPaint>();
            var index = 0;
            foreach (var read in sequence.GetProperty("reads").EnumerateArray())
            {
                var setting = read.GetProperty("menuCover");
                bool? menuCover = setting.ValueKind == JsonValueKind.Null ? null : setting.GetBoolean();
                var rows = read.GetProperty("rows").EnumerateArray().ToList();
                var blocks = rows.Select((row, i) => new RegionWatcher.Block(i, 1, Box(row.GetProperty("box")), 0.04)
                {
                    Paint = SteadyPaint(row.GetProperty("mode").GetString()!, Box(row.GetProperty("box"))),
                }).ToList();
                var output = RegionWatcher.SteadyPaints(blocks, [.. rows.Select(row => row.GetProperty("text").GetString()!)], memory,
                                                        read.GetProperty("map").GetBoolean(), menuCover);
                var expected = read.GetProperty("expected").EnumerateArray().Select(e => e.GetString()).ToList();
                for (var k = 0; k < rows.Count; k++)
                {
                    Assert.True(output[k].Paint?.Mode == expected[k], $"{name} okuma {index}: {rows[k].GetProperty("text").GetString()} ({output[k].Paint?.Mode})");
                    // Taşınan ölçü satırın yeni yerindedir.
                    Assert.True(Math.Abs(output[k].Paint!.Cover.Top - Box(rows[k].GetProperty("box")).Top) < 1e-9, $"{name} okuma {index}");
                }
                index++;
            }
        }
    }

    private static TextPaint SteadyPaint(string mode, TextBox box)
    {
        var paint = new TextPaint("#202020", box.Bottom - box.Top, box);
        double width = box.Right - box.Left, height = box.Bottom - box.Top;
        return mode switch
        {
            "beside" => paint with
            {
                Mode = PaintMode.Beside, Spot = new TextBox(box.Right + 0.01, box.Top, box.Right + 0.01 + width, box.Bottom),
                SpotRoom = new TextBox(box.Right + 0.01, box.Top, box.Right + 0.01 + width, box.Bottom), Label = MenuLayout.LabelColor,
            },
            "twin" => paint with
            {
                Mode = PaintMode.Twin, Twin = new TextBox(box.Left, box.Bottom + 0.01, box.Right, box.Bottom + 0.01 + height),
                Spot = new TextBox(box.Left, box.Bottom + 0.01, box.Right, box.Bottom + 0.01 + height),
            },
            _ => paint with { Mode = PaintMode.Cover },
        };
    }

    private static ScreenTranslation.Item Item(TextPaint paint) =>
        new("Menu", "Menü", paint.Cover, 0.04)
        {
            Style = new PhoneTextStyle("#202020", "#F0F0F0"), Look = new TextLook(false, false, "left", false, false), Paint = paint,
        };
}
