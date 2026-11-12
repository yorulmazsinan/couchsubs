// SPDX-License-Identifier: AGPL-3.0-only

using System.Buffers.Binary;
using System.IO.Compression;
using CouchSubs.Core;
using CouchSubs.RemotePlay;

namespace CouchSubs.Linux.Tests;

public sealed class ClaudeTranslatorTests
{
    [Fact]
    public void OnlyAnthropicKeysGoToClaude()
    {
        Assert.True(ClaudeTranslator.IsClaudeKey(" sk-ant-api03-abc "));
        Assert.False(ClaudeTranslator.IsClaudeKey("0f1e2d3c-aaaa-bbbb-cccc-123456789abc:fx"));
    }

    [Fact]
    public void RequestIsShortAndCarriesContext()
    {
        var request = ClaudeTranslator.Request("Peter: I did it.", "Mina: Look at this.");
        Assert.Equal("claude-haiku-5-5", request.Model.Raw());
        Assert.InRange(request.MaxTokens, 100, 1000);
        // Varsayılan JSON kodlayıcı "<" işaretini < yazar; metni okunur karşılaştırmak için gevşek kodlama.
        var options = new System.Text.Json.JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
        var json = System.Text.Json.JsonSerializer.Serialize(request, options);
        Assert.Contains("<earlier>", json);
        Assert.Contains("<line>Peter: I did it.</line>", json);
        Assert.Contains("disabled", json);

        var first = System.Text.Json.JsonSerializer.Serialize(ClaudeTranslator.Request("Hello.", ""), options);
        Assert.DoesNotContain("<earlier>", first);
    }
}

public sealed class FileAppStoreTests : IDisposable
{
    private readonly string folder = Path.Combine(Path.GetTempPath(), "couchsubs-test-" + Guid.NewGuid().ToString("N"));
    private string FilePath => Path.Combine(folder, "secure.json");

    public void Dispose()
    {
        if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
    }

    [Fact]
    public void KaydedilenDegerYenidenAcilincaOkunur()
    {
        new FileAppStore(FilePath).Save("accountId", new byte[] { 1, 2, 3 });
        new FileAppStore(FilePath).Save("tvKey", "anahtar");

        var reopened = new FileAppStore(FilePath);
        Assert.Equal(new byte[] { 1, 2, 3 }, reopened.Load<byte[]>("accountId"));
        Assert.Equal("anahtar", reopened.Load<string>("tvKey"));
        Assert.Null(reopened.Load<string>("yok"));
    }

    [Fact]
    public void SilinenAnahtarOkunmaz()
    {
        var store = new FileAppStore(FilePath);
        store.Save("tvKey", "anahtar");
        store.Remove("tvKey");
        Assert.Null(new FileAppStore(FilePath).Load<string>("tvKey"));
    }

    [Fact]
    public void BozukDosyaKurulumuBastanBaslatir()
    {
        Directory.CreateDirectory(folder);
        File.WriteAllText(FilePath, "{bozuk");
        var store = new FileAppStore(FilePath);
        Assert.Null(store.Load<string>("tvKey"));
        store.Save("tvKey", "yeni");
        Assert.Equal("yeni", store.Load<string>("tvKey"));
    }

    [Fact]
    public void DosyayiYalnizSahibiOkuyabilir()
    {
        if (OperatingSystem.IsWindows()) return;
        new FileAppStore(FilePath).Save("tvKey", "anahtar");
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(FilePath));
    }
}

public sealed class PngTests
{
    [Fact]
    public void KareKucultulupGecerliPngOlur()
    {
        // 4x2 kare: sol yarı kırmızı, sağ yarı mavi (BGRA).
        var frame = Frame.Blank(4, 2);
        for (var y = 0; y < 2; y++)
            for (var x = 0; x < 4; x++)
            {
                var i = (y * frame.Stride) + (x * 4);
                frame.Pixels[i + (x < 2 ? 2 : 0)] = 255;
                frame.Pixels[i + 3] = 255;
            }

        var png = Png.Encode(frame, maxWidth: 2);

        Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, png[..8]);
        Assert.Equal("IHDR", System.Text.Encoding.ASCII.GetString(png, 12, 4));
        Assert.Equal(2, BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(16)));
        Assert.Equal(1, BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(20)));

        // IDAT: süzgeç baytı + iki RGB piksel (kırmızı, mavi).
        var length = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(33));
        Assert.Equal("IDAT", System.Text.Encoding.ASCII.GetString(png, 37, 4));
        using var zlib = new ZLibStream(new MemoryStream(png, 41, length), CompressionMode.Decompress);
        using var raw = new MemoryStream();
        zlib.CopyTo(raw);
        Assert.Equal(new byte[] { 0, 255, 0, 0, 0, 0, 255 }, raw.ToArray());
    }
}

