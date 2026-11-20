// SPDX-License-Identifier: AGPL-3.0-only

using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace CouchSubs.Core;

/// <summary>
/// Oyun ipuçlarının içindeki kumanda simgeleri ("Hold △ to sprint", "Use 🕹 to move the camera"). Yazı tanıma simgeyi
/// okuyamaz: harf sanır ("Hold A to sprint", "PressÄ to open", "Useo to move") ya da yerinde boşluk bırakır. Çevirmen
/// o harfi atınca TV'deki çeviri simgeyi de örtüyor, Türkçede yalnız "basılı tut" kalıyordu; neye basılacağı
/// görünmüyordu. Burada simge satırın içinde bulunur (<see cref="Mark"/>), kareden kesilir (<see cref="Crop"/>) ve
/// çeviride yeri korunarak (<see cref="IconText"/>) TV'ye resim olarak gider.
/// </summary>
public static class ButtonIcons
{
    /// <summary>Okunan metinde simgenin yeri; satırın <see cref="TextLine.Icons"/> listesindeki sıradaki simgedir.</summary>
    public const char Marker = '￼';

    /// <summary>Simgeden önce gelen fiiller: "Press △", "Hold R2", "Use ◎".</summary>
    private static readonly HashSet<string> Verbs = new(StringComparer.OrdinalIgnoreCase)
    {
        "press", "hold", "tap", "push", "use", "mash", "release", "click", "hit", "pressing", "holding", "tapping", "using",
    };

    /// <summary>İki simgeyi bağlayanlar: "Press △ or ○", "Hold L1 + R1".</summary>
    private static readonly HashSet<string> Joiners = new(StringComparer.OrdinalIgnoreCase) { "and", "or", "+", "/", "then" };

    /// <summary>Düğme adları ve simgeleri; harf olarak okunsalar da simgedirler.</summary>
    private static readonly HashSet<string> Names = new(StringComparer.OrdinalIgnoreCase)
    {
        "R1", "R2", "R3", "L1", "L2", "L3", "RB", "LB", "RT", "LT", "LS", "RS", "ZL", "ZR",
        "✕", "×", "⨯", "✖", "○", "◯", "●", "□", "▢", "◻", "■", "△", "▲", "⨂",
    };

    /// <summary>Fiile yapışık okunan simgeden sonra gelemeyecek harfler: "Uses", "Used", "User", "Pushy", "Tape" sözcüktür.</summary>
    private const string Inflections = "sdeyr";

    private const string Brackets = "()[]{}<>「」\"'“”‘’";
    private const string Punctuation = ".,;:!?…";

