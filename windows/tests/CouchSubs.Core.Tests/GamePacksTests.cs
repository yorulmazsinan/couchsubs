// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;

namespace CouchSubs.Core.Tests;

/// <summary>Mac ile ortak deneme dosyaları: core/Tests/CouchSubsCoreTests/Fixtures.</summary>
internal static class PackFixtures
{
    public static string Path(string name, [CallerFilePath] string source = "") =>
        System.IO.Path.GetFullPath(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(source)!, "..", "..", "..",
            "core", "Tests", "CouchSubsCoreTests", "Fixtures", name));

    public static string TemporaryDirectory()
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "packs-" + Guid.NewGuid());
        Directory.CreateDirectory(path);
        return path;
    }
}

public class PackKeyTests
{
    private sealed record Vector(string input, string canon, string key);

    /// <summary>Mac ve paket hazırlayan Python betiği (canon.py) ile aynı sonuç: Fixtures/golden-vectors.json.</summary>
    [Fact]
    public void GoldenVectors()
    {
        var vectors = JsonSerializer.Deserialize<List<Vector>>(File.ReadAllText(PackFixtures.Path("golden-vectors.json")))!;
        Assert.Equal(15, vectors.Count);
        foreach (var vector in vectors)
        {
            Assert.Equal(vector.canon, PackKey.Canon(vector.input));
            Assert.Equal(vector.key, PackKey.Key(vector.input) ?? "");
        }
    }

    [Fact]
    public void TagsLongerThanFortyCharactersStay()
    {
        Assert.Equal("a   c", PackKey.StripTags("a <b> c"));
        var tooLong = "<" + new string('x', 41) + ">";
        Assert.Equal(tooLong, PackKey.StripTags(tooLong));
        Assert.Equal(" ", PackKey.StripTags("<" + new string('x', 40) + ">"));
        Assert.Equal("a < b   c", PackKey.StripTags("a < b <i> c"));
        Assert.Equal("< >", PackKey.StripTags("<<b>>"));
    }
}

public class GamePackTests
{
    private static GamePack Load(string name) => GamePack.Decode(File.ReadAllBytes(PackFixtures.Path(name)), name.Replace(".json.gz", ""));

    [Fact]
    public void WrappedAndBareFormatsLoad()
    {
        var wrapped = Load("pack-wrapped.json.gz");
        Assert.Equal("test-game", wrapped.Id);
        Assert.Equal("Test Game", wrapped.Title);
        Assert.Equal(5, wrapped.Entries.Count);
        var bare = Load("pack-bare.json.gz");
        Assert.Equal("pack-bare", bare.Id);
        Assert.Equal("pack-bare", bare.Title);
        Assert.Equal(2, bare.Entries.Count);
    }

    [Fact]
    public void PlainJsonIsAccepted()
    {
        var key = PackKey.Key("Get back!")!;
        var pack = GamePack.Decode(Encoding.UTF8.GetBytes($"{{\"{key}\": \"Geri çekil!\"}}"), "plain");
        Assert.Equal("Geri çekil!", pack.Entries[PackKey.Number(key)!.Value]);
    }

    [Fact]
    public void BrokenFilesAreRejected()
    {
        Assert.Throws<InvalidDataException>(() => GamePack.Decode(Encoding.UTF8.GetBytes("not json"), "x"));
        Assert.Throws<InvalidDataException>(() => GamePack.Decode([0x1f, 0x8b, 8, 0, .. Enumerable.Repeat((byte)7, 30)], "x"));
        Assert.Throws<InvalidDataException>(() => GamePack.Decode(Encoding.UTF8.GetBytes("{\"format\":3,\"entries\":{\"0123456789abcdef\":\"x\"}}"), "x"));
        Assert.Throws<InvalidDataException>(() => GamePack.Decode(Encoding.UTF8.GetBytes("{\"bad\":\"x\"}"), "x"));
    }

    /// <summary>Paketteki Türkçede kalan biçim etiketleri TV'ye gitmez.</summary>
    [Fact]
    public void TagsAreRemovedFromTurkish()
    {
        var pack = Load("pack-wrapped.json.gz");
        var key = PackKey.Number(PackKey.Key("<b><h>SCANNATURI SPECIALE</></> KNIFE")!)!.Value;
        Assert.Equal("SCANNATURI SPECIALE BIÇAĞI", pack.Entries[key]);
    }

