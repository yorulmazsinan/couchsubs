// SPDX-License-Identifier: AGPL-3.0-only

using System.Text;
using System.Text.Json;

namespace CouchSubs.Core.Tests;

/// <summary>Mac'teki PackFuzzyTests ve paket betiği (common.py) ile aynı imza: Fixtures/fuzzy-vectors.json.</summary>
public class PackFuzzyTests
{
    /// <summary>
    /// İkinci tur düzeltmeler (yutulan harf, benzeyen harf, iki karışıklık) Mac ve Android'le aynı küme; arama anahtarları
    /// metinlerinkiyle aynı.
    /// </summary>
    [Fact]
    public void EditVectors()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("fuzzy-vectors.json")));
        var thresholds = document.RootElement.GetProperty("thresholds");
        Assert.Equal([PackFuzzy.EditLength.Minimum, PackFuzzy.EditLength.Maximum, PackFuzzy.EditLength.Pairs],
            thresholds.GetProperty("editLength").EnumerateArray().Select(item => item.GetInt32()).ToArray());
        Assert.Equal(PackFuzzy.MinimumEvidence, thresholds.GetProperty("minimumEvidence").GetDouble());
        Assert.Equal(PackFuzzy.CleanMissing, thresholds.GetProperty("cleanMissing").GetInt32());
        var edits = document.RootElement.GetProperty("edits").EnumerateArray().ToList();
        Assert.True(edits.Count >= 5);
        static List<string> Strings(JsonElement array) => array.EnumerateArray().Select(item => item.GetString()!).ToList();
        foreach (var vector in edits)
        {
            var input = vector.GetProperty("input").GetString()!;
            var found = PackFuzzy.Edits(input);
            Assert.Equal(vector.GetProperty("count").GetInt32(), found.Count);
            Assert.Equal(Strings(vector.GetProperty("first")), found.Take(5).ToList());
            Assert.Equal(Strings(vector.GetProperty("last")), found.TakeLast(5).ToList());
            foreach (var expected in Strings(vector.GetProperty("contains"))) Assert.Contains(expected, found);
            Assert.Equal(found.Select(edit => PackKey.CanonNumber(Encoding.UTF8.GetBytes(edit))).ToHashSet(), PackFuzzy.EditKeys(input));
            Assert.Empty(found.Intersect(PackFuzzy.Variants(input)));
        }
        foreach (var vector in document.RootElement.GetProperty("evidence").EnumerateArray())
        {
            var z = PackFuzzy.Evidence(vector.GetProperty("both").GetInt32(), vector.GetProperty("inQuery").GetInt32(),
                vector.GetProperty("inEntry").GetInt32(), vector.GetProperty("bits").GetInt32());
            Assert.Equal(vector.GetProperty("query").GetDouble(), z.Query, 9);
            Assert.Equal(vector.GetProperty("entry").GetDouble(), z.Entry, 9);
        }
    }

    [Fact]
    public void SignatureVectors()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("fuzzy-vectors.json")));
        var signatures = document.RootElement.GetProperty("signatures").EnumerateArray().ToList();
        Assert.True(signatures.Count > 10);
        foreach (var vector in signatures)
        {
            var input = vector.GetProperty("input").GetString()!;
            var folded = new StringBuilder();
            foreach (var rune in PackFuzzy.Folded(input)) folded.Append(rune.ToString());
            Assert.Equal(vector.GetProperty("folded").GetString(), folded.ToString());
            Assert.Equal(vector.GetProperty("damaged").GetBoolean(), PackFuzzy.Damaged(input));
            var signature = PackFuzzy.Signature(input);
            if (vector.GetProperty("length").ValueKind == JsonValueKind.Null)
            {
                Assert.Null(signature);
                continue;
            }
            Assert.Equal(vector.GetProperty("length").GetInt32(), signature!.Value.Length);
            Assert.Equal(vector.GetProperty("bits").GetInt32(), PackFuzzy.Bits(signature.Value.Length));
            Assert.Equal(vector.GetProperty("bloom").GetString(), Convert.ToHexStringLower(signature.Value.Bytes));
        }
        foreach (var pair in document.RootElement.GetProperty("similarities").EnumerateArray())
        {
            var bits = pair.GetProperty("bits").GetInt32();
            var query = PackFuzzy.Bloom(PackFuzzy.TrigramHashes(PackFuzzy.Folded(pair.GetProperty("query").GetString()!)), bits);
            var entry = PackFuzzy.Bloom(PackFuzzy.TrigramHashes(PackFuzzy.Folded(pair.GetProperty("entry").GetString()!)), bits);
            Assert.Equal(pair.GetProperty("similarity").GetDouble(), PackFuzzy.Similarity(query, entry, 0, bits), 9);
        }
    }
}
