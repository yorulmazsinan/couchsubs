// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.Json;

namespace CouchSubs.Core;

/// <summary>
/// Paketteki satırın bulanık imzası: OCR'ın bozduğu satırı (harf hatası, birleşmiş sözcük) bulmak için.
/// canon metnin boşlukları atılır, OCR'ın karıştırdığı harfler birleştirilir (l/1/ı/j → i, 0 → o, 5 → s), kalan dizinin
/// her farklı üçlüsü FNV-1a 64 ile özetlenip m bitten birine düşer (Bloom kümesi; m uzunlukla büyür: 64/128/256).
/// Her bit onlarca farklı üçlünün ortak izidir ve sıra tutulmaz: İngilizce metin geri çıkarılamaz.
/// Mac'teki CouchSubsCore/PackFuzzy.swift ve paket betiği (augment.py, common.py) ile birebir aynı; ortak deneme verisi
/// core/Tests/CouchSubsCoreTests/Fixtures/fuzzy-vectors.json.
/// </summary>
public static class PackFuzzy
{
    /// <summary>Bundan kısa satırda bulanık arama yok.</summary>
    public const int MinLength = 16;
    /// <summary>
    /// GTA paketinde bulanık aramanın en kısa satırı: 8-15 harfli satırlarda da OCR hataları ("I'II take it." → "I'll take
    /// it.") bulunsun diye. Paket betiği GTA paketine bu boydan imza yazar (common.py SHORT_MIN_LEN); öteki oyunlar
    /// <see cref="MinLength"/>. Öteki oyunlarda da işe yarar; yalnız GTA'da denendi.
    /// </summary>
    public const int ShortMinLength = 8;
    internal const int MaxBits = 256;
    internal const int BitsPerGram = 3;
    internal const double Margin = 5;
    /// <summary>
    /// Tek yönlü kapsama (yarım ya da fazlalıklı okuma): iki taraf da en az <c>MinLength</c> harf; kısa tarafın en az
    /// <c>Inner</c>'ı uzun tarafta; uzun tarafın en az <c>Partial</c>'ı (satır yarım okunmuş) ya da <c>Extra</c>'sı (okumada
    /// fazlalık var: köşe yazısı, çöp) kısa tarafta; benzerlik <c>Inner - Penalty</c> sayılır. Fazlalık az olmalı: iki ayrı
    /// altyazının birleştiği okuma tek bir altyazıya çıkmasın.
    /// </summary>
    internal static readonly (int MinLength, double Inner, double Partial, double Extra, double Penalty) Containment = (22, 90, 25, 55, 10);
    /// <summary>
    /// Fazlalıklı okumada yan cümle denetimi (<see cref="ClauseHashes"/>): okuma birden çok cümle ya da yan cümleyse en az
    /// <c>Letters</c> harfli her birinin üçlülerinin en az <c>Covered</c>'ı kısa adayda olmalı. İki altyazı yan yana
    /// okununca ("Hey, look. … But listen, I got some other work.") ikinci cümle adayda yoktur: yalnız birinin Türkçesi
    /// gösterilmez, satır cümle cümle aranır ya da motora gider.
    /// </summary>
    internal static readonly (int Letters, double Covered) SentenceCheck = (6, 30);
    /// <summary>OCR izi olmayan satır neredeyse aynı olmalı: (uzunluk sınırı, en düşük benzerlik).</summary>
    private static readonly (int Limit, double Value)[] CleanMinimum = [(24, 90), (256, 80)];
    /// <summary>OCR izi olan satır: (uzunluk sınırı, en düşük benzerlik).</summary>
    private static readonly (int Limit, double Value)[] DamagedMinimum = [(24, 70), (40, 60), (256, 55)];

    private static readonly Dictionary<int, int> Fold = new()
    {
        ['l'] = 'i', ['1'] = 'i', ['ı'] = 'i', ['j'] = 'i', ['0'] = 'o', ['5'] = 's', ['æ'] = 'a', ['ø'] = 'o', ['œ'] = 'o', ['ß'] = 's',
    };