    [Fact]
    public void LibraryMergesBundledAndUserPacks()
    {
        var user = PackFixtures.TemporaryDirectory();
        IEnumerable<(string, byte[])> Bundled() =>
        [
            ("a.json.gz", File.ReadAllBytes(PackFixtures.Path("pack-bare.json.gz"))),
            ("b.json.gz", File.ReadAllBytes(PackFixtures.Path("pack-wrapped.json.gz"))),
            ("c.json.gz", Encoding.UTF8.GetBytes("bozuk")),
        ];
        var library = new GamePackLibrary(Bundled, user);
        Assert.Equal(["a", "Test Game"], library.Packs.Select(p => p.Title));
        Assert.Equal([2, 5], library.Packs.Select(p => p.Entries));
        // Aynı anahtarda sonraki paket kazanır.
        Assert.Equal("Yere yat!", library.Find("Get Down!"));
        Assert.Equal("Geri çekil!", library.Find("Get back!"));

        // Kullanıcının klasöründeki aynı kimlikli paket uygulamanınkinin yerine geçer ve sonra okunur.
        var key = PackKey.Key("Get Down!");
        File.WriteAllText(Path.Combine(user, "test.json"), $"{{\"format\":1,\"id\":\"test-game\",\"title\":\"Test Game 2\",\"entries\":{{\"{key}\":\"Yat yere!\"}}}}");
        library.Reload();
        Assert.Equal(["a", "Test Game 2"], library.Packs.Select(p => p.Title));
        Assert.Equal([true, false], library.Packs.Select(p => p.BuiltIn));
        Assert.Equal("Yat yere!", library.Find("Get Down!"));
        Assert.Null(library.Find("Who is that?"));
    }

    [Fact]
    public void MissingDirectoriesGiveAnEmptyLibrary()
    {
        var library = new GamePackLibrary(null, Path.Combine(Path.GetTempPath(), "yok-" + Guid.NewGuid()));
        Assert.Empty(library.Packs);
        Assert.Null(library.Find("Get Down!"));
    }

    /// <summary>Yalnız tek bir gömülü paket: paketler birleşince ortak satırlarda ("Get down!") sonraki paket kazanır.</summary>
    internal static IEnumerable<(string Name, byte[] Data)> EmbeddedOnly(string file) =>
        GamePackLibrary.EmbeddedPacks().Where(pack => pack.Name == file);

