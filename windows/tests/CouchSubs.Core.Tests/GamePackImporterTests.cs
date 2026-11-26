// SPDX-License-Identifier: AGPL-3.0-only

using System.Text;
using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

public class GamePackImporterTests
{
    [Fact]
    public void FlatJsonHashesEnglishAndCountsInvalidRecords()
    {
        var preview = Parse(
            "\uFEFF" + """{"You fucked up now, boy!":"  Bu kez işi batırdın!  ","...":"x","":"x","Blank":"  ","Number":7}""",
            "flat.JSON");

        Assert.Null(preview.SuggestedTitle);
        Assert.Equal(new KeyValuePair<string, string>("e7f18c8f6d1083ab", "Bu kez işi batırdın!"), Assert.Single(preview.Entries));
        Assert.Equal(4, preview.InvalidCount);
        Assert.Equal(0, preview.DuplicateCount);
        Assert.Equal(0, preview.ConflictCount);
    }

    [Theory]
    [InlineData("""{"game":"Old","game":"  Test Game  ","title":"Alternate","subtitles":{"Get Down!":"Yere yat!"},"other":"ignored"}""", "Test Game")]
    [InlineData("""{"game":"  ","title":"Alternate","subtitles":{"Get Down!":"Yere yat!"}}""", "Alternate")]
    public void SubtitleEnvelopeUsesLastMetadataAndOnlyTranslationMembers(string json, string title)
    {
        var preview = Parse(json, "envelope.json");

        Assert.Equal(title, preview.SuggestedTitle);
        Assert.Equal(new KeyValuePair<string, string>("ebf811f2fee9a8cc", "Yere yat!"), Assert.Single(preview.Entries));
        Assert.Equal(0, preview.InvalidCount);
    }

    [Fact]
    public void HashedEnvelopeValidatesAndLowercasesKeysWithoutRehashing()
    {
        var preview = Parse(
            """{"format":2,"format":1.0,"id":"ignored","title":" Existing Game ","game":"Alternate","entries":{"0123456789ABCDEF":"Türkçe","0123456789abcdef":"Türkçe","+123456789abcdef":"bad","g123456789abcdef":"bad","fedcba9876543210":null,"9999999999999999":"  ","123":"bad"}}""",
            "existing.json");

        Assert.Equal("Existing Game", preview.SuggestedTitle);
        Assert.Equal(new KeyValuePair<string, string>("0123456789abcdef", "Türkçe"), Assert.Single(preview.Entries));
        Assert.Equal(5, preview.InvalidCount);
        Assert.Equal(1, preview.DuplicateCount);
        Assert.Equal(0, preview.ConflictCount);
    }

    [Theory]
    [InlineData("""{"Get Down!":"Yere yat!","Get Down!":"Çök!","Get Down!":"Çök!","Who is that?":"Kim o?","Who is that?":"Kim o?"}""", "ce61a5b5526ea81a")]
    [InlineData("""{"subtitles":{"Get Down!":"Yere yat!","Get Down!":"Çök!","Get Down!":"Çök!","Who is that?":"Kim o?","Who is that?":"Kim o?"}}""", "ce61a5b5526ea81a")]
    [InlineData("""{"format":1,"entries":{"0123456789abcdef":"Yere yat!","0123456789abcdef":"Çök!","0123456789abcdef":"Çök!","ffffffffffffffff":"Kim o?","ffffffffffffffff":"Kim o?"}}""", "ffffffffffffffff")]
    public void EveryRepeatedJsonMemberReachesThePairAccumulator(string json, string survivingKey)
    {
        var preview = Parse(json, "repeat.json");

        Assert.Equal(new KeyValuePair<string, string>(survivingKey, "Kim o?"), Assert.Single(preview.Entries));
        Assert.Equal(0, preview.InvalidCount);
        Assert.Equal(2, preview.DuplicateCount);
        Assert.Equal(1, preview.ConflictCount);
    }