    /// <summary>Yazı tanımanın sık karıştırdığı harf dizileri (canon metinde, küçük harf): okunan → asıl olabilecek.</summary>
    internal static readonly (string Read, string Real)[] Confusions =
    [
        ("rn", "m"), ("m", "rn"), ("cl", "d"), ("d", "cl"), ("vv", "w"), ("ri", "n"), ("n", "ri"), ("li", "h"),
        ("l", "i"), ("i", "l"), ("1", "l"), ("1", "i"), ("0", "o"), ("5", "s"), ("j", "i"), ("c", "e"), ("e", "c"),
        ("a", "o"), ("o", "a"), ("h", "b"), ("b", "h"), ("f", "t"), ("t", "f"), ("u", "v"), ("v", "u"), ("y", "v"),
        ("v", "y"), ("q", "g"), ("g", "q"),
    ];
    /// <summary>Tek düzeltmeyle denenecek en kısa ve en uzun canon satır (harf sayısı); daha uzun satırda bulanık imza yeter.</summary>
    internal static readonly (int Minimum, int Maximum) VariantLength = (6, 48);

    /// <summary>
    /// Satırın tek bir OCR düzeltmesiyle olabileceği canon hâller: karıştırılan harf dizisi değişir, bir harf düşer,
    /// sözcük ikiye bölünür (OCR boşluğu ya da kesme işaretini yuttu: "cant" → "can t") ya da iki sözcük birleşir.
    /// Pakette tam anahtarla aranırlar; bulanık imzanın yetmediği kısa satırlar içindir. Mac'teki
    /// <c>PackFuzzy.variants</c> ile aynı küme.
    /// </summary>
    internal static List<string> Variants(string text)
    {
        var canon = PackKey.Canon(text);
        // at[i]: i. harfin metindeki yeri (UTF-16), at[count] = metnin boyu.
        var at = new List<int>();
        for (var position = 0; position < canon.Length; position += char.IsSurrogatePair(canon, position) ? 2 : 1) at.Add(position);
        var count = at.Count;
        at.Add(canon.Length);
        if (count < VariantLength.Minimum || count > VariantLength.Maximum) return [];
        var output = new HashSet<string>(StringComparer.Ordinal);
        void Add(string value)
        {
            if (value.Length > 0 && !value.StartsWith(' ') && !value.EndsWith(' ') && !value.Contains("  ", StringComparison.Ordinal))
                output.Add(value);
        }
        // Harf aralıkları ([0, cut) + orta + [resume, count)) birleştirilir.
        string Join(int cut, string middle, int resume) =>
            string.Concat(canon.AsSpan(0, at[cut]), middle, canon.AsSpan(at[resume]));
        for (var index = 0; index < count; index++)
        {
            foreach (var (read, real) in Confusions)
            {
                // Karışan diziler ASCII: harf sayısı UTF-16 boyuna eşit.
                if (index + read.Length > count || at[index + read.Length] - at[index] != read.Length
                    || string.CompareOrdinal(canon, at[index], read, 0, read.Length) != 0) continue;
                Add(Join(index, real, index + read.Length));
            }
            Add(Join(index, "", index + 1));
            if (canon[at[index]] != ' ' && index > 0 && canon[at[index - 1]] != ' ') Add(Join(index, " ", index));
        }
        output.Remove(canon);
        var sorted = output.ToList();
        sorted.Sort(StringComparer.Ordinal);
        return sorted;
    }

    /// <summary>canon metin, boşluksuz ve OCR'ın karıştırdığı harfler birleşmiş.</summary>
    internal static List<Rune> Folded(string text)
    {
        var output = new List<Rune>();
        foreach (var rune in PackKey.Canon(text).EnumerateRunes())
        {
            if (rune.Value == ' ') continue;
            output.Add(Fold.TryGetValue(rune.Value, out var folded) ? new Rune(folded) : rune);
        }
        return output;
    }

    /// <summary>Uzunluğa göre Bloom boyu (bit).</summary>
    internal static int Bits(int length)
    {
        var bits = 64;
        while (bits < MaxBits && length * BitsPerGram > bits) bits *= 2;
        return bits;
    }

    internal static List<ulong> TrigramHashes(List<Rune> runes)
    {
        var hashes = new HashSet<ulong>();
        Span<byte> buffer = stackalloc byte[4];
        for (var index = 0; index + 3 <= runes.Count; index++)
        {
            var hash = 0xcbf29ce484222325UL;
            for (var offset = 0; offset < 3; offset++)
            {
                var written = runes[index + offset].EncodeToUtf8(buffer);
                for (var b = 0; b < written; b++)
                {
                    hash ^= buffer[b];
                    hash *= 0x100000001b3UL;
                }
            }
            hashes.Add(hash);
        }
        return [.. hashes];
    }