    /// <summary>
    /// Satırdaki simgeleri <see cref="Marker"/> ile işaretler ve yerlerini <see cref="TextLine.Icons"/>'a yazar. Simge
    /// yalnız ipucu kalıbında aranır, konuşma bozulmasın: bir fiilin ("press", "hold", "use"...) ya da bir simgeden sonra
    /// gelen "and/or/+" bağlacının ardındaki (1) tek harf/simge ya da düğme adı ("A", "Ä", "©", "R2"), (2) fiile yapışık
    /// tek harf ("PressÄ", "Useo") ve (3) fiilden sonraki, birkaç harf genişliğindeki boşluk (simge hiç okunmamış).
    /// Simgeyi tanıyan okuyucunun yazdığı simge karakteri ("Hold △ to sprint", PaddleOCR) ya da düğme adı da simgedir;
    /// işaretlenen satır kumanda ipucu sayılıp atılmaz, simgesiyle çevrilir. Satır başı/sonundaki simge ("R2 Swing",
    /// "△ Pick up") işaretlenmez: bu kısa ipuçları bilerek hiç çevrilmez (ek alanda sürekli gelip gider), üstleri de
    /// örtülmez. Okuyucu sözcük yerlerini vermiyorsa yerler satırın içinde harf sayısına göre kestirilir; o zaman boşluk
    /// aranmaz. Simge yoksa satır olduğu gibi döner.
    /// </summary>
    public static TextLine Mark(TextLine line)
    {
        if (line.Box is not { } lineBox || line.Icons is { Count: > 0 }) return line;
        var measured = line.Words is { Count: > 0 };
        var words = measured ? line.Words! : Estimate(line.Text, lineBox);
        if (words.Count == 0) return line;
        var charWidth = AverageCharWidth(words);
        var tokens = new List<string>();
        var icons = new List<IconSlot>();
        var isIcon = new bool[words.Count];
        double top = lineBox.Top, bottom = lineBox.Bottom, pad = (bottom - top) * 0.3;
        // (0) Tuş kalıntısı kalıbı (ButtonPrompts.IsIconPrompt, GTA 6 havuzu): "Hold I LI to", "Press (9 0 to",
        // "Release 2 and R2 to". Bağlaçsız art arda kalıntılar tek simgenin parçalarıdır; bağlaç iki simgeyi ayırır.
        var span = ButtonPrompts.IconRemnantSpan([.. words.Select(word => word.Text)], line.Text);

        for (var i = 0; i < words.Count; i++)
        {
            var word = words[i];
            if (span is { } remnants && i > remnants.Verb && i < remnants.To)
            {
                var to = remnants.To;
                if (ButtonPrompts.IsConnector(word.Text.Trim(Brackets.ToCharArray())))
                {
                    tokens.Add(word.Text);
                    continue;
                }
                var last = i;
                while (last + 1 < to && !ButtonPrompts.IsConnector(words[last + 1].Text.Trim(Brackets.ToCharArray()))) last++;
                var left = Math.Min(word.Box.Left, (words[i - 1].Box.Right + word.Box.Left) / 2);
                var right = Math.Max(words[last].Box.Right, (words[last].Box.Right + words[last + 1].Box.Left) / 2);
                tokens.Add(Marker.ToString());
                icons.Add(new IconSlot(new TextBox(left, top - pad, right, bottom + pad),
                                       string.Join(' ', words.Skip(i).Take(last - i + 1).Select(w => w.Text))));
                for (var k = i; k <= last; k++) isIcon[k] = true;
                i = last;
                continue;
            }
            var previous = i > 0 ? Letters(words[i - 1].Text) : "";
            var afterVerb = i > 0 && Verbs.Contains(previous);
            var joiner = i > 0 && Joiners.Contains(words[i - 1].Text.Trim(Brackets.ToCharArray()));
            // "Press △ or ○", ya da fiil önceden geçmiş: "Use ◎ to move the camera and △ to interact".
            var afterJoinedIcon = joiner && ((i > 1 && isIcon[i - 2])
                                             || (i + 1 < words.Count && words[i + 1].Text.Equals("to", StringComparison.OrdinalIgnoreCase)));

            // (3) Fiil ile bu sözcük arasında okunmamış simge: boşluk birkaç harf genişliğinde.
            if (measured && afterVerb && !IsIconToken(word.Text) && word.Box.Left - words[i - 1].Box.Right >= charWidth * 2.5)
            {
                tokens.Add(Marker.ToString());
                // Sözcük kenarları yaklaşık olabilir (PaddleOCR harf ortalarından çıkarır): iki yana birer harf payı;
                // kutuya giren harf kırıntıları kırpılırken atılır.
                icons.Add(new IconSlot(new TextBox(words[i - 1].Box.Right - charWidth, top - pad, word.Box.Left + charWidth, bottom + pad), ""));
                tokens.Add(word.Text);
                continue;
            }
            // (1) Simgenin okunduğu harf ya da düğme adı.
            if ((afterVerb || afterJoinedIcon) && IsIconToken(word.Text))
            {
                isIcon[i] = true;
                // Komşu sözcükle arasındaki boşluğun ortasına kadar; kutular üst üste biniyorsa (gelişmiş yazı tanıma
                // kutuları geniş tutar) sözcüğün kendi kutusu küçülmez.
                var left = Math.Min(word.Box.Left, i > 0 ? (words[i - 1].Box.Right + word.Box.Left) / 2
                                                         : word.Box.Left - (word.Box.Right - word.Box.Left) / 2);
                var right = Math.Max(word.Box.Right, i + 1 < words.Count ? (word.Box.Right + words[i + 1].Box.Left) / 2
                                                                         : word.Box.Right + (word.Box.Right - word.Box.Left) / 2);
                var trail = TrailingPunctuation(word.Text);
                tokens.Add(Marker + trail);
                icons.Add(new IconSlot(new TextBox(left, top - pad, right, bottom + pad), word.Text[..^trail.Length]));
                continue;
            }
            // (2) Fiile yapışık simge: "PressÄ", "Useo".
            if (GluedVerb(word.Text) is { } verb)
            {
                isIcon[i] = true;
                // Simge harften geniştir; kesim fiilin son harfinden başlar, fazlası kırpılırken atılır.
                var split = Math.Min(word.Box.Right, word.Box.Left + ((verb.Length - 1) * charWidth));
                var right = i + 1 < words.Count ? (word.Box.Right + words[i + 1].Box.Left) / 2 : word.Box.Right;
                tokens.Add(verb);
                tokens.Add(Marker.ToString());
                icons.Add(new IconSlot(new TextBox(split, top - pad, right, bottom + pad), word.Text[verb.Length..]));
                continue;
            }
            tokens.Add(word.Text);
        }
        if (icons.Count == 0) return line;
        return line with { Text = string.Join(' ', tokens), Words = null, Icons = icons };
    }

