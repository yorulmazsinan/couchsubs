// SPDX-License-Identifier: AGPL-3.0-only

using System.IO.Compression;
using System.Text;
using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Translation.Tests;

/// <summary>
/// #1355: içe aktarmada kabul edilen ve nedenine göre atlanan kayıtlar, biçim 2 paketler ve oyun seçiliyken içe aktarılan
/// paket. Mac GamePackImporterTests ve Android ile aynı ortak deneme dosyası (Fixtures/pack-import-report.json).
/// </summary>
public class PackImportReportTests
{
    private static JsonDocument Report() => JsonDocument.Parse(File.ReadAllText(Fixture("pack-import-report.json")));

    /// <summary>Her dosya türünde kabul edilen satırlar, atlananlar ve günlük satırı Mac ve Android ile aynı.</summary>
    [Fact]
    public void SharedImportReportCases()
    {
        using var report = Report();
        foreach (var item in report.RootElement.GetProperty("cases").EnumerateArray())
        {
            var file = item.GetProperty("file").GetString()!;
            var preview = GamePackImporter.Parse(Encoding.UTF8.GetBytes(item.GetProperty("text").GetString()!), file);
            Assert.Equal(item.GetProperty("accepted").GetInt32(), preview.AcceptedCount);
            Assert.Equal(item.GetProperty("segments").GetInt32(), preview.Segments.Count);
            var skipped = item.GetProperty("skipped").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetInt32());
            Assert.Equal(skipped, preview.Skipped.ToDictionary(p => p.Key.Name(), p => p.Value));
            Assert.Equal(item.TryGetProperty("fuzzyDropped", out var dropped) && dropped.GetBoolean(), preview.FuzzyDropped);
            Assert.Equal(item.TryGetProperty("title", out var title) ? title.GetString() : null, preview.SuggestedTitle);
            Assert.Equal(item.GetProperty("log").GetString(), preview.LogLine(file));

            var directory = TemporaryDirectory();
            try
            {
                GamePackImporter.Install(preview, "Harbor", directory, replacing: false);
                var library = new GamePackLibrary(null, directory);
                foreach (var lookup in item.GetProperty("lookups").EnumerateObject())
                {
                    var expected = lookup.Value.ValueKind == JsonValueKind.Null ? null : lookup.Value.GetString();
                    Assert.True(expected == PackLookup.Match(library, lookup.Name)?.Text, $"{file}: {lookup.Name}");
                }
            }
            finally { Directory.Delete(directory, recursive: true); }
        }
    }

    /// <summary>
    /// Paket betiğiyle yapılan biçim 2 paket (OCR verisiyle) içe aktarılabilir; oyunun adından farklı bir başlıkla kurulsa
    /// da oyun elle seçiliyken satırlar (OCR hatalı olanlar da) bu paketten bulunur. Başka oyunun paketi seçilen oyunda
    /// yine aranmaz (#218).
    /// </summary>
    [Fact]
    public void FormatTwoCommunityPackServesTheChosenGameDespiteADifferentTitle()
    {
        using var report = Report();
        var community = report.RootElement.GetProperty("community");
        string Text(string name) => community.GetProperty(name).GetString()!;

        byte[] data;
        using (var gzip = new GZipStream(File.OpenRead(Fixture("pack-fuzzy.json.gz")), CompressionMode.Decompress))
        using (var memory = new MemoryStream())
        {
            gzip.CopyTo(memory);
            data = memory.ToArray();
        }
        var preview = GamePackImporter.Parse(data, "harbor-fuzzy.json");
        Assert.NotNull(preview.Fuzzy);
        Assert.False(preview.FuzzyDropped);
        Assert.Equal(0, preview.SkippedCount);
        Assert.True(preview.AcceptedCount > 10);

        var other = $$$"""{"format":1,"id":"elsewhere","title":"{{{Text("otherPackTitle")}}}","entries":{"{{{PackKey.Key(Text("otherLine"))}}}":"Fener söndü."}}""";
        var directory = TemporaryDirectory();
        try
        {
            var library = new GamePackLibrary(() => [("elsewhere.json", Encoding.UTF8.GetBytes(other))], directory);
            Assert.Equal(Text("missingLog"), library.LimitLog(Text("chosenGame")));

            GamePackImporter.Install(preview, Text("title"), directory, replacing: false);
            Assert.Equal(Text("installLog"), preview.InstallLog($" {Text("title")} "));
            library.Reload();
            library.LimitToGame(Text("chosenGame"));
            Assert.Equal(Text("log"), library.LimitLog(Text("chosenGame")));
            Assert.Null(PackLookup.Match(library, Text("otherLine")));

            using var cases = JsonDocument.Parse(File.ReadAllText(Fixture("pack-fuzzy-cases.json")));
            Assert.NotNull(PackLookup.Match(library, cases.RootElement.GetProperty("warmUp").GetString()!));
            foreach (var item in cases.RootElement.GetProperty("cases").EnumerateArray())
            {
                var screen = item.GetProperty("screen").GetString()!;
                var expected = item.GetProperty("turkish").ValueKind == JsonValueKind.Null ? null : item.GetProperty("turkish").GetString();
                Assert.True(expected == PackLookup.Match(library, screen)?.Text, $"{screen} => {PackLookup.Match(library, screen)?.Text} (beklenen {expected})");
            }
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static string TemporaryDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "pack-import-" + Guid.NewGuid());
        Directory.CreateDirectory(path);
        return path;
    }

    private static string Fixture(string name, [System.Runtime.CompilerServices.CallerFilePath] string source = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..", "core", "Tests", "CouchSubsCoreTests", "Fixtures", name));
}