    internal static ulong[] Bloom(List<ulong> hashes, int bits)
    {
        var words = new ulong[bits / 64];
        foreach (var hash in hashes)
        {
            var bit = (int)(hash & (ulong)(bits - 1));
            words[bit >> 6] |= 1UL << (bit & 63);
        }
        return words;
    }

    /// <summary>
    /// İki yönlü, rastlantıdan arındırılmış kapsama (0-100): min(sorgunun üçlülerinin adayda olanı, adayınkinin sorguda
    /// olanı). <paramref name="entry"/>: dizindeki kelimeler, <paramref name="offset"/>'ten başlayarak bits / 64 tane.
    /// </summary>
    internal static double Similarity(ulong[] query, ulong[] entry, int offset, int bits)
    {
        int both = 0, inQuery = 0, inEntry = 0;
        for (var index = 0; index < bits / 64; index++)
        {
            ulong q = query[index], e = entry[offset + index];
            both += BitOperations.PopCount(q & e);
            inQuery += BitOperations.PopCount(q);
            inEntry += BitOperations.PopCount(e);
        }
        return Score(both, inQuery, inEntry, bits);
    }

    /// <summary>Benzerlik, bit sayılarından (ortak, sorgudaki, adaydaki).</summary>
    internal static double Score(int both, int inQuery, int inEntry, int bits)
    {
        var (query, entry) = Coverage(both, inQuery, inEntry, bits);
        return Math.Min(query, entry);
    }

    /// <summary>Rastlantıdan arındırılmış tek yönlü kapsamalar (0-100): sorgunun adayda olanı, adayın sorguda olanı.</summary>
    internal static (double Query, double Entry) Coverage(int both, int inQuery, int inEntry, int bits)
    {
        if (inQuery == 0 || inEntry == 0) return (0, 0);
        double fillQuery = (double)inQuery / bits, fillEntry = (double)inEntry / bits;
        if (fillQuery >= 1 || fillEntry >= 1) return (0, 0);
        var queryCovered = ((double)both / inQuery - fillEntry) / (1 - fillEntry);
        var entryCovered = ((double)both / inEntry - fillQuery) / (1 - fillQuery);
        return (100.0 * queryCovered, 100.0 * entryCovered);
    }

    private const string ClauseEnders = ".!?…,;:";
    /// <summary>Ardından küçük harf gelse de bölen işaretler (yan cümle).</summary>
    private const string ClauseMarks = ",;:";
    private const string ClauseClosers = "\"'”’)]";

    /// <summary>
    /// Satırın cümle ve yan cümleleri: . ! ? … (yinelenebilir, isteğe bağlı kapanış tırnağı ya da ayraç) ardından boşluk
    /// ve büyük harf, ya da , ; : … ve üç nokta ardından boşluk. Tek noktadan sonra küçük harfle süren yer ("seriously.
    /// nis seriously") bölünmez: OCR çöpüdür, ayrı cümle değil. Mac'teki <c>PackFuzzy.clauses</c> ile aynı.
    /// </summary>
    internal static List<string> Clauses(string text)
    {
        var runes = text.EnumerateRunes().ToList();
        var output = new List<string>();
        int begin = 0, index = 0;
        bool Is(string set, Rune rune) => rune.IsBmp && set.Contains((char)rune.Value);
        void Cut(int end)
        {
            var builder = new StringBuilder();
            for (var position = begin; position < end; position++) builder.Append(runes[position].ToString());
            var clause = builder.ToString().Trim();
            if (clause.Length > 0) output.Add(clause);
        }
        while (index < runes.Count)
        {
            if (!Is(ClauseEnders, runes[index])) { index++; continue; }
            var end = index;
            while (end < runes.Count && Is(ClauseEnders, runes[end])) end++;
            while (end < runes.Count && Is(ClauseClosers, runes[end])) end++;
            var next = end;
            while (next < runes.Count && Rune.IsWhiteSpace(runes[next])) next++;
            // Üç nokta da küçük harfle süren yan cümleyi ayırır ("to escape... if we're able").
            var dots = 0;
            var soft = false;
            for (var position = index; position < end; position++)
            {
                if (Is(ClauseMarks, runes[position]) || runes[position].Value == '…') soft = true;
                if (runes[position].Value == '.') dots++;
            }
            if (next > end && next < runes.Count && (soft || dots > 1 || Rune.IsUpper(runes[next])))
            {
                Cut(end);
                begin = next;
            }
            index = Math.Max(next, index + 1);
        }
        Cut(runes.Count);
        // SentenceCheck.Letters harften kısa yan cümle ("Bye," "Dad.") sonrakine (sonuncuysa öncekine) eklenir.
        var merged = new List<string>();
        var pending = "";
        foreach (var clause in output)
        {
            var joined = pending.Length == 0 ? clause : pending + " " + clause;
            if (Folded(joined).Count < SentenceCheck.Letters) pending = joined;
            else { merged.Add(joined); pending = ""; }
        }
        if (pending.Length > 0)
        {
            if (merged.Count > 0) merged[^1] = merged[^1] + " " + pending;
            else merged.Add(pending);
        }
        return merged;
    }

