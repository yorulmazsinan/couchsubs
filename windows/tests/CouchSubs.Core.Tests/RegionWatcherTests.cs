// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Ek alanlar: ana altyazıdan ayrı, seyrek okunur; yazı kararlıysa ve değiştiyse çevrilir (Mac: RegionWatcherTests.swift).</summary>
public class RegionWatcherTests
{
    private sealed class Reader : ITextReader
    {
        public List<TextLine> Lines { get; set; } = [];
        public int Count;
        public int ScreenReads;
        public List<(int Width, int Height)> Sizes { get; } = [];
        public int FailuresRemaining;
        public Action? OnRead;
        public Func<Frame, List<TextLine>>? ScreenLines;
        public string Read(Frame image) => string.Join('\n', Lines.Select(line => line.Text));
        public Reading ReadScreen(Frame image)
        {
            ScreenReads++;
            Sizes.Add((image.Width, image.Height));
            var reading = ReadLines(image, false);
            return ScreenLines is null ? reading : new Reading(ScreenLines(image));
        }
        public Reading ReadLines(Frame image, bool deep)
        {
            Interlocked.Increment(ref Count);
            OnRead?.Invoke();
            if (FailuresRemaining > 0)
            {
                FailuresRemaining--;
                throw new InvalidOperationException("Expected OCR failure");
            }
            return new Reading(Lines);
        }
    }