    /// <summary>
    /// Gelişmiş yazı tanıma (PaddleOCR) ipucu satırını simgenin olduğu yerden böler: "Press" | "R2" | "to open the weapon
    /// wheel." ayrı satırlar olunca cümle ikiye bölünüp çevriliyordu. Aynı sırada yan yana duran (aralarında en çok
    /// <see cref="Reading.RowGap"/>) ve ipucu kalıbını sürdüren parçalar tek satır olur: soldaki parça fiille ya da
    /// fiilden sonraki simgeyle biter, ya da sağdaki parça "and/or"dan sonra gelen tek simgedir. Sözcük yerleri korunur.
    /// </summary>
    public static Reading JoinHints(Reading reading)
    {
        if (reading.Lines.Count < 2 || reading.Lines.Any(line => line.Box is null)) return reading;
        var pieces = reading.Lines.ToList();
        for (var joined = true; joined;)
        {
            joined = false;
            for (var a = 0; a < pieces.Count && !joined; a++)
                for (var b = 0; b < pieces.Count && !joined; b++)
                {
                    if (a == b || !Continues(pieces[a], pieces[b])) continue;
                    var (left, right) = (pieces[a], pieces[b]);
                    double? confidence = left.Confidence is { } x && right.Confidence is { } y ? Math.Min(x, y) : left.Confidence ?? right.Confidence;
                    pieces[a] = new TextLine(left.Text + " " + right.Text, left.Box!.Value.Union(right.Box!.Value), confidence,
                        [.. left.Words ?? Estimate(left.Text, left.Box!.Value), .. right.Words ?? Estimate(right.Text, right.Box!.Value)]);
                    pieces.RemoveAt(b);
                    joined = true;
                }
        }
        return pieces.Count == reading.Lines.Count ? reading : new Reading(pieces.OrderBy(line => line.Box!.Value.Top));
    }