    /// <summary>
    /// Fazlalıklı okumanın denetlenecek yan cümleleri: her biri için üçlü kümesi seçenekleri (biri kısa adayda yeterince
    /// varsa yan cümle tamam). Köşe yazısına benzeyen yan cümle atlanır; ilk yan cümlenin başındaki ve sonuncunun
    /// sonundaki en çok üç büyük harfli sözcük ("Mirror Park Errr.", "… in a state Vinewood Hills") köşe yazısı olabilir,
    /// onlarsız hâli de seçenektir. Seçeneklerden biri <c>SentenceCheck.Letters</c> harften kısaysa yan cümle
    /// denetlenmez. Okuma tek yan cümleyse boş.
    /// </summary>
    internal static List<List<List<ulong>>> ClauseHashes(string text)
    {
        var parts = Clauses(text);
        var output = new List<List<List<ulong>>>();
        if (parts.Count < 2) return output;
        for (var position = 0; position < parts.Count; position++)
        {
            var part = parts[position];
            if (OverlayLike(part)) continue;
            var words = part.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            var options = new List<string> { part };
            for (var count = 1; count <= 3 && count < words.Length; count++)
            {
                if (position == 0 && words.Take(count).All(Capitalized)) options.Add(string.Join(' ', words.Skip(count)));
                if (position == parts.Count - 1 && words.Skip(words.Length - count).All(Capitalized))
                    options.Add(string.Join(' ', words.Take(words.Length - count)));
            }
            var folds = options.Select(Folded).ToList();
            if (folds.Any(fold => fold.Count < SentenceCheck.Letters)) continue;
            output.Add([.. folds.Select(TrigramHashes)]);
        }
        return output;
    }

    /// <summary>Büyük harfle başlayan, yalnız harf ve rakamlı sözcük (köşe yazısı sözcüğü: "Vinewood", "LOSNN").</summary>
    internal static bool Capitalized(string word)
    {
        var runes = word.EnumerateRunes().ToList();
        return runes.Count > 0 && Rune.IsUpper(runes[0]) && runes.All(rune => IsLetter(rune) || IsDigit(rune));
    }

    /// <summary>
    /// Köşe yazısına benzeyen parça: "•" içerir ya da en çok dört sözcük, noktalama yok ve her sözcük büyük harfle
    /// başlar ("San Andreas", "First Person • zoom"). Fazlalık sayılır, cümle değil.
    /// </summary>
    internal static bool OverlayLike(string text)
    {
        if (text.Contains('•')) return true;
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return words.Length > 0 && words.Length <= 4 && words.All(Capitalized);
    }

    /// <summary>
    /// Her yan cümlenin seçeneklerinden birinin üçlülerinin en az <c>SentenceCheck.Covered</c>'ı (rastlantıdan
    /// arındırılmış) adayın Bloom'unda mı. <paramref name="entry"/>: dizindeki kelimeler, <paramref name="offset"/>'ten
    /// başlayarak bits / 64 tane; <paramref name="inEntry"/>: adaydaki 1 bit sayısı.
    /// </summary>
    internal static bool CoversClauses(List<List<List<ulong>>> clauses, ulong[] entry, int offset, int bits, int inEntry)
    {
        var fill = (double)inEntry / bits;
        if (fill >= 1) return false;
        bool Covered(List<ulong> hashes)
        {
            var words = Bloom(hashes, bits);
            int both = 0, inClause = 0;
            for (var index = 0; index < words.Length; index++)
            {
                both += BitOperations.PopCount(words[index] & entry[offset + index]);
                inClause += BitOperations.PopCount(words[index]);
            }
            if (inClause == 0) return true;
            return 100.0 * ((double)both / inClause - fill) / (1 - fill) >= SentenceCheck.Covered;
        }
        return clauses.All(options => options.Any(Covered));
    }