    /// <summary>Uygulamaya gömülü paketler (Mafia, GTA V, RDR2) birlikte yüklenir ve hızlı aranır.</summary>
    [Fact]
    public void EmbeddedPacksLoad()
    {
        var before = GC.GetTotalMemory(true);
        var watch = Stopwatch.StartNew();
        var all = new GamePackLibrary(GamePackLibrary.EmbeddedPacks, null);
        var ids = all.Packs.Select(pack => pack.Id).ToList();
        watch.Stop();
        var memory = GC.GetTotalMemory(true) - before;
        Console.WriteLine($"paket yükleme: {watch.ElapsedMilliseconds} ms, bellek: {memory / 1024} KB, {all.Packs.Sum(p => p.Entries)} satır");
        Assert.Equal(["assassins-creed-shadows", "call-of-duty-modern-warfare-2019", "death-stranding-2", "elden-ring", "gta-v", "mafia-the-old-country", "red-dead-redemption-2"], ids);
        Assert.All(all.Packs, pack => Assert.True(pack.BuiltIn));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10));
        GC.KeepAlive(all);

        var library = new GamePackLibrary(() => EmbeddedOnly("mafia-the-old-country.json.gz"), null);
        var mafia = library.Packs.Single(pack => pack.Id == "mafia-the-old-country");
        Assert.Equal("Mafia: The Old Country", mafia.Title);
        Assert.True(mafia.Entries > 18000);
        Assert.True(mafia.BuiltIn);
        Assert.Equal("Şimdi ayvayı yedin, evlat!", library.Find("You fucked up now, boy!"));
        Assert.Equal("Annesi vefat etti.", library.Find("It’s his mother, she passed."));
        Assert.Equal("Yere yat!", library.Find("Get Down!"));
        GC.KeepAlive(library);
    }

    /// <summary>Her gömülü paket kendi başına açılır, en az beklenen satırı taşır ve bilinen satırlar (anahtarlar canon.py
    /// ile hesaplandı) boş olmayan Türkçeye çıkar. Mac'teki testEachBundledPackHasItsLines ile aynı.</summary>
    [Theory]
    [InlineData("mafia-the-old-country.json.gz", "mafia-the-old-country", "Mafia: The Old Country", 18000,
        new[] { "e7f18c8f6d1083ab", "15014c246455f36c" })]
    // "Are you listening to me?", "Cool, I'll see you later.", "Take out the Lost."
    [InlineData("gta-v.json.gz", "gta-v", "Grand Theft Auto V", 150_000,
        new[] { "e43b873bf7992f8f", "cc57fc6e0542ca05", "aaa1a152be96d47f" })]
    // "Can't see where I'm going.", "I'm not afraid to fight you.", "Burn the tobacco fields"
    [InlineData("red-dead-redemption-2.json.gz", "red-dead-redemption-2", "Red Dead Redemption 2", 150_000,
        new[] { "7fab2b68b3726a28", "3484a8ef3d8c7fc7", "bc0c9435160e8723" })]
    // "The Tarnished will soon return.", "Let it be Margit the Fell!", "Roundtable Hold"
    [InlineData("elden-ring.json.gz", "elden-ring", "Elden Ring + Shadow of the Erdtree", 37000,
        new[] { "fd7b2bef9d7e5fe1", "d9e5d9f200bbd946", "d5017888c04251a9" })]
    public void EachEmbeddedPackHasItsLines(string file, string id, string title, int minimum, string[] keys)
    {
        var (name, data) = EmbeddedOnly(file).Single();
        var pack = GamePack.Decode(data, name[..^".json.gz".Length]);
        Assert.Equal(id, pack.Id);
        Assert.Equal(title, pack.Title);
        Assert.True(pack.Entries.Count > minimum, $"{id}: {pack.Entries.Count}");
        foreach (var key in keys)
        {
            var turkish = pack.Entries.GetValueOrDefault(PackKey.Number(key)!.Value, "");
            Assert.False(string.IsNullOrEmpty(turkish), $"{id} {key}");
            Assert.DoesNotContain("~", turkish);
        }
    }

    /// <summary>Biçim 2: Mafia paketinde parçalar ve imzalar da var; hiç tam eşleşme olmadan bulanık arama yapılmaz.</summary>
    [Fact]
    public void VersionTwoPackHasSegmentsAndSignatures()
    {
        var (name, data) = EmbeddedOnly("mafia-the-old-country.json.gz").Single();
        var pack = GamePack.Decode(data, name[..^".json.gz".Length]);
        Assert.True(pack.Segments.Count > 10000, $"{pack.Segments.Count}");
        Assert.True(pack.Fuzzy?.Count > 20000, $"{pack.Fuzzy?.Count}");
        var library = new GamePackLibrary(() => EmbeddedOnly("mafia-the-old-country.json.gz"), null);
        const string garbled = "All this will bébehind u soon: Uötil'then don't let any of these båétards getpyou, alrightiz:t";
        Assert.Null(library.SearchScope);
        Assert.Null(library.Nearest(garbled));
        Assert.Equal("Che buono.", library.Find("Che buono."));
        Assert.NotNull(library.Find("then clear the way for someone who does."));
        Assert.NotNull(library.Find("You fucked up now, boy!"));
        Assert.Equal("mafia-the-old-country", library.SearchScope);
        Assert.Equal(library.Find("All this will be behind us soon. Until then don’t let any of these bastards get to you, alright?"), library.Nearest(garbled));
    }

    /// <summary>Assassin's Creed Shadows, Death Stranding 2, Modern Warfare (2019) ve Elden Ring paketleri de uygulamaya gömülüdür.</summary>
    [Theory]
    [InlineData("assassins-creed-shadows", "Assassin's Creed Shadows", 39000)]
    [InlineData("death-stranding-2", "Death Stranding 2: On the Beach", 23000)]
    [InlineData("call-of-duty-modern-warfare-2019", "Call of Duty: Modern Warfare (2019)", 50000)]
    [InlineData("elden-ring", "Elden Ring + Shadow of the Erdtree", 37000)]
    public void MoreEmbeddedPacksLoad(string id, string title, int minimum)
    {
        var library = new GamePackLibrary(GamePackLibrary.EmbeddedPacks, null);
        var pack = library.Packs.Single(p => p.Id == id);
        Assert.Equal(title, pack.Title);
        Assert.True(pack.Entries > minimum, $"{id}: {pack.Entries}");
        Assert.True(pack.BuiltIn);
    }

    [Fact]
    public void MoreEmbeddedPacksTranslate()
    {
        var library = new GamePackLibrary(GamePackLibrary.EmbeddedPacks, null);
        Assert.Equal("Yagoro? Burada ne yapıyorsun?", library.Find("Yagoro? What are you doing here?"));
        // Sahne notu ("[laughs]") ekranda kalsa da kalmasa da aynı satır bulunur.
        const string gnats = "Her yerdeler, biliyorsun, sinekler gibi! Ne arıyorsan bulacaksın. Naoe'me her zaman güvenebilirim.";
        Assert.Equal(gnats, library.Find("They are everywhere, you know, like gnats! Whatever it is, you will find it. I can always count on my Naoe."));
        Assert.Equal(gnats, library.Find("They are everywhere, you know, like gnats! [laughs] Whatever it is, you will find it. I can always count on my Naoe."));
        Assert.Equal("Terminal Fort Knot tehlikede. Bir boşluk patlaması hepsini öldürür!", library.Find("Terminal Fort Knot is in danger. A voidout would kill them all!"));
        Assert.Equal("Konumuma hava ikmali talep ediyorum!", library.Find("Requesting air drop on my position!"));
        Assert.Equal("Lekeli yakında geri dönecek.", library.Find("The Tarnished will soon return."));
        Assert.Equal("Margit, Uğursuz Alâmet", library.Find("Margit, the Fell Omen"));
    }
}