    [Theory]
    [InlineData("""{"format":1,"title":"Existing Game","entries":[]}""")]
    [InlineData("""{"format":1,"title":"Existing Game","entries":"text"}""")]
    [InlineData("""{"format":1,"title":"Existing Game","entries":[true,"Get Down!","Yere yat!"]}""")]
    [InlineData("""{"format":1,"title":"Existing Game","subtitles":{"Get Down!":"Yere yat!"}}""")]
    [InlineData("""{"format":2,"title":"Existing Game","entries":null}""")]
    [InlineData("""{"format":3,"entries":{"0123456789abcdef":"Türkçe"}}""")]
    [InlineData("""{"format":true,"entries":{"0123456789abcdef":"Türkçe"}}""")]
    [InlineData("""{"oops",1}""")]
    [InlineData("""{"Get Down!":"\uD800"}""")]
    [InlineData("[1,2]")]
    public void MalformedJsonAndUnsupportedEnvelopesAreRejected(string json)
    {
        Assert.Throws<InvalidDataException>(() => Parse(json, "broken.json"));
    }

    [Fact]
    public void UnsupportedFileExtensionsAreRejected()
    {
        Assert.Throws<InvalidDataException>(() => Parse("pairs", "file.csv"));
    }

    [Fact]
    public void InvalidUtf8IsRejected()
    {
        Assert.Throws<InvalidDataException>(() => GamePackImporter.Parse([0xff], "file.txt"));
    }

    [Fact]
    public void TextRecognizesOneTabBeforeEqualsAndRejectsMultipleTabs()
    {
        var preview = Parse(
            "\uFEFF  # ignored\r\n\r\nGet Down! = Yere yat! = şimdi\r\nWho is that?\tKim o? = bilmiyorum\r\n"
            + "You fucked up now, boy!\tBu kez işi batırdın!\r\nExtra = invalid\ttwo\ttabs\r\n"
            + "broken\r\nEmpty = \r\n\tMissing\r\n",
            "pairs.txt");

        Assert.Equal(3, preview.Entries.Count);
        Assert.Equal("Yere yat! = şimdi", preview.Entries["ebf811f2fee9a8cc"]);
        Assert.Equal("Kim o? = bilmiyorum", preview.Entries["ce61a5b5526ea81a"]);
        Assert.Equal("Bu kez işi batırdın!", preview.Entries["e7f18c8f6d1083ab"]);
        Assert.Equal(4, preview.InvalidCount);
    }

    [Fact]
    public void ConflictingCanonicalKeyStaysOmittedAndRepeatedTargetsStillCount()
    {
        var preview = Parse(
            "Get Down! = Yere yat!\nget down = Yere yat!\n<b>GET DOWN</b> = Çök!\n"
            + "Get down? = Yere yat!\nGet down = Eğil!\nWho is that? = Kim o?",
            "pairs.txt");

        Assert.Equal(new KeyValuePair<string, string>("ce61a5b5526ea81a", "Kim o?"), Assert.Single(preview.Entries));
        Assert.Equal(2, preview.DuplicateCount);
        Assert.Equal(1, preview.ConflictCount);
        Assert.Equal(0, preview.InvalidCount);
    }

    [Fact]
    public void BilingualSrtRejectsMalformedCuesAndRetainsTheirNeighbors()
    {
        string[] cues =
        [
            "1\n00:00:01,250 --> 00:00:03,999\n Get Down! \n Yere yat! ",
            "2\n00:00:04,000 --> 00:00:05,000\nOne line",
            "3\n00:00:06,000 --> 00:00:07,000\nThree\nText\nLines",
            "４\n00:00:08,000 --> 00:00:09,000\nBad\nIndex",
            "5\n00:60:00,000 --> 00:60:01,000\nBad\nClock",
            "6\n00:00:11.000 --> 00:00:11.999\nBad\nSeparator",
            "7\n00:00:13,000 --> 00:00:12,000\nReversed\nClock",
            "8\n00:00:14,000 --> 00:00:14,000\nEqual\nClock",
            "9\n00:00:15,000 --> 00:00:16,000\nWho is that?\nKim o?",
        ];
        var preview = Parse("\uFEFF" + string.Join("\n \t\n", cues).Replace("\n", "\r\n"), "pairs.SRT");

        Assert.Equal(2, preview.Entries.Count);
        Assert.Equal("Yere yat!", preview.Entries["ebf811f2fee9a8cc"]);
        Assert.Equal("Kim o?", preview.Entries["ce61a5b5526ea81a"]);
        Assert.Equal(7, preview.InvalidCount);
    }