    /// <summary><paramref name="right"/>, <paramref name="left"/>'in hemen sağında aynı sırada ve ipucu ondan sürüyor.</summary>
    private static bool Continues(TextLine left, TextLine right)
    {
        TextBox a = left.Box!.Value, b = right.Box!.Value;
        var overlap = Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top);
        var smaller = Math.Min(a.Bottom - a.Top, b.Bottom - b.Top);
        if (smaller <= 0 || overlap < smaller * 0.6 || b.Left <= a.Left || b.Left - a.Right > Reading.RowGap) return false;
        var first = left.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var second = right.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (first.Length == 0 || second.Length == 0) return false;
        if (Verbs.Contains(Letters(first[^1]))) return true;
        if (first.Length >= 2 && IsIconToken(first[^1]) && (Verbs.Contains(Letters(first[^2])) || Joiners.Contains(first[^2]))) return true;
        return second.Length == 1 && IsIconToken(second[0]) && Joiners.Contains(first[^1]);
    }

    /// <summary>Tek harf/simge (küçük "a" ve "I" dışında: sözcüktürler) ya da düğme adı; çevresindeki parantez ve noktalama sayılmaz.</summary>
    /// <summary>Sözcük bir kumanda tuşunun adı ya da simgesi mi ("R3", "(L1)", "△").</summary>
    public static bool IsButtonName(string text) => Names.Contains(text.Trim(Brackets.ToCharArray()));

    private static bool IsIconToken(string text)
    {
        var core = text.Trim(Brackets.ToCharArray()).TrimEnd(Punctuation.ToCharArray()).Trim(Brackets.ToCharArray());
        if (Names.Contains(core)) return true;
        if (core.Length != 1) return false;
        var c = core[0];
        if (char.IsDigit(c) || c is 'a' or 'I' or '-' or '–' or '—' or '&') return false;
        return char.IsUpper(c) || c is 'o' or 'x' || !char.IsLetter(c);
    }

    /// <summary>Fiile yapışmış tek harf ("PressÄ" → "Press"); değilse null.</summary>
    private static string? GluedVerb(string text)
    {
        if (text.Length < 4) return null;
        var verb = text[..^1];
        var last = text[^1];
        if (!Verbs.Contains(verb) || !verb.All(char.IsLetter)) return null;
        if (char.IsLower(last) && Inflections.Contains(last)) return null;
        return char.IsLetter(last) || !char.IsPunctuation(last) ? verb : null;
    }

    private static string TrailingPunctuation(string text)
    {
        var end = text.Length;
        while (end > 1 && Punctuation.Contains(text[end - 1])) end--;
        return text[end..];
    }

    private static string Letters(string text) => new([.. text.Where(char.IsLetter)]);

    /// <summary>Yeri bilinen sözcüklerin harf başına ortalama genişliği (alan genişliğine oranla).</summary>
    private static double AverageCharWidth(IReadOnlyList<TextWord> words)
    {
        var normal = words.Where(word => word.Text.Length >= 2 && !IsIconToken(word.Text)).ToList();
        if (normal.Count == 0) normal = [.. words];
        var chars = normal.Sum(word => word.Text.Length);
        return chars == 0 ? 0 : normal.Sum(word => word.Box.Right - word.Box.Left) / chars;
    }

    /// <summary>Sözcük yerleri bilinmiyorsa satırın kutusu harf sayısına göre paylaştırılır.</summary>
    private static IReadOnlyList<TextWord> Estimate(string text, TextBox box)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return [];
        var width = (box.Right - box.Left) / trimmed.Length;
        var result = new List<TextWord>();
        var start = 0;
        for (var i = 0; i <= trimmed.Length; i++)
        {
            if (i < trimmed.Length && trimmed[i] != ' ') continue;
            if (i > start)
                result.Add(new TextWord(trimmed[start..i], new TextBox(box.Left + start * width, box.Top, box.Left + i * width, box.Bottom)));
            start = i + 1;
        }
        return result;
    }

    /// <summary>
    /// Simgeyi kareden keser ve PNG (data: adresi) olarak verir; bulunamazsa null. Kutu kabacadır (simgenin okunduğu
    /// harf simgeden dar, kestirilen yer kayık olabilir): içindeki zeminden ayrışan pikseller sütun sütun gruplanır,
    /// kutunun ortasına en yakın grup simgedir ve sıkıca kırpılır. <paramref name="frame"/>, kutunun oranlandığı karedir.
    /// </summary>
    public static string? Crop(Frame frame, TextBox box)
    {
        if (Locate(frame, box) is not { } ink) return null;
        return "data:image/png;base64," + Convert.ToBase64String(Png(frame.Crop(ink.Left, ink.Top, ink.Width, ink.Height)));
    }

    /// <summary>Kutudaki simgenin karedeki yeri (piksel, kenar payıyla); simge yoksa null. Bkz. <see cref="Crop"/>.</summary>
    private static (int Left, int Top, int Width, int Height, int InkWidth, int InkHeight)? Locate(Frame frame, TextBox box)
    {
        int x0 = Math.Clamp((int)Math.Floor(box.Left * frame.Width), 0, frame.Width);
        int x1 = Math.Clamp((int)Math.Ceiling(box.Right * frame.Width), 0, frame.Width);
        int y0 = Math.Clamp((int)Math.Floor(box.Top * frame.Height), 0, frame.Height);
        int y1 = Math.Clamp((int)Math.Ceiling(box.Bottom * frame.Height), 0, frame.Height);
        int width = x1 - x0, height = y1 - y0;
        if (width < 4 || height < 6) return null;

        var background = BorderMedian(frame, x0, y0, width, height);
        var ink = new bool[width * height];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var i = ((y0 + y) * frame.Stride) + ((x0 + x) * 4);
                var distance = Math.Abs(frame.Pixels[i] - background.B) + Math.Abs(frame.Pixels[i + 1] - background.G)
                               + Math.Abs(frame.Pixels[i + 2] - background.R);
                ink[(y * width) + x] = distance > 90;
            }

        // Bitişik piksel kümeleri: simge genellikle kutudaki en büyük kümedir; kutuya taşan komşu harfler ("Use|o")
        // ayrı küçük kümelerdir. Ana kümenin içine düşen kümeler (halkanın içindeki △, düğmenin üstündeki "R2") simgeye katılır.
        var components = Components(ink, width, height);
        var central = components.Where(c => (c.Left + c.Right) / 2.0 >= width * 0.1 && (c.Left + c.Right) / 2.0 <= width * 0.9).ToList();
        if (central.Count == 0) return null;
        var main = central.MaxBy(c => (c.Right - c.Left) * (c.Bottom - c.Top));
        int start = main.Left, end = main.Right, top = main.Top, bottom = main.Bottom;
        double padX = (end - start) * 0.15, padY = (bottom - top) * 0.15;
        foreach (var c in components)
            if (c.Left >= start - padX && c.Right <= end + padX && c.Top >= top - padY && c.Bottom <= bottom + padY)
                (start, end, top, bottom) = (Math.Min(start, c.Left), Math.Max(end, c.Right), Math.Min(top, c.Top), Math.Max(bottom, c.Bottom));
        // Simge satır yüksekliğinin en az üçte biri kadardır; daha küçüğü kir ya da harf kırıntısıdır.
        if (bottom - top < height * 0.3 || end - start < 3) return null;

        const int margin = 2;
        var left = Math.Max(0, x0 + start - margin);
        var right = Math.Min(frame.Width, x0 + end + margin);
        var cropTop = Math.Max(0, y0 + top - margin);
        var cropBottom = Math.Min(frame.Height, y0 + bottom + margin);
        return (left, cropTop, right - left, cropBottom - cropTop, end - start, bottom - top);
    }

    /// <summary>
    /// Kutuda simge biçiminde bir şekil var mı: zeminden ayrışan, satır yüksekliğinin en az yarısı kadar ve kabaca kare
    /// (düğme dairesi, omuz tuşu kutusu). Boşluk ya da harf kırıntısı simge sayılmaz.
    /// </summary>
    /// <summary>Kutudaki parlak piksellerin çoğu renksiz mi (kumanda simgesi beyaz/gri; portre, harita renkli).</summary>
    internal static bool IsColourless(Frame frame, TextBox box)
    {
        int left = (int)(box.Left * frame.Width), right = (int)Math.Ceiling(box.Right * frame.Width);
        int top = (int)(box.Top * frame.Height), bottom = (int)Math.Ceiling(box.Bottom * frame.Height);
        int bright = 0, coloured = 0;
        for (var y = Math.Max(0, top); y < Math.Min(frame.Height, bottom); y++)
            for (var x = Math.Max(0, left); x < Math.Min(frame.Width, right); x++)
            {
                var p = y * frame.Stride + x * 4;
                int b = frame.Pixels[p], g = frame.Pixels[p + 1], r = frame.Pixels[p + 2];
                if ((299 * r + 587 * g + 114 * b) / 1000 < 110) continue;
                bright++;
                if (Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b)) > 60) coloured++;
            }
        return bright > 0 && coloured * 4 < bright;
    }

    internal static bool HasIcon(Frame frame, TextBox box, double lineHeightPx)
    {
        if (Locate(frame, box) is not { } ink) return false;
        if (ink.InkHeight < lineHeightPx * 0.5 || ink.InkHeight > lineHeightPx * 2.2) return false;
        var aspect = (double)ink.InkWidth / ink.InkHeight;
        return aspect is >= 0.6 and <= 2.4;
    }

    /// <summary>
    /// Ek alanlarda fiilsiz yerlerdeki simgeler (yalnız simge kareden doğrulanırsa işaretlenir; <see cref="Mark"/> fiil
    /// kalıbını zaten kapsar):
    /// <list type="bullet">
    /// <item>Büyük harfli tuş çubuğu ("SET DESTINATION ✕ EXIT ○", "OFFER RIDE e LUCIA"): sözcük arasındaki simge
    /// genişliğinde boşluk, tek harf ya da harfsiz parça ("e", "A", "•"), sonundaki simge.</item>
    /// <item>Satırın başındaki simge ("△ Pick up", "B Pick up"): satırın hemen solu ya da başta tek harf/işaret.</item>
    /// </list>
    /// Sıradan cümlenin ortasındaki boşluk aranmaz: orada harita işareti ya da renkli ad durur (GTA 6: "your personal
    /// vehicle ◆ for easy access"). GameTranslator.IconWords (AGPL-3.0-only) üzerinden Nino Game Translator'ın VisionReader.withIcons / withEdgeIcons kurallarından uyarlandı.
    /// </summary>
    /// <param name="monochrome">
    /// Otomatik bulunan ekran yazısında: yalnız renksiz (beyaz/gri) simgeler kabul edilir. Görev kutusundaki portre ve
    /// harita parçası simge sanılıp çevirinin içine kesiliyordu (gerçek kare doğrulaması, GTA 6).
    /// </param>
    public static TextLine MarkFree(TextLine line, Frame frame, bool monochrome = false)
    {
        if (line.Box is not { } lineBox || line.Icons is { Count: > 0 } || frame.Width < 8 || frame.Height < 8) return line;
        var words = line.Words is { Count: > 0 } measured ? measured : Estimate(line.Text, lineBox);
        if (words.Count == 0) return line;
        double top = lineBox.Top, bottom = lineBox.Bottom, pad = (bottom - top) * 0.3;
        var linePx = (bottom - top) * frame.Height;
        if (linePx < 6) return line;
        var head = string.Concat(words.Where(word => word.Text.Length > 1 && !Names.Contains(word.Text)).Select(word => word.Text));
        var bar = head.Count(char.IsLetter) >= 2 && head == head.ToUpperInvariant();
        var tokens = new List<string>();
        var icons = new List<IconSlot>();
        var spanX = linePx * 1.8 / frame.Width;
        TextBox Padded(double left, double right) =>
            new(Math.Clamp(left, 0, 1), Math.Clamp(top - pad, 0, 1),
                Math.Clamp(right, 0, 1), Math.Clamp(bottom + pad, 0, 1));
        bool Icon(TextBox box) => HasIcon(frame, box, linePx) && (!monochrome || IsColourless(frame, box));

        // Satırın solundaki simge (okunmamış): "△ Pick up".
        if (!IsIconToken(words[0].Text) && lineBox.Left > 0)
        {
            var box = Padded(lineBox.Left - spanX, lineBox.Left - (spanX * 0.08));
            if (Icon(box)) { tokens.Add(Marker.ToString()); icons.Add(new IconSlot(box, "")); }
        }
        for (var i = 0; i < words.Count; i++)
        {
            var word = words[i];
            if (bar && i > 0)
            {
                var left = words[i - 1].Box.Right;
                var gapPx = (word.Box.Left - left) * frame.Width;
                if (gapPx > linePx * 0.9 && tokens.LastOrDefault() != Marker.ToString())
                {
                    var box = Padded(left + (gapPx * 0.1 / frame.Width), word.Box.Left - (gapPx * 0.1 / frame.Width));
                    if (Icon(box)) { tokens.Add(Marker.ToString()); icons.Add(new IconSlot(box, "")); }
                }
            }
            var text = word.Text;
            var core = text.Trim(Brackets.ToCharArray());
            // Tuş çubuğunda tek harf/rakam ya da yanlış okunmuş omuz tuşu ("11", "12"); satır başında simge gibi parça.
            var named = Names.Contains(core);
            var suspicious = bar
                ? named || core.Length == 1 || core is "11" or "12" or "13" or "21" or "22" or "23" || (core.Length <= 2 && !core.Any(char.IsLetterOrDigit))
                : i == 0 && words.Count >= 2 && IsIconToken(text);
            if (suspicious)
            {
                var boxLeft = i > 0 ? Math.Min(word.Box.Left, (words[i - 1].Box.Right + word.Box.Left) / 2) : word.Box.Left - ((word.Box.Right - word.Box.Left) / 2);
                var boxRight = i + 1 < words.Count ? Math.Max(word.Box.Right, (word.Box.Right + words[i + 1].Box.Left) / 2)
                                                   : word.Box.Right + ((word.Box.Right - word.Box.Left) / 2);
                // OCR yalnız içteki harfleri kutulayabilir. Dış çerçeveye pay bırak, iki düğme arasındaki ortayı geçme.
                var measuredButton = named && line.Words is { Count: > 0 };
                if (measuredButton)
                {
                    var rim = linePx * 0.3 / frame.Width;
                    boxLeft = Math.Max(boxLeft, word.Box.Left - rim);
                    boxRight = Math.Min(boxRight, word.Box.Right + rim);
                }
                var box = Padded(boxLeft, boxRight);
                // Satır başında okunan düğme adı ("R2 Swing") kareden doğrulanmadıkça işaretlenmez: bu kısa ipuçları
                // eskisi gibi çevrilmez, düğme görünür kalır.
                if (Icon(box))
                {
                    if (measuredButton || tokens.LastOrDefault() != Marker.ToString())
                    {
                        tokens.Add(Marker.ToString());
                        icons.Add(new IconSlot(box, core));
                    }
                    continue;
                }
                // Tanınmayan harfsiz parça ("•", "*"): simge değil, yazı da değil.
                if (!named && !core.Any(char.IsLetterOrDigit) && core is not ("+" or "/" or "&" or "-")) continue;
            }
            tokens.Add(text);
        }
        // Tuş çubuğunun sonundaki simge: "SELECT ✕".
        if (bar && tokens.Count > 0 && tokens[^1] != Marker.ToString() && lineBox.Right < 1)
        {
            var box = Padded(lineBox.Right + (spanX * 0.08), lineBox.Right + spanX);
            if (Icon(box)) { tokens.Add(Marker.ToString()); icons.Add(new IconSlot(box, "")); }
        }
        if (icons.Count == 0) return line;
        return line with { Text = string.Join(' ', tokens), Words = null, Icons = icons };
    }

    /// <summary>Kesilmiş simgeler: kutusu verilen her simge kareden kesilir (bkz. <see cref="Crop"/>).</summary>
    public static IReadOnlyList<IconSlot> WithImages(IReadOnlyList<IconSlot> icons, Frame frame) =>
        [.. icons.Select(icon => icon.Image is null ? icon with { Image = Crop(frame, icon.Box) } : icon)];

    /// <summary>Sekiz komşulu bitişik piksel kümelerinin kutuları (sağ ve alt kenar dahil değil); dört pikselden küçükler atılır.</summary>
    private static List<(int Left, int Top, int Right, int Bottom)> Components(bool[] ink, int width, int height)
    {
        var seen = new bool[ink.Length];
        var result = new List<(int, int, int, int)>();
        var stack = new Stack<int>();
        for (var start = 0; start < ink.Length; start++)
        {
            if (!ink[start] || seen[start]) continue;
            int left = width, top = height, right = 0, bottom = 0, count = 0;
            seen[start] = true;
            stack.Push(start);
            while (stack.Count > 0)
            {
                var index = stack.Pop();
                int x = index % width, y = index / width;
                count++;
                (left, right, top, bottom) = (Math.Min(left, x), Math.Max(right, x + 1), Math.Min(top, y), Math.Max(bottom, y + 1));
                for (var dy = -1; dy <= 1; dy++)
                    for (var dx = -1; dx <= 1; dx++)
                    {
                        int nx = x + dx, ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
                        var next = (ny * width) + nx;
                        if (!ink[next] || seen[next]) continue;
                        seen[next] = true;
                        stack.Push(next);
                    }
            }
            if (count >= 4) result.Add((left, top, right, bottom));
        }
        return result;
    }

    private static (int B, int G, int R) BorderMedian(Frame frame, int x0, int y0, int width, int height)
    {
        var b = new List<int>();
        var g = new List<int>();
        var r = new List<int>();
        void Add(int x, int y)
        {
            var i = (y * frame.Stride) + (x * 4);
            b.Add(frame.Pixels[i]);
            g.Add(frame.Pixels[i + 1]);
            r.Add(frame.Pixels[i + 2]);
        }
        for (var x = x0; x < x0 + width; x++) { Add(x, y0); Add(x, y0 + height - 1); }
        for (var y = y0; y < y0 + height; y++) { Add(x0, y); Add(x0 + width - 1, y); }
        static int Median(List<int> values) { values.Sort(); return values[values.Count / 2]; }
        return (Median(b), Median(g), Median(r));
    }

    /// <summary>BGRA kareyi RGBA PNG'ye çevirir.</summary>
    public static byte[] Png(Frame frame)
    {
        var raw = new byte[frame.Height * ((frame.Width * 4) + 1)];
        for (var y = 0; y < frame.Height; y++)
        {
            var row = y * ((frame.Width * 4) + 1);
            for (var x = 0; x < frame.Width; x++)
            {
                int i = (y * frame.Stride) + (x * 4), o = row + 1 + (x * 4);
                raw[o] = frame.Pixels[i + 2];
                raw[o + 1] = frame.Pixels[i + 1];
                raw[o + 2] = frame.Pixels[i];
                raw[o + 3] = 255;
            }
        }
        using var compressed = new MemoryStream();
        using (var zlib = new ZLibStream(compressed, CompressionLevel.Optimal, leaveOpen: true)) zlib.Write(raw);
        using var png = new MemoryStream();
        png.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        var header = new byte[13];
        WriteBigEndian(header, 0, frame.Width);
        WriteBigEndian(header, 4, frame.Height);
        header[8] = 8; // bit derinliği
        header[9] = 6; // RGBA
        Chunk(png, "IHDR", header);
        Chunk(png, "IDAT", compressed.ToArray());
        Chunk(png, "IEND", []);
        return png.ToArray();
    }

    private static void Chunk(Stream stream, string type, byte[] data)
    {
        var length = new byte[4];
        WriteBigEndian(length, 0, data.Length);
        stream.Write(length);
        var body = new byte[4 + data.Length];
        Encoding.ASCII.GetBytes(type).CopyTo(body, 0);
        data.CopyTo(body, 4);
        stream.Write(body);
        var crc = new byte[4];
        WriteBigEndian(crc, 0, (int)Crc32(body));
        stream.Write(crc);
    }

    private static void WriteBigEndian(byte[] target, int offset, int value)
    {
        target[offset] = (byte)(value >> 24);
        target[offset + 1] = (byte)(value >> 16);
        target[offset + 2] = (byte)(value >> 8);
        target[offset + 3] = (byte)value;
    }

    private static readonly uint[] CrcTable = Enumerable.Range(0, 256).Select(n =>
    {
        var c = (uint)n;
        for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        return c;
    }).ToArray();

    private static uint Crc32(byte[] data)
    {
        var crc = 0xFFFFFFFF;
        foreach (var b in data) crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFF;
    }
}

