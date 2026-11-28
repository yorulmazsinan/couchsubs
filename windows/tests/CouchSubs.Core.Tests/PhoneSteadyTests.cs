// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Aynı mesajın OCR'la bir iki harfi farklı okunuşu yeni mesaj sayılmaz: bilinen çevirisi kullanılır, çeviri gidip gelmez.
/// Sayı ya da olumsuzluk değiştiren okuma ve kısa satır aynı mesaj sayılmaz (Mac GamePhoneStabilityTests ve Android
/// PhoneSteadyTest ile aynı deneme).
/// </summary>
public class PhoneSteadyTests
{
    private static readonly Dictionary<string, string> Known = new()
    {
        ["Did you hear back from the guy at the marina?"] = "Marinadaki adamdan haber aldın mı?",
        ["Meet me at 5 by the docks"] = "Benimle 5'te rıhtımda buluş",
        ["I can do that tonight"] = "Bunu bu gece yapabilirim",
        ["Ok"] = "Tamam",
    };

    [Fact]
    public void SameMessageReadSlightlyDifferentlyKeepsItsTranslation()
    {
        Assert.Equal("Marinadaki adamdan haber aldın mı?", PhoneSteady.Translation("Did you hear back from the guy at the rnarina?", Known));
        Assert.Equal("Marinadaki adamdan haber aldın mı?", PhoneSteady.Translation("Did you hear back frorn the guy at the marina", Known));
        Assert.Null(PhoneSteady.Translation("Meet me at 6 by the docks", Known));
        Assert.Null(PhoneSteady.Translation("I can't do that tonight", Known));
        Assert.Null(PhoneSteady.Translation("On", Known));
        Assert.Null(PhoneSteady.Translation("Where are you going tonight?", Known));
        Assert.Equal("Tamam", PhoneSteady.Translation("Ok", Known));
    }

    [Fact]
    public void PhoneMemoryKeepsTheFirstTranslationAcrossReplyOcrVariants()
    {
        const string original = "You still have that jumpsuit? I kinda wanna see Jay in it. You'll like it, Jay. Really breathable.";
        const string translation = "Tulum hâlâ sende mi? Jay'i onunla görmek isterim. Beğenirsin Jay, hava alıyor.";
        string[] variants = [original, original.Replace("You'll", "Youll"), original.Replace("You'll", "You'l"),
            original.Replace("it, Jay", "it,t Jay"), original.Replace("it, Jay", "it Jay")];
        var memory = new PhoneMemory();
        memory.Remember(original, translation);
        foreach (var variant in variants)
        {
            Assert.True(PhoneSteady.SameReading(original, variant));
            Assert.Equal(translation, memory.Translation(variant));
            memory.Remember(variant, "Motorun sonraki çevirisi.");
        }
        Assert.All(variants, variant => Assert.Equal(translation, memory.Translation(variant)));
    }

    [Fact]
    public void SingleLetterSlipsInLongWordsAreTheSameMessage()
    {
        const string original = "You still have that jumpsuit? I kinda wanna see Jay in it. You'll like it, Jay. Really breathable.";
        Assert.True(PhoneSteady.SameReading(original, original.Replace("breathable", "breathabie")));
        Assert.True(PhoneSteady.SameReading(original, original.Replace("jumpsuit", "jumpsuitt").Replace("Really", "Reaily")));
        Assert.True(PhoneSteady.SameReading("Balsero IS SOMETHING good tonight", "Balsero IS SOMETHINnG good tonight"));
        Assert.True(PhoneSteady.SameReading("Thx amigo! U find", "Thx amigo! U flnd"));
        // Üç sözcükte kayma, kısa sözcükte değişim ve başa eklenen harf aynı mesaj değildir.
        Assert.False(PhoneSteady.SameReading(original,
            original.Replace("breathable", "breathahle").Replace("jumpsuit", "jumpsuil").Replace("Really", "Reaxly")));
        Assert.False(PhoneSteady.SameReading("It is so cold outside tonight.", "It is so bold outside tonight."));
        Assert.False(PhoneSteady.SameReading("I'm here waiting for you at the station.", "I'm there waiting for you at the station."));
    }

    /// <summary>X, 28 Kas, beta.107 (dördüncü günlük): bitişik okunan sözcük yeni mesaj sayılıyor, sayfa yeniden
    /// yayımlanıyordu; paketin bulanık eşleşmesi "3 Members"ı "5 üye" gösteriyordu.</summary>
    [Fact]
    public void JoinedWordsAreTheSameMessageAndFuzzyPackKeepsNumbers()
    {
        const string message = "Yo I still can't believe them jits tried us. This the community center in Southside.";
        Assert.True(PhoneSteady.SameReading(message, message.Replace("I still", "Istill")));
        Assert.True(PhoneSteady.TruncatedReading("Yo Istill can't believe them jits", message));
        Assert.False(GamePackLibrary.KeepsNumbers("3 Members", "5 üye"));
        Assert.True(GamePackLibrary.KeepsNumbers("3 Members", "3 üye"));
        Assert.True(GamePackLibrary.KeepsNumbers("Southside, SW 13th St", "Southside, SW 13. Cadde"));
    }

    [Fact]
    public void DifferentMessagesKeepSeparateTranslations()
    {
        foreach (var (first, second) in new[] { ("I'm here.", "I'm there."),
            ("I'm here waiting for you at the station.", "I'm there waiting for you at the station."),
            ("Meet me at exit 15.", "Meet me at exit 16."), ("I can do that tonight.", "I can't do that tonight.") })
        {
            var memory = new PhoneMemory();
            memory.Remember(first, "Birinci");
            Assert.Null(memory.Translation(second));
            Assert.False(PhoneSteady.SameBubble(first, new(0, 0, 1, 1), second, new(0, 0, 1, 1)));
            Assert.Equal("İkinci", memory.Remember(second, "İkinci"));
        }
    }

    [Fact]
    public void ScrollIsAllMatchedBubblesMovingTheSameWay()
    {
        // #1202, #1197: kaydırınca balonların hepsi aynı yöne kayar; bekletme ve konum sabitleme atlanır.
        (string, double)[] before = [("Where are you?", .30), ("At the docks.", .45), ("On my way.", .60)];
        (string, double)[] up = [("At the docks.", .25), ("On my way.", .40), ("Hurry up.", .55)];
        Assert.True(PhoneSteady.Scrolled(before, up, .04));
        (string, double)[] down = [("Hey.", .15), ("Where are you?", .38), ("At the docks.", .53)];
        Assert.True(PhoneSteady.Scrolled(before, down, .04));
        // Titreme (satır yüksekliğinin yarısından az) kaydırma değildir.
        (string, double)[] jitter = [("Where are you?", .31), ("At the docks.", .46), ("On my way.", .61)];
        Assert.False(PhoneSteady.Scrolled(before, jitter, .04));
        // Biri yukarı biri aşağı: kaydırma değil.
        (string, double)[] mixed = [("Where are you?", .20), ("At the docks.", .55)];
        Assert.False(PhoneSteady.Scrolled(before, mixed, .04));
        // Eşleşen balon yok ya da satır yüksekliği bilinmiyor.
        Assert.False(PhoneSteady.Scrolled(before, [("New chat.", .2)], .04));
        Assert.False(PhoneSteady.Scrolled(before, up, 0));
        // OCR'la biraz farklı okunan aynı mesaj da eşleşir.
        (string, double)[] typo = [("At the docks now, come.", .30)];
        Assert.True(PhoneSteady.Scrolled([("At the docks now, corne.", .50)], typo, .04));
    }
}
