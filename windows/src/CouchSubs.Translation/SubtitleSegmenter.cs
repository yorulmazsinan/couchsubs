// SPDX-License-Identifier: AGPL-3.0-only

using System.Text;
using System.Text.RegularExpressions;

namespace CouchSubs.Translation;

/// <summary>
/// Altyazıyı modele cümle cümle verir. Denemede bütün metin tek seferde çevrilince model kısa cümleleri
/// ("Boy!", "What is that?") ve ikinci satırı sık sık düşürdü; cümle başına çeviri hiçbirini kaybetmedi.
/// Konuşmacı etiketi ("ATREUS:", "Kratos:") ve diyalog tirelerine dokunulmaz, çünkü model onları siliyor ya da
/// çeviriyor. Mac'teki CouchSubsCore/SubtitleSegmenter.swift ile aynı kurallar.
/// </summary>
internal static partial class SubtitleSegmenter
{
    /// <summary>Çevrilecek bir parça ya da olduğu gibi kalacak ayraç/etiket.</summary>
    internal readonly record struct Piece(string Text, bool Translate);

    // Etiket: satır ya da cümle başında, en çok üç sözcüklü ad ve iki nokta. Ya tümü büyük harf ("ATREUS:", "OLD MAN:")
    // ya da her sözcüğü büyük harfle başlayan ("Kratos:", "Mimir Head:").
    [GeneratedRegex(@"^(?<label>(?<name>\p{Lu}[\p{Lu}\d'’.\-]+(?:[ ]\p{Lu}[\p{Lu}\d'’.\-]*){0,2}|\p{Lu}\p{Ll}[\p{L}'’.\-]*(?:[ ]\p{Lu}[\p{L}'’.\-]*){0,2}):)(?:\s+|$)")]
    private static partial Regex SpeakerLabelPattern();