/// <summary>TV'de çevirinin içine konacak simge: düz metinde <paramref name="At"/>. karakterden önce.</summary>
public sealed record IconPlacement(int At, string Image);

/// <summary>
/// Simgenin yerini çeviri boyunca korur. Çeviriden önce her <see cref="ButtonIcons.Marker"/> uydurma bir özel adla
/// değiştirilir (<see cref="TermProtector"/> ile aynı gerekçe: çevirmenler özel adı olduğu gibi bırakır, "[1]" gibi
/// işaretleri düşürebilir): "Hold Feldor to sprint" → "Koşmak için Feldor'u basılı tut". Çeviriden sonra ad (ekiyle
/// birlikte: ek gerçek düğmenin adına uymaz) simgenin sıra imine döner; çevirmen adı düşürdüyse simge başa konur.
/// </summary>
public static class IconText
{
    /// <summary>Çevrilmiş metinde k. simgenin imi: U+E000 + k (özel kullanım alanı).</summary>
    public const char FirstSlot = '';

    /// <summary>Terim korumasının adlarıyla aynı kurallar; sondan başlanır, ikisi aynı metinde karşılaşmasın.</summary>
    private static readonly string[] Names = [.. TermProtector.Placeholders.Reverse()];

    /// <summary>
    /// Simgeleri adlarla değiştirir; kullanılan adlar sırayla döner. Ad kalmazsa fazla simge düşer. Simgenin ardındaki
    /// noktalama ada yapışık kalır ("Hold Feldor.").
    /// </summary>
    public static (string Text, IReadOnlyList<string> Names) Protect(string paragraph)
    {
        if (paragraph.IndexOf(ButtonIcons.Marker) < 0) return (paragraph, []);
        var free = new Queue<string>(Names.Where(name => !paragraph.Contains(name, StringComparison.OrdinalIgnoreCase)));
        var used = new List<string>();
        var builder = new StringBuilder(paragraph.Length + 16);
        foreach (var c in paragraph)
        {
            if (c != ButtonIcons.Marker) builder.Append(c);
            else if (free.Count > 0) { var name = free.Dequeue(); used.Add(name); builder.Append(name); }
        }
        return (Collapse(builder.ToString()), used);
    }

