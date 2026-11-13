// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Terim sözlüğü ve koruma (Mac: GlossaryTests).</summary>
public class GlossaryTests
{
    private const string GodOfWar = """
        { "game": "God of War",
          "terms": { "Leviathan Axe": "Leviathan Baltası", "Axe": "Balta", "Midgard": "Midgard", "World Serpent": "Dünya Yılanı" },
          "keep": ["Kratos", "Atreus"] }
        """;

    private static Glossary Gow => Glossary.Parse(GodOfWar);

    [Fact]
    public void ParsesTermsAndKeepNames()
    {
        var glossary = Gow;
        Assert.Equal(6, glossary.Count);
        Assert.Equal("Leviathan Baltası", glossary.Turkish("leviathan  axe"));
        Assert.Equal("Kratos", glossary.Turkish("KRATOS"));
        Assert.Null(glossary.Turkish("Freya"));
    }

    [Fact]
    public void FindsWholeWordsCaseInsensitiveLongestFirst()
    {
        var found = Gow.Find("THROW THE LEVIATHAN AXE, then the axe. Kratos's axes. Midgardian.");
        Assert.Equal(["Leviathan Axe", "Axe", "Kratos"], found.Select(m => m.English));
        Assert.Equal(10, found[0].Start);
    }

    [Fact]
    public void CapitalizedTermsAndKeepNamesAreCapitalWords()
    {
        Assert.Equal(new[] { "atreus", "axe", "kratos", "leviathan", "midgard", "serpent", "world" }, Gow.CapitalWords.Order());
        Assert.DoesNotContain("health", Glossary.BuiltIn.CapitalWords);
    }

    [Fact]
    public void BuiltInGlossaryHasGeneralGameTerms()
    {
        Assert.True(Glossary.BuiltIn.Count >= 10);
        Assert.Equal("can iksiri", Glossary.BuiltIn.Turkish("Health Potion"));
        Assert.Equal("yetenek ağacı", Glossary.BuiltIn.Turkish("skill tree"));
    }

    // Phantom Blade Zero: kahramanın adı "Soul" çevrilmez, sıradan "soul" çevrilir (Emir, 2026-11-13).
    [Fact]
    public void KeepExactNamesMatchOnlyAsWritten()
    {
        var found = Glossary.BuiltIn.Find("Soul, you sold your soul. SOUL!");
        Assert.Equal(["Soul"], found.Select(m => m.English));
        Assert.Equal(0, found[0].Start);
        Assert.DoesNotContain("soul", Glossary.BuiltIn.CapitalWords);
        Assert.NotEqual(Glossary.Parse("""{ "keep": ["Soul"] }""").Fingerprint, Glossary.Parse("""{ "keepExact": ["Soul"] }""").Fingerprint);
    }

    [Fact]
    public void LaterGlossaryWinsAndFingerprintFollowsContent()
    {
        var user = Glossary.Parse("""{ "terms": { "skill tree": "beceri ağacı" } }""");
        var merged = Glossary.Merge([Glossary.BuiltIn, user]);
        Assert.Equal("beceri ağacı", merged.Turkish("skill tree"));
        Assert.NotEqual(Glossary.BuiltIn.Fingerprint, merged.Fingerprint);
        Assert.Equal(merged.Fingerprint, Glossary.Merge([Glossary.BuiltIn, user]).Fingerprint);
    }

    [Fact]
    public void IgnoresEntriesWithoutLetters() =>
        Assert.Equal(1, Glossary.Parse("""{ "terms": { "...": "x", "Odin": "Odin", "": "y" }, "keep": [3] }""").Count);

