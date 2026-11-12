// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

public class SubtitleLogTests
{
    [Fact]
    public void WritesOnlyWhileEnabledAndKeepsOneBackup()
    {
        var folder = Path.Combine(Path.GetTempPath(), "altyazi-log-" + Guid.NewGuid());
        var file = Path.Combine(folder, "altyazi.log");
        try
        {
            SubtitleLog.Write("yazılmamalı");
            SubtitleLog.Enable(file);
            SubtitleLog.Write("#1 \"Get down!\" → paket:mafia");
            SubtitleLog.Disable();
            SubtitleLog.Write("bu da yazılmamalı");
            var text = File.ReadAllText(file);
            Assert.Contains("] #1 \"Get down!\" → paket:mafia\n", text);
            Assert.DoesNotContain("yazılmamalı", text);
            Assert.StartsWith("[20", text);

            // Dosya 1 MB'yi geçince .1'e taşınır; ikinci taşımada eski yedek silinir (en çok ~2 MB).
            File.WriteAllText(file, new string('x', (int)SubtitleLog.MaxBytes));
            SubtitleLog.Enable(file);
            SubtitleLog.Write("yeni dosya");
            SubtitleLog.Flush();
            Assert.Equal(SubtitleLog.MaxBytes, new FileInfo(file + ".1").Length);
            Assert.Contains("yeni dosya", File.ReadAllText(file));
            File.WriteAllText(file, new string('y', (int)SubtitleLog.MaxBytes));
            SubtitleLog.Write("üçüncü");
            SubtitleLog.Disable();
            Assert.Equal('y', File.ReadAllText(file + ".1")[0]);
            Assert.Contains("üçüncü", File.ReadAllText(file));
        }
        finally
        {
            SubtitleLog.Disable();
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void ExcerptIsQuotedSingleLineAndShort()
    {
        Assert.Equal("\"ENZO: Get down! / Now!\"", SubtitleLog.Excerpt("ENZO: Get down!\nNow!"));
        var longText = SubtitleLog.Excerpt(new string('a', 300));
        Assert.Equal(SubtitleLog.ExcerptLength + 2, longText.Length);
        Assert.EndsWith("…\"", longText);
    }

    [Fact]
    public void VideoStallTrackerReportsGapFromChiakiLines()
    {
        var clock = new TestClock();
        var tracker = new VideoStallTracker(clock.Read);
        Assert.Null(tracker.Note("[chiaki info] Received IDR frame, resuming decode"));
        Assert.Equal("görüntü durdu: FEC hatası, IDR karesi bekleniyor", tracker.Note("[chiaki info] FEC failed, waiting for IDR frame"));
        Assert.Null(tracker.Note("[chiaki warning] Video FEC failure, already waiting for requested IDR"));
        clock.Now += 1234;
        Assert.Equal("görüntü sürdü: IDR karesi geldi (1234 ms boşluk)", tracker.Note("[chiaki info] Received IDR frame, resuming decode"));
        Assert.Null(tracker.Note("[chiaki info] StreamConnection requesting IDR frame"));
    }

    /// <summary>Önbellekten dönen satır "önbellek", motorun yeni çevirdiği satır o motorun adıyla görünür.</summary>
    [Fact]
    public async Task ProbeTellsCacheHitsFromFreshTranslations()
    {
        var cache = new TranslationCache(engine: "deepl");
        var fresh = await Probe(() => { if (!cache.TryGet("Run!", out _)) cache.Store("Run!", "Koş!"); });
        Assert.Equal("çeviri:deepl", fresh.Outcome());
        var cached = await Probe(() => { cache.TryGet("Run!", out _); cache.Store("Run!", "Koş!"); });
        Assert.Equal("önbellek", cached.Outcome());
        Assert.Equal("çeviri:opus", new TranslationProbe().Outcome("opus"));
        Assert.Null(TranslationProbe.Current);
    }

    private static async Task<TranslationProbe> Probe(Action work)
    {
        var probe = new TranslationProbe();
        TranslationProbe.Current = probe;
        await Task.Yield();
        work();
        return probe;
    }

    /// <summary>Günlük için: kararlı olmadan kalkan çöp okuma ve yok sayılan kötü yeniden okuma not edilir; kararlar değişmez.</summary>
    [Fact]
    public void StabilizerNotesGarbledDropAndWorseReread()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        const string garbled = "- Nat) but, you knpw. shit, I m";
        Assert.Equal(StabilizerAction.None, s.Feed(garbled));
        Assert.Null(s.Note);
        clock.Now += 100;
        Assert.Equal(StabilizerAction.None, s.Feed(""));
        Assert.Equal(new StabilizerNote(StabilizerNoteKind.GarbledDropped, garbled), s.Note);
        s.Feed("");
        Assert.Null(s.Note);

        const string full = "Shit, I just came by to see if there's somethin' I can help you with.";
        const string worse = "Shit, I came by to see if there somethinl I can help ya.";
        Assert.Equal(StabilizerAction.Translate(full), s.Feed(full));
        s.Feed(worse);
        Assert.Equal(StabilizerAction.None, s.Feed(worse));
        Assert.Equal(new StabilizerNote(StabilizerNoteKind.WorseReread, worse), s.Note);
    }
}
