// SPDX-License-Identifier: AGPL-3.0-only
namespace CouchSubs.Core.Tests;

/// <summary>
/// X'te iki kişi: diyalogda her altyazı iki kez çıkıyor, önce beyaz (adsız), sonra adıyla renkli. Renkli konuşan adı ilk
/// karelerde okunamıyor, cümle adsız çevrilip gösteriliyor; ad okununca aynı cümle yeni satır sayılıp yeniden çevriliyordu
/// (Mac/iPhone: SpeakerReadLateTests.swift, Android: SpeakerReadLateTest.kt).
/// </summary>
public class SpeakerReadLateTests
{
    /// <summary>Çevirisi kaynağa benzemeyen motor (benzerse hat "zaten hedef dilde" sayıp göstermez).</summary>
    private sealed class Translator : ITextTranslator
    {
        private readonly GatedTranslator gate = new();
        public List<string> Requested => gate.Requested;
        public void Open() => gate.Open();
        public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            await gate.TranslateAsync(text, cancellationToken);
            lock (gate) return $"Çeviri {Requested.Count}.";
        }
    }

    private static async Task<(Translator Translator, FakeSender Sender)> Replay(string[] frames, bool open = true, bool showNames = true)
    {
        long clock = 0;
        var translator = new Translator();
        if (open) translator.Open();
        var sender = new FakeSender();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock) { ShowSpeakerNames = showNames };
        try
        {
            for (var i = 0; i < frames.Length; i++)
            {
                await pipeline.ProcessAsync(Frame.Blank(64, 64), new CropRegion());
                if (open) await pipeline.WaitForTranslationsAsync();
                else if (i == 0) for (var n = 0; n < 200 && translator.Requested.Count == 0; n++) await Task.Delay(5);
                clock += 150;
            }
        }
        finally { translator.Open(); await pipeline.WaitForTranslationsAsync(); }
        return (translator, sender);
    }

    [Theory]
    [InlineData("We need to go now.")]
    [InlineData("Come on.")]
    [InlineData("Jus- Just be quiet. Donnie's up.")]
    [InlineData("You know what I mean, right?")]
    public async Task NameReadLaterUpdatesTheShownLineWithoutTranslatingAgain(string sentence)
    {
        var (translator, sender) = await Replay([sentence, "JASON: " + sentence, "JASON: " + sentence]);
        Assert.Equal(new[] { sentence }, translator.Requested);
        Assert.Equal(new[] { "Çeviri 1.", "JASON: Çeviri 1." }, sender.Sent);
        Assert.Equal(new[] { false, true }, sender.Replaces);
    }

    [Fact]
    public async Task NameOnItsOwnRowIsTheSameLine()
    {
        var (translator, sender) = await Replay(["What the hell was that?", "JASON:\nWhat the hell was that?"]);
        Assert.Equal(new[] { "What the hell was that?" }, translator.Requested);
        Assert.Equal("JASON: Çeviri 1.", sender.Sent[^1]);
        Assert.True(sender.Replaces[^1]);
    }

    [Fact]
    public async Task NameReadWhileTranslatingShowsOnlyTheNamedLine()
    {
        var (translator, sender) = await Replay(["We need to go now.", "JASON: We need to go now.", "JASON: We need to go now."], open: false);
        Assert.Equal(new[] { "We need to go now." }, translator.Requested);
        Assert.Equal(new[] { "JASON: Çeviri 1." }, sender.Sent);
    }

    [Fact]
    public async Task FlickeringNameIsOneLine()
    {
        var (translator, sender) = await Replay(["Come on.", "JASON: Come on.", "Come on.", "JASON: Come on.", "Come on."]);
        Assert.Equal(new[] { "Come on." }, translator.Requested);
        Assert.Equal(new[] { "Çeviri 1.", "JASON: Çeviri 1." }, sender.Sent);

        var (named, first) = await Replay(["JASON: Come on.", "Come on.", "JASON: Come on.", "Come on."]);
        Assert.Equal(new[] { "Come on." }, named.Requested);
        Assert.Equal(new[] { "JASON: Çeviri 1." }, first.Sent);
    }

    [Fact]
    public async Task NamesHiddenSendsNothingNew()
    {
        var (translator, sender) = await Replay(["We need to go now.", "JASON: We need to go now."], showNames: false);
        Assert.Equal(new[] { "We need to go now." }, translator.Requested);
        Assert.Equal(new[] { "Çeviri 1." }, sender.Sent);
    }

    [Fact]
    public async Task DifferentSentenceWithNameIsStillANewLine()
    {
        var (translator, sender) = await Replay(["We need to go now.", "JASON: We don't need to go now."]);
        Assert.Equal(new[] { "We need to go now.", "We don't need to go now." }, translator.Requested);
        Assert.Equal(2, sender.Sent.Count);

        var (other, _) = await Replay(["We need to go now.", "LUCIA: Where are we going?"]);
        Assert.Equal(new[] { "We need to go now.", "Where are we going?" }, other.Requested);
    }

    [Fact]
    public void StabilizerTreatsUnnamedRereadOfNamedLineAsSame()
    {
        Assert.True(SubtitleStabilizer.IsUnnamedReread("Come on.", "JASON: Come on."));
        Assert.True(SubtitleStabilizer.IsUnnamedReread("What the hell was that?", "Jason:\nWhat the hell was that?"));
        Assert.False(SubtitleStabilizer.IsUnnamedReread("Come on.", "Come on."));
        Assert.False(SubtitleStabilizer.IsUnnamedReread("LUCIA: Come on.", "JASON: Come on."));
        Assert.False(SubtitleStabilizer.IsUnnamedReread("Go home.", "JASON: Come on."));
    }
}