    /// <summary>(uzunluk, Bloom baytları) — paket betiğinin yazdığıyla aynı; satır çok kısaysa null.</summary>
    internal static (int Length, byte[] Bytes)? Signature(string text, int minLength = MinLength)
    {
        var runes = Folded(text);
        if (runes.Count < minLength) return null;
        var length = Math.Min(runes.Count, 255);
        var words = Bloom(TrigramHashes(runes), Bits(length));
        var bytes = new byte[words.Length * 8];
        for (var index = 0; index < words.Length; index++) BitConverter.TryWriteBytes(bytes.AsSpan(index * 8), words[index]);
        if (!BitConverter.IsLittleEndian) throw new PlatformNotSupportedException();
        return (length, bytes);
    }

    /// <summary>Kabul için en düşük benzerlik (0-100), OCR izine ve uzunluğa göre.</summary>
    internal static double Required(int length, bool damaged)
    {
        var table = damaged ? DamagedMinimum : CleanMinimum;
        foreach (var (limit, value) in table)
            if (length < limit) return value;
        return table[^1].Value;
    }

    private const string Edge = ".,!?;:'\"()[]-…“”’‘";
    private const string Typographic = "’‘“”—–…";

    internal static bool IsLetter(Rune rune) => Rune.IsLetter(rune);

    internal static bool IsDigit(Rune rune) => rune.IsBmp && CharUnicodeInfo.GetDigitValue((char)rune.Value) >= 0;

    /// <summary>
    /// OCR izi: İngilizce satırda ASCII dışı harf ya da işaret, sözcük içinde harf olmayan işaret ya da rakam, tek harfli
    /// garip sözcük, çok uzun (birleşmiş) sözcük. İzi olmayan satırın neredeyse aynı olması gerekir: temiz ama pakette
    /// olmayan satır büyük olasılıkla başka bir satırdır.
    /// </summary>
    internal static bool Damaged(string text)
    {
        foreach (var rune in text.EnumerateRunes())
            if (rune.Value > 127 && !Typographic.Contains(rune.ToString(), StringComparison.Ordinal)) return true;
        foreach (var word in text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var core = word.EnumerateRunes().ToList();
            while (core.Count > 0 && Edge.Contains(core[0].ToString(), StringComparison.Ordinal)) core.RemoveAt(0);
            while (core.Count > 0 && Edge.Contains(core[^1].ToString(), StringComparison.Ordinal)) core.RemoveAt(core.Count - 1);
            if (core.Count == 0) continue;
            for (var index = 1; index < core.Count - 1; index++)
                if (IsLetter(core[index - 1]) && IsLetter(core[index + 1]) && !IsLetter(core[index])
                    && core[index].Value is not ('\'' or '’' or '-'))
                    return true;
            for (var index = 1; index < core.Count; index++)
            {
                Rune previous = core[index - 1], current = core[index];
                if ((IsLetter(previous) && IsDigit(current)) || (IsDigit(previous) && IsLetter(current))) return true;
            }
            if (core.Count == 1 && IsLetter(core[0]) && core[0].Value is not ('a' or 'A' or 'I' or 'o' or 'O')) return true;
            if (core.Count > 14) return true;
        }
        return false;
    }
}

/// <summary>Bir paketin bulanık dizini: imzalı satırlar uzunluğa göre sıralı, Bloom kelimeleri ardışık.</summary>
public sealed class PackFuzzyIndex
{
    private readonly byte[] lengths;
    private readonly ulong[] keys;
    private readonly int[] offsets;
    private readonly ulong[] words;
    /// <summary>Her satırın Bloom'undaki 1 bit sayısı.</summary>
    private readonly int[] ones;
    /// <summary>start[n]: uzunluğu n olan ilk satırın sırası.</summary>
    private readonly int[] start = new int[257];

    public int Count => keys.Length;