    [Fact]
    public void IdsUseStablePathSafeAscii()
    {
        Assert.Equal("community-my-game-a-a", GamePackImporter.MakeId(" ../My GAME\\a:a... "));
        Assert.Equal("community-game", GamePackImporter.MakeId("../遊戲"));
        Assert.Equal("community-" + new string('a', 80), GamePackImporter.MakeId(new string('a', 300)));
        Assert.Equal("community-" + new string('a', 79), GamePackImporter.MakeId(new string('a', 79) + " b"));
    }

    [Fact]
    public void InstallPublishesFormatOneAndRequiresExplicitReplacement()
    {
        using var temp = new TempDirectory();
        var directory = Path.Combine(temp.Path, "packs");
        var library = new GamePackLibrary(null, directory);
        Assert.Empty(library.Packs);
        var initial = Parse("Get Down! = Yere yat!", "pairs.txt");
        var destination = GamePackImporter.Install(initial, " Test Game ", directory, replacing: false);
        Assert.Equal(Path.Combine(directory, "community-test-game.json"), destination);
        var original = File.ReadAllBytes(destination);
        using var json = JsonDocument.Parse(original);
        Assert.Equal(4, json.RootElement.EnumerateObject().Count());
        Assert.Equal(1, json.RootElement.GetProperty("format").GetInt32());
        Assert.Equal("community-test-game", json.RootElement.GetProperty("id").GetString());
        Assert.Equal("Test Game", json.RootElement.GetProperty("title").GetString());
        var entry = Assert.Single(json.RootElement.GetProperty("entries").EnumerateObject());
        Assert.Equal("ebf811f2fee9a8cc", entry.Name);
        Assert.Equal("Yere yat!", entry.Value.GetString());

        library.Reload();
        var installed = Assert.Single(library.Packs);
        Assert.Equal("Test Game", installed.Title);
        Assert.Equal(1, installed.Entries);
        Assert.Equal("Yere yat!", library.Find("Get Down!"));

        var updated = Parse("Get Down! = Çök!", "pairs.txt");
        Assert.Throws<IOException>(() => GamePackImporter.Install(updated, "Test Game", directory, replacing: false));
        Assert.Equal(original, File.ReadAllBytes(destination));
        Assert.Equal([destination], Directory.GetFileSystemEntries(directory));

        Assert.Equal(destination, GamePackImporter.Install(updated, "Test Game", directory, replacing: true));
        library.Reload();
        Assert.Equal("Çök!", library.Find("Get Down!"));
        Assert.Equal([destination], Directory.GetFileSystemEntries(directory));
    }

    [Fact]
    public void BlankTitleAndEmptyPreviewCannotWriteFiles()
    {
        using var temp = new TempDirectory();
        var initial = Parse("Get Down! = Yere yat!", "pairs.txt");
        Assert.Throws<ArgumentException>(() => GamePackImporter.Install(initial, " \n ", temp.Path, replacing: false));
        Assert.Empty(Directory.GetFileSystemEntries(temp.Path));

        var destination = GamePackImporter.Install(initial, "Test Game", temp.Path, replacing: false);
        var original = File.ReadAllBytes(destination);
        var empty = Parse("# no pairs\ninvalid", "pairs.txt");
        Assert.Throws<InvalidDataException>(() => GamePackImporter.Install(empty, "Test Game", temp.Path, replacing: true));
        Assert.Equal(original, File.ReadAllBytes(destination));
    }

