// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

public class SubtitleStabilizerTests
{
    /// Noktalamayla bitmeyen satır yazılmakta olabilir; iki kare aynı okununca gönderilir.
    [Fact]
    public void UnfinishedLineIsSentAfterTwoStableFrames()
    {
        var s = new SubtitleStabilizer();
        Assert.Equal(StabilizerAction.None, s.Feed("We do not have time"));
        Assert.Equal(StabilizerAction.Translate("We do not have time"), s.Feed("We do not have time"));
        Assert.Equal(StabilizerAction.None, s.Feed("We do not have time"));
    }

    /// Süslü yazıda aynı cümle her karede başka çöple okunur; TV'de iki çeviri olarak görünmemeli.
    [Fact]
    public void GarbledRereadOfSentLineDoesNotReemit()
    {
        var s = new SubtitleStabilizer();
        const string first = "Across the deep waters, Pbo went,\nhoping a boat would carry him home.";
        Assert.Equal(StabilizerAction.Translate(first), s.Feed(first));
        Assert.Equal(StabilizerAction.None, s.Feed("Across the deep waters O went,"));
        Assert.Equal(StabilizerAction.None, s.Feed("Across the deep waters O went,"));
        Assert.Equal(StabilizerAction.Translate("We should keep moving."), s.Feed("We should keep moving."));
    }

    /// Noktayla biten çöp okuma (altyazılar geçişte üst üste solarken) ilk karede çevrilmez; ardından gelen düzgün okuma çevrilir.
    [Fact]
    public void GarbledSentenceIsNotSentOnFirstFrame()
    {
        var s = new SubtitleStabilizer();
        Assert.Equal(StabilizerAction.None, s.Feed("Gtt solkolfege."));
        Assert.Equal(StabilizerAction.Translate("Go to college."), s.Feed("Go to college."));
    }