public sealed class UiThreadTests
{
    [Fact]
    public async Task IsVeDevamiAyniIsParcacigindaCalisir()
    {
        var ui = new UiThread();
        var (before, after) = await ui.Run(async () =>
        {
            var first = Environment.CurrentManagedThreadId;
            await Task.Delay(20);
            return (first, Environment.CurrentManagedThreadId);
        });
        Assert.Equal(before, after);
        Assert.NotEqual(Environment.CurrentManagedThreadId, before);
    }

    [Fact]
    public async Task HataCagiranaUlasir()
    {
        var ui = new UiThread();
        await Assert.ThrowsAsync<InvalidOperationException>(() => ui.Run(() => throw new InvalidOperationException("olmadı")));
        // Hatadan sonra sıra çalışmaya devam eder.
        Assert.Equal(7, await ui.Run(() => 7));
    }
}

public sealed class TesseractReaderTests
{
    [Theory]
    [InlineData("en", "eng")]
    [InlineData("ja", "jpn")]
    [InlineData("de", "deu")]
    [InlineData("tur", "tur")]
    public void OyunDiliTesseractAdinaCevrilir(string language, string expected) =>
        Assert.Equal(expected, TesseractReader.TesseractName(language));

    private static TesseractReader.Word W(string text, float confidence) => new(text, confidence, 0, 0, 10, 10);

    [Theory]
    [InlineData("|", "I")]
    [InlineData("|'m", "I'm")]
    [InlineData("|t.", "It.")]
    [InlineData("a|b$", "a|b$")]
    [InlineData("word", "word")]
    public void DikCizgiOkunanBuyukIDuzeltilir(string read, string expected) =>
        Assert.Equal(expected, TesseractReader.FixCapitalI(read));

    [Fact]
    public void GoruntudenUydurulanSatirAtilir()
    {
        Assert.Empty(TesseractReader.Confident([W("ma", 51), W("dt", 69), W("io", 55), W("r", 34)]));
        // Tek harf ya da tek simge satır değildir.
        Assert.Empty(TesseractReader.Confident([W("~", 81)]));
    }

    [Fact]
    public void SatirinKenarinaYapisanCopKirpilirOrtadakiSozcukKalir()
    {
        // Tesseract doğru okuduğu sözcüğe de bazen 0 güven verir ("down", "and"); ortadaysa kalır.
        var line = TesseractReader.Confident([W("|", 54), W("Ss", 28), W("Keep", 96), W("your", 96), W("head", 96), W("down", 0),
            W("and", 0), W("follow", 96), W("me.", 97), W("eC,", 57)]);
        Assert.Equal("Keep your head down and follow me.", string.Join(' ', line.Select(word => word.Text)));
    }

    [Fact]
    public void HamKareTersCevrilirBeyazYaziKoyuOlur()
    {
        var frame = Frame.Blank(2, 1);
        frame.Pixels[0] = frame.Pixels[1] = frame.Pixels[2] = 255;   // beyaz piksel, yanındaki siyah
        Assert.Equal(new byte[] { 0, 255 }, TesseractReader.Gray(frame, invert: true));
        Assert.Equal(new byte[] { 255, 0 }, TesseractReader.Gray(frame, invert: false));
    }
}

public sealed class PanelTests
{
    [Fact]
    public void YapistirilanAdresOlduguGibiKullanilir()
    {
        var uri = Panel.ParseRedirect($"  {PsnAccount.RedirectPrefix}?code=abc123&cid=1  ");
        Assert.Equal("abc123", PsnAccount.CodeFromRedirect(uri));
    }

    [Theory]
    [InlineData("abc123")]
    [InlineData("code=abc123")]
    [InlineData("?code=abc123&cid=1")]
    public void YalnizKodYapistirilincaAdresTamamlanir(string pasted) =>
        Assert.Equal("abc123", PsnAccount.CodeFromRedirect(Panel.ParseRedirect(pasted)));
}