    [Fact]
    public void LoadsUserFolderAndSkipsBrokenFiles()
    {
        var directory = Path.Combine(Path.GetTempPath(), "couchsubs-glossary-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            File.WriteAllText(Path.Combine(directory, "gow.json"), GodOfWar);
            File.WriteAllText(Path.Combine(directory, "broken.json"), "{ not json");
            File.WriteAllText(Path.Combine(directory, "notes.txt"), """{ "keep": ["Ignored"] }""");
            var glossary = Glossary.Load(directory);
            Assert.Equal("Leviathan Baltası", glossary.Turkish("Leviathan Axe"));
            Assert.Equal("can iksiri", glossary.Turkish("health potion"));
            Assert.Null(glossary.Turkish("Ignored"));
            Assert.Equal(Glossary.BuiltIn.Count, Glossary.Load(Path.Combine(directory, "missing")).Count);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void StoreReloadsWhenAFileChanges()
    {
        var directory = Path.Combine(Path.GetTempPath(), "couchsubs-glossary-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var now = DateTimeOffset.UnixEpoch;
        try
        {
            var store = new GlossaryStore(directory, () => now);
            Assert.Null(store.Current.Turkish("Kratos"));
            File.WriteAllText(Path.Combine(directory, "gow.json"), GodOfWar);
            // Klasöre birkaç saniyede bir bakılır.
            Assert.Null(store.Current.Turkish("Kratos"));
            now += TimeSpan.FromSeconds(6);
            Assert.Equal("Kratos", store.Current.Turkish("Kratos"));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}

/// <summary>Yer tutucuyla terim koruma (Mac: TermProtectionTests).</summary>
public class TermProtectionTests
{
    private static readonly Glossary Gow = Glossary.Parse("""
        { "terms": { "Leviathan Axe": "Leviathan Baltası", "Midgard": "Midgard", "health potion": "can iksiri" },
          "keep": ["Kratos", "Atreus"] }
        """);

    [Fact]
    public void ReplacesTermsWithPlaceholderNames()
    {
        var protector = new TermProtector(Gow, "");
        var (text, slots) = protector.Protect("Kratos, take the Leviathan Axe to Midgard. Kratos!");
        Assert.Equal("Zarmon, take the Velkor to Dorvan. Zarmon!", text);
        Assert.Equal(["Kratos", "Leviathan Axe", "Midgard"], slots.Select(s => s.English));
    }

    [Theory]
    [InlineData("Zarmon, Velkor'u Dorvan'a götür. Zarmon!", "Kratos, Leviathan Baltası'nı Midgard'a götür. Kratos!")]
    [InlineData("ZARMON, VELKOR'U DORVAN'A GÖTÜR. ZARMON!", "Kratos, Leviathan Baltası'nı Midgard'a GÖTÜR. Kratos!")]
    [InlineData("Zarmon, Velkor ’u Dorvana götür. Zarmon!", "Kratos, Leviathan Baltası'nı Midgard'a götür. Kratos!")]
    public void RestoresTermsWithSuffixesDespiteCaseAndSpacing(string output, string expected)
    {
        var protector = new TermProtector(Gow, "");
        var (_, slots) = protector.Protect("Kratos, take the Leviathan Axe to Midgard. Kratos!");
        Assert.Equal(expected, TermProtector.Restore(output, slots, protector.AllSlots));
    }

    [Fact]
    public void MissingPlaceholderMeansUnreliable()
    {
        var protector = new TermProtector(Gow, "");
        var (_, slots) = protector.Protect("Take the Leviathan Axe to Midgard.");
        Assert.Null(TermProtector.Restore("Baltayı Dorvan'a götür.", slots, protector.AllSlots));
    }

    [Fact]
    public void PlaceholderFromAnotherPartMeansUnreliable()
    {
        var protector = new TermProtector(Gow, "");
        protector.Protect("Kratos!");
        var (_, slots) = protector.Protect("Go to Midgard.");
        Assert.Null(TermProtector.Restore("Zarmon Velkor'a git.", slots, protector.AllSlots));
        Assert.Equal("Midgard'a git.", TermProtector.Restore("Velkor'a git.", slots, protector.AllSlots));
    }

    [Fact]
    public void CommonNounAtSentenceStartIsCapitalized()
    {
        var protector = new TermProtector(Gow, "");
        var (_, slots) = protector.Protect("Drink the health potion. Health potion first!");
        Assert.Equal("Can iksirini iç. Önce can iksiri!", TermProtector.Restore("Zarmon'u iç. Önce Zarmon!", slots));
    }

    [Fact]
    public void QuotedPlaceholderIsNotASuffix()
    {
        var protector = new TermProtector(Gow, "");
        var (_, slots) = protector.Protect("He said 'Midgard' again.");
        Assert.Equal("Yine 'Midgard' dedi.", TermProtector.Restore("Yine 'Zarmon' dedi.", slots));
    }

    [Fact]
    public void PlaceholderAlreadyInTheSourceIsSkipped()
    {
        var protector = new TermProtector(Gow, "Zarmon met Kratos.");
        Assert.Equal("Zarmon met Velkor.", protector.Protect("Zarmon met Kratos.").Text);
    }

    [Fact]
    public void TextWithoutTermsIsUnchanged()
    {
        var protector = new TermProtector(Gow, "");
        var (text, slots) = protector.Protect("We go now.");
        Assert.Equal("We go now.", text);
        Assert.Empty(slots);
        Assert.Equal("Şimdi gidiyoruz.", TermProtector.Restore("Şimdi gidiyoruz.", slots, protector.AllSlots));
    }
}