    private PackFuzzyIndex(byte[] lengths, ulong[] keys, int[] offsets, ulong[] words)
    {
        this.lengths = lengths;
        this.keys = keys;
        this.offsets = offsets;
        this.words = words;
        ones = new int[keys.Length];
        for (var index = 0; index < keys.Length; index++)
            for (var word = 0; word < PackFuzzy.Bits(lengths[index]) / 64; word++) ones[index] += BitOperations.PopCount(words[offsets[index] + word]);
        var position = 0;
        for (var length = 0; length <= 256; length++)
        {
            while (position < lengths.Length && lengths[position] < length) position++;
            start[length] = position;
        }
    }

    /// <summary>
    /// Paketteki "fuzzy" nesnesi. <paramref name="order"/>: paketteki bütün anahtarlar (entries + segments) sayı sırasıyla.
    /// Biçim tutmazsa null (paket yine de tam eşleşmeyle çalışır).
    /// </summary>
    internal static PackFuzzyIndex? Decode(JsonElement json, IReadOnlyList<ulong> order)
    {
        try
        {
            if (json.ValueKind != JsonValueKind.Object || !json.TryGetProperty("version", out var version) || version.GetInt32() != 1
                || !json.TryGetProperty("count", out var count) || count.GetInt32() != order.Count) return null;
            var mask = Convert.FromBase64String(json.GetProperty("mask").GetString() ?? "");
            var lengthBytes = Convert.FromBase64String(json.GetProperty("lengths").GetString() ?? "");
            var blooms = Convert.FromBase64String(json.GetProperty("blooms").GetString() ?? "");
            if (mask.Length != (order.Count + 7) / 8) return null;
            var items = new List<(byte Length, ulong Key, int Offset)>(lengthBytes.Length);
            var byteOffset = 0;
            for (var index = 0; index < order.Count; index++)
            {
                if (((mask[index >> 3] >> (index & 7)) & 1) == 0) continue;
                if (items.Count >= lengthBytes.Length) return null;
                var length = lengthBytes[items.Count];
                items.Add((length, order[index], byteOffset));
                byteOffset += PackFuzzy.Bits(length) / 8;
            }
            if (items.Count != lengthBytes.Length || byteOffset != blooms.Length) return null;
            items.Sort((a, b) => a.Length != b.Length ? a.Length.CompareTo(b.Length) : a.Key.CompareTo(b.Key));
            var words = new ulong[blooms.Length / 8];
            var offsets = new int[items.Count];
            var written = 0;
            for (var index = 0; index < items.Count; index++)
            {
                offsets[index] = written;
                var count64 = PackFuzzy.Bits(items[index].Length) / 64;
                for (var word = 0; word < count64; word++)
                    words[written++] = BitConverter.ToUInt64(blooms, items[index].Offset + word * 8);
            }
            return new PackFuzzyIndex([.. items.Select(i => i.Length)], [.. items.Select(i => i.Key)], offsets, words);
        }
        catch (Exception error) when (error is FormatException or InvalidOperationException or KeyNotFoundException)
        {
            return null;
        }
    }