    [Fact]
    public void SourceDestinationCheckReportsTheMatchWithoutChangingFiles()
    {
        using var temp = new TempDirectory();
        var destination = Path.Combine(temp.Path, "community-test-game.json");
        var original = Encoding.UTF8.GetBytes("""{"Get Down!":"Yere yat!"}""");
        File.WriteAllBytes(destination, original);

        Assert.True(GamePackImporter.IsSourceDestination(" Test Game ", temp.Path, destination));
        var missingDirectory = Path.Combine(temp.Path, "missing");
        Assert.False(GamePackImporter.IsSourceDestination("Test Game", missingDirectory, destination));
        Assert.Equal(original, File.ReadAllBytes(destination));
        Assert.Equal([destination], Directory.GetFileSystemEntries(temp.Path));
    }

    [Fact]
    public void InstallRefusesItsOwnSourcePathBeforeWriting()
    {
        using var temp = new TempDirectory();
        var destination = Path.Combine(temp.Path, "community-test-game.json");
        var original = Encoding.UTF8.GetBytes("""{"Get Down!":"Yere yat!"}""");
        File.WriteAllBytes(destination, original);
        var preview = GamePackImporter.Parse(original, destination);
        var source = Path.Combine(temp.Path, ".", Path.GetFileName(destination));

        Assert.Throws<InvalidOperationException>(() =>
            GamePackImporter.Install(preview, "Test Game", temp.Path, replacing: true, sourcePath: source));

        Assert.Equal(original, File.ReadAllBytes(destination));
        Assert.Equal([destination], Directory.GetFileSystemEntries(temp.Path));
    }

    [Fact]
    public void InstallRefusesSourceThroughADirectorySymlink()
    {
        // Creating symlinks on Windows depends on privileges and developer mode.
        if (OperatingSystem.IsWindows()) return;

        using var temp = new TempDirectory();
        var directory = Directory.CreateDirectory(Path.Combine(temp.Path, "packs")).FullName;
        var destination = Path.Combine(directory, "community-test-game.json");
        var original = Encoding.UTF8.GetBytes("""{"Get Down!":"Yere yat!"}""");
        File.WriteAllBytes(destination, original);
        var alias = Path.Combine(temp.Path, "alias");
        Directory.CreateSymbolicLink(alias, directory);
        var source = Path.Combine(alias, Path.GetFileName(destination));
        var preview = GamePackImporter.Parse(File.ReadAllBytes(source), source);

        Assert.True(GamePackImporter.IsSourceDestination("Test Game", directory, source));
        Assert.Throws<InvalidOperationException>(() =>
            GamePackImporter.Install(preview, "Test Game", directory, replacing: true, sourcePath: source));

        Assert.Equal(original, File.ReadAllBytes(destination));
        Assert.Equal([destination], Directory.GetFileSystemEntries(directory));
    }

    [Fact]
    public void PathFallbackIdentifiesSourceThroughAnAncestorLink()
    {
        // On Windows, creating symlinks can require additional privileges.
        if (OperatingSystem.IsWindows()) return;

        using var temp = new TempDirectory();
        var physicalParent = Directory.CreateDirectory(Path.Combine(temp.Path, "physical")).FullName;
        var directory = Directory.CreateDirectory(Path.Combine(physicalParent, "packs")).FullName;
        var destination = Path.Combine(directory, "community-test-game.json");
        File.WriteAllText(destination, """{"Get Down!":"Yere yat!"}""");
        var alias = Path.Combine(temp.Path, "alias");
        Directory.CreateSymbolicLink(alias, physicalParent);
        var source = Path.Combine(alias, "packs", Path.GetFileName(destination));
        var otherFile = Path.Combine(alias, "packs", "other.json");
        File.WriteAllBytes(otherFile, File.ReadAllBytes(destination));

        Assert.True(GamePackImporter.SameResolvedPath(source, destination));
        Assert.False(GamePackImporter.SameResolvedPath(otherFile, destination));
    }

    private static GamePackImportPreview Parse(string source, string fileName) =>
        GamePackImporter.Parse(Encoding.UTF8.GetBytes(source), fileName);

    private sealed class TempDirectory : IDisposable
    {
        public string Path { get; } = PackFixtures.TemporaryDirectory();

        public void Dispose() => Directory.Delete(Path, recursive: true);
    }
}
