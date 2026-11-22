// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Ek alanlarda fiilsiz yerlerdeki simgeler (tuş çubuğu, satır başı) ve tuş çubuğu sözlüğü.</summary>
public class FreeButtonIconsTests
{
    private const char M = ButtonIcons.Marker;

    /// <summary>Siyah kare; verilen piksel kutularına beyaz halka çizilir (düğme dairesi gibi).</summary>
    private static Frame Draw(int width, int height, params (int X, int Y, int Size)[] rings)
    {
        var frame = Frame.Blank(width, height);
        foreach (var (x0, y0, size) in rings)
            for (var y = y0; y < y0 + size; y++)
                for (var x = x0; x < x0 + size; x++)
                {
                    var edge = x - x0 < 3 || y - y0 < 3 || x0 + size - x <= 3 || y0 + size - y <= 3;
                    if (!edge) continue;
                    var i = (y * frame.Stride) + (x * 4);
                    frame.Pixels[i] = frame.Pixels[i + 1] = frame.Pixels[i + 2] = 255;
                    frame.Pixels[i + 3] = 255;
                }
        return frame;
    }

    private static TextWord Word(string text, double left, double right) => new(text, new TextBox(left, 0.25, right, 0.75));

    private static TextLine Line(params TextWord[] words) =>
        new(string.Join(' ', words.Select(word => word.Text)), new TextBox(words[0].Box.Left, 0.25, words[^1].Box.Right, 0.75), null, words);