    /// <summary>
    /// Eşik, uzunluk ve ikinci aday şartlarını sağlayan en benzer satırın anahtarı; yoksa null.
    /// <paramref name="translation"/>: anahtarın Türkçesi (aynı Türkçeli iki aday birbirinin rakibi sayılmaz).
    /// Önce boyu yakın adaylar (benzerlik iki yönlü kapsamanın küçüğü). Hiçbiri eşiği geçmezse boyu çok farklı adaylarda
    /// tek yönlü kapsamaya bakılır (<see cref="PackFuzzy.Containment"/>): yarım okunan satır (iki satırlık altyazının bir
    /// satırı) uzun adayın içinde, köşe yazısı ya da çöp eklenmiş okuma kısa adayın dışında kalır.
    /// </summary>
    /// <param name="minLength">Bundan kısa satır aranmaz (GTA paketinde <see cref="PackFuzzy.ShortMinLength"/>).</param>
    public ulong? Nearest(string text, Func<ulong, string?> translation, int minLength = PackFuzzy.MinLength)
    {
        var runes = PackFuzzy.Folded(text);
        if (runes.Count < minLength || keys.Length == 0) return null;
        var length = Math.Min(runes.Count, 255);
        var need = PackFuzzy.Required(length, PackFuzzy.Damaged(text));
        var hashes = PackFuzzy.TrigramHashes(runes);
        // Sorgunun üç boydaki Bloom'u ve bit sayısı (64, 128, 256 bit).
        ulong[][] queries = [PackFuzzy.Bloom(hashes, 64), PackFuzzy.Bloom(hashes, 128), PackFuzzy.Bloom(hashes, 256)];
        var queryOnes = queries.Select(query => query.Sum(word => BitOperations.PopCount(word))).ToArray();
        var floor = need - PackFuzzy.Margin;

        var contain = PackFuzzy.Containment;
        // Okumanın yan cümle üçlüleri (PackFuzzy.ClauseHashes); ilk fazlalıklı adayda hesaplanır.
        List<List<List<ulong>>>? clauses = null;
        // Boyu lower..upper olan adaylar. İki yönlü (wide false): benzerlik kapsamaların küçüğü. Tek yönlü: kısa taraf en
        // az Inner kapsanmalı, uzun tarafın en az Partial/Extra'sı kısa tarafta; benzerlik Inner - Penalty.
        List<(double Score, ulong Key)> Scan(int lower, int upper, bool wide)
        {
            var found = new List<(double Score, ulong Key)>();
            if (lower > upper) return found;
            for (var index = start[lower]; index < start[upper + 1]; index++)
            {
                int entryLength = lengths[index];
                var tier = BitOperations.Log2((uint)PackFuzzy.Bits(entryLength)) - 6;
                var query = queries[tier];
                var both = 0;
                for (var word = 0; word < query.Length; word++) both += BitOperations.PopCount(query[word] & words[offsets[index] + word]);
                int inQuery = queryOnes[tier], inEntry = ones[index], bits = 64 << tier;
                if (!wide)
                {
                    var score = PackFuzzy.Score(both, inQuery, inEntry, bits);
                    if (score >= floor) found.Add((score, keys[index]));
                    continue;
                }
                // Kısa tarafın bitlerinin en az %90'ı ortak olmalı (hızlı eleme).
                if (entryLength < contain.MinLength || entryLength == length
                    || both * 10 < 9 * (entryLength > length ? inQuery : inEntry)) continue;
                var cover = PackFuzzy.Coverage(both, inQuery, inEntry, bits);
                var (inner, outer, least) = entryLength > length
                    ? (cover.Query, cover.Entry, contain.Partial) : (cover.Entry, cover.Query, contain.Extra);
                if (inner < contain.Inner || outer < least || inner - contain.Penalty < floor) continue;
                // Fazlalıklı okumada her yan cümle adayda olmalı: ikinci bir altyazının cümlesi fazlalık sayılmaz.
                if (entryLength < length)
                {
                    clauses ??= PackFuzzy.ClauseHashes(text);
                    if (clauses.Count > 0 && !PackFuzzy.CoversClauses(clauses, words, offsets[index], bits, inEntry)) continue;
                }
                found.Add((inner - contain.Penalty, keys[index]));
            }
            return found;
        }

        // En iyi aday; eşiği geçmiyorsa null, Türkçesi farklı rakibi yakınsa Ambiguous.
        (ulong? Key, bool Ambiguous) Pick(List<(double Score, ulong Key)> found)
        {
            if (found.Count == 0) return (null, false);
            var best = found[0];
            foreach (var candidate in found)
                if (candidate.Score > best.Score || (candidate.Score == best.Score && candidate.Key > best.Key)) best = candidate;
            if (best.Score < need) return (null, false);
            var turkish = translation(best.Key);
            foreach (var other in found)
                if (other.Key != best.Key && other.Score > best.Score - PackFuzzy.Margin && translation(other.Key) != turkish) return (null, true);
            return (best.Key, false);
        }

        // Aday uzunluğu en çok ±%25 farklı: |aday - satır| * 4 <= satır.
        int nearLower = length - length / 4, nearUpper = Math.Min(255, length + length / 4);
        var close = Scan(nearLower, nearUpper, wide: false);
        // Tek yönlü adaylara yalnız iki yönlü hiçbir aday eşiği geçmediyse bakılır: satırın 11/20'si ile 5/2'si arası
        // (fazlalıklı okumada aday satırın en az %55'i kadar olur).
        var first = Pick(close);
        if (first.Key is not null || first.Ambiguous || length < contain.MinLength) return first.Key;
        var contained = Scan(Math.Max(contain.MinLength, length * 11 / 20), Math.Min(255, length * 5 / 2), wide: true);
        if (contained.Count == 0) return null;
        close.AddRange(contained);
        return Pick(close).Key;
    }
}
