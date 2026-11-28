// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// GTA 6 telefonunun çevirisi kararlı (X, 22 Kas: "sağ tarafta kutu çıkarıyorsun ama her saniye şekli de hareketi de
/// değişiyor"): aynı ekran gürültülü okunsa da, telefon kapanıp açılsa da çizilen Türkçe birebir aynı kalır, mesaj yeniden
/// çevrilmez. Mac (PhoneSteadyOutputTests.swift) ve Android (PhoneSteadyOutputTest.kt) aynı durumları sınar. Metinler uydurmadır.
/// </summary>
public partial class RegionWatcherTests
{
    /// <summary>X, 28 Kas, beta.107: telefon açıkken, oyun dururken balon çevirileri kendi kendine değişiyor,
    /// balonlar birleşip ayrılıyor, renk turuncu/mavi gidip geliyor, kutular köşeli.</summary>
    [Fact]
    public async Task DegradedChatReadsKeepTheShownPageAndNewMessagesStillUpdate()
    {
        const string a = "Whatever the next stunt is, maybe add wearing underwear to the plan.";
        const string b = "You still have that jumpsuit? I kinda wanna see Jay in it. You'll like it, Jay. Really breathable.";
        const string shortB = "You still have that";
        const string newMessage = "Meet at the marina before sunset.";
        static TextLine Bubble(string text, double top, double height = .025)
        {
            var box = new TextBox(.30, top, .92, top + height);
            return new TextLine(text, box) { PhoneBox = box };
        }
        var first = Bubble("Whatever the next stunt is, maybe", .53);
        var lastA = Bubble("add wearing underwear to the plan.", .559);
        var second = Bubble("You still have that jumpsuit? I kinda", .61);
        var middleB = Bubble("wanna see Jay in it. You'll like it,", .639);
        var lastB = Bubble("Jay. Really breathable.", .668);
        var header = Bubble("Papa Audacity, Jason, Lucia", .07);
        var reader = new Reader { Lines = [header, first, lastA, second, middleB, lastB] };
        var server = new Server();
        var translator = new Translator { Map = text => text switch
        {
            a => "Bir sonraki numara ne olursa olsun, plana iç çamaşırı giymeyi de ekleyin.",
            b => "Tulum hâlâ sende mi? Jay'i onunla görmek isterim. Beğenirsin Jay, hava alıyor.",
            _ => "Güneş batmadan marinada buluşalım.",
        } };
        var watcher = new RegionWatcher(reader, translator, server);
        using var lifetime = new CancellationTokenSource();
        var phone = Phone with { PanelLifetime = lifetime.Token, Region = new CropRegion(0, 1, 0, 1) };
        await watcher.PassAsync(Shade(20), [phone]);
        await watcher.PassAsync(Shade(20), [phone]);
        Assert.Equal([a, b], server.Blocks[^1]!.Select(item => item.Source));
        var sends = server.Sent.Count;
        var calls = translator.Calls.Count;

        List<TextLine>[] worse = [[first, lastA, second, middleB, lastB],
            [first, lastA], [first, lastA, Bubble(shortB, .611)], [Bubble(a + " " + b, .531, .164)],
            [Bubble(a + " " + shortB, .532, .105)], [Bubble(shortB, .611)],
            [first, lastA, Bubble("You still have that see Jay in it.", .612),
                Bubble("Youll like it, Jay. Really breathable.", .641)]];
        foreach (var reading in worse)
        {
            reader.Lines = reading;
            foreach (byte shade in new byte[] { 90, 160, 90 })
                await watcher.PassAsync(Shade(shade), [phone]);
            Assert.Equal(sends, server.Sent.Count);
            Assert.Equal(calls, translator.Calls.Count);
        }

        reader.Lines = [header, first, lastA, second, middleB, lastB, Bubble(newMessage, .76)];
        await watcher.PassAsync(Shade(30), [phone]);
        Assert.Equal([a, b, newMessage], server.Blocks[^1]!.Select(item => item.Source));
        reader.Lines = [Bubble(second.Text, .38), Bubble(middleB.Text, .409), Bubble(lastB.Text, .438), Bubble(newMessage, .53)];
        await watcher.PassAsync(Shade(160), [phone]);
        Assert.Equal([b, newMessage], server.Blocks[^1]!.Select(item => item.Source));
        Assert.Equal(calls + 1, translator.Calls.Count);
    }