    /// <summary>
    /// Ortak vakalar core/Tests/CouchSubsCoreTests/Fixtures/free-button-icons.json (Mac FreeButtonIconsTests.swift ve
    /// Android FreeButtonIconsTest.kt aynı dosyayı okur).
    /// </summary>
    [Fact]
    public async Task SharedCasesMatchMacAndAndroid()
    {
        using var fixture = System.Text.Json.JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("free-button-icons.json")));
        var root = fixture.RootElement;
        var layout = root.GetProperty("frame");
        int width = layout.GetProperty("width").GetInt32(), height = layout.GetProperty("height").GetInt32();
        int top = layout.GetProperty("top").GetInt32(), size = layout.GetProperty("size").GetInt32();
        static int[] Rgb(System.Text.Json.JsonElement item, string name, int[] fallback) =>
            item.TryGetProperty(name, out var value) ? [.. value.EnumerateArray().Select(v => v.GetInt32())] : fallback;
        var cases = root.GetProperty("cases").EnumerateArray().ToList();
        Assert.True(cases.Count >= 10);
        foreach (var item in cases)
        {
            var name = item.GetProperty("name").GetString()!;
            var background = Rgb(item, "background", [0, 0, 0]);
            var ink = Rgb(item, "ink", [255, 255, 255]);
            var frame = Frame.Blank(width, height);
            void Paint(int x, int y, int[] color)
            {
                var i = (y * frame.Stride) + (x * 4);
                frame.Pixels[i] = (byte)color[2];
                frame.Pixels[i + 1] = (byte)color[1];
                frame.Pixels[i + 2] = (byte)color[0];
                frame.Pixels[i + 3] = 255;
            }
            for (var y = 0; y < height; y++)
                for (var x = 0; x < width; x++) Paint(x, y, background);
            foreach (var x0 in item.GetProperty("rings").EnumerateArray().Select(v => v.GetInt32()))
                for (var y = top; y < top + size; y++)
                    for (var x = x0; x < x0 + size; x++)
                        if (x - x0 < 3 || x0 + size - x <= 3 || y - top < 3 || top + size - y <= 3) Paint(x, y, ink);
            var source = Line([.. item.GetProperty("words").EnumerateArray()
                .Select(w => Word(w[0].GetString()!, w[1].GetDouble(), w[2].GetDouble()))]);
            if (item.TryGetProperty("markFree", out var expected))
            {
                var marked = ButtonIcons.MarkFree(source, frame);
                Assert.True(expected.GetProperty("text").GetString() == marked.Text, $"{name}: {marked.Text}");
                if (expected.TryGetProperty("icons", out var icons))
                {
                    Assert.Equal(icons.EnumerateArray().Select(v => v.GetString()), marked.Icons!.Select(icon => icon.Text));
                    Assert.All(ButtonIcons.WithImages(marked.Icons!, frame), icon =>
                    {
                        Assert.InRange(icon.Box.Left, 0, 1);
                        Assert.InRange(icon.Box.Right, 0, 1);
                        Assert.NotNull(icon.Image);
                    });
                }
                else
                {
                    Assert.Same(source, marked);
                }
            }
            if (item.TryGetProperty("screen", out var screen))
            {
                var items = await ScreenTranslation.TranslateAsync(frame, new LinesReader(new Reading([source])), new FakeTranslator());
                Assert.Equal(screen.GetProperty("paragraphs").EnumerateArray().Select(v => v.GetString()),
                             items.SelectMany(i => i.Source.Split('\n')));
                var maxRight = screen.GetProperty("maxRight").GetDouble();
                Assert.All(items, i => Assert.True(i.Icons is null && i.Box.Right <= maxRight + 1e-9, $"{name}: {i.Box}"));
            }
        }
    }

    [Fact]
    public void ButtonBarGapWithAnIconIsMarked()
    {
        // 400×40 kare, satır 20 piksel; DESTINATION ile EXIT arasında 40 piksellik boşlukta simge.
        var frame = Draw(400, 40, (191, 11, 18));
        var line = Line(Word("SET", 0.05, 0.15), Word("DESTINATION", 0.17, 0.45), Word("EXIT", 0.55, 0.65));
        var marked = ButtonIcons.MarkFree(line, frame);
        Assert.Equal($"SET DESTINATION {M} EXIT", marked.Text);
        Assert.Single(marked.Icons!);
        var region = new CropRegion(0, 1, 0, 1);
        var reading = new Reading([line]);
        Assert.NotEqual(RegionWatcher.MakeCandidate(reading, region, Draw(400, 40)).Key,
                        RegionWatcher.MakeCandidate(reading, region, frame).Key);
    }

    [Fact]
    public void EmptyGapIsNotAnIcon()
    {
        var line = Line(Word("SET", 0.05, 0.15), Word("DESTINATION", 0.17, 0.45), Word("EXIT", 0.55, 0.65));
        Assert.Same(line, ButtonIcons.MarkFree(line, Draw(400, 40)));
    }

    /// <summary>Sıradan cümlenin ortasındaki şekil harita işaretidir (GTA 6 ipucu kutusu), simge sayılmaz.</summary>
    [Fact]
    public void GapInASentenceIsNotSearched()
    {
        var frame = Draw(400, 40, (191, 11, 18));
        var line = Line(Word("your", 0.05, 0.15), Word("vehicle", 0.17, 0.45), Word("for", 0.55, 0.65));
        Assert.Same(line, ButtonIcons.MarkFree(line, frame));
    }

    [Fact]
    public void IconLeftOfTheLineIsMarked()
    {
        // Satır x=120'de başlar; simge solunda (yükseklik 20, arama genişliği 36 piksel).
        var frame = Draw(400, 40, (92, 11, 18));
        var line = Line(Word("Pick", 0.30, 0.40), Word("up", 0.42, 0.47));
        var marked = ButtonIcons.MarkFree(line, frame);
        Assert.Equal($"{M} Pick up", marked.Text);
    }

    [Fact]
    public void MisreadLetterInAButtonBarIsMarkedWhenItLooksLikeAnIcon()
    {
        // "OFFER RIDE e LUCIA": ✕ "e" okunuyor.
        var frame = Draw(400, 40, (178, 11, 18));
        var line = Line(Word("OFFER", 0.05, 0.20), Word("RIDE", 0.22, 0.40), Word("e", 0.45, 0.50), Word("LUCIA", 0.56, 0.75));
        Assert.Equal($"OFFER RIDE {M} LUCIA", ButtonIcons.MarkFree(line, frame).Text);
    }

    [Fact]
    public void ButtonBarCommandsComeFromTheGlossary()
    {
        Assert.Equal($"Hedef belirle {M} Çıkış {M}", UiCommands.Translate($"SET DESTINATION {M} EXIT {M}"));
        Assert.Equal($"Aç {M}", UiCommands.Translate($"OPEN {M}"));
        Assert.Equal("Yakıt al", UiCommands.Translate("REFUEL"));
        Assert.Null(UiCommands.Translate("Open the door"));
        Assert.Null(UiCommands.Translate($"LAUNCH ROCKETS {M} EXIT"));
    }

    [Fact]
    public void IconsInsideEitherCropEdgeRemainVisible()
    {
        var frame = Draw(400, 40, (4, 11, 18), (377, 11, 18));
        var line = Line(Word("SELECT", 30 / 400.0, 0.7), Word("ITEM", 0.73, 371 / 400.0));
        var marked = ButtonIcons.MarkFree(line, frame);
        Assert.Equal($"{M} SELECT ITEM {M}", marked.Text);
        Assert.All(ButtonIcons.WithImages(marked.Icons!, frame), icon =>
        {
            Assert.InRange(icon.Box.Left, 0, 1);
            Assert.InRange(icon.Box.Right, 0, 1);
            Assert.NotNull(icon.Image);
        });
    }

    [Fact]
    public void AdjacentMeasuredShoulderButtonsKeepTheirOwnImages()
    {
        var frame = Draw(400, 40, (122, 11, 18), (150, 11, 18));
        var line = Line(Word("SELECT", 0.05, 0.26), Word("L1", 0.30, 0.355), Word("R1", 0.37, 0.43));
        var marked = ButtonIcons.MarkFree(line, frame);
        Assert.Equal($"SELECT {M} {M}", marked.Text);
        Assert.Equal(new[] { "L1", "R1" }, marked.Icons!.Select(icon => icon.Text));
        Assert.True(marked.Icons![0].Box.Right <= marked.Icons[1].Box.Left);
        Assert.All(ButtonIcons.WithImages(marked.Icons, frame), icon => Assert.NotNull(icon.Image));
    }

    [Fact]
    public void UnconfirmedSymbolStaysAsTextBesideAConfirmedButton()
    {
        var frame = Draw(400, 40, (150, 11, 18));
        var line = Line(Word("SELECT", 0.05, 0.26), Word("○", 0.30, 0.355), Word("R1", 0.37, 0.43));
        var marked = ButtonIcons.MarkFree(line, frame);
        Assert.Equal($"SELECT ○ {M}", marked.Text);
        Assert.Equal("R1", Assert.Single(marked.Icons!).Text);
    }

    [Fact]
    public void RegionGroupsKeepTheImageFoundBesideAnIndependentMessage()
    {
        var frame = Draw(400, 40, (22, 11, 18));
        var reading = new Reading([Line(Word("R2", 0.05, 0.11), Word("Swing", 0.13, 0.28)),
                                   Line(Word("Incoming", 0.65, 0.79), Word("call", 0.8, 0.89))]);
        var candidate = RegionWatcher.MakeCandidate(reading, new CropRegion(0, 1, 0, 1), frame);
        Assert.Equal(2, candidate.Blocks!.Count);
        // Satır başındaki tuş simgesi çeviriye girmez, kutunun dışında kalır; ekranda görünür (#860).
        Assert.Equal(new[] { "Swing", "Incoming call" }, candidate.Paragraphs);
        Assert.Null(candidate.Icons);
        Assert.True(candidate.Blocks![0].Box.Left >= 0.11);
    }

    /// <summary>
    /// "Ekranı çevir"de tuş ipucu atılmaz: etiketi kendi kutusunda çevrilir, tuş ("R2") çeviriye girmez ve ekranda özgün
    /// haliyle görünür kalır (simgesi görünse de görünmese de; GTA 6 tuş çubuğu ve etkileşim seçenekleri).
    /// </summary>
    [Fact]
    public async Task FullScreenTranslatesThePromptLabelAndLeavesTheButton()
    {
        var reading = new Reading([Line(Word("R2", 0.05, 0.11), Word("Swing", 0.13, 0.28))]);
        var reader = new LinesReader(reading);
        foreach (var frame in new[] { Draw(400, 40), Draw(400, 40, (22, 11, 18)) })
        {
            var translator = new FakeTranslator();
            var item = Assert.Single(await ScreenTranslation.TranslateAsync(frame, reader, translator));
            Assert.Equal(["Swing"], translator.Requested);
            Assert.Equal(0.13, item.Box.Left);
            Assert.Null(item.Icons);
        }
    }

    [Fact]
    public void MeasuredButtonIncludesTheOutlineAroundItsLetters()
    {
        var frame = Draw(400, 40, (120, 11, 18));
        // OCR düğmenin yalnız ortasındaki harfleri kutuladı (124..134); kontur 120..138.
        var line = Line(Word("SELECT", 0.05, 0.26), Word("R1", 124 / 400.0, 134 / 400.0));
        var marked = ButtonIcons.MarkFree(line, frame);
        var icon = Assert.Single(ButtonIcons.WithImages(marked.Icons!, frame));
        Assert.Equal(ButtonIcons.Crop(frame, new TextBox(0.28, 0.1, 0.36, 0.9)), icon.Image);
    }
}