    /// <summary>
    /// Çevirideki adları <paramref name="offset"/>'ten başlayan sıra imlerine çevirir. Çeviride bulunmayan adın simgesi
    /// metnin başına konur (en azından hangi düğme olduğu görünsün).
    /// </summary>
    public static string Restore(string translation, IReadOnlyList<string> names, int offset)
    {
        var missing = new StringBuilder();
        for (var k = 0; k < names.Count; k++)
        {
            var slot = ((char)(FirstSlot + offset + k)).ToString();
            var pattern = new Regex($@"(?<![\p{{L}}\p{{N}}]){Regex.Escape(names[k])}(?:\s?['’`´]\p{{L}}+|\p{{L}}+)?(?![\p{{L}}\p{{N}}])",
                                    RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (pattern.IsMatch(translation)) translation = pattern.Replace(translation, slot);
            else missing.Append(slot).Append(' ');
        }
        return missing.Length == 0 ? translation : missing + translation;
    }

    /// <summary>Okunan paragraf çevrilmeden gösterilecekse simgeleri sırayla imlenir.</summary>
    public static string Indexed(string paragraph, int offset)
    {
        var builder = new StringBuilder(paragraph.Length);
        var next = offset;
        foreach (var c in paragraph) builder.Append(c == ButtonIcons.Marker ? (char)(FirstSlot + next++) : c);
        return builder.ToString();
    }

    /// <summary>
    /// İmli metni TV'ye gidecek düz metne ve simge yerlerine ayırır. Kesilemeyen simgenin yerine okunan hali yazılır;
    /// art arda boşluklar teke iner (eski TV uygulamaları simgesiz düz metni gösterir).
    /// </summary>
    public static (string Text, IReadOnlyList<IconPlacement> Icons) Render(string marked, IReadOnlyList<IconSlot> slots)
    {
        var text = new StringBuilder(marked.Length);
        var icons = new List<IconPlacement>();
        void Append(string value)
        {
            foreach (var c in value)
            {
                if (c == ' ' && (text.Length == 0 || text[^1] == ' ' || text[^1] == '\n')) continue;
                // Simgenin ardındaki noktalama ve satır sonu önündeki boşluğu yutar: "için [◎], etkileşim".
                if ((c == '\n' || ".,;:!?…)".Contains(c)) && text.Length > 0 && text[^1] == ' ')
                {
                    text.Length--;
                    for (var i = 0; i < icons.Count; i++)
                        if (icons[i].At > text.Length) icons[i] = icons[i] with { At = text.Length };
                }
                text.Append(c);
            }
        }
        foreach (var c in marked)
        {
            var k = c - FirstSlot;
            if (c == ButtonIcons.Marker || k < 0 || k >= 0x100) { if (c != ButtonIcons.Marker) Append(c.ToString()); continue; }
            if (k < slots.Count && slots[k].Image is { } image) icons.Add(new IconPlacement(text.Length, image));
            else if (k < slots.Count) Append(slots[k].Text);
        }
        var plain = text.ToString();
        var trimmed = plain.TrimEnd();
        return (trimmed, [.. icons.Select(icon => icon with { At = Math.Min(icon.At, trimmed.Length) })]);
    }

    /// <summary>Simgesiz düz metin (okunanın kaydı ve karşılaştırma için).</summary>
    public static string Plain(string text) =>
        Collapse(new string([.. text.Where(c => c != ButtonIcons.Marker && (c < FirstSlot || c >= FirstSlot + 0x100))]));

    private static string Collapse(string text) => MultipleSpaces().Replace(text, " ").Trim();

    private static Regex MultipleSpaces() => new(" {2,}", RegexOptions.CultureInvariant);
}
