// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.CompilerServices;
using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// GTA 6 telefonunun sohbet dışı ekranları (Sinan Bey, beta.100 3416–3425): ekran türü, kartlar, kartların panelde telefonun
/// yanında orantılı boyda ve tek renkte çizilmesi, telefonun yazılarının altyazıya ve ekran yazısı kutularına gitmemesi, ekran
/// değişince eski kartların hemen kalkması ve aynı ekranda kartların kaybolmaması. Ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/phone-screens.json (Mac/iPhone PhoneScreenTests.swift, Android PhoneScreenTest.kt).
/// </summary>
public class PhoneScreenTests
{
    private static JsonElement Fixture() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("phone-screens.json"))).RootElement;

    private static TextBox Box(JsonElement value)
    {
        var v = value.EnumerateArray().Select(item => item.GetDouble()).ToArray();
        return new TextBox(v[0], v[1], v[2], v[3]);
    }

    private static TextBox Box(double[] v) => new(v[0], v[1], v[2], v[3]);

    [Fact]
    public void SharedScreensGiveTheSameKindAndCards()
    {
        var all = Fixture();
        foreach (var screen in all.GetProperty("screens").EnumerateArray())
        {
            var name = screen.GetProperty("name").GetString()!;
            var lines = screen.GetProperty("lines").EnumerateArray()
                .Select(line => new PhoneScreen.Line(line.GetProperty("text").GetString()!, Box(line.GetProperty("box")))).ToList();
            var kind = PhoneScreen.KindOf(lines);
            Assert.True(screen.GetProperty("kind").GetString() == kind.ToString().ToLowerInvariant(), $"{name}: {kind}");
            var cards = PhoneScreen.Cards(lines, kind);
            var expected = screen.GetProperty("cards").EnumerateArray().ToList();
            Assert.True(expected.Count == cards.Count, $"{name}: {cards.Count} kart");
            for (var i = 0; i < cards.Count; i++)
            {
                Assert.Equal(expected[i].GetProperty("paragraphs").EnumerateArray().Select(p => p.GetString()!).ToList(),
                             PhoneScreen.Paragraphs(cards[i], lines));
                Assert.True(expected[i].GetProperty("titled").GetBoolean() == cards[i].Titled, $"{name} {i} titled");
                Assert.True(expected[i].GetProperty("bold").GetBoolean() == cards[i].Bold, $"{name} {i} bold");
            }
        }
        foreach (var text in all.GetProperty("times").GetProperty("yes").EnumerateArray()) Assert.True(PhoneScreen.IsTime(text.GetString()!));
        foreach (var text in all.GetProperty("times").GetProperty("no").EnumerateArray()) Assert.False(PhoneScreen.IsTime(text.GetString()!));
    }

    private static string FramePath(string name, [CallerFilePath] string source = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..", "testdata", "frames", name));

    /// <summary>
    /// Gerçek sohbet kareleri (kayıtlı okumalarıyla) sohbet kalır: alt satıra sarılmış kısa parçalar ("off for you") etiket
    /// sayılmaz.
    /// </summary>
    [Theory]
    [InlineData("gta6-telefon-sohbet-1")]
    [InlineData("gta6-telefon-sohbet-2")]
    public void RealChatFramesStayChats(string name)
    {
        var frame = Jpeg.Load(FramePath(name + ".jpg"));
        Assert.True(GamePhoneGeometry.TryLocate(frame, out var pose), name);
        var handset = new ScreenPhoneCard.Handset(pose, frame.Width / (double)frame.Height);
        using var json = JsonDocument.Parse(File.ReadAllText(FramePath(Path.Combine("ocr", name + "-tam.json"))));
        var lines = new List<PhoneScreen.Line>();
        foreach (var line in json.RootElement.GetProperty("lines").EnumerateArray())
        {
            if (line.GetProperty("box").GetArrayLength() != 4) continue;
            var box = Box(line.GetProperty("box"));
            if (!ScreenPhoneCard.Holds(box, handset)) continue;
            lines.Add(new PhoneScreen.Line(line.GetProperty("text").GetString()!, handset.Flat(box)));
        }
        Assert.True(lines.Count >= 4, name);
        Assert.Equal(PhoneScreen.Kind.Chat, PhoneScreen.KindOf(lines));
    }

    private static TextLine Line(string text, double[] spot) =>
        new(text, new TextBox(0.4 + spot[0] * 0.2, 0.1 + spot[1] * 0.8, 0.4 + spot[2] * 0.2, 0.1 + spot[3] * 0.8)) { PhoneBox = Box(spot) };

    /// <summary>
    /// Otomatik telefon okuması: uygulama ekranının satırları kartlarına ayrılır (rol Card, başlıklı kart iki paragraf),
    /// gönderide kullanıcı adı, konum ve fotoğraf yazısı çevrilmez, açıklama tek grup.
    /// </summary>
    [Fact]
    public void AutoPhoneReadingGroupsAppScreensIntoCards()
    {
        var fitness = new Reading([
            Line("Training", [0.06, 0.12, 0.3, 0.14]),
            Line("Power Session", [0.1, 0.17, 0.5, 0.19]), Line("Stage 2/4", [0.1, 0.195, 0.35, 0.215]),
            Line("Session done. Take a break.", [0.12, 0.25, 0.8, 0.27]),
            Line("Endurance Run", [0.1, 0.32, 0.5, 0.34]), Line("Stage 1/4", [0.1, 0.345, 0.35, 0.365]),
            Line("7PM", [0.7, 0.5, 0.8, 0.52]),
        ]);
        var groups = GamePhoneText.Groups(GamePhoneText.ForTranslation(fitness));
        Assert.Equal([["Training"], ["Power Session", "Stage 2/4"], ["Session done. Take a break."], ["Endurance Run", "Stage 1/4"]],
                     groups.Select(group => group.Paragraphs.ToList()).ToList());
        Assert.All(groups, group => Assert.Equal(ScreenPhoneCard.Role.Card, group.Phone?.Role));
        Assert.Equal([false, true, false, true], groups.Select(group => group.Phone!.Titled).ToList());

        var post = new Reading([
            Line("BAIT SHOP", [0.2, 0.12, 0.6, 0.17]),
            Line("@harbor_bait_club", [0.12, 0.56, 0.62, 0.585]),
            Line("Sunrise run past the north jetty", [0.06, 0.6, 0.92, 0.625]),
            Line("Grab the spring issue at the dock t...", [0.06, 0.63, 0.92, 0.655]),
            Line("Grab the spring issue", [0.3, 0.63, 0.7, 0.655]),
            Line("Marlin Point", [0.1, 0.7, 0.4, 0.72]),
        ]);
        var caption = Assert.Single(GamePhoneText.Groups(GamePhoneText.ForTranslation(post)));
        Assert.Equal(["Sunrise run past the north jetty Grab the spring issue at the dock t..."], caption.Paragraphs);
        Assert.Equal(ScreenPhoneCard.Role.Card, caption.Phone?.Role);
    }

    private static readonly GamePhoneGeometry.Pose Pose = new(0.62, 0.15, 0.62, 0.85);

    private static ScreenTranslation.Item Card(string source, string translation, double top, double height = 0.012, bool titled = false,
                                               PhoneTextStyle? style = null, bool unchanged = false) =>
        new(source, translation, new TextBox(0.56, 0.2 + top * 0.6, 0.7, 0.2 + top * 0.6 + height), height)
        {
            Unchanged = unchanged,
            Style = style,
            Phone = new ScreenPhoneCard.Placement(ScreenPhoneCard.Role.Card, new TextBox(0.06, top, 0.9, top + 0.03), titled),
        };

    /// <summary>
    /// Kartlar telefonun boş yanında (telefonun üstünde değil), mesaj listesi kartı görünüşünde (avatarsız), hepsi aynı
    /// renkte ve aynı genişlikte; başlıklı kartın başlığı kalın ad, gövdesi altında; çevrilmeyen kart (ad) çizilmez.
    /// </summary>
    [Fact]
    public void AppCardsAreDrawnBesideThePhoneAsUniformRowCards()
    {
        var handset = new ScreenPhoneCard.Handset(Pose, 16.0 / 9);
        var white = new PhoneTextStyle("#F2F2F2", "#111111");
        var navy = new PhoneTextStyle("#1A2238", "#F0F0F0");
        ScreenTranslation.Item[] items =
        [
            Card("Riley", "Riley", 0.03, style: white, unchanged: true),
            Card("Power Session\nStage 2/4", "Güç Seansı\nAşama 2/4", 0.17, titled: true, style: white),
            Card("Session done. Take a break.", "Seans bitti. Mola ver.", 0.25, style: navy),
            Card("Endurance Run\nStage 1/4", "Dayanıklılık Koşusu\nAşama 1/4", 0.32, titled: true, style: white),
        ];
        var laid = ScreenPhoneCard.Layout(items, handset).Where(item => !item.Unchanged).ToList();
        var rows = laid.Where(item => item.Panel == ScreenPhoneCard.PanelPart.Row).ToList();
        Assert.Equal(3, rows.Count);
        Assert.Equal(["Güç Seansı", "", "Dayanıklılık Koşusu"], rows.Select(row => row.ListRow!.Name).ToList());
        Assert.Equal(["Aşama 2/4", "Seans bitti. Mola ver.", "Aşama 1/4"], rows.Select(row => row.ListRow!.Preview).ToList());
        Assert.All(rows, row => Assert.True(row.ListRow!.Avatar is null && row.ListRow.PortraitSpot is null));
        Assert.Single(rows.Select(row => row.Style?.Background ?? "").Distinct());
        Assert.Equal(white.Background, rows[0].Style?.Background);
        Assert.Single(rows.Select(row => Math.Round(row.Box.Right - row.Box.Left, 9)).Distinct());
        var phone = handset.Bounds;
        Assert.All(rows, row => Assert.True(row.Box.Right <= phone.Left + 1e-9 || row.Box.Left >= phone.Right - 1e-9, "telefonun üstünde değil"));
        // Kartların üstü İngilizcesiyle aynı hizada, üst üste binmez.
        for (var i = 1; i < rows.Count; i++) Assert.True(rows[i - 1].Box.Bottom <= rows[i].Box.Top + 1e-9);
        Assert.DoesNotContain(laid, item => item.Source == "Riley");
    }

    /// <summary>
    /// Yazı boyu telefon yazısıyla orantılı: fotoğrafın içindeki büyük yazı ya da yakın kamera paneli dev yazıyla çizmez
    /// (3416); çift sayıda ölçümde küçük ortanca alınır.
    /// </summary>
    [Fact]
    public void CardTextIsProportionalNotHuge()
    {
        var handset = new ScreenPhoneCard.Handset(Pose, 16.0 / 9);
        var small = Card("Last call for the boat", "Tekne için son çağrı", 0.6, height: 0.012);
        var sign = Card("BAIT SHOP", "YEM DÜKKANI", 0.1, height: 0.07);
        Assert.Equal(0.012, ScreenPhoneCard.MeasuredLine([small, sign]));
        foreach (var row in ScreenPhoneCard.Layout([small, sign], handset).Where(item => item.Panel == ScreenPhoneCard.PanelPart.Row))
        {
            Assert.True(row.LineHeight <= ScreenPhoneCard.MaxLine + 1e-9);
            Assert.True(row.LineHeight >= ScreenPhoneCard.MinLine - 1e-9);
        }
        var huge = ScreenPhoneCard.Layout([Card("Big", "Büyük yazı", 0.3, height: 0.08)], handset, textScale: 1);
        Assert.Equal(ScreenPhoneCard.MaxLine, huge.First(item => item.Panel == ScreenPhoneCard.PanelPart.Row).LineHeight, 9);
        // Altyazı boyutu ayarı yine çarpan olarak işler.
        var scaled = ScreenPhoneCard.Layout([Card("Big", "Büyük yazı", 0.3, height: 0.08)], handset, textScale: 1.5);
        Assert.Equal(ScreenPhoneCard.MaxLine * 1.5, scaled.First(item => item.Panel == ScreenPhoneCard.PanelPart.Row).LineHeight, 9);
    }

    /// <summary>Ana ekran ve hava yazıları da telefonun üstüne yazılmaz: panelde kart olur; saat ("7PM") çevrilmez.</summary>
    [Fact]
    public void HomeAndWeatherTextGoesToThePanel()
    {
        var handset = new ScreenPhoneCard.Handset(Pose, 16.0 / 9);
        var home = Card("Partly cloudy", "Parçalı bulutlu", 0.2);
        home = home with { Phone = home.Phone! with { Role = ScreenPhoneCard.Role.Home } };
        var row = ScreenPhoneCard.Layout([home], handset).First(item => item.Panel == ScreenPhoneCard.PanelPart.Row);
        Assert.Equal("Parçalı bulutlu", row.ListRow?.Preview);
        Assert.True(row.Box.Right <= handset.Bounds.Left + 1e-9 || row.Box.Left >= handset.Bounds.Right - 1e-9);
        var weather = PhoneChat.WithoutAppNames([
            Line("Now", [0.06, 0.1, 0.2, 0.12]), Line("71°", [0.06, 0.13, 0.3, 0.2]),
            Line("Partly cloudy", [0.06, 0.21, 0.5, 0.23]), Line("7PM", [0.06, 0.3, 0.14, 0.32]),
            Line("8PM", [0.2, 0.3, 0.28, 0.32]), Line("Sunset", [0.06, 0.6, 0.3, 0.62]),
        ]);
        Assert.DoesNotContain(weather, line => line.Text is "7PM" or "8PM");
        Assert.Contains(weather, line => line.Text == "Sunset");
    }

    /// <summary>GamePhoneTrackerTests.PhoneFrame'in tonları; <paramref name="blend"/>: kasa ve zemin ekranla aynı açık tonda.</summary>
    private static byte PhoneGray(int x, int y, bool blend)
    {
        byte gray = 85;
        if (x is >= 160 and < 244 && y is >= 22 and < 201) gray = 110;
        if (blend) gray = 192;
        if (x is >= 164 and < 240 && y is >= 40 and < 181) gray = 195;
        if (x is >= 196 and < 209 && y is >= 33 and < 35) gray = 25;
        if (x is >= 212 and < 215 && y is >= 33 and < 36) gray = 25;
        if (x is >= 198 and < 207 && y is >= 189 and < 191) gray = 25;
        if (x is >= 198 and < 207 && y is >= 170 and < 172) gray = 24;
        return gray;
    }

    private static Frame Picture(Func<int, int, byte> gray)
    {
        var frame = Frame.Blank(400, 225);
        for (var y = 0; y < 225; y++)
            for (var x = 0; x < 400; x++)
                Array.Fill(frame.Pixels, gray(x, y), y * frame.Stride + x * 4, 3);
        return frame;
    }

    /// <summary>
    /// Açık telefonun yanları beyaz ekranda zemine karışınca sıkı arama telefonu bulamaz; son yerindeki gevşek doğrulama
    /// (hoparlör yarığı, kamera, alt çentik) telefonu tutar. Yeni telefon gevşek doğrulamayla açılmaz; telefon gerçekten
    /// kalkınca (yarıklar yok) tolerans dolunca kapanır.
    /// </summary>
    [Fact]
    public void OpenPhoneIsKeptWhenItsSidesBlendIntoTheBackground()
    {
        var normal = GamePhoneTrackerTests.PhoneFrame();
        // Beyaz ekran, açık kasa ve açık zemin aynı tonda: yan kenar yok (yalnız yarıklar ve kamera koyu).
        var blended = Picture((x, y) => PhoneGray(x, y, blend: true));
        var gone = Picture((_, _) => 85);
        Assert.False(GamePhoneGeometry.TryLocate(blended, out _), "sıkı arama bulamıyor");
        Assert.True(GamePhoneGeometry.TryLocate(normal, out var found));
        Assert.True(GamePhoneGeometry.TryLocate(blended, found, out var near), "son yerinde doğrulanır");
        Assert.Equal(found.TopY, near.TopY, 3.0 / 225);
        Assert.False(GamePhoneGeometry.TryLocate(gone, found, out _));
        // Uzaktaki eski yer doğrulamaz.
        var far = new GamePhoneGeometry.Pose(found.TopX - 0.2, found.TopY, found.BottomX - 0.2, found.BottomY);
        Assert.False(GamePhoneGeometry.TryLocate(blended, far, out _));

        var tracker = new GamePhoneTracker();
        tracker.TrySample(normal, 0, out var first);
        Assert.Null(first);
        tracker.TrySample(normal, 330, out var second);
        Assert.NotNull(second);
        for (var turn = 2; turn <= 12; turn++)
        {
            tracker.TrySample(blended, turn * 330, out var held);
            Assert.True(held is not null, $"tur {turn}");
        }
        var closed = false;
        for (var turn = 13; turn <= 18; turn++)
        {
            tracker.TrySample(gone, turn * 330, out var shown);
            if (shown is null) closed = true;
        }
        Assert.True(closed);
        // Kapanmış telefon gevşek doğrulamayla açılmaz.
        var fresh = new GamePhoneTracker();
        fresh.TrySample(blended, 0, out var a);
        fresh.TrySample(blended, 330, out var b);
        Assert.Null(a);
        Assert.Null(b);
    }

    /// <summary>Altyazı süzgeci açık telefonu tek ıskada bırakmaz (3418, 3420, 3421): GamePhoneTracker.MissGrace arama tutulur.</summary>
    [Fact]
    public void SubtitleFilterHoldsThePhoneThroughShortMisses()
    {
        var handset = new ScreenPhoneCard.Handset(Pose, 16.0 / 9);
        var misses = 0;
        Assert.Equal(handset, SubtitlePipeline.HeldPhone(handset, null, ref misses));
        for (var i = 0; i < GamePhoneTracker.MissGrace; i++) Assert.Equal(handset, SubtitlePipeline.HeldPhone(null, handset, ref misses));
        Assert.Null(SubtitlePipeline.HeldPhone(null, handset, ref misses));
        Assert.Equal(0, misses);
        Assert.Null(SubtitlePipeline.HeldPhone(null, null, ref misses));
        // Açık telefonun son yeri verilince sıkı arama ıskalasa da kare telefonlu sayılır.
        var normal = GamePhoneTrackerTests.PhoneFrame();
        var blended = Picture((x, y) => PhoneGray(x, y, blend: true));
        var open = ScreenPhoneCard.Phone(normal);
        Assert.NotNull(open);
        Assert.Null(ScreenPhoneCard.Phone(blended));
        Assert.NotNull(ScreenPhoneCard.Phone(blended, open));
    }

    // --- Oturum (otomatik telefon okuması) ---

    private sealed class Reader : ITextReader
    {
        private readonly object gate = new();
        private List<TextLine> lines = [];
        public void Set(List<TextLine> value) { lock (gate) lines = value; }
        public string Read(Frame image) => ReadLines(image, false).Text;
        public Reading ReadScreen(Frame image) => ReadLines(image, false);
        public int Reads;
        public Reading ReadLines(Frame image, bool deep)
        {
            lock (gate)
            {
                Reads++;
                return new Reading(lines);
            }
        }
    }

    private sealed class Translator : ITextTranslator
    {
        private static readonly Dictionary<string, string> Known = new()
        {
            ["City council approves the waterfront plan"] = "Meclis sahil planını onayladı",
            ["The council voted late on Tuesday to approve the long delayed plan."] = "Meclis salı geç saatte uzun süredir bekleyen planı onayladı.",
            ["Partly cloudy"] = "Parçalı bulutlu",
            ["Sunset"] = "Gün batımı",
            ["Now"] = "Şimdi",
            ["Governor speaks today"] = "Vali bugün konuşuyor",
        };
        public List<string> Calls { get; } = [];
        public bool TranslatesTogether => true;
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            lock (Calls) Calls.Add(text);
            return Task.FromResult(Known.TryGetValue(text, out var known) ? known : "Çeviri " + new string([.. text.Reverse()]));
        }
        public int Count { get { lock (Calls) return Calls.Count; } }
    }

    private sealed class Server : IRegionSender
    {
        public List<(string Id, IReadOnlyList<ScreenTranslation.Item> Items)> Sent { get; } = [];
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight = null) =>
            SendRegion(id, text, box, lineHeight, null, null);
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight, IReadOnlyList<IconPlacement>? icons,
                               IReadOnlyList<ScreenTranslation.Item>? blocks)
        {
            lock (Sent)
                Sent.Add((id, text.Length == 0 ? [] : blocks ?? [new ScreenTranslation.Item("", text, box ?? new TextBox(0, 0, 1, 1), lineHeight ?? 0)]));
        }
        public void ClearRegions() { }
        public List<(string Id, IReadOnlyList<ScreenTranslation.Item> Items)> Copy() { lock (Sent) return [.. Sent]; }
    }

    private static async Task WaitForPass(RegionWatcher watcher)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (watcher.IsBusy) await Task.Delay(5, timeout.Token);
    }

    /// <summary>Telefon karesi, ekranı <paramref name="tone"/> tonunda (ekrandaki görüntü değişti, yeniden okunur).</summary>
    private static Frame Screen(byte tone)
    {
        var frame = GamePhoneTrackerTests.PhoneFrame();
        for (var y = 42; y < 168; y++) Array.Fill(frame.Pixels, tone, y * frame.Stride + 166 * 4, 72 * 4);
        return frame;
    }

    private static TextLine Flat(string text, double[] spot) => new(text, Box(spot));

    private static WatchedArea PhoneArea(GamePhoneGeometry.Pose pose, CancellationToken lifetime) =>
        new("game-phone", "Phone", pose.Bounds) { PanelLifetime = lifetime, PhonePose = pose };

    /// <summary>
    /// Uygulama değişince (makaleden hava uygulamasına) eski kartlar aynı gönderide kalkar; aynı ekran art arda okununca
    /// kartlar kaybolmaz, yeniden gönderilmez ve yeniden çevrilmez (#1279).
    /// </summary>
    [Fact]
    public async Task ScreenChangeReplacesCardsAndSameScreenStaysStill()
    {
        var frame = GamePhoneTrackerTests.PhoneFrame();
        Assert.True(GamePhoneGeometry.TryLocate(frame, out var found));
        using var lifetime = new CancellationTokenSource();
        var area = PhoneArea(found, lifetime.Token);
        var reader = new Reader();
        var translator = new Translator();
        var server = new Server();
        long clock = 0;
        var watcher = new RegionWatcher(reader, translator, server, clock: () => clock);
        reader.Set([Flat("< Back", [0.04, 0.02, 0.2, 0.045]),
                    Flat("City council approves", [0.06, 0.06, 0.9, 0.1]), Flat("the waterfront plan", [0.06, 0.105, 0.9, 0.145]),
                    Flat("The council voted late on Tuesday to", [0.06, 0.6, 0.94, 0.62]),
                    Flat("approve the long delayed plan.", [0.06, 0.625, 0.9, 0.645])]);
        watcher.Offer(frame, [area]);
        await WaitForPass(watcher);
        var first = server.Copy().Last(sent => sent.Id == "game-phone").Items;
        var rows = first.Where(item => item.ListRow is not null).Select(item => item.ListRow!).ToList();
        Assert.Equal(["Meclis sahil planını onayladı", ""], rows.Select(row => row.Name).ToList());
        Assert.Equal(["", "Meclis salı geç saatte uzun süredir bekleyen planı onayladı."], rows.Select(row => row.Preview).ToList());
        Assert.DoesNotContain(first, item => item.Translation.Contains("Back"));

        // Aynı ekran yeniden okunur (kare biraz değişti) ama gönderi ve çeviri yinelenmez, kartlar yerinde kalır.
        var sends = server.Copy().Count;
        var calls = translator.Count;
        var reads = reader.Reads;
        for (var turn = 1; turn <= 4; turn++)
        {
            clock += 450;
            watcher.Offer(Screen(turn % 2 == 1 ? (byte)225 : (byte)195), [area]);
            await WaitForPass(watcher);
        }
        Assert.True(reader.Reads > reads, "yeniden okundu");
        Assert.Equal(calls, translator.Count);
        Assert.DoesNotContain(server.Copy().Skip(sends), sent => sent.Id == "game-phone" && sent.Items.Count == 0);

        // Hava uygulaması: eski makale kartları bu gönderide kalkar.
        reader.Set([Flat("Now", [0.06, 0.1, 0.2, 0.12]), Flat("71°", [0.06, 0.13, 0.3, 0.2]),
                    Flat("Partly cloudy", [0.06, 0.21, 0.5, 0.23]), Flat("7PM", [0.06, 0.3, 0.14, 0.32]),
                    Flat("Sunset", [0.06, 0.6, 0.3, 0.62])]);
        clock += 450;
        watcher.Offer(Screen(150), [area]);
        await WaitForPass(watcher);
        var weather = server.Copy().Last(sent => sent.Id == "game-phone").Items;
        var texts = weather.Where(item => item.ListRow is not null).Select(item => item.ListRow!.Name + item.ListRow.Preview).ToList();
        Assert.DoesNotContain(texts, text => text.Contains("Meclis"));
        Assert.Contains("Parçalı bulutlu", texts);
        Assert.Contains("Gün batımı", texts);
        Assert.DoesNotContain(texts, text => text.Contains("7PM"));
    }

    /// <summary>Telefon açılınca otomatik ekran yazısı kutuları (telefonun ekranına çizilmiş olanlar dahil) aynı karede kalkar.</summary>
    [Fact]
    public async Task PhoneOpeningClearsScreenTextBoxesAtOnce()
    {
        var frame = GamePhoneTrackerTests.PhoneFrame();
        Assert.True(GamePhoneGeometry.TryLocate(frame, out var found));
        var reader = new Reader();
        var server = new Server();
        long clock = 0;
        var watcher = new RegionWatcher(reader, new Translator(), server, clock: () => clock);
        reader.Set([new TextLine("Governor speaks today", new TextBox(0.1, 0.2, 0.9, 0.5))]);
        var auto = new WatchedArea("auto-7", "auto", new CropRegion(0.3, 0.4, 0.45, 0.6)) { Auto = true };
        for (var i = 0; i < 4; i++)
        {
            await watcher.PassAsync(frame, [auto]);
            clock += 1000;
        }
        Assert.Contains(server.Copy(), sent => sent.Id == "auto-7" && sent.Items.Count > 0);
        var before = server.Copy().Count;
        using var lifetime = new CancellationTokenSource();
        watcher.Offer(frame, [PhoneArea(found, lifetime.Token)]);
        Assert.Contains(server.Copy().Skip(before), sent => sent.Id == "auto-7" && sent.Items.Count == 0);
        await WaitForPass(watcher);
    }
}
