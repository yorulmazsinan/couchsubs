// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Linux;

/// <summary>
/// Gecikmenin nereden geldiğini panel günlüğünde göstermek için yazı tanıma süresini ölçer. Her kare yazılmaz: yalnız
/// okunan metin değişince (yeni altyazı, altyazı kalktı) bir satır düşülür.
/// </summary>
internal sealed class TimedReader(ITextReader inner) : ITextReader
{
    private string lastLogged = "";

    public string Read(Frame image) => ReadLines(image, true).Text;

    public string Read(Frame image, bool deep) => ReadLines(image, deep).Text;

    public Reading ReadLines(Frame image, bool deep)
    {
        var started = Environment.TickCount64;
        var reading = inner.ReadLines(image, deep);
        var text = reading.Text.ReplaceLineEndings(" ").Trim();
        if (text != lastLogged)
        {
            lastLogged = text;
            Log.Write("okuma", $"{Environment.TickCount64 - started} ms{(deep ? " (derin)" : "")}: {(text.Length == 0 ? "(boş)" : text)}");
        }
        return reading;
    }
}

/// <summary>Cihaz üstü çevirinin süresini günlüğe yazar (önbellekten gelenler yazılmaz).</summary>
internal sealed class TimedTranslator(ITextTranslator inner, string name) : ITextTranslator
{
    public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
    {
        var started = Environment.TickCount64;
        var translated = await inner.TranslateAsync(text, cancellationToken);
        var elapsed = Environment.TickCount64 - started;
        if (elapsed > 5) Log.Write("çeviri", $"{name} {elapsed} ms");
        return translated;
    }

    public IReadOnlyList<CouchSubs.Core.Dubbing.SpokenLine> SpokenLines(string text) => inner.SpokenLines(text);
}