    /// Altyazılar geçişte üst üste solarken birkaç kare aynı çöp okunabiliyor (GTA V, #26): geçiş süresince çevrilmez,
    /// gerçekten öyle duran yazı ise sonunda çevrilir.
    [Fact]
    public void GarbledLineIsSentOnlyAfterStayingLongerThanACrossfade()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        const string garbled = "- Nat) but, you knpw. shit, I m";
        for (var i = 0; i < 5; i++)
        {
            Assert.Equal(StabilizerAction.None, s.Feed(garbled));
            clock.Now += 100;
        }
        clock.Now += SubtitleStabilizer.GarbledStableMs;
        Assert.Equal(StabilizerAction.Translate(garbled), s.Feed(garbled));
    }

    /// Daktilo efektinde yarım satır gönderildikten sonra tamamı gelirse o da çevrilir.
    [Fact]
    public void CompletedLineAfterSentPartIsTranslated()
    {
        var s = new SubtitleStabilizer();
        Assert.Equal(StabilizerAction.None, s.Feed("We do not have"));
        Assert.Equal(StabilizerAction.Translate("We do not have"), s.Feed("We do not have"));
        Assert.Equal(StabilizerAction.Translate("We do not have time for this."), s.Feed("We do not have time for this."));
    }

    private const string Full = "Shit, I just came by to see if there's somethin' I can help you with.";
    private const string Worse = "Shit, I came by to see if there somethinl I can help ya.";

    /// Açık zeminde (GTA V, #26) aynı cümle her karede bir iki sözcüğü eksik ya da başka okunuyordu; her okuma ayrı
    /// çevrilip TV'de üç çeviri üst üste duruyordu. Daha kötü okuma yeni satır sayılmaz, eskisiyle gidip gelmesi de.
    [Fact]
    public void WorseRereadOfSentLineIsNotTranslatedAgain()
    {
        var s = new SubtitleStabilizer();
        Assert.Equal(StabilizerAction.Translate(Full), s.Feed(Full));
        Assert.Equal(StabilizerAction.None, s.Feed(Worse));
        Assert.Equal(StabilizerAction.None, s.Feed(Full));
        Assert.Equal(StabilizerAction.None, s.Feed(Worse));
    }

    /// Önce eksik okunan cümlenin daha çok sözcüklü okuması gelirse yeniden çevrilir (TV eskisinin yerine koyar).
    [Fact]
    public void BetterRereadOfSentLineIsTranslated()
    {
        var s = new SubtitleStabilizer();
        Assert.Equal(StabilizerAction.Translate(Worse), s.Feed(Worse));
        Assert.Equal(StabilizerAction.Translate(Full), s.Feed(Full));
        Assert.Equal(StabilizerAction.None, s.Feed(Worse));
    }

    /// Cümle bitmişse beklemeye gerek yok; hızlı konuşmada her kare önemli.
    [Theory]
    [InlineData("We do not have time.")]
    [InlineData("Wait!")]
    [InlineData("Who are you?")]
    [InlineData("I know…")]
    [InlineData("\"Run.\"")]
    public void FinishedSentenceIsSentOnFirstFrame(string line)
    {
        var s = new SubtitleStabilizer();
        Assert.Equal(StabilizerAction.Translate(line), s.Feed(line));
        Assert.Equal(StabilizerAction.None, s.Feed(line));
    }

    [Fact]
    public void OcrNoiseDoesNotReemit()
    {
        var s = new SubtitleStabilizer();
        s.Feed("The gate will not hold"); s.Feed("The gate will not hold");
        Assert.Equal(StabilizerAction.None, s.Feed("The gale will not hold"));
        Assert.Equal(StabilizerAction.None, s.Feed("The gale will not hold"));
    }

    [Fact]
    public void FlickeringHudDoesNotSpam()
    {
        var s = new SubtitleStabilizer();
        var sent = 0;
        for (var i = 0; i < 20; i++)
            if (s.Feed(i % 2 == 0 ? "24 / 120" : "").Kind == StabilizerKind.Translate) sent++;
        Assert.Equal(0, sent);
    }

    [Fact]
    public void TypewriterSendsCompletedLine()
    {
        var s = new SubtitleStabilizer();
        s.Feed("We do"); s.Feed("We do not have");
        Assert.Equal(StabilizerAction.Translate("We do not have time for this, boy."), s.Feed("We do not have time for this, boy."));
        Assert.Equal(StabilizerAction.None, s.Feed("We do not have time for this, boy."));
    }

    /// Altyazının kalktığına okuma sayısıyla değil süreyle karar verilir: bölge 800 ms boş kalınca silinir.
    [Fact]
    public void EmptyRegionClearsAfterClearTime()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        s.Feed("Hello there"); s.Feed("Hello there");
        Assert.Equal(StabilizerAction.None, s.Feed(""));
        clock.Now += SubtitleStabilizer.ClearAfterMs - 1;
        Assert.Equal(StabilizerAction.None, s.Feed(""));
        clock.Now += 1;
        Assert.Equal(StabilizerAction.Clear, s.Feed(""));
        Assert.Equal(StabilizerAction.None, s.Feed(""));
    }

    /// Parlak arka planda okuma birkaç kare kaçar; 800 ms'den kısa boşluk ne siler ne yeniden gönderir.
    [Fact]
    public void ShortFlickerNeitherClearsNorResends()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        s.Feed("Hold the gate");
        Assert.Equal(StabilizerAction.Translate("Hold the gate"), s.Feed("Hold the gate"));
        for (var i = 0; i < 3; i++)
        {
            for (var frame = 0; frame < 10; frame++) { clock.Now += 50; Assert.Equal(StabilizerAction.None, s.Feed("")); }
            for (var frame = 0; frame < 4; frame++) { clock.Now += 50; Assert.Equal(StabilizerAction.None, s.Feed("Hold the gate")); }
        }
    }

    /// Kalkan satır 1,5 sn içinde geri gelirse yeniden çevrilmez; çevirisi yeniden gösterilsin diye Restore döner.
    [Fact]
    public void LineReturningSoonAfterClearIsRestored()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        Assert.Equal(StabilizerAction.Translate("Hold the gate."), s.Feed("Hold the gate."));
        s.Feed("");
        clock.Now += SubtitleStabilizer.ClearAfterMs;
        Assert.Equal(StabilizerAction.Clear, s.Feed(""));
        clock.Now += SubtitleStabilizer.RestoreWithinMs;
        Assert.Equal(StabilizerAction.None, s.Feed("Hold the gate"));
        Assert.Equal(StabilizerAction.Restore("Hold the gate."), s.Feed("Hold the gate"));
        Assert.Equal(StabilizerAction.None, s.Feed("Hold the gate."));
        // Geri gelen satır da kalkınca silinir.
        s.Feed("");
        clock.Now += SubtitleStabilizer.ClearAfterMs;
        Assert.Equal(StabilizerAction.Clear, s.Feed(""));
    }

    /// Daha geç gelen aynı satır gerçek bir tekrardır (oyunda aynı söz yeniden söylendi); yeniden çevrilir.
    [Fact]
    public void LineReturningLaterIsTranslatedAgain()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        s.Feed("Hold the gate.");
        s.Feed("");
        clock.Now += SubtitleStabilizer.ClearAfterMs;
        Assert.Equal(StabilizerAction.Clear, s.Feed(""));
        clock.Now += SubtitleStabilizer.RestoreWithinMs + 1;
        Assert.Equal(StabilizerAction.Translate("Hold the gate."), s.Feed("Hold the gate."));
    }

    /// Okuma iki satır arasında gidip gelirse (yerine başkası geldi, sonra geri döndü) eski satır yeniden çevrilmez.
    [Fact]
    public void ReplacedLineComingBackIsRestored()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        Assert.Equal(StabilizerAction.Translate("Hold the gate."), s.Feed("Hold the gate."));
        clock.Now += 100;
        Assert.Equal(StabilizerAction.Translate("Run!"), s.Feed("Run!"));
        clock.Now += 100;
        Assert.Equal(StabilizerAction.Restore("Hold the gate."), s.Feed("Hold the gate."));
        clock.Now += 100;
        Assert.Equal(StabilizerAction.Restore("Run!"), s.Feed("Run!"));
    }

    /// İki konuşmacı neredeyse aynı sözleri söylüyor; ikinci satır da çevrilmeli.
    [Theory]
    [InlineData("Where are you going?", "Where are you going, boy?")]
    [InlineData("Where are you going, boy?", "Where are you going?")]
    [InlineData("We need to leave this place before the sun goes down.", "We need to leave this place before the sun goes down, boy.")]
    public void TwoSpeakersWithOverlappingWordsAreBothTranslated(string first, string second)
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        Assert.Equal(StabilizerAction.Translate(first), s.Feed(first));
        clock.Now += 50;
        Assert.Equal(StabilizerAction.Translate(second), s.Feed(second));
    }

    /// Önceden çeviren çevirmenle: bozuk ilk kare tek başına gönderilmez; doğrulanan satır ilk okunan hâliyle gider
    /// (çevirisi o metinle başlatılmıştı).
    [Fact]
    public void GarbledFirstReadingIsConfirmedThenSentAsFirstRead()
    {
        var s = new SubtitleStabilizer(cleanFastPathOnly: true);
        Assert.Equal(StabilizerAction.None, s.Feed("xa Oh, I know exactly who gave you your orders."));
        Assert.Equal(StabilizerAction.Translate("xa Oh, I know exactly who gave you your orders."), s.Feed("Oh, I know exactly who gave you your orders."));
        Assert.Equal(StabilizerAction.None, s.Feed("Oh, I know exactly who gave you your orders."));
    }

    [Fact]
    public void SingleGarbledFrameIsNeverSentButCleanLineGoesAtOnce()
    {
        var s = new SubtitleStabilizer(cleanFastPathOnly: true);
        Assert.Equal(StabilizerAction.None, s.Feed("f fe & ie want it."));
        Assert.Equal(StabilizerAction.Translate("In fact, sir, now you can do me a favor..."), s.Feed("In fact, sir, now you can do me a favor..."));
    }

    /// Bir kez görünüp kalkan kısa satır da gösterilmeli (yalnız iki kare doğrulaması bunu hiç göstermiyordu).
    [Fact]
    public void CleanLineSeenOnceIsSent()
    {
        var s = new SubtitleStabilizer(cleanFastPathOnly: true);
        Assert.Equal(StabilizerAction.Translate("you boys... how'd you boys like a couple of bucks?"), s.Feed("you boys... how'd you boys like a couple of bucks?"));
    }

    [Theory]
    [InlineData("Peter: I did it.", true)]
    [InlineData("Spider-Man: First cover!", true)]
    [InlineData("Head over to the tavern run by Mr. Gray...", true)]
    [InlineData("f fe & ie want it.", false)]
    [InlineData("A _ there's an extra ten bucks if you do.", false)]
    [InlineData("4 Pr and give the stuff out for free.", false)]
    [InlineData("Spider-Man **: can't believe you have this!", false)]
    public void CleanReadingsAreRecognised(string raw, bool clean) => Assert.Equal(clean, SubtitleStabilizer.LooksClean(raw));

    [Fact]
    public void AlreadyTranslatedIsSkipped()
    {
        var s = new SubtitleStabilizer();
        Assert.False(s.ShouldSend("Kullanıcı Ekle Oturum Açtı", "Kullanıcı Ekle Oturum Açtı"));
        Assert.True(s.ShouldSend("Add user", "Kullanıcı ekle"));
    }

    [Fact]
    public void ResetClearsOnlyAfterSomethingWasSent()
    {
        var s = new SubtitleStabilizer();
        Assert.Equal(StabilizerAction.None, s.Reset());
        s.Feed("Hello there"); s.Feed("Hello there");
        Assert.Equal(StabilizerAction.Clear, s.Reset());
        Assert.Equal(StabilizerAction.None, s.Reset());
    }

    /// Çevirisi başarısız olan satır ekranda kaldıkça yeniden denenebilmeli; ama saniyede en çok bir kez.
    [Fact]
    public void ForgottenLineIsTranslatedAgainAfterBackoff()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        s.Feed("Hold the gate");
        Assert.Equal(StabilizerAction.Translate("Hold the gate"), s.Feed("Hold the gate"));
        s.ForgetSent();
        for (var frame = 0; frame < 19; frame++) { clock.Now += 50; Assert.Equal(StabilizerAction.None, s.Feed("Hold the gate")); }
        clock.Now += 50;
        Assert.Equal(StabilizerAction.Translate("Hold the gate"), s.Feed("Hold the gate"));
    }

    /// <summary>Altyazının bölgedeki yeri ve bölge izi (64 × 12 gri örnek).</summary>
    private static readonly TextBox Place = new(0.3, 0.6, 0.7, 0.85);

    private static byte[] Scene(Action<byte[]>? change = null)
    {
        var signature = Enumerable.Repeat((byte)120, ReadScheduler.SignatureWidth * ReadScheduler.SignatureHeight).ToArray();
        change?.Invoke(signature);
        return signature;
    }

    /// <summary>Altyazının yerine düşen bir örnek (satır 8, sütun 30).</summary>
    private static void SubtitleSpot(byte[] s, int delta) => s[(8 * ReadScheduler.SignatureWidth) + 30] = (byte)(120 + delta);

    /// <summary>
    /// Parlak zeminde yazı tanıma ekranda duran altyazıyı saniyelerce okuyamıyor (It Takes Two): satırın yeri, son
    /// okunduğu kareden beri değişmediyse (bölgenin başka yerindeki kıpırtı ve video gürültüsü sayılmaz) satır silinmez,
    /// yeniden okununca da yeniden çevrilmez.
    /// </summary>
    [Fact]
    public void LineIsKeptThroughMissedReadsWhileItsPlaceIsUnchanged()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        Assert.Equal(StabilizerAction.Translate("Hold the gate."), s.Feed("Hold the gate.", Scene(), Place));
        var moving = Scene(x => { x[0] = 250; x[5] = 10; SubtitleSpot(x, 10); });
        for (var t = 0; t < 3000; t += 50)
        {
            clock.Now += 50;
            Assert.Equal(StabilizerAction.None, s.Feed("", moving, null));
        }
        Assert.Equal(StabilizerAction.None, s.Feed("Hold the gate.", Scene(), Place));
        // Okunduktan sonra yine kaçarsa süre baştan sayılır.
        for (var t = 0; t < 3000; t += 50)
        {
            clock.Now += 50;
            Assert.Equal(StabilizerAction.None, s.Feed("", Scene(), null));
        }
    }

    /// <summary>Altyazı gerçekten kalkınca (yeri değişti) satır her zamanki sürede silinir.</summary>
    [Fact]
    public void LineIsClearedOnTimeWhenItsPlaceChanges()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        s.Feed("Hold the gate.", Scene(), Place);
        var gone = Scene(x => SubtitleSpot(x, 60));
        Assert.Equal(StabilizerAction.None, s.Feed("", gone, null));
        clock.Now += SubtitleStabilizer.ClearAfterMs - 1;
        Assert.Equal(StabilizerAction.None, s.Feed("", gone, null));
        clock.Now += 1;
        Assert.Equal(StabilizerAction.Clear, s.Feed("", gone, null));
    }

    /// <summary>Okuma bir süre kaçtıktan sonra satırın yeri değişirse silinme o andan itibaren her zamanki sürede olur.</summary>
    [Fact]
    public void HeldLineIsClearedOnTimeOnceItsPlaceChanges()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        s.Feed("Hold the gate.", Scene(), Place);
        clock.Now += 2000;
        Assert.Equal(StabilizerAction.None, s.Feed("", Scene(), null));
        clock.Now += 1000;
        var gone = Scene(x => SubtitleSpot(x, -60));
        Assert.Equal(StabilizerAction.None, s.Feed("", gone, null));
        clock.Now += SubtitleStabilizer.ClearAfterMs - 1;
        Assert.Equal(StabilizerAction.None, s.Feed("", Scene(), null));
        clock.Now += 1;
        Assert.Equal(StabilizerAction.Clear, s.Feed("", Scene(), null));
    }

    /// <summary>Yeri hiç değişmese de boş okunan satır en çok <see cref="SubtitleStabilizer.HoldUnchangedMs"/> tutulur.</summary>
    [Fact]
    public void UnchangedPlaceHoldsTheLineOnlyForALimitedTime()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        s.Feed("Hold the gate.", Scene(), Place);
        Assert.Equal(StabilizerAction.None, s.Feed("", Scene(), null));
        clock.Now += SubtitleStabilizer.HoldUnchangedMs - 1;
        Assert.Equal(StabilizerAction.None, s.Feed("", Scene(), null));
        clock.Now += 1;
        Assert.Equal(StabilizerAction.Clear, s.Feed("", Scene(), null));
    }

    /// <summary>Satırın yeri bilinmiyorsa (okuyucu kutu vermedi) ya da kare izi yoksa eski kural: 800 ms boşlukta silinir.</summary>
    [Fact]
    public void WithoutPlaceOrSignatureEmptyReadsClearAsBefore()
    {
        foreach (var (signature, place) in new (byte[]?, TextBox?)[] { (Scene(), null), (null, Place) })
        {
            var clock = new TestClock();
            var s = new SubtitleStabilizer(clock: clock.Read);
            s.Feed("Hold the gate.", signature, place);
            s.Feed("", signature, null);
            clock.Now += SubtitleStabilizer.ClearAfterMs;
            Assert.Equal(StabilizerAction.Clear, s.Feed("", signature, null));
        }
    }

    /// Bekleme yalnız başarısız satır için: başka bir satır hemen çevrilir.
    [Fact]
    public void BackoffDoesNotDelayANewLine()
    {
        var clock = new TestClock();
        var s = new SubtitleStabilizer(clock: clock.Read);
        s.Feed("Hold the gate"); s.Feed("Hold the gate");
        s.ForgetSent();
        Assert.Equal(StabilizerAction.Translate("Run!"), s.Feed("Run!"));
    }
}

internal sealed class TestClock
{
    public long Now { get; set; } = 1_000_000;
    public long Read() => Now;
}