    /// <summary>X, 28 Kas, beta.107 (ikinci günlük): uzun ilk mesajın üst ya da ortadaki satırları okunmayınca balon her
    /// okumada başka satırdan başlıyordu ("in the Keys…", "him out…"); gösterilen sayfa korunur.</summary>
    [Fact]
    public async Task LongBubbleReadWithoutItsTopLinesKeepsTheShownPage()
    {
        static TextLine Bubble(string text, double top, double left = .30)
        {
            var box = new TextBox(left, top, .80, top + .025);
            return new TextLine(text, box) { PhoneBox = box };
        }
        string[] rows = ["Hey Lu, checking in. Been down", "in the Keys. Kenton got caught", "up in some bad shit, had to get",
            "him out. But he's okay now,", "about to start selling the goods.", "Should be some big money..."];
        var lines = rows.Select((text, i) => Bubble(text, .20 + i * .029)).ToList();
        var reply = Bubble("Couple mins!", .40, .60);
        var reader = new Reader { Lines = [.. lines, reply] };
        var server = new Server();
        var translator = new Translator { Map = text => text.StartsWith("Hey Lu") ? "Selam Lu, haber vereyim dedim." : "Birkaç dakika!" };
        var watcher = new RegionWatcher(reader, translator, server);
        var log = new List<string>();
        watcher.Log = log.Add;
        using var lifetime = new CancellationTokenSource();
        var phone = Phone with { PanelLifetime = lifetime.Token, Region = new CropRegion(0, 1, 0, 1) };
        await watcher.PassAsync(Shade(20), [phone]);
        await watcher.PassAsync(Shade(20), [phone]);
        Assert.Equal(2, server.Blocks[^1]!.Count);
        var sends = server.Sent.Count;
        var calls = translator.Calls.Count;

        List<TextLine>[] worse = [[.. lines.Skip(1), reply], [.. lines.Skip(3), reply], [.. lines.Take(2), .. lines.Skip(3), reply]];
        foreach (var reading in worse)
        {
            reader.Lines = reading;
            foreach (byte shade in new byte[] { 90, 160, 90 })
                await watcher.PassAsync(Shade(shade), [phone]);
            Assert.True(sends == server.Sent.Count, string.Join(" || ", log));
            Assert.Equal(calls, translator.Calls.Count);
        }
    }

    [Fact]
    public async Task NoisyPhoneReadingsAndReopeningKeepTheSameTranslation()
    {
        const string message = "Are you coming to the barbecue tonight?";
        var reader = new Reader { Lines = [Line(message)] };
        var server = new Server();
        var calls = 0;
        // Her çağrıda başka Türkçe veren motor (yapay zekâ gibi).
        var translator = new Translator { Map = text => $"Çeviri {Interlocked.Increment(ref calls)}: {text}" };
        var watcher = new RegionWatcher(reader, translator, server);
        var log = new List<string>();
        watcher.Log = log.Add;
        using var first = new CancellationTokenSource();
        var open = Phone with { PanelLifetime = first.Token };
        await watcher.PassAsync(Shade(10), [open]);
        await watcher.PassAsync(Shade(10), [open]);
        var shown = server.Sent[^1].Text;
        Assert.StartsWith("Çeviri 1:", shown);

        // Bir harfi oynayan, soru işareti kaçan okumalar.
        reader.Lines = [Line("Are you cominq to the barbecue tonight?")];
        await watcher.PassAsync(Shade(40), [open]);
        await watcher.PassAsync(Shade(40), [open]);
        reader.Lines = [Line("Are you coming to the barbecue tonight")];
        await watcher.PassAsync(Shade(70), [open]);
        await watcher.PassAsync(Shade(70), [open]);

        // Telefon kapanıp yeniden açıldı: hafızadaki çeviri kullanılır.
        first.Cancel();
        watcher.RemovePanel(open.Id);
        using var next = new CancellationTokenSource();
        var reopened = Phone with { PanelLifetime = next.Token };
        reader.Lines = [Line(message)];
        log.Clear();
        await watcher.PassAsync(Shade(10), [reopened]);
        await watcher.PassAsync(Shade(10), [reopened]);

        Assert.Equal(1, calls);
        Assert.Contains(log, line => line.EndsWith("→ hazır çeviri"));
        Assert.All(server.Sent.Where(sent => sent.Text.Length > 0), sent => Assert.Equal(shown, sent.Text));
        Assert.Equal(shown, server.Sent[^1].Text);
    }

    [Fact]
    public async Task ResetForgetsThePhoneMemory()
    {
        var reader = new Reader { Lines = [Line("Bring the folding chairs from the garage.")] };
        var server = new Server();
        var translator = new Translator();
        var watcher = new RegionWatcher(reader, translator, server);
        using var lifetime = new CancellationTokenSource();
        var open = Phone with { PanelLifetime = lifetime.Token };
        await watcher.PassAsync(Shade(10), [open]);
        await watcher.PassAsync(Shade(10), [open]);
        watcher.Reset();
        await watcher.PassAsync(Shade(10), [open]);
        await watcher.PassAsync(Shade(10), [open]);
        Assert.Equal(2, translator.Calls.Count);
    }
}