    private sealed class Translator : ITextTranslator
    {
        public List<string> Calls { get; } = [];
        public int FailuresRemaining;
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            lock (Calls)
            {
                Calls.Add(text);
                if (FailuresRemaining > 0)
                {
                    FailuresRemaining--;
                    return Task.FromException<string>(new InvalidOperationException("Expected test failure"));
                }
            }
            return Respond?.Invoke(text) ?? Task.FromResult(Map(text));
        }
        public Func<string, Task<string>>? Respond { get; set; }
        public Func<string, string> Map { get; set; } = text => "TR: " + text;
    }

    private sealed class Server : IRegionSender
    {
        public List<(string Id, string Text, TextBox? Box, double? LineHeight)> Sent { get; } = [];
        /// <summary>Her gönderimin blokları (<see cref="Sent"/> ile aynı sırada; bloksuz gönderimde null).</summary>
        public List<IReadOnlyList<ScreenTranslation.Item>?> Blocks { get; } = [];
        public int Clears;
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight = null) =>
            SendRegion(id, text, box, lineHeight, null, null);
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight, IReadOnlyList<IconPlacement>? icons,
                               IReadOnlyList<ScreenTranslation.Item>? blocks)
        {
            lock (Sent)
            {
                Sent.Add((id, text, box, lineHeight));
                Blocks.Add(blocks);
            }
        }
        public void ClearRegions() => Interlocked.Increment(ref Clears);
    }

    /// <summary>Düz gri kare; <paramref name="shade"/> değişince bölge izi değişir.</summary>
    private static Frame Shade(byte shade)
    {
        var frame = Frame.Blank(320, 180);
        Array.Fill(frame.Pixels, shade);
        return frame;
    }

    private static readonly WatchedArea Quest = new("q", "Quest", ExtraAreaPreset.Quest.Region());
    private static readonly WatchedArea Phone = new("p", "Phone", ExtraAreaPreset.Phone.Region());

    private static TextLine Line(string text, double top = 0.2, double height = 0.1) => new(text, new TextBox(0.1, top, 0.9, top + height));

    private static readonly WatchedArea Hud = new("hud", "HUD", new CropRegion(0, 1, 0, 1));

    // Beş piksel boyundaki etiket, tüm ekranı örnekleyen iki satırın arasına düşer.
    private static Frame HudFrame(int letters)
    {
        var frame = Frame.Blank(320, 180);
        for (var y = 38; y < 43; y++)
            for (var x = 33; x < 33 + 5 * letters; x++)
                if (x % 5 < 3)
                    Array.Fill(frame.Pixels, (byte)245, y * frame.Stride + x * 4, 3);
        return frame;
    }

    private static async Task WaitForPass(RegionWatcher watcher)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (watcher.IsBusy) await Task.Delay(5, timeout.Token);
    }

    // Hazır alan (GTA 6 yardım kutusu) bölgenin tamamını kaplayan kare: zemin düz panel ya da oyun dünyası.
    private static Frame PresetFrame(bool panel) => UiPanelTests.Region(panel ? (_, _) => 28 : null, 240, width: 320, height: 180);
    private static readonly WatchedArea PresetHelp = new("preset-help", "Help", new CropRegion(0, 1, 0, 1)) { RequiresPanel = true };

    [Fact]
    public async Task PresetAreaWithoutAnInterfacePanelIsNeverReadOrShown()
    {
        // Oyun yanlış seçiliyse (PS5 ana ekranı, başka oyun) ya da bölgede yalnız dünya yazısı varsa hazır alan çevrilmez.
        var reader = new Reader { Lines = [Line("LIQUOR STORE OPEN 24 HOURS")] };
        var server = new Server();
        long clock = 0;
        var watcher = new RegionWatcher(reader, new Translator(), server, clock: () => clock);
        for (var i = 0; i < 3; i++)
        {
            await watcher.PassAsync(PresetFrame(panel: false), [PresetHelp]);
            clock += 1000;
        }
        Assert.Equal(0, reader.Count);
        Assert.Empty(server.Sent);
    }

    [Fact]
    public async Task PresetAreaOnAPanelIsTranslatedAndRemovedWhenThePanelGoes()
    {
        var reader = new Reader { Lines = [Line("Follow Vicki to the car.")] };
        var server = new Server();
        long clock = 0;
        var watcher = new RegionWatcher(reader, new Translator(), server, clock: () => clock);
        await watcher.PassAsync(PresetFrame(panel: true), [PresetHelp]);
        await watcher.PassAsync(PresetFrame(panel: true), [PresetHelp]);
        Assert.Contains(server.Sent, message => message.Id == "preset-help" && message.Text == "TR: Follow Vicki to the car.");
        clock += 1000;
        await watcher.PassAsync(PresetFrame(panel: false), [PresetHelp]);
        Assert.Equal(("preset-help", ""), (server.Sent[^1].Id, server.Sent[^1].Text));
    }

    [Fact]
    public void GameAreaPresetsRequireAnInterfacePanel() =>
        Assert.All(GameAreaPresets.Areas("GTA 6"), area => Assert.True(area.RequiresPanel));

    [Fact]
    public async Task SmallChangingMenuLabelIsReadEvenWhenTheAreaSignatureMatches()
    {
        var greet = HudFrame(5);
        var antagonize = HudFrame(10);
        Assert.Equal(RegionCropper.Signature(greet), RegionCropper.Signature(antagonize));
        var reader = new Reader { Lines = [Line("Greet", 0.2, 0.05)] };
        var server = new Server();
        long clock = 0;
        var watcher = new RegionWatcher(reader, new Translator(), server, clock: () => clock);
        await watcher.PassAsync(greet, [Hud]);
        await watcher.PassAsync(greet, [Hud]);
        reader.Lines = [Line("Antagonize", 0.2, 0.05)];
        await watcher.PassAsync(antagonize, [Hud]);
        await watcher.PassAsync(antagonize, [Hud]);
        clock += 6000;
        await watcher.PassAsync(antagonize, [Hud]);
        Assert.Equal(2, reader.Count);
        Assert.Equal(["TR: Greet", "TR: Antagonize"], server.Sent.Select(message => message.Text));
    }

    [Fact]
    public async Task NewTextOutsideEarlierBoxesIsEventuallyReadOnASparseSignatureCollision()
    {
        long clock = 0;
        var reader = new Reader();
        var server = new Server();
        var watcher = new RegionWatcher(reader, new Translator(), server, clock: () => clock);
        await watcher.PassAsync(HudFrame(0), [Hud]);
        await watcher.PassAsync(HudFrame(0), [Hud]);
        clock += 6000;
        reader.Lines = [Line("Antagonize", 0.2, 0.05)];
        await watcher.PassAsync(HudFrame(10), [Hud]);
        await watcher.PassAsync(HudFrame(10), [Hud]);
        Assert.Equal(2, reader.Count);
        Assert.Equal("TR: Antagonize", Assert.Single(server.Sent).Text);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task InFlightTranslationOnlyPublishesIfTheSourceStillMatches(bool newCommand)
    {
        var greet = HudFrame(5);
        var reader = new Reader { Lines = [Line("Greet", 0.2, 0.05)] };
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var translator = new Translator { Respond = text =>
        {
            if (text != "Greet") return Task.FromResult("Kışkırt");
            entered.TrySetResult();
            return release.Task;
        } };
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server, intervalMs: 0);
        watcher.Offer(greet, [Hud]);
        await WaitForPass(watcher);
        watcher.Offer(greet, [Hud]);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var next = HudFrame(newCommand ? 10 : 5);
        // Başka bölgede de hareket var. O tek başına değişmeyen komutun çevirisini düşürmemeli.
        Array.Fill(next.Pixels, (byte)200, 0, next.Stride);
        if (newCommand) reader.Lines = [Line("Antagonize", 0.2, 0.05)];
        watcher.Offer(next, [Hud]);
        release.SetResult("Selam ver");
        await WaitForPass(watcher);
        watcher.Offer(next, [Hud]);
        await WaitForPass(watcher);
        Assert.Equal(newCommand ? "Kışkırt" : "Selam ver", Assert.Single(server.Sent).Text);
    }

    [Fact]
    public async Task AConfirmedNewCommandClearsOnlyItsOldTranslationWhileWaiting()
    {
        var reader = new Reader { Lines = [Line("Greet", 0.2, 0.05)] };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        await watcher.PassAsync(HudFrame(5), [Hud]);
        await watcher.PassAsync(HudFrame(5), [Hud]);
        reader.Lines = [Line("Antagonize", 0.2, 0.05)];
        var release = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        translator.Respond = _ => release.Task;
        await watcher.PassAsync(HudFrame(10), [Hud]);
        var pending = watcher.PassAsync(HudFrame(10), [Hud]);
        Assert.Equal(["TR: Greet", ""], server.Sent.Select(message => message.Text));
        Assert.All(server.Sent, message => Assert.Equal(Hud.Id, message.Id));
        release.SetResult("Kışkırt");
        await pending;
        Assert.Equal("Kışkırt", server.Sent.Last().Text);
    }

    [Fact]
    public async Task CommandChangedDuringTheFinalReadDoesNotPublishTheOldResponse()
    {
        var greet = HudFrame(5);
        var next = HudFrame(10);
        var reader = new Reader { Lines = [Line("Greet", 0.2, 0.05)] };
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var translator = new Translator { Respond = text =>
        {
            if (text != "Greet") return Task.FromResult("Kışkırt");
            entered.TrySetResult();
            return release.Task;
        } };
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server, intervalMs: 0);
        watcher.Offer(greet, [Hud]);
        await WaitForPass(watcher);
        watcher.Offer(greet, [Hud]);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var sameWithMotion = HudFrame(5);
        Array.Fill(sameWithMotion.Pixels, (byte)200, 0, sameWithMotion.Stride);
        watcher.Offer(sameWithMotion, [Hud]);
        reader.OnRead = () => watcher.Offer(next, [Hud]);
        release.SetResult("Selam ver");
        await WaitForPass(watcher);
        Assert.Empty(server.Sent);
        reader.OnRead = null;
        reader.Lines = [Line("Antagonize", 0.2, 0.05)];
        watcher.Offer(next, [Hud]);
        await WaitForPass(watcher);
        watcher.Offer(next, [Hud]);
        await WaitForPass(watcher);
        Assert.Equal("Kışkırt", Assert.Single(server.Sent).Text);
    }

    [Fact]
    public async Task ClosingPhoneKeepsQuestAndRepeatingThePhoneReadsItAgain()
    {
        var reader = new Reader { Lines = [Line("Call me.")] };
        var server = new Server();
        var watcher = new RegionWatcher(reader, new Translator(), server);
        using var first = new CancellationTokenSource();
        var open = Phone with { PanelLifetime = first.Token };
        await watcher.PassAsync(Shade(10), [Quest, open]);
        await watcher.PassAsync(Shade(10), [Quest, open]);
        first.Cancel();
        watcher.RemovePanel(open.Id);
        await watcher.PassAsync(Shade(10), [Quest, open]); // sıraya daha önce giren eski kare
        using var next = new CancellationTokenSource();
        var reopened = Phone with { PanelLifetime = next.Token };
        await watcher.PassAsync(Shade(10), [Quest, reopened]);
        await watcher.PassAsync(Shade(10), [Quest, reopened]);

        Assert.Equal([("p", "TR: Call me."), ("q", "TR: Call me."), ("p", ""), ("p", "TR: Call me.")],
            server.Sent.Select(s => (s.Id, s.Text)));
        var phoneCrop = RegionCropper.Crop(Shade(10), open.Region);
        Assert.Equal(3, reader.Count);
        Assert.Equal(2, reader.Sizes.Count(size => size == (phoneCrop.Width, phoneCrop.Height)));
        Assert.Equal(0, server.Clears);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ClosingPhoneDropsAnInFlightTranslationEvenWhenTheEngineIgnoresCancellation(bool honorsCancellation)
    {
        var reader = new Reader { Lines = [Line("Call me.")] };
        var server = new Server();
        var translator = new WaitingPhoneTranslator(honorsCancellation);
        var watcher = new RegionWatcher(reader, translator, server);
        using var lifetime = new CancellationTokenSource();
        var panel = Phone with { PanelLifetime = lifetime.Token };
        var pending = watcher.PassAsync(Shade(10), [panel]);
        Assert.False(pending.IsCompleted);
        lifetime.Cancel();
        watcher.RemovePanel(panel.Id);
        if (!honorsCancellation) translator.Release.SetResult();
        await pending.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal([""], server.Sent.Select(s => s.Text));
        Assert.Equal(0, server.Clears);
    }

    [Fact]
    public async Task MovingThePhoneMovesItsBoxWithoutRetranslatingTheSameMessage()
    {
        var reader = new Reader { Lines = [Line("Call me.")] };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        using var lifetime = new CancellationTokenSource();
        var open = Phone with { PanelLifetime = lifetime.Token, Region = new CropRegion(0.15, 0.85, 0.3, 0.6) };
        await watcher.PassAsync(Shade(10), [open]);
        await watcher.PassAsync(Shade(10), [open]);
        var moved = open with { Region = new CropRegion(0.15, 0.85, 0.35, 0.65) };
        await watcher.PassAsync(Shade(10), [moved]);
        Assert.Single(translator.Calls);
        Assert.Equal(2, server.Sent.Count);
        Assert.Equal(0.05, server.Sent[1].Box!.Value.Left - server.Sent[0].Box!.Value.Left, 5);
    }

    private sealed class WaitingPhoneTranslator(bool honorsCancellation = true, bool together = false, string? waitFor = null) : ITextTranslator
    {
        public bool TranslatesTogether => together;
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<string> Calls { get; } = [];
        public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            Calls.Add(text);
            if (waitFor is null || text == waitFor)
            {
                Started.TrySetResult();
                await Release.Task.WaitAsync(honorsCancellation ? cancellationToken : CancellationToken.None);
            }
            return "TR: " + text;
        }
    }

    private static Frame ChangedPhoneLabel()
    {
        var frame = Shade(10);
        // A small glyph stroke between the scan lines of the whole-region signature, inside the second bubble.
        for (int y = 121; y <= 124; y++) Array.Fill(frame.Pixels, (byte)220, y * frame.Stride + 168 * 4, 2 * 4);
        Assert.Equal(RegionCropper.Signature(Shade(10)), RegionCropper.Signature(frame));
        return frame;
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ChangedPhoneLabelWithdrawsTheOldTranslationBeforeItsReplacementIsReady(bool keepOtherBubble)
    {
        using var lifetime = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var panel = Phone with { PanelLifetime = lifetime.Token, Region = new CropRegion(0, 1, 0, 1) };
        List<TextLine> Page(string label) => keepOtherBubble
            ? [Line("Wait outside.", .1, .05), Line(label, .65, .05)] : [Line(label, .65, .05)];
        var reader = new Reader { Lines = Page("Greet") };
        var translator = new WaitingPhoneTranslator(together: true, waitFor: "Antagonize");
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        await watcher.PassAsync(Shade(10), [panel]);
        Assert.Contains("TR: Greet", Assert.Single(server.Sent).Text);
        reader.Lines = Page("Antagonize");
        var changed = ChangedPhoneLabel();
        var pass = watcher.PassAsync(changed, [panel]);
        try
        {
            Assert.Equal(2, reader.ScreenReads);
            await translator.Started.Task.WaitAsync(lifetime.Token);
            Assert.Equal(keepOtherBubble ? "TR: Wait outside." : "", server.Sent[^1].Text);
            if (keepOtherBubble) Assert.Equal(.1, Assert.Single(server.Blocks[^1]!).Box.Top, 5);
        }
        finally { translator.Release.TrySetResult(); }
        await pass;
        Assert.Contains("TR: Antagonize", server.Sent[^1].Text);
        for (int i = 0; i < 12; i++) await watcher.PassAsync(changed, [panel]);
        Assert.Equal(2, reader.ScreenReads);
        Assert.Single(translator.Calls, text => text == "Antagonize");
    }

    [Fact]
    public async Task TinyChangeWhilePhoneLabelIsBeingTranslatedNeverPublishesTheStaleLabel()
    {
        using var lifetime = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var panel = Phone with { PanelLifetime = lifetime.Token, Region = new CropRegion(0, 1, 0, 1) };
        var reader = new Reader { Lines = [Line("Greet", .65, .05)] };
        var translator = new WaitingPhoneTranslator(waitFor: "Greet");
        var server = new Server();
        long clock = 0;
        var watcher = new RegionWatcher(reader, translator, server, clock: () => clock);
        watcher.Offer(Shade(10), [panel]);
        await translator.Started.Task.WaitAsync(lifetime.Token);
        var changed = ChangedPhoneLabel();
        reader.Lines = [Line("Antagonize", .65, .05)];
        watcher.Offer(changed, [panel]);
        translator.Release.SetResult();
        while (watcher.IsBusy) await Task.Delay(4, lifetime.Token);
        Assert.DoesNotContain(server.Sent, sent => sent.Text.Contains("TR: Greet"));
        clock = 1000;
        watcher.Offer(changed, [panel]);
        while (watcher.IsBusy) await Task.Delay(4, lifetime.Token);
        Assert.Equal("TR: Antagonize", server.Sent[^1].Text);
        Assert.Equal(2, reader.ScreenReads);
    }

    [Fact]
    public async Task SlowManualAreaThenPhoneReadsOnlyTheNewestOfferedFrame()
    {
        using var lifetime = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var phone = Phone with { PanelLifetime = lifetime.Token, Region = new CropRegion(0, 1, 0, 1) };
        var reader = new Reader
        {
            Lines = [Line("Visit the docks")],
            ScreenLines = image => [Line(image.Width != 320 ? "Visit the docks" : image.Pixels[0] < 100 ? "Greet" : "Antagonize")]
        };
        var server = new Server();
        var translator = new WaitingPhoneTranslator(waitFor: "Visit the docks");
        long clock = 0;
        var watcher = new RegionWatcher(reader, translator, server, clock: () => clock);
        await watcher.PassAsync(Shade(10), [Quest]); // Bir sonraki normal turda görev çevrilecek.
        watcher.Offer(Shade(10), [Quest, phone]);
        await translator.Started.Task.WaitAsync(lifetime.Token);
        watcher.Offer(Shade(90), [Quest, phone]);
        watcher.Offer(Shade(180), [Quest, phone]);
        translator.Release.SetResult();
        while (watcher.IsBusy) await Task.Delay(4, lifetime.Token);
        Assert.Equal("TR: Antagonize", Assert.Single(server.Sent, item => item.Id == phone.Id).Text);
        Assert.Contains(server.Sent, item => item.Id == Quest.Id && item.Text == "TR: Visit the docks");
        Assert.DoesNotContain("Greet", translator.Calls);
        Assert.Single(reader.Sizes, size => size.Width == 320);
    }

    [Theory]
    [InlineData(1, false)]
    [InlineData(2, false)]
    [InlineData(1, true)]
    [InlineData(2, true)]
    public async Task StableManualAreasConfirmAt250msIndependentlyOfThePhone(int count, bool phoneOpen)
    {
        using var lifetime = new CancellationTokenSource();
        var reader = new Reader { Lines = [Line("Check the map")] };
        var server = new Server();
        long clock = 0;
        var watcher = new RegionWatcher(reader, new Translator(), server, clock: () => clock);
        var areas = new List<WatchedArea> { Quest };
        if (count == 2) areas.Add(Quest with { Id = "help" });
        if (phoneOpen) areas.Add(Phone with { PanelLifetime = lifetime.Token });
        var frame = Shade(12);
        watcher.Offer(frame, areas);
        await WaitForPass(watcher);
        Assert.Equal(phoneOpen ? 1 : 0, server.Sent.Count);
        var reads = watcher.Reads;
        Assert.Equal(areas.Count, reads);
        clock = 249;
        watcher.Offer(frame, areas);
        await WaitForPass(watcher);
        Assert.DoesNotContain(server.Sent, item => item.Id != Phone.Id);
        clock = 250;
        watcher.Offer(frame, areas);
        await WaitForPass(watcher);
        foreach (var area in areas) Assert.Single(server.Sent, item => item.Id == area.Id && item.Text == "TR: Check the map");
        Assert.Equal(reads, watcher.Reads);
    }

    [Fact]
    public async Task MildVideoNoiseAndAnIsolatedPixelDoNotRereadAStablePhoneLabel()
    {
        using var lifetime = new CancellationTokenSource();
        var phone = Phone with { PanelLifetime = lifetime.Token, Region = new CropRegion(0, 1, 0, 1) };
        var reader = new Reader { Lines = [Line("Greet", .65, .05)] };
        var server = new Server();
        var watcher = new RegionWatcher(reader, new Translator(), server);
        var first = Shade(60);
        await watcher.PassAsync(first, [phone]);
        for (int i = 0; i < 20; i++)
        {
            var noise = Shade((byte)(i % 2 == 0 ? 54 : 66));
            Array.Fill(noise.Pixels, (byte)130, (121 + i % 3) * noise.Stride + 169 * 4, 4);
            await watcher.PassAsync(noise, [phone]);
        }
        Assert.Equal(1, reader.ScreenReads);
        Assert.Single(server.Sent);
    }

    [Theory]
    [InlineData("Meet Chase at 15.", "Meet Chase at 50.")]
    [InlineData("Meet Chase at noon.", "Meet May at noon.")]
    [InlineData("I can do that.", "I can't do that.")]
    public async Task PhonePublishesOnlyUnchangedBubblesThenFillsNewTextWithoutRetranslatingTheRest(string oldText, string newText)
    {
        const string common = "Wait outside.";
        var reader = new Reader { Lines = [Line(common, .1, .05), Line(oldText, .65, .05)] };
        var translator = new WaitingPhoneTranslator(together: true);
        var server = new Server();
        long clock = 0;
        var watcher = new RegionWatcher(reader, translator, server, clock: () => clock);
        using var lifetime = new CancellationTokenSource();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var panel = Phone with { PanelLifetime = lifetime.Token, Region = new CropRegion(0, 1, 0, 1) };
        watcher.Offer(Shade(10), [panel]);
        await translator.Started.Task.WaitAsync(timeout.Token);  // İlk okunabilir telefon karesi.
        reader.Lines = [Line(common, .13, .05), Line(newText, .68, .05)];
        watcher.Offer(Shade(65), [panel]);
        translator.Release.SetResult();
        while (watcher.IsBusy) await Task.Delay(4, timeout.Token);

        Assert.Equal("TR: Wait outside.", Assert.Single(server.Sent).Text);
        Assert.Equal(.13, Assert.Single(server.Blocks[0]!).Box.Top, 5);
        clock = 1000;
        watcher.Offer(Shade(65), [panel]);
        while (watcher.IsBusy) await Task.Delay(4, timeout.Token);
        Assert.Equal([common, oldText, newText], translator.Calls);
        Assert.Equal(["TR: " + common, "TR: " + newText], server.Blocks[^1]!.Select(item => item.Translation));
    }

    [Fact]
    public async Task LocalPhonePublishesTheMessageBeforeTranslatingTheHeaderAndRemainingBubble()
    {
        var reader = new Reader { Lines = [Line("Inbox", .1, .025), Line("Wait outside.", .35, .025), Line("Call me.", .67, .025)] };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        using var lifetime = new CancellationTokenSource();
        var panel = Phone with { PanelLifetime = lifetime.Token };
        await watcher.PassAsync(Shade(10), [panel]);
        Assert.Equal(["Wait outside."], translator.Calls);
        Assert.Equal("TR: Wait outside.", Assert.Single(server.Sent).Text);

        await watcher.PassAsync(Shade(10), [panel]);
        Assert.Equal(["Wait outside.", "Inbox", "Call me."], translator.Calls);
        Assert.Equal(["TR: Inbox", "TR: Wait outside.", "TR: Call me."], server.Blocks[^1]!.Select(i => i.Translation));
    }

    [Fact]
    public async Task FasterOpenPhonePassesDoNotAccelerateOrClearRegularAreas()
    {
        var reader = new Reader { Lines = [Line("One message.")] };
        var server = new Server();
        using var lifetime = new CancellationTokenSource();
        var phone = Phone with { PanelLifetime = lifetime.Token };
        long clock = 0;
        var watcher = new RegionWatcher(reader, new Translator(), server, clock: () => clock);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        foreach (var time in new[] { 0, 330, 450, 900, 1000 })
        {
            clock = time;
            watcher.Offer(Shade((byte)(time / 5)), [Quest, phone]);
            while (watcher.IsBusy) await Task.Delay(4, timeout.Token);
        }
        var phoneCrop = RegionCropper.Crop(Shade(10), phone.Region);
        Assert.Equal(5, reader.ScreenReads);
        Assert.Equal(3, reader.Sizes.Count(size => size == (phoneCrop.Width, phoneCrop.Height)));
        Assert.DoesNotContain(server.Sent, item => item.Id == Quest.Id && item.Text.Length == 0);
    }

    [Fact]
    public async Task ChangingEndOfFirstPreviewCannotStarveOtherMessagesOrPrioritizeContactNames()
    {
        var reader = new Reader();
        var translator = new Translator();
        var watcher = new RegionWatcher(reader, translator, new Server());
        using var lifetime = new CancellationTokenSource();
        var phone = Phone with { PanelLifetime = lifetime.Token };
        foreach (var (tail, shade) in new[] { ("th.,", 20), ("ttv", 60), ("th.w", 100) })
        {
            reader.Lines = [Line("Suggested", .02, .025), Line("Sally Jones", .15, .025),
                Line("Her rent just came " + tail, .33, .025), Line("Call me soon.", .55, .025), Line("Do we have time?", .75, .025)];
            await watcher.PassAsync(Shade((byte)shade), [phone]);
        }
        Assert.Equal(["Her rent just came th.,", "Call me soon.", "Do we have time?"], translator.Calls);
    }

    [Fact]
    public async Task OpeningAnotherChatStartsWithItsFirstMessageEvenIfAListPreviewReappearsFurtherDown()
    {
        var reader = new Reader();
        var translator = new Translator();
        var watcher = new RegionWatcher(reader, translator, new Server());
        using var lifetime = new CancellationTokenSource();
        var phone = Phone with { PanelLifetime = lifetime.Token };
        reader.Lines = [Line("Suggested", .02, .025), Line("Sally Jones", .16, .025),
            Line("Her rent just came th.,", .33, .025), Line("Bring the car.", .55, .025), Line("Do we have time?", .78, .025)];
        await watcher.PassAsync(Shade(20), [phone]);
        // Aynı listenin başka önizlemeleri yenilendi; ilk hücrenin sonundaki OCR farkı sırayı başa alamaz.
        reader.Lines = [Line("Suggested", .02, .025), Line("Sally Jones", .16, .025),
            Line("Her rent just came ttv.", .33, .025), Line("I'll wait here.", .55, .025), Line("Leave now.", .78, .025)];
        await watcher.PassAsync(Shade(60), [phone]);
        reader.Lines = [Line("The first new message is important.", .12, .025), Line("Call me soon.", .34, .025),
            Line("Do you need me?", .55, .025), Line("Her rent just came through.", .78, .025)];
        await watcher.PassAsync(Shade(100), [phone]);
        Assert.Equal(["Her rent just came th.,", "I'll wait here.", "The first new message is important."], translator.Calls);
    }

    [Theory]
    [InlineData("The rent just came th.,", "The rent just came th...")]
    [InlineData("The rent just came th.„", "The rent just came th...")]
    [InlineData("The rent just came ttv.", "The rent just came ttv.")]
    [InlineData("Call May at 06:40.", "Call May at 06:40.")]
    public void OnlyTrailingEllipsisPunctuationIsNormalizedAtTheEdgeOfAConfirmedList(string preview, string expected)
    {
        static TextLine Row(string value, double y) => new(value, new TextBox(.2, y, .91, y + .03));
        var reading = new Reading([Row("Suggested", .02), Row("Brian", .14), Row(preview, .175),
            Row("Joey", .28), Row("Call me soon.", .315), Row("Messages", .48),
            Row("May", .57), Row("Do we have time?", .605)]);
        Assert.Contains(GamePhoneText.ForTranslation(reading).Lines, l => l.Text == expected);
        Assert.Equal(preview, Assert.Single(GamePhoneText.ForTranslation(new Reading([Row(preview, .2)])).Lines).Text);
    }

    [Fact]
    public async Task ReturningToASeenMessageReusesOnlyItsExactTextUntilThePhoneCloses()
    {
        var reader = new Reader();
        var translator = new Translator();
        var watcher = new RegionWatcher(reader, translator, new Server());
        using var lifetime = new CancellationTokenSource();
        var phone = Phone with { PanelLifetime = lifetime.Token };
        foreach (var (message, shade) in new[] { ("Meet May at 15.", 20), ("Meet May at 50.", 80), ("Meet May at 15.", 20) })
        {
            reader.Lines = [Line(message)];
            await watcher.PassAsync(Shade((byte)shade), [phone]);
        }
        lifetime.Cancel();
        watcher.RemovePanel(phone.Id);
        using var reopened = new CancellationTokenSource();
        await watcher.PassAsync(Shade(20), [phone with { PanelLifetime = reopened.Token }]);
        Assert.Equal(["Meet May at 15.", "Meet May at 50.", "Meet May at 15."], translator.Calls);
    }

    [Fact]
    public async Task ClosingPhoneBetweenDetectorSamplesNeverReadsGameplayOrPublishesPendingMessage()
    {
        var phone = GamePhoneTrackerTests.PhoneFrame();
        var tracker = new GamePhoneTracker();
        tracker.TrySample(phone, 0, out _);
        tracker.TrySample(phone, 400, out var region);
        Assert.NotNull(region);
        using var lifetime = new CancellationTokenSource();
        var area = tracker.WithPose(Phone with { Region = region, PanelLifetime = lifetime.Token });
        var reader = new Reader { Lines = [Line("Read my message.")] };
        var translator = new WaitingPhoneTranslator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        watcher.Offer(phone, [area]);
        await translator.Started.Task.WaitAsync(timeout.Token);

        // The text area still looks the same. The phone itself is already gone.
        var gameplay = Frame.Blank(phone.Width, phone.Height);
        Array.Fill(gameplay.Pixels, (byte)195);
        reader.Lines = [Line("Return to the main menu.")];
        watcher.Offer(gameplay, [area]);
        translator.Release.SetResult();
        while (watcher.IsBusy) await Task.Delay(4, timeout.Token);
        await watcher.PassAsync(gameplay, [area]);
        await watcher.PassAsync(gameplay, [area]);
        Assert.Equal(1, reader.ScreenReads);
        Assert.Equal(["Read my message."], translator.Calls);
        Assert.DoesNotContain(server.Sent, sent => sent.Text.Length > 0);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task PendingPhoneTranslationRechecksChangedTextButNotVideoOutsideTheText(bool changeText)
    {
        var first = Shade(10);
        var next = Shade(10);
        var top = changeText ? 36 : 118;
        for (var y = top; y < top + 17; y++) Array.Fill(next.Pixels, (byte)220, y * next.Stride + 32 * 4, 255 * 4);
        using var lifetime = new CancellationTokenSource();
        var area = Phone with { PanelLifetime = lifetime.Token, Region = new CropRegion(0, 1, 0, 1) };
        var reader = new Reader { Lines = [Line("Where are you?")] };
        var server = new Server();
        var translator = new WaitingPhoneTranslator();
        long clock = 0;
        var watcher = new RegionWatcher(reader, translator, server, clock: () => clock);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        async Task WaitUntilIdle()
        {
            while (watcher.IsBusy) await Task.Delay(4, timeout.Token);
        }
        watcher.Offer(first, [area]);
        await translator.Started.Task.WaitAsync(timeout.Token);
        if (changeText) reader.Lines = [Line("Meet me outside.")];
        watcher.Offer(Shade(125), [area]); // Ara kare birikmemeli, son sayfa geçerlidir.
        watcher.Offer(next, [area]); // Çevirmen meşgulken gelen yeni kare.
        translator.Release.SetResult();
        await WaitUntilIdle();

        if (changeText)
        {
            Assert.DoesNotContain(server.Sent, sent => sent.Text == "TR: Where are you?");
            clock = 2000;
            watcher.Offer(next, [area]);
            await WaitUntilIdle();
            Assert.Contains(server.Sent, sent => sent.Text == "TR: Meet me outside.");
            Assert.Equal(["Where are you?", "Meet me outside."], translator.Calls);
            Assert.Equal(2, reader.ScreenReads);
        }
        else
        {
            Assert.Equal("TR: Where are you?", Assert.Single(server.Sent).Text);
            Assert.Single(translator.Calls);
            Assert.Equal(1, reader.ScreenReads);
        }
    }

    [Fact]
    public async Task FailedReadRetriesOnAnUnchangedFrameThenStopsReading()
    {
        var reader = new Reader { Lines = [Line("Find the blacksmith")], FailuresRemaining = 1 };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Empty(server.Sent); // Başarılı yeni okuma yine kararlılık bekler.
        for (var i = 0; i < 4; i++) await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal(2, reader.Count);
        Assert.Equal(["Find the blacksmith"], translator.Calls);
        Assert.Equal(["TR: Find the blacksmith"], server.Sent.Select(s => s.Text));
    }

    [Fact]
    public async Task FailedReadKeepsShownTextAndDiscardsUnconfirmedReading()
    {
        var reader = new Reader { Lines = [Line("Talk to Arthur")] };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        reader.Lines = [Line("Meet Arthur at the barn")];
        await watcher.PassAsync(Shade(60), [Quest]);
        reader.FailuresRemaining = 1;
        await watcher.PassAsync(Shade(100), [Quest]);
        reader.Lines = [Line("Find the blacksmith")];
        await watcher.PassAsync(Shade(100), [Quest]);
        Assert.Equal(["TR: Talk to Arthur"], server.Sent.Select(s => s.Text));
        await watcher.PassAsync(Shade(100), [Quest]);
        Assert.Equal(["Talk to Arthur", "Find the blacksmith"], translator.Calls);
        Assert.Equal(["TR: Talk to Arthur", "TR: Find the blacksmith"], server.Sent.Select(s => s.Text));
    }

    [Fact]
    public async Task FailedReadDoesNotBlockAnotherArea()
    {
        var reader = new Reader { Lines = [Line("Find the blacksmith")], FailuresRemaining = 1 };
        var server = new Server();
        var watcher = new RegionWatcher(reader, new Translator(), server);
        await watcher.PassAsync(Shade(10), [Quest, Phone]);
        await watcher.PassAsync(Shade(10), [Quest, Phone]);
        Assert.Equal(["p"], server.Sent.Select(s => s.Id));
        await watcher.PassAsync(Shade(10), [Quest, Phone]);
        Assert.Equal(["p", "q"], server.Sent.Select(s => s.Id));
        Assert.Equal(3, reader.Count);
    }

    [Fact]
    public async Task RepeatedReadFailuresStillRespectThePassInterval()
    {
        long clock = 0;
        var reader = new Reader { FailuresRemaining = 10 };
        var server = new Server();
        var watcher = new RegionWatcher(reader, new Translator(), server, clock: () => clock);
        for (var step = 0; step <= 20; step++)
        {
            clock = step * RegionWatcher.DefaultIntervalMs / 10;
            watcher.Offer(Shade(10), [Quest]);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            while (watcher.IsBusy) await Task.Delay(5, timeout.Token);
        }
        Assert.Equal(3, watcher.Passes);
        Assert.Equal(3, reader.Count);
        Assert.Empty(server.Sent);
    }

    [Fact]
    public async Task StableTextIsTranslatedOnceAndPlacedInItsArea()
    {
        var (reader, translator, server) = (new Reader(), new Translator(), new Server());
        var watcher = new RegionWatcher(reader, translator, server);
        reader.Lines = [Line("Find the blacksmith")];
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Empty(server.Sent);
        await watcher.PassAsync(Shade(10), [Quest]);
        var sent = Assert.Single(server.Sent);
        Assert.Equal("TR: Find the blacksmith", sent.Text);
        Assert.True(sent.Box!.Value.Left > Quest.Region.Left && sent.Box.Value.Right < Quest.Region.Right);
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal(1, reader.Count);
        Assert.Single(translator.Calls);
        Assert.Single(server.Sent);
    }

    /// <summary>Ekranda zaten Türkçe olan yazı (bozuk okunmuş olsa da) çevrilmez, kutu gösterilmez (#289).</summary>
    [Fact]
    public async Task TurkishTextIsNotTranslated()
    {
        var reader = new Reader { Lines = [Line("Sistem Yazillml Güncellem€")] };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        for (var i = 0; i < 3; i++) await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Empty(translator.Calls);
        Assert.All(server.Sent, sent => Assert.Equal("", sent.Text));
    }

    [Fact]
    public async Task EnglishTextWithTurkishNameIsTranslated()
    {
        var reader = new Reader { Lines = [Line("Atatürk said no.")] };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        for (var i = 0; i < 3; i++) await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal(["Atatürk said no."], translator.Calls);
        Assert.Equal(["TR: Atatürk said no."], server.Sent.Select(s => s.Text));
    }

    [Fact]
    public async Task SameTextAtNewGeometryUpdatesRegionWithoutRetranslating()
    {
        var reader = new Reader { Lines = [Line("Find the blacksmith", 0.2, 0.1)] };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        var first = server.Sent[0];

        reader.Lines = [Line("Find the blacksmith", 0.45, 0.2)];
        await watcher.PassAsync(Shade(60), [Quest]);

        Assert.Equal(["TR: Find the blacksmith", "TR: Find the blacksmith"], server.Sent.Select(s => s.Text));
        Assert.NotEqual(first.Box?.Top, server.Sent[1].Box?.Top);
        Assert.NotEqual(first.LineHeight, server.Sent[1].LineHeight);
        Assert.Equal(["Find the blacksmith"], translator.Calls);
    }

    [Fact]
    public async Task FailedTranslationRetriesWithoutLosingPreviouslyShownText()
    {
        var (reader, translator, server) = (new Reader(), new Translator(), new Server());
        var watcher = new RegionWatcher(reader, translator, server);
        reader.Lines = [Line("Talk to Arthur")];
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal(["TR: Talk to Arthur"], server.Sent.Select(s => s.Text));

        reader.Lines = [Line("Meet Arthur at the barn")];
        translator.FailuresRemaining = 1;
        await watcher.PassAsync(Shade(90), [Quest]);
        await watcher.PassAsync(Shade(90), [Quest]);
        Assert.Equal(["TR: Talk to Arthur"], server.Sent.Select(s => s.Text));

        await watcher.PassAsync(Shade(90), [Quest]);
        Assert.Equal(["Talk to Arthur", "Meet Arthur at the barn", "Meet Arthur at the barn"], translator.Calls);
        Assert.Equal(["TR: Talk to Arthur", "TR: Meet Arthur at the barn"], server.Sent.Select(s => s.Text));
    }

    [Fact]
    public async Task MovingBackgroundWithTheSameTextIsNotTranslatedAgain()
    {
        var (reader, translator, server) = (new Reader(), new Translator(), new Server());
        var watcher = new RegionWatcher(reader, translator, server);
        reader.Lines = [Line("Talk to Arthur")];
        foreach (var shade in new byte[] { 10, 60, 110, 160, 210 }) await watcher.PassAsync(Shade(shade), [Quest]);
        Assert.Equal(5, reader.Count);
        Assert.Equal(["Talk to Arthur"], translator.Calls);
        Assert.Equal(["TR: Talk to Arthur"], server.Sent.Select(s => s.Text));
    }

    [Fact]
    public async Task ChangedTextIsTranslatedAndEmptyAreaRemovesTheBox()
    {
        var (reader, server) = (new Reader(), new Server());
        var watcher = new RegionWatcher(reader, new Translator(), server);
        reader.Lines = [Line("Talk to Arthur")];
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        reader.Lines = [Line("Meet Arthur at the barn")];
        await watcher.PassAsync(Shade(90), [Quest]);
        await watcher.PassAsync(Shade(90), [Quest]);
        reader.Lines = [];
        await watcher.PassAsync(Shade(200), [Quest]);
        await watcher.PassAsync(Shade(200), [Quest]);
        Assert.Equal(["TR: Talk to Arthur", "TR: Meet Arthur at the barn", ""], server.Sent.Select(s => s.Text));
    }

    [Fact]
    public async Task PromptsAndNumbersShowNothing()
    {
        var (reader, server) = (new Reader(), new Server());
        var watcher = new RegionWatcher(reader, new Translator(), server);
        reader.Lines = [Line("R2 Swing"), Line("23m", 0.5)];
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Empty(server.Sent);
    }

    [Fact]
    public async Task PackTranslationIsUsedBeforeTheEngine()
    {
        var (reader, translator, server) = (new Reader(), new Translator(), new Server());
        var watcher = new RegionWatcher(reader, translator, server)
        {
            PackLookup = text => text == "New message" ? new PackMatch("Yeni mesaj", []) : null,
        };
        reader.Lines = [Line("New message", 0.1), Line("Call me when you get this.", 0.25)];
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal(["Yeni mesaj\nTR: Call me when you get this."], server.Sent.Select(s => s.Text));
        Assert.Equal(["Call me when you get this."], translator.Calls);
    }

    [Theory]
    [InlineData(true, null, "Aç", false)]
    [InlineData(true, "Menüyü aç", "Menüyü aç", false)]
    [InlineData(false, null, "TR: OPEN", true)]
    public async Task CommandGlossaryRespectsPackAndLanguagePair(bool enabled, string? packText, string expected, bool usesEngine)
    {
        var reader = new Reader { Lines = [Line("OPEN")] };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server)
        {
            PackLookup = text => text == "OPEN" && packText is not null ? new PackMatch(packText, []) : null,
            TranslatesUiCommands = enabled,
        };
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal(expected, Assert.Single(server.Sent).Text);
        Assert.Equal(usesEngine ? 1 : 0, translator.Calls.Count);
    }

    [Fact]
    public async Task RemovedAreaLosesItsBoxAndResetClearsAll()
    {
        var (reader, server) = (new Reader(), new Server());
        var watcher = new RegionWatcher(reader, new Translator(), server);
        reader.Lines = [Line("Where are you?")];
        await watcher.PassAsync(Shade(10), [Quest, Phone]);
        await watcher.PassAsync(Shade(10), [Quest, Phone]);
        Assert.Equal(["p", "q"], server.Sent.Select(s => s.Id).Order());
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal(("p", ""), (server.Sent[^1].Id, server.Sent[^1].Text));
        watcher.Reset();
        Assert.Equal(1, server.Clears);
        watcher.Reset();
        Assert.Equal(1, server.Clears);
    }

    [Fact]
    public async Task OfferRunsAtMostOncePerInterval()
    {
        long clock = 0;
        var (reader, server) = (new Reader(), new Server());
        var watcher = new RegionWatcher(reader, new Translator(), server, clock: () => clock);
        reader.Lines = [Line("Find the blacksmith")];
        var frame = Shade(10);
        async Task OfferAndWait()
        {
            watcher.Offer(frame, [Quest]);
            while (watcher.IsBusy) await Task.Delay(5);
        }
        await OfferAndWait();
        const int interval = RegionWatcher.DefaultIntervalMs;
        for (var step = 1; step <= 9; step++)
        {
            clock = step * interval / 10;
            await OfferAndWait();
        }
        Assert.Equal(1, watcher.Passes);
        clock = interval;
        await OfferAndWait();
        Assert.Equal(2, watcher.Passes);
        Assert.Equal(["TR: Find the blacksmith"], server.Sent.Select(s => s.Text));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task EarlyConfirmationOnlyPublishesAnUnchangedCandidateWithoutOcr(bool changed)
    {
        long clock = 0;
        var reader = new Reader { Lines = [Line("Find the blacksmith")] };
        var server = new Server();
        var watcher = new RegionWatcher(reader, new Translator(), server, clock: () => clock);
        async Task Offer(Frame frame)
        {
            watcher.Offer(frame, [Quest]);
            while (watcher.IsBusy) await Task.Delay(1);
        }
        await Offer(Shade(10));
        clock = 249;
        await Offer(Shade(10));
        Assert.Empty(server.Sent);
        var next = Shade(changed ? (byte)100 : (byte)10);
        clock = 250;
        await Offer(next);
        Assert.Equal(1, reader.Count);
        Assert.Equal(changed ? 0 : 1, server.Sent.Count);

        reader.Lines = [Line("Talk to Arthur")];
        clock = 750;
        await Offer(Shade(100));
        Assert.Equal(1, reader.Count);
        clock = 1000;
        await Offer(Shade(100));
        Assert.Equal(2, reader.Count);
        clock = 1250;
        await Offer(Shade(100));
        Assert.Equal("TR: Talk to Arthur", server.Sent.Last().Text);
    }

    private static TextLine At(string text, double left, double top, double right, double bottom) =>
        new(text, new TextBox(left, top, right, bottom));

    private static TextBox InQuest(TextBox box)
    {
        var region = Quest.Region;
        return box.PlacedIn(new TextBox(region.Left, region.Top, region.Right, region.Bottom));
    }

    /// <summary>
    /// Alanda birbirinden ayrı duran yazılar (görev başlığı ve sola kaymış ayrı hedef) alt alta tek kutuda değil, her biri
    /// kendi yeriyle gider; eski TV'ler için birleşik metin de kalır.
    /// </summary>
    [Fact]
    public async Task SeparateGroupsInAnAreaAreSentAsBlocksAtTheirOwnPlaces()
    {
        var reader = new Reader { Lines = [At("Find the blacksmith", 0.5, 0.1, 0.95, 0.2), At("Go to the barn", 0.1, 0.6, 0.4, 0.7)] };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal(["TR: Find the blacksmith\nTR: Go to the barn"], server.Sent.Select(s => s.Text));
        var blocks = Assert.Single(server.Blocks)!;
        Assert.Equal(["TR: Find the blacksmith", "TR: Go to the barn"], blocks.Select(b => b.Translation));
        Assert.Equal(["Find the blacksmith", "Go to the barn"], blocks.Select(b => b.Source));
        Assert.Equal(InQuest(new TextBox(0.5, 0.1, 0.95, 0.2)), blocks[0].Box);
        Assert.Equal(InQuest(new TextBox(0.1, 0.6, 0.4, 0.7)), blocks[1].Box);
        var height = Quest.Region.Bottom - Quest.Region.Top;
        Assert.Equal(0.1 * height, blocks[0].LineHeight, 9);
        // Birleşik kutu iki yazıyı da kapsar (bloksuz eski TV uygulamaları için).
        Assert.Equal(InQuest(new TextBox(0.1, 0.1, 0.95, 0.7)), server.Sent[0].Box);
    }

    /// <summary>Tek grup (alt alta sarılmış tek yazı) eskisi gibi tek kutudur, blok gönderilmez.</summary>
    [Fact]
    public async Task OneGroupIsSentWithoutBlocks()
    {
        var reader = new Reader { Lines = [Line("Find the blacksmith and ask him", 0.2), Line("to repair your sword.", 0.3)] };
        var translator = new Translator { Map = _ => "Demirciyi bul ve kılıcını onarmasını iste." };
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal(["Find the blacksmith and ask him to repair your sword."], translator.Calls);
        Assert.Equal(["Demirciyi bul ve kılıcını onarmasını iste."], server.Sent.Select(s => s.Text));
        Assert.Equal([null], server.Blocks);
    }

    /// <summary>Çevirisi aslıyla aynı grup (ad) blok olarak gönderilmez; İngilizcesi görünür kalır.</summary>
    [Fact]
    public async Task UntranslatedGroupIsLeftOutOfTheBlocks()
    {
        var reader = new Reader { Lines = [At("Arthur", 0.1, 0.1, 0.3, 0.2), At("Meet me at the barn", 0.1, 0.6, 0.6, 0.7)] };
        var translator = new Translator { Map = text => text == "Arthur" ? "Arthur" : "TR: " + text };
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        var blocks = Assert.Single(server.Blocks)!;
        var block = Assert.Single(blocks);
        Assert.Equal("TR: Meet me at the barn", block.Translation);
        Assert.Equal(InQuest(new TextBox(0.1, 0.6, 0.6, 0.7)), block.Box);
    }

    /// <summary>Aynı yazı kayınca yeniden çevrilmez; bloklar aynı çeviriyle yeni yerlerine gönderilir.</summary>
    [Fact]
    public async Task MovedBlocksKeepTheirTranslations()
    {
        var reader = new Reader { Lines = [At("Find the blacksmith", 0.5, 0.1, 0.95, 0.2), At("Go to the barn", 0.1, 0.6, 0.4, 0.7)] };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        reader.Lines = [At("Find the blacksmith", 0.5, 0.1, 0.95, 0.2), At("Go to the barn", 0.1, 0.7, 0.4, 0.8)];
        await watcher.PassAsync(Shade(60), [Quest]);
        Assert.Equal(["Find the blacksmith", "Go to the barn"], translator.Calls);
        Assert.Equal(2, server.Sent.Count);
        var moved = server.Blocks[1]!;
        Assert.Equal(["TR: Find the blacksmith", "TR: Go to the barn"], moved.Select(b => b.Translation));
        Assert.Equal(InQuest(new TextBox(0.1, 0.7, 0.4, 0.8)), moved[1].Box);
        // Yer değişmeden yeniden okunan aynı yazı bir şey göndermez.
        await watcher.PassAsync(Shade(100), [Quest]);
        Assert.Equal(2, server.Sent.Count);
    }

    /// <summary>GTA 6'nın etkileşim menüsü: sağa yaslı, sıkışık satırlar; her birinin sağında kendi tuş simgesi var.</summary>
    private static List<TextLine> Gta6Menu() =>
        [At("HAIR", 0.80, 0.50, 0.92, 0.60), At("GREET", 0.76, 0.65, 0.92, 0.75), At("STYLIST", 0.70, 0.80, 0.92, 0.90)];

    /// <summary>
    /// GTA 6'da menünün her satırı kendi yerine çevrilir: tek kutuda satır aralığı tutmuyor, "SAÇ" HAIR ile GREET arasına
    /// düşüyor, HAIR açıkta kalıyordu. Her blok kendi satırının üstünde, sağdaki simgesinin yanında durur.
    /// </summary>
    [Fact]
    public async Task Gta6MenuRowsAreSentAsOneBlockPerRow()
    {
        var reader = new Reader { Lines = Gta6Menu() };
        var translator = new Translator { Map = text => text switch { "HAIR" => "SAÇ", "GREET" => "SELAM", _ => text } };
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server) { Game = () => "Grand Theft Auto VI" };
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal(["HAIR", "GREET", "STYLIST"], translator.Calls);
        var blocks = Assert.Single(server.Blocks)!;
        // STYLIST çevrilmedi (aynı kaldı): bloğu gönderilmez, İngilizcesi görünür kalır.
        Assert.Equal(["SAÇ", "SELAM"], blocks.Select(b => b.Translation));
        Assert.Equal(InQuest(new TextBox(0.80, 0.50, 0.92, 0.60)), blocks[0].Box);
        Assert.Equal(InQuest(new TextBox(0.76, 0.65, 0.92, 0.75)), blocks[1].Box);
    }

    /// <summary>Menü satırlarını bölme yalnız GTA 6'da: başka oyunda (ya da oyun bilinmiyorsa) yerleşim değişmez.</summary>
    [Theory]
    [InlineData("Red Dead Redemption 2")]
    [InlineData(null)]
    public async Task MenuRowsStayInOneBoxOutsideGta6(string? game)
    {
        var reader = new Reader { Lines = Gta6Menu() };
        var server = new Server();
        var watcher = new RegionWatcher(reader, new Translator(), server) { Game = () => game };
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal([null], server.Blocks);
    }

    /// <summary>GTA 6'da da büyük-küçük harfli bilgi kutusu bölünmez: tek cümle, tek kutu.</summary>
    [Fact]
    public async Task Gta6InfoTextIsNotSplitIntoRows()
    {
        var reader = new Reader { Lines = [Line("Your actions will affect your criminal", 0.2), Line("profile and may have a lasting impact.", 0.3)] };
        var server = new Server();
        var watcher = new RegionWatcher(reader, new Translator(), server) { Game = () => "GTA 6" };
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal([null], server.Blocks);
    }

    /// <summary>Kararlı gösterilip shown edilmiş yazı.</summary>
    private static async Task Show(RegionWatcher watcher, Reader reader, string text, byte shade)
    {
        reader.Lines = [Line(text)];
        await watcher.PassAsync(Shade(shade), [Quest]);
        await watcher.PassAsync(Shade(shade), [Quest]);
    }

    /// <summary>Görev yazısı arada kaybolup yeniden çıkınca çevirmene yeniden gidilmez.</summary>
    [Fact]
    public async Task ReappearingTextUsesTheEarlierTranslation()
    {
        var (reader, translator, server) = (new Reader(), new Translator(), new Server());
        var watcher = new RegionWatcher(reader, translator, server);
        await Show(watcher, reader, "Find the blacksmith", 10);
        await Show(watcher, reader, "", 90);
        await Show(watcher, reader, "Find the blacksmith", 170);
        Assert.Equal(["Find the blacksmith"], translator.Calls);
        Assert.Equal(["TR: Find the blacksmith", "", "TR: Find the blacksmith"], server.Sent.Select(s => s.Text));
    }

    /// <summary>
    /// Yazı belirirken renkli sözcük geç geliyor: az önce gösterilen yazının başı okunursa tamamı beklenir; görev iki kez
    /// çevrilip değişmez.
    /// </summary>
    [Fact]
    public async Task PartialReadingOfTheLastTextWaitsForTheWholeText()
    {
        var (reader, translator, server) = (new Reader(), new Translator(), new Server());
        var watcher = new RegionWatcher(reader, translator, server);
        await Show(watcher, reader, "Fly to a drop point", 10);
        await Show(watcher, reader, "", 90);
        await Show(watcher, reader, "Fly to a", 170);
        reader.Lines = [Line("Fly to a drop point")];
        await watcher.PassAsync(Shade(250), [Quest]);
        await watcher.PassAsync(Shade(250), [Quest]);
        Assert.Equal(["Fly to a drop point"], translator.Calls);
        Assert.Equal(["TR: Fly to a drop point", "", "TR: Fly to a drop point"], server.Sent.Select(s => s.Text));
    }

    /// <summary>Arka plan oynarken ekrandakinin harfi bozuk okuması kutuyu değiştirmez.</summary>
    [Fact]
    public async Task NearlySameReadingKeepsTheShownText()
    {
        var (reader, translator, server) = (new Reader(), new Translator(), new Server());
        var watcher = new RegionWatcher(reader, translator, server);
        await Show(watcher, reader, "SET DESTINATION EXIT", 10);
        await Show(watcher, reader, "SET DESTINATIPN EXIT", 90);
        await Show(watcher, reader, "SET DESTINATION EXIT", 170);
        Assert.Equal(["SET DESTINATION EXIT"], translator.Calls);
        Assert.Single(server.Sent);
    }

    /// <summary>Yalnız bir sözcüğü değişen görev, o hâlde kalırsa birkaç tur sonra gösterilir.</summary>
    [Fact]
    public async Task NearlySameTextThatStaysIsShownAfterTheHoldLimit()
    {
        var (reader, translator, server) = (new Reader(), new Translator(), new Server());
        var watcher = new RegionWatcher(reader, translator, server);
        await Show(watcher, reader, "Go to the barn", 10);
        await Show(watcher, reader, "Go to the bank", 90);
        Assert.Single(server.Sent);
        for (var i = 0; i < RegionWatcher.HoldLimit; i++) await watcher.PassAsync(Shade(90), [Quest]);
        Assert.Equal(["TR: Go to the barn", "TR: Go to the bank"], server.Sent.Select(s => s.Text));
    }


    [Theory]
    [InlineData("Find the blacksmith", "Escape")]
    [InlineData("Meet me at gate 5", "Meet me at gate 6")]
    [InlineData("You can open it", "You can't open it")]
    public async Task ConfirmedNewPromptDoesNotWaitForTheHoldLimit(string first, string next)
    {
        var reader = new Reader();
        var server = new Server();
        var watcher = new RegionWatcher(reader, new Translator(), server);
        await Show(watcher, reader, first, 10);
        await Show(watcher, reader, next, 90);
        Assert.Equal(["TR: " + first, "TR: " + next], server.Sent.Select(s => s.Text));
    }

    [Fact]
    public async Task IntermittentTypoDoesNotAccumulateHolds()
    {
        var reader = new Reader();
        var server = new Server();
        var watcher = new RegionWatcher(reader, new Translator(), server);
        await Show(watcher, reader, "Go to the barn", 10);
        for (var i = 0; i <= RegionWatcher.HoldLimit; i++)
        {
            await Show(watcher, reader, "Go to the bank", 90);
            await Show(watcher, reader, "Go to the barn", 10);
        }
        Assert.Equal(["TR: Go to the barn"], server.Sent.Select(s => s.Text));
    }

    [Fact]
    public async Task CancelledConfirmedTranslationCanBeRetriedOnTheSameFrame()
    {
        var reader = new Reader { Lines = [Line("Find the blacksmith")] };
        var translator = new Translator { Respond = _ => Task.FromCanceled<string>(new CancellationToken(true)) };
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Empty(translator.Calls);
        await watcher.PassAsync(Shade(10), [Quest]);
        translator.Respond = null;
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Equal(["Find the blacksmith", "Find the blacksmith"], translator.Calls);
        Assert.Equal(["TR: Find the blacksmith"], server.Sent.Select(s => s.Text));
    }

    [Fact]
    public async Task FailedTranslationDoesNotHoldTheNextConfirmedPrompt()
    {
        var reader = new Reader();
        var translator = new Translator { FailuresRemaining = 1 };
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server);
        await Show(watcher, reader, "Find the blacksmith", 10);
        await Show(watcher, reader, "Find", 90);
        Assert.Equal(["TR: Find"], server.Sent.Select(s => s.Text));
    }

    [Fact]
    public void PartialAndWordLosingReadingsAreRecognised()
    {
        Assert.True(RegionWatcher.IsPartOf("add marker set destination", "add marker set destination exit"));
        Assert.False(RegionWatcher.IsPartOf("talk to arthur", "meet arthur at the barn"));
        Assert.True(RegionWatcher.LosesWords("find ￼", "find donnie"));
        Assert.False(RegionWatcher.LosesWords("hold ￼ to climb", "hold to climb"));
    }

    [Fact]
    public void TextKeyKeepsButtonIcons()
    {
        Assert.Equal("set destination ￼ exit", RegionWatcher.TextKey(["SET DESTINATION ￼ EXIT"]));
        Assert.NotEqual(RegionWatcher.TextKey(["SET DESTINATION"]), RegionWatcher.TextKey(["SET DESTINATION ￼"]));
    }

    [Fact]
    public void NoAreasMeansNoWork()
    {
        var reader = new Reader();
        var watcher = new RegionWatcher(reader, new Translator(), new Server());
        watcher.Offer(Shade(10), []);
        Assert.False(watcher.IsBusy);
        Assert.Equal(0, reader.Count);
    }

    private static readonly WatchedArea AutoArea = new("auto-1", ScreenTextDetector.AreaName, new CropRegion(0.02, 0.2, 0.02, 0.4)) { Auto = true };

    [Fact]
    public async Task AutoAreaTranslatesRealTextInPlace()
    {
        var reader = new Reader { Lines = [Line("Lamar has sent you a message.")] };
        var server = new Server();
        var rejected = new List<string>();
        var translator = new Translator { Map = _ => "Lamar sana mesaj gönderdi." };
        var watcher = new RegionWatcher(reader, translator, server) { Rejected = rejected.Add };
        await watcher.PassAsync(Shade(10), [AutoArea]);
        await watcher.PassAsync(Shade(10), [AutoArea]);
        Assert.Equal(["auto-1|Lamar sana mesaj gönderdi."], server.Sent.Select(item => item.Id + "|" + item.Text));
        Assert.Empty(rejected);
    }

    [Theory]
    [InlineData("$1,250")]
    [InlineData("HONOR")]
    [InlineData("LIQUOR STORE")]
    public async Task AutoAreaWithNoiseIsRejectedNotTranslated(string text)
    {
        var reader = new Reader { Lines = [Line(text)] };
        var translator = new Translator();
        var server = new Server();
        var rejected = new List<string>();
        var watcher = new RegionWatcher(reader, translator, server) { Rejected = rejected.Add };
        await watcher.PassAsync(Shade(10), [AutoArea]);
        await watcher.PassAsync(Shade(10), [AutoArea]);
        Assert.Empty(translator.Calls);
        Assert.Empty(server.Sent);
        Assert.Equal(["auto-1"], rejected);
    }

    [Fact]
    public async Task AutoAreaWithoutTextIsRejected()
    {
        var server = new Server();
        var rejected = new List<string>();
        var watcher = new RegionWatcher(new Reader(), new Translator(), server) { Rejected = rejected.Add };
        await watcher.PassAsync(Shade(10), [AutoArea]);
        await watcher.PassAsync(Shade(10), [AutoArea]);
        Assert.Equal(["auto-1"], rejected);
        Assert.Empty(server.Sent);
    }

    [Fact]
    public async Task NoiseInAUserAreaIsStillHandledAsBefore()
    {
        // Gürültü elemesi yalnız otomatik alanlarda: kullanıcının alanı eskisi gibi çevrilir.
        var reader = new Reader { Lines = [Line("LIQUOR STORE")] };
        var server = new Server();
        var rejected = new List<string>();
        var watcher = new RegionWatcher(reader, new Translator(), server) { Rejected = rejected.Add };
        await watcher.PassAsync(Shade(10), [Quest]);
        await watcher.PassAsync(Shade(10), [Quest]);
        Assert.Empty(rejected);
        Assert.Equal(["TR: LIQUOR STORE"], server.Sent.Select(item => item.Text));
    }

    [Fact]
    public async Task AutoAreasAreReadEveryHalfSecond()
    {
        long clock = 0;
        var reader = new Reader { Lines = [Line("Follow Paulie to the car.")] };
        var watcher = new RegionWatcher(reader, new Translator(), new Server(), clock: () => clock);
        watcher.Offer(Shade(10), [AutoArea]);
        await WaitForPass(watcher);
        clock = RegionWatcher.AutoIntervalMs;
        watcher.Offer(Shade(20), [AutoArea]);
        await WaitForPass(watcher);
        Assert.Equal(2, watcher.Passes);

        var user = new RegionWatcher(reader, new Translator(), new Server(), clock: () => clock);
        clock = 0;
        user.Offer(Shade(10), [Quest]);
        await WaitForPass(user);
        clock = RegionWatcher.AutoIntervalMs;
        user.Offer(Shade(20), [Quest]);
        await WaitForPass(user);
        Assert.Equal(1, user.Passes);
    }

    private static readonly WatchedArea MenuLabel = new("auto-2", ScreenTextDetector.AreaName, new CropRegion(0.2, 0.3, 0.2, 0.3)) { Auto = true, Menu = true };

    [Fact]
    public async Task MenuLabelIsTranslatedFromTheDictionaryAtOnce()
    {
        var reader = new Reader { Lines = [Line("OFF")] };
        var translator = new Translator();
        var server = new Server();
        var watcher = new RegionWatcher(reader, translator, server) { TranslatesUiCommands = true };
        await watcher.PassAsync(Shade(10), [MenuLabel]);
        await watcher.PassAsync(Shade(10), [MenuLabel]);
        Assert.Empty(translator.Calls);
        Assert.Equal(["KAPALI"], server.Sent.Select(item => item.Text));
    }

    [Fact]
    public async Task NumberLabelInAMenuIsNotDrawn()
    {
        var reader = new Reader { Lines = [Line("40")] };
        var server = new Server();
        var rejected = new List<string>();
        var watcher = new RegionWatcher(reader, new Translator(), server) { TranslatesUiCommands = true, Rejected = rejected.Add };
        await watcher.PassAsync(Shade(10), [MenuLabel]);
        await watcher.PassAsync(Shade(10), [MenuLabel]);
        Assert.Empty(server.Sent.Where(item => item.Text.Length > 0));
    }
}