    /// <summary>Büyük harfle başlayıp iki noktayla biten ama ad olmayan oyun başlıkları; bunlar çevrilir.</summary>
    private static readonly HashSet<string> NotNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "note", "warning", "tip", "hint", "objective", "objectives", "quest", "goal", "new", "reward", "rewards",
        "location", "chapter", "mission", "task", "tutorial", "update", "info", "status", "level", "controls",
        "press", "hold", "tap", "remember", "example", "question", "answer", "result", "results", "time",
        "listen", "look", "wait", "okay", "ok", "well", "so", "yes", "no", "now", "then", "and", "but",
    };

    /// <summary>Satır başındaki konuşmacı etiketi; tek sözcüklü başlıklar ("Note:", "Objective:") ad sayılmaz.</summary>
    private static Match? SpeakerLabel(string text)
    {
        var match = SpeakerLabelPattern().Match(text);
        if (!match.Success) return null;
        var name = match.Groups["name"].Value;
        return !name.Contains(' ') && NotNames.Contains(name) ? null : match;
    }

    /// <summary>Etiket parçasındaki ad ("ATREUS: " → "ATREUS"); etiket değilse null.</summary>
    public static string? LabelName(Piece piece) =>
        !piece.Translate && piece.Text.EndsWith(": ", StringComparison.Ordinal) ? piece.Text[..^2] : null;

    [GeneratedRegex(@"^(?<dash>[-–—]+)\s*")]
    private static partial Regex DialogueDash();

    // Cümle sonu: . ! ? … (yinelenebilir), ardından isteğe bağlı kapanış tırnağı/parantez ve boşluk.
    [GeneratedRegex(@"(?<=[.!?…]+[""'”’)\]]*)\s+")]
    private static partial Regex SentenceGap();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();

    /// <summary>Noktadan sonra cümle bitmeyen kısaltmalar ("Mr. Smith").</summary>
    private static readonly HashSet<string> Abbreviations = new(StringComparer.OrdinalIgnoreCase)
    {
        "mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "mt", "vs", "etc", "e.g", "i.e", "lt", "sgt", "capt", "gen", "col",
    };

    public static List<Piece> Split(string text)
    {
        var pieces = new List<Piece>();
        var lines = text.Replace("\r\n", "\n").Split('\n');
        var block = new StringBuilder();
        var pendingSeparator = "";

        void FlushBlock()
        {
            if (block.Length == 0) return;
            if (pendingSeparator.Length > 0) pieces.Add(new Piece(pendingSeparator, false));
            AddBlock(pieces, block.ToString());
            block.Clear();
            pendingSeparator = "\n";
        }

        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            // Etiketli ya da tireli satır yeni bir konuşmadır; diğer satırlar sarmadır, birleştirilir. Altyazı seçicinin
            // konuşan adı saydığı satır (SpeakerPrefix: "JASON : …", "Lucia：…") da yeni konuşmadır; aynı anda konuşan iki
            // kişinin satırı tek satıra birleşiyordu (beta.103 bildirimi; Mac, iPhone ve Android aynı).
            if (SpeakerLabel(line) is not null || CouchSubs.Core.SpeakerPrefix.Parse(line) is not null
                || DialogueDash().IsMatch(line)) FlushBlock();
            if (block.Length > 0) block.Append(' ');
            block.Append(line);
        }
        FlushBlock();
        return pieces;
    }

    private static void AddBlock(List<Piece> pieces, string block)
    {
        block = Whitespace().Replace(block, " ");
        var dash = DialogueDash().Match(block);
        if (dash.Success)
        {
            pieces.Add(new Piece(dash.Groups["dash"].Value + " ", false));
            block = block[dash.Length..];
        }

        var first = true;
        foreach (var sentence in SplitSentences(block))
        {
            if (!first) pieces.Add(new Piece(" ", false));
            first = false;
            var body = sentence;
            if (SpeakerLabel(body) is { } label)
            {
                pieces.Add(new Piece(label.Groups["label"].Value + " ", false));
                body = body[label.Length..];
            }
            if (body.Length > 0) pieces.Add(new Piece(body, HasLetter(body)));
        }
    }

    private static IEnumerable<string> SplitSentences(string block)
    {
        var start = 0;
        foreach (Match gap in SentenceGap().Matches(block))
        {
            var candidate = block[start..gap.Index];
            var next = gap.Index + gap.Length < block.Length ? block[gap.Index + gap.Length] : '\0';
            // "wait... what" gibi küçük harfle süren yer ve kısaltmalar cümle sonu değildir.
            if (char.IsLower(next) || EndsWithAbbreviation(candidate)) continue;
            yield return candidate;
            start = gap.Index + gap.Length;
        }
        if (start < block.Length) yield return block[start..];
    }

    private static bool EndsWithAbbreviation(string sentence)
    {
        if (!sentence.EndsWith('.')) return false;
        var lastSpace = sentence.LastIndexOf(' ');
        var word = sentence[(lastSpace + 1)..^1];
        // Tek harf ad baş harfidir ("J. R. R.").
        return (word.Length == 1 && char.IsUpper(word[0])) || Abbreviations.Contains(word);
    }

    /// <summary>
    /// Tümü büyük harfli cümleyi ("THE GATE WILL NOT HOLD.") cümle düzenine çevirir; model büyük harfli
    /// sözcükleri ad sanıp çevirmeden bırakıyordu ("GATE daha fazla dayanamaz"). Bilinen adlar (konuşmacı
    /// etiketlerinden öğrenilen) büyük harfle başlar. Tek sözcüğe dokunulmaz.
    /// </summary>
    public static string NormalizeCase(string sentence, IReadOnlySet<string>? names = null)
    {
        var letters = 0;
        foreach (var c in sentence)
        {
            if (char.IsLower(c)) return sentence;
            if (char.IsLetter(c)) letters++;
        }
        if (letters < 2 || !sentence.Trim().Contains(' ')) return sentence;

        var output = new StringBuilder(sentence.Length);
        var word = new StringBuilder();
        var startOfSentence = true;

        void FlushWord()
        {
            if (word.Length == 0) return;
            var lower = word.ToString().ToLowerInvariant();
            // İngilizcede "I" her zaman büyük.
            var capital = startOfSentence || lower == "i" || (names?.Contains(lower) ?? false);
            output.Append(capital ? char.ToUpperInvariant(lower[0]) + lower[1..] : lower);
            startOfSentence = false;
            word.Clear();
        }

        foreach (var c in sentence)
        {
            if (char.IsLetter(c) || c is '\'' or '’')
            {
                word.Append(c);
                continue;
            }
            FlushWord();
            if (c is '.' or '!' or '?' or '…') startOfSentence = true;
            output.Append(c);
        }
        FlushWord();
        return output.ToString();
    }

    /// <summary>Harfsiz parça ("...", "?!", "3") modele gitmez; olduğu gibi kalır.</summary>
    private static bool HasLetter(string text)
    {
        foreach (var c in text)
            if (char.IsLetter(c)) return true;
        return false;
    }
}
